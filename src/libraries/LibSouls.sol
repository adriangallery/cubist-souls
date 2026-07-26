// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title LibSouls - AppStorage + ERC721 core for Cubist Souls
/// @notice All collection state lives here, at a dedicated slot, so every facet
///         (present and future) reads/writes the same layout. Append-only struct.
library LibSouls {
    bytes32 internal constant STORAGE_SLOT = keccak256("cubistsouls.app.storage");

    struct Layout {
        // --- ERC721 core ---
        string name;
        string symbol;
        mapping(uint256 => address) owners;
        mapping(address => uint256) balances;
        mapping(uint256 => address) tokenApprovals;
        mapping(address => mapping(address => bool)) operatorApprovals;
        uint256 totalSupply;
        // --- conversion ---
        address pikkazo; // the legacy collection whose burn frees a soul
        bool convertPaused;
        // --- metadata ---
        address renderer; // swappable art contract (ISoulRenderer)
        bool rendererFrozen;
        // --- royalties (ERC2981) ---
        address royaltyReceiver;
        uint96 royaltyBps;
        // append new fields BELOW this line only
        //
        // --- ConvertFacetV2: timed pricing + cohort tagging (append-only) ---
        // saleStart is the epoch the pricing curve is measured from (unix seconds).
        // bound1/2/3 are ELAPSED-SECOND thresholds since saleStart (not day counts):
        //   elapsed <  bound1              -> free   (price 0, cohort 1)
        //   bound1  <= elapsed < bound2    -> price1 (cohort 2)
        //   bound2  <= elapsed < bound3    -> price2 (cohort 3)
        //   elapsed >= bound3              -> price3 (cohort 4)
        // freedAt[id] = block.timestamp when a soul was freed via convert() V2.
        // A legacy soul (freed before V2) has freedAt == 0 -> cohort 0 (Genesis).
        // _reentrancyLock: OZ-style guard for the payable convert refund path.
        uint64 saleStart;
        uint256 price1;
        uint256 price2;
        uint256 price3;
        uint32 bound1;
        uint32 bound2;
        uint32 bound3;
        mapping(uint256 => uint64) freedAt;
        uint256 _reentrancyLock;
        // treasury: destination for withdraw() of accrued convert ETH.
        address treasury;
        // --- ReaperFacet: Soul Reapers — Pikkazo canvases burned as offerings (append-only) ---
        // soulsConsumed[reaperId] : running total of Pikkazo canvases a given Soul
        //   ("reaper") has consumed as fuel. Both offer() and forgeMark() add to it.
        // reaperMarks[reaperId]   : bitmask of forged marks (bit i set == markId i forged);
        //   marks are PERMANENT and bound to the token id (they travel on transfer).
        // markPrices[markId]      : number of Pikkazos required to forge that mark
        //   (0=Orange 6, 1=FlameCrown 12, 2=Phoenix 18, 3=BurningSoul 30 — seeded by ReaperInit,
        //   hot-reconfigurable via ReaperFacet.setMarkPrice).
        // canvasConsumed[pikkazoId] : a Pikkazo burned as a reaper offering. This is a
        //   PERMANENT, one-way flag. Such a canvas gave its soul to a reaper and NO Soul
        //   NFT for that id may EVER be minted afterwards. It is the REUSABLE RESCUE GUARD:
        //   mint() below reverts on a consumed canvas, so EVERY minting/rescue facet — present
        //   or future — inherits the guarantee for free simply by routing through LibSouls.mint().
        //   Future rescue facets may also pre-check via isCanvasConsumed(). (NOTE: facets
        //   already deployed BEFORE this field existed carry an inlined pre-guard copy of
        //   mint(); to extend the on-chain guarantee to them they must be recompiled+Replaced.)
        // reaperPaused            : independent pause switch for the ReaperFacet.
        mapping(uint256 => uint256) soulsConsumed;
        mapping(uint256 => uint256) reaperMarks;
        mapping(uint8 => uint16) markPrices;
        mapping(uint256 => bool) canvasConsumed;
        bool reaperPaused;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    // --- shared ERC721 internals (used by ERC721 + Convert facets) ---

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error SoulAlreadyExists(uint256 tokenId);
    error SoulDoesNotExist(uint256 tokenId);
    error MintToZero();
    error CanvasConsumedByReaper(uint256 tokenId);

    function exists(uint256 tokenId) internal view returns (bool) {
        return layout().owners[tokenId] != address(0);
    }

    /// @notice True if a Pikkazo canvas was burned as a Soul Reaper offering. Such a
    ///         canvas can NEVER back a minted Soul again. This is the reusable rescue
    ///         guard: it is enforced inside mint(), so any facet that mints Souls is
    ///         protected without having to remember to check. Kept `internal` so
    ///         future facets can also pre-check before doing work.
    function isCanvasConsumed(uint256 tokenId) internal view returns (bool) {
        return layout().canvasConsumed[tokenId];
    }

    function mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert MintToZero();
        Layout storage l = layout();
        if (l.owners[tokenId] != address(0)) revert SoulAlreadyExists(tokenId);
        // Reusable rescue guard: a canvas devoured by a reaper never mints a Soul.
        if (l.canvasConsumed[tokenId]) revert CanvasConsumedByReaper(tokenId);
        l.owners[tokenId] = to;
        unchecked {
            l.balances[to] += 1;
            l.totalSupply += 1;
        }
        emit Transfer(address(0), to, tokenId);
    }
}
