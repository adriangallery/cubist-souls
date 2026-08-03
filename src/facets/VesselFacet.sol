// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC6551Registry} from "./ReaperAccountFacet.sol";

/// @title VesselFacet - thirty souls join forces inside a sacrificed canvas
///
/// @notice THE UNION (ratified by Adrian 03-ago-2026): 30 regular Souls, all
///         held by one collector, fuse into a VESSEL — a new token minted over
///         a canvas that a reaper consumed. Those canvas ids are the only ids
///         provably free forever: the rescue guard says no SOUL can ever mint
///         there, and a vessel is deliberately NOT a soul (isVessel marks it,
///         freedAt is sealed at fuse time so cohort logic can never read it as
///         OG/Genesis).
///
///         CUSTODY, NOT VAULT: the 30 members are transferred to the diamond
///         itself. They do not live in the vessel's ERC-6551 account — there
///         the owner could extract them with execute() and farm new vessels.
///         No selector in the diamond releases custody; "dissolve" is a future
///         additive cut to be designed when the holdings question is answered.
///         The vessel's vault IS created (inside the fuse tx, founder pays the
///         gas) — reserved for whatever the museum binds to vessels later.
///
///         THE DELIBERATE BYPASS: minting over a consumed canvas contradicts
///         the public reading of the rescue guard ("a consumed canvas never
///         mints"). This facet does it EXPLICITLY and only here: the guard in
///         LibSouls.mint() is untouched and keeps protecting every other mint
///         path forever. A public dev update must precede the first fusion
///         (transparency is the house style).
///
///         Purely additive cut. Rite fee (vesselFee, seeded 0.0005 ETH by
///         VesselInit, owner-adjustable) accrues in the diamond and leaves via
///         the existing ConvertFacetV2.withdraw() to treasury.
contract VesselFacet {
    // Same verified ERC-6551 stack as ReaperAccountFacet (mainnet immutables).
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    address internal constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    bytes32 internal constant SALT = bytes32(0);

    uint256 internal constant UNION_SIZE = 30;
    uint256 internal constant MAX_NAME_BYTES = 64;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event VesselFused(
        uint256 indexed vesselId, address indexed founder, address vault, string name, uint256[] members
    );
    event VesselRenamed(uint256 indexed vesselId, string name);
    event VesselFeeSet(uint256 fee);

    error WrongFee(uint256 want, uint256 got);
    error NeedExactlyThirty(uint256 got);
    error NotYourSoul(uint256 soulId);
    error SoulCarriesFire(uint256 soulId); // consumed > 0: the fire and the communion are separate paths
    error AlreadyInUnion(uint256 soulId); // fused already, or duplicated in the list
    error VesselsCannotJoin(uint256 id);
    error CanvasNotConsumed(uint256 canvasId);
    error CanvasTaken(uint256 canvasId);
    error BadName();
    error NotAVessel(uint256 id);
    error NotVesselOwner(uint256 vesselId);
    error VaultCreateFailed(address vault);
    error Reentrancy();

    // ------------------------------------------------------------------ rite

    /// @notice Fuse exactly 30 of your souls into a vessel minted over the
    ///         consumed canvas of your choice. Pays the rite fee to the museum.
    ///         The members pass into the diamond's custody — permanently, until
    ///         a future dissolution facet says otherwise. The vessel's ERC-6551
    ///         vault is created in this same transaction, on your gas.
    function fuse(uint256 canvasId, uint256[] calldata soulIds, string calldata name)
        external
        payable
        returns (address vault)
    {
        LibSouls.Layout storage l = LibSouls.layout();
        _lock(l);

        if (msg.value != l.vesselFee) revert WrongFee(l.vesselFee, msg.value);
        if (soulIds.length != UNION_SIZE) revert NeedExactlyThirty(soulIds.length);
        if (bytes(name).length == 0 || bytes(name).length > MAX_NAME_BYTES) revert BadName();

        // the chosen canvas: consumed by a reaper (provably never a soul), still free
        if (canvasId == 0 || !l.canvasConsumed[canvasId]) revert CanvasNotConsumed(canvasId);
        if (l.owners[canvasId] != address(0)) revert CanvasTaken(canvasId);

        // take the thirty into custody
        for (uint256 i = 0; i < UNION_SIZE; i++) {
            uint256 id = soulIds[i];
            if (l.fusedInto[id] != 0) revert AlreadyInUnion(id); // also catches duplicates
            if (l.isVessel[id]) revert VesselsCannotJoin(id);
            if (l.owners[id] != msg.sender) revert NotYourSoul(id);
            if (l.soulsConsumed[id] != 0) revert SoulCarriesFire(id);

            l.fusedInto[id] = canvasId;
            delete l.tokenApprovals[id];
            l.owners[id] = address(this);
            emit Transfer(msg.sender, address(this), id);
        }
        unchecked {
            l.balances[msg.sender] -= UNION_SIZE;
            l.balances[address(this)] += UNION_SIZE;
        }
        l.vesselMembers[canvasId] = soulIds;

        // mint the vessel — the ONE deliberate bypass of the rescue guard.
        // freedAt is sealed NOW: cohort logic must never read a vessel as OG.
        l.owners[canvasId] = msg.sender;
        l.isVessel[canvasId] = true;
        l.vesselName[canvasId] = name;
        l.freedAt[canvasId] = uint64(block.timestamp);
        unchecked {
            l.balances[msg.sender] += 1;
            l.totalSupply += 1;
        }
        emit Transfer(address(0), msg.sender, canvasId);

        // the vessel's vault, on the founder's gas — atomic with the fusion
        vault = IERC6551Registry(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, address(this), canvasId);
        if (vault.code.length == 0) {
            IERC6551Registry(REGISTRY).createAccount(ACCOUNT_PROXY, SALT, block.chainid, address(this), canvasId);
            (bool ok,) = vault.call(abi.encodeWithSignature("initialize(address)", ACCOUNT_V3));
            if (!ok) revert VaultCreateFailed(vault);
        }

        emit VesselFused(canvasId, msg.sender, vault, name, soulIds);
        _unlock(l);
    }

    /// @notice Rename the plaque. Only the vessel's current holder.
    function renameVessel(uint256 vesselId, string calldata newName) external {
        LibSouls.Layout storage l = LibSouls.layout();
        if (!l.isVessel[vesselId]) revert NotAVessel(vesselId);
        if (l.owners[vesselId] != msg.sender) revert NotVesselOwner(vesselId);
        if (bytes(newName).length == 0 || bytes(newName).length > MAX_NAME_BYTES) revert BadName();
        l.vesselName[vesselId] = newName;
        emit VesselRenamed(vesselId, newName);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Retune the rite fee. Owner only.
    function setVesselFee(uint256 fee) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.layout().vesselFee = fee;
        emit VesselFeeSet(fee);
    }

    // ----------------------------------------------------------------- views

    function vesselFee() external view returns (uint256) {
        return LibSouls.layout().vesselFee;
    }

    function isVesselToken(uint256 id) external view returns (bool) {
        return LibSouls.layout().isVessel[id];
    }

    function vesselNameOf(uint256 vesselId) external view returns (string memory) {
        return LibSouls.layout().vesselName[vesselId];
    }

    function membersOf(uint256 vesselId) external view returns (uint256[] memory) {
        return LibSouls.layout().vesselMembers[vesselId];
    }

    /// @notice The vessel holding a soul (0 == the soul is free).
    function vesselOf(uint256 soulId) external view returns (uint256) {
        return LibSouls.layout().fusedInto[soulId];
    }

    /// @notice THE attribution primitive (Adrian 03-ago: power counts for the
    ///         vessel's owner, flexibly). For a fused soul: the wallet holding
    ///         its vessel. For anything else: the direct owner. Every reader
    ///         (govern, raffle, board) should attribute through this single
    ///         view so tomorrow's policy change is one facet Replace, not a
    ///         scavenger hunt.
    function custodianOf(uint256 soulId) external view returns (address) {
        LibSouls.Layout storage l = LibSouls.layout();
        uint256 vessel = l.fusedInto[soulId];
        if (vessel != 0) return l.owners[vessel];
        return l.owners[soulId];
    }

    /// @notice The vessel's ERC-6551 vault (created at fuse, so `deployed` is
    ///         true for any real vessel).
    function vesselVault(uint256 vesselId) external view returns (address vault, bool deployed) {
        LibSouls.Layout storage l = LibSouls.layout();
        if (!l.isVessel[vesselId]) revert NotAVessel(vesselId);
        vault = IERC6551Registry(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, address(this), vesselId);
        deployed = vault.code.length > 0;
    }

    // -------------------------------------------------------------- internal

    function _lock(LibSouls.Layout storage l) private {
        if (l._reentrancyLock == _ENTERED) revert Reentrancy();
        l._reentrancyLock = _ENTERED;
    }

    function _unlock(LibSouls.Layout storage l) private {
        l._reentrancyLock = _NOT_ENTERED;
    }
}
