// 「⑤ 头动结果解读与可视化」卡片接线自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/results_card_test.mjs
//
// 验证：点「读取并解读结果」后渲染每名受试者指标表格、逐帧 FD 曲线 SVG、中文解释；
//       点击表格行切换曲线受试者；切换参考阈值会重新请求 resultsjson。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const commands = [];

// ---------------- 最小 React 假实现（hooks 顺序模型） ----------------
let hookStates = [];
let hookIndex = 0;
const React = {
  createElement(type, props, ...children) {
    const flat = children.flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false);
    return { type, props: props || {}, children: flat };
  },
  useState(initial) {
    const i = hookIndex++;
    if (!(i in hookStates)) hookStates[i] = typeof initial === 'function' ? initial() : initial;
    const set = (value) => {
      hookStates[i] = typeof value === 'function' ? value(hookStates[i]) : value;
    };
    return [hookStates[i], set];
  },
  useMemo(fn) {
    hookIndex += 1;
    return fn();
  },
  useEffect() {
    hookIndex += 1;
  },
  useRef(initial) {
    const i = hookIndex++;
    if (!(i in hookStates)) hookStates[i] = { current: initial };
    return hookStates[i];
  },
};

let slotComponent = null;
const fakeWindow = {
  addEventListener() {},
  removeEventListener() {},
  __ModuleLoader__: {
    load({ factory }) {
      const mod = factory((name) => (name === 'react' ? React : {}));
      mod.apply(fakeCtx);
    },
  },
};
globalThis.window = fakeWindow;
globalThis.btoa = (s) => Buffer.from(s, 'binary').toString('base64');

// ---------------- 假的 /mri resultsjson 结果（结构同 Host） ----------------
function cannedResults(threshold) {
  const th = Number(threshold) || 0.2;
  const subject = (id, meanFD, level, label, jen, power) => ({
    id,
    metrics: {
      meanFDJenkinson: meanFD,
      meanFDPower: meanFD * 1.8,
      nFDPower02: 2,
      pctFDPower02: 0.2,
      maxTx: 0.5,
    },
    maxTranslation: 0.5,
    maxRotation: 0.3,
    frames: jen.length,
    grades: {
      maxTranslation: { level: 'ok', label: '≤1.0 mm 可接受' },
      maxRotation: { level: 'attention', label: '1.0–2.0° 需关注' },
      badFrameRatio: { level: 'warn', label: '15–30% 偏高' },
    },
    verdict: { level, label, reasons: [`mean FD_Jenkinson ${meanFD.toFixed(3)} mm（参考阈值 ${th} mm）`], threshold: th },
    series: { jenkinson: jen, power },
  });
  const subjects = [
    subject('SubA', 0.05, 'ok', '头动较小', [0, 0.03, 0.05, 0.02, 0.06], [0, 0.05, 0.08, 0.03, 0.09]),
    subject('SubB', 0.18, 'attention', '处于常见可接受范围', [0, 0.10, 0.22, 0.08, 0.15], [0, 0.15, 0.35, 0.12, 0.24]),
    subject('SubC', 0.30, 'warn', '偏大，建议关注', [0, 0.20, 0.42, 0.18, 0.35], [0, 0.30, 0.62, 0.28, 0.52]),
  ];
  return {
    ok: true,
    available: true,
    workDir: '/mock/MyStudy',
    threshold: th,
    message: '已读取 3 名受试者的头动指标与逐帧 FD 曲线',
    summary: {
      count: 3,
      mean: (0.05 + 0.18 + 0.3) / 3,
      median: 0.18,
      max: 0.3,
      min: 0.05,
      threshold: th,
      overThreshold: th <= 0.3 ? ['SubC'] : [],
      worstSubject: 'SubC',
    },
    defaultSubjectId: 'SubC',
    subjects,
    files: { headMotionTsv: '/mock/RealignParameter/HeadMotion.tsv' },
    explanations: {
      overview: [
        '这些数字来自 DPARSF 头动校正后的 RealignParameter/HeadMotion.tsv 与逐帧 FD 文件。',
        'mean FD_Jenkinson 是相邻帧相对位移的均方根（mm），DPABI 常用 0.2 mm 作为参考阈值。',
        '表格中的 Number/Percent of FD_Power>0.2/0.5 表示超过常用坏点阈值的帧数与占比。',
      ],
      thresholdNote: '参考阈值：mean FD_Jenkinson 常用 0.2 mm。',
    },
    excludedByMaxMotion: [{ criteria: '1.0mm and 1.0 degree in max head motion', subjects: ['SubC'] }],
    references: {
      maxTranslation: { label: '最大平移', unit: 'mm', tiers: [{ level: 'ok', label: '≤1.0 mm 可接受' }, { level: 'attention', label: '1.0–2.0 mm 需关注' }, { level: 'warn', label: '2.0–3.0 mm 偏大' }, { level: 'bad', label: '>3.0 mm 较大' }] },
      maxRotation: { label: '最大旋转', unit: '°', tiers: [{ level: 'ok', label: '≤1.0° 可接受' }, { level: 'attention', label: '1.0–2.0° 需关注' }] },
      badFrameRatio: { label: '坏帧比例（FD_Power>0.2）', unit: '%', tiers: [{ level: 'ok', label: '≤5% 少' }, { level: 'attention', label: '5–15% 中等' }] },
      gradingNote: '以上只用于快速定位需要回看的受试者。',
    },
    scrubbing: {
      notes: [
        'Scrubbing（censor）= 按逐帧 FD 阈值标记坏帧，再在指标计算/回归阶段剔除或插值。',
        'DPABI 做法一：Cfg.IsScrubbing=1 + Scrubbing.FDType/FDThreshold/ScrubbingMethod。',
      ],
    },
    warnings: [],
  };
}

