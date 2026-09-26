#!/usr/bin/env node
// dan-check — the first CONSUMER of a DAN verdict: one command that refuses.
//
//   node body/tools/dan-check.mjs --target 0xADDR \
//        --target-rpc <url> --home-rpc <url> --cell 0xCELL [--deep] [--json]
//
// Exit 0 = clean, settled, window closed.  Exit 1 = REFUSE.  Exit 2 = CANNOT VERIFY.
// Bolt it onto your own door:  dan-check --target 0x… || exit 1
//
// WHAT THIS IS. A read-only chain lookup. It fetches the target's runtime code from the
// TARGET chain, recomputes its codehash, and asks the DAN cell on the HOME chain what
// verdict is settled for that hash. No LLM, no judgement, no cell bytes, nothing written
// anywhere. Reproducible by anyone with two RPC URLs. The gate is YOURS and opt-in — the
// network does not refuse to settle on your behalf, and making it do so would be a
// mechanism change with its own attack surface (FC-14).
//
// TWO SOURCES ARE NOT AUTOMATICALLY TWO SOURCES (VD-256). `--target-rpc-2` compares two endpoints and
// refuses when they differ - but two URLs from the SAME provider are ONE source wearing two hostnames,
// and this tool cannot tell. It sees URLs, not corporate structure. INDEPENDENCE IS YOURS TO SUPPLY;
// the flag only makes disagreement loud once you have supplied it.
//
// THE PROOF WAS WEIGHED AND PARKED (VD-256, row FC-21). `eth_getProof` at the pinned block would carry a
// Merkle proof of the account - codehash included - verifiable OFFLINE by a reader with no RPC, which
// changes the claim from testimony to verification. It is parked, not missed, and its honest limit is the
// reason: the proof verifies against a state root, the root comes from a header, and without a light
// client the header still comes from an endpoint. So it licenses "verifiable against a block hash you
// obtained elsewhere", never "trustless". The trigger is written on FC-21 - a consumer who cannot re-run
// the command, or the first exit-2 disagreement seen in the wild.
//
// THE ANCHOR, AND WHAT A ROW WITHOUT ONE MEANS (VD-255, 2026-09-22). A DAN row certifies BYTES.
// The artifact is a hash and the verdict is about the code whose hash that is. A row MAY also carry
// a deployed address, and where it does the cell checked AT SUBMIT that the address really held that
// code (`ArtifactHashMismatch`). A row submitted WITHOUT one - a contract on another chain, a Solana
// program, a document, a dataset - certifies the bytes and asserts NO link to any deployment, because
// the cell cannot see another chain and does not pretend to. THE LINK IS THE READER'S TO CHECK, AND
// THIS TOOL IS THAT CHECK: it hashes the live code itself and refuses when no settled row matches.
// Why the cell can leave it to you without leaving money on it: NO PAYMENT READS THE ADDRESS.
// `CellLogicLib` touches `deployedAddress` at create, on supersede and in the submit event, and
// nowhere else; the two `BytecodeDrift` guards gate the OPENING of a dispute re-audit, and for an
// unanchored row there is nothing to drift from - the row IS the bytes.
//
// WHAT IT REPORTS, and the distinction is the point: a SETTLED ON-CHAIN VERDICT. Never a
// simulation, never a prediction, never a preview. (FC-14 refusal-vocabulary constraint,
// board 0.3 — the 2026-08-08 simulation-phishing class: the same bytecode can answer a
// pre-signing simulator differently from the chain, because the contract branches on the
// observation environment. No identity check closes that, because the codehash is constant
// throughout. This tool never previews anything, which is why it is immune — and it says so
// rather than leaving a reader to assume.)
//
// ── THE SIX OBSERVER LAWS (FC-7) BIND THIS TOOL ─────────────────────────────────────────
// FC-7's row states them and says in terms that they "bind FC-14 / FC-1 equally — a consumer
// tool is an observer someone else runs". Where each lands here:
//   (1) measure at source ....... code comes from the target chain, hash recomputed locally;
//                                 nothing trusts a third-party index or a cached answer.
//   (2) absence is not zero ..... a missing index entry is UNMEASURED, not "never audited".
//                                 See THE AMBIGUITY below — this is the sharpest rule here.
//   (3) three verdicts .......... PASS / REFUSE / CANNOT-VERIFY. "Couldn't check" must never
//                                 render as either a pass or a fail. This is why exit 2
//                                 exists and why every RPC failure lands there, never on 0.
//   (4) number ≠ verdict ........ the raw state name and id are printed beside the verdict,
//                                 both labelled, so a reader can disagree with the mapping.
//   (5) no assertion that cannot fail ... the clean path requires a POSITIVE match on a
//                                 specific state; it is never "nothing looked wrong".
//   (6) every finding gets a disposition ... every state in the enum is named below. None
//                                 falls through to a default.
//
// ── THE AMBIGUITY, and why --deep exists ────────────────────────────────────────────────
// `artifactToAuditId(hash) == 0` does NOT mean "never audited". Verified by call path
// (AuditCell.sol:1385-1387 `_voidAuditRow`, and :1405-1407 the spec-invalidation path):
// both DELETE the index entry and set the row to `Invalidated`. The audit row still exists
// — it is simply no longer reachable from the codehash. So an absent index means EITHER
// "never audited" OR "audited, then invalidated", and those are materially different facts
// to hand someone deciding whether to deploy. Both REFUSE (exit 1), so the gate is
// fail-closed either way; --deep walks nextAuditId() and matches artifactHash to say which.
// Default is the two-call path because O(N) on every CI run is a cost most callers will
// route around, and a check people disable is worse than a slower one they keep.
//
// AND ZERO IS A ROW (PC-132, measured 2026-09-24). Audit ids start at 0 (`id = L.nextAuditId++`,
// CellLogicLib.sol), and the live cell's row 0 is its genesis audit (PC-77). So the index answers
// 0 for the first row a cell ever files AND for "no entry", and until PC-132 this tool read both
// as absence: Room 1's settled Beanstalk verdict — row 0, InBlock, on a fresh deploy of the cured
// hull — was REFUSED, and --deep, walking from 1, called it NEVER AUDITED ("all 0 of 0 rows
// read"). The cell keeps the disambiguator itself: `artifactRegistered[h]` (CellStorage.sol:139),
// set beside the index (AuditCell.sol:1319-1320) and cleared with it (SubmitAuditLib.sol:608-609,
// :639). The lookup reads that bit FIRST; the index value is only consulted when the bit says
// there is an entry, and --deep walks from 0. No hull byte changed for this; the cure is here.
//
// ── WHAT IS DELIBERATELY NOT READ ───────────────────────────────────────────────────────
// Spec-gap status. `SpecGapModule.Status.Declined` is a label the AUDITED PARTY sets at zero
// cost, while the underlying failure had to verify against a pinned artifactHash+specHash to
// be fileable at all (FC-15's Team Finance residual: "a derived view must never render a
// protocol-set label as a merit finding"). A consumer reading that enum without the
// known-gaps list and the event history would read "declined" as "not a real gap". This tool
// therefore reads AuditState ONLY and says so — adding a gap read later means also reading
// `toolHasGap` and the event trail, or not adding it.
//
// ── THE ONE CONSUMER THIS TOOL CANNOT BE (PC-32's explicit cannot) ──────────────────────
// Owed by PC-32 since 2026-08-13 and SKIPPED by this build; written 2026-08-20 when the
// sweep found the trigger had fired and gone unread. It is here, not in the board row,
// because the person who needs it is whoever opens this file to build a consumer on top.
//
// A CONSUMER THAT RENDERS A CODEHASH FOR A HUMAN TO COMPARE IS NOT A GUARANTEE, and this
// tool must never be presented as making one. PC-32's hard constraint: the refusal that
// protects value has to be a REVERT IN THE CODE THAT MOVES THE VALUE, not a check a person
// performs. In the cell those are `ClaimDisputeModule:401` and `SpecGapModule:251` — both
// `if (deployed != address(0) && deployed.codehash != artifactHash) revert BytecodeDrift()`.
// That is the guarantee. This tool is a SATELLITE: it reads chain state that already exists
// and reaches the same conclusion earlier, off-chain, where a human can act on it. Useful,
// and not load-bearing.
//
// The failure mode is not "the tool is wrong" — it is a UI that prints two hashes side by
// side and calls the comparison "verified". A check a human can skip is the same pole as an
// off-chain council: it holds exactly as long as attention does. If you are building that
// UI, the honest label is "this address matches the audit row as of block N", never
// "verified" or "safe".
//
// SCOPE QUALIFIER, measured 2026-08-20 and true of the cell, not of this tool: both in-path
// guards are conditional on `deployed != address(0)`. An audit with no deployed address (the
// optional EVM anchor at `SubmitAuditLib.sol:205`) moves value with no drift guard — there
// is nothing to drift, so it is not a defect, but "every value-moving path is covered" holds
// only for audits that HAVE a deployed address. Do not repeat the claim without the clause.
//
// ── NO BYPASS ───────────────────────────────────────────────────────────────────────────
// There is deliberately no --force, no --ignore, no allowlist and no exit-code override.
// Any such flag is guard surface: it becomes the thing CI sets once and never unsets, and
// then the refusal is decorative. If you need to proceed past a refusal, that is a decision
// a human takes visibly in their own pipeline, not a flag this tool hands them.

