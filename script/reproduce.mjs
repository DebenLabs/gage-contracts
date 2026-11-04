#!/usr/bin/env node
// Prove a public contracts tree builds the deployed bytecode. No dependencies: the same file runs in gage's own
// repository on an export (scripts/check-public-contracts.mjs) and in the public repository on itself
// (script/reproduce.mjs).
//
//   node scripts/check-public-contracts.mjs --tree <dir> [--libs | --libs-from <dir>] [--no-build]
//     [--reference <out dir>] [--sourcify <chainId>] [--rpc <url>] [--interfaces] [--json <file>]
//
// --libs checks lib/ out at the commits lib.lock.json pins (--libs-from copies an existing checkout of them).
// The build is `forge build` in the tree, with the tree's own foundry.toml. Then, for every contract in
// deployments/<chainId>.json:
//   --reference  the creation and runtime bytecode equal those of a build of the release commit in gage's
//                repository (its contracts/out), and that build compiled no source file the tree lacks;
//   --sourcify   they equal the bytecode Sourcify recompiled from the verified sources at each address (an
//                address Sourcify has not verified is a difference);
//   --rpc        the runtime equals the code at each address, immutables masked, and each code store's parts
//                (SSTORE2: a leading STOP, then one slice) joined equal its contract's creation code.
// --interfaces also compiles interfaces/ with solc 0.8.26 and 0.8.28. Exits 1 on any difference.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const argv = process.argv.slice(2);
const opt = (flag, fallback) => {
  const i = argv.indexOf(`--${flag}`);
  return i === -1 ? fallback : argv[i + 1];
};
const has = (flag) => argv.includes(`--${flag}`);
const tree = path.resolve(opt('tree', '.'));
const run = (cmd, args, cwd = tree) => execFileSync(cmd, args, {cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 << 20});
const json = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const problems = [];
const results = [];

// -------------------------------------------------------------------------------------------------- libraries
const lock = json(path.join(tree, 'lib.lock.json')).libraries;
if (opt('libs-from')) {
  for (const lib of lock) {
    const to = path.join(tree, lib.path);
    if (fs.existsSync(path.join(to, '.git')) || fs.existsSync(path.join(to, 'src')) || fs.existsSync(path.join(to, 'contracts'))) continue;
    const from = path.resolve(opt('libs-from'), path.basename(lib.path));
    if (!fs.existsSync(from)) {
      console.log(`${lib.path}: not under --libs-from, left for --libs`);
      continue;
    }
    const head = run('git', ['-C', from, 'rev-parse', 'HEAD'], from).trim();
    if (head !== lib.commit) throw new Error(`${from} is at ${head}, not the pinned ${lib.commit}`);
    fs.mkdirSync(path.dirname(to), {recursive: true});
    fs.cpSync(from, to, {recursive: true, filter: (src) => !/\/(?:out|cache|node_modules|\.git)(?:\/|$)/.test(src.slice(from.length))});
  }
} else if (has('libs')) {
  for (const lib of lock) {
    const to = path.join(tree, lib.path);
    if (fs.existsSync(to) && fs.readdirSync(to).length) continue;
    run('git', ['clone', '--quiet', lib.url, to]);
    run('git', ['-C', to, 'checkout', '--quiet', lib.commit]);
    run('git', ['-C', to, 'submodule', 'update', '--init', '--recursive', '--quiet']);
  }
}

// ------------------------------------------------------------------------------------------------------ build
if (!has('no-build')) {
  console.log(`forge build in ${tree}`);
  run('forge', ['build']);
}
const out = path.join(tree, 'out');
const artifactOf = (dir, source, contract) => {
  const file = path.join(dir, path.basename(source), `${contract}.json`);
  if (!fs.existsSync(file)) return null;
  const artifact = json(file);
  return artifact.metadata?.settings?.compilationTarget?.[source] === contract ? artifact : null;
};

const deployment = fs.readdirSync(path.join(tree, 'deployments')).filter((f) => /^\d+\.json$/.test(f)).map((f) => json(path.join(tree, 'deployments', f)))[0];
if (!deployment) throw new Error('no deployments/<chainId>.json in the tree');
const stores = deployment.codeStores ?? [];
const unique = [...new Map([...deployment.contracts, ...stores].map((c) => [`${c.source}:${c.contract}`, c])).values()];
const built = new Map();
for (const c of unique) {
  const artifact = artifactOf(out, c.source, c.contract);
  if (!artifact) problems.push(`${c.source}:${c.contract}: not built by the tree`);
  else built.set(`${c.source}:${c.contract}`, artifact);
}

