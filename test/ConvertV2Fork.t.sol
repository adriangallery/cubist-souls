// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
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
    function totalSupply() external view returns (uint256);
}

/// Fork test that applies the ConvertFacetV2 upgrade to the REAL LIVE Cubist
/// Souls diamond on Ethereum mainnet and exercises a paid convert + withdraw
/// against live state. Runs only when ETH_RPC is set (fork by STATE, no getLogs):
///   ETH_RPC=<url> forge test --match-contract ConvertV2Fork -vv
contract ConvertV2ForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;
    address constant TREASURY = 0xCF8509a3fFa4721768499a4631dd31333111c709;

    uint32 constant B1 = 7 days;
    uint32 constant B2 = 21 days;
    uint32 constant B3 = 60 days;
    uint256 constant P1 = 0.0001 ether;
    uint256 constant P2 = 0.0003 ether;
    uint256 constant P3 = 0.0005 ether;

    address owner_;
    ConvertFacetV2 conv;
    SoulsERC721Facet souls;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);

        owner_ = OwnershipFacet(DIAMOND).owner();

        // apply the exact production cut: Replace convert + Add 7 + init defaults
        ConvertFacetV2 v2 = new ConvertFacetV2();
        ConvertV2Init initC = new ConvertV2Init();

        bytes4[] memory rep = new bytes4[](1);
        rep[0] = ConvertFacet.convert.selector;
        bytes4[] memory adds = new bytes4[](10);
        adds[0] = ConvertFacetV2.priceNow.selector;
        adds[1] = ConvertFacetV2.freedAt.selector;
        adds[2] = ConvertFacetV2.cohortOf.selector;
        adds[3] = ConvertFacetV2.saleStart.selector;
        adds[4] = ConvertFacetV2.pricing.selector;
        adds[5] = ConvertFacetV2.setPricing.selector;
        adds[6] = ConvertFacetV2.treasury.selector;
        adds[7] = ConvertFacetV2.setTreasury.selector;
        adds[8] = bytes4(keccak256("withdraw()"));
        adds[9] = bytes4(keccak256("withdraw(address)"));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(address(v2), IDiamondCut.FacetCutAction.Replace, rep);
        cuts[1] = IDiamondCut.FacetCut(address(v2), IDiamondCut.FacetCutAction.Add, adds);

        vm.prank(owner_);
        IDiamondCut(DIAMOND).diamondCut(
            cuts, address(initC), abi.encodeCall(ConvertV2Init.init, (uint64(0), B1, B2, B3, P1, P2, P3, TREASURY))
        );

        conv = ConvertFacetV2(DIAMOND);
        souls = SoulsERC721Facet(DIAMOND);
    }

    function _findLiveCanvas() internal view returns (address holder, uint256 id) {
        uint16[20] memory c =
            [uint16(3995), 99, 100, 2500, 4200, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9200, 9500, 500, 1500, 2000, 3000, 3500, 5000];
        for (uint256 i = 0; i < c.length; i++) {
            try IPikkazoLike(PIKKAZO).ownerOf(c[i]) returns (address o) {
                // require a plain EOA so refund/balance semantics are clean
                if (o != address(0) && o.code.length == 0) return (o, c[i]);
            } catch {}
        }
        revert("no live EOA canvas");
    }

    function test_fork_paidConvertAndWithdraw() public {
        // move into the price2 tier by backdating saleStart
        vm.prank(owner_);
        conv.setPricing(uint64(block.timestamp - uint256(B2) - 1), B1, B2, B3, P1, P2, P3);
        uint256 unit = conv.priceNow();
        assertEq(unit, P2);

        (address holder, uint256 id) = _findLiveCanvas();
        uint256 pikSupplyBefore = IPikkazoLike(PIKKAZO).totalSupply();
        vm.deal(holder, unit + 1 ether);

        vm.prank(holder);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 diamondBefore = DIAMOND.balance;

        vm.prank(holder);
        conv.convert{value: unit + 0.3 ether}(ids); // overpay -> refund

        // Authoritative, gas-independent charge proof: the diamond accrues EXACTLY
        // `unit`, not the overpay -> the 0.3 ETH excess was refunded. (The pranked
        // EOA's own balance delta = unit + fork gas, so we don't assert on it.)
        assertEq(DIAMOND.balance, diamondBefore + unit);
        // soul minted same id, canvas burned on the legacy contract
        assertEq(souls.ownerOf(id), holder);
        assertEq(IPikkazoLike(PIKKAZO).totalSupply(), pikSupplyBefore - 1);
        // cohort + freedAt tagging
        assertEq(conv.freedAt(id), uint64(block.timestamp));
        assertEq(conv.cohortOf(id), 3);

        // no-arg withdraw() sweeps to the configured treasury
        assertEq(conv.treasury(), TREASURY);
        uint256 treasBefore = TREASURY.balance;
        vm.prank(owner_);
        conv.withdraw();
        assertEq(TREASURY.balance, treasBefore + unit);
        assertEq(DIAMOND.balance, diamondBefore);
    }

    function test_fork_legacyTokenIsGenesis() public view {
        // #136 was freed pre-V2 (genesis on the live diamond) -> no freedAt -> Genesis
        assertEq(conv.freedAt(136), 0);
        assertEq(conv.cohortOf(136), 0);
    }

    function test_fork_freeTierRefundsAll() public {
        // default init saleStart = cut time -> elapsed ~0 -> free tier
        vm.prank(owner_);
        conv.setPricing(uint64(block.timestamp), B1, B2, B3, P1, P2, P3);
        assertEq(conv.priceNow(), 0);

        (address holder, uint256 id) = _findLiveCanvas();
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        IPikkazoLike(PIKKAZO).setApprovalForAll(DIAMOND, true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 holderBefore = holder.balance;
        vm.prank(holder);
        conv.convert{value: 0.5 ether}(ids);
        assertEq(holder.balance, holderBefore); // fully refunded
        assertEq(conv.cohortOf(id), 1); // free-window cohort
        assertEq(DIAMOND.balance, 0);
    }
}
