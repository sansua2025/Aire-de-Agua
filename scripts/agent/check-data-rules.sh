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
FILES=()
case "$MODE" in
  --file) FILES=("$@") ;;
  --diff)
    BASE="${1:?Uso: check-data-rules.sh --diff <base>}"
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done \
      < <(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD -- '*.sql' '*.ts' '*.tsx' 2>/dev/null)
    ;;
  *) echo "Uso: check-data-rules.sh --file <ruta>... | --diff <base>"; exit 2 ;;
esac

FAILS=0; WARNS=0
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
warn() { echo "WARN  $1"; WARNS=$((WARNS+1)); }

for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -f "$f" ] || continue
  case "$f" in *.sql|*.ts|*.tsx) ;; *) continue ;; esac
  # saltar tipos generados de Supabase: contienen nombres de columna
  # (valor_compras, ordered_at...) en definiciones de tipo, no en queries.
  case "$f" in */types/database.ts|*/database.types.ts) continue ;; esac

  # R1 — valor_compras es revenue de Meta (0 por bug de pixel)
  grep -qiE 'valor_compras' "$f" \
    && fail "$f — 'valor_compras' como revenue. Usa 'roas_real' / v_meta_ads_roas_real."

  # R2 — ventas siempre en hora de Bogotá (+ estado_pago='paid')
  if grep -qiE 'ordered_at' "$f" && ! grep -qiE 'America/Bogota' "$f"; then
    fail "$f — 'ordered_at' sin AT TIME ZONE 'America/Bogota' (y filtra estado_pago='paid')."
  fi

  # R3 — productos via venta_items → variantes → productos
  if grep -qiE 'venta_items' "$f" && grep -qiE '\bproductos\b' "$f" && ! grep -qiE 'variantes' "$f"; then
    fail "$f — join venta_items↔productos sin 'variantes'. Camino: venta_items → variantes → productos."
  fi

  # R4 — migraciones: reversa documentada (aviso, no bloqueo)
  case "$f" in
    supabase/migrations/*.sql)
      if grep -qiE '\b(create|alter|add)\b' "$f" && ! grep -qiE 'down|rollback|drop|revert' "$f"; then
        warn "$f — migración sin reversa documentada. Incluye el rollback o documéntalo."
      fi ;;
  esac

  # R5 — RPCs nuevos deben denegar acceso a anon (patrón AIR-61/AIR-69/AIR-91, ≥2 detecciones)
  # Si la migración define una función nueva, exigir REVOKE EXECUTE ... FROM anon (o PUBLIC).
  case "$f" in
    supabase/migrations/*.sql)
      if grep -qiE 'CREATE (OR REPLACE )?FUNCTION' "$f" && \
         ! grep -qiE 'REVOKE EXECUTE' "$f"; then
        warn "$f — RPC nuevo sin 'REVOKE EXECUTE ... FROM anon'. Añade REVOKE para evitar exposición vía PostgREST."
      fi ;;
  esac
done

echo "---"
echo "data-rules: ${FAILS} fail / ${WARNS} warn (archivos: ${#FILES[@]})"
[ "$FAILS" -gt 0 ] && exit 1
exit 0
