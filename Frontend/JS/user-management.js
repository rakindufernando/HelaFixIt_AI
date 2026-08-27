/* HelaFixIt AI System Admin User Management
   Dedicated page controller so user actions do not depend on other System Admin modules. */
(function(){
    'use strict';

    const state={options:null,currentDetails:null,loading:false};
    const el=id=>document.getElementById(id);

    function emptyRow(cols,title,text){
        return '<tr><td colspan="'+cols+'"><div class="empty-state"><h3>'+escapeHTML(title)+'</h3><p>'+escapeHTML(text)+'</p></div></td></tr>';
    }

    function setFormStatus(message,type){
        const box=el('userFormStatus');
        if(!box)return;
        if(!message){box.hidden=true;box.textContent='';box.className='user-form-status';return;}
        box.hidden=false;
        box.textContent=message;
        box.className='user-form-status '+(type||'info');
    }

    function setButtonBusy(button,busy,busyText){
        if(!button)return;
        if(busy){
            if(!button.dataset.originalText)button.dataset.originalText=button.textContent;
            button.disabled=true;button.textContent=busyText||'Please wait...';
        }else{
            button.disabled=false;button.textContent=button.dataset.originalText||button.textContent;
        }
    }

    async function getOptions(force){
        if(state.options&&!force)return state.options;
        const response=await apiRequest('/system-admin/user-options');
        state.options=response.data||{};
        return state.options;
    }

    function fillSelect(id,items,placeholder,labeler){
        const node=el(id);if(!node)return;
        const current=String(node.value||'');
        node.innerHTML='<option value="">'+escapeHTML(placeholder)+'</option>'+(items||[]).map(item=>'<option value="'+item.id+'">'+escapeHTML(labeler(item))+'</option>').join('');
        if(current&&[...node.options].some(o=>o.value===current))node.value=current;
    }

    function fillOptions(){
        const opts=state.options||{};
        ['editResidentBuilding','editAdminBuilding','editTechBuilding'].forEach(id=>fillSelect(id,opts.buildings||[],'Select building',b=>(b.code||'')+' - '+(b.name||'')));
        fillSelect('editUserSkill',opts.skills||[],'Select skill',s=>s.name||'');
        const password=String(opts.defaultStaffPassword||'helafixit@321');
        if(el('defaultStaffPassword'))el('defaultStaffPassword').textContent=password;
    }

    function populateResidentFloors(buildingId,selected){
        const node=el('editResidentFloor');if(!node)return;
        const bid=Number(buildingId||0),floors=(state.options&&state.options.floors)||[];
        node.innerHTML='<option value="">Select floor</option>'+floors.filter(f=>Number(f.buildingId)===bid).map(f=>'<option value="'+f.id+'">'+escapeHTML(f.name)+'</option>').join('');
        if(selected)node.value=String(selected);
    }

    function setRoleFields(role,isNew){
        const sections={resident:'residentUserFields',admin:'adminUserFields',technician:'technicianUserFields'};
        Object.values(sections).forEach(id=>{const n=el(id);if(n)n.style.display='none';});
        const roleInputs={
            resident:['editResidentBuilding','editResidentFloor','editResidentUnit','editResidentType','editResidentLanguage'],
            admin:['editAdminBuilding','editAdminJobTitle','editCanReviewEmergencies'],
            technician:['editTechBuilding','editUserSkill','editEmployeeCode','editAvailability','editMaxJobs','editEmergencyEligible']
        };
        Object.values(roleInputs).flat().forEach(id=>{const n=el(id);if(n)n.disabled=true;});
        if(sections[role]){const n=el(sections[role]);if(n)n.style.display='block';(roleInputs[role]||[]).forEach(id=>{const f=el(id);if(f)f.disabled=false;});}
        const create=el('createOnlyFields');if(create)create.style.display=isNew?'block':'none';
    }

    function accountInfo(details){
        const box=el('userAccountInfo');if(!box)return;
        if(!details){box.style.display='none';box.innerHTML='';return;}
        box.style.display='grid';
        box.innerHTML='<strong>Account information</strong>'+
            '<span>User ID '+escapeHTML(details.displayId||'')+' · Created '+escapeHTML(formatDate(details.created))+' · Last login '+escapeHTML(formatDate(details.lastLogin))+'</span>'+
            '<span>Last password change '+escapeHTML(formatDate(details.lastPasswordChange))+(details.lockedUntil?' · Locked until '+escapeHTML(formatDate(details.lockedUntil)):'')+'</span>';
    }

    function firstInvalidField(form){
        return [...form.querySelectorAll('input,select,textarea')].find(field=>{
            if(field.disabled||field.type==='hidden'||field.type==='button'||field.type==='submit')return false;
            return !validateFieldFormat(field);
        })||null;
    }

    function validateUserForm(){
        const form=el('userEditForm');
        let valid=true,first=null;
        [...form.querySelectorAll('input,select,textarea')].forEach(field=>{
            if(field.disabled||field.type==='hidden'||field.type==='button'||field.type==='submit')return;
            if(!validateFieldFormat(field)){valid=false;if(!first)first=field;}
        });
        const isNew=el('editUserId').value==='NEW';
        const role=isNew?el('editUserRole').value:(state.currentDetails&&state.currentDetails.role);
        function requireValue(id,message){const n=el(id);if(!n||n.disabled)return; if(!String(n.value||'').trim()){valid=false;fieldErrorCompat(n,message);if(!first)first=n;}}
        if(role==='admin')requireValue('editAdminBuilding','Select the assigned building.');
        if(role==='technician'){
            requireValue('editTechBuilding','Select the assigned building.');
            requireValue('editUserSkill','Select the primary skill.');
            requireValue('editEmployeeCode','Enter the technician employee code.');
        }
        if(role==='resident'){
            requireValue('editResidentBuilding','Select the resident building.');
            requireValue('editResidentFloor','Select the resident floor.');
        }
        const email=String(el('editUserEmail').value||'').trim().toLowerCase();
        if(role!=='resident' && !email.endsWith('@helafixit.lk')){
            valid=false;fieldErrorCompat(el('editUserEmail'),'Staff email addresses must end with @helafixit.lk.');if(!first)first=el('editUserEmail');
        }
        if(!valid&&first){
            const scroller=el('userFormScroll');
            if(scroller){const top=first.getBoundingClientRect().top-scroller.getBoundingClientRect().top+scroller.scrollTop-80;scroller.scrollTo({top:Math.max(0,top),behavior:'smooth'});}
            setTimeout(()=>first.focus({preventScroll:true}),250);
            setFormStatus('Please correct the highlighted field before saving.','error');
        }
        return valid;
    }

    function fieldErrorCompat(field,message){
        if(!field)return;
        if(typeof window.clearFieldError==='function')window.clearFieldError(field);
        field.style.borderColor='#e5484d';
        const parent=field.closest('.field');
        if(parent){const old=parent.querySelector('.field-error');if(old)old.remove();const small=document.createElement('small');small.className='field-error';small.style.color='#b42318';small.textContent=message;parent.appendChild(small);}
    }

    function buildPayload(){
        const phone=normalizeSriLankanMobile(el('editUserPhone').value);
        const base={
            name:el('editUserName').value.trim(),
            email:el('editUserEmail').value.trim().toLowerCase(),
            phone:phone,
            status:el('editUserStatus').value,
            email_verified:el('editEmailVerified').checked
        };
        const isNew=el('editUserId').value==='NEW';
        const role=isNew?el('editUserRole').value:state.currentDetails.role;
        if(isNew)base.role=role;
        if(role==='resident')Object.assign(base,{building_id:el('editResidentBuilding').value,floor_id:el('editResidentFloor').value,unit_number:el('editResidentUnit').value.trim(),resident_type:el('editResidentType').value,preferred_language:el('editResidentLanguage').value});
        if(role==='admin')Object.assign(base,{building_id:el('editAdminBuilding').value,job_title:el('editAdminJobTitle').value.trim(),can_review_emergencies:el('editCanReviewEmergencies').checked});
        if(role==='technician')Object.assign(base,{building_id:el('editTechBuilding').value,skill_id:el('editUserSkill').value,employee_code:el('editEmployeeCode').value.trim().toUpperCase(),availability:el('editAvailability').value,max_jobs:Number(el('editMaxJobs').value),emergency_eligible:el('editEmergencyEligible').checked});
        return base;
    }

    function resetCreateForm(){
        const form=el('userEditForm');form.reset();state.currentDetails=null;
        el('editUserId').value='NEW';el('editUserStatus').value='Active';el('editEmailVerified').checked=true;
        el('editUserRole').disabled=false;el('editUserRole').value='admin';
        if(el('editMaxJobs'))el('editMaxJobs').value=(state.options&&state.options.defaultTechnicianMaxJobs)||4;
        if(el('editAvailability'))el('editAvailability').value='Available';
        if(el('editAdminJobTitle'))el('editAdminJobTitle').value='Apartment Administrator';
        el('userModalTitle').textContent='Add staff user';
        el('userModalSubtitle').textContent='Create an Apartment Admin, Technician or System Admin account';
        fillOptions();setRoleFields('admin',true);accountInfo(null);setFormStatus('', '');
        const scroller=el('userFormScroll');if(scroller)scroller.scrollTop=0;
    }

    async function loadUsers(){
        const body=el('userRows');if(!body||state.loading)return;
        state.loading=true;body.innerHTML=emptyRow(7,'Loading users','Reading current accounts from the database.');
        try{
            const params=new URLSearchParams({
                search:el('userSearch').value.trim(),role:el('userRoleFilter').value,status:el('userStatusFilter').value,deleted:el('userDeletedFilter').value
            });
            const response=await apiRequest('/system-admin/users?'+params.toString());
            const users=(response.data&&response.data.users)||[];
            const current=currentUser()||{};
            body.innerHTML=users.map(u=>{
                let actions='<button type="button" class="btn-app btn-secondary btn-sm" data-action="edit" data-id="'+u.id+'">Edit</button>';
                if(u.deleted){actions+=' <button type="button" class="btn-app btn-success btn-sm" data-action="restore" data-id="'+u.id+'">Restore</button>';}
                else{
                    if(Number(current.dbId)!==Number(u.id))actions+=' <button type="button" class="btn-app btn-secondary btn-sm" data-action="password" data-id="'+u.id+'" data-name="'+escapeHTML(u.name)+'">Password</button>';
                    if(u.status==='Locked'||u.lockedUntil)actions+=' <button type="button" class="btn-app btn-secondary btn-sm" data-action="unlock" data-id="'+u.id+'">Unlock</button>';
                    if(Number(current.dbId)!==Number(u.id))actions+=' <button type="button" class="btn-app btn-danger btn-sm" data-action="delete" data-id="'+u.id+'" data-name="'+escapeHTML(u.name)+'">Delete</button>';
                }
                return '<tr><td><span class="table-primary">'+escapeHTML(u.name)+'</span><span class="table-secondary">'+escapeHTML(u.displayId)+(u.mustChangePassword?' · Password change required':'')+'</span></td><td><span class="table-primary">'+escapeHTML(u.email)+'</span><span class="table-secondary">'+escapeHTML(u.phone||'-')+'</span></td><td>'+escapeHTML(u.roleName)+'</td><td>'+escapeHTML(u.block||'-')+'</td><td>'+makeBadge(u.status)+(u.emailVerified?' <span class="table-secondary">Email verified</span>':'')+'</td><td>'+formatDate(u.lastLogin)+'</td><td class="user-action-cell">'+actions+'</td></tr>';
            }).join('')||emptyRow(7,'No users found','No accounts match the selected filters.');
        }catch(error){body.innerHTML=emptyRow(7,'Users could not be loaded',error.message||'Please try again.');showMessage(error.message,'error');}
        finally{state.loading=false;}
    }

    async function openEdit(userId){
        setFormStatus('Loading account details...','info');
        try{
            const response=await apiRequest('/system-admin/users/'+userId),d=response.data.user;state.currentDetails=d;
            fillOptions();
            el('editUserId').value=String(userId);el('editUserName').value=d.name||'';el('editUserEmail').value=d.email||'';el('editUserPhone').value=d.phone||'';el('editUserStatus').value=d.accountStatus||'Active';el('editEmailVerified').checked=!!d.emailVerified;
            el('editUserRole').value=d.role;el('editUserRole').disabled=true;setRoleFields(d.role,false);
            el('userModalTitle').textContent='Edit '+d.name;el('userModalSubtitle').textContent=(d.roleName||'User')+' · '+(d.displayId||'');
            if(d.resident){el('editResidentBuilding').value=d.resident.buildingId||'';populateResidentFloors(d.resident.buildingId,d.resident.floorId);el('editResidentUnit').value=d.resident.unitNumber||'';el('editResidentType').value=d.resident.residentType||'Other';el('editResidentLanguage').value=d.resident.preferredLanguage||'English';}
            if(d.admin){el('editAdminBuilding').value=d.admin.buildingId||'';el('editAdminJobTitle').value=d.admin.jobTitle||'Apartment Administrator';el('editCanReviewEmergencies').checked=!!d.admin.canReviewEmergencies;}
            if(d.technician){el('editTechBuilding').value=d.technician.buildingId||'';el('editUserSkill').value=d.technician.skillId||'';el('editEmployeeCode').value=d.technician.employeeCode||'';el('editAvailability').value=d.technician.availability||'Off Duty';el('editMaxJobs').value=d.technician.maxJobs||4;el('editEmergencyEligible').checked=!!d.technician.emergencyEligible;}
            accountInfo(d);setFormStatus('', '');openModal('userModal');const scroller=el('userFormScroll');if(scroller)scroller.scrollTop=0;
        }catch(error){setFormStatus(error.message||'Account details could not be loaded.','error');showMessage(error.message,'error');}
    }

    async function saveUser(event){
        event.preventDefault();
        if(!validateUserForm())return;
        const button=el('saveUserButton');setButtonBusy(button,true,el('editUserId').value==='NEW'?'Creating...':'Saving...');setFormStatus('Saving account information...','info');
        try{
            const id=el('editUserId').value,payload=buildPayload();
            if(id==='NEW'){
                const result=await apiRequest('/system-admin/users',{method:'POST',body:payload});
                const password=(result.data&&result.data.temporaryPassword)||(state.options&&state.options.defaultStaffPassword)||'helafixit@321';
                closeModal('userModal');showMessage('Staff account created. Initial password: '+password,'success');
            }else{
                await apiRequest('/system-admin/users/'+id,{method:'PUT',body:payload});closeModal('userModal');showMessage('User account updated.','success');
            }
            await loadUsers();
        }catch(error){
            setFormStatus(error.message||'The account could not be saved.','error');showMessage(error.message||'The account could not be saved.','error');
        }finally{setButtonBusy(button,false);}
    }

    function openPasswordReset(id,name){
        el('resetUserId').value=String(id);el('adminResetPasswordForm').reset();el('resetPasswordUserLabel').textContent=name||('User '+id);
        const defaultPassword=(state.options&&state.options.defaultStaffPassword)||'helafixit@321';el('adminTemporaryPassword').value=defaultPassword;el('adminTemporaryPasswordConfirm').value=defaultPassword;openModal('passwordResetModal');
    }

    async function resetPassword(event){
        event.preventDefault();const form=event.currentTarget;if(!validateRequired(form))return;
        const a=el('adminTemporaryPassword').value,b=el('adminTemporaryPasswordConfirm').value;if(a!==b){showMessage('Temporary passwords do not match.','error');return;}
        const button=el('resetPasswordButton');setButtonBusy(button,true,'Resetting...');
        try{await apiRequest('/system-admin/users/'+el('resetUserId').value+'/reset-password',{method:'POST',body:{temporary_password:a}});closeModal('passwordResetModal');showMessage('Temporary password updated. The user must change it at next sign in.','success');await loadUsers();}
        catch(error){showMessage(error.message,'error');}
        finally{setButtonBusy(button,false);}
    }

    async function handleTableAction(event){
        const button=event.target.closest('button[data-action]');if(!button)return;
        const id=Number(button.dataset.id),action=button.dataset.action,name=button.dataset.name||'this user';
        if(!id)return;
        try{
            if(action==='edit')return openEdit(id);
            if(action==='password')return openPasswordReset(id,name);
            if(action==='unlock'){setButtonBusy(button,true,'Unlocking...');await apiRequest('/system-admin/users/'+id+'/unlock',{method:'POST'});showMessage('Account unlocked.','success');}
            if(action==='delete'){
                if(!confirm('Delete the account for '+name+'? The account will lose access while maintenance history is retained.'))return;
                setButtonBusy(button,true,'Deleting...');await apiRequest('/system-admin/users/'+id,{method:'DELETE'});showMessage('User account deleted.','success');
            }
            if(action==='restore'){
                if(!confirm('Restore this user account?'))return;
                setButtonBusy(button,true,'Restoring...');await apiRequest('/system-admin/users/'+id+'/restore',{method:'POST'});showMessage('User account restored.','success');
            }
            await loadUsers();
        }catch(error){showMessage(error.message||'The user action could not be completed.','error');}
        finally{setButtonBusy(button,false);}
    }

    async function init(){
        if(!el('userRows'))return;
        try{
            await getOptions();fillOptions();
            el('addUserButton').addEventListener('click',()=>{resetCreateForm();openModal('userModal');});
            el('editUserRole').addEventListener('change',e=>setRoleFields(e.target.value,true));
            el('editResidentBuilding').addEventListener('change',e=>populateResidentFloors(e.target.value,''));
            el('userEditForm').addEventListener('submit',saveUser);
            el('adminResetPasswordForm').addEventListener('submit',resetPassword);
            el('userRows').addEventListener('click',handleTableAction);
            const copy=el('copyDefaultPassword');if(copy)copy.addEventListener('click',async()=>{const password=(state.options&&state.options.defaultStaffPassword)||'helafixit@321';try{await navigator.clipboard.writeText(password);showMessage('Initial password copied.','success');}catch(_){showMessage('Initial password: '+password,'info');}});
            ['userRoleFilter','userStatusFilter','userDeletedFilter'].forEach(id=>el(id).addEventListener('change',loadUsers));
            let timer=null;el('userSearch').addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(loadUsers,250);});
            await loadUsers();
        }catch(error){showMessage(error.message||'User Management could not be initialized.','error');}
    }

    document.addEventListener('DOMContentLoaded',()=>{if(typeof currentUser==='function'&&currentUser())init();});
})();
