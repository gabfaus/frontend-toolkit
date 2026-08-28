const endpoint = 'https://21st.dev/api/mcp';
const token = process.env.API_KEY_21ST;

if (!token) {
  throw new Error('CREDENTIAL_GATE: API_KEY_21ST is not available.');
}

const functional = process.argv.includes('--functional');
const protocolVersion = '2025-06-18';
const timeoutMs = 120_000;
let nextId = 1;
let sessionId;

function parseResponse(contentType, body) {
  if (!body.trim()) return undefined;
  if (contentType.includes('text/event-stream')) {
    const messages = body
      .split(/\r?\n\r?\n/)
      .flatMap((event) => {
        const data = event
          .split(/\r?\n/)
          .filter((line) => line.startsWith('data:'))
          .map((line) => line.slice(5).trim())
          .join('\n');
        if (!data) return [];
        return [JSON.parse(data)];
      });
    return messages.at(-1);
  }
  return JSON.parse(body);
}

async function send(message) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    'MCP-Protocol-Version': protocolVersion,
  };
  if (sessionId) headers['Mcp-Session-Id'] = sessionId;

  try {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify(message),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`MCP HTTP request failed with status ${response.status}.`);
    }
    sessionId ??= response.headers.get('mcp-session-id') ?? undefined;
    return parseResponse(response.headers.get('content-type') ?? '', await response.text());
  } finally {
    clearTimeout(timeout);
  }
}

async function request(method, params = {}) {
  const id = nextId++;
  const response = await send({ jsonrpc: '2.0', id, method, params });
  if (!response || response.id !== id) {
    throw new Error(`MCP ${method} returned no matching JSON-RPC response.`);
  }
  if (response.error) {
    throw new Error(`MCP ${method} failed with JSON-RPC code ${response.error.code}.`);
  }
  return response.result;
}

async function closeSession() {
  if (!sessionId) return 'stateless-no-session-id';
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const response = await fetch(endpoint, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
        'Mcp-Session-Id': sessionId,
        'MCP-Protocol-Version': protocolVersion,
      },
      signal: controller.signal,
    });
    if (![200, 202, 204, 404, 405].includes(response.status)) {
      throw new Error(`MCP session teardown failed with status ${response.status}.`);
    }
    return `http-${response.status}`;
  } finally {
    clearTimeout(timeout);
  }
}

let teardown = 'not-attempted';
try {
  const initialized = await request('initialize', {
    protocolVersion,
    capabilities: {},
    clientInfo: { name: 'frontend-toolkit-smoke', version: '1.0.0' },
  });
  await send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
  const listed = await request('tools/list');
  const tools = listed.tools ?? [];
  if (tools.length === 0) throw new Error('MCP tools/list returned no tools.');

  const result = {
    endpoint,
    protocolVersion: initialized.protocolVersion,
    serverInfo: initialized.serverInfo,
    tools: tools.map(({ name, description, inputSchema, annotations }) => ({
      name,
      description,
      inputSchema,
      annotations,
    })),
  };

  if (functional) {
    const search = tools.find((tool) => tool.name === 'search');
    if (!search) throw new Error('The observed tool inventory has no search tool.');
    const properties = search.inputSchema?.properties ?? {};
    const required = search.inputSchema?.required ?? [];
    if (!Object.hasOwn(properties, 'query') || required.some((name) => name !== 'query')) {
      throw new Error('The search schema is not the expected read-only query contract.');
    }
    const searchResult = await request('tools/call', {
      name: 'search',
      arguments: { query: 'dashboard' },
    });
    if (searchResult.isError) throw new Error('The read-only dashboard search returned isError.');
    const text = (searchResult.content ?? [])
      .filter((item) => item.type === 'text')
      .map((item) => item.text)
      .join('\n');
    if (!text.toLowerCase().includes('dashboard')) {
      throw new Error('The read-only search response did not contain dashboard results.');
    }
    result.functional = {
      tool: 'search',
      query: 'dashboard',
      outcome: 'results-returned',
    };
  }

  teardown = await closeSession();
  result.teardown = teardown;
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  if (teardown === 'not-attempted') {
    try {
      teardown = await closeSession();
    } catch {
      teardown = 'failed-after-primary-error';
    }
  }
  throw error;
}
