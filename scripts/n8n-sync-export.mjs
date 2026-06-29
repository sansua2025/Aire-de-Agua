#!/usr/bin/env node
/**
 * n8n-sync-export.mjs — Exporta workflows de n8n live al shape SANEADO del repo.
 *
 * Convención del repo (n8n/workflows/*.json):
 *   - Top-level: solo { name, nodes, connections, settings }
 *   - settings filtrado a { executionOrder, errorWorkflow } (solo las que existan)
 *   - credentials.<key>.id => "PLACEHOLDER" (nunca el id real); se conserva el name
 *   - Indent 2 espacios + newline final
 *
 * USO:
 *   node scripts/n8n-sync-export.mjs <workflowId> <rutaDestino> [<id2> <ruta2> ...]
 *
 * Requiere en el entorno: N8N_API_URL (incl. /api/v1), N8N_API_KEY
 * (source .env de la raíz del repo antes de ejecutar).
 *
 * SEGURIDAD: nunca persiste el id real de credenciales; falla si detecta uno.
 * DEPENDENCIAS: Node >= 18 (fetch nativo).
 */

import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');

const N8N_API_URL = process.env.N8N_API_URL;
const N8N_API_KEY = process.env.N8N_API_KEY;
if (!N8N_API_URL || !N8N_API_KEY) {
  console.error('Error: N8N_API_URL y N8N_API_KEY deben estar definidas en el entorno.');
  process.exit(1);
}

async function fetchWorkflow(id) {
  const url = `${N8N_API_URL.replace(/\/$/, '')}/workflows/${id}`;
  const res = await fetch(url, {
    headers: { 'X-N8N-API-KEY': N8N_API_KEY, Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`GET ${url} -> HTTP ${res.status}: ${await res.text()}`);
  }
  const data = await res.json();
  return data.data || data; // la API puede envolver en .data
}

function sanitize(wf) {
  const settings = {};
  if (wf.settings && typeof wf.settings === 'object') {
    if (wf.settings.executionOrder !== undefined) settings.executionOrder = wf.settings.executionOrder;
    if (wf.settings.errorWorkflow !== undefined) settings.errorWorkflow = wf.settings.errorWorkflow;
  }

  const nodes = (wf.nodes || []).map((node) => {
    if (node.credentials && typeof node.credentials === 'object') {
      const creds = {};
      for (const [key, cred] of Object.entries(node.credentials)) {
        creds[key] = { id: 'PLACEHOLDER' };
        if (cred && cred.name !== undefined) creds[key].name = cred.name;
      }
      return { ...node, credentials: creds };
    }
    return node;
  });

  return { name: wf.name, nodes, connections: wf.connections || {}, settings };
}

function assertNoRealCredIds(clean) {
  for (const node of clean.nodes) {
    if (!node.credentials) continue;
    for (const cred of Object.values(node.credentials)) {
      if (cred && cred.id !== 'PLACEHOLDER') {
        throw new Error(`Credencial con id real detectada en nodo "${node.name}": ${cred.id}`);
      }
    }
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 2 || args.length % 2 !== 0) {
    console.error('Uso: node scripts/n8n-sync-export.mjs <id> <ruta> [<id2> <ruta2> ...]');
    process.exit(1);
  }

  for (let i = 0; i < args.length; i += 2) {
    const id = args[i];
    const dest = resolve(REPO_ROOT, args[i + 1]);
    const wf = await fetchWorkflow(id);
    const clean = sanitize(wf);
    assertNoRealCredIds(clean);
    const out = JSON.stringify(clean, null, 2) + '\n';
    JSON.parse(out); // sanity re-parse
    writeFileSync(dest, out, 'utf8');
    console.log(`OK  ${id} -> ${args[i + 1]}  (${clean.nodes.length} nodes)`);
  }
}

main().catch((e) => {
  console.error('ERROR:', e.message);
  process.exit(1);
});
