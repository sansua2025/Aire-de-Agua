# Sensor · Meta Pixel Purchase `value=0`

> Última actualización: 2026-06-09
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

## Evidencia (2026-06)

- 6550 / 6737 filas históricas con `valor_compras` en `0`/`null`.
- 84 / 87 filas en los últimos 14 días aún en `0` (última fecha `2026-06-08`).
- Bug vigente al momento de documentar.

## Salvaguarda en producción

La fuente de verdad de revenue/ROAS de pauta **no** es `meta_ads_performance.valor_compras`
(pixel roto), sino la vista `v_meta_ads_roas_real.roas_real`, derivada del revenue real de
Shopify. El Loop Weekly ya opera sobre `roas_real`.

**Regla:** ningún consumidor debe usar `valor_compras` como revenue mientras el pixel esté en 0.

## Acciones manuales (fundador, fuera del repo)

1. Shopify → canal Facebook/IG: pixel `1030747298351597` en modo **Optimized** + **CAPI
   habilitado**, sin GTM Server-Side reconectado.
2. Meta Events Manager: compra de prueba → confirmar `Purchase` con `value > 0` y
   `currency=COP`, sin duplicados pixel/CAPI.

## Riesgo a vigilar

Si se reconecta GTM Server-Side CAPI **sin deduplicación por `event_id`**, reaparece el
doble conteo de conversiones/valor.

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

Los criterios de aceptación restantes son acciones manuales del fundador en Shopify/Meta.
El flujo de agentes solo aporta esta documentación y la query de monitoreo.
