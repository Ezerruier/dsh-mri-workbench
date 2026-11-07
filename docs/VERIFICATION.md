# dsh-mri-workbench 验证记录

时间：2026-11-06 00:34 ~ 00:42（Asia/Shanghai）
环境：DSH 0.2.2-rc.1（desktop profile）、MATLAB R2026a、DPABI V10.0_260625、SPM12、Windows。

> 脱敏说明：本地绝对路径与受试者编号已按公开仓库要求脱敏替换，技术结论、数字与命令未改动。

## 1. 安装

```
plugin_manager install_bundle target = <仓库根目录绝对路径>
→ stage=enable, application=applied, warnings=[]
```

插件列表可见：
```
dsh-mri-workbench 0.1.0  enabled=true  installed=true  (row: include:dsh-mri-workbench)
```

## 2. Client 页面注册（cordis_inspect_query Slots.listSubTree root=conversation.view）

occupants：
```
chat            order 0
trajectory      order 10
mri-workbench   order 35   ← 本插件
stats           order 40
```
状态 active=true，说明 Client 模块已加载并完成槽位注册。

## 3. Agent 工具实测（真实调用）

### 3.1 环境检查
`mri_workbench_env`：
```
MATLAB：D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe
工作台目录：<仓库>\matlab\MRI_Workbench
DPABI：D:\Software\DPABI；SPM12：D:\Software\spm12
预设：1 经典 DARTEL / 2 仅功能像 / 3 BIDS / 4 快速质控
```

### 3.2 扫描（mri_workbench_scan）
```
root = ...\testdata\Study（开发期临时测试数据，未随仓库发布）
→ 数据扫描完成：DPARSF 标准目录（3 名受试者）
   WorkingDir=...\Study, StartingDirName=FunRaw
   TR=2, 时间点=6, 层数=8, 数据类型=NIfTI
```

### 3.3 配置生成与校验（mri_workbench_prepare, preset=4 快速质控）
- 无覆盖项：`要删除 10 个时间点，但总时间点只有 6 个` → 校验正确拦截（ok=false）；
- 覆盖 `IsRemoveFirstTimePoints=0` 后：`检查通过（6 项）`，`Cfg.mat` 生成于 `.mri-workbench/prep/<时间戳>/`。

### 3.4 后台启动与实时反馈（mri_workbench_start / job_output / mri_workbench_wait）
```
start → jobId = bash-…（DSH Job），runDir = .mri-workbench/runs/<时间戳>
job_list：bash-… [bash] running — MATLAB · DPARSF 预处理 · 3 名受试者
job_output 实时输出包含：
  [工作台] 后台预处理进程启动…
  Removing First 10 Time Points…
  Realign Setup:Sub01 OK / Sub02 OK / Sub03 OK
  Moving Head Motion Corrected Files:Sub01 OK …
  Congratulations, the running of DPARSFA is done!!! :)
  [工作台] 总耗时：6.9 秒；状态：finished
mri_workbench_wait → MRI 工作台状态：finished；阶段：Realign Setup → Moving Head Motion Corrected Files
```

### 3.5 取消（start → cancel → wait）
```
mri_workbench_cancel → {ok:true, result:"requested"}
Job 通知：[status: killed, 用户取消（MATLAB 进程树已终止）]
mri_workbench_wait → MRI 工作台状态：cancelled
```

### 3.6 产物
```
<数据目录>/RealignParameter/HeadMotion.tsv        存在
<数据目录>/RealignParameter/ExcludeSubjects…txt   存在
<数据目录>/FunRawR/Sub01..03                      存在
```

## 4. 命令路径

`/mri help|env|presets|scan|prepare|run|status|cancel|open` 由 Host `ctx.commands.register` 注册；
页面按钮通过 `ctx.remote.commands.execute(sessionId, '/mri …', [])` 调用同一套 Host 操作
（与 Agent 工具共享实现，符合 DSH “一个操作两个调用方” 的插件实践）。

## 5. 未验证 / 限制

- Client 页面的视觉呈现未通过浏览器截图验证（本环境无浏览器控制能力）；slot 注册与模块加载已确认。
- `mri_workbench_open_gui` 会打开 MATLAB 桌面窗口，未自动测试以免干扰用户桌面。
- 真实 DICOM 数据端到端未验证（本机无真实数据；转换仍由官方 DPARSF 引擎执行）。
- 旧第三方 `dsh-matlab-workbench@0.1.0-beta.2` 与 DSH 0.2.2-rc.1 不兼容（engines 限制），市场无新版；本插件独立工作。

---

# 人工 QC 扩展验证记录（qc-dsh）

时间：2026-11-06 00:44 ~ 00:53（Asia/Shanghai）
环境：DSH 0.2.2-rc.1（desktop profile，**重载由 Lead 执行**）、Node v24.21.0（DSH 运行时自带）、Windows PowerShell 5.1。
依据：`matlab/MRI_Workbench/docs/QC_CONTRACT.md` 第 4 节（DSH 扩展要求）；DPARSF 事实核对自
`D:\Software\DPABI\DPARSF\DPARSFA_run.m:1304-1318 / 1418-1432 / 1121-1129`、
`D:\Software\DPABI\QualityControl\DPABI_QC_TOOL.m:404-429 / 440-464`。

## 6. 改动文件（仅这 4 个）

| 文件 | 内容 |
| --- | --- |
| `index.mjs` | 新增 `mri_workbench_qc` 工具、`/mri qc` / `/mri qcstatus` 子命令、系统提示人工 QC 指引；新增 Node 侧 TSV/HeadMotion 只读解析与摘要（`buildQcSummary`/`renderQcSummary` 等，导出仅供离线自测）；`tool()` 统一输出 `jsonSafe`（剔除 `undefined`、`NaN`/`Infinity` → `null`，避免 DSH “not lossless JSON” 校验错误）。原 8 个工具与命令参数未改。 |
| `client.js` | 「MRI 工作台」页新增「④ 人工 QC」卡片：[刷新 QC 评分]（`/mri qcstatus`）、[打开 MATLAB 人工 QC]（`/mri qc`），输出复用现有 output 区；zh/en locale 补齐。 |
| `README.md` | 新增「人工 QC」章节（TSV 格式、工具参数/返回、`/mri qc`/`/mri qcstatus`、MeanFD 阈值语义）、使用步骤与已知限制。 |
| `docs/VERIFICATION.md` | 本记录。 |

未改动：`matlab/MRI_Workbench/+mrw/**`、`locale/*.json`、`cordis.patch.yml`、`package.json`；未调用 `plugin_manager`、未改 profile。

## 7. 实现要点（与契约对应）

- 工作目录解析顺序：工具参数 `workDir` → 最近 prepare 的 `WorkingDir` → 最近 scan 的 `WorkingDir` → `.mri-workbench/prep/<stamp>/state.json`（`WorkingDir`/`DataProcessDir`、`SubjectID`）→ `.mri-workbench/scan-result.json` → `index.json`（`Detected.WorkingDir`）→ 当前会话工作区（回退时在 `warnings` 与摘要中提示）。显式传入不存在目录 → 中文报错。
- TSV 解析：首行 `Subject ID`/`QC Score` 表头识别；`NaN` → 未评分（null）；UTF-8（含 BOM、CRLF）与 GBK 自适应（DPARSF 在中文 Windows 上 `fopen(...,'w')` 的系统编码）；缺失文件返回 `exists=false` 不抛异常；评语可含 Tab（按前两列切分后保留余下内容）。
- 汇总：受试者总数 = 显式/状态受试者 ∪ TSV 行 ∪ `HeadMotion.tsv` 行 ∪ DPARSF 输出目录（Fun/T1/Realign 前缀及 Results 的受试者子目录，自然排序）去重；每模态 `scored/total/unscored/meanScore/lowScores(≤2)/belowThreshold(Min)/unscoredIDs/recentComments`。
- HeadMotion：`RealignParameter/HeadMotion.tsv` 依表头 `mean FD_Jenkinson` 定位第 21 列（无表头时按 DPARSF 21 列约定），`%e` 科学计数法可解析；多 session 前缀文件回退查找第一个并在 warnings 注明。
- 阈值：默认 `MaxMeanFD=0.2`、`T1Min/FunMin/NormMin=3`；存在 `QC/ManualQC_thresholds.json` 时采用其值。超阈值判定沿用 DPABI_QC_TOOL 语义：`MeanFD >= MaxMeanFD`、`Score < Min` 为低于阈值。
- `/mri qc`：检查 `+mrw/QcViewer.m` 存在 → `spawn(matlab, ['-r', "addpath('<wbRoot>'); mrw.QcViewer.open('<workDir>','T1');"], { detached, stdio:'ignore' })`，返回中文提示；缺失 QcViewer 时中文报错（不启动 MATLAB）。不伪造评分/结论。

## 8. 语法与离线自测结果（已执行）

```
node --check index.mjs   → exit 0
node --check client.js   → exit 0
```

样例（保留供 Lead 复测）：`tests/node/fixtures/qc_dsh_test/`
- `make_fixtures.ps1` + `fixtures.json` → `sample/`（5 名受试者；T1=UTF-8 BOM+CRLF、Fun=GBK、Norm=仅表头、HeadMotion=DPARSF 21 列）、`sample2/`（+`QC/ManualQC_thresholds.json`：T1Min=4、MaxMeanFD=0.3、UseMeanFD=true）、`sample3/`（无 QC/、无 RealignParameter/）。
- 生成命令：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\node\fixtures\qc_dsh_test\make_fixtures.ps1`

```
node tests\node\qc_dsh_test\test-qc-dsh.mjs       → 全部通过：19 项检查（exit 0）
  PASS T1 TSV：表头/行数/NaN→未评分/中文评语（UTF-8 BOM+CRLF）
  PASS Fun TSV：GBK 编码中文评语自动解码
  PASS 缺失 TSV 不抛异常（exists=false）
  PASS 无表头 TSV：Subject01 数据行不被误判为表头
  PASS NormalizationQC 只有表头：exists=true、0 行
  PASS HeadMotion TSV：第 21 列 mean FD_Jenkinson 解析
  PASS discoverSubjectIds：FunRaw/T1Raw/RealignParameter 去重 + 自然排序
  PASS 摘要：受试者总数 = 5（目录发现）
  PASS 摘要：T1 已评分 4/5、平均 3.5、低分 Sub02、未评分 Sub03
  PASS 摘要：Fun 已评分 4/5、平均 2.5、低分 Sub02+Sub10
  PASS 摘要：Norm 文件存在但 0 评分 → meanScore=null、全部未评分
  PASS 摘要：HeadMotion 默认阈值 0.2 → 超阈值 Sub02/Sub04、范围 0.05–0.35
  PASS 阈值文件：MaxMeanFD=0.3 → 仅 Sub02 超阈值；UseMeanFD 透传
  PASS 阈值文件：T1Min=4 → 低于配置阈值名单含 Sub10（低分不重复列出）
  PASS 缺文件：hasScores=false、各模态 available=false、warnings 非空
  PASS 渲染：包含每模态进度、低分、未评分、MeanFD 超阈值、最近评语
  PASS 渲染：阈值文件说明 + 低分提示
  PASS 渲染：无评分时给出打开查看器提示
  PASS JSON-safe：undefined/NaN/Infinity 处理 + 摘要可无损 JSON 往返

node tests\node\qc_dsh_test\test-apply-wiring.mjs → 全部通过：15 项检查（exit 0）
  （mock DSH Host context，不启动 DSH/MATLAB）
  PASS inject 声明保持 tools/systemPrompt/commands
  PASS 原 8 个工具仍注册（完全兼容）
  PASS 新工具 mri_workbench_qc：参数 schema 仅 workDir（可选）
  PASS mri_workbench_qc 显式 workDir → 摘要正确且 lossless JSON
  PASS mri_workbench_qc 渲染文本（tool output.render）
  PASS mri_workbench_qc 缺省 workDir（无最近配置）→ 回退工作区并给出提醒
  PASS mri_workbench_qc 显式 workDir 不存在 → 中文错误
  PASS /mri qcstatus <目录> → 返回与工具一致的摘要文本
  PASS /mri qcstatus（缺省目录）→ 不崩溃，提示无评分
  PASS /mri help 列出 qc / qcstatus 子命令
  PASS /mri qc <不存在的目录> → 中文错误（在 spawn MATLAB 之前拦截）
  PASS 命令 input.hint 包含 qc
  PASS 系统提示新增人工 QC 指引（不伪造 QC 结论）
  PASS 原工具 mri_workbench_env / status 仍可执行（兼容性）
  PASS dispose 函数可调用
```

渲染文本样例（`sample/`，默认阈值；供 Lead 对照）：

```
人工 QC 摘要
- 工作目录：...\tests\node\fixtures\qc_dsh_test\sample
- 工作目录来源：工具参数/命令行指定
- 受试者总数：5 名

T1 原始像（QC/RawT1ImgQC.tsv）：已评分 4/5（80%），平均分 3.5
  · 低分（≤2）：Sub02（2 分）
  · 未评分（1）：Sub03
  · 最近评语：Sub01「图像清晰，无伪影」；Sub02「轻微运动伪影，建议复核」；Sub04「灰白质对比良好」；Sub10「配准可接受」
功能平均像（QC/RawFunImgQC.tsv）：已评分 4/5（80%），平均分 2.5
  · 低分（≤2）：Sub02（1 分）；Sub10（2 分）
  · 未评分（1）：Sub03
  · 最近评语：Sub01「功能平均像正常」；Sub02「信号丢失严重」；Sub04「可接受」；Sub10「伪影明显」
标准化检查（QC/NormalizationQC.tsv）：已评分 0/5（0%），平均分 —
  · 未评分（5）：Sub01、Sub02、Sub03、Sub04、Sub10
头动（RealignParameter/HeadMotion.tsv）：MeanFD 阈值 0.2 mm
  · MeanFD 超阈值（≥ 0.2 mm）：Sub02（0.350）；Sub04（0.220）
  · MeanFD 范围 0.050–0.350，平均 0.164

