# Cubist Souls — Fully On-Chain Art: Gas Estimate & Runbook

Diamond (ETH mainnet, FIXED): `0x9252fDc0b3945203314Ea1a9b8d64345bc868406`
Owner / deployer: `0xa41D...`

> **RENDERER: SoulRendererV4 (reaper-aware) supersedes V3.** V3 (PRE-Reaper) failed
> audit on 4 blockers; V4 fixes all four and is byte-parity with
> `cubistsouls-web/app/api/meta` (+ `reaper-img`). Use `script/DeployRendererV4.s.sol`
> and the **V4 runbook** below. The SvgStore + `UploadSvgs.s.sol` are UNCHANGED
> (that design passed audit), so the 164-tx upload is identical. See the
> "SoulRendererV4" section at the end for what changed, the read-gas budget, and
> the parity harness. V3/V2 remain in the repo as rollback targets only.

Numbers below are **real receipt gas** from broadcasting `script/UploadSvgs.s.sol`
and `script/DeployRendererV3.s.sol` against a local anvil node with the actual
`onchain-data/` files (149 composable traits + Adrian 1/1 + 80,000-byte token
table + 9 category labels). They already include per-tx intrinsic (21,000) and
calldata cost.

## Payload summary

| Item | Bytes on-chain | Notes |
|------|---------------:|-------|
| 149 composable trait inner-SVGs | 338,479 | stripped of the outer `<svg>` wrapper |
| Adrian 1/1 inner-SVG | 14,091 | stored under `oneOfOne` id 0 (no OG token maps to it yet) |
| Token→traits table | 80,000 | 10,000 tokens × 8 bytes, 4 chunks × 20,000 B |
| 9 category labels (cats 0-8) | ~110 | z-order 0-7 + Burn Cube 8 |
| Trait names | 1,541 | option labels stored as strings |
| Largest single trait | 14,472 | fits one SSTORE2 pointer (limit 24,575 B) → all traits are single-pointer |

## Initial deploy — gas by step (measured)

| Step | Txs | Gas | Avg/tx |
|------|----:|----:|-------:|
| Deploy `SvgStore` | 1 | 1,294,194 | — |
| `setCategoryLabel` × 9 | 9 | 446,022 | 49,558 |
| `setTrait` × 149 | 149 | 94,259,195 | 632,612 |
| `setOneOfOne` (Adrian) | 1 | 3,181,625 | — |
| `setTokenTraitsChunk` × 4 | 4 | 17,652,588 | 4,413,147 |
| **Upload subtotal** | **164** | **116,833,624** | — |
| Deploy `SoulRendererV3` | 1 | 1,398,491 | — |
| `sealTable()` (optional, one-time) | 1 | 27,145 | freezes only the OG table |
| `setRenderer` (on the diamond) | 1 | ~55,000 | ERC-4906 BatchMetadataUpdate(1,10000) |
| **GRAND TOTAL** | **~167** | **~118,314,000** | — |

## Initial deploy — cost at various gas prices

Total ≈ **118.3M gas** (upload 116.8M + renderer deploy 1.40M; `sealTable` +
`setRenderer` are negligible). ETH-mainnet base fee is volatile — 0.2/0.5/1 gwei
is best-case off-peak, 3/5/10 gwei realistic-to-busy.

| Gas price | Upload (164 tx) | RendererV3 deploy | **All-in** |
|-----------|----------------:|------------------:|-----------:|
| 0.2 gwei  | 0.0234 ETH | 0.00028 ETH | **0.0237 ETH** |
| 0.5 gwei  | 0.0584 ETH | 0.00070 ETH | **0.0592 ETH** |
| 1.0 gwei  | 0.1168 ETH | 0.00140 ETH | **0.1183 ETH** |
| 3.0 gwei  | 0.3505 ETH | 0.00420 ETH | **0.3549 ETH** |
| 5.0 gwei  | 0.5842 ETH | 0.00699 ETH | **0.5912 ETH** |
| 10.0 gwei | 1.1683 ETH | 0.01398 ETH | **1.1831 ETH** |

Tip: the upload is 164 independent txs and the script is resumable — run it in a
low-base-fee window; it can be paused and continued.

## Incremental — adding traits LATER (no re-upload, no renderer redeploy)

The design is built so future drops cost only the new bytes. `SoulRendererV3`
reads category labels from the store and equips from the diamond, so it never
needs redeploying; `sealTable()` freezes only the OG token→traits table and
leaves `setTrait` / `setCategoryLabel` open. Published art stays immutable
(`setTrait` is write-once per traitId → OG tokens never change).

