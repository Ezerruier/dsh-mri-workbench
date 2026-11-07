// 「T1 裁剪兼容模式」界面选择器 + prepare 文本提示自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/t1_crop_ui_test.mjs
//
// 覆盖：
//  1) client.js ② 预处理配置卡新增的「T1 裁剪兼容模式」下拉框（auto/old_dcm2nii/no_crop），
//     中文选项文案来自 zh 字典、hint 文案存在，位置在「并行 worker 数」之后；
//  2) 页面加载读取已保存覆盖并回显 T1CropCompat 当前值；
//  3) 选择 old_dcm2nii / no_crop 时写入的参数覆盖 payload 含 T1CropCompat 且保留其他覆盖（如 TR）；
//  4) 选择 auto 时移除 T1CropCompat 覆盖（其他覆盖保留）；
//  5) index.mjs renderPrepare：仅当 t1CropCompat 非 auto 时，在「将执行 N 步」之后输出
//     「- T1 裁剪兼容：<t1CropCompatLabel>（<t1CropPlan>）」。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { apply } from '../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');

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

// =====================================================================
// 第一部分：client.js 页面渲染（最小假 React + 假 DSH Client ctx）
// =====================================================================
let overrides = [{ key: 'TR', value: 2.5 }, { key: 'T1CropCompat', value: 'old_dcm2nii' }];
const commands = [];
const overridePayloads = [];
let registeredLocales = null;

// ---------------- 最小 React 假实现（hooks 顺序模型；useEffect 立即执行，用于测试首屏读取覆盖） ----------------
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
  useEffect(fn) {
    hookIndex += 1;
    if (typeof fn === 'function') fn();
  },
  useRef(initial) {
    const i = hookIndex++;
    if (!(i in hookStates)) hookStates[i] = { current: initial };
    return hookStates[i];
  },
};

// ---------------- 最小 window/ModuleLoader ----------------
let slotComponent = null;
const fakeWindow = {
  addEventListener() {},
  removeEventListener() {},
  __ModuleLoader__: {
    load({ factory }) {
      const mod = factory((name) => {
        if (name === 'react') return React;
        return {};
      });
      mod.apply(fakeCtx);
    },
  },
};
globalThis.window = fakeWindow;
globalThis.btoa = (s) => Buffer.from(s, 'binary').toString('base64');

