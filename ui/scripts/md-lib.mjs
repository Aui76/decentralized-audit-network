/**
 * Markdown → HTML subset for RealDeal docs presentation layer.
 */
import { resolveMdHref } from "./docs-manifest.mjs";

const ANCHOR_ALIASES = {
  "the-door-gate-a": "gate-a",
  "the-challenge-gate-c": "gate-c",
  "three-questions-not-three-committees": "three-questions",
};

/** @type {Map<string, string>} */
let linkRegistry = new Map();
/** @type {string} */
let linkContext = "";

export function setLinkContext(registry, fromRelPath = "") {
  linkRegistry = registry;
  linkContext = fromRelPath.replace(/\\/g, "/");
}

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function slugifyHeading(text) {
  const gate = text.match(/\(Gate ([ABC])\)/i);
  if (gate) return `gate-${gate[1].toLowerCase()}`;
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .slice(0, 56);
}

function headingId(explicit, text) {
  if (explicit && ANCHOR_ALIASES[explicit]) return ANCHOR_ALIASES[explicit];
  if (explicit) return explicit;
  return slugifyHeading(text);
}

function resolveHref(href) {
  return resolveMdHref(href, linkContext, linkRegistry);
}

function externalLinkLabel(url) {
  try {
    const u = new URL(url);
    if (/basescan/i.test(u.hostname)) return "Basescan ↗";
    return `${u.hostname.replace(/^www\./, "")} ↗`;
  } catch {
    return "Link ↗";
  }
}

/** End-of-page nav footer — one style site-wide. */
export function docPageFoot(links) {
  const inner = links
    .map(({ href, label }) => `<a href="${escapeHtml(href)}">${escapeHtml(label)}</a>`)
    .join(" · ");
  return `\n      <footer class="doc-page-foot">${inner}</footer>`;
}

export function normalizeBookLabels(text) {
  return String(text)
    .replace(/RealDeal ch\./gi, "Book ch ")
    .replace(/RealDeal book/gi, "The Book")
    .replace(/RealDeal readers/gi, "Book readers")
    .replace(/RealDeal — read the book/gi, "The Book");
}

export function formatText(text) {
  const re = /(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)/g;
  let out = "";
  let last = 0;
  let m;
  const normalized = normalizeBookLabels(text);
  while ((m = re.exec(normalized))) {
    if (m.index > last) out += escapeHtml(normalized.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith("**")) out += `<strong>${escapeHtml(tok.slice(2, -2))}</strong>`;
    else if (tok.startsWith("*")) out += `<em>${escapeHtml(tok.slice(1, -1))}</em>`;
    else if (tok.startsWith("`")) out += `<code>${escapeHtml(tok.slice(1, -1))}</code>`;
    last = m.index + tok.length;
  }
  if (last < normalized.length) out += escapeHtml(normalized.slice(last));
  return out;
}

export function inlineMd(text) {
  const normalized = normalizeBookLabels(text);
  const re = /\[[^\]]+\]\([^)]+\)/g;
  let out = "";
  let last = 0;
  let m;
  while ((m = re.exec(normalized))) {
    if (m.index > last) out += formatText(normalized.slice(last, m.index));
    const tok = m[0];
    const lm = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (lm) {
      const href = resolveHref(lm[2]);
      const rawLabel = lm[1];
      const label = formatText(rawLabel);
      if (!href) out += label;
      else if (/^https?:\/\//i.test(href)) {
        const display = /^https?:\/\//i.test(rawLabel.trim()) ? externalLinkLabel(href) : label;
        out += `<a href="${escapeHtml(href)}" target="_blank" rel="noopener">${display}</a>`;
      } else out += `<a href="${escapeHtml(href)}">${label}</a>`;
    } else {
      out += formatText(tok);
    }
    last = m.index + tok.length;
  }
  if (last < normalized.length) out += formatText(normalized.slice(last));
  return out;
}

function parseTableRow(line) {
  return line
    .split("|")
    .slice(1, -1)
    .map((c) => c.trim());
}

function isTableRow(line) {
  return line.trim().startsWith("|");
}

function isTableSep(line) {
  return /^\|\s*[-:]+/.test(line.trim());
}

