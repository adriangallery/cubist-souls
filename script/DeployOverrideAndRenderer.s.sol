// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {TraitOverride} from "../src/onchain/TraitOverride.sol";
import {SoulRendererV4_1} from "../src/onchain/SoulRendererV4_1.sol";
import {RevisionManifest} from "./RevisionManifest.sol";

/// @title DeployOverrideAndRenderer - stand up the revision layer, don't touch the diamond
/// @notice Phase 2-4 of the artist-revision rollout (phase 1 = UploadRevisions):
///           1. deploy TraitOverride (owner = deployer 0xa41D…4814)
///           2. setOverrides(from[21], to[21])   (the definitive mapping)
///           3. deploy SoulRendererV4_1(diamond, store, override)
///         setRenderer() on the diamond is intentionally NOT done here — Fable runs
///         `SoulsAdminFacet.setRenderer(<V4_1>)` as a separate, explicit tx after a
///         final read-back, exactly as the diamond evolution rules require.
///
/// Env:
///   DIAMOND (default 0x9252…8406) Cubist Souls diamond
///   STORE   (default 0x6702…46C6) live SvgStore (must already hold the 21 v2 traits)
///
/// Dry-run (fork, no broadcast):
///   forge script script/DeployOverrideAndRenderer.s.sol --fork-url $ETH_RPC -vv
/// Live (Fable, after GO; --slow):
///   forge script script/DeployOverrideAndRenderer.s.sol --rpc-url $ETH_RPC --broadcast --slow -vv
contract DeployOverrideAndRenderer is Script {
    address constant DEFAULT_DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant DEFAULT_STORE = 0x6702016627141350792Dd366885a2Fc794eE46C6;

    function run() external returns (address overrideAddr, address rendererAddr) {
        address diamond = vm.envOr("DIAMOND", DEFAULT_DIAMOND);
        address store = vm.envOr("STORE", DEFAULT_STORE);
        require(store.code.length != 0, "STORE has no code");
        require(diamond.code.length != 0, "DIAMOND has no code");

        (uint16[] memory from, uint16[] memory to,,) = RevisionManifest.all();

        vm.startBroadcast();

        TraitOverride ovr = new TraitOverride();
        console.log("TraitOverride:", address(ovr));

        ovr.setOverrides(from, to);
        console.log("setOverrides: %s pairs", from.length);

        SoulRendererV4_1 renderer = new SoulRendererV4_1(diamond, store, address(ovr));
        console.log("SoulRendererV4_1:", address(renderer));

        vm.stopBroadcast();

        // read-back sanity (view, no tx)
        require(ovr.owner() == tx.origin || ovr.owner() != address(0), "owner set");
        require(renderer.diamond() == diamond, "renderer diamond");
        require(address(renderer.store()) == store, "renderer store");
        require(renderer.traitOverride() == address(ovr), "renderer override");
        require(ovr.resolve(from[0]) == to[0], "override[0] wired");

        console.log("NEXT (Fable, separate tx): SoulsAdminFacet.setRenderer(%s)", address(renderer));
        return (address(ovr), address(renderer));
    }
}
