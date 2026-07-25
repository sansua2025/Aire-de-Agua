# AIR-239 — Rollback del jsCode de E5A (Build Prompt / Parse Claude)

Guardrail (AIR-239, human-gate). Snapshot del jsCode **ANTES** de los cambios de
F1-b ("el LLM narra sobre hechos"), leido de `origin/main` (commit base
`c0637d2`). Si hay que revertir en caliente el workflow vivo `9uDRQuIEOjKwRfYF`
sin re-importar el JSON entero, pega estos cuerpos en los nodos correspondientes.

> El workflow vivo puede traer una copia `activeVersion.nodes` (AIR-140). Si es
> asi, aplica el rollback en AMBAS copias del nodo.

## Nodo `Build Prompt (sanitized)` (id `cd185aa9-fc2b-4958-9059-2317d3a830dc`) — jsCode ORIGINAL

```javascript
const week = $('Set Week Config').first().json;
const snapshot = $('RPC compute_weekly_snapshot').first().json;
const anomalias = $('RPC detect_anomalies').first().json;
const memoria = $('RPC get_memoria_activa').first().json;

function sanitize(s, maxLen) {
  if (s == null) return null;
  maxLen = maxLen || 200;
  const str = String(s).replace(/[\x00-\x1F\x7F]/g, ' ').replace(/<[^>]*>/g, '');
  return str.length > maxLen ? str.slice(0, maxLen) + '...' : str;
}

function sanitizeInsight(ins) {
  return {
    dominio: sanitize(ins.dominio, 30),
    tipo: sanitize(ins.tipo, 30),
    titulo: sanitize(ins.titulo, 200),
    descripcion: sanitize(ins.descripcion, 500),
    score_confianza: ins.score_confianza,
    veces_confirmado: ins.veces_confirmado,
    accion_sugerida: sanitize(ins.accion_sugerida, 300)
  };
}

function sanitizeResuelta(r) {
  return {
    insight_key: sanitize(r.insight_key, 60),
    titulo: sanitize(r.titulo, 200),
    nota_resolucion: sanitize(r.nota_resolucion, 300),
    fecha: r.fecha
  };
}

const ultimoSnapshotRaw = (memoria && memoria.ultimo_snapshot) || null;
const ultimoSnapshotSanitized = ultimoSnapshotRaw ? Object.assign({}, ultimoSnapshotRaw, { resumen: sanitize(ultimoSnapshotRaw.resumen, 600) }) : null;

const memoriaSanitized = {
  insights: ((memoria && memoria.insights) || []).map(sanitizeInsight),
  creative_learnings: ((memoria && memoria.creative_learnings) || []).map(function(l) {
    return {
      elemento: sanitize(l.elemento, 30),
      valor: sanitize(l.valor, 100),
      canal: l.canal,
      indice_rendimiento: l.indice_rendimiento,
      score_confianza: l.score_confianza,
      muestra_anuncios: l.muestra_anuncios
    };
  }),
  ultimo_snapshot: ultimoSnapshotSanitized,
  condiciones_resueltas: ((memoria && memoria.condiciones_resueltas) || []).map(sanitizeResuelta)
};

const snapshotSanitized = JSON.parse(JSON.stringify(snapshot || {}));
((snapshotSanitized && snapshotSanitized.top_ads) || []).forEach(function(a) {
  if (a == null) return;
  if (a.ad_name != null) a.ad_name = sanitize(a.ad_name, 80);
  if (a.campaign_name != null) a.campaign_name = sanitize(a.campaign_name, 80);
  if (a.adset_name != null) a.adset_name = sanitize(a.adset_name, 80);
  if (a.objetivo != null) a.objetivo = sanitize(a.objetivo, 60);
  if (a.audiencia != null) a.audiencia = sanitize(a.audiencia, 60);
});
((snapshotSanitized && snapshotSanitized.top_productos) || []).forEach(function(p) {
  if (p == null) return;
  if (p.producto_titulo != null) p.producto_titulo = sanitize(p.producto_titulo, 120);
});
((snapshotSanitized && snapshotSanitized.mix_canal_web) || []).forEach(function(m) {
  if (m == null) return;
  if (m.canal_tipo != null) m.canal_tipo = sanitize(m.canal_tipo, 30);
});

const brandCfg = $('RPC get_brand_config').first().json;
const systemPrompt = brandCfg.persona_system;

const schema = JSON.stringify({
  resumen_ai: 'string 3 oraciones',
  insights: [{
    dominio: 'ventas|paid|web|cliente|producto|general',
    tipo: 'patron|oportunidad|riesgo|anomalia|logro',
    insight_key: 'slug snake_case estable de la CONDICION, sin semana/fecha/valores; reutiliza el mismo si ya se detecto antes. Ej: klaviyo_canal_apagado, cvr_web_critico, roas_real_paid',
    requiere_del_humano: 'decidir_urgente|informacion|celebrar|nada. Triage conservador: decidir_urgente solo si es accionable y de alto impacto; logro relevante=celebrar; por defecto informacion. NUNCA aprobar.',
    titulo: 'string',
    descripcion: 'string',
    metrica_clave: 'string',
    valor_observado: 'number',
    valor_referencia: 'number|null',
    delta_pct: 'number|null',
    score_confianza: '0-1',
    accion_sugerida: 'string',
    signo_predicho: 'sube|baja|null - si se toma la accion_sugerida, deberia la metrica_clave subir o bajar? null si no aplica'
  }],
  audience_actions: [{
    segmento: 'VIP|Recurrente|Nuevo|Riesgo|Dormant',
    accion_klaviyo: 'string',
    accion_meta: 'string',
    copy_angle: 'string'
  }],
  top_canal: 'string',
  top_ad_id: 'string|null'
}, null, 2);

const instruccionResueltas = memoriaSanitized.condiciones_resueltas.length > 0
  ? '\n\nIMPORTANTE: las condiciones listadas en MEMORIA.condiciones_resueltas ya NO aplican esta semana (fueron auto-resueltas por contradiccion contra datos frescos). NO las repitas como insight nuevo bajo ningun motivo, ni con el mismo insight_key ni con uno distinto. Si sigue siendo relevante mencionarlas, hazlo como una frase breve dentro de resumen_ai, nunca como insight con requiere_del_humano alto.'
  : '';

const userPrompt = 'Semana: ' + week.week_start + ' a ' + week.week_end + '\n\n<data>\n## SNAPSHOT (incluye roas_real, meta_funnel, top_ads, mix_canal_web, top_productos):\n' + JSON.stringify(snapshotSanitized, null, 2) + '\n\n## ANOMALIAS:\n' + JSON.stringify(anomalias, null, 2) + '\n\n## MEMORIA:\n' + JSON.stringify(memoriaSanitized, null, 2) + '\n</data>' + instruccionResueltas + '\n\nGenera el analisis en este JSON exacto:\n' + schema;

return [{ json: { system_prompt: systemPrompt, user_prompt: userPrompt, week_start: week.week_start, week_end: week.week_end, start_time: Date.now() } }];
```

