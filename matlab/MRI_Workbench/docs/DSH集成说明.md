# DSH 集成说明（dsh-mri-workbench 插件）

> 目标：让 MRI 静息态工作台**在 DeepSeek Harness 里启动运作**，分析与代码仍然由 MATLAB + DPABI/DPARSF 高级版在后台执行。
>
> 本机 DSH：**0.2.2-rc.1**（desktop profile）。

## 1. 插件位置与安装状态

| 项 | 值 |
|---|---|
| 插件源码 | 仓库根目录（`index.mjs` / `client.js` / `package.json`） |
| 安装方式 | `plugin_manager install_bundle`（profile `desktop`，本地 link 安装） |
| 安装结果 | `application: applied`，`warnings: []` |
| 插件 ID | `include:dsh-mri-workbench`（bundle row `dsh-mri-workbench`） |
| Host 工具 | `mri_workbench_env` / `scan` / `prepare` / `start` / `status` / `wait` / `cancel` / `open_gui` / `qc` / `params`（可调字段）/ `overrides`（手动参数覆盖） |
| Client 页面 | `conversation.view` 槽位新增 **「MRI 工作台」**（id `mri-workbench`，order 35） |
| 人类命令 | `/mri env | presets | scan <目录> | params [关键词] | overrides [set <base64>|clear] | prepare <预设序号> [k=v] | run | status | cancel | open | qc | qcstatus` |

安装后若页面还没出现「MRI 工作台」标签页，**刷新一次 DSH 页面**即可（Client 模块需要重新加载）。Host 工具与 `/mri` 命令无需刷新即可用。

## 2. 它如何把工作台搬进 DSH

```
会话视图「MRI 工作台」页                     Agent（本机/DSH）
   │ ctx.remote.commands.execute('/mri …')      │ mri_workbench_* 工具
   ▼                                            ▼
Host 插件 dsh-mri-workbench（仅编排，不实现算法）
   ├─ 数据扫描 → MATLAB -batch → mrw.cli('scan', …) → mrw.ScanEngine
   ├─ 配置生成 → MATLAB -batch → mrw.cli('prepare', …) → mrw.CfgBuilder（+运行前校验）
   └─ 后台预处理 → DSH 后台 Job（kind=bash，owner=会话）
          └─ spawn matlab -batch → mrw.headlessRunner → 官方 DPARSFA_run（DPARSF 高级版引擎）
```

- **计算仍在 MATLAB**：插件不重写任何预处理逻辑，直接调用工作台已有 MATLAB 代码（`matlab/MRI_Workbench/+mrw/`）与官方 `DPARSFA_run`。
- **实时反馈**：预处理 Job 的 `run.log` 被 DSH Job 输出源持续泵入，会话顶部「后台任务」列表实时滚动显示；Agent 可用 `job_output` 或 `mri_workbench_wait` 获取同一份日志并汇报。
- **可取消**：取消通过 `ctx.jobs.kill` → `taskkill /T /F` 终止 MATLAB 进程树；Job 会以 `killed` 状态收敛。
- **不改 DPABI 安装**：与原有工作台一致，只读取 DPABI/SPM 路径并写工作区数据（`.mri-workbench/`）。

## 3. 在 DSH 中使用

### 页面上

1. 会话顶部视图切换 → **MRI 工作台**；
2. 输入数据根目录（`<root>/FunRaw/<受试者>/` 或 `<root>/BIDS/`）→ 开始扫描；
3. 选择预设（1 经典 DARTEL / 2 仅功能像 / 3 BIDS / 4 快速质控）→ 生成配置并校验；
4. 开始预处理 → 会话顶部「后台任务」看实时日志；刷新状态/取消运行；
5. 需要完整中文悬停解释、术语库与手动调参时 → 点页面右上角常驻的「打开 MATLAB 桌面版」（等价 `/mri open`；③ 运行卡里也有同一按钮）。

### 对 Agent

> “扫描 `D:\Data\MyStudy`，用快速质控预设生成配置，检查通过后启动预处理，并汇报进度。”

