// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";
import {SoulRendererV4_1} from "../src/onchain/SoulRendererV4_1.sol";
import {TraitOverride} from "../src/onchain/TraitOverride.sol";
import {SvgManifest} from "./SvgManifest.sol";
import {RevisionManifest} from "./RevisionManifest.sol";
import {SvgStrip} from "./SvgStrip.sol";

/// @title HarnessDumpV4_1 - fork the live diamond, stand up a store with the 149
///        originals + 21 v2 revisions, wire a TraitOverride with the 21 pairs, and
///        dump BOTH renderers' output for the revision token sample:
///          - V4_1 with the override ACTIVE  (uri_v41)   -> image shows v2 art
///          - V4 with NO override            (uri_v4)    -> reference attributes
///        for every token, plus the derived consumed/marks (real on-chain reaper
///        state, e.g. #8777). Read-only fork (NO broadcast). Pair with
///        harness/parity_v2.mjs.
///
///        Run: ETH_RPC=<mainnet rpc> forge script script/HarnessDumpV4_1.s.sol
contract HarnessDumpV4_1 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        string memory rpc = vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc);

        SvgStore store = _loadStore();
        _uploadRevisions(store);

        TraitOverride ovr = new TraitOverride();
        (uint16[] memory from, uint16[] memory to,,) = RevisionManifest.all();
        ovr.setOverrides(from, to);

        SoulRendererV4 v4 = new SoulRendererV4(DIAMOND, address(store));
        SoulRendererV4_1 v41 = new SoulRendererV4_1(DIAMOND, address(store), address(ovr));
        console2.log("SvgStore(fork):", address(store));
        console2.log("TraitOverride(fork):", address(ovr));
        console2.log("V4(fork):", address(v4));
        console2.log("V4_1(fork):", address(v41));

        uint256[] memory ids = _sample();
        string memory path = "harness/out/onchain_v41.ndjson";
        vm.writeFile(path, "");
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (uint256 consumed, uint256 marks) = v41.reaperState(id);
            string memory line = string(
                abi.encodePacked(
                    '{"id":', _u(id),
                    ',"consumed":', _u(consumed),
                    ',"marks":', _u(marks),
                    ',"uri_v41":"', v41.tokenURI(id),
                    '","uri_v4":"', v4.tokenURI(id),
                    '"}'
                )
            );
            vm.writeLine(path, line);
        }
        console2.log("wrote harness/out/onchain_v41.ndjson for", ids.length, "tokens");
    }

    /// 11 tokens that collectively use ALL 21 revised traits; includes the real
    /// marked reaper #8777 (override + reaper marks together).
    function _sample() internal pure returns (uint256[] memory a) {
        a = new uint256[](11);
        a[0] = 4;    // star-neon, mad-man
        a[1] = 136;  // white-hoodie, colony
        a[2] = 187;  // star-blue, impr-sunrise, painter-work, greek-gods(head), colony
        a[3] = 924;  // heatwave, greek-gods(clothes+head), gentleman, color-picker
        a[4] = 1194; // time-leap, greek-gods, trucker-cap, gentleman, so-lame
        a[5] = 3783; // star-pink, glow-stone, greek-gods x2, colony
        a[6] = 4294; // star-red, time-leap, white-hoodie, colony, color-picker
        a[7] = 4456; // star-neon, trucker-cap, gentleman, so-lame, cynical
        a[8] = 4654; // star-blue, white-hoodie, trucker-cap, artistic, so-lame, color-picker
        a[9] = 5496; // star-pink, soft-cloud, greek-gods, so-lame, color-picker
        a[10] = 8777; // REAPER: star-pink, colony, color-picker (+ marks)
    }

    function _uploadRevisions(SvgStore s) internal {
        (, uint16[] memory to, string[] memory names, string[] memory paths) =
            RevisionManifest.all();
        for (uint256 i; i < to.length; ++i) {
            s.setTrait(to[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        }
    }

    function _loadStore() internal returns (SvgStore s) {
        s = new SvgStore();
        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        for (uint256 i; i < ids.length; ++i) {
            s.setTrait(ids[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        }
        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        for (uint256 i; i < cats.length; ++i) s.setCategoryLabel(cats[i], labels[i]);
        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        uint256 cb = s.TOKENS_PER_CHUNK() * 8;
        for (uint256 c; c < table.length / cb; ++c) {
            bytes memory data = new bytes(cb);
            for (uint256 j; j < cb; ++j) data[j] = table[c * cb + j];
            s.setTokenTraitsChunk(c, data);
        }
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 d;
        while (t != 0) {
            d++;
            t /= 10;
        }
        bytes memory b = new bytes(d);
        while (v != 0) {
            d -= 1;
            b[d] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }
}
