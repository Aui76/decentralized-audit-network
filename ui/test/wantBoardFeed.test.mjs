/** Tests for wantBoardFeed.mjs. Run: node test/wantBoardFeed.test.mjs */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildWantFeed } from "../wantBoardFeed.mjs";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const vmSrc = readFileSync(`${membraneRoot}/view-model.js`, "utf8");
const modelMatch = vmSrc.match(/window\.__MODEL\s*=\s*(\{[\s\S]*\});?\s*$/);
assert.ok(modelMatch, "view-model.js must export window.__MODEL");
const model = JSON.parse(modelMatch[1]);

let pass = 0;
let fail = 0;
const t = (name, fn) => {
  try {
    fn();
    pass++;
    console.log("  ok  " + name);
  } catch (e) {
    fail++;
    console.error("FAIL  " + name + "\n      " + e.message);
  }
};

console.log("wantBoardFeed");

t("builds at least one contract from live view-model", () => {
  const feed = buildWantFeed(model);
  assert.ok(feed.length >= 1);
  assert.ok(feed[0].contract.startsWith("0x"));
});

t("each row has required fact fields", () => {
  const feed = buildWantFeed(model);
  for (const c of feed) {
    assert.ok(typeof c.stakesUsd === "number");
    assert.ok(typeof c.holders === "number");
    assert.ok(["unaudited", "live", "passed"].includes(c.auditStatus));
    assert.ok(typeof c.riskResemblance === "number");
  }
});

t("settled InBlock target maps to passed status", () => {
  const feed = buildWantFeed(model);
  const row = feed.find((c) => c.contract.toLowerCase() === "0xed490ea0335fc99df42c3c7bc95d623dfc6b87a8");
  assert.ok(row);
  assert.equal(row.auditStatus, "passed");
});

t("extras merge without duplicating indexed targets", () => {
  const extra = "0x00000000000000000000000000000000000000ee";
  const feed = buildWantFeed(model, [{ contract: extra, name: "Extra", addedAt: 99 }]);
  assert.equal(feed.filter((c) => c.contract.toLowerCase() === extra).length, 1);
});

t("deterministic for same model", () => {
  const a = buildWantFeed(model);
  const b = buildWantFeed(model);
  assert.deepEqual(a.map((x) => x.contract), b.map((x) => x.contract));
});

console.log("\n" + pass + " passed, " + fail + " failed");
if (fail > 0) process.exit(1);
