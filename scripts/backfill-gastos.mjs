#!/usr/bin/env node
/**
 * backfill-gastos.mjs  —  AIR-166 · Backfill BigQuery/Firestore → tabla `gastos`
 *
 * Toma un export LOCAL de la tabla BigQuery
 *   `adea-d2c-analytics.firebase_expense.app_expenses`
 * (NDJSON / JSONL / JSON-array / CSV) y emite un `.sql` IDEMPOTENTE que un
 * humano revisa y aplica sobre PROD. El script NUNCA escribe a la base de datos
 * ni a BigQuery: solo lee un archivo local y produce SQL.
 *
 * Contrato destino: migración 106_air164_app_gastos_schema.sql
 *   gastos(id, concepto, categoria_id FK, monto numeric(14,2)>0, fecha date,
 *          pagador_id FK, recibo_path, creado_por, created_at, updated_at,
 *          firestore_id UNIQUE)
 *
 * DECISIONES (Santiago, 2026-07-03):
 *   - Se migra TODO el export (incl. los 7 egresos con userId 2/3 que la UI
 *     vieja ocultaba: son gastos reales).
 *   - El .sql es idempotente: INSERT ... ON CONFLICT (firestore_id) DO NOTHING.
 *   - Corte: snapshot completo del export al día de ejecución; re-corridas
 *     idempotentes capturan rezagados.
 *
 * MAPEOS (diccionario explícito; FALLA RUIDOSAMENTE ante valor desconocido):
 *   category → categoria_id (13 slugs del seed)
 *   paidBy   → pagador_id  ('Aire de Agua'→aire_de_agua, 'Santi&Susi'→santi_susi)
 *
 * FECHA: derivada del timestamp en zona America/Bogota (UTC-5, sin DST).
 *   ~24 filas cambian de día contable vs UTC → NUNCA tomar la fecha en UTC.
 *
 * USO:
 *   node scripts/backfill-gastos.mjs --input <archivo>            # dry-run (default)
 *   node scripts/backfill-gastos.mjs --input <archivo> --out backfill.sql
 *
 * OPCIONES:
 *   --input <ruta>   Export local de BQ (requerido). .ndjson/.jsonl/.json/.csv
 *   --out <ruta>     Emite el .sql idempotente a esa ruta (sino: dry-run)
 *   --dry-run        Solo plan + validación, sin emitir (comportamiento por defecto)
 *   --help           Ayuda
 *
 * SEGURIDAD / DATOS:
 *   - El export y el .sql emitido contienen datos financieros → NUNCA se
 *     commitean (ver .gitignore: scripts/.data/, *.gastos.*, backfill*.sql).
 *   - El script no hace red ni escribe a PROD. Solo lee --input y (opcional)
 *     escribe --out.
 *
 * DEPENDENCIAS: Node.js >= 18. Sin deps externas.
 */

import { readFileSync, writeFileSync } from 'node:fs';

// ============================================================================
// Diccionarios de mapeo (fuente: seed de la migración 106). Sin fallbacks
// silenciosos: cualquier valor fuera de estas tablas ABORTA la corrida.
// ============================================================================

// category (BQ) → categoria_id (slug). Se aceptan tanto los nombres de
// display del seed como los slugs, normalizados (trim + minúsculas + espacios
// colapsados). Cualquier otra cosa es un error ruidoso.
const CATEGORIA_MAP = {
  'gastos fijos': 'gastos_fijos', 'gastos_fijos': 'gastos_fijos',
  'operations': 'operations',
  'feria': 'feria',
  'publicidad': 'publicidad',
  'fotos': 'fotos',
  'otros': 'otros',
  'shopify': 'shopify',
  'replit': 'replit',
  'pixlr': 'pixlr',
  'marketing automation': 'marketing_automation', 'marketing_automation': 'marketing_automation',
  'shipping': 'shipping',
  'cogs': 'cogs',
  'assets': 'assets',
};

// paidBy (BQ) → pagador_id. Tolera variantes de espacios/case y de '&' con o
// sin espacios ('Santi&Susi' == 'Santi & Susi'), pero SOLO para estos 2.
const PAGADOR_MAP = {
  'aire de agua': 'aire_de_agua', 'aire_de_agua': 'aire_de_agua',
  'santi&susi': 'santi_susi', 'santi_susi': 'santi_susi',
};

