// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SoulsBatchTransferFacet} from "../src/facets/SoulsBatchTransferFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISouls {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function owner() external view returns (address);
}

interface ILoupe {
    function facetAddress(bytes4 selector) external view returns (address);
}

/// Fork test for the batch-transfer cut, against REAL mainnet state.
///
/// The question this answers: with the REAL Limit Break validator and the REAL
/// collection policy (DEFAULT ruleset + OTC flags for 7702/smart wallets), does an
/// owner-initiated batchTransfer go through? If the policy treated the batch as an
/// unauthorized operator, the tool would be dead on arrival. Runs only when
/// ETH_RPC is set:
///   ETH_RPC=<url> forge test --match-contract BatchTransferFork -vv
contract BatchTransferForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant OWNER = 0xa41D5fAF7BA8B82E276125dE2a053216e91f4814;

    bool forked;
    ISouls souls = ISouls(DIAMOND);
    address dest = makeAddr("dest");
    mapping(address => uint256) ownedInRange;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _applyCut() internal {
        SoulsBatchTransferFacet facet = new SoulsBatchTransferFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SoulsBatchTransferFacet.batchTransfer.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });

        vm.prank(souls.owner());
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
    }

    /// A real holder, their real souls, the real validator: one tx, N souls move.
    function test_realHolderBatchesThroughRealValidator() public {
        if (!forked) return;
        _applyCut();

        // find a holder with at least 3 souls by walking real ownership:
        // pass 1 counts owners, pass 2 collects the winner's ids
        address whale;
        for (uint256 id = 1; id <= 400 && whale == address(0); id++) {
            try souls.ownerOf(id) returns (address o) {
                if (o.code.length != 0) continue; // keep it to a plain EOA holder
                if (++ownedInRange[o] == 3) whale = o;
            } catch {}
        }
        assertTrue(whale != address(0), "needs a real holder with 3+ souls in ids 1..400");

        uint256[] memory ids = new uint256[](3);
        uint256 found;
        for (uint256 id = 1; id <= 400 && found < 3; id++) {
            try souls.ownerOf(id) returns (address o) {
                if (o == whale) ids[found++] = id;
            } catch {}
        }
        assertEq(found, 3);
        console.log("holder:", whale);
        console.log("souls: ", ids[0], ids[1], ids[2]);

        uint256 supplyBefore = souls.totalSupply();
        uint256 balBefore = souls.balanceOf(whale);

        vm.prank(whale);
        SoulsBatchTransferFacet(DIAMOND).batchTransfer(dest, ids);

        assertEq(souls.ownerOf(ids[0]), dest);
        assertEq(souls.ownerOf(ids[1]), dest);
        assertEq(souls.ownerOf(ids[2]), dest);
        assertEq(souls.balanceOf(whale), balBefore - 3);
        assertEq(souls.balanceOf(dest), 3);
        assertEq(souls.totalSupply(), supplyBefore, "supply untouched");
    }

    /// The guard survives contact with reality: you cannot batch someone else's souls.
    function test_strangerCannotBatchRealSouls() public {
        if (!forked) return;
        _applyCut();

        address realOwner = souls.ownerOf(136);
        address stranger = makeAddr("stranger");
        assertTrue(realOwner != stranger);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 136;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SoulsBatchTransferFacet.NotYourSoul.selector, 136));
        SoulsBatchTransferFacet(DIAMOND).batchTransfer(dest, ids);
    }

    /// Before the cut, the selector must be unrouted - proves the Add is genuinely new.
    function test_selectorIsVirginBeforeTheCut() public view {
        if (!forked) return;
        assertEq(
            ILoupe(DIAMOND).facetAddress(SoulsBatchTransferFacet.batchTransfer.selector),
            address(0),
            "batchTransfer must not be routed yet"
        );
    }
}
