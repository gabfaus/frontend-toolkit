import {
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
  statSync
} from 'node:fs';
import { join } from 'node:path';

const MINIMUM_STORYBOOK_MAJOR = 8;
const MAX_CONFIG_BYTES = 128 * 1024;

export const SUPPORTED_FRAMEWORKS = Object.freeze([
  '@storybook/angular',
  '@storybook/html-vite',
  '@storybook/nextjs',
  '@storybook/react-vite',
  '@storybook/react-webpack5',
  '@storybook/svelte-vite',
  '@storybook/vue3',
  '@storybook/vue3-vite'
]);

const CORE_DEPENDENCY_EXCLUSIONS = new Set([
  '@storybook/addon-mcp',
  '@storybook/mcp',
  '@storybook/test',
  '@storybook/addon-test',
  '@storybook/test-runner'
]);

const CONFIG_NAMES = Object.freeze([
  'main.js',
  'main.cjs',
  'main.mjs',
  'main.ts',
  'main.cts',
  'main.mts'
]);

const KNOWN_TOOLS = Object.freeze([
  'docs',
  'preview',
  'preview-development',
  'testing',
  'review-create',
  'remote-review',
  'publish',
  'publication',
  'chromatic'
]);

const BLOCKED_EFFECTS = Object.freeze({
  'review-create': 'AUTHORIZATION_REQUIRED',
  'remote-review': 'AUTHORIZATION_REQUIRED',
  publish: 'AUTHORIZATION_REQUIRED',
  publication: 'AUTHORIZATION_REQUIRED',
  chromatic: 'AUTHORIZATION_REQUIRED'
});

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isRegularNonSymlink(path) {
  try {
    return lstatSync(path).isFile() && statSync(path).isFile();
  } catch {
    return false;
  }
}

