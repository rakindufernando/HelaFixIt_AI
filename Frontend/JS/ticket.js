/* Live resident ticket submission using the Flask backend and XAMPP database. */
(function () {
    let ticketOptions = null;

    function optionHtml(value, label) {
        return '<option value="' + escapeHTML(value) + '">' + escapeHTML(label) + '</option>';
    }

    function fillLocationOptions() {
        if (!ticketOptions || !getElement('ticketBlock')) return;
        const block = getElement('ticketBlock');
        const floor = getElement('ticketFloor');
        const area = getElement('ticketArea');
        block.innerHTML = '<option value="">Select block</option>' + ticketOptions.buildings.map(function (b) {
            return optionHtml(b.building_id, b.block_code + ' · ' + b.name);
        }).join('');
        const preferredBuilding = String(ticketOptions.resident.building_id || '');
        if (preferredBuilding) block.value = preferredBuilding;
        if (ticketOptions.buildings.length === 1) {
            block.disabled = true;
            block.title = 'Your registered building is used for maintenance requests.';
        }

        function drawFloors() {
            const buildingId = Number(block.value || 0);
            const floors = ticketOptions.floors.filter(function (f) { return Number(f.building_id) === buildingId; });
            floor.innerHTML = '<option value="">Select floor</option>' + floors.map(function (f) {
                return optionHtml(f.floor_id, f.name);
            }).join('');
            const preferredFloor = Number(ticketOptions.resident.floor_id || 0);
            if (floors.some(function (f) { return Number(f.floor_id) === preferredFloor; })) floor.value = String(preferredFloor);
            drawAreas();
        }

        function drawAreas() {
            const buildingId = Number(block.value || 0);
            const floorId = Number(floor.value || 0);
            const areas = ticketOptions.areas.filter(function (a) {
                return Number(a.building_id) === buildingId && (!a.floor_id || Number(a.floor_id) === floorId);
            });
            area.innerHTML = '<option value="">Select area</option>' + areas.map(function (a) {
                return optionHtml(a.area_id, a.name);
            }).join('');
        }

        block.addEventListener('change', drawFloors);
        floor.addEventListener('change', drawAreas);
        drawFloors();
    }

    async function loadTicketOptions() {
        if (!getElement('ticketForm')) return;
        try {
            const response = await apiRequest('/resident/ticket-options');
            ticketOptions = response.data;
            fillLocationOptions();
        } catch (error) {
            showMessage(error.message || 'Could not load apartment locations.', 'error');
        }
    }

    async function submitTicket(form) {
        if (!validateRequired(form)) return;
        const button = form.querySelector('button[type="submit"]');
        const originalText = button ? button.textContent : '';
        if (button) { button.disabled = true; button.textContent = 'Saving ticket...'; }

        const body = new FormData();
        body.append('title', getElement('ticketTitle').value.trim());
        body.append('description', getElement('ticketDescription').value.trim());
        body.append('building_id', getElement('ticketBlock').value);
        body.append('floor_id', getElement('ticketFloor').value);
        body.append('area_id', getElement('ticketArea').value);
        body.append('asset', getElement('ticketAsset').value.trim());
        const image = getElement('ticketImage');
        if (image && image.files && image.files[0]) body.append('image', image.files[0]);

        try {
            const response = await apiRequest('/resident/tickets', { method:'POST', body:body });
            const ticket = response.data.ticket;
            showMessage('Ticket saved to the live database.', 'success');
            setTimeout(function () {
                location.href = 'ticket-ai-result.html?id=' + encodeURIComponent(ticket.id);
            }, 450);
        } catch (error) {
            showMessage(error.message || 'Ticket could not be submitted.', 'error');
            if (button) { button.disabled = false; button.textContent = originalText; }
        }
    }

    document.addEventListener('DOMContentLoaded', function () {
        loadTicketOptions();
        const form = getElement('ticketForm');
        if (form) form.addEventListener('submit', function (event) {
            event.preventDefault();
            submitTicket(form);
        });
    });
})();
