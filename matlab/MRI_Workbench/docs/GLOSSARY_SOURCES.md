# 中文术语库（glossary.tsv）来源与校验说明

本文件说明 `resources/glossary.tsv` 的数据来源、生成方式、覆盖统计、校验方法与已知不确定条目。
生成者：glossary-writer（task-3）；写入范围仅 `resources/glossary.tsv` 与本文件，未改动任何代码。

## 1. 交付物与格式

| 项 | 内容 |
|---|---|
| 主文件 | `matlab/MRI_Workbench/resources/glossary.tsv`（UTF-8 无 BOM，LF 换行，TAB 分隔） |
| 表头 | `Key` `EN` `ZH` `Tip` `Category` `Default` `Advice` `Source`（8 列） |
| 数据行 | 142 行（Cfg 97 + 通用术语 45），单行单元格，单元格内无 TAB/换行 |
| 主键 | Cfg Key（与 `+mrw/CfgSchema.m` 完全一致，点号路径）或 `term:<英文>` |
| Tip | 2–5 句中文，按「作用 / 取值 / 影响或常见坑」组织，面向非 DPABI 专家型研究生 |
| Category | 数据整理 / 时间层与头动 / 结构像处理 / 标准化与平滑 / 回归与滤波 / 指标计算 / 术语 / 界面（与 `mrw.Glossary.categoryNames()` 精确一致，见第 7 节第 12 条） |
| Source | `DPARSFA_run.m:<行号>`、`DPARSF_run.m:<行号>`、DPABI 子函数行号或官方文档 URL；无对应来源时写 `DPABI 官方文档/术语常识` |

## 2. 生成流程（可复现）

1. 用正则从 `matlab/MRI_Workbench/+mrw/CfgSchema.m` 的 `R` 表格逐行提取 `Key / Group / ZH Label / EN`，共 **97** 个 Key。
   该步骤保证 **Key 一字不差、ZH 与 CfgSchema 中文 Label 完全一致、EN 与 CfgSchema 一致**（校验脚本第 5 项复查）。
2. 为每个 Key 人工撰写 `Tip / Default / Advice / Source`，并按 CfgSchema 的 Group 映射到 `Category`
   （与 `+mrw/Glossary.categoryNames()` 的 8 个名字逐一精确对应，保证 `GlossaryPanel` 的分类下拉能筛出数据）：
   - `基础设置`→数据整理；`时间层与头动`→时间层与头动；`结构像处理`→结构像处理；
   - `标准化与平滑`→标准化与平滑；`回归与滤波`→回归与滤波；`指标计算`→指标计算；
   - `高级与运行`→按字段归入界面（`IsAllowGUI`、`ParallelWorkersNumber`）、数据整理（`IsApplyDownloadedReorientMats`）、
     结构像处理（`SpecialMode`）；通用术语统一为 `术语`。
3. 追加 45 条通用术语行（`term:<英文>`，Category=术语）。
4. 生成时即做断言：Cfg Key 覆盖 100%、无重复 Key、每行 8 列、单元格无 TAB/CR/LF，再写入文件。
5. 用独立 PowerShell 校验脚本从**已写入的文件**重新读取并复核（结果见第 6 节）。

## 3. Cfg 字段来源（97 行）

### 3.1 rfmri 官方配置文档（字段含义主来源）

`Configurations for DPARSFA_run`，<http://rfmri.org/content/configurations-dparsfarun>

- 抓取方式：`Invoke-WebRequest -UseBasicParsing -Uri "http://rfmri.org/content/configurations-dparsfarun"`（HTTP 200，正文约 11.8k 字符），去 HTML 标签后逐字段核对注释。
- 该文档逐行给出 `Cfg.<字段>=<示例值> ; %英文说明`，是 `Tip` 中"取值/作用"的主要依据；`SliceTiming.SliceNumber` 的自动层序假设、`Covremove.HeadMotion` 1–4 与 11–14 模型、`Scrubbing.ScrubbingMethod` 五种方式、`CalFC.ROIDef` 五种定义形式等细节均取自该页原文。
- 该页覆盖了 97 个 Cfg Key 中的 93 个；未覆盖的 4 个（`IsExtractAALTC`、`ParallelWorkersNumber`、`IsBIDStoDPARSF`、`SpecialMode`）改用源码行号作 Source（见 3.2）。`IsAllowGUI` 在该页仅以文字提及（"Will be skipped if Cfg.IsAllowGUI set to 0"）而无独立赋值示例，Source 采用 `DPARSFA_run.m:7` 的函数头说明。

