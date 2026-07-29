// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SoulsCreatorTokenFacet} from "../src/facets/SoulsCreatorTokenFacet.sol";
import {SoulsSweepFacet} from "../src/facets/SoulsSweepFacet.sol";
import {CreatorTokenInit} from "../src/upgradeInitializers/CreatorTokenInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISouls {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
    function owner() external view returns (address);
}

interface IValidatorView {
    function getCollectionSecurityPolicy(address collection) external view returns (bytes memory);
}

/// Fork test for the ERC-721C cut, against REAL mainnet state.
///
/// The question this answers, and the reason it exists: with the collection's
/// security policy left UNSET inside the real validator, does a transfer still go
/// through? If it did not, the cut would freeze the collection. Runs only when
/// ETH_RPC is set:
///   ETH_RPC=<url> forge test --match-contract CreatorTokenFork -vv
contract CreatorTokenForkTest is Test {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;
    address constant VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    address constant OWNER = 0xa41D5fAF7BA8B82E276125dE2a053216e91f4814;

    bytes4 constant IID_CREATOR_TOKEN = 0xad0d7f6c;
    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd;
    bytes4 constant SEL_SAFE_TRANSFER = 0x42842e0e;
    bytes4 constant SEL_SAFE_TRANSFER_DATA = 0xb88d4fde;

    bool forked;
    ISouls souls = ISouls(DIAMOND);
    address marketplace = makeAddr("marketplace");
    address buyer = makeAddr("buyer");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _applyCut() internal {
        SoulsCreatorTokenFacet facet = new SoulsCreatorTokenFacet();
        CreatorTokenInit initializer = new CreatorTokenInit();

        bytes4[] memory added = new bytes4[](3);
        added[0] = SoulsCreatorTokenFacet.getTransferValidator.selector;
        added[1] = SoulsCreatorTokenFacet.getTransferValidationFunction.selector;
        added[2] = SoulsCreatorTokenFacet.setTransferValidator.selector;

        bytes4[] memory replaced = new bytes4[](3);
        replaced[0] = SEL_TRANSFER_FROM;
        replaced[1] = SEL_SAFE_TRANSFER;
        replaced[2] = SEL_SAFE_TRANSFER_DATA;

        SoulsSweepFacet sweepFacet = new SoulsSweepFacet();
        bytes4[] memory sweepSels = new bytes4[](2);
        sweepSels[0] = SoulsSweepFacet.sweepERC20.selector;
        sweepSels[1] = SoulsSweepFacet.erc20Balance.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: added
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaced
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(sweepFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sweepSels
        });

        vm.prank(OWNER);
        IDiamondCut(DIAMOND).diamondCut(
            cuts, address(initializer), abi.encodeCall(CreatorTokenInit.init, (VALIDATOR))
        );
    }

    /// Find a real token id that exists on mainnet right now, held by a PLAIN EOA
    /// (no code): a 7702-delegated or smart-contract holder hits a different branch
    /// of the validator and would muddy the result.
    function _aLiveToken() internal view returns (uint256 id, address holder) {
        for (uint256 i = 1; i < 12000; i++) {
            try souls.ownerOf(i) returns (address o) {
                if (o != address(0) && o.code.length == 0) return (i, o);
            } catch {}
        }
        revert("no live token found");
    }

    /// Find a real token held by an account WITH code (7702 delegate or smart wallet).
    function _aLiveTokenHeldByCodeAccount() internal view returns (uint256 id, address holder) {
        for (uint256 i = 1; i < 12000; i++) {
            try souls.ownerOf(i) returns (address o) {
                if (o != address(0) && o.code.length > 0) return (i, o);
            } catch {}
        }
        revert("no contract-held token found");
    }

    /// The default policy (rulesetId 0) is NOT passive. This test records exactly
    /// what it does to each kind of holder and caller, so the decision is made on
    /// measurements and not on assumptions.
    function test_whatTheDefaultPolicyActuallyAllows() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveToken();
        console.log("plain-EOA holder / token:", holder, id);

        _applyCut();

        assertTrue(souls.supportsInterface(IID_CREATOR_TOKEN), "ICreatorToken advertised");
        assertEq(SoulsCreatorTokenFacet(DIAMOND).getTransferValidator(), VALIDATOR);

        // (a) plain EOA moving their own token
        vm.prank(holder);
        (bool okSelf,) = DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, holder, buyer, id));
        console.log("  plain EOA self-transfer allowed:", okSelf);

        // (b) an arbitrary operator (an unlisted marketplace) moving it
        address currentHolder = souls.ownerOf(id);
        vm.prank(currentHolder);
        souls.setApprovalForAll(marketplace, true);
        vm.prank(marketplace);
        (bool okOperator,) =
            DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, currentHolder, buyer, id));
        console.log("  unlisted operator transfer allowed:", okOperator);

        assertTrue(okSelf, "a plain EOA must always be able to move their own soul");
    }

    /// EIP-7702-delegated wallets (and smart wallets) are a separate branch of the
    /// default policy. Adrian's own wallet is 7702-upgraded, so this is not academic.
    function test_sevenSevenZeroTwoHolderUnderDefaultPolicy() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveTokenHeldByCodeAccount();
        console.log("code-account holder / token:", holder, id);
        console.log("  code size:", holder.code.length);

        _applyCut();

        vm.prank(holder);
        (bool ok, bytes memory err) =
            DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, holder, buyer, id));
        console.log("  self-transfer allowed:", ok);
        if (!ok && err.length >= 4) {
            console.log("  revert selector:", vm.toString(bytes4(err)));
        }
    }

    /// Which marketplaces survive the default policy. A sale is executed by the
    /// marketplace's transfer proxy, so THAT is the address the validator judges.
    function test_whichMarketplacesCanStillMoveTokens() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveToken();
        _applyCut();

        address[4] memory operators = [
            0x1E0049783F008A0085193E00003D00cd54003c71, // OpenSea (Seaport) Conduit
            0x0000000000000068F116a894984e2DB1123eB395, // Seaport 1.6
            0x00000000000111AbE46ff893f3B2fdF1F759a8A8, // Blur ExecutionDelegate
            0x0000000000c2d145a2526bD8C716263bFeBe1A72 // Magic Eden / MEE
        ];
        string[4] memory names = ["OpenSea conduit", "Seaport 1.6    ", "Blur delegate  ", "Magic Eden     "];

        for (uint256 i = 0; i < operators.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(holder);
            souls.setApprovalForAll(operators[i], true);
            vm.prank(operators[i]);
            (bool ok,) = DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, holder, buyer, id));
            console.log(string.concat("  ", names[i], " allowed:"), ok);
            vm.revertToState(snap);
        }
    }

    /// The 7702 lockout is a policy flag, not a law: the collection owner can lift it
    /// on the validator without touching the diamond.
    function test_sevenSevenZeroTwoLockoutCanBeLifted() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveTokenHeldByCodeAccount();
        _applyCut();

        vm.prank(holder);
        (bool okBefore,) = DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, holder, buyer, id));
        console.log("  7702 self-transfer BEFORE flags:", okBefore);

        // FLAG_RULESET_WHITELIST_ALLOW_OTC_FOR_7702_DELEGATES (1<<1)
        // | FLAG_RULESET_WHITELIST_ALLOW_OTC_FOR_SMART_WALLETS (1<<2)
        uint16 rulesetOptions = (1 << 1) | (1 << 2);
        vm.prank(OWNER);
        (bool okCfg,) = VALIDATOR.call(
            abi.encodeWithSignature(
                "setRulesetOfCollection(address,uint8,address,uint8,uint16)",
                DIAMOND,
                uint8(0), // RULESET_ID_DEFAULT
                address(0),
                uint8(0),
                rulesetOptions
            )
        );
        console.log("  setRulesetOfCollection by collection owner ok:", okCfg);

        vm.prank(holder);
        (bool okAfter,) = DIAMOND.call(abi.encodeWithSelector(SEL_TRANSFER_FROM, holder, buyer, id));
        console.log("  7702 self-transfer AFTER  flags:", okAfter);
    }

    /// Royalties paid to the contract itself: can the money actually get out again?
    /// ETH goes through ConvertFacetV2.withdraw, which lives on the real diamond
    /// (the local harness still builds with ConvertFacet v1, so this only means
    /// anything here).
    function test_ethRoyaltiesReachAndLeaveTheContract() public {
        if (!forked) return;
        _applyCut();

        uint256 balBefore = DIAMOND.balance;

        // a Seaport ETH-denominated royalty is a bare value call
        address payer = makeAddr("payer");
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool paid,) = DIAMOND.call{value: 0.05 ether}("");
        assertTrue(paid, "diamond must accept a bare ETH transfer");
        assertEq(DIAMOND.balance, balBefore + 0.05 ether);

        address sink = makeAddr("sink");
        vm.prank(OWNER);
        (bool swept,) = DIAMOND.call(abi.encodeWithSignature("withdraw(address)", sink));
        assertTrue(swept, "owner must be able to sweep ETH out");
        assertEq(DIAMOND.balance, 0);
        assertEq(sink.balance, balBefore + 0.05 ether);
    }

    /// The same for a sale settled from a bid, which pays in WETH.
    function test_wethRoyaltiesReachAndLeaveTheContract() public {
        if (!forked) return;
        _applyCut();

        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address whale = 0x2f0B23F53734FA68559FE0B6D2a6d0EF6a4a4e6A; // WETH-rich account
        uint256 amount = 1 ether;

        vm.prank(whale);
        (bool sent,) = WETH.call(abi.encodeWithSignature("transfer(address,uint256)", DIAMOND, amount));
        if (!sent) return; // whale moved on; the local suite already covers the logic

        address sink = makeAddr("wethSink");
        vm.prank(OWNER);
        (bool ok, bytes memory ret) =
            DIAMOND.call(abi.encodeWithSignature("sweepERC20(address,address)", WETH, sink));
        assertTrue(ok, "sweepERC20");
        assertEq(abi.decode(ret, (uint256)), amount);

        (, bytes memory balData) =
            WETH.staticcall(abi.encodeWithSignature("balanceOf(address)", sink));
        assertEq(abi.decode(balData, (uint256)), amount, "WETH must be recoverable");
    }

    function test_stateSurvivesTheCut() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveToken();
        uint256 supplyBefore = souls.totalSupply();
        uint256 balBefore = souls.balanceOf(holder);
        (address recvBefore, uint256 royBefore) = souls.royaltyInfo(id, 1 ether);

        _applyCut();

        assertEq(souls.totalSupply(), supplyBefore, "supply");
        assertEq(souls.balanceOf(holder), balBefore, "balance");
        assertEq(souls.ownerOf(id), holder, "ownership");
        (address recvAfter, uint256 royAfter) = souls.royaltyInfo(id, 1 ether);
        assertEq(recvAfter, recvBefore, "royalty receiver");
        assertEq(royAfter, royBefore, "royalty amount");
        assertEq(souls.owner(), OWNER, "diamond owner");
        assertTrue(souls.supportsInterface(0x80ac58cd), "ERC721 flag survives");
        assertTrue(souls.supportsInterface(0x2a55205a), "ERC2981 flag survives");
    }

    function test_gasCostOfTheExtraValidatorCall() public {
        if (!forked) return;

        (uint256 id, address holder) = _aLiveToken();

        uint256 g0 = gasleft();
        vm.prank(holder);
        souls.transferFrom(holder, buyer, id);
        uint256 before = g0 - gasleft();

        vm.prank(buyer);
        souls.transferFrom(buyer, holder, id);

        _applyCut();

        g0 = gasleft();
        vm.prank(holder);
        souls.transferFrom(holder, buyer, id);
        uint256 afterCut = g0 - gasleft();

        console.log("transferFrom gas before cut:", before);
        console.log("transferFrom gas after  cut:", afterCut);
    }
}
