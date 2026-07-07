/**
 * Run: node test/concernStep0Refresh.test.mjs
 */
import assert from "node:assert/strict";
import {
  fnSelector,
  readU8,
  readBool,
  readU256,
  decodeAuditsReturn,
  decodeClaimReturn,
  mergeLiveStep0ChainFacts,
  patchAuditRowFromStep0,
} from "../concernStep0Refresh.mjs";
import { AuditState } from "../../../cell/indexer/auditState.mjs";

assert.match(fnSelector("audits(uint256)"), /^0x[0-9a-f]{8}$/);
assert.equal(fnSelector("audits(uint256)"), fnSelector("audits(uint256)"));
assert.equal(fnSelector("auditProofHash(uint256)"), "0x04bf5be8");

const auditHex =
  "0x" +
  "0".repeat(64 * 5) +
  "06".padStart(64, "0") + // state InBlock = 6
  "0".repeat(64 * 6) +
  "0".repeat(63) +
  "0" + // isVulnerabilityReport false
  "0".repeat(63) +
  "0" + // isClaimDispute false
  "0".repeat(64 * 6);

const audit = decodeAuditsReturn(auditHex);
assert.equal(audit.state, AuditState.InBlock);
assert.equal(audit.isClaimDispute, false);

const claimHex =
  "0x" +
  "0".repeat(64 * 5) +
  "0".repeat(63) +
  "1" + // resolved true
  "0".repeat(63) +
  "1"; // exists true
assert.equal(decodeClaimReturn(claimHex).exists, true);
assert.equal(decodeClaimReturn(claimHex).resolved, true);

const merged = mergeLiveStep0ChainFacts(
  { state: AuditState.AwaitingWindow, claimOpen: false, claimFilingAllowed: true, scope: { status: "unavailable" } },
  { state: AuditState.Claimed, claimOpen: true, disputeOpen: false, integrityOpen: false, specChallengeOpen: false, claimFilingAllowed: false, refreshedAt: "t", source: "rpc" },
);
assert.equal(merged.state, AuditState.Claimed);
assert.equal(merged.claimOpen, true);
assert.equal(merged.claimFilingAllowed, false);
assert.equal(merged.step0Source, "rpc");

const row = patchAuditRowFromStep0(
  { id: 7, state: "InBlock", claimable: true, claim: null },
  { state: AuditState.Claimed, claimOpen: true, claimExists: true, disputeOpen: true, integrityOpen: true, specChallengeOpen: false, claimFilingAllowed: false, refreshedAt: "t" },
);
assert.equal(row.state, "Claimed");
assert.equal(row.claimable, false);
assert.equal(row.hasOpenDispute, true);

console.log("concernStep0Refresh.test.mjs: all assertions passed");
