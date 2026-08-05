// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface ISvgStoreW {
    function setTrait(uint16 traitId, string calldata name, bytes calldata inner) external;
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function frozen() external view returns (bool);
}

/// @title UploadWater - the tide goes on chain
///
/// Eight pieces, stored in the reserved band next to the fire marks and the
/// death mask, so the renderer can reach them by id forever:
///   0x0800 burning soul · 0x0801 flame crown · 0x0802 orange · 0x0803 phoenix
///   0x0804 memento mori
///   0x0805..0x080C  the water
///
/// They are stored FLATTENED (no CSS classes, namespaced root id): the renderer
/// concatenates layers into a single document, and shared class names would
/// repaint whatever else is on the canvas. Verified pixel-identical to the
/// artist's files before upload.
contract UploadWater is Script {
    address constant STORE = 0x6702016627141350792Dd366885a2Fc794eE46C6;

    function run() external {
        ISvgStoreW store = ISvgStoreW(STORE);
        require(!store.frozen(), "store sealed");

        string[8] memory files = [
            "onchain-data/water-opensea.svg",
            "onchain-data/water-underwater-love.svg",
            "onchain-data/water-go-with-the-flow.svg",
            "onchain-data/water-cold-lips.svg",
            "onchain-data/water-touch-sea-grass.svg",
            "onchain-data/water-sniper-snapper.svg",
            "onchain-data/water-swarm-together-strong.svg",
            "onchain-data/water-drowning-dreams.svg"
        ];
        string[8] memory names = [
            "Opensea",
            "Underwater Love",
            "Go With The Flow",
            "Cold Lips",
            "Touch Sea Grass",
            "Sniper Snapper",
            "Swarm Together Strong",
            "Drowning Dreams"
        ];

        vm.startBroadcast();
        for (uint256 i; i < 8; i++) {
            uint16 id = uint16(0x0805 + i);
            if (store.traitSvg(id).length != 0) {
                console.log("already stored, skipping", id);
                continue;
            }
            bytes memory inner = vm.readFileBinary(files[i]);
            require(inner.length > 400, "fragment too small");
            store.setTrait(id, names[i], inner);
            console.log("stored", id, names[i]);
        }
        vm.stopBroadcast();

        for (uint256 i; i < 8; i++) {
            require(store.traitSvg(uint16(0x0805 + i)).length > 400, "missing after upload");
        }
        console.log("the tide is on chain");
    }
}
