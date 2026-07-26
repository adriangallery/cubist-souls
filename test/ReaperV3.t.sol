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
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {LibSouls} from "../src/libraries/LibSouls.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";

/// Economy-V2 unit tests for the Soul Reapers. setUp builds the LIVE diamond shape
/// through ReaperFacetV2 (Add full ReaperFacet + ReaperInit, then Replace offer/forgeMark
/// onto V2 with the OG guard) and mints an OG reaper Soul to the holder via a real
/// convert(). Each V3 test then applies the minimal Economy-V2 Replace (marksOf +
/// forgeMark -> ReaperFacetV3) via _v3(); the union tests seed legacy reaperMarks bits
/// through the still-live V2 forgeMark BEFORE cutting to V3, exactly as Adrian did on
/// #8777. The bit layout is 0=Orange 1=FlameCrown 2=Phoenix 3=BurningSoul.
contract ReaperV3Test is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    ConvertFacetV2 convV2;
    ReaperFacet reaper; // typed handle; selectors route per the current cut
    ReaperFacetV3 reaperV3; // for V3-only errors

    uint256 constant REAPER = 3995; // OG Soul (V1-converted, freedAt == 0)
    uint256 constant NONOG = 250; // non-OG Soul: freed via ConvertFacetV2 (freedAt != 0)

    address treasury = makeAddr("treasury");
    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    uint256 constant ORANGE = 1 << 0;
    uint256 constant FLAME = 1 << 1;
    uint256 constant PHOENIX = 1 << 2;
    uint256 constant BURNING = 1 << 3;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _applyReaperCut(); // Add full ReaperFacet (10 selectors) + seed markPrices
        _applyReaperV2Replace(); // Replace offer + forgeMark -> V2 (OG guard)

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        reaper = ReaperFacet(diamond);

        // OG reaper Soul (3995) via a real V1 convert (V1 never records freedAt -> OG).
        pikkazo.mint(holder, REAPER);
        for (uint256 i = 100; i < 300; i++) {
            pikkazo.mint(holder, i);
        }
        pikkazo.mint(stranger, 777);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        conv.convert(_arr(REAPER));
        vm.stopPrank();

        vm.prank(stranger);
        pikkazo.setApprovalForAll(diamond, true);

        // Upgrade to ConvertFacetV2 and free a NON-OG Soul (250) so freedAt != 0.
        _applyConvertV2Cut(uint64(block.timestamp));
        convV2 = ConvertFacetV2(diamond);
        pikkazo.mint(holder, NONOG);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        convV2.convert(_arr(NONOG));
        assertEq(convV2.cohortOf(REAPER), 0, "REAPER must be OG");
        assertTrue(convV2.cohortOf(NONOG) != 0, "NONOG must be non-OG");
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
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacet.offer.selector;
        rep[1] = ReaperFacet.forgeMark.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    /// The Economy-V2 Replace under test: marksOf (from ReaperFacet) + forgeMark (from
    /// ReaperFacetV2) both onto ReaperFacetV3. Returns the V3 facet address.
    function _v3() internal returns (address v3addr) {
        reaperV3 = new ReaperFacetV3();
        v3addr = address(reaperV3);
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacetV3.marksOf.selector; // 0xfb115701
        rep[1] = ReaperFacetV3.forgeMark.selector; // 0x900b4cc1
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: v3addr,
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
            cuts, address(initC), abi.encodeCall(ConvertV2Init.init, (start, B1, B2, B3, P1, P2, P3, treasury))
        );
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

    /// Feed `n` canvases (from 100.. cursor) to REAPER, advancing a per-test cursor so
    /// each offer uses fresh canvases. Splits into <=50 chunks (MAX_PER_TX).
    uint256 private _cursor = 100;

    function _feed(uint256 n) internal {
        while (n > 0) {
            uint256 chunk = n > 50 ? 50 : n;
            vm.prank(holder);
            reaper.offer(REAPER, _range(_cursor, chunk));
            _cursor += chunk;
            n -= chunk;
        }
    }

    // ============================================================ cut routing

    function test_v3_cut_routing_and_regression() public {
        address v3 = _v3();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        // marksOf + forgeMark now route to V3
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), v3, "marksOf -> V3");
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), v3, "forgeMark -> V3");

        // offer stays on V2 (NOT V3, NOT the original ReaperFacet)
        address offerFacet = loupe.facetAddress(ReaperFacet.offer.selector);
        assertTrue(offerFacet != address(0) && offerFacet != v3, "offer stays on V2");

        // isReaper + the other views/admin stay on the original ReaperFacet (NOT V3)
        address rf = loupe.facetAddress(ReaperFacet.isReaper.selector);
        assertTrue(rf != address(0) && rf != v3, "isReaper stays on ReaperFacet");
        assertEq(loupe.facetAddress(ReaperFacet.soulsConsumed.selector), rf, "soulsConsumed stays");
        assertEq(loupe.facetAddress(ReaperFacet.markPrice.selector), rf, "markPrice stays");
        assertEq(loupe.facetAddress(ReaperFacet.setMarkPrice.selector), rf, "setMarkPrice stays");
        assertEq(loupe.facetAddress(ReaperFacet.reaperPaused.selector), rf, "reaperPaused stays");
        assertEq(loupe.facetAddress(ReaperFacet.isCanvasConsumed.selector), rf, "isCanvasConsumed stays");
        assertTrue(offerFacet != rf, "offer (V2) distinct from views (ReaperFacet)");

        // convert regression: unaffected
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != address(0));
        assertTrue(loupe.facetAddress(ConvertFacet.convert.selector) != v3);
    }

    // =================================================== milestone thresholds

    function test_marks_consumed0_none() public {
        _v3();
        assertEq(reaper.marksOf(REAPER), 0);
        assertFalse(reaper.isReaper(REAPER));
    }

    function test_marks_consumed5_none() public {
        _feed(5);
        _v3();
        assertEq(reaper.soulsConsumed(REAPER), 5);
        assertEq(reaper.marksOf(REAPER), 0, "5 < 6: no marks");
        assertFalse(reaper.isReaper(REAPER));
    }

    function test_marks_consumed6_orange() public {
        _feed(6);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE, "6 -> Orange");
        assertFalse(reaper.isReaper(REAPER));
    }

    function test_marks_consumed11_onlyOrange() public {
        _feed(11);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE, "11: Orange only (12 not reached)");
    }

    function test_marks_consumed12_orangeFlame() public {
        _feed(12);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME, "12 -> Orange+FlameCrown");
    }

    function test_marks_consumed17_orangeFlame() public {
        _feed(17);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME, "17: not yet Phoenix");
    }

    function test_marks_consumed18_threeMarks() public {
        _feed(18);
        _v3();
        // the #8777 retroactive shape
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX, "18 -> O+FC+P");
        assertFalse(reaper.isReaper(REAPER), "18 < 30: not yet a Reaper");
    }

    function test_marks_consumed29_threeMarks_notBurning() public {
        _feed(29);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX, "29: no BurningSoul yet");
        assertFalse(reaper.isReaper(REAPER));
    }

    function test_marks_consumed30_allAndAscended() public {
        _feed(30);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX | BURNING, "30 -> all four");
        assertTrue(reaper.isReaper(REAPER), "30 -> Ascended");
    }

    function test_marks_consumed42_stillAllFour() public {
        _feed(42);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX | BURNING, "over 30 stays all four");
        assertTrue(reaper.isReaper(REAPER));
    }

    // ====================================================== legacy bit union

    /// A legacy forged bit (set on-storage via the pre-V3 forge path) is preserved by the
    /// derived marksOf even when consumption alone would NOT unlock it.
    function test_union_legacyBitBelowThreshold_preserved() public {
        // Cheap-forge BurningSoul (bit 3) at consumed==1 by temporarily lowering its price
        vm.prank(owner_);
        reaper.setMarkPrice(3, 1);
        vm.prank(holder);
        reaper.forgeMark(REAPER, 3, _arr(200)); // reaperMarks bit3 set, consumed = 1
        vm.prank(owner_);
        reaper.setMarkPrice(3, 30); // restore threshold

        _v3();

        // consumed 1 derives NOTHING (all thresholds > 1) but the legacy bit3 survives
        assertEq(reaper.soulsConsumed(REAPER), 1);
        assertEq(reaper.marksOf(REAPER), BURNING, "legacy bit3 preserved via union");
        assertFalse(reaper.isReaper(REAPER), "consumed 1 is not a Reaper");
    }

    /// Reproduces #8777: two hand-forged marks (Orange + FlameCrown) that are a consistent
    /// SUBSET of the derived set at 18 consumed -> union == derived (O|FC|P), lossless.
    function test_union_8777_shape_subsetConsistent() public {
        vm.startPrank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6)); // Orange, consumed 6
        reaper.forgeMark(REAPER, 1, _range(106, 12)); // FlameCrown, consumed 18
        vm.stopPrank();

        _v3();

        assertEq(reaper.soulsConsumed(REAPER), 18);
        // legacy bits {0,1} are a subset of derived {0,1,2} at 18 -> union unchanged
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX, "8777 retro: O|FC|P");
    }

    // ==================================================== forgeMark deprecated

    function test_forgeMark_revertsDeprecated_forOwner() public {
        _v3();
        vm.prank(holder);
        vm.expectRevert(ReaperFacetV3.ForgeDeprecated.selector);
        reaper.forgeMark(REAPER, 0, _range(100, 6));
    }

    function test_forgeMark_revertsDeprecated_regardlessOfArgs() public {
        _v3();
        // wrong size, non-owner, unconfigured mark: all still ForgeDeprecated (pure revert)
        vm.prank(stranger);
        vm.expectRevert(ReaperFacetV3.ForgeDeprecated.selector);
        reaper.forgeMark(REAPER, 7, new uint256[](0));
    }

    function test_forgeMark_revertsDeprecated_burnsNothing() public {
        _v3();
        assertEq(pikkazo.ownerOf(100), holder);
        vm.prank(holder);
        vm.expectRevert(ReaperFacetV3.ForgeDeprecated.selector);
        reaper.forgeMark(REAPER, 3, _range(100, 30));
        // pure revert -> no canvas touched, no consumption
        assertEq(pikkazo.ownerOf(100), holder, "no burn");
        assertEq(reaper.soulsConsumed(REAPER), 0, "no consumption");
    }

    // ============================================= offer unchanged post-cut

    function test_offer_stillWorks_afterV3() public {
        _v3();
        _feed(9);
        assertEq(reaper.soulsConsumed(REAPER), 9);
        // and derived marks track it live
        assertEq(reaper.marksOf(REAPER), ORANGE, "9 -> Orange");
    }

    function test_offer_ascension_stillFiresOnce_afterV3() public {
        _v3();
        _feed(29);
        vm.expectEmit(true, false, false, true, diamond);
        emit ReaperFacet.ReaperAscended(REAPER, 30);
        vm.prank(holder);
        reaper.offer(REAPER, _range(_cursor, 1)); // fresh canvas, crosses 30
        assertTrue(reaper.isReaper(REAPER));
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX | BURNING);
    }

    function test_nonOG_offer_stillReverts_afterV3() public {
        _v3();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, NONOG));
        reaper.offer(NONOG, _range(100, 3));
    }

    // ============================================ hot-retune of thresholds

    function test_setMarkPrice_retunesThreshold_up() public {
        _feed(6);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE);
        // raise Orange threshold to 100: consumed 6 no longer derives it (no legacy bit)
        vm.prank(owner_);
        reaper.setMarkPrice(0, 100);
        assertEq(reaper.marksOf(REAPER), 0, "threshold raised -> Orange re-locks");
    }

    function test_setMarkPrice_retunesThreshold_down() public {
        _feed(3);
        _v3();
        assertEq(reaper.marksOf(REAPER), 0, "3 < 6");
        vm.prank(owner_);
        reaper.setMarkPrice(0, 3);
        assertEq(reaper.marksOf(REAPER), ORANGE, "threshold lowered -> Orange unlocks at 3");
    }

    function test_setMarkPrice_zeroDisablesDerivation_keepsLegacy() public {
        // forge legacy Orange bit, then zero its threshold
        vm.prank(holder);
        reaper.forgeMark(REAPER, 0, _range(100, 6)); // bit0, consumed 6
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE);
        vm.prank(owner_);
        reaper.setMarkPrice(0, 0); // disable Orange milestone
        // derivation of bit0 stops, but the legacy forged bit0 survives via union
        assertEq(reaper.marksOf(REAPER), ORANGE, "threshold 0: legacy bit still shown");
    }

    // ==================================================== marks travel with token

    function test_marks_travelWithToken() public {
        _feed(18);
        _v3();
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX);

        vm.prank(holder);
        souls.transferFrom(holder, stranger, REAPER);
        assertEq(souls.ownerOf(REAPER), stranger);
        // derived from soulsConsumed[REAPER], which is keyed by token id -> follows token
        assertEq(reaper.marksOf(REAPER), ORANGE | FLAME | PHOENIX, "marks follow the token");
        assertEq(reaper.soulsConsumed(REAPER), 18);
    }
}
