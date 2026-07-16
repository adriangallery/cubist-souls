// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulRendererV2} from "../src/render/SoulRendererV2.sol";
import {SoulsAdminFacet} from "../src/facets/SoulsAdminFacet.sol";

/// Deploys SoulRendererV2 and points the live Cubist Souls diamond at it.
/// The broadcast key must be the diamond owner (0xa41D...).
/// setRenderer emits ERC-4906 BatchMetadataUpdate(1, 10000) -> OpenSea refreshes.
///
/// Env: DIAMOND (Cubist Souls diamond address).
/// Dry-run: forge script script/DeployRenderer.s.sol --fork-url $RPC
/// Live:    add --broadcast --slow  (only after explicit go-ahead)
contract DeployRenderer is Script {
    address constant DIAMOND_MAINNET = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        address diamond = vm.envOr("DIAMOND", DIAMOND_MAINNET);

        vm.startBroadcast();
        SoulRendererV2 renderer = new SoulRendererV2();
        SoulsAdminFacet(diamond).setRenderer(address(renderer));
        vm.stopBroadcast();

        console.log("SoulRendererV2:", address(renderer));
        console.log("Diamond:       ", diamond);
        console.log("tokenURI(136): ", renderer.tokenURI(136));
    }
}
