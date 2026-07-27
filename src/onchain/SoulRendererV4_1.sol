// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";
import {Base64} from "./Base64.sol";
import {OGFrozen} from "./OGFrozen.sol";

interface ISvgStore {
    function traitsOf(uint256 tokenId) external view returns (uint8[8] memory);
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function traitName(uint16 traitId) external view returns (string memory);
    function categoryLabel(uint8 cat) external view returns (string memory);
    function oneOfOneExists(uint256 id) external view returns (bool);
    function oneOfOneSvg(uint256 id) external view returns (bytes memory);
    function oneOfOneName(uint256 id) external view returns (string memory);
}

interface IReaperReads {
    function soulsConsumed(uint256 reaperId) external view returns (uint256);
    function marksOf(uint256 reaperId) external view returns (uint256); // bitmask
    function cohortOf(uint256 tokenId) external view returns (uint8);
}

interface ITraitOverride {
    function resolve(uint16 traitId) external view returns (uint16);
}

/// @title SoulRendererV4_1 - artist-revision-aware Cubist Souls renderer
/// @notice Byte-for-byte identical to SoulRendererV4 EXCEPT the IMAGE layer ids are
///         passed through an immutable TraitOverride before the SVG is fetched from
///         the store. This lets corrected art (uploaded to the SvgStore under a
///         fresh option id) replace the original layer in the composed image while
///         the ATTRIBUTES stay pinned to the ORIGINAL trait id — so every
///         trait_type/value string, order, name, description, cohort and reaper
///         attribute is UNCHANGED versus V4. With an override table that has no
///         entries, resolve() is the identity and this renderer is metadata- AND
///         image-parity with V4 down to the byte.
///
///         Attributes ALWAYS read the original id (never the override target), a
///         double safeguard on top of the fact that every revision is uploaded
///         with the SAME name string as the original it corrects.
///
///         All the V4 guarantees are preserved: reaper-aware marks/rename/
///         substitution, OG-frozen-list cohorts, off-chain fallback, and
///         never-revert view functions (code-length guards + try/catch, including
///         a fail-open guard around the override read itself).
contract SoulRendererV4_1 is ISoulRenderer {
    // -------------------------------------------------------------- config
    string internal constant BASE = "https://cubistsouls.com/api";
    string internal constant EXTERNAL_URL = "https://cubistsouls.com";

    string internal constant LORE =
        "Ten thousand cubist portraits were abandoned by their maker. Inside every canvas, a soul stayed trapped. "
        "Each Cubist Soul exists because its holder burned the original canvas on Ethereum, an irreversible act of liberation. "
        "The soul kept its number, and the face it wore in the canvas that held it.";

    uint256 internal constant TH_ORANGE = 6;
    uint256 internal constant TH_FLAME = 12;
    uint256 internal constant TH_PHOENIX = 18;
    uint256 internal constant TH_BURNING = 30;
    uint256 internal constant ASCEND_AT = 30;

    uint16 internal constant BC_ORANGE = 0x0802; // markId 0 -> substitutes cat 0
    uint16 internal constant BC_FLAME = 0x0801; // markId 1 -> substitutes cat 3
    uint16 internal constant BC_PHOENIX = 0x0803; // markId 2 -> FX on top
    uint16 internal constant BC_BURNING = 0x0800; // markId 3 -> substitutes cat 1

    address public immutable diamond; // soulsConsumed + marksOf + cohortOf
    ISvgStore public immutable store;
    address public immutable traitOverride; // maps original traitId -> revision id

    constructor(address diamond_, address store_, address override_) {
        diamond = diamond_;
        store = ISvgStore(store_);
        traitOverride = override_;
    }

    // ------------------------------------------------------------- ISoulRenderer

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        if (address(store).code.length == 0) return _fallback(tokenId);

        (uint256 consumed, uint256 marks) = _reaperState(tokenId);

        string memory image;
        uint8[8] memory t; // ORIGINAL base traits (unsubstituted, for attributes)
        bool haveTraits;

        if (store.oneOfOneExists(tokenId)) {
            image = _wrapSvg(store.oneOfOneSvg(tokenId));
            for (uint256 i; i < 8; ++i) t[i] = 0xFF;
        } else {
            t = store.traitsOf(tokenId);
            for (uint256 i; i < 8; ++i) {
                if (t[i] != 0xFF) {
                    haveTraits = true;
                    break;
                }
            }
            if (!haveTraits) return _fallback(tokenId);
            image = _composeReaperImage(t, marks);
        }

        bytes memory json = abi.encodePacked(
            '{"name":"',
            _name(tokenId, consumed),
            '","description":"',
            LORE,
            '","image":"',
            image,
            '","external_url":"',
            EXTERNAL_URL,
            '","attributes":',
            _attributes(tokenId, t, consumed, marks),
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function contractURI() external pure override returns (string memory) {
        return string.concat(BASE, "/collection");
    }

    /// @notice Compose an arbitrary stack of traitIds into an on-chain SVG data-URI.
    ///         Each id is resolved through the override so shop/preview frontends
    ///         see the corrected art too. Never reverts.
    function composeSvg(uint16[] calldata traitIds) external view returns (string memory) {
        if (address(store).code.length == 0) return "";
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 i; i < traitIds.length; ++i) {
            svg = bytes.concat(svg, store.traitSvg(_resolve(traitIds[i])));
        }
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    function reaperState(uint256 tokenId) external view returns (uint256 consumed, uint256 marks) {
        return _reaperState(tokenId);
    }

    // ------------------------------------------------------------------ name

    function _name(uint256 tokenId, uint256 consumed) private pure returns (string memory) {
        return string.concat(
            consumed >= ASCEND_AT ? "Soul Reaper #" : "Cubist Soul #", _toString(tokenId)
        );
    }

    // ---------------------------------------------------------------- reaper

    function _reaperState(uint256 tokenId) private view returns (uint256 consumed, uint256 marks) {
        if (diamond.code.length == 0) return (0, 0);
        try IReaperReads(diamond).soulsConsumed(tokenId) returns (uint256 c) {
            consumed = c;
        } catch {}
        try IReaperReads(diamond).marksOf(tokenId) returns (uint256 m) {
            marks = m;
        } catch {}
        if (consumed >= TH_ORANGE) marks |= (uint256(1) << 0);
        if (consumed >= TH_FLAME) marks |= (uint256(1) << 1);
        if (consumed >= TH_PHOENIX) marks |= (uint256(1) << 2);
        if (consumed >= TH_BURNING) marks |= (uint256(1) << 3);
    }

    // ----------------------------------------------------------------- image

    /// @dev Resolve a layer id through the override (fail-open to the input id) and
    ///      fetch its inner SVG from the store. This is the ONLY behavioural
    ///      difference from V4: the id used to fetch the image bytes is the
    ///      override target; the id used for attributes stays the original.
    function _resolve(uint16 id) private view returns (uint16) {
        address o = traitOverride;
        if (o.code.length == 0) return id;
        try ITraitOverride(o).resolve(id) returns (uint16 r) {
            return r == 0 ? id : r;
        } catch {
            return id;
        }
    }

    function _layerSvg(uint16 id) private view returns (bytes memory) {
        return store.traitSvg(_resolve(id));
    }

    function _composeReaperImage(uint8[8] memory t, uint256 marks) private view returns (string memory) {
        bool orange = marks & (uint256(1) << 0) != 0;
        bool flame = marks & (uint256(1) << 1) != 0;
        bool phoenix = marks & (uint256(1) << 2) != 0;
        bool burning = marks & (uint256(1) << 3) != 0;

        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 cat; cat < 8; ++cat) {
            uint16 id;
            bool present;
            if (cat == 0 && orange) {
                id = BC_ORANGE;
                present = true;
            } else if (cat == 1 && burning) {
                id = BC_BURNING;
                present = true;
            } else if (cat == 3 && flame) {
                id = BC_FLAME;
                present = true;
            } else if (t[cat] != 0xFF) {
                id = (uint16(cat) << 8) | uint16(t[cat]);
                present = true;
            }
            if (present) svg = bytes.concat(svg, _layerSvg(id));
        }
        if (phoenix) svg = bytes.concat(svg, _layerSvg(BC_PHOENIX)); // FX on top
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    function _wrapSvg(bytes memory inner) private pure returns (string memory) {
        bytes memory svg = bytes.concat(
            bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">'),
            inner,
            bytes("</svg>")
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    // ------------------------------------------------------------ attributes

    function _attrCatOrder() private pure returns (uint8[8] memory o) {
        o[0] = 0; // Art Background
        o[1] = 1; // Base
        o[2] = 2; // Clothes
        o[3] = 4; // Mouth
        o[4] = 3; // Head
        o[5] = 5; // Left Eye
        o[6] = 6; // Nose
        o[7] = 7; // Right Eye
    }

    function _attributes(uint256 tokenId, uint8[8] memory t, uint256 consumed, uint256 marks)
        private
        view
        returns (string memory)
    {
        bytes memory attrs = "[";
        bool first = true;

        uint8[8] memory order = _attrCatOrder();
        for (uint256 i; i < 8; ++i) {
            uint8 cat = order[i];
            if (t[cat] == 0xFF) continue;
            // ORIGINAL id for the name — never the override target.
            uint16 traitId = (uint16(cat) << 8) | uint16(t[cat]);
            attrs = abi.encodePacked(
                attrs,
                first ? "" : ",",
                '{"trait_type":"',
                _catLabel(cat),
                '","value":"',
                store.traitName(traitId),
                '"}'
            );
            first = false;
        }

        attrs = abi.encodePacked(
            attrs,
            first ? "" : ",",
            '{"trait_type":"Origin","value":"Pikkazo Canvas #',
            _toString(tokenId),
            '"},{"trait_type":"Status","value":"Freed"}'
        );
        first = false;

        (bool okC, string memory cohortName) = _cohort(tokenId);
        if (okC) {
            attrs = abi.encodePacked(attrs, ',{"trait_type":"Cohort","value":"', cohortName, '"}');
        }

        if (consumed > 0) {
            attrs = abi.encodePacked(
                attrs, ',{"trait_type":"Souls Consumed","value":', _toString(consumed), "}"
            );
        }

        attrs = _appendMark(attrs, marks, 0, "Orange");
        attrs = _appendMark(attrs, marks, 1, "Flame Crown");
        attrs = _appendMark(attrs, marks, 2, "Phoenix");
        attrs = _appendMark(attrs, marks, 3, "Burning Soul");

        return string(abi.encodePacked(attrs, "]"));
    }

    function _appendMark(bytes memory attrs, uint256 marks, uint8 bit, string memory nameStr)
        private
        pure
        returns (bytes memory)
    {
        if (marks & (uint256(1) << bit) == 0) return attrs;
        return abi.encodePacked(attrs, ',{"trait_type":"Reaper Mark","value":"', nameStr, '"}');
    }

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
        return "";
    }

    // ---------------------------------------------------------------- cohort

    function _cohort(uint256 tokenId) private view returns (bool ok, string memory name) {
        if (OGFrozen.isOG(tokenId)) return (true, "OG");
        if (diamond.code.length == 0) return (false, "");
        try IReaperReads(diamond).cohortOf(tokenId) returns (uint8 c) {
            if (c == 1) return (true, "Era I");
            if (c == 2) return (true, "Era II");
            if (c == 3) return (true, "Era III");
            if (c == 4) return (true, "Era IV");
            return (false, "");
        } catch {
            return (false, "");
        }
    }

    // ------------------------------------------------------------------ misc

    function _fallback(uint256 tokenId) private pure returns (string memory) {
        return string.concat(BASE, "/meta?id=", _toString(tokenId));
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
