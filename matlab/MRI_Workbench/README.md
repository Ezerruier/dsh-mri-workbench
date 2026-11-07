# MRI 静息态分析工作台（MATLAB + DPABI/DPARSF）

面向静息态 fMRI 预处理的 GUI 工作台：**自动搜索索引数据目录、全中文参数界面、每个参数都有鼠标悬停解释、一键后台调用 DPABI 官方 DPARSFA 引擎运行**，并可给原生 DPABI 界面动态汉化。工作台不修改 DPABI 安装文件。

## 功能特性（对应需求）

1. **后台代码直接启动 DPABI 功能**：不依赖原生 GUI，`mrw.CfgBuilder` 生成 DPARSFA 官方 `Cfg` 结构，`mrw.Runner` 在独立 MATLAB 进程中调用官方 `DPARSFA_run(Cfg,[],[],0)`，界面不冻结、可取消。
2. **中文界面 + 悬停解释**：98 个 DPARSFA/工作台参数全部中文标签、分组展示，鼠标悬停即显示「作用 / 默认值 / 推荐 / 出处」；另有 143 条中英文术语库可检索。原生 DPABI/DPARSF 界面也可一键汉化并附加悬停解释（`mrw.NativePatch`，不改安装文件）。
3. **DPARSFA 预处理界面与功能**：基础设置、时间层与头动、结构像处理、标准化与平滑、回归与滤波、指标计算（ALFF/fALFF、ReHo、DC、FC/ROI、VMHC、Scrubbing）等完整参数面板，五种预设一键套用（含「空白（仅补步骤/续跑）」）；运行前检查会检测已处理阶段目录、rp 文件冲突与续跑依赖。
4. **工作目录自动搜索索引**：选择数据根目录后自动识别 DPARSF（FunRaw/T1Raw/S2_FunRaw）、BIDS、通用 NIfTI、DICOM 布局，自动提取受试者、功能/结构像目录、TR、时间点、层数，一键填入预处理参数——替代原生 DPARSFA 反复手动指定目录的流程。
5. **UI 优化**：深色标题栏 + 工作流导航 + 卡片式参数分组 + 实时日志/进度 + 运行前检查清单 + 术语库检索。
6. **可缩放人工 QC（参考 DPARSF）**：T1 原始像、功能平均像、标准化检查（wFun/wT1/wGM 叠加 DPABI MNI 边缘轮廓）三类人工检查；鼠标滚轮/拖拽/按钮缩放平移、切片滚动、窗宽窗位；按 DPARSF 规则 1–5 分 + 评语，写入 **DPARSF 兼容的 `QC/RawT1ImgQC.tsv`、`RawFunImgQC.tsv`、`NormalizationQC.tsv`**；支持评分阈值筛选与导出通过名单。

## 目录结构

```
MRI_Workbench/
  StartWorkbench.m          启动入口
  +mrw/                     工作台代码（MATLAB package）
    WorkbenchApp.m          主界面（6 个页面）
    DataPanel.m             ① 数据索引（自动扫描）
    PreprocessPanel.m       ② 预处理参数面板（中文 + 悬停解释）
    RunPanel.m              ③ 运行与日志
    GlossaryPanel.m         ④ 术语库
    SettingsPanel.m         ⑤ 设置与帮助
    QcModel.m               ⑥ 人工 QC 数据模型（图像/评分/阈值/头动）
    QcPanel.m               ⑥ 人工 QC 面板（可缩放查看 + 1–5 分评分）
    QcViewer.m              独立人工 QC 窗口（可从命令/DSH 启动）
    CfgSchema.m             Cfg 字段元数据（UI 数据源）
    CfgBuilder.m            配置构建/预设/运行前校验/存取
    Runner.m               独立进程后台运行管理器
    headlessRunner.m        子进程内执行 DPARSFA_run 的脚本
    ScanEngine.m            数据目录自动扫描/索引
    NiftiHeader.m           NIfTI 头解析
    T1Compat.m              T1 裁剪兼容（旧版 dcm2nii 真实裁剪 / 免裁剪直通）
    Dpabi.m                 DPABI/SPM 定位、路径、原生界面启动
    NativePatch.m / NativeLaunch.m   原生界面汉化
    Glossary.m / UiKit.m / Settings.m
  resources/glossary.tsv    术语库（143 条：98 参数 + 45 术语）
  resources/native_labels.tsv 原生界面控件中文标签
  docs/                     设计文档、DPABI 引擎研究、使用手册
  tests/                    MATLAB 测试脚本
  runs/                     每次运行的 cfg.mat / run.log / status.json
```

