// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {RaffleFacet} from "../src/facets/RaffleFacet.sol";
import {LibRaffle} from "../src/libraries/LibRaffle.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// The raffles are configuration, not code: these tests are mostly about the rules
/// that must hold no matter what an occasion is set to — the snapshot can never be in
/// the future, the seed can never be re-rolled, the weights freeze the moment the seed
/// exists, and an excluded wallet counts zero however many souls it holds.
contract RaffleTest is Test {
    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");
    address whale = makeAddr("whale");
    address stranger = makeAddr("stranger");

    RaffleFacet r;

    function setUp() public {
        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        RaffleFacet facet = new RaffleFacet();
        bytes4[] memory sels = new bytes4[](14);
        sels[0] = RaffleFacet.createRaffle.selector;
        sels[1] = RaffleFacet.setWeights.selector;
        sels[2] = RaffleFacet.setPrize.selector;
        sels[3] = RaffleFacet.setHolderBlock.selector;
        sels[4] = RaffleFacet.rearmDraw.selector;
        sels[5] = RaffleFacet.setExcluded.selector;
        sels[6] = RaffleFacet.setGloballyExcluded.selector;
        sels[7] = RaffleFacet.cancelRaffle.selector;
        sels[8] = RaffleFacet.anchorSeed.selector;
        sels[9] = RaffleFacet.publishWinners.selector;
        sels[10] = RaffleFacet.raffleCount.selector;
        sels[11] = RaffleFacet.isExcluded.selector;
        sels[12] = RaffleFacet.ticketsFor.selector;
        sels[13] = RaffleFacet.setCloseBlock.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        r = RaffleFacet(diamond);
        vm.roll(1000); // room for a past snapshot
    }

    function _weights() internal pure returns (LibRaffle.Weights memory) {
        // the first occasion: the reaper tickets plus one entry for simply holding
        return LibRaffle.Weights({
            perConsumedSoul: 1,
            perAscendedReaper: 10, // the perk for going all the way to Soul Reaper
            perHolderWallet: 1,
            perSoulHeld: 0,
            perOGSoulHeld: 0,
            maxPerWallet: 0
        });
    }

    function _create() internal returns (uint256 id) {
        vm.prank(owner_);
        id = r.createRaffle("The first 1/1", "ipfs://placeholder", uint64(block.number - 10), uint64(block.number + 20), uint64(block.number + 25), 1, _weights());
    }

    // --- the two blocks ---

    function test_snapshotMustAlreadyBeMined() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.SnapshotMustBePast.selector, uint64(block.number + 1)));
        r.createRaffle("x", "", uint64(block.number + 1), uint64(block.number + 20), uint64(block.number + 25), 1, _weights());
    }

    function test_drawMustBeInTheFuture() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.CloseMustBeFuture.selector, uint64(block.number)));
        r.createRaffle("x", "", uint64(block.number - 1), uint64(block.number), uint64(block.number + 5), 1, _weights());
    }

    function test_seedCannotBeTakenEarly() public {
        uint256 id = _create();
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.DrawBlockNotReached.selector, id, uint64(1025)));
        r.anchorSeed(id);
    }

    function test_anyoneCanAnchorTheSeed() public {
        uint256 id = _create();
        vm.roll(1030);
        vm.prank(stranger); // deliberately not the owner
        bytes32 seed = r.anchorSeed(id);
        assertTrue(seed != bytes32(0));
    }

    function test_seedCannotBeRerolled() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.AlreadyDrawn.selector, id));
        r.anchorSeed(id);
    }

    function test_windowExpiresAndOwnerCanRearm() public {
        uint256 id = _create();
        vm.roll(1025 + 300); // past the 256-block reach of blockhash
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.DrawWindowExpired.selector, id, uint64(1025)));
        r.anchorSeed(id);

        vm.prank(owner_);
        r.rearmDraw(id, uint64(block.number + 5));
        vm.roll(block.number + 6);
        assertTrue(r.anchorSeed(id) != bytes32(0));
    }

    function test_rearmCannotRerollAnExistingResult() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.AlreadyDrawn.selector, id));
        r.rearmDraw(id, uint64(block.number + 5));
    }

    // --- the rules freeze when the seed lands ---

    function test_weightsFreezeOnceDrawn() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.AlreadyDrawn.selector, id));
        r.setWeights(id, _weights());
    }

    function test_exclusionsFreezeOnceDrawn() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        address[] memory a = new address[](1);
        a[0] = whale;
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.AlreadyDrawn.selector, id));
        r.setExcluded(id, a, true);
    }

    // --- tickets ---

    function test_holderWithoutReaperTicketsStillGetsOne() public {
        uint256 id = _create();
        // 0 consumed, holds 3 souls → the flat entry only
        assertEq(r.ticketsFor(id, holder, 0, 0, 3, 0), 1);
    }

    function test_nonHolderGetsNothing() public {
        uint256 id = _create();
        assertEq(r.ticketsFor(id, stranger, 0, 0, 0, 0), 0);
    }

    function test_consumedSoulsAddOnTop() public {
        uint256 id = _create();
        assertEq(r.ticketsFor(id, whale, 49, 0, 348, 0), 50); // 49 consumed + 1 for holding
    }

    function test_excludedWalletCountsZeroHoweverBigItIs() public {
        uint256 id = _create();
        address[] memory a = new address[](1);
        a[0] = whale;
        vm.prank(owner_);
        r.setExcluded(id, a, true);
        assertTrue(r.isExcluded(id, whale));
        assertEq(r.ticketsFor(id, whale, 49, 0, 348, 0), 0);
    }

    function test_globalExclusionAppliesToEveryRaffle() public {
        uint256 id = _create();
        address[] memory a = new address[](1);
        a[0] = owner_; // the museum's own wallet
        vm.prank(owner_);
        r.setGloballyExcluded(a, true);

        assertEq(r.ticketsFor(id, owner_, 100, 0, 100, 0), 0);
        uint256 id2 = _create(); // a later occasion inherits it
        assertEq(r.ticketsFor(id2, owner_, 100, 0, 100, 0), 0);
    }

    function test_globalExclusionCanBeLifted() public {
        address[] memory a = new address[](1);
        a[0] = owner_;
        vm.startPrank(owner_);
        r.setGloballyExcluded(a, true);
        r.setGloballyExcluded(a, false);
        vm.stopPrank();
        uint256 id = _create();
        assertEq(r.ticketsFor(id, owner_, 0, 0, 1, 0), 1);
    }

    function test_capLimitsAWhale() public {
        vm.prank(owner_);
        uint256 id = r.createRaffle("capped", "", uint64(block.number - 5), uint64(block.number + 10), uint64(block.number + 15), 1,
            LibRaffle.Weights({perConsumedSoul: 1, perAscendedReaper: 0, perHolderWallet: 1, perSoulHeld: 0, perOGSoulHeld: 0, maxPerWallet: 10}));
        assertEq(r.ticketsFor(id, whale, 49, 0, 348, 0), 10);
        assertEq(r.ticketsFor(id, holder, 0, 0, 1, 0), 1); // the cap doesn't touch the small holder
    }

    function test_weightsAreFullyReconfigurable() public {
        // a later occasion that ignores reapers entirely and counts OG souls
        vm.prank(owner_);
        uint256 id = r.createRaffle("OG night", "", uint64(block.number - 5), uint64(block.number + 10), uint64(block.number + 15), 3,
            LibRaffle.Weights({perConsumedSoul: 0, perAscendedReaper: 0, perHolderWallet: 0, perSoulHeld: 0, perOGSoulHeld: 2, maxPerWallet: 0}));
        assertEq(r.ticketsFor(id, whale, 49, 0, 348, 244), 488); // 244 OG × 2, reapers ignored
        assertEq(r.ticketsFor(id, holder, 0, 0, 3, 0), 0); // holds souls but no OG → out
    }

    // --- publishing ---

    function test_winnersNeedTheSeedFirst() public {
        uint256 id = _create();
        address[] memory w = new address[](1);
        w[0] = holder;
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.NotDrawnYet.selector, id));
        r.publishWinners(id, w, keccak256("list"));
    }

    function test_winnerCountMustMatchTheAnnouncedOne() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        address[] memory w = new address[](2);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.WrongWinnerCount.selector, 1, 2));
        r.publishWinners(id, w, keccak256("list"));
    }

    function test_winnersCanOnlyBePublishedOnce() public {
        uint256 id = _create();
        vm.roll(1030);
        r.anchorSeed(id);
        address[] memory w = new address[](1);
        w[0] = holder;
        vm.startPrank(owner_);
        r.publishWinners(id, w, keccak256("list"));
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.AlreadyDrawn.selector, id));
        r.publishWinners(id, w, keccak256("other"));
        vm.stopPrank();
    }

    // --- ownership ---

    function test_onlyOwnerConfigures() public {
        uint256 id = _create();
        vm.startPrank(stranger);
        vm.expectRevert();
        r.createRaffle("x", "", uint64(block.number - 1), uint64(block.number + 5), uint64(block.number + 9), 1, _weights());
        vm.expectRevert();
        r.setWeights(id, _weights());
        vm.expectRevert();
        r.cancelRaffle(id);
        vm.stopPrank();
    }

    function test_cancelledRaffleIsInert() public {
        uint256 id = _create();
        vm.prank(owner_);
        r.cancelRaffle(id);
        vm.roll(1030);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.RaffleIsCancelled.selector, id));
        r.anchorSeed(id);
    }

    // --- the open window (Adrian 31-jul: leave it open X days to pull burns in) ---

    function test_burningDuringTheWindowIsWhatTheCloseBlockIsFor() public {
        uint256 id = _create();
        // the same wallet, before and after feeding the fire during the window
        assertEq(r.ticketsFor(id, holder, 0, 0, 2, 0), 1);   // just holding
        assertEq(r.ticketsFor(id, holder, 12, 0, 2, 0), 13); // 12 canvases given
    }

    function test_ascendedReaperCarriesTheExtraPerk() public {
        uint256 id = _create(); // perAscendedReaper = 10
        // two wallets that consumed the same 30 canvases, but one took a soul all
        // the way to Soul Reaper
        assertEq(r.ticketsFor(id, holder, 30, 0, 1, 0), 31);
        assertEq(r.ticketsFor(id, whale, 30, 1, 1, 0), 41);
    }

    function test_drawMustComeAfterTheClose() public {
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(RaffleFacet.DrawMustFollowClose.selector, uint64(block.number + 5), uint64(block.number + 20))
        );
        r.createRaffle("x", "", uint64(block.number - 1), uint64(block.number + 20), uint64(block.number + 5), 1, _weights());
    }

    function test_windowCanBeExtendedWhileStillOpen() public {
        uint256 id = _create();
        vm.roll(1010); // still inside the window (closes at 1020)
        vm.prank(owner_);
        r.setCloseBlock(id, uint64(1100), uint64(1105));
        vm.roll(1101);
        // the seed can't be taken yet — the draw moved with the close
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.DrawBlockNotReached.selector, id, uint64(1105)));
        r.anchorSeed(id);
    }

    function test_windowCannotBeReopenedOnceShut() public {
        uint256 id = _create();
        vm.roll(1021); // past the close
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(RaffleFacet.WindowAlreadyClosed.selector, id, uint64(1020)));
        r.setCloseBlock(id, uint64(1200), uint64(1205));
    }
}