提示：低分（≤2）或未评分受试者建议人工复核；运行 /mri qc 可在 MATLAB 中打开可缩放人工 QC 查看器。
```

## 9. 待 Lead 重载后验证（qc-dsh 未执行，任务约束：Lead 统一重载与实测）

1. **重载插件**（Lead 执行 `plugin_manager`/desktop profile 重载；qc-dsh 未调用、未改 profile）。
2. 确认 Agent 工具表出现 `mri_workbench_qc`（原 8 个工具仍在），页面「MRI 工作台」出现第 4 张「④ 人工 QC」卡片（zh/en）。
3. 工具实测（用保留样例，避免碰真实数据）：
   `mri_workbench_qc({"workDir":"<repo>\\tests\\node\\fixtures\\qc_dsh_test\\sample"})`
   → 预期输出与第 8 节渲染样例一致；再不带参数调用一次，验证 workDir 推导链（无最近 prepare/scan 时应回退工作区并提示）。
4. 命令实测：`/mri qcstatus "<sample 路径>"` 输出同摘要；`/mri help` 含 `qc`/`qcstatus`。
5. `/mri qc "<sample 路径>"` → 真实 MATLAB 桌面应打开「人工 QC — 可缩放查看」窗口（需 QcPanel/QcModel 已由队友就绪；若 QcPanel 未就绪，QcViewer 会显示占位提示，属预期）。**视觉验证受限**：本环境无浏览器/桌面截图控制能力，需人工确认窗口出现与可缩放交互。
6. 页面按钮实测：点「刷新 QC 评分」→ output 区显示摘要；点「打开 MATLAB 人工 QC」→ 等待数秒后 MATLAB 窗口出现，输出区显示中文提示。
7. 回归：原 `mri_workbench_env` / `status` / `/mri env` / `/mri status` 等仍正常；`mri_workbench_scan → prepare → start → wait → cancel` 路径未被改动（本文件 diff 仅新增函数/工具/命令分支）。
8. 真实 DPARSF 工作目录（预处理后，含 GBK 编码的 `QC/RawT1ImgQC.tsv` 与真实 `RealignParameter/HeadMotion.tsv`）复测一次，确认中文评语无乱码、第 21 列 MeanFD 正确。

已知限制（如实说明）：
- 插件重载、真实 DSH 工具调用与页面视觉验证由 Lead 执行；qc-dsh 仅做语法检查 + 离线函数级/接线级自测。
- `mri_workbench_qc` 只汇总已保存评分，不启动 MATLAB、不评分、不推断图像质量；MATLAB 窗口能否成功弹出无法由 Host 确认。
- 真实 DPARSF 数据上的 GBK/UTF-8 双编码读取、多 session HeadMotion 文件回退仅用合成样例验证。

## 10. Lead 完成的重载与实测（2026-11-06 01:00 前后）

1. **插件重载**：对 bundle row `include:dsh-mri-workbench` 执行 disable → enable，`application: applied`，`warnings: []`。
2. **工具表**：系统提示与工具列表中已出现 `mri_workbench_qc`；原 8 个 `mri_workbench_*` 工具仍可用（`mri_workbench_env` 实测正常）。
3. **工具实测（显式 workDir = `tests/node/fixtures/qc_dsh_test/sample`）**：输出与第 8 节渲染样例**逐行一致**（T1 4/5 平均 3.5、低分 Sub02、未评分 Sub03；Fun 4/5 平均 2.5、低分 Sub02/Sub10；Norm 0/5；MeanFD 超阈值 Sub02/Sub04、范围 0.050–0.350），中文评语无乱码，返回为合法 JSON（无 “not lossless JSON” 错误）。
4. **工具实测（缺省 workDir）**：正确回退到会话工作区并给出中文 warnings（未找到 QC/RealignParameter 目录时的提示完整、不崩溃）。
5. **MATLAB 侧集成（-batch）**：`mrw.QcViewer.open(fixture,'T1')` 创建窗口并成功内嵌 QcPanel，`setZoomFactor(2.5)` → `getZoomFactor=2.50`，评分 4 分 + 中文评语写入后 `QcModel.loadScores` 读回一致；`WorkbenchApp` 第⑥页可打开、同步工作目录并截图。`tests/test_qc_integration_lead.m` 输出 `QC_INTEGRATION_RESULT=SUCCESS`。
6. **人工 QC 组件测试**：`test_qc_model` PASS 177/177、`test_qc_panel` PASS 101/101（详见 `matlab/MRI_Workbench/docs/人工QC验证记录.md`），全工作台回归 **8/8 PASS**。
7. **Client 槽位**：重载后 `conversation.view` occupant `mri-workbench` 仍为 active（order 35）；「④ 人工 QC」卡片随 Client 模块更新，页面需刷新一次可见。
8. **未由自动化验证**：`/mri qc` 在真实桌面弹出的 MATLAB 窗口视觉表现（本环境无浏览器/桌面截图控制，按规范只验证到窗口创建与组件渲染）；`/mri qcstatus` 页面按钮点击路径（Host 接线级 15 项自测通过，UI 点击需人工确认）。

## 11. 手动配置参数（Cfg 覆盖）— 2026-11-06 19:30 前后

背景：用户反馈「工作台的配置选项不能人为调整」。核查结果：MATLAB 桌面版一直有完整参数面板（② 预处理参数，97 字段，可编辑 + 悬停解释）；**DSH 页面的 ② 卡片原先只有预设下拉**，虽然宿主层 `/mri prepare <预设> k=v` 已支持覆盖，但 UI 未暴露。本次补齐 DSH 侧手动调参能力。

### 改动

| 文件 | 内容 |
| --- | --- |
| `matlab/MRI_Workbench/+mrw/cli.m` | 新增 `mrw.cli('schema', resultFile)` 动作：导出 CfgSchema 全部 97 字段（key/group/label/en/type/default/options/dependsOn/advanced）；`prepare` 结果新增 `overrides/overrideCount`（实际应用的覆盖项）。修复 cellstr 被 jsonencode 成嵌套数组的问题（groups 改为写入后再赋值）。 |
| `index.mjs` | 新增工具 `mri_workbench_params`（读 CfgSchema，缓存 `.mri-workbench/schema.json`，支持 filter/refresh）、`mri_workbench_overrides`（show/set/clear，按会话保存）；`opPrepare` 把会话覆盖与工具参数合并；新增命令 `/mri params`、`/mri overrides [set <base64>|clear]`、help/hint/系统提示同步。 |
| `client.js` | 「② 预处理配置」卡片新增「参数覆盖（JSON）」文本编辑框与 [应用覆盖] / [清空覆盖] / [查看可调参数] 按钮；[生成配置并校验] 使用已保存覆盖；中英文 locale 补齐。 |
| `README.md`、`matlab/MRI_Workbench/docs/DSH集成说明.md` | 新增「手动调整预处理参数（Cfg 覆盖）」章节与命令示例。 |

### 实测（Lead，真实 DSH 工具调用）

1. **schema 导出**：`mrw.cli('schema', …)` → `ok=true, count=97`，7 个分组齐全；`SliceTiming.SliceOrder` 默认 `[1,3,5,…,32]`、`IsSliceTiming` 默认 0、依赖条件 `IsNormalize>0` 等字段正确。
2. **`mri_workbench_params`**（filter=「平滑」）：返回 11 项匹配字段，按「标准化与平滑 / 指标计算」分组显示 key、中文名、类型、默认值、依赖、高级标记；缓存生效（首次读取后不重复启动 MATLAB）。
3. **`mri_workbench_overrides`**：
   - `show` → 0 项；
   - `set [{IsRemoveFirstTimePoints:false},{Bad Key!:1},{TR:2.5}]` → 应用 2 项、忽略 1 项非法 key，并提示下一次 prepare 生效；
   - `clear` → 清空。
4. **端到端 prepare**（合成 2 被试 FunRaw 数据，16 时间点，TR=2；预设 4 快速质控）：
   - 未加覆盖时预设 4 原本含「删除前 10 个时间点」；
   - 应用 `IsRemoveFirstTimePoints=false` + `TR=2.5` 后，`mri_workbench_prepare` 返回：`TR=2.5`、`将执行 1 步：头动校正`、结果尾部列出「参数覆盖（2 项）：IsRemoveFirstTimePoints=false；TR=2.5」；
   - 直接加载生成的 `Cfg.mat` 验证：`TR=2.50`、`IsRemoveFirstTimePoints=0`、`RemoveFirstTimePoints=0`、`IsRealign=1`、2 名受试者 —— **覆盖确实写入了 Cfg**，不是只改显示。
5. `node --check index.mjs client.js` → exit 0；插件 disable→enable 重载 `application: applied`；原工具/命令回归正常。
6. 测试数据清理：删除临时测试目录 `cfgtest` 与 `.mri-workbench/` 运行产物，插件状态重载复位（本记录保留命令与结果）。

### 未由自动化验证

- 页面新增的「参数覆盖」编辑框/按钮的**浏览器视觉与点击**未截图验证（本环境无浏览器控制）；其命令路径与上面的 Host 工具/命令共用同一套 helper（`/mri overrides set` 用 base64 传 JSON，避免引号与空格问题），Host 侧逻辑已实测。
- 首次「查看可调参数」需启动一次 MATLAB 读取 CfgSchema（约 20 秒），之后走缓存。

## 12. DPARSF 风格参数设置弹窗（中英对照 + 悬停解释）— 2026-11-06 19:45 前后

背景：用户要求把上一节的手动调参「做成 DPARSF 类似的用户交互界面，可设置成弹窗，优化 UI，中英文对照，鼠标悬停解释作用」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | 新增 `ParameterDialog`：弹窗内左侧 7 个 DPARSF 分组导航、右侧参数表单；字段按类型渲染（bool 开关 / enum 下拉 / int·double 数字 / vector `[4, 4, 4]` / text·dir·file 文本框 / subjects 只读）；中文标签 + English 原名 + Cfg key 中英对照；`title` 原生悬停 tooltip（中文解释 Tip、类型、默认值、启用条件、高级标记）；按 `DependsOn` 自动置灰并显示受哪个参数控制；搜索框跨分组过滤；「显示高级参数」开关；底部「已修改 N 项 / 当前覆盖 M 项」+ 恢复默认 / 取消 / 应用覆盖 / 清空全部覆盖；Esc 或点击遮罩关闭。卡片 ② 改为「参数设置…（弹窗）」+「生成配置并校验」，保留「高级（JSON 覆盖）」折叠兜底编辑器。 |
| `index.mjs` | 新增命令 `/mri paramsjson`（返回 Client 可 `JSON.parse` 的完整字段包，含 tip/options/dependsOn，约 55 KB）；`opSchema` 合并 `resources/glossary.tsv` 的 Tip（缓存版本升到 v2，97/97 字段带 tip）；`renderParams` 分组输出逐条字段。 |
| `matlab/MRI_Workbench/docs/DSH集成说明.md`、`README.md` | 更新为「DPARSF 风格参数弹窗」章节与使用步骤。 |

### 验证（真实执行）

1. **schema + glossary**：缓存 `.mri-workbench/schema.json` `version=2`，97 条字段全部带 `tip`（如 TR 144 字、`SliceTiming.SliceOrder` 119 字悬停解释）；字段包含 `group/label/en/type/default/options/dependsOn/advanced`；`groups` 为 7 个字符串数组（修复 MATLAB cellstr 嵌套 `[[...]]` 问题）。
2. **弹窗数据通道**：`tests/node/param_dialog_test.mjs`（mock DSH Host，不启动 DSH/MATLAB）**9/9 通过**：
   - `mri_workbench_params` / `mri_workbench_overrides` 注册成功；
   - 参数工具返回 97 项、每条带 tip，TR 字段中文名/English/类型正确；
   - `/mri paramsjson` 返回可 `JSON.parse` 的包：97 项、7 分组、枚举 options、依赖 dependsOn、tip 均存在，大小 55,164 字节；
   - `mri_workbench_overrides` set/show/clear 与 `paramsjson` 中的 overrides 联动正确（非法 key 被跳过）；
   - `/mri help`、命令 hint、系统提示均含手动调参与覆盖说明。
3. **弹窗渲染级验证**：`tests/node/param_dialog_render_test.mjs`（最小 React 假实现执行 `client.js` 真实渲染函数，不启动浏览器）**8/8 通过**：
   - 页面初始渲染无异常，含「参数设置…（弹窗）」按钮；
   - 点击后请求 `/mri paramsjson` 并渲染出弹窗（role=dialog）；
   - 弹窗含 7 个分组导航与中英分组名（基础设置 / Basic …）；
   - 当前分组字段显示「中文标签 + English 原名 + Cfg key」；
   - 字段悬停 `title` 含 glossary 中文 Tip、类型、默认值（实测 TR tooltip 为「重复时间 TR（秒，0=自动） / TR … 说明：扫描重复时间 TR… 类型：小数 / double；默认：0」）；
   - 切换「结构像处理」后 enum 下拉与中文选项（不分割/旧版分割…）正常渲染；
   - 点「应用覆盖」会调用 `/mri overrides set <base64>`；
   - 应用后弹窗关闭、页面恢复、覆盖计数更新。
4. **语法与加载**：`node --check index.mjs client.js` = 0；插件 disable→enable 重载 `application: applied`；
5. **Client 槽位**：`conversation.view` occupant `mri-workbench` 仍为 active（order 35）。
6. **无浏览器视觉验证**：本环境无浏览器控制能力，弹窗的真实浏览器渲染/悬停样式/点击未做截图验证；以上为「数据通道 + 渲染函数 + 注册 + JS 语法」级证据，页面侧最终视觉需人工刷新后确认。

### 已知限制

- 首次打开弹窗需启动一次 MATLAB 读取 CfgSchema（约 20 秒，之后走 55 KB 缓存）；打开时静默执行 `/mri paramsjson`，不把大 JSON 写进执行输出区。
- 悬停解释使用浏览器原生 `title` tooltip（样式随系统）；如需自定义富文本 tooltip 需进一步开发。
- 「恢复默认」只把表单重置为 CfgSchema 默认值（应用后仍会显式覆盖这些字段）；要彻底清除手动覆盖请用「清空全部覆盖」。
- 弹窗按 1120×760（最大 96vw×90vh）设计，窄屏下左栏固定 190px、表单自适应；真实浏览器/DPI 下的视觉细节待人工确认。

## 13. 参数弹窗依赖联动修复：勾选父开关后子字段仍置灰 — 2026-11-06 20:10 前后

背景：用户反馈「删除个数（`RemoveFirstTimePoints`，启用条件 `IsRemoveFirstTimePoints=1`）已经设置了，为什么还是灰色的」。

根因：`client.js` 的依赖判断 `condMet` 用 `sameValue`（`JSON.stringify` 比较）核对父开关值——
- CfgSchema 的 `dependsOn.Value` 由 MATLAB 导出为数值 `1`；
- 弹窗 bool 控件写回的是 JS 布尔值 `true`。

`JSON.stringify(true) !== JSON.stringify(1)`，所以勾选「删除初始时间点」后子字段永远不满足条件、保持置灰；已保存为布尔 `true` 的覆盖（README 示例/旧会话）重新打开弹窗时同样置灰。MATLAB 桌面版 `mrw.CfgSchema.cmpVal` 已把 logical 转 double，故桌面版不受影响。同类问题影响所有「bool → 子字段」依赖（如 `IsSliceTiming` → 层数/层序、`IsAllowGUI` → 交互项）。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | 新增 `normalizeCondValue`（`true/false → 1/0`，兼容字符串 `"true"/"false"`），`condMet` 比较前归一化父值与依赖值；bool 控件写回改为数值 1/0，与 CfgSchema 默认值/Cfg 数值约定一致。 |
| `tests/node/param_dialog_dep_test.mjs` | 新增依赖联动回归测试（渲染级，不启动浏览器/DSH/MATLAB）：默认置灰 → 勾选父开关后立即解禁；应用覆盖保存为数值 1/0 且带删除个数 10；模拟刷新后布尔覆盖 `value:true` 仍可解禁。 |

### 验证（真实执行）

1. 修复前 `node tests\node\param_dialog_dep_test.mjs`：在「勾选父开关后，删除个数立即解禁」处 FAIL（实际 `disabled=true`），复现用户现象。
2. 修复后：`tests/node/param_dialog_dep_test.mjs` **6/6 PASS**；原 `tests/node/param_dialog_render_test.mjs` **8/8 PASS**；`tests/node/param_dialog_test.mjs`（Host 接线）**9/9 PASS**；`node --check client.js` exit 0。
3. 页面生效方式：Client 模块更新需刷新页面一次（本环境无浏览器控制，弹窗真实视觉/点击仍需人工刷新后确认）。

### 已知限制

- 布尔归一化只在比较层进行，已保存的旧布尔覆盖不会被改写（下次应用覆盖时自然写成 1/0）。
- 本修复只涉及 Client 弹窗的依赖判断与 bool 写值，不改 Host/命令/Cfg 构建逻辑。

## 14. 并行 worker 数真正生效：headlessRunner 显式建池 — 2026-11-06 20:45 前后

背景：用户问「是不是能设置并行分析被试数，就是多个核磁数据一同处理」。

核查：`ParallelWorkersNumber`（高级与运行，0=关闭）字段存在，但原实现只在 `N=0` 时关 `parallel.Settings.Pool.AutoCreate`；`N>0` 时放任 parfor 自动建池——DPARSFA_run 最早的 parfor（删初始时间点，`:627-631`）在引擎建池代码块（`:1704-1717`）之前执行，会先建本机默认 **24 worker** 池，导致设定的 N 被忽略、24GB 内存易被抢爆。

### 改动

| 文件 | 内容 |
| --- | --- |
| `matlab/MRI_Workbench/+mrw/headlessRunner.m` | 步骤 3 重写：始终 `ps.Pool.AutoCreate=false`；`N>0` 时按 `min(N, 物理核心数, 被试数)` 显式 `parpool('Processes',N)`（失败回退 `parpool(N)`，再失败回退串行并写日志）；`N<=1` 不建池；日志记录上限截断与池大小。 |
| `matlab/MRI_Workbench/tests/test_parallel_pool_lead.m` | 新增集成测试：2 名合成被试 + 快速质控预设 + 请求 6 worker → 期望自动降为 2 并建 2-worker 池，且日志无 24 worker 自动池。 |
| `matlab/MRI_Workbench/+mrw/CfgBuilder.m` | 运行前校验新增：`ParallelWorkersNumber` 超过被试数时提醒“运行时将按被试数 N 运行”（实测 6 vs 2 → 1 项提醒）。 |
| `matlab/MRI_Workbench/docs/DPARSFA_ENGINE.md`、`matlab/MRI_Workbench/resources/glossary.tsv` | 同步并行机制说明与调参建议（24GB 内存下的推荐值）。 |

### 验证（真实执行）

1. `matlab -batch "addpath('<tests>'); test_parallel_pool_lead"` → `PARALLEL_POOL_TEST=SUCCESS`（exit 0）。
   - 日志含：`并行数 6 超过“物理核心(24)/被试数(2)”上限，自动调整为 2`
   - 日志含：`已连接到具有 2 个工作单元的并行池`
   - 日志含：`[工作台] 并行：已创建 2 worker 并行池（物理核心 24，被试 2 名）`
   - 无 `24 个工作单元` / `24 worker` 自动池记录；DPARSFA_run 正常结束（21.6 s，状态 finished）。
2. `N=0` 串行路径保持原逻辑（`AutoCreate=false` + 日志“未启用并行…”），未改 Cfg 默认值；回归运行 `test_runner_lead`（2 被试、快速质控）→ exit 0、`FINAL_STATE=finished`、耗时 6.8 s。
3. 并行模式下日志会出现 DPARSF 原有 parfor 变量作用域警告（`SliceOrder`/`RefFile`/`DirImg`），不影响运行。

### 推荐值（本机 Intel Ultra 7 270K Plus，24 物理核 / 24GB RAM）

- 快速质控（仅转换+头动校正）：6–8
- 仅功能像（EPI 模板标准化 + 平滑 + 指标）：4–6
- 经典 DARTEL 全流程：3–4
- 原则：N ≤ 被试数；内存不足时回退 0（串行）。

### 已知限制

- 并行只加速引擎里跨被试的 parfor 步骤；分割/DARTEL 等组步骤仍串行，加速比有限。
- 建池会额外占用 10–30 s 启动时间；被试很少（1–2 人）时收益小。
- 若 PCT 缺失/内存不足导致建池失败，会自动回退串行（日志有警告），不中断任务。

## 15. 页面 ② 卡新增「并行 worker 数」快速选择 — 2026-11-06 21:05 前后

背景：用户要求「优化工作站界面，能让我选择 worker」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | ② 预处理配置卡新增「并行 worker 数（被试并行）」下拉框（`0 · 串行（默认）` / 2 / 4 / 6 / 8 / 12），带 `min(设定值, 物理核心数, 被试数)` 说明；页面加载时经 `/mri paramsjson` 同步当前覆盖；选择后经 `/mri overrides set` **只改 `ParallelWorkersNumber` 一项**并保留其他覆盖（如 TR）；选「0 · 串行」移除该项；当前覆盖值不在固定选项里时自动补一个选项。 |
| `tests/node/worker_select_test.mjs` | 新增渲染级接线测试：下拉框/选项/说明渲染；选 4 保存覆盖且保留 TR；选串行移除 worker 覆盖。 |

### 验证（真实执行）

1. `node tests/node/worker_select_test.mjs` → **3/3 PASS**。
2. 回归：`tests/node/param_dialog_render_test.mjs` 8/8、`tests/node/param_dialog_dep_test.mjs` 6/6、`tests/node/param_dialog_test.mjs`（Host 接线）9/9，`node --check client.js` exit 0。
3. 生效方式：Client 模块更新需刷新页面一次（本环境无浏览器控制，真实浏览器视觉/点击仍需人工刷新后确认）。

### 已知限制

- 下拉框只列常用值；其他数值仍可在「参数设置…」弹窗（勾选「显示高级参数」→「高级与运行」）或 `/mri prepare <预设> ParallelWorkersNumber=N` 设置。
- 首次打开页面时若 CfgSchema 缓存不存在，会静默触发一次 MATLAB 读取（约 20 秒），不影响页面其他操作。
- 页面不启动 MATLAB，只读写 Host 会话里的参数覆盖；实际建池仍由 MATLAB 侧 `headlessRunner` 完成（见第 14 节）。

## 16. 新增「⑤ 头动结果解读与可视化」与 `mri_workbench_results` — 2026-11-06 21:30 前后

背景：用户反馈「经工作台运作后头动校正完成，但 DPARSF 的结果表格看不懂，请新添功能，可视化并带解释分析结果」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `index.mjs` | 新增纯 Node 读取链：`parseHeadMotionTable`（`RealignParameter/HeadMotion.tsv` 21 列 → 命名字段）、`findFdSeriesFiles`（逐帧 `FD_Jenkinson/FD_Power/FD_VanDijk`）、`parseExcludeSubjectsFile`（最大头动排除名单）、`buildHeadMotionResults`（每人指标 + 曲线 + 组摘要 + 阈值分层提示 + 中英文列解释）；新增 Agent 工具 `mri_workbench_results({workDir?, threshold?})`、命令 `/mri results [工作目录]` 与 `/mri resultsjson [工作目录\|阈值]`（供页面）、help/hint/系统提示同步；工作目录复用 `resolveQcWorkDir`（最近配置 → 最近扫描 → 落盘 prep → 工作区）。 |
| `client.js` | 新增「⑤ 头动结果解读与可视化」整宽卡片：组摘要 + 每名受试者指标表（mean FD_Jenkinson/FD_Power、最大平移/旋转、FD_Power>0.2 帧数/占比、启发式提示 pill）、逐帧 FD SVG 折线（蓝=FD_Jenkinson、橙=FD_Power、红虚线=阈值、红点=坏点帧）、逐列中文解释、最大头动排除名单；支持 0.2/0.5/1.0 mm 阈值切换与表格行切换受试者；页面加载自动读取一次，失败时保留手动按钮。 |
| `README.md` | 新增「头动结果解读」章节（HeadMotion.tsv 列含义表、阈值判读参考、命令与工具用法）。 |
| `tests/node/results_test.mjs`、`tests/node/results_card_test.mjs`、`tests/node/fixtures/results_fixture/` | Host 解析/命令测试 + 卡片渲染测试 + 合成 fixture（3 名受试者、每名 10 帧）。 |

### 验证（真实执行）

1. `node tests/node/results_test.mjs` → **8/8 PASS**（表格解析、组摘要、阈值分层、阈值参数改变名单、排除名单、空目录不抛异常、`/mri results` 文本、`/mri resultsjson` JSON）。
2. `node tests/node/results_card_test.mjs` → **4/4 PASS**（卡片渲染、读取后表格/曲线/解释、行切换受试者、阈值切换重新请求）。
3. 回归：`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3、`param_dialog_test`（Host 接线）9/9、`node --check client.js/index.mjs` 均 exit 0。
4. **真实数据验证**（用户当前工作目录 `D:\Data\MyStudy`，快速质控预设，6 名受试者 × 230 帧）：
   `mri_workbench_results({workDir:...})` 返回 available=true、6 名受试者、每人 230 帧曲线；组均值 mean FD_Jenkinson = **0.072 mm**，最大 0.105（sub-S06_ses-endpoint），MeanFD ≥ 0.2 mm 名单为空；每人坏点帧数/占比与 `HeadMotion.tsv` 一致（如 sub-S06_ses-baseline 62 帧 / 27.0%）。
