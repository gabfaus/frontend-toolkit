import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  BROWSER_QA_SCHEMA_VERSION,
  BrowserQaContractError,
  boundedText,
  ensureContainedPath,
  flattenEvidenceNodes,
  normalizeViewport,
} from './browser-qa-contract.mjs';

const MAX_INPUT_BYTES = 2 * 1024 * 1024;
const MAX_CHECKS = 32;

const CHECK_DEFINITIONS = Object.freeze([
  { id: 'semantic-structure', required: true, manualReviewRequired: false },
  { id: 'landmarks', required: true, manualReviewRequired: false },
  { id: 'headings', required: true, manualReviewRequired: false },
  { id: 'form-labels', required: true, manualReviewRequired: false },
  { id: 'form-relationships', required: true, manualReviewRequired: false },
  { id: 'aria-consistency', required: true, manualReviewRequired: false },
  { id: 'keyboard-order', required: true, manualReviewRequired: false },
  { id: 'focus-visibility', required: true, manualReviewRequired: false },
  { id: 'focus-behavior', required: true, manualReviewRequired: false },
  { id: 'ax-naming-state', required: true, manualReviewRequired: false },
  { id: 'reduced-motion', required: true, manualReviewRequired: true },
  { id: 'reflow', required: true, manualReviewRequired: true },
]);

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
const LANDMARK_ROLES = new Set(['banner', 'complementary', 'contentinfo', 'form', 'main', 'navigation', 'region', 'search']);
const VALID_STATUSES = new Set(['PASS', 'FAIL', 'INCOMPLETE', 'UNKNOWN']);

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function fail(message) {
  process.stderr.write(`ACCESSIBILITY_VERIFY_BLOCKED: ${boundedText(message, 2048)}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const result = { root: null, input: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--root') result.root = argv[++index];
    else if (argument === '--input') result.input = argv[++index];
    else throw new BrowserQaContractError(`Unknown accessibility argument: ${argument}.`);
  }
  if (!result.root || !result.input) throw new BrowserQaContractError('--root and --input are required.');
  return result;
}

function canonicalTempRoot(value) {
  const root = path.resolve(value);
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) throw new BrowserQaContractError('Verification root is not a directory.');
  const real = fs.realpathSync(root);
  const temp = fs.realpathSync(os.tmpdir());
  const relative = path.relative(temp, real);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new BrowserQaContractError('Verification root must be inside the OS temporary directory.');
  }
  return real;
}

function readContainedObservation(root, input) {
  const inputName = String(input);
  if (path.isAbsolute(inputName) || inputName !== path.basename(inputName) || inputName === '.' || inputName === '..' || /[\\/:]/.test(inputName)) {
    throw new BrowserQaContractError('Verification input must be a basename inside the supplied root.');
  }
  const inputPath = ensureContainedPath(root, inputName, { mustExist: true, label: 'Verification input' });
  const stat = fs.lstatSync(inputPath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_INPUT_BYTES) {
    throw new BrowserQaContractError('Verification input is not a bounded regular file.');
  }
  try {
    return JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  } catch (error) {
    throw new BrowserQaContractError(`Verification input is not valid JSON: ${boundedText(error.message, 512)}.`);
  }
}

function getBundle(observation) {
  if (!isRecord(observation)) throw new BrowserQaContractError('Accessibility evidence must be an object.');
  const callerStatus = observation.status;
  if (observation.kind === 'browser-qa-execution-envelope') {
    return { bundle: observation.browserEvidenceBundle, dedicated: observation.dedicatedExecution, callerStatus, source: 'browser-qa-execution-envelope' };
  }
  if (observation.kind === 'browser-evidence-bundle') {
    return { bundle: observation, dedicated: null, callerStatus, source: 'browser-evidence-bundle' };
  }
  return { bundle: null, dedicated: null, callerStatus, source: 'unknown' };
}

function validateNode(node, label, depth = 0, counter = { count: 0 }) {
  if (!isRecord(node) || depth > 32) throw new BrowserQaContractError(`${label} is malformed.`);
  counter.count += 1;
  if (counter.count > 300) throw new BrowserQaContractError(`${label} exceeds the total bounded node limit.`);
  if (typeof node.role !== 'string' || node.role.length < 1 || node.role.length > 64) throw new BrowserQaContractError(`${label}.role is invalid.`);
  if (typeof node.accessibleName !== 'string' || node.accessibleName.length > 256) throw new BrowserQaContractError(`${label}.accessibleName is invalid.`);
  if (node.children !== undefined) {
    if (!Array.isArray(node.children) || node.children.length > 300) throw new BrowserQaContractError(`${label}.children is invalid.`);
    node.children.forEach((child, index) => validateNode(child, `${label}.children[${index}]`, depth + 1, counter));
  }
  if (node.states !== undefined && !isRecord(node.states)) throw new BrowserQaContractError(`${label}.states is invalid.`);
}

function statusFromEvidence(value, evidenceRefs, limitations = []) {
  if (!isRecord(value) || !VALID_STATUSES.has(value.status) || !Array.isArray(value.evidenceRefs) || value.evidenceRefs.length === 0) {
    return { status: 'INCOMPLETE', evidenceRefs, limitations: [...limitations, 'Required dedicated evidence is missing or is not linked by evidenceRefs.'] };
  }
  return {
    status: value.status,
    evidenceRefs: value.evidenceRefs.slice(0, 16).map((ref) => boundedText(ref, 128)),
    limitations: [...limitations, ...(Array.isArray(value.limitations) ? value.limitations.slice(0, 8).map((item) => boundedText(item, 512)) : [])],
  };
}

function validateBundle(bundle) {
  if (!isRecord(bundle)) throw new BrowserQaContractError('BrowserEvidenceBundle is missing.');
  const required = ['schemaVersion', 'kind', 'materialized', 'attempted', 'browserReady', 'sessionReady', 'succeeded', 'browser', 'session', 'viewport', 'networkPolicy', 'evidence', 'outputContract'];
  for (const field of required) if (!(field in bundle)) throw new BrowserQaContractError(`BrowserEvidenceBundle.${field} is missing.`);
  if (bundle.schemaVersion !== BROWSER_QA_SCHEMA_VERSION || bundle.kind !== 'browser-evidence-bundle') throw new BrowserQaContractError('BrowserEvidenceBundle schema or kind is invalid.');
  for (const field of ['materialized', 'attempted', 'browserReady', 'sessionReady', 'succeeded']) if (typeof bundle[field] !== 'boolean') throw new BrowserQaContractError(`BrowserEvidenceBundle.${field} must be boolean.`);
  normalizeViewport(bundle.viewport, 'BrowserEvidenceBundle.viewport');
  if (!isRecord(bundle.browser) || bundle.browser.headless !== true || bundle.browser.headlessControl !== 'explicit-cli-flag') throw new BrowserQaContractError('Browser identity/headless contract is invalid.');
  if (!isRecord(bundle.session) || bundle.session.persistentState !== false || bundle.session.ephemeral !== true) throw new BrowserQaContractError('Browser session state contract is invalid.');
  if (!isRecord(bundle.networkPolicy) || bundle.networkPolicy.externalSubrequests !== 'deny') throw new BrowserQaContractError('Network policy is not the fixed deny policy.');
  if (!isRecord(bundle.outputContract) || bundle.outputContract.valid !== true || bundle.outputContract.rawHtmlIncluded !== false || bundle.outputContract.arbitraryJavaScriptUsed !== false) throw new BrowserQaContractError('BrowserEvidenceBundle output contract is unsafe.');
  if (!isRecord(bundle.evidence)) throw new BrowserQaContractError('BrowserEvidenceBundle.evidence is missing.');
  const evidence = bundle.evidence;
  if (!isRecord(evidence.dom) || !Array.isArray(evidence.dom.nodes) || evidence.dom.nodes.length > 300) throw new BrowserQaContractError('DOM evidence is malformed or unbounded.');
  const domCounter = { count: 0 };
  evidence.dom.nodes.forEach((node, index) => validateNode(node, `evidence.dom.nodes[${index}]`, 0, domCounter));
  if (!isRecord(evidence.ax) || !Array.isArray(evidence.ax.tree) || evidence.ax.tree.length > 300) throw new BrowserQaContractError('AX evidence is malformed or unbounded.');
  const axCounter = { count: 0 };
  evidence.ax.tree.forEach((node, index) => validateNode(node, `evidence.ax.tree[${index}]`, 0, axCounter));
  if (!Array.isArray(evidence.screenshots) || evidence.screenshots.length > 8) throw new BrowserQaContractError('Screenshot evidence is malformed or unbounded.');
  for (const [index, artifact] of evidence.screenshots.entries()) {
    if (!isRecord(artifact) || typeof artifact.basename !== 'string' || !/^[-A-Za-z0-9._]{1,128}$/.test(artifact.basename) || typeof artifact.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(artifact.sha256) || !(artifact.sizeBytes > 0) || artifact.existsAtCapture !== true) {
      throw new BrowserQaContractError(`Screenshot artifact ${index} is malformed.`);
    }
    normalizeViewport(artifact.viewport, `evidence.screenshots[${index}].viewport`);
  }
  if (!isRecord(evidence.requests) || !Array.isArray(evidence.requests.items) || evidence.requests.items.length > 300) throw new BrowserQaContractError('Request evidence is malformed or unbounded.');
  if (!isRecord(evidence.requests.externalSubrequests) || !Array.isArray(evidence.requests.externalSubrequests.observed)) throw new BrowserQaContractError('External request evidence is malformed.');
  if (!isRecord(evidence.keyboardFocus) || !Array.isArray(evidence.keyboardFocus.observations) || evidence.keyboardFocus.observations.length > 300) throw new BrowserQaContractError('Keyboard/focus evidence is malformed or unbounded.');
  return evidence;
}

function nodeRoles(nodes) {
  return flattenEvidenceNodes(nodes).map((node) => node.role);
}

function nodeList(nodes) {
  return flattenEvidenceNodes(nodes);
}

function explicitEvidence(evidence, pathName, fallbackRefs) {
  const segments = pathName.split('.');
  let value = evidence;
  for (const segment of segments) value = value?.[segment];
  return statusFromEvidence(value, fallbackRefs);
}

function evaluateChecks(evidence, bundle, manualReview) {
  const domNodes = nodeList(evidence.dom.nodes);
  const axNodes = nodeList(evidence.ax.tree);
  const roles = new Set(domNodes.map((node) => node.role));
  const axInteractive = axNodes.filter((node) => INTERACTIVE_ROLES.has(node.role));
  const formControls = domNodes.filter((node) => ['textbox', 'searchbox', 'combobox', 'spinbutton', 'checkbox', 'radio'].includes(node.role));
  const headings = domNodes.filter((node) => node.role === 'heading');
  const base = new Map();
  base.set('semantic-structure', domNodes.length > 0 ? { status: 'PASS', evidenceRefs: ['evidence.dom.nodes'], limitations: [] } : { status: 'FAIL', evidenceRefs: ['evidence.dom'], limitations: ['No semantic nodes were captured.'] });
  base.set('landmarks', roles.size && [...roles].some((role) => LANDMARK_ROLES.has(role)) ? { status: 'PASS', evidenceRefs: ['evidence.dom.nodes'], limitations: [] } : explicitEvidence(evidence.dom, 'landmarks', ['evidence.dom.landmarks']));
  if (headings.length === 0) base.set('headings', { status: 'FAIL', evidenceRefs: ['evidence.dom.nodes'], limitations: ['No heading was captured.'] });
  else {
    const levels = headings.map((node) => Number(node.level)).filter((level) => Number.isInteger(level) && level > 0);
    const skipped = levels.some((level, index) => index > 0 && level - levels[index - 1] > 1);
    base.set('headings', skipped ? { status: 'FAIL', evidenceRefs: ['evidence.dom.nodes'], limitations: ['Heading levels skip a level.'] } : { status: 'PASS', evidenceRefs: ['evidence.dom.nodes'], limitations: [] });
  }
  const unnamedControls = formControls.filter((node) => !node.accessibleName.trim());
  base.set('form-labels', unnamedControls.length ? { status: 'FAIL', evidenceRefs: ['evidence.dom.nodes'], limitations: ['A form control has no accessible name.'] } : { status: 'PASS', evidenceRefs: ['evidence.dom.nodes'], limitations: [] });
  base.set('form-relationships', explicitEvidence(evidence.dom, 'formRelationships', ['evidence.dom.formRelationships']));
  const ariaIssues = Array.isArray(evidence.dom.ariaIssues) ? evidence.dom.ariaIssues : [];
  base.set('aria-consistency', ariaIssues.length ? { status: 'FAIL', evidenceRefs: ['evidence.dom.ariaIssues'], limitations: ['ARIA evidence contains a contradiction or invalid relationship.'] } : explicitEvidence(evidence.dom, 'aria', ['evidence.dom.aria']));
  const focusObservations = evidence.keyboardFocus.observations;
  const failedFocus = focusObservations.filter((item) => item.status === 'FAIL');
  const unknownFocus = focusObservations.filter((item) => !VALID_STATUSES.has(item.status) || item.status === 'UNKNOWN' || item.status === 'INCOMPLETE');
  base.set('keyboard-order', focusObservations.length === 0 ? { status: 'INCOMPLETE', evidenceRefs: ['evidence.keyboardFocus'], limitations: ['No typed keyboard interaction evidence was captured.'] } : failedFocus.length ? { status: 'FAIL', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['Keyboard/focus observation failed.'] } : unknownFocus.length ? { status: 'UNKNOWN', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['Focus order was not fully observable.'] } : { status: 'PASS', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: [] });
  const invisible = focusObservations.filter((item) => item.focusVisible === false || item.focusVisibility?.status === 'FAIL');
  base.set('focus-visibility', invisible.length ? { status: 'FAIL', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['A focused control was not visibly indicated.'] } : focusObservations.length && focusObservations.every((item) => item.focusVisible === true || item.focusVisibility?.status === 'PASS') ? { status: 'PASS', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: [] } : { status: 'INCOMPLETE', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['Focus visibility was not captured.'] });
  base.set('focus-behavior', failedFocus.length ? { status: 'FAIL', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['Focus behavior did not meet the typed expectation.'] } : focusObservations.length && unknownFocus.length === 0 ? { status: 'PASS', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: [] } : { status: 'INCOMPLETE', evidenceRefs: ['evidence.keyboardFocus.observations'], limitations: ['Focus return/trap behavior was not fully captured.'] });
  const unnamedAx = axInteractive.filter((node) => !node.accessibleName.trim());
  base.set('ax-naming-state', evidence.ax.status !== 'COMPLETE' || evidence.ax.dedicated !== true || evidence.ax.supportVerified !== true || evidence.ax.captureInvocation?.fresh !== true ? { status: 'INCOMPLETE', evidenceRefs: ['evidence.ax'], limitations: ['Dedicated AX evidence is incomplete, not fresh, or runtime support was not verified.'] } : unnamedAx.length ? { status: 'FAIL', evidenceRefs: ['evidence.ax.tree'], limitations: ['An interactive AX node has no accessible name.'] } : { status: 'PASS', evidenceRefs: ['evidence.ax.tree'], limitations: [] });
  base.set('reduced-motion', explicitEvidence(evidence, 'motion.reducedMotion', ['evidence.motion.reducedMotion']));
  base.set('reflow', explicitEvidence(evidence, 'reflow', ['evidence.reflow']));

  return CHECK_DEFINITIONS.map((definition) => {
    const result = base.get(definition.id) ?? { status: 'INCOMPLETE', evidenceRefs: [], limitations: ['No verifier rule produced a result.'] };
    const manual = manualReview?.byCheck?.[definition.id] ?? manualReview?.checks?.[definition.id];
    let status = result.status;
    const limitations = [...result.limitations];
    let manualApplied = false;
    if (status === 'FAIL') {
      if (manual) limitations.push('Manual review cannot override an automated failure.');
    } else if (definition.manualReviewRequired) {
      if (isRecord(manual) && manual.status === 'PASS' && Array.isArray(manual.evidenceRefs) && manual.evidenceRefs.length > 0) {
        status = 'PASS';
        manualApplied = true;
      } else if (isRecord(manual) && manual.status === 'FAIL') {
        status = 'FAIL';
        manualApplied = true;
      } else if (status === 'PASS') {
        limitations.push('Automated evidence is present, but this check still requires review of the stated manual category.');
        status = 'UNKNOWN';
      } else {
        status = 'UNKNOWN';
      }
    }
    return {
      id: definition.id,
      status,
      required: definition.required,
      evidenceRefs: result.evidenceRefs,
      limitations: limitations.slice(0, 12),
      manualReviewRequired: definition.manualReviewRequired,
      manualReviewApplied: manualApplied,
    };
  });
}

function finalStatus(checks, evidence, bundle) {
  if (evidence.requests.externalSubrequests.observed.length > 0) return 'FAIL';
  if (evidence.requests.status !== 'COMPLETE') return 'INCOMPLETE';
  if (checks.some((check) => check.status === 'FAIL')) return 'FAIL';
  if (checks.some((check) => check.required && check.status === 'UNKNOWN')) return 'UNKNOWN';
  if (checks.some((check) => check.required && check.status === 'INCOMPLETE')) return 'INCOMPLETE';
  const hermetic = bundle.synthetic === true || bundle.evidenceOrigin === 'hermetic-fixture';
  if (!hermetic && (!bundle.materialized || !bundle.attempted || !bundle.browserReady || !bundle.sessionReady || bundle.succeeded !== true)) return 'INCOMPLETE';
  return 'PASS';
}

function makeMalformedReport(message, callerStatus) {
  return {
    schemaVersion: 1,
    mode: 'ACCESSIBILITY_VERIFY',
    status: 'FAIL',
    contractValid: false,
    readOnly: true,
    codeModified: false,
    browserStarted: false,
    dedicatedPass: false,
    callerStatusIgnored: callerStatus !== undefined,
    checks: CHECK_DEFINITIONS.map((definition) => ({
      id: definition.id,
      status: 'INCOMPLETE',
      required: definition.required,
      evidenceRefs: [],
      limitations: [boundedText(message, 1024)],
      manualReviewRequired: definition.manualReviewRequired,
    })),
    manualReview: { globalBooleanIgnored: true, byCheckUsed: false },
    axe: { classification: 'SUPPLEMENTARY', scanExecuted: false, status: 'NOT_EXECUTED', callerClaimIgnored: true },
    failureType: 'OUTPUT_CONTRACT_FAILURE',
  };
}

try {
  const args = parseArgs(process.argv.slice(2));
  const root = canonicalTempRoot(args.root);
  const observation = readContainedObservation(root, args.input);
  const { bundle, dedicated, callerStatus, source } = getBundle(observation);
  if (!bundle) {
    process.stdout.write(`${JSON.stringify(makeMalformedReport('Only a BrowserEvidenceBundle or the local execution envelope is accepted; caller checks/status are not authority.', callerStatus), null, 2)}\n`);
  } else {
    let evidence;
    try {
      evidence = validateBundle(bundle);
    } catch (error) {
      process.stdout.write(`${JSON.stringify(makeMalformedReport(error.message, callerStatus), null, 2)}\n`);
      process.exitCode = 0;
      throw new Error('__REPORT_EMITTED__');
    }
    const manualReview = isRecord(bundle.manualReview) ? bundle.manualReview : isRecord(observation.manualReview) ? observation.manualReview : null;
    const checks = evaluateChecks(evidence, bundle, manualReview);
    const dedicatedEligible = source === 'browser-qa-execution-envelope'
      ? isRecord(dedicated) && dedicated.materialized === true && dedicated.attempted === true && dedicated.childStarted === true && dedicated.succeeded === true && bundle.materialized === true && bundle.attempted === true && bundle.browserReady === true && bundle.sessionReady === true && bundle.succeeded === true
      : bundle.synthetic !== true && bundle.materialized === true && bundle.attempted === true && bundle.browserReady === true && bundle.sessionReady === true && bundle.succeeded === true;
    const evidenceStatus = finalStatus(checks, evidence, bundle);
    const hermeticEvidence = bundle.synthetic === true || bundle.evidenceOrigin === 'hermetic-fixture';
    const reportStatus = hermeticEvidence && evidenceStatus === 'PASS' ? 'INCOMPLETE' : evidenceStatus;
    process.stdout.write(`${JSON.stringify({
      schemaVersion: 1,
      mode: 'ACCESSIBILITY_VERIFY',
      status: reportStatus,
      contractValid: true,
      readOnly: true,
      codeModified: false,
      browserStarted: bundle.browserReady === true,
      browserReady: bundle.browserReady,
      sessionReady: bundle.sessionReady,
      dedicatedPass: dedicatedEligible && reportStatus === 'PASS',
      evidenceOrigin: bundle.synthetic === true ? 'hermetic-fixture' : source,
      syntheticEvidenceStatus: hermeticEvidence ? evidenceStatus : null,
      callerStatusIgnored: callerStatus !== undefined,
      checks,
      manualReview: {
        globalBooleanIgnored: manualReview?.reviewed === true,
        byCheckUsed: checks.some((check) => check.manualReviewApplied),
      },
      axe: { classification: 'SUPPLEMENTARY', scanExecuted: false, status: 'NOT_EXECUTED', callerClaimIgnored: true },
      limitations: [
        ...(Array.isArray(bundle.limitations) ? bundle.limitations.slice(0, 12).map((item) => boundedText(item, 512)) : []),
        ...(!dedicatedEligible ? ['This evidence is not eligible to claim a dedicated PASS.'] : []),
      ],
    }, null, 2)}\n`);
  }
} catch (error) {
  if (error?.message !== '__REPORT_EMITTED__') fail(error.message);
}
