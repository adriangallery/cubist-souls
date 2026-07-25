// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SvgManifest} from "./SvgManifest.sol";
import {SvgStrip} from "./SvgStrip.sol";

/// @title UploadSvgs - deploy SvgStore and load all Cubist Souls on-chain data
/// @notice Idempotent / resumable: reads what is already stored and skips it, so
///         an interrupted run (or Base in-flight tx throttling) can be re-run
///         with the same STORE address to finish the job.
///
///         Uploads:
///           - 149 composable trait inner-SVGs (cats 0-8), stripped of wrapper
///           - the Adrian 1/1 one-of-one (under oneOfOne id 0)
///           - the 80,000-byte token->traits table in 4 x 20,000-byte chunks
///
/// Env:
///   STORE   (optional) existing SvgStore to resume; if unset a new one is deployed
///   DIAMOND (optional, unused here but kept for symmetry) Cubist Souls diamond
///
/// Dry-run (no broadcast, deploys to the fork and loads everything):
///   forge script script/UploadSvgs.s.sol --fork-url $RPC -vv
/// Live (ONLY after explicit go-ahead; Base needs --slow for in-flight limits):
///   forge script script/UploadSvgs.s.sol --rpc-url $RPC --broadcast --slow -vv
contract UploadSvgs is Script {
    function run() external {
        address storeAddr = vm.envOr("STORE", address(0));

        vm.startBroadcast();

        SvgStore store;
        if (storeAddr == address(0) || storeAddr.code.length == 0) {
            store = new SvgStore();
            console.log("Deployed SvgStore:", address(store));
        } else {
            store = SvgStore(storeAddr);
            console.log("Resuming SvgStore:", address(store));
        }

        _uploadCategoryLabels(store);
        _uploadTraits(store);
        _uploadAdrian(store);
        _uploadTokenTable(store);

        vm.stopBroadcast();

        console.log("Done. SvgStore:", address(store));
        console.log("  trait chunks uploaded:", store.tokenTraitChunkCount());
    }

    function _uploadCategoryLabels(SvgStore store) internal {
        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        uint256 stored;
        uint256 skipped;
        for (uint256 i; i < cats.length; ++i) {
            if (bytes(store.categoryLabel(cats[i])).length != 0) {
                skipped++;
                continue;
            }
            store.setCategoryLabel(cats[i], labels[i]);
            stored++;
        }
        console.log("Category labels: stored %s, skipped %s", stored, skipped);
    }

    function _uploadTraits(SvgStore store) internal {
        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        uint256 skipped;
        uint256 stored;
        for (uint256 i; i < ids.length; ++i) {
            if (store.traitExists(ids[i])) {
                skipped++;
                continue;
            }
            bytes memory inner = SvgStrip.inner(bytes(vm.readFile(paths[i])));
            store.setTrait(ids[i], names[i], inner);
            stored++;
        }
        console.log("Traits: stored %s, skipped %s", stored, skipped);
    }

    function _uploadAdrian(SvgStore store) internal {
        if (store.oneOfOneExists(0)) {
            console.log("Adrian 1/1: already stored");
            return;
        }
        (string memory path, string memory name) = SvgManifest.adrian();
        bytes memory inner = SvgStrip.inner(bytes(vm.readFile(path)));
        store.setOneOfOne(0, name, inner);
        console.log("Adrian 1/1: stored");
    }

    function _uploadTokenTable(SvgStore store) internal {
        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        require(table.length == store.MAX_TOKENS() * 8, "bad table length");

        uint256 chunkBytes = store.TOKENS_PER_CHUNK() * 8;
        uint256 nChunks = table.length / chunkBytes;
        uint256 have = store.tokenTraitChunkCount();

        for (uint256 c; c < nChunks; ++c) {
            if (c < have) continue;
            bytes memory data = _slice(table, c * chunkBytes, chunkBytes);
            store.setTokenTraitsChunk(c, data);
            console.log("Token table chunk stored:", c);
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
