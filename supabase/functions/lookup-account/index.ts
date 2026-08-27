import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7'

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function notRegistered(): Response {
  return json({ error: 'not_registered' }, 404)
}

type AuthUser = {
  id: string
  email?: string | null
  user_metadata?: Record<string, unknown> | null
}

function displayNameOf(user: AuthUser, email: string): string {
  const meta = user.user_metadata ?? {}
  for (const key of ['full_name', 'display_name', 'name']) {
    const value = meta[key]
    if (typeof value === 'string' && value.trim().length > 0) {
      return value.trim()
    }
  }
  return email
}

serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

    const missing = [
      ['SUPABASE_URL', supabaseUrl],
      ['SUPABASE_ANON_KEY', supabaseAnonKey],
      ['SUPABASE_SERVICE_ROLE_KEY', supabaseServiceRoleKey],
    ].filter(([, v]) => !v).map(([k]) => k)

    if (missing.length > 0) {
      console.error('lookup-account: missing required env:', missing.join(', '))
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

    let parsed: unknown
    try {
      parsed = await req.json()
    } catch (_) {
      return json({ error: 'invalid_request' }, 400)
    }

    if (typeof parsed !== 'object' || parsed === null) {
      return json({ error: 'invalid_request' }, 400)
    }

    const rawEmail = (parsed as { email?: unknown }).email
    const email = typeof rawEmail === 'string' ? rawEmail.trim().toLowerCase() : ''
    if (email.length === 0 || !email.includes('@')) {
      return json({ error: 'invalid_request' }, 400)
    }

    const admin = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    let found: AuthUser | null = null
    for (let page = 1; page <= 10; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 })
      if (error) {
        console.error('lookup-account: listUsers failed:', error)
        return json({ error: 'internal_error' }, 500)
      }

      const users = (data?.users ?? []) as AuthUser[]
      found = users.find((user) => (user.email ?? '').toLowerCase() === email) ?? null
      if (found || users.length < 200) {
        break
      }
    }

    if (!found) {
      return notRegistered()
    }

    const { data: subscription, error: subscriptionError } = await admin
      .from('subscriptions')
      .select('status, current_period_end')
      .eq('user_id', found.id)
      .maybeSingle()

    if (subscriptionError) {
      console.error('lookup-account: subscriptions read failed:', subscriptionError)
      return json({ error: 'internal_error' }, 500)
    }

    const status = typeof subscription?.status === 'string' ? subscription.status : ''
    const periodEnd = typeof subscription?.current_period_end === 'string'
      ? Date.parse(subscription.current_period_end)
      : Number.NaN

    if (
      (status !== 'active' && status !== 'demo')
      || !Number.isFinite(periodEnd)
      || periodEnd <= Date.now()
    ) {
      return notRegistered()
    }

    const canonicalEmail = (found.email ?? email).trim()
    return json({
      accountId: found.id,
      email: canonicalEmail,
      displayName: displayNameOf(found, canonicalEmail),
    }, 200)
  } catch (error) {
    console.error('lookup-account: unexpected error:', error)
    return json({ error: 'internal_error' }, 500)
  }
})
