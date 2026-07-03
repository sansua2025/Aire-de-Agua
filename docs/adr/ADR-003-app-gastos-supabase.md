# ADR-003 · App de Gastos — gastos.airedeagua.com

**Estado:** Propuesto · 2026-07-02
**Decisores:** Santiago Suárez
**Referencias:** Figma https://www.figma.com/design/tZf2DRA3AfUoIVNet1uIsn · Épica Linear (ver issues hijos)

---

## Contexto

Los egresos de Aire de Agua se capturan hoy en una app externa (Replit + Firebase Auth + Firestore) con export a BigQuery (`adea-d2c-analytics.firebase_expense.app_expenses`). Estado verificado al 2026-07-02:

- **293 filas** en BigQuery · **$194.5M COP** · rango 2024-12-02 → 2026-07-01
- La UI de la app reporta **286 gastos · $191.938.811** — descuadre de 7 registros sin explicar
- Schema actual: `amount FLOAT` (aritmética inexacta para dinero), `category` y `expenseType` desnormalizados por fila, `userId` constante `"1"`

Problemas: (1) **silo** — los costos operativos viven fuera de Supabase, donde están ventas, COGS unitario y Meta Ads; imposibilita P&L/margen real sin pipelines de sync (bloquea la visión de AIR-65). (2) **Costo** — Replit es un hosting pagado redundante con Vercel. (3) **Calidad** — FLOAT para plata, sin editar/eliminar, sin comprobantes.

## Decisión

Reconstruir la app **dentro del monorepo** `sansua2025/Aire-de-Agua` y **dentro de la Supabase existente** (`vnctmzsgemefgbtjctlo`), servida como `gastos.airedeagua.com` desde el mismo proyecto Vercel del dashboard. Se descartó repo/proyecto aparte: recrearía el silo y duplicaría la maquinaria de agentes (merge-gate, guards, drift detectors) que solo está cableada a este repo.

### D1 · Datos: 3 tablas, jerarquía tipo→categoría como config

```sql
create table gasto_categorias (
  id      text primary key,          -- 'feria', 'gastos_fijos', ...
  tipo    text not null,             -- 'Marketing','Operations','Technology','Shipping','COGS','Assets'
  nombre  text not null,
  activa  boolean not null default true,
  orden   int not null default 0
);

create table gasto_pagadores (
  id      text primary key,          -- 'aire_de_agua', 'santi_susi'
  nombre  text not null,
  activo  boolean not null default true
);

create table gastos (
  id            uuid primary key default gen_random_uuid(),
  concepto      text not null,
  categoria_id  text not null references gasto_categorias(id),
  monto         numeric(14,2) not null check (monto > 0),
  fecha         date not null,
  pagador_id    text not null references gasto_pagadores(id),
  recibo_path   text,                          -- Storage, bucket privado 'recibos'
  creado_por    text not null,                 -- email de la sesión Auth.js
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  firestore_id  text unique                    -- idempotencia del backfill
);
```

Racionales:
- **`numeric`, no `float`**: aritmética exacta para dinero. La UI captura enteros COP (sin centavos); `(14,2)` deja margen.
- **Tipo derivado por JOIN, no columna en `gastos`**: la jerarquía vive una sola vez en config. La UI actual ya la trata como dependiente ("Selecciona primero un tipo").
- **Config-as-data**: retirar una categoría del formulario = `update ... set activa=false`, sin redeploy. Mismo patrón que `brand_knowledge`.
- **`fecha date`** (no timestamptz): el gasto es un hecho de día contable en Bogotá; evita la clase de bugs de timezone ya documentada en el Cerebro.

Seed de `gasto_categorias` (mapeo real verificado contra BQ, las sumas cuadran al peso):

| tipo | categorías |
|---|---|
| Operations | Gastos Fijos, Operations |
| Marketing | Feria, Publicidad, Fotos, Otros |
| Technology | Shopify, Replit, Pixlr, Marketing Automation |
| Shipping | Shipping |
| COGS | COGS |
| Assets | Assets |

