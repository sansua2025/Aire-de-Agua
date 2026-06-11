# Sensor · Validación HMAC-SHA256 Webhook Shopify

> Última actualización: 2026-06-11
> Linear: [AIR-88](https://linear.app/airedeagua/issue/AIR-88) — Seguridad: validar firma HMAC en webhook entrante de Shopify
> HITL: este runbook lo aplica Santiago con supervisión. No ejecutar de forma autónoma.

## Síntoma

El workflow `E2 - Webhook Shopify Products` (n8n id `pjJT4JKv27IE4aTx`) recibe eventos
`products/create` y `products/update` de Shopify y los escribe directamente en Supabase
(`productos`, `variantes`). Si la firma HMAC del webhook no se valida, cualquier atacante
con el URL del endpoint puede hacer un POST con datos arbitrarios e inyectar productos falsos.

## Root cause

El workflow usa el nodo nativo `shopifyTrigger` (typeVersion 1), que **valida HMAC
internamente de forma automática**, pero solo si la credencial "Shopify Admin API" en n8n
tiene el campo `Client Secret / Webhook Secret` completado. Si ese campo está vacío, la
validación no ocurre.

El fix principal es de **configuración de credencial**, no de código.

## Hallazgo clave

`shopifyTrigger` maneja la validación HMAC sin nodo adicional. El único requisito es que el
secret esté en la credencial. No es necesario reemplazar el nodo trigger por uno genérico
ni agregar un Code node de validación — eso sería la ruta de mayor riesgo (cambia el URL
del endpoint).

## Acciones HITL (Santiago, con supervisión)

### Paso 1 — Verificar la credencial en n8n

1. Abrir n8n UI → **Credentials** → buscar "Shopify Admin API".
2. Confirmar que el campo **Client Secret** (o "Webhook Secret", según la versión del nodo)
   está completado.
   - Si está vacío: continuar con el paso 2.
   - Si tiene valor: saltar al paso 4 (verificar que coincida con Shopify).

### Paso 2 — Obtener el secret desde Shopify (fuente de verdad)

1. Shopify Admin → **Settings → Notifications → Webhooks**.
2. Anotar el valor actual de **Webhook signature secret** antes de cambiar nada.
   Las credenciales de n8n no tienen rollback; el valor previo debe quedar registrado
   de forma segura fuera del repo (gestor de contraseñas o variable de entorno local).
3. Confirmar que el mismo valor está en la variable de entorno `SHOPIFY_WEBHOOK_SECRET`
   del entorno de n8n (si aplica).

### Paso 3 — Completar el secret en la credencial de n8n

1. En la credencial "Shopify Admin API", pegar el secret obtenido en el paso 2.
2. Guardar la credencial.
3. Confirmar que la credencial es la misma que usa el workflow E2 entrante (no crear
   una credencial duplicada).

> Nota: esta credencial puede ser compartida con el flujo saliente E2B. Configurar el
> secret no afecta las llamadas salientes a la API de Shopify, solo la validación HMAC
> entrante.

### Paso 4 — Prueba de rechazo con firma inválida

Desde terminal, enviar un POST con header de firma inválida al URL del webhook en n8n:

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "<URL_DEL_WEBHOOK_N8N>" \
  -H "Content-Type: application/json" \
  -H "X-Shopify-Hmac-Sha256: invalido==" \
  -d '{"id":99999,"title":"Producto inyectado","variants":[]}'
```

Resultado esperado: respuesta `4xx` o conexión cerrada. El workflow **no debe ejecutarse**
y el producto no debe aparecer en Supabase:

```sql
SELECT * FROM productos WHERE shopify_product_id = '99999';
-- Debe devolver 0 filas.
```

### Paso 5 — Prueba de aceptación con webhook real

1. Shopify Admin → **Settings → Notifications → Webhooks** → "Send test notification"
   para el evento `products/update`.
2. Verificar en n8n UI → **Executions** → el workflow E2 debe aparecer con estado
   `Success`.
3. Verificar en Supabase:

```sql
SELECT estado, created_at, detalle
FROM sync_log
WHERE workflow = 'E2_webhook_shopify_products'
ORDER BY created_at DESC
LIMIT 5;
-- Debe haber al menos un registro con estado = 'ok' posterior al fix.
```

### Paso 6 — Versionar el workflow E2 entrante

1. En n8n UI → workflow `E2 - Webhook Shopify Products` → **Download / Export JSON**.
2. **Antes de commitear**, verificar que el JSON exportado **no contiene el secret en
   texto plano** (buscar la cadena del secret en el archivo):
   ```bash
   grep -i "secret\|webhook_secret\|client_secret" n8n/workflows/E2_Webhook_Shopify_Products.json
   ```
   Si el secret aparece → no commitear el archivo hasta sanitizarlo o confirmar que el
   campo exportado está redactado por n8n.
3. Guardar el JSON en `n8n/workflows/E2_Webhook_Shopify_Products.json`.
   (Relacionado con AIR-89 — versionado de workflows.)

## Plan B — Solo si la credencial no expone campo de secret

Si la versión de la credencial "Shopify Admin API" instalada en este entorno de n8n no
expone el campo de secret, la alternativa es reemplazar `shopifyTrigger` por un nodo
`Webhook` genérico con Raw Body + un nodo Code de validación HMAC.

**Advertencia crítica:** cambiar el nodo trigger genera un URL de endpoint diferente.
Hay que re-registrar el webhook en Shopify Admin antes de que el flujo antiguo expire, o
la ingesta se interrumpe hasta completar el re-registro.

Nodo Code de referencia (colocar inmediatamente después del nodo Webhook genérico):

```javascript
const crypto = require('crypto');
const rawBody = $input.first().binary?.data
  ? Buffer.from($input.first().binary.data, 'base64').toString('utf8')
  : JSON.stringify($input.first().json);
const received = $input.first().headers?.['x-shopify-hmac-sha256'] ?? '';
const secret = $env.SHOPIFY_WEBHOOK_SECRET;
if (!secret) throw new Error('SHOPIFY_WEBHOOK_SECRET no configurado');
const computed = crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest('base64');
let valid = false;
try {
  valid = crypto.timingSafeEqual(
    Buffer.from(computed, 'base64'),
    Buffer.from(received, 'base64')
  );
} catch (_) {
  valid = false;
}
if (!valid) throw new Error('HMAC_INVALID');
return $input.all();
```

> Importante: el HMAC de Shopify se calcula sobre el raw body exacto. Si el nodo Webhook
> parsea el body antes de llegar al Code node, el raw body ya no está disponible y el
> HMAC calculado diferirá del enviado por Shopify, rechazando todos los webhooks
> legítimos. Configurar el nodo Webhook en modo **Raw Body** es obligatorio en este plan.

## Criterios de aceptación

| Criterio | Verificación |
|----------|-------------|
| Credencial Shopify con secret configurado | n8n UI → Credentials → campo no vacío |
| POST con firma inválida no escribe en Supabase | `SELECT * FROM productos WHERE shopify_product_id='99999'` → 0 filas |
| Webhook real de Shopify ejecuta con éxito | n8n Executions → estado `Success` |
| `sync_log` registra estado `ok` | Query del paso 5, paso 3 |
| Workflow E2 entrante versionado en `n8n/workflows/` | Archivo presente sin secrets en texto plano |

## Riesgos

- **Cambio de URL (Plan B):** reemplazar `shopifyTrigger` por nodo Webhook genérico cambia
  el endpoint. Re-registrar en Shopify o se interrumpe la ingesta hasta completarlo.
- **Raw body vs JSON re-serializado:** el HMAC de Shopify se valida sobre el raw body
  original. Un Code node posterior a un parse del body no tiene acceso al raw body y
  rechazaría todos los webhooks reales. Solo aplica al Plan B.
- **Credencial compartida:** la credencial "Shopify Admin API" puede estar siendo usada
  por el flujo saliente E2B. Verificar antes de modificar que no hay workflows activos
  que dependan del campo que se edita.
- **Secret en el JSON exportado:** algunos exportadores de n8n incluyen valores de
  credencial en el JSON. Revisar el archivo antes de commitear (paso 6).

## Estado del issue

Pendiente de aplicación manual por el fundador. La validación HMAC es el único cambio
requerido para cerrar AIR-88. El versionado del workflow es complementario (AIR-89).
