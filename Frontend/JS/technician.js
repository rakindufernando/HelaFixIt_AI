/* Technician portal backed by Flask and the live maintenance workflow. */
(function () {
    function riskText(t) { return t.risk === null || t.risk === undefined ? 'Pending' : t.risk + '/100'; }
    function jobCard(t) {
        return '<div class="ticket-card ' + (t.emergency ? 'emergency-card' : '') + '"><div class="ticket-head"><div><span class="ticket-id">' + escapeHTML(t.id) + '</span><div class="ticket-title">' + escapeHTML(t.title) + '</div></div>' + makeBadge(t.priority) + '</div>' +
            '<div class="ticket-meta"><span>' + escapeHTML(t.category) + '</span><span>' + escapeHTML(t.block) + ' · ' + escapeHTML(t.floor) + '</span><span>Risk ' + riskText(t) + '</span></div>' +
            '<div class="ticket-actions">' + makeBadge(t.status) + '<button class="btn-app btn-secondary btn-sm" onclick="navigateWithId(\'technician-job-details.html\',\'' + escapeHTML(t.id) + '\')">Open job</button></div></div>';
    }

    async function renderDashboard() {
        if (!getElement('technicianDashboard')) return;
        try {
            const response = await apiRequest('/technician/dashboard');
            const d = response.data;
            setText('techAssignedCount', d.stats.assigned); setText('techEmergencyCount', d.stats.emergency); setText('techProgressCount', d.stats.in_progress); setText('techCompletedCount', d.stats.completed);
            setText('techAvailability', d.profile ? d.profile.status : '-');
            getElement('techDashboardJobs').innerHTML = d.jobs.map(jobCard).join('') || '<div class="empty-state"><h3>No jobs assigned</h3><p>New jobs will appear here after apartment admin assignment.</p></div>';
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderAssigned() {
        const root = getElement('assignedJobList'); if (!root) return;
        async function draw() {
            try {
                const status = getElement('techJobStatusFilter').value;
                const path = '/technician/jobs' + (status ? '?status=' + encodeURIComponent(status) : '');
                const response = await apiRequest(path);
                root.innerHTML = response.data.jobs.map(jobCard).join('') || '<div class="card"><div class="empty-state"><h3>No matching jobs</h3><p>Try another status filter.</p></div></div>';
            } catch (error) { root.innerHTML = '<div class="card"><div class="empty-state"><h3>Could not load jobs</h3><p>' + escapeHTML(error.message) + '</p></div></div>'; }
        }
        getElement('techJobStatusFilter').addEventListener('change', draw); draw();
    }

    async function renderEmergency() {
        const root = getElement('techEmergencyList'); if (!root) return;
        try {
            const response = await apiRequest('/technician/jobs?emergency=true');
            root.innerHTML = response.data.jobs.map(jobCard).join('') || '<div class="card"><div class="empty-state"><h3>No emergency jobs</h3><p>You currently have no emergency assignments.</p></div></div>';
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function loadJob() {
        const id = getQuery('id');
        if (!id) throw new Error('Open a job from Assigned Jobs first.');
        const response = await apiRequest('/technician/jobs/' + encodeURIComponent(id));
        return response.data.ticket;
    }

    async function renderDetails() {
        if (!getElement('technicianJobDetails')) return;
        try {
            const t = await loadJob();
            setText('jobDetailId', t.id); setText('jobDetailTitle', t.title); setText('jobDetailDescription', t.description); setText('jobDetailResident', t.resident);
            setText('jobDetailLocation', t.block + ' · ' + t.floor + ' · ' + t.area); setText('jobDetailCategory', t.category);
            setText('jobDetailRisk', t.risk === null ? 'Pending analysis' : t.risk + '/100 · ' + t.riskLevel); setText('jobDetailSafety', t.safety);
            setText('jobDetailRepair', t.repairNote || 'No repair note yet.'); getElement('jobDetailPriority').innerHTML = makeBadge(t.priority); getElement('jobDetailStatus').innerHTML = makeBadge(t.status);
            const issuePhotoSection = getElement('jobIssuePhotoSection');
            if (issuePhotoSection && t.issuePhoto) {
                const loaded = await loadProtectedImage('/technician/jobs/' + encodeURIComponent(t.id) + '/issue-photo', getElement('jobIssuePhoto'));
                issuePhotoSection.hidden = !loaded;
            }
            const updateLink = getElement('updateStatusLink');
            const notesLink = getElement('repairNotesLink');
            const completionLink = getElement('completionLink');
            const statusChoices = allowedStatuses(t.status);
            if (updateLink) {
                updateLink.href = 'update-job-status.html?id=' + encodeURIComponent(t.id);
                updateLink.style.display = statusChoices.length ? '' : 'none';
            }
            if (notesLink) {
                notesLink.href = 'repair-notes.html?id=' + encodeURIComponent(t.id);
                notesLink.style.display = ['Accepted','In Progress','On Hold'].includes(t.status) ? '' : 'none';
            }
            if (completionLink) {
                completionLink.href = 'completion-proof.html?id=' + encodeURIComponent(t.id);
                completionLink.style.display = t.status === 'In Progress' ? '' : 'none';
            }
        } catch (error) { showMessage(error.message, 'error'); }
    }

    function allowedStatuses(current) {
        if (current === 'Assigned' || current === 'Auto Assigned') return ['Accepted'];
        if (current === 'Accepted') return ['In Progress'];
        if (current === 'In Progress') return ['On Hold'];
        if (current === 'On Hold') return ['In Progress'];
        return [];
    }

    async function renderStatus() {
        if (!getElement('updateJobStatusPage')) return;
        try {
            const t = await loadJob(); setText('statusJobId', t.id); setText('statusJobTitle', t.title);
            const select = getElement('jobStatusSelect'); const choices = allowedStatuses(t.status);
            select.innerHTML = choices.map(function (s) { return '<option>' + escapeHTML(s) + '</option>'; }).join('') || '<option value="">No status change available</option>';
            const noteField = getElement('statusNote');
            const submitButton = getElement('jobStatusForm').querySelector('button[type="submit"]');
            noteField.value = '';
            if (!choices.length && submitButton) submitButton.disabled = true;
            function updateNoteRequirement() {
                const required = select.value === 'On Hold';
                noteField.required = required;
                noteField.placeholder = required ? 'Explain why the job is being placed on hold.' : 'Add a short progress note if needed.';
            }
            select.addEventListener('change', updateNoteRequirement);
            updateNoteRequirement();
            getElement('jobStatusForm').addEventListener('submit', async function (event) {
                event.preventDefault(); if (!select.value) { showMessage('No status change is available for this job.', 'error'); return; }
                if (select.value === 'On Hold' && !noteField.value.trim()) { showMessage('Add a short reason before placing the job on hold.', 'error'); noteField.focus(); return; }
                try {
                    await apiRequest('/technician/jobs/' + encodeURIComponent(t.id) + '/status', {method:'POST', body:{status:select.value, note:noteField.value.trim()}});
                    showMessage('Job status saved to the database.', 'success');
                    setTimeout(function () { location.href = 'technician-job-details.html?id=' + encodeURIComponent(t.id); }, 300);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderNotes() {
        if (!getElement('repairNotesPage')) return;
        try {
            const t = await loadJob(); setText('notesJobId', t.id); setText('notesJobTitle', t.title); getElement('repairNotesText').value = t.repairNote || '';
            const notesForm = getElement('repairNotesForm');
            const canAddNotes = ['Accepted','In Progress','On Hold'].includes(t.status);
            if (!canAddNotes) {
                const button = notesForm.querySelector('button[type="submit"]');
                if (button) button.disabled = true;
                getElement('repairNotesText').disabled = true;
                showMessage('Accept the job before adding repair notes.', 'info');
            }
            notesForm.addEventListener('submit', async function (event) {
                event.preventDefault();
                if (!validateRequired(event.currentTarget)) return;
                try {
                    await apiRequest('/technician/jobs/' + encodeURIComponent(t.id) + '/repair-note', {method:'POST', body:{note:getElement('repairNotesText').value.trim()}});
                    showMessage('Repair note saved to the database.', 'success');
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderCompletion() {
        if (!getElement('completionProofPage')) return;
        try {
            const t = await loadJob(); setText('proofJobId', t.id); setText('proofJobTitle', t.title); getElement('completionSummary').value = t.repairNote || '';
            const form = getElement('completionProofForm');
            if (t.status !== 'In Progress') {
                const button = form.querySelector('button[type="submit"]');
                if (button) button.disabled = true;
                showMessage('Start the job before marking it completed.', 'info');
            }
            form.addEventListener('submit', async function (event) {
                event.preventDefault(); if (!validateRequired(form)) return;
                const body = new FormData(); body.append('summary', getElement('completionSummary').value.trim());
                const file = getElement('proofFile'); if (file.files && file.files[0]) body.append('image', file.files[0]);
                try {
                    await apiRequest('/technician/jobs/' + encodeURIComponent(t.id) + '/complete', {method:'POST', body:body});
                    showMessage('Job marked resolved in the database.', 'success');
                    setTimeout(function () { location.href = 'assigned-jobs.html'; }, 350);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message, 'error'); }
    }

    async function renderProfile() {
        if (!getElement('technicianProfile')) return;
        try {
            const response = await apiRequest('/technician/profile'); const t = response.data.profile;
            setText('techProfileName', t.name); setText('techProfileSkill', t.skill); setText('techProfileInitial', (t.name || 'T')[0]);
            getElement('techName').value = t.name || '';
            if(getElement('techEmail'))getElement('techEmail').value=t.email||'';
            getElement('techPhone').value = t.phone || '';
            if(getElement('techEmployeeCode'))getElement('techEmployeeCode').value=t.employeeCode||'';
            getElement('techSkill').value = t.skill || '';
            if(getElement('techBuilding'))getElement('techBuilding').value=t.block||'';
            if(getElement('techWorkload'))getElement('techWorkload').value=String(t.workload||0)+' / '+String(t.maxJobs||0);
            if(getElement('techEmergencyEligible'))getElement('techEmergencyEligible').value=t.emergency?'Yes':'No';
            getElement('techAvailabilitySelect').value = t.status || 'Off Duty';
            getElement('techProfileForm').addEventListener('submit', async function (event) {
                event.preventDefault();
                if (!validateRequired(event.currentTarget)) return;
                try {
                    const update = await apiRequest('/technician/profile', {method:'PUT', body:{name:getElement('techName').value.trim(), phone:normalizeSriLankanMobile(getElement('techPhone').value), availability:getElement('techAvailabilitySelect').value}});
                    const userResponse = await apiRequest('/auth/me'); setAuthSession(getAuthToken(), userResponse.data.user);
                    showMessage('Technician profile updated.', 'success'); setTimeout(function () { location.reload(); }, 250);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) { showMessage(error.message, 'error'); }
    }


    async function renderNotifications() {
        const root=getElement('technicianNotificationList'); if(!root)return;
        async function draw(){try{const r=await apiRequest('/technician/notifications');root.innerHTML=(r.data.notifications||[]).map(n=>'<div class="notification-item '+(!n.read?'unread':'')+'"><div class="notification-symbol">'+(/emergency/i.test((n.type||'')+(n.title||''))?'!':'i')+'</div><div><h4>'+escapeHTML(n.title)+'</h4><p>'+escapeHTML(n.text)+'</p><time>'+formatDate(n.time)+'</time></div></div>').join('')||'<div class="empty-state"><h3>No notifications</h3><p>Assigned job and emergency notifications will appear here.</p></div>';}catch(e){showMessage(e.message,'error');}}
        const btn=getElement('markTechnicianRead');if(btn)btn.onclick=async()=>{try{await apiRequest('/technician/notifications/read-all',{method:'POST'});showMessage('Notifications marked as read.','success');await draw();if(window.refreshNotificationButton)window.refreshNotificationButton();}catch(e){showMessage(e.message,'error');}};await draw();
    }
    document.addEventListener('DOMContentLoaded', function () {
        if (!currentUser()) return;
        renderDashboard(); renderAssigned(); renderEmergency(); renderDetails(); renderStatus(); renderNotes(); renderCompletion(); renderProfile();
        renderNotifications();
    });
})();
