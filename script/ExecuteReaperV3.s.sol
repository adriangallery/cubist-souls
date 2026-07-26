// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @title ExecuteReaperV3 - broadcast the Economy-V2 Reaper upgrade on the LIVE diamond
/// @notice REPLACE-only cut of exactly the two selectors whose behaviour changes:
///           - marksOf   (0xfb115701)  moved FROM ReaperFacet   (0x8fa5..50a5) -> V3
///                                     becomes a derived view (milestone thresholds
///                                     UNION legacy reaperMarks bits).
///           - forgeMark (0x900b4cc1)  moved FROM ReaperFacetV2 (0xf198..aB10) -> V3
///                                     now reverts ForgeDeprecated().
///         `offer` (0x9d6f563d) stays on ReaperFacetV2 (OG guard intact); `isReaper`
///         and every other view/admin selector stay on ReaperFacet. NO _init: storage is
///         unchanged and markPrices (6/12/18/30) are reused verbatim as unlock
///         thresholds. Broadcast key MUST be the diamond owner (0xa41D...). Validate
///         first with the fork dry-run (test/ReaperV3Fork.t.sol) — must PASS.
///
/// Run (ONLY after Adrian's explicit go-ahead; key via env, never inlined):
///   forge script script/ExecuteReaperV3.s.sol --rpc-url "$RPC" \
///     --private-key "$KEY" --broadcast --slow -vvv
contract ExecuteReaperV3 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        vm.startBroadcast();

        ReaperFacetV3 facet = new ReaperFacetV3();

        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacetV3.marksOf.selector; // 0xfb115701 (was on ReaperFacet)
        rep[1] = ReaperFacetV3.forgeMark.selector; // 0x900b4cc1 (was on ReaperFacetV2)

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });

        // No initializer: storage layout is unchanged (thresholds reuse markPrices).
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("ReaperFacetV3:", address(facet));
        console.log("Replaced marksOf   0xfb115701 -> V3 (derived view)");
        console.log("Replaced forgeMark 0x900b4cc1 -> V3 (ForgeDeprecated)");
        console.log("Diamond cut applied on", DIAMOND);
    }
}
