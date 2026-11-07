# 原生 DPABI / DPARSF 界面汉化 + 鼠标悬停解释（NativePatch）

> 模块归属：T4「原生 DPABI 界面汉化 + 悬停解释」
> 代码：`+mrw/NativePatch.m`、`+mrw/NativeLaunch.m`
> 数据：`resources/native_labels.tsv`
> 测试：`tests/test_native_patch.m`
> 依赖（可选）：`+mrw/Glossary.m` + `resources/glossary.tsv`（术语库，用于悬停解释）

---

## 1. 目标与边界

用户要求：**把原生 DPABI/DPARSF 的英文界面调回中文，并在鼠标悬停时显示参数的概述/建议**。

DPABI 的主 GUI 是 `.fig` 布局 + 加密 `.p` 回调（如 `DPARSF/DPARSFA.fig` + `DPARSFA.p`）：

- 不能修改 `D:\Software\DPABI` 下任何文件（也不允许重新保存 .fig）；
- 不能反编译 `.p`，不能替换回调；
- 因此只能在**原生窗口已经打开**之后，从 MATLAB 运行时动态修改控件显示文字 + `Tooltip`。

本模块正是这样实现的：**打开窗口 → 动态汉化 → 悬停解释 → 可一键还原**。所有修改都记录原值，`unpatch` 后逐控件与原始 `.fig` 完全一致；全程 `try/catch` 隔离，任何异常都不会破坏原界面。

不做什么：

- 不改 DPABI 安装文件、不覆盖 `.fig`/`.p`、不写注册表；
- 不启动需要 `uiwait` 的 DPARSFA.p 界面做自动化测试（只 `openfig` 读取 `DPARSFA.fig` 做真实断言）；
- 不翻译 popupmenu 的选项列表（理由见 §5 安全规则）。

---

## 2. 快速使用

```matlab
% 1) 把工作台项目根加入路径（+mrw 位于其下）
addpath('<仓库>\matlab\MRI_Workbench');

% 2) 打开原生界面（自动汉化 + 自动监视后续子窗口 30 秒）
mrw.NativeLaunch.openDPABI();              % DPABI 主界面
mrw.NativeLaunch.openDPARSFMain();         % DPARSF 经典版入口
mrw.NativeLaunch.openDPARSFA();            % DPARSFA 高级版（空白配置）
mrw.NativeLaunch.openDPARSFA('Blank');     % 也可用模板短名，自动补 Template_ 前缀/.mat

% 3) 也可以不用 NativeLaunch：自己打开窗口后手动汉化
mrw.NativePatch.patchAll();                % 汉化当前所有已打开的原生窗口
mrw.NativePatch.unpatchAll();              % 还原英文
mrw.NativePatch.isPatched(fig)             % 单个窗口是否已汉化
s = mrw.NativePatch.patchFigure(fig);      % 汉化单个窗口（返回统计）
mrw.NativeLaunch.stopPatchMonitor();       % 停掉自动监视器（30 秒后也会自动停）
```

返回的统计结构体（`patchFigure` / `patchAll`）示例：

```text
[NativePatch] 扫描 4 个图窗，汉化 3 个窗口：翻译 100 个控件，Tooltip 131 个，
              已汉化 0，跳过 0，异常 0，耗时 253.6 ms
```

字段：`Key, Name, Found, Matched, Translated, AlreadyPatched, Tooltips, Skipped, Errors, Elapsed, LastError`；
`patchAll` 额外有 `FiguresScanned, FiguresPatched, Details`；`unpatchAll` 有 `FiguresRestored, Restored, Errors, Elapsed`。

### 与工作台已有启动入口的关系

`+mrw/Dpabi.m` 的 `launchDPABI()/launchDPARSFMain()/launchDPARSFA(name)` 已经会优先转调本模块的
`mrw.NativeLaunch.*`，并在 `Settings.NativePatch` 开启时调用 `mrw.NativePatch.patchAll()`，
因此从工作台 UI 打开原生界面即自动获得中文 + 悬停解释，无需重复接线。

---

## 3. 覆盖范围与统计

