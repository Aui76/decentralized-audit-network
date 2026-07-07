/**
 * Generate all docs HTML from RealDeal markdown.
 * Run: node scripts/sync-docs-pages.mjs
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import {
  FLOWS_ORDER,
  NOTEBOOK_BOOKS,
  STANDALONE_NOTEBOOK,
  bookHtml,
  buildLinkRegistry,
  leafHtml,
  parseReadmeDescriptions,
  parseReadmeLeafOrder,
  parseReadmeMeta,
  parseReadmeSections,
} from "./docs-manifest.mjs";
import {
  docPageFoot,
  escapeHtml,
  inlineMd,
  mdToHtml,
  pageShell,
  parseStoryMaps,
  setLinkContext,
} from "./md-lib.mjs";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const repoRoot = fileURLToPath(new URL("../../..", import.meta.url));
const bookDir = join(repoRoot, "RealDeal/book/chapters");
const notebookRoot = join(repoRoot, "RealDeal/notebook");
const outlinePath = join(repoRoot, "RealDeal/book/BOOK-OUTLINE.md");

const linkRegistry = buildLinkRegistry(repoRoot);

function writePage(filename, html) {
  writeFileSync(join(membraneRoot, filename), html, "utf8");
}

function htmlForMd(relPath, mdFile) {
  const key = `${relPath}/${mdFile}`.replace(/\\/g, "/");
  return linkRegistry.get(key) ?? null;
}

function buildCombinedForward() {
  const combined = new Map();
  for (const book of Object.values(NOTEBOOK_BOOKS)) {
    const forPath = join(notebookRoot, book.dir, "for-realdeal.md");
    if (!existsSync(forPath)) continue;
    const { forward } = parseStoryMaps(readFileSync(forPath, "utf8"));
    for (const [num, specs] of forward) {
      const existing = combined.get(num) ?? [];
      for (const s of specs) {
        const href = htmlForMd(book.dir, s.md);
        if (href && !existing.some((e) => e.href === href)) {
          existing.push({ href, label: s.label });
        }
      }
      combined.set(num, existing);
    }
  }
  return combined;
}

function buildBookBridge(chapterNum, combinedForward) {
  const links = combinedForward.get(chapterNum) ?? [];
  if (!links.length) return "";
  const items = links
    .map((l) => `<li><a href="${l.href}">${escapeHtml(l.label)}</a></li>`)
    .join("\n          ");
  return `
      <div class="doc-bridge">
        <p class="doc-bridge-lbl">Go deeper — notebook spec</p>
        <ul>
          ${items}
        </ul>
      </div>`;
}

function buildSpecStoryBridge(specMd, reverse) {
  const chapters = reverse.get(specMd) ?? [];
  if (!chapters.length) return "";
  const seen = new Set();
  const items = [];
  for (const c of chapters) {
    const href = bookHtml(c.num);
    if (seen.has(href)) continue;
    seen.add(href);
    items.push(`<li><a href="${href}">Book ch ${c.num} · ${escapeHtml(c.title)}</a></li>`);
  }
  return `
      <div class="doc-bridge doc-bridge-story">
        <p class="doc-bridge-lbl">Story context</p>
        <ul>
          ${items.join("\n          ")}
        </ul>
      </div>`;
}

function parseOutline() {
  const outline = readFileSync(outlinePath, "utf8");
  const partLabels = {};
  for (const line of outline.split("\n")) {
    const m = line.match(/^\|\s*\*\*([IVX]+)\s*—\s*([^*|]+)\*\*\s*\|\s*[\d–-]+\s*\|/);
    if (m) partLabels[m[1]] = `${m[1]} — ${m[2].trim()}`;
  }
  if (outline.match(/\|\s*\*\*Close\*\*\s*\|\s*24\s*\|/)) partLabels.Close = "Close";

  const chapters = [];
  for (const line of outline.split("\n")) {
    const m = line.match(
      /^\|\s*(\d+)\s*\|\s*\*\*([^*]+)\*\*\s*\|\s*`chapters\/(\d+-[^`]+\.md)`\s*\|\s*(\w+)\s*\|/
    );
    if (!m) continue;
    chapters.push({
      num: Number(m[1]),
      title: m[2].trim(),
      file: m[3],
      part: partLabels[m[4].trim()] ?? m[4].trim(),
      partShort: m[4].trim(),
      html: bookHtml(Number(m[1])),
    });
  }
  return chapters;
}

function generateBookChapter(ch, combinedForward) {
  const mdPath = join(bookDir, ch.file);
  if (!existsSync(mdPath)) return false;
  setLinkContext(linkRegistry, `book/chapters/${ch.file}`);
  const src = readFileSync(mdPath, "utf8");
  const { question, bodyHtml } = mdToHtml(src);
  const bridge = buildBookBridge(ch.num, combinedForward);
  const partEyebrow = ch.partShort === "Close" ? "Close" : ch.part.split(" — ")[0] ?? ch.part;
  const body = `
      <div class="doc-layer-row">
        <a href="docs-book.html" class="doc-layer doc-layer-story">The Book · ${escapeHtml(partEyebrow)}</a>
        <span class="doc-layer doc-layer-story">Story · chapter ${ch.num}</span>
      </div>
      <h1>${escapeHtml(ch.title)}</h1>
      ${question ? `<p class="doc-q">${inlineMd(question)}</p>` : ""}
      ${bridge}
      ${bodyHtml}
      ${docPageFoot([
        { href: "docs-book.html", label: "← The Book" },
        { href: "docs.html", label: "Docs" },
      ])}`;
  writePage(ch.html, pageShell({ title: `${ch.num} · ${ch.title} · The Book`, body }));
  return true;
}

function stripStoryLine(src) {
  return src.replace(/^\*\*Story:\*\*[^\n]*\n?/m, "");
}

function generateNotebookLeaf(book, mdName, reverse) {
  const htmlName = htmlForMd(book.dir, mdName);
  if (!htmlName) return false;
  const mdPath = join(notebookRoot, book.dir, mdName);
  if (!existsSync(mdPath)) {
    console.warn(`Skip missing ${book.dir}/${mdName}`);
    return false;
  }
  setLinkContext(linkRegistry, `${book.dir}/${mdName}`);
  let src = readFileSync(mdPath, "utf8");
  const bridge = buildSpecStoryBridge(mdName, reverse);
  if (bridge) src = stripStoryLine(src);
  const titleMatch = src.match(/^# (.+)$/m);
  const title = titleMatch?.[1]?.trim() ?? mdName;
  const { question, bodyHtml } = mdToHtml(src);
  const body = `
      <div class="doc-layer-row">
        <a href="${book.hub}" class="doc-layer doc-layer-spec">${escapeHtml(book.track)}</a>
        <span class="doc-layer doc-layer-spec">Spec · reader</span>
      </div>
      <h1>${escapeHtml(title)}</h1>
      ${question ? `<p class="doc-q">${inlineMd(question)}</p>` : ""}
      ${bridge}
      ${bodyHtml}
      ${docPageFoot([
        { href: book.hub, label: `← ${book.track}` },
        { href: "docs-notebook.html", label: "Notebook" },
      ])}`;
  writePage(htmlName, pageShell({ title: `${title} · ${book.track}`, body }));
  return true;
}

function generateStandalone(relPath, meta) {
  const mdPath = join(notebookRoot, relPath);
  if (!existsSync(mdPath)) return false;
  setLinkContext(linkRegistry, relPath);
  const src = readFileSync(mdPath, "utf8");
  const titleMatch = src.match(/^# (.+)$/m);
  const title = titleMatch?.[1]?.trim() ?? meta.title;
  const { question, bodyHtml } = mdToHtml(src);
  const body = `
      <div class="doc-layer-row">
        <a href="docs-notebook.html" class="doc-layer doc-layer-spec">The Notebook</a>
        <span class="doc-layer doc-layer-spec">Spec · ${escapeHtml(meta.track)}</span>
      </div>
      <h1>${escapeHtml(title)}</h1>
      ${question ? `<p class="doc-q">${inlineMd(question)}</p>` : ""}
      ${bodyHtml}
      ${docPageFoot([{ href: "docs-notebook.html", label: "← Notebook" }])}`;
  writePage(meta.html, pageShell({ title: `${title} · ${meta.track}`, body }));
  return true;
}

function generateBookIndex(chapters) {
  const parts = [
    { title: "Part I — Why &amp; what", nums: [1, 2, 3, 4] },
    { title: "Part II — Rules of the game", nums: [5, 6, 7] },
    { title: "Part III — The mechanism", nums: [8, 9, 10, 11, 12] },
    { title: "Part IV — People &amp; money", nums: [13, 14, 15, 16] },
    { title: "Part V — Philosophy &amp; edge", nums: [17, 18, 19, 20] },
    { title: "Part VI — Experience", nums: [21, 22, 23] },
    { title: "Close", nums: [24] },
  ];
  let listHtml = "";
  for (const part of parts) {
    listHtml += `
      <div class="doc-part">
        <h2>${part.title}</h2>
        <div class="list">`;
    for (const n of part.nums) {
      const ch = chapters.find((c) => c.num === n);
      if (!ch) continue;
      listHtml += `
          <a class="item" href="${ch.html}"><span><span class="act">${ch.num} · ${escapeHtml(ch.title)}</span><br><span class="who">${escapeHtml(ch.title)}</span></span><span class="arrow">→</span></a>`;
    }
    listHtml += `
        </div>
      </div>`;
  }
  const body = `
      <p class="eyebrow"><a href="docs.html">Docs</a> · <span class="doc-layer doc-layer-story">The Book</span></p>
      <h1>The Book</h1>
      <p class="lede">One front-to-back argument. Normative specs live in <a href="docs-notebook.html">The Notebook</a> — each chapter links there when you need depth.</p>
      ${listHtml}
      ${docPageFoot([
        { href: "docs.html", label: "← Docs" },
        { href: "docs-notebook.html", label: "Notebook" },
      ])}`;
  writePage("docs-book.html", pageShell({ title: "The Book · Docs", body }));
}

function generateNotebookHub(book) {
  const readmePath = join(notebookRoot, book.dir, "README.md");
  const readme = readFileSync(readmePath, "utf8");
  const meta = parseReadmeMeta(readme);
  const desc = parseReadmeDescriptions(readme);
  const sections = parseReadmeSections(readme, join(notebookRoot, book.dir));
  let listHtml = "";
  for (const sec of sections) {
    listHtml += `
      <h2>${escapeHtml(sec.title)}</h2>
      <div class="list">`;
    for (const leaf of sec.mds) {
      const html = htmlForMd(book.dir, leaf.md);
      if (!html) continue;
      const who = desc.get(leaf.md) ?? "";
      listHtml += `
        <a class="item" href="${html}"><span><span class="act">${escapeHtml(leaf.label)}</span><br><span class="who">${escapeHtml(who)}</span></span><span class="arrow">→</span></a>`;
    }
    listHtml += `
      </div>`;
  }
  const body = `
      <div class="doc-layer-row">
        <a href="docs-notebook.html" class="doc-layer doc-layer-spec">The Notebook</a>
        <span class="doc-layer doc-layer-spec">Spec book · ${escapeHtml(book.track)}</span>
      </div>
      <h1>${escapeHtml(meta.h1)}</h1>
      ${meta.question ? `<p class="doc-q">${inlineMd(meta.question)}</p>` : ""}
      ${meta.lede ? `<p class="lede">${inlineMd(meta.lede)}</p>` : ""}
      ${listHtml}
      ${docPageFoot([{ href: "docs-notebook.html", label: "← Notebook" }])}`;
  writePage(book.hub, pageShell({ title: `${book.track} · The Notebook`, body }));
}

function generateNotebookIndex() {
  const books = [
    { href: "docs-problem.html", name: "Problem", line: "Seven design constraints — why reputation-based audit fails strangers." },
    { href: "docs-mechanism.html", name: "Mechanism", line: "Binary, reproducible, self-funding settlement shape." },
    { href: "docs-participants.html", name: "Participants", line: "Roles, pool assignment (CRD), phase tags (O3)." },
    { href: "docs-economy.html", name: "The AUDIT Economy", line: "Issuance, escrow, payout — canonical money rules." },
    { href: "docs-health.html", name: "Network Health", line: "Maturity, flow, signals, contagion — advisory read model." },
    { href: "docs-flows.html", name: "Flows", line: "Lifecycle, three gates, overlays, mainnet checklist." },
    { href: "docs-integration.html", name: "Integration", line: "Organs, membrane, Bob card, scope, UI spec." },
    { href: "docs-contract.html", name: "Contract API", line: "AuditCell views and entrypoints." },
    { href: "docs-fingerprint.html", name: "Fingerprint", line: "AUDIT_RESULT_V1 encoding (LOCKED)." },
  ];
  let listHtml = "";
  for (const b of books) {
    listHtml += `
        <a class="item" href="${b.href}"><span><span class="act">${escapeHtml(b.name)}</span><br><span class="who">${escapeHtml(b.line)}</span></span><span class="arrow">→</span></a>`;
  }
  const body = `
      <p class="eyebrow"><a href="docs.html">Docs</a> · <span class="doc-layer doc-layer-spec">The Notebook</span></p>
      <h1>Notebook — spec reference</h1>
      <p class="lede">Interconnected books for integrators and readers who need procedure depth. Jump by book or topic — not a single linear read.</p>
      <p class="doc-fence">Read <a href="docs-book.html">The Book</a> first if you want the why. Open a notebook book when a story chapter sends you here — or when you are wiring against the cell.</p>
      <div class="list">
        ${listHtml}
      </div>
      ${docPageFoot([
        { href: "docs.html", label: "← Docs" },
        { href: "docs-book.html", label: "The Book" },
      ])}`;
  writePage("docs-notebook.html", pageShell({ title: "The Notebook · Docs", body }));
}

const chapters = parseOutline();
const combinedForward = buildCombinedForward();

let bookCount = 0;
for (const ch of chapters) {
  if (generateBookChapter(ch, combinedForward)) bookCount++;
}

let notebookLeafCount = 0;
for (const book of Object.values(NOTEBOOK_BOOKS)) {
  const forPath = join(notebookRoot, book.dir, "for-realdeal.md");
  const { reverse } = existsSync(forPath)
    ? parseStoryMaps(readFileSync(forPath, "utf8"))
    : { reverse: new Map() };
  const bookDirAbs = join(notebookRoot, book.dir);
  const order =
    book.slug === "flows"
      ? FLOWS_ORDER.map((md) => ({ md }))
      : parseReadmeLeafOrder(readFileSync(join(bookDirAbs, "README.md"), "utf8"), bookDirAbs);
  for (const { md } of order) {
    if (generateNotebookLeaf(book, md, reverse)) notebookLeafCount++;
  }
  generateNotebookHub(book);
}

let standaloneCount = 0;
for (const [rel, meta] of Object.entries(STANDALONE_NOTEBOOK)) {
  if (generateStandalone(rel, meta)) standaloneCount++;
}

generateBookIndex(chapters);
generateNotebookIndex();

console.log(
  `Generated ${bookCount} book chapters, ${notebookLeafCount} notebook leaves, ${standaloneCount} standalone pages, indexes updated.`
);
