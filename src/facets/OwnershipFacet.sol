// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";

/// @title OwnershipFacet - EIP-173 ownership with 2-step transfer
contract OwnershipFacet is IERC173 {
    /// @notice Get the address of the owner
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// @notice Initiate ownership transfer to a new owner (2-step)
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setPendingOwner(_newOwner);
    }

    /// @notice Accept ownership transfer (must be called by pending owner)
    function acceptOwnership() external override {
        LibDiamond.acceptOwnership();
    }

    /// @notice Get the pending owner address
    function pendingOwner() external view override returns (address pending_) {
        pending_ = LibDiamond.pendingOwner();
    }
}
