// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// Executes the ConvertFacetV2 upgrade on the LIVE Cubist Souls diamond.
/// Broadcast key MUST be the diamond owner (0xa41D...).
/// Run: forge script script/ExecuteConvertV2.s.sol --rpc-url $RPC --private-key "$KEY" --broadcast --slow
/// Validated first by script/DeployConvertV2.s.sol fork E2E (must PASS).
contract ExecuteConvertV2 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant TREASURY = 0xCF8509a3fFa4721768499a4631dd31333111c709;
    uint64 constant SALE_START = 1784419200; // 2026-07-19 00:00 UTC
    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    function run() external {
        vm.startBroadcast();

        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();
        bytes memory initCalldata =
            abi.encodeCall(ConvertV2Init.init, (SALE_START, B1, B2, B3, P1, P2, P3, TREASURY));

        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector; // 0xd5ef903a

        bytes4[] memory adds = new bytes4[](10);
        adds[0] = ConvertFacetV2.priceNow.selector;
        adds[1] = ConvertFacetV2.freedAt.selector;
        adds[2] = ConvertFacetV2.cohortOf.selector;
        adds[3] = ConvertFacetV2.saleStart.selector;
        adds[4] = ConvertFacetV2.pricing.selector;
        adds[5] = ConvertFacetV2.setPricing.selector;
        adds[6] = ConvertFacetV2.treasury.selector;
        adds[7] = ConvertFacetV2.setTreasury.selector;
        adds[8] = bytes4(keccak256("withdraw()"));
        adds[9] = bytes4(keccak256("withdraw(address)"));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: adds
        });

        IDiamondCut(DIAMOND).diamondCut(cuts, address(initC), initCalldata);

        vm.stopBroadcast();

        console.log("ConvertFacetV2:", address(v2));
        console.log("ConvertV2Init: ", address(initC));
        console.log("Diamond cut applied on", DIAMOND);
    }
}
