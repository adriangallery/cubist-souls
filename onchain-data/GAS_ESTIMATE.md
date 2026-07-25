# Cubist Souls — Fully On-Chain Art: Gas Estimate & Runbook

Diamond (ETH mainnet, FIXED): `0x9252fDc0b3945203314Ea1a9b8d64345bc868406`
Owner / deployer: `0xa41D...`

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
