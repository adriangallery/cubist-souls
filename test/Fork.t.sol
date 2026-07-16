// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../src/diamond/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {CubistSoulsTest, DiamondHarness} from "./CubistSouls.t.sol";

interface IPikkazoFull {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
    function totalSupply() external view returns (uint256);
}

/// Fork test against the REAL Pikkazo SeaDrop clone on Ethereum mainnet.
/// Runs only when ETH_RPC is set:  ETH_RPC=<url> forge test --match-contract Fork
contract ForkTest is Test {
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;
    address constant HOLDER = 0x4943407105999e3E97EFA2035F5cbC64D72581C6; // Adrian, 253 pikkazos

    address diamond;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        diamond = new DiamondHarness().build(HOLDER, PIKKAZO);
    }

    function test_fork_convertRealPikkazos() public {
        IPikkazoFull pikkazo = IPikkazoFull(PIKKAZO);
        uint256 supplyBefore = pikkazo.totalSupply();
        assertEq(pikkazo.ownerOf(99), HOLDER);
        assertEq(pikkazo.ownerOf(3995), HOLDER);

        vm.startPrank(HOLDER);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 99;
        ids[1] = 3995;
        ConvertFacet(diamond).convert(ids);
        vm.stopPrank();

        // canvases burned for real on the legacy contract
        assertEq(pikkazo.totalSupply(), supplyBefore - 2);
        vm.expectRevert();
        pikkazo.ownerOf(99);

        // souls exist with the same ids
        SoulsERC721Facet souls = SoulsERC721Facet(diamond);
        assertEq(souls.ownerOf(99), HOLDER);
        assertEq(souls.ownerOf(3995), HOLDER);
        assertEq(souls.totalSupply(), 2);
        assertTrue(bytes(souls.tokenURI(3995)).length > 100);
    }

    function test_fork_thirdPartyCannotStealViaConvert() public {
        address attacker = makeAddr("attacker");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99; // belongs to HOLDER
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ConvertFacet.NotYourPikkazo.selector, 99));
        ConvertFacet(diamond).convert(ids);
    }
}
