const OWN = Object.prototype.hasOwnProperty;

export class ImpeccableAuthorityBoundaryError extends Error {
  constructor(code, message) {
    super(`${code}: ${message}`);
    this.name = 'ImpeccableAuthorityBoundaryError';
    this.code = code;
  }
}

export function validateImpeccableAuthorityPolicy(policy) {
  assertPlainObject(policy, 'policy');
  assertExactKeys(
    policy,
    [
      'schemaVersion', 'policyId', 'architecture', 'authorityOrder', 'upstream', 'inputSchema',
      'dataBlocks', 'directives', 'subagents', 'capabilities', 'liveEvents', 'outputEnvelope',
    ],
    [],
    'policy',
  );
  if (policy.schemaVersion !== 1) fail('UNKNOWN_POLICY_SCHEMA', 'Only policy schemaVersion 1 is supported.');
  if (policy.architecture !== 'ftk-owned-structural-context-mediator') {
    fail('INVALID_POLICY', 'The policy does not select the FTK-owned structural mediator.');
  }
  assertPlainObject(policy.upstream, 'policy.upstream');
  assertExactKeys(
    policy.upstream,
    ['id', 'ref', 'commitSha', 'snapshotTreeSha256', 'skillEntrySha256', 'contractFiles', 'runtimeImportPolicy', 'runtimeImportReason'],
    [],
    'policy.upstream',
  );
  for (const field of ['id', 'ref', 'commitSha', 'snapshotTreeSha256', 'skillEntrySha256', 'runtimeImportPolicy', 'runtimeImportReason']) {
    assertString(policy.upstream[field], `policy.upstream.${field}`);
  }
  assertStringArrayLikeContractFiles(policy.upstream.contractFiles, 'policy.upstream.contractFiles');
  if (policy.upstream?.runtimeImportPolicy !== 'deny') {
    fail('INVALID_POLICY', 'Upstream runtime imports must be denied at this boundary.');
  }
  if (policy.inputSchema?.unknownBlockPolicy !== 'deny' || policy.inputSchema?.unknownKeyPolicy !== 'deny') {
    fail('INVALID_POLICY', 'Unknown context blocks and keys must fail closed.');
  }
  if (policy.directives?.unknownDirectivePolicy !== 'deny') {
    fail('INVALID_POLICY', 'Unknown directives must fail closed.');
  }
  if (policy.liveEvents?.unknownEventPolicy !== 'deny' || policy.liveEvents?.unknownKeyPolicy !== 'deny') {
    fail('INVALID_POLICY', 'Unknown live events and fields must fail closed.');
  }
  if (policy.outputEnvelope?.dataNeverBecomesDirective !== true
      || policy.outputEnvelope?.upstreamInstructionsForwarded !== false) {
    fail('INVALID_POLICY', 'The output contract must keep data subordinate and drop upstream instructions.');
  }
  assertUniqueStrings(policy.capabilities, 'policy.capabilities');
  assertUniqueStrings(policy.inputSchema.allowedBlockTypes, 'policy.inputSchema.allowedBlockTypes');
  assertUniqueStrings(policy.directives.explicitlyProhibited, 'policy.directives.explicitlyProhibited');
  assertUniqueStrings(policy.liveEvents.discardedFields, 'policy.liveEvents.discardedFields');
  assertUniqueBy(policy.directives.allowlist, 'name', 'policy.directives.allowlist');
  assertUniqueBy(policy.liveEvents.schemas, 'type', 'policy.liveEvents.schemas');
  return policy;
}

export function expectedImpeccableSourceFingerprint(policy) {
  validateImpeccableAuthorityPolicy(policy);
  return {
    upstreamId: policy.upstream.id,
    ref: policy.upstream.ref,
    commitSha: policy.upstream.commitSha,
    snapshotTreeSha256: policy.upstream.snapshotTreeSha256,
    skillEntrySha256: policy.upstream.skillEntrySha256,
    contractFiles: policy.upstream.contractFiles.map(({ path, sha256 }) => ({ path, sha256 })),
  };
}

