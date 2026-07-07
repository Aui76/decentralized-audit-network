# Put the UI online (the easy way)

The `ui/` folder is a static site — **no build, no config, no secrets.** It reads the public Base Sepolia RPC
directly, so hosting is just "serve these files."

## Vercel — ~1 minute

1. [vercel.com](https://vercel.com) → **Continue with GitHub**.
2. **Add New → Project** → pick **`decentralized-audit-network`**.
3. Set **Root Directory = `ui`** → **Deploy**. (Leave every other setting default.)
4. You get a link like `https://dan-xxxx.vercel.app`. Open `…/explorer.html` to confirm the audit list shows.

Put that link in your ETHGlobal submission's **"live demo"** field. Every `git push` auto-redeploys it.

*(Netlify is identical if you prefer: Add site → import the repo → **Base directory = `ui`** → Deploy.)*

---

**If you redeploy the cell** before the event, update the UI's cell address / `ui/view-model.js` snapshot, then it
auto-redeploys on push. Nothing else to do.
