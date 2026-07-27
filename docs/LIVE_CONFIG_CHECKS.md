# LIVE_CONFIG_CHECKS — companion notes

**File:** `supabase/sql/live-config-checks.sql`
**What it is:** a read-only, copy-paste self-audit for the **live** Missionite
Supabase project. `supabase/sql/schema.sql` proves only the SQL we *wrote*; it cannot
prove the live project was actually migrated to that state. This script asserts
the live config matches intent and prints `PASS` / `FAIL` / `INFO` rows, plus a
`SUMMARY` row at the end. Expect roughly forty rows, not fourteen: the checks that
sweep a privilege matrix emit one row per role/verb pair.

Wherever a check below says "every verb" it means the six it actually tests —
`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`. `TRIGGER` is not
swept; `REVOKE ALL` in `schema.sql` covers it, so only a hand-issued `GRANT TRIGGER`
would slip past.

It is one statement (a CTE per check, `UNION ALL`'d) rather than one statement
per check, so the SQL editor cannot show you some result blocks and quietly hide
others.

## When to run it

- **After any change to `supabase/sql/schema.sql`** that you pasted into the live
  project — that is the moment the repo and the live project can diverge.
- **Before publishing a release.** The activation endpoint mints signed
  entitlement documents; a client-writable `subscriptions` table means anyone
  with an account can self-grant one.
- **After any hand-edit in the Dashboard** (a GRANT, a policy, an RLS toggle),
  including one you made on purpose and meant to undo.
- Periodically, as a drift check. It costs one query.

## How to run

1. Supabase Dashboard → **SQL Editor** → New query.
2. Paste the whole of `live-config-checks.sql`, **Run**.
3. It is **read-only** — only `SELECT`s, no writes and no DDL. Safe on production.
4. Read the `status` column. The final `SUMMARY` row is `FAIL` if anything above
   it failed, so that one row is the go/no-go.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 0 | Schema-shape probe (`INFO`) | tells you whether the activation half of `schema.sql` was applied at all. It looks for the **5-arg** `issue_activation(uuid,text,inet,text,text)`, so a project still carrying only the pre-floor function reads as `CATALOG ONLY` |
| 1 | RLS **enabled** on `subscriptions`, `activation_events`, `releases`, `download_events` | `pg_class.relrowsecurity` is the live truth and does not depend on any policy existing |
| 2 | `subscriptions_select_own` exists, `cmd = SELECT`, roles `{authenticated}`, `qual` mentions `auth.uid()` | a policy of the right *name* with a hand-edited `USING (true)` would expose every user's entitlement row |
| 3 | `subscriptions` has **zero** `INSERT`/`UPDATE`/`DELETE`/`ALL` policies | with RLS on, "no policy" is what denies the write |
| 4 | `authenticated` on `subscriptions`: `SELECT` true, `INSERT`/`UPDATE`/`DELETE` false | a client that can write this table can self-grant a licence |
| 5 | `anon` on `subscriptions`: every verb false | `REVOKE ALL ... FROM anon` actually ran |
| 6 | `activation_events`: zero policies **and** no privilege for `anon` or `authenticated` on any verb | the ledger *is* the rate cap — a client that could `DELETE` from it could reset its own cap |
| 7 | `issue_activation(uuid,text,inet,text,text)` exists, `prosecdef = true`, `proconfig` pins `search_path=public` | a `SECURITY DEFINER` function without a pinned `search_path` is the classic hijack |
| 8 | `EXECUTE` on `issue_activation(uuid,text,inet,text,text)`: `service_role` true, `authenticated`/`anon` false | the RPC takes a user id as an *argument*, so a client caller could mint activations for any account. Two separate default grants have to be undone: `CREATE FUNCTION` grants `EXECUTE` to `PUBLIC`, **and** Supabase's default privileges grant it to `anon`/`authenticated` *directly* — which `REVOKE ... FROM PUBLIC` alone does **not** remove. `schema.sql` names all three; this check is what catches it if one is dropped |
| 9 | `subscriptions.current_period_end` `is_nullable = 'NO'` | the signed payload carries a **total** `subscriptionEndUtc`; the .NET verifier never has to reason about an absent date |
| 10 | Positive control: any public table with RLS **disabled** | catches a table nobody remembered to list in check 1 |
| 11 | `activation_events_outcome_check` admits `refused_outdated` | the version-floor refusal writes `outcome = 'refused_outdated'` to the ledger. Against a live CHECK that predates the floor, that INSERT raises, `issue_activation`'s exception handler converts it to `{"status": "error"}`, and every stale-build activation 500s instead of returning the 403 the app knows how to render. The `detail` column prints the live constraint text |
| 12 | The legacy 3-arg `issue_activation(uuid,text,inet)` overload is **gone** | Postgres overloads on the argument list, so `CREATE OR REPLACE` of the 5-arg function does **not** remove the 3-arg one — `schema.sql` drops it explicitly. Left behind it is an un-gated bypass: it takes no `build_tag`/`platform`, skips the minimum-version floor entirely, and `service_role` can still call it |
| 13 | `app_policy` exists, RLS **on**, **zero** policies, no `anon`/`authenticated` privilege on any verb | the floor lives in this table and check 1 does not list it. A client that could write it could lower or delete its own floor and keep activating a stale build; a missing table means no floor at all — every build activates. The `detail` column prints the **live floor per platform**, or `(no rows — no floor set)`: `schema.sql` creates the table but seeds no row |

## Reading the status values

- **PASS** — live matches intent.
- **FAIL** — a real mismatch. Chase it before shipping. The dangerous ones are
  RLS off on an existing table (1, 10), any write path onto `subscriptions`
  (3, 4), any client access to `activation_events` (6), `EXECUTE` on
  `issue_activation` reaching a client role (8), and any part of the version
  floor coming undone — a stale `outcome` domain (11), a surviving 3-arg
  overload (12), or a writable or missing `app_policy` (13).
- **INFO** — the check-0 shape row. Not a verdict; it tells you which objects
  exist so a wall of "table missing" FAILs is legible.
- **SUMMARY** — the last row: `FAIL` if any check above it failed.

## The deliberate-FAIL probe (prove the script can fail)

A self-audit that has only ever printed `PASS` has not been shown to work. Once,
on a project you are willing to mutate, confirm check 4 actually flips:

```sql
-- 1. baseline: run live-config-checks.sql — every row PASS.

-- 2. introduce the exact misconfiguration the check exists to catch:
GRANT UPDATE ON public.subscriptions TO authenticated;

-- 3. re-run live-config-checks.sql. Expect exactly one flip:
--      "4. authenticated -> subscriptions: UPDATE"  PASS -> FAIL
--    and the SUMMARY row FAIL. Everything else stays PASS.

-- 4. put it back, and re-run once more to confirm it returns to all-PASS:
REVOKE UPDATE ON public.subscriptions FROM authenticated;
```

Two honest notes on that probe:

- Steps 2 and 4 are **writes**. The rest of this file is read-only; the probe is
  not. Prefer a scratch project. If you must run it on production, run steps 2–4
  back to back and finish with the all-PASS re-run.
- During the probe window the grant is real but **not yet exploitable**: RLS is
  still on and there is still no `UPDATE` policy, so the write is denied by the
  policy layer even though the privilege exists. That is the point of checking
  both layers (3 *and* 4) — either one alone leaves a single mistake between an
  account and a self-granted licence.

## Honest caveats (what this script does NOT prove)

- It checks **structure**, not the behaviour of the running system. It cannot
  prove the `activate` edge function passes a *verified* user id to
  `issue_activation`, that the signing key in the function secrets is the one
  the shipped app trusts, or that the rate cap actually holds under concurrency
  (the cap is a read-then-insert, not `SERIALIZABLE` — the true ceiling is one
  over the configured maximum).
- It cannot prove the version floor actually **bites**. Check 13 shows the floor
  that is configured, not that any request is measured against it: the floor is
  skipped whenever the caller sends no `build_tag`/`platform`, and
  `app_policy.min_version` must equal a `releases.version` exactly — an
  unrecognised value fails **open** and the activation is granted. Only a real
  activation attempt from a stale build proves the refusal path.
- Check 2 reads the policy's `qual` text and only asserts that it *mentions*
  `auth.uid()`. A contrived qual could mention it and still be wrong; the
  printed `qual` is in the `detail` column, so read it the first time.
- It cannot see Dashboard-only settings: whether sign-up is disabled, the Auth
  redirect URLs, or which key the site actually ships. Those stay manual —
  see [`SETUP.md`](./SETUP.md).
