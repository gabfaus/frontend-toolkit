import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

export const BROWSER_QA_SCHEMA_VERSION = 1;
export const FAILURE_TYPES = Object.freeze([
  'INVALID_INPUT',
  'DEPENDENCY_OR_RUNTIME_FAILURE',
  'UPSTREAM_EXECUTION_FAILURE',
  'OUTPUT_CONTRACT_FAILURE',
  'TIMEOUT',
  'UNKNOWN_FAILURE',
]);

export const BROWSERS = Object.freeze(['chromium', 'firefox', 'webkit', 'msedge']);
export const INTERACTION_ACTIONS = Object.freeze([
  'Tab',
  'Shift+Tab',
  'Enter',
  'Space',
  'Escape',
  'click',
  'fill',
]);
export const REQUIRED_EVIDENCE = Object.freeze(['dom', 'ax', 'screenshot', 'requests', 'keyboardFocus']);
export const VIEWPORT_LIMITS = Object.freeze({
  minWidth: 320,
  maxWidth: 3840,
  minHeight: 240,
  maxHeight: 2160,
});
export const MAX_OPERATIONS = 64;
export const MAX_NODES = 300;
export const MAX_REQUESTS = 300;
export const MAX_ARTIFACTS = 8;
export const MAX_TEXT_LENGTH = 4096;

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);
const INTERACTIVE_ROLES = new Set([
  'button',
  'checkbox',
  'combobox',
  'link',
  'menuitem',
  'option',
  'radio',
  'searchbox',
  'slider',
  'spinbutton',
  'switch',
  'tab',
  'textbox',
]);
const KNOWN_AX_STATES = new Set([
  'active',
  'checked',
  'disabled',
  'expanded',
  'focused',
  'hidden',
  'invalid',
  'pressed',
  'readonly',
  'required',
  'selected',
]);

export class BrowserQaContractError extends Error {
  constructor(message, code = 'INVALID_INPUT') {
    super(message);
    this.name = 'BrowserQaContractError';
    this.code = code;
  }
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertRecord(value, label) {
  if (!isRecord(value)) throw new BrowserQaContractError(`${label} must be an object.`);
}

function assertExactKeys(value, allowed, label) {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) throw new BrowserQaContractError(`${label} contains unsupported field: ${key}.`);
  }
}

function assertString(value, label, { min = 1, max = MAX_TEXT_LENGTH, allowEmpty = false } = {}) {
  if (typeof value !== 'string' || (!allowEmpty && value.length < min) || value.length > max) {
    throw new BrowserQaContractError(`${label} must be a bounded string.`);
  }
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) {
    throw new BrowserQaContractError(`${label} contains a control character.`);
  }
  return value;
}

