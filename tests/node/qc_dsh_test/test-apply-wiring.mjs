// dsh-mri-workbench 人工 QC 插件接线自测（mock DSH Host context，不启动 DSH、不启动 MATLAB）
// 前置（可选，样例已作为静态 fixture 提交）: powershell -NoProfile -ExecutionPolicy Bypass -File tests/node/fixtures/qc_dsh_test/make_fixtures.ps1
// 运行: node tests/node/qc_dsh_test/test-apply-wiring.mjs
// 验证：mri_workbench_qc 已注册并可执行、/mri qcstatus 命令可用、/mri help 更新、
//       系统提示含人工 QC 指引、原工具/命令保持兼容；工具输出可无损 JSON 序列化。
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { apply, inject } from '../../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..', '..');
// 静态 fixture 位于 tests/node/fixtures/qc_dsh_test/（由 fixtures.json + make_fixtures.ps1 生成后提交）。
const sample = path.join(here, '..', 'fixtures', 'qc_dsh_test', 'sample');

// 新仓库布局：MATLAB 工作台位于 <repo>/matlab/MRI_Workbench，用 MRI_WORKBENCH_ROOT 指向它；
// 会话工作区用独立临时目录，避免继承本机真实 .mri-workbench 运行状态。
process.env.MRI_WORKBENCH_ROOT = path.join(repoRoot, 'matlab', 'MRI_Workbench');
const workspace = mkdtempSync(path.join(os.tmpdir(), 'mrw-apply-wiring-ws-'));

let passed = 0;
async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`PASS  ${name}`);
  } catch (err) {
    console.error(`FAIL  ${name}`);
    throw err;
  }
}

