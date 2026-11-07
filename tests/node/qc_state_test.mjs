// 人工 QC 窗口实时状态读取自测（mri_workbench_qcstate 工具 / /mri qcstate 命令）
// 运行: node tests/node/qc_state_test.mjs
// 不启动 DSH、不启动 MATLAB；用临时目录写合法/缺字段/损坏/过期/不存在的状态 JSON。
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { apply, readQcViewerState, renderQcState } from '../../index.mjs';

const tmpRoots = [];
// 隔离的空会话工作区：避免继承本机真实 .mri-workbench 运行状态，保证无参 workDir 的 workspace-fallback 分支可复现。
const workspace = makeWorkDir('workspace');

function makeWorkDir(label) {
  const dir = mkdtempSync(path.join(os.tmpdir(), `mri-qcstate-${label}-`));
  tmpRoots.push(dir);
  return dir;
}

function writeState(dir, data) {
  mkdirSync(path.join(dir, 'QC'), { recursive: true });
  const file = path.join(dir, 'QC', '.qcviewer_state.json');
  writeFileSync(file, typeof data === 'string' ? data : JSON.stringify(data, null, 2), 'utf8');
  return file;
}

function nowIso() {
  return new Date().toISOString();
}

/** 本地墙钟时间（不含时区），用于模拟 MATLAB nowIsoLocal 写出错误时区标记的现状。 */
function localWallClockIso() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function fullState(overrides = {}) {
  return {
    schema: 'mrw.qcviewer.state.v2',
    version: 2,
    updatedAt: nowIso(),
    workDir: '/data/MyStudy',
    modality: 'T1',
    modalityLabel: 'T1 原始像',
    subjectID: 'Sub01',
    subjectIndex: 1,
    subjectCount: 3,
    file: 'T1Img/Sub01/coT1.nii',
    viewMode: 'triple',
    activeOrientation: 'axial',
    crosshairVoxel: [32, 32, 15],
    crosshairWorld: [-0.5, 12.3, 8.4],
    crosshairDisplay: [-0.5, 12.3, 8.4],
    display: {
      mode: 'acpc',
      hasVolume: true,
      matrix: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
      acVoxel: [32, 32, 18],
      pcVoxel: [32, 32, 10],
      acWorld: [0, 0, 0],
      pcWorld: [0, 18, 0],
      distanceMm: 18,
      angleDeg: 0,
      manualTranslationMm: [0, 0, 0],
      manualRotationDeg: [0, 0, 0],
      flips: { lr: false, ap: false, is: false },
      message: '',
    },
    slices: { axial: { index: 15, count: 30 }, coronal: { index: 32, count: 64 }, sagittal: { index: 32, count: 64 } },
    window: [2, 98],
    clim: [0, 1000],
    colormap: 'gray',
    interp: 'linear',
    zoom: 1,
    crosshairVisible: true,
    overlay: { visible: true, alpha: 0.55, normKind: 'Fun' },
    score: { current: 3, saved: null },
    headMotion: {
      fdType: 'FD_Jenkinson',
      fdThreshold: 0.2,
      values: [0.01, 0.02, 0.31, 0.05],
      meanFD: 0.08,
      maxFD: 0.31,
      badFrames: [3],
      badRatio: 0.05,
      maxTranslation: 1.2,
      maxRotation: 0.6,
    },
    filter: 'all',
    sort: 'id',
    progress: { T1: { scored: 1, total: 3 }, Fun: { scored: 0, total: 3 }, Norm: { scored: 0, total: 3 } },
    message: '',
    ...overrides,
  };
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

function assertLossless(value, label, where = '$') {
  if (value === undefined) throw new Error(`${label}: undefined at ${where}`);
  if (typeof value === 'number') {
    assert.ok(Number.isFinite(value), `${label}: non-finite number at ${where} (${value})`);
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

// ---- mock DSH ctx：注册工具与命令，不启动真实 DSH -------------------
const tools = new Map();
const commands = new Map();
const ctx = {
  logger: { info() {}, warn() {}, error() {} },
  effect(fn) { fn(); return () => {}; },
  tools: { register(def) { tools.set(def.name, def); } },
  commands: { register(def) { commands.set(def.name, def); } },
  systemPrompt: { section() {} },
  get(name) { return name === 'workingDirectory' ? { ensure: async () => workspace } : undefined; },
};
apply(ctx);
const agent = { id: 'mock-qcstate-agent' };
const exec = { agent, signal: undefined };

async function callTool(name, args) {
  const def = tools.get(name);
  assert.ok(def, `工具未注册：${name}`);
  return def.execute(args ?? {}, exec);
}
async function callCommand(rawInput) {
  const command = commands.get('mri');
  assert.ok(command, '命令 /mri 未注册');
  return command.handler({ rawInput, agent, signal: undefined });
}

const fullDir = makeWorkDir('full');
writeState(fullDir, fullState());

try {
  // ------------------------------------------------------------------
  // 1. 工具 / 命令注册与描述
  // ------------------------------------------------------------------
  await check('工具 mri_workbench_qcstate 与 /mri qcstate 已注册，描述说明配合 matlab_snapshot', () => {
    assert.ok(tools.has('mri_workbench_qcstate'), '未注册 mri_workbench_qcstate');
    assert.ok(commands.has('mri'), '未注册 /mri 命令');
    const def = tools.get('mri_workbench_qcstate');
    assert.ok(def.description.includes('matlab_snapshot'), '工具描述未提到 matlab_snapshot');
    assert.ok(def.description.includes('qcviewer_state.json'), '工具描述未提到状态文件');
    assert.deepEqual(def.parameters.required, []);
    assert.ok(def.parameters.properties.workDir, '缺少 workDir 参数');
  });

  await check('/mri help 列出 qcstate 子命令', async () => {
    const help = await callCommand('help');
    assert.equal(help.kind, 'success');
    assert.ok(help.text.includes('/mri qcstate'), help.text);
  });

  // ------------------------------------------------------------------
  // 2. 合法 JSON（契约 §7 全字段）
  // ------------------------------------------------------------------
  await check('合法 JSON：全字段解析正确', () => {
    const res = readQcViewerState(fullDir);
    assert.equal(res.available, true);
    assert.equal(res.found, true);
    assert.equal(res.schema, 'mrw.qcviewer.state.v2');
    assert.equal(res.schemaMatches, true);
    assert.equal(res.version, 2);
    assert.equal(res.stale, false);
    assert.ok(Number.isFinite(res.ageMinutes) && res.ageMinutes >= 0 && res.ageMinutes < 5, `ageMinutes=${res.ageMinutes}`);
    assert.equal(res.stateFileRel, 'QC/.qcviewer_state.json');
    assert.equal(res.subject.id, 'Sub01');
    assert.equal(res.subject.index, 1);
    assert.equal(res.subject.count, 3);
    assert.equal(res.modality, 'T1');
    assert.equal(res.modalityLabel, 'T1 原始像');
    assert.equal(res.file, 'T1Img/Sub01/coT1.nii');
    assert.equal(res.view.mode, 'triple');
    assert.equal(res.view.modeLabel, '三正交');
    assert.equal(res.view.activeOrientation, 'axial');
    assert.deepEqual(res.crosshair.voxel, [32, 32, 15]);
    assert.deepEqual(res.crosshair.world, [-0.5, 12.3, 8.4]);
    assert.deepEqual(res.crosshair.display, [-0.5, 12.3, 8.4]);
    assert.deepEqual(res.slices.axial, { index: 15, count: 30 });
    assert.deepEqual(res.slices.coronal, { index: 32, count: 64 });
    assert.equal(res.display.mode, 'acpc');
    assert.equal(res.display.distanceMm, 18);
    assert.equal(res.display.angleDeg, 0);
    assert.deepEqual(res.display.acVoxel, [32, 32, 18]);
    assert.deepEqual(res.display.pcVoxel, [32, 32, 10]);
    assert.equal(res.display.matrix.length, 4);
    assert.deepEqual(res.viewSettings.window, [2, 98]);
    assert.deepEqual(res.viewSettings.clim, [0, 1000]);
    assert.equal(res.viewSettings.colormap, 'gray');
    assert.equal(res.viewSettings.interp, 'linear');
    assert.equal(res.viewSettings.zoom, 1);
    assert.equal(res.viewSettings.crosshairVisible, true);
    assert.equal(res.overlay.visible, true);
    assert.equal(res.overlay.alpha, 0.55);
    assert.equal(res.overlay.normKind, 'Fun');
    assert.equal(res.score.current, 3);
    assert.equal(res.score.saved, null);
    assert.equal(res.headMotion.fdType, 'FD_Jenkinson');
    assert.equal(res.headMotion.fdThreshold, 0.2);
    assert.equal(res.headMotion.valueCount, 4);
    assert.deepEqual(res.headMotion.values, [0.01, 0.02, 0.31, 0.05]);
    assert.deepEqual(res.headMotion.badFrames, [3]);
    assert.equal(res.headMotion.badFrameCount, 1);
    assert.ok(Math.abs(res.headMotion.meanFD - 0.08) < 1e-12);
    assert.equal(res.filter, 'all');
    assert.equal(res.filterLabel, '全部');
    assert.equal(res.sort, 'id');
    assert.equal(res.sortLabel, '受试者 ID');
    assert.deepEqual(res.progress.T1, { scored: 1, total: 3 });
    assert.deepEqual(res.progress.Norm, { scored: 0, total: 3 });
  });

  await check('合法 JSON：中文摘要包含关键字段', () => {
    const text = renderQcState(readQcViewerState(fullDir));
    for (const expected of [
      '人工 QC 窗口状态',
      '受试者：Sub01（第 1/3 名） · 模态 T1 原始像',
      '视图模式：三正交（活动方向：水平位（轴位））',
      '十字线：体素 (32, 32, 15)；世界 (-0.50, 12.30, 8.40) mm；显示 (-0.50, 12.30, 8.40) mm',
      '显示模式：AC-PC 配平；AC-PC 距离 18.00 mm；配平角度 0.00°',
      '显示矩阵（4x4',
      '显示设置：窗宽 2–98%',
      '模板轮廓叠加：叠加显示，透明度 0.55，标准化图 Fun',
      '评分：当前 3 分；已保存 —',
      '头动/曲线：FD 类型 FD_Jenkinson；阈值 0.20 mm；MeanFD 0.080',
      '坏帧 1/4（5.0%）',
      '筛选/排序：全部 / 受试者 ID',
      '评分进度：T1 1/3；Fun 0/3；Norm 0/3',
      '只影响显示，不改写 NIfTI',
    ]) {
      assert.ok(text.includes(expected), `摘要缺少：${expected}\n---\n${text}`);
    }
  });

  // ------------------------------------------------------------------
  // 3. 工具 / 命令真实执行（mock ctx，同一份实现代码）
  // ------------------------------------------------------------------
  await check('工具 mri_workbench_qcstate：返回结构化 JSON + 渲染文本', async () => {
    const res = await callTool('mri_workbench_qcstate', { workDir: fullDir });
    assert.equal(res.ok, true);
    assert.equal(res.available, true);
    assert.equal(res.action, 'qcstate');
    assert.equal(res.workDirSource, 'argument');
    assert.equal(res.subject.id, 'Sub01');
    assert.equal(res.display.distanceMm, 18);
    assertLossless(res, 'mri_workbench_qcstate 返回');
    const def = tools.get('mri_workbench_qcstate');
    const rendered = def.output.render({}, res);
    assert.ok(Array.isArray(rendered) && rendered[0].type === 'text');
    assert.ok(rendered[0].text.includes('人工 QC 窗口状态'));
    assert.ok(rendered[0].text.includes('Sub01'));
  });

  await check('/mri qcstate 命令输出中文摘要', async () => {
    const result = await callCommand(`qcstate "${fullDir}"`);
    assert.equal(result.kind, 'success');
    assert.ok(result.text.includes('人工 QC 窗口状态'), result.text);
    assert.ok(result.text.includes('Sub01'));
    assert.ok(result.text.includes('AC-PC 距离 18.00 mm'));
    assert.ok(result.text.includes('FD_Jenkinson'));
  });

  // ------------------------------------------------------------------
  // 4. 缺字段：容错读取、不崩溃、显示「—」
  // ------------------------------------------------------------------
  await check('缺字段 JSON：available=true、缺失字段为 null、摘要不崩溃', () => {
    const dir = makeWorkDir('partial');
    writeState(dir, { schema: 'mrw.qcviewer.state.v2', updatedAt: nowIso() });
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.subject.id, null);
    assert.equal(res.display.mode, null);
    assert.equal(res.view.mode, null);
    assert.equal(res.headMotion.valueCount, 0);
    assert.equal(res.score.current, null);
    const text = renderQcState(res);
    assert.ok(text.includes('人工 QC 窗口状态'));
    assert.ok(text.includes('受试者：—'));
    assert.ok(text.includes('十字线：体素 (—)'));
  });

  // ------------------------------------------------------------------
  // 5. 损坏 JSON
  // ------------------------------------------------------------------
  await check('损坏 JSON：available=false、中文友好提示、摘要给出怎么做', () => {
    const dir = makeWorkDir('broken');
    writeState(dir, '{ "schema": "mrw.qcviewer.state.v2", "subjectID": "Sub01"');
    const res = readQcViewerState(dir);
    assert.equal(res.available, false);
    assert.equal(res.found, true);
    assert.ok(res.message.includes('JSON 解析失败'), res.message);
    const text = renderQcState(res);
    assert.ok(text.includes('人工 QC 窗口状态'));
    assert.ok(text.includes('怎么做'));
    assert.ok(text.includes('复制状态给 Agent'));
  });

  // ------------------------------------------------------------------
  // 6. 过期（updatedAt > 30 分钟）
  // ------------------------------------------------------------------
  await check('过期状态：stale=true、仍可读、摘要明确提示过期', () => {
    const dir = makeWorkDir('stale');
    const old = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
    writeState(dir, fullState({ updatedAt: old }));
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.stale, true);
    assert.ok(res.ageMinutes > 100, `ageMinutes=${res.ageMinutes}`);
    assert.ok(res.warnings.some((warning) => warning.includes('未更新')), JSON.stringify(res.warnings));
    assert.equal(res.message, '状态文件已过期：MATLAB 人工 QC 窗口可能已关闭或未再操作');
    const text = renderQcState(res);
    assert.ok(text.includes('超过 30 分钟未更新'), text);
    assert.ok(text.includes('仅供参考'));
  });

  await check('过期阈值可配置：maxAgeMinutes=1 时刚写入也可能过期', () => {
    const dir = makeWorkDir('stale-cfg');
    writeState(dir, fullState({ updatedAt: new Date(Date.now() - 2 * 60 * 1000).toISOString() }));
    assert.equal(readQcViewerState(dir).stale, false);
    assert.equal(readQcViewerState(dir, { maxAgeMinutes: 1 }).stale, true);
  });

  // ------------------------------------------------------------------
  // 7. 状态文件不存在 / 工作目录不存在
  // ------------------------------------------------------------------
  await check('状态文件不存在：中文提示「未打开或尚未操作」+ 操作建议', () => {
    const dir = makeWorkDir('empty');
    const res = readQcViewerState(dir);
    assert.equal(res.available, false);
    assert.equal(res.found, false);
    assert.ok(res.message.includes('.qcviewer_state.json'), res.message);
    assert.ok(res.message.includes('未打开或尚未操作'), res.message);
    const text = renderQcState(res);
    assert.ok(text.includes('状态文件：QC/.qcviewer_state.json（不存在）'));
    assert.ok(text.includes('/mri qc'));
  });

  await check('工具：状态文件不存在时 ok=true/available=false（不抛异常）', async () => {
    const dir = makeWorkDir('empty2');
    const res = await callTool('mri_workbench_qcstate', { workDir: dir });
    assert.equal(res.ok, true);
    assert.equal(res.available, false);
    assert.ok(res.message.includes('未打开或尚未操作'));
  });

  await check('工作目录不存在：命令与工具都返回中文提示而不崩溃', async () => {
    const missing = path.join(os.tmpdir(), 'mri-qcstate-does-not-exist-xyz');
    const byCommand = await callCommand(`qcstate "${missing}"`);
    assert.equal(byCommand.kind, 'success');
    assert.ok(byCommand.text.includes('工作目录不可用'), byCommand.text);
    const byTool = await callTool('mri_workbench_qcstate', { workDir: missing });
    assert.equal(byTool.ok, false);
    assert.equal(byTool.available, false);
    assert.ok(byTool.message.includes('工作目录不可用'), byTool.message);
  });

  await check('工具：未传 workDir 时按最近配置/会话工作区推导（不抛异常）', async () => {
    const res = await callTool('mri_workbench_qcstate', {});
    assert.equal(res.ok, true);
    assert.equal(typeof res.available, 'boolean');
    assert.ok(res.workDir);
    assert.ok(res.workDirSource);
    if (res.workDirSource === 'workspace-fallback') {
      assert.ok(res.warnings.some((warning) => warning.includes('当前会话工作区')), JSON.stringify(res.warnings));
    }
    assert.ok(renderQcState(res).includes('人工 QC 窗口状态'));
  });

  // ------------------------------------------------------------------
  // 8. schema 版本不匹配 / 实际实现与契约有偏差时的容错
  // ------------------------------------------------------------------
  await check('schema 不匹配：仍按兼容方式读取并给出提醒', () => {
    const dir = makeWorkDir('schema');
    writeState(dir, fullState({ schema: 'mrw.qcviewer.state.v1' }));
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.schemaMatches, false);
    assert.equal(res.subject.id, 'Sub01');
    assert.ok(res.warnings.some((warning) => warning.includes('schema=mrw.qcviewer.state.v1')), JSON.stringify(res.warnings));
    assert.ok(renderQcState(res).includes('已兼容读取'));
  });

  await check('字段偏差容错：嵌套 crosshair / FD / display.acpc / view.slices / 中文视图名', () => {
    const dir = makeWorkDir('variant');
    writeState(dir, {
      schema: 'mrw.qcviewer.state.v2',
      version: 2,
      updatedAt: nowIso(),
      subjectID: 'Sub02',
      modality: 'T1',
      viewMode: '三正交',
      activeOrientation: '水平位',
      crosshair: { voxel: [10, 20, 30], world: [1, 2, 3], display: [4, 5, 6] },
      view: { slices: { axial: { index: 10, count: 20 } } },
      display: {
        mode: 'acpc',
        acpc: { distanceMm: 22.5, angleDeg: 3.2, acWorld: [0, 0, 0], pcWorld: [0, 22.5, 0] },
      },
      FD: {
        fdType: 'FD_Power',
        fdThreshold: 0.5,
        values: [0.1, 0.6, 0.02, 0.7],
        meanFD: 0.1,
        badFrames: [2, 4],
      },
      window: { low: 5, high: 95 },
      score: 4,
      filter: '仅未评分',
      sort: '评分↓',
    });
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.view.mode, 'triple');
    assert.equal(res.view.modeLabel, '三正交');
    assert.equal(res.view.activeOrientation, 'axial');
    assert.deepEqual(res.crosshair.voxel, [10, 20, 30]);
    assert.deepEqual(res.crosshair.world, [1, 2, 3]);
    assert.deepEqual(res.crosshair.display, [4, 5, 6]);
    assert.deepEqual(res.slices.axial, { index: 10, count: 20 });
    assert.equal(res.display.mode, 'acpc');
    assert.equal(res.display.distanceMm, 22.5);
    assert.equal(res.display.angleDeg, 3.2);
    assert.equal(res.headMotion.fdType, 'FD_Power');
    assert.deepEqual(res.headMotion.badFrames, [2, 4]);
    assert.equal(res.headMotion.badFrameCount, 2);
    assert.deepEqual(res.viewSettings.window, [5, 95]);
    assert.equal(res.score.current, 4);
    assert.equal(res.filter, 'unscored');
    assert.equal(res.filterLabel, '仅未评分');
    assert.equal(res.sort, 'scoredesc');
    assert.equal(res.sortLabel, '评分↓');
    const text = renderQcState(res);
    assert.ok(text.includes('仅未评分'), text);
    assert.ok(text.includes('评分↓'), text);
  });

  await check('字段偏差容错：面板实际取值（filter=meanfd / sort=score_desc/meanfd_desc 等）', () => {
    const cases = [
      { filter: 'meanfd', sort: 'score_desc', filterKey: 'fd', sortKey: 'scoredesc', filterLabel: 'MeanFD 超阈值', sortLabel: '评分↓' },
      { filter: 'low', sort: 'meanfd_desc', filterKey: 'low', sortKey: 'meanfddesc', filterLabel: '低分（≤阈值）', sortLabel: 'MeanFD↓' },
      { filter: 'scored', sort: 'score_asc', filterKey: 'scored', sortKey: 'scoreasc', filterLabel: '已评分', sortLabel: '评分↑' },
      { filter: 'unscored', sort: 'meanfd_asc', filterKey: 'unscored', sortKey: 'meanfdasc', filterLabel: '仅未评分', sortLabel: 'MeanFD↑' },
      { filter: 'all', sort: 'id', filterKey: 'all', sortKey: 'id', filterLabel: '全部', sortLabel: '受试者 ID' },
    ];
    for (const item of cases) {
      const dir = makeWorkDir('panel-values');
      writeState(dir, fullState({ filter: item.filter, sort: item.sort }));
      const res = readQcViewerState(dir);
      assert.equal(res.filter, item.filterKey, `filter=${item.filter}`);
      assert.equal(res.filterLabel, item.filterLabel, `filter=${item.filter}`);
      assert.equal(res.sort, item.sortKey, `sort=${item.sort}`);
      assert.equal(res.sortLabel, item.sortLabel, `sort=${item.sort}`);
    }
  });

  await check('updatedAt 时区标记错误（-00:00，MATLAB nowIsoLocal 现状）：按本地时间解读并提醒', () => {
    const dir = makeWorkDir('tz-bug');
    writeState(dir, fullState({ updatedAt: `${localWallClockIso()}-00:00` }));
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.stale, false);
    assert.ok(Number.isFinite(res.ageMinutes), `ageMinutes=${res.ageMinutes}`);
    assert.ok(res.ageMinutes >= -5 && res.ageMinutes < 10, `ageMinutes=${res.ageMinutes}`);
    if (new Date().getTimezoneOffset() !== 0) {
      assert.ok(res.warnings.some((warning) => warning.includes('时区标记')), JSON.stringify(res.warnings));
      assert.ok(renderQcState(res).includes('时区标记'), renderQcState(res).slice(0, 600));
    }
  });

  await check('updatedAt 缺失：退回文件修改时间并提醒', () => {
    const dir = makeWorkDir('no-time');
    const state = fullState();
    delete state.updatedAt;
    writeState(dir, state);
    const res = readQcViewerState(dir);
    assert.equal(res.available, true);
    assert.equal(res.updatedAtSource, 'file-mtime');
    assert.ok(res.warnings.some((warning) => warning.includes('updatedAt')), JSON.stringify(res.warnings));
    assert.ok(Number.isFinite(res.ageMinutes));
  });

  await check('合法 JSON：JSON 可无损序列化（工具输出约束）', async () => {
    const res = await callTool('mri_workbench_qcstate', { workDir: fullDir });
    assertLossless(res, '工具输出');
    const roundtrip = JSON.parse(JSON.stringify(res));
    assert.deepEqual(roundtrip, res);
  });

  // ------------------------------------------------------------------
  // 输出样例（便于人工检查）
  // ------------------------------------------------------------------
  console.log('\n================ 渲染样例：合法状态 ================');
  console.log(renderQcState(readQcViewerState(fullDir)));
  console.log('\n================ 渲染样例：状态文件不存在 ================');
  console.log(renderQcState(readQcViewerState(makeWorkDir('sample-empty'))));

  console.log(`\n全部通过：${passed} 项检查`);
} finally {
  for (const dir of tmpRoots) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* 清理失败不影响测试结论 */
    }
  }
}
