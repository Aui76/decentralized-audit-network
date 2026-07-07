/* Membrane wallet bar — shared Connect → Network → Ready (Base Sepolia 84532, real MetaMask) */
(function (global) {
  "use strict";

  const CHAIN_HEX = "0x14a34";
  const CHAIN_ID = 84532;
  const BASE_SEPOLIA = {
    chainId: CHAIN_HEX,
    chainName: "Base Sepolia",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: ["https://sepolia.base.org"],
    blockExplorerUrls: ["https://sepolia.basescan.org"],
  };

  let walletProvider = null;
  let account = null;
  let onChange = null;
  let onMultWallet = null;

  const $ = (id) => document.getElementById(id);

  function listProviders() {
    const e = global.ethereum;
    if (!e) return [];
    if (Array.isArray(e.providers) && e.providers.length) return e.providers;
    return [e];
  }

  function chainNum(cid) {
    try {
      const s = String(cid).trim();
      if (!s) return 0;
      if (s.startsWith("0x") || s.startsWith("0X")) return parseInt(s, 16);
      const d = Number(s);
      return Number.isFinite(d) ? d : parseInt(s, 16);
    } catch (e) {
      return 0;
    }
  }

  function chainOk(cid) {
    return chainNum(cid) === CHAIN_ID;
  }

  function isRealMetaMask(p) {
    return (
      p &&
      ((p.isMetaMask && p._metamask) ||
        (p.isMetaMask &&
          !p.isRabby &&
          !p.isBraveWallet &&
          !p.isCoinbaseWallet &&
          !p.isPhantom))
    );
  }

  function pickMetaMask() {
    const ps = listProviders();
    return (
      ps.find((p) => p.isMetaMask && p._metamask) ||
      ps.find(
        (p) =>
          p.isMetaMask &&
          !p.isRabby &&
          !p.isBraveWallet &&
          !p.isCoinbaseWallet &&
          !p.isPhantom
      ) ||
      null
    );
  }

  function eth() {
    return walletProvider || pickMetaMask() || global.ethereum;
  }

  function providerName(p) {
    if (!p) return "?";
    if (p.isRabby) return "Rabby";
    if (p.isBraveWallet) return "Brave";
    if (p.isCoinbaseWallet) return "Coinbase";
    if (p.isPhantom) return "Phantom";
    if (p.isMetaMask && p._metamask) return "MetaMask";
    if (p.isMetaMask) return "MetaMask? (imposter?)";
    return "Wallet";
  }

  function chainHint(cid) {
    const n = chainNum(cid);
    if (n === CHAIN_ID) return "";
    if (n === 11155111)
      return "You are on <b>Ethereum Sepolia</b> — wrong testnet. This site needs <b>Base Sepolia</b> (84532).";
    if (n === 1) return "You are on Ethereum mainnet — switch to Base Sepolia testnet.";
    return "Wrong network (chain " + cid + "). Switch to Base Sepolia (84532).";
  }

  function isUserReject(e) {
    return e?.code === 4001 || String(e?.message || "").includes("User rejected");
  }

  function isUnrecognizedChain(e) {
    const code = e?.code ?? e?.data?.originalError?.code;
    if (code === 4902) return true;
    const msg = String(e?.message || e || "").toLowerCase();
    return msg.includes("unrecognized chain") || msg.includes("4902") || msg.includes("not added");
  }

  function wlog(m) {
    const el = $("walletlog");
    if (el) el.innerHTML = m;
  }

  function req(method, params) {
    return eth().request({ method, params });
  }

  async function auditProviders() {
    const rows = [];
    for (const p of listProviders()) {
      try {
        const cid = await p.request({ method: "eth_chainId", params: [] });
        rows.push({ name: providerName(p), n: chainNum(cid), err: null });
      } catch (e) {
        rows.push({ name: providerName(p), err: "?" });
      }
    }
    return rows;
  }

  async function pinMetaMask(showLog) {
    const ps = listProviders();
    if (!ps.length) {
      if (showLog) wlog('<span class="bad">No browser wallet found.</span>');
      return false;
    }
    const mm = pickMetaMask();
    if (!mm) {
      walletProvider = ps[0];
      if (showLog)
        wlog(
          '<span class="bad"><b>Real MetaMask not found.</b> Disable Rabby, Brave, Coinbase Wallet, etc. and reload.</span>'
        );
    } else {
      walletProvider = mm;
    }
    const audit = await auditProviders();
    if (showLog && audit.length > 1 && onMultWallet) {
      const summary = audit
        .map((r) => (r.err ? r.name + ":?" : r.name + "=" + r.n))
        .join(" · ");
      onMultWallet(
        '<span class="warnc">Wallets detected: ' +
          summary +
          " — using <b>" +
          providerName(walletProvider) +
          "</b> only.</span>"
      );
    }
    const wp = $("wprovider");
    if (wp) {
      wp.textContent = providerName(walletProvider);
      wp.className = "pill " + (mm ? "ok" : "bad");
    }
    return !!mm;
  }

  function stepState() {
    if (!account) return "connect";
    if (!isRealMetaMask(walletProvider)) return "network";
    return chainOkCached ? "ready" : "network";
  }

  let chainOkCached = false;

  function renderSteps() {
    const el = $("wsteps");
    if (!el) return;
    const s = stepState();
    // before connection only the first chip exists; the rest unfold on connect
    el.classList.toggle("wallet-steps--folded", s === "connect");
    el.querySelectorAll(".wstep").forEach((node) => {
      const step = node.getAttribute("data-step");
      node.classList.remove("on", "done");
      if (step === "connect") {
        // description follows state: the step name becomes the state name
        node.textContent = account ? "Connected" : "Connect";
        if (s === "connect") node.classList.add("on");
        else node.classList.add("done");
      }
      if (step === "network") {
        node.textContent = s === "ready" ? "Base Sepolia · 84532" : "Network";
        if (s === "network") node.classList.add("on");
        if (s === "ready") node.classList.add("done");
      }
      if (step === "ready" && s === "ready") node.classList.add("on", "done");
    });
  }

  function syncConnectButton() {
    // same button, same place, both states — only the words change
    const btn = $("connect");
    if (!btn) return;
    btn.textContent = stepState() === "connect" ? "Connect wallet" : "Disconnect";
  }

  async function disconnect() {
    try {
      await req("wallet_revokePermissions", [{ eth_accounts: {} }]);
      // MetaMask fires accountsChanged → page reloads via bindWalletEvents
      setAccount([]);
      chainOkCached = false;
      notify();
      wlog("Disconnected.");
    } catch (e) {
      // wallet doesn't support revoke — drop local state, tell the truth
      setAccount([]);
      chainOkCached = false;
      notify();
      wlog(
        'Disconnected from this page. To fully revoke: MetaMask → <b>⋮ → Connected sites</b> → remove this site.'
      );
    }
  }

  let unfoldChecked = false;
  function maybeUnfold() {
    // cascade when the happy path is reached — once per page load, no theater on wrong network
    if (unfoldChecked || stepState() !== "ready") return;
    unfoldChecked = true;
    const el = $("wsteps");
    if (!el) return;
    Array.from(el.children).forEach((k, i) => k.style.setProperty("--wu-i", String(i)));
    el.classList.add("wallet-steps--unfold");
  }

  function notify() {
    renderSteps();
    syncConnectButton();
    syncSignButtons();
    maybeUnfold();
    if (onChange) onChange(getState());
  }

  function getState() {
    return {
      account,
      chainOk: chainOkCached,
      realMetaMask: isRealMetaMask(walletProvider),
      ready: !!(account && isRealMetaMask(walletProvider) && chainOkCached),
      provider: providerName(walletProvider),
    };
  }

  function syncSignButtons() {
    const ready = getState().ready;
    document.querySelectorAll("[data-requires-wallet]").forEach((btn) => {
      if (btn.dataset.walletLock === "1") btn.disabled = !ready;
    });
  }

  function lockSignButton(btn, locked) {
    if (!btn) return;
    if (locked) {
      btn.dataset.requiresWallet = "1";
      btn.dataset.walletLock = "1";
      btn.disabled = !getState().ready;
    } else {
      delete btn.dataset.walletLock;
    }
  }

  async function ensureBaseSepolia(fromUser) {
    if (!walletProvider || !isRealMetaMask(walletProvider)) {
      if (fromUser)
        wlog(
          '<span class="bad">Cannot switch — real MetaMask not connected. Disable other wallet extensions and reload.</span>'
        );
      return false;
    }
    const nBefore = chainNum(await req("eth_chainId", []));
    if (fromUser)
      wlog(
        "MetaMask reports chain <b>" +
          nBefore +
          "</b> — requesting switch to <b>84532</b>…"
      );
    try {
      await req("wallet_switchEthereumChain", [{ chainId: CHAIN_HEX }]);
    } catch (switchErr) {
      if (isUserReject(switchErr)) {
        if (fromUser)
          wlog(
            '<span class="warn">Switch cancelled — pick <b>Base Sepolia</b> in MetaMask\'s network dropdown. That\'s normal.</span>'
          );
        return false;
      }
      if (isUnrecognizedChain(switchErr)) {
        if (fromUser) wlog("Approve <b>Add Base Sepolia network</b> in MetaMask…");
        try {
          await req("wallet_addEthereumChain", [BASE_SEPOLIA]);
        } catch (addErr) {
          if (isUserReject(addErr)) return false;
          if (fromUser)
            wlog(
              '<span class="bad">Add failed. MetaMask → Settings → Advanced → <b>Show test networks</b>.</span>'
            );
          return false;
        }
        await req("wallet_switchEthereumChain", [{ chainId: CHAIN_HEX }]);
      } else {
        if (fromUser)
          wlog(
            '<span class="bad">Switch failed: ' +
              (switchErr.message || switchErr) +
              "</span>"
          );
        return false;
      }
    }
    const nAfter = chainNum(await req("eth_chainId", []));
    const ok = nAfter === CHAIN_ID;
    if (fromUser) {
      if (ok)
        wlog(
          "MetaMask on chain <b>84532</b>. Confirm the fox icon says <b>Base Sepolia · MetaMask</b> before signing."
        );
      else
        wlog(
          '<span class="bad">MetaMask still on chain <b>' +
            nAfter +
            "</b> — open MetaMask → <b>Base Sepolia</b> (manual switch is fine).</span>"
        );
    }
    return ok;
  }

  async function refreshNet() {
    if (!eth()) {
      const na = $("netactions");
      if (na) na.style.display = "none";
      chainOkCached = false;
      notify();
      return false;
    }
    const cid = await req("eth_chainId", []);
    const n = chainNum(cid);
    const ok = chainOk(cid);
    chainOkCached = ok;
    const via = providerName(walletProvider || eth());
    const net = $("net");
    if (net) {
      net.textContent = ok
        ? "Base Sepolia · 84532 · " + via
        : "chain " + n + " · " + via;
      net.className = "pill " + (ok ? "ok" : "bad");
    }
    const na = $("netactions");
    if (na) na.style.display = ok ? "none" : "flex";
    const note = $("netnote");
    if (note) {
      if (!isRealMetaMask(walletProvider))
        note.innerHTML =
          '<span class="warn">Not talking to real MetaMask — disable other wallet extensions and reload.</span>';
      else if (!ok)
        note.innerHTML =
          chainHint(cid) +
          ' Click <b>Add / switch to Base Sepolia</b>, or pick <b>Base Sepolia</b> in MetaMask once — that\'s normal.';
      else
        note.textContent =
          "Ready on Base Sepolia (84532). Manual switch in MetaMask counts — you're good to sign.";
    }
    notify();
    return ok;
  }

  function bindWalletEvents() {
    if (!eth() || !eth().on) return;
    eth().on("chainChanged", () => location.reload());
    eth().on("accountsChanged", () => location.reload());
  }

  function setAccount(accs) {
    account = accs && accs[0] ? accs[0] : null;
    const ac = $("acct");
    if (ac) {
      if (account) {
        ac.textContent = account.slice(0, 6) + "…" + account.slice(-4);
        ac.className = "pill ok";
      } else {
        ac.textContent = "not connected";
        ac.className = "pill";
      }
    }
  }

  async function connect() {
    if (!listProviders().length) {
      wlog('<span class="bad">No browser wallet found.</span>');
      return;
    }
    try {
      await pinMetaMask(true);
      wlog("Step 1 · approve <b>Connect</b> in MetaMask…");
      const accs = await req("eth_requestAccounts", []);
      setAccount(accs);
      wlog("Step 2 · approve <b>Switch network</b> to Base Sepolia if MetaMask asks…");
      await ensureBaseSepolia(true);
      await refreshNet();
      bindWalletEvents();
    } catch (e) {
      wlog('<span class="bad">Connect failed: ' + (e.message || e) + "</span>");
      throw e;
    }
  }

  async function addNetwork() {
    if (!listProviders().length) {
      wlog('<span class="bad">Install MetaMask first.</span>');
      return;
    }
    await pinMetaMask(true);
    if (!account) {
      try {
        const a = await req("eth_requestAccounts", []);
        setAccount(a);
      } catch (e) {
        wlog("Connect account first.");
        return;
      }
    }
    await ensureBaseSepolia(true);
    await refreshNet();
  }

  async function syncIfConnected() {
    if (!listProviders().length) return;
    try {
      await pinMetaMask(false);
      const accs = await req("eth_accounts", []);
      if (!accs.length) return;
      setAccount(accs);
      await refreshNet();
      bindWalletEvents();
    } catch (e) {
      /* silent */
    }
  }

  function mountHtml() {
    return (
      '<div class="wallet-steps" id="wsteps">' +
      '<span class="wstep" data-step="connect">Connect</span>' +
      '<span class="wstep-arrow">→</span>' +
      '<span class="wstep" data-step="network">Network</span>' +
      '<span class="wstep-arrow">→</span>' +
      '<span class="wstep" data-step="ready">Ready</span>' +
      '<span id="acct" class="pill">not connected</span>' +
      '<span id="wprovider" class="pill">—</span>' +
      "</div>" +
      '<div class="row">' +
      '<button type="button" id="connect">Connect wallet</button>' +
      "</div>" +
      '<p class="tiny wallet-netline"><b>Network:</b> <b>Base Sepolia</b> (chain id <span class="mono">84532</span>) — not Ethereum Sepolia (<span class="mono">11155111</span>).</p>' +
      '<div class="row" id="netactions" style="margin-top:6px;display:none">' +
      '<button type="button" class="sec" id="addNetwork">Add / switch to Base Sepolia</button>' +
      "</div>" +
      '<p class="tiny" id="netnote" style="margin:8px 0 0"></p>' +
      '<p class="tiny" id="walletlog" style="margin:6px 0 0;color:var(--mut)"></p>'
    );
  }

  function init(opts) {
    opts = opts || {};
    onChange = opts.onChange || null;
    onMultWallet = opts.onMultWallet || null;
    const root = opts.root ? document.querySelector(opts.root) : null;
    if (root) root.innerHTML = mountHtml();
    const btn = $("connect");
    const add = $("addNetwork");
    if (btn)
      btn.onclick = () => {
        if (stepState() === "connect") connect().catch(() => {});
        else disconnect();
      };
    if (add) add.onclick = () => addNetwork();
    renderSteps();
    syncConnectButton();
    syncIfConnected();
    return api;
  }

  const api = {
    CHAIN_ID,
    CHAIN_HEX,
    init,
    mountHtml,
    get account() {
      return account;
    },
    get ready() {
      return getState().ready;
    },
    isReady: () => getState().ready,
    isRealMetaMask: () => isRealMetaMask(walletProvider),
    getState,
    eth,
    req,
    ensureBaseSepolia,
    refreshNet,
    lockSignButton,
    syncSignButtons,
    wlog,
  };

  global.MembraneWallet = api;
})(typeof window !== "undefined" ? window : globalThis);