5. 另生成离线图（开发期临时产物，未随仓库发布）与汇总 `headmotion_summary.csv` 供对照（用 Pillow 绘制，数据源同上）。

### 已知限制

- 目前只覆盖头动结果（用户当前最先遇到的表）；分割/标准化/ALFF 等后续结果表暂未做同款解读，可按相同模式扩展（`Result` 目录解析 + 卡片）。
- “提示”是按均值与坏点占比的启发式分层，不是 DPABI 正式 QC 评分；人工评分仍走 ④ 或 `/mri qc`。
- 页面 ⑤ 卡需要刷新一次页面/等 HMR 加载新 Client 模块；Host 工具与命令已随插件热更新可用。

## 17. ⑤ 卡 FD 曲线改为多受试者可选叠加 — 2026-11-06 21:55 前后

背景：用户要求「逐帧 FD 曲线可以选择被试，而不是只展示 1 个」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | ⑤ 卡 FD 曲线改为多受试者叠加：默认全选；上方提供受试者复选框（稳定配色）、「全选/清空选择」按钮与曲线指标下拉（FD_Jenkinson / FD_Power，切换不需要重新读取文件）；点击表格行也可加入/移出曲线；空选时显示提示。工具提示/说明文案同步。 |
| `tests/node/results_card_test.mjs` | 覆盖默认全选叠加、勾选/表格行多选切换、指标切换不重新请求、全选/清空、阈值切换。 |
| `README.md` | 使用步骤与功能说明补充「多受试者叠加 + 指标切换」。 |

### 验证（真实执行）

