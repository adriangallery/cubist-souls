// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ConvertFacet} from "../src/facets/ConvertFacet.sol";
import {ConvertFacetV2} from "../src/facets/ConvertFacetV2.sol";
import {ConvertV2Init} from "../src/upgradeInitializers/ConvertV2Init.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {SoulsERC721Facet} from "../src/facets/SoulsERC721Facet.sol";

interface IPikkazoLike {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

/// @title DeployConvertV2 - assemble the ConvertFacetV2 upgrade (NO broadcast)
/// @notice Two modes:
///
///   1) PLAN (default, no fork):  forge script script/DeployConvertV2.s.sol
///      Deploys ConvertFacetV2 + ConvertV2Init locally and PRINTS the exact
///      diamondCut plan (selectors, actions, init calldata). Nothing on-chain.
///
///   2) DRY-RUN E2E (fork):       ETH_RPC=<url> forge script script/DeployConvertV2.s.sol
///      Forks mainnet by STATE (no getLogs needed), impersonates the live diamond
///      owner to apply the cut, then impersonates a real Pikkazo holder to run a
///      PAID convert, and finally the owner withdraw. Proves charge/mint/freedAt/
///      withdraw end-to-end against LIVE state. Still NEVER broadcasts.
///
/// Deploy defaults (all settable later via setPricing):
///   bounds  b1=7d  b2=21d  b3=60d   (elapsed-second thresholds)
///   prices  p1=0.0001  p2=0.0003  p3=0.0005 ether
///   saleStart = 0 -> snaps to the cut block timestamp.
contract DeployConvertV2 is Script {
    address constant DIAMOND_MAINNET = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO_MAINNET = 0x6478b94dfa32F3eab600970D04B34615eE97484e;
    // Adrian's decisions (2026-07-19):
    address constant TREASURY = 0xCF8509a3fFa4721768499a4631dd31333111c709;
    uint64 constant SALE_START = 1784419200; // 2026-07-19 00:00 UTC

    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    function v2AddSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ConvertFacetV2.priceNow.selector;
        s[1] = ConvertFacetV2.freedAt.selector;
        s[2] = ConvertFacetV2.cohortOf.selector;
        s[3] = ConvertFacetV2.saleStart.selector;
        s[4] = ConvertFacetV2.pricing.selector;
        s[5] = ConvertFacetV2.setPricing.selector;
        s[6] = ConvertFacetV2.treasury.selector;
        s[7] = ConvertFacetV2.setTreasury.selector;
        s[8] = bytes4(keccak256("withdraw()"));
        s[9] = bytes4(keccak256("withdraw(address)"));
    }

