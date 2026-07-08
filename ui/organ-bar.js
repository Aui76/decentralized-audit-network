/**
 * organ-bar.js — DAN organism strip (L2 / membrane).
 * A slim top banner drawn in the right-rail idiom: DAN as a body of organs.
 * Each organ lights when its contract resolves live on-chain (address present + nonzero
 * in the deployment truth JSON). No manual flag — reality drives lit/dim. Future organs
 * added to ORGANS render dim until their address lands in the JSON, then auto-light.
 * Self-mounting: include <script src="organ-bar.js?v=4"> once per page; it prepends the strip.
 */
(function () {
  if (window.self !== window.top) return;            // never inside the split-view iframe
  if (document.querySelector('.organ-bar')) return;  // idempotent

  // Anatomy roster (labels + order). Lit/dim is NOT set here — it comes from the address.
  var ORGANS = [
    { key: 'AuditCell',            label: 'Audit Cell',        abbr: 'CELL', anchor: true },
    { key: 'CellToken',            label: 'AUDIT token',       abbr: 'TKN'  },
    { key: 'CellEscrow',           label: 'Escrow',            abbr: 'ESC'  },
    { key: 'IssuanceModule',       label: 'Issuance',          abbr: 'ISS'  },
    { key: 'AssignmentModule',     label: 'Assignment',        abbr: 'ASN'  },
    { key: 'ClaimDisputeModule',   label: 'Claim / Dispute',   abbr: 'DSP'  },
    { key: 'SpecArbiterModule',    label: 'Spec Arbiter',      abbr: 'ARB'  },
    { key: 'SpecGapModule',        label: 'Spec Gap',          abbr: 'GAP'  },
    { key: 'IntegrityReviewModule',label: 'Integrity Review',  abbr: 'INT'  },
    { key: 'StructuralUpgradeModule',label: 'Structural',      abbr: 'STR'  },
    { key: 'BlockhashEntropy',     label: 'Entropy',           abbr: 'ENT'  },
    { key: 'FmeaRegistry',         label: 'FMEA Registry',     abbr: 'FMEA' }
  ];
  var ZERO = '0x0000000000000000000000000000000000000000';
  function live(a) { return !!a && /^0x[0-9a-fA-F]{40}$/.test(a) && a.toLowerCase() !== ZERO; }
  function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

  // Fallback address source: whatever the page's view-model exposes (index has none → {}).
  function fromModel() {
    var m = (window.__MODEL && window.__MODEL.meta) || {};
    return {
      AuditCell: m.cell, CellToken: m.cellToken,
      IntegrityReviewModule: m.integrityReviewModule, SpecArbiterModule: m.specArbiterModule,
      FmeaRegistry: m.fmeaRegistry
    };
  }
  function scanBase(addrs) {
    var chain = (window.__MODEL && window.__MODEL.meta && window.__MODEL.meta.chainId) || 84532;
    return 'https://sepolia.basescan.org/address/';
  }

  // which organ is this page about? page can declare <body data-organ="Key">; else filename map.
  var PAGE_ORGAN = {
    'index.html': 'AuditCell', 'explorer.html': 'AuditCell', 'network-qa.html': 'AuditCell',
    'concern.html': 'AuditCell', 'manage.html': 'AuditCell', 'auditor.html': 'AuditCell',
    'verifier.html': 'AuditCell', 'want-board.html': 'AuditCell',
    'economy.html': 'IssuanceModule',
    'tokenomics.html': 'CellToken', 'demo-pool.html': 'CellToken',
    'protocol.html': 'CellEscrow', 'post.html': 'CellEscrow',
    'bughunter.html': 'ClaimDisputeModule'
  };
  // docs filename-prefix → organ (the doc pages that clearly describe one organ)
  var PREFIX_ORGAN = [
    ['docs-economy', 'IssuanceModule'],
    ['docs-flows-spec-arbiter', 'SpecArbiterModule'],
    ['docs-flows-spec-gap', 'SpecGapModule'],
    ['docs-flows-integrity-review', 'IntegrityReviewModule'],
    ['docs-structural', 'StructuralUpgradeModule'],
    ['docs-participants-assignment', 'AssignmentModule'],
    ['docs-flows-disputes', 'ClaimDisputeModule'],
    ['docs-disputes', 'ClaimDisputeModule']
  ];
  function currentOrgan() {
    var declared = document.body.getAttribute('data-organ');
    if (declared) return declared;
    var here = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    if (PAGE_ORGAN[here]) return PAGE_ORGAN[here];
    for (var i = 0; i < PREFIX_ORGAN.length; i++) {
      if (here.indexOf(PREFIX_ORGAN[i][0]) === 0) return PREFIX_ORGAN[i][1];
    }
    return '';
  }

  function render(addrs) {
    addrs = addrs || {};
    var current = currentOrgan();
    var liveCount = 0;
    var chips = ORGANS.map(function (o) {
      var a = addrs[o.key];
      var on = live(a);
      if (on) liveCount++;
      var isCur = (o.key === current);
      var cls = 'ob-organ' + (o.anchor ? ' anchor' : '') + (on ? ' live' : ' dim') + (isCur ? ' current' : '');
      var title = o.label + (on ? ' · ' + a : ' · not deployed') + (isCur ? ' · you are here' : '');
      var inner = '<span class="d"></span><span class="ob-abbr">' + esc(o.abbr) + '</span>';
      return on
        ? '<a class="' + cls + '" href="https://sepolia.basescan.org/address/' + esc(a) + '" target="_blank" rel="noopener" title="' + esc(title) + '">' + inner + '</a>'
        : '<span class="' + cls + '" title="' + esc(title) + '">' + inner + '</span>';
    }).join('');

    var bar = document.createElement('div');
    bar.className = 'organ-bar';
    bar.setAttribute('aria-label', 'Decentralized Audit Network — live organs');
    bar.innerHTML =
      '<span class="ob-organs">' + chips + '</span>' +
      '<span class="ob-right">' +
        '<span class="ob-count">' + liveCount + '/' + ORGANS.length + ' organs live · Base Sepolia</span>' +
        '<span class="ob-brand"><span class="pulse"></span>Decentralized Audit Network</span>' +
      '</span>';
    document.body.insertBefore(bar, document.body.firstChild);
    document.body.classList.add('has-organ-bar'); // lets fixed elements offset below the bar
  }

  // Reality source: the deployment truth JSON (generated at deploy, not hand-edited).
  // Try local-first (public export serves ui/ as web root → ./deployments), then the
  // network-membrane sibling path (../deployments), then the bundled model as last resort.
  var PATHS = ['./deployments/84532-cell.json', '../deployments/84532-cell.json'];
  (function tryPath(i) {
    if (i >= PATHS.length) { render(fromModel()); return; }
    fetch(PATHS[i])
      .then(function (r) { if (!r.ok) throw 0; return r.json(); })
      .then(function (j) { render(j); })
      .catch(function () { tryPath(i + 1); });
  })(0);
})();
