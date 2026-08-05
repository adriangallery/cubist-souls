// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ConvertFacetV4} from "../src/facets/ConvertFacetV4.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface IDiaU {
    function priceNow() external view returns (uint256);
    function orderPot() external view returns (uint256);
    function orderRoster() external view returns (uint256[] memory);
    function treasury() external view returns (address);
    function pendingDraw() external view returns (uint64, bool, uint256);
}

/// The draw stops needing anyone to run it: one burn opens it, the next burn
/// settles it. Replaces convert() and withdraw() with V4 and adds the kill
/// switch. Proven on a mainnet fork in DrawInMintFork.t.sol.
contract UpgradeDrawInMint is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        IDiaU d = IDiaU(DIAMOND);
        uint256 price = d.priceNow();
        uint256 pot = d.orderPot();
        uint256 roster = d.orderRoster().length;
        address treasury = d.treasury();
        console.log("price/pot/roster:", price, pot, roster);

        bytes4[] memory rep = new bytes4[](3);
        rep[0] = ConvertFacet.convert.selector;
        rep[1] = bytes4(keccak256("withdraw()"));
        rep[2] = bytes4(keccak256("withdraw(address)"));
        bytes4[] memory add = new bytes4[](1);
        add[0] = ConvertFacetV4.setDrawInMint.selector;

        vm.startBroadcast();
        ConvertFacetV4 v4 = new ConvertFacetV4();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: address(v4), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: rep});
        cuts[1] = IDiamondCut.FacetCut({facetAddress: address(v4), action: IDiamondCut.FacetCutAction.Add, functionSelectors: add});
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        require(d.priceNow() == price, "price moved");
        require(d.orderPot() == pot, "pot moved");
        require(d.orderRoster().length == roster, "roster moved");
        require(d.treasury() == treasury, "treasury moved");
        console.log("convert facet:", address(v4));
    }
}
