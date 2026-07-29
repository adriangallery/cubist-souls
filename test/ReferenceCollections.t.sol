// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getTransferValidator() external view returns (address);
    function supportsInterface(bytes4) external view returns (bool);
}

/// What do the two reference collections ACTUALLY enforce?
///
/// Both advertise ICreatorToken and point at the canonical validator, and OpenSea
/// shows "Creator earnings are enforced" for them. But their security policy inside
/// the validator is unset. This measures the real behaviour instead of guessing:
/// does an arbitrary operator get blocked on them, or is the validator merely
/// advertised and never consulted?
///
///   ETH_RPC=<url> forge test --match-contract ReferenceCollections -vv
contract ReferenceCollectionsTest is Test {
    address constant PLAYABLE = 0xE7d97e9e47aD0640F92F43f204e5fCce2ce8b20e;
    address constant NON_PLAYABLE = 0xA2a6063B910fC7A7a286196F6c9b62B2797fa0Ae;
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    bool forked;
    address buyer = makeAddr("buyer");
    address randomOperator = makeAddr("randomOperator");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _probe(address collection, string memory label) internal {
        IERC721Like c = IERC721Like(collection);
        console.log(string.concat("=== ", label));
        console.log("  validator:", c.getTransferValidator());
        console.log("  ICreatorToken:", c.supportsInterface(0xad0d7f6c));

        (uint256 id, address holder) = _aToken(collection);
        console.log("  probe token / holder:", id, holder);
        console.log("  holder code size:", holder.code.length);

        // (a) holder moves their own token
        uint256 snap = vm.snapshotState();
        vm.prank(holder);
        (bool okSelf,) =
            collection.call(abi.encodeWithSelector(IERC721Like.transferFrom.selector, holder, buyer, id));
        console.log("  self-transfer allowed:      ", okSelf);
        vm.revertToState(snap);

        // (b) a completely unlisted operator moves it
        snap = vm.snapshotState();
        vm.prank(holder);
        c.setApprovalForAll(randomOperator, true);
        vm.prank(randomOperator);
        (bool okRandom,) =
            collection.call(abi.encodeWithSelector(IERC721Like.transferFrom.selector, holder, buyer, id));
        console.log("  unlisted operator allowed:  ", okRandom);
        vm.revertToState(snap);

        // (c) the OpenSea conduit moves it (what an actual OpenSea sale does)
        snap = vm.snapshotState();
        vm.prank(holder);
        c.setApprovalForAll(OPENSEA_CONDUIT, true);
        vm.prank(OPENSEA_CONDUIT);
        (bool okOS,) =
            collection.call(abi.encodeWithSelector(IERC721Like.transferFrom.selector, holder, buyer, id));
        console.log("  OpenSea conduit allowed:    ", okOS);
        vm.revertToState(snap);
    }

    function _aToken(address collection) internal view returns (uint256 id, address holder) {
        for (uint256 i = 1; i < 5000; i++) {
            try IERC721Like(collection).ownerOf(i) returns (address o) {
                if (o != address(0)) return (i, o);
            } catch {}
        }
        revert("no token found");
    }

    function test_playableCharacters() public {
        if (!forked) return;
        _probe(PLAYABLE, "Playable Characters (0xe7d9...b20e)");
    }

    function test_nonPlayableCharacter() public {
        if (!forked) return;
        _probe(NON_PLAYABLE, "Non Playable Character (0xa2a6...a0ae)");
    }
}
