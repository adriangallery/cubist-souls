// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {MockValidator} from "./CreatorToken.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {SoulsCreatorTokenFacet} from "../src/facets/SoulsCreatorTokenFacet.sol";
import {SoulsBatchTransferFacet} from "../src/facets/SoulsBatchTransferFacet.sol";
import {CreatorTokenInit} from "../src/upgradeInitializers/CreatorTokenInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// A contract with no onERC721Received - the vault a batch must NOT brick souls into.
contract DeafWall {}

/// A receiver that lies about the magic value.
contract WrongMagicReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// Counts callbacks, so we can prove the safe check runs PER TOKEN, not once.
contract CountingReceiver {
    uint256 public received;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        received++;
        return this.onERC721Received.selector;
    }
}

contract BatchTransferTest is Test {
    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd;
    bytes4 constant SEL_SAFE_TRANSFER = 0x42842e0e;
    bytes4 constant SEL_SAFE_TRANSFER_DATA = 0xb88d4fde;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    MockPikkazo pikkazo;
    MockValidator validator;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address other = makeAddr("other");
    address dest = makeAddr("dest");

    SoulsERC721Facet souls;
    SoulsBatchTransferFacet batch;
    SoulsCreatorTokenFacet ct;

    function setUp() public {
        pikkazo = new MockPikkazo();
        validator = new MockValidator();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        souls = SoulsERC721Facet(diamond);
        batch = SoulsBatchTransferFacet(diamond);
        ct = SoulsCreatorTokenFacet(diamond);

        _applyCreatorTokenCut(address(validator));
        _applyBatchCut();

        // holder frees souls 1..5, other frees soul 6 - the honest way, via convert
        _free(holder, 1);
        _free(holder, 2);
        _free(holder, 3);
        _free(holder, 4);
        _free(holder, 5);
        _free(other, 6);
    }

    function _free(address who, uint256 id) internal {
        pikkazo.mint(who, id);
        vm.startPrank(who);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        ConvertFacet(diamond).convert(ids);
        vm.stopPrank();
    }

    /// Mirrors script/AddCreatorToken.s.sol: the state prod is in today.
    function _applyCreatorTokenCut(address validator_) internal {
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

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
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

        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(
            cuts, address(initializer), abi.encodeCall(CreatorTokenInit.init, (validator_))
        );
    }

    /// Mirrors script/AddBatchTransfer.s.sol: one selector, pure Add.
    function _applyBatchCut() internal {
        SoulsBatchTransferFacet facet = new SoulsBatchTransferFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SoulsBatchTransferFacet.batchTransfer.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });

        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    // --- the happy path ---

    function test_batchMovesEverySoul() public {
        vm.expectEmit(true, true, true, true, diamond);
        emit Transfer(holder, dest, 1);
        vm.expectEmit(true, true, true, true, diamond);
        emit Transfer(holder, dest, 3);
        vm.expectEmit(true, true, true, true, diamond);
        emit Transfer(holder, dest, 5);

        vm.prank(holder);
        batch.batchTransfer(dest, _ids(1, 3, 5));

        assertEq(souls.ownerOf(1), dest);
        assertEq(souls.ownerOf(3), dest);
        assertEq(souls.ownerOf(5), dest);
        assertEq(souls.ownerOf(2), holder, "unlisted souls stay put");
        assertEq(souls.balanceOf(holder), 2);
        assertEq(souls.balanceOf(dest), 3);
        assertEq(souls.totalSupply(), 6, "a transfer never changes supply");
    }

    function test_singleTokenBatchWorks() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.prank(holder);
        batch.batchTransfer(dest, ids);
        assertEq(souls.ownerOf(2), dest);
    }

    function test_staleApprovalsAreCleared() public {
        vm.prank(holder);
        souls.approve(other, 1);
        assertEq(souls.getApproved(1), other);

        vm.prank(holder);
        batch.batchTransfer(dest, _ids(1, 2, 3));
        assertEq(souls.getApproved(1), address(0), "approval must not follow the token");
    }

    // --- ownership is checked per token, and the batch is all-or-nothing ---

    function test_revertsIfAnyTokenIsNotYours() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SoulsBatchTransferFacet.NotYourSoul.selector, 6));
        batch.batchTransfer(dest, _ids(1, 2, 6));
        assertEq(souls.ownerOf(1), holder, "revert must roll back the whole batch");
    }

    function test_revertsOnNonexistentToken() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SoulsBatchTransferFacet.NonexistentToken.selector, 9999));
        batch.batchTransfer(dest, _ids(1, 2, 9999));
    }

    function test_revertsOnDuplicateId() public {
        // after the first move holder no longer owns it, so the duplicate trips NotYourSoul
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SoulsBatchTransferFacet.NotYourSoul.selector, 1));
        batch.batchTransfer(dest, _ids(1, 2, 1));
    }

    function test_revertsOnEmptyBatch() public {
        vm.prank(holder);
        vm.expectRevert(SoulsBatchTransferFacet.EmptyBatch.selector);
        batch.batchTransfer(dest, new uint256[](0));
    }

    function test_revertsOnZeroDestination() public {
        vm.prank(holder);
        vm.expectRevert(SoulsBatchTransferFacet.TransferToZero.selector);
        batch.batchTransfer(address(0), _ids(1, 2, 3));
    }

    function test_operatorApprovalGrantsNothingHere() public {
        // even a fully approved operator cannot batch-move someone else's souls:
        // this door is owner-only by design
        vm.prank(holder);
        souls.setApprovalForAll(other, true);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SoulsBatchTransferFacet.NotYourSoul.selector, 1));
        batch.batchTransfer(dest, _ids(1, 2, 3));
    }

    // --- the security policy sees every hop ---

    function test_validatorConsultedPerToken_callerIsOwner() public {
        vm.prank(holder);
        batch.batchTransfer(dest, _ids(1, 2, 3));

        assertEq(validator.calls(), 3, "one validation per soul");
        assertEq(validator.lastCaller(), holder, "caller==from: the OTC path the policy allows");
        assertEq(validator.lastFrom(), holder);
        assertEq(validator.lastTo(), dest);
        assertEq(validator.lastTokenId(), 3);
    }

    function test_validatorBlockRevertsTheBatch() public {
        validator.block_(holder, true);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.CallerNotAllowed.selector, holder));
        batch.batchTransfer(dest, _ids(1, 2, 3));
    }

    function test_noValidatorMeansNoExternalCall() public {
        vm.prank(owner_);
        ct.setTransferValidator(address(0));

        vm.prank(holder);
        batch.batchTransfer(dest, _ids(1, 2, 3));
        assertEq(validator.calls(), 0);
        assertEq(souls.ownerOf(2), dest);
    }

    // --- safe-receiver semantics, per token ---

    function test_contractDestinationMustAcknowledgeEachToken() public {
        CountingReceiver vault = new CountingReceiver();
        vm.prank(holder);
        batch.batchTransfer(address(vault), _ids(1, 2, 3));
        assertEq(vault.received(), 3, "onERC721Received once per soul");
        assertEq(souls.balanceOf(address(vault)), 3);
    }

    function test_revertsIntoDeafContract() public {
        DeafWall wall = new DeafWall();
        vm.prank(holder);
        vm.expectRevert(SoulsBatchTransferFacet.UnsafeRecipient.selector);
        batch.batchTransfer(address(wall), _ids(1, 2, 3));
    }

    function test_revertsOnWrongMagicValue() public {
        WrongMagicReceiver liar = new WrongMagicReceiver();
        vm.prank(holder);
        vm.expectRevert(SoulsBatchTransferFacet.UnsafeRecipient.selector);
        batch.batchTransfer(address(liar), _ids(1, 2, 3));
    }

    // --- what travels with the token ---

    function test_singleTransferPathUntouched() public {
        // the Replace'd single transferFrom keeps working exactly as before the Add
        vm.prank(holder);
        souls.transferFrom(holder, dest, 4);
        assertEq(souls.ownerOf(4), dest);
        assertEq(validator.calls(), 1);
    }
}
