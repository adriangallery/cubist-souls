// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ICreatorToken, ITransferValidator721} from "../interfaces/ICreatorToken.sol";

/// @title SoulsCreatorTokenFacet - ERC-721C wiring for Cubist Souls
///
/// @notice Two things live here:
///   1. ICreatorToken (ADD)     - getTransferValidator / getTransferValidationFunction /
///                                setTransferValidator. This trio (interfaceId 0xad0d7f6c,
///                                flagged on the Loupe by CreatorTokenInit) is what
///                                OpenSea reads to mark creator earnings as ENFORCED.
///   2. transfers (REPLACE)     - transferFrom + both safeTransferFrom, identical to
///                                SoulsERC721Facet except for one added hook: the
///                                validator is consulted before the token moves.
///
/// @dev This is the ONE non-additive cut of the collection: the three transfer selectors
///      are Replace'd off SoulsERC721Facet onto this facet. Everything else (approvals,
///      balances, metadata, royalties) stays exactly where it was. The transfer bodies
///      below are a byte-for-byte copy of the originals plus `_validate`, so the
///      accounting cannot drift.
///
/// @dev The facet decides only WHETHER to ask the validator, never WHAT it answers.
///      The answer comes from the collection's security policy, which lives inside the
///      validator and is set with setRulesetOfCollection() - no diamondCut needed to
///      tighten or loosen it later. Shipping with an UNSET policy means the call is a
///      pass-through: nothing is blocked, every marketplace keeps working, and OpenSea
///      still charges the 5% creator fee. Kill switch: setTransferValidator(address(0))
///      removes the external call entirely.
contract SoulsCreatorTokenFacet {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    error NotOwnerNorApproved();
    error NonexistentToken(uint256 tokenId);
    error TransferFromIncorrectOwner();
    error TransferToZero();
    error UnsafeRecipient();

    // --- ICreatorToken (ADD) ---

    function getTransferValidator() external view returns (address) {
        return LibSouls.layout().transferValidator;
    }

    /// @notice Tells integrators which hook this collection calls, and that it is a
    ///         state-changing (non-view) call. Matches ITransferValidator721.
    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        functionSignature = ITransferValidator721.validateTransfer.selector; // 0xcaee23ea
        isViewFunction = false;
    }

    /// @notice Point the collection at a transfer validator, or at address(0) to
    ///         disable validation altogether. Owner only.
    function setTransferValidator(address validator) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.Layout storage l = LibSouls.layout();
        address old = l.transferValidator;
        l.transferValidator = validator;
        emit TransferValidatorUpdated(old, validator);
    }

    // --- transfers (REPLACE) ---

    function transferFrom(address from, address to, uint256 tokenId) public {
        LibSouls.Layout storage l = LibSouls.layout();
        address owner_ = l.owners[tokenId];
        if (owner_ == address(0)) revert NonexistentToken(tokenId);
        if (owner_ != from) revert TransferFromIncorrectOwner();
        if (to == address(0)) revert TransferToZero();
        if (
            msg.sender != owner_ && msg.sender != l.tokenApprovals[tokenId]
                && !l.operatorApprovals[owner_][msg.sender]
        ) revert NotOwnerNorApproved();

        _validate(l, from, to, tokenId);

        delete l.tokenApprovals[tokenId];
        unchecked {
            l.balances[from] -= 1;
            l.balances[to] += 1;
        }
        l.owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    // --- internals ---

    /// @dev No validator configured == plain ERC721, no external call, no extra gas.
    function _validate(LibSouls.Layout storage l, address from, address to, uint256 tokenId) private {
        address validator = l.transferValidator;
        if (validator == address(0)) return;
        ITransferValidator721(validator).validateTransfer(msg.sender, from, to, tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
