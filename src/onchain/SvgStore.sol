// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SSTORE2} from "./SSTORE2.sol";

/// @title SvgStore - fully on-chain SVG + token->trait registry for Cubist Souls
/// @notice Standalone (NOT a diamond facet) so it can be deployed and loaded
///         without touching the live diamond. Holds:
///           - the inner SVG content of every composable trait (cats 0-8),
///             keyed by traitId = (cat<<8)|opt, each as one-or-more SSTORE2
///             pointers (a trait may span several pointers if > 24575 bytes);
///           - one-of-one SVGs keyed by an arbitrary id;
///           - the 80,000-byte token->traits table (10000 tokens x 8 bytes),
///             split across fixed-size SSTORE2 chunks, read via traitsOf().
///
///         Writes are owner-only and can be frozen forever with seal(). All
///         reads are non-reverting so a consuming renderer never bricks: a
///         missing trait yields "" and a not-yet-uploaded token yields 0xFF x8.
contract SvgStore {
    using SSTORE2 for address;

    // ------------------------------------------------------------------ config
    uint256 public constant MAX_TOKENS = 10_000;
    uint256 public constant TOKENS_PER_CHUNK = 2_500; // 2500 * 8 = 20,000 bytes/pointer
    uint256 internal constant BYTES_PER_TOKEN = 8;

    // ------------------------------------------------------------------ storage
    address public owner;
    bool public frozen;

    struct Asset {
        string name;
        address[] pointers;
    }

    // traitId (cat<<8)|opt  =>  inner-SVG asset
    mapping(uint16 => Asset) internal _traits;
    // one-of-one id (e.g. tokenId, or 0 for the yet-unassigned Adrian) => asset
    mapping(uint256 => Asset) internal _oneOfOnes;
    // token->traits table, one pointer per chunk of TOKENS_PER_CHUNK tokens
    address[] internal _tokenTraitChunks;

    // ------------------------------------------------------------------ events
    event TraitStored(uint16 indexed traitId, uint256 pointerCount, uint256 byteLength);
    event OneOfOneStored(uint256 indexed id, uint256 pointerCount, uint256 byteLength);
    event TokenTraitsChunkStored(uint256 indexed chunkIndex, uint256 byteLength);
    event OwnershipTransferred(address indexed from, address indexed to);
    event Sealed();

    // ------------------------------------------------------------------ errors
    error NotOwner();
    error IsSealed();
    error AlreadyStored();
    error EmptyData();
    error BadChunkIndex();
    error BadChunkLength();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notSealed() {
        if (frozen) revert IsSealed();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // =============================================================== admin write

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// @notice One-way freeze of all write functions.
    function seal() external onlyOwner {
        frozen = true;
        emit Sealed();
    }

    /// @notice Store the inner SVG content of a composable trait. Idempotent-
    ///         friendly: reverts AlreadyStored if the traitId already has data,
    ///         so an interrupted upload can be resumed by skipping stored ids.
    ///         Splits `inner` across as many SSTORE2 pointers as needed.
    function setTrait(uint16 traitId, string calldata name, bytes calldata inner)
        external
        onlyOwner
        notSealed
    {
        if (inner.length == 0) revert EmptyData();
        Asset storage a = _traits[traitId];
        if (a.pointers.length != 0) revert AlreadyStored();
        a.name = name;
        _storePointers(a.pointers, inner);
        emit TraitStored(traitId, a.pointers.length, inner.length);
    }

    /// @notice Store a one-of-one SVG under an arbitrary id.
    function setOneOfOne(uint256 id, string calldata name, bytes calldata inner)
        external
        onlyOwner
        notSealed
    {
        if (inner.length == 0) revert EmptyData();
        Asset storage a = _oneOfOnes[id];
        if (a.pointers.length != 0) revert AlreadyStored();
        a.name = name;
        _storePointers(a.pointers, inner);
        emit OneOfOneStored(id, a.pointers.length, inner.length);
    }

    /// @notice Append the next chunk of the token->traits table. Chunks must be
    ///         uploaded in order; `chunkIndex` must equal the current count.
    ///         Every chunk is exactly TOKENS_PER_CHUNK*8 bytes (the table is an
    ///         exact multiple, 10000/2500 = 4 chunks).
    function setTokenTraitsChunk(uint256 chunkIndex, bytes calldata data)
        external
        onlyOwner
        notSealed
    {
        if (chunkIndex != _tokenTraitChunks.length) revert BadChunkIndex();
        if (data.length != TOKENS_PER_CHUNK * BYTES_PER_TOKEN) revert BadChunkLength();
        _tokenTraitChunks.push(SSTORE2.write(data));
        emit TokenTraitsChunkStored(chunkIndex, data.length);
    }

    function _storePointers(address[] storage pointers, bytes calldata inner) private {
        uint256 max = 24_575; // SSTORE2 per-pointer payload limit
        uint256 off;
        uint256 len = inner.length;
        while (off < len) {
            uint256 end = off + max;
            if (end > len) end = len;
            pointers.push(SSTORE2.write(inner[off:end]));
            off = end;
        }
    }

    // ==================================================================== reads

    // --- traits ---

    function traitExists(uint16 traitId) external view returns (bool) {
        return _traits[traitId].pointers.length != 0;
    }

    function traitName(uint16 traitId) external view returns (string memory) {
        return _traits[traitId].name;
    }

    function traitPointerCount(uint16 traitId) external view returns (uint256) {
        return _traits[traitId].pointers.length;
    }

    /// @notice Concatenated inner SVG for a trait; "" if not stored. Never reverts.
    function traitSvg(uint16 traitId) external view returns (bytes memory) {
        return _concat(_traits[traitId].pointers);
    }

    // --- one-of-ones ---

    function oneOfOneExists(uint256 id) external view returns (bool) {
        return _oneOfOnes[id].pointers.length != 0;
    }

    function oneOfOneName(uint256 id) external view returns (string memory) {
        return _oneOfOnes[id].name;
    }

    function oneOfOneSvg(uint256 id) external view returns (bytes memory) {
        return _concat(_oneOfOnes[id].pointers);
    }

    // --- token->traits table ---

    function tokenTraitChunkCount() external view returns (uint256) {
        return _tokenTraitChunks.length;
    }

    /// @notice The 8 option indices for a token (order = z-order cats 0..7).
    ///         Returns 0xFF for a category with no trait, and 0xFF x8 for any
    ///         token whose chunk has not been uploaded yet or is out of range.
    ///         Never reverts.
    function traitsOf(uint256 tokenId) external view returns (uint8[8] memory out) {
        for (uint256 i; i < 8; ++i) out[i] = 0xFF;
        if (tokenId == 0 || tokenId > MAX_TOKENS) return out;

        uint256 chunk = (tokenId - 1) / TOKENS_PER_CHUNK;
        if (chunk >= _tokenTraitChunks.length) return out;

        uint256 idx = (tokenId - 1) % TOKENS_PER_CHUNK;
        uint256 start = idx * BYTES_PER_TOKEN;
        bytes memory raw = SSTORE2.read(_tokenTraitChunks[chunk], start, start + BYTES_PER_TOKEN);
        for (uint256 i; i < 8; ++i) out[i] = uint8(raw[i]);
    }

    function _concat(address[] storage pointers) private view returns (bytes memory data) {
        uint256 n = pointers.length;
        if (n == 0) return "";
        if (n == 1) return SSTORE2.read(pointers[0]);
        for (uint256 i; i < n; ++i) {
            data = bytes.concat(data, SSTORE2.read(pointers[i]));
        }
    }
}
