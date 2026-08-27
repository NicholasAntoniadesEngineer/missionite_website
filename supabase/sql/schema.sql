CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS public.releases (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version       TEXT NOT NULL,
    platform      TEXT NOT NULL CHECK (platform IN ('mac', 'win')),
    asset_id      BIGINT NOT NULL,
    asset_name    TEXT NOT NULL,
    file_size     BIGINT,
    sha256        TEXT,
    notes         TEXT,
    published_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_releases_published_at ON public.releases(published_at DESC);
CREATE INDEX IF NOT EXISTS idx_releases_platform_published ON public.releases(platform, published_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS ux_releases_version_platform ON public.releases(version, platform);

ALTER TABLE public.releases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS releases_select_authenticated ON public.releases;
CREATE POLICY releases_select_authenticated ON public.releases
    FOR SELECT TO authenticated USING (true);

GRANT SELECT ON public.releases TO authenticated;
REVOKE ALL ON public.releases FROM anon;

CREATE TABLE IF NOT EXISTS public.download_events (
    id             BIGSERIAL PRIMARY KEY,
    user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    release_id     UUID NOT NULL REFERENCES public.releases(id) ON DELETE CASCADE,
    downloaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_download_events_release ON public.download_events(release_id);
CREATE INDEX IF NOT EXISTS idx_download_events_user ON public.download_events(user_id);
CREATE INDEX IF NOT EXISTS idx_download_events_time ON public.download_events(downloaded_at DESC);

ALTER TABLE public.download_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.download_events FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.subscriptions (
    user_id             UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    status              TEXT NOT NULL DEFAULT 'demo'
                        CHECK (status IN ('active', 'demo', 'cancelled', 'expired')),
    tier                TEXT NOT NULL DEFAULT 'demo'
                        CHECK (tier IN ('demo', 'standard', 'business')),
    current_period_end  TIMESTAMPTZ NOT NULL,
    note                TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS min_version_override TEXT;

CREATE INDEX IF NOT EXISTS idx_subscriptions_status_period
    ON public.subscriptions(status, current_period_end);

CREATE OR REPLACE FUNCTION public.touch_subscriptions_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.touch_subscriptions_updated_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_subscriptions_updated_at ON public.subscriptions;
CREATE TRIGGER trg_subscriptions_updated_at
    BEFORE UPDATE ON public.subscriptions
    FOR EACH ROW EXECUTE FUNCTION public.touch_subscriptions_updated_at();

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscriptions_select_own ON public.subscriptions;
CREATE POLICY subscriptions_select_own ON public.subscriptions
    FOR SELECT TO authenticated USING (user_id = auth.uid());

GRANT SELECT ON public.subscriptions TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.subscriptions FROM authenticated;
REVOKE ALL ON public.subscriptions FROM anon;

CREATE TABLE IF NOT EXISTS public.activation_events (
    id            BIGSERIAL PRIMARY KEY,
    user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    outcome       TEXT NOT NULL
                  CHECK (outcome IN ('granted', 'refused_inactive', 'refused_expired',
                                     'refused_absent', 'refused_outdated', 'rate_limited')),
    window_end    TIMESTAMPTZ,
    app_version   TEXT,
    client_ip     INET
);

ALTER TABLE public.activation_events DROP CONSTRAINT IF EXISTS activation_events_outcome_check;
ALTER TABLE public.activation_events ADD CONSTRAINT activation_events_outcome_check
    CHECK (outcome IN ('granted', 'refused_inactive', 'refused_expired',
                       'refused_absent', 'refused_outdated', 'rate_limited'));

CREATE INDEX IF NOT EXISTS idx_activation_events_user_time
    ON public.activation_events(user_id, occurred_at DESC);

ALTER TABLE public.activation_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.activation_events FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.app_policy (
    platform     TEXT PRIMARY KEY CHECK (platform IN ('mac', 'win')),
    min_version  TEXT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.app_policy ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.app_policy FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.issue_activation(
    p_user_id     UUID,
    p_app_version TEXT DEFAULT NULL,
    p_client_ip   INET DEFAULT NULL,
    p_build_tag   TEXT DEFAULT NULL,
    p_platform    TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    DAY_WINDOW    CONSTANT INTERVAL := INTERVAL '24 hours';
    DAY_MAX       CONSTANT INTEGER  := 40;
    BURST_WINDOW  CONSTANT INTERVAL := INTERVAL '10 minutes';
    BURST_MAX     CONSTANT INTEGER  := 12;
    OFFLINE_SPAN  CONSTANT INTERVAL := INTERVAL '14 days';
    v_now       TIMESTAMPTZ := NOW();
    v_day       INTEGER;
    v_burst     INTEGER;
    v_sub       public.subscriptions%ROWTYPE;
    v_window    TIMESTAMPTZ;
    v_reason    TEXT;
    v_tag       TEXT;
    v_floor     TEXT;
    v_client_at TIMESTAMPTZ;
    v_floor_at  TIMESTAMPTZ;
    v_latest    TEXT;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error');
    END IF;

    SELECT count(*) INTO v_day   FROM activation_events
     WHERE user_id = p_user_id AND occurred_at > v_now - DAY_WINDOW
       AND outcome NOT IN ('refused_outdated', 'rate_limited');
    SELECT count(*) INTO v_burst FROM activation_events
     WHERE user_id = p_user_id AND occurred_at > v_now - BURST_WINDOW
       AND outcome NOT IN ('refused_outdated', 'rate_limited');

    IF v_day >= DAY_MAX OR v_burst >= BURST_MAX THEN
        INSERT INTO activation_events (user_id, outcome, app_version, client_ip)
             VALUES (p_user_id, 'rate_limited', p_app_version, p_client_ip);
        RETURN jsonb_build_object(
            'status', 'rate_limited',
            'retry_after_seconds',
            CASE WHEN v_burst >= BURST_MAX
                 THEN EXTRACT(EPOCH FROM BURST_WINDOW)::int
                 ELSE EXTRACT(EPOCH FROM DAY_WINDOW)::int END);
    END IF;

    SELECT * INTO v_sub FROM subscriptions WHERE user_id = p_user_id;

    IF NOT FOUND THEN
        v_reason := 'absent';
    ELSIF v_sub.status NOT IN ('active', 'demo') THEN
        v_reason := 'inactive';
    ELSIF v_sub.current_period_end <= v_now THEN
        v_reason := 'expired';
    END IF;

    IF v_reason IS NOT NULL THEN
        INSERT INTO activation_events (user_id, outcome, app_version, client_ip)
             VALUES (p_user_id, 'refused_' || v_reason, p_app_version, p_client_ip);
        RETURN jsonb_build_object('status', 'inactive', 'reason', v_reason);
    END IF;

    SELECT version INTO v_latest FROM releases
     WHERE platform = p_platform
     ORDER BY published_at DESC LIMIT 1;

    IF p_build_tag IS NOT NULL AND p_platform IS NOT NULL THEN
        v_tag   := regexp_replace(p_build_tag, '^[vV]', '');
        v_floor := COALESCE(v_sub.min_version_override,
                            (SELECT min_version FROM app_policy WHERE platform = p_platform));

        IF v_floor IS NOT NULL THEN
            SELECT max(published_at) INTO v_client_at FROM releases
             WHERE platform = p_platform AND version = v_tag;
            SELECT max(published_at) INTO v_floor_at  FROM releases
             WHERE platform = p_platform AND version = v_floor;

            IF v_client_at IS NOT NULL AND v_floor_at IS NOT NULL AND v_client_at < v_floor_at THEN
                INSERT INTO activation_events (user_id, outcome, app_version, client_ip)
                     VALUES (p_user_id, 'refused_outdated', p_app_version, p_client_ip);
                RETURN jsonb_build_object(
                    'status',          'outdated_build',
                    'latest_version',  v_latest,
                    'minimum_version', v_floor);
            END IF;
        END IF;
    END IF;

    v_window := LEAST(v_now + OFFLINE_SPAN, v_sub.current_period_end);

    INSERT INTO activation_events (user_id, outcome, window_end, app_version, client_ip)
         VALUES (p_user_id, 'granted', v_window, p_app_version, p_client_ip);

    RETURN jsonb_build_object(
        'status',            'ok',
        'tier',              v_sub.tier,
        'sub_status',        v_sub.status,
        'subscription_end',  to_char(v_sub.current_period_end AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'window_end',        to_char(v_window                 AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'server_time',       to_char(v_now                    AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'latest_version',    v_latest);
EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'issue_activation: %', SQLERRM;
    RETURN jsonb_build_object('status', 'error');
END;
$$;

DROP FUNCTION IF EXISTS public.issue_activation(uuid, text, inet);

REVOKE ALL ON FUNCTION public.issue_activation(UUID, TEXT, INET, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_activation(UUID, TEXT, INET, TEXT, TEXT) TO service_role;
