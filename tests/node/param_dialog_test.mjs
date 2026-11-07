// 参数设置弹窗接线自测（mock DSH Host context，不启动 DSH、不启动 MATLAB）
// 运行: node tests/node/param_dialog_test.mjs
// 目的：验证 Client 弹窗依赖的 /mri paramsjson 命令返回可解析、字段带中文悬停解释(tip)，
//       mri_workbench_params 工具、overrides 保存/清空、命令 help 与系统提示。
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { apply } from '../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
// 隔离工作区：写入 tests/node/fixtures/schema.json 的 CfgSchema 缓存（离线运行不启动 MATLAB），
// 避免继承本机真实 .mri-workbench 运行状态。
const workspace = mkdtempSync(path.join(os.tmpdir(), 'mrw-param-dialog-ws-'));
mkdirSync(path.join(workspace, '.mri-workbench'), { recursive: true });
copyFileSync(path.join(here, 'fixtures', 'schema.json'), path.join(workspace, '.mri-workbench', 'schema.json'));

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

const tools = new Map();
const commands = new Map();
const promptSections = [];
const ctx = {
  logger: { info() {}, warn() {}, error() {} },
  effect(fn) { fn(); return () => {}; },
  tools: { register(def) { tools.set(def.name, def); } },
  commands: { register(def) { commands.set(def.name, def); } },
  systemPrompt: { section(def) { promptSections.push(def); } },
  get(name) { return name === 'workingDirectory' ? { ensure: async () => workspace } : undefined; },
};
const dispose = apply(ctx);
const agent = { id: 'mock-param-dialog-agent' };
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

console.log(`tools=${[...tools.keys()].join(',')}`);

await check('新工具 mri_workbench_params / mri_workbench_overrides 已注册', () => {
  assert.ok(tools.has('mri_workbench_params'));
  assert.ok(tools.has('mri_workbench_overrides'));
});

await check('mri_workbench_params 返回 CfgSchema 且每条带 tip（悬停解释）', async () => {
  const value = await callTool('mri_workbench_params', { filter: 'TR' });
  assert.equal(value.ok, true);
  assert.equal(value.total, 98);
  assert.ok(Array.isArray(value.entries) && value.entries.length > 0);
  const tr = value.entries.find((e) => e.key === 'TR');
  assert.ok(tr, '缺少 TR 字段');
  assert.ok(typeof tr.tip === 'string' && tr.tip.length > 20, 'TR 缺中文悬停解释 tip');
  assert.equal(tr.label, '重复时间 TR（秒，0=自动）');
  assert.equal(tr.en, 'TR');
  assert.equal(tr.type, 'double');
});

await check('mri_workbench_params 无 filter 返回 98 项且分组正确', async () => {
  const value = await callTool('mri_workbench_params', {});
  assert.equal(value.count, value.total);
  assert.equal(value.entries.length, 98);
  assert.deepEqual(value.groups, ['基础设置', '时间层与头动', '结构像处理', '标准化与平滑', '回归与滤波', '指标计算', '高级与运行']);
  assert.ok(value.entries.every((e) => typeof e.tip === 'string'));
});

await check('/mri paramsjson 返回 Client 可 JSON.parse 的参数包', async () => {
  const result = await callCommand('paramsjson');
  assert.equal(result.kind, 'success');
  const payload = JSON.parse(result.text);
  assert.equal(payload.ok, true);
  assert.equal(payload.total, 98);
  assert.ok(Array.isArray(payload.groups) && payload.groups.length === 7);
  assert.ok(Array.isArray(payload.entries) && payload.entries.length === 98);
  assert.ok(Array.isArray(payload.overrides));
  const tr = payload.entries.find((e) => e.key === 'TR');
  assert.ok(tr && tr.tip && tr.tip.length > 20);
  const smooth = payload.entries.find((e) => e.key === 'IsSmooth');
  assert.ok(Array.isArray(smooth.options) && smooth.options.length === 3, 'IsSmooth 枚举选项缺失');
  const deps = payload.entries.find((e) => e.key === 'SliceTiming.SliceOrder');
  assert.ok(deps.dependsOn, '依赖条件缺失');
  assert.ok(Buffer.byteLength(result.text, 'utf8') < 200000, '参数包过大');
});

await check('overrides set/show/clear 与 paramsjson 联动', async () => {
  const set = await callTool('mri_workbench_overrides', {
    action: 'set',
    overrides: [{ key: 'TR', value: 2.5 }, { key: 'IsRemoveFirstTimePoints', value: false }, { key: 'Bad Key!', value: 1 }],
  });
  assert.equal(set.ok, true);
  assert.equal(set.overrides.length, 2);
  assert.deepEqual(set.skipped, ['Bad Key!']);

  const show = await callTool('mri_workbench_overrides', { action: 'show' });
  assert.equal(show.overrides.length, 2);

  const paramsJson = JSON.parse((await callCommand('paramsjson')).text);
  assert.equal(paramsJson.overrides.length, 2);
  assert.equal(paramsJson.overrides.find((o) => o.key === 'TR').value, 2.5);

  const clear = await callTool('mri_workbench_overrides', { action: 'clear' });
  assert.equal(clear.overrides.length, 0);
  const afterClear = JSON.parse((await callCommand('paramsjson')).text);
  assert.equal(afterClear.overrides.length, 0);
});

await check('/mri help 包含 params/overrides 用法', async () => {
  const result = await callCommand('help');
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('/mri params'));
  assert.ok(result.text.includes('/mri overrides'));
  assert.ok(result.text.includes('/mri prepare'));
});

await check('命令 input.hint 包含 params/overrides', () => {
  const hint = String(commands.get('mri').input.hint);
  assert.ok(hint.includes('params'));
  assert.ok(hint.includes('overrides'));
});

await check('系统提示包含手动调参指引', () => {
  const text = promptSections[0].text;
  assert.ok(text.includes('mri_workbench_params'));
  assert.ok(text.includes('mri_workbench_overrides'));
  assert.ok(text.includes('参数覆盖'));
});

await check('dispose 可调用', () => {
  assert.equal(typeof dispose, 'function');
  dispose();
});

rmSync(workspace, { recursive: true, force: true });

console.log(`\n全部通过：${passed} 项检查`);
