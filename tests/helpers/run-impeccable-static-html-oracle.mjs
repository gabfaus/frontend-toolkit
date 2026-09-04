/*
 * Test-only oracle launcher for the pinned Impeccable static-HTML engine.
 *
 * The oracle is imported from the existing pinned checkout. Its bare imports
 * are resolved by the FTK-owned canonical loader, so this helper cannot
 * silently fall back to ambient or project modules.
 */
import path from 'node:path';
import { pathToFileURL } from 'node:url';

function fail(message) {
  throw new Error(message);
}

const [runtimeModule, skillRoot, inputPath] = process.argv.slice(2);
if (!runtimeModule || !skillRoot || !inputPath || process.argv.length !== 5) {
  fail('Oracle launcher requires runtime module, pinned skill root, and input path.');
}

const runtimeUrl = pathToFileURL(path.resolve(runtimeModule)).href;
const skillRootPath = path.resolve(skillRoot);
const inputFilePath = path.resolve(inputPath);

await import(runtimeUrl);
const [{ detectHtml }, { createDetectorProfile }] = await Promise.all([
  import(pathToFileURL(path.join(skillRootPath, 'scripts/detector/engines/static-html/detect-html.mjs')).href),
  import(pathToFileURL(path.join(skillRootPath, 'scripts/detector/profile/profiler.mjs')).href),
]);

const profile = createDetectorProfile();
const findings = await detectHtml(inputFilePath, { inlineIgnores: false, profile });
const state = globalThis.__ftkStaticHtmlRuntime;
if (!state || state.initialized !== true) fail('Canonical static-HTML loader did not initialize.');

process.stdout.write(JSON.stringify({
  schemaVersion: 1,
  findings,
  profile: profile.events,
  runtime: {
    loadedPackages: [...state.loadedPackages].sort(),
    expectedPackages: Object.keys(state.expectedPackages).sort(),
    quickSortLoaded: state.quickSortLoaded === true,
  },
}) + '\n');
