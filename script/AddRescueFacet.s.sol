// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RescueFreeFacet} from "../src/facets/RescueFreeFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISoulsView {
    function isFreed(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
}

/// @title AddRescueFacet - add RescueFreeFacet to the live diamond and free the
///        souls of canvases that were burned OUTSIDE convert().
///
/// This is an ADDITIVE diamondCut (no Replace/Remove), consistent with the
/// evolution framework. The rescue mint itself is guarded on-chain: it can only
/// mint an id whose Pikkazo canvas is already dead and whose Soul is not freed.
///
/// Dry-run (no key needed, simulates against real mainnet state):
///   forge script script/AddRescueFacet.s.sol --fork-url $RPC -vvv
///
/// Broadcast (ONLY after go-ahead; key via env, never inlined):
///   forge script script/AddRescueFacet.s.sol --rpc-url $RPC \
///     --private-key $DEPLOYER_KEY --broadcast --slow -vvv
contract AddRescueFacet is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        // recipient = the wallet that burned the canvases (owner-attested).
        address to = vm.envOr("RESCUE_TO", address(0x91796dA9B38C524aFe98b9C915E8118a16f55786));
        uint256[] memory ids = _ids();

        ISoulsView souls = ISoulsView(DIAMOND);
        uint256 supplyBefore = souls.totalSupply();
        console.log("Diamond:        ", DIAMOND);
        console.log("Rescue recipient:", to);
        console.log("Supply before:  ", supplyBefore);
        for (uint256 i = 0; i < ids.length; i++) {
            console.log("  id, already freed?:", ids[i], souls.isFreed(ids[i]));
        }

        vm.startBroadcast();

        // 1) deploy the new facet
        RescueFreeFacet rescue = new RescueFreeFacet();

        // 2) additive cut: add adminFreeBurned
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RescueFreeFacet.adminFreeBurned.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(rescue),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        // 3) free the orphaned souls to their liberator
        RescueFreeFacet(DIAMOND).adminFreeBurned(to, ids);

        vm.stopBroadcast();

        console.log("RescueFreeFacet:", address(rescue));
        console.log("Supply after:   ", souls.totalSupply());
        for (uint256 i = 0; i < ids.length; i++) {
            console.log("  freed id -> owner:", ids[i], souls.ownerOf(ids[i]));
        }
    }

    function _ids() internal view returns (uint256[] memory ids) {
        // default to the verified pair; override with RESCUE_IDS="1905,1906"
        try vm.envUint("RESCUE_IDS", ",") returns (uint256[] memory parsed) {
            if (parsed.length > 0) return parsed;
        } catch {}
        ids = new uint256[](2);
        ids[0] = 1905;
        ids[1] = 1906;
    }
}
