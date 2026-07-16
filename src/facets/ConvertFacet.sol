// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ConvertFacet - burn a Pikkazo, free its Soul
/// @notice The ONLY way a Cubist Soul comes into existence: the holder approves
///         this diamond on the Pikkazo contract, the diamond burns the canvas
///         (real ERC721A burn, supply goes down forever) and mints the Soul
///         with the SAME tokenId. 1:1, on-chain verifiable, no snapshot.
contract ConvertFacet {
    /// @notice A canvas burned, a soul freed.
    event SoulFreed(address indexed liberator, uint256 indexed tokenId);

    error ConvertIsPaused();
    error NothingToConvert();
    error TooManyAtOnce();
    error NotYourPikkazo(uint256 tokenId);

    uint256 private constant MAX_PER_TX = 50;

    /// @notice Burn `tokenIds` on the Pikkazo contract and mint the same ids here.
    /// @dev Caller must first `setApprovalForAll(diamond, true)` on Pikkazo so the
    ///      diamond passes Pikkazo's owner-or-approved burn check.
    function convert(uint256[] calldata tokenIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.convertPaused) revert ConvertIsPaused();
        uint256 n = tokenIds.length;
        if (n == 0) revert NothingToConvert();
        if (n > MAX_PER_TX) revert TooManyAtOnce();

        IPikkazo pikkazo = IPikkazo(l.pikkazo);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = tokenIds[i];
            // The burn below already enforces owner-or-approved on OUR address,
            // but that alone would let anyone with approval burn a third party's
            // token and mint themselves the soul. Bind soul to canvas owner.
            if (pikkazo.ownerOf(id) != msg.sender) revert NotYourPikkazo(id);
            pikkazo.burn(id);
            LibSouls.mint(msg.sender, id);
            emit SoulFreed(msg.sender, id);
        }
    }

    /// @notice The legacy collection this diamond converts from.
    function pikkazoContract() external view returns (address) {
        return LibSouls.layout().pikkazo;
    }

    function convertPaused() external view returns (bool) {
        return LibSouls.layout().convertPaused;
    }

    /// @notice True once `tokenId` has been freed (exists as a Soul).
    function isFreed(uint256 tokenId) external view returns (bool) {
        return LibSouls.exists(tokenId);
    }
}
