// Membrane indexer — reads the live AuditCell on Base Sepolia (84532) and emits the
// canonical view-model (RealDeal/notebook/meta/docs-read-model.md). Read-only: no wallet, no writes.
//
//   RPC_URL=https://sepolia.base.org node indexer.mjs
//   (defaults: ../deployments/84532-cell.json live, else predecessor harness for archived explorer)
//
// Writes view-model.json (canonical) and view-model.js (window.__MODEL, for file:// open).

import { createPublicClient, http, formatEther } from "viem";
import { baseSepolia } from "viem/chains";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { auditCellAbi, STATE } from "./abi.mjs";
import { outcomeOf as statusOutcome } from "./status-labels.mjs";
import { scopeFieldsFromSpecHash } from "../../cell/indexer/resolveAuditScope.mjs";

const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";

function loadDeployment() {
  const paths = [
    process.env.DEPLOYMENT_JSON,
    "../deployments/84532-cell.json",
    "../predecessor/deployments/84532-harness.json",
  ].filter(Boolean);
  for (const rel of paths) {
    const p = new URL(rel, import.meta.url);
    if (!existsSync(p)) continue;
    try { return JSON.parse(readFileSync(p)); } catch {}
  }
  return null;
}

function resolveCell() {
  if (process.env.AUDIT_CELL) return process.env.AUDIT_CELL;
  const d = loadDeployment();
  if (d?.AuditCell) return d.AuditCell;
  throw new Error("Set AUDIT_CELL or provide ../deployments/84532-cell.json (Phase B) or predecessor harness JSON");
}

function resolveFromBlock(d) {
  if (process.env.FROM_BLOCK) return BigInt(process.env.FROM_BLOCK);
  if (d?.deployBlock != null) return BigInt(d.deployBlock);
  return 0n;
}

const deployment = loadDeployment();
const address = resolveCell();
const FROM_BLOCK = resolveFromBlock(deployment);
const client = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) });
const read = (functionName, args = []) => client.readContract({ address, abi: auditCellAbi, functionName, args });
const short = (h) => (!h ? "—" : h.length > 14 ? `${h.slice(0, 8)}…${h.slice(-4)}` : h);
const ZERO = "0x0000000000000000000000000000000000000000000000000000000000000000";
const wei = (v) => formatEther(v ?? 0n);

/** viem returns multi-output getters as array-like tuples even when outputs are named. */
function pick(tuple, name, i) {
  const v = tuple?.[name] ?? tuple?.[i];
  if (v === undefined) throw new Error(`tuple field ${name}/${i} missing`);
  return v;
}

function parseAudit(r) {
  return {
    protocol: pick(r, "protocol", 0),
    auditor: pick(r, "auditor", 1),
    deployedAddress: pick(r, "deployedAddress", 2),
    bounty: pick(r, "bounty", 3),
    windowStart: pick(r, "windowStart", 4),
    state: pick(r, "state", 5),
    specHash: pick(r, "specHash", 6),
    specToolId: pick(r, "specToolId", 8),
    isVulnerabilityReport: pick(r, "isVulnerabilityReport", 12),
    isClaimDispute: pick(r, "isClaimDispute", 13),
    linkedAuditId: pick(r, "linkedAuditId", 14),
    caseRoot: pick(r, "caseRoot", 18),
    supersedesAuditId: pick(r, "supersedesAuditId", 19),
  };
}

function parseClaim(r) {
  return {
    claimant: pick(r, "claimant", 0),
    toolId: pick(r, "toolId", 1),
    proofHash: pick(r, "proofHash", 2),
    stake: pick(r, "stake", 4),
    resolved: pick(r, "resolved", 5),
    exists: pick(r, "exists", 6),
  };
}

const CLAIM_STAKE_BPS = 5000n;

