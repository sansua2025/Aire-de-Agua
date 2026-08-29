#!/usr/bin/env node
/**
 * check-n8n-repo-drift.mjs  —  AIR-146 job nocturno de drift repo↔n8n
 *
 * Compara los workflows VIVOS en n8n (vía API REST, solo lectura) contra los
 * JSON versionados en n8n/workflows/. Detecta que algo quedó "Done en repo pero
 * no desplegado" o un draft vivo que nunca se exportó.
 *
 * Reusa el patrón de acceso a la API de scripts/n8n-export.mjs (AIR-89):
 *   - env vars N8N_API_URL + N8N_API_KEY (sourcear el .env de la raíz del repo).
 *   - N8N_API_URL puede o no incluir /api/v1 (se normaliza).
 *
 * USO:
 *   set -a; . .env; set +a
 *   node scripts/check-n8n-repo-drift.mjs            # reporte humano
 *   node scripts/check-n8n-repo-drift.mjs --json     # reporte máquina (sin secretos)
 *
 * EXIT:
 *   0  → sin drift
 *   1  → drift detectado (ver reporte)
 *   2  → error de configuración/red
 *
 * SEGURIDAD (🚩):
 *   - SOLO LECTURA. Únicamente GET /workflows. Cero mutaciones.
 *   - NUNCA imprime secretos, credenciales, tokens ni la API key. El reporte solo
 *     contiene nombres de workflow, ids de workflow (no de credencial) y tipos de
 *     drift. Al comparar contenido se IGNORAN las credenciales por completo (el
 *     repo usa {id:"PLACEHOLDER"} y nombres distintos a los del vivo) para no
 *     marcar todo como driftado; se comparan name/type/parameters/jsCode y
 *     connections de los nodos.
 *
 * DEPENDENCIAS: Node.js >= 18 (fetch nativo). Sin deps externas.
 */

import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const REPO_DIR = resolve(__dirname, '..', 'n8n', 'workflows');

const JSON_OUT = process.argv.includes('--json');

const N8N_API_URL = process.env.N8N_API_URL;
const N8N_API_KEY = process.env.N8N_API_KEY;

if (!N8N_API_URL || !N8N_API_KEY) {
  console.error('Error: N8N_API_URL y N8N_API_KEY deben estar definidas (sourcea el .env de la raíz).');
  process.exit(2);
}

// Base normalizada: tolera N8N_API_URL con o sin /api/v1.
const API_BASE = (() => {
  const raw = N8N_API_URL.replace(/\/$/, '');
  return raw.endsWith('/api/v1') ? raw : `${raw}/api/v1`;
})();

// Redacción para lo que pueda acabar PUBLICADO. El reporte se captura con 2>&1 y
// viaja al CUERPO de un issue creado por API, donde el enmascarado de secrets de
// GitHub Actions NO aplica. Node emite "Failed to parse URL from <API_BASE>" ante
// una URL malformada: sin esto, N8N_BASE_URL quedaría publicado en el issue.
function redact(text) {
  let out = String(text ?? '');
  for (const s of [API_BASE, N8N_API_URL, N8N_API_URL.replace(/\/$/, ''), N8N_API_KEY]) {
    if (s && String(s).length >= 4) out = out.split(String(s)).join('<redactado>');
  }
  return out;
}

async function apiFetch(path) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'X-N8N-API-KEY': N8N_API_KEY, 'Accept': 'application/json' },
  });
  if (!res.ok) {
    // No incluir headers ni cuerpos que pudieran filtrar la key.
    throw new Error(`n8n API ${res.status} ${res.statusText} en ${path}`);
  }
  return res.json();
}

async function listLiveWorkflows() {
  let cursor = null;
  const all = [];
  do {
    const qs = cursor
      ? `?limit=200&cursor=${encodeURIComponent(cursor)}`
      : '?limit=200';
    const page = await apiFetch(`/workflows${qs}`);
    const items = Array.isArray(page.data) ? page.data : (Array.isArray(page) ? page : []);
    all.push(...items);
    cursor = page.nextCursor || null;
  } while (cursor);
  return all;
}

// --- Normalización para comparación de contenido ---
// Compara la "forma funcional" de cada nodo: name, type y parameters (incluye
// jsCode). Las CREDENCIALES se ignoran POR COMPLETO: el repo usa
// {id:"PLACEHOLDER"} y el vivo ids reales, y además el NOMBRE de la misma
// credencial difiere entre entornos (p.ej. "Supabase AdeA" en repo vs
// "Header Auth Supabase" en vivo). Son una preocupación de despliegue, no de
// lógica del workflow; incluirlas marcaría casi todo como driftado (falso
// positivo). El binding de credenciales se valida en otra parte (export AIR-89).
function normalizeNode(node) {
  return {
    name: node.name ?? null,
    type: node.type ?? null,
    parameters: node.parameters ?? {},
  };
}

function normalizeGraph(wf) {
  const nodes = Array.isArray(wf.nodes) ? wf.nodes : [];
  // Ordenar por nombre para que el orden del array no genere falsos positivos.
  const normNodes = nodes
    .map(normalizeNode)
    .sort((a, b) => String(a.name).localeCompare(String(b.name)));
  return {
    nodes: normNodes,
    connections: wf.connections ?? {},
  };
}

