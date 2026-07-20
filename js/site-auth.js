/**
 * Missionite — site auth glue (thin, framework-free).
 * ============================================================================
 * Shared helpers used by account.html and download.html. Depends on the
 * auth_db submodule's window.AuthService (loaded before this file) and the
 * site-owned window.SupabaseConfig.
 *
 * REQUIRED SCRIPT ORDER on any auth-aware page:
 *   1. lib/auth_db/shared/vendor/supabase/supabase.min.js   (window.supabase)
 *   2. js/supabase-config.js                                (window.SupabaseConfig)
 *   3. lib/auth_db/shared/services/authService.js           (window.AuthService)
 *   4. js/site-auth.js                                       (this file)
 *
 * ----------------------------------------------------------------------------
 * WHY THIS FILE PATCHES AuthService AT RUNTIME (and does NOT edit the submodule)
 * ----------------------------------------------------------------------------
 * The shared AuthService is designed for the money_tracker / messaging_app
 * layout, where an unauthenticated visitor should be bounced to a login page at
 * `<base>/auth/views/auth.html`. It enforces that in THREE places:
 *   - the onAuthStateChange listener redirects on SIGNED_OUT and on an
 *     INITIAL_SESSION that carries no user (i.e. a signed-out visitor),
 *   - validateSession(autoRedirect=true) redirects on failure,
 *   - signOut() ends with an unconditional window.location.href to that path.
 * Missionite is a static marketing site with NO such page: an unauthenticated
 * visitor to account.html must simply SEE the sign-in form, and download.html
 * must render an in-page "Sign in to download" card — never a 404 redirect.
 *
 * We therefore replace AuthService._redirectToSignIn with a no-op at load time.
 * That single override neutralises BOTH redirecting code paths in the auth-state
 * listener and the one in validateSession(), leaving all of AuthService's actual
 * auth logic (client creation, signIn, session tracking, event dispatch) intact.
 * We also provide our OWN signOut() below rather than calling AuthService.signOut()
 * (whose final line is that hard redirect). The submodule files are never modified.
 * ============================================================================
 */
