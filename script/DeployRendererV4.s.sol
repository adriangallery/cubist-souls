// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";

/// @title DeployRendererV4 - deploy the reaper-aware fully on-chain renderer
/// @notice Deploys SoulRendererV4 wired to the live diamond (which hosts the
///         reaper + cohort reads it staticcalls) and a loaded SvgStore. Does NOT
///         call setRenderer: pointing the diamond at V4 is a separate, explicit
///         step gated on Adrian's go-ahead (see onchain-data/GAS_ESTIMATE.md).
///
/// Env:
///   DIAMOND (optional) Cubist Souls diamond, defaults to mainnet
///   STORE   (required) the SvgStore address from UploadSvgs
///
/// Dry-run: STORE=<addr> forge script script/DeployRendererV4.s.sol --fork-url $RPC -vv
/// Live:    STORE=<addr> forge script script/DeployRendererV4.s.sol --rpc-url $RPC --broadcast --slow -vv
contract DeployRendererV4 is Script {
    address constant DIAMOND_MAINNET = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        address diamond = vm.envOr("DIAMOND", DIAMOND_MAINNET);
        address store = vm.envAddress("STORE");
        require(store != address(0), "STORE required");
        require(store.code.length != 0, "STORE has no code");

        vm.startBroadcast();
        SoulRendererV4 renderer = new SoulRendererV4(diamond, store);
        vm.stopBroadcast();

        console.log("SoulRendererV4:", address(renderer));
        console.log("Diamond:       ", diamond);
        console.log("SvgStore:      ", store);
        console.log("");
        console.log("Verify BEFORE setRenderer:");
        console.log("  cast call %s 'rendererFrozen()(bool)' --rpc-url $RPC   # must be false", diamond);
        console.log("Then point the diamond at V4 (NOT executed here):");
        console.log("  cast send %s 'setRenderer(address)' %s \\", diamond, address(renderer));
        console.log("    --rpc-url $RPC --account <owner> --slow");
    }
}
