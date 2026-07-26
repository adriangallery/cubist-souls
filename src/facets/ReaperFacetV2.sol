// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ReaperFacetV2 - OG-only Soul Reapers ("Only an OG could become a Soul Reaper")
/// @notice Behaviour-identical successor of the two ReaperFacet ritual entrypoints
///         (`offer` and `forgeMark`) with ONE added rule ratified by Adrian 2026-07-26:
///         the rite is reserved for OG (Genesis) Souls. An OG Soul is one that was NOT
///         freed through the paid V2 sale — exactly `ConvertFacetV2.cohortOf(id) == 0`,
///         which is `freedAt[id] == 0`. Legacy/genesis Souls (migrated or V1-converted)
///         never recorded a `freedAt`, so they are OG; any Soul freed via V2 carries a
///         non-zero `freedAt` and is barred.
///
///         The guard reads `LibSouls.layout().freedAt[reaperId]` DIRECTLY from the
///         shared AppStorage — NO external call to ConvertFacetV2 on the same diamond
///         (cheaper, no re-entrancy surface, identical result). It runs BEFORE any burn,
///         so a non-OG reaper never destroys a canvas.
///
///         Everything else is byte-for-byte the original logic: the reaper consumes
///         Pikkazo canvases (burned on the legacy contract, no Soul minted, flagged
///         `canvasConsumed` forever), `soulsConsumed` grows, marks are forged at exact
///         prices, and `ReaperAscended` fires once at 30. This facet only holds `offer`
///         and `forgeMark`; the views/admin selectors stay on the original ReaperFacet
///         (they never change, and `isReaper` is protected by construction — a non-OG
///         can never accumulate consumption, so it can never read as a Reaper).
///
///         Storage is UNCHANGED (no new field in LibSouls.Layout — the guard reuses the
///         existing ConvertFacetV2 `freedAt` mapping). supportsInterface lives on the
///         Loupe (repo rule).
contract ReaperFacetV2 {
    /// @notice Canvases offered to a reaper. `newConsumed` is the authoritative running
    ///         total AFTER this offering (indexers should use it, not sum pikkazoIds
    ///         across events, since forgeMark also raises the total).
    event SoulsOffered(uint256 indexed reaperId, address indexed offerer, uint256[] pikkazoIds, uint256 newConsumed);
    /// @notice A permanent mark was forged onto a reaper. `cost` == canvases burned ==
    ///         markPrice(markId) at forge time; `newConsumed` is the running total after.
    event MarkForged(uint256 indexed reaperId, uint8 indexed markId, uint256 cost, uint256 newConsumed);
    /// @notice Fired ONCE, the first time a reaper's consumed count reaches >= 30.
    event ReaperAscended(uint256 indexed reaperId, uint256 consumed);

    error ReaperIsPaused();
    error NothingOffered();
    error TooManyAtOnce();
    error NotReaperOwner(uint256 reaperId);
    error NotYourPikkazo(uint256 pikkazoId);
    error MarkNotConfigured(uint8 markId);
    error WrongOfferingSize(uint256 required, uint256 provided);
    error MarkAlreadyForged(uint256 reaperId, uint8 markId);
    error Reentrancy();
    /// @notice The reaper Soul is not an OG (freedAt != 0 -> cohort >= 1). Only OG
    ///         (Genesis, cohort 0) Souls may perform the rite.
    error NotOGSoul(uint256 reaperId);

    uint256 private constant MAX_PER_TX = 50;
    uint256 private constant ASCENSION_THRESHOLD = 30;
    // Shares LibSouls.Layout._reentrancyLock with ConvertFacetV2 so a convert and an
    // offer can never re-enter one another. 0 (fresh storage) reads as "not entered".
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // --------------------------------------------------------------- offerings

    /// @notice Offer `pikkazoIds` to your OG reaper Soul: burn each canvas on Pikkazo
    ///         (no Soul minted) and add them to `soulsConsumed[reaperId]`. Caller must
    ///         own `reaperId` on this diamond, `reaperId` must be an OG Soul
    ///         (freedAt == 0), and caller must own each offered canvas and have
    ///         `setApprovalForAll(diamond,true)` on Pikkazo. Free in ETH.
    function offer(uint256 reaperId, uint256[] calldata pikkazoIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);
        if (l.reaperPaused) revert ReaperIsPaused();

        uint256 n = pikkazoIds.length;
        if (n == 0) revert NothingOffered();
        if (n > MAX_PER_TX) revert TooManyAtOnce();
        if (l.owners[reaperId] != msg.sender) revert NotReaperOwner(reaperId);
        // OG-ONLY: only Genesis Souls (cohort 0 == freedAt 0) may reap. Checked BEFORE
        // any burn so a non-OG reaper never destroys a canvas.
        if (l.freedAt[reaperId] != 0) revert NotOGSoul(reaperId);

        _consume(l, pikkazoIds);

        uint256 prev = l.soulsConsumed[reaperId];
        uint256 nowConsumed = prev + n;
        l.soulsConsumed[reaperId] = nowConsumed;

        emit SoulsOffered(reaperId, msg.sender, pikkazoIds, nowConsumed);
        _maybeAscend(reaperId, prev, nowConsumed);

        _unlock(l);
    }

    /// @notice Forge a permanent mark onto your OG reaper. Behaves like offer() but the
    ///         number of canvases MUST equal markPrice(markId), and it sets the mark
    ///         bit (reverts if already forged). Canvases are burned + counted toward
    ///         `soulsConsumed` just like an offering. OG-only. Free in ETH.
    function forgeMark(uint256 reaperId, uint8 markId, uint256[] calldata pikkazoIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);
        if (l.reaperPaused) revert ReaperIsPaused();
        if (l.owners[reaperId] != msg.sender) revert NotReaperOwner(reaperId);
        // OG-ONLY guard (see offer): before any burn / price work.
        if (l.freedAt[reaperId] != 0) revert NotOGSoul(reaperId);

        uint16 price = l.markPrices[markId];
        if (price == 0) revert MarkNotConfigured(markId);

        uint256 n = pikkazoIds.length;
        if (n != price) revert WrongOfferingSize(price, n);

        uint256 bit = uint256(1) << markId;
        if (l.reaperMarks[reaperId] & bit != 0) revert MarkAlreadyForged(reaperId, markId);

        _consume(l, pikkazoIds);

        l.reaperMarks[reaperId] |= bit;
        uint256 prev = l.soulsConsumed[reaperId];
        uint256 nowConsumed = prev + n;
        l.soulsConsumed[reaperId] = nowConsumed;

        emit MarkForged(reaperId, markId, n, nowConsumed);
        _maybeAscend(reaperId, prev, nowConsumed);

        _unlock(l);
    }

    // --------------------------------------------------------------- internal

    /// Burn each offered canvas (owner-or-approved gate via Pikkazo.burn) WITHOUT
    /// minting a Soul, then flag it consumed forever. Binds each canvas to the caller
    /// first (ownerOf==sender) so an operator cannot feed a third party's canvas to
    /// their own reaper — the same defense convert() uses.
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

    function _maybeAscend(uint256 reaperId, uint256 prev, uint256 nowConsumed) private {
        if (prev < ASCENSION_THRESHOLD && nowConsumed >= ASCENSION_THRESHOLD) {
            emit ReaperAscended(reaperId, nowConsumed);
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
