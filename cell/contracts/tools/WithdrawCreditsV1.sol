// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "genesis-tools/AuditResultV1.sol";

/// @dev Organ 1 heart — deterministic withdraw-credits checker per Life/specs/withdraw-credits-v1.md (LOCKED).
///      Tool identity v1.1.0: content-bound `toolArtifactHash` (L-02) — keccak256 of this library's runtime bytecode.
library WithdrawCreditsV1 {
    string internal constant TOOL_NAME = "withdraw-credits";
    string internal constant TOOL_VERSION = "1.1.0";
    string internal constant ENTRYPOINT = "encodeResult(address,uint256,uint256)";
    /// @dev L-02: keccak256(runtime bytecode) with this slot = bytes32(0) at build time (see ComputeToolArtifactHash.s.sol).
    bytes32 internal constant TOOL_ARTIFACT_HASH =
        0x630e81f397d999d092e086f66d93af2828eed69363e37dc1cca6395c5670c2c7;

    bytes32 internal constant SPEC_DOMAIN = keccak256("AUDIT_SPEC_V1");
    bytes32 internal constant SPEC_ID = keccak256("genesis.spec.withdraw-credits.v1");
    uint256 internal constant SPEC_VERSION = 1;
    bytes32 internal constant INVARIANTS_DOMAIN = keccak256("AUDIT_INVARIANTS_V1");
    bytes32 internal constant INVARIANT_ID = keccak256("INVARIANT_WITHDRAW_DECREMENTS_CREDITS_V1");

    address public constant FIXTURE_CALLER = address(uint160(0xB0));
    uint256 internal constant FIXTURE_AMOUNT = 1 ether;

    bytes32 internal constant LOCATION_COMMITMENT =
        keccak256(abi.encode("withdraw(uint256)", "credits[msg.sender]", "missing-post-decrement"));

    function specInvariantId() public pure returns (bytes32) {
        return INVARIANT_ID;
    }

    function specId() public pure returns (bytes32) {
        return SPEC_ID;
    }

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
        return keccak256(abi.encode(FIXTURE_CALLER, FIXTURE_AMOUNT, FIXTURE_AMOUNT));
    }

    function contextRoot() public pure returns (bytes32) {
        return AuditResultV1.contextRoot("0.8.20", "cancun", 1, true, toolConfigRoot(), bytes32(0));
    }

    /// @dev Pure encode from fixture readings. `pre` must equal FIXTURE_AMOUNT; `post` is credits after withdraw.
    function encodeResult(address target, uint256 pre, uint256 post)
        internal
        view
        returns (bool pass, bytes32 artifactHash, bytes32 findingsRoot_, bytes32 resultRoot_)
    {
        artifactHash = target.codehash;
        require(pre == FIXTURE_AMOUNT, "fixture: pre");
        pass = post == 0;

        if (!pass) {
            bytes32 witness = keccak256(abi.encode(pre, post));
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
