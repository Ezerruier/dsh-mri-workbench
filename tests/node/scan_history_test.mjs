// 扫描输出的「目录处理历史」自测（纯目录读取，不启动 MATLAB/DSH）：
// 解释工作目录里 FunImg* 阶段目录与 RealignParameter/Results 等目录各自经过哪些处理。
// 运行: node tests/node/scan_history_test.mjs
import assert from 'node:assert/strict';
import path from 'node:path';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  decodeDparsfFunDir,
  buildProcessingHistory,
  renderProcessingHistory,
} from '../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, 'tmp_scan_history', 'workdir');

function resetFixture() {
  rmSync(path.join(here, 'tmp_scan_history'), { recursive: true, force: true });
  const subj = ['sub-A', 'sub-B', 'sub-C'];
  for (const stage of ['FunImg', 'FunImgA', 'FunImgAR', 'FunImgARB', 'T1Img', 'RealignParameter', 'VoxelSpecificHeadMotion']) {
    for (const id of subj) mkdirSync(path.join(fixture, stage, id), { recursive: true });
  }
  for (const measure of ['ReHo_FunImgARB', 'ALFF_FunImgARB']) {
    for (const id of subj) mkdirSync(path.join(fixture, 'Results', measure, id), { recursive: true });
  }
}

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

await check('decodeDparsfFunDir 解析 FunImg/FunImgA/FunImgAR/FunImgARB 与 Scrubbing 输出', () => {
  assert.deepEqual(decodeDparsfFunDir('FunImg'), {
    name: 'FunImg',
    sessionPrefix: '',
    base: 'FunImg',
    suffix: '',
    steps: [],
    stepText: '功能像 NIfTI 起始数据',
    isScrubbingOutput: false,
    depth: 0,
  });
  const a = decodeDparsfFunDir('FunImgA');
  assert.equal(a.base, 'FunImg');
  assert.deepEqual(a.steps.map((s) => s.token), ['A']);
  assert.ok(a.stepText.includes('时间层校正'));
  const arB = decodeDparsfFunDir('FunImgARB');
  assert.deepEqual(arB.steps.map((s) => s.token), ['A', 'R', 'B']);
  assert.equal(arB.isScrubbingOutput, true);
  assert.ok(arB.stepText.includes('头动校正'));
  assert.ok(arB.stepText.includes('Scrubbing'));
  assert.equal(arB.depth, 3);
  // 多 session 前缀 + VMHC sym 后缀
  const s2 = decodeDparsfFunDir('S2_FunImgARsym');
  assert.equal(s2.sessionPrefix, 'S2_');
  assert.equal(s2.base, 'FunImg');
  assert.deepEqual(s2.steps.map((s) => s.token), ['A', 'R', 'sym']);
  // 非功能像目录不识别
  assert.equal(decodeDparsfFunDir('T1Img'), null);
  assert.equal(decodeDparsfFunDir('RealignParameter'), null);
});

await check('buildProcessingHistory 识别阶段链、受试者数、结果目录与续跑建议', () => {
  resetFixture();
  const history = buildProcessingHistory(fixture, { startingDirName: 'FunImg' });
  assert.deepEqual(history.chain, ['FunImg', 'FunImgA', 'FunImgAR', 'FunImgARB']);
  assert.deepEqual(history.stages.map((s) => s.name), ['FunImg', 'FunImgA', 'FunImgAR', 'FunImgARB']);
  assert.ok(history.stages.every((s) => s.subjectCount === 3));
  const scrubStage = history.stages.find((s) => s.name === 'FunImgARB');
  assert.equal(scrubStage.isScrubbingOutput, true);
  const extras = history.otherDirs.map((d) => d.name);
  for (const name of ['RealignParameter', 'VoxelSpecificHeadMotion', 'Results', 'T1Img']) {
    assert.ok(extras.includes(name), `缺少结果目录说明：${name}`);
  }
  assert.ok(history.otherDirs.find((d) => d.name === 'RealignParameter').note.includes('FD_Jenkinson'));
  assert.equal(history.suggestedStartingDirName, 'FunImgAR');
  assert.ok(history.hint.includes('只补 Scrubbing'));
  assert.ok(history.hint.includes('FunImgAR'));
  assert.ok(history.hint.includes('完整重跑请先恢复原始数据'));
});

await check('renderProcessingHistory 生成执行输出说明行（含处理链、每目录、文件命名与提示）', () => {
  const history = buildProcessingHistory(fixture, { startingDirName: 'FunImg' });
  const lines = renderProcessingHistory(history);
  const text = lines.join('\n');
  assert.ok(text.includes('数据目录处理历史：FunImg → FunImgA → FunImgAR → FunImgARB'), text);
  assert.ok(text.includes('FunImgARB：功能像 NIfTI 起始数据 → 时间层校正（Slice Timing） → 头动校正（Realign） → Scrubbing（坏帧剔除/插值）'), text);
  assert.ok(text.includes('3 名受试者'), text);
  assert.ok(text.includes('输出文件 <受试者>/<受试者>_4DVolume.nii'), text);
  assert.ok(text.includes('RealignParameter：头动校正参数与 FD 曲线'), text);
  assert.ok(text.includes('文件命名：阶段目录内的 4D NIfTI'), text);
  assert.ok(text.includes('提示：') && text.includes('完整重跑请先恢复原始数据'), text);
});

await check('只有 FunImg 时提示删初始点为原地操作', () => {
  rmSync(path.join(here, 'tmp_scan_history'), { recursive: true, force: true });
  for (const id of ['sub-A', 'sub-B']) mkdirSync(path.join(fixture, 'FunImg', id), { recursive: true });
  const history = buildProcessingHistory(fixture, { startingDirName: 'FunImg' });
  assert.deepEqual(history.chain, ['FunImg']);
  const text = renderProcessingHistory(history).join('\n');
  assert.ok(text.includes('FunImg：功能像 NIfTI 起始数据'), text);
  assert.ok(text.includes('「删除初始时间点」会原地改写此目录'), text);
  assert.ok(text.includes('完整重跑前请先恢复原始数据'), text);
});

await check('没有功能像目录（如 BIDS/空目录）时不输出说明，也不抛异常', () => {
  rmSync(path.join(here, 'tmp_scan_history'), { recursive: true, force: true });
  mkdirSync(path.join(fixture, 'RealignParameter', 'sub-A'), { recursive: true });
  const history = buildProcessingHistory(fixture);
  assert.deepEqual(history.stages, []);
  assert.deepEqual(history.chain, []);
  assert.deepEqual(renderProcessingHistory(history), []);
  assert.deepEqual(renderProcessingHistory(undefined), []);
});

await check('FunRaw（DICOM 原始目录）也能被识别与说明', () => {
  rmSync(path.join(here, 'tmp_scan_history'), { recursive: true, force: true });
  for (const id of ['sub-A', 'sub-B']) mkdirSync(path.join(fixture, 'FunRaw', id), { recursive: true });
  const decoded = decodeDparsfFunDir('FunRaw');
  assert.equal(decoded.base, 'FunRaw');
  const history = buildProcessingHistory(fixture, { startingDirName: 'FunRaw' });
  assert.deepEqual(history.chain, ['FunRaw']);
  const text = renderProcessingHistory(history).join('\n');
  assert.ok(text.includes('原始功能像（DICOM）目录'), text);
});

rmSync(path.join(here, 'tmp_scan_history'), { recursive: true, force: true });
console.log(`\n全部通过：${passed} 项检查`);
