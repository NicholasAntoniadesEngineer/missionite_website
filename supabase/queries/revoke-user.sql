UPDATE public.subscriptions
   SET status = 'cancelled'
 WHERE user_id = '<PASTE-UUID>'
RETURNING *;
