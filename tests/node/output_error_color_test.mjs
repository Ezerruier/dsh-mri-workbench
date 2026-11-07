// 执行输出「错误行红色」自测（渲染级，不启动浏览器/DSH/MATLAB）。
// 运行: node tests/node/output_error_color_test.mjs
//
// 验证：执行输出卡片中的错误行用主题错误色渲染、普通行保持默认色，
//       且输出文本内容逐字不变；覆盖“错误：小节 + 列表项”“检查未通过”
//       摘要行、英文 Error/Warning 小节、状态=error 不误染、取消失败提示。
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const clientSource = readFileSync(path.join(repoRoot, 'client.js'), 'utf8');
const ERROR_COLOR = 'var(--dsw-alias-state-error-primary)';

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

// ---------------- 最小 DSH Client ctx（remote.commands 返回可控文本） ----------------
let commandText = '';
let slotComponent = null;
const fakeCtx = {
  effect(fn) { return fn(); },
  locale: {
    register() {},
    bind() { return (key) => key; },
  },
  slots: {
    inject(_name, fn) { fn(); },
    register(_def, component) { slotComponent = component; },
  },
  get() { return undefined; },
  remote: {
    commands: {
      async execute() {
        return { ok: true, value: { result: { kind: 'success', text: commandText } } };
      },
    },
  },
};
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
function rawText(node) {
  if (node === null || node === undefined) return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (typeof node !== 'object') return '';
  return (node.children || []).map(rawText).join('');
}
const findButton = (root, action) => findAll(root, (n) => n.type === 'button' && n.props['data-action'] === action)[0];
const findOutput = (root) => findAll(root, (n) => n.type === 'pre' && n.props['data-role'] === 'output')[0];
const outputLines = (root) => findAll(findOutput(root), (n) => n.type === 'span');
const errorFlags = (root) => outputLines(root).map((n) => {
  const color = n.props && n.props.style ? n.props.style.color : undefined;
  return color === ERROR_COLOR;
});

async function runCommand(text) {
  commandText = text;
  const btn = findButton(tree, 'env');
  assert.ok(btn, '缺少「检查环境」按钮');
  await btn.props.onClick();
  tree = render();
  return tree;
}

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

await check('空输出时显示占位文案且没有错误样式', () => {
  const out = findOutput(tree);
  assert.ok(out, '缺少执行输出区域');
  assert.equal(outputLines(tree).length, 0, '空输出不应有逐行节点');
  assert.equal(rawText(out), 'out.empty', '占位文案应为 out.empty 的 i18n 文本');
});

await check('中文辅助：错误：小节及列表项红色，提醒：小节恢复默认色，文本不变', async () => {
  const text = [
    '预处理配置：发现 1 个错误、0 项提醒',
    '- 预设：快速质控（仅转换+头动校正）',
    '错误：',
    '- 工作目录已有处理阶段目录（FunImg），但当前从 "FunImg" 重新执行「删除初始时间点」…',
    '- 运行前检查未通过',
    '提醒：',
    '- 当前配置没有启用任何步骤',
    '- 其他正常提醒',
  ].join('\n');
  await runCommand(text);
  assert.equal(rawText(findOutput(tree)), text, '输出文本被改动');
  assert.deepEqual(errorFlags(tree), [true, false, true, true, true, false, false, false]);
});

await check('失败摘要行：发现 N（N>0）个错误 / 检查未通过 标红，发现 0 个错误不标红', async () => {
  await runCommand('预处理配置：发现 2 个错误、1 项提醒');
  assert.deepEqual(errorFlags(tree), [true], '“发现 2 个错误”摘要行应为红色');
  await runCommand('预处理配置：检查未通过');
  assert.deepEqual(errorFlags(tree), [true], '“检查未通过”摘要行应为红色');
  await runCommand('预处理配置：发现 0 个错误、1 项提醒');
  assert.deepEqual(errorFlags(tree), [false], '“发现 0 个错误”不应标红');
});

await check('英文 Error/Warning 小节：Error 与列表项红色，Warning 之后恢复默认色', async () => {
  const text = ['Error:', '- boom', 'Warning:', '- ok'].join('\n');
  await runCommand(text);
  assert.equal(rawText(findOutput(tree)), text);
  assert.deepEqual(errorFlags(tree), [true, true, false, false]);
});

await check('扫描输出中的「状态=error」不会误染红整行', async () => {
  const text = [
    '数据扫描完成：DPARSF 标准目录（FunRaw/AnatRaw）（6 名受试者）',
    '- 工作目录：/data/Study',
    '  · sub-S01_ses-baseline：NIfTI，时间点=230，TR=2，状态=error',
    '提醒（1）：某受试者状态异常',
  ].join('\n');
  await runCommand(text);
  assert.equal(rawText(findOutput(tree)), text);
  assert.deepEqual(errorFlags(tree), [false, false, false, false]);
});

await check('取消失败提示行（非“错误：”小节）也渲染为红色', async () => {
  commandText = '取消失败：尚未启动预处理任务';
  const btn = findButton(tree, 'cancel');
  assert.ok(btn, '缺少「取消运行」按钮');
  await btn.props.onClick();
  tree = render();
  assert.equal(rawText(findOutput(tree)), commandText);
  assert.deepEqual(errorFlags(tree), [true]);
});

await check('完全正常的输出没有任何红色行', async () => {
  const text = ['MRI 工作台环境检查', '- MATLAB：/opt/Matlab/bin/matlab.exe', '- DPABI：/opt/DPABI'].join('\n');
  await runCommand(text);
  assert.equal(rawText(findOutput(tree)), text);
  assert.deepEqual(errorFlags(tree), [false, false, false]);
});

console.log(`\n全部通过：${passed} 项检查`);
