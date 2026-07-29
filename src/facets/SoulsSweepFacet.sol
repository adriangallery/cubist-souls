// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @title SoulsSweepFacet - ERC20 escape hatch for the diamond
///
/// @notice The diamond can already receive and sweep ETH (`receive()` +
///         ConvertFacetV2.withdraw). It cannot move ERC20s — and it needs to, the
///         moment the collection points its royalties at itself: an OpenSea sale
///         paid from a bid settles in **WETH**, not ETH. Without this facet that
///         WETH would land in the diamond and stay there forever.
///
/// @dev Additive cut. Owner only. Non-standard tokens that return no boolean are
///      handled the way OpenZeppelin's SafeERC20 does: success plus either empty
///      returndata or a true word.
contract SoulsSweepFacet {
    event SweptERC20(address indexed token, address indexed to, uint256 amount);

    error ZeroRecipient();
    error ZeroToken();
    error SweepFailed();

    /// @notice Send the diamond's entire balance of `token` to `to`. Owner only.
    /// @return amount The balance that was moved (0 is a no-op, not an error).
    function sweepERC20(address token, address to) external returns (uint256 amount) {
        LibDiamond.enforceIsContractOwner();
        if (token == address(0)) revert ZeroToken();
        if (to == address(0)) revert ZeroRecipient();

        (bool okBal, bytes memory balData) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, address(this))); // balanceOf(address)
        if (!okBal || balData.length < 32) revert SweepFailed();
        amount = abi.decode(balData, (uint256));
        if (amount == 0) return 0;

        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SweepFailed();

        emit SweptERC20(token, to, amount);
    }

    /// @notice What the diamond currently holds of `token`. Convenience view so the
    ///         royalty balance is readable without an indexer.
    function erc20Balance(address token) external view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
