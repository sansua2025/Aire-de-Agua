# E5-E · Dashboard Looker Studio — guía de setup

> Linear: [AIR-55](https://linear.app/airedeagua/issue/AIR-55)
> Última actualización: 2026-04-30

## Por qué Looker Studio

- 0-code, comparte por link, refresh automático.
- Exportable a PDF para reporte ejecutivo mensual.
- Las 5 vistas `analytics.view_dashboard_*` ya están listas y excluyen PII.
- Custom Next.js es overkill para Fase 1.

## Pre-requisitos (1 vez)

### 1. Activar el rol `dashboard_reader` con password

El rol fue creado por la migración 022 en estado `NOLOGIN`. Para que Looker pueda conectarse, necesita LOGIN + password. **No lo guardamos en git** por seguridad.

En el **SQL Editor de Supabase** correr (1 vez, password generado fuera de banda):

```sql
ALTER ROLE dashboard_reader LOGIN PASSWORD '<password seguro>';
```

Anotar el password en un gestor de contraseñas (1Password, Bitwarden). Looker lo necesita una sola vez al configurar la conexión.

### 2. Verificar permisos del rol

Las migraciones 022 y 029 ya otorgan SELECT en las 5 vistas. Verificar:

```sql
SELECT
  table_name,
  has_table_privilege('dashboard_reader', 'analytics.' || table_name, 'SELECT') AS puede_leer
FROM information_schema.views
WHERE table_schema = 'analytics' AND table_name LIKE 'view_dashboard_%';
```

Las 5 deben retornar `puede_leer = true`. Si alguna es `false`:

```sql
GRANT SELECT ON analytics.view_dashboard_<nombre> TO dashboard_reader;
```

### 3. Exponer schema `analytics` a PostgREST (opcional)

Si querés que Looker use la **conexión PostgreSQL** directa (recomendado), no necesitás esto.
Si querés usar el **REST API** de Supabase, hay que ir a `Project Settings > API > Exposed schemas` y agregar `analytics`.

Recomiendo **conexión Postgres directa** porque Looker la maneja nativamente.

## Setup en Looker Studio

### 1. Crear nueva fuente de datos

1. Ir a [lookerstudio.google.com](https://lookerstudio.google.com)
2. **Create > Data source**
3. Elegir **PostgreSQL**
4. Configurar conexión:
   - **Host:** `db.vnctmzsgemefgbtjctlo.supabase.co`
   - **Port:** `5432`
   - **Database:** `postgres`
   - **Username:** `dashboard_reader`
   - **Password:** el seteado en el paso 1
   - **SSL:** Enable
5. **Custom Query** y pegar:
   ```sql
   SELECT * FROM analytics.view_dashboard_weekly_kpi
   ```
6. Repetir para cada una de las 5 vistas (crear 5 fuentes de datos):
   - `analytics.view_dashboard_weekly_kpi`
   - `analytics.view_dashboard_funnel`
   - `analytics.view_dashboard_paid`
   - `analytics.view_dashboard_insights_activos`
   - `analytics.view_dashboard_anomalias`

### 2. Crear el reporte (5 páginas)

**Create > Report**, agregar las 5 fuentes.

### Página 1 — Resumen Ejecutivo
Fuente: `view_dashboard_weekly_kpi`

Layout:
- 6 **Scorecards** (KPI tiles) con comparison metric:
  - `ventas_total` (primary) + `delta_ventas_pct` (comparison)
  - `roas_meta` + `delta_roas_pct`
  - `cvr_web` (formato %) + `delta_cvr_pct`
  - `aov` (moneda COP) + `delta_aov_pct`
  - `sesiones` (sin delta)
  - `ordenes_total` (sin delta)
- Color condicional en deltas: rojo si `<-10%`, verde si `>+10%`
- **Text block** abajo mostrando `resumen_ai` de la última semana
- **Time series chart** (últimas 8 semanas) con `ventas_total` y `gasto_meta` overlay

### Página 2 — Funnel Web
Fuente: `view_dashboard_funnel`

- **Bar chart**: sesiones → vistas_producto → agrega_carrito → inicia_checkout → compras (datos sumados últimos 30d)
- **Time series**: cvr_total últimos 30 días, día por día
- **Scorecard**: tasa_rebote promedio últimos 7d

### Página 3 — Performance Paid
Fuente: `view_dashboard_paid`

- **Tabla** por campaña: `campaign_name | gasto | roas | cpa | ctr_pct | num_ads`
- Sort por `gasto` desc
- **Heatmap** de ROAS por día/campaña (si hay data densidad)
- **Scorecard**: gasto total últimos 30d, ROAS promedio ponderado

### Página 4 — Email (placeholder)
Hasta que Klaviyo esté ingresando datos, esta página puede mostrar:
- **Text block**: "Datos email pendientes — workflow E3E - Klaviyo Daily Sync no activo aún. AIR-7 trackea progreso."

Cuando Klaviyo esté activo, agregar fuente de datos sobre `klaviyo_campaigns` o crear `analytics.view_dashboard_email`.

### Página 5 — Inteligencia AI
Fuentes: `view_dashboard_insights_activos` + `view_dashboard_anomalias`

Layout 2 columnas:

**Columna izquierda (insights):**
- **Tabla** con: `dominio | tipo | titulo | accion_sugerida | score_confianza | veces_confirmado`
- Filtro por dominio (dropdown)
- Sort por `score_confianza` desc

**Columna derecha (anomalías):**
- **Tabla** últimos 30 días: `metrica_clave | valor_observado | delta_pct | titulo`
- Sort por `ABS(delta_pct)` desc

**Footer de página:**
- Text block con `weekly_snapshot.resumen_ai` última corrida (link a fuente)

## Compartir y refresh

### Refresh
Por defecto Looker Studio cachea 12 horas. Para datos T-1 está bien.
Para acelerar: **Resource > Manage data freshness > Set custom refresh frequency** = 1 hora.

### Compartir
**Share button > Get link > Anyone with link can view**.
Stakeholders no necesitan cuenta de Looker.

### Exportar a PDF mensual
**File > Download > PDF**. Útil para reporte mensual a stakeholders.

## Auditoría de PII

Antes de compartir, **verificar visualmente cada página**:
- ❌ NO debe aparecer `cliente_email`, `telefono`, `direccion`, `nombre completo`
- ✅ Sí pueden aparecer: cantidades, IDs internos (uuid), fechas, métricas agregadas, segmentos

Si alguna vista expone PII por error, modificar la migración 029 y hacer `CREATE OR REPLACE VIEW` para excluir el campo.

## Troubleshooting

| Error | Causa | Fix |
|---|---|---|
| "permission denied for schema analytics" | El rol no tiene USAGE | `GRANT USAGE ON SCHEMA analytics TO dashboard_reader;` |
| "permission denied for view_dashboard_*" | El rol no tiene SELECT | `GRANT SELECT ON analytics.view_dashboard_<x> TO dashboard_reader;` |
| Connection timeout | Firewall de Supabase o SSL mal configurado | Verificar SSL ON, IP en allowlist si Supabase lo requiere |
| Datos viejos (>12h) | Cache de Looker | Resource > Manage data freshness > Refresh now |
| KPI cards en NULL | Snapshot weekly no se llenó | Revisar `ai_analysis_log` últimos lunes; correr `compute_weekly_snapshot` manual |
