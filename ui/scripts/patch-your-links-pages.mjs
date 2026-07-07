import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const inject =
  '\n<script src="your-links.js"></script>\n<script src="membrane-rail.js"></script>\n';

let n = 0;
for (const f of fs.readdirSync(root).filter((x) => x.endsWith(".html"))) {
  const p = path.join(root, f);
  let s = fs.readFileSync(p, "utf8");
  if (s.includes("your-links.js") || s.includes("docs-rail.js")) continue;
  if (!s.includes("layout-docs") && !s.includes("layout-tool")) continue;
  if (!s.includes("</body>")) continue;
  s = s.replace("</body>", inject + "</body>");
  fs.writeFileSync(p, s);
  n++;
  console.log("patched", f);
}
console.log("total", n);
