import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtimeRequire = createRequire(new URL('./runtime/package.json', import.meta.url));
const { Client, StreamableHTTPClientTransport } = runtimeRequire('@modelcontextprotocol/client');
const { McpServer } = runtimeRequire('@modelcontextprotocol/server');
const { StdioServerTransport } = runtimeRequire('@modelcontextprotocol/server/stdio');

const REMOTE_ENDPOINT = 'https://21st.dev/api/mcp';
const MAX_REMOTE_RESPONSE_BYTES = 1024 * 1024;
const MAX_RESULTS = 20;
const MAX_QUERY_LENGTH = 256;
const DEFAULT_TIMEOUT_MS = 20_000;
const SDK_RECONNECTION_OPTIONS = Object.freeze({
  maxReconnectionDelay: 1,
  initialReconnectionDelay: 1,
  reconnectionDelayGrowFactor: 1,
  maxRetries: 0
});

const ERROR_CODES = Object.freeze([
  'INVALID_INPUT',
  'AUTH_UNAVAILABLE',
  'REMOTE_UNAVAILABLE',
  'REMOTE_TIMEOUT',
  'REMOTE_PROTOCOL_MISMATCH',
  'REMOTE_TOOL_MISSING',
  'REMOTE_RESPONSE_INVALID',
  'POLICY_DENIED',
  'INTERNAL_ERROR'
]);

const LOCAL_INPUT_JSON_SCHEMA = Object.freeze({
  type: 'object',
  properties: {
    query: {
      type: 'string',
      minLength: 1,
      maxLength: MAX_QUERY_LENGTH,
      description: 'Search text. It is trimmed and rejects control characters.'
    }
  },
  required: ['query'],
  additionalProperties: false
});

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

function validateLocalInput(args) {
  if (!isRecord(args)) throw new FacadeError('INVALID_INPUT');

  const fields = Object.keys(args);
  if (fields.length !== 1 || fields[0] !== 'query' || typeof args.query !== 'string') {
    throw new FacadeError('INVALID_INPUT');
  }

  const query = args.query.trim();
  if (query.length < 1 || query.length > MAX_QUERY_LENGTH || /\p{Cc}/u.test(query)) {
    throw new FacadeError('INVALID_INPUT');
  }
  return query;
}

function createLocalInputSchema() {
  return {
    '~standard': {
      version: 1,
      vendor: 'frontend-toolkit',
      validate(value) {
        // The handler owns the stable error contract; this schema only prevents
        // the SDK from rewriting the caller's object before that validation.
        return { value };
      },
      jsonSchema: {
        input() {
          return LOCAL_INPUT_JSON_SCHEMA;
        },
        output() {
          return LOCAL_INPUT_JSON_SCHEMA;
        }
      }
    }
  };
}

function getInputUrl(input) {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.href;
  if (input && typeof input.url === 'string') return input.url;
  throw new FacadeError('POLICY_DENIED');
}

function assertFixedRemoteEndpoint(input) {
  const url = new URL(getInputUrl(input));
  if (url.protocol !== 'https:' || url.origin !== 'https://21st.dev' ||
      url.pathname !== '/api/mcp' || url.search !== '' || url.hash !== '') {
    throw new FacadeError('POLICY_DENIED');
  }
  return url;
}

