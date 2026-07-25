# Cubist Souls — Fully On-Chain Art: Gas Estimate & Runbook

Diamond (ETH mainnet, FIXED): `0x9252fDc0b3945203314Ea1a9b8d64345bc868406`
Owner / deployer: `0xa41D...`

Numbers below are **real receipt gas** from broadcasting `script/UploadSvgs.s.sol`
and `script/DeployRendererV3.s.sol` against a local anvil fork with the actual
`onchain-data/` files (149 composable traits + Adrian 1/1 + 80,000-byte token
table). They already include per-tx intrinsic (21,000) and calldata cost.

## Payload summary

| Item | Bytes on-chain | Notes |
|------|---------------:|-------|
| 149 composable trait inner-SVGs | 338,479 | stripped of the outer `<svg>` wrapper |
| Adrian 1/1 inner-SVG | 14,091 | stored under `oneOfOne` id 0 (no OG token maps to it yet) |
| Token→traits table | 80,000 | 10,000 tokens × 8 bytes, 4 chunks × 20,000 B |
| Trait names | 1,541 | option labels stored as strings |
| Largest single trait | 14,472 | fits one SSTORE2 pointer (limit 24,575 B) → all traits are single-pointer |

## Gas by step (measured)

| Step | Txs | Gas | Avg/tx |
|------|----:|----:|-------:|
| Deploy `SvgStore` | 1 | 1,063,387 | — |
| `setTrait` × 149 | 149 | 92,289,295 | 619,391 |
| `setOneOfOne` (Adrian) | 1 | 3,181,482 | — |
| `setTokenTraitsChunk` × 4 | 4 | 17,652,244 | 4,413,061 |
| **Upload subtotal** | **155** | **114,186,408** | — |
| Deploy `SoulRendererV3` | 1 | 1,164,075 | — |
| `setRenderer` (diamond) | 1 | ~55,000 | ERC-4906 BatchMetadataUpdate(1,10000) |
| **GRAND TOTAL** | **157** | **~115,405,000** | — |

## Cost at various gas prices

Total ≈ **115.4M gas** (upload 114.2M + renderer deploy 1.16M; the final
`setRenderer` is negligible). ETH mainnet base fee is volatile — the 0.2/0.5/1
gwei rows are best-case off-peak; 3/5/10 gwei rows are realistic-to-busy.

| Gas price | Upload (155 tx) | RendererV3 deploy | **All-in** |
|-----------|----------------:|------------------:|-----------:|
| 0.2 gwei  | 0.0228 ETH | 0.00023 ETH | **0.0231 ETH** |
| 0.5 gwei  | 0.0571 ETH | 0.00058 ETH | **0.0577 ETH** |
| 1.0 gwei  | 0.1142 ETH | 0.00116 ETH | **0.1154 ETH** |
| 3.0 gwei  | 0.3426 ETH | 0.00349 ETH | **0.3461 ETH** |
| 5.0 gwei  | 0.5709 ETH | 0.00582 ETH | **0.5768 ETH** |
| 10.0 gwei | 1.1419 ETH | 0.01164 ETH | **1.1535 ETH** |

Tip: because the upload is 155 independent txs, run it during a low-base-fee
window; the script is resumable so it can be paused and continued.

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
# First run: deploys SvgStore and uploads all 155 items.
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

### 3. (Optional) Freeze the store forever

Only once every trait, the Adrian 1/1, and all 4 table chunks are verified
on-chain. This is irreversible.

```
cast send <svgstore_addr> 'seal()' --rpc-url $RPC --account <deployer> --slow
```

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

## Rollback

`setRenderer` is reversible while the diamond's `rendererFrozen` is false: point
it back at the current `SoulRendererV2` address. No state on the diamond changes;
the SvgStore is independent and can be re-pointed by a future renderer.
