# 静息态 MRI 分析工作台 — 协作接口契约（CONTRACT）

版本: v1（Lead 维护，任何人修改需先通知 Lead）

## 0. 环境事实（已核实）

- 工作目录（项目根）: `matlab/MRI_Workbench`（仓库内）
  - 该目录将被 `StartWorkbench.m` 加入 MATLAB 路径，包目录 `+mrw` 位于其下。
- MATLAB: R2026a, `D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe`（可用 `-batch` 无界面运行）。
- DPABI: `D:\Software\DPABI`（版本 Release V10.0_260625，入口 `dpabi.m`，预处理引擎 `DPARSF\DPARSFA_run.m`）。
- SPM12: `D:\Software\spm12`。已保存在用户 MATLAB 路径中（`which DPABI.m`、`which spm.m` 可解析）。
- 工具箱: Image Processing, Parallel Computing (PCT), Signal Processing, Statistics 均已安装。
- 无真实 MRI 被试数据；测试请用**运行时生成**的小型合成数据集（不要提交大二进制）。
- 参考产物（只读）: 开发期临时产物（未随仓库发布），含 DPARSF 各模板配置 JSON、DPARSFA.fig 控件 dump。
  重要文件: `tmpl_Template_Blank_Cfg.pretty.json`（Cfg 基线）、`fig_uicontrols.pretty.json`。

## 1. 代码目录约定

```
MRI_Workbench/
  StartWorkbench.m              启动入口（Lead）
  +mrw/
    CfgSchema.m                 Cfg 字段元数据（Lead）
    CfgBuilder.m                UI 状态 -> DPARSFA Cfg 结构（Lead）
    Glossary.m                  术语库读取/检索（Lead）
    ScanEngine.m                数据目录自动扫描/索引（T3）
    NiftiHeader.m               NIfTI 头信息解析（T3）
    T1Compat.m                  T1 裁剪兼容（旧版 dcm2nii 真实裁剪 / 免裁剪直通）（Lead）
    Runner.m                    后台运行 DPARSFA_run 的管理器（Lead）
    headlessRunner.m            独立 MATLAB 进程中的运行脚本（Lead）
    NativePatch.m               原生 DPABI 界面汉化/悬停解释（T4）
    NativeLaunch.m              从代码启动原生 DPABI/DPARSFA（T4）
    Dpabi.m                     DPABI/SPM 定位与路径（Lead）
    WorkbenchApp.m              主界面（Lead）
    PreprocessPanel.m           预处理参数面板组件（T5）
  resources/
    glossary.tsv                术语库（T2）
    native_labels.tsv           原生界面控件中文标签（T4）
  docs/                         各模块文档
  tests/                        MATLAB 测试脚本（允许生成临时合成数据）
  runs/                         运行输出（cfg.mat、log.txt、status.json；gitignore）
  logs/                         工作台日志（gitignore）
```

**写入隔离**：只写自己任务声明的文件；共享文件（如 `glossary.tsv`）只有 owner 可写。Lead 负责最终整合。

## 2. 接口

### 2.1 `mrw.NiftiHeader.read(filePath)` (T3)

返回 struct（字段必须齐全，缺失用 NaN/''）:

| 字段 | 类型 | 说明 |
|---|---|---|
| `File` | char | 绝对路径 |
| `Format` | char | `'nii'` / `'nii.gz'` / `'hdr/img'` |
| `Dim` | 1x8 double | NIfTI dim |
| `VoxSize` | 1x3 double | 体素大小 mm |
| `TR` | double | pixdim(4)，单位秒；≤0/NaN 表示未知 |
| `TimePoints` | double | dim(4)（4D 时）或 1 |
| `SliceNumber` | double | dim(3) |
| `DatatypeName` | char | 如 `'float32'` |
| `ReadOK` | logical | 解析是否成功 |
| `Message` | char | 失败原因（中文） |

要求：支持 `.nii`、`.nii.gz`（gunzip 到 tempdir 后读并清理）、`.hdr/.img`；NIfTI-1 与 NIfTI-2；大小端；不依赖 SPM/IPT。只读文件头，不加载全部数据。

### 2.2 `idx = mrw.ScanEngine.scan(rootDir, opts)` (T3)

`opts`（struct，可省略字段）: `MaxDepth` (6)、`ProgressFcn`（@(msg)）、`IncludeDICOM` (true)、`IncludeBIDS` (true)、`IncludeNIfTI` (true)。

返回 `idx` struct，字段固定：

