# Missionite — backend setup (one-time)

Missionite runs on its **own dedicated Supabase project** (separate from the
shared `auth_db` backend) and deploys the website as a **static GitHub Pages**
site. Downloads are **invite-only**: there is no public sign-up anywhere — you
create demo accounts by hand, and the "sign up" option is turned **off** at the
Supabase level so the client can never create accounts.

The same project also carries **entitlement**: a `subscriptions` row you write by
hand decides whether the desktop app may activate, and the `activate` edge
function signs a short-lived offline window for it. No client can grant itself
anything — every write on that path is yours.

Follow these steps in order. Estimated time: ~30 minutes.

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
   - **Redirect URLs**: add the **site root** so password-recovery links are
     allowed to land there (the site is a single gated `index.html`; recovery
     redirects to `origin + pathname`):
     `https://<user>.github.io/missionite_website/`
     (add your custom domain too if you use one). Recovery emails will not
     redirect to a URL that isn't on this allow-list.

---

## 3. Auth hardening (dashboard)

Two settings that matter once the desktop app is signing in. The app authenticates
straight against GoTrue (password grant, then refresh grants), so a stolen session
is a stolen *refresh token* — these bound what it can do.

1. **Authentication → Providers → Email → "Secure password change"**: turn it
   **ON**. With it off, anything holding a valid session can set a new password
   outright and lock the real owner out. With it on, a password change needs
   re-authentication first (Supabase emails a one-time code), so possession of a
   token is no longer enough to take the account over.
   - (Dashboard versions move this: it may sit under **Authentication → Sign In /
     Providers → Email**, or under **Authentication → Settings** / **Policies**.
     Same setting.)
2. **Authentication → Sessions**: set an **inactivity timeout** of about **30
   days**, so a refresh token that nobody uses stops working instead of living
   forever.
   - Session time-boxing and inactivity timeout are **paid-plan** controls. If
     they are greyed out or carry a plan badge on your project, note it and move
     on — the primary bound on a stolen session is the **14-day activation
     window** (§8), not the session lifetime.
   - Leave **refresh-token rotation** and reuse detection at their defaults
     (on) if your project exposes them; the desktop app refreshes normally and
     rotation is what turns a copied refresh token into a detectable event.

---

## 4. Create demo users (invite-only accounts)

For each person you want to grant access:

1. **Authentication → Users → Add user** (aka "Invite" / "Create new user").
2. Enter their **email** and a **password** (at least 12 characters — the app
   enforces this when they later change it).
3. Enable **Auto Confirm User** (or confirm the email) so they can sign in
   immediately without an email round-trip.
4. Share the credentials with them privately; they can set their own password
   later via **Forgot password?** on the site's sign-in view.

---

## 5. Run the schema + checks

1. **SQL Editor → New query**.
2. Paste the entire contents of [`schema.sql`](../supabase/sql/schema.sql) and click **Run**.
3. This creates five tables with RLS locked down:
   - `releases` — the build catalog (any signed-in user may read it).
   - `download_events` — the download audit log (service role only).
   - `subscriptions` — entitlement; a user may read **their own** row and write
     **nothing**. You write it from the SQL editor (§9).
   - `activation_events` — the activation audit *and* the rate-limit ledger
     (service role only). It is also where `issue_activation` counts attempts,
     which is why no client may touch it.
   - `app_policy` — the minimum activatable build per platform (service role
     only). `register-release.sh` raises it on every publish (§13); no row at all
     means no floor.

   It also creates `issue_activation()`, the SECURITY DEFINER function that makes
   the activation decision. **There is no trigger on `auth.users`:** creating a
   user grants nothing, and every `subscriptions` row is written by hand (§9).

   The script is safe to re-run — it never `DROP`s a table, so your catalog,
   audit history, and hand-written entitlements survive.
4. **New query** again, paste the entire contents of
   [`live-config-checks.sql`](../supabase/sql/live-config-checks.sql), **Run**. It is read-only.
5. Read the `status` column: every row should be **PASS**, except check 0 which
   is an **INFO** shape row and should read `FULL — catalog + activation`. The
   last **SUMMARY** row is the go/no-go — it says `FAIL` if anything above it
   failed. Chase any FAIL before shipping; `schema.sql` proves what you *wrote*,
   this proves what the live project actually *is*.