function assertInteger(value, label, min, max) {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new BrowserQaContractError(`${label} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

export function normalizeLoopbackUrl(value, label = 'URL') {
  assertString(value, label, { max: 4096 });
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new BrowserQaContractError(`${label} must be an absolute HTTP loopback URL.`);
  }
  const hostname = parsed.hostname.toLowerCase();
  if (parsed.protocol !== 'http:' || !LOOPBACK_HOSTS.has(hostname)) {
    throw new BrowserQaContractError(`${label} must use an allowed HTTP loopback origin.`);
  }
  if (parsed.username || parsed.password) {
    throw new BrowserQaContractError(`${label} must not contain URL credentials.`);
  }
  if (parsed.port && (!/^\d+$/.test(parsed.port) || Number(parsed.port) < 1 || Number(parsed.port) > 65535)) {
    throw new BrowserQaContractError(`${label} contains an invalid port.`);
  }
  return parsed.href;
}

export function normalizeViewport(value, label = 'viewport') {
  assertRecord(value, label);
  assertExactKeys(value, ['width', 'height'], label);
  return {
    width: assertInteger(value.width, `${label}.width`, VIEWPORT_LIMITS.minWidth, VIEWPORT_LIMITS.maxWidth),
    height: assertInteger(value.height, `${label}.height`, VIEWPORT_LIMITS.minHeight, VIEWPORT_LIMITS.maxHeight),
  };
}

function normalizeSubject(value) {
  if (value === undefined) return null;
  assertRecord(value, 'subject');
  assertExactKeys(value, ['reference', 'expectedViewport', 'motionExpectations', 'fixture'], 'subject');
  const subject = {};
  if (value.reference !== undefined) subject.reference = assertString(value.reference, 'subject.reference', { max: 512 });
  if (value.expectedViewport !== undefined) subject.expectedViewport = normalizeViewport(value.expectedViewport, 'subject.expectedViewport');
  if (value.fixture !== undefined) subject.fixture = assertString(value.fixture, 'subject.fixture', { max: 256 });
  if (value.motionExpectations !== undefined) {
    assertRecord(value.motionExpectations, 'subject.motionExpectations');
    assertExactKeys(value.motionExpectations, ['prefersReducedMotion'], 'subject.motionExpectations');
    const reducedMotion = value.motionExpectations.prefersReducedMotion;
    if (!['required', 'not-required', 'unknown'].includes(reducedMotion)) {
      throw new BrowserQaContractError('subject.motionExpectations.prefersReducedMotion is invalid.');
    }
    subject.motionExpectations = { prefersReducedMotion: reducedMotion };
  }
  return subject;
}

function normalizeTarget(value, label) {
  assertRecord(value, label);
  assertExactKeys(value, ['kind', 'role', 'name', 'label'], label);
  if (value.kind === 'role') {
    if (!INTERACTIVE_ROLES.has(value.role)) throw new BrowserQaContractError(`${label}.role is not an allowlisted interactive role.`);
    const target = { kind: 'role', role: value.role };
    if (value.name !== undefined) target.name = assertString(value.name, `${label}.name`, { max: 256 });
    return target;
  }
  if (value.kind === 'label') {
    return { kind: 'label', label: assertString(value.label, `${label}.label`, { max: 256 }) };
  }
  throw new BrowserQaContractError(`${label}.kind must be role or label.`);
}

function normalizeOperation(value, index) {
  assertRecord(value, `operations[${index}]`);
  const operation = value.operation;
  assertString(operation, `operations[${index}].operation`, { max: 64 });
  switch (operation) {
    case 'session.open': {
      assertExactKeys(value, ['operation', 'browser', 'url', 'viewport', 'headless', 'networkPolicy'], `operations[${index}]`);
      if (!BROWSERS.includes(value.browser)) throw new BrowserQaContractError(`operations[${index}].browser is not allowlisted.`);
      assertRecord(value.networkPolicy, `operations[${index}].networkPolicy`);
      assertExactKeys(value.networkPolicy, ['externalSubrequests'], `operations[${index}].networkPolicy`);
      if (value.networkPolicy.externalSubrequests !== 'deny') {
        throw new BrowserQaContractError('External subrequests must use the fixed deny policy.');
      }
      if (value.headless !== true) throw new BrowserQaContractError('session.open.headless must be true.');
      return {
        operation,
        browser: value.browser,
        url: normalizeLoopbackUrl(value.url, `operations[${index}].url`),
        viewport: normalizeViewport(value.viewport, `operations[${index}].viewport`),
        headless: true,
        networkPolicy: { externalSubrequests: 'deny' },
      };
    }
    case 'navigate':
      assertExactKeys(value, ['operation', 'url'], `operations[${index}]`);
      return { operation, url: normalizeLoopbackUrl(value.url, `operations[${index}].url`) };
    case 'viewport.resize':
      assertExactKeys(value, ['operation', 'width', 'height'], `operations[${index}]`);
      return {
        operation,
        width: assertInteger(value.width, `operations[${index}].width`, VIEWPORT_LIMITS.minWidth, VIEWPORT_LIMITS.maxWidth),
        height: assertInteger(value.height, `operations[${index}].height`, VIEWPORT_LIMITS.minHeight, VIEWPORT_LIMITS.maxHeight),
      };
    case 'capture.dom':
    case 'capture.ax':
      assertExactKeys(value, ['operation', 'maxNodes'], `operations[${index}]`);
      return {
        operation,
        maxNodes: value.maxNodes === undefined ? MAX_NODES : assertInteger(value.maxNodes, `operations[${index}].maxNodes`, 1, MAX_NODES),
      };
    case 'capture.screenshot':
      assertExactKeys(value, ['operation', 'artifact', 'fullPage'], `operations[${index}]`);
      if (value.fullPage !== undefined && value.fullPage !== false) {
        throw new BrowserQaContractError('Full-page screenshots are not enabled by the bounded contract.');
      }
      return {
        operation,
        artifact: normalizeArtifactBasename(value.artifact, 'screenshot'),
        fullPage: false,
      };
    case 'capture.requests':
      assertExactKeys(value, ['operation', 'maxRequests'], `operations[${index}]`);
      return {
        operation,
        maxRequests: value.maxRequests === undefined ? MAX_REQUESTS : assertInteger(value.maxRequests, `operations[${index}].maxRequests`, 1, MAX_REQUESTS),
      };
    case 'interaction': {
      assertExactKeys(value, ['operation', 'action', 'target', 'value', 'expectedFocus'], `operations[${index}]`);
      if (!INTERACTION_ACTIONS.includes(value.action)) throw new BrowserQaContractError(`operations[${index}].action is not allowlisted.`);
      const normalized = { operation, action: value.action };
      if ((value.action === 'click' || value.action === 'fill') && value.target === undefined) {
        throw new BrowserQaContractError(`operations[${index}].target is required for ${value.action}.`);
      }
      if (value.target !== undefined) {
        normalized.target = normalizeTarget(value.target, `operations[${index}].target`);
        if (value.action === 'fill' && normalized.target.kind === 'role' && !['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(normalized.target.role)) {
          throw new BrowserQaContractError(`operations[${index}].target must identify a text entry control for fill.`);
        }
      }
      if (value.action === 'fill') {
        normalized.value = assertString(value.value, `operations[${index}].value`, { max: MAX_TEXT_LENGTH, allowEmpty: true });
      } else if (value.value !== undefined) {
        throw new BrowserQaContractError(`operations[${index}].value is not accepted for ${value.action}.`);
      }
      if (value.expectedFocus !== undefined) {
        if (!['target', 'previous', 'none', 'unknown'].includes(value.expectedFocus)) {
          throw new BrowserQaContractError(`operations[${index}].expectedFocus is invalid.`);
        }
        normalized.expectedFocus = value.expectedFocus;
      }
      return normalized;
    }
    case 'session.close':
      assertExactKeys(value, ['operation'], `operations[${index}]`);
      return { operation };
    default:
      throw new BrowserQaContractError(`Unsupported browser operation: ${operation}.`);
  }
}

export function normalizeArtifactBasename(value, label = 'artifact') {
  assertString(value, label, { max: 128 });
  if (value === '.' || value === '..' || value.startsWith('.') || /[\\/:*?"<>|]/.test(value)) {
    throw new BrowserQaContractError(`${label} must be a basename without path separators.`);
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) {
    throw new BrowserQaContractError(`${label} contains unsupported characters.`);
  }
  const stem = value.split('.')[0].toUpperCase();
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/.test(stem)) {
    throw new BrowserQaContractError(`${label} uses a reserved Windows device name.`);
  }
  if (label === 'screenshot' && !/\.png$/i.test(value)) {
    throw new BrowserQaContractError('Screenshot artifacts must use the .png extension.');
  }
  return value;
}

export function validateTransaction(value) {
  assertRecord(value, 'transaction');
  assertExactKeys(value, ['schemaVersion', 'operation', 'subject', 'operations', 'requiredEvidence'], 'transaction');
  if (value.schemaVersion !== BROWSER_QA_SCHEMA_VERSION) throw new BrowserQaContractError('Unsupported browser transaction schemaVersion.');
  if (value.operation !== 'browser-qa.transaction') throw new BrowserQaContractError('transaction.operation must be browser-qa.transaction.');
  if (!Array.isArray(value.operations) || value.operations.length < 2 || value.operations.length > MAX_OPERATIONS) {
    throw new BrowserQaContractError(`transaction.operations must contain between 2 and ${MAX_OPERATIONS} operations.`);
  }
  const operations = value.operations.map(normalizeOperation);
  if (operations[0].operation !== 'session.open') throw new BrowserQaContractError('The first operation must be session.open.');
  if (operations[operations.length - 1].operation !== 'session.close') throw new BrowserQaContractError('The last operation must be session.close.');
  if (operations.slice(1, -1).some((item) => item.operation === 'session.open' || item.operation === 'session.close')) {
    throw new BrowserQaContractError('session.open and session.close may appear only at the transaction boundaries.');
  }
  const requiredEvidence = value.requiredEvidence === undefined ? ['dom', 'screenshot', 'requests'] : value.requiredEvidence;
  if (!Array.isArray(requiredEvidence) || requiredEvidence.length > REQUIRED_EVIDENCE.length) {
    throw new BrowserQaContractError('transaction.requiredEvidence must be a bounded array.');
  }
  const normalizedRequiredEvidence = [...new Set(requiredEvidence)];
  if (normalizedRequiredEvidence.length !== requiredEvidence.length || normalizedRequiredEvidence.some((item) => !REQUIRED_EVIDENCE.includes(item))) {
    throw new BrowserQaContractError('transaction.requiredEvidence contains an unsupported or duplicated evidence kind.');
  }
  if (!normalizedRequiredEvidence.includes('requests')) {
    throw new BrowserQaContractError('capture.requests evidence is mandatory for the fixed external-subrequest deny policy.');
  }
  return {
    schemaVersion: BROWSER_QA_SCHEMA_VERSION,
    operation: 'browser-qa.transaction',
    subject: normalizeSubject(value.subject),
    operations,
    requiredEvidence: normalizedRequiredEvidence,
  };
}

export function boundedText(value, max = MAX_TEXT_LENGTH) {
  const text = String(value ?? '');
  const redacted = text
    .replace(/(password|passcode|secret|token|api[-_]?key|authorization|cookie)\s*[:=]\s*([^\s,;]+)/gi, '$1=[REDACTED]')
    .replace(/\bBearer\s+[^\s,;]+/gi, 'Bearer [REDACTED]');
  return redacted.length > max ? `${redacted.slice(0, max)}...[truncated]` : redacted;
}

function decodeQuoted(value) {
  try {
    return JSON.parse(`"${value.replace(/"/g, '\\"')}"`);
  } catch {
    return boundedText(value, 256);
  }
}

