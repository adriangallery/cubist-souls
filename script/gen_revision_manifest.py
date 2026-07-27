#!/usr/bin/env python3
"""Regenerate script/RevisionManifest.sol from onchain-data/revisions-index.json.
Run from repo root AFTER script/normalize_revisions.py:
    python3 script/gen_revision_manifest.py
"""
import json
import os
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# nextOption(cat) on the LIVE store 0x6702..46C6 before this upload.
BASE = {0: 15, 1: 20, 2: 15, 3: 15, 4: 20, 5: 20, 6: 20, 7: 20}


def main():
    idx = json.load(open(os.path.join(ROOT, "onchain-data/revisions-index.json")))
    revs = idx["revisions"]

    # verify to == (cat<<8)|(base+k)
    cnt = defaultdict(int)
    for r in revs:
        cat = r["cat"]
        exp = (cat << 8) | (BASE[cat] + cnt[cat])
        cnt[cat] += 1
        assert exp == r["to"], f'mapping drift {r["name"]}: {exp} != {r["to"]}'

    L = []
    L += ["// SPDX-License-Identifier: MIT", "pragma solidity ^0.8.30;", ""]
    L += ["/// @title RevisionManifest - AUTO-GENERATED from onchain-data/revisions-index.json.",
          "///         DO NOT EDIT BY HAND. Regenerate: python3 script/gen_revision_manifest.py",
          "/// @notice The 21 artist revisions: original traitId (`from`, override key + unchanged",
          "///         attribute name) -> revision traitId (`to`, a fresh option per category",
          "///         captured against the LIVE store 0x6702..46C6), shared name, flattened v2 path.",
          "library RevisionManifest {",
          f"    uint256 internal constant COUNT = {len(revs)};", ""]
    L += ["    function expectedBase(uint8 cat) internal pure returns (uint16) {"]
    for c in sorted(BASE):
        L.append(f"        if (cat == {c}) return {BASE[c]};")
    L += ["        return type(uint16).max;", "    }", ""]
    L += ["    function all()", "        internal", "        pure",
          "        returns (uint16[] memory from, uint16[] memory to, string[] memory names, string[] memory paths)",
          "    {"]
    n = len(revs)
    L += [f"        from = new uint16[]({n});", f"        to = new uint16[]({n});",
          f"        names = new string[]({n});", f"        paths = new string[]({n});"]
    for i, r in enumerate(revs):
        L.append(f'        from[{i}] = {r["from"]}; to[{i}] = {r["to"]}; '
                 f'names[{i}] = "{r["name"]}"; paths[{i}] = "{r["v2_svg"]}";')
    L += ["    }", "}"]
    open(os.path.join(ROOT, "script/RevisionManifest.sol"), "w").write("\n".join(L) + "\n")
    print("wrote script/RevisionManifest.sol (%d revisions)" % n)


if __name__ == "__main__":
    main()
