/* HelaFixIt AI landing page navigation and lightweight UI behaviour. */
(function () {
    'use strict';

    function initHome() {
        if (!document.body.classList.contains('landing-page')) return;

        const header = document.getElementById('siteHeader');
        const menu = document.getElementById('navMenu');
        const toggle = document.getElementById('menuToggle');
        const backToTop = document.getElementById('backToTop');
        const links = Array.from(document.querySelectorAll('.nav-link[href^="#"]'));
        const sections = links.map(function (link) {
            const selector = link.getAttribute('href');
            return selector ? document.querySelector(selector) : null;
        }).filter(Boolean);
        const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

        let frameRequested = false;

        function headerHeight() {
            return header ? Math.ceil(header.getBoundingClientRect().height + 18) : 96;
        }

        function setActive(id) {
            links.forEach(function (link) {
                const active = link.getAttribute('href') === '#' + id;
                link.classList.toggle('active', active);
                if (active) link.setAttribute('aria-current', 'page');
                else link.removeAttribute('aria-current');
            });
        }

        function activeSectionId() {
            if (!sections.length) return '';
            if (window.scrollY <= 20) return sections[0].id;

            const marker = headerHeight() + Math.min(120, window.innerHeight * 0.18);
            let current = sections[0];

            sections.forEach(function (section) {
                if (section.getBoundingClientRect().top <= marker) current = section;
            });

            const pageBottom = document.documentElement.scrollHeight - window.innerHeight;
            if (window.scrollY >= pageBottom - 4) current = sections[sections.length - 1];
            return current.id;
        }

        function setMenuState(open) {
            document.body.classList.toggle('menu-open', open);
            if (menu) menu.classList.toggle('open', open);
            if (toggle) {
                toggle.classList.toggle('open', open);
                toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
                toggle.setAttribute('aria-label', open ? 'Close navigation menu' : 'Open navigation menu');
            }
        }

        function closeMenu() {
            setMenuState(false);
        }

        function update() {
            frameRequested = false;
            if (header) header.classList.toggle('is-scrolled', window.scrollY > 16);
            setActive(activeSectionId());
            if (backToTop) backToTop.classList.toggle('show', window.scrollY > 650);
        }

        function scheduleUpdate() {
            if (frameRequested) return;
            frameRequested = true;
            window.requestAnimationFrame(update);
        }

        function scrollToSection(section) {
            if (!section) return;
            const top = Math.max(0, window.scrollY + section.getBoundingClientRect().top - headerHeight());
            closeMenu();
            setActive(section.id);
            window.scrollTo({ top: top, behavior: reduceMotion ? 'auto' : 'smooth' });
        }

        document.querySelectorAll('a[href^="#"]').forEach(function (anchor) {
            anchor.addEventListener('click', function (event) {
                const selector = anchor.getAttribute('href');
                if (!selector || selector === '#') return;
                const target = document.querySelector(selector);
                if (!target) return;
                event.preventDefault();
                scrollToSection(target);
                if (history.replaceState) history.replaceState(null, '', '#' + target.id);
            });
        });

        if (toggle && menu) {
            toggle.setAttribute('aria-expanded', 'false');
            toggle.addEventListener('click', function () {
                setMenuState(!menu.classList.contains('open'));
            });
        }

        if (backToTop && sections.length) {
            backToTop.addEventListener('click', function () {
                scrollToSection(sections[0]);
                if (history.replaceState) history.replaceState(null, '', '#' + sections[0].id);
            });
        }

        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') closeMenu();
        });

        document.addEventListener('click', function (event) {
            if (!menu || !toggle || !menu.classList.contains('open')) return;
            if (menu.contains(event.target) || toggle.contains(event.target)) return;
            closeMenu();
        });

        window.addEventListener('resize', function () {
            if (window.innerWidth > 900) closeMenu();
            scheduleUpdate();
        });

        const revealElements = Array.from(document.querySelectorAll('.reveal'));
        [
            '.home-feature-grid .reveal',
            '.user-role-grid .reveal',
            '.workflow-steps .reveal'
        ].forEach(function (selector) {
            document.querySelectorAll(selector).forEach(function (element, index) {
                element.style.setProperty('--reveal-delay', Math.min(index * 55, 165) + 'ms');
            });
        });

        if (reduceMotion || !('IntersectionObserver' in window)) {
            revealElements.forEach(function (element) { element.classList.add('show'); });
        } else {
            const observer = new IntersectionObserver(function (entries) {
                entries.forEach(function (entry) {
                    if (!entry.isIntersecting) return;
                    entry.target.classList.add('show');
                    observer.unobserve(entry.target);
                });
            }, { threshold: 0.08, rootMargin: '0px 0px -24px 0px' });
            revealElements.forEach(function (element) { observer.observe(element); });
        }

        window.addEventListener('scroll', scheduleUpdate, { passive: true });
        window.addEventListener('load', scheduleUpdate);

        const hashTarget = window.location.hash ? document.querySelector(window.location.hash) : null;
        if (hashTarget && sections.includes(hashTarget)) {
            window.requestAnimationFrame(function () { scrollToSection(hashTarget); });
        }

        window.requestAnimationFrame(update);
    }

    document.addEventListener('DOMContentLoaded', initHome);
})();
