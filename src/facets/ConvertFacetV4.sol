// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibSouls} from "../libraries/LibSouls.sol";

interface IPikkazo {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
}

/// @title ConvertFacetV4 - payable conversion with a time-stepped price curve
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
/// @notice V3 == V2 with the Order's half wired into the contract itself, and
///         withdraw() taught to respect it.
///
///         WHY THIS IS A REPLACE AND NOT A HELPER: the Order's share used to be
///         credited by the museum with an owner-only call, which meant a wrong
///         number typed once could hand royalties — money that is NOT shared —
///         to the reapers. Now nobody types a number. The contract takes exactly
///         half of what a minter just paid, at the moment they pay it, and can
///         do nothing else. Royalties and the fusion rite never touch that line
///         because they never pass through here (Adrian 04-ago).
///
///         And the mirror of the same worry: withdraw() used to sweep the entire
///         balance, which would have carried the Order's unpaid share out with
///         it. It now sweeps only what is free.
///
///         Everything else is byte-for-byte V2: same pricing, same refunds, same
///         cohort tagging, same events, same guards.
/// @notice V4 == V3 plus the draw riding along with the mint, which is how it
///         was meant to work: no keeper, no extra transaction, no schedule.
///
///         ONE MINT OPENS, THE NEXT ONE SETTLES. A mint sets aside its half and
///         commits the draw to a block two ahead — a block that does not exist
///         yet, so nobody can see who will win. The next mint that comes along
///         reads that block's hash, pays the winner, and commits the following
///         draw. The person minting cannot influence the result: it was fixed by
///         a block mined before they arrived.
///
///         MINTING MUST NEVER FAIL BECAUSE OF THE DRAW. A vault that refuses the
///         money, an expired block hash, an empty roster: each is handled and the
///         mint carries on. The worst case is that the Order's share waits for
///         the next mint, which is exactly where it was anyway.
contract ConvertFacetV4 {
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
    // the 6551 stack, to find a reaper's vault (same constants as the pot facet)
    address private constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address private constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    bytes32 private constant SALT = bytes32(0);
    uint64 private constant DRAW_DELAY = 2;
    uint16 private constant DEFAULT_BASE = 100;
    uint16 private constant DEFAULT_BONUS_CAP = 30;

    event DrawOpened(uint256 pot, uint64 drawBlock);
    event DrawSettled(
        uint256 indexed reaperId, address indexed vault, uint256 amount, uint256 weight, uint256 totalWeight
    );
    event DrawPayoutFailed(uint256 indexed reaperId, address indexed vault, uint256 amount);
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

        // First settle whatever the PREVIOUS mint left open — decided by a block
        // that was mined before this caller showed up — then take this mint's
        // half, then commit the next draw. Never reverts: the mint comes first.
        _settleIfDue(l);

        if (total > 0) {
            // The Order's half, taken from the sum actually charged (never from
            // msg.value: the excess is refunded below and was never revenue).
            // Integer division leaves any odd wei with the museum.
            l.orderPot += total / 2;
            emit ConvertPaid(msg.sender, n, total);
        }

        _openIfIdle(l);

        // interaction last: refund the exact excess to the caller
        uint256 refund = msg.value - total;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        l._reentrancyLock = _NOT_ENTERED;
    }

    // -------------------------------------------------------------- the draw

    /// Pay out the draw the previous mint committed, if its block has been mined
    /// and its hash is still reachable. Any failure leaves the pot untouched and
    /// simply reopens later — a mint is never held hostage by a payout.
    function _settleIfDue(LibSouls.Layout storage l) private {
        uint64 target = l.drawBlock;
        if (target == 0 || block.number <= target) return;

        bytes32 h = blockhash(target);
        if (h == bytes32(0)) {
            l.drawBlock = 0; // older than 256 blocks: recommit below
            return;
        }

        uint256 amount = l.orderPot;
        uint256 n = l.orderRoster.length;
        if (amount == 0 || n == 0) {
            l.drawBlock = 0;
            return;
        }

        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += _weight(l, l.orderRoster[i]);
        }
        uint256 pick = uint256(keccak256(abi.encode(h, target, amount))) % total;

        uint256 cursor;
        uint256 w;
        uint256 winner;
        for (uint256 i; i < n; ++i) {
            uint256 id = l.orderRoster[i];
            w = _weight(l, id);
            cursor += w;
            if (pick < cursor) {
                winner = id;
                break;
            }
        }

        address vault = _vaultOf(winner);

        // effects before interaction, and the interaction cannot revert the mint
        l.orderPot = 0;
        l.drawBlock = 0;
        l.lastWinner = winner;
        l.lastDrawAt = uint64(block.timestamp);

        (bool ok,) = payable(vault).call{value: amount}("");
        if (ok) {
            emit DrawSettled(winner, vault, amount, w, total);
        } else {
            // give it back to the Order and let the next mint try again
            l.orderPot = amount;
            l.lastWinner = 0;
            emit DrawPayoutFailed(winner, vault, amount);
        }
    }

    /// Commit the next draw to a block nobody can see yet.
    function _openIfIdle(LibSouls.Layout storage l) private {
        if (l.drawInMintOff) return;
        if (l.drawBlock != 0) return;
        if (l.orderPot == 0 || l.orderRoster.length == 0) return;
        l.drawBlock = uint64(block.number) + DRAW_DELAY;
        emit DrawOpened(l.orderPot, l.drawBlock);
    }

    function _weight(LibSouls.Layout storage l, uint256 reaperId) private view returns (uint256) {
        uint256 base = l.weightBase == 0 ? DEFAULT_BASE : l.weightBase;
        uint256 cap = l.weightBase == 0 && l.weightBonusCap == 0 ? DEFAULT_BONUS_CAP : l.weightBonusCap;
        uint256 kept = l.balances[_vaultOf(reaperId)];
        return base + (kept < cap ? kept : cap);
    }

    function _vaultOf(uint256 reaperId) private view returns (address) {
        (bool ok, bytes memory ret) = REGISTRY.staticcall(
            abi.encodeWithSignature(
                "account(address,bytes32,uint256,address,uint256)",
                ACCOUNT_PROXY,
                SALT,
                block.chainid,
                address(this),
                reaperId
            )
        );
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @notice Turn the in-mint draw off (or back on). Owner only. With it off,
    ///         the pot still fills and anyone can still run openDraw/settleDraw.
    function setDrawInMint(bool on) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.layout().drawInMintOff = !on;
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

    /// Sweeps only what belongs to the museum: the Order's unpaid share stays
    /// behind, whoever calls this and however often.
    function _sweep(address to) private {
        LibSouls.Layout storage l = LibSouls.layout();
        uint256 bal = address(this).balance - l.orderPot; // delegatecall: this == the diamond
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
