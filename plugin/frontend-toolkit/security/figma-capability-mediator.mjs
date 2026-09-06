import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const policyPath = resolve(dirname(fileURLToPath(import.meta.url)), 'figma-operation-policy.json');
const policy = JSON.parse(readFileSync(policyPath, 'utf8'));

const readTools = new Set(policy.capabilities.FIGMA_READ.tools);
const writeTools = new Set(policy.capabilities.FIGMA_WRITE.tools);
const manualTools = new Set(Object.keys(policy.manualOperations));
const serverIds = new Set(Object.values(policy.transports).map(transport => transport.id));

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function deny(code, extra = {}) {
  return {
    decision: code,
    allowed: false,
    executed: false,
    handler: 'none',
    ...extra
  };
}

export function getFigmaPolicy() {
  return policy;
}

export function resolveServerSelection(selection) {
  if (selection === undefined) {
    return {
      serverId: policy.serverSelection.defaultServerId,
      defaulted: true
    };
  }

  if (!Array.isArray(selection) || selection.length !== 1) {
    return deny('DENY_SERVER_SELECTION', {
      reason: 'exactly one Figma transport must be active',
      activeServerIds: Array.isArray(selection) ? selection : []
    });
  }

  const [serverId] = selection;
  if (!serverIds.has(serverId)) {
    return deny('DENY_SERVER_SELECTION', {
      reason: 'unknown Figma transport ID',
      activeServerIds: selection
    });
  }

  return {
    serverId,
    defaulted: false
  };
}

function baseResult(capability, serverId) {
  return {
    capability,
    serverId,
    responseTrust: policy.responseTrust,
    externalResponse: true,
    executed: false
  };
}

export function evaluateToolRequest({
  capability = policy.defaultCapability,
  serverId,
  activeServerIds,
  tool
} = {}) {
  const selection = resolveServerSelection(
    activeServerIds === undefined ? (serverId === undefined ? undefined : [serverId]) : activeServerIds
  );
  if (selection.allowed === false) return selection;

  if (typeof tool !== 'string' || tool.length === 0) {
    return deny('DENY_UNKNOWN_TOOL', { reason: 'tool name is required' });
  }

  const selectedServerId = selection.serverId;
  if (readTools.has(tool)) {
    if (!['FIGMA_READ', 'FIGMA_DESIGN_TO_CODE'].includes(capability)) {
      return deny('DENY_CAPABILITY_TOOL_MISMATCH', {
        ...baseResult(capability, selectedServerId),
        tool
      });
    }

    return {
      decision: 'ALLOW_READ_REQUEST',
      allowed: true,
      ...baseResult(capability, selectedServerId),
      tool,
      effects: ['NETWORK_PASSIVE'],
      remoteWrite: false,
      authorizationRequired: false
    };
  }

  if (manualTools.has(tool)) {
    const operation = policy.manualOperations[tool];
    return {
      decision: 'MANUAL_AUTHORIZATION_REQUIRED',
      allowed: false,
      ...baseResult('FIGMA_READ', selectedServerId),
      tool,
      effects: operation.effects,
      reason: operation.reason,
      authorizationRequired: true,
      remoteWrite: false,
      handler: 'none'
    };
  }

  if (writeTools.has(tool)) {
    return {
      decision: 'MANUAL_AUTHORIZATION_REQUIRED',
      allowed: false,
      ...baseResult('FIGMA_WRITE', selectedServerId),
      tool,
      effects: ['EXTERNAL_MUTATION'],
      reason: 'Figma write boundary is disabled until explicit authorization immediately before the call',
      authorizationRequired: true,
      remoteWrite: false,
      handler: 'none'
    };
  }

  return deny('DENY_UNKNOWN_TOOL', {
    ...baseResult(capability, selectedServerId),
    tool,
    reason: policy.unknownToolPolicy
  });
}

export function wrapExternalResponse(data) {
  return {
    source: 'figma-mcp',
    untrusted: true,
    data
  };
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : '';
if (invokedPath === import.meta.url) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { input += chunk; });
  process.stdin.on('end', () => {
    try {
      const request = JSON.parse(input);
      if (!isRecord(request)) throw new Error('request must be an object');
      process.stdout.write(JSON.stringify(evaluateToolRequest(request)) + '\n');
    } catch {
      process.stdout.write(JSON.stringify(deny('DENY_INVALID_REQUEST')) + '\n');
      process.exitCode = 1;
    }
  });
}
