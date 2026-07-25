// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";
import {Base64} from "./Base64.sol";

interface ISvgStore {
    function traitsOf(uint256 tokenId) external view returns (uint8[8] memory);
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function traitName(uint16 traitId) external view returns (string memory);
}

interface ICohort {
    function cohortOf(uint256 tokenId) external view returns (uint8);
}

/// @title SoulRendererV3 - fully on-chain art renderer for Cubist Souls
/// @notice Drop-in replacement for SoulRendererV2 (same ISoulRenderer surface,
///         consumed by SoulsERC721Facet via staticcall). Composes each Soul's
///         SVG from the per-trait inner fragments in an immutable SvgStore, in
///         the real z-order (art-background, base, clothes, head, mouth,
///         left-eye, nose, right-eye), and emits fully on-chain base64 JSON.
///
///         Honorarium 1/1s (raster, 0xFF x8 in the table) and any token whose
///         data is not yet uploaded fall back to the exact same off-chain
///         endpoint V2 uses, so the collection never shows a blank. tokenURI /
///         contractURI are view and NEVER revert.
///
///         This module is swappable (setRenderer) — the store address and
///         off-chain fallback base can be re-pointed by shipping a new renderer.
contract SoulRendererV3 is ISoulRenderer {
    /// @dev off-chain fallback (mirrors SoulRendererV2's BASE).
    string internal constant BASE = "https://cubistsouls.vercel.app/api";

    string internal constant DESCRIPTION =
        "A soul freed from an abandoned canvas, reborn fully on-chain.";

    /// @dev z-order category labels (index = category / z-order position).
    ///      Fixed forever, so hardcoded rather than read from the store.
    function _categoryLabel(uint256 cat) private pure returns (string memory) {
        if (cat == 0) return "Art Background";
        if (cat == 1) return "Base";
        if (cat == 2) return "Clothes";
        if (cat == 3) return "Head";
        if (cat == 4) return "Mouth";
        if (cat == 5) return "Left Eye";
        if (cat == 6) return "Nose";
        return "Right Eye"; // cat == 7
    }

    address public immutable diamond; // for cohortOf(id)
    ISvgStore public immutable store;

    constructor(address diamond_, address store_) {
        diamond = diamond_;
        store = ISvgStore(store_);
    }

    // ------------------------------------------------------------------ ISoulRenderer

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        // If the store somehow has no code, never revert: fall back off-chain.
        if (address(store).code.length == 0) return _fallback(tokenId);

        uint8[8] memory t = store.traitsOf(tokenId);

        bool anyTrait;
        for (uint256 i; i < 8; ++i) {
            if (t[i] != 0xFF) {
                anyTrait = true;
                break;
            }
        }
        // Honorarium raster 1/1 or not-yet-uploaded token -> off-chain fallback.
        if (!anyTrait) return _fallback(tokenId);

        string memory image = _image(t);
        string memory attrs = _attributes(tokenId, t);
        string memory idStr = _toString(tokenId);

        bytes memory json = abi.encodePacked(
            '{"name":"Cubist Soul #',
            idStr,
            '","description":"',
            DESCRIPTION,
            '","image":"',
            image,
            '","attributes":',
            attrs,
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function contractURI() external pure override returns (string memory) {
        return string.concat(BASE, "/collection");
    }

    // ------------------------------------------------------------------ internals

    function _fallback(uint256 tokenId) private pure returns (string memory) {
        return string.concat(BASE, "/meta?id=", _toString(tokenId));
    }

    /// @dev Concatenate present layers in z-order and base64-encode the SVG.
    function _image(uint8[8] memory t) private view returns (string memory) {
        bytes memory svg =
            bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 cat; cat < 8; ++cat) {
            if (t[cat] == 0xFF) continue;
            uint16 traitId = (uint16(cat) << 8) | uint16(t[cat]);
            svg = bytes.concat(svg, store.traitSvg(traitId));
        }
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// @dev Build the attributes array: one entry per present trait + Cohort.
    function _attributes(uint256 tokenId, uint8[8] memory t) private view returns (string memory) {
        bytes memory attrs = "[";
        bool first = true;
        for (uint256 cat; cat < 8; ++cat) {
            if (t[cat] == 0xFF) continue;
            uint16 traitId = (uint16(cat) << 8) | uint16(t[cat]);
            string memory value = store.traitName(traitId);
            attrs = abi.encodePacked(
                attrs,
                first ? "" : ",",
                '{"trait_type":"',
                _categoryLabel(cat),
                '","value":"',
                value,
                '"}'
            );
            first = false;
        }

        (bool ok, string memory cohortName) = _cohort(tokenId);
        if (ok) {
            attrs = abi.encodePacked(
                attrs,
                first ? "" : ",",
                '{"trait_type":"Cohort","value":"',
                cohortName,
                '"}'
            );
        }

        return string(abi.encodePacked(attrs, "]"));
    }

    /// @dev cohortOf via staticcall to the diamond. try/catch does NOT catch a
    ///      call to a codeless address, so guard with a code-length check first.
    function _cohort(uint256 tokenId) private view returns (bool ok, string memory name) {
        if (diamond.code.length == 0) return (false, "");
        try ICohort(diamond).cohortOf(tokenId) returns (uint8 c) {
            return (true, _cohortName(c));
        } catch {
            return (false, "");
        }
    }

    function _cohortName(uint8 c) private pure returns (string memory) {
        if (c == 0) return "Genesis";
        if (c == 1) return "Free";
        if (c == 2) return "Tier 1";
        if (c == 3) return "Tier 2";
        if (c == 4) return "Tier 3";
        return "Unknown";
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
