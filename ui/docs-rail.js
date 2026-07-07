/**
 * Docs right panel — two rails: The Book (green) + Notebook spec (blue).
 * Active rail lights up for the track you are reading; the other stays dimmed
 * and keeps its last snapshot when you switch book ↔ notebook.
 * Driven by docs-nav.json (see scripts/build-docs-nav.mjs).
 */
(function () {
  const BOOK_HUB = "docs-book.html";
  const NOTEBOOK_HUB = "docs-notebook.html";
  const DOCS_HUB = "docs.html";
  const BOOK_SNAP = "docRailBookSnap";
  const SPEC_SNAP = "docRailSpecSnap";

  const rail = document.getElementById("docRail");
  const layout = document.querySelector(".layout-docs");
  if (!rail || !layout) return;

  const page = location.pathname.split("/").pop() || DOCS_HUB;

  fetch("docs-nav.json")
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error("nav fetch failed"))))
    .then((manifest) => {
      const entry = manifest[page];
      showRail(entry ? render(entry) : renderFallback());
    })
    .catch(() => {
      showRail(renderFallback());
    });

  function showRail(parts) {
    if (parts.rail) {
      rail.innerHTML = parts.rail;
      rail.hidden = false;
      layout.classList.add("layout-docs--rail");
      layout.classList.remove("layout-docs--full");
      if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        rail.classList.remove("doc-rail--mounted");
        void rail.offsetWidth;
        rail.classList.add("doc-rail--mounted");
      }
      const linksEl = rail.querySelector(".your-links");
      if (linksEl && window.MembraneYourLinks) {
        MembraneYourLinks.bindShell(linksEl);
      }
    } else {
      // personal tools live in the toolbelt — no right rail on docs pages
      rail.innerHTML = "";
      rail.hidden = true;
      layout.classList.remove("layout-docs--rail");
    }
    // The Book rail lives in the LEFT nav, under the menu
    const nav = layout.querySelector("nav");
    if (nav && parts.book) {
      let host = document.getElementById("navBookRail");
      if (!host) {
        host = document.createElement("div");
        host.id = "navBookRail";
        nav.appendChild(host);
      }
      host.innerHTML = parts.book;
    }
  }

  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function loadSnap(key) {
    try {
      const raw = sessionStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function saveBookSnap(entry) {
    sessionStorage.setItem(
      BOOK_SNAP,
      JSON.stringify({
        page,
        pos: entry.pos,
        title: entry.title,
        prev: entry.prev,
        prevLabel: entry.prevLabel,
        next: entry.next,
        nextLabel: entry.nextLabel,
      })
    );
  }

  function saveSpecSnap(entry) {
    sessionStorage.setItem(
      SPEC_SNAP,
      JSON.stringify({
        book: entry.book,
        hub: entry.hub,
        part: entry.part,
        partPos: entry.partPos,
        partTotal: entry.partTotal,
        prev: entry.prev,
        prevLabel: entry.prevLabel,
        prevPart: entry.prevPart,
        next: entry.next,
        nextLabel: entry.nextLabel,
        nextPart: entry.nextPart,
      })
    );
  }

  function defaultBookData() {
    return { page: BOOK_HUB, title: "Chapter index" };
  }

  function defaultSpecData() {
    return { book: "The Notebook", hub: NOTEBOOK_HUB };
  }

  function renderFallback() {
    const bookSnap = loadSnap(BOOK_SNAP);
    const specSnap = loadSnap(SPEC_SNAP);
    const isBookHub = page === BOOK_HUB;
    const isNotebookHub = page === NOTEBOOK_HUB;
    const isDocsRoot = page === DOCS_HUB;

    return renderDual(
      isBookHub ? { isHub: true } : bookSnap || defaultBookData(),
      isNotebookHub ? { isHub: true, book: "The Notebook", hub: NOTEBOOK_HUB } : specSnap || defaultSpecData(),
      isBookHub,
      isNotebookHub && !isDocsRoot
    );
  }

  function seqRow(prev, prevLabel, prevPart, next, nextLabel, nextPart) {
    const navBits = [];
    if (prev && prevLabel) {
      const hint = prevPart ? ` title="${esc(prevPart)}"` : "";
      navBits.push(`<a class="doc-rail-prev" href="${esc(prev)}"${hint}>← ${esc(prevLabel)}</a>`);
    }
    if (next && nextLabel) {
      const hint = nextPart ? ` title="${esc(nextPart)}"` : "";
      navBits.push(`<a class="doc-rail-next" href="${esc(next)}"${hint}>${esc(nextLabel)} →</a>`);
    }
    if (!navBits.length) return "";
    return `<div class="doc-rail-row doc-rail-row--seq">${navBits.join("")}</div>`;
  }

  function relatedSpecsRow(specs) {
    if (!specs?.length) return "";
    const links = specs
      .slice(0, 4)
      .map((s) => `<a href="${esc(s.href)}">${esc(s.label)}</a>`)
      .join("");
    return `<div class="doc-rail-row doc-rail-row--related">${links}</div>`;
  }

  function bookRailHeader() {
    return `<a class="doc-rail-book" href="${BOOK_HUB}">The Book</a>`;
  }

  function chBox(data, active) {
    const label = data.isHub
      ? "Chapter index"
      : `Book ch ${data.pos} · ${esc(data.title)}`;
    if (active) {
      return `<div class="doc-rail-part doc-rail-part--link doc-rail-ch-now">${label}</div>`;
    }
    const href = data.page || data.story || BOOK_HUB;
    return `<a class="doc-rail-part doc-rail-part--link" href="${esc(href)}">${label}</a>`;
  }

  /** @param {object} data book rail fields */
  /** @param {boolean} active */
  function renderBookRail(data, active) {
    const on = active ? " doc-rail-block--on" : " doc-rail-block--off";
    let where = "";
    let seq = "";

    if (data.isHub && active) {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        bookRailHeader() +
        `<div class="doc-rail-part doc-rail-part--link doc-rail-ch-now">Chapter index</div>` +
        `</div>`;
    } else if (data.pos != null && data.title) {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        bookRailHeader() +
        chBox(data, active) +
        `</div>`;
      seq = seqRow(data.prev, data.prevLabel, null, data.next, data.nextLabel, null);
    } else if (data.story && data.storyLabel) {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        bookRailHeader() +
        `<a class="doc-rail-part doc-rail-part--link" href="${esc(data.story)}">${esc(data.storyLabel)}</a>` +
        `</div>`;
    } else {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        bookRailHeader() +
        `<a class="doc-rail-part doc-rail-part--link" href="${BOOK_HUB}">Chapter index</a>` +
        `</div>`;
    }

    return (
      `<section class="doc-rail-block doc-rail-block--book${on}" aria-label="The Book">` +
      where +
      seq +
      `</section>`
    );
  }

  /** @param {object} data spec rail fields */
  /** @param {boolean} active */
  function renderSpecRail(data, active) {
    const on = active ? " doc-rail-block--on" : " doc-rail-block--off";
    let where = "";
    let seq = "";
    let related = "";

    if (data.isHub && active && data.book) {
      const bookLine = data.hub
        ? `<a class="doc-rail-book" href="${esc(data.hub)}">${esc(data.book)}</a>`
        : `<a class="doc-rail-book" href="${NOTEBOOK_HUB}">${esc(data.book)}</a>`;
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        bookLine +
        `<div class="doc-rail-part doc-rail-ch-now">Book index</div>` +
        `</div>`;
    } else if (data.book) {
      const hubHref = data.hub || NOTEBOOK_HUB;
      const bookLine = `<a class="doc-rail-book" href="${esc(hubHref)}">${esc(data.book)}</a>`;
      const partLine =
        data.part && data.partPos != null && data.partTotal != null
          ? `<div class="doc-rail-part">${esc(data.part)} · ${data.partPos} / ${data.partTotal}</div>`
          : `<a class="doc-rail-part doc-rail-part--link" href="${esc(hubHref)}">Book index</a>`;
      where = `<div class="doc-rail-row doc-rail-row--where">${bookLine}${partLine}</div>`;
      seq = seqRow(
        data.prev,
        data.prevLabel,
        data.prevPart,
        data.next,
        data.nextLabel,
        data.nextPart
      );
    } else if (data.relatedSpecs?.length) {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        `<a class="doc-rail-book" href="${NOTEBOOK_HUB}">The Notebook</a>` +
        `<a class="doc-rail-part doc-rail-part--link" href="${NOTEBOOK_HUB}">Book index</a>` +
        `</div>`;
      related = relatedSpecsRow(data.relatedSpecs);
    } else {
      where =
        `<div class="doc-rail-row doc-rail-row--where">` +
        `<a class="doc-rail-book" href="${NOTEBOOK_HUB}">The Notebook</a>` +
        `<a class="doc-rail-part doc-rail-part--link" href="${NOTEBOOK_HUB}">Book index</a>` +
        `</div>`;
    }

    return (
      `<section class="doc-rail-block doc-rail-block--spec${on}" aria-label="Notebook spec">` +
      where +
      seq +
      related +
      `</section>`
    );
  }

  function renderDual(bookData, specData, bookActive, specActive) {
    return {
      book:
        renderBookRail(bookData, bookActive) +
        renderSpecRail(specData, specActive),
      rail: window.MembraneYourLinks ? MembraneYourLinks.renderCollapsed() : "",
    };
  }

  function render(entry) {
    const isBook = entry.track === "book";
    const isSpec = entry.track === "spec";
    const isDocsRoot = entry.track === "docs";

    if (isBook && !entry.isHub) saveBookSnap(entry);
    if (isSpec && !entry.isHub) saveSpecSnap(entry);

    const bookSnap = loadSnap(BOOK_SNAP);
    const specSnap = loadSnap(SPEC_SNAP);

    if (isDocsRoot) {
      return renderDual(
        bookSnap || defaultBookData(),
        specSnap || defaultSpecData(),
        false,
        false
      );
    }

    const bookData = isBook ? entry : bookSnap || defaultBookData();
    const specData = isSpec ? entry : specSnap || defaultSpecData();

    return renderDual(bookData, specData, isBook, isSpec);
  }
})();
