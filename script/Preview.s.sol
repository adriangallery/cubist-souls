// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PlaceholderRenderer} from "../src/render/PlaceholderRenderer.sol";

/// Prints tokenURI samples so the placeholder can be eyeballed before deploy.
contract Preview is Script {
    function run() external {
        PlaceholderRenderer r = new PlaceholderRenderer();
        console.log("TOKEN_3995:");
        console.log(r.tokenURI(3995));
        console.log("TOKEN_99:");
        console.log(r.tokenURI(99));
        console.log("CONTRACT_URI:");
        console.log(r.contractURI());
    }
}
