import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const testRoot = path.dirname(fileURLToPath(import.meta.url));
const facadePath = path.join(testRoot, '..', 'claude', 'facade', 'context7-facade.mjs');
const policyPath = path.join(testRoot, '..', 'plugin', 'frontend-toolkit', 'security', 'context7-operation-policy.json');
const lockPath = path.join(testRoot, '..', 'integrations', 'context7.lock.json');
const runtimeRequire = createRequire(path.join(path.dirname(facadePath), 'runtime', 'package.json'));
const { Client, InMemoryTransport } = runtimeRequire('@modelcontextprotocol/client');
const { createFacadeServer, CONTEXT7_REMOTE_ENDPOINT } = await import(pathToFileURL(facadePath).href);

const SYNTHETIC_API_KEY = 'synthetic-context7-key';

function responseFor(message, result, status = 200, extraHeaders = {}) {
  const body = JSON.stringify({ jsonrpc: '2.0', id: message.id, result });
  return new Response(body, {
    status,
    headers: {
      'content-type': 'application/json',
      'content-length': String(Buffer.byteLength(body)),
      ...extraHeaders
    }
  });
}

function createMockFetch({ mode = 'success' } = {}) {
  const calls = [];
  const fetchImplementation = async (input, init = {}) => {
    calls.push({
      url: String(input),
      method: init.method ?? input.method,
      headers: Object.fromEntries(new Headers(init.headers).entries()),
      body: init.body
    });
    const message = JSON.parse(init.body);
    if (message.method === 'notifications/initialized') return new Response(null, { status: 202 });
    if (message.method === 'initialize') {
      return responseFor(message, {
        protocolVersion: message.params?.protocolVersion ?? '2025-11-25',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'synthetic-context7', version: '4.0.5' }
      });
    }
    if (message.method === 'tools/list') {
      const tools = [
        { name: 'resolve-library-id', inputSchema: { type: 'object' } },
        { name: 'query-docs', inputSchema: { type: 'object' } }
      ];
      if (mode === 'extra-tools') {
        tools.push({ name: 'refresh', inputSchema: { type: 'object' } }, { name: 'add-source', inputSchema: { type: 'object' } }, { name: 'future-tool', inputSchema: { type: 'object' } });
      }
      if (mode === 'missing-query') tools.splice(1, 1);
      return responseFor(message, { tools });
    }
    if (message.method === 'tools/call') {
      if (mode === 'large-response') {
        const body = JSON.stringify({
          data: { snippets: [{ content: 'x'.repeat(2 * 1024 * 1024) }] }
        });
        return new Response(body, {
          status: 200,
          headers: {
            'content-type': 'application/json',
            'content-length': String(Buffer.byteLength(body))
          }
        });
      }
      if (message.params?.name === 'resolve-library-id') {
        return responseFor(message, {
          structuredContent: {
            libraries: [{
              libraryId: message.params.arguments.libraryName === 'react'
                ? '/facebook/react@18.3.1'
                : '/synthetic/library',
              title: 'Synthetic React documentation',
              source: 'https://context7.com/synthetic/react'
            }]
          }
        });
      }
      if (message.params?.name === 'query-docs') {
        return responseFor(message, {
          structuredContent: {
            snippets: [{
              title: 'Synthetic useEffect documentation',
              content: 'Untrusted synthetic documentation data.',
              url: 'https://context7.com/synthetic/react/use-effect'
            }],
            total: 1
          }
        });
      }
      return responseFor(message, {
        isError: true,
        content: [{ type: 'text', text: JSON.stringify({ error: 'tool denied' }) }]
      });
    }
    return responseFor(message, {}, 400);
  };
  return { fetchImplementation, calls };
}

function errorCode(call) {
  if (call?.result?.structuredContent?.error) return call.result.structuredContent.error;
  const text = call?.result?.content?.find(item => item.type === 'text')?.text;
  if (text) {
    try { return JSON.parse(text).error ?? null; } catch { return null; }
  }
  return null;
}

async function run({ mode = 'success', apiKey = SYNTHETIC_API_KEY } = {}) {
  const mock = createMockFetch({ mode });
  const server = (await import(pathToFileURL(facadePath).href)).createFacadeServer({
    getApiKey: () => apiKey,
    fetchImplementation: mock.fetchImplementation,
    timeoutMs: 100
  });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'synthetic-context7-test-client', version: '1.0.0' });
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  const tools = await client.listTools();
  const calls = [];
  try {
    calls.push({ name: 'resolve-library-id', result: await client.callTool({
      name: 'resolve-library-id',
      arguments: { libraryName: 'react' }
    }) });
    calls.push({ name: 'query-docs', result: await client.callTool({
      name: 'query-docs',
      arguments: { libraryId: '/facebook/react@18.3.1', query: 'useEffect cleanup' }
    }) });
  } finally {
    await client.close().catch(() => {});
    await server.close().catch(() => {});
  }
  return { tools, calls, mockCalls: mock.calls };
}

