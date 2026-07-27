# Missionite — activation deploy runbook

The go-moment script: bring the activation endpoint live on the Missionite
Supabase project, prove it, and know how to undo it. Run the steps **in order** —
each one's expected result is the entry condition for the next.

Background and the click-paths live in [`SETUP.md`](./SETUP.md); this file is the
short version you actually work from on the day. Budget ~30 minutes.

---

## Before you start

- **Supabase CLI installed and linked** to the Missionite project
  (`supabase login`, then `supabase link --project-ref <project-ref>` from the
  repo root — `SETUP.md` §7).
- **Dashboard open** on the same project, on **SQL Editor**.
- **The vendor-only signing PEM on disk**, path to hand:
  `<ECSS_framework>/dist/VENDOR-ONLY-signing-key-k384c7ff8d66b.pem`.
  If it is already gone, stop — you cannot re-set the secret from anything else,
  and a new keypair means a new app release (`SETUP.md` §8).
- **A test account** in this project — dashboard-created, auto-confirmed, whose
  password you know and can type. Not a real user's account; this runbook
  deliberately breaks its entitlement and burns its rate limit.
- **`openssl`** (public half) and **`deno`** (signature check, step 8).
- **`gh` authenticated** only if you are also registering a build afterwards
  (`SETUP.md` §13).
- The **service role key is not needed** anywhere in this runbook. Do not export it.

---

## 1. Paste the schema

**Pre-flight first.** The schema creates a UNIQUE index on
`releases(version, platform)`, and `CREATE UNIQUE INDEX` fails outright if the
catalog already holds a duplicate pair. **New query**:

```sql
SELECT version, platform, count(*) FROM public.releases GROUP BY 1,2 HAVING count(*) > 1;
```

Expect **zero rows**. If any come back, keep the newest row of each pair and
delete the others before going on — the index cannot be built around them, and
without it `register-release.sh` cannot upsert.

**SQL Editor → New query** → paste all of [`schema.sql`](../supabase/sql/schema.sql) → **Run**.

Safe to re-run: no `DROP TABLE` anywhere, so an existing catalog and audit
history survive. Expect `Success. No rows returned`.

## 2. Run the live checks

**New query** → paste all of
[`live-config-checks.sql`](../supabase/sql/live-config-checks.sql) → **Run**. Read-only.

Expect every row **PASS**, with check 0 (`INFO`) reading
`FULL — catalog + activation` and the final **SUMMARY** row PASS.

**Stop if** anything reads FAIL — `LIVE_CONFIG_CHECKS.md` says what each one
means. A write path onto `subscriptions`, or any client access to
`activation_events`, is a self-granted licence waiting to happen.

## 3. Secrets — public half, set, verify, delete

Order matters: derive the public half **before** the private key leaves the disk.

```bash
# 1) keep the public half — not a secret, needed for step 8
openssl pkey -in '<path to the vendor-only signing-key PEM>' -pubout \
    -out '<a folder outside this repo>/activation-pub-k384c7ff8d66b.pem'

# 2) hand the private key to the function; only the PATH touches your shell history
supabase secrets set ACTIVATION_SIGNING_KEY="$(cat '<path to the vendor-only signing-key PEM>')"
supabase secrets set ACTIVATION_KEY_ID=k384c7ff8d66b

# 3) verify the names are there (this prints names and a digest, never values)
supabase secrets list

# 4) only now, remove the private key from disk
rm -P '<path to the vendor-only signing-key PEM>'
```

**Stop if** step 3 does not list both names. After step 4 the only copy of that
key is inside Supabase's secret store, which you cannot read back — if you want
a recovery copy, it goes in your password manager first, never on disk.

## 4. Deploy `activate`

```bash
supabase functions deploy activate
```

Keep default JWT verification. Do **not** set `ALLOWED_ORIGIN` — this endpoint is
desktop-only and has no CORS by design, and secrets are project-wide so setting
it would re-pin `get-download` instead (`SETUP.md` §8).