// JSON canónico (claves ordenadas recursivamente) → hash estable.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}

function graphHash(wf) {
  return createHash('sha256').update(canonical(normalizeGraph(wf))).digest('hex');
}

// Diff legible de nodos entre dos grafos normalizados (para el reporte).
function nodeDiffSummary(repoWf, liveWf) {
  const repoNodes = new Map(normalizeGraph(repoWf).nodes.map((n) => [n.name, n]));
  const liveNodes = new Map(normalizeGraph(liveWf).nodes.map((n) => [n.name, n]));
  const onlyRepo = [...repoNodes.keys()].filter((n) => !liveNodes.has(n));
  const onlyLive = [...liveNodes.keys()].filter((n) => !repoNodes.has(n));
  const changed = [];
  for (const [name, rn] of repoNodes) {
    const ln = liveNodes.get(name);
    if (ln && canonical(rn) !== canonical(ln)) changed.push(name);
  }
  const connectionsDiffer =
    canonical(repoWf.connections ?? {}) !== canonical(liveWf.connections ?? {});
  return { onlyRepo, onlyLive, changed, connectionsDiffer };
}

// --- Carga de workflows del repo ---
function loadRepoWorkflows() {
  // `.sort()`: el orden de readdirSync depende del FS. El reporte se hashea para
  // decidir si se notifica; un orden inestable cambiaría el hash sin cambiar el drift.
  const files = readdirSync(REPO_DIR).filter((f) => f.endsWith('.json')).sort();
  const out = [];
  for (const file of files) {
    let wf;
    try {
      wf = JSON.parse(readFileSync(join(REPO_DIR, file), 'utf8'));
    } catch (err) {
      out.push({ file, name: null, parseError: err.message, wf: null });
      continue;
    }
    out.push({ file, name: wf.name ?? null, parseError: null, wf });
  }
  return out;
}

// --- Main ---
async function main() {
  const live = await listLiveWorkflows();
  const repo = loadRepoWorkflows();

  const liveById = new Map(live.map((w) => [w.id, w]));
  const liveByName = new Map();
  for (const w of live) {
    if (!liveByName.has(w.name)) liveByName.set(w.name, []);
    liveByName.get(w.name).push(w);
  }
  const repoByName = new Map();
  for (const r of repo) {
    if (r.name == null) continue;
    if (!repoByName.has(r.name)) repoByName.set(r.name, []);
    repoByName.get(r.name).push(r);
  }

  const drift = {
    parseErrors: [],      // archivos del repo que no parsean
    liveSinRepo: [],      // (a)
    repoSinLive: [],      // (b)
    contenido: [],        // (c)
    errorWorkflowFantasma: [], // (d)
    draftNeqRunning: [],  // (e)
  };

  // Archivos que no parsean (no es un tipo "oficial" pero hay que reportarlo).
  for (const r of repo) {
    if (r.parseError) drift.parseErrors.push({ file: r.file, error: r.parseError });
  }

  // (a) live sin repo
  for (const w of live) {
    if (!repoByName.has(w.name)) {
      drift.liveSinRepo.push({ id: w.id, name: w.name, active: !!w.active });
    }
  }

  // (b) repo sin live
  for (const [name, entries] of repoByName) {
    if (!liveByName.has(name)) {
      drift.repoSinLive.push({ name, files: entries.map((e) => e.file) });
    }
  }

  // (c) drift de contenido (solo para nombres presentes en ambos lados)
  for (const [name, entries] of repoByName) {
    const liveMatches = liveByName.get(name);
    if (!liveMatches) continue;
    // Si hay duplicados de un mismo lado, lo dejamos explícito y comparamos 1:1
    // contra la primera coincidencia viva (orden de la API).
    for (const entry of entries) {
      if (!entry.wf) continue;
      const liveWf = liveMatches[0];
      if (graphHash(entry.wf) !== graphHash(liveWf)) {
        const d = nodeDiffSummary(entry.wf, liveWf);
        drift.contenido.push({
          name,
          file: entry.file,
          liveId: liveWf.id,
          ambiguousLive: liveMatches.length > 1,
          ambiguousRepo: entries.length > 1,
          ...d,
        });
      }
    }
  }

  // (d) errorWorkflow fantasma: settings.errorWorkflow en un workflow VIVO que
  //     apunta a un id que no existe entre los workflows vivos.
  for (const w of live) {
    const ref = w.settings && w.settings.errorWorkflow;
    if (ref && !liveById.has(ref)) {
      drift.errorWorkflowFantasma.push({ id: w.id, name: w.name, errorWorkflow: ref });
    }
  }

  // (e) draft != running: workflow vivo con versionId distinto de activeVersionId.
  for (const w of live) {
    // Solo aplica si ambos campos existen (workflows con versionado activo).
    if (w.versionId && w.activeVersionId && w.versionId !== w.activeVersionId) {
      drift.draftNeqRunning.push({ id: w.id, name: w.name, active: !!w.active });
    }
  }

  const total =
    drift.parseErrors.length +
    drift.liveSinRepo.length +
    drift.repoSinLive.length +
    drift.contenido.length +
    drift.errorWorkflowFantasma.length +
    drift.draftNeqRunning.length;

  // ORDEN ESTABLE DEL REPORTE. Las secciones (a), (d) y (e) se construyen iterando
  // la respuesta de `GET /workflows`, cuyo orden la API no garantiza. El consumidor
  // del reporte (.github/workflows/n8n-drift.yml) lo hashea con sha256 para decidir
  // si COMENTA el issue: sin un orden determinista el hash cambiaría sin que cambie
  // el drift y el issue recibiría un comentario cada noche — justo el ruido que el
  // anti-spam existe para evitar.
  const by = (key) => (a, b) => String(key(a)).localeCompare(String(key(b)));
  drift.parseErrors.sort(by((e) => e.file));
  drift.liveSinRepo.sort(by((w) => `${w.name}\u0000${w.id}`));
  drift.repoSinLive.sort(by((w) => w.name));
  for (const r of drift.repoSinLive) r.files.sort();
  drift.contenido.sort(by((d) => `${d.name}\u0000${d.file}\u0000${d.liveId}`));
  drift.errorWorkflowFantasma.sort(by((w) => `${w.name}\u0000${w.id}`));
  drift.draftNeqRunning.sort(by((w) => `${w.name}\u0000${w.id}`));

  if (JSON_OUT) {
    console.log(JSON.stringify({ total, counts: countsOf(drift), drift }, null, 2));
  } else {
    printReport(drift, { liveCount: live.length, repoCount: repo.length });
  }

  process.exit(total > 0 ? 1 : 0);
}

