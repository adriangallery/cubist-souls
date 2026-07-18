// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {RescueFreeFacet} from "../src/facets/RescueFreeFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// Tests for the post-deploy rescue path: canvases burned directly on the legacy
/// contract (outside convert()) can have their Soul minted by the owner, but
/// only if the canvas is really gone and the soul isn't already freed.
contract RescueFreeTest is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address burner = makeAddr("burner"); // the 0x9179... equivalent
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    RescueFreeFacet rescue;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);

        // add the rescue facet the same way the mainnet cut will
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
        rescue = RescueFreeFacet(diamond);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    // The exact live scenario: burner owned 1905/1906, burned them directly on
    // Pikkazo (never minted on this mock == burned/gone), owner rescues them.
    function test_rescue_freesBurnedCanvas() public {
        // canvas is gone (ownerOf reverts on mock, like the real burned token)
        assertFalse(conv.isFreed(1905));
        assertFalse(conv.isFreed(1906));

        vm.prank(owner_);
        rescue.adminFreeBurned(burner, _ids(1905, 1906));

        assertEq(souls.ownerOf(1905), burner);
        assertEq(souls.ownerOf(1906), burner);
        assertEq(souls.balanceOf(burner), 2);
        assertTrue(conv.isFreed(1905));
        assertTrue(conv.isFreed(1906));
        assertTrue(bytes(souls.tokenURI(1905)).length > 100);
    }

    function test_rescue_revertsIfCanvasStillAlive() public {
        pikkazo.mint(burner, 1905); // canvas alive -> must use convert()
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RescueFreeFacet.CanvasStillAlive.selector, 1905));
        rescue.adminFreeBurned(burner, _one(1905));
    }

    function test_rescue_revertsIfAlreadyFreed() public {
        vm.prank(owner_);
        rescue.adminFreeBurned(burner, _one(1905));
        // second attempt: soul already exists
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RescueFreeFacet.AlreadyFreed.selector, 1905));
        rescue.adminFreeBurned(burner, _one(1905));
    }

    function test_rescue_cannotDoubleMintVsConvert() public {
        // a normal convert first
        pikkazo.mint(burner, 42);
        vm.startPrank(burner);
        pikkazo.setApprovalForAll(diamond, true);
        conv.convert(_one(42));
        vm.stopPrank();
        assertEq(souls.ownerOf(42), burner);
        // rescue must refuse: already freed
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RescueFreeFacet.AlreadyFreed.selector, 42));
        rescue.adminFreeBurned(stranger, _one(42));
    }

    function test_rescue_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        rescue.adminFreeBurned(stranger, _one(1905));
    }

    function test_rescue_revertsOnEmpty() public {
        vm.prank(owner_);
        vm.expectRevert(RescueFreeFacet.NothingToRescue.selector);
        rescue.adminFreeBurned(burner, new uint256[](0));
    }
}