## 5. Create the test subscription row

**SQL Editor**, running [`queries/add-demo-user.sql`](../supabase/queries/add-demo-user.sql)
with the test account's **uuid** (copy it from **Authentication → Users** — the
grants key on uuid, not email). Expect **1 row** returned, `status = demo`,
`tier = demo`, `current_period_end` **one week** out.

**Stop if** it raises a foreign-key error — the uuid does not match a user. (This
is an `INSERT`, so a bad uuid errors; it does not come back as 0 rows.)

## 6. Catalog and floor — see what is about to be refused

Two read-only queries, and the pair you run **before and after** every
`register-release.sh`. The first is the newest build per platform; the second is
the floor those builds are measured against.

```sql
SELECT DISTINCT ON (platform) platform, version, published_at
    FROM public.releases ORDER BY platform, published_at DESC;

SELECT * FROM public.app_policy;
```

Read them together: every build older than `min_version` is refused at activation
(sign-in itself is version-blind — the floor lives in `issue_activation`).
Registering raises the floor to the version it just catalogued, so *after* a
release the two answers agree — `min_version` equals the newest `version` — and
the difference between the before and after picture is exactly the set of copies
in the field that just stopped activating.

Step 7 needs both: at least one `releases` row, and an `app_policy` row for the
platform you test. The stale-build attempt is measured against them.

### What `register-release.sh` does between those two reads

It uploads nothing. It reads the assets already attached to the GitHub release
for `<tag>`, writes the `mac` + `win` catalog rows, then raises the floor.

- **Needs** `bash`, `curl`, an authenticated `gh`, and `shasum` or `sha256sum`.
  `GH_RELEASES_REPO` and `ECSS_DIST_DIR` override the source repo and the local
  dist directory.
- **`sha256` comes from the local `dist/` file, not from GitHub.** GitHub rewrites
  spaces in asset names to dots (`Missionite v5.4.app.zip` is served as
  `Missionite.v5.4.app.zip`), so the asset name never matches disk and the script
  globs `Missionite <tag><suffix>` instead. **If that local file is gone the row
  is still written — with an empty `sha256` and only a warning.** Register from
  the machine that built the release.
- **The floor is written last, on purpose**: it must never name a version whose
  binaries are not already downloadable. If the catalog write lands and the floor
  write fails, downloads work and the old floor stands; the script says so and
  points at `supabase/queries/set-minimum-version.sql`. Fix it on **both** platforms.
- **Two PostgREST literals that look like typos and are not.** The upserts pass
  `on_conflict=version,platform` and `on_conflict=platform` because PostgREST
  otherwise resolves conflicts against the primary key, which never collides.
  And `updated_at` is sent as the string `"now"`, PostgreSQL's timestamp literal
  — `now()` is not valid input syntax for `timestamptz`.

## 7. The curl matrix

Get a token with the password grant. The password is typed, never written down:

```bash
PROJECT_URL="https://<project-ref>.supabase.co"
ANON_KEY="<anon public key>"
TEST_EMAIL="<test-account-email>"

# prompt without echoing, and without bash-vs-zsh "read -p" differences
printf 'test account password: '; stty -echo; read -r TEST_PASSWORD; stty echo; printf '\n'

ACCESS_TOKEN=$(curl -s -X POST "$PROJECT_URL/auth/v1/token?grant_type=password" \
        -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
        -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
unset TEST_PASSWORD
[ -n "$ACCESS_TOKEN" ] && echo "token acquired" || echo "NO TOKEN — check the email/password"
```

(`jq -r .access_token` does the same job if you have it.)

One helper, so each attempt gets a fresh nonce and the last response is kept.
Both arguments are optional: `activate` on its own behaves exactly as before,
while `activate v0.0 mac` also sends `build_tag` and `platform`.

