// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

/// @title ReaperFacetV3 - ECONOMY V2: marks are MILESTONES of accumulated consumption
/// @notice Ratified by Adrian 2026-07-26 ("con 30 almas consiga todos los traits y perks"):
///         the per-batch forge economy is retired. Marks are now HITOS unlocked by the
///         reaper's ACCUMULATED `soulsConsumed`:
///           mark 0 Orange       at >= 6   consumed
///           mark 1 FlameCrown   at >= 12
///           mark 2 Phoenix      at >= 18
///           mark 3 BurningSoul  at >= 30   (skin + rename — the final prize)
///         30 Pikkazos burned = EVERYTHING. There is nothing to buy per batch anymore;
///         the only ritual action is `offer` (unchanged, OG-guarded, on ReaperFacetV2).
///
///         This facet is a minimal Replace of exactly the two selectors whose BEHAVIOUR
///         changes under Economy V2:
///
///         1) `marksOf(uint256)` (0xfb115701) — moved off the original ReaperFacet
///            (0x8fa5..50a5) — becomes a DERIVED VIEW: the bitmask of every milestone
///            whose threshold <= soulsConsumed[id], UNIONED with the legacy on-storage
///            `reaperMarks[id]` bits (Adrian's 2 hand-forged marks on #8777 are a
///            consistent subset of the derived set, so the union changes nothing there
///            but never loses a legacy flag). Thresholds are read from `markPrices`
///            (same numbers 6/12/18/30, now semantically "unlock thresholds", still
///            hot-adjustable via ReaperFacet.setMarkPrice). A milestone with threshold 0
///            (unconfigured/disabled) never derives; its legacy bit, if any, survives via
///            the union.
///
///         2) `forgeMark(uint256,uint8,uint256[])` (0x900b4cc1) — moved off ReaperFacetV2
///            (0xf198..aB10) — now reverts `ForgeDeprecated()`. Marks are earned by
///            consumption, never purchased. The selector is kept live (Replace, not
///            Remove) so any stale caller/UI gets a clear, decodable error instead of a
///            fallthrough / "function does not exist".
///
///         UNCHANGED (NOT touched by this cut): `offer` (ReaperFacetV2, OG guard intact),
///         `isReaper` (>=30, ReaperFacet), and every other view/admin selector on
///         ReaperFacet. Storage is UNCHANGED — no new field in LibSouls.Layout, no _init;
///         markPrices are already seeded and are reused verbatim as thresholds.
///         supportsInterface lives on the Loupe (repo rule).
///
///         Retroactive happy effect: #8777, sitting at 18 consumed, now reads
///         marksOf == Orange | FlameCrown | Phoenix automatically — no tx, no forge.
contract ReaperFacetV3 {
    /// @notice forgeMark is retired under Economy V2 — marks are milestones of
    ///         accumulated consumption, unlocked by offer(), never purchased.
    error ForgeDeprecated();

    /// Number of milestone marks (0=Orange 1=FlameCrown 2=Phoenix 3=BurningSoul).
    /// Kept explicit: the ratified set is exactly these four; adding a 5th milestone is a
    /// deliberate facet change, not a silent setMarkPrice side effect.
    uint8 private constant MARK_COUNT = 4;

    // -------------------------------------------------------------- deprecated

    /// @notice DEPRECATED. Reverts `ForgeDeprecated()`. Marks are no longer bought per
    ///         batch; they unlock automatically as `soulsConsumed` crosses each
    ///         milestone. The only ritual action is `offer`.
    function forgeMark(uint256, uint8, uint256[] calldata) external pure {
        revert ForgeDeprecated();
    }

    // -------------------------------------------------------------------- view

    /// @notice DERIVED bitmask of a reaper's marks under Economy V2: bit `i` is set iff
    ///         `markPrices[i] != 0 && soulsConsumed[reaperId] >= markPrices[i]`, UNIONED
    ///         with the legacy `reaperMarks[reaperId]` storage bits (hand-forged marks
    ///         are preserved). markId layout: 0=Orange 1=FlameCrown 2=Phoenix
    ///         3=BurningSoul. Same selector/signature as before (0xfb115701) so callers
    ///         and the renderer need no ABI change.
    function marksOf(uint256 reaperId) external view returns (uint256) {
        LibSouls.Layout storage l = LibSouls.layout();
        uint256 consumed = l.soulsConsumed[reaperId];
        uint256 derived = l.reaperMarks[reaperId]; // legacy forged bits (union base)
        for (uint8 i = 0; i < MARK_COUNT; i++) {
            uint16 threshold = l.markPrices[i];
            if (threshold != 0 && consumed >= threshold) {
                derived |= (uint256(1) << i);
            }
        }
        return derived;
    }
}
