/* Shared API helper for the HelaFixIt AI Flask backend. */
(function () {
    // HelaFixIt AI pages must be opened through the Flask server so every screen reads live database data.
    if (window.location.protocol === 'file:') {
        const decodedPath = decodeURIComponent(window.location.pathname || '').replace(/\\/g, '/');
        const marker = '/Frontend/';
        const lowerPath = decodedPath.toLowerCase();
        const markerIndex = lowerPath.lastIndexOf(marker.toLowerCase());
        if (markerIndex !== -1) {
            const relativePath = decodedPath.slice(markerIndex + marker.length);
            const query = window.location.search || '';
            window.location.replace('http://127.0.0.1:5000/' + relativePath.split('/').map(encodeURIComponent).join('/') + query);
            return;
        }
    }

    function resolveBase() {
        const host = window.location.hostname;
        const localHost = host === '127.0.0.1' || host === 'localhost';
        if (localHost && window.location.port !== '5000') return 'http://127.0.0.1:5000/api';
        return window.location.origin + '/api';
    }

    const API_BASE = resolveBase();

    function isMaintenancePage() {
        return decodeURIComponent(window.location.pathname || '').toLowerCase().endsWith('/pages/public pages/maintenance.html');
    }

    function clearStore(store) {
        store.removeItem('helafixitAccessToken');
        store.removeItem('helafixitCurrentUser');
    }

    function sessionStoreForExistingToken() {
        if (localStorage.getItem('helafixitAccessToken')) return localStorage;
        if (sessionStorage.getItem('helafixitAccessToken')) return sessionStorage;
        return localStorage;
    }

    window.redirectToMaintenancePage = function () {
        if (isMaintenancePage()) return;
        window.location.replace('/Pages/Public%20pages/maintenance.html');
    };

    window.getAuthToken = function () {
        return localStorage.getItem('helafixitAccessToken') || sessionStorage.getItem('helafixitAccessToken') || '';
    };

    window.setAuthSession = function (token, user, rememberDevice) {
        let store;
        if (rememberDevice === true || rememberDevice === false) {
            clearStore(localStorage);
            clearStore(sessionStorage);
            store = rememberDevice ? localStorage : sessionStorage;
        } else {
            store = sessionStoreForExistingToken();
        }
        if (token) store.setItem('helafixitAccessToken', token);
        if (user) store.setItem('helafixitCurrentUser', JSON.stringify(user));
    };

    window.clearAuthSession = function () {
        clearStore(localStorage);
        clearStore(sessionStorage);
    };

    window.apiRequest = async function (path, options) {
        options = options || {};
        const headers = Object.assign({}, options.headers || {});
        const token = getAuthToken();
        if (token) headers.Authorization = 'Bearer ' + token;

        let body = options.body;
        if (body && !(body instanceof FormData) && typeof body !== 'string') {
            headers['Content-Type'] = 'application/json';
            body = JSON.stringify(body);
        }

        const response = await fetch(API_BASE + path, {
            method: options.method || 'GET',
            headers: headers,
            body: body,
        });

        let payload;
        try {
            payload = await response.json();
        } catch (error) {
            payload = { success: false, message: 'The server returned an unreadable response.' };
        }

        if (!response.ok || payload.success === false) {
            if (response.status === 401 && path !== '/auth/login') {
                clearAuthSession();
            }
            const maintenanceMode = response.status === 503 && !!(payload.details && payload.details.maintenanceMode);
            if (maintenanceMode) {
                const user = (typeof window.currentUser === 'function') ? window.currentUser() : null;
                if (!user || user.role !== 'systemAdmin') {
                    window.redirectToMaintenancePage();
                }
            }
            const err = new Error(payload.message || 'Request failed.');
            err.status = response.status;
            err.payload = payload;
            err.maintenanceMode = maintenanceMode;
            throw err;
        }
        return payload;
    };

    window.HELAFIX_API_BASE = API_BASE;
})();
