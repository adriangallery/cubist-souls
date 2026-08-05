// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulRendererV6} from "../src/onchain/SoulRendererV6.sol";

interface IDia6 {
    function renderer() external view returns (address);
    function rendererFrozen() external view returns (bool);
    function setRenderer(address) external;
    function tokenURI(uint256) external view returns (string memory);
}

interface ILive6 {
    function store() external view returns (address);
    function traitOverride() external view returns (address);
}

/// Souls entrusted to a reaper travel with it when it is sold, and a marketplace
/// cannot show that. The metadata now can: "Souls Behind". Byte-identical to the
/// live renderer for everything that carries nothing (proven on a fork).
contract UpgradeRendererV6 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        IDia6 d = IDia6(DIAMOND);
        address live = d.renderer();
        address store = ILive6(live).store();
        address ovr = ILive6(live).traitOverride();
        require(!d.rendererFrozen(), "renderer frozen");
        console.log("live renderer:", live);

        vm.startBroadcast();
        SoulRendererV6 v6 = new SoulRendererV6(DIAMOND, store, ovr);
        d.setRenderer(address(v6));
        vm.stopBroadcast();

        require(d.renderer() == address(v6), "not swapped");
        require(bytes(d.tokenURI(99)).length > 100, "a soul must still render");
        require(bytes(d.tokenURI(487)).length > 100, "a loaded reaper must still render");
        console.log("new renderer:", address(v6));
        console.log("souls behind 487:", v6.soulsBehind(487));
    }
}
