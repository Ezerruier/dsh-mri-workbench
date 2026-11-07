# 人工 QC 验证记录（Lead 集成）

时间：2026-11-06 01:00–01:15
环境：MATLAB R2026a + DPABI V10.0_260625 + SPM12

> 脱敏说明：本地绝对路径与受试者编号已按公开仓库要求脱敏替换，技术结论、数字与命令未改动。

## 1. 组件测试

| 测试 | 结果 |
|---|---|
| `tests/test_qc_model.m`（QcModel + fixture） | **PASS 177/177**（1.3 s）：discover/subjects、`.nii/.nii.gz/4D 平均`、makeSlice 三方向、edgeSliceFor 非空轮廓（真实 DPABI Edge 模板，max 0.921，743/546/200 轮廓点）、DPARSF 兼容 TSV 往返/合并、阈值与通过名单、HeadMotion 21 列解析 |
| `tests/test_qc_panel.m`（QcPanel UI） | **PASS 101/101**：缩放 2.5×（`getZoomFactor=2.500000`，XLim 64→25.6，中心不变，1× 复原）、滚轮交互后仍准确、切片/方向/窗宽、T1⇄Fun⇄Norm、wFun/wT1/wGM、模板轮廓开关与透明度、评分保存/自动下一人/进度、筛选、导出名单、空数据中文提示；29 个交互控件 100% Tooltip；构造 1.95 s |
| `tests/test_qc_integration_lead.m`（Lead 集成） | **SUCCESS**：`mrw.QcViewer.open(base,'T1')` 创建窗口 + 内嵌 QcPanel；`setZoomFactor(2.5)` → `getZoomFactor=2.50`；评分 4 分 + 中文评语写入后 `QcModel.loadScores` 读回一致；`WorkbenchApp` 第⑥页可打开、同步工作目录、评分与截图正常 |

## 2. 截图（tests/ 下）

- `out_qc_panel_default.png`：T1 原始像默认视图（1.00×、窗宽 2/98、评分区、MeanFD、进度）。
- `out_qc_panel_zoom.png`：**8.00×** 放大视图，像素级放大可见。
- `out_qc_panel_norm.png`：标准化检查（wFun + DPABI MNI 边缘轮廓、透明度/类型切换）。
- `out_qc_integration/viewer_zoom.png`：独立 QcViewer 2.5×。
- `out_qc_integration/page6_qc.png`：主工作台第⑥页嵌入效果（1500×920）。

## 3. 与 DPARSF 的对应关系（已核源码）

| 工作台人工 QC | DPARSF/DPABI |
|---|---|
| T1 原始像 `T1Img/<subj>/c*`，1–5 分+评语 | `y_spm_image` 评分（`DPARSFA_run.m:1287-1318`），`QC/RawT1ImgQC.tsv` |
| 功能平均像 `RealignParameter/<subj>/mean*` | `DPARSFA_run.m:1392-1432`，`QC/RawFunImgQC.tsv` |
| 标准化 wFun/wT1/wGM + Edge 轮廓 | `y_QC_Normalization.m`，`QC/NormalizationQC.tsv` |
| 阈值（默认 3）/ MeanFD（第 21 列）/ 导出名单 | `ReorientThreQC.m`、`DPABI_QC_TOOL.m` |

## 4. 已知限制

- 标准化轮廓要求图像在 MNI 空间；非 MNI 时轮廓为空（不报错）。
- 模板缓存约 34 MB（首次加载）；超大 4D 数据切切片可能变慢（小数据 0.004 s/切）。
- `mrw.QcViewer` 桌面窗口在 -batch 下已验证创建与截图，真实桌面窗口弹出需人工确认。
- 键盘快捷键（↑↓ 切片、←→ 受试者）需图像区获得焦点。

---

## 5. v2（2026-11-07）：三正交 / 原点与 AC-PC / 方位校准 / 多切片 / FD 联动 / Agent 实时指导

时间：2026-11-07（与 DSH 页面 ④、MATLAB QC 窗口升级同批交付）
范围：`mrw.QcView`（新建）、`mrw.QcModel.loadFdSeries`、`mrw.QcPanel` v2、`mrw.QcAlignDialog`（新建）、
`mrw.QcViewer`、状态 JSON（`QC/.qcviewer_state.json`）与 DSH 读取端。

### 5.1 新增功能（实现与 MATLAB 侧测试）