1. `node tests/node/results_card_test.mjs` → **6/6 PASS**（含默认 3 条曲线叠加、取消 SubB 剩 2 条、点行恢复 3 条、切 FD_Power 仍 3 条且不发新请求、清空/全选、阈值切换）。
2. 回归：`results_test` 8/8、`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3、`param_dialog_test` 9/9；`node --check client.js/index.mjs` exit 0。
3. 真实工作目录（6 名受试者 × 230 帧）下 ⑤ 卡默认叠加 6 条 FD_Jenkinson 曲线；可单独勾选查看某一受试者。

### 已知限制

- 被试很多（如数十人）时全选叠加会较密，可取消勾选或改用「只看少数几人」；图表纵轴按当前所选受试者的最大 FD 自适应。
- FD_Power 模式下红点（超阈值帧）仅用于 FD_Jenkinson；两指标可分别查看，避免同一图内线型过多。

## 18. 新增经验分级参考与 Scrubbing/Censor 功能 — 2026-11-06 22:20 前后

背景：用户要求「新增参考阈值：最大平移 / 旋转、坏帧比例，并给出经验分级参考；新增 scrubbing / censor 功能与相应解释」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `index.mjs` | ① 结果 JSON 新增 `references`（最大平移/旋转/坏帧比例的 4 档经验分级 + 说明）与每人 `grades`；`renderResults` 输出分级参考与 scrubbing 说明。② 新增 `buildCensorPlan` / `opCensorExport` / `opCensor`：按 FD_Jenkinson/FD_Power 每帧阈值标记坏帧（支持 previous/later 邻域扩展），计算帧号（删点后 1-based）、数量/占比；`export=true` 写入 `<workDir>/ScrubbingPreview/<FDtype>_<阈值>/<subj>_censor_frames.txt` 与 `censor_summary.tsv`。③ 新增 Agent 工具 `mri_workbench_censor`、命令 `/mri censor [jenkinson|power] [阈值] [工作目录]`、help/hint/系统提示。 |
| `client.js` | ⑤ 卡表格对最大平移/最大旋转/坏帧比例按分级着色（悬停显示档位）；新增「经验分级参考」区块；新增「坏帧 / Scrubbing（censor）」区块：FD 类型 + 每帧阈值 + 方式（cut/nearest/linear/spline/pchip）选择、实时坏帧预览表（每人坏帧数/占比/前 12 帧号）、「导出坏帧清单」（调用 `/mri censor`）、「写入 scrubbing 参数覆盖」（合并写入 `IsScrubbing=1`、`Scrubbing.FDType/FDThreshold/ScrubbingMethod`，保留其他覆盖）；新增 scrubbing 中文说明。 |
| `README.md` | 补充经验分级表、Scrubbing/censor 用法与 DPABI 两种做法说明、命令示例。 |
| `tests/node/results_test.mjs`、`tests/node/results_card_test.mjs` | Host 测试扩展分级 JSON 与 censor 工具/命令/导出文件断言；卡片测试扩展分级着色、坏帧预览实时计算、导出调用与参数覆盖合并。 |

### 验证（真实执行）

1. `node tests/node/results_test.mjs` → **12/12 PASS**（新增：references/grades；censor 计算 SubA=0、SubB=[3]、SubC=[3,5,6,7,8,9,10]；export 写文件与 summary；`/mri censor` 命令；测试后清理 `ScrubbingPreview`）。
2. `node tests/node/results_card_test.mjs` → **10/10 PASS**（新增：分级参考/着色、坏帧预览按 FD 类型阈值实时更新、导出显示路径、scrubbing 参数覆盖合并且保留 TR）。
3. 回归：`worker_select_test` 3/3、`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`param_dialog_test` 9/9；`node --check client.js/index.mjs` exit 0。
4. **真实数据**（`D:\Data\MyStudy`，6 被试 × 230 帧）：
   - 分级：sub-S06_ses-baseline 最大平移 1.01 mm →「需关注」；sub-S04_ses-endpoint 最大旋转 1.27° →「需关注」；sub-S06 两个 session 坏帧比例 27%/30% →「偏高」；其余多为「可接受」。
   - FD_Jenkinson > 0.2 mm：5/6 人有坏帧，合计 78 帧（最高 sub-S06_ses-endpoint 29 帧 / 12.6%）。
   - FD_Power > 0.5 mm：4/6 人有坏帧，合计 39 帧（最高 sub-S04_ses-baseline 14 帧 / 6.1%）。

### 已知限制

- 分级是启发式参考，平移/旋转档位取自 DPARSF 排除档位的简化，坏帧比例档位非文献共识；不替代人工 QC 与正式入组决定。
- 页面坏帧预览使用页面已加载的曲线（超过 600 帧会被抽样），帧号为近似值；导出清单由 Host 用完整 FD 序列计算。
- 「写入 scrubbing 参数覆盖」只写 Cfg；需重新「生成配置并校验」并在后续指标/回归流程运行才生效；当前快速质控（仅头动校正）预设不会执行 scrubbing 步骤。
- 邻域扩展（previous/later）当时仅通过 `mri_workbench_censor` 工具参数提供，页面未暴露输入框（已在 §19 补上页面选择）。

## 19. ⑤ 卡新增 Scrubbing 前/后扩展帧数（PreviousPoints / LaterPoints）选择 — 2026-11-07 09:03 前后

背景：用户要求「给核磁工作台增加 scrubbing-PreviousPoints / LaterPoints 功能选择」——§18 的 ⑤ 卡坏帧预览/导出/参数覆盖只能按坏帧本身计算，前/后邻域扩展仅在 Agent 工具里传 `previous`/`later`，页面未暴露。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | ⑤ 卡「坏帧 / Scrubbing（censor）」区块新增两个下拉：**向前扩展帧数**、**向后扩展帧数**（0–12，默认 0；悬停 title 与提示文案说明对应 DPABI `Scrubbing.PreviousPoints/LaterPoints`）。坏帧预览按「坏帧 ± 前/后扩展」合并去重实时计算；「导出坏帧清单」把 `prev=N later=N` 传给 `/mri censor`；「写入 scrubbing 参数覆盖」新增 `Scrubbing.PreviousPoints` / `Scrubbing.LaterPoints`（恒写 0，可清除旧覆盖）；预览标题与抽样提示说明扩展后帧号同样可能为近似值。zh/en locale 补齐。 |
| `index.mjs` | `/mri censor` 新增 `prev=N` / `previous=N` / `later=N` 参数解析（clamp 0–12），help、命令 input hint、系统提示与 `buildCensorPlan` 的 message 同步说明；导出目录在扩展非 0 时追加 `_prevX_laterY`（沿用原有行为）。 |
| `README.md` | ⑤ 卡说明、`/mri censor` 语法、`Scrubbing.PreviousPoints/LaterPoints` 用法（含 `Covremove.HeadMotionScrubbingRegressors.*` 对应参数）与导出目录后缀更新。 |
| `tests/node/results_test.mjs`、`tests/node/results_card_test.mjs` | Host：工具 `previous/later` 扩展结果、`/mri censor … prev=1 later=2` 命令导出帧号；卡片：两个选择器渲染、扩展预览、导出命令参数、参数覆盖写入。 |

### 验证（真实执行）

1. `node tests/node/results_test.mjs` → **14/14 PASS**（新增：`mri_workbench_censor` 前 1 后 1 扩展，SubB 基础 [3] → [2,3,4]、SubC [3,5,6,7,8,9,10] → [2..10]；`/mri censor jenkinson 0.2 prev=1 later=2` 生成 `ScrubbingPreview/FD_Jenkinson_0p2mm_prev1_later2/`，SubB 文件 [2,3,4,5]、SubC 文件 [2..10]）。
2. `node tests/node/results_card_test.mjs` → **11/11 PASS**（新增：前/后扩展选择器存在且为 `censor-previous`/`censor-later`；SubB/SubC 扩展后帧号与数量/占比；导出命令为 `/mri censor jenkinson 0.2 prev=1 later=2`；参数覆盖含 `Scrubbing.PreviousPoints=1` / `Scrubbing.LaterPoints=2`）。
3. 回归：`param_dialog_test` 9/9、`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3；`node --check client.js`、`node --check index.mjs` 均 exit 0。
4. **运行中 Host 重载**：`plugin_manager set_plugin include:dsh-mri-workbench`（enabled false → true），两次均 `application=applied`、`warnings=[]`；重载后本轮系统提示已包含新的 prev/later 说明、`mri_workbench_censor` 调用正常（fixture 上返回前 1/后 1 扩展后的 SubC 9 帧、SubB 3 帧），说明运行中的 Host 已加载新 `index.mjs`。
5. Client 端：`dsh-client-hmr`（500 ms stat-poll）会在 `client.js` 变更后热重载插件；若页面未立即变化，刷新一次页面即可。没有浏览器控制能力，未做真实视觉截图确认（沿用既有验证方式）。

### 已知限制

- 页面预览基于已加载的 FD 曲线（>600 帧会抽样；DPARSF 真实 230 帧数据不触发），抽样时帧号与扩展结果均为近似值；导出清单始终由 Host 用完整序列计算，以导出为准。
- 页面「写入参数覆盖」当时只写 `IsScrubbing` 这一套 `Scrubbing.PreviousPoints/LaterPoints`；`Covremove.IsHeadMotionScrubbingRegressors` 回归量方式已在 §20 补到页面（「Scrubbing 方式」选 spike）。
- 扩展帧数限制 0–12（Host 侧 `clampInt`），超出范围会被截断；是否扩展及扩展多少属于研究方案决定，需在方法中写明。

## 20. ⑤ 卡新增「Spike 回归」方式（Covremove 头动 scrubbing 回归量）— 2026-11-07 09:23 前后

背景：用户问「怎么没有 Spike 功能」。核对本机 DPABI/DPARSF 源码与界面：DPABI 没有名为 Spike 的独立预处理步骤/菜单；DPABI 官方论坛把「头动 scrubbing 回归量」（每坏帧一个回归量、不缩短序列，`Cfg.Covremove.IsHeadMotionScrubbingRegressors`）称为 **spike regression**。经与用户确认，本次在页面 ⑤ 补上该方式。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | ⑤ 卡「Scrubbing 方式」下拉新增 **spike** 选项（`spike · 每坏帧一个回归量（不缩短序列）`）；选择后显示说明（DPABI 对应 `Covremove.IsHeadMotionScrubbingRegressors=1` + `HeadMotionScrubbingRegressors.*`、要求流程含协变量回归、与 IsScrubbing 互斥）。「写入 scrubbing 参数覆盖」按方式分支：spike → 清掉两套旧值后写 `IsScrubbing=0`、`Covremove.IsHeadMotionScrubbingRegressors=1`、`Covremove.HeadMotionScrubbingRegressors.{FDType,FDThreshold,PreviousPoints,LaterPoints}`；常规方式 → 写 `IsScrubbing=1` + `Scrubbing.*` 并显式 `Covremove.IsHeadMotionScrubbingRegressors=0`（两种互斥）。写入提示/说明文案 zh/en 同步。 |
| `index.mjs` | 系统提示补充页面 ⑤ 的 spike 方式（= 头动 scrubbing 回归量、与 IsScrubbing 互斥、依赖 `IsCovremove=1`）。命令与工具参数未变（坏帧导出与方式无关）。 |
| `README.md` | 页面 ⑤ 说明、Scrubbing 章节新增 spike 方式的两套覆盖字段、生效条件（预设 1/3 已启用回归；预设 2/4 需手动 `IsCovremove=1`）与互斥规则。 |
| `tests/node/results_card_test.mjs` | 新增：spike 选项存在、选择后显示提示、写入回归量覆盖（含前/后扩展 1/2 与 TR 保留、无 `Scrubbing.*` 残留）、切回 cut 时写 `IsScrubbing=1` 且显式关闭回归量。 |

### 验证（真实执行）

1. `node tests/node/results_card_test.mjs` → **13/13 PASS**（新增 2 项 spike 相关检查）。
2. `node tests/node/results_test.mjs` → **14/14 PASS**（Host 侧未改动，回归通过）；`node --check client.js`、`node --check index.mjs` 均 exit 0。
3. 回归：`param_dialog_test` 9/9、`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3。
4. **运行中 Host 重载**：预处理空闲时 `plugin_manager set_plugin include:dsh-mri-workbench`（enabled false → true），两次均 `application=applied`、`warnings=[]`；重载后系统提示包含新的 spike 说明。页面端 Client 插件由 HMR/图更新重载，刷新页面一次即可看到新选项。
5. 语义核对（本机 DPABI 源码）：`DPARSFA_run.m:2854-2884` / `3791-3821` 在 `Covremove.IsHeadMotionScrubbingRegressors==1` 时按 FD 阈值 + `PreviousPoints`/`LaterPoints` 生成逐帧 0/1 回归量（`BadTimePointsRegressor` 拼进 `CovariablesDef.CovMat`），确认不删点、不插值；`DPARSF_ScrubbingSetting_gui.m` 在该分支隐藏方法选项并显示 "use each bad time point as a regressor"。DPABI 全目录检索无 "spike" 源码符号，故工作台按论坛术语映射为 spike regression。

### 已知限制

- Spike 回归只在包含「协变量回归」步骤的流程里执行：经典 DARTEL（预设 1）/ BIDS（预设 3）默认 `IsCovremove=1`；仅功能像（预设 2）/ 快速质控（预设 4）为 0，需在「参数设置…」弹窗（显示高级参数）里手动开启 `IsCovremove=1`，否则覆盖写入后不会改变输出。
- 页面不会自动开启 `IsCovremove`：是否做协变量回归属于研究方案决定（与 §16 的“不替用户改参数”原则一致）。
- 「Spike」是 DPABI 社区/论坛对 scrubbing regressors 的称呼，不是 DPABI 官方菜单名；DPABI/DPARSF 没有 despiking（去尖峰）预处理步骤，若需要 despike 需另行选择工具。
- 坏帧预览/导出与 Scrubbing 方式无关：spike 方式仍使用同一份坏帧清单（帧号定义不变）。

## 21. 扫描输出新增「目录处理历史」解释 — 2026-11-07 10:12 前后

背景：用户扫描 `D:\Data\MyStudy` 时，执行输出只有受试者列表与一条「检测到多个功能像起始目录（FunImg/FunImgA/FunImgAR/FunImgARB）」提醒，不知道这些目录各自经过什么处理。用户要求：**在执行输出栏中给目录下文件增加"数据经过什么处理"的解释**。

### 改动

