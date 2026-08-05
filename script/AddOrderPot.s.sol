// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {OrderPotFacet} from "../src/facets/OrderPotFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ILoupeP {
    function facetAddress(bytes4 selector) external view returns (address);
}

interface IPot {
    function registerReaper(uint256 id) external;
    function orderRoster() external view returns (uint256[] memory);
    function weightOf(uint256 id) external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function orderPot() external view returns (uint256);
    function isReaper(uint256 id) external view returns (bool);
}

/// @title AddOrderPot - half of every burn-to-mint fee goes to the Order
///
/// Additive cut (11 selectors) plus the roster: every reaper Ascended so far is
/// registered in the same broadcast, so the draw is usable immediately.
///
/// The pot starts EMPTY on purpose. The diamond's current balance mixes mint
/// fees with royalties and the fusion rite, and only the mint fee is shared —
/// there is no honest way to split the past, so the Order's share is counted
/// from here forward, credited by the museum as mints land.
contract AddOrderPot is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    uint256[11] ASCENDED = [uint256(136), 373, 487, 2201, 2680, 3654, 6225, 6559, 6669, 7681, 8777];

    function run() external {
        ILoupeP loupe = ILoupeP(DIAMOND);
        IPot pot = IPot(DIAMOND);

        bytes4[] memory sels = new bytes4[](12);
        sels[0] = OrderPotFacet.registerReaper.selector;
        sels[1] = OrderPotFacet.setWeightParams.selector;
        sels[2] = OrderPotFacet.openDraw.selector;
        sels[3] = OrderPotFacet.settleDraw.selector;
        sels[4] = OrderPotFacet.orderPot.selector;
        sels[5] = OrderPotFacet.orderRoster.selector;
        sels[6] = OrderPotFacet.weightOf.selector;
        sels[7] = OrderPotFacet.totalWeight.selector;
        sels[8] = OrderPotFacet.pendingDraw.selector;
        sels[9] = OrderPotFacet.lastDraw.selector;
        sels[10] = OrderPotFacet.vaultOf.selector;
        sels[11] = OrderPotFacet.weightParams.selector;

        for (uint256 i; i < sels.length; i++) {
            require(loupe.facetAddress(sels[i]) == address(0), "selector already routed");
        }
        for (uint256 i; i < ASCENDED.length; i++) {
            require(pot.isReaper(ASCENDED[i]), "roster stale");
        }

        vm.startBroadcast();

        OrderPotFacet facet = new OrderPotFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        for (uint256 i; i < ASCENDED.length; i++) {
            pot.registerReaper(ASCENDED[i]);
        }

        vm.stopBroadcast();

        console.log("facet:      ", address(facet));
        console.log("roster:     ", pot.orderRoster().length);
        console.log("totalWeight:", pot.totalWeight());
        console.log("pot:        ", pot.orderPot());
        require(pot.orderRoster().length == ASCENDED.length, "roster incomplete");
        require(pot.totalWeight() >= ASCENDED.length, "weights wrong");
    }
}