```bash
activate() {
    nonce=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
    extra=""
    [ -n "${1:-}" ] && extra="$extra,\"build_tag\":\"$1\""
    [ -n "${2:-}" ] && extra="$extra,\"platform\":\"$2\""
    curl -s -i -X POST "$PROJECT_URL/functions/v1/activate" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"nonce\":\"$nonce\",\"app_version\":\"runbook\"$extra}" \
    | tee /tmp/activate-last.txt
}
```

**Mind the accounting.** Attempts that reach the rate-limit counters are capped
at **4 per 10 minutes**. The matrix below is **six attempts of which five
count**: `refused_outdated` is deliberately excluded from those counters, so the
stale-build attempt is free and slots in without disturbing the arithmetic. Rows
1–4 spend the burst, row 5 spends nothing, row 6 *is* the rate-limit test.

That exclusion is not taken on trust — the matrix proves it for free. If
`refused_outdated` ever started charging a token, row 5 would answer **429** and
the rate limit would arrive one row early.

Run them back to back, changing the row in the SQL editor between each.

| # | Set up first (SQL editor) | Run | Expect |
|---|---|---|---|
| 1 | row as granted in step 5 | `activate` | **200** `{ payload, signature, keyId }` |
| 2 | revoke snippet (`status='cancelled'`) | `activate` | **403** `{"error":"subscription_inactive","reason":"inactive"}` |
| 3 | re-grant, then expire-now snippet (leave status `demo`) | `activate` | **403** `... "reason":"expired"` |
| 4 | re-grant (12 months) | `activate` | **200** envelope again — capture it before row 5 |
| 5 | nothing; catalog + floor as seen in step 6 | `activate v0.0 mac` | **403** `{"error":"outdated_build","latest_version":"<newest>"}` — and no token spent |
| 6 | nothing | `activate` | **429** `{"error":"rate_limited",...}` + a `Retry-After` header |

Capture attempt 4's envelope for step 8 **before running rows 5 and 6** — the
helper overwrites `/tmp/activate-last.txt` on every call. This reads the file
the helper already wrote — it does **not** call the endpoint again:

```bash
tail -n 1 /tmp/activate-last.txt > /tmp/envelope.json
```

Two more checks that never reach the ledger, so they are free and can run any time:

```bash
# garbage token -> 401
curl -s -i -X POST "$PROJECT_URL/functions/v1/activate" \
    -H "Authorization: Bearer not-a-real-token" -H "Content-Type: application/json" \
    -d '{"nonce":"AAAAAAAAAAAAAAAAAAAAAA"}'

# OPTIONS -> 405, and no Access-Control-* headers anywhere
curl -s -i -X OPTIONS "$PROJECT_URL/functions/v1/activate"
```

Notes:
- The 401 body may be the function's `{"error":"unauthorized"}` or the platform
  gateway's own `Invalid JWT` — either is a pass; the status is the assertion.
- If a *valid* call answers 401, your access token expired (they are short-lived).
  Re-run the password grant.
- To clear the cap on the test account instead of waiting out the ten minutes,
  use the ledger-reset snippet in `SETUP.md` §9. Test account only.
- Row 5 may still leave an audit row; what it must not do is spend a token, and
  row 6 is what proves that — the 429 arrives on the sixth attempt, not the fifth.
- **Before moving to step 9**, re-grant the test row *and* clear the cap — either
  wait out the ten-minute burst window or run that reset. Attempt 6 left this
  account rate-limited, and the desktop app is the same user: it would be refused
  with `429` and look like a broken deploy.

## 8. Verify the envelope signature

Prove the key in the secret store is the key the app trusts.

```bash
cat > /tmp/verify-envelope.ts <<'TS'
// Verify one activation envelope against the PUBLIC half of the signing key.
const pem = await Deno.readTextFile(Deno.args[0]);
const env = JSON.parse(await Deno.readTextFile(Deno.args[1]));

const spki = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
const key = await crypto.subtle.importKey(
    "spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);

const b64url = (s: string) => Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4)),
    (c) => c.charCodeAt(0));

const payload = b64url(env.payload);
const signature = Uint8Array.from(atob(env.signature), (c) => c.charCodeAt(0));
const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key, signature, payload);

console.log(ok ? "SIGNATURE OK" : "SIGNATURE BAD");
console.log(new TextDecoder().decode(payload));
TS

deno run --allow-read /tmp/verify-envelope.ts \
    '<a folder outside this repo>/activation-pub-k384c7ff8d66b.pem' /tmp/envelope.json
```

