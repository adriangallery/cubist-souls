// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../src/diamond/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {SoulsAdminFacet} from "../src/facets/SoulsAdminFacet.sol";
import {PlaceholderRenderer} from "../src/render/PlaceholderRenderer.sol";
import {SoulsInit} from "../src/upgradeInitializers/SoulsInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// Mock that mirrors the semantics of the real Pikkazo SeaDrop clone:
/// public burn(tokenId), gated on owner-or-approved-operator.
contract MockPikkazo {
    mapping(uint256 => address) public ownerOfMap;
    mapping(address => mapping(address => bool)) public operatorApprovals;

    error TransferCallerNotOwnerNorApproved();
    error OwnerQueryForNonexistentToken();

    function mint(address to, uint256 id) external {
        ownerOfMap[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = ownerOfMap[id];
        if (o == address(0)) revert OwnerQueryForNonexistentToken();
    }

    function setApprovalForAll(address operator, bool approved) external {
        operatorApprovals[msg.sender][operator] = approved;
    }

    function burn(uint256 id) external {
        address owner_ = ownerOfMap[id];
        if (owner_ == address(0)) revert OwnerQueryForNonexistentToken();
        if (msg.sender != owner_ && !operatorApprovals[owner_][msg.sender]) {
            revert TransferCallerNotOwnerNorApproved();
        }
        ownerOfMap[id] = address(0);
    }
}

contract DiamondHarness {
    // helper to build the diamond exactly like the deploy script does
    function build(address owner_, address pikkazo) external returns (address) {
        return build(owner_, pikkazo, address(0), new uint256[](0));
    }

    function build(address owner_, address pikkazo, address genesisTo, uint256[] memory genesisIds)
        public
        returns (address)
    {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        Diamond diamond = new Diamond(address(this), address(cutFacet));

        Deploy d = new Deploy();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(address(new DiamondLoupeFacet()), d.loupeSelectors());
        cuts[1] = _cut(address(new OwnershipFacet()), d.ownershipSelectors());
        cuts[2] = _cut(address(new SoulsERC721Facet()), d.erc721Selectors());
        cuts[3] = _cut(address(new ConvertFacet()), d.convertSelectors());
        cuts[4] = _cut(address(new SoulsAdminFacet()), d.adminSelectors());

        PlaceholderRenderer renderer = new PlaceholderRenderer();
        SoulsInit initC = new SoulsInit();
        IDiamondCut(address(diamond)).diamondCut(
            cuts,
            address(initC),
            abi.encodeCall(SoulsInit.init, (pikkazo, address(renderer), owner_, 500, genesisTo, genesisIds))
        );
        // hand ownership to the intended owner (2-step)
        OwnershipFacet(address(diamond)).transferOwnership(owner_);
        return address(diamond);
    }

    function _cut(address facet, bytes4[] memory sels) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
    }
}