import { keccak256Hex, selector } from "./keccak256.mjs";
import { pathToFileURL } from "node:url";

const SPEC_VERSION = "dan-check/1";

// AuditState, from cell/contracts/CellStorage.sol:13-23. Order is load-bearing — these are
// ABI indices, and an off-by-one here reports the wrong verdict silently.
const AUDIT_STATE = [
  "None", "Submitted", "Assigned", "InAudit", "AwaitingWindow",
  "Audited", "InBlock", "Claimed", "Exploited", "Invalidated",
];

// THE MAPPING, and every entry cites why. Verified by call path 2026-08-20, not assumed.
//
// Only `InBlock` is clean. CellLogicLib.sol:535-539 gates the AwaitingWindow -> InBlock
// transition on `block.timestamp >= a.windowStart + a.auditWindow` — i.e. InBlock is
// precisely "the adversarial window has CLOSED". `AwaitingWindow` therefore means the window
// is still OPEN and anyone may still claim a vulnerability; exiting 0 there would assert that
// a passing audit is a promise, which is the one thing DAN's design refuses in writing.
//
// Note what this does NOT claim: AuditCell.sol:1012-1013 `_claimEligibleState` includes
// InBlock, so a vulnerability can still be claimed against a clean artifact. "Clean" means
// "settled, window closed, nothing claimed as of this block" — never "safe forever". The
// asOfBlock stamp exists so a reader can tell how old that answer is.
const VERDICT = {
  None:           { exit: 1, why: "no settled audit reachable for this codehash" },
  Submitted:      { exit: 2, why: "audit submitted, not yet assigned — no verdict exists yet" },
  Assigned:       { exit: 2, why: "audit assigned, not yet started — no verdict exists yet" },
  InAudit:        { exit: 2, why: "audit in progress — no verdict exists yet" },
  AwaitingWindow: { exit: 2, why: "verdict submitted but the ADVERSARIAL WINDOW IS STILL OPEN (CellLogicLib.sol:535-539) — not yet confirmed" },
  Audited:        { exit: 2, why: "state 'Audited' — set on the spec-gap path (AuditCell.sol:1323) and not the confirmed-settlement state; treated as unverifiable rather than guessed" },
  InBlock:        { exit: 0, why: "settled and the adversarial window has closed" },
  Claimed:        { exit: 1, why: "a VULNERABILITY CLAIM IS OPEN against this artifact" },
  Exploited:      { exit: 1, why: "this artifact is recorded EXPLOITED" },
  Invalidated:    { exit: 1, why: "the audit for this artifact was INVALIDATED" },
};

