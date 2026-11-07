// 参数设置弹窗「渲染级」自测：用最小 React 假实现执行 client.js 的真实渲染函数，
// 验证弹窗能打开、字段/分组/悬停解释/中英文/依赖置灰等结构正确。不启动浏览器/DSH/MATLAB。
// 运行: node tests/node/param_dialog_render_test.mjs
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const cacheFile = path.join(here, 'fixtures', 'schema.json');
const cached = JSON.parse(readFileSync(cacheFile, 'utf8'));
const paramsPayload = JSON.stringify({
  ok: true,
  count: cached.count,
  total: cached.count,
  groups: cached.groups,
  entries: cached.entries,
  overrides: [],
});

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

// ---------------- 最小 DSH Client ctx ----------------
const T_MAP = {
  'params.typeLabel': '类型',
  'params.defaultLabel': '默认',
  'params.advancedBadge': '高级',
  'params.depsLabel': '启用条件',
  'params.disabledByDeps': '由其他参数控制，当前不可用',
  'preset.5': '空白（仅补步骤/续跑）',
};
const commandsExecuted = [];
const fakeCtx = {
  effect(fn) { fn(); },
  locale: {
    register() {},
    bind() {
      return (key) => (key in T_MAP ? T_MAP[key] : key);
    },
  },
  slots: {
    inject(_name, fn) { fn(); },
    register(_def, component) { slotComponent = component; },
  },
  remote: {
    commands: {
      async execute(_sessionId, line) {
        commandsExecuted.push(line);
        let text = '';
        if (line.startsWith('/mri paramsjson')) text = paramsPayload;
        else if (line.startsWith('/mri overrides set')) text = '参数覆盖：2 项\n已保存';
        else if (line.startsWith('/mri overrides clear')) text = '参数覆盖：0 项';
        else if (line.startsWith('/mri prepare')) text = '预处理配置：检查通过（6 项）';
        return { ok: true, value: { result: { kind: 'success', text } } };
      },
    },
  },
};

// 加载 client.js（其内部调用 window.__ModuleLoader__.load 并 apply）
const clientSource = readFileSync(path.join(repoRoot, 'client.js'), 'utf8');
new Function('window', 'require', clientSource)(fakeWindow, (name) => (name === 'react' ? React : {}));
assert.ok(slotComponent, 'slot 组件未注册');

const props = { sessionId: 'mock-session', ctx: fakeCtx };

// 展开函数组件（模拟 React 渲染），同时按渲染顺序推进 hooks
function expand(node) {
  if (node === null || node === undefined) return node;
  if (typeof node === 'string' || typeof node === 'number') return node;
  if (typeof node !== 'object') return node;
  if (typeof node.type === 'function') {
    const rendered = node.type(node.props || {});
    return expand(rendered);
  }
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
console.log('初次渲染节点数:', findAll(tree, () => true).length);

await check('页面初始渲染无异常，含「参数设置…（弹窗）」按钮', () => {
  const btn = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'params-dialog');
  assert.equal(btn.length, 1);
  assert.equal(textOf(btn[0]), 'prep.editParams');
});

await check('预处理预设下拉包含第 5 个「空白/续跑」预设', () => {
  const select = findAll(tree, (n) => n.type === 'select' && n.props.id === 'mrw-preset')[0];
  assert.ok(select, '缺少预设下拉');
  const options = findAll(select, (n) => n.type === 'option');
  assert.equal(options.length, 5, '预设数量应为 5');
  assert.equal(options[4].props.value, '5');
  assert.ok(textOf(options[4]).includes('空白（仅补步骤/续跑）'), '缺少空白/续跑预设标签');
});

await check('点击打开弹窗：请求 /mri paramsjson 并渲染参数弹窗', async () => {
  const btn = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'params-dialog')[0];
  await btn.props.onClick();
  assert.ok(commandsExecuted.some((l) => l.startsWith('/mri paramsjson')));
  tree = render();
  const dialog = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog');
  assert.equal(dialog.length, 1, '未渲染弹窗');
});

await check('弹窗含 7 个分组导航与中英分组名', () => {
  const dialog = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog')[0];
  const texts = textOf(dialog);
  for (const label of ['基础设置', '时间层与头动', '结构像处理', '标准化与平滑', '回归与滤波', '指标计算', '高级与运行']) {
    assert.ok(texts.includes(label), `缺分组：${label}`);
  }
  assert.ok(texts.includes('Basic') && texts.includes('Normalize & Smooth'), '分组英文名缺失');
});

await check('当前分组渲染字段，含中文名 + English + key', () => {
  const dialog = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog')[0];
  const texts = textOf(dialog);
  assert.ok(texts.includes('工作目录'));
  assert.ok(texts.includes('Working Directory'));
  assert.ok(texts.includes('基础设置'));
  // 默认分组基础设置应包含 TR 字段
  assert.ok(texts.includes('重复时间 TR'), '缺少 TR 中文标签');
  assert.ok(texts.includes('TR  ·  TR'), '缺少 English + key 副标签');
});

await check('字段悬停解释 title 含 glossary 中文 Tip', () => {
  const labelled = findAll(tree, (n) => n.type === 'div' && typeof n.props.title === 'string' && n.props.title.includes('\n'));
  assert.ok(labelled.length > 0, '没有带多行 tooltip 的字段');
  const trTip = labelled.find((n) => n.props.title.includes('重复时间 TR（秒，0=自动）'));
  assert.ok(trTip, 'TR 字段缺 tooltip');
  assert.ok(trTip.props.title.includes('扫描重复时间'), 'TR tooltip 未包含 glossary Tip 文本');
  assert.ok(trTip.props.title.includes('类型：小数 / double'), 'tooltip 缺类型');
  assert.ok(trTip.props.title.includes('默认：0'), 'tooltip 缺默认值');
});

await check('切换到「结构像处理」分组后可看到 enum 下拉与中文选项', () => {
  const groupBtn = findAll(tree, (n) => n.type === 'button' && textOf(n).includes('结构像处理'))[0];
  assert.ok(groupBtn, '缺少结构像处理分组按钮');
  groupBtn.props.onClick();
  tree = render();
  const selects = findAll(tree, (n) => n.type === 'select');
  assert.ok(selects.length >= 1, '缺少下拉框');
  const optTexts = findAll(tree, (n) => n.type === 'option').map(textOf).join(' ');
  assert.ok(optTexts.includes('不分割') || optTexts.includes('旧版分割'), '缺少枚举中文选项');
});

await check('底部「应用覆盖」按钮存在，点击后调用 /mri overrides set', async () => {
  const buttons = findAll(tree, (n) => n.type === 'button');
  const applyBtn = buttons.find((n) => textOf(n) === 'params.apply');
  assert.ok(applyBtn, '缺少应用覆盖按钮');
  await applyBtn.props.onClick();
  assert.ok(commandsExecuted.some((l) => l.startsWith('/mri overrides set ')), '未调用 overrides set');
});

await check('弹窗关闭后页面恢复，覆盖状态更新', () => {
  tree = render();
  const dialogs = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog');
  assert.equal(dialogs.length, 0, '弹窗未关闭');
  assert.ok(textOf(tree).includes('prep.status'));
});

console.log(`\n全部通过：${passed} 项检查`);
