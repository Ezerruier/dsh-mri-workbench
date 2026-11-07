// 头动结果解读 Host 侧自测（不启动 DSH/MATLAB）：解析 HeadMotion.tsv + 逐帧 FD，
// 输出每名受试者指标、曲线、启发式提示、最大头动排除名单与中文说明。
// 运行: node tests/node/results_test.mjs
import assert from 'node:assert/strict';
import path from 'node:path';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { apply } from '../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const fixture = path.join(here, 'fixtures', 'results_fixture');
const emptyDir = path.join(fixture, 'empty');

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
const ctx = {
  logger: { info() {}, warn() {}, error() {} },
  effect(fn) { fn(); return () => {}; },
  tools: { register(def) { tools.set(def.name, def); } },
  commands: { register(def) { commands.set(def.name, def); } },
  systemPrompt: { section() {} },
  get(name) { return name === 'workingDirectory' ? { ensure: async () => repoRoot } : undefined; },
};
apply(ctx);
const agent = { id: 'mock-results-agent' };
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

await check('mri_workbench_results 已注册', () => {
  assert.ok(tools.has('mri_workbench_results'));
});

await check('解析 HeadMotion.tsv + 逐帧 FD：3 名受试者、10 帧曲线、组摘要正确', async () => {
  const res = await callTool('mri_workbench_results', { workDir: fixture });
  assert.equal(res.ok, true);
  assert.equal(res.available, true);
  assert.equal(res.subjects.length, 3);
  const a = res.subjects.find((s) => s.id === 'SubA');
  const b = res.subjects.find((s) => s.id === 'SubB');
  const c = res.subjects.find((s) => s.id === 'SubC');
  assert.equal(a.metrics.meanFDJenkinson, 0.05);
  assert.equal(b.metrics.meanFDJenkinson, 0.18);
  assert.equal(c.metrics.meanFDJenkinson, 0.3);
  assert.equal(a.series.jenkinson.length, 10);
  assert.equal(a.series.power.length, 10);
  assert.equal(a.frames, 10);
  assert.equal(res.summary.count, 3);
  assert.ok(Math.abs(res.summary.mean - (0.05 + 0.18 + 0.3) / 3) < 1e-9);
  assert.equal(res.summary.worstSubject, 'SubC');
  assert.equal(res.defaultSubjectId, 'SubC');
  assert.deepEqual(res.summary.overThreshold.sort(), ['SubC']);
  assert.ok(res.explanations.overview.length >= 5);
  assert.ok(res.explanations.thresholdNote.includes('0.2'));
});

await check('每名受试者的提示等级按 mean FD 分层', async () => {
  const res = await callTool('mri_workbench_results', { workDir: fixture });
  const byId = Object.fromEntries(res.subjects.map((s) => [s.id, s.verdict]));
  assert.equal(byId.SubA.level, 'ok');
  assert.equal(byId.SubB.level, 'attention');
  assert.equal(byId.SubC.level, 'warn');
  assert.ok(byId.SubC.reasons.join('；').includes('0.300'));
});

await check('阈值参数会改变超阈值名单与提示', async () => {
  const res = await callTool('mri_workbench_results', { workDir: fixture, threshold: 0.15 });
  assert.equal(res.threshold, 0.15);
  assert.deepEqual(res.summary.overThreshold.sort(), ['SubB', 'SubC']);
  const b = res.subjects.find((s) => s.id === 'SubB');
  assert.equal(b.verdict.level, 'warn');
});

await check('最大头动排除名单被解析', async () => {
  const res = await callTool('mri_workbench_results', { workDir: fixture });
  const oneZero = res.excludedByMaxMotion.find((g) => g.criteria.startsWith('1.0mm'));
  assert.ok(oneZero, '缺少 1.0mm 组');
  assert.deepEqual(oneZero.subjects, ['SubC']);
  const half = res.excludedByMaxMotion.find((g) => g.criteria.startsWith('0.5mm'));
  assert.deepEqual(half.subjects, ['SubB', 'SubC']);
});

await check('没有 RealignParameter 时返回 available=false 且不抛异常', async () => {
  const res = await callTool('mri_workbench_results', { workDir: emptyDir });
  assert.equal(res.ok, true);
  assert.equal(res.available, false);
  assert.ok(res.message.includes('HeadMotion.tsv'));
});

await check('/mri results 渲染中文解读文本', async () => {
  const result = await callCommand(`results "${fixture}"`);
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('DPARSF 头动结果解读'));
  assert.ok(result.text.includes('mean FD_Jenkinson'));
  assert.ok(result.text.includes('SubA'));
  assert.ok(result.text.includes('FD_Power>0.2'));
});

await check('/mri resultsjson 返回 Client 可解析 JSON', async () => {
  const result = await callCommand(`resultsjson "${fixture}"`);
  assert.equal(result.kind, 'success');
  const payload = JSON.parse(result.text);
  assert.equal(payload.ok, true);
  assert.equal(payload.available, true);
  assert.equal(payload.subjects.length, 3);
  assert.ok(payload.workDirSourceLabel);
});

