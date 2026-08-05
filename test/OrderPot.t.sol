// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV3} from "../src/facets/ConvertFacetV3.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {OrderPotFacet} from "../src/facets/OrderPotFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// The Order's half: how it is earned, how it cannot be tampered with, and how
/// it is drawn.
///
/// The property Adrian asked for out loud is the one this file is built around:
/// money that is NOT the Order's must never reach a reaper. So the pot has
/// exactly ONE source — a paid mint, crediting exactly half, inside the mint
/// itself — and exactly ONE exit: a settled draw. No function credits it by
/// hand, and withdraw() cannot carry it away. Both are asserted here; the
/// adversarial attempts live in OrderPotExploit.t.sol.
contract OrderPotTest is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes constant REGISTRY_CODE =
        hex"608060405234801561001057600080fd5b50600436106100365760003560e01c8063246a00211461003b5780638a54c52f1461006a575b600080fd5b61004e6100493660046101b7565b61007d565b6040516001600160a01b03909116815260200160405180910390f35b61004e6100783660046101b7565b6100e1565b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b60015284601552605560002060601b60601c60005260206000f35b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b600152846015526055600020803b61018b578560b760556000f580610157576320188a596000526004601cfd5b80606c52508284887f79f19b3655ee38b1ce526556b7731a20c8f218fbda4a3990b6cc4172fdf887226060606ca46020606cf35b8060601b60601c60005260206000f35b80356001600160a01b03811681146101b257600080fd5b919050565b600080600080600060a086880312156101cf57600080fd5b6101d88661019b565b945060208601359350604086013592506101f46060870161019b565b94979396509194608001359291505056fea2646970667358221220ea2fe53af507453c64dd7c1db05549fa47a298dfb825d6d11e1689856135f16764736f6c63430008110033";

    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address treasury = makeAddr("treasury");

    SoulsERC721Facet souls;
    ConvertFacetV3 conv;
    ReaperFacet reaper;
    OrderPotFacet pot;

    uint256 constant PRICE = 0.01 ether;
    uint256 constant R1 = 3001;
    uint256 constant R2 = 3002;
    uint256 constant PLAIN = 3003;

    function setUp() public {
        vm.etch(REGISTRY, REGISTRY_CODE);
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();
        _cutReaper();
        _cutConvertV3();
        _cutPot();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacetV3(diamond);
        reaper = ReaperFacet(diamond);
        pot = OrderPotFacet(diamond);

        pikkazo.mint(holder, R1);
        pikkazo.mint(holder, R2);
        pikkazo.mint(holder, PLAIN);
        for (uint256 i = 100; i < 400; i++) pikkazo.mint(holder, i);
        vm.deal(holder, 100 ether);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = R1;
        ids[1] = R2;
        ids[2] = PLAIN;
        conv.convert{value: 3 * PRICE}(ids);
        reaper.offer(R1, _range(100, 30));
        reaper.offer(R2, _range(130, 30));
        vm.stopPrank();
        assertTrue(reaper.isReaper(R1) && reaper.isReaper(R2));
    }

    // ------------------------------------------------------------- cut wiring

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

    function _cutConvertV3() internal {
        ConvertFacetV3 v3 = new ConvertFacetV3();
        ConvertV2Init initC = new ConvertV2Init();
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector;
        bytes4[] memory add = new bytes4[](5);
        add[0] = ConvertFacetV3.priceNow.selector;
        add[1] = ConvertFacetV3.pricing.selector;
        add[2] = bytes4(keccak256("withdraw()"));
        add[3] = bytes4(keccak256("withdraw(address)"));
        add[4] = ConvertFacetV3.setPricing.selector;
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](2);
        c[0] = IDiamondCut.FacetCut({facetAddress: address(v3), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: rep});
        c[1] = IDiamondCut.FacetCut({facetAddress: address(v3), action: IDiamondCut.FacetCutAction.Add, functionSelectors: add});
        vm.prank(owner_);
        // no free window: price1 applies from the first second
        IDiamondCut(diamond).diamondCut(
            c,
            address(initC),
            abi.encodeCall(
                ConvertV2Init.init, (uint64(block.timestamp), 0, 365 days, 730 days, PRICE, PRICE, PRICE, treasury)
            )
        );
    }

    function _cutPot() internal {
        OrderPotFacet f = new OrderPotFacet();
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](1);

        bytes4[] memory s = new bytes4[](6);
        s[0] = OrderPotFacet.registerReaper.selector;
        s[1] = OrderPotFacet.openDraw.selector;
        s[2] = OrderPotFacet.settleDraw.selector;
        s[3] = OrderPotFacet.orderPot.selector;
        s[4] = OrderPotFacet.orderRoster.selector;
        s[5] = OrderPotFacet.weightOf.selector;
        c[0] = IDiamondCut.FacetCut({facetAddress: address(f), action: IDiamondCut.FacetCutAction.Add, functionSelectors: s});
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(c, address(0), "");

        bytes4[] memory s2 = new bytes4[](6);
        s2[0] = OrderPotFacet.totalWeight.selector;
        s2[1] = OrderPotFacet.pendingDraw.selector;
        s2[2] = OrderPotFacet.lastDraw.selector;
        s2[3] = OrderPotFacet.vaultOf.selector;
        s2[4] = OrderPotFacet.weightParams.selector;
        s2[5] = OrderPotFacet.setWeightParams.selector;
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

    /// Mint souls the way a holder does — the pot's only source.
    function _mint(uint256 start, uint256 n) internal {
        vm.prank(holder);
        conv.convert{value: n * PRICE}(_range(start, n));
    }

    // ---------------------------------------------------- the pot's ONE source

    function test_a_paid_mint_credits_exactly_half() public {
        uint256 before = pot.orderPot();
        _mint(200, 4);
        assertEq(pot.orderPot() - before, (4 * PRICE) / 2, "half of what was charged");
    }

    function test_the_setup_mint_already_credited_half() public {
        assertEq(pot.orderPot(), (3 * PRICE) / 2, "three souls freed in setUp");
    }

    /// Overpaying does not enlarge the Order's share: the excess is refunded and
    /// was never revenue.
    function test_overpayment_is_refunded_and_not_shared() public {
        uint256 before = pot.orderPot();
        uint256 bal = holder.balance;
        vm.prank(holder);
        conv.convert{value: 5 ether}(_range(210, 2));
        assertEq(pot.orderPot() - before, (2 * PRICE) / 2, "only the price counts");
        assertEq(holder.balance, bal - 2 * PRICE, "the rest came back");
    }

    /// There is no hand-credit path at all — the selector does not exist.
    function test_there_is_no_way_to_credit_by_hand() public {
        vm.prank(owner_);
        (bool ok,) = diamond.call(abi.encodeWithSignature("creditOrder(uint256)", uint256(1 ether)));
        assertFalse(ok, "creditOrder must not exist on the diamond");
    }

    // ------------------------------------------- the museum cannot take it

    function test_withdraw_leaves_the_orders_share_behind() public {
        _mint(200, 10); // 0.1 charged -> 0.05 to the Order
        uint256 owed = pot.orderPot();

        // royalties and other income arrive OUTSIDE convert: all of it is the museum's
        (bool sent,) = diamond.call{value: 0.3 ether}("");
        assertTrue(sent);

        uint256 diamondBal = diamond.balance;
        vm.prank(owner_);
        ConvertFacetV3(diamond).withdraw();

        assertEq(treasury.balance, diamondBal - owed, "the museum swept only its own");
        assertEq(diamond.balance, owed, "the Order's share stayed");
        assertEq(pot.orderPot(), owed, "and is still owed");
    }

    function test_the_pot_survives_repeated_withdrawals() public {
        _mint(200, 6);
        uint256 owed = pot.orderPot();
        for (uint256 i; i < 3; i++) {
            vm.prank(owner_);
            ConvertFacetV3(diamond).withdraw();
        }
        assertEq(diamond.balance, owed);
        assertEq(pot.orderPot(), owed);
    }

    // ------------------------------------------------------------ membership

    function test_only_ascended_can_register_and_only_once() public {
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.NotAscended.selector, PLAIN));
        pot.registerReaper(PLAIN);
        pot.registerReaper(R1);
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.AlreadyRegistered.selector, R1));
        pot.registerReaper(R1);
        assertEq(pot.orderRoster().length, 1);
    }

    // -------------------------------------------------------------- the draw

    function test_draw_pays_the_whole_pot_to_a_members_vault() public {
        _register();
        _mint(200, 10);
        uint256 owed = pot.orderPot();

        pot.openDraw();
        (uint64 target, bool settleable,) = pot.pendingDraw();
        assertFalse(settleable, "never settleable in the block it opened");
        vm.expectRevert(abi.encodeWithSelector(OrderPotFacet.TooEarly.selector, target));
        pot.settleDraw();

        vm.roll(vm.getBlockNumber() + 3);
        (uint256 winner, address vault, uint256 amount) = pot.settleDraw();
        assertTrue(winner == R1 || winner == R2);
        assertEq(vault, pot.vaultOf(winner));
        assertEq(amount, owed);
        assertEq(vault.balance, owed, "paid into the reaper's own vault");
        assertEq(pot.orderPot(), 0);
    }

    function test_cannot_open_twice_or_settle_without_a_draw() public {
        _register();
        _mint(200, 2);
        vm.expectRevert(OrderPotFacet.NoDrawOpen.selector);
        pot.settleDraw();
        pot.openDraw();
        vm.expectRevert(OrderPotFacet.DrawAlreadyOpen.selector);
        pot.openDraw();
    }

    function test_no_roster_no_draw() public {
        _mint(200, 1);
        vm.expectRevert(OrderPotFacet.EmptyRoster.selector);
        pot.openDraw();
    }

    function test_expired_draw_reopens() public {
        _register();
        _mint(200, 2);
        pot.openDraw();
        vm.roll(vm.getBlockNumber() + 300);
        vm.expectRevert(OrderPotFacet.DrawExpired.selector);
        pot.settleDraw();
    }

    // ------------------------------------------------------------- weighting

    function test_weight_is_the_reaper_first_and_the_souls_second() public {
        _register();
        (uint16 base, uint16 cap) = pot.weightParams();
        assertEq(base, 100, "being a reaper is the weight");
        assertEq(cap, 30, "and thirty souls is all the tilt there is");

        assertEq(pot.weightOf(R1), 100, "a bare reaper is a full member");
        assertEq(pot.totalWeight(), 200);
        assertEq(pot.weightOf(PLAIN), 0, "outsiders have no weight");

        address v1 = pot.vaultOf(R1);
        vm.prank(holder);
        souls.transferFrom(holder, v1, PLAIN);
        assertEq(pot.weightOf(R1), 101, "one soul, one ticket");
    }

    /// Souls tilt the draw; they cannot buy it. Thirty and sixty are worth the
    /// same, and the best-fed reaper only outweighs a bare one 130 to 100.
    function test_souls_cannot_buy_the_draw() public {
        _register();
        address v1 = pot.vaultOf(R1);
        _mint(200, 30);
        _mint(230, 30);

        vm.startPrank(holder);
        for (uint256 i; i < 30; i++) souls.transferFrom(holder, v1, 200 + i);
        vm.stopPrank();
        assertEq(pot.weightOf(R1), 130, "thirty souls: the most a reaper can gain");

        vm.startPrank(holder);
        for (uint256 i; i < 30; i++) souls.transferFrom(holder, v1, 230 + i);
        vm.stopPrank();
        assertEq(pot.weightOf(R1), 130, "sixty souls buy nothing further");
        assertEq(pot.totalWeight(), 230);
    }

    function test_weight_params_are_tunable_by_the_owner_only() public {
        _register();
        vm.prank(holder);
        vm.expectRevert();
        pot.setWeightParams(10, 5);

        vm.prank(owner_);
        vm.expectRevert(OrderPotFacet.BadWeightParams.selector);
        pot.setWeightParams(0, 5);

        vm.prank(owner_);
        pot.setWeightParams(50, 10);
        (uint16 base, uint16 cap) = pot.weightParams();
        assertEq(base, 50);
        assertEq(cap, 10);
        assertEq(pot.weightOf(R1), 50);

        vm.prank(owner_);
        pot.setWeightParams(100, 0);
        address v1 = pot.vaultOf(R1);
        vm.prank(holder);
        souls.transferFrom(holder, v1, PLAIN);
        assertEq(pot.weightOf(R1), 100, "no bonus configured, no tilt");
    }

    receive() external payable {}
}
