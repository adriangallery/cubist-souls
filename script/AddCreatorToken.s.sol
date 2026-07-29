// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SoulsCreatorTokenFacet} from "../src/facets/SoulsCreatorTokenFacet.sol";
import {SoulsSweepFacet} from "../src/facets/SoulsSweepFacet.sol";
import {CreatorTokenInit} from "../src/upgradeInitializers/CreatorTokenInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

interface ISoulsAdmin {
    function setRoyaltyInfo(address receiver, uint96 bps) external;
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
}

interface IValidatorAdmin {
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
}

interface ILoupeView {
    function facetAddress(bytes4 selector) external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface ICreatorTokenView {
    function getTransferValidator() external view returns (address);
    function getTransferValidationFunction() external view returns (bytes4, bool);
}

/// @title AddCreatorToken - make Cubist Souls an ERC-721C so OpenSea enforces the 5%.
///
/// This is the collection's ONLY non-additive cut: the three transfer selectors move
/// from SoulsERC721Facet to SoulsCreatorTokenFacet (same bodies + a validator hook).
/// Everything else is an Add.
///
/// What it does NOT do: block anybody. The collection's security policy inside the
/// validator is left UNSET, so validateTransfer is a pass-through and every
/// marketplace (Blur included) keeps working. Turning real blocking on later is a
/// call to setRulesetOfCollection() on the validator — never another diamondCut.
///
/// Dry-run against real mainnet state (no key):
///   forge script script/AddCreatorToken.s.sol --fork-url $RPC -vvv
///
/// Broadcast (ONLY after explicit go-ahead; key via env, never inlined):
///   forge script script/AddCreatorToken.s.sol --rpc-url $RPC \
///     --private-key $DEPLOYER_KEY --broadcast --slow -vvv
contract AddCreatorToken is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    /// Canonical Limit Break CreatorTokenTransferValidator on Ethereum mainnet.
    /// Same one used by Playable Characters (0xe7d9...b20e) and Non Playable
    /// Character (0xa2a6...a0ae).
    address constant VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 constant SEL_SAFE_TRANSFER = 0x42842e0e; // safeTransferFrom(address,address,uint256)
    bytes4 constant SEL_SAFE_TRANSFER_DATA = 0xb88d4fde; // safeTransferFrom(address,address,uint256,bytes)
    bytes4 constant IID_CREATOR_TOKEN = 0xad0d7f6c;
    uint8 constant RULESET_ID_DEFAULT = 0;

    function run() external {
        address validator = vm.envOr("TRANSFER_VALIDATOR", VALIDATOR);
        ILoupeView loupe = ILoupeView(DIAMOND);

        console.log("Diamond:   ", DIAMOND);
        console.log("Validator: ", validator);
        console.log("-- before --");
        console.log("  transferFrom facet:  ", loupe.facetAddress(SEL_TRANSFER_FROM));
        console.log("  ICreatorToken flag:  ", loupe.supportsInterface(IID_CREATOR_TOKEN));

        vm.startBroadcast();

        SoulsCreatorTokenFacet facet = new SoulsCreatorTokenFacet();
        SoulsSweepFacet sweep = new SoulsSweepFacet();
        CreatorTokenInit initializer = new CreatorTokenInit();

        // (1) ADD the ICreatorToken trio
        bytes4[] memory added = new bytes4[](3);
        added[0] = SoulsCreatorTokenFacet.getTransferValidator.selector;
        added[1] = SoulsCreatorTokenFacet.getTransferValidationFunction.selector;
        added[2] = SoulsCreatorTokenFacet.setTransferValidator.selector;

        // (2) REPLACE the three transfer selectors off SoulsERC721Facet
        bytes4[] memory replaced = new bytes4[](3);
        replaced[0] = SEL_TRANSFER_FROM;
        replaced[1] = SEL_SAFE_TRANSFER;
        replaced[2] = SEL_SAFE_TRANSFER_DATA;

        // (3) ADD the ERC20 escape hatch: royalties paid from a bid arrive as WETH,
        //     and without this the diamond could never move them.
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
            facetAddress: address(sweep),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sweepSels
        });

        IDiamondCut(DIAMOND).diamondCut(
            cuts, address(initializer), abi.encodeCall(CreatorTokenInit.init, (validator))
        );

        // (4) Lift the OTC lockout for EIP-7702 delegates and smart wallets, so a
        //     holder on a modern wallet can still move their own soul.
        //     FLAG_RULESET_WHITELIST_ALLOW_OTC_FOR_7702_DELEGATES (1<<1)
        //   | FLAG_RULESET_WHITELIST_ALLOW_OTC_FOR_SMART_WALLETS  (1<<2)
        IValidatorAdmin(validator).setRulesetOfCollection(
            DIAMOND, RULESET_ID_DEFAULT, address(0), 0, (1 << 1) | (1 << 2)
        );

        // (5) Royalties to the contract itself, not to a wallet. Opt-in via env so
        //     the cut can be run without touching where the money goes.
        if (vm.envOr("ROYALTIES_TO_CONTRACT", false)) {
            ISoulsAdmin(DIAMOND).setRoyaltyInfo(DIAMOND, 500); // 5%
        }

        vm.stopBroadcast();

        (bytes4 fn, bool isView) = ICreatorTokenView(DIAMOND).getTransferValidationFunction();
        console.log("-- after --");
        console.log("  facet deployed:      ", address(facet));
        console.log("  transferFrom facet:  ", loupe.facetAddress(SEL_TRANSFER_FROM));
        console.log("  ICreatorToken flag:  ", loupe.supportsInterface(IID_CREATOR_TOKEN));
        console.log("  getTransferValidator:", ICreatorTokenView(DIAMOND).getTransferValidator());
        console.log("  validation fn:       ", vm.toString(fn), isView);

        require(loupe.facetAddress(SEL_TRANSFER_FROM) == address(facet), "transferFrom not replaced");
        require(loupe.facetAddress(SEL_SAFE_TRANSFER) == address(facet), "safeTransferFrom not replaced");
        require(loupe.facetAddress(SEL_SAFE_TRANSFER_DATA) == address(facet), "safeTransferFrom(data) not replaced");
        require(loupe.supportsInterface(IID_CREATOR_TOKEN), "ICreatorToken flag not set");
        require(ICreatorTokenView(DIAMOND).getTransferValidator() == validator, "validator not set");
        require(fn == 0xcaee23ea && !isView, "wrong validation function");
        require(loupe.facetAddress(SoulsSweepFacet.sweepERC20.selector) == address(sweep), "sweep not added");

        (address royaltyReceiver, uint256 royaltyAmount) = ISoulsAdmin(DIAMOND).royaltyInfo(1, 1 ether);
        console.log("  royalty receiver:    ", royaltyReceiver);
        console.log("  royalty on 1 ETH:    ", royaltyAmount);
        require(royaltyAmount == 0.05 ether, "royalty must stay at 5%");
    }
}
