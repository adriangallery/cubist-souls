// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title SvgManifest - AUTO-GENERATED from onchain-data/traits-index.json. DO NOT EDIT BY HAND.
/// @notice Flat list of composable traits (cats 0-8) for the upload script and tests.
///         Regenerate with: python3 script/gen_manifest.py
library SvgManifest {
    uint256 internal constant COUNT = 149;

    /// @return traitIds  (cat<<8)|opt for every composable trait
    /// @return paths     path relative to repo root of the full SVG document
    /// @return names     option label used as the on-chain trait name
    function all() internal pure returns (uint16[] memory traitIds, string[] memory paths, string[] memory names) {
        traitIds = new uint16[](149);
        paths = new string[](149);
        names = new string[](149);
        traitIds[0] = 0; paths[0] = "onchain-data/svg/art-background/color-block.svg"; names[0] = "Color Block";
        traitIds[1] = 1; paths[1] = "onchain-data/svg/art-background/emerald-tiles.svg"; names[1] = "Emerald Tiles";
        traitIds[2] = 2; paths[2] = "onchain-data/svg/art-background/leaf-tiles.svg"; names[2] = "Leaf Tiles";
        traitIds[3] = 3; paths[3] = "onchain-data/svg/art-background/snow-tiles.svg"; names[3] = "Snow Tiles";
        traitIds[4] = 4; paths[4] = "onchain-data/svg/art-background/star-blue.svg"; names[4] = "Star Blue";
        traitIds[5] = 5; paths[5] = "onchain-data/svg/art-background/star-brown.svg"; names[5] = "Star Brown";
        traitIds[6] = 6; paths[6] = "onchain-data/svg/art-background/star-emerald.svg"; names[6] = "Star Emerald";
        traitIds[7] = 7; paths[7] = "onchain-data/svg/art-background/star-green.svg"; names[7] = "Star Green";
        traitIds[8] = 8; paths[8] = "onchain-data/svg/art-background/star-neon.svg"; names[8] = "Star Neon";
        traitIds[9] = 9; paths[9] = "onchain-data/svg/art-background/star-orange.svg"; names[9] = "Star Orange";
        traitIds[10] = 10; paths[10] = "onchain-data/svg/art-background/star-pink.svg"; names[10] = "Star Pink";
        traitIds[11] = 11; paths[11] = "onchain-data/svg/art-background/star-purple.svg"; names[11] = "Star Purple";
        traitIds[12] = 12; paths[12] = "onchain-data/svg/art-background/star-red.svg"; names[12] = "Star Red";
        traitIds[13] = 13; paths[13] = "onchain-data/svg/art-background/star-snow.svg"; names[13] = "Star Snow";
        traitIds[14] = 14; paths[14] = "onchain-data/svg/art-background/star-white.svg"; names[14] = "Star White";
        traitIds[15] = 256; paths[15] = "onchain-data/svg/base/ancient-tribe.svg"; names[15] = "Ancient Tribe";
        traitIds[16] = 257; paths[16] = "onchain-data/svg/base/as-a-human.svg"; names[16] = "As a Human";
        traitIds[17] = 258; paths[17] = "onchain-data/svg/base/childs-play.svg"; names[17] = "Childs Play";
        traitIds[18] = 259; paths[18] = "onchain-data/svg/base/dark-night.svg"; names[18] = "Dark Night";
        traitIds[19] = 260; paths[19] = "onchain-data/svg/base/emerald-shine.svg"; names[19] = "Emerald Shine";
        traitIds[20] = 261; paths[20] = "onchain-data/svg/base/geometry-dash.svg"; names[20] = "Geometry Dash";
        traitIds[21] = 262; paths[21] = "onchain-data/svg/base/glow-stone.svg"; names[21] = "Glow Stone";
        traitIds[22] = 263; paths[22] = "onchain-data/svg/base/grassland.svg"; names[22] = "Grassland";
        traitIds[23] = 264; paths[23] = "onchain-data/svg/base/heatwave.svg"; names[23] = "Heatwave";
        traitIds[24] = 265; paths[24] = "onchain-data/svg/base/impression-sunrise.svg"; names[24] = "Impression Sunrise";
        traitIds[25] = 266; paths[25] = "onchain-data/svg/base/ocean-eyes.svg"; names[25] = "Ocean Eyes";
        traitIds[26] = 267; paths[26] = "onchain-data/svg/base/playground.svg"; names[26] = "Playground";
        traitIds[27] = 268; paths[27] = "onchain-data/svg/base/snowy-weather.svg"; names[27] = "Snowy Weather";
        traitIds[28] = 269; paths[28] = "onchain-data/svg/base/soft-cloud.svg"; names[28] = "Soft Cloud";
        traitIds[29] = 270; paths[29] = "onchain-data/svg/base/star-gazer.svg"; names[29] = "Star Gazer";
        traitIds[30] = 271; paths[30] = "onchain-data/svg/base/star-struck.svg"; names[30] = "Star Struck";
        traitIds[31] = 272; paths[31] = "onchain-data/svg/base/sun-burn.svg"; names[31] = "Sun Burn";
        traitIds[32] = 273; paths[32] = "onchain-data/svg/base/sunset-point.svg"; names[32] = "Sunset Point";
        traitIds[33] = 274; paths[33] = "onchain-data/svg/base/the-scream.svg"; names[33] = "The Scream";
        traitIds[34] = 275; paths[34] = "onchain-data/svg/base/time-leap.svg"; names[34] = "Time Leap";
        traitIds[35] = 512; paths[35] = "onchain-data/svg/clothes/black-hoodie.svg"; names[35] = "Black Hoodie";
        traitIds[36] = 513; paths[36] = "onchain-data/svg/clothes/detective-noir.svg"; names[36] = "Detective Noir";
        traitIds[37] = 514; paths[37] = "onchain-data/svg/clothes/emerald-butler.svg"; names[37] = "Emerald Butler";
        traitIds[38] = 515; paths[38] = "onchain-data/svg/clothes/fiery-suit.svg"; names[38] = "Fiery Suit";
        traitIds[39] = 516; paths[39] = "onchain-data/svg/clothes/greek-gods.svg"; names[39] = "Greek Gods";
        traitIds[40] = 517; paths[40] = "onchain-data/svg/clothes/high-noble.svg"; names[40] = "High Noble";
        traitIds[41] = 518; paths[41] = "onchain-data/svg/clothes/painter-work.svg"; names[41] = "Painter Work";
        traitIds[42] = 519; paths[42] = "onchain-data/svg/clothes/polo-spike.svg"; names[42] = "Polo Spike";
        traitIds[43] = 520; paths[43] = "onchain-data/svg/clothes/red-scarf.svg"; names[43] = "Red Scarf";
        traitIds[44] = 521; paths[44] = "onchain-data/svg/clothes/shabby-suit.svg"; names[44] = "Shabby Suit";
        traitIds[45] = 522; paths[45] = "onchain-data/svg/clothes/shabby-vest.svg"; names[45] = "Shabby Vest";
        traitIds[46] = 523; paths[46] = "onchain-data/svg/clothes/spider-vest.svg"; names[46] = "Spider Vest";
        traitIds[47] = 524; paths[47] = "onchain-data/svg/clothes/tartan-flanel.svg"; names[47] = "Tartan Flanel";
        traitIds[48] = 525; paths[48] = "onchain-data/svg/clothes/tribe-vest.svg"; names[48] = "Tribe Vest";
        traitIds[49] = 526; paths[49] = "onchain-data/svg/clothes/white-hoodie.svg"; names[49] = "White Hoodie";
        traitIds[50] = 768; paths[50] = "onchain-data/svg/head/beanie-thug.svg"; names[50] = "Beanie Thug";
        traitIds[51] = 769; paths[51] = "onchain-data/svg/head/birthday-party.svg"; names[51] = "Birthday Party";
        traitIds[52] = 770; paths[52] = "onchain-data/svg/head/business-man.svg"; names[52] = "Business Man";
        traitIds[53] = 771; paths[53] = "onchain-data/svg/head/classic-hat.svg"; names[53] = "Classic Hat";
        traitIds[54] = 772; paths[54] = "onchain-data/svg/head/dress-to-impress.svg"; names[54] = "Dress to Impress";
        traitIds[55] = 773; paths[55] = "onchain-data/svg/head/greek-gods.svg"; names[55] = "Greek Gods";
        traitIds[56] = 774; paths[56] = "onchain-data/svg/head/paper-crown.svg"; names[56] = "Paper Crown";
        traitIds[57] = 775; paths[57] = "onchain-data/svg/head/punk-never-die.svg"; names[57] = "Punk Never Die";
        traitIds[58] = 776; paths[58] = "onchain-data/svg/head/red-flat-cap.svg"; names[58] = "Red Flat Cap";
        traitIds[59] = 777; paths[59] = "onchain-data/svg/head/senior-detective.svg"; names[59] = "Senior Detective";
        traitIds[60] = 778; paths[60] = "onchain-data/svg/head/slick-back.svg"; names[60] = "Slick Back";
        traitIds[61] = 779; paths[61] = "onchain-data/svg/head/snapback.svg"; names[61] = "Snapback";
        traitIds[62] = 780; paths[62] = "onchain-data/svg/head/tribe-hat.svg"; names[62] = "Tribe Hat";
        traitIds[63] = 781; paths[63] = "onchain-data/svg/head/trickster.svg"; names[63] = "Trickster";
        traitIds[64] = 782; paths[64] = "onchain-data/svg/head/trucker-cap.svg"; names[64] = "Trucker Cap";
        traitIds[65] = 1024; paths[65] = "onchain-data/svg/mouth/amphibious.svg"; names[65] = "Amphibious";
        traitIds[66] = 1025; paths[66] = "onchain-data/svg/mouth/artistic.svg"; names[66] = "Artistic";
        traitIds[67] = 1026; paths[67] = "onchain-data/svg/mouth/checkered.svg"; names[67] = "Checkered";
        traitIds[68] = 1027; paths[68] = "onchain-data/svg/mouth/clown-surprise.svg"; names[68] = "Clown Surprise";
        traitIds[69] = 1028; paths[69] = "onchain-data/svg/mouth/coward.svg"; names[69] = "Coward";
        traitIds[70] = 1029; paths[70] = "onchain-data/svg/mouth/diva.svg"; names[70] = "Diva";
        traitIds[71] = 1030; paths[71] = "onchain-data/svg/mouth/dress-to-kill.svg"; names[71] = "Dress to Kill";
        traitIds[72] = 1031; paths[72] = "onchain-data/svg/mouth/gentleman.svg"; names[72] = "Gentleman";
        traitIds[73] = 1032; paths[73] = "onchain-data/svg/mouth/lipstain.svg"; names[73] = "Lipstain";
        traitIds[74] = 1033; paths[74] = "onchain-data/svg/mouth/need-water.svg"; names[74] = "Need Water";
        traitIds[75] = 1034; paths[75] = "onchain-data/svg/mouth/nervous.svg"; names[75] = "Nervous";
        traitIds[76] = 1035; paths[76] = "onchain-data/svg/mouth/not-speak.svg"; names[76] = "Not Speak";
        traitIds[77] = 1036; paths[77] = "onchain-data/svg/mouth/rainbow-grill.svg"; names[77] = "Rainbow Grill";
        traitIds[78] = 1037; paths[78] = "onchain-data/svg/mouth/scaredy.svg"; names[78] = "Scaredy";
        traitIds[79] = 1038; paths[79] = "onchain-data/svg/mouth/scary.svg"; names[79] = "Scary";
        traitIds[80] = 1039; paths[80] = "onchain-data/svg/mouth/sharp-angle.svg"; names[80] = "Sharp Angle";
        traitIds[81] = 1040; paths[81] = "onchain-data/svg/mouth/sheriff-on-duty.svg"; names[81] = "Sheriff on Duty";
        traitIds[82] = 1041; paths[82] = "onchain-data/svg/mouth/talk-to-much.svg"; names[82] = "Talk to Much";
        traitIds[83] = 1042; paths[83] = "onchain-data/svg/mouth/unshaven.svg"; names[83] = "Unshaven";
        traitIds[84] = 1043; paths[84] = "onchain-data/svg/mouth/wide-open.svg"; names[84] = "Wide Open";
        traitIds[85] = 1280; paths[85] = "onchain-data/svg/left-eye/all-seeing-eye.svg"; names[85] = "All Seeing Eye";
        traitIds[86] = 1281; paths[86] = "onchain-data/svg/left-eye/asymmetrical.svg"; names[86] = "Asymmetrical";
        traitIds[87] = 1282; paths[87] = "onchain-data/svg/left-eye/blank-gaze.svg"; names[87] = "Blank Gaze";
        traitIds[88] = 1283; paths[88] = "onchain-data/svg/left-eye/checkered.svg"; names[88] = "Checkered";
        traitIds[89] = 1284; paths[89] = "onchain-data/svg/left-eye/childs-play.svg"; names[89] = "Childs Play";
        traitIds[90] = 1285; paths[90] = "onchain-data/svg/left-eye/colony.svg"; names[90] = "Colony";
        traitIds[91] = 1286; paths[91] = "onchain-data/svg/left-eye/confidence.svg"; names[91] = "Confidence";
        traitIds[92] = 1287; paths[92] = "onchain-data/svg/left-eye/danger-sign.svg"; names[92] = "Danger Sign";
        traitIds[93] = 1288; paths[93] = "onchain-data/svg/left-eye/dead-man.svg"; names[93] = "Dead Man";
        traitIds[94] = 1289; paths[94] = "onchain-data/svg/left-eye/hierarchy.svg"; names[94] = "Hierarchy";
        traitIds[95] = 1290; paths[95] = "onchain-data/svg/left-eye/kinda-blue.svg"; names[95] = "Kinda Blue";
        traitIds[96] = 1291; paths[96] = "onchain-data/svg/left-eye/normal-square.svg"; names[96] = "Normal Square";
        traitIds[97] = 1292; paths[97] = "onchain-data/svg/left-eye/not-see.svg"; names[97] = "Not See";
        traitIds[98] = 1293; paths[98] = "onchain-data/svg/left-eye/so-lame.svg"; names[98] = "So Lame";
        traitIds[99] = 1294; paths[99] = "onchain-data/svg/left-eye/the-doll-maker.svg"; names[99] = "The Doll Maker";
        traitIds[100] = 1295; paths[100] = "onchain-data/svg/left-eye/tilted.svg"; names[100] = "Tilted";
        traitIds[101] = 1296; paths[101] = "onchain-data/svg/left-eye/tired-man.svg"; names[101] = "Tired Man";
        traitIds[102] = 1297; paths[102] = "onchain-data/svg/left-eye/triangle-bright.svg"; names[102] = "Triangle Bright";
        traitIds[103] = 1298; paths[103] = "onchain-data/svg/left-eye/triangle-buddy.svg"; names[103] = "Triangle Buddy";
        traitIds[104] = 1299; paths[104] = "onchain-data/svg/left-eye/wrong-option.svg"; names[104] = "Wrong Option";
        traitIds[105] = 1536; paths[105] = "onchain-data/svg/nose/amethyst-block.svg"; names[105] = "Amethyst Block";
        traitIds[106] = 1537; paths[106] = "onchain-data/svg/nose/banana-juice.svg"; names[106] = "Banana Juice";
        traitIds[107] = 1538; paths[107] = "onchain-data/svg/nose/big-bad-red.svg"; names[107] = "Big Bad Red";
        traitIds[108] = 1539; paths[108] = "onchain-data/svg/nose/block.svg"; names[108] = "Block";
        traitIds[109] = 1540; paths[109] = "onchain-data/svg/nose/digital-circus.svg"; names[109] = "Digital Circus";
        traitIds[110] = 1541; paths[110] = "onchain-data/svg/nose/jagged.svg"; names[110] = "Jagged";
        traitIds[111] = 1542; paths[111] = "onchain-data/svg/nose/jigsaw.svg"; names[111] = "Jigsaw";
        traitIds[112] = 1543; paths[112] = "onchain-data/svg/nose/mirrored.svg"; names[112] = "Mirrored";
        traitIds[113] = 1544; paths[113] = "onchain-data/svg/nose/monkey-business.svg"; names[113] = "Monkey Business";
        traitIds[114] = 1545; paths[114] = "onchain-data/svg/nose/mountains.svg"; names[114] = "Mountains";
        traitIds[115] = 1546; paths[115] = "onchain-data/svg/nose/pinocchio.svg"; names[115] = "Pinocchio";
        traitIds[116] = 1547; paths[116] = "onchain-data/svg/nose/playground.svg"; names[116] = "Playground";
        traitIds[117] = 1548; paths[117] = "onchain-data/svg/nose/sky-scraper.svg"; names[117] = "Sky Scraper";
        traitIds[118] = 1549; paths[118] = "onchain-data/svg/nose/small-business.svg"; names[118] = "Small Business";
        traitIds[119] = 1550; paths[119] = "onchain-data/svg/nose/smell-detector.svg"; names[119] = "Smell Detector";
        traitIds[120] = 1551; paths[120] = "onchain-data/svg/nose/spike.svg"; names[120] = "Spike";
        traitIds[121] = 1552; paths[121] = "onchain-data/svg/nose/steep-stairs.svg"; names[121] = "Steep Stairs";
        traitIds[122] = 1553; paths[122] = "onchain-data/svg/nose/tangerine.svg"; names[122] = "Tangerine";
        traitIds[123] = 1554; paths[123] = "onchain-data/svg/nose/thunderstorm.svg"; names[123] = "Thunderstorm";
        traitIds[124] = 1555; paths[124] = "onchain-data/svg/nose/tribe-quest.svg"; names[124] = "Tribe Quest";
        traitIds[125] = 1792; paths[125] = "onchain-data/svg/right-eye/amphibious.svg"; names[125] = "Amphibious";
        traitIds[126] = 1793; paths[126] = "onchain-data/svg/right-eye/bruise.svg"; names[126] = "Bruise";
        traitIds[127] = 1794; paths[127] = "onchain-data/svg/right-eye/christmas-tree.svg"; names[127] = "Christmas Tree";
        traitIds[128] = 1795; paths[128] = "onchain-data/svg/right-eye/color-picker.svg"; names[128] = "Color Picker";
        traitIds[129] = 1796; paths[129] = "onchain-data/svg/right-eye/cynical.svg"; names[129] = "Cynical";
        traitIds[130] = 1797; paths[130] = "onchain-data/svg/right-eye/emergency-exit.svg"; names[130] = "Emergency Exit";
        traitIds[131] = 1798; paths[131] = "onchain-data/svg/right-eye/eyeshadow.svg"; names[131] = "Eyeshadow";
        traitIds[132] = 1799; paths[132] = "onchain-data/svg/right-eye/flying-kite.svg"; names[132] = "Flying Kite";
        traitIds[133] = 1800; paths[133] = "onchain-data/svg/right-eye/focused.svg"; names[133] = "Focused";
        traitIds[134] = 1801; paths[134] = "onchain-data/svg/right-eye/gaze.svg"; names[134] = "Gaze";
        traitIds[135] = 1802; paths[135] = "onchain-data/svg/right-eye/mad-man.svg"; names[135] = "Mad Man";
        traitIds[136] = 1803; paths[136] = "onchain-data/svg/right-eye/moon-drop.svg"; names[136] = "Moon Drop";
        traitIds[137] = 1804; paths[137] = "onchain-data/svg/right-eye/nocturnal.svg"; names[137] = "Nocturnal";
        traitIds[138] = 1805; paths[138] = "onchain-data/svg/right-eye/safe-circuit.svg"; names[138] = "Safe Circuit";
        traitIds[139] = 1806; paths[139] = "onchain-data/svg/right-eye/scratched-deep.svg"; names[139] = "Scratched Deep";
        traitIds[140] = 1807; paths[140] = "onchain-data/svg/right-eye/shiny-gems.svg"; names[140] = "Shiny Gems";
        traitIds[141] = 1808; paths[141] = "onchain-data/svg/right-eye/smakeman.svg"; names[141] = "Smakeman";
        traitIds[142] = 1809; paths[142] = "onchain-data/svg/right-eye/spare-coin.svg"; names[142] = "Spare Coin";
        traitIds[143] = 1810; paths[143] = "onchain-data/svg/right-eye/time-square.svg"; names[143] = "Time Square";
        traitIds[144] = 1811; paths[144] = "onchain-data/svg/right-eye/toy-box.svg"; names[144] = "Toy Box";
        traitIds[145] = 2048; paths[145] = "onchain-data/svg/burn-cube/burning-soul.svg"; names[145] = "Burning Soul";
        traitIds[146] = 2049; paths[146] = "onchain-data/svg/burn-cube/flame-crown.svg"; names[146] = "Flame Crown";
        traitIds[147] = 2050; paths[147] = "onchain-data/svg/burn-cube/orange.svg"; names[147] = "Orange";
        traitIds[148] = 2051; paths[148] = "onchain-data/svg/burn-cube/phoenix.svg"; names[148] = "Phoenix";
    }

    /// @notice Category (z-order) labels for setCategoryLabel, cats 0-8.
    function categories() internal pure returns (uint8[] memory cats, string[] memory labels) {
        cats = new uint8[](9);
        labels = new string[](9);
        cats[0] = 0; labels[0] = "Art Background";
        cats[1] = 1; labels[1] = "Base";
        cats[2] = 2; labels[2] = "Clothes";
        cats[3] = 3; labels[3] = "Head";
        cats[4] = 4; labels[4] = "Mouth";
        cats[5] = 5; labels[5] = "Left Eye";
        cats[6] = 6; labels[6] = "Nose";
        cats[7] = 7; labels[7] = "Right Eye";
        cats[8] = 8; labels[8] = "Burn Cube";
    }

    /// @notice Adrian 1/1 (vector) one-of-one; stored under oneOfOne id 0 (no OG token maps to it yet).
    function adrian() internal pure returns (string memory path, string memory name) {
        path = "onchain-data/svg/one-of-one/adrian.svg";
        name = "Adrian";
    }
}
