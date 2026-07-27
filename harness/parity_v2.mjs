// Cubist Souls — REVISION PARITY HARNESS v2 (node).
//
// Consumes harness/out/onchain_v41.ndjson (produced by script/HarnessDumpV4_1.s.sol
// on a mainnet fork) — one line per revision token with the V4_1 tokenURI (override
// ACTIVE) and the V4 tokenURI (no override, the reference). For every token:
//
//   • ATTRIBUTES: asserts the V4_1(override) metadata (name, description,
//     external_url, and every attribute incl. order) is BYTE-IDENTICAL to the V4
//     reference — i.e. the override changes NOTHING in the metadata (100% gate).
//     (V4 is itself api-parity, proven by harness/parity.mjs, so this is transitive
//     parity with cubistsouls.com/api.)
//
//   • IMAGE: rasterizes the V4_1 on-chain composed SVG (which now shows the artist's
//     revised art) to 768px and pixel-diffs it against a LOCAL reference composited
//     from the ARTIST'S RAW new SVGs (for revised layers) + the on-chain originals
//     (for untouched layers) + the burn-cube marks (applying the exact reaper
//     substitution for the token's real consumed/marks). Reports per-token pixel
//     match % (≥99% gate). This proves the on-chain composite shows the artist's
//     intended art, in the right z-slot, with reaper marks intact.
//
// Usage:  node harness/parity_v2.mjs
// sharp resolved from the sibling cubistsouls-web repo (as harness/parity.mjs does).

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const WEB = path.resolve(process.cwd(), "../cubistsouls-web");
let sharp;
try {
  sharp = require(path.join(WEB, "node_modules/sharp"));
} catch {
  sharp = require("sharp");
}

const NDJSON = process.env.DUMP || "harness/out/onchain_v41.ndjson";
const SIZE = 768;
const INK = { r: 11, g: 9, b: 8 };
const PIXEL_PASS = 99; // % — revised art must match the artist's raw closely
const ART = "/private/tmp/claude-501/-Users-adrian/c17f0312-f7a6-4226-95a8-c2656bb77321/scratchpad/traits_new/Traits New";

const rows = readFileSync(NDJSON, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const table = readFileSync("onchain-data/tokentraits.bin");
const traitsIdx = JSON.parse(readFileSync("onchain-data/traits-index.json", "utf8"));
const revIdx = JSON.parse(readFileSync("onchain-data/revisions-index.json", "utf8"));

// traitId -> on-chain original svg path (traits-index paths are repo-relative
// under onchain-data/, e.g. "svg/base/dark-night.svg").
const origSvg = new Map();
for (const c of traitsIdx.categories)
  for (const o of c.options) origSvg.set(o.traitId, path.join("onchain-data", o.svg));
// original traitId(from) -> artist RAW svg path
const artRaw = new Map();
for (const r of revIdx.revisions) artRaw.set(r.from, r.artist_raw);

// burn-cube traitIds (category 8) — same substitution the renderer uses.
const BC_ORANGE = 0x0802, BC_FLAME = 0x0801, BC_PHOENIX = 0x0803, BC_BURNING = 0x0800;

function traitsOf(tokenId) {
  const off = (tokenId - 1) * 8;
  return [...table.subarray(off, off + 8)];
}

function decodeDataUri(uri) {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(uri);
  if (!m) return null;
  return { mime: m[1], buf: Buffer.from(m[2], "base64") };
}

async function rasterLayer(file) {
  // isolated layer -> 768 RGBA PNG (keeps alpha for compositing)
  return sharp(readFileSync(file), { density: 144 })
    .resize(SIZE, SIZE, { fit: "fill" })
    .png()
    .toBuffer();
}

async function toRawFlat(buf, isSvg) {
  const img = isSvg ? sharp(buf, { density: 144 }) : sharp(buf);
  const { data } = await img
    .resize(SIZE, SIZE, { fit: "fill" })
    .flatten({ background: INK })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return data;
}

async function compositeRaw(layerFiles) {
  const inputs = [];
  for (const f of layerFiles) inputs.push({ input: await rasterLayer(f) });
  const { data } = await sharp({
    create: { width: SIZE, height: SIZE, channels: 3, background: INK },
  })
    .composite(inputs)
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return data;
}

// Reference layer-file list for a token, applying reaper substitution.
function referenceLayers(tokenId, marks) {
  const t = traitsOf(tokenId);
  const orange = marks & 1, flame = marks & 2, phoenix = marks & 4, burning = marks & 8;
  const files = [];
  for (let cat = 0; cat < 8; cat++) {
    if (cat === 0 && orange) { files.push(origSvg.get(BC_ORANGE)); continue; }
    if (cat === 1 && burning) { files.push(origSvg.get(BC_BURNING)); continue; }
    if (cat === 3 && flame) { files.push(origSvg.get(BC_FLAME)); continue; }
    const opt = t[cat];
    if (opt === 0xff) continue;
    const id = (cat << 8) | opt;
    // revised layer -> ARTIST RAW; else on-chain original.
    files.push(artRaw.has(id) ? artRaw.get(id) : origSvg.get(id));
  }
  if (phoenix) files.push(origSvg.get(BC_PHOENIX));
  return files;
}

function pixelMatch(a, b) {
  const n = Math.min(a.length, b.length);
  let s = 0;
  for (let i = 0; i < n; i++) s += Math.abs(a[i] - b[i]);
  return 100 * (1 - s / n / 255);
}

function attrsEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].trait_type !== b[i].trait_type) return false;
    if (a[i].value !== b[i].value) return false;
    if (typeof a[i].value !== typeof b[i].value) return false;
  }
  return true;
}

