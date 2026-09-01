import { pathToFileURL } from 'node:url';
import { lstat, mkdir, realpath, rm } from 'node:fs/promises';
import path from 'node:path';

function fail(message) {
  throw new Error(`FTK codec boundary: ${message}`);
}

function parseArgs(argv) {
  const allowed = new Set(['--project-root', '--codec', '--output', '--esbuild-module', '--upstream-root', '--execute-contract']);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (!allowed.has(name) || values.has(name)) fail(`unknown or duplicate argument ${name}`);
    if (name === '--execute-contract') {
      values.set(name, true);
      continue;
    }
    if (index + 1 >= argv.length) fail(`missing value for ${name}`);
    values.set(name, argv[++index]);
  }
  for (const name of ['--project-root', '--codec', '--output', '--esbuild-module', '--upstream-root']) {
    if (!values.has(name)) fail(`missing ${name}`);
  }
  return values;
}

function isWithin(root, candidate, allowRoot = false) {
  const relative = path.relative(root, candidate);
  return (allowRoot && relative === '') || (relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

async function assertNoReparseAncestry(root, candidate) {
  if (!isWithin(root, candidate, true)) fail('path is outside its approved root');
  const relative = path.relative(root, candidate);
  let current = root;
  for (const segment of relative ? relative.split(path.sep) : []) {
    current = path.join(current, segment);
    try {
      const item = await lstat(current);
      if (item.isSymbolicLink()) fail(`symbolic-link path component denied: ${current}`);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
  }
}

const args = parseArgs(process.argv.slice(2));
const projectRoot = await realpath(path.resolve(args.get('--project-root')));
const upstreamRoot = await realpath(path.resolve(args.get('--upstream-root')));
const codec = await realpath(path.resolve(args.get('--codec')));
const esbuildModule = await realpath(path.resolve(args.get('--esbuild-module')));
const output = path.resolve(args.get('--output'));

if (!isWithin(projectRoot, codec)) fail('codec is outside the project');
if (!isWithin(upstreamRoot, esbuildModule)) fail('esbuild module is outside the pinned upstream');
if (!isWithin(projectRoot, output)) fail('compiled output is outside the project');
if (!['.ts', '.tsx', '.js', '.mjs'].includes(path.extname(codec))) fail('codec extension is not supported');
await assertNoReparseAncestry(projectRoot, codec);
await assertNoReparseAncestry(projectRoot, output);
await mkdir(path.dirname(output), { recursive: true });
await assertNoReparseAncestry(projectRoot, path.dirname(output));

const { build } = await import(pathToFileURL(esbuildModule).href);
let result;
try {
  result = await build({
    entryPoints: [codec],
    outfile: output,
    bundle: true,
    platform: 'node',
    format: 'esm',
    target: 'es2022',
    metafile: true,
    write: true,
    logLevel: 'silent',
  });
  for (const input of Object.keys(result.metafile.inputs)) {
    const candidate = await realpath(path.resolve(projectRoot, input));
    if (!isWithin(projectRoot, candidate)) fail(`resolved module escaped the project: ${input}`);
    await assertNoReparseAncestry(projectRoot, candidate);
  }
  if (args.has('--execute-contract')) {
    const loaded = await import(`${pathToFileURL(output).href}?ftk=${Date.now()}`);
    if (typeof loaded.decodeSurfaces !== 'function') fail('codec must export decodeSurfaces');
  }
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, inputCount: Object.keys(result.metafile.inputs).length, contract: 'decodeSurfaces' })}\n`);
} catch (error) {
  await rm(output, { force: true }).catch(() => {});
  throw error;
}