Nota semántica: `gastos.categoria='COGS'` es **caja** (pagos a proveedores); `cogs_variantes_shopify` es **devengado** (costo unitario por venta). Conceptos distintos que no deben sumarse entre sí. Cualquier RPC de P&L debe elegir uno explícitamente.

### D2 · Auth: reutilizar Auth.js v5 (Google OAuth + allowlist)

El dashboard ya autentica con Google OAuth y allowlist por email (`dashboard/auth.ts`, `ALLOWED_EMAILS`). La app de gastos usa la **misma sesión**: se agrega el email de Susi al allowlist. No se introduce Supabase Auth (evita segundo sistema de identidad). `creado_por` guarda el email de la sesión.

### D3 · Acceso a datos: escrituras por RPC gobernada, lecturas por vista

Consistente con el patrón de la casa (reglas en SQL/RPCs, `SECURITY DEFINER`, rol lector sin acceso directo a tablas):
- **Escritura:** `gastos_guardar(jsonb) returns jsonb` (insert/update por presencia de `id`; valida categoría activa, pagador, monto>0) y `gastos_eliminar(uuid)`. `SECURITY DEFINER`, ejecutadas desde route handlers del server (la key nunca llega al browser — patrón AIR-58).
- **Lectura:** vista `v_gastos_detalle` (gastos ⋈ categorías con tipo resuelto) + RPC `gastos_resumen(p_desde date, p_hasta date)` para los agregados del tab Resumen (por categoría, por tipo, por pagador, serie mensual). El front no calcula métricas: las lee.

### D4 · Recibos: Storage privado

Bucket `recibos` **privado** (el repo es público; los comprobantes son información financiera). Upload y lectura vía route handlers con signed URLs de corta vida. `gastos.recibo_path` guarda la ruta.

### D5 · Frontend y dominio

- Route group `dashboard/app/(gastos)` con **shell/estética propia** (diseño Figma aprobado: monto-primero con numpad, chips tipo→categoría, historial con swipe, resumen con barras). Íconos `lucide-react` (mapeo 1:1 con el Figma).
- `gastos.airedeagua.com` se agrega como dominio del mismo proyecto Vercel; el middleware existente hace rewrite por hostname hacia `/(gastos)` y aplica la misma protección de sesión.
- Formato monetario `es-CO`, enteros, separador de miles en vivo.

### D6 · Migración de datos y corte

1. Backfill de las 293 filas de BQ → `gastos` vía script one-off (idempotente por `firestore_id`). **Los datos NO se comitean al repo** (repo público): el script lee un export local/efímero.
2. **Reconciliación obligatoria antes del corte:** explicar el descuadre 293 (BQ) vs 286 ($191.938.811, app). Hipótesis: registros borrados en Firestore que persisten en el export a BQ. Si se confirma, excluirlos del backfill y documentar los `firestore_id` excluidos en el issue.
3. Validación: `count` y `sum(monto)` por categoría idénticos entre origen depurado y `gastos`.
4. Corte: apagar Replit, eliminar el proyecto Firebase, archivar el dataset BQ (export CSV final como respaldo frío, fuera del repo).

## Consecuencias

**Positivas:** una sola fuente de verdad de egresos junto a ventas/COGS/Ads → habilita P&L y margen real (insumo para AIR-65); −1 hosting pagado, −2 sistemas (Firebase, BQ-export); editar/eliminar y comprobantes, capacidades hoy inexistentes; el Cerebro puede exponer `gastos_resumen` como tool MCP más adelante.

**Negativas / riesgos:** migración con descuadre conocido que exige reconciliación manual; primer flujo de **escritura de usuario** sobre la Supabase de producción (hasta hoy los writes son de pipelines) — mitigado por RPCs gobernadas y validaciones en SQL; el subdominio comparte proyecto Vercel: un deploy roto afecta dashboard y gastos a la vez (aceptado: mismo blast radius que ya existe entre secciones del dashboard).

**Fuera de alcance (explícito):** presupuestos/forecast de gasto, multi-moneda, aprobaciones de gasto, OCR de recibos. Se registran como ideas, no como requisitos.
