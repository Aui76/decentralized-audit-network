/**
 * Live Step 0 chain facts — eth_call refresh for concern.html (zero deps, browser-safe).
 * Refreshes only Step-0 routing fields; scope/FMEA stay on the indexed view-model row.
 */
import { AuditState } from "../../cell/indexer/auditState.mjs";

const INTEGRITY_OPEN = new Set([1, 2]);
const CLAIM_ELIGIBLE = new Set([
  AuditState.AwaitingWindow,
  AuditState.Audited,
  AuditState.InBlock,
]);

const DEFAULT_RPC = "https://sepolia.base.org";

// Minimal keccak256 (same as verify.mjs — zero deps).
const _KM = (1n << 64n) - 1n;
const _KRC = [0x1n, 0x8082n, 0x800000000000808An, 0x8000000080008000n, 0x808Bn, 0x80000001n, 0x8000000080008081n, 0x8000000000008009n, 0x8An, 0x88n, 0x80008009n, 0x8000000An, 0x8000808Bn, 0x800000000000008Bn, 0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800An, 0x800000008000000An, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
const _KRHO = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
const _Krot = (x, n) => (n === 0n ? x : ((x << n) | (x >> (64n - n))) & _KM);
function keccak256(input) {
  const S = new Array(25).fill(0n);
  const rate = 136;
  const len = input.length;
  const pl = Math.ceil((len + 1) / rate) * rate;
  const p = new Uint8Array(pl);
  p.set(input);
  p[len] ^= 1;
  p[pl - 1] ^= 0x80;
  for (let o = 0; o < pl; o += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let l = 0n;
      for (let j = 0; j < 8; j++) l |= BigInt(p[o + i * 8 + j]) << (8n * BigInt(j));
      S[i] ^= l;
    }
    for (let r = 0; r < 24; r++) {
      const C = [0, 1, 2, 3, 4].map((x) => S[x] ^ S[x + 5] ^ S[x + 10] ^ S[x + 15] ^ S[x + 20]);
      const D = [0, 1, 2, 3, 4].map((x) => C[(x + 4) % 5] ^ _Krot(C[(x + 1) % 5], 1n));
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) S[x + 5 * y] ^= D[x];
      const B = new Array(25).fill(0n);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = _Krot(S[x + 5 * y], BigInt(_KRHO[x + 5 * y]));
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) S[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y]) & _KM;
      S[0] ^= _KRC[r];
    }
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let l = S[i];
    for (let j = 0; j < 8; j++) out[i * 8 + j] = Number((l >> (8n * BigInt(j))) & 0xffn);
  }
  return out;
}

/** @param {string} sig */
export function fnSelector(sig) {
  const hash = keccak256(new TextEncoder().encode(sig));
  const hex = [...hash].map((b) => b.toString(16).padStart(2, "0")).join("");
  return "0x" + hex.slice(0, 8);
}

/** @param {bigint | number | string} n */
export function padU256(n) {
  let x = BigInt(n);
  const out = new Uint8Array(32);
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

export function bytesToHex(u) {
  return "0x" + [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** @param {string} hex @param {number} wordIndex */
export function readWord(hex, wordIndex) {
  const s = hex.replace(/^0x/, "");
  const start = wordIndex * 64;
  return "0x" + s.slice(start, start + 64);
}

export function readU8(hex, wordIndex) {
  return Number(BigInt(readWord(hex, wordIndex)) & 0xffn);
}

export function readBool(hex, wordIndex) {
  return BigInt(readWord(hex, wordIndex)) !== 0n;
}

export function readU256(hex, wordIndex) {
  return BigInt(readWord(hex, wordIndex));
}

/**
 * @param {string} rpcUrl
 * @param {string} to
 * @param {string} data
 */
export async function ethCall(rpcUrl, to, data) {
  const r = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to, data }, "latest"],
    }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
  return j.result;
}

/** Decode audits(uint256) static tuple (AuditCell getter order). */
export function decodeAuditsReturn(hex) {
  return {
    state: readU8(hex, 5),
    isVulnerabilityReport: readBool(hex, 12),
    isClaimDispute: readBool(hex, 13),
  };
}

/** Decode vulnerabilityClaims(uint256) tuple tail fields. */
export function decodeClaimReturn(hex) {
  return {
    resolved: readBool(hex, 5),
    exists: readBool(hex, 6),
  };
}