// Nombres de columna candidatos en el export (BQ/Firestore varían). Se resuelve
// el primero presente; si ninguno aparece → error ruidoso indicando la fila.
const FIELD_CANDIDATES = {
  concepto:    ['concepto', 'concept', 'description', 'descripcion', 'desc', 'detalle', 'name', 'title'],
  amount:      ['amount', 'monto', 'value', 'valor', 'total'],
  category:    ['category', 'categoria', 'category_name', 'categoryName'],
  paidBy:      ['paidBy', 'paid_by', 'pagador', 'payer'],
  timestamp:   ['date', 'fecha', 'timestamp', 'createdAt', 'created_at', 'time', 'datetime'],
  firestoreId: ['firestoreId', 'firestore_id', 'documentId', 'document_id', 'docId', 'doc_id', 'id', '_id'],
};

const CREADO_POR = 'backfill@migracion';
const TZ = 'America/Bogota';

// Orden de columnas del INSERT (usado también por el round-trip de validación).
const COLS = ['concepto', 'categoria_id', 'monto', 'fecha', 'pagador_id', 'creado_por', 'firestore_id'];
const IDX = Object.fromEntries(COLS.map((c, i) => [c, i]));

// ============================================================================
// Utilidades
// ============================================================================

function fail(msg) {
  console.error('\nERROR: ' + msg + '\n');
  process.exit(1);
}

const normCat = (s) => String(s).trim().toLowerCase().replace(/\s+/g, ' ');
const normPag = (s) => String(s).trim().toLowerCase().replace(/\s*&\s*/g, '&').replace(/\s+/g, ' ');

// Resuelve el primer campo candidato presente (valor no vacío). devuelve
// { key, value } o null si ninguno está.
function resolveField(row, candidates) {
  for (const k of candidates) {
    if (Object.prototype.hasOwnProperty.call(row, k)) {
      const v = row[k];
      if (v !== null && v !== undefined && String(v).trim() !== '') {
        return { key: k, value: v };
      }
    }
  }
  return null;
}

// Convierte un valor de timestamp (string ISO, epoch seg/ms, o {_seconds}/{value})
// a milisegundos epoch. Falla ruidosamente si no se puede interpretar.
function toEpochMs(raw, ctx) {
  if (raw && typeof raw === 'object') {
    if (raw._seconds !== undefined) return Number(raw._seconds) * 1000 + Math.floor(Number(raw._nanoseconds || 0) / 1e6);
    if (raw.seconds !== undefined) return Number(raw.seconds) * 1000 + Math.floor(Number(raw.nanos || 0) / 1e6);
    if (raw.value !== undefined) return toEpochMs(raw.value, ctx);
    fail(`timestamp objeto no reconocido en ${ctx}: ${JSON.stringify(raw)}`);
  }
  if (typeof raw === 'number' || /^\d+(\.\d+)?$/.test(String(raw).trim())) {
    let n = Number(raw);
    // epoch en segundos (~1.7e9) vs milisegundos (~1.7e12) vs microsegundos.
    if (n < 1e12) n = n * 1000;          // segundos → ms
    else if (n > 1e15) n = Math.floor(n / 1000); // microsegundos → ms
    return n;
  }
  const s = String(raw).trim();
  // BQ suele exportar "YYYY-MM-DD HH:MM:SS UTC" o "YYYY-MM-DD HH:MM:SS.ssssss UTC".
  const bq = s.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(\.\d+)?\s*(UTC)?$/);
  let iso = s;
  if (bq) iso = `${bq[1]}T${bq[2]}${bq[3] || ''}Z`;
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) fail(`timestamp no parseable en ${ctx}: "${s}"`);
  return ms;
}

// epoch ms → 'YYYY-MM-DD' en zona America/Bogota (en-CA da formato ISO).
const _bogotaFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
});
function bogotaDate(epochMs) {
  return _bogotaFmt.format(new Date(epochMs)); // 'YYYY-MM-DD'
}

