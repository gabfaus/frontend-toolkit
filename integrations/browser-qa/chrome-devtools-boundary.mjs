import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const policyPath = fileURLToPath(new URL('./chrome-devtools-policy.json', import.meta.url));
const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));

const toolAliases = new Map([
  ['list_pages', 'list_pages'],
  ['navigate_page', 'navigate_page'],
  ['take_screenshot', 'take_screenshot'],
  ['list_console_messages', 'list_console_messages'],
  ['list_network_requests', 'list_network_requests'],
]);

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 2;
}

function loopbackUrl(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error('URL must be an absolute HTTP loopback URL.');
  }
  if (parsed.protocol !== 'http:' || !['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname)) {
    throw new Error('Only HTTP loopback origins are allowed by the Chrome DevTools boundary.');
  }
  if (parsed.username || parsed.password) {
    throw new Error('Credentials in a URL are denied.');
  }
  return parsed.href;
}

function parseArgs(argv) {
  const result = { tool: null, url: null, config: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--config') {
      result.config = true;
    } else if (argument === '--tool') {
      result.tool = argv[++index];
    } else if (argument === '--url') {
      result.url = argv[++index];
    } else {
      throw new Error(`Unknown boundary argument: ${argument}`);
    }
  }
  if (result.config && (result.tool || result.url)) {
    throw new Error('--config cannot be combined with a tool or URL.');
  }
  return result;
}

try {
  const argumentsForBoundary = parseArgs(process.argv.slice(2));
  if (argumentsForBoundary.config || !argumentsForBoundary.tool) {
    process.stdout.write(JSON.stringify({
      status: 'PASS',
      executed: false,
      chromeStarted: false,
      mcpRegistered: false,
      policy,
    }, null, 2) + '\n');
  } else {
    if (!toolAliases.has(argumentsForBoundary.tool)) {
      throw new Error(`Tool is not allowlisted: ${argumentsForBoundary.tool}`);
    }
    if (argumentsForBoundary.url) {
      argumentsForBoundary.url = loopbackUrl(argumentsForBoundary.url);
    }
    process.stdout.write(JSON.stringify({
      status: 'PASS',
      executed: false,
      chromeStarted: false,
      mcpRegistered: false,
      tool: toolAliases.get(argumentsForBoundary.tool),
      url: argumentsForBoundary.url,
    }) + '\n');
  }
} catch (error) {
  fail(`CHROME_DEVTOOLS_BOUNDARY_BLOCKED: ${error.message}`);
}