// ---------------- 假 DSH Client ctx ----------------
const T_MAP = {
  'res.title': '⑤ 头动结果解读与可视化',
  'res.load': '读取并解读结果',
  'res.refresh': '刷新结果',
  'res.threshold': 'MeanFD 参考阈值',
  'res.summaryTitle': '总体情况',
  'res.tableTitle': '每名受试者的头动指标',
  'res.chartTitle': '逐帧 FD 曲线',
  'res.explainTitle': '这些数字怎么看？',
  'res.colSubject': '受试者',
  'res.colMeanFD': 'mean FD_Jenkinson (mm)',
  'res.colMeanFDPower': 'mean FD_Power (mm)',
  'res.colMaxTrans': '最大平移 (mm)',
  'res.colMaxRot': '最大旋转 (°)',
  'res.colBadFrames': 'FD_Power>0.2 帧数/占比',
  'res.colVerdict': '提示',
  'res.overThreshold': 'MeanFD ≥ 阈值',
  'res.none': '无',
  'res.frames': '帧',
  'res.metric': '曲线指标',
  'res.subjectsPick': '选择受试者（可多选）',
  'res.selectAll': '全选',
  'res.clearAll': '清空选择',
  'res.noneSelected': '请至少勾选一名受试者查看 FD 曲线。',
  'res.chartHint': '可勾选/点击多名受试者叠加对比',
  'res.autoHint': '页面会自动读取最近一次配置的工作目录',
  'res.unavailable': '未找到头动结果',
  'res.gradingTitle': '经验分级参考（启发式，不是诊断/入组标准）',
  'res.censorTitle': '坏帧 / Scrubbing（censor）',
  'res.censorFdType': 'FD 类型',
  'res.censorThreshold': '每帧阈值',
  'res.censorPrevious': '向前扩展帧数',
  'res.censorLater': '向后扩展帧数',
  'res.scrubMethod': 'Scrubbing 方式',
  'res.scrubSpike': 'spike · 每坏帧一个回归量（不缩短序列）',
  'res.spikeHint': 'Spike 回归 = 为每个坏帧单独建立一个回归量（DPABI：Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*），不删除/插值时间点；需流程包含协变量回归步骤。与 IsScrubbing 互斥。',
  'res.spikeApplied': '已写入 Spike 回归参数覆盖（Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*）；下次「生成配置并校验」后生效。',
  'res.censorPreview': '坏帧预览（帧号 = 删初始点后 1-based，含前/后扩展）',
  'res.censorExport': '导出坏帧清单',
  'res.censorApply': '写入 scrubbing 参数覆盖',
  'res.censorBusy': '处理中…',
  'res.censorExported': '已导出：',
  'res.censorApplied': '已写入 scrubbing 参数覆盖（IsScrubbing=1）；下次「生成配置并校验」后生效。',
  'res.censorHint': '坏帧 = 逐帧 FD 超过所选阈值的帧',
  'res.censorEmpty': '当前阈值下没有坏帧。',
  'res.censorSampled': '注意：曲线点经过抽样，帧号为近似值；导出清单由 Host 用完整序列计算。',
  'res.colCensorSubject': '受试者',
  'res.colCensorCount': '坏帧数',
  'res.colCensorPct': '坏帧比例',
  'res.colCensorFrames': '前 12 个帧号',
  'res.error': '头动结果读取失败：',
};
let mockOverrides = [{ key: 'TR', value: 2.5 }];
const overridePayloads = [];
const fakeCtx = {
  effect(fn) { fn(); },
  locale: {
    register() {},
    bind() { return (key) => (key in T_MAP ? T_MAP[key] : key); },
  },
  slots: {
    inject(_name, fn) { fn(); },
    register(_def, component) { slotComponent = component; },
  },
  remote: {
    commands: {
      async execute(_sessionId, line) {
        commands.push(line);
        let text = '';
        if (line.startsWith('/mri resultsjson')) {
          const tokens = line.split(/\s+/);
          const threshold = Number(tokens[2]);
          text = JSON.stringify(cannedResults(Number.isFinite(threshold) ? threshold : 0.2));
        } else if (line.startsWith('/mri paramsjson')) {
          text = JSON.stringify({ ok: true, count: 97, total: 97, groups: [], entries: [], overrides: mockOverrides });
        } else if (line.startsWith('/mri overrides set ')) {
          const b64 = line.slice('/mri overrides set '.length).trim();
          mockOverrides = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
          overridePayloads.push(mockOverrides);
          text = `参数覆盖：${mockOverrides.length} 项`;
        } else if (line.startsWith('/mri censor')) {
          text = 'DPARSF Scrubbing / Censor 坏帧清单\n- 状态：已导出\n已导出：/mock/ScrubbingPreview/FD_Jenkinson_0p2mm\n汇总表：/mock/ScrubbingPreview/FD_Jenkinson_0p2mm/censor_summary.tsv';
        }
        return { ok: true, value: { result: { kind: 'success', text } } };
      },
    },
  },
};

