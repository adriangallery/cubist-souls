// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperFacetV4} from "../src/facets/ReaperFacetV4.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @title CloseTheOrder - seal the Soul Reaper register at twelve, on the LIVE diamond
/// @notice REPLACE-only cut of EXACTLY ONE selector:
///           - offer (0x9d6f563d)  moved FROM ReaperFacetV2 (0xf198..aB10) -> V4,
///                                 which now requires soulsConsumed >= 30.
///         The twelve keep reaping; no soul below 30 may light or feed the fire again.
///         `forgeMark`/`marksOf` stay on ReaperFacetV3, `isReaper` and every other
///         view/admin selector stay on ReaperFacet. NO _init: storage is unchanged.
///         Broadcast key MUST be the diamond owner (0xa41D...). Validate first with
///         test/ReaperV4Fork.t.sol against the live state — must PASS.
///
/// Run (key via env, never inlined):
///   forge script script/CloseTheOrder.s.sol --rpc-url "$RPC" \
///     --private-key "$KEY" --broadcast --slow -vvv
contract CloseTheOrder is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        vm.startBroadcast();

        ReaperFacetV4 facet = new ReaperFacetV4();

        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ReaperFacetV4.offer.selector; // 0x9d6f563d (was on ReaperFacetV2)

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });

        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("ReaperFacetV4:", address(facet));
        console.log("Replaced offer 0x9d6f563d -> V4 (OrderClosed below 30)");
        console.log("THE ORDER IS CLOSED AT TWELVE. Diamond:", DIAMOND);
    }
}
