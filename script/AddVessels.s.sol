// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {VesselFacet} from "../src/facets/VesselFacet.sol";
import {VesselInit} from "../src/upgradeInitializers/VesselInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ILoupeV {
    function facetAddress(bytes4 selector) external view returns (address);
}

interface IVesselView {
    function vesselFee() external view returns (uint256);
}

/// @title AddVessels - the union of thirty goes live
///
/// Purely additive cut: VesselFacet, 10 selectors, VesselInit seeds the rite
/// fee at the ratified 0.0005 ETH. No storage collision (append-only fields),
/// no Replace, the rescue guard in LibSouls.mint() untouched.
///
/// NOTE (F3): the public dev update explaining the deliberate guard bypass
/// should go out BEFORE the first fusion is announced.
///
/// Dry-run:  forge script script/AddVessels.s.sol --fork-url $RPC \
///             --sender 0xa41D5fAF7BA8B82E276125dE2a053216e91f4814 -vv
/// Broadcast: forge script script/AddVessels.s.sol --rpc-url $RPC \
///             --private-key $DEPLOYER_KEY --broadcast --slow -vvv
contract AddVessels is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        ILoupeV loupe = ILoupeV(DIAMOND);
        bytes4[] memory sels = new bytes4[](10);
        sels[0] = VesselFacet.fuse.selector;
        sels[1] = VesselFacet.renameVessel.selector;
        sels[2] = VesselFacet.setVesselFee.selector;
        sels[3] = VesselFacet.vesselFee.selector;
        sels[4] = VesselFacet.isVesselToken.selector;
        sels[5] = VesselFacet.vesselNameOf.selector;
        sels[6] = VesselFacet.membersOf.selector;
        sels[7] = VesselFacet.vesselOf.selector;
        sels[8] = VesselFacet.custodianOf.selector;
        sels[9] = VesselFacet.vesselVault.selector;

        console.log("Diamond:", DIAMOND);
        for (uint256 i = 0; i < sels.length; i++) {
            require(loupe.facetAddress(sels[i]) == address(0), "selector already routed");
        }

        vm.startBroadcast();
        VesselFacet facet = new VesselFacet();
        VesselInit initC = new VesselInit();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(initC), abi.encodeCall(VesselInit.init, ()));
        vm.stopBroadcast();

        console.log("-- after --");
        console.log("  facet deployed:", address(facet));
        for (uint256 i = 0; i < sels.length; i++) {
            require(loupe.facetAddress(sels[i]) == address(facet), "selector not routed");
        }
        require(IVesselView(DIAMOND).vesselFee() == 0.0005 ether, "fee not seeded");
        console.log("  rite fee: 0.0005 ETH  OK");
    }
}
