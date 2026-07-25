#!/usr/bin/env python3
"""Regenerate script/SvgManifest.sol from onchain-data/traits-index.json.

Run from the repo root:  python3 script/gen_manifest.py
The manifest is a flat list of the 149 composable traits (cats 0-8) plus the
Adrian 1/1 one-of-one, consumed by script/UploadSvgs.s.sol and the tests.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> None:
    d = json.load(open(os.path.join(ROOT, "onchain-data/traits-index.json")))
    entries = []  # (traitId, path, name)
    for c in d["categories"]:
        for o in c["options"]:
            entries.append((o["traitId"], o["svg"], o["label"]))
    adrian = next(x for x in d["oneOfOnes"] if x.get("svg"))

    lines = [
        "// SPDX-License-Identifier: MIT",
        "pragma solidity ^0.8.30;",
        "",
        "/// @title SvgManifest - AUTO-GENERATED from onchain-data/traits-index.json. DO NOT EDIT BY HAND.",
        "/// @notice Flat list of composable traits (cats 0-8) for the upload script and tests.",
        "///         Regenerate with: python3 script/gen_manifest.py",
        "library SvgManifest {",
        f"    uint256 internal constant COUNT = {len(entries)};",
        "",
        "    /// @return traitIds  (cat<<8)|opt for every composable trait",
        "    /// @return paths     path relative to repo root of the full SVG document",
        "    /// @return names     option label used as the on-chain trait name",
        "    function all() internal pure returns (uint16[] memory traitIds, string[] memory paths, string[] memory names) {",
        f"        traitIds = new uint16[]({len(entries)});",
        f"        paths = new string[]({len(entries)});",
        f"        names = new string[]({len(entries)});",
    ]
    for i, (tid, path, name) in enumerate(entries):
        lines.append(
            f'        traitIds[{i}] = {tid}; paths[{i}] = "onchain-data/{path}"; names[{i}] = "{esc(name)}";'
        )
    lines += [
        "    }",
        "",
        "    /// @notice Adrian 1/1 (vector) one-of-one; stored under oneOfOne id 0 (no OG token maps to it yet).",
        "    function adrian() internal pure returns (string memory path, string memory name) {",
        f'        path = "onchain-data/{adrian["svg"]}";',
        '        name = "Adrian";',
        "    }",
        "}",
    ]
    out = os.path.join(ROOT, "script/SvgManifest.sol")
    open(out, "w").write("\n".join(lines) + "\n")
    print(f"wrote {out} with {len(entries)} entries")


if __name__ == "__main__":
    main()
