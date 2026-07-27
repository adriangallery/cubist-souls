// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";
import {OGFrozen} from "../src/onchain/OGFrozen.sol";
import {Base64} from "../src/onchain/Base64.sol";
import {SvgManifest} from "../script/SvgManifest.sol";
import {SvgStrip} from "../script/SvgStrip.sol";

import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperFacetV2} from "../src/facets/ReaperFacetV2.sol";
import {ReaperFacetV3} from "../src/facets/ReaperFacetV3.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";

/// @title OnchainRenderV4Test - full spec coverage for the reaper-aware V4 renderer.
/// @notice Forges reaper/cohort state on a diamond built from the REAL facets
///         (ConvertFacet(V2) + ReaperFacet(V2/V3)), loads the REAL SvgStore data,
///         and asserts the V4 output is parity with the canonical api/meta:
///         reaper rename/marks/substitution image, OG-list vs live-era cohorts,
///         canonical Mouth-before-Head attribute order, numeric Souls Consumed,
///         one-of-one precedence, off-chain fallback, and never-revert.
contract OnchainRenderV4Test is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");

    SvgStore store;
    SoulRendererV4 renderer;

    // OG (frozen-list) souls
    uint256 constant OG_136 = 136;
    uint256 constant REAPER = 8777; // OG + real reaper; minted V1 so freedAt==0 (OG guard passes)
    // non-frozen souls
    uint256 constant LEGACY_1 = 1; // V1-minted, freedAt==0, NOT in OG list -> Cohort omitted
    uint256 constant ERA_2 = 2; // V2-minted -> cohortOf 1..4 -> "Era I".."Era IV"
    uint256 constant EMPTY_90 = 90; // honorarium: 0xFF x8 -> off-chain fallback

    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    address treasury = makeAddr("treasury");

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _addReaper(); // ReaperFacet (10 sels) + ReaperInit (markPrices 6/12/18/30)
        _replaceReaperV2(); // offer/forgeMark -> V2 (OG guard)

        // Mint LEGACY souls via V1 convert (freedAt stays 0) BEFORE the V2 cut.
        pikkazo.mint(holder, LEGACY_1);
        pikkazo.mint(holder, REAPER);
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        ConvertFacet(diamond).convert(_arr2(LEGACY_1, REAPER));
        vm.stopPrank();

        _replaceReaperV3(); // marksOf(derived) + forgeMark(deprecated) -> V3
        _addConvertV2(uint64(block.timestamp)); // cohortOf + timed pricing

        // Mint an era soul via V2 convert (freedAt != 0 -> cohortOf 1 == "Era I").
        pikkazo.mint(holder, ERA_2);
        vm.prank(holder);
        ConvertFacetV2(diamond).convert(_arr1(ERA_2));

        store = _loadStore();
        renderer = new SoulRendererV4(diamond, address(store));
    }

    // =========================================================== OG cohort (B2)

    function test_OGList_DecidesOG_NotCohortZero() public view {
        // 136 is in the frozen list; the test diamond's cohortOf(136) is 0 (never
        // V2-converted). V4 must still label it OG from the list, never from the read.
        assertTrue(OGFrozen.isOG(OG_136));
        string memory json = _json(renderer.tokenURI(OG_136));
        _assertHas(json, '"trait_type":"Cohort","value":"OG"');
        _assertStarts(json, '{"name":"Cubist Soul #136"');
    }

    function test_NonFrozen_CohortZero_OmitsCohort() public view {
        // LEGACY_1: not in the OG list, freedAt==0 -> cohortOf==0. Must OMIT Cohort,
        // never emit "OG" (the exact bug the api/meta OG_FROZEN fix addressed).
        assertFalse(OGFrozen.isOG(LEGACY_1));
        string memory json = _json(renderer.tokenURI(LEGACY_1));
        _assertNotHas(json, '"trait_type":"Cohort"');
    }

    function test_NonFrozen_LiveEra() public view {
        // ERA_2: not frozen, V2-converted at t=saleStart -> cohortOf==1 -> "Era I".
        assertFalse(OGFrozen.isOG(ERA_2));
        assertEq(ConvertFacetV2(diamond).cohortOf(ERA_2), 1);
        string memory json = _json(renderer.tokenURI(ERA_2));
        _assertHas(json, '"trait_type":"Cohort","value":"Era I"');
        _assertNotHas(json, '"value":"OG"');
    }

    function test_OGFrozen_Boundaries() public pure {
        assertTrue(OGFrozen.isOG(99)); // first
        assertTrue(OGFrozen.isOG(9976)); // last
        assertTrue(OGFrozen.isOG(163)); // Mich
        assertTrue(OGFrozen.isOG(8777));
        assertFalse(OGFrozen.isOG(0));
        assertFalse(OGFrozen.isOG(98));
        assertFalse(OGFrozen.isOG(100));
        assertFalse(OGFrozen.isOG(10000));
        assertFalse(OGFrozen.isOG(70000));
    }

    // ====================================================== parity metadata (B4)

    function test_Parity_MetadataShape() public view {
        string memory json = _json(renderer.tokenURI(OG_136));
        // description = exact long lore
        _assertHas(
            json,
            '"description":"Ten thousand cubist portraits were abandoned by their maker.'
        );
        _assertHas(json, "The soul kept its number, and the face it wore in the canvas that held it.");
        // external_url
        _assertHas(json, '"external_url":"https://cubistsouls.com"');
        // Origin + Status
        _assertHas(json, '{"trait_type":"Origin","value":"Pikkazo Canvas #136"}');
        _assertHas(json, '{"trait_type":"Status","value":"Freed"}');
        // on-chain composed image
        _assertHas(json, '"image":"data:image/svg+xml;base64,');
    }

    function test_Parity_TraitValues_Match136() public view {
        // Values must equal the canonical Pikkazo metadata for #136.
        string memory json = _json(renderer.tokenURI(OG_136));
        _assertHas(json, '{"trait_type":"Art Background","value":"Emerald Tiles"}');
        _assertHas(json, '{"trait_type":"Base","value":"Sun Burn"}');
        _assertHas(json, '{"trait_type":"Clothes","value":"White Hoodie"}');
        _assertHas(json, '{"trait_type":"Mouth","value":"Diva"}');
        _assertHas(json, '{"trait_type":"Head","value":"Punk Never Die"}');
        _assertHas(json, '{"trait_type":"Left Eye","value":"Colony"}');
        _assertHas(json, '{"trait_type":"Nose","value":"Amethyst Block"}');
        _assertHas(json, '{"trait_type":"Right Eye","value":"Gaze"}');
    }

    function test_Parity_AttributeOrder_MouthBeforeHead() public view {
        // The canonical order is Mouth BEFORE Head. The image z-order is Head below
        // Mouth. Assert attribute order (this is the audit's Head/Mouth flag).
        string memory json = _json(renderer.tokenURI(OG_136));
        uint256 pMouth = _indexOf(json, '"trait_type":"Mouth"');
        uint256 pHead = _indexOf(json, '"trait_type":"Head"');
        uint256 pAB = _indexOf(json, '"trait_type":"Art Background"');
        uint256 pClothes = _indexOf(json, '"trait_type":"Clothes"');
        uint256 pLeftEye = _indexOf(json, '"trait_type":"Left Eye"');
        assertTrue(pAB < pClothes, "AB before Clothes");
        assertTrue(pClothes < pMouth, "Clothes before Mouth");
        assertTrue(pMouth < pHead, "Mouth BEFORE Head (canonical)");
        assertTrue(pHead < pLeftEye, "Head before Left Eye");
    }

    function test_Image_DrawOrder_HeadBelowMouth() public view {
        // In the composed SVG, the Head fragment must appear BEFORE (below) the
        // Mouth fragment — opposite of the attribute order.
        string memory json = _json(renderer.tokenURI(OG_136));
        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        bytes memory head = store.traitSvg(0x0300 | 7); // 136 head opt 7 (Punk Never Die)
        bytes memory mouth = store.traitSvg(0x0400 | 5); // 136 mouth opt 5 (Diva)
        uint256 iHead = _indexOfBytes(svg, head);
        uint256 iMouth = _indexOfBytes(svg, mouth);
        assertTrue(iHead != type(uint256).max && iMouth != type(uint256).max, "fragments present");
        assertTrue(iHead < iMouth, "Head drawn below Mouth (z-order)");
    }

    // ============================================================= reaper (B1)

    function test_Reaper_Consumed18_MarksAndImage() public {
        _feed(REAPER, 18); // Orange(6) + Flame(12) + Phoenix(18); Burning needs 30
        (uint256 consumed, uint256 marks) = renderer.reaperState(REAPER);
        assertEq(consumed, 18);
        assertEq(marks, 0x7); // bits 0,1,2

        string memory json = _json(renderer.tokenURI(REAPER));
        // not yet ascended
        _assertStarts(json, '{"name":"Cubist Soul #8777"');
        // numeric Souls Consumed (no quotes)
        _assertHas(json, '{"trait_type":"Souls Consumed","value":18}');
        // three marks, api strings
        _assertHas(json, '{"trait_type":"Reaper Mark","value":"Orange"}');
        _assertHas(json, '{"trait_type":"Reaper Mark","value":"Flame Crown"}');
        _assertHas(json, '{"trait_type":"Reaper Mark","value":"Phoenix"}');
        _assertNotHas(json, '"value":"Burning Soul"');

        // image substitutes Orange->AB, Flame->Head, paints Phoenix on top; Base
        // (no Burning mark yet) keeps the original base layer.
        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        assertTrue(_contains(svg, store.traitSvg(0x0802)), "orange bc in image"); // AB substitute
        assertTrue(_contains(svg, store.traitSvg(0x0801)), "flame bc in image"); // head substitute
        assertTrue(_contains(svg, store.traitSvg(0x0803)), "phoenix fx in image");
        assertFalse(_contains(svg, store.traitSvg(0x0800)), "no burning bc yet");
        // original base (cat1 opt10 for 8777) still present
        assertTrue(_contains(svg, store.traitSvg(0x0100 | 10)), "base layer intact");
    }

    function test_Reaper_Consumed30_AscendAndFullSet() public {
        _feed(REAPER, 30);
        (uint256 consumed, uint256 marks) = renderer.reaperState(REAPER);
        assertEq(consumed, 30);
        assertEq(marks, 0xF); // all four bits

        string memory json = _json(renderer.tokenURI(REAPER));
        _assertStarts(json, '{"name":"Soul Reaper #8777"'); // ascended rename
        _assertHas(json, '{"trait_type":"Souls Consumed","value":30}');
        _assertHas(json, '{"trait_type":"Reaper Mark","value":"Burning Soul"}');

        // Trait attributes still show the ORIGINAL head/base (not the marks).
        _assertHas(json, '{"trait_type":"Head","value":"Snapback"}'); // 8777 head opt 11
        _assertHas(json, '{"trait_type":"Base","value":"Ocean Eyes"}'); // 8777 base opt 10

        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        assertTrue(_contains(svg, store.traitSvg(0x0800)), "burning bc substitutes base");
        // original base fragment is now GONE (substituted by burning soul)
        assertFalse(_contains(svg, store.traitSvg(0x0100 | 10)), "base substituted out");
    }

    function test_Reaper_ImageParityWithReaperImg_Order() public {
        // The composed reaper stack order must be: [AB|Orange], [Base|Burning],
        // Clothes, [Head|Flame], Mouth, LEye, Nose, REye, then Phoenix fx.
        _feed(REAPER, 30);
        string memory json = _json(renderer.tokenURI(REAPER));
        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        uint256 iOrange = _indexOfBytes(svg, store.traitSvg(0x0802)); // AB slot
        uint256 iBurning = _indexOfBytes(svg, store.traitSvg(0x0800)); // Base slot
        uint256 iClothes = _indexOfBytes(svg, store.traitSvg(0x0200 | 5)); // 8777 clothes opt5
        uint256 iFlame = _indexOfBytes(svg, store.traitSvg(0x0801)); // Head slot
        uint256 iPhoenix = _indexOfBytes(svg, store.traitSvg(0x0803)); // fx top
        assertTrue(iOrange < iBurning, "AB(Orange) below Base(Burning)");
        assertTrue(iBurning < iClothes, "Base below Clothes");
        assertTrue(iClothes < iFlame, "Clothes below Head(Flame)");
        assertTrue(iFlame < iPhoenix, "Head below Phoenix fx");
    }

    // ==================================================== one-of-one + fallback

    function test_OneOfOne_ImageWins() public {
        // Attach a curated 1/1 to an id that also has a trait row; the 1/1 image
        // must win (extra a). Use LEGACY_1 (has traits).
        vm.prank(store.owner());
        store.setOneOfOne(LEGACY_1, "Special", bytes("<rect id='ooo'/>"));

        string memory json = _json(renderer.tokenURI(LEGACY_1));
        bytes memory svg = _b64(_after(_imageField(json), "base64,"));
        assertTrue(_contains(svg, bytes("<rect id='ooo'/>")), "1/1 image used");
        // no per-trait attributes for a 1/1 (documented gap), but Origin/Status still present
        _assertHas(json, '{"trait_type":"Origin","value":"Pikkazo Canvas #1"}');
        _assertNotHas(json, '"trait_type":"Art Background"');
    }

    function test_Fallback_EmptyToken() public view {
        // 90 = honorarium raster (0xFF x8), no on-chain asset -> off-chain fallback.
        assertEq(renderer.tokenURI(EMPTY_90), "https://cubistsouls.com/api/meta?id=90");
    }

    function test_ContractURI_Parity() public view {
        assertEq(renderer.contractURI(), "https://cubistsouls.com/api/collection");
    }

    // ========================================================= never-revert (b)

    function test_NeverRevert_CodelessStore() public {
        SoulRendererV4 r = new SoulRendererV4(diamond, address(0xDEAD));
        assertEq(r.tokenURI(136), "https://cubistsouls.com/api/meta?id=136");
    }

    function test_NeverRevert_CodelessDiamond() public {
        SoulRendererV4 r = new SoulRendererV4(address(0xBEEF), address(store));
        // Still renders on-chain (store present); OG-list cohort still works,
        // reaper reads fail-open to 0, no revert.
        string memory json = _json(r.tokenURI(OG_136));
        _assertStarts(json, '{"name":"Cubist Soul #136"');
        _assertHas(json, '"trait_type":"Cohort","value":"OG"'); // from embedded list
        _assertNotHas(json, '"trait_type":"Souls Consumed"');
    }

    function test_NeverRevert_ComposeSvg() public {
        uint16[] memory ids = new uint16[](2);
        ids[0] = 0x0100;
        ids[1] = 0x0300;
        string memory uri = renderer.composeSvg(ids);
        _assertStarts(uri, "data:image/svg+xml;base64,");
    }

    // ================================================================== wiring

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

    uint256 private _cursor = 100000; // fresh canvas ids for offerings

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
        return uri; // fallback URL
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

    function _assertNotHas(string memory json, string memory needle) internal pure {
        assertFalse(_contains(bytes(json), bytes(needle)), needle);
    }

    function _assertStarts(string memory s, string memory p) internal pure {
        assertTrue(_startsWith(s, p), p);
    }

    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        return _indexOfBytes(bytes(hay), bytes(needle));
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
