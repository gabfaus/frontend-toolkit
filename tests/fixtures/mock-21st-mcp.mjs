import { createServer } from 'node:http';
import { once } from 'node:events';

export const SYNTHETIC_API_KEY = 'mh03b-synthetic-key';

function jsonResponse(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body)
  });
  response.end(body);
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

function searchTool() {
  return {
    name: 'search',
    description: 'Synthetic read-only search tool.',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string' } },
      required: ['query'],
      additionalProperties: false
    }
  };
}

function rpcResult(message, result) {
  return { jsonrpc: '2.0', id: message.id, result };
}

export async function startMock21stServer({
  mode = 'success',
  apiKey = SYNTHETIC_API_KEY
} = {}) {
  const requests = [];
  const server = createServer(async (request, response) => {
    requests.push({
      method: request.method,
      path: request.url,
      headers: { ...request.headers }
    });

    if (mode === 'redirect') {
      response.writeHead(302, { location: 'https://example.invalid/api/mcp' });
      response.end();
      return;
    }
    if (mode === 'timeout') return;
    if (mode === 'disconnect') {
      request.socket.destroy();
      return;
    }
    if (request.method !== 'POST' || request.url !== '/api/mcp') {
      jsonResponse(response, 404, { error: 'not found' });
      return;
    }
    if (request.headers['x-api-key'] !== apiKey) {
      jsonResponse(response, 401, { error: 'unauthorized' });
      return;
    }

    let message;
    try {
      message = JSON.parse(await readBody(request));
    } catch {
      jsonResponse(response, 400, { error: 'invalid json' });
      return;
    }

    if (mode === 'http-500') {
      jsonResponse(response, 500, { error: 'synthetic unavailable' });
      return;
    }
    if (mode === 'protocol-invalid') {
      jsonResponse(response, 200, { not: 'mcp' });
      return;
    }
    if (message.method === 'notifications/initialized') {
      response.writeHead(202);
      response.end();
      return;
    }
    if (message.method === 'initialize') {
      jsonResponse(response, 200, rpcResult(message, {
        protocolVersion: message.params?.protocolVersion ?? '2025-11-25',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'synthetic-21st', version: '1.0.0' }
      }));
      return;
    }
    if (message.method === 'tools/list') {
      const tools = mode === 'missing-search'
        ? [{ name: 'generate', inputSchema: { type: 'object' } }]
        : mode === 'extra-tool'
          ? [searchTool(), { name: 'generate', inputSchema: { type: 'object' } }]
          : [searchTool()];
      jsonResponse(response, 200, rpcResult(message, { tools }));
      return;
    }
    if (message.method === 'tools/call') {
      if (message.params?.name !== 'search') {
        jsonResponse(response, 200, rpcResult(message, {
          isError: true,
          content: [{ type: 'text', text: JSON.stringify({ error: 'tool denied' }) }]
        }));
        return;
      }
      if (mode === 'invalid-payload') {
        jsonResponse(response, 200, rpcResult(message, {
          structuredContent: { results: [{ unexpected: true }] }
        }));
        return;
      }
      if (mode === 'large-payload') {
        jsonResponse(response, 200, rpcResult(message, {
          structuredContent: { results: [{ title: 'x', description: 'x'.repeat(2 * 1024 * 1024) }] }
        }));
        return;
      }
      jsonResponse(response, 200, rpcResult(message, {
        structuredContent: {
          results: [{
            title: 'Synthetic Button',
            url: 'https://21st.dev/synthetic/button',
            description: 'Untrusted synthetic search data.'
          }],
          total: 1
        },
        content: [{ type: 'text', text: '{"results":[{"title":"Synthetic Button"}],"total":1}' }]
      }));
      return;
    }
    jsonResponse(response, 200, {
      jsonrpc: '2.0',
      id: message.id,
      error: { code: -32601, message: 'method not found' }
    });
  });

  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  return {
    port: address.port,
    requests,
    async close() {
      server.close();
      await once(server, 'close').catch(() => {});
    }
  };
}
