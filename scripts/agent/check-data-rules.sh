#!/usr/bin/env bash
# Reglas críticas de datos de Aire de Agua — FUENTE ÚNICA DE VERDAD.
# La consumen: el hook run-checks.sh (por archivo, feedback al editar) y el
# CI de GitHub (sobre el diff del PR). Si una regla nueva se repite en reviews,
# se "gradúa" aquí (retro la propone) y deja de vivir solo en prompts.
#
# Uso:
#   check-data-rules.sh --file <ruta>...   # archivos concretos
#   check-data-rules.sh --diff <base>      # archivos cambiados vs base (p.ej. origin/main)
# Salida: líneas "FAIL ..." (bloquean, exit 1) y "WARN ..." (no bloquean).
set -uo pipefail
MODE="${1:---help}"; shift || true
BASE=""
FILES=()
case "$MODE" in
  --file) FILES=("$@") ;;
  --diff)
    BASE="${1:?Uso: check-data-rules.sh --diff <base>}"
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done \
      < <(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD -- '*.sql' '*.ts' '*.tsx' 'n8n/workflows/*.json' 2>/dev/null)
    ;;
  *) echo "Uso: check-data-rules.sh --file <ruta>... | --diff <base>"; exit 2 ;;
esac

FAILS=0; WARNS=0
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
warn() { echo "WARN  $1"; WARNS=$((WARNS+1)); }

# scan_text "<archivo>": superficie sobre la que se evalúa el GATILLO de cada regla.
#   --file: el archivo completo (feedback al editar en vivo, sin ruido de diff).
#   --diff: SOLO las líneas AÑADIDAS del PR para este archivo. Así una regla solo
#           se dispara cuando el PR INTRODUCE el patrón, no por texto preexistente
#           (bug AIR-143: PR #68 tocó E5A y R1 matcheó un 'valor_compras=$0'
#           pedagógico que ya existía). Excluimos el header '+++ b/...'.
# El COMPLEMENTO de las reglas multi-línea (R2/R3) NO usa esto: ver más abajo.
scan_text() {
  local file="$1"
  if [ "$MODE" = "--diff" ]; then
    git diff "$BASE"...HEAD -- "$file" 2>/dev/null \
      | grep -E '^\+' | grep -vE '^\+\+\+'
  else
    cat "$file"
  fi
}

for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -f "$f" ] || continue
  ADDED="$(scan_text "$f")"
  # Los workflows n8n (.json) entran SOLO para R1 (valor_compras): el bug de E8B
  # demostró que el grep de revenue de pixel debe cubrirlos. R2/R3/R4 son
  # específicas de SQL/TS y no aplican al JSON exportado.
  case "$f" in
    n8n/workflows/*.json)
      printf '%s' "$ADDED" | grep -qiE 'valor_compras' \
        && fail "$f — 'valor_compras' como revenue. Usa 'roas_real' / v_meta_ads_roas_real."
      continue ;;
  esac

  case "$f" in *.sql|*.ts|*.tsx) ;; *) continue ;; esac
  # saltar tipos generados de Supabase y tipos de vistas del dashboard hechos
  # a mano (analytics.ts): contienen nombres de columna (valor_compras,
  # ordered_at...) en definiciones de tipo, no en queries.
  case "$f" in */types/database.ts|*/database.types.ts|*/types/analytics.ts) continue ;; esac

  # R1 — valor_compras es revenue de Meta (0 por bug de pixel)
  # Single-keyword: el gatillo en $ADDED es prueba suficiente de violación NUEVA.
  printf '%s' "$ADDED" | grep -qiE 'valor_compras' \
    && fail "$f — 'valor_compras' como revenue. Usa 'roas_real' / v_meta_ads_roas_real."

  # R2 — ventas siempre en hora de Bogotá (+ estado_pago='paid')
  # Multi-línea (gatillo presente Y complemento ausente). Para no falsear por
  # contexto preexistente NI perder detección cuando el complemento legítimo ya
  # estaba en una línea no-añadida: el GATILLO ('ordered_at') se evalúa sobre
  # $ADDED (solo dispara si el PR lo introduce), pero el COMPLEMENTO
  # ('America/Bogota') se evalúa sobre el ARCHIVO COMPLETO ("$f").
  if printf '%s' "$ADDED" | grep -qiE 'ordered_at' && ! grep -qiE 'America/Bogota' "$f"; then
    fail "$f — 'ordered_at' sin AT TIME ZONE 'America/Bogota' (y filtra estado_pago='paid')."
  fi

  # R3 — productos via venta_items → variantes → productos
  # Mismo criterio que R2: gatillos ('venta_items' + 'productos') sobre $ADDED,
  # complemento ('variantes') sobre el archivo completo.
  if printf '%s' "$ADDED" | grep -qiE 'venta_items' && printf '%s' "$ADDED" | grep -qiE '\bproductos\b' && ! grep -qiE 'variantes' "$f"; then
    fail "$f — join venta_items↔productos sin 'variantes'. Camino: venta_items → variantes → productos."
  fi

  # R4 — migraciones: reversa documentada (aviso, no bloqueo).
  # Mismo criterio gatillo-en-añadidas (create/alter/add sobre $ADDED) para no
  # avisar por una migración preexistente que el PR apenas roza; complemento
  # (down/rollback/...) sobre el archivo completo.
  case "$f" in
    supabase/migrations/*.sql)
      if printf '%s' "$ADDED" | grep -qiE '\b(create|alter|add)\b' && ! grep -qiE 'down|rollback|drop|revert' "$f"; then
        warn "$f — migración sin reversa documentada. Incluye el rollback o documéntalo."
      fi ;;
  esac
done

echo "---"
echo "data-rules: ${FAILS} fail / ${WARNS} warn (archivos: ${#FILES[@]})"
[ "$FAILS" -gt 0 ] && exit 1
exit 0