### 3.2 DPABI 源码（行号来源）

安装位置：`D:\Software\DPABI`（Release V10.0_260625，入口 `dpabi.m`；CONTRACT.md 第 0 节）。

- `DPABI\DPARSF\DPARSFA_run.m`：5127 行，是 97 个 Cfg 字段中 **89 条** 的 Source 行号出处。引用方式为「字段默认值处理行」或「字段实际使用行」，例如：
  - 删点执行 `DPARSFA_run.m:628`、自动层序假设 `:727`、层顺序/参考层写入 SPM job `:787-788`；
  - 掩膜 warp 触发条件 `:2579`、个体空间 WM/CSF 分割掩膜阈值 `:2544`/`:2563`；
  - 回归阶段 `:2489`、多项式趋势 `:2821`、头动模型 `:2826`、scrubbing 回归量 `:2854-2884`；
  - WM/CSF/全脑掩膜选择 `:2918-2941`（SPM 分支用 `Masks/WarpedMasks/<subj>_WhiteMask_09_...`、`CsfMask_07_...`、`BrainMask_05_...`；
    Segment 分支用 `Masks/SegmentationMasks/FunSpace_ThrdMask_*`）；
  - CompCor 实际 PC 数取 `Covremove.CSF.CompCorPCNum`：`:2907`（AfterRealign）与 `:3862`（AfterNormalize）；
  - ALFF/fALFF `:3989-4015`、ReHo `:4110-4145`、DC `:4162`、FC `:4421-4427`、ROI 提取 `:4437-4456`、
    VMHC `:4629`、CWAS `:4477-4478`、BET `:1528-1694`、AutoMask `:2082-2130`、SpecialMode `:2296/2306/3111`、并行 `:1709`；
  - 默认值兼容段 `:41-237`（`if ~isfield(...)` 分支）。
- `DPABI\DPARSF\DPARSF_run.m`：`IsRemoveFirstTimePoints` 的 Source（`:27` 仅做 basic→advanced 参数传递），
  以及 `IsNormalize` 与 `IsNeedT1CoregisterToFun / IsSegment / IsDARTEL` 的自动联动（`:40-52`，写入对应 Tip）。

### 3.3 DPABI 子函数（术语行与部分 Cfg 行的行为依据）

| 文件 | 用途 |
|---|---|
| `DPARSF\Subfunctions\y_alff_falff.m` | ALFF/fALFF 定义、频段、sqrt(2/N) 版本差异（行 2-5, 35-37, 144, 152-155） |
| `DPARSF\Subfunctions\y_reho.m` | ReHo/KCC、邻域 7/19/27（行 2-6, 38-40） |
| `DPARSF\Subfunctions\y_DegreeCentrality.m` | DC 加权和/二值化定义、r 阈值（行 3-8, 31-32） |
| `DPARSF\Subfunctions\y_FD_Jenkinson.m` | Jenkinson FD 相对/绝对 RMS（行 1-11） |
| `DPARSF\Subfunctions\y_Scrubbing.m` | 五种 scrubbing 方式（行 8-14） |
| `DPARSF\Subfunctions\y_VMHC.m` | VMHC 定义与文献（行 3-5） |
| `DPABI\Subfunctions\y_CompCor_PC.m` | CompCor PCA 前去趋势/方差归一化、PCNum（行 1-14） |
| `DPARSF\Subfunctions\y_RegressOutImgCovariates.m` | 协变量回归模型与 Add Mean Back（行 1-25） |
| `DPARSF\Subfunctions\y_Call_bet.m` | BET 在 Windows 用 MRIcroN 版 bet、Linux/Mac 用 FSL 或 Docker（行 1-41） |

### 3.4 DPABI 模板默认值（Default 列核对）

开发期临时产物（未随仓库发布）：`tmpl_Template_Blank_Cfg.pretty.json`（只读）以及 `tmpl_Template_*_Cfg.pretty.json` 全量模板。

- CfgSchema 默认值与 Blank 模板一致（如 `Filter.AHighPass_LowCutoff=0.01`、`Filter.ALowPass_HighCutoff=0.1`、
  `Covremove.PolynomialTrend=1`、`Covremove.HeadMotion=4`、`Scrubbing.ScrubbingMethod='cut'`、`Normalize.VoxSize=[3 3 3]`、
  `Smooth.FWHM=[4 4 4]`、`MaskFile='Default'`、`CalReHo.ClusterNVoxel=27`、`CalDegreeCentrality.rThreshold=0.25`）。
