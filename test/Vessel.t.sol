// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {VesselFacet} from "../src/facets/VesselFacet.sol";
import {VesselInit} from "../src/upgradeInitializers/VesselInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// Unit tests for VesselFacet — the union of thirty: gate checks, custody lock,
/// the deliberate rescue-guard bypass, fee accounting, attribution.
///
/// The canonical ERC-6551 registry is vm.etch'd with its REAL mainnet bytecode
/// (same approach as ReaperAccount.t.sol); the Tokenbound proxy/V3 behavior is
/// covered by VesselFork.t.sol against mainnet.
contract VesselTest is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes constant REGISTRY_CODE =
        hex"608060405234801561001057600080fd5b50600436106100365760003560e01c8063246a00211461003b5780638a54c52f1461006a575b600080fd5b61004e6100493660046101b7565b61007d565b6040516001600160a01b03909116815260200160405180910390f35b61004e6100783660046101b7565b6100e1565b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b60015284601552605560002060601b60601c60005260206000f35b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b600152846015526055600020803b61018b578560b760556000f580610157576320188a596000526004601cfd5b80606c52508284887f79f19b3655ee38b1ce526556b7731a20c8f218fbda4a3990b6cc4172fdf887226060606ca46020606cf35b8060601b60601c60005260206000f35b80356001600160a01b03811681146101b257600080fd5b919050565b600080600080600060a086880312156101cf57600080fd5b6101d88661019b565b945060208601359350604086013592506101f46060870161019b565b94979396509194608001359291505056fea2646970667358221220ea2fe53af507453c64dd7c1db05549fa47a298dfb825d6d11e1689856135f16764736f6c63430008110033";

    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address other = makeAddr("other");
    address treasury = makeAddr("treasury");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    ConvertFacetV2 convV2;
    ReaperFacet reaper;
    VesselFacet vessel;

    uint256 constant FEE = 0.0005 ether;
    uint256 constant CANVAS = 900; // pikkazo the holder offers to a reaper -> consumed
    uint256 constant CANVAS2 = 901; // second consumed canvas, for collision tests
    uint256 constant FIRE_SOUL = 700; // soul that consumed 1 canvas (carries fire)

    // ConvertFacetV2 pricing knobs (free window active for all converts here)
    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;

    event VesselFused(
        uint256 indexed vesselId, address indexed founder, address vault, string name, uint256[] members
    );
    event VesselRenamed(uint256 indexed vesselId, string name);

    uint256[] thirty; // souls 1..30, holder's, consumed == 0

    function setUp() public {
        vm.etch(REGISTRY, REGISTRY_CODE);

        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _applyReaperCut();
        _applyConvertV2Cut(uint64(block.timestamp));
        _applyVesselCut();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        convV2 = ConvertFacetV2(diamond);
        reaper = ReaperFacet(diamond);
        vessel = VesselFacet(diamond);

        // 32 souls for the holder (1..30 the union + FIRE_SOUL + one spare 31),
        // plus canvases 900/901 to consume, plus a soul for `other`.
        vm.deal(holder, 1 ether);
        vm.deal(other, 1 ether);
        for (uint256 i = 1; i <= 31; i++) {
            pikkazo.mint(holder, i);
        }
        pikkazo.mint(holder, FIRE_SOUL);
        pikkazo.mint(holder, CANVAS);
        pikkazo.mint(holder, CANVAS2);
        pikkazo.mint(other, 555);

        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i = 1; i <= 31; i++) {
            ids[i - 1] = i;
        }
        ids[31] = FIRE_SOUL;
        convV2.convert(ids); // free window: 32 souls
        // FIRE_SOUL eats both spare canvases -> consumed == 2, canvases 900/901 consumed
        uint256[] memory canv = new uint256[](2);
        canv[0] = CANVAS;
        canv[1] = CANVAS2;
        reaper.offer(FIRE_SOUL, canv);
        vm.stopPrank();

        vm.startPrank(other);
        pikkazo.setApprovalForAll(diamond, true);
        convV2.convert(_arr(555));
        vm.stopPrank();

        for (uint256 i = 1; i <= 30; i++) {
            thirty.push(i);
        }
    }

    // ------------------------------------------------------------ cut wiring

    function _applyReaperCut() internal {
        ReaperFacet facet = new ReaperFacet();
        ReaperInit initC = new ReaperInit();
        bytes4[] memory s = new bytes4[](3);
        s[0] = ReaperFacet.offer.selector;
        s[1] = ReaperFacet.soulsConsumed.selector;
        s[2] = ReaperFacet.isReaper.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(initC), abi.encodeCall(ReaperInit.init, ()));
    }

    function _applyConvertV2Cut(uint64 start) internal {
        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();
        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector;
        bytes4[] memory add = new bytes4[](6);
        add[0] = ConvertFacetV2.freedAt.selector;
        add[1] = ConvertFacetV2.cohortOf.selector;
        add[2] = ConvertFacetV2.treasury.selector;
        add[3] = ConvertFacetV2.setTreasury.selector;
        add[4] = bytes4(keccak256("withdraw()"));
        add[5] = bytes4(keccak256("withdraw(address)"));
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: rep
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(v2),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: add
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(
            cuts, address(initC), abi.encodeCall(ConvertV2Init.init, (start, B1, B2, B3, 0.0001 ether, 0.0003 ether, 0.0005 ether, treasury))
        );
    }

    function _applyVesselCut() internal {
        VesselFacet facet = new VesselFacet();
        VesselInit initC = new VesselInit();
        bytes4[] memory s = new bytes4[](9);
        s[0] = VesselFacet.fuse.selector;
        s[1] = VesselFacet.renameVessel.selector;
        s[2] = VesselFacet.setVesselFee.selector;
        s[3] = VesselFacet.vesselFee.selector;
        s[4] = VesselFacet.isVesselToken.selector;
        s[5] = VesselFacet.vesselNameOf.selector;
        s[6] = VesselFacet.membersOf.selector;
        s[7] = VesselFacet.vesselOf.selector;
        s[8] = VesselFacet.custodianOf.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(initC), abi.encodeCall(VesselInit.init, ()));
        // vesselVault view rides on a 10th selector; separate add keeps arrays honest
        bytes4[] memory s2 = new bytes4[](1);
        s2[0] = VesselFacet.vesselVault.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s2
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    // --------------------------------------------------------------- helpers

    function _arr(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _fuse() internal returns (address vault) {
        vm.prank(holder);
        vault = vessel.fuse{value: FEE}(CANVAS, thirty, "The First Communion");
    }

    // ------------------------------------------------------------ happy path

    function test_fuse_happy() public {
        uint256 balBefore = address(diamond).balance;
        address vault = _fuse();

        // the vessel: minted to founder, marked, named, cohort sealed
        assertEq(souls.ownerOf(CANVAS), holder);
        assertTrue(vessel.isVesselToken(CANVAS));
        assertEq(vessel.vesselNameOf(CANVAS), "The First Communion");
        assertTrue(convV2.freedAt(CANVAS) != 0, "freedAt sealed: no phantom OG");
        assertTrue(convV2.cohortOf(CANVAS) != 0, "vessel must never read as Genesis/OG");

        // custody: all 30 held by the diamond, mapped to the vessel
        for (uint256 i = 1; i <= 30; i++) {
            assertEq(souls.ownerOf(i), diamond);
            assertEq(vessel.vesselOf(i), CANVAS);
        }
        assertEq(vessel.membersOf(CANVAS).length, 30);

        // vault: real registry CREATE2, deployed in the same tx
        (address v, bool deployed) = vessel.vesselVault(CANVAS);
        assertEq(v, vault);
        assertTrue(deployed);

        // the rite fee stays in the museum
        assertEq(address(diamond).balance, balBefore + FEE);
    }

    function test_fee_withdraw_to_treasury() public {
        _fuse();
        uint256 bal = address(diamond).balance;
        vm.prank(owner_);
        ConvertFacetV2(diamond).withdraw();
        assertEq(treasury.balance, bal);
    }

    // -------------------------------------------------------------- the gate

    function test_reverts() public {
        // wrong fee
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.WrongFee.selector, FEE, FEE - 1));
        vessel.fuse{value: FEE - 1}(CANVAS, thirty, "x");

        // wrong count
        uint256[] memory tooFew = new uint256[](29);
        for (uint256 i = 0; i < 29; i++) tooFew[i] = i + 1;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.NeedExactlyThirty.selector, 29));
        vessel.fuse{value: FEE}(CANVAS, tooFew, "x");

        // duplicate member
        uint256[] memory dup = new uint256[](30);
        for (uint256 i = 0; i < 30; i++) dup[i] = i + 1;
        dup[29] = 1;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.AlreadyInUnion.selector, 1));
        vessel.fuse{value: FEE}(CANVAS, dup, "x");

        // not your soul (other's 555 in the list)
        uint256[] memory notMine = new uint256[](30);
        for (uint256 i = 0; i < 29; i++) notMine[i] = i + 1;
        notMine[29] = 555;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.NotYourSoul.selector, 555));
        vessel.fuse{value: FEE}(CANVAS, notMine, "x");

        // a soul that carries fire (consumed > 0) cannot join
        uint256[] memory withFire = new uint256[](30);
        for (uint256 i = 0; i < 29; i++) withFire[i] = i + 1;
        withFire[29] = FIRE_SOUL;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.SoulCarriesFire.selector, FIRE_SOUL));
        vessel.fuse{value: FEE}(CANVAS, withFire, "x");

        // canvas not consumed (a plain unminted id)
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.CanvasNotConsumed.selector, 9999));
        vessel.fuse{value: FEE}(9999, thirty, "x");

        // bad name
        vm.prank(holder);
        vm.expectRevert(VesselFacet.BadName.selector);
        vessel.fuse{value: FEE}(CANVAS, thirty, "");
    }

    function test_canvas_collision_second_fuse_reverts() public {
        _fuse();
        // holder only has soul 31 free now; but the revert fires on the canvas first
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.CanvasTaken.selector, CANVAS));
        vessel.fuse{value: FEE}(CANVAS, thirty, "again");
    }

    function test_fused_soul_cannot_join_second_vessel() public {
        _fuse();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.AlreadyInUnion.selector, 1));
        vessel.fuse{value: FEE}(CANVAS2, thirty, "again");
    }

    function test_vessel_cannot_join_a_vessel() public {
        _fuse();
        uint256[] memory withVessel = new uint256[](30);
        for (uint256 i = 0; i < 29; i++) withVessel[i] = i + 1; // fused already, but vessel check…
        withVessel[29] = CANVAS; // …must fire for the vessel id itself
        vm.prank(holder);
        // members 1..29 hit AlreadyInUnion first — order the list so the vessel id leads
        withVessel[0] = CANVAS;
        withVessel[29] = 31;
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.VesselsCannotJoin.selector, CANVAS));
        vessel.fuse{value: FEE}(CANVAS2, withVessel, "x");
    }

    // ------------------------------------------------------------ the custody

    function test_custody_is_locked_no_path_out() public {
        _fuse();
        // direct transfer: nobody is owner/approved for diamond-held souls
        vm.prank(holder);
        vm.expectRevert();
        souls.transferFrom(diamond, holder, 1);
        // the founder cannot approve what they no longer own
        vm.prank(holder);
        vm.expectRevert();
        souls.approve(holder, 1);
    }

    function test_rescue_guard_untouched_for_soul_mints() public {
        // the ONE bypass is fuse(); the reusable guard still protects LibSouls.mint.
        // CANVAS2 is consumed: converting it must stay impossible forever.
        vm.prank(holder);
        vm.expectRevert(); // MockPikkazo: token burned -> ownerOf reverts inside convert
        convV2.convert(_arr(CANVAS2));
    }

    // ----------------------------------------------------------- attribution

    function test_custodian_follows_vessel_owner() public {
        _fuse();
        assertEq(vessel.custodianOf(1), holder, "fused soul -> vessel owner");
        assertEq(vessel.custodianOf(31), holder, "free soul -> direct owner");

        // sell the vessel: attribution follows, custody unchanged
        vm.prank(holder);
        souls.transferFrom(holder, other, CANVAS);
        assertEq(vessel.custodianOf(1), other);
        assertEq(souls.ownerOf(1), diamond);
    }

    // ---------------------------------------------------------------- plaque

    function test_rename_only_owner() public {
        _fuse();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.NotVesselOwner.selector, CANVAS));
        vessel.renameVessel(CANVAS, "stolen");

        vm.prank(holder);
        vm.expectEmit(true, false, false, true, diamond);
        emit VesselRenamed(CANVAS, "The Choir");
        vessel.renameVessel(CANVAS, "The Choir");
        assertEq(vessel.vesselNameOf(CANVAS), "The Choir");

        // rename is NOT for regular souls
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.NotAVessel.selector, 31));
        vessel.renameVessel(31, "nope");
    }

    // ----------------------------------------------------------------- admin

    function test_fee_is_owner_tunable() public {
        vm.prank(holder);
        vm.expectRevert();
        vessel.setVesselFee(1 ether);

        vm.prank(owner_);
        vessel.setVesselFee(0.001 ether);
        assertEq(vessel.vesselFee(), 0.001 ether);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(VesselFacet.WrongFee.selector, 0.001 ether, FEE));
        vessel.fuse{value: FEE}(CANVAS, thirty, "x");
    }
}