/**
 * @param {object} cfg
 * @param {string} cfg.cell
 * @param {number | bigint} cfg.auditId
 * @param {string} [cfg.rpcUrl]
 * @param {string | null} [cfg.integrityModule]
 * @param {string | null} [cfg.specArbiterModule]
 * @param {string} [cfg.auditKind] — view-model kind (audit | dispute | fix)
 */
export async function fetchStep0ChainFacts(cfg) {
  const rpcUrl = cfg.rpcUrl || DEFAULT_RPC;
  const cell = cfg.cell;
  const id = BigInt(cfg.auditId);
  const idHex = bytesToHex(padU256(id)).slice(2);

  const auditData = fnSelector("audits(uint256)") + idHex;
  const claimData = fnSelector("vulnerabilityClaims(uint256)") + idHex;
  const disputeData = fnSelector("activeDisputeAuditId(uint256)") + idHex;

  const [auditHex, claimHex, disputeHex] = await Promise.all([
    ethCall(rpcUrl, cell, auditData),
    ethCall(rpcUrl, cell, claimData),
    ethCall(rpcUrl, cell, disputeData),
  ]);

  const audit = decodeAuditsReturn(auditHex);
  const claim = decodeClaimReturn(claimHex);
  const disputeId = readU256(disputeHex, 0);

  let integrityOpen = false;
  if (cfg.integrityModule) {
    const ih = await ethCall(rpcUrl, cfg.integrityModule, fnSelector("integrityReviewStatusOf(uint256)") + idHex);
    integrityOpen = INTEGRITY_OPEN.has(readU8(ih, 0));
  }

  let specChallengeOpen = false;
  if (cfg.specArbiterModule) {
    const sh = await ethCall(
      rpcUrl,
      cfg.specArbiterModule,
      fnSelector("challengeActive(uint256)") + idHex,
    );
    specChallengeOpen = readBool(sh, 0);
  }

  const kind = cfg.auditKind ?? (audit.isClaimDispute ? "dispute" : audit.isVulnerabilityReport ? "fix" : "audit");
  const claimOpen = claim.exists && !claim.resolved;
  // Matches ClaimDisputeModule._claimEligible (AwaitingWindow | Audited | InBlock)
  // plus membrane/indexer: kind === "audit" && !vulnerabilityClaims(id).exists.
  // Does not check claimant identity (wallet path enforces that at tx time).
  const claimFilingAllowed = kind === "audit" && CLAIM_ELIGIBLE.has(audit.state) && !claim.exists;

  return {
    state: audit.state,
    claimOpen,
    claimExists: claim.exists,
    disputeOpen: disputeId > 0n,
    integrityOpen,
    specChallengeOpen,
    claimFilingAllowed,
    refreshedAt: new Date().toISOString(),
    source: "rpc",
  };
}

/**
 * Overlay live Step-0 fields onto chain facts from the indexed row.
 * @param {object} baseChain — auditRowToChainFacts(row)
 * @param {object} live — fetchStep0ChainFacts result
 */
export function mergeLiveStep0ChainFacts(baseChain, live) {
  if (!live) return baseChain;
  return {
    ...baseChain,
    state: live.state ?? baseChain.state,
    claimOpen: live.claimOpen ?? baseChain.claimOpen,
    disputeOpen: live.disputeOpen ?? baseChain.disputeOpen,
    integrityOpen: live.integrityOpen ?? baseChain.integrityOpen,
    specChallengeOpen: live.specChallengeOpen ?? baseChain.specChallengeOpen,
    claimFilingAllowed: live.claimFilingAllowed ?? baseChain.claimFilingAllowed,
    step0RefreshedAt: live.refreshedAt ?? null,
    step0Source: live.source ?? "indexed",
  };
}

/** Patch view-model audit row display fields after live refresh. */
export function patchAuditRowFromStep0(audit, live) {
  if (!audit || !live) return audit;
  const names = [
    "None", "Submitted", "Assigned", "InAudit", "AwaitingWindow", "Audited",
    "InBlock", "Claimed", "Exploited", "Invalidated",
  ];
  const next = { ...audit };
  if (live.state != null) next.state = names[live.state] ?? audit.state;
  next.claimable = !!live.claimFilingAllowed;
  next.hasOpenDispute = !!live.disputeOpen;
  if (live.claimOpen) {
    next.claim = { ...(audit.claim || {}), resolved: false };
  } else if (!live.claimExists) {
    next.claim = null;
  }
  next.integrityReviewStatus = live.integrityOpen ? 1 : 0;
  next.specChallengeActive = !!live.specChallengeOpen;
  next.step0RefreshedAt = live.refreshedAt;
  return next;
}
