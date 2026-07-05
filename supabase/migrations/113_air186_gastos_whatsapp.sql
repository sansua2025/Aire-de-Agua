-- AIR-186 (Épica app de gastos AIR-164) · Canal WhatsApp de gastos.
-- Spec: AIR-186. Base: mig 106 (schema + RPCs gobernadas), 108 (autor/editor),
--   109 (precision_fecha + última recreación de v_gastos_detalle).
-- Fecha: 2026-07-04
--
-- PROPÓSITO
--   Habilitar el registro de gastos vía WhatsApp (Twilio). Añade la infraestructura
--   de datos del canal conversacional, sin tocar el flujo de la app web:
--     - Allowlist de remitentes autorizados (quién puede registrar y con qué pagador).
--     - Estado conversacional por teléfono (borrador pendiente de confirmación).
--     - Ledger de dedupe de mensajes entrantes (Twilio reintenta el webhook).
--   Además marca el ORIGEN de cada gasto ('app' | 'whatsapp') e idempotiza la
--   escritura por message_sid de Twilio para que un reintento no duplique el gasto.
--
-- SEGURIDAD
--   - RLS habilitado en las 3 tablas nuevas, sin policies (deny-by-default).
--   - REVOKE de anon/authenticated (las default privileges de la casa granteán a anon).
--   - El acceso lo hace el server (route handler / workflow n8n) con service_role.
--
-- Idempotente: re-ejecutable sin error (create table if not exists / add column if
--   not exists / or replace). Rollback documentado al final del archivo.

-- ============================================================================
-- 1 · Tablas del canal WhatsApp (allowlist / estado / ledger de dedupe)
-- ============================================================================

-- Allowlist: solo estos teléfonos pueden registrar gastos por WhatsApp.
create table if not exists gastos_wa_usuarios (
  telefono        text primary key,           -- formato Twilio: 'whatsapp:+57...'
  email           text not null,              -- se usa como creado_por del gasto
  nombre          text,
  pagador_default text not null references gasto_pagadores(id),
  activo          boolean not null default true
);

comment on table gastos_wa_usuarios is
  'Allowlist del canal WhatsApp de gastos (AIR-186): remitentes autorizados. '
  'Un teléfono no presente/activo aquí no puede registrar gastos por WhatsApp.';
comment on column gastos_wa_usuarios.telefono is
  'Identificador Twilio del remitente (formato ''whatsapp:+57...''). PK del canal.';
comment on column gastos_wa_usuarios.email is
  'Email del usuario; se propaga como gastos.creado_por (autor del gasto).';
comment on column gastos_wa_usuarios.pagador_default is
  'Pagador por defecto de este remitente (FK gasto_pagadores). Puede variar por gasto.';
comment on column gastos_wa_usuarios.activo is
  'Interruptor de allowlist: false deshabilita al remitente sin borrar su historial.';

-- Estado conversacional: un borrador de gasto pendiente de confirmar por teléfono.
create table if not exists gastos_wa_sesiones (
  telefono           text primary key references gastos_wa_usuarios(telefono),
  estado             text not null default 'idle' check (estado in ('idle','pendiente_confirmacion')),
  gasto_pendiente    jsonb,
  ultimo_gasto_id    uuid references gastos(id) on delete set null,
  ultimo_message_sid text,
  expira_at          timestamptz,
  updated_at         timestamptz not null default now()
);

comment on table gastos_wa_sesiones is
  'Estado conversacional del canal WhatsApp (AIR-186): borrador pendiente de '
  'confirmación por teléfono. Máquina de estados idle → pendiente_confirmacion.';
comment on column gastos_wa_sesiones.estado is
  'Estado de la conversación: ''idle'' (sin borrador) o ''pendiente_confirmacion''.';
comment on column gastos_wa_sesiones.gasto_pendiente is
  'Borrador del gasto (payload parseado del mensaje) a la espera de confirmación.';
comment on column gastos_wa_sesiones.ultimo_gasto_id is
  'Último gasto confirmado por este teléfono (FK gastos; set null si se borra).';
comment on column gastos_wa_sesiones.ultimo_message_sid is
  'message_sid del último mensaje procesado en esta sesión (traza/undo).';
comment on column gastos_wa_sesiones.expira_at is
  'Momento de expiración del borrador pendiente; pasado este instante se descarta.';

-- Ledger de dedupe: Twilio reintenta el webhook; registrar cada message_sid una vez.
create table if not exists gastos_wa_mensajes (
  message_sid text primary key,
  telefono    text not null,
  recibido_at timestamptz not null default now(),
  resultado   jsonb
);

comment on table gastos_wa_mensajes is
  'Ledger de dedupe de mensajes entrantes de Twilio (AIR-186): Twilio reintenta el '
  'webhook; el message_sid como PK garantiza procesar cada mensaje una sola vez.';
