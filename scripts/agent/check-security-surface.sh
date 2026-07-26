#!/usr/bin/env bash
# Superficie de seguridad de migraciones — guardarraíl CI determinista (AIR-232 Parte A).
#
# GATE BEST-EFFORT / DEFENSA EN PROFUNDIDAD. Este check es un linter de TEXTO sobre el diff
# de migraciones: atrapa las clases comunes de regresión (SECDEF sin REVOKE FROM PUBLIC,
# tabla public sin RLS, vista sin security_invoker, SECDEF sin search_path) en el PR, de
# forma barata. NO es un parser SQL hermético y NO debe tratarse como garantía: casos
# sintácticos exóticos (escape-strings raras, unicode U&'...', etc.) pueden evadirlo. La
# GARANTÍA real y no-evadible es la Parte B (AIR-261): get_advisors(security) contra el
# catálogo aplicado de Postgres, inmune a trucos de texto.
#
# Gradúa a check las 3 lecciones vivas de la auditoría de seguridad (AIR-231/AIR-203/AIR-87):
# lo que se repite en review de seguridad pasa a ser gate determinista, no prompt.
# Se dispara SOLO sobre las líneas AÑADIDAS de supabase/migrations/*.sql (una migración
# NUEVA introduce todo su contenido como añadido). No es retroactivo: el SQL histórico ya
# aplicado en PROD no entra al diff, así que no lo enrojece.
#
# 4 reglas (todas FAIL, bloquean el merge):
#   S1  CREATE [OR REPLACE] FUNCTION ... SECURITY DEFINER  sin un
#       REVOKE EXECUTE ON FUNCTION <fn> ... FROM ... PUBLIC en la MISMA migración.
#       Exige el literal PUBLIC (lección AIR-231 / mig 142: revocar solo de
#       anon/authenticated es un NO-OP mientras PUBLIC conserve el grant — cualquier
#       rol ejecuta la función vía la membresía implícita en PUBLIC). Excepción por
#       allowlist de firma (security-surface-allowlist.txt): RPCs analytics.* que
#       están GRANT-eadas a anon/authenticated por diseño (read-path del dashboard).
#   S2  CREATE TABLE public.<x>  (o  ALTER TABLE ... SET SCHEMA public)  sin su
#       ALTER TABLE ... ENABLE ROW LEVEL SECURITY. RLS deny-by-default es el patrón
#       de la base (mig 006). Sin RLS, anon key + URL del proyecto lee/escribe la tabla.
#   S3  CREATE [MATERIALIZED] VIEW public.<x>  sin  security_invoker = true. Una vista
#       SECURITY DEFINER (el default) evalúa permisos del owner y salta el RLS de las
#       tablas base (lección AIR-203 / AIR-87). Acotado a public. (por diseño excluye
#       analytics.view_dashboard_* — el dashboard las consume por service_role).
#   S4  CREATE FUNCTION ... SECURITY DEFINER  sin  SET search_path  explícito. Un
#       search_path mutable en una función que corre como owner es un vector de
#       escalada (advisor function_search_path_mutable).
#
# Uso (misma interfaz que check-data-rules.sh / check-docstring-rpc-loop.sh):
#   check-security-surface.sh --file <ruta>...   # archivos .sql concretos
#   check-security-surface.sh --diff <base>      # migraciones cambiadas vs base (origin/main)
# Salida: líneas "FAIL ..." (bloquean, exit 1). Sin FAIL -> exit 0.
set -uo pipefail

MODE="${1:---help}"; shift || true
FILES=()
case "$MODE" in
  --file) FILES=("$@") ;;
  --diff)
    BASE="${1:?Uso: check-security-surface.sh --diff <base>}"
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done \
      < <(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD -- 'supabase/migrations/*.sql' 2>/dev/null)
    ;;
  *) echo "Uso: check-security-surface.sh --file <ruta>... | --diff <base>"; exit 2 ;;
esac

FAILS=0
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }

ALLOWLIST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/security-surface-allowlist.txt"