    function convertReplaceSelector() public pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ConvertFacet.convert.selector; // 0xd5ef903a
    }

    function _buildCut(address v2) internal pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: v2,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: convertReplaceSelector()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: v2,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: v2AddSelectors()
        });
    }

    function run() external {
        address diamond = vm.envOr("DIAMOND", DIAMOND_MAINNET);
        string memory rpc = vm.envOr("ETH_RPC", string(""));

        // Deploy the new facet + initializer (simulation only; no broadcast).
        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();
        bytes memory initCalldata =
            abi.encodeCall(ConvertV2Init.init, (SALE_START, B1, B2, B3, P1, P2, P3, TREASURY));

        console.log("=== ConvertFacetV2 upgrade PLAN (no broadcast) ===");
        console.log("Diamond:          ", diamond);
        console.log("ConvertFacetV2:   ", address(v2));
        console.log("ConvertV2Init:    ", address(initC));
        console.log("REPLACE convert(uint256[]) 0xd5ef903a -> ConvertFacetV2");
        bytes4[] memory adds = v2AddSelectors();
        for (uint256 i = 0; i < adds.length; i++) {
            console.logBytes4(adds[i]);
        }
        console.log("init calldata (ConvertV2Init.init):");
        console.logBytes(initCalldata);

        if (bytes(rpc).length == 0) {
            console.log("No ETH_RPC set -> PLAN mode only. Set ETH_RPC to run fork E2E.");
            return;
        }

        _forkE2E(diamond, address(v2), address(initC), initCalldata);
    }

    /// Full end-to-end proof against LIVE forked state. No broadcast.
    function _forkE2E(address diamond, address v2, address initC, bytes memory initCalldata) internal {
        vm.createSelectFork(vm.envString("ETH_RPC"));

        // Re-deploy inside the fork so the facet/init have code on this fork.
        v2 = address(new ConvertFacetV2());
        initC = address(new ConvertV2Init());
        initCalldata = abi.encodeCall(ConvertV2Init.init, (SALE_START, B1, B2, B3, P1, P2, P3, TREASURY));

        address owner_ = OwnershipFacet(diamond).owner();
        console.log("\n=== FORK DRY-RUN E2E vs LIVE diamond ===");
        console.log("Live owner:       ", owner_);

        // ---- apply the cut as the live owner ----
        uint256 gasBefore = gasleft();
        vm.prank(owner_);
        IDiamondCut(diamond).diamondCut(_buildCut(v2), initC, initCalldata);
        uint256 cutGas = gasBefore - gasleft();
        console.log("diamondCut gas:   ", cutGas);

        ConvertFacetV2 conv = ConvertFacetV2(diamond);
        // force a PAID tier so we demonstrate a charge (jump past bound2)
        vm.prank(owner_);
        conv.setPricing(uint64(block.timestamp - uint256(B2) - 1), B1, B2, B3, P1, P2, P3);
        uint256 unit = conv.priceNow();
        console.log("priceNow (tier2): ", unit);
        require(unit == P2, "expected price2 tier");

        // ---- find a live Pikkazo holder to impersonate ----
        (address holder, uint256 id) = _findLiveCanvas();
        console.log("Impersonating holder:", holder);
        console.log("Converting canvas id:", id);

        SoulsERC721Facet souls = SoulsERC721Facet(diamond);
        vm.deal(holder, unit + 1 ether);

        vm.prank(holder);
        IPikkazoLike(PIKKAZO_MAINNET).setApprovalForAll(diamond, true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 diamondBalBefore = diamond.balance;

        uint256 g2 = gasleft();
        vm.prank(holder);
        conv.convert{value: unit + 0.3 ether}(ids); // overpay -> expect refund
        uint256 convGas = g2 - gasleft();

        // assertions. Note: on a fork the pranked EOA is charged gas, so its
        // balance delta = unit + gas (env-dependent). The authoritative,
        // gas-independent proof of "charged exactly `unit`, refunded the rest"
        // is the diamond's ETH accrual: it grows by exactly `unit`, not by the
        // overpay -> the 0.3 ETH excess was refunded.
        require(souls.ownerOf(id) == holder, "soul not minted to holder");
        require(diamond.balance == diamondBalBefore + unit, "diamond did not accrue exact price (refund failed)");
        require(conv.freedAt(id) == uint64(block.timestamp), "freedAt not recorded");
        require(conv.cohortOf(id) == 3, "cohort should be 3 (price2 tier)");
        console.log("convert (paid) gas:", convGas);
        console.log("diamond ETH after: ", diamond.balance);
        console.log("freedAt(id):       ", conv.freedAt(id));
        console.log("cohortOf(id):      ", conv.cohortOf(id));

        // ---- no-arg withdraw() sweeps to the configured treasury ----
        require(conv.treasury() == TREASURY, "treasury not set by init");
        uint256 treasBefore = TREASURY.balance;
        vm.prank(owner_);
        conv.withdraw();
        require(TREASURY.balance == treasBefore + unit, "withdraw did not move balance to treasury");
        require(diamond.balance == diamondBalBefore, "diamond not swept");
        console.log("withdraw() OK, treasury got:", TREASURY.balance - treasBefore);
        console.log("=== E2E PASSED ===");
    }

    /// Scan a spread of ids for one whose canvas is still alive on Pikkazo.
    function _findLiveCanvas() internal view returns (address holder, uint256 id) {
        uint16[20] memory candidates =
            [uint16(3995), 99, 100, 2500, 4200, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9200, 9500, 500, 1500, 2000, 3000, 3500, 5000];
        for (uint256 i = 0; i < candidates.length; i++) {
            try IPikkazoLike(PIKKAZO_MAINNET).ownerOf(candidates[i]) returns (address o) {
                if (o != address(0) && o.code.length == 0) return (o, candidates[i]);
            } catch {}
        }
        revert("no live EOA pikkazo canvas found in candidate set");
    }
}
