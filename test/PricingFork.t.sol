// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

interface IPricing {
    function pricing()
        external
        view
        returns (uint64 saleStart, uint32 b1, uint32 b2, uint32 b3, uint256 p1, uint256 p2, uint256 p3);
    function setPricing(uint64 newSaleStart, uint32 b1, uint32 b2, uint32 b3, uint256 p1, uint256 p2, uint256 p3)
        external;
    function priceNow() external view returns (uint256);
    function cohortOf(uint256 tokenId) external view returns (uint8);
    function freedAt(uint256 tokenId) external view returns (uint64);
    function owner() external view returns (address);
}

/// The new ladder (Adrian, 03-ago): 0.0003 from now, 0.01 on Aug 9, 0.03 on Sep 17.
///
/// What this proves before touching a live collection's price:
///   1. the window boundaries and saleStart are UNTOUCHED (a saleStart reset would
///      reopen the FREE window — the one catastrophic failure mode here, because
///      setPricing turns a 0 into block.timestamp);
///   2. the price is right in each of the three windows, checked by warping;
///   3. cohorts of already-freed souls do not move (cohort reads freedAt, not price,
///      but this is the assertion that keeps a future refactor honest).
///
///   ETH_RPC=<url> forge test --match-contract PricingFork -vv
contract PricingForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    uint256 constant P_NOW = 0.0003 ether;
    uint256 constant P_AUG9 = 0.01 ether;
    uint256 constant P_SEP17 = 0.03 ether;

    bool forked;
    IPricing d = IPricing(DIAMOND);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function test_fork_new_ladder() public {
        if (!forked) return;

        (uint64 start, uint32 b1, uint32 b2, uint32 b3, uint256 oldP1,,) = d.pricing();
        console.log("saleStart", start);
        console.log("price before", oldP1);

        // cohorts of a spread of real souls, before
        uint256[5] memory ids = [uint256(1), 99, 136, 1538, 2201];
        uint8[5] memory cohortBefore;
        uint64[5] memory freedBefore;
        for (uint256 i; i < ids.length; i++) {
            cohortBefore[i] = d.cohortOf(ids[i]);
            freedBefore[i] = d.freedAt(ids[i]);
        }

        vm.prank(d.owner());
        d.setPricing(start, b1, b2, b3, P_NOW, P_AUG9, P_SEP17);

        // 1. the schedule itself is untouched — above all, saleStart
        (uint64 s2, uint32 n1, uint32 n2, uint32 n3, uint256 p1, uint256 p2, uint256 p3) = d.pricing();
        assertEq(s2, start, "saleStart MUST NOT move (0 would reopen the free window)");
        assertEq(n1, b1);
        assertEq(n2, b2);
        assertEq(n3, b3);
        assertEq(p1, P_NOW);
        assertEq(p2, P_AUG9);
        assertEq(p3, P_SEP17);

        // 2. the price in each window
        assertEq(d.priceNow(), P_NOW, "today");
        vm.warp(start + b2); // Aug 9 00:00 UTC
        assertEq(d.priceNow(), P_AUG9, "Aug 9");
        vm.warp(start + b2 + 1 days);
        assertEq(d.priceNow(), P_AUG9, "still Aug");
        vm.warp(start + b3); // Sep 17 00:00 UTC
        assertEq(d.priceNow(), P_SEP17, "Sep 17");
        vm.warp(start + b3 + 365 days);
        assertEq(d.priceNow(), P_SEP17, "and it stays, never drops");

        // 3. nobody's cohort moved
        for (uint256 i; i < ids.length; i++) {
            assertEq(d.cohortOf(ids[i]), cohortBefore[i], "cohort moved");
            assertEq(d.freedAt(ids[i]), freedBefore[i], "freedAt moved");
        }
    }

    /// The failure mode worth a test of its own: passing 0 as saleStart resets the
    /// clock to now and the FREE window reopens. This documents why the script
    /// always passes the stored saleStart back.
    function test_fork_zero_saleStart_would_reopen_the_free_window() public {
        if (!forked) return;
        (uint64 start, uint32 b1, uint32 b2, uint32 b3,,,) = d.pricing();
        vm.prank(d.owner());
        d.setPricing(0, b1, b2, b3, P_NOW, P_AUG9, P_SEP17);
        (uint64 s2,,,,,,) = d.pricing();
        assertTrue(s2 != start, "sanity: 0 becomes now");
        assertEq(d.priceNow(), 0, "souls would be FREE again: never pass 0");
    }
}
