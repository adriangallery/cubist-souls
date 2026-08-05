// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ConvertFacetV3} from "../src/facets/ConvertFacetV3.sol";
import {OrderPotFacet} from "../src/facets/OrderPotFacet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface IDiamondP {
    function owner() external view returns (address);
    function priceNow() external view returns (uint256);
    function pricing()
        external
        view
        returns (uint64, uint32, uint32, uint32, uint256, uint256, uint256);
    function convert(uint256[] calldata ids) external payable;
    function withdraw() external;
    function treasury() external view returns (address);
    function orderPot() external view returns (uint256);
    function orderRoster() external view returns (uint256[] memory);
    function totalWeight() external view returns (uint256);
    function weightOf(uint256 id) external view returns (uint256);
    function weightParams() external view returns (uint16, uint16);
    function openDraw() external;
    function settleDraw() external returns (uint256, address, uint256);
    function vaultOf(uint256 id) external view returns (address);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IPikkazoP {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

/// THE UPGRADE, against real mainnet state.
///
/// This cut replaces the LIVE mint function, so the bar is: minting must behave
/// exactly as it does today (same price, same refund, same soul), and on top of
/// that the Order's half must appear — taken from what was charged, never from
/// the museum's other income, and never removable by a sweep.
///
///   ETH_RPC=<url> forge test --match-contract OrderPotUpgradeFork -vv
contract OrderPotUpgradeForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;

    bool forked;
    IDiamondP d = IDiamondP(DIAMOND);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _upgrade();
    }

    function _upgrade() internal {
        ConvertFacetV3 v3 = new ConvertFacetV3();
        OrderPotFacet potV2 = new OrderPotFacet();

        bytes4[] memory rep = new bytes4[](3);
        rep[0] = ConvertFacet.convert.selector;
        rep[1] = bytes4(keccak256("withdraw()"));
        rep[2] = bytes4(keccak256("withdraw(address)"));

        bytes4[] memory potRep = new bytes4[](10);
        potRep[0] = OrderPotFacet.registerReaper.selector;
        potRep[1] = OrderPotFacet.openDraw.selector;
        potRep[2] = OrderPotFacet.settleDraw.selector;
        potRep[3] = OrderPotFacet.orderPot.selector;
        potRep[4] = OrderPotFacet.orderRoster.selector;
        potRep[5] = OrderPotFacet.weightOf.selector;
        potRep[6] = OrderPotFacet.totalWeight.selector;
        potRep[7] = OrderPotFacet.pendingDraw.selector;
        potRep[8] = OrderPotFacet.lastDraw.selector;
        potRep[9] = OrderPotFacet.vaultOf.selector;

        bytes4[] memory potAdd = new bytes4[](2);
        potAdd[0] = OrderPotFacet.setWeightParams.selector;
        potAdd[1] = OrderPotFacet.weightParams.selector;

        bytes4[] memory potRemove = new bytes4[](1);
        potRemove[0] = bytes4(keccak256("creditOrder(uint256)"));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: address(v3), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: rep});
        cuts[1] = IDiamondCut.FacetCut({facetAddress: address(potV2), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: potRep});
        cuts[2] = IDiamondCut.FacetCut({facetAddress: address(potV2), action: IDiamondCut.FacetCutAction.Add, functionSelectors: potAdd});
        cuts[3] = IDiamondCut.FacetCut({facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: potRemove});

        vm.prank(d.owner());
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
    }

    function _aLiveCanvas() internal view returns (uint256 id, address holder) {
        for (uint256 i = 1; i <= 3000; i++) {
            (bool ok, bytes memory ret) = PIKKAZO.staticcall(abi.encodeWithSignature("ownerOf(uint256)", i));
            if (!ok || ret.length != 32) continue;
            address h = abi.decode(ret, (address));
            if (h == address(0) || h.code.length > 0) continue;
            return (i, h);
        }
        revert("no canvas");
    }

    function test_fork_minting_still_works_and_credits_half() public {
        if (!forked) return;

        uint256 price = d.priceNow();
        assertEq(price, 0.0003 ether, "the ladder is untouched");
        assertEq(d.orderPot(), 0, "the Order starts owed nothing");

        (uint256 canvas, address holder) = _aLiveCanvas();
        vm.deal(holder, 1 ether);
        uint256 before = holder.balance;
        uint256 diamondBefore = DIAMOND.balance;

        uint256[] memory ids = new uint256[](1);
        ids[0] = canvas;
        vm.startPrank(holder);
        IPikkazoP(PIKKAZO).setApprovalForAll(DIAMOND, true);
        d.convert{value: 1 ether}(ids); // deliberate overpayment
        vm.stopPrank();

        assertEq(d.ownerOf(canvas), holder, "the soul was freed, as always");
        assertEq(holder.balance, before - price, "the excess came back");
        assertEq(DIAMOND.balance, diamondBefore + price, "the museum took the price");
        assertEq(d.orderPot(), price / 2, "and half of it is the Order's");
    }

    function test_fork_sweep_cannot_take_the_orders_half() public {
        if (!forked) return;
        (uint256 canvas, address holder) = _aLiveCanvas();
        vm.deal(holder, 1 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = canvas;
        vm.startPrank(holder);
        IPikkazoP(PIKKAZO).setApprovalForAll(DIAMOND, true);
        d.convert{value: 0.0003 ether}(ids);
        vm.stopPrank();

        uint256 owed = d.orderPot();
        assertGt(owed, 0);
        address treasury = d.treasury();
        uint256 tBefore = treasury.balance;
        uint256 diamondBefore = DIAMOND.balance;

        vm.prank(d.owner());
        d.withdraw();

        assertEq(treasury.balance, tBefore + diamondBefore - owed, "swept only the museum's");
        assertEq(DIAMOND.balance, owed, "the Order's half stayed");
        assertEq(d.orderPot(), owed);
    }

    function test_fork_roster_survives_the_upgrade_and_weights_are_reshaped() public {
        if (!forked) return;
        uint256[] memory roster = d.orderRoster();
        assertEq(roster.length, 15, "the fifteen are still registered");

        (uint16 base, uint16 cap) = d.weightParams();
        assertEq(base, 100);
        assertEq(cap, 30);
        assertEq(d.weightOf(roster[0]), 100, "a bare reaper is a full member now");
        assertEq(d.totalWeight(), 1500, "fifteen equals, before any souls");
    }

    function test_fork_a_real_draw_pays_a_real_vault() public {
        if (!forked) return;
        (uint256 canvas, address holder) = _aLiveCanvas();
        vm.deal(holder, 1 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = canvas;
        vm.startPrank(holder);
        IPikkazoP(PIKKAZO).setApprovalForAll(DIAMOND, true);
        d.convert{value: 0.0003 ether}(ids);
        vm.stopPrank();

        uint256 owed = d.orderPot();
        d.openDraw();
        vm.roll(vm.getBlockNumber() + 3);
        (uint256 winner, address vault, uint256 amount) = d.settleDraw();

        assertEq(amount, owed);
        assertEq(vault.balance, owed, "a real reaper's vault was paid");
        assertEq(d.orderPot(), 0);
        console.log("winner", winner);
        console.log("vault", vault);
    }
}