# argcount <arglist>: número de argumentos de nivel superior de una firma. Cuenta las
# comas a profundidad 0 (respeta '(...)' y '[...]' anidados, p.ej. numeric(10,2), int[]).
# '' -> 0. Es la dimensión "args normalizada" de la firma: robusta a alias de tipos
# (int vs integer), a DEFAULT y a nombres de parámetro — a diferencia de comparar el
# texto de los tipos, que produciría falsos positivos contra migraciones reales.
argcount() {
  local a c depth=0 i n=0
  a="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$a" ] && { echo 0; return; }
  n=1
  for (( i=0; i<${#a}; i++ )); do
    c="${a:i:1}"
    case "$c" in
      '('|'[') depth=$((depth+1)) ;;
      ')'|']') depth=$((depth-1)) ;;
      ',') [ "$depth" -eq 0 ] && n=$((n+1)) ;;
    esac
  done
  echo "$n"
}

# paren_args <stmt-normalizado> <qual>: contenido del PRIMER grupo de paréntesis
# balanceado que sigue a '<qual>(' (la lista de argumentos de la firma). '' si no aparece.
# Opera sobre texto ya normalizado por strip_sql (comillas fuera, '.' sin espacios).
paren_args() {
  local s="$1" qual="$2" rest c depth=1 i out=""
  case "$s" in *"${qual}("*) rest="${s#*"${qual}("}" ;; *) echo ""; return 1 ;; esac
  for (( i=0; i<${#rest}; i++ )); do
    c="${rest:i:1}"
    if [ "$c" = "(" ]; then depth=$((depth+1))
    elif [ "$c" = ")" ]; then depth=$((depth-1)); [ "$depth" -eq 0 ] && break
    fi
    out="$out$c"
  done
  printf '%s' "$out"
}

# is_type_word <token>: true si <token> es la PRIMERA palabra de un nombre de tipo de
# Postgres (no un nombre de parámetro). Se usa para distinguir 'p_desde date' (nombre +
# tipo) de 'timestamp with time zone' (tipo multi-palabra sin nombre).
is_type_word() {
  case "$1" in
    int|int2|int4|int8|integer|smallint|bigint|bool|boolean|text|varchar|char|character|\
    numeric|decimal|real|float|float4|float8|double|precision|date|time|timestamp|timestamptz|timetz|\
    interval|json|jsonb|uuid|bytea|money|name|oid|xml|cidr|inet|macaddr|macaddr8|bit|\
    serial|bigserial|smallserial|point|line|lseg|box|path|polygon|circle|tsvector|tsquery|\
    hstore|anyelement|anyarray|anynonarray|record|void|trigger) return 0 ;;
    *) return 1 ;;
  esac
}

# canon_alias <tipo>: normaliza alias de tipos de Postgres a una forma canónica única
# (int/int4->integer, int8->bigint, int2->smallint, bool->boolean, varchar/character
# varying->character varying, numeric/decimal->numeric, float8/float->double precision,
# float4->real, timestamptz->timestamp with time zone, timetz->time with time zone, etc.).
# Descarta modificadores de longitud/precisión (numeric(10,2)->numeric) y preserva '[]'.
canon_alias() {
  local t arr=""
  t="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -s ' ')"
  case "$t" in *'[]') arr="[]"; t="$(printf '%s' "${t%\[\]}" | sed -E 's/[[:space:]]+$//')" ;; esac
  t="$(printf '%s' "$t" | sed -E 's/\([^)]*\)//g; s/[[:space:]]+$//')"
  case "$t" in
    int|int4)                                    t='integer' ;;
    int8)                                        t='bigint' ;;
    int2)                                        t='smallint' ;;
    bool)                                        t='boolean' ;;
    varchar|'character varying')                 t='character varying' ;;
    decimal|numeric)                             t='numeric' ;;
    float8|float|'double precision')             t='double precision' ;;
    float4|real)                                 t='real' ;;
    timestamptz|'timestamp with time zone')      t='timestamp with time zone' ;;
    timestamp|'timestamp without time zone')     t='timestamp without time zone' ;;
    timetz|'time with time zone')                t='time with time zone' ;;
    time|'time without time zone')               t='time without time zone' ;;
  esac
  printf '%s%s' "$t" "$arr"
}

