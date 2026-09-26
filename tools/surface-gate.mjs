#!/usr/bin/env node
/**
 * surface-gate.mjs — the safety guard: no function/event/error silently dropped across a rebuild.
 *
 * Implements surface-conservation-gate-proposal.txt:
 *   ABI(candidate) ⊇ ABI(baseline) − RemovalsAllowlist,  keyed on SELECTORS (functions + errors) and
 *   EVENT topic0s — across the ELEVEN NAMED CELL CONTRACTS in CONTRACTS below, which is NOT the union of
 *   the cell and its satellites (PC-45; corrected under VD-78 — the union wording was the proposal's
 *   intent, never this file's behaviour). A selector encodes name AND parameter types, so this catches
 *   wholesale removals AND silent signature changes a name-diff misses — but only within those eleven.
 *
 * Commands:
 *   node surface-gate.mjs snapshot [chainId]   → write the baseline surface from the current build
 *   node surface-gate.mjs check    [chainId]   → FAIL (exit 1) if any baseline selector is missing (un-allowlisted)
 *   node surface-gate.mjs check    [chainId] --selftest → inject a drop, prove the gate catches it (teeth)
 *
 * Reads compiled artifacts from cell/out/ (run `forge build` in cell/ first). No cell change; off-chain gate.
 */
import { Interface } from "../../cell/node_modules/ethers/lib.esm/ethers.js";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const CELL = join(here, "..", "..", "cell");
const OUT = join(CELL, "out");

// The integrator/settlement-visible surface AS THIS FILE MEASURES IT = these eleven contracts' external ABIs.
// ⚠ READ THIS BEFORE DERIVING THE SET (PC-45, ruled by VD-78). candidateSurface() iterates ONLY this array,
// so the gate is wrong in BOTH directions, and the second one stops work:
//   (a) false green - a selector that LEAVES a satellite is invisible here and the board still prints CONSERVED;
//   (b) false red   - a selector legitimately MOVED INTO a satellite (FC-17 moves withdrawForLP into
//       cell/contracts/satellites/AuditEthMembrane.sol) leaves the candidate set, lands in `missing`, and
//       exits 1 with SURFACE DROP on correct work - stopping every launch and every preview.
// Until VD-78's correction this comment read "A function that MOVED to a satellite is still in the union
// (not a drop)" - the exact reverse of what the code does. The fix is to DERIVE the contract set, and its
// acceptance needs BOTH directions proven: a red fixture AND a green one. The green direction is the
// scheduled operation, so a derived set proven only red is unproven on the thing it will actually do.
const CONTRACTS = [
  "AuditCell", "CellToken", "CellEscrow", "IssuanceModule", "ClaimDisputeModule",
  "SpecGapModule", "SpecArbiterModule", "IntegrityReviewModule", "StructuralUpgradeModule",
  "FmeaRegistry", "AssignmentModule",
];

const baselinePath = (chainId) => join(CELL, `deployed-surface-${chainId}.json`);
const removalsPath = join(CELL, "surface-removals.txt");

function artifactAbi(name) {
  const p = join(OUT, `${name}.sol`, `${name}.json`);
  if (!existsSync(p)) throw new Error(`artifact not found: ${p}\n  → run \`forge build\` in cell/ first.`);
  return JSON.parse(readFileSync(p, "utf8")).abi;
}

/** selector/topic0 -> { kind, sig, from: [contract,...] } across the whole union. */
function candidateSurface() {
  const surface = new Map();
  for (const name of CONTRACTS) {
    const iface = new Interface(artifactAbi(name));
    for (const f of iface.fragments) {
      let key, kind;
      if (f.type === "function") { key = f.selector; kind = "function"; }
      else if (f.type === "event") { key = f.topicHash; kind = "event"; }
      else if (f.type === "error") { key = f.selector; kind = "error"; }
      else continue; // constructor / fallback / receive
      const sig = f.format("sighash");
      if (!surface.has(key)) surface.set(key, { kind, sig, from: [name] });
      else if (!surface.get(key).from.includes(name)) surface.get(key).from.push(name);
    }
  }
  return surface;
}

function loadRemovals() {
  const allow = new Map();
  if (!existsSync(removalsPath)) return allow;
  for (const line of readFileSync(removalsPath, "utf8").split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const m = t.match(/^(0x[0-9a-fA-F]{8,64})\s+(.+)$/); // selector/topic + reason (reason required = teeth)
    if (m) allow.set(m[1].toLowerCase(), m[2].trim());
  }
  return allow;
}

