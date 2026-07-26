// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
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

/// Fork dry-run of the OG-only ReaperFacetV2 Replace against the REAL LIVE Cubist Souls
/// diamond on Ethereum mainnet. Runs only when ETH_RPC is set (state fork, no getLogs):
///   ETH_RPC=<url> forge test --match-contract ReaperV2Fork -vv
///
/// It proves, in order:
///   1) PRE-CUT  — a NON-OG Soul (freed via V2, cohort != 0) CAN offer (current facet).
///   2) CUT      — Replace offer(0x9d6f563d)+forgeMark(0x900b4cc1) onto ReaperFacetV2;
///                 those 2 selectors now route to V2, the 8 view/admin selectors stay.
///   3) POST-CUT — the same NON-OG Soul now REVERTS NotOGSoul and burns nothing.
///   4) POST-CUT — a real OG Soul (#136, freedAt == 0) can STILL offer.
///   5) POST-CUT — soulsConsumed/marksOf/markPrice/reaperPaused respond identically.
contract ReaperV2ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    // A real EOA Pikkazo holder (55 canvases) and 3 canvases it owns (verified 2026-07-26).
    address constant HOLDER = 0x4d2B791a85675aFAD37b8C65Cc5255a91e581bEe;
    uint256 constant C_CONVERT = 1000; // convert via V2 -> a NON-OG Soul (id 1000)
    uint256 constant C_PRECUT = 6000; // offered pre-cut (burned) to prove non-OG works today
    uint256 constant C_SPARE = 6017; // used post-cut: reverts for non-OG, then feeds OG #136

    uint256 constant OG_REAPER = 136; // real OG Soul, cohortOf == 0

    address owner_;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        owner_ = OwnershipFacet(DIAMOND).owner();
    }

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _replaceSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ReaperFacet.offer.selector; // 0x9d6f563d
        s[1] = ReaperFacet.forgeMark.selector; // 0x900b4cc1
    }

    function test_fork_ogOnlyReplace_prePost() public {
        ConvertFacetV2 cv = ConvertFacetV2(DIAMOND);
        ReaperFacet r = ReaperFacet(DIAMOND);
        SoulsERC721Facet souls = SoulsERC721Facet(DIAMOND);
        IDiamondLoupe loupe = IDiamondLoupe(DIAMOND);

        // preconditions on live state
        require(IPikkazoLike(PIKKAZO).ownerOf(C_CONVERT) == HOLDER, "C_CONVERT not held");
        require(IPikkazoLike(PIKKAZO).ownerOf(C_PRECUT) == HOLDER, "C_PRECUT not held");
        require(IPikkazoLike(PIKKAZO).ownerOf(C_SPARE) == HOLDER, "C_SPARE not held");
        assertEq(cv.cohortOf(OG_REAPER), 0, "#136 must be OG");

        vm.prank(HOLDER);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);

        // free a NON-OG Soul (id 1000) through the live V2 sale (pays priceNow)
        uint256 price = cv.priceNow();
        vm.deal(HOLDER, price + 1 ether);
        vm.prank(HOLDER);
        cv.convert{value: price}(_arr(C_CONVERT));
        assertEq(souls.ownerOf(C_CONVERT), HOLDER);
        uint8 nonOgCohort = cv.cohortOf(C_CONVERT);
        assertTrue(nonOgCohort != 0, "converted soul must be non-OG");
        emit log_named_uint("non-OG soul 1000 cohort", nonOgCohort);

        // snapshot views (must be identical post-cut)
        uint16 mp0 = r.markPrice(0);
        uint16 mp1 = r.markPrice(1);
        uint16 mp2 = r.markPrice(2);
        uint16 mp3 = r.markPrice(3);
        bool pausedBefore = r.reaperPaused();
        uint256 consumed136Before = r.soulsConsumed(OG_REAPER);
        uint256 marks136Before = r.marksOf(OG_REAPER);

        // ---- (1) PRE-CUT: non-OG soul CAN offer on the current live facet ----
        uint256 consumedNonOgStart = r.soulsConsumed(C_CONVERT);
        vm.prank(HOLDER);
        r.offer(C_CONVERT, _arr(C_PRECUT)); // burns canvas 6000
        assertEq(r.soulsConsumed(C_CONVERT), consumedNonOgStart + 1, "pre-cut offer should count");
        assertTrue(r.isCanvasConsumed(C_PRECUT), "pre-cut canvas consumed");
        emit log_string("PRE-CUT: non-OG offer succeeded on live facet");

        // ---- (2) CUT: Replace offer + forgeMark onto ReaperFacetV2 ----
        ReaperFacetV2 v2 = new ReaperFacetV2();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: _replaceSelectors()
        });
        uint256 g = gasleft();
        vm.prank(owner_);
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        emit log_named_uint("diamondCut(Replace x2) gas", g - gasleft());

        // routing: offer + forgeMark -> V2; views stay on the original facet
        assertEq(loupe.facetAddress(ReaperFacet.offer.selector), address(v2));
        assertEq(loupe.facetAddress(ReaperFacet.forgeMark.selector), address(v2));
        assertTrue(loupe.facetAddress(ReaperFacet.soulsConsumed.selector) != address(v2));
        assertTrue(loupe.facetAddress(ReaperFacet.reaperPaused.selector) != address(v2));

        // ---- (3) POST-CUT: non-OG soul offer REVERTS and burns nothing ----
        uint256 pikSupplyBefore = IPikkazoLike(PIKKAZO).totalSupply();
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, C_CONVERT));
        r.offer(C_CONVERT, _arr(C_SPARE));
        assertEq(IPikkazoLike(PIKKAZO).ownerOf(C_SPARE), HOLDER, "spare canvas must survive");
        assertEq(IPikkazoLike(PIKKAZO).totalSupply(), pikSupplyBefore, "nothing burned");
        assertEq(r.soulsConsumed(C_CONVERT), consumedNonOgStart + 1, "non-OG count unchanged");
        // forgeMark also barred
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(ReaperFacetV2.NotOGSoul.selector, C_CONVERT));
        r.forgeMark(C_CONVERT, 0, new uint256[](6));
        emit log_string("POST-CUT: non-OG offer + forgeMark revert NotOGSoul, no burn");

        // ---- (4) POST-CUT: OG #136 can STILL offer ----
        address o136 = souls.ownerOf(OG_REAPER);
        vm.prank(o136);
        souls.transferFrom(o136, HOLDER, OG_REAPER);
        vm.prank(HOLDER);
        r.offer(OG_REAPER, _arr(C_SPARE)); // burns canvas 6017
        assertEq(r.soulsConsumed(OG_REAPER), consumed136Before + 1, "OG offer should count");
        assertTrue(r.isCanvasConsumed(C_SPARE), "OG-offered canvas consumed");
        emit log_string("POST-CUT: OG #136 offer succeeded through V2");

        // ---- (5) POST-CUT: views respond identically ----
        assertEq(r.markPrice(0), mp0);
        assertEq(r.markPrice(1), mp1);
        assertEq(r.markPrice(2), mp2);
        assertEq(r.markPrice(3), mp3);
        assertEq(r.reaperPaused(), pausedBefore);
        assertEq(r.marksOf(OG_REAPER), marks136Before);
        emit log_string("POST-CUT: markPrice/reaperPaused/marksOf/soulsConsumed identical");
    }
}
