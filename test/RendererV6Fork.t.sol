// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SoulRendererV6} from "../src/onchain/SoulRendererV6.sol";

interface ISoulsR6 {
    function ownerOf(uint256) external view returns (address);
    function owner() external view returns (address);
    function renderer() external view returns (address);
    function tokenURI(uint256) external view returns (string memory);
    function vaultOf(uint256) external view returns (address);
    function batchTransfer(address to, uint256[] calldata ids) external;
    function isReaper(uint256) external view returns (bool);
    function setRenderer(address) external;
}

interface ILiveR6 {
    function store() external view returns (address);
    function traitOverride() external view returns (address);
}

/// V6 adds ONE line to a reaper's metadata: what its vault carries, because
/// that is what a buyer inherits. Everything else must be untouched.
///
///   ETH_RPC=<url> forge test --match-contract RendererV6Fork -vv
contract RendererV6ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant WHALE = 0x4943407105999e3E97EFA2035F5cbC64D72581C6;
    uint256 constant REAPER = 8777;

    bool forked;
    ISoulsR6 s = ISoulsR6(DIAMOND);
    SoulRendererV6 v6;
    address live;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        live = s.renderer();
        v6 = new SoulRendererV6(DIAMOND, ILiveR6(live).store(), ILiveR6(live).traitOverride());
    }

    function _liveURI(uint256 id) internal view returns (string memory) {
        (bool ok, bytes memory d) = live.staticcall(abi.encodeWithSignature("tokenURI(uint256)", id));
        require(ok, "live reverted");
        return abi.decode(d, (string));
    }

    /// Nothing changes for anyone who carries nothing — souls, and reapers with
    /// an empty vault, are byte-identical to what is live today.
    function test_fork_identical_while_nothing_is_carried() public {
        if (!forked) return;
        // NOTE: a reaper that already carries souls is expected to differ — that
        // is the whole feature. Only tokens carrying nothing must match.
        uint256[5] memory ids = [uint256(1), 23, 99, 136, REAPER];
        for (uint256 i; i < ids.length; i++) {
            assertEq(
                keccak256(bytes(v6.tokenURI(ids[i]))),
                keccak256(bytes(_liveURI(ids[i]))),
                "must match the live renderer"
            );
        }
    }

    /// A reaper that already carries souls says so — and the live renderer does
    /// not. This is the whole point of V6.
    function test_fork_a_loaded_reaper_declares_its_load() public {
        if (!forked) return;
        uint256 loaded = 487; // carries thirty, placed through the museum's own tool
        string memory v6uri = _json(v6.tokenURI(loaded));
        assertTrue(_has(v6uri, '"trait_type":"Souls Behind","value":30'), "V6 declares the load");
        assertFalse(_has(_json(_liveURI(loaded)), "Souls Behind"), "the live renderer hides it");
    }

    /// Put souls behind a reaper and the metadata says so — the line a buyer
    /// needs before bidding.
    function test_fork_metadata_reports_what_the_reaper_carries() public {
        if (!forked) return;
        address vault = s.vaultOf(REAPER);
        assertTrue(s.isReaper(REAPER));

        // three of the whale's souls stand behind it
        uint256[] memory ids = new uint256[](3);
        uint256 n;
        for (uint256 id = 1; id <= 4000 && n < 3; id++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!ok || ret.length != 32) continue;
            if (abi.decode(ret, (address)) != WHALE) continue;
            if (s.isReaper(id)) continue;
            ids[n++] = id;
        }
        require(n == 3, "not enough souls");

        string memory before = _json(v6.tokenURI(REAPER));
        assertFalse(_has(before, "Souls Behind"), "nothing carried, nothing said");

        vm.prank(WHALE);
        s.batchTransfer(vault, ids);

        string memory after_ = _json(v6.tokenURI(REAPER));
        assertTrue(_has(after_, "Souls Behind"), "the metadata must show the load");
        assertTrue(_has(after_, '"trait_type":"Souls Behind","value":3'), "and the exact count");
        // and the live renderer still says nothing — this is what V6 adds
        assertFalse(_has(_json(_liveURI(REAPER)), "Souls Behind"), "sanity: V5 has no such line");
    }

    /// decode the data:application/json;base64 payload before looking inside it
    function _json(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        uint256 start;
        for (uint256 i; i + 7 < b.length; i++) {
            if (b[i] == "b" && b[i + 1] == "a" && b[i + 2] == "s" && b[i + 3] == "e" && b[i + 4] == "6"
                && b[i + 5] == "4" && b[i + 6] == ",") {
                start = i + 7;
                break;
            }
        }
        bytes memory data = new bytes(b.length - start);
        for (uint256 i; i < data.length; i++) data[i] = b[start + i];
        return string(_b64(data));
    }

    function _b64(bytes memory data) internal pure returns (bytes memory) {
        if (data.length == 0) return "";
        uint256 pad;
        if (data[data.length - 1] == "=") pad++;
        if (data.length > 1 && data[data.length - 2] == "=") pad++;
        bytes memory out = new bytes((data.length / 4) * 3 - pad);
        uint256 o;
        for (uint256 i; i + 3 < data.length; i += 4) {
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

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory nd = bytes(needle);
        if (nd.length == 0 || nd.length > h.length) return false;
        for (uint256 i; i + nd.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j; j < nd.length; j++) {
                if (h[i + j] != nd[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
