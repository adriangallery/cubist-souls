// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface IPricing {
    function pricing()
        external
        view
        returns (uint64 saleStart, uint32 b1, uint32 b2, uint32 b3, uint256 p1, uint256 p2, uint256 p3);
    function setPricing(uint64 newSaleStart, uint32 b1, uint32 b2, uint32 b3, uint256 p1, uint256 p2, uint256 p3)
        external;
    function priceNow() external view returns (uint256);
}

/// @title SetPricing - the new ladder (Adrian, 03-ago-2026)
///
///   from now  : 0.0003 ETH   (was 0.0001)
///   from Aug 9: 0.01  ETH    (was 0.0003)
///   from Sep17: 0.03  ETH    (was 0.0005)
///
/// The windows themselves do NOT move: saleStart and the three bounds are read
/// from storage and written back verbatim. That matters more than it looks —
/// setPricing turns a saleStart of 0 into block.timestamp, which would restart
/// the clock and REOPEN THE FREE WINDOW. Proven in PricingFork.t.sol.
contract SetPricing is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    uint256 constant P_NOW = 0.0003 ether;
    uint256 constant P_AUG9 = 0.01 ether;
    uint256 constant P_SEP17 = 0.03 ether;

    function run() external {
        IPricing d = IPricing(DIAMOND);
        (uint64 start, uint32 b1, uint32 b2, uint32 b3, uint256 op1, uint256 op2, uint256 op3) = d.pricing();

        require(start != 0, "no saleStart: refusing to write");
        console.log("saleStart (kept):", start);
        console.log("before -> now/aug/sep:", op1, op2, op3);

        vm.startBroadcast();
        d.setPricing(start, b1, b2, b3, P_NOW, P_AUG9, P_SEP17);
        vm.stopBroadcast();

        (uint64 s2, uint32 n1, uint32 n2, uint32 n3, uint256 p1, uint256 p2, uint256 p3) = d.pricing();
        require(s2 == start, "saleStart moved");
        require(n1 == b1 && n2 == b2 && n3 == b3, "bounds moved");
        require(p1 == P_NOW && p2 == P_AUG9 && p3 == P_SEP17, "prices not set");
        require(d.priceNow() == P_NOW, "priceNow wrong");
        console.log("after  -> now/aug/sep:", p1, p2, p3);
        console.log("priceNow:", d.priceNow());
    }
}