const policy = JSON.parse(readFileSync(policyPath, 'utf8'));
const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
assert.equal(policy.status, 'conditional');
assert.deepEqual(policy.exposedTools.map(tool => tool.name), ['resolve-library-id', 'query-docs']);
assert.equal(policy.unknownToolPolicy, 'deny');
assert.equal(policy.mutationPolicy, 'deny');
assert.equal(policy.transport.credentialEnvVar, 'CONTEXT7_API_KEY');
assert.equal(lock.version, '4.0.5');
assert.equal(lock.license, 'MIT');
assert.equal(lock.directMcpExposure, 'rejected');
assert.equal(lock.credentialValuesInRepository, false);

const success = await run({ mode: 'extra-tools' });
assert.deepEqual(success.tools.tools.map(tool => tool.name), ['resolve-library-id', 'query-docs']);
assert.equal(success.calls[0].result.structuredContent.source, 'context7');
assert.equal(success.calls[0].result.structuredContent.provenance.remoteTool, 'resolve-library-id');
assert.equal(success.calls[0].result.structuredContent.provenance.version, '4.0.5');
assert.equal(success.calls[1].result.structuredContent.request.libraryId, '/facebook/react@18.3.1');
assert.equal(success.calls[1].result.structuredContent.untrusted, true);
assert(success.mockCalls.length >= 6); // initialize/list/call for each approved operation
assert(success.mockCalls.every(call => call.url === CONTEXT7_REMOTE_ENDPOINT));
assert(success.mockCalls.some(call => typeof call.body === 'string'));
assert(success.mockCalls.every(call => call.headers['x-api-key'] === SYNTHETIC_API_KEY));
assert(!JSON.stringify(success).includes('refresh'));
assert(!JSON.stringify(success).includes('add-source'));

const missingQuery = await run({ mode: 'missing-query' });
assert.equal(errorCode(missingQuery.calls[0]), 'REMOTE_TOOL_MISSING');
assert.equal(errorCode(missingQuery.calls[1]), 'REMOTE_TOOL_MISSING');

const invalidCases = [
  ['resolve-library-id', { libraryName: '' }, 'INVALID_INPUT'],
  ['resolve-library-id', { libraryName: 'https://private.example/docs' }, 'INVALID_INPUT'],
  ['query-docs', { libraryId: 'https://context7.com/react', query: 'hooks' }, 'INVALID_INPUT'],
  ['query-docs', { libraryId: '/facebook/react', query: 'token: secret-value' }, 'SENSITIVE_INPUT'],
  ['query-docs', { libraryId: '/facebook/react', query: '```console.log(1)```' }, 'SENSITIVE_INPUT'],
  ['query-docs', { libraryId: '/facebook/react', query: 'x'.repeat(513) }, 'INVALID_INPUT'],
  ['query-docs', { libraryId: '/facebook/react', query: 'user@example.com docs' }, 'SENSITIVE_INPUT'],
  ['query-docs', { libraryId: '/facebook/react', query: 'hooks', extra: true }, 'INVALID_INPUT']
];
for (const [name, argumentsValue, expected] of invalidCases) {
  const mock = createMockFetch();
  const server = (await import(pathToFileURL(facadePath).href)).createFacadeServer({
    getApiKey: () => SYNTHETIC_API_KEY,
    fetchImplementation: mock.fetchImplementation
  });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'synthetic-invalid-input-client', version: '1.0.0' });
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  const result = await client.callTool({ name, arguments: argumentsValue });
  assert.equal(errorCode({ result }), expected, `${name} did not fail with ${expected}`);
  assert.equal(mock.calls.length, 0);
  await client.close().catch(() => {});
  await server.close().catch(() => {});
}

const unknownMock = createMockFetch();
const unknownServer = (await import(pathToFileURL(facadePath).href)).createFacadeServer({
  getApiKey: () => SYNTHETIC_API_KEY,
  fetchImplementation: unknownMock.fetchImplementation
});
const [unknownClientTransport, unknownServerTransport] = InMemoryTransport.createLinkedPair();
const unknownClient = new Client({ name: 'synthetic-unknown-tool-client', version: '1.0.0' });
await unknownServer.connect(unknownServerTransport);
await unknownClient.connect(unknownClientTransport);
for (const name of ['refresh', 'add-source', 'update-policy']) {
  const result = await unknownClient.callTool({ name, arguments: {} }).catch(error => ({ thrown: error }));
  assert(result.thrown || result.isError || result.result?.isError);
}
await unknownClient.close().catch(() => {});
await unknownServer.close().catch(() => {});
assert.equal(unknownMock.calls.length, 0);

const large = await run({ mode: 'large-response' });
assert.equal(errorCode(large.calls[0]), 'REMOTE_RESPONSE_INVALID');
assert.equal(errorCode(large.calls[1]), 'REMOTE_RESPONSE_INVALID');

const noCredential = await run({ apiKey: null });
assert(noCredential.mockCalls.every(call => !('x-api-key' in call.headers)));
assert(!JSON.stringify(noCredential).includes(SYNTHETIC_API_KEY));

console.log('PASS: Context7 facade exposes exactly resolve-library-id and query-docs.');
console.log('PASS: unknown, mutation-like and future tools remain fail-closed.');
console.log('PASS: input, secret/PII/code-block, query and response limits are enforced.');
console.log('PASS: versioned library IDs, untrusted response data and provenance are preserved.');
console.log('CONTEXT7 NETWORK CALLS=0; CONTEXT7 MOCK REQUESTS ONLY; CREDENTIAL VALUES PERSISTED=0');
