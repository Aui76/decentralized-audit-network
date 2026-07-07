// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/Eip712Reference.sol";

/// @dev O1 oracle: `indexer/eip712Digests.mjs` must match `Eip712Reference` (same math as cathedral `AuditNetwork` views).
contract Eip712DigestsOracleTest is Test {
    Eip712Reference internal ref;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CLAIM_TYPEHASH =
        keccak256("ClaimVulnerability(uint256 originalAuditId,bytes32 toolId,bytes32 resultRoot)");
    bytes32 internal constant VERDICT_TYPEHASH =
        keccak256("SubmitVerdict(uint256 auditId,bytes32 toolId,bool pass,bytes32 resultRoot)");

    function setUp() external {
        ref = new Eip712Reference();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Decentralized Audit Network")),
                keccak256(bytes("1")),
                block.chainid,
                address(ref)
            )
        );
    }

    function _typedDataHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function test_eip712_domain_separator() external view {
        assertEq(ref.eip712DomainSeparator(), _domainSeparator());
    }

    function test_eip712_claim_digest() external view {
        uint256 originalAuditId = 42;
        bytes32 toolId = keccak256("claim-tool");
        bytes32 resultRoot = keccak256("claim-root");

        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, originalAuditId, toolId, resultRoot));
        assertEq(ref.eip712ClaimDigest(originalAuditId, toolId, resultRoot), _typedDataHash(structHash));
    }

    function test_eip712_verdict_digest() external view {
        uint256 auditId = 7;
        bytes32 toolId = keccak256("verdict-tool");
        bytes32 resultRoot = keccak256("verdict-root");

        bytes32 structHash = keccak256(abi.encode(VERDICT_TYPEHASH, auditId, toolId, true, resultRoot));
        assertEq(ref.eip712VerdictDigest(auditId, toolId, true, resultRoot), _typedDataHash(structHash));
    }
}
