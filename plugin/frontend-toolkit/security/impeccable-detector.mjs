/*
 * FTK contained detector boundary for Impeccable skill-v4.1.2.
 *
 * The canonical rule registry and analytical functions are Apache-2.0 upstream
 * Impeccable code. They are imported, unmodified, only after the pinned module
 * graph is fingerprinted. Traversal, configuration, import-graph, linked-CSS,
 * and result-contract code in this file is FTK-owned mediation. See the
 * repository THIRD_PARTY_NOTICES.md and the pinned upstream LICENSE/NOTICE.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const LIMITS = Object.freeze({
  requestBytes: 2 * 1024 * 1024,
  payloadBytes: 1024 * 1024,
  fileBytes: 1024 * 1024,
  totalBytes: 8 * 1024 * 1024,
  fileCount: 200,
  depth: 12,
  configBytes: 64 * 1024,
  designBytes: 256 * 1024,
  patterns: 100,
  patternLength: 256,
});

const SCANNABLE_EXTENSIONS = new Set([
  '.html', '.htm', '.css', '.scss', '.sass', '.less',
  '.jsx', '.tsx', '.js', '.ts', '.vue', '.svelte', '.astro', '.blade.php',
]);
const HTML_EXTENSIONS = new Set(['.html', '.htm']);
const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', '__pycache__']);
const HIDDEN_SOURCE_DIRS = new Set(['.vitepress', '.vuepress', '.storybook']);
const CSP_SCAN_EXTENSIONS = new Set([
  '.js', '.mjs', '.cjs', '.ts', '.mts', '.cts', '.tsx', '.jsx',
  '.astro', '.vue', '.svelte', '.html',
]);
const CSP_SKIP_DIRS = new Set([
  'node_modules', '.git', '.next', '.turbo', '.svelte-kit', '.nuxt',
  '.astro', 'dist', 'build', 'out', '.vercel',
]);
const CSP_LIMITS = Object.freeze({
  fileBytes: 64 * 1024,
  totalBytes: LIMITS.totalBytes,
  fileCount: LIMITS.fileCount,
  depth: 6,
  hiddenDirectories: 'excluded except no exceptions',
});
const CONFIG_DETECTOR_KEYS = new Set([
  'ignoreRules', 'ignoreFiles', 'ignoreValues', 'designSystem', 'advisoryRules',
]);
const OPTION_KEYS = new Set([
  'scopes', 'viewport', 'quiet', 'includeAdvisory', 'profile',
  'useProjectConfig', 'useDesignSystem', 'inlineIgnores',
]);
const FRAMEWORK_CONFIGS = Object.freeze([
  { name: 'Next.js', files: ['next.config.js', 'next.config.mjs', 'next.config.ts'], defaultPort: 3000, portRe: /port\s*[:=]\s*(\d+)/ },
  { name: 'SvelteKit', files: ['svelte.config.js', 'svelte.config.ts'], defaultPort: 5173, portRe: /port\s*[:=]\s*(\d+)/ },
  { name: 'Nuxt', files: ['nuxt.config.js', 'nuxt.config.ts'], defaultPort: 3000, portRe: /port\s*[:=]\s*(\d+)/ },
  { name: 'Vite', files: ['vite.config.js', 'vite.config.ts', 'vite.config.mjs'], defaultPort: 5173, portRe: /port\s*[:=]\s*(\d+)/ },
  { name: 'Astro', files: ['astro.config.js', 'astro.config.ts', 'astro.config.mjs'], defaultPort: 4321, portRe: /port\s*[:=]\s*(\d+)/ },
  { name: 'Angular', files: ['angular.json'], defaultPort: 4200, portRe: /"port"\s*:\s*(\d+)/ },
  { name: 'Remix', files: ['remix.config.js', 'remix.config.ts'], defaultPort: 3000, portRe: /port\s*[:=]\s*(\d+)/ },
]);
const IMPORT_PATTERNS = Object.freeze([
  /import\s+(?:[\s\S]*?from\s+)?['"]([^'"]+)['"]/g,
  /@import\s+(?:url\(\s*)?['"]?([^'");\s]+)['"]?\s*\)?/g,
  /@(?:use|forward)\s+['"]([^'"]+)['"]/g,
]);

function fail(message) {
  throw new Error(message);
}

function assertPlainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object.`);
  return value;
}

function canonicalCommittedBytes(filePath) {
  const bytes = fs.readFileSync(filePath);
  const canonical = [];
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] === 0x0d && bytes[index + 1] === 0x0a) {
      canonical.push(0x0a);
      index += 1;
    } else {
      if (bytes[index] === 0x0d) fail('Pinned detector module contains a non-canonical lone CR byte.');
      canonical.push(bytes[index]);
    }
  }
  return Buffer.from(canonical);
}

function canonicalFingerprint(filePath) {
  const bytes = canonicalCommittedBytes(filePath);
  const header = Buffer.from(`blob ${bytes.length}\0`, 'utf8');
  return {
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    gitBlob: crypto.createHash('sha1').update(header).update(bytes).digest('hex'),
  };
}

function within(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function assertNoReparse(root, candidate) {
  if (!within(root, candidate)) fail('Path escapes the canonical project root.');
  const relative = path.relative(root, candidate);
  let cursor = root;
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, segment);
    if (!fs.existsSync(cursor)) break;
    const item = fs.lstatSync(cursor);
    if (item.isSymbolicLink()) fail('Path crosses a symlink or junction/reparse point.');
    const real = fs.realpathSync.native(cursor);
    if (!within(root, real)) fail('Path resolves outside the canonical project root.');
  }
}

function canonicalRoot(input) {
  if (typeof input !== 'string' || !input) fail('projectRoot is required.');
  const resolved = path.resolve(input);
  if (!fs.statSync(resolved).isDirectory()) fail('projectRoot must be a directory.');
  if (fs.lstatSync(resolved).isSymbolicLink()) fail('projectRoot cannot be a reparse point.');
  return fs.realpathSync.native(resolved);
}

function relativeDisplay(root, candidate) {
  return path.relative(root, candidate).split(path.sep).join('/') || '.';
}

function hasScannableExtension(fileName) {
  const lower = fileName.toLowerCase();
  if (SCANNABLE_EXTENSIONS.has(path.extname(lower))) return true;
  return [...SCANNABLE_EXTENSIONS].some(ext => ext.indexOf('.', 1) !== -1 && lower.endsWith(ext));
}

function readBounded(filePath, maxBytes, state = null) {
  const item = fs.lstatSync(filePath);
  if (item.isSymbolicLink() || !item.isFile()) fail('Detector input must be a regular non-reparse file.');
  if (item.size > maxBytes) fail(`Detector input exceeds the ${maxBytes}-byte file limit.`);
  if (state) {
    state.bytes += item.size;
    if (state.bytes > LIMITS.totalBytes) fail('Detector inputs exceed the total byte limit.');
  }
  return fs.readFileSync(filePath, 'utf8');
}

function resolveContained(root, inputPath, expect = 'file') {
  if (typeof inputPath !== 'string' || !inputPath || path.isAbsolute(inputPath)) {
    fail('inputPath must be a non-empty relative path.');
  }
  const candidate = path.resolve(root, inputPath);
  if (!within(root, candidate)) fail('inputPath escapes projectRoot.');
  assertNoReparse(root, candidate);
  const item = fs.lstatSync(candidate);
  if (expect === 'file' && !item.isFile()) fail('inputPath must identify a file.');
  if (expect === 'directory' && !item.isDirectory()) fail('inputPath must identify a directory.');
  return fs.realpathSync.native(candidate);
}

function readJsonFileStrict(root, relativePath, maxBytes) {
  const candidate = path.resolve(root, relativePath);
  if (!within(root, candidate)) fail('Configuration path escaped projectRoot.');
  if (!fs.existsSync(candidate)) return null;
  assertNoReparse(root, candidate);
  const text = readBounded(candidate, maxBytes);
  try {
    return assertPlainObject(JSON.parse(text.replace(/^\uFEFF/, '')), relativePath);
  } catch (error) {
    fail(`Invalid ${relativePath}: ${error.message}`);
  }
}

function stringList(value, label, allowed = null) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > LIMITS.patterns) fail(`${label} must be a bounded string array.`);
  const result = [];
  for (const item of value) {
    if (typeof item !== 'string' || !item.trim() || item.length > LIMITS.patternLength || /[\0\r\n]/.test(item)) {
      fail(`${label} contains an invalid value.`);
    }
    const normalized = item.trim();
    if (allowed && !allowed.has(normalized)) fail(`${label} contains an unknown canonical value: ${normalized}`);
    if (!result.includes(normalized)) result.push(normalized);
  }
  return result;
}

function detectorSection(raw, label, canonicalIds) {
  if (!raw) return {};
  const section = raw.detector && typeof raw.detector === 'object' && !Array.isArray(raw.detector)
    ? raw.detector
    : {};
  for (const key of Object.keys(section)) {
    if (!CONFIG_DETECTOR_KEYS.has(key)) fail(`${label}.detector contains unknown field: ${key}`);
  }
  const result = {
    ignoreRules: stringList(section.ignoreRules, `${label}.detector.ignoreRules`, canonicalIds),
    ignoreFiles: stringList(section.ignoreFiles, `${label}.detector.ignoreFiles`),
    ignoreValues: [],
  };
  if (section.designSystem !== undefined) {
    assertPlainObject(section.designSystem, `${label}.detector.designSystem`);
    for (const key of Object.keys(section.designSystem)) {
      if (key !== 'enabled') fail(`${label}.detector.designSystem contains unknown field: ${key}`);
    }
    if (section.designSystem.enabled !== undefined && typeof section.designSystem.enabled !== 'boolean') {
      fail(`${label}.detector.designSystem.enabled must be boolean.`);
    }
    result.designSystem = { enabled: section.designSystem.enabled !== false };
  }
  if (section.advisoryRules !== undefined && !['include', 'exclude'].includes(section.advisoryRules)) {
    fail(`${label}.detector.advisoryRules is invalid.`);
  }
  if (section.advisoryRules !== undefined) result.advisoryRules = section.advisoryRules;
  if (section.ignoreValues !== undefined) {
    if (!Array.isArray(section.ignoreValues) || section.ignoreValues.length > LIMITS.patterns) {
      fail(`${label}.detector.ignoreValues must be a bounded array.`);
    }
    for (const [index, entry] of section.ignoreValues.entries()) {
      assertPlainObject(entry, `${label}.detector.ignoreValues[${index}]`);
      const allowedKeys = new Set(['rule', 'value', 'file', 'files', 'createdAt', 'reason']);
      for (const key of Object.keys(entry)) if (!allowedKeys.has(key)) fail(`${label}.detector.ignoreValues contains unknown field: ${key}`);
      if (!canonicalIds.has(entry.rule)) fail(`${label}.detector.ignoreValues contains an unknown rule.`);
      if (typeof entry.value !== 'string' || !entry.value || entry.value.length > LIMITS.patternLength) fail(`${label}.detector.ignoreValues contains an invalid value.`);
      const normalized = { rule: entry.rule, value: entry.value };
      const files = stringList(entry.files, `${label}.detector.ignoreValues.files`);
      if (typeof entry.file === 'string' && entry.file) files.push(entry.file);
      if (files.length) normalized.files = [...new Set(files)];
      result.ignoreValues.push(normalized);
    }
  }
  return result;
}

function mergeConfig(target, source) {
  target.ignoreRules = [...new Set([...target.ignoreRules, ...(source.ignoreRules || [])])];
  target.ignoreFiles = [...new Set([...target.ignoreFiles, ...(source.ignoreFiles || [])])];
  target.ignoreValues = [...target.ignoreValues, ...(source.ignoreValues || [])];
  if (source.designSystem) target.designSystem = source.designSystem;
  if (source.advisoryRules) target.advisoryRules = source.advisoryRules;
}

function loadConfig(root, options, canonicalIds) {
  const config = { ignoreRules: [], ignoreFiles: [], ignoreValues: [], designSystem: { enabled: true } };
  if (!options.useProjectConfig) return config;
  for (const name of ['.impeccable/config.json', '.impeccable/config.local.json']) {
    const raw = readJsonFileStrict(root, name, LIMITS.configBytes);
    if (!raw) continue;
    // Top-level non-detector fields are explicitly forward-compatible upstream data.
    if (raw.hook && typeof raw.hook === 'object' && !Array.isArray(raw.hook)) {
      const legacyDetector = Object.fromEntries(Object.entries(raw.hook).filter(([key]) => CONFIG_DETECTOR_KEYS.has(key)));
      mergeConfig(config, detectorSection({ detector: legacyDetector }, `${name}.hook-compat`, canonicalIds));
    }
    mergeConfig(config, detectorSection(raw, name, canonicalIds));
  }
  return config;
}

function validateOptions(raw, scopeIds) {
  const options = raw === undefined || raw === null ? {} : assertPlainObject(raw, 'options');
  for (const key of Object.keys(options)) if (!OPTION_KEYS.has(key)) fail(`options contains unknown field: ${key}`);
  const result = {
    scopes: stringList(options.scopes, 'options.scopes', scopeIds),
    quiet: options.quiet === true,
    includeAdvisory: options.includeAdvisory !== false,
    profile: options.profile === true,
    useProjectConfig: options.useProjectConfig !== false,
    useDesignSystem: options.useDesignSystem !== false,
    inlineIgnores: options.inlineIgnores !== false,
    viewport: null,
  };
  for (const key of ['quiet', 'includeAdvisory', 'profile', 'useProjectConfig', 'useDesignSystem', 'inlineIgnores']) {
    if (options[key] !== undefined && typeof options[key] !== 'boolean') fail(`options.${key} must be boolean.`);
  }
  if (options.viewport !== undefined && options.viewport !== null) {
    assertPlainObject(options.viewport, 'options.viewport');
    if (Object.keys(options.viewport).some(key => !['width', 'height'].includes(key))) fail('options.viewport contains an unknown field.');
    const { width, height } = options.viewport;
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 100 || height < 100 || width > 10000 || height > 10000) {
      fail('options.viewport must be bounded integer width/height metadata.');
    }
    result.viewport = { width, height };
  }
  return result;
}

function walkProject(root, start, config, shouldIgnoreDetectionFile) {
  const files = [];
  const state = { bytes: 0 };
  function walk(dir, depth) {
    if (depth > LIMITS.depth) fail('Project traversal exceeds the depth limit.');
    assertNoReparse(root, dir);
    const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en'));
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) fail('Project traversal encountered a symlink or junction/reparse point.');
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        if (entry.name.startsWith('.') && !HIDDEN_SOURCE_DIRS.has(entry.name)) continue;
        walk(full, depth + 1);
      } else if (entry.isFile() && hasScannableExtension(entry.name)) {
        assertNoReparse(root, full);
        if (shouldIgnoreDetectionFile(full, root, config)) continue;
        const item = fs.lstatSync(full);
        if (item.size > LIMITS.fileBytes) fail('Project contains a detector file over the per-file limit.');
        state.bytes += item.size;
        if (state.bytes > LIMITS.totalBytes) fail('Project detector exceeds the total byte limit.');
        files.push(fs.realpathSync.native(full));
        if (files.length > LIMITS.fileCount) fail('Project detector exceeds the file-count limit.');
      }
    }
  }
  const item = fs.lstatSync(start);
  if (item.isFile()) files.push(start);
  else walk(start, 0);
  return { files, bytes: state.bytes };
}

function walkCspProject(root) {
  const records = [];
  let totalBytes = 0;
  function walk(dir, depth) {
    assertNoReparse(root, dir);
    const entries = fs.readdirSync(dir, { withFileTypes: true })
      .sort((a, b) => a.name.localeCompare(b.name, 'en'));
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) fail('CSP traversal encountered a symlink or junction/reparse point.');
      const item = fs.lstatSync(full);
      if (item.isSymbolicLink()) fail('CSP traversal encountered a symlink or junction/reparse point.');
      if (entry.isDirectory()) {
        if (CSP_SKIP_DIRS.has(entry.name) || entry.name.startsWith('.')) continue;
        if (depth >= CSP_LIMITS.depth) fail('CSP traversal exceeds the depth limit.');
        walk(full, depth + 1);
        continue;
      }
      if (!entry.isFile() || !CSP_SCAN_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) continue;
      assertNoReparse(root, full);
      if (item.size > CSP_LIMITS.fileBytes) fail('CSP input exceeds the per-file limit.');
      totalBytes += item.size;
      if (totalBytes > CSP_LIMITS.totalBytes) fail('CSP inputs exceed the total byte limit.');
      records.push({
        path: fs.realpathSync.native(full),
        relative: relativeDisplay(root, full),
        body: fs.readFileSync(full, 'utf8'),
      });
      if (records.length > CSP_LIMITS.fileCount) fail('CSP traversal exceeds the file-count limit.');
    }
  }
  walk(root, 0);
  return { records, totalBytes };
}

function analyzeCspRecords(records) {
  const scanExtensions = new Set(['.js', '.mjs', '.cjs', '.ts', '.mts', '.cts', '.tsx', '.jsx']);
  const layoutExtensions = new Set(['.tsx', '.jsx', '.astro', '.vue', '.svelte', '.html']);
  const hits = { appendArrays: [], appendString: [], middleware: [], metaTag: [] };
  const monorepoSignals = [/\bbuildCSPConfig\b/, /\bbuildSecurityHeaders\b/, /\badditionalScriptSrc\b/, /\badditionalConnectSrc\b/, /\bcreateBaseNextConfig\b/];
  const svelteSignals = [/\bkit\s*:/, /\bcsp\s*:/, /\bdirectives\s*:/];
  const nuxtSignals = [/[\x22']nuxt-security[\x22']/, /\bcontentSecurityPolicy\b/];
  const inlineSignals = [/[\x22']Content-Security-Policy[\x22']/i, /\bscript-src\b/, /\bconnect-src\b/];
  const middlewareHint = /headers\.set\(\s*[\x22']Content-Security-Policy[\x22']/i;
  const metaHint = /http-equiv\s*=\s*[\x22']Content-Security-Policy[\x22']/i;
  for (const record of records) {
    const ext = path.extname(record.path).toLowerCase();
    const base = path.basename(record.path).toLowerCase();
    const relative = record.relative.split(path.sep).join('/');
    const isConfig = name => new RegExp(`(^|/)${name}\\.config\\.`).test(relative);
    if (scanExtensions.has(ext) && /packages\/[^/]+\/src\/.*(config|next-config|security)/.test(relative) && monorepoSignals.some(re => re.test(record.body))) {
      hits.appendArrays.push(relative);
      continue;
    }
    if (scanExtensions.has(ext) && isConfig('svelte') && svelteSignals.every(re => re.test(record.body))) {
      hits.appendArrays.push(relative);
      continue;
    }
    if (scanExtensions.has(ext) && isConfig('nuxt') && nuxtSignals.every(re => re.test(record.body))) {
      hits.appendArrays.push(relative);
      continue;
    }
    if (scanExtensions.has(ext) && /(^|\/)(next|nuxt|vite|astro|svelte)\.config\./.test(relative) && inlineSignals.every(re => re.test(record.body))) {
      hits.appendString.push(relative);
      continue;
    }
    if (['middleware.ts', 'middleware.js', 'middleware.mjs'].includes(base) && middlewareHint.test(record.body)) hits.middleware.push(relative);
    if (layoutExtensions.has(ext) && metaHint.test(record.body)) hits.metaTag.push(relative);
  }
  if (hits.appendArrays.length) return { shape: 'append-arrays', signals: hits.appendArrays };
  if (hits.appendString.length) return { shape: 'append-string', signals: hits.appendString };
  if (hits.middleware.length) return { shape: 'middleware', signals: hits.middleware };
  if (hits.metaTag.length) return { shape: 'meta-tag', signals: hits.metaTag };
  return { shape: null, signals: [] };
}

function resolveImport(specifier, fromDir, fileSet) {
  if (!/^[./]/.test(specifier)) return null;
  const base = path.resolve(fromDir, specifier);
  if (fileSet.has(base)) return base;
  for (const extension of SCANNABLE_EXTENSIONS) {
    if (fileSet.has(base + extension)) return base + extension;
    const indexFile = path.join(base, `index${extension}`);
    if (fileSet.has(indexFile)) return indexFile;
  }
  return null;
}

function buildImportGraph(root, files, contentByFile) {
  const fileSet = new Set(files);
  const importedBy = new Map();
  let edgeCount = 0;
  for (const file of files) {
    for (const pattern of IMPORT_PATTERNS) {
      pattern.lastIndex = 0;
      for (const match of contentByFile.get(file).matchAll(pattern)) {
        if (/^[./]/.test(match[1])) {
          const candidate = path.resolve(path.dirname(file), match[1]);
          if (!within(root, candidate)) fail('Import specifier escapes projectRoot.');
          assertNoReparse(root, candidate);
        }
        const imported = resolveImport(match[1], path.dirname(file), fileSet);
        if (!imported) continue;
        if (!importedBy.has(imported)) importedBy.set(imported, new Set());
        importedBy.get(imported).add(file);
        edgeCount += 1;
      }
    }
  }
  return { importedBy, edgeCount };
}

function detectFramework(root) {
  const entries = new Set(fs.readdirSync(root));
  for (const definition of FRAMEWORK_CONFIGS) {
    const name = definition.files.find(file => entries.has(file));
    if (!name) continue;
    const configPath = path.join(root, name);
    assertNoReparse(root, configPath);
    const content = readBounded(configPath, LIMITS.configBytes);
    const match = content.match(definition.portRe);
    return {
      name: definition.name,
      configPath: relativeDisplay(root, configPath),
      declaredPort: match ? Number(match[1]) : definition.defaultPort,
      probe: 'not-performed',
      probeOperation: 'impeccable.detector.loopback',
    };
  }
  return null;
}

function extractLinkedCss(root, htmlPath, html) {
  const result = [];
  const linkRe = /<link\b[^>]*\brel\s*=\s*['"]?stylesheet['"]?[^>]*>/gi;
  for (const tag of html.matchAll(linkRe)) {
    const href = tag[0].match(/\bhref\s*=\s*(['"])(.*?)\1/i) || tag[0].match(/\bhref\s*=\s*([^\s>]+)/i);
    if (!href) continue;
    const value = (href[2] || href[1] || '').split(/[?#]/)[0];
    if (!value || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(value) || value.includes('\0')) {
      fail('HTML linked stylesheet must be a local path.');
    }
    const candidate = value.startsWith('/')
      ? path.resolve(root, value.replace(/^\/+/, ''))
      : path.resolve(path.dirname(htmlPath), value);
    if (!within(root, candidate)) fail('HTML linked stylesheet escapes projectRoot.');
    assertNoReparse(root, candidate);
    if (!fs.existsSync(candidate) || !fs.lstatSync(candidate).isFile() || path.extname(candidate).toLowerCase() !== '.css') {
      fail('HTML linked stylesheet must identify a contained .css file.');
    }
    if (!result.includes(candidate)) result.push(fs.realpathSync.native(candidate));
  }
  return result;
}

async function loadDesignSystem(root, options, config, upstream) {
  if (!options.useDesignSystem || config.designSystem?.enabled === false) return null;
  const names = ['DESIGN.md', 'Design.md', 'design.md', 'docs/DESIGN.md', '.agents/context/DESIGN.md'];
  const relative = names.find(name => fs.existsSync(path.join(root, name)));
  if (!relative) return null;
  const mdPath = path.resolve(root, relative);
  assertNoReparse(root, mdPath);
  const frontmatter = upstream.parseFrontmatter(readBounded(mdPath, LIMITS.designBytes));
  if (!frontmatter || typeof frontmatter !== 'object') return null;
  let sidecar = null;
  let sidecarPath = null;
  for (const name of ['.impeccable/design.json', 'DESIGN.json', path.join(path.dirname(relative), 'DESIGN.json')]) {
    const value = readJsonFileStrict(root, name, LIMITS.designBytes);
    if (value) { sidecar = value; sidecarPath = path.resolve(root, name); break; }
  }
  return upstream.normalizeDesignSystem({
    frontmatter,
    sidecar,
    sourcePath: mdPath,
    sidecarPath,
    mdNewerThanJson: false,
  });
}

function registryContract(antipatterns, engineSupport) {
  const regexRules = new Set([
    'side-tab', 'border-accent-on-rounded', 'overused-font', 'flat-type-hierarchy',
    'gradient-text', 'ai-color-palette', 'monotonous-spacing', 'bounce-easing',
    'dark-glow', 'radial-halo', 'marquee', 'em-dash-overuse',
    'marketing-buzzword', 'aphoristic-cadence', 'broken-image', 'gray-on-color',
    'layout-transition', 'codex-grid-background',
  ]);
  const browserOnlyRules = new Set([
    'script-error', 'content-hidden-at-rest', 'edge-flush-cards', 'text-occlusion',
    'first-viewport-column-overflow', 'body-text-viewport-edge', 'text-overflow',
    'image-hover-transform',
  ]);
  return antipatterns.map(rule => ({
    id: rule.id,
    category: rule.category || null,
    severity: rule.severity || 'warning',
    advisory: rule.advisory === true,
    scopes: Array.isArray(rule.scopes) ? [...rule.scopes] : [],
    engineFamilies: [
      ...(regexRules.has(rule.id) ? ['regex'] : []),
      ...(!browserOnlyRules.has(rule.id) ? ['static-html'] : []),
      ...(engineSupport.browser ? ['browser'] : []),
      ...(rule.id === 'low-contrast' && engineSupport.visual ? ['visual'] : []),
    ],
  }));
}

function getCanonicalStaticRuntimeState() {
  const state = globalThis.__ftkStaticHtmlRuntime
  if (!state || state.initialized !== true || !(state.loadedPackages instanceof Set)) {
    fail('Canonical static-HTML runtime was not initialized.')
  }
  const expected = new Set(Object.keys(state.expectedPackages || {}))
  const loaded = [...state.loadedPackages].sort()
  if (!loaded.every(name => expected.has(name))) fail('Static-HTML runtime loaded a package outside the canonical snapshot.')
  if (state.quickSortLoaded === true) fail('source-map-js quick-sort.js reached the static-HTML runtime.')
  return {
    moduleRoot: state.moduleRoot,
    expectedPackages: [...expected].sort(),
    loadedPackages: loaded,
    resolvedSpecifiers: [...(state.resolvedModules || new Map())]
      .map(([specifier, resolved]) => ({ specifier, path: path.relative(state.moduleRoot, resolved).split(path.sep).join('/') }))
      .sort((a, b) => a.specifier.localeCompare(b.specifier)),
    quickSortLoaded: false,
  }
}

function assertFullStaticHtmlExecution(profile, filePath) {
  const events = Array.isArray(profile?.events) ? profile.events : []
  const required = new Set([
    'parse-document',
    'css-rules',
    'css-selectors',
    'compute-styles',
  ])
  const observed = new Set(events.filter(event => event.engine === 'static-html').map(event => event.ruleId))
  for (const ruleId of required) {
    if (!observed.has(ruleId)) fail('Canonical static-HTML engine did not execute ' + ruleId + ': ' + filePath)
  }
  return getCanonicalStaticRuntimeState()
}
function findingEngine(profile, ruleId, fallback) {
  const event = profile.events.find(item => Array.isArray(item.findingIds) && item.findingIds.includes(ruleId));
  return event?.engine || fallback;
}

function normalizeFinding(item, root, profile, fallbackEngine, suppressedReason = null) {
  const file = item.file && path.isAbsolute(item.file) && root ? relativeDisplay(root, item.file) : String(item.file || '<payload>');
  return {
    ruleId: item.antipattern,
    severity: item.severity || 'warning',
    classification: item.category || null,
    message: item.description || '',
    path: file.split(path.sep).join('/'),
    location: item.line ? { line: item.line, column: null } : null,
    snippet: item.snippet || '',
    engine: findingEngine(profile, item.antipattern, fallbackEngine),
    scopes: item.__ruleScopes || [],
    advisory: item.advisory === true,
    ignored: Boolean(suppressedReason),
    suppressed: Boolean(suppressedReason),
    suppressionReason: suppressedReason,
    importedBy: Array.isArray(item.importedBy) ? item.importedBy : [],
  };
}

async function analyzeContent(content, displayPath, absolutePath, root, context) {
  const profile = context.upstream.createDetectorProfile();
  context.profiles.add(profile);
  const isHtml = /\.html?$/i.test(displayPath);
  let raw;
  if (isHtml && absolutePath) {
    for (const cssPath of extractLinkedCss(root, absolutePath, content)) {
      readBounded(cssPath, LIMITS.fileBytes, context.resourceState);
      context.linkedCss.add(relativeDisplay(root, cssPath));
    }
    raw = await context.upstream.detectHtml(absolutePath, {
      inlineIgnores: false,
      designSystem: context.designSystem || undefined,
      profile,
    });
    context.staticRuntimeReports.push(assertFullStaticHtmlExecution(profile, absolutePath));
  } else {
    raw = context.upstream.detectText(content, displayPath, {
      inlineIgnores: false,
      designSystem: context.designSystem || undefined,
      viewport: context.options.viewport || undefined,
      profile,
    });
  }
  const activeInline = context.options.inlineIgnores
    ? new Set(context.upstream.applyInlineIgnores(raw, content))
    : new Set(raw);
  const findings = raw.map(item => ({ item, reason: activeInline.has(item) ? null : 'inline-ignore', profile }));
  return { findings, profile };
}

function applyFilters(records, context) {
  const activeInline = records.filter(record => !record.reason).map(record => record.item);
  const activeConfig = new Set(context.upstream.filterDetectionFindings(activeInline, context.config));
  for (const record of records) if (!record.reason && !activeConfig.has(record.item)) record.reason = 'project-config';
  const scopeSet = new Set(context.options.scopes);
  for (const record of records) {
    const rule = context.ruleMap.get(record.item.antipattern);
    record.item.__ruleScopes = rule?.scopes || [];
    if (!record.reason && scopeSet.size && !(rule?.scopes || []).some(scope => scopeSet.has(scope))) record.reason = 'scope';
    if (!record.reason && !context.options.includeAdvisory && record.item.advisory === true) record.reason = 'advisory-disabled';
  }
  return records;
}

function resultContract(operation, root, context, records, reportExtra = {}) {
  const active = records.filter(record => !record.reason);
  const primary = active.filter(record => record.item.advisory !== true);
  const advisory = active.filter(record => record.item.advisory === true);
  const uniqueProfiles = [...context.profiles];
  const profileEvents = uniqueProfiles.flatMap(value => value.events || []);
  const profile = { events: profileEvents };
  return {
    schemaVersion: 2,
    operation,
    effects: ['LOCAL_READ_ONLY'],
    source: {
      kind: 'pinned-upstream-analytics-through-ftk-boundary',
      version: context.policy.upstreamVersion,
      commit: context.policy.upstreamCommit,
      detectorContractSha256: context.policy.detectorContract.registrySha256,
    },
    ruleCatalog: context.catalog,
    findings: active.map(record => normalizeFinding(record.item, root, profile, reportExtra.engine || 'regex')),
    suppressedFindings: records.filter(record => record.reason).map(record => normalizeFinding(record.item, root, profile, reportExtra.engine || 'regex', record.reason)),
    summary: {
      total: active.length,
      primary: primary.length,
      advisory: advisory.length,
      suppressed: records.length - active.length,
      result: primary.length ? 'findings' : (advisory.length ? 'advisory-only' : 'clean'),
      resultCode: primary.length ? 2 : 0,
    },
    presentation: { structured: true, quiet: context.options.quiet, advisoryAffectsResult: false },
    report: {
      enginesExecuted: [...new Set(profileEvents.map(event => event.engine).filter(Boolean))],
      rulesConsidered: context.catalog.map(rule => rule.id),
      profiler: context.options.profile ? context.upstream.summarizeDetectorProfile(profile) : [],
      viewport: context.options.viewport,
      viewportApplication: context.options.viewport ? 'browser-file-operation-only' : 'not-requested',
      scopes: context.options.scopes,
      linkedCss: [...context.linkedCss].sort(),
      effectiveConfig: {
        designSystemEnabled: context.config.designSystem?.enabled !== false,
        advisoryRules: context.config.advisoryRules || null,
        ignoreRuleCount: context.config.ignoreRules.length,
        ignoreFileCount: context.config.ignoreFiles.length,
        ignoreValueCount: context.config.ignoreValues.length,
      },
      staticHtmlRuntime: context.staticRuntimeReports,
      ...reportExtra,
    },
    safety: {
      limits: LIMITS,
      networkAttempted: false,
      writesPerformed: false,
      projectCodeExecuted: false,
      parentSecretsInherited: false,
      childEnvironmentNames: Object.keys(process.env).sort(),
    },
  };
}

async function loadPinned(policyPath, skillRoot) {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const contract = assertPlainObject(policy.detectorContract, 'detectorContract');
  if (policy.upstreamCommit !== '63b04e2530f5c7b41ea83c133daab24f34912456') fail('Pinned detector commit drifted.');
  const canonicalSkillRoot = fs.realpathSync.native(skillRoot);
  const modules = new Map();
  for (const entry of contract.moduleFingerprints || []) {
    if (!entry || typeof entry.path !== 'string' || !/^[0-9a-f]{40}$/.test(entry.gitBlob) || !/^[0-9a-f]{64}$/.test(entry.sha256)) fail('Detector module fingerprint contract is malformed.');
    if (modules.has(entry.path)) fail('Detector module fingerprint contract contains a duplicate path.');
    const filePath = path.resolve(canonicalSkillRoot, entry.path);
    if (!within(canonicalSkillRoot, filePath)) fail('Detector module path escaped the pinned skill root.');
    assertNoReparse(canonicalSkillRoot, filePath);
    const actual = canonicalFingerprint(filePath);
    if (actual.sha256 !== entry.sha256 || actual.gitBlob !== entry.gitBlob) fail(`Pinned detector canonical module fingerprint mismatch: ${entry.path}`);
    modules.set(entry.path, filePath);
  }
  if (modules.size !== 16) fail('Detector reviewed module inventory drifted.');
  const required = [
    'scripts/detector/registry/antipatterns.mjs',
    'scripts/detector/engines/regex/detect-text.mjs',
    'scripts/detector/engines/static-html/detect-html.mjs',
    'scripts/detector/shared/inline-ignores.mjs',
    'scripts/detector/profile/profiler.mjs',
    'scripts/detector/design-system.mjs',
    'scripts/lib/impeccable-config.mjs',
  ];
  for (const name of required) if (!modules.has(name)) fail(`Required detector module is not fingerprinted: ${name}`);
  const imported = await Promise.all(required.map(name => import(pathToFileURL(modules.get(name)).href)));
  const [registry, regex, staticHtml, inline, profiler, design, config] = imported;
  const ids = registry.ANTIPATTERNS.map(rule => rule.id);
  if (new Set(ids).size !== ids.length || JSON.stringify(ids) !== JSON.stringify(contract.canonicalRuleIds)) {
    fail('Canonical detector rule identities drifted from the reviewed pinned contract.');
  }
  if (canonicalFingerprint(modules.get(required[0])).sha256 !== contract.registrySha256) fail('Canonical registry fingerprint drifted.');
  return {
    policy,
    ANTIPATTERNS: registry.ANTIPATTERNS,
    RULE_SCOPES: registry.RULE_SCOPES,
    RULE_ENGINE_SUPPORT: registry.RULE_ENGINE_SUPPORT,
    detectText: regex.detectText,
    detectHtml: staticHtml.detectHtml,
    applyInlineIgnores: inline.applyInlineIgnores,
    createDetectorProfile: profiler.createDetectorProfile,
    summarizeDetectorProfile: profiler.summarizeDetectorProfile,
    parseFrontmatter: design.parseFrontmatter,
    normalizeDesignSystem: design.normalizeDesignSystem,
    filterDetectionFindings: config.filterDetectionFindings,
    shouldIgnoreDetectionFile: config.shouldIgnoreDetectionFile,
  };
}

async function run(request, policyPath, skillRoot) {
  assertPlainObject(request, 'request');
  const allowedEnvironment = new Set(['SystemRoot', 'TEMP', 'TMP', 'IMPECCABLE_NO_UPDATE_CHECK', 'IMPECCABLE_NO_TELEMETRY', 'DO_NOT_TRACK']);
  const unexpectedEnvironment = Object.keys(process.env).filter(name => !allowedEnvironment.has(name));
  if (unexpectedEnvironment.length) fail('Detector child inherited an unregistered environment name.');
  const requestKeys = new Set(['operation', 'projectRoot', 'inputPath', 'content', 'contentType', 'options']);
  for (const key of Object.keys(request)) if (!requestKeys.has(key)) fail(`request contains unknown field: ${key}`);
  const upstream = await loadPinned(policyPath, skillRoot);
  const canonicalIds = new Set(upstream.ANTIPATTERNS.map(rule => rule.id));
  const scopeIds = new Set(upstream.RULE_SCOPES);
  const options = validateOptions(request.options, scopeIds);
  const engineSupport = Object.fromEntries(Object.entries(upstream.RULE_ENGINE_SUPPORT).map(([key, value]) => [key, [...value]]));
  const catalog = registryContract(upstream.ANTIPATTERNS, engineSupport);
  const ruleMap = new Map(upstream.ANTIPATTERNS.map(rule => [rule.id, rule]));
  const root = request.operation === 'impeccable.detector.payload' ? null : canonicalRoot(request.projectRoot);
  const config = root ? loadConfig(root, options, canonicalIds) : { ignoreRules: [], ignoreFiles: [], ignoreValues: [], designSystem: { enabled: false } };
  const context = {
    upstream,
    policy: upstream.policy,
    options,
    config,
    catalog,
    ruleMap,
    linkedCss: new Set(),
    profiles: new Set(),
    resourceState: { bytes: 0 },
    staticRuntimeReports: [],
    designSystem: root ? await loadDesignSystem(root, options, config, upstream) : null,
  };

  if (request.operation === 'impeccable.detector.payload') {
    const types = new Set(['html', 'css', 'scss', 'sass', 'less', 'jsx', 'tsx', 'js', 'ts', 'vue', 'svelte', 'astro']);
    if (!types.has(request.contentType)) fail('contentType is not registered for payload detection.');
    if (typeof request.content !== 'string' || Buffer.byteLength(request.content) > LIMITS.payloadBytes) fail('Payload content exceeds the bounded typed payload contract.');
    const analyzed = await analyzeContent(request.content, `<payload>.${request.contentType}`, null, null, context);
    const records = applyFilters(analyzed.findings, context);
    return resultContract(request.operation, null, context, records, {
      engine: 'regex',
      inputMode: 'typed-payload',
      fileCount: 0,
      importGraph: { nodes: 0, edges: 0 },
      framework: null,
      designSystem: { applied: false },
      skippedModes: [{ mode: 'path-authority', reason: 'payload contract intentionally has no filesystem authority' }],
    });
  }

  if (request.operation === 'impeccable.detector.csp') {
    const inventory = walkCspProject(root);
    const csp = analyzeCspRecords(inventory.records);
    return {
      schemaVersion: 2,
      operation: request.operation,
      effects: ['LOCAL_READ_ONLY'],
      source: { kind: 'pinned-upstream-csp-through-ftk-boundary', version: upstream.policy.upstreamVersion, commit: upstream.policy.upstreamCommit },
      analysis: { shape: csp.shape, signals: csp.signals.map(signal => signal.split(path.sep).join('/')) },
      findings: [],
      suppressedFindings: [],
      summary: { total: 0, primary: 0, advisory: 0, suppressed: 0, result: csp.shape ? 'signal-detected' : 'clean', resultCode: 0 },
      report: {
        enginesExecuted: ['csp-static'], rulesConsidered: [], profiler: [],
        fileCount: inventory.records.length, totalBytes: inventory.totalBytes,
        extensionContract: [...CSP_SCAN_EXTENSIONS].sort(), traversalLimits: CSP_LIMITS,
      },
      safety: { limits: { ...LIMITS, csp: CSP_LIMITS }, networkAttempted: false, writesPerformed: false, projectCodeExecuted: false, parentSecretsInherited: false, childEnvironmentNames: Object.keys(process.env).sort() },
    };
  }

  if (request.operation === 'impeccable.detector.local') {
    const file = resolveContained(root, request.inputPath, 'file');
    if (!hasScannableExtension(file)) fail('inputPath extension is not registered for local detection.');
    if (upstream.shouldIgnoreDetectionFile(file, root, config)) {
      return resultContract(request.operation, root, context, [], {
        engine: 'regex', inputMode: 'single-file', fileCount: 0,
        importGraph: { nodes: 0, edges: 0 }, framework: detectFramework(root),
        designSystem: { applied: Boolean(context.designSystem) }, skippedFiles: [relativeDisplay(root, file)],
      });
    }
    const content = readBounded(file, LIMITS.fileBytes, context.resourceState);
    const analyzed = await analyzeContent(content, relativeDisplay(root, file), file, root, context);
    const records = applyFilters(analyzed.findings, context);
    return resultContract(request.operation, root, context, records, {
      engine: HTML_EXTENSIONS.has(path.extname(file).toLowerCase()) ? 'static-html' : 'regex',
      inputMode: 'single-file', fileCount: 1,
      importGraph: { nodes: 1, edges: 0 }, framework: detectFramework(root),
      designSystem: { applied: Boolean(context.designSystem) },
    });
  }

  if (request.operation === 'impeccable.detector.project') {
    const start = request.inputPath ? resolveContained(root, request.inputPath, 'directory') : root;
    const inventory = walkProject(root, start, config, upstream.shouldIgnoreDetectionFile);
    const contentByFile = new Map(inventory.files.map(file => [file, readBounded(file, LIMITS.fileBytes)]));
    const graph = buildImportGraph(root, inventory.files, contentByFile);
    const records = [];
    for (const file of inventory.files) {
      const analyzed = await analyzeContent(contentByFile.get(file), relativeDisplay(root, file), file, root, context);
      const importers = graph.importedBy.get(file);
      if (importers) {
        for (const record of analyzed.findings) record.item.importedBy = [...importers].map(value => relativeDisplay(root, value)).sort();
      }
      records.push(...analyzed.findings);
    }
    applyFilters(records, context);
    return resultContract(request.operation, root, context, records, {
      engine: 'multi-engine-local', inputMode: 'project', fileCount: inventory.files.length,
      importGraph: { nodes: inventory.files.length, edges: graph.edgeCount },
      framework: detectFramework(root), designSystem: { applied: Boolean(context.designSystem) },
    });
  }

  fail(`UNKNOWN detector operation is denied: ${request.operation}`);
}

async function readRequest() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > LIMITS.requestBytes) fail('Detector request exceeds the request limit.');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    fail('Detector request must be valid JSON.');
  }
}

try {
  if (process.argv.length !== 4) fail('Detector boundary requires fixed policy and pinned skill-root arguments.');
  const request = await readRequest();
  const result = await run(request, path.resolve(process.argv[2]), path.resolve(process.argv[3]));
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  const resourceLeaf = typeof error?.resource === 'string' ? error.resource.split(/[\\/]/).filter(Boolean).slice(-1)[0] : '';
  const rawMessage = [error?.message, resourceLeaf ? 'resource=' + resourceLeaf : ''].filter(Boolean).join(' ');
  const message = String(rawMessage || 'Detector boundary failed.')
    .replace(/[A-Za-z]:[\\/][^\r\n"']+/g, '<path>');
  process.stderr.write(`${JSON.stringify({ schemaVersion: 1, error: message })}\n`);
  process.exitCode = 1;
}
