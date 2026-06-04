#!/usr/bin/env node
// One-off: clear compare_at_price across the catalog.
// For every variant where compareAtPrice > 0, set price = compareAtPrice and compareAtPrice = null.
// Writes a CSV snapshot first to enable rollback.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

function loadEnv() {
  const envPath = path.join(REPO_ROOT, ".env");
  const raw = fs.readFileSync(envPath, "utf8");
  for (const line of raw.split("\n")) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    if (!process.env[m[1]]) process.env[m[1]] = v;
  }
}

loadEnv();

const SHOP = process.env.SHOPIFY_STORE_DOMAIN;
const TOKEN = process.env.SHOPIFY_ACCESS_TOKEN;
const API_VERSION = "2025-04";
const DRY_RUN = process.argv.includes("--dry-run");

if (!SHOP || !TOKEN) {
  console.error("Missing SHOPIFY_STORE_DOMAIN or SHOPIFY_ACCESS_TOKEN in .env");
  process.exit(1);
}

const ENDPOINT = `https://${SHOP}/admin/api/${API_VERSION}/graphql.json`;

async function gql(query, variables) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": TOKEN,
      },
      body: JSON.stringify({ query, variables }),
    });
    if (res.status === 429 || res.status >= 500) {
      const wait = 1000 * Math.pow(2, attempt);
      console.warn(`HTTP ${res.status}, retry in ${wait}ms`);
      await new Promise(r => setTimeout(r, wait));
      continue;
    }
    const json = await res.json();
    if (json.errors) {
      const throttled = json.errors.some(e => e.extensions?.code === "THROTTLED");
      if (throttled) {
        const wait = 1500 * (attempt + 1);
        console.warn(`THROTTLED, retry in ${wait}ms`);
        await new Promise(r => setTimeout(r, wait));
        continue;
      }
      throw new Error("GraphQL errors: " + JSON.stringify(json.errors));
    }
    return json.data;
  }
  throw new Error("Exhausted retries");
}

const VARIANTS_QUERY = `
  query Variants($cursor: String) {
    productVariants(first: 250, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      edges {
        node {
          id
          sku
          price
          compareAtPrice
          product { id title }
        }
      }
    }
  }
`;

const BULK_UPDATE = `
  mutation UpdateVariants($productId: ID!, $variants: [ProductVariantsBulkInput!]!) {
    productVariantsBulkUpdate(productId: $productId, variants: $variants) {
      productVariants { id price compareAtPrice }
      userErrors { field message code }
    }
  }
`;

async function fetchAllDiscountedVariants() {
  const out = [];
  let cursor = null;
  let page = 0;
  while (true) {
    page++;
    const data = await gql(VARIANTS_QUERY, { cursor });
    const conn = data.productVariants;
    for (const edge of conn.edges) {
      const v = edge.node;
      const cap = v.compareAtPrice ? parseFloat(v.compareAtPrice) : 0;
      if (cap > 0) out.push(v);
    }
    console.log(`Page ${page}: scanned ${conn.edges.length}, discounted total so far: ${out.length}`);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }
  return out;
}

function csvEscape(s) {
  if (s === null || s === undefined) return "";
  const str = String(s);
  if (/[",\n]/.test(str)) return `"${str.replace(/"/g, '""')}"`;
  return str;
}

function writeSnapshot(variants) {
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const file = path.join(__dirname, `snapshot-${ts}.csv`);
  const header = "variant_id,product_id,product_title,sku,price_before,compare_at_price_before\n";
  const rows = variants.map(v =>
    [v.id, v.product.id, csvEscape(v.product.title), csvEscape(v.sku), v.price, v.compareAtPrice].join(",")
  );
  fs.writeFileSync(file, header + rows.join("\n") + "\n");
  console.log(`Snapshot written: ${file} (${variants.length} variants)`);
  return file;
}

function groupByProduct(variants) {
  const map = new Map();
  for (const v of variants) {
    if (!map.has(v.product.id)) map.set(v.product.id, []);
    map.get(v.product.id).push(v);
  }
  return map;
}

async function applyUpdates(byProduct) {
  let okCount = 0;
  let errCount = 0;
  const errors = [];
  for (const [productId, vars] of byProduct.entries()) {
    const input = vars.map(v => ({
      id: v.id,
      price: v.compareAtPrice,
      compareAtPrice: null,
    }));
    const data = await gql(BULK_UPDATE, { productId, variants: input });
    const r = data.productVariantsBulkUpdate;
    if (r.userErrors && r.userErrors.length > 0) {
      errCount += vars.length;
      for (const e of r.userErrors) {
        errors.push({ productId, message: e.message, field: e.field });
        console.error(`Error on ${productId}: ${e.message} (${(e.field||[]).join('.')})`);
      }
    } else {
      okCount += r.productVariants.length;
      console.log(`OK product ${productId}: updated ${r.productVariants.length} variants`);
    }
    await new Promise(r => setTimeout(r, 300));
  }
  return { okCount, errCount, errors };
}

async function main() {
  console.log(`=== End-promo job @ ${new Date().toISOString()} ===`);
  console.log(`Shop: ${SHOP}  API: ${API_VERSION}  DRY_RUN: ${DRY_RUN}`);
  const variants = await fetchAllDiscountedVariants();
  console.log(`Found ${variants.length} variants with compare_at_price > 0`);
  if (variants.length === 0) {
    console.log("Nothing to do");
    return;
  }
  const snapshot = writeSnapshot(variants);
  if (DRY_RUN) {
    console.log("DRY_RUN: skipping mutations");
    return;
  }
  const byProduct = groupByProduct(variants);
  console.log(`Applying updates across ${byProduct.size} products...`);
  const { okCount, errCount, errors } = await applyUpdates(byProduct);
  console.log(`=== Done. variants_ok=${okCount} variants_err=${errCount} snapshot=${snapshot}`);
  if (errCount > 0) {
    const errFile = snapshot.replace(".csv", ".errors.json");
    fs.writeFileSync(errFile, JSON.stringify(errors, null, 2));
    console.log(`Errors file: ${errFile}`);
    process.exit(2);
  }
}

main().catch(err => {
  console.error("FATAL:", err);
  process.exit(1);
});