| 文件 | 内容 |
| --- | --- |
| `index.mjs` | 新增模块级纯函数（均导出供离线测试）：`decodeDparsfFunDir(name)` 解析 `FunImg`/`FunRaw` + 后缀字母（`A` 层校正、`R` 头动校正、`C` 协变量回归、`W` 标准化、`S` 平滑、`F` 滤波、`D` 去趋势、`B` Scrubbing、`sym` VMHC 对称化；支持 `S2_` 多 session 前缀）；`buildProcessingHistory(workDir,{startingDirName})` 汇总阶段目录链、每目录受试者数、`RealignParameter/Results/T1Img/VoxelSpecificHeadMotion` 等目录用途与续跑建议；`renderProcessingHistory(history)` 渲染为执行输出文本行。`opScan` 扫描后附加 `processingHistory` 字段；`renderScan` 在提醒之后追加「处理历史 / 逐目录说明 / 文件命名 / 续跑提示」；`mri_workbench_scan` 工具描述同步说明会解释处理历史。 |
| `README.md` | 使用步骤 1 提及扫描输出包含处理历史；新增小节「扫描输出：目录处理历史（FunImg* 后缀含义）」（各后缀含义、结果目录用途、续跑提示、命令/工具等价）。 |
| `tests/node/scan_history_test.mjs`（新增） | 覆盖：目录名解码（层校正/头动校正/Scrubbing/多 session/VMHC 后缀/非功能像目录返回 null）；真实目录结构的阶段链排序、受试者数、结果目录说明、只补 Scrubbing 时建议 `StartingDirName=FunImgAR`；输出文本包含每条说明；只有 `FunImg` 时提示「删除初始时间点」是原地改写；无功能像目录（BIDS/空目录）不输出也不抛异常；`FunRaw` DICOM 目录可识别。 |

### 验证（真实执行）

1. `node tests/node/scan_history_test.mjs` → **6/6 PASS**。
2. 回归：`results_test` 14/14、`results_card_test` 13/13、`param_dialog_test` 9/9、`param_dialog_render_test` 8/8、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3；`node --check index.mjs` exit 0。
3. **运行中 Host 重载 + 真实数据扫描验证**：`plugin_manager set_plugin include:dsh-mri-workbench`（enabled false → true，均 `application=applied`、`warnings=[]`）；随后对用户真实目录执行 `mri_workbench_scan`，输出末尾追加：
   ```
   - 数据目录处理历史：FunImg → FunImgA → FunImgAR → FunImgARB
     · FunImg：功能像 NIfTI 起始数据（6 名受试者；「删除初始时间点」会原地改写此目录）
     · FunImgA：功能像 NIfTI 起始数据 → 时间层校正（Slice Timing）（6 名受试者）
     · FunImgAR：功能像 NIfTI 起始数据 → 时间层校正（Slice Timing） → 头动校正（Realign）（6 名受试者）
     · FunImgARB：功能像 NIfTI 起始数据 → 时间层校正（Slice Timing） → 头动校正（Realign） → Scrubbing（坏帧剔除/插值）（6 名受试者；输出文件 <受试者>/<受试者>_4DVolume.nii）
     · RealignParameter：头动校正参数与 FD 曲线（rp_*.txt、mean*.nii、FD_Jenkinson/FD_Power/FD_VanDijk_*.txt、HeadMotion.tsv、ExcludeSubjects*.txt）
     · Results / T1Img / VoxelSpecificHeadMotion：…
   - 文件命名：阶段目录内的 4D NIfTI 由 SPM/DPARSF 按前缀命名（a=层校正、r=头动校正、w=标准化、s=平滑）；Scrubbing 输出为 <受试者>_4DVolume.nii。
   - 提示：…（只补 Scrubbing：起始目录名=FunImgAR…；完整重跑请先恢复原始数据）
   ```
   同时确认该用户最新的 DPARSF 运行（`runs/20261107-095805-540`）状态为 finished（3.0 分钟），`FunImgARB/` 已生成。
4. 说明：本次只改 Host 侧文本渲染与目录读取，不改 MATLAB/DPARSF；页面①的输出区会直接显示该文本，无需刷新页面（若页面插件未自动更新，刷新一次即可）。

### 已知限制

- 处理历史基于 DPARSF 目录命名约定（`FunImg*`/`FunRaw`）：BIDS 布局或不按 DPARSF 命名的目录不显示该段说明；自定义改名的目录无法识别。
- 仅从目录名**推断**处理链，不校验目录内文件内容；`FunImg` 是否已被「删除初始时间点」原地裁剪无法从名字判断，因此只给固定提醒。
- 阶段目录的受试者数按子目录计数；若目录被手工改名/混入其他文件，数量可能不代表真实受试者。
- 续跑提示只是建议：实际续跑仍需 `StartingDirName`/`TimePoints` 与中间数据匹配，并注意 `RemoveFirstTimePoints` 的原地覆盖行为。

## 22. 预设 5「空白/续跑」+ 已处理目录预检（含启动拦截）— 2026-11-07 10:19 前后

背景：§21 之后用户确认实现「预设 5 空白/续跑 + 已处理目录预检」，并采纳先做预检（更安全、改动小）、再加空白预设与测试的顺序。目标：避免再次出现在已处理数据上用完整预设重跑导致的**重复删点 / rp 文件重名「输入参数太多」**，并给「只补某一步」提供正确入口。

### 改动

| 文件 | 内容 |
| --- | --- |
| `matlab/MRI_Workbench/+mrw/CfgBuilder.m` | ① 预设列表新增第 5 个「空白（仅补步骤/续跑）」，`presetBlank()` 关闭全部处理与指标步骤；② 新增私有辅助 `detectStageDirs`（识别 `FunRaw`/`FunImg*` 阶段目录及 `S2_` 前缀、受试者数）、`describeStageDir`（后缀→中文步骤）、`funDirSuffix`、`suggestText`；③ `validate` 新增预检：`已处理目录`（列出 FunImg* 且说明各目录处理步骤）、`重复处理风险`（从 FunImg 重跑「删除初始时间点」= error；重跑其它步骤 = warn；起始目录已是处理目录仍开删除 = error）、`rp 文件冲突`（同一受试者多个 `rp*.txt` 且会重跑头动校正 = error，否则 warn）、`Scrubbing 依赖`（缺 FD 文件 = error）、`可执行步骤`（空白配置 = warn）、`续跑模式`（从阶段目录继续 = ok 并列出步骤）。 |
| `index.mjs` | `PRESETS` 增加第 5 个；`mri_workbench_prepare` 预设上限 4→5 并更新工具描述；`opPrepare` 的状态保存 `ok/errors/warnings`；`ensurePrepareState` 插件重启后从 `prep/*/cli-result.json` 恢复预检结果；`opStart` 新增 fail-safe：**预检有 error 或没有任何启用步骤时拒绝启动**并返回原因；`renderPrepare` 对空白配置显示「将执行 0 步」；`mri_workbench_start` 描述同步。 |
| `client.js` | 预设下拉加入第 5 个「空白（仅补步骤/续跑）」zh/en 文案。 |
| `matlab/MRI_Workbench/tests/test_processed_dir_checks.m`（新增） | 23 项断言：预设列表/空白预设、已处理目录 error/warn、rp 冲突 error/warn、续跑模式 ok、缺 FD error、空白配置 warn、干净目录不误报。 |
| `tests/node/param_dialog_render_test.mjs` | 新增预设下拉含 5 项且第 5 项为「空白/续跑」的渲染检查。 |
| `README.md`（仓库根 + `matlab/MRI_Workbench/README.md`）、`matlab/MRI_Workbench/docs/使用手册.md` | 使用步骤、命令示例、新增「运行前预检」章节、预设表与续跑说明。 |

### 验证（真实执行）

1. **MATLAB 预检/预设测试**：`matlab -batch "... addpath(pwd); addpath(fullfile(pwd,'tests')); test_processed_dir_checks"` → **全部通过**（23 项 PASS，exit 0）。
2. Node 回归：`param_dialog_test` 9/9、`param_dialog_render_test` 9/9（新增预设检查）、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3、`scan_history_test` 6/6、`results_test` 14/14、`results_card_test` 13/13；`node --check client.js/index.mjs` exit 0。
3. **运行中 Host 重载 + 真实数据实测**（用户目录 `D:\Data\MyStudy`，已有 FunImg/FunImgA/FunImgAR/FunImgARB）：
   - `mri_workbench_prepare({preset:4})` → `发现 1 个错误、0 项提醒`，错误为：`工作目录已有处理阶段目录（FunImg、FunImgA、FunImgAR、FunImgARB），但当前从 "FunImg" 重新执行「删除初始时间点」…`；
   - 紧接着 `mri_workbench_start()` → 返回 `Error: 运行前检查未通过，已阻止启动：…`（未启动任何 MATLAB 进程，正是 §18/今早事故的防线）；
   - `mri_workbench_prepare({preset:5})`（完全空白）→ `检查通过，但有 1 项提醒`，输出显示「将执行 0 步：未启用任何处理步骤（空白/续跑预设，请先勾选要补做的步骤）」与提醒「没有启用任何步骤」；`mri_workbench_start()` → `Error: 当前配置没有启用任何步骤（空白/续跑预设需要先勾选要补做的步骤），已阻止启动。`；
   - `mri_workbench_prepare({preset:5, overrides: StartingDirName=FunImgAR, IsScrubbing=1, Scrubbing.*, ParallelWorkersNumber=4})` → `检查通过（9 项）`，`将执行 1 步：Scrubbing`，起始目录 `FunImgAR`。
4. `mri_workbench_env` 预设列表显示 5 项；页面预设下拉由 `dsh-client-hmr` 热重载后可见第 5 项（无浏览器控制，结构由渲染测试覆盖）。

### 已知限制

- 预检基于**目录名/文件个数**推断，不解析 NIfTI 时间点：续跑时 `TimePoints` 与实际阶段目录帧数是否一致仍需用户确认（可设 0 让引擎自动检测，或按上一轮值填写）。
- 启动拦截只在 prepare 阶段带有预检结果时生效；插件重启后从旧版本 prep 目录恢复的配置若没有 `cli-result.json`，不做启动拦截（但仍正常执行）。
- 空白预设不会自动设置 `StartingDirName`：需用户显式改为阶段目录（预检会给出建议目录）；只有 `FunImg` 一个起始目录时保持原值。
- `rp 文件冲突` 检测按受试者目录统计 `rp*.txt` 个数；多 session（`S2_` 前缀）场景的 rp 文件命名差异尚未单独区分，建议继续用目录命名约定。






## 23. ① 数据索引卡「浏览…」弹出系统文件夹选择框 — 2026-11-07 11:59 前后

背景：用户要求「给核磁工作台增加个功能：数据索引（自动搜索）的选择根目录可以弹出选择文件目录」。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | ① 卡数据根目录输入框右侧新增 **浏览…** 按钮（`data-action=browse-root`，带悬停说明）。点击后 `pickDirectoryFromHost(ctx)` 依次尝试：① 桌面版 preload 暴露的 `globalThis.__DSH_DIRECTORY_PICKER__.pick()`（Electron 原生「选择文件夹」对话框）；② 回退 `ctx.get('uiWorkspace').pickDirectory()`（普通 Web 场景的 Host 侧原生选择器，ui-workspace 客户端已封装 `ctx.remote.directoryPicker.pick`）。返回绝对路径时写入输入框（`setRoot`）；取消（resolve null）不改动输入框；选择器都不可用时提示「当前界面无法弹出系统目录选择框，请手动输入或粘贴路径」，报错时显示「打开目录选择框失败：…」。等待期间按钮显示「正在打开…」并禁用，完成后恢复。仅客户端改动，Host 无需重启；新增中英文文案 `data.browse*` 5 条，手动输入时清除选择器错误。 |
| `README.md` | 特性列表与使用步骤 1 提及「浏览…」；新增小节「数据根目录：手动输入或「浏览…」选择」（桌面版原生对话框 / 普通 Web 回退 Host 选择器 / 取消不改输入 / 不自动扫描）。 |
| `tests/node/browse_dir_test.mjs`（新增） | 9 项渲染级自测：按钮渲染与文案/title/data-action；点击不执行 `/mri` 命令；桌面桥返回路径写入输入框；取消不改输入；等待期间「正在打开…」+禁用；无桥回退 `uiWorkspace.pickDirectory()`；桥报错也回退；无选择器提示；都报错时提示原因；zh/en 文案 key 一一对应。 |
| 开发期 UI 自动化/截图脚本（新增；开发期临时产物，未随仓库发布） | 运行中 Harness 的 UI 自动化/截图验证脚本（Windows UI Automation；选择文件夹对话框为同进程 `#32770` 原生窗口）。 |

### 验证（真实执行）

1. `node --check client.js` → exit 0；`node tests/node/browse_dir_test.mjs` → **9/9 PASS**。
2. 回归：`param_dialog_test` 9/9、`param_dialog_render_test` 9/9、`param_dialog_dep_test` 6/6、`worker_select_test` 3/3、`scan_history_test` 6/6、`results_test` 14/14、`results_card_test` 13/13，全部通过。
3. **运行中 Harness 热重载 + 真机 UI 实测**（桌面版，用户当前会话窗口，未重启 Host）：
   - 修改 `client.js` 后 `dsh-client-hmr`（Host 侧每 500ms stat 轮询入口产物）自动替换了运行中的插件；截图中「MRI 工作台」页 ① 卡已出现 **浏览…** 按钮（无需刷新页面）；
   - 用 Windows UI Automation 切到「MRI 工作台」标签页并调用「浏览…」→ 弹出系统原生 **「选择文件夹」** 对话框（title=`选择文件夹`，class=`#32770`，尺寸 960×540）；
   - 点对话框「选择文件夹」选中当前目录（下载）→ 对话框关闭，页面「数据根目录」输入框 UIA 读回值 = `C:\Users\user\Downloads`（原生选择器返回的绝对路径已写入输入框）；
   - 截图确认按钮等待期显示「正在打开…」；清理：清空输入框（UIA 读回空值）、ESC 确认无遗留对话框、切回「对话」标签页恢复用户原视图。
   - 说明：截图与 UIA 脚本仅用于本次验证（开发期临时产物，未随仓库发布）。

### 已知限制

