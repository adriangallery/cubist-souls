// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ReaperFacetV4} from "../src/facets/ReaperFacetV4.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";

interface IPikkazoLike {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

/// Fork dry-run of THE CLOSURE (ReaperFacetV4 Replace of `offer`) against the REAL
/// LIVE Cubist Souls diamond on Ethereum mainnet. State fork only (no getLogs):
///   ETH_RPC=<url> forge test --match-contract ReaperV4Fork -vv
///
/// Anchored to VERIFIED live state (queried 2026-08-03, the day the twelfth ascended):
///   - THE TWELVE, all at exactly 30 consumed:
///     136, 373, 487, 1650, 2201, 2680, 3654, 6225, 6559, 6669, 7681, 8777.
///   - The two aspirants the closure seals: #1682 at 1/30, #2474 at 6/30
///     (#2474's holder 0x4AdF..e2F4 already owns reaper #2201).
///   - #490: OG (cohort 0), 0 consumed, held by 0xdcDB..5bFB — the "new initiate".
///   - #380: NON-OG (cohort 1), 0 consumed — proves the guard ORDER survives.
///   - #6560: OG, 0 consumed, held by 0x214f..F553 who ALSO owns reaper #373 —
///     proves an existing member cannot start a thirteenth.
///   - Routing pre-cut: offer(0x9d6f563d) -> ReaperFacetV2 0xf198..aB10.
///   - Canvases 6000/6017/6061/6082 held by 0x4d2B..1bEe (the live feed for the
///     "the twelve keep reaping" leg).
///
/// Proves, in order:
///   1) PRE-CUT  — the twelve are twelve, all at 30; the two aspirants are where we
///                 said; offer still routes to V2 and an aspirant CAN still climb.
///   2) CUT      — Replace offer -> ReaperFacetV4 (owner-impersonated).
///   3) POST-CUT — routing: offer -> V4; forgeMark/marksOf/isReaper untouched.
///   4) POST-CUT — an ASCENDED reaper still burns canvases and climbs past 30.
///   5) POST-CUT — #2474 (6/30) and #1682 (1/30) revert OrderClosed, burning nothing.
///   6) POST-CUT — #490 (a fresh OG) cannot initiate; #6560 (a member's second soul)
///                 cannot either; #380 still reverts NotOGSoul (guard order intact).
///   7) POST-CUT — the roster is exactly twelve and every view is unchanged.
contract ReaperV4ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    address constant REAPER_V1 = 0x8Fa530B63F4E74f825271f652306dad7eC1750A5; // views/admin
    address constant REAPER_V2 = 0xf1988f107A52f7b12dDfb1CA747D43a60DDCaB10; // offer (pre-cut)

    uint256 constant ASPIRANT_1682 = 1682; // 1/30
    uint256 constant ASPIRANT_2474 = 2474; // 6/30
    uint256 constant VIRGIN_OG_490 = 490; // OG, 0 consumed
    uint256 constant NONOG_380 = 380; // cohort 1, 0 consumed
    uint256 constant MEMBER_SECOND_6560 = 6560; // OG, 0 consumed, held by #373's owner

    address constant CANVAS_HOLDER = 0x4d2B791a85675aFAD37b8C65Cc5255a91e581bEe;

    address owner_;

