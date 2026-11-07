// ① 数据索引卡「浏览…」目录选择按钮自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/browse_dir_test.mjs
//
// 验证：
//  - ① 卡渲染「浏览…」按钮（title / data-action 齐全），点它不会执行 /mri 命令；
//  - 桌面版原生桥 __DSH_DIRECTORY_PICKER__.pick() 返回路径 → 写入「数据根目录」输入框；
//  - 用户取消（resolve null）→ 输入框保持不变、不报错；
//  - 等待选择期间按钮显示「正在打开…」并禁用；
//  - 没有原生桥时回退 uiWorkspace.pickDirectory()；原生桥报错也会回退；
//  - 两种选择器都不可用 / 都报错 → 显示对应中文提示；
//  - zh/en 文案 key 一一对应（新增文案双语齐全）。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const clientPath = path.join(repoRoot, 'client.js');
const clientSource = readFileSync(clientPath, 'utf8');

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

// ---------------- 最小 DSH Client ctx ----------------
const T_MAP = {
  'data.root': '数据根目录',
  'data.rootPlaceholder': '例如 /data/MyStudy',
  'data.browse': '浏览…',
  'data.browseTitle': '弹出系统文件夹选择框，选择数据根目录（也可直接输入或粘贴路径）',
  'data.browseBusy': '正在打开…',
  'data.browseUnavailable': '当前界面无法弹出系统目录选择框，请手动输入或粘贴路径。',
  'data.browseFailed': '打开目录选择框失败：',
};
const dictionaries = {};
const commands = [];
let uiWorkspace;
const fakeCtx = {
  effect(fn) { return fn(); },
  locale: {
    register(_ns, dicts) { dictionaries.zh = dicts.zh; dictionaries.en = dicts.en; },
    bind() { return (key) => (key in T_MAP ? T_MAP[key] : key); },
  },
  slots: {
    inject(_name, fn) { fn(); },
    register(_def, component) { slotComponent = component; },
  },
  get(name) { return name === 'uiWorkspace' ? uiWorkspace : undefined; },
  remote: {
    commands: {
      async execute(_sessionId, line) {
        commands.push(line);
        let text = '';
        if (line.startsWith('/mri paramsjson')) {
          text = JSON.stringify({ ok: true, count: 97, total: 97, groups: [], entries: [], overrides: [] });
        }
        return { ok: true, value: { result: { kind: 'success', text } } };
      },
    },
  },
};

// ---------------- 加载 client.js ----------------
let slotComponent = null;
let bridge;
function setBridge(value) {
  if (value === undefined) delete globalThis.__DSH_DIRECTORY_PICKER__;
  else globalThis.__DSH_DIRECTORY_PICKER__ = value;
}
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

new Function('window', 'require', clientSource)(fakeWindow, (name) => (name === 'react' ? React : {}));
assert.ok(slotComponent, 'slot 组件未注册');

const props = { sessionId: 'mock-session', ctx: fakeCtx };

// ---------------- 渲染 / 遍历工具 ----------------
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
const findBrowse = (root) => findAll(root, (n) => n.type === 'button' && n.props['data-action'] === 'browse-root')[0];
const findRootInput = (root) => findAll(root, (n) => n.type === 'input' && n.props.id === 'mrw-root')[0];
const findBrowseError = (root) => findAll(root, (n) => n.props && n.props['data-role'] === 'browse-error')[0];

let tree = render();
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

await check('① 卡渲染「浏览…」按钮（文案/title/data-action）且点它不执行 /mri 命令', async () => {
  const btn = findBrowse(tree);
  assert.ok(btn, '缺少「浏览…」按钮');
  assert.equal(textOf(btn), '浏览…');
  assert.equal(btn.props.title, T_MAP['data.browseTitle']);
  assert.equal(btn.props.type, 'button');
  assert.equal(btn.props.disabled, false);
  assert.ok(findRootInput(tree), '缺少数据根目录输入框');
  const before = commands.length;
  uiWorkspace = undefined;
  setBridge(undefined);
  await btn.props.onClick(); // 无选择器：只显示提示，不应执行宿主命令
  tree = render();
  assert.equal(commands.length, before, '点击浏览按钮不应执行 /mri 命令');
});

await check('桌面原生桥返回路径：写入数据根目录输入框', async () => {
  setBridge({ pick: async () => '/data/StudyA' });
  const btn = findBrowse(tree);
  await btn.props.onClick();
  tree = render();
  assert.equal(findRootInput(tree).props.value, '/data/StudyA', '路径未写入输入框');
  assert.equal(findBrowseError(tree), undefined, '成功时不应出现错误提示');
  assert.equal(textOf(findBrowse(tree)), '浏览…', '按钮应恢复为「浏览…」');
});