- 两个 Timing 字段在不同模板中取值不同（已实测 14 个模板）：
  - `Normalize.Timing` / `Smooth.Timing`：Blank 模板为 `OnResults`；`CalculateInMNISpace*`、`TaskfMRIPreprocessing`、
    `Monkey/RatProcessing` 为 `OnFunctionalData`；`V4_CalculateInMNISpace_Warp_DARTEL` 的 Smooth 为 `OnResults`。
    故 `Default` 列写作「OnFunctionalData（工作台默认；DPABI Blank 模板为 OnResults）」。
  - `Covremove.Timing`：Blank、DARTEL/UnifiedSegment 系列、ReHoDC 等为 `AfterRealign`；`CalculateInMNISpace_TraditionalOrder`、
    Task fMRI、Rat 模板为 `AfterNormalize`。Default 列按工作台默认 `AfterRealign`。
  - `Filter.Timing`：全部模板均为 `AfterNormalize`。

### 3.5 领域文献（仅用于通用术语行的出处标注）

以下文献用于术语行的定义溯源，均先与 DPABI 源码内注释核对过（`y_*.m` 头部的 Ref 行），未逐篇抓取原文：

- Zang et al., 2004, NeuroImage（ReHo）；Zang et al., 2007, NeuroImage（ALFF）；Zou et al., 2008（fALFF）；
- Zuo et al., 2010（VMHC）；Zuo et al., 2012, Cereb Cortex（Network Centrality）；Buckner et al., 2009（Cortical Hubs）；
- Behzadi et al., 2007（CompCor）；Power et al., 2012, NeuroImage 59:2142-2154（Power FD）；
- Jenkinson et al., 2002, NeuroImage（Jenkinson FD）；
- Ashburner, 2007, NeuroImage（DARTEL）；Ashburner & Friston, 2005, NeuroImage（Unified Segmentation）；
- SPM12 手册（Realign / Normalize / Smooth / Unified Segmentation）；
- BIDS 规范 <https://bids.neuroimaging.io>；FSL BET 文档。

## 4. 通用术语行（45 条）

Key 列表（`term:` 前缀）：

```
term:ReHo, term:ALFF, term:fALFF, term:mReHo, term:mALFF, term:KCC, term:VMHC,
term:Degree Centrality, term:Functional Connectivity, term:zFC, term:FD,
term:Power FD, term:Jenkinson FD, term:Scrubbing, term:Temporal Mask, term:DARTEL,
term:Unified Segmentation, term:Nuisance Regression, term:Global Signal, term:CompCor,
term:Slice Timing, term:Realign, term:Normalization, term:Smoothing, term:Detrend,
term:Band-pass Filter, term:ROI, term:AAL, term:MNI, term:BIDS, term:T1, term:TR,
term:Time Points, term:Voxel Size, term:FWHM, term:Bet, term:AutoMask, term:Reorient,
term:Affine Regularisation, term:Special Mode, term:QC, term:EPI Template,
term:Co-registration, term:GM/WM/CSF, term:Interpolation
```

说明：`term:` 行 `Default`/`Advice` 留空（术语无默认值概念，契约允许为空），Source 指向 DPABI 源码行或文献/官方文档。

## 5. 覆盖与分布统计

| 指标 | 数值 |
|---|---|
| 数据行数 | 142 |
| Cfg 行数 / CfgSchema Key 总数 | 97 / 97（覆盖率 **100%**） |
| 通用术语行数 | 45（要求 ≥35） |
| Tip 句数 | 全部 2–5 句（脚本检查 0 条越界） |
| Tip 字符数范围 | 72–261 |
| 文件大小 | 66,305 字节（UTF-8 无 BOM，LF） |
| 类别分布 | 回归与滤波 30、指标计算 26、结构像处理 11、数据整理 11、标准化与平滑 9、时间层与头动 8、界面 2、术语 45 |
| Cfg 行 Source 分布 | 源码行号 90 条（`DPARSFA_run.m` 89 + `DPARSF_run.m` 1）、官方文档 URL 7 条 |
| 术语行 Source 分布 | 引用 DPABI 源码/子函数行号 37 条（其中 3 条同时给出官方 URL）、仅官方文档/规范/SPM 手册 8 条 |

## 6. 自助校验（结果粘贴）

校验脚本逻辑（PowerShell；从文件重新读取，不复用生成时的内存数据）：

