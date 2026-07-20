-- ============================================================================
-- Missionite — release catalog schema (run ONCE on the dedicated project)
-- ============================================================================
-- Creates the two tables the download page + edge function need:
--   * releases        — the published build catalog (SELECT: authenticated only)
--   * download_events  — an audit log of who downloaded what (service-role only)
--
-- This file is SAFE TO RE-RUN: it uses CREATE TABLE IF NOT EXISTS, DROP POLICY
-- IF EXISTS before each CREATE POLICY, and CREATE INDEX IF NOT EXISTS. It never
-- DROPs a table, so re-running will not wipe your catalog or audit history.
--
-- Run it in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- (See supabase/SETUP.md for the full click-path.)
--
-- SECURITY MODEL
--   - RLS is ENABLED on both tables. There are NO anon/public policies anywhere.
--   - releases: any AUTHENTICATED (signed-in) user may SELECT. No client may
--     INSERT/UPDATE/DELETE — the catalog is written only with the service role
--     key (which BYPASSES RLS) from register-release.sh.
--   - download_events: RLS is enabled with NO policies, so neither anon nor
--     authenticated can SELECT or INSERT. Only the get-download edge function,
--     using the service role key (BYPASSES RLS), writes rows. You read the log
--     from the dashboard (also service role). This keeps the who-downloaded-what
--     graph private to the operator.
-- ============================================================================

-- Required for gen_random_uuid() (present by default on Supabase; idempotent).
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- releases — the published build catalog
-- ---------------------------------------------------------------------------
-- A row points at a GitHub Release ASSET (by numeric id) on the PRIVATE app repo
-- — the binaries are NOT stored in Supabase (see the note at the bottom).
CREATE TABLE IF NOT EXISTS public.releases (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version       TEXT NOT NULL,                         -- e.g. "5.3"
    platform      TEXT NOT NULL CHECK (platform IN ('mac', 'win')),
    asset_id      BIGINT NOT NULL,                       -- GitHub Release asset numeric id
    asset_name    TEXT NOT NULL,                         -- GitHub asset file name (for display/reference)
    file_size     BIGINT,                                -- bytes (from the GitHub asset metadata)
    sha256        TEXT,                                  -- lower-case hex digest of the artifact
    notes         TEXT,                                  -- release notes / changelog line
    published_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.releases IS 'Published Missionite desktop builds. SELECT-able by any authenticated user; written only via the service role (register-release.sh).';
COMMENT ON COLUMN public.releases.asset_id   IS 'GitHub Release asset numeric id (repos/<owner>/<repo>/releases/assets/<id>). The get-download edge function exchanges it for a short-lived, GitHub-signed URL — never a public link.';
COMMENT ON COLUMN public.releases.asset_name IS 'GitHub Release asset file name, e.g. "Missionite v5.3 2026-07-20T18-54-35Z.dmg". Shown for reference; the download is brokered via asset_id, not this name.';
COMMENT ON COLUMN public.releases.platform   IS 'Target platform: ''mac'' or ''win''.';

-- Ordering / lookup indexes (newest first, and newest-per-platform).
CREATE INDEX IF NOT EXISTS idx_releases_published_at ON public.releases(published_at DESC);
CREATE INDEX IF NOT EXISTS idx_releases_platform_published ON public.releases(platform, published_at DESC);

ALTER TABLE public.releases ENABLE ROW LEVEL SECURITY;

-- SELECT: signed-in users only (never anon). No INSERT/UPDATE/DELETE policy is
-- defined, so ordinary clients cannot write the catalog; the service role does
-- (it bypasses RLS). This is the whole client-side security boundary.
DROP POLICY IF EXISTS releases_select_authenticated ON public.releases;
CREATE POLICY releases_select_authenticated ON public.releases
    FOR SELECT TO authenticated USING (true);

-- Grants: allow the authenticated role to SELECT (RLS still narrows it via the
-- policy above); make sure anon has nothing.
GRANT SELECT ON public.releases TO authenticated;
REVOKE ALL ON public.releases FROM anon;

-- ---------------------------------------------------------------------------
-- download_events — audit log (service-role writes only; no client access)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.download_events (
    id             BIGSERIAL PRIMARY KEY,
    user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    release_id     UUID NOT NULL REFERENCES public.releases(id) ON DELETE CASCADE,
    downloaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.download_events IS 'Audit log: one row per download URL issued by the get-download edge function. Written only by the service role; not readable/insertable by anon or authenticated.';

CREATE INDEX IF NOT EXISTS idx_download_events_release ON public.download_events(release_id);
CREATE INDEX IF NOT EXISTS idx_download_events_user ON public.download_events(user_id);
CREATE INDEX IF NOT EXISTS idx_download_events_time ON public.download_events(downloaded_at DESC);

-- RLS ENABLED, and DELIBERATELY NO POLICIES: with RLS on and no policy, the
-- anon and authenticated roles are denied ALL access (SELECT and INSERT). Only
-- the service role (edge function) — which bypasses RLS — can insert. Belt-and-
-- suspenders: revoke every table privilege from the client roles too.
ALTER TABLE public.download_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.download_events FROM anon, authenticated;

-- (No GRANT to anon/authenticated anywhere. The service role needs no GRANT: it
--  owns/bypasses RLS and already has table privileges as a superuser-like role.)

-- ============================================================================
-- BINARIES — served from GitHub Releases (NOT Supabase Storage)
-- ============================================================================
-- The demo binaries are NOT stored in Supabase. They live as ASSETS on GitHub
-- Releases of the PRIVATE app repo (NicholasAntoniadesEngineer/ECSS_framework):
-- the free Supabase tier's per-file caps can't hold the ~144 MB / ~253 MB builds.
--
-- This table stores only the GitHub numeric asset id (asset_id) plus its file
-- name (asset_name). At request time the get-download edge function — holding a
-- fine-grained PAT with Contents:read on that private repo — exchanges asset_id
-- for a short-lived, GitHub-signed download URL (GET .../releases/assets/<id>
-- with Accept: application/octet-stream and redirect: manual, yielding a 302
-- whose Location header is the signed URL). The PAT is never exposed to the
-- browser; Supabase (free) only stores this metadata + the audit log and runs
-- the authenticated broker. There is no storage bucket to create.
-- ============================================================================
