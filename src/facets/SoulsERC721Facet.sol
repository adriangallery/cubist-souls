// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";
import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";

/// @title SoulsERC721Facet - ERC721 core for Cubist Souls
/// @dev supportsInterface intentionally NOT declared here: it lives on
///      DiamondLoupeFacet reading ds.supportedInterfaces (set in SoulsInit).
contract SoulsERC721Facet {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error NotOwnerNorApproved();
    error NonexistentToken(uint256 tokenId);
    error TransferFromIncorrectOwner();
    error TransferToZero();
    error ApproveToOwner();
    error UnsafeRecipient();

    // --- metadata ---

    function name() external view returns (string memory) {
        return LibSouls.layout().name;
    }

    function symbol() external view returns (string memory) {
        return LibSouls.layout().symbol;
    }

    /// @notice Never reverts for an existing token: if the renderer is unset or
    ///         broken, a minimal inline JSON keeps marketplaces alive.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (!LibSouls.exists(tokenId)) revert NonexistentToken(tokenId);
        address renderer = LibSouls.layout().renderer;
        // code check first: try/catch does NOT catch calls to a codeless address
        if (renderer.code.length > 0) {
            try ISoulRenderer(renderer).tokenURI(tokenId) returns (string memory uri) {
                return uri;
            } catch {}
        }
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"Cubist Soul #',
            _toString(tokenId),
            '","description":"A soul freed from an abandoned canvas. Its shape is still to come."}'
        );
    }

    function contractURI() external view returns (string memory) {
        address renderer = LibSouls.layout().renderer;
        if (renderer.code.length > 0) {
            try ISoulRenderer(renderer).contractURI() returns (string memory uri) {
                return uri;
            } catch {}
        }
        return "";
    }

    // --- supply / balances ---

    function totalSupply() external view returns (uint256) {
        return LibSouls.layout().totalSupply;
    }

    function balanceOf(address owner_) external view returns (uint256) {
        return LibSouls.layout().balances[owner_];
    }

    function ownerOf(uint256 tokenId) public view returns (address owner_) {
        owner_ = LibSouls.layout().owners[tokenId];
        if (owner_ == address(0)) revert NonexistentToken(tokenId);
    }

    // --- approvals ---

    function approve(address to, uint256 tokenId) external {
        address owner_ = ownerOf(tokenId);
        if (to == owner_) revert ApproveToOwner();
        if (msg.sender != owner_ && !LibSouls.layout().operatorApprovals[owner_][msg.sender]) {
            revert NotOwnerNorApproved();
        }
        LibSouls.layout().tokenApprovals[tokenId] = to;
        emit Approval(owner_, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (!LibSouls.exists(tokenId)) revert NonexistentToken(tokenId);
        return LibSouls.layout().tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        LibSouls.layout().operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return LibSouls.layout().operatorApprovals[owner_][operator];
    }

    // --- transfers ---

    function transferFrom(address from, address to, uint256 tokenId) public {
        LibSouls.Layout storage l = LibSouls.layout();
        address owner_ = ownerOf(tokenId);
        if (owner_ != from) revert TransferFromIncorrectOwner();
        if (to == address(0)) revert TransferToZero();
        if (
            msg.sender != owner_ && msg.sender != l.tokenApprovals[tokenId]
                && !l.operatorApprovals[owner_][msg.sender]
        ) revert NotOwnerNorApproved();

        delete l.tokenApprovals[tokenId];
        unchecked {
            l.balances[from] -= 1;
            l.balances[to] += 1;
        }
        l.owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    // --- royalties (ERC2981) ---

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        LibSouls.Layout storage l = LibSouls.layout();
        return (l.royaltyReceiver, (salePrice * l.royaltyBps) / 10_000);
    }

    // --- internals ---

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
