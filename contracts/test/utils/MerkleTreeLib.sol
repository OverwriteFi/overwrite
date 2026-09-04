// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Builds Merkle roots and proofs in Solidity, because there is no JavaScript test harness in this repo.
/// Uses OpenZeppelin `MerkleProof`'s sorted-pair convention, so a proof produced here verifies against
/// `MerkleProof.verifyCalldata` unchanged. An odd node at any level is promoted to the next level untouched.
library MerkleTreeLib {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[][] memory levels = _levels(leaves);
        return levels[levels.length - 1][0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
        bytes32[][] memory levels = _levels(leaves);
        uint256 depth = levels.length;

        uint256 count;
        uint256 idx = index;
        for (uint256 d; d + 1 < depth; ++d) {
            if ((idx ^ 1) < levels[d].length) count++;
            idx /= 2;
        }

        p = new bytes32[](count);
        idx = index;
        uint256 k;
        for (uint256 d; d + 1 < depth; ++d) {
            uint256 sib = idx ^ 1;
            if (sib < levels[d].length) p[k++] = levels[d][sib];
            idx /= 2;
        }
    }

    function _levels(bytes32[] memory leaves) private pure returns (bytes32[][] memory levels) {
        uint256 n = leaves.length;
        require(n > 0, "MerkleTreeLib: empty");
        uint256 depth = 1;
        for (uint256 m = n; m > 1; m = (m + 1) / 2) {
            depth++;
        }
        levels = new bytes32[][](depth);
        levels[0] = leaves;
        for (uint256 d = 1; d < depth; ++d) {
            bytes32[] memory prev = levels[d - 1];
            uint256 len = (prev.length + 1) / 2;
            bytes32[] memory cur = new bytes32[](len);
            for (uint256 i; i < len; ++i) {
                cur[i] = (2 * i + 1 < prev.length) ? hashPair(prev[2 * i], prev[2 * i + 1]) : prev[2 * i];
            }
            levels[d] = cur;
        }
    }
}
