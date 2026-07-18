// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazoView {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title RescueFreeFacet - free souls whose canvas was burned OUTSIDE convert()
/// @notice Some holders burned their Pikkazo directly on the legacy contract
///         (`burn()` → 0x0) instead of going through `ConvertFacet.convert()`,
///         so the canvas is gone forever but no Soul was ever minted. This facet
///         lets the owner mint those orphaned Souls to their rightful holder.
///
///         The 1:1 invariant is preserved ON-CHAIN, not by trust: an id can be
///         freed here ONLY if its canvas is already dead on the legacy contract
///         (`ownerOf` reverts) and the Soul is not already freed. A live canvas
///         can NEVER be minted here — it must go through `convert()`, which burns
///         it. This is the exact `CanvasStillAlive` guard used by `SoulsInit` for
///         the pre-diamond burns (#136, #1064), reused for post-deploy strays.
///
///         The recipient is owner-attested: only the owner can call this, and the
///         owner verifies off-chain (burn tx sender) who the liberator was — the
///         same trust model as `SoulsInit.genesisTo`. On-chain we still cannot
///         mint anything for a canvas that is not already burned.
contract RescueFreeFacet {
    /// @notice A stray canvas (burned outside convert) had its Soul freed.
    event SoulRescued(address indexed to, uint256 indexed tokenId);

    error NothingToRescue();
    error TooManyAtOnce();
    error CanvasStillAlive(uint256 tokenId);
    error AlreadyFreed(uint256 tokenId);

    uint256 private constant MAX_PER_TX = 50;

    /// @notice Mint Souls for canvases already burned on the legacy contract.
    /// @param to  the liberator who burned the canvas (owner-attested off-chain).
    /// @param ids the token ids to free; each canvas MUST already be dead on Pikkazo.
    function adminFreeBurned(address to, uint256[] calldata ids) external {
        LibDiamond.enforceIsContractOwner();

        uint256 n = ids.length;
        if (n == 0) revert NothingToRescue();
        if (n > MAX_PER_TX) revert TooManyAtOnce();

        address pikkazo = LibSouls.layout().pikkazo;

        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[i];
            // Soul must not already exist (no double-mint).
            if (LibSouls.exists(id)) revert AlreadyFreed(id);
            // Canvas must already be gone on the legacy contract. If ownerOf
            // succeeds the canvas is alive and MUST use convert() instead.
            try IPikkazoView(pikkazo).ownerOf(id) returns (address) {
                revert CanvasStillAlive(id);
            } catch {}
            LibSouls.mint(to, id);
            emit SoulRescued(to, id);
        }
    }
}
