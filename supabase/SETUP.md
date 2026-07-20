# Missionite — backend setup (one-time)

Missionite runs on its **own dedicated Supabase project** (separate from the
shared `auth_db` backend) and deploys the website as a **static GitHub Pages**
site. Downloads are **invite-only**: there is no public sign-up anywhere — you
create demo accounts by hand, and the "sign up" option is turned **off** at the
Supabase level so the client can never create accounts.

Follow these steps in order. Estimated time: ~20 minutes.

---

## 1. Create the dedicated Supabase project

1. Go to <https://supabase.com/dashboard> → **New project**.
2. Name it e.g. `missionite`, pick a region close to your users, set a strong
   database password (store it in your password manager).
3. Wait for provisioning to finish.

---

## 2. Auth — email sign-in ON, public sign-up OFF (the invite-only gate)

1. **Authentication → Providers → Email**: make sure **Email** is **enabled**.
2. **Authentication → Providers → Email → "Allow new users to sign up"**: turn
   this **OFF**. This is the server-side invite-only gate — with it off, even if
   someone hits the API directly, no new account can be created. The website
   never renders a sign-up form regardless.
   - (Depending on dashboard version this toggle may appear as **Authentication →
     Sign In / Providers → "Allow new users to sign up"**, or under
     **Authentication → Settings**. Same setting.)
3. **Authentication → URL Configuration**:
   - **Site URL**: your Pages URL, e.g. `https://<user>.github.io/missionite_website`
     (or your custom domain).
   - **Redirect URLs**: add the **account page** URL so password-recovery links
     are allowed to land there:
     `https://<user>.github.io/missionite_website/account.html`
     (add both the site root and the account.html URL; add your custom domain
     too if you use one). Recovery emails will not redirect to a URL that isn't
     on this allow-list.

---

## 3. Create demo users (invite-only accounts)

For each person you want to grant access:

1. **Authentication → Users → Add user** (aka "Invite" / "Create new user").
2. Enter their **email** and a **password** (at least 12 characters — the app
   enforces this when they later change it).
3. Enable **Auto Confirm User** (or confirm the email) so they can sign in
   immediately without an email round-trip.
4. Share the credentials with them privately; they can set their own password
   later via **Forgot password?** on `account.html`.

---

## 4. Database — create the tables

1. **SQL Editor → New query**.
2. Paste the entire contents of [`schema.sql`](./schema.sql) and click **Run**.
3. This creates `releases` and `download_events` with RLS locked down (signed-in
   users can read the catalog; only the service role writes it or the audit log).
   The script is safe to re-run.

---

## 5. GitHub Releases access — a fine-grained PAT + function secrets

