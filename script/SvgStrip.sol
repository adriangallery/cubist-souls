// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title SvgStrip - extract the inner content of a full SVG document
/// @notice Off-chain helper (runs inside forge script / tests, never deployed).
///         The onchain-data/svg/*.svg files are complete documents:
///         optionally a leading `<?xml ... ?>` declaration, then a single
///         `<svg ...>` root, content, and a trailing `</svg>`. The renderer only
///         concatenates inner content under its own clean root, so we must strip
///         the outer wrapper before uploading.
library SvgStrip {
    /// @notice Returns everything between the end of the opening `<svg ...>` tag
    ///         and the final `</svg>`. Reverts on malformed input (fine: this is
    ///         build-time tooling, not on-chain).
    function inner(bytes memory doc) internal pure returns (bytes memory) {
        uint256 n = doc.length;

        // Find the start of the "<svg" root element.
        uint256 svgTag = _indexOf(doc, "<svg", 0);
        require(svgTag != type(uint256).max, "no <svg");

        // The opening tag ends at the first '>' at or after svgTag. (These files
        // are minified attribute SVGs with no '>' inside attribute values.)
        uint256 gt = type(uint256).max;
        for (uint256 i = svgTag; i < n; ++i) {
            if (doc[i] == ">") {
                gt = i;
                break;
            }
        }
        require(gt != type(uint256).max, "no opening >");
        uint256 start = gt + 1;

        // Find the last "</svg>".
        uint256 close = _lastIndexOf(doc, "</svg>");
        require(close != type(uint256).max && close >= start, "no </svg>");

        uint256 len = close - start;
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = doc[start + i];
        }
        return out;
    }

    function _indexOf(bytes memory hay, bytes memory needle, uint256 from)
        private
        pure
        returns (uint256)
    {
        uint256 hn = hay.length;
        uint256 nn = needle.length;
        if (nn == 0 || nn > hn) return type(uint256).max;
        for (uint256 i = from; i + nn <= hn; ++i) {
            bool m = true;
            for (uint256 j; j < nn; ++j) {
                if (hay[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return i;
        }
        return type(uint256).max;
    }

    function _lastIndexOf(bytes memory hay, bytes memory needle) private pure returns (uint256) {
        uint256 hn = hay.length;
        uint256 nn = needle.length;
        if (nn == 0 || nn > hn) return type(uint256).max;
        for (uint256 i = hn - nn + 1; i > 0; --i) {
            uint256 k = i - 1;
            bool m = true;
            for (uint256 j; j < nn; ++j) {
                if (hay[k + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return k;
        }
        return type(uint256).max;
    }
}
