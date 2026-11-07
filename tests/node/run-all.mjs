// 运行 tests/node 下全部离线 Node 自测（不启动 DSH / MATLAB / 浏览器）。
//
// 用法（仓库根目录或任意目录均可）:
//   node tests/node/run-all.mjs
//
// 输出：每个脚本一行 `PASS <name> (<n> checks)` 或 `FAIL <name>`（失败时附输出尾部），
// 最后汇总脚本数与检查数；任一脚本失败则以非零码退出（供 CI 使用）。
import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');

/**
 * 递归发现测试脚本：tests/node 下所有 .mjs（跳过本文件、fixtures/ 与 node_modules/）。
 * 允许按组放子目录（例如 qc_dsh_test/test-qc-dsh.mjs）。
 */
function discover(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'fixtures' || entry.name === 'node_modules') continue;
      out.push(...discover(full));
    } else if (entry.isFile() && entry.name.endsWith('.mjs') && entry.name !== 'run-all.mjs') {
      out.push(full);
    }
  }
  return out;
}

const toPosix = (p) => p.split(path.sep).join('/');
const scriptName = (file) => toPosix(path.relative(repoRoot, file));

/** 解析脚本自报的检查数：兼容 `全部通过：N 项检查` 与 `N/N PASS` 两种既有格式。 */
function countChecks(stdout) {
  const zh = stdout.match(/全部通过[：:]\s*(\d+)\s*项检查/);
  if (zh) return Number(zh[1]);
  const legacy = stdout.match(/^(\d+)\/\d+\s+PASS\s*$/m);
  if (legacy) return Number(legacy[1]);
  const passLines = stdout.match(/^PASS\s{2,}/gm);
  return passLines ? passLines.length : 0;
}

function countSkips(stdout) {
  const skips = stdout.match(/^SKIP\s/gm);
  return skips ? skips.length : 0;
}

function indent(text) {
  return text
    .trim()
    .split(/\r?\n/)
    .map((line) => `     ${line}`)
    .join('\n');
}

const scripts = discover(here).sort((a, b) => scriptName(a).localeCompare(scriptName(b)));
if (scripts.length === 0) {
  console.error('未发现任何测试脚本：tests/node 下没有 .mjs 文件。');
  process.exit(1);
}

let failed = 0;
let totalChecks = 0;
let totalSkips = 0;

for (const script of scripts) {
  const name = scriptName(script);
  const result = spawnSync(process.execPath, [script], {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  });
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';
  const ok = !result.error && result.status === 0;
  const checks = countChecks(stdout);
  const skips = countSkips(stdout);

  if (ok) {
    totalChecks += checks;
    totalSkips += skips;
    console.log(`PASS ${name} (${checks} checks)`);
    if (skips > 0) {
      console.log(`     SKIP ${skips} 项平台相关检查（详见 tests/node/README.md）`);
    }
  } else {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(indent([stdout, stderr].filter(Boolean).join('\n')));
    if (result.error) console.log(`     启动失败：${result.error.message}`);
  }
}

console.log('');
if (failed > 0) {
  console.error(`FAILED ${failed}/${scripts.length} 个测试脚本（通过 ${scripts.length - failed} 个）`);
  process.exit(1);
}
const skipNote = totalSkips > 0 ? `，SKIP ${totalSkips} 项（平台相关）` : '';
console.log(`PASS 全部 ${scripts.length} 个测试脚本（合计 ${totalChecks} 项检查${skipNote}）`);
