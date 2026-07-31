// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibRaffle} from "../libraries/LibRaffle.sol";

/// @title RaffleFacet - the museum's raffles, configurable per occasion
///
/// @notice Adrian's brief (30-jul): the raffles must be SET UP, not rebuilt. So this
///         facet holds no prize logic and no hard-coded rules — only a list of
///         raffles, each with its own ticket weights, its own exclusions and its own
///         two blocks. A new occasion is `createRaffle(...)`; it is never another
///         diamondCut.
///
/// @dev WHAT IS ON-CHAIN AND WHAT IS NOT, and why.
///
///      Enumerating every holder and every ticket on-chain would cost a fortune and
///      would have to be re-run for each raffle. It is also unnecessary: the ticket
///      list is DERIVABLE by anyone from public chain state. So the chain holds the
///      three things that must not be trusted to a website —
///
///        1. the RULES (weights, exclusions, the two blocks), fixed before the draw;
///        2. the SEED, taken from a block nobody could predict;
///        3. the OUTCOME, together with the hash of the published ticket list.
///
///      …and the list itself is published off-chain. Anyone can rebuild it from the
///      snapshot block, apply the on-chain rules, draw with the on-chain seed and
///      check they get the same winners and the same hash. The museum cannot lie
///      about the result without it being provable.
///
/// @dev THREE BLOCKS, because an OPEN raffle and an un-farmable one pull in opposite
///      directions and a single snapshot cannot serve both.
///
///      The point of leaving an occasion open for days (Adrian, 31-jul) is to make
///      burning Pikkazos during the window count. A snapshot in the past would earn
///      nobody anything for taking part. But moving it to the end re-opens the hole:
///      the flat per-wallet entry could be farmed by splitting a collection across
///      fifty addresses on the last day.
///
///      The two kinds of ticket carry different risks, so they are counted at
///      different heights:
///
///        `holderBlock` — PAST at announcement. The flat per-wallet entry and the
///        per-soul weights are counted here. This is the farmable part, and a count
///        that already happened cannot be gamed.
///
///        `closeBlock` — FUTURE. Consumed Pikkazos and ascended reapers are counted
///        here, so everything burned while the window is open earns its tickets.
///        These cannot be farmed by splitting wallets: more tickets means more
///        canvases actually given to the fire.
///
///        `drawBlock` — after the close. Its hash is the seed, so the museum cannot
///        know the outcome when it sets any of this up.
///
///      Remove any one of the three and something breaks: no open window, or a
///      farmable entry, or a draw the museum could steer.
contract RaffleFacet {
    event RaffleCreated(uint256 indexed id, string label, uint64 holderBlock, uint64 closeBlock, uint64 drawBlock, uint32 winners);
    event RaffleUpdated(uint256 indexed id);
    event RaffleCancelled(uint256 indexed id);
    event SeedAnchored(uint256 indexed id, bytes32 seed, uint64 drawBlock);
    event DrawRearmed(uint256 indexed id, uint64 newDrawBlock);
    event WinnersPublished(uint256 indexed id, address[] winners, bytes32 ticketsHash);
    event ExclusionSet(uint256 indexed id, address indexed account, bool excluded);
    event GlobalExclusionSet(address indexed account, bool excluded);

    error NoSuchRaffle(uint256 id);
    error SnapshotMustBePast(uint64 holderBlock);
    error CloseMustBeFuture(uint64 closeBlock);
    error DrawMustFollowClose(uint64 drawBlock, uint64 closeBlock);
    error WindowAlreadyClosed(uint256 id, uint64 closeBlock);
    error AlreadyDrawn(uint256 id);
    error NotDrawnYet(uint256 id);
    error DrawBlockNotReached(uint256 id, uint64 drawBlock);
    error DrawWindowExpired(uint256 id, uint64 drawBlock);
    error RaffleIsCancelled(uint256 id);
    error NoWinners();
    error WrongWinnerCount(uint256 expected, uint256 got);

    /// blockhash() only reaches back 256 blocks (~51 min). Past that the seed can no
    /// longer be taken from `drawBlock` and the owner must re-arm with a new one —
    /// which is why `rearmDraw` exists and why it is only allowed BEFORE a seed
    /// exists (it can never be used to re-roll an unwanted result).
    uint64 internal constant BLOCKHASH_WINDOW = 256;

    // ------------------------------------------------------------------ setup

    /// @notice Open a new raffle. Owner only.
    /// @param label       what the occasion is called
    /// @param prizeURI    what is on the table (image / description)
    /// @param holderBlock block the HOLDER entry is counted at — MUST already be mined
    /// @param closeBlock  block the window shuts and burning stops counting — future
    /// @param drawBlock   block whose hash becomes the seed — after the close
    /// @param winners     how many wallets win
    /// @param w           the ticket weights for THIS occasion
    function createRaffle(
        string calldata label,
        string calldata prizeURI,
        uint64 holderBlock,
        uint64 closeBlock,
        uint64 drawBlock,
        uint32 winners,
        LibRaffle.Weights calldata w
    ) external returns (uint256 id) {
        LibDiamond.enforceIsContractOwner();
        if (winners == 0) revert NoWinners();
        if (holderBlock >= block.number) revert SnapshotMustBePast(holderBlock);
        if (closeBlock <= block.number) revert CloseMustBeFuture(closeBlock);
        if (drawBlock <= closeBlock) revert DrawMustFollowClose(drawBlock, closeBlock);

        LibRaffle.Layout storage l = LibRaffle.layout();
        id = l.count++;
        LibRaffle.Raffle storage r = l.raffles[id];
        r.label = label;
        r.prizeURI = prizeURI;
        r.holderBlock = holderBlock;
        r.closeBlock = closeBlock;
        r.drawBlock = drawBlock;
        r.winners = winners;
        r.w = w;

        emit RaffleCreated(id, label, holderBlock, closeBlock, drawBlock, winners);
    }

    /// @notice Re-tune an occasion BEFORE its seed exists. Once the seed is anchored
    ///         the rules are frozen — otherwise the museum could change the weights
    ///         after seeing the draw.
    function setWeights(uint256 id, LibRaffle.Weights calldata w) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        r.w = w;
        emit RaffleUpdated(id);
    }

    function setPrize(uint256 id, string calldata label, string calldata prizeURI) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        r.label = label;
        r.prizeURI = prizeURI;
        emit RaffleUpdated(id);
    }

    /// @notice Move the holder count — still has to be a block already mined.
    function setHolderBlock(uint256 id, uint64 holderBlock) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        if (holderBlock >= block.number) revert SnapshotMustBePast(holderBlock);
        r.holderBlock = holderBlock;
        emit RaffleUpdated(id);
    }

    /// @notice Extend (or shorten) the open window. Only while it is still open and
    ///         before any seed exists — a window cannot be reopened after it shut,
    ///         which would let late burns in after people saw the field.
    function setCloseBlock(uint256 id, uint64 closeBlock, uint64 drawBlock) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        if (block.number >= r.closeBlock) revert WindowAlreadyClosed(id, r.closeBlock);
        if (closeBlock <= block.number) revert CloseMustBeFuture(closeBlock);
        if (drawBlock <= closeBlock) revert DrawMustFollowClose(drawBlock, closeBlock);
        r.closeBlock = closeBlock;
        r.drawBlock = drawBlock;
        emit RaffleUpdated(id);
    }

    /// @notice Point the draw at a different future block. Only before a seed exists,
    ///         so a result can never be re-rolled; this is for the case where nobody
    ///         called `anchorSeed` inside the 256-block window.
    function rearmDraw(uint256 id, uint64 newDrawBlock) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        if (newDrawBlock <= block.number || newDrawBlock <= r.closeBlock) {
            revert DrawMustFollowClose(newDrawBlock, r.closeBlock);
        }
        r.drawBlock = newDrawBlock;
        emit DrawRearmed(id, newDrawBlock);
    }

    /// @notice Keep wallets out of ONE occasion.
    function setExcluded(uint256 id, address[] calldata accounts, bool isExcluded) external {
        LibDiamond.enforceIsContractOwner();
        _mutable(id); // same freeze rule: exclusions are part of the rules
        LibRaffle.Layout storage l = LibRaffle.layout();
        for (uint256 i; i < accounts.length; i++) {
            l.excluded[id][accounts[i]] = isExcluded;
            emit ExclusionSet(id, accounts[i], isExcluded);
        }
    }

    /// @notice Keep wallets out of EVERY occasion — the museum's own wallets belong
    ///         here. Applies to raffles already created as well as future ones, and
    ///         deliberately so: it is the standing "we do not enter our own draws"
    ///         rule, not a per-raffle tweak.
    function setGloballyExcluded(address[] calldata accounts, bool isExcluded) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Layout storage l = LibRaffle.layout();
        for (uint256 i; i < accounts.length; i++) {
            address a = accounts[i];
            if (l.globallyExcluded[a] == isExcluded) continue;
            l.globallyExcluded[a] = isExcluded;
            if (isExcluded) {
                l.globallyExcludedList.push(a);
            } else {
                address[] storage list = l.globallyExcludedList;
                for (uint256 j; j < list.length; j++) {
                    if (list[j] == a) {
                        list[j] = list[list.length - 1];
                        list.pop();
                        break;
                    }
                }
            }
            emit GlobalExclusionSet(a, isExcluded);
        }
    }

    function cancelRaffle(uint256 id) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _mutable(id);
        r.cancelled = true;
        emit RaffleCancelled(id);
    }

    // ------------------------------------------------------------------ the draw

    /// @notice Freeze the seed from the draw block's hash. Deliberately callable by
    ///         ANYONE: the museum must not be the only party able to make the draw
    ///         happen, and there is nothing to choose — the value is whatever that
    ///         block hashed to.
    function anchorSeed(uint256 id) external returns (bytes32 seed) {
        LibRaffle.Raffle storage r = _existing(id);
        if (r.cancelled) revert RaffleIsCancelled(id);
        if (r.seed != bytes32(0)) revert AlreadyDrawn(id);
        if (block.number <= r.drawBlock) revert DrawBlockNotReached(id, r.drawBlock);
        if (block.number > r.drawBlock + BLOCKHASH_WINDOW) revert DrawWindowExpired(id, r.drawBlock);

        seed = blockhash(r.drawBlock);
        // Defensive: inside the window blockhash is always non-zero, but a zero seed
        // would silently mean "not drawn yet" everywhere else in this facet.
        if (seed == bytes32(0)) revert DrawWindowExpired(id, r.drawBlock);
        r.seed = seed;
        emit SeedAnchored(id, seed, r.drawBlock);
    }

    /// @notice Record the outcome and the hash of the ticket list it was drawn from.
    ///         The museum computes the draw off-chain — but from an on-chain seed it
    ///         could not predict, over a snapshot fixed in advance, under weights
    ///         frozen before the seed existed. Publishing the list's hash here is what
    ///         makes the whole thing checkable: rebuild the list, hash it, compare.
    function publishWinners(uint256 id, address[] calldata winners, bytes32 ticketsHash) external {
        LibDiamond.enforceIsContractOwner();
        LibRaffle.Raffle storage r = _existing(id);
        if (r.cancelled) revert RaffleIsCancelled(id);
        if (r.seed == bytes32(0)) revert NotDrawnYet(id);
        if (r.winnerList.length != 0) revert AlreadyDrawn(id);
        if (winners.length != r.winners) revert WrongWinnerCount(r.winners, winners.length);

        for (uint256 i; i < winners.length; i++) r.winnerList.push(winners[i]);
        r.ticketsHash = ticketsHash;
        emit WinnersPublished(id, winners, ticketsHash);
    }

    // ------------------------------------------------------------------ views

    function raffleCount() external view returns (uint256) {
        return LibRaffle.layout().count;
    }

    function raffle(uint256 id)
        external
        view
        returns (
            string memory label,
            string memory prizeURI,
            uint64 holderBlock,
            uint64 closeBlock,
            uint64 drawBlock,
            bytes32 seed,
            uint32 winners,
            bool cancelled,
            bytes32 ticketsHash,
            address[] memory winnerList,
            LibRaffle.Weights memory w
        )
    {
        LibRaffle.Raffle storage r = _existing(id);
        return (r.label, r.prizeURI, r.holderBlock, r.closeBlock, r.drawBlock, r.seed, r.winners, r.cancelled, r.ticketsHash, r.winnerList, r.w);
    }

    /// @notice Whether a wallet is out of this occasion, for either reason.
    function isExcluded(uint256 id, address account) external view returns (bool) {
        LibRaffle.Layout storage l = LibRaffle.layout();
        return l.globallyExcluded[account] || l.excluded[id][account];
    }

    function globallyExcluded() external view returns (address[] memory) {
        return LibRaffle.layout().globallyExcludedList;
    }

    /// @notice The ticket formula, on-chain, so the site and any auditor apply exactly
    ///         the same arithmetic. The COUNTS are supplied by the caller (they come
    ///         from the snapshot block, which this contract cannot read); the WEIGHTS,
    ///         the cap and the exclusion are authoritative here.
    function ticketsFor(
        uint256 id,
        address account,
        uint256 soulsConsumed,
        uint256 ascendedReapers,
        uint256 soulsHeld,
        uint256 ogSoulsHeld
    ) external view returns (uint256) {
        LibRaffle.Layout storage l = LibRaffle.layout();
        if (l.globallyExcluded[account] || l.excluded[id][account]) return 0;
        LibRaffle.Weights memory w = _existing(id).w;

        uint256 t = soulsConsumed * w.perConsumedSoul
            + ascendedReapers * w.perAscendedReaper
            + soulsHeld * w.perSoulHeld
            + ogSoulsHeld * w.perOGSoulHeld;
        if (soulsHeld > 0) t += w.perHolderWallet;
        if (w.maxPerWallet != 0 && t > w.maxPerWallet) t = w.maxPerWallet;
        return t;
    }

    // ------------------------------------------------------------------ internals

    function _existing(uint256 id) private view returns (LibRaffle.Raffle storage r) {
        LibRaffle.Layout storage l = LibRaffle.layout();
        if (id >= l.count) revert NoSuchRaffle(id);
        r = l.raffles[id];
    }

    /// A raffle whose rules may still be changed: it exists, it is not cancelled and
    /// no seed has been taken yet.
    function _mutable(uint256 id) private view returns (LibRaffle.Raffle storage r) {
        r = _existing(id);
        if (r.cancelled) revert RaffleIsCancelled(id);
        if (r.seed != bytes32(0)) revert AlreadyDrawn(id);
    }
}
