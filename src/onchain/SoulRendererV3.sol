// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";
import {Base64} from "./Base64.sol";

interface ISvgStore {
    function traitsOf(uint256 tokenId) external view returns (uint8[8] memory);
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function traitName(uint16 traitId) external view returns (string memory);
    function categoryLabel(uint8 cat) external view returns (string memory);
}

interface ICohort {
    function cohortOf(uint256 tokenId) external view returns (uint8);
}

/// @notice OPTIONAL future selector. The Ola-3 TraitFacet added to the diamond
///         MUST expose exactly this signature: it returns the extra traitIds a
///         token has equipped, in paint order (rendered on top of the 8 base
///         layers). Until that facet exists the diamond's fallback reverts on
///         this unknown selector and the renderer's try/catch absorbs it — so
///         THIS already-deployed renderer starts showing equips the day the
///         facet is cut, with no redeploy.
interface IEquip {
    function equippedTraits(uint256 tokenId) external view returns (uint16[] memory);
}

/// @title SoulRendererV3 - fully on-chain, evolvable art renderer for Cubist Souls
/// @notice Drop-in replacement for SoulRendererV2 (same ISoulRenderer surface,
///         consumed by SoulsERC721Facet via staticcall). Composes each Soul's
///         SVG from the per-trait inner fragments in an SvgStore, in the real
///         z-order (art-background, base, clothes, head, mouth, left-eye, nose,
///         right-eye), then paints any equipped traits on top, and emits fully
///         on-chain base64 JSON.
///
///         Evolvable without redeploy: category labels are read from the store
///         (so new categories work), and equips are read from the diamond (so a
///         future TraitFacet lights up automatically). Honorarium 1/1s (raster,
///         0xFF x8) and not-yet-uploaded tokens fall back to the same off-chain
///         endpoint V2 uses. tokenURI / contractURI / composeSvg are view and
///         NEVER revert.
contract SoulRendererV3 is ISoulRenderer {
    /// @dev off-chain fallback (mirrors SoulRendererV2's BASE).
    string internal constant BASE = "https://cubistsouls.vercel.app/api";

    string internal constant DESCRIPTION =
        "A soul freed from an abandoned canvas, reborn fully on-chain.";

    address public immutable diamond; // cohortOf(id) + equippedTraits(id)
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

        // Base layers (z-order) + equipped layers (paint order) on top.
        uint16[] memory layers = _allLayers(t, _equipped(tokenId));

        string memory image = _composeImageURI(layers);
        string memory attrs = _attributes(tokenId, layers);
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

    /// @notice Compose an arbitrary stack of traitIds into an on-chain SVG
    ///         data-URI. For shop/preview frontends to render any candidate
    ///         stack by eth_call against this already-deployed renderer. Never
    ///         reverts (returns "" if the store is unreachable).
    function composeSvg(uint16[] calldata traitIds) external view returns (string memory) {
        if (address(store).code.length == 0) return "";
        return _composeImageURI(traitIds);
    }

    // ------------------------------------------------------------------ internals

    function _fallback(uint256 tokenId) private pure returns (string memory) {
        return string.concat(BASE, "/meta?id=", _toString(tokenId));
    }

    /// @dev Present base traits (z-order) followed by equipped traits (on top).
    function _allLayers(uint8[8] memory t, uint16[] memory equipped)
        private
        pure
        returns (uint16[] memory ids)
    {
        uint256 n;
        for (uint256 cat; cat < 8; ++cat) {
            if (t[cat] != 0xFF) n++;
        }
        ids = new uint16[](n + equipped.length);
        uint256 k;
        for (uint256 cat; cat < 8; ++cat) {
            if (t[cat] == 0xFF) continue;
            ids[k++] = (uint16(cat) << 8) | uint16(t[cat]);
        }
        for (uint256 i; i < equipped.length; ++i) {
            ids[k++] = equipped[i];
        }
    }

    /// @dev Equipped traits from the diamond. try/catch absorbs the unknown-
    ///      selector revert until the TraitFacet exists (diamond always has
    ///      code, so try/catch is valid here without a code-length dodge).
    function _equipped(uint256 tokenId) private view returns (uint16[] memory) {
        if (diamond.code.length == 0) return new uint16[](0);
        try IEquip(diamond).equippedTraits(tokenId) returns (uint16[] memory eq) {
            return eq;
        } catch {
            return new uint16[](0);
        }
    }

    /// @dev Concatenate layers in order and base64-encode the SVG data-URI.
    function _composeImageURI(uint16[] memory ids) private view returns (string memory) {
        bytes memory svg =
            bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 i; i < ids.length; ++i) {
            svg = bytes.concat(svg, store.traitSvg(ids[i]));
        }
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// @dev One attribute per layer (base + equipped) + Cohort.
    function _attributes(uint256 tokenId, uint16[] memory ids) private view returns (string memory) {
        bytes memory attrs = "[";
        bool first = true;
        for (uint256 i; i < ids.length; ++i) {
            uint16 traitId = ids[i];
            attrs = abi.encodePacked(
                attrs,
                first ? "" : ",",
                '{"trait_type":"',
                _catLabel(uint8(traitId >> 8)),
                '","value":"',
                store.traitName(traitId),
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

    /// @dev Category label from the store, falling back to the fixed z-order
    ///      labels for cats 0-7 if the store has none (so a fresh store still
    ///      renders the OG collection correctly).
    function _catLabel(uint8 cat) private view returns (string memory) {
        string memory fromStore = store.categoryLabel(cat);
        if (bytes(fromStore).length != 0) return fromStore;
        if (cat == 0) return "Art Background";
        if (cat == 1) return "Base";
        if (cat == 2) return "Clothes";
        if (cat == 3) return "Head";
        if (cat == 4) return "Mouth";
        if (cat == 5) return "Left Eye";
        if (cat == 6) return "Nose";
        if (cat == 7) return "Right Eye";
        return ""; // unknown category with no store label
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
