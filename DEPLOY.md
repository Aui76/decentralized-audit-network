# Deploying the UI (for judges / a live link)

The `ui/` folder is a **static site** — plain HTML/JS/CSS. It talks to the public Base Sepolia RPC
(`https://sepolia.base.org`) directly via `fetch`, with **no build step, no `node_modules`, no server code**. So
it hosts anywhere that serves static files. The audit list loads from the bundled snapshot (`ui/view-model.js`);
the "Reproduce it now" button verifies live against Base Sepolia.

> Deploy the **`ui/` directory only** — not the repo root (which also has `cell/`, `tools/`, etc.).
> Put the resulting URL in your ETHGlobal submission's **"live demo"** field.

---

## Option A — Vercel (recommended, ~5 min)

1. Go to [vercel.com](https://vercel.com) → sign in with GitHub → **Add New… → Project**.
2. Import the **`decentralized-audit-network`** repo.
3. Set:
   - **Root Directory** → `ui`
   - **Framework Preset** → **Other**
   - **Build Command** → *leave empty*
   - **Output Directory** → *leave empty* (it serves `ui/` as-is)
4. **Deploy.** You get a URL like `https://dan-xxxx.vercel.app`.
5. Open `…vercel.app/explorer.html` to confirm.

## Option B — Netlify (also ~5 min)

1. [app.netlify.com](https://app.netlify.com) → **Add new site → Import an existing project** → GitHub → the repo.
2. Set:
   - **Base directory** → `ui`
   - **Build command** → *empty*
   - **Publish directory** → `ui` (or `.` relative to base)
3. **Deploy site** → you get a `…netlify.app` URL. Confirm at `/explorer.html`.

*(Netlify drag-and-drop also works — but drag a copy of `ui/` **without** `node_modules`, or the upload is huge and slow. The Git import above avoids that, since `node_modules` is gitignored.)*

## Option C — GitHub Pages (fallback; fiddlier for a subfolder)

Pages serves from a branch root or `/docs`, so a subfolder needs a small Action. Create
`.github/workflows/pages.yml`:

```yaml
name: Deploy UI to Pages
on:
  push: { branches: [main] }
permissions: { contents: read, pages: write, id-token: write }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: { name: github-pages, url: "${{ steps.deployment.outputs.page_url }}" }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with: { path: ui }        # publish only the ui/ folder
      - id: deployment
        uses: actions/deploy-pages@v4
```

Then repo **Settings → Pages → Source: GitHub Actions**. Push → it deploys to
`https://aui76.github.io/decentralized-audit-network/explorer.html`.

---

## After deploying — 30-second check

- Open `<your-url>/explorer.html` → the audit list (#0–#13) should render.
- Click a row → detail panel + **Reproduce it now** button appear; the verify runs read-only against Base Sepolia.
- Spot-check `index.html`, `auditor.html`, `verifier.html` load.

## Notes

- **Public RPC is fine for a demo** but rate-limited. If judging traffic is heavy, swap `https://sepolia.base.org`
  for a free dedicated Base Sepolia RPC (Alchemy/Infura) — it's referenced in `ui/verify-core.mjs`
  (`rpcUrl` default) and the app's config; not required for the hackathon.
- **If you redeploy the cell** before the event, the live addresses change — re-point the UI's cell address /
  `view-model.js` snapshot at the new deployment, then redeploy the site.
- No secrets are involved — the UI is read-only and holds no keys.
