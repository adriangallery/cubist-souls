// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Diamond} from "../src/diamond/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {SoulsAdminFacet} from "../src/facets/SoulsAdminFacet.sol";
import {PlaceholderRenderer} from "../src/render/PlaceholderRenderer.sol";
import {SoulsInit} from "../src/upgradeInitializers/SoulsInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// Deploys the Cubist Souls diamond.
/// Env: PIKKAZO (defaults to mainnet Pikkazo), ROYALTY_RECEIVER, ROYALTY_BPS.
/// Run: forge script script/Deploy.s.sol --fork-url $RPC (dry-run)
///      add --broadcast --slow only after explicit go-ahead.
contract Deploy is Script {
    address constant PIKKAZO_MAINNET = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    function run() external {
        address pikkazo = vm.envOr("PIKKAZO", PIKKAZO_MAINNET);
        // default: Adrian's personal wallet, not the bot deployer
        address royaltyReceiver = vm.envOr("ROYALTY_RECEIVER", address(0x4943407105999e3E97EFA2035F5cbC64D72581C6));
        uint96 royaltyBps = uint96(vm.envOr("ROYALTY_BPS", uint256(500)));
        // canvases already burned before this deployment: their souls are
        // minted at init to the wallet that burned them (init verifies the
        // canvas is really gone via ownerOf-reverts on the legacy contract)
        address genesisTo = vm.envOr("GENESIS_TO", address(0x4943407105999e3E97EFA2035F5cbC64D72581C6));
        uint256[] memory genesisIds = new uint256[](2);
        genesisIds[0] = 136; // converted on the abandoned first deployment
        genesisIds[1] = 1064; // burned directly, pre-Souls

        vm.startBroadcast();

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        Diamond diamond = new Diamond(msg.sender, address(cutFacet));
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        SoulsERC721Facet erc721 = new SoulsERC721Facet();
        ConvertFacet convertF = new ConvertFacet();
        SoulsAdminFacet admin = new SoulsAdminFacet();
        PlaceholderRenderer renderer = new PlaceholderRenderer();
        SoulsInit initC = new SoulsInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(address(loupe), loupeSelectors());
        cuts[1] = _cut(address(ownership), ownershipSelectors());
        cuts[2] = _cut(address(erc721), erc721Selectors());
        cuts[3] = _cut(address(convertF), convertSelectors());
        cuts[4] = _cut(address(admin), adminSelectors());

        IDiamondCut(address(diamond)).diamondCut(
            cuts,
            address(initC),
            abi.encodeCall(
                SoulsInit.init, (pikkazo, address(renderer), royaltyReceiver, royaltyBps, genesisTo, genesisIds)
            )
        );

        vm.stopBroadcast();

        console.log("Diamond (Cubist Souls):", address(diamond));
        console.log("PlaceholderRenderer:  ", address(renderer));
        console.log("Pikkazo source:       ", pikkazo);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function loupeSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function ownershipSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = OwnershipFacet.owner.selector;
        s[1] = OwnershipFacet.transferOwnership.selector;
        s[2] = OwnershipFacet.acceptOwnership.selector;
        s[3] = OwnershipFacet.pendingOwner.selector;
    }

    function erc721Selectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
        s[0] = SoulsERC721Facet.name.selector;
        s[1] = SoulsERC721Facet.symbol.selector;
        s[2] = SoulsERC721Facet.tokenURI.selector;
        s[3] = SoulsERC721Facet.contractURI.selector;
        s[4] = SoulsERC721Facet.totalSupply.selector;
        s[5] = SoulsERC721Facet.balanceOf.selector;
        s[6] = SoulsERC721Facet.ownerOf.selector;
        s[7] = SoulsERC721Facet.approve.selector;
        s[8] = SoulsERC721Facet.getApproved.selector;
        s[9] = SoulsERC721Facet.setApprovalForAll.selector;
        s[10] = SoulsERC721Facet.isApprovedForAll.selector;
        s[11] = SoulsERC721Facet.transferFrom.selector;
        s[12] = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        s[13] = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
        s[14] = SoulsERC721Facet.royaltyInfo.selector;
    }

    function convertSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = ConvertFacet.convert.selector;
        s[1] = ConvertFacet.pikkazoContract.selector;
        s[2] = ConvertFacet.convertPaused.selector;
        s[3] = ConvertFacet.isFreed.selector;
    }

    function adminSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = SoulsAdminFacet.setRenderer.selector;
        s[1] = SoulsAdminFacet.freezeRenderer.selector;
        s[2] = SoulsAdminFacet.rendererFrozen.selector;
        s[3] = SoulsAdminFacet.renderer.selector;
        s[4] = SoulsAdminFacet.setConvertPaused.selector;
        s[5] = SoulsAdminFacet.setRoyaltyInfo.selector;
    }
}
