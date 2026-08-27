(function () {
    'use strict';

    var _initialHash = (typeof window !== 'undefined' && window.location && window.location.hash) || '';
    var IS_RECOVERY = /(?:[#&?])type=recovery(?:&|$)/.test(_initialHash);

    if (window.AuthService && typeof window.AuthService._redirectToSignIn === 'function') {
        window.AuthService._redirectToSignIn = function noRedirectOnMissionite() {};
    }

    var _initPromise = null;
    var _authCallbacks = [];
    var _wired = false;

    function cfg() { return window.SupabaseConfig; }
    function svc() { return window.AuthService; }

    function isConfigured() {
        return !!(cfg() && typeof cfg().isConfigured === 'function' && cfg().isConfigured());
    }

    function init() {
        if (_initPromise) return _initPromise;
        _initPromise = (async function () {
            if (!isConfigured()) {
                _wireAuthEvents();
                return { ok: false, configured: false, session: null, error: 'not-configured' };
            }
            try {
                await svc().initialize();
                _wireAuthEvents();
                var session = await getSession();
                return { ok: true, configured: true, session: session, error: null };
            } catch (e) {
                console.error('[SiteAuth] init failed:', e && e.message);
                _wireAuthEvents();
                return { ok: false, configured: true, session: null, error: (e && e.message) || 'init-failed' };
            }
        })();
        return _initPromise;
    }

    async function getSession() {
        var s = svc();
        if (!s || !s.client || !s.client.auth) return null;
        try {
            var res = await s.client.auth.getSession();
            var session = res && res.data ? res.data.session : null;
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

    async function freshAccessToken() {
        var session = await getSession();
        return session ? session.access_token : null;
    }

    async function signIn(email, password) {
        var s = svc();
        if (!s) return { success: false, error: 'Auth service unavailable', user: null };
        return await s.signIn(email, password);
    }

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
                try { s.stopPeriodicSessionValidation(); } catch (_) {}
            }
        }
        window.dispatchEvent(new CustomEvent('auth:signout'));
    }

    async function sendReset(email) {
        var s = svc();
        if (!s || !s.client || !s.client.auth) {
            return { success: false, error: 'Auth service not ready. Refresh and try again.' };
        }
        try {
            var redirectTo = window.location.origin + window.location.pathname;
            var res = await s.client.auth.resetPasswordForEmail(email.trim(), { redirectTo: redirectTo });
            if (res && res.error) return { success: false, error: res.error.message };
            return { success: true, error: null };
        } catch (e) {
            return { success: false, error: (e && e.message) || 'Could not send reset email' };
        }
    }

    async function setNewPassword(newPassword) {
        var s = svc();
        if (!s || typeof s.updatePassword !== 'function') {
            return { success: false, error: 'Auth service not ready. Refresh and try again.' };
        }
        return await s.updatePassword(newPassword);
    }

    function onAuth(cb) {
        if (typeof cb !== 'function') return;
        _authCallbacks.push(cb);
        _wireAuthEvents();
        cb({ signedIn: isAuthenticated(), email: currentEmail() });
    }

    function _notify() {
        var state = { signedIn: isAuthenticated(), email: currentEmail() };
        _authCallbacks.forEach(function (cb) {
            try { cb(state); } catch (e) { console.warn('[SiteAuth] onAuth cb error:', e && e.message); }
        });
    }

    function _wireAuthEvents() {
        if (_wired) return;
        _wired = true;
        window.addEventListener('auth:signin', _notify);
        window.addEventListener('auth:signout', _notify);
    }

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
        if (out.indexOf('.') !== -1) out = out.replace(/\.0$/, '');
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

    function functionsUrl(name) {
        var base = (cfg() && cfg().PROJECT_URL) ? cfg().PROJECT_URL.replace(/\/+$/, '') : '';
        return base + '/functions/v1/' + name;
    }

    function anonKey() {
        return (cfg() && cfg().PUBLISHABLE_API_KEY) || '';
    }

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
        freshAccessToken: freshAccessToken,
        signIn: signIn,
        signOut: signOut,
        sendReset: sendReset,
        setNewPassword: setNewPassword,
        onAuth: onAuth,
        isValidEmail: isValidEmail,
        formatBytes: formatBytes,
        formatDate: formatDate,
        escapeHtml: escapeHtml,
        functionsUrl: functionsUrl,
        anonKey: anonKey,
        client: client
    };
})();