- 原生对话框不接受「初始目录」参数（DSH 原生目录桥与 `uiWorkspace.pickDirectory()` 均无入参），打开时由系统/Electron 决定起始位置；需要从指定位置开始时可手动输入路径。
- 「浏览…」只选目录、不自动扫描；选好后仍需点「开始扫描」。
- 普通 Web（浏览器与 Host 不同机）场景下回退的是 Host 侧原生选择器（在 Host 机器屏幕上弹出），依赖 Host 组合 `dsh-host-directory-picker-auto`；若组合只提供浏览后端则显示「打开目录选择框失败」，仍可手动输入。
- UI 自动化验证使用 Windows UI Automation + 截图脚本（非浏览器 DevTools）；不同 DPI/窗口位置下按钮坐标由 UIA 实时读取，脚本已按元素矩形定位。

## 24. 扫描根目录=已处理阶段目录（如 FunImgARB）时 TR/时间点/层数/数据类型显示「未知」 — 2026-11-07 12:20 前后

背景：用户扫描 `D:\Data\MyStudy\FunImgARB` 时执行输出为：
`DPARSF 标准目录（FunRaw/AnatRaw）（1 名受试者）`、`TR=未知 / 时间点=未知 / 层数=未知 / 数据类型=未知`。

原因：`mrw.ScanEngine.analyzeDPARSF` 把“扫描根目录本身”也当成 DPARSF 目录树的一部分。根目录名为 `FunImgARB`（匹配 `^FunImg[A-Za-z0-9]*$`）但它的父目录才是工作目录，于是被误判成“subjectFirst 布局里的嵌套功能像目录”：以父目录名当受试者（1 名），受试者目录=阶段目录本身（其下没有 NIfTI 文件直接位于该层），因此读不到头信息 → 全「未知」；实际该阶段目录下有 6 个受试者子目录，每个有 1 个 4D NIfTI（TR=2s、230 时间点、33 层，头部 pixdim[4]=2.0000014）。

### 改动

| 文件 | 内容 |
| --- | --- |
| `matlab/MRI_Workbench/+mrw/ScanEngine.m` | ① `analyzeDPARSF` 新增“根目录本身就是 DPARSF 功能像目录”分支（`Variant='rootModal'`）：当扫描根目录名匹配 `FunRaw`/`FunImg*`、其子目录（排除模态目录与空目录）含图像文件、且存在上级目录时，`WorkingDir`=上级、`StartingDirName`=根目录名（去 `S2_` 前缀）；② 新增 `planRootModal`：受试者=根目录下含图像文件的子目录，FunDirs=各受试者子目录，结构像在上级目录的 `T1Raw/T1Img/AnatRaw/<SubjID>` 中查找，并输出“续跑模式”warning（session 专属目录额外警告）；③ `scan` 对 rootModal 覆写 `LayoutName`（`DPARSF 已处理阶段目录（<name>，续跑模式）` / `DPARSF 功能像原始目录（FunRaw）`）；④ `countAnatInDir` 在目录不在扫描树内时按需 `scanOneDir` 现读，保证 AnatFileCount/AnatType 正确；⑤ `assembleSubject` 对自动检测 TR 四舍五入到 4 位小数，消除 NIfTI pixdim float32 噪声（2.0000014305114746 → 2）；⑥ 类头注释补充识别规则。 |
| `matlab/MRI_Workbench/tests/test_scan_engine.m` | 新增 `ScanEngine-RootModal` section（36 项断言）：FunImgARB 阶段目录的布局/名称/受试者数/WorkingDir=上级/StartingDirName/TR-TP-层数/结构像来自 T1Img/状态与 warning；FunRaw 根目录（假 DICOM）；防护：根目录名恰为 `FunImg` 但实为工作目录时仍按 dirFirst；回归：扫描上级工作目录行为不变。 |
| `matlab/MRI_Workbench/docs/CONTRACT.md`、`matlab/MRI_Workbench/docs/使用手册.md`、`README.md` | 记录“根目录=功能像/阶段目录”的识别规则、LayoutName、续跑模式与使用说明。 |

### 验证（真实执行）

1. `matlab -batch "cd('<仓库>\matlab\MRI_Workbench'); addpath('tests'); test_scan_engine"` → **PASS 254/254**（含新增 RootModal 36 项）；`test_processed_dir_checks` → 全部通过（exit 0）。
2. 真实目录重新扫描（同一 MATLAB 代码路径，无需重启 Host/插件）：
   - `mri_workbench_scan(root='D:\Data\MyStudy\FunImgARB')` →
     `数据扫描完成：DPARSF 已处理阶段目录（FunImgARB，续跑模式）（6 名受试者）`；
     `工作目录 D:\...\MyStudy`；`起始目录名 FunImgARB；session 数 1`；
     `TR=2 秒，时间点=230，层数=33`；`数据类型 NIfTI`；6 名受试者均 `NIfTI，时间点=230，TR=2，状态=ok`；
     提醒“扫描根目录本身就是已处理的 DPARSF 功能像阶段目录 … WorkingDir 自动取其上级目录 …”；并给出 FunImg→FunImgA→FunImgAR→FunImgARB 处理历史与续跑提示。
   - 回归扫描上级工作目录 `...\MyStudy` → 仍为 `DPARSF 标准目录（FunRaw/AnatRaw）（6 名受试者）`，TR=2/230/33，提示“检测到多个功能像起始目录…选择 FunImg”。
   - 续跑集成检查：重新扫描 FunImgARB 后 `mri_workbench_prepare({preset:5})` → `数据目录 ...\MyStudy；受试者 6 名；起始目录 FunImgARB；TR=2，时间点=230`，说明扫描结果可直接进入续跑配置（空白预设仍需再勾选要补的步骤）。
3. 说明：本次仅改 MATLAB 侧（`+mrw/ScanEngine.m`）与测试/文档，Host 插件与页面无需重启或刷新。

### 已知限制

- 根目录名为 session 专属目录（如 `S2_FunRaw`）时仍按单 session 给出（`FunctionalSessionNumber=1`），会额外提示“建议扫描完整工作目录”；多 session 续跑应以完整工作目录为准。
- 根目录是阶段目录时，结构像目录在扫描根目录之外（上级），扫描索引中的 `AnatFileCount/AnatType` 通过现读补齐，但仍不把该目录纳入 `Stats.DirsScanned`。
- “根目录 = 功能像目录”规则只针对功能像/阶段目录；直接扫描 `T1Raw/T1Img` 等结构像目录仍走通用 NIfTI 识别。
- TR 四舍五入到 4 位小数（0.1 ms），对 DPARSF 配置使用无影响。

## 25. 执行输出中的错误行改为红色字体 — 2026-11-07 13:58 前后

背景：用户要求「执行输出中错误改成红色字体」。页面底部「③ 执行输出」卡片此前把整段命令返回文本放在一个 `<pre>` 里用默认色显示，`生成配置并校验` 失败时的「错误：」小节及其列表项（如“起始目录名 FunImgARB 已是处理后的数据…”）也是黑色；只有命令抛异常时单独显示的 error 段落是红色。

### 改动

| 文件 | 内容 |
| --- | --- |
| `client.js` | 新增 `styles.outputError`（主题错误色 `var(--dsw-alias-state-error-primary)`）与纯函数 `classifyOutputLine` / `renderOutputText`：执行输出按行拆成 `<span>` 渲染，错误行套错误色；识别规则——`错误：`/`Error:` 小节标题及其后的列表项标红（遇到 `提醒：`/`警告：`/`Warnings` 小节恢复默认色），含「检查未通过 / 发现 N 个错误（N>0）/ 已阻止启动 / 取消失败 / 生成配置失败 / 扫描失败 / 运行失败 / 参数覆盖无效」等失败提示的整行标红；受试者行里的 `状态=error` 不误染。输出文本内容与复制内容不变。仅客户端改动，由 `dsh-client-hmr` 自动热重载，Host/页面无需重启。 |
| `tests/node/output_error_color_test.mjs`（新增） | 7 项渲染级自测：空输出占位；中文「错误：」小节及列表项红色、`提醒：`后恢复默认色、文本逐字不变；失败摘要行（“发现 2 个错误”/“检查未通过”标红，“发现 0 个错误”不标红）；英文 Error/Warning 小节；`状态=error` 不误染；`取消失败：`单行提示红色；正常输出无红色行。 |
| `README.md` | 新增「执行输出（错误红色显示）」小节说明着色规则。 |

### 验证（真实执行）

1. `node --check client.js` → exit 0；`node tests/node/output_error_color_test.mjs` → **7/7 PASS**。
2. Node 回归全套通过：`browse_dir_test` 9/9、`worker_select_test` 3/3、`param_dialog_test` 9/9、`param_dialog_render_test` 9/9、`param_dialog_dep_test` 6/6、`scan_history_test` 6/6、`results_test` 14/14、`results_card_test` 13/13。
3. **运行中 Harness 真机验证**（桌面版，未重启 Host）：
   - 修改 `client.js` 后 `dsh-client-hmr` 自动替换插件；UIA 检查执行输出区域已变成逐行 `Text` 节点（不再是一整块文本），说明新渲染已生效；
   - 用 UIA 切到「MRI 工作台」→ 点「生成配置并校验」（预设 4，对已处理目录产生预检错误）→ 执行输出出现「错误：」小节；
   - 截图 + 像素级取色：失败摘要行“预处理配置：发现 1 个错误、0 项提醒”、`错误：` 行及错误列表项文字均为 **RGB(236,19,19)**（主题错误色），普通输出行（如“预设：快速质控…”“- 受试者：6 名…”）为 **RGB(15,17,21)**（默认文字色）；截图与裁剪 `output-error-card.png`（开发期临时产物，未随仓库发布；附件中也保留了首轮 135928 版本）；
   - 验证后已重新执行 `mri_workbench_prepare({preset:5})` 恢复「空白/续跑」配置，并把界面切回「对话」标签页。
4. 说明：本次仅改客户端渲染，MATLAB/DPARSF 与 Host 命令逻辑未动。

### 已知限制

- 着色按「错误小节标题 + 失败关键词」启发式识别：不属于错误小节、也不含上述失败关键词的行保持默认色（例如普通信息行里顺带出现的“错误”二字）；`提醒：` 小节内即使出现“失败”字样也不标红。
- 行内 `状态=error` 等英文关键词不单独触发整行红色（避免把扫描输出中的受试者行整体染红）；如需按受试者状态标红可后续扩展。
- 输出仍以纯文本进入会话命令记录；着色只影响页面「执行输出」卡片的显示。

## 26. T1 裁剪兼容模式：旧版 dcm2nii（可裁剪 NIfTI）/ 免裁剪直通 — 2026-11-07 14:50 前后

背景：用户报告 14:13 的 DPARSF 运行失败在 `DPARSFA_run.m:1641`：DPABI 的「结构像裁剪」步骤已改用 dcm2niix（只支持 DICOM 输入），而 `T1Img/` 里只有 6 个 `T1.nii`，`Converted 0 DICOMs` 导致没有生成 `c*/co*`；BET 本身成功（PATH 补丁生效），但走到 T1 配准/分割前的 `questdlg`「是否用未裁剪的 T1」时，无界面模式无法弹窗 → 报错退出。用户要求把「换用能处理 NIfTI 的旧版 dcm2nii 并验证」和「改用不需要裁剪的 T1 路径」两个功能选择加入工作台。

### 改动

| 文件 | 内容 |
| --- | --- |
| `matlab/MRI_Workbench/+mrw/T1Compat.m`（新增） | T1 裁剪兼容层。`normalizeMode/labelOf/planOf/oldDcm2niiExe/t1Needed/hasCroppedFile/t1Files/apply(Cfg,logFcn)`。`old_dcm2nii`：对每个受试者的 `T1Img/<ID>/`（已有 c* 则跳过；只允许一个 T1）调用 DPABI 自带旧版 `DPARSF/dcm2nii/dcm2nii.exe`（参数 `-g N -m N -n Y -r Y -v N -x Y`）对 NIfTI T1 重定向+裁剪，验证生成 c* 文件（若 dcm2nii 判断“无需裁剪”则把 T1 复制为 c* 直通）；`no_crop`：把未裁剪 T1 复制为 c* 直通文件；两种模式都设置 `IsNeedReorientCropT1Img=0`（关闭 DPARSF 的 dcm2niix 裁剪步骤）。支持 .nii/.nii.gz；`.img/.hdr` 给出明确错误；DICOM 转换模式自动跳过。 |
| `matlab/MRI_Workbench/+mrw/CfgSchema.m` | 新增 `T1CropCompat` 枚举（`auto` 默认 / `old_dcm2nii` / `no_crop`，分组「结构像处理」，中英文标签与选项；字段总数 97→98）。 |
| `matlab/MRI_Workbench/+mrw/CfgBuilder.m` | build 在 reconcile 后应用兼容模式（T1 链需要时关闭 `IsNeedReorientCropT1Img`，保留 `Cfg.T1CropCompat`）；validate 重写 T1 检查：auto + 裁剪开关 + 纯 NIfTI 时给出明确 error（dcm2niix 只支持 DICOM，提示改用兼容模式）；auto 无 co* 的 error 文案补充兼容模式；old_dcm2nii 校验旧版 exe、多个 T1 文件、说明待处理人数；no_crop 给 warn（c* 直通需人工 QC）；路径非 ASCII 提示补 dcm2nii。 |
| `matlab/MRI_Workbench/+mrw/headlessRunner.m` | 载入 Cfg 后、DPARSFA_run 之前调用 `mrw.T1Compat.apply` 并打印日志；传给 DPARSFA_run 前删除 `T1CropCompat` 工作台字段。 |
| `matlab/MRI_Workbench/+mrw/cli.m` | prepare 结果新增 `t1CropCompat / t1CropCompatLabel / t1CropPlan / t1CropIsAction`。 |
| `matlab/MRI_Workbench/resources/glossary.tsv`、`matlab/MRI_Workbench/docs/CONTRACT.md`、`matlab/MRI_Workbench/docs/使用手册.md`、`matlab/MRI_Workbench/README.md` | 新增 T1CropCompat 术语（143 条）、T1Compat API 契约、使用说明与故障排查、功能列表。 |
| `matlab/MRI_Workbench/tests/test_t1_compat.m`（新增） | 48 项断言：schema 字段/枚举/默认值；模式归一化；auto 不干预；old_dcm2nii 真实裁剪（合成 T1 → c*）；已有 c* 跳过；no_crop 字节一致直通；缺 T1/多 T1 中文错误；不需要 T1/DICOM 转换模式跳过；CfgBuilder build 三模式与 validate 三类提示；headlessRunner/cli 接线。 |
| `client.js` | ② 卡新增「T1 裁剪兼容模式」下拉（`id=mrw-t1crop`、`data-action=t1crop-select`，选项 自动/旧版 dcm2nii/免裁剪 + hint）；仿 worker 选择器读写 `T1CropCompat` 覆盖（保留其它覆盖、auto 移除、首屏回显）。 |
| `index.mjs` | renderPrepare 在「将执行 N 步」后追加 `- T1 裁剪兼容：<label>（<plan>）`；schema 缓存 version 2→3（让新字段进入参数弹窗）；prepare 工具描述与系统提示补充 T1CropCompat 用法。 |
| `tests/node/t1_crop_ui_test.mjs`（新增）、`tests/node/param_dialog_test.mjs` | 11 项渲染级选择器/输出测试；param_dialog 的 schema 数量断言 97→98。 |
| `README.md` | 「T1 裁剪兼容（可选）」说明段。 |

