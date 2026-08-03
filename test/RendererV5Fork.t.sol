// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SoulRendererV5} from "../src/onchain/SoulRendererV5.sol";
import {VesselFacet} from "../src/facets/VesselFacet.sol";

interface ISoulsR {
    function ownerOf(uint256) external view returns (address);
    function owner() external view returns (address);
    function tokenURI(uint256) external view returns (string memory);
    function renderer() external view returns (address);
    function soulsConsumed(uint256) external view returns (uint256);
    function isCanvasConsumed(uint256) external view returns (bool);
    function offer(uint256, uint256[] calldata) external;
    function fuse(uint256, uint256[] calldata, string calldata) external payable returns (address);
    function isVesselToken(uint256) external view returns (bool);
    function setRenderer(address) external;
}

interface IPikkazoR {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
    function transferFrom(address, address, uint256) external;
}

interface ISvgStoreR {
    function setTrait(uint16 traitId, string calldata name, bytes calldata inner) external;
    function traitSvg(uint16 traitId) external view returns (bytes memory);
    function owner() external view returns (address);
}

/// Fork test for the Memento Mori renderer against REAL mainnet state.
///
/// The two questions that matter before swapping the renderer of a live
/// collection:
///   1. REGRESSION — is V5 byte-for-byte identical to the LIVE renderer for
///      every ordinary Soul, every reaper, and the OG/era cohorts? (A renderer
///      swap touches all 3k+ tokens; anything but equality is a bug.)
///   2. The union branch — does a freshly fused Memento Mori render with the
///      museum's name, the death mask on top, and none of the soul attributes?
///
///   ETH_RPC=<url> forge test --match-contract RendererV5Fork -vv
contract RendererV5ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;
    address constant STORE = 0x6702016627141350792Dd366885a2Fc794eE46C6;
    address constant OVERRIDE_GUESS = address(0); // read from the live renderer below
    address constant WHALE = 0x4943407105999e3E97EFA2035F5cbC64D72581C6;
    uint256 constant CROWN = 8777; // a real reaper (marks + rename)
    uint16 constant BC_MEMENTO = 0x0804;

    bool forked;
    ISoulsR souls = ISoulsR(DIAMOND);
    SoulRendererV5 v5;
    address live;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        live = souls.renderer();
        // same immutables as the live renderer, so any difference is behavioural
        (, bytes memory sd) = live.staticcall(abi.encodeWithSignature("store()"));
        (, bytes memory od) = live.staticcall(abi.encodeWithSignature("traitOverride()"));
        address storeAddr = abi.decode(sd, (address));
        address overrideAddr = abi.decode(od, (address));
        assertEq(storeAddr, STORE, "store moved?");
        v5 = new SoulRendererV5(DIAMOND, storeAddr, overrideAddr);
    }

    function _liveURI(uint256 id) internal view returns (string memory) {
        (bool ok, bytes memory d) = live.staticcall(abi.encodeWithSignature("tokenURI(uint256)", id));
        require(ok, "live tokenURI reverted");
        return abi.decode(d, (string));
    }

    // ------------------------------------------------------- 1. REGRESSION

    function test_fork_parity_with_live_renderer() public {
        if (!forked) return;
        // a spread: OG cohort, later eras, a reaper with marks, a mid id
        uint256[8] memory ids = [uint256(1), 23, 99, 136, 373, 2201, 6669, CROWN];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            (bool exists,) = DIAMOND.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!exists) continue;
            assertEq(
                keccak256(bytes(v5.tokenURI(id))),
                keccak256(bytes(_liveURI(id))),
                "V5 must be byte-identical for souls and reapers"
            );
        }
    }

    // ------------------------------------------------- 2. the union branch

    function _uploadMask() internal {
        bytes memory inner = vm.readFileBinary("onchain-data/memento-mori-inner.svg");
        assertGt(inner.length, 10_000, "mask fragment looks empty");
        vm.prank(ISvgStoreR(STORE).owner());
        ISvgStoreR(STORE).setTrait(BC_MEMENTO, "Memento Mori", inner);
        assertGt(ISvgStoreR(STORE).traitSvg(BC_MEMENTO).length, 10_000, "mask not stored");
    }

    function _thirtyOfWhale() internal view returns (uint256[] memory ids) {
        ids = new uint256[](30);
        uint256 n;
        for (uint256 id = 1; id <= 4000 && n < 30; id++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!ok || ret.length != 32) continue;
            if (abi.decode(ret, (address)) != WHALE) continue;
            if (souls.soulsConsumed(id) != 0) continue;
            if (souls.isVesselToken(id)) continue;
            ids[n++] = id;
        }
        require(n == 30, "whale has <30 clean souls");
    }

    function _makeConsumedCanvas() internal returns (uint256) {
        address crownHolder = souls.ownerOf(CROWN);
        for (uint256 id = 1; id <= 3000; id++) {
            (bool ok, bytes memory ret) = PIKKAZO.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!ok || ret.length != 32) continue;
            address h = abi.decode(ret, (address));
            if (h == address(0) || h.code.length > 0) continue;
            vm.prank(h);
            IPikkazoR(PIKKAZO).transferFrom(h, crownHolder, id);
            uint256[] memory one = new uint256[](1);
            one[0] = id;
            vm.startPrank(crownHolder);
            IPikkazoR(PIKKAZO).setApprovalForAll(DIAMOND, true);
            souls.offer(CROWN, one);
            vm.stopPrank();
            return id;
        }
        revert("no live pikkazo");
    }

    function test_fork_memento_mori_renders() public {
        if (!forked) return;
        _uploadMask();

        uint256 canvas = _makeConsumedCanvas();
        uint256[] memory members = _thirtyOfWhale();
        vm.deal(WHALE, 1 ether);
        vm.prank(WHALE);
        souls.fuse{value: 0.0005 ether}(canvas, members, string.concat("Memento Mori #", vm.toString(canvas)));
        assertTrue(souls.isVesselToken(canvas));

        // decode the data:application/json;base64 payload
        string memory uri = v5.tokenURI(canvas);
        bytes memory json = vm.parseBytes(string.concat("0x", _hex(Base64Decode(uri))));
        string memory j = string(json);

        assertTrue(_contains(j, string.concat('"name":"Memento Mori #', vm.toString(canvas), '"')), "museum plaque");
        assertTrue(_contains(j, '"trait_type":"Status","value":"Memento Mori"'), "status");
        assertTrue(_contains(j, '"trait_type":"Mask","value":"Memento Mori"'), "mask trait");
        assertTrue(_contains(j, '"trait_type":"Souls United","value":30'), "thirty");
        assertFalse(_contains(j, '"trait_type":"Cohort"'), "a union has no era");
        assertFalse(_contains(j, "Souls Consumed"), "a union never burned anything");
        assertTrue(_contains(j, "data:image/svg+xml;base64,"), "on-chain art");

        // the mask must be the LAST layer of the composed svg
        string memory svg = string(_b64(_between(j, '"image":"data:image/svg+xml;base64,', '"')));
        bytes memory maskInner = ISvgStoreR(STORE).traitSvg(BC_MEMENTO);
        assertTrue(_contains(svg, string(maskInner)), "mask painted");
        uint256 at = _indexOf(svg, string(maskInner));
        assertEq(at + maskInner.length + 6, bytes(svg).length, "mask must be the top layer (last before </svg>)");

        // and an ordinary soul is untouched by the presence of the union
        assertEq(keccak256(bytes(v5.tokenURI(99))), keccak256(bytes(_liveURI(99))), "souls unchanged");
        console.log("Memento Mori", canvas);
    }

    // ----------------------------------------------------------- helpers

    function Base64Decode(string memory uri) internal pure returns (bytes memory) {
        return _b64(_between(uri, "data:application/json;base64,", ""));
    }

    function _between(string memory s, string memory startTok, string memory endTok)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(s);
        uint256 start = _indexOf(s, startTok) + bytes(startTok).length;
        uint256 end = b.length;
        if (bytes(endTok).length != 0) {
            for (uint256 i = start; i < b.length; i++) {
                if (b[i] == bytes(endTok)[0]) {
                    end = i;
                    break;
                }
            }
        }
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; i++) out[i] = b[start + i];
        return string(out);
    }

    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        return type(uint256).max;
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return _indexOf(hay, needle) != type(uint256).max;
    }

    function _hex(bytes memory b) internal pure returns (string memory) {
        bytes memory hexd = "0123456789abcdef";
        bytes memory out = new bytes(b.length * 2);
        for (uint256 i; i < b.length; i++) {
            out[i * 2] = hexd[uint8(b[i]) >> 4];
            out[i * 2 + 1] = hexd[uint8(b[i]) & 0x0f];
        }
        return string(out);
    }

    /// minimal base64 decoder (test-only)
    function _b64(string memory s) internal pure returns (bytes memory) {
        bytes memory data = bytes(s);
        if (data.length == 0) return "";
        uint256 pad = 0;
        if (data[data.length - 1] == "=") pad++;
        if (data.length > 1 && data[data.length - 2] == "=") pad++;
        bytes memory out = new bytes((data.length / 4) * 3 - pad);
        uint256 o;
        for (uint256 i; i < data.length; i += 4) {
            uint256 v = (_c(data[i]) << 18) | (_c(data[i + 1]) << 12) | (_c(data[i + 2]) << 6) | _c(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(v >> 16));
            if (o < out.length) out[o++] = bytes1(uint8((v >> 8) & 0xFF));
            if (o < out.length) out[o++] = bytes1(uint8(v & 0xFF));
        }
        return out;
    }

    function _c(bytes1 ch) internal pure returns (uint256) {
        uint8 c = uint8(ch);
        if (c >= 65 && c <= 90) return c - 65;
        if (c >= 97 && c <= 122) return c - 71;
        if (c >= 48 && c <= 57) return c + 4;
        if (c == 43) return 62;
        if (c == 47) return 63;
        return 0;
    }
}