// ── minimal ABI encoding: 4-byte selector + 32-byte words. No dependencies on purpose —
// a tool whose job is refusing should not carry a supply chain to do it. ───────────────
// DERIVED, never transcribed. The first draft of this file hardcoded three selectors written
// from memory and ALL THREE WERE WRONG (artifactToAuditId is 0xf1c8eee2, not 0x9e1a4d19).
// Shipped, every call would have hit a nonexistent function, reverted, and been reported as
// "cannot verify" — fail-closed and completely useless, i.e. a tool that refuses everything
// looks exactly like a tool that works until someone checks a clean artifact. Deriving them
// from the signature removes the failure mode instead of testing for it.
const SELECTORS = {
  artifactRegistered: selector("artifactRegistered(bytes32)"),
  artifactToAuditId: selector("artifactToAuditId(bytes32)"),
  nextAuditId: selector("nextAuditId()"),
  getAudit: selector("getAudit(uint256)"),
};

function pad32(hexNo0x) { return hexNo0x.padStart(64, "0"); }

export function encodeCall(selector, ...words) {
  return selector + words.map((w) => pad32(String(w).replace(/^0x/, ""))).join("");
}

export function isDesignator(code) {
  // EIP-7702 delegation designator: exactly 23 bytes, 0xef0100 || 20-byte address.
  // PC-18/DEC-34 HARD requirement (FC-14 row): refuse, and name the delegate.
  const h = (code || "").replace(/^0x/, "").toLowerCase();
  return h.length === 46 && h.startsWith("ef0100");
}

