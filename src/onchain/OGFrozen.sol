// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title OGFrozen - the FROZEN-FOREVER OG cohort of Cubist Souls, embedded on-chain
/// @notice The OG cohort is EXACTLY the 863 souls minted up to the ConvertV2 cut
///         (Ethereum block 25565191). It is a fixed, historical fact, so it is
///         embedded here as a sorted big-endian uint16 blob (863 x 2 = 1726 bytes)
///         and answered by an on-chain binary search — deciding "is this an OG"
///         NEVER touches the network and can NEVER be wrong.
///
///         This is the on-chain twin of cubistsouls-web/app/api/meta/og_frozen.json.
///         The two are generated from the same source and MUST stay identical
///         (the parity harness diffs them). Membership here is authoritative for
///         the renderer's Cohort attribute: an id in this list is "OG"; any other
///         id's era (I..IV) is read live from the diamond's cohortOf.
///
///         A library with an `internal` view is inlined into the renderer's
///         bytecode at compile time, so there is NO extra deployment and no
///         external call — the blob ships inside SoulRendererV4.
library OGFrozen {
    /// Sorted ascending, big-endian uint16, 863 entries. DO NOT EDIT BY HAND.
    /// Regenerate from og_frozen.json (see runbook / script).
    bytes internal constant IDS =
        hex"0063006a0088009e00a300a600a800c300e500ec00f70104010b01170133013a013b014101620169017501760186018d019c01a001a101bb01bc01bf01c001c701cd01ce01d601df01e401e701e801ea01ee01ef01f601fa020302050206020a0216022802320239023a0243025102520254025c025d025e026e0271027f028f0290029702a602a902ab02c702ce02cf02d102e102fa02fb030d03570358035e035f03600370037a038903d903ea03ec03f103f203fe03ff040304280429042b043404350438044f045f046204660468047204760477047b047e048d048e049804a104a204ca04ce04d004d104e304f104fc050005010518051a052b052c052e0543054705480549055805660569056a057c05870588058a058d058e058f0590059205a205ab05ac05b905bd05cc05ce05db05dc05de0601061506320634063e063f064306470649064b064e064f065e06630664066b066d0671067206750676067e06920695069d069e06b706bf06c606c706da06e006e206e506f206f607060708070d070e071d0722072307270729072d074207450746074b074c0751075207610762076a076d0770077107720789078a078b078e079d079e079f07a707ab07c107c207c907ca07d207dc07f007f8080108020817081d082c083a08560857085a085b085c0860086c08720873087c08810882088308840885088c088d0899089a089b089f08a608a808ab08ac08c308d408d508e008f7091a091b093a093b095709580959095a09740978097b0981098b0992099e09a709a909aa09ab09cb09cc09db09de09df09e809e909f909fd0a0f0a130a250a3d0a450a490a5a0a780a8d0a960aa40aa50aac0ab10ac10ace0ae30ae40af50b1b0b240b260b270b280b290b2e0b2f0b4b0b4c0b600b720b730b750b770b790b810b820b840b850b8c0b8d0be30be40be90bec0bfb0bfe0bff0c070c080c0f0c100c110c130c1b0c1c0c610c620c680c6f0c750c7d0c7e0c800c810c820c850c860c8d0c950c960c980c990c9c0caa0cbe0ccb0cd90cdd0cf30d090d1e0d1f0d210d240d280d290d3b0d560d570d610d680d750d7a0d950da20db30dd80ddc0de40ded0e030e130e370e3a0e460e470e4e0e5d0e670e770e7a0e800e810e830e840e870e880ea00ea10eb70ebf0ec30edb0ee30eea0eed0eee0ef90f070f090f310f320f5f0f640f980f9b0fa30fa90fac0fc20fd60fed0ffd0ffe100a100d101010121022103d104d1077107e108d108e1096109b10ad10cd10ce10d010d110d810f111011106110e111e1123112c112e115f116a11751176119c11ae11d211d611f111f311f61200120e1210124f126d126e127d129b12b912c112c512cc12cd12ce12ed12f2131f132813291333134e13741378137b137c13a513a613b013fc1417142714341438143f144714481449144f1451146f14701476147714a114cf14d014d514f61500152115221523152c15431558157015ba15be15db15f916021619161f164f165f16601688168f1697169a169b16a716be16c216c316ec16f516fa171a171b172817291758177f179117921793179417a917b017e517e617e717e817f917fb17fd18061809180a1823183b1851187c188a18e218e319061915191c19241931193219341937195f196e1981198919911997199f19a019ac19b319ba19bb19be19bf19c019c119dc19dd19de19e31a021a0c1a0d1a141a151a1e1a1f1a291a341a411a541a6c1a6f1a8d1a941a981a9a1a9b1a9c1aa01ab21ab91ad31ade1adf1ae31ae61af21afb1b0d1b2d1b3b1b411b421b541b591b891b8e1bbe1bc81bd21bd51bd71be51bee1bf71c021c061c081c161c1d1c381c391c5a1c611c641c661c671c691c6a1c6c1c6f1c751c7b1c821c931c941c971c9b1c9c1c9f1ca31ca61ca71cad1cb31cb41cb51cb71cb91cbd1cc01cc71ccf1cd01cd21cd61cd71cda1cdb1cde1cf11cf71d121d211d321d4a1d551d611d631d671d801d931da71dad1dd31dd41dd51ddf1de01dea1df31df41e011e101e251e2d1e731e7f1e831e8b1eab1ebf1ed01edc1ef81f0d1f391f601f8c1f8f1fb31fcc1fde1fdf1fe21fe420012008200a206a206b207220822084209b20a020a820f020f820fb20ff210a210e210f211d212e2130213e214021612162216321672168216b217021712175217621792184219621a221b121cb21d821e521f3220e220f221a223122322239223a224522472249229322a322af22b822ed22fc233d234c235a23672385238723952396239d23b023b923f82411243524442454248824a324a524fe25102511251425302535254c25652581258225b325b625bc25e625f225fc2609260f263e26402648264f265e26652668267a267c267d26842689268b26d626df26e026f8";

    uint256 internal constant COUNT = 863;

    /// @notice True iff `id` is one of the 863 frozen OG souls. Binary search over
    ///         the embedded sorted blob (~10 comparisons). Never reverts.
    function isOG(uint256 id) internal pure returns (bool) {
        if (id == 0 || id > 65535) return false;
        uint256 lo = 0;
        uint256 hi = COUNT; // exclusive
        bytes memory ids = IDS;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 off = mid << 1;
            uint256 v;
            assembly {
                // ids data starts at ids+0x20; read the 2 big-endian bytes at off
                let word := mload(add(add(ids, 0x20), off))
                v := shr(240, word) // top 16 bits
            }
            if (v == id) return true;
            if (v < id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return false;
    }
}