// 加载 client.js
const clientSource = readFileSync(path.join(repoRoot, 'client.js'), 'utf8');
new Function('window', 'require', clientSource)(fakeWindow, (name) => (name === 'react' ? React : {}));
assert.ok(slotComponent, 'slot 组件未注册');
const props = { sessionId: 'mock-session', ctx: fakeCtx };

function expand(node) {
  if (node === null || node === undefined) return node;
  if (typeof node === 'string' || typeof node === 'number') return node;
  if (typeof node !== 'object') return node;
  if (typeof node.type === 'function') return expand(node.type(node.props || {}));
  return Object.assign({}, node, { children: (node.children || []).map(expand) });
}
function render() {
  hookIndex = 0;
  return expand(slotComponent(props));
}
function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  visit(node);
  for (const child of node.children || []) walk(child, visit);
}
function findAll(root, pred) {
  const out = [];
  walk(root, (n) => { if (pred(n)) out.push(n); });
  return out;
}
function textOf(node) {
  if (node === null || node === undefined) return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (typeof node !== 'object') return '';
  return (node.children || []).map(textOf).join(' ');
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

let tree = render();
const findLoadBtn = (root) => findAll(root, (n) => n.type === 'button' && n.props['data-action'] === 'results-load')[0];

await check('⑤ 卡片已渲染：标题、阈值选择、读取按钮与说明', () => {
  assert.ok(textOf(tree).includes('⑤ 头动结果解读与可视化'));
  assert.ok(findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-fd-threshold').length === 1);
  assert.ok(findLoadBtn(tree), '缺少读取按钮');
  assert.ok(textOf(tree).includes('只读文件，不启动 MATLAB') || textOf(tree).includes('res.hint'));
});

await check('点击「读取并解读结果」后渲染表格、曲线与解释（默认叠加全部受试者）', async () => {
  await findLoadBtn(tree).props.onClick();
  tree = render();
  assert.ok(commands.some((l) => l.startsWith('/mri resultsjson')), '未请求 resultsjson');
  const table = findAll(tree, (n) => n.type === 'table' && n.props['data-role'] === 'results-table')[0];
  assert.ok(table, '缺少结果表格');
  const rows = findAll(table, (n) => n.type === 'tr' && n.props['data-subject']);
  assert.deepEqual(rows.map((r) => r.props['data-subject']), ['SubC', 'SubB', 'SubA']);
  assert.ok(textOf(table).includes('0.300'), '表格缺少 SubC 的 mean FD');
  assert.ok(findAll(tree, (n) => n.type === 'svg').length >= 1, '缺少 FD 曲线 SVG');
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 3, '默认应叠加 3 名受试者的曲线');
  const text = textOf(tree);
  assert.ok(text.includes('组均值 mean FD_Jenkinson'), '缺少组摘要');
  assert.ok(text.includes('mean FD_Jenkinson 是相邻帧相对位移的均方根'), '缺少逐列解释');
  assert.ok(text.includes('已选 3 名受试者'), '缺少叠加受试者计数');
});

await check('勾选/取消受试者与点击表格行可多选切换曲线', () => {
  const labelB = findAll(tree, (n) => n.type === 'label' && n.props['data-subject-check'] === 'SubB')[0];
  assert.ok(labelB, '缺少受试者勾选框');
  const box = findAll(labelB, (n) => n.type === 'input')[0];
  box.props.onChange();
  tree = render();
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 2, '取消 SubB 后应剩 2 条曲线');
  assert.ok(textOf(tree).includes('已选 2 名受试者'));

  const table = findAll(tree, (n) => n.type === 'table' && n.props['data-role'] === 'results-table')[0];
  const rowB = findAll(table, (n) => n.type === 'tr' && n.props['data-subject'] === 'SubB')[0];
  rowB.props.onClick();
  tree = render();
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 3, '点击行重新加入 SubB 后应恢复 3 条曲线');
});

