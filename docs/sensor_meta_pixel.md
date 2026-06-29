# Sensor · Meta Pixel Purchase `value=0`

> Última actualización: 2026-06-16
> Linear: [AIR-71](https://linear.app/airedeagua/issue/AIR-71) — Sensor · Fix Meta pixel value=0

## Síntoma

El evento `Purchase` del pixel de Meta reporta `value=0`. En consecuencia, la columna
`meta_ads_performance.valor_compras` llega en `0`/`null` para las filas afectadas.

## Root cause

El payload del Purchase **no se construye en nuestro stack** (n8n / Supabase / dashboard).
Vive en dos lugares fuera del repo:

1. El **pixel del canal Facebook/Instagram de Shopify**.
2. **GTM Server-Side CAPI** (container `GTM-NNXL7BTQ`).

Ambos entraban en conflicto al enviar el evento `Purchase`, dejando el `value` en 0.
GTM Server-Side ya fue **desconectado**. El fix definitivo es una corrección manual en
Shopify/Meta Business, no de código.

## Evidencia

### Estado histórico (superado — al 2026-06-08)

- 6550 / 6737 filas históricas con `valor_compras` en `0`/`null`.
- 84 / 87 filas en los últimos 14 días aún en `0` (última fecha `2026-06-08`).
- Bug vigente al momento de esa medición. **Esta evidencia está OBSOLETA**: refleja el
  estado previo al fix manual, no el estado actual.

### Estado actual (verificado vía MCP, 2026-06-13)

- **`valor_compras` recuperado.** En `meta_ads_performance`, en los últimos 30 días
  `compras_sin_valor = 0` en TODAS las fechas: cada fila con `compras > 0` trae
  `valor_compras > 0`. Ejemplos: `2026-06-12 = 207.000 COP`, `2026-06-05 = 142.000 COP`.
- **Señal del pixel sana.** `ads_get_dataset_quality` sobre el pixel `1030747298351597`:
  evento `Purchase` con EMQ composite **9.3** y cobertura 100% en todas las match-keys
  (email, phone, fbc, ct, st, zip, country).
- **Matiz honesto (no sobre-interpretar la EMQ):** la EMQ confirma calidad de *match*
  (capacidad de atribuir el evento a una persona), **no** valida el valor del campo `value`
  per se. Además, `meta_ads_performance.valor_compras` proviene de la Insights API
  (revenue atribuido), **no** es lectura directa del campo `value` del evento crudo. Por eso
  el criterio de Events Manager (`value > 0` + `currency = COP` en el evento crudo) **requirió
  confirmación humana**, que quedó realizada al 2026-06-16 (ver Acciones manuales y Estado del
  issue).

## Salvaguarda en producción

La fuente de verdad de revenue/ROAS de pauta **no** es `meta_ads_performance.valor_compras`,
sino la vista `v_meta_ads_roas_real.roas_real`, derivada del revenue real de Shopify. El Loop
Weekly ya opera sobre `roas_real`.

**Regla (permanente):** ningún consumidor debe usar `valor_compras` como revenue. El motivo
**ya no es el pixel** — el bug `value=0` quedó resuelto (ver AIR-71). Es la **cobertura de
atribución**: `valor_compras` solo refleja conversiones que Meta atribuye a la pauta, y ~75%
de las ventas son POS sin atribución. Aunque el pixel esté sano, `valor_compras` subcuenta el
revenue de forma sistemática. `roas_real` cruza el gasto contra el revenue real de Shopify y
no arrastra ese sesgo.

## Acciones manuales (fundador, fuera del repo — ejecutadas al 2026-06-16)

Quedaron aplicadas y confirmadas; se conservan como registro de la configuración que sostiene el fix:

1. Shopify → canal Facebook/IG: pixel `1030747298351597` en modo **Optimized** + **CAPI
   habilitado**, sin GTM Server-Side reconectado.
2. Meta Events Manager: compra de prueba → confirmado `Purchase` con `value > 0` y
   `currency=COP`, sin duplicados pixel/CAPI.

## Riesgo a vigilar

Si se reconecta GTM Server-Side CAPI **sin deduplicación por `event_id`**, reaparece el
doble conteo de conversiones/valor. Mantener GTM Server-Side desconectado (o con dedup por
`event_id` verificada) es la condición que sostiene el fix.

## Query de monitoreo

Correr unos días después de aplicar el fix manual. Reemplazar `<FECHA_DEL_FIX>` por la fecha
en que se aplicó el fix en Shopify/Meta.

```sql
SELECT count(*) FILTER (WHERE valor_compras > 0)                  AS con_valor,
       count(*) FILTER (WHERE compras > 0 AND valor_compras = 0)  AS compras_sin_valor
FROM meta_ads_performance
WHERE fecha > '<FECHA_DEL_FIX>' AND compras > 0;
-- Éxito: con_valor > 0 y compras_sin_valor ~ 0.
```

## Estado del issue

**RESUELTO y cerrado (verificado 2026-06-16).** El bug `value=0` quedó corregido:
`valor_compras` llega correcto desde mayo 2026 y la señal del pixel está sana (EMQ 9.3,
cobertura 100%, `compras_sin_valor = 0`). Con esto, **AIR-71 cierra también AIR-65 y AIR-72**.

> Histórico: el cierre estuvo pendiente de confirmación humana en Meta Events Manager (compra
> de prueba con `value > 0` + `currency = COP` en el evento crudo) y de verificar la
> deduplicación por `event_id`. Ambos pasos quedaron confirmados al 2026-06-16.

Nota para consumidores de datos: que el pixel esté sano **no** cambia la regla de la sección
"Salvaguarda en producción" — el revenue de pauta se sigue tomando de `roas_real`, ahora por
cobertura de atribución (POS ~75% sin atribución), no por el pixel.
