import fs from 'node:fs';
import path from 'node:path';

const targetAxeVersion = '4.13.0';

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const result = { root: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--root') {
      result.root = argv[++index];
    } else {
      throw new Error(`Unknown axe argument: ${argv[index]}`);
    }
  }
  if (!result.root) {
    throw new Error('--root is required.');
  }
  return result;
}

function readContainedPackage(root, relativePath) {
  const packagePath = path.resolve(root, relativePath);
  const rootWithSeparator = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (packagePath !== root && !packagePath.startsWith(rootWithSeparator)) {
    throw new Error(`Package path escaped the project root: ${relativePath}`);
  }
  if (!fs.existsSync(packagePath)) {
    return null;
  }
  const realRoot = fs.realpathSync(root);
  const realPackagePath = fs.realpathSync(packagePath);
  const realRootWithSeparator = realRoot.endsWith(path.sep) ? realRoot : `${realRoot}${path.sep}`;
  if (!realPackagePath.startsWith(realRootWithSeparator)) {
    throw new Error(`Package path resolves outside the project root: ${relativePath}`);
  }
  return JSON.parse(fs.readFileSync(realPackagePath, 'utf8'));
}

try {
  const argumentsForAxe = parseArgs(process.argv.slice(2));
  const root = fs.realpathSync(path.resolve(argumentsForAxe.root));
  if (!fs.statSync(root).isDirectory()) {
    throw new Error('Project root is not a directory.');
  }
  const axe = readContainedPackage(root, 'node_modules/@axe-core/playwright/package.json');
  const playwright = readContainedPackage(root, 'node_modules/playwright/package.json');
  const playwrightTest = readContainedPackage(root, 'node_modules/@playwright/test/package.json');
  const compatibleRunner = playwright ?? playwrightTest;
  let status = 'INCOMPLETE';
  let reason = 'Conditional @axe-core/playwright is not installed in the target project.';
  if (axe && axe.version !== targetAxeVersion) {
    status = 'UNKNOWN';
    reason = `Installed axe version is not the frozen target ${targetAxeVersion}.`;
  } else if (axe && compatibleRunner && /^1\./.test(String(compatibleRunner.version))) {
    status = 'SUPPLEMENTARY_AVAILABLE';
    reason = 'Conditional dependency is available; no scan was executed or authorized by this adapter.';
  }
  process.stdout.write(JSON.stringify({
    status,
    classification: 'CONDITIONAL',
    target: `@axe-core/playwright@${targetAxeVersion}`,
    available: Boolean(axe),
    compatiblePlaywright: Boolean(compatibleRunner),
    installedVersion: axe?.version ?? null,
    scanExecuted: false,
    installAttempted: false,
    codeModified: false,
    reason,
  }, null, 2) + '\n');
} catch (error) {
  fail(`AXE_CONDITIONAL_BLOCKED: ${error.message}`);
}