export function delegateOf(code) {
  return "0x" + (code || "").replace(/^0x/, "").toLowerCase().slice(6);
}

export class Refusal extends Error {
  constructor(exit, reason, detail, out) {
    super(reason);
    this.exit = exit;
    this.reason = reason;
    this.detail = detail || null;
    // Carries whatever was measured before the refusal, so --json stamps a refusal with the
    // same specVersion / asOfBlock / codehash provenance as a pass. A refusal nobody can
    // reproduce is worth little more than no refusal.
    this.out = out || null;
  }
}

// `rpc` is injected so the whole decision path is testable offline against fixtures. A tool
// that can only be tested against a live chain gets tested once (2026-08-20 lesson: the
// accept path is the half fail-closed reasoning cannot cover).
// eth_getCode takes a block as a hex QUANTITY or a tag. A person meets block numbers as decimals
// (explorers, `--fork-block-number`, the plaques), and a node handed "14595905" refuses it — which
// this tool then reported as CANNOT VERIFY, so the pin only worked for callers who converted by
// hand (measured 2026-09-24 against anvil). Decimal is converted; hex and tags pass through.
export function normalizeBlock(block) {
  if (!block) return null;
  const s = String(block).trim();
  return /^\d+$/.test(s) ? "0x" + BigInt(s).toString(16) : s;
}