// Escapa un string para literal SQL de comillas simples (standard_conforming_strings on).
function sqlStr(v) {
  return "'" + String(v).replace(/'/g, "''") + "'";
}

// ============================================================================
// Parsers de entrada (dep-free)
// ============================================================================

// CSV con soporte de comillas dobles, comas y saltos de línea embebidos.
function parseCSV(text) {
  const rows = [];
  let field = '', record = [], inQuotes = false;
  const pushField = () => { record.push(field); field = ''; };
  const pushRecord = () => { rows.push(record); record = []; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += c;
    } else {
      if (c === '"') inQuotes = true;
      else if (c === ',') pushField();
      else if (c === '\r') { /* skip, handled by \n */ }
      else if (c === '\n') { pushField(); pushRecord(); }
      else field += c;
    }
  }
  // último campo/registro si el archivo no termina en newline
  if (field !== '' || record.length > 0) { pushField(); pushRecord(); }
  if (rows.length === 0) return [];
  const header = rows[0];
  return rows.slice(1)
    .filter((r) => !(r.length === 1 && r[0] === '')) // descartar líneas vacías
    .map((r) => Object.fromEntries(header.map((h, i) => [h, r[i]])));
}

function parseInput(path) {
  const raw = readFileSync(path, 'utf8');
  const lower = path.toLowerCase();
  if (lower.endsWith('.csv')) return parseCSV(raw);

  // JSON array o NDJSON/JSONL. Intentar array primero.
  const trimmed = raw.trim();
  if (trimmed.startsWith('[')) {
    const arr = JSON.parse(trimmed);
    if (!Array.isArray(arr)) fail('el JSON no es un array de objetos');
    return arr;
  }
  // NDJSON: una línea = un objeto JSON.
  const out = [];
  const lines = trimmed.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try { out.push(JSON.parse(line)); }
    catch (e) { fail(`línea ${i + 1} no es JSON válido: ${e.message}`); }
  }
  return out;
}

// ============================================================================
// Mapeo fila → registro destino
// ============================================================================

function mapRow(row, i) {
  const ctx = `fila #${i + 1}`;
  const errors = [];

  const fId = resolveField(row, FIELD_CANDIDATES.firestoreId);
  if (!fId) errors.push(`${ctx}: sin firestore_id (claves probadas: ${FIELD_CANDIDATES.firestoreId.join(', ')})`);
  const ref = fId ? `firestore_id=${fId.value}` : ctx;

  const catF = resolveField(row, FIELD_CANDIDATES.category);
  let categoria_id = null;
  if (!catF) errors.push(`${ref}: sin campo category`);
  else {
    categoria_id = CATEGORIA_MAP[normCat(catF.value)];
    if (!categoria_id) errors.push(`${ref}: category desconocida "${catF.value}" (no está en el diccionario de 13 slugs)`);
  }

  const pagF = resolveField(row, FIELD_CANDIDATES.paidBy);
  let pagador_id = null;
  if (!pagF) errors.push(`${ref}: sin campo paidBy`);
  else {
    pagador_id = PAGADOR_MAP[normPag(pagF.value)];
    if (!pagador_id) errors.push(`${ref}: paidBy desconocido "${pagF.value}" (esperado: Aire de Agua | Santi&Susi)`);
  }

  const amtF = resolveField(row, FIELD_CANDIDATES.amount);
  let monto = null;
  if (!amtF) errors.push(`${ref}: sin campo amount`);
  else {
    const n = Number(amtF.value);
    if (Number.isNaN(n)) errors.push(`${ref}: amount no numérico "${amtF.value}"`);
    else {
      monto = Math.round(n * 100) / 100;
      if (monto <= 0) errors.push(`${ref}: monto debe ser > 0 (recibido ${monto})`);
    }
  }

  const tsF = resolveField(row, FIELD_CANDIDATES.timestamp);
  let fecha = null;
  if (!tsF) errors.push(`${ref}: sin campo timestamp/date`);
  else fecha = bogotaDate(toEpochMs(tsF.value, ref));

  const conF = resolveField(row, FIELD_CANDIDATES.concepto);
  let concepto = null;
  if (!conF) errors.push(`${ref}: sin campo concepto/descripcion`);
  else {
    concepto = String(conF.value).trim();
    if (concepto === '') errors.push(`${ref}: concepto vacío`);
  }

  return {
    errors,
    resolved: {
      firestoreId: fId && fId.key, category: catF && catF.key, paidBy: pagF && pagF.key,
      amount: amtF && amtF.key, timestamp: tsF && tsF.key, concepto: conF && conF.key,
    },
    record: errors.length ? null : {
      concepto,
      categoria_id,
      monto,
      fecha,
      pagador_id,
      creado_por: CREADO_POR,
      firestore_id: String(fId.value),
    },
  };
}

