/* Final System Admin management corrections for HelaFixIt AI. */
(function () {
    function replaceNode(id, deep) {
        const old = document.getElementById(id);
        if (!old) return null;
        const fresh = old.cloneNode(deep !== false);
        old.replaceWith(fresh);
        return fresh;
    }

    function button(label, action, id, extraClass) {
        return '<button type="button" class="btn-app btn-secondary btn-sm ' + (extraClass || '') + '" data-action="' + action + '" data-id="' + id + '">' + escapeHTML(label) + '</button>';
    }

    function actionCell(id, active) {
        return '<div class="table-actions">' + button('Edit', 'edit', id) + button(active ? 'Disable' : 'Enable', 'toggle', id) + '</div>';
    }

    function ask(label, current) {
        const value = window.prompt(label, current == null ? '' : String(current));
        return value === null ? null : value.trim();
    }

    function askNumber(label, current) {
        const value = ask(label, current);
        if (value === null) return null;
        const number = Number(value);
        if (!Number.isFinite(number)) {
            showMessage('Enter a valid number.', 'error');
            return undefined;
        }
        return number;
    }

    function confirmStatus(name, active) {
        return window.confirm((active ? 'Disable ' : 'Enable ') + name + '?');
    }

    async function runAction(task, successText, refresh) {
        try {
            await task();
            showMessage(successText, 'success');
            await refresh();
        } catch (error) {
            showMessage(error.message || 'The action could not be completed.', 'error');
        }
    }

    function selectedOption(select, value) {
        if (!select) return;
        select.value = value == null ? '' : String(value);
    }

    async function initSkills() {
        if (!document.getElementById('skillRows')) return;
        const body = replaceNode('skillRows', false);
        const form = replaceNode('addSkillForm', true);
        const techSelect = document.getElementById('skillTechnicianSelect');
        const assignmentRoot = document.getElementById('skillAssignmentRows');
        const saveButton = document.getElementById('saveTechnicianSkills');
        let skillData = [];
        let technicianData = [];

        async function refresh() {
            const [skillsResponse, assignmentsResponse] = await Promise.all([
                apiRequest('/system-admin/skills'),
                apiRequest('/system-admin/technician-skill-assignments')
            ]);
            skillData = skillsResponse.data.skills || [];
            technicianData = assignmentsResponse.data.technicians || [];
            body.innerHTML = skillData.map(function (x) {
                return '<tr><td>SKL-' + String(x.id).padStart(2, '0') + '</td>' +
                    '<td><span class="table-primary">' + escapeHTML(x.name) + '</span><span class="table-secondary">' + escapeHTML(x.description || '') + '</span></td>' +
                    '<td>' + Number(x.technicians || 0) + '</td><td>' + makeBadge(x.active ? 'Active' : 'Inactive') + '</td>' +
                    '<td>' + actionCell(x.id, x.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="5"><div class="empty-state"><h3>No skills configured</h3><p>Add the technician skills used by maintenance categories.</p></div></td></tr>';

            if (techSelect) {
                const current = techSelect.value;
                const activeTechnicians = technicianData.filter(function (t) { return t.active; });
                techSelect.innerHTML = '<option value="">Select technician</option>' + activeTechnicians.map(function (t) {
                    return '<option value="' + t.id + '">' + escapeHTML(t.name + ' · ' + (t.employeeCode || 'Technician')) + '</option>';
                }).join('');
                if (activeTechnicians.some(function (t) { return String(t.id) === String(current); })) techSelect.value = current;
                renderAssignments();
            }
        }

        function renderAssignments() {
            if (!assignmentRoot || !techSelect || !saveButton) return;
            const technician = technicianData.find(function (t) { return String(t.id) === String(techSelect.value); });
            if (!technician) {
                assignmentRoot.innerHTML = '<div class="empty-state"><h3>Select a technician</h3><p>Choose a technician to update verified and primary skills.</p></div>';
                saveButton.disabled = true;
                return;
            }
            const assigned = new Map((technician.skills || []).map(function (s) { return [Number(s.id), s]; }));
            assignmentRoot.innerHTML = '<div class="table-wrap"><table class="data-table"><thead><tr><th>Use</th><th>Skill</th><th>Level</th><th>Verified</th><th>Primary</th></tr></thead><tbody>' +
                skillData.map(function (skill) {
                    const current = assigned.get(Number(skill.id));
                    const checked = current ? ' checked' : '';
                    const disabled = !skill.active && !current ? ' disabled' : '';
                    const level = current ? current.level : 'Intermediate';
                    const levels = ['Basic','Intermediate','Advanced','Expert'].map(function (x) { return '<option' + (x === level ? ' selected' : '') + '>' + x + '</option>'; }).join('');
                    return '<tr data-assignment-row="' + skill.id + '"><td><input class="skill-use" type="checkbox"' + checked + disabled + '></td>' +
                        '<td><span class="table-primary">' + escapeHTML(skill.name) + '</span>' + (!skill.active ? '<span class="table-secondary">Inactive skill</span>' : '') + '</td>' +
                        '<td><select class="filter-select skill-level"' + disabled + '>' + levels + '</select></td>' +
                        '<td><input class="skill-verified" type="checkbox"' + (current && current.verified !== false ? ' checked' : '') + disabled + '></td>' +
                        '<td><input class="skill-primary" type="radio" name="primarySkill"' + (current && current.primary ? ' checked' : '') + disabled + '></td></tr>';
                }).join('') + '</tbody></table></div>';
            saveButton.disabled = false;
        }

        if (form) form.addEventListener('submit', function (event) {
            event.preventDefault();
            const name = document.getElementById('newSkill').value.trim();
            const description = document.getElementById('newSkillDescription') ? document.getElementById('newSkillDescription').value.trim() : '';
            runAction(function () { return apiRequest('/system-admin/skills', {method:'POST', body:{name:name, description:description}}); }, 'Technician skill added.', async function () { form.reset(); await refresh(); });
        });

        body.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]');
            if (!control) return;
            const id = Number(control.dataset.id);
            const item = skillData.find(function (x) { return Number(x.id) === id; });
            if (!item) return;
            if (control.dataset.action === 'edit') {
                const name = ask('Skill name', item.name); if (name === null) return;
                const description = ask('Description', item.description || ''); if (description === null) return;
                runAction(function () { return apiRequest('/system-admin/skills/' + id, {method:'PUT', body:{name:name, description:description}}); }, 'Technician skill updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.name, item.active)) {
                runAction(function () { return apiRequest('/system-admin/skills/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Technician skill status updated.', refresh);
            }
        });

        if (techSelect) techSelect.addEventListener('change', renderAssignments);
        if (saveButton) saveButton.addEventListener('click', function () {
            const technicianId = Number(techSelect.value || 0);
            if (!technicianId) return;
            const assignments = [];
            assignmentRoot.querySelectorAll('[data-assignment-row]').forEach(function (row) {
                const use = row.querySelector('.skill-use');
                if (!use || !use.checked) return;
                assignments.push({
                    skill_id: Number(row.dataset.assignmentRow),
                    level: row.querySelector('.skill-level').value,
                    verified: row.querySelector('.skill-verified').checked,
                    primary: row.querySelector('.skill-primary').checked
                });
            });
            if (!assignments.length) { showMessage('Select at least one technician skill.', 'error'); return; }
            if (assignments.filter(function (x) { return x.primary; }).length !== 1) { showMessage('Select exactly one primary skill.', 'error'); return; }
            runAction(function () { return apiRequest('/system-admin/technicians/' + technicianId + '/skills', {method:'PUT', body:{assignments:assignments}}); }, 'Technician skills updated.', refresh);
        });

        await refresh();
    }

    async function initCategories() {
        if (!document.getElementById('categoryRows')) return;
        const body = replaceNode('categoryRows', false);
        const form = replaceNode('categoryForm', true);
        let categories = [];
        let skills = [];

        async function refresh() {
            const response = await apiRequest('/system-admin/categories');
            categories = response.data.categories || [];
            skills = response.data.skills || [];
            const skillSelect = document.getElementById('newCategoryTech');
            if (skillSelect) skillSelect.innerHTML = '<option value="">Select technician skill</option>' + skills.filter(function (x) { return x.active; }).map(function (x) { return '<option value="' + x.id + '">' + escapeHTML(x.name) + '</option>'; }).join('');
            body.innerHTML = categories.map(function (c) {
                return '<tr><td>' + escapeHTML(c.code) + '</td><td><span class="table-primary">' + escapeHTML(c.name) + '</span><span class="table-secondary">' + escapeHTML(c.priority) + '</span></td>' +
                    '<td>' + escapeHTML(c.technician) + '</td><td>' + c.riskWeight + '</td><td>' + makeBadge(c.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(c.id, c.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="6"><div class="empty-state"><h3>No categories configured</h3><p>Add a maintenance category.</p></div></td></tr>';
        }

        if (form) form.addEventListener('submit', function (event) {
            event.preventDefault();
            const name = document.getElementById('newCategoryName').value.trim();
            const code = (document.getElementById('newCategoryCode').value || name).trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 50);
            const description = document.getElementById('newCategoryDescription') ? document.getElementById('newCategoryDescription').value.trim() : '';
            runAction(function () { return apiRequest('/system-admin/categories', {method:'POST', body:{
                code:code, name:name, skill_id:document.getElementById('newCategoryTech').value || null,
                risk_weight:document.getElementById('newCategoryWeight').value, priority:document.getElementById('newCategoryPriority').value,
                description:description
            }}); }, 'Issue category added.', async function () { form.reset(); await refresh(); });
        });

        body.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = categories.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const code = ask('Category code', item.code); if (code === null) return;
                const name = ask('Category name', item.name); if (name === null) return;
                const priority = ask('Default priority  Low, Medium, High or Emergency', item.priority); if (priority === null) return;
                const risk = askNumber('Risk weight from 0 to 30', item.riskWeight); if (risk === null || risk === undefined) return;
                const description = ask('Description', item.description || ''); if (description === null) return;
                const skillList = skills.filter(function (x) { return x.active || Number(x.id) === Number(item.skillId); }).map(function (x) { return x.id + '  ' + x.name; }).join('\n');
                const skillValue = ask('Default technician skill ID\n' + skillList, item.skillId || ''); if (skillValue === null) return;
                runAction(function () { return apiRequest('/system-admin/categories/' + id, {method:'PUT', body:{code:code, name:name, priority:priority, risk_weight:risk, description:description, skill_id:skillValue || null}}); }, 'Issue category updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.name, item.active)) {
                runAction(function () { return apiRequest('/system-admin/categories/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Issue category status updated.', refresh);
            }
        });
        await refresh();
    }

    async function initBuildings() {
        if (!document.getElementById('buildingRows')) return;
        const body = replaceNode('buildingRows', false);
        const form = replaceNode('buildingForm', true);
        let buildings = [];

        async function refresh() {
            const response = await apiRequest('/system-admin/buildings');
            buildings = response.data.buildings || [];
            body.innerHTML = buildings.map(function (b) {
                return '<tr><td>' + b.id + '</td><td><span class="table-primary">' + escapeHTML(b.name) + '</span><span class="table-secondary">' + escapeHTML(b.code) + '</span></td>' +
                    '<td>' + b.floors + ' / ' + b.declaredFloors + '</td><td>' + b.units + ' / ' + b.declaredUnits + '</td><td>' + makeBadge(b.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(b.id, b.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="6"><div class="empty-state"><h3>No buildings configured</h3><p>Add an apartment building.</p></div></td></tr>';
        }

        if (form) form.addEventListener('submit', function (event) {
            event.preventDefault();
            runAction(function () { return apiRequest('/system-admin/buildings', {method:'POST', body:{
                code:document.getElementById('buildingCode').value.trim(), name:document.getElementById('buildingName').value.trim(),
                floors:document.getElementById('buildingFloors').value, units:document.getElementById('buildingUnits').value
            }}); }, 'Building added.', async function () { form.reset(); await refresh(); });
        });

        body.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = buildings.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const code = ask('Building code', item.code); if (code === null) return;
                const name = ask('Building name', item.name); if (name === null) return;
                const floors = askNumber('Declared floor count', item.declaredFloors); if (floors === null || floors === undefined) return;
                const units = askNumber('Declared unit count', item.declaredUnits); if (units === null || units === undefined) return;
                const address = ask('Address label  optional', item.address || ''); if (address === null) return;
                runAction(function () { return apiRequest('/system-admin/buildings/' + id, {method:'PUT', body:{code:code, name:name, floors:floors, units:units, address:address}}); }, 'Building updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.name, item.active)) {
                runAction(function () { return apiRequest('/system-admin/buildings/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Building status updated.', refresh);
            }
        });
        await refresh();
    }

    async function initLocationsAndUnits() {
        if (!document.getElementById('areaRows')) return;
        const areaRows = replaceNode('areaRows', false);
        const floorRows = replaceNode('floorRows', false);
        const unitRows = replaceNode('unitRows', false);
        const floorForm = replaceNode('floorForm', true);
        const areaForm = replaceNode('areaForm', true);
        const unitForm = replaceNode('unitForm', true);
        let data = {buildings:[], floors:[], areas:[], units:[]};

        function buildingOptions() {
            return '<option value="">Select building</option>' + data.buildings.map(function (b) { return '<option value="' + b.id + '">' + escapeHTML(b.code + ' - ' + b.name) + '</option>'; }).join('');
        }
        function floorOptions(buildingId, allowAll) {
            return (allowAll ? '<option value="">All floors</option>' : '<option value="">Select floor</option>') + data.floors.filter(function (f) { return Number(f.buildingId) === Number(buildingId) && f.active; }).map(function (f) { return '<option value="' + f.id + '">' + escapeHTML(f.name) + '</option>'; }).join('');
        }
        function refreshDependentSelects() {
            const areaBuilding = document.getElementById('areaBuilding');
            const areaFloor = document.getElementById('areaFloor');
            if (areaBuilding && areaFloor) areaFloor.innerHTML = floorOptions(areaBuilding.value, true);
            const unitBuilding = document.getElementById('unitBuilding');
            const unitFloor = document.getElementById('unitFloor');
            if (unitBuilding && unitFloor) unitFloor.innerHTML = floorOptions(unitBuilding.value, false);
        }

        async function refresh() {
            const [locationsResponse, unitsResponse] = await Promise.all([apiRequest('/system-admin/locations'), apiRequest('/system-admin/units')]);
            data = Object.assign({}, locationsResponse.data, {units: unitsResponse.data.units || []});
            ['floorBuilding','areaBuilding','unitBuilding'].forEach(function (id) { const select = document.getElementById(id); if (select) select.innerHTML = buildingOptions(); });
            refreshDependentSelects();
            floorRows.innerHTML = (data.floors || []).map(function (f) {
                return '<tr><td>' + escapeHTML(f.block) + '</td><td>' + f.number + '</td><td>' + escapeHTML(f.name) + '</td><td>' + makeBadge(f.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(f.id, f.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="5"><div class="empty-state"><h3>No floors configured</h3><p>Add a floor for a building.</p></div></td></tr>';
            areaRows.innerHTML = (data.areas || []).map(function (a) {
                return '<tr><td>AREA-' + String(a.id).padStart(2, '0') + '</td><td><span class="table-primary">' + escapeHTML(a.name) + '</span><span class="table-secondary">' + escapeHTML(a.block + ' · ' + a.floor) + '</span></td>' +
                    '<td>' + escapeHTML(a.type) + '</td><td>' + a.riskWeight + '</td><td>' + makeBadge(a.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(a.id, a.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="6"><div class="empty-state"><h3>No areas configured</h3><p>Add a maintenance area.</p></div></td></tr>';
            unitRows.innerHTML = (data.units || []).map(function (u) {
                return '<tr><td>' + escapeHTML(u.block) + '</td><td>' + escapeHTML(u.floor) + '</td><td>' + escapeHTML(u.unitNumber) + '</td><td>' + escapeHTML(u.type) + '</td><td>' + makeBadge(u.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(u.id, u.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="6"><div class="empty-state"><h3>No units configured</h3><p>Add apartment or facility units.</p></div></td></tr>';
        }

        const areaBuilding = document.getElementById('areaBuilding'); if (areaBuilding) areaBuilding.addEventListener('change', refreshDependentSelects);
        const unitBuilding = document.getElementById('unitBuilding'); if (unitBuilding) unitBuilding.addEventListener('change', refreshDependentSelects);

        if (floorForm) floorForm.addEventListener('submit', function (event) {
            event.preventDefault();
            runAction(function () { return apiRequest('/system-admin/floors', {method:'POST', body:{building_id:document.getElementById('floorBuilding').value, floor_number:document.getElementById('floorNumber').value, name:document.getElementById('floorName').value.trim()}}); }, 'Floor added.', async function () { floorForm.reset(); await refresh(); });
        });
        if (areaForm) areaForm.addEventListener('submit', function (event) {
            event.preventDefault();
            runAction(function () { return apiRequest('/system-admin/areas', {method:'POST', body:{building_id:document.getElementById('areaBuilding').value, floor_id:document.getElementById('areaFloor').value || null, name:document.getElementById('newArea').value.trim(), area_type:document.getElementById('areaType').value, risk_weight:document.getElementById('areaRisk').value}}); }, 'Area added.', async function () { areaForm.reset(); await refresh(); });
        });
        if (unitForm) unitForm.addEventListener('submit', function (event) {
            event.preventDefault();
            runAction(function () { return apiRequest('/system-admin/units', {method:'POST', body:{floor_id:document.getElementById('unitFloor').value, unit_number:document.getElementById('unitNumber').value.trim(), unit_type:document.getElementById('unitType').value}}); }, 'Unit added.', async function () { unitForm.reset(); await refresh(); });
        });

        floorRows.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = data.floors.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const number = askNumber('Floor number', item.number); if (number === null || number === undefined) return;
                const name = ask('Floor name', item.name); if (name === null) return;
                runAction(function () { return apiRequest('/system-admin/floors/' + id, {method:'PUT', body:{floor_number:number, name:name}}); }, 'Floor updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.name, item.active)) {
                runAction(function () { return apiRequest('/system-admin/floors/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Floor status updated.', refresh);
            }
        });
        areaRows.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = data.areas.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const name = ask('Area name', item.name); if (name === null) return;
                const type = ask('Area type  Private, Common, Service, Outdoor or Other', item.type); if (type === null) return;
                const risk = askNumber('Risk weight from 0 to 30', item.riskWeight); if (risk === null || risk === undefined) return;
                runAction(function () { return apiRequest('/system-admin/areas/' + id, {method:'PUT', body:{name:name, area_type:type, risk_weight:risk}}); }, 'Area updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.name, item.active)) {
                runAction(function () { return apiRequest('/system-admin/areas/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Area status updated.', refresh);
            }
        });
        unitRows.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = data.units.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const number = ask('Unit number', item.unitNumber); if (number === null) return;
                const type = ask('Unit type  Apartment, Common Facility, Staff or Other', item.type); if (type === null) return;
                runAction(function () { return apiRequest('/system-admin/units/' + id, {method:'PUT', body:{unit_number:number, unit_type:type}}); }, 'Unit updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.unitNumber, item.active)) {
                runAction(function () { return apiRequest('/system-admin/units/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Unit status updated.', refresh);
            }
        });
        await refresh();
    }

    async function initBackupHistory() {
        const body = document.getElementById('backupHistoryRows');
        if (!body) return;
        async function refresh() {
            try {
                const response = await apiRequest('/system-admin/backup/records');
                const records = response.data.records || [];
                body.innerHTML = records.map(function (r) {
                    return '<tr><td>EXP-' + String(r.id).padStart(3, '0') + '</td><td>' + escapeHTML(r.type || 'Data') + '</td>' +
                        '<td>' + escapeHTML(r.fileName || 'helafixit_data_export.json') + '</td><td>' + makeBadge(r.status || 'Completed') + '</td>' +
                        '<td>' + escapeHTML(r.startedBy || 'System') + '</td><td>' + (r.completedAt ? formatDate(r.completedAt) : '-') + '</td></tr>';
                }).join('') || '<tr><td colspan="6"><div class="empty-state"><h3>No exports yet</h3><p>Download a JSON export to create the first history record.</p></div></td></tr>';
                const count = document.getElementById('backupRecords');
                const last = document.getElementById('backupLastTime');
                if (count) count.textContent = String(records.length);
                if (last) last.textContent = records.length && records[0].completedAt ? formatDate(records[0].completedAt) : 'Ready';
            } catch (error) {
                body.innerHTML = '<tr><td colspan="6"><div class="empty-state"><h3>Export history unavailable</h3><p>' + escapeHTML(error.message || 'Please try again.') + '</p></div></td></tr>';
            }
        }
        const download = document.getElementById('downloadBackup');
        if (download && !download.dataset.historyRefreshBound) {
            download.dataset.historyRefreshBound = '1';
            download.addEventListener('click', function () {
                window.setTimeout(refresh, 1200);
                window.setTimeout(refresh, 2600);
            });
        }
        await refresh();
    }

    async function initSafetyRules() {
        if (!document.getElementById('safetyRuleRows')) return;
        const body = replaceNode('safetyRuleRows', false);
        const form = replaceNode('safetyRuleForm', true);
        let rules = [];
        let categories = [];

        async function refresh() {
            const response = await apiRequest('/system-admin/safety-rules');
            rules = response.data.rules || [];
            categories = response.data.categories || [];
            const category = document.getElementById('ruleCategory');
            if (category) category.innerHTML = '<option value="">Any category</option>' + categories.filter(function (c) { return c.active; }).map(function (c) { return '<option value="' + c.id + '">' + escapeHTML(c.name) + '</option>'; }).join('');
            body.innerHTML = rules.map(function (x) {
                return '<tr><td>' + escapeHTML(x.code) + '</td><td><span class="table-primary">' + escapeHTML(x.keyword) + '</span><span class="table-secondary">' + escapeHTML(x.language + ' · ' + x.matchType) + '</span></td>' +
                    '<td>' + escapeHTML(x.category) + '</td><td>' + x.risk + '</td><td>' + escapeHTML(x.warning) + '</td><td>' + makeBadge(x.active ? 'Active' : 'Inactive') + '</td><td>' + actionCell(x.id, x.active) + '</td></tr>';
            }).join('') || '<tr><td colspan="7"><div class="empty-state"><h3>No database safety rules</h3><p>Add hazard rules used by the AI decision support workflow.</p></div></td></tr>';
        }

        if (form) form.addEventListener('submit', function (event) {
            event.preventDefault();
            runAction(function () { return apiRequest('/system-admin/safety-rules', {method:'POST', body:{
                code:document.getElementById('ruleCode').value.trim(), keyword:document.getElementById('ruleKeyword').value.trim(),
                category_id:document.getElementById('ruleCategory').value || null, score:document.getElementById('ruleScore').value,
                warning:document.getElementById('ruleWarning').value.trim(), language:document.getElementById('ruleLanguage').value,
                severity:document.getElementById('ruleSeverity').value, match_type:'Phrase',
                resident_action:document.getElementById('ruleResidentAction') ? document.getElementById('ruleResidentAction').value.trim() : '',
                technician_action:document.getElementById('ruleTechnicianAction') ? document.getElementById('ruleTechnicianAction').value.trim() : ''
            }}); }, 'Safety rule added.', async function () { form.reset(); await refresh(); });
        });

        body.addEventListener('click', function (event) {
            const control = event.target.closest('[data-action]'); if (!control) return;
            const id = Number(control.dataset.id); const item = rules.find(function (x) { return Number(x.id) === id; }); if (!item) return;
            if (control.dataset.action === 'edit') {
                const code = ask('Rule code', item.code); if (code === null) return;
                const keyword = ask('Hazard keyword or phrase', item.keyword); if (keyword === null) return;
                const matchType = ask('Match type  Keyword, Phrase or Regex', item.matchType); if (matchType === null) return;
                const language = ask('Language  Any, English, Sinhala, Singlish or Mixed', item.language); if (language === null) return;
                const severity = ask('Severity  Low, Medium, High or Critical', item.severity); if (severity === null) return;
                const risk = askNumber('Risk score weight from 0 to 50', item.risk); if (risk === null || risk === undefined) return;
                const warning = ask('Safety warning', item.warning); if (warning === null) return;
                const residentAction = ask('Resident action', item.residentAction || ''); if (residentAction === null) return;
                const technicianAction = ask('Technician action', item.technicianAction || ''); if (technicianAction === null) return;
                const categoryList = categories.filter(function (c) { return c.active || Number(c.id) === Number(item.categoryId); }).map(function (c) { return c.id + '  ' + c.name; }).join('\n');
                const categoryId = ask('Category ID  leave blank for any category\n' + categoryList, item.categoryId || ''); if (categoryId === null) return;
                runAction(function () { return apiRequest('/system-admin/safety-rules/' + id, {method:'PUT', body:{code:code, keyword:keyword, match_type:matchType, language:language, severity:severity, score:risk, warning:warning, resident_action:residentAction, technician_action:technicianAction, category_id:categoryId || null}}); }, 'Safety rule updated.', refresh);
            } else if (control.dataset.action === 'toggle' && confirmStatus(item.code, item.active)) {
                runAction(function () { return apiRequest('/system-admin/safety-rules/' + id + '/status', {method:'PATCH', body:{active:!item.active}}); }, 'Safety rule status updated.', refresh);
            }
        });
        await refresh();
    }

    async function init() {
        try {
            await initSkills();
            await initCategories();
            await initBuildings();
            await initLocationsAndUnits();
            await initSafetyRules();
            await initBackupHistory();
        } catch (error) {
            showMessage(error.message || 'System Admin management controls could not be loaded.', 'error');
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { window.setTimeout(init, 350); });
    } else {
        window.setTimeout(init, 350);
    }
})();
