// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulsBatchTransferFacet} from "../src/facets/SoulsBatchTransferFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ILoupeView {
    function facetAddress(bytes4 selector) external view returns (address);
}

/// @title AddBatchTransfer - the holder tool: send many Souls in one transaction.
///
/// Purely additive cut: ONE new selector (batchTransfer), nothing replaced,
/// nothing removed. The single-transfer path, the validator policy and the
/// royalties are untouched - the batch calls the same validator hook per token.
///
/// Dry-run against real mainnet state (no key):
///   forge script script/AddBatchTransfer.s.sol --fork-url $RPC -vvv
///
/// Broadcast (ONLY after explicit go-ahead; key via env, never inlined):
///   forge script script/AddBatchTransfer.s.sol --rpc-url $RPC \
///     --private-key $DEPLOYER_KEY --broadcast --slow -vvv
contract AddBatchTransfer is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        ILoupeView loupe = ILoupeView(DIAMOND);
        bytes4 sel = SoulsBatchTransferFacet.batchTransfer.selector;

        console.log("Diamond:", DIAMOND);
        console.log("-- before --");
        console.log("  batchTransfer facet:", loupe.facetAddress(sel));
        require(loupe.facetAddress(sel) == address(0), "batchTransfer already routed");

        vm.startBroadcast();

        SoulsBatchTransferFacet facet = new SoulsBatchTransferFacet();

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("-- after --");
        console.log("  facet deployed:     ", address(facet));
        console.log("  batchTransfer facet:", loupe.facetAddress(sel));
        require(loupe.facetAddress(sel) == address(facet), "cut did not route the selector");
    }
}
