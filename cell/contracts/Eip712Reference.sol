// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev O1 reference — cathedral `AuditNetwork` EIP-712 view helpers (F-04), extracted for puzzle oracle tests.
contract Eip712Reference {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant EIP712_CLAIM_TYPEHASH =
        keccak256("ClaimVulnerability(uint256 originalAuditId,bytes32 toolId,bytes32 resultRoot)");
    bytes32 internal constant EIP712_VERDICT_TYPEHASH =
        keccak256("SubmitVerdict(uint256 auditId,bytes32 toolId,bool pass,bytes32 resultRoot)");

    function eip712DomainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Decentralized Audit Network")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function eip712ClaimDigest(uint256 originalAuditId, bytes32 toolId, bytes32 resultRoot)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(EIP712_CLAIM_TYPEHASH, originalAuditId, toolId, resultRoot));
        return keccak256(abi.encodePacked("\x19\x01", eip712DomainSeparator(), structHash));
    }

    function eip712VerdictDigest(uint256 auditId, bytes32 toolId, bool pass, bytes32 resultRoot)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(EIP712_VERDICT_TYPEHASH, auditId, toolId, pass, resultRoot));
        return keccak256(abi.encodePacked("\x19\x01", eip712DomainSeparator(), structHash));
    }
}
