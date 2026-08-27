/* System Admin pages use only data returned by the Flask API and MySQL database. */
(function(){
    function emptyRow(cols,title,text){return '<tr><td colspan="'+cols+'"><div class="empty-state"><h3>'+escapeHTML(title)+'</h3><p>'+escapeHTML(text)+'</p></div></td></tr>';}

    async function renderDashboard(){
        if(!getElement('systemAdminDashboard'))return;
        try{
            const r=await apiRequest('/system-admin/dashboard'),d=r.data;
            setText('sysUsers',d.stats.users);setText('sysTechnicians',d.stats.technicians);setText('sysCategories',d.stats.categories);setText('sysBuildings',d.stats.buildings);
            const pending=getElement('sysPendingRegistrations'); if(pending)setText('sysPendingRegistrations',d.stats.pending_registrations);
            getElement('sysAuditPreview').innerHTML=d.audit.map(function(l){return '<div class="notification-item"><div class="notification-symbol">L</div><div><h4>'+escapeHTML(l.action)+' · '+escapeHTML(l.target)+'</h4><p>'+escapeHTML(l.detail||'Recorded system action')+'</p><time>'+formatDate(l.time)+' · '+escapeHTML(l.user)+'</time></div></div>';}).join('')||'<div class="empty-state"><h3>No audit activity</h3><p>System actions will appear here.</p></div>';
        }catch(e){showMessage(e.message,'error');}
    }

    async function renderRoles(){const body=getElement('roleRows');if(!body)return;try{const r=await apiRequest('/system-admin/roles');body.innerHTML=r.data.roles.map(x=>'<tr><td><span class="table-primary">'+escapeHTML(x.name)+'</span><span class="table-secondary">'+escapeHTML(x.code)+'</span></td><td>'+x.users+'</td><td>'+escapeHTML(x.permissions||'No permissions configured')+'</td><td>'+makeBadge(x.active?'Active':'Inactive')+'</td></tr>').join('');}catch(e){showMessage(e.message,'error');}}

    async function renderSkills(){const body=getElement('skillRows');if(!body)return;async function draw(){const r=await apiRequest('/system-admin/skills');body.innerHTML=r.data.skills.map(x=>'<tr><td>SKL-'+String(x.id).padStart(2,'0')+'</td><td><span class="table-primary">'+escapeHTML(x.name)+'</span><span class="table-secondary">'+escapeHTML(x.description||'')+'</span></td><td>'+x.technicians+'</td><td>'+makeBadge(x.active?'Active':'Inactive')+'</td></tr>').join('')||emptyRow(4,'No skills configured','Add the technician skills used by maintenance categories.');}getElement('addSkillForm').addEventListener('submit',async e=>{e.preventDefault();try{await apiRequest('/system-admin/skills',{method:'POST',body:{name:getElement('newSkill').value.trim()}});e.currentTarget.reset();showMessage('Technician skill added.','success');await draw();}catch(err){showMessage(err.message,'error');}});try{await draw();}catch(e){showMessage(e.message,'error');}}

    async function renderCategories(){const body=getElement('categoryRows');if(!body)return;async function draw(){const r=await apiRequest('/system-admin/categories');const d=r.data;const tech=getElement('newCategoryTech');if(tech)tech.innerHTML='<option value="">Select technician skill</option>'+d.skills.map(s=>'<option value="'+s.id+'">'+escapeHTML(s.name)+'</option>').join('');body.innerHTML=d.categories.map(c=>'<tr><td>'+escapeHTML(c.code)+'</td><td><span class="table-primary">'+escapeHTML(c.name)+'</span><span class="table-secondary">'+escapeHTML(c.priority)+'</span></td><td>'+escapeHTML(c.technician)+'</td><td>'+c.riskWeight+'</td><td>'+makeBadge(c.active?'Active':'Inactive')+'</td><td>Configured</td></tr>').join('');}getElement('categoryForm').addEventListener('submit',async e=>{e.preventDefault();try{const name=getElement('newCategoryName').value.trim();await apiRequest('/system-admin/categories',{method:'POST',body:{code:(getElement('newCategoryCode').value||name).trim().toUpperCase().replace(/[^A-Z0-9]+/g,'_').slice(0,50),name:name,skill_id:getElement('newCategoryTech').value||null,risk_weight:getElement('newCategoryWeight').value,priority:getElement('newCategoryPriority').value}});e.currentTarget.reset();showMessage('Issue category added.','success');await draw();}catch(err){showMessage(err.message,'error');}});try{await draw();}catch(e){showMessage(e.message,'error');}}

    async function renderBuildings(){const body=getElement('buildingRows');if(!body)return;async function draw(){const r=await apiRequest('/system-admin/buildings');body.innerHTML=r.data.buildings.map(b=>'<tr><td>'+b.id+'</td><td><span class="table-primary">'+escapeHTML(b.name)+'</span><span class="table-secondary">'+escapeHTML(b.code)+'</span></td><td>'+b.floors+' / '+b.declaredFloors+'</td><td>'+b.units+' / '+b.declaredUnits+'</td><td>'+makeBadge(b.active?'Active':'Inactive')+'</td></tr>').join('')||emptyRow(5,'No buildings configured','Add the apartment blocks before resident registration.');}getElement('buildingForm').addEventListener('submit',async e=>{e.preventDefault();try{await apiRequest('/system-admin/buildings',{method:'POST',body:{code:getElement('buildingCode').value.trim(),name:getElement('buildingName').value.trim(),floors:getElement('buildingFloors').value,units:getElement('buildingUnits').value}});e.currentTarget.reset();showMessage('Building added.','success');await draw();}catch(err){showMessage(err.message,'error');}});try{await draw();}catch(e){showMessage(e.message,'error');}}

    async function renderAreas(){const body=getElement('areaRows');if(!body)return;async function draw(){const r=await apiRequest('/system-admin/locations'),d=r.data;const building=getElement('areaBuilding'),floor=getElement('areaFloor');building.innerHTML='<option value="">Select building</option>'+d.buildings.map(b=>'<option value="'+b.id+'">'+escapeHTML(b.code+' - '+b.name)+'</option>').join('');function floors(){const bid=Number(building.value||0);floor.innerHTML='<option value="">All floors</option>'+d.floors.filter(f=>f.buildingId===bid).map(f=>'<option value="'+f.id+'">'+escapeHTML(f.name)+'</option>').join('');}building.onchange=floors;floors();body.innerHTML=d.areas.map(a=>'<tr><td>AREA-'+String(a.id).padStart(2,'0')+'</td><td><span class="table-primary">'+escapeHTML(a.name)+'</span><span class="table-secondary">'+escapeHTML(a.block+' · '+a.floor)+'</span></td><td>'+escapeHTML(a.type)+'</td><td>'+a.riskWeight+'</td></tr>').join('')||emptyRow(4,'No areas configured','Add maintenance areas after creating buildings and floors.');const floorRows=getElement('floorRows');if(floorRows)floorRows.innerHTML=d.floors.map(f=>'<tr><td>'+escapeHTML(f.block)+'</td><td>'+f.number+'</td><td>'+escapeHTML(f.name)+'</td><td>'+makeBadge(f.active?'Active':'Inactive')+'</td></tr>').join('')||emptyRow(4,'No floors configured','Add a floor for a building.');}
        const floorForm=getElement('floorForm');if(floorForm)floorForm.addEventListener('submit',async e=>{e.preventDefault();try{await apiRequest('/system-admin/floors',{method:'POST',body:{building_id:getElement('floorBuilding').value,floor_number:getElement('floorNumber').value,name:getElement('floorName').value.trim()}});e.currentTarget.reset();showMessage('Floor added.','success');await draw();}catch(err){showMessage(err.message,'error');}});
        getElement('areaForm').addEventListener('submit',async e=>{e.preventDefault();try{await apiRequest('/system-admin/areas',{method:'POST',body:{building_id:getElement('areaBuilding').value,floor_id:getElement('areaFloor').value||null,name:getElement('newArea').value.trim(),area_type:getElement('areaType').value,risk_weight:getElement('areaRisk').value}});e.currentTarget.reset();showMessage('Area added.','success');await draw();}catch(err){showMessage(err.message,'error');}});
        try{await draw();const r=await apiRequest('/system-admin/buildings');const options='<option value="">Select building</option>'+r.data.buildings.map(b=>'<option value="'+b.id+'">'+escapeHTML(b.code+' - '+b.name)+'</option>').join('');if(getElement('floorBuilding'))getElement('floorBuilding').innerHTML=options;}catch(e){showMessage(e.message,'error');}}

    async function renderRules(){const body=getElement('safetyRuleRows');if(!body)return;async function draw(){const r=await apiRequest('/system-admin/safety-rules'),d=r.data;const category=getElement('ruleCategory');category.innerHTML='<option value="">Any category</option>'+d.categories.map(c=>'<option value="'+c.id+'">'+escapeHTML(c.name)+'</option>').join('');body.innerHTML=d.rules.map(x=>'<tr><td>'+escapeHTML(x.code)+'</td><td><span class="table-primary">'+escapeHTML(x.keyword)+'</span><span class="table-secondary">'+escapeHTML(x.language+' · '+x.matchType)+'</span></td><td>'+escapeHTML(x.category)+'</td><td>'+x.risk+'</td><td>'+escapeHTML(x.warning)+'</td><td>'+makeBadge(x.active?'Active':'Inactive')+'</td></tr>').join('')||emptyRow(6,'No database safety rules','The local multilingual rule file remains active. Database rules can be added here.');}getElement('safetyRuleForm').addEventListener('submit',async e=>{e.preventDefault();try{const keyword=getElement('ruleKeyword').value.trim();await apiRequest('/system-admin/safety-rules',{method:'POST',body:{code:getElement('ruleCode').value.trim(),keyword:keyword,category_id:getElement('ruleCategory').value||null,score:getElement('ruleScore').value,warning:getElement('ruleWarning').value.trim(),language:getElement('ruleLanguage').value,severity:getElement('ruleSeverity').value,match_type:'Phrase'}});e.currentTarget.reset();showMessage('Safety rule added.','success');await draw();}catch(err){showMessage(err.message,'error');}});try{await draw();}catch(e){showMessage(e.message,'error');}}

    async function renderSettings(){
        if(!getElement('systemSettingsPage'))return;
        try{
            const r=await apiRequest('/system-admin/settings'),s=r.data.settings||{};
            function val(key,fallback){return s[key] && s[key].value !== undefined ? s[key].value : fallback;}
            getElement('settingSystemName').value=val('system_name','HelaFixIt AI');
            getElement('settingApartmentName').value=val('apartment_name','');
            getElement('settingEmergencyThreshold').value=Number(val('emergency_risk_threshold',86));
            getElement('settingDuplicateThreshold').value=Math.round(Number(val('duplicate_similarity_threshold',0.72))*100);
            getElement('settingConfidenceThreshold').value=Math.round(Number(val('low_confidence_threshold',0.65))*100);
            getElement('settingMaxUpload').value=Number(val('max_upload_mb',5));
            getElement('settingAllowedImages').value=val('allowed_image_types','jpg,jpeg,png,webp');
            getElement('settingDefaultLanguage').value=val('default_language','English');
            getElement('settingTechnicianMaxJobs').value=Number(val('technician_default_max_jobs',4));
            getElement('settingNotificationRetention').value=Number(val('notification_retention_days',90));
            getElement('setting_autoEmergencyAssignment').checked=!!val('auto_emergency_assignment',true);
            getElement('setting_emailAlerts').checked=!!val('email_alerts',false);
            getElement('setting_smsAlerts').checked=!!val('sms_alerts',false);
            getElement('setting_browserAlerts').checked=!!val('browser_alerts',true);
            getElement('setting_allowRegistration').checked=!!val('allow_registration',true);
            getElement('setting_maintenanceMode').checked=!!val('maintenance_mode',false);

            const form=getElement('systemSettingsForm');
            if(form.dataset.bound)return;
            form.dataset.bound='1';
            form.addEventListener('submit',async e=>{
                e.preventDefault();
                const duplicatePercent=Number(getElement('settingDuplicateThreshold').value);
                const confidencePercent=Number(getElement('settingConfidenceThreshold').value);
                const emergency=Number(getElement('settingEmergencyThreshold').value);
                const maxUpload=Number(getElement('settingMaxUpload').value);
                const techMax=Number(getElement('settingTechnicianMaxJobs').value);
                const retention=Number(getElement('settingNotificationRetention').value);
                if(emergency<0||emergency>100||duplicatePercent<0||duplicatePercent>100||confidencePercent<0||confidencePercent>100||maxUpload<1||maxUpload>20||techMax<1||techMax>20||retention<7||retention>365){
                    showMessage('Check the numeric setting limits before saving.','error');return;
                }
                try{
                    await apiRequest('/system-admin/settings',{method:'PUT',body:{
                        system_name:getElement('settingSystemName').value.trim(),
                        apartment_name:getElement('settingApartmentName').value.trim(),
                        emergency_risk_threshold:emergency,
                        duplicate_similarity_threshold:duplicatePercent/100,
                        low_confidence_threshold:confidencePercent/100,
                        max_upload_mb:maxUpload,
                        allowed_image_types:getElement('settingAllowedImages').value.trim(),
                        default_language:getElement('settingDefaultLanguage').value,
                        technician_default_max_jobs:techMax,
                        notification_retention_days:retention,
                        auto_emergency_assignment:getElement('setting_autoEmergencyAssignment').checked,
                        email_alerts:getElement('setting_emailAlerts').checked,
                        sms_alerts:getElement('setting_smsAlerts').checked,
                        browser_alerts:getElement('setting_browserAlerts').checked,
                        allow_registration:getElement('setting_allowRegistration').checked,
                        registration_requires_approval:true,
                        maintenance_mode:getElement('setting_maintenanceMode').checked
                    }});
                    showMessage('System settings updated. New tickets and new staff accounts will use the saved values.','success');
                }catch(err){showMessage(err.message,'error');}
            });
        }catch(e){showMessage(e.message,'error');}
    }

    async function renderAudit(){
        const body=getElement('auditRows');if(!body)return;
        const state={page:1,pages:1,loading:false,filtersReady:false};
        const el=id=>getElement(id);
        function value(id){const node=el(id);return node?String(node.value||'').trim():'';}
        function actionLabel(code){return String(code||'').toLowerCase().split('_').filter(Boolean).map(w=>w.charAt(0).toUpperCase()+w.slice(1)).join(' ');}
        function optionHTML(items,current,first){return '<option value="">'+escapeHTML(first)+'</option>'+(items||[]).map(x=>'<option value="'+escapeHTML(x)+'"'+(String(x)===String(current)?' selected':'')+'>'+escapeHTML(actionLabel(x))+'</option>').join('');}
        function changeDetails(log){
            const oldValue=String(log.oldValue||''),newValue=String(log.newValue||'');
            if(!oldValue&&!newValue)return '';
            let html='<details class="audit-change-details"><summary>View recorded changes</summary><div class="audit-change-grid">';
            if(oldValue)html+='<div class="audit-change-box"><strong>Before</strong>\n'+escapeHTML(oldValue)+'</div>';
            if(newValue)html+='<div class="audit-change-box"><strong>After</strong>\n'+escapeHTML(newValue)+'</div>';
            return html+'</div></details>';
        }
        function buildQuery(){
            const p=new URLSearchParams();
            [['search',value('auditSearch')],['action',value('auditActionFilter')],['entity',value('auditEntityFilter')],['user',value('auditUserFilter')],['date_from',value('auditDateFrom')],['date_to',value('auditDateTo')]].forEach(([k,v])=>{if(v)p.set(k,v);});
            p.set('page',String(state.page));p.set('per_page',value('auditPageSize')||'25');
            return p.toString();
        }
        async function draw(resetPage){
            if(state.loading)return;
            if(resetPage)state.page=1;
            state.loading=true;
            if(el('auditLoading'))el('auditLoading').style.display='block';
            try{
                const r=await apiRequest('/system-admin/audit-logs?'+buildQuery()),d=r.data||{};
                state.page=Number(d.page||1);state.pages=Math.max(1,Number(d.pages||1));
                if(!state.filtersReady){
                    const action=el('auditActionFilter'),entity=el('auditEntityFilter');
                    if(action)action.innerHTML=optionHTML(d.actions,value('auditActionFilter'),'All actions');
                    if(entity){
                        const current=value('auditEntityFilter');
                        entity.innerHTML='<option value="">All modules</option>'+(d.entities||[]).map(x=>'<option value="'+escapeHTML(x)+'"'+(String(x)===String(current)?' selected':'')+'>'+escapeHTML(x)+'</option>').join('');
                    }
                    state.filtersReady=true;
                }
                if(el('auditTotalRecords'))el('auditTotalRecords').textContent=String(d.total||0);
                if(el('auditFilteredRecords'))el('auditFilteredRecords').textContent=String(d.filtered||0);
                if(el('auditCurrentPage'))el('auditCurrentPage').textContent=state.page+' of '+state.pages;
                if(el('auditPageStatus'))el('auditPageStatus').textContent='Page '+state.page+' of '+state.pages;
                if(el('auditPreviousPage'))el('auditPreviousPage').disabled=state.page<=1;
                if(el('auditNextPage'))el('auditNextPage').disabled=state.page>=state.pages;
                body.innerHTML=(d.logs||[]).map(l=>{
                    const user='<span class="table-primary">'+escapeHTML(l.user||'System')+'</span>'+(l.email?'<span class="audit-user-email">'+escapeHTML(l.email)+'</span>':'');
                    const action='<span class="audit-action-name">'+escapeHTML(actionLabel(l.action))+'</span><span class="audit-action-code">'+escapeHTML(l.action||'')+'</span>';
                    const target='<span class="table-primary">'+escapeHTML(l.entity||'-')+'</span>'+(l.entityId?'<span class="audit-meta">ID '+escapeHTML(l.entityId)+'</span>':'');
                    const detail='<div class="audit-detail-text">'+escapeHTML(l.detail||'Recorded system action')+changeDetails(l)+'</div>'+(l.userAgent?'<span class="audit-meta" title="'+escapeHTML(l.userAgent)+'">Browser information recorded</span>':'');
                    return '<tr><td>'+formatDate(l.time)+'</td><td>'+user+'</td><td>'+action+'</td><td>'+target+'</td><td>'+escapeHTML(l.ipAddress||'-')+'</td><td>'+detail+'</td></tr>';
                }).join('')||emptyRow(6,'No audit records','No records match the selected filters.');
            }catch(e){
                body.innerHTML=emptyRow(6,'Audit logs could not be loaded',e.message||'Please try again.');
                showMessage(e.message,'error');
            }finally{state.loading=false;if(el('auditLoading'))el('auditLoading').style.display='none';}
        }
        let timer=null;
        function debouncedDraw(){clearTimeout(timer);timer=setTimeout(()=>draw(true),280);}
        ['auditSearch','auditUserFilter'].forEach(id=>{const node=el(id);if(node)node.addEventListener('input',debouncedDraw);});
        ['auditActionFilter','auditEntityFilter','auditDateFrom','auditDateTo','auditPageSize'].forEach(id=>{const node=el(id);if(node)node.addEventListener('change',()=>draw(true));});
        if(el('auditRefreshButton'))el('auditRefreshButton').addEventListener('click',()=>draw(false));
        if(el('auditResetFilters'))el('auditResetFilters').addEventListener('click',()=>{['auditSearch','auditActionFilter','auditEntityFilter','auditUserFilter','auditDateFrom','auditDateTo'].forEach(id=>{const node=el(id);if(node)node.value='';});state.page=1;draw(true);});
        if(el('auditPreviousPage'))el('auditPreviousPage').addEventListener('click',()=>{if(state.page>1){state.page--;draw(false);}});
        if(el('auditNextPage'))el('auditNextPage').addEventListener('click',()=>{if(state.page<state.pages){state.page++;draw(false);}});
        await draw(true);
    }

    async function renderBackup(){if(!getElement('backupPage'))return;try{const r=await apiRequest('/system-admin/dashboard');setText('backupRecords',r.data.stats.users+' users');setText('backupLastTime','Ready');}catch(e){}const b=getElement('downloadBackup');if(b)b.addEventListener('click',async function(){try{const data=await apiRequest('/system-admin/backup/export');const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='helafixit_data_export.json';a.click();URL.revokeObjectURL(a.href);showMessage('Database data export downloaded.','success');}catch(e){showMessage(e.message,'error');}});}

    async function renderNotifications(){
        const root=getElement('systemAdminNotificationList');if(!root)return;
        async function draw(){
            try{
                const r=await apiRequest('/system-admin/notifications');
                root.innerHTML=(r.data.notifications||[]).map(n=>'<div class="notification-item '+(!n.read?'unread':'')+'"><div class="notification-symbol">'+(/emergency/i.test((n.type||'')+(n.title||''))?'!':'i')+'</div><div><h4>'+escapeHTML(n.title)+'</h4><p>'+escapeHTML(n.text)+'</p><time>'+formatDate(n.time)+'</time></div></div>').join('')||'<div class="empty-state"><h3>No notifications</h3><p>System and account notifications will appear here.</p></div>';
                if(window.refreshNotificationButton)window.refreshNotificationButton();
            }catch(e){showMessage(e.message,'error');}
        }
        const btn=getElement('markSystemAdminRead');if(btn&&!btn.dataset.bound){btn.dataset.bound='1';btn.addEventListener('click',async()=>{try{await apiRequest('/system-admin/notifications/read-all',{method:'POST'});showMessage('Notifications marked as read.','success');await draw();}catch(e){showMessage(e.message,'error');}});}
        await draw();
    }


    async function renderSystemAdminProfile(){
        if(!getElement('systemAdminProfile'))return;
        try{
            const r=await apiRequest('/system-admin/profile'),p=r.data.profile||{};
            getElement('sysProfileName').value=p.name||'';
            getElement('sysProfileEmail').value=p.email||'';
            getElement('sysProfilePhone').value=p.phone||'';
            setText('sysProfileDisplayName',p.name||'System Admin');
            setText('sysProfileDisplayEmail',p.email||'');
            setText('sysProfileInitial',(p.name||'S').charAt(0).toUpperCase());
            setText('sysProfileLastLogin',formatDate(p.lastLogin));
            const status=getElement('sysProfileStatus');
            if(status){status.textContent=p.status||'Active';status.className='badge '+((p.status||'Active')==='Active'?'badge-active':'badge-warning');}
            const form=getElement('systemAdminProfileForm');
            if(form&&!form.dataset.bound){
                form.dataset.bound='1';
                form.addEventListener('submit',async function(event){
                    event.preventDefault();
                    if(!validateRequired(form))return;
                    try{
                        const phone=normalizeSriLankanMobile(getElement('sysProfilePhone').value);
                        await apiRequest('/system-admin/profile',{method:'PUT',body:{name:getElement('sysProfileName').value.trim(),phone:phone}});
                        const me=await apiRequest('/auth/me');setAuthSession(getAuthToken(),me.data.user);
                        showMessage('System Admin profile updated.','success');
                        await renderSystemAdminProfile();
                    }catch(e){showMessage(e.message||'Profile could not be updated.','error');}
                });
            }
        }catch(e){showMessage(e.message||'System Admin profile could not be loaded.','error');}
    }

    async function renderRegistrations(){const body=getElement('registrationRequestRows');if(!body)return;async function draw(){try{const status=getElement('registrationStatusFilter').value,r=await apiRequest('/system-admin/registration-requests?status='+encodeURIComponent(status));body.innerHTML=r.data.requests.map(x=>'<tr><td><span class="table-primary">'+escapeHTML(x.fullName)+'</span><span class="table-secondary">'+escapeHTML(x.email)+'</span></td><td>'+escapeHTML(x.phone)+'</td><td>'+escapeHTML(x.block+' · '+x.floor+(x.unitNumber?' · '+x.unitNumber:''))+'</td><td>'+escapeHTML(x.residentType)+'</td><td>'+formatDate(x.requestedAt)+'</td><td>'+makeBadge(x.status)+'</td><td>'+(x.status==='Pending'?'<button class="btn-app btn-success btn-sm" data-approve="'+x.id+'">Approve</button> <button class="btn-app btn-danger btn-sm" data-reject="'+x.id+'">Reject</button>':'Reviewed')+'</td></tr>').join('')||emptyRow(7,'No registration requests','Resident registration requests will appear here.');body.querySelectorAll('[data-approve],[data-reject]').forEach(btn=>btn.addEventListener('click',async()=>{const action=btn.dataset.approve?'approve':'reject',id=btn.dataset.approve||btn.dataset.reject,note=prompt('Optional review note')||'';try{await apiRequest('/system-admin/registration-requests/'+id+'/review',{method:'POST',body:{action:action,note:note}});showMessage('Registration request '+(action==='approve'?'approved':'rejected')+'.','success');await draw();}catch(e){showMessage(e.message,'error');}}));}catch(e){showMessage(e.message,'error');}}getElement('registrationStatusFilter').addEventListener('change',draw);draw();}

    document.addEventListener('DOMContentLoaded',function(){if(!currentUser())return;renderDashboard();renderRoles();renderSkills();renderCategories();renderBuildings();renderAreas();renderRules();renderSettings();renderAudit();renderBackup();renderRegistrations();renderNotifications();renderSystemAdminProfile();});
})();