contract CubistSoulsTest is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    SoulsAdminFacet admin;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        admin = SoulsAdminFacet(diamond);

        pikkazo.mint(holder, 3995);
        pikkazo.mint(holder, 99);
        pikkazo.mint(stranger, 777);
    }

    function _approveAndConvert(address who, uint256 id) internal {
        vm.startPrank(who);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        conv.convert(ids);
        vm.stopPrank();
    }

    // --- conversion ---

    function test_convert_burnsAndMintsSameId() public {
        _approveAndConvert(holder, 3995);
        assertEq(souls.ownerOf(3995), holder);
        assertEq(souls.totalSupply(), 1);
        vm.expectRevert(MockPikkazo.OwnerQueryForNonexistentToken.selector);
        pikkazo.ownerOf(3995);
    }

    function test_convert_batch() public {
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 3995;
        ids[1] = 99;
        conv.convert(ids);
        vm.stopPrank();
        assertEq(souls.balanceOf(holder), 2);
    }

    function test_convert_revertsWithoutApproval() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3995;
        vm.prank(holder);
        vm.expectRevert(MockPikkazo.TransferCallerNotOwnerNorApproved.selector);
        conv.convert(ids);
    }

    function test_convert_revertsIfNotYourPikkazo() public {
        // stranger approved the diamond, but tries to convert holder's token
        vm.startPrank(stranger);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3995;
        vm.expectRevert(abi.encodeWithSelector(ConvertFacet.NotYourPikkazo.selector, 3995));
        conv.convert(ids);
        vm.stopPrank();
    }

    function test_convert_cannotConvertTwice() public {
        _approveAndConvert(holder, 3995);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3995;
        vm.prank(holder);
        vm.expectRevert(); // pikkazo.ownerOf reverts: token gone
        conv.convert(ids);
    }

    function test_convert_pausable() public {
        vm.prank(owner_);
        admin.setConvertPaused(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3995;
        vm.prank(holder);
        vm.expectRevert(ConvertFacet.ConvertIsPaused.selector);
        conv.convert(ids);
    }

    // --- genesis mints (canvases burned before the diamond existed) ---

    function test_genesisMintsAtInit() public {
        // ids 136/1064 were never minted on this mock -> ownerOf reverts,
        // which is exactly the state of a burned canvas on the real contract
        uint256[] memory ids = new uint256[](2);
        ids[0] = 136;
        ids[1] = 1064;
        address d2 = new DiamondHarness().build(owner_, address(pikkazo), owner_, ids);

        SoulsERC721Facet s2 = SoulsERC721Facet(d2);
        assertEq(s2.ownerOf(136), owner_);
        assertEq(s2.ownerOf(1064), owner_);
        assertEq(s2.totalSupply(), 2);
        assertEq(s2.balanceOf(owner_), 2);
        assertTrue(bytes(s2.tokenURI(136)).length > 100);
    }

    function test_genesisRevertsIfCanvasStillAlive() public {
        pikkazo.mint(holder, 136); // canvas alive -> genesis must fail
        uint256[] memory ids = new uint256[](1);
        ids[0] = 136;
        DiamondHarness h = new DiamondHarness();
        vm.expectRevert();
        h.build(owner_, address(pikkazo), owner_, ids);
    }

    // --- ERC721 basics ---

    function test_transferAndApprovals() public {
        _approveAndConvert(holder, 3995);
        vm.prank(holder);
        souls.transferFrom(holder, stranger, 3995);
        assertEq(souls.ownerOf(3995), stranger);
        assertEq(souls.balanceOf(holder), 0);

        vm.prank(stranger);
        souls.approve(holder, 3995);
        vm.prank(holder);
        souls.safeTransferFrom(stranger, holder, 3995);
        assertEq(souls.ownerOf(3995), holder);
    }

    function test_strangerCannotTransfer() public {
        _approveAndConvert(holder, 3995);
        vm.prank(stranger);
        vm.expectRevert(SoulsERC721Facet.NotOwnerNorApproved.selector);
        souls.transferFrom(holder, stranger, 3995);
    }

    // --- metadata ---

    function test_tokenURI_fromPlaceholderRenderer() public {
        _approveAndConvert(holder, 3995);
        string memory uri = souls.tokenURI(3995);
        assertTrue(bytes(uri).length > 100);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
    }

    function test_tokenURI_neverRevertsIfRendererBroken() public {
        _approveAndConvert(holder, 3995);
        vm.prank(owner_);
        admin.setRenderer(address(0xdead)); // not a contract with tokenURI
        string memory uri = souls.tokenURI(3995);
        assertTrue(bytes(uri).length > 0); // inline fallback served
    }

    function test_rendererSwapAndFreeze() public {
        address newRenderer = address(new PlaceholderRenderer());
        vm.prank(owner_);
        admin.setRenderer(newRenderer);
        assertEq(admin.renderer(), newRenderer);

        vm.prank(owner_);
        admin.freezeRenderer();
        vm.prank(owner_);
        vm.expectRevert(SoulsAdminFacet.RendererIsFrozen.selector);
        admin.setRenderer(address(1));
    }

    function test_onlyOwnerAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        admin.setRenderer(address(1));
        vm.prank(stranger);
        vm.expectRevert();
        admin.setConvertPaused(true);
    }

    function test_royalty() public {
        (address recv, uint256 amt) = souls.royaltyInfo(1, 10 ether);
        assertEq(recv, owner_);
        assertEq(amt, 0.5 ether); // 500 bps
    }

    function test_supportsInterface() public view {
        DiamondLoupeFacet loupe = DiamondLoupeFacet(diamond);
        assertTrue(loupe.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(loupe.supportsInterface(0x5b5e139f)); // metadata
        assertTrue(loupe.supportsInterface(0x2a55205a)); // ERC2981
    }

    function _prefix(string memory s, uint256 n) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
        return string(out);
    }
}
