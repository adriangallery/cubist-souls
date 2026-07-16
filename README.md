# Cubist Souls

On-chain source for **Cubist Souls** — an EIP-2535 Diamond NFT collection on
**Ethereum mainnet**. Cubist Souls is the takeover successor of the Pikkazo
canvases: *burn a Pikkazo and you automatically get its Cubist Soul — same
token id, its original art recovered, "trapped in abandoned canvases, freed by
fire."*

Supply is created **only by conversion**: `convert(tokenId[])` burns the caller's
Pikkazo(s) on the old contract and mints the Soul with the **same token id**.
There is no arbitrary mint or airdrop.

## Live addresses (Ethereum mainnet · chainId 1)

The canonical deployment ("v2"). Owner / deployer: `0xa41D5faF7Ba8b82e276125dE2a053216e91F4814`.

| Contract | Address |
|----------|---------|
| **Diamond (Cubist Souls, SOUL)** | `0x9252fDc0b3945203314Ea1a9b8d64345bc868406` |
| DiamondCutFacet | `0x1b250cbfCF66f5aEDfCE27006A7e5e60A609Fc04` |
| DiamondLoupeFacet | `0x518b9cd6c9a1dfedf45649dab300e02996145b8b` |
| OwnershipFacet | `0x982ba235df4fd68e7017e719dc7de5de797dc907` |
| SoulsERC721Facet | `0x0df6535a435a4dc93ad419705e38714f033444ef` |
| ConvertFacet | `0x1fd4d782ea228f9eb6cfb39505e69925fe25ce26` |
| SoulsAdminFacet | `0xf58689a5adaf38b4827ba867d790d16d7b171654` |
| PlaceholderRenderer | `0x79708f0c127820091e00fd3e2e0ec09e6447cb61` |
| SoulsInit (init only) | `0xf15bbf6755321d8cf12039d58385141af63c29a2` |
| **SoulRendererV2** (active renderer) | `0x10A45F264e5F71518f24e78244aA8B7f0be6D316` |

Constructor args of the Diamond: `(owner = 0xa41D…4814, diamondCutFacet = 0x1b25…Fc04)`.

- Old **Pikkazo** contract (source of burns): `0x6478b94dfa32F3eab600970D04B34615eE97484e`
- OpenSea collection slug: `cubist-souls`
- Metadata / render endpoints: `https://cubistsouls.vercel.app/api` (`SoulRendererV2`
  points `tokenURI`/`contractURI` here; the renderer is **swappable, not frozen**).

## Architecture

Standard Nick Mudge EIP-2535 Diamond (Cut / Loupe / Ownership 2-step) plus the
Souls facets:

- **SoulsERC721Facet** — ERC-721 + ERC-2981 royalties + ERC-4906. `tokenURI`
  never reverts (renderer code-check + try/catch + inline fallback).
- **ConvertFacet** — `convert(uint256[])`: requires `ownerOf == msg.sender` on
  Pikkazo, calls `pikkazo.burn`, mints the same id. Max 50/tx, pausable.
- **SoulsAdminFacet** — `setRenderer` / `freezeRenderer` (one-way) /
  `setConvertPaused` / `setRoyaltyInfo` (cap 10%).
- **SoulsInit** — one-shot initializer; mints the pre-diamond burns (#136, #1064)
  to their owner, guarded by `CanvasStillAlive`.
- Renderers (`PlaceholderRenderer`, `SoulRendererV2`) are external, swappable
  modules implementing `ISoulRenderer`. `supportsInterface` lives in the Loupe.

Storage uses a single append-only struct `LibSouls.Layout` at slot
`keccak256("cubistsouls.app.storage")`.

## Evolution framework (binding)

This diamond and the `cubist-souls` collection are **definitive** — a live
project. Rules for any future change:

- **No v3, no redeploy, no migration.** Evolve only via `diamondCut` (additive;
  `Replace`/`Remove` only with strong justification) and `setRenderer`.
- **Storage is append-only** in `LibSouls.Layout` — never reorder or insert
  existing fields; only append.
- Supply semantics are sacred: supply grows **only** by conversion
  (burn Pikkazo → Soul, same id). Never add arbitrary mint/airdrop.
- Always **dry-run on a fork** before any on-chain cut.

## Build & test

Requires [Foundry](https://book.getfoundry.sh/) and Solidity 0.8.30
(`via_ir = true`, `optimizer_runs = 1000` — see `foundry.toml`).

```shell
# clone with the forge-std submodule
git clone --recurse-submodules https://github.com/adriangallery/cubist-souls
# (or, if already cloned)
git submodule update --init --recursive

forge build
forge test                                   # unit tests (fork tests auto-skip)
ETH_RPC=https://ethereum-rpc.publicnode.com forge test   # + 2 fork tests vs real Pikkazo
```

18 tests (16 unit with a `MockPikkazo`, 2 fork against the real Pikkazo contract).

## Deploy scripts

`script/Deploy.s.sol` deploys the full diamond + facets + init; the deploy
record for the live mainnet deployment is in `broadcast/` (public tx data only).
`script/DeployRenderer.s.sol` deploys `SoulRendererV2`. Signing keys are supplied
via environment variables at deploy time and are **never** committed.
