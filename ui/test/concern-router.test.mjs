/**
 * Integration tests — membrane adapter + cell/indexer deriveConcernRouter.
 * Run: node test/concern-router.test.mjs
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { deriveConcernRouter, Lane, Question } from "../../../cell/indexer/deriveConcernRouter.mjs";
import { auditRowToChainFacts } from "../concernAdapter.mjs";
import { presentConcernRoute } from "../concernPresentation.mjs";
import { AuditState } from "../../../cell/indexer/auditState.mjs";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const bundleSrc = readFileSync(`${membraneRoot}/concern-router.js`, "utf8");
assert.doesNotThrow(() => new Function(bundleSrc), "concern-router.js must parse in browser");
const sandbox = { window: {} };
vm.runInNewContext(bundleSrc, sandbox);
assert.equal(typeof sandbox.window.deriveConcernRouter, "function");
assert.equal(typeof sandbox.window.auditRowToChainFacts, "function");
assert.equal(typeof sandbox.window.fetchStep0ChainFacts, "function");

const INTEGRITY_NONE = 0;

function audit(over = {}) {
  return {
    id: 7,
    kind: "audit",
    state: "InBlock",
    claimable: true,
    claimStakeEth: "100.0",
    claim: null,
    hasOpenDispute: false,
    integrityReviewStatus: INTEGRITY_NONE,
    specChallengeActive: false,
    scope: { status: "has-categories", covered: ["WITHDRAW-LIMIT"], notChecked: ["REENTRANCY"] },
    fmea: { knownClassIds: [] },
    ...over,
  };
}

function routeRow(row, answers = {}) {
  const chain = auditRowToChainFacts(row);
  return presentConcernRoute(row, deriveConcernRouter({ chain, answers }));
}

assert.equal(routeRow(audit(), {}).ask, Question.Verify);
assert.equal(routeRow(audit(), { verify: "not-run" }).lane, Lane.ReCheckFirst);
assert.equal(routeRow(audit(), { verify: "different" }).lane, Lane.PossibleMismatch);
assert.equal(routeRow(audit({ claimable: false }), { verify: "different" }).lane, Lane.ClaimNotOpen);
assert.equal(routeRow(audit(), { verify: "same", worry: "on-list" }).lane, Lane.ChecksOut);
assert.equal(routeRow(audit(), { verify: "same", worry: "on-list", suspectsFaked: true }).lane, Lane.Integrity);
assert.equal(routeRow(audit(), { verify: "same", worry: "off-list" }).lane, Lane.SpecGap);
assert.equal(routeRow(audit({ state: "Exploited", claimable: false }), {}).lane, Lane.AlreadyHandled);
assert.equal(routeRow(audit(), { concern: "tool" }).lane, Lane.Structural);

const chainFromString = auditRowToChainFacts(audit());
assert.equal(chainFromString.state, AuditState.InBlock);

const r1 = routeRow(audit(), { verify: "not-run" });
const r2 = routeRow(audit(), { verify: "not-run" });
assert.equal(r1.lane, r2.lane);
assert.ok(r1.disclaimer.includes("Suggestions only"));
const checkout = routeRow(audit(), { verify: "same", worry: "on-list" });
assert.ok(checkout.body.includes("You told us"));
assert.ok(!checkout.body.includes("FMEA memory"));
assert.equal(checkout.fmeaContext, null);

const withFmea = routeRow(audit({ fmea: { knownClassIds: ["0xabc"] } }), { verify: "same", worry: "on-list" });
assert.ok(withFmea.fmeaContext && withFmea.fmeaContext.count === 1);
assert.ok(!withFmea.body.includes("FMEA memory"));

console.log("concern-router.test.mjs: all assertions passed");
