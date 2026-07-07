/**
 * Lane → UI card (titles, bodies, links). Interpretation only — not settlement.
 */
import { Lane } from "../../cell/indexer/deriveConcernRouter.mjs";

const DISCLAIMER =
  "Suggestions only — the chain settles by reproduction, not this page.";

/** @param {string} lane */
function linksFor(lane, auditId) {
  const id = auditId ?? "";
  const ex = `explorer.html?id=${id}`;
  const manage = `manage.html?audit=${id}`;
  const map = {
    [Lane.AlreadyHandled]: [
      { label: "Back to audit record", href: ex },
      { label: "Walkthrough in section 3", href: "#appendNewcomer" },
      { label: "Verify in section 1", href: "#appendVerify" },
    ],
    [Lane.ReCheckFirst]: [
      { label: "Verify section below", href: "#appendVerify" },
      { label: "Manage (wallet)", href: manage },
    ],
    [Lane.PossibleMismatch]: [
      { label: "Manage — file a claim", href: manage },
      { label: "Bug-hunter guide", href: "bughunter.html" },
    ],
    [Lane.ClaimNotOpen]: [
      { label: "Back to audit record", href: ex },
      { label: "Verify section below", href: "#appendVerify" },
    ],
    [Lane.ChecksOut]: [
      { label: "Back to audit record", href: ex },
      { label: "How ideas become real", href: "ideas.html" },
    ],
    [Lane.Integrity]: [
      { label: "Bug-hunter — integrity path", href: "bughunter.html" },
      { label: "Manage (wallet)", href: manage },
    ],
    [Lane.SpecGap]: [
      { label: "Bug-hunter guide", href: "bughunter.html" },
      { label: "Spec-gap flow", href: "../../RealDeal/notebook/6-flows/book/06-spec-gap.md" },
    ],
    [Lane.ReadTheList]: [
      { label: "Back to audit record", href: ex },
      { label: "Verify section below", href: "#appendVerify" },
    ],
    [Lane.Structural]: [
      { label: "Structural upgrades", href: "docs-structural.html" },
      { label: "Phase G runbook", href: "phase-g-runbook.html" },
    ],
    [Lane.Lost]: [
      { label: "Bug-hunter quickstart", href: "bughunter.html" },
      { label: "Verify section below", href: "#appendVerify" },
    ],
  };
  return map[lane] ?? map[Lane.Lost];
}

const LANES = {
  [Lane.AlreadyHandled]: {
    title: "Already being handled — watch here",
    body: "The chain shows this audit is resolved, in dispute, or has an open overlay. Do not duplicate — follow progress in the explorer.",
  },
  [Lane.ReCheckFirst]: {
    title: "Re-check it yourself (no wallet)",
    body: "You have not re-run this audit's check yet. Recompute the result root on the pinned contract, then return if something still looks wrong.",
  },
  [Lane.PossibleMismatch]: {
    title: "You may have found a real problem",
    body: "You said your re-run gave a different answer than the chain recorded — so you may have caught something the audit got wrong. We haven't checked that here; only the network can, by re-running your result. If you're confident, the next step is to file a claim: connect a wallet, put down a refundable deposit, and submit your result on the Manage page (link below).",
  },
  [Lane.ClaimNotOpen]: {
    title: "Mismatch noted — claim path not open here",
    body: "You told us your re-run disagreed with the recorded result, but the chain will not accept a new vulnerability claim on this audit right now (wrong state, prior claim record, or not an ordinary audit row). Watch the explorer for state; re-verify before trying another path.",
  },
  [Lane.ChecksOut]: {
    title: "It checks out (by your report)",
    body: "You told us your re-run matched the recorded result and your worry is on the declared check list — we didn't verify either claim here. That does not prove the app is safe forever — only that this audit line may be internally consistent if your re-run was correct.",
  },
  [Lane.Integrity]: {
    title: "Looks right but feels gamed — integrity path",
    body: "You told us the check reproduced, but you suspect process abuse (wash / collusion). Integrity review is a separate staked overlay — not a bug claim on the declared check.",
  },
  [Lane.SpecGap]: {
    title: "Outside what was promised — report a spec gap",
    body: "You told us your re-run matched and your worry is outside what this audit declared it would check. Spec-gap is a separate overlay with its own stake and adoption economics.",
  },
  [Lane.ReadTheList]: {
    title: "Your re-run matched — now check the scope",
    body: "Good — your re-run matched the recorded result, so this audit is internally consistent. Whether that covers the thing you're worried about depends on what the audit actually promised to check (its declared scope). Compare your worry against that scope below; if no list is shown for this audit, open the verify guide to see how its checks were bound.",
  },
  [Lane.Structural]: {
    title: "The network tool itself may be wrong — advanced",
    body: "You believe the canonical network harness is wrong, not just this one audit. That is the structural upgrade railroad (gap → fix → jury) — not an ordinary claim.",
  },
  [Lane.Lost]: {
    title: "Not sure? Start here",
    body: "Your answers did not match a single escalated lane. Read the bug-hunter quickstart, verify an audit, then return.",
  },
};

