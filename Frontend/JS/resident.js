/* Resident portal backed by Flask and the helafixit_ai database. */
(function () {
    function riskText(ticket) {
        return ticket.risk === null || ticket.risk === undefined ? 'Pending' : ticket.risk + '/100';
    }

    function notificationHTML(items) {
        return (items || []).map(function (n) {
            const emergency = /emergency/i.test(n.type || '') || /emergency/i.test(n.title || '');
            return '<div class="notification-item ' + (!n.read ? 'unread' : '') + '">' +
                '<div class="notification-symbol">' + (emergency ? '!' : 'i') + '</div>' +
                '<div><h4>' + escapeHTML(n.title) + '</h4><p>' + escapeHTML(n.text) + '</p><time>' + formatDate(n.time) + '</time></div></div>';
        }).join('') || '<div class="empty-state"><h3>No notifications</h3><p>New maintenance updates will appear here.</p></div>';
    }

    function ticketCard(ticket) {
        return '<div class="ticket-card ' + (ticket.emergency ? 'emergency-card' : '') + '">' +
            '<div class="ticket-head"><div><span class="ticket-id">' + escapeHTML(ticket.id) + '</span><div class="ticket-title">' + escapeHTML(ticket.title) + '</div></div>' + makeBadge(ticket.priority) + '</div>' +
            '<div class="ticket-meta"><span>' + escapeHTML(ticket.category) + '</span><span>' + escapeHTML(ticket.block) + ' · ' + escapeHTML(ticket.floor) + '</span><span>' + formatDate(ticket.created) + '</span></div>' +
            '<div class="ticket-actions">' + makeBadge(ticket.status) + '<button class="btn-app btn-secondary btn-sm" onclick="navigateWithId(\'ticket-details.html\',\'' + escapeHTML(ticket.id) + '\')">View details</button></div></div>';
    }

    async function renderDashboard() {
        if (!getElement('residentDashboard')) return;
        try {
            const response = await apiRequest('/resident/dashboard');
            const data = response.data;
            setText('statMyTickets', data.stats.total);
            setText('statOpenTickets', data.stats.open);
            setText('statEmergencyTickets', data.stats.emergency);
            setText('statCompletedTickets', data.stats.completed);
            const list = getElement('recentResidentTickets');
            if (list) list.innerHTML = data.recent_tickets.map(ticketCard).join('') || '<div class="empty-state"><div class="empty-icon">0</div><h3>No tickets yet</h3><p>Submit your first maintenance request.</p></div>';
            const notices = getElement('residentDashboardNotifications');
            if (notices) notices.innerHTML = notificationHTML(data.notifications);
        } catch (error) {
            showMessage(error.message || 'Resident dashboard could not be loaded.', 'error');
        }
    }

    async function renderMyTickets() {
        const body = getElement('residentTicketRows');
        if (!body) return;
        let timer = null;
        async function draw() {
            try {
                const params = new URLSearchParams();
                const q = getElement('residentTicketSearch').value.trim();
                const status = getElement('residentStatusFilter').value;
                const priority = getElement('residentPriorityFilter').value;
                if (q) params.set('search', q);
                if (status) params.set('status', status);
                if (priority) params.set('priority', priority);
                const response = await apiRequest('/resident/tickets?' + params.toString());
                const rows = response.data.tickets;
                body.innerHTML = rows.map(function (t) {
                    return '<tr><td><span class="table-primary">' + escapeHTML(t.id) + '</span><span class="table-secondary">' + formatDate(t.created, false) + '</span></td>' +
                        '<td><span class="table-primary">' + escapeHTML(t.title) + '</span><span class="table-secondary">' + escapeHTML(t.category) + '</span></td>' +
                        '<td>' + makeBadge(t.priority) + '</td><td>' + riskText(t) + '</td><td>' + makeBadge(t.status) + '</td>' +
                        '<td>' + (t.technician ? escapeHTML(t.technician) : '<span class="table-secondary">Not assigned</span>') + '</td>' +
                        '<td><button class="btn-app btn-secondary btn-sm" onclick="navigateWithId(\'ticket-details.html\',\'' + escapeHTML(t.id) + '\')">View</button></td></tr>';
                }).join('') || '<tr><td colspan="7"><div class="empty-state"><h3>No matching tickets</h3><p>Try changing the filters.</p></div></td></tr>';
            } catch (error) {
                body.innerHTML = '<tr><td colspan="7"><div class="empty-state"><h3>Could not load tickets</h3><p>' + escapeHTML(error.message) + '</p></div></td></tr>';
            }
        }
        getElement('residentTicketSearch').addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(draw, 250); });
        getElement('residentStatusFilter').addEventListener('change', draw);
        getElement('residentPriorityFilter').addEventListener('change', draw);
        draw();
    }

    async function renderDetails() {
        if (!getElement('residentTicketDetails')) return;
        const id = getQuery('id');
        if (!id) return;
        try {
            const response = await apiRequest('/resident/tickets/' + encodeURIComponent(id));
            const t = response.data.ticket;
            setText('detailTicketId', t.id);
            setText('detailTitle', t.title);
            setText('detailDescription', t.description);
            setText('detailLocation', t.block + ' · ' + t.floor + ' · ' + t.area);
            setText('detailAsset', t.asset);
            setText('detailCategory', t.category);
            setText('detailRisk', t.risk === null ? 'Pending analysis' : t.risk + '/100 · ' + t.riskLevel);
            setText('detailTechnician', t.technician || 'Waiting for assignment');
            setText('detailCreated', formatDate(t.created));
            setText('detailSafety', t.safety);
            setText('detailRepairNote', t.repairNote || 'No repair notes have been added yet.');
            getElement('detailPriority').innerHTML = makeBadge(t.priority);
            getElement('detailStatus').innerHTML = makeBadge(t.status);
            setText('detailDuplicate', t.predictionAvailable ? (t.duplicate ? 'Possible duplicate of ' + (t.duplicateOf || '-') : 'No duplicate detected') : 'Duplicate analysis not available');
            const timeline = getElement('ticketTimeline');
            if (timeline) {
                timeline.innerHTML = (t.timeline || []).map(function (item) {
                    return '<div class="timeline-item done"><span class="timeline-dot"></span><h4>' + escapeHTML(item.to || item.type) + '</h4><p>' + escapeHTML(item.note || item.type) + '</p><small>' + escapeHTML(item.by) + ' · ' + formatDate(item.created) + '</small></div>';
                }).join('') || '<div class="timeline-item done"><span class="timeline-dot"></span><h4>Submitted</h4><p>Ticket is stored in the live database.</p></div>';
            }
        } catch (error) {
            showMessage(error.message || 'Ticket details could not be loaded.', 'error');
        }
    }

    async function renderNotifications() {
        const root = getElement('residentNotificationList');
        if (!root) return;
        try {
            const response = await apiRequest('/resident/notifications');
            root.innerHTML = notificationHTML(response.data.notifications);
        } catch (error) {
            root.innerHTML = '<div class="empty-state"><h3>Could not load notifications</h3><p>' + escapeHTML(error.message) + '</p></div>';
        }
        const button = getElement('markResidentRead');
        if (button) button.onclick = async function () {
            try {
                await apiRequest('/resident/notifications/read-all', {method:'POST'});
                showMessage('Notifications marked as read.', 'success');
                await renderNotifications();
                if (window.refreshNotificationButton) window.refreshNotificationButton();
            } catch (error) { showMessage(error.message, 'error'); }
        };
    }

    async function renderProfile() {
        if (!getElement('residentProfile')) return;
        try {
            const response = await apiRequest('/resident/profile');
            const p = response.data.profile;
            getElement('profileName').value = p.name || '';
            getElement('profileEmail').value = p.email || '';
            getElement('profilePhone').value = p.phone || '';
            getElement('profileBlock').value = p.block ? p.block + ' - ' + p.building : p.building || '';
            getElement('profileFloor').value = p.floor || '';
            getElement('profileApartment').value = p.unitNumber || '';
            if (getElement('profileLanguage')) getElement('profileLanguage').value = p.preferredLanguage || 'English';
            if (getElement('profileContactPreference')) getElement('profileContactPreference').value = p.contactPreference || 'In App';
            setText('profileDisplayName', p.name);
            setText('profileDisplayEmail', p.email);
            setText('profileInitial', (p.name || 'R')[0]);
            const form = getElement('residentProfileForm');
            form.addEventListener('submit', async function (event) {
                event.preventDefault();
                if (!validateRequired(event.currentTarget)) return;
                try {
                    const phone = normalizeSriLankanMobile(getElement('profilePhone').value);
                    await apiRequest('/resident/profile', {method:'PUT', body:{
                        name:getElement('profileName').value.trim(), phone:phone,
                        preferred_language:getElement('profileLanguage') ? getElement('profileLanguage').value : p.preferredLanguage,
                        contact_preference:getElement('profileContactPreference') ? getElement('profileContactPreference').value : p.contactPreference
                    }});
                    const me = await apiRequest('/auth/me'); setAuthSession(getAuthToken(), me.data.user);
                    showMessage('Resident profile updated.', 'success');
                    await renderProfile();
                } catch (error) { showMessage(error.message, 'error'); }
            }, {once:true});
        } catch (error) { showMessage(error.message || 'Resident profile could not be loaded.', 'error'); }
    }

    document.addEventListener('DOMContentLoaded', function () {
        if (!currentUser()) return;
        renderDashboard();
        renderMyTickets();
        renderDetails();
        renderNotifications();
        renderProfile();
    });
})();
