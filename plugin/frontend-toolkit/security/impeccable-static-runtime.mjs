/*
 * FTK-owned canonical static-HTML module boundary.
 *
 * This file contains no parser, selector, CSS or cascade semantics. It
 * installs a synchronous Node loader which resolves every third-party bare
 * import used by the pinned Impeccable static-HTML engine from one explicit,
 * audited dependency root. Unknown bare imports fail closed.
 */
import fs from 'node:fs';
import path from 'node:path';
import { builtinModules, registerHooks } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SECURITY_ROOT = path.dirname(fileURLToPath(import.meta.url));
const EXPECTED_PACKAGES = Object.freeze({
  htmlparser2: '12.0.0', 'css-select': '7.0.0', 'css-tree': '3.2.1', domutils: '4.0.2',
  boolbase: '2.0.0', 'css-what': '8.0.0', 'dom-serializer': '3.1.1',
  domelementtype: '3.0.0', domhandler: '6.0.1', entities: '8.0.0',
  'mdn-data': '2.27.1', 'nth-check': '3.0.1', 'source-map-js': '1.2.1',
});

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function assertNoReparse(root, candidate) {
  if (!isWithin(root, candidate)) throw new Error('Canonical static-HTML path escaped its root.');
  let cursor = root;
  for (const segment of path.relative(root, candidate).split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, segment);
    if (!fs.existsSync(cursor)) break;
    if (fs.lstatSync(cursor).isSymbolicLink()) throw new Error('Canonical static-HTML dependency crosses a reparse point.');
  }
}

function canonicalDirectory(candidate) {
  if (!fs.existsSync(candidate) || !fs.statSync(candidate).isDirectory()) return null;
  assertNoReparse(path.dirname(candidate), candidate);
  return fs.realpathSync.native(candidate);
}

function findCanonicalModuleRoot() {
  const containerName = path.basename(path.dirname(path.dirname(SECURITY_ROOT)));
  const candidate = containerName === 'plugins'
    ? path.resolve(SECURITY_ROOT, '..', 'third_party', 'static-html-dependencies', 'node_modules')
    : path.resolve(SECURITY_ROOT, '..', '..', '..', 'third_party', 'runtimes', 'impeccable-static-html', 'node_modules');
  const root = canonicalDirectory(candidate);
  if (!root) throw new Error('Canonical static-HTML dependency root is missing for the fixed layout.');
  return root;
}

function assertCanonicalInventory(moduleRoot) {
  const actual = fs.readdirSync(moduleRoot, { withFileTypes: true }).filter(entry => entry.isDirectory()).map(entry => entry.name).sort();
  const expected = Object.keys(EXPECTED_PACKAGES).sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Canonical static-HTML dependency inventory drifted.');
  for (const [name, version] of Object.entries(EXPECTED_PACKAGES)) {
    const packageRoot = path.join(moduleRoot, name);
    assertNoReparse(moduleRoot, packageRoot);
    const manifestPath = path.join(packageRoot, 'package.json');
    if (!fs.existsSync(manifestPath) || fs.lstatSync(manifestPath).isSymbolicLink()) throw new Error(`Canonical package manifest is unavailable: ${name}`);
    let manifest;
    try { manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); } catch { throw new Error(`Canonical package manifest is invalid: ${name}`); }
    if (manifest.name !== name || manifest.version !== version) throw new Error(`Canonical package identity drifted: ${name}`);
    if (fs.readdirSync(packageRoot, { withFileTypes: true }).some(entry => entry.isDirectory() && entry.name === 'node_modules')) throw new Error(`Nested module root is not permitted: ${name}`);
  }
}

function packageName(specifier) {
  if (!specifier || specifier.startsWith('.') || specifier.startsWith('/') || specifier.startsWith('file:') || specifier.startsWith('node:')) return null;
  return specifier.split('/')[0];
}

function packagePathFromUrl(url) {
  if (!url.startsWith('file:')) return null;
  const filePath = path.resolve(fileURLToPath(url));
  if (!isWithin(moduleRoot, filePath)) return null;
  return path.relative(moduleRoot, filePath).split(path.sep)[0] || null;
}

const moduleRoot = findCanonicalModuleRoot();
assertCanonicalInventory(moduleRoot);

