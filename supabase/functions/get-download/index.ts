import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7'

const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? '*'

const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const GH_RELEASES_REPO = Deno.env.get('GH_RELEASES_REPO') ?? 'NicholasAntoniadesEngineer/ECSS_framework'
const GH_RELEASES_TOKEN = Deno.env.get('GH_RELEASES_TOKEN') ?? ''

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!

    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.startsWith('Bearer ')
      ? authHeader.slice('Bearer '.length).trim()
      : ''

    if (!token) {
      return json({ error: 'Unauthorized: missing bearer token' }, 401)
    }

    const authClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data: authData, error: authError } = await authClient.auth.getUser(token)
    if (authError || !authData?.user) {
      return json({ error: 'Unauthorized: invalid or expired token' }, 401)
    }
    const userId = authData.user.id

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

    // A download_events insert failure must never deny a valid download: log it and continue.
    const { error: logError } = await admin
      .from('download_events')
      .insert({ user_id: userId, release_id: release.id })
    if (logError) {
      console.error('get-download: download_events insert failed (continuing):', logError)
    }

    const assetUrl = `https://api.github.com/repos/${GH_RELEASES_REPO}/releases/assets/${release.asset_id}`
    let ghStatus = 0
    let location = ''
    // redirect:'manual' plus body.cancel(): we want only the 302's Location — following it would stream the whole multi-hundred-MB binary through this function.
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
      try { await ghResp.body?.cancel() } catch (_) { }
    } catch (fetchErr) {
      console.error('get-download: GitHub asset fetch failed:', fetchErr)
      return json({ error: 'Could not reach the download provider' }, 502)
    }

    if (ghStatus !== 302 || !location) {
      console.error('get-download: unexpected GitHub response status:', ghStatus)
      return json({ error: 'Could not create the download link' }, 502)
    }

    return json({ url: location }, 200)
  } catch (error) {
    console.error('get-download: unexpected error:', error)
    return json({ error: 'An unexpected error occurred' }, 500)
  }
})