```
idx.Root              char   绝对路径
idx.Layout            char   'DPARSF'|'BIDS'|'NIFTI'|'DICOM'|'MIXED'|'UNKNOWN'
idx.LayoutName        char   中文描述，如 'DPARSF 标准目录（FunRaw/AnatRaw）'
idx.Subjects          struct array，字段:
    ID                char   受试者编号
    Dir               char   受试者 session1 功能像目录（如 <wd>/FunRaw/Sub01）
    FunDirs           cell   1xS，各 session 的受试者功能像目录（如 <wd>/FunRaw/Sub01、<wd>/S2_FunRaw/Sub01）
    AnatDir           char   受试者结构像目录（如 <wd>/T1Raw/Sub01；无则 ''）
    FunType           char   'DICOM'|'NIfTI'|'BIDS'|'MIXED'|''
    AnatType          char   'DICOM'|'NIfTI'|'BIDS'|'MIXED'|''
    FunFileCount      double 功能像文件数（DICOM 为张数）
    AnatFileCount     double 结构像文件数
    TimePoints        double NaN=未知
    TR                double NaN=未知
    SliceNumber       double NaN=未知
    VoxelSize         1x3    未知为 [NaN NaN NaN]
    Sessions          double 功能像 session 数
    HasAnat           logical
    Status            char   'ok'|'warn'|'error'
    Messages          cell   中文提示（可为空）
idx.Detected          struct: WorkingDir, StartingDirName('FunRaw'), FunctionalSessionNumber,
                              TR, TimePoints, SliceNumber, SubjectIDs(cellstr)
idx.Warnings          cell
idx.Errors            cell
idx.Stats             struct: Elapsed, DirsScanned, FilesScanned
```

识别规则（至少覆盖；已按 DPABI 引擎源码 DPARSFA_run.m:250-340 校正）：
- DPARSF：`<WorkingDir>/FunRaw/<SubjID>/*`、`<WorkingDir>/S2_FunRaw/<SubjID>/*`、`<WorkingDir>/T1Raw/<SubjID>/*`
  （模态目录在外层、受试者目录在里层；结构像兼容 `AnatRaw`/`T1Img`；已处理起始目录如 `FunImg/<SubjID>` 也可识别）。
- 根目录本身就是 DPARSF 功能像目录（`FunRaw`、`FunImg*`，如直接扫描 `<WorkingDir>\FunImgARB`）时按「根目录 = 模态/阶段目录」解释：
  `Detected.WorkingDir` 自动取其上级目录、`StartingDirName` 取该目录名（去掉 `S2_` 前缀；如 `FunImgARB`），受试者取该目录下含图像文件的子目录，
  并从子目录 NIfTI 头读取 TR/时间点/层数；`LayoutName` 为 `DPARSF 已处理阶段目录（<name>，续跑模式）`（`FunRaw` 时为 `DPARSF 功能像原始目录（FunRaw）`），
  结构像自动在上级目录的 `T1Raw`/`T1Img`/`AnatRaw/<SubjID>` 查找。若根目录名恰好像模态目录、但其子目录本身是 `FunRaw`/`T1Raw` 等模态目录，
  仍按“工作目录 + dirFirst”处理（不触发本规则）。
- BIDS：`<WorkingDir>/BIDS/sub-*/[ses-*/]func/*_bold.nii*`、`anat/*_T1w.nii*`，从 JSON sidecar 读 RepetitionTime；
  Detected.WorkingDir = 含 BIDS 子目录的那一层，SubjectID = sub-*，并加 `IsBIDS=true` 字段（追加在 Detected 末尾，不得删改已有字段）。
- NIfTI 通用：目录中 4D `.nii(.gz)` 视为功能像，3D 且像 T1 的视为结构像；尽量推断 WorkingDir 与受试者，并在 warning 中提示需整理成 `FunRaw/<SubjID>` 结构。
- DICOM：`FunRaw/<SubjID>` 等命名优先；否则统计每目录 `.dcm/.ima/.IMA` 数量，最多者视为功能像序列；用 `spm_dicom_headers`（若在路径）或 `dicominfo` 抽样读 TR/层数/时间点，失败则 NaN 并给 warning。
- `idx.Subjects.Dir` = 受试者 session1 功能像目录（如 `<wd>/FunRaw/Sub01`）；`FunDirs` = 各 session 受试者功能像目录；
  `AnatDir` = 受试者结构像目录（如 `<wd>/T1Raw/Sub01`）。
- Detected.WorkingDir/StartingDirName/FunctionalSessionNumber/SubjectIDs/TR/TimePoints/SliceNumber 直接可填入 Cfg。
- 性能：避免对 >5000 文件的目录逐个读头；抽样 + 计数；进度回调可选。
- 中文路径、`*.nii.gz`、大小写不敏感扩展名必须支持。

### 2.3 `mrw.Glossary`（T2 提供数据，Lead 实现读取）