/** Plain-language Step 0 card from router reason (not one generic blob). */
function alreadyHandledCopy(routeResult) {
  const reason = String(routeResult.reason ?? "");
  const stateName = routeResult.facts?.stateName ?? "Unknown";

  if (reason.includes("still in progress")) {
    return {
      title: "Still in review — come back when the window opens",
      body:
        `On-chain status for this audit: ${stateName}. An auditor is still working, or the challenge window has not opened yet. ` +
        "You can still re-run verify in section 1 below, but filing a claim or using the walkthrough in section 3 usually waits until the audit is in Passed — window open or Settled. Watch the explorer for updates.",
    };
  }
  if (reason.includes("vulnerability claim")) {
    return {
      title: "A bug claim is already open on this audit",
      body:
        "Someone has already filed a vulnerability claim here. Do not file a duplicate — follow the claim and any dispute re-audit on the audit record.",
    };
  }
  if (reason.includes("dispute re-audit")) {
    return {
      title: "A dispute re-audit is already in progress",
      body:
        "The protocol opened an independent re-check on the original contract. Wait for that result — do not start a parallel path on this page.",
    };
  }
  if (reason.includes("integrity review")) {
    return {
      title: "An integrity review is already open",
      body:
        "A separate integrity overlay is active on this audit. Follow it on the audit record — this walkthrough is not the right door.",
    };
  }
  if (reason.includes("spec challenge")) {
    return {
      title: "A spec challenge is already open",
      body:
        "Someone is challenging whether the declared spec was auditable (Gate A). Follow that overlay on the audit record — not an ordinary bug claim.",
    };
  }
  if (reason.includes("resolved or in dispute")) {
    return {
      title: `${stateName} — follow the settled record`,
      body:
        `This audit is already in a resolved or disputing state (${stateName}). ` +
        "The walkthrough below is for choosing a next step when nothing serious is already in flight. Open the audit record to see what happened.",
    };
  }
  return {
    title: LANES[Lane.AlreadyHandled].title,
    body: LANES[Lane.AlreadyHandled].body,
  };
}

/**
 * @param {object} audit — view-model row
 * @param {{ lane: string|null, ask: string|null, reason: string, facts: object }} routeResult
 */
export function presentConcernRoute(audit, routeResult) {
  const lane = routeResult.lane;
  const def = LANES[lane] ?? LANES[Lane.Lost];
  const handled =
    lane === Lane.AlreadyHandled ? alreadyHandledCopy(routeResult) : null;
  const title = handled ? handled.title : def.title;
  const body = handled ? handled.body : def.body;
  const gaps = routeResult.facts?.fmeaGaps ?? [];
  const fmeaContext =
    gaps.length > 0
      ? {
          count: gaps.length,
          note:
            "Optional heads-up: the tool this audit used has missed some kinds of bugs before (that history is recorded on-chain). It is just background — it does not change the answer above, and it does not mean anything is wrong with this audit.",
        }
      : null;
  const CLAIM_LANES = [Lane.PossibleMismatch, Lane.Integrity, Lane.SpecGap];
  const preflight = CLAIM_LANES.includes(lane)
    ? [
        {
          label: "Can you file a claim right now?",
          ok: !!audit.claimable,
          detail: audit.claimable ? "Yes — this audit is open for a new claim" : "No — not open (already claimed, or wrong state)",
        },
        {
          label: "Refundable deposit to file",
          ok: true,
          detail: audit.claimStakeEth ? `${audit.claimStakeEth} AUDIT — returned if your claim holds` : "—",
        },
      ]
    : [];
  return {
    lane,
    ask: routeResult.ask,
    title,
    body,
    preflight,
    links: linksFor(lane, audit.id),
    chainSnapshot: {
      auditId: audit.id,
      state: audit.state,
      stakeEth: audit.claimStakeEth,
    },
    fmea: { knownClassIds: gaps },
    fmeaContext,
    disclaimer: DISCLAIMER,
    reason: routeResult.reason,
    facts: routeResult.facts,
  };
}
