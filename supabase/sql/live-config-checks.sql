WITH

c0 AS (
  SELECT
    '00'   AS seq,
    '0. schema shape'                                                AS check_name,
    'INFO'                                                           AS status,
    CASE
      WHEN to_regclass('public.subscriptions')    IS NOT NULL
       AND to_regclass('public.activation_events') IS NOT NULL
       AND to_regprocedure('public.issue_activation(uuid,text,inet,text,text)') IS NOT NULL
        THEN 'FULL — catalog + activation (subscriptions, activation_events, issue_activation)'
      WHEN to_regclass('public.releases') IS NOT NULL
        THEN 'CATALOG ONLY — the activation section of schema.sql has NOT been applied'
      ELSE 'UNRECOGNISED — neither the catalog nor the activation objects are present'
    END                                                              AS detail
),

c1 AS (
  SELECT
    '01'                                                             AS seq,
    '1. RLS enabled: ' || e.tbl                                      AS check_name,
    CASE
      WHEN c.relname IS NULL                          THEN 'FAIL'
      WHEN c.relrowsecurity IS DISTINCT FROM TRUE     THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    CASE
      WHEN c.relname IS NULL                          THEN 'table missing — schema.sql was not applied here'
      WHEN c.relrowsecurity IS DISTINCT FROM TRUE     THEN 'RLS DISABLED on an existing table'
      ELSE 'RLS on'
    END                                                              AS detail
  FROM (VALUES ('subscriptions'), ('activation_events'),
               ('releases'),      ('download_events')) AS e(tbl)
  LEFT JOIN pg_class c
    ON c.relname     = e.tbl
   AND c.relnamespace = 'public'::regnamespace
   AND c.relkind      = 'r'
),

c2 AS (
  SELECT
    '02'                                                             AS seq,
    '2. policy subscriptions_select_own: SELECT / {authenticated} / auth.uid()' AS check_name,
    CASE
      WHEN p.policyname IS NULL                            THEN 'FAIL'
      WHEN p.cmd <> 'SELECT'                               THEN 'FAIL'
      WHEN p.roles::text[] <> ARRAY['authenticated']       THEN 'FAIL'
      WHEN coalesce(p.qual, '') NOT ILIKE '%auth.uid()%'   THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    CASE
      WHEN p.policyname IS NULL THEN 'policy missing — either RLS drifted or no client can read its own row'
      ELSE 'cmd=' || p.cmd || '  roles=' || p.roles::text || '  qual=' || coalesce(p.qual, '(null)')
    END                                                              AS detail
  FROM (SELECT 1) d
  LEFT JOIN pg_policies p
    ON p.schemaname = 'public'
   AND p.tablename  = 'subscriptions'
   AND p.policyname = 'subscriptions_select_own'
),

c3 AS (
  SELECT
    '03'                                                             AS seq,
    '3. subscriptions has ZERO INSERT/UPDATE/DELETE/ALL policies'    AS check_name,
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END               AS status,
    CASE
      WHEN count(*) = 0 THEN 'no write policy exists — clients cannot write their own entitlement'
      ELSE 'WRITE POLICY PRESENT: ' || string_agg(policyname || ' (' || cmd || ')', ', ' ORDER BY policyname)
    END                                                              AS detail
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'subscriptions'
    AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
),

c4 AS (
  SELECT
    '04'                                                             AS seq,
    '4. authenticated -> subscriptions: ' || v.verb                  AS check_name,
    CASE
      WHEN to_regclass('public.subscriptions') IS NULL
        OR to_regrole('authenticated') IS NULL                       THEN 'FAIL'
      WHEN has_table_privilege('authenticated', 'public.subscriptions', v.verb) = v.expected THEN 'PASS'
      ELSE 'FAIL'
    END                                                              AS status,
    'expected ' || v.expected::text || ' — ' || v.why                AS detail
  FROM (VALUES
      ('SELECT', TRUE,  'the site shows a signed-in user their own status'),
      ('INSERT', FALSE, 'a client that can INSERT can self-grant a licence'),
      ('UPDATE', FALSE, 'a client that can UPDATE can extend its own period'),
      ('DELETE', FALSE, 'a client that can DELETE can erase the operator record')
  ) AS v(verb, expected, why)
),

c5 AS (
  SELECT
    '05'                                                             AS seq,
    '5. anon -> subscriptions: ' || v.verb                           AS check_name,
    CASE
      WHEN to_regclass('public.subscriptions') IS NULL
        OR to_regrole('anon') IS NULL                                THEN 'FAIL'
      WHEN has_table_privilege('anon', 'public.subscriptions', v.verb) THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    'anon must hold no privilege at all on the entitlement table'    AS detail
  FROM (VALUES ('SELECT'), ('INSERT'), ('UPDATE'),
               ('DELETE'), ('TRUNCATE'), ('REFERENCES')) AS v(verb)
),

