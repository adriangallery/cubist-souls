// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VesselFacet} from "../src/facets/VesselFacet.sol";
import {VesselInit} from "../src/upgradeInitializers/VesselInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISoulsV {
    function ownerOf(uint256 tokenId) external view returns (address);
    function owner() external view returns (address);
    function isReaper(uint256 tokenId) external view returns (bool);
    function soulsConsumed(uint256 tokenId) external view returns (uint256);
    function isCanvasConsumed(uint256 tokenId) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function offer(uint256 reaperId, uint256[] calldata pikkazoIds) external;
    function cohortOf(uint256 tokenId) external view returns (uint8);
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
    // vessel surface
    function fuse(uint256 canvasId, uint256[] calldata soulIds, string calldata name)
        external
        payable
        returns (address);
    function vesselFee() external view returns (uint256);
    function isVesselToken(uint256 id) external view returns (bool);
    function membersOf(uint256 vesselId) external view returns (uint256[] memory);
    function custodianOf(uint256 soulId) external view returns (address);
    function vesselVault(uint256 vesselId) external view returns (address, bool);
}

interface IPikkazoV {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IAccountV3V {
    function owner() external view returns (address);
    function token() external view returns (uint256, address, uint256);
}

/// Fork test for the vessel cut against REAL mainnet state: real souls of a real
/// whale, a real Pikkazo burned as a real offering to mint the consumed canvas,
/// the real 6551 stack for the vessel's vault, real cohort + royalty readers.
///
///   ETH_RPC=<url> forge test --match-contract VesselFork -vv
contract VesselForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant PIKKAZO = 0x6478b94dfa32F3eab600970D04B34615eE97484e;
    address constant WHALE = 0x4943407105999e3E97EFA2035F5cbC64D72581C6; // largest holder (Adrian)
    uint256 constant CROWN = 8777; // OG reaper that receives the offering

    bool forked;
    ISoulsV souls = ISoulsV(DIAMOND);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _applyCut();
    }

    function _applyCut() internal {
        VesselFacet facet = new VesselFacet();
        VesselInit initC = new VesselInit();
        bytes4[] memory s = new bytes4[](10);
        s[0] = VesselFacet.fuse.selector;
        s[1] = VesselFacet.renameVessel.selector;
        s[2] = VesselFacet.setVesselFee.selector;
        s[3] = VesselFacet.vesselFee.selector;
        s[4] = VesselFacet.isVesselToken.selector;
        s[5] = VesselFacet.vesselNameOf.selector;
        s[6] = VesselFacet.membersOf.selector;
        s[7] = VesselFacet.vesselOf.selector;
        s[8] = VesselFacet.custodianOf.selector;
        s[9] = VesselFacet.vesselVault.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        vm.prank(souls.owner());
        IDiamondCut(DIAMOND).diamondCut(cuts, address(initC), abi.encodeCall(VesselInit.init, ()));
    }

    /// 30 real souls held by the whale with consumed == 0.
    function _thirtyOfWhale() internal view returns (uint256[] memory ids) {
        ids = new uint256[](30);
        uint256 n = 0;
        for (uint256 id = 1; id <= 4000 && n < 30; id++) {
            (bool ok, bytes memory ret) =
                DIAMOND.staticcall(abi.encodeWithSelector(ISoulsV.ownerOf.selector, id));
            if (!ok || ret.length != 32) continue;
            if (abi.decode(ret, (address)) != WHALE) continue;
            if (souls.soulsConsumed(id) != 0) continue;
            ids[n++] = id;
        }
        require(n == 30, "whale has <30 clean souls below 4000??");
    }

    /// Burn a REAL Pikkazo as a REAL offering so a fresh consumed canvas exists.
    /// Live offer() is reaper-owner-only, so the canvas is handed to the crown's
    /// holder first and the offering is made by them — the true production path.
    function _makeConsumedCanvas() internal returns (uint256 canvasId) {
        address crownHolder = souls.ownerOf(CROWN);
        for (uint256 id = 1; id <= 3000; id++) {
            (bool ok, bytes memory ret) =
                PIKKAZO.staticcall(abi.encodeWithSelector(IPikkazoV.ownerOf.selector, id));
            if (!ok || ret.length != 32) continue;
            address holder = abi.decode(ret, (address));
            if (holder == address(0) || holder.code.length > 0) continue; // EOAs only: no receiver surprises
            vm.prank(holder);
            IPikkazoV(PIKKAZO).transferFrom(holder, crownHolder, id);

            uint256[] memory one = new uint256[](1);
            one[0] = id;
            vm.startPrank(crownHolder);
            IPikkazoV(PIKKAZO).setApprovalForAll(DIAMOND, true);
            souls.offer(CROWN, one);
            vm.stopPrank();
            require(souls.isCanvasConsumed(id), "offer did not consume");
            return id;
        }
        revert("no live pikkazo below 3000??");
    }

    function test_fork_fuse_end_to_end() public {
        if (!forked) return;

        uint256[] memory members = _thirtyOfWhale();
        uint256 canvas = _makeConsumedCanvas();
        uint256 fee = souls.vesselFee();
        assertEq(fee, 0.0005 ether, "ratified rite fee");

        uint256 diamondBal = DIAMOND.balance;
        vm.deal(WHALE, 1 ether);
        vm.prank(WHALE);
        address vault = souls.fuse{value: fee}(canvas, members, "The First Communion");

        // vessel minted over the sacrificed canvas, to the founder
        assertEq(souls.ownerOf(canvas), WHALE);
        assertTrue(souls.isVesselToken(canvas));
        assertTrue(souls.cohortOf(canvas) != 0, "no phantom OG on the REAL cohort reader");

        // custody: the diamond holds all thirty; attribution points at the founder
        for (uint256 i = 0; i < 30; i++) {
            assertEq(souls.ownerOf(members[i]), DIAMOND);
            assertEq(souls.custodianOf(members[i]), WHALE);
        }

        // no path out — not even for the founder
        vm.prank(WHALE);
        vm.expectRevert();
        souls.transferFrom(DIAMOND, WHALE, members[0]);

        // the vault: real registry, real proxy, real V3 — owned by the founder
        (address v, bool deployed) = souls.vesselVault(canvas);
        assertEq(v, vault);
        assertTrue(deployed);
        assertEq(IAccountV3V(vault).owner(), WHALE);
        (uint256 cid, address tc, uint256 tid) = IAccountV3V(vault).token();
        assertEq(cid, 1);
        assertEq(tc, DIAMOND);
        assertEq(tid, canvas);

        // the rite fee accrued in the museum
        assertEq(DIAMOND.balance, diamondBal + fee);

        // vessel resale pays the enforced royalty like any piece in the museum
        (address rcv, uint256 roy) = souls.royaltyInfo(canvas, 1 ether);
        assertTrue(rcv != address(0));
        assertEq(roy, 0.05 ether, "5% enforced");

        // and the vessel travels whole: sell it, attribution follows
        address buyer = makeAddr("buyer");
        vm.prank(WHALE);
        souls.transferFrom(WHALE, buyer, canvas);
        assertEq(souls.custodianOf(members[0]), buyer);

        console.log("vessel", canvas);
        console.log("vault", vault);
    }
}
