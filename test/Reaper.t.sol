// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {SoulsAdminFacet} from "../src/facets/SoulsAdminFacet.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
import {RescueFreeFacet} from "../src/facets/RescueFreeFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
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
    ConvertFacetV2 convV2;
    SoulsAdminFacet admin;
    ReaperFacet reaper;
    RescueFreeFacet rescue;

    uint256 constant REAPER = 3995; // OG Soul (V1-converted, freedAt == 0) the holder feeds
    uint256 constant NONOG = 250; // non-OG Soul: freed via ConvertFacetV2 (freedAt != 0)

    // ConvertFacetV2 pricing (fixed here for deterministic tests)
    address treasury = makeAddr("treasury");
    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        // Live shape: Add the full ReaperFacet (views + admin + the 2 ritual entrypoints),
        // then REPLACE offer+forgeMark onto ReaperFacetV2 (the OG-only upgrade under test).
        _applyReaperCut();
        _applyReaperV2Replace();
        _addRescueFacet();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        admin = SoulsAdminFacet(diamond);
        reaper = ReaperFacet(diamond);
        rescue = RescueFreeFacet(diamond);

        // Give the holder an OG reaper Soul (id 3995) via a real V1 convert (V1 never
        // records freedAt -> cohort 0 -> OG), plus a big stock of canvases (100..199).
        pikkazo.mint(holder, REAPER);
        for (uint256 i = 100; i < 200; i++) {
            pikkazo.mint(holder, i);
        }
        pikkazo.mint(stranger, 777);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        conv.convert(_arr(REAPER)); // OG Soul 3995 (freedAt == 0)
        vm.stopPrank();
        assertEq(souls.ownerOf(REAPER), holder);

        vm.prank(stranger);
        pikkazo.setApprovalForAll(diamond, true);

        // Upgrade convert -> ConvertFacetV2 (mirrors the live diamond), then free a
        // NON-OG Soul (id 250) through V2 so it carries a non-zero freedAt (cohort 1).
        _applyConvertV2Cut(uint64(block.timestamp));
        convV2 = ConvertFacetV2(diamond);
        pikkazo.mint(holder, NONOG);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        convV2.convert(_arr(NONOG)); // free window (price 0) -> non-OG Soul 250
        assertEq(souls.ownerOf(NONOG), holder);
        assertTrue(convV2.cohortOf(NONOG) != 0, "NONOG must be non-OG");
        assertEq(convV2.cohortOf(REAPER), 0, "REAPER must be OG");
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

    function _applyReaperV2Replace() internal {
        ReaperFacetV2 facet = new ReaperFacetV2();
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacet.offer.selector; // 0x9d6f563d
        rep[1] = ReaperFacet.forgeMark.selector; // 0x900b4cc1
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _v2AddSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ConvertFacetV2.priceNow.selector;
        s[1] = ConvertFacetV2.freedAt.selector;
        s[2] = ConvertFacetV2.cohortOf.selector;
        s[3] = ConvertFacetV2.saleStart.selector;
        s[4] = ConvertFacetV2.pricing.selector;
        s[5] = ConvertFacetV2.setPricing.selector;
        s[6] = ConvertFacetV2.treasury.selector;
        s[7] = ConvertFacetV2.setTreasury.selector;
        s[8] = bytes4(keccak256("withdraw()"));
        s[9] = bytes4(keccak256("withdraw(address)"));
    }

    function _applyConvertV2Cut(uint64 start) internal {
        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector; // 0xd5ef903a
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _v2AddSelectors()
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(
            cuts, address(initC), abi.encodeCall(ConvertV2Init.init, (start, B1, B2, B3, P1, P2, P3, treasury))
        );
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
        // offer + forgeMark now route to ReaperFacetV2 (the Replace target)...
        address v2 = loupe.facetAddress(ReaperFacet.offer.selector);
        assertTrue(v2 != address(0));
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), v2);
        // ...while the 8 views/admin selectors STAY on the original ReaperFacet.
        address rf = loupe.facetAddress(ReaperFacet.soulsConsumed.selector);
        assertTrue(rf != address(0));
        assertTrue(rf != v2, "views must not move to V2");
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.isReaper.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.markPrice.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.setMarkPrice.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.setReaperPaused.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.reaperPaused.selector), rf);
        assertEq(loupe.facetAddress(ReaperFacet.isCanvasConsumed.selector), rf);
        // regression: convert + friends still resolve to their own facets
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != address(0));
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != v2);
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
        // no Soul minted for offered canvases (holder holds the OG reaper + the non-OG 250)
        assertEq(souls.balanceOf(holder), 2);
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

    // -------------------------------------------------- OG-ONLY (ReaperFacetV2)

    /// The OG Soul (cohort 0, freedAt == 0) offers normally — the rite works.
    function test_og_offer_works() public {
        assertEq(convV2.cohortOf(REAPER), 0);
        vm.prank(holder);
        reaper.offer(REAPER, _range(100, 3));
        assertEq(reaper.soulsConsumed(REAPER), 3);
    }

    /// The OG Soul can forge marks normally.
    function test_og_forgeMark_works() public {
        vm.prank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6));
        assertEq(reaper.marksOf(REAPER), 1 << 0);
        assertEq(reaper.soulsConsumed(REAPER), 6);
    }

    /// A NON-OG Soul (freed via V2, freedAt != 0) is barred from offering.
    function test_nonOG_offer_reverts() public {
        assertTrue(convV2.cohortOf(NONOG) != 0);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, NONOG));
        reaper.offer(NONOG, _range(100, 3));
    }

    /// A NON-OG Soul is barred from forging marks.
    function test_nonOG_forgeMark_reverts() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, NONOG));
        reaper.forgeMark(NONOG, 0, _range(100, 6));
    }

    /// The OG guard runs BEFORE any burn: a rejected non-OG offer destroys no canvas
    /// and moves no counter.
    function test_nonOG_revert_burnsNothing() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, NONOG));
        reaper.offer(NONOG, _range(100, 3));
        // canvases untouched, not flagged consumed, no consumption recorded
        for (uint256 i = 100; i < 103; i++) {
            assertEq(pikkazo.ownerOf(i), holder);
            assertFalse(reaper.isCanvasConsumed(i));
        }
        assertEq(reaper.soulsConsumed(NONOG), 0);
    }

    /// Ownership is still checked BEFORE the OG guard: a stranger calling on a Soul they
    /// do not own gets NotReaperOwner (not NotOGSoul), regardless of cohort.
    function test_ownerCheck_precedesOGGuard() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacet.NotReaperOwner.selector, NONOG));
        reaper.offer(NONOG, _range(100, 3));
    }

    /// Pausing still short-circuits before the OG guard (paused wins for any Soul).
    function test_paused_precedesOGGuard_forNonOG() public {
        vm.prank(owner_);
        reaper.setReaperPaused(true);
        vm.prank(holder);
        vm.expectRevert(ReaperFacet.ReaperIsPaused.selector);
        reaper.offer(NONOG, _range(100, 3));
    }
}
