// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title SSTORE2 - read/write bytes to contract code (cheap large storage)
/// @notice Minimal vendored implementation (solady/0xSequence lineage). Data is
///         written as the runtime code of a freshly deployed contract, prefixed
///         with a single 0x00 STOP byte so the "data contract" can never be
///         executed. Reads copy the code back with EXTCODECOPY.
/// @dev Max payload is 24575 bytes (EIP-170 contract-size limit 24576 minus the
///      1-byte STOP prefix). Callers that need more must split across pointers.
library SSTORE2 {
    error DeploymentFailed();
    error ReadOutOfBounds();

    /// @notice Writes `data` to a new data contract and returns its address.
    function write(bytes memory data) internal returns (address pointer) {
        // Creation code that RETURNs (STOP-prefixed `data`) as runtime code.
        //
        //   0x00  61 <len+1>   PUSH2 codeLen      (runtime size incl. STOP byte)
        //   0x03  80           DUP1
        //   0x04  60 0a        PUSH1 0x0a         (offset of runtime in this init code)
        //   0x06  3d           RETURNDATASIZE     (0)
        //   0x07  39           CODECOPY
        //   0x08  3d           RETURNDATASIZE     (0)
        //   0x09  f3           RETURN
        //   0x0a  00           STOP               (the prefix byte)
        //   0x0b..            <data>
        uint256 len = data.length;
        // runtime length = data length + 1 (STOP byte); guard the 2-byte PUSH.
        if (len + 1 > 0xffff) revert DeploymentFailed();

        bytes memory initCode = abi.encodePacked(
            hex"61",
            uint16(len + 1),
            hex"80600a3d393df300",
            data
        );

        assembly {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert DeploymentFailed();
    }

    /// @notice Reads the full payload stored at `pointer` (skips the STOP byte).
    function read(address pointer) internal view returns (bytes memory) {
        uint256 size = pointer.code.length;
        if (size == 0) return "";
        return _readCode(pointer, 1, size);
    }

    /// @notice Reads `data[start:end]` from the payload stored at `pointer`.
    /// @param start inclusive start offset into the logical payload (0-based)
    /// @param end   exclusive end offset into the logical payload
    function read(address pointer, uint256 start, uint256 end) internal view returns (bytes memory) {
        // +1 on each side to skip the STOP prefix byte.
        uint256 size = pointer.code.length;
        if (size == 0 || end + 1 > size || start > end) revert ReadOutOfBounds();
        return _readCode(pointer, start + 1, end + 1);
    }

    function _readCode(address pointer, uint256 start, uint256 end) private view returns (bytes memory out) {
        uint256 n = end - start;
        out = new bytes(n);
        assembly {
            extcodecopy(pointer, add(out, 0x20), start, n)
        }
    }

    /// @notice Logical payload length stored at `pointer` (0 if empty/nonexistent).
    function length(address pointer) internal view returns (uint256) {
        uint256 size = pointer.code.length;
        return size == 0 ? 0 : size - 1;
    }
}
