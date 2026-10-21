'use strict';
// Guardian WebUI: read-only, no network, no arbitrary shell input, no HTML from root.
// KernelSU's ksu.exec(cmd) calls ShellUtils.fastCmd and returns ONLY THE LAST LINE.
// Always use the callback overload ksu.exec(cmd, callbackName) for multiline output.
const BASE = '/data/adb/modules/lsposed_guardian/guardian.sh';
const $ = id => document.getElementById(id);
const tasks = [
  ['gates', 'qualification'], ['integrity', 'integrity'], ['doctor', 'doctor'],
  ['qstatus', 'quarantine-status'], ['hist', 'history'],
  ['heartbeat', 'history-health']
];
let sequence = 0;
let refreshInProgress = false;
let modules = [];
let modulesLoaded = false;
let expectedEnabled = null;
const MODULE_LINE = /^\s*([a-zA-Z0-9_.-]+)\s+(\d+)\s+(enabled|disabled)\s*$/i;

function setStatus(message) { $('message').textContent = message; }
function errorDescription(error) { return String(error && error.message || error).slice(0, 240); }
function command(args) {
  if (!window.ksu || typeof window.ksu.exec !== 'function') {
    return Promise.reject(new Error('KernelSU WebUI bridge unavailable. Open from KernelSU manager.'));
  }
  // Every command is constant except a separately validated package identifier.
  return new Promise((resolve, reject) => {
    const callbackName = `__guardianExecCallback${++sequence}`;
    let finished = false;
    const cleanup = () => {
      finished = true;
      clearTimeout(timeout);
      delete window[callbackName];
    };
    const timeout = setTimeout(() => {
      if (finished) return;
      cleanup();
      reject(new Error(`Full-output command timed out: ${args}`));
    }, 45000);
    window[callbackName] = (exitCode, stdout, stderr) => {
      if (finished) return;
      cleanup();
      if (Number(exitCode) !== 0) {
        reject(new Error(`Command failed (${exitCode}): ${String(stderr || stdout || '').slice(0, 200)}`));
      } else if (typeof stdout !== 'string') {
        reject(new Error('KernelSU callback did not return stdout text'));
      } else {
        resolve(stdout);
      }
    };
    try {
      // Two-argument bridge overload supplies ALL lines and the real exit code.
      const returned = window.ksu.exec(`/system/bin/sh ${BASE} ${args}`, callbackName);
      if (typeof returned === 'string') {
        cleanup();
        reject(new Error('KernelSU full-output callback unsupported; refusing truncated synchronous output'));
      }
    } catch (error) {
      if (!finished) cleanup();
      reject(error);
    }
  });
}
function parseModuleList(raw) {
  const entries = [];
  let unrecognized = 0;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || /^PACKAGE\s+UID\s+STATUS$/i.test(trimmed) || /^-+$/.test(trimmed)) continue;
    const match = line.match(MODULE_LINE);
    if (!match) { unrecognized++; continue; }
    entries.push({pkg: match[1], uid: match[2], enabled: match[3].toLowerCase() === 'enabled'});
  }
  if (unrecognized || entries.length === 0 || new Set(entries.map(x => x.pkg)).size !== entries.length) {
    throw new Error('Vector module output was incomplete or unsupported; inventory not displayed');
  }
  return entries.sort((a, b) => a.pkg.localeCompare(b.pkg));
}
function renderModules() {
  const root = $('modulelist');
  root.replaceChildren();
  if (!modulesLoaded) { root.textContent = 'Module inventory has not loaded.'; return; }
  const filter = $('modulefilter').value;
  const search = $('modulesearch').value.trim().toLowerCase();
  const filtered = modules.filter(item =>
    (filter === 'all' || (filter === 'enabled') === item.enabled) &&
    (!search || item.pkg.toLowerCase().includes(search))
  );
  $('modulecount').textContent = `${modules.length} installed · ${modules.filter(x => x.enabled).length} enabled · ${modules.filter(x => !x.enabled).length} disabled`;
  if (expectedEnabled !== null && modules.filter(x => x.enabled).length !== expectedEnabled) {
    $('modulewarning').textContent = `Inventory mismatch: Vector status reports ${expectedEnabled} enabled; listing reports ${modules.filter(x => x.enabled).length}. Treat inventory as unverified.`;
  } else {
    $('modulewarning').textContent = '';
  }
  if (!filtered.length) { root.textContent = 'No modules match these filters.'; return; }
  const fragment = document.createDocumentFragment();
  for (const item of filtered) {
    const entry = document.createElement('div');
    entry.className = 'module-entry';
    const info = document.createElement('div');
    const pkg = document.createElement('strong');
    pkg.textContent = item.pkg;
    const uid = document.createElement('small');
    uid.textContent = `UID ${item.uid}`;
    info.append(pkg, uid);
    const state = document.createElement('span');
    state.className = `module-state ${item.enabled ? 'is-enabled' : 'is-disabled'}`;
    state.textContent = item.enabled ? 'Enabled' : 'Disabled';
    const inspect = document.createElement('button');
    inspect.type = 'button';
    inspect.className = 'module-inspect';
    inspect.textContent = 'Scopes';
    inspect.setAttribute('aria-label', `Inspect scopes for ${item.pkg}`);
    inspect.addEventListener('click', () => inspectModule(item.pkg));
    entry.append(info, state, inspect);
    fragment.appendChild(entry);
  }
  root.appendChild(fragment);
}
async function inspectModule(pkg) {
  // Package names originate from Vector inventory, but validate again before
  // adding anything to a shell command. Never execute arbitrary UI text.
  if (!/^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+$/.test(pkg) || pkg.includes('..')) {
    $('modulescope').textContent = 'Unsupported module identifier.';
    return;
  }
  $('modulescope').textContent = `Reading explicit scopes for ${pkg}…`;
  try {
    const result = await command(`scope ${pkg}`);
    $('modulescope').textContent = `Module: ${pkg}\n${result}`;
  } catch (error) {
    $('modulescope').textContent = `Scope lookup failed for ${pkg}: ${errorDescription(error)}`;
  }
}
const validTarget = s => s === 'system_server' || (/^[a-zA-Z_][a-zA-Z0-9_.]*\.[a-zA-Z0-9_.]+$/.test(s) && !s.includes('..'));
function show(tab) {
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  document.querySelectorAll('.section').forEach(s => s.classList.toggle('active', s.id === tab));
}
async function refresh() {
  if (refreshInProgress) return;
  refreshInProgress = true;
  $('refresh').disabled = true;
  setStatus('Reading Guardian state…');
  try {
    const report = JSON.parse(await command('report'));
    $('version').textContent = `v${report.version ?? 'unknown'}`;
    $('mode').textContent = report.recovery_armed ? 'ARMED' : 'OBSERVE';
    $('qual').textContent = report.snapshot_validation ?? 'Unknown integrity';
    $('samples').textContent = String(report.historical_checkpoints ?? 0);
    $('historyhealth').textContent = report.history_recent_poll ? 'Polling healthy' : 'Polling unverified';
    $('collector').textContent = report.collector_recent_poll ? 'Healthy' : 'Unverified';
    $('quarantine').textContent = String(report.quarantine_active ?? 0);
    $('pending').textContent = `${report.quarantine_pending ?? 0} pending`;
    try {
      modulesLoaded = false;
      $('modulelist').textContent = 'Loading complete Vector module inventory…';
      modules = parseModuleList(await command('modules'));
      modulesLoaded = true;
      renderModules();
    } catch (error) {
      modules = [];
      modulesLoaded = false;
      $('modulecount').textContent = 'Inventory unavailable';
      $('modulewarning').textContent = errorDescription(error);
      $('modulelist').textContent = 'Could not verify complete module inventory.';
    }
    for (const [id, cmd] of tasks) {
      try {
        const output = await command(cmd);
        $(id).textContent = output;
        if (id === 'doctor') {
          const match = output.match(/Enabled Modules:\s*(\d+)/i);
          expectedEnabled = match ? Number(match[1]) : null;
          if (modulesLoaded) renderModules();
        }
      } catch (error) {
        $(id).textContent = `Unavailable: ${errorDescription(error)}`;
      }
    }
    setStatus('Read-only state refreshed (full multiline output).');
  } catch (error) {
    setStatus(`Cannot load Guardian: ${errorDescription(error)}`);
  } finally {
    refreshInProgress = false;
    $('refresh').disabled = false;
  }
}
async function analyze() {
  const target = $('target').value.trim();
  if (!validTarget(target)) {
    $('analysis').textContent = 'Invalid process identifier. Use an Android package name or system_server.';
    return;
  }
  $('analyze').disabled = true;
  $('analysis').textContent = 'Reviewing historical evidence…';
  try { $('analysis').textContent = await command(`recovery-plan ${target}`); }
  catch (error) { $('analysis').textContent = `Review failed: ${errorDescription(error)}`; }
  finally { $('analyze').disabled = false; }
}
document.querySelectorAll('.tabs button').forEach(b => b.addEventListener('click', () => show(b.dataset.tab)));
$('refresh').addEventListener('click', refresh);
$('analyze').addEventListener('click', analyze);
$('modulefilter').addEventListener('change', renderModules);
$('modulesearch').addEventListener('input', renderModules);
refresh();
