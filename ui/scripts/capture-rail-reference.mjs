/**
 * Capture reference screenshots of the docs right rail (book + spec active).
 * Run: node scripts/capture-rail-reference.mjs
 * Requires local server on http://127.0.0.1:5173
 */
import { existsSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import puppeteer from "puppeteer-core";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const outDir = join(membraneRoot, "_reference");
mkdirSync(outDir, { recursive: true });

const candidates = [
  process.env.PUPPETEER_EXECUTABLE_PATH,
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
].filter(Boolean);

const executablePath = candidates.find((p) => existsSync(p));
if (!executablePath) {
  console.error("No Chrome/Edge found. Set PUPPETEER_EXECUTABLE_PATH.");
  process.exit(1);
}

const shots = [
  { url: "http://127.0.0.1:5173/docs-book-01.html", file: "docs-rail-book-ch01.png" },
  { url: "http://127.0.0.1:5173/docs-flows-gate-a.html", file: "docs-rail-spec-gate-a.png" },
  { url: "http://127.0.0.1:5173/docs-book.html", file: "docs-rail-book-hub.png" },
];

const browser = await puppeteer.launch({
  executablePath,
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
});

const page = await browser.newPage();
for (const { url, file } of shots) {
  await page.goto(url, { waitUntil: "networkidle2", timeout: 30000 });
  await page.waitForSelector("#docRail .doc-rail-block--book", { timeout: 10000 });
  const path = join(outDir, file);
  await page.screenshot({ path, fullPage: false });
  console.log(`Wrote ${path}`);
}
await browser.close();
