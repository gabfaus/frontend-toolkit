import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const testRoot = path.dirname(fileURLToPath(import.meta.url));
const adapterPath = path.join(testRoot, '..', 'plugin', 'frontend-toolkit', 'security', 'storybook-adapter.mjs');
const lockPath = path.join(testRoot, '..', 'integrations', 'storybook.lock.json');
const adapterSource = readFileSync(adapterPath, 'utf8');
const { detectStorybookProject, planStorybookTool } = await import(pathToFileURL(adapterPath).href);

function createFixture(manifest, config = null) {
  const root = mkdtempSync(path.join(tmpdir(), 'ftk-09i-storybook-'));
  writeFileSync(path.join(root, 'package.json'), JSON.stringify(manifest), 'utf8');
  if (config !== null) {
    const storybook = path.join(root, '.storybook');
    mkdirSync(storybook);
    writeFileSync(path.join(storybook, 'main.js'), config, 'utf8');
  }
  return root;
}

function cleanup(root) {
  rmSync(root, { recursive: true, force: true });
}

const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
assert.equal(lock.classification, 'conditional');
assert.equal(lock.targetPackages[0].version, '10.6.0');
assert.equal(lock.targetPackages[1].version, '10.6.0');
assert.equal(lock.targetPackages[0].license, 'MIT');
assert.equal(lock.installation, 'never-automatic');
assert.equal(lock.runtimeStartup, 'never-automatic');

const empty = createFixture({ name: 'synthetic-empty-project', version: '1.0.0' });
try {
  const detection = detectStorybookProject(empty);
  assert.equal(detection.status, 'OFF');
  assert.equal(detection.statusReason, 'storybook-not-detected');
  assert.equal(planStorybookTool(empty, 'docs').decision, 'DENY');
  assert.equal(planStorybookTool(empty, 'preview').autoStart, false);
  assert.equal(planStorybookTool(empty, 'review-create').decision, 'AUTHORIZATION_REQUIRED');
  assert.equal(planStorybookTool(empty, 'publish').decision, 'AUTHORIZATION_REQUIRED');
} finally {
  cleanup(empty);
}

const incomplete = createFixture(
  {
    name: 'synthetic-incomplete-project',
    devDependencies: { storybook: '^10.6.0' }
  },
  "export default { framework: '@storybook/react-vite' };"
);
try {
  const detection = detectStorybookProject(incomplete);
  assert.equal(detection.status, 'INCOMPLETE');
  assert(detection.missingOrBlocked.includes('storybook-dependency-missing') === false);
  assert.equal(planStorybookTool(incomplete, 'docs').decision, 'DENY');
  assert.equal(planStorybookTool(incomplete, 'testing').status, 'incomplete');
} finally {
  cleanup(incomplete);
}

const eligible = createFixture(
  {
    name: 'synthetic-eligible-project',
    devDependencies: {
      storybook: '^10.6.0',
      '@storybook/react-vite': '^10.6.0',
      '@storybook/addon-mcp': '10.6.0',
      '@storybook/mcp': '10.6.0',
      '@storybook/test': '^10.6.0'
    }
  },
  "export default { framework: '@storybook/react-vite', addons: ['@storybook/addon-mcp'] };"
);
try {
  const detection = detectStorybookProject(eligible);
  assert.equal(detection.status, 'ELIGIBLE');
  assert.equal(detection.evidence.compatibility, 'supported');
  assert.equal(detection.evidence.mcpAddon.present, true);
  assert.equal(detection.evidence.mcpAddon.configured, true);
  assert.equal(detection.testing.available, true);
  assert.equal(planStorybookTool(eligible, 'docs').status, 'available');
  assert.equal(planStorybookTool(eligible, 'preview').status, 'available');
  assert.equal(planStorybookTool(eligible, 'testing').status, 'available');
  assert.equal(planStorybookTool(eligible, 'review-create').status, 'blocked');
  assert.equal(planStorybookTool(eligible, 'review-create').decision, 'AUTHORIZATION_REQUIRED');
  assert.equal(planStorybookTool(eligible, 'remote-review').decision, 'AUTHORIZATION_REQUIRED');
  assert.equal(planStorybookTool(eligible, 'publication').decision, 'AUTHORIZATION_REQUIRED');
  assert.equal(planStorybookTool(eligible, 'unknown-future-tool').decision, 'DENY');
} finally {
  cleanup(eligible);
}

const unsupported = createFixture(
  {
    name: 'synthetic-unsupported-project',
    devDependencies: {
      storybook: '^7.6.0',
      '@storybook/unknown-framework': '^7.6.0'
    }
  },
  "export default { framework: '@storybook/unknown-framework' };"
);
try {
  const detection = detectStorybookProject(unsupported);
  assert.equal(detection.status, 'INCOMPLETE');
  assert(detection.missingOrBlocked.includes('storybook-framework-unsupported'));
  assert(detection.missingOrBlocked.includes('storybook-version-below-minimum'));
  assert.equal(planStorybookTool(unsupported, 'preview').decision, 'DENY');
} finally {
  cleanup(unsupported);
}

const dynamic = createFixture(
  {
    name: 'synthetic-dynamic-project',
    devDependencies: {
      storybook: '^10.6.0',
      '@storybook/react-vite': '^10.6.0'
    }
  },
  'export default { framework: process.env.STORYBOOK_FRAMEWORK };'
);
try {
  const detection = detectStorybookProject(dynamic);
  assert.equal(detection.status, 'INCOMPLETE');
  assert(detection.missingOrBlocked.includes('storybook-framework-undetectable'));
} finally {
  cleanup(dynamic);
}

assert(!/\b(?:fetch|spawn|exec|execFile|fork)\s*\(/u.test(adapterSource));
assert(!adapterSource.includes('child_process'));
assert(adapterSource.includes('autoStart: false'));
assert(adapterSource.includes('install: false'));
assert(adapterSource.includes('network: false'));

console.log('PASS: project without Storybook is OFF.');
console.log('PASS: incomplete, unsupported and dynamically configured Storybook projects stay INCOMPLETE/OFF.');
console.log('PASS: eligible Storybook docs, preview and testing are conditional and never auto-start.');
console.log('PASS: review-create, remote review, publication and unknown tools fail closed.');
console.log('STORYBOOK INSTALLS=0; STORYBOOK SERVERS STARTED=0; REMOTE PUBLICATIONS=0');
