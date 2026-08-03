// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ReaperAccountFacet} from "../src/facets/ReaperAccountFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISouls {
    function ownerOf(uint256 tokenId) external view returns (address);
    function owner() external view returns (address);
    function isReaper(uint256 tokenId) external view returns (bool);
    function soulsConsumed(uint256 tokenId) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function reaperAccount(uint256 tokenId) external view returns (address, bool);
    function activateReaperAccount(uint256 tokenId) external returns (address);
}

interface ILoupe {
    function facetAddress(bytes4 selector) external view returns (address);
}

/// Tokenbound AccountV3 surface under test.
interface IAccountV3 {
    function owner() external view returns (address);
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

/// Fork test for the reaper-vault cut, against REAL mainnet state: the REAL
/// canonical registry, the REAL Tokenbound AccountProxy/AccountV3/Guardian and
/// the REAL Limit Break validator policy on the collection.
///
/// Questions this answers that the unit tests cannot:
///   1. Does initialize(AccountV3) succeed on a fresh proxy (guardian trusts it)?
///   2. Does owner()/token() resolve to the actual reaper holder?
///   3. Can the holder execute() assets OUT of the vault (and a stranger NOT)?
///   4. Does the collection's ERC-721C policy allow transferring a Soul INTO a
///      vault (receiver is a smart contract)?
///   5. Is the ownership cycle (reaper safe-transferred into its OWN vault)
///      actually blocked by V3's guard?
///
/// Runs only when ETH_RPC is set:
///   ETH_RPC=<url> forge test --match-contract ReaperAccountFork -vv
contract ReaperAccountForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    /// The Order as of 2026-08-03 (every ReaperAscended since genesis).
    uint256[11] ASCENDED = [uint256(136), 373, 487, 2201, 2680, 3654, 6225, 6559, 6669, 7681, 8777];

    /// Adrian's crown reaper — the one that gets the smoke-test asset in prod.
    uint256 constant CROWN = 8777;

    bool forked;
    ISouls souls = ISouls(DIAMOND);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _applyCut();
    }

    function _applyCut() internal {
        ReaperAccountFacet facet = new ReaperAccountFacet();
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = ReaperAccountFacet.reaperAccount.selector;
        sels[1] = ReaperAccountFacet.activateReaperAccount.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        vm.prank(souls.owner());
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
    }

    /// A real Soul on mainnet that is NOT a reaper (found dynamically so the
    /// test never goes stale as the Order grows).
    function _someRegularSoul() internal view returns (uint256) {
        for (uint256 id = 1; id < 300; id++) {
            // ownerOf reverts for non-existent ids — probe with a staticcall
            (bool ok, bytes memory ret) =
                DIAMOND.staticcall(abi.encodeWithSelector(ISouls.ownerOf.selector, id));
            if (!ok || ret.length != 32) continue;
            if (!souls.isReaper(id)) return id;
        }
        revert("no regular soul below 300??");
    }

    // ------------------------------------------------------------------ gate

    function test_fork_regular_soul_has_no_vault() public {
        if (!forked) return;
        uint256 regular = _someRegularSoul();
        vm.expectRevert(abi.encodeWithSelector(ReaperAccountFacet.NotAscended.selector, regular));
        souls.reaperAccount(regular);
        vm.expectRevert(abi.encodeWithSelector(ReaperAccountFacet.NotAscended.selector, regular));
        souls.activateReaperAccount(regular);
    }

    // ------------------------------------------------- activation, real stack

    function test_fork_activate_crown_reaper_and_owner_resolves() public {
        if (!forked) return;
        assertTrue(souls.isReaper(CROWN), "sanity: #8777 ascended");

        (address predicted, bool deployedBefore) = souls.reaperAccount(CROWN);
        assertFalse(deployedBefore, "not yet activated on mainnet");

        address acc = souls.activateReaperAccount(CROWN);
        assertEq(acc, predicted);
        assertTrue(acc.code.length > 0, "vault deployed");

        // The REAL AccountV3 must recognize the reaper's holder as its owner.
        address holder = souls.ownerOf(CROWN);
        assertEq(IAccountV3(acc).owner(), holder, "vault obeys the crown's holder");
        (uint256 chainId, address tokenContract, uint256 tokenId) = IAccountV3(acc).token();
        assertEq(chainId, 1);
        assertEq(tokenContract, DIAMOND);
        assertEq(tokenId, CROWN);
    }

    function test_fork_activate_every_current_reaper() public {
        if (!forked) return;
        for (uint256 i = 0; i < ASCENDED.length; i++) {
            uint256 id = ASCENDED[i];
            assertTrue(souls.isReaper(id), "roster stale?");
            address acc = souls.activateReaperAccount(id);
            assertTrue(acc.code.length > 0);
            assertEq(IAccountV3(acc).owner(), souls.ownerOf(id));
        }
    }

    // ----------------------------------------------------- assets in and out

    function test_fork_holder_executes_out_stranger_cannot() public {
        if (!forked) return;
        address acc = souls.activateReaperAccount(CROWN);
        address holder = souls.ownerOf(CROWN);
        address beneficiary = makeAddr("beneficiary");

        vm.deal(acc, 1 ether); // the test asset lands in the vault

        // a stranger cannot move it
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IAccountV3(acc).execute(beneficiary, 0.4 ether, "", 0);

        // the reaper's holder can
        vm.prank(holder);
        IAccountV3(acc).execute(beneficiary, 0.4 ether, "", 0);
        assertEq(beneficiary.balance, 0.4 ether);
        assertEq(acc.balance, 0.6 ether);
    }

    /// A Soul can be sent INTO a reaper's vault (the ERC-721C policy must accept
    /// a smart-contract receiver), and the holder can send it back out again.
    function test_fork_vault_can_hold_and_release_a_soul() public {
        if (!forked) return;
        address acc = souls.activateReaperAccount(CROWN);
        address holder = souls.ownerOf(CROWN);

        uint256 regular = _someRegularSoul();
        address regularHolder = souls.ownerOf(regular);

        vm.prank(regularHolder);
        souls.safeTransferFrom(regularHolder, acc, regular);
        assertEq(souls.ownerOf(regular), acc, "vault holds the soul");

        // and OUT again: the crown holder executes a transferFrom from the vault
        vm.prank(holder);
        IAccountV3(acc).execute(
            DIAMOND, 0, abi.encodeWithSelector(ISouls.transferFrom.selector, acc, regularHolder, regular), 0
        );
        assertEq(souls.ownerOf(regular), regularHolder, "vault releases the soul");
    }

    /// The brick scenario: safe-transferring the crown INTO its own vault must
    /// revert (AccountV3 ownership-cycle guard). If this ever passes silently,
    /// the reaper would be lost forever.
    function test_fork_ownership_cycle_is_blocked() public {
        if (!forked) return;
        address acc = souls.activateReaperAccount(CROWN);
        address holder = souls.ownerOf(CROWN);

        vm.prank(holder);
        vm.expectRevert();
        souls.safeTransferFrom(holder, acc, CROWN);
    }
}
