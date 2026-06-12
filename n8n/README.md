# n8n Workflows — Aire de Agua

Versión GitOps de los workflows productivos de n8n. Cada archivo `.json` es una copia fiel del workflow en n8n, con IDs de credenciales reemplazados por `"PLACEHOLDER"` para evitar filtrar secretos.

## Estructura

```
n8n/workflows/
  E2_*.json          — Capa de datos Shopify (webhooks + backfill + retry)
  E3A_*.json         — Sync Meta Ads
  E3B_*.json         — Sync Amplitude
  E3C_*.json         — Backfill UTM Amplitude
  E3D_*.json         — Organic visual enrichment
  E3E_*.json         — Klaviyo daily sync (campaigns + profiles + flow)
  E3_IG_*.json       — IG Posts semanal
  E4A_*.json         — Embeddings pipeline (brand_knowledge + productos)
  E4B_*.json         — Creative embeddings (ads Meta)
  E4C_*.json         — Paid visual descriptions via Claude vision
  E4D_*.json         — Instagram embeddings
  E4EA_*.json        — Product images sync desde Shopify
  E4EB_*.json        — Product visual embeddings (vision + fusion)
  E4EC_*.json        — Creative-product semantic matcher
  E4F_*.json         — COGS sync desde Shopify GraphQL
  E5A_*.json         — Loop weekly analysis + Shopify journeys backfill
  E5B_*.json         — Shopify journey daily sync
  E5K_*.json         — Knowledge consolidation (mensual, inactivo)
  E5_Loop_*.json     — Loop closer diario + health check + insights decay
  Sentinela_v1.json  — Senales del sistema → issues Linear agent-ready (AIR-99)
```

## Inventario (31 workflows)

| Archivo | ID n8n | Activo | Descripcion |
|---------|--------|--------|-------------|
| E2B_Product_Sync_To_Shopify | — | — | Sync productos hacia Shopify |
| E2_Backfill_Historico_Shopify | `fcNTDNNiYXqpxwlF` | false | Backfill manual productos + ordenes |
| E2_Retry_Huerfanos | `xuxjBhMssAXSLJju` | true | Retry venta_items con variante_id NULL (AIR-63) |
| E2_Webhook_Shopify_Customers | `DQ4tVkCbtnp4KDX4` | true | Webhook customers create/update |
| E2_Webhook_Shopify_Inventory | `RDp3C304UGnJmIOs` | true | Webhook inventory_levels update |
| E2_Webhook_Shopify_Orders | `TChWc5Jc6R8JUUyZ` | true | Webhook orders create/updated |
| E2_Webhook_Shopify_Products | `pjJT4JKv27IE4aTx` | true | Webhook products create/update + trigger E4A |
| E3A_Meta_Ads_Backfill | — | — | Backfill historico Meta Ads |
| E3A_Meta_Ads_Daily_Sync | — | — | Sync diario Meta Ads |
| E3B_Amplitude_Daily_Sync | — | — | Sync diario Amplitude |
| E3C_Backfill_Amplitude_UTM | — | — | Backfill UTM Amplitude |
| E3D_Organic_Visual_Enrichment | — | — | Enriquecimiento visual organic |
| E3E_Klaviyo_Daily_Sync | `F9pncjlVfCmBTHab` | true | Klaviyo: campaigns + profiles + flow_daily |
| E3_IG_Posts_Semanal | — | — | IG posts semanal |
| E4A_Embeddings_Pipeline | `8Og2ICgiKKHz2Fu4` | true | Embeddings brand_knowledge + productos |
| E4B_Creative_Embeddings | `9PPS7Sy9YnaQdUzW` | true | Embeddings creativos Meta Ads |
| E4C_Paid_Visual_Descriptions | `Qi2XfUxioVNknVKB` | true | Descripciones visuales via Claude vision |
| E4D_Instagram_Embeddings | — | — | Embeddings posts Instagram |
| E4EA_Product_Images_Sync | `o5VYzfH53UY78Gyd` | true | Sync imagenes productos desde Shopify |
| E4EB_Product_Visual_Embeddings | `Oiubt4y4BEOUDrGr` | true | Vision + embeddings product_images + fusion |
| E4EC_Creative_Product_Matcher | `CVF6WSI7K1rQqLI5` | true | Match semantico creatives → producto |
| E4F_COGS_Shopify_Sync | `lY2hYkpVjt7BFn0Y` | true | COGS variantes desde Shopify GraphQL |
| E5A_Loop_Weekly_Analysis | `9uDRQuIEOjKwRfYF` | true | Loop semanal analisis E5-C v2 |
| E5A_Shopify_Journeys_Backfill | `gH4dzWln6bbswyHU` | false | Backfill journeys Shopify (manual) |
| E5B_Shopify_Journey_Daily_Sync | `IfMV3I62PPIO6WpB` | true | Journey diario Shopify |
| E5K_Knowledge_Consolidation | — | — | Knowledge consolidation (version anterior) |
| E5K_Loop_Knowledge_Consolidation | `Boxt57xlMD09FJ9l` | false | E5-K mensual: Claude+OpenAI+Gmail+dedup |
| E5_Loop_Closer_Daily | `GuopyIlOL1z4FPXM` | true | Loop closer diario 8am COT |
| E5_Loop_Health_Check | `9NJ9rL5opJVneBSv` | true | Health check diario 9am COT |
| E5_Loop_Insights_Decay | `4OI0n6oZ4hoVEO7L` | true | Decay insights mensual |
| Sentinela_v1 | `Aul2pyDbdIECaBhY` | false | AIR-99: 3 senales (n8n fails + sync_log gap + drift) → issues Linear AIR con label agent-ready + dedupe por titulo |

## Actualizar un workflow

Usa el script de export para actualizar uno o todos:

```bash
# Exportar todos los workflows
N8N_API_URL=https://n8n.airedeagua.com N8N_API_KEY=$N8N_API_KEY \
  node scripts/n8n-export.mjs

# Exportar un workflow especifico por ID
N8N_API_URL=https://n8n.airedeagua.com N8N_API_KEY=$N8N_API_KEY \
  node scripts/n8n-export.mjs --id 9uDRQuIEOjKwRfYF

# Ver que exportaria sin escribir
N8N_API_URL=https://n8n.airedeagua.com N8N_API_KEY=$N8N_API_KEY \
  node scripts/n8n-export.mjs --dry-run
```

Luego commitear los archivos modificados con el formato:
```
feat(gitops): actualizar <Nombre> (AIR-XX)
```

## Seguridad

- Los JSONs exportados nunca contienen claves secretas. n8n reemplaza valores de credenciales por referencias `{"id":"PLACEHOLDER","name":"..."}` al exportar.
- Verificar antes de cada PR: `grep -rIE "sb_secret|sk-|eyJ[A-Za-z0-9]{20}" n8n/workflows/`
- `N8N_API_KEY` solo en variables de entorno locales o CI secrets, nunca en archivos del repo.

## Dependencias del script

- Node.js >= 18 (fetch nativo, sin npm install)
- Env vars: `N8N_API_URL`, `N8N_API_KEY`