await check('切换曲线指标 FD_Jenkinson / FD_Power 不需要重新读取文件', () => {
  const before = commands.filter((l) => l.startsWith('/mri resultsjson')).length;
  const metric = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-fd-metric')[0];
  assert.ok(metric, '缺少曲线指标选择器');
  metric.props.onChange({ target: { value: 'power' } });
  tree = render();
  const chart = findAll(tree, (n) => n.type === 'div' && n.props['data-role'] === 'results-chart')[0];
  assert.ok(textOf(chart).includes('FD_Power（mm/帧）'), '曲线未切换到 FD_Power');
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 3);
  const after = commands.filter((l) => l.startsWith('/mri resultsjson')).length;
  assert.equal(after, before, '切换指标不应重新请求 resultsjson');
});

await check('全选 / 清空选择按钮生效', () => {
  const clearBtn = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'subjects-none')[0];
  assert.ok(clearBtn, '缺少清空选择按钮');
  clearBtn.props.onClick();
  tree = render();
  assert.ok(findAll(tree, (n) => n.props['data-role'] === 'results-chart-empty').length === 1, '清空后应显示提示');
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 0);

  const allBtn = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'subjects-all')[0];
  allBtn.props.onClick();
  tree = render();
  assert.equal(findAll(tree, (n) => n.type === 'polyline').length, 3, '全选后应恢复 3 条曲线');
});

