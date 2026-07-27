-- Set minimum version — manual escape hatch; the release script raises this floor on its own
INSERT INTO public.app_policy (platform, min_version)
VALUES ('<mac|win>', '<VERSION e.g. 5.4>')
    ON CONFLICT (platform) DO UPDATE
   SET min_version = EXCLUDED.min_version,
       updated_at  = NOW()
RETURNING *;
