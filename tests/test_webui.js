'use strict';
// Hermetic KernelSU WebUI regression: guarded root actions, responsive inventory,
// callback-only multiline bridge, independent subsystem health, and diagnostics.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const ROOT=path.join(__dirname,'..');
const html=fs.readFileSync(path.join(ROOT,'webroot/index.html'),'utf8');
const js=fs.readFileSync(path.join(ROOT,'webroot/main.js'),'utf8');
const ids=[...html.matchAll(/\bid="([a-z][a-z0-9-]*)"/g)].map(m=>m[1]);
assert.equal(new Set(ids).size,ids.length,'duplicate HTML id');
function element(id=''){
 const e={id,dataset:{},className:'',textContent:'',value:'',hidden:false,disabled:false,children:[],listeners:{},attributes:{},
  append(...args){this.children.push(...args)},appendChild(child){if(child.fragment)this.children.push(...child.children);else this.children.push(child);return child},
  replaceChildren(){this.children=[];this.textContent=''},setAttribute(k,v){this.attributes[k]=v},
  addEventListener(name,fn){this.listeners[name]=fn},scrollIntoView(){}};
 e.classList={toggle(k,on){if(on)e.className+=' '+k;else e.className=e.className.replace(k,'')},add(k){e.className+=' '+k},remove(...a){for(const k of a)e.className=e.className.replace(k,'')}};
 return e;
}
const inventory=[...Array.from({length:8},(_,i)=>`mod.enabled${i+1}  ${10000+i} enabled`),...Array.from({length:12},(_,i)=>`mod.disabled${i+1} ${10100+i} disabled`)].join('\n');
const report={producer:'lsposed-guardian',version:'0.12.1',boot_id:'aa-bb',last_stable_boot_id:'aa-bb',vector_cli_available:true,historical_checkpoints:56,stored_crash_events:8,history_recent_poll:false,collector_recent_poll:true,quarantine_active:0,quarantine_pending:0,automatic_quarantine_enabled:false,snapshot_validation:'legacy_header_only',qualification:'UNQUALIFIED'};
const outputs={report:JSON.stringify(report),modules:`PACKAGE UID STATUS\n--------------------\n${inventory}`,
 doctor:'Boot stable\nEnabled Modules: 8\n',qualification:'qualification=UNQUALIFIED\nactual_early_boot_restore_test=PASS_MANUAL_ONE_SHOT_RECEIPT',integrity:'baseline=legacy_header_only\n',
 'automatic-status':'auto_quarantine=0\nsafe_mode_armed=0\nauto_bootloop_reboot=0\nsafe_mode_owner=ASHREXCUE_DEFERRED\ncooldown_seconds=43200\ncrash_exclude_packages=com.openai.chatgpt,org.example.excluded\nhistory_monitor_enabled=1\npolicy=all_scoped\n',
 'history-changes':'interval_start_epoch=1793284661\ninterval_end_epoch=1793284800\nobservation_changes=NONE\n',
 'history-health':'history_recent_poll=no\nhistory_last_poll_result=error\nhistory_last_poll_epoch=1793369477\nhistory_last_failure_reason=vector_scope_unavailable\nhistory_last_failure_module=mod.enabled3\n',
 'collector-health':'collector_recent_poll=yes\n',
 'notifications-status':'notifications_enabled=0\nnotifications_transport=unavailable\nnotifications_last_result=unavailable_or_rejected\n',
 history:'Historical observations:\n boot=aa-bb sampled_epoch=1793284661 enabled=8 scoped_rows=19 sha256=abcde1234\n boot=aa-bb sampled_epoch=1793284800 enabled=8 scoped_rows=19 sha256=abcde1234\n',
 'quarantine-status':'Manual quarantine records\n(none)', 'quarantine-ledger':'QUARANTINED\tmod.alpha\t1793284800\taa-bb\t220\tAUTO_CORRELATED_NOT_CAUSAL\tactive\tdisabled',
 'crash-audit':'retained_events=8\nhistory_state=PRESENT',
 'scope mod.enabled1':'APP_PACKAGE\ncom.android.systemui\n',
 'scope-structured mod.enabled1':'scope_count=1\nscope=com.android.systemui|0\n',
 'history-module mod.enabled1':'module_observation=1793284800|1|1\n',
 'recovery-plan com.android.systemui':'decision=INSUFFICIENT_CRASH_EVIDENCE\nrecent_crash_count=2\ndistinct_process_count=1\nnext_step=NO_MODULE_ACTION\n',
 'history-capture':'PASS',
 'cooldown-set 86400 --apply':'cooldown_seconds=86400',
 'exclusion-add org.example.test --apply':'crash_exclude_packages=com.openai.chatgpt,org.example.test',
 'exclusion-remove org.example.excluded --apply':'crash_exclude_packages=com.openai.chatgpt',
 'collect':'Stored crash events: 8',
 'notifications-on --apply':'notifications_enabled=1',
 'notifications-off':'notifications_enabled=0',
 'notifications-test --apply':'Shell accepted test notification',
 'automatic-on --apply':'PASS_GUARDIAN_AUTOMATIC_MODE_ARMED',
 'automatic-off':'PASS_GUARDIAN_AUTOMATIC_MODE_DISARMED',
 'safe-mode-arm --apply':'AUTO_SAFE_MODE=1',
 'safe-mode-disarm':'AUTO_SAFE_MODE=0'};
