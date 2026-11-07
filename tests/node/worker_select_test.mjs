// 「并行 worker 数」界面选择器接线自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/worker_select_test.mjs
//
// 验证：② 预处理配置卡上新增的 worker 下拉框能选择 2/4/6/8/12；
//       选择后只改 ParallelWorkersNumber 一项覆盖，保留其他已保存覆盖（如 TR）；
//       选择「0 · 串行」会移除该项覆盖；页面提示文案可见。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');

let overrides = [{ key: 'TR', value: 2.5 }];
const commands = [];
const overridePayloads = [];

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

// ---------------- 最小 DSH Client ctx（模拟 Host 会话覆盖状态） ----------------
const T_MAP = {
  'params.items': '项',
  'params.loading': '正在读取 CfgSchema…',
  'prep.workers': '并行 worker 数（被试并行）',
  'prep.workersHint': '实际并行池 = min(设定值, 物理核心数, 被试数)；0=串行。',
  'prep.workersUnset': '0 · 串行（默认）',
};
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
        commands.push(line);
        let text = '';
        if (line.startsWith('/mri paramsjson')) {
          text = JSON.stringify({
            ok: true,
            count: 97,
            total: 97,
            groups: [],
            entries: [],
            overrides,
          });
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
const findWorkerSelect = (root) => findAll(root, (n) => n.type === 'select' && n.props.id === 'mrw-workers')[0];

await check('② 预处理配置卡渲染「并行 worker 数」下拉框与说明', () => {
  const sel = findWorkerSelect(tree);
  assert.ok(sel, '缺少 mrw-workers 下拉框');
  const optionTexts = findAll(sel, (n) => n.type === 'option').map(textOf);
  assert.ok(optionTexts.includes('0 · 串行（默认）'), '缺少串行选项');
  for (const n of ['2', '4', '6', '8', '12']) {
    assert.ok(optionTexts.includes(`${n} worker`), `缺少 ${n} worker 选项`);
  }
  assert.ok(textOf(tree).includes('实际并行池 = min(设定值, 物理核心数, 被试数)'), '缺少并行说明文案');
});

await check('选择 4 worker：保存 ParallelWorkersNumber=4 且保留 TR 覆盖', async () => {
  const sel = findWorkerSelect(tree);
  await sel.props.onChange({ target: { value: '4' } });
  tree = render();
  assert.equal(findWorkerSelect(tree).props.value, '4', '下拉框未显示 4');
  const last = overridePayloads[overridePayloads.length - 1];
  assert.ok(last, '未调用 /mri overrides set');
  assert.equal(last.find((o) => o.key === 'ParallelWorkersNumber')?.value, 4, '缺少 worker 覆盖');
  assert.equal(last.find((o) => o.key === 'TR')?.value, 2.5, 'TR 覆盖被覆盖操作清掉了');
  assert.ok(commands.some((l) => l.startsWith('/mri paramsjson')), '未先读取现有覆盖');
});

await check('选择「0 · 串行」：移除 worker 覆盖但保留其他覆盖', async () => {
  const sel = findWorkerSelect(tree);
  await sel.props.onChange({ target: { value: 'unset' } });
  tree = render();
  assert.equal(findWorkerSelect(tree).props.value, 'unset', '下拉框未回到串行');
  assert.equal(overrides.length, 1, '覆盖项数量不对');
  assert.equal(overrides[0].key, 'TR', '应只保留 TR 覆盖');
});

console.log(`\n全部通过：${passed} 项检查`);
