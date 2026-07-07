import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const tag = '<script src="your-links.js"></script>\n';

let n = 0;
for (const f of fs.readdirSync(root).filter((x) => x.endsWith(".html"))) {
  const p = path.join(root, f);
  let s = fs.readFileSync(p, "utf8");
  if (!s.includes("docs-rail.js") || s.includes("your-links.js")) continue;
  s = s.replace('<script src="docs-rail.js"></script>', tag + '<script src="docs-rail.js"></script>');
  fs.writeFileSync(p, s);
  n++;
  console.log("patched", f);
}
console.log("total", n);