const delay=()=>new Promise(resolve=>setTimeout(resolve,35));
async function exercise(bridge,allowConfirmation=true){
 const map=Object.fromEntries(ids.map(id=>[id,element(id)]));map.modulefilter.value='all';map.target.value='com.android.systemui';map.technical.hidden=true;map['module-details'].hidden=true;map['samples-pane'].hidden=true;
 const nav=[...html.matchAll(/data-tab="([^"]+)"/g)].map(m=>{const e=element();e.dataset.tab=m[1];return e});
 const screens=['home','modules','activity','review','settings'].map(id=>map[id]);
 const views=['events','samples'].map(a=>{const e=element();e.dataset.activity=a;return e});
 const go=[element()];go[0].dataset.navigate='settings';
 const document={getElementById(id){assert.ok(map[id],`missing element ${id}`);return map[id]},
  querySelectorAll(sel){if(sel==='.bottom-nav button')return nav;if(sel==='.screen')return screens;if(sel==='[data-activity]')return views;if(sel==='[data-navigate]')return go;throw Error('selector: '+sel)},
  createElement(tag){const e=element();e.tagName=tag;return e},createDocumentFragment(){const e=element();e.fragment=true;return e}};
 let confirmCount=0;const calls=[];const window={scrollTo(){},confirm(){confirmCount++;return allowConfirmation},ksu:{exec(cmd,cb){calls.push(cmd);return bridge(window,cmd,cb)}}};
 const context={window,document,navigator:{clipboard:{writeText:async()=>{}}},setTimeout,clearTimeout,console,Promise,Error,Number,String,Set,Date};
 vm.runInNewContext(js,context,{filename:'main.js'});await delay();await delay();
 return {map,nav,window,calls,confirmCount:()=>confirmCount,views};
}
(async()=>{
 const bridge=(w,cmd,cb)=>{assert.equal(typeof cb,'string');const key=cmd.split('guardian.sh ')[1];queueMicrotask(()=>w[cb](0,outputs[key]||'', ''));return null};
 let t=await exercise(bridge);
 assert.equal(t.map.modulecount.textContent,'20 installed · 8 enabled · 12 disabled');
 assert.equal(t.map['modules-total'].textContent,'20');
 assert.equal(t.map['sampler'].textContent,'Needs attention');
 assert.equal(t.map.collector.textContent,'Healthy');
 assert.match(t.map.attention.textContent,/vector_scope_unavailable/);
 assert.match(t.map['sampler-fields'].children[0].children[1].textContent,/Unavailable/);
 assert.equal(t.map['crash-protection'].textContent,'Disabled');
 assert.equal(t.calls.some(c=>c.includes('automatic-on --apply')),false,'no auto arming on load');
 assert.equal(t.map.modulelist.children.length,20,'20 compact module rows');
 t.map.modulesearch.value='enabled1';t.map.modulesearch.listeners.input();assert.equal(t.map.modulelist.children.length,1);
 t.map.modulesearch.value='';t.map.modulefilter.value='disabled';t.map.modulefilter.listeners.change();assert.equal(t.map.modulelist.children.length,12);
 t.map.modulefilter.value='all';t.map.modulefilter.listeners.change();t.map.modulelist.children.find(e=>e.children[0].children[0].children[0].textContent==='mod.enabled1').children[0].listeners.click();await delay();assert.ok(t.map.modulescope.children.length>0,'scope loaded');
 assert.ok(t.calls.some(c=>c.includes('scope mod.enabled1')));
 assert.ok(t.calls.some(c=>c.includes('scope-structured mod.enabled1')));
 assert.ok(t.calls.some(c=>c.includes('history-module mod.enabled1')));
 assert.match(t.map['module-history'].children[0].children[1].children[1].textContent,/scope rows/);
 t.map['show-technical'].listeners.click();assert.equal(t.map.technical.hidden,true===false);
 t.map['show-technical'].listeners.click();assert.equal(t.map.technical.hidden,true);
 assert.match(t.map['change-summary'].textContent,/No detected changes/);
 assert.equal(t.map['quarantine-records'].children.length,1,'structured quarantine ledger');
 assert.match(t.map['module-quarantine'].textContent,/No Guardian quarantine/);
 assert.match(t.map['exclusion-list'].children[0].children[0].textContent,/com.openai.chatgpt/);
 assert.equal(t.map['save-cooldown'].disabled,false);
 assert.equal(t.map['notifications-state'].textContent,'Off');
 t.map['notifications-on'].listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith('notifications-on --apply')));
 t.map.cooldown.value='86400';t.map['save-cooldown'].listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith('cooldown-set 86400 --apply')));
 t.map['exclude-target'].value='org.example.test';t.map['add-exclusion'].listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith('exclusion-add org.example.test --apply')));
 t.map['retry-collector'].listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith(' collect')));
 t.map['view-sampler'].listeners.click();assert.equal(t.map['samples-pane'].hidden,false);
 t.map['exclude-target'].value='invalid;reboot';t.map['add-exclusion'].listeners.click();await delay();assert.equal(t.calls.some(c=>c.includes('invalid;reboot')),false);
 assert.match(t.map.gates.textContent,/PASS_MANUAL_ONE_SHOT/);
 assert.equal(t.map.disarm.disabled,true);
 t.map.arm.listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith('automatic-on --apply')));assert.equal(t.confirmCount(),4);
 t.map['retry-sampler'].listeners.click();await delay();await delay();assert.ok(t.calls.some(c=>c.endsWith('history-capture')));
 t.map.analyze.listeners.click();await delay();assert.match(t.map.analysis.textContent,/INSUFFICIENT/);
 assert.match(t.map['analysis-summary'].children[1].children[1].textContent,/2/);
 t.map.target.value='com.foo; reboot';t.map.analyze.listeners.click();assert.match(t.map.analysis.textContent,/Invalid/);
 const cancelled=await exercise(bridge,false);cancelled.map.arm.listeners.click();await delay();assert.equal(cancelled.calls.some(c=>c.includes('automatic-on --apply')),false);
 const mismatch=await exercise((w,cmd,cb)=>{const key=cmd.split('guardian.sh ')[1];queueMicrotask(()=>w[cb](0,key==='modules'?'PACKAGE UID STATUS\nmod.single 30000 enabled\n':outputs[key]||'',''));return null});
 assert.match(mismatch.map.modulewarning.textContent,/Inventory mismatch/);
 const unknown=await exercise((w,cmd,cb)=>{const key=cmd.split('guardian.sh ')[1];queueMicrotask(()=>w[cb](key==='automatic-status'?1:0,outputs[key]||'',key==='automatic-status'?'Unable to read policy':''));return null});
 assert.equal(unknown.map['crash-protection'].textContent,'Unavailable');assert.equal(unknown.map.arm.disabled,true,'cannot arm with unknown policy');
 const unverified=await exercise((w,cmd,cb)=>{const key=cmd.split('guardian.sh ')[1];queueMicrotask(()=>w[cb](key==='history-changes'?1:0,outputs[key]||'',key==='history-changes'?'corrupt checkpoint':''));return null});
 assert.match(unverified.map['change-summary'].textContent,/Cannot verify/);
 const bad=await exercise(()=> 'LAST_LINE_ONLY');assert.match(bad.map.message.textContent,/Cannot refresh Guardian/);
 const fail=await exercise((w,cmd,cb)=>{const key=cmd.split('guardian.sh ')[1];queueMicrotask(()=>w[cb](key==='modules'?1:0,outputs[key]||'',key==='modules'?'Vector unavailable':''));return null});
 assert.match(fail.map.modulewarning.textContent,/Command modules failed/);
 console.log('PASS_WEBUI_AUDIT_SCOPE_COUNTS_HISTORY_POLICY_NOTIFICATIONS');
 console.log('PASS_WEBUI_V012_PROTECTION_DASHBOARD');
 console.log('PASS_WEBUI_V012_SPLIT_COLLECTOR_AND_SAMPLER');
 console.log('PASS_WEBUI_V012_20_MODULES_AND_SCOPES');
 console.log('PASS_WEBUI_V012_HISTORY_CHANGE_DEDUP');
 console.log('PASS_WEBUI_V012_GUARDED_ROOT_WRITES');
 console.log('PASS_WEBUI_V012_DIAGNOSTICS_AND_REVIEW');
 console.log('PASS_WEBUI_V012_FAIL_CLOSED_BRIDGE_AND_INVENTORY');
})().catch(e=>{console.error(e);process.exitCode=1});