`resources/native_labels.tsv` 共 **208 行**，覆盖 **9 个原生窗口**：

| Figure 键 | 原生窗口（.fig） | 控件行数 | 已汉化 | Tooltip（有术语库） |
|---|---|---:|---:|---:|
| `dpabi` | `dpabi.fig`（DPABI 主界面） | 15 | 10 | 10 |
| `DPARSF_main` | `DPARSF/DPARSF_main.fig`（DPARSF 入口） | 6 | 6 | 6 |
| `DPARSFA` | `DPARSF/DPARSFA.fig`（高级版主界面） | 119 | 84 | 115 |
| `DPARSF_NuisanceSetting` | `SubGUIs/DPARSF_NuisanceSetting.fig` | 20 | 12 | 20 |
| `DPARSF_FieldMap` | `SubGUIs/DPARSF_FieldMap.fig` | 14 | 12 | 12 |
| `DPARSF_ROI_Template` | `SubGUIs/DPARSF_ROI_Template.fig` | 7 | 7 | 7 |
| `DPARSF_ScrubbingSetting_gui` | `SubGUIs/DPARSF_ScrubbingSetting_gui.fig` | 17 | 14 | 17 |
| `ReorientThreQC` | `SubGUIs/ReorientThreQC.fig` | 8 | 4 | 4 |
| `DPARSF_ChooseGUI` | `SubGUIs/DPARSF_ChooseGUI.fig` | 2 | 2 | 2 |
| **合计** | 9 个窗口 | **208** | **151** | **193** |

说明：

- `DPARSFA` 的 **119 个 uicontrol 全覆盖**（每个控件在 TSV 中都有且仅有一行，测试逐 tag 断言 119/119）。
- 「已汉化」= String 实际发生中文替换的控件数；`Tooltip` 数含“只加提示、不改文字”的控件
  （edit/popupmenu/listbox、纯缩写/品牌名等）。术语库缺失时 Tooltip 自动降级为
  “中文（English）”简版，此时 `DPARSFA` 仍有 86 个控件可悬停，不报错。
- DPARSFA 未汉化的 35 个控件构成（数学核验：119 − 84 = 35）：
  - 19 个 `edit`：文字是数值/路径**数据**，不可改；已翻译其相邻静态文本标签（TR、时间点数、层数…）；
  - 1 个 `popupmenu`：模板下拉框 **String 一律不动**（见 §5），只加 Tooltip；
  - 1 个 `listbox`：受试者列表是数据；
  - 4 个纯符号/单位：`A`、`~`、`~`、`...`（`Chinese` 留空 = 明确跳过）；
  - 6 个品牌/缩写与英文同名，无需翻译：`VMHC`、`CWAS`、`ReHo`、`ALFF+fALFF`、`Friston 24`、`FWHM:`；
  - 2 个极窄 radiobutton（`19`、`7`）：保留数字，避免中文截断（相邻的 `27 体素` 已汉化，Tooltip 仍给出 ReHo 邻域解释）。
- 括号内 `（…）`/冒号等在窄控件里改用半角（`TR(秒):`、`频段(Hz):`），以保证**不换行、不截断**；
  这已用 `get(h,'Extent')` 与真实 `exportapp` 截图逐控件核对（见 §7）。
- 子界面通过 `Tag`/窗口标题识别；`DPARSF_NuisanceSetting`、`DPARSF_ROI_Template`、
  `DPARSF_ChooseGUI` 的 `.fig` Tag 都是通用的 `figure1`，因此用窗口标题 + 特征子控件兜底识别。

---

## 4. 工作原理

### 4.1 数据驱动：`resources/native_labels.tsv`

UTF-8、TAB 分隔、首行表头，6 列：

