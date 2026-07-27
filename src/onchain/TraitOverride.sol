// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title TraitOverride - owner-only trait-id redirection table for Cubist Souls
/// @notice A tiny standalone module (NOT a diamond facet) that maps an ORIGINAL
///         composable traitId to a REVISION traitId. SoulRendererV4_1 passes every
///         layer id through `resolve()` before fetching its SVG, so an artist can
///         ship corrected art (uploaded to the SvgStore under a fresh option id)
///         and have it appear in the image WITHOUT touching the immutable
///         token->traits table and WITHOUT changing any attribute (the renderer
///         keeps reading the ORIGINAL id for names).
///
///         Design mirrors the SvgStore/evolution philosophy: owner-only writes,
///         reads NEVER revert, single-hop resolution (no recursion, no loops), and
///         a mapping absence resolves to the identity (same id in, same id out).
///
///         `to == 0` is treated as "no override" on write (use clearOverride to
///         remove), so a mapping can never point a real trait (traitId 0 is a
///         valid trait: Art Background / Color Block) at nothing by accident — a
///         cleared entry always resolves to the identity.
contract TraitOverride {
    address public owner;

    /// original traitId => revision traitId (0 == no override).
    mapping(uint16 => uint16) internal _to;

    event OwnershipTransferred(address indexed from, address indexed to);
    event OverrideSet(uint16 indexed from, uint16 indexed to);
    event OverrideCleared(uint16 indexed from);

    error NotOwner();
    error LengthMismatch();
    error ZeroAddress();
    error SelfOverride();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // =============================================================== admin write

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// @notice Batch set overrides. `from[i]` (an original traitId) will resolve to
    ///         `to[i]` (a revision traitId). Idempotent: re-setting overwrites.
    ///         `to[i] == from[i]` is rejected (would be a no-op loop); use
    ///         clearOverride to remove instead.
    function setOverrides(uint16[] calldata from, uint16[] calldata to) external onlyOwner {
        if (from.length != to.length) revert LengthMismatch();
        for (uint256 i; i < from.length; ++i) {
            if (from[i] == to[i]) revert SelfOverride();
            _to[from[i]] = to[i];
            emit OverrideSet(from[i], to[i]);
        }
    }

    /// @notice Remove an override; `from` resolves back to itself (identity).
    function clearOverride(uint16 from) external onlyOwner {
        delete _to[from];
        emit OverrideCleared(from);
    }

    // ==================================================================== reads

    /// @notice Single-hop resolution. Returns the revision id if one is set, else
    ///         the input id unchanged. Never reverts.
    function resolve(uint16 traitId) external view returns (uint16) {
        uint16 t = _to[traitId];
        return t == 0 ? traitId : t;
    }

    /// @notice The raw mapping value (0 == no override). For indexers/tests.
    function overrideOf(uint16 traitId) external view returns (uint16) {
        return _to[traitId];
    }

    /// @notice Whether `traitId` has an active override.
    function hasOverride(uint16 traitId) external view returns (bool) {
        return _to[traitId] != 0;
    }
}
