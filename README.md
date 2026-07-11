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

## Status & honesty

Live on Base Sepolia (testnet). The economics are stress-tested: confirmed attacks were reproduced against the
real contracts, fixed, and re-proven to lose money — the resistance tests here are part of that. Known,
lower-priority items are tracked and gated to mainnet; nothing is claimed "unbreakable." Mainnet follows once the
fixes are deployed and proven.

## License

**Dual-licensed** — see [`NOTICE`](NOTICE) for the exact map.

- **The settlement core** (`AuditCell`, the cell libraries, the settlement satellites) is **BUSL-1.1** ([`LICENSE`](LICENSE)) — read it, fork it, run it non-production freely; production use needs a commercial licence (akerve@gmail.com); converts to **GPL-2.0-or-later** on **2030-06-24**.
- **The integration surface** — the interfaces, the **re-runnable audit tools**, the EIP-712 reference, the test targets, `tools/` and `ui/` — is **MIT** ([`LICENSE-MIT`](LICENSE-MIT)).

In short: **verify us, integrate with us, build organs and indexers on us — freely.** The only thing the licence asks is that you don't fork the settlement core and run it as a competing network without talking to us. Each file's SPDX header governs.