// --------------------------------------------------------------------------------- against the monorepo build
const reference = opt('reference');
if (reference) {
  const files = new Set(fs.readdirSync(path.join(tree, 'src'), {recursive: true}).map((f) => `src/${f}`));
  for (const c of unique) {
    const mine = built.get(`${c.source}:${c.contract}`);
    const theirs = artifactOf(path.resolve(reference), c.source, c.contract);
    const row = {check: 'reference', contract: c.contract, source: c.source};
    if (!mine || !theirs) {
      problems.push(`${c.contract}: ${theirs ? 'tree' : 'reference'} artifact missing`);
      results.push({...row, ok: false});
      continue;
    }
    const missing = Object.keys(theirs.metadata.sources).filter((s) => s.startsWith('src/') && !files.has(s));
    const creation = mine.bytecode.object === theirs.bytecode.object;
    const runtime = mine.deployedBytecode.object === theirs.deployedBytecode.object;
    // Immutable slots are keyed by AST ID, which depends on the files compiled together: compare where they sit.
    const slots = (a) => JSON.stringify(Object.values(a.deployedBytecode.immutableReferences ?? {}).map((l) => l.map((r) => `${r.start}:${r.length}`).join(',')).sort());
    const immutables = slots(mine) === slots(theirs);
    const ok = creation && runtime && immutables && missing.length === 0;
    results.push({...row, ok, creation, runtime, immutables, bytes: (mine.deployedBytecode.object.length - 2) / 2});
    if (!ok) problems.push(`${c.contract}: reference ${[!creation && 'creation', !runtime && 'runtime', !immutables && 'immutables', missing.length && `missing ${missing.join(' ')}`].filter(Boolean).join(', ')} differ`);
  }
}

// ---------------------------------------------------------------------------------- against Sourcify and chain
const masked = (code, refs) => {
  let s = code.replace(/^0x/, '');
  for (const list of Object.values(refs ?? {})) for (const {start, length} of list) s = s.slice(0, start * 2) + '0'.repeat(length * 2) + s.slice((start + length) * 2);
  return s;
};
const sourcify = opt('sourcify');
const rpc = opt('rpc');
for (const c of deployment.contracts) {
  if (!c.address || (!sourcify && !rpc)) continue;
  const artifact = built.get(`${c.source}:${c.contract}`);
  if (!artifact) continue;
  if (sourcify) {
    const url = `https://sourcify.dev/server/v2/contract/${sourcify}/${c.address}?fields=creationBytecode,runtimeBytecode`;
    const r = await fetch(url, {signal: AbortSignal.timeout(60_000)});
    const body = r.ok ? await r.json() : null;
    const creation = body?.creationBytecode?.recompiledBytecode === artifact.bytecode.object;
    const runtime = body?.runtimeBytecode?.recompiledBytecode === artifact.deployedBytecode.object;
    results.push({check: 'sourcify', contract: c.contract, address: c.address, ok: creation && runtime, creation, runtime, status: r.status});
    if (!(creation && runtime)) problems.push(`${c.contract} at ${c.address}: Sourcify ${r.ok ? [!creation && 'creation', !runtime && 'runtime'].filter(Boolean).join(' and ') + ' differ' : `HTTP ${r.status}`}`);
  }
  if (rpc) {
    const r = await fetch(rpc, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [c.address, 'latest']}), signal: AbortSignal.timeout(60_000)});
    const code = (await r.json()).result ?? '0x';
    const refs = artifact.deployedBytecode.immutableReferences;
    const ok = masked(code, refs) === masked(artifact.deployedBytecode.object, refs);
    results.push({check: 'chain', contract: c.contract, address: c.address, ok});
    if (!ok) problems.push(`${c.contract} at ${c.address}: runtime differs from the chain`);
  }
}
for (const s of rpc ? stores : []) {
  const artifact = built.get(`${s.source}:${s.contract}`);
  if (!artifact) continue;
  let joined = '';
  for (const address of s.parts) {
    const r = await fetch(rpc, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [address, 'latest']}), signal: AbortSignal.timeout(60_000)});
    const code = ((await r.json()).result ?? '0x').replace(/^0x/, '');
    joined += code.startsWith('00') ? code.slice(2) : `<${address} has no leading STOP>`;
  }
  const ok = `0x${joined}` === artifact.bytecode.object;
  results.push({check: 'chain', contract: s.contract, codeStore: s.parts, ok});
  if (!ok) problems.push(`${s.contract}: the code stored at ${s.parts.join(', ')} differs from its creation code`);
}

// ----------------------------------------------------------------------------------------------- interfaces
if (has('interfaces')) {
  for (const version of ['0.8.26', '0.8.28']) {
    try {
      run('forge', ['build', '--contracts', 'interfaces', '--use', version, '--out', `out-interfaces-${version}`, '--cache-path', `cache-interfaces-${version}`, '--skip', 'test', '--skip', 'script']);
      results.push({check: 'interfaces', solc: version, ok: true});
    } catch (e) {
      results.push({check: 'interfaces', solc: version, ok: false});
      problems.push(`interfaces/ do not compile with solc ${version}: ${String(e.stderr).slice(0, 400)}`);
    }
  }
}

const by = (check) => results.filter((r) => r.check === check);
for (const check of ['reference', 'sourcify', 'chain', 'interfaces']) {
  const rows = by(check);
  if (rows.length) console.log(`${check}: ${rows.filter((r) => r.ok).length}/${rows.length} match`);
}
if (opt('json')) fs.writeFileSync(opt('json'), JSON.stringify({tree, release: deployment.release, status: deployment.status, results, problems}, null, 2) + '\n');
if (problems.length) {
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log(`${deployment.release}: ${unique.length} contracts reproduce${deployment.status === 'placeholder' ? ' (placeholder release: testnet addresses)' : ''}.`);