| 列 | 说明 |
|---|---|
| `Figure` | 窗口标识：`dpabi` / `DPARSF_main` / `DPARSFA` / `DPARSF_NuisanceSetting` / `DPARSF_FieldMap` / `DPARSF_ROI_Template` / `DPARSF_ScrubbingSetting_gui` / `ReorientThreQC` / `DPARSF_ChooseGUI` |
| `Tag` | 控件 Tag（已与 DPABI V10.0_260625 的真实 `.fig` 逐一对齐；`panel` 行放 uipanel Tag） |
| `Style` | `text` / `pushbutton` / `checkbox` / `radiobutton` / `popupmenu` / `edit` / `listbox` / `panel` |
| `English` | 原始英文文字（严格取自 `fig_uicontrols.pretty.json` / 本模块的 hierarchy dump，用于安全匹配） |
| `Chinese` | 中文文字；**留空 = 明确跳过**（不改文字，只按需加 Tooltip）；`Chinese == English` 表示品牌/缩写保持原样 |
| `GlossaryKey` | 首选术语库 Key（`glossary.tsv` 的 `Key` 列，如 `IsRealign`、`TR`、`SliceTiming.SliceNumber`）；空则按英文原文 `Glossary.tooltip(english)` 查 |

扩充方式：给新窗口加行时，除 TSV 外还需在 `NativePatch.identify()` 中加该窗口的
Tag/标题识别，并在 `NativeLaunch.figureFile()`（若需从代码打开）中加 `.fig` 路径。

### 4.2 汉化流程（`patchFigure`）

1. `findall(groot,'Type','figure')` 找到图窗 → `keyForFigure` 按 Tag/标题/特征控件识别窗口；
2. 读取 TSV 中该窗口的行，建立 `Tag → 行` 与 `Style|English → 行` 两个索引；
3. 遍历 `uicontrol` + `uipanel` + `uibuttongroup`：
   - 先按 `Tag` 匹配；Tag 不存在（DPABI 升级改 tag）时按 `Style+English` 兜底；
   - **只有当前文字与表里的 `English` 完全一致（或仅首尾空白差异）时才替换**，认不出就不动；
   - 只改 `text/pushbutton/checkbox/radiobutton/togglebutton/panel`；`popupmenu`/`edit`/`listbox` 的 String 永不触碰；
4. 逐控件设置中文 Tooltip（优先级：`GlossaryKey` → 英文原文查术语库 → “中文（English）”简版）；
   若控件原本已有英文 Tooltip（如 `editSliceNumber` 的 `SHOULD BE EXTREMELY CAUTIOUS!!!` 警告），
   新提示会附在其后（`原始英文提示：…`），不丢原信息；
5. 把 `{句柄, 属性, 原值, 原 Tooltip, 新 Tooltip}` 记录到该 figure 的
   `appdata('mrwNativePatch')`；**不写 `guidata`，不碰 DPABI 自己的 handles 变量**。

### 4.3 还原流程（`unpatchFigure` / `unpatchAll`）

按记录把 String/Title、Tooltip 逐项写回原值，删除 appdata。若图窗已关闭则自动跳过；
若控件已被 DPABI 销毁则 `isvalid` 检查后跳过。还原后用 `isequal` 对全部控件逐项比对，
与 `.fig` 原始值**完全一致**（测试对 3 个窗口、140 个控件、含空值/多行/Tooltip 均做了断言）。

### 4.4 幂等与动态刷新

- 已汉化窗口再次 `patchAll/patchFigure`：识别 `当前文字 == 中文` → 计入 `AlreadyPatched`，不重复改；
- 若 DPABI 后续把标签改回英文（常见于加载模板/切换状态后的 `set(...,'String',...)`），再次调用即可补译；
- 30 秒监视器（`NativeLaunch.startPatchMonitor`）每 0.5 秒 `patchAll` 一次（`BusyMode=drop`，绝不会卡界面），
  用于自动汉化“打开 DPABI 后才创建”的子窗口；到时自动停止，也可 `stopPatchMonitor()` 手动停。
- 监视器回调、任何单控件、任何单图窗处理都包 `try/catch`；异常只累计到 `Errors`/`LastError`，不向外抛。

---

## 5. 安全规则（为什么不会碰坏原界面）

1. **只改显示文字**：`text/pushbutton/checkbox/radiobutton/togglebutton` 的 String 与 uipanel 的 Title，
   不涉及回调、Value、Enable、Position、Font、Units 等任何其他属性（字号/字体/布局完全保持原样，
   中文直接沿用原控件字体渲染，Windows 中文系统下由系统字体回退正常显示）。
