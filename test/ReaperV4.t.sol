// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ReaperFacetV4} from "../src/facets/ReaperFacetV4.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";

/// THE ORDER IS CLOSED — unit tests for ReaperFacetV4 (Replace of `offer`).
///
/// setUp rebuilds the LIVE diamond shape in order (ReaperFacet Add + ReaperInit ->
/// V2 Replace offer/forgeMark -> V3 Replace marksOf/forgeMark) and then, per test,
/// applies the V4 Replace of `offer` via _v4(). Three OG souls are prepared through
/// real convert()s: ASCENDED (fed to 30 BEFORE the closure — the twelve), ASPIRANT
/// (fed to 6 before the closure — #1682/#2474's real situation) and VIRGIN (0).
/// A non-OG soul (freed via ConvertFacetV2) checks the guard ORDER.
contract ReaperV4Test is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    ConvertFacetV2 convV2;
    ReaperFacet reaper; // typed handle; selectors route per the current cut

    uint256 constant ASCENDED = 3995; // OG, fed to 30 pre-closure (one of "the twelve")
    uint256 constant ASPIRANT = 4100; // OG, fed to 6 pre-closure (sealed by the closure)
    uint256 constant VIRGIN = 4200; // OG, never lit the fire
    uint256 constant NONOG = 250; // freed via ConvertFacetV2 (freedAt != 0)

    address treasury = makeAddr("treasury");
    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    // canvas id books, kept disjoint so no test feeds a burned id twice
    uint256 nextCanvas = 1000;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _applyReaperCut(); // Add full ReaperFacet (10 selectors) + seed markPrices
        _applyReaperV2Replace(); // Replace offer + forgeMark -> V2 (OG guard)
        _applyReaperV3Replace(); // Replace marksOf + forgeMark -> V3 (economy V2)

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        reaper = ReaperFacet(diamond);

        // Canvas bank for the holder + the three OG souls, all via V1 convert (OG).
        pikkazo.mint(holder, ASCENDED);
        pikkazo.mint(holder, ASPIRANT);
        pikkazo.mint(holder, VIRGIN);
        for (uint256 i = nextCanvas; i < nextCanvas + 300; i++) {
            pikkazo.mint(holder, i);
        }
        pikkazo.mint(stranger, 777);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        conv.convert(_arr(ASCENDED));
        conv.convert(_arr(ASPIRANT));
        conv.convert(_arr(VIRGIN));
        vm.stopPrank();

        vm.prank(stranger);
        pikkazo.setApprovalForAll(diamond, true);

        // A non-OG soul, freed through the paid V2 sale.
        _applyConvertV2Cut(uint64(block.timestamp));
        convV2 = ConvertFacetV2(diamond);
        pikkazo.mint(holder, NONOG);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        convV2.convert{value: P3}(_arr(NONOG));
        assertTrue(convV2.cohortOf(NONOG) != 0, "NONOG must be non-OG");

        // Pre-closure history: the twelve ascend, an aspirant is mid-climb.
        vm.prank(holder);
        reaper.offer(ASCENDED, _canvases(30));
        vm.prank(holder);
        reaper.offer(ASPIRANT, _canvases(6));
        assertEq(reaper.soulsConsumed(ASCENDED), 30, "ascended at 30 pre-closure");
        assertEq(reaper.soulsConsumed(ASPIRANT), 6, "aspirant at 6 pre-closure");
        assertTrue(reaper.isReaper(ASCENDED));
        assertFalse(reaper.isReaper(ASPIRANT));
    }

    // ------------------------------------------------------------ the closure

    /// The twelve keep reaping: an already-ascended reaper can still burn canvases
    /// after the Order closes, and its total keeps climbing past 30.
    function test_v4_ascendedReaperKeepsReaping() public {
        address v4 = _v4();
        assertEq(IDiamondLoupe(diamond).facetAddress(ReaperFacet.offer.selector), v4, "offer -> V4");

        uint256[] memory feed = _canvases(5);
        vm.prank(holder);
        reaper.offer(ASCENDED, feed);

        assertEq(reaper.soulsConsumed(ASCENDED), 35, "the twelve keep climbing");
        for (uint256 i = 0; i < feed.length; i++) {
            assertEq(pikkazo.ownerOfMap(feed[i]), address(0), "canvas really burned");
            assertTrue(reaper.isCanvasConsumed(feed[i]), "consumed flag set");
        }
        assertTrue(reaper.isReaper(ASCENDED));
    }

    /// No new reapers: a soul mid-climb (0 < consumed < 30) is sealed where it stands.
    /// The revert carries its sealed total, and NOT ONE canvas is burned.
    function test_v4_aspirantIsSealed() public {
        _v4();
        uint256[] memory feed = _canvases(24); // exactly what it needed to reach 30

        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, ASPIRANT, 6));
        vm.prank(holder);
        reaper.offer(ASPIRANT, feed);

        assertEq(reaper.soulsConsumed(ASPIRANT), 6, "aspirant sealed at 6");
        assertFalse(reaper.isReaper(ASPIRANT), "never a reaper");
        for (uint256 i = 0; i < feed.length; i++) {
            assertEq(pikkazo.ownerOfMap(feed[i]), holder, "rejected offering burns nothing");
            assertFalse(reaper.isCanvasConsumed(feed[i]), "canvas untouched");
        }
    }

    /// No new initiates: a soul that never lit the fire cannot start.
    function test_v4_virginSoulCannotInitiate() public {
        _v4();
        uint256[] memory feed = _canvases(1);

        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, VIRGIN, 0));
        vm.prank(holder);
        reaper.offer(VIRGIN, feed);

        assertEq(pikkazo.ownerOfMap(feed[0]), holder, "no burn");
        assertEq(reaper.soulsConsumed(VIRGIN), 0);
    }

    /// The roster can never grow again: ReaperAscended cannot be emitted post-closure.
    /// (A reaper past 30 emits SoulsOffered only; anything below 30 reverts.)
    function test_v4_ascensionEventCanNeverFireAgain() public {
        _v4();
        vm.recordLogs();
        vm.prank(holder);
        reaper.offer(ASCENDED, _canvases(3));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 ascendedTopic = keccak256("ReaperAscended(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ascendedTopic, "no new ascension, ever");
        }
    }

    // -------------------------------------------------- guards kept, in order

    /// The OG guard runs BEFORE the closure guard: a non-OG soul still reads as
    /// NotOGSoul (the closure must not shadow or reorder the existing gates).
    function test_v4_nonOGStillNotOGSoul() public {
        _v4();
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.NotOGSoul.selector, NONOG));
        vm.prank(holder);
        reaper.offer(NONOG, _canvases(1));
    }

    /// Ownership is still checked first — a stranger gets NotReaperOwner, not
    /// OrderClosed (no information about the roster leaks to non-owners).
    function test_v4_ownershipStillCheckedFirst() public {
        _v4();
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.NotReaperOwner.selector, ASCENDED));
        vm.prank(stranger);
        reaper.offer(ASCENDED, _canvases(1));
    }

    /// The global pause still wins over everything, even for the twelve.
    function test_v4_pauseStillWins() public {
        _v4();
        vm.prank(owner_);
        reaper.setReaperPaused(true);
        vm.expectRevert(ReaperFacetV4.ReaperIsPaused.selector);
        vm.prank(holder);
        reaper.offer(ASCENDED, _canvases(1));
    }

    /// Batch bounds are unchanged: empty and >50 still revert for the twelve.
    function test_v4_batchBoundsUnchanged() public {
        _v4();
        vm.expectRevert(ReaperFacetV4.NothingOffered.selector);
        vm.prank(holder);
        reaper.offer(ASCENDED, new uint256[](0));

        vm.expectRevert(ReaperFacetV4.TooManyAtOnce.selector);
        vm.prank(holder);
        reaper.offer(ASCENDED, _canvases(51));
    }

    /// A reaper cannot be fed a third party's canvas (the operator defense survives).
    function test_v4_cannotFeedSomeoneElsesCanvas() public {
        _v4();
        uint256[] memory notMine = _arr(777); // stranger's canvas
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.NotYourPikkazo.selector, 777));
        vm.prank(holder);
        reaper.offer(ASCENDED, notMine);
    }

    // ------------------------------------------------- everything else intact

    /// The rest of the reaper surface is untouched by this cut: forgeMark still
    /// ForgeDeprecated (V3), marksOf still the derived milestone view, views live on
    /// their original facets.
    function test_v4_restOfSurfaceUntouched() public {
        address v1 = IDiamondLoupe(diamond).facetAddress(ReaperFacet.isReaper.selector);
        address v3 = IDiamondLoupe(diamond).facetAddress(ReaperFacet.forgeMark.selector);
        address v4 = _v4();

        assertEq(IDiamondLoupe(diamond).facetAddress(ReaperFacet.isReaper.selector), v1, "isReaper stays");
        assertEq(IDiamondLoupe(diamond).facetAddress(ReaperFacet.forgeMark.selector), v3, "forgeMark stays V3");
        assertEq(IDiamondLoupe(diamond).facetAddress(ReaperFacet.marksOf.selector), v3, "marksOf stays V3");
        assertTrue(v4 != v3 && v4 != v1, "V4 is its own facet");

        vm.expectRevert(ReaperFacetV3.ForgeDeprecated.selector);
        vm.prank(holder);
        reaper.forgeMark(ASCENDED, 0, new uint256[](6));

        // derived milestones: 30 consumed == every mark; 6 == Orange only.
        assertEq(reaper.marksOf(ASCENDED), 0xF, "all four milestones at 30");
        assertEq(reaper.marksOf(ASPIRANT), 1, "Orange only at 6");
        assertEq(reaper.markPrice(3), 30, "thresholds untouched");
    }

    /// Reopening the Order is possible only through another explicit cut (the
    /// diamond stays evolutionary — the closure is code, not a one-way trapdoor).
    function test_v4_reopeningRequiresAnotherCut() public {
        _v4();
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, ASPIRANT, 6));
        vm.prank(holder);
        reaper.offer(ASPIRANT, _canvases(1));

        // owner cuts `offer` back to V2 -> the rite is open again
        _applyReaperV2Replace();
        vm.prank(holder);
        reaper.offer(ASPIRANT, _canvases(1));
        assertEq(reaper.soulsConsumed(ASPIRANT), 7, "reopened by cut");
    }

    // ---------------------------------------------------------- cut wiring

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
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ReaperFacet.offer.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        // forgeMark also moves to V2 the first time (mirrors the live cut history);
        // it is Replaced again by V3 right after, so only `offer` matters here.
    }

    function _applyReaperV3Replace() internal {
        ReaperFacetV3 facet = new ReaperFacetV3();
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacetV3.marksOf.selector;
        rep[1] = ReaperFacetV3.forgeMark.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    /// THE CUT UNDER TEST: Replace exactly `offer` (0x9d6f563d) -> ReaperFacetV4.
    function _v4() internal returns (address v4addr) {
        ReaperFacetV4 facet = new ReaperFacetV4();
        v4addr = address(facet);
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ReaperFacetV4.offer.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: v4addr,
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
        rep[0] = ConvertFacet.convert.selector;
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
            cuts,
            address(initC),
            abi.encodeCall(ConvertV2Init.init, (start, B1, B2, B3, P1, P2, P3, treasury))
        );
    }

    // ------------------------------------------------------------- helpers

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    /// Hand out `n` fresh canvas ids the holder owns (never reused across a test).
    function _canvases(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = nextCanvas + i;
        }
        nextCanvas += n;
    }
}
