// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {TraitOverride} from "../src/onchain/TraitOverride.sol";
import {SoulRendererV4_1} from "../src/onchain/SoulRendererV4_1.sol";
import {RevisionManifest} from "../script/RevisionManifest.sol";
import {SvgStrip} from "../script/SvgStrip.sol";

interface IOwner {
    function owner() external view returns (address);
}

interface ISoulsAdmin {
    function setRenderer(address newRenderer) external;
    function renderer() external view returns (address);
    function rendererFrozen() external view returns (bool);
}

interface ISvgStoreRead {
    function owner() external view returns (address);
    function nextOption(uint8 cat) external view returns (uint16);
    function traitExists(uint16 traitId) external view returns (bool);
    function traitName(uint16 traitId) external view returns (string memory);
}

interface ISoulRenderer {
    function tokenURI(uint256) external view returns (string memory);
}

/// @title RevisionsForkGas - full-flow dry-run of the artist-revision rollout on a
///        mainnet fork against the LIVE SvgStore + Diamond, with gas measured per
///        phase. Runs only when ETH_RPC is set:
///          ETH_RPC=<mainnet rpc> forge test --match-contract RevisionsForkGas -vv
contract RevisionsForkGasTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant STORE = 0x6702016627141350792Dd366885a2Fc794eE46C6;
    uint256 constant TOKEN = 136; // white-hoodie + colony (2 revisions)

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
    }

    function test_fork_fullFlow_gasByPhase() public {
        (uint16[] memory from, uint16[] memory to, string[] memory names, string[] memory paths) =
            RevisionManifest.all();

        // ---- drift guard on the live store (proves target ids are still free) ----
        ISvgStoreRead sr = ISvgStoreRead(STORE);
        for (uint256 i; i < to.length; ++i) {
            assertTrue(sr.traitExists(from[i]), "orig exists");
            assertFalse(sr.traitExists(to[i]), "target free");
            assertEq(uint8(to[i] >> 8), uint8(from[i] >> 8), "same cat");
        }

        // =================================================== PHASE 1: upload (21x)
        address storeOwner = sr.owner();
        SvgStore store = SvgStore(STORE);
        uint256 totalUpload;
        uint256 maxTx;
        for (uint256 i; i < to.length; ++i) {
            bytes memory inner = SvgStrip.inner(bytes(vm.readFile(paths[i])));
            vm.prank(storeOwner);
            uint256 g = gasleft();
            store.setTrait(to[i], names[i], inner);
            g = g - gasleft();
            totalUpload += g;
            if (g > maxTx) maxTx = g;
            // name preserved from the original
            assertEq(store.traitName(to[i]), store.traitName(from[i]));
        }
        console2.log("PHASE 1 upload 21 setTrait  total gas:", totalUpload);
        console2.log("PHASE 1   max single setTrait gas:", maxTx);
        console2.log("PHASE 1   avg per setTrait gas:", totalUpload / 21);

        // ============================================ PHASE 2: deploy TraitOverride
        uint256 g2 = gasleft();
        TraitOverride ovr = new TraitOverride();
        g2 = g2 - gasleft();
        console2.log("PHASE 2 deploy TraitOverride gas:", g2);

        // ================================================= PHASE 3: setOverrides(21)
        uint256 g3 = gasleft();
        ovr.setOverrides(from, to);
        g3 = g3 - gasleft();
        console2.log("PHASE 3 setOverrides(21) gas:", g3);

        // ============================================ PHASE 4: deploy SoulRendererV4_1
        uint256 g4 = gasleft();
        SoulRendererV4_1 v41 = new SoulRendererV4_1(DIAMOND, STORE, address(ovr));
        g4 = g4 - gasleft();
        console2.log("PHASE 4 deploy SoulRendererV4_1 gas:", g4);

        // =================================================== PHASE 5: setRenderer
        require(!ISoulsAdmin(DIAMOND).rendererFrozen(), "renderer frozen");
        address dOwner = IOwner(DIAMOND).owner();
        vm.prank(dOwner);
        uint256 g5 = gasleft();
        ISoulsAdmin(DIAMOND).setRenderer(address(v41));
        g5 = g5 - gasleft();
        console2.log("PHASE 5 setRenderer gas:", g5);

        assertEq(ISoulsAdmin(DIAMOND).renderer(), address(v41), "renderer live");

        // ------- read-back: the diamond now serves the revised art on #136 -------
        string memory uri = ISoulRenderer(DIAMOND).tokenURI(TOKEN);
        assertTrue(bytes(uri).length > 0, "tokenURI");
        // resolve wired
        assertEq(ovr.resolve(526), to[11]); // white-hoodie 0x020E -> its v2 target

        console2.log("---------------------------------------------");
        console2.log("TOTAL gas (phases 1-5):", totalUpload + g2 + g3 + g4 + g5);
        console2.log("Renderer now live on diamond:", address(v41));
    }
}
