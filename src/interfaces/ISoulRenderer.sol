// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ISoulRenderer - swappable art module for Cubist Souls
/// @notice The diamond delegates all metadata here. Swap the renderer to change
///         the art; freeze it (in the diamond) once the final art is decided.
interface ISoulRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function contractURI() external view returns (string memory);
}
