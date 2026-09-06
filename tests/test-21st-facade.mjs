import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const [, , nodePath, facadePath, preloadPath] = process.argv;
if (!nodePath || !facadePath || !preloadPath) {
  throw new Error('Expected governed Node, facade and preload paths.');
}

const runtimeRequire = createRequire(path.join(path.dirname(facadePath), 'runtime', 'package.json'));
const { Client, InMemoryTransport } = runtimeRequire('@modelcontextprotocol/client');
const { StdioClientTransport } = runtimeRequire('@modelcontextprotocol/client/stdio');
const { startMock21stServer, SYNTHETIC_API_KEY } = await import(
  pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'mock-21st-mcp.mjs')).href
);
const { createFacadeServer } = await import(pathToFileURL(facadePath).href);

function testEnvironment(extra = {}) {
  const environment = {};
  for (const name of ['SystemRoot', 'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH', 'ComSpec', 'PATHEXT']) {
    if (process.env[name] !== undefined) environment[name] = process.env[name];
  }
  return { ...environment, ...extra };
}

function withTimeout(promise, timeoutMs) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('test timeout')), timeoutMs))
  ]);
}

function extractError(call) {
  if (call?.result?.structuredContent?.error) return call.result.structuredContent.error;
  const text = call?.result?.content?.find(item => item.type === 'text')?.text;
  if (text) {
    try {
      const parsed = JSON.parse(text);
      if (parsed.error) return parsed.error;
    } catch {}
  }
  const message = String(call?.thrown ?? '');
  return [
    'INVALID_INPUT',
    'AUTH_UNAVAILABLE',
    'REMOTE_UNAVAILABLE',
    'REMOTE_TIMEOUT',
    'REMOTE_PROTOCOL_MISMATCH',
    'REMOTE_TOOL_MISSING',
    'REMOTE_RESPONSE_INVALID',
    'POLICY_DENIED',
    'INTERNAL_ERROR'
  ].find(code => message.includes(code)) ?? null;
}

async function runChild(mode, argumentsValue, {
  apiKey = SYNTHETIC_API_KEY,
  callName = 'search'
} = {}) {
  const mock = await startMock21stServer({ mode });
  const environment = testEnvironment({
    FTK_TEST_21ST_PORT: String(mock.port)
  });
  if (apiKey !== null) environment.API_KEY_21ST = apiKey;

  const transport = new StdioClientTransport({
    command: nodePath,
    args: ['--import', pathToFileURL(preloadPath).href, facadePath],
    env: environment,
    cwd: path.dirname(facadePath),
    stderr: 'pipe'
  });
  let stderr = '';
  transport.stderr?.on('data', chunk => { stderr += chunk.toString('utf8'); });
  const client = new Client({ name: 'mh03b-test-client', version: '1.0.0' });
  let tools;
  let call;
  try {
    await withTimeout(client.connect(transport), 5000);
    tools = await withTimeout(client.listTools(), 5000);
    try {
      call = { result: await withTimeout(client.callTool({ name: callName, arguments: argumentsValue }), 5000) };
    } catch (error) {
      call = { thrown: error?.message ?? String(error) };
    }
  } catch (error) {
    call = { thrown: error?.message ?? String(error) };
  } finally {
    await client.close().catch(() => {});
    await mock.close();
  }
  return {
    tools,
    toolNames: tools?.tools?.map(tool => tool.name) ?? [],
    call,
    error: extractError(call),
    requests: mock.requests,
    stderr
  };
}

async function runInProcess(fetchImplementation, timeoutMs) {
  const server = createFacadeServer({
    getApiKey: () => SYNTHETIC_API_KEY,
    fetchImplementation,
    timeoutMs
  });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'mh03b-in-process-client', version: '1.0.0' });
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  let call;
  try {
    call = { result: await withTimeout(client.callTool({ name: 'search', arguments: { query: 'timeout' } }), 2000) };
  } catch (error) {
    call = { thrown: error?.message ?? String(error) };
  } finally {
    await client.close().catch(() => {});
    await server.close().catch(() => {});
  }
  return { call, error: extractError(call) };
}

