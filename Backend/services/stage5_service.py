from __future__ import annotations

import json
from datetime import datetime

from database import get_connection, query_all, query_one
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name, validate_plain_text


def _audit(cursor, user_id, action, entity_type, entity_id=None, reason=None, old=None, new=None):
    cursor.execute(
        """INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,old_value,new_value,reason)
           VALUES(%s,%s,%s,%s,%s,%s,%s)""",
        (
            user_id, action, entity_type, str(entity_id) if entity_id is not None else None,
            json.dumps(old, ensure_ascii=False, default=str) if old is not None else None,
            json.dumps(new, ensure_ascii=False, default=str) if new is not None else None,
            reason,
        ),
    )


def _flag(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {'1', 'true', 'yes', 'on', 'active'}


def update_skill(skill_id, payload, user_id):
    name = clean_text(payload.get('name'), 100)
    description = clean_text(payload.get('description'), 255)
    if len(name) < 2:
        return None, 'Enter a valid technician skill name.', 400
    connection = get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT skill_id,skill_name,description,active FROM skills WHERE skill_id=%s FOR UPDATE', (skill_id,))
            old = c.fetchone()
            if not old:
                return None, 'Technician skill not found.', 404
            c.execute('SELECT skill_id FROM skills WHERE LOWER(skill_name)=LOWER(%s) AND skill_id<>%s LIMIT 1', (name, skill_id))
            if c.fetchone():
                return None, 'Another technician skill already uses this name.', 409
            c.execute('UPDATE skills SET skill_name=%s,description=%s WHERE skill_id=%s', (name, description or None, skill_id))
            _audit(c, user_id, 'SKILL_UPDATED', 'Skill', skill_id, 'Technician skill updated.', old, {'name': name, 'description': description})
        connection.commit()
        return {'id': int(skill_id)}, None, 200
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()


def set_skill_status(skill_id, active, user_id):
    connection = get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT skill_id,skill_name,active FROM skills WHERE skill_id=%s FOR UPDATE', (skill_id,)); row = c.fetchone()
            if not row: return None, 'Technician skill not found.', 404
            c.execute('UPDATE skills SET active=%s WHERE skill_id=%s', (bool(active), skill_id))
            _audit(c, user_id, 'SKILL_STATUS_CHANGED', 'Skill', skill_id, f"Skill {'enabled' if active else 'disabled'}.", row, {'active': bool(active)})
        connection.commit(); return {'id': int(skill_id), 'active': bool(active)}, None, 200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def technician_skill_assignments():
    technicians = query_all(
        """SELECT tp.technician_id,u.full_name,tp.employee_code,tp.active,tp.availability,
                  GROUP_CONCAT(CONCAT(s.skill_id,'|',s.skill_name,'|',ts.skill_level,'|',IF(ts.verified,1,0),'|',IF(ts.is_primary,1,0))
                               ORDER BY ts.is_primary DESC,s.skill_name SEPARATOR ';;') AS skill_data
           FROM technician_profiles tp JOIN users u ON u.user_id=tp.user_id
           LEFT JOIN technician_skills ts ON ts.technician_id=tp.technician_id
           LEFT JOIN skills s ON s.skill_id=ts.skill_id
           WHERE u.is_deleted=FALSE
           GROUP BY tp.technician_id,u.full_name,tp.employee_code,tp.active,tp.availability
           ORDER BY u.full_name"""
    )
    result = []
    for row in technicians:
        skills = []
        raw = row.get('skill_data') or ''
        if raw:
            for item in raw.split(';;'):
                parts = item.split('|')
                if len(parts) == 5:
                    skills.append({'id': int(parts[0]), 'name': parts[1], 'level': parts[2], 'verified': parts[3] == '1', 'primary': parts[4] == '1'})
        result.append({'id': int(row['technician_id']), 'name': row['full_name'], 'employeeCode': row['employee_code'], 'active': bool(row['active']), 'availability': row['availability'], 'skills': skills})
    return result


def replace_technician_skills(technician_id, assignments, user_id):
    if not isinstance(assignments, list) or not assignments:
        return None, 'Select at least one technician skill.', 400
    clean = []
    primary_count = 0
    for item in assignments:
        try: sid = int(item.get('skill_id'))
        except (TypeError, ValueError): return None, 'Select valid technician skills.', 400
        level = item.get('level') if item.get('level') in {'Basic','Intermediate','Advanced','Expert'} else 'Intermediate'
        verified = bool(item.get('verified', True)); primary = bool(item.get('primary'))
        primary_count += 1 if primary else 0
        clean.append((sid, level, verified, primary))
    if primary_count != 1:
        return None, 'Select exactly one primary skill.', 400
    connection = get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT technician_id FROM technician_profiles WHERE technician_id=%s AND active=TRUE FOR UPDATE', (technician_id,))
            if not c.fetchone(): return None, 'Active technician not found.', 404
            ids = tuple(x[0] for x in clean)
            placeholders = ','.join(['%s'] * len(ids))
            c.execute(f'SELECT skill_id FROM skills WHERE active=TRUE AND skill_id IN ({placeholders})', ids)
            if len(c.fetchall()) != len(set(ids)): return None, 'One or more selected skills are unavailable.', 400
            c.execute('SELECT ts.skill_id,s.skill_name,ts.skill_level,ts.verified,ts.is_primary FROM technician_skills ts JOIN skills s ON s.skill_id=ts.skill_id WHERE ts.technician_id=%s', (technician_id,))
            old = c.fetchall()
            c.execute('DELETE FROM technician_skills WHERE technician_id=%s', (technician_id,))
            for sid, level, verified, primary in clean:
                c.execute('INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,is_primary) VALUES(%s,%s,%s,%s,%s)', (technician_id, sid, level, verified, primary))
            _audit(c, user_id, 'TECHNICIAN_SKILLS_UPDATED', 'Technician', technician_id, 'Technician skill assignments updated.', old, assignments)
        connection.commit(); return {'id': int(technician_id)}, None, 200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def update_category(category_id, payload, user_id):
    name = clean_text(payload.get('name'), 100)
    description = clean_text(payload.get('description'), 255)
    code = clean_text(payload.get('code'), 50).upper()
    priority = payload.get('priority') if payload.get('priority') in {'Emergency','High','Medium','Low'} else 'Medium'
    try:
        weight = float(payload.get('risk_weight', 0)); skill_id = int(payload.get('skill_id')) if payload.get('skill_id') else None
    except (TypeError, ValueError): return None, 'Enter valid category values.', 400
    if not code or len(name) < 2 or weight < 0 or weight > 30:
        return None, 'Enter a valid category code, name and risk weight from 0 to 30.', 400
    connection = get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM issue_categories WHERE category_id=%s FOR UPDATE', (category_id,)); old = c.fetchone()
            if not old: return None, 'Issue category not found.', 404
            if skill_id:
                c.execute('SELECT skill_id FROM skills WHERE skill_id=%s AND active=TRUE', (skill_id,))
                if not c.fetchone(): return None, 'Select an active technician skill.', 400
            c.execute('SELECT category_id FROM issue_categories WHERE (LOWER(category_code)=LOWER(%s) OR LOWER(name)=LOWER(%s)) AND category_id<>%s LIMIT 1', (code, name, category_id))
            if c.fetchone(): return None, 'Another category already uses this code or name.', 409
            c.execute('UPDATE issue_categories SET category_code=%s,name=%s,default_skill_id=%s,default_priority=%s,severity_weight=%s,description=%s WHERE category_id=%s', (code,name,skill_id,priority,weight,description or None,category_id))
            if skill_id:
                c.execute("UPDATE category_skill_mappings SET is_primary=FALSE WHERE category_id=%s", (category_id,))
                c.execute("""INSERT INTO category_skill_mappings(category_id,skill_id,required_level,match_weight,is_primary,active)
                             VALUES(%s,%s,'Intermediate',100,TRUE,TRUE)
                             ON DUPLICATE KEY UPDATE is_primary=TRUE,active=TRUE,match_weight=100""", (category_id, skill_id))
            _audit(c,user_id,'CATEGORY_UPDATED','IssueCategory',category_id,'Issue category updated.',old,{'code':code,'name':name,'priority':priority,'risk_weight':weight,'skill_id':skill_id})
        connection.commit(); return {'id':int(category_id)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def set_category_status(category_id, active, user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT category_id,name,active FROM issue_categories WHERE category_id=%s FOR UPDATE',(category_id,));row=c.fetchone()
            if not row:return None,'Issue category not found.',404
            c.execute('UPDATE issue_categories SET active=%s WHERE category_id=%s',(bool(active),category_id))
            c.execute('UPDATE category_skill_mappings SET active=%s WHERE category_id=%s',(bool(active),category_id))
            _audit(c,user_id,'CATEGORY_STATUS_CHANGED','IssueCategory',category_id,f"Category {'enabled' if active else 'disabled'}.",row,{'active':bool(active)})
        connection.commit();return {'id':int(category_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def update_building(building_id,payload,user_id):
    code=clean_text(payload.get('code'),50);name=clean_text(payload.get('name'),150);address=clean_text(payload.get('address'),255)
    try:floors=int(payload.get('floors') or 0);units=int(payload.get('units') or 0)
    except (TypeError,ValueError):return None,'Enter valid floor and unit counts.',400
    if not code or len(name)<2 or floors<0 or floors>200 or units<0 or units>5000:return None,'Enter valid building details.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM buildings WHERE building_id=%s FOR UPDATE',(building_id,));old=c.fetchone()
            if not old:return None,'Building not found.',404
            c.execute('SELECT building_id FROM buildings WHERE complex_id=%s AND LOWER(block_code)=LOWER(%s) AND building_id<>%s LIMIT 1',(old['complex_id'],code,building_id))
            if c.fetchone():return None,'Another building already uses this code.',409
            c.execute('UPDATE buildings SET block_code=%s,name=%s,address_label=%s,declared_floor_count=%s,declared_unit_count=%s WHERE building_id=%s',(code,name,address or None,floors,units,building_id))
            _audit(c,user_id,'BUILDING_UPDATED','Building',building_id,'Building details updated.',old,{'code':code,'name':name,'address':address,'floors':floors,'units':units})
        connection.commit();return {'id':int(building_id)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def set_building_status(building_id,active,user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT building_id,name,status FROM buildings WHERE building_id=%s FOR UPDATE',(building_id,));row=c.fetchone()
            if not row:return None,'Building not found.',404
            status='Active' if active else 'Inactive';c.execute('UPDATE buildings SET status=%s WHERE building_id=%s',(status,building_id))
            _audit(c,user_id,'BUILDING_STATUS_CHANGED','Building',building_id,f'Building set to {status}.',row,{'status':status})
        connection.commit();return {'id':int(building_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def update_floor(floor_id,payload,user_id):
    name=clean_text(payload.get('name'),80)
    try:number=int(payload.get('floor_number'))
    except (TypeError,ValueError):return None,'Enter a valid floor number.',400
    if not name or number<-20 or number>200:return None,'Enter a valid floor number and name.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM floors WHERE floor_id=%s FOR UPDATE',(floor_id,));old=c.fetchone()
            if not old:return None,'Floor not found.',404
            c.execute('SELECT floor_id FROM floors WHERE building_id=%s AND floor_number=%s AND floor_id<>%s LIMIT 1',(old['building_id'],number,floor_id))
            if c.fetchone():return None,'This floor number already exists in the building.',409
            c.execute('UPDATE floors SET floor_number=%s,name=%s WHERE floor_id=%s',(number,name,floor_id))
            _audit(c,user_id,'FLOOR_UPDATED','Floor',floor_id,'Floor updated.',old,{'number':number,'name':name})
        connection.commit();return {'id':int(floor_id)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def set_floor_status(floor_id,active,user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT floor_id,name,status FROM floors WHERE floor_id=%s FOR UPDATE',(floor_id,));row=c.fetchone()
            if not row:return None,'Floor not found.',404
            status='Active' if active else 'Inactive';c.execute('UPDATE floors SET status=%s WHERE floor_id=%s',(status,floor_id))
            _audit(c,user_id,'FLOOR_STATUS_CHANGED','Floor',floor_id,f'Floor set to {status}.',row,{'status':status})
        connection.commit();return {'id':int(floor_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def update_area(area_id,payload,user_id):
    name=clean_text(payload.get('name'),100);area_type=payload.get('area_type') if payload.get('area_type') in {'Private','Common','Service','Outdoor','Other'} else 'Common'
    try:risk=float(payload.get('risk_weight') or 0)
    except (TypeError,ValueError):return None,'Enter a valid area risk weight.',400
    if not name or risk<0 or risk>30:return None,'Enter a valid area name and risk weight from 0 to 30.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM areas WHERE area_id=%s FOR UPDATE',(area_id,));old=c.fetchone()
            if not old:return None,'Area not found.',404
            c.execute('UPDATE areas SET name=%s,area_type=%s,risk_weight=%s WHERE area_id=%s',(name,area_type,risk,area_id))
            _audit(c,user_id,'AREA_UPDATED','Area',area_id,'Maintenance area updated.',old,{'name':name,'type':area_type,'risk_weight':risk})
        connection.commit();return {'id':int(area_id)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def set_area_status(area_id,active,user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT area_id,name,status FROM areas WHERE area_id=%s FOR UPDATE',(area_id,));row=c.fetchone()
            if not row:return None,'Area not found.',404
            status='Active' if active else 'Inactive';c.execute('UPDATE areas SET status=%s WHERE area_id=%s',(status,area_id))
            _audit(c,user_id,'AREA_STATUS_CHANGED','Area',area_id,f'Area set to {status}.',row,{'status':status})
        connection.commit();return {'id':int(area_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def update_safety_rule(rule_id,payload,user_id):
    code=clean_text(payload.get('code'),80).upper();keyword=clean_text(payload.get('keyword'),255);warning=clean_text(payload.get('warning'),500)
    match_type=payload.get('match_type') if payload.get('match_type') in {'Keyword','Phrase','Regex'} else 'Phrase'
    language=payload.get('language') if payload.get('language') in {'English','Sinhala','Singlish','Mixed','Any'} else 'Any'
    severity=payload.get('severity') if payload.get('severity') in {'Low','Medium','High','Critical'} else 'High'
    resident_action=clean_text(payload.get('resident_action'),500);technician_action=clean_text(payload.get('technician_action'),500)
    try:score=float(payload.get('score') or 0);category_id=int(payload.get('category_id')) if payload.get('category_id') else None
    except (TypeError,ValueError):return None,'Enter valid safety rule values.',400
    if not code or not keyword or not warning or score<0 or score>50:return None,'Enter rule code, matching text, warning and a risk weight from 0 to 50.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM safety_rules WHERE safety_rule_id=%s FOR UPDATE',(rule_id,));old=c.fetchone()
            if not old:return None,'Safety rule not found.',404
            c.execute('SELECT safety_rule_id FROM safety_rules WHERE LOWER(rule_code)=LOWER(%s) AND safety_rule_id<>%s LIMIT 1',(code,rule_id))
            if c.fetchone():return None,'Another safety rule already uses this code.',409
            c.execute("""UPDATE safety_rules SET category_id=%s,rule_code=%s,keyword_or_pattern=%s,match_type=%s,language_type=%s,
                       score_weight=%s,severity=%s,warning_message=%s,resident_action=%s,technician_action=%s,updated_by=%s WHERE safety_rule_id=%s""",
                      (category_id,code,keyword,match_type,language,score,severity,warning,resident_action or None,technician_action or None,user_id,rule_id))
            _audit(c,user_id,'SAFETY_RULE_UPDATED','SafetyRule',rule_id,'Safety rule updated.',old,{'code':code,'keyword':keyword,'severity':severity,'score':score})
        connection.commit();return {'id':int(rule_id)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def set_safety_rule_status(rule_id,active,user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT safety_rule_id,rule_code,active FROM safety_rules WHERE safety_rule_id=%s FOR UPDATE',(rule_id,));row=c.fetchone()
            if not row:return None,'Safety rule not found.',404
            c.execute('UPDATE safety_rules SET active=%s,updated_by=%s WHERE safety_rule_id=%s',(bool(active),user_id,rule_id))
            _audit(c,user_id,'SAFETY_RULE_STATUS_CHANGED','SafetyRule',rule_id,f"Safety rule {'enabled' if active else 'disabled'}.",row,{'active':bool(active)})
        connection.commit();return {'id':int(rule_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def system_admin_profile(user_id):
    row=query_one("""SELECT u.user_id,u.full_name,u.email,u.phone,u.account_status,u.email_verified,u.last_login_at,u.created_at
                     FROM users u JOIN roles r ON r.role_id=u.role_id WHERE u.user_id=%s AND r.role_code='system_admin' AND u.is_deleted=FALSE LIMIT 1""",(user_id,))
    if not row:return None
    return {'id':int(row['user_id']),'name':row['full_name'],'email':row['email'],'phone':row.get('phone') or '', 'status':row['account_status'],'emailVerified':bool(row['email_verified']), 'lastLogin':row['last_login_at'].isoformat() if row.get('last_login_at') else None,'created':row['created_at'].isoformat() if row.get('created_at') else None}


def update_system_admin_profile(user_id,payload):
    name=clean_text(payload.get('name'),150);phone=normalize_mobile(payload.get('phone'))
    if not validate_name(name):return None,'Enter a valid full name.',400
    if phone and not validate_mobile(phone):return None,'Enter a valid Sri Lankan mobile number.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT full_name,phone FROM users WHERE user_id=%s FOR UPDATE',(user_id,));old=c.fetchone()
            if not old:return None,'System Admin account not found.',404
            c.execute('UPDATE users SET full_name=%s,phone=%s WHERE user_id=%s',(name,phone or None,user_id))
            _audit(c,user_id,'PROFILE_UPDATED','User',user_id,'System Admin profile updated.',old,{'name':name,'phone':phone})
        connection.commit();return system_admin_profile(user_id),None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def resident_profile(user_id):
    row=query_one("""SELECT u.user_id,u.full_name,u.email,u.phone,rp.resident_type,rp.preferred_language,rp.contact_preference,
                            rp.unit_number,b.block_code,b.name AS building_name,f.name AS floor_name
                     FROM users u JOIN resident_profiles rp ON rp.user_id=u.user_id
                     JOIN buildings b ON b.building_id=rp.building_id JOIN floors f ON f.floor_id=rp.floor_id
                     WHERE u.user_id=%s AND u.is_deleted=FALSE LIMIT 1""",(user_id,))
    if not row:return None
    return {'name':row['full_name'],'email':row['email'],'phone':row.get('phone') or '', 'residentType':row['resident_type'],'preferredLanguage':row['preferred_language'],'contactPreference':row['contact_preference'],'unitNumber':row.get('unit_number') or '', 'block':row['block_code'],'building':row['building_name'],'floor':row['floor_name']}


def update_resident_profile(user_id,payload):
    name=clean_text(payload.get('name'),150);phone=normalize_mobile(payload.get('phone'));language=payload.get('preferred_language');contact=payload.get('contact_preference')
    if not validate_name(name):return None,'Enter a valid full name.',400
    if not validate_mobile(phone,required=True):return None,'Enter a valid Sri Lankan mobile number.',400
    if language not in {'English','Sinhala','Singlish','Mixed'}:return None,'Select a valid preferred language.',400
    if contact not in {'In App','Email','SMS','Phone'}:return None,'Select a valid contact preference.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT full_name,phone FROM users WHERE user_id=%s FOR UPDATE',(user_id,));old=c.fetchone()
            if not old:return None,'Resident account not found.',404
            c.execute('UPDATE users SET full_name=%s,phone=%s WHERE user_id=%s',(name,phone,user_id))
            c.execute('UPDATE resident_profiles SET preferred_language=%s,contact_preference=%s WHERE user_id=%s',(language,contact,user_id))
            _audit(c,user_id,'PROFILE_UPDATED','Resident',user_id,'Resident profile updated.',old,{'name':name,'phone':phone,'language':language,'contact':contact})
        connection.commit();return resident_profile(user_id),None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def backup_records(limit=50):
    safe_limit = max(1, min(int(limit), 100))
    rows=query_all(f"""SELECT br.backup_id,br.backup_type,br.file_name,br.file_location,br.backup_status,br.size_bytes,br.started_at,br.completed_at,br.notes,u.full_name
                      FROM backup_records br LEFT JOIN users u ON u.user_id=br.started_by ORDER BY br.started_at DESC LIMIT {safe_limit}""")
    return [{'id':int(r['backup_id']),'type':r['backup_type'],'fileName':r.get('file_name') or '', 'location':r.get('file_location') or '', 'status':r['backup_status'],'size':int(r.get('size_bytes') or 0),'startedAt':r['started_at'].isoformat() if r.get('started_at') else None,'completedAt':r['completed_at'].isoformat() if r.get('completed_at') else None,'notes':r.get('notes') or '', 'startedBy':r.get('full_name') or 'System'} for r in rows]


def filtered_audit_logs(search='', action='', entity='', date_from='', date_to='', user=''):
    where=['1=1'];params=[]
    if search:
        q=f'%{search}%';where.append('(al.action_type LIKE %s OR al.entity_type LIKE %s OR al.entity_id LIKE %s OR al.reason LIKE %s OR u.full_name LIKE %s)');params.extend([q,q,q,q,q])
    if action:
        where.append('al.action_type=%s');params.append(action)
    if entity:
        where.append('al.entity_type=%s');params.append(entity)
    if user:
        where.append('u.full_name LIKE %s');params.append(f'%{user}%')
    if date_from:
        where.append('DATE(al.created_at)>=%s');params.append(date_from)
    if date_to:
        where.append('DATE(al.created_at)<=%s');params.append(date_to)
    rows=query_all(f"""SELECT al.audit_id,al.action_type,al.entity_type,al.entity_id,al.reason,al.created_at,u.full_name
                       FROM audit_logs al LEFT JOIN users u ON u.user_id=al.user_id
                       WHERE {' AND '.join(where)} ORDER BY al.created_at DESC LIMIT 1000""",tuple(params))
    options=query_one('SELECT COUNT(*) total FROM audit_logs') or {'total':0}
    actions=query_all('SELECT DISTINCT action_type value FROM audit_logs ORDER BY action_type')
    entities=query_all('SELECT DISTINCT entity_type value FROM audit_logs ORDER BY entity_type')
    return {
        'logs':[{'id':int(r['audit_id']),'time':r['created_at'].isoformat() if r.get('created_at') else None,'user':r.get('full_name') or 'System','action':r['action_type'],'entity':r['entity_type'],'target':f"{r['entity_type']} {r.get('entity_id') or ''}".strip(),'detail':r.get('reason') or ''} for r in rows],
        'options':{'actions':[r['value'] for r in actions],'entities':[r['value'] for r in entities],'total':int(options['total'] or 0)}
    }


def record_audit(user_id, action, entity_type, entity_id=None, reason=''):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            _audit(c,user_id,action,entity_type,entity_id,reason)
        connection.commit()
    except Exception:
        connection.rollback();raise
    finally:
        connection.close()


def create_unit(payload,user_id):
    try: floor_id=int(payload.get('floor_id'))
    except (TypeError,ValueError): return None,'Select a valid floor.',400
    number=clean_text(payload.get('unit_number'),40);unit_type=payload.get('unit_type') if payload.get('unit_type') in {'Apartment','Common Facility','Staff','Other'} else 'Apartment'
    if not number or len(number)>40:return None,'Enter a valid apartment or unit number.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("SELECT floor_id FROM floors WHERE floor_id=%s AND status='Active'",(floor_id,))
            if not c.fetchone():return None,'Select an active floor.',400
            c.execute("INSERT INTO units(floor_id,unit_number,unit_type,status) VALUES(%s,%s,%s,'Active')",(floor_id,number,unit_type));uid=c.lastrowid
            _audit(c,user_id,'UNIT_CREATED','Unit',uid,'Apartment or unit created.',None,{'floor_id':floor_id,'unit_number':number,'unit_type':unit_type})
        connection.commit();return {'id':int(uid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc):return None,'This unit number already exists on the selected floor.',409
        raise
    finally:connection.close()


def update_unit(unit_id,payload,user_id):
    number=clean_text(payload.get('unit_number'),40);unit_type=payload.get('unit_type') if payload.get('unit_type') in {'Apartment','Common Facility','Staff','Other'} else 'Apartment'
    if not number:return None,'Enter a valid apartment or unit number.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT * FROM units WHERE unit_id=%s FOR UPDATE',(unit_id,));old=c.fetchone()
            if not old:return None,'Unit not found.',404
            c.execute('SELECT unit_id FROM units WHERE floor_id=%s AND unit_number=%s AND unit_id<>%s LIMIT 1',(old['floor_id'],number,unit_id))
            if c.fetchone():return None,'This unit number already exists on the floor.',409
            c.execute('UPDATE units SET unit_number=%s,unit_type=%s WHERE unit_id=%s',(number,unit_type,unit_id))
            _audit(c,user_id,'UNIT_UPDATED','Unit',unit_id,'Apartment or unit updated.',old,{'unit_number':number,'unit_type':unit_type})
        connection.commit();return {'id':int(unit_id)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()


def set_unit_status(unit_id,active,user_id):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT unit_id,unit_number,status FROM units WHERE unit_id=%s FOR UPDATE',(unit_id,));row=c.fetchone()
            if not row:return None,'Unit not found.',404
            status='Active' if active else 'Inactive';c.execute('UPDATE units SET status=%s WHERE unit_id=%s',(status,unit_id));_audit(c,user_id,'UNIT_STATUS_CHANGED','Unit',unit_id,f'Unit set to {status}.',row,{'status':status})
        connection.commit();return {'id':int(unit_id),'active':bool(active)},None,200
    except Exception:connection.rollback();raise
    finally:connection.close()