c6a AS (
  SELECT
    '06'                                                             AS seq,
    '6a. activation_events has ZERO policies'                        AS check_name,
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END               AS status,
    CASE
      WHEN count(*) = 0 THEN 'RLS on with no policy denies every client role'
      ELSE 'POLICY PRESENT: ' || string_agg(policyname || ' (' || cmd || ')', ', ' ORDER BY policyname)
    END                                                              AS detail
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'activation_events'
),

c6b AS (
  SELECT
    '06'                                                             AS seq,
    '6b. ' || r.rolename || ' -> activation_events: ' || v.verb      AS check_name,
    CASE
      WHEN to_regclass('public.activation_events') IS NULL
        OR to_regrole(r.rolename) IS NULL                            THEN 'FAIL'
      WHEN has_table_privilege(r.rolename, 'public.activation_events', v.verb) THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    'the rate-limit ledger must be unreadable and unwritable by clients' AS detail
  FROM (VALUES ('anon'), ('authenticated')) AS r(rolename)
  CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'),
                     ('DELETE'), ('TRUNCATE'), ('REFERENCES')) AS v(verb)
),

c7 AS (
  SELECT
    '07'                                                             AS seq,
    '7. issue_activation: exists + SECURITY DEFINER + pinned search_path' AS check_name,
    CASE
      WHEN p.oid IS NULL           THEN 'FAIL'
      WHEN p.prosecdef IS NOT TRUE THEN 'FAIL'
      WHEN NOT EXISTS (
             SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
             WHERE cfg ILIKE 'search_path=%' AND cfg ILIKE '%public%'
           )                       THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    CASE
      WHEN p.oid IS NULL THEN 'public.issue_activation(uuid,text,inet,text,text) not found'
      ELSE 'prosecdef=' || p.prosecdef::text || '  proconfig=' || coalesce(array_to_string(p.proconfig, ', '), '(none)')
    END                                                              AS detail
  FROM (SELECT 1) d
  LEFT JOIN pg_proc p
    ON p.oid = to_regprocedure('public.issue_activation(uuid,text,inet,text,text)')::oid
),

c8 AS (
  SELECT
    '08'                                                             AS seq,
    '8. EXECUTE issue_activation -> ' || r.rolename                  AS check_name,
    CASE
      WHEN to_regprocedure('public.issue_activation(uuid,text,inet,text,text)') IS NULL
        OR to_regrole(r.rolename) IS NULL                            THEN 'FAIL'
      WHEN has_function_privilege(r.rolename, 'public.issue_activation(uuid,text,inet,text,text)', 'EXECUTE') = r.expected THEN 'PASS'
      ELSE 'FAIL'
    END                                                              AS status,
    'expected ' || r.expected::text || ' — ' || r.why                AS detail
  FROM (VALUES
      ('authenticated', FALSE, 'the RPC takes a user id as an ARGUMENT; a client caller could mint activations for any account'),
      ('anon',          FALSE, 'an unauthenticated caller must never reach the signer'),
      ('service_role',  TRUE,  'the activate edge function calls it after JWT-verifying the caller')
  ) AS r(rolename, expected, why)
),

c9 AS (
  SELECT
    '09'                                                             AS seq,
    '9. subscriptions.current_period_end is NOT NULL'                AS check_name,
    CASE
      WHEN c.column_name IS NULL   THEN 'FAIL'
      WHEN c.is_nullable = 'NO'    THEN 'PASS'
      ELSE 'FAIL'
    END                                                              AS status,
    CASE
      WHEN c.column_name IS NULL THEN 'column missing'
      WHEN c.is_nullable = 'NO'  THEN 'subscriptionEndUtc in the signed payload stays total'
      ELSE 'NULLABLE — a NULL period would emit an absent subscriptionEndUtc'
    END                                                              AS detail
  FROM (SELECT 1) d
  LEFT JOIN information_schema.columns c
    ON c.table_schema = 'public'
   AND c.table_name   = 'subscriptions'
   AND c.column_name  = 'current_period_end'
),

c10 AS (
  SELECT
    '10'                                                             AS seq,
    '10. positive control: public tables with RLS DISABLED'          AS check_name,
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END               AS status,
    CASE
      WHEN count(*) = 0 THEN 'every public base table has RLS on'
      ELSE 'RLS OFF: ' || string_agg(relname, ', ' ORDER BY relname)
    END                                                              AS detail
  FROM pg_class
  WHERE relnamespace  = 'public'::regnamespace
    AND relkind       = 'r'
    AND relrowsecurity = FALSE
),

