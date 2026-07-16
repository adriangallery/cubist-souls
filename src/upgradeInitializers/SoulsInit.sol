// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazoView {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title SoulsInit - one-shot initializer run via diamondCut's _init delegatecall
contract SoulsInit {
    error AlreadyInitialized();
    error ZeroPikkazo();
    error CanvasStillAlive(uint256 tokenId);

    function init(
        address pikkazo,
        address renderer,
        address royaltyReceiver,
        uint96 royaltyBps,
        address genesisTo,
        uint256[] calldata genesisIds
    ) external {
        if (pikkazo == address(0)) revert ZeroPikkazo();
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.pikkazo != address(0)) revert AlreadyInitialized();

        l.name = "Cubist Souls";
        l.symbol = "SOUL";
        l.pikkazo = pikkazo;
        l.renderer = renderer;
        l.royaltyReceiver = royaltyReceiver;
        l.royaltyBps = royaltyBps;

        // ERC165 flags served by DiamondLoupeFacet.supportsInterface
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[0x01ffc9a7] = true; // ERC165
        ds.supportedInterfaces[0x1f931c1c] = true; // IDiamondCut
        ds.supportedInterfaces[0x48e2b093] = true; // IDiamondLoupe
        ds.supportedInterfaces[0x7f5828d0] = true; // ERC173 (ownership)
        ds.supportedInterfaces[0x80ac58cd] = true; // ERC721
        ds.supportedInterfaces[0x5b5e139f] = true; // ERC721Metadata
        ds.supportedInterfaces[0x2a55205a] = true; // ERC2981 royalties
        ds.supportedInterfaces[0x49064906] = true; // ERC4906 metadata update

        // Souls for canvases burned BEFORE this diamond existed (e.g. on the
        // abandoned first deployment). Only an id whose canvas is already gone
        // (ownerOf reverts on the legacy contract) can be minted here — a live
        // canvas must go through convert(). One-shot by the guard above.
        for (uint256 i = 0; i < genesisIds.length; i++) {
            uint256 id = genesisIds[i];
            try IPikkazoView(pikkazo).ownerOf(id) returns (address) {
                revert CanvasStillAlive(id);
            } catch {}
            LibSouls.mint(genesisTo, id);
        }
    }
}
