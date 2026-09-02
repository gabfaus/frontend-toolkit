#!/usr/bin/env node

const ENDPOINTS = Object.freeze({
  'impeccable.update-check': Object.freeze({ method: 'GET', origin: 'https://impeccable.style', path: '/api/version' }),
  'impeccable.concept.remote-roll': Object.freeze({ method: 'GET', origin: 'https://impeccable.style', path: '/api/roll' }),
  'impeccable.concept.card-fetch': Object.freeze({ method: 'GET', origin: 'https://impeccable.style', pathPrefix: '/worlds/cards/' }),
  'impeccable.telemetry.choice': Object.freeze({ method: 'POST', origin: 'https://impeccable.style', path: '/api/chosen' }),
  'impeccable.paid-generation.upstream': Object.freeze({ method: 'POST', origin: 'https://api.openai.com', paths: ['/v1/images/generations', '/v1/images/edits'] }),
});

const INPUT_KEYS = Object.freeze({
  'impeccable.update-check': [],
  'impeccable.concept.remote-roll': ['scope', 'key', 'mode', 'grain', 'platform', 'reroll', 'candidateCount'],
  'impeccable.concept.card-fetch': ['cardAsset'],
  'impeccable.telemetry.choice': ['chosenId', 'key', 'scope', 'mode', 'kind', 'register'],
  'impeccable.paid-generation.upstream': ['variant'],
});

function fail(message) {
  throw new Error(`IMPECCABLE_NETWORK_BLOCKED: ${message}`);
}

function assertPlainObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) {
    fail(`${label} must be a plain object`);
  }
}

function assertExactKeys(operation, input) {
  assertPlainObject(input, 'input');
  const allowed = INPUT_KEYS[operation];
  if (!allowed) fail(`unknown operation ${operation}`);
  const unexpected = Object.keys(input).filter((key) => !allowed.includes(key));
  if (unexpected.length) fail(`unregistered input keys: ${unexpected.sort().join(', ')}`);
}

function optionalToken(value, name, pattern, maxLength = 128) {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value !== 'string' || value.length > maxLength || !pattern.test(value)) fail(`invalid ${name}`);
  return value;
}

function requiredToken(value, name, pattern, maxLength = 128) {
  const token = optionalToken(value, name, pattern, maxLength);
  if (token === undefined) fail(`missing ${name}`);
  return token;
}

function boundedInteger(value, name, minimum, maximum, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  if (!Number.isInteger(value) || value < minimum || value > maximum) fail(`invalid ${name}`);
  return value;
}

function assertEndpoint(operation, url, method) {
  const definition = ENDPOINTS[operation];
  if (!definition) fail(`unknown operation ${operation}`);
  const parsed = new URL(url);
  if (parsed.origin !== definition.origin || method !== definition.method) fail(`unknown host or method for ${operation}`);
  if (definition.path && parsed.pathname !== definition.path) fail(`unknown endpoint for ${operation}`);
  if (definition.pathPrefix && !parsed.pathname.startsWith(definition.pathPrefix)) fail(`unknown endpoint for ${operation}`);
  if (definition.paths && !definition.paths.includes(parsed.pathname)) fail(`unknown endpoint for ${operation}`);
  if (parsed.username || parsed.password || parsed.hash) fail('URL credentials and fragments are denied');
}