await check('切换参考阈值会重新请求并更新显示', async () => {
  const before = commands.filter((l) => l.startsWith('/mri resultsjson')).length;
  const select = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-fd-threshold')[0];
  await select.props.onChange({ target: { value: '0.5' } });
  tree = render();
  const after = commands.filter((l) => l.startsWith('/mri resultsjson')).length;
  assert.equal(after, before + 1, '阈值切换未重新请求');
  assert.ok(commands.some((l) => l.trim() === '/mri resultsjson 0.5'), '请求未带阈值 0.5');
  assert.ok(textOf(tree).includes('阈值 0.5 mm'), '摘要未显示新阈值');
  const chart = findAll(tree, (n) => n.type === 'div' && n.props['data-role'] === 'results-chart')[0];
  assert.ok(textOf(chart).includes('0.50 mm'), '曲线阈值线未更新');
});

await check('经验分级参考与表格分级着色已渲染', () => {
  const grading = findAll(tree, (n) => n.props['data-role'] === 'results-grading')[0];
  assert.ok(grading, '缺少经验分级参考区块');
  const gradingText = textOf(grading);
  assert.ok(gradingText.includes('最大平移'), '缺少最大平移分级');
  assert.ok(gradingText.includes('≤1.0 mm 可接受'), '缺少平移分级档位');
  assert.ok(gradingText.includes('坏帧比例'), '缺少坏帧比例分级');
  const table = findAll(tree, (n) => n.type === 'table' && n.props['data-role'] === 'results-table')[0];
  const colored = findAll(table, (n) => n.type === 'span' && typeof n.props.style === 'object' && typeof n.props.style.color === 'string' && n.props.title);
  assert.ok(colored.length >= 3, '表格分级单元格未着色');
});

const getCensorRow = (subjectId) => {
  const table = findAll(tree, (n) => n.type === 'table' && n.props['data-role'] === 'censor-table')[0];
  assert.ok(table, '缺少坏帧预览表');
  return findAll(table, (n) => n.type === 'tr' && n.props['data-censor-subject'] === subjectId)[0];
};

await check('坏帧预览按 FD 类型/阈值实时计算', () => {
  const table = findAll(tree, (n) => n.type === 'table' && n.props['data-role'] === 'censor-table')[0];
  assert.ok(table, '缺少坏帧预览表');
  // 默认 FD_Jenkinson / 0.2 mm：SubB 第 3 帧 0.22>0.2；SubC 第 3、5 帧 0.42/0.35>0.2；SubA 无
  assert.ok(textOf(getCensorRow('SubB')).includes('3'), 'SubB 坏帧未计算');
  const subC = textOf(getCensorRow('SubC'));
  assert.ok(subC.includes('3, 5'), `SubC 坏帧号不对：${subC}`);
  assert.ok(textOf(getCensorRow('SubA')).includes('0'), 'SubA 应无坏帧');

  const typeSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-type')[0];
  const thresholdSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-threshold')[0];
  typeSelect.props.onChange({ target: { value: 'power' } });
  thresholdSelect.props.onChange({ target: { value: '0.5' } });
  tree = render();
  // FD_Power / 0.5 mm：SubC 第 3、5 帧（0.62/0.52），SubB 无
  assert.ok(textOf(getCensorRow('SubC')).includes('3, 5'), '切换 FD_Power/0.5 后 SubC 坏帧不对');
  assert.ok(textOf(getCensorRow('SubB')).includes('0'), '切换后 SubB 应无坏帧');
});