function isDirectory(path) {
  try {
    return lstatSync(path).isDirectory() && statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function readJson(path) {
  if (!isRegularNonSymlink(path)) return { value: null, reason: 'missing' };
  try {
    return { value: JSON.parse(readFileSync(path, 'utf8')), reason: null };
  } catch {
    return { value: null, reason: 'invalid-json' };
  }
}

function dependencyMap(manifest) {
  const result = new Map();
  if (!isPlainObject(manifest)) return result;
  for (const field of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
    if (!isPlainObject(manifest[field])) continue;
    for (const [name, version] of Object.entries(manifest[field])) {
      if (typeof version === 'string' && !result.has(name)) result.set(name, version);
    }
  }
  return result;
}

function firstVersionMajor(dependencies, names) {
  for (const name of names) {
    const value = dependencies.get(name);
    if (typeof value !== 'string') continue;
    const match = value.match(/(?:^|[^0-9])(\d{1,3})(?:\.|$)/u);
    if (match) return Number(match[1]);
  }
  return null;
}

function findConfig(storybookRoot) {
  for (const name of CONFIG_NAMES) {
    const path = join(storybookRoot, name);
    if (isRegularNonSymlink(path)) return { name, path };
  }
  return null;
}

function readConfig(config) {
  if (!config) return { source: '', reason: 'missing' };
  try {
    const buffer = readFileSync(config.path);
    if (buffer.byteLength > MAX_CONFIG_BYTES) return { source: '', reason: 'too-large' };
    return { source: buffer.toString('utf8'), reason: null };
  } catch {
    return { source: '', reason: 'unreadable' };
  }
}

function extractFramework(source) {
  const simple = source.match(/\bframework\s*:\s*['"]([^'"]+)['"]/u);
  if (simple) return simple[1];
  const objectName = source.match(/\bframework\s*:\s*\{[\s\S]{0,400}?\bname\s*:\s*['"]([^'"]+)['"]/u);
  if (objectName) return objectName[1];
  return null;
}

function hasConfiguredAddon(source, addon) {
  return new RegExp(`['"]${addon.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}['"]`, 'u').test(source);
}

function baseCapability(tool, status, decision, reason, extra = {}) {
  return {
    tool,
    status,
    decision,
    reason,
    autoStart: false,
    install: false,
    network: false,
    ...extra
  };
}

function capabilitiesFor(detection) {
  const conditionallyAvailable = detection.status === 'ELIGIBLE';
  const conditionalStatus = conditionallyAvailable ? 'available' : detection.status.toLowerCase();
  const conditionalDecision = conditionallyAvailable ? 'ALLOW_CONDITIONALLY' : 'DENY';
  const capabilities = {
    docs: baseCapability('docs', conditionalStatus, conditionalDecision, detection.statusReason),
    preview: baseCapability('preview', conditionalStatus, conditionalDecision, detection.statusReason),
    'preview-development': baseCapability('preview-development', conditionalStatus, conditionalDecision, detection.statusReason),
    testing: detection.testing.available
      ? baseCapability('testing', conditionalStatus, conditionalDecision, detection.statusReason)
      : baseCapability('testing', 'incomplete', 'DENY', 'storybook-test-capability-not-detected')
  };
  for (const [tool, decision] of Object.entries(BLOCKED_EFFECTS)) {
    const status = tool === 'review-create' ? 'blocked' : 'deferred';
    capabilities[tool] = baseCapability(tool, status, decision, 'external-effect-requires-current-authorization', {
      externalEffect: true,
      mcpAddonRequired: true
    });
  }
  return capabilities;
}

export function detectStorybookProject(projectRoot) {
  let root;
  try {
    if (typeof projectRoot !== 'string' || !isDirectory(projectRoot)) {
      return { status: 'OFF', statusReason: 'project-root-unavailable', capabilities: {} };
    }
    root = realpathSync(projectRoot);
  } catch {
    return { status: 'OFF', statusReason: 'project-root-unavailable', capabilities: {} };
  }

  const manifestResult = readJson(join(root, 'package.json'));
  const manifest = isPlainObject(manifestResult.value) ? manifestResult.value : null;
  const dependencies = dependencyMap(manifest);
  const storybookRoot = join(root, '.storybook');
  const configDirectory = isDirectory(storybookRoot);
  const config = findConfig(storybookRoot);
  const configResult = readConfig(config);
  const frameworkFromConfig = extractFramework(configResult.source);
  const coreDependencyNames = [...dependencies.keys()].filter(name =>
    name === 'storybook' || (name.startsWith('@storybook/') && !CORE_DEPENDENCY_EXCLUSIONS.has(name))
  );
  const coreDependencyPresent = coreDependencyNames.length > 0;
  const mcpAddonPresent = dependencies.has('@storybook/addon-mcp') || dependencies.has('@storybook/mcp');
  const mcpAddonConfigured = hasConfiguredAddon(configResult.source, '@storybook/addon-mcp') ||
    hasConfiguredAddon(configResult.source, '@storybook/mcp');
  const testDependencyNames = ['@storybook/test', '@storybook/addon-test', '@storybook/test-runner']
    .filter(name => dependencies.has(name));
  const observed = configDirectory || coreDependencyPresent;
  const reasons = [];

  if (!observed) {
    const result = {
      status: 'OFF',
      statusReason: 'storybook-not-detected',
      evidence: {
        config: false,
        dependency: false,
        framework: null,
        mcpAddon: { present: false, configured: false }
      },
      testing: { available: false, dependencies: [] }
    };
    result.capabilities = capabilitiesFor(result);
    return result;
  }

  if (!config) reasons.push('storybook-config-missing');
  if (configResult.reason) reasons.push(`storybook-config-${configResult.reason}`);
  if (!coreDependencyPresent) reasons.push('storybook-dependency-missing');
  if (!frameworkFromConfig) reasons.push('storybook-framework-undetectable');
  if (frameworkFromConfig && !SUPPORTED_FRAMEWORKS.includes(frameworkFromConfig)) {
    reasons.push('storybook-framework-unsupported');
  } else if (frameworkFromConfig && !dependencies.has(frameworkFromConfig)) {
    reasons.push('storybook-framework-dependency-missing');
  }
  const storybookMajor = firstVersionMajor(dependencies, ['storybook', ...coreDependencyNames]);
  if (storybookMajor === null) reasons.push('storybook-version-undetectable');
  else if (storybookMajor < MINIMUM_STORYBOOK_MAJOR) reasons.push('storybook-version-below-minimum');

  const result = {
    status: reasons.length === 0 ? 'ELIGIBLE' : 'INCOMPLETE',
    statusReason: reasons.length === 0 ? 'minimum-prerequisites-detected' : reasons[0],
    evidence: {
      config: Boolean(config),
      configFile: config?.name ?? null,
      dependency: coreDependencyPresent,
      dependencyNames: coreDependencyNames,
      framework: frameworkFromConfig,
      storybookMajor,
      compatibility: reasons.includes('storybook-framework-unsupported') || reasons.includes('storybook-version-below-minimum')
        ? 'unsupported'
        : reasons.length === 0 ? 'supported' : 'undetermined',
      mcpAddon: {
        present: mcpAddonPresent,
        configured: mcpAddonConfigured,
        requiredFor: ['review-create', 'remote-review', 'publish']
      }
    },
    missingOrBlocked: reasons,
    testing: {
      available: testDependencyNames.length > 0,
      dependencies: testDependencyNames
    }
  };
  result.capabilities = capabilitiesFor(result);
  return result;
}

export function planStorybookTool(projectRoot, tool) {
  if (typeof tool !== 'string' || !KNOWN_TOOLS.includes(tool)) {
    return {
      tool: typeof tool === 'string' ? tool : null,
      status: 'blocked',
      decision: 'DENY',
      reason: 'unknown-tool',
      autoStart: false,
      install: false,
      network: false
    };
  }
  const detection = detectStorybookProject(projectRoot);
  return {
    ...detection.capabilities[tool],
    detection: {
      status: detection.status,
      statusReason: detection.statusReason,
      evidence: detection.evidence,
      missingOrBlocked: detection.missingOrBlocked ?? [],
      testing: detection.testing
    }
  };
}