Re-run the checks after **any** change you paste into the live project and after
any hand-edit in the dashboard (a GRANT, a policy, an RLS toggle). Details, the
per-check rationale, and the **deliberate-FAIL probe** — the one-time exercise
that proves the script can actually fail — are in
[`LIVE_CONFIG_CHECKS.md`](./LIVE_CONFIG_CHECKS.md). Run that probe on a scratch
project if you can; it is the only part of the audit that writes.

### Schema notes

- **Re-runnable by construction**: `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF
  NOT EXISTS`, a `DROP ... IF EXISTS` before each policy and trigger, and `CREATE
  OR REPLACE` for the function. No table is ever dropped, so a re-run costs you
  nothing.
- **`releases`** carries exactly one policy — `SELECT` to `authenticated`. No
  client role gets `INSERT`/`UPDATE`/`DELETE`, and `anon` is revoked outright, so
  the catalog is written only with the service role key, which bypasses RLS. That
  one policy is the whole client-side boundary.
- **`download_events`** has RLS enabled and **deliberately no policies at all**:
  RLS on with zero policies denies `anon` and `authenticated` everything, leaving
  `get-download` under the service role as the only writer. Table privileges are
  revoked from both client roles too. The who-downloaded-what graph stays
  operator-only.
- **`app_policy.min_version`** must equal a `releases.version` exactly, **with no
  leading `v`** (`5.4`, never `v5.4`) — the floor is compared by that release's
  `published_at`, and a value matching no release fails **open**.
- **`subscriptions.current_period_end`** is `NOT NULL` on purpose: the signed
  payload carries a non-nullable end date. For open-ended access set a far date
  (`2099-01-01`), never an empty one.

---

## 6. GitHub Releases access — a fine-grained PAT + function secrets

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
2. Hand it to the edge function as secrets, via the Supabase CLI (see step 7 for
   installing/linking the CLI):
   ```bash
   supabase secrets set GH_RELEASES_TOKEN="<the fine-grained PAT>"
   supabase secrets set GH_RELEASES_REPO="NicholasAntoniadesEngineer/ECSS_framework"
   ```
   `GH_RELEASES_REPO` is optional (the function defaults to that repo), but
   setting it explicitly is future-proof. These secrets are held **only**
   server-side by the function.

---

## 7. Deploy the `get-download` edge function

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
  `supabase secrets set` commands in step 6 — set them before or after deploying;
  the function reads them at runtime to broker the GitHub-hosted binaries.
- CORS defaults to `*` (safe here — the function is authorized by a per-user
  Bearer token, not cookies). To pin it to your origin instead:
  ```bash
  supabase secrets set ALLOWED_ORIGIN="https://<user>.github.io"
  ```
- The function verifies the caller's JWT itself, so deploying with default JWT
  verification is fine.

---

## 8. Activation function — secrets and deploy

`activate` is the signed entitlement endpoint the **desktop app** calls (never the
website): the app signs in, POSTs a random `nonce`, and gets back a signed
envelope — `{ payload, signature, keyId, latest }` — carrying the tier, the
subscription end, and a **window end** at most **14 days** out. (`latest` is the
newest catalogued version for the platform, outside the signature — an update
hint, never a trust input.) The decision itself is made in
the database by `issue_activation`, from a user id the function has verified; the
client only ever *receives* a verdict.

It needs two secrets: the ECDSA P-256 private key that signs the payload, and the
key id that is stamped into it.

```bash
supabase secrets set ACTIVATION_SIGNING_KEY="$(cat '<path to the vendor-only signing-key PEM>')"
supabase secrets set ACTIVATION_KEY_ID=k384c7ff8d66b
```

The vendor-only PEM lives with the app build, at
`<ECSS_framework>/dist/VENDOR-ONLY-signing-key-k384c7ff8d66b.pem` — the same
`dist/` that `ECSS_DIST_DIR` points at in `scripts/register-release.sh`. Use the
`"$(cat '<path>')"` form exactly as written: only the **path** reaches your
command line and your shell history — the key text never does. Never paste the
key itself into a terminal, a file, this repo, or a message.

**Before deleting the PEM, keep the public half** — it is not a secret, and you
need it to verify an envelope later:

