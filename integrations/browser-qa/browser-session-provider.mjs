import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  BROWSER_QA_SCHEMA_VERSION,
  BrowserQaContractError,
  FAILURE_TYPES,
  boundedText,
  buildEmptyEvidence,
  ensureContainedPath,
  extractUrls,
  flattenEvidenceNodes,
  inferFocusedNode,
  isLoopbackUrl,
  normalizeArtifactBasename,
  parseCliSnapshot,
  safeUrlSummary,
  sha256File,
  validateArtifact,
  validateTransaction,
} from './browser-qa-contract.mjs';

const MAX_CLI_OUTPUT_CHARACTERS = 65536;
const MAX_ACTION_TIMEOUT_MS = 30000;
const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const LOCK_PATH = path.resolve(MODULE_DIRECTORY, '..', 'browser-qa.lock.json');

function parseArgs(argv) {
  const result = { root: null, input: null, cliEntry: null, cliPackageRoot: null, validateOnly: false, synthetic: false };
  const valueArguments = new Set(['--root', '--input', '--cli-entry', '--cli-package-root']);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--validate-only') {
      result.validateOnly = true;
    } else if (argument === '--synthetic') {
      result.synthetic = true;
    } else if (valueArguments.has(argument)) {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new BrowserQaContractError(`${argument} requires a value.`);
      const keyByArgument = {
        '--root': 'root',
        '--input': 'input',
        '--cli-entry': 'cliEntry',
        '--cli-package-root': 'cliPackageRoot',
      };
      result[keyByArgument[argument]] = value;
    } else {
      throw new BrowserQaContractError(`Unknown provider argument: ${argument}.`);
    }
  }
  if (!result.root || !result.input) throw new BrowserQaContractError('--root and --input are required.');
  if (!result.validateOnly && (!result.cliEntry || !result.cliPackageRoot)) {
    throw new BrowserQaContractError('--cli-entry and --cli-package-root are required for execution.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  return result;
}

function canonicalDirectory(value, label) {
  const resolved = path.resolve(value);
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    throw new BrowserQaContractError(`${label} must be an existing directory.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  return fs.realpathSync(resolved);
}

function canonicalSessionRoot(value) {
  const real = canonicalDirectory(value, 'Provider root');
  const parent = fs.realpathSync(path.dirname(real));
  const hostTemp = process.env.FTK_BROWSER_QA_HOST_TEMP;
  if (!hostTemp) throw new BrowserQaContractError('The dedicated host temporary root is not present in the child environment.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  const expectedBase = fs.realpathSync(path.join(hostTemp, 'ftk-playwright'));
  if (!samePath(parent, expectedBase) || path.basename(real).toLowerCase() === 'ftk-playwright') {
    throw new BrowserQaContractError('Provider root must be a dedicated child of the OS temporary Browser QA root.', 'INVALID_INPUT');
  }
  return real;
}

function canonicalFile(value, label, root = null) {
  const resolved = path.resolve(value);
  if (root) ensureContainedPath(root, resolved, { mustExist: true, label });
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
    throw new BrowserQaContractError(`${label} must be an existing file.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const stat = fs.lstatSync(resolved);
  if (stat.isSymbolicLink()) throw new BrowserQaContractError(`${label} may not be a symbolic link.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  return fs.realpathSync(resolved);
}

function readJson(filePath, label) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new BrowserQaContractError(`${label} is not valid JSON: ${boundedText(error.message, 512)}.`, 'OUTPUT_CONTRACT_FAILURE');
  }
}

function readPackage(packageRoot, label) {
  const packageJsonPath = canonicalFile(path.join(packageRoot, 'package.json'), `${label} package.json`, packageRoot);
  const packageJson = readJson(packageJsonPath, `${label} package.json`);
  return { packageJsonPath, packageJson };
}

function samePath(left, right) {
  return path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
}

function getCliEntryFromPackage(packageRoot, packageJson) {
  const bin = packageJson.bin;
  const configured = typeof bin === 'string' ? bin : bin?.['playwright-cli'];
  const entry = configured || packageJson.main || 'cli.js';
  if (typeof entry !== 'string' || entry.length < 1 || entry.includes('..')) {
    throw new BrowserQaContractError('Playwright CLI package entry is not a safe relative path.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const entryPath = path.resolve(packageRoot, entry);
  ensureContainedPath(packageRoot, entryPath, { mustExist: true, label: 'Playwright CLI entry' });
  return canonicalFile(entryPath, 'Playwright CLI entry', packageRoot);
}

function hashStatus(cliEntry, expectedHash, synthetic) {
  try {
    const actualHash = sha256File(cliEntry);
    if (synthetic) return { actualHash, status: 'SYNTHETIC_TEST_DOUBLE' };
    if (expectedHash && actualHash.toLowerCase() !== expectedHash.toLowerCase()) {
      throw new BrowserQaContractError('Playwright CLI entry hash does not match the frozen lock.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
    }
    return { actualHash, status: expectedHash ? 'VERIFIED' : 'UNVERIFIED_BYTES' };
  } catch (error) {
    if (error instanceof BrowserQaContractError) throw error;
    return { actualHash: null, status: 'UNVERIFIED_BYTES' };
  }
}

function resolveRuntimePackage(nodeModulesRoot, packageName, expectedVersion) {
  const packageRoot = path.join(nodeModulesRoot, packageName);
  if (!fs.existsSync(packageRoot)) {
    throw new BrowserQaContractError(`${packageName} is not materialized beside the pinned CLI.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const { packageJsonPath, packageJson } = readPackage(packageRoot, packageName);
  if (packageJson.name !== packageName || packageJson.version !== expectedVersion) {
    throw new BrowserQaContractError(`${packageName} version or package identity is not the frozen runtime.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  return { root: fs.realpathSync(packageRoot), packageJsonPath, version: packageJson.version };
}

function resolveBrowserIdentity(playwrightCoreRoot, lock) {
  const browsersPath = canonicalFile(path.join(playwrightCoreRoot, 'browsers.json'), 'Playwright browser manifest', playwrightCoreRoot);
  const browsers = readJson(browsersPath, 'Playwright browser manifest').browsers;
  const chromium = Array.isArray(browsers) ? browsers.find((item) => item?.name === 'chromium') : null;
  if (!chromium || typeof chromium.revision !== 'string' || typeof chromium.browserVersion !== 'string') {
    throw new BrowserQaContractError('The exact Playwright runtime did not expose a stable Chromium revision.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const browserCacheValue = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!browserCacheValue) {
    throw new BrowserQaContractError('The prepared Playwright browser cache is not present in the child environment.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const browserCache = canonicalDirectory(browserCacheValue, 'Playwright browser cache');
  const browserDirectory = path.join(browserCache, `chromium-${chromium.revision}`);
  const markerPath = canonicalFile(path.join(browserDirectory, 'INSTALLATION_COMPLETE'), 'Chromium installation marker', browserCache);
  const executablePath = canonicalFile(path.join(browserDirectory, 'chrome-win64', 'chrome.exe'), 'Chromium executable', browserCache);
  const versionMarkerPath = canonicalFile(path.join(browserDirectory, 'chrome-win64', `${chromium.browserVersion}.manifest`), 'Chromium version marker', browserCache);
  const versionMarker = fs.readFileSync(versionMarkerPath, 'utf8');
  if (!versionMarker.includes(chromium.browserVersion)) {
    throw new BrowserQaContractError('The prepared Chromium executable version marker does not match the exact runtime.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const browserLock = lock.browserMaterialization;
  if (!browserLock?.revisionPinTracked || String(browserLock.revision) !== chromium.revision) {
    throw new BrowserQaContractError('The Browser QA lock does not record the exact Chromium revision discovered by the runtime.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  return {
    family: 'chromium',
    revision: chromium.revision,
    browserVersion: chromium.browserVersion,
    platform: 'win64',
    cachePath: browserCache,
    executablePath,
    executableSha256: sha256File(executablePath),
    revisionStatus: 'VERIFIED_RUNTIME_DESCRIPTOR_AND_INSTALLATION_MARKERS',
    revisionPinTracked: true,
    chromiumSandbox: process.env.PLAYWRIGHT_MCP_SANDBOX !== 'false',
    sandboxControl: process.env.PLAYWRIGHT_MCP_SANDBOX === 'false' ? 'explicit-gate-override' : 'runtime-default',
    executableRelationship: 'playwright-core browsers.json -> chromium revision directory -> Chrome for Testing executable',
    markerPath,
  };
}

function resolveCliIdentity(cliEntryValue, cliPackageRootValue, syntheticRequested) {
  const cliPackageRoot = canonicalDirectory(cliPackageRootValue, 'Playwright CLI package root');
  const { packageJsonPath, packageJson } = readPackage(cliPackageRoot, '@playwright/cli');
  const lock = readJson(LOCK_PATH, 'browser-qa lock');
  const expectedCli = lock.playwright?.cli;
  if (!expectedCli || expectedCli.id !== '@playwright/cli' || expectedCli.version !== '0.1.19') {
    throw new BrowserQaContractError('The Browser QA CLI lock is incomplete.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const synthetic = packageJson.ftkSyntheticTestDouble === true;
  if (syntheticRequested !== synthetic) {
    throw new BrowserQaContractError('Synthetic CLI execution requires an explicit matching test double.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  if (packageJson.name !== expectedCli.id || packageJson.version !== expectedCli.version) {
    throw new BrowserQaContractError('Playwright CLI package identity or version is not the frozen target.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  if (packageJson.license && packageJson.license !== expectedCli.license) {
    throw new BrowserQaContractError('Playwright CLI package license does not match the frozen target.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  }
  const cliEntry = canonicalFile(cliEntryValue, 'Playwright CLI entry', cliPackageRoot);
  const expectedEntry = getCliEntryFromPackage(cliPackageRoot, packageJson);
  if (!samePath(cliEntry, expectedEntry)) throw new BrowserQaContractError('CLI entry is not the package-owned bin entry.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  const hash = hashStatus(cliEntry, expectedCli.cliEntrySha256, synthetic);
  const nodeModulesRoot = path.dirname(path.dirname(cliPackageRoot));
  const playwright = resolveRuntimePackage(nodeModulesRoot, 'playwright', lock.playwright.effectiveCliRuntime.find((item) => item.id === 'playwright').version);
  const playwrightCore = resolveRuntimePackage(nodeModulesRoot, 'playwright-core', lock.playwright.effectiveCliRuntime.find((item) => item.id === 'playwright-core').version);
  const limitations = [];
  if (hash.status === 'UNVERIFIED_BYTES') limitations.push('CLI entry bytes could not be hashed stably in this environment; package/path identity was checked, but byte provenance remains limited.');
  if (synthetic) limitations.push('Synthetic CLI test double is not real browser materialization and cannot produce a dedicated PASS.');
  const browser = synthetic ? null : resolveBrowserIdentity(playwrightCore.root, lock);
  if (browser?.chromiumSandbox === false) limitations.push('Chromium sandbox was explicitly disabled by the gate override; this is not a secure default for untrusted pages.');
  return {
    expectedPackage: expectedCli.id,
    expectedVersion: expectedCli.version,
    packageName: packageJson.name,
    packageVersion: packageJson.version,
    packageLicense: packageJson.license ?? null,
    packageJson: path.basename(packageJsonPath),
    entryName: path.basename(cliEntry),
    entrySha256: hash.actualHash,
    expectedEntrySha256: expectedCli.cliEntrySha256 ?? null,
    entryHashStatus: hash.status,
    executableProvenance: 'package-owned-node-entry',
    runtime: {
      nodePackage: playwright.version,
      nodeCorePackage: playwrightCore.version,
      nodePackageIdentity: 'frozen-effective-cli-runtime',
    },
    synthetic,
    browserRevisionVerified: browser !== null,
    browser,
    limitations,
    cliEntry,
    cliPackageRoot,
  };
}

function childEnvironment() {
  const names = ['SystemRoot', 'ComSpec', 'TEMP', 'TMP'];
  const environment = {};
  for (const name of names) {
    if (process.env[name]) environment[name] = process.env[name];
  }
  environment.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1';
  environment.PLAYWRIGHT_HTML_OPEN = 'never';
  environment.NO_COLOR = '1';
  environment.NO_UPDATE_NOTIFIER = '1';
  const hostTemp = process.env.FTK_BROWSER_QA_HOST_TEMP;
  if (!hostTemp) throw new BrowserQaContractError('The dedicated host temporary root is not present in the CLI child environment.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
  const expected = {
    PLAYWRIGHT_BROWSERS_PATH: path.resolve(hostTemp, 'browser-cache'),
    PWTEST_DAEMON_SESSION_DIR: path.resolve(process.cwd(), 'daemon'),
    PWTEST_SERVER_REGISTRY: path.resolve(process.cwd(), 'server-registry'),
    PWTEST_CLI_GLOBAL_CONFIG: path.resolve(process.cwd()),
  };
  for (const [name, value] of Object.entries(expected)) {
    if (!process.env[name] || !samePath(process.env[name], value)) {
      throw new BrowserQaContractError(`${name} is not bound to the dedicated TEMP session.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
    }
    environment[name] = value;
  }
  const sandboxOverride = process.env.PLAYWRIGHT_MCP_SANDBOX;
  if (sandboxOverride !== undefined) {
    if (!['true', 'false'].includes(sandboxOverride)) throw new BrowserQaContractError('PLAYWRIGHT_MCP_SANDBOX must be an explicit true/false value.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
    environment.PLAYWRIGHT_MCP_SANDBOX = sandboxOverride;
  }
  return environment;
}

function runCli(cliEntry, args, cwd) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let overflowed = false;
    let timedOut = false;
    let settled = false;
    const sessionName = path.basename(path.resolve(cwd));
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/.test(sessionName)) {
      resolve({ exitCode: null, stdout: '', stderr: '', overflowed: false, timedOut: false, errorMessage: 'The temporary session name is not safe.' });
      return;
    }
    const child = spawn(process.execPath, [cliEntry, `-s=${sessionName}`, ...args], {
      cwd,
      env: childEnvironment(),
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const append = (target, chunk) => {
      const text = chunk.toString('utf8');
      const currentLength = target === 'stdout' ? stdout.length : stderr.length;
      const remaining = Math.max(0, MAX_CLI_OUTPUT_CHARACTERS - currentLength);
      if (target === 'stdout') {
        stdout += text.slice(0, remaining);
      } else {
        stderr += text.slice(0, remaining);
      }
      if (text.length > remaining) {
        overflowed = true;
        try { child.kill(); } catch { /* The outer Job Object remains the cleanup authority. */ }
      }
    };
    child.stdout.on('data', (chunk) => append('stdout', chunk));
    child.stderr.on('data', (chunk) => append('stderr', chunk));
    const timeout = setTimeout(() => {
      timedOut = true;
      try { child.kill(); } catch { /* The outer Job Object remains the cleanup authority. */ }
    }, MAX_ACTION_TIMEOUT_MS);
    const finish = (exitCode, errorMessage = '') => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve({
        exitCode: typeof exitCode === 'number' ? exitCode : null,
        stdout: boundedText(stdout, MAX_CLI_OUTPUT_CHARACTERS),
        stderr: boundedText(stderr, MAX_CLI_OUTPUT_CHARACTERS),
        overflowed,
        timedOut,
        errorMessage: boundedText(errorMessage, 1024),
      });
    };
    child.on('error', (error) => finish(null, error.message));
    child.on('close', (exitCode) => finish(exitCode));
  });
}

function requireSuccessfulCommand(result, description) {
  if (result.timedOut) throw new BrowserQaContractError(`${description} exceeded the bounded action timeout.`, 'TIMEOUT');
  if (result.overflowed) throw new BrowserQaContractError(`${description} exceeded the bounded output contract.`, 'OUTPUT_CONTRACT_FAILURE');
  if (result.errorMessage) throw new BrowserQaContractError(`${description} could not execute: ${result.errorMessage}.`, 'DEPENDENCY_OR_RUNTIME_FAILURE');
  if (result.exitCode !== 0) throw new BrowserQaContractError(`${description} failed with exit code ${result.exitCode}.`, 'UPSTREAM_EXECUTION_FAILURE');
}

function snapshotEvidence(parsed, kind, maxNodes) {
  const nodes = parsed.roots ?? [];
  return {
    status: parsed.nodeCount > 0 ? 'COMPLETE' : 'INCOMPLETE',
    evidenceKind: 'structured-browser-snapshot',
    source: 'playwright-cli.snapshot',
    nodeCount: parsed.nodeCount,
    truncated: parsed.truncated,
    [kind === 'dom' ? 'nodes' : 'tree']: nodes,
    evidenceRefs: [kind],
    limitations: [
      'The pinned CLI snapshot is structured evidence, not raw HTML.',
      'Original DOM tag names and computed styles are not exposed by this CLI operation.',
      ...(parsed.truncated ? ['Snapshot node limit was reached.'] : []),
    ],
  };
}

function findTarget(snapshot, target) {
  const nodes = flattenEvidenceNodes(snapshot?.roots ?? []);
  if (target.kind === 'label') {
    return nodes.find((node) => node.accessibleName === target.label && ['textbox', 'combobox', 'searchbox', 'spinbutton'].includes(node.role)) ??
      nodes.find((node) => node.accessibleName === target.label);
  }
  return nodes.find((node) => node.role === target.role && (target.name === undefined || node.accessibleName === target.name));
}

function focusObservation(before, after, operation, target, observationId) {
  const expected = operation.expectedFocus ?? 'unknown';
  let status = 'INCOMPLETE';
  if (expected === 'unknown') status = 'UNKNOWN';
  else if (expected === 'none') status = after ? 'FAIL' : 'PASS';
  else if (!after) status = 'INCOMPLETE';
  else if (expected === 'previous') status = before?.ref && after.ref === before.ref ? 'PASS' : 'FAIL';
  else if (expected === 'target') status = target?.ref && after.ref === target.ref ? 'PASS' : 'FAIL';
  else if (after) status = 'PASS';
  return {
    id: observationId,
    status,
    action: operation.action,
    focusBefore: before,
    focusAfter: after,
    expectedBehavior: expected,
    target: target ? { ref: target.ref ?? null, role: target.role, accessibleName: target.accessibleName } : null,
    focusVisible: null,
    focusVisibility: {
      status: 'INCOMPLETE',
      evidenceRefs: ['snapshot.before', 'snapshot.after'],
      limitations: ['The pinned CLI snapshot does not expose computed focus visibility.'],
    },
    evidenceRefs: ['snapshot.before', 'snapshot.after'],
    limitations: after ? [] : ['The CLI snapshot did not expose a focused node.'],
  };
}

function parseRequestEvidence(output, maxRequests) {
  const urls = extractUrls(output).slice(0, maxRequests);
  const items = urls.map((url) => ({
    url: safeUrlSummary(url),
    origin: (() => { try { return new URL(url).origin; } catch { return '[unparseable]'; } })(),
    loopback: isLoopbackUrl(url),
    method: 'UNKNOWN',
    resourceType: 'UNKNOWN',
  }));
  const external = items.filter((item) => !item.loopback);
  return {
    status: urls.length > 0 ? (external.length ? 'FAIL' : 'COMPLETE') : 'INCOMPLETE',
    items,
    externalSubrequests: {
      observed: external.map((item) => item.origin),
      blocked: [],
      status: external.length ? 'VERIFICATION_FAILURE' : urls.length ? 'NO_EXTERNAL_OBSERVED' : 'UNKNOWN',
    },
    evidenceRefs: ['capture.requests'],
    limitations: [
      'The pinned CLI does not expose request interception in this typed surface.',
      ...(external.length ? ['External subrequest observed; the transaction is fail-closed and is not a success.'] : []),
      ...(urls.length === 0 ? ['CLI request output was empty or unstructured.'] : []),
    ],
  };
}

function requiredEvidenceStatus(evidence, required) {
  const statuses = [];
  for (const kind of required) {
    if (kind === 'screenshot') statuses.push(evidence.screenshots.length > 0 ? 'COMPLETE' : 'INCOMPLETE');
    else if (kind === 'keyboardFocus') statuses.push(evidence.keyboardFocus.observations.length > 0 ? evidence.keyboardFocus.status : 'INCOMPLETE');
    else statuses.push(evidence[kind]?.status ?? 'INCOMPLETE');
  }
  return statuses;
}

async function executeTransaction(transaction, root, identity) {
  const evidence = buildEmptyEvidence();
  const limitations = [...identity.limitations];
  const failures = [];
  let currentViewport = transaction.operations[0].viewport;
  let currentUrl = transaction.operations[0].url;
  let snapshot = null;
  let browserReady = false;
  let sessionReady = false;
  let timedOut = false;
  const readinessProbe = { browser: 'not-run', session: 'not-run' };
  let sessionOpenAttempted = false;
  let opened = false;
  let closed = false;
  let closeSucceeded = false;
  let operationIndex = 0;

  const recordFailure = (error, operation) => {
    const code = FAILURE_TYPES.includes(error?.code) ? error.code : 'UNKNOWN_FAILURE';
    if (code === 'TIMEOUT') timedOut = true;
    failures.push({ operation, failureType: code, message: boundedText(error?.message ?? String(error), 1024) });
  };

  const getSnapshot = async (maxNodes = 300) => {
    const result = await runCli(identity.cliEntry, ['snapshot'], root);
    requireSuccessfulCommand(result, 'snapshot');
    const parsed = parseCliSnapshot(result.stdout, maxNodes);
    snapshot = parsed;
    return parsed;
  };

  const execute = async (operation) => {
    operationIndex += 1;
    switch (operation.operation) {
      case 'session.open': {
        sessionOpenAttempted = true;
        const result = await runCli(identity.cliEntry, ['open', operation.url, `--browser=${operation.browser}`, '--no-headed'], root);
        requireSuccessfulCommand(result, 'session.open');
        opened = true;
        currentViewport = operation.viewport;
        currentUrl = operation.url;
        try {
          const parsed = await getSnapshot();
          if (parsed.nodeCount > 0) {
            browserReady = true;
            sessionReady = true;
            readinessProbe.browser = 'snapshot-command-complete';
            readinessProbe.session = 'non-empty-structured-snapshot';
          } else {
            readinessProbe.browser = 'snapshot-command-empty';
            readinessProbe.session = 'snapshot-command-empty';
          }
        } catch (error) {
          readinessProbe.browser = 'snapshot-probe-failed';
          readinessProbe.session = 'snapshot-probe-failed';
          limitations.push(`Session readiness probe was unavailable: ${boundedText(error.message, 512)}`);
        }
        if (sessionReady) {
          const resizeResult = await runCli(identity.cliEntry, ['resize', String(operation.viewport.width), String(operation.viewport.height)], root);
          requireSuccessfulCommand(resizeResult, 'session.open viewport application');
        }
        break;
      }
      case 'navigate': {
        if (!sessionReady) throw new BrowserQaContractError('navigate requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const result = await runCli(identity.cliEntry, ['goto', operation.url], root);
        requireSuccessfulCommand(result, 'navigate');
        currentUrl = operation.url;
        snapshot = null;
        break;
      }
      case 'viewport.resize': {
        if (!sessionReady) throw new BrowserQaContractError('viewport.resize requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const result = await runCli(identity.cliEntry, ['resize', String(operation.width), String(operation.height)], root);
        requireSuccessfulCommand(result, 'viewport.resize');
        currentViewport = { width: operation.width, height: operation.height };
        snapshot = null;
        break;
      }
      case 'capture.dom': {
        if (!sessionReady) throw new BrowserQaContractError('capture.dom requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const parsed = await getSnapshot(operation.maxNodes);
        evidence.dom = snapshotEvidence(parsed, 'dom', operation.maxNodes);
        break;
      }
      case 'capture.ax': {
        if (!sessionReady) throw new BrowserQaContractError('capture.ax requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const parsed = await getSnapshot(operation.maxNodes);
        evidence.ax = snapshotEvidence(parsed, 'ax', operation.maxNodes);
        evidence.ax.evidenceKind = 'accessibility-tree';
        evidence.ax.captureInvocation = {
          operation: 'capture.ax',
          command: 'snapshot',
          fresh: true,
          source: 'playwright-cli',
        };
        evidence.ax.dedicated = parsed.nodeCount > 0 && parsed.sourceTextPresent;
        evidence.ax.supportVerified = evidence.ax.dedicated;
        if (!evidence.ax.dedicated) evidence.ax.limitations.push('The pinned CLI did not provide a parseable AX snapshot; AX evidence remains INCOMPLETE.');
        break;
      }
      case 'capture.screenshot': {
        if (!sessionReady) throw new BrowserQaContractError('capture.screenshot requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const artifact = normalizeArtifactBasename(operation.artifact, 'screenshot');
        const result = await runCli(identity.cliEntry, ['screenshot', '--filename', artifact], root);
        requireSuccessfulCommand(result, 'capture.screenshot');
        evidence.screenshots.push(validateArtifact(root, artifact, currentViewport));
        if (evidence.screenshots.length > 8) throw new BrowserQaContractError('Screenshot artifact limit exceeded.', 'OUTPUT_CONTRACT_FAILURE');
        break;
      }
      case 'capture.requests': {
        if (!sessionReady) throw new BrowserQaContractError('capture.requests requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const result = await runCli(identity.cliEntry, ['requests', '--static'], root);
        requireSuccessfulCommand(result, 'capture.requests');
        evidence.requests = parseRequestEvidence(`${result.stdout}\n${result.stderr}`, operation.maxRequests);
        break;
      }
      case 'interaction': {
        if (!sessionReady) throw new BrowserQaContractError('interaction requires a ready browser session.', 'DEPENDENCY_OR_RUNTIME_FAILURE');
        const beforeSnapshot = snapshot ?? await getSnapshot(300);
        const beforeFocus = inferFocusedNode(beforeSnapshot);
        let target = null;
        if (operation.target) {
          target = findTarget(beforeSnapshot, operation.target);
          if (!target?.ref) throw new BrowserQaContractError('Typed interaction target was not found in the current snapshot.', 'OUTPUT_CONTRACT_FAILURE');
        }
        const args = operation.action === 'click'
          ? ['click', target.ref]
          : operation.action === 'fill'
            ? ['fill', target.ref, operation.value]
            : ['press', operation.action];
        const result = await runCli(identity.cliEntry, args, root);
        requireSuccessfulCommand(result, `interaction.${operation.action}`);
        const afterSnapshot = await getSnapshot(300);
        const afterFocus = inferFocusedNode(afterSnapshot);
        evidence.keyboardFocus.observations.push(focusObservation(beforeFocus, afterFocus, operation, target, `focus-${operationIndex}`));
        evidence.keyboardFocus.status = evidence.keyboardFocus.observations.some((item) => item.status === 'FAIL')
          ? 'FAIL'
          : evidence.keyboardFocus.observations.some((item) => item.status === 'UNKNOWN')
            ? 'UNKNOWN'
            : evidence.keyboardFocus.observations.every((item) => item.status === 'PASS')
              ? 'COMPLETE'
              : 'INCOMPLETE';
        break;
      }
      case 'session.close': {
        if (opened && !closed) {
          const result = await runCli(identity.cliEntry, ['close'], root);
          requireSuccessfulCommand(result, 'session.close');
          closed = true;
          closeSucceeded = true;
        } else {
          closed = true;
          closeSucceeded = true;
        }
        break;
      }
      default:
        throw new BrowserQaContractError(`Unsupported operation: ${operation.operation}.`);
    }
  };

  try {
    for (const operation of transaction.operations) {
      try {
        await execute(operation);
      } catch (error) {
        recordFailure(error, operation.operation);
        break;
      }
    }
  } finally {
    if (sessionOpenAttempted && !closed) {
      try {
        const closeResult = await runCli(identity.cliEntry, ['close'], root);
        if (closeResult.timedOut) {
          timedOut = true;
          failures.push({ operation: 'session.close', failureType: 'TIMEOUT', message: 'session.close exceeded the bounded action timeout.' });
          limitations.push('Session close cleanup exceeded the bounded action timeout.');
        } else if (closeResult.exitCode === 0 && !closeResult.overflowed) {
          closed = true;
          closeSucceeded = true;
        } else if (closeResult.overflowed) {
          limitations.push('Session close cleanup exceeded the bounded output contract.');
        } else {
          limitations.push('Session close did not complete inside the provider cleanup budget.');
        }
      } catch (error) {
        if (error?.code === 'TIMEOUT') {
          timedOut = true;
          failures.push({ operation: 'session.close', failureType: 'TIMEOUT', message: boundedText(error.message, 1024) });
        }
        limitations.push(`Session close cleanup failed: ${boundedText(error.message, 512)}`);
      }
    }
  }

  const requiredStatuses = requiredEvidenceStatus(evidence, transaction.requiredEvidence);
  const missingRequired = transaction.requiredEvidence.filter((kind, index) => requiredStatuses[index] !== 'COMPLETE');
  const externalObserved = evidence.requests.externalSubrequests.observed.length > 0;
  if (externalObserved) {
    limitations.push('External subrequests are not silently permitted; the evidence bundle is a verification failure.');
    if (!failures.some((failure) => failure.failureType === 'OUTPUT_CONTRACT_FAILURE')) {
      failures.push({ operation: 'capture.requests', failureType: 'OUTPUT_CONTRACT_FAILURE', message: 'External subrequest observed under the fixed deny policy.' });
    }
  }
  if (missingRequired.length) limitations.push(`Required evidence is incomplete: ${missingRequired.join(', ')}.`);
  if (!closeSucceeded) limitations.push('The explicit session.close operation did not prove successful cleanup.');
  if (!identity.browserRevisionVerified) {
    limitations.push('Browser engine revision was not verified from the exact runtime and prepared browser state.');
  }
  const providerSucceeded = failures.length === 0 && browserReady && sessionReady && closeSucceeded && missingRequired.length === 0;
  const identityAllowsDedicatedPass = !identity.synthetic && identity.browserRevisionVerified === true;
  const succeeded = providerSucceeded && identityAllowsDedicatedPass;
  const primaryFailure = failures.find((failure) => failure.failureType === 'TIMEOUT') ?? failures[0];
  const failureType = primaryFailure?.failureType ?? (providerSucceeded ? 'DEPENDENCY_OR_RUNTIME_FAILURE' : browserReady ? 'OUTPUT_CONTRACT_FAILURE' : 'DEPENDENCY_OR_RUNTIME_FAILURE');
  return {
    schemaVersion: BROWSER_QA_SCHEMA_VERSION,
    kind: 'browser-evidence-bundle',
    capability: 'playwright-cli',
    operation: 'browser-qa.transaction',
    materialized: !identity.synthetic && identity.browserRevisionVerified,
    attempted: true,
    timedOut,
    browserReady,
    sessionReady,
    succeeded,
    failureType: succeeded ? null : failureType,
    browser: {
      engine: transaction.operations[0].browser,
      headless: true,
      headlessControl: 'explicit-cli-flag',
      headlessFlag: '--no-headed',
      chromiumSandbox: identity.browser?.chromiumSandbox ?? null,
      sandboxControl: identity.browser?.sandboxControl ?? null,
      revision: identity.browser?.revision ?? null,
      browserVersion: identity.browser?.browserVersion ?? null,
      revisionStatus: identity.browser?.revisionStatus ?? 'UNVERIFIED',
      revisionPinTracked: identity.browser?.revisionPinTracked ?? false,
      cachePath: identity.browser?.cachePath ?? null,
      executablePath: identity.browser?.executablePath ?? null,
      executableSha256: identity.browser?.executableSha256 ?? null,
      executableRelationship: identity.browser?.executableRelationship ?? null,
    },
    session: {
      state: closeSucceeded ? 'CLOSED' : sessionOpenAttempted ? 'CLEANUP_LIMITED' : 'NOT_OPENED',
      ephemeral: true,
      persistentState: false,
      owner: 'browser-session-provider',
      transport: 'same-cli-session-working-directory',
      cleanup: {
        attempted: sessionOpenAttempted,
        closeSucceeded,
        state: closeSucceeded ? 'COMPLETED' : sessionOpenAttempted ? 'LIMITED' : 'NOT_REQUIRED',
      },
      readinessProbe,
      currentUrl: safeUrlSummary(currentUrl),
      operationCount: operationIndex,
    },
    viewport: currentViewport,
    networkPolicy: {
      externalSubrequests: 'deny',
      enforcement: 'post-capture-fail-closed',
      interceptionAvailable: false,
      externalObserved,
    },
    evidence,
    artifacts: evidence.screenshots,
    requiredEvidence: transaction.requiredEvidence,
    limitations: [...new Set(limitations)],
    failures,
    outputContract: {
      valid: true,
      bounded: true,
      rawHtmlIncluded: false,
      arbitraryJavaScriptUsed: false,
      artifactContainmentValidated: true,
    },
    synthetic: identity.synthetic,
  };
}

function outputJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = canonicalSessionRoot(args.root);
  const inputName = normalizeArtifactBasename(args.input, 'provider input');
  const inputPath = ensureContainedPath(root, inputName, { mustExist: true, label: 'provider input' });
  const transaction = validateTransaction(readJson(inputPath, 'browser transaction'));
  if (args.validateOnly) {
    outputJson({ valid: true, schemaVersion: BROWSER_QA_SCHEMA_VERSION, operation: transaction.operation, requiredEvidence: transaction.requiredEvidence });
    return;
  }
  const identity = resolveCliIdentity(args.cliEntry, args.cliPackageRoot, args.synthetic);
  const bundle = await executeTransaction(transaction, root, identity);
  outputJson(bundle);
}

main().catch((error) => {
  process.stderr.write(`BROWSER_QA_PROVIDER_BLOCKED: ${boundedText(error.message, 2048)}\n`);
  process.exitCode = error instanceof BrowserQaContractError && FAILURE_TYPES.includes(error.code) ? 2 : 1;
});
