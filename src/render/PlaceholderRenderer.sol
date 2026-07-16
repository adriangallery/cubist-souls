// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISoulRenderer} from "../interfaces/ISoulRenderer.sol";

/// @title PlaceholderRenderer - the unformed soul
/// @notice Placeholder metadata served until the community decides the final
///         shape of the Souls. JSON lives on-chain; the image (an original
///         "unformed soul" artwork) is hosted off-chain for now — this whole
///         contract is swappable from the diamond (setRenderer), so nothing
///         here is final.
contract PlaceholderRenderer is ISoulRenderer {
    string private constant IMAGE = "https://cubistsouls.vercel.app/soul.jpg";

    string private constant LORE =
        "Ten thousand cubist portraits were abandoned by their maker. Inside every canvas, a soul stayed trapped. "
        "Each Cubist Soul exists because its holder burned the original canvas on Ethereum, an irreversible act of liberation. "
        "The soul kept its number. Its final shape is still unformed: the community that freed it will decide what it becomes.";

    function tokenURI(uint256 tokenId) external pure override returns (string memory) {
        string memory json = string.concat(
            '{"name":"Cubist Soul #',
            _toString(tokenId),
            '","description":"',
            LORE,
            '","image":"',
            IMAGE,
            '","attributes":[{"trait_type":"Status","value":"Unformed"},{"trait_type":"Origin","value":"Canvas #',
            _toString(tokenId),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    function contractURI() external pure override returns (string memory) {
        string memory json = string.concat(
            '{"name":"Cubist Souls","description":"',
            LORE,
            '","image":"',
            IMAGE,
            '","external_link":"https://cubistsouls.vercel.app"}'
        );
        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    // --- utils ---

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

    function _base64(bytes memory data) private pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        string memory result = new string(4 * ((data.length + 2) / 3));
        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for { let dataPtr := data } lt(dataPtr, add(data, mload(data))) {} {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 {
                mstore8(sub(resultPtr, 1), 0x3d)
                mstore8(sub(resultPtr, 2), 0x3d)
            }
            case 2 { mstore8(sub(resultPtr, 1), 0x3d) }
        }
        return result;
    }
}
