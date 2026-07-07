/**
 * Emit docs-nav.json from RealDeal book outline + notebook book order.
 * Run: node scripts/build-docs-nav.mjs
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import {
  FLOWS_HTML,
  NOTEBOOK_BOOKS,
  STANDALONE_NOTEBOOK,
  SPEC_STORY_ANCHOR,
  bookHtml,
  buildLinkRegistry,
  parseReadmeSections,
} from "./docs-manifest.mjs";

const membraneRoot = fileURLToPath(new URL("..", import.meta.url));
const repoRoot = fileURLToPath(new URL("../../..", import.meta.url));
const bookOutlinePath = join(repoRoot, "RealDeal/book/BOOK-OUTLINE.md");
const notebookRoot = join(repoRoot, "RealDeal/notebook");
const outPath = join(membraneRoot, "docs-nav.json");

function htmlExists(name) {
  return existsSync(join(membraneRoot, name));
}

function parsePartLabels(outline) {
  const labels = {};
  for (const line of outline.split("\n")) {
    const m = line.match(/^\|\s*\*\*([IVX]+)\s*—\s*([^*|]+)\*\*\s*\|\s*[\d–-]+\s*\|/);
    if (m) labels[m[1]] = `${m[1]} — ${m[2].trim()}`;
  }
  const labelsClose = outline.match(/\|\s*\*\*Close\*\*\s*\|\s*24\s*\|\s*([^|]+)\s*\|/);
  if (labelsClose) labels.Close = `Close — ${labelsClose[1].trim()}`;
  return labels;
}

function parseBookChapters(outline) {
  const partLabels = parsePartLabels(outline);
  const chapters = [];
  for (const line of outline.split("\n")) {
    const m = line.match(
      /^\|\s*(\d+)\s*\|\s*\*\*([^*]+)\*\*\s*\|\s*`chapters\/(\d+-[^`]+\.md)`\s*\|\s*(\w+)\s*\|/
    );
    if (!m) continue;
    const num = Number(m[1]);
    chapters.push({
      num,
      title: m[2].trim(),
      part: partLabels[m[4].trim()] ?? m[4].trim(),
      html: bookHtml(num),
    });
  }
  return chapters;
}

function parseStoryLinks(forRealdealPath, bookHtmlByNum, specHtmlByMd, labelByHtml, specsByBookHtml) {
  const forRealdeal = readFileSync(forRealdealPath, "utf8");
  /** @type {Map<string, { num: number, title: string }[]>} */
  const bySpec = new Map();
  for (const line of forRealdeal.split("\n")) {
    if (!line.startsWith("| [")) continue;
    const row = line.match(/^\|\s*\[(\d+)\s*—\s*([^\]]+)\]\([^)]+\)\s*\|\s*(.+?)\s*\|$/);
    if (!row) continue;
    const chapterNum = Number(row[1]);
    const chapterTitle = row[2].trim();
    const cell = row[3];
    const specRe = /\[([^\]]+)\]\(([^)]+\.md)(#[^)]*)?\)/g;
    let sm;
    while ((sm = specRe.exec(cell)) !== null) {
      const md = sm[2].split("/").pop();
      if (!bySpec.has(md)) bySpec.set(md, []);
      bySpec.get(md).push({ num: chapterNum, title: chapterTitle });
    }
  }

  /** @type {Record<string, { href: string, label: string }>} */
  const story = {};
  for (const [md, chapters] of bySpec) {
    const html = specHtmlByMd.get(md);
    if (!html || !htmlExists(html)) continue;
    const sorted = [...chapters].sort((a, b) => {
      const a6 = a.num === 6 ? 0 : 1;
      const b6 = b.num === 6 ? 0 : 1;
      if (a6 !== b6) return a6 - b6;
      return a.num - b.num;
    });
    const pick = sorted.find((c) => bookHtmlByNum.has(c.num));
    if (!pick) continue;
    const bookPage = bookHtmlByNum.get(pick.num);
    const anchor = SPEC_STORY_ANCHOR[md];
    story[html] = {
      href: anchor ? `${bookPage}#${anchor}` : bookPage,
      label: `Ch ${pick.num} · ${pick.title}`,
    };

    if (!specsByBookHtml[bookPage]) specsByBookHtml[bookPage] = [];
    const specLabel = labelByHtml.get(html) ?? md;
    if (!specsByBookHtml[bookPage].some((s) => s.href === html)) {
      specsByBookHtml[bookPage].push({ href: html, label: specLabel });
    }
  }
  return story;
}

function neighbour(items, index, dir) {
  for (let i = index + dir; dir > 0 ? i < items.length : i >= 0; i += dir) {
    if (htmlExists(items[i].html)) return items[i];
  }
  return null;
}

function leafHtmlFor(book, md, registry) {
  if (book.slug === "flows" && FLOWS_HTML[md]) return FLOWS_HTML[md];
  return registry.get(`${book.dir}/${md}`);
}

