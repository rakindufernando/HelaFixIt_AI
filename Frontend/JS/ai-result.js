/* Displays the current database-backed analysis state for a resident ticket.
   AI results are loaded from the current database record. */
(function () {
    function displayValue(value, fallback) {
        return value === null || value === undefined || value === '' ? (fallback || '-') : value;
    }

    async function renderResultPage() {
        const root = getElement('aiResultPage');
        if (!root) return;
        let id = getQuery('id');
        try {
            if (!id) {
                const listResponse = await apiRequest('/resident/tickets');
                const tickets = (listResponse.data || {}).tickets || [];
                if (!tickets.length) {
                    showMessage('No maintenance tickets are available yet. Submit a ticket first.', 'info');
                    return;
                }
                id = tickets[0].id;
                history.replaceState(null, '', location.pathname + '?id=' + encodeURIComponent(id));
            }
            const response = await apiRequest('/resident/tickets/' + encodeURIComponent(id) + '/analysis');
            const ticket = response.data.ticket;
            setText('resultTicketId', ticket.id);
            setText('resultCategory', ticket.predictionAvailable ? displayValue(ticket.category) : 'Pending analysis');
            setText('resultPriority', ticket.predictionAvailable ? displayValue(ticket.priority) : 'Pending');
            setText('resultRisk', ticket.risk === null ? 'Pending' : ticket.risk + '/100');
            setText('resultConfidence', ticket.confidence === null ? 'Pending' : ticket.confidence + '%');
            setText('resultLanguage', displayValue(ticket.language, 'Unknown'));
            setText('resultTechnicianType', ticket.predictionAvailable ? displayValue(ticket.technicianType) : 'Pending recommendation');
            setText('resultSafety', ticket.predictionAvailable ? displayValue(ticket.safety) : 'Ticket analysis is pending.');
            setText('resultDuplicate', ticket.predictionAvailable ? (ticket.duplicate ? 'Possible duplicate of ' + displayValue(ticket.duplicateOf) : 'No active duplicate detected') : 'Pending duplicate check');
            setText('resultAssignment', ticket.technician ? ticket.technician + ' · ' + displayValue(ticket.assignmentMethod) : 'Waiting for apartment admin assignment');

            const risk = ticket.risk === null ? 0 : Math.max(0, Math.min(100, Number(ticket.risk)));
            const confidence = ticket.confidence === null ? 0 : Math.max(0, Math.min(100, Number(ticket.confidence)));
            const riskBar = getElement('resultRiskBar');
            const confidenceBar = getElement('resultConfidenceBar');
            if (riskBar) setTimeout(function () { riskBar.style.width = risk + '%'; }, 100);
            if (confidenceBar) setTimeout(function () { confidenceBar.style.width = confidence + '%'; }, 140);
            const emergency = getElement('emergencyResultNotice');
            if (emergency) emergency.style.display = ticket.emergency ? 'flex' : 'none';

            const pendingNote = getElement('analysisPendingNotice');
            if (pendingNote) pendingNote.style.display = ticket.predictionAvailable ? 'none' : 'flex';
        } catch (error) {
            showMessage(error.message || 'Ticket analysis could not be loaded.', 'error');
        }
    }

    document.addEventListener('DOMContentLoaded', renderResultPage);
})();