export async function danCheck({ target, cell, rpc, keccak256, deep = false , block }) {
  const a_block = normalizeBlock(block);
  const out = {
    specVersion: SPEC_VERSION,
    computedAtUtc: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    reports: "settled on-chain verdict",   // never a simulation, preview or prediction
    reads: "AuditState only (not spec-gap status — see header)",
    target, cell,
  };

  // (1) measure at source. Law (3): any read failure is exit 2, never a benign default.
  let code, asOfBlock;
  try {
    // `--block` PINS THE QUESTION (VD-255 follow-on). `latest` answers "right now, according to this
    // endpoint", which is true when asked and unreproducible five minutes later: a proxy upgrade or a
    // selfdestruct+CREATE2 at the same address moves the bytes under a claim that has no time in it.
    // A pinned block makes the time part of the statement - anyone with an archive node re-asks and
    // gets the same answer forever, which is the discipline the fork-at-a-block exhibits already use.
    const at = a_block || "latest";
    code = await rpc.target("eth_getCode", [target, at]);
    out.readAtBlock = at;
    asOfBlock = await rpc.home("eth_blockNumber", []);
    // A SECOND ENDPOINT CANNOT MAKE EITHER HONEST - it makes a lying or lagging one LOUD. This repo has
    // already been served stale state by a lagging node (an all-zero block hash beside a real receipt).
    // Disagreement is exit 2, never exit 0: two sources that differ have not verified anything.
    if (rpc.target2) {
      const code2 = await rpc.target2("eth_getCode", [target, at]);
      out.secondSource = true;
      if ((code2 || "0x") !== (code || "0x")) {
        throw new Refusal(2, "CANNOT VERIFY: two target RPCs disagree about the code at this address",
                          `at ${at}: source A ${(code || "0x").length} bytes, source B ${(code2 || "0x").length} bytes`,
                          out);
      }
    }
    out.targetChainId = BigInt(await rpc.target("eth_chainId", [])).toString();
    out.homeChainId = BigInt(await rpc.home("eth_chainId", [])).toString();
  } catch (e) {
    // A Refusal raised INSIDE this block already knows what went wrong - re-wrapping it as "an RPC read
    // failed" would replace a true diagnosis with a false one (the two-endpoint disagreement reads as a
    // dead RPC). Same law (3), better sentence: unverified, and say which unverified.
    if (e instanceof Refusal) throw e;
    throw new Refusal(2, "CANNOT VERIFY: an RPC read failed, so nothing was checked", String(e.message || e), out);
  }
  out.asOfBlockHome = asOfBlock;

  if (!code || code === "0x") {
    throw new Refusal(1, "REFUSE: target has no code (EOA, or not deployed on this chain)", null, out);
  }

  // (2) PC-18/DEC-34, before any lookup — the codehash of a designator would match the
  // AUDITED POINTER while behaviour lives at the mutable delegate.
  if (isDesignator(code)) {
    const d = delegateOf(code);
    throw new Refusal(1,
      `REFUSE: target is an EIP-7702 delegation designator pointing at ${d}`,
      `An audit row for this address would certify the POINTER, not the delegate, and the ` +
      `delegate is mutable. Auditing a delegate is legitimate — the right target is the ` +
      `delegate's own address: re-run with --target ${d}`, out);
  }

  const codehash = keccak256(code);
  out.codehash = codehash;

  // (3) the lookup: codehash -> presence bit -> auditId -> state. The bit comes first because the
  // index answers 0 both for "no entry" and for row 0, and row 0 is a real row (PC-132, header).
  let registered, auditId;
  try {
    registered = BigInt(await rpc.home("eth_call",
      [{ to: cell, data: encodeCall(SELECTORS.artifactRegistered, codehash) }, "latest"])) !== 0n;
    if (registered) {
      auditId = BigInt(await rpc.home("eth_call",
        [{ to: cell, data: encodeCall(SELECTORS.artifactToAuditId, codehash) }, "latest"]));
    }
  } catch (e) {
    throw new Refusal(2, "CANNOT VERIFY: the home-chain lookup failed", String(e.message || e), out);
  }

  if (!registered) {
    // Law (2): absence is UNMEASURED. Say which absence it is, or say that you cannot.
    let detail = "No audit row is reachable from this codehash. That means EITHER it was " +
      "never audited, OR it was audited and the audit was invalidated (which DELETES the " +
      "index — AuditCell.sol:1385-1387, :1405-1407). Re-run with --deep to distinguish them.";
    if (deep) {
      const r = await deepScan({ cell, rpc, codehash });
      out.deepScan = r;
      if (r.id) {
        detail = `Deep scan: audit #${r.id} carries this artifactHash in state ${r.state} — ` +
          `the artifact WAS audited and its index was cleared.`;
      } else if (r.skipped > 0) {
        detail = `Deep scan INCONCLUSIVE: ${r.scanned} of ${r.rows} rows read, ` +
          `${r.skipped} UNREADABLE (short getAudit return). This artifact matched none of the ` +
          `rows that could be read — but "never audited" would be a claim built out of the ` +
          `rows that could not. Still refusing; the ambiguity is NOT resolved.`;
      } else {
        detail = `Deep scan complete: all ${r.scanned} of ${r.rows} rows read, none carries ` +
          `this artifactHash — NEVER AUDITED.`;
      }
    }
    throw new Refusal(1, "REFUSE: no settled audit reachable for this codehash", detail, out);
  }

  out.auditId = auditId.toString();
  let row;
  try {
    row = await readAuditRow({ cell, rpc, auditId });
  } catch (e) {
    throw new Refusal(2, "CANNOT VERIFY: could not read the audit row", String(e.message || e), out);
  }

  // The audit row must actually be ABOUT the artifact we hashed. The index is a mapping and
  // mappings can be cleared and rewritten (AuditCell.sol:1365-1366 writes, :1386-1387 and
  // :1406-1407 delete); confirming the row's own artifactHash closes the gap between "the
  // index pointed here" and "this row certifies this bytecode". Law (5): the clean path
  // requires a positive match, never the absence of a complaint.
  if (row.artifactHash.toLowerCase() !== codehash.toLowerCase()) {
    throw new Refusal(2,
      `CANNOT VERIFY: index points at audit #${auditId}, but that row's artifactHash is ` +
      `${row.artifactHash}, not ${codehash}`, null, out);
  }

  // SCOPE, from CellStorage.sol:50-56 (G-30 reserve, DEC-18/DEC-22): `targetChainId` records
  // which chain the audited artifact lives on, 0 meaning this cell's own chain. No write path
  // sets it today by design, so every row today certifies a HOME-CHAIN artifact. If the caller
  // pointed at a different chain, a codehash match is not by itself a verdict about THAT
  // deployment — extending a home-chain verdict across chains is FC-1's job and its own
  // decision. FC-14 is the home-chain-first slice, so say so rather than quietly widening.
  if (row.targetChainId === 0n && out.targetChainId !== out.homeChainId) {
    throw new Refusal(2,
      `CANNOT VERIFY: the audit row certifies this artifact on the HOME chain ` +
      `(${out.homeChainId}) and you asked about chain ${out.targetChainId}`,
      "Identical bytecode on another chain is a different deployment. Carrying a verdict " +
      "across chains is FC-1's seam, not this tool's — dan-check will not assume it.", out);
  }
  if (row.targetChainId !== 0n && row.targetChainId.toString() !== out.targetChainId) {
    throw new Refusal(2,
      `CANNOT VERIFY: the audit row names target chain ${row.targetChainId}, ` +
      `you asked about chain ${out.targetChainId}`, null, out);
  }

  const stateIdx = row.state;
  const name = AUDIT_STATE[stateIdx];
  if (name === undefined) {
    // Law (6): nothing falls through. An unknown index means the enum moved under us.
    throw new Refusal(2,
      `CANNOT VERIFY: audit #${auditId} reports state index ${stateIdx}, which this tool ` +
      `does not know. The cell's AuditState enum has changed; dan-check is out of date.`, null, out);
  }

  // Law (4): publish the raw observation beside the interpretation, both labelled.
  out.state = name;
  out.stateIndex = stateIdx;
  const v = VERDICT[name];
  out.verdictReason = v.why;

  if (v.exit !== 0) throw new Refusal(v.exit, `${v.exit === 1 ? "REFUSE" : "CANNOT VERIFY"}: ${v.why}`, null, out);
  out.verdict = "CLEAN";
  return out;
}