/** Ordered spec leaves with README section (part) labels. */
function leavesFromSections(book, readme, bookDirAbs, registry) {
  const sections = parseReadmeSections(readme, bookDirAbs);
  const leaves = [];
  for (const sec of sections) {
    for (const { md, label } of sec.mds) {
      const html = leafHtmlFor(book, md, registry);
      if (!html || !htmlExists(html)) continue;
      leaves.push({ md, label, html, part: sec.title });
    }
  }
  return leaves;
}

function buildManifest() {
  const outline = readFileSync(bookOutlinePath, "utf8");
  const registry = buildLinkRegistry(repoRoot);

  const chapters = parseBookChapters(outline);
  const total = chapters.length;
  const bookHtmlByNum = new Map(
    chapters.filter((c) => htmlExists(c.html)).map((c) => [c.num, c.html])
  );

  /** @type {Record<string, object>} */
  const manifest = {};
  /** @type {Record<string, { href: string, label: string }[]>} */
  const specsByBookHtml = {};

  chapters.forEach((ch, i) => {
    if (!htmlExists(ch.html)) return;
    const entry = {
      track: "book",
      hub: "docs-book.html",
      title: ch.title,
      part: ch.part,
      pos: ch.num,
      total,
    };
    const prev = neighbour(chapters, i, -1);
    const next = neighbour(chapters, i, 1);
    if (prev) {
      entry.prev = prev.html;
      entry.prevLabel = prev.title;
    }
    if (next) {
      entry.next = next.html;
      entry.nextLabel = next.title;
    }
    manifest[ch.html] = entry;
  });

  for (const book of Object.values(NOTEBOOK_BOOKS)) {
    const readmePath = join(notebookRoot, book.dir, "README.md");
    const forPath = join(notebookRoot, book.dir, "for-realdeal.md");
    if (!existsSync(readmePath)) continue;

    const readme = readFileSync(readmePath, "utf8");
    const bookDirAbs = join(notebookRoot, book.dir);
    const leaves = leavesFromSections(book, readme, bookDirAbs, registry);

    const specHtmlByMd = new Map(leaves.map((l) => [l.md, l.html]));
    const labelByHtml = new Map(leaves.map((l) => [l.html, l.label]));
    const storyByHtml = existsSync(forPath)
      ? parseStoryLinks(forPath, bookHtmlByNum, specHtmlByMd, labelByHtml, specsByBookHtml)
      : {};

    const partTotals = new Map();
    for (const leaf of leaves) {
      partTotals.set(leaf.part, (partTotals.get(leaf.part) ?? 0) + 1);
    }
    const partPos = new Map();

    leaves.forEach((leaf, i) => {
      const idxInPart = (partPos.get(leaf.part) ?? 0) + 1;
      partPos.set(leaf.part, idxInPart);

      const entry = {
        track: "spec",
        book: book.track,
        hub: book.hub,
        part: leaf.part,
        partPos: idxInPart,
        partTotal: partTotals.get(leaf.part),
        pos: i + 1,
        total: leaves.length,
      };

      const prev = leaves[i - 1];
      const next = leaves[i + 1];
      if (prev) {
        entry.prev = prev.html;
        entry.prevLabel = prev.label;
        if (prev.part !== leaf.part) entry.prevPart = prev.part;
      }
      if (next) {
        entry.next = next.html;
        entry.nextLabel = next.label;
        if (next.part !== leaf.part) entry.nextPart = next.part;
      }

      const story = storyByHtml[leaf.html];
      if (story) {
        entry.story = story.href;
        entry.storyLabel = story.label;
      }
      manifest[leaf.html] = entry;
    });
  }

  for (const meta of Object.values(STANDALONE_NOTEBOOK)) {
    if (!htmlExists(meta.html)) continue;
    manifest[meta.html] = {
      track: "spec",
      book: meta.track,
      hub: "docs-notebook.html",
    };
  }

  if (htmlExists("docs-book.html")) {
    manifest["docs-book.html"] = { track: "book", isHub: true };
  }
  if (htmlExists("docs-notebook.html")) {
    manifest["docs-notebook.html"] = {
      track: "spec",
      book: "The Notebook",
      hub: "docs-notebook.html",
      isHub: true,
    };
  }
  if (htmlExists("docs.html")) {
    manifest["docs.html"] = { track: "docs" };
  }
  for (const book of Object.values(NOTEBOOK_BOOKS)) {
    if (!htmlExists(book.hub)) continue;
    manifest[book.hub] = {
      track: "spec",
      book: book.track,
      hub: book.hub,
      isHub: true,
    };
  }

  for (const [bookHtml, specs] of Object.entries(specsByBookHtml)) {
    if (manifest[bookHtml] && specs.length) {
      manifest[bookHtml].relatedSpecs = specs;
    }
  }

  return manifest;
}

const manifest = buildManifest();
writeFileSync(outPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
console.log(`Wrote ${outPath} (${Object.keys(manifest).length} pages)`);
