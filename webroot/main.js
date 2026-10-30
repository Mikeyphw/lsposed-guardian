'use strict';
// Root-bridge command allowlist; never interpolate unvalidated UI text into a shell.
// KernelSU exec's synchronous overload truncates output. Always use a named callback.
const BASE='/data/adb/modules/lsposed_guardian/guardian.sh';
const $=id=>document.getElementById(id);
const READ_COMMANDS=new Set(['report','doctor','qualification','integrity','modules','history','history-changes','history-health','quarantine-status','quarantine-ledger','crash-audit','automatic-status','triage','collector-health','collect','notifications-status']);
const WRITE_COMMANDS=new Set(['automatic-on --apply','automatic-off','safe-mode-arm --apply','safe-mode-disarm','notifications-on --apply','notifications-off','notifications-test --apply']);
const COOLDOWNS=new Set(['3600','10800','21600','43200','86400','172800','604800']);
const MODULE_LINE=/^\s*([A-Za-z0-9_.-]+)\s+(\d+)\s+(enabled|disabled)\s*$/i;
const PKG_RE=/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/;
const state={report:null,raw:{},kv:{},modules:[],loaded:false,expectedEnabled:null,scopes:null,refreshing:false,writing:false,callbacks:0,seq:0,tab:'home',error:null,lastActionNotice:'',lastRefreshOk:false,scopeSeq:0};
function errorText(e){return String(e && e.message || e).slice(0,350)}
function safePkg(pkg){return PKG_RE.test(pkg)&&!pkg.includes('..')}
function safeTarget(s){return s==='system_server'||safePkg(s)}
function text(id,value){$(id).textContent=String(value===null||value===undefined?'—':value)}
function kv(raw){const out={};for(const line of String(raw||'').split(/\r?\n/)){const m=/^([a-z][a-z0-9_]*)=(.*)$/i.exec(line.trim());if(m)out[m[1]]=m[2]}return out}
function when(epoch){const n=Number(epoch);return Number.isFinite(n)&&n>0?new Date(n*1000).toLocaleString():'Not recorded'}
function statusClass(el,kind){el.classList.remove('good','warn','bad');if(kind)el.classList.add(kind)}
function clear(el){el.replaceChildren()}
function add(parent,tag,content,cls){const el=document.createElement(tag);if(cls)el.className=cls;el.textContent=content;parent.appendChild(el);return el}
function row(label,value){const wrap=document.createElement('div');wrap.className='kv-row';add(wrap,'span',label);add(wrap,'strong',value);return wrap}
function fields(id,items){const root=$(id);clear(root);for(const [a,b] of items)root.appendChild(row(a,String(b??'—')))}
function eventItem(title,detail,symbol='•',level=''){const el=document.createElement('div');el.className='event-row';const icon=add(el,'span',symbol,'event-icon');if(level)statusClass(icon,level);const body=document.createElement('div');body.className='event-copy';add(body,'strong',title);add(body,'small',detail);el.appendChild(body);return el}
function show(tab){if(!['home','modules','activity','review','settings'].includes(tab))return;state.tab=tab;document.querySelectorAll('.bottom-nav button').forEach(b=>{const on=b.dataset.tab===tab;b.classList.toggle('active',on);b.setAttribute('aria-current',on?'page':'false')});document.querySelectorAll('.screen').forEach(s=>s.classList.toggle('active',s.id===tab));if(typeof window.scrollTo==='function')window.scrollTo({top:0,behavior:'instant'})}
function command(args){
  const read=READ_COMMANDS.has(args),write=WRITE_COMMANDS.has(args);
  const scope=args.startsWith('scope ')?args.slice(6):null;
  const plan=args.startsWith('recovery-plan ')?args.slice(14):null;
  const structured=args.startsWith('scope-structured ')?args.slice(17):null;
  const moduleHistory=args.startsWith('history-module ')?args.slice(15):null;
  const exclusion=/^(exclusion-add|exclusion-remove) ([^ ]+) --apply$/.exec(args);
  const cooldown=/^cooldown-set ([0-9]+) --apply$/.exec(args);
  if(!read&&!write&&!(scope&&safePkg(scope))&&!(plan&&safeTarget(plan))&&args!=='history-capture'&&!(structured&&safePkg(structured))&&!(moduleHistory&&safePkg(moduleHistory))&&!(exclusion&&safePkg(exclusion[2]))&&!(cooldown&&COOLDOWNS.has(cooldown[1])))return Promise.reject(new Error('Command not permitted by WebUI'));
  if(!window.ksu||typeof window.ksu.exec!=='function')return Promise.reject(new Error('KernelSU bridge unavailable. Open WebUI from KernelSU.'));
  return new Promise((resolve,reject)=>{
    const cb=`__guardianUiCallback${++state.callbacks}`;let done=false;
    const cleanup=()=>{done=true;clearTimeout(timeout);delete window[cb]};
    const timeout=setTimeout(()=>{if(!done){cleanup();reject(new Error('Command timed out: '+args))}},45000);
    window[cb]=(code,stdout,stderr)=>{if(done)return;cleanup();if(Number(code)!==0)reject(new Error(`Command ${args} failed (${code}): ${String(stderr||stdout||'').slice(0,250)}`));else if(typeof stdout!=='string')reject(new Error('Incomplete KernelSU full-output response'));else resolve(stdout)};
    try{const ret=window.ksu.exec(`/system/bin/sh ${BASE} ${args}`,cb);if(typeof ret==='string'){cleanup();reject(new Error('Truncated synchronous KernelSU output rejected'))}}catch(e){if(!done)cleanup();reject(e)}
  });
}
function parseModules(raw){let invalid=0;const entries=[];for(const line of raw.split(/\r?\n/)){const trimmed=line.trim();if(!trimmed||/^PACKAGE\s+UID\s+STATUS$/i.test(trimmed)||/^-+$/.test(trimmed))continue;const m=line.match(MODULE_LINE);if(!m||!safePkg(m[1])){invalid++;continue}entries.push({pkg:m[1],uid:m[2],enabled:m[3].toLowerCase()==='enabled'})}if(invalid||!entries.length||new Set(entries.map(x=>x.pkg)).size!==entries.length)throw new Error('Vector inventory incomplete or unsupported');return entries.sort((a,b)=>a.pkg.localeCompare(b.pkg))}
function renderModules(){const root=$('modulelist');clear(root);if(!state.loaded){add(root,'p','Full Vector inventory unavailable.','empty');return}
 const enabled=state.modules.filter(m=>m.enabled).length;
 text('modules-total',state.modules.length);text('modules-summary',`${enabled} enabled · ${state.modules.length-enabled} disabled`);
 text('modulecount',`${state.modules.length} installed · ${enabled} enabled · ${state.modules.length-enabled} disabled`);
 text('modulewarning',state.expectedEnabled!==null&&enabled!==state.expectedEnabled?`Inventory mismatch: Vector reports ${state.expectedEnabled} enabled; listing has ${enabled}.`: '');
 const search=$('modulesearch').value.trim().toLowerCase(),filter=$('modulefilter').value;
 const filtered=state.modules.filter(m=>(filter==='all'||m.enabled===(filter==='enabled'))&&(!search||m.pkg.toLowerCase().includes(search)));
 if(!filtered.length){add(root,'p','No modules match the filters.','empty');return}
 const frag=document.createDocumentFragment();for(const mod of filtered){const entry=document.createElement('div');entry.className='module-entry';const btn=document.createElement('button');btn.type='button';btn.className='module-row';btn.setAttribute('aria-label',`Inspect ${mod.pkg} scopes`);const info=document.createElement('span');info.className='module-info';add(info,'strong',mod.pkg);add(info,'small',`UID ${mod.uid}`);btn.appendChild(info);add(btn,'span',mod.enabled?'Enabled':'Disabled',`module-state ${mod.enabled?'is-enabled':'is-disabled'}`);add(btn,'span','›','chevron');btn.addEventListener('click',()=>inspectModule(mod));entry.appendChild(btn);frag.appendChild(entry)}root.appendChild(frag);
}
async function inspectModule(mod){
 const panel=$('module-details');panel.hidden=false;text('scope-title',mod.pkg);text('modulescope','Reading explicit scopes…');
 panel.scrollIntoView?.({block:'nearest',behavior:'smooth'});const seq=++state.scopeSeq;
 fields('module-meta',[['Package',mod.pkg],['State',mod.enabled?'Enabled':'Disabled'],['UID',mod.uid],['Description','Not provided by Vector CLI']]);
 text('module-history','Loading checksum-verified samples…');
 const q=(state.raw['quarantine-status']||'').split(/\r?\n/).find(x=>/^(\s*(active|NEEDS_RECONCILIATION|ROLLBACK_NEEDS_RECONCILIATION):)/.test(x)&&x.includes(mod.pkg));
 text('module-quarantine',q?'Guardian quarantine: '+q.trim():'No Guardian quarantine recorded for this module.');
 if(!safePkg(mod.pkg)){text('modulescope','Invalid module identifier');return}
 try{
  const responses=await Promise.allSettled([command('scope-structured '+mod.pkg),command('history-module '+mod.pkg),command('scope '+mod.pkg)]);
  if(seq!==state.scopeSeq)return;
  const root=$('modulescope');clear(root);
  const structured=responses[0],history=responses[1],raw=responses[2];
  if(structured.status==='fulfilled'){
   const lines=structured.value.split(/\r?\n/),countLine=lines.find(x=>/^scope_count=\d+$/.test(x));
   const pairs=lines.filter(x=>x.startsWith('scope=')).map(x=>x.slice(6).split('|'));
   const count=countLine?Number(countLine.slice(12)):NaN;
   if(Number.isSafeInteger(count)&&count===pairs.length&&pairs.every(x=>x.length===2&&safePkg(x[0])&&/^\d+$/.test(x[1]))){
    fields('module-meta',[['Package',mod.pkg],['State',mod.enabled?'Enabled':'Disabled'],['UID',mod.uid],['Verified scope rows',count],['Description','Not provided by Vector CLI']]);
    if(count){const list=document.createElement('ul');list.className='scope-list';for(const pair of pairs)add(list,'li',pair[0]+' · user '+pair[1]);root.appendChild(list)}
    else add(root,'p','No explicit Vector scopes reported.','empty');
   }else add(root,'p','Malformed structured scope output; count unavailable.','warning');
  }else add(root,'p','Structured scope inspection unavailable: '+errorText(structured.reason),'warning');
  const moduleHistory=$('module-history');clear(moduleHistory);
  if(history.status==='fulfilled'){
   const observations=history.value.split(/\r?\n/).filter(x=>x.startsWith('module_observation='));
   if(observations.length){for(const item of observations.reverse()){
    const m=/^module_observation=(\d+)\|([01])\|(\d+)$/.exec(item);
    if(m)moduleHistory.appendChild(eventItem(m[2]==='1'?'Observed enabled':'Observed disabled',`${when(m[1])} · ${m[3]} scope rows`,'◷'));
    else add(moduleHistory,'p','Invalid observation; use technical diagnostics.','warning');
   }}else add(moduleHistory,'p','No retained historical samples.','empty');
  }else add(moduleHistory,'p','Historical sample verification unavailable: '+errorText(history.reason),'warning');
  if(raw.status==='fulfilled'){
   const details=document.createElement('details');add(details,'summary','Original Vector scope output');add(details,'pre',raw.value);root.appendChild(details);
  }
 }catch(e){if(seq===state.scopeSeq)text('modulescope','Scope lookup failed: '+errorText(e))}
}
function parseSamples(raw){const out=[];for(const line of raw.split(/\r?\n/)){const m=line.match(/boot=([a-fA-F0-9-]+)\s+sampled_epoch=(\d+)\s+enabled=(\d+)\s+scoped_rows=(\d+)\s+sha256=([a-fA-F0-9]+)/);if(m)out.push({boot:m[1],epoch:Number(m[2]),enabled:Number(m[3]),scoped:Number(m[4]),sha:m[5]})}return out}
function renderSamples(){
 const samples=parseSamples(state.raw.history||'');const root=$('sample-list');clear(root);
 const count=state.report?.historical_checkpoints;text('samples-count',Number.isSafeInteger(count)?`${count} / 512`:'Unavailable / 512');
 const v=state.kv['history-changes']||{},changed=$('verified-changes');clear(changed);
 const raw=state.raw['history-changes']||'';
 const verified=v.observation_changes==='NONE'||v.observation_changes==='DETECTED';
 if(verified){
  text('change-summary',v.observation_changes==='NONE'?'No detected changes between the last two verified snapshots.':'Verified differences between the last two snapshots:');
  const changes=raw.split(/\r?\n/).filter(x=>x.startsWith('observed_change='));
  if(changes.length)for(const line of changes){const [kind,...fields]=line.slice('observed_change='.length).split('|');changed.appendChild(eventItem(kind.replaceAll('_',' ').toLowerCase(),fields.join(' · ')+' · observed interval '+when(v.interval_start_epoch)+' to '+when(v.interval_end_epoch),'◷'))}
 }else text('change-summary','Cannot verify configuration changes: '+(v.observation_changes||'change diagnostic unavailable')+'. No conclusion about changes.');
 if(!samples.length){add(root,'p','No usable historical samples displayed.','empty');return}
 [...samples].reverse().forEach((sample,i)=>root.appendChild(eventItem(i===0?'Latest sampled configuration':'Observed configuration',`${when(sample.epoch)} · ${sample.enabled} enabled · ${sample.scoped} scope rows · SHA ${sample.sha.slice(0,12)}…`,'◷')));
}
function parseLedger(raw){
 const result=[];
 for(const line of String(raw||'').split(/\r?\n/)){
  const p=line.split('\t');if(p.length!==8||!/^\d{9,12}$/.test(p[2]))continue;
  result.push({kind:p[0],pkg:p[1],epoch:Number(p[2]),boot:p[3],vector:p[4],attribution:p[5],before:p[6],after:p[7]});
 }
 return result.sort((a,b)=>b.epoch-a.epoch).slice(0,50);
}
function renderActivity(){
 const root=$('events-list'),recent=$('recent-activity');clear(root);clear(recent);
 const r=state.report||{},h=state.kv['history-health']||{},a=state.kv['automatic-status']||{};
 const events=[['Vector and Guardian',r.boot_id&&r.last_stable_boot_id===r.boot_id?'Current boot verified stable':'Current boot not verified stable','◇',r.boot_id&&r.last_stable_boot_id===r.boot_id?'good':'warn'],
 ['Crash collector',r.collector_recent_poll===true?'Current-boot background poll healthy':`Background poll not verified · ${r.collector_last_poll_reason||'unknown'}`,r.collector_recent_poll===true?'✓':'!',''+(r.collector_recent_poll===true?'good':'warn')],
 ['Historical scope sampling',r.history_recent_poll===true?'Current-boot background poll healthy':`Background poll not verified · ${h.history_last_failure_reason||h.history_last_poll_result||'unknown'}`,r.history_recent_poll===true?'✓':'!',''+(r.history_recent_poll===true?'good':'warn')]];
 const ledger=parseLedger(state.raw['quarantine-ledger']);
 const qroot=$('quarantine-records');clear(qroot);
 if(ledger.length){for(const entry of ledger){
  const detail=`${when(entry.epoch)} · ${entry.pkg} · ${entry.attribution} · ${entry.before} → ${entry.after}`;
  qroot.appendChild(eventItem(entry.kind.replaceAll('_',' '),detail,'◷'));
  events.push([`Guardian ${entry.kind.toLowerCase()}`,detail,'◷','']);
 }}else add(qroot,'p','No parseable quarantine events. Use technical details if the journal is unavailable.','empty');
 text('quarantine-raw',(state.raw['quarantine-status']||'No status')+'\n\n'+(state.raw['quarantine-ledger']||'No ledger'));
 const v=state.kv['history-changes']||{};
 if(v.observation_changes==='DETECTED'){
  for(const line of String(state.raw['history-changes']||'').split(/\r?\n/).filter(x=>x.startsWith('observed_change=')).slice(-6)){
   const [kind,...parts]=line.slice('observed_change='.length).split('|');events.push([`Observed ${kind.replaceAll('_',' ').toLowerCase()}`,parts.join(' · ')+` · between ${when(v.interval_start_epoch)} and ${when(v.interval_end_epoch)}`,'◷','']);
  }
 }
 if(!ledger.length&&Number(r.quarantine_active)===0)events.push(['Guardian quarantine','No current quarantine records','✓','good']);
 for(const [title,detail,icon,kind] of events)root.appendChild(eventItem(title,detail,icon,kind));
 for(const [title,detail,icon,kind] of events.slice(0,3))recent.appendChild(eventItem(title,detail,icon,kind));
 const hfail=h.history_last_failure_reason||h.history_last_poll_result||'unknown';
 fields('sampler-fields',[['Current-boot background poll',r.history_recent_poll===true?'Healthy':'Unavailable / stale'],['Background last attempt',when(h.history_last_poll_epoch)],['Background last result',h.history_last_poll_result||'Unknown'],['Background failure stage',hfail],['Affected module',h.history_last_failure_module||'Not recorded'],['Last background success',when(h.history_last_background_success_epoch)],['Last manual or background capture',when(h.history_last_success_epoch)],['Last capture result',h.history_manual_or_background_capture_reason||'Not recorded']]);
 const warnings=[];
 if(r.history_recent_poll!==true)warnings.push(`Scope sampler needs attention (${hfail}). Automatic crash decisions require verified recent scopes.`);
 if(r.collector_recent_poll!==true)warnings.push('Crash collector heartbeat is not current.');
 if(r.vector_cli_available!==true)warnings.push('Vector CLI unavailable.');
 if(state.raw['automatic-status']?.startsWith('Unavailable:'))warnings.push('Protection configuration could not be verified.');
 if(r.snapshot_validation==='legacy_header_only')warnings.push('Historical recovery baseline is legacy-only; automatic SQLite recovery remains disabled.');
 text('attention',warnings.join(' '));
 fields('health-summary',[['Crash collector last background poll',when(r.collector_last_poll_epoch)],['Crash collector result',r.collector_last_poll_result||'Unavailable'],['Crash collector failure',r.collector_last_failure_reason||r.collector_last_poll_reason||'Not recorded'],['Scope sampler last background poll',when(h.history_last_poll_epoch)],['Scope sampler background result',h.history_last_poll_result||'Unavailable'],['Scope sampler failed module',h.history_last_failure_module||'Not recorded']]);
 renderSamples();
}
function renderProtection(){
 const r=state.report||{},a=state.kv['automatic-status']||{};
 const policyKnown=state.lastRefreshOk&&!state.raw['automatic-status']?.startsWith('Unavailable:')&&/^[01]$/.test(a.auto_quarantine||'')&&/^[01]$/.test(a.safe_mode_armed||'');
 const stable=!!r.boot_id&&r.boot_id===r.last_stable_boot_id;
 const collectorHealthy=r.collector_recent_poll===true&&state.raw['collector-health']&&!state.raw['collector-health'].startsWith('Unavailable:');
 const samplerHealthy=r.history_recent_poll===true&&state.raw['history-health']&&!state.raw['history-health'].startsWith('Unavailable:');
 const on=policyKnown&&a.auto_quarantine==='1',sm=policyKnown&&a.safe_mode_armed==='1',reboot=policyKnown&&a.auto_bootloop_reboot==='1';
 const vectorReady=r.vector_cli_available===true;
 const ready=!!(stable&&vectorReady&&collectorHealthy&&samplerHealthy&&r.passive_crash_monitor===true&&a.history_monitor_enabled==='1');
 const crashLabel=!policyKnown?'Unavailable':on?(ready?'Armed · evidence healthy':'Armed · action blocked until ready'):'Disabled';
 const bootOwner=a.safe_mode_owner==='ASHREXCUE_DEFERRED';
 const bootLabel=!policyKnown?'Unavailable':sm?(bootOwner?'Armed · deferred to AshReXcue':reboot?'Armed · watchdog on':'Armed · no watchdog'):'Disabled';
 text('crash-protection',crashLabel);statusClass($('crash-protection'),!policyKnown?'warn':on?(ready?'good':'warn'):null);
 text('boot-protection',bootLabel);statusClass($('boot-protection'),!policyKnown?'warn':sm&&bootOwner?'warn':sm?'good':null);
 text('auto-state',!policyKnown?'Unavailable':on?'Armed':'Off');statusClass($('auto-state'),!policyKnown?'warn':on?(ready?'good':'warn'):null);
 text('safe-state',!policyKnown?'Unavailable':sm?(bootOwner?'Deferred':'Armed'):'Off');statusClass($('safe-state'),!policyKnown?'warn':sm&&bootOwner?'warn':sm?'good':null);
 text('auto-detail',!policyKnown?'Effective root policy unavailable; actions are blocked.':`Crash response ${on?'armed':'off'} · scope and crash evidence ${ready?'fresh':'not fully verified'} · reboot watchdog ${reboot?'armed':'off'}`);
 text('safe-owner',!policyKnown?'Root policy unavailable.':bootOwner?'AshReXcue detected: Guardian defers platform bootloop action.':sm?'Guardian can mark Vector disabled on a qualifying failed boot.':'Bootloop fallback is not armed.');
 for(const [id,enabled] of [['arm',!on&&stable],['disarm',on||sm||reboot],['safe-arm',!sm&&stable],['safe-disarm',sm]])$(id).disabled=!policyKnown||!enabled||state.writing||state.refreshing;
 const cooldown=String(a.cooldown_seconds||'43200');$('cooldown').value=COOLDOWNS.has(cooldown)?cooldown:'43200';
 $('save-cooldown').disabled=!policyKnown||state.writing||state.refreshing;
 $('add-exclusion').disabled=!policyKnown||state.writing||state.refreshing;
 const n=state.kv['notifications-status']||{},nKnown=state.lastRefreshOk&&!state.raw['notifications-status']?.startsWith('Unavailable:')&&/^[01]$/.test(n.notifications_enabled||'');
 const notificationsOn=nKnown&&n.notifications_enabled==='1';
 text('notifications-state',!nKnown?'Unavailable':notificationsOn?'Enabled · delivery unverified':'Off');
 $('notifications-on').disabled=!nKnown||notificationsOn||state.writing||state.refreshing;
 $('notifications-off').disabled=!nKnown||!notificationsOn||state.writing||state.refreshing;
 $('notifications-test').disabled=!nKnown||!notificationsOn||state.writing||state.refreshing;
 fields('notification-details',[['Transport',n.notifications_transport||'Unknown'],['Last shell acceptance',when(n.notifications_last_accepted_epoch)],['Last transport failure',when(n.notifications_last_failure_epoch)],['Last result',n.notifications_last_result||'Not tested'],['Displayed on device','Requires manual confirmation']]);
 const excludes=policyKnown?String(a.crash_exclude_packages||'').split(',').filter(safePkg):[];
 const list=$('exclusion-list');clear(list);
 if(policyKnown){for(const pkg of [...new Set(excludes)]){
  const item=document.createElement('div');item.className='exclusion-row';add(item,'span',pkg);
  if(pkg!=='com.openai.chatgpt'){
   const del=add(item,'button','Remove','btn-secondary');del.type='button';del.setAttribute('aria-label','Remove exclusion '+pkg);del.disabled=state.writing||state.refreshing;
   del.addEventListener('click',()=>modify(`exclusion-remove ${pkg} --apply`,'Remove crash exclusion',`Crashes from ${pkg} may be considered in future automatic decisions.`));
  }else add(item,'small','Required');list.appendChild(item);
 }}else add(list,'p','Exclusion list unavailable until root policy is verified.','empty');
 fields('safeguard-summary',[['Module selection',a.policy==='all_scoped'?'All uniquely eligible scoped modules':a.policy==='allowlist'?'Explicit module allowlist':'Unavailable'],['One attempt per boot','Enforced by on-device transaction ledger'],['Minimum cooldown',policyKnown?Math.round(Number(a.cooldown_seconds)/3600)+' hours':'Unknown'],['Mandatory exclusion','com.openai.chatgpt']]);
 fields('policy-details',[['Policy',policyKnown?a.policy||'Unknown':'Unavailable'],['Crash action per boot','At most one attempt'],['Cooldown',policyKnown?`${Math.round(Number(a.cooldown_seconds)/3600)} hours`:'Unknown'],['Last action',when(a.last_action_epoch)],['Last module',a.last_action_module||'None'],['Boot watchdog',!policyKnown?'Unknown':reboot?'Armed':'Off'],['Safe-mode owner',a.safe_mode_owner||'Unknown'],['Vector disable marker',a.vector_disable_marker||'Unknown'],['Database auto-restore','Disabled']]);
 if(!state.lastRefreshOk)text('overall','Device status unavailable');
 else if(!vectorReady)text('overall','Vector unavailable');
 else if(!collectorHealthy&&!samplerHealthy)text('overall','Monitoring needs attention');
 else if(!samplerHealthy)text('overall','Scope monitoring needs attention');
 else if(!collectorHealthy)text('overall','Crash collector needs attention');
 else text('overall','Device monitoring healthy');
 text('overall-detail',`${stable?'Boot verified stable':'Boot not verified stable'} · ${vectorReady?'Vector CLI available':'Vector unavailable'} · ${!policyKnown?'Protection state unknown':on?'Crash protection armed':'Automatic crash response off'}`);
 fields('diagnostics',[['Version',r.version||'Unknown'],['Current boot',r.boot_id||'Unknown'],['Stable boot',stable?'Yes':'Unverified'],['Recorded crash events',r.stored_crash_events??'—'],['Recorded checkpoints',r.historical_checkpoints??'—'],['Quarantine pending',r.quarantine_pending??'—'],['Recovery qualification',r.qualification||'UNQUALIFIED'],['Collector last failure',r.collector_last_failure_reason||'None recorded']]);
}
async function refresh(){if(state.refreshing||state.writing)return;state.refreshing=true;$('refresh').disabled=true;text('message','Refreshing device state…');const request=++state.seq;
 try{const report=JSON.parse(await command('report'));if(!report||report.producer!=='lsposed-guardian')throw new Error('Unexpected diagnostic producer');state.report=report;state.lastRefreshOk=true;text('version',`v${report.version||'?'}`);
  const jobs=['automatic-status','history-health','collector-health','notifications-status','modules','qualification','integrity','doctor','history','history-changes','quarantine-status','quarantine-ledger','crash-audit'];
  const settled=await Promise.allSettled(jobs.map(cmd=>command(cmd)));if(request!==state.seq)return;let errors=[];
  settled.forEach((s,i)=>{const key=jobs[i];if(s.status==='fulfilled'){state.raw[key]=s.value;state.kv[key]=kv(s.value)}else{state.raw[key]=`Unavailable: ${errorText(s.reason)}`;state.kv[key]={};errors.push(key)}});
  try{state.modules=parseModules(state.raw.modules);state.loaded=true;state.expectedEnabled=Number(state.raw.doctor.match(/Enabled Modules:\s*(\d+)/i)?.[1]??NaN);if(!Number.isFinite(state.expectedEnabled))state.expectedEnabled=null}catch(e){state.loaded=false;state.modules=[];text('modulewarning',state.raw.modules?.startsWith('Unavailable:')?state.raw.modules:errorText(e))}
  renderModules();text('quarantine',report.quarantine_active??0);text('pending',`${report.quarantine_pending??0} pending`);
  text('collector',report.collector_recent_poll?'Healthy':'Needs attention');statusClass($('collector'),report.collector_recent_poll?'good':'warn');text('collector-detail',report.collector_recent_poll?'Current-boot heartbeat':report.collector_last_poll_reason||'No current poll');
  text('sampler',report.history_recent_poll?'Healthy':'Needs attention');statusClass($('sampler'),report.history_recent_poll?'good':'warn');text('sampler-detail',report.history_recent_poll?'Current-boot heartbeat':state.kv['history-health'].history_last_failure_reason||'Not verified');
  text('gates',state.raw.qualification);text('integrity',state.raw.integrity);text('doctor',state.raw.doctor);text('crash-audit',state.raw['crash-audit']);text('automatic-raw',state.raw['automatic-status']);
  renderProtection();renderActivity();text('updated',`Last refreshed ${new Date().toLocaleTimeString()}`);text('message',state.lastActionNotice || (errors.length?`Partial refresh: ${errors.length} unavailable diagnostics (${errors.join(', ')}).`:'Device state refreshed.'));state.lastActionNotice='';
 }catch(e){state.lastRefreshOk=false;state.error=errorText(e);text('overall','Connection unavailable');text('updated','Last refresh failed · earlier data may be stale');text('message',`Cannot refresh Guardian: ${state.error}`)}finally{state.refreshing=false;$('refresh').disabled=false;renderProtection()}}
