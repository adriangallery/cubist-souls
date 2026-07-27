// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";
import {SoulRendererV4_1} from "../src/onchain/SoulRendererV4_1.sol";
import {TraitOverride} from "../src/onchain/TraitOverride.sol";
import {SvgManifest} from "../script/SvgManifest.sol";
import {RevisionManifest} from "../script/RevisionManifest.sol";
import {SvgStrip} from "../script/SvgStrip.sol";

import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";

/// @title OnchainRenderV4_1Test - proves SoulRendererV4_1 is (a) BYTE-PARITY with
///         SoulRendererV4 when the override table is empty, and (b) swaps ONLY the
///         image layer (attributes byte-identical) when overrides are active.
contract OnchainRenderV4_1Test is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");

    SvgStore store;
    SoulRendererV4 v4;      // reference
    SoulRendererV4_1 v41;   // subject
    TraitOverride ovr;

    uint256 constant OG_136 = 136;   // uses White Hoodie (clothes) + Colony (left eye): 2 revisions
    uint256 constant REAPER = 8777;
    uint256 constant LEGACY_1 = 1;
    uint256 constant ERA_2 = 2;
    uint256 constant EMPTY_90 = 90;

    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    address treasury = makeAddr("treasury");

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _addReaper();
        _replaceReaperV2();

        pikkazo.mint(holder, LEGACY_1);
        pikkazo.mint(holder, REAPER);
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        ConvertFacet(diamond).convert(_arr2(LEGACY_1, REAPER));
        vm.stopPrank();

        _replaceReaperV3();
        _addConvertV2(uint64(block.timestamp));

        pikkazo.mint(holder, ERA_2);
        vm.prank(holder);
        ConvertFacetV2(diamond).convert(_arr1(ERA_2));

        store = _loadStore();          // 149 originals
        _uploadRevisions(store);       // + 21 v2 traits (same names, fresh ids)

        ovr = new TraitOverride();     // EMPTY by default
        v4 = new SoulRendererV4(diamond, address(store));
        v41 = new SoulRendererV4_1(diamond, address(store), address(ovr));
    }

    // ==================================================== A) byte-parity (empty override)

    function test_Parity_EmptyOverride_136() public view {
        assertEq(v41.tokenURI(OG_136), v4.tokenURI(OG_136));
    }

    function test_Parity_EmptyOverride_LegacyEraEmpty() public view {
        assertEq(v41.tokenURI(LEGACY_1), v4.tokenURI(LEGACY_1));
        assertEq(v41.tokenURI(ERA_2), v4.tokenURI(ERA_2));
        assertEq(v41.tokenURI(EMPTY_90), v4.tokenURI(EMPTY_90)); // both delegate to api
    }

    function test_Parity_EmptyOverride_ReaperAllStages() public {
        _feed(REAPER, 6);
        assertEq(v41.tokenURI(REAPER), v4.tokenURI(REAPER), "consumed 6");
        _feed(REAPER, 6); // 12
        assertEq(v41.tokenURI(REAPER), v4.tokenURI(REAPER), "consumed 12");
        _feed(REAPER, 6); // 18
        assertEq(v41.tokenURI(REAPER), v4.tokenURI(REAPER), "consumed 18");
        _feed(REAPER, 12); // 30
        assertEq(v41.tokenURI(REAPER), v4.tokenURI(REAPER), "consumed 30");
    }

    function test_Parity_EmptyOverride_ContractURIAndCompose() public view {
        assertEq(v41.contractURI(), v4.contractURI());
        uint16[] memory ids = new uint16[](3);
        ids[0] = 0x0004; // star-blue (a revised original)
        ids[1] = 0x020E; // white-hoodie
        ids[2] = 0x0505; // colony
        assertEq(v41.composeSvg(ids), v4.composeSvg(ids));
    }

    // Every token in the harness sample: byte-equal with empty override. This is the
    // transitive proof that all 17 V4 assertions hold identically on V4_1.
    function test_Parity_EmptyOverride_FullSample() public view {
        uint256[35] memory ids = [
            uint256(2), 3, 4, 5, 90, 99, 163, 250, 294, 518, 600, 777, 1023, 1404, 1727,
            1994, 2391, 2855, 3206, 3712, 4269, 4942, 5000, 5728, 6449, 6841, 7000, 7316,
            7668, 8496, 8777, 9110, 9976, 9999, 10000
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(v41.tokenURI(ids[i]), v4.tokenURI(ids[i]));
        }
    }

    // ==================================================== B) override active

    function _activateOverrides() internal {
        (uint16[] memory from, uint16[] memory to,,) = RevisionManifest.all();
        vm.prank(ovr.owner());
        ovr.setOverrides(from, to);
    }

    function test_Override_ImageSwaps_AttributesIdentical_136() public {
        // Snapshot attributes + image BEFORE overrides.
        string memory jsonBefore = _json(v41.tokenURI(OG_136));
        string memory attrsBefore = _attrsSlice(jsonBefore);
        bytes memory imgBefore = _b64(_after(_imageField(jsonBefore), "base64,"));

        _activateOverrides();

        string memory jsonAfter = _json(v41.tokenURI(OG_136));
        string memory attrsAfter = _attrsSlice(jsonAfter);
        bytes memory imgAfter = _b64(_after(_imageField(jsonAfter), "base64,"));

        // ATTRIBUTES byte-identical (names pinned to original id).
        assertEq(attrsAfter, attrsBefore, "attributes must be byte-identical");
        // Also equals V4's attributes (double check vs the reference renderer).
        assertEq(attrsAfter, _attrsSlice(_json(v4.tokenURI(OG_136))), "attrs == V4");

        // IMAGE changed: v1 white-hoodie/colony fragments gone, v2 present.
        assertTrue(_neq(imgAfter, imgBefore), "image must change");
        assertTrue(_contains(imgAfter, store.traitSvg(0x0211)), "white-hoodie v2 (0x0211) in image");
        assertTrue(_contains(imgAfter, store.traitSvg(0x0514)), "colony v2 (0x0514) in image");
        assertFalse(_contains(imgAfter, store.traitSvg(0x020E)), "white-hoodie v1 gone");
        assertFalse(_contains(imgAfter, store.traitSvg(0x0505)), "colony v1 gone");
        // Non-revised layer (head Punk Never Die 0x0307) untouched.
        assertTrue(_contains(imgAfter, store.traitSvg(0x0307)), "head v1 intact");
    }

    function test_Override_ReaperMarksStillCorrect() public {
        _feed(REAPER, 30);
        _activateOverrides();
        string memory json = _json(v41.tokenURI(REAPER));
        _assertStarts(json, '{"name":"Soul Reaper #8777"');
        _assertHas(json, '{"trait_type":"Reaper Mark","value":"Burning Soul"}');
        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        // Marks (burn cubes) are not overridden -> still present in the image.
        assertTrue(_contains(svg, store.traitSvg(0x0802)), "orange bc");
        assertTrue(_contains(svg, store.traitSvg(0x0801)), "flame bc");
        assertTrue(_contains(svg, store.traitSvg(0x0800)), "burning bc");
        assertTrue(_contains(svg, store.traitSvg(0x0803)), "phoenix fx");
    }

    function test_Override_ClearRestores() public {
        string memory before = v41.tokenURI(OG_136);
        _activateOverrides();
        assertTrue(
            keccak256(bytes(v41.tokenURI(OG_136))) != keccak256(bytes(before)),
            "changed while active"
        );
        // clear both #136 revisions
        vm.startPrank(ovr.owner());
        ovr.clearOverride(0x020E); // white-hoodie
        ovr.clearOverride(0x0505); // colony
        vm.stopPrank();
        assertEq(v41.tokenURI(OG_136), before, "restored after clear");
    }

    function test_Override_ResolveIdentityAndTable() public {
        _activateOverrides();
        assertEq(ovr.resolve(0x020E), 0x0211); // white-hoodie -> v2
        assertEq(ovr.resolve(0x0505), 0x0514); // colony -> v2
        assertEq(ovr.resolve(0x0307), 0x0307); // non-revised -> identity
        assertEq(ovr.resolve(0x0000), 0x0000); // traitId 0 valid, no override -> identity
        assertTrue(ovr.hasOverride(0x020E));
        assertFalse(ovr.hasOverride(0x0307));
    }

    function test_Override_OnlyOwner() public {
        (uint16[] memory from, uint16[] memory to,,) = RevisionManifest.all();
        vm.expectRevert(TraitOverride.NotOwner.selector);
        vm.prank(holder);
        ovr.setOverrides(from, to);
    }

    function test_Override_RejectsSelfLoop() public {
        uint16[] memory f = new uint16[](1);
        uint16[] memory t = new uint16[](1);
        f[0] = 0x020E;
        t[0] = 0x020E;
        address o = ovr.owner();
        vm.prank(o);
        vm.expectRevert(TraitOverride.SelfOverride.selector);
        ovr.setOverrides(f, t);
    }

    function test_Override_NeverRevert_CodelessOverride() public {
        // A V4_1 wired to a codeless override behaves exactly like V4.
        SoulRendererV4_1 r = new SoulRendererV4_1(diamond, address(store), address(0xDEAD));
        assertEq(r.tokenURI(OG_136), v4.tokenURI(OG_136));
    }

    // Definitive mapping is exactly the 21 expected pairs.
    function test_Mapping_Definitive() public {
        _activateOverrides();
        (uint16[] memory from, uint16[] memory to,,) = RevisionManifest.all();
        assertEq(from.length, 21);
        for (uint256 i; i < from.length; ++i) {
            assertEq(ovr.resolve(from[i]), to[i]);
            // to lives in the same category as from
            assertEq(uint8(to[i] >> 8), uint8(from[i] >> 8));
            // v2 trait actually uploaded, and carries the SAME name
            assertTrue(store.traitExists(to[i]), "v2 uploaded");
            assertEq(store.traitName(to[i]), store.traitName(from[i]), "name preserved");
        }
    }

    // ================================================================== wiring

    function _uploadRevisions(SvgStore s) internal {
        (, uint16[] memory to, string[] memory names, string[] memory paths) =
            RevisionManifest.all();
        for (uint256 i; i < to.length; ++i) {
            s.setTrait(to[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        }
    }

    function _addReaper() internal {
        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        bytes4[] memory s = new bytes4[](10);
        s[0] = ReaperFacet.offer.selector;
        s[1] = ReaperFacet.forgeMark.selector;
        s[2] = ReaperFacet.soulsConsumed.selector;
        s[3] = ReaperFacet.marksOf.selector;
        s[4] = ReaperFacet.isReaper.selector;
        s[5] = ReaperFacet.markPrice.selector;
        s[6] = ReaperFacet.setMarkPrice.selector;
        s[7] = ReaperFacet.setReaperPaused.selector;
        s[8] = ReaperFacet.reaperPaused.selector;
        s[9] = ReaperFacet.isCanvasConsumed.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Add, s);
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(initC), abi.encodeCall(ReaperInit.init, ()));
    }

    function _replaceReaperV2() internal {
        ReaperFacetV2 facet = new ReaperFacetV2();
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacet.offer.selector;
        rep[1] = ReaperFacet.forgeMark.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Replace, rep);
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _replaceReaperV3() internal {
        ReaperFacetV3 facet = new ReaperFacetV3();
        bytes4[] memory rep = new bytes4[](2);
        rep[0] = ReaperFacetV3.marksOf.selector;
        rep[1] = ReaperFacetV3.forgeMark.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Replace, rep);
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _addConvertV2(uint64 start) internal {
        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector;
        bytes4[] memory add = new bytes4[](10);
        add[0] = ConvertFacetV2.priceNow.selector;
        add[1] = ConvertFacetV2.freedAt.selector;
        add[2] = ConvertFacetV2.cohortOf.selector;
        add[3] = ConvertFacetV2.saleStart.selector;
        add[4] = ConvertFacetV2.pricing.selector;
        add[5] = ConvertFacetV2.setPricing.selector;
        add[6] = ConvertFacetV2.treasury.selector;
        add[7] = ConvertFacetV2.setTreasury.selector;
        add[8] = bytes4(keccak256("withdraw()"));
        add[9] = bytes4(keccak256("withdraw(address)"));
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(address(v2), IDiamondCut.FacetCutAction.Replace, rep);
        cuts[1] = IDiamondCut.FacetCut(address(v2), IDiamondCut.FacetCutAction.Add, add);
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(
            cuts,
            address(initC),
            abi.encodeCall(
                ConvertV2Init.init,
                (start, B1, B2, B3, 0.0001 ether, 0.0003 ether, 0.0005 ether, treasury)
            )
        );
    }

    uint256 private _cursor = 100000;

    function _feed(uint256 soulId, uint256 n) internal {
        while (n > 0) {
            uint256 chunk = n > 50 ? 50 : n;
            uint256[] memory ids = new uint256[](chunk);
            for (uint256 i; i < chunk; ++i) {
                ids[i] = _cursor + i;
                pikkazo.mint(holder, ids[i]);
            }
            _cursor += chunk;
            vm.prank(holder);
            ReaperFacet(diamond).offer(soulId, ids);
            n -= chunk;
        }
    }

    function _loadStore() internal returns (SvgStore s) {
        s = new SvgStore();
        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        for (uint256 i; i < ids.length; ++i) {
            s.setTrait(ids[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        }
        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        for (uint256 i; i < cats.length; ++i) {
            s.setCategoryLabel(cats[i], labels[i]);
        }
        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        uint256 chunkBytes = s.TOKENS_PER_CHUNK() * 8;
        for (uint256 c; c < table.length / chunkBytes; ++c) {
            bytes memory data = new bytes(chunkBytes);
            for (uint256 j; j < chunkBytes; ++j) data[j] = table[c * chunkBytes + j];
            s.setTokenTraitsChunk(c, data);
        }
    }

    // ================================================================ helpers

    function _arr1(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _json(string memory uri) internal pure returns (string memory) {
        if (_startsWith(uri, "data:application/json;base64,")) {
            return string(_b64(_after(uri, "base64,")));
        }
        return uri;
    }

    function _attrsSlice(string memory json) internal pure returns (string memory) {
        return _after(json, '"attributes":');
    }

    function _imageField(string memory json) internal pure returns (string memory) {
        string memory tail = _after(json, '"image":"');
        bytes memory b = bytes(tail);
        uint256 end;
        for (; end < b.length; ++end) {
            if (b[end] == '"') break;
        }
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) out[i] = b[i];
        return string(out);
    }

    function _assertHas(string memory json, string memory needle) internal pure {
        assertTrue(_contains(bytes(json), bytes(needle)), needle);
    }

    function _assertStarts(string memory s, string memory p) internal pure {
        assertTrue(_startsWith(s, p), p);
    }

    function _neq(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) != keccak256(b);
    }

    function _indexOfBytes(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        if (needle.length == 0 || needle.length > hay.length) return type(uint256).max;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return i;
        }
        return type(uint256).max;
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
        return _indexOfBytes(hay, needle) != type(uint256).max;
    }

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

    function _b64(string memory data) internal pure returns (bytes memory) {
        bytes memory b = bytes(data);
        if (b.length == 0) return "";
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
