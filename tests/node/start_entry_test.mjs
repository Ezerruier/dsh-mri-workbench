// DSH 开始页入口与原生主面板接线；不启动 DSH 或 MATLAB。
// Run: node tests/node/start_entry_test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../../client.js', import.meta.url), 'utf8');
const slots = new Map();
const selections = [];
const commands = [];
let dictionaries;
let language = 'zh';
let plugin;
const React = {
  createElement(type, props, ...children) {
    return { type, props: props || {}, children: children.flat(Infinity).filter((c) => c != null && c !== false) };
  },
  useState(value) { return [typeof value === 'function' ? value() : value, () => {}]; },
  useEffect() {},
  useMemo(fn) { return fn(); },
};
const ctx = {
  effect(fn) { return fn(); },
  locale: {
    register(_namespace, value) { dictionaries = value; },
    bind() { return (key) => dictionaries[language][key] ?? key; },
  },
  slots: {
    inject(_name, fn) { return fn(); },
    register(definition, component) { slots.set(definition.name, { definition, component }); },
  },
  layout: { selectPanel(id) { selections.push(id); } },
  remote: { commands: { execute(...args) { commands.push(args); throw new Error('Opening must not execute commands'); } } },
};
const fakeWindow = {
  __ModuleLoader__: {
    load({ factory }) {
      plugin = factory((name) => {
        assert.equal(name, 'react');
        return React;
      });
      plugin.apply(ctx);
    },
  },
};
new Function('window', source)(fakeWindow);

function find(node, predicate) {
  if (node == null || typeof node !== 'object') return undefined;
  if (predicate(node)) return node;
  for (const child of node.children || []) {
    const found = find(child, predicate);
    if (found) return found;
  }
}
const text = (node) => typeof node === 'string' ? node : (node?.children || []).map(text).join('');
const button = (node, action) => find(node, (n) => n.type === 'button' && n.props['data-action'] === action);
let passed = 0;
function check(name, fn) {
  fn();
  console.log(`PASS  ${name}`);
  passed++;
}

check('注册原生开始页入口、主面板，并保留会话标签页', () => {
  assert.ok(plugin.inject.includes('layout'));
  assert.equal(slots.get('conversation.hero.options').definition.id, 'mri-workbench.open');
  assert.equal(slots.get('main').definition.key, 'mri-workbench');
  assert.equal(slots.get('conversation.view').definition.id, 'mri-workbench');
});

const Hero = slots.get('conversation.hero.options').component;
const Main = slots.get('main').component;
check('中英文入口均为可访问的原生按钮', () => {
  for (const [lang, label] of [['zh', '打开 MRI 工作台'], ['en', 'Open MRI workbench']]) {
    language = lang;
    const entry = button(Hero({ sessionId: 'blank-session' }), 'open-workbench');
    assert.ok(entry);
    assert.equal(entry.props.type, 'button');
    assert.equal(text(entry), label);
  }
  language = 'zh';
});

check('入口只选择面板，不发消息或执行 MRI 命令', () => {
  button(Hero({ sessionId: 'blank-session' }), 'open-workbench').props.onClick();
  assert.deepEqual(selections, ['mri-workbench']);
  assert.deepEqual(commands, []);
});

const snapshot = {
  byId: {
    old: { id: 'old-session', retainedBy: { sidebar: 1 } },
    current: { id: 'blank-session', retainedBy: { mainView: 1 } },
  },
};
const renderMain = () => Main({ useSessions: (select) => select(snapshot) });
let workbench;
check('打开复用当前空白会话，切换会话后重新读取绑定', () => {
  workbench = renderMain();
  assert.equal(workbench.props.sessionId, 'blank-session');
  assert.equal(workbench.props.key, 'blank-session');
  snapshot.byId.current = { id: 'next-session', retainedBy: { mainView: 1 } };
  const next = renderMain();
  assert.equal(next.props.sessionId, 'next-session');
  assert.equal(next.props.key, 'next-session');
});

check('工作台返回按钮回到开始界面', () => {
  const view = workbench.type(workbench.props);
  const back = button(view, 'back-to-start');
  assert.equal(text(back), '返回开始');
  back.props.onClick();
  assert.equal(selections.at(-1), null);
  assert.deepEqual(commands, []);
});

check('没有会话时显示提示和返回入口，不挂载工作台或执行命令', () => {
  snapshot.byId = {};
  const empty = renderMain();
  assert.equal(typeof empty.type, 'string');
  assert.ok(text(empty).includes('请先在开始界面选择工作区，再打开工作台。'));
  button(empty, 'back-to-start').props.onClick();
  assert.equal(selections.at(-1), null);
  assert.deepEqual(commands, []);
});

check('已有标签页仍使用相同工作台组件，且不添加返回按钮', () => {
  const tab = slots.get('conversation.view').component({ sessionId: 'existing-session' });
  assert.equal(tab.type, workbench.type);
  assert.equal(tab.props.sessionId, 'existing-session');
  assert.equal(button(tab.type(tab.props), 'back-to-start'), undefined);
});

console.log(`\n${passed}/${passed} PASS`);
