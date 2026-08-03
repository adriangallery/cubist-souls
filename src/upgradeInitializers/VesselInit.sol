// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

/// @title VesselInit - seeds the fusion rite fee (ratified: 0.0005 ETH).
contract VesselInit {
    function init() external {
        LibSouls.layout().vesselFee = 0.0005 ether;
    }
}