// Audit is a FULLY STATIC struct (CellStorage.sol:26-57 — every member is address/uint/bool/
// bytes32/enum, no dynamic type), so getAudit returns it inline with NO leading offset word.
// That was checked, not assumed: one dynamic member anywhere in the struct shifts every index
// below by one and this tool would report a confident, wrong verdict.
//   word 6 = state      word 8 = artifactHash      word 23 = targetChainId
//
// W_TARGET_CHAIN WAS 24 AND THAT WAS WRONG (fixed 2026-08-20). The struct has 24 fields, so
// the last index is 23; six comment lines sit between `bountyEscrowed` and `targetChainId`
// and I counted them. The unit fixtures encoded 25 words and asserted the same wrong constant,
// so the suite passed 41/41 — the test agreed with the code because one person wrote both
// against one mistaken count. The LIVE cell returned 24 words and the smoke caught it in one
// call. dan-check.test.mjs now derives these three offsets from CellStorage.sol itself, so a
// shared assumption is no longer possible: the source is the only place the number lives.
export const W_STATE = 6, W_ARTIFACT = 8, W_TARGET_CHAIN = 23;

async function readAuditRow({ cell, rpc, auditId }) {
  const raw = await rpc.home("eth_call",
    [{ to: cell, data: encodeCall(SELECTORS.getAudit, auditId.toString(16)) }, "latest"]);
  const words = raw.replace(/^0x/, "").match(/.{64}/g) || [];
  if (words.length <= W_TARGET_CHAIN) {
    throw new Error(`short getAudit return (${words.length} words, need > ${W_TARGET_CHAIN})`);
  }
  return {
    state: Number(BigInt("0x" + words[W_STATE])),
    artifactHash: "0x" + words[W_ARTIFACT],
    targetChainId: BigInt("0x" + words[W_TARGET_CHAIN]),
  };
}

