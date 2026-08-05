// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

interface ISoulsV2 {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
    function batchTransfer(address to, uint256[] calldata ids) external;
    function reaperAccount(uint256 id) external view returns (address, bool);
    function isReaper(uint256 id) external view returns (bool);
}

interface IAccount {
    function owner() external view returns (address);
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

/// Can a holder stock their reaper's vault with souls, and get them back?
///
/// This needs NO new contract code — it is the ERC-6551 account plus the batch
/// transfer facet we already shipped. The test proves the four moves a UI would
/// have to offer, against real mainnet state:
///   1. many souls INTO the vault in one transaction (the courier, aimed at it);
///   2. all of them OUT in one transaction (the vault calling that same courier);
///   3. souls moved from one reaper's vault straight into another's;
///   4. only the reaper's holder can do any of it.
///
///   ETH_RPC=<url> forge test --match-contract VaultSoulsFork -vv
contract VaultSoulsForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant WHALE = 0x4943407105999e3E97EFA2035F5cbC64D72581C6;
    uint256 constant REAPER_A = 8777;
    uint256 constant REAPER_B = 136;

    bool forked;
    ISoulsV2 souls = ISoulsV2(DIAMOND);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _threeOfWhale() internal view returns (uint256[] memory ids) {
        ids = new uint256[](3);
        uint256 n;
        for (uint256 id = 1; id <= 4000 && n < 3; id++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            if (!ok || ret.length != 32) continue;
            if (abi.decode(ret, (address)) != WHALE) continue;
            if (souls.isReaper(id)) continue; // don't move a reaper into a vault
            ids[n++] = id;
        }
        require(n == 3, "not enough souls");
    }

    function test_fork_stock_and_recover() public {
        if (!forked) return;

        (address vaultA,) = souls.reaperAccount(REAPER_A);
        (address vaultB,) = souls.reaperAccount(REAPER_B);
        address holderA = souls.ownerOf(REAPER_A);
        uint256[] memory ids = _threeOfWhale();

        // 1. IN — the courier, aimed at the reaper's own vault. One transaction.
        vm.prank(WHALE);
        souls.batchTransfer(vaultA, ids);
        for (uint256 i; i < 3; i++) assertEq(souls.ownerOf(ids[i]), vaultA, "soul should sit in the vault");

        // 2. OUT — the vault calls the same courier, driven by the reaper's holder.
        vm.prank(holderA);
        IAccount(vaultA).execute(
            DIAMOND, 0, abi.encodeWithSelector(ISoulsV2.batchTransfer.selector, holderA, ids), 0
        );
        for (uint256 i; i < 3; i++) assertEq(souls.ownerOf(ids[i]), holderA, "and back out, all three");

        // 3. SIDEWAYS — straight from one reaper's vault into another's.
        vm.prank(holderA);
        souls.batchTransfer(vaultA, ids);
        vm.prank(holderA);
        IAccount(vaultA).execute(
            DIAMOND, 0, abi.encodeWithSelector(ISoulsV2.batchTransfer.selector, vaultB, ids), 0
        );
        for (uint256 i; i < 3; i++) assertEq(souls.ownerOf(ids[i]), vaultB, "moved to the other reaper");

        // 4. nobody else can empty a vault
        vm.prank(makeAddr("thief"));
        vm.expectRevert();
        IAccount(vaultB).execute(
            DIAMOND, 0, abi.encodeWithSelector(ISoulsV2.batchTransfer.selector, makeAddr("thief"), ids), 0
        );

        console.log("vault A", vaultA);
        console.log("vault B", vaultB);
    }

    /// The one move that must never be offered: a reaper into its OWN vault.
    /// safeTransferFrom is blocked by the account's cycle guard; plain
    /// transferFrom is NOT, and would seal the token inside itself forever.
    function test_fork_self_custody_is_the_trap() public {
        if (!forked) return;
        (address vaultA,) = souls.reaperAccount(REAPER_A);
        address holderA = souls.ownerOf(REAPER_A);

        vm.prank(holderA);
        vm.expectRevert(); // the guard does its job on the safe path
        souls.safeTransferFrom(holderA, vaultA, REAPER_A);

        // and on the unsafe path it goes through — which is why the UI must refuse it
        vm.prank(holderA);
        souls.transferFrom(holderA, vaultA, REAPER_A);
        assertEq(souls.ownerOf(REAPER_A), vaultA);
        assertEq(IAccount(vaultA).owner(), vaultA, "the reaper now owns itself: bricked");
    }
}
