// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ReaperAccountFacet} from "../src/facets/ReaperAccountFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ILoupeView {
    function facetAddress(bytes4 selector) external view returns (address);
}

interface IVault {
    function reaperAccount(uint256 tokenId) external view returns (address, bool);
    function activateReaperAccount(uint256 tokenId) external returns (address);
    function isReaper(uint256 tokenId) external view returns (bool);
}

/// @title AddReaperAccounts - the Order gets its vaults (ERC-6551, reapers only)
///
/// One broadcast, three movements:
///   1. Purely additive cut: ReaperAccountFacet, TWO selectors (reaperAccount +
///      activateReaperAccount). Nothing replaced, nothing removed.
///   2. Backfill: activate the vault of every reaper Ascended so far (the keeper
///      auto-activates future ones the moment ReaperAscended fires).
///   3. Smoke asset: 0.0002 ETH into the crown reaper's (#8777) fresh vault, so
///      the tool can be exercised end-to-end in the museum immediately.
///
/// Dry-run against real mainnet state (no key):
///   forge script script/AddReaperAccounts.s.sol --fork-url $RPC -vvv
///
/// Broadcast (ONLY after explicit go-ahead; key via env, never inlined):
///   forge script script/AddReaperAccounts.s.sol --rpc-url $RPC \
///     --private-key $DEPLOYER_KEY --broadcast --slow -vvv
contract AddReaperAccounts is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    uint256 constant CROWN = 8777;
    uint256 constant SMOKE_WEI = 0.0002 ether;

    /// Every ReaperAscended on mainnet as of 2026-08-03 (verified via logs).
    uint256[11] ASCENDED = [uint256(136), 373, 487, 2201, 2680, 3654, 6225, 6559, 6669, 7681, 8777];

    function run() external {
        ILoupeView loupe = ILoupeView(DIAMOND);
        IVault vault = IVault(DIAMOND);
        bytes4 selView = ReaperAccountFacet.reaperAccount.selector;
        bytes4 selAct = ReaperAccountFacet.activateReaperAccount.selector;

        console.log("Diamond:", DIAMOND);
        console.log("-- before --");
        require(loupe.facetAddress(selView) == address(0), "reaperAccount already routed");
        require(loupe.facetAddress(selAct) == address(0), "activateReaperAccount already routed");
        for (uint256 i = 0; i < ASCENDED.length; i++) {
            require(vault.isReaper(ASCENDED[i]), "roster stale: not a reaper");
        }

        vm.startBroadcast();

        // 1. the cut
        ReaperAccountFacet facet = new ReaperAccountFacet();
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = selView;
        sels[1] = selAct;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        // 2. backfill: every Ascended reaper gets its vault now
        for (uint256 i = 0; i < ASCENDED.length; i++) {
            address acc = vault.activateReaperAccount(ASCENDED[i]);
            console.log("vault", ASCENDED[i], acc);
        }

        // 3. smoke asset into the crown's vault
        (address crownVault,) = vault.reaperAccount(CROWN);
        (bool sent,) = crownVault.call{value: SMOKE_WEI}("");
        require(sent, "smoke transfer failed");

        vm.stopBroadcast();

        console.log("-- after --");
        console.log("  facet deployed:      ", address(facet));
        require(loupe.facetAddress(selView) == address(facet), "view not routed");
        require(loupe.facetAddress(selAct) == address(facet), "activate not routed");
        for (uint256 i = 0; i < ASCENDED.length; i++) {
            (address acc, bool deployed) = vault.reaperAccount(ASCENDED[i]);
            require(deployed && acc.code.length > 0, "vault missing");
        }
        console.log("  crown vault:         ", crownVault);
        console.log("  crown vault balance: ", crownVault.balance);
    }
}
