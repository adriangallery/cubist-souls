// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";
import {SvgManifest} from "./SvgManifest.sol";
import {SvgStrip} from "./SvgStrip.sol";

/// @title HarnessDumpV4 - fork the live diamond, stand up a real SvgStore, deploy
///        SoulRendererV4 against the REAL diamond, and dump tokenURI + reaperState
///        for the parity sample to harness/out/onchain.json.
/// @notice Read-only against mainnet (a local fork; NO broadcast, NO tx sent). The
///         reaper/cohort reads (soulsConsumed/marksOf/cohortOf) therefore see the
///         REAL on-chain state (e.g. #8777 at 18 consumed). Pair with
///         harness/parity.mjs which diffs this dump against cubistsouls.com/api.
///
///         Run: ETH_RPC=<mainnet rpc> forge script script/HarnessDumpV4.s.sol
contract HarnessDumpV4 is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    function run() external {
        string memory rpc = vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc);

        SvgStore store = _loadStore();
        SoulRendererV4 renderer = new SoulRendererV4(DIAMOND, address(store));
        console2.log("SvgStore (fork):", address(store));
        console2.log("SoulRendererV4 (fork):", address(renderer));

        uint256[] memory ids = _sample();

        // NDJSON, one token per line, written incrementally so the per-token data-URI
        // (up to ~20KB base64) never accumulates into one giant memory buffer.
        string memory path = "harness/out/onchain.ndjson";
        vm.writeFile(path, ""); // truncate
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            string memory uri = renderer.tokenURI(id);
            (uint256 consumed, uint256 marks) = renderer.reaperState(id);
            string memory line = string(
                abi.encodePacked(
                    '{"id":',
                    _u(id),
                    ',"consumed":',
                    _u(consumed),
                    ',"marks":',
                    _u(marks),
                    ',"uri":"',
                    uri, // data-uri base64 or fallback URL: both JSON-safe
                    '"}'
                )
            );
            vm.writeLine(path, line);
        }
        console2.log("wrote harness/out/onchain.ndjson for", ids.length, "tokens");
    }

    /// 35-token parity sample: OGs spread across the frozen list, eras (non-frozen),
    /// honorarium 1/1s (90/294/600), Mich #163 (OG w/o asset), and the real reaper.
    function _sample() internal pure returns (uint256[] memory s) {
        uint16[35] memory a = [
            uint16(2), 3, 4, 5, 90, 99, 163, 250, 294, 518, 600, 777, 1023, 1404, 1727, 1994, 2391,
            2855, 3206, 3712, 4269, 4942, 5000, 5728, 6449, 6841, 7000, 7316, 7668, 8496, 8777, 9110,
            9976, 9999, 10000
        ];
        s = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) s[i] = a[i];
    }

    function _loadStore() internal returns (SvgStore store) {
        store = new SvgStore();
        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        for (uint256 i; i < ids.length; ++i) {
            store.setTrait(ids[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        }
        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        for (uint256 i; i < cats.length; ++i) {
            store.setCategoryLabel(cats[i], labels[i]);
        }
        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        uint256 chunkBytes = store.TOKENS_PER_CHUNK() * 8;
        for (uint256 c; c < table.length / chunkBytes; ++c) {
            bytes memory data = new bytes(chunkBytes);
            for (uint256 j; j < chunkBytes; ++j) data[j] = table[c * chunkBytes + j];
            store.setTokenTraitsChunk(c, data);
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
            d--;
            b[d] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }
}