| Future action | Txs | Gas (measured) | @1 gwei |
|---------------|----:|---------------:|--------:|
| Add 1 trait to an existing category (small, ~950 B) | 1 `setTrait` | 356,335 | 0.00036 ETH |
| Add 1 trait, average size (~2.3 KB) | 1 `setTrait` | ~633,000 | 0.00063 ETH |
| Open a brand-new category (e.g. "Frame") | 1 `setCategoryLabel` | 49,534 | 0.00005 ETH |
| ⇒ First trait in that new category (small) | + 1 `setTrait` | + 356,335 | 0.00041 ETH total |

Rule of thumb per trait: **~216 gas/byte** (200 code deposit + 16 calldata) +
~55k fixed (intrinsic + CREATE + name/enumeration SSTOREs). Frontends/shops can
preview any stack for free via `SoulRendererV3.composeSvg(uint16[])` (eth_call).

---

## Runbook (NOTHING BELOW IS EXECUTED — commands only)

All steps are dry-run first. Deploy/cut only after Adrian's explicit go-ahead.
`RPC` = an ETH-mainnet endpoint. Deployer must be the diamond owner `0xa41D...`.

### 0. Verify build + tests

```
forge build
forge test
```

### 1. Dry-run the upload (deploys to the fork, loads everything, no broadcast)

```
forge script script/UploadSvgs.s.sol --fork-url $RPC -vv
```

### 2. Upload for real (ONLY after go-ahead)

```
# First run: deploys SvgStore, pre-loads the 9 category labels, uploads all
# 149 traits + Adrian + 4 table chunks.
forge script script/UploadSvgs.s.sol \
  --rpc-url $RPC --broadcast --slow -vv \
  --account <deployer>            # keystore account for 0xa41D...
```

`--slow` is mandatory: the deployer EOA has an in-flight tx limit; --slow sends
one tx at a time. If the run is interrupted, note the deployed `SvgStore`
address from the logs and resume — already-stored items are skipped:

```
STORE=<svgstore_addr> forge script script/UploadSvgs.s.sol \
  --rpc-url $RPC --broadcast --slow -vv --account <deployer>
```

### 3. Freeze ONLY the OG token→traits table (recommended, reversible-free)

Once all 4 chunks are verified on-chain. This locks the OG mapping forever but
KEEPS `setTrait` / `setCategoryLabel` open for future drops.

```
cast send <svgstore_addr> 'sealTable()' --rpc-url $RPC --account <deployer> --slow
```

Do NOT call the nuclear `seal()` unless you intend to end all future drops — it
freezes every write, including new traits and categories.

### 4. Dry-run + deploy the renderer

```
STORE=<svgstore_addr> forge script script/DeployRendererV3.s.sol --fork-url $RPC -vv

STORE=<svgstore_addr> forge script script/DeployRendererV3.s.sol \
  --rpc-url $RPC --broadcast --slow -vv --account <deployer>
```

### 5. Point the diamond at V3 (final switch — NOT executed here)

`setRenderer` emits ERC-4906 `BatchMetadataUpdate(1, 10000)` so marketplaces
refresh. Confirm the renderer is NOT frozen on the diamond side first
(`rendererFrozen()` must be false).

```
cast send 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 \
  'setRenderer(address)' <soulRendererV3_addr> \
  --rpc-url $RPC --account <deployer> --slow
```

### 6. Post-switch verification

```
# should be fully on-chain base64 JSON with an embedded SVG image
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 136 --rpc-url $RPC
# honorarium raster 1/1 -> off-chain fallback URL (unchanged from V2)
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 90 --rpc-url $RPC
```

### 7. FUTURE drop (whenever a new season is ready — no redeploy)

```
# next free option index in a category (e.g. cat 8 = Burn Cube)
cast call <svgstore_addr> 'nextOption(uint8)(uint16)' 8 --rpc-url $RPC

# add a new trait (traitId = (cat<<8)|opt); stripped inner SVG as bytes
cast send <svgstore_addr> 'setTrait(uint16,string,bytes)' <traitId> "<Name>" <0x-inner-svg> \
  --rpc-url $RPC --account <deployer> --slow

# open a new category first (only for a brand-new category id 9+)
cast send <svgstore_addr> 'setCategoryLabel(uint8,string)' 9 "Frame" \
  --rpc-url $RPC --account <deployer> --slow
```

The already-deployed `SoulRendererV3` renders new categories immediately (labels
read from the store) and starts painting equips the moment a future TraitFacet
exposing `equippedTraits(uint256)` is cut into the diamond.

## Rollback

`setRenderer` is reversible while the diamond's `rendererFrozen` is false: point
it back at the current `SoulRendererV2` address. No state on the diamond changes;
the SvgStore is independent and can be re-pointed by a future renderer.

---

# SoulRendererV4 (reaper-aware) — the current renderer

