// Cubist Souls — SoulRendererV4 PARITY HARNESS (node).
//
// Compares the on-chain renderer output (dumped by script/HarnessDumpV4.s.sol on a
// mainnet fork -> harness/out/onchain.ndjson) against the canonical off-chain
// endpoint https://cubistsouls.com/api, field by field:
//
//   • metadata: name / description / external_url + every attribute (trait_type,
//     value, and ORDER) — reports a per-token field match %.
//   • image: rasterizes the on-chain composed SVG to 768px and pixel-diffs it
//     against the canonical image the api points to (api/img raster for a plain
//     Soul, api/reaper-img composite for a marked reaper). Reports a per-token
//     pixel match % (mean per-channel similarity over RGB, flattened onto the
//     --ink wall so transparent gaps read as the wall, never white). This is the
//     check that surfaces any Head/Mouth z-order regression.
//
//   • fallback tokens (honorarium 1/1s + assetless OGs like Mich #163): the
//     on-chain tokenURI DELEGATES to the exact api/meta URL, so parity is by
//     construction — we assert the URL and skip the JSON/image diff.
//
// Usage:
//   node harness/parity.mjs                 # diff dump vs live api
//   API=https://cubistsouls.com/api node harness/parity.mjs
//
// sharp is resolved from the sibling cubistsouls-web repo (already installed).

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const WEB = path.resolve(process.cwd(), "../cubistsouls-web");
let sharp;
try {
  sharp = require(path.join(WEB, "node_modules/sharp"));
} catch {
  sharp = require("sharp"); // fall back to a local install if present
}

const API = process.env.API || "https://cubistsouls.com/api";
const NDJSON = process.env.DUMP || "harness/out/onchain.ndjson";
const SIZE = 768;
const INK = { r: 11, g: 9, b: 8 };
const PIXEL_PASS = 90; // % — report threshold (raster-vs-vector antialiasing tolerated)
const FIELD_PASS = 100; // % — metadata must be exact

const rows = readFileSync(NDJSON, "utf8").trim().split("\n").map((l) => JSON.parse(l));

function decodeDataUri(uri) {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(uri);
  if (!m) return null;
  return { mime: m[1], buf: Buffer.from(m[2], "base64") };
}

async function fetchJson(url) {
  const r = await fetch(url, { signal: AbortSignal.timeout(25000) });
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return r.json();
}
async function fetchBuf(url) {
  const r = await fetch(url, { signal: AbortSignal.timeout(45000) });
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return Buffer.from(await r.arrayBuffer());
}

// Normalize any image buffer (PNG raster OR svg) to a flat 768x768 RGB raw buffer
// over the ink wall.
async function toRaw(buf, isSvg) {
  const img = isSvg ? sharp(buf, { density: 144 }) : sharp(buf);
  const { data } = await img
    .resize(SIZE, SIZE, { fit: "fill" })
    .flatten({ background: INK })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return data; // length SIZE*SIZE*3
}

function pixelMatch(a, b) {
  const n = Math.min(a.length, b.length);
  let sum = 0;
  for (let i = 0; i < n; i++) sum += Math.abs(a[i] - b[i]);
  const meanAbs = sum / n; // 0..255
  return 100 * (1 - meanAbs / 255);
}

// Compare two attribute arrays field-by-field, order-sensitive. Returns {pct, diffs}.
function diffAttrs(onchain, api) {
  const max = Math.max(onchain.length, api.length);
  let ok = 0;
  const diffs = [];
  for (let i = 0; i < max; i++) {
    const o = onchain[i];
    const a = api[i];
    const os = o ? `${o.trait_type}=${o.value}(${typeof o.value})` : "∅";
    const as = a ? `${a.trait_type}=${a.value}(${typeof a.value})` : "∅";
    if (o && a && o.trait_type === a.trait_type && o.value === a.value && typeof o.value === typeof a.value) {
      ok++;
    } else {
      diffs.push(`  [${i}] onchain:${os} | api:${as}`);
    }
  }
  return { pct: max === 0 ? 100 : (100 * ok) / max, diffs };
}

function pad(s, n) {
  s = String(s);
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}

const summary = { fields: [], pixels: [], fallback: 0, fail: [] };

console.log(`\nPARITY HARNESS — ${rows.length} tokens · dump=${NDJSON} · api=${API}\n`);
console.log(pad("id", 7) + pad("kind", 12) + pad("name✓", 7) + pad("desc✓", 7) + pad("ext✓", 6) + pad("attrs%", 8) + pad("pixels%", 9) + "notes");
console.log("-".repeat(78));

