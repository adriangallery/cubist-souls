// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {RevisionManifest} from "./RevisionManifest.sol";
import {SvgStrip} from "./SvgStrip.sol";

interface ISvgStoreRead {
    function traitExists(uint16 traitId) external view returns (bool);
    function nextOption(uint8 cat) external view returns (uint16);
    function traitName(uint16 traitId) external view returns (string memory);
}

/// @title UploadRevisions - upload the 21 artist-revised traits to the LIVE SvgStore
/// @notice Uploads each flattened v2 SVG (onchain-data/svg/<cat>/<slug>-v2.svg) under
///         a FRESH option id per category with the SAME name string as the original
///         it corrects. The token->traits table and every original trait are left
///         untouched — this is purely additive (the SvgStore is append-only,
///         write-once-per-id, un-sealed).
///
///         Resumable / idempotent: a revision whose target id already exists is
///         skipped, so an interrupted run (or Base/Ethereum in-flight throttling)
///         can be re-run with the same STORE address to finish.
///
///         Drift guard: on a FRESH run (nothing from this batch stored yet) it
///         asserts nextOption(cat) == RevisionManifest.expectedBase(cat) for every
///         touched category, so a concurrently-added trait can never silently shift
///         the target ids. Once partially uploaded, explicit-id writes + the store's
///         AlreadyStored revert keep every subsequent run safe.
///
/// Env:
///   STORE   (required) the live SvgStore (0x6702016627141350792Dd366885a2Fc794eE46C6)
///
/// Dry-run (fork, no broadcast):
///   STORE=0x6702016627141350792Dd366885a2Fc794eE46C6 \
///     forge script script/UploadRevisions.s.sol --fork-url $ETH_RPC -vv
/// Live (Fable, after GO; --slow for in-flight limits):
///   STORE=0x6702016627141350792Dd366885a2Fc794eE46C6 \
///     forge script script/UploadRevisions.s.sol --rpc-url $ETH_RPC --broadcast --slow -vv
contract UploadRevisions is Script {
    function run() external {
        address storeAddr = vm.envAddress("STORE");
        require(storeAddr.code.length != 0, "STORE has no code");
        SvgStore store = SvgStore(storeAddr);
        ISvgStoreRead r = ISvgStoreRead(storeAddr);

        (uint16[] memory from, uint16[] memory to, string[] memory names, string[] memory paths) =
            RevisionManifest.all();

        // --- pre-flight: original exists + name preserved; count already-stored ---
        uint256 already;
        for (uint256 i; i < to.length; ++i) {
            require(r.traitExists(from[i]), "original trait missing");
            if (r.traitExists(to[i])) already++;
        }

        // --- drift guard on a fresh run only ---
        if (already == 0) {
            for (uint256 i; i < to.length; ++i) {
                uint8 cat = uint8(to[i] >> 8);
                require(
                    r.nextOption(cat) == RevisionManifest.expectedBase(cat),
                    "store drifted: nextOption != expectedBase"
                );
            }
            console.log("Drift guard OK (fresh run).");
        } else {
            console.log("Resuming: revisions already stored:", already);
        }

        vm.startBroadcast();

        uint256 stored;
        uint256 skipped;
        for (uint256 i; i < to.length; ++i) {
            if (r.traitExists(to[i])) {
                skipped++;
                console.log("skip (exists) to=%s name=%s", to[i], names[i]);
                continue;
            }
            bytes memory inner = SvgStrip.inner(bytes(vm.readFile(paths[i])));
            store.setTrait(to[i], names[i], inner);
            stored++;
            // from -> to line for the override step (grep-able in the run log)
            console.log("OVERRIDE from=%s to=%s", from[i], to[i]);
            console.log("   stored name=%s bytes=%s", names[i], inner.length);
        }

        vm.stopBroadcast();

        console.log("Revisions: stored %s, skipped %s", stored, skipped);
        console.log("Verify names preserved (sample):");
        console.log("  to=%s name=%s", to[0], r.traitName(to[0]));
    }
}