export function mediateImpeccableContext(input, policy, options = {}) {
  validateImpeccableAuthorityPolicy(policy);
  validateOptions(options);
  assertPlainObject(input, 'context input');
  assertExactKeys(
    input,
    policy.inputSchema.requiredTopLevelKeys,
    policy.inputSchema.allowedTopLevelKeys.filter((key) => !policy.inputSchema.requiredTopLevelKeys.includes(key)),
    'context input',
  );
  if (input.schemaVersion !== policy.inputSchema.schemaVersion) {
    fail('UNKNOWN_INPUT_SCHEMA', `Unsupported context schemaVersion ${JSON.stringify(input.schemaVersion)}.`);
  }
  const sourceFingerprint = validateSourceFingerprint(input.sourceFingerprint, policy);
  const invocation = validateInvocation(input.invocation, policy);
  if (!Array.isArray(input.blocks)) fail('INVALID_SCHEMA', 'context input.blocks must be an array.');

  const data = [];
  const advisory = [];
  const requestedOperations = [capabilityRequest(invocation.capability)];
  for (const block of input.blocks) {
    mediateBlock(block, policy, options, { data, advisory, requestedOperations });
  }

  return envelope(policy, sourceFingerprint, { data, advisory, requestedOperations, events: [] });
}

export function mediateImpeccableLiveEvent(input, policy) {
  validateImpeccableAuthorityPolicy(policy);
  assertPlainObject(input, 'live input');
  assertExactKeys(input, ['schemaVersion', 'sourceFingerprint', 'event'], [], 'live input');
  if (input.schemaVersion !== policy.liveEvents.schemaVersion) {
    fail('UNKNOWN_LIVE_SCHEMA', `Unsupported live schemaVersion ${JSON.stringify(input.schemaVersion)}.`);
  }
  const sourceFingerprint = validateSourceFingerprint(input.sourceFingerprint, policy);
  const event = validateLiveEvent(input.event, policy);
  const requestedOperations = event.ftkRepresentation.nextAction === 'no-effect'
    ? []
    : [{
        type: 'live-event',
        operation: event.ftkRepresentation.nextAction,
        mediation: 'sr3i-required',
        execution: 'not-performed',
      }];
  return envelope(policy, sourceFingerprint, {
    data: [],
    advisory: [],
    requestedOperations,
    events: [event],
  });
}

function mediateBlock(block, policy, options, output) {
  assertPlainObject(block, 'context block');
  if (typeof block.type !== 'string' || !policy.inputSchema.allowedBlockTypes.includes(block.type)) {
    fail('UNKNOWN_BLOCK', `Block type ${JSON.stringify(block.type)} is not registered.`);
  }
  if (OWN.call(policy.dataBlocks, block.type)) {
    output.data.push(validateDataBlock(block, policy.dataBlocks[block.type]));
    return;
  }
  if (block.type === 'directive') {
    output.advisory.push(validateDirective(block, policy));
    return;
  }
  if (block.type === 'subagent-recommendation') {
    output.requestedOperations.push(validateSubagentRecommendation(block, policy, options));
    return;
  }
  fail('UNKNOWN_BLOCK', `Block type ${JSON.stringify(block.type)} has no mediator.`);
}

function validateDataBlock(block, schema) {
  assertExactKeys(block, schema.requiredFields, schema.optionalFields, `${block.type} block`);
  for (const field of ['path', 'content']) assertString(block[field], `${block.type}.${field}`);
  if (block.type === 'surface-brief') {
    assertString(block.slug, 'surface-brief.slug');
    if (OWN.call(block, 'primaryTarget')) assertString(block.primaryTarget, 'surface-brief.primaryTarget');
    if (OWN.call(block, 'relatedTargets')) {
      assertStringArray(block.relatedTargets, 'surface-brief.relatedTargets');
    }
  }
  return cloneJson({ kind: block.type, ...withoutKey(block, 'type') });
}

function validateDirective(block, policy) {
  assertExactKeys(block, ['type', 'name', 'data'], [], 'directive block');
  assertString(block.name, 'directive.name');
  if (policy.directives.explicitlyProhibited.includes(block.name)) {
    fail('PROHIBITED_DIRECTIVE', `Directive ${block.name} attempts to alter authority or authorization.`);
  }
  const definition = policy.directives.allowlist.find(({ name }) => name === block.name);
  if (!definition) fail('UNKNOWN_DIRECTIVE', `Directive ${block.name} is not in the exact allowlist.`);
  assertPlainObject(block.data, `directive ${block.name}.data`);
  assertExactKeys(block.data, definition.requiredFields, definition.optionalFields, `directive ${block.name}.data`);
  validateInertJson(block.data, `directive ${block.name}.data`);
  return {
    code: definition.ftkAdvisoryCode,
    message: definition.ftkMessage,
    data: cloneJson(block.data),
  };
}