(function () {
    'use strict';

    // Capture the URL hash SYNCHRONOUSLY at load, before supabase-js can parse
    // and strip it. A Supabase password-recovery link lands here as
    //   account.html#access_token=...&type=recovery&...
    // and we must detect that even after detectSessionInUrl clears the hash.
    var _initialHash = (typeof window !== 'undefined' && window.location && window.location.hash) || '';
    var IS_RECOVERY = /(?:[#&?])type=recovery(?:&|$)/.test(_initialHash);

    // Neutralise the submodule's forced redirects (see header comment). Guarded
    // so this file is safe to load even if AuthService is somehow absent.
    if (window.AuthService && typeof window.AuthService._redirectToSignIn === 'function') {
        window.AuthService._redirectToSignIn = function noRedirectOnMissionite() {
            // Intentionally does nothing: Missionite handles signed-out UI in-page.
            console.log('[SiteAuth] _redirectToSignIn suppressed (static site handles this in-page)');
        };
    }

    var _initPromise = null;      // memoised init
    var _authCallbacks = [];      // onAuth subscribers
    var _wired = false;           // window event listeners attached once

    function cfg() { return window.SupabaseConfig; }
    function svc() { return window.AuthService; }

    function isConfigured() {
        return !!(cfg() && typeof cfg().isConfigured === 'function' && cfg().isConfigured());
    }

    /**
     * Bring AuthService up and settle the initial session, WITHOUT ever
     * redirecting. Safe to call from every auth-aware page.
     * @returns {Promise<{ok:boolean, configured:boolean, session:?Object, error:?string}>}
     */
    function init() {
        if (_initPromise) return _initPromise;
        _initPromise = (async function () {
            if (!isConfigured()) {
                // Not wired to a project yet — surface a friendly state, don't throw.
                _wireNavEvents();
                applyNav(null);
                return { ok: false, configured: false, session: null, error: 'not-configured' };
            }
            try {
                await svc().initialize();
                _wireNavEvents();
                var session = await getSession();
                applyNav(IS_RECOVERY ? null : session);
                return { ok: true, configured: true, session: session, error: null };
            } catch (e) {
                console.error('[SiteAuth] init failed:', e && e.message);
                _wireNavEvents();
                applyNav(null);
                return { ok: false, configured: true, session: null, error: (e && e.message) || 'init-failed' };
            }
        })();
        return _initPromise;
    }

    /**
     * Non-redirecting session check (the "guard" for gated pages). Reads the
     * live session straight from the Supabase client so it is never stale, and
     * mirrors it back onto AuthService's in-memory state.
     * @returns {Promise<?Object>} the session, or null if signed out
     */
    async function getSession() {
        var s = svc();
        if (!s || !s.client || !s.client.auth) return null;
        try {
            var res = await s.client.auth.getSession();
            var session = res && res.data ? res.data.session : null;
            // Keep AuthService's cached view consistent (used by getAccessToken()).
            s.session = session || null;
            s.currentUser = session ? session.user : null;
            return session || null;
        } catch (e) {
            console.warn('[SiteAuth] getSession error:', e && e.message);
            return null;
        }
    }

    function isAuthenticated() {
        var s = svc();
        return !!(s && s.isAuthenticated && s.isAuthenticated());
    }

    function currentEmail() {
        var s = svc();
        var u = s && s.getCurrentUser ? s.getCurrentUser() : null;
        return u ? u.email : null;
    }

    /** Access token from AuthService's cached session (may lag a refresh). */
    function getAccessToken() {
        var s = svc();
        return s && s.getAccessToken ? s.getAccessToken() : null;
    }

    /** Access token read fresh from the client — preferred for authorized calls. */
    async function freshAccessToken() {
        var session = await getSession();
        return session ? session.access_token : null;
    }

    /**
     * Sign in via the shared AuthService (dispatches auth:signin on success).
     * @returns {Promise<{success:boolean, error:?string, user:?Object}>}
     */
    async function signIn(email, password) {
        var s = svc();
        if (!s) return { success: false, error: 'Auth service unavailable', user: null };
        return await s.signIn(email, password);
    }

    /**
     * Sign out WITHOUT the submodule's hard redirect. Clears the server session
     * and local state, then lets the UI update in place.
     * @returns {Promise<void>}
     */
    async function signOut() {
        var s = svc();
        try {
            if (s && s.client && s.client.auth) {
                await s.client.auth.signOut();
            }
        } catch (e) {
            console.warn('[SiteAuth] signOut (server) error, continuing:', e && e.message);
        }
        if (s) {
            s.currentUser = null;
            s.session = null;
            if (typeof s.stopPeriodicSessionValidation === 'function') {
                try { s.stopPeriodicSessionValidation(); } catch (_) { /* ignore */ }
            }
        }
        // The auth-state listener will also emit auth:signout; dispatch here too
        // so the UI updates even if the listener is slow. Handlers are idempotent.
        window.dispatchEvent(new CustomEvent('auth:signout'));
    }

    /**
     * "Forgot password?" — send a Supabase recovery email. We call the client's
     * resetPasswordForEmail directly (NOT AuthService.resetPassword, which hard-
     * codes redirectTo=<base>/auth/views/auth.html) so the recovery link lands
     * back on this site's account.html, where setNewPassword() takes over.
     * @returns {Promise<{success:boolean, error:?string}>}
     */
    async function sendReset(email) {
        var s = svc();
        if (!s || !s.client || !s.client.auth) {
            return { success: false, error: 'Auth service not ready. Refresh and try again.' };
        }
        try {
            var redirectTo = window.location.origin + window.location.pathname; // this account.html
            var res = await s.client.auth.resetPasswordForEmail(email.trim(), { redirectTo: redirectTo });
            if (res && res.error) return { success: false, error: res.error.message };
            return { success: true, error: null };
        } catch (e) {
            return { success: false, error: (e && e.message) || 'Could not send reset email' };
        }
    }

    /**
     * Set a new password during the recovery landing. Delegates to
     * AuthService.updatePassword (updateUser under the hood; enforces the
     * shared >=12-char policy). Requires the recovery session that supabase-js
     * establishes from the URL hash.
     * @returns {Promise<{success:boolean, error:?string}>}
     */
    async function setNewPassword(newPassword) {
        var s = svc();
        if (!s || typeof s.updatePassword !== 'function') {
            return { success: false, error: 'Auth service not ready. Refresh and try again.' };
        }
        return await s.updatePassword(newPassword);
    }

    /**
     * Subscribe to auth changes. Fires immediately with the current state and
     * again on every auth:signin / auth:signout.
     * @param {(state:{signedIn:boolean, email:?string}) => void} cb
     */
    function onAuth(cb) {
        if (typeof cb !== 'function') return;
        _authCallbacks.push(cb);
        _wireNavEvents();
        cb({ signedIn: isAuthenticated(), email: currentEmail() });
    }

    function _notify() {
        var state = { signedIn: isAuthenticated(), email: currentEmail() };
        applyNav(IS_RECOVERY ? null : (state.signedIn ? { user: { email: state.email } } : null));
        _authCallbacks.forEach(function (cb) {
            try { cb(state); } catch (e) { console.warn('[SiteAuth] onAuth cb error:', e && e.message); }
        });
    }

    function _wireNavEvents() {
        if (_wired) return;
        _wired = true;
        window.addEventListener('auth:signin', _notify);
        window.addEventListener('auth:signout', _notify);
    }

    /**
     * Swap the shared nav between signed-out ("Sign in") and signed-in
     * ("Account" + "Sign out"). Operates on the verbatim shared nav markup:
     * it finds the Sign-in link (an anchor to account.html inside .nav-links)
     * and injects/removes a Sign-out button — no bespoke markup required.
     * @param {?Object} session
     */
    function applyNav(session) {
        var nav = document.querySelector('.nav-links');
        if (!nav) return;
        var signInLink = nav.querySelector('a[href$="account.html"]');
        var signOutBtn = nav.querySelector('[data-navrole="signout"]');
        var signedIn = !!(session && session.user);

        if (signedIn) {
            if (signInLink) {
                signInLink.textContent = 'Account';
                signInLink.setAttribute('aria-label', 'Account (signed in)');
            }
            if (!signOutBtn) {
                signOutBtn = document.createElement('button');
                signOutBtn.type = 'button';
                signOutBtn.className = 'btn btn-ghost';
                signOutBtn.setAttribute('data-navrole', 'signout');
                signOutBtn.textContent = 'Sign out';
                signOutBtn.addEventListener('click', function () { signOut(); });
                if (signInLink && signInLink.after) signInLink.after(signOutBtn);
                else nav.appendChild(signOutBtn);
            }
            signOutBtn.hidden = false;
        } else {
            if (signInLink) {
                signInLink.textContent = 'Sign in';
                signInLink.removeAttribute('aria-label');
            }
            if (signOutBtn) signOutBtn.remove();
        }
    }

    // ---- small formatting / validation helpers used by the pages ----

    function isValidEmail(email) {
        return typeof email === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
    }

    function formatBytes(bytes) {
        var n = Number(bytes);
        if (!isFinite(n) || n <= 0) return '—';
        var units = ['B', 'KB', 'MB', 'GB', 'TB'];
        var i = Math.floor(Math.log(n) / Math.log(1024));
        i = Math.max(0, Math.min(i, units.length - 1));
        var val = n / Math.pow(1024, i);
        var out = (i === 0) ? String(Math.round(val)) : val.toFixed(val >= 10 ? 0 : 1);
        if (out.indexOf('.') !== -1) out = out.replace(/\.0$/, ''); // 5.0 MB -> 5 MB
        return out + ' ' + units[i];
    }

    function formatDate(value) {
        if (!value) return '—';
        var d = new Date(value);
        if (isNaN(d.getTime())) return String(value);
        try {
            return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
        } catch (_) {
            return d.toISOString().slice(0, 10);
        }
    }

    function escapeHtml(value) {
        if (value === null || value === undefined) return '';
        return String(value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    /** Build the invoke URL for a Supabase Edge Function on this project. */
    function functionsUrl(name) {
        var base = (cfg() && cfg().PROJECT_URL) ? cfg().PROJECT_URL.replace(/\/+$/, '') : '';
        return base + '/functions/v1/' + name;
    }

    /** Publishable/anon key — sent as the apikey header on Edge Function calls. */
    function anonKey() {
        return (cfg() && cfg().PUBLISHABLE_API_KEY) || '';
    }

    /** The live Supabase client (or null). */
    function client() {
        var s = svc();
        return s ? s.client : null;
    }

    window.SiteAuth = {
        IS_RECOVERY: IS_RECOVERY,
        isConfigured: isConfigured,
        init: init,
        getSession: getSession,
        isAuthenticated: isAuthenticated,
        currentEmail: currentEmail,
        getAccessToken: getAccessToken,
        freshAccessToken: freshAccessToken,
        signIn: signIn,
        signOut: signOut,
        sendReset: sendReset,
        setNewPassword: setNewPassword,
        onAuth: onAuth,
        applyNav: applyNav,
        isValidEmail: isValidEmail,
        formatBytes: formatBytes,
        formatDate: formatDate,
        escapeHtml: escapeHtml,
        functionsUrl: functionsUrl,
        anonKey: anonKey,
        client: client
    };
})();
