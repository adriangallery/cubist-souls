// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

/// @title CreatorTokenInit - initializer for the ERC-721C cut
/// @notice Run via diamondCut's _init delegatecall together with the
///         SoulsCreatorTokenFacet Add+Replace. Idempotent on purpose: it only
///         writes a flag and an address, so re-running it is harmless.
contract CreatorTokenInit {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    /// @param validator The shared Creator Token transfer validator to consult on
    ///        every transferFrom. Mainnet canonical:
    ///        0x721C008fdff27bf06e7e123956e2fe03b63342e3.
    ///        Pass address(0) to wire the facet but leave validation off.
    function init(address validator) external {
        LibSouls.Layout storage l = LibSouls.layout();
        address old = l.transferValidator;
        l.transferValidator = validator;
        emit TransferValidatorUpdated(old, validator);

        // ICreatorToken — served by DiamondLoupeFacet.supportsInterface. This is the
        // flag marketplaces read to treat creator earnings as enforced on-chain.
        LibDiamond.diamondStorage().supportedInterfaces[0xad0d7f6c] = true;
    }
}