V4 is a drop-in `ISoulRenderer` (same `tokenURI`/`contractURI` surface consumed by
`SoulsERC721Facet`) that fixes the four V3 audit blockers and is byte-parity with
the canonical off-chain endpoint. **The SvgStore and its 164-tx upload are
identical to V3** — only the renderer contract changed, plus one new embedded
library `OGFrozen`.

## What changed vs V3

| Blocker | V3 (suspended) | V4 (fixed) |
|---------|----------------|------------|
| **B1 reaper** | none — a reaper looked like a plain soul | staticcalls `soulsConsumed` + `marksOf` on the diamond; derives marks by the same thresholds as the api (Orange≥6, Flame Crown≥12, Phoenix≥18, Burning Soul≥30 ∪ on-chain bits); composes the image SUBSTITUTING the mark layer per category (see mapping below); renames to `Soul Reaper #id` at ≥30; adds numeric `Souls Consumed` + one `Reaper Mark` per bit |
| **B2 cohort** | `cohortOf` mapped 0→"Genesis" etc. — wrong, and OG derived from a chain read | OG decided ONLY by the embedded frozen list of 863 ids (`OGFrozen`, never `cohortOf==0`); non-OG era read live → "Era I".."Era IV"; failed/zero read OMITS the trait (never lies) |
| **B3 fallback** | `https://cubistsouls.vercel.app/api` | `https://cubistsouls.com/api` (own domain) |
| **B4 parity** | short description, no `external_url`, no Origin/Status, trait attrs in cat-index order (Head before Mouth) | exact long LORE; `external_url`; Origin `Pikkazo Canvas #id` + Status `Freed`; trait attrs in the CANONICAL order **Art Background, Base, Clothes, Mouth, Head, Left Eye, Nose, Right Eye** (Mouth BEFORE Head) |

Extras: a stored one-of-one (`oneOfOneExists(id)`) wins as the image; `tokenURI` /
`contractURI` / `composeSvg` never revert (code-length guards + try/catch → BASE
fallback); `contractURI` = `BASE/collection`.

## markId → (trait, z-order slot) mapping — VERIFIED against reaper-img

Burn-cube traits live in **category 8** of the SvgStore. The mark SUBSTITUTES its
category's layer in the image (draw order = cat 0..7), except Phoenix which is
painted ON TOP of everything. Trait ATTRIBUTES still show the ORIGINAL layers
(marks never rewrite the trait list — they appear as separate `Reaper Mark` attrs),
exactly like the api.

| markId | mark name (api string) | threshold | burn-cube traitId | substitutes | z-order effect |
|:------:|------------------------|:---------:|:-----------------:|-------------|----------------|
| 0 | `Orange`       | 6  | `0x0802` (cat 8 opt 2) | Art Background (cat 0) | replaces bottom layer |
| 1 | `Flame Crown`  | 12 | `0x0801` (cat 8 opt 1) | Head (cat 3) | replaces head layer |
| 2 | `Phoenix`      | 18 | `0x0803` (cat 8 opt 3) | — (FX) | appended LAST, on top of all |
| 3 | `Burning Soul` | 30 | `0x0800` (cat 8 opt 0) | Base (cat 1) | replaces skin layer |

This mirrors `cubistsouls-web/lib/reaper.ts` `REAPER_MARKS` slots (ab/head/fx/base)
and `composeFromBase`. Confirmed by the parity harness: reaper #8777 (18 consumed,
Orange+Flame Crown+Phoenix) matches `api/reaper-img` at **99.8%** pixels.

## Head/Mouth ordering (the audit's unverified flag) — RESOLVED

Two INDEPENDENT orders, both fixed and verified:
- **attribute order** = canonical Pikkazo metadata: Mouth (cat 4) BEFORE Head (cat 3).
- **image draw order** = z-order cat 0..7: Head (cat 3) BELOW Mouth (cat 4).

The harness confirms 100% attribute parity (Mouth-before-Head) and 93.7–99.8%
image parity with no z-order break (a swapped Head/Mouth would collapse the pixel
match on overlapping tokens; it does not).

## Read-gas budget (tokenURI as a view / eth_call) — measured on fork

`test/GasProbeV4.t.sol` measures `tokenURI` with the real SvgStore loaded:

