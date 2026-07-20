# Missionite — website

The marketing and access site for **Missionite**, a desktop tool that assembles and
tracks a space project's ECSS document set across review milestones — living documents,
verification matrix, delivery packages.

It is a **fully static site** (no bundler, no framework, no build step) deployed to
**GitHub Pages**. During the demo phase, downloads are **invite-only**: the site offers
sign-in only — there is no public registration anywhere.

## Layout

```
index.html            Landing page
privacy.html          Privacy (invite-only demo)
terms.html            Evaluation terms
404.html              Not-found page
account.html          Sign in (invite-only — no registration)
download.html         Signed-in downloads via the get-download broker
styles.css            Shared design system (the CSS contract)
assets/               Logo mark, favicon, source icon, app screenshot
js/                   Site auth glue + Supabase config (see "Configuration")
lib/auth_db/          Shared auth substrate — git submodule (see below)
supabase/             Backend setup for this project's Supabase (see SETUP.md)
.github/workflows/    GitHub Pages deploy
```

## Auth substrate (submodule)

Auth is provided by the shared **auth_db** repo, consumed as a git submodule at
`lib/auth_db` and loaded through `window.*` globals (`window.SupabaseConfig`,
`window.AuthService`) — no bundler. It is declared in `.gitmodules`; after cloning run:

```bash
git submodule update --init
```

Do not edit anything under `lib/auth_db` from this repo — it is shared and owned upstream.

The deploy checks it out with `submodules: recursive` (see `.github/workflows/deploy.yml`).

## Local preview

No build step — just serve the folder from its root:

```bash
python3 -m http.server 8000
# then open http://localhost:8000
```

Serving from the repo root matters so that `lib/auth_db/...` script paths resolve.

## Configuration

Site-specific Supabase settings live in **`js/supabase-config.js`** (placeholders —
point `PROJECT_URL` and the publishable/anon key at this site's dedicated Supabase
project). The publishable key is safe to ship client-side; row-level security is the
actual protection. The auth glue that wires the forms to `window.AuthService` lives in
**`js/site-auth.js`**.

## Backend

The Supabase schema and the `get-download` edge function that vends
release binaries to signed-in users are set up per **`supabase/SETUP.md`**.

## Deployment

One-time: repo **Settings → Pages → Source: GitHub Actions** (with the default
branch-based source, Pages runs its own Jekyll build, which cannot resolve the
submodule and fails).

Then just push to `main`. The workflow checks out (with submodules), uploads the
repository root as the Pages artifact, and deploys — no build step.

## Releases

Demo binaries live as assets on GitHub Releases of the private `ECSS_framework`
repo. After each app publish, catalog them for the download page with
`supabase/register-release.sh <tag>` (see `supabase/SETUP.md`).
