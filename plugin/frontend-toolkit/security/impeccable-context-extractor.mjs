#!/usr/bin/env node

import { lstat, readFile, readdir, realpath } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_CONTEXT_BYTES = 1024 * 1024;
const MAX_SURFACE_BRIEFS = 32;
const CONTEXT_NAMES = Object.freeze({
  product: Object.freeze(['PRODUCT.md', 'Product.md', 'product.md']),
  design: Object.freeze(['DESIGN.md', 'Design.md', 'design.md']),
});

function fail(code, message) {
  throw new Error(`${code}: ${message}`);
}

function parseArguments(argv) {
  const allowed = new Set(['mode', 'projectRoot', 'capability', 'eventJson', 'authorityPolicy', 'operationPolicy', 'mediator']);
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const token = argv[index];
    if (!token?.startsWith('--') || index + 1 >= argv.length) fail('INVALID_ARGUMENTS', 'Arguments must be registered name/value pairs.');
    const name = token.slice(2);
    if (!allowed.has(name) || Object.hasOwn(parsed, name)) fail('INVALID_ARGUMENTS', `Unknown or duplicate argument ${token}.`);
    parsed[name] = argv[index + 1];
  }
  for (const required of ['mode', 'authorityPolicy', 'operationPolicy', 'mediator']) {
    if (!parsed[required]) fail('INVALID_ARGUMENTS', `Missing --${required}.`);
  }
  if (!['context', 'live-event'].includes(parsed.mode)) fail('UNKNOWN_MODE', 'Only context and live-event modes are registered.');
  const modeKeys = parsed.mode === 'context'
    ? new Set(['mode', 'projectRoot', 'capability', 'authorityPolicy', 'operationPolicy', 'mediator'])
    : new Set(['mode', 'eventJson', 'authorityPolicy', 'operationPolicy', 'mediator']);
  const unexpected = Object.keys(parsed).filter((key) => !modeKeys.has(key));
  if (unexpected.length) fail('INVALID_ARGUMENTS', `Mode received unregistered inputs: ${unexpected.join(', ')}.`);
  return parsed;
}

async function readJsonFile(filePath, label) {
  let text;
  try {
    text = await readFile(filePath, 'utf8');
  } catch {
    fail('POLICY_UNAVAILABLE', `${label} is unavailable.`);
  }
  try {
    return JSON.parse(text);
  } catch {
    fail('INVALID_POLICY', `${label} is not valid JSON.`);
  }
}

function assertIntegratedContracts(authorityPolicy, operationPolicy) {
  if (operationPolicy?.architecture !== 'ftk-owned-external-effects-mediation'
      || operationPolicy?.unknownOperationPolicy !== 'deny'
      || operationPolicy?.unknownEffectPolicy !== 'deny') {
    fail('INVALID_OPERATION_POLICY', 'The Impeccable operation policy is not fail closed.');
  }
  if (authorityPolicy?.upstream?.commitSha !== operationPolicy.upstreamCommit) {
    fail('CONTRACT_DRIFT', 'Authority and operation policies identify different upstream commits.');
  }
  const registered = new Set((operationPolicy.operations ?? []).map(({ id }) => id));
  const requested = new Set([authorityPolicy?.requestedOperationContract?.contextOperationId]);
  for (const schema of authorityPolicy?.liveEvents?.schemas ?? []) {
    if (schema.requestedOperationId !== null) requested.add(schema.requestedOperationId);
  }
  for (const operationId of requested) {
    if (typeof operationId !== 'string' || !registered.has(operationId)) {
      fail('CONTRACT_DRIFT', `Authority mapping references an unregistered operation: ${String(operationId)}.`);
    }
  }
}

function assertMediatedRequests(envelope, operationPolicy) {
  const registered = new Set(operationPolicy.operations.map(({ id }) => id));
  for (const request of envelope.requestedOperations) {
    if (request.type === 'subagent') {
      if (request.execution !== 'not-performed' || request.fallback !== 'inline') {
        fail('AUTHORITY_BYPASS', 'Subagent recommendation escaped the host boundary.');
      }
      continue;
    }
    if (typeof request.requestedOperationId !== 'string' || !registered.has(request.requestedOperationId)) {
      fail('UNKNOWN_REQUESTED_OPERATION', 'Mediator produced an unregistered requested operation.');
    }
    if (request.execution !== 'not-performed') fail('AUTHORITY_BYPASS', 'Mediator performed an operation.');
  }
}

function relativeWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  if (relative === '') return '.';
  if (path.isAbsolute(relative) || relative === '..' || relative.startsWith(`..${path.sep}`)) {
    fail('PATH_ESCAPE', 'Context path escapes ProjectRoot.');
  }
  return relative.replaceAll(path.sep, '/');
}

async function assertPhysicalPath(root, candidate, expectedType) {
  const info = await lstat(candidate);
  if (info.isSymbolicLink()) fail('REPARSE_POINT_DENIED', 'Context paths cannot be symbolic links or junctions.');
  if (expectedType === 'file' && !info.isFile()) fail('INVALID_CONTEXT_PATH', 'Expected a regular context file.');
  if (expectedType === 'directory' && !info.isDirectory()) fail('INVALID_CONTEXT_PATH', 'Expected a context directory.');
  const physical = await realpath(candidate);
  relativeWithin(root, physical);
  return { info, physical };
}