## Nodo `Parse Claude + split insights` (id `a1b2d4c1-5270-42fb-8c19-a0125c9e3a20`) — jsCode ORIGINAL

```javascript
const claudeResp = $input.first().json;
const promptCtx = $('Build Prompt (sanitized)').first().json;
const text = (claudeResp && claudeResp.content && claudeResp.content[0] && claudeResp.content[0].text) || '';

let parsed;
try {
  parsed = JSON.parse(text);
} catch (e) {
  const m = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (m) parsed = JSON.parse(m[1].trim());
  else throw new Error('Claude response not valid JSON: ' + text.slice(0, 200));
}

const week_start = promptCtx.week_start;
const week_end = promptCtx.week_end;
const tokens = ((claudeResp.usage && claudeResp.usage.input_tokens) || 0) + ((claudeResp.usage && claudeResp.usage.output_tokens) || 0);
const duration_seconds = Math.round((Date.now() - promptCtx.start_time) / 1000);

const items = [{
  json: {
    item_kind: 'meta',
    week_start: week_start,
    week_end: week_end,
    tokens: tokens,
    duration_seconds: duration_seconds,
    resumen_ai: parsed.resumen_ai || '',
    insights_count: (parsed.insights || []).length,
    audience_actions: parsed.audience_actions || [],
    top_canal: parsed.top_canal || null,
    top_ad_id: parsed.top_ad_id || null
  }
}];

for (const ins of (parsed.insights || [])) {
  items.push({
    json: {
      item_kind: 'insight',
      insight_payload: Object.assign({}, ins, { periodo_inicio: week_start, periodo_fin: week_end })
    }
  });
}

return items;
```

## Qué cambió en el PR (para revertir de forma dirigida)
- `Build Prompt (sanitized)`: nueva seccion `## HECHOS` dentro de `<data>` con el
  jsonb normalizado de `analytics_evaluate_detectors`; regla de restriccion de
  `insight_key` en el schema; se anexa `hechos` al output del nodo. Se preservan
  intactos `sanitize()`, `snapshotSanitized` (AIR-119) y la persona defensiva.
- `Parse Claude + split insights`: validador post-parse (espejo de
  `dashboard/evals/cerebro/validate-insights.ts`) que acepta solo insights
  respaldados por un HECHO disparado+muestra_suficiente (numeros iguales) o una
  hipotesis (`hipotesis_*`, score<=0.5, max 1); taggea `fuente`; loguea descartes.
- Nodo NUEVO `RPC evaluate_detectors` (httpRequest a
  `/rest/v1/rpc/analytics_evaluate_detectors`) cableado entre `RPC get_brand_config`
  y `Build Prompt (sanitized)`. Para revertir: eliminar el nodo y recablear
  `RPC get_brand_config -> Build Prompt (sanitized)`.
- `Render Email HTML`: badge de `fuente` por insight (cambio cosmetico).