| 功能 | 说明 |
|---|---|
| 三正交联动视图 | 单视图 / 三正交（轴/冠/矢）/ 多切片网格三种视图模式；三正交共享 3D 十字线，点击切换十字线，第四格为位置与校准信息 |
| 十字线与坐标读数 | 体素（1-based）/ 世界 mm / 显示 mm 三行实时读数；显示矩阵与显示模式摘要 |
| 原点校准与 AC-PC 配平 | 「方位校准…」对话框：以十字线设原点、拾取 AC/PC、应用 AC-PC 配平（显示层）、显示距离/角度/旋转平移 |
| 方位调整 | 6 自由度平移/旋转、左右/前后/上下翻转、色阶（灰阶/热色/jet）、插值（线性/最近邻）；「重置方位」 |
| 多切片网格 | 当前方向等间隔切片拼图，点击 tile 选层，十字线所在 tile 高亮 |
| FD 曲线与头动联动 | 底部 FD 曲线（类型/阈值可调、坏帧红点），MeanFD/最大 FD/坏帧数/最大平移旋转；与评分低分联动标红 |
| 排序筛选 | 受试者表按 全部/仅未评分/已评分/低分≤阈值/MeanFD 超阈值 筛选；按 ID/评分/MeanFD 排序 |
| 状态 JSON | 窗口操作后自动写 `<工作目录>/QC/.qcviewer_state.json`（schema v2）；工具条「复制状态给 Agent」复制 JSON |

> MATLAB 端测试（`test_qc_view.m` 新建、`test_qc_panel.m` 扩展、`test_qc_integration_lead.m`、回归 `test_qc_model.m`）
> 由 view-engine / panel-ui 实现者执行并报告；截图（单视图 / 三正交 / AC-PC / 多切片 / FD 低分联动）在 `matlab/MRI_Workbench/tests/` 下。
> 本记录的 5.2–5.4 为 **DSH 读取端（dsh-bridge）实测**，与上表状态 JSON 契约一一对应。

### 5.2 DSH 读取端（dsh-bridge）— 改动

| 文件 | 内容 |
|---|---|
| `index.mjs` | 新增 `readQcViewerState` / `renderQcState`（纯 Node 只读，不启动 MATLAB）；新增工具 `mri_workbench_qcstate`、命令 `/mri qcstate [工作目录]`、`/mri help` 与系统提示（先 `matlab_snapshot` 截图再读状态做实时指导）；缺文件/JSON 损坏/过期 >30 分钟中文提示，schema 不一致与字段改名容错 |
| `client.js` | 页面 ④ 卡 hint 更新（三正交/AC-PC/方位校准/多切片/FD 联动/排序筛选/复制状态给 Agent），新增「读取 MATLAB QC 状态」按钮（`data-action=qc-state`，执行 `/mri qcstate`），zh/en locale |
| `tests/node/qc_state_test.mjs`（新建） | 20 项 Node 断言：合法全字段、缺字段、损坏 JSON、过期、过期阈值、文件不存在、工作目录不存在、schema 不一致、字段偏差容错（嵌套 crosshair / FD / display.acpc / 中文视图名 / 面板实际 filter/sort 取值）、updatedAt 缺失回退文件时间、updatedAt 时区标记错误按本地时间解读、JSON 无损 |
| `README.md`、`docs/VERIFICATION.md` | 新增「人工 QC 窗口实时状态 / Agent 实时指导」说明与验证条目（§27） |
| `matlab/MRI_Workbench/docs/人工QC使用说明.md` | 重写/新增 v2 全部功能说明、Agent 实时指导用法（工具/命令/截图配合/典型对话）、限制 |

### 5.3 验证（真实执行）

1. 语法与离线测试：
   - `node --check index.mjs` → exit 0；`node --check client.js` → exit 0；
   - `node tests/node/qc_state_test.mjs` → **全部通过 20 项检查**（含合法 JSON 全字段、缺字段、损坏 JSON、过期、文件不存在、工作目录不存在、schema 不一致、字段偏差容错）。
2. 运行中 DSH（未重启进程）：
   - `plugin_manager set_plugin target=include:dsh-mri-workbench enabled=false → true`，两次均 `application=applied`、`warnings=[]`；
   - 重载后 Agent 工具表出现 `mri_workbench_qcstate`；
   - 用契约 §7 样例写出的真实 fixture（临时目录 `%TEMP%\mri-qcstate-dsh\QC\.qcviewer_state.json`）调用工具：返回中文摘要包含受试者 Sub01（第 1/3 名）· 模态 T1 原始像、三正交、十字线体素 `(32, 32, 15)`、世界 `(-0.50, 12.30, 8.40) mm`、AC-PC 距离 18.00 mm、显示矩阵 4×4、FD_Jenkinson 坏帧 1/4（5.0%）、评分 3 分与三模态进度；
   - 不传 `workDir` 时按最近 prepare 目录推导到用户数据目录 `D:\Data\MyStudy`，因该目录尚无状态文件，工具返回「MATLAB 人工 QC 窗口未打开或尚未操作」+ 操作建议（未崩溃、未伪造状态）；
   - 工作目录不存在时工具/命令均返回中文「工作目录不可用」提示。
