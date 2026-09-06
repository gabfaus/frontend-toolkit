import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtimeRequire = createRequire(new URL('./runtime/package.json', import.meta.url));
const { Client, StreamableHTTPClientTransport } = runtimeRequire('@modelcontextprotocol/client');
const { McpServer } = runtimeRequire('@modelcontextprotocol/server');
const { StdioServerTransport } = runtimeRequire('@modelcontextprotocol/server/stdio');

export const CONTEXT7_REMOTE_ENDPOINT = 'https://mcp.context7.com/mcp';
export const CONTEXT7_ALLOWED_TOOLS = Object.freeze(['resolve-library-id', 'query-docs']);

const UPSTREAM_PACKAGE = '@upstash/context7-mcp';
const UPSTREAM_VERSION = '4.0.5';
const MAX_REMOTE_RESPONSE_BYTES = 1024 * 1024;
const MAX_LIBRARY_NAME_LENGTH = 200;
const MAX_LIBRARY_ID_LENGTH = 256;
const MAX_QUERY_LENGTH = 512;
const MAX_TIMEOUT_MS = 20_000;
const DEFAULT_TIMEOUT_MS = 20_000;
const SDK_RECONNECTION_OPTIONS = Object.freeze({
  maxReconnectionDelay: 1,
  initialReconnectionDelay: 1,
  reconnectionDelayGrowFactor: 1,
  maxRetries: 0
});

const ERROR_CODES = Object.freeze([
  'INVALID_INPUT',
  'SENSITIVE_INPUT',
  'AUTH_UNAVAILABLE',
  'REMOTE_UNAVAILABLE',
  'REMOTE_TIMEOUT',
  'REMOTE_PROTOCOL_MISMATCH',
  'REMOTE_TOOL_MISSING',
  'REMOTE_RESPONSE_INVALID',
  'POLICY_DENIED',
  'AUTHORIZATION_REQUIRED',
  'INTERNAL_ERROR'
]);

