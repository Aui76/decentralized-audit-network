// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "genesis-tools/AuditResultV1.sol";

/// @dev Verdict tool — transferCredits must decrement sender credits (tutorial-trick check #2).
library TransferCreditsV1 {
    string internal constant TOOL_NAME = "transfer-credits";
    string internal constant TOOL_VERSION = "1.0.0";
    string internal constant ENTRYPOINT = "encodeResult(address,uint256,uint256)";
    bytes32 internal constant TOOL_ARTIFACT_HASH =
        0x390f7f7742a2419d6ddd8f9dc9afffacbdef7e41b861d6c295ec147e3a73fbed;

    bytes32 internal constant SPEC_DOMAIN = keccak256("AUDIT_SPEC_V1");
    bytes32 internal constant SPEC_ID = keccak256("tutorial.spec.transfer-credits.v1");
    uint256 internal constant SPEC_VERSION = 1;
    bytes32 internal constant INVARIANTS_DOMAIN = keccak256("AUDIT_INVARIANTS_V1");
    bytes32 internal constant INVARIANT_ID = keccak256("INVARIANT_TRANSFER_DECREMENTS_SENDER_V1");

    address public constant FIXTURE_FROM = address(uint160(0xB0));
    address public constant FIXTURE_ACTOR = address(uint160(0xC1));
    address public constant FIXTURE_TO = address(uint160(0xC1));
    uint256 internal constant FIXTURE_AMOUNT = 1 ether;

    bytes32 internal constant LOCATION_COMMITMENT =
        keccak256(abi.encode("transferCredits(address,address,uint256)", "credits[from]", "missing-sender-decrement"));

    function toolArtifactHash() public pure returns (bytes32) {
        return TOOL_ARTIFACT_HASH;
    }

    function toolId() public pure returns (bytes32) {
        return AuditResultV1.toolId(TOOL_NAME, TOOL_VERSION, TOOL_ARTIFACT_HASH, ENTRYPOINT);
    }

    function specHash() public pure returns (bytes32) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = INVARIANT_ID;
        bytes32 invariantsRoot = keccak256(abi.encode(INVARIANTS_DOMAIN, ids));
        return keccak256(abi.encode(SPEC_DOMAIN, SPEC_ID, SPEC_VERSION, invariantsRoot));
    }

    function toolConfigRoot() internal pure returns (bytes32) {
        return keccak256(abi.encode(FIXTURE_FROM, FIXTURE_ACTOR, FIXTURE_TO, FIXTURE_AMOUNT));
    }

    function contextRoot() public pure returns (bytes32) {
        return AuditResultV1.contextRoot("0.8.20", "cancun", 1, true, toolConfigRoot(), bytes32(0));
    }

    function encodeResult(address target, uint256 preFrom, uint256 postFrom)
        internal
        view
        returns (bool pass, bytes32 artifactHash, bytes32 findingsRoot_, bytes32 resultRoot_)
    {
        artifactHash = target.codehash;
        require(preFrom == FIXTURE_AMOUNT, "fixture: pre");
        pass = postFrom == 0;

        if (!pass) {
            bytes32 witness = keccak256(abi.encode(preFrom, postFrom));
            findingsRoot_ = AuditResultV1.findingsRoot(INVARIANT_ID, LOCATION_COMMITMENT, witness);
        }

        resultRoot_ = AuditResultV1.resultRoot(
            toolId(),
            artifactHash,
            specHash(),
            contextRoot(),
            pass ? AuditResultV1.VERDICT_PASS : AuditResultV1.VERDICT_FAIL,
            findingsRoot_
        );
    }
}
