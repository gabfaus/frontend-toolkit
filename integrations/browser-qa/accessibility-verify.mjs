import fs from 'node:fs';
import path from 'node:path';

const checks = [
  ['wcag22', false],
  ['semanticHtml', false],
  ['landmarksHeadings', false],
  ['keyboard', true],
  ['focus', true],
  ['formsLabelsErrors', false],
  ['aria', false],
  ['contrastNonText', true],
  ['zoomReflow', true],
  ['prefersReducedMotion', true],
  ['motionAccessibility', true],
  ['screenReaderReasoning', true],
];
const validStatuses = new Set(['PASS', 'FAIL', 'INCOMPLETE', 'UNKNOWN']);

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const result = { root: null, input: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--root') {
      result.root = argv[++index];
    } else if (argv[index] === '--input') {
      result.input = argv[++index];
    } else {
      throw new Error(`Unknown accessibility argument: ${argv[index]}`);
    }
  }
  if (!result.root || !result.input) {
    throw new Error('--root and --input are required.');
  }
  return result;
}

function getStatus(value, checkId) {
  const status = typeof value === 'string' ? value : value?.status;
  if (!validStatuses.has(status)) {
    throw new Error(`Check ${checkId} must contain one of PASS, FAIL, INCOMPLETE or UNKNOWN.`);
  }
  return status;
}

try {
  const argumentsForVerify = parseArgs(process.argv.slice(2));
  const root = fs.realpathSync(path.resolve(argumentsForVerify.root));
  if (!fs.statSync(root).isDirectory()) {
    throw new Error('Verification root is not a directory.');
  }
  const inputPath = path.resolve(root, argumentsForVerify.input);
  const rootWithSeparator = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (!inputPath.startsWith(rootWithSeparator)) {
    throw new Error('Verification input escaped the supplied root.');
  }
  const realInputPath = fs.realpathSync(inputPath);
  if (!realInputPath.startsWith(rootWithSeparator)) {
    throw new Error('Verification input resolves outside the supplied root.');
  }
  const observation = JSON.parse(fs.readFileSync(realInputPath, 'utf8'));
  const observedChecks = observation.checks ?? {};
  const results = checks.map(([id, manualReviewRequired]) => {
    const status = observedChecks[id] === undefined ? 'INCOMPLETE' : getStatus(observedChecks[id], id);
    return { id, status, manualReviewRequired };
  });
  const manualReviewRequired = results.some((result) => result.manualReviewRequired);
  const manualReviewCompleted = observation.manualReview?.reviewed === true;
  let status = 'PASS';
  if (results.some((result) => result.status === 'FAIL')) {
    status = 'FAIL';
  } else if (results.some((result) => result.status === 'UNKNOWN')) {
    status = 'UNKNOWN';
  } else if (results.some((result) => result.status === 'INCOMPLETE')) {
    status = 'INCOMPLETE';
  } else if (manualReviewRequired && !manualReviewCompleted) {
    status = 'UNKNOWN';
  }
  process.stdout.write(JSON.stringify({
    schemaVersion: 1,
    mode: 'ACCESSIBILITY_VERIFY',
    status,
    readOnly: true,
    codeModified: false,
    browserStarted: false,
    manualReviewRequired,
    manualReviewCompleted,
    checks: results,
    axe: {
      classification: 'CONDITIONAL',
      used: observation.axe?.used === true,
      status: observation.axe?.status ?? 'INCOMPLETE',
    },
  }, null, 2) + '\n');
} catch (error) {
  fail(`ACCESSIBILITY_VERIFY_BLOCKED: ${error.message}`);
}
