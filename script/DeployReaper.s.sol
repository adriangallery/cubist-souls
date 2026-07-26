// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";

interface IPikkazoLike {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
    function totalSupply() external view returns (uint256);
}

/// @title DeployReaper - assemble the ADD-only ReaperFacet cut (NO broadcast)
/// @notice Two modes, both simulation-only (never touches mainnet):
///
///   1) PLAN (default, no fork):  forge script script/DeployReaper.s.sol
///      Deploys ReaperFacet + ReaperInit locally and PRINTS the exact diamondCut
///      plan (Add selectors + init calldata). Nothing on-chain.
///
///   2) DRY-RUN E2E (fork):       ETH_RPC=<url> forge script script/DeployReaper.s.sol
///      Forks mainnet by STATE, impersonates the live diamond owner to apply the
///      ADD cut, verifies the views post-cut (seeded mark prices, unpaused), then
///      impersonates a real Pikkazo holder (given a real Soul) to run a real
///      offer() and prove burn+consume against LIVE state. Still NEVER broadcasts.
///
/// The real broadcast lives in script/ExecuteReaper.s.sol (owner key required).
contract DeployReaper is Script {
    address constant DIAMOND_MAINNET = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO_MAINNET = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    function reaperAddSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ReaperFacet.offer.selector;
        s[1] = ReaperFacet.forgeMark.selector;
        s[2] = ReaperFacet.soulsConsumed.selector;
        s[3] = ReaperFacet.marksOf.selector;
        s[4] = ReaperFacet.isReaper.selector;
        s[5] = ReaperFacet.markPrice.selector;
        s[6] = ReaperFacet.setMarkPrice.selector;
        s[7] = ReaperFacet.setReaperPaused.selector;
        s[8] = ReaperFacet.reaperPaused.selector;
        s[9] = ReaperFacet.isCanvasConsumed.selector;
    }

    function _buildCut(address facet) internal pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: reaperAddSelectors()
        });
    }

    function run() external {
        address diamond = vm.envOr("DIAMOND", DIAMOND_MAINNET);
        string memory rpc = vm.envOr("ETH_RPC", string(""));

        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        bytes memory initCalldata = abi.encodeCall(ReaperInit.init, ());

        console.log("=== ReaperFacet ADD cut PLAN (no broadcast) ===");
        console.log("Diamond:      ", diamond);
        console.log("ReaperFacet:  ", address(facet));
        console.log("ReaperInit:   ", address(initC));
        console.log("ADD selectors -> ReaperFacet:");
        bytes4[] memory adds = reaperAddSelectors();
        for (uint256 i = 0; i < adds.length; i++) {
            console.logBytes4(adds[i]);
        }
        console.log("init calldata (ReaperInit.init):");
        console.logBytes(initCalldata);

        if (bytes(rpc).length == 0) {
            console.log("No ETH_RPC set -> PLAN mode only. Set ETH_RPC to run fork E2E.");
            return;
        }

        _forkE2E(diamond);
    }

    function _forkE2E(address diamond) internal {
        vm.createSelectFork(vm.envString("ETH_RPC"));

        // re-deploy inside the fork so the facet/init have code here
        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();

        address owner_ = OwnershipFacet(diamond).owner();
        console.log("\n=== FORK DRY-RUN E2E vs LIVE diamond ===");
        console.log("Live owner:   ", owner_);

        uint256 gasBefore = gasleft();
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(_buildCut(address(facet)), address(initC), abi.encodeCall(ReaperInit.init, ()));
        uint256 cutGas = gasBefore - gasleft();
        console.log("diamondCut gas:", cutGas);

        ReaperFacet reaper = ReaperFacet(diamond);
        SoulsERC721Facet souls = SoulsERC721Facet(diamond);

        // ---- post-cut view verification ----
        require(reaper.markPrice(0) == 6, "Orange price");
        require(reaper.markPrice(1) == 12, "FlameCrown price");
        require(reaper.markPrice(2) == 18, "Phoenix price");
        require(reaper.markPrice(3) == 30, "BurningSoul price");
        require(!reaper.reaperPaused(), "should be unpaused");
        console.log("views OK: mark prices 6/12/18/30, unpaused");

        // ---- real offer as a live holder ----
        (address holder, uint256[] memory ids) = _findHolderCanvases(diamond);
        require(ids.length > 0, "holder has no candidate canvases");
        uint256 reaperId = 136;
        address soulOwner = souls.ownerOf(reaperId);
        vm.prank(soulOwner);
        souls.transferFrom(soulOwner, holder, reaperId); // holder becomes a reaper

        vm.prank(holder);
        IPikkazoLike(PIKKAZO_MAINNET).setApprovalForAll(diamond, true);

        uint256 pikBefore = IPikkazoLike(PIKKAZO_MAINNET).totalSupply();
        uint256 soulBefore = souls.totalSupply();

        uint256 g2 = gasleft();
        vm.prank(holder);
        reaper.offer(reaperId, ids);
        uint256 offerGas = g2 - gasleft();

        require(reaper.soulsConsumed(reaperId) == ids.length, "consumed mismatch");
        require(IPikkazoLike(PIKKAZO_MAINNET).totalSupply() == pikBefore - ids.length, "canvases not burned");
        require(souls.totalSupply() == soulBefore, "unexpected soul mint");
        for (uint256 i = 0; i < ids.length; i++) {
            require(reaper.isCanvasConsumed(ids[i]), "canvas not flagged consumed");
        }

        console.log("Impersonated holder:", holder);
        console.log("Reaper (Soul) id:   ", reaperId);
        console.log("Canvases offered:   ", ids.length);
        console.log("offer() gas:        ", offerGas);
        console.log("soulsConsumed now:  ", reaper.soulsConsumed(reaperId));
        console.log("=== E2E PASSED ===");
    }

    function _findHolderCanvases(address /*diamond*/ ) internal view returns (address holder, uint256[] memory ids) {
        uint16[20] memory c =
            [uint16(3995), 99, 100, 2500, 4200, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9200, 9500, 500, 1500, 2000, 3000, 3500, 5000];
        for (uint256 i = 0; i < c.length; i++) {
            try IPikkazoLike(PIKKAZO_MAINNET).ownerOf(c[i]) returns (address o) {
                if (o != address(0) && o.code.length == 0) {
                    holder = o;
                    break;
                }
            } catch {}
        }
        require(holder != address(0), "no live EOA canvas");
        uint256[] memory tmp = new uint256[](c.length);
        uint256 k;
        for (uint256 i = 0; i < c.length; i++) {
            try IPikkazoLike(PIKKAZO_MAINNET).ownerOf(c[i]) returns (address o) {
                if (o == holder) tmp[k++] = c[i];
            } catch {}
        }
        ids = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            ids[i] = tmp[i];
        }
    }
}