```bash
openssl pkey -in '<path to the vendor-only signing-key PEM>' -pubout \
    -out '<a folder outside this repo>/activation-pub-k384c7ff8d66b.pem'
```

Then verify the secrets landed and remove the private key from disk:

```bash
supabase secrets list          # prints NAMES (and a digest) — never the values
rm -P '<path to the vendor-only signing-key PEM>'
```

(`-P` is macOS's overwrite-before-unlink flag — plain `rm` elsewhere. On an SSD
it is a courtesy, not an erasure guarantee; the control that matters is that the
key now exists only in the secret store.)

Deploy:

```bash
supabase functions deploy activate
```

Notes:
- `supabase secrets list` proving a name is present proves only that *something*
  is set. The proof that the **right** key landed is a verified envelope — see
  step 7 of [`DEPLOY_RUNBOOK.md`](./DEPLOY_RUNBOOK.md).
- Once the PEM is deleted, the only copy is inside Supabase's secret store, which
  you **cannot read back**. If you want a recovery copy, put it in your password
  manager — not on disk, not in a repo. Losing the key costs exactly what leaking
  it costs (see the box below).
- Deploy with default JWT verification. The function re-verifies the token itself
  and calls `issue_activation` with the id it verified, so the user id can never
  be spoofed by the body.
- **Do not set `ALLOWED_ORIGIN` for `activate`.** It is desktop-only and has no
  CORS by design: it emits no `Access-Control-*` headers and answers anything
  that is not a `POST` with `405`. Setting that secret would not change `activate`
  at all — but secrets are **project-wide**, so it *would* re-pin
  `get-download`'s CORS (step 7). Set it only if that is what you meant.
- Secrets being project-wide also means every function you deploy into this
  project can read `ACTIVATION_SIGNING_KEY`. Keep that in mind before adding one.
- **After rotating the key, redeploy.** The function imports the key once per
  isolate and caches it, so a warm isolate can keep signing with the *old* key
  until it recycles. `supabase functions deploy activate` forces fresh isolates.

> **If the signing key leaks, a new app release is required.** The public half is
> integrity-pinned into every shipped binary, so there is no server-side
> revocation that reaches installed copies. Recovery is: generate a new keypair,
> `supabase secrets set` the new `ACTIVATION_SIGNING_KEY` and a new
> `ACTIVATION_KEY_ID`, redeploy `activate`, embed the new public half in the app,
> and **ship a new release**. Until a user installs it, their copy still trusts
> the old key. Rotating also does not shorten windows already issued — those run
> to their end.

---

## 9. Subscriptions — grant, extend, revoke

`subscriptions` is the entitlement table: one row per user, written only by you.
The queries live in [`supabase/queries/`](../supabase/queries/) — open **SQL Editor → New query**,
paste a file, and **save it under the same name as the file**. They then sit in
the sidebar as named queries you open, fill in and run.

| Saved query | What it does |
| --- | --- |
| [`add-demo-user.sql`](../supabase/queries/add-demo-user.sql) | Grants (or re-grants) one week of `demo` access. |
| [`add-premium-user.sql`](../supabase/queries/add-premium-user.sql) | Grants 12 months of `active` / `business` access — no demo watermark on rendered documents. |
| [`revoke-user.sql`](../supabase/queries/revoke-user.sql) | Sets `status` to `cancelled`. |
| [`user-status.sql`](../supabase/queries/user-status.sql) | The entitlement row, then the last 10 activation attempts. |
| [`set-minimum-version.sql`](../supabase/queries/set-minimum-version.sql) | Sets the global minimum app version for one platform. |
| [`pin-user-version.sql`](../supabase/queries/pin-user-version.sql) | Overrides that floor for one user, or clears it with `NULL`. |

All but `set-minimum-version.sql` take a `'<PASTE-UUID>'` placeholder — copy the
uuid from **Authentication → Users**; that one takes `'<mac|win>'` and a version.
Every statement ends in `RETURNING *`, but read the result by statement type: the
two `UPDATE`s (`revoke-user`, `pin-user-version`) return **0 rows** for a uuid
that has no subscription, while the two grants are `INSERT`s against a foreign key
to `auth.users`, so a wrong uuid **raises an error** rather than returning 0 rows.
Either way it never silently does nothing.