async function deepScan({ cell, rpc, codehash }) {
  const n = BigInt(await rpc.home("eth_call",
    [{ to: cell, data: SELECTORS.nextAuditId }, "latest"]));
  const want = codehash.toLowerCase();
  let scanned = 0, skipped = 0;
  // From 0: the first row a cell files is id 0 (PC-132). Starting at 1 skipped the genesis audit
  // on the live cell and the only row on a fresh one, and then called the artifact NEVER AUDITED.
  for (let i = 0n; i < n; i++) {
    const raw = await rpc.home("eth_call",
      [{ to: cell, data: encodeCall(SELECTORS.getAudit, i.toString(16)) }, "latest"]);
    const words = raw.replace(/^0x/, "").match(/.{64}/g) || [];
    // SAME THRESHOLD AS readAuditRow, and it must stay same. This read `words.length < 9`
    // until 2026-08-20 while its sibling twelve lines up required > W_TARGET_CHAIN (23) —
    // two thresholds for one ABI return. A 10-to-23-word row was therefore not merely
    // skipped here, it was ACCEPTED, and words[8] read as artifactHash: a truncated row
    // could produce a false POSITIVE match, which is worse than the missing skip-count.
    if (words.length <= W_TARGET_CHAIN) { skipped++; continue; }
    scanned++;
    if ("0x" + words[W_ARTIFACT].toLowerCase() === want) {
      return { id: i.toString(), state: AUDIT_STATE[Number(BigInt("0x" + words[W_STATE]))] ?? "unknown",
               scanned, skipped, rows: Number(n) };
    }
  }
  // "NEVER AUDITED" IS A POSITIVE CLAIM AND MUST NOT BE BUILT OUT OF SILENCES.
  // The old version returned null after silently skipping any unreadable row, and the caller
  // rendered that as "no audit row anywhere carries this artifactHash — NEVER AUDITED". If
  // three rows had been unreadable the honest answer was "I could not read three rows, so I
  // do not know". That is law (2) in this file's own header — a missing entry is UNMEASURED,
  // not absent — described there as "the sharpest rule here", and broken here by its author
  // on the same day the pattern was catalogued elsewhere. Absence is now returned only when
  // every row was actually read.
  return { found: null, scanned, skipped, rows: Number(n) };
}

export { AUDIT_STATE, VERDICT, SPEC_VERSION };

// ── CLI ─────────────────────────────────────────────────────────────────────────────────
// Kept below the exported logic so the decision path can be tested with injected fixtures
// and no network. The 2026-08-20 lesson, applied on day one: fail-closed reasoning cannot
// establish that the ACCEPT path works, and a guard that only ever refuses is indistinguishable
// from a guard that works until someone checks a clean artifact.

function jsonRpc(url) {
  let id = 0;
  return async (method, params) => {
    const res = await fetch(url, {
      method: "POST",
      // One request per call and no pooled socket left behind: a kept-alive socket still closing
      // at process exit trips libuv's `UV_HANDLE_CLOSING` assertion on Windows (Node 24.3), which
      // ABORTS the process — and an abort exits 127, replacing EVERY verdict, CLEAN included, with
      // a number no consumer of the exit table was told about. Measured 2026-09-24.
      headers: { "content-type": "application/json", "connection": "close" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
    });
    if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
    const j = await res.json();
    if (j.error) throw new Error(`${method}: ${j.error.message || JSON.stringify(j.error)}`);
    return j.result;
  };
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    const name = k.slice(2);
    if (name === "deep" || name === "json") { a[name] = true; continue; }
    a[name] = argv[++i];
  }
  return a;
}

