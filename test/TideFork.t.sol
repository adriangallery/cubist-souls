// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SoulRendererV7} from "../src/onchain/SoulRendererV7.sol";

interface ISoulsT {
    function ownerOf(uint256) external view returns (address);
    function renderer() external view returns (address);
    function vaultOf(uint256) external view returns (address);
    function batchTransfer(address to, uint256[] calldata ids) external;
    function isReaper(uint256) external view returns (bool);
    function soulsConsumed(uint256) external view returns (uint256);
}

interface ILiveT {
    function store() external view returns (address);
    function traitOverride() external view returns (address);
}

/// THE TIDE, against real mainnet state.
///
/// A renderer swap touches every token, so the bar is the same as always: what
/// carries nothing must be byte-identical to what is live. On top of that, the
/// drowning must behave — hair first, eyes never, clothes gone, reversible, and
/// two reapers at the same depth must not look alike.
///
///   ETH_RPC=<url> forge test --match-contract TideFork -vv
contract TideForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant WHALE = 0x4943407105999e3E97EFA2035F5cbC64D72581C6;
    // The roster moves while the museum is open, so the test reads reality
    // instead of hardcoding it: one reaper that keeps nothing, one that is full.
    uint256 DRY;
    uint256 WET;

    bool forked;
    ISoulsT s = ISoulsT(DIAMOND);
    SoulRendererV7 v7;
    address live;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        live = s.renderer();
        v7 = new SoulRendererV7(DIAMOND, ILiveT(live).store(), ILiveT(live).traitOverride());

        uint256[] memory roster = _roster();
        for (uint256 i; i < roster.length; i++) {
            (uint256 d, uint256 kept) = v7.tide(roster[i]);
            if (DRY == 0 && kept == 0) DRY = roster[i];
            if (WET == 0 && d >= 6) WET = roster[i];
        }
        require(DRY != 0 && WET != 0, "need one dry and one drowned reaper");
        console.log("dry", DRY);
        console.log("drowned", WET);
    }

    function _roster() internal view returns (uint256[] memory) {
        (bool ok, bytes memory d) = DIAMOND.staticcall(abi.encodeWithSignature("orderRoster()"));
        require(ok, "roster");
        return abi.decode(d, (uint256[]));
    }

    function _liveURI(uint256 id) internal view returns (string memory) {
        (bool ok, bytes memory d) = live.staticcall(abi.encodeWithSignature("tokenURI(uint256)", id));
        require(ok, "live reverted");
        return abi.decode(d, (string));
    }

    /// Souls, and reapers that keep nothing, are untouched.
    function test_fork_dry_tokens_are_identical() public {
        if (!forked) return;
        uint256[4] memory ids = [uint256(1), 23, 99, DRY];
        for (uint256 i; i < ids.length; i++) {
            assertEq(keccak256(bytes(v7.tokenURI(ids[i]))), keccak256(bytes(_liveURI(ids[i]))), "must match live");
        }
        (uint256 depth,) = v7.tide(DRY);
        assertEq(depth, 0, "keeps nothing, so nothing is wet");
    }

    /// The one that keeps thirty is fully taken, and says so.
    function test_fork_thirty_souls_means_fully_drowned() public {
        if (!forked) return;
        (uint256 depth, uint256 kept) = v7.tide(WET);
        assertGe(kept, 30);
        assertEq(depth, 6, "six pieces, the lot");
        assertTrue(keccak256(bytes(v7.tokenURI(WET))) != keccak256(bytes(_liveURI(WET))), "it must have changed");
    }

    /// The hair is the first thing the water takes, for every token.
    function test_fork_the_hair_always_goes_first() public {
        if (!forked) return;
        uint256[6] memory ids = [uint256(136), 373, 487, 2201, 6669, 8777];
        for (uint256 i; i < ids.length; i++) {
            uint8[6] memory order = v7.drownOrder(ids[i]);
            assertEq(order[0], 3, "slot 3 is the head");
            // and the order is a permutation: every slot exactly once
            bool[9] memory seen;
            for (uint256 j; j < 6; j++) {
                assertFalse(seen[order[j]], "a slot repeated");
                seen[order[j]] = true;
            }
            assertTrue(seen[0] && seen[1] && seen[3] && seen[4] && seen[6] && seen[8], "a slot missing");
            // the eyes are never in it
            assertFalse(seen[5] || seen[7], "the eyes must never drown");
        }
    }

    /// Two reapers at the same depth do not look the same.
    function test_fork_no_two_reapers_sink_alike() public {
        if (!forked) return;
        uint256[] memory r = _roster();
        uint8[6] memory a = v7.drownOrder(r[0]);
        uint8[6] memory b = v7.drownOrder(r[1]);
        uint8[6] memory c = v7.drownOrder(r[2]);
        assertTrue(_differs(a, b) && _differs(b, c) && _differs(a, c), "orders must differ");
    }

    /// Taking the souls back out dries the reaper again — the tide falls.
    function test_fork_the_tide_falls_when_the_souls_leave() public {
        if (!forked) return;
        address vault = s.vaultOf(WET);
        string memory wet = v7.tokenURI(WET);

        // the vault sends everything it keeps back to the holder
        uint256[] memory found = new uint256[](40);
        uint256 n;
        for (uint256 id = 1; id <= 10000 && n < 40; id++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!ok || ret.length != 32) continue;
            if (abi.decode(ret, (address)) != vault) continue;
            found[n++] = id;
        }
        require(n > 0, "the vault should keep something");
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) ids[i] = found[i];
        address holder = s.ownerOf(WET);
        vm.prank(holder);
        (bool done,) = vault.call(
            abi.encodeWithSignature(
                "execute(address,uint256,bytes,uint8)",
                DIAMOND,
                uint256(0),
                abi.encodeWithSelector(ISoulsT.batchTransfer.selector, holder, ids),
                uint8(0)
            )
        );
        assertTrue(done, "the vault should release them");

        (uint256 depth, uint256 kept) = v7.tide(WET);
        assertEq(kept, 0);
        assertEq(depth, 0, "dry again");
        assertTrue(keccak256(bytes(v7.tokenURI(WET))) != keccak256(bytes(wet)), "the art went back");
        assertEq(keccak256(bytes(v7.tokenURI(WET))), keccak256(bytes(_liveURI(WET))), "and matches the dry art");
    }

    function _differs(uint8[6] memory a, uint8[6] memory b) internal pure returns (bool) {
        for (uint256 i; i < 6; i++) if (a[i] != b[i]) return true;
        return false;
    }
}
