// Minimal AuditCell ABI — only the read socket the explorer needs.
// Tuple field order matches the struct DEFINITION in AuditCell.sol (getter order), verified 2026-06-11.

export const auditCellAbi = [
  { type: "function", name: "nextAuditId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "blockHeight", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalSuccessfulAudits", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimVerifier", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "minAuditWindow", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimResolutionWindow", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimFilingStake", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "activeDisputeAuditId", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "auditProofHash", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "auditVerdictPass", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "latestBlockHash", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  {
    type: "function", name: "tools", stateMutability: "view", inputs: [{ type: "bytes32" }],
    outputs: [
      { name: "proposer", type: "address" },
      { name: "isSpecValidationTool", type: "bool" },
      { name: "isInvariantEvaluator", type: "bool" },
      { name: "canonical", type: "bool" },
      { name: "exists", type: "bool" },
      { name: "successfulUses", type: "uint256" },
      { name: "failedUses", type: "uint256" },
    ],
  },
  {
    type: "function", name: "audits", stateMutability: "view", inputs: [{ type: "uint256" }],
    outputs: [
      { name: "protocol", type: "address" },
      { name: "auditor", type: "address" },
      { name: "deployedAddress", type: "address" },
      { name: "bounty", type: "uint256" },
      { name: "windowStart", type: "uint256" },
      { name: "state", type: "uint8" },
      { name: "specHash", type: "bytes32" },
      { name: "artifactHash", type: "bytes32" },
      { name: "specToolId", type: "bytes32" },
      { name: "specPassDigest", type: "bytes32" },
      { name: "specAuditorAttested", type: "bool" },
      { name: "pickupTime", type: "uint256" },
      { name: "isVulnerabilityReport", type: "bool" },
      { name: "isClaimDispute", type: "bool" },
      { name: "linkedAuditId", type: "uint256" },
      { name: "stateBeforeClaim", type: "uint8" },
      { name: "lastDiscoverer", type: "address" },
      { name: "protocolApprovedAssignment", type: "bool" },
      { name: "caseRoot", type: "bytes32" },
      { name: "supersedesAuditId", type: "uint256" },
    ],
  },
  {
    type: "function", name: "vulnerabilityClaims", stateMutability: "view", inputs: [{ type: "uint256" }],
    outputs: [
      { name: "claimant", type: "address" },
      { name: "toolId", type: "bytes32" },
      { name: "proofHash", type: "bytes32" },
      { name: "claimTimestamp", type: "uint256" },
      { name: "stake", type: "uint256" },
      { name: "resolved", type: "bool" },
      { name: "exists", type: "bool" },
    ],
  },
  // events used for the timeline
  { type: "event", name: "AuditSubmitted", inputs: [
    { name: "id", type: "uint256", indexed: true }, { name: "protocol", type: "address", indexed: true },
    { name: "deployedAddress", type: "address", indexed: true }, { name: "bounty", type: "uint256" },
    { name: "artifactHash", type: "bytes32" }, { name: "specToolId", type: "bytes32" }, { name: "specPassDigest", type: "bytes32" } ] },
  { type: "event", name: "VerdictSubmitted", inputs: [
    { name: "id", type: "uint256", indexed: true }, { name: "pass", type: "bool" },
    { name: "toolId", type: "bytes32", indexed: true }, { name: "proofHash", type: "bytes32" } ] },
  { type: "event", name: "AuditConfirmed", inputs: [ { name: "id", type: "uint256", indexed: true } ] },
  { type: "event", name: "VulnerabilityClaimed", inputs: [
    { name: "id", type: "uint256", indexed: true }, { name: "claimant", type: "address", indexed: true },
    { name: "toolId", type: "bytes32", indexed: true }, { name: "proofHash", type: "bytes32" }, { name: "stake", type: "uint256" } ] },
  { type: "event", name: "DisputeReauditOpened", inputs: [
    { name: "originalAuditId", type: "uint256", indexed: true }, { name: "disputeAuditId", type: "uint256", indexed: true } ] },
  { type: "event", name: "OriginalAuditExploited", inputs: [
    { name: "originalAuditId", type: "uint256", indexed: true }, { name: "discoverer", type: "address", indexed: true },
    { name: "amountPaid", type: "uint256" }, { name: "fixSubmitter", type: "address" } ] },
  { type: "event", name: "ClaimExpired", inputs: [
    { name: "originalAuditId", type: "uint256", indexed: true }, { name: "claimant", type: "address", indexed: true }, { name: "amountPaid", type: "uint256" } ] },
  { type: "event", name: "ClaimVindicated", inputs: [
    { name: "originalAuditId", type: "uint256", indexed: true }, { name: "claimant", type: "address", indexed: true }, { name: "stakeSlashed", type: "uint256" } ] },
  { type: "event", name: "PositiveBlockMinted", inputs: [
    { name: "height", type: "uint256", indexed: true }, { name: "auditId", type: "uint256", indexed: true },
    { name: "reward", type: "uint256" }, { name: "blockHash", type: "bytes32" } ] },
  { type: "event", name: "ToolCanonized", inputs: [ { name: "toolId", type: "bytes32", indexed: true } ] },
  { type: "event", name: "ToolCanonizationRewarded", inputs: [
    { name: "toolId", type: "bytes32", indexed: true }, { name: "proposer", type: "address", indexed: true },
    { name: "reward", type: "uint256" }, { name: "blockHash", type: "bytes32" } ] },
];

export { STATE_ENUM as STATE } from "./status-labels.mjs";
