import assert from 'node:assert/strict';
import {
  evaluateToolRequest,
  getFigmaPolicy,
  resolveServerSelection,
  wrapExternalResponse
} from '../plugin/frontend-toolkit/security/figma-capability-mediator.mjs';

const policy = getFigmaPolicy();
const readTools = policy.capabilities.FIGMA_READ.tools;
const writeTools = policy.capabilities.FIGMA_WRITE.tools;

assert.equal(policy.defaultCapability, 'FIGMA_READ');
assert.deepEqual(resolveServerSelection(['figma', 'figma-desktop']), {
  decision: 'DENY_SERVER_SELECTION',
  allowed: false,
  executed: false,
  handler: 'none',
  reason: 'exactly one Figma transport must be active',
  activeServerIds: ['figma', 'figma-desktop']
});
assert.equal(resolveServerSelection(['figma']).serverId, 'figma');
assert.equal(resolveServerSelection(['figma-desktop']).serverId, 'figma-desktop');

for (const tool of readTools) {
  for (const serverId of ['figma', 'figma-desktop']) {
    const result = evaluateToolRequest({ capability: 'FIGMA_READ', serverId, tool });
    assert.equal(result.decision, 'ALLOW_READ_REQUEST', tool);
    assert.equal(result.serverId, serverId);
    assert.equal(result.executed, false);
    assert.equal(result.remoteWrite, false);
    assert.equal(result.externalResponse, true);
  }
}

const designToCode = evaluateToolRequest({
  capability: 'FIGMA_DESIGN_TO_CODE',
  serverId: 'figma',
  tool: 'get_design_context'
});
assert.equal(designToCode.decision, 'ALLOW_READ_REQUEST');
assert.equal(designToCode.remoteWrite, false);
assert.equal(designToCode.executed, false);

for (const tool of writeTools) {
  const result = evaluateToolRequest({ capability: 'FIGMA_WRITE', serverId: 'figma', tool });
  assert.equal(result.decision, 'MANUAL_AUTHORIZATION_REQUIRED', tool);
  assert.equal(result.authorizationRequired, true);
  assert.equal(result.handler, 'none');
  assert.equal(result.executed, false);
  assert.equal(result.remoteWrite, false);
}

for (const tool of ['download_assets', 'whoami']) {
  const result = evaluateToolRequest({ serverId: 'figma', tool });
  assert.equal(result.decision, 'MANUAL_AUTHORIZATION_REQUIRED', tool);
  assert.equal(result.authorizationRequired, true);
  assert.equal(result.executed, false);
}

const unknown = evaluateToolRequest({ serverId: 'figma', tool: 'unknown_figma_tool' });
assert.equal(unknown.decision, 'DENY_UNKNOWN_TOOL');
assert.equal(unknown.allowed, false);
assert.equal(unknown.executed, false);

assert.deepEqual(wrapExternalResponse({ nodeId: 'fixture-node' }), {
  source: 'figma-mcp',
  untrusted: true,
  data: { nodeId: 'fixture-node' }
});

console.log('PASS: Figma read allowlist is hermetic across remote and desktop IDs.');
console.log('PASS: design-to-code consumes read context without REMOTE_WRITE.');
console.log('PASS: Figma write, asset-save and identity operations remain manual-only.');
console.log('PASS: unknown Figma tools fail closed and responses stay untrusted data.');
console.log('REAL FIGMA CALLS=0; OAUTH=0; ACCOUNT/PLAN SELECTION=0');