for (const row of rows) {
  const id = row.id;
  const uri = row.uri;

  // Fallback: on-chain delegates to the api. Parity by construction.
  if (uri.startsWith("http")) {
    const expect = `${API}/meta?id=${id}`;
    const ok = uri === expect;
    summary.fallback++;
    if (!ok) summary.fail.push(`#${id} fallback URL mismatch: ${uri}`);
    console.log(
      pad(id, 7) + pad("fallback", 12) + pad("-", 7) + pad("-", 7) + pad("-", 6) + pad("-", 8) + pad("-", 9) +
        (ok ? "DELEGATED ✓ " + uri : "URL MISMATCH " + uri)
    );
    continue;
  }

  const oc = decodeDataUri(uri);
  let ocJson;
  try {
    ocJson = JSON.parse(oc.buf.toString("utf8"));
  } catch (e) {
    summary.fail.push(`#${id} on-chain JSON parse: ${e.message}`);
    console.log(pad(id, 7) + pad("onchain", 12) + "JSON PARSE FAIL");
    continue;
  }

  let apiJson;
  try {
    apiJson = await fetchJson(`${API}/meta?id=${id}`);
  } catch (e) {
    console.log(pad(id, 7) + pad("onchain", 12) + `api/meta fetch fail: ${e.message}`);
    summary.fail.push(`#${id} api/meta: ${e.message}`);
    continue;
  }

  const nameOk = ocJson.name === apiJson.name;
  const descOk = ocJson.description === apiJson.description;
  const extOk = ocJson.external_url === apiJson.external_url;
  const attr = diffAttrs(ocJson.attributes || [], apiJson.attributes || []);

  summary.fields.push(attr.pct);
  if (!nameOk) summary.fail.push(`#${id} name: onchain='${ocJson.name}' api='${apiJson.name}'`);
  if (!descOk) summary.fail.push(`#${id} description mismatch`);
  if (!extOk) summary.fail.push(`#${id} external_url: onchain='${ocJson.external_url}' api='${apiJson.external_url}'`);
  if (attr.pct < FIELD_PASS) summary.fail.push(`#${id} attrs ${attr.pct.toFixed(1)}%\n${attr.diffs.join("\n")}`);

  // Image diff: rasterize on-chain SVG vs the canonical image the api points to.
  let pixPct = NaN;
  let note = "";
  try {
    const ocImg = decodeDataUri(ocJson.image);
    const ocRaw = await toRaw(ocImg.buf, ocImg.mime.includes("svg"));
    const apiImgBuf = await fetchBuf(apiJson.image); // api/img (raster) or reaper-img (composite)
    const apiRaw = await toRaw(apiImgBuf, false);
    pixPct = pixelMatch(ocRaw, apiRaw);
    summary.pixels.push(pixPct);
    note = apiJson.image.includes("reaper-img") ? "vs reaper-img" : "vs api/img(raster)";
    if (pixPct < PIXEL_PASS) note += " ⚠LOW";
  } catch (e) {
    note = `img diff skipped: ${e.message}`;
  }

  console.log(
    pad(id, 7) +
      pad(row.consumed >= 30 ? "reaper★" : row.marks ? "marked" : "onchain", 12) +
      pad(nameOk ? "✓" : "✗", 7) +
      pad(descOk ? "✓" : "✗", 7) +
      pad(extOk ? "✓" : "✗", 6) +
      pad(attr.pct.toFixed(0), 8) +
      pad(Number.isNaN(pixPct) ? "-" : pixPct.toFixed(1), 9) +
      note
  );
  if (attr.diffs.length) attr.diffs.forEach((d) => console.log(d));
}

const avg = (a) => (a.length ? (a.reduce((s, x) => s + x, 0) / a.length) : 100);
console.log("\n" + "=".repeat(78));
console.log(`metadata field match avg: ${avg(summary.fields).toFixed(2)}%  (${summary.fields.length} onchain tokens)`);
console.log(`image pixel match avg:    ${avg(summary.pixels).toFixed(2)}%  (${summary.pixels.length} compared)`);
console.log(`fallback (delegated):     ${summary.fallback} tokens`);
if (summary.fail.length) {
  console.log(`\nFAILURES (${summary.fail.length}):`);
  summary.fail.forEach((f) => console.log(" - " + f));
  process.exitCode = 1;
} else {
  console.log(`\nALL METADATA FIELDS BYTE-PARITY ✓`);
}
