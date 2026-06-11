#!/usr/bin/env bash
# PostToolUse (Edit|Write) — "red squigglies": feedback en el momento del edit.
# Formatea (best-effort) y corre los chequeos deterministas de reglas de datos
# sobre el archivo editado; si encuentra algo, lo devuelve a Claude (exit 2).
# El typecheck pesado (tsc --noEmit) lo hace 'verify', no este hook, para no
# frenar cada edición.

set -uo pipefail
INPUT="$(cat)"
if command -v jq >/dev/null 2>&1; then
  FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
else
  FILE="$(printf '%s' "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
fi
[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

ISSUES=""
add() { ISSUES="${ISSUES}\n- $1"; }

# Formato best-effort (no falla)
case "$FILE" in
  *.ts|*.tsx|*.js|*.jsx|*.json)
    command -v npx >/dev/null 2>&1 && [ -f dashboard/package.json ] && (cd dashboard && npx --no-install prettier --write "$FILE" >/dev/null 2>&1) || true ;;
esac

# ESLint sobre el archivo editado (feedback inmediato; no-op si aún no está instalado)
case "$FILE" in
  *.ts|*.tsx)
    if command -v npx >/dev/null 2>&1 && [ -f dashboard/package.json ] && printf '%s' "$FILE" | grep -q '/dashboard/'; then
      OUT="$(cd dashboard && npx --no-install eslint "$FILE" 2>&1)"; rc=$?
      [ $rc -ne 0 ] && [ -n "$OUT" ] && add "ESLint:\n$(printf '%s' "$OUT" | head -20)"
    fi ;;
esac

# Reglas críticas de datos (determinista, barato)
case "$FILE" in
  *.sql|*.ts|*.tsx)
    grep -niE 'valor_compras' "$FILE" >/dev/null 2>&1 && add "Regla de datos: 'valor_compras' es revenue de Meta (0 por bug de pixel). Usa 'roas_real' / v_meta_ads_roas_real."
    if grep -niE 'ordered_at' "$FILE" >/dev/null 2>&1 && ! grep -qiE "America/Bogota" "$FILE"; then
      add "Regla de datos: 'ordered_at' sin AT TIME ZONE 'America/Bogota' (y filtra estado_pago='paid')."
    fi
    if grep -qiE 'venta_items' "$FILE" && grep -qiE '\bproductos\b' "$FILE" && ! grep -qiE 'variantes' "$FILE"; then
      add "Regla de datos: join venta_items↔productos sin 'variantes'. Camino correcto: venta_items → variantes → productos."
    fi ;;
esac

# Migración: avisa si no parece reversible
case "$FILE" in
  supabase/migrations/*.sql)
    grep -qiE '\b(create|alter|add)\b' "$FILE" 2>/dev/null && ! grep -qiE 'down|rollback|drop|revert' "$FILE" 2>/dev/null \
      && add "Migración: parece sin reversa. Considera incluir el rollback o documentarlo." ;;
esac

if [ -n "$ISSUES" ]; then
  printf 'Revisa antes de seguir (%s):' "$FILE" >&2
  printf '%b\n' "$ISSUES" >&2
  exit 2
fi
exit 0