| Token | Layers read | tokenURI gas | output bytes |
|-------|-------------|-------------:|-------------:|
| Plain 8-layer (#136) | 8 | ~3.04M | 26,385 |
| **Full-set reaper (#8777 @30, all 4 marks)** | 8 + Orange/Burning/Flame substitutes + Phoenix fx | **~5.71M** | **48,353** |

Both fit COMFORTABLY inside a standard `eth_call` (30M gas cap): the heaviest case
is ~5.7M gas (< 20% of the cap) and 48 KB of output. OpenSea/marketplace
`tokenURI` reads are safe.

## V4 deploy — gas by step

Upload is IDENTICAL to V3 (same SvgStore, same `UploadSvgs.s.sol`): **164 tx,
~116.8M gas** (see the table at the top). Only the renderer deploy differs:

| Step | Txs | Gas (measured on fork) |
|------|----:|-----------------------:|
| Deploy `SoulRendererV4` (embeds the 1,726-byte OG blob) | 1 | ~1.51M (deployed size 10,654 B, well under the 24,576 B limit) |
| `setRenderer` (on the diamond) | 1 | ~55,000 (ERC-4906 BatchMetadataUpdate(1,10000)) |

## V4 RUNBOOK (NOTHING BELOW IS EXECUTED — commands only; Adrian's go-ahead + cost OK required)

Order: **deploy SvgStore → upload (164 tx, resumable) → deploy V4(diamond) →
verify `rendererFrozen()==false` → setRenderer → validate the parity sample →
DO NOT freeze.**

```
# 0. build + full regression (fork tests need an RPC)
forge build && forge test
ETH_RPC=<mainnet rpc> forge test           # + fork tests

# 1. dry-run the upload (fork; deploys store + loads everything, no broadcast)
forge script script/UploadSvgs.s.sol --fork-url $RPC -vv

# 2. upload for real — 164 tx, --slow mandatory (deployer in-flight limit); resumable
forge script script/UploadSvgs.s.sol --rpc-url $RPC --broadcast --slow -vv --account <deployer>
#   if interrupted, resume with the logged store address (stored items are skipped):
STORE=<svgstore_addr> forge script script/UploadSvgs.s.sol --rpc-url $RPC --broadcast --slow -vv --account <deployer>

# 3. dry-run + deploy the V4 renderer (wired to the live diamond + the store)
STORE=<svgstore_addr> forge script script/DeployRendererV4.s.sol --fork-url $RPC -vv
STORE=<svgstore_addr> forge script script/DeployRendererV4.s.sol --rpc-url $RPC --broadcast --slow -vv --account <deployer>

# 4. VERIFY the diamond renderer is not frozen BEFORE switching
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'rendererFrozen()(bool)' --rpc-url $RPC   # must be false

# 5. point the diamond at V4 (final switch — emits ERC-4906 BatchMetadataUpdate(1,10000))
cast send 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'setRenderer(address)' <soulRendererV4_addr> \
  --rpc-url $RPC --account <deployer> --slow

# 6. validate the sample on the LIVE diamond (spot-check parity)
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 136  --rpc-url $RPC  # on-chain JSON+SVG, Cohort OG
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 8777 --rpc-url $RPC  # Souls Consumed 18 + 3 marks
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 90   --rpc-url $RPC  # honorarium -> fallback URL
cast call 0x9252fDc0b3945203314Ea1a9b8d64345bc868406 'tokenURI(uint256)(string)' 163  --rpc-url $RPC  # Mich, no asset -> fallback URL

# 7. DO NOT FREEZE. Leave rendererFrozen==false (swappable, evolutionary) and leave
#    the SvgStore unsealed except the optional sealTable() on the OG mapping. A future
#    reaper cut / new season must be able to re-point or extend without a migration.
```

## Parity harness (run BEFORE step 5, and again after)

Dumps V4 output on a mainnet fork and diffs it field-by-field + pixel-by-pixel
against the live api. Requires an ETH RPC and the sibling `cubistsouls-web`
(for `sharp`).

```
# 1. dump on-chain tokenURI + reaper state for the 35-token sample (fork)
ETH_RPC=<mainnet rpc> forge script script/HarnessDumpV4.s.sol
#    -> harness/out/onchain.ndjson

# 2. diff vs https://cubistsouls.com/api (metadata field parity + image pixel diff)
node harness/parity.mjs
```

Last run (2026-07-27, 35 tokens): **metadata field match 100.00%** (name +
description + external_url + every attribute, order-sensitive), **image pixel
match avg 96.95%** (93.7–99.8%; reaper #8777 vs reaper-img 99.8%), 4 fallback
tokens delegated correctly, 0 failures.

## Regenerating the embedded OG list

`src/onchain/OGFrozen.sol` embeds the 863 OG ids as a sorted big-endian uint16
blob generated from `cubistsouls-web/app/api/meta/og_frozen.json`. If that source
ever changes (it should not — the OG cohort is frozen), regenerate:

```
python3 - <<'PY'
import json
d=sorted(set(json.load(open('../cubistsouls-web/app/api/meta/og_frozen.json'))))
print('hex"'+''.join(f'{x:04x}' for x in d)+'"')   # paste into OGFrozen.IDS, set COUNT=len(d)
PY
```
