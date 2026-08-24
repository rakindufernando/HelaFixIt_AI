(function () {
    const EMAIL_RE = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

    window.normalizeSriLankanMobile = function(value){
        let compact = String(value || '').trim().replace(/[\s().-]+/g, '');
        if (!compact) return '';
        if (compact.startsWith('0094')) compact = '+94' + compact.slice(4);
        else if (compact.startsWith('94') && !compact.startsWith('+94')) compact = '+' + compact;
        else if (compact.startsWith('0')) compact = '+94' + compact.slice(1);
        else if (compact.startsWith('7') && compact.length === 9) compact = '+94' + compact;
        return compact;
    };

    window.isEmail = function(value){ return EMAIL_RE.test(String(value || '').trim()); };
    window.isSriLankanMobile = function(value){ return /^\+947\d{8}$/.test(normalizeSriLankanMobile(value)); };
    window.isValidName = function(value){
        const text = String(value || '').trim();
        if (text.length < 2 || text.length > 150 || !/\p{L}/u.test(text)) return false;
        return [...text].every(ch => /[\p{L}\p{M}]/u.test(ch) || [' ', '-', "'", '.'].includes(ch));
    };
    window.isValidPassword = function(value){
        const text = String(value || '');
        return text.length >= 8 && text.length <= 64 && /[A-Za-z]/.test(text) && /\d/.test(text);
    };
    window.isValidUnitNumber = function(value){
        const text=String(value || '').trim();
        return !text || /^[A-Za-z0-9][A-Za-z0-9 ./_-]{0,39}$/.test(text);
    };
    window.isValidEmployeeCode = function(value){
        const text=String(value || '').trim();
        return !text || /^[A-Za-z0-9][A-Za-z0-9_-]{1,49}$/.test(text);
    };

    function clearFieldError(field){
        field.style.borderColor='';
        const parent=field.closest('.field');
        const error=parent && parent.querySelector('.field-error');
        if(error) error.remove();
    }
    function fieldError(field,message){
        clearFieldError(field);
        field.style.borderColor='#e5484d';
        const parent=field.closest('.field');
        if(parent){const small=document.createElement('small');small.className='field-error';small.style.color='#b42318';small.textContent=message;parent.appendChild(small);}
    }
    window.clearFieldError=clearFieldError;

    window.validateFieldFormat=function(field){
        clearFieldError(field);
        const type=field.dataset.validate || field.type || '';
        if ((field.type === 'checkbox' || field.type === 'radio')) {
            if (field.required && !field.checked) {
                fieldError(field, 'This confirmation is required.');
                return false;
            }
            return true;
        }
        const value=String(field.value || '').trim();
        if(field.required && !value){fieldError(field,'This field is required.');return false;}
        if(!value && !field.required)return true;
        if(type==='email' && !isEmail(value)){fieldError(field,'Enter a valid email address.');return false;}
        if(type==='mobile' && !isSriLankanMobile(value)){fieldError(field,'Use 0771234567 or +94771234567.');return false;}
        if(type==='name' && !isValidName(value)){fieldError(field,'Use letters, spaces, apostrophes, periods or hyphens only.');return false;}
        if(type==='password' && !isValidPassword(field.value)){fieldError(field,'Use 8 to 64 characters with at least one letter and one number.');return false;}
        if(type==='unit' && !isValidUnitNumber(value)){fieldError(field,'Use letters, numbers, spaces, /, -, _ or . only.');return false;}
        if(type==='employee-code' && !isValidEmployeeCode(value)){fieldError(field,'Use letters, numbers, hyphens or underscores only.');return false;}
        if(field.type==='number'){
            const number=Number(field.value);
            if(!Number.isFinite(number)){fieldError(field,'Enter a valid number.');return false;}
            if(field.min!=='' && number<Number(field.min)){fieldError(field,'Value must be at least '+field.min+'.');return false;}
            if(field.max!=='' && number>Number(field.max)){fieldError(field,'Value must not exceed '+field.max+'.');return false;}
        }
        if(field.maxLength>0 && value.length>field.maxLength){fieldError(field,'Maximum length is '+field.maxLength+' characters.');return false;}
        return true;
    };

    window.validateRequired = function (form) {
        let valid = true;
        form.querySelectorAll('input,select,textarea').forEach(function(field){
            if(field.disabled || field.type==='hidden' || field.type==='button' || field.type==='submit')return;
            if(!validateFieldFormat(field))valid=false;
        });
        if (!valid) showMessage('Please correct the highlighted fields.', 'error');
        return valid;
    };

    document.addEventListener('input',function(event){
        const field=event.target;
        if(field.matches && field.matches('input,textarea'))clearFieldError(field);
    });
    document.addEventListener('change',function(event){
        const field=event.target;
        if(field.matches && field.matches('select'))clearFieldError(field);
    });
})();
