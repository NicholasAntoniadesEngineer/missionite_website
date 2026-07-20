import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7'

/**
 * Missionite — get-download edge function
 * ---------------------------------------------------------------------------
 * An authenticated BROKER for the demo binaries, which live as ASSETS on GitHub
 * Releases of the PRIVATE app repo (NicholasAntoniadesEngineer/ECSS_framework) —
 * NOT in Supabase Storage. The browser never sees the asset or the PAT: it POSTs
 * a release_id with the signed-in user's access token, and this function (after
 * verifying that token) looks up the GitHub asset id, asks GitHub for a short-
 * lived signed URL, records the download, and returns that URL.
 *
 * How the URL is minted: GET https://api.github.com/repos/<repo>/releases/assets/<id>
 * with `Accept: application/octet-stream` and `redirect: "manual"` returns a 302
 * whose `Location` header is GitHub's own short-lived signed download URL. We
 * return that Location; the fine-grained PAT never leaves the server.
 *
 * Request:  POST { release_id: string }
 *           Headers: Authorization: Bearer <user access token>
 * Response: 200 { url }            — short-lived GitHub-signed download URL
 *           400 { error }          — missing/invalid body
 *           401 { error }          — missing/invalid/expired token
 *           404 { error }          — unknown release_id
 *           500 { error }          — unexpected server error
 *           502 { error }          — GitHub did not return the expected redirect
 *
 * Secrets (Deno.env): GH_RELEASES_TOKEN (fine-grained PAT scoped to the app repo
 * with Contents: Read-only) and GH_RELEASES_REPO (default the app repo below).
 *
 * CORS: this is a broker authorized by a per-user Bearer token (no cookies), so a
 * wildcard origin is safe and keeps it usable from the GitHub Pages origin.
 * Override with the ALLOWED_ORIGIN env var to pin it if desired.
 */

const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? '*'

const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// GitHub Releases source for the private binaries.
const GH_RELEASES_REPO = Deno.env.get('GH_RELEASES_REPO') ?? 'NicholasAntoniadesEngineer/ECSS_framework'
const GH_RELEASES_TOKEN = Deno.env.get('GH_RELEASES_TOKEN') ?? ''

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

serve(async (req) => {
  // CORS preflight.
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  // Only POST is supported.
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!

    // ---- 1) Authenticate the caller BEFORE any privileged work ----
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.startsWith('Bearer ')
      ? authHeader.slice('Bearer '.length).trim()
      : ''

    if (!token) {
      return json({ error: 'Unauthorized: missing bearer token' }, 401)
    }

    // Verify the JWT with the non-privileged anon client (auth.getUser). The bare
    // anon key has no associated user, so it is rejected here too.
    const authClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data: authData, error: authError } = await authClient.auth.getUser(token)
    if (authError || !authData?.user) {
      return json({ error: 'Unauthorized: invalid or expired token' }, 401)
    }
    const userId = authData.user.id

    // ---- 2) Parse the request body ----
    let body: { release_id?: string } = {}
    try {
      body = await req.json()
    } catch (_) {
      return json({ error: 'Invalid JSON body' }, 400)
    }
    const releaseId = (body.release_id ?? '').toString().trim()
    if (!releaseId) {
      return json({ error: 'release_id is required' }, 400)
    }

    // ---- 3) Look up the release with the service role (bypasses RLS) ----
    const admin = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    const { data: release, error: relError } = await admin
      .from('releases')
      .select('id, asset_id')
      .eq('id', releaseId)
      .maybeSingle()

    if (relError) {
      console.error('get-download: release lookup error:', relError)
      return json({ error: 'Failed to look up release' }, 500)
    }
    if (!release || release.asset_id == null) {
      return json({ error: 'Unknown release' }, 404)
    }

    // ---- 4) Record the download (best effort — never block the user on the log) ----
    const { error: logError } = await admin
      .from('download_events')
      .insert({ user_id: userId, release_id: release.id })
    if (logError) {
      // Log server-side and continue: an audit-log hiccup must not deny a valid download.
      console.error('get-download: download_events insert failed (continuing):', logError)
    }

    // ---- 5) Ask GitHub for a short-lived signed URL for the private asset ----
    // GET the asset with Accept: octet-stream and manual redirect handling: GitHub
    // answers 302 with the signed URL in the Location header. The PAT is never
    // returned to the caller — only the resulting short-lived URL is.
    const assetUrl = `https://api.github.com/repos/${GH_RELEASES_REPO}/releases/assets/${release.asset_id}`
    let ghStatus = 0
    let location = ''
    try {
      const ghResp = await fetch(assetUrl, {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${GH_RELEASES_TOKEN}`,
          'Accept': 'application/octet-stream',
          'User-Agent': 'missionite-get-download',
        },
        redirect: 'manual',
      })
      ghStatus = ghResp.status
      location = ghResp.headers.get('location') ?? ''
      // We only ever needed the headers; drain/close the body so nothing leaks.
      try { await ghResp.body?.cancel() } catch (_) { /* ignore */ }
    } catch (fetchErr) {
      console.error('get-download: GitHub asset fetch failed:', fetchErr)
      return json({ error: 'Could not reach the download provider' }, 502)
    }

    // GitHub answers a 302 whose Location is the short-lived signed URL. Anything
    // else (401 bad/again-missing token, 404 asset gone, 5xx) is a broker failure.
    if (ghStatus !== 302 || !location) {
      console.error('get-download: unexpected GitHub response status:', ghStatus)
      return json({ error: 'Could not create the download link' }, 502)
    }

    return json({ url: location }, 200)
  } catch (error) {
    console.error('get-download: unexpected error:', error)
    return json({ error: (error as Error)?.message || 'An unexpected error occurred' }, 500)
  }
})
