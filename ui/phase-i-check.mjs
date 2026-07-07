#!/usr/bin/env node
// Phase I gate — refresh indexer + assert membrane read model matches live cell.
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const depPath = join(here, "../deployments/84532-cell.json");
const vmPath = join(here, "view-model.json");

function fail(msg) {
  console.error("FAIL:", msg);
  process.exit(1);
}

if (!existsSync(depPath)) fail("missing ../deployments/84532-cell.json");

const dep = JSON.parse(readFileSync(depPath, "utf8"));
const cell = dep.AuditCell;
if (!cell) fail("deployment missing AuditCell");

console.log("Running membrane indexer…");
const idx = spawnSync(process.execPath, ["indexer.mjs"], { cwd: here, stdio: "inherit", env: { ...process.env, AUDIT_CELL: cell } });
if (idx.status !== 0) fail("indexer.mjs exited " + idx.status);

const vm = JSON.parse(readFileSync(vmPath, "utf8"));
const m = vm.meta;

if (m.cell?.toLowerCase() !== cell.toLowerCase()) fail(`view-model cell mismatch: ${m.cell} vs ${cell}`);
if (m.audits < 11) fail(`expected >= 11 audits, got ${m.audits}`);
if (!m.rollout?.m1Complete || !m.rollout?.m2Complete) fail("rollout flags missing in view-model");
if (!m.withdrawCreditsTool?.canonical) fail("withdraw-credits tool not canonical in view-model");
if (!m.latestBlockHash) fail("latestBlockHash empty");
if (!m.networkTimeline?.some((e) => e.label === "CAN mint")) fail("no CAN mint in networkTimeline");

const a1 = vm.audits.find((a) => a.id === dep.phaseCAuditId);
if (!a1 || a1.state !== "InBlock") fail("phase C audit not InBlock");

const aD = vm.audits.find((a) => a.id === dep.phaseDAuditId);
if (!aD) fail("phase D audit missing");
if (!aD.claim && aD.state !== "Exploited") fail("phase D audit missing claim/exploit evidence");

const aH = vm.audits.find((a) => a.id === dep.phaseHCanonAuditId);
if (!aH || aH.state !== "InBlock") fail("phase H canon audit not InBlock");

console.log("PASS Phase I membrane check");
console.log(`  cell ${m.cell}`);
console.log(`  audits ${m.audits} · claimable ${m.claimableCount} · positiveBlocks ${m.positiveBlocks}`);
console.log(`  tool canonical · uses ${m.withdrawCreditsTool.successfulUses} · CAN events ${m.networkTimeline.length}`);