export function buildRequest(operation, input = {}) {
  assertExactKeys(operation, input);
  let url;
  let options;

  if (operation === 'impeccable.update-check') {
    url = new URL('/api/version', ENDPOINTS[operation].origin);
    options = { method: 'GET', redirect: 'manual' };
  } else if (operation === 'impeccable.concept.remote-roll') {
    const scope = requiredToken(input.scope, 'scope', /^[a-z][a-z0-9-]{0,63}$/);
    const key = requiredToken(input.key, 'key', /^[A-Za-z0-9._:-]{1,128}$/);
    const mode = optionalToken(input.mode, 'mode', /^[a-z][a-z0-9-]{0,63}$/);
    const grain = optionalToken(input.grain, 'grain', /^[a-z][a-z0-9-]{0,63}$/);
    const platform = optionalToken(input.platform, 'platform', /^[a-z][a-z0-9-]{0,63}$/);
    const reroll = boundedInteger(input.reroll, 'reroll', 0, 100, 0);
    const candidateCount = boundedInteger(input.candidateCount, 'candidateCount', 1, 20, 7);
    url = new URL('/api/roll', ENDPOINTS[operation].origin);
    url.searchParams.set('scope', scope);
    url.searchParams.set('key', key);
    url.searchParams.set('reroll', String(reroll));
    url.searchParams.set('candidateCount', String(candidateCount));
    if (mode) url.searchParams.set('mode', mode);
    if (grain) url.searchParams.set('grain', grain);
    if (platform) url.searchParams.set('platform', platform);
    options = { method: 'GET', redirect: 'manual' };
  } else if (operation === 'impeccable.concept.card-fetch') {
    const cardAsset = requiredToken(input.cardAsset, 'cardAsset', /^[a-z0-9][a-z0-9-]{0,63}(?:-hero)?\.webp$/);
    url = new URL(`/worlds/cards/${cardAsset}`, ENDPOINTS[operation].origin);
    options = { method: 'GET', redirect: 'manual' };
  } else if (operation === 'impeccable.telemetry.choice') {
    const kind = optionalToken(input.kind, 'kind', /^(?:assigned|pick|challenger|canon)$/);
    const chosenId = optionalToken(input.chosenId, 'chosenId', /^[a-z0-9][a-z0-9-]{0,63}$/);
    if (!kind && !chosenId) fail('telemetry requires kind or chosenId');
    if ((!kind || kind === 'challenger') && !chosenId) fail('challenger telemetry requires chosenId');
    const body = {
      ...(chosenId ? { chosenId } : {}),
      key: optionalToken(input.key, 'key', /^[A-Za-z0-9._:-]{1,128}$/),
      scope: optionalToken(input.scope, 'scope', /^[a-z][a-z0-9-]{0,63}$/),
      mode: optionalToken(input.mode, 'mode', /^[a-z][a-z0-9-]{0,63}$/),
      ...(kind ? { kind } : {}),
      ...(input.register ? { register: requiredToken(input.register, 'register', /^(?:safer|bolder)$/) } : {}),
    };
    for (const key of Object.keys(body)) if (body[key] === undefined) delete body[key];
    url = new URL('/api/chosen', ENDPOINTS[operation].origin);
    options = { method: 'POST', redirect: 'manual', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
  } else if (operation === 'impeccable.paid-generation.upstream') {
    const variant = requiredToken(input.variant, 'variant', /^(?:generations|edits)$/);
    url = new URL(`/v1/images/${variant}`, ENDPOINTS[operation].origin);
    options = { method: 'POST', redirect: 'manual' };
  } else {
    fail(`unknown operation ${operation}`);
  }

  assertEndpoint(operation, url.href, options.method);
  return Object.freeze({ operation, url: url.href, options: Object.freeze(options) });
}

async function readJson(response, maximumBytes = 1024 * 1024) {
  const text = await response.text();
  if (Buffer.byteLength(text, 'utf8') > maximumBytes) fail('response exceeds boundary');
  try {
    return JSON.parse(text);
  } catch {
    fail('response is not valid JSON');
  }
}

function assertSuccess(response) {
  if (!response || typeof response.status !== 'number') fail('transport returned an invalid response');
  if (response.status >= 300 && response.status < 400) fail('redirects are denied');
  if (response.status < 200 || response.status >= 300) fail(`endpoint returned status ${response.status}`);
}

export async function executeNetworkOperation(operation, input = {}, { transport = globalThis.fetch } = {}) {
  if (operation === 'impeccable.paid-generation.upstream') {
    fail('paid generation requires the dedicated host-authorized upstream child; this client never accepts or injects OPENAI_API_KEY');
  }
  if (typeof transport !== 'function') fail('transport is unavailable');
  const request = buildRequest(operation, input);
  const response = await transport(request.url, request.options);
  assertSuccess(response);

  if (operation === 'impeccable.concept.card-fetch') {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength === 0 || bytes.byteLength > 8 * 1024 * 1024) fail('card asset size is outside boundary');
    return Object.freeze({ operation, mediaType: 'image/webp', byteLength: bytes.byteLength, bytes });
  }

  const value = await readJson(response);
  if (operation === 'impeccable.update-check') {
    const latestVersion = optionalToken(value?.latestVersion ?? value?.version ?? value?.latest, 'latestVersion', /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/);
    if (!latestVersion) fail('version response lacks typed version data');
    return Object.freeze({ operation, latestVersion, updatePerformed: false, cacheWritten: false });
  }
  if (operation === 'impeccable.concept.remote-roll') {
    if (!Array.isArray(value?.challengers) || value.challengers.length === 0 || value.challengers.length > 20) fail('roll response lacks bounded challengers');
    return Object.freeze({ operation, source: 'remote', challengers: value.challengers, telemetrySent: false });
  }
  return Object.freeze({ operation, accepted: true });
}

export function endpointInventory() {
  return ENDPOINTS;
}

if (process.argv[1] && new URL(import.meta.url).pathname.replace(/^\/(.:)/, '$1') === process.argv[1].replaceAll('\\', '/')) {
  process.stderr.write('Direct CLI network execution is denied; use the host-mediated runner integration.\n');
  process.exitCode = 64;
}
