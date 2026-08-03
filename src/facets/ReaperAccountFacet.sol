// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

/// Minimal surface of the canonical ERC-6551 registry (v0.3.1, same address on
/// every chain). `account` computes the deterministic CREATE2 address without
/// deploying; `createAccount` deploys it (and simply returns the address if the
/// account already exists — the registry is idempotent by construction).
interface IERC6551Registry {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);

    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address);
}

/// @title ReaperAccountFacet - every Ascended reaper carries its own vault (ERC-6551)
/// @notice THE GATE: only a Soul that has ASCENDED (soulsConsumed >= 30, the same
///         threshold as ReaperFacet.isReaper) is recognized as having a reaper
///         account. Regular Souls have none — both entrypoints revert NotAscended.
///
///         The ERC-6551 registry itself is permissionless (anyone can deploy a
///         token-bound account for ANY NFT, ours included — that cannot be
///         prevented at the standard level). What this facet defines is OFFICIAL
///         RECOGNITION: the museum only computes, activates and displays accounts
///         for members of the Order. This facet is the single on-chain source of
///         truth the web and any future facet must consult.
///
///         Account stack (verified on mainnet, immutables read from bytecode):
///         canonical registry + Tokenbound AccountProxy initialized to AccountV3.
///         V3 accounts are what tokenbound.app manages natively, so holders get a
///         full asset-management UI (send/receive/sign) for free, and AccountV3
///         carries the ownership-cycle guard (a reaper can never be safe-locked
///         inside its own vault).
///
///         No new storage: ascension state is already in LibSouls, and the
///         registry's CREATE2 determinism makes the account address a pure
///         function of (chainid, diamond, tokenId). Purely additive cut, two
///         selectors. Activation is PERMISSIONLESS and idempotent: the account
///         belongs to whoever holds the reaper, no matter who paid the gas to
///         deploy it — which is what lets the museum keeper auto-activate vaults
///         the moment ReaperAscended fires, at zero cost and zero risk to the
///         holder.
contract ReaperAccountFacet {
    /// Canonical ERC-6551 registry (eip-6551, same address on all chains).
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    /// Tokenbound AccountProxy — the implementation param the registry clones.
    address internal constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    /// Tokenbound AccountV3 — what each fresh proxy is initialized to (this is
    /// AccountProxy's own trusted initialImplementation immutable).
    address internal constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    /// Salt 0 == tokenbound.app default, so the museum and the tokenbound UI
    /// resolve the SAME account for a reaper.
    bytes32 internal constant SALT = bytes32(0);
    /// Mirror of ReaperFacet.ASCENSION_THRESHOLD (>= 30 consumed == Ascended).
    uint256 internal constant ASCENSION_THRESHOLD = 30;

    /// Fired once per reaper, when its vault is actually deployed.
    event ReaperAccountActivated(uint256 indexed reaperId, address indexed account);

    /// The Soul exists but has not consumed >= 30 canvases — regular Souls have
    /// no reaper account, by design.
    error NotAscended(uint256 reaperId);
    /// The fresh account's initialize(AccountV3) call failed — should be
    /// unreachable (V3 is the proxy's own trusted initial implementation), kept
    /// loud instead of silent so a broken deploy can never masquerade as a vault.
    error AccountInitFailed(address account);

    // ------------------------------------------------------------------- view

    /// @notice The official vault address of an Ascended reaper, plus whether it
    ///         is deployed yet. Reverts for regular Souls (NotAscended) and for
    ///         ids that are not Souls at all (SoulDoesNotExist).
    function reaperAccount(uint256 reaperId) external view returns (address account, bool deployed) {
        _requireAscended(reaperId);
        account = IERC6551Registry(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, address(this), reaperId);
        deployed = account.code.length > 0;
    }

    // ---------------------------------------------------------------- activate

    /// @notice Deploy (or heal) the vault of an Ascended reaper. Permissionless:
    ///         the account is CREATE2-bound to the token, so whoever calls this
    ///         only ever gifts gas — control always follows ownerOf(reaperId).
    ///         Idempotent: calling again on a live vault is a harmless no-op that
    ///         returns the same address.
    function activateReaperAccount(uint256 reaperId) external returns (address account) {
        _requireAscended(reaperId);
        account = IERC6551Registry(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, address(this), reaperId);
        bool fresh = account.code.length == 0;
        if (fresh) {
            IERC6551Registry(REGISTRY).createAccount(ACCOUNT_PROXY, SALT, block.chainid, address(this), reaperId);
        }
        // Initialize the proxy to AccountV3. On a fresh account this MUST succeed
        // (AccountInitFailed otherwise). On an existing account the call reverts
        // AlreadyInitialized and is deliberately ignored — except in the odd case
        // where a third party createAccount()'d raw via the registry and never
        // initialized: then this call heals the vault into a working V3 account.
        (bool ok,) = account.call(abi.encodeWithSignature("initialize(address)", ACCOUNT_V3));
        if (fresh) {
            if (!ok) revert AccountInitFailed(account);
            emit ReaperAccountActivated(reaperId, account);
        }
    }

    // ---------------------------------------------------------------- internal

    function _requireAscended(uint256 reaperId) internal view {
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.owners[reaperId] == address(0)) revert LibSouls.SoulDoesNotExist(reaperId);
        if (l.soulsConsumed[reaperId] < ASCENSION_THRESHOLD) revert NotAscended(reaperId);
    }
}
