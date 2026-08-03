// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulRendererV5} from "../src/onchain/SoulRendererV5.sol";

interface ISvgStoreW {
    function setTrait(uint16 traitId, string calldata name, bytes calldata inner) external;
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function owner() external view returns (address);
    function frozen() external view returns (bool);
}

interface IDiamondR {
    function renderer() external view returns (address);
    function rendererFrozen() external view returns (bool);
    function setRenderer(address newRenderer) external;
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface ILiveRenderer {
    function store() external view returns (address);
    function traitOverride() external view returns (address);
}

/// @title AddMementoMori - the death mask goes on-chain
///
/// Three movements, one broadcast:
///   1. Store the mask in the SvgStore as trait 0x0804 ("Memento Mori"), the
///      next id in the reserved band that already holds the reaper marks
///      (0x0800 burning · 0x0801 flame · 0x0802 orange · 0x0803 phoenix).
///   2. Deploy SoulRendererV5 with the SAME immutables as the live renderer.
///   3. Point the diamond at it.
///
/// V5 is byte-identical to the live renderer for every Soul and every Reaper
/// (proved on a mainnet fork in RendererV5Fork.t.sol); the only new behaviour is
/// the Memento Mori branch.
///
/// Dry-run:   forge script script/AddMementoMori.s.sol --fork-url $RPC \
///              --sender 0xa41D5fAF7BA8B82E276125dE2a053216e91f4814 -vv
/// Broadcast: forge script script/AddMementoMori.s.sol --rpc-url $RPC \
///              --private-key $DEPLOYER_KEY --broadcast --slow -vv
contract AddMementoMori is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant STORE = 0x6702016627141350792Dd366885a2Fc794eE46C6;
    uint16 constant BC_MEMENTO = 0x0804;

    function run() external {
        ISvgStoreW store = ISvgStoreW(STORE);
        IDiamondR diamond = IDiamondR(DIAMOND);

        address live = diamond.renderer();
        address storeAddr = ILiveRenderer(live).store();
        address overrideAddr = ILiveRenderer(live).traitOverride();

        console.log("live renderer:", live);
        console.log("store:        ", storeAddr);
        console.log("override:     ", overrideAddr);
        require(storeAddr == STORE, "store mismatch");
        require(!store.frozen(), "store sealed");
        require(!diamond.rendererFrozen(), "renderer frozen");
        require(store.traitSvg(BC_MEMENTO).length == 0, "mask already stored");

        bytes memory inner = vm.readFileBinary("onchain-data/memento-mori-inner.svg");
        require(inner.length > 10_000, "mask fragment looks wrong");
        console.log("mask bytes:   ", inner.length);

        vm.startBroadcast();

        // 1. the mask
        store.setTrait(BC_MEMENTO, "Memento Mori", inner);

        // 2. the renderer that knows what to do with it
        SoulRendererV5 v5 = new SoulRendererV5(DIAMOND, storeAddr, overrideAddr);

        // 3. the swap
        diamond.setRenderer(address(v5));

        vm.stopBroadcast();

        console.log("-- after --");
        console.log("  mask stored bytes:", store.traitSvg(BC_MEMENTO).length);
        console.log("  renderer:         ", diamond.renderer());
        require(diamond.renderer() == address(v5), "renderer not swapped");
        require(store.traitSvg(BC_MEMENTO).length == inner.length, "mask incomplete");
        // a soul must still render (never-revert guarantee, live path)
        require(bytes(diamond.tokenURI(99)).length > 100, "soul render broken");
    }
}