### 验证（真实执行）

1. **MATLAB 单元/回归**：`test_t1_compat` → **PASS 48/48**；`test_scan_engine` 254/254；`test_processed_dir_checks`、`test_core_lead` 全部通过。
2. **真实数据端到端**（临时副本：`FunImgARB/sub-S01_ses-baseline` + `T1Img/sub-S01_ses-baseline/T1.nii`；配置 `IsBet=1`、`IsNeedReorientCropT1Img=1`，复现原失败触发条件；`headlessRunner` → 官方 `DPARSFA_run`，1 名被试，步骤=头动校正→BET→EPI 模板标准化）：
   - **对照 auto 模式**：`mrw.CfgBuilder.validate` 直接报 error——`1 名受试者的 T1 是 NIfTI，但“结构像裁剪”步骤调用的是 dcm2niix（只支持 DICOM），不会生成 c*/co*，无界面运行会在 BET/分割处因无法弹确认框而失败；请把「T1 裁剪兼容模式」改为…`（提前拦截，不再跑 3 分钟后才失败）。
   - **old_dcm2nii 模式**：预检通过；运行前用旧版 dcm2nii 生成 `cT1.nii`（10,351,504 字节；原 `T1.nii` 24,641,888 字节，已重定向+裁剪）；日志含 `T1 裁剪兼容：使用旧版 dcm2nii…`、`已生成裁剪文件 cT1.nii`、`Bet finished`，不含 `No co* T1 image`；状态 **finished（0.8 分钟）**；`T1ImgBet/` 有 BET 输出。证据：开发期临时证据文件（`old_dcm2nii.run.log`、`.status.json`、`.cT1.nii`，未随仓库发布）。
   - **no_crop 模式**：预检仅 warn（`运行前会把 1 名受试者的未裁剪 T1 复制为 c* 直通文件…需人工 QC`）；运行生成与 `T1.nii` 字节数一致的 `cT1.nii`（24,641,888 字节）；BET/标准化正常；状态 **finished（0.8 分钟）**。证据：开发期临时证据文件（`no_crop.run.log` 等，未随仓库发布）。
3. **DSH 页面真机验证**（运行中 Host 用 `plugin_manager set_plugin include:dsh-mri-workbench` 重载，client.js 由 `dsh-client-hmr` 热重载；未重启 DSH）：
   - 页面 ② 卡出现「T1 裁剪兼容模式」下拉（UIA：`id=mrw-t1crop`，当前值 `旧版 dcm2nii（可裁剪 NIfTI）`，与已保存覆盖回显一致）；
   - 点「生成配置并校验」后执行输出出现 `- T1 裁剪兼容：旧版 dcm2nii（运行前对 NIfTI T1 重定向+裁剪生成 c*/co*，不依赖 dcm2niix）` 行（UIA 文本捕获）；截图（开发期临时产物，未随仓库发布）同时显示 ② 卡「T1 裁剪兼容模式」下拉（选中“旧版 dcm2nii（可裁剪 NIfTI）”）与执行输出中的 T1 兼容行（该次为预设 4 复现已处理目录预检错误，错误行红色），`t1ui-top-143948.png` 为 ② 卡近景；
   - 随后用 Agent 工具 `mri_workbench_prepare({preset:5})` 恢复「空白/续跑」配置，输出含最终文案：`- T1 裁剪兼容：旧版 dcm2nii（运行前对 NIfTI T1 重定向+裁剪生成 c*/co*，不依赖 dcm2niix）`；参数覆盖保留 `T1CropCompat="old_dcm2nii"`（对用户当前 `MyStudy` 数据直接生效）。
4. **Node/UI 测试**：`node --check client.js/index.mjs` OK；`t1_crop_ui_test` 11/11，`worker_select` 3、`browse_dir` 9、`output_error_color` 7、`param_dialog*` 9+9+6、`scan_history` 6、`results` 14、`results_card` 13，全部 PASS。

### 已知限制

- `old_dcm2nii` 依赖 DPABI 自带的旧版 `dcm2nii.exe`（2016 版）；若安装中缺失会给出中文错误并建议改用「免裁剪」。
- 旧版 dcm2nii 判断“无需裁剪”（图像已紧贴脑边界）时，会把该 T1 复制为 `c*` 直通文件；此时等价于免裁剪，仍需 QC。
- `no_crop` 不重定向/去颈，只解决了「无界面确认框」问题；分割/标准化质量必须人工 QC，且每名受试者会多占一份 T1 大小的磁盘（c* 直通副本）。
- 兼容模式只对需要 T1 的流程（分割/配准/DARTEL/BET/应用重定向矩阵）生效；T1Raw DICOM 转换路线自动跳过。T1 为 Analyze（.img/.hdr）时旧 dcm2nii 裁剪暂不支持，会提示先转 .nii。
- `T1CropCompat` 是工作台字段，`headlessRunner` 在调用 `DPARSFA_run` 前删除；MATLAB 桌面 GUI 需重启 MATLAB 才能加载新增的 CfgSchema 字段（DSH 页面与工具已重载生效）。

## 2026-11-07：新建会话开始页入口

- `client.js` 在原生 `conversation.hero.options` 注册「打开 MRI 工作台」按钮，位于空白开始页工作区/模式选择行右侧；点击选择原生 `main` 面板，不必先发送消息。
- 主面板复用 `WorkbenchView`，通过 `useSessions` 读取当前 `mainView` 会话，以会话 ID 作为 React key；「返回开始」恢复原会话。没有会话时只显示提示和返回按钮，避免执行无会话命令。原有会话标签页保留。
- Node 检查：`node --check client.js` 通过；新增 `tests/node/start_entry_test.mjs` 7/7 通过；目录选择、输出颜色、worker 选择、参数弹窗渲染/依赖、结果卡与 T1 兼容 UI 回归共 58 项通过。
- 运行中 DSH 由 HMR 自动加载；实测「新会话」空白开始页出现入口，点击显示完整工作台及返回按钮，再点击「返回开始」恢复原空白开始页。验证后停留在开始页。没有启动 MATLAB 或执行预处理。
- DSH 原生 Hero 扩展依赖已绑定工作区的空白会话；若尚未绑定会话，先在开始页选择工作区。

## 27. 人工 QC 窗口 v2 的 DSH 读取端：`mri_workbench_qcstate` / `/mri qcstate` — 2026-11-07 21:3x 前后

背景：用户要求升级 MATLAB 人工 QC 窗口（三正交/原点/AC-PC/方位/多切片/FD 联动等），并希望「Agent 实时指导显影情况」。Lead 的设计契约（开发期文档，未随仓库发布）§7/§8 规定：MATLAB 窗口在操作后自动写 `<workDir>/QC/.qcviewer_state.json`（schema `mrw.qcviewer.state.v2`），DSH 侧新增读取工具/命令 + 页面 ④ 按钮，Agent 先 `matlab_snapshot` 截图再读状态做实时指导。

### 改动

| 文件 | 内容 |
| --- | --- |
| `index.mjs` | ① 新增纯函数 `readQcViewerState(workDir, options?)`：解析 `<workDir>/QC/.qcviewer_state.json`（兼容工作目录根下的同名文件），归一化受试者/模态/视图模式/活动方向/十字线（体素·世界·显示）/切片/显示层（模式、4×4 矩阵、AC/PC、距离/角度、手动平移旋转、翻转、消息）/窗宽 clim 色阶插值缩放十字线开关/叠加/评分/头动（FD 类型、阈值、逐帧值摘要前 60 帧、MeanFD、最大 FD、坏帧、坏帧率、最大平移旋转）/筛选排序/三模态进度；字段缺失、schema 不一致、字段改名（`headMotion`↔`FD`、顶层 `crosshairVoxel`↔嵌套 `crosshair`、`display.acpc` 嵌套、中文视图名/筛选排序标签、`window` 对象）均容错；`updatedAt` 缺失时退回文件修改时间；超过 30 分钟标记过期。② 新增 `renderQcState` 中文摘要渲染（工具、命令、页面共用）：缺文件/JSON 损坏/过期时给出「MATLAB 人工 QC 窗口未打开或尚未操作」+ 操作建议，不抛异常。③ 新增 Host 工具 `mri_workbench_qcstate`（参数 `workDir?`，不启动 MATLAB，描述里明确「配合 matlab_snapshot 做实时指导」）、命令 `/mri qcstate [工作目录]`、`/mri help` 与命令 input hint、系统提示新增「先截图再读状态」段落。 |
| `client.js` | 页面 ④ 人工 QC 卡 hint 更新（三正交/十字线坐标/原点/AC-PC/方位校准/多切片/FD 联动/排序筛选/复制状态给 Agent，并说明窗口写 `QC/.qcviewer_state.json`）；新增「读取 MATLAB QC 状态」按钮（`data-action=qc-state`，执行 `/mri qcstate`，复用页面执行输出区）；zh/en locale 文案同步。 |
| `tests/node/qc_state_test.mjs`（新增） | 20 项 Node 断言：工具/命令注册与描述；合法 JSON 全字段解析+中文摘要；工具/命令真实执行（mock ctx）；缺字段；损坏 JSON；过期（含可配置 `maxAgeMinutes`）；状态文件不存在；工作目录不存在；未传 workDir 推导；schema 不一致；字段偏差（嵌套 crosshair/FD/display.acpc/view.slices/中文视图名/面板实际 filter/sort 取值）；`updatedAt` 缺失回退文件时间；`updatedAt` 时区标记错误（`-00:00`）按本地时间解读；工具输出 JSON 无损。 |
| `matlab/MRI_Workbench/docs/人工QC使用说明.md` | 重写/新增 v2 章节：视图模式、十字线与坐标、原点/AC-PC、方位微调/色阶/插值、排序筛选、FD 曲线、快捷键、状态输出；新增「Agent 实时指导」章（怎么问、Agent 流程=先截图再读状态、工具/命令/状态 JSON 概要/过期规则）与限制。 |
| `matlab/MRI_Workbench/docs/人工QC验证记录.md` | 追加 v2 记录（功能清单、DSH 读取端改动、真实执行验证、限制）。 |
| `README.md` | 功能列表/工具列表/页面卡片说明/命令示例/人工 QC 章新增「窗口 v2 与 Agent 实时指导」小节、架构图与已知限制、离线自测入口更新。 |

### 验证（真实执行）

1. 语法与离线测试（仓库根目录）：
   ```
   node --check index.mjs   → exit 0
   node --check client.js   → exit 0
   node tests/node/qc_state_test.mjs              → 全部通过：20 项检查
   ```
   覆盖：合法 JSON 全字段（Sub01/三正交/十字线 [32,32,15]/AC-PC 18 mm/窗宽 [2,98]/FD 坏帧 1/4/评分进度）、缺字段显示「—」、损坏 JSON、过期 2 小时、文件不存在、工作目录不存在、schema v1 提醒、字段偏差容错（含面板实际 filter/sort 取值）、updatedAt 缺失回退文件修改时间、updatedAt 时区标记错误按本地时间解读、JSON 无损。
2. **运行中 DSH 真机验证**（未重启 DSH 进程）：
   - `plugin_manager set_plugin target=include:dsh-mri-workbench enabled=false` → `{application:"applied", warnings:[]}`；再 `enabled=true` → `{application:"applied", warnings:[]}`；
   - 重载后 Agent 工具表出现 `mri_workbench_qcstate`（工具描述含 `matlab_snapshot` 与 `qcviewer_state.json`）；
   - 用契约 §7 样例 JSON 写到临时工作目录 `%TEMP%\mri-qcstate-dsh\QC\.qcviewer_state.json`，真实调用工具（`workDir` 指向该目录）返回中文摘要：`受试者：Sub01（第 1/3 名） · 模态 T1 原始像`、`视图模式：三正交（活动方向：水平位（轴位））`、`十字线：体素 (32, 32, 15)；世界 (-0.50, 12.30, 8.40) mm`、`显示模式：AC-PC 配平；AC-PC 距离 18.00 mm；配平角度 0.00°`、`显示矩阵（4x4…）`、`显示设置：窗宽 2–98%…`、`模板轮廓叠加：叠加显示，透明度 0.55，标准化图 Fun`、`FD 类型 FD_Jenkinson；阈值 0.20 mm；MeanFD 0.080；坏帧 1/4（5.0%）`、`评分：当前 3 分`、`评分进度：T1 1/3；Fun 0/3；Norm 0/3`；
   - 不传 `workDir` 时推导到最近 prepare 目录 `D:\Data\MyStudy`；该目录尚无状态文件，工具返回「MATLAB 人工 QC 窗口未打开或尚未操作：未找到 QC/.qcviewer_state.json…」+ 操作建议（说明未伪造状态）；
   - 工作目录不存在：工具返回 `ok=false` + 中文「工作目录不可用」，命令返回 success 文本提示（不抛未捕获异常）。