// ============================================================================
// Emisión del .sql idempotente
// ============================================================================

function buildSQL(records, inputName) {
  const now = new Date().toISOString();
  const lines = [];
  lines.push('-- AIR-166 · Backfill BigQuery/Firestore → gastos');
  lines.push(`-- Generado: ${now}`);
  lines.push(`-- Fuente:   ${inputName}`);
  lines.push(`-- Filas:    ${records.length}`);
  lines.push('-- Idempotente: ON CONFLICT (firestore_id) DO NOTHING. Re-aplicable sin duplicar.');
  lines.push('-- Revisión humana obligatoria antes de aplicar a PROD.');
  lines.push('');
  lines.push('BEGIN;');
  lines.push('');
  lines.push('INSERT INTO gastos (' + COLS.join(', ') + ') VALUES');
  const tuples = records.map((r) => {
    return '  (' + [
      sqlStr(r.concepto),
      sqlStr(r.categoria_id),
      r.monto.toFixed(2),
      sqlStr(r.fecha),
      sqlStr(r.pagador_id),
      sqlStr(r.creado_por),
      sqlStr(r.firestore_id),
    ].join(', ') + ')';
  });
  lines.push(tuples.join(',\n'));
  lines.push('ON CONFLICT (firestore_id) DO NOTHING;');
  lines.push('');
  lines.push('COMMIT;');
  lines.push('');
  return lines.join('\n');
}

// ============================================================================
// Round-trip: re-parsea el .sql emitido y agrega por categoria_id, comparando
// contra la agregación de los registros. Detecta corrupción de escape/rounding.
// ============================================================================

function parseValuesTuples(sql) {
  // Aislar el bloque entre 'VALUES' y 'ON CONFLICT' para no leer la lista de
  // columnas del INSERT como si fuera una tupla.
  // 'VALUES' del INSERT (no aparece en los comentarios de cabecera). 'ON CONFLICT'
  // se busca DESPUÉS de VALUES porque también aparece en un comentario de cabecera.
  const start = sql.indexOf('VALUES');
  const end = start >= 0 ? sql.indexOf('ON CONFLICT', start) : -1;
  if (start < 0 || end < 0) fail('round-trip: no se encontró bloque VALUES ... ON CONFLICT');
  const body = sql.slice(start + 'VALUES'.length, end);

  const tuples = [];
  let depth = 0, inStr = false, field = '', fields = null;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (inStr) {
      if (c === "'") {
        if (body[i + 1] === "'") { field += "'"; i++; }
        else inStr = false;
      } else field += c;
      continue;
    }
    if (c === "'") { inStr = true; continue; }
    if (c === '(') { depth++; if (depth === 1) { fields = []; field = ''; } continue; }
    if (c === ')') {
      if (depth === 1) { fields.push(field.trim()); tuples.push(fields); fields = null; field = ''; }
      depth--; continue;
    }
    if (depth === 1) {
      if (c === ',') { fields.push(field.trim()); field = ''; }
      else field += c;
    }
  }
  return tuples;
}

// Suma en centavos (enteros) para comparar sin ruido de float.
function aggregate(rowsAsPairs) {
  // rowsAsPairs: [{categoria_id, montoNum}]
  const m = new Map();
  for (const { categoria_id, montoNum } of rowsAsPairs) {
    const cur = m.get(categoria_id) || { count: 0, cents: 0 };
    cur.count += 1;
    cur.cents += Math.round(montoNum * 100);
    m.set(categoria_id, cur);
  }
  return m;
}

