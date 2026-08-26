DELETE FROM public.activation_events WHERE outcome = 'rate_limited';

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

REVOKE ALL ON FUNCTION public.issue_activation(UUID, TEXT, INET, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_activation(UUID, TEXT, INET, TEXT, TEXT) TO service_role;