c11 AS (
  SELECT
    '11'                                                             AS seq,
    '11. activation_events.outcome CHECK admits refused_outdated'    AS check_name,
    CASE
      WHEN d.def IS NULL                   THEN 'FAIL'
      WHEN d.def LIKE '%refused_outdated%' THEN 'PASS'
      ELSE 'FAIL'
    END                                                              AS status,
    CASE
      WHEN d.def IS NULL THEN 'constraint activation_events_outcome_check not found — the ledger INSERT cannot be trusted to stay inside a known domain'
      WHEN d.def NOT LIKE '%refused_outdated%' THEN 'STALE DOMAIN: ' || d.def || ' — the version-floor INSERT would raise and every stale-build activation would 500'
      ELSE d.def
    END                                                              AS detail
  FROM (SELECT 1) x
  LEFT JOIN (
    SELECT pg_get_constraintdef(oid) AS def
      FROM pg_constraint
     WHERE conrelid = to_regclass('public.activation_events')::oid
       AND conname  = 'activation_events_outcome_check'
  ) d ON TRUE
),

c12 AS (
  SELECT
    '12'                                                             AS seq,
    '12. legacy 3-arg issue_activation overload is GONE'             AS check_name,
    CASE
      WHEN to_regprocedure('public.issue_activation(uuid,text,inet)') IS NULL THEN 'PASS'
      ELSE 'FAIL'
    END                                                              AS status,
    CASE
      WHEN to_regprocedure('public.issue_activation(uuid,text,inet)') IS NULL
        THEN 'only the version-gated signature remains'
      ELSE 'UN-GATED OVERLOAD PRESENT: the 3-arg function skips the minimum-version floor entirely and service_role can still call it'
    END                                                              AS detail
),

c13 AS (
  SELECT
    '13'                                                             AS seq,
    '13. app_policy: exists + RLS on + zero policies + no client privileges' AS check_name,
    CASE
      WHEN to_regclass('public.app_policy') IS NULL THEN 'FAIL'
      WHEN (SELECT relrowsecurity FROM pg_class
             WHERE oid = to_regclass('public.app_policy')::oid) IS NOT TRUE THEN 'FAIL'
      WHEN (SELECT count(*) FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'app_policy') > 0 THEN 'FAIL'
      WHEN EXISTS (
             SELECT 1
               FROM (VALUES ('anon'), ('authenticated')) AS r(rolename)
               CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'),
                                  ('DELETE'), ('TRUNCATE'), ('REFERENCES')) AS v(verb)
              WHERE to_regrole(r.rolename) IS NOT NULL
                AND has_table_privilege(r.rolename, 'public.app_policy', v.verb)
           ) THEN 'FAIL'
      ELSE 'PASS'
    END                                                              AS status,
    CASE
      WHEN to_regclass('public.app_policy') IS NULL
        THEN 'table missing — no minimum-version floor can be enforced, every build activates'
      ELSE 'live floor — ' || coalesce((xpath('/row/f/text()', query_to_xml(
             'SELECT coalesce(string_agg(platform || ''='' || min_version, '', '' ORDER BY platform), ''(no rows — no floor set)'') AS f FROM public.app_policy',
             false, true, '')))[1]::text, '(unreadable)')
    END                                                              AS detail
),

all_checks AS (
  SELECT * FROM c0  UNION ALL
  SELECT * FROM c1  UNION ALL
  SELECT * FROM c2  UNION ALL
  SELECT * FROM c3  UNION ALL
  SELECT * FROM c4  UNION ALL
  SELECT * FROM c5  UNION ALL
  SELECT * FROM c6a UNION ALL
  SELECT * FROM c6b UNION ALL
  SELECT * FROM c7  UNION ALL
  SELECT * FROM c8  UNION ALL
  SELECT * FROM c9  UNION ALL
  SELECT * FROM c10 UNION ALL
  SELECT * FROM c11 UNION ALL
  SELECT * FROM c12 UNION ALL
  SELECT * FROM c13
)

SELECT seq, check_name, status, detail FROM all_checks
UNION ALL
SELECT
  'ZZ',
  'SUMMARY — chase every FAIL before shipping a release',
  CASE WHEN count(*) FILTER (WHERE status = 'FAIL') > 0 THEN 'FAIL' ELSE 'PASS' END,
  (count(*) FILTER (WHERE status = 'PASS'))::text || ' PASS / ' ||
  (count(*) FILTER (WHERE status = 'FAIL'))::text || ' FAIL / ' ||
  (count(*) FILTER (WHERE status NOT IN ('PASS', 'FAIL')))::text || ' INFO'
FROM all_checks
ORDER BY 1, 2;
