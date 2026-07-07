import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

let n = 0;
for (const f of fs.readdirSync(root).filter((x) => x.endsWith(".html"))) {
  const p = path.join(root, f);
  let s = fs.readFileSync(p, "utf8");
  const before = s;
  s = s.replace(/your-links\.js(\?v=\d+)?/g, "your-links.js?v=5");
  s = s.replace(/docs-rail\.js(\?v=\d+)?/g, "docs-rail.js?v=5");
  s = s.replace(/membrane-rail\.js(\?v=\d+)?/g, "membrane-rail.js?v=2");
  if (s !== before) {
    fs.writeFileSync(p, s);
    n++;
  }
}
console.log("bumped script cache", n, "files");
