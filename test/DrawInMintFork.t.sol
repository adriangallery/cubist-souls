// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ConvertFacetV4} from "../src/facets/ConvertFacetV4.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface IDia {
    function owner() external view returns (address);
    function priceNow() external view returns (uint256);
    function convert(uint256[] calldata ids) external payable;
    function orderPot() external view returns (uint256);
    function pendingDraw() external view returns (uint64, bool, uint256);
    function lastDraw() external view returns (uint256, uint64);
    function vaultOf(uint256 id) external view returns (address);
    function orderRoster() external view returns (uint256[] memory);
    function ownerOf(uint256 id) external view returns (address);
    function withdraw() external;
    function treasury() external view returns (address);
}

interface IPik {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

/// A vault that refuses ETH, to prove a bad payout can never break a mint.
contract Refuser {
    receive() external payable {
        revert("no");
    }
}

/// THE DRAW RIDES THE MINT — against real mainnet state.
///
/// One burn opens the draw, the next burn settles it. No keeper, no schedule,
/// no extra transaction. What must hold:
///   • the first mint after the upgrade opens a draw and pays nobody;
///   • the second mint pays the winner the first mint's half;
///   • the minter cannot influence who wins (it was fixed by an earlier block);
///   • and a refusing vault does NOT stop anyone from minting.
///
///   ETH_RPC=<url> forge test --match-contract DrawInMintFork -vv
contract DrawInMintForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    bool forked;
    IDia d = IDia(DIAMOND);
    uint256 nextCanvas = 1;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        ConvertFacetV4 v4 = new ConvertFacetV4();
        bytes4[] memory rep = new bytes4[](3);
        rep[0] = ConvertFacet.convert.selector;
        rep[1] = bytes4(keccak256("withdraw()"));
        rep[2] = bytes4(keccak256("withdraw(address)"));
        bytes4[] memory add = new bytes4[](1);
        add[0] = ConvertFacetV4.setDrawInMint.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: address(v4), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: rep});
        cuts[1] = IDiamondCut.FacetCut({facetAddress: address(v4), action: IDiamondCut.FacetCutAction.Add, functionSelectors: add});
        vm.prank(d.owner());
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
    }

    /// burn one live canvas as its real holder
    function _mintOne() internal returns (uint256 paid) {
        uint256 price = d.priceNow();
        for (uint256 i = nextCanvas; i <= 4000; i++) {
            (bool ok, bytes memory ret) = PIKKAZO.staticcall(abi.encodeWithSignature("ownerOf(uint256)", i));
            if (!ok || ret.length != 32) continue;
            address h = abi.decode(ret, (address));
            if (h == address(0) || h.code.length > 0) continue;
            nextCanvas = i + 1;
            uint256[] memory ids = new uint256[](1);
            ids[0] = i;
            vm.deal(h, 1 ether);
            vm.startPrank(h);
            IPik(PIKKAZO).setApprovalForAll(DIAMOND, true);
            d.convert{value: price}(ids);
            vm.stopPrank();
            return price;
        }
        revert("no canvas left");
    }

    function test_fork_one_mint_opens_the_next_one_settles() public {
        if (!forked) return;
        uint256 potAtStart = d.orderPot(); // the live pot: mints already happened
        (uint256 lastWinnerAtStart,) = d.lastDraw();

        // FIRST BURN — accumulates and commits a draw. Nobody is paid yet.
        uint256 paid = _mintOne();
        assertEq(d.orderPot(), potAtStart + paid / 2, "half set aside");
        (uint64 target, bool settleable,) = d.pendingDraw();
        assertGt(target, 0, "a draw is committed");
        assertFalse(settleable, "to a block that has not happened");
        (uint256 winnerBefore,) = d.lastDraw();
        assertEq(winnerBefore, lastWinnerAtStart, "nobody new has won yet");

        // the committed block happens
        vm.roll(vm.getBlockNumber() + 3);

        // SECOND BURN — settles the first one's half, then sets aside its own.
        uint256 owed = d.orderPot();
        uint256 paid2 = _mintOne();

        (uint256 winner, uint64 at) = d.lastDraw();
        assertGt(winner, 0, "the second burn paid somebody");
        assertTrue(winner != lastWinnerAtStart || lastWinnerAtStart == 0 || at > 0);
        assertGt(at, 0);
        address vault = d.vaultOf(winner);
        assertEq(vault.balance, owed, "the winner got the FIRST burn's half");
        assertEq(d.orderPot(), paid2 / 2, "and the second burn's half is now waiting");

        (uint64 target2, bool s2,) = d.pendingDraw();
        assertGt(target2, 0, "with the next draw already committed");
        assertFalse(s2);
        console.log("winner", winner);
        console.log("vault", vault);
    }

    /// The result is fixed before the settling minter arrives: whoever mints
    /// second, the winner is the same.
    function test_fork_the_settler_cannot_change_the_outcome() public {
        if (!forked) return;
        _mintOne();
        vm.roll(vm.getBlockNumber() + 3);

        uint256 snap = vm.snapshotState();
        _mintOne();
        (uint256 winnerA,) = d.lastDraw();

        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 5); // a different, later settler
        _mintOne();
        (uint256 winnerB,) = d.lastDraw();

        assertEq(winnerA, winnerB, "the block that decided it was already mined");
    }

    /// A vault that refuses money must not be able to block the collection.
    function test_fork_a_refusing_vault_never_blocks_a_mint() public {
        if (!forked) return;
        uint256[] memory roster = d.orderRoster();
        for (uint256 i; i < roster.length; i++) {
            vm.etch(d.vaultOf(roster[i]), address(new Refuser()).code);
        }

        _mintOne();
        vm.roll(vm.getBlockNumber() + 3);
        uint256 owed = d.orderPot();

        uint256 paid2 = _mintOne(); // must NOT revert
        assertEq(d.orderPot(), owed + paid2 / 2, "the share waits for the next mint");
        (uint256 winner,) = d.lastDraw();
        assertEq(winner, 0, "no winner recorded when the payout failed");
    }

    /// And the museum's sweep still cannot touch the Order's share.
    function test_fork_sweep_still_respects_the_share() public {
        if (!forked) return;
        _mintOne();
        uint256 owed = d.orderPot();
        vm.prank(d.owner());
        d.withdraw();
        assertEq(DIAMOND.balance, owed);
        assertEq(d.orderPot(), owed);
    }
}
