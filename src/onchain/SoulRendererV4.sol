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

/// @notice Reaper + cohort selectors live on the SAME diamond that calls this
///         renderer via tokenURI. The diamond address is injected immutable at
///         construction (the renderer is called BY the diamond, but reading it
///         BACK by address is a plain staticcall, not a re-entrant call).
interface IReaperReads {
    function soulsConsumed(uint256 reaperId) external view returns (uint256);
    function marksOf(uint256 reaperId) external view returns (uint256); // bitmask
    function cohortOf(uint256 tokenId) external view returns (uint8);
}

/// @title SoulRendererV4 - fully on-chain, REAPER-AWARE renderer for Cubist Souls
/// @notice Drop-in ISoulRenderer replacement for SoulRendererV2/V3. Produces
///         metadata that is PARITY with the canonical off-chain endpoint
///         (cubistsouls-web app/api/meta + reaper-img), but computed and served
///         entirely on-chain from an SvgStore + live diamond reads.
///
///         Corrects the four V3 blockers found in audit:
///
///         B1 REAPER-AWARE. Reads soulsConsumed + marksOf off the diamond by
///            staticcall. Marks are derived exactly as the api: the on-chain
///            bitmask UNIONED with the milestone thresholds (Orange >=6,
///            Flame Crown >=12, Phoenix >=18, Burning Soul >=30). When marks are
///            present the image COMPOSES with each mark SUBSTITUTING its layer:
///              markId 0 Orange       -> Art Background (cat 0)  [burn-cube 0x0802]
///              markId 3 Burning Soul -> Base           (cat 1)  [burn-cube 0x0800]
///              markId 1 Flame Crown  -> Head           (cat 3)  [burn-cube 0x0801]
///              markId 2 Phoenix      -> FX painted ON TOP of all [burn-cube 0x0803]
///            name becomes "Soul Reaper #id" at consumed >= 30; a numeric
///            "Souls Consumed" attribute is added when consumed > 0; one
///            "Reaper Mark" attribute per set bit (Orange / Flame Crown /
///            Phoenix / Burning Soul), same strings as the api.
///
///         B2 COHORTS. OG membership is decided by an embedded frozen list of the
///            863 OG ids (OGFrozen) — never by cohortOf == 0. A non-OG's era is
///            read live: cohortOf 1..4 -> "Era I".."Era IV". A failed/zero era
///            read OMITS the Cohort attribute (never lies), matching the api.
///
///         B3 FALLBACK. Off-chain BASE is https://cubistsouls.com (own domain) —
///            used for honorarium 1/1s with no on-chain asset and not-yet-uploaded
///            tokens, exactly the V2/V3 contract.
///
///         B4 PARITY. description is the exact long LORE; attributes carry Origin
///            ("Pikkazo Canvas #id"), Status ("Freed"), Cohort, then reaper attrs,
///            in the api's order; external_url is https://cubistsouls.com. The
///            per-trait attribute order matches the canonical Pikkazo metadata
///            (Art Background, Base, Clothes, MOUTH, HEAD, Left Eye, Nose, Right
///            Eye) — Mouth BEFORE Head — while the image z-order draws Head below
///            Mouth. That deliberate asymmetry is the Head/Mouth ordering the
///            audit flagged: attribute order != draw order, both fixed here.
///
///         Extras: (a) a token with a stored one-of-one in the SvgStore renders
///         that image on-chain (its id wins over the trait table); (b) tokenURI /
///         contractURI / composeSvg are view and NEVER revert (code-length guards
///         + try/catch, fall back to BASE); (c) contractURI mirrors api/collection.
contract SoulRendererV4 is ISoulRenderer {
    // -------------------------------------------------------------- config

    /// Off-chain fallback + contractURI host (own domain, post-Vercel — B3).
    string internal constant BASE = "https://cubistsouls.com/api";
    string internal constant EXTERNAL_URL = "https://cubistsouls.com";

    /// The exact long lore string served by api/meta + api/collection (B4).
    string internal constant LORE =
        "Ten thousand cubist portraits were abandoned by their maker. Inside every canvas, a soul stayed trapped. "
        "Each Cubist Soul exists because its holder burned the original canvas on Ethereum, an irreversible act of liberation. "
        "The soul kept its number, and the face it wore in the canvas that held it.";

    /// Milestone thresholds, hardcoded to match api/meta + reaper-img byte-for-byte
    /// (Orange 6, Flame Crown 12, Phoenix 18, Burning Soul 30). marksOf on-chain
    /// already derives the same set from markPrices; we re-union here so parity is
    /// guaranteed even if this renderer is set before the V3 marksOf cut.
    uint256 internal constant TH_ORANGE = 6;
    uint256 internal constant TH_FLAME = 12;
    uint256 internal constant TH_PHOENIX = 18;
    uint256 internal constant TH_BURNING = 30;
    uint256 internal constant ASCEND_AT = 30;

    /// Burn-cube trait ids in the SvgStore (category 8), by markId.
    uint16 internal constant BC_ORANGE = 0x0802; // markId 0 -> substitutes cat 0
    uint16 internal constant BC_FLAME = 0x0801; // markId 1 -> substitutes cat 3
    uint16 internal constant BC_PHOENIX = 0x0803; // markId 2 -> FX on top
    uint16 internal constant BC_BURNING = 0x0800; // markId 3 -> substitutes cat 1

    address public immutable diamond; // soulsConsumed + marksOf + cohortOf
    ISvgStore public immutable store;

    constructor(address diamond_, address store_) {
        diamond = diamond_;
        store = ISvgStore(store_);
    }

    // ------------------------------------------------------------- ISoulRenderer

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        // Never revert: a codeless store cannot compose anything -> off-chain.
        if (address(store).code.length == 0) return _fallback(tokenId);

        (uint256 consumed, uint256 marks) = _reaperState(tokenId);

        // Resolve the image source.
        string memory image;
        uint8[8] memory t; // original base traits (unsubstituted, for attributes)
        bool haveTraits;

        if (store.oneOfOneExists(tokenId)) {
            // A curated 1/1 image wins over the trait table (extra a).
            image = _wrapSvg(store.oneOfOneSvg(tokenId));
            // 1/1s are not in the trait table; leave t as 0xFF x8 (no trait attrs).
            for (uint256 i; i < 8; ++i) t[i] = 0xFF;
        } else {
            t = store.traitsOf(tokenId);
            for (uint256 i; i < 8; ++i) {
                if (t[i] != 0xFF) {
                    haveTraits = true;
                    break;
                }
            }
            // Honorarium raster 1/1 with no on-chain asset, or not-yet-uploaded
            // token -> off-chain fallback, exactly like V2/V3 (B3).
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

    /// @notice Compose an arbitrary stack of traitIds into an on-chain SVG data-URI
    ///         for shop/preview frontends. Never reverts.
    function composeSvg(uint16[] calldata traitIds) external view returns (string memory) {
        if (address(store).code.length == 0) return "";
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 i; i < traitIds.length; ++i) {
            svg = bytes.concat(svg, store.traitSvg(traitIds[i]));
        }
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// @notice Expose the derived reaper state the renderer uses (for indexers /
    ///         the parity harness). Never reverts.
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

    /// @dev consumed + derived mark bitmask, matching api/meta + reaper-img. Any
    ///      read failure yields the neutral {0,0} (fail-open). Diamond always has
    ///      code in production, but guard anyway so a mis-wired renderer can't brick.
    function _reaperState(uint256 tokenId) private view returns (uint256 consumed, uint256 marks) {
        if (diamond.code.length == 0) return (0, 0);
        try IReaperReads(diamond).soulsConsumed(tokenId) returns (uint256 c) {
            consumed = c;
        } catch {}
        try IReaperReads(diamond).marksOf(tokenId) returns (uint256 m) {
            marks = m;
        } catch {}
        // Union with milestone thresholds, exactly as the api does.
        if (consumed >= TH_ORANGE) marks |= (uint256(1) << 0);
        if (consumed >= TH_FLAME) marks |= (uint256(1) << 1);
        if (consumed >= TH_PHOENIX) marks |= (uint256(1) << 2);
        if (consumed >= TH_BURNING) marks |= (uint256(1) << 3);
    }

    // ----------------------------------------------------------------- image

    /// @dev Compose the on-chain SVG in draw z-order (cats 0..7), substituting the
    ///      mark burn-cube layer for its category, then painting Phoenix on top.
    ///      Mirrors reaper-img composeFromBase exactly (marks add their layer even
    ///      if the base category is empty).
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
            if (present) svg = bytes.concat(svg, store.traitSvg(id));
        }
        if (phoenix) svg = bytes.concat(svg, store.traitSvg(BC_PHOENIX)); // FX on top
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

    // Attribute EMISSION order matches the canonical Pikkazo metadata: Mouth (cat 4)
    // is listed BEFORE Head (cat 3). Draw order (image) is cat 0..7 (Head below
    // Mouth). Keep the two independent — this is the Head/Mouth asymmetry.
    // order: Art Background, Base, Clothes, Mouth, Head, Left Eye, Nose, Right Eye.
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

        // 1) per-trait attributes in canonical (Mouth-before-Head) order.
        uint8[8] memory order = _attrCatOrder();
        for (uint256 i; i < 8; ++i) {
            uint8 cat = order[i];
            if (t[cat] == 0xFF) continue;
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

        // 2) Origin, Status (always).
        attrs = abi.encodePacked(
            attrs,
            first ? "" : ",",
            '{"trait_type":"Origin","value":"Pikkazo Canvas #',
            _toString(tokenId),
            '"},{"trait_type":"Status","value":"Freed"}'
        );
        first = false;

        // 3) Cohort (OG from the frozen list, else live era; omit on failure).
        (bool okC, string memory cohortName) = _cohort(tokenId);
        if (okC) {
            attrs = abi.encodePacked(attrs, ',{"trait_type":"Cohort","value":"', cohortName, '"}');
        }

        // 4) Souls Consumed (numeric) when > 0.
        if (consumed > 0) {
            attrs = abi.encodePacked(
                attrs, ',{"trait_type":"Souls Consumed","value":', _toString(consumed), "}"
            );
        }

        // 5) one Reaper Mark per set bit, ascending, api strings.
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

    /// @dev Category label from the store, falling back to the canonical z-order
    ///      labels for cats 0-7 so a fresh store still renders correctly.
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

    /// @dev OG is decided ONLY by the embedded frozen list (B2). A non-OG's era is
    ///      read live from the diamond: 1..4 -> "Era I".."Era IV". Anything else
    ///      (era read failed, or cohortOf == 0 for a non-frozen id) OMITS the
    ///      attribute, exactly like the api's `return null` path. NEVER "OG" from
    ///      cohortOf == 0.
    function _cohort(uint256 tokenId) private view returns (bool ok, string memory name) {
        if (OGFrozen.isOG(tokenId)) return (true, "OG");
        if (diamond.code.length == 0) return (false, "");
        try IReaperReads(diamond).cohortOf(tokenId) returns (uint8 c) {
            if (c == 1) return (true, "Era I");
            if (c == 2) return (true, "Era II");
            if (c == 3) return (true, "Era III");
            if (c == 4) return (true, "Era IV");
            return (false, ""); // c == 0 on a non-frozen id is a glitch: omit.
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
