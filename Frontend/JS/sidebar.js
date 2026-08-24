(function () {
    document.addEventListener('DOMContentLoaded', function () {
        const toggle = getElement('sidebarToggle');
        const sidebar = document.querySelector('.sidebar');
        let overlay = document.querySelector('.sidebar-overlay');

        if (sidebar && !overlay) {
            overlay = document.createElement('div');
            overlay.className = 'sidebar-overlay';
            overlay.setAttribute('aria-hidden', 'true');
            document.body.appendChild(overlay);
        }

        function isDrawerMode() { return window.innerWidth <= 1024; }

        function setOpen(open) {
            if (!isDrawerMode()) open = false;
            document.body.classList.toggle('sidebar-open', open);
            if (toggle) toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
            if (overlay) overlay.setAttribute('aria-hidden', open ? 'false' : 'true');
        }

        if (toggle) {
            toggle.setAttribute('aria-expanded', 'false');
            toggle.addEventListener('click', function () {
                setOpen(!document.body.classList.contains('sidebar-open'));
            });
        }

        document.querySelectorAll('.app-nav-link').forEach(function (link) {
            link.addEventListener('click', function () {
                if (isDrawerMode()) setOpen(false);
            });
        });

        if (overlay) overlay.addEventListener('click', function () { setOpen(false); });

        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && document.body.classList.contains('sidebar-open')) setOpen(false);
        });

        window.addEventListener('resize', function () {
            if (!isDrawerMode()) setOpen(false);
        });
    });
})();