function surfaceToJson(surface, chainId) {
  const selectors = {};
  for (const [k, v] of [...surface.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    selectors[k] = { kind: v.kind, sig: v.sig, from: v.from };
  }
  return { chainId: Number(chainId), generatedAt: new Date().toISOString(), contracts: CONTRACTS, count: surface.size, selectors };
}

function snapshot(chainId) {
  const surface = candidateSurface();
  writeFileSync(baselinePath(chainId), JSON.stringify(surfaceToJson(surface, chainId), null, 2) + "\n");
  console.log(`snapshot written: ${baselinePath(chainId)}  (${surface.size} selectors across ${CONTRACTS.length} contracts)`);
}

function check(chainId, selftest) {
  const bp = baselinePath(chainId);
  if (!existsSync(bp)) throw new Error(`no baseline at ${bp} — run \`snapshot ${chainId}\` first (or commit the deployed surface).`);
  const baseline = JSON.parse(readFileSync(bp, "utf8")).selectors;
  const candidate = candidateSurface();
  const allow = loadRemovals();

  let injected = null;
  if (selftest) {
    // Teeth check: pretend a real function was dropped from the candidate and confirm the gate flags it.
    const victim = Object.entries(baseline).find(([k, v]) => v.kind === "function" && !allow.has(k.toLowerCase()));
    if (!victim) throw new Error("selftest: no eligible function in baseline to drop");
    injected = victim;
    candidate.delete(victim[0]);
  }

  const missing = [];
  for (const [key, meta] of Object.entries(baseline)) {
    if (!candidate.has(key) && !allow.has(key.toLowerCase())) missing.push([key, meta]);
  }
  const added = [...candidate.keys()].filter((k) => !(k in baseline));

  if (selftest) {
    const caught = missing.some(([k]) => k === injected[0]);
    console.log(caught
      ? `SELFTEST PASS — gate caught the injected drop: ${injected[1].sig} [${injected[0]}]`
      : `SELFTEST FAIL — gate did NOT catch a dropped function (teeth broken)`);
    process.exit(caught ? 0 : 1);
  }

  console.log(`surface check vs ${bp}`);
  console.log(`  baseline: ${Object.keys(baseline).length} · candidate: ${candidate.size} · allowlisted removals: ${allow.size}`);
  if (added.length) console.log(`  (+${added.length} new selectors added — informational, not a problem)`);

  if (missing.length === 0) {
    console.log(`\n✅ SURFACE CONSERVED — nothing from the baseline is missing (un-allowlisted). Safe to redeploy on this axis.`);
    process.exit(0);
  }
  console.log(`\n❌ SURFACE DROP — ${missing.length} selector(s) present in the baseline are GONE and not allowlisted:`);
  for (const [key, meta] of missing) console.log(`   - [${meta.kind}] ${meta.sig}   ${key}   (was in: ${(meta.from || []).join(", ")})`);
  console.log(`\nEither restore them, or add each to cell/surface-removals.txt with a signed reason (a reshape names its replacement).`);
  console.log(`\n⚠ FIRST: did the selector MOVE to a satellite rather than leave the codebase? Then this is NOT a removal -`);
  console.log(`  it is this gate's known blindness (PC-45): candidateSurface() reads only the ${CONTRACTS.length} names hardcoded above,`);
  console.log(`  so a function moved into cell/contracts/satellites/ reads as GONE. Do NOT write a removal reason:`);
  console.log(`  cell/surface-removals.txt is the one file where a removal carries a signed justification, and a`);
  console.log(`  moved-not-removed entry poisons that record. Fix the contract set instead.`);
  process.exit(1);
}

const [cmd, arg2, arg3] = process.argv.slice(2);
const chainId = (arg2 && !arg2.startsWith("--")) ? arg2 : "31337";
const selftest = process.argv.includes("--selftest");
try {
  if (cmd === "snapshot") snapshot(chainId);
  else if (cmd === "check") check(chainId, selftest);
  else { console.error("usage: surface-gate.mjs <snapshot|check> [chainId] [--selftest]"); process.exit(2); }
} catch (e) {
  console.error(`surface-gate error: ${e.message}`);
  process.exit(2);
}