    function twelve() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](12);
        ids[0] = 136;
        ids[1] = 373;
        ids[2] = 487;
        ids[3] = 1650;
        ids[4] = 2201;
        ids[5] = 2680;
        ids[6] = 3654;
        ids[7] = 6225;
        ids[8] = 6559;
        ids[9] = 6669;
        ids[10] = 7681;
        ids[11] = 8777;
    }

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        owner_ = OwnershipFacet(DIAMOND).owner();
    }

    function _canvases() internal pure returns (uint256[] memory c) {
        c = new uint256[](2);
        c[0] = 6000;
        c[1] = 6017;
    }

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function test_fork_theOrderIsClosed_prePost() public {
        ReaperFacet r = ReaperFacet(DIAMOND);
        SoulsERC721Facet souls = SoulsERC721Facet(DIAMOND);
        IDiamondLoupe loupe = IDiamondLoupe(DIAMOND);

        // ---- (1) PRE-CUT anchors ----
        uint256[] memory ids = twelve();
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(r.soulsConsumed(ids[i]), 30, "each of the twelve sits at 30");
            assertTrue(r.isReaper(ids[i]), "and reads as a reaper");
        }
        assertEq(r.soulsConsumed(ASPIRANT_1682), 1, "#1682 at 1/30");
        assertEq(r.soulsConsumed(ASPIRANT_2474), 6, "#2474 at 6/30");
        assertFalse(r.isReaper(ASPIRANT_1682));
        assertFalse(r.isReaper(ASPIRANT_2474));
        assertEq(ConvertFacetV2(DIAMOND).cohortOf(VIRGIN_OG_490), 0, "#490 is OG");
        assertEq(r.soulsConsumed(VIRGIN_OG_490), 0, "#490 never lit the fire");
        assertTrue(ConvertFacetV2(DIAMOND).cohortOf(NONOG_380) != 0, "#380 is non-OG");
        assertEq(loupe.facetAddress(ReaperFacet.offer.selector), REAPER_V2, "offer on V2 pre-cut");
        bool pausedBefore = r.reaperPaused();
        assertFalse(pausedBefore, "the fire is not paused");

        // The doors are still open pre-cut: aspirant #2474 CAN still climb today.
        // Done inside a snapshot and rolled back, so this proves V4 is what closes
        // them — not some pre-existing condition of the live state.
        uint256 snap = vm.snapshotState();
        {
            address o2474pre = souls.ownerOf(ASPIRANT_2474);
            vm.prank(o2474pre);
            souls.transferFrom(o2474pre, CANVAS_HOLDER, ASPIRANT_2474);
            vm.prank(CANVAS_HOLDER);
            IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);
            vm.prank(CANVAS_HOLDER);
            r.offer(ASPIRANT_2474, _arr(6082));
            assertEq(r.soulsConsumed(ASPIRANT_2474), 7, "pre-cut the aspirant still climbs");
        }
        vm.revertToState(snap);
        assertEq(r.soulsConsumed(ASPIRANT_2474), 6, "snapshot rolled back to live state");
        emit log_string("PRE-CUT: twelve at 30, #1682 1/30, #2474 6/30, offer on V2");

        // ---- (2) CUT: Replace offer -> ReaperFacetV4 ----
        ReaperFacetV4 v4 = new ReaperFacetV4();
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ReaperFacetV4.offer.selector; // 0x9d6f563d
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v4),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        uint256 g = gasleft();
        vm.prank(owner_);
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        emit log_named_uint("diamondCut(Replace offer) gas", g - gasleft());

        // ---- (3) POST-CUT routing ----
        assertEq(loupe.facetAddress(ReaperFacet.offer.selector), address(v4), "offer -> V4");
        assertEq(loupe.facetAddress(ReaperFacet.isReaper.selector), REAPER_V1, "isReaper UNCHANGED");
        address v3addr = loupe.facetAddress(ReaperFacet.forgeMark.selector);
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), v3addr, "marksOf UNCHANGED (V3)");
        emit log_string("POST-CUT: offer -> V4; views/forgeMark untouched");

        // ---- (4) THE TWELVE KEEP REAPING ----
        // Move reaper #136 to the live canvas holder and feed it two real Pikkazos.
        uint256[] memory feed = _canvases();
        for (uint256 i = 0; i < feed.length; i++) {
            require(IPikkazoLike(PIKKAZO).ownerOf(feed[i]) == CANVAS_HOLDER, "canvas anchor stale");
        }
        address o136 = souls.ownerOf(136);
        vm.prank(o136);
        souls.transferFrom(o136, CANVAS_HOLDER, 136);
        vm.prank(CANVAS_HOLDER);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);
        vm.prank(CANVAS_HOLDER);
        r.offer(136, feed);
        assertEq(r.soulsConsumed(136), 32, "an ascended reaper climbs past 30");
        assertTrue(r.isCanvasConsumed(feed[0]) && r.isCanvasConsumed(feed[1]), "canvases really burned");
        emit log_string("POST-CUT: reaper #136 fed 2 canvases -> 32 consumed (the twelve keep reaping)");

        // ---- (5) THE ASPIRANTS ARE SEALED ----
        uint256[] memory one = _arr(6061);
        address o2474 = souls.ownerOf(ASPIRANT_2474);
        vm.prank(o2474);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, ASPIRANT_2474, 6));
        r.offer(ASPIRANT_2474, one);

        address o1682 = souls.ownerOf(ASPIRANT_1682);
        vm.prank(o1682);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, ASPIRANT_1682, 1));
        r.offer(ASPIRANT_1682, one);

        assertEq(r.soulsConsumed(ASPIRANT_2474), 6, "#2474 sealed at 6");
        assertEq(r.soulsConsumed(ASPIRANT_1682), 1, "#1682 sealed at 1");
        assertFalse(r.isCanvasConsumed(6061), "rejected offerings burned nothing");
        assertEq(IPikkazoLike(PIKKAZO).ownerOf(6061), CANVAS_HOLDER, "canvas untouched");
        emit log_string("POST-CUT: #2474 and #1682 revert OrderClosed, no canvas burned");

        // ---- (6) NO NEW INITIATES ----
        address o490 = souls.ownerOf(VIRGIN_OG_490);
        vm.prank(o490);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, VIRGIN_OG_490, 0));
        r.offer(VIRGIN_OG_490, one);

        // a current member cannot start a thirteenth with a second soul
        address o6560 = souls.ownerOf(MEMBER_SECOND_6560);
        vm.prank(o6560);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.OrderClosed.selector, MEMBER_SECOND_6560, 0));
        r.offer(MEMBER_SECOND_6560, one);

        // guard ORDER intact: a non-OG still reads NotOGSoul, not OrderClosed
        address o380 = souls.ownerOf(NONOG_380);
        vm.prank(o380);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV4.NotOGSoul.selector, NONOG_380));
        r.offer(NONOG_380, one);
        emit log_string("POST-CUT: #490 / #6560 OrderClosed; #380 still NotOGSoul (guard order intact)");

        // ---- (7) THE ROSTER IS TWELVE, VIEWS UNCHANGED ----
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(r.isReaper(ids[i]), "still a reaper");
        }
        assertEq(r.markPrice(0), 6);
        assertEq(r.markPrice(1), 12);
        assertEq(r.markPrice(2), 18);
        assertEq(r.markPrice(3), 30);
        assertEq(r.reaperPaused(), pausedBefore, "pause switch untouched");
        assertEq(r.marksOf(8777), 0xF, "derived milestones untouched (all four at 30)");
        emit log_string("=== FORK DRY-RUN PASSED: THE ORDER IS CLOSED AT TWELVE ===");
    }
}
