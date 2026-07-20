# Missionite website — architecture plan

## Shape

- **Fully static site**, deployed to **GitHub Pages**. No bundler, no framework, no
  build step — plain HTML/CSS with a little `window.*`-globals JavaScript for auth.
- Deploy on push to `main` via `.github/workflows/deploy.yml` (checkout with
  `submodules: recursive`, upload the repo root, `deploy-pages`).

## Auth substrate

- Identity/auth comes from the shared **auth_db** repo, consumed as a git submodule at
  `lib/auth_db` and loaded via `window.SupabaseConfig` / `window.AuthService` /
  `window.AuthGuard`. Never modified from this repo.
- This site talks to its **own dedicated Supabase project** (not shared with the other
  apps). Site config lives in `js/supabase-config.js`; the form glue in `js/site-auth.js`.

## Access model — invite-only demo phase

- **No public registration anywhere.** The site offers **sign-in only**.
- Every download call-to-action reads **"Sign in to download"**, with a quiet note that
  access is invite-only and a mailto to request a demo account.
- Accounts are created out-of-band (by invitation); the site never renders a sign-up form.

## Releases

- Build binaries live as **assets on GitHub Releases of the private ECSS_framework repo**; Supabase keeps auth, the release catalog, and the download audit.
- A **`get-download` edge function** authorizes the signed-in user and returns a
  short-lived signed URL for the requested build — the binary is never a public link.
- Download events (time + which build) are recorded for the demo; project data stays on
  the user's machine.

## Design

- **Light theme throughout.** Deep-blue accent `#1F4E79`, Inter type, generous
  whitespace, hairline borders, soft radii. Design system centralized in `styles.css`
  under a fixed class contract so every page — including the auth pages — stays visually
  consistent.

## Ownership split (this build)

- **Worker A** — scaffold, `styles.css` design system, `index.html`, `privacy.html`,
  `terms.html`, `404.html`, assets, deploy workflow, README/PLAN.
- **Worker B** — `account.html`, `download.html`, `js/site-auth.js`, `js/supabase-config.js`,
  and `supabase/` (schema + `get-download` function + `SETUP.md`).