await check('结果 JSON 包含经验分级参考与每人分级', async () => {
  const res = await callTool('mri_workbench_results', { workDir: fixture });
  assert.ok(res.references, '缺少 references');
  assert.equal(res.references.maxTranslation.tiers.length, 4);
  assert.equal(res.references.maxRotation.tiers.length, 4);
  assert.equal(res.references.badFrameRatio.tiers.length, 4);
  assert.ok(res.references.gradingNote.includes('非文献共识'));
  assert.ok(Array.isArray(res.scrubbing?.notes) && res.scrubbing.notes.length >= 3, '缺少 scrubbing 说明');
  const subA = res.subjects.find((s) => s.id === 'SubA');
  const subB = res.subjects.find((s) => s.id === 'SubB');
  assert.equal(subA.grades.maxTranslation.level, 'ok');
  assert.equal(subA.grades.badFrameRatio.level, 'attention'); // 10%
  assert.equal(subB.grades.badFrameRatio.level, 'bad'); // 40%
  assert.ok(subB.grades.badFrameRatio.label.includes('30%'));
});

await check('mri_workbench_censor 计算坏帧（FD_Jenkinson > 0.2 mm）', async () => {
  assert.ok(tools.has('mri_workbench_censor'), '工具未注册');
  const res = await callTool('mri_workbench_censor', { workDir: fixture, fdType: 'FD_Jenkinson', threshold: 0.2 });
  assert.equal(res.ok, true);
  assert.equal(res.available, true);
  assert.equal(res.fdType, 'jenkinson');
  assert.equal(res.threshold, 0.2);
  const byId = Object.fromEntries(res.subjects.map((s) => [s.id, s]));
  assert.equal(byId.SubA.count, 0);
  assert.deepEqual(byId.SubB.frames, [3]);
  assert.deepEqual(byId.SubC.frames, [3, 5, 6, 7, 8, 9, 10]);
  assert.equal(byId.SubC.total, 10);
  assert.ok(Math.abs(byId.SubC.percent - 70) < 1e-9);
  assert.equal(res.summary.subjectsWithBadFrames, 2);
  assert.equal(res.exportDir, undefined);
});

await check('mri_workbench_censor 支持 previous/later 邻域扩展', async () => {
  const res = await callTool('mri_workbench_censor', { workDir: fixture, fdType: 'FD_Jenkinson', threshold: 0.2, previous: 1, later: 1 });
  assert.equal(res.ok, true);
  assert.equal(res.previous, 1);
  assert.equal(res.later, 1);
  const byId = Object.fromEntries(res.subjects.map((s) => [s.id, s]));
  assert.deepEqual(byId.SubA.frames, []);
  assert.deepEqual(byId.SubB.frames, [2, 3, 4]);
  assert.deepEqual(byId.SubC.frames, [2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.ok(res.message.includes('向前 1 / 向后 1 帧扩展'), `message 未说明扩展：${res.message}`);
  const laterOnly = await callTool('mri_workbench_censor', { workDir: fixture, fdType: 'FD_Jenkinson', threshold: 0.2, previous: 0, later: 2 });
  assert.deepEqual(laterOnly.subjects.find((s) => s.id === 'SubB').frames, [3, 4, 5]);
});

await check('mri_workbench_censor export=true 写坏帧文件与汇总表（随后清理）', async () => {
  const res = await callTool('mri_workbench_censor', { workDir: fixture, export: true });
  assert.ok(res.exportDir && existsSync(res.exportDir), '未创建导出目录');
  assert.ok(res.summaryFile && existsSync(res.summaryFile), '未写汇总表');
  const summary = readFileSync(res.summaryFile, 'utf8');
  assert.ok(summary.includes('nBadFrames'));
  assert.ok(summary.includes('SubC'));
  const subCFile = path.join(res.exportDir, 'SubC_censor_frames.txt');
  assert.ok(existsSync(subCFile), '未写 SubC 坏帧文件');
  assert.equal(readFileSync(subCFile, 'utf8').trim().split(/\r?\n/).length, 7);
  rmSync(path.join(fixture, 'ScrubbingPreview'), { recursive: true, force: true });
  assert.ok(!existsSync(path.join(fixture, 'ScrubbingPreview')), '清理失败');
});

await check('/mri censor 命令导出并返回中文清单', async () => {
  const result = await callCommand(`censor jenkinson 0.2 "${fixture}"`);
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('Scrubbing / Censor'));
  assert.ok(result.text.includes('SubC'));
  assert.ok(result.text.includes('已导出：'));
  rmSync(path.join(fixture, 'ScrubbingPreview'), { recursive: true, force: true });
});

await check('/mri censor 命令支持 prev=N / later=N 邻域扩展', async () => {
  const result = await callCommand(`censor jenkinson 0.2 prev=1 later=2 "${fixture}"`);
  assert.equal(result.kind, 'success');
  assert.ok(result.text.includes('邻域扩展：前 1 / 后 2 帧'), result.text);
  const dir = path.join(fixture, 'ScrubbingPreview', 'FD_Jenkinson_0p2mm_prev1_later2');
  assert.ok(existsSync(dir), '未按邻域扩展创建导出目录');
  const subB = readFileSync(path.join(dir, 'SubB_censor_frames.txt'), 'utf8').trim().split(/\r?\n/).map(Number);
  assert.deepEqual(subB, [2, 3, 4, 5]);
  const subC = readFileSync(path.join(dir, 'SubC_censor_frames.txt'), 'utf8').trim().split(/\r?\n/).map(Number);
  assert.deepEqual(subC, [2, 3, 4, 5, 6, 7, 8, 9, 10]);
  rmSync(path.join(fixture, 'ScrubbingPreview'), { recursive: true, force: true });
});

console.log(`\n全部通过：${passed} 项检查`);
