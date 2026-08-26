const SupabaseConfig = {
    PROJECT_URL: 'https://qqrenkzyucvfpanygdrb.supabase.co',
    PUBLISHABLE_API_KEY: 'sb_publishable_Ok92AbxGyQCMEcQ5UGkTRA_E9uUFpCZ',

    _clientInstance: null,

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

    getClient() {
        if (this._clientInstance) return this._clientInstance;

        if (!this.isConfigured()) {
            throw new Error(
                'Supabase is not configured. Set PROJECT_URL and PUBLISHABLE_API_KEY in ' +
                'src/js/supabase-config.js (see docs/SETUP.md).'
            );
        }

        if (!window.supabase) {
            throw new Error('Supabase client library not loaded. Include the vendored supabase-js script before this file.');
        }

        this._clientInstance = window.supabase.createClient(this.PROJECT_URL, this.PUBLISHABLE_API_KEY);
        return this._clientInstance;
    },

    async waitForLibrary(maxWaitTime = 10000) {
        const startTime = Date.now();
        while (!window.supabase && (Date.now() - startTime) < maxWaitTime) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        if (!window.supabase) {
            throw new Error('Supabase library failed to load within timeout period');
        }
    },

    async initialize() {
        if (typeof window === 'undefined') {
            throw new Error('Supabase config can only be used in a browser environment');
        }

        if (!this.isConfigured()) {
            throw new Error(
                'Supabase is not configured. Set PROJECT_URL and PUBLISHABLE_API_KEY in ' +
                'src/js/supabase-config.js (see docs/SETUP.md).'
            );
        }

        if (!window.supabase) {
            await this.waitForLibrary();
        }

        return this.getClient();
    }
};

if (typeof window !== 'undefined') {
    window.SupabaseConfig = SupabaseConfig;
}
