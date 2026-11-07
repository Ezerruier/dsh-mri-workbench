// 参数设置弹窗「依赖联动」回归自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/param_dialog_dep_test.mjs
//
// 回归背景：CfgSchema 的 DependsOn 值来自 MATLAB（数值 1/0），而弹窗里的 bool 控件写回的是
// JS 布尔值（true/false）。两者若直接用 JSON.stringify 比较会不相等，表现为「已勾选父开关，
// 依赖它的子字段仍永久置灰」。本测试锁定两条路径：
//   1) 在弹窗内勾选父开关后，子字段必须立即解禁；
//   2) 已保存的布尔覆盖（value:true）重新打开弹窗时也应视为满足 IsRemoveFirstTimePoints=1。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const cacheFile = path.join(here, 'fixtures', 'schema.json');
const cached = JSON.parse(readFileSync(cacheFile, 'utf8'));

// 模拟 Host 会话状态：/mri overrides set 之后，/mri paramsjson 返回最新覆盖。
let currentOverrides = [];

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
        if (line.startsWith('/mri paramsjson')) {
          text = JSON.stringify({
            ok: true,
            count: cached.count,
            total: cached.count,
            groups: cached.groups,
            entries: cached.entries,
            overrides: currentOverrides,
          });
        } else if (line.startsWith('/mri overrides set ')) {
          const b64 = line.slice('/mri overrides set '.length).trim();
          const payload = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
          currentOverrides = payload;
          text = `参数覆盖：${payload.length} 项\n已保存`;
        } else if (line.startsWith('/mri overrides clear')) {
          currentOverrides = [];
          text = '参数覆盖：0 项';
        } else if (line.startsWith('/mri prepare')) {
          text = '预处理配置：检查通过（6 项）';
        }
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
function findWithParents(root, pred) {
  const out = [];
  (function visit(node, parent) {
    if (!node || typeof node !== 'object') return;
    if (pred(node)) out.push({ node, parent });
    for (const child of node.children || []) visit(child, node);
  })(root, null);
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

// 通过字段 tooltip 的「中文名 / English」前缀定位字段行，再从控件列取输入控件
function findControlInput(root, labelPrefix, inputType) {
  const hits = findWithParents(root, (node) =>
    node.type === 'div' && typeof node.props.title === 'string' &&
    node.props.title.startsWith(`${labelPrefix}\n`));
  assert.equal(hits.length, 1, `字段行定位失败：${labelPrefix}（命中 ${hits.length} 个）`);
  const row = hits[0].parent;
  assert.ok(row && Array.isArray(row.children) && row.children.length >= 2, `字段行结构异常：${labelPrefix}`);
  const inputs = findAll(row.children[1], (n) => n.type === 'input');
  const input = inputType ? inputs.find((n) => n.props.type === inputType) : inputs[0];
  assert.ok(input, `未找到 ${inputType} 输入控件：${labelPrefix}`);
  return input;
}

function openParamsDialog() {
  const btn = findAll(tree, (n) => n.type === 'button' && n.props['data-action'] === 'params-dialog');
  assert.equal(btn.length, 1, '缺少「参数设置…（弹窗）」按钮');
  return btn[0].props.onClick();
}
function switchGroup(groupName) {
  const btn = findAll(tree, (n) => n.type === 'button' && textOf(n).includes(groupName));
  assert.ok(btn.length >= 1, `缺少分组按钮：${groupName}`);
  btn[0].props.onClick();
  tree = render();
}

let tree = render();

// ---------------- 场景 1：弹窗内勾选父开关，子字段应立即解禁 ----------------
await check('打开参数设置弹窗', async () => {
  await openParamsDialog();
  tree = render();
  const dialog = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog');
  assert.equal(dialog.length, 1, '未渲染弹窗');
});

await check('「时间层与头动」分组：删除个数默认置灰（父开关未开）', () => {
  switchGroup('时间层与头动');
  const num = findControlInput(tree, '删除个数 / Number of Time Points to Remove', 'number');
  assert.equal(num.props.disabled, true, '父开关未开时删除个数不应可编辑');
});

await check('勾选「删除初始时间点」后，删除个数立即解禁', () => {
  const box = findControlInput(tree, '删除初始时间点 / Remove First Time Points', 'checkbox');
  assert.equal(box.props.disabled, false, '父开关本身不应被禁用');
  box.props.onChange({ target: { checked: true } });
  tree = render();
  const num = findControlInput(tree, '删除个数 / Number of Time Points to Remove', 'number');
  assert.equal(num.props.disabled, false, '父开关已开启，删除个数仍然置灰');
});

await check('应用覆盖时 bool 以 MATLAB 兼容的 1/0 保存，并带上删除个数 10', async () => {
  const num = findControlInput(tree, '删除个数 / Number of Time Points to Remove', 'number');
  num.props.onChange({ target: { value: '10' } });
  tree = render();
  const applyBtn = findAll(tree, (n) => n.type === 'button' && textOf(n) === 'params.apply');
  assert.equal(applyBtn.length, 1, '缺少应用覆盖按钮');
  await applyBtn[0].props.onClick();
  const last = [...commandsExecuted].reverse().find((l) => l.startsWith('/mri overrides set '));
  assert.ok(last, '未调用 /mri overrides set');
  const payload = JSON.parse(Buffer.from(last.slice('/mri overrides set '.length).trim(), 'base64').toString('utf8'));
  const boolItem = payload.find((o) => o.key === 'IsRemoveFirstTimePoints');
  const numItem = payload.find((o) => o.key === 'RemoveFirstTimePoints');
  assert.ok(boolItem, '覆盖里缺少 IsRemoveFirstTimePoints');
  assert.equal(boolItem.value, 1, 'bool 覆盖应保存为数值 1（与 CfgSchema 默认值/依赖值一致）');
  assert.ok(numItem, '覆盖里缺少 RemoveFirstTimePoints');
  assert.equal(numItem.value, 10);
});

// ---------------- 场景 2：旧的布尔覆盖（value:true）也应满足依赖 ----------------
hookStates = [];              // 模拟刷新页面后重新挂载
currentOverrides = [{ key: 'IsRemoveFirstTimePoints', value: true }];

await check('刷新后重新打开弹窗（覆盖为布尔 true）', async () => {
  tree = render();
  await openParamsDialog();
  tree = render();
  const dialog = findAll(tree, (n) => n.type === 'div' && n.props.role === 'dialog');
  assert.equal(dialog.length, 1, '未渲染弹窗');
});

await check('布尔覆盖 value:true 也视为满足 IsRemoveFirstTimePoints=1，删除个数可编辑', () => {
  switchGroup('时间层与头动');
  const num = findControlInput(tree, '删除个数 / Number of Time Points to Remove', 'number');
  assert.equal(num.props.disabled, false, '布尔覆盖 true 未被视为满足依赖，字段仍然置灰');
});

console.log(`\n全部通过：${passed} 项检查`);
