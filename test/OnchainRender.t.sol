// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV3} from "../src/onchain/SoulRendererV3.sol";
import {Base64} from "../src/onchain/Base64.sol";
import {SvgManifest} from "../script/SvgManifest.sol";
import {SvgStrip} from "../script/SvgStrip.sol";

/// Minimal diamond stand-in exposing cohortOf but NOT equippedTraits: a call to
/// the missing selector reverts, exercising the renderer's equip try/catch.
contract MockCohort {
    uint8 public c;

    constructor(uint8 c_) {
        c = c_;
    }

    function cohortOf(uint256) external view returns (uint8) {
        return c;
    }
}

/// Diamond stand-in with BOTH cohortOf and the future equippedTraits selector.
contract MockDiamondFull {
    uint8 public cohort;
    uint16[] internal eq;

    constructor(uint8 cohort_, uint16[] memory eq_) {
        cohort = cohort_;
        eq = eq_;
    }

    function cohortOf(uint256) external view returns (uint8) {
        return cohort;
    }

    function equippedTraits(uint256) external view returns (uint16[] memory) {
        return eq;
    }
}

/// @title OnchainRenderTest - unit + real-data coverage for SvgStore + RendererV3
contract OnchainRenderTest is Test {
    // ===================================================================== units

    function test_Strip_SimpleDocument() public pure {
        bytes memory doc = bytes('<svg xmlns="x" id="a" viewBox="0 0 768 768">INNER-CONTENT</svg>');
        assertEq(string(SvgStrip.inner(doc)), "INNER-CONTENT");
    }

    function test_Strip_WithXmlDeclaration() public pure {
        bytes memory doc = bytes('<?xml version="1.0"?><svg id="b"><path/></svg>');
        assertEq(string(SvgStrip.inner(doc)), "<path/>");
    }

    function test_Store_TraitRoundTrip() public {
        SvgStore store = new SvgStore();
        store.setTrait(0x0102, "Emerald Tiles", bytes("<rect x='1'/>"));

        assertTrue(store.traitExists(0x0102));
        assertEq(store.traitName(0x0102), "Emerald Tiles");
        assertEq(store.traitPointerCount(0x0102), 1);
        assertEq(string(store.traitSvg(0x0102)), "<rect x='1'/>");
    }

    function test_Store_TraitMultiPointer() public {
        SvgStore store = new SvgStore();
        // > 24575 bytes forces at least 2 SSTORE2 pointers.
        uint256 n = 30_000;
        bytes memory big = new bytes(n);
        for (uint256 i; i < n; ++i) {
            big[i] = bytes1(uint8(65 + (i % 26)));
        }
        store.setTrait(0x0500, "Big", big);
        assertGe(store.traitPointerCount(0x0500), 2);
        assertEq(store.traitSvg(0x0500), big);
    }

    function test_Store_RejectsDuplicate() public {
        SvgStore store = new SvgStore();
        store.setTrait(0x0001, "a", bytes("x"));
        vm.expectRevert(SvgStore.AlreadyStored.selector);
        store.setTrait(0x0001, "a", bytes("y"));
    }

    function test_Store_OnlyOwner() public {
        SvgStore store = new SvgStore();
        vm.prank(address(0xBEEF));
        vm.expectRevert(SvgStore.NotOwner.selector);
        store.setTrait(0x0001, "a", bytes("x"));
    }

    function test_Store_SealFreezesWrites() public {
        SvgStore store = new SvgStore();
        store.seal();
        assertTrue(store.frozen());
        vm.expectRevert(SvgStore.IsSealed.selector);
        store.setTrait(0x0001, "a", bytes("x"));
    }

    function test_Store_TokenChunkOrderAndRead() public {
        SvgStore store = new SvgStore();
        uint256 chunkBytes = store.TOKENS_PER_CHUNK() * 8;

        // out-of-order rejected
        bytes memory data = new bytes(chunkBytes);
        vm.expectRevert(SvgStore.BadChunkIndex.selector);
        store.setTokenTraitsChunk(1, data);

        // wrong length rejected
        vm.expectRevert(SvgStore.BadChunkLength.selector);
        store.setTokenTraitsChunk(0, new bytes(chunkBytes - 1));

        // token 3 gets 8 distinct bytes
        for (uint256 i; i < 8; ++i) {
            data[2 * 8 + i] = bytes1(uint8(i + 1)); // token 3 -> index 2
        }
        store.setTokenTraitsChunk(0, data);

        uint8[8] memory t = store.traitsOf(3);
        for (uint256 i; i < 8; ++i) {
            assertEq(t[i], uint8(i + 1));
        }
    }

    function test_Store_TraitsOf_UnuploadedReturnsFF() public {
        SvgStore store = new SvgStore();
        uint8[8] memory t = store.traitsOf(1);
        for (uint256 i; i < 8; ++i) assertEq(t[i], 0xFF);
        // out of range
        uint8[8] memory z = store.traitsOf(0);
        for (uint256 i; i < 8; ++i) assertEq(z[i], 0xFF);
    }

    // ============================================================ real data load

    SvgStore internal realStore;
    SoulRendererV3 internal renderer;
    MockCohort internal cohort;

    function _loadReal() internal {
        realStore = new SvgStore();

        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        for (uint256 i; i < ids.length; ++i) {
            bytes memory inner = SvgStrip.inner(bytes(vm.readFile(paths[i])));
            realStore.setTrait(ids[i], names[i], inner);
        }

        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        for (uint256 i; i < cats.length; ++i) {
            realStore.setCategoryLabel(cats[i], labels[i]);
        }

        (string memory apath, string memory aname) = SvgManifest.adrian();
        realStore.setOneOfOne(0, aname, SvgStrip.inner(bytes(vm.readFile(apath))));

        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        uint256 chunkBytes = realStore.TOKENS_PER_CHUNK() * 8;
        for (uint256 c; c < table.length / chunkBytes; ++c) {
            bytes memory data = new bytes(chunkBytes);
            for (uint256 j; j < chunkBytes; ++j) data[j] = table[c * chunkBytes + j];
            realStore.setTokenTraitsChunk(c, data);
        }

        cohort = new MockCohort(2); // "Tier 1"
        renderer = new SoulRendererV3(address(cohort), address(realStore));
    }

    function test_Real_StripIsCorrect() public view {
        (, string[] memory paths,) = SvgManifest.all();
        bytes memory doc = bytes(vm.readFile(paths[0]));
        bytes memory inner = SvgStrip.inner(doc);
        assertGt(inner.length, 0);
        assertLt(inner.length, doc.length);
        // stripped content must contain neither the opening nor closing root tag
        assertFalse(_contains(inner, bytes("<svg")));
        assertFalse(_contains(inner, bytes("</svg>")));
    }

    function test_Real_TokenURI136_ComposesEightLayers() public {
        _loadReal();

        // token 136 = [1,16,14,7,5,5,0,9] over z-order cats 0..7, all present.
        uint8[8] memory expOpt = [uint8(1), 16, 14, 7, 5, 5, 0, 9];
        string[8] memory expLabel = [
            "Emerald Tiles",
            "Sun Burn",
            "White Hoodie",
            "Punk Never Die",
            "Diva",
            "Colony",
            "Amethyst Block",
            "Gaze"
        ];

        string memory uri = renderer.tokenURI(136);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));

        // decode the JSON and check structure + attributes
        string memory json = string(_b64decode(_after(uri, "base64,")));
        assertTrue(_startsWith(json, '{"name":"Cubist Soul #136"'));
        assertTrue(_contains(bytes(json), bytes('"image":"data:image/svg+xml;base64,')));
        assertTrue(_contains(bytes(json), bytes('"trait_type":"Cohort","value":"Tier 1"')));
        for (uint256 i; i < 8; ++i) {
            assertTrue(
                _contains(bytes(json), bytes(string.concat('"value":"', expLabel[i], '"'))),
                expLabel[i]
            );
        }

        // Rebuild the exact expected composed SVG and confirm it is the image.
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768">');
        for (uint256 cat; cat < 8; ++cat) {
            uint16 traitId = (uint16(cat) << 8) | uint16(expOpt[cat]);
            svg = bytes.concat(svg, realStore.traitSvg(traitId));
        }
        svg = bytes.concat(svg, bytes("</svg>"));
        string memory expectedImage = string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
        assertTrue(_contains(bytes(json), bytes(expectedImage)), "image mismatch");
    }

    function test_Real_TokenURI_NeverReverts() public {
        _loadReal();

        // id 1: composed on-chain
        string memory u1 = renderer.tokenURI(1);
        assertTrue(_startsWith(u1, "data:application/json;base64,"));

        // id 90: honorarium raster (0xFF x8) -> off-chain fallback, same as V2
        string memory u90 = renderer.tokenURI(90);
        assertEq(u90, "https://cubistsouls.vercel.app/api/meta?id=90");

        // id 10000: composed on-chain
        string memory u10000 = renderer.tokenURI(10000);
        assertTrue(_startsWith(u10000, "data:application/json;base64,"));
    }

    function test_Real_ContractURI() public {
        _loadReal();
        assertEq(renderer.contractURI(), "https://cubistsouls.vercel.app/api/collection");
    }

    function test_Real_CohortOmittedWhenDiamondCodeless() public {
        _loadReal();
        // renderer pointed at a codeless "diamond": no Cohort attr, no revert.
        SoulRendererV3 r2 = new SoulRendererV3(address(0xDEAD), address(realStore));
        string memory json = string(_b64decode(_after(r2.tokenURI(136), "base64,")));
        assertFalse(_contains(bytes(json), bytes('"trait_type":"Cohort"')));
    }

    // ========================================================= granular sealing

    function test_Store_SealTable_FreezesOnlyTable() public {
        SvgStore store = new SvgStore();
        store.sealTable();
        assertTrue(store.tokenTableFrozen());
        assertFalse(store.frozen());

        // table writes blocked...
        bytes memory chunk = new bytes(store.TOKENS_PER_CHUNK() * 8);
        vm.expectRevert(SvgStore.TableIsSealed.selector);
        store.setTokenTraitsChunk(0, chunk);

        // ...but new traits and categories still allowed (future drops).
        store.setCategoryLabel(9, "Frame");
        store.setTrait(0x0900, "Golden Frame", bytes("<rect/>"));
        assertTrue(store.traitExists(0x0900));
        assertEq(store.categoryLabel(9), "Frame");
    }

    function test_Store_Enumeration() public {
        SvgStore store = new SvgStore();
        assertEq(store.nextOption(8), 0);
        store.setTrait(0x0800, "Burning Soul", bytes("a"));
        store.setTrait(0x0801, "Second", bytes("b"));
        assertEq(store.categoryTraitCount(8), 2);
        assertEq(store.categoryTraitAt(8, 0), 0x0800);
        assertEq(store.categoryTraitAt(8, 1), 0x0801);
        assertEq(store.nextOption(8), 2); // next free opt in cat 8
    }

    function test_Store_CategoryLabel_WriteOnce() public {
        SvgStore store = new SvgStore();
        store.setCategoryLabel(0, "Art Background");
        assertEq(store.categoryLabel(0), "Art Background");
        vm.expectRevert(SvgStore.AlreadyStored.selector);
        store.setCategoryLabel(0, "Something Else");
    }

    // ================================================== evolvable renderer paths

    function test_Real_CategoryLabel_FromStoreWithFallback() public {
        _loadReal();
        // store-provided label used (equals the hardcoded one here)
        string memory json = string(_b64decode(_after(renderer.tokenURI(136), "base64,")));
        assertTrue(_contains(bytes(json), bytes('"trait_type":"Art Background"')));

        // fresh store with NO labels -> renderer falls back to hardcoded 0-7.
        SvgStore bare = new SvgStore();
        bare.setTrait(0x0000, "Color Block", bytes("<rect/>"));
        SoulRendererV3 r = new SoulRendererV3(address(cohort), address(bare));
        bytes memory svg = _b64decode(_after(r.composeSvg(_ids(0x0000)), "base64,"));
        assertTrue(_contains(svg, bytes("<rect/>")));
    }

    function test_Real_EquippedTraits_RenderedOnTop() public {
        _loadReal();

        // A diamond that reports one equipped trait (burn-cube "Burning Soul").
        uint16 equipId = 0x0800; // cat 8, opt 0
        MockDiamondFull d = new MockDiamondFull(2, _ids(equipId));
        SoulRendererV3 r = new SoulRendererV3(address(d), address(realStore));

        string memory json = string(_b64decode(_after(r.tokenURI(136), "base64,")));
        // equipped attribute present: cat 8 label "Burn Cube" + its name
        assertTrue(_contains(bytes(json), bytes('"trait_type":"Burn Cube"')));
        assertTrue(_contains(bytes(json), bytes('"value":"Burning Soul"')));

        // and its SVG fragment is layered into the image
        bytes memory frag = realStore.traitSvg(equipId);
        string memory equippedImg = _imageField(json);
        bytes memory decoded = _b64decode(_after(equippedImg, "base64,"));
        assertTrue(_contains(decoded, frag), "equipped fragment missing from svg");
    }

    function test_Real_EquipTryCatch_NoSelector_NoRevert() public {
        _loadReal();
        // MockCohort has NO equippedTraits selector -> call reverts -> catch ->
        // renders exactly as with no equips, never reverts.
        string memory withMock = string(_b64decode(_after(renderer.tokenURI(136), "base64,")));
        assertFalse(_contains(bytes(withMock), bytes('"trait_type":"Burn Cube"')));
    }

    function test_Real_ComposeSvg_ArbitraryStack() public {
        _loadReal();
        string memory uri = renderer.composeSvg(_ids2(0x0100, 0x0300)); // base opt0 + head opt0
        assertTrue(_startsWith(uri, "data:image/svg+xml;base64,"));
        bytes memory svg = _b64decode(_after(uri, "base64,"));
        assertTrue(_contains(svg, bytes('viewBox="0 0 768 768"')));
        assertTrue(_contains(svg, realStore.traitSvg(0x0100)));
        assertTrue(_contains(svg, realStore.traitSvg(0x0300)));
    }

    function test_Real_NewDrop_AddedTraits_OGUnchanged() public {
        _loadReal();

        // capture OG token 136 BEFORE any new drop
        string memory before = renderer.tokenURI(136);

        // NEW DROP: append a fresh cat-8 option and a brand-new category 9.
        assertEq(realStore.nextOption(8), 4); // 4 burn-cube already loaded
        uint16 newBurn = (uint16(8) << 8) | realStore.nextOption(8); // 0x0804
        realStore.setTrait(newBurn, "Comet Cube", bytes("<circle r='9'/>"));

        realStore.setCategoryLabel(9, "Frame");
        uint16 newFrame = (uint16(9) << 8) | realStore.nextOption(9); // 0x0900
        realStore.setTrait(newFrame, "Golden Frame", bytes("<rect id='f'/>"));

        // composeSvg serves the new traits immediately (no renderer redeploy).
        string memory uri = renderer.composeSvg(_ids2(newBurn, newFrame));
        bytes memory svg = _b64decode(_after(uri, "base64,"));
        assertTrue(_contains(svg, bytes("<circle r='9'/>")));
        assertTrue(_contains(svg, bytes("<rect id='f'/>")));

        // OG token 136 is byte-identical: existing art is immutable.
        assertEq(renderer.tokenURI(136), before, "OG token changed after drop");
    }

    // ==================================================================== helpers

    function _ids(uint16 a) internal pure returns (uint16[] memory out) {
        out = new uint16[](1);
        out[0] = a;
    }

    function _ids2(uint16 a, uint16 b) internal pure returns (uint16[] memory out) {
        out = new uint16[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @dev extract the value of the "image":"..." field from a decoded JSON.
    function _imageField(string memory json) internal pure returns (string memory) {
        string memory tail = _after(json, '"image":"');
        // cut at the closing quote
        bytes memory b = bytes(tail);
        uint256 end;
        for (; end < b.length; ++end) {
            if (b[end] == '"') break;
        }
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) out[i] = b[i];
        return string(out);
    }


    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        if (b.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    /// @dev returns the substring of `s` after the first occurrence of `marker`.
    function _after(string memory s, string memory marker) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory m = bytes(marker);
        for (uint256 i; i + m.length <= b.length; ++i) {
            bool hit = true;
            for (uint256 j; j < m.length; ++j) {
                if (b[i + j] != m[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                uint256 start = i + m.length;
                bytes memory out = new bytes(b.length - start);
                for (uint256 k; k < out.length; ++k) out[k] = b[start + k];
                return string(out);
            }
        }
        return "";
    }

    /// @dev standard base64 decode (assumes valid, padded input).
    function _b64decode(string memory data) internal pure returns (bytes memory) {
        bytes memory b = bytes(data);
        if (b.length == 0) return "";

        // build reverse lookup
        bytes memory table = new bytes(128);
        bytes memory alphabet = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        for (uint256 i; i < alphabet.length; ++i) {
            table[uint8(alphabet[i])] = bytes1(uint8(i));
        }

        uint256 pad;
        if (b[b.length - 1] == "=") pad++;
        if (b[b.length - 2] == "=") pad++;

        uint256 outLen = (b.length / 4) * 3 - pad;
        bytes memory out = new bytes(outLen);

        uint256 o;
        for (uint256 i; i < b.length; i += 4) {
            uint256 n = (uint256(uint8(table[uint8(b[i])])) << 18)
                | (uint256(uint8(table[uint8(b[i + 1])])) << 12)
                | (uint256(uint8(table[uint8(b[i + 2])])) << 6)
                | uint256(uint8(table[uint8(b[i + 3])]));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 16));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 8));
            if (o < outLen) out[o++] = bytes1(uint8(n));
        }
        return out;
    }
}