function parseSnapshotAttributeBlock(block) {
  const attributes = {};
  for (const part of block.trim().split(/\s+/)) {
    if (!part) continue;
    const equals = part.indexOf('=');
    const key = equals === -1 ? part : part.slice(0, equals);
    const raw = equals === -1 ? 'true' : part.slice(equals + 1);
    if (!/^[a-zA-Z][a-zA-Z0-9_-]{0,31}$/.test(key)) continue;
    const value = raw.replace(/^"|"$/g, '');
    if (key === 'ref') attributes.ref = boundedText(value, 64);
    else if (key === 'level') attributes.level = Number.isInteger(Number(value)) ? Number(value) : boundedText(value, 32);
    else if (KNOWN_AX_STATES.has(key)) attributes[key] = value === 'true' ? true : value === 'false' ? false : boundedText(value, 64);
  }
  return attributes;
}

function parseSnapshotLine(line, id) {
  const match = line.match(/^\s*-\s+(.+?)\s*$/);
  if (!match) return null;
  const body = match[1];
  const roleMatch = body.match(/^([a-zA-Z][a-zA-Z0-9_-]{0,63})(?:\s+"((?:[^"\\]|\\.)*)")?/);
  if (!roleMatch) return null;
  const role = roleMatch[1].toLowerCase();
  const node = {
    id,
    role,
    accessibleName: roleMatch[2] ? boundedText(decodeQuoted(roleMatch[2]), 256) : '',
    states: {},
    children: [],
  };
  const attributeMatch = body.match(/\[([^\]]{1,512})\]/g);
  for (const block of attributeMatch ?? []) Object.assign(node.states, parseSnapshotAttributeBlock(block.slice(1, -1)));
  if (node.states.level !== undefined) {
    node.level = node.states.level;
    delete node.states.level;
  }
  if (node.states.ref !== undefined) {
    node.ref = node.states.ref;
    delete node.states.ref;
  }
  return node;
}