const fmeaRegistryAbi = [
  { type: "function", name: "toolKnownGapCount", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "toolKnownGapAt", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "uint256" }], outputs: [{ type: "bytes32" }] },
];
const integrityAbi = [
  { type: "function", name: "integrityReviewStatusOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint8" }] },
];
const specArbiterAbi = [
  { type: "function", name: "challengeActive", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bool" }] },
];

async function readAt(addr, abi, functionName, args = []) {
  if (!addr) return null;
  try {
    return await client.readContract({ address: addr, abi, functionName, args });
  } catch {
    return null;
  }
}

async function loadFmeaGaps(specToolId, fmeaAddr) {
  if (!fmeaAddr || !specToolId || specToolId === ZERO) return [];
  const n = await readAt(fmeaAddr, fmeaRegistryAbi, "toolKnownGapCount", [specToolId]);
  if (n == null || n === 0n) return [];
  const out = [];
  for (let i = 0n; i < n; i++) {
    const c = await readAt(fmeaAddr, fmeaRegistryAbi, "toolKnownGapAt", [specToolId, i]);
    if (c && c !== ZERO) out.push(c);
  }
  return out;
}
const DEFAULT_CLAIM_TOOL = "0xd485f0578dcf1925aa28cfb312584a4a172c4f5da7f05bde4c078c992b598456";
const SPEC_HASH = "0x7fe57aec3c363ab9da26d8a45f6bd22f30a5f441b597136e9b8fbcdca38fbe77";
const SPEC_TOOL = "0x6b158852c2edaa3e62fa63340ffca6c6eb5836485795e937ae647fdb35c9561b";
const SPEC_ERRORS = "0x781f8f2ec1a776740197b3a18452031254b7bf02b49544ce7a5ec35816c814d8";

function claimEligibleState(state) {
  return state === "AwaitingWindow" || state === "Audited" || state === "InBlock";
}

function stakeEstimate(bountyWei, floorWei) {
  const scaled = (bountyWei * CLAIM_STAKE_BPS) / 10000n;
  return scaled > floorWei ? scaled : floorWei;
}
function kindOf(a) { return a.isClaimDispute ? "dispute" : a.isVulnerabilityReport ? "fix" : "audit"; }
function buildReproduce(id, kind, target, linkedId, expectedRoot, toolId, cell) {
  if (!expectedRoot || !target || target === "0x0000000000000000000000000000000000000000") return null;
  return {
    label: kind === "dispute" ? "Dispute FAIL reproduction (pinned O)"
      : kind === "fix" ? "Fix-audit verdict root" : "Verdict / claim root",
    expectedRoot,
    target,
    toolId: toolId ?? DEFAULT_CLAIM_TOOL,
    spec: `${DOC}/specs/withdraw-credits-v1.md`,
    manifest: "../tools/withdraw-credits-v1.1/manifest.json",
    runbook: kind === "dispute" ? `${DOC}/predecessor/dispute-auditor-runbook.md` : null,
    harness: `# From Life repo root — recompute root on pinned target O\n$env:TARGET_ADDRESS="${target}"\n.\\tools\\withdraw-credits-v1.1\\run.ps1`,
    verifyCast: `cast call ${cell} "auditProofHash(uint256)" ${id} --rpc-url base_sepolia`,
    linkedOriginalId: kind === "dispute" || kind === "fix" ? linkedId || null : null,
  };
}
function outcomeOf(s) {
  return statusOutcome(s);
}

const DOC = "../../RealDeal/notebook";
const LOG_CHUNK = BigInt(process.env.LOG_CHUNK || "1999");

async function getEvents(eventName) {
  const latest = await client.getBlockNumber();
  const out = [];
  let start = FROM_BLOCK;
  while (start <= latest) {
    const end = start + LOG_CHUNK > latest ? latest : start + LOG_CHUNK;
    const chunk = await client.getContractEvents({ address, abi: auditCellAbi, eventName, fromBlock: start, toBlock: end });
    out.push(...chunk);
    start = end + 1n;
  }
  return out;
}

async function timelineByAudit() {
  const map = {};
  const push = (id, ev) => { (map[id] ??= []).push(ev); };
  const get = getEvents;
  const idOf = (l) => Number(l.args.id ?? l.args.originalAuditId);
  for (const l of await get("AuditSubmitted")) push(idOf(l), { i: "plus", label: "Submitted", detail: `bounty ${wei(l.args.bounty)} AUDIT`, tx: l.transactionHash });
  for (const l of await get("VerdictSubmitted")) push(idOf(l), { i: l.args.pass ? "circle-check" : "circle-x", label: `Verdict ${l.args.pass ? "PASS" : "FAIL"}`, detail: `tool ${short(l.args.toolId)} · root ${short(l.args.proofHash)}`, tx: l.transactionHash });
  for (const l of await get("AuditConfirmed")) push(idOf(l), { i: "cube", label: "Confirmed", detail: "→ InBlock", tx: l.transactionHash });
  for (const l of await get("VulnerabilityClaimed")) push(idOf(l), { i: "alert-triangle", label: "Claimed", detail: `by ${short(l.args.claimant)} · root ${short(l.args.proofHash)}`, tx: l.transactionHash });
  for (const l of await get("DisputeReauditOpened")) { push(Number(l.args.originalAuditId), { i: "git-branch", label: `Dispute opened #${l.args.disputeAuditId}`, detail: "pinned O", tx: l.transactionHash }); }
  for (const l of await get("OriginalAuditExploited")) push(idOf(l), { i: "coin", label: "Exploited", detail: `paid ${wei(l.args.amountPaid)} to ${short(l.args.discoverer)}`, tx: l.transactionHash });
  for (const l of await get("ClaimExpired")) push(idOf(l), { i: "rotate", label: "Claim expired (restored)", detail: "G-14 deadline path", tx: l.transactionHash });
  for (const l of await get("ClaimVindicated")) push(idOf(l), { i: "shield-check", label: "Claim vindicated", detail: `stake slashed ${wei(l.args.stakeSlashed)}`, tx: l.transactionHash });
  for (const l of await get("PositiveBlockMinted")) push(Number(l.args.auditId), { i: "coin", label: "Positive block mint", detail: `height ${l.args.height} · reward ${wei(l.args.reward)} AUDIT`, tx: l.transactionHash });
  return map;
}

async function networkTimeline() {
  const out = [];
  const get = getEvents;
  for (const l of await get("ToolCanonized")) {
    out.push({ i: "badge-check", label: "Tool canonized", detail: `tool ${short(l.args.toolId)}`, tx: l.transactionHash });
  }
  for (const l of await get("ToolCanonizationRewarded")) {
    out.push({ i: "sparkles", label: "CAN mint", detail: `${wei(l.args.reward)} AUDIT → ${short(l.args.proposer)}`, tx: l.transactionHash });
  }
  return out;
}

async function main() {
  const [n, height, successful, verifier, aw, crw, cfs, chainHash] = await Promise.all([
    read("nextAuditId"), read("blockHeight"), read("totalSuccessfulAudits"),
    read("claimVerifier"), read("minAuditWindow"), read("claimResolutionWindow"),
    read("claimFilingStake"), read("latestBlockHash"),
  ]);
  let toolMeta = null;
  try {
    const t = await read("tools", [DEFAULT_CLAIM_TOOL]);
    toolMeta = {
      toolId: DEFAULT_CLAIM_TOOL,
      proposer: pick(t, "proposer", 0),
      canonical: pick(t, "canonical", 3),
      successfulUses: Number(pick(t, "successfulUses", 5)),
    };
  } catch { toolMeta = null; }
  const tl = await timelineByAudit();
  const netTl = await networkTimeline();
  const cellToken = deployment?.CellToken ?? null;
  const fmeaAddr = deployment?.FmeaRegistry ?? null;
  const integrityAddr = deployment?.IntegrityReviewModule ?? null;
  const specArbiterAddr = deployment?.SpecArbiterModule ?? null;
  const fmeaGapCache = new Map();
  const audits = [];
  for (let id = 0; id < Number(n); id++) {
    const a = parseAudit(await read("audits", [BigInt(id)]));
    const root = await read("auditProofHash", [BigInt(id)]);
    const c = parseClaim(await read("vulnerabilityClaims", [BigInt(id)]));
    const activeDispute = Number(await read("activeDisputeAuditId", [BigInt(id)]));
    const kind = kindOf(a);
    const linkedId = Number(a.linkedAuditId) || null;
    const state = STATE[Number(a.state)];
    let verdictPass = null;
    if (!["Submitted", "Assigned", "InAudit"].includes(state)) {
      try { verdictPass = await read("auditVerdictPass", [BigInt(id)]); } catch { verdictPass = null; }
    }
    const resultRoot = root === ZERO ? null : root;
    const claimRoot = c.exists && c.proofHash !== ZERO ? c.proofHash : null;
    const expectedRoot = claimRoot ?? resultRoot;
    const toolId = c.exists ? c.toolId : (deployment?.withdrawCreditsToolId ?? DEFAULT_CLAIM_TOOL);
    const claimable = claimEligibleState(state) && kind === "audit" && !c.exists;
    const stakeWei = stakeEstimate(a.bounty, cfs);
    const specKey = a.specToolId ?? ZERO;
    let knownClassIds = fmeaGapCache.get(specKey);
    if (knownClassIds === undefined) {
      knownClassIds = await loadFmeaGaps(specKey, fmeaAddr);
      fmeaGapCache.set(specKey, knownClassIds);
    }
    const integrityReviewStatus = kind === "audit"
      ? Number(await readAt(integrityAddr, integrityAbi, "integrityReviewStatusOf", [BigInt(id)]) ?? 0)
      : 0;
    const specChallengeActive = kind === "audit"
      ? !!(await readAt(specArbiterAddr, specArbiterAbi, "challengeActive", [BigInt(id)]))
      : false;
    audits.push({
      id, kind, state, outcome: outcomeOf(state),
      protocol: a.protocol, auditor: a.auditor, target: a.deployedAddress,
      bounty: wei(a.bounty), bountyWei: a.bounty.toString(),
      specToolId: a.specToolId,
      specHash: a.specHash,
      resultRoot,
      verdictPass,
      verdictLabel: verdictPass === null ? null : verdictPass ? "PASS" : "FAIL",
      linkedAuditId: linkedId,
      caseRoot: a.caseRoot === ZERO ? null : a.caseRoot,
      claimable,
      claimStakeEth: wei(stakeWei),
      hasOpenDispute: activeDispute > 0,
      disputeAuditId: kind === "audit" && activeDispute > 0 ? activeDispute : (kind === "dispute" ? id : null),
      claim: c.exists ? { claimant: c.claimant, toolId: c.toolId, resultRoot: c.proofHash, stake: wei(c.stake), resolved: c.resolved } : null,
      integrityReviewStatus,
      specChallengeActive,
      fmea: { specToolId: a.specToolId, knownClassIds: knownClassIds.map((x) => x) },
      scope: scopeFieldsFromSpecHash(a.specHash),
      reproduce: buildReproduce(id, kind, a.deployedAddress, linkedId, expectedRoot, toolId, address),
      timeline: tl[id] || [],
      explorer: {
        cell: `https://sepolia.basescan.org/address/${address}`,
        target: a.deployedAddress !== "0x0000000000000000000000000000000000000000"
          ? `https://sepolia.basescan.org/address/${a.deployedAddress}` : null,
      },
    });
  }
  const claimableCount = audits.filter((x) => x.claimable).length;
  const model = {
    meta: {
      chainId: 84532, cell: address, cellToken, deployment: deployment?.cellVersion ?? null,
      fromBlock: FROM_BLOCK.toString(),
      claimVerifier: verifier, trustMode: verifier === "0x0000000000000000000000000000000000000000" ? "declare-only · testnet-grade" : "verifier-gated",
      audits: Number(n), claimableCount, positiveBlocks: Number(height), successful: Number(successful),
      auditWindowSec: Number(aw), claimResolutionWindowSec: Number(crw),
      claimFilingStakeEth: wei(cfs), claimStakeBps: Number(CLAIM_STAKE_BPS),
      defaultClaimToolId: deployment?.withdrawCreditsToolId ?? DEFAULT_CLAIM_TOOL,
      latestBlockHash: chainHash === ZERO ? null : chainHash,
      withdrawCreditsTool: toolMeta,
      rollout: {
        m1Complete: deployment?.m1Complete ?? null,
        m2Complete: deployment?.m2Complete ?? null,
        phaseCAuditId: deployment?.phaseCAuditId ?? null,
        phaseDAuditId: deployment?.phaseDAuditId ?? null,
        phaseHCanonAuditId: deployment?.phaseHCanonAuditId ?? null,
      },
      networkTimeline: netTl,
      specHash: deployment?.specHash ?? SPEC_HASH,
      specToolId: deployment?.specToolId ?? SPEC_TOOL,
      specErrorsRoot: SPEC_ERRORS,
      rpcUrl: process.env.RPC_URL || "https://sepolia.base.org",
      generatedAt: new Date().toISOString(),
      explorer: {
        cell: `https://sepolia.basescan.org/address/${address}`,
        token: cellToken ? `https://sepolia.basescan.org/address/${cellToken}` : null,
      },
      reproduce: {
        spec: `${DOC}/specs/withdraw-credits-v1.md`,
        manifest: "../tools/withdraw-credits-v1.1/manifest.json",
        lifeRun: "../tools/withdraw-credits-v1.1/run.ps1",
        runbook: `${DOC}/predecessor/dispute-auditor-runbook.md`,
        forge: "# cell sibling: cd ../cell && forge script script/tools/RunWithdrawCreditsV1.s.sol:RunWithdrawCreditsV1",
      },
      guides: {
        registerAuditor: `# ${DOC}/operator/runbooks/CUTOVER-RUNBOOK.md — register() on live cell`,
        postAudit: `# membrane/post.html or ${DOC}/operator/runbooks/CUTOVER-RUNBOOK.md`,
        concern: "membrane/concern.html",
        ideas: "ideas.html",
      },
      fmeaRegistry: fmeaAddr,
      integrityReviewModule: integrityAddr,
      specArbiterModule: specArbiterAddr,
      cellDependency: "../../RealDeal/notebook/ops/cell-dependency.md",
    },
    audits,
  };
  writeFileSync(new URL("./view-model.json", import.meta.url), JSON.stringify(model, null, 2));
  writeFileSync(new URL("./view-model.js", import.meta.url), `window.__MODEL = ${JSON.stringify(model)};\n`);
  console.log(`Indexed ${model.meta.audits} audits → view-model.json (+ .js). trustMode: ${model.meta.trustMode}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