Re-running a grant on an existing user is how you extend it: the upsert rewrites
`current_period_end` from today, so a lapsed row never gets a period that is half
in the past.

Only `status` of `active` or `demo` **and** a `current_period_end` in the future
entitles activation — anything else is refused by `issue_activation` before a
signature is ever produced. It checks `status` **before** the date, so a row that
is both cancelled *and* lapsed refuses with `inactive`, not `expired`. To see
`expired`, leave `status` at `active`/`demo`. A user with **no row at all**
refuses with `absent`, which `user-status.sql` shows as an empty first result.

That second statement is also your rate-limit view: the cap is **12 activations
per user per rolling 24 hours** and **4 per 10 minutes**. Every refusal consumes a
token exactly like a grant does — **except `refused_outdated`**, which is ledgered
but deliberately not counted, so a stale build being turned away cannot eat the
budget the freshly-updated build needs moments later. So a user with a broken
client can still lock themselves out for ten minutes; that is the ledger working,
not a fault.

**Drill tools — deliberately not saved queries.** End a period now without
touching `status`, which is how you exercise the `expired` refusal:

```sql
UPDATE public.subscriptions SET current_period_end = NOW()
 WHERE user_id = '<PASTE-UUID>' RETURNING *;
```

And reset the cap for a test account, when you have deliberately burned the burst
allowance during the deploy drill:

```sql
DELETE FROM public.activation_events WHERE user_id = '<PASTE-UUID>';
```

> This destroys audit rows. Only ever for **your own test account** — never a
> real user's. That ledger is both the rate cap and the only record of who
> activated when.

> **Revocation does not reach a copy that is already running.** Cancelling the
> row stops the *next* activation; a window already issued keeps running to its
> end — at most **14 days** from when it was issued
> (`LEAST(now + 14 days, current_period_end)`). That bound is the design, not a
> gap: it is what lets the app work on an aeroplane. To shorten the worst case
> *ahead of time*, keep `current_period_end` close, since the window is clamped
> to it. Nothing can claw back a window that is already signed.

---

## 10. Wire the website to this project

Open [`src/js/supabase-config.js`](../src/js/supabase-config.js) and set the two constants
to **this project's** values (from **Settings → API**):

```js
PROJECT_URL:         'https://<project-ref>.supabase.co',   // "Project URL"
PUBLISHABLE_API_KEY: '<anon public key>',                   // "anon" / "public" key
```

