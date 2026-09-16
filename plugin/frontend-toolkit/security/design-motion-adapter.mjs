/* FTK-owned Phase 1 adapter. External Skills are semantic source only. */

const OPERATIONS = new Set(['taste', 'review-animations', 'improve-animations', 'animate']);
const SEVERITIES = new Set(['BLOCKER', 'HIGH', 'MEDIUM', 'LOW', 'INFO']);
const FORBIDDEN_KEYS = new Set([
  'outputpath', 'planpath', 'animationplanpath', 'writepath', 'projectroot',
  'projectpath', 'browser', 'network', 'install', 'installer', 'command',
  'executable', 'scriptpath', 'subagent', 'subagents',
]);
const ZERO_EFFECTS = Object.freeze({
  network: 0,
  browser: 0,
  install: 0,
  projectWrite: 0,
  projectExecution: 0,
  upstreamExecution: 0,
  subagentInvocation: 0,
});

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, required, optional, label) {
  if (!isObject(value)) throw new Error(`${label} must be an object.`);
  const allowed = new Set([...required, ...optional]);
  for (const key of required) if (!Object.hasOwn(value, key)) throw new Error(`${label} is missing ${key}.`);
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new Error(`${label} contains unknown key ${key}.`);
}

function inert(value, label, depth = 0) {
  if (depth > 20) throw new Error(`${label} exceeds the maximum JSON depth.`);
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`${label} contains a non-finite number.`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => inert(item, `${label}[${index}]`, depth + 1));
    return;
  }
  if (isObject(value)) {
    for (const [key, item] of Object.entries(value)) {
      if (key === '__proto__' || key === 'prototype' || key === 'constructor') throw new Error(`${label} contains a forbidden key.`);
      inert(item, `${label}.${key}`, depth + 1);
    }
    return;
  }
  throw new Error(`${label} contains a non-JSON value.`);
}

function noForbiddenKeys(value, label) {
  if (value === null || typeof value !== 'object') return;
  if (Array.isArray(value)) {
    value.forEach((item, index) => noForbiddenKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (FORBIDDEN_KEYS.has(key.toLowerCase())) throw new Error(`${label} contains an effect or persistence key: ${key}.`);
    noForbiddenKeys(item, `${label}.${key}`);
  }
}

function strings(value, label, allowNull = false) {
  if (value === null && allowNull) return;
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string' || item.trim() === '')) {
    throw new Error(`${label} must be an array of non-empty strings.`);
  }
}

