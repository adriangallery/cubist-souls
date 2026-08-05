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

interface IVesselReads {
    function isVesselToken(uint256 id) external view returns (bool);
}

interface IKeptReads {
    function balanceOf(address owner) external view returns (uint256);
}

/// The canonical ERC-6551 registry: where a reaper's vault address comes from.
interface IRegistryReads {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}

interface ITraitOverride {
    function resolve(uint16 traitId) external view returns (uint16);
}

/// @title SoulRendererV7 - the tide takes a reaper, one piece at a time
/// @notice Byte-for-byte identical to SoulRendererV4_1 for EVERY Soul and every
///         Soul Reaper. The only addition is a branch for the unions: a token
///         flagged `isVesselToken` on the diamond is not a soul at all, so it
///         gets its own name, lore, art and attributes.
///
///         A MEMENTO MORI (VesselFacet, 03-ago-2026) is thirty souls fused into
///         a canvas a reaper burned long ago. It shows that canvas's recovered
///         art with the DEATH MASK (trait 0x0804) painted ABOVE every other
///         layer — the same "FX on top" slot the Phoenix mark uses — and it is
///         always named by the museum: "Memento Mori #<id>". The holder does not
///         write the plaque (Adrian, 03-ago).
///
///         What a vessel deliberately does NOT carry: the Cohort trait (a vessel
///         has no era — it was never freed), the reaper attributes, and the soul
///         lore. Everything else about the renderer is untouched, including the
///         never-revert guarantee: every external read is guarded by a
///         code-length check or a try/catch, so tokenURI can never break.
/// @notice V6 == V5 plus one attribute, for a reason that is really about
///         buyers: souls entrusted to a reaper live in its token-bound vault,
///         so THEY TRAVEL WITH THE SALE. Someone bidding on a reaper is bidding
///         on whatever stands behind it, and a marketplace has no way to show
///         that. Now the metadata does: "Souls Behind" is the number of tokens
///         its vault holds, read live at tokenURI time.
///
///         Everything else is byte-identical to V5 — souls, Memento Mori, marks,
///         cohorts, names, art. Only an Ascended reaper gains the line, and only
///         when it actually carries something.
/// @notice V7 == V6 plus THE DROWNING. A reaper that keeps souls in its vault
///         is slowly taken by the water: every five souls swaps one more of its
///         fire pieces for the tide, and pulling the souls back out dries it
///         again. The art is a live reading of what the reaper carries — that
///         is the whole point, and it is why it belongs on chain rather than in
///         a picture someone regenerates.
///
///         THE RULES, all of them deliberate:
///           • the HAIR goes first, always — it is what the eye reads first, so
///             one soul already tells you something is happening;
///           • the EYES are never touched. Water covers everything else, and if
///             it took the eyes too, every drowned reaper would look like the
///             same painting. The gaze is what keeps them individual;
///           • the CLOTHES come off once the water starts — a dry torso floating
///             over the tide reads as a piece of another picture;
///           • the ORDER of the remaining pieces is fixed per token, so two
///             reapers at the same depth never look alike;
///           • it is REVERSIBLE, and that is intended: the tide rises and falls
///             with what the holder entrusts.
contract SoulRendererV7 is ISoulRenderer {
    // -------------------------------------------------------------- config
    string internal constant BASE = "https://cubistsouls.com/api";
    string internal constant EXTERNAL_URL = "https://cubistsouls.com";

    string internal constant LORE =
        "Ten thousand cubist portraits were abandoned by their maker. Inside every canvas, a soul stayed trapped. "
        "Each Cubist Soul exists because its holder burned the original canvas on Ethereum, an irreversible act of liberation. "
        "The soul kept its number, and the face it wore in the canvas that held it.";

    string internal constant VESSEL_LORE =
        "Thirty souls joined forces and poured themselves into a canvas that a reaper burned long ago. "
        "The empty canvas hangs again under the death mask, not as a soul but as a Memento Mori. "
        "Its thirty rest in the museum's custody and travel with it, wherever it hangs.";

    uint256 internal constant TH_ORANGE = 6;
    uint256 internal constant TH_FLAME = 12;
    uint256 internal constant TH_PHOENIX = 18;
    uint256 internal constant TH_BURNING = 30;
    uint256 internal constant ASCEND_AT = 30;
    uint256 internal constant UNION_SIZE = 30;

    uint16 internal constant BC_ORANGE = 0x0802; // markId 0 -> substitutes cat 0
    uint16 internal constant BC_FLAME = 0x0801; // markId 1 -> substitutes cat 3
    uint16 internal constant BC_PHOENIX = 0x0803; // markId 2 -> FX on top
    uint16 internal constant BC_BURNING = 0x0800; // markId 3 -> substitutes cat 1
    uint16 internal constant BC_MEMENTO = 0x0804; // the death mask -> FX on top, unions only

    // the tide, in the same reserved band (0x0805..0x080C)
    uint16 internal constant W_BACKGROUND = 0x0805;
    uint16 internal constant W_BASE = 0x0806;
    uint16 internal constant W_HEAD = 0x0807;
    uint16 internal constant W_MOUTH = 0x0808;
    uint16 internal constant W_NOSE = 0x0809;
    uint16 internal constant W_FX = 0x080C;
    uint256 internal constant SOULS_PER_PIECE = 5; // 30 kept souls = fully drowned
    uint256 internal constant DROWN_PIECES = 6;

    // the vault a reaper keeps its souls in (same stack as ReaperAccountFacet)
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    bytes32 internal constant SALT = bytes32(0);

    address public immutable diamond; // soulsConsumed + marksOf + cohortOf + isVesselToken
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

        if (_isVessel(tokenId)) return _vesselURI(tokenId);

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
            image = _composeDrownedImage(tokenId, t, marks, _depth(tokenId, consumed));
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

    // ---------------------------------------------------------------- unions

    /// @dev Fail-open: an unreachable diamond, an old diamond without the facet,
    ///      or any revert means "not a union" and the soul path runs unchanged.
    function _isVessel(uint256 tokenId) private view returns (bool) {
        if (diamond.code.length == 0) return false;
        try IVesselReads(diamond).isVesselToken(tokenId) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    function _vesselURI(uint256 tokenId) private view returns (string memory) {
        string memory image;

        if (store.oneOfOneExists(tokenId)) {
            image = _wrapWithMask(store.oneOfOneSvg(tokenId));
        } else {
            uint8[8] memory t = store.traitsOf(tokenId);
            bool haveTraits;
            for (uint256 i; i < 8; ++i) {
                if (t[i] != 0xFF) {
                    haveTraits = true;
                    break;
                }
            }
            if (!haveTraits) return _fallback(tokenId);
            image = _composeVesselImage(t);
        }

        bytes memory json = abi.encodePacked(
            '{"name":"Memento Mori #',
            _toString(tokenId),
            '","description":"',
            VESSEL_LORE,
            '","image":"',
            image,
            '","external_url":"',
            EXTERNAL_URL,
            '/vessels","attributes":',
            _vesselAttributes(tokenId),
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// The canvas's own layers, then the death mask above every one of them.
    function _composeVesselImage(uint8[8] memory t) private view returns (string memory) {
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 cat; cat < 8; ++cat) {
            if (t[cat] == 0xFF) continue;
            svg = bytes.concat(svg, _layerSvg((uint16(cat) << 8) | uint16(t[cat])));
        }
        svg = bytes.concat(svg, _layerSvg(BC_MEMENTO)); // the mask, on top of everything
        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    function _wrapWithMask(bytes memory inner) private view returns (string memory) {
        bytes memory svg = bytes.concat(
            bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">'),
            inner,
            _layerSvg(BC_MEMENTO),
            bytes("</svg>")
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// A union carries no era and no reaper marks: it was never freed, and it
    /// never burned anything. It carries what it IS.
    function _vesselAttributes(uint256 tokenId) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '[{"trait_type":"Origin","value":"Pikkazo Canvas #',
                _toString(tokenId),
                '"},{"trait_type":"Status","value":"Memento Mori"}',
                ',{"trait_type":"Mask","value":"Memento Mori"}',
                ',{"trait_type":"Souls United","value":',
                _toString(UNION_SIZE),
                "}]"
            )
        );
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

    /// How many pieces the tide has taken: one per five souls kept, six at most.
    function _depth(uint256 tokenId, uint256 consumed) private view returns (uint256) {
        if (consumed < ASCEND_AT) return 0;
        uint256 kept = _soulsBehind(tokenId);
        uint256 d = kept / SOULS_PER_PIECE;
        return d > DROWN_PIECES ? DROWN_PIECES : d;
    }

    /// The order this token drowns in. The hair is always first; the rest is
    /// fixed per token, so no two reapers sink the same way. Returns the slot
    /// codes 0=background 1=base 3=head 4=mouth 6=nose 8=fx.
    function _drownOrder(uint256 tokenId) private pure returns (uint8[6] memory order) {
        order[0] = 3; // the hair, always first
        uint8[5] memory rest = [0, 1, 4, 6, 8];
        uint256 seed = uint256(keccak256(abi.encode(tokenId, "cubistsouls.tide")));
        for (uint256 i = 5; i > 0; --i) {
            uint256 j = seed % i;
            seed /= 7;
            order[6 - i] = rest[j];
            rest[j] = rest[i - 1];
        }
        return order;
    }

    function _isWet(uint256 tokenId, uint256 depth, uint8 slot) private pure returns (bool) {
        if (depth == 0) return false;
        uint8[6] memory order = _drownOrder(tokenId);
        for (uint256 i; i < depth && i < DROWN_PIECES; ++i) {
            if (order[i] == slot) return true;
        }
        return false;
    }

    function _waterFor(uint8 slot) private pure returns (uint16) {
        if (slot == 0) return W_BACKGROUND;
        if (slot == 1) return W_BASE;
        if (slot == 3) return W_HEAD;
        if (slot == 4) return W_MOUTH;
        if (slot == 6) return W_NOSE;
        return W_FX;
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

    /// The reaper as the tide currently has it. With depth 0 this is byte-for-byte
    /// the V6 composition, so a reaper that keeps nothing is untouched.
    function _composeDrownedImage(uint256 tokenId, uint8[8] memory t, uint256 marks, uint256 depth)
        private
        view
        returns (string memory)
    {
        if (depth == 0) return _composeReaperImage(t, marks);

        bool orange = marks & (uint256(1) << 0) != 0;
        bool flame = marks & (uint256(1) << 1) != 0;
        bool phoenix = marks & (uint256(1) << 2) != 0;
        bool burning = marks & (uint256(1) << 3) != 0;

        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 cat; cat < 8; ++cat) {
            // once the water starts, the clothes are gone
            if (cat == 2) continue;

            if (_isWet(tokenId, depth, uint8(cat))) {
                svg = bytes.concat(svg, _layerSvg(_waterFor(uint8(cat))));
                continue;
            }

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

        // the FX slot: the tide's own, or the phoenix while it still burns
        if (_isWet(tokenId, depth, 8)) svg = bytes.concat(svg, _layerSvg(W_FX));
        else if (phoenix) svg = bytes.concat(svg, _layerSvg(BC_PHOENIX));

        svg = bytes.concat(svg, bytes("</svg>"));
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// @notice How deep the tide has taken this reaper (0..6), and how many souls
    ///         it keeps. Public so the museum's web can mirror the art exactly.
    function tide(uint256 tokenId) external view returns (uint256 depth, uint256 kept) {
        kept = _soulsBehind(tokenId);
        (uint256 consumed,) = _reaperState(tokenId);
        depth = _depth(tokenId, consumed);
    }

    /// @notice The order this token drowns in (slot codes), for the web.
    function drownOrder(uint256 tokenId) external pure returns (uint8[6] memory) {
        return _drownOrder(tokenId);
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

        // What a buyer needs to see before bidding: this travels with the sale.
        if (consumed >= ASCEND_AT) {
            uint256 kept = _soulsBehind(tokenId);
            if (kept > 0) {
                attrs = abi.encodePacked(
                    attrs, ',{"trait_type":"Souls Behind","value":', _toString(kept), "}"
                );
                uint256 d = _depth(tokenId, consumed);
                if (d > 0) {
                    attrs = abi.encodePacked(
                        attrs,
                        ',{"trait_type":"Tide","value":',
                        _toString(d),
                        '},{"trait_type":"State","value":"',
                        d >= DROWN_PIECES ? "Drowned" : "Drowning",
                        '"}'
                    );
                }
            }
        }

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

    // ---------------------------------------------------- what a reaper carries

    /// @notice How many tokens stand behind a reaper. Public so the museum (and
    ///         anyone else) can read it without decoding metadata.
    function soulsBehind(uint256 reaperId) external view returns (uint256) {
        return _soulsBehind(reaperId);
    }

    /// How many tokens sit in this reaper's vault. Fail-open to 0: a missing
    /// registry or an unreachable diamond must never break tokenURI.
    function _soulsBehind(uint256 reaperId) private view returns (uint256) {
        if (REGISTRY.code.length == 0 || diamond.code.length == 0) return 0;
        try IRegistryReads(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, diamond, reaperId) returns (
            address vault
        ) {
            if (vault == address(0) || vault.code.length == 0) return 0;
            try IKeptReads(diamond).balanceOf(vault) returns (uint256 n) {
                return n;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
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
