// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @title ExecuteReaperV2 - broadcast the OG-only Reaper upgrade on the LIVE diamond
/// @notice REPLACE-only cut of the two ritual entrypoints `offer` (0x9d6f563d) and
///         `forgeMark` (0x900b4cc1) onto ReaperFacetV2 (adds the OG-only guard). The
///         other 8 Reaper selectors (views + admin) stay on the original ReaperFacet
///         (0x8fa530b6...50a5) — they never change. NO _init (no new storage; markPrices
///         and reaperPaused are already seeded and preserved). Broadcast key MUST be the
///         diamond owner (0xa41D...). Validate first with a fork dry-run (must PASS).
///
/// Run (ONLY after Adrian's explicit go-ahead; key via env, never inlined):
///   forge script script/ExecuteReaperV2.s.sol --rpc-url "$RPC" \
///     --private-key "$KEY" --broadcast --slow -vvv
contract ExecuteReaperV2 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        vm.startBroadcast();

        ReaperFacetV2 facet = new ReaperFacetV2();

        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacet.offer.selector; // 0x9d6f563d
        rep[1] = ReaperFacet.forgeMark.selector; // 0x900b4cc1

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });

        // No initializer: storage layout is unchanged (guard reuses existing freedAt).
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("ReaperFacetV2:", address(facet));
        console.log("Replaced offer  0x9d6f563d -> V2");
        console.log("Replaced forgeMark 0x900b4cc1 -> V2");
        console.log("Diamond cut applied on", DIAMOND);
    }
}
