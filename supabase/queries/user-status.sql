SELECT *
  FROM public.subscriptions
 WHERE user_id = '<PASTE-UUID>';

SELECT occurred_at, outcome, window_end, app_version, client_ip
  FROM public.activation_events
 WHERE user_id = '<PASTE-UUID>'
 ORDER BY occurred_at DESC
 LIMIT 10;
