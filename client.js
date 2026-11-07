window.__ModuleLoader__.load({
  id: 'dsh-mri-workbench',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    const dictionaries = {
      zh: {
        'view.tab': 'MRI 工作台',
        'view.openWorkbench': '打开 MRI 工作台',
        'view.backToStart': '返回开始',
        'view.noSession': '请先在开始界面选择工作区，再打开工作台。',
        'view.title': 'MRI 静息态分析工作台',
        'view.subtitle': '在 Harness 内操作工作台；预处理由 MATLAB + DPABI/DPARSF 在后台独立进程执行。',
        'view.note': '长任务的实时日志会流式显示在会话顶部「后台任务」列表；也可以让 Agent 调用 mri_workbench_wait 汇报进度。',
        'view.openDesktop': '打开 MATLAB 桌面版',
        'view.openDesktopTitle': '启动 MATLAB 桌面版工作台（StartWorkbench）：完整中文参数悬停解释、术语库与可缩放人工 QC。',
        'data.title': '① 数据索引（自动搜索）',
        'data.hint': '支持 DPARSF（FunRaw/T1Raw）、BIDS、通用 NIfTI 与 DICOM 布局；自动识别受试者、TR、时间点与层数。',
        'data.root': '数据根目录',
        'data.rootPlaceholder': '例如 D:\\Data\\MyStudy',
        'data.browse': '浏览…',
        'data.browseTitle': '弹出系统文件夹选择框，选择数据根目录（也可直接输入或粘贴路径）',
        'data.browseBusy': '正在打开…',
        'data.browseUnavailable': '当前界面无法弹出系统目录选择框，请手动输入或粘贴路径。',
        'data.browseFailed': '打开目录选择框失败：',
        'data.depth': '扫描深度',
        'data.scan': '开始扫描',
        'prep.title': '② 预处理配置',
        'prep.preset': '预设',
        'prep.prepare': '生成配置并校验',
        'prep.hint': '使用上一步扫描结果生成 DPARSF Cfg，并执行运行前检查（目录结构 / TR / 层序 / T1 形态等）。下方的「参数覆盖」可手动调整任意参数。',
        'prep.overrides': '参数覆盖（JSON）',
        'prep.overridesHint': '手动调整 DPARSF 参数：填 CfgSchema 字段 JSON 数组（如 [{"key":"TR","value":2},{"key":"IsRemoveFirstTimePoints","value":false}]），先「应用覆盖」再「生成配置并校验」。点「查看可调参数」列出全部字段与默认值。',
        'prep.overridesPlaceholder': '[{"key":"TR","value":2}]',
        'prep.applyOverrides': '应用覆盖',
        'prep.clearOverrides': '清空覆盖',
        'prep.params': '查看可调参数',
        'prep.editParams': '参数设置…（弹窗）',
        'prep.advancedJson': '高级（JSON 覆盖）',
        'prep.status': '参数覆盖',
        'prep.workers': '并行 worker 数（被试并行）',
        'prep.workersHint': '实际并行池 = min(设定值, 物理核心数, 被试数)；0=串行。本机 24GB 内存建议：经典 DARTEL 全流程 4、仅功能像 6、快速质控 6–8；内存不足请调低或保持串行。其他数值可在「参数设置…」弹窗（勾选显示高级参数）里填。',
        'prep.workersUnset': '0 · 串行（默认）',
        'prep.t1Crop': 'T1 裁剪兼容模式',
        'prep.t1CropHint': '旧版 dcm2nii：用旧版 dcm2nii 对 NIfTI T1 重定向+裁剪，生成真正的 c*/co*（不依赖 dcm2niix）；免裁剪：不重定向/去颈，生成 c* 直通副本，分割质量需在 QC 里复核。',
        'prep.t1CropAuto': '自动（DPARSF 默认）',
        'prep.t1CropOldDcm2nii': '旧版 dcm2nii（可裁剪 NIfTI）',
        'prep.t1CropNoCrop': '免裁剪（用未裁剪 T1 继续）',
        'params.title': '预处理参数设置',
        'params.subtitle': 'DPARSF 风格参数面板 · 中英文对照 · 鼠标悬停查看解释',
        'params.search': '搜索参数（中文 / English / key）',
        'params.close': '关闭',
        'params.cancel': '取消',
        'params.apply': '应用覆盖',
        'params.reset': '恢复默认',
        'params.clearAll': '清空全部覆盖',
        'params.loading': '正在读取 CfgSchema…',
        'params.loadingHint': '首次需要启动一次 MATLAB（约 20 秒），之后使用缓存。',
        'params.error': '参数读取失败：',
        'params.changed': '已修改',
        'params.items': '项',
        'params.overrides': '当前覆盖',
        'params.showAdvanced': '显示高级参数',
        'params.groupTitle': '参数分组',
        'params.subjects': '名受试者（来自数据扫描，只读）',
        'params.tooltipHint': '悬停查看说明',
        'params.defaultLabel': '默认',
        'params.typeLabel': '类型',
        'params.depsLabel': '启用条件',
        'params.advancedBadge': '高级',
        'params.disabledByDeps': '由其他参数控制，当前不可用',
        'params.noMatch': '没有匹配的参数',
        'preset.1': '经典静息态（DARTEL 全流程）',
        'preset.2': '仅功能像（EPI 模板标准化，无结构像）',
        'preset.3': 'BIDS 数据一键预处理',
        'preset.4': '快速质控（仅转换+头动校正）',
        'preset.5': '空白（仅补步骤/续跑）',
        'run.title': '③ 运行与反馈',
        'run.start': '开始预处理',
        'run.status': '刷新状态',
        'run.cancel': '取消运行',
        'run.env': '检查环境',
        'run.open': '打开 MATLAB 桌面版',
        'run.hint': '运行前请先生成配置并通过校验。取消会终止后台 MATLAB 进程树，已生成的中间结果会保留。',
        'qc.title': '④ 人工 QC',
        'qc.hint': '汇总 DPARSF 兼容的人工 QC 评分（1–5 分，1=很差，5=很好）。MATLAB 人工 QC 窗口已升级：三正交联动、十字线与体素/世界/显示坐标、原点校准、AC-PC 配平、方位校准（平移/旋转/翻转）、多切片网格、FD 曲线与头动/评分联动、受试者排序筛选、色阶/插值；工具条「复制状态给 Agent」可把当前状态 JSON 复制到剪贴板。窗口会在操作后自动写出实时状态（QC/.qcviewer_state.json）：点「读取 MATLAB QC 状态」可看十字线、AC-PC、显示矩阵、窗宽、叠加、FD 与评分进度；也可在对话里让 Agent 先截图再读状态做实时指导。评分为空时点「打开 MATLAB 人工 QC」进入可缩放查看器评分。',
        'qc.refresh': '刷新 QC 评分',
        'qc.state': '读取 MATLAB QC 状态',
        'qc.stateTitle': '读取 MATLAB 人工 QC 窗口写出的实时状态（QC/.qcviewer_state.json），不启动 MATLAB；窗口未打开或尚未操作时会给出中文提示。Agent 侧可用 mri_workbench_qcstate 读取同一份状态，配合截图做实时指导。',
        'qc.open': '打开 MATLAB 人工 QC',
        'res.title': '⑤ 头动结果解读与可视化',
        'res.hint': '读取 DPARSF 的头动表格与逐帧 FD 曲线，做成表格和折线图，并解释每一列的含义与常见判读参考。只读文件，不启动 MATLAB。',
        'res.load': '读取并解读结果',
        'res.refresh': '刷新结果',
        'res.threshold': 'MeanFD 参考阈值',
        'res.loading': '正在读取头动结果…',
        'res.empty': '点「读取并解读结果」查看头动表格与逐帧 FD 曲线（需先完成头动校正）。',
        'res.unavailable': '未找到头动结果',
        'res.summaryTitle': '总体情况',
        'res.explainTitle': '这些数字怎么看？',
        'res.tableTitle': '每名受试者的头动指标',
        'res.chartTitle': '逐帧 FD 曲线',
        'res.chartHint': '可勾选/点击多名受试者叠加对比（默认全选）；红虚线 = 参考阈值；红点 = FD_Jenkinson 超过阈值的帧。切换指标不需要重新读取文件。',
        'res.metric': '曲线指标',
        'res.subjectsPick': '选择受试者（可多选）',
        'res.selectAll': '全选',
        'res.clearAll': '清空选择',
        'res.noneSelected': '请至少勾选一名受试者查看 FD 曲线。',
        'res.gradingTitle': '经验分级参考（启发式，不是诊断/入组标准）',
        'res.censorTitle': '坏帧 / Scrubbing（censor）',
        'res.censorFdType': 'FD 类型',
        'res.censorThreshold': '每帧阈值',
        'res.censorPrevious': '向前扩展帧数',
        'res.censorLater': '向后扩展帧数',
        'res.scrubMethod': 'Scrubbing 方式',
        'res.scrubSpike': 'spike · 每坏帧一个回归量（不缩短序列）',
        'res.spikeHint': 'Spike 回归 = 为每个坏帧单独建立一个回归量（DPABI：Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*），不删除/插值时间点，序列长度不变；从「协变量回归」步骤开始生效（经典 DARTEL / BIDS 预设已启用回归；仅功能像 / 快速质控预设未启用，可在「参数设置…」里把 IsCovremove 设为 1）。Spike 回归与 IsScrubbing 删点/插值互斥。',
        'res.spikeApplied': '已写入 Spike 回归参数覆盖（Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*，含 FD 类型/阈值/前后扩展）；需流程包含「协变量回归」步骤，下次「生成配置并校验」后生效。',
        'res.censorPreview': '坏帧预览（帧号 = 删初始点后 1-based，含前/后扩展）',
        'res.censorExport': '导出坏帧清单',
        'res.censorApply': '写入 scrubbing 参数覆盖',
        'res.censorBusy': '处理中…',
        'res.censorExported': '已导出：',
        'res.censorApplied': '已写入 Scrubbing 参数覆盖（IsScrubbing=1 + Scrubbing.*，含前后扩展帧数）；下次「生成配置并校验」后生效。',
        'res.censorHint': '坏帧 = 逐帧 FD 超过所选阈值的帧；向前/向后扩展帧数对应 DPABI 的 Scrubbing.PreviousPoints / LaterPoints（头动伪影常波及相邻帧，适当扩展能更彻底去伪影，但会减少有效帧）。「Scrubbing 方式」里的 cut/nearest/linear/spline/pchip 走 IsScrubbing（删点/插值），选 spike 则写入头动 scrubbing 回归量（Covremove.IsHeadMotionScrubbingRegressors，两种互斥）。导出文件位于工作目录 ScrubbingPreview/，可用于 DPARSF 的 IsScrubbing（剔除/插值）或作为 Covremove.IsHeadMotionScrubbingRegressors 回归量。',
        'res.censorEmpty': '当前阈值下没有坏帧。',
        'res.censorSampled': '注意：曲线点经过抽样，帧号（含扩展后的帧号）为近似值；导出清单由 Host 用完整序列计算。',
        'res.colCensorSubject': '受试者',
        'res.colCensorCount': '坏帧数',
        'res.colCensorPct': '坏帧比例',
        'res.colCensorFrames': '前 12 个帧号',
        'res.colSubject': '受试者',
        'res.colMeanFD': 'mean FD_Jenkinson (mm)',
        'res.colMeanFDPower': 'mean FD_Power (mm)',
        'res.colMaxTrans': '最大平移 (mm)',
        'res.colMaxRot': '最大旋转 (°)',
        'res.colBadFrames': 'FD_Power>0.2 帧数/占比',
        'res.colVerdict': '提示',
        'res.frames': '帧',
        'res.overThreshold': 'MeanFD ≥ 阈值',
        'res.none': '无',
        'res.moreFiles': '结果文件',
        'res.autoHint': '页面会自动读取最近一次配置的工作目录；如结果在别处，可用 /mri results <工作目录> 或让 Agent 指定 workDir。',
        'res.error': '头动结果读取失败：',
        'out.title': '执行输出',
        'out.empty': '点击上方按钮开始。结果会显示在这里，并作为命令记录进入会话。',
        'out.busy': '执行中…',
        'out.error': '错误：'
      },
      en: {
        'view.tab': 'MRI workbench',
        'view.openWorkbench': 'Open MRI workbench',
        'view.backToStart': 'Back to Start',
        'view.noSession': 'Choose a workspace on Start, then open the workbench.',
        'view.title': 'MRI resting-state workbench',
        'view.subtitle': 'Operate the workbench inside Harness; preprocessing runs in a background MATLAB + DPABI/DPARSF process.',
        'view.note': 'Live logs for long runs stream into the session background jobs list. You can also ask the Agent to call mri_workbench_wait for progress.',
        'view.openDesktop': 'Open MATLAB desktop app',
        'view.openDesktopTitle': 'Launch the MATLAB desktop workbench (StartWorkbench): full Chinese parameter tooltips, glossary and zoomable manual QC.',
        'data.title': '1. Data index (auto scan)',
        'data.hint': 'Supports DPARSF (FunRaw/T1Raw), BIDS, plain NIfTI and DICOM layouts; auto-detects subjects, TR, time points and slices.',
        'data.root': 'Data root',
        'data.rootPlaceholder': 'e.g. D:\\Data\\MyStudy',
        'data.browse': 'Browse…',
        'data.browseTitle': 'Open the system folder chooser to pick the data root (you can also type or paste a path)',
        'data.browseBusy': 'Opening…',
        'data.browseUnavailable': 'This surface cannot open a system folder chooser; please type or paste the path.',
        'data.browseFailed': 'Failed to open the folder chooser: ',
        'data.depth': 'Scan depth',
        'data.scan': 'Scan',
        'prep.title': '2. Preprocessing configuration',
        'prep.preset': 'Preset',
        'prep.prepare': 'Build config and validate',
        'prep.hint': 'Builds a DPARSF Cfg from the scan result and runs the preflight checks (layout, TR, slice order, T1 shape, ...). Use the override editor below to adjust any parameter manually.',
        'prep.overrides': 'Parameter overrides (JSON)',
        'prep.overridesHint': 'Adjust any DPARSF parameter: enter a JSON array of CfgSchema fields (e.g. [{"key":"TR","value":2},{"key":"IsRemoveFirstTimePoints","value":false}]), click "Apply overrides", then "Build config and validate". "Show parameters" lists every field with its default.',
        'prep.overridesPlaceholder': '[{"key":"TR","value":2}]',
        'prep.applyOverrides': 'Apply overrides',
        'prep.clearOverrides': 'Clear overrides',
        'prep.params': 'Show parameters',
        'prep.editParams': 'Parameter settings… (dialog)',
        'prep.advancedJson': 'Advanced (JSON overrides)',
        'prep.status': 'Overrides',
        'prep.workers': 'Parallel workers (subjects)',
        'prep.workersHint': 'Actual pool = min(setting, physical cores, subjects); 0 = serial. With 24GB RAM: 4 for the classic DARTEL pipeline, 6 for functional only, 6-8 for quick QC. Lower it or stay serial if memory is tight; other values can be entered in the parameter dialog (enable "Show advanced parameters").',
        'prep.workersUnset': '0 · serial (default)',
        'prep.t1Crop': 'T1 crop compatibility',
        'prep.t1CropHint': 'Legacy dcm2nii: reorient + crop the NIfTI T1 with the old dcm2nii, producing real c*/co* (no dcm2niix); No crop: copy the uncropped T1 as a c* pass-through, so re-check segmentation quality in QC.',
        'prep.t1CropAuto': 'Auto (DPARSF default)',
        'prep.t1CropOldDcm2nii': 'Legacy dcm2nii (crops NIfTI)',
        'prep.t1CropNoCrop': 'No crop (continue with uncropped T1)',
        'params.title': 'Preprocessing parameter settings',
        'params.subtitle': 'DPARSF-style parameter dialog · bilingual · hover for explanations',
        'params.search': 'Search parameters (Chinese / English / key)',
        'params.close': 'Close',
        'params.cancel': 'Cancel',
        'params.apply': 'Apply overrides',
        'params.reset': 'Reset to defaults',
        'params.clearAll': 'Clear all overrides',
        'params.loading': 'Loading CfgSchema…',
        'params.loadingHint': 'First load starts MATLAB once (about 20 s); later loads use the cache.',
        'params.error': 'Failed to load parameters: ',
        'params.changed': 'changed',
        'params.items': 'items',
        'params.overrides': 'current overrides',
        'params.showAdvanced': 'Show advanced parameters',
        'params.groupTitle': 'Groups',
        'params.subjects': 'subjects (from data scan; read-only)',
        'params.tooltipHint': 'Hover for details',
        'params.defaultLabel': 'default',
        'params.typeLabel': 'type',
        'params.depsLabel': 'enabled when',
        'params.advancedBadge': 'advanced',
        'params.disabledByDeps': 'Controlled by other parameters; currently unavailable',
        'params.noMatch': 'No matching parameter',
        'preset.1': 'Classic resting-state (DARTEL pipeline)',
        'preset.2': 'Functional only (EPI normalization, no T1)',
        'preset.3': 'BIDS one-click preprocessing',
        'preset.4': 'Quick QC (convert + realign only)',
        'preset.5': 'Blank (add one step / continuation)',
        'run.title': '3. Run and feedback',
        'run.start': 'Start preprocessing',
        'run.status': 'Refresh status',
        'run.cancel': 'Cancel run',
        'run.env': 'Check environment',
        'run.open': 'Open MATLAB desktop app',
        'run.hint': 'Build and validate the configuration first. Cancel kills the background MATLAB process tree; produced intermediates stay on disk.',
        'qc.title': '4. Manual QC',
        'qc.hint': 'Summarize DPARSF-compatible manual QC scores (1-5, 1=very poor, 5=very good). The MATLAB manual-QC window now has linked tri-planar views with crosshair voxel/world/display coordinates, origin calibration, AC-PC alignment, orientation adjustments (translation/rotation/flips), montage, FD curve linked to head motion/scoring, subject sorting/filtering and colormap/interpolation; the toolbar button "Copy state for agent" copies the current state JSON to the clipboard. After each operation the window writes a live state file (QC/.qcviewer_state.json): click "Read MATLAB QC state" to see crosshair, AC-PC, display matrix, window, overlay, FD and scoring progress; or ask the agent to take a screenshot then read the state for live guidance. When no scores exist yet, open the MATLAB manual QC viewer to score images.',
        'qc.refresh': 'Refresh QC scores',
        'qc.state': 'Read MATLAB QC state',
        'qc.stateTitle': 'Read the live state written by the MATLAB manual-QC window (QC/.qcviewer_state.json) without starting MATLAB; reports a friendly hint when the window is closed or untouched. The agent can read the same state through mri_workbench_qcstate and combine it with a screenshot for live guidance.',
        'qc.open': 'Open MATLAB manual QC',
        'res.title': '5. Head-motion results explained',
        'res.hint': 'Reads DPARSF head-motion tables and per-frame FD curves, renders a table plus line charts and explains every column. Read-only, no MATLAB startup.',
        'res.load': 'Load and explain results',
        'res.refresh': 'Refresh results',
        'res.threshold': 'MeanFD reference threshold',
        'res.loading': 'Loading head-motion results…',
        'res.empty': 'Click "Load and explain results" to see the head-motion table and FD curves (requires completed realignment).',
        'res.unavailable': 'No head-motion results found',
        'res.summaryTitle': 'Group summary',
        'res.explainTitle': 'How to read these numbers',
        'res.tableTitle': 'Per-subject head-motion metrics',
        'res.chartTitle': 'Per-frame FD curves',
        'res.chartHint': 'Check or click multiple subjects to overlay their curves (all selected by default); red dashed = threshold; red dots = FD_Jenkinson frames above threshold. Switching the metric does not reload files.',
        'res.metric': 'Metric',
        'res.subjectsPick': 'Subjects to overlay',
        'res.selectAll': 'Select all',
        'res.clearAll': 'Clear selection',
        'res.noneSelected': 'Select at least one subject to draw the FD curves.',
        'res.gradingTitle': 'Empirical grading reference (heuristic, not a diagnostic/inclusion rule)',
        'res.censorTitle': 'Bad frames / Scrubbing (censor)',
        'res.censorFdType': 'FD type',
        'res.censorThreshold': 'Per-frame threshold',
        'res.censorPrevious': 'Previous frames',
        'res.censorLater': 'Later frames',
        'res.scrubMethod': 'Scrubbing method',
        'res.scrubSpike': 'spike · one regressor per bad frame (keeps series length)',
        'res.spikeHint': 'Spike regression creates one regressor per bad frame (DPABI: Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*); time points are neither deleted nor interpolated, so the series length is unchanged. It takes effect from the "nuisance covariates regression" step (the classic DARTEL and BIDS presets enable regression; the functional-only and quick-QC presets do not — set IsCovremove to 1 in the parameter dialog if needed). Spike regression and IsScrubbing (cut/interpolate) are mutually exclusive.',
        'res.spikeApplied': 'Spike-regression overrides saved (Covremove.IsHeadMotionScrubbingRegressors=1 + HeadMotionScrubbingRegressors.*, including FD type/threshold/previous/later frames); the pipeline must include the "nuisance covariates regression" step; they take effect on the next "Build config and validate".',
        'res.censorPreview': 'Bad-frame preview (1-based frame index after removing initial volumes; includes previous/later expansion)',
        'res.censorExport': 'Export bad-frame list',
        'res.censorApply': 'Save scrubbing overrides',
        'res.censorBusy': 'Working…',
        'res.censorExported': 'Exported: ',
        'res.censorApplied': 'Scrubbing overrides saved (IsScrubbing=1 + Scrubbing.*, including previous/later frames); they take effect on the next "Build config and validate".',
        'res.censorHint': 'A bad frame = a frame whose FD exceeds the selected threshold; the previous/later frame counts map to DPABI Scrubbing.PreviousPoints / LaterPoints (motion artifacts often affect neighboring frames, so expansion removes more artifact but keeps fewer frames). "Scrubbing method" cut/nearest/linear/spline/pchip uses IsScrubbing (delete/interpolate); spike writes head-motion scrubbing regressors (Covremove.IsHeadMotionScrubbingRegressors) instead — the two are mutually exclusive. Exported files land under <workDir>/ScrubbingPreview/ and can feed DPARSF IsScrubbing (cut/interpolate) or Covremove.IsHeadMotionScrubbingRegressors.',
        'res.censorEmpty': 'No bad frames at this threshold.',
        'res.censorSampled': 'Note: curve points were downsampled, so frame numbers (including expanded ones) are approximate; the exported list is computed from the full series on the Host.',
        'res.colCensorSubject': 'Subject',
        'res.colCensorCount': 'Bad frames',
        'res.colCensorPct': 'Bad-frame share',
        'res.colCensorFrames': 'First 12 frame indices',
        'res.colSubject': 'Subject',
        'res.colMeanFD': 'mean FD_Jenkinson (mm)',
        'res.colMeanFDPower': 'mean FD_Power (mm)',
        'res.colMaxTrans': 'max translation (mm)',
        'res.colMaxRot': 'max rotation (°)',
        'res.colBadFrames': 'FD_Power>0.2 frames / share',
        'res.colVerdict': 'Hint',
        'res.frames': 'frames',
        'res.overThreshold': 'MeanFD ≥ threshold',
        'res.none': 'none',
        'res.moreFiles': 'Result files',
        'res.autoHint': 'The page auto-resolves the working directory of the latest prepared configuration; use /mri results <workDir> or ask the Agent with workDir if results live elsewhere.',
        'res.error': 'Failed to read head-motion results: ',
        'out.title': 'Output',
        'out.empty': 'Use a button above. Output appears here and is also recorded as a command in the session.',
        'out.busy': 'Running…',
        'out.error': 'Error: '
      }
    };

    function flatten(dict) {
      return Object.fromEntries(Object.entries(dict));
    }

    // 「浏览…」按钮的目录选择：优先用桌面版 preload 暴露的原生目录桥
    // （window.__DSH_DIRECTORY_PICKER__，Electron 文件夹对话框）；普通 Web 页面
    // 回退到 ui-workspace 客户端的 pickDirectory()（Host 侧原生选择器）。
    // 返回所选绝对路径；用户取消返回 null；当前界面没有可用选择器时抛出带
    // code = MRW_NO_DIRECTORY_PICKER 的错误（页面据此提示手动输入）。
    const MRW_NO_DIRECTORY_PICKER = 'MRW_NO_DIRECTORY_PICKER';

    async function pickDirectoryFromHost(ctx) {
      const desktop = typeof globalThis !== 'undefined' ? globalThis.__DSH_DIRECTORY_PICKER__ : undefined;
      const candidates = [];
      if (desktop && typeof desktop.pick === 'function') {
        candidates.push(() => desktop.pick());
      }
      const uiWorkspace = ctx && typeof ctx.get === 'function' ? ctx.get('uiWorkspace') : undefined;
      if (uiWorkspace && typeof uiWorkspace.pickDirectory === 'function') {
        candidates.push(() => uiWorkspace.pickDirectory());
      }
      if (!candidates.length) {
        const error = new Error('no directory picker is available in this surface');
        error.code = MRW_NO_DIRECTORY_PICKER;
        throw error;
      }
      let lastError;
      for (const pick of candidates) {
        try {
          return await pick();
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError;
    }

    const styles = {
      page: {
        height: '100%',
        boxSizing: 'border-box',
        overflow: 'auto',
        padding: '20px 24px 32px',
        background: 'var(--dsw-alias-bg-base)',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 13,
        lineHeight: 1.5
      },
      header: { marginBottom: 14 },
      headerTop: { display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' },
      title: { margin: 0, fontSize: 20, fontWeight: 600 },
      subtitle: { margin: '6px 0 0', color: 'var(--dsw-alias-label-secondary)' },
      note: {
        margin: '10px 0 0',
        padding: '8px 12px',
        border: '1px solid var(--dsw-alias-border-l1)',
        borderRadius: 8,
        background: 'var(--dsw-alias-bg-layer-2)',
        color: 'var(--dsw-alias-label-secondary)'
      },
      grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12, marginBottom: 12 },
      card: {
        border: '1px solid var(--dsw-alias-border-l1)',
        borderRadius: 10,
        background: 'var(--dsw-alias-bg-layer-1)',
        padding: 14
      },
      cardTitle: { margin: '0 0 6px', fontSize: 14, fontWeight: 600 },
      hint: { margin: '0 0 10px', color: 'var(--dsw-alias-label-secondary)', fontSize: 12 },
      row: { display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 8 },
      label: { color: 'var(--dsw-alias-label-secondary)', minWidth: 64 },
      input: {
        flex: '1 1 160px',
        minWidth: 140,
        padding: '6px 8px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-base)',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 13
      },
      select: {
        flex: '1 1 220px',
        minWidth: 180,
        padding: '6px 8px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-base)',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 13
      },
      button: {
        padding: '6px 12px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-layer-2)',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 13,
        cursor: 'pointer'
      },
      textarea: {
        width: '100%',
        boxSizing: 'border-box',
        minHeight: 64,
        padding: '6px 8px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-base)',
        color: 'var(--dsw-alias-label-primary)',
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: 12,
        resize: 'vertical'
      },
      primary: {
        padding: '6px 12px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-brand-primary)',
        background: 'var(--dsw-alias-brand-primary)',
        color: 'var(--dsw-alias-bg-base)',
        fontSize: 13,
        fontWeight: 600,
        cursor: 'pointer'
      },
      danger: {
        padding: '6px 12px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-layer-2)',
        color: 'var(--dsw-alias-state-error-primary)',
        fontSize: 13,
        cursor: 'pointer'
      },
      disabled: { opacity: 0.55, cursor: 'default' },
      outCard: { border: '1px solid var(--dsw-alias-border-l1)', borderRadius: 10, background: 'var(--dsw-alias-bg-layer-1)', padding: 14 },
      resultsCard: { border: '1px solid var(--dsw-alias-border-l1)', borderRadius: 10, background: 'var(--dsw-alias-bg-layer-1)', padding: 14, marginBottom: 12 },
      resultSummary: { margin: '6px 0 10px', paddingLeft: 18, fontSize: 12, lineHeight: 1.7, color: 'var(--dsw-alias-label-primary)' },
      resultTable: { width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 8 },
      resultTh: { textAlign: 'left', padding: '6px 8px', borderBottom: '1px solid var(--dsw-alias-border-l1)', color: 'var(--dsw-alias-label-secondary)', fontWeight: 600, whiteSpace: 'nowrap' },
      resultTd: { padding: '6px 8px', borderBottom: '1px solid var(--dsw-alias-border-l1)', verticalAlign: 'top' },
      resultRow: { cursor: 'pointer' },
      resultRowActive: { background: 'var(--dsw-alias-bg-layer-2)' },
      chartBox: { marginTop: 6, padding: 8, borderRadius: 8, border: '1px solid var(--dsw-alias-border-l1)', background: 'var(--dsw-alias-bg-base)' },
      chartSvg: { width: '100%', height: 'auto', display: 'block' },
      pill: { display: 'inline-block', padding: '1px 8px', borderRadius: 10, fontSize: 11, border: '1px solid currentColor', whiteSpace: 'nowrap' },
      small: { fontSize: 11, color: 'var(--dsw-alias-label-secondary)' },
      pre: {
        margin: 0,
        maxHeight: 320,
        overflow: 'auto',
        whiteSpace: 'pre-wrap',
        overflowWrap: 'anywhere',
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: 12,
        color: 'var(--dsw-alias-label-primary)'
      },
      error: { margin: '8px 0 0', color: 'var(--dsw-alias-state-error-primary)' },
      outputError: { color: 'var(--dsw-alias-state-error-primary)' },
      busy: { margin: '8px 0 0', color: 'var(--dsw-alias-state-warn-primary)' },
      // ---- 参数设置弹窗（DPARSF 风格） ----
      overlay: {
        position: 'fixed',
        inset: 0,
        background: 'rgba(0, 0, 0, 0.45)',
        zIndex: 1000,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 20
      },
      dialog: {
        width: 'min(1120px, 96vw)',
        height: 'min(760px, 90vh)',
        display: 'flex',
        flexDirection: 'column',
        borderRadius: 12,
        border: '1px solid var(--dsw-alias-border-l1)',
        background: 'var(--dsw-alias-bg-base)',
        color: 'var(--dsw-alias-label-primary)',
        boxShadow: '0 18px 60px rgba(0,0,0,0.35)',
        overflow: 'hidden'
      },
      dialogHeader: {
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'space-between',
        gap: 12,
        padding: '14px 18px',
        borderBottom: '1px solid var(--dsw-alias-border-l1)',
        background: 'var(--dsw-alias-bg-layer-1)'
      },
      dialogTitle: { margin: 0, fontSize: 16, fontWeight: 600 },
      dialogSub: { margin: '4px 0 0', fontSize: 12, color: 'var(--dsw-alias-label-secondary)' },
      dialogBody: { flex: '1 1 auto', display: 'flex', minHeight: 0 },
      groupNav: {
        width: 190,
        flex: '0 0 190px',
        borderRight: '1px solid var(--dsw-alias-border-l1)',
        background: 'var(--dsw-alias-bg-layer-1)',
        padding: '10px 8px',
        overflow: 'auto',
        boxSizing: 'border-box'
      },
      groupBtn: {
        display: 'block',
        width: '100%',
        textAlign: 'left',
        padding: '7px 8px',
        marginBottom: 4,
        borderRadius: 6,
        border: '1px solid transparent',
        background: 'transparent',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 12,
        cursor: 'pointer'
      },
      groupBtnActive: {
        display: 'block',
        width: '100%',
        textAlign: 'left',
        padding: '7px 8px',
        marginBottom: 4,
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'var(--dsw-alias-bg-layer-2)',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: 12,
        fontWeight: 600,
        cursor: 'pointer'
      },
      formPane: { flex: '1 1 auto', minWidth: 0, display: 'flex', flexDirection: 'column' },
      formToolbar: {
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '10px 14px',
        borderBottom: '1px solid var(--dsw-alias-border-l1)'
      },
      formScroll: { flex: '1 1 auto', overflow: 'auto', padding: '6px 14px 14px' },
      fieldRow: {
        display: 'grid',
        gridTemplateColumns: 'minmax(200px, 1fr) minmax(180px, 300px)',
        gap: 12,
        alignItems: 'start',
        padding: '8px 0',
        borderBottom: '1px dashed var(--dsw-alias-border-l1)'
      },
      fieldLabelZh: { fontWeight: 600, fontSize: 13 },
      fieldLabelEn: { color: 'var(--dsw-alias-label-secondary)', fontSize: 11 },
      fieldHint: { color: 'var(--dsw-alias-label-secondary)', fontSize: 11, marginTop: 2 },
      fieldControl: { display: 'flex', flexDirection: 'column', gap: 2 },
      badge: {
        display: 'inline-block',
        padding: '0 5px',
        marginLeft: 6,
        borderRadius: 4,
        border: '1px solid var(--dsw-alias-border-l2)',
        fontSize: 10,
        color: 'var(--dsw-alias-label-secondary)',
        fontWeight: 400
      },
      dialogFooter: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 10,
        padding: '12px 18px',
        borderTop: '1px solid var(--dsw-alias-border-l1)',
        background: 'var(--dsw-alias-bg-layer-1)'
      },
      footerLeft: { color: 'var(--dsw-alias-label-secondary)', fontSize: 12 },
      footerRight: { display: 'flex', gap: 8 },
      iconBtn: {
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'transparent',
        color: 'var(--dsw-alias-label-primary)',
        borderRadius: 6,
        width: 28,
        height: 28,
        cursor: 'pointer',
        fontSize: 16,
        lineHeight: '20px'
      }
    };

    // 执行输出按行着色：错误行用错误色（红色），其余行沿用主题默认色；输出文本本身不改动。
    //   - “错误：/Error:”小节标题及其后的列表项 → 红色（直到遇到“提醒：/警告：/Warnings”等小节）；
    //   - 含“检查未通过/已阻止启动/取消失败/…失败/参数覆盖无效”等失败提示的行 → 红色；
    //   - “状态=error”这类行内英文不触发（避免把整行受试者提示误染红）。
    const OUTPUT_ERROR_HEAD = /^\s*(?:[-·•*]\s+)?(?:错误|Error)\s*(?:[:：]|$)/i;
    const OUTPUT_OTHER_SECTION = /^\s*(?:提醒|警告|Warnings?|WARN)\s*(?:[（(]|[:：]|$)/i;
    const OUTPUT_BULLET = /^\s*[-·•*]\s+/;
    const OUTPUT_FAILURE_LINE = /(?:检查未通过|已阻止启动|取消失败|生成配置失败|扫描失败|运行失败|参数覆盖无效|发现\s*[1-9]\d*\s*个错误)/;

    function classifyOutputLine(line, inErrorBlock) {
      if (OUTPUT_OTHER_SECTION.test(line)) return { error: false, inErrorBlock: false };
      if (OUTPUT_ERROR_HEAD.test(line)) return { error: true, inErrorBlock: true };
      if (OUTPUT_BULLET.test(line)) return { error: inErrorBlock, inErrorBlock };
      if (line.trim() === '') return { error: false, inErrorBlock };
      return { error: OUTPUT_FAILURE_LINE.test(line), inErrorBlock: false };
    }

    function renderOutputText(text) {
      const lines = String(text ?? '').split(/\r?\n/);
      const nodes = [];
      let inErrorBlock = false;
      for (let i = 0; i < lines.length; i += 1) {
        const verdict = classifyOutputLine(lines[i], inErrorBlock);
        inErrorBlock = verdict.inErrorBlock;
        nodes.push(h('span', {
          key: `out-line-${i}`,
          style: verdict.error ? styles.outputError : null
        }, i === lines.length - 1 ? lines[i] : `${lines[i]}\n`));
      }
      return nodes;
    }

    const GROUP_EN = {
      '基础设置': 'Basic',
      '时间层与头动': 'Slice timing & motion',
      '结构像处理': 'Structural',
      '标准化与平滑': 'Normalize & Smooth',
      '回归与滤波': 'Regression & filter',
      '指标计算': 'Metrics',
      '高级与运行': 'Advanced & runtime'
    };

    const TYPE_LABEL = {
      bool: '布尔 / bool',
      enum: '枚举 / enum',
      int: '整数 / int',
      double: '小数 / double',
      vector: '数值向量 / vector',
      text: '文本 / text',
      dir: '目录 / dir',
      file: '文件 / file',
      maskfile: '掩膜文件 / mask file',
      roi: 'ROI',
      subjects: '受试者 / subjects'
    };

    function condsOf(dep) {
      if (!dep) return [];
      if (Array.isArray(dep)) return dep;
      if (Array.isArray(dep.Conds)) return dep.Conds;
      if (dep.Conds && typeof dep.Conds === 'object') return [dep.Conds];
      if (dep.Key) return [dep];
      return [];
    }

    function valueKey(v) {
      try {
        return JSON.stringify(v);
      } catch {
        return String(v);
      }
    }

    function sameValue(a, b) {
      return valueKey(a) === valueKey(b);
    }

    function formatValue(v) {
      if (v === null || v === undefined) return '—';
      if (Array.isArray(v)) return `[${v.join(', ')}]`;
      if (typeof v === 'object') return valueKey(v);
      if (typeof v === 'string') return v;
      return String(v);
    }

    // CfgSchema 的依赖值来自 MATLAB（数值 1/0），而开关控件写回的是 JS 布尔值 true/false。
    // 比较前先归一化，否则「勾选父开关后子字段仍置灰」——因为 JSON.stringify(true) !== JSON.stringify(1)。
    function normalizeCondValue(v) {
      if (v === true) return 1;
      if (v === false) return 0;
      if (typeof v === 'string') {
        const s = v.trim().toLowerCase();
        if (s === 'true') return 1;
        if (s === 'false') return 0;
      }
      return v;
    }

    function parseVector(text) {
      const s = String(text ?? '').trim();
      if (!s) return null;
      try {
        const v = JSON.parse(s);
        if (Array.isArray(v)) return v;
        if (typeof v === 'number') return [v];
      } catch {
        /* fall through */
      }
      const parts = s.replace(/[\[\]]/g, ' ').split(/[\s,;]+/).filter(Boolean);
      if (!parts.length) return null;
      const nums = parts.map((p) => Number(p));
      if (nums.some((n) => Number.isNaN(n))) return null;
      return nums;
    }

    function condText(c) {
      return `${c.Key} ${c.Op || '='} ${formatValue(c.Value)}`;
    }

    function condMet(draft, c) {
      const cur = normalizeCondValue(draft[c.Key]);
      const ref = normalizeCondValue(c.Value);
      const op = String(c.Op ?? '=');
      if (op === '=' || op === '==') return sameValue(cur, ref);
      if (op === '!=' || op === '<>') return !sameValue(cur, ref);
      const a = Number(cur);
      const b = Number(ref);
      if (Number.isNaN(a) || Number.isNaN(b)) return false;
      if (op === '>') return a > b;
      if (op === '<') return a < b;
      if (op === '>=') return a >= b;
      if (op === '<=') return a <= b;
      return true;
    }

    function groupLabel(group) {
      const en = GROUP_EN[group];
      return en ? `${group} / ${en}` : group;
    }

    // ------------------------------------------------------------------
    // DPARSF 风格参数设置弹窗（中英文对照 + 悬停解释 + 依赖联动）
    // ------------------------------------------------------------------
    function ParameterDialog({ t, schema, applyBusy, onClose, onApply }) {
      const entries = Array.isArray(schema.entries) ? schema.entries : [];
      const groups = Array.isArray(schema.groups) && schema.groups.length
        ? schema.groups
        : [...new Set(entries.map((e) => e.group))];
      const defaults = React.useMemo(() => {
        const d = {};
        for (const e of entries) d[e.key] = e.default;
        return d;
      }, [schema]);
      const baseline = React.useMemo(() => {
        const b = Object.assign({}, defaults);
        for (const o of schema.overrides || []) b[o.key] = o.value;
        return b;
      }, [schema, defaults]);
      const [draft, setDraft] = React.useState(baseline);
      const [activeGroup, setActiveGroup] = React.useState(groups[0] || '');
      const [filter, setFilter] = React.useState('');
      const [showAdvanced, setShowAdvanced] = React.useState(false);

      React.useEffect(() => {
        const onKey = (ev) => {
          if (ev.key === 'Escape') onClose();
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
      }, [onClose]);

      const dirtyKeys = entries.filter((e) => !sameValue(draft[e.key], baseline[e.key])).map((e) => e.key);
      const overridesCount = (schema.overrides || []).length;
      const setVal = (key, value) => setDraft((prev) => Object.assign({}, prev, { [key]: value }));
      const depsMet = (e) => condsOf(e.dependsOn).every((c) => condMet(draft, c));

      const controlFor = (e, disabled) => {
        const v = draft[e.key];
        const common = { style: Object.assign({}, styles.input, { flex: '1 1 auto', width: '100%' }), disabled };
        if (e.type === 'subjects') {
          return h('input', {
            style: common.style,
            readOnly: true,
            disabled: true,
            value: `${Array.isArray(v) ? v.length : 0} ${t('params.subjects')}`
          });
        }
        if (e.type === 'bool') {
          return h('label', { style: { display: 'inline-flex', alignItems: 'center', gap: 8, fontSize: 12 } },
            h('input', { type: 'checkbox', checked: !!v, disabled, onChange: (ev) => setVal(e.key, ev.target.checked ? 1 : 0) }),
            h('span', null, v ? '开启 / On' : '关闭 / Off'));
        }
        if (e.type === 'enum') {
          const options = Array.isArray(e.options) ? e.options.slice() : [];
          if (!options.some((o) => sameValue(o.value, v))) options.unshift({ label: formatValue(v), value: v });
          return h('select', {
            style: Object.assign({}, styles.select, { flex: '1 1 auto', width: '100%' }),
            value: valueKey(v),
            disabled,
            onChange: (ev) => {
              const opt = options.find((o) => valueKey(o.value) === ev.target.value);
              setVal(e.key, opt ? opt.value : v);
            }
          }, options.map((o) => h('option', { key: valueKey(o.value), value: valueKey(o.value) }, `${o.label}（${formatValue(o.value)}）`)));
        }
        if (e.type === 'int' || e.type === 'double') {
          return h('input', {
            style: common.style,
            type: 'number',
            step: e.type === 'int' ? 1 : 'any',
            value: Number.isFinite(Number(v)) ? String(v) : '',
            disabled,
            onChange: (ev) => {
              const raw = ev.target.value;
              if (raw === '') return setVal(e.key, 0);
              const n = Number(raw);
              setVal(e.key, Number.isFinite(n) ? (e.type === 'int' ? Math.round(n) : n) : raw);
            }
          });
        }
        if (e.type === 'vector') {
          return h('input', {
            style: common.style,
            type: 'text',
            value: Array.isArray(v) ? `[${v.join(', ')}]` : String(v ?? ''),
            disabled,
            placeholder: '例如 [4, 4, 4] 或 4 4 4',
            onChange: (ev) => {
              const parsed = parseVector(ev.target.value);
              setVal(e.key, parsed || ev.target.value);
            }
          });
        }
        return h('input', {
          style: common.style,
          type: 'text',
          value: typeof v === 'string' ? v : valueKey(v),
          disabled,
          onChange: (ev) => setVal(e.key, ev.target.value)
        });
      };

      const renderField = (e) => {
        const disabled = e.type === 'subjects' || !depsMet(e);
        const deps = condsOf(e.dependsOn).map(condText);
        const tip = [
          `${e.label} / ${e.en}`,
          e.tip ? `说明：${e.tip}` : '',
          `${t('params.typeLabel')}：${TYPE_LABEL[e.type] || e.type}；${t('params.defaultLabel')}：${formatValue(e.default)}`,
          deps.length ? `${t('params.depsLabel')}：${deps.join(' 且 ')}` : '',
          e.advanced ? t('params.advancedBadge') : '',
          disabled && e.type !== 'subjects' ? t('params.disabledByDeps') : ''
        ].filter(Boolean).join('\n');
        return h('div', { key: e.key, style: Object.assign({}, styles.fieldRow, { opacity: disabled ? 0.6 : 1 }) },
          h('div', { title: tip, style: { cursor: 'help' } },
            h('div', { style: styles.fieldLabelZh }, e.label, e.advanced ? h('span', { style: styles.badge }, t('params.advancedBadge')) : null),
            h('div', { style: styles.fieldLabelEn }, `${e.en}  ·  ${e.key}`),
            h('div', { style: styles.fieldHint }, `${TYPE_LABEL[e.type] || e.type}${deps.length ? ` · ${t('params.depsLabel')}：${deps.join(' / ')}` : ''}`)
          ),
          h('div', { style: styles.fieldControl },
            controlFor(e, disabled),
            h('div', { style: styles.fieldHint }, `${t('params.defaultLabel')}：${formatValue(e.default)}`)
          )
        );
      };

      const needle = filter.trim().toLowerCase();
      const matching = entries.filter((e) => {
        if (!showAdvanced && e.advanced) return false;
        if (!needle) return e.group === activeGroup;
        return [e.key, e.label, e.en, e.group].some((x) => String(x ?? '').toLowerCase().includes(needle));
      });
      const groupedSearch = needle
        ? groups.map((g) => ({ group: g, items: matching.filter((e) => e.group === g) })).filter((x) => x.items.length)
        : [];

      const apply = () => {
        const merged = new Map((schema.overrides || []).map((o) => [o.key, o.value]));
        for (const k of dirtyKeys) merged.set(k, draft[k]);
        onApply([...merged.entries()].map(([key, value]) => ({ key, value })));
      };

      return h('div', {
        style: styles.overlay,
        role: 'presentation',
        onMouseDown: (ev) => { if (ev.target === ev.currentTarget) onClose(); }
      },
        h('div', { style: styles.dialog, role: 'dialog', 'aria-modal': 'true', 'aria-label': t('params.title') },
          h('div', { style: styles.dialogHeader },
            h('div', null,
              h('h3', { style: styles.dialogTitle }, `${t('params.title')}  /  Parameter settings`),
              h('p', { style: styles.dialogSub }, `${t('params.subtitle')} · ${entries.length} ${t('params.items')}`)
            ),
            h('button', { type: 'button', style: styles.iconBtn, onClick: onClose, title: t('params.close'), 'aria-label': t('params.close') }, '×')
          ),
          h('div', { style: styles.dialogBody },
            h('div', { style: styles.groupNav },
              h('div', { style: Object.assign({}, styles.fieldHint, { padding: '4px 8px 8px', fontWeight: 600 }) }, t('params.groupTitle')),
              groups.map((g) => h('button', {
                key: g,
                type: 'button',
                style: !needle && g === activeGroup ? styles.groupBtnActive : styles.groupBtn,
                onClick: () => { setFilter(''); setActiveGroup(g); }
              }, groupLabel(g)))
            ),
            h('div', { style: styles.formPane },
              h('div', { style: styles.formToolbar },
                h('input', {
                  style: Object.assign({}, styles.input, { flex: '1 1 auto' }),
                  placeholder: t('params.search'),
                  value: filter,
                  onChange: (ev) => setFilter(ev.target.value)
                }),
                h('label', { style: { display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 12, whiteSpace: 'nowrap' } },
                  h('input', { type: 'checkbox', checked: showAdvanced, onChange: (ev) => setShowAdvanced(ev.target.checked) }),
                  t('params.showAdvanced')
                )
              ),
              h('div', { style: styles.formScroll },
                needle
                  ? (groupedSearch.length
                    ? groupedSearch.map(({ group, items }) => h('div', { key: group },
                      h('div', { style: { padding: '12px 0 4px', fontWeight: 600, fontSize: 13, borderBottom: '1px solid var(--dsw-alias-border-l1)' } }, groupLabel(group)),
                      items.map(renderField)))
                    : h('p', { style: styles.hint }, t('params.noMatch')))
                  : matching.map(renderField)
              )
            )
          ),
          h('div', { style: styles.dialogFooter },
            h('div', { style: styles.footerLeft },
              `${t('params.changed')} ${dirtyKeys.length} ${t('params.items')} · ${t('params.overrides')} ${overridesCount} ${t('params.items')}`),
            h('div', { style: styles.footerRight },
              h('button', { type: 'button', style: styles.danger, disabled: applyBusy, onClick: () => onApply([]) }, t('params.clearAll')),
              h('button', { type: 'button', style: styles.button, disabled: applyBusy, onClick: () => setDraft(Object.assign({}, defaults)) }, t('params.reset')),
              h('button', { type: 'button', style: styles.button, disabled: applyBusy, onClick: onClose }, t('params.cancel')),
              h('button', { type: 'button', style: styles.primary, disabled: applyBusy, onClick: apply }, applyBusy ? '…' : t('params.apply'))
            )
          )
        )
      );
    }

    const VERDICT_COLORS = {
      ok: 'var(--dsw-alias-state-success-primary, #2e7d32)',
      attention: 'var(--dsw-alias-state-warn-primary, #f9a825)',
      warn: 'var(--dsw-alias-state-warn-primary, #ef6c00)',
      bad: 'var(--dsw-alias-state-error-primary, #c62828)',
      unknown: 'var(--dsw-alias-label-secondary)'
    };

    // 多受试者逐帧 FD 曲线（SVG，不依赖任何图表库）：可勾选多名受试者叠加对比
    const SERIES_COLORS = ['#1565c0', '#ef6c00', '#2e7d32', '#c62828', '#6a1b9a', '#00838f', '#ad1457', '#4e342e'];

    // Scrubbing 前/后扩展帧数的可选值（对应 DPABI Scrubbing.PreviousPoints / LaterPoints，Host 侧上限 12）
    const CENSOR_POINT_OPTIONS = Array.from({ length: 13 }, (_, i) => String(i));

    // T1 裁剪兼容模式（参数覆盖 T1CropCompat）：
    //   auto       = DPARSF 默认（T1 为 DICOM 时仍由 dcm2niix 裁剪）
    //   old_dcm2nii= 运行前用旧版 dcm2nii 对 NIfTI T1 重定向+裁剪，生成真正的 c*/co*
    //   no_crop    = 不做重定向/去颈，把未裁剪 T1 复制为 c* 直通副本（分割质量需 QC）
    const T1_CROP_COMPAT_OPTIONS = ['auto', 'old_dcm2nii', 'no_crop'];

    function shortSubjectId(id) {
      return String(id ?? '').replace(/^sub-/, '').replace('_ses-', ' · ');
    }

    // subjects: 要叠加展示的受试者数组；colors: 与 subjects 对齐的颜色；metric: 'jenkinson' | 'power'
    function FdCurveChart({ t, subjects, colors, metric, threshold }) {
      const W = 720, H = 250, L = 56, R = 14, T = 18, B = 30;
      const list = Array.isArray(subjects) ? subjects : [];
      const seriesOf = (s) => (Array.isArray(s?.series?.[metric]) ? s.series[metric] : []);
      const n = Math.max(0, ...list.map((s) => seriesOf(s).length));
      if (!list.length || !n) return h('p', { style: styles.hint }, t('res.noneSelected'));
      let maxVal = Math.max(threshold * 1.4, 0.3);
      for (const s of list) for (const v of seriesOf(s)) if (Number.isFinite(v)) maxVal = Math.max(maxVal, v);
      const yMax = Math.ceil(maxVal * 10) / 10;
      const x = (i) => L + (n <= 1 ? 0 : (i / (n - 1)) * (W - L - R));
      const y = (v) => T + (1 - Math.max(0, Math.min(yMax, Number(v) || 0)) / yMax) * (H - T - B);
      const points = (values) => values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
      const marks = [];
      for (let k = 0; k <= 4; k++) {
        const value = (yMax * k) / 4;
        const yy = y(value);
        marks.push(h('line', { key: `g${k}`, x1: L, y1: yy, x2: W - R, y2: yy, stroke: 'var(--dsw-alias-border-l1)', strokeWidth: 1 }));
        marks.push(h('text', { key: `gt${k}`, x: L - 8, y: yy + 3, textAnchor: 'end', fontSize: 10, fill: 'var(--dsw-alias-label-secondary)' }, value.toFixed(2)));
      }
      for (let k = 0; k <= 4; k++) {
        const frame = Math.round((k / 4) * (n - 1));
        marks.push(h('text', { key: `xt${k}`, x: x(frame), y: H - 10, textAnchor: 'middle', fontSize: 10, fill: 'var(--dsw-alias-label-secondary)' }, String(frame + 1)));
      }
      const thY = y(threshold);
      const label = metric === 'power' ? 'FD_Power' : 'FD_Jenkinson';
      return h('div', null,
        h('div', { style: Object.assign({}, styles.small, { marginBottom: 4 }) }, `${label}（mm/帧） · 已选 ${list.length} 名受试者`),
        h('svg', { viewBox: `0 0 ${W} ${H}`, style: styles.chartSvg, role: 'img', 'aria-label': `${t('res.chartTitle')} (${label})` },
          h('rect', { x: L, y: T, width: W - L - R, height: H - T - B, fill: 'transparent' }),
          marks,
          h('line', { x1: L, y1: thY, x2: W - R, y2: thY, stroke: '#c62828', strokeWidth: 1.2, strokeDasharray: '5 4' }),
          h('text', { x: W - R, y: thY - 5, textAnchor: 'end', fontSize: 10, fill: '#c62828' }, `${threshold.toFixed(2)} mm`),
          list.map((s, idx) => {
            const values = seriesOf(s);
            if (values.length < 2) return null;
            const color = (Array.isArray(colors) && colors[idx]) || SERIES_COLORS[idx % SERIES_COLORS.length];
            return h('g', { key: `series-${s.id}` },
              h('title', null, s.id),
              h('polyline', { points: points(values), fill: 'none', stroke: color, strokeWidth: 1.6, opacity: 0.95 }),
              metric === 'jenkinson'
                ? values.map((v, i) => (Number.isFinite(v) && v > threshold
                  ? h('circle', { key: `b${i}`, cx: x(i), cy: y(v), r: 1.8, fill: '#c62828' })
                  : null))
                : null
            );
          }),
          h('text', { x: W / 2, y: H - 0.5, textAnchor: 'middle', fontSize: 10, fill: 'var(--dsw-alias-label-secondary)' }, t('res.frames')),
          h('text', { x: L + 4, y: T + 10, fontSize: 10, fill: 'var(--dsw-alias-label-secondary)' }, 'FD (mm)')
        )
      );
    }

    function WorkbenchView({ t, sessionId, ctx, onBack }) {
      const [busy, setBusy] = React.useState('');
      const [output, setOutput] = React.useState('');
      const [error, setError] = React.useState('');
      const [root, setRoot] = React.useState('');
      const [browseBusy, setBrowseBusy] = React.useState(false);
      const [browseError, setBrowseError] = React.useState('');
      const [depth, setDepth] = React.useState('6');
      const [preset, setPreset] = React.useState('4');
      const [overridesText, setOverridesText] = React.useState('[]');
      const [schema, setSchema] = React.useState(null);
      const [paramsOpen, setParamsOpen] = React.useState(false);
      const [schemaBusy, setSchemaBusy] = React.useState(false);
      const [overrideCount, setOverrideCount] = React.useState(0);
      const [showJson, setShowJson] = React.useState(false);
      const [workerValue, setWorkerValue] = React.useState(null);
      const [workerBusy, setWorkerBusy] = React.useState(false);
      const [t1CropValue, setT1CropValue] = React.useState('auto');
      const [t1CropBusy, setT1CropBusy] = React.useState(false);
      const [results, setResults] = React.useState(null);
      const [resultsBusy, setResultsBusy] = React.useState(false);
      const [resultsError, setResultsError] = React.useState('');
      const [resultsThreshold, setResultsThreshold] = React.useState('0.2');
      const [resultsMetric, setResultsMetric] = React.useState('jenkinson');
      const [selectedChartSubjects, setSelectedChartSubjects] = React.useState([]);
      const [censorType, setCensorType] = React.useState('jenkinson');
      const [censorThreshold, setCensorThreshold] = React.useState('0.2');
      const [censorPrevious, setCensorPrevious] = React.useState('0');
      const [censorLater, setCensorLater] = React.useState('0');
      const [scrubMethod, setScrubMethod] = React.useState('cut');
      const [censorBusy, setCensorBusy] = React.useState(false);
      const [censorNotice, setCensorNotice] = React.useState('');

      const exec = async (line, opts = {}) => {
        setBusy(line);
        setError('');
        try {
          const result = await ctx.remote.commands.execute(sessionId, line, []);
          if (!result || result.ok !== true) {
            throw new Error(result?.error?.message ?? '命令执行失败');
          }
          if (result.value === undefined) {
            throw new Error('命令不可用：工作台插件可能未激活，请刷新页面后重试。');
          }
          const commandResult = result.value.result;
          if (commandResult?.kind === 'error') throw new Error(commandResult.text ?? '命令返回错误');
          const text = commandResult?.text ?? '';
          if (!opts.silent) setOutput(text);
          return text;
        } catch (err) {
          setError(String(err?.message ?? err));
          return '';
        } finally {
          setBusy('');
        }
      };

      const disabled = !!busy;

      // ① 卡「浏览…」：弹出系统文件夹选择框，把选中的绝对路径写入数据根目录
      const browseRoot = async () => {
        if (browseBusy || disabled) return;
        setBrowseBusy(true);
        setBrowseError('');
        try {
          const picked = await pickDirectoryFromHost(ctx);
          const value = typeof picked === 'string' ? picked.trim() : '';
          if (value) setRoot(value);
        } catch (err) {
          if (err && err.code === MRW_NO_DIRECTORY_PICKER) {
            setBrowseError(t('data.browseUnavailable'));
          } else {
            setBrowseError(`${t('data.browseFailed')}${String(err?.message ?? err)}`);
          }
        } finally {
          setBrowseBusy(false);
        }
      };

      // 将文本编码为 UTF-8 base64（供 /mri overrides set 传参，避免命令行的引号/空格问题）
      const toBase64Utf8 = (text) => {
        const bytes = new TextEncoder().encode(String(text ?? ''));
        let bin = '';
        for (const b of bytes) bin += String.fromCharCode(b);
        return btoa(bin);
      };

      const workerFromOverrides = (list) => {
        const item = (Array.isArray(list) ? list : []).find((o) => o && o.key === 'ParallelWorkersNumber');
        const n = Number(item?.value);
        return Number.isFinite(n) && n > 0 ? n : null;
      };

      // 从已保存覆盖中解析 T1CropCompat；未设置或值无效时回退 auto（DPARSF 默认）
      const t1CropFromOverrides = (list) => {
        const item = (Array.isArray(list) ? list : []).find((o) => o && o.key === 'T1CropCompat');
        const value = String(item?.value ?? '');
        return T1_CROP_COMPAT_OPTIONS.includes(value) ? value : 'auto';
      };

      // 从 Host 读取当前参数覆盖，并同步 JSON 编辑器与「并行 worker 数」「T1 裁剪兼容模式」选择器
      const loadOverrides = async () => {
        const text = await exec('/mri paramsjson', { silent: true });
        const data = JSON.parse(text);
        if (!data || data.ok !== true) throw new Error('参数列表格式错误');
        const list = Array.isArray(data.overrides) ? data.overrides : [];
        setOverrideCount(list.length);
        setOverridesText(JSON.stringify(list, null, 2));
        setWorkerValue(workerFromOverrides(list));
        setT1CropValue(t1CropFromOverrides(list));
        return list;
      };

      // ② 卡上的「并行 worker 数」快速选择：只改 ParallelWorkersNumber 一项，保留其他覆盖
      const applyWorker = async (raw) => {
        setWorkerBusy(true);
        setError('');
        try {
          const list = await loadOverrides();
          const rest = list.filter((o) => o && o.key !== 'ParallelWorkersNumber');
          if (raw !== 'unset') {
            const n = Number(raw);
            if (!Number.isInteger(n) || n <= 0) throw new Error('并行 worker 数必须是正整数');
            rest.push({ key: 'ParallelWorkersNumber', value: n });
          }
          await exec(`/mri overrides set ${toBase64Utf8(JSON.stringify(rest))}`, { silent: true });
          setOverrideCount(rest.length);
          setOverridesText(JSON.stringify(rest, null, 2));
          setWorkerValue(raw === 'unset' ? null : Number(raw));
          setOutput(raw === 'unset'
            ? '已取消并行设置，恢复为串行（0）'
            : `并行 worker 数已设为 ${raw}（参数覆盖，下次生成配置时生效）`);
        } catch (err) {
          setError(`设置并行 worker 数失败：${String(err?.message ?? err)}`);
        } finally {
          setWorkerBusy(false);
        }
      };

      // ② 卡上的「T1 裁剪兼容模式」快速选择：只改 T1CropCompat 一项，保留其他覆盖；auto 时移除该项
      const t1CropLabel = (value) => (value === 'old_dcm2nii'
        ? t('prep.t1CropOldDcm2nii')
        : (value === 'no_crop' ? t('prep.t1CropNoCrop') : t('prep.t1CropAuto')));
      const applyT1Crop = async (raw) => {
        const value = T1_CROP_COMPAT_OPTIONS.includes(raw) ? raw : 'auto';
        setT1CropBusy(true);
        setError('');
        try {
          const list = await loadOverrides();
          const rest = list.filter((o) => o && o.key !== 'T1CropCompat');
          if (value !== 'auto') rest.push({ key: 'T1CropCompat', value });
          await exec(`/mri overrides set ${toBase64Utf8(JSON.stringify(rest))}`, { silent: true });
          setOverrideCount(rest.length);
          setOverridesText(JSON.stringify(rest, null, 2));
          setT1CropValue(value);
          setOutput(value === 'auto'
            ? 'T1 裁剪兼容模式已恢复为自动（DPARSF 默认），已移除该项参数覆盖'
            : `T1 裁剪兼容模式已设为「${t1CropLabel(value)}」（参数覆盖，下次生成配置时生效）`);
        } catch (err) {
          setError(`设置 T1 裁剪兼容模式失败：${String(err?.message ?? err)}`);
        } finally {
          setT1CropBusy(false);
        }
      };

      // 页面加载时同步一次当前覆盖（只读会话状态，不启动 MATLAB）
      React.useEffect(() => {
        let cancelled = false;
        (async () => {
          try {
            const result = await ctx.remote.commands.execute(sessionId, '/mri paramsjson', []);
            const text = result?.value?.result?.text;
            if (cancelled || result?.ok !== true || !text) return;
            const data = JSON.parse(text);
            if (!data || data.ok !== true) return;
            const list = Array.isArray(data.overrides) ? data.overrides : [];
            setOverrideCount(list.length);
            setOverridesText(JSON.stringify(list, null, 2));
            setWorkerValue(workerFromOverrides(list));
            setT1CropValue(t1CropFromOverrides(list));
          } catch {
            /* 读取失败不影响页面其他功能 */
          }
        })();
        return () => { cancelled = true; };
      }, []);

      // 读取并解读头动结果（Host 侧纯 Node 解析 RealignParameter，不启动 MATLAB）
      const loadResults = async (thresholdOverride) => {
        const threshold = thresholdOverride ?? resultsThreshold;
        setResultsBusy(true);
        setResultsError('');
        try {
          const text = await exec(`/mri resultsjson ${threshold}`, { silent: true });
          const data = JSON.parse(text);
          if (!data || data.ok !== true) throw new Error('结果格式错误');
          setResults(data);
          const ids = (data.subjects || []).map((s) => s.id);
          setSelectedChartSubjects((prev) => {
            const keep = (Array.isArray(prev) ? prev : []).filter((id) => ids.includes(id));
            return keep.length ? keep : ids;
          });
        } catch (err) {
          setResultsError(String(err?.message ?? err));
        } finally {
          setResultsBusy(false);
        }
      };

      const changeResultsThreshold = (value) => {
        setResultsThreshold(value);
        return loadResults(value);
      };

      const toggleChartSubject = (id) => {
        setSelectedChartSubjects((prev) => {
          const list = Array.isArray(prev) ? prev : [];
          return list.includes(id) ? list.filter((x) => x !== id) : [...list, id];
        });
      };

      const setAllChartSubjects = (all) => {
        const ids = (results?.subjects || []).map((s) => s.id);
        setSelectedChartSubjects(all ? ids : []);
      };

      // Scrubbing 前/后扩展帧数（0–12，对应 Scrubbing.PreviousPoints / LaterPoints）：预览、导出与参数覆盖共用
      const censorPoints = (value) => Math.min(12, Math.max(0, Math.round(Number(value) || 0)));

      // 按当前 censor 设置，从已加载的逐帧 FD 序列计算坏帧（用于预览；导出由 Host 用完整序列计算）
      const censorFramesFor = (subject) => {
        const series = Array.isArray(subject?.series?.[censorType]) ? subject.series[censorType] : [];
        const threshold = Number(censorThreshold) || 0.2;
        const previous = censorPoints(censorPrevious);
        const later = censorPoints(censorLater);
        const flagged = new Set();
        series.forEach((value, index) => {
          if (!(Number.isFinite(value) && value > threshold)) return;
          const frame = index + 1;
          for (let offset = -previous; offset <= later; offset++) {
            const target = frame + offset;
            if (target >= 1 && target <= series.length) flagged.add(target);
          }
        });
        const frames = [...flagged].sort((a, b) => a - b);
        const sampled = Number.isFinite(subject?.frames) && subject.frames > series.length;
        return {
          frames,
          count: frames.length,
          total: series.length,
          percent: series.length ? (frames.length / series.length) * 100 : null,
          sampled,
          previous,
          later,
        };
      };

      const exportCensor = async () => {
        setCensorBusy(true);
        setCensorNotice('');
        try {
          const expand = `prev=${censorPoints(censorPrevious)} later=${censorPoints(censorLater)}`;
          const text = await exec(`/mri censor ${censorType} ${censorThreshold} ${expand}`, { silent: true });
          const lines = String(text ?? '').split(/\r?\n/);
          const exported = lines.find((line) => line.startsWith('已导出：'));
          setCensorNotice(exported ? `${t('res.censorExported')}${exported.replace('已导出：', '').trim()}` : String(text ?? '').slice(0, 500));
        } catch (err) {
          setCensorNotice(`${t('res.error')}${String(err?.message ?? err)}`);
        } finally {
          setCensorBusy(false);
        }
      };

      const applyScrubbingConfig = async () => {
        setCensorBusy(true);
        setCensorNotice('');
        try {
          const list = await loadOverrides();
          const isSpike = scrubMethod === 'spike';
          // DPABI 两种做法互斥：先清掉 IsScrubbing 与头动 scrubbing 回归量两套旧覆盖，再按当前方式写入
          const rest = list.filter((o) => o
            && o.key !== 'IsScrubbing'
            && !String(o.key).startsWith('Scrubbing.')
            && o.key !== 'Covremove.IsHeadMotionScrubbingRegressors'
            && !String(o.key).startsWith('Covremove.HeadMotionScrubbingRegressors.'));
          const fdType = censorType === 'power' ? 'FD_Power' : 'FD_Jenkinson';
          const fdThreshold = Number(censorThreshold) || 0.2;
          const previous = censorPoints(censorPrevious);
          const later = censorPoints(censorLater);
          // spike = DPABI 的「头动 scrubbing 回归量」（每坏帧一个回归量，不缩短序列）
          const payload = rest.concat(isSpike ? [
            { key: 'IsScrubbing', value: 0 },
            { key: 'Covremove.IsHeadMotionScrubbingRegressors', value: 1 },
            { key: 'Covremove.HeadMotionScrubbingRegressors.FDType', value: fdType },
            { key: 'Covremove.HeadMotionScrubbingRegressors.FDThreshold', value: fdThreshold },
            { key: 'Covremove.HeadMotionScrubbingRegressors.PreviousPoints', value: previous },
            { key: 'Covremove.HeadMotionScrubbingRegressors.LaterPoints', value: later },
          ] : [
            { key: 'IsScrubbing', value: 1 },
            { key: 'Scrubbing.FDType', value: fdType },
            { key: 'Scrubbing.FDThreshold', value: fdThreshold },
            { key: 'Scrubbing.PreviousPoints', value: previous },
            { key: 'Scrubbing.LaterPoints', value: later },
            { key: 'Scrubbing.ScrubbingMethod', value: scrubMethod },
            { key: 'Covremove.IsHeadMotionScrubbingRegressors', value: 0 },
          ]);
          await exec(`/mri overrides set ${toBase64Utf8(JSON.stringify(payload))}`, { silent: true });
          setOverrideCount(payload.length);
          setOverridesText(JSON.stringify(payload, null, 2));
          setCensorNotice(t(isSpike ? 'res.spikeApplied' : 'res.censorApplied'));
        } catch (err) {
          setCensorNotice(`${t('res.error')}${String(err?.message ?? err)}`);
        } finally {
          setCensorBusy(false);
        }
      };

      // 页面加载时自动读取一次头动结果（目录由 Host 从最近配置推导；无结果时显示提示）
      React.useEffect(() => {
        let cancelled = false;
        (async () => {
          try {
            const result = await ctx.remote.commands.execute(sessionId, '/mri resultsjson 0.2', []);
            const text = result?.value?.result?.text;
            if (cancelled || result?.ok !== true || !text) return;
            const data = JSON.parse(text);
            if (!data || data.ok !== true) return;
            setResults(data);
            setSelectedChartSubjects((data.subjects || []).map((s) => s.id));
          } catch {
            /* 无结果/读取失败时保留“点按钮读取”的入口 */
          }
        })();
        return () => { cancelled = true; };
      }, []);

      const applyOverrides = () => {
        setError('');
        let parsed;
        try {
          parsed = JSON.parse(overridesText);
        } catch (err) {
          setError(`${t('prep.overrides')}：${String(err?.message ?? err)}`);
          return;
        }
        if (!Array.isArray(parsed)) {
          setError(`${t('prep.overrides')}：需要一个 JSON 数组，例如 [{"key":"TR","value":2}]`);
          return;
        }
        setOverrideCount(parsed.length);
        setWorkerValue(workerFromOverrides(parsed));
        exec(`/mri overrides set ${toBase64Utf8(JSON.stringify(parsed))}`);
      };

      const clearOverrides = () => {
        setOverridesText('[]');
        setOverrideCount(0);
        setWorkerValue(null);
        exec('/mri overrides clear');
      };

      // 打开「DPARSF 风格参数设置弹窗」：从 Host 取 CfgSchema（含中文悬停解释）
      const openParams = async () => {
        setSchemaBusy(true);
        setError('');
        try {
          const text = await exec('/mri paramsjson', { silent: true });
          const data = JSON.parse(text);
          if (!data || data.ok !== true) throw new Error('参数列表格式错误');
          setSchema(data);
          setOverrideCount((data.overrides || []).length);
          setOverridesText(JSON.stringify(data.overrides || [], null, 2));
          setWorkerValue(workerFromOverrides(data.overrides || []));
          setParamsOpen(true);
        } catch (err) {
          setError(`${t('params.error')}${String(err?.message ?? err)}`);
        } finally {
          setSchemaBusy(false);
        }
      };

      const applyDialogOverrides = async (list) => {
        const payload = Array.isArray(list) ? list : [];
        await exec(`/mri overrides set ${toBase64Utf8(JSON.stringify(payload))}`);
        setOverrideCount(payload.length);
        setOverridesText(JSON.stringify(payload, null, 2));
        setWorkerValue(workerFromOverrides(payload));
        setParamsOpen(false);
      };

      const renderResultsBody = () => {
        if (!results) return null;
        if (!results.available) {
          return h('div', null,
            h('p', { style: styles.hint, 'data-role': 'results-unavailable' }, `${t('res.unavailable')}：${results.message ?? ''}`),
            h('p', { style: styles.small }, t('res.autoHint')),
            Array.isArray(results.warnings) && results.warnings.length
              ? h('ul', { style: styles.resultSummary }, results.warnings.map((w, i) => h('li', { key: i }, w)))
              : null
          );
        }
        const subjects = Array.isArray(results.subjects) ? results.subjects : [];
        const summary = results.summary || {};
        const pickedIds = Array.isArray(selectedChartSubjects) ? selectedChartSubjects : [];
        const fmt = (v, d = 2) => (Number.isFinite(Number(v)) ? Number(v).toFixed(d) : '—');
        const sorted = [...subjects].sort((a, b) => (b.metrics?.meanFDJenkinson ?? -1) - (a.metrics?.meanFDJenkinson ?? -1));
        const colorFor = (s) => SERIES_COLORS[Math.max(0, sorted.findIndex((x) => x.id === s.id)) % SERIES_COLORS.length];
        const picked = sorted.filter((s) => pickedIds.includes(s.id));
        const pickedColors = picked.map(colorFor);
        const gradeSpan = (text, grade) => h('span', {
          title: grade?.label || '',
          style: grade ? { color: VERDICT_COLORS[grade.level] || 'inherit', fontWeight: 600 } : {}
        }, text);
        return h('div', null,
          h('div', { style: styles.resultSummary },
            h('div', { style: { fontWeight: 600, marginBottom: 4 } }, t('res.summaryTitle')),
            h('div', { 'data-role': 'results-summary' },
              `受试者 ${summary.count ?? subjects.length} 名；组均值 mean FD_Jenkinson = ${fmt(summary.mean, 3)} mm；中位数 ${fmt(summary.median, 3)} mm；最大 ${fmt(summary.max, 3)} mm${summary.worstSubject ? `（${summary.worstSubject}）` : ''}`
            ),
            h('div', null, `${t('res.overThreshold')} ${results.threshold} mm：${summary.overThreshold?.length ? summary.overThreshold.join('、') : t('res.none')}`)
          ),
          h('div', { style: { margin: '10px 0 4px', fontWeight: 600 } }, t('res.tableTitle')),
          h('table', { style: styles.resultTable, 'data-role': 'results-table' },
            h('thead', null, h('tr', null,
              [t('res.colSubject'), t('res.colMeanFD'), t('res.colMeanFDPower'), t('res.colMaxTrans'), t('res.colMaxRot'), t('res.colBadFrames'), t('res.colVerdict')]
                .map((label) => h('th', { key: label, style: styles.resultTh }, label))
            )),
            h('tbody', null, sorted.map((s) => {
              const m = s.metrics || {};
              const pct = Number.isFinite(m.pctFDPower02) ? `${fmt(m.pctFDPower02 * 100, 1)}%` : '—';
              return h('tr', {
                key: s.id,
                style: Object.assign({}, styles.resultRow, pickedIds.includes(s.id) ? styles.resultRowActive : {}),
                onClick: () => toggleChartSubject(s.id),
                title: '点击切换是否在曲线图中显示',
                'data-subject': s.id,
              },
                h('td', { style: styles.resultTd }, s.id),
                h('td', { style: styles.resultTd }, fmt(m.meanFDJenkinson, 3)),
                h('td', { style: styles.resultTd }, fmt(m.meanFDPower, 3)),
                h('td', { style: styles.resultTd }, gradeSpan(fmt(s.maxTranslation, 2), s.grades?.maxTranslation)),
                h('td', { style: styles.resultTd }, gradeSpan(fmt(s.maxRotation, 2), s.grades?.maxRotation)),
                h('td', { style: styles.resultTd }, gradeSpan(`${fmt(m.nFDPower02, 0)} / ${pct}`, s.grades?.badFrameRatio)),
                h('td', { style: styles.resultTd },
                  h('span', { style: Object.assign({}, styles.pill, { color: VERDICT_COLORS[s.verdict?.level] || VERDICT_COLORS.unknown }) }, s.verdict?.label ?? '—')
                )
              );
            }))
          ),
          results.references
            ? h('div', { style: { margin: '10px 0 6px' } },
              h('div', { style: { fontWeight: 600, marginBottom: 2 } }, t('res.gradingTitle')),
              h('ul', { style: styles.resultSummary, 'data-role': 'results-grading' },
                ['maxTranslation', 'maxRotation', 'badFrameRatio'].map((key) => {
                  const ref = results.references[key];
                  return ref
                    ? h('li', { key }, `${ref.label}（${ref.unit}）：${(ref.tiers || []).map((tier) => tier.label).join('；')}`)
                    : null;
                })
              ),
              results.references.gradingNote ? h('p', { style: styles.small }, results.references.gradingNote) : null
            )
            : null,
          h('div', { style: { margin: '12px 0 4px', fontWeight: 600 } }, t('res.chartTitle')),
          h('div', { style: styles.row },
            h('label', { style: styles.label, htmlFor: 'mrw-fd-metric' }, t('res.metric')),
            h('select', {
              id: 'mrw-fd-metric', style: styles.select, value: resultsMetric,
              onChange: (e) => setResultsMetric(e.target.value),
              'data-action': 'fd-metric'
            },
              h('option', { value: 'jenkinson' }, 'FD_Jenkinson'),
              h('option', { value: 'power' }, 'FD_Power')
            )
          ),
          h('div', { style: styles.row },
            h('span', { style: styles.label }, t('res.subjectsPick')),
            sorted.map((s) => h('label', {
              key: s.id,
              style: { display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 11, cursor: 'pointer', whiteSpace: 'nowrap' },
              'data-subject-check': s.id,
            },
              h('input', {
                type: 'checkbox',
                checked: pickedIds.includes(s.id),
                onChange: () => toggleChartSubject(s.id)
              }),
              h('span', { style: { color: colorFor(s) } }, shortSubjectId(s.id))
            )),
            btn(t('res.selectAll'), styles.button, () => setAllChartSubjects(true), { 'data-action': 'subjects-all' }),
            btn(t('res.clearAll'), styles.button, () => setAllChartSubjects(false), { 'data-action': 'subjects-none' })
          ),
          picked.length
            ? h('div', { style: styles.chartBox, 'data-role': 'results-chart' },
              h(FdCurveChart, { t, subjects: picked, colors: pickedColors, metric: resultsMetric, threshold: Number(results.threshold) || 0.2 }))
            : h('p', { style: styles.hint, 'data-role': 'results-chart-empty' }, t('res.noneSelected')),
          h('p', { style: styles.small }, t('res.chartHint')),
          h('div', { style: { margin: '12px 0 4px', fontWeight: 600 } }, t('res.censorTitle')),
          h('div', { style: styles.row },
            h('label', { style: styles.label, htmlFor: 'mrw-censor-type' }, t('res.censorFdType')),
            h('select', {
              id: 'mrw-censor-type', style: styles.select, value: censorType,
              onChange: (e) => setCensorType(e.target.value),
              'data-action': 'censor-type'
            },
              h('option', { value: 'jenkinson' }, 'FD_Jenkinson'),
              h('option', { value: 'power' }, 'FD_Power')
            ),
            h('label', { style: styles.label, htmlFor: 'mrw-censor-threshold' }, t('res.censorThreshold')),
            h('select', {
              id: 'mrw-censor-threshold', style: styles.select, value: censorThreshold,
              onChange: (e) => setCensorThreshold(e.target.value),
              'data-action': 'censor-threshold'
            }, ['0.2', '0.5', '1'].map((value) => h('option', { key: value, value }, `${value} mm`))),
            h('label', { style: styles.label, htmlFor: 'mrw-censor-previous' }, t('res.censorPrevious')),
            h('select', {
              id: 'mrw-censor-previous', style: styles.select, value: censorPrevious,
              onChange: (e) => setCensorPrevious(e.target.value),
              title: '对应 DPABI Scrubbing.PreviousPoints：坏帧向前（更早方向）扩展的帧数',
              'data-action': 'censor-previous'
            }, CENSOR_POINT_OPTIONS.map((value) => h('option', { key: value, value }, value))),
            h('label', { style: styles.label, htmlFor: 'mrw-censor-later' }, t('res.censorLater')),
            h('select', {
              id: 'mrw-censor-later', style: styles.select, value: censorLater,
              onChange: (e) => setCensorLater(e.target.value),
              title: '对应 DPABI Scrubbing.LaterPoints：坏帧向后（更晚方向）扩展的帧数',
              'data-action': 'censor-later'
            }, CENSOR_POINT_OPTIONS.map((value) => h('option', { key: value, value }, value))),
            h('label', { style: styles.label, htmlFor: 'mrw-scrub-method' }, t('res.scrubMethod')),
            h('select', {
              id: 'mrw-scrub-method', style: styles.select, value: scrubMethod,
              onChange: (e) => setScrubMethod(e.target.value),
              'data-action': 'scrub-method'
            },
              ['cut', 'nearest', 'linear', 'spline', 'pchip'].map((value) => h('option', { key: value, value }, value))
                .concat([h('option', { key: 'spike', value: 'spike' }, t('res.scrubSpike'))])
            ),
            btn(t('res.censorExport'), styles.button, exportCensor, { 'data-action': 'censor-export', disabled: censorBusy }),
            btn(t('res.censorApply'), styles.button, applyScrubbingConfig, { 'data-action': 'censor-apply', disabled: censorBusy })
          ),
          scrubMethod === 'spike'
            ? h('p', { style: styles.small, 'data-role': 'spike-hint' }, t('res.spikeHint'))
            : null,
          censorBusy ? h('p', { style: styles.busy }, t('res.censorBusy')) : null,
          censorNotice ? h('p', { style: styles.small, 'data-role': 'censor-notice' }, censorNotice) : null,
          h('div', { style: { margin: '6px 0 4px', fontWeight: 600 } }, t('res.censorPreview')),
          h('table', { style: styles.resultTable, 'data-role': 'censor-table' },
            h('thead', null, h('tr', null,
              [t('res.colCensorSubject'), t('res.colCensorCount'), t('res.colCensorPct'), t('res.colCensorFrames')]
                .map((label) => h('th', { key: label, style: styles.resultTh }, label))
            )),
            h('tbody', null, sorted.map((s) => {
              const info = censorFramesFor(s);
              const pct = info.percent === null ? '—' : `${fmt(info.percent, 1)}%`;
              const head = info.frames.slice(0, 12).join(', ')
                + (info.frames.length > 12 ? ` …（${info.frames.length} 帧）` : '');
              return h('tr', { key: s.id, 'data-censor-subject': s.id },
                h('td', { style: styles.resultTd }, s.id),
                h('td', { style: styles.resultTd }, String(info.count)),
                h('td', { style: styles.resultTd }, pct),
                h('td', { style: styles.resultTd }, head || '—')
              );
            }))
          ),
          sorted.some((s) => Number.isFinite(s?.frames) && (s.series?.[censorType]?.length || 0) < s.frames)
            ? h('p', { style: styles.small }, t('res.censorSampled'))
            : null,
          h('p', { style: styles.small }, t('res.censorHint')),
          h('div', { style: { margin: '12px 0 2px', fontWeight: 600 } }, t('res.explainTitle')),
          h('ul', { style: styles.resultSummary }, (results.explanations?.overview || []).map((text, i) => h('li', { key: i }, text))),
          results.explanations?.thresholdNote ? h('p', { style: styles.small }, results.explanations.thresholdNote) : null,
          Array.isArray(results.scrubbing?.notes) && results.scrubbing.notes.length
            ? h('div', null,
              h('div', { style: { margin: '10px 0 2px', fontWeight: 600 } }, 'Scrubbing / Censor 说明'),
              h('ul', { style: styles.resultSummary, 'data-role': 'scrubbing-notes' }, results.scrubbing.notes.map((note, i) => h('li', { key: i }, note)))
            )
            : null,
          Array.isArray(results.excludedByMaxMotion) && results.excludedByMaxMotion.length
            ? h('div', null,
              h('div', { style: { margin: '10px 0 2px', fontWeight: 600 } }, 'DPARSF 最大头动排除名单'),
              h('ul', { style: styles.resultSummary }, results.excludedByMaxMotion.map((g, i) => h('li', { key: i }, `${g.criteria}：${g.subjects.length ? g.subjects.join('、') : t('res.none')}`)))
            )
            : null,
          h('p', { style: styles.small }, `结果目录：${results.workDir}${results.files?.headMotionTsv ? ` · ${results.files.headMotionTsv}` : ''}`)
        );
      };

      const btn = (label, style, onClick, extra) =>
        h('button', {
          type: 'button',
          style: disabled ? Object.assign({}, style, styles.disabled) : style,
          disabled,
          onClick,
          ...(extra ?? {})
        }, label);

      const presetItems = [1, 2, 3, 4, 5].map((n) => h('option', { key: n, value: String(n) }, t(`preset.${n}`)));
      // 固定常用选项；若当前覆盖值不在列表里（例如 Agent 设置了 3），补一个选项避免下拉框显示空白
      const workerOptions = Array.from(new Set([2, 4, 6, 8, 12, ...(workerValue == null ? [] : [workerValue])]))
        .sort((a, b) => a - b);

      return h('section', { 'aria-label': t('view.tab'), style: styles.page, 'data-dsh-mri-workbench': 'active' },
        h('header', { style: styles.header },
          onBack ? h('div', { style: styles.row },
            h('button', { type: 'button', style: styles.button, onClick: onBack, 'data-action': 'back-to-start' }, t('view.backToStart'))
          ) : null,
          h('div', { style: styles.headerTop },
            h('div', null,
              h('h2', { style: styles.title }, t('view.title')),
              h('p', { style: styles.subtitle }, t('view.subtitle'))
            ),
            h('button', {
              type: 'button',
              style: disabled ? Object.assign({}, styles.primary, styles.disabled) : styles.primary,
              disabled,
              title: t('view.openDesktopTitle'),
              onClick: () => exec('/mri open'),
              'data-action': 'open-desktop'
            }, t('view.openDesktop'))
          ),
          h('p', { style: styles.note }, t('view.note'))
        ),
        h('div', { style: styles.grid },
          h('section', { style: styles.card, 'aria-label': t('data.title') },
            h('h3', { style: styles.cardTitle }, t('data.title')),
            h('p', { style: styles.hint }, t('data.hint')),
            h('div', { style: styles.row },
              h('label', { style: styles.label, htmlFor: 'mrw-root' }, t('data.root')),
              h('input', {
                id: 'mrw-root', style: styles.input, value: root,
                placeholder: t('data.rootPlaceholder'),
                onChange: (e) => { setRoot(e.target.value); setBrowseError(''); }
              }),
              h('button', {
                type: 'button',
                style: disabled || browseBusy ? Object.assign({}, styles.button, styles.disabled) : styles.button,
                disabled: disabled || browseBusy,
                title: t('data.browseTitle'),
                onClick: browseRoot,
                'data-action': 'browse-root'
              }, browseBusy ? t('data.browseBusy') : t('data.browse'))
            ),
            browseError ? h('p', { style: styles.error, role: 'alert', 'data-role': 'browse-error' }, browseError) : null,
            h('div', { style: styles.row },
              h('label', { style: styles.label, htmlFor: 'mrw-depth' }, t('data.depth')),
              h('input', {
                id: 'mrw-depth', style: styles.input, value: depth, inputMode: 'numeric',
                onChange: (e) => setDepth(e.target.value)
              }),
              btn(t('data.scan'), styles.primary, () => {
                const line = `/mri scan "${root.trim()}" ${String(depth || '6').trim()}`;
                exec(line);
              }, { 'data-action': 'scan' })
            ),
            h('div', { style: styles.row },
              btn(t('run.env'), styles.button, () => exec('/mri env'), { 'data-action': 'env' })
            )
          ),
          h('section', { style: styles.card, 'aria-label': t('prep.title') },
            h('h3', { style: styles.cardTitle }, t('prep.title')),
            h('p', { style: styles.hint }, t('prep.hint')),
            h('div', { style: styles.row },
              h('label', { style: styles.label, htmlFor: 'mrw-preset' }, t('prep.preset')),
              h('select', {
                id: 'mrw-preset', style: styles.select, value: preset,
                onChange: (e) => setPreset(e.target.value)
              }, presetItems)
            ),
            h('div', { style: styles.row },
              h('label', { style: styles.label, htmlFor: 'mrw-workers' }, t('prep.workers')),
              h('select', {
                id: 'mrw-workers', style: styles.select,
                value: workerValue == null ? 'unset' : String(workerValue),
                onChange: (e) => applyWorker(e.target.value),
                disabled: workerBusy || disabled,
                'data-action': 'worker-select'
              },
                h('option', { value: 'unset' }, t('prep.workersUnset')),
                workerOptions.map((n) => h('option', { key: n, value: String(n) }, `${n} worker`))
              )
            ),
            h('p', { style: styles.hint, 'data-role': 'worker-hint' }, t('prep.workersHint')),
            h('div', { style: styles.row },
              h('label', { style: styles.label, htmlFor: 'mrw-t1crop' }, t('prep.t1Crop')),
              h('select', {
                id: 'mrw-t1crop', style: styles.select,
                value: t1CropValue,
                onChange: (e) => applyT1Crop(e.target.value),
                disabled: t1CropBusy || disabled,
                title: t('prep.t1CropHint'),
                'data-action': 't1crop-select'
              },
                h('option', { value: 'auto' }, t('prep.t1CropAuto')),
                h('option', { value: 'old_dcm2nii' }, t('prep.t1CropOldDcm2nii')),
                h('option', { value: 'no_crop' }, t('prep.t1CropNoCrop'))
              )
            ),
            h('p', { style: styles.hint, 'data-role': 't1crop-hint' }, t('prep.t1CropHint')),
            h('div', { style: styles.row },
              btn(t('prep.editParams'), styles.primary, openParams, { 'data-action': 'params-dialog', disabled: schemaBusy }),
              btn(t('prep.prepare'), styles.primary, () => exec(`/mri prepare ${preset}`), { 'data-action': 'prepare' })
            ),
            h('p', { style: styles.hint },
              `${t('prep.status')}：${overrideCount} ${t('params.items')}${schemaBusy ? ` · ${t('params.loading')}` : ''}`),
            btn(t('prep.advancedJson'), styles.button, () => setShowJson((v) => !v), { 'data-action': 'toggle-json' }),
            showJson ? h('div', { style: { marginTop: 8 } },
              h('textarea', {
                id: 'mrw-overrides',
                style: styles.textarea,
                value: overridesText,
                spellCheck: false,
                placeholder: t('prep.overridesPlaceholder'),
                onChange: (e) => setOverridesText(e.target.value)
              }),
              h('p', { style: styles.hint }, t('prep.overridesHint')),
              h('div', { style: styles.row },
                btn(t('prep.applyOverrides'), styles.button, applyOverrides, { 'data-action': 'overrides-set' }),
                btn(t('prep.clearOverrides'), styles.button, clearOverrides, { 'data-action': 'overrides-clear' }),
                btn(t('prep.params'), styles.button, () => exec('/mri params'), { 'data-action': 'params' })
              )
            ) : null
          ),
          h('section', { style: styles.card, 'aria-label': t('run.title') },
            h('h3', { style: styles.cardTitle }, t('run.title')),
            h('p', { style: styles.hint }, t('run.hint')),
            h('div', { style: styles.row },
              btn(t('run.start'), styles.primary, () => exec('/mri run'), { 'data-action': 'run' }),
              btn(t('run.status'), styles.button, () => exec('/mri status'), { 'data-action': 'status' }),
              btn(t('run.cancel'), styles.danger, () => exec('/mri cancel'), { 'data-action': 'cancel' }),
              btn(t('run.open'), styles.button, () => exec('/mri open'), { 'data-action': 'open' })
            )
          ),
          h('section', { style: styles.card, 'aria-label': t('qc.title') },
            h('h3', { style: styles.cardTitle }, t('qc.title')),
            h('p', { style: styles.hint }, t('qc.hint')),
            h('div', { style: styles.row },
              btn(t('qc.refresh'), styles.primary, () => exec('/mri qcstatus'), { 'data-action': 'qc-status' }),
              btn(t('qc.state'), styles.button, () => exec('/mri qcstate'), { 'data-action': 'qc-state', title: t('qc.stateTitle') }),
              btn(t('qc.open'), styles.button, () => exec('/mri qc'), { 'data-action': 'qc-open' })
            )
          )
        ),
        h('section', { style: styles.resultsCard, 'aria-label': t('res.title'), 'data-action': 'results-card' },
          h('h3', { style: styles.cardTitle }, t('res.title')),
          h('p', { style: styles.hint }, t('res.hint')),
          h('div', { style: styles.row },
            h('label', { style: styles.label, htmlFor: 'mrw-fd-threshold' }, t('res.threshold')),
            h('select', {
              id: 'mrw-fd-threshold', style: styles.select, value: resultsThreshold,
              onChange: (e) => changeResultsThreshold(e.target.value),
              'data-action': 'fd-threshold'
            }, ['0.2', '0.5', '1'].map((v) => h('option', { key: v, value: v }, `${v} mm`))),
            btn(results ? t('res.refresh') : t('res.load'), styles.primary, () => loadResults(), { 'data-action': 'results-load', disabled: resultsBusy })
          ),
          resultsBusy ? h('p', { style: styles.busy, 'data-role': 'results-busy' }, t('res.loading')) : null,
          resultsError ? h('p', { style: styles.error, role: 'alert' }, `${t('res.error')}${resultsError}`) : null,
          results ? renderResultsBody() : h('p', { style: styles.hint, 'data-role': 'results-empty' }, t('res.empty'))
        ),
        h('section', { style: styles.outCard, 'aria-label': t('out.title') },
          h('h3', { style: styles.cardTitle }, t('out.title')),
          h('pre', { style: styles.pre, 'data-role': 'output' }, output ? renderOutputText(output) : t('out.empty')),
          busy ? h('p', { style: styles.busy, role: 'status' }, `${t('out.busy')} ${busy}`) : null,
          error ? h('p', { style: styles.error, role: 'alert' }, `${t('out.error')}${error}`) : null
        ),
        paramsOpen && schema
          ? h(ParameterDialog, {
            key: 'mrw-param-dialog',
            t,
            schema,
            applyBusy: !!busy,
            onClose: () => setParamsOpen(false),
            onApply: applyDialogOverrides
          })
          : null
      );
    }

    return {
      inject: ['slots', 'locale', 'remote', 'remote.commands', 'layout'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register('mriWorkbench', {
          zh: flatten(dictionaries.zh),
          en: flatten(dictionaries.en)
        }));
        const t = ctx.locale.bind('mriWorkbench');
        ctx.slots.inject('conversation.hero.options', () => ctx.slots.register({
          name: 'conversation.hero.options',
          id: 'mri-workbench.open',
          order: 35
        }, () => h('button', {
          type: 'button',
          style: styles.button,
          onClick: () => ctx.layout.selectPanel('mri-workbench'),
          'data-action': 'open-workbench'
        }, t('view.openWorkbench'))));
        ctx.slots.inject('main', () => ctx.slots.register({
          name: 'main',
          key: 'mri-workbench'
        }, ({ useSessions }) => {
          const sessionId = useSessions((s) => Object.values(s.byId).find((row) => (row.retainedBy.mainView ?? 0) > 0)?.id);
          const onBack = () => ctx.layout.selectPanel(null);
          return sessionId
            ? h(WorkbenchView, { key: sessionId, t, ctx, sessionId, onBack })
            : h('section', { style: styles.page },
              h('button', { type: 'button', style: styles.button, onClick: onBack, 'data-action': 'back-to-start' }, t('view.backToStart')),
              h('p', { style: styles.subtitle }, t('view.noSession'))
            );
        }));
        ctx.slots.inject('conversation.view', () => ctx.slots.register({
          name: 'conversation.view',
          id: 'mri-workbench',
          order: 35,
          label: () => t('view.tab')
        }, (props) => h(WorkbenchView, Object.assign({}, props, { t, ctx }))));
      }
    };
  }
});