const REVIEW_REASONS={
 INSUFFICIENT_CRASH_EVIDENCE:'Fewer than three recent crash events were retained for this process.',
 INSUFFICIENT_DISTINCT_PROCESSES:'Crashes do not involve at least two distinct process IDs.',
 HISTORICAL_COVERAGE_MISSING:'No sufficiently recent same-boot historical scope observation for every crash.',
 HISTORICAL_CHECKPOINT_INVALID:'One or more historical scope checkpoints failed validation.',
 MULTIPLE_SCOPED_CANDIDATES:'More than one enabled module matched a historical scope.',
 NO_EXPLICIT_SCOPED_CANDIDATES:'No explicitly scoped enabled module matched.',
 INCONSISTENT_HISTORICAL_CANDIDATES:'The uniquely scoped module changed across the crash evidence.',
 CURRENT_VECTOR_STATE_UNAVAILABLE:'Current Vector module/scope state could not be verified.',
 CONFIGURATION_CHANGED_SINCE_CRASH:'Current Vector module or scopes no longer match observations before the crashes.',
 EXCLUDED_BY_USER:'This process is excluded from crash-based automatic decisions.',
 REVIEW_SINGLE_SCOPED_MODULE:'One module qualifies for manual review only; the scope is not proof of causation.'
};
async function analyze(){const target=$('target').value.trim();if(!safeTarget(target)){text('analysis','Invalid package or process identifier');return} $('analyze').disabled=true;text('analysis','Reading historical scope evidence…');try{const raw=await command('recovery-plan '+target);text('analysis',raw);const v=kv(raw);fields('analysis-summary',[['Process',target],['Recent crash events',v.recent_crash_count??'Not reported'],['Distinct PIDs',v.distinct_process_count??'Not reported'],['Last matched scopes',v.last_matched_scope_count??'Not determined'],['Refusal / review reason',REVIEW_REASONS[v.decision]||'No supported determination'],['Decision',(v.decision||'Unknown').replaceAll('_',' ').toLowerCase()],['Candidate',v.candidate||'None (no action)'],['Next step',v.next_step||'Review only'],['Offline recovery',v.offline_recovery||'Not qualified'],['Causality','Not established']])}catch(e){text('analysis',errorText(e));fields('analysis-summary',[['Status','Unavailable'],['Reason',errorText(e)]])}finally{$('analyze').disabled=false}}
async function modify(args,heading,warning){
 if(state.writing||state.refreshing)return;
 if(typeof window.confirm!=='function'||!window.confirm(`${heading}\n\n${warning}`))return;
 state.writing=true;for(const id of ['arm','disarm','safe-arm','safe-disarm','save-cooldown','add-exclusion','notifications-on','notifications-off','notifications-test'])$(id).disabled=true;
 text('message',`Applying: ${heading}…`);
 try{const result=await command(args);state.lastActionNotice=`${heading}: command returned ${result.trim().split(/\r?\n/)[0]||'success'}. Effective policy refreshed below.`}
 catch(e){state.lastActionNotice=`${heading} failed: ${errorText(e)}. Check effective policy.`}
 finally{state.writing=false;await refresh()}
}
function copyDiagnostics(){const payload=JSON.stringify({report:state.report,qualification:state.raw.qualification,integrity:state.raw.integrity,automatic_policy:state.raw['automatic-status'],history_health:state.raw['history-health'],crash_audit:state.raw['crash-audit']},null,2);if(navigator.clipboard?.writeText){navigator.clipboard.writeText(payload).then(()=>text('message','Diagnostics copied.'),()=>text('message','Clipboard denied; use technical details.'))}else{text('message','Clipboard unavailable in this WebView; use technical details.') }}
function activityView(tab){const samples=tab==='samples';$('samples-pane').hidden=!samples;$('events-pane').hidden=samples;document.querySelectorAll('[data-activity]').forEach(b=>b.classList.toggle('selected',b.dataset.activity===tab))}
document.querySelectorAll('.bottom-nav button').forEach(b=>b.addEventListener('click',()=>show(b.dataset.tab)));
document.querySelectorAll('[data-navigate]').forEach(b=>b.addEventListener('click',()=>show(b.dataset.navigate)));
document.querySelectorAll('[data-activity]').forEach(b=>b.addEventListener('click',()=>activityView(b.dataset.activity)));
$('open-protection').addEventListener('click',()=>show('settings'));
$('view-sampler').addEventListener('click',()=>{show('activity');activityView('samples')});
$('refresh').addEventListener('click',refresh);$('modulesearch').addEventListener('input',renderModules);$('modulefilter').addEventListener('change',renderModules);$('close-scopes').addEventListener('click',()=>{$('module-details').hidden=true});$('analyze').addEventListener('click',analyze);
$('arm').addEventListener('click',()=>modify('automatic-on --apply','Enable automatic protection','Guardian may disable a uniquely eligible module and may request a bounded emergency bootloop fallback. Modules disabled previously are not automatically restored.'));
$('disarm').addEventListener('click',()=>modify('automatic-off','Disarm all automatic actions','Future automatic responses will stop. Existing quarantine journals and safe-mode disable markers remain.'));
$('safe-arm').addEventListener('click',()=>modify('safe-mode-arm --apply','Enable bootloop fallback','If repeated boots fail, Guardian may disable the KernelSU Vector module on a later boot. AshReXcue owns boot protection when installed.'));
$('safe-disarm').addEventListener('click',()=>modify('safe-mode-disarm','Disable bootloop fallback','This does not remove an already-created Vector disable marker.'));
$('retry-sampler').addEventListener('click',async()=>{if(state.writing||state.refreshing)return;state.writing=true;$('retry-sampler').disabled=true;try{await command('history-capture');text('message','Read-only sample captured. The background polling heartbeat is independent.')}catch(e){text('message','Read-only capture failed: '+errorText(e))}finally{state.writing=false;$('retry-sampler').disabled=false;await refresh()}});
$('notifications-on').addEventListener('click',()=>modify('notifications-on --apply','Enable notifications','Best-effort Android notifications may fail on some ROMs. Send a test after activation.'));
$('notifications-off').addEventListener('click',()=>modify('notifications-off','Disable notifications','Guardian event journals remain on-device.'));
$('notifications-test').addEventListener('click',()=>modify('notifications-test --apply','Send test notification','Check the Android notification shade manually; shell acceptance does not prove delivery.'));
$('save-cooldown').addEventListener('click',()=>{const s=$('cooldown').value;if(!COOLDOWNS.has(s))return;text('message','Invalid cooldown');modify(`cooldown-set ${s} --apply`,'Update quarantine cooldown',`Change the minimum interval between automatic interventions to ${Math.round(Number(s)/3600)} hours.`)});
$('add-exclusion').addEventListener('click',()=>{const pkg=$('exclude-target').value.trim();if(!safePkg(pkg)){text('message','Invalid Android package identifier');return}modify(`exclusion-add ${pkg} --apply`,'Add crash exclusion',`Guardian will ignore ${pkg} crash events in future auto decisions.`)});
$('retry-collector').addEventListener('click',async()=>{if(state.writing||state.refreshing)return;state.writing=true;$('retry-collector').disabled=true;try{const result=await command('collect');state.lastActionNotice='One-time crash collection completed: '+result.trim().slice(0,180)+'. Background collector health is separate.'}catch(e){state.lastActionNotice='Crash collection failed: '+errorText(e)}finally{state.writing=false;$('retry-collector').disabled=false;await refresh()}});
$('show-technical').addEventListener('click',()=>{$('technical').hidden=!$('technical').hidden;text('show-technical',$('technical').hidden?'Show technical details':'Hide technical details')});$('copy-diagnostics').addEventListener('click',copyDiagnostics);
refresh();