2. **popupmenu 的 String 绝对不动**：DPARSF/DPARSFA 的回调常按 `get(h,'Value')` 或选项字符串分支，
   改字符串可能改变行为（尤其是模板选择框）；只加 Tooltip，既保留悬停解释又零风险。
3. **edit / listbox 的文字是数据**（路径、数值、受试者列表），永不改；它们的参数名由相邻 `text` 标签翻译。
4. **只认原文再翻译**：当前文字与标签表 `English` 不一致时（DPABI 动态改写、用户自定义、语言不同版本）
   一律跳过并计数，绝不覆盖；因此可安全地重复调用、可与其他工具共存。
5. **原值记录 + 可逆**：记录存在 figure appdata，关闭窗口即消失，不污染全局状态、不写磁盘；
   `unpatch` 后与 `.fig` 原始 String/Tooltip **逐项完全相等**。
6. **异常隔离**：单控件、单窗口、监视器 tick 全部 `try/catch`；测试里专门构造了
   “未知图窗/空图窗/被改写文字”三种异常场景，断言零副作用。
7. **不写 DPABI 安装目录**：只 `openfig` 读取与运行时 set 属性；测试中用文件时间戳对比确认未修改。

---

## 6. 已知限制

1. **未覆盖 DPARSF 基础版 `DPARSF.fig`**（任务是 dpabi / DPARSF_main / DPARSFA；基础版控件与 DPARSFA 大量重名，
   TSV 可直接续加 `DPARSF` 行并补 `identify` 支持；`NativeLaunch.figureFile` 已预留 `DPARSF` 路径映射）。
2. **popupmenu 选项仍是英文**：如上，为避免回调风险只加 Tooltip、不改项；模板下拉框当前显示
   `Template Para...`（英文缩写）但悬停有中文说明。
3. **DPABI 在窗口打开后动态改写标签**（个别状态下 DPARSF 会 `set` 控件文字）时，本次汉化可能被覆盖：
   重新 `patchAll()` 即可；`NativeLaunch` 打开后的 30 秒监视器也会自动补。
4. **窗口识别依赖 Tag/标题**：如果用户脚本把图窗改名/改 Tag，或 DPABI 大版本改了控件 Tag，
   可能识别不到（Tag 匹配失败时仍有 `Style+English` 兜底；完全不识别则安全跳过，不会误改）。
5. **极窄控件使用短标签**（如 `去颅`、`先平滑`、`邻域:`、`层顺序:`）以避免截断，完整解释见悬停 Tooltip；
   数字选项 `19`/`7` 保留数字不汉化。若以后 DPABI 布局变宽，可把 `Chinese` 改回完整词。
6. **DPARSFA.p 的实际 GUI 未在自动化测试中启动**（其内部可能 `uiwait`，-batch 会挂住）；
   `openDPARSFA` 走官方 `DPARSFA()` 入口 + 前置 timer 监视器，属人工验证项（本机不自动跑）。
7. **术语库缺失时** Tooltip 降级为“中文（English）”简版（不报错）；如需更丰富解释，
   由 `resources/glossary.tsv`（T2 提供）覆盖 `GlossaryKey`。若 glossary 在 MATLAB 启动后才生成，
   `mrw.Glossary` 有自己的缓存，需 `clear mrw.Glossary` 或重启（本模块不强制清它的缓存）。
8. **只汉化文字与悬停**，不翻译 `msgbox/questdlg` 等其他弹窗内容（它们由 DPABI 代码在运行时生成）。

---

## 7. 测试与验证（真实 `.fig`，-batch 可复现）

```powershell
& 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch "cd('<仓库>\matlab\MRI_Workbench'); addpath(pwd); addpath(fullfile(pwd,'tests')); test_native_patch"
```

测试覆盖（共 **523 项断言**，全部通过，输出末尾打印 `TEST PASSED`）：

1. **资源完整性**：208 行、9 个窗口、无重复 `Figure+Tag`、Style 合法、edit 不含中文、
   “中文≠英文”的行必须含 CJK 字符、DPARSFA=119 行；
