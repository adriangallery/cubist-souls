// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ConvertFacetV2 - payable conversion with a time-stepped price curve
/// @notice Drop-in replacement for ConvertFacet.convert. It keeps EVERY sacred
///         invariant of the original (supply only via conversion; burn the
///         Pikkazo canvas and mint the SAME tokenId; require ownerOf==sender;
///         max 50/tx; honour convertPaused) and layers on:
///           1. a settable, time-stepped price (free window -> three paid tiers),
///           2. per-token `freedAt` timestamps (cohort tagging + future staking),
///           3. exact-change-with-refund payment (ETH accrues in the diamond),
///           4. a simple reentrancy guard on the refund path.
///
///         The diamond fallback is payable and forwards msg.value on delegatecall,
///         so `convert` receiving ETH here is safe. The `convert(uint256[])`
///         selector (0xd5ef903a) is unchanged: this facet REPLACES the old one
///         for that selector. The old ConvertFacet keeps serving pikkazoContract /
///         convertPaused / isFreed; those selectors are NOT declared here.
contract ConvertFacetV2 {
    /// @notice A canvas burned, a soul freed. Identical to the V1 event so every
    ///         indexer / frontend that watches SoulFreed keeps working unchanged.
    event SoulFreed(address indexed liberator, uint256 indexed tokenId);
    /// @notice Emitted once per paid conversion with the aggregate amount charged.
    event ConvertPaid(address indexed liberator, uint256 count, uint256 paid);
    /// @notice Pricing curve updated by the owner.
    event PricingUpdated(uint64 saleStart, uint32 bound1, uint32 bound2, uint32 bound3, uint256 price1, uint256 price2, uint256 price3);
    /// @notice Treasury (default withdraw destination) updated by the owner.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    /// @notice Accrued ETH swept out of the diamond by the owner.
    event Withdrawn(address indexed to, uint256 amount);

    error ConvertIsPaused();
    error NothingToConvert();
    error TooManyAtOnce();
    error NotYourPikkazo(uint256 tokenId);
    error Underpaid(uint256 required, uint256 provided);
    error RefundFailed();
    error WithdrawFailed();
    error ZeroRecipient();
    error NoTreasury();
    error BadBounds();
    error Reentrancy();

    uint256 private constant MAX_PER_TX = 50;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ---------------------------------------------------------------- convert

    /// @notice Burn `tokenIds` on Pikkazo and free the same ids here, paying
    ///         `priceNow() * tokenIds.length`. Overpayment is refunded; the rest
    ///         accrues in the diamond. Caller must `setApprovalForAll(diamond,true)`
    ///         on Pikkazo first (that is how the diamond passes Pikkazo's burn gate).
    /// @dev Checks-effects-interactions: all state (burn/mint/freedAt) happens
    ///      before the single external ETH send (the refund), which is additionally
    ///      wrapped in a reentrancy guard. `_reentrancyLock` defaults to 0 in
    ///      storage, which is treated as "not entered" (== _NOT_ENTERED for gating).
    function convert(uint256[] calldata tokenIds) external payable {
        LibSouls.Layout storage l = LibSouls.layout();

        if (l._reentrancyLock == _ENTERED) revert Reentrancy();
        l._reentrancyLock = _ENTERED;

        if (l.convertPaused) revert ConvertIsPaused();
        uint256 n = tokenIds.length;
        if (n == 0) revert NothingToConvert();
        if (n > MAX_PER_TX) revert TooManyAtOnce();

        uint256 unit = _priceNow(l);
        uint256 total = unit * n;
        if (msg.value < total) revert Underpaid(total, msg.value);

        IPikkazo pikkazo = IPikkazo(l.pikkazo);
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = tokenIds[i];
            // Binds the soul to the CURRENT canvas owner. The burn below also
            // enforces owner-or-approved, but that alone would let any approved
            // operator burn a third party's token and take the soul.
            if (pikkazo.ownerOf(id) != msg.sender) revert NotYourPikkazo(id);
            pikkazo.burn(id);
            LibSouls.mint(msg.sender, id);
            l.freedAt[id] = nowTs; // cohort tag + future staking duration anchor
            emit SoulFreed(msg.sender, id);
        }

        if (total > 0) emit ConvertPaid(msg.sender, n, total);

        // interaction last: refund the exact excess to the caller
        uint256 refund = msg.value - total;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        l._reentrancyLock = _NOT_ENTERED;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Set the whole pricing curve. Owner only, callable AS MANY TIMES as
    ///         needed — this is the hot-reconfiguration knob: shorten/extend the
    ///         windows or change any price at will and it takes effect from the
    ///         next block. `saleStart == 0` snaps to now (matches "default = now");
    ///         pass an explicit epoch to anchor/rewind the curve. Bounds are
    ///         elapsed-second thresholds and must be non-decreasing (b1<=b2<=b3).
    function setPricing(
        uint64 newSaleStart,
        uint32 b1,
        uint32 b2,
        uint32 b3,
        uint256 p1,
        uint256 p2,
        uint256 p3
    ) external {
        LibDiamond.enforceIsContractOwner();
        if (!(b1 <= b2 && b2 <= b3)) revert BadBounds();
        LibSouls.Layout storage l = LibSouls.layout();
        uint64 start = newSaleStart == 0 ? uint64(block.timestamp) : newSaleStart;
        l.saleStart = start;
        l.bound1 = b1;
        l.bound2 = b2;
        l.bound3 = b3;
        l.price1 = p1;
        l.price2 = p2;
        l.price3 = p3;
        emit PricingUpdated(start, b1, b2, b3, p1, p2, p3);
    }

    /// @notice Set the treasury: the default destination for `withdraw()`. Owner
    ///         only, changeable at any time.
    function setTreasury(address newTreasury) external {
        LibDiamond.enforceIsContractOwner();
        if (newTreasury == address(0)) revert ZeroRecipient();
        LibSouls.Layout storage l = LibSouls.layout();
        emit TreasuryUpdated(l.treasury, newTreasury);
        l.treasury = newTreasury;
    }

    /// @notice Sweep ALL ETH accrued in the diamond to the configured treasury.
    ///         Owner only. Reverts if no treasury is set (use withdraw(address)).
    function withdraw() external {
        LibDiamond.enforceIsContractOwner();
        address to = LibSouls.layout().treasury;
        if (to == address(0)) revert NoTreasury();
        _sweep(to);
    }

    /// @notice Sweep all accrued ETH to an explicit recipient. Owner only.
    ///         Kept as an escape hatch independent of the treasury setting.
    function withdraw(address to) external {
        LibDiamond.enforceIsContractOwner();
        if (to == address(0)) revert ZeroRecipient();
        _sweep(to);
    }

    function _sweep(address to) private {
        uint256 bal = address(this).balance; // delegatecall: this == the diamond
        (bool ok,) = payable(to).call{value: bal}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(to, bal);
    }

    // ------------------------------------------------------------------ views

    /// @notice Price per soul at the current block, following the curve.
    function priceNow() external view returns (uint256) {
        return _priceNow(LibSouls.layout());
    }

    /// @notice Timestamp a soul was freed via V2 convert. 0 for legacy (Genesis).
    function freedAt(uint256 tokenId) external view returns (uint64) {
        return LibSouls.layout().freedAt[tokenId];
    }

    /// @notice Cohort of a soul: 0=Genesis (freed before V2), 1=Free window,
    ///         2=price1 tier, 3=price2 tier, 4=price3 tier.
    function cohortOf(uint256 tokenId) external view returns (uint8) {
        LibSouls.Layout storage l = LibSouls.layout();
        uint64 f = l.freedAt[tokenId];
        if (f == 0) return 0; // legacy soul, no freedAt recorded -> Genesis
        uint256 elapsed = f <= l.saleStart ? 0 : uint256(f) - uint256(l.saleStart);
        if (elapsed < l.bound1) return 1;
        if (elapsed < l.bound2) return 2;
        if (elapsed < l.bound3) return 3;
        return 4;
    }

    function saleStart() external view returns (uint64) {
        return LibSouls.layout().saleStart;
    }

    function treasury() external view returns (address) {
        return LibSouls.layout().treasury;
    }

    /// @notice The full pricing curve in one call.
    function pricing()
        external
        view
        returns (uint64 saleStart_, uint32 bound1, uint32 bound2, uint32 bound3, uint256 price1, uint256 price2, uint256 price3)
    {
        LibSouls.Layout storage l = LibSouls.layout();
        return (l.saleStart, l.bound1, l.bound2, l.bound3, l.price1, l.price2, l.price3);
    }

    // --------------------------------------------------------------- internal

    function _priceNow(LibSouls.Layout storage l) private view returns (uint256) {
        // Saturating elapsed: before saleStart (or unset) -> 0 -> free tier.
        uint256 start = l.saleStart;
        uint256 elapsed = block.timestamp <= start ? 0 : block.timestamp - start;
        if (elapsed < l.bound1) return 0;
        if (elapsed < l.bound2) return l.price1;
        if (elapsed < l.bound3) return l.price2;
        return l.price3;
    }
}