Expect `SIGNATURE OK`, then the payload JSON. Read it: `keyId` is
`k384c7ff8d66b`, `userId` is the test user, `nonce` is the one you sent, and
`windowEndUtc` is **at most 14 days** after `serverTimeUtc`.

> **`openssl dgst -verify` will fail on a perfectly valid envelope — do not use
> it here.** WebCrypto emits the ECDSA signature as raw P1363 (`r || s`, 64 bytes
> on P-256); `openssl` only accepts a DER-wrapped `ECDSA-Sig-Value`. Converting
> between them is possible and fiddly, and a failed conversion looks exactly like
> a bad key. The Deno check above is what the app itself does.

## 9. App-side end-to-end

On a machine with the shipped build: sign into the desktop app as the test
account.

Expect the app to activate, mint its vault, and **relaunch silently** into the
entitled state — no prompt, no visible round trip.

Then confirm from the server side, in the SQL editor (inspect snippet,
`SETUP.md` §9): a fresh `granted` row in `activation_events` carrying the app's
real `app_version` and a `window_end` ≤ 14 days out.

**Stop if** the app activates but no `granted` row appears — it is talking to a
different project.

## 10. Revoke drill

Run the revoke snippet (`SETUP.md` §9) against the test account, then call
`activate` once more.

Expect **403** `subscription_inactive` / `inactive`, and a matching
`refused_inactive` row in the ledger.

The already-installed app **keeps working** until its current window ends — that
is the design (≤ 14 days), not a failed drill. Verify the refusal in the ledger,
not by watching the app die.

Re-grant the test row afterwards if you want the account usable.

## 11. Rollback

Everything here is reversible server-side, in seconds:

```bash
supabase functions delete activate
supabase secrets unset ACTIVATION_SIGNING_KEY ACTIVATION_KEY_ID   # optional
```

```sql
-- optional: remove the entitlement rows you created
DELETE FROM public.subscriptions WHERE user_id IN
    (SELECT id FROM auth.users WHERE email IN ('<user@example.com>'));
```

**Lowering the version floor** is its own rollback, and a different shape of one:
[`queries/set-minimum-version.sql`](../supabase/queries/set-minimum-version.sql), run for
**both** platforms. Server-side it is instant, but no copy in the field learns
about it until its next server contact — one sitting inside its offline window
(≤ 14 days) cannot be reached at all until then. Lowering the floor un-refuses
future activations; it does not reach back into a copy already showing the
update card.

The tables can stay: without the function they are inert, and
`activation_events` is the only record of what happened. Deleting the function
stops **new** windows being issued; it does not reach copies already running,
which keep working to the end of their last window (≤ 14 days). There is no
server-side switch that revokes faster than that — by design.

---

## Go / no-go

Call it live when all of these are true:

- [ ] `live-config-checks.sql` — all PASS, SUMMARY PASS (step 2).
- [ ] `supabase secrets list` shows both activation names; the private PEM is off disk (step 3).
- [ ] The curl matrix produced 200 / 403 inactive / 403 expired / 200 / 403 outdated / 429 (step 7).
- [ ] The stale build was refused `outdated_build` **and cost nothing** — the 429
      still landed on the sixth attempt, not the fifth (step 7).
- [ ] Garbage token → 401 and `OPTIONS` → 405 (step 7).
- [ ] `SIGNATURE OK` against the public half, `windowEndUtc` ≤ 14 days (step 8).
- [ ] Real app signs in, vault minted, silent relaunch, `granted` row present (step 9).
- [ ] Revoke drill refused the next activation (step 10).