comment on column gastos_wa_mensajes.message_sid is
  'SID único del mensaje Twilio. PK: bloquea el reprocesado de reintentos.';
comment on column gastos_wa_mensajes.telefono is
  'Teléfono remitente del mensaje (formato Twilio ''whatsapp:+57...'').';
comment on column gastos_wa_mensajes.resultado is
  'Resultado del procesamiento (p.ej. gasto_id creado, error) para auditoría.';

-- RLS deny-by-default + REVOKE (patrón de la casa: default privileges granteán a anon).
alter table gastos_wa_usuarios enable row level security;
alter table gastos_wa_sesiones enable row level security;
alter table gastos_wa_mensajes enable row level security;

revoke all on gastos_wa_usuarios from anon, authenticated;
revoke all on gastos_wa_sesiones from anon, authenticated;
revoke all on gastos_wa_mensajes from anon, authenticated;

-- ============================================================================
-- 2 · Columnas nuevas en gastos (aditivas): origen + wa_message_sid
-- ============================================================================

-- origen: canal por el que entró el gasto. Default 'app' preserva las filas previas.
alter table gastos add column if not exists origen text not null default 'app';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'gastos_origen_check'
  ) then
    alter table gastos
      add constraint gastos_origen_check check (origen in ('app','whatsapp'));
  end if;
end $$;

comment on column gastos.origen is
  'Canal de captura del gasto: ''app'' (default, app web) o ''whatsapp'' (AIR-186).';

-- wa_message_sid: message_sid de Twilio que originó el gasto (idempotencia del canal).
alter table gastos add column if not exists wa_message_sid text;

-- Índice único parcial: un message_sid → a lo sumo un gasto. NULL no colisiona.
do $$
begin
  if not exists (
    select 1 from pg_class where relname = 'gastos_wa_message_sid_uidx'
  ) then
    create unique index gastos_wa_message_sid_uidx
      on gastos (wa_message_sid) where wa_message_sid is not null;
  end if;
end $$;

comment on column gastos.wa_message_sid is
  'message_sid de Twilio que originó el gasto por WhatsApp (AIR-186). Único (parcial). '
  'Sirve de clave de idempotencia: un reintento del webhook no duplica el gasto.';

-- ============================================================================
-- 3 · Escritura gobernada: gastos_guardar (idempotencia por wa_message_sid + origen)
--   PARTE de la definición vigente en PROD (idéntica byte a byte salvo los cambios
--   marcados con AIR-186). NO se toca nada más.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gastos_guardar(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_id           uuid    := nullif(p->>'id', '')::uuid;
  v_concepto     text    := btrim(coalesce(p->>'concepto', ''));
  v_categoria_id text    := p->>'categoria_id';
  v_monto        numeric := nullif(p->>'monto', '')::numeric;
  v_fecha        date    := nullif(p->>'fecha', '')::date;
  v_pagador_id   text    := p->>'pagador_id';
  v_recibo_path  text    := p->>'recibo_path';
  v_creado_por   text    := nullif(btrim(coalesce(p->>'creado_por', '')), '');
  -- AIR-186: canal de origen (default 'app') e idempotencia por message_sid de Twilio.
  v_origen         text  := coalesce(nullif(p->>'origen', ''), 'app');
  v_wa_message_sid text  := nullif(p->>'wa_message_sid', '');
  v_row          gastos%rowtype;
begin
  -- Validaciones comunes (mensajes claros; el route handler los mapea a 400).
  if v_concepto = '' then
    raise exception 'concepto vacío';
  end if;
  if v_monto is null or v_monto <= 0 then
    raise exception 'monto debe ser > 0 (recibido: %)', coalesce(p->>'monto', 'null');
  end if;
  if v_fecha is null then
    raise exception 'fecha es obligatoria';
  end if;
  if v_categoria_id is null or not exists (select 1 from gasto_categorias where id = v_categoria_id) then
    raise exception 'categoría inexistente: %', coalesce(v_categoria_id, 'null');
  end if;
  if not exists (select 1 from gasto_categorias where id = v_categoria_id and activa) then
    raise exception 'categoría inactiva: %', v_categoria_id;
  end if;
  if v_pagador_id is null or not exists (select 1 from gasto_pagadores where id = v_pagador_id) then
    raise exception 'pagador inexistente: %', coalesce(v_pagador_id, 'null');
  end if;
  if not exists (select 1 from gasto_pagadores where id = v_pagador_id and activo) then
    raise exception 'pagador inactivo: %', v_pagador_id;
  end if;
  -- AIR-186: el canal de origen debe ser uno de los soportados.
  if v_origen not in ('app','whatsapp') then
    raise exception 'origen inválido: %', v_origen;
  end if;

  if v_id is null then
    -- AIR-186: idempotencia del canal WhatsApp. Si el message_sid ya produjo un gasto,
    -- NO se revalida ni se re-inserta: se devuelve el existente marcado como duplicado.
    if v_wa_message_sid is not null then
      select * into v_row from gastos where wa_message_sid = v_wa_message_sid;
      if found then
        return to_jsonb(v_row) || jsonb_build_object('duplicado', true);
      end if;
    end if;
    -- INSERT. creado_por fija al autor original; editado_por queda null (nunca editado).
    if v_creado_por is null then
      raise exception 'creado_por es obligatorio';
    end if;
    -- AIR-186: se persisten origen y wa_message_sid (inmutables tras el insert).
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id, recibo_path, creado_por, origen, wa_message_sid)
    values (v_concepto, v_categoria_id, v_monto, v_fecha, v_pagador_id, v_recibo_path, v_creado_por, v_origen, v_wa_message_sid)
    returning * into v_row;
  else
    -- UPDATE. recibo_path: si la clave viene en el payload se aplica (incluye null
    -- para limpiar); si NO viene, se preserva el valor actual (patrón merge de la casa).
    -- creado_por es INMUTABLE (AIR-174): NO se toca aquí. La clave `creado_por` del
    -- payload actúa como ACTOR de la edición → se registra en editado_por (último editor).
    -- AIR-186: origen y wa_message_sid son INMUTABLES tras el insert → NO se tocan.
    update gastos set
      concepto     = v_concepto,
      categoria_id = v_categoria_id,
      monto        = v_monto,
      fecha        = v_fecha,
      pagador_id   = v_pagador_id,
      recibo_path  = case when p ? 'recibo_path' then v_recibo_path else recibo_path end,
      editado_por  = coalesce(v_creado_por, editado_por),
      updated_at   = now()
    where id = v_id
    returning * into v_row;
    if not found then
      raise exception 'gasto inexistente: %', v_id;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$function$;

