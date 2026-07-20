/**
 * Missionite — Supabase Configuration (site-owned)
 * ============================================================================
 *  >>> ACTION REQUIRED <<<  PASTE YOUR OWN PROJECT VALUES BELOW.
 * ============================================================================
 * Missionite runs on its OWN DEDICATED Supabase project — NOT the shared
 * auth_db backend. Create a fresh project (see supabase/SETUP.md), then replace
 * the two placeholder strings below with that project's values:
 *
 *   PROJECT_URL          -> Settings > API > "Project URL"
 *                           (looks like https://abcdefghijkl.supabase.co)
 *   PUBLISHABLE_API_KEY  -> Settings > API > "Project API keys" > anon / public
 *                           (the publishable "anon" key — safe to ship in the
 *                            browser; Row-Level Security is what protects data)
 *
 * Until BOTH placeholders are replaced, sign-in and downloads will fail with a
 * clear console error rather than talking to the wrong backend.
 *
 * This file deliberately MIRRORS the interface of the auth_db submodule's
 * database/config/supabaseConfig.js (PROJECT_URL, PUBLISHABLE_API_KEY,
 * getClient(), waitForLibrary(), initialize()) so that the submodule's
 * shared AuthService can consume `window.SupabaseConfig` unchanged. Because we
 * provide our OWN window.SupabaseConfig, the submodule's supabaseConfig.js is
 * simply never loaded — do NOT include it on any page.
 *
 * LOAD ORDER: the vendored supabase-js
 *   (lib/auth_db/shared/vendor/supabase/supabase.min.js) must load BEFORE this
 *   file, and this file must load BEFORE lib/auth_db/shared/services/authService.js.
 * ============================================================================
 */

const SupabaseConfig = {
    // ---- PLACEHOLDERS — REPLACE WITH YOUR DEDICATED MISSIONITE PROJECT ----
    PROJECT_URL: 'https://qqrenkzyucvfpanygdrb.supabase.co',
    PUBLISHABLE_API_KEY: 'sb_publishable_Ok92AbxGyQCMEcQ5UGkTRA_E9uUFpCZ',
    // ----------------------------------------------------------------------

    _clientInstance: null,

    /**
     * True once real (non-placeholder) values have been pasted in above.
     * The UI uses this to show a friendly "not configured yet" message instead
     * of firing doomed network requests at a placeholder host.
     * @returns {boolean}
     */
    isConfigured() {
        return (
            typeof this.PROJECT_URL === 'string' &&
            this.PROJECT_URL.startsWith('https://') &&
            this.PROJECT_URL !== 'MISSIONITE_SUPABASE_URL' &&
            typeof this.PUBLISHABLE_API_KEY === 'string' &&
            this.PUBLISHABLE_API_KEY.length > 0 &&
            this.PUBLISHABLE_API_KEY !== 'MISSIONITE_SUPABASE_PUBLISHABLE_KEY'
        );
    },

    /**
     * Get Supabase client instance (reuses existing instance if available).
     * @returns {Object} Supabase client
     */
    getClient() {
        console.log('[SupabaseConfig] getClient() called');

        if (this._clientInstance) {
            console.log('[SupabaseConfig] Reusing existing Supabase client instance');
            return this._clientInstance;
        }

        if (!this.isConfigured()) {
            throw new Error(
                'Supabase is not configured yet. Paste your Missionite project URL ' +
                'and publishable key into js/supabase-config.js (see the comment at ' +
                'the top of that file and supabase/SETUP.md).'
            );
        }

        if (!window.supabase) {
            console.error('[SupabaseConfig] Supabase client library not loaded');
            throw new Error('Supabase client library not loaded. Please include the vendored supabase-js script before this file.');
        }

        console.log('[SupabaseConfig] Creating new Supabase client with URL:', this.PROJECT_URL);
        this._clientInstance = window.supabase.createClient(this.PROJECT_URL, this.PUBLISHABLE_API_KEY);
        console.log('[SupabaseConfig] Supabase client created successfully');
        return this._clientInstance;
    },

    /**
     * Wait for the Supabase library (window.supabase) to load.
     * @param {number} maxWaitTime - Maximum time to wait in milliseconds
     * @returns {Promise<void>}
     */
    async waitForLibrary(maxWaitTime = 10000) {
        const startTime = Date.now();
        while (!window.supabase && (Date.now() - startTime) < maxWaitTime) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        if (!window.supabase) {
            throw new Error('Supabase library failed to load within timeout period');
        }
    },

    /**
     * Initialize the Supabase client.
     * @returns {Promise<Object>} Supabase client instance
     */
    async initialize() {
        console.log('[SupabaseConfig] initialize() called');
        if (typeof window === 'undefined') {
            throw new Error('Supabase config can only be used in a browser environment');
        }

        if (!this.isConfigured()) {
            throw new Error(
                'Supabase is not configured yet. Paste your Missionite project URL ' +
                'and publishable key into js/supabase-config.js (see supabase/SETUP.md).'
            );
        }

        if (!window.supabase) {
            console.log('[SupabaseConfig] Waiting for Supabase library to load...');
            await this.waitForLibrary();
            console.log('[SupabaseConfig] Supabase library loaded');
        }

        return this.getClient();
    }
};

if (typeof window !== 'undefined') {
    window.SupabaseConfig = SupabaseConfig;
}
