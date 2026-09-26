# DAN — Decentralized Audit Network

**▶ Live demo:** **https://decentralized-audit-network.vercel.app/explorer.html** — the on-chain audit explorer,
running live against Base Sepolia. No install needed; just open it.

**The problem.** When a smart contract is "audited" today, you're trusting a firm's PDF — you can't check it
yourself, and money still gets stolen from audited contracts.

**What we built.** DAN turns an audit into something anyone can verify. An auditor runs a tool and posts the
result on-chain; anyone can re-run the same tool and confirm it — no trust needed. If someone finds a bug the
auditor missed, they prove it on-chain and get paid from an escrow. Every rule is binary and automatic: no
committee, no reputation, no "trust me."

**It's real and live.** Full protocol in Solidity (Foundry-tested), deployed on **Base Sepolia** testnet. A
browser UI shows the whole audit lifecycle — submit → audit → confirm → claim → payout — reading straight from
the chain.

**Who.** Solo, built AI-assisted (vibe-coded) end to end.

> **One-liner:** DAN makes smart-contract audits verifiable by anyone instead of "trust the auditor" — the
> auditor posts a re-runnable result on-chain, and bug-hunters get paid from escrow to catch what's missed.

---

## What's in this repo

| Path | What |
|------|------|
| `cell/contracts/` | The protocol — `AuditCell`, `CellToken`, `CellEscrow`, `IssuanceModule`, and the L1 satellites (spec arbiter, integrity review, assignment, structural upgrades, claim/dispute). |
| `cell/test/` | Foundry test suite, including **resistance tests** that drive attack scenarios against the contracts and assert they fail (Sybil rings, claim-drain, mint-farming, escrow solvency, founder vesting). |
| `cell/script/` | Deploy + wiring scripts (Foundry). |
| `ui/` | The browser front end — an on-chain explorer plus participant flows (auditor, protocol, verifier, bug-hunter), reading live from the deployed cell. Open `ui/explorer.html`. |
| `tools/` | The re-runnable audit tools + their manifests — the checks anyone can run to independently confirm an audit result. This is what makes "don't trust, verify" literal: the UI's "reproduce this audit yourself" links point here. |
| `tools/dan-check.mjs` | One command that asks the live cell whether a settled audit covers the code at any address. See *Check any contract* below. |
| `deployments/` | Live Base Sepolia addresses + genesis/lifecycle transaction hashes (public on-chain data). |

---

## Run it

**Contracts + tests** (needs [Foundry](https://book.getfoundry.sh/)):

```bash
cd cell
forge install foundry-rs/forge-std   # fetch the test dependency
forge build
forge test
```

**UI** — easiest is the [**live demo**](https://decentralized-audit-network.vercel.app/explorer.html) (nothing to
install). To run it locally instead (static — any local server):

```bash
cd ui
npx serve .        # or: python3 -m http.server
# then open explorer.html
```

---

## Check any contract

`tools/dan-check.mjs` hashes the code at an address and asks the live cell whether a settled audit row carries
that hash. You need Node 18 or later and nothing else. It has no dependencies and it only reads.

```bash
node tools/dan-check.mjs --cell 0xb034F198869726c36965B95879eCB65Bdb1076c9 --home-rpc https://sepolia.base.org --deep --target 0xYOURS
```

If the address lives on another chain, add `--target-rpc` with an endpoint for that chain. You get one of three
answers. CLEAN is exit 0: a row passed that exact code and its claim window closed with no claim. REFUSE is exit 1:
no row carries the hash, or the row went bad. CANNOT VERIFY is exit 2: a read failed or the row hasn't settled yet.
CLEAN never means safe, only that nobody had claimed a flaw as of the block it prints.

When I ran it on 25 September 2026 the cell had filed one row, its genesis audit. So almost any address you try
will come back REFUSE, because nobody has filed a row for it yet.

---

## Status & honesty

Live on Base Sepolia (testnet). The economics are stress-tested: confirmed attacks were reproduced against the
real contracts, fixed, and re-proven to lose money — the resistance tests here are part of that. Known,
lower-priority items are tracked and gated to mainnet; nothing is claimed "unbreakable." Mainnet follows once the
fixes are deployed and proven.

The contracts in this tree are newer than the live cell. I deployed the cell at `0xb034F198869726c36965B95879eCB65Bdb1076c9`
on 13 September 2026, and all 12 of its contracts are verified on Sourcify, so the exact source it runs is readable
there. After that deploy I changed 11 contract files, the last on 18 September, and this tree carries those
changes. If you compile it you get the next cell's bytecode, not the live one's. `deployments/84532-cell.json` lists
the live addresses. The source commit it records is in my private tree, not in this one.

## License

**Dual-licensed** — see [`NOTICE`](NOTICE) for the exact map.

- **The settlement core** (`AuditCell`, the cell libraries, the settlement satellites) is **BUSL-1.1** ([`LICENSE`](LICENSE)) — read it, fork it, run it non-production freely; production use needs a commercial licence (akerve@gmail.com); converts to **GPL-2.0-or-later** on **2030-06-24**.
- **The integration surface** — the interfaces, the **re-runnable audit tools**, the EIP-712 reference, the test targets, `tools/` and `ui/` — is **MIT** ([`LICENSE-MIT`](LICENSE-MIT)).

In short: **verify us, integrate with us, build organs and indexers on us — freely.** The only thing the licence asks is that you don't fork the settlement core and run it as a competing network without talking to us. Each file's SPDX header governs.