async function findSingleContextFile(root, names, label) {
  const matches = new Map();
  for (const name of names) {
    const candidate = path.join(root, name);
    try {
      const checked = await assertPhysicalPath(root, candidate, 'file');
      const identity = process.platform === 'win32' ? checked.physical.toLowerCase() : checked.physical;
      matches.set(identity, { path: checked.physical, relative: relativeWithin(root, checked.physical), size: checked.info.size });
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      throw error;
    }
  }
  if (matches.size > 1) fail('AMBIGUOUS_CONTEXT', `Multiple ${label} variants exist.`);
  return [...matches.values()][0] ?? null;
}

async function readBoundedContext(file, label) {
  if (file.size > MAX_CONTEXT_BYTES) fail('CONTEXT_TOO_LARGE', `${label} exceeds ${MAX_CONTEXT_BYTES} bytes.`);
  return readFile(file.path, 'utf8');
}

async function collectContextBlocks(projectRoot) {
  const rootInfo = await lstat(projectRoot);
  if (rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) fail('INVALID_PROJECT_ROOT', 'ProjectRoot must be a physical directory.');
  const root = await realpath(projectRoot);
  const product = await findSingleContextFile(root, CONTEXT_NAMES.product, 'PRODUCT.md');
  const design = await findSingleContextFile(root, CONTEXT_NAMES.design, 'DESIGN.md');
  const blocks = [];
  if (product) blocks.push({ type: 'product-markdown', path: product.relative, content: await readBoundedContext(product, 'PRODUCT.md') });
  if (design) blocks.push({ type: 'design-markdown', path: design.relative, content: await readBoundedContext(design, 'DESIGN.md') });

  const surfacesRoot = path.join(root, '.impeccable', 'surfaces');
  const surfaces = [];
  try {
    await assertPhysicalPath(root, surfacesRoot, 'directory');
    const entries = await readdir(surfacesRoot, { withFileTypes: true });
    const markdown = entries.filter((entry) => entry.name.endsWith('.md')).sort((a, b) => a.name.localeCompare(b.name));
    if (markdown.length > MAX_SURFACE_BRIEFS) fail('CONTEXT_TOO_LARGE', `More than ${MAX_SURFACE_BRIEFS} surface briefs are not accepted.`);
    for (const entry of markdown) {
      if (!/^[a-z0-9][a-z0-9-]{0,63}\.md$/.test(entry.name)) fail('UNKNOWN_SURFACE_BRIEF', 'Surface brief filename is outside the structural contract.');
      const checked = await assertPhysicalPath(root, path.join(surfacesRoot, entry.name), 'file');
      const relative = relativeWithin(root, checked.physical);
      const slug = entry.name.slice(0, -3);
      const content = await readBoundedContext({ path: checked.physical, size: checked.info.size }, `surface brief ${slug}`);
      surfaces.push({ type: 'surface-brief', path: relative, slug, content });
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  blocks.push(...surfaces);
  blocks.push({
    type: 'directive',
    name: 'RESOLVED_CONTEXT',
    data: {
      projectRoot: '.',
      productPath: product?.relative ?? '',
      designPath: design?.relative ?? '',
      surfaceBriefPath: surfaces.length === 1 ? surfaces[0].path : '',
    },
  });
  if (!product) blocks.push({ type: 'directive', name: 'NO_PRODUCT_MD', data: {} });
  if (surfaces.length > 1) {
    blocks.push({ type: 'directive', name: 'SURFACE_CONTEXT_AVAILABLE', data: { candidates: surfaces.map(({ path: filePath, slug }) => ({ path: filePath, slug })) } });
  }
  return { root, blocks };
}

export async function runIntegratedImpeccableMediation(argv) {
  const args = parseArguments(argv);
  const authorityPolicy = await readJsonFile(args.authorityPolicy, 'authority policy');
  const operationPolicy = await readJsonFile(args.operationPolicy, 'operation policy');
  assertIntegratedContracts(authorityPolicy, operationPolicy);
  const mediatorUrl = pathToFileURL(path.resolve(args.mediator)).href;
  const mediator = await import(mediatorUrl);
  mediator.validateImpeccableAuthorityPolicy(authorityPolicy);
  const sourceFingerprint = mediator.expectedImpeccableSourceFingerprint(authorityPolicy);
  let envelope;
  if (args.mode === 'context') {
    if (!args.projectRoot || !args.capability) fail('INVALID_ARGUMENTS', 'Context mode requires ProjectRoot and capability.');
    const { blocks } = await collectContextBlocks(args.projectRoot);
    envelope = mediator.mediateImpeccableContext({
      schemaVersion: 1,
      sourceFingerprint,
      blocks,
      invocation: { skill: 'impeccable', capability: args.capability },
    }, authorityPolicy);
  } else {
    if (!args.eventJson || args.eventJson.length > MAX_CONTEXT_BYTES) fail('INVALID_ARGUMENTS', 'Live event JSON is missing or too large.');
    let event;
    try { event = JSON.parse(args.eventJson); } catch { fail('INVALID_LIVE_EVENT', 'Live event is not valid JSON.'); }
    envelope = mediator.mediateImpeccableLiveEvent({ schemaVersion: 1, sourceFingerprint, event }, authorityPolicy);
  }
  assertMediatedRequests(envelope, operationPolicy);
  return envelope;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname.replace(/^\/(.:)/, '$1'))) {
  runIntegratedImpeccableMediation(process.argv.slice(2))
    .then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 64;
    });
}