The `anon` key is safe to ship in the browser — Row-Level Security is what
protects the data. Commit this change (it's expected to be public).

---

## 11. Add the auth substrate as a git submodule

The site expects the shared client code at `src/lib/auth_db/`:

```bash
# If a plain clone of auth_db was made at src/lib/auth_db for local development,
# remove it first so git can register the real submodule in its place:
rm -rf src/lib/auth_db

git submodule add https://github.com/NicholasAntoniadesEngineer/auth_db src/lib/auth_db
git commit -m "Add auth_db submodule"
```

Make sure your Pages deploy checks out submodules — the workflow's checkout step
must use `with: { submodules: recursive }` (`.github/workflows/deploy.yml` already does).

The checkout is not the artifact. The workflow's staging step copies only the submodule
files the site loads, so the submodule's internal documents are never published; a page
that starts loading another submodule file needs that path added to the list in the
workflow, and the deploy's reference check fails until it is (README, "Deployment").

---

## 12. Enable GitHub Pages (GitHub Actions source)

1. Push the repo to GitHub.
2. **Repo → Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. The included Pages workflow builds and deploys on every push to the default
   branch. Your site will be live at
   `https://<user>.github.io/<repo>/` (e.g. `.../missionite_website/`).

---

## 13. Publish a build (repeat after each app release)

Publishing is two stages: **(a)** build the binaries and upload them to a GitHub
Release of the private app repo, then **(b)** register that release in this
catalog. Both run **locally** (never in CI, never committed).

**(a) In the app repo (`ECSS_framework`)** — build each platform, then attach the
assets to the GitHub Release for the current tag (e.g. `v5.3`):

```bash
# Canonical, always-current version of this loop: ECSS_framework/docs/RELEASING.md
bash build/mac/publish-mac.sh          # produces dist/Missionite <tag>.app.zip
bash build/windows/publish-win.sh      # produces dist/Missionite <tag>.exe
bash build/publish-github-release.sh   # uploads both as release assets (skips the Licence Minter)
```

**(b) In this repo (`missionite_website`)** — register the two assets in the
catalog so signed-in users see the build. Export the service role key first:

```bash
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"   # Settings → API → service_role

./scripts/register-release.sh v5.3 \
    "Demo build: verification matrix + delivery packages."
```

`register-release.sh` uploads **nothing** — it reads the release's assets via
`gh` (picking the mac `.app.zip` and win `.exe`, excluding the Licence Minter),
takes each `asset_id` + size from GitHub, computes the SHA-256 from the matching
local file in the app repo's `dist/` if it is still present, and upserts the two
catalog rows on `(version, platform)`. Re-running for the same tag rewrites those
rows in place but leaves `published_at` alone, so re-registering an old tag cannot
make it the newest build. Signed-in users then see the new build in the site's
signed-in downloads view, brokered by `get-download`.

The macOS asset must be a **`.app.zip`** — the script hard-exits with
`no macOS .app.zip asset on <tag>` if it finds none.

Point `ECSS_DIST_DIR` at the app repo's `dist/` (it defaults there) so the SHA-256
can be computed from the local artifacts. If the files are gone, the script warns
and stores an **empty** `sha256` rather than failing — the catalog row still works,
but you lose the digest.

> **Then it raises the floor.** Once both rows land, the script upserts
> `app_policy.min_version` to this version on **both** platforms, so every earlier
> build is refused at activation from that moment on. This is the intended release
> gesture, but it is not undoable by re-running an older tag out of order — use
> [`queries/set-minimum-version.sql`](../supabase/queries/set-minimum-version.sql) to put the
> floor back. Follow [`DEPLOY_RUNBOOK.md`](./DEPLOY_RUNBOOK.md).

> **Keep the service role key secret.** It bypasses RLS. Never put it in the
> website, in `src/js/supabase-config.js`, in the repo, or in any client code — only
> in your local shell environment when running `register-release.sh`.

---

## Quick verification checklist

### Website

- [ ] Visiting the site **signed out** shows the sign-in view (no build list).
- [ ] Signing in shows the workspace with the latest macOS/Windows builds.
- [ ] Clicking **Download** starts a file download (via a short-lived GitHub asset URL).
- [ ] **Forgot password?** emails a link that lands back on the site root (`index.html`), which shows the "Set a new password" view.
- [ ] Trying to sign up is impossible (no form on the site; sign-up disabled in Supabase).

### Backend config

- [ ] `live-config-checks.sql` returns **all PASS**, check 0 reads `FULL — catalog + activation`, and the `SUMMARY` row is PASS.
- [ ] `supabase secrets list` shows `ACTIVATION_SIGNING_KEY` and `ACTIVATION_KEY_ID`.
- [ ] The vendor-only private PEM is **gone from disk**; the derived public half is kept somewhere outside this repo.
- [ ] `ALLOWED_ORIGIN` is **not** set for `activate` (no CORS, deliberately).
- [ ] "Secure password change" is ON.

### Activation endpoint

Run against a **test account** — see [`DEPLOY_RUNBOOK.md`](./DEPLOY_RUNBOOK.md)
for the exact calls, and mind the order: every attempt that reaches the database
consumes one of the 4-per-10-minutes tokens.

- [ ] Entitled user → **200** with a `{ payload, signature, keyId, latest }` envelope whose `windowEndUtc` is ≤ 14 days out.
- [ ] No `subscriptions` row → **403** `{"error":"subscription_inactive","reason":"absent"}`.
- [ ] `status = 'cancelled'` → **403** `{"error":"subscription_inactive","reason":"inactive"}`.
- [ ] `current_period_end` in the past (status left at `demo`) → **403** `{"error":"subscription_inactive","reason":"expired"}`.
- [ ] Garbage/expired bearer token → **401** (never reaches the ledger, so it costs no rate-limit token).
- [ ] 5 calls inside 10 minutes → the 5th is **429** `{"error":"rate_limited", ...}` with a `Retry-After` header.
- [ ] `OPTIONS` → **405** `{"error":"method_not_allowed"}`, with no `Access-Control-*` headers.
- [ ] `activation_events` shows one row per attempt above, with the matching `outcome`.
