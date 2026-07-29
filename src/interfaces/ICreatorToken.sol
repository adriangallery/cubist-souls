// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ICreatorToken - Limit Break Creator Token Standard (ERC-721C)
/// @notice interfaceId 0xad0d7f6c == getTransferValidator ^ getTransferValidationFunction
///         ^ setTransferValidator. This is the flag OpenSea reads to mark a
///         collection's creator earnings as ENFORCED.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);

    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);

    function setTransferValidator(address validator) external;
}

/// @title ITransferValidator721 - the ERC721 leg of the shared transfer validator.
/// @dev Canonical validator on mainnet: 0x721C008fdff27bf06e7e123956e2fe03b63342e3.
///      It reverts when the calling operator is not allowed by the collection's
///      security policy. With an UNSET policy (rulesetId 0) it is a no-op.
interface ITransferValidator721 {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external;
}
