# Missionite — website

The access site for **Missionite**, a desktop tool that assembles and tracks a space
project's ECSS document set across review milestones — living documents, verification
matrix, delivery packages. The desktop app itself lives in the private
`ECSS_framework` repo; this repo is the website and its Supabase backend.

It is a **fully static site** (no bundler, no framework, no build step) deployed to
**GitHub Pages**. There is no marketing content: `index.html` is a single gated page —
a signed-out visitor sees only the sign-in card, a signed-in user sees the download
workspace. Access is **invite-only**; there is no public registration anywhere.

## Layout

```
src/                    The deployed site — this folder IS the Pages artifact root
  index.html            The whole site: sign-in gate + download workspace
  privacy.html          Privacy (invite-only demo)
  terms.html            Evaluation terms
  404.html              Not-found page
  styles.css            Shared design system (the CSS contract)
  assets/               Logo mark, favicon, app-icon source artwork
  js/                   Site auth glue + Supabase config (see "Configuration")
  lib/auth_db/          Shared auth substrate — git submodule (see below)
supabase/               Backend definition (see below)
  sql/                  schema.sql, live-config-checks.sql
  functions/            activate + get-download edge functions
  queries/              Copy-paste operator SQL (grant, revoke, pin, status, floor)
docs/                   SETUP.md, DEPLOY_RUNBOOK.md, LIVE_CONFIG_CHECKS.md
scripts/                register-release.sh
.github/workflows/      GitHub Pages deploy
```

Nothing outside `src/` is deployed. Every `src=`/`href=` in the pages is relative and
stays inside `src/`, so the folder serves standalone.

## Auth substrate (submodule)

Auth is provided by the shared **auth_db** repo, consumed as a git submodule at
`src/lib/auth_db` and loaded through `window.*` globals (`window.SupabaseConfig`,
`window.AuthService`) — no bundler. It is declared in `.gitmodules`; after cloning run:

```bash
git submodule update --init
```

Do not edit anything under `src/lib/auth_db` from this repo — it is shared and owned
upstream. `src/js/site-auth.js` neuters `AuthService._redirectToSignIn` at load: the
submodule bounces signed-out visitors to a login page this site does not have, and the
gate is rendered in-page instead.

The deploy checks it out with `submodules: recursive` (see `.github/workflows/deploy.yml`).

## Local preview

No build step — serve `src/`, which is what Pages serves:

```bash
python3 -m http.server 8000 --directory src
# then open http://localhost:8000
```

Serving from `src/` matters so that `lib/auth_db/...` script paths resolve.

## Configuration

Site-specific Supabase settings live in **`src/js/supabase-config.js`**, which already
carries this site's dedicated project: `PROJECT_URL` and the publishable/anon key.
Both are meant to be public — the publishable key is safe to ship client-side and
row-level security is the actual protection. The auth glue that wires the forms to
`window.AuthService` lives in **`src/js/site-auth.js`**.

## Design

Light theme throughout: deep-blue accent `#1F4E79`, Inter type, generous whitespace,
hairline borders, soft radii. The shared design system is centralized in
`src/styles.css` under a fixed class contract; anything used by one page only lives in
that page's own `<style>` block, `mi-` prefixed on `index.html`.

## Backend

One dedicated Supabase project, defined entirely under `supabase/`:

```
sql/schema.sql              The five tables, RLS, grants, and issue_activation()
sql/live-config-checks.sql  Read-only assertions against the live project
functions/get-download      Brokers a short-lived GitHub-signed URL for a build
functions/activate          Issues the signed activation document the desktop app checks
queries/                    Copy-paste operator SQL (grant, revoke, pin, status, floor)
```

Every `.sql` in this repo is lowercase kebab-case and lives under `supabase/sql/` or
`supabase/queries/`.

Two separate gates, easy to conflate:

- **Download** (`get-download`) requires only a valid signed-in session. It does
  **not** check `subscriptions` — any signed-in account can fetch any catalogued build.
- **Activation** (`activate`) is where entitlement is enforced: subscription status,
  then the minimum-version floor, behind a rate limit.

Creating the account is not the grant. There is no trigger on `auth.users`; every
entitlement is a hand-written `subscriptions` row (`supabase/queries/`).

`get-download` takes `POST { release_id }` with the user's access token as a Bearer
header and returns `200 { url }` — GitHub's own short-lived signed URL, obtained by
requesting the asset with `Accept: application/octet-stream` and `redirect: manual`
and handing back the 302's `Location`, so the PAT never leaves the server. Errors are
`400` bad body, `401` bad token, `404` unknown release, `502` GitHub did not redirect,
`500` otherwise.

Start at **`docs/SETUP.md`**. What each live check proves, and what it cannot, is in
**`docs/LIVE_CONFIG_CHECKS.md`**.

## Deployment

One-time: repo **Settings → Pages → Source: GitHub Actions** (with the default
branch-based source, Pages runs its own Jekyll build, which cannot resolve the
submodule and fails).

Then just push to `main`. The workflow checks out (with submodules), uploads **`src/`**
as the Pages artifact, and deploys — no build step.

## Releases

Demo binaries live as assets on GitHub Releases of the private `ECSS_framework`
repo (a macOS `.app.zip` and a Windows `.exe`). After each app publish, catalog them
with `scripts/register-release.sh <tag>` (see `docs/SETUP.md`). The release drill on
the app side is `ECSS_framework/docs/RELEASING.md`, which calls that same script.

That script is not just a catalog write: once the rows land it also raises
`app_policy.min_version` to that version **on both platforms**, so every older build
is refused at activation from then on. Follow `docs/DEPLOY_RUNBOOK.md`.
