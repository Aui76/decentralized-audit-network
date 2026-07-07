/** Shared docs page naming — book, flows, and notebook books. */
import { existsSync, readFileSync } from "node:fs";
import { join, basename } from "node:path";

export const FLOWS_HTML = {
  "01-audit-lifecycle.md": "docs-flows-lifecycle.html",
  "02-the-door-gate-a.md": "docs-flows-gate-a.html",
  "03-vulnerability-disclosure.md": "docs-flows-vulnerability.html",
  "04-audit-mutex-policy.md": "docs-flows-mutex.html",
  "05-spec-arbiter.md": "docs-flows-spec-arbiter.html",
  "06-spec-gap.md": "docs-flows-spec-gap.html",
  "07-integrity-review.md": "docs-flows-integrity-review.html",
  "08-structural-upgrades.md": "docs-structural.html",
  "09-mainnet-gates.md": "docs-flows-mainnet-gates.html",
  "appendix-a-module-wiring.md": "docs-flows-appendix-a.html",
};

export const FLOWS_ORDER = [
  "01-audit-lifecycle.md",
  "02-the-door-gate-a.md",
  "03-vulnerability-disclosure.md",
  "04-audit-mutex-policy.md",
  "05-spec-arbiter.md",
  "06-spec-gap.md",
  "07-integrity-review.md",
  "08-structural-upgrades.md",
  "09-mainnet-gates.md",
  "appendix-a-module-wiring.md",
];

export const SPEC_STORY_ANCHOR = {
  "02-the-door-gate-a.md": "gate-a",
  "03-vulnerability-disclosure.md": "gate-c",
};

/** @type {Record<string, { hub: string, track: string, dir: string, slug: string }>} */
export const NOTEBOOK_BOOKS = {
  participants: {
    hub: "docs-participants.html",
    track: "Participants",
    dir: "3-participants/book",
    slug: "participants",
  },
  economy: {
    hub: "docs-economy.html",
    track: "The AUDIT Economy",
    dir: "4-economy/book",
    slug: "economy",
  },
  health: {
    hub: "docs-health.html",
    track: "Network Health",
    dir: "5-health/book",
    slug: "health",
  },
  flows: {
    hub: "docs-flows.html",
    track: "Flows",
    dir: "6-flows/book",
    slug: "flows",
  },
  integration: {
    hub: "docs-integration.html",
    track: "Integration",
    dir: "8-integration/book",
    slug: "integration",
  },
};

/** @type {Record<string, { html: string, track: string, title: string }>} */
export const STANDALONE_NOTEBOOK = {
  "1-problem/problem.md": { html: "docs-problem.html", track: "Problem", title: "Design constraints" },
  "2-mechanism/mechanism.md": { html: "docs-mechanism.html", track: "Mechanism", title: "Mechanism" },
  "7-contract/reference.md": { html: "docs-contract.html", track: "Contract API", title: "Contract surface" },
  "fingerprint-technical-note.md": {
    html: "docs-fingerprint.html",
    track: "Fingerprint",
    title: "Fingerprint Technical Note",
  },
};

const SKIP_README_LEAVES = new Set([
  "README.md",
  "for-realdeal.md",
  "how-to-read.md",
  "glossary.md",
  "preface.md",
]);

export function bookHtml(num) {
  return `docs-book-${String(num).padStart(2, "0")}.html`;
}

export function leafSlug(mdFile) {
  return mdFile.replace(/\.md$/, "").replace(/^\d{2}-/, "");
}

export function leafHtml(bookSlug, mdFile) {
  if (bookSlug === "flows" && FLOWS_HTML[mdFile]) return FLOWS_HTML[mdFile];
  return `docs-${bookSlug}-${leafSlug(mdFile)}.html`;
}

export function isSpecLeafMd(file) {
  if (SKIP_README_LEAVES.has(file)) return false;
  return /^(\d{2}-|appendix-|adaptive-)/.test(file);
}

export function parseReadmeLeafOrder(readme, bookDirAbs) {
  const order = [];
  const seen = new Set();
  const re = /\[([^\]]+)\]\(([^)]+\.md)\)/g;
  let m;
  while ((m = re.exec(readme)) !== null) {
    const file = basename(m[2]);
    if (!isSpecLeafMd(file)) continue;
    if (bookDirAbs && !existsSync(join(bookDirAbs, file))) continue;
    if (seen.has(file)) continue;
    seen.add(file);
    order.push({ md: file, label: m[1].trim() });
  }
  return order;
}

