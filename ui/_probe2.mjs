import fs from "fs";
global.window = {};
eval(fs.readFileSync("view-model.js","utf8"));           // window.__MODEL
eval(fs.readFileSync("want-board-engine.js","utf8"));    // window.buildWantFeed, deriveWantBoard
const feed = window.buildWantFeed(window.__MODEL);
const all  = window.deriveWantBoard({ contracts: feed });
const risky= window.deriveWantBoard({ contracts: feed, filter:{ risk:true } });
console.log("BUNDLE — total:", all.length, "| risk-filtered:", risky.length);
console.log("BUNDLE — riskResemblance values:", feed.map(c=>c.riskResemblance).join(","));