export function parseCliSnapshot(value, maxNodes = MAX_NODES) {
  const text = boundedText(value, 65536);
  let snapshotText = text;
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed === 'string') snapshotText = parsed;
    else if (isRecord(parsed) && typeof parsed.snapshot === 'string') snapshotText = parsed.snapshot;
    else if (isRecord(parsed) && typeof parsed.output === 'string') snapshotText = parsed.output;
  } catch {
    // The official CLI emits a text tree; JSON is accepted for hermetic doubles.
  }
  const roots = [];
  const stack = [];
  let nodeCount = 0;
  let truncated = false;
  for (const line of snapshotText.split(/\r?\n/)) {
    if (!/^\s*-\s+/.test(line)) continue;
    if (nodeCount >= maxNodes) {
      truncated = true;
      break;
    }
    const node = parseSnapshotLine(line, `node-${nodeCount + 1}`);
    if (!node) continue;
    nodeCount += 1;
    const indent = (line.match(/^\s*/) ?? [''])[0].replace(/\t/g, '  ').length;
    while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
    if (stack.length) stack[stack.length - 1].node.children.push(node);
    else roots.push(node);
    stack.push({ indent, node });
  }
  return { roots, nodeCount, truncated, sourceTextPresent: snapshotText.trim().length > 0 };
}

export function flattenEvidenceNodes(roots) {
  const result = [];
  const visit = (node) => {
    const copy = { ...node, children: undefined };
    delete copy.children;
    result.push(copy);
    for (const child of node.children ?? []) visit(child);
  };
  for (const root of roots ?? []) visit(root);
  return result;
}