Agent 会使用 `mri_workbench_scan` → `mri_workbench_prepare` → `mri_workbench_start` → `mri_workbench_wait`；运行中用户也能在 Jobs 面板看到同一份日志。

### 命令

```
/mri help
/mri env
/mri presets
/mri scan "D:\Data\MyStudy" 6
/mri params [关键词]                    # 列出可调 Cfg 参数（首次启动一次 MATLAB 读取 CfgSchema，之后缓存）
/mri overrides                         # 查看已保存的参数覆盖
/mri overrides set <base64(JSON数组)>  # 应用参数覆盖
/mri overrides clear                   # 清空参数覆盖
/mri prepare 4
/mri prepare 4 TR=2 IsRemoveFirstTimePoints=true
/mri run
/mri status
/mri cancel
/mri open
```

### 手动调整配置参数（DPARSF 风格参数弹窗）

页面「② 预处理配置」点 **参数设置…（弹窗）** 打开 DPARSF 风格参数面板，可手动调整全部 **97 个 Cfg 字段**，不再只有 4 个预设，也不需要手写 JSON：

- **弹窗界面**：左侧 7 个分组导航（基础设置 / 时间层与头动 / 结构像处理 / 标准化与平滑 / 回归与滤波 / 指标计算 / 高级与运行）；右侧参数表单，按需滚动。
- **中英文对照**：每项显示中文标签 + English 原名 + Cfg key；分组名与标题也中英对照。
- **鼠标悬停解释**：悬停字段显示 tooltip：中文解释（来自 `resources/glossary.tsv` 的 Tip）、类型、默认值、启用条件、是否高级；97/97 字段均有 Tip。
- **控件自适应 + 依赖联动**：bool 开关、enum 下拉、数字输入、向量 `[4, 4, 4]`、文本；不满足启用条件（如未开时间层校正时的层数/层序）自动置灰并提示由哪个参数控制；「0=自动」的字段在默认值处有说明。
- **搜索与高级参数**：搜索框可按中文/English/key 跨分组过滤；「显示高级参数」开关控制高级项。
- **应用**：底部显示「已修改 N 项 / 当前覆盖 M 项」；**应用覆盖** 保存到会话（下次生成配置自动合并），**恢复默认** 重置表单，**清空全部覆盖** 清除所有手动覆盖；卡片的「高级（JSON 覆盖）」保留 JSON 兜底编辑器。
- **实现通道**：弹窗通过 `/mri paramsjson` 获取字段包（含 `tip`），通过 `/mri overrides set <base64>` 保存；与 Agent 工具、`/mri prepare k=v` 共享同一套 Host 逻辑。首次打开需启动一次 MATLAB（约 20 秒）读取 CfgSchema，之后走 `.mri-workbench/schema.json` 缓存（55 KB 字段包）。
- **命令**：`/mri params [关键词]`、`/mri overrides set <base64(JSON数组)>`、`/mri overrides clear`、`/mri prepare 4 key=value`。
- **Agent**：`mri_workbench_params`（字段 + tip）、`mri_workbench_overrides`（show/set/clear）；下一次 `mri_workbench_prepare` 自动合并覆盖。Agent 不应擅自替用户改参数，需先确认。
- **与 MATLAB 桌面版一致**：桌面版「② 预处理参数」也是同一套 CfgSchema（97 字段，全中文 + 悬停解释），两者可以配合使用。

### 人工 QC

- **页面**：点「人工QC」顶部按钮或导航「⑥ 人工QC」→ 在 MATLAB 桌面窗口（可缩放：滚轮缩放/拖拽平移/按钮缩放）中评分；DSH 页面「④ 人工 QC」卡片可 [刷新 QC 评分] / [打开 MATLAB 人工 QC]。
- **Agent 工具**：`mri_workbench_qc`（`workDir` 可选）— 纯 Node 读取 `QC/*.tsv` 与 `HeadMotion.tsv`，返回各模态已评分/总数/平均分、低分（≤2）、未评分、MeanFD 超阈值与最近评语；不启动 MATLAB。适合让 Agent 汇总人工 QC 进度并提示复核。
- **命令**：`/mri qcstatus [workDir]` 返回同上摘要文本；`/mri qc [workDir]` 在 MATLAB 桌面打开可缩放人工 QC 查看器（写入 DPARSF 兼容 `QC/RawT1ImgQC.tsv`、`RawFunImgQC.tsv`、`NormalizationQC.tsv`）。
- 限制：Agent 不应代替用户给出人工 QC 结论，只做数据汇总与提示；`/mri qc` 的 MATLAB 窗口需人工查看。

