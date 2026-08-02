// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";
import {ITransferValidator721} from "../interfaces/ICreatorToken.sol";

/// @title SoulsBatchTransferFacet - move many Souls in one transaction
///
/// @notice The holder tool the community asked for: send any number of your own
///         Souls to one address in a single transaction. No approvals, no helper
///         contract, no marketplace in the middle - you call the collection itself.
///
/// @dev Why a facet and not an external batch-sender: Cubist Souls is an ERC-721C.
///      The collection's security policy inside the transfer validator blocks
///      unauthorized OPERATORS, so a third-party batch contract driven by
///      setApprovalForAll would be rejected (and asking holders to grant blanket
///      approvals is exactly the phishing surface we do not want). Here the caller
///      IS the owner of every token, which is the OTC path the policy allows.
///
/// @dev Purely additive cut (one selector). Each token's move is a byte-for-byte
///      copy of SoulsCreatorTokenFacet.transferFrom collapsed to the owner-caller
///      case, INCLUDING the validator hook - the security policy sees every hop,
///      exactly as if the holder had sent them one by one. Marks, consumed counts
///      and cohorts live on the token id, so they travel untouched.
contract SoulsBatchTransferFacet {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error EmptyBatch();
    error TransferToZero();
    error NonexistentToken(uint256 tokenId);
    error NotYourSoul(uint256 tokenId);
    error UnsafeRecipient();

    /// @notice Send `tokenIds` (all owned by the caller) to `to`, safely: if `to`
    ///         is a contract it must acknowledge each token, same as
    ///         safeTransferFrom, so a batch can never brick souls into a vault
    ///         that cannot handle them.
    function batchTransfer(address to, uint256[] calldata tokenIds) external {
        if (tokenIds.length == 0) revert EmptyBatch();
        if (to == address(0)) revert TransferToZero();

        LibSouls.Layout storage l = LibSouls.layout();
        address validator = l.transferValidator;
        bool toIsContract = to.code.length != 0;

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            address owner_ = l.owners[tokenId];
            if (owner_ == address(0)) revert NonexistentToken(tokenId);
            if (owner_ != msg.sender) revert NotYourSoul(tokenId);

            // Same hook, same order as the single transfer: policy first, then move.
            if (validator != address(0)) {
                ITransferValidator721(validator).validateTransfer(msg.sender, msg.sender, to, tokenId);
            }

            delete l.tokenApprovals[tokenId];
            unchecked {
                l.balances[msg.sender] -= 1;
                l.balances[to] += 1;
            }
            l.owners[tokenId] = to;
            emit Transfer(msg.sender, to, tokenId);

            if (toIsContract) _checkOnERC721Received(msg.sender, to, tokenId);
        }
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId) private {
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "") returns (bytes4 retval) {
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
