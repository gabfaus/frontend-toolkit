import { spawn, spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline';

const npxCliPath = process.env.FTK_NPX_CLI_PATH;
if (!npxCliPath) throw new Error('FTK_NPX_CLI_PATH is required.');
const runFunctional = process.argv.includes('--functional');

const server = spawn(process.execPath, [npxCliPath, '--yes', 'shadcn@4.19.0', 'mcp'], {
  cwd: process.cwd(),
  env: process.env,
  stdio: ['pipe', 'pipe', 'pipe'],
});

function stopServer() {
  if (!server.pid) return;
  if (process.platform === 'win32') {
    spawnSync('taskkill.exe', ['/PID', String(server.pid), '/T', '/F'], { stdio: 'ignore' });
  } else {
    server.kill('SIGTERM');
  }
}

let nextId = 1;
let stderr = '';
const pending = new Map();
const lines = createInterface({ input: server.stdout, crlfDelay: Infinity });

server.stderr.setEncoding('utf8');
server.stderr.on('data', (chunk) => { stderr += chunk; });
lines.on('line', (line) => {
  if (!line.trim()) return;
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id !== undefined && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  }
});

function send(message) {
  server.stdin.write(`${JSON.stringify(message)}\n`);
}

function request(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ jsonrpc: '2.0', id, method, params });
  });
}

const timeout = setTimeout(() => {
  const error = new Error(`MCP smoke timeout. stderr=${stderr.slice(0, 500)}`);
  for (const { reject } of pending.values()) reject(error);
  pending.clear();
  stopServer();
}, 120_000);

try {
  const initialized = await request('initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'frontend-toolkit-smoke', version: '1.0.0' },
  });
  send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
  const listed = await request('tools/list');
  const tools = listed.tools ?? [];
  if (tools.length === 0) throw new Error('MCP tools/list returned no tools.');

  const summary = {
    protocolVersion: initialized.protocolVersion,
    serverInfo: initialized.serverInfo,
    tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
  };
  if (runFunctional) {
    const search = await request('tools/call', {
      name: 'search_items_in_registries',
      arguments: { registries: ['@shadcn'], query: 'button', limit: 5 },
    });
    const view = await request('tools/call', {
      name: 'view_items_in_registries',
      arguments: { items: ['@shadcn/button'] },
    });
    const textOf = (result) => (result.content ?? [])
      .filter((item) => item.type === 'text')
      .map((item) => item.text)
      .join('\n');
    const searchText = textOf(search);
    const viewText = textOf(view);
    if (search.isError || !searchText.toLowerCase().includes('button')) {
      throw new Error(`Read-only search failed: ${searchText.slice(0, 500)}`);
    }
    if (view.isError || !viewText.toLowerCase().includes('button')) {
      throw new Error(`Read-only view failed: ${viewText.slice(0, 500)}`);
    }
    summary.functional = {
      search: 'button found in @shadcn',
      view: '@shadcn/button returned component information',
    };
  }
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
} finally {
  clearTimeout(timeout);
  lines.close();
  server.stdin.end();
  stopServer();
}
