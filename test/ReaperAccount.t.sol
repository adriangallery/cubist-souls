// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockPikkazo, DiamondHarness} from "./CubistSouls.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ReaperFacet} from "../src/facets/ReaperFacet.sol";
import {ReaperInit} from "../src/upgradeInitializers/ReaperInit.sol";
import {ReaperAccountFacet, IERC6551Registry} from "../src/facets/ReaperAccountFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {LibSouls} from "../src/libraries/LibSouls.sol";

/// Unit tests for ReaperAccountFacet — THE GATE (only Ascended reapers have a
/// vault) plus determinism/idempotence of activation.
///
/// The canonical ERC-6551 registry does not exist on a fresh local chain, so its
/// REAL mainnet runtime bytecode is vm.etch'd at the canonical address: the
/// CREATE2 math, the idempotent createAccount and the account() view are the
/// genuine article, not a mock. (AccountProxy/AccountV3 behavior — initialize,
/// owner(), execute — is exercised in ReaperAccountFork.t.sol against mainnet.)
contract ReaperAccountTest is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;

    /// Real mainnet runtime bytecode of the canonical ERC-6551 registry v0.3.1
    /// (read via eth_getCode on 2026-08-03).
    bytes constant REGISTRY_CODE =
        hex"608060405234801561001057600080fd5b50600436106100365760003560e01c8063246a00211461003b5780638a54c52f1461006a575b600080fd5b61004e6100493660046101b7565b61007d565b6040516001600160a01b03909116815260200160405180910390f35b61004e6100783660046101b7565b6100e1565b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b60015284601552605560002060601b60601c60005260206000f35b600060806024608c376e5af43d82803e903d91602b57fd5bf3606c5285605d52733d60ad80600a3d3981f3363d3d373d3d3d363d7360495260ff60005360b76055206035523060601b600152846015526055600020803b61018b578560b760556000f580610157576320188a596000526004601cfd5b80606c52508284887f79f19b3655ee38b1ce526556b7731a20c8f218fbda4a3990b6cc4172fdf887226060606ca46020606cf35b8060601b60601c60005260206000f35b80356001600160a01b03811681146101b257600080fd5b919050565b600080600080600060a086880312156101cf57600080fd5b6101d88661019b565b945060208601359350604086013592506101f46060870161019b565b94979396509194608001359291505056fea2646970667358221220ea2fe53af507453c64dd7c1db05549fa47a298dfb825d6d11e1689856135f16764736f6c63430008110033";

    MockPikkazo pikkazo;
    address diamond;
    address owner_ = makeAddr("adrian");
    address holder = makeAddr("holder");

    SoulsERC721Facet souls;
    ConvertFacet conv;
    ReaperFacet reaper;
    ReaperAccountFacet vault;

    uint256 constant REAPER = 3995; // the Soul the holder feeds to ascension
    uint256 constant REGULAR = 250; // a freed Soul that never consumes anything
    uint256 constant GHOST = 4242; // never minted

    event ReaperAccountActivated(uint256 indexed reaperId, address indexed account);

    function setUp() public {
        vm.etch(REGISTRY, REGISTRY_CODE);

        pikkazo = new MockPikkazo();
        diamond = new DiamondHarness().build(owner_, address(pikkazo));
        vm.prank(owner_);
        OwnershipFacet(diamond).acceptOwnership();

        _applyReaperCut();
        _applyAccountCut();

        souls = SoulsERC721Facet(diamond);
        conv = ConvertFacet(diamond);
        reaper = ReaperFacet(diamond);
        vault = ReaperAccountFacet(diamond);

        // Free two Souls and stock the holder with canvases 100..199 to offer.
        pikkazo.mint(holder, REAPER);
        pikkazo.mint(holder, REGULAR);
        for (uint256 i = 100; i < 200; i++) {
            pikkazo.mint(holder, i);
        }
        vm.startPrank(holder);
        pikkazo.setApprovalForAll(diamond, true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = REAPER;
        ids[1] = REGULAR;
        conv.convert(ids);
        vm.stopPrank();
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

    function _applyAccountCut() internal {
        ReaperAccountFacet facet = new ReaperAccountFacet();
        bytes4[] memory s = new bytes4[](2);
        s[0] = ReaperAccountFacet.reaperAccount.selector;
        s[1] = ReaperAccountFacet.activateReaperAccount.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    // --------------------------------------------------------------- helpers

    function _range(uint256 start, uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = start + i;
        }
    }

    function _ascend() internal {
        vm.prank(holder);
        reaper.offer(REAPER, _range(100, 30));
        assertTrue(reaper.isReaper(REAPER), "sanity: ascended");
    }

    function _expectedAccount(uint256 id) internal view returns (address) {
        return IERC6551Registry(REGISTRY).account(
            0x55266d75D1a14E4572138116aF39863Ed6596E7F, bytes32(0), block.chainid, diamond, id
        );
    }

    // ------------------------------------------------------------ THE GATE

    function test_view_regular_soul_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReaperAccountFacet.NotAscended.selector, REGULAR));
        vault.reaperAccount(REGULAR);
    }

    function test_activate_regular_soul_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReaperAccountFacet.NotAscended.selector, REGULAR));
        vault.activateReaperAccount(REGULAR);
    }

    function test_nonexistent_soul_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(LibSouls.SoulDoesNotExist.selector, GHOST));
        vault.reaperAccount(GHOST);
        vm.expectRevert(abi.encodeWithSelector(LibSouls.SoulDoesNotExist.selector, GHOST));
        vault.activateReaperAccount(GHOST);
    }

    /// 29 consumed is NOT a reaper; the 30th canvas opens the vault. Exact same
    /// edge as ReaperFacet.isReaper — the two gates can never disagree.
    function test_threshold_edge_29_then_30() public {
        vm.prank(holder);
        reaper.offer(REAPER, _range(100, 29));
        assertFalse(reaper.isReaper(REAPER));
        vm.expectRevert(abi.encodeWithSelector(ReaperAccountFacet.NotAscended.selector, REAPER));
        vault.reaperAccount(REAPER);

        vm.prank(holder);
        reaper.offer(REAPER, _range(129, 1));
        assertTrue(reaper.isReaper(REAPER));
        (address acc, bool deployed) = vault.reaperAccount(REAPER);
        assertTrue(acc != address(0));
        assertFalse(deployed);
    }

    // ----------------------------------------------------------- activation

    function test_view_matches_registry_math_and_activation_deploys() public {
        _ascend();
        (address predicted, bool deployedBefore) = vault.reaperAccount(REAPER);
        assertEq(predicted, _expectedAccount(REAPER), "facet must resolve the tokenbound.app address");
        assertFalse(deployedBefore);

        vm.expectEmit(true, true, false, false, diamond);
        emit ReaperAccountActivated(REAPER, predicted);
        address acc = vault.activateReaperAccount(REAPER);

        assertEq(acc, predicted, "activation lands on the predicted address");
        assertTrue(acc.code.length > 0, "vault is deployed");
        (, bool deployedAfter) = vault.reaperAccount(REAPER);
        assertTrue(deployedAfter);
    }

    /// Anyone may pay the gas — the museum keeper does in production — but the
    /// address is CREATE2-bound to the token, so the caller gains nothing.
    function test_activation_is_permissionless_and_idempotent() public {
        _ascend();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        address acc = vault.activateReaperAccount(REAPER);
        assertEq(acc, _expectedAccount(REAPER));

        // second call: same address, no revert, and NO second Activated event
        vm.recordLogs();
        vm.prank(holder);
        address again = vault.activateReaperAccount(REAPER);
        assertEq(again, acc);
        assertEq(vm.getRecordedLogs().length, 0, "no event on the no-op path");
    }

    /// Two reapers never share a vault.
    function test_accounts_are_per_token() public {
        _ascend();
        vm.prank(holder);
        reaper.offer(REGULAR, _range(130, 30)); // second ascension
        (address a,) = vault.reaperAccount(REAPER);
        (address b,) = vault.reaperAccount(REGULAR);
        assertTrue(a != b);
    }
}