## 快速开始

1. 确认已安装 **MATLAB（R2020b 及以上，推荐 R2026a）**、**SPM12**、**DPABI（含 DPARSFA_run.m）**；
2. 在 MATLAB 中把本目录加入路径并启动：
   ```matlab
   cd('<仓库>\matlab\MRI_Workbench')
   StartWorkbench
   ```
   若 DPABI/SPM12 未在 MATLAB 路径中，请到「⑤ 设置与帮助 → 路径设置」指定根目录后点「保存路径并重新检测环境」。
3. ①「数据索引」→ 选择数据根目录 →「开始自动扫描」→ 检查结果 →「应用到预处理参数」；
4. ②「预处理参数」→ 选择预设（如“经典静息态（DARTEL 全流程）”），按需调整（悬停可看解释）；
5. ③「运行与日志」→「运行前检查」→ 通过后「开始预处理」；日志实时滚动，可取消；结果写入工作目录。
6. ⑥「人工QC」→ 检查 T1/功能平均像/标准化图像（可缩放、可叠加 MNI 轮廓）→ 1–5 分 + 评语 → 导出通过名单（详见 [人工QC使用说明](docs/人工QC使用说明.md)）。

数据目录规范（详见 [docs/使用手册.md](docs/使用手册.md)）：

```
<工作目录>/
  FunRaw/<受试者ID>/    功能像（DICOM 或 NIfTI）
  T1Raw/<受试者ID>/     T1 结构像（DICOM；若已在 T1Img 放 NIfTI 请勾选“结构像裁剪”）
  S2_FunRaw/<受试者ID>/ 第 2 个功能 session（可选）
  BIDS/                 BIDS 数据集根目录（预处理时勾选“BIDS 数据转 DPARSF 结构”）
```

NIfTI 已转换数据可用 `FunImg/<ID>/` + `T1Img/<ID>/`，起始目录名设为 `FunImg`、关闭 DICOM 转换。

## 文档

- [使用手册](docs/使用手册.md)：数据准备、各参数含义、预设、运行与排错
- [人工QC使用说明](docs/人工QC使用说明.md)：可缩放查看、DPARSF 兼容评分、阈值与名单
- [DSH 集成说明](docs/DSH集成说明.md)：在 DeepSeek Harness 内运行工作台（`dsh-mri-workbench` 插件：页面 + Agent 工具 + 后台 Job 实时日志）
- [验证报告](docs/验证报告.md)：全模块测试 6/6、端到端验收、截图与已知限制
- [DPABI 引擎研究](docs/DPARSFA_ENGINE.md)：DPARSFA 源码行为、Cfg 全字段、日志、校验与坑
- [协作接口契约](docs/CONTRACT.md)
- [术语库来源](docs/GLOSSARY_SOURCES.md)
- [原生界面汉化说明](docs/NATIVE_PATCH.md)

## 运行环境

- 已在本机验证：MATLAB R2026a + DPABI V10.0_260625 + SPM12（`D:\Software\DPABI`、`D:\Software\spm12`），Windows 10/11。
- DPABI/SPM 的安装方式与官方一致；本工作台只读 DPABI 目录。

## 安全与说明

- 所有数据留在本机；预处理计算全部由 DPABI 官方引擎完成。
- 后台运行不弹任何交互对话框；原生界面中的交互功能（如交互重定向）请使用「打开原生 DPARSF 高级版」。
- 若论文使用 DPABI，请按官方要求引用：Yan, C.G., Wang, X.D., Zuo, X.N., Zang, Y.F., 2016. DPABI: Data Processing & Analysis for (Resting-State) Brain Imaging. Neuroinformatics 14, 339-351.
