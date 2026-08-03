// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ReaperFacetV4 - THE ORDER IS CLOSED (register sealed at twelve)
/// @notice Ratified by Adrian 2026-08-03, with the twelfth reaper (#1650) ascended:
///         the Order takes no new members. From this cut on, `offer` is reserved for
///         souls that have ALREADY ascended — `soulsConsumed[reaperId] >= 30`.
///
///           • The twelve keep reaping. An ascended reaper may go on burning canvases
///             forever; its `soulsConsumed` keeps climbing (raffle tickets, museum
///             hours, the leaderboard). Nothing they had is taken away.
///           • No new reapers. A soul at 1..29 can no longer climb to 30 — the last
///             rung is gone, not the ladder's promise rewritten. #1682 (1/30) and
///             #2474 (6/30) stand sealed where the doors closed on them. Deliberate:
///             Adrian chose the dry close over a grace clause, so the roster reads
///             exactly twelve, forever.
///           • No new initiates. A soul at 0 consumed cannot light the fire at all —
///             the same guard covers both cases with one comparison, so nobody burns
///             a canvas into a rite that can no longer be finished.
///
///         WHY A HARDCODED RULE AND NOT A SWITCH: `setReaperPaused(true)` already
///         exists but is the wrong tool — it freezes the twelve too. A new storage
///         flag is worse: `reaperPaused` is the last field of LibSouls.Layout and any
///         bool appended beside it shares that slot, where the ALREADY-DEPLOYED
///         ReaperFacet.setReaperPaused would overwrite it on a full-slot store. So the
///         closure lives in code: zero storage, nothing to flip by accident. Reopening
///         the Order is a deliberate diamond cut — a public act, as it should be.
///
///         This facet is a minimal Replace of EXACTLY ONE selector, `offer`
///         (0x9d6f563d), moved off ReaperFacetV2 (0xf198..aB10). The body is
///         byte-for-byte ReaperFacetV2's — same pause check, same OG (freedAt == 0)
///         guard, same reentrancy lock shared with ConvertFacetV2, same burn-then-count
///         order, same events — plus the closure check, placed BEFORE any burn so a
///         rejected offering never destroys a canvas.
///
///         UNCHANGED (NOT touched by this cut): `forgeMark` (ReaperFacetV3, already
///         ForgeDeprecated), `marksOf` (V3 derived view), `isReaper`, every other
///         view/admin selector on ReaperFacet, and the whole vessel/6551 surface.
///         Storage is UNCHANGED — no new field, no _init. supportsInterface lives on
///         the Loupe (repo rule).
contract ReaperFacetV4 {
    /// @notice Canvases offered to a reaper. `newConsumed` is the authoritative running
    ///         total AFTER this offering.
    event SoulsOffered(uint256 indexed reaperId, address indexed offerer, uint256[] pikkazoIds, uint256 newConsumed);
    /// @notice Fired ONCE, the first time a reaper's consumed count reaches >= 30. Under
    ///         V4 it can never fire again (no soul below 30 may offer) — kept for ABI
    ///         and history parity.
    event ReaperAscended(uint256 indexed reaperId, uint256 consumed);

    error ReaperIsPaused();
    error NothingOffered();
    error TooManyAtOnce();
    error NotReaperOwner(uint256 reaperId);
    error NotYourPikkazo(uint256 pikkazoId);
    error Reentrancy();
    /// @notice The reaper Soul is not an OG (freedAt != 0 -> cohort >= 1).
    error NotOGSoul(uint256 reaperId);
    /// @notice The Order is closed. Only the souls that had already ascended
    ///         (soulsConsumed >= 30) may keep feeding the fire; `consumed` is this
    ///         soul's sealed total.
    error OrderClosed(uint256 reaperId, uint256 consumed);

    uint256 private constant MAX_PER_TX = 50;
    uint256 private constant ASCENSION_THRESHOLD = 30;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // --------------------------------------------------------------- offerings

    /// @notice Offer `pikkazoIds` to your ASCENDED reaper: burn each canvas on Pikkazo
    ///         (no Soul minted) and add them to `soulsConsumed[reaperId]`. Caller must
    ///         own `reaperId`, the soul must be OG (freedAt == 0) AND already a reaper
    ///         (soulsConsumed >= 30 — the Order is closed), and the caller must own each
    ///         offered canvas with `setApprovalForAll(diamond,true)` on Pikkazo.
    ///         Free in ETH.
    function offer(uint256 reaperId, uint256[] calldata pikkazoIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);
        if (l.reaperPaused) revert ReaperIsPaused();

        uint256 n = pikkazoIds.length;
        if (n == 0) revert NothingOffered();
        if (n > MAX_PER_TX) revert TooManyAtOnce();
        if (l.owners[reaperId] != msg.sender) revert NotReaperOwner(reaperId);
        // OG-ONLY: only Genesis Souls (cohort 0 == freedAt 0) may reap.
        if (l.freedAt[reaperId] != 0) revert NotOGSoul(reaperId);

        // THE ORDER IS CLOSED: the rite is now reserved for the already-ascended.
        // Checked BEFORE any burn, so a closed-out soul never destroys a canvas.
        uint256 prev = l.soulsConsumed[reaperId];
        if (prev < ASCENSION_THRESHOLD) revert OrderClosed(reaperId, prev);

        _consume(l, pikkazoIds);

        uint256 nowConsumed = prev + n;
        l.soulsConsumed[reaperId] = nowConsumed;

        emit SoulsOffered(reaperId, msg.sender, pikkazoIds, nowConsumed);

        _unlock(l);
    }

    // --------------------------------------------------------------- internal

    /// Burn each offered canvas (owner-or-approved gate via Pikkazo.burn) WITHOUT
    /// minting a Soul, then flag it consumed forever. Binds each canvas to the caller
    /// first (ownerOf == sender) so an operator cannot feed a third party's canvas to
    /// their own reaper.
    function _consume(LibSouls.Layout storage l, uint256[] calldata pikkazoIds) private {
        IPikkazo pikkazo = IPikkazo(l.pikkazo);
        uint256 n = pikkazoIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = pikkazoIds[i];
            if (pikkazo.ownerOf(id) != msg.sender) revert NotYourPikkazo(id);
            pikkazo.burn(id);
            l.canvasConsumed[id] = true; // permanent: no Soul for this id, ever
        }
    }

    function _lock(LibSouls.Layout storage l) private {
        if (l._reentrancyLock == _ENTERED) revert Reentrancy();
        l._reentrancyLock = _ENTERED;
    }

    function _unlock(LibSouls.Layout storage l) private {
        l._reentrancyLock = _NOT_ENTERED;
    }
}