function createBoundedFetch({ apiKey, fetchImplementation, timeoutMs }) {
  return async (input, init = {}) => {
    assertFixedRemoteEndpoint(input);

    const headers = new Headers(init.headers);
    if (headers.has('authorization') || headers.has('proxy-authorization') || headers.has('cookie')) {
      throw new FacadeError('POLICY_DENIED');
    }
    headers.set('x-api-key', apiKey);

    const timeoutController = new AbortController();
    let timedOut = false;
    let timer;
    const parentSignal = init.signal;
    const abortFromParent = () => timeoutController.abort(parentSignal.reason);
    if (parentSignal) {
      if (parentSignal.aborted) {
        abortFromParent();
      } else {
        parentSignal.addEventListener('abort', abortFromParent, { once: true });
      }
    }

    const clearBounds = () => {
      if (timer) clearTimeout(timer);
      if (parentSignal) parentSignal.removeEventListener('abort', abortFromParent);
    };

    timer = setTimeout(() => {
      timedOut = true;
      timeoutController.abort(new FacadeError('REMOTE_TIMEOUT'));
      timeoutReject(new FacadeError('REMOTE_TIMEOUT'));
    }, timeoutMs);

    let timeoutReject;
    const timeoutPromise = new Promise((_, reject) => {
      timeoutReject = reject;
    });
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
      if (!response.body) {
        clearBounds();
        return response;
      }

      const reader = response.body.getReader();
      let bytes = 0;
      const boundedBody = new ReadableStream({
        async pull(controller) {
          try {
            const { value, done } = await Promise.race([reader.read(), timeoutPromise]);
            if (done) {
              clearBounds();
              controller.close();
              return;
            }
            bytes += value.byteLength;
            if (bytes > MAX_REMOTE_RESPONSE_BYTES) {
              await reader.cancel();
              clearBounds();
              controller.error(new FacadeError('REMOTE_RESPONSE_INVALID'));
              return;
            }
            controller.enqueue(value);
          } catch (error) {
            clearBounds();
            controller.error(timedOut ? new FacadeError('REMOTE_TIMEOUT') : error);
          }
        },
        async cancel(reason) {
          clearBounds();
          await reader.cancel(reason);
        }
      });

      return new Response(boundedBody, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers
      });
    } catch (error) {
      clearBounds();
      if (timedOut || (error instanceof DOMException && error.name === 'TimeoutError')) {
        throw new FacadeError('REMOTE_TIMEOUT');
      }
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
  if (error?.code === 'REMOTE_RESPONSE_INVALID') {
    return new FacadeError('REMOTE_RESPONSE_INVALID');
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
  const searchTool = result.tools.find(tool => isRecord(tool) && tool.name === 'search');
  if (!searchTool) throw new FacadeError('REMOTE_TOOL_MISSING');
}

function parseStructuredSearchPayload(result) {
  if (!isRecord(result) || result.isError === true) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }

  if (isRecord(result.structuredContent)) return result.structuredContent;
  if (!Array.isArray(result.content) || result.content.length !== 1 ||
      !isRecord(result.content[0]) || result.content[0].type !== 'text' ||
      typeof result.content[0].text !== 'string') {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }

  try {
    const parsed = JSON.parse(result.content[0].text);
    if (!isRecord(parsed)) throw new Error('not an object');
    return parsed;
  } catch {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
}

function normalizeSearchResponse(result, query) {
  const payload = parseStructuredSearchPayload(result);
  const payloadKeys = Object.keys(payload);
  if (payloadKeys.some(key => !['results', 'total'].includes(key)) ||
      !Array.isArray(payload.results) || payload.results.length > MAX_RESULTS) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }

  const results = payload.results.map(item => {
    if (!isRecord(item)) throw new FacadeError('REMOTE_RESPONSE_INVALID');
    const itemKeys = Object.keys(item);
    if (itemKeys.some(key => !['title', 'url', 'description'].includes(key)) ||
        typeof item.title !== 'string' || item.title.trim().length < 1 || item.title.length > 512) {
      throw new FacadeError('REMOTE_RESPONSE_INVALID');
    }
    const normalized = { title: item.title };
    if (item.url !== undefined) {
      if (typeof item.url !== 'string' || item.url.length > 2048) {
        throw new FacadeError('REMOTE_RESPONSE_INVALID');
      }
      let url;
      try { url = new URL(item.url); } catch { throw new FacadeError('REMOTE_RESPONSE_INVALID'); }
      if (!['http:', 'https:'].includes(url.protocol)) {
        throw new FacadeError('REMOTE_RESPONSE_INVALID');
      }
      normalized.url = item.url;
    }
    if (item.description !== undefined) {
      if (typeof item.description !== 'string' || item.description.length > 4096) {
        throw new FacadeError('REMOTE_RESPONSE_INVALID');
      }
      normalized.description = item.description;
    }
    return normalized;
  });

  const normalized = {
    source: '21st',
    untrusted: true,
    query,
    results
  };
  if (payload.total !== undefined) {
    if (!Number.isSafeInteger(payload.total) || payload.total < 0) {
      throw new FacadeError('REMOTE_RESPONSE_INVALID');
    }
    normalized.total = payload.total;
  }
  if (JSON.stringify(normalized).length > MAX_REMOTE_RESPONSE_BYTES) {
    throw new FacadeError('REMOTE_RESPONSE_INVALID');
  }
  return normalized;
}

async function searchRemote({ apiKey, query, fetchImplementation, timeoutMs }) {
  const client = new Client({ name: 'frontend-toolkit-21st-facade', version: '1.0.0' });
  const transport = new StreamableHTTPClientTransport(new URL(REMOTE_ENDPOINT), {
    requestInit: { headers: { 'x-api-key': apiKey } },
    fetch: createBoundedFetch({ apiKey, fetchImplementation, timeoutMs }),
    reconnectionOptions: SDK_RECONNECTION_OPTIONS
  });

  try {
    // SDK v2's default negotiation is legacy. No wire-level initialize/session
    // implementation or 2026 revision pin is maintained by this facade.
    await client.connect(transport);
    const inventory = await client.listTools();
    validateRemoteToolInventory(inventory);
    const result = await client.callTool({ name: 'search', arguments: { query } });
    return normalizeSearchResponse(result, query);
  } catch (error) {
    throw classifyRemoteError(error);
  } finally {
    try { await client.close(); } catch { /* close never leaks details */ }
  }
}

export function createFacadeServer({
  getApiKey = () => process.env.API_KEY_21ST,
  fetchImplementation = globalThis.fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS
} = {}) {
  const server = new McpServer({ name: 'frontend-toolkit-21st-facade', version: '1.0.0' });
  server.registerTool('search', {
    title: 'Search 21st',
    description: 'Search the approved read-only 21st discovery surface.',
    inputSchema: createLocalInputSchema()
  }, async args => {
    try {
      const query = validateLocalInput(args);
      const apiKey = getApiKey();
      if (typeof apiKey !== 'string' || apiKey.length === 0 || apiKey.trim().length === 0) {
        throw new FacadeError('AUTH_UNAVAILABLE');
      }
      return successResult(await searchRemote({ apiKey, query, fetchImplementation, timeoutMs }));
    } catch (error) {
      const classified = error instanceof FacadeError ? error : classifyRemoteError(error);
      console.error('FTK 21st facade: ' + classified.code);
      return errorResult(ERROR_CODES.includes(classified.code) ? classified.code : 'INTERNAL_ERROR');
    }
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
    console.error('FTK 21st facade failed closed.');
    process.exitCode = 1;
  });
}