# canon_one_type <arg>: tipo canónico de UN argumento. Descarta 'DEFAULT ...'/'= ...',
# el modo (IN/INOUT/VARIADIC; OUT se excluye de la firma de identidad -> ''), y el nombre
# de parámetro (identificador simple seguido de espacio que NO sea un type word). El resto
# se normaliza con canon_alias. Alinea con pg_get_function_identity_arguments.
canon_one_type() {
  local s mode="" first
  s="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -s ' ')"
  [ -z "$s" ] && { printf ''; return; }
  s="$(printf '%s' "$s" | sed -E 's/[[:space:]]+default[[:space:]]+.*$//; s/[[:space:]]*=[[:space:]]*.*$//')"
  case "$s" in
    'in '*)       s="${s#in }" ;;
    'out '*)      printf ''; return ;;
    'inout '*)    s="${s#inout }" ;;
    'variadic '*) s="${s#variadic }"; mode="variadic " ;;
  esac
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -s ' ')"
  first="$(printf '%s' "$s" | sed -E 's/^([a-z_][a-z0-9_]*)[[:space:]].*/\1/')"
  if [ "$first" != "$s" ] && ! is_type_word "$first"; then
    s="$(printf '%s' "$s" | sed -E 's/^[a-z_][a-z0-9_]*[[:space:]]+//')"
  fi
  printf '%s%s' "$mode" "$(canon_alias "$s")"
}

# canon_sig <arglist>: FIRMA canónica de tipos de una lista de argumentos, tipos
# separados por ',' (ignora nombres, DEFAULT y OUT; alias normalizados). '' -> ''.
# Es la firma de identidad normalizada usada para matchear allowlist por TIPOS (no solo
# por aridad — AIR-232/N2: un overload de misma aridad y distinto tipo NO queda exento).
canon_sig() {
  local a c depth=0 i cur="" out="" first=1
  a="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$a" ] && { printf ''; return; }
  local -a parts=()
  for (( i=0; i<${#a}; i++ )); do
    c="${a:i:1}"
    case "$c" in
      '('|'[') depth=$((depth+1)); cur="$cur$c" ;;
      ')'|']') depth=$((depth-1)); cur="$cur$c" ;;
      ',') if [ "$depth" -eq 0 ]; then parts+=("$cur"); cur=""; else cur="$cur$c"; fi ;;
      *) cur="$cur$c" ;;
    esac
  done
  parts+=("$cur")
  local p ct
  for p in "${parts[@]}"; do
    ct="$(canon_one_type "$p")"
    [ -z "$ct" ] && continue
    if [ "$first" -eq 1 ]; then out="$ct"; first=0; else out="$out,$ct"; fi
  done
  printf '%s' "$out"
}

# allow_hit <qualname> <aridad> <arglist-crudo>: true si la FIRMA COMPLETA (schema.fn +
# firma canónica de TIPOS) está en la allowlist de S1. Matchea por qualname Y tipos
# canónicos — NO solo por nombre (AIR-232/V7) ni solo por aridad (AIR-232/N2): un overload
# peligroso de un nombre allowlisted con DISTINTO tipo a igual aridad (p.ej.
# analytics.get_funnel(text,text,text) vs la firma legítima (date,date,text)) NO queda
# exento. La aridad se usa como pre-filtro rápido; el match exige tipos canónicos iguales.
# Un '#' inicia comentario.
allow_hit() {
  local q="$1" ar="$2" csig="$3" line lqual largs
  [ -f "$ALLOWLIST_FILE" ] || return 1
  csig="$(canon_sig "$csig")"
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr 'A-Z' 'a-z' | tr -d '"' \
            | sed -E 's/[[:space:]]*\.[[:space:]]*/./g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    lqual="$(printf '%s' "$line" | sed -E 's/\(.*//; s/[[:space:]]+$//')"
    [ "$lqual" = "$q" ] || continue
    case "$line" in
      *"("*) largs="$(printf '%s' "$line" | sed -E 's/^[^(]*\(//; s/\)[^)]*$//')" ;;
      *) largs="" ;;
    esac
    # Pre-filtro por aridad; match definitivo por firma canónica de tipos.
    [ "$(argcount "$largs")" = "$ar" ] || continue
    [ "$(canon_sig "$largs")" = "$csig" ] && return 0
  done < "$ALLOWLIST_FILE"
  return 1
}

