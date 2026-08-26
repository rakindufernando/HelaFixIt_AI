/* Apartment Admin portal backed by Flask and the live database. */
(function () {
    function riskText(t) { return t.risk === null || t.risk === undefined ? 'Pending' : t.risk + '/100'; }
    function ticketRows(rows, actions) {
        return (rows || []).map(function (t) {
            return '<tr><td><span class="table-primary">' + escapeHTML(t.id) + '</span><span class="table-secondary">' + formatDate(t.created, false) + '</span></td>' +
                '<td><span class="table-primary">' + escapeHTML(t.title) + '</span><span class="table-secondary">' + escapeHTML(t.block) + ' · ' + escapeHTML(t.area) + '</span></td>' +
                '<td>' + makeBadge(t.category) + '</td><td>' + makeBadge(t.priority) + '</td><td><strong>' + riskText(t) + '</strong></td>' +
                '<td>' + makeBadge(t.status) + '</td><td>' + (t.technician ? escapeHTML(t.technician) : '<span class="table-secondary">Unassigned</span>') + '</td>' +
                '<td><div class="table-actions">' + actions(t) + '</div></td></tr>';
        }).join('');
    }
    function reviewButton(t) { return '<button class="btn-app btn-secondary btn-sm" onclick="navigateWithId(\'ai-review.html\',\'' + escapeHTML(t.id) + '\')">Review</button>'; }

    async function renderDashboard() {
        if (!getElement('adminDashboard')) return;
        try {
            const response = await apiRequest('/admin/dashboard');
            const d = response.data;
            setText('adminTotalActive', d.stats.active);
            setText('adminPendingReview', d.stats.pending_review);
            setText('adminEmergency', d.stats.emergency);
            setText('adminTechniciansAvailable', d.stats.available_technicians);
            getElement('adminRecentRows').innerHTML = ticketRows(d.recent_tickets, function (t) { return reviewButton(t); });
            getElement('adminEmergencyList').innerHTML = d.emergencies.map(function (t) {
                return '<div class="ticket-card emergency-card"><div class="ticket-head"><div><span class="ticket-id">' + escapeHTML(t.id) + '</span><div class="ticket-title">' + escapeHTML(t.title) + '</div></div>' + makeBadge(t.priority) + '</div>' +
                    '<div class="ticket-meta"><span>Risk ' + riskText(t) + '</span><span>' + escapeHTML(t.block) + '</span><span>' + escapeHTML(t.technician || 'Unassigned') + '</span></div></div>';
            }).join('') || '<div class="empty-state"><h3>No emergency tickets</h3><p>There are no active emergency tickets at the moment.</p></div>';
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderQueue() {
        const body = getElement('adminQueueRows');
        if (!body) return;
        let timer = null;
        try {
            const categoryResponse = await apiRequest('/admin/categories');
            const categorySelect = getElement('adminQueueCategory');
            const selected = categorySelect.value;
            categorySelect.innerHTML = '<option value="">All categories</option>' + (categoryResponse.data.categories || []).map(function(c){ return '<option value="'+escapeHTML(c.name)+'">'+escapeHTML(c.name)+'</option>'; }).join('');
            if (selected) categorySelect.value = selected;
        } catch (error) { /* Ticket queue can still load without category options. */ }
        async function draw() {
            try {
                const params = new URLSearchParams();
                const values = {
                    search:getElement('adminQueueSearch').value.trim(),
                    status:getElement('adminQueueStatus').value,
                    priority:getElement('adminQueuePriority').value,
                    category:getElement('adminQueueCategory').value,
                };
                Object.keys(values).forEach(function (key) { if (values[key]) params.set(key, values[key]); });
                const response = await apiRequest('/admin/tickets?' + params.toString());
                body.innerHTML = ticketRows(response.data.tickets, function (t) {
                    return reviewButton(t) + '<button class="btn-app btn-sm" onclick="navigateWithId(\'assign-technician.html\',\'' + escapeHTML(t.id) + '\')">Assign</button>';
                }) || '<tr><td colspan="8"><div class="empty-state"><h3>No matching tickets</h3><p>Try changing the filters.</p></div></td></tr>';
            } catch (error) { body.innerHTML = '<tr><td colspan="8">' + escapeHTML(error.message) + '</td></tr>'; }
        }
        getElement('adminQueueSearch').addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(draw, 250); });
        ['adminQueueStatus','adminQueuePriority','adminQueueCategory'].forEach(function (id) { getElement(id).addEventListener('change', draw); });
        draw();
    }

    async function renderAIReview() {
        if (!getElement('adminAIReview')) return;
        let id = getQuery('id');
        try {
            if (!id) {
                const queue = await apiRequest('/admin/tickets?status=Awaiting%20Review');
                id = queue.data.tickets[0] ? queue.data.tickets[0].id : '';
            }
            if (!id) { showMessage('No ticket is available for review.', 'info'); return; }
            const response = await apiRequest('/admin/tickets/' + encodeURIComponent(id));
            const t = response.data.ticket;
            setText('reviewTicketId', t.id); setText('reviewTicketTitle', t.title); setText('reviewDescription', t.description);
            setText('reviewResident', t.resident); setText('reviewLocation', t.block + ' · ' + t.floor + ' · ' + t.area);
            setText('reviewCategory', t.category); setText('reviewPriority', t.priority); setText('reviewRisk', t.risk === null ? 'Pending' : t.risk + '/100');
            setText('reviewConfidence', t.confidence === null ? 'Pending' : t.confidence + '%'); setText('reviewTechnicianType', t.technicianType);
            setText('reviewLanguage', t.language); setText('reviewSafety', t.safety);
            setText('reviewDuplicate', t.predictionAvailable ? (t.duplicate ? 'Possible duplicate of ' + (t.duplicateOf || '-') : 'No active duplicate detected') : 'AI duplicate check not connected yet');
            setText('reviewAssignment', t.technician ? t.technician + ' · ' + (t.assignmentMethod || '') : 'Not assigned');
            getElement('reviewRiskBar').style.width = (t.risk || 0) + '%';
            getElement('reviewConfidenceBar').style.width = (t.confidence || 0) + '%';
            getElement('reviewPriorityBadge').innerHTML = makeBadge(t.priority);
            getElement('reviewStatusBadge').innerHTML = makeBadge(t.status);

            const categorySelect = getElement('reviewCategoryEdit');
            categorySelect.innerHTML = '<option value="">Keep current category</option>' + response.data.categories.map(function (c) { return '<option>' + escapeHTML(c.name) + '</option>'; }).join('');
            const assignmentLink = document.querySelector('#adminAIReview .grid-2 a.btn-app');
            if (assignmentLink) assignmentLink.href = 'assign-technician.html?id=' + encodeURIComponent(t.id);
            const rerunButton = getElement('rerunAIAnalysis');
            if (rerunButton) rerunButton.addEventListener('click', async function () {
                rerunButton.disabled = true;
                try {
                    await apiRequest('/ai/tickets/' + encodeURIComponent(t.id) + '/analyse', {method:'POST'});
                    showMessage('Ticket analysis updated using the current local AI model and safety rules.', 'success');
                    setTimeout(function () { location.reload(); }, 350);
                } catch (error) { showMessage(error.message || 'AI analysis could not be updated.', 'error'); }
                finally { rerunButton.disabled = false; }
            });
            getElement('saveAIReview').addEventListener('click', async function () {
                try {
                    const result = await apiRequest('/admin/tickets/' + encodeURIComponent(t.id) + '/review', {
                        method:'POST',
                        body:{category:categorySelect.value || null, priority:getElement('reviewPriorityEdit').value || null, note:getElement('reviewNote') ? getElement('reviewNote').value.trim() : ''}
                    });
                    showMessage('Admin review saved to the database.', 'success');
                    setTimeout(function () { location.href = 'ai-review.html?id=' + encodeURIComponent(result.data.ticket.id); }, 300);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message || 'Ticket review could not be loaded.', 'error'); }
    }

    async function renderAssignment() {
        if (!getElement('assignTechnicianPage')) return;
        let id = getQuery('id');
        try {
            if (!id) {
                const queue = await apiRequest('/admin/tickets');
                const candidate = (queue.data.tickets || []).find(function(t){ return !['Resolved','Closed','Cancelled'].includes(t.status) && !t.technician; });
                id = candidate ? candidate.id : '';
            }
            if (!id) {
                getElement('technicianOptions').innerHTML = '<div class="empty-state"><h3>No ticket needs assignment</h3><p>Open the ticket queue to review current maintenance work.</p></div>';
                getElement('confirmAssignment').disabled = true;
                showMessage('There is no unassigned active ticket at the moment.', 'info');
                return;
            }
            const response = await apiRequest('/admin/tickets/' + encodeURIComponent(id) + '/technicians');
            const t = response.data.ticket;
            setText('assignTicketId', t.id); setText('assignTicketTitle', t.title); setText('assignRequiredSkill', t.technicianType);
            setText('assignRisk', t.risk === null ? 'Pending analysis' : t.risk + '/100 · ' + t.riskLevel);
            const candidates = response.data.candidates;
            getElement('technicianOptions').innerHTML = candidates.map(function (x) {
                const disabled = ['Off Duty','On Leave'].includes(x.status) || x.workload >= x.maxJobs;
                return '<label class="ticket-card" style="display:block;' + (disabled ? 'opacity:.55' : '') + '"><div class="ticket-head"><div><input type="radio" name="technicianPick" value="' + x.id + '" ' + (disabled ? 'disabled' : '') + '> <strong>' + escapeHTML(x.name) + '</strong>' +
                    '<div class="ticket-meta"><span>' + escapeHTML(x.skills) + '</span><span>' + escapeHTML(x.block) + '</span><span>Workload ' + x.workload + '/' + x.maxJobs + '</span><span>Rating ' + (x.rating || '-') + '</span>' + (x.skillMatch ? '<span>Skill match</span>' : '') + '</div></div>' + makeBadge(x.status) + '</div></label>';
            }).join('') || '<div class="empty-state"><h3>No technicians found</h3><p>Add an active technician before assigning this ticket.</p></div>';
            getElement('confirmAssignment').addEventListener('click', async function () {
                const pick = document.querySelector('input[name="technicianPick"]:checked');
                if (!pick) { showMessage('Select an available technician first.', 'error'); return; }
                try {
                    await apiRequest('/admin/tickets/' + encodeURIComponent(id) + '/assign', {method:'POST', body:{technician_id:Number(pick.value)}});
                    showMessage('Technician assigned in the live database.', 'success');
                    setTimeout(function () { location.href = 'ticket-queue.html'; }, 350);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message || 'Assignment options could not be loaded.', 'error'); }
    }

    async function renderEmergency() {
        const body = getElement('emergencyRows'); if (!body) return;
        try {
            const response = await apiRequest('/admin/emergencies');
            body.innerHTML = ticketRows(response.data.tickets, function (t) {
                return reviewButton(t) + '<button class="btn-app ' + (t.technician ? 'btn-secondary' : 'btn-danger') + ' btn-sm" onclick="navigateWithId(\'assign-technician.html\',\'' + escapeHTML(t.id) + '\')">' + (t.technician ? 'Reassign' : 'Assign now') + '</button>';
            }) || '<tr><td colspan="8"><div class="empty-state"><h3>No emergency tickets</h3><p>No emergency records are currently active.</p></div></td></tr>';
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderDuplicates() {
        const root = getElement('duplicateGroups'); if (!root) return;
        try {
            const response = await apiRequest('/admin/duplicates');
            root.innerHTML = response.data.duplicates.map(function (d) {
                const actions = d.status === 'Pending' ? '<div class="form-actions duplicate-actions"><button class="btn-app btn-success btn-sm" data-duplicate-action="confirm" data-duplicate-id="'+d.id+'">Confirm duplicate</button><button class="btn-app btn-secondary btn-sm" data-duplicate-action="reject" data-duplicate-id="'+d.id+'">Not a duplicate</button></div>' : '';
                return '<div class="card"><div class="card-header"><div><h3>' + escapeHTML(d.source.id) + ' possible duplicate</h3><p>Similarity ' + d.similarity + '%</p></div>' + makeBadge(d.status) + '</div><div class="card-body"><div class="grid-2">' +
                    '<div class="ticket-card"><span class="ticket-id">New report ' + escapeHTML(d.source.id) + '</span><div class="ticket-title">' + escapeHTML(d.source.title) + '</div><div class="ticket-meta"><span>' + escapeHTML(d.source.block) + ' · ' + escapeHTML(d.source.floor) + '</span><span>' + escapeHTML(d.source.status) + '</span></div></div>' +
                    '<div class="ticket-card"><span class="ticket-id">Existing ' + escapeHTML(d.matched.id) + '</span><div class="ticket-title">' + escapeHTML(d.matched.title) + '</div><div class="ticket-meta"><span>' + escapeHTML(d.matched.block) + ' · ' + escapeHTML(d.matched.floor) + '</span><span>' + escapeHTML(d.matched.status) + '</span></div></div></div>' + actions + '</div></div>';
            }).join('') || '<div class="card"><div class="empty-state"><h3>No duplicates</h3><p>No stored duplicate matches were found.</p></div></div>';
            root.querySelectorAll('[data-duplicate-action]').forEach(function(button){
                button.addEventListener('click', async function(){
                    const action=button.dataset.duplicateAction;
                    const note=prompt(action==='confirm' ? 'Optional confirmation note' : 'Optional rejection note') || '';
                    try {
                        await apiRequest('/admin/duplicates/'+button.dataset.duplicateId+'/review',{method:'POST',body:{action:action,note:note}});
                        showMessage(action==='confirm' ? 'Duplicate confirmed.' : 'Duplicate rejected.','success');
                        await renderDuplicates();
                    } catch(error){ showMessage(error.message,'error'); }
                });
            });
        } catch (error) { root.innerHTML = '<div class="card"><div class="empty-state"><h3>Could not load duplicates</h3><p>' + escapeHTML(error.message) + '</p></div></div>'; }
    }

    async function renderTechnicianManagement() {
        const body = getElement('adminTechnicianRows'); if (!body) return;
        async function draw() {
            try {
                const response = await apiRequest('/admin/technicians');
                body.innerHTML = response.data.technicians.map(function (t) {
                    return '<tr><td><span class="table-primary">' + escapeHTML(t.name) + '</span><span class="table-secondary">' + escapeHTML(t.employeeCode) + '</span></td><td>' + escapeHTML(t.skill) + '</td><td>' + escapeHTML(t.block) + '</td><td>' + makeBadge(t.status) + '</td><td>' + t.workload + '/' + t.maxJobs + '</td><td>' + (t.emergency ? 'Yes' : 'No') + '</td><td>' + (t.rating || '-') + '</td><td><select class="filter-select" data-tech-id="' + t.id + '"><option' + (t.status==='Available'?' selected':'') + '>Available</option><option' + (t.status==='Busy'?' selected':'') + '>Busy</option><option' + (t.status==='Off Duty'?' selected':'') + '>Off Duty</option><option' + (t.status==='On Leave'?' selected':'') + '>On Leave</option></select></td></tr>';
                }).join('') || '<tr><td colspan="8"><div class="empty-state"><h3>No technicians configured</h3><p>System Admin must add an active technician for this building.</p></div></td></tr>';
                body.querySelectorAll('select[data-tech-id]').forEach(function (select) {
                    select.addEventListener('change', async function () {
                        try {
                            await apiRequest('/admin/technicians/' + select.dataset.techId + '/availability', {method:'PATCH', body:{availability:select.value}});
                            showMessage('Technician availability updated.', 'success');
                            draw();
                        } catch (error) { showMessage(error.message, 'error'); }
                    });
                });
            } catch (error) { showMessage(error.message, 'error'); }
        }
        draw();
    }

    async function renderNotifications() {
        const root = getElement('adminNotificationList'); if (!root) return;
        try {
            const response = await apiRequest('/admin/notifications');
            root.innerHTML = response.data.notifications.map(function (n) {
                const emergency = /emergency/i.test(n.type || '') || /emergency/i.test(n.title || '');
                return '<div class="notification-item ' + (!n.read ? 'unread' : '') + '"><div class="notification-symbol">' + (emergency ? '!' : 'i') + '</div><div><h4>' + escapeHTML(n.title) + '</h4><p>' + escapeHTML(n.text) + '</p><time>' + formatDate(n.time) + '</time></div></div>';
            }).join('') || '<div class="empty-state"><h3>No notifications</h3><p>Operational alerts will appear here.</p></div>';
        } catch (error) { showMessage(error.message, 'error'); }
        const mark=getElement('markAdminRead');if(mark&&!mark.dataset.bound){mark.dataset.bound='1';mark.addEventListener('click',async function(){try{await apiRequest('/admin/notifications/read-all',{method:'POST'});showMessage('Notifications marked as read.','success');await renderNotifications();if(window.refreshNotificationButton)window.refreshNotificationButton();}catch(e){showMessage(e.message,'error');}});}
    }

    async function renderProfile() {
        if (!getElement('adminProfile')) return;
        try {
            const response = await apiRequest('/admin/profile');
            const p = response.data.profile;
            setText('adminProfileName', p.name); setText('adminProfileEmail', p.email); setText('adminProfileInitial', (p.name || 'A')[0]);
            getElement('adminName').value = p.name || ''; getElement('adminEmail').value = p.email || ''; getElement('adminPhone').value = p.phone || '';
            const building=getElement('adminBuilding'); if(building)building.value=(p.block ? p.block+' - ' : '')+(p.building||'');
            const emergency=getElement('adminEmergencyAccess'); if(emergency)emergency.value=p.canReviewEmergencies?'Enabled':'Not enabled';
            const job = getElement('adminJobTitle'); if (job) job.value = p.jobTitle || '';
            getElement('adminProfileForm').addEventListener('submit', async function (event) {
                event.preventDefault();
                if (!validateRequired(event.currentTarget)) return;
                try {
                    await apiRequest('/admin/profile', {method:'PUT', body:{name:getElement('adminName').value.trim(), phone:normalizeSriLankanMobile(getElement('adminPhone').value), job_title:job ? job.value.trim() : ''}});
                    const me = await apiRequest('/auth/me'); setAuthSession(getAuthToken(), me.data.user);
                    showMessage('Admin profile updated.', 'success'); setTimeout(function () { location.reload(); }, 250);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message || 'Profile could not be loaded.', 'error'); }
    }

    async function renderRegistrations() {
        const body = getElement('registrationRequestRows'); if (!body) return;
        async function draw() {
            try {
                const status = getElement('registrationStatusFilter').value;
                const response = await apiRequest('/admin/registration-requests?status=' + encodeURIComponent(status));
                const rows = response.data.requests || [];
                body.innerHTML = rows.map(function (x) {
                    const action = x.status === 'Pending'
                        ? '<button class="btn-app btn-success btn-sm" data-approve="'+x.id+'">Approve</button> <button class="btn-app btn-danger btn-sm" data-reject="'+x.id+'">Reject</button>'
                        : 'Reviewed';
                    return '<tr><td><span class="table-primary">'+escapeHTML(x.fullName)+'</span><span class="table-secondary">'+escapeHTML(x.email)+'</span></td><td>'+escapeHTML(x.phone)+'</td><td>'+escapeHTML(x.block+' · '+x.floor+(x.unitNumber?' · '+x.unitNumber:''))+'</td><td>'+escapeHTML(x.residentType)+'</td><td>'+formatDate(x.requestedAt)+'</td><td>'+makeBadge(x.status)+'</td><td>'+action+'</td></tr>';
                }).join('') || '<tr><td colspan="7"><div class="empty-state"><h3>No registration requests</h3><p>Resident registration requests will appear here.</p></div></td></tr>';
                body.querySelectorAll('[data-approve],[data-reject]').forEach(function (button) {
                    button.addEventListener('click', async function () {
                        const action = button.dataset.approve ? 'approve' : 'reject';
                        const id = button.dataset.approve || button.dataset.reject;
                        const note = prompt('Optional review note') || '';
                        try {
                            await apiRequest('/admin/registration-requests/'+id+'/review',{method:'POST',body:{action:action,note:note}});
                            showMessage('Registration request '+(action==='approve'?'approved':'rejected')+'.','success'); await draw();
                        } catch (error) { showMessage(error.message,'error'); }
                    });
                });
            } catch (error) { showMessage(error.message || 'Registration requests could not be loaded.', 'error'); }
        }
        getElement('registrationStatusFilter').addEventListener('change', draw); await draw();
    }

    document.addEventListener('DOMContentLoaded', function () {
        if (!currentUser()) return;
        renderDashboard(); renderQueue(); renderAIReview(); renderAssignment(); renderEmergency(); renderDuplicates(); renderTechnicianManagement(); renderNotifications(); renderProfile(); renderRegistrations();
    });
})();