function countsOf(drift) {
  return {
    parseErrors: drift.parseErrors.length,
    liveSinRepo: drift.liveSinRepo.length,
    repoSinLive: drift.repoSinLive.length,
    contenido: drift.contenido.length,
    errorWorkflowFantasma: drift.errorWorkflowFantasma.length,
    draftNeqRunning: drift.draftNeqRunning.length,
  };
}

function printReport(drift, meta) {
  const L = [];
  L.push('# Drift repo↔n8n (AIR-146)');
  L.push('');
  L.push(`Workflows vivos: ${meta.liveCount} · Archivos en repo: ${meta.repoCount}`);
  L.push('');

  const section = (title, items, render) => {
    L.push(`## ${title} — ${items.length}`);
    if (items.length === 0) {
      L.push('OK — sin drift.');
    } else {
      for (const it of items) L.push(`- ${render(it)}`);
    }
    L.push('');
  };

  if (drift.parseErrors.length) {
    section('JSON inválido en repo', drift.parseErrors, (e) => `${e.file}: ${e.error}`);
  }

  section('(a) Vivo sin respaldo en repo', drift.liveSinRepo, (w) =>
    `"${w.name}" (id ${w.id}${w.active ? ', activo' : ', inactivo'})`);

  section('(b) Repo sin workflow vivo (¿no desplegado / renombrado?)', drift.repoSinLive, (w) =>
    `"${w.name}" → ${w.files.join(', ')}`);

  section('(c) Drift de contenido (nodos/jsCode/connections; ignora credenciales)', drift.contenido, (d) => {
    const bits = [];
    if (d.onlyRepo.length) bits.push(`solo-repo: ${d.onlyRepo.join(', ')}`);
    if (d.onlyLive.length) bits.push(`solo-vivo: ${d.onlyLive.join(', ')}`);
    if (d.changed.length) bits.push(`cambiados: ${d.changed.join(', ')}`);
    if (d.connectionsDiffer) bits.push('connections difieren');
    const flags = [];
    if (d.ambiguousLive) flags.push('⚠ múltiples vivos con este name');
    if (d.ambiguousRepo) flags.push('⚠ múltiples archivos repo con este name');
    return `"${d.name}" (${d.file} vs id ${d.liveId})${flags.length ? ' [' + flags.join('; ') + ']' : ''}: ${bits.join(' | ') || 'difieren'}`;
  });

  section('(d) errorWorkflow fantasma (apunta a id vivo inexistente)', drift.errorWorkflowFantasma, (w) =>
    `"${w.name}" (id ${w.id}) → errorWorkflow="${w.errorWorkflow}" no existe`);

  section('(e) Draft ≠ running (versionId ≠ activeVersionId)', drift.draftNeqRunning, (w) =>
    `"${w.name}" (id ${w.id}${w.active ? ', activo' : ', inactivo'})`);

  const total =
    drift.parseErrors.length + drift.liveSinRepo.length + drift.repoSinLive.length +
    drift.contenido.length + drift.errorWorkflowFantasma.length + drift.draftNeqRunning.length;

  L.push('---');
  L.push(total > 0 ? `RESULTADO: ${total} item(s) de drift.` : 'RESULTADO: sin drift.');

  console.log(L.join('\n'));
}

main().catch((err) => {
  console.error('Fatal:', redact(err && err.message ? err.message : err));
  process.exit(2);
});