-- ============================================================================
-- 4 · Lectura: v_gastos_detalle con origen + wa_message_sid al final
--   Copia EXACTA de la mig 109 (última que la recrea) + las 2 columnas nuevas
--   AL FINAL (create or replace view no permite reordenar/renombrar columnas).
-- ============================================================================

create or replace view v_gastos_detalle
with (security_invoker = true) as
select
  g.id,
  g.concepto,
  g.categoria_id,
  cat.nombre  as categoria_nombre,
  cat.tipo    as tipo,
  g.monto,
  g.fecha,
  g.pagador_id,
  pag.nombre  as pagador_nombre,
  g.recibo_path,
  g.creado_por,
  g.created_at,
  g.updated_at,
  g.firestore_id,
  g.editado_por,
  g.precision_fecha,
  g.origen,
  g.wa_message_sid
from gastos g
join gasto_categorias cat on cat.id = g.categoria_id
join gasto_pagadores  pag on pag.id = g.pagador_id;

-- Grants (create or replace PRESERVA grants; explícito por claridad — como en 108/109).
revoke all on v_gastos_detalle from anon, authenticated;
grant select on v_gastos_detalle to service_role;

revoke all on function gastos_guardar(jsonb) from public, anon, authenticated;
grant execute on function gastos_guardar(jsonb) to service_role;

-- ============================================================================
-- 5 · SEED de allowlist — pendiente de datos humanos (AIR-187).
--   Los teléfonos reales los provee Santiago. Descomentar y completar:
-- ============================================================================
-- insert into gastos_wa_usuarios (telefono, email, nombre, pagador_default) values
--   ('whatsapp:+57XXXXXXXXXX', 'ssuarez.mesa@gmail.com', 'Santiago', 'aire_de_agua'),
--   ('whatsapp:+57XXXXXXXXXX', 'EMAIL_SUSI', 'Susi', 'aire_de_agua')
-- on conflict (telefono) do nothing;

-- ============================================================================
-- Rollback (down) — revertir esta migración:
--
--   -- 1. Restaurar gastos_guardar y v_gastos_detalle SIN los cambios AIR-186:
--   --    re-ejecutar la migración 109 (recrea la vista) y la 108 (recrea la RPC),
--   --    en ese orden inverso (108 luego 109), para volver a la definición previa.
--   -- 2. Quitar columnas nuevas de gastos:
--   drop index if exists gastos_wa_message_sid_uidx;
--   alter table gastos drop constraint if exists gastos_origen_check;
--   alter table gastos drop column if exists wa_message_sid;
--   alter table gastos drop column if exists origen;
--   -- 3. Quitar tablas del canal (orden por FKs: mensajes/sesiones antes que usuarios):
--   drop table if exists gastos_wa_mensajes;
--   drop table if exists gastos_wa_sesiones;
--   drop table if exists gastos_wa_usuarios;
-- ============================================================================
