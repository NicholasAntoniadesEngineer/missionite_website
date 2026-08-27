import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7'

const ALLOWED_ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? '*'

const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const GH_RELEASES_REPO = Deno.env.get('GH_RELEASES_REPO') ?? 'NicholasAntoniadesEngineer/ECSS_framework'
const GH_RELEASES_TOKEN = (Deno.env.get('GH_RELEASES_TOKEN') ?? '').trim()

const TOKEN_FIX =
  'Mint a new fine-grained PAT (GitHub → Settings → Developer settings → Fine-grained tokens; ' +
  'resource owner NicholasAntoniadesEngineer; only ECSS_framework; Contents: Read-only) and run: ' +
  'supabase secrets set GH_RELEASES_TOKEN="<the PAT>"'

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function tokenMissingMessage(): string {
  return (
    'Could not create the download link. The download broker\'s GH_RELEASES_TOKEN is empty. ' +
    TOKEN_FIX
  )
}

function tokenRejectedMessage(httpStatus: number): string {
  return (
    'Could not create the download link. GitHub rejected the download broker\'s token ' +
    `(HTTP ${httpStatus}) — it is missing, expired, or revoked. GitHub often returns 404 ` +
    'for a private repo when the token is dead. ' +
    TOKEN_FIX
  )
}

function staleAssetMessage(httpStatus: number): string {
  return (
    'Could not create the download link. The catalogued GitHub asset id is not on the ' +
    `release (HTTP ${httpStatus}). The token is valid — re-run register-release.sh for ` +
    'this tag after the GitHub release assets are in place.'
  )
}

function githubFailureMessage(httpStatus: number): string {
  return (
    'Could not create the download link. GitHub did not return a signed file URL ' +
    `(HTTP ${httpStatus}).`
  )
}

type GithubGet = { status: number; location: string }

async function githubGet(
  url: string,
  accept: string,
  redirect: RequestRedirect,
): Promise<GithubGet> {
  const ghResp = await fetch(url, {
    method: 'GET',
    headers: {
      'Authorization': `Bearer ${GH_RELEASES_TOKEN}`,
      'Accept': accept,
      'User-Agent': 'missionite-get-download',
    },
    redirect,
  })
  const location = ghResp.headers.get('location') ?? ''
  try { await ghResp.body?.cancel() } catch (_) { }
  return { status: ghResp.status, location }
}

async function repoAccessStatus(): Promise<number> {
  const { status } = await githubGet(
    `https://api.github.com/repos/${GH_RELEASES_REPO}`,
    'application/vnd.github+json',
    'follow',
  )
  return status
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

    let body: { release_id?: string; probe?: boolean } = {}
    try {
      body = await req.json()
    } catch (_) {
      return json({ error: 'Invalid JSON body' }, 400)
    }

    if (body.probe === true) {
      if (!GH_RELEASES_TOKEN) {
        console.error('get-download: probe — GH_RELEASES_TOKEN is empty')
        return json({ error: tokenMissingMessage() }, 502)
      }
      let repoStatus = 0
      try {
        repoStatus = await repoAccessStatus()
      } catch (fetchErr) {
        console.error('get-download: probe GitHub repo fetch failed:', fetchErr)
        return json({ error: 'Could not reach the download provider' }, 502)
      }
      if (repoStatus === 200) return json({ ok: true }, 200)
      console.error('get-download: probe GitHub repo status:', repoStatus)
      return json({ error: tokenRejectedMessage(repoStatus) }, 502)
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

    const { error: logError } = await admin
      .from('download_events')
      .insert({ user_id: userId, release_id: release.id })
    if (logError) {
      console.error('get-download: download_events insert failed (continuing):', logError)
    }

    if (!GH_RELEASES_TOKEN) {
      console.error('get-download: GH_RELEASES_TOKEN is empty')
      return json({ error: tokenMissingMessage() }, 502)
    }

    const assetUrl = `https://api.github.com/repos/${GH_RELEASES_REPO}/releases/assets/${release.asset_id}`
    let ghStatus = 0
    let location = ''
    try {
      const asset = await githubGet(assetUrl, 'application/octet-stream', 'manual')
      ghStatus = asset.status
      location = asset.location
    } catch (fetchErr) {
      console.error('get-download: GitHub asset fetch failed:', fetchErr)
      return json({ error: 'Could not reach the download provider' }, 502)
    }

    if (ghStatus === 302 && location) {
      return json({ url: location }, 200)
    }

    if (ghStatus === 401 || ghStatus === 403) {
      console.error('get-download: GitHub rejected the releases token:', ghStatus)
      return json({ error: tokenRejectedMessage(ghStatus) }, 502)
    }

    if (ghStatus === 404) {
      let repoStatus = 0
      try {
        repoStatus = await repoAccessStatus()
      } catch (fetchErr) {
        console.error('get-download: GitHub repo check failed:', fetchErr)
        return json({ error: tokenRejectedMessage(404) }, 502)
      }
      if (repoStatus === 200) {
        console.error('get-download: catalogued asset missing:', release.asset_id)
        return json({ error: staleAssetMessage(404) }, 502)
      }
      console.error('get-download: GitHub 404 on asset; repo status:', repoStatus)
      return json({ error: tokenRejectedMessage(repoStatus || 404) }, 502)
    }

    console.error('get-download: unexpected GitHub response status:', ghStatus)
    return json({ error: githubFailureMessage(ghStatus) }, 502)
  } catch (error) {
    console.error('get-download: unexpected error:', error)
    return json({ error: 'An unexpected error occurred' }, 500)
  }
})
