import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7'

const NONCE_MIN_BYTES = 16
const NONCE_MAX_BYTES = 64
const APP_VERSION_MAX_CHARS = 64
const BUILD_TAG_MAX_CHARS = 64
const RETRY_AFTER_FALLBACK_SECONDS = 600

function json(body: unknown, status: number, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  })
}

function toBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  return btoa(binary)
}

function base64UrlEncode(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function base64UrlDecode(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null
  if (value.length % 4 === 1) return null
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4)
  try {
    const binary = atob(padded)
    const out = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i)
    return out
  } catch (_) {
    return null
  }
}

let keyPromise: Promise<CryptoKey> | null = null

function signingKey(): Promise<CryptoKey> {
  if (keyPromise) return keyPromise
  keyPromise = (async () => {
    const pem = Deno.env.get('ACTIVATION_SIGNING_KEY') ?? ''
    const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
    const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
    return await crypto.subtle.importKey(
      'pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  })()
  return keyPromise
}

type Verdict = {
  status?: string
  tier?: string
  sub_status?: string
  subscription_end?: string
  window_end?: string
  server_time?: string
  reason?: string
  retry_after_seconds?: number
  latest_version?: string
  minimum_version?: string
}

serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const activationKeyId = Deno.env.get('ACTIVATION_KEY_ID') ?? ''
    const activationSigningKey = Deno.env.get('ACTIVATION_SIGNING_KEY') ?? ''

    const missing = [
      ['SUPABASE_URL', supabaseUrl],
      ['SUPABASE_ANON_KEY', supabaseAnonKey],
      ['SUPABASE_SERVICE_ROLE_KEY', supabaseServiceRoleKey],
      ['ACTIVATION_KEY_ID', activationKeyId],
      ['ACTIVATION_SIGNING_KEY', activationSigningKey],
    ].filter(([, v]) => !v).map(([k]) => k)

    if (missing.length > 0) {
      console.error('activate: missing required env:', missing.join(', '))
      return json({ error: 'internal_error' }, 500)
    }

    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.startsWith('Bearer ')
      ? authHeader.slice('Bearer '.length).trim()
      : ''

    if (!token) {
      return json({ error: 'unauthorized' }, 401)
    }

    const authClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data: authData, error: authError } = await authClient.auth.getUser(token)
    if (authError || !authData?.user) {
      return json({ error: 'unauthorized' }, 401)
    }

    const verifiedUserId = authData.user.id
    const verifiedEmail = authData.user.email ?? ''

    let parsed: unknown
    try {
      parsed = await req.json()
    } catch (_) {
      return json({ error: 'invalid_request' }, 400)
    }

    if (typeof parsed !== 'object' || parsed === null) {
      return json({ error: 'invalid_request' }, 400)
    }
    const body = parsed as {
      nonce?: unknown
      app_version?: unknown
      build_tag?: unknown
      platform?: unknown
    }

    const nonce = typeof body.nonce === 'string' ? body.nonce : ''
    const nonceBytes = nonce.length > 0 && nonce.length <= 256 ? base64UrlDecode(nonce) : null
    if (!nonceBytes || nonceBytes.length < NONCE_MIN_BYTES || nonceBytes.length > NONCE_MAX_BYTES) {
      return json({ error: 'invalid_request' }, 400)
    }

    const appVersion = typeof body.app_version === 'string' && body.app_version.trim()
      ? body.app_version.trim().slice(0, APP_VERSION_MAX_CHARS)
      : null

    const buildTag = typeof body.build_tag === 'string' && body.build_tag.trim()
      ? body.build_tag.trim().slice(0, BUILD_TAG_MAX_CHARS)
      : null

    const platform = body.platform === 'mac' || body.platform === 'win' ? body.platform : null

    const clientIp = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || null

    const admin = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    const { data: verdictData, error: rpcError } = await admin.rpc('issue_activation', {
      p_user_id: verifiedUserId,
      p_app_version: appVersion ?? null,
      p_client_ip: clientIp,
      p_build_tag: buildTag,
      p_platform: platform,
    })

    if (rpcError) {
      console.error('activate: issue_activation rpc failed:', rpcError)
      return json({ error: 'internal_error' }, 500)
    }

    const verdict = (verdictData ?? {}) as Verdict

    if (verdict.status === 'rate_limited') {
      const n = Number(verdict.retry_after_seconds)
      const retryAfter = Number.isFinite(n) && n > 0 ? Math.ceil(n) : RETRY_AFTER_FALLBACK_SECONDS
      return json(
        { error: 'rate_limited', retry_after_seconds: retryAfter },
        429,
        { 'Retry-After': String(retryAfter) },
      )
    }

    if (verdict.status === 'outdated_build') {
      return json({
        error: 'outdated_build',
        reason: 'outdated',
        latest_version: verdict.latest_version ?? '',
        minimum_version: verdict.minimum_version ?? '',
      }, 403)
    }

    if (verdict.status === 'inactive') {
      return json({ error: 'subscription_inactive', reason: verdict.reason ?? 'inactive' }, 403)
    }

    if (verdict.status !== 'ok') {
      console.error('activate: rpc returned status:', verdict.status)
      return json({ error: 'internal_error' }, 500)
    }

    if (!verdict.tier || !verdict.sub_status || !verdict.server_time ||
        !verdict.window_end || !verdict.subscription_end) {
      console.error('activate: rpc ok verdict missing fields:', JSON.stringify(verdict))
      return json({ error: 'internal_error' }, 500)
    }

    const payload = {
      v: 1,
      keyId: activationKeyId,
      nonce: nonce,
      userId: verifiedUserId,
      email: verifiedEmail,
      customer: verifiedEmail,
      org: '',
      tier: verdict.tier,
      status: verdict.sub_status,
      serverTimeUtc: verdict.server_time,
      windowEndUtc: verdict.window_end,
      subscriptionEndUtc: verdict.subscription_end,
    }

    const payloadBytes = new TextEncoder().encode(JSON.stringify(payload))

    const signatureBytes = new Uint8Array(await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' }, await signingKey(), payloadBytes))

    return json({
      payload: base64UrlEncode(payloadBytes),
      signature: toBase64(signatureBytes),
      keyId: activationKeyId,
      latest: verdict.latest_version ?? '',
    }, 200)
  } catch (error) {
    console.error('activate: unexpected error:', error)
    return json({ error: 'internal_error' }, 500)
  }
})
