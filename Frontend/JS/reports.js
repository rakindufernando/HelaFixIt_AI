/* Apartment Admin reports use only current MariaDB data returned by Flask. */
(function(){
    function minutesText(value){
        value=Number(value||0);
        if(!value)return '-';
        if(value<60)return Math.round(value)+' min';
        const h=Math.floor(value/60),m=Math.round(value%60);
        return h+' h'+(m?' '+m+' min':'');
    }
    function safeItems(items){return Array.isArray(items)?items:[];}
    function countList(items){
        items=safeItems(items);
        const total=Math.max(...items.map(x=>Number(x.value||0)),1);
        return items.map(x=>'<div class="report-list-row"><span>'+escapeHTML(x.label||'Unknown')+'</span><div class="progress"><span style="width:'+Math.max(3,Math.round(Number(x.value||0)/total*100))+'%"></span></div><strong>'+Number(x.value||0)+'</strong></div>').join('')||'<div class="empty-state"><p>No records available.</p></div>';
    }
    function setReportValue(id,value){if(getElement(id))setText(id,value);}
    async function renderReports(){
        if(!getElement('reportsPage'))return;
        try{
            const response=await apiRequest('/admin/reports');
            const d=response.data||{},s=d.summary||{},a=d.ai||{};
            const categories=safeItems(d.categories),priority=safeItems(d.priority),statuses=safeItems(d.statuses),buildings=safeItems(d.buildings),floors=safeItems(d.floors),monthly=safeItems(d.monthly),technicians=safeItems(d.technicians);

            setReportValue('reportTotal',Number(s.total||0));
            setReportValue('reportOpen',Number(s.open||0));
            setReportValue('reportEmergency',Number(s.emergency||0));
            setReportValue('reportCompleted',Number(s.completed||0));
            setReportValue('reportCompletionTime',minutesText(s.avgCompletionMinutes));
            setReportValue('reportResponseTime',minutesText(s.avgResponseMinutes));
            setReportValue('reportDuplicates',Number(s.duplicates||0));
            setReportValue('reportAutoAssignments',Number(s.autoAssignments||0));
            setReportValue('reportAiPredictions',Number(a.predictions||0));
            setReportValue('reportCategoryConfidence',Number(a.avgCategoryConfidence||0).toFixed(1)+'%');
            setReportValue('reportPriorityConfidence',Number(a.avgPriorityConfidence||0).toFixed(1)+'%');
            setReportValue('reportManualReviews',Number(a.manualReviews||0));
            setReportValue('reportSafetyPredictions',Number(a.safetyPredictions||0));
            setReportValue('reportAiCorrections',Number(a.corrections||0));

            if(d.scope&&d.scope.buildingId){
                setReportValue('reportScopeText','Live data for '+(d.scope.block?d.scope.block+' - ':'')+(d.scope.building||'assigned building'));
            }else{
                setReportValue('reportScopeText','Live maintenance data for the assigned building');
            }

            const max=Math.max(...categories.map(x=>Number(x.value||0)),1);
            const bars=getElement('categoryBars');
            if(bars)bars.innerHTML=categories.map(x=>'<div class="chart-bar-group"><div class="chart-bar" style="--h:'+Math.max(8,Math.round(Number(x.value||0)/max*100))+'%"></div><span>'+escapeHTML(x.label||'Unknown')+'<br>'+Number(x.value||0)+'</span></div>').join('')||'<div class="empty-state"><p>No ticket data available.</p></div>';
            if(getElement('prioritySummary'))getElement('prioritySummary').innerHTML=countList(priority);
            if(getElement('statusReportList'))getElement('statusReportList').innerHTML=countList(statuses);
            if(getElement('buildingReportList'))getElement('buildingReportList').innerHTML=countList(buildings);
            if(getElement('floorReportList'))getElement('floorReportList').innerHTML=countList(floors);
            if(getElement('monthlyReportRows'))getElement('monthlyReportRows').innerHTML=monthly.map(x=>'<tr><td>'+escapeHTML(x.month||'-')+'</td><td>'+Number(x.submitted||0)+'</td><td>'+Number(x.completed||0)+'</td><td>'+Number(x.emergency||0)+'</td></tr>').join('')||'<tr><td colspan="4">No monthly records available.</td></tr>';
            if(getElement('workloadRows'))getElement('workloadRows').innerHTML=technicians.map(t=>'<tr><td><span class="table-primary">'+escapeHTML(t.name||'Technician')+'</span><span class="table-secondary">Technician '+Number(t.id||0)+'</span></td><td>'+makeBadge(t.availability||'Unknown')+'</td><td>'+Number(t.workload||0)+'/'+Number(t.maxJobs||0)+'</td><td><div class="progress"><span style="width:'+Math.min(100,Math.round((Number(t.workload||0)/Math.max(1,Number(t.maxJobs||1)))*100))+'%"></span></div></td><td>'+Number(t.completed||0)+'</td><td>'+minutesText(t.avgResponseMinutes)+'</td><td>'+(t.rating===null||t.rating===undefined?'-':Number(t.rating).toFixed(1)+'/5')+'</td></tr>').join('')||'<tr><td colspan="7">No technician records available.</td></tr>';

            const exportButton=getElement('exportReport');
            if(exportButton&&!exportButton.dataset.bound){
                exportButton.dataset.bound='1';
                exportButton.addEventListener('click',function(){
                    const rows=[['HelaFixIt AI Maintenance Report'],['Building',d.scope?((d.scope.block||'')+' '+(d.scope.building||'')).trim():'' ],[],['Metric','Value'],['Total tickets',s.total||0],['Open tickets',s.open||0],['Emergency tickets',s.emergency||0],['Resolved tickets',s.completed||0],['Average completion minutes',s.avgCompletionMinutes||0],['Average response minutes',s.avgResponseMinutes||0],['Duplicate reports',s.duplicates||0],['Auto emergency assignments',s.autoAssignments||0],[],['Category','Count'],...categories.map(x=>[x.label,x.value]),[],['Priority','Count'],...priority.map(x=>[x.label,x.value]),[],['Technician','Availability','Active jobs','Capacity','Completed','Average response minutes'],...technicians.map(t=>[t.name,t.availability,t.workload,t.maxJobs,t.completed,t.avgResponseMinutes])];
                    const csv=rows.map(row=>row.map(v=>'"'+String(v==null?'':v).replace(/"/g,'""')+'"').join(',')).join('\n');
                    const blob=new Blob([csv],{type:'text/csv;charset=utf-8'}),link=document.createElement('a');
                    link.href=URL.createObjectURL(blob);link.download='HelaFixIt_maintenance_report.csv';link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000);showMessage('Report exported.','success');
                });
            }
        }catch(e){showMessage(e.message||'Reports could not be loaded.','error');}
    }
    document.addEventListener('DOMContentLoaded',renderReports);
})();
