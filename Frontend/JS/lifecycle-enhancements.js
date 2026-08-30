/* Final ticket lifecycle controls that match the configured HelaFixIt AI status transitions. */
(function () {
    function queryId() {
        return new URLSearchParams(window.location.search).get('id') || '';
    }

    async function residentActions() {
        const root = document.getElementById('residentTicketDetails');
        if (!root) return;
        const id = queryId();
        if (!id) return;
        try {
            const response = await apiRequest('/resident/tickets/' + encodeURIComponent(id));
            const ticket = response.data.ticket;
            const allowedCancel = ['Submitted','Analysing','Awaiting Review','Urgent Unassigned'].includes(ticket.status);
            const canClose = ticket.status === 'Resolved';
            const canReopen = ticket.status === 'Resolved' || ticket.status === 'Closed';
            if (!allowedCancel && !canClose && !canReopen) return;

            const section = document.createElement('section');
            section.className = 'card';
            section.id = 'residentLifecycleActions';
            section.innerHTML = '<div class="card-header"><div><h3>Ticket actions</h3><p>Use only the actions available for the current maintenance status.</p></div></div><div class="card-body"><div class="form-actions" id="residentLifecycleButtons"></div></div>';
            const firstCard = root.querySelector('.card');
            if (firstCard && firstCard.nextSibling) root.insertBefore(section, firstCard.nextSibling); else root.appendChild(section);
            const controls = section.querySelector('#residentLifecycleButtons');

            if (allowedCancel) {
                const cancel = document.createElement('button');
                cancel.type = 'button'; cancel.className = 'btn-app btn-secondary'; cancel.textContent = 'Cancel ticket';
                cancel.addEventListener('click', async function () {
                    const reason = window.prompt('Why do you want to cancel this maintenance ticket?');
                    if (reason === null) return;
                    if (reason.trim().length < 5) { showMessage('Enter a short cancellation reason.', 'error'); return; }
                    if (!window.confirm('Cancel ' + id + '?')) return;
                    try {
                        await apiRequest('/resident/tickets/' + encodeURIComponent(id) + '/cancel', {method:'POST', body:{reason:reason.trim()}});
                        showMessage('Maintenance ticket cancelled.', 'success');
                        window.setTimeout(function () { window.location.reload(); }, 500);
                    } catch (error) { showMessage(error.message, 'error'); }
                });
                controls.appendChild(cancel);
            }

            if (canClose) {
                const close = document.createElement('button');
                close.type = 'button'; close.className = 'btn-app'; close.textContent = 'Confirm repair and close';
                close.addEventListener('click', async function () {
                    if (!window.confirm('Confirm that the issue is resolved and close ' + id + '?')) return;
                    try {
                        await apiRequest('/resident/tickets/' + encodeURIComponent(id) + '/close', {method:'POST', body:{note:'Resident confirmed that the maintenance issue has been resolved.'}});
                        showMessage('Ticket closed.', 'success');
                        window.setTimeout(function () { window.location.reload(); }, 500);
                    } catch (error) { showMessage(error.message, 'error'); }
                });
                controls.appendChild(close);
            }

            if (canReopen) {
                const reopen = document.createElement('button');
                reopen.type = 'button'; reopen.className = 'btn-app btn-secondary'; reopen.textContent = 'Reopen issue';
                reopen.addEventListener('click', async function () {
                    const reason = window.prompt('Explain what is still wrong or what happened again.');
                    if (reason === null) return;
                    if (reason.trim().length < 5) { showMessage('Enter a short reason for reopening the ticket.', 'error'); return; }
                    try {
                        await apiRequest('/resident/tickets/' + encodeURIComponent(id) + '/reopen', {method:'POST', body:{reason:reason.trim()}});
                        showMessage('Ticket reopened and returned to the maintenance workflow.', 'success');
                        window.setTimeout(function () { window.location.reload(); }, 700);
                    } catch (error) { showMessage(error.message, 'error'); }
                });
                controls.appendChild(reopen);
            }
        } catch (error) {
            showMessage(error.message || 'Ticket actions could not be loaded.', 'error');
        }
    }

    async function technicianActions() {
        const root = document.getElementById('technicianJobDetails');
        if (!root) return;
        const id = queryId();
        if (!id) return;
        try {
            const response = await apiRequest('/technician/jobs/' + encodeURIComponent(id));
            const ticket = response.data.ticket;
            if (!['Assigned','Auto Assigned'].includes(ticket.status)) return;
            const actions = root.querySelector('.quick-actions');
            if (!actions || document.getElementById('declineAssignmentButton')) return;
            const button = document.createElement('button');
            button.type = 'button';
            button.id = 'declineAssignmentButton';
            button.className = 'quick-action';
            button.style.textAlign = 'left';
            button.style.cursor = 'pointer';
            button.innerHTML = '<strong>Decline assignment</strong><span>Return this job to the apartment admin for reassignment</span>';
            const back = actions.querySelector('a[href="assigned-jobs.html"]');
            if (back) actions.insertBefore(button, back); else actions.appendChild(button);
            button.addEventListener('click', async function () {
                const reason = window.prompt('Why can you not accept this assignment?');
                if (reason === null) return;
                if (reason.trim().length < 5) { showMessage('Enter a short decline reason.', 'error'); return; }
                if (!window.confirm('Decline ' + id + ' and return it for reassignment?')) return;
                try {
                    await apiRequest('/technician/jobs/' + encodeURIComponent(id) + '/decline', {method:'POST', body:{reason:reason.trim()}});
                    showMessage('Assignment declined. The apartment admin has been notified.', 'success');
                    window.setTimeout(function () { window.location.href = 'assigned-jobs.html'; }, 650);
                } catch (error) { showMessage(error.message, 'error'); }
            });
        } catch (error) {
            showMessage(error.message || 'Assignment actions could not be loaded.', 'error');
        }
    }

    async function init() {
        await residentActions();
        await technicianActions();
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { window.setTimeout(init, 450); });
    else window.setTimeout(init, 450);
})();
