// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface IOrder {
    function reaperAccount(uint256 id) external view returns (address account, bool deployed);
    function activateReaperAccount(uint256 id) external returns (address);
    function registerReaper(uint256 id) external;
    function orderRoster() external view returns (uint256[] memory);
    function totalWeight() external view returns (uint256);
    function isReaper(uint256 id) external view returns (bool);
}

/// @title CatchUpOrder - the Order grew while the keeper was blind
///
/// Four souls ascended after the vault backfill (the museum's keeper had been
/// failing on a 403 from the public RPCs, so nobody noticed). This gives the
/// newcomers everything the first eleven already have: a vault of their own and
/// a place on the draw's roster. Both calls are idempotent-safe: the script
/// checks state first and skips whatever is already done.
contract CatchUpOrder is Script {
    address constant DIAMOND = 0x9252fDc0b3945203314Ea1a9b8d64345bc868406;

    uint256[4] NEWCOMERS = [uint256(1650), 2474, 2852, 5728];

    function run() external {
        IOrder d = IOrder(DIAMOND);

        for (uint256 i; i < NEWCOMERS.length; i++) {
            require(d.isReaper(NEWCOMERS[i]), "not ascended");
        }

        vm.startBroadcast();
        for (uint256 i; i < NEWCOMERS.length; i++) {
            uint256 id = NEWCOMERS[i];
            (, bool deployed) = d.reaperAccount(id);
            if (!deployed) {
                address v = d.activateReaperAccount(id);
                console.log("vault opened", id, v);
            }
            if (!_onRoster(d, id)) {
                d.registerReaper(id);
                console.log("registered", id);
            }
        }
        vm.stopBroadcast();

        uint256[] memory roster = d.orderRoster();
        console.log("roster now:", roster.length);
        console.log("totalWeight:", d.totalWeight());
        require(roster.length == 15, "roster should be 15");
        for (uint256 i; i < NEWCOMERS.length; i++) {
            (address v, bool deployed) = d.reaperAccount(NEWCOMERS[i]);
            require(deployed && v.code.length > 0, "vault missing");
        }
    }

    function _onRoster(IOrder d, uint256 id) internal view returns (bool) {
        uint256[] memory roster = d.orderRoster();
        for (uint256 i; i < roster.length; i++) {
            if (roster[i] == id) return true;
        }
        return false;
    }
}