const SENSITIVE_INPUT_PATTERNS = Object.freeze([
  /-----BEGIN [^-]+ PRIVATE KEY-----/iu,
  /\b(?:api[\s_-]*key|token|access[\s_-]*token|refresh[\s_-]*token|client[\s_-]*secret|password|passwd|secret|bearer|cookie|authorization)\b\s*[:=]/iu,
  /\b(?:sk|ghp|github_pat|xoxb|xoxp|npm)[_-][a-z0-9_-]{8,}\b/iu,
  /\b[\w.+-]+@[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+\b/iu,
  /\b\d{3}[.\s]?\d{3}[.\s]?\d{3}[-\s]?\d{2}\b/u
]);

class FacadeError extends Error {
  constructor(code) {
    super(code);
    this.name = 'FacadeError';
    this.code = code;
  }
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function errorResult(code) {
  return {
    isError: true,
    structuredContent: { error: code },
    content: [{ type: 'text', text: JSON.stringify({ error: code }) }]
  };
}

function successResult(value) {
  return {
    structuredContent: value,
    content: [{ type: 'text', text: JSON.stringify(value) }]
  };
}

function assertSafeText(value, maxLength) {
  if (typeof value !== 'string') throw new FacadeError('INVALID_INPUT');
  const text = value.trim();
  if (text.length < 1 || text.length > maxLength || /\p{Cc}/u.test(text)) {
    throw new FacadeError('INVALID_INPUT');
  }
  if (/```|=>|\b(?:const|let|var|class|import|export)\s+[A-Za-z_$]/u.test(text)) {
    throw new FacadeError('SENSITIVE_INPUT');
  }
  if (SENSITIVE_INPUT_PATTERNS.some(pattern => pattern.test(text))) {
    throw new FacadeError('SENSITIVE_INPUT');
  }
  return text;
}

function validateLibraryName(value) {
  const libraryName = assertSafeText(value, MAX_LIBRARY_NAME_LENGTH);
  if (/^[a-z][a-z0-9+.-]*:\/\//iu.test(libraryName) || libraryName.startsWith('//')) {
    throw new FacadeError('INVALID_INPUT');
  }
  return libraryName;
}

function validateLibraryId(value) {
  const libraryId = assertSafeText(value, MAX_LIBRARY_ID_LENGTH);
  // Context7 IDs are data identifiers, never URLs. Both @version and /vN
  // forms are accepted so a caller can keep a documentation pin explicit.
  const versionedId = /^\/[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._-]{1,120}(?:@[A-Za-z0-9][A-Za-z0-9._-]{0,63}|\/v?[0-9][A-Za-z0-9._-]{0,63})?$/u;
  if (!versionedId.test(libraryId)) throw new FacadeError('INVALID_INPUT');
  return libraryId;
}

function validateQuery(value) {
  return assertSafeText(value, MAX_QUERY_LENGTH);
}

function createInputSchema(toolName) {
  const properties = toolName === 'resolve-library-id'
    ? {
        libraryName: {
          type: 'string',
          minLength: 1,
          maxLength: MAX_LIBRARY_NAME_LENGTH,
          description: 'Specific library name only; do not include secrets, PII or source code.'
        }
      }
    : {
        libraryId: {
          type: 'string',
          minLength: 1,
          maxLength: MAX_LIBRARY_ID_LENGTH,
          description: 'Context7 library identifier, optionally pinned to a version.'
        },
        query: {
          type: 'string',
          minLength: 1,
          maxLength: MAX_QUERY_LENGTH,
          description: 'One specific documentation concept; do not include secrets, PII or source code.'
        }
      };
  const required = toolName === 'resolve-library-id' ? ['libraryName'] : ['libraryId', 'query'];
  const schema = Object.freeze({
    type: 'object',
    properties,
    required,
    additionalProperties: false
  });
  return {
    '~standard': {
      version: 1,
      vendor: 'frontend-toolkit',
      validate(value) {
        // The handler owns the stable error contract; preserve the caller's
        // object until the explicit boundary validation runs.
        return { value };
      },
      jsonSchema: {
        input() { return schema; },
        output() { return schema; }
      }
    }
  };
}

function validateLocalInput(toolName, args) {
  if (!isRecord(args)) throw new FacadeError('INVALID_INPUT');
  const keys = Object.keys(args).sort();
  if (toolName === 'resolve-library-id') {
    if (keys.length !== 1 || keys[0] !== 'libraryName') throw new FacadeError('INVALID_INPUT');
    return { libraryName: validateLibraryName(args.libraryName) };
  }
  if (keys.length !== 2 || keys[0] !== 'libraryId' || keys[1] !== 'query') {
    throw new FacadeError('INVALID_INPUT');
  }
  return {
    libraryId: validateLibraryId(args.libraryId),
    query: validateQuery(args.query)
  };
}

function getInputUrl(input) {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.href;
  if (input && typeof input.url === 'string') return input.url;
  throw new FacadeError('POLICY_DENIED');
}

function assertFixedRemoteEndpoint(input) {
  let url;
  try {
    url = new URL(getInputUrl(input));
  } catch {
    throw new FacadeError('POLICY_DENIED');
  }
  if (url.protocol !== 'https:' || url.origin !== 'https://mcp.context7.com' ||
      url.pathname !== '/mcp' || url.search !== '' || url.hash !== '') {
    throw new FacadeError('POLICY_DENIED');
  }
  return url;
}

function createBoundedFetch({ apiKey, fetchImplementation, timeoutMs }) {
  if (typeof fetchImplementation !== 'function') throw new FacadeError('REMOTE_UNAVAILABLE');
  const boundedTimeout = Number.isFinite(timeoutMs) && timeoutMs > 0
    ? Math.min(timeoutMs, MAX_TIMEOUT_MS)
    : DEFAULT_TIMEOUT_MS;

  return async (input, init = {}) => {
    assertFixedRemoteEndpoint(input);
    const headers = new Headers(init.headers);
    if (headers.has('authorization') || headers.has('proxy-authorization') || headers.has('cookie')) {
      throw new FacadeError('POLICY_DENIED');
    }
    if (typeof apiKey === 'string' && apiKey.trim().length > 0) {
      headers.set('x-api-key', apiKey);
    } else {
      headers.delete('x-api-key');
    }

    const timeoutController = new AbortController();
    let timedOut = false;
    let timer;
    const parentSignal = init.signal;
    const abortFromParent = () => timeoutController.abort(parentSignal.reason);
    if (parentSignal) {
      if (parentSignal.aborted) abortFromParent();
      else parentSignal.addEventListener('abort', abortFromParent, { once: true });
    }
    const clearBounds = () => {
      if (timer) clearTimeout(timer);
      if (parentSignal) parentSignal.removeEventListener('abort', abortFromParent);
    };

    let timeoutReject;
    const timeoutPromise = new Promise((_, reject) => { timeoutReject = reject; });
    timer = setTimeout(() => {
      timedOut = true;
      timeoutController.abort(new FacadeError('REMOTE_TIMEOUT'));
      timeoutReject(new FacadeError('REMOTE_TIMEOUT'));
    }, boundedTimeout);

    try {
      const response = await Promise.race([
        Promise.resolve().then(() => fetchImplementation(input, {
          ...init,
          headers,
          redirect: 'error',
          signal: timeoutController.signal
        })),
        timeoutPromise
      ]);
      const contentLength = response.headers.get('content-length');
      if (contentLength !== null && Number(contentLength) > MAX_REMOTE_RESPONSE_BYTES) {
        throw new FacadeError('REMOTE_RESPONSE_INVALID');
      }
      const bytes = new Uint8Array(await Promise.race([response.arrayBuffer(), timeoutPromise]));
      if (bytes.byteLength > MAX_REMOTE_RESPONSE_BYTES) {
        throw new FacadeError('REMOTE_RESPONSE_INVALID');
      }
      clearBounds();
      return new Response(bytes, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers
      });
    } catch (error) {
      clearBounds();
      if (timedOut || error?.name === 'AbortError') throw new FacadeError('REMOTE_TIMEOUT');
      throw error;
    }
  };
}

function classifyRemoteError(error) {
  if (error instanceof FacadeError) return error;
  if (error?.name === 'AbortError' || error?.code === 'UND_ERR_CONNECT_TIMEOUT') {
    return new FacadeError('REMOTE_TIMEOUT');
  }
  if (error?.name === 'SdkHttpError') {
    const status = Number(error.status ?? error.statusCode);
    if (status === 401 || status === 403) return new FacadeError('AUTH_UNAVAILABLE');
    if (status >= 500) return new FacadeError('REMOTE_UNAVAILABLE');
    return new FacadeError('REMOTE_PROTOCOL_MISMATCH');
  }
  if (error?.name === 'TypeError' || error?.name === 'SseError') {
    return new FacadeError('REMOTE_UNAVAILABLE');
  }
  return new FacadeError('REMOTE_PROTOCOL_MISMATCH');
}

function validateRemoteToolInventory(result) {
  if (!isRecord(result) || !Array.isArray(result.tools)) {
    throw new FacadeError('REMOTE_PROTOCOL_MISMATCH');
  }
  for (const name of CONTEXT7_ALLOWED_TOOLS) {
    if (!result.tools.some(tool => isRecord(tool) && tool.name === name)) {
      throw new FacadeError('REMOTE_TOOL_MISSING');
    }
  }
}

function boundedData(value, depth = 0) {
  if (depth > 8) throw new FacadeError('REMOTE_RESPONSE_INVALID');
  if (value === null || typeof value === 'boolean' || typeof value === 'number') return value;
  if (typeof value === 'string') {
    if (value.length > 32 * 1024) throw new FacadeError('REMOTE_RESPONSE_INVALID');
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length > 100) throw new FacadeError('REMOTE_RESPONSE_INVALID');
    return value.map(item => boundedData(item, depth + 1));
  }
  if (!isRecord(value)) throw new FacadeError('REMOTE_RESPONSE_INVALID');
  const keys = Object.keys(value);
  if (keys.length > 100 || keys.some(key => key.length > 128)) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
  return Object.fromEntries(keys.map(key => [key, boundedData(value[key], depth + 1)]));
}

function parseRemotePayload(result) {
  if (!isRecord(result) || result.isError === true) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
  if (result.structuredContent !== undefined) return boundedData(result.structuredContent);
  if (!Array.isArray(result.content) || result.content.length < 1 || result.content.length > 100) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
  const content = result.content.map(item => {
    if (!isRecord(item) || item.type !== 'text' || typeof item.text !== 'string') {
      throw new FacadeError('REMOTE_RESPONSE_INVALID');
    }
    return { type: 'text', text: item.text };
  });
  return boundedData({ content });
}

function normalizeRemoteResponse(result, operation, request) {
  const data = parseRemotePayload(result);
  const normalized = {
    source: 'context7',
    untrusted: true,
    operation,
    request,
    provenance: {
      provider: 'Context7',
      package: UPSTREAM_PACKAGE,
      version: UPSTREAM_VERSION,
      endpoint: CONTEXT7_REMOTE_ENDPOINT,
      remoteTool: operation
    },
    data
  };
  if (Buffer.byteLength(JSON.stringify(normalized), 'utf8') > MAX_REMOTE_RESPONSE_BYTES) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
  return normalized;
}

async function callRemote({ operation, request, apiKey, fetchImplementation, timeoutMs }) {
  const client = new Client({ name: 'frontend-toolkit-context7-facade', version: '1.0.0' });
  const headers = typeof apiKey === 'string' && apiKey.trim().length > 0
    ? { 'x-api-key': apiKey }
    : {};
  const transport = new StreamableHTTPClientTransport(new URL(CONTEXT7_REMOTE_ENDPOINT), {
    requestInit: { headers },
    fetch: createBoundedFetch({ apiKey, fetchImplementation, timeoutMs }),
    reconnectionOptions: SDK_RECONNECTION_OPTIONS
  });
  try {
    await client.connect(transport);
    const inventory = await client.listTools();
    validateRemoteToolInventory(inventory);
    const result = await client.callTool({ name: operation, arguments: request });
    return normalizeRemoteResponse(result, operation, request);
  } catch (error) {
    throw classifyRemoteError(error);
  } finally {
    try { await client.close(); } catch { /* close never leaks details */ }
  }
}

function registerTool(server, name, inputSchema, handler) {
  server.registerTool(name, {
    title: `Context7 ${name}`,
    description: `Conditional read-only Context7 ${name} through the FTK facade.`,
    inputSchema
  }, async args => {
    try {
      return successResult(await handler(args));
    } catch (error) {
      const classified = error instanceof FacadeError ? error : classifyRemoteError(error);
      console.error(`FTK Context7 facade: ${classified.code}`);
      return errorResult(ERROR_CODES.includes(classified.code) ? classified.code : 'INTERNAL_ERROR');
    }
  });
}

export function createFacadeServer({
  getApiKey = () => process.env.CONTEXT7_API_KEY,
  fetchImplementation = globalThis.fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS
} = {}) {
  const server = new McpServer({ name: 'frontend-toolkit-context7-facade', version: '1.0.0' });
  registerTool(server, 'resolve-library-id', createInputSchema('resolve-library-id'), async args => {
    const request = validateLocalInput('resolve-library-id', args);
    return callRemote({
      operation: 'resolve-library-id',
      request,
      apiKey: getApiKey(),
      fetchImplementation,
      timeoutMs
    });
  });
  registerTool(server, 'query-docs', createInputSchema('query-docs'), async args => {
    const request = validateLocalInput('query-docs', args);
    return callRemote({
      operation: 'query-docs',
      request,
      apiKey: getApiKey(),
      fetchImplementation,
      timeoutMs
    });
  });
  return server;
}

export async function main() {
  const server = createFacadeServer();
  await server.connect(new StdioServerTransport());
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : '';
if (invokedPath === import.meta.url) {
  main().catch(() => {
    console.error('FTK Context7 facade failed closed.');
    process.exitCode = 1;
  });
}