await check('坏帧预览支持向前/向后扩展帧数（对应 Scrubbing.PreviousPoints/LaterPoints）', () => {
  // 恢复 FD_Jenkinson / 0.2 mm
  findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-type')[0].props.onChange({ target: { value: 'jenkinson' } });
  findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-threshold')[0].props.onChange({ target: { value: '0.2' } });
  tree = render();
  const previousSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-previous')[0];
  const laterSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-censor-later')[0];
  assert.ok(previousSelect, '缺少向前扩展帧数选择器');
  assert.ok(laterSelect, '缺少向后扩展帧数选择器');
  assert.equal(previousSelect.props['data-action'], 'censor-previous');
  assert.equal(laterSelect.props['data-action'], 'censor-later');
  previousSelect.props.onChange({ target: { value: '1' } });
  laterSelect.props.onChange({ target: { value: '2' } });
  tree = render();
  // SubC 基础坏帧 3、5；前 1 / 后 2 扩展后为 2–5（序列仅 5 帧）；SubB 基础坏帧 3 → 2–5
  const subC = textOf(getCensorRow('SubC'));
  assert.ok(subC.includes('2, 3, 4, 5'), `SubC 扩展后坏帧号不对：${subC}`);
  const subCText = subC.replace(/\s+/g, ' ').trim();
  assert.ok(subCText.startsWith('SubC 4 80.0%'), `SubC 扩展后数量/占比不对：${subCText}`);
  assert.ok(textOf(getCensorRow('SubB')).includes('2, 3, 4, 5'), 'SubB 扩展后坏帧号不对');
  assert.ok(textOf(getCensorRow('SubA')).includes('0'), 'SubA 应仍无坏帧');
  assert.ok(textOf(tree).includes('含前/后扩展'), '预览标题未提示扩展');
});

await check('点击「导出坏帧清单」调用 /mri censor 并显示导出路径', async () => {
  const btnExport = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'censor-export')[0];
  assert.ok(btnExport, '缺少导出坏帧清单按钮');
  await btnExport.props.onClick();
  tree = render();
  assert.ok(commands.some((l) => l.trim() === '/mri censor jenkinson 0.2 prev=1 later=2'), '未在 /mri censor 命令中传入 prev/later');
  const notice = findAll(tree, (n) => n.props['data-role'] === 'censor-notice')[0];
  assert.ok(notice && textOf(notice).includes('ScrubbingPreview'), '未显示导出路径');
});

await check('「写入 scrubbing 参数覆盖」合并覆盖且保留其他参数', async () => {
  const btnApply = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'censor-apply')[0];
  assert.ok(btnApply, '缺少写入 scrubbing 参数覆盖按钮');
  await btnApply.props.onClick();
  tree = render();
  const payload = overridePayloads[overridePayloads.length - 1];
  assert.ok(payload, '未写入参数覆盖');
  assert.ok(payload.some((o) => o.key === 'IsScrubbing' && o.value === 1), '缺少 IsScrubbing=1');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.FDType' && o.value === 'FD_Jenkinson'), '缺少 Scrubbing.FDType');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.FDThreshold' && o.value === 0.2), '缺少 Scrubbing.FDThreshold');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.PreviousPoints' && o.value === 1), '缺少 Scrubbing.PreviousPoints');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.LaterPoints' && o.value === 2), '缺少 Scrubbing.LaterPoints');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.ScrubbingMethod' && o.value === 'cut'), '缺少 Scrubbing.ScrubbingMethod');
  assert.ok(payload.some((o) => o.key === 'TR' && o.value === 2.5), 'TR 覆盖被清掉');
});

