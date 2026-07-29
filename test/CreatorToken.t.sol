// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {SoulsCreatorTokenFacet} from "../src/facets/SoulsCreatorTokenFacet.sol";
import {SoulsSweepFacet} from "../src/facets/SoulsSweepFacet.sol";
import {CreatorTokenInit} from "../src/upgradeInitializers/CreatorTokenInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";

/// Validator stub with the same shape as the real one: a pass-through by default
/// (that is what an UNSET collection policy does), switchable to a blocklist so we
/// can prove the enforcement path works when the policy IS set.
contract MockValidator {
    mapping(address => bool) public blocked;
    uint256 public calls;
    address public lastCaller;
    address public lastFrom;
    address public lastTo;
    uint256 public lastTokenId;

    error CallerNotAllowed(address caller);

    function block_(address operator, bool isBlocked) external {
        blocked[operator] = isBlocked;
    }

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external {
        calls++;
        lastCaller = caller;
        lastFrom = from;
        lastTo = to;
        lastTokenId = tokenId;
        if (blocked[caller]) revert CallerNotAllowed(caller);
    }
}

/// Minimal WETH-shaped token: returns a bool, like the real one.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A token that returns nothing on transfer (USDT-shaped), to prove the sweep
/// does not choke on non-standard ERC20s.
contract MockNoReturnERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract CreatorTokenTest is Test {
    bytes4 constant IID_CREATOR_TOKEN = 0xad0d7f6c;
    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd;
    bytes4 constant SEL_SAFE_TRANSFER = 0x42842e0e;
    bytes4 constant SEL_SAFE_TRANSFER_DATA = 0xb88d4fde;
    bytes4 constant SEL_VALIDATE_TRANSFER = 0xcaee23ea;

    MockPikkazo pikkazo;
    MockValidator validator;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address buyer = makeAddr("buyer");
    address marketplace = makeAddr("marketplace");
    address stranger = makeAddr("stranger");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    SoulsCreatorTokenFacet ct;

    function setUp() public {
        pikkazo = new MockPikkazo();
        validator = new MockValidator();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        ct = SoulsCreatorTokenFacet(diamond);

        _applyCut(address(validator));

        // give `holder` a soul the honest way
        pikkazo.mint(holder, 1);
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        conv.convert(ids);
        vm.stopPrank();
    }

    /// Mirrors script/AddCreatorToken.s.sol exactly: Add the ICreatorToken trio,
    /// Replace the three transfer selectors, init in the same cut.
    function _applyCut(address validator_) internal {
        SoulsCreatorTokenFacet facet = new SoulsCreatorTokenFacet();
        CreatorTokenInit initializer = new CreatorTokenInit();

        bytes4[] memory added = new bytes4[](3);
        added[0] = SoulsCreatorTokenFacet.getTransferValidator.selector;
        added[1] = SoulsCreatorTokenFacet.getTransferValidationFunction.selector;
        added[2] = SoulsCreatorTokenFacet.setTransferValidator.selector;

        bytes4[] memory replaced = new bytes4[](3);
        replaced[0] = SEL_TRANSFER_FROM;
        replaced[1] = SEL_SAFE_TRANSFER;
        replaced[2] = SEL_SAFE_TRANSFER_DATA;

        SoulsSweepFacet sweepFacet = new SoulsSweepFacet();
        bytes4[] memory sweepSels = new bytes4[](2);
        sweepSels[0] = SoulsSweepFacet.sweepERC20.selector;
        sweepSels[1] = SoulsSweepFacet.erc20Balance.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: added
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaced
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(sweepFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sweepSels
        });

        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(
            cuts, address(initializer), abi.encodeCall(CreatorTokenInit.init, (validator_))
        );
    }

    // --- what OpenSea reads ---

    function test_advertisesCreatorTokenInterface() public view {
        assertTrue(IERC165(diamond).supportsInterface(IID_CREATOR_TOKEN), "ICreatorToken flag");
        // the pre-existing flags must survive the cut
        assertTrue(IERC165(diamond).supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(IERC165(diamond).supportsInterface(0x2a55205a), "ERC2981");
    }

    function test_exposesValidatorAndValidationFunction() public view {
        assertEq(ct.getTransferValidator(), address(validator));
        (bytes4 fn, bool isView) = ct.getTransferValidationFunction();
        assertEq(fn, SEL_VALIDATE_TRANSFER);
        assertFalse(isView);
    }

    function test_royaltyInfoUnchangedByTheCut() public view {
        (address receiver, uint256 amount) = souls.royaltyInfo(1, 1 ether);
        assertEq(receiver, owner_);
        assertEq(amount, 0.05 ether, "5%");
    }

    // --- the validator is consulted, with the right arguments ---

    function test_transferConsultsValidator() public {
        vm.prank(holder);
        souls.transferFrom(holder, buyer, 1);

        assertEq(validator.calls(), 1);
        assertEq(validator.lastCaller(), holder);
        assertEq(validator.lastFrom(), holder);
        assertEq(validator.lastTo(), buyer);
        assertEq(validator.lastTokenId(), 1);
        assertEq(souls.ownerOf(1), buyer);
    }

    function test_safeTransferConsultsValidator() public {
        Receiver r = new Receiver();
        vm.prank(holder);
        souls.safeTransferFrom(holder, address(r), 1);
        assertEq(validator.calls(), 1);
        assertEq(souls.ownerOf(1), address(r));
    }

    function test_operatorIsTheCallerNotTheOwner() public {
        vm.prank(holder);
        souls.setApprovalForAll(marketplace, true);

        vm.prank(marketplace);
        souls.transferFrom(holder, buyer, 1);

        assertEq(validator.lastCaller(), marketplace, "caller must be the operator");
        assertEq(souls.ownerOf(1), buyer);
    }

    // --- pass-through by default (unset policy) vs real blocking ---

    function test_passesThroughWhenPolicyAllowsEveryone() public {
        vm.prank(holder);
        souls.setApprovalForAll(marketplace, true);
        vm.prank(marketplace);
        souls.transferFrom(holder, buyer, 1);
        assertEq(souls.ownerOf(1), buyer, "no policy set == nobody blocked");
    }

    function test_blocksBlockedOperatorWhenPolicyIsSet() public {
        validator.block_(marketplace, true);

        vm.prank(holder);
        souls.setApprovalForAll(marketplace, true);

        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.CallerNotAllowed.selector, marketplace));
        souls.transferFrom(holder, buyer, 1);

        assertEq(souls.ownerOf(1), holder, "token must not move");
    }

    // --- kill switch ---

    function test_killSwitchRestoresPlainTransfers() public {
        validator.block_(holder, true);

        vm.prank(owner_);
        ct.setTransferValidator(address(0));

        vm.prank(holder);
        souls.transferFrom(holder, buyer, 1); // no external call at all
        assertEq(souls.ownerOf(1), buyer);
        assertEq(validator.calls(), 0);
    }

    function test_onlyOwnerCanSetValidator() public {
        vm.prank(stranger);
        vm.expectRevert();
        ct.setTransferValidator(address(0));
    }

    // --- the replaced bodies must behave exactly like the originals ---

    function test_transferAccountingUnchanged() public {
        assertEq(souls.balanceOf(holder), 1);
        vm.prank(holder);
        souls.approve(marketplace, 1);

        vm.prank(marketplace);
        souls.transferFrom(holder, buyer, 1);

        assertEq(souls.balanceOf(holder), 0);
        assertEq(souls.balanceOf(buyer), 1);
        assertEq(souls.getApproved(1), address(0), "approval cleared");
        assertEq(souls.totalSupply(), 1);
    }

    function test_stillRejectsUnauthorisedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(SoulsCreatorTokenFacet.NotOwnerNorApproved.selector);
        souls.transferFrom(holder, buyer, 1);
        assertEq(validator.calls(), 0, "auth is checked before the validator");
    }

    function test_stillRejectsTransferToZero() public {
        vm.prank(holder);
        vm.expectRevert(SoulsCreatorTokenFacet.TransferToZero.selector);
        souls.transferFrom(holder, address(0), 1);
    }

    function test_stillRejectsWrongFrom() public {
        vm.prank(holder);
        vm.expectRevert(SoulsCreatorTokenFacet.TransferFromIncorrectOwner.selector);
        souls.transferFrom(stranger, buyer, 1);
    }

    function test_stillRejectsNonexistentToken() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SoulsCreatorTokenFacet.NonexistentToken.selector, uint256(99)));
        souls.transferFrom(holder, buyer, 99);
    }

    function test_stillRejectsUnsafeRecipient() public {
        vm.prank(holder);
        vm.expectRevert(SoulsCreatorTokenFacet.UnsafeRecipient.selector);
        souls.safeTransferFrom(holder, address(pikkazo), 1);
    }

    // --- minting is untouched: convert() must not go through the validator ---

    function test_mintIsNotValidated() public {
        validator.block_(address(0), true); // would trip if mint were routed through it
        pikkazo.mint(stranger, 2);
        vm.startPrank(stranger);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        conv.convert(ids2);
        vm.stopPrank();
        assertEq(souls.ownerOf(2), stranger);
        assertEq(validator.calls(), 0, "mint path untouched by the cut");
    }

    // --- royalties paid to the contract itself ---

    function test_diamondAcceptsPlainEthTransfer() public {
        // Seaport pays an ETH-denominated royalty with a bare call. If the diamond
        // rejected it, every sale would revert.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = diamond.call{value: 0.05 ether}("");
        assertTrue(ok, "diamond must accept a bare ETH transfer");
        assertEq(diamond.balance, 0.05 ether);
    }

    function test_wethRoyaltiesAreRecoverable() public {
        MockERC20 weth = new MockERC20();
        weth.mint(diamond, 3 ether); // a sale settled from a bid

        assertEq(SoulsSweepFacet(diamond).erc20Balance(address(weth)), 3 ether);

        vm.prank(owner_);
        uint256 moved = SoulsSweepFacet(diamond).sweepERC20(address(weth), owner_);

        assertEq(moved, 3 ether);
        assertEq(weth.balanceOf(owner_), 3 ether);
        assertEq(weth.balanceOf(diamond), 0);
    }

    function test_sweepHandlesNonStandardTokens() public {
        MockNoReturnERC20 usdt = new MockNoReturnERC20();
        usdt.mint(diamond, 100e6);
        vm.prank(owner_);
        SoulsSweepFacet(diamond).sweepERC20(address(usdt), owner_);
        assertEq(usdt.balanceOf(owner_), 100e6);
    }

    function test_sweepIsOwnerOnly() public {
        MockERC20 weth = new MockERC20();
        weth.mint(diamond, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        SoulsSweepFacet(diamond).sweepERC20(address(weth), stranger);
    }

    function test_sweepRejectsZeroRecipient() public {
        MockERC20 weth = new MockERC20();
        vm.prank(owner_);
        vm.expectRevert(SoulsSweepFacet.ZeroRecipient.selector);
        SoulsSweepFacet(diamond).sweepERC20(address(weth), address(0));
    }

    function test_sweepOfEmptyBalanceIsANoOp() public {
        MockERC20 weth = new MockERC20();
        vm.prank(owner_);
        assertEq(SoulsSweepFacet(diamond).sweepERC20(address(weth), owner_), 0);
    }
}