# norm_stream: normaliza SQL (stdin) a UNA sola línea apta para partir por ';':
#   - reemplaza cada cuerpo dollar-quoted ($$...$$ / $tag$...$tag$) por ' ASBODY '
#     (los ';' internos del cuerpo de una función no deben partir statements);
#   - elimina comentarios de BLOQUE '/* ... */' (multilínea) y de LÍNEA '--' que vivan
#     FUERA de un cuerpo dollar-quoted Y FUERA de un string de comilla simple (en Postgres
#     un '/* */' es whitespace: sin esto, 'SECURITY /*x*/ DEFINER' evadía la detección —
#     AIR-232/V1);
#   - colapsa saltos de línea/tabs a espacios (une statements partidos en varias líneas
#     -> 'SECURITY\nDEFINER' se detecta como uno solo — AIR-232/V2);
#   - quita comillas dobles y colapsa espacios alrededor de '.' para normalizar el
#     qualifier de schema ("public".x, public . x -> public.x — AIR-232/V3,V4,V5).
# El tracker de dollar-quoting, de STRINGS de comilla simple y de comentarios se hace a
# mano (awk, char-a-char) porque los cuerpos y strings son multilínea. Precedencia del
# state-machine: cuerpo dollar-quoted > string '...' > comentario. Un '/*', '*/' o '--'
# DENTRO de un cuerpo o de un string NO es comentario y no debe tocarse (AIR-232/N1: un
# "DEFAULT '/*'" o "DEFAULT '--'" borraba SECURITY DEFINER/cuerpo/REVOKE hasta EOF).
# NOTA: NO hay un segundo strip de '--' fuera de awk — reintroduciría el hueco del '--'
# dentro de un string; el awk ya elimina TODO comentario de línea correctamente.
# SQ: la comilla simple se pasa como variable awk (-v) — el shell la sustituye literal
# dentro de "..." — para no depender de escapes hex/octal (\x27) que mawk antiguo no soporta.
norm_stream() {
  awk -v SQ="'" '
    { all = all $0 "\n" }
    END {
      n = length(all); i = 1; out = ""; intag = 0; tag = ""; instr = 0
      while (i <= n) {
        c = substr(all, i, 1)
        two = substr(all, i, 2)
        # Dentro de un string de comilla simple (nunca a la vez que un cuerpo dollar): la
        # comilla doblada ('' -> SQ SQ) es un escape (sigue en el string); ni /*, ni */, ni
        # -- son comentarios. Se emite literal hasta cerrar el string.
        # Un backslash inicia un PAR ESCAPADO: en una cadena escape E...e... un backslash+comilla
        # NO cierra el string (AIR-232/N3: un DEFAULT E backslash-comilla slash-star cerraba el
        # string en el backslash-comilla y el slash-star comia SECURITY DEFINER/REVOKE hasta EOF
        # -> 0 fail). SUPUESTO conservador: aplicamos el mismo trato a cualquier cadena de comilla
        # simple; con standard_conforming_strings Postgres trata el backslash como literal, asi que
        # reconocer backslash-comilla como escape es el comportamiento seguro que evita el truncado
        # (a lo sumo consume un char de mas DENTRO del string, nunca fuera).
        if (instr) {
          if (c == "\\") { out = out substr(all, i, 2); i += 2; continue }
          if (two == SQ SQ) { out = out SQ SQ; i += 2; continue }
          out = out c
          if (c == SQ) instr = 0
          i++; continue
        }
        if (!intag && two == "/*") {
          i += 2
          while (i <= n && substr(all, i, 2) != "*/") i++
          i += 2; out = out " "; continue
        }
        if (!intag && two == "--") {
          while (i <= n && substr(all, i, 1) != "\n") i++
          continue
        }
        # Un string de comilla simple solo ARRANCA fuera de un cuerpo dollar-quoted.
        if (!intag && c == SQ) { instr = 1; out = out c; i++; continue }
        if (c == "$") {
          j = i + 1; t = ""
          while (j <= n && substr(all, j, 1) ~ /[a-zA-Z0-9_]/) { t = t substr(all, j, 1); j++ }
          if (j <= n && substr(all, j, 1) == "$") {
            if (!intag)        { intag = 1; tag = t; out = out " ASBODY "; i = j + 1; continue }
            else if (t == tag) { intag = 0;          i = j + 1; continue }
            else               {                     i = j + 1; continue }
          }
        }
        if (!intag) out = out c
        i++
      }
      print out
    }
  ' | tr '\n\t' '  ' | tr -d '"' \
    | sed -E 's/[[:space:]]*\.[[:space:]]*/./g' | tr -s ' '
}
strip_sql() { norm_stream < "$1"; }