export function inferFocusedNode(evidence) {
  const nodes = flattenEvidenceNodes(evidence?.roots ?? evidence?.tree ?? []);
  const focused = nodes.find((node) => node.states?.focused === true || node.states?.focused === 'true' ||
    (node.role !== 'generic' && (node.states?.active === true || node.states?.active === 'true')));
  return focused ? { id: focused.id, ref: focused.ref ?? null, role: focused.role, accessibleName: focused.accessibleName } : null;
}

export function ensureContainedPath(root, relativeOrAbsolute, { mustExist = false, label = 'path' } = {}) {
  const rootAbsolute = path.resolve(root);
  const candidate = path.isAbsolute(relativeOrAbsolute)
    ? path.resolve(relativeOrAbsolute)
    : path.resolve(rootAbsolute, relativeOrAbsolute);
  const relative = path.relative(rootAbsolute, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new BrowserQaContractError(`${label} escaped its canonical root.`, 'INVALID_INPUT');
  }
  if (mustExist && !fs.existsSync(candidate)) throw new BrowserQaContractError(`${label} does not exist.`, 'OUTPUT_CONTRACT_FAILURE');
  if (fs.existsSync(rootAbsolute)) {
    const realRoot = fs.realpathSync(rootAbsolute);
    const realCandidate = fs.existsSync(candidate) ? fs.realpathSync(candidate) : candidate;
    const realRelative = path.relative(realRoot, realCandidate);
    if (realRelative === '..' || realRelative.startsWith(`..${path.sep}`) || path.isAbsolute(realRelative)) {
      throw new BrowserQaContractError(`${label} resolves outside its canonical root.`, 'INVALID_INPUT');
    }
  }
  return candidate;
}

export function sha256File(filePath) {
  return createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

export function validateArtifact(root, basename, viewport) {
  const artifactPath = ensureContainedPath(root, basename, { mustExist: true, label: 'artifact' });
  if (fs.lstatSync(artifactPath).isSymbolicLink()) {
    throw new BrowserQaContractError('Screenshot artifact may not be a symbolic link.', 'OUTPUT_CONTRACT_FAILURE');
  }
  const stat = fs.statSync(artifactPath);
  if (!stat.isFile() || stat.size < 1 || stat.size > 20 * 1024 * 1024) {
    throw new BrowserQaContractError('Screenshot artifact is empty, non-regular, or exceeds the bounded size.', 'OUTPUT_CONTRACT_FAILURE');
  }
  return {
    kind: 'screenshot',
    basename,
    sizeBytes: stat.size,
    sha256: sha256File(artifactPath),
    viewport: { ...viewport },
    existsAtCapture: true,
  };
}

export function safeUrlSummary(value) {
  try {
    const parsed = new URL(value);
    return `${parsed.origin}${parsed.pathname}`.slice(0, 1024);
  } catch {
    return '[unparseable-url]';
  }
}

export function isLoopbackUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'http:' && LOOPBACK_HOSTS.has(parsed.hostname.toLowerCase()) && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}

export function extractUrls(value) {
  const urls = new Set();
  for (const match of String(value ?? '').matchAll(/https?:\/\/[^\s"'<>()[\]{}]+/gi)) {
    const raw = match[0].replace(/[),.;]+$/, '');
    try {
      const parsed = new URL(raw);
      if (parsed.username || parsed.password) continue;
      urls.add(parsed.href);
    } catch {
      // Unstructured CLI output is handled as an incomplete request contract.
    }
  }
  return [...urls];
}

export function buildEmptyEvidence() {
  return {
    dom: { status: 'INCOMPLETE', evidenceRefs: [], nodes: [], limitations: ['DOM evidence was not captured.'] },
    ax: { status: 'INCOMPLETE', evidenceRefs: [], tree: [], limitations: ['AX evidence was not captured.'] },
    screenshots: [],
    requests: { status: 'INCOMPLETE', items: [], externalSubrequests: { observed: [], blocked: [], status: 'UNKNOWN' }, limitations: ['Request evidence was not captured.'] },
    keyboardFocus: { status: 'INCOMPLETE', observations: [], limitations: ['Keyboard/focus evidence was not captured.'] },
    motion: { status: 'INCOMPLETE', reducedMotion: 'UNKNOWN', limitations: ['Motion preference was not inspected.'] },
    reflow: { status: 'INCOMPLETE', limitations: ['Reflow evidence was not captured.'] },
  };

  // The function intentionally returns a bounded object only; raw HTML, raw CLI
  // output, and page storage state never belong in a BrowserEvidenceBundle.
}
