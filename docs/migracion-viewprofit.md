# Migración ViewProfit — Export de issues AIR-18 a AIR-36

**Fecha de export:** 2026-06-12
**Origen:** Linear workspace `airedeagua`, team `AIR` (Aire de Agua), proyecto `ViewProfit — Agente de Prospección`
**Propósito:** Estos issues pertenecen al producto **ViewProfit** (pipeline de prospección de tiendas Shopify) y deben recrearse en otro workspace. Este archivo es un export read-only del contenido completo de cada issue para facilitar la migración. Ningún issue fue modificado en Linear durante el export.

**Resumen del export:**

- 19 issues exportados: AIR-18, AIR-19, AIR-20, AIR-21, AIR-22, AIR-23, AIR-24, AIR-25, AIR-26, AIR-27, AIR-28, AIR-29, AIR-30, AIR-31, AIR-32, AIR-33, AIR-34, AIR-35, AIR-36.
- Todos están en estado **Backlog** (abiertos). Ninguno cerrado, cancelado ni archivado.
- Ninguno tiene labels asignados.
- Ninguno tiene comentarios.
- Todos creados por Santiago Suárez.

---

## AIR-18 — EPIC: Pipeline de Discovery de Prospectos

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Relaciones:** Hijos (parent de): AIR-19, AIR-20, AIR-21, AIR-25, AIR-29 (estos issues tienen `parentId = AIR-18`). Sin blocks / blocked-by / related directos.

### Descripción

## Objetivo

Construir un pipeline automatizado en n8n que descubra tiendas Shopify colombianas activas que hagan fit con el ICP de ViewProfit, las valide técnicamente y las almacene en Supabase con un score de prospección.

## Fuentes de discovery (por tier)

### Tier 1 — Alta calidad

1. **Facebook Ads Library API** — marcas actualmente pautando en Colombia (mejor señal de actividad)
2. **Google Search con operadores** — `"powered by Shopify" site:.co` por industria
3. **Instagram Hashtags** — `#modacolombia`, `#tiendaonlinecolombia`, etc.

### Tier 2 — Apoyo

4. **Apify** — como puente mientras se aprueba token de Meta
5. **BuiltWith / Wappalyzer** — filtro directo por tecnología + país

## Arquitectura del pipeline

```
[Discovery] → [Normalización URL] → [Validación Shopify] → [Enrich Instagram] → [Score ICP] → [Supabase]
```

## Dependencias