2.1 **真实 MATLAB 写盘链路**（panel-ui 的 QcPanel 已可解析后）：
   - 用 `matlab -batch` 执行 `base=qc_fixture('dsh_bridge_state2'); fig=uifigure(...); p=mrw.QcPanel(fig, struct('WorkingDir',base,'Modality','T1','Footer',true)); p.setViewMode('triple'); p.setSubject('Sub01'); p.setScore(4); p.exportState(<base>/QC/.qcviewer_state.json)` → 生成真实状态 JSON（schema/version/updatedAt/workDir/subjectID=Sub01/subjectCount=3/viewMode=triple/activeOrientation=axial/crosshairVoxel=[33,33,16]/display(native)/window=[2,98]/clim=[0.57,625.66]/overlay/score.current=4/headMotion.values 60 帧/meanFD=0.0595/maxFD=0.31/badFrames 2 帧/progress/filter=all/sort=id）；
   - 运行中 DSH 的 `mri_workbench_qcstate` 读取该真实文件 → 摘要显示 `受试者：Sub01（第 1/3 名） · 模态 T1 原始像`、`三正交`、`十字线：体素 (33, 33, 16)；世界 (32, 32, 15) mm`、`窗宽 2–98%`、`评分：当前 4 分`、`FD_Jenkinson 阈值 0.20 mm；MeanFD 0.060；最大 FD 0.310；坏帧 2/60（3.3%）；坏帧帧号 10、42` 等，README 所述链路端到端可用。
   - 真实链路发现 2 处 MATLAB 写盘与契约的偏差（读取端已容错，建议 panel-ui 复核）：① `updatedAt` 写成 `2026-11-07T21:46:43-00:00`（本地时间却标 UTC；`nowIsoLocal` 用两个 datetime 相减求时区偏移，二者时刻相同故得 0）→ DSH 按标记解读会得到「未来时间」，读取端已自动改为按本地时间解读并提醒；**该问题已由 panel-ui 修复**（`nowIsoLocal` 改用 `datetime(...,'Format','...XXX')`，真机验收实测 `2026-11-07T22:11:11+08:00`，见 §28）；② `crosshairVoxel` 与 `crosshairWorld/Display` 可能不同源（`buildStateJson` 用 `getCrosshairVoxel()` 与 `getViewInfo()` 分别取），实测出现体素 `[33,33,16]` 而世界 `[32,32,15]`，建议统一来源或先同步后再取。
3. 页面端：`client.js` 由 `dsh-client-hmr` 热重载；另做渲染级自测（fake React/ModuleLoader 加载真实 `client.js`）：④ 卡渲染出「读取 MATLAB QC 状态」按钮（`data-action=qc-state`），点击后执行 `/mri qcstate`；hint 含三正交/AC-PC/方位校准/多切片/FD/排序筛选/复制状态给 Agent；「刷新 QC 评分」按钮保留。浏览器视觉截图未做，刷新页面一次后即可看到。
4. **与实际 MATLAB 写盘实现交叉核对**（读取 `mrw.QcPanel.buildStateJson` 并跑真实导出，panel-ui 实现）：
   - 字段与契约 §7 一致（schema/version/updatedAt/workDir/modality/subjectID/viewMode/activeOrientation/crosshairVoxel+World+Display/display(mode,hasVolume,matrix,acVoxel,pcVoxel,acWorld,pcWorld,distanceMm,angleDeg,manualTranslationMm,manualRotationDeg,flips,message)/slices/window/clim/colormap/interp/zoom/crosshairVisible/overlay/score/headMotion/filter/sort/progress/message）；
   - 筛选/排序实际写盘取值为 `all|unscored|scored|low|meanfd` 与 `id|score_asc|score_desc|meanfd_asc|meanfd_desc`，读取端已兼容（含 `*_desc` 降序判定，单测覆盖）；
   - MATLAB `jsonencode` 把 NaN 写为 `null`、缺失向量写为 `[]`，`updatedAt` 为 `yyyy-mm-ddTHH:MM:SS±hh:00`；读取端均按预期处理（空值显示「—」、缺失时间退回文件修改时间、时区标记异常改按本地时间解读并提醒）；
   - 已报告给 Lead/panel-ui 的偏差（读取端已容错，不阻塞 DSH 使用）：① `nowIsoLocal` 曾把本地时间标成 `-00:00`（应写真实偏移如 `+08:00` 或 UTC+`Z`）——**panel-ui 已修复**，真机验收实测 `2026-11-07T22:11:11+08:00`（见 §28）；② `crosshairVoxel` 与 `crosshairWorld/Display` 不同源（体素取面板属性、世界/显示取 QcView），实测 `[33,33,16]` vs `[32,32,15]`；③ `display.matrix = reshape(dm(1:16),4,4).'` 为 `QcView.getInfo().DisplayMatrix` 的转置（native 单位阵时不可见），若契约期望原矩阵需 panel-ui 复核。
5. 说明：本次只改 DSH 插件 Host/Client 与文档、离线自测；MATLAB `+mrw/*.m`、DPABI/SPM、用户数据与评分 TSV 均未改动。MATLAB 侧窗口 v2（QcView/QcPanel/QcAlignDialog/状态写盘）由 view-engine/panel-ui 实现并测试，DSH 读取端按契约 §7 schema 兼容读取。

### 已知限制

- 状态文件由 MATLAB 窗口写出：窗口未打开/未操作时不存在；窗口关闭或长时间不操作后读到的是旧状态（>30 分钟明确提示过期），此时工具只给操作建议，不给具体坐标。
- 读取端做了容错（缺失字段→「—」、schema 不一致→提醒），但不会替 MATLAB 端补字段；若实际实现与契约 §7 有偏差，摘要会提示 schema/版本不一致，需要 MATLAB 侧补齐后才能完整显示。
- 状态 JSON 的逐帧 FD `values` 可能很长：工具只返回前 60 帧 + 总帧数摘要，曲线判读以 MATLAB 窗口或 `mri_workbench_results` 为准。
- 工具/按钮只读取与展示：不启动 MATLAB、不写评分、不替代人工 QC 结论；截图（`matlab_snapshot`）与状态 JSON 之间可能有秒级时间差，以状态文件 `updatedAt` 为准。
- MATLAB 桌面 GUI 已打开时需重启 MATLAB 才能加载新增/修改的 `+mrw` 类；DSH 侧 Host 用 plugin_manager 重载、Client 用 HMR + 刷新页面生效。
- MATLAB 端 `nowIsoLocal` 曾把本地时间误标为 `-00:00`；panel-ui 已修复为真实本地偏移（真机验收实测 `+08:00`，见 §28），DSH 读取端仍保留「异常时区标记按本地时间解读」的容错。
- 真实 MATLAB 写盘链路已在 QcPanel 可解析后跑通（见验证第 2.1 项）；若 panel-ui 后续改动 `buildStateJson` 字段名，DSH 读取端会显示「—」并提示 schema/字段差异，需要重新核对（任务 4 独立验收覆盖）。

## 28. Lead 真机验收：MATLAB 桌面人工 QC v2 窗口 + DSH `mri_workbench_qcstate` 实时指导链路 — 2026-11-07 22:11 前后

背景：§27 完成后，Lead 按契约 §9 做真实桌面/真实数据验收——在 MATLAB 桌面打开 v2 人工 QC 窗口，用 `matlab_snapshot` 截图、UIA 实际点击「方位校准…」做 AC-PC 配平，同时用运行中的 DSH 工具读取同一状态 JSON，验证「Agent 先截图再读状态」链路。本节记录的是 **Lead 提供的真机验收证据**（DSH 读取端与其一致）。

### 环境

- MATLAB R2026a 桌面版（独立进程；验证后已关闭），DPABI/SPM12 已配置；
- 真实 DPARSF 数据：`D:\Data\MyStudy`（6 名受试者；`T1Img/`、`RealignParameter/`、`QC/RawT1ImgQC.tsv` 均存在）；
- 打开方式：`addpath('<仓库>\matlab\MRI_Workbench'); mrw.QcViewer.open(workDir,'T1')` → `p.setViewMode('triple')`。

### 实测内容（真实截图 / 状态 / 工具输出）

1. **`matlab_snapshot` 真实窗口**：三正交同屏（水平位 81/162、冠状位 99/196、矢状位 82/163）、十字线联动、右侧 1–5 评分区与 MeanFD `0.0321`、底部 FD 曲线（阈值红虚线 / 坏帧红点 / MeanFD(TSV) 0.0321 / 序列均值 0.0321 / 最大 FD 0.0794）、坐标读数行均可见；截图 `.dsh-matlab-feedback/run-2026-11-07T14-11-51-092Z-0u9tuo/w1-QC...png`。
2. **UIA 实际点击「方位校准…」**打开 `mrw.QcAlignDialog`（截图 `.dsh-matlab-feedback/run-2026-11-07T14-15-44-393Z-rf015f/w1-AC-PC.png`）；在真实数据上依次「设为 AC → 切受试者 → 设为 PC → 应用 AC-PC 配平」成功：状态 JSON `display.mode=acpc`、`distanceMm=3.00`、`angleDeg=114.24`、4×4 显示矩阵非单位阵；三正交图像可见倾斜重采样，窗口状态栏显示「AC-PC 配平完成：距离 3.00 mm · 角度 114.2°（仅影响显示）」。
3. **运行中 DSH 工具 `mri_workbench_qcstate(workDir)`** 读取同一真实状态文件：受试者 `sub-S04_ses-endpoint`、三正交、AC-PC `3.00 mm` / `114.24°`、FD_Jenkinson 坏帧 `10/230`（帧号 31,32,33,113,114,115,135,190,191,192）、评分进度 6/6 等与窗口显示一致 → 证明「Agent 先 `matlab_snapshot` 再 `qcstate`」的实时指导链路真实可用。
4. **状态 JSON 实际字段（本次真机）**：`updatedAt = 2026-11-07T22:11:11+08:00`（本地时区偏移，DSH 解析后新鲜度正常）；`headMotion.meanFD = 0.0321`（`RealignParameter/HeadMotion.tsv` 第 21 列，与窗口右列一致）、`seriesMeanFD = 0.0321`、`meanFDSource = HeadMotion.tsv#meanFD_Jenkinson`、`maxFD = 0.0794`、`badFrames` 10 帧、`badRatio ≈ 4.3%`（逐帧序列口径）；`display.mode = acpc`、`distanceMm = 3.00`、`angleDeg = 114.24`。
5. **关闭清理**：关闭查看器后 `QC/.qcviewer_state.json` 自动删除（`mrw.QcViewer` 关闭清理），真实数据 `QC/` 目录恢复原样（仅 `RawT1ImgQC.tsv`/`RawFunImgQC.tsv`）；显示层 AC-PC 未写回任何 NIfTI。验证后已关闭该 MATLAB 桌面进程，DSH 窗口恢复。

### 已知限制

- 本次 AC/PC 为任意拾取点（用于验证几何/交互链路，**不是解剖学 AC/PC**）；真实 AC-PC 配平仍需用户按前、后连合的解剖位置拾取，拾取点不准会得到无解剖意义的角度。
- 截图位于 DSH 会话运行目录 `.dsh-matlab-feedback/`（未复制进插件仓库）；如需长期归档可复制到 `matlab/MRI_Workbench/tests/` 或开发期截图目录。
- 真机验收由 Lead 执行，本节记录其确认的证据；DSH 读取端输出与窗口显示一致（受试者/三正交/AC-PC/坏帧/评分进度）。

## 29. Lead 收尾补丁：单视图十字线绘制 — 2026-11-07 22:2x 前后

背景：verifier 独立验收观察②——单视图模式下勾选「显示十字线」/按 `X` 不绘制十字线（原实现只在三正交/多切片绘制），与提示/文档不一致。Lead 做了收尾补丁并实测通过（本文档仅记录，不含代码改动）。

### 改动（`matlab/MRI_Workbench/+mrw/QcPanel.m`，Lead 实现）

| 项 | 内容 |
| --- | --- |
| `SingleCross` 属性 | 保存单视图的两条十字线对象（开启时 2 条线；关闭时删除并清空） |
| `drawSingleCrosshair` / `clearSingleCrosshair` | 单视图十字线绘制/清除；`drawImage` 末尾调用；`setCrosshairVisible` 在单视图下补一次重绘 |
| 效果 | 单视图勾选「显示十字线」/按 `X` 也绘制并隐藏十字线，与三正交/多切片**共用同一体素位置**（同源）；三正交/多切片行为不变 |

### 验证（Lead 实测，真实输出文件）

1. `test_qc_ui_v2_accept` → **67/67 PASS**，含新增断言「单视图开启十字线后有 2 条线 / 关闭后线条消失」；证据 `matlab/MRI_Workbench/tests/out_qc_ui_v2_accept2.txt`（末行 `=== 验收结果：0 项失败 / 共 67 项断言 ===`）。
2. `test_qc_panel` → **253 项检查 0 失败**；证据 `matlab/MRI_Workbench/tests/out_qc_panel_v2.txt`。
3. `test_all_lead` → **10/10 通过**（最后再跑一次确认，以最终 `matlab/MRI_Workbench/tests/out_all.txt` 为准）。

### 限制

- 单视图十字线是显示层叠加，不改变像素、评分与状态 JSON 的含义；与三正交/多切片同源（同一 1-based 体素位置）。
- 单视图只显示当前切片；十字线所在切片通过切片滑条/↑↓ 调整。

## 2026-11-07：QC v3 本地兼容复核

本轮仅修改MATLAB QC及文档；没有安装/卸载插件、修改DSH profile、重载或重启宿主。状态schema保留 `mrw.qcviewer.state.v2`，没有新增读取端必需字段，应用数据日志独立保存。

指定本机Node实际执行 `node --check index.mjs` 成功；`node tests/node/qc_state_test.mjs` 为20项全部通过（日志为开发期临时产物，未随仓库发布）。无需DSH专用工具；截图使用Windows computer-use，状态可由Node读JSON。

MATLAB回归、真实数据副本、性能与方向证据见开发期执行报告（未随仓库发布）。部分物理键鼠/最终确认界面截图被用户窗口接管中断，未声称全真机验收完成。
