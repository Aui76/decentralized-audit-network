/**
 * Demo pool swap — ETH → AUDIT via SwapRouter02 on Base Sepolia (84532).
 * Uniswap's web app does not support this testnet; this uses the live demo router.
 */
(function () {
  const FEE = 10000;
  const SQRT_PRICE_LIMIT = 4295128740n; // MIN_SQRT_RATIO + 1
  const SWAP_SEL = "0x04e45aaf";
  const SCAN = "https://sepolia.basescan.org";
  const DEFAULT_ROUTER = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
  const DEFAULT_WETH = "0x4200000000000000000000000000000000000006";

  const TE = new TextEncoder();
  const M = (1n << 64n) - 1n;
  const RC = [
    0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n,
    0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn,
    0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an,
    0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n,
  ];
  const RHO = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
  const rot = (x, n) => (n === 0n ? x : ((x << n) | (x >> (64n - n))) & M);

  function keccak(input) {
    const S = new Array(25).fill(0n);
    const rate = 136;
    const len = input.length;
    const pl = Math.ceil((len + 1) / rate) * rate;
    const p = new Uint8Array(pl);
    p.set(input);
    p[len] ^= 1;
    p[pl - 1] ^= 0x80;
    for (let o = 0; o < pl; o += rate) {
      for (let i = 0; i < rate / 8; i++) {
        let l = 0n;
        for (let j = 0; j < 8; j++) l |= BigInt(p[o + i * 8 + j]) << (8n * BigInt(j));
        S[i] ^= l;
      }
      for (let r = 0; r < 24; r++) {
        const C = [0, 1, 2, 3, 4].map((x) => S[x] ^ S[x + 5] ^ S[x + 10] ^ S[x + 15] ^ S[x + 20]);
        const D = [0, 1, 2, 3, 4].map((x) => C[(x + 4) % 5] ^ rot(C[(x + 1) % 5], 1n));
        for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) S[x + 5 * y] ^= D[x];
        const B = new Array(25).fill(0n);
        for (let x = 0; x < 5; x++)
          for (let y = 0; y < 5; y++) B[y + 5 * (((2 * x + 3 * y) % 5))] = rot(S[x + 5 * y], BigInt(RHO[x + 5 * y]));
        for (let x = 0; x < 5; x++)
          for (let y = 0; y < 5; y++) S[x + 5 * y] = (B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & B[((x + 2) % 5) + 5 * y])) & M;
        S[0] ^= RC[r];
      }
    }
    const out = new Uint8Array(32);
    for (let i = 0; i < 4; i++) {
      let l = S[i];
      for (let j = 0; j < 8; j++) out[i * 8 + j] = Number((l >> (8n * BigInt(j))) & 0xffn);
    }
    return out;
  }

  const hx = (u) => "0x" + [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
  const fromHex = (h) => {
    h = (h || "").replace(/^0x/, "");
    if (h.length % 2) h = "0" + h;
    const a = new Uint8Array(h.length / 2);
    for (let i = 0; i < a.length; i++) a[i] = parseInt(h.substr(i * 2, 2), 16);
    return a;
  };
  const cat = (a) => {
    const n = a.reduce((s, x) => s + x.length, 0);
    const o = new Uint8Array(n);
    let p = 0;
    for (const x of a) {
      o.set(x, p);
      p += x.length;
    }
    return o;
  };
  const w = () => new Uint8Array(32);
  const u256 = (v) => {
    const b = w();
    let x = BigInt(v);
    for (let i = 31; i >= 0; i--) {
      b[i] = Number(x & 0xffn);
      x >>= 8n;
    }
    return b;
  };
  const addr = (h) => {
    const u = fromHex(h);
    const b = w();
    b.set(u.slice(-20), 12);
    return b;
  };

  function $(id) {
    return document.getElementById(id);
  }

  function log(html) {
    const el = $("demo-swap-log");
    if (el) el.innerHTML = html;
  }

  function parseEth(s) {
    const t = String(s || "").trim();
    if (!t || !/^\d+(\.\d+)?$/.test(t)) throw new Error("Enter a valid ETH amount");
    const [whole, frac = ""] = t.split(".");
    const fracPadded = (frac + "000000000000000000").slice(0, 18);
    return BigInt(whole) * 10n ** 18n + BigInt(fracPadded);
  }

  function buildSwapData(weth, audit, recipient, amountIn) {
    return (
      SWAP_SEL +
      hx(
        cat([
          addr(weth),
          addr(audit),
          u256(FEE),
          addr(recipient),
          u256(amountIn),
          u256(0),
          u256(SQRT_PRICE_LIMIT),
        ])
      ).slice(2)
    );
  }

  async function loadConfig() {
    const r = await fetch("./demo-pool-config.json");
    if (!r.ok) throw new Error("demo pool config missing");
    return r.json();
  }

  async function waitReceipt(h, req) {
    for (let i = 0; i < 120; i++) {
      const rec = await req("eth_getTransactionReceipt", [h]);
      if (rec) return rec;
      await new Promise((s) => setTimeout(s, 2500));
    }
    throw new Error("receipt timeout");
  }

  function syncSwapBtn(W) {
    const btn = $("demo-swap-btn");
    if (!btn) return;
    btn.disabled = !(W && W.isReady());
  }

  async function doSwap(cfg, W) {
    if (!W.account) throw new Error("Connect wallet first");
    if (!W.isReady()) throw new Error("Switch to Base Sepolia");
    if (!W.isRealMetaMask()) throw new Error("Use MetaMask for signing");

    const amountIn = parseEth($("demo-swap-eth")?.value || "0");
    if (amountIn <= 0n) throw new Error("Amount must be > 0");

    const weth = cfg.WETH9 || DEFAULT_WETH;
    const audit = cfg.CellToken;
    const router = cfg.swapRouter02 || DEFAULT_ROUTER;
    const data = buildSwapData(weth, audit, W.account, amountIn);
    const value = "0x" + amountIn.toString(16);

    log("Requesting signature in MetaMask…");
    const hash = await W.req("eth_sendTransaction", [
      { from: W.account, to: router, data, value },
    ]);
    log(`Sent: <a href="${SCAN}/tx/${hash}" target="_blank" rel="noopener">${hash.slice(0, 14)}…</a> — waiting…`);
    const rec = await waitReceipt(hash, W.req);
    if (rec.status === "0x1") {
      log(`<span class="good">Swap confirmed.</span> <a href="${SCAN}/tx/${hash}" target="_blank" rel="noopener">View on Basescan</a>`);
      if (typeof window.__demoPoolRefresh === "function") window.__demoPoolRefresh();
    } else {
      log(`<span class="danger">Swap reverted.</span> <a href="${SCAN}/tx/${hash}" target="_blank" rel="noopener">View on Basescan</a>`);
    }
  }

  document.addEventListener("DOMContentLoaded", async () => {
    const W = window.MembraneWallet;
    if (!W) return;

    W.init({
      root: "#demo-wallet-root",
      onChange: () => syncSwapBtn(W),
    });

    let cfg;
    try {
      cfg = await loadConfig();
    } catch (e) {
      log("Could not load swap config.");
      return;
    }

    syncSwapBtn(W);
    const btn = $("demo-swap-btn");
    if (btn) {
      btn.onclick = () => {
        btn.disabled = true;
        doSwap(cfg, W)
          .catch((e) => log(`<span class="danger">${e.message || e}</span>`))
          .finally(() => syncSwapBtn(W));
      };
    }
  });
})();