const USAGE = `dan-check — refuse to proceed unless a DAN verdict says otherwise

  node dan-check.mjs --target 0xADDR --cell 0xCELL \\
       --home-rpc <url> [--target-rpc <url>] [--deep] [--json]

  --target-rpc defaults to --home-rpc (the home-chain-first case; cross-chain is FC-1).
  --deep       distinguish "never audited" from "audited then invalidated" (walks all rows).
  --block <n|tag>   read the target's code AT THAT BLOCK instead of 'latest', so the answer is
               reproducible by anyone with an archive node. Decimal, hex (0x...) or a tag. Without
               it the claim has no time in it and cannot be re-checked later.
  --target-rpc-2 <url>  read the code from a SECOND target endpoint and refuse (exit 2) if the two
               disagree. It does not make either honest; it makes a lying or lagging one loud.

Exit codes:  0 = CLEAN (settled, adversarial window closed)
             1 = REFUSE (no reachable audit / claimed / exploited / invalidated / 7702 designator)
             2 = CANNOT VERIFY (in progress, unreadable, out of scope) — never treat as clean
`;

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.target || !a.cell || !a["home-rpc"]) { process.stderr.write(USAGE); process.exit(2); }
  const home = jsonRpc(a["home-rpc"]);
  const rpc = { home, target: a["target-rpc"] ? jsonRpc(a["target-rpc"]) : home,
                target2: a["target-rpc-2"] ? jsonRpc(a["target-rpc-2"]) : null };

  let result, refusal = null;
  try {
    result = await danCheck({
      target: a.target, cell: a.cell, rpc, keccak256: keccak256Hex, deep: !!a.deep,
      block: a.block || null,
    });
  } catch (e) {
    if (!(e instanceof Refusal)) {
      // Law (3) again: an unexpected throw is NOT a pass and NOT a fail. It is unverified.
      process.stderr.write(`CANNOT VERIFY: dan-check itself failed — ${e.stack || e}\n`);
      process.exit(2);
    }
    refusal = e;
  }

  if (a.json) {
    const payload = refusal
      ? { ...(refusal.out || {}), specVersion: SPEC_VERSION, verdict: refusal.exit === 1 ? "REFUSE" : "CANNOT_VERIFY",
          exit: refusal.exit, reason: refusal.reason, detail: refusal.detail }
      : { ...result, exit: 0 };
    process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
  } else if (refusal) {
    process.stderr.write(`\n  ${refusal.reason}\n`);
    if (refusal.detail) process.stderr.write(`  ${refusal.detail}\n`);
    process.stderr.write(`  [${SPEC_VERSION}] reports a settled on-chain verdict, never a simulation\n\n`);
  } else {
    process.stdout.write(
      `\n  CLEAN — audit #${result.auditId}, state ${result.state} (${result.verdictReason})\n` +
      `  codehash ${result.codehash}\n` +
      `  [${SPEC_VERSION}] home chain ${result.homeChainId} @ block ${result.asOfBlockHome} · ` +
      `computed ${result.computedAtUtc}\n` +
      `  A settled verdict is not a promise: the artifact remains claimable ` +
      `(AuditCell.sol:1012-1013). This is a fact as of the block above, not forever.\n\n`);
  }
  // Set, not called: process.exit() while a socket handle is still closing is the abort described
  // at jsonRpc(). With no work left the loop drains at once and the code is honoured.
  process.exitCode = refusal ? refusal.exit : 0;
}

// ENTRY GUARD — pathToFileURL, never string concatenation.
//
// This was `import.meta.url === \`file://${process.argv[1]}\`` and it NEVER MATCHED ON WINDOWS.
// process.argv[1] is `C:\\Users\\…\\dan-check.mjs`; import.meta.url is
// `file:///C:/Users/…/dan-check.mjs` — different separators, a drive letter, three slashes not
// two. So main() was never called, the CLI printed nothing, and the process EXITED 0.
//
// That is the worst failure this tool could have and the only one that is not fail-closed:
// `dan-check --target 0xEXPLOITED || exit 1` would have passed, silently, every time, on the
// operator's own platform. Every earlier "live CLI" run happened in a Linux sandbox where the
// two strings coincidentally agree, so nothing before this caught it.
//
// Found 2026-08-20 by running the documented command on Windows — after 46 unit tests, a
// 12-check live smoke against the real chain, and a review that read the file. None of them
// executed this line, because none of them invoked the file as a program on this OS.
if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