2. **DPARSFA 覆盖率**：真实 `openfig` 后逐控件比对，119/119 个 uicontrol 都能在 TSV 找到同 Tag 同 Style 的行；
3. **真实翻译/还原**（`openfig` 打开 `dpabi.fig`、`DPARSF_main.fig`、`DPARSFA.fig`）：
   - 断言翻译数（dpabi=10、DPARSF_main=6、DPARSFA=84）、关键中文文字（头动校正/时间层校正/标准化/平滑/协变量回归/BET 去颅骨…）；
   - 断言 **popupmenu String 深比较未变**、listbox 未变、全部 edit 数值未变；
   - 断言 Tooltip 覆盖、`editSliceNumber` 的原始英文警告仍保留；
   - 断言幂等（第二次 `Translated=0`、`AlreadyPatched>0`）；
   - `unpatch` 后**逐控件**断言 String 与 Tooltip 都和 openfig 初始值 `isequal`；
4. **patchAll/unpatchAll**：3 窗口一次汉化 100 个控件、逐控件还原；`isPatched` 状态正确；
5. **安全性**：把按钮改成 `Custom Tool XYZ` 后重翻译 → 原样保留（Skipped=1）；未知图窗/伪造原生空图窗零副作用；
6. **NativeLaunch**：`openDPARSFMain/openDPABI` 打开即汉化、窗口标题正确；
   timer 监视器能在 3 秒内自动汉化新出现的窗口，`stopPatchMonitor` 清理 timer；
7. **性能**（本机 R2026a，629×697 的 DPARSFA 窗口）：
   - 单窗口 `patchFigure`：约 **0.1–0.2 s**（冷缓存首次含 TSV 解析）；
   - `unpatchFigure`：约 **20 ms**；
   - `patchAll` 3 个窗口：约 **0.25–0.31 s**；
8. **截图**：测试把真实图窗导出为 PNG 到 `%TEMP%\mrw_native_patch_test\`
   （`native_patch_DPARSF_main.png`、`native_patch_DPARSFA.png`），已人工 `read_image` 检查：
   中文显示正常、无乱码、无换行/截断（窄控件改用半角标点后单行完整显示）。

最近一次 -batch 实测输出（节选）：

```text
================ NativePatch 测试 ================
预期翻译控件数: dpabi=10, DPARSF_main=6, DPARSFA=84
DPARSFA 控件覆盖率: 119/119
dpabi: translated=10 tooltips=10, patch=85.4ms, 还原逐控件一致
DPARSF_main: translated=6 tooltips=6, 还原逐控件一致
popupmenu String 未变，Tooltip=25 字符
patchAll: 3 窗口 / 翻译 100 / 耗时 253.6 ms；unpatchAll 全部逐控件与原始值一致
认不出的按钮文字保持原样，Skipped=1
openDPARSFMain: 已打开并自动汉化（标题 DPARSF）
openDPABI: 已打开并自动汉化（标题 DPABI）
timer 监视器: 自动汉化新窗口成功，清理 1 个 timer（此前清理 0）
DPARSFA 单窗: 汉化 190.2 ms / 还原 19.5 ms（119 控件）
================ 结果：523 项断言，0 失败 ================
TEST PASSED
```

（控制台中文在 GBK 代码页下可能显示为乱码，这是 PowerShell 控制台编码问题；
MATLAB 内部字符串与 PNG 截图中的中文均正常。）

---

## 8. 文件与协作

| 文件 | 说明 |
|---|---|
| `+mrw/NativePatch.m` | 汉化/还原核心（静态类）|
| `+mrw/NativeLaunch.m` | 打开原生窗口 + timer 监视器 |
| `resources/native_labels.tsv` | 9 个窗口 208 行中文标签表（T4 私有数据文件）|
| `tests/test_native_patch.m` | -batch 测试（真实 .fig + 断言 + 截图）|
| `docs/NATIVE_PATCH.md` | 本文档 |

写入边界：本模块**只写**上述 5 个文件；`resources/glossary.tsv` 由 T2 维护、本模块只读；
`D:\Software\DPABI` 与开发期临时目录只读；测试截图写 `%TEMP%`，不提交二进制。
