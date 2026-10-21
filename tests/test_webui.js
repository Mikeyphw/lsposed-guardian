'use strict';
// Hermetic regression for KernelSU full-output callback, counts, filtering, errors.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../webroot/main.js'), 'utf8');

function element(id='') {
  return {
    id, value:'', textContent:'', disabled:false, children:[], className:'', dataset:{},
    classList:{toggle(){}}, listeners:{},
    append(...items){this.children.push(...items)},
    appendChild(item){this.children.push(item)},
    replaceChildren(){this.children=[];this.textContent=''},
    addEventListener(type,handler){this.listeners[type]=handler},
    setAttribute(name,value){this[name]=value}
  };
}
const tick = async () => new Promise(resolve=>setTimeout(resolve,10));
async function exercise(bridge) {
  const ids = [
    'message','refresh','version','mode','qual','samples','historyhealth','collector',
    'quarantine','pending','modulelist','modulecount','modulewarning',
    'modulefilter','modulesearch','modulescope','gates','integrity','doctor','qstatus','hist','heartbeat',
    'target','analyze','analysis'
  ];
  const map = Object.fromEntries(ids.map(id=>[id,element(id)]));
  map.modulefilter.value='all';
  const tabs=[element('tab')];
  const sections=[element('section')];
  const document = {
    getElementById(id){if(!map[id]) throw Error('Unknown element: '+id);return map[id]},
    querySelectorAll(sel){return sel.includes('tabs')?tabs:sections},
    createElement:()=>element(),
    createDocumentFragment:()=>element()
  };
  const window = {ksu:{exec(command,name){return bridge(window,command,name)}}};
  const context = {window,document,setTimeout,clearTimeout,console,Promise,Error,Number,String,Set};
  vm.runInNewContext(source,context,{filename:'main.js'});
  await tick();
  await tick();
  return {map,window};
}
const inventory = [
  ...Array.from({length:8},(_,i)=>`mod.enabled${i+1}     ${10000+i}  enabled`),
  ...Array.from({length:12},(_,i)=>`mod.disabled${i+1}   ${10100+i}  disabled`)
].join('\n');
const outputs = {
  report: JSON.stringify({version:'0.8.0',historical_checkpoints:56,history_recent_poll:true,collector_recent_poll:true}),
  modules: `PACKAGE UID STATUS\n------------------\n${inventory}\n`,
  doctor: 'Boot stable\nEnabled Modules: 8\nCurrent status: healthy\n',
  qualification: 'sandbox_restore_lab=PASS\nsandbox_quarantine_lab=PASS\nqualification=UNQUALIFIED\n',
  'scope mod.enabled1': 'APP_PACKAGE\ncom.android.systemui\n',
  integrity: 'baseline=legacy_header_only\nobserved=sqlite_integrity_verified\n',
  'quarantine-status':'Manual quarantine records\n(none)\n',
  history:'sample 1\nsample 2\nsample 3\n',
  'history-health':'history_recent_poll=yes\nstatus=ok\n'
};
(async()=>{
  const bridge = (window, command, cbName) => {
    assert.equal(typeof cbName,'string','must use asynchronous callback');
    const match=command.match(/guardian\.sh (.*)$/);
    const cmd=match?.[1];
    queueMicrotask(()=>window[cbName](0,outputs[cmd] || '', ''));
    return null;
  };
  const {map} = await exercise(bridge);
  assert.equal(map.modulecount.textContent,'20 installed · 8 enabled · 12 disabled');
  assert.equal(map.modulelist.children.length,1);
  assert.equal(map.modulelist.children[0].children.length,20);
  assert.equal(map.hist.textContent,'sample 1\nsample 2\nsample 3\n');
  assert.match(map.doctor.textContent,/Boot stable\nEnabled Modules: 8/);
  assert.equal(map.modulewarning.textContent,'');
  assert.match(map.gates.textContent,/qualification=UNQUALIFIED/);
  map.modulesearch.value='mod.enabled1'; map.modulesearch.listeners.input();
  map.modulelist.children[0].children[0].children[2].listeners.click();
  map.modulesearch.value=''; map.modulesearch.listeners.input();
  await tick();
  assert.match(map.modulescope.textContent,/com.android.systemui/);
  map.modulefilter.value='enabled';map.modulefilter.listeners.change();
  assert.equal(map.modulelist.children[0].children.length,8);
  map.modulefilter.value='disabled';map.modulefilter.listeners.change();
  assert.equal(map.modulelist.children[0].children.length,12);
  map.modulefilter.value='all';map.modulesearch.value='enabled1';map.modulesearch.listeners.input();
  assert.equal(map.modulelist.children[0].children.length,1);
  // Older one-arg last-line response must fail closed; never misrepresent 1 row as inventory.
  const bad=await exercise((_window,_command,_cb)=>'only final line');
  assert.match(bad.map.message.textContent,/Cannot load Guardian/);
  assert.equal(bad.map.modulelist.children.length,0);
  const mismatch=await exercise((window,cmd,name)=>{
    const sub=cmd.split('guardian.sh ')[1];
    queueMicrotask(()=>window[name](0,sub==='modules' ? `PACKAGE UID STATUS\nmod.single 30000 enabled\n` : outputs[sub],''));
    return null;
  });
  assert.match(mismatch.map.modulewarning.textContent,/Inventory mismatch/);
  const failure=await exercise((window,cmd,name)=>{
    const sub=cmd.split('guardian.sh ')[1];
    queueMicrotask(()=>window[name](sub==='modules'?1:0,outputs[sub] || '',sub==='modules'?'Vector unavailable':''));
    return null;
  });
  assert.equal(failure.map.modulecount.textContent,'Inventory unavailable');
  assert.match(failure.map.modulewarning.textContent,/Command failed/);
  console.log('PASS_WEBUI_SCOPE_INSPECTION_READ_ONLY');
  console.log('PASS_WEBUI_QUALIFICATION_GATES_VISIBLE');
  console.log('PASS_WEBUI_FULL_MULTILINE_20_MODULES');
  console.log('PASS_WEBUI_ENABLED_DISABLED_FILTERS');
  console.log('PASS_WEBUI_HISTORY_MULTILINE');
  console.log('PASS_WEBUI_REFUSES_TRUNCATED_SYNC_RESULT');
  console.log('PASS_WEBUI_DETECTS_INVENTORY_MISMATCH');
  console.log('PASS_WEBUI_REFUSES_FAILED_MODULE_LIST');
})().catch(e=>{console.error(e);process.exitCode=1});