数据文件 `resources/glossary.tsv`，UTF-8，首行表头，TAB 分隔，列：
`Key, EN, ZH, Tip, Category, Default, Advice, Source`
- `Key`: Cfg 字段路径（如 `SliceTiming.SliceOrder`）或 `term:<英文术语>`（如 `term:ReHo`）。
- `EN`: 英文术语；`ZH`: 中文名（术语库显示用）；`Tip`: 2–5 句中文概述（鼠标悬停显示，含作用/取值/建议/常见坑）；`Category`: 分类（数据整理/时间层/头动/结构像/标准化/平滑/回归/滤波/指标计算/术语/界面）。
- `Default`: 默认值说明；`Advice`: 推荐设置（可为空）；`Source`: 来源 URL 或 DPABI 文档出处（可为空）。
- 必须覆盖 `CfgSchema` 中每个 Key（Lead 提供清单）+ 至少 30 个通用术语（ReHo、ALFF、fALFF、mReHo、mALFF、VMHC、DC、FC、FD、scrubbing、DARTEL、unified segmentation、nuisance regression、global signal、CompCor、AAL、MNI 等）。

### 2.4 `mrw.NativePatch`（T4）

- `mrw.NativePatch.patchAll()`：查找已打开的 DPABI / DPARSF(classic) / DPARSFA 图窗，按 `resources/native_labels.tsv` 翻译可安全翻译的控件（text/panel/pushbutton/checkbox/radiobutton 的 String；popupmenu 仅改 TooltipString，不改 String 以防回调依赖字符串），并按术语库给所有控件设置中文 TooltipString。
- `mrw.NativePatch.unpatchAll()`：恢复英文。
- `mrw.NativeLaunch.openDPABI()` / `openDPARSFA(templateName)`：从代码打开原生界面；打开后自动启动 patch 监视器（timer，30 秒内发现新图窗即汉化）。
- 必须幂等、可逆、失败不影响原界面功能；不得修改 DPABI 安装文件。

### 2.5 `mrw.PreprocessPanel`（T5）

见任务 task-5 全文。接口：构造 `PreprocessPanel(parent, options)`（options: PresetNames/PresetSelectedFcn/RunRequestedFcn），
方法 `getState()/setState(st)/applyDetected(det)/reset()/refreshEnables()/highlightKey(key)`，
事件 `Changed`、`RequestSubjectEdit`。State 为与 Cfg 同构的嵌套 struct，字段集合由 `mrw.CfgSchema` 决定。
主 App 用 `mrw.CfgBuilder.build(panel.State, runOpts)` 生成最终 Cfg。

### 2.6 其他 Lead 负责的模块（供队友调用，不修改）

- `mrw.Dpabi`：`root()`、`spmRoot()`、`ensurePath()`、`status()`、`version()`、`templates()`、`blankTemplate()`、`launchDPABI()`、`launchDPARSFA(templateName)`。
- `mrw.CfgBuilder`：`defaultState()`、`presets()`、`build(state, runOpts)`、`validate(Cfg)`、`summary(Cfg)`、`saveCfg(Cfg,path)`、`loadCfg(path)`。
- `mrw.T1Compat`：T1 结构像裁剪兼容层（2026-11 新增）。背景：DPABI 的裁剪步骤改用 dcm2niix（只支持 DICOM），`T1Img` 只有 NIfTI `T1.nii` 时不会生成 `c*/co*`，无界面运行会在 `DPARSFA_run.m:1641` 附近的 questdlg 处失败。API：`normalizeMode/labelOf/planOf/oldDcm2niiExe/t1Needed/hasCroppedFile/t1Files/apply(Cfg,logFcn)`。对应 Cfg 字段 `T1CropCompat`（`auto|old_dcm2nii|no_crop`，默认 auto；属工作台字段，`headlessRunner` 在调用 `DPARSFA_run` 前执行兼容处理并删除该字段）。`old_dcm2nii` 用 DPABI 自带旧版 `dcm2nii.exe` 对 NIfTI T1 真实重定向+裁剪；`no_crop` 把未裁剪 T1 复制为 `c*` 直通文件（需人工 QC）。两种模式都会关闭 DPARSF 自带裁剪步骤。
- `mrw.Runner`：独立 MATLAB 进程后台执行 `DPARSFA_run`，日志/状态回调、取消。
- `mrw.UiKit` / `mrw.Glossary` / `mrw.CfgSchema`：见各文件头注释。

## 3. 验证要求

- 每个模块交付前必须用 `matlab.exe -batch` 跑通自己的测试脚本，并在回报中贴出关键输出。
- 不修改 `D:\Software\DPABI` 下任何文件。
- 不覆盖别人 write scope 的文件。