2.1 真实 MATLAB 写盘 → DSH 读取链路（QcPanel 可解析后）：
   - `matlab -batch`：`base=qc_fixture('dsh_bridge_state2')` → `mrw.QcPanel(fig, struct('WorkingDir',base,'Modality','T1','Footer',true))` → `setViewMode('triple')`、`setSubject('Sub01')`、`setScore(4)` → `exportState(<base>/QC/.qcviewer_state.json)`；
   - 生成的 JSON 含 subjectID=Sub01/subjectCount=3/viewMode=triple/activeOrientation=axial/crosshairVoxel=[33,33,16]/display.mode=native/window=[2,98]/clim=[0.57,625.66]/overlay/score.current=4/headMotion 60 帧（meanFD=0.0595、maxFD=0.31、2 个坏帧）/progress/filter=all/sort=id；
   - 运行中 DSH 的 `mri_workbench_qcstate` 读取该真实文件 → 摘要正确显示受试者/三正交/十字线/窗宽/评分/FD（`MeanFD 0.060`、`最大 FD 0.310`、`坏帧 2/60（3.3%）`、坏帧帧号 10、42）等，端到端链路可用；
   - 同时发现 2 处 MATLAB 写盘偏差（DSH 已容错，建议 panel-ui 复核）：① `updatedAt` 写成 `2026-11-07T21:46:43-00:00`（本地时间误标 UTC，`nowIsoLocal` 用两次 datetime 相减求时区偏移恒为 0）→ DSH 自动按本地时间解读并提醒；**该问题已由 panel-ui 修复**（真机验收实测 `2026-11-07T22:11:11+08:00`，见 5.5）；② `crosshairVoxel` 与 `crosshairWorld/Display` 不同源（实测体素 `[33,33,16]`、世界 `[32,32,15]`）。
3. 页面端：`client.js` 由 `dsh-client-hmr` 热重载（渲染级自测：fake React/ModuleLoader 加载真实 `client.js` 后，④ 卡渲染出「读取 MATLAB QC 状态」按钮 `data-action=qc-state`，点击执行 `/mri qcstate`；hint 含三正交/AC-PC/方位校准/多切片/FD/排序筛选/复制状态给 Agent；刷新评分按钮保留）。浏览器视觉截图未做，按既有验证方式刷新页面一次即可看到。
4. 与 MATLAB 写盘实现交叉核对（`mrw.QcPanel.buildStateJson`，panel-ui 实现）：字段与契约 §7 一致；筛选/排序写盘值 `all|unscored|scored|low|meanfd`、`id|score_asc|score_desc|meanfd_asc|meanfd_desc` 已被读取端兼容；`updatedAt` 格式 `yyyy-mm-ddTHH:MM:SS±hh:00`、NaN→null、缺失向量→[] 均按预期处理（空值显示「—」；时区标记异常时按本地时间解读并提醒）。**已报告 panel-ui/Lead 的偏差**：① `updatedAt` 时区标记曾为 `-00:00`——**已修复**，真机验收实测 `2026-11-07T22:11:11+08:00`（见 5.5）；② `crosshairVoxel` 与 `crosshairWorld/Display` 不同源；③ `display.matrix` 为 `QcView.getInfo().DisplayMatrix` 的转置（`reshape(dm(1:16),4,4).'`，native 单位阵时不可见），若契约期望原矩阵需复核。
5. 未修改：DPABI/SPM、用户研究数据、MATLAB `+mrw` 源码（本记录 5.2 只涉及 DSH 插件与离线 Node 自测 `tests/node/`）。

### 5.4 已知限制（DSH 读取端）

- 状态 JSON 由 MATLAB 窗口写出；窗口未打开/未操作/关闭后，DSH 读到的是缺文件或旧状态（>30 分钟会明确提示过期），此时工具只给操作建议，不给具体坐标。
- DSH 读取端按契约 §7 做容错，但**不修改** MATLAB 端 schema：若实际实现字段改名，缺字段在摘要中显示「—」并给出 schema/版本提醒，需 MATLAB 侧补字段才能显示完整。
- 状态 JSON 中逐帧 FD `values` 可能很长：工具只返回前 60 帧摘要 + 总帧数，曲线判读以 MATLAB 窗口或 `mri_workbench_results` 为准。
- 工具输出与页面按钮只是**读取/显示**：不启动 MATLAB、不写评分、不替代人工 QC 结论。

### 5.5 Lead 真机验收（真实 MATLAB 桌面 + 真实 MyStudy 数据，2026-11-07 22:11 前后）