export function parseReadmeSections(readme, bookDirAbs) {
  const sections = [];
  let current = null;
  for (const line of readme.split("\n")) {
    if (line.startsWith("## ")) {
      current = { title: line.slice(3).trim(), mds: [] };
      sections.push(current);
      continue;
    }
    if (!current) continue;
    if (!line.trim().startsWith("|")) continue;
    const re = /\[([^\]]+)\]\(([^)]+\.md)\)/g;
    let m;
    while ((m = re.exec(line)) !== null) {
      const file = basename(m[2]);
      if (!isSpecLeafMd(file)) continue;
      if (bookDirAbs && !existsSync(join(bookDirAbs, file))) continue;
      if (!current.mds.some((e) => e.md === file)) {
        current.mds.push({ md: file, label: m[1].trim() });
      }
    }
  }
  return sections.filter(
    (s) =>
      s.mds.length > 0 &&
      !/^Front matter$/i.test(s.title) &&
      !/^What lives here vs elsewhere$/i.test(s.title)
  );
}

export function parseReadmeMeta(readme) {
  const h1 = readme.match(/^# (.+)$/m)?.[1]?.trim() ?? "";
  let question = "";
  let lede = "";
  for (const line of readme.split("\n")) {
    const t = line.trim();
    if (/^\*\*Question this doc answers:\*\*/i.test(t)) {
      question = t
        .replace(/^\*\*Question this doc answers:\*\*\s*/i, "")
        .replace(/\*\*/g, "")
        .trim();
    }
    if (!lede && t && !t.startsWith("#") && !t.startsWith("**") && !t.startsWith("|") && t !== "---") {
      if (!/^Audience:/i.test(t) && !/^Book readers:/i.test(t) && !/^RealDeal readers:/i.test(t) && !/^Notebook redirects/i.test(t)) {
        lede = t;
        break;
      }
    }
  }
  return { h1, question, lede };
}

export function parseReadmeDescriptions(readme) {
  const desc = new Map();
  for (const line of readme.split("\n")) {
    if (!line.trim().startsWith("|")) continue;
    const cells = line.split("|").map((c) => c.trim()).filter(Boolean);
    if (cells.length < 2) continue;
    for (const cell of cells) {
      const m = cell.match(/^\[([^\]]+)\]\(([^)]+\.md)\)$/);
      if (!m) continue;
      const md = basename(m[2]);
      const nextIdx = cells.indexOf(cell) + 1;
      if (nextIdx < cells.length && isSpecLeafMd(md)) {
        desc.set(md, cells[nextIdx]);
      }
    }
  }
  return desc;
}

export function buildLinkRegistry(repoRoot) {
  /** @type {Map<string, string>} */
  const byPath = new Map();

  function add(key, html) {
    byPath.set(key.replace(/\\/g, "/"), html);
  }

  const outline = readFileSync(join(repoRoot, "RealDeal/book/BOOK-OUTLINE.md"), "utf8");
  for (const line of outline.split("\n")) {
    const m = line.match(/^\|\s*(\d+)\s*\|\s*\*\*[^*]+\*\*\s*\|\s*`chapters\/(\d+-[^`]+\.md)`\s*\|/);
    if (m) add(`book/chapters/${m[2]}`, bookHtml(Number(m[1])));
  }

  for (const book of Object.values(NOTEBOOK_BOOKS)) {
    const readmePath = join(repoRoot, "RealDeal/notebook", book.dir, "README.md");
    if (!existsSync(readmePath)) continue;
    const readme = readFileSync(readmePath, "utf8");
    const order =
      book.slug === "flows" ? FLOWS_ORDER.map((md) => ({ md })) : parseReadmeLeafOrder(readme, join(repoRoot, "RealDeal/notebook", book.dir));
    for (const { md } of order) {
      add(`${book.dir}/${md}`, leafHtml(book.slug, md));
    }
  }

  for (const [rel, meta] of Object.entries(STANDALONE_NOTEBOOK)) {
    add(rel, meta.html);
  }

  return byPath;
}

export function resolveMdHref(href, fromRelPath, registry) {
  if (!href || href.startsWith("http")) return href || null;
  const [pathPart, hash] = href.split("#");
  const fromDir = fromRelPath.includes("/") ? fromRelPath.replace(/\/[^/]+$/, "") : "";
  const normalized = join(fromDir, pathPart).replace(/\\/g, "/");
  const candidates = [
    normalized,
    normalized.replace(/^(\.\.\/)+/, ""),
    basename(pathPart),
  ];
  for (const key of candidates) {
    for (const [regKey, html] of registry.entries()) {
      if (regKey === key || regKey.endsWith(`/${key}`) || regKey.endsWith(`/${basename(key)}`)) {
        return hash ? `${html}#${hash}` : html;
      }
    }
  }
  const base = basename(pathPart);
  for (const [regKey, html] of registry.entries()) {
    if (regKey.endsWith(`/${base}`)) return hash ? `${html}#${hash}` : html;
  }
  return null;
}
