# Operator queries

The day-to-day SQL for running subscriptions and the version floor. Each file is
one saved query.

| File | What it does |
| --- | --- |
| [`add-demo-user.sql`](add-demo-user.sql) | Grants (or re-grants) one week of `demo` access. |
| [`add-premium-user.sql`](add-premium-user.sql) | Grants 12 months of `active` / `business` access — no demo watermark on rendered documents. |
| [`revoke-user.sql`](revoke-user.sql) | Sets `status` to `cancelled`. |
| [`user-status.sql`](user-status.sql) | Shows the entitlement row, then the last 10 activation attempts. |
| [`set-minimum-version.sql`](set-minimum-version.sql) | Sets the global minimum app version for one platform. |
| [`pin-user-version.sql`](pin-user-version.sql) | Overrides that floor for one user, or clears the override with `NULL`. |

## Using them

**SQL Editor → New query →** paste the file → **Save**, under the same name as
the file. They then sit in the sidebar, ready to open, edit and run.

Every file ships placeholders. Five take `'<PASTE-UUID>'`; `set-minimum-version.sql`
is the one that takes no uuid, and instead wants `'<mac|win>'` plus
`'<VERSION e.g. 5.4>'`. `pin-user-version.sql` carries the version placeholder with
its clear-the-override instruction spelled out inside the quotes — replace the whole
quoted string, either with a version or with a bare `NULL`. Replace them all before
running; never save a query with a real uuid baked in. Copy the uuid from
**Authentication → Users**.

A wrong uuid never silently does nothing, but what you see depends on the
statement:

- `revoke-user.sql`, `pin-user-version.sql` — `UPDATE ... RETURNING *`, so a uuid
  with no subscription row returns **0 rows**.
- `add-demo-user.sql`, `add-premium-user.sql` — `INSERT` against a foreign key to
  `auth.users`, so an unknown uuid **raises a foreign-key error** and a malformed
  one raises `invalid input syntax for type uuid`.
- `user-status.sql` — two plain `SELECT`s, no `RETURNING`; an unknown uuid is
  simply an empty result, which is also how "no entitlement row" looks.

## Two things worth knowing

Only `status` of **`active`** or **`demo`** entitles activation, and only while
`current_period_end` is still in the future. `cancelled` and `expired` are
refused before a signature is ever produced.

`current_period_end` is the value the signed activation document carries as the
subscription end — it is what the installed app reads, so it is the date that
decides when access stops. The offline window the app runs on is clamped to it.