The demo binaries are **not** stored in Supabase (the free tier's per-file caps
can't hold the ~144 MB / ~253 MB builds). They live as **assets on GitHub
Releases** of the **private** app repo `NicholasAntoniadesEngineer/ECSS_framework`.
The `get-download` edge function reaches them with a **fine-grained personal
access token**, which it exchanges for a short-lived, GitHub-signed URL per
request — the token is never shipped to the browser.

1. Create the token: **GitHub → Settings → Developer settings → Fine-grained
   tokens → Generate new token**.
   - **Resource owner**: `NicholasAntoniadesEngineer`.
   - **Repository access → Only select repositories**: pick **only**
     `NicholasAntoniadesEngineer/ECSS_framework`.
   - **Permissions → Repository permissions → Contents: Read-only** (leave every
     other permission at *No access*).
   - Generate and **copy** the token (you only see it once).
2. Hand it to the edge function as secrets, via the Supabase CLI (see step 6 for
   installing/linking the CLI):
   ```bash
   supabase secrets set GH_RELEASES_TOKEN="<the fine-grained PAT>"
   supabase secrets set GH_RELEASES_REPO="NicholasAntoniadesEngineer/ECSS_framework"
   ```
   `GH_RELEASES_REPO` is optional (the function defaults to that repo), but
   setting it explicitly is future-proof. These secrets are held **only**
   server-side by the function.

---

## 6. Deploy the `get-download` edge function

Install the Supabase CLI if needed (<https://supabase.com/docs/guides/cli>), then
from the repo root:

```bash
# One-time: link the CLI to your project (grab <project-ref> from the dashboard URL)
supabase login
supabase link --project-ref <project-ref>

# Deploy the function (its folder is supabase/functions/get-download)
supabase functions deploy get-download
```

Notes:
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are
  injected into deployed functions automatically — you do **not** set them.
- `GH_RELEASES_TOKEN` (and optionally `GH_RELEASES_REPO`) come from the
  `supabase secrets set` commands in step 5 — set them before or after deploying;
  the function reads them at runtime to broker the GitHub-hosted binaries.
- CORS defaults to `*` (safe here — the function is authorized by a per-user
  Bearer token, not cookies). To pin it to your origin instead:
  ```bash
  supabase secrets set ALLOWED_ORIGIN="https://<user>.github.io"
  ```
- The function verifies the caller's JWT itself, so deploying with default JWT
  verification is fine.

---

## 7. Wire the website to this project

Open [`js/supabase-config.js`](../js/supabase-config.js) and replace the two
placeholders with **this project's** values (from **Settings → API**):

```js
PROJECT_URL:         'https://<project-ref>.supabase.co',   // "Project URL"
PUBLISHABLE_API_KEY: '<anon public key>',                   // "anon" / "public" key
```

The `anon` key is safe to ship in the browser — Row-Level Security is what
protects the data. Commit this change (it's expected to be public).

---

## 8. Add the auth substrate as a git submodule

The site expects the shared client code at `lib/auth_db/`:

```bash
# If a plain clone of auth_db was made at lib/auth_db for local development,
# remove it first so git can register the real submodule in its place:
rm -rf lib/auth_db

git submodule add https://github.com/NicholasAntoniadesEngineer/auth_db lib/auth_db
git commit -m "Add auth_db submodule"
```

Make sure your Pages deploy checks out submodules — the workflow's checkout step
must use `with: { submodules: recursive }` (Worker A's `deploy.yml` already does).

---

## 9. Enable GitHub Pages (GitHub Actions source)

1. Push the repo to GitHub.
2. **Repo → Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. The included Pages workflow builds and deploys on every push to the default
   branch. Your site will be live at
   `https://<user>.github.io/<repo>/` (e.g. `.../missionite_website/`).

---

## 10. Publish a build (repeat after each app release)

Publishing is two stages: **(a)** build the binaries and upload them to a GitHub
Release of the private app repo, then **(b)** register that release in this
catalog. Both run **locally** (never in CI, never committed).

**(a) In the app repo (`ECSS_framework`)** — build each platform, then attach the
assets to the GitHub Release for the current tag (e.g. `v5.3`):

```bash
bash build/mac/publish-mac.sh          # produces dist/Missionite <tag> ….dmg
bash build/windows/publish-win.sh      # produces dist/Missionite <tag> ….exe
bash build/publish-github-release.sh   # uploads both as release assets (skips the Licence Minter)
```

**(b) In this repo (`missionite_website`)** — register the two assets in the
catalog so signed-in users see the build. Export the service role key first:

```bash
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"   # Settings → API → service_role

./supabase/register-release.sh v5.3 \
    "Demo build: verification matrix + delivery packages."
```

`register-release.sh` uploads **nothing** — it reads the release's assets via
`gh` (picking the mac `.dmg` and win `.exe`, excluding the Licence Minter),
takes each `asset_id` + size from GitHub, computes the SHA-256 from the matching
local file in the app repo's `dist/` if it is still present, and inserts the two
catalog rows. Re-running for the same tag replaces those rows. Signed-in users
then see the new build on `download.html`, brokered by `get-download`.

> **Keep the service role key secret.** It bypasses RLS. Never put it in the
> website, in `js/supabase-config.js`, in the repo, or in any client code — only
> in your local shell environment when running `register-release.sh`.

---

## Quick verification checklist

- [ ] Visiting `download.html` **signed out** shows "Sign in to download" (no build list).
- [ ] Signing in on `account.html` shows "You're signed in" + a link to downloads.
- [ ] `download.html` **signed in** lists the latest macOS/Windows builds.
- [ ] Clicking **Download** starts a file download (via a short-lived GitHub asset URL).
- [ ] **Forgot password?** emails a link that lands on `account.html` and lets you set a new password.
- [ ] Trying to sign up is impossible (no form on the site; sign-up disabled in Supabase).
