INSERT INTO public.subscriptions (user_id, status, tier, current_period_end, note)
VALUES ('<PASTE-UUID>', 'active', 'business', NOW() + INTERVAL '12 months', 'Premium access')
    ON CONFLICT (user_id) DO UPDATE
   SET status             = EXCLUDED.status,
       tier               = EXCLUDED.tier,
       current_period_end = EXCLUDED.current_period_end,
       note               = EXCLUDED.note
RETURNING *;
