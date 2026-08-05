// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC6551Registry} from "./ReaperAccountFacet.sol";

/// @title OrderPotFacet - the museum pays the Order, one member at a time
///
/// @notice Half of every burn-to-mint fee is set aside for the Order and paid
///         out, whole, to a SINGLE reaper drawn at random (Adrian 04-ago-2026).
///         Royalties and the fusion rite are NOT shared: they keep the museum
///         running. Memento Mori do not take part — for now.
///
///         TWO THINGS MAKE THIS SAFE:
///
///         1. The draw NEVER happens in the transaction that pays. If the
///            winner were decided while someone was minting, a minter holding a
///            reaper could read the outcome before signing and only mint when
///            their own piece wins — minting free, forever. So a draw is opened
///            first and settled later, against the hash of a block that did not
///            exist when it was opened. Nobody can grind a future block.
///
///         2. The pot is an ACCOUNTING line, not a second balance. The ETH sits
///            in the diamond the whole time and only moves when a draw settles,
///            so it can never be double-spent by withdraw(): crediting requires
///            the balance to be there.
///
///         WEIGHT: a reaper's odds are `1 + the number of tokens its vault
///         holds`. Feeding souls to your reaper makes it likelier to be chosen —
///         and since the vault is bound to the token, that strength is part of
///         the piece and travels with it when sold. The base 1 means an empty
///         reaper is never excluded, only outmatched. Reading a vault's holdings
///         is free: they are balances in this very contract.
contract OrderPotFacet {
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    bytes32 internal constant SALT = bytes32(0);
    uint256 internal constant ASCENSION_THRESHOLD = 30;
    uint64 internal constant DRAW_DELAY = 2; // blocks between opening and settling

    event ReaperRegistered(uint256 indexed reaperId, uint256 rosterSize);
    event OrderCredited(uint256 amount, uint256 pot);
    event DrawOpened(uint256 pot, uint64 drawBlock);
    event DrawSettled(uint256 indexed reaperId, address indexed vault, uint256 amount, uint256 weight, uint256 totalWeight);

    error NotAscended(uint256 reaperId);
    error AlreadyRegistered(uint256 reaperId);
    error EmptyRoster();
    error EmptyPot();
    error DrawAlreadyOpen();
    error NoDrawOpen();
    error TooEarly(uint64 drawBlock);
    error DrawExpired(); // >256 blocks: blockhash is gone, reopen
    error InsufficientBalance(uint256 free, uint256 asked);
    error PayoutFailed(address vault);

    // ------------------------------------------------------------- membership

    /// @notice Put an Ascended reaper on the roster. Permissionless: the contract
    ///         checks the ascension itself, so anyone (the museum's keeper, the
    ///         holder, a bystander) can pay the gas. Membership is permanent.
    function registerReaper(uint256 reaperId) external {
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.soulsConsumed[reaperId] < ASCENSION_THRESHOLD) revert NotAscended(reaperId);
        if (l.inOrderRoster[reaperId]) revert AlreadyRegistered(reaperId);
        l.inOrderRoster[reaperId] = true;
        l.orderRoster.push(reaperId);
        emit ReaperRegistered(reaperId, l.orderRoster.length);
    }

    // ----------------------------------------------------------------- credit

    /// @notice Earmark `amount` of the diamond's ETH for the Order. Owner only —
    ///         the museum credits the Order's half of each burn-to-mint fee.
    ///         Cannot earmark ETH that is not there, and cannot earmark twice.
    function creditOrder(uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibSouls.Layout storage l = LibSouls.layout();
        uint256 free = address(this).balance - l.orderPot;
        if (amount > free) revert InsufficientBalance(free, amount);
        l.orderPot += amount;
        emit OrderCredited(amount, l.orderPot);
    }

    // ------------------------------------------------------------------- draw

    /// @notice Open a draw. Fixes the FUTURE block whose hash picks the winner.
    ///         Permissionless — but nobody can see that block yet, which is the
    ///         whole point.
    function openDraw() external {
        LibSouls.Layout storage l = LibSouls.layout();
        if (l.orderPot == 0) revert EmptyPot();
        if (l.orderRoster.length == 0) revert EmptyRoster();
        if (l.drawBlock != 0) revert DrawAlreadyOpen();
        l.drawBlock = uint64(block.number) + DRAW_DELAY;
        emit DrawOpened(l.orderPot, l.drawBlock);
    }

    /// @notice Settle the open draw: pick a member weighted by the souls their
    ///         vault holds and send the whole pot to that vault. Permissionless;
    ///         the result is already fixed by the block hash, so it does not
    ///         matter who submits it.
    function settleDraw() external returns (uint256 reaperId, address vault, uint256 amount) {
        LibSouls.Layout storage l = LibSouls.layout();
        uint64 target = l.drawBlock;
        if (target == 0) revert NoDrawOpen();
        if (block.number <= target) revert TooEarly(target);

        bytes32 h = blockhash(target);
        if (h == bytes32(0)) {
            // more than 256 blocks late: the hash is unreachable, reopen instead
            l.drawBlock = uint64(block.number) + DRAW_DELAY;
            emit DrawOpened(l.orderPot, l.drawBlock);
            revert DrawExpired();
        }

        uint256 total = _totalWeight(l);
        uint256 pick = uint256(keccak256(abi.encode(h, target, l.orderPot))) % total;

        uint256 n = l.orderRoster.length;
        uint256 cursor;
        uint256 w;
        for (uint256 i; i < n; ++i) {
            uint256 id = l.orderRoster[i];
            w = _weight(l, id);
            cursor += w;
            if (pick < cursor) {
                reaperId = id;
                break;
            }
        }

        amount = l.orderPot;
        l.orderPot = 0;
        l.drawBlock = 0;
        l.lastWinner = reaperId;
        l.lastDrawAt = uint64(block.timestamp);

        vault = vaultOf(reaperId);
        (bool ok,) = payable(vault).call{value: amount}("");
        if (!ok) revert PayoutFailed(vault);

        emit DrawSettled(reaperId, vault, amount, w, total);
    }

    // ------------------------------------------------------------------ views

    function orderPot() external view returns (uint256) {
        return LibSouls.layout().orderPot;
    }

    function orderRoster() external view returns (uint256[] memory) {
        return LibSouls.layout().orderRoster;
    }

    /// @notice A reaper's odds: 1, plus every token its vault holds.
    function weightOf(uint256 reaperId) external view returns (uint256) {
        LibSouls.Layout storage l = LibSouls.layout();
        if (!l.inOrderRoster[reaperId]) return 0;
        return _weight(l, reaperId);
    }

    function totalWeight() external view returns (uint256) {
        return _totalWeight(LibSouls.layout());
    }

    /// @notice The open draw, if any: the block that will decide it and whether
    ///         it can be settled now.
    function pendingDraw() external view returns (uint64 drawBlock_, bool settleable, uint256 pot) {
        LibSouls.Layout storage l = LibSouls.layout();
        drawBlock_ = l.drawBlock;
        settleable = drawBlock_ != 0 && block.number > drawBlock_;
        pot = l.orderPot;
    }

    function lastDraw() external view returns (uint256 winner, uint64 at) {
        LibSouls.Layout storage l = LibSouls.layout();
        return (l.lastWinner, l.lastDrawAt);
    }

    /// @notice The 6551 account bound to a reaper — where its winnings land, and
    ///         where its souls are kept.
    function vaultOf(uint256 reaperId) public view returns (address) {
        return IERC6551Registry(REGISTRY).account(ACCOUNT_PROXY, SALT, block.chainid, address(this), reaperId);
    }

    // --------------------------------------------------------------- internal

    function _weight(LibSouls.Layout storage l, uint256 reaperId) private view returns (uint256) {
        return 1 + l.balances[vaultOf(reaperId)];
    }

    function _totalWeight(LibSouls.Layout storage l) private view returns (uint256 total) {
        uint256 n = l.orderRoster.length;
        for (uint256 i; i < n; ++i) {
            total += _weight(l, l.orderRoster[i]);
        }
    }
}
