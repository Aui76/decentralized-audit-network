/**
 * Demo pool — live price, LP position stats, address panel (84532).
 */
import {
  amountsForPosition,
  decodePosition,
  decodeSignedTick,
} from "./demo-pool-v3.mjs";

(function () {
  const RPC = "https://sepolia.base.org";
  const SLOT0_SELECTOR = "0x3850c7bd";
  const BALANCE_OF_SELECTOR = "0x70a08231";
  const POSITIONS_SELECTOR = "0x99fbab88";
  const WETH9 = "0x4200000000000000000000000000000000000006";
  const NPM = "0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2";
  const MIN_SQRT = 4295128739n + 1n;
  const SCAN = "https://sepolia.basescan.org";
  const TOKEN_DECIMALS = 18;
  const REFRESH_MS = 60_000;

  let depCache = null;
  let addrsRendered = false;

  function $(id) {
    return document.getElementById(id);
  }

  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  async function ethCall(to, data) {
    const res = await fetch(RPC, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to, data }, "latest"],
      }),
    });
    const j = await res.json();
    if (j.error) throw new Error(j.error.message || "eth_call failed");
    return j.result;
  }

  function decodeSlot0(hex) {
    const h = hex.replace(/^0x/, "");
    const sqrtPriceX96 = BigInt("0x" + h.slice(0, 64));
    const tick = decodeSignedTick("0x" + h.slice(64, 128));
    return { sqrtPriceX96, tick };
  }

  function priceAuditPerEth(sqrtPriceX96, auditIsToken1) {
    if (sqrtPriceX96 <= MIN_SQRT) return 0;
    const Q96 = 2n ** 96n;
    const ratio = Number(sqrtPriceX96 * sqrtPriceX96) / Number(Q96 * Q96);
    if (auditIsToken1) return ratio;
    return ratio > 0 ? 1 / ratio : 0;
  }

  function padAddress(addr) {
    return addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  }

  async function tokenBalance(token, holder) {
    const hex = await ethCall(token, BALANCE_OF_SELECTOR + padAddress(holder));
    return BigInt(hex);
  }

  function formatTokenAmount(raw, symbol, maxFrac = 4) {
    const base = 10n ** BigInt(TOKEN_DECIMALS);
    const whole = raw / base;
    const frac = raw % base;
    let text;
    if (frac === 0n) {
      text = whole.toLocaleString(undefined, { maximumFractionDigits: 0 });
    } else {
      const fracStr = frac.toString().padStart(TOKEN_DECIMALS, "0").slice(0, maxFrac).replace(/0+$/, "");
      text = fracStr
        ? `${whole.toLocaleString(undefined, { maximumFractionDigits: 0 })}.${fracStr}`
        : whole.toLocaleString(undefined, { maximumFractionDigits: 0 });
    }
    return `${text} ${symbol}`;
  }

  function formatWethAmount(raw) {
    const n = Number(raw) / 10 ** TOKEN_DECIMALS;
    if (!Number.isFinite(n) || n <= 0) return "0 WETH";
    return `${n.toLocaleString(undefined, { maximumFractionDigits: 4 })} WETH`;
  }

  function tvlInWeth(wethRaw, auditRaw, auditPerEth) {
    const weth = Number(wethRaw) / 10 ** TOKEN_DECIMALS;
    const audit = Number(auditRaw) / 10 ** TOKEN_DECIMALS;
    if (auditPerEth > 1e-6 && audit > 1e-9) {
      const auditAsWeth = audit / auditPerEth;
      if (Number.isFinite(auditAsWeth) && auditAsWeth >= 0 && auditAsWeth < 1e9) {
        return weth + auditAsWeth;
      }
    }
    return weth;
  }

  async function loadDeployment() {
    if (depCache) return depCache;
    const local = await fetch("./demo-pool-config.json");
    if (local.ok) {
      depCache = await local.json();
      return depCache;
    }
    const vm = window.__MODEL?.meta?.demoLp;
    if (vm?.demoLpPool) {
      depCache = { CellToken: window.__MODEL.meta.cellToken, ...vm };
      return depCache;
    }
    const r = await fetch("./view-model.json");
    if (r.ok) {
      const m = await r.json();
      if (m.meta?.demoLp?.demoLpPool) {
        depCache = { CellToken: m.meta.cellToken, ...m.meta.demoLp };
        return depCache;
      }
    }
    const dep = await fetch("../deployments/84532-cell.json");
    if (!dep.ok) throw new Error("demo pool config missing");
    depCache = await dep.json();
    return depCache;
  }

  async function readPositionAmounts(dep, sqrtPriceX96, tick) {
    const tokenId = BigInt(dep.demoLpPositionId || 0);
    const npm = dep.nonfungiblePositionManager || NPM;
    if (tokenId <= 0n) return { amount0: 0n, amount1: 0n, tokenId: null };

    const idHex = tokenId.toString(16).padStart(64, "0");
    const posHex = await ethCall(npm, POSITIONS_SELECTOR + idHex);
    const pos = decodePosition(posHex);
    const amts = amountsForPosition(pos.liquidity, pos.tickLower, pos.tickUpper, sqrtPriceX96, tick);
    return {
      amount0: amts.amount0 + pos.tokensOwed0,
      amount1: amts.amount1 + pos.tokensOwed1,
      tokenId: tokenId.toString(),
    };
  }

  function addrRow(label, addr, kind) {
    if (!addr) return "";
    const url = `${SCAN}/${kind}/${addr}`;
    return (
      `<div class="demo-addr">` +
      `<span class="demo-addr-label">${esc(label)}</span>` +
      `<a class="demo-addr-link mono" href="${url}" target="_blank" rel="noopener">${esc(addr)}</a>` +
      `</div>`
    );
  }

  function txRow(label, hash) {
    if (!hash) return "";
    return (
      `<div class="demo-addr">` +
      `<span class="demo-addr-label">${esc(label)}</span>` +
      `<a class="demo-addr-link" href="${SCAN}/tx/${esc(hash)}" target="_blank" rel="noopener">View on Basescan</a>` +
      `</div>`
    );
  }

  function renderAddresses(dep) {
    const list = $("demo-addrs-list");
    const section = $("demo-addrs");
    if (!list || !section) return;
    const weth = dep.WETH9 || WETH9;
    list.innerHTML =
      addrRow("AUDIT token", dep.CellToken, "address") +
      addrRow("WETH", weth, "address") +
      addrRow("Uniswap pool", dep.demoLpPool, "address") +
      txRow("Example swap", dep.demoLpSwapTx);
    section.hidden = !dep.demoLpPool;
  }

  function renderPoolStats(stats, auditPerEth) {
    const section = $("demo-stats");
    const wethEl = $("stat-weth");
    const auditEl = $("stat-audit");
    const tvlEl = $("stat-tvl");
    const detailEl = $("stat-detail");
    const noteEl = $("stat-note");
    const updatedEl = $("stat-updated");
    if (!section || !wethEl || !auditEl || !tvlEl) return;

    wethEl.textContent = formatTokenAmount(stats.totalWeth, "WETH");
    auditEl.textContent = formatTokenAmount(stats.totalAudit, "AUDIT", 2);
    tvlEl.textContent = formatWethAmount(
      BigInt(Math.round(tvlInWeth(stats.totalWeth, stats.totalAudit, auditPerEth) * 10 ** TOKEN_DECIMALS))
    );

    if (detailEl) {
      detailEl.textContent =
        `LP position #${stats.positionId} (Uniswap accounting): ${formatTokenAmount(stats.posWeth, "WETH")} + ${formatTokenAmount(stats.posAudit, "AUDIT", 2)}`;
    }
    if (noteEl) {
      noteEl.textContent =
        "Swapping ETH buys AUDIT — it does not deposit ETH into the pool. When AUDIT is sold out, the router swaps what it can and refunds the rest to your wallet. Refreshes every minute.";
    }
    if (updatedEl) {
      updatedEl.textContent = "Last updated " + new Date().toLocaleTimeString();
    }
    section.hidden = false;
  }

  async function refresh() {
    const status = $("pool-status");
    const priceEl = $("pool-price");
    const statsSection = $("demo-stats");
    try {
      const dep = await loadDeployment();
      const pool = dep.demoLpPool;
      const audit = dep.CellToken;
      const weth = dep.WETH9 || WETH9;
      if (!addrsRendered) {
        renderAddresses(dep);
        addrsRendered = true;
      }

      if (!pool || !pool.startsWith("0x") || pool.length < 42) {
        status.textContent = "Demo pool not set up yet.";
        priceEl.textContent = "—";
        if (statsSection) statsSection.hidden = true;
        return;
      }

      const slotHex = await ethCall(pool, SLOT0_SELECTOR);
      const { sqrtPriceX96, tick } = decodeSlot0(slotHex);

      const [looseWeth, looseAudit, pos] = await Promise.all([
        tokenBalance(weth, pool),
        tokenBalance(audit, pool),
        readPositionAmounts(dep, sqrtPriceX96, tick),
      ]);

      // balanceOf(pool) is the physical total; position amounts are the LP NFT's share (subset, not additive).
      const totalWeth = looseWeth;
      const totalAudit = looseAudit;
      const auditPerEth = priceAuditPerEth(sqrtPriceX96, true);

      if (sqrtPriceX96 <= MIN_SQRT) {
        priceEl.textContent = "below range (AUDIT sold out at this tier)";
        status.textContent = "Live on Base Sepolia — AUDIT side depleted; big swaps mostly refund unused ETH.";
      } else {
        priceEl.textContent =
          auditPerEth > 0
            ? `~${auditPerEth.toLocaleString(undefined, { maximumFractionDigits: 2 })} AUDIT / ETH`
            : "—";
        status.textContent = "Live on Base Sepolia.";
      }
      renderPoolStats(
        {
          looseWeth,
          looseAudit,
          posWeth: pos.amount0,
          posAudit: pos.amount1,
          totalWeth,
          totalAudit,
          positionId: pos.tokenId || "—",
        },
        auditPerEth
      );
    } catch (e) {
      status.textContent = "Could not read pool: " + e.message;
      if (statsSection) statsSection.hidden = true;
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    refresh();
    setInterval(refresh, REFRESH_MS);
  });

  window.__demoPoolRefresh = refresh;
})();