export function mdToHtml(src, { stopAtRelated = true } = {}) {
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  let i = 0;
  let question = "";
  let pendingAnchor = "";
  const blocks = [];

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    if (stopAtRelated && (trimmed === "## Related" || /^(\*\*)?Previous chapter:/i.test(trimmed))) break;
    if (trimmed.startsWith("# ") && i < 3) {
      i++;
      continue;
    }
    if (trimmed.startsWith("> ") || trimmed === "---" || /^(\*\*)?Audience:/i.test(trimmed)) {
      i++;
      continue;
    }
    if (/^\*\*Question this (chapter|doc) answers:\*\*/i.test(trimmed)) {
      question = trimmed
        .replace(/^\*\*Question this (chapter|doc) answers:\*\*\s*/i, "")
        .replace(/^\*\*|\*\*$/g, "");
      i++;
      continue;
    }

    const anchorMatch = trimmed.match(/^<a id="([^"]+)"><\/a>$/);
    if (anchorMatch) {
      pendingAnchor = anchorMatch[1];
      i++;
      continue;
    }

    if (trimmed.startsWith("## ")) {
      const title = trimmed.slice(3).trim();
      const id = headingId(pendingAnchor, title);
      pendingAnchor = "";
      blocks.push(`<h2 id="${escapeHtml(id)}">${inlineMd(title)}</h2>`);
      i++;
      continue;
    }

    if (trimmed.startsWith("### ")) {
      blocks.push(`<h3>${inlineMd(trimmed.slice(4).trim())}</h3>`);
      i++;
      continue;
    }

    if (trimmed.startsWith("```")) {
      i++;
      const codeLines = [];
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        codeLines.push(lines[i]);
        i++;
      }
      i++;
      blocks.push(`<pre class="mono doc-pre">${escapeHtml(codeLines.join("\n"))}</pre>`);
      continue;
    }

    if (isTableRow(trimmed)) {
      const tableLines = [];
      while (i < lines.length && isTableRow(lines[i].trim())) {
        tableLines.push(lines[i]);
        i++;
      }
      const rows = tableLines.filter((l) => !isTableSep(l.trim())).map(parseTableRow);
      if (rows.length) {
        const [head, ...body] = rows;
        let html = '<table class="doc-table"><thead><tr>';
        for (const cell of head) html += `<th>${inlineMd(cell)}</th>`;
        html += "</tr></thead><tbody>";
        for (const row of body) {
          html += "<tr>";
          for (const cell of row) html += `<td>${inlineMd(cell)}</td>`;
          html += "</tr>";
        }
        html += "</tbody></table>";
        blocks.push(html);
      }
      continue;
    }

    if (/^[-*] /.test(trimmed)) {
      const items = [];
      while (i < lines.length && /^[-*] /.test(lines[i].trim())) {
        items.push(lines[i].trim().replace(/^[-*] /, ""));
        i++;
      }
      blocks.push(`<ul>${items.map((it) => `<li>${inlineMd(it)}</li>`).join("")}</ul>`);
      continue;
    }

    if (/^\d+\. /.test(trimmed)) {
      const items = [];
      while (i < lines.length && /^\d+\. /.test(lines[i].trim())) {
        items.push(lines[i].trim().replace(/^\d+\. /, ""));
        i++;
      }
      blocks.push(`<ol>${items.map((it) => `<li>${inlineMd(it)}</li>`).join("")}</ol>`);
      continue;
    }

    if (!trimmed) {
      i++;
      continue;
    }

    blocks.push(`<p>${inlineMd(trimmed)}</p>`);
    i++;
  }

  return { question, bodyHtml: blocks.join("\n      ") };
}

export function parseStoryMaps(text) {
  const forward = new Map();
  const reverse = new Map();
  for (const line of text.split("\n")) {
    if (!line.startsWith("| [")) continue;
    const row = line.match(/^\|\s*\[(\d+)\s*—\s*([^\]]+)\]\([^)]+\)\s*\|\s*(.+?)\s*\|$/);
    if (!row) continue;
    const num = Number(row[1]);
    const chapterTitle = row[2].trim();
    const specs = [];
    const re = /\[([^\]]+)\]\(([^)]+\.md)(#[^)]*)?\)/g;
    let sm;
    while ((sm = re.exec(row[3])) !== null) {
      const md = sm[2].split("/").pop();
      specs.push({ md, label: sm[1].trim() });
      if (!reverse.has(md)) reverse.set(md, []);
      reverse.get(md).push({ num, title: chapterTitle });
    }
    if (specs.length) forward.set(num, [...(forward.get(num) ?? []), ...specs]);
  }
  return { forward, reverse };
}

export function pageShell({ title, body }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>!function(){try{var k="membrane_nav_session",s=sessionStorage.getItem(k);document.documentElement.classList.add(s?"nav-session":"cold-load");if(!s)sessionStorage.setItem(k,"1")}catch(e){}}();</script>
<title>${escapeHtml(title)} · Audit Cell</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="site.css?v=5">
</head>
<body class="page-prose">
<div class="layout layout-docs">

  <nav>
    <div class="brand"><span class="dot"></span> Audit Cell</div>
    <a class="navlink" href="index.html">Welcome</a>
    <a class="navlink" href="quickstart.html">Quickstart</a>
    <a class="navlink on" href="resources.html">Resources</a>
    <a class="navlink" href="help.html">Help</a>
  </nav>

  <main>
    <div class="inner">
${body}
    </div>
  </main>

  <aside id="docRail" aria-label="You are here" hidden></aside>

</div>
<script src="motion.js?v=1"></script>
<script src="your-links.js?v=4"></script>
<script src="docs-rail.js?v=7"></script>
</body>
</html>
`;
}
