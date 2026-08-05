// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {OrderPotFacet} from "../src/facets/OrderPotFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// Unit tests for the Order's pot: membership, the accounting invariant, the
/// two-step draw, and the weighting that makes feeding a reaper worth doing.
///
/// The canonical ERC-6551 registry is etched with its real mainnet bytecode so
/// vault addresses are the genuine CREATE2 ones.
contract OrderPotTest is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes constant REGISTRY_CODE =
        hex"608060405234801561001057600080fd5b50600436106100365760003560e01c8063246a00211461003b5780638a54c52f1461006a575b600080fd5b61004e6100493660046101b7565b61007d565b6040516001600160a01b03909116815260200160405180910390f35b61004e6100783660046101b7565b6100e1565b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b60015284601552605560002060601b60601c60005260206000f35b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b600152846015526055600020803b61018b578560b760556000f580610157576320188a596000526004601cfd5b80606c52508284887f79f19b3655ee38b1ce526556b7731a20c8f218fbda4a3990b6cc4172fdf887226060606ca46020606cf35b8060601b60601c60005260206000f35b80356001600160a01b03811681146101b257600080fd5b919050565b600080600080600060a086880312156101cf57600080fd5b6101d88661019b565b945060208601359350604086013592506101f46060870161019b565b94979396509194608001359291505056fea2646970667358221220ea2fe53af507453c64dd7c1db05549fa47a298dfb825d6d11e1689856135f16764736f6c63430008110033";

    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    ReaperFacet reaper;
    OrderPotFacet pot;

    uint256 constant R1 = 3001; // becomes a reaper
    uint256 constant R2 = 3002; // becomes a reaper
    uint256 constant PLAIN = 3003; // stays a plain soul

    function setUp() public {
        vm.etch(REGISTRY, REGISTRY_CODE);
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();
        _cutReaper();
        _cutPot();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        reaper = ReaperFacet(diamond);
        pot = OrderPotFacet(diamond);

        // three souls for the holder + 200 canvases to feed the fire
        pikkazo.mint(holder, R1);
        pikkazo.mint(holder, R2);
        pikkazo.mint(holder, PLAIN);
        for (uint256 i = 100; i < 300; i++) pikkazo.mint(holder, i);
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = R1;
        ids[1] = R2;
        ids[2] = PLAIN;
        conv.convert(ids);
        reaper.offer(R1, _range(100, 30)); // ascends
        reaper.offer(R2, _range(130, 30)); // ascends
        vm.stopPrank();
        assertTrue(reaper.isReaper(R1) && reaper.isReaper(R2));
    }

    function _cutReaper() internal {
        ReaperFacet f = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        bytes4[] memory s = new bytes4[](3);
        s[0] = ReaperFacet.offer.selector;
        s[1] = ReaperFacet.soulsConsumed.selector;
        s[2] = ReaperFacet.isReaper.selector;
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](1);
        c[0] = IDiamondCut.FacetCut({facetAddress: address(f), action: IDiamondCut.FacetCutAction.Add, functionSelectors: s});
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(c, address(initC), abi.encodeCall(ReaperInit.init, ()));
    }

    function _cutPot() internal {
        OrderPotFacet f = new OrderPotFacet();
        bytes4[] memory s = new bytes4[](9);
        s[0] = OrderPotFacet.registerReaper.selector;
        s[1] = OrderPotFacet.creditOrder.selector;
        s[2] = OrderPotFacet.openDraw.selector;
        s[3] = OrderPotFacet.settleDraw.selector;
        s[4] = OrderPotFacet.orderPot.selector;
        s[5] = OrderPotFacet.orderRoster.selector;
        s[6] = OrderPotFacet.weightOf.selector;
        s[7] = OrderPotFacet.totalWeight.selector;
        s[8] = OrderPotFacet.vaultOf.selector;
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](1);
        c[0] = IDiamondCut.FacetCut({facetAddress: address(f), action: IDiamondCut.FacetCutAction.Add, functionSelectors: s});
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(c, address(0), "");

        bytes4[] memory s2 = new bytes4[](2);
        s2[0] = OrderPotFacet.pendingDraw.selector;
        s2[1] = OrderPotFacet.lastDraw.selector;
        c[0] = IDiamondCut.FacetCut({facetAddress: address(f), action: IDiamondCut.FacetCutAction.Add, functionSelectors: s2});
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(c, address(0), "");
    }

    function _range(uint256 s, uint256 n) internal pure returns (uint256[] memory x) {
        x = new uint256[](n);
        for (uint256 i; i < n; i++) x[i] = s + i;
    }

    function _register() internal {
        pot.registerReaper(R1);
        pot.registerReaper(R2);
    }

    // ------------------------------------------------------------ membership

    function test_only_ascended_can_register_and_only_once() public {
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.NotAscended.selector, PLAIN));
        pot.registerReaper(PLAIN);

        pot.registerReaper(R1); // permissionless: any caller
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.AlreadyRegistered.selector, R1));
        pot.registerReaper(R1);
        assertEq(pot.orderRoster().length, 1);
    }

    // ------------------------------------------------------ the pot invariant

    function test_cannot_earmark_money_that_is_not_there() public {
        vm.deal(diamond, 1 ether);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.InsufficientBalance.selector, 1 ether, 1 ether + 1));
        pot.creditOrder(1 ether + 1);

        vm.prank(owner_);
        pot.creditOrder(0.6 ether);
        // the rest is still the museum's, and cannot be double-earmarked
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.InsufficientBalance.selector, 0.4 ether, 0.5 ether));
        pot.creditOrder(0.5 ether);
        assertEq(pot.orderPot(), 0.6 ether);
    }

    function test_credit_is_owner_only() public {
        vm.deal(diamond, 1 ether);
        vm.prank(holder);
        vm.expectRevert();
        pot.creditOrder(0.1 ether);
    }

    // -------------------------------------------------------------- the draw

    function test_draw_pays_the_whole_pot_to_a_members_vault() public {
        _register();
        vm.deal(diamond, 1 ether);
        vm.prank(owner_);
        pot.creditOrder(0.4 ether);

        pot.openDraw();
        (uint64 target, bool settleable,) = pot.pendingDraw();
        assertFalse(settleable, "cannot settle in the same block it was opened");
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.TooEarly.selector, target));
        pot.settleDraw();

        vm.roll(vm.getBlockNumber() + 3);
        (uint256 winner, address vault, uint256 amount) = pot.settleDraw();
        assertTrue(winner == R1 || winner == R2, "winner is a member");
        assertEq(vault, pot.vaultOf(winner));
        assertEq(amount, 0.4 ether);
        assertEq(vault.balance, 0.4 ether, "the vault got paid");
        assertEq(pot.orderPot(), 0, "pot emptied");
        assertEq(address(diamond).balance, 0.6 ether, "the museum keeps its half");

        (uint64 db,,) = pot.pendingDraw();
        assertEq(db, 0, "no draw left open");
    }

    function test_cannot_open_twice_or_settle_without_a_draw() public {
        _register();
        vm.deal(diamond, 1 ether);
        vm.prank(owner_);
        pot.creditOrder(0.1 ether);

        vm.expectRevert(OrderPotFacet.NoDrawOpen.selector);
        pot.settleDraw();

        pot.openDraw();
        vm.expectRevert(OrderPotFacet.DrawAlreadyOpen.selector);
        pot.openDraw();
    }

    function test_empty_pot_or_roster_cannot_open() public {
        vm.expectRevert(OrderPotFacet.EmptyPot.selector);
        pot.openDraw();

        vm.deal(diamond, 1 ether);
        vm.prank(owner_);
        pot.creditOrder(0.1 ether);
        vm.expectRevert(OrderPotFacet.EmptyRoster.selector);
        pot.openDraw();
    }

    /// Late settlement: past 256 blocks the hash is gone, so it reopens rather
    /// than settling on a zero hash (which would always pick the same member).
    function test_expired_draw_reopens() public {
        _register();
        vm.deal(diamond, 1 ether);
        vm.prank(owner_);
        pot.creditOrder(0.1 ether);
        pot.openDraw();
        vm.roll(vm.getBlockNumber() + 300);
        vm.expectRevert(OrderPotFacet.DrawExpired.selector);
        pot.settleDraw();
    }

    // ------------------------------------------------------------- weighting

    function test_weight_is_one_plus_the_souls_the_vault_holds() public {
        _register();
        assertEq(pot.weightOf(R1), 1, "an empty reaper still has a chance");
        assertEq(pot.weightOf(R2), 1);
        assertEq(pot.totalWeight(), 2);
        assertEq(pot.weightOf(PLAIN), 0, "outsiders have no weight");

        // feed R1: send it a soul (resolve the vault BEFORE pranking — an
        // external call in the argument list would eat the prank)
        address v1 = pot.vaultOf(R1);
        vm.prank(holder);
        souls.transferFrom(holder, v1, PLAIN);
        assertEq(pot.weightOf(R1), 2, "one soul, one extra ticket");
        assertEq(pot.totalWeight(), 3);
    }

    /// With every ticket but one on a single reaper, the draw must land on it —
    /// this is what makes feeding your reaper mean something.
    function test_a_well_fed_reaper_wins() public {
        _register();
        // move 30 souls into R1's vault (freed from canvases 200..229)
        vm.startPrank(holder);
        uint256[] memory more = _range(200, 30);
        conv.convert(more);
        address v1 = pot.vaultOf(R1);
        for (uint256 i; i < more.length; i++) souls.transferFrom(holder, v1, more[i]);
        vm.stopPrank();

        assertEq(pot.weightOf(R1), 31);
        assertEq(pot.weightOf(R2), 1);
        assertEq(pot.totalWeight(), 32);

        // 32 tickets, 31 of them R1's: over several draws R1 takes nearly all
        uint256 winsR1;
        for (uint256 i; i < 8; i++) {
            vm.deal(diamond, 1 ether);
            vm.prank(owner_);
            pot.creditOrder(0.01 ether);
            pot.openDraw();
            vm.roll(vm.getBlockNumber() + 3);
            (uint256 w,,) = pot.settleDraw();
            if (w == R1) winsR1++;
        }
        assertGe(winsR1, 6, "the fed reaper should dominate the draw");
    }
}