function assertLossless(value, label, where = '$') {
  if (value === undefined) throw new Error(`${label}: undefined at ${where}`);
  if (typeof value === 'number') {
    assert.ok(Number.isFinite(value), `${label}: non-finite number at ${where}`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertLossless(item, label, `${where}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) assertLossless(item, label, `${where}.${key}`);
  }
}

if (!existsSync(sample)) {
  console.error('缺少样例目录：请先运行 powershell -NoProfile -ExecutionPolicy Bypass -File tests/node/fixtures/qc_dsh_test/make_fixtures.ps1（或恢复提交的静态 fixture）');
  process.exit(2);
}

// ------------------------------------------------------------------
// mock DSH Host context
// ------------------------------------------------------------------
const tools = new Map();
const commands = new Map();
const promptSections = [];
const wdService = { ensure: async () => workspace };
const ctx = {
  logger: { info() {}, warn() {}, error() {} },
  effect(fn) {
    fn();
    return () => {};
  },
  tools: { register(def) { tools.set(def.name, def); } },
  commands: { register(def) { commands.set(def.name, def); } },
  systemPrompt: { section(def) { promptSections.push(def); } },
  get(name) { return name === 'workingDirectory' ? wdService : undefined; },
};

const dispose = apply(ctx);
const agent = { id: 'mock-qc-agent' };
const exec = { agent, signal: undefined };

async function callTool(name, args) {
  const tool = tools.get(name);
  assert.ok(tool, `工具未注册：${name}`);
  return tool.execute(args ?? {}, exec);
}

async function callCommand(rawInput) {
  const command = commands.get('mri');
  assert.ok(command, '命令 /mri 未注册');
  return command.handler({ rawInput, agent, signal: undefined });
}

// ------------------------------------------------------------------
console.log(`\n注册结果：tools=${[...tools.keys()].join(',')}`);
console.log(`commands=${[...commands.keys()].join(',')}`); 

await check('inject 声明保持 tools/systemPrompt/commands', () => {
  assert.deepEqual(inject, ['tools', 'systemPrompt', 'commands']);
});

await check('原 8 个工具仍注册（完全兼容）', () => {
  for (const name of [
    'mri_workbench_env',
    'mri_workbench_scan',
    'mri_workbench_prepare',
    'mri_workbench_start',
    'mri_workbench_status',
    'mri_workbench_wait',
    'mri_workbench_cancel',
    'mri_workbench_open_gui',
  ]) {
    assert.ok(tools.has(name), `缺少工具 ${name}`);
  }
});

await check('新工具 mri_workbench_qc：参数 schema 仅 workDir（可选）', () => {
  const tool = tools.get('mri_workbench_qc');
  assert.ok(tool);
  assert.deepEqual(Object.keys(tool.parameters.properties), ['workDir']);
  assert.deepEqual(tool.parameters.required, []);
  assert.equal(tool.parameters.additionalProperties, false);
  assert.ok(/QC Score|manual QC/i.test(tool.description));
});

await check('mri_workbench_qc 显式 workDir → 摘要正确且 lossless JSON', async () => {
  const value = await callTool('mri_workbench_qc', { workDir: sample });
  assertLossless(value, 'mri_workbench_qc 输出');
  assert.deepEqual(JSON.parse(JSON.stringify(value)), value);
  assert.equal(value.action, 'qc');
  assert.equal(value.ok, true);
  assert.equal(value.workDir, path.resolve(sample));
  assert.equal(value.workDirSource, 'argument');
  assert.equal(value.subjectTotal, 5);
  assert.equal(value.hasScores, true);
  assert.equal(value.modalities.find((m) => m.key === 'T1').scored, 4);
  assert.deepEqual(value.headMotion.over.map((row) => row.id), ['Sub02', 'Sub04']);
});

await check('mri_workbench_qc 渲染文本（tool output.render）', async () => {
  const tool = tools.get('mri_workbench_qc');
  const value = await callTool('mri_workbench_qc', { workDir: sample });
  const rendered = tool.output.render({}, value);
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].type, 'text');
  assert.ok(rendered[0].text.includes('人工 QC 摘要'));
  assert.ok(rendered[0].text.includes('T1 原始像（QC/RawT1ImgQC.tsv）：已评分 4/5（80%），平均分 3.5'));
  assert.ok(rendered[0].text.includes('MeanFD 超阈值'));
});

await check('mri_workbench_qc 缺省 workDir（无最近配置）→ 回退工作区并给出提醒', async () => {
  const value = await callTool('mri_workbench_qc', {});
  assertLossless(value, 'mri_workbench_qc 回退输出');
  assert.equal(value.workDirSource, 'workspace-fallback');
  assert.ok(value.warnings.some((warning) => warning.includes('回退到当前会话工作区')));
});

await check('mri_workbench_qc 显式 workDir 不存在 → 中文错误', async () => {
  await assert.rejects(
    () => callTool('mri_workbench_qc', { workDir: path.join(here, 'no-such-dir') }),
    (err) => {
      assert.ok(err instanceof Error);
      assert.ok(err.message.includes('工作目录不存在'));
      return true;
    },
  );
});

await check('/mri qcstatus <目录> → 返回与工具一致的摘要文本', async () => {
  const result = await callCommand(`qcstatus "${sample}"`);
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('人工 QC 摘要'));
  assert.ok(result.text.includes('T1 原始像（QC/RawT1ImgQC.tsv）：已评分 4/5（80%），平均分 3.5'));
  assert.ok(result.text.includes('功能平均像'));
});

await check('/mri qcstatus（缺省目录）→ 不崩溃，提示无评分', async () => {
  const result = await callCommand('qcstatus');
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('人工 QC 摘要'));
});

await check('/mri help 列出 qc / qcstatus 子命令', async () => {
  const result = await callCommand('help');
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('/mri qc [工作目录]'));
  assert.ok(result.text.includes('/mri qcstatus [工作目录]'));
});

await check('/mri qc <不存在的目录> → 中文错误（在 spawn MATLAB 之前拦截）', async () => {
  const result = await callCommand(`qc "${path.join(here, 'no-such-dir')}"`);
  assert.equal(result.kind, 'error');
  assert.ok(result.text.includes('工作目录不存在'));
  assert.ok(result.text.includes('MRI 工作台操作失败'));
});

await check('命令 input.hint 包含 qc', () => {
  const command = commands.get('mri');
  assert.ok(String(command.input.hint).includes('qc'));
});

await check('系统提示新增人工 QC 指引（不伪造 QC 结论）', () => {
  assert.equal(promptSections.length, 1);
  const text = promptSections[0].text;
  assert.ok(text.includes('mri_workbench_qc'));
  assert.ok(text.includes('人工 QC'));
  assert.ok(text.includes('不得在对话中伪造 QC 评分'));
});

await check('原工具 mri_workbench_env / status 仍可执行（兼容性）', async () => {
  const env = await callTool('mri_workbench_env', {});
  assert.equal(env.kind, 'mri-workbench');
  assert.equal(env.action, 'env');
  assert.equal(env.workbenchExists, true); // 通过 MRI_WORKBENCH_ROOT 指向 <repo>/matlab/MRI_Workbench
  if (process.platform === 'win32') {
    // 原断言：Windows 本机开发环境需能找到 matlab.exe。
    assert.equal(env.matlabExists, true);
  } else {
    console.log('SKIP  matlabExists===true 是 Windows 本机开发环境断言；CI ubuntu 无 MATLAB，改校验字段类型');
    assert.equal(typeof env.matlabExists, 'boolean');
    assert.equal(typeof env.matlabExe, 'string');
  }
  const status = await callTool('mri_workbench_status', {});
  assert.equal(status.action, 'status');
  assert.equal(status.hasRun, false);
});

await check('dispose 函数可调用', () => {
  assert.equal(typeof dispose, 'function');
  dispose();
});

rmSync(workspace, { recursive: true, force: true });

console.log(`\n全部通过：${passed} 项检查`);
