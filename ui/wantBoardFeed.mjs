/**
 * Want-board contract facts feed (L-25) — view-model + FMEA/contagion -> deriveWantBoard input.
 * Spec: body/proposals/want-board-proposal.txt
 *
 * PURE. Reads indexed audit rows (stakes, exposure, audit status, risk-resemblance) and
 * optional user-added contracts. Same model -> same feed. Interpretation only.
 *
 * Usage: node test/wantBoardFeed.test.mjs
 */

import { derivePortfolioContagion } from "../../cell/indexer/deriveContagion.mjs";

const ACTIVE = new Set(["Submitted", "Assigned", "InAudit", "AwaitingWindow", "Audited"]);
const SETTLED = new Set(["InBlock", "Exploited", "Claimed", "Invalidated"]);
const ADDR_ZERO = "0x0000000000000000000000000000000000000000";

function normAddr(a) {
  const s = String(a || "").trim();
  if (!s || s.toLowerCase() === ADDR_ZERO) return "";
  return s.toLowerCase();
}

function auditStatusForRows(rows) {
  if (!rows.length) return "unaudited";
  let live = false;
  let settled = false;
  for (const a of rows) {
    if (ACTIVE.has(a.state)) live = true;
    if (SETTLED.has(a.state)) settled = true;
  }
  if (live) return "live";
  if (settled) return "passed";
  return "unaudited";
}

function nameForTarget(rows) {
  const a = rows[0];
  const short = a.target ? a.target.slice(0, 6) + "..." + a.target.slice(-4) : "?";
  return "Target " + short + " (audit #" + a.id + ")";
}

function buildToolKnownGaps(audits) {
  const out = {};
  for (const a of audits) {
    const tool = normAddr(a.specToolId);
    const ids = a.fmea?.knownClassIds ?? [];
    if (!tool || !ids.length) continue;
    out[tool] = ids.map(String);
  }
  return out;
}

function buildExploits(audits) {
  const out = [];
  for (const a of audits) {
    if (a.state !== "Exploited") continue;
    const cid = a.fmea?.knownClassIds?.[0] ?? null;
    out.push({ auditId: a.id, vulnerabilityClassId: cid, specToolId: a.specToolId });
  }
  return out;
}

function riskForTarget(rows, contagion) {
  for (const a of rows) {
    const row = contagion?.perAudit?.[String(a.id)];
    if (row && (row.reauditAdvisory || row.exposureScore > 0)) return 1;
  }
  return 0;
}

function holderCount(rows) {
  const set = new Set();
  for (const a of rows) {
    if (a.protocol) set.add(normAddr(a.protocol));
    if (a.auditor) set.add(normAddr(a.auditor));
    if (a.claim?.claimant) set.add(normAddr(a.claim.claimant));
  }
  return set.size;
}

function maxStakeUsd(rows) {
  let max = 0;
  for (const a of rows) {
    const n = Number(a.bounty);
    if (Number.isFinite(n) && n > max) max = n;
  }
  return max;
}

/**
 * @param {object} model — view-model { meta, audits }
 * @param {object[]} [extras] — user-added { contract, name?, addedAt? }
 */
export function buildWantFeed(model, extras = []) {
  const audits = model?.audits ?? [];
  const byTarget = new Map();

  for (const a of audits) {
    const key = normAddr(a.target);
    if (!key) continue;
    if (!byTarget.has(key)) byTarget.set(key, []);
    byTarget.get(key).push(a);
  }

  const toolKnownGaps = buildToolKnownGaps(audits);
  const contagion = derivePortfolioContagion({
    audits: audits.map((a) => ({ id: a.id, state: a.state, specToolId: a.specToolId })),
    exploits: buildExploits(audits),
    toolKnownGaps,
  });

  const contracts = [];
  let addedAt = 0;
  for (const [key, rows] of byTarget) {
    rows.sort((a, b) => a.id - b.id);
    contracts.push({
      contract: rows[0].target,
      name: nameForTarget(rows),
      stakesUsd: maxStakeUsd(rows),
      holders: holderCount(rows),
      auditStatus: auditStatusForRows(rows),
      riskResemblance: riskForTarget(rows, contagion),
      addedAt: addedAt++,
    });
  }

  for (const e of extras) {
    const key = normAddr(e.contract);
    if (!key || byTarget.has(key)) continue;
    contracts.push({
      contract: e.contract,
      name: e.name || "New contract (facts pending)",
      stakesUsd: Number(e.stakesUsd) || 0,
      holders: Number(e.holders) || 0,
      auditStatus: e.auditStatus === "live" || e.auditStatus === "passed" ? e.auditStatus : "unaudited",
      riskResemblance: e.riskResemblance ? 1 : 0,
      addedAt: Number(e.addedAt) || addedAt++,
    });
  }

  return contracts;
}

export default buildWantFeed;