## 4. 数据与路径

- 插件运行数据：`<工作区>/.mri-workbench/`
  - `index.json`：扫描索引
  - `prep/<时间戳>/Cfg.mat|state.json|checks.json`：预处理配置与检查结果
  - `runs/<时间戳>/run.log|status.json`：每次运行日志与状态
- 环境变量（可选）：`MATLAB_EXE`、`MRI_WORKBENCH_ROOT`、`DPABI_ROOT`、`SPM_ROOT`。
- 默认探测：MATLAB `D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe`，DPABI `D:\Software\DPABI`，SPM12 `D:\Software\spm12`。

## 5. 已验证（本机实测）

| 能力 | 结果 |
|---|---|
| 环境检查 | ✔ MATLAB / DPABI / SPM / 工作台目录全部识别 |
| 扫描 | ✔ 合成 DPARSF 数据集 3 名受试者，Layout=DPARSF，TR=2，时间点/层数自动识别 |
| 配置生成 + 校验 | ✔ 预设 4 通过 6 项检查；故意删点过多时正确报错 |
| 后台启动 | ✔ 创建 DSH Job `bash-…`，会话 Jobs 中显示为「MATLAB · DPARSF 预处理 · 3 名受试者」 |
| 实时日志 | ✔ Job 输出流显示 `Realign Setup:Sub0x OK`、`Congratulations…`，中文正常 |
| 等待/汇报 | ✔ `mri_workbench_wait` 返回 finished、阶段列表与日志尾部 |
| 取消 | ✔ Job 收敛为 killed / “用户取消（MATLAB 进程树已终止）”，状态 cancelled |
| Client 页面 | ✔ `conversation.view` occupant `mri-workbench` 已注册（order 35，active） |
| 人工 QC 工具 | ✔ `mri_workbench_qc` 对样例工作目录返回各模态已评分/平均分/低分/MeanFD 超阈值（见 `docs/VERIFICATION.md` 与 `tests/node/fixtures/qc_dsh_test/`）；默认无参数时按推导链回退并给出中文提示 |
| `/mri qcstatus` | ✔ Host 接线级自测 15 项通过（命令返回摘要文本）；需刷新页面后在 UI 点击验证 |
| `/mri qc` | ✔ 实现为 MATLAB 桌面 `mrw.QcViewer.open`（先校验 +mrw/QcViewer.m 存在）；Lead 已用 -batch 验证 QcViewer 窗口与 QcPanel 可创建、可评分，桌面窗口视觉需人工确认 |
| UI 视觉验证 | ⚠ 无浏览器控制能力，未截图验证；刷新页面后以实际显示为准 |

产物验证：`RealignParameter/HeadMotion.tsv`、`FunRawR/` 正常生成。

## 6. 已知限制

1. 页面 UI 的视觉表现（明暗主题、窄屏布局）未在自动化环境中截图验证；页面组件使用 Host 主题 token，刷新页面即可加载。
2. 扫描/生成配置需启动一次 MATLAB `-batch`（约 15–30 秒），按钮会显示“执行中”。
3. 长时间预处理日志依赖 DSH Jobs；若 jobs 服务不可用，插件会退化为独立进程（用 `/mri status` 轮询）。
4. 交互式 DPARSF 步骤（交互重定向/ROI、FieldMap）仍需 MATLAB 桌面版工作台或原生 DPARSF。
5. 旧的第三方插件 `dsh-matlab-workbench@0.1.0-beta.2`（lemonxiny55，PID 实验台）因 `engines.dsh` 仅声明 `0.2.1-rc.2 || 0.2.1-rc.3`，与 DSH 0.2.2-rc.1 不兼容并被 profile 拒绝；插件市场暂无更新版本。本插件不依赖它，可保留或按需移除。
