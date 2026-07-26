// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ReaperFacet - Soul Reapers: feed the second fire with Pikkazo canvases
/// @notice A Soul (the "reaper") consumes Pikkazo canvases as offerings. Each
///         offered canvas is BURNED on the legacy Pikkazo contract using the exact
///         same owner-or-approved gate as convert() — but, unlike convert(), NO
///         Soul is minted for it. Its soul is devoured by the reaper instead:
///         `soulsConsumed[reaperId]` grows, and the canvas id is flagged
///         `canvasConsumed` FOREVER so a Soul for that id can NEVER be minted again.
///
///         The consumed-canvas guarantee is not enforced here in isolation: it lives
///         in LibSouls.mint(), so every present and future minting/rescue facet
///         inherits it for free (see LibSouls.isCanvasConsumed + the guard baked into
///         mint()). Any future rescue facet MUST route through LibSouls.mint() (all
///         do) and may additionally pre-check via isCanvasConsumed() below.
///
///         forgeMark() is the same offering ritual but pays an EXACT price in canvases
///         for a permanent cosmetic "mark" bitflag bound to the reaper token (marks
///         travel with the Soul when it is sold). markIds: 0=Orange 1=FlameCrown
///         2=Phoenix 3=BurningSoul; prices are seeded by ReaperInit and are
///         hot-reconfigurable via setMarkPrice.
///
///         Offering is FREE in ETH ("the fire feeds on canvases, not on ETH") — offer
///         and forgeMark are nonpayable. When a reaper's consumed count first crosses
///         30 it Ascends: `ReaperAscended` fires exactly once. The metadata rename to
///         "Soul Reaper #id", the "Souls Consumed: N" trait and the MH multiplier are
///         applied OFF-CHAIN by api/meta from `soulsConsumed` — the renderer is
///         swappable, so no freeze and no redeploy are needed.
///
///         Storage is append-only in LibSouls.Layout. supportsInterface is NOT declared
///         here — it lives on the Loupe (repo rule).
contract ReaperFacet {
    /// @notice Canvases offered to a reaper. `newConsumed` is the authoritative running
    ///         total AFTER this offering (indexers should use it, not sum pikkazoIds
    ///         across events, since forgeMark also raises the total).
    event SoulsOffered(uint256 indexed reaperId, address indexed offerer, uint256[] pikkazoIds, uint256 newConsumed);
    /// @notice A permanent mark was forged onto a reaper. `cost` == canvases burned ==
    ///         markPrice(markId) at forge time; `newConsumed` is the running total after.
    event MarkForged(uint256 indexed reaperId, uint8 indexed markId, uint256 cost, uint256 newConsumed);
    /// @notice Fired ONCE, the first time a reaper's consumed count reaches >= 30.
    event ReaperAscended(uint256 indexed reaperId, uint256 consumed);
    /// @notice A mark's price (in Pikkazos) was set by the owner.
    event MarkPriceUpdated(uint8 indexed markId, uint16 price);
    /// @notice The Reaper pause switch was toggled by the owner.
    event ReaperPausedSet(bool paused);

    error ReaperIsPaused();
    error NothingOffered();
    error TooManyAtOnce();
    error NotReaperOwner(uint256 reaperId);
    error NotYourPikkazo(uint256 pikkazoId);
    error MarkNotConfigured(uint8 markId);
    error WrongOfferingSize(uint256 required, uint256 provided);
    error MarkAlreadyForged(uint256 reaperId, uint8 markId);
    error Reentrancy();

    uint256 private constant MAX_PER_TX = 50;
    uint256 private constant ASCENSION_THRESHOLD = 30;
    // Shares LibSouls.Layout._reentrancyLock with ConvertFacetV2 so a convert and an
    // offer can never re-enter one another. 0 (fresh storage) reads as "not entered".
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // --------------------------------------------------------------- offerings

    /// @notice Offer `pikkazoIds` to your reaper Soul: burn each canvas on Pikkazo
    ///         (no Soul minted) and add them to `soulsConsumed[reaperId]`. Caller must
    ///         own `reaperId` on this diamond and own each offered canvas, and must
    ///         `setApprovalForAll(diamond,true)` on Pikkazo first (how the diamond
    ///         passes Pikkazo's burn gate). Free in ETH.
    function offer(uint256 reaperId, uint256[] calldata pikkazoIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);
        if (l.reaperPaused) revert ReaperIsPaused();

        uint256 n = pikkazoIds.length;
        if (n == 0) revert NothingOffered();
        if (n > MAX_PER_TX) revert TooManyAtOnce();
        if (l.owners[reaperId] != msg.sender) revert NotReaperOwner(reaperId);

        _consume(l, pikkazoIds);

        uint256 prev = l.soulsConsumed[reaperId];
        uint256 nowConsumed = prev + n;
        l.soulsConsumed[reaperId] = nowConsumed;

        emit SoulsOffered(reaperId, msg.sender, pikkazoIds, nowConsumed);
        _maybeAscend(reaperId, prev, nowConsumed);

        _unlock(l);
    }

    /// @notice Forge a permanent mark onto your reaper. Behaves like offer() but the
    ///         number of canvases MUST equal markPrice(markId), and it sets the mark
    ///         bit (reverts if already forged). Canvases are burned + counted toward
    ///         `soulsConsumed` just like an offering. Free in ETH.
    function forgeMark(uint256 reaperId, uint8 markId, uint256[] calldata pikkazoIds) external {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);
        if (l.reaperPaused) revert ReaperIsPaused();
        if (l.owners[reaperId] != msg.sender) revert NotReaperOwner(reaperId);

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

    // ------------------------------------------------------------------ admin

    /// @notice Set a mark's price in canvases. Owner only, callable at any time
    ///         (hot-reconfigurable). Setting 0 disables forging that mark.
    function setMarkPrice(uint8 markId, uint16 price) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.layout().markPrices[markId] = price;
        emit MarkPriceUpdated(markId, price);
    }

    /// @notice Pause/unpause the Reaper rituals independently of convert(). Owner only.
    function setReaperPaused(bool paused) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.layout().reaperPaused = paused;
        emit ReaperPausedSet(paused);
    }

    // ------------------------------------------------------------------ views

    /// @notice Total Pikkazo canvases a reaper has consumed (offer + forgeMark).
    function soulsConsumed(uint256 reaperId) external view returns (uint256) {
        return LibSouls.layout().soulsConsumed[reaperId];
    }

    /// @notice Bitmask of forged marks for a reaper (bit i == markId i). uint256.
    function marksOf(uint256 reaperId) external view returns (uint256) {
        return LibSouls.layout().reaperMarks[reaperId];
    }

    /// @notice True once a reaper has consumed >= 30 canvases (Ascended).
    function isReaper(uint256 reaperId) external view returns (bool) {
        return LibSouls.layout().soulsConsumed[reaperId] >= ASCENSION_THRESHOLD;
    }

    /// @notice Canvases required to forge a mark (0 == unconfigured/disabled).
    function markPrice(uint8 markId) external view returns (uint16) {
        return LibSouls.layout().markPrices[markId];
    }

    /// @notice The Reaper pause state.
    function reaperPaused() external view returns (bool) {
        return LibSouls.layout().reaperPaused;
    }

    /// @notice True if a Pikkazo canvas was permanently burned as an offering and can
    ///         therefore NEVER back a minted Soul. Exposed for the panel / The Order
    ///         indexer and for any future rescue facet to consult.
    function isCanvasConsumed(uint256 pikkazoId) external view returns (bool) {
        return LibSouls.layout().canvasConsumed[pikkazoId];
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