await check('用户取消（resolve null）：输入框不变且不报错', async () => {
  setBridge({ pick: async () => null });
  await findBrowse(tree).props.onClick();
  tree = render();
  assert.equal(findRootInput(tree).props.value, '/data/StudyA', '取消后输入框被改动');
  assert.equal(findBrowseError(tree), undefined, '取消不应报错');
});

await check('等待选择期间按钮显示「正在打开…」并禁用', async () => {
  let resolvePick;
  setBridge({ pick: () => new Promise((resolve) => { resolvePick = resolve; }) });
  const pending = findBrowse(tree).props.onClick();
  tree = render();
  const busyBtn = findBrowse(tree);
  assert.equal(textOf(busyBtn), '正在打开…', '未显示打开中状态');
  assert.equal(busyBtn.props.disabled, true, '打开中按钮未禁用');
  resolvePick('/data/BusyPick');
  await pending;
  tree = render();
  assert.equal(findRootInput(tree).props.value, '/data/BusyPick');
});

await check('没有原生桥时回退 uiWorkspace.pickDirectory()', async () => {
  setBridge(undefined);
  let called = 0;
  const seenCtx = fakeCtx;
  const previousGet = seenCtx.get;
  seenCtx.get = (name) => {
    if (name === 'uiWorkspace') {
      return { pickDirectory: async () => { called += 1; return '/data/WebFallback'; } };
    }
    return previousGet(name);
  };
  try {
    await findBrowse(tree).props.onClick();
    tree = render();
    assert.equal(called, 1, '未调用 uiWorkspace.pickDirectory');
    assert.equal(findRootInput(tree).props.value, '/data/WebFallback');
    assert.equal(findBrowseError(tree), undefined);
  } finally {
    seenCtx.get = previousGet;
  }
});

await check('原生桥报错时回退 uiWorkspace 并成功写入', async () => {
  setBridge({ pick: async () => { throw new Error('ipc boom'); } });
  const seenCtx = fakeCtx;
  const previousGet = seenCtx.get;
  seenCtx.get = (name) => {
    if (name === 'uiWorkspace') return { pickDirectory: async () => '/data/AfterBridgeError' };
    return previousGet(name);
  };
  try {
    await findBrowse(tree).props.onClick();
    tree = render();
    assert.equal(findRootInput(tree).props.value, '/data/AfterBridgeError', '回退路径未生效');
    assert.equal(findBrowseError(tree), undefined, '回退成功却显示错误');
  } finally {
    seenCtx.get = previousGet;
  }
});

await check('没有可用选择器：显示「无法弹出系统目录选择框」提示', async () => {
  setBridge(undefined);
  const seenCtx = fakeCtx;
  const previousGet = seenCtx.get;
  seenCtx.get = () => undefined;
  try {
    await findBrowse(tree).props.onClick();
    tree = render();
    const err = findBrowseError(tree);
    assert.ok(err, '缺少错误提示');
    assert.equal(textOf(err), T_MAP['data.browseUnavailable']);
    assert.equal(findRootInput(tree).props.value, '/data/AfterBridgeError', '失败时输入框被改动');
  } finally {
    seenCtx.get = previousGet;
  }
});

await check('选择器报错：显示「打开目录选择框失败：…」', async () => {
  setBridge(undefined);
  const seenCtx = fakeCtx;
  const previousGet = seenCtx.get;
  seenCtx.get = (name) => (name === 'uiWorkspace'
    ? { pickDirectory: async () => { throw new Error('host dialog failed'); } }
    : undefined);
  try {
    await findBrowse(tree).props.onClick();
    tree = render();
    const err = findBrowseError(tree);
    assert.ok(err, '缺少错误提示');
    const text = textOf(err);
    assert.ok(text.startsWith(T_MAP['data.browseFailed']), `错误文案前缀不对：${text}`);
    assert.ok(text.includes('host dialog failed'), `错误未透传原因：${text}`);
  } finally {
    seenCtx.get = previousGet;
    setBridge(undefined);
  }
});

await check('zh/en 文案 key 一一对应且新增文案双语齐全', () => {
  assert.ok(dictionaries.zh, '未注册中文文案');
  assert.ok(dictionaries.en, '未注册英文文案');
  const zhKeys = Object.keys(dictionaries.zh).sort();
  const enKeys = Object.keys(dictionaries.en).sort();
  assert.deepEqual(zhKeys, enKeys, 'zh/en 文案 key 不一致');
  for (const key of ['data.browse', 'data.browseTitle', 'data.browseBusy', 'data.browseUnavailable', 'data.browseFailed']) {
    assert.ok(dictionaries.zh[key], `中文缺少 ${key}`);
    assert.ok(dictionaries.en[key], `英文缺少 ${key}`);
  }
});

console.log(`\n全部通过：${passed} 项检查`);
