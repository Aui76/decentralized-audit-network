/**
 * Your links — personal pin board (localStorage, cross-page).
 * v2: empty drop zone, manual drag reorder, track color hints.
 */
(function () {
  const STORAGE_KEY = "membraneYourLinks";
  const MAX_LINKS = 24;

  // a page rendered inside the split pane strips its own chrome
  const FRAMED = window.self !== window.top;
  if (FRAMED) document.documentElement.classList.add("framed");

  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      const items = raw ? JSON.parse(raw) : [];
      return Array.isArray(items) ? items.filter((i) => i && i.href && i.label) : [];
    } catch {
      return [];
    }
  }

  function save(items) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(items.slice(0, MAX_LINKS)));
  }

  function detectTrack(href) {
    const f = (href.split("?")[0].split("#")[0].split("/").pop() || href).toLowerCase();
    if (/^docs-book(-|$)/.test(f)) return "book";
    if (
      /^docs-(participants|economy|health|flows|integration|contract|problem|mechanism|fingerprint|structural)/.test(
        f
      )
    )
      return "spec";
    if (/^(explorer|post|manage|concern)\.html$/i.test(f)) return "tool";
    return "neutral";
  }

  function normalizeHref(href) {
    const raw = href.trim();
    if (!raw) return "";
    try {
      if (/^https?:\/\//i.test(raw)) {
        const u = new URL(raw);
        if (u.origin !== location.origin) return u.href;
        const leaf = u.pathname.split("/").pop() || "index.html";
        return leaf + u.search + u.hash;
      }
    } catch {
      /* relative */
    }
    return raw.replace(/^\.\//, "").split("/").pop() || raw;
  }

  function pageLabel() {
    const h1 = document.querySelector("main h1");
    if (h1) return h1.textContent.trim();
    return (document.title || "")
      .replace(/\s*·\s*Audit Cell\s*$/i, "")
      .replace(/\s*—\s*Audit Cell\s*$/i, "")
      .trim();
  }

  function currentHref() {
    return location.pathname.split("/").pop() || "index.html";
  }

  function addLink(href, label, track) {
    const h = normalizeHref(href);
    if (!h) return false;
    const items = load();
    if (items.some((i) => i.href === h)) return false;
    items.push({
      href: h,
      label: (label || h).trim(),
      track: track || detectTrack(h),
    });
    save(items);
    return true;
  }

  function removeAt(idx) {
    const items = load();
    items.splice(idx, 1);
    save(items);
  }

  function move(from, to) {
    const items = load();
    if (from < 0 || from >= items.length || to < 0 || to >= items.length || from === to) return;
    const [it] = items.splice(from, 1);
    items.splice(to, 0, it);
    save(items);
  }

  function labelFromHref(href) {
    const leaf = href.split("?")[0].split("#")[0];
    const base = leaf.split("/").pop() || leaf;
    if (/^docs-book-\d+\.html$/i.test(base)) return base.replace(/^docs-book-(\d+)\.html$/i, "Book ch $1");
    const names = {
      "explorer.html": "Explorer",
      "post.html": "Post bounty",
      "manage.html": "Manage cell",
      "concern.html": "Find your step",
      "index.html": "Welcome",
    };
    if (names[base]) return names[base];
    return base.replace(/\.html$/i, "").replace(/-/g, " ");
  }

  function addFromUri(uri, listEl, dropEl) {
    let href = uri;
    let label = labelFromHref(uri);
    try {
      const u = new URL(uri, location.href);
      href = normalizeHref(u.href);
      if (/^https?:\/\//i.test(uri) && u.origin !== location.origin) {
        label = u.hostname + u.pathname;
      }
    } catch {
      href = normalizeHref(uri);
    }
    addLink(href, label, detectTrack(href));
    renderList(listEl, dropEl);
  }

  function updateSummary(shell, count) {
    const sum = shell?.querySelector(".your-links-summary");
    if (!sum) return;
    sum.textContent = count ? `Your links · ${count}` : "Your links";
  }

  function renderList(listEl, dropEl) {
    const items = load();
    const shell = listEl.closest(".your-links");
    const clearBtn = dropEl.closest(".your-links-body")?.querySelector(".your-links-clear");
    if (clearBtn) clearBtn.hidden = items.length === 0;

    updateSummary(shell, items.length);
    if (typeof updateBelt === "function") updateBelt();
    dropEl.textContent = items.length ? "Drop another link" : "Drop links here";

    if (!items.length) {
      listEl.innerHTML = "";
      return;
    }

    listEl.innerHTML = items
      .map(
        (item, idx) =>
          `<li class="your-links-item" draggable="true" data-idx="${idx}">` +
          `<span class="your-links-grip" aria-hidden="true" title="Drag to reorder">⋮⋮</span>` +
          `<a class="your-links-link your-links-link--${esc(item.track)}" href="${esc(item.href)}" title="${esc(item.href)}">${esc(item.label)}</a>` +
          `<button type="button" class="your-links-remove" data-idx="${idx}" aria-label="Remove">×</button>` +
          `</li>`
      )
      .join("");
    bindListEvents(listEl, dropEl);
  }

  function bindListEvents(listEl, dropEl) {
    let dragIdx = null;

    listEl.querySelectorAll(".your-links-item").forEach((li) => {
      li.addEventListener("dragstart", (e) => {
        dragIdx = Number(li.dataset.idx);
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", String(dragIdx));
        li.classList.add("your-links-item--drag");
      });
      li.addEventListener("dragend", () => {
        dragIdx = null;
        li.classList.remove("your-links-item--drag");
      });
      li.addEventListener("dragover", (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
      });
      li.addEventListener("drop", (e) => {
        e.preventDefault();
        e.stopPropagation();
        const to = Number(li.dataset.idx);
        if (dragIdx !== null && dragIdx !== to) {
          move(dragIdx, to);
          renderList(listEl, dropEl);
        }
      });
    });

    listEl.querySelectorAll(".your-links-remove").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.preventDefault();
        removeAt(Number(btn.dataset.idx));
        renderList(listEl, dropEl);
      });
    });

    // your-links open in the split pane — current page stays on top
    listEl.querySelectorAll(".your-links-link").forEach((a) => {
      a.addEventListener("click", (e) => {
        if (e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
        e.preventDefault();
        openSplit(a.getAttribute("href"), a.textContent);
      });
    });
  }

  function bindDropZone(dropEl, listEl) {
    dropEl.addEventListener("dragover", (e) => {
      e.preventDefault();
      dropEl.classList.add("your-links-drop--over");
    });
    dropEl.addEventListener("dragleave", () => {
      dropEl.classList.remove("your-links-drop--over");
    });
    dropEl.addEventListener("drop", (e) => {
      e.preventDefault();
      dropEl.classList.remove("your-links-drop--over");
      const uri =
        e.dataTransfer.getData("text/uri-list").split("\n").find((l) => l && !l.startsWith("#")) ||
        e.dataTransfer.getData("text/plain");
      if (uri) addFromUri(uri.trim(), listEl, dropEl);
    });
  }

  /* ---- Your audits — personal watchlist, advisory reading only (L2 organ) ---- */
  const AUD_KEY = "membraneYourAudits";
  const AUD_STATES = ["None","Submitted","Assigned","InAudit","AwaitingWindow","Audited","InBlock","Claimed","Exploited","Invalidated"];
  const AUD_GLOSS = {
    Submitted: "in review — waiting for an auditor",
    Assigned: "in review — auditor decision pending",
    InAudit: "in review — tool running",
    AwaitingWindow: "passed — challenge window open",
    Audited: "settled",
    InBlock: "settled and paid",
    Claimed: "disputed — independent re-check running",
    Exploited: "bug confirmed — original pass was wrong",
    Invalidated: "voided — spec invalidated",
  };

  function audStateName(s) {
    return typeof s === "number" ? AUD_STATES[s] || String(s) : String(s || "");
  }

  function audCat(name) {
    if (name === "Audited" || name === "InBlock") return "ok";
    if (name === "AwaitingWindow") return "win";
    if (name === "Claimed") return "warn";
    if (name === "Exploited") return "bad";
    return "mut";
  }

  function audLoad() {
    try {
      const raw = localStorage.getItem(AUD_KEY);
      const items = raw ? JSON.parse(raw) : [];
      return Array.isArray(items) ? items.filter((i) => i && i.id != null) : [];
    } catch {
      return [];
    }
  }

  function audSave(items) {
    localStorage.setItem(AUD_KEY, JSON.stringify(items.slice(0, 24)));
  }

  let audModelP = null;
  function audModel() {
    if (window.__MODEL) return Promise.resolve(window.__MODEL);
    if (!audModelP)
      audModelP = fetch("view-model.json")
        .then((r) => (r.ok ? r.json() : null))
        .catch(() => null);
    return audModelP;
  }

  /* ---- live watch states — read-only auditStateOf(id) per watched id, 10-min cache ----
     selector 0x1b9cd781 derived at build time from keccak("auditStateOf(uint256)") via
     verify-core.mjs keccak (same derivation reproduces nextAuditId's 0xd1a69cc4). */
  const AUD_STATE_SEL = "0x1b9cd781";
  const AUD_LIVE_KEY = "membraneWatchStates";
  function audLiveStates(meta, ids) {
    // resolves {id: stateNumber} for the ids it could read; {} on RPC failure (never rejects)
    return new Promise((resolve) => {
      let cached = null;
      try {
        cached = JSON.parse(sessionStorage.getItem(AUD_LIVE_KEY) || "null");
      } catch (e) { /* re-read */ }
      if (cached && Date.now() - cached.at < 600000 && ids.every((id) => cached.states[id] != null))
        return resolve(cached.states);
      const rpc = (meta && meta.rpcUrl) || "https://sepolia.base.org";
      const cell = meta && meta.cell;
      if (!cell) return resolve({});
      const states = {};
      const next = (i) => {
        if (i >= ids.length) {
          try { sessionStorage.setItem(AUD_LIVE_KEY, JSON.stringify({ at: Date.now(), states })); } catch (e) {}
          return resolve(states);
        }
        const idHex = BigInt(ids[i]).toString(16).padStart(64, "0");
        fetch(rpc, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: cell, data: AUD_STATE_SEL + idHex }, "latest"] }),
        })
          .then((r) => r.json())
          .then((j) => {
            if (j && j.result && j.result.length >= 3) states[ids[i]] = parseInt(j.result, 16);
            next(i + 1);
          })
          .catch(() => resolve(states)); // RPC gone — return what we have, rail degrades to snapshot
      };
      next(0);
    });
  }

  function audMarkSeen(id, name) {
    const items = audLoad();
    const it = items.find((i) => String(i.id) === String(id));
    if (it && name && it.lastState !== name) {
      it.lastState = name;
      audSave(items);
    }
  }

  function audSegs(name) {
    // mini fill-the-sequence rail: posted · review · window · outcome
    const seg = (cls, t) => `<span class="ya-seg ${cls}" title="${t}"></span>`;
    const inReview = name === "Submitted" || name === "Assigned" || name === "InAudit";
    const win = name === "AwaitingWindow";
    const settled = name === "Audited" || name === "InBlock";
    const branch = name === "Claimed" ? "warn" : name === "Exploited" ? "bad" : name === "Invalidated" ? "mut" : null;
    return (
      seg("done", "posted") +
      seg(inReview ? "on" : "done", "in review") +
      seg(win ? "on" : settled ? "done" : "", "challenge window") +
      (branch ? seg(branch + " on", AUD_GLOSS[name] || name) : seg(settled ? "on done" : "", "settled"))
    );
  }

  function audCardHtml(item, a, liveState) {
    // liveState (number) wins over the snapshot when the read succeeded
    const live = liveState != null;
    const name = live ? audStateName(liveState) : a ? audStateName(a.state) : null;
    const cat = name ? audCat(name) : "mut";
    const changed = name && item.lastState && item.lastState !== name;
    return (
      `<li class="ya-card ya-card--${cat}" data-id="${item.id}">` +
      `<div class="ya-head"><span class="ya-id">#${esc(item.id)}</span>` +
      (changed ? `<span class="tag ya-changed">changed</span>` : "") +
      `<button type="button" class="your-links-remove ya-remove" data-id="${item.id}" aria-label="Remove">×</button></div>` +
      (name
        ? `<div class="ya-rail">${audSegs(name)}</div><div class="ya-gloss">${esc(AUD_GLOSS[name] || name)}</div>`
        : `<div class="ya-gloss">state unknown here — open it below</div>`) +
      (changed
        ? `<div class="ya-diff">${esc(item.lastState)} → ${esc(name)} since your last look` +
          ` <button type="button" class="ya-seen" data-id="${item.id}" data-state="${esc(name)}">seen</button></div>`
        : "") +
      audVerifiedLine(item.id) +
      `<div class="ya-links"><a href="explorer.html?id=${item.id}">Explorer</a><a href="concern.html?id=${item.id}">Find your step →</a></div>` +
      `</li>`
    );
  }

  function audVerifiedLine(id) {
    try {
      const v = JSON.parse(localStorage.getItem("membraneYourVerifications") || "{}")[String(id)];
      if (v && v.verdict)
        return `<div class="ya-verified">reproduced by you · ${new Date(v.at).toLocaleDateString()} ✓</div>`;
    } catch (e) { /* no ledger */ }
    return "";
  }

  function audUpdateSummary(shell) {
    const sum = shell.querySelector(".your-links-summary");
    const n = audLoad().length;
    if (sum) sum.textContent = n ? `Your audits · ${n}` : "Your audits";
  }

  function audRender(shell) {
    const listEl = shell.querySelector(".ya-list");
    const empty = shell.querySelector(".ya-empty");
    if (!listEl) return;
    const items = audLoad();
    audUpdateSummary(shell);
    updateBelt();
    if (empty) empty.hidden = items.length > 0;
    const batchRow = shell.querySelector(".ya-batchrow");
    if (batchRow) batchRow.hidden = items.length === 0;
    if (!items.length) {
      listEl.innerHTML = "";
      return;
    }
    audModel().then((m) => {
      const byId = {};
      (m && m.audits ? m.audits : []).forEach((a) => (byId[a.id] = a));
      const paint = (liveStates) => {
        const anyLive = Object.keys(liveStates).length > 0;
        const snap = shell.querySelector(".ya-snapage");
        if (snap && m && m.meta && m.meta.generatedAt) {
          snap.hidden = false;
          snap.textContent = anyLive
            ? "state read live from the chain · details from snapshot · " + agoStr(m.meta.generatedAt)
            : "cards read the indexed snapshot · " + agoStr(m.meta.generatedAt);
        }
        listEl.innerHTML = items.map((it) => audCardHtml(it, byId[it.id], liveStates[it.id])).join("");
        // first sight of an audit sets the diff baseline; after that, only
        // opening it (or the "seen" button) moves lastState — a change badge
        // survives reloads until the visitor actually looks.
        let dirty = false;
        items.forEach((it) => {
          if (it.lastState) return;
          const nm = liveStates[it.id] != null ? audStateName(liveStates[it.id]) : byId[it.id] ? audStateName(byId[it.id].state) : null;
          if (nm) { it.lastState = nm; dirty = true; }
        });
        if (dirty) audSave(items);
      };
      audLiveStates(m && m.meta, items.map((it) => it.id)).then(paint, () => paint({}));
    });
  }

  function audShellHtml() {
    return (
      `<details class="your-audits your-links--collapsed doc-rail-block doc-rail-block--links">` +
      `<summary class="lbl your-links-summary">Your audits</summary>` +
      `<div class="your-links-body">` +
      `<p class="tiny ya-snapage" hidden></p>` +
      `<ul class="ya-list"></ul>` +
      `<div class="ya-batchrow" hidden>` +
      `<button type="button" class="ya-batch">Re-verify all watched</button>` +
      `<span class="tiny ya-batchout"></span>` +
      `</div>` +
      `<p class="tiny ya-empty">Watch audits from the explorer — each card keeps an advisory reading of the line. It never acts for you.</p>` +
      `</div></details>`
    );
  }

  /* ---- batch Level-A re-verify — nothing asserted, everything re-derived ----
     Writes the personal ledger in the exact shape explorer.html owns:
     membraneYourVerifications = { [id]: { verdict, root, at } }. Keep that shape.
     Honest buckets: audits are pre-sorted on settled on-chain facts (state, specHash)
     so an EXPECTED non-match is never dressed up as an alarm. Labels can only
     downgrade alarm — VERIFIED still comes only from re-derivation. */
  // canonical fixture spec — derived at build time from verify-core.mjs `specHash`
  // (re-derive if the fixture spec ever versions; B2 below depends on it)
  const AUD_CANON_SPEC = "0x7fe57aec3c363ab9da26d8a45f6bd22f30a5f441b597136e9b8fbcdca38fbe77";
  const AUD_PRE_VERDICT = { Submitted: 1, Assigned: 1, InAudit: 1 }; // no settled root yet
  function audBatchVerify(shell) {
    const out = shell.querySelector(".ya-batchout");
    const btn = shell.querySelector(".ya-batch");
    if (!out || !btn || btn.disabled) return;
    btn.disabled = true;
    out.textContent = "loading verifier…";
    const loader = window.MembraneVerify
      ? Promise.resolve()
      : import("./verify-browser.mjs?v=1").catch(() => null);
    Promise.all([audModel(), loader]).then(async ([m]) => {
      if (!window.MembraneVerify || !m || !m.meta) {
        out.textContent = "verifier unavailable on this page";
        btn.disabled = false;
        return;
      }
      const byId = {};
      (m.audits || []).forEach((a) => (byId[a.id] = a));
      const items = audLoad();
      const liveStates = await audLiveStates(m.meta, items.map((it) => it.id));
      const buckets = { ok: [], bad: [], expMis: [], paradox: [], notSettled: [], diffSpec: [], err: [] };
      let skipped = 0, rpcDead = false;
      for (let i = 0; i < items.length; i++) {
        const a = byId[items[i].id];
        if (!a || !a.target) { skipped++; continue; }
        const stName = audStateName(liveStates[a.id] != null ? liveStates[a.id] : a.state);
        const overturned = stName === "Exploited" || stName === "Invalidated";
        if (AUD_PRE_VERDICT[stName]) { buckets.notSettled.push(a.id); continue; }
        if (a.specHash && String(a.specHash).toLowerCase() !== AUD_CANON_SPEC) { buckets.diffSpec.push(a.id); continue; }
        out.textContent = "re-verifying " + (i + 1) + "/" + items.length + "…";
        try {
          const r = await window.MembraneVerify.reproduce({
            rpcUrl: m.meta.rpcUrl || "https://sepolia.base.org",
            cell: m.meta.cell,
            auditId: a.id,
            target: a.target,
          });
          if (r && r.ok && r.verdict) {
            if (overturned) {
              // should be impossible for honest data — worth a human's eyes
              buckets.paradox.push(a.id);
            } else {
              buckets.ok.push(a.id);
              try {
                const l = JSON.parse(localStorage.getItem("membraneYourVerifications") || "{}");
                l[String(a.id)] = { verdict: r.verdict, root: r.onchain, at: Date.now() };
                localStorage.setItem("membraneYourVerifications", JSON.stringify(l));
              } catch (e) { /* ledger write best-effort */ }
            }
          } else if (r && r.ok) {
            // recomputation ran and the on-chain root matched neither encoding
            if (overturned) buckets.expMis.push(a.id); // the record working, not an alarm
            else buckets.bad.push(a.id);
          } else {
            // could not complete the recomputation — NOT the same as a mismatch
            buckets.err.push(a.id);
          }
        } catch (e) {
          rpcDead = true;
          break;
        }
      }
      const any = Object.keys(buckets).some((k) => buckets[k].length);
      if (rpcDead && !any) {
        out.textContent = "RPC unreachable — nothing written";
      } else {
        const link = (id) => '<a href="explorer.html?id=' + id + '">#' + id + "</a>";
        const ids = (arr) => " (" + arr.map(link).join(", ") + ")";
        out.innerHTML =
          "VERIFIED " + buckets.ok.length +
          (buckets.bad.length ? ' · <span class="ya-batchbad">MISMATCH ' + buckets.bad.length + ids(buckets.bad) + "</span>" : "") +
          (buckets.paradox.length ? ' · <span class="ya-batchbad">verifies but overturned ' + buckets.paradox.length + ids(buckets.paradox) + " — read the audit page</span>" : "") +
          (buckets.expMis.length ? " · expected mismatch " + buckets.expMis.length + ids(buckets.expMis) + " — verdict overturned; the record working" : "") +
          (buckets.notSettled.length ? " · not settled yet " + buckets.notSettled.length + ids(buckets.notSettled) + " — nothing to check" : "") +
          (buckets.diffSpec.length ? " · different spec " + buckets.diffSpec.length + ids(buckets.diffSpec) + " — not checkable in-tab" : "") +
          (buckets.err.length ? " · could not verify " + buckets.err.length + ids(buckets.err) : "") +
          (skipped ? " · skipped " + skipped + " (not in snapshot yet)" : "") +
          (rpcDead ? " · stopped early (RPC)" : "");
      }
      btn.disabled = false;
      audRender(shell); // refresh "reproduced by you" lines
    });
  }

  function bindAudits(shell) {
    if (!shell || shell.dataset.audWired) return;
    shell.dataset.audWired = "1";
    audUpdateSummary(shell);
    shell.addEventListener("toggle", () => { if (shell.open) audRender(shell); });
    shell.addEventListener("click", (e) => {
      const seen = e.target.closest(".ya-seen");
      if (seen) {
        e.preventDefault();
        audMarkSeen(seen.dataset.id, seen.dataset.state);
        audRender(shell);
        return;
      }
      const batch = e.target.closest(".ya-batch");
      if (batch) {
        e.preventDefault();
        audBatchVerify(shell);
        return;
      }
      const link = e.target.closest(".ya-links a");
      if (link && !(e.ctrlKey || e.metaKey || e.shiftKey)) {
        // opening the audit counts as looking at it — the diff baseline moves
        const card = link.closest(".ya-card");
        if (card) {
          const btnSeen = card.querySelector(".ya-seen");
          if (btnSeen) audMarkSeen(btnSeen.dataset.id, btnSeen.dataset.state);
        }
        // audit card links open in the split — theory on top, the line below
        e.preventDefault();
        openSplit(link.getAttribute("href"), link.textContent.replace(/→/g, "").trim());
        return;
      }
      const btn = e.target.closest(".ya-remove");
      if (!btn) return;
      e.preventDefault();
      audSave(audLoad().filter((i) => String(i.id) !== String(btn.dataset.id)));
      audRender(shell);
      mountNavChip();
    });
  }

  /* ---- lacquer — favicon + browser-chrome color, injected so no page needs editing ---- */
  function lacquer() {
    if (!document.querySelector('link[rel~="icon"]')) {
      const l = document.createElement("link");
      l.rel = "icon";
      l.href =
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#050807"/><rect x="7" y="7" width="18" height="18" rx="4" fill="#2bff8a"/></svg>'
        );
      document.head.appendChild(l);
    }
    if (!document.querySelector('meta[name="theme-color"]')) {
      const m = document.createElement("meta");
      m.name = "theme-color";
      m.content = "#050807";
      document.head.appendChild(m);
    }
  }

  /* ---- standardized page foot — same four doors at the end of every page ---- */
  function standardizeFooter() {
    const main = document.querySelector("main");
    if (!main) return;
    const LINKS =
      '<a href="network-qa.html">Q&amp;A</a> · <a href="explorer.html">Explorer</a> · <a href="docs.html">Docs</a> · <a href="docs-verify.html">Verify</a>';
    let foot = main.querySelector(".doc-page-foot");
    if (!foot) {
      foot = document.createElement("footer");
      foot.className = "doc-page-foot";
      (main.querySelector(".inner") || main.querySelector(".wrap") || main).appendChild(foot);
    }
    const hasAnchors = !!foot.querySelector("a");
    const text = foot.textContent.trim();
    if (hasAnchors || !text) {
      // links-only or empty footer — replace with the standard four
      foot.innerHTML = LINKS;
    } else {
      // meaningful text (e.g. explorer's snapshot line) — keep it, add the row
      foot.innerHTML = "<div>" + foot.innerHTML + "</div>" + '<div style="margin-top:6px">' + LINKS + "</div>";
    }
  }

  /* ---- snapshot freshness — the site says how old its data is, everywhere ---- */
  function agoStr(ts) {
    const t = Date.parse(ts);
    if (isNaN(t)) return "";
    const s = Math.max(0, Math.floor((Date.now() - t) / 1000));
    if (s < 60) return s + "s ago";
    const m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    const h = Math.floor(m / 60);
    if (h < 24) return h + "h ago";
    return Math.floor(h / 24) + "d ago";
  }

  function freshnessPing(meta, maxId) {
    // one read-only eth_call per 10 minutes, cached — compares chain head to the snapshot
    return new Promise((resolve) => {
      try {
        const cached = JSON.parse(sessionStorage.getItem("membraneFreshPing") || "null");
        if (cached && Date.now() - cached.at < 600000) return resolve(cached.next);
      } catch (e) { /* re-ping */ }
      fetch(meta.rpcUrl || "https://sepolia.base.org", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: meta.cell, data: "0xd1a69cc4" }, "latest"] }),
      })
        .then((r) => r.json())
        .then((j) => {
          const next = j && j.result ? parseInt(j.result, 16) : null;
          try { sessionStorage.setItem("membraneFreshPing", JSON.stringify({ at: Date.now(), next })); } catch (e) {}
          resolve(next);
        })
        .catch(() => resolve(null));
    });
  }

  function mountFreshness() {
    if (FRAMED) return;
    const nav = document.querySelector(".layout nav");
    if (!nav || document.getElementById("navSnapshot")) return;
    audModel().then((m) => {
      if (!m || !m.meta || !m.meta.generatedAt) return;
      const chip = document.createElement("a");
      chip.id = "navSnapshot";
      chip.className = "nav-watch";
      chip.href = "docs-verify.html";
      const age = agoStr(m.meta.generatedAt);
      const stale = Date.now() - Date.parse(m.meta.generatedAt) > 86400000;
      chip.textContent = "snapshot · " + age;
      chip.title = "This site reads an indexed snapshot of the chain (" + age + "). Live reads: concern Step 0, Reproduce it now, demo pool. Operator refresh: npm run index.";
      if (stale) chip.classList.add("nav-watch--changed");
      nav.appendChild(chip);
      const maxId = (m.audits || []).reduce((s, a) => Math.max(s, a.id), -1);
      freshnessPing(m.meta, maxId).then((next) => {
        if (next == null) return;
        const newer = next - (maxId + 1);
        if (newer > 0) {
          chip.textContent = "snapshot · " + age + " · " + newer + " newer on chain";
          chip.classList.add("nav-watch--changed");
        }
      });
    });
  }

  function mountNavChip() {
    const nav = document.querySelector(".layout nav");
    if (!nav) return;
    let chip = document.getElementById("navWatchChip");
    const n = audLoad().length;
    if (!n) { if (chip) chip.remove(); return; }
    if (!chip) {
      chip = document.createElement("a");
      chip.id = "navWatchChip";
      chip.className = "nav-watch";
      chip.href = "explorer.html";
      nav.appendChild(chip);
    }
    chip.textContent = "Watching · " + n;
    audModel().then((m) => {
      if (!m || !m.audits) return;
      const byId = {};
      m.audits.forEach((a) => (byId[a.id] = a));
      const changed = audLoad().filter((it) => byId[it.id] && it.lastState && audStateName(byId[it.id].state) !== it.lastState).length;
      const badge = document.getElementById("tbAuditsCount");
      if (badge) badge.classList.toggle("toolbelt-count--changed", changed > 0);
      if (changed) {
        chip.textContent = "Watching · " + n + " · " + changed + " changed";
        chip.classList.add("nav-watch--changed");
      }
    });
  }

  window.MembraneYourAudits = {
    load: audLoad,
    has: (id) => audLoad().some((i) => String(i.id) === String(id)),
    toggle(id, state) {
      const items = audLoad();
      const idx = items.findIndex((i) => String(i.id) === String(id));
      if (idx >= 0) items.splice(idx, 1);
      else items.push({ id: Number(id), lastState: audStateName(state), addedAt: Date.now() });
      audSave(items);
      document.querySelectorAll(".your-audits").forEach((s) => { audUpdateSummary(s); if (s.open) audRender(s); });
      mountNavChip();
      return idx < 0;
    },
    refresh() {
      document.querySelectorAll(".your-audits").forEach((s) => { audUpdateSummary(s); if (s.open) audRender(s); });
      mountNavChip();
    },
  };

  const SIGN_PAGES = /^(post|manage|demo-pool)\.html$/i;

  function decorateSigningLinks() {
    document.querySelectorAll("main a[href]").forEach((a) => {
      if (a.dataset.signsTag) return;
      const leaf = (a.getAttribute("href") || "").split("?")[0].split("#")[0].split("/").pop();
      if (!SIGN_PAGES.test(leaf)) return;
      a.dataset.signsTag = "1";
      // a signing surface may never render inside another page — break out of any frame
      if (FRAMED) a.target = "_top";
      const tag = document.createElement("span");
      tag.className = "tag tag-signs";
      tag.textContent = "signs";
      tag.title = "This page can send wallet transactions — browsing the rest of the site needs no wallet";
      (a.querySelector(".name, .act") || a).appendChild(tag);
    });
  }

  function enablePageLinkDrag() {
    document.querySelectorAll("main a[href]").forEach((a) => {
      const href = a.getAttribute("href") || "";
      if (href.startsWith("#") || a.dataset.linksDrag) return;
      a.dataset.linksDrag = "1";
      a.draggable = true;
      a.addEventListener("dragstart", (e) => {
        const url = a.href;
        if (!url) return;
        e.dataTransfer.setData("text/uri-list", url);
        e.dataTransfer.setData("text/plain", url);
        e.dataTransfer.effectAllowed = "copy";
      });
    });
  }

  function observeMainLinks() {
    const main = document.querySelector("main");
    if (!main || main.dataset.linksObserved) return;
    main.dataset.linksObserved = "1";
    new MutationObserver(() => {
      enablePageLinkDrag();
      decorateSigningLinks();
    }).observe(main, {
      childList: true,
      subtree: true,
    });
    enablePageLinkDrag();
    decorateSigningLinks();
  }

  function wireShell(shell) {
    const listEl = shell.querySelector(".your-links-list");
    const dropEl = shell.querySelector(".your-links-drop");

    renderList(listEl, dropEl);
    bindDropZone(dropEl, listEl);

    const pinBtn = shell.querySelector(".your-links-pin");
    pinBtn.addEventListener("click", () => {
      const added = addLink(currentHref(), pageLabel(), detectTrack(currentHref()));
      if (!added) {
        const prev = pinBtn.textContent;
        pinBtn.textContent = "Already pinned";
        setTimeout(() => {
          pinBtn.textContent = prev;
        }, 1200);
      }
      renderList(listEl, dropEl);
    });

    shell.querySelector(".your-links-clear").addEventListener("click", () => {
      save([]);
      renderList(listEl, dropEl);
    });

    observeMainLinks();
  }

  function shellHtml(collapsed) {
    const body =
      `<div class="your-links-body">` +
      `<div class="your-links-toolbar">` +
      `<button type="button" class="your-links-pin">Pin page</button>` +
      `<button type="button" class="your-links-clear" hidden>Clear</button>` +
      `</div>` +
      `<ul class="your-links-list"></ul>` +
      `<div class="your-links-drop" tabindex="0">Drop links here</div>` +
      `</div>`;

    if (collapsed) {
      return (
        `<details class="your-links your-links--collapsed doc-rail-block doc-rail-block--links">` +
        `<summary class="lbl your-links-summary">Your links</summary>` +
        body +
        `</details>`
      );
    }

    return (
      `<section class="your-links your-links--full doc-rail-block doc-rail-block--links" aria-label="Your links">` +
      `<div class="lbl your-links-summary">Your links</div>` +
      body +
      `</section>`
    );
  }

  function renderCollapsed() {
    // legacy rail slot — everything personal now lives in the toolbelt dock
    return "";
  }

  /* ---- Split view — current page on top, a linked page below ---- */
  let beltCloseRef = null;

  function leafOf(href) {
    return (String(href).split("?")[0].split("#")[0].split("/").pop() || "").toLowerCase();
  }

  function splitFrameHref() {
    const f = document.getElementById("splitFrame");
    if (!f) return "";
    try {
      return f.contentWindow.location.href;
    } catch (e) {
      return f.src;
    }
  }

  function closeSplit() {
    const pane = document.getElementById("splitPane");
    if (pane) pane.remove();
    document.documentElement.classList.remove("split-open");
    document.body.style.paddingBottom = "";
    try { sessionStorage.removeItem("membraneSplitKeep"); } catch (e) {}
  }

  function openSplit(href, label) {
    if (FRAMED) {
      location.href = href;
      return;
    }
    if (/^https?:\/\//i.test(href)) {
      try {
        if (new URL(href).origin !== location.origin) {
          window.open(href, "_blank", "noopener");
          return;
        }
      } catch (e) { /* treat as relative */ }
    }
    if (SIGN_PAGES.test(leafOf(href))) {
      // signing surfaces always take the full window — never framed
      location.href = href;
      return;
    }
    let pane = document.getElementById("splitPane");
    if (!pane) {
      pane = document.createElement("div");
      pane.id = "splitPane";
      pane.className = "split-pane";
      pane.innerHTML =
        '<div class="split-handle" id="splitHandle" title="Drag to resize · double-click to reset"><span>⇕</span></div>' +
        '<div class="split-bar">' +
        '<span class="split-title" id="splitTitle"></span>' +
        '<span class="split-actions">' +
        '<button type="button" class="helplink" id="splitFull">open full ↗</button>' +
        '<button type="button" class="helplink" id="splitSwap">swap ⇅</button>' +
        '<button type="button" class="helplink" id="splitClose">close ×</button>' +
        "</span></div>" +
        '<iframe id="splitFrame" class="split-frame" title="Split view"></iframe>';
      document.body.appendChild(pane);
      document.documentElement.classList.add("split-open");
      pane.querySelector("#splitClose").onclick = closeSplit;
      pane.querySelector("#splitFull").onclick = () => {
        const target = splitFrameHref();
        try { sessionStorage.removeItem("membraneSplitKeep"); } catch (e) {}
        location.href = target;
      };
      pane.querySelector("#splitSwap").onclick = () => {
        try {
          sessionStorage.setItem("membraneSplitReopen", location.href);
        } catch (e) { /* no persistence — swap becomes open-full */ }
        location.href = splitFrameHref();
      };
      // resizable split — the handle drags the boundary between the two pages
      const frame = pane.querySelector("#splitFrame");
      const handle = pane.querySelector("#splitHandle");
      const setH = (h) => {
        h = Math.max(140, Math.min(window.innerHeight * 0.85, h));
        pane.style.height = h + "px";
        document.body.style.paddingBottom = h + 24 + "px";
        try { localStorage.setItem("membraneSplitH", String(Math.round(h))); } catch (e) {}
      };
      try {
        const saved = parseInt(localStorage.getItem("membraneSplitH") || "", 10);
        if (saved) setH(saved);
      } catch (e) {}
      handle.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        frame.style.pointerEvents = "none";
        const move = (ev) => setH(window.innerHeight - ev.clientY);
        const up = () => {
          frame.style.pointerEvents = "";
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
      });
      handle.addEventListener("dblclick", () => {
        pane.style.height = "";
        document.body.style.paddingBottom = "";
        try { localStorage.removeItem("membraneSplitH"); } catch (e) {}
      });
      frame.addEventListener("load", () => {
        try {
          const t = (frame.contentDocument.title.split("·")[0] || "").trim();
          if (t) document.getElementById("splitTitle").textContent = t;
        } catch (e) { /* cross-origin — leave the label */ }
        // browsing inside the pane updates what survives navigation
        try { sessionStorage.setItem("membraneSplitKeep", splitFrameHref()); } catch (e) {}
      });
    }
    pane.querySelector("#splitFrame").src = href;
    document.getElementById("splitTitle").textContent = (label || leafOf(href)).trim();
    try { sessionStorage.setItem("membraneSplitKeep", href); } catch (e) {}
    if (beltCloseRef) beltCloseRef();
  }

  function restoreSplit() {
    // the split survives top-page navigation until explicitly closed
    if (FRAMED) return;
    let re = null;
    let keep = null;
    try {
      re = sessionStorage.getItem("membraneSplitReopen");
      if (re) sessionStorage.removeItem("membraneSplitReopen");
      keep = sessionStorage.getItem("membraneSplitKeep");
    } catch (e) { return; }
    const target = re || keep;
    if (!target) return;
    // signing surfaces take the full window — the pane waits for the next page
    if (SIGN_PAGES.test(leafOf(location.pathname))) return;
    openSplit(target, "");
  }

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeSplit();
  });

  /* ---- Toolbelt — one green strip, every personal tool behind it ---- */
  function buildToolbelt() {
    if (FRAMED) return;
    if (document.getElementById("toolbelt") || !document.body) return;
    const belt = document.createElement("div");
    belt.id = "toolbelt";
    belt.className = "toolbelt";
    belt.innerHTML =
      '<button type="button" id="toolbeltStrip" class="toolbelt-strip" aria-expanded="false" aria-controls="toolbeltDock" title="Your tools — links, audits">' +
      '<span class="toolbelt-label">Tools</span>' +
      '<span class="toolbelt-count" id="tbLinksCount" title="Your links">0</span>' +
      '<span class="toolbelt-count" id="tbAuditsCount" title="Your audits">0</span>' +
      "</button>" +
      '<div id="toolbeltDock" class="toolbelt-dock" role="region" aria-label="Your tools">' +
      shellHtml(true) +
      audShellHtml() +
      "</div>";
    document.body.appendChild(belt);
    bindShell(belt.querySelector(".your-links"));

    const strip = belt.querySelector("#toolbeltStrip");
    let pinned = false;
    let tOpen = null;
    let tClose = null;
    const isOpen = () => belt.classList.contains("toolbelt--open");
    const open = () => {
      belt.classList.add("toolbelt--open");
      strip.setAttribute("aria-expanded", "true");
    };
    const close = () => {
      belt.classList.remove("toolbelt--open");
      strip.setAttribute("aria-expanded", "false");
      pinned = false;
    };
    beltCloseRef = close;
    strip.addEventListener("mouseenter", () => {
      clearTimeout(tClose);
      tOpen = setTimeout(open, 150);
    });
    strip.addEventListener("dragenter", open);
    strip.addEventListener("focus", open);
    strip.addEventListener("click", () => {
      if (isOpen() && pinned) close();
      else {
        open();
        pinned = true;
      }
    });
    belt.addEventListener("mouseenter", () => clearTimeout(tClose));
    belt.addEventListener("mouseleave", () => {
      clearTimeout(tOpen);
      tClose = setTimeout(() => {
        if (!pinned) close();
      }, 300);
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && isOpen()) close();
    });
    updateBelt();
  }

  function updateBelt() {
    const l = document.getElementById("tbLinksCount");
    const a = document.getElementById("tbAuditsCount");
    if (l) l.textContent = String(load().length);
    if (a) a.textContent = String(audLoad().length);
  }

  function bindShell(shell) {
    if (!shell || shell.dataset.linksWired) return;
    shell.dataset.linksWired = "1";
    wireShell(shell);
    const host = shell.parentElement;
    if (host) bindAudits(host.querySelector(".your-audits"));
  }

  /** @param {HTMLElement} host */
  function mount(host, opts) {
    const mode = opts?.mode || "full";
    const collapsed = mode === "collapsed";

    host.hidden = false;
    const layout = host.closest(".layout-docs, .layout-tool");
    layout?.classList.remove("layout-docs--full");
    if (layout?.classList.contains("layout-docs")) {
      layout.classList.add("layout-docs--rail");
    }
    if (layout?.classList.contains("layout-tool")) {
      layout.classList.add("layout-tool--links");
    }

    host.innerHTML = shellHtml(collapsed) + audShellHtml();
    bindShell(host.querySelector(".your-links"));
    return host.querySelector(".your-links");
  }

  /** @deprecated use renderCollapsed + bindShell in docs-rail */
  function appendCollapsed(host) {
    host.insertAdjacentHTML("beforeend", renderCollapsed());
    bindShell(host.querySelector(".your-links:last-of-type"));
  }

  window.MembraneYourLinks = {
    mount,
    appendCollapsed,
    renderCollapsed,
    bindShell,
    load,
    addLink,
    detectTrack,
  };

  // cross-tab sync — a batch re-verify (or watch/unwatch) in one tab updates every
  // other open tab: the storage event fires only in OTHER tabs, exactly what we need
  window.addEventListener("storage", (e) => {
    if (e && e.key && !/^membraneYour(Audits|Verifications|Links)$/.test(e.key)) return;
    updateBelt();
    mountNavChip();
    document.querySelectorAll(".your-audits").forEach((s) => {
      audUpdateSummary(s);
      if (s.open) audRender(s);
    });
    document.querySelectorAll(".your-links").forEach((s) => {
      const l = s.querySelector(".your-links-list");
      const d = s.querySelector(".your-links-drop");
      if (l && d) renderList(l, d);
    });
  });

  // the toolbelt, signing-page tags, watch chip, and snapshot age mount on every page
  lacquer();
  buildToolbelt();
  standardizeFooter();
  decorateSigningLinks();
  mountNavChip();
  mountFreshness();
  restoreSplit();
  // framed pages keep decorating dynamically rendered links (concern router etc.)
  if (FRAMED) observeMainLinks();
})();
