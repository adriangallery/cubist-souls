// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
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

/// Fork test that applies the ADD-only ReaperFacet cut to the REAL LIVE Cubist Souls
/// diamond on Ethereum mainnet and exercises the views + a real offer against live
/// state. Runs only when ETH_RPC is set (fork by STATE, no getLogs):
///   ETH_RPC=<url> forge test --match-contract ReaperFork -vv
contract ReaperForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    address owner_;
    ReaperFacet reaper;
    SoulsERC721Facet souls;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);

        owner_ = OwnershipFacet(DIAMOND).owner();
        _applyReaperCut();

        reaper = ReaperFacet(DIAMOND);
        souls = SoulsERC721Facet(DIAMOND);
    }

    function _reaperSelectors() internal pure returns (bytes4[] memory s) {
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

    function _applyReaperCut() internal {
        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Add, _reaperSelectors());
        vm.prank(owner_);
        IDiamondCut(DIAMOND).diamondCut(cuts, address(initC), abi.encodeCall(ReaperInit.init, ()));
    }

    /// Find one live EOA Pikkazo holder and up to `max` of its canvases.
    function _findHolderCanvases(uint256 max) internal view returns (address holder, uint256[] memory ids) {
        uint16[20] memory c =
            [uint16(3995), 99, 100, 2500, 4200, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9200, 9500, 500, 1500, 2000, 3000, 3500, 5000];
        // pick the first live EOA holder
        for (uint256 i = 0; i < c.length; i++) {
            try IPikkazoLike(PIKKAZO).ownerOf(c[i]) returns (address o) {
                if (o != address(0) && o.code.length == 0) {
                    holder = o;
                    break;
                }
            } catch {}
        }
        require(holder != address(0), "no live EOA canvas");
        // collect that holder's canvases among the candidates (bounded by max)
        uint256[] memory tmp = new uint256[](c.length);
        uint256 k;
        for (uint256 i = 0; i < c.length && k < max; i++) {
            try IPikkazoLike(PIKKAZO).ownerOf(c[i]) returns (address o) {
                if (o == holder) {
                    tmp[k++] = c[i];
                }
            } catch {}
        }
        ids = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            ids[i] = tmp[i];
        }
    }

    // Post-cut view verification.
    function test_fork_viewsResolveAndSeeded() public view {
        IDiamondLoupe loupe = IDiamondLoupe(DIAMOND);
        assertTrue(loupe.facetAddress(ReaperFacet.offer.selector) != address(0));
        assertEq(reaper.markPrice(0), 6);
        assertEq(reaper.markPrice(1), 12);
        assertEq(reaper.markPrice(2), 18);
        assertEq(reaper.markPrice(3), 30);
        assertFalse(reaper.reaperPaused());
        // #136 is a real minted Soul on the live diamond; untouched by reaper yet
        assertEq(reaper.soulsConsumed(136), 0);
        assertFalse(reaper.isReaper(136));
        assertEq(reaper.marksOf(136), 0);
    }

    // Real offer as a live holder: give the holder a real Soul (transfer #136 from
    // its live owner), then offer its own live canvases and prove the burn+consume.
    function test_fork_offerAsRealHolder() public {
        (address holder, uint256[] memory ids) = _findHolderCanvases(3);
        require(ids.length > 0, "holder has no candidate canvases");

        uint256 reaperId = 136;
        address soulOwner = souls.ownerOf(reaperId);
        vm.prank(soulOwner);
        souls.transferFrom(soulOwner, holder, reaperId); // holder becomes a reaper
        assertEq(souls.ownerOf(reaperId), holder);

        vm.prank(holder);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);

        uint256 pikSupplyBefore = IPikkazoLike(PIKKAZO).totalSupply();
        uint256 soulSupplyBefore = souls.totalSupply();

        vm.prank(holder);
        reaper.offer(reaperId, ids);

        // consumed count grew by the number of canvases; reaper flagged if >=30
        assertEq(reaper.soulsConsumed(reaperId), ids.length);
        // each canvas burned on Pikkazo + flagged consumed forever
        assertEq(IPikkazoLike(PIKKAZO).totalSupply(), pikSupplyBefore - ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(reaper.isCanvasConsumed(ids[i]));
        }
        // NO Soul minted for offered canvases -> souls supply unchanged
        assertEq(souls.totalSupply(), soulSupplyBefore);
    }
}
