#!/usr/bin/env bash
# Self-test de check-security-surface.sh (AIR-232 Parte A).
# Verifica +/- por cada una de las 4 reglas (S1..S4), el caso clave del literal
# PUBLIC (lección AIR-231) y el salto por allowlist. Usa archivos temporales
# (mktemp); NUNCA escribe en supabase/migrations/.
# Uso: bash scripts/agent/check-security-surface.selftest.sh   (exit 0 = OK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$DIR/check-security-surface.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "ok    $1"; PASS=$((PASS+1)); }
bad() { echo "BAD   $1"; FAIL=$((FAIL+1)); }
run() { bash "$LINT" --file "$1" 2>&1; }   # captura ANTES de grepear (pipefail + exit 1)

# ============================================================
# S1 — SECURITY DEFINER sin REVOKE ... FROM PUBLIC
# ============================================================

# S1-neg: SECDEF con REVOKE ... FROM PUBLIC, anon, authenticated -> PASA (sin FAIL S1).
cat > "$TMP/s1_ok_public.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.foo(p int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT p; $$;
REVOKE EXECUTE ON FUNCTION public.foo(int) FROM PUBLIC, anon, authenticated;
SQL
OUT="$(run "$TMP/s1_ok_public.sql")"
echo "$OUT" | grep -q "S1:" && bad "S1 no debe disparar con REVOKE ... FROM PUBLIC" || ok "S1 pasa con REVOKE ... FROM PUBLIC"

# S1-pos (CLAVE AIR-231): REVOKE solo FROM anon, authenticated (SIN PUBLIC) -> FALLA.
cat > "$TMP/s1_bad_nopublic.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.foo(p int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT p; $$;
REVOKE EXECUTE ON FUNCTION public.foo(int) FROM anon, authenticated;
SQL
OUT="$(run "$TMP/s1_bad_nopublic.sql")"
echo "$OUT" | grep -q "S1:.*public.foo" \
  && ok "S1 FALLA con REVOKE ... FROM anon,authenticated SIN PUBLIC (caso AIR-231)" \
  || bad "S1 DEBERÍA fallar sin el literal PUBLIC"

# S1-pos: SECDEF sin ningún REVOKE -> FALLA.
cat > "$TMP/s1_bad_norevoke.sql" <<'SQL'
CREATE FUNCTION public.bar()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN NULL; END; $$;
SQL
OUT="$(run "$TMP/s1_bad_norevoke.sql")"
echo "$OUT" | grep -q "S1:.*public.bar" \
  && ok "S1 FALLA sin ningún REVOKE" || bad "S1 DEBERÍA fallar sin REVOKE"

