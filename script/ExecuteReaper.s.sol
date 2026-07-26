// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @title ExecuteReaper - broadcast the ADD-only ReaperFacet cut on the LIVE diamond
/// @notice ADD-only (no Replace / no Remove), consistent with the diamond evolution
///         framework. Broadcast key MUST be the diamond owner (0xa41D...). Validate
///         first with script/DeployReaper.s.sol fork E2E (must PASS).
///
/// Run (ONLY after Adrian's explicit go-ahead; key via env, never inlined):
///   forge script script/ExecuteReaper.s.sol --rpc-url "$RPC" \
///     --private-key "$KEY" --broadcast --slow -vvv
contract ExecuteReaper is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        vm.startBroadcast();

        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        bytes memory initCalldata = abi.encodeCall(ReaperInit.init, ());

        bytes4[] memory adds = new bytes4[](10);
        adds[0] = ReaperFacet.offer.selector;
        adds[1] = ReaperFacet.forgeMark.selector;
        adds[2] = ReaperFacet.soulsConsumed.selector;
        adds[3] = ReaperFacet.marksOf.selector;
        adds[4] = ReaperFacet.isReaper.selector;
        adds[5] = ReaperFacet.markPrice.selector;
        adds[6] = ReaperFacet.setMarkPrice.selector;
        adds[7] = ReaperFacet.setReaperPaused.selector;
        adds[8] = ReaperFacet.reaperPaused.selector;
        adds[9] = ReaperFacet.isCanvasConsumed.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: adds
        });

        IDiamondCut(DIAMOND).diamondCut(cuts, address(initC), initCalldata);

        vm.stopBroadcast();

        console.log("ReaperFacet:", address(facet));
        console.log("ReaperInit: ", address(initC));
        console.log("Diamond cut applied on", DIAMOND);
    }
}
