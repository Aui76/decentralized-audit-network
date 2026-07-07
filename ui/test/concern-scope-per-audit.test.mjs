/**
 * Per-audit scope honesty — different specHash pins must not share a borrowed golden list.
 * Run: node test/concern-scope-per-audit.test.mjs
 */
import assert from "node:assert/strict";
import { scopeFieldsFromSpecHash, WITHDRAW_CREDITS_SPEC_HASH } from "../../../cell/indexer/resolveAuditScope.mjs";
import { referenceSpecHash } from "../../../cell/indexer/specReferenceFixture.mjs";
import { auditRowToChainFacts } from "../concernAdapter.mjs";
import { deriveConcernRouter, Lane } from "../../../cell/indexer/deriveConcernRouter.mjs";

const refHash = referenceSpecHash();
const wcHash = WITHDRAW_CREDITS_SPEC_HASH;
const unknownHash = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

const refScope = scopeFieldsFromSpecHash(refHash);
const wcScope = scopeFieldsFromSpecHash(wcHash);
const unkScope = scopeFieldsFromSpecHash(unknownHash);

assert.equal(refScope.status, "has-categories");
assert.ok(refScope.covered.includes("REENTRANCY"));
assert.equal(wcScope.status, "declared-empty");
assert.equal(wcScope.covered.length, 0);
assert.equal(unkScope.status, "unavailable");
assert.notDeepEqual(refScope.covered, wcScope.covered);

function row(id, specHash, scope) {
  return {
    id,
    kind: "audit",
    state: "InBlock",
    claimable: true,
    claimStakeEth: "1.0",
    claim: null,
    hasOpenDispute: false,
    integrityReviewStatus: 0,
    specChallengeActive: false,
    specHash,
    scope,
    fmea: { knownClassIds: [] },
  };
}

const refAudit = row(1, refHash, refScope);
const wcAudit = row(2, wcHash, wcScope);

const refChain = auditRowToChainFacts(refAudit);
const wcChain = auditRowToChainFacts(wcAudit);

assert.notDeepEqual(refChain.scope.covered, wcChain.scope.covered);
assert.equal(refChain.scope.status, "has-categories");
assert.equal(wcChain.scope.status, "declared-empty");

const refSame = deriveConcernRouter({ chain: refChain, answers: { verify: "same" } });
const wcSame = deriveConcernRouter({ chain: wcChain, answers: { verify: "same" } });

assert.equal(refSame.ask, "scope");
assert.equal(wcSame.lane, Lane.ReadTheList);

console.log("concern-scope-per-audit.test.mjs: all assertions passed");