function validateSubagentRecommendation(block, policy, options) {
  assertExactKeys(block, ['type', 'workflow', 'agent'], ['reason'], 'subagent-recommendation block');
  if (!policy.subagents.workflows.includes(block.workflow)) {
    fail('UNKNOWN_SUBAGENT_WORKFLOW', `Subagent workflow ${JSON.stringify(block.workflow)} is not registered.`);
  }
  if (!policy.subagents.agents.includes(block.agent)) {
    fail('UNKNOWN_SUBAGENT', `Subagent ${JSON.stringify(block.agent)} is not registered.`);
  }
  if (OWN.call(block, 'reason')) assertString(block.reason, 'subagent-recommendation.reason');
  const hostAllows = options.hostPermissions?.subagents === 'allow';
  return {
    type: 'subagent',
    workflow: block.workflow,
    agent: block.agent,
    origin: 'upstream-recommendation',
    mediation: hostAllows ? 'host-may-dispatch' : 'inline-required',
    execution: 'not-performed',
    fallback: policy.subagents.fallback,
    ...(OWN.call(block, 'reason') ? { reason: block.reason } : {}),
  };
}

function validateLiveEvent(event, policy) {
  assertPlainObject(event, 'live event');
  assertString(event.type, 'live event.type');
  const schema = policy.liveEvents.schemas.find(({ type }) => type === event.type);
  if (!schema) fail('UNKNOWN_LIVE_EVENT', `Live event ${JSON.stringify(event.type)} is not registered.`);
  const discarded = policy.liveEvents.discardedFields;
  assertExactKeys(
    event,
    ['type', ...schema.requiredFields],
    [...schema.optionalFields, ...discarded],
    `live event ${event.type}`,
  );
  for (const field of [...schema.requiredFields, ...schema.optionalFields]) {
    if (OWN.call(event, field)) validateTypedField(event[field], schema.fieldTypes[field], `live event ${event.type}.${field}`);
  }
  for (const field of discarded) {
    if (OWN.call(event, field)) assertString(event[field], `live event ${event.type}.${field}`);
  }
  const data = {};
  for (const [key, value] of Object.entries(event)) {
    if (key !== 'type' && !discarded.includes(key)) data[key] = cloneJson(value);
  }
  return {
    type: event.type,
    data,
    ftkRepresentation: {
      code: schema.ftkCode,
      nextAction: schema.ftkNextAction,
      authority: 'ftk-owned',
    },
  };
}

function validateSourceFingerprint(actual, policy) {
  const expected = expectedFingerprintWithoutPolicyValidation(policy);
  assertPlainObject(actual, 'sourceFingerprint');
  assertExactKeys(actual, ['upstreamId', 'ref', 'commitSha', 'snapshotTreeSha256', 'skillEntrySha256', 'contractFiles'], [], 'sourceFingerprint');
  for (const field of ['upstreamId', 'ref', 'commitSha', 'snapshotTreeSha256', 'skillEntrySha256']) {
    assertString(actual[field], `sourceFingerprint.${field}`);
  }
  assertStringArrayLikeContractFiles(actual.contractFiles, 'sourceFingerprint.contractFiles');
  if (canonicalJson(actual) !== canonicalJson(expected)) {
    fail('SOURCE_FINGERPRINT_MISMATCH', 'The source fingerprint does not match the pinned Impeccable contract.');
  }
  return cloneJson(actual);
}

function expectedFingerprintWithoutPolicyValidation(policy) {
  return {
    upstreamId: policy.upstream.id,
    ref: policy.upstream.ref,
    commitSha: policy.upstream.commitSha,
    snapshotTreeSha256: policy.upstream.snapshotTreeSha256,
    skillEntrySha256: policy.upstream.skillEntrySha256,
    contractFiles: policy.upstream.contractFiles.map(({ path, sha256 }) => ({ path, sha256 })),
  };
}

function validateInvocation(invocation, policy) {
  assertPlainObject(invocation, 'invocation');
  assertExactKeys(invocation, ['skill', 'capability'], [], 'invocation');
  if (invocation.skill !== 'impeccable') fail('INVALID_INVOCATION', 'Only the Impeccable adapter may use this mediator.');
  if (!policy.capabilities.includes(invocation.capability)) {
    fail('UNKNOWN_CAPABILITY', `Capability ${JSON.stringify(invocation.capability)} is not registered.`);
  }
  return invocation;
}

function capabilityRequest(capability) {
  return {
    type: 'capability',
    capability,
    selectionMeaning: 'capability-selected-only',
    effectsGranted: [],
    execution: 'not-performed',
  };
}

function validateOptions(options) {
  assertPlainObject(options, 'options');
  assertExactKeys(options, [], ['hostPermissions'], 'options');
  if (!OWN.call(options, 'hostPermissions')) return;
  assertPlainObject(options.hostPermissions, 'options.hostPermissions');
  assertExactKeys(options.hostPermissions, ['subagents'], [], 'options.hostPermissions');
  if (!['allow', 'deny'].includes(options.hostPermissions.subagents)) {
    fail('INVALID_HOST_PERMISSION', 'options.hostPermissions.subagents must be allow or deny.');
  }
}

