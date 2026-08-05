// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ConvertFacetV3} from "../src/facets/ConvertFacetV3.sol";
import {OrderPotFacet} from "../src/facets/OrderPotFacet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface IDiamondU {
    function priceNow() external view returns (uint256);
    function orderPot() external view returns (uint256);
    function orderRoster() external view returns (uint256[] memory);
    function totalWeight() external view returns (uint256);
    function weightParams() external view returns (uint16, uint16);
    function treasury() external view returns (address);
}

interface ILoupeU {
    function facetAddress(bytes4 selector) external view returns (address);
}

/// @title UpgradeOrderPot - the Order's half, taken by the contract itself
///
/// Four movements in one cut:
///   1. convert() and withdraw() move to ConvertFacetV3. The mint now sets aside
///      half of what it charged, and the sweep can no longer carry that half
///      away.
///   2. The pot facet is replaced with the reshaped draw: being a reaper is 100,
///      each soul kept is +1 up to 30.
///   3. setWeightParams/weightParams are added so the shape can be tuned without
///      another cut.
///   4. creditOrder is REMOVED. After this there is no way for anyone, owner
///      included, to move museum money into the Order's line by hand.
///
/// Proven against mainnet state in OrderPotUpgradeFork.t.sol before broadcasting.
contract UpgradeOrderPot is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    bytes4 constant SEL_CREDIT_ORDER = bytes4(keccak256("creditOrder(uint256)"));

    function run() external {
        IDiamondU d = IDiamondU(DIAMOND);
        ILoupeU loupe = ILoupeU(DIAMOND);

        uint256 priceBefore = d.priceNow();
        uint256 potBefore = d.orderPot();
        uint256 rosterBefore = d.orderRoster().length;
        address treasuryBefore = d.treasury();
        require(loupe.facetAddress(SEL_CREDIT_ORDER) != address(0), "creditOrder already gone");
        console.log("price/pot/roster before:", priceBefore, potBefore, rosterBefore);

        bytes4[] memory rep = new bytes4[](3);
        rep[0] = ConvertFacet.convert.selector;
        rep[1] = bytes4(keccak256("withdraw()"));
        rep[2] = bytes4(keccak256("withdraw(address)"));

        bytes4[] memory potRep = new bytes4[](10);
        potRep[0] = OrderPotFacet.registerReaper.selector;
        potRep[1] = OrderPotFacet.openDraw.selector;
        potRep[2] = OrderPotFacet.settleDraw.selector;
        potRep[3] = OrderPotFacet.orderPot.selector;
        potRep[4] = OrderPotFacet.orderRoster.selector;
        potRep[5] = OrderPotFacet.weightOf.selector;
        potRep[6] = OrderPotFacet.totalWeight.selector;
        potRep[7] = OrderPotFacet.pendingDraw.selector;
        potRep[8] = OrderPotFacet.lastDraw.selector;
        potRep[9] = OrderPotFacet.vaultOf.selector;

        bytes4[] memory potAdd = new bytes4[](2);
        potAdd[0] = OrderPotFacet.setWeightParams.selector;
        potAdd[1] = OrderPotFacet.weightParams.selector;

        bytes4[] memory potRemove = new bytes4[](1);
        potRemove[0] = SEL_CREDIT_ORDER;

        vm.startBroadcast();
        ConvertFacetV3 v3 = new ConvertFacetV3();
        OrderPotFacet potFacet = new OrderPotFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: address(v3), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: rep});
        cuts[1] = IDiamondCut.FacetCut({facetAddress: address(potFacet), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: potRep});
        cuts[2] = IDiamondCut.FacetCut({facetAddress: address(potFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: potAdd});
        cuts[3] = IDiamondCut.FacetCut({facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: potRemove});
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        // nothing about the sale may have moved
        require(d.priceNow() == priceBefore, "price moved");
        require(d.orderPot() == potBefore, "pot moved");
        require(d.orderRoster().length == rosterBefore, "roster moved");
        require(d.treasury() == treasuryBefore, "treasury moved");
        require(loupe.facetAddress(SEL_CREDIT_ORDER) == address(0), "creditOrder still routed");

        (uint16 base, uint16 cap) = d.weightParams();
        console.log("convert facet:", address(v3));
        console.log("pot facet:    ", address(potFacet));
        console.log("weights:      ", base, cap);
        console.log("totalWeight:  ", d.totalWeight());
        require(base == 100 && cap == 30, "weights not reshaped");
        require(d.totalWeight() == rosterBefore * 100, "weights wrong");
    }
}
