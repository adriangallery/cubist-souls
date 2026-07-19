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

    function exists(uint256 tokenId) internal view returns (bool) {
        return layout().owners[tokenId] != address(0);
    }

    function mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert MintToZero();
        Layout storage l = layout();
        if (l.owners[tokenId] != address(0)) revert SoulAlreadyExists(tokenId);
        l.owners[tokenId] = to;
        unchecked {
            l.balances[to] += 1;
            l.totalSupply += 1;
        }
        emit Transfer(address(0), to, tokenId);
    }
}
