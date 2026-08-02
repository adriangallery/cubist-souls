// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title LibRaffle - storage for the museum's raffles
/// @notice Its OWN diamond storage slot, deliberately not appended to LibSouls: the
///         raffles are a self-contained feature and keeping them off the shared
///         layout means a future raffle change can never disturb the collection's
///         core state.
library LibRaffle {
    bytes32 internal constant STORAGE_SLOT = keccak256("cubistsouls.raffle.storage");

    /// @notice How a wallet's tickets are counted FOR ONE RAFFLE. Every field is set
    ///         per raffle, so a new occasion is a new set of numbers — never a new
    ///         facet, never another diamondCut.
    ///
    ///         tickets(wallet) = perConsumedSoul × soulsConsumed   (counted at CLOSE)
    ///                         + perAscendedReaper × ascendedReapers (counted at CLOSE)
    ///                         + perSoulHeld       × soulsHeld       (counted at HOLDER block)
    ///                         + perOGSoulHeld     × ogSoulsHeld     (counted at HOLDER block)
    ///                         + (soulsHeld > 0 ? perHolderWallet : 0)
    ///         then capped at maxPerWallet when that is non-zero.
    struct Weights {
        uint16 perConsumedSoul;   // the reaper tickets: 1 per Pikkazo given to the fire
        uint16 perAscendedReaper; // extra for each soul that went all the way to Soul Reaper
        uint16 perHolderWallet;   // a flat entry for anyone holding a soul at all
        uint16 perSoulHeld;       // 0 by default — for occasions that want size to count
        uint16 perOGSoulHeld;     // 0 by default — for occasions that want seniority to count
        uint32 maxPerWallet;      // 0 = uncapped
    }

    struct Raffle {
        string label;         // "The first 1/1"
        string prizeURI;      // image/description of what is on the table
        // TWO counts, at two heights, because the two kinds of ticket carry different
        // risks. See the facet's header for the full reasoning.
        uint64 holderBlock; // PAST at announcement — the flat per-wallet entry is counted here
        uint64 closeBlock;  // FUTURE — the window shuts; burning up to here still earns tickets
        uint64 drawBlock;   // after closeBlock — its hash is the seed
        bytes32 seed;         // blockhash(drawBlock), 0 until anchored
        uint32 winners;       // how many wallets win
        bool cancelled;
        bytes32 ticketsHash;  // keccak of the published ticket list, set with the winners
        address[] winnerList; // recorded once the draw is published
        Weights w;
    }

    struct Layout {
        uint256 count;
        mapping(uint256 => Raffle) raffles;
        mapping(uint256 => mapping(address => bool)) excluded; // per raffle
        mapping(address => bool) globallyExcluded;             // every raffle, e.g. the museum's own wallets
        address[] globallyExcludedList;                        // enumerable for the site
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}