function pad(s, n) {
  s = String(s);
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}

const fail = [];
const pix = [];
let attrOk = 0;

console.log(`\nREVISION PARITY v2 — ${rows.length} tokens · dump=${NDJSON}\n`);
console.log(pad("id", 7) + pad("kind", 10) + pad("attrs==V4", 11) + pad("pixels%", 9) + "revised layers");
console.log("-".repeat(78));

for (const row of rows) {
  const v41 = decodeDataUri(row.uri_v41);
  const v4 = decodeDataUri(row.uri_v4);
  if (!v41 || !v4) { fail.push(`#${row.id} non-data uri`); continue; }
  const j41 = JSON.parse(v41.buf.toString("utf8"));
  const j4 = JSON.parse(v4.buf.toString("utf8"));

  // 1) metadata byte-parity
  const metaOk =
    j41.name === j4.name &&
    j41.description === j4.description &&
    j41.external_url === j4.external_url &&
    attrsEqual(j41.attributes || [], j4.attributes || []);
  if (metaOk) attrOk++;
  else fail.push(`#${row.id} metadata differs between V4_1(override) and V4`);

  // 2) image vs local reference (artist raw)
  let p = NaN;
  const t = traitsOf(row.id);
  const revised = revIdx.revisions
    .filter((r) => {
      const cat = r.from >> 8, opt = r.from & 0xff;
      return t[cat] === opt;
    })
    .map((r) => r.slug);
  try {
    const ocImg = decodeDataUri(j41.image);
    const ocRaw = await toRawFlat(ocImg.buf, ocImg.mime.includes("svg"));
    const refRaw = await compositeRaw(referenceLayers(row.id, row.marks));
    p = pixelMatch(ocRaw, refRaw);
    pix.push(p);
    if (p < PIXEL_PASS) fail.push(`#${row.id} image ${p.toFixed(2)}% < ${PIXEL_PASS}%`);
  } catch (e) {
    fail.push(`#${row.id} image diff error: ${e.message}`);
  }

  console.log(
    pad(row.id, 7) +
      pad(row.consumed >= 30 ? "reaper★" : row.marks ? "marked" : "plain", 10) +
      pad(metaOk ? "✓" : "✗ DIFF", 11) +
      pad(Number.isNaN(p) ? "-" : p.toFixed(2), 9) +
      revised.join(",")
  );
}

const avg = (a) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : 100);
console.log("\n" + "=".repeat(78));
console.log(`metadata parity (V4_1 override == V4): ${attrOk}/${rows.length} tokens`);
console.log(`image pixel match avg: ${avg(pix).toFixed(2)}%  min: ${Math.min(...pix).toFixed(2)}%  (gate ${PIXEL_PASS}%)`);
if (fail.length) {
  console.log(`\nFAILURES (${fail.length}):`);
  fail.forEach((f) => console.log("  - " + f));
  process.exitCode = 1;
} else {
  console.log(`\nALL REVISION TOKENS: metadata byte-parity ✓, revised art ≥${PIXEL_PASS}% ✓`);
}
