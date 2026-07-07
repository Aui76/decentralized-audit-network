/**
 * Maps membrane view-model audit rows → normalized chain facts for deriveConcernRouter.
 * Spec: body/proposals/concern-router-proposal.txt
 */
import { STATE_ENUM } from "./status-labels.mjs";
import { AuditState } from "../../cell/indexer/auditState.mjs";

const INTEGRITY_OPEN = new Set([1, 2]); // Open, VerdictSubmitted

/** @param {object} audit — view-model audit row from indexer.mjs */
export function auditRowToChainFacts(audit) {
  if (!audit) throw new Error("audit required");
  const stateIdx = typeof audit.state === "number"
    ? audit.state
    : STATE_ENUM.indexOf(audit.state);
  const scope = audit.scope ?? { status: "unavailable", covered: [], notChecked: [] };
  return {
    state: stateIdx >= 0 ? stateIdx : AuditState.None,
    claimOpen: !!(audit.claim && !audit.claim.resolved),
    disputeOpen: !!audit.hasOpenDispute,
    integrityOpen: INTEGRITY_OPEN.has(Number(audit.integrityReviewStatus ?? 0)),
    specChallengeOpen: !!audit.specChallengeActive,
    scope: {
      status: scope.status ?? "unavailable",
      covered: scope.covered ?? [],
      notChecked: scope.notChecked ?? [],
    },
    requiredStake: audit.claimStakeEth ?? null,
    bounty: audit.bounty ?? audit.bountyWei ?? null,
    claimFilingAllowed: !!audit.claimable,
    fmeaGaps: audit.fmea?.knownClassIds ?? [],
  };
}

/** Human-readable scope lines for Step 3. */
export function formatScopeList(scope) {
  if (!scope || scope.status === "unavailable") {
    return { html: "<p class=\"k\"><em>Declared scope not available for this audit — read the spec link below.</em></p>", items: [] };
  }
  const covered = scope.covered ?? [];
  if (scope.status === "declared-empty" || covered.length === 0) {
    return { html: "<p class=\"k\"><em>This audit declared an empty scope list.</em></p>", items: [] };
  }
  const items = covered.map((s) => (typeof s === "string" ? s : s.symbol ?? String(s)));
  const lis = items.map((s) => `<li><span class="mono">${escapeHtml(s)}</span></li>`).join("");
  return { html: `<ul class="k scope-list">${lis}</ul>`, items };
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export { escapeHtml };
