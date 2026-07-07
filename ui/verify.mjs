#!/usr/bin/env node
// Cross-platform audit verifier — zero dependencies, any OS, just `node`.
//   node verify.mjs <auditId> [--rpc <url>] [--cell <addr>] [--target <addr>]
//
// What it proves, independently of us:
//   1. self-test: recomputes toolId / specHash / contextRoot and checks them against the
//      published canonical values (proves this script's AUDIT_RESULT_V1 encoding is correct);
//   2. fetches the audit target's LIVE bytecode -> artifactHash (real on-chain object O);
//   3. recomputes the PASS and FAIL resultRoots for that real bytecode;
//   4. fetches the cell's on-chain auditProofHash(id) and reports which verdict it encodes.
// If the on-chain root equals our recomputed root, the settled verdict is the honest encoding
// of [PASS|FAIL] on the *real deployed bytecode* under the canonical spec+tool — no trust in us.
//
// Honest limit: this re-derives the ENCODING + binding, not the EVM execution. Re-running the
// fixture to independently re-derive the verdict (Level B) needs an EVM fork — see README.
//
// No PowerShell, no foundry, no clone of ../cell. Verify needs no wallet and no stake.
//
// Encoding + reproduction core: verify-core.mjs (ONE TRUTH — shared with the in-tab
// "Reproduce it now" button via verify-browser.mjs; do not fork the encoding here).

import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { selfTestRows, reproduce } from "./verify-core.mjs";

// ---------- self-test ----------
function selfTest(){
  const rows=selfTestRows();
  let ok=true;
  console.log("Self-test (encoding correctness):");
  for(const r of rows){ok=ok&&r.ok;console.log("  "+r.name.padEnd(11),r.ok?"MATCH ✓":"MISMATCH ✗   got "+r.got);}
  if(!ok){console.error("ENCODING SELF-TEST FAILED — do not trust results.");process.exit(2);}
  return ok;
}

// ---------- main ----------
const args=process.argv.slice(2);
const opt=(f,d)=>{const i=args.indexOf(f);return i>=0?args[i+1]:d;};
const auditId=args.find(a=>/^\d+$/.test(a));
selfTest();
if(auditId===undefined){console.log("\nUsage: node verify.mjs <auditId> [--rpc <url>] [--cell <addr>] [--target <addr>]");process.exit(0);}

// load cell from deployment JSON (live) or view-model fallback
function loadCellDefault() {
  const paths = ["../deployments/84532-cell.json"];
  for (const rel of paths) {
    try {
      const p = join(dirname(fileURLToPath(import.meta.url)), rel);
      const d = JSON.parse(readFileSync(p, "utf8"));
      if (d?.AuditCell) return d.AuditCell;
    } catch {}
  }
  return null;
}
let vm=null;
try{const here=dirname(fileURLToPath(import.meta.url));vm=JSON.parse(readFileSync(join(here,"view-model.json"),"utf8"));}catch{}
const cell=opt("--cell", loadCellDefault() || vm?.meta?.cell || "0xB8BFC2dd2CDFF79e018479C8a97B6AeC1979ff6d");
const rpcUrl=opt("--rpc", "https://sepolia.base.org");
const row=vm?.audits?.find(a=>String(a.id)===auditId);
const target=opt("--target", row?.target);
if(!target){console.error("No target for audit "+auditId+" — pass --target <addr> or place view-model.json next to this script.");process.exit(1);}

(async()=>{
  console.log("\nVerifying audit #"+auditId+"  (cell "+cell+", rpc "+rpcUrl+")");
  const r=await reproduce({rpcUrl,cell,auditId,target});
  if(!r.ok){console.error(r.error||("failed at "+r.stage));process.exit(1);}
  console.log("  target O           ",r.target);
  console.log("  artifactHash (live)",r.artifactHash);
  console.log("  root if PASS       ",r.rootPASS);
  console.log("  root if FAIL       ",r.rootFAIL);
  console.log("  on-chain root      ",r.onchain);
  if(r.verdict) console.log("\n  VERIFIED ✓  on-chain root = honest "+r.verdict+" encoding of the REAL deployed bytecode under the canonical spec+tool.");
  else console.log("\n  MISMATCH ✗  on-chain root binds neither PASS nor FAIL of this bytecode/spec — investigate (wrong target, non-standard FAIL post, tampering, or a non-withdraw-credits tool).");
})().catch(e=>{console.error("\nRPC error:",e.message);process.exit(1);});