function envelope(policy, sourceFingerprint, parts) {
  return {
    schemaVersion: policy.outputEnvelope.schemaVersion,
    sourceFingerprint: cloneJson(sourceFingerprint),
    data: parts.data,
    advisory: parts.advisory,
    requestedOperations: parts.requestedOperations,
    events: parts.events,
  };
}

function validateTypedField(value, type, label) {
  switch (type) {
    case 'string': assertString(value, label); break;
    case 'non-empty-string':
      assertString(value, label);
      if (!value.trim()) fail('INVALID_SCHEMA', `${label} must not be empty.`);
      break;
    case 'positive-integer':
      if (!Number.isInteger(value) || value < 1) fail('INVALID_SCHEMA', `${label} must be a positive integer.`);
      break;
    case 'object': assertPlainObject(value, label); validateInertJson(value, label); break;
    case 'array':
      if (!Array.isArray(value)) fail('INVALID_SCHEMA', `${label} must be an array.`);
      validateInertJson(value, label);
      break;
    case 'json': validateInertJson(value, label); break;
    default: fail('INVALID_POLICY', `Unknown field type ${JSON.stringify(type)} for ${label}.`);
  }
}

function validateInertJson(value, label, depth = 0) {
  if (depth > 20) fail('INVALID_SCHEMA', `${label} exceeds the maximum nesting depth.`);
  if (value === null || ['string', 'boolean'].includes(typeof value)) return;
  if (typeof value === 'number' && Number.isFinite(value)) return;
  if (Array.isArray(value)) {
    value.forEach((item, index) => validateInertJson(item, `${label}[${index}]`, depth + 1));
    return;
  }
  if (isPlainObject(value)) {
    for (const [key, item] of Object.entries(value)) {
      if (key === '__proto__' || key === 'prototype' || key === 'constructor') {
        fail('INVALID_SCHEMA', `${label} contains a forbidden object key.`);
      }
      validateInertJson(item, `${label}.${key}`, depth + 1);
    }
    return;
  }
  fail('INVALID_SCHEMA', `${label} must contain JSON data only.`);
}

function assertStringArrayLikeContractFiles(value, label) {
  if (!Array.isArray(value)) fail('INVALID_SCHEMA', `${label} must be an array.`);
  for (const [index, item] of value.entries()) {
    assertPlainObject(item, `${label}[${index}]`);
    assertExactKeys(item, ['path', 'sha256'], [], `${label}[${index}]`);
    assertString(item.path, `${label}[${index}].path`);
    assertString(item.sha256, `${label}[${index}].sha256`);
  }
}

function assertUniqueStrings(value, label) {
  assertStringArray(value, label);
  if (new Set(value).size !== value.length) fail('INVALID_POLICY', `${label} contains duplicates.`);
}

function assertStringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    fail('INVALID_SCHEMA', `${label} must be an array of strings.`);
  }
}

function assertUniqueBy(value, key, label) {
  if (!Array.isArray(value)) fail('INVALID_POLICY', `${label} must be an array.`);
  const items = value.map((item) => item?.[key]);
  if (items.some((item) => typeof item !== 'string') || new Set(items).size !== items.length) {
    fail('INVALID_POLICY', `${label} must contain unique string ${key} values.`);
  }
}

function assertExactKeys(value, required, optional, label) {
  const allowed = new Set([...required, ...optional]);
  const missing = required.filter((key) => !OWN.call(value, key));
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (missing.length) fail('INVALID_SCHEMA', `${label} is missing required keys: ${missing.join(', ')}.`);
  if (unknown.length) fail('UNKNOWN_KEY', `${label} contains unknown keys: ${unknown.join(', ')}.`);
}

function assertPlainObject(value, label) {
  if (!isPlainObject(value)) fail('INVALID_SCHEMA', `${label} must be a plain object.`);
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertString(value, label) {
  if (typeof value !== 'string') fail('INVALID_SCHEMA', `${label} must be a string.`);
}

function withoutKey(value, omitted) {
  return Object.fromEntries(Object.entries(value).filter(([key]) => key !== omitted));
}

function cloneJson(value) {
  validateInertJson(value, 'value');
  return JSON.parse(JSON.stringify(value));
}

function canonicalJson(value) {
  return JSON.stringify(sortJson(value));
}

function sortJson(value) {
  if (Array.isArray(value)) return value.map(sortJson);
  if (!isPlainObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortJson(value[key])]));
}

function fail(code, message) {
  throw new ImpeccableAuthorityBoundaryError(code, message);
}