for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -f "$f" ] || continue
  case "$f" in *.sql) ;; *) continue ;; esac

  # ADDED: superficie del GATILLO. --diff -> solo líneas añadidas (la regla solo se
  # dispara cuando el PR INTRODUCE el patrón). --file -> archivo completo.
  if [ "$MODE" = "--diff" ]; then
    ADDED="$(git diff "$BASE"...HEAD -- "$f" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')"
  else
    ADDED="$(cat "$f")"
  fi
  # in_added <regex-egrep>: true si el patrón aparece (case-insensitive) en las líneas
  # añadidas, YA NORMALIZADAS (comentarios de bloque/línea fuera, saltos de línea unidos,
  # schema-qualifier normalizado). Normalizar antes de grepear cierra V1 (comentario de
  # bloque entre SECURITY y DEFINER) y V2 (SECURITY / DEFINER en líneas separadas): el
  # gatillo ya no es línea-a-línea. Un 'SECURITY DEFINER' citado en una cabecera '--' no
  # gatilla porque el comentario se elimina (mig 142 documenta "6 funciones SECURITY DEFINER").
  ADDED_FLAT="$(printf '%s\n' "$ADDED" | norm_stream)"
  in_added() { printf '%s' "$ADDED_FLAT" | grep -qiE "$1"; }

  # Statements bodyless del archivo COMPLETO (el COMPLEMENTO de cada regla —REVOKE,
  # ENABLE RLS, security_invoker— puede vivir en cualquier statement de la misma
  # migración, no necesariamente pegado al CREATE).
  FLAT="$(strip_sql "$f")"
  IFS=';' read -ra STMTS <<< "$FLAT"

  for stmt in "${STMTS[@]}"; do
    slc="$(printf '%s' "$stmt" | tr 'A-Z' 'a-z')"

    # ---------------- S1 + S4: funciones SECURITY DEFINER ----------------
    if printf '%s' "$slc" | grep -qE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function[[:space:]]' \
       && printf '%s' "$slc" | grep -qE 'security[[:space:]]+definer'; then
      qual="$(printf '%s' "$stmt" | grep -oiE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function[[:space:]]+[a-zA-Z0-9_.\"]+' \
              | head -1 | sed -E 's/.*function[[:space:]]+//I' | tr -d '"' | tr 'A-Z' 'a-z')"
      [ -z "$qual" ] && continue
      short="${qual##*.}"
      # GATILLO: la función SECDEF fue introducida por el diff (nombre + 'security definer'
      # en líneas añadidas). Evita disparar por un statement preexistente de una migración
      # apenas rozada por el PR (las migraciones son inmutables, pero somos precisos).
      in_added 'security[[:space:]]+definer' && in_added "(^|[^a-zA-Z0-9_])${short}([^a-zA-Z0-9_]|\$)" || continue

      # FIRMA: qualname + aridad + firma canónica de tipos. La aridad discrimina overloads
      # y es la base del matching de REVOKE/GRANT (V6): un REVOKE sobre OTRA firma (otro
      # schema u otra aridad) ya no satisface el check. La firma de tipos (cargs) discrimina
      # el match de allowlist (V7/N2): un overload de igual aridad y distinto tipo NO exento.
      cargs="$(paren_args "$slc" "$qual")"
      carity="$(argcount "$cargs")"
      qre="$(printf '%s' "$qual" | sed -E 's/[.]/\\./g')"

      # S4: SET search_path explícito en la MISMA definición (bodyless conserva la cabecera).
      if ! printf '%s' "$slc" | grep -qE 'set[[:space:]]+search_path'; then
        fail "$f — S4: función SECURITY DEFINER '${qual}' sin 'SET search_path' explícito (search_path mutable = vector de escalada)."
      fi

      # S1: REVOKE ... FROM ... PUBLIC para ESTA firma, sin GRANT que lo reabra.
      if allow_hit "$qual" "$carity" "$cargs"; then
        : # allowlisted (qualname + firma canónica de tipos): GRANT a anon/authenticated por diseño (dashboard).
      else
        # REVOKE EXECUTE ... <qual>(<misma aridad>) ... FROM ... PUBLIC.
        revoke_ok=0
        for r in "${STMTS[@]}"; do
          rlc="$(printf '%s' "$r" | tr 'A-Z' 'a-z')"
          printf '%s' "$rlc" | grep -qE 'revoke[[:space:]]+execute[[:space:]]+on[[:space:]]+function' || continue
          # Firma completa: MISMO qualname (no solo el nombre corto -> cierra V6, un REVOKE
          # sobre analytics.foo no cuenta para public.foo) y MISMA aridad.
          printf '%s' "$rlc" | grep -qE "(^|[^a-zA-Z0-9_.])${qre}\(" || continue
          [ "$(argcount "$(paren_args "$rlc" "$qual")")" = "$carity" ] || continue
          # El literal PUBLIC debe estar en la lista FROM (no en el 'public.' del schema,
          # que va ANTES de 'from'). Cortamos en el primer ' from ' y buscamos 'public'.
          case " $rlc " in *" from "*) frompart="${rlc#* from }" ;; *) continue ;; esac
          printf '%s' "$frompart" | grep -qwE 'public' && revoke_ok=1
        done
        # NET-EFFECT (V6b): un GRANT EXECUTE ... <qual>(<aridad>) ... TO ... PUBLIC/anon/
        # authenticated tras el REVOKE reabre el vector -> el REVOKE queda anulado.
        grant_reopen=0
        for g in "${STMTS[@]}"; do
          glc="$(printf '%s' "$g" | tr 'A-Z' 'a-z')"
          printf '%s' "$glc" | grep -qE 'grant[[:space:]]+execute[[:space:]]+on[[:space:]]+function' || continue
          printf '%s' "$glc" | grep -qE "(^|[^a-zA-Z0-9_.])${qre}\(" || continue
          [ "$(argcount "$(paren_args "$glc" "$qual")")" = "$carity" ] || continue
          case " $glc " in *" to "*) topart="${glc#* to }" ;; *) continue ;; esac
          printf '%s' "$topart" | grep -qwE 'public|anon|authenticated' && grant_reopen=1
        done
        if [ "$revoke_ok" -eq 0 ]; then
          fail "$f — S1: función SECURITY DEFINER '${qual}' sin 'REVOKE EXECUTE ON FUNCTION ${qual} ... FROM ... PUBLIC' en la misma migración (revocar solo de anon/authenticated es NO-OP; ver AIR-231). Si es read-path legítimo, agrégala a security-surface-allowlist.txt."
        elif [ "$grant_reopen" -eq 1 ]; then
          fail "$f — S1: función SECURITY DEFINER '${qual}' tiene REVOKE FROM PUBLIC pero un 'GRANT EXECUTE ... TO PUBLIC/anon/authenticated' posterior REABRE el vector (net-effect = ejecutable por anon; ver AIR-231/AIR-232)."
        fi
      fi
    fi

    # ---------------- S2: tablas public sin RLS ----------------
    tname=""
    if printf '%s' "$slc" | grep -qE 'create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?public\.'; then
      tname="$(printf '%s' "$stmt" | grep -oiE 'create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?public\.[a-zA-Z0-9_.\"]+' \
               | head -1 | sed -E 's/.*public\.//' | tr -d '"' | tr 'A-Z' 'a-z')"
    elif printf '%s' "$slc" | grep -qE 'alter[[:space:]]+table[[:space:]].*set[[:space:]]+schema[[:space:]]+public'; then
      tname="$(printf '%s' "$stmt" | grep -oiE 'alter[[:space:]]+table[[:space:]]+(only[[:space:]]+)?[a-zA-Z0-9_.\"]+' \
               | head -1 | sed -E 's/.*table[[:space:]]+(only[[:space:]]+)?//I' | tr -d '"' | tr 'A-Z' 'a-z')"
      tname="${tname##*.}"
    fi
    if [ -n "$tname" ]; then
      if in_added "(create[[:space:]]+table|set[[:space:]]+schema)" && in_added "(^|[^a-zA-Z0-9_])${tname}([^a-zA-Z0-9_]|\$)"; then
        rls_ok=0
        for t in "${STMTS[@]}"; do
          tlc="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"
          printf '%s' "$tlc" | grep -qE 'enable[[:space:]]+row[[:space:]]+level[[:space:]]+security' || continue
          printf '%s' "$tlc" | grep -qE "(^|[^a-zA-Z0-9_])${tname}([^a-zA-Z0-9_]|\$)" && rls_ok=1
        done
        [ "$rls_ok" -eq 0 ] && fail "$f — S2: tabla public.${tname} sin 'ALTER TABLE ... ENABLE ROW LEVEL SECURITY' en la migración (RLS deny-by-default; ver mig 006 / AIR-203)."
      fi
    fi

    # ---------------- S3: vistas public sin security_invoker ----------------
    if printf '%s' "$slc" | grep -qE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(materialized[[:space:]]+)?view[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?public\.'; then
      vname="$(printf '%s' "$stmt" | grep -oiE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(materialized[[:space:]]+)?view[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?public\.[a-zA-Z0-9_.\"]+' \
               | head -1 | sed -E 's/.*public\.//' | tr -d '"' | tr 'A-Z' 'a-z')"
      [ -z "$vname" ] && continue
      if in_added 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(materialized[[:space:]]+)?view' && in_added "(^|[^a-zA-Z0-9_])${vname}([^a-zA-Z0-9_]|\$)"; then
        si_ok=0
        for v in "${STMTS[@]}"; do
          vlc="$(printf '%s' "$v" | tr 'A-Z' 'a-z')"
          printf '%s' "$vlc" | grep -qE 'security_invoker[[:space:]]*=[[:space:]]*true' || continue
          printf '%s' "$vlc" | grep -qE "(^|[^a-zA-Z0-9_])${vname}([^a-zA-Z0-9_]|\$)" && si_ok=1
        done
        [ "$si_ok" -eq 0 ] && fail "$f — S3: vista public.${vname} sin 'security_invoker = true' (una vista SECURITY DEFINER salta el RLS de las tablas base; ver AIR-203 / AIR-87)."
      fi
    fi
  done
done

echo "---"
echo "security-surface: ${FAILS} fail (archivos: ${#FILES[@]})"
[ "$FAILS" -gt 0 ] && exit 1
exit 0
