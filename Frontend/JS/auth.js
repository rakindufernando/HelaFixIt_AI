/* Authentication and resident registration connected to the Flask API and MySQL database. */
(function () {
    const routes = {
        resident:'../Resident pages/resident-dashboard.html',
        admin:'../Apartment Admin pages/admin-dashboard.html',
        technician:'../Technician pages/technician-dashboard.html',
        systemAdmin:'../System Admin pages/system-admin-dashboard.html'
    };

    function roleName(role) {
        return {resident:'Resident', admin:'Apartment Admin', technician:'Technician', systemAdmin:'System Admin'}[role] || role;
    }
    window.roleName = roleName;

    function redirectToLogin() {
        clearAuthSession();
        const body = document.body;
        location.href = body.dataset.loginPath || '../Public pages/login.html';
    }

    function applyUserToPage(user) {
        if (!user) return;
        document.querySelectorAll('[data-user-name]').forEach(function(el){ el.textContent = user.name; });
        document.querySelectorAll('[data-user-role]').forEach(function(el){ el.textContent = roleName(user.role); });
        document.querySelectorAll('[data-user-initial]').forEach(function(el){ el.textContent = (user.name || 'U').charAt(0).toUpperCase(); });
    }

    async function protectPage() {
        const body = document.body;
        const allowed = body.dataset.allowedRole;
        if (!allowed) return;
        const token = getAuthToken();
        const localUser = currentUser();
        if (!token || !localUser) { redirectToLogin(); return; }
        const accepted = allowed.split(',').map(function(v){ return v.trim(); });
        if (accepted.indexOf(localUser.role) === -1) {
            location.href = body.dataset.unauthorizedPath || '../Public pages/unauthorized.html';
            return;
        }
        applyUserToPage(localUser);
        try {
            const response = await apiRequest('/auth/me');
            const user = response.data.user;
            setAuthSession(token, user);
            if (accepted.indexOf(user.role) === -1) {
                location.href = body.dataset.unauthorizedPath || '../Public pages/unauthorized.html';
                return;
            }
            applyUserToPage(user);
            if (user.mustChangePassword) { location.href = '../Public pages/change-password.html'; return; }
        } catch (error) { if (error && error.maintenanceMode) return; redirectToLogin(); }
    }

    async function performLogin(email, password, role, button) {
        if (button) button.disabled = true;
        try {
            const response = await apiRequest('/auth/login', {method:'POST', body:{email:email,password:password,role:role}});
            setAuthSession(response.data.access_token, response.data.user);
            if (response.data.must_change_password || response.data.user.mustChangePassword) {
                showMessage('Change the temporary password to continue.', 'info');
                setTimeout(function(){ location.href = 'change-password.html'; }, 250);
            } else {
                showMessage('Login successful.', 'success');
                setTimeout(function(){ location.href = routes[response.data.user.role]; }, 300);
            }
        } catch (error) { if (error && error.maintenanceMode) return; showMessage(error.message, 'error'); }
        finally { if (button) button.disabled = false; }
    }

    window.logout = async function () {
        try { if (getAuthToken()) await apiRequest('/auth/logout', {method:'POST'}); } catch (error) {}
        clearAuthSession();
        location.href = document.body.dataset.loginPath || '../Public pages/login.html';
    };

    function initLogin() {
        const form = getElement('loginForm');
        if (!form) return;
        form.addEventListener('submit', function(e){
            e.preventDefault();
            if (!validateRequired(form)) return;
            performLogin(getElement('loginEmail').value.trim(), getElement('loginPassword').value, getElement('loginRole').value, form.querySelector('button[type="submit"]'));
        });
    }

    async function loadRegistrationOptions() {
        const blockSelect = getElement('registerBlock');
        const floorSelect = getElement('registerFloor');
        if (!blockSelect || !floorSelect) return;
        function fillFloors(buildings, blockCode) {
            const building = buildings.find(function(item){ return item.block_code === blockCode; });
            floorSelect.innerHTML = '<option value="">Select floor</option>';
            if (!building) return;
            building.floors.forEach(function(floor){
                const option = document.createElement('option');
                option.value = floor.floor_number;
                option.textContent = floor.name || ('Floor ' + floor.floor_number);
                floorSelect.appendChild(option);
            });
        }
        try {
            const response = await apiRequest('/auth/registration-options');
            const buildings = response.data.buildings || [];
            const language = getElement('registerLanguage');
            if (language && response.data.defaultLanguage) language.value = response.data.defaultLanguage;
            const submitButton = getElement('registerForm') ? getElement('registerForm').querySelector('button[type="submit"]') : null;
            if (submitButton && response.data.registrationEnabled === false) {
                submitButton.disabled = true;
                submitButton.textContent = 'Registration unavailable';
                showMessage('Resident registration is currently disabled by the System Admin.', 'info');
            }
            blockSelect.innerHTML = '<option value="">Select block</option>';
            buildings.forEach(function(building){
                const option = document.createElement('option');
                option.value = building.block_code;
                option.textContent = building.block_code + ' - ' + building.name;
                blockSelect.appendChild(option);
            });
            if (!buildings.length) showMessage('Apartment buildings must be configured by the System Admin before resident registration.', 'error');
            blockSelect.addEventListener('change', function(){ fillFloors(buildings, blockSelect.value); });
        } catch (error) { showMessage(error.message || 'Registration locations could not be loaded.', 'error'); }
    }

    async function checkRegistrationStatus(email) {
        if (!email || !isEmail(email)) { showMessage('Enter a valid email address to check the request.', 'error'); return; }
        try {
            const response = await apiRequest('/auth/registration-status?email=' + encodeURIComponent(email));
            const request = response.data.registration;
            const box = getElement('registrationStatusResult');
            if (box) {
                box.style.display = 'block';
                box.innerHTML = '<strong>Request status ' + escapeHTML(request.status) + '</strong><span>Submitted ' + escapeHTML(formatDate(request.requestedAt)) + '</span>' + (request.reviewedAt ? '<span>Reviewed ' + escapeHTML(formatDate(request.reviewedAt)) + '</span>' : '');
            }
        } catch (error) { showMessage(error.message || 'Registration request was not found.', 'error'); }
    }

    function initRegister() {
        const form = getElement('registerForm');
        if (!form) return;
        loadRegistrationOptions();
        const statusButton = getElement('checkRegistrationStatus');
        if (statusButton) statusButton.addEventListener('click', function(){ checkRegistrationStatus(getElement('registerEmail').value.trim()); });
        form.addEventListener('submit', async function(e){
            e.preventDefault();
            if (!validateRequired(form)) return;
            const password = getElement('registerPassword').value;
            const confirm = getElement('registerConfirm').value;
            const email = getElement('registerEmail').value.trim();
            if (!isValidPassword(password)) { showMessage('Password must use 8 to 64 characters with at least one letter and one number.', 'error'); return; }
            if (password !== confirm) { showMessage('Passwords do not match.', 'error'); return; }
            if (!isEmail(email)) { showMessage('Please enter a valid email address.', 'error'); return; }
            const button = form.querySelector('button[type="submit"]');
            button.disabled = true;
            try {
                const response = await apiRequest('/auth/register', {
                    method:'POST',
                    body:{
                        full_name:getElement('registerName').value.trim(),
                        email:email,
                        phone:normalizeSriLankanMobile(getElement('registerPhone').value),
                        block:getElement('registerBlock').value,
                        floor:getElement('registerFloor').value,
                        unit_number:getElement('registerApartment').value.trim(),
                        resident_type:getElement('registerResidentType') ? getElement('registerResidentType').value : 'Other',
                        preferred_language:getElement('registerLanguage') ? getElement('registerLanguage').value : 'English',
                        password:password
                    }
                });
                showMessage(response.message || 'Registration request submitted for approval.', 'success');
                const result = getElement('registrationStatusResult');
                if (result) {
                    result.style.display = 'block';
                    result.innerHTML = '<strong>Registration request submitted</strong><span>Your account will be created after an Apartment Admin or System Admin approves the request. You can then sign in using the same email and password.</span>';
                }
                button.textContent = 'Request submitted';
                button.disabled = true;
            } catch (error) { showMessage(error.message, 'error'); button.disabled = false; }
        });
    }

    function initForgot() {
        const form = getElement('forgotForm');
        if (!form) return;
        form.addEventListener('submit', async function(e){
            e.preventDefault();
            if (!validateRequired(form)) return;
            const button = form.querySelector('button[type="submit"]'); button.disabled = true;
            try {
                const response = await apiRequest('/auth/forgot-password', {method:'POST',body:{email:getElement('forgotEmail').value.trim()}});
                const result = getElement('forgotResult');
                if (result) {
                    result.style.display = 'block';
                    result.innerHTML = '<div><strong>Password reset request created</strong><span>If the account exists, a System Admin will be notified so the account can be verified and a temporary password can be issued securely.</span></div>';
                }
                showMessage('Password reset request created.', 'success');
            } catch (error) { showMessage(error.message, 'error'); }
            finally { button.disabled = false; }
        });
    }

    function initReset() {
        const form = getElement('resetPasswordForm'); if (!form) return;
        const token = new URLSearchParams(location.search).get('token') || '';
        if (!token) showMessage('The reset token is missing.', 'error');
        form.addEventListener('submit', async function(e){
            e.preventDefault(); if (!validateRequired(form)) return;
            const password = getElement('resetPassword').value, confirm = getElement('resetConfirm').value;
            if (!isValidPassword(password)) { showMessage('Password must use 8 to 64 characters with at least one letter and one number.', 'error'); return; }
            if (password !== confirm) { showMessage('Passwords do not match.', 'error'); return; }
            const button = form.querySelector('button[type="submit"]'); button.disabled = true;
            try { await apiRequest('/auth/reset-password', {method:'POST',body:{token:token,password:password}}); showMessage('Password updated.', 'success'); setTimeout(function(){ location.href='login.html'; },600); }
            catch (error) { showMessage(error.message,'error'); }
            finally { button.disabled=false; }
        });
    }



    function initChangePassword() {
        const form=getElement('changePasswordForm'); if(!form)return;
        if(!getAuthToken() || !currentUser()){ location.href='login.html'; return; }
        form.addEventListener('submit',async function(e){
            e.preventDefault(); if(!validateRequired(form))return;
            const current=getElement('currentPassword').value,newPassword=getElement('newPassword').value,confirm=getElement('newPasswordConfirm').value;
            if(!isValidPassword(newPassword)){showMessage('New password must use 8 to 64 characters with at least one letter and one number.','error');return;}
            if(newPassword!==confirm){showMessage('New passwords do not match.','error');return;}
            const button=form.querySelector('button[type="submit"]');button.disabled=true;
            try{await apiRequest('/auth/change-password',{method:'POST',body:{current_password:current,new_password:newPassword}});clearAuthSession();showMessage('Password changed. Sign in again.','success');setTimeout(()=>location.href='login.html',600);}
            catch(error){showMessage(error.message,'error');}
            finally{button.disabled=false;}
        });
    }
    document.addEventListener('DOMContentLoaded', function(){ protectPage(); initLogin(); initRegister(); initForgot(); initReset(); initChangePassword(); });
})();
