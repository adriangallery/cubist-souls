// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ERC-173 Contract Ownership Standard
interface IERC173 {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Get the address of the owner
    function owner() external view returns (address owner_);

    /// @notice Set the address of the new owner of the contract (2-step: initiates transfer)
    function transferOwnership(address _newOwner) external;

    /// @notice Accept ownership transfer (2-step: completes transfer)
    function acceptOwnership() external;

    /// @notice Get the pending owner address
    function pendingOwner() external view returns (address pending_);
}