await check('Scrubbing 方式含 spike 回归并写入头动 scrubbing 回归量参数覆盖', async () => {
  const methodSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-scrub-method')[0];
  assert.ok(methodSelect, '缺少 Scrubbing 方式选择器');
  const values = findAll(methodSelect, (n) => n.type === 'option').map((o) => o.props.value);
  assert.ok(values.includes('spike'), 'Scrubbing 方式缺少 spike 选项');
  methodSelect.props.onChange({ target: { value: 'spike' } });
  tree = render();
  const hint = findAll(tree, (n) => n.props['data-role'] === 'spike-hint')[0];
  assert.ok(hint && textOf(hint).includes('Covremove.IsHeadMotionScrubbingRegressors'), '选择 spike 后缺少回归量说明');
  const btnApply = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'censor-apply')[0];
  await btnApply.props.onClick();
  tree = render();
  const payload = overridePayloads[overridePayloads.length - 1];
  assert.ok(payload, '未写入 spike 参数覆盖');
  assert.ok(payload.some((o) => o.key === 'IsScrubbing' && o.value === 0), 'spike 模式应关闭 IsScrubbing');
  assert.ok(payload.some((o) => o.key === 'Covremove.IsHeadMotionScrubbingRegressors' && o.value === 1), '缺少 Covremove.IsHeadMotionScrubbingRegressors=1');
  assert.ok(payload.some((o) => o.key === 'Covremove.HeadMotionScrubbingRegressors.FDType' && o.value === 'FD_Jenkinson'), '缺少回归量 FDType');
  assert.ok(payload.some((o) => o.key === 'Covremove.HeadMotionScrubbingRegressors.FDThreshold' && o.value === 0.2), '缺少回归量 FDThreshold');
  assert.ok(payload.some((o) => o.key === 'Covremove.HeadMotionScrubbingRegressors.PreviousPoints' && o.value === 1), '缺少回归量 PreviousPoints');
  assert.ok(payload.some((o) => o.key === 'Covremove.HeadMotionScrubbingRegressors.LaterPoints' && o.value === 2), '缺少回归量 LaterPoints');
  assert.ok(!payload.some((o) => String(o.key).startsWith('Scrubbing.')), 'spike 模式不应再写 Scrubbing.* 方法');
  assert.ok(payload.some((o) => o.key === 'TR' && o.value === 2.5), 'TR 覆盖被清掉');
  const notice = findAll(tree, (n) => n.props['data-role'] === 'censor-notice')[0];
  assert.ok(notice && textOf(notice).includes('Spike 回归'), '未显示 spike 写入提示');
});

await check('切回常规 Scrubbing 方式会关闭回归量并重新写 IsScrubbing', async () => {
  const methodSelect = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-scrub-method')[0];
  methodSelect.props.onChange({ target: { value: 'cut' } });
  tree = render();
  const spikeHint = findAll(tree, (n) => n.props['data-role'] === 'spike-hint')[0];
  assert.equal(spikeHint, undefined, '切回 cut 后不应再显示 spike 提示');
  const btnApply = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'censor-apply')[0];
  await btnApply.props.onClick();
  tree = render();
  const payload = overridePayloads[overridePayloads.length - 1];
  assert.ok(payload.some((o) => o.key === 'IsScrubbing' && o.value === 1), 'cut 模式应启用 IsScrubbing');
  assert.ok(payload.some((o) => o.key === 'Scrubbing.ScrubbingMethod' && o.value === 'cut'), '缺少 ScrubbingMethod');
  assert.ok(payload.some((o) => o.key === 'Covremove.IsHeadMotionScrubbingRegressors' && o.value === 0), 'cut 模式应关闭回归量');
  assert.ok(!payload.some((o) => String(o.key).startsWith('Covremove.HeadMotionScrubbingRegressors.')), 'cut 模式不应残留回归量字段');
});

console.log(`\n全部通过：${passed} 项检查`);
