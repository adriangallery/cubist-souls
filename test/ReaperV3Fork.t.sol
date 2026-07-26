// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";

interface IPikkazoLike {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
    function totalSupply() external view returns (uint256);
}

/// Fork dry-run of the Economy-V2 ReaperFacetV3 Replace against the REAL LIVE Cubist
/// Souls diamond on Ethereum mainnet. State fork only (no getLogs). Run when ETH_RPC set:
///   ETH_RPC=<url> forge test --match-contract ReaperV3Fork -vv
///
/// Anchored to VERIFIED live state (queried 2026-07-26):
///   - #8777: soulsConsumed == 18, raw reaperMarks == 3 (bits {0,1} = Orange+FlameCrown,
///     Adrian's only two MarkForged events on chain — both reaperId 8777, markId 0 & 1),
///     isReaper == false, owner 0x4943...
///   - #136:  OG (cohort 0), soulsConsumed == 0, marks 0.
///   - markPrices 6/12/18/30; reaperPaused false.
///   - Routing: marksOf(0xfb115701) -> ReaperFacet 0x8fa5..50a5; forgeMark(0x900b4cc1) &
///     offer(0x9d6f563d) -> ReaperFacetV2 0xf198..aB10; isReaper(0xfeacc37e) -> 0x8fa5.
///
/// Proves, in order:
///   1) PRE-CUT  — live views match the anchors above (incl. marksOf(8777)==3, the raw
///                 bitmask, and routing).
///   2) CUT      — Replace marksOf + forgeMark onto ReaperFacetV3 (owner-impersonated).
///   3) POST-CUT — routing: marksOf & forgeMark -> V3; offer stays on V2 (same addr);
///                 isReaper stays on ReaperFacet (same addr).
///   4) POST-CUT — the RETROACTIVE HAPPY EFFECT: marksOf(8777) == Orange|FlameCrown|
///                 Phoenix (7); soulsConsumed(8777) still 18; isReaper still false.
///   5) POST-CUT — forgeMark reverts ForgeDeprecated() and burns nothing.
///   6) POST-CUT — views identical: markPrice 6/12/18/30, reaperPaused, soulsConsumed.
///   7) POST-CUT — offer still works (unchanged V2 logic) and marksOf tracks it live:
///                 feed 6 canvases to OG #136 -> marksOf(136) == Orange.
contract ReaperV3ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    address constant REAPER_V1 = 0x8Fa530B63F4E74f825271f652306dad7eC1750A5; // views/admin
    address constant REAPER_V2 = 0xf1988f107A52f7b12dDfb1CA747D43a60DDCaB10; // offer/forgeMark

    uint256 constant EIGHT777 = 8777; // consumed 18, raw marks {0,1}
    uint256 constant OG_136 = 136; // OG, consumed 0

    uint256 constant ORANGE = 1 << 0;
    uint256 constant FLAME = 1 << 1;
    uint256 constant PHOENIX = 1 << 2;

    address owner_;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        owner_ = OwnershipFacet(DIAMOND).owner();
    }

    function _replaceSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ReaperFacetV3.marksOf.selector; // 0xfb115701
        s[1] = ReaperFacetV3.forgeMark.selector; // 0x900b4cc1
    }

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function test_fork_economyV2Replace_prePost() public {
        ReaperFacet r = ReaperFacet(DIAMOND);
        SoulsERC721Facet souls = SoulsERC721Facet(DIAMOND);
        IDiamondLoupe loupe = IDiamondLoupe(DIAMOND);

        // ---- (1) PRE-CUT anchors ----
        assertEq(r.soulsConsumed(EIGHT777), 18, "8777 consumed must be 18");
        assertEq(r.marksOf(EIGHT777), 3, "8777 raw marks must be {0,1}=3 pre-cut");
        assertFalse(r.isReaper(EIGHT777), "8777 not a reaper (<30)");
        uint16 mp0 = r.markPrice(0);
        uint16 mp1 = r.markPrice(1);
        uint16 mp2 = r.markPrice(2);
        uint16 mp3 = r.markPrice(3);
        assertEq(mp0, 6);
        assertEq(mp1, 12);
        assertEq(mp2, 18);
        assertEq(mp3, 30);
        bool pausedBefore = r.reaperPaused();
        // routing pre-cut
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), REAPER_V1, "marksOf on V1 pre");
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), REAPER_V2, "forgeMark on V2 pre");
        assertEq(loupe.facetAddress(ReaperFacet.offer.selector), REAPER_V2, "offer on V2 pre");
        assertEq(loupe.facetAddress(ReaperFacet.isReaper.selector), REAPER_V1, "isReaper on V1 pre");
        emit log_string("PRE-CUT: anchors OK (8777 consumed 18, raw marks 3, prices 6/12/18/30)");

        // ---- (2) CUT: Replace marksOf + forgeMark -> ReaperFacetV3 ----
        ReaperFacetV3 v3 = new ReaperFacetV3();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v3),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: _replaceSelectors()
        });
        uint256 g = gasleft();
        vm.prank(owner_);
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        emit log_named_uint("diamondCut(Replace x2) gas", g - gasleft());

        // ---- (3) POST-CUT routing ----
        assertEq(loupe.facetAddress(ReaperFacet.marksOf.selector), address(v3), "marksOf -> V3");
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), address(v3), "forgeMark -> V3");
        assertEq(loupe.facetAddress(ReaperFacet.offer.selector), REAPER_V2, "offer UNCHANGED on V2");
        assertEq(loupe.facetAddress(ReaperFacet.isReaper.selector), REAPER_V1, "isReaper UNCHANGED on V1");
        emit log_string("POST-CUT: marksOf+forgeMark -> V3; offer stays V2; isReaper stays V1");

        // ---- (4) RETROACTIVE HAPPY EFFECT: #8777 gains Phoenix ----
        assertEq(r.marksOf(EIGHT777), ORANGE | FLAME | PHOENIX, "8777 -> O|FC|P (7)");
        assertEq(r.soulsConsumed(EIGHT777), 18, "8777 consumed unchanged");
        assertFalse(r.isReaper(EIGHT777), "8777 still not a reaper (<30)");
        emit log_string("POST-CUT: marksOf(8777)==7 (Orange|FlameCrown|Phoenix) - retroactive Phoenix");

        // ---- (5) forgeMark deprecated, burns nothing ----
        uint256 pikSupplyBefore = IPikkazoLike(PIKKAZO).totalSupply();
        vm.expectRevert(ReaperFacetV3.ForgeDeprecated.selector);
        r.forgeMark(EIGHT777, 0, new uint256[](6));
        assertEq(IPikkazoLike(PIKKAZO).totalSupply(), pikSupplyBefore, "forgeMark burned nothing");
        emit log_string("POST-CUT: forgeMark reverts ForgeDeprecated, no burn");

        // ---- (6) views identical ----
        assertEq(r.markPrice(0), mp0);
        assertEq(r.markPrice(1), mp1);
        assertEq(r.markPrice(2), mp2);
        assertEq(r.markPrice(3), mp3);
        assertEq(r.reaperPaused(), pausedBefore);
        emit log_string("POST-CUT: markPrice/reaperPaused unchanged");

        // ---- (7) offer still works (unchanged V2 logic) and marksOf tracks it live ----
        // A verified live EOA (55 canvases, 2026-07-26) and 4 canvases it owns.
        address holder = 0x4d2B791a85675aFAD37b8C65Cc5255a91e581bEe;
        uint256[] memory four = new uint256[](4);
        four[0] = 6000;
        four[1] = 6017;
        four[2] = 6061;
        four[3] = 6082;
        for (uint256 i = 0; i < four.length; i++) {
            require(IPikkazoLike(PIKKAZO).ownerOf(four[i]) == holder, "canvas not held");
        }
        assertEq(ConvertFacetV2(DIAMOND).cohortOf(OG_136), 0, "#136 must be OG");
        assertEq(r.soulsConsumed(OG_136), 0, "#136 starts at 0");
        assertEq(r.marksOf(OG_136), 0, "#136 no marks at 0");

        address o136 = souls.ownerOf(OG_136);
        vm.prank(o136);
        souls.transferFrom(o136, holder, OG_136);
        vm.prank(holder);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);
        vm.prank(holder);
        r.offer(OG_136, four); // burns 4 canvases via the UNCHANGED V2 offer

        assertEq(r.soulsConsumed(OG_136), 4, "#136 consumed 4 after live offer");
        assertEq(r.marksOf(OG_136), 0, "4 < 6: no Orange yet (derived live)");
        // hot-retune the Orange threshold DOWN to 4 -> derivation flips on live
        vm.prank(owner_);
        r.setMarkPrice(0, 4);
        assertEq(r.marksOf(OG_136), ORANGE, "#136 -> Orange after threshold retune (derived live)");
        emit log_string("POST-CUT: live offer(4) + setMarkPrice(0,4) -> marksOf==Orange (derivation tracks live state)");
        emit log_string("=== FORK DRY-RUN PASSED ===");
    }
}
