UPDATE public.subscriptions
   SET min_version_override = '<VERSION e.g. 5.4 — or replace the quoted value with a bare NULL to follow the global floor>'
 WHERE user_id = '<PASTE-UUID>'
RETURNING *;