const valid = await runChild('success', { query: 'button' });
assert.deepEqual(valid.toolNames, ['search'], JSON.stringify({
  tools: valid.tools,
  call: valid.call,
  requests: valid.requests.map(request => ({ method: request.method, path: request.path })),
  stderr: valid.stderr
}));
assert.equal(valid.error, null, JSON.stringify({
  call: valid.call,
  requests: valid.requests.map(request => ({ method: request.method, path: request.path })),
  stderr: valid.stderr
}));
assert.equal(valid.call.result.structuredContent.source, '21st');
assert.equal(valid.call.result.structuredContent.untrusted, true);
assert.equal(valid.call.result.structuredContent.results.length, 1);
assert.equal(valid.call.result.structuredContent.total, 1);
assert(valid.requests.some(request => request.headers['x-api-key'] === SYNTHETIC_API_KEY));
assert(valid.requests.every(request => !request.headers.authorization));
assert(!valid.stderr.includes(SYNTHETIC_API_KEY));

const missingAuth = await runChild('success', { query: 'button' }, { apiKey: null });
assert.equal(missingAuth.error, 'AUTH_UNAVAILABLE');
assert.equal(missingAuth.requests.length, 0);

for (const invalid of [
  { query: '' },
  { query: ' '.repeat(4) },
  { query: 'x'.repeat(257) },
  { query: 'line\nbreak' },
  { query: 'nul\u0000byte' },
  { query: 'button', extra: true },
  { query: 'button', url: 'https://example.invalid' },
  { query: 'button', headers: { authorization: 'Bearer synthetic' } }
]) {
  const result = await runChild('success', invalid);
  assert.equal(result.error, 'INVALID_INPUT');
  assert.equal(result.requests.length, 0);
}

for (const name of ['generate', 'install', 'publish', 'delete', 'iterate']) {
  const result = await runChild('success', {}, { callName: name });
  assert(result.call.thrown || result.call.result?.isError);
  assert.equal(result.requests.length, 0);
}

const extraRemoteTool = await runChild('extra-tool', { query: 'button' });
assert.deepEqual(extraRemoteTool.toolNames, ['search']);
assert.equal(extraRemoteTool.error, null);

const missingRemoteTool = await runChild('missing-search', { query: 'button' });
assert.equal(missingRemoteTool.error, 'REMOTE_TOOL_MISSING');

const invalidPayload = await runChild('invalid-payload', { query: 'button' });
assert.equal(invalidPayload.error, 'REMOTE_RESPONSE_INVALID');

const largePayload = await runChild('large-payload', { query: 'button' });
assert.equal(largePayload.error, 'REMOTE_RESPONSE_INVALID');

const serverError = await runChild('http-500', { query: 'button' });
assert.equal(serverError.error, 'REMOTE_UNAVAILABLE');

const disconnected = await runChild('disconnect', { query: 'button' });
assert.equal(disconnected.error, 'REMOTE_UNAVAILABLE');

const protocolMismatch = await runChild('protocol-invalid', { query: 'button' });
assert(['REMOTE_PROTOCOL_MISMATCH', 'REMOTE_UNAVAILABLE', 'REMOTE_RESPONSE_INVALID'].includes(protocolMismatch.error));

const redirected = await runChild('redirect', { query: 'button' });
assert.notEqual(redirected.error, null);

const timeout = await runInProcess(() => new Promise(() => {}), 50);
assert.equal(timeout.error, 'REMOTE_TIMEOUT');

console.log('PASS: local MCP tools/list exposes exactly search.');
console.log('PASS: valid search uses x-api-key and normalizes untrusted results.');
console.log('PASS: local input validation rejects empty, controls, long, unknown and network fields.');
console.log('PASS: unknown local tools are not exposed or forwarded.');
console.log('PASS: remote inventory extras are not exposed; missing search fails closed.');
console.log('PASS: timeout, unavailable, protocol, invalid response, size and redirect cases fail closed.');
console.log('PASS: synthetic credential is absent from facade stderr; REAL MCP CALLS=0.');
