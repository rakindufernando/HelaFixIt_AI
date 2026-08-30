/* Shared helper functions for all HelaFixIt AI frontend pages. */
(function () {
    window.getElement = function (id) { return document.getElementById(id); };
    window.getElements = function (selector, root) { return Array.from((root || document).querySelectorAll(selector)); };
    window.escapeHTML = function (value) {
        return String(value == null ? '' : value).replace(/[&<>'"]/g, function (char) {
            return { '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[char];
        });
    };
    window.slug = function (value) { return String(value || '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); };
    window.formatDate = function (value, withTime) {
        if (!value) return '-';
        const date = new Date(value);
        if (isNaN(date)) return value;
        return date.toLocaleDateString('en-LK', withTime === false ? {year:'numeric',month:'short',day:'numeric'} : {year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
    };
    window.currentUser = function () {
        try {
            const raw = localStorage.getItem('helafixitCurrentUser') || sessionStorage.getItem('helafixitCurrentUser');
            return raw ? JSON.parse(raw) : null;
        } catch (e) { return null; }
    };
    window.showMessage = function (message, type) {
        let container = document.querySelector('.toast-container');
        if (!container) { container = document.createElement('div'); container.className = 'toast-container'; document.body.appendChild(container); }
        const toast = document.createElement('div');
        toast.className = 'toast ' + (type || 'info');
        toast.textContent = message;
        container.appendChild(toast);
        setTimeout(function () { toast.style.opacity = '0'; toast.style.transform = 'translateX(15px)'; }, 2600);
        setTimeout(function () { toast.remove(); }, 3000);
    };
    window.openModal = function (id) {
        const modal = getElement(id);
        if (!modal) return;
        modal.classList.add('show');
        modal.setAttribute('aria-hidden', 'false');
        document.body.classList.add('modal-open');
        const scrollArea = modal.querySelector('.user-management-form-content') || modal.querySelector('.modal-body');
        if (scrollArea) scrollArea.scrollTop = 0;
    };
    window.closeModal = function (id) {
        const modal = getElement(id);
        if (!modal) return;
        modal.classList.remove('show');
        modal.setAttribute('aria-hidden', 'true');
        if (!document.querySelector('.modal-backdrop.show')) document.body.classList.remove('modal-open');
    };
    window.makeBadge = function (text) { return '<span class="badge badge-' + slug(text) + '">' + escapeHTML(text) + '</span>'; };
    window.getQuery = function (name) { return new URLSearchParams(location.search).get(name); };
    window.navigateWithId = function (url, id) { location.href = url + '?id=' + encodeURIComponent(id); };
    window.setText = function (id, text) { const el = getElement(id); if (el) el.textContent = text; };

    function initModals() {
        document.querySelectorAll('[data-close-modal]').forEach(function(btn){ btn.addEventListener('click', function(){ closeModal(btn.dataset.closeModal); }); });
        document.querySelectorAll('.modal-backdrop').forEach(function(backdrop){ backdrop.addEventListener('click', function(e){ if(e.target === backdrop) closeModal(backdrop.id); }); });
    }


    async function applyPublicSystemSettings() {
        if (typeof window.apiRequest !== 'function') return;
        try {
            const response = await apiRequest('/auth/public-settings');
            const data = response.data || {};
            const systemName = data.systemName || 'HelaFixIt AI';
            const apartmentName = data.apartmentName || 'Apartment Maintenance';
            document.querySelectorAll('.sidebar-brand strong').forEach(function(el){ el.textContent = systemName; });
            document.querySelectorAll('.sidebar-brand span').forEach(function(el){ el.textContent = apartmentName; });
            document.querySelectorAll('[data-system-name]').forEach(function(el){ el.textContent = systemName; });
            document.querySelectorAll('[data-apartment-name]').forEach(function(el){ el.textContent = apartmentName; });
            if (document.title && document.title.includes('HelaFixIt AI')) document.title = document.title.replace(/HelaFixIt AI/g, systemName);

            const pagePath = decodeURIComponent(window.location.pathname || '').toLowerCase();
            const exempt = document.body && document.body.dataset.maintenanceExempt === 'true';
            const user = currentUser();
            if (data.maintenanceMode && !exempt && (!user || user.role !== 'systemAdmin')) {
                window.location.replace('/Pages/Public%20pages/maintenance.html');
                return;
            }
        } catch (error) { /* Static branding remains available when settings cannot be loaded. */ }
    }

    function notificationPageForRole(role) {
        return {
            resident: 'resident-notifications.html',
            admin: 'admin-notifications.html',
            technician: 'technician-notifications.html',
            systemAdmin: 'system-admin-notifications.html'
        }[role] || '';
    }

    function ensureNotificationButton() {
        const body = document.body;
        if (!body || !body.dataset.allowedRole) return null;
        const actions = document.querySelector('.topbar-actions');
        if (!actions) return null;
        let button = actions.querySelector('[data-notification-button], .icon-button[title="Notifications"]');
        if (!button) {
            button = document.createElement('button');
            button.className = 'icon-button';
            button.type = 'button';
            button.title = 'Notifications';
            button.innerHTML = 'N<span class="notification-dot is-hidden" aria-hidden="true"></span>';
            button.setAttribute('data-notification-button', 'true');
            const userChip = actions.querySelector('.user-chip');
            actions.insertBefore(button, userChip || actions.firstChild);
        } else {
            button.type = 'button';
            button.setAttribute('data-notification-button', 'true');
            button.setAttribute('aria-label', 'Open notifications');
            let dot = button.querySelector('.notification-dot');
            if (!dot) {
                dot = document.createElement('span');
                dot.className = 'notification-dot is-hidden';
                dot.setAttribute('aria-hidden', 'true');
                button.appendChild(dot);
            } else {
                dot.classList.add('is-hidden');
            }
        }
        return button;
    }

    async function refreshNotificationButton() {
        const button = ensureNotificationButton();
        const user = currentUser();
        if (!button || !user || typeof window.apiRequest !== 'function') return;
        const page = notificationPageForRole(user.role);
        if (!page) return;
        if (!button.dataset.notificationBound) {
            button.dataset.notificationBound = '1';
            button.addEventListener('click', function () { window.location.href = page; });
        }
        try {
            const response = await apiRequest('/auth/notification-summary');
            const count = Number((response.data || {}).unread || 0);
            const dot = button.querySelector('.notification-dot');
            if (dot) dot.classList.toggle('is-hidden', count <= 0);
            button.title = count > 0 ? ('Notifications (' + count + ' unread)') : 'Notifications';
            button.setAttribute('aria-label', button.title);
        } catch (error) {
            const dot = button.querySelector('.notification-dot');
            if (dot) dot.classList.add('is-hidden');
        }
    }
    window.refreshNotificationButton = refreshNotificationButton;

    document.addEventListener('keydown', function (event) { if (event.key === 'Escape') { const open = document.querySelector('.modal-backdrop.show'); if (open && open.id) closeModal(open.id); } });

    document.addEventListener('DOMContentLoaded', function () {
        initModals();
        applyPublicSystemSettings();
        ensureNotificationButton();
        window.setTimeout(refreshNotificationButton, 0);
        if (document.body && document.body.dataset.allowedRole) {
            window.setInterval(refreshNotificationButton, 30000);
            window.addEventListener('focus', refreshNotificationButton);
            const user = currentUser();
            if (!user || user.role !== 'systemAdmin') {
                window.setInterval(applyPublicSystemSettings, 30000);
            }
        }
    });
})();
