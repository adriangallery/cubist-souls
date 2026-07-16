// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

/// @title SoulsAdminFacet - owner controls for Cubist Souls
contract SoulsAdminFacet {
    /// @dev ERC4906: tells marketplaces to refresh metadata after a renderer swap.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event RendererUpdated(address indexed oldRenderer, address indexed newRenderer);
    event RendererFrozen(address indexed renderer);
    event ConvertPausedSet(bool paused);
    event RoyaltyInfoUpdated(address receiver, uint96 bps);

    error RendererIsFrozen();
    error RoyaltyTooHigh();

    /// @notice Swap the art module. This is how the collection evolves:
    ///         placeholder today, final art tomorrow — same contract, same ids.
    function setRenderer(address newRenderer) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.rendererFrozen) revert RendererIsFrozen();
        emit RendererUpdated(l.renderer, newRenderer);
        l.renderer = newRenderer;
        emit BatchMetadataUpdate(1, 10_000);
    }

    /// @notice One-way switch. Once the community-approved art is live, freeze it
    ///         and the metadata path can never be changed again.
    function freezeRenderer() external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.Layout storage l = LibSouls.layout();
        l.rendererFrozen = true;
        emit RendererFrozen(l.renderer);
    }

    function rendererFrozen() external view returns (bool) {
        return LibSouls.layout().rendererFrozen;
    }

    function renderer() external view returns (address) {
        return LibSouls.layout().renderer;
    }

    function setConvertPaused(bool paused) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.layout().convertPaused = paused;
        emit ConvertPausedSet(paused);
    }

    function setRoyaltyInfo(address receiver, uint96 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > 1_000) revert RoyaltyTooHigh(); // hard cap 10%
        LibSouls.Layout storage l = LibSouls.layout();
        l.royaltyReceiver = receiver;
        l.royaltyBps = bps;
        emit RoyaltyInfoUpdated(receiver, bps);
    }
}