1. UTF-8 读取，记录字节数与是否 BOM；
2. 表头必须为 8 个指定列名；
3. 逐行 `-split "\t"`，列数必须为 8；统计单元格内 CR/LF；
4. Key 去重检查；`term:` 行与 Cfg 行分开计数；
5. 用正则 `^\s*'([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)',` 从 `+mrw\CfgSchema.m` 提取 R 表格第一列 Key，
   检查缺失/多余（term: 行不参与）；同时比对 ZH、EN 与 CfgSchema 是否完全一致；
6. Source 空值检查、通用术语数量 ≥35。

可复制的快速复核（Windows PowerShell，路径为仓库根）：

```powershell
$tsv    = '<仓库>\matlab\MRI_Workbench\resources\glossary.tsv'
$schema = '<仓库>\matlab\MRI_Workbench\+mrw\CfgSchema.m'
$lines  = [System.IO.File]::ReadAllLines($tsv, [System.Text.Encoding]::UTF8)
$lines.Count                                                    # 143
($lines | Where-Object { ($_ -split "`t").Count -ne 8 }).Count  # 0
$keys = $lines[1..($lines.Count-1)] | ForEach-Object { ($_ -split "`t")[0] }
$keys.Count; ($keys | Select-Object -Unique).Count               # 142 / 142
$schemaKeys = [regex]::Matches(
  [System.IO.File]::ReadAllText($schema, [System.Text.Encoding]::UTF8),
  "(?m)^\s*'([^']+)',\s*'[^']+',\s*'[^']+',\s*'[^']+',") |
  ForEach-Object { $_.Groups[1].Value }