function stringValue(value, label, allowNull = true) {
  if (value === null && allowNull) return;
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${label} must be a non-empty string.`);
}

function clone(value) {
  return value === null || value === undefined ? value : JSON.parse(JSON.stringify(value));
}

function validateContext(context) {
  exactKeys(context, ['routingMode', 'referenceAuthority', 'approvedReference', 'allowedDelta', 'target', 'constraints'], [], 'context');
  inert(context, 'context');
  noForbiddenKeys(context, 'context');
  if (!['QUALITY_FIRST', 'FIDELITY_FIRST'].includes(context.routingMode)) throw new Error('context.routingMode is invalid.');
  if (!['none', 'primary-authority'].includes(context.referenceAuthority)) throw new Error('context.referenceAuthority is invalid.');
  if (context.referenceAuthority === 'primary-authority' && (!isObject(context.approvedReference) || typeof context.approvedReference.id !== 'string' || context.approvedReference.id.trim() === '')) throw new Error('context.approvedReference.id is required for primary-authority.');
  if (context.approvedReference !== null) {
    exactKeys(context.approvedReference, ['id'], ['kind', 'authority', 'uri', 'revision', 'label'], 'context.approvedReference');
    stringValue(context.approvedReference.id, 'context.approvedReference.id', false);
  }
  if (context.routingMode === 'FIDELITY_FIRST' && (context.referenceAuthority !== 'primary-authority' || !isObject(context.approvedReference))) {
    throw new Error('FIDELITY_FIRST requires primary-authority and approvedReference.');
  }
  strings(context.allowedDelta, 'context.allowedDelta');
  const allowedDeltas = new Set(['none', 'timing-only', 'easing-only', 'duration-only', 'sequence-only', 'reduced-motion-only', 'direction-only']);
  if (context.allowedDelta.some((item) => !allowedDeltas.has(item))) throw new Error('context.allowedDelta contains an unsupported value.');
  if (context.allowedDelta.includes('none') && context.allowedDelta.length > 1) throw new Error('context.allowedDelta=none cannot be combined.');
  if (!isObject(context.target) || !isObject(context.constraints)) throw new Error('context.target and context.constraints must be objects.');
}

function validateSourceVerification(sourceVerification) {
  exactKeys(sourceVerification, ['verified', 'dependencyId', 'sourceFingerprint', 'representation'], [], 'sourceVerification');
  if (sourceVerification.verified !== true) throw new Error('sourceVerification must be verified.');
  if (typeof sourceVerification.dependencyId !== 'string' || sourceVerification.dependencyId.trim() === '') throw new Error('sourceVerification.dependencyId is invalid.');
  if (typeof sourceVerification.sourceFingerprint !== 'string' || !/^[0-9a-f]{64}$/.test(sourceVerification.sourceFingerprint)) throw new Error('sourceVerification.sourceFingerprint is invalid.');
  if (sourceVerification.representation !== 'canonical-lf-and-crlf-normalized') throw new Error('sourceVerification representation is invalid.');
}

function validateFindingInput(finding, label) {
  exactKeys(finding, ['id', 'target', 'category', 'severityHint', 'evidence'], ['currentState', 'recommendedState', 'rationale', 'limitations'], label);
  inert(finding, label);
  noForbiddenKeys(finding, label);
  stringValue(finding.id, `${label}.id`, false);
  stringValue(finding.category, `${label}.category`, false);
  const hint = String(finding.severityHint).toUpperCase();
  if (!SEVERITIES.has(hint)) throw new Error(`${label}.severityHint is invalid.`);
  if (!(typeof finding.target === 'string' && finding.target.trim() !== '') && !isObject(finding.target)) throw new Error(`${label}.target is invalid.`);
  strings(finding.evidence, `${label}.evidence`);
  if (finding.evidence.length === 0) throw new Error(`${label}.evidence must not be empty.`);
  for (const name of ['rationale', 'limitations']) if (Object.hasOwn(finding, name)) strings(finding[name], `${label}.${name}`);
  for (const name of ['currentState', 'recommendedState']) if (Object.hasOwn(finding, name) && finding[name] !== null && !isObject(finding[name])) throw new Error(`${label}.${name} must be an object or null.`);
}

function validateOperationInput(operation, input) {
  if (!isObject(input)) throw new Error('child request input must be an object.');
  switch (operation) {
    case 'taste': {
      exactKeys(input, [], ['explicitRequest', 'aestheticGap', 'surfaceType', 'designRead', 'designVariance', 'motionIntensity', 'visualDensity', 'direction', 'rationale', 'limitations'], 'request.input');
      if (Object.hasOwn(input, 'explicitRequest') && typeof input.explicitRequest !== 'boolean') throw new Error('request.input.explicitRequest must be boolean.');
      if (Object.hasOwn(input, 'aestheticGap') && input.aestheticGap !== null) {
        exactKeys(input.aestheticGap, ['material'], ['description'], 'request.input.aestheticGap');
        if (typeof input.aestheticGap.material !== 'boolean') throw new Error('request.input.aestheticGap.material must be boolean.');
        if (Object.hasOwn(input.aestheticGap, 'description')) stringValue(input.aestheticGap.description, 'request.input.aestheticGap.description');
      }
      if (Object.hasOwn(input, 'surfaceType') && input.surfaceType !== null && !['dashboard', 'table', 'multi-step', 'accessibility', 'responsive-layout', 'generic-ux', 'other'].includes(input.surfaceType)) throw new Error('request.input.surfaceType is invalid.');
      if (Object.hasOwn(input, 'designRead') && input.designRead !== null && !isObject(input.designRead)) throw new Error('request.input.designRead must be an object or null.');
      for (const name of ['designVariance', 'motionIntensity', 'visualDensity']) if (Object.hasOwn(input, name)) stringValue(input[name], `request.input.${name}`);
      for (const name of ['direction', 'rationale', 'limitations']) if (Object.hasOwn(input, name)) strings(input[name], `request.input.${name}`);
      break;
    }
    case 'review-animations': {
      exactKeys(input, ['motionRelevant'], ['motion', 'findings'], 'request.input');
      if (typeof input.motionRelevant !== 'boolean') throw new Error('request.input.motionRelevant must be boolean.');
      if (Object.hasOwn(input, 'motion') && input.motion !== null && !isObject(input.motion)) throw new Error('request.input.motion must be an object or null.');
      if (input.motionRelevant) {
        if (!isObject(input.motion)) throw new Error('request.input.motion is required when motionRelevant is true.');
        exactKeys(input.motion, ['evidence'], ['existing', 'scope', 'source', 'summary'], 'request.input.motion');
        strings(input.motion.evidence, 'request.input.motion.evidence');
        if (input.motion.evidence.length === 0) throw new Error('request.input.motion.evidence must not be empty.');
        if (Object.hasOwn(input.motion, 'existing') && typeof input.motion.existing !== 'boolean') throw new Error('request.input.motion.existing must be boolean.');
        for (const name of ['scope', 'source', 'summary']) if (Object.hasOwn(input.motion, name)) stringValue(input.motion[name], `request.input.motion.${name}`);
      }
      if (Object.hasOwn(input, 'findings')) {
        if (!Array.isArray(input.findings)) throw new Error('request.input.findings must be an array.');
        input.findings.forEach((finding, index) => validateFindingInput(finding, `request.input.findings[${index}]`));
      }
      break;
    }
    case 'improve-animations': {
      exactKeys(input, [], ['explicitRequest', 'concreteFinding', 'findingRefs', 'priority', 'timing', 'easing', 'duration', 'sequence', 'reducedMotionRequirement', 'acceptanceCriteria', 'limitations'], 'request.input');
      if (Object.hasOwn(input, 'explicitRequest') && typeof input.explicitRequest !== 'boolean') throw new Error('request.input.explicitRequest must be boolean.');
      if (Object.hasOwn(input, 'concreteFinding') && input.concreteFinding !== null) validateFindingInput(input.concreteFinding, 'request.input.concreteFinding');
      if (Object.hasOwn(input, 'findingRefs')) strings(input.findingRefs, 'request.input.findingRefs');
      for (const name of ['priority', 'easing']) if (Object.hasOwn(input, name)) stringValue(input[name], `request.input.${name}`);
      if (Object.hasOwn(input, 'timing') && input.timing !== null && !isObject(input.timing)) throw new Error('request.input.timing must be an object or null.');
      if (Object.hasOwn(input, 'duration') && input.duration !== null && (typeof input.duration !== 'number' || !Number.isFinite(input.duration))) throw new Error('request.input.duration must be numeric or null.');
      if (Object.hasOwn(input, 'sequence')) strings(input.sequence, 'request.input.sequence');
      if (Object.hasOwn(input, 'reducedMotionRequirement') && input.reducedMotionRequirement !== null && !isObject(input.reducedMotionRequirement)) throw new Error('request.input.reducedMotionRequirement must be an object or null.');
      if (Object.hasOwn(input, 'acceptanceCriteria')) strings(input.acceptanceCriteria, 'request.input.acceptanceCriteria');
      if (Object.hasOwn(input, 'limitations')) strings(input.limitations, 'request.input.limitations');
      break;
    }
    case 'animate':
      exactKeys(input, [], [], 'request.input');
      break;
    default:
      throw new Error('child request operation is unknown.');
  }
}

function validateRequest(request) {
  exactKeys(request, ['schemaVersion', 'operation', 'context', 'input'], ['sourceVerification', 'testHarness'], 'child request');
  inert(request, 'child request');
  noForbiddenKeys(request, 'child request');
  if (request.schemaVersion !== 1) throw new Error('child request schemaVersion is unsupported.');
  if (!OPERATIONS.has(request.operation)) throw new Error('child request operation is unknown.');
  validateContext(request.context);
  if (!isObject(request.input)) throw new Error('child request input must be an object.');
  validateOperationInput(request.operation, request.input);
  if (request.operation !== 'animate') validateSourceVerification(request.sourceVerification);
  else if (Object.hasOwn(request, 'sourceVerification')) validateSourceVerification(request.sourceVerification);
  if (Object.hasOwn(request, 'testHarness')) {
    exactKeys(request.testHarness, ['behavior'], [], 'testHarness');
    if (!['malformed', 'stdout-overflow', 'stderr-overflow', 'timeout', 'fail'].includes(request.testHarness.behavior)) throw new Error('testHarness behavior is unknown.');
  }
}

function severity(value) {
  const normalized = String(value).toUpperCase();
  if (!SEVERITIES.has(normalized)) throw new Error(`Unsupported finding severity hint: ${value}.`);
  return normalized;
}

function normalizeFinding(finding) {
  const result = {
    id: finding.id,
    target: clone(finding.target),
    category: finding.category,
    normalizedSeverity: severity(finding.severityHint),
    evidence: [...finding.evidence],
    currentState: clone(finding.currentState ?? null),
    recommendedState: clone(finding.recommendedState ?? null),
    rationale: [...(finding.rationale ?? [])],
    limitations: [...(finding.limitations ?? [])],
  };
  return result;
}

function common(request, status, limitations) {
  return {
    schemaVersion: 1,
    adapter: 'ftk-owned-design-motion-adapter',
    operation: request.operation,
    status,
    routingMode: request.context.routingMode,
    referenceAuthority: request.context.referenceAuthority,
    approvedReference: clone(request.context.approvedReference),
    allowedDelta: [...request.context.allowedDelta],
    sourceFingerprint: request.sourceVerification.sourceFingerprint,
    effects: { ...ZERO_EFFECTS },
    limitations: [...limitations],
  };
}

function taste(request) {
  const input = request.input;
  const explicit = input.explicitRequest === true;
  const materialGap = isObject(input.aestheticGap) && input.aestheticGap.material === true;
  const defaultExcludedSurface = ['dashboard', 'table', 'multi-step', 'accessibility', 'responsive-layout', 'generic-ux'].includes(input.surfaceType);
  const eligible = explicit || materialGap;
  const base = common(request, eligible ? 'ADVISORY' : 'NOT_APPLICABLE', [
    'Phase 1 Taste is advisory and read-only; it does not authorize implementation, image generation, installation, network, or project writes.',
    ...(input.limitations ?? []),
  ]);
  if (!eligible || (defaultExcludedSurface && !explicit && !materialGap)) {
    return { ...base, designRead: null, designVariance: null, motionIntensity: null, visualDensity: null, direction: [], rationale: [] };
  }
  if (!isObject(input.designRead)) throw new Error('Taste advisory requires structured input.designRead.');
  return {
    ...base,
    designRead: clone(input.designRead),
    designVariance: input.designVariance ?? null,
    motionIntensity: input.motionIntensity ?? null,
    visualDensity: input.visualDensity ?? null,
    direction: [...(input.direction ?? [])],
    rationale: [...(input.rationale ?? [])],
  };
}

function review(request) {
  const input = request.input;
  const limitations = [
    'Phase 1 review is semantic and read-only; no browser, runtime telemetry, tool call, or project execution was performed.',
  ];
  if (!input.motionRelevant) {
    return {
      ...common(request, 'NOT_APPLICABLE', limitations),
      findings: [],
      decision: 'NOT_APPLICABLE',
    };
  }
  const findings = (input.findings ?? []).map(normalizeFinding);
  const blocks = findings.some((finding) => finding.normalizedSeverity === 'BLOCKER' || finding.normalizedSeverity === 'HIGH');
  return {
    ...common(request, 'COMPLETE', limitations),
    findings,
    decision: blocks ? 'BLOCK' : 'APPROVE',
  };
}

function improve(request) {
  const input = request.input;
  const finding = input.concreteFinding ?? null;
  const refs = [...(input.findingRefs ?? [])];
  if (finding && !refs.includes(finding.id)) refs.unshift(finding.id);
  const requested = input.explicitRequest === true;
  const eligible = requested || Boolean(finding);
  const limitations = [
    'Phase 1 improve-animations returns an inline plan only; it does not write a plan file, project file, or implementation.',
    ...(input.limitations ?? []),
  ];
  if (!eligible) {
    return { ...common(request, 'NOT_APPLICABLE', limitations), plan: null };
  }
  if (request.context.routingMode === 'FIDELITY_FIRST') {
    const deltaChecks = [
      ['timing', 'timing-only', input.timing !== null && input.timing !== undefined],
      ['easing', 'easing-only', input.easing !== null && input.easing !== undefined],
      ['duration', 'duration-only', input.duration !== null && input.duration !== undefined],
      ['sequence', 'sequence-only', Array.isArray(input.sequence) && input.sequence.length > 0],
      ['reducedMotionRequirement', 'reduced-motion-only', input.reducedMotionRequirement !== null && input.reducedMotionRequirement !== undefined],
    ];
    for (const [field, delta, present] of deltaChecks) if (present && !request.context.allowedDelta.includes(delta)) throw new Error(`FIDELITY_FIRST input.${field} exceeds context.allowedDelta.`);
  }
  const priority = input.priority ?? (finding ? severity(finding.severityHint) : null);
  return {
    ...common(request, 'PLAN', limitations),
    plan: {
      findingRefs: refs,
      priority,
      timing: clone(input.timing ?? null),
      easing: input.easing ?? null,
      duration: input.duration ?? null,
      sequence: [...(input.sequence ?? [])],
      reducedMotionRequirement: clone(input.reducedMotionRequirement ?? null),
      acceptanceCriteria: [...(input.acceptanceCriteria ?? [])],
      limitations: ['Plan is advisory and must be separately selected and authorized before implementation.'],
      planPersistence: 'INLINE_ONLY',
    },
  };
}

function animateBlocked(request) {
  return {
    schemaVersion: 1,
    adapter: 'ftk-owned-design-motion-adapter',
    operation: 'animate',
    status: 'REGISTERED_NO_HANDLER',
    routingMode: request.context.routingMode,
    referenceAuthority: request.context.referenceAuthority,
    approvedReference: clone(request.context.approvedReference),
    allowedDelta: [...request.context.allowedDelta],
    sourceFingerprint: null,
    effects: { ...ZERO_EFFECTS },
    limitations: ['Phase 2 boundary: animate has no Phase 1 handler and cannot be inferred from routing, review, improve, findings, or Skill selection.'],
  };
}

async function testHarness(request, result) {
  if (!request.testHarness) return result;
  switch (request.testHarness.behavior) {
    case 'malformed':
      process.stdout.write('{malformed-phase1-output');
      return null;
    case 'stdout-overflow':
      process.stdout.write('x'.repeat(300000));
      return null;
    case 'stderr-overflow':
      process.stderr.write('x'.repeat(300000));
      return result;
    case 'timeout':
      await new Promise(() => {});
      return result;
    case 'fail':
      process.stderr.write('semantic adapter failure (test harness)\n');
      process.exitCode = 17;
      return null;
    default:
      throw new Error('Unsupported test harness behavior.');
  }
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf8');
}

async function main() {
  const raw = await readStdin();
  const request = JSON.parse(raw);
  validateRequest(request);
  if (request.operation === 'animate') {
    process.stdout.write(`${JSON.stringify(animateBlocked(request))}\n`);
    return;
  }
  const result = request.operation === 'taste' ? taste(request)
    : request.operation === 'review-animations' ? review(request)
      : improve(request);
  const harnessResult = await testHarness(request, result);
  if (harnessResult === null) return;
  process.stdout.write(`${JSON.stringify(harnessResult)}\n`);
}

main().catch((error) => {
  process.stderr.write(`FTK design-motion adapter failure: ${String(error?.message ?? error)}\n`);
  process.exitCode = 2;
});