function validateRoundTrip(records, sql) {
  const expected = aggregate(records.map((r) => ({ categoria_id: r.categoria_id, montoNum: r.monto })));
  const tuples = parseValuesTuples(sql);
  if (tuples.length !== records.length) {
    fail(`round-trip: el .sql tiene ${tuples.length} tuplas pero hay ${records.length} registros`);
  }
  const actual = aggregate(tuples.map((t) => ({
    categoria_id: t[IDX.categoria_id],
    montoNum: Number(t[IDX.monto]),
  })));

  const cats = new Set([...expected.keys(), ...actual.keys()]);
  const table = [];
  let ok = true;
  for (const cat of [...cats].sort()) {
    const e = expected.get(cat) || { count: 0, cents: 0 };
    const a = actual.get(cat) || { count: 0, cents: 0 };
    const match = e.count === a.count && e.cents === a.cents;
    if (!match) ok = false;
    table.push({
      categoria_id: cat,
      count: e.count,
      sum_monto: (e.cents / 100).toFixed(2),
      sql_count: a.count,
      sql_sum: (a.cents / 100).toFixed(2),
      match: match ? 'ok' : 'MISMATCH',
    });
  }
  return { ok, table };
}

// ============================================================================
// Reporte / plan
// ============================================================================

function printPlan(records) {
  const byCat = aggregate(records.map((r) => ({ categoria_id: r.categoria_id, montoNum: r.monto })));
  const byPag = new Map();
  let totalCents = 0;
  for (const r of records) {
    totalCents += Math.round(r.monto * 100);
    const p = byPag.get(r.pagador_id) || { count: 0, cents: 0 };
    p.count += 1; p.cents += Math.round(r.monto * 100);
    byPag.set(r.pagador_id, p);
  }

  console.log(`\nPlan de backfill: ${records.length} filas · total ${(totalCents / 100).toFixed(2)}\n`);

  console.log('Por categoria_id:');
  console.table([...byCat.entries()].sort().map(([categoria_id, v]) => ({
    categoria_id, count: v.count, sum_monto: (v.cents / 100).toFixed(2),
  })));

  console.log('Por pagador_id:');
  console.table([...byPag.entries()].sort().map(([pagador_id, v]) => ({
    pagador_id, count: v.count, sum_monto: (v.cents / 100).toFixed(2),
  })));
}

// ============================================================================
// Main
// ============================================================================

function parseArgs(argv) {
  const a = { input: null, out: null, dryRun: true, help: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--help' || t === '-h') a.help = true;
    else if (t === '--input') a.input = argv[++i];
    else if (t === '--out') { a.out = argv[++i]; a.dryRun = false; }
    else if (t === '--dry-run') a.dryRun = true;
    else fail(`argumento no reconocido: ${t}`);
  }
  return a;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log([
      'Uso: node scripts/backfill-gastos.mjs --input <archivo> [--out backfill.sql]',
      '',
      '  --input <ruta>   Export local de BQ (.ndjson/.jsonl/.json/.csv). Requerido.',
      '  --out <ruta>     Emite el .sql idempotente. Sin --out: dry-run (default).',
      '  --dry-run        Solo plan + validación (comportamiento por defecto).',
      '  --help           Esta ayuda.',
    ].join('\n'));
    return;
  }
  if (!args.input) fail('falta --input <archivo>. Usa --help.');

  const rows = parseInput(args.input);
  if (!rows.length) fail(`el export "${args.input}" no tiene filas`);

  const mapped = rows.map((r, i) => mapRow(r, i));
  const errors = mapped.flatMap((m) => m.errors);
  if (errors.length) {
    console.error(`\n${errors.length} error(es) de mapeo — se aborta sin emitir nada:\n`);
    for (const e of errors) console.error('  - ' + e);
    process.exit(1);
  }

  const records = mapped.map((m) => m.record);

  // Transparencia: qué columnas del export se resolvieron para cada campo.
  const resolvedSample = mapped[0].resolved;
  console.log('\nCampos resueltos del export (fila #1):');
  console.table([resolvedSample]);

  printPlan(records);

  // Round-trip de validación sobre el SQL que se emitiría.
  const sql = buildSQL(records, args.input.split('/').pop());
  const { ok, table } = validateRoundTrip(records, sql);
  console.log('Validación round-trip (registros vs .sql emitido):');
  console.table(table);
  if (!ok) fail('la agregación del .sql NO coincide con los registros de entrada. NO se emite.');

  if (args.dryRun) {
    console.log('\nDRY-RUN ok. Validación pasó. Usa --out <archivo> para emitir el .sql.\n');
    return;
  }

  writeFileSync(args.out, sql);
  console.log(`\n.sql emitido: ${args.out} (${records.length} filas, idempotente). Revisar antes de aplicar a PROD.\n`);
}

main();
