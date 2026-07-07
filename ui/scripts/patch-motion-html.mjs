/** One-shot: bump CSS + add motion.js to manual HTML pages. */
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
let n = 0;

for (const name of readdirSync(root).filter((f) => f.endsWith(".html"))) {
  const path = join(root, name);
  let html = readFileSync(path, "utf8");
  const before = html;
  html = html.replaceAll("site.css?v=4", "site.css?v=5");
  html = html.replaceAll('href="site.css"', 'href="site.css?v=5"');
  html = html.replaceAll("docs-rail.js?v=6", "docs-rail.js?v=7");
  if (!html.includes("motion.js") && html.includes("</body>")) {
    html = html.replace("</body>", '<script src="motion.js?v=1"></script>\n</body>');
  }
  if (html !== before) {
    writeFileSync(path, html, "utf8");
    n++;
  }
}

console.log(`Patched ${n} HTML files.`);