const loadedPackages = new Set();
const resolvedModules = new Map();
const allowedBarePackages = new Set(Object.keys(EXPECTED_PACKAGES));
const sourceRoot = path.resolve(SECURITY_ROOT, '..', '..', '..');
const allowedRelativeRoots = [
  moduleRoot,
  SECURITY_ROOT,
  path.resolve(sourceRoot, 'external', 'impeccable'),
  path.resolve(SECURITY_ROOT, '..', 'third_party', 'upstreams', 'impeccable'),
];

function assertAllowedRelativeResult(specifier, url) {
  if (!url.startsWith('file:')) throw new Error(`Non-file relative module is denied: ${specifier}`);
  const resolved = path.resolve(fileURLToPath(url));
  const root = allowedRelativeRoots.find(candidate => isWithin(candidate, resolved));
  if (!root) throw new Error(`Relative module escaped fixed FTK/upstream roots: ${specifier}`);
  assertNoReparse(root, resolved);
}

function selectExportTarget(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    for (const item of value) {
      try { return selectExportTarget(item); } catch { /* try the next declared condition */ }
    }
  }
  if (value && typeof value === 'object') {
    for (const key of ['import', 'default', 'node', 'require']) {
      if (Object.prototype.hasOwnProperty.call(value, key)) return selectExportTarget(value[key]);
    }
  }
  throw new Error('Package export has no supported static condition.');
}

function resolveCanonicalPackage(specifier) {
  const name = packageName(specifier);
  if (!name) return null;
  if (!allowedBarePackages.has(name)) throw new Error('Ambient bare module resolution is denied: ' + specifier);
  const packageRoot = path.join(moduleRoot, name);
  const manifestPath = path.join(packageRoot, 'package.json');
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); }
  catch { throw new Error('Canonical package manifest is unavailable: ' + name); }

  const subpath = specifier.slice(name.length).replace('/', '');
  let target;
  if (subpath) {
    const exportKey = './' + subpath;
    if (manifest.exports) {
      const exports = manifest.exports;
      if (typeof exports !== 'object' || !Object.prototype.hasOwnProperty.call(exports, exportKey)) {
        throw new Error('Canonical package subpath is not exported: ' + specifier);
      }
      target = selectExportTarget(exports[exportKey]);
    } else {
      target = exportKey;
    }
  } else if (manifest.exports) {
    const rootExport = typeof manifest.exports === 'string' ? manifest.exports : manifest.exports['.'];
    target = selectExportTarget(rootExport);
  } else {
    target = manifest.module || manifest.main || './index.js';
  }

  if (typeof target !== 'string' || !target.startsWith('./')) throw new Error('Canonical package target is invalid: ' + specifier);
  let absolute = path.resolve(packageRoot, target);
  if (!isWithin(packageRoot, absolute)) throw new Error('Canonical package target escaped its root: ' + specifier);
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
    if (!path.extname(absolute) && fs.existsSync(absolute + '.js')) absolute += '.js';
    else throw new Error('Canonical package target is unavailable: ' + specifier);
  }
  assertNoReparse(moduleRoot, absolute);
  if (packagePathFromUrl(pathToFileURL(absolute).href) !== name) throw new Error('Canonical package identity mismatch: ' + specifier);
  resolvedModules.set(specifier, absolute);
  loadedPackages.add(name);
  return { url: pathToFileURL(absolute).href, shortCircuit: true };
}

const runtimeState = { initialized: true, moduleRoot, expectedPackages: { ...EXPECTED_PACKAGES }, resolvedModules, loadedPackages, quickSortLoaded: false };
globalThis.__ftkStaticHtmlRuntime = runtimeState;

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('node:') || builtinModules.includes(specifier)) return nextResolve(specifier, context);
    const packageResult = resolveCanonicalPackage(specifier);
    if (packageResult) return packageResult;
    if (specifier.startsWith('node:')) return nextResolve(specifier, context);
    const result = nextResolve(specifier, context);
    if (specifier.startsWith('.') || specifier.startsWith('/') || specifier.startsWith('file:')) assertAllowedRelativeResult(specifier, result.url);
    else throw new Error(`Unregistered module specifier is denied: ${specifier}`);
    return result;
  },
  load(url, context, nextLoad) {
    const packageNameFromPath = packagePathFromUrl(url);
    if (packageNameFromPath) {
      loadedPackages.add(packageNameFromPath);
      if (url.endsWith('/source-map-js/lib/quick-sort.js')) {
        runtimeState.quickSortLoaded = true;
        throw new Error('source-map-js quick-sort.js is outside the approved static-HTML path.');
      }
    }
    return nextLoad(url, context);
  },
});

export { EXPECTED_PACKAGES, moduleRoot, runtimeState };
