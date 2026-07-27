// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SvgStore} from "../src/onchain/SvgStore.sol";
import {SoulRendererV4} from "../src/onchain/SoulRendererV4.sol";
import {SvgManifest} from "../script/SvgManifest.sol";
import {SvgStrip} from "../script/SvgStrip.sol";

/// Mock diamond that lets us dial soulsConsumed/marksOf/cohortOf for gas probing a
/// full-set reaper without wiring the whole diamond.
contract DialDiamond {
    uint256 public c;
    uint256 public m;
    function set(uint256 c_, uint256 m_) external { c = c_; m = m_; }
    function soulsConsumed(uint256) external view returns (uint256) { return c; }
    function marksOf(uint256) external view returns (uint256) { return m; }
    function cohortOf(uint256) external pure returns (uint8) { return 0; }
}

contract GasProbeV4Test is Test {
    SvgStore store;
    SoulRendererV4 r;
    DialDiamond d;

    function setUp() public {
        store = new SvgStore();
        (uint16[] memory ids, string[] memory paths, string[] memory names) = SvgManifest.all();
        for (uint256 i; i < ids.length; ++i) store.setTrait(ids[i], names[i], SvgStrip.inner(bytes(vm.readFile(paths[i]))));
        (uint8[] memory cats, string[] memory labels) = SvgManifest.categories();
        for (uint256 i; i < cats.length; ++i) store.setCategoryLabel(cats[i], labels[i]);
        bytes memory table = vm.readFileBinary("onchain-data/tokentraits.bin");
        uint256 cb = store.TOKENS_PER_CHUNK() * 8;
        for (uint256 c2; c2 < table.length / cb; ++c2) {
            bytes memory data = new bytes(cb);
            for (uint256 j; j < cb; ++j) data[j] = table[c2 * cb + j];
            store.setTokenTraitsChunk(c2, data);
        }
        d = new DialDiamond();
        r = new SoulRendererV4(address(d), address(store));
    }

    function test_gas_plain_8layer() public view {
        uint256 g = gasleft();
        string memory uri = r.tokenURI(136);
        g = g - gasleft();
        console2.log("PLAIN #136 tokenURI gas:", g);
        console2.log("PLAIN #136 output bytes:", bytes(uri).length);
    }

    function test_gas_full_reaper() public {
        d.set(30, 0xF); // consumed 30, all 4 marks -> full substitution + phoenix fx
        uint256 g = gasleft();
        string memory uri = r.tokenURI(8777);
        g = g - gasleft();
        console2.log("FULL REAPER #8777 tokenURI gas:", g);
        console2.log("FULL REAPER #8777 output bytes:", bytes(uri).length);
    }
}