($schemaKeys | Where-Object { $keys -notcontains $_ }).Count      # 0（无缺失 Cfg Key）
($keys | Where-Object { $_ -like 'term:*' }).Count                # 45
```

实际输出：

```
================ glossary.tsv 校验报告 ================
文件            : <仓库>\matlab\MRI_Workbench\resources\glossary.tsv
编码/大小       : UTF-8 (no BOM), 66305 字节
总行数(含表头)  : 143
数据行数        : 142
Cfg 行数        : 97
通用术语行数    : 45
CfgSchema Key   : 97 个；覆盖率 97/97
Key 重复        : 0
列数!=8 的行    : 0
单元格 CR/LF    : 0
Source 空行     : 0
ZH 不一致       : 0
EN 不一致       : 0
结果            : PASS（全部检查通过）
```

补充检查（另跑）：

- Tip 句数（按 。！？ 计数）：非 2–5 句的条目 **0** 条；最短 72 字（`Scrubbing.LaterPoints`），最长 261 字（`IsCWAS`）。
- 全文件 TAB 总数 1001 = 表头 7 + 142 数据行 × 7，无多余 TAB；ASCII 双引号 0 个、首尾空格 0 个、U+FFFD 0 个。
- 97 条 Cfg 行中 90 条的 Source 行号已回读 `DPARSFA_run.m`/`DPARSF_run.m` 对应行，确认该行确实包含对应字段
  （`Covremove.WM.Method` 指向 `:2887` 的注释行「Mask covariates CompCor methods」，为该块起始注释，属预期）。

## 7. 已知不确定 / 需 Lead 注意的条目

1. **`Normalize.Timing` / `Smooth.Timing` 默认值存在上下文差异**：CfgSchema 与 MNI 空间模板为 `OnFunctionalData`，
   DPABI Blank 模板为 `OnResults`。Default 列同时写明两者，UI 展示时建议以 CfgSchema 为准。
2. **`Covremove.HeadMotion` 选项范围**：CfgSchema 仅枚举 1–4（工作台下拉），但 DPABI 官方文档与源码还支持 11–14 的
   体素特异模型。术语库按工作台 1–4 解释，并在 Tip 中说明 11–14 存在，未虚构选项。
3. **`IsRemoveFirstTimePoints` 在 `DPARSFA_run.m` 中无直接引用**：实际删除由 `RemoveFirstTimePoints>0` 控制
   （`DPARSF_run.m:27` 仅传递参数）。Tip 已明确"开关只是界面意图"这一坑，Source 指向 `DPARSF_run.m:27`。
4. **`IsExtractAALTC` 无实际计算实现**：`DPARSFA_run.m:224-225` 只有默认值兼容；检索整个 DPABI 目录（含 .m/.p/.fig）仅此一处，
   推测由加密的 `DPARSFA.p` 界面逻辑处理。Tip 给出替代做法（`CalFC.ROIDef` + `IsExtractROISignals`），未断言其内部行为。
5. **`Covremove.WM.CompCorPCNum` 实际不生效**：`DPARSFA_run.m:2907,3862` 调用 `y_CompCor_PC` 时固定使用
   `Covremove.CSF.CompCorPCNum`；WM 与 CSF 同时 CompCor 时两掩膜合并做一次 PCA。已在两条 Tip 中标注，
   建议 UI 侧把两者联动或加提示，否则用户改 WM 的 PC 数不会生效。
6. **`Covremove.WM/CSF.MaskThreshold` 只对 Segment 掩膜生效**：SPM 分支使用预先阈值化的
   `WhiteMask_09` / `CsfMask_07` 模板掩膜，界面上的阈值数值不参与计算。Tip 已写明。
7. **`Scrubbing.Timing`、`Covremove.WholeBrain.IsBothWithWithoutGSR`、`CalFC.ROISelectedIndex`、`DPARSFVersion`**
   出现在 DPABI 模板/文档中，但未列入 CfgSchema，故本术语库未收录（严格按 CfgSchema 主键，不扩充）。
8. **未直接引用中文网络教程（CSDN / 52brain / 微信公众号）**：这类页面链接易失效且内容难以逐条核验，
   Source 统一用官方文档与源码行号；若后续需要中文出处，可在不改变现有条目的前提下补充。
9. **术语 Key 含空格与斜杠**（如 `term:Degree Centrality`、`term:GM/WM/CSF`）：这是按任务示例格式保留的，
   MATLAB 侧按普通字符串 Key 处理即可，不涉及文件系统路径。
10. **文献引用未逐篇联网核对**：均来自 DPABI 源码内参考文献注释与领域常识（见 3.5），属稳定经典文献；
    若要求 DOI 级引用，可在 Source 列追加 DOI，不影响当前悬停解释。
11. **CWAS 调用参数疑似错位（实验性功能）**：`DPARSFA_run.m:4474-4478` 调用 `y_CWAS` 只传 5 个参数，
    而 `y_CWAS.m:1` 的签名需要 6 个（第 6 个为 `iter`，在 `y_CWAS.m:130` 被使用）。按此版本源码，`iter` 未定义，
    该路径可能直接报错；`IsCWAS`/`CWAS.iter`/`CWAS.Regressors` 三条 Tip 已如实标注"启用前需小样本验证"，
    未臆测其可用性。CWAS 的实际算法为：逐体素构建被试间全脑 FC 模式距离矩阵 → `y_mdmr` 多变量距离矩阵回归 + 置换检验
    （`y_CWAS.m:112-133`，`y_mdmr` 为其内部子函数 `y_CWAS.m:165`）。
12. **Category 粒度与 CONTRACT.md 2.3 的差异（已按现有代码对齐）**：CONTRACT 2.3 列举的细粒度分类是
    「数据整理 / 时间层 / 头动 / 结构像 / 标准化 / 平滑 / 回归 / 滤波 / 指标计算 / 术语 / 界面」，
    但当前 `+mrw/Glossary.categoryNames()` 与 `GlossaryPanel.refresh()` 用 8 个 CfgSchema 分组名 + `术语`/`界面`
    做**精确字符串**筛选（`rows(strcmp({rows.Category}, cat))`）。若按细粒度写，分类下拉会全部筛出 0 条。
    因此本术语库的 Category 采用与代码一致的 8 个名字（细粒度信息仍体现在 Key 与 Tip 中）。
    若 Lead 希望改用细粒度分类，只需在 `GlossaryPanel` 加一层映射或修改 `categoryNames()`；
    数据可由构建脚本一键重新生成（脚本内保留「分组→分类」映射），无需逐条手改。
13. **9 组 EN 字段同名**（设计使然，非错误）：`Voxel Size`、`FD Type`、`FD Threshold`、`Previous Points`、`Later Points`、
    `Detrend`、`Degree Centrality`、`Scrubbing`、`Special Mode` 各出现 2 次（Cfg 字段与通用术语之间，或两组 Cfg 字段之间）。
    主键 Key 全局唯一，UI 按 Key 取解释不受影响；仅 `mrw.Glossary.load()` 的 `EN:` 别名索引会「后出现的覆盖前面的」
    （后出现的多为 `term:` 行或 `Scrubbing.*` 行）。若 Lead 想按 EN 做唯一索引，可改为「先到先得」或改用 `term:` 前缀区分。