# S1-allowlist: firma en allowlist (analytics.get_kpis) sin REVOKE -> NO FALLA S1.
cat > "$TMP/s1_allow.sql" <<'SQL'
CREATE OR REPLACE FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(x numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT 1::numeric; $$;
GRANT EXECUTE ON FUNCTION analytics.get_kpis(date, date, text) TO anon;
SQL
run "$TMP/s1_allow.sql" | grep -q "S1:" \
  && bad "S1 NO debe disparar en función allowlisted (analytics.get_kpis)" \
  || ok "S1 se salta la firma allowlisted (analytics.get_kpis)"

# ============================================================
# S4 — SECURITY DEFINER sin SET search_path
# ============================================================

# S4-pos: SECDEF sin SET search_path -> FALLA (y también S1: sin REVOKE).
cat > "$TMP/s4_bad.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.baz()
RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1; $$;
REVOKE EXECUTE ON FUNCTION public.baz() FROM PUBLIC;
SQL
OUT="$(run "$TMP/s4_bad.sql")"
echo "$OUT" | grep -q "S4:.*public.baz" \
  && ok "S4 FALLA sin SET search_path" || bad "S4 DEBERÍA fallar sin SET search_path"
# El REVOKE FROM PUBLIC está presente -> S1 NO debe disparar aquí (aísla S4).
echo "$OUT" | grep -q "S1:" && bad "S4 case: S1 no debía disparar (hay REVOKE FROM PUBLIC)" || ok "S4 case: S1 correctamente silencioso"

# S4-neg: SECDEF con SET search_path + REVOKE FROM PUBLIC -> sin FAIL.
cat > "$TMP/s4_ok.sql" <<'SQL'
CREATE FUNCTION public.qux()
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT 1; $$;
REVOKE EXECUTE ON FUNCTION public.qux() FROM PUBLIC, anon, authenticated;
SQL
run "$TMP/s4_ok.sql" | grep -qE "FAIL" \
  && bad "S4-neg no debía producir FAIL alguno" || ok "S4 pasa con search_path + REVOKE FROM PUBLIC"

# ============================================================
# S2 — CREATE TABLE public.<x> sin ENABLE ROW LEVEL SECURITY
# ============================================================

# S2-pos: CREATE TABLE public sin RLS -> FALLA.
cat > "$TMP/s2_bad.sql" <<'SQL'
CREATE TABLE public.secreta (id int primary key, dato text);
SQL
OUT="$(run "$TMP/s2_bad.sql")"
echo "$OUT" | grep -q "S2:.*public.secreta" \
  && ok "S2 FALLA en CREATE TABLE public sin RLS" || bad "S2 DEBERÍA fallar sin ENABLE RLS"

# S2-neg: CREATE TABLE public CON ENABLE RLS -> sin FAIL.
cat > "$TMP/s2_ok.sql" <<'SQL'
CREATE TABLE public.segura (id int primary key, dato text);
ALTER TABLE public.segura ENABLE ROW LEVEL SECURITY;
SQL
run "$TMP/s2_ok.sql" | grep -qE "FAIL" \
  && bad "S2-neg no debía producir FAIL" || ok "S2 pasa con ENABLE ROW LEVEL SECURITY"

# S2-neg (schema no-public): CREATE TABLE analytics.x sin RLS -> NO dispara S2.
cat > "$TMP/s2_analytics.sql" <<'SQL'
CREATE TABLE analytics.staging (id int, v numeric);
SQL
run "$TMP/s2_analytics.sql" | grep -q "S2:" \
  && bad "S2 solo aplica a public.*, no a analytics.*" || ok "S2 no dispara en analytics.* (acotado a public)"

# ============================================================
# S3 — CREATE [MATERIALIZED] VIEW public.<x> sin security_invoker
# ============================================================

# S3-pos: CREATE VIEW public sin security_invoker -> FALLA.
cat > "$TMP/s3_bad.sql" <<'SQL'
CREATE VIEW public.v_expuesta AS SELECT id, dato FROM public.segura;
SQL
OUT="$(run "$TMP/s3_bad.sql")"
echo "$OUT" | grep -q "S3:.*public.v_expuesta" \
  && ok "S3 FALLA en CREATE VIEW public sin security_invoker" || bad "S3 DEBERÍA fallar sin security_invoker"

# S3-neg: CREATE VIEW public CON security_invoker = true (WITH inline) -> sin FAIL.
cat > "$TMP/s3_ok_inline.sql" <<'SQL'
CREATE VIEW public.v_ok WITH (security_invoker = true) AS SELECT 1 AS x;
SQL
run "$TMP/s3_ok_inline.sql" | grep -qE "FAIL" \
  && bad "S3-neg (inline) no debía producir FAIL" || ok "S3 pasa con WITH (security_invoker = true)"

# S3-neg: security_invoker vía ALTER VIEW aparte -> sin FAIL.
cat > "$TMP/s3_ok_alter.sql" <<'SQL'
CREATE VIEW public.v_ok2 AS SELECT 1 AS x;
ALTER VIEW public.v_ok2 SET (security_invoker = true);
SQL
run "$TMP/s3_ok_alter.sql" | grep -qE "FAIL" \
  && bad "S3-neg (ALTER) no debía producir FAIL" || ok "S3 pasa con ALTER VIEW ... SET (security_invoker = true)"

# S3-neg (regresión analytics.view_dashboard_*): NO debe fallar (acotado a public).
cat > "$TMP/s3_analytics_dashboard.sql" <<'SQL'
CREATE OR REPLACE VIEW analytics.view_dashboard_kpis AS SELECT 1 AS x;
SQL
run "$TMP/s3_analytics_dashboard.sql" | grep -q "S3:" \
  && bad "S3 no debe disparar en analytics.view_dashboard_* (acotado a public)" \
  || ok "S3 no dispara en analytics.view_dashboard_* (regresión OK)"

# ============================================================
# AIR-232 (Parte A, endurecimiento): 7 vectores de evasión que antes daban 0 fail.
# Cada caso afirma que el vector AHORA es bloqueado (FALLA), o para V7 que el
# overload peligroso NO queda exento por la allowlist.
# ============================================================

# V1 — comentario de bloque /* */ entre SECURITY y DEFINER (en Postgres es whitespace).
cat > "$TMP/v1_block_comment.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.evil1(p int)
RETURNS int LANGUAGE sql SECURITY /* sneaky */ DEFINER SET search_path = public AS $$ SELECT p; $$;
SQL
OUT="$(run "$TMP/v1_block_comment.sql")"
echo "$OUT" | grep -q "S1:.*public.evil1" \
  && ok "V1 FALLA: SECURITY /* */ DEFINER (comentario de bloque saneado)" \
  || bad "V1 DEBERÍA fallar: comentario de bloque entre SECURITY y DEFINER evade"

# V2 — SECURITY y DEFINER en líneas separadas (statement multilínea).
cat > "$TMP/v2_multiline.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.evil2(p int)
RETURNS int LANGUAGE sql
SECURITY
DEFINER
SET search_path = public AS $$ SELECT p; $$;
SQL
OUT="$(run "$TMP/v2_multiline.sql")"
echo "$OUT" | grep -q "S1:.*public.evil2" \
  && ok "V2 FALLA: SECURITY / DEFINER en líneas separadas (detección por statement)" \
  || bad "V2 DEBERÍA fallar: SECURITY y DEFINER en líneas separadas evade"

# V3 — CREATE TABLE con schema citado "public".
cat > "$TMP/v3_quoted_schema.sql" <<'SQL'
CREATE TABLE "public".secreta (id int primary key, dato text);
SQL
OUT="$(run "$TMP/v3_quoted_schema.sql")"
echo "$OUT" | grep -q "S2:.*public.secreta" \
  && ok 'V3 FALLA: CREATE TABLE "public".secreta (schema citado normalizado)' \
  || bad 'V3 DEBERÍA fallar: schema citado "public" evade S2'

# V4 — CREATE TABLE con espacios alrededor del punto.
cat > "$TMP/v4_spaced_dot.sql" <<'SQL'
CREATE TABLE public . secreta (id int primary key, dato text);
SQL
OUT="$(run "$TMP/v4_spaced_dot.sql")"
echo "$OUT" | grep -q "S2:.*public.secreta" \
  && ok "V4 FALLA: CREATE TABLE public . secreta (espacios en el qualifier normalizados)" \
  || bad "V4 DEBERÍA fallar: espacios alrededor del '.' evaden S2"

# V5 — CREATE VIEW con schema citado "public".
cat > "$TMP/v5_quoted_view.sql" <<'SQL'
CREATE VIEW "public".v_expuesta AS SELECT 1 AS x;
SQL
OUT="$(run "$TMP/v5_quoted_view.sql")"
echo "$OUT" | grep -q "S3:.*public.v_expuesta" \
  && ok 'V5 FALLA: CREATE VIEW "public".v_expuesta (schema citado normalizado)' \
  || bad 'V5 DEBERÍA fallar: schema citado "public" evade S3'

# V6 — REVOKE con NOMBRE CORTO pero OTRO schema (analytics.foo) no cuenta para public.foo.
cat > "$TMP/v6_revoke_wrong_schema.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.foo(p int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT p; $$;
REVOKE EXECUTE ON FUNCTION analytics.foo(int) FROM PUBLIC;
SQL
OUT="$(run "$TMP/v6_revoke_wrong_schema.sql")"
echo "$OUT" | grep -q "S1:.*public.foo" \
  && ok "V6 FALLA: REVOKE sobre analytics.foo no satisface el check de public.foo (firma completa)" \
  || bad "V6 DEBERÍA fallar: REVOKE por nombre corto en otro schema evade"

# V6b — REVOKE FROM PUBLIC pero un GRANT ... TO PUBLIC posterior REABRE el vector.
cat > "$TMP/v6b_grant_reopen.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.foo(p int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT p; $$;
REVOKE EXECUTE ON FUNCTION public.foo(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.foo(int) TO PUBLIC;
SQL
OUT="$(run "$TMP/v6b_grant_reopen.sql")"
echo "$OUT" | grep -q "S1:.*public.foo.*REABRE" \
  && ok "V6b FALLA: GRANT ... TO PUBLIC tras el REVOKE reabre el vector (net-effect)" \
  || bad "V6b DEBERÍA fallar: GRANT TO PUBLIC posterior anula el REVOKE"

# V7 — overload peligroso de un nombre allowlisted NO debe quedar exento por firma.
cat > "$TMP/v7_overload.sql" <<'SQL'
CREATE OR REPLACE FUNCTION analytics.get_kpis(evil text)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT 1; $$;
GRANT EXECUTE ON FUNCTION analytics.get_kpis(text) TO anon;
SQL
OUT="$(run "$TMP/v7_overload.sql")"
echo "$OUT" | grep -q "S1:.*analytics.get_kpis" \
  && ok "V7 FALLA: overload analytics.get_kpis(evil text) NO exento (allowlist por firma)" \
  || bad "V7 DEBERÍA fallar: overload de nombre allowlisted queda exento por qualname"

# ============================================================
# AIR-232 (Parte A, 2ª ronda): 2 vectores NUEVOS del security-reviewer.
#   N1 — '/*' o '--' dentro de un string '...' evadía el stripping de comentarios.
#   N2 — allowlist por aridad (no por firma de tipos): overload de igual aridad y
#        distinto tipo de un nombre allowlisted quedaba exento.
# ============================================================

# N1a — DEFAULT '/*' : el '/*' vive en un string; NO es comentario. Antes borraba
# SECURITY DEFINER/cuerpo/REVOKE hasta EOF -> 0 fail. Ahora S1 FALLA (sin REVOKE).
cat > "$TMP/n1a_slash_star_in_string.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.evil_n1b(p text DEFAULT '/*')
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT 1; $$;
SQL
OUT="$(run "$TMP/n1a_slash_star_in_string.sql")"
echo "$OUT" | grep -q "S1:.*public.evil_n1b" \
  && ok "N1a FALLA: DEFAULT '/*' en string no evade (string-aware)" \
  || bad "N1a DEBERÍA fallar: '/*' dentro de string '...' evade el stripping"

# N1b — DEFAULT '--' en la MISMA línea que SECURITY DEFINER. El '--' vive en un string;
# antes (2º strip 'sed s/--.*$//') borraba el resto de la línea -> evadía. Ahora S1 FALLA.
cat > "$TMP/n1b_dashdash_in_string.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.evil_n1c(p text DEFAULT '--') RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT 1; $$;
SQL
OUT="$(run "$TMP/n1b_dashdash_in_string.sql")"
echo "$OUT" | grep -q "S1:.*public.evil_n1c" \
  && ok "N1b FALLA: DEFAULT '--' en string (misma línea) no evade" \
  || bad "N1b DEBERÍA fallar: '--' dentro de string '...' borra el resto de la línea"

# N1-control — un '/*' de comentario REAL (fuera de string) SÍ se strippea y el caso sano
# (con REVOKE FROM PUBLIC + search_path) PASA sin FAIL. Asegura que el fix no rompe el
# stripping legítimo de comentarios.
cat > "$TMP/n1_control_real_comment.sql" <<'SQL'
/* comentario de bloque real: crea RPC de dashboard */
CREATE OR REPLACE FUNCTION public.sano_n1(p int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT p; $$;
REVOKE EXECUTE ON FUNCTION public.sano_n1(int) FROM PUBLIC, anon, authenticated;
SQL
run "$TMP/n1_control_real_comment.sql" | grep -qE "FAIL" \
  && bad "N1-control no debía producir FAIL (comentario real + caso sano)" \
  || ok "N1-control PASA: comentario /* */ real se strippea, caso sano sin FAIL"

# N2 — overload de un nombre allowlisted (analytics.get_funnel) con IGUAL aridad (3) pero
# DISTINTO tipo (text,text,text vs date,date,text). Antes exento por aridad -> 0 fail.
# Ahora S1 FALLA (la firma canónica de tipos no coincide con la allowlist).
cat > "$TMP/n2_overload_wrong_types.sql" <<'SQL'
CREATE OR REPLACE FUNCTION analytics.get_funnel(a text, b text, c text)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT 1; $$;
GRANT EXECUTE ON FUNCTION analytics.get_funnel(text,text,text) TO PUBLIC;
SQL
OUT="$(run "$TMP/n2_overload_wrong_types.sql")"
echo "$OUT" | grep -q "S1:.*analytics.get_funnel" \
  && ok "N2 FALLA: overload get_funnel(text,text,text) NO exento (allowlist por tipos)" \
  || bad "N2 DEBERÍA fallar: overload de igual aridad y distinto tipo queda exento"

# N2-control — la firma allowlisted EXACTA (date,date,text, con nombres/DEFAULT/alias)
# sigue exenta: NO debe disparar S1. Verifica que el match por tipos canónicos no produce
# falso positivo sobre el read-path legítimo del dashboard.
cat > "$TMP/n2_control_exact_sig.sql" <<'SQL'
CREATE OR REPLACE FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, analytics AS $$ SELECT 1; $$;
GRANT EXECUTE ON FUNCTION analytics.get_funnel(date, date, text) TO anon;
SQL
run "$TMP/n2_control_exact_sig.sql" | grep -q "S1:" \
  && bad "N2-control: la firma allowlisted exacta NO debía disparar S1" \
  || ok "N2-control PASA: firma allowlisted exacta (date,date,text) sigue exenta"

# ============================================================
# Regresión: migraciones reales 142 / 143 NO deben enrojecer.
# ============================================================
REPO="$(cd "$DIR/../.." && pwd)"
for m in 142_air231_revoke_execute_secdef_rpcs 143_air203_rls_direcciones_web_pii; do
  p="$REPO/supabase/migrations/${m}.sql"
  [ -f "$p" ] || { ok "skip regresión ${m} (no existe)"; continue; }
  if run "$p" | grep -qE "FAIL"; then
    bad "migración real ${m} produjo FAIL (falso positivo)"
  else
    ok "migración real ${m} sin FAIL"
  fi
done

echo "---"
echo "selftest: ${PASS} ok / ${FAIL} bad"
[ "$FAIL" -eq 0 ]
