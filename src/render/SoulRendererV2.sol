// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";

/// @title SoulRendererV2 - reveal renderer for Cubist Souls
/// @notice Each Soul shows the original Pikkazo art and its cubist traits under
///         the Cubist Souls name/lore. Per-token metadata (traits differ per id
///         and can't live on-chain cheaply) is served from an off-chain endpoint
///         that mirrors our durable GitHub copy of the art, falling back to
///         Pikkazo IPFS so a freshly-burned Soul reveals instantly.
///
///         This module is swappable (setRenderer) and not frozen: the base URL
///         can move to a pinned IPFS gateway later without changing token ids.
///         Returning a plain string, tokenURI never reverts.
contract SoulRendererV2 is ISoulRenderer {
    string private constant BASE = "https://cubistsouls.vercel.app/api";

    function tokenURI(uint256 tokenId) external pure override returns (string memory) {
        return string.concat(BASE, "/meta?id=", _toString(tokenId));
    }

    function contractURI() external pure override returns (string memory) {
        return string.concat(BASE, "/collection");
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