* Token Meta Ads Library API (solicitar en [facebook.com/ads/library/api/](<http://facebook.com/ads/library/api/>))
* Cuenta Apify (puente inmediato)
* RapidAPI Instagram Scraper
* Tabla `prospects` en Supabase
* SerpAPI o ScaleSerp para Google queries

## Criterio de éxito

* 100+ prospectos Tier A en Supabase en las primeras 4 semanas
* Tasa de confirmación Shopify > 80% sobre URLs descubiertas
* Pipeline corriendo automáticamente sin intervención manual

### Comentarios

(ninguno)

---

## AIR-19 — Infraestructura: Crear tabla prospects en Supabase y obtener credenciales de APIs

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Relaciones:** Parent: AIR-18. Sin blocks / blocked-by / related directos.

### Descripción

## Historia de Usuario

Como equipo de ViewProfit  
Quiero tener el schema de Supabase y credenciales de APIs listas  
Para que el pipeline de discovery pueda almacenar y enriquecer prospectos desde el primer día

## Tareas

### 1\. Crear tabla `prospects` en Supabase

```sql
CREATE TABLE prospects (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,

  -- Identificación
  brand_name TEXT,
  website_url TEXT UNIQUE NOT NULL,
  instagram_handle TEXT,
  instagram_url TEXT,

  -- Validación Shopify
  runs_shopify BOOLEAN,
  shopify_confidence TEXT CHECK (shopify_confidence IN ('confirmed', 'likely', 'possible', 'unknown')),
  shopify_score INTEGER,
  shopify_signals JSONB,

  -- Instagram
  instagram_followers INTEGER,
  instagram_following INTEGER,
  instagram_posts INTEGER,
  instagram_bio TEXT,
  instagram_last_checked TIMESTAMPTZ,

  -- Clasificación
  industry TEXT,
  country TEXT DEFAULT 'CO',
  city TEXT,

  -- Score ICP
  icp_score INTEGER CHECK (icp_score BETWEEN 0 AND 100),
  icp_tier TEXT CHECK (icp_tier IN ('A', 'B', 'C', 'descartado')),
  icp_notes TEXT,

  -- Estado prospección
  status TEXT DEFAULT 'nuevo'
    CHECK (status IN ('nuevo', 'calificado', 'contactado', 'interesado', 'descartado')),

  -- Meta
  source TEXT,
  discovered_at TIMESTAMPTZ DEFAULT NOW(),
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  raw_data JSONB
);

CREATE INDEX ON prospects (icp_tier);
CREATE INDEX ON prospects (status);
CREATE INDEX ON prospects (industry);
CREATE INDEX ON prospects (instagram_followers);
CREATE INDEX ON prospects (runs_shopify);
```

### 2\. Obtener credenciales

- [ ] **Meta Ads Library API** → solicitar acceso en `facebook.com/ads/library/api/`
- [ ] **Apify** → crear cuenta, obtener API token, instalar actor `apify/facebook-ads-library-scraper`
- [ ] **RapidAPI Instagram Scraper** → suscribirse al plan básico (\~$10/mes)
- [ ] **SerpAPI** → crear cuenta plan básico (100 búsquedas/mes gratis para empezar)
- [ ] Guardar todos los tokens como variables de entorno en n8n

### 3\. Verificar conectividad n8n ↔ Supabase

- [ ] Crear credencial de Supabase en n8n
- [ ] Test: INSERT y SELECT manual desde un workflow de prueba

## Criterio de Aceptación

* Tabla creada y accesible desde n8n
* Al menos Apify + RapidAPI operativos (Meta puede tardar 24-48h)
* Un registro de prueba insertado exitosamente en `prospects`

### Comentarios

(ninguno)

---

## AIR-20 — Discovery Fuente 1: Workflow n8n — Facebook Ads Library via Apify

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Relaciones:** Parent: AIR-18. Sin blocks / blocked-by / related directos.

### Descripción

## Historia de Usuario

Como equipo de ViewProfit  
Quiero un workflow en n8n que use Apify para encontrar marcas colombianas activas pautando en Meta  
Para tener un flujo de prospectos de alta calidad desde el día 1

## Por qué Apify (decisión definitiva)

Apify maneja el browser rendering de la Ads Library en su infraestructura. Sin fricción de aprobación de Meta, sin mantener Playwright, sin tokens que expiren. Es la ruta más rápida y estable para bootstrap.

**Costo:** \~$2-5 por 1,000 anuncios procesados → \~$10-20/mes para el volumen que necesitamos.

## Credencial necesaria

* Cuenta en [apify.com](<http://apify.com>) → obtener **API Token** en Settings → Integrations
* Actor a usar: `apify/facebook-ads-library-scraper`
* Guardar token como variable de entorno en n8n: `APIFY_TOKEN`

## Configuración del workflow n8n

### Nodo 1 — Schedule Trigger

```
Frecuencia: Lunes y Jueves, 7:00am
```

### Nodo 2 — Set: Lista de queries por industria

```javascript
// Retorna array — cada item alimenta el loop
const queries = [
  "envíos a todo colombia",
  "tienda online colombia",
  "moda colombiana",
  "ropa mujer colombia",
  "ropa hombre colombia",
  "accesorios colombia",
  "belleza colombia",
  "skincare colombia",
  "calzado colombia",
  "hogar decoración colombia",
  "joyería colombia",
  "suplementos colombia",
  "ropa deportiva colombia",
  "mascotas colombia tienda"
];
return queries.map(q => ({ query: q }));
```

### Nodo 3 — Loop Over Items

### Nodo 4 — HTTP Request: Disparar Apify Actor

```
Method: POST
URL: https://api.apify.com/v2/acts/apify~facebook-ads-library-scraper/runs?token={{$env.APIFY_TOKEN}}
Headers:
  Content-Type: application/json
Body (JSON):
{
  "searchTerms": ["{{ $json.query }}"],
  "country": "CO",
  "activeStatus": "ACTIVE",
  "mediaType": "all",
  "limit": 100
}
```

Respuesta: devuelve `{ id: "RUN_ID", ... }` — guardar el `id` para el siguiente nodo.

### Nodo 5 — Wait

```
Esperar: 90 segundos
(Apify tarda ~60-90s en procesar 100 anuncios)
```

### Nodo 6 — HTTP Request: Obtener resultados del run

```
Method: GET
URL: https://api.apify.com/v2/actor-runs/{{ $json.id }}/dataset/items?token={{$env.APIFY_TOKEN}}
```

### Nodo 7 — Code: Extraer y normalizar URLs de destino

```javascript
const items = $input.all();
const results = [];

for (const item of items) {
  const ad = item.json;

  // Apify expone estos campos según la versión del actor
  let url = ad.destinationUrl
         || ad.outboundLink
         || ad.websiteUrl
         || ad.url
         || null;

  // Fallback: extraer URL del copy del anuncio
  if (!url && ad.bodyText) {
    const match = ad.bodyText.match(/https?:\/\/[a-zA-Z0-9.-]+\.[a-z]{2,}/);
    if (match) url = match[0];
  }

  if (!url) continue;

  // Normalizar a dominio raíz (sin path ni query params)
  try {
    const parsed = new URL(url);
    const domain = `${parsed.protocol}//${parsed.hostname}`;

    // Excluir marketplaces y redes sociales — no son tiendas propias
    const exclude = [
      'facebook.com', 'instagram.com', 'linktr.ee',
      'wa.me', 'whatsapp.com', 'youtube.com',
      'mercadolibre.com', 'amazon.com', 'rappi.com'
    ];
    if (exclude.some(e => parsed.hostname.includes(e))) continue;

    results.push({
      website_url: domain,
      brand_name: ad.pageName || null,
      facebook_page_id: ad.pageId || null,
      ad_copy: ad.bodyText?.substring(0, 200) || null,
      source: 'apify_fb_ads',
      raw_data: ad
    });
  } catch(e) {
    continue;
  }
}

// Deduplicar por dominio dentro del mismo run
const seen = new Set();
return results.filter(r => {
  if (seen.has(r.website_url)) return false;
  seen.add(r.website_url);
  return true;
});
```

### Nodo 8 — Supabase: Verificar si el dominio ya existe

```
Operación: Select
Tabla: prospects
Filtro: website_url = {{ $json.website_url }}
Limit: 1
```

### Nodo 9 — IF: ¿Es nuevo?

```
Condición: largo del resultado de Supabase = 0
Rama Sí → pasar a workflow de Validación Shopify (AIR-21)
Rama No → descartar (ya está en la BD)
```

### Nodo 10 — Supabase: Insert inicial (solo campos básicos)

```
Operación: Insert
Tabla: prospects
Campos:
  website_url: {{ $json.website_url }}
  brand_name:  {{ $json.brand_name }}
  source:      apify_fb_ads
  status:      nuevo
  raw_data:    {{ $json.raw_data }}
```

*Los campos de Shopify e Instagram se llenan en los siguientes workflows.*

## Manejo de errores

* Si Apify devuelve error 4xx → log en n8n + continuar con siguiente query (no detener el loop)
* Si el run de Apify sigue en estado `RUNNING` a los 90s → hacer un segundo wait de 60s y reintentar
* Si dataset viene vacío → saltar esa query, no es error

## Criterio de Aceptación

- [ ] Workflow corre automáticamente lunes y jueves sin intervención manual
- [ ] Procesa mínimo 10 queries por ejecución
- [ ] Extrae y normaliza URLs correctamente a dominio raíz
- [ ] Descarta duplicados antes de insertar en Supabase
- [ ] Errores de Apify logueados pero no detienen el pipeline completo
- [ ] Al menos 30 URLs nuevas únicas por ejecución semanal

## Costo estimado

* \~$10-20/mes para 14 queries × 100 anuncios × 2 veces/semana
* Apify ofrece $5 de crédito gratuito al registrarse → suficiente para la primera prueba

### Comentarios

(ninguno)

---

## AIR-21 — Validación Shopify: Workflow n8n — Detector multi-vector con 4 requests en cascada

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Relaciones:** Parent: AIR-18. Related to: AIR-36 (FASE 3 — Enriquecimiento Shopify via /products.json + Generador de Insight Hook).

### Descripción

## Historia de Usuario

Como equipo de ViewProfit  
Quiero un workflow en n8n que valide si una URL corre sobre Shopify usando múltiples vectores de detección  
Para no desperdiciar esfuerzo de enriquecimiento en tiendas que no son Shopify

## Vectores de detección (orden de ejecución)

```
Request 1: GET /robots.txt     → buscar "use Shopify" — liviano, 1KB
Request 2: GET /cart.js        → JSON con token = confirmado, 1KB
Request 3: HEAD del dominio    → headers powered-by, cookies _shopify_
Request 4: GET / (15KB)        → Shopify.shop, cdn.shopify.com, Instagram handle
```

Si Request 1 o 2 dan positivo → STOP, ya es "confirmed". Los siguientes solo si los anteriores no fueron concluyentes.

## Nodo Code: Función de detección consolidada

```javascript
function detectShopify(html, headers, cartResponse, robotsTxt) {
  const signals = [];
  const weights = {};

  // TIER 1: Confirmación absoluta
  if (html?.includes('cdn.shopify.com')) {
    signals.push('cdn_shopify'); weights['cdn_shopify'] = 10;
  }
  if (html?.match(/Shopify\.shop\s*=\s*["'][^"']+\.myshopify\.com["']/)) {
    signals.push('shopify_shop_object'); weights['shopify_shop_object'] = 10;
  }
  if (html?.includes('window.Shopify') || html?.includes('var Shopify =')) {
    signals.push('shopify_global_object'); weights['shopify_global_object'] = 9;
  }
  if (cartResponse?.token !== undefined) {
    signals.push('cart_js_endpoint'); weights['cart_js_endpoint'] = 10;
  }

  // TIER 2: Alta probabilidad
  if (html?.includes('ShopifyAnalytics') || html?.includes('Trekkie')) {
    signals.push('shopify_analytics'); weights['shopify_analytics'] = 8;
  }
  if (html?.includes('shopifycloud')) {
    signals.push('shopify_cloud_script'); weights['shopify_cloud_script'] = 8;
  }
  if (html?.match(/action=["']\/cart\/(add|update)["']/)) {
    signals.push('cart_form_action'); weights['cart_form_action'] = 7;
  }
  if (html?.includes('name="form_type"') && html?.includes('value="product"')) {
    signals.push('shopify_form_type'); weights['shopify_form_type'] = 7;
  }

  // TIER 3: Señales de apoyo
  if (html?.match(/data-section-type=["'][^"']+["']/)) {
    signals.push('section_data_attrs'); weights['section_data_attrs'] = 5;
  }
  if (html?.match(/class=["']template-(index|product|collection|cart|page)/)) {
    signals.push('template_body_class'); weights['template_body_class'] = 5;
  }
  if (robotsTxt?.includes('use Shopify')) {
    signals.push('robots_txt_shopify'); weights['robots_txt_shopify'] = 9;
  }
  if (robotsTxt?.includes('Disallow: /checkout')) {
    signals.push('robots_checkout_disallow'); weights['robots_checkout_disallow'] = 4;
  }
  if (headers?.['powered-by']?.toLowerCase().includes('shopify')) {
    signals.push('header_powered_by'); weights['header_powered_by'] = 10;
  }
  if (headers?.['set-cookie']?.includes('_shopify_')) {
    signals.push('shopify_cookies'); weights['shopify_cookies'] = 8;
  }

  const totalScore = signals.reduce((sum, s) => sum + (weights[s] || 0), 0);

  let confidence;
  if (totalScore >= 10) confidence = 'confirmed';
  else if (totalScore >= 5)  confidence = 'likely';
  else if (totalScore >= 2)  confidence = 'possible';
  else confidence = 'unknown';

  // Extraer handle de Instagram del HTML
  const igMatches = html?.match(/instagram\.com\/([a-zA-Z0-9._]+)/g) || [];
  const exclude = ['sharer','share','p','reel','explore','accounts','reels'];
  const handles = [...new Set(
    igMatches.map(m => m.split('/')[1]).filter(h => !exclude.includes(h))
  )];

  // Extraer nombre de tienda del Shopify.shop
  const shopMatch = html?.match(/Shopify\.shop\s*=\s*["']([^"']+)["']/);
  const shopifyInternalId = shopMatch ? shopMatch[1] : null;

  // Extraer tema activo
  const themeMatch = html?.match(/"name":"([^"]+)","id":(\d+)/);
  const theme = themeMatch ? `${themeMatch[1]} (id:${themeMatch[2]})` : null;

  return {
    runs_shopify: totalScore >= 5,
    shopify_confidence: confidence,
    shopify_score: totalScore,
    shopify_signals: signals,
    instagram_handle: handles[0] || null,
    shopify_internal_id: shopifyInternalId,
    shopify_theme: theme
  };
}
```

## Flujo del workflow

```
[Input: website_url]
        ↓
[HTTP: GET /robots.txt]  ← timeout 5s
        ↓
[IF: contiene "use Shopify"]
  Sí → confidence=confirmed, skip requests 2-4
  No ↓
[HTTP: GET /cart.js]     ← timeout 5s
        ↓
[IF: JSON con token]
  Sí → confidence=confirmed, skip requests 3-4
  No ↓
[HTTP: HEAD /]           ← solo headers, rápido
        ↓
[HTTP: GET / primeros 15KB]
        ↓
[Code: detectShopify() con todos los vectores]
        ↓
[IF: shopify_confidence = confirmed OR likely]
  Sí → continuar a enriquecimiento Instagram
  No → Supabase UPDATE runs_shopify=false, status=descartado
```

## Criterio de Aceptación

- [ ] Detecta correctamente tiendas Shopify con dominio propio (sin [myshopify.com](<http://myshopify.com>) visible)
- [ ] Tasa de falsos negativos < 5% (validar con 20 tiendas conocidas)
- [ ] Tasa de falsos positivos = 0% (no marcar como Shopify lo que no lo es)
- [ ] Timeout de 5s por request para no bloquear el pipeline
- [ ] Extrae Instagram handle del HTML cuando está disponible
- [ ] Resultado guardado en Supabase con todos los campos de validación

## Notas técnicas

* Usar `headers: { Range: 'bytes=0-15360' }` para pedir solo primeros 15KB del HTML
* Manejar redirects (301/302) siguiendo hasta el destino final
* User-Agent: simular móvil para evitar bloqueos: `Mozilla/5.0 (iPhone; CPU iPhone OS 17_0...)`

### Comentarios

(ninguno)

---

## AIR-22 — FASE 1 — Crear schema de prospects en Supabase

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Estimate:** 2 Points
- **Relaciones:** Related to: AIR-36. Sin parent.

### Descripción

Crear tabla `prospects` en Supabase con campos: id (uuid), brand_name, website_url (unique), instagram_handle, runs_shopify (boolean), shopify_confidence (confirmed/likely/unknown), shopify_signals (jsonb), instagram_followers, instagram_bio, industry, country (default CO), icp_score (0-100), icp_tier (A/B/C/descartado), status (nuevo/calificado/contactado/interesado/descartado), source, discovered_at, last_updated, raw_data (jsonb). Crear índices en icp_tier, status, instagram_followers, runs_shopify.

Criterios: tabla creada, insertar registro de prueba, confirmar que upsert por website_url funciona.

### Comentarios

(ninguno)

---

## AIR-23 — FASE 1 — Setup cuenta Apify y configurar actor Ads Library

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Estimate:** 1 Point
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Crear cuenta en [apify.com](<http://apify.com>). Buscar actor "Facebook Ads Library Scraper". Configurar input inicial: country=CO, searchTerms=\["moda colombia","ropa colombia","tienda online colombia","belleza colombia","accesorios colombia"\], activeStatus=ACTIVE, limit=500. Correr manualmente y verificar que el output incluye destinationUrl o url del anuncio. Guardar API key de Apify como variable de entorno en n8n.

Criterios: actor corre sin errores, output tiene al menos 50 registros con URL de destino visible, API key guardada en n8n credentials.

### Comentarios

(ninguno)

---

## AIR-24 — FASE 1 — Setup RapidAPI Instagram Scraper

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Estimate:** 1 Point
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Registrar en [rapidapi.com](<http://rapidapi.com>). Buscar y suscribirse a "Instagram Scraper API" (buscar una con endpoint /v1/info?username=). Verificar que devuelve follower_count, biography, media_count, is_verified. Guardar API key en n8n credentials. Hacer prueba manual con handle conocido (ej: airedeagua\_).

Criterios: endpoint responde con datos correctos, key guardada, costo mensual confirmado menor a $15 USD para volumen esperado.

### Comentarios

(ninguno)

---

## AIR-25 — Enriquecimiento Instagram: Workflow n8n — RapidAPI scraper + inferencia de industria

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Relaciones:** Parent: AIR-18. Related to: AIR-36.

### Descripción

## Historia de Usuario

Como equipo de ViewProfit  
Quiero un workflow que consulte Instagram de cada prospecto validado como Shopify  
Para enriquecer el perfil con seguidores, bio e industria antes de calcular el score ICP

## Fuente

RapidAPI → Instagram Scraper API (\~$10/mes, sin aprobación de Meta)

## Prerequisito

El prospecto debe tener `instagram_handle` extraído del HTML (por AIR-21) o el `brand_name` como fallback de búsqueda.

## Nodo HTTP Request: RapidAPI

```
Method: GET
URL: https://instagram-scraper-api2.p.rapidapi.com/v1/info
Headers:
  X-RapidAPI-Key: {{$env.RAPIDAPI_KEY}}
  X-RapidAPI-Host: instagram-scraper-api2.p.rapidapi.com
Query params:
  username: {{$json.instagram_handle}}
```

## Respuesta que interesa

```javascript
{
  data: {
    user: {
      follower_count: 45200,
      following_count: 832,
      media_count: 340,
      biography: "Moda colombiana 🇨🇴 | Envíos a todo el país | Link: tienda.com",
      is_verified: false,
      full_name: "Marca XYZ"
    }
  }
}
```

## Nodo Code: Procesar respuesta + inferir industria

```javascript
const user = $input.item.json.data?.user;
if (!user) return { instagram_found: false };

const bio = user.biography || '';
const fullName = user.full_name || '';

// Inferir industria desde bio y nombre
function inferIndustry(bio, name) {
  const text = (bio + ' ' + name).toLowerCase();
  const categories = {
    'moda':        ['moda', 'ropa', 'outfit', 'fashion', 'vestido', 'camisa', 'jeans'],
    'belleza':     ['belleza', 'skincare', 'cosmétic', 'maquillaje', 'cabello', 'cuidado'],
    'calzado':     ['zapato', 'calzado', 'tenis', 'sneaker', 'bota'],
    'accesorios':  ['accesorio', 'bolso', 'cartera', 'joyería', 'collar', 'pulsera'],
    'hogar':       ['hogar', 'decoración', 'casa', 'mueble', 'cocina'],
    'suplementos': ['suplemento', 'proteína', 'gym', 'fitness', 'nutrición'],
    'mascotas':    ['mascota', 'perro', 'gato', 'pet'],
    'deportes':    ['deporte', 'running', 'ciclismo', 'fútbol', 'sport'],
  };

  for (const [industry, keywords] of Object.entries(categories)) {
    if (keywords.some(k => text.includes(k))) return industry;
  }
  return 'otro';
}

return {
  instagram_found: true,
  instagram_followers: user.follower_count,
  instagram_following: user.following_count,
  instagram_posts: user.media_count,
  instagram_bio: bio,
  instagram_verified: user.is_verified,
  brand_name_ig: fullName,
  industry: inferIndustry(bio, fullName),
  instagram_last_checked: new Date().toISOString()
};
```

## Lógica de fallback si no hay handle

```javascript
// Si no se extrajo handle del HTML, intentar búsqueda por nombre de marca
// GET https://instagram-scraper-api2.p.rapidapi.com/v1/search?query={brand_name}
// Tomar el primer resultado con username similar al brand_name
// Si similarity < 0.7 → no asignar, marcar instagram_handle = null
```

## Filtro ICP mínimo de seguidores

```javascript
// Solo continuar al score si:
const MIN_FOLLOWERS = 5000; // Tier mínimo para consideración
if (user.follower_count < MIN_FOLLOWERS) {
  // Guardar en Supabase con icp_tier = 'C' directamente, no calcular score completo
}
```

## Criterio de Aceptación

- [ ] Consulta exitosa cuando hay `instagram_handle`
- [ ] Fallback de búsqueda por nombre funciona con precisión > 70%
- [ ] Industria inferida correctamente en > 80% de los casos (validar muestra de 20)
- [ ] Prospectos con < 5K followers marcados como tier C automáticamente
- [ ] Campos guardados en Supabase: followers, following, posts, bio, industry, last_checked

### Comentarios

(ninguno)

---

## AIR-26 — Score ICP: Algoritmo de puntuación y asignación de tiers A/B/C en Supabase

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Relaciones:** Parent: AIR-18. Sin blocks / blocked-by / related directos.

### Descripción

## Historia de Usuario

Como equipo de ViewProfit  
Quiero que cada prospecto reciba un score automático 0-100 y un tier A/B/C  
Para priorizar a quién contactar primero sin revisar manualmente cada registro

## Lógica de scoring

```javascript
function scoreICP(prospect) {
  let score = 0;
  const notes = [];

  // === SHOPIFY (máx 30 pts) ===
  if (prospect.shopify_confidence === 'confirmed') {
    score += 30; notes.push('Shopify confirmado');
  } else if (prospect.shopify_confidence === 'likely') {
    score += 15; notes.push('Shopify probable');
  } else {
    score -= 20; notes.push('No Shopify');
  }

  // === INSTAGRAM FOLLOWERS (máx 30 pts) ===
  const f = prospect.instagram_followers || 0;
  if (f >= 100000)     { score += 30; notes.push(`${f.toLocaleString()} seg (muy alto)`); }
  else if (f >= 50000) { score += 25; notes.push(`${f.toLocaleString()} seg (alto)`); }
  else if (f >= 10000) { score += 20; notes.push(`${f.toLocaleString()} seg (ICP)`); }
  else if (f >= 5000)  { score += 8;  notes.push(`${f.toLocaleString()} seg (bajo)`); }
  else                 { score -= 15; notes.push('Muy pocos seguidores'); }

  // === INDUSTRIA (máx 15 pts) ===
  const highFit = ['moda', 'belleza', 'accesorios', 'calzado', 'joyería', 'suplementos'];
  const medFit  = ['hogar', 'deportes', 'mascotas'];
  if (highFit.includes(prospect.industry)) {
    score += 15; notes.push(`Industria alta: ${prospect.industry}`);
  } else if (medFit.includes(prospect.industry)) {
    score += 8;  notes.push(`Industria media: ${prospect.industry}`);
  } else {
    notes.push(`Industria desconocida/baja`);
  }

  // === SEÑALES DE ACTIVIDAD (máx 15 pts) ===
  // Pautando activamente en Meta (viene de Ads Library)
  if (prospect.source === 'apify_fb_ads') {
    score += 15; notes.push('Pautando activamente en Meta');
  }
  // Cuenta verificada en Instagram
  if (prospect.instagram_verified) {
    score += 5; notes.push('Cuenta verificada IG');
  }

  // === PENALIZACIONES ===
  if (!prospect.instagram_handle) {
    score -= 10; notes.push('Sin Instagram detectado');
  }

  // Clamp 0-100
  score = Math.max(0, Math.min(100, score));

  // Tier
  let tier;
  if (score >= 70)      tier = 'A';
  else if (score >= 45) tier = 'B';
  else if (score >= 20) tier = 'C';
  else                  tier = 'descartado';

  return { icp_score: score, icp_tier: tier, icp_notes: notes.join(' | ') };
}
```

## Tabla de referencia de tiers

| Tier | Score | Acción |
| -- | -- | -- |
| **A** | 70-100 | Contactar esta semana — Shopify confirmado + 10K+ followers + industria fit |
| **B** | 45-69 | Calificar manualmente — algún criterio débil |
| **C** | 20-44 | Monitorear — potencial a futuro |
| **descartado** | < 20 | No Shopify o señales muy débiles |

## Criterio de Aceptación

- [ ] Score calculado correctamente con los 5 factores
- [ ] Tier asignado consistentemente con la tabla
- [ ] `icp_notes` legibles en español para revisión manual
- [ ] Resultado guardado en Supabase (icp_score, icp_tier, icp_notes, last_updated)
- [ ] Score recalculado automáticamente si el prospecto se enriquece (re-run en UPDATE)

### Comentarios

(ninguno)

---

## AIR-27 — FASE 2 — Nodo n8n: Detector Shopify multi-vector

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Estimate:** 3 Points
- **Relaciones:** Related to: AIR-36. Sin parent.

### Descripción

Construir el nodo Code en n8n que detecta si un dominio corre Shopify usando 4 vectores en secuencia: (1) GET /robots.txt — buscar texto "use Shopify" o "Disallow: /checkout"; (2) GET /cart.js — si responde JSON con campo "token" = confirmado absoluto; (3) HEAD headers — buscar powered-by:Shopify, x-shopid, cookies *shopify*\*; (4) GET primeros 15KB del HTML — buscar [cdn.shopify.com](<http://cdn.shopify.com>), window.Shopify, [Shopify.shop](<http://Shopify.shop>), ShopifyAnalytics, Trekkie, shopifycloud. Sistema de scoring: cada señal suma puntos, resultado final: confirmed (>=10pts) / likely (5-9pts) / unknown (<5pts). Detener en cuanto se alcance "confirmed" para no gastar requests innecesarios. Output: {runs_shopify, shopify_confidence, shopify_score, shopify_signals\[\]}.

Criterios: probado con mínimo 10 URLs reales, precisión >95%, tiempo promedio <3 segundos por dominio.

### Comentarios

(ninguno)

---

## AIR-28 — FASE 2 — Flujo n8n: Discovery desde Apify Ads Library

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Estimate:** 3 Points
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Construir flujo completo en n8n: Schedule Trigger (diario 6am) → Set nodo con lista de 10 queries de búsqueda → Loop por cada query → HTTP Request a API de Apify para correr actor Ads Library → esperar resultado (webhook o polling) → Code nodo para extraer y normalizar URLs de destino de los anuncios → filtrar dominios propios (excluir [facebook.com](<http://facebook.com>), [instagram.com](<http://instagram.com>), [linktr.ee](<http://linktr.ee>), [wa.me](<http://wa.me>), [mercadolibre.com](<http://mercadolibre.com>)) → IF ¿ya existe en Supabase? → Si no existe: pasar al detector Shopify → Supabase upsert. Queries iniciales: "envíos colombia", "tienda online colombia", "moda colombiana", "ropa mujer colombia", "accesorios colombia", "belleza colombia", "calzado colombia", "hogar decoracion colombia", "joyería colombia", "suplementos colombia".

Criterios: flujo corre sin errores manuales, procesa mínimo 50 URLs por ejecución, no crea duplicados.

### Comentarios

(ninguno)

---

## AIR-29 — Alertas: Resumen diario de prospectos Tier A por WhatsApp

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Relaciones:** Parent: AIR-18. Related to: AIR-36.

### Descripción

## Historia de Usuario

Como Santiago  
Quiero recibir un resumen diario de los nuevos prospectos Tier A descubiertos  
Para saber cada mañana a quién contactar ese día sin entrar a Supabase

## Canal de alerta: WhatsApp via n8n

### Trigger

Cada día a las 8:00am si hay nuevos prospectos Tier A con status = 'nuevo' descubiertos en las últimas 24h

### Nodo Supabase: Query de nuevos Tier A

```sql
SELECT brand_name, website_url, instagram_handle, 
       instagram_followers, industry, icp_score, icp_notes
FROM prospects
WHERE icp_tier = 'A'
  AND status = 'nuevo'
  AND discovered_at > NOW() - INTERVAL '24 hours'
ORDER BY icp_score DESC
LIMIT 10;
```

### Nodo Code: Formatear mensaje

```javascript
const prospects = $input.all();

if (prospects.length === 0) return [{ skip: true }];

const lines = prospects.map((p, i) => {
  const f = p.json.instagram_followers?.toLocaleString('es-CO') || 'N/A';
  return `${i + 1}. *${p.json.brand_name || 'Sin nombre'}*\n` +
         `   🌐 ${p.json.website_url}\n` +
         `   📸 @${p.json.instagram_handle || 'N/A'} · ${f} seg\n` +
         `   🏷️ ${p.json.industry || 'N/A'} · Score: ${p.json.icp_score}/100`;
}).join('\n\n');

const msg = `🎯 *ViewProfit — Prospectos Tier A nuevos*\n` +
            `📅 ${new Date().toLocaleDateString('es-CO')}\n\n` +
            `${lines}\n\n` +
            `_Ver todos en Supabase → tabla prospects_`;

return [{ message: msg }];
```

### Mensaje de ejemplo

```
🎯 ViewProfit — Prospectos Tier A nuevos
📅 7 de abril de 2026

1. Marca XYZ Moda
   🌐 https://marcaxyz.com
   📸 @marcaxyz · 45,200 seg
   🏷️ moda · Score: 82/100

2. Belleza Natural CO
   🌐 https://bellezanatural.co
   📸 @bellezanaturalco · 23,100 seg
   🏷️ belleza · Score: 75/100
```

## Criterio de Aceptación

- [ ] Mensaje enviado solo si hay prospectos nuevos (no enviar si lista vacía)
- [ ] Máximo 10 prospectos por mensaje
- [ ] Formato legible en WhatsApp (negrita con asteriscos)
- [ ] Incluye score e industria para decisión rápida
- [ ] Workflow separado del pipeline principal (no bloquea el discovery)

### Comentarios

(ninguno)

---

## AIR-30 — FASE 3 — Nodo n8n: Extractor de Instagram handle desde HTML

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Estimate:** 2 Points
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Nodo Code que dado el HTML del sitio web extrae el handle de Instagram de la marca. Buscar patrones: [instagram.com/\[handle\]](<http://instagram.com/%5Bhandle%5D>) en links, atributos href, texto visible. Filtrar handles genéricos (sharer, share, p, reel, explore, accounts, reels). Si encuentra múltiples candidatos, priorizar el que aparece más veces o el que está en el footer/header. Output: {instagram_handle, instagram_url, instagram_confidence}.

Criterios: probado con 10 sitios reales incluyendo [airedeagua.com](<http://airedeagua.com>) (debe detectar "airedeagua\_"), tasa de detección >80% en tiendas colombianas activas.

### Comentarios

(ninguno)

---

## AIR-31 — FASE 3 — Nodo n8n: Enriquecimiento Instagram via RapidAPI

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Estimate:** 2 Points
- **Relaciones:** Related to: AIR-36. Sin parent.

### Descripción

Flujo semanal (lunes 8am) que enriquece prospectos sin datos de Instagram. Supabase SELECT WHERE instagram_followers IS NULL AND instagram_handle IS NOT NULL → Loop → HTTP Request a RapidAPI Instagram Scraper → Code para extraer follower_count, following_count, media_count, biography, is_verified → Supabase UPDATE prospect con datos. Manejo de errores: si handle no existe en Instagram (404) → marcar instagram_handle como inválido. Rate limiting: máximo 1 request por segundo para no superar límites de RapidAPI.

Criterios: enriquece correctamente airedeagua\_ con sus datos reales, maneja errores sin romper el loop.

### Comentarios

(ninguno)

---

## AIR-32 — FASE 3 — Nodo n8n: Motor de scoring ICP

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Medium (3)
- **Estimate:** 2 Points
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Nodo Code que calcula el ICP score (0-100) y asigna tier basado en: Shopify confirmed +30pts / likely +15pts / no shopify -20pts. Instagram followers >=50k +30pts / >=10k +20pts / >=5k +5pts / <5k -15pts. Industria alto fit (moda, belleza, accesorios, hogar, joyería, suplementos) +15pts. Industria fit medio (electrónica, mascotas, deportes) +10pts. Tiers: A=70-100 (contactar esta semana), B=40-69 (calificar manualmente), C=20-39 (monitorear), descartado=<20. Output: {icp_score, icp_tier, icp_notes con razones detalladas}.

Criterios: score coherente con definición ICP, tier A solo para tiendas Shopify confirmado + followers >=10k + industria fit.

### Comentarios

(ninguno)

---

## AIR-33 — FASE 4 — Flujo n8n: Alerta WhatsApp para prospectos Tier A

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Medium (3)
- **Estimate:** 2 Points
- **Relaciones:** Related to: AIR-36. Sin parent.

### Descripción

Al final del flujo de discovery, si un nuevo prospecto resulta Tier A: enviar mensaje WhatsApp via Twilio con resumen del prospecto. Formato del mensaje: "🟢 Nuevo prospecto Tier A\\n\[Nombre marca\]\\n🌐 \[URL\]\\n📸 @\[instagram_handle\] — \[followers\] seguidores\\n🏭 \[industria\]\\n⭐ Score ICP: \[score\]/100\\n\[notas ICP\]".

Criterios: mensaje llega correctamente al número configurado, solo se dispara para Tier A, no se repite si el prospecto ya existía (solo nuevos).

### Comentarios

(ninguno)

---

## AIR-34 — FASE 4 — Seed manual: 50 URLs iniciales desde Facebook Ads Library

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Urgent (1)
- **Estimate:** 1 Point
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Tarea operativa (no técnica). Antes de que el agente esté completamente automatizado, hacer seed manual de la base de datos. Entrar a [facebook.com/ads/library](<http://facebook.com/ads/library>), filtrar: País=Colombia, Estado=Activo, buscar keywords: "envíos colombia", "moda colombiana", "tienda online", "compra ahora colombia". Copiar URLs de destino de los anuncios (mínimo 50). Insertar en tabla prospects de Supabase con source="seed_manual". Este seed permite empezar a validar el detector Shopify y el scoring antes de que los flujos automáticos estén listos.

Criterios: 50+ URLs en Supabase con status="nuevo" y source="seed_manual".

### Comentarios

(ninguno)

---

## AIR-35 — FASE 4 — Validación end-to-end: correr pipeline completo

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** Medium (3)
- **Estimate:** 2 Points
- **Relaciones:** Sin parent / blocks / blocked-by / related.

### Descripción

Prueba integral del pipeline completo sobre las 50 URLs del seed manual. Correr flujo de validación Shopify sobre todas → correr extractor Instagram → correr enriquecimiento RapidAPI → correr scoring → revisar resultados en Supabase. Métricas esperadas: >40 URLs procesadas exitosamente (80%), >15 confirmadas como Shopify (30%), >10 con Instagram encontrado, >5 Tier A identificados. Documentar falsos positivos y falsos negativos del detector.

Criterios: pipeline completo sin errores críticos, al menos 3 prospectos Tier A reales identificados para primera ronda de outreach.

### Comentarios

(ninguno)

---

## AIR-36 — FASE 3 — Nodo n8n: Enriquecimiento Shopify via /products.json + Generador de Insight Hook

- **Estado:** Backlog
- **Labels:** (ninguno)
- **Prioridad:** High (2)
- **Estimate:** 2 Points
- **Relaciones:** Related to (7): AIR-31, AIR-22, AIR-27, AIR-25, AIR-29, AIR-33, AIR-21. Sin parent.

### Descripción

## Historia de Usuario

Como equipo de ViewProfit
Quiero un nodo en n8n que analice automáticamente el catálogo público de cada tienda Shopify confirmada
Para generar un "insight hook" personalizado con datos reales de la tienda que sirva como gancho en el primer mensaje de outreach

---

## Qué hace exactamente

Para cada prospecto con `shopify_confidence = 'confirmed'` o `'likely'`, el nodo:

1. Llama a `/products.json?limit=250` de forma paginada (máx 250 por request, iterar hasta cubrir todo el catálogo)
2. Extrae métricas del catálogo
3. Infiere industria y margen estimado (usando la industria ya detectada vía Instagram bio)
4. Genera un texto de `insight_hook` listo para usar en DM de Instagram
5. Actualiza el registro en Supabase con todos los campos nuevos

## Qué NO hace

* No requiere autenticación ni API key de Shopify (endpoint público)
* No analiza órdenes reales ni ventas históricas
* No genera el mensaje final ni lo envía — solo produce el hook como insumo
* No accede a datos privados del merchant

## Suposiciones clave

* Todas las tiendas Shopify exponen `/products.json` públicamente por defecto
* La industria ya fue inferida en el paso de enriquecimiento Instagram (AIR-25/AIR-31)
* El margen estimado es por industria (tabla estática), no calculado por producto
* El hook generado es una propuesta — Santiago lo revisa antes de enviarlo en V1

---

## Criterios de Aceptación

- [ ] El nodo lee `/products.json` paginado correctamente (maneja tiendas con >250 SKUs)
- [ ] Extrae correctamente: total_skus, avg_price, min_price, max_price, has_discounts, top_collections
- [ ] Mapea industria → margen_bruto_estimado y margen_neto_estimado usando tabla estática
- [ ] Genera campo `insight_hook` (texto < 300 caracteres) con datos reales de la tienda
- [ ] Maneja errores: si `/products.json` devuelve 404 o está bloqueado → marcar `shopify_products_accessible = false` y continuar sin romper el flujo
- [ ] Actualiza tabla `prospects` en Supabase con todos los campos nuevos
- [ ] Tiempo de ejecución por prospecto < 10 segundos
- [ ] No procesa prospectos que ya tienen `insight_hook` generado (idempotente)

---

## Datos a Extraer de /products.json

| Campo calculado | Lógica | Tipo |
| -- | -- | -- |
| `total_skus` | COUNT de variants activas | Integer |
| `total_products` | COUNT de productos | Integer |
| `avg_price` | PROMEDIO de `variant.price` | Decimal |
| `min_price` | MIN de `variant.price` | Decimal |
| `max_price` | MAX de `variant.price` | Decimal |
| `has_discounts` | ¿Algún `compare_at_price` > `price`? | Boolean |
| `discount_pct` | % productos con descuento activo | Decimal |
| `top_collections` | Primeras 3 colecciones del catálogo | Array\[String\] |
| `catalog_currency` | Moneda detectada (COP/MXN/USD) | String |

---

## Tabla Estática: Margen por Industria

```javascript
const MARGENES_INDUSTRIA = {
  'moda':        { bruto: 0.60, neto: 0.38, error_comun: 'devoluciones (15-25%)' },
  'belleza':     { bruto: 0.68, neto: 0.44, error_comun: 'muestras y roturas' },
  'joyeria':     { bruto: 0.72, neto: 0.48, error_comun: 'merma y garantías' },
  'hogar':       { bruto: 0.52, neto: 0.32, error_comun: 'peso en envíos' },
  'suplementos': { bruto: 0.65, neto: 0.41, error_comun: 'vencimientos como pérdida' },
  'electronica': { bruto: 0.28, neto: 0.14, error_comun: 'garantías y devoluciones' },
  'mascotas':    { bruto: 0.48, neto: 0.29, error_comun: 'variable por tipo de producto' },
  'deportes':    { bruto: 0.50, neto: 0.31, error_comun: 'tallas y devoluciones' },
  'default':     { bruto: 0.52, neto: 0.32, error_comun: 'costos variables no visibles' }
};
```

---

## Lógica del Generador de Insight Hook

```javascript
function generarInsightHook(prospecto) {
  const margen = MARGENES_INDUSTRIA[prospecto.industry] || MARGENES_INDUSTRIA['default'];

  // Calcular gap estimado mensual (asume ~30 órdenes/día baseline por tamaño Instagram)
  const ordenes_estimadas_mes = estimarOrdenes(prospecto.instagram_followers);
  const revenue_estimado = ordenes_estimadas_mes * prospecto.avg_price;
  const gap_mensual = Math.round((margen.bruto - margen.neto) * revenue_estimado / 10000) * 10000;

  // Formato de moneda según país
  const moneda = prospecto.country === 'CO' ? 'COP' : 
                 prospecto.country === 'MX' ? 'MXN' : 'USD';

  return `Tienen ${prospecto.total_products} productos en Shopify, precio promedio ` +
         `$${formatNum(prospecto.avg_price)} ${moneda}. ` +
         `En ${prospecto.industry}, la diferencia entre margen bruto y neto real ` +
         `suele ser $${formatNum(gap_mensual)}+ al mes en costos que Shopify no muestra.`;
}

function estimarOrdenes(followers) {
  if (followers >= 100000) return 150;
  if (followers >= 50000)  return 80;
  if (followers >= 10000)  return 35;
  return 15;
}
```

---

## Campos Nuevos en Supabase (ALTER TABLE prospects)

```sql
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS total_products INTEGER;
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS total_skus INTEGER;
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS avg_price DECIMAL(12,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS min_price DECIMAL(12,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS max_price DECIMAL(12,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS has_discounts BOOLEAN;
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS discount_pct DECIMAL(5,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS top_collections TEXT[];
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS catalog_currency VARCHAR(10);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS margen_bruto_estimado DECIMAL(5,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS margen_neto_estimado DECIMAL(5,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS gap_mensual_estimado DECIMAL(12,2);
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS insight_hook TEXT;
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS shopify_products_accessible BOOLEAN DEFAULT true;
ALTER TABLE prospects ADD COLUMN IF NOT EXISTS products_enriched_at TIMESTAMP;
```

---

## Flujo n8n (nodos en secuencia)

```text
[Supabase SELECT]
WHERE shopify_confidence IN ('confirmed','likely')
AND insight_hook IS NULL
AND shopify_products_accessible IS NOT FALSE
LIMIT 50 por ejecución
        ↓
[Loop Over Items]
        ↓
[HTTP Request: GET /products.json?limit=250&page=1]
  → Si 404/bloqueado: UPDATE shopify_products_accessible=false → continuar
        ↓
[Code Node: Paginar si total_products > 250]
  → Repetir requests hasta cubrir catálogo completo
        ↓
[Code Node: Calcular métricas del catálogo]
  → total_products, total_skus, avg_price, min_price, max_price
  → has_discounts, discount_pct, top_collections
        ↓
[Code Node: Mapear industria → márgenes estimados]
  → Usar tabla MARGENES_INDUSTRIA
  → Calcular gap_mensual_estimado
        ↓
[Code Node: Generar insight_hook]
  → Texto < 300 chars con datos reales
        ↓
[Supabase UPDATE prospects]
  → Guardar todos los campos + products_enriched_at = NOW()
```

---

## Manejo de Errores

| Caso | Comportamiento |
| -- | -- |
| `/products.json` devuelve 404 | `shopify_products_accessible = false`, continuar |
| Catálogo vacío (0 productos) | `insight_hook = null`, loggear como "tienda sin productos" |
| `avg_price = 0` (productos gratis) | Excluir de cálculo de gap, usar solo conteo de SKUs en hook |
| Rate limiting del sitio | Retry con backoff 5s, máx 3 intentos |
| Industria no mapeada | Usar `'default'` en tabla de márgenes |

---

## Dependencias

* **Prerequisito:** AIR-21 / AIR-27 — Validación Shopify (necesita `shopify_confidence`)
* **Prerequisito:** AIR-25 / AIR-31 — Enriquecimiento Instagram (necesita `industry`)
* **Relacionado:** AIR-22 — Schema de prospects en Supabase (requiere ALTER TABLE)
* **Alimenta:** AIR-29 / AIR-33 — Alerta WhatsApp Tier A (el `insight_hook` va en el mensaje)

## Estimación

2 puntos (\~2 días de desarrollo)

---

## Riesgos / Edge Cases

* **Tiendas con contraseña activa:** Algunas tiendas tienen el storefront protegido — `/products.json` devuelve redirect a `/password`. Detectar y marcar como `shopify_products_accessible = false`
* **Precios en múltiples monedas:** Si `catalog_currency` no coincide con el país del prospecto, el cálculo del gap puede estar inflado/desinflado. V1 acepta esta imprecisión con advertencia en el hook
* **Catálogos muy grandes (>1000 SKUs):** Limitar paginación a 5 requests máximo (1250 productos) para no sobrecargar. Suficiente para las métricas
* **Insight hook genérico si falta industria:** Si `industry` es null, el hook dice "su categoría" en lugar del nombre real — aceptable pero menos impactante

---

## Tracking / Observabilidad

```javascript
// Loggear en tabla n8n_logs o campo jsonb en prospects
{
  "accion": "products_enriched",
  "prospect_id": uuid,
  "total_products": number,
  "avg_price": number,
  "industry": string,
  "insight_hook_generado": boolean,
  "shopify_accessible": boolean,
  "duracion_ms": number,
  "timestamp": ISO8601
}
```

### Comentarios

(ninguno)
