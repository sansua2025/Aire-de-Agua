#!/usr/bin/env node
/**
 * n8n-export.mjs  —  AIR-89 GitOps export helper
 *
 * Exporta todos los workflows de n8n a n8n/workflows/<Nombre>.json
 * usando la API REST de n8n. Requiere credenciales por env vars.
 *
 * USO:
 *   N8N_API_URL=https://n8n.example.com N8N_API_KEY=<key> node scripts/n8n-export.mjs
 *
 * OPCIONES:
 *   --id <workflowId>   Exportar un solo workflow por ID
 *   --dry-run           Muestra qué exportaría sin escribir archivos
 *   --out <dir>         Directorio de salida (default: n8n/workflows)
 *
 * SEGURIDAD:
 *   - Nunca commitear N8N_API_KEY al repo.
 *   - El script no persiste credenciales; solo las lee desde el entorno.
 *   - Las credenciales en los JSONs exportados aparecen como
 *     {"id":"PLACEHOLDER","name":"..."} por diseño de n8n al exportar.
 *
 * DEPENDENCIAS: Node.js >= 18 (fetch nativo). Sin deps externas.
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

// --- Config ---
const N8N_API_URL = process.env.N8N_API_URL;
const N8N_API_KEY = process.env.N8N_API_KEY;

if (!N8N_API_URL || !N8N_API_KEY) {
  console.error('Error: N8N_API_URL y N8N_API_KEY deben estar definidas como env vars.');
  process.exit(1);
}

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const SINGLE_ID = (() => {
  const i = args.indexOf('--id');
  return i >= 0 ? args[i + 1] : null;
})();
const OUT_DIR = (() => {
  const i = args.indexOf('--out');
  return i >= 0 ? resolve(args[i + 1]) : resolve(__dirname, '..', 'n8n', 'workflows');
})();

// --- Helpers ---
function toPascalCase(name) {
  // Preserva prefijos tipo E2_, E3A_, E5K_, etc.
  return name.trim().replace(/[^a-zA-Z0-9_\- ]/g, '').replace(/[\s-]+/g, '_');
}

async function apiFetch(path) {
  const url = `${N8N_API_URL.replace(/\/$/, '')}/api/v1${path}`;
  const res = await fetch(url, {
    headers: {
      'X-N8N-API-KEY': N8N_API_KEY,
      'Accept': 'application/json',
    },
  });
  if (!res.ok) {
    throw new Error(`n8n API ${res.status} ${res.statusText} — ${url}`);
  }
  return res.json();
}

// --- Exportar un workflow por ID ---
async function exportWorkflow(id) {
  const data = await apiFetch(`/workflows/${id}`);
  const wf = data.data || data; // la API puede envolver en .data
  const name = toPascalCase(wf.name || id);
  const filename = `${name}.json`;
  const filepath = join(OUT_DIR, filename);
  const content = JSON.stringify(wf, null, 2);

  console.log(`  ${wf.active ? '[ACTIVO]' : '[inactivo]'} ${wf.name}  →  ${filename}`);

  if (!DRY_RUN) {
    writeFileSync(filepath, content + '\n', 'utf8');
  }
  return { id: wf.id, name: wf.name, filename, active: wf.active };
}

// --- Main ---
async function main() {
  console.log(`n8n-export.mjs`);
  console.log(`  URL: ${N8N_API_URL}`);
  console.log(`  Salida: ${OUT_DIR}`);
  console.log(`  Modo: ${DRY_RUN ? 'DRY RUN' : 'escritura real'}`);
  console.log('');

  if (!DRY_RUN) {
    mkdirSync(OUT_DIR, { recursive: true });
  }

  if (SINGLE_ID) {
    const result = await exportWorkflow(SINGLE_ID);
    console.log(`\nExportado: ${result.filename}`);
    return;
  }

  // Listar todos los workflows con paginacion
  let cursor = null;
  const allWorkflows = [];

  do {
    const qs = cursor ? `?cursor=${encodeURIComponent(cursor)}&limit=100` : '?limit=100';
    const page = await apiFetch(`/workflows${qs}`);
    const items = Array.isArray(page.data) ? page.data : (Array.isArray(page) ? page : []);
    allWorkflows.push(...items);
    cursor = (page.nextCursor) || null;
  } while (cursor);

  console.log(`Workflows encontrados: ${allWorkflows.length}`);
  console.log('');

  const results = [];
  for (const wf of allWorkflows) {
    try {
      const r = await exportWorkflow(wf.id);
      results.push(r);
    } catch (err) {
      console.error(`  ERROR exportando ${wf.id} (${wf.name}): ${err.message}`);
    }
  }

  const activos = results.filter(r => r.active).length;
  console.log('');
  console.log(`Exportados: ${results.length} workflows (${activos} activos, ${results.length - activos} inactivos)`);
  if (DRY_RUN) console.log('DRY RUN: no se escribieron archivos.');
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