- 环境：MATLAB R2026a 桌面（独立进程，验证后已关闭）；真实数据 `D:\Data\MyStudy`（6 名受试者；`T1Img/`、`RealignParameter/`、`QC/RawT1ImgQC.tsv` 存在）。
- 打开方式：`addpath('<仓库>\matlab\MRI_Workbench'); mrw.QcViewer.open(workDir,'T1')` → `p.setViewMode('triple')`。
- `matlab_snapshot` 真实窗口：三正交同屏（水平 81/162、冠状 99/196、矢状 82/163）、十字线联动、右侧 1–5 评分与 MeanFD 0.0321、底部 FD 曲线（阈值红虚线/坏帧红点、MeanFD(TSV) 0.0321/序列均值 0.0321/最大 FD 0.0794）、坐标读数行；截图 `.dsh-matlab-feedback/run-2026-11-07T14-11-51-092Z-0u9tuo/w1-QC...png`。
- UIA 实际点击「方位校准…」打开对话框（截图 `.dsh-matlab-feedback/run-2026-11-07T14-15-44-393Z-rf015f/w1-AC-PC.png`）；真实数据上「设为 AC → 切受试者 → 设为 PC → 应用 AC-PC 配平」成功：状态 JSON `display.mode=acpc`、`distanceMm=3.00`、`angleDeg=114.24`、4×4 显示矩阵非单位阵；三正交图像可见倾斜重采样，状态栏显示「AC-PC 配平完成：距离 3.00 mm · 角度 114.2°（仅影响显示）」。
- 运行中 DSH 工具 `mri_workbench_qcstate(workDir)` 读取真实状态：受试者 `sub-S04_ses-endpoint`/三正交/AC-PC 3.00 mm/114.24°/FD_Jenkinson 坏帧 10/230（帧号 31,32,33,113,114,115,135,190,191,192）/评分进度 6/6 等与窗口一致 → 「先 matlab_snapshot 再 qcstate」链路真实可用。
- 状态 JSON 字段：`updatedAt=2026-11-07T22:11:11+08:00`（时区已修复）；`headMotion.meanFD=0.0321`（HeadMotion.tsv 第 21 列，与窗口右列一致）、`seriesMeanFD=0.0321`、`meanFDSource=HeadMotion.tsv#meanFD_Jenkinson`、`maxFD=0.0794`、`badFrames` 10 帧、`badRatio≈4.3%`（逐帧序列口径）。
- 关闭查看器后 `QC/.qcviewer_state.json` 自动删除（QcViewer 关闭清理），真实数据 `QC/` 目录恢复原样（仅评分 TSV）；显示层 AC-PC 未写回任何 NIfTI；验证后已关闭 MATLAB 桌面进程、DSH 窗口恢复。
- 限制：本次 AC/PC 为任意拾取点（演示几何/交互，不是解剖 AC/PC）；真实配平需用户按解剖位置拾取。
- 收尾补丁（单视图十字线，Lead 实测）：`QcPanel.m` 新增 `SingleCross` 属性与 `drawSingleCrosshair`/`clearSingleCrosshair`（`drawImage` 末尾调用、`setCrosshairVisible` 单视图下补重绘），单视图勾选「显示十字线」/按 `X` 也绘制，与三正交/多切片共用同一体素位置；`test_qc_ui_v2_accept` **67/67 PASS**（新增“单视图开启后有 2 条线/关闭后消失”）、`test_qc_panel` **253 项 0 失败**、`test_all_lead` **10/10**（以最终 `tests/out_all.txt` 为准）。


## 2026-11-07：人工 QC v3 本地执行

完整执行报告（`qc_v3_REPORT.md`）、阶段计划/进度（`qc_v3_plan.md`、`qc_v3_progress.md`）与最终全量复跑（真实鼠标坐标修复后）日志（`qc_v3_logs/final_all_after_real_click_fix.txt`）均为开发期临时产物，未随仓库发布。修改前基线10/10；方向/模型/面板/UI阶段分别388/179/253/67断言通过；新交互24项、新数据写出117项通过。

方向以同一真实cT1的本机SPM `spm_image` World Space为基准（程序自报SPM26），native斜切与非native使用同一方向。真实图163×196×162，合成64×64×30。真实单击复验最大误差0.1263源体素；窗口布局/方向截图位于开发期临时产物（`qc_v3_evidence/before`、`phase1`、`final`，未随仓库发布）。

性能独立30次切层：合成单图/三图中位6.780/18.969ms，真实11.778/29.176ms；drawnow另有85–89ms。不是60fps声明。真实副本header-only与resample均通过SPM/y_Read/niftiinfo；原目录12个T1整文件哈希/大小前后相同，输出日志可回退。细节和命令见报告。

严格区分验收层次：方向/紧凑信息/普通滚轮与修复后的单击有真实桌面证据。用户在拖拽验收时接管窗口，因此停止键鼠注入、停止命令轮询，保留该活动窗口；Ctrl+滚轮/连续滑条/拖拽/按钮最终物理验收，以及AC-PC/应用确认的最终桌面截图尚未齐全。其回调/服务自动化已通过，不能据此标记全部DoD完成。
