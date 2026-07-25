// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulRendererV3} from "../src/onchain/SoulRendererV3.sol";

/// @title DeployRendererV3 - deploy the fully on-chain renderer
/// @notice Deploys SoulRendererV3 wired to the live diamond and a loaded
///         SvgStore. Does NOT call setRenderer: pointing the diamond at V3 is a
///         separate, explicit step (see onchain-data/GAS_ESTIMATE.md runbook).
///
/// Env:
///   DIAMOND (optional) Cubist Souls diamond, defaults to mainnet
///   STORE   (required) the SvgStore address from UploadSvgs
///
/// Dry-run: forge script script/DeployRendererV3.s.sol --fork-url $RPC -vv
/// Live:    forge script script/DeployRendererV3.s.sol --rpc-url $RPC --broadcast --slow -vv
contract DeployRendererV3 is Script {
    address constant DIAMOND_MAINNET = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        address diamond = vm.envOr("DIAMOND", DIAMOND_MAINNET);
        address store = vm.envAddress("STORE");
        require(store != address(0), "STORE required");

        vm.startBroadcast();
        SoulRendererV3 renderer = new SoulRendererV3(diamond, store);
        vm.stopBroadcast();

        console.log("SoulRendererV3:", address(renderer));
        console.log("Diamond:       ", diamond);
        console.log("SvgStore:      ", store);
        console.log("");
        console.log("Next (NOT executed here) - point the diamond at V3:");
        console.log("  cast send %s 'setRenderer(address)' %s \\", diamond, address(renderer));
        console.log("    --rpc-url $RPC --account <owner> --slow");
    }
}
