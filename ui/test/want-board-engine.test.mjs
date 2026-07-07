/** Bundle smoke test for want-board-engine.js. Run via npm run test:want-board */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const bundleSrc = readFileSync(`${membraneRoot}/want-board-engine.js`, "utf8");
assert.doesNotThrow(() => new Function(bundleSrc), "want-board-engine.js must parse in browser");
const sandbox = { window: {}, global: {} };
sandbox.global = sandbox.window;
vm.runInNewContext(bundleSrc, sandbox);
assert.equal(typeof sandbox.window.deriveWantBoard, "function");
assert.equal(typeof sandbox.window.buildWantFeed, "function");
assert.equal(typeof sandbox.window.buildWantTypedData, "function");
assert.equal(typeof sandbox.window.verifyWant, "function");
console.log("want-board-engine.test.mjs: all assertions passed");
