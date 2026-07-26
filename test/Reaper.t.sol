// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {SoulsAdminFacet} from "../src/facets/SoulsAdminFacet.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {RescueFreeFacet} from "../src/facets/RescueFreeFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {LibSouls} from "../src/libraries/LibSouls.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// Exhaustive unit tests for the ReaperFacet (Soul Reapers). setUp builds the live
/// diamond shape, applies the ADD-only Reaper cut with ReaperInit (exactly the
/// production path), also adds RescueFreeFacet so the "offered canvas is never
/// rescuable" guarantee can be proven end-to-end, then mints a reaper Soul to the
/// holder via a real convert() so the reaper is a genuine token holder.
contract ReaperTest is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    SoulsAdminFacet admin;
    ReaperFacet reaper;
    RescueFreeFacet rescue;

    uint256 constant REAPER = 3995; // the Soul the holder converts and then feeds

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _applyReaperCut();
        _addRescueFacet();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        admin = SoulsAdminFacet(diamond);
        reaper = ReaperFacet(diamond);
        rescue = RescueFreeFacet(diamond);

        // Give the holder a reaper Soul (id 3995) via a real convert, and a big
        // stock of canvases (100..199) to offer/forge with.
        pikkazo.mint(holder, REAPER);
        for (uint256 i = 100; i < 200; i++) {
            pikkazo.mint(holder, i);
        }
        pikkazo.mint(stranger, 777);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        conv.convert(_arr(REAPER)); // holder now owns Soul 3995
        vm.stopPrank();
        assertEq(souls.ownerOf(REAPER), holder);

        vm.prank(stranger);
        pikkazo.setApprovalForAll(diamond, true);
    }

    // ------------------------------------------------------------ cut wiring

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
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _reaperSelectors()
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(initC), abi.encodeCall(ReaperInit.init, ()));
    }

    function _addRescueFacet() internal {
        RescueFreeFacet facet = new RescueFreeFacet();
        Deploy d = new Deploy();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: d.rescueSelectors()
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _range(uint256 start, uint256 count) internal pure returns (uint256[] memory x) {
        x = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            x[i] = start + i;
        }
    }

    // ----------------------------------------------------------------- wiring

    function test_cut_selectorsResolveAndConvertRegression() public view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address rf = loupe.facetAddress(ReaperFacet.offer.selector);
        assertTrue(rf != address(0));
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.soulsConsumed.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.isReaper.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.markPrice.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.setMarkPrice.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.setReaperPaused.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.reaperPaused.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.isCanvasConsumed.selector), rf);
        // regression: convert + friends still resolve to their own facets
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != address(0));
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != rf);
        assertTrue(loupe.facetAddress(ConvertFacet.isFreed.selector) != address(0));
    }

    function test_markPrices_seededByInit() public view {
        assertEq(reaper.markPrice(0), 6); // Orange
        assertEq(reaper.markPrice(1), 12); // FlameCrown
        assertEq(reaper.markPrice(2), 18); // Phoenix
        assertEq(reaper.markPrice(3), 30); // BurningSoul
        assertEq(reaper.markPrice(4), 0); // unconfigured
        assertFalse(reaper.reaperPaused());
    }

    // ------------------------------------------------------------------ offer

    function test_offer_happy() public {
        uint256[] memory ids = _range(100, 3);
        vm.expectEmit(true, true, false, true, diamond);
        emit ReaperFacet.SoulsOffered(REAPER, holder, ids, 3);
        vm.prank(holder);
        reaper.offer(REAPER, ids);

        assertEq(reaper.soulsConsumed(REAPER), 3);
        assertFalse(reaper.isReaper(REAPER));
        // canvases burned on Pikkazo + flagged consumed forever
        for (uint256 i = 100; i < 103; i++) {
            assertTrue(reaper.isCanvasConsumed(i));
            vm.expectRevert(MockPikkazo.OwnerQueryForNonexistentToken.selector);
            pikkazo.ownerOf(i);
        }
        // no Soul minted for offered canvases
        assertEq(souls.balanceOf(holder), 1); // only the reaper itself
    }

    function test_offer_accumulates() public {
        vm.startPrank(holder);
        reaper.offer(REAPER, _range(100, 5));
        reaper.offer(REAPER, _range(105, 4));
        vm.stopPrank();
        assertEq(reaper.soulsConsumed(REAPER), 9);
    }

    function test_offer_empty_reverts() public {
        vm.prank(holder);
        vm.expectRevert(ReaperFacet.NothingOffered.selector);
        reaper.offer(REAPER, new uint256[](0));
    }

    function test_offer_max50_reverts() public {
        vm.prank(holder);
        vm.expectRevert(ReaperFacet.TooManyAtOnce.selector);
        reaper.offer(REAPER, new uint256[](51));
    }

    function test_offer_notReaperOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.NotReaperOwner.selector, REAPER));
        reaper.offer(REAPER, _range(100, 1));
    }

    function test_offer_pikkazoAjeno_reverts() public {
        // holder owns the reaper but tries to offer stranger's canvas 777
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.NotYourPikkazo.selector, 777));
        reaper.offer(REAPER, _arr(777));
    }

    // ------------------------------------------------------------- forgeMark

    function test_forgeMark_happy() public {
        uint256[] memory ids = _range(100, 6); // Orange price = 6
        vm.expectEmit(true, true, false, true, diamond);
        emit ReaperFacet.MarkForged(REAPER, 0, 6, 6);
        vm.prank(holder);
        reaper.forgeMark(REAPER, 0, ids);

        assertEq(reaper.marksOf(REAPER), 1 << 0);
        assertEq(reaper.soulsConsumed(REAPER), 6);
    }

    function test_forgeMark_multipleMarksCombine() public {
        vm.startPrank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6)); // Orange
        reaper.forgeMark(REAPER, 1, _range(110, 12)); // FlameCrown
        vm.stopPrank();
        assertEq(reaper.marksOf(REAPER), (1 << 0) | (1 << 1));
        assertEq(reaper.soulsConsumed(REAPER), 18);
    }

    function test_forgeMark_doubleSameMark_reverts() public {
        vm.startPrank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6));
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.MarkAlreadyForged.selector, REAPER, uint8(0)));
        reaper.forgeMark(REAPER, 0, _range(110, 6));
        vm.stopPrank();
    }

    function test_forgeMark_wrongSize_reverts() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.WrongOfferingSize.selector, 6, 5));
        reaper.forgeMark(REAPER, 0, _range(100, 5));
    }

    function test_forgeMark_notConfigured_reverts() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.MarkNotConfigured.selector, uint8(7)));
        reaper.forgeMark(REAPER, 7, _range(100, 1));
    }

    function test_forgeMark_notReaperOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.NotReaperOwner.selector, REAPER));
        reaper.forgeMark(REAPER, 0, _range(100, 6));
    }

    // ------------------------------------------------------------- ascension

    function test_ascension_firesOnceAtThreshold() public {
        // 29 first: no ascension
        vm.prank(holder);
        reaper.offer(REAPER, _range(100, 29));
        assertEq(reaper.soulsConsumed(REAPER), 29);
        assertFalse(reaper.isReaper(REAPER));

        // the 30th crosses -> ReaperAscended fires exactly once with consumed=30
        vm.expectEmit(true, false, false, true, diamond);
        emit ReaperFacet.ReaperAscended(REAPER, 30);
        vm.prank(holder);
        reaper.offer(REAPER, _range(129, 1));
        assertTrue(reaper.isReaper(REAPER));

        // further offerings do NOT re-emit ReaperAscended
        vm.recordLogs();
        vm.prank(holder);
        reaper.offer(REAPER, _range(130, 3));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 ascendTopic = keccak256("ReaperAscended(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ascendTopic, "ReaperAscended re-emitted");
        }
        assertEq(reaper.soulsConsumed(REAPER), 33);
    }

    function test_ascension_viaForgeMarkBurningSoul() public {
        // BurningSoul (mark 3) costs 30 -> a single forge crosses the threshold
        vm.expectEmit(true, false, false, true, diamond);
        emit ReaperFacet.ReaperAscended(REAPER, 30);
        vm.prank(holder);
        reaper.forgeMark(REAPER, 3, _range(100, 30));
        assertTrue(reaper.isReaper(REAPER));
        assertEq(reaper.marksOf(REAPER), 1 << 3);
    }

    // ------------------------------------------------------- pause / admin

    function test_paused_blocksOfferAndForge() public {
        vm.prank(owner_);
        reaper.setReaperPaused(true);
        assertTrue(reaper.reaperPaused());

        vm.prank(holder);
        vm.expectRevert(ReaperFacet.ReaperIsPaused.selector);
        reaper.offer(REAPER, _range(100, 1));

        vm.prank(holder);
        vm.expectRevert(ReaperFacet.ReaperIsPaused.selector);
        reaper.forgeMark(REAPER, 0, _range(100, 6));

        // unpause -> works again
        vm.prank(owner_);
        reaper.setReaperPaused(false);
        vm.prank(holder);
        reaper.offer(REAPER, _range(100, 1));
        assertEq(reaper.soulsConsumed(REAPER), 1);
    }

    function test_setReaperPaused_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        reaper.setReaperPaused(true);
    }

    function test_setMarkPrice_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        reaper.setMarkPrice(0, 10);
    }

    function test_setMarkPrice_hotChangeApplies() public {
        // owner bumps Orange from 6 -> 10 mid-flight
        vm.prank(owner_);
        reaper.setMarkPrice(0, 10);
        assertEq(reaper.markPrice(0), 10);

        // old size (6) now reverts, new size (10) works
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.WrongOfferingSize.selector, 10, 6));
        reaper.forgeMark(REAPER, 0, _range(100, 6));

        vm.prank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 10));
        assertEq(reaper.marksOf(REAPER), 1 << 0);
        assertEq(reaper.soulsConsumed(REAPER), 10);
    }

    // ---------------------------------------------- marks travel with token

    function test_marksAndConsumed_travelWithToken() public {
        vm.startPrank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6));
        reaper.offer(REAPER, _range(110, 4));
        souls.transferFrom(holder, stranger, REAPER); // sell the reaper
        vm.stopPrank();

        assertEq(souls.ownerOf(REAPER), stranger);
        // marks + consumed are keyed by token id -> they follow the token
        assertEq(reaper.marksOf(REAPER), 1 << 0);
        assertEq(reaper.soulsConsumed(REAPER), 10);

        // and the new owner can keep feeding it
        pikkazo.mint(stranger, 900);
        vm.prank(stranger);
        reaper.offer(REAPER, _arr(900));
        assertEq(reaper.soulsConsumed(REAPER), 11);
    }

    // ---------------------------------- offered canvas is NEVER rescuable

    function test_offeredCanvas_neverRescuable() public {
        vm.prank(holder);
        reaper.offer(REAPER, _arr(150));
        assertTrue(reaper.isCanvasConsumed(150));

        // The live rescue path MUST refuse to mint a Soul for a consumed canvas.
        // (RescueFreeFacet here is recompiled with the guarded LibSouls.mint, so the
        //  guarantee is enforced on-chain, not by trust.)
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(LibSouls.CanvasConsumedByReaper.selector, 150));
        rescue.adminFreeBurned(stranger, _arr(150));
    }

    function test_offeredCanvas_cannotBeReConverted() public {
        vm.prank(holder);
        reaper.offer(REAPER, _arr(150));
        // canvas is burned on Pikkazo -> convert reverts at ownerOf
        vm.prank(holder);
        vm.expectRevert(MockPikkazo.OwnerQueryForNonexistentToken.selector);
        conv.convert(_arr(150));
    }

    function test_doubleOffer_sameCanvas_reverts() public {
        vm.startPrank(holder);
        reaper.offer(REAPER, _arr(150));
        // canvas already burned -> second offer reverts at Pikkazo.ownerOf
        vm.expectRevert(MockPikkazo.OwnerQueryForNonexistentToken.selector);
        reaper.offer(REAPER, _arr(150));
        vm.stopPrank();
    }
}
