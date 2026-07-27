// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title RevisionManifest - AUTO-GENERATED from onchain-data/revisions-index.json.
///         DO NOT EDIT BY HAND. Regenerate: python3 script/gen_revision_manifest.py
/// @notice The 21 artist revisions: original traitId (`from`, override key + unchanged
///         attribute name) -> revision traitId (`to`, a fresh option per category
///         captured against the LIVE store 0x6702..46C6), shared name, flattened v2 path.
library RevisionManifest {
    uint256 internal constant COUNT = 21;

    function expectedBase(uint8 cat) internal pure returns (uint16) {
        if (cat == 0) return 15;
        if (cat == 1) return 20;
        if (cat == 2) return 15;
        if (cat == 3) return 15;
        if (cat == 4) return 20;
        if (cat == 5) return 20;
        if (cat == 6) return 20;
        if (cat == 7) return 20;
        return type(uint16).max;
    }

    function all()
        internal
        pure
        returns (uint16[] memory from, uint16[] memory to, string[] memory names, string[] memory paths)
    {
        from = new uint16[](21);
        to = new uint16[](21);
        names = new string[](21);
        paths = new string[](21);
        from[0] = 4; to[0] = 15; names[0] = "Star Blue"; paths[0] = "onchain-data/svg/art-background/star-blue-v2.svg";
        from[1] = 8; to[1] = 16; names[1] = "Star Neon"; paths[1] = "onchain-data/svg/art-background/star-neon-v2.svg";
        from[2] = 10; to[2] = 17; names[2] = "Star Pink"; paths[2] = "onchain-data/svg/art-background/star-pink-v2.svg";
        from[3] = 12; to[3] = 18; names[3] = "Star Red"; paths[3] = "onchain-data/svg/art-background/star-red-v2.svg";
        from[4] = 262; to[4] = 276; names[4] = "Glow Stone"; paths[4] = "onchain-data/svg/base/glow-stone-v2.svg";
        from[5] = 264; to[5] = 277; names[5] = "Heatwave"; paths[5] = "onchain-data/svg/base/heatwave-v2.svg";
        from[6] = 265; to[6] = 278; names[6] = "Impression Sunrise"; paths[6] = "onchain-data/svg/base/impression-sunrise-v2.svg";
        from[7] = 269; to[7] = 279; names[7] = "Soft Cloud"; paths[7] = "onchain-data/svg/base/soft-cloud-v2.svg";
        from[8] = 275; to[8] = 280; names[8] = "Time Leap"; paths[8] = "onchain-data/svg/base/time-leap-v2.svg";
        from[9] = 516; to[9] = 527; names[9] = "Greek Gods"; paths[9] = "onchain-data/svg/clothes/greek-gods-v2.svg";
        from[10] = 518; to[10] = 528; names[10] = "Painter Work"; paths[10] = "onchain-data/svg/clothes/painter-work-v2.svg";
        from[11] = 526; to[11] = 529; names[11] = "White Hoodie"; paths[11] = "onchain-data/svg/clothes/white-hoodie-v2.svg";
        from[12] = 773; to[12] = 783; names[12] = "Greek Gods"; paths[12] = "onchain-data/svg/head/greek-gods-v2.svg";
        from[13] = 782; to[13] = 784; names[13] = "Trucker Cap"; paths[13] = "onchain-data/svg/head/trucker-cap-v2.svg";
        from[14] = 1025; to[14] = 1044; names[14] = "Artistic"; paths[14] = "onchain-data/svg/mouth/artistic-v2.svg";
        from[15] = 1031; to[15] = 1045; names[15] = "Gentleman"; paths[15] = "onchain-data/svg/mouth/gentleman-v2.svg";
        from[16] = 1285; to[16] = 1300; names[16] = "Colony"; paths[16] = "onchain-data/svg/left-eye/colony-v2.svg";
        from[17] = 1293; to[17] = 1301; names[17] = "So Lame"; paths[17] = "onchain-data/svg/left-eye/so-lame-v2.svg";
        from[18] = 1795; to[18] = 1812; names[18] = "Color Picker"; paths[18] = "onchain-data/svg/right-eye/color-picker-v2.svg";
        from[19] = 1796; to[19] = 1813; names[19] = "Cynical"; paths[19] = "onchain-data/svg/right-eye/cynical-v2.svg";
        from[20] = 1802; to[20] = 1814; names[20] = "Mad Man"; paths[20] = "onchain-data/svg/right-eye/mad-man-v2.svg";
    }
}