// ---------------- 最小 DSH Client ctx（模拟 Host 会话覆盖状态；locale 用真实 zh 字典） ----------------
const fakeCtx = {
  effect(fn) { fn(); },
  locale: {
    register(name, dicts) { if (name === 'mriWorkbench') registeredLocales = dicts; },
    bind() {
      return (key) => {
        const zh = registeredLocales && registeredLocales.zh;
        return zh && typeof zh[key] === 'string' ? zh[key] : key;
      };
    },
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
        if (line.startsWith('/mri paramsjson')) {
          text = JSON.stringify({ ok: true, count: 98, total: 98, groups: [], entries: [], overrides });
        } else if (line.startsWith('/mri overrides set ')) {
          const b64 = line.slice('/mri overrides set '.length).trim();
          overrides = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
          overridePayloads.push(overrides);
          text = `参数覆盖：${overrides.length} 项\n已保存`;
        } else if (line.startsWith('/mri overrides clear')) {
          overrides = [];
          text = '参数覆盖：0 项';
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
// 等页面加载 useEffect 里的 /mri paramsjson 异步返回（microtask 队列）
async function settle(rounds = 16) {
  for (let i = 0; i < rounds; i += 1) await Promise.resolve();
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
const findT1CropSelect = (root) => findAll(root, (n) => n.type === 'select' && n.props.id === 'mrw-t1crop')[0];
const findWorkerSelect = (root) => findAll(root, (n) => n.type === 'select' && n.props.id === 'mrw-workers')[0];
const zh = (key) => (registeredLocales?.zh ? registeredLocales.zh[key] : undefined);
const en = (key) => (registeredLocales?.en ? registeredLocales.en[key] : undefined);

let tree = render();
await settle();
tree = render(); // 首屏 useEffect 读回已保存覆盖后的状态

await check('新增 zh/en 字典条目齐全', () => {
  const keys = ['prep.t1Crop', 'prep.t1CropHint', 'prep.t1CropAuto', 'prep.t1CropOldDcm2nii', 'prep.t1CropNoCrop'];
  for (const key of keys) {
    assert.ok(typeof zh(key) === 'string' && zh(key).length > 0, `zh 缺少 ${key}`);
    assert.ok(typeof en(key) === 'string' && en(key).length > 0, `en 缺少 ${key}`);
  }
  assert.notEqual(zh('prep.t1Crop'), en('prep.t1Crop'), '中英文标签不应相同');
});

await check('② 卡渲染「T1 裁剪兼容模式」下拉框且只有 3 个选项（auto/old_dcm2nii/no_crop）', () => {
  const sel = findT1CropSelect(tree);
  assert.ok(sel, '缺少 mrw-t1crop 下拉框');
  const opts = findAll(sel, (n) => n.type === 'option');
  assert.deepEqual(opts.map((o) => o.props.value), ['auto', 'old_dcm2nii', 'no_crop'], '选项值/顺序不对');
  assert.deepEqual(opts.map(textOf), [
    '自动（DPARSF 默认）',
    '旧版 dcm2nii（可裁剪 NIfTI）',
    '免裁剪（用未裁剪 T1 继续）',
  ], '中文选项文案不对');
  assert.equal(sel.props['data-action'], 't1crop-select', '缺少 data-action 标记');
});

await check('下拉框位于「并行 worker 数」之后，且有 hint 说明两种模式含义', () => {
  const all = [];
  walk(tree, (n) => all.push(n));
  const workerIndex = all.indexOf(findWorkerSelect(tree));
  const cropIndex = all.indexOf(findT1CropSelect(tree));
  assert.ok(workerIndex >= 0, '缺少 worker 下拉框');
  assert.ok(cropIndex > workerIndex, 'T1 裁剪兼容下拉框应位于并行 worker 数之后');
  const hints = findAll(tree, (n) => n.type === 'p' && n.props['data-role'] === 't1crop-hint');
  assert.equal(hints.length, 1, '缺少 t1crop-hint 说明行');
  const hintText = textOf(hints[0]);
  assert.ok(hintText.includes('旧版 dcm2nii') && hintText.includes('c*/co*'), 'hint 未说明旧版 dcm2nii 会生成真正 c*/co*');
  assert.ok(hintText.includes('直通') && hintText.includes('QC'), 'hint 未说明免裁剪是直通副本且分割质量需 QC');
});

await check('已保存覆盖回显：页面加载读取 T1CropCompat=old_dcm2nii 并显示', () => {
  assert.ok(commands.some((l) => l.startsWith('/mri paramsjson')), '首屏未读取参数覆盖');
  assert.equal(findT1CropSelect(tree).props.value, 'old_dcm2nii', '下拉框未回显已保存覆盖');
});

await check('选择 no_crop：payload 含 T1CropCompat=no_crop 且保留 TR 覆盖', async () => {
  const sel = findT1CropSelect(tree);
  await sel.props.onChange({ target: { value: 'no_crop' } });
  tree = render();
  assert.equal(findT1CropSelect(tree).props.value, 'no_crop', '下拉框未显示 no_crop');
  const last = overridePayloads[overridePayloads.length - 1];
  assert.ok(last, '未调用 /mri overrides set');
  assert.equal(last.find((o) => o.key === 'T1CropCompat')?.value, 'no_crop', '缺少 T1CropCompat 覆盖');
  assert.equal(last.find((o) => o.key === 'TR')?.value, 2.5, 'TR 覆盖被覆盖操作清掉了');
  assert.equal(last.filter((o) => o.key === 'T1CropCompat').length, 1, 'T1CropCompat 覆盖重复');
});

await check('选择 old_dcm2nii：payload 含 T1CropCompat=old_dcm2nii 且保留 TR 覆盖', async () => {
  const sel = findT1CropSelect(tree);
  await sel.props.onChange({ target: { value: 'old_dcm2nii' } });
  tree = render();
  assert.equal(findT1CropSelect(tree).props.value, 'old_dcm2nii', '下拉框未显示 old_dcm2nii');
  const last = overridePayloads[overridePayloads.length - 1];
  assert.equal(last.find((o) => o.key === 'T1CropCompat')?.value, 'old_dcm2nii', '缺少 T1CropCompat=old_dcm2nii');
  assert.equal(last.find((o) => o.key === 'TR')?.value, 2.5, 'TR 覆盖被覆盖操作清掉了');
});

await check('选择 auto：移除 T1CropCompat 覆盖但保留其他覆盖', async () => {
  const sel = findT1CropSelect(tree);
  await sel.props.onChange({ target: { value: 'auto' } });
  tree = render();
  assert.equal(findT1CropSelect(tree).props.value, 'auto', '下拉框未回到 auto');
  assert.deepEqual(overrides, [{ key: 'TR', value: 2.5 }], '应只保留 TR 覆盖');
  const last = overridePayloads[overridePayloads.length - 1];
  assert.equal(last.some((o) => o.key === 'T1CropCompat'), false, 'payload 仍含 T1CropCompat');
  assert.equal(last.find((o) => o.key === 'TR')?.value, 2.5, 'TR 覆盖被覆盖操作清掉了');
});

await check('再次从 Host 读取覆盖时选择器同步（applyWorker 触发 loadOverrides）', async () => {
  overrides = [{ key: 'TR', value: 2.5 }, { key: 'T1CropCompat', value: 'no_crop' }];
  const workerSel = findWorkerSelect(tree);
  assert.ok(workerSel, '缺少 worker 下拉框');
  await workerSel.props.onChange({ target: { value: '4' } });
  tree = render();
  assert.equal(findT1CropSelect(tree).props.value, 'no_crop', '读取覆盖后 T1 裁剪兼容模式未同步');
});

// =====================================================================
// 第二部分：index.mjs renderPrepare 文本（经 mri_workbench_prepare 工具的 output.render 调用）
// =====================================================================
const tools = new Map();
const hostCtx = {
  logger: { info() {}, warn() {}, error() {} },
  effect(fn) { fn(); return () => {}; },
  tools: { register(def) { tools.set(def.name, def); } },
  commands: { register() {} },
  systemPrompt: { section() {} },
  get() { return undefined; },
};
apply(hostCtx);

const prepareTool = tools.get('mri_workbench_prepare');
assert.ok(prepareTool, 'mri_workbench_prepare 工具未注册');
const renderPrepareText = (res) => prepareTool.output.render({}, res).map((part) => part.text).join('\n');
const basePrepare = {
  ok: true,
  summary: '检查通过',
  preset: '经典静息态（DARTEL 全流程）',
  workingDir: '/data/Study',
  subjectCount: 6,
  startingDirName: 'FunImg',
  tr: 2,
  timePoints: 230,
  steps: ['时间层校正', '头动校正'],
  cfgPath: '/data/Study/Cfg.mat',
  overrides: [],
  errors: [],
  warnings: [],
};

await check('renderPrepare：非 auto 时在「将执行 N 步」之后输出 T1 裁剪兼容行', () => {
  const text = renderPrepareText({
    ...basePrepare,
    t1CropCompat: 'old_dcm2nii',
    t1CropCompatLabel: '旧版 dcm2nii',
    t1CropPlan: '运行前用旧版 dcm2nii 对 NIfTI T1 重定向+裁剪生成 c*（不依赖 dcm2niix）',
  });
  const lines = text.split('\n');
  const stepIndex = lines.findIndex((line) => line.startsWith('- 将执行 2 步：时间层校正 → 头动校正'));
  assert.ok(stepIndex >= 0, '缺少「将执行 N 步」行');
  assert.equal(
    lines[stepIndex + 1],
    '- T1 裁剪兼容：旧版 dcm2nii（运行前用旧版 dcm2nii 对 NIfTI T1 重定向+裁剪生成 c*（不依赖 dcm2niix））',
    'T1 裁剪兼容行内容/位置不对',
  );
});

await check('renderPrepare：no_crop 模式同样输出兼容行（含中文说明）', () => {
  const text = renderPrepareText({
    ...basePrepare,
    steps: [],
    t1CropCompat: 'no_crop',
    t1CropCompatLabel: '免裁剪',
    t1CropPlan: '把未裁剪 T1 复制为 c* 直通副本（不重定向/去颈），分割质量需 QC',
  });
  const lines = text.split('\n');
  const stepIndex = lines.findIndex((line) => line.startsWith('- 将执行 0 步'));
  assert.ok(stepIndex >= 0, '缺少「将执行 0 步」行');
  assert.equal(
    lines[stepIndex + 1],
    '- T1 裁剪兼容：免裁剪（把未裁剪 T1 复制为 c* 直通副本（不重定向/去颈），分割质量需 QC）',
    'no_crop 兼容行内容/位置不对',
  );
});

await check('renderPrepare：auto 或缺省 t1CropCompat 时不输出兼容行', () => {
  const autoText = renderPrepareText({
    ...basePrepare,
    t1CropCompat: 'auto',
    t1CropCompatLabel: '自动（DPARSF 默认）',
    t1CropPlan: '不额外处理',
  });
  assert.equal(autoText.includes('T1 裁剪兼容'), false, 'auto 不应输出 T1 裁剪兼容行');
  const missingText = renderPrepareText(basePrepare);
  assert.equal(missingText.includes('T1 裁剪兼容'), false, '无 t1CropCompat 字段时不应输出兼容行');
});

console.log(`\n全部通过：${passed} 项检查`);
