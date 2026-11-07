# 推荐预设（可直接生成可运行的 Cfg）

本文件给出三套预设。约定：**统一以 `Template_Blank.mat` 为基线再覆盖**，这样生成的 Cfg 天然包含模板全部顶层字段（58 个），不会踩 `isfield` 缺省逻辑的坑；生成后 `save(cfgFile,'Cfg')` 即可 `DPARSFA_run(cfgFile,'','',0)`。
若希望"不依赖 DPABI 自带模板"地自建 Cfg，字段全集见 `cfg_fields.tsv`（131 行，含类型/默认值/生效条件/坑）。

模板差异（哪个模板把哪些开关置 1）见 `templates_diff.tsv`。

---

## 预设 A：经典静息态预处理（DICOM 输入，统一分割标准化，含常用指标）

适用：常规静息态被试，T1 与功能像都是原始 DICOM；输出 FunImgARWSCF 及 Results 指标。

```matlab
% ---- 预设 A ----
dpabiRoot = 'D:\Software\DPABI';                 % 只用于拼 ROIDef 路径
workDir   = '<你的工作目录>';                      % 需存在 FunRaw/<subj>、T1Raw/<subj>
subj      = {'S01','S02'};                        % 与目录名一致
load(fullfile(dpabiRoot,'DPARSF','Jobmats','Template_Blank.mat'));   % 变量名必须是 Cfg

Cfg.WorkingDir     = workDir;
Cfg.DataProcessDir = workDir;
Cfg.SubjectID      = subj;

% 输入转换
Cfg.IsNeedConvertFunDCM2IMG = 1;      % FunRaw/<subj>/* -> FunImg/<subj>/*.nii
Cfg.IsNeedConvertT1DCM2IMG  = 1;      % T1Raw/<subj>/*  -> T1Img/<subj>/*
Cfg.IsNeedReorientCropT1Img = 1;      % T1Img -> co*（强烈建议：避免无 co* 时 headless 报错）
Cfg.IsBIDStoDPARSF          = 0;

% 时间信息：TimePoints=0 表示不校验；TR=0 表示从 NIfTI 头自动读取（要求 pixdim[4]>0）
Cfg.TimePoints = 0;
Cfg.TR         = 2;                   % 若不读头，务必显式填秒
Cfg.FunctionalSessionNumber = 1;

% 首点与切片时间（SliceNumber=0 时依赖 SliceOrderInfo.tsv / BIDS json，风险高，建议显式填）
Cfg.IsRemoveFirstTimePoints = 1;
Cfg.RemoveFirstTimePoints   = 10;
Cfg.IsSliceTiming           = 1;
Cfg.SliceTiming.SliceNumber      = 0;             % 0=从 NIfTI 头读层数
Cfg.SliceTiming.SliceOrder       = [];            % SliceNumber=0 时被忽略；>0 时必须等长
Cfg.SliceTiming.ReferenceSlice   = 0;             % 0 合法（第一层）

% 头动
Cfg.IsRealign                     = 1;
Cfg.IsCalVoxelSpecificHeadMotion  = 0;
Cfg.IsNeedReorientFunImgInteractively = 0;        % 无 GUI 必须为 0
Cfg.IsNeedReorientT1ImgInteractively  = 0;
Cfg.IsNeedReorientInteractivelyAfterCoreg = 0;

% 结构像链：T1->Fun coreg + 统一分割（SPM12 new segment, IsSegment=2）
Cfg.IsNeedT1CoregisterToFun = 1;
Cfg.IsSegment               = 2;
Cfg.Segment.AffineRegularisationInSegmentation = 'mni';   % 东亚脑可改 'eastern'
Cfg.IsDARTEL                = 0;
Cfg.IsBet                   = 1;                 % 可选；若不需要可置 0
Cfg.IsAutoMask              = 0;

% 标准化 / 平滑（在功能像阶段做，保证指标也在 MNI 空间）
Cfg.IsNormalize      = 2;                         % 2=用分割信息 seg_sn.mat
Cfg.Normalize.Timing = 'OnFunctionalData';
Cfg.Normalize.BoundingBox = [-90 -126 -72; 90 90 108];
Cfg.Normalize.VoxSize     = [3 3 3];
Cfg.IsSmooth      = 1;
Cfg.Smooth.Timing = 'OnFunctionalData';
Cfg.Smooth.FWHM   = [4 4 4];

% 回归 / 滤波（都在标准化之后）
Cfg.IsCovremove      = 1;
Cfg.Covremove.Timing = 'AfterNormalize';
Cfg.Covremove.PolynomialTrend = 1;
Cfg.Covremove.HeadMotion      = 4;                % Friston 24
Cfg.Covremove.WM.IsRemove = 1;  Cfg.Covremove.WM.Mask = 'SPM';  Cfg.Covremove.WM.Method  = 'Mean';
Cfg.Covremove.CSF.IsRemove = 1; Cfg.Covremove.CSF.Mask = 'SPM'; Cfg.Covremove.CSF.Method = 'Mean';
Cfg.Covremove.WholeBrain.IsRemove = 0;            % 不做 GSR
Cfg.Covremove.IsAddMeanBack = 0;
Cfg.IsFilter      = 1;
Cfg.Filter.Timing = 'AfterNormalize';
Cfg.Filter.ALowPass_HighCutoff = 0.1;
Cfg.Filter.AHighPass_LowCutoff = 0.01;
Cfg.Filter.AAddMeanBack = 'Yes';

% 掩膜：默认 DPABI/Templates/BrainMask_05_91x109x91
Cfg.MaskFile = 'Default';
Cfg.IsWarpMasksIntoIndividualSpace = 0;

% 指标计算
Cfg.IsDetrend = 0;
Cfg.IsCalALFF = 1;
Cfg.CalALFF.AHighPass_LowCutoff = 0.01;
Cfg.CalALFF.ALowPass_HighCutoff = 0.1;
Cfg.IsCalReHo = 1;
Cfg.CalReHo.ClusterNVoxel = 27;
Cfg.CalReHo.SmoothReHo    = 0;
Cfg.IsCalDegreeCentrality = 1;
Cfg.CalDegreeCentrality.rThreshold = 0.25;
Cfg.IsCalFC = 1;
Cfg.IsExtractROISignals = 1;
Cfg.CalFC.ROIDef = {fullfile(dpabiRoot,'Templates','aal.nii')};
Cfg.CalFC.IsMultipleLabel = 1;
Cfg.CalFC.ROISelectedIndex = {};
Cfg.IsDefineROIInteractively = 0;
Cfg.IsCalVMHC = 0;  Cfg.IsNormalizeToSymmetricGroupT1Mean = 0;  Cfg.IsSmoothBeforeVMHC = 0;
Cfg.IsCWAS = 0;

Cfg.IsAllowGUI = 0;      % 数值 0，不要传字符串
Cfg.ParallelWorkersNumber = 0;

save('<你的工作目录>\cfg.mat','Cfg');
DPARSFA_run('<你的工作目录>\cfg.mat','','',0);
```

关键目录后缀顺序（本预设）：`FunRaw → FunImg → FunImgA → FunImgAR → FunImgARW → FunImgARWS → FunImgARWSC → FunImgARWSCF`，指标在 `Results/*_FunImgARWSC(F)`，最后结果标准化/平滑到 `ResultsW`/`ResultsWS`。
（-A 切片、-R realign、-W 标准化、-S 平滑、-C 回归、-F 滤波）

---

## 预设 B：仅功能像预处理（DARTEL 统一分割链，不做指标计算）

适用：只想快速得到标准空间 4D 数据，指标留到 DPABI 统计模块再做。

```matlab
% ---- 预设 B ----
load(fullfile('D:\Software\DPABI','DPARSF','Jobmats','Template_Blank.mat'));
Cfg.WorkingDir = '<work>';  Cfg.DataProcessDir = '<work>';  Cfg.SubjectID = {'S01'};
Cfg.FunctionalSessionNumber = 1;
Cfg.TimePoints = 0;  Cfg.TR = 0;                  % TR=0 自动读 NIfTI 头
Cfg.IsNeedConvertFunDCM2IMG = 1;
Cfg.IsNeedConvertT1DCM2IMG  = 1;
Cfg.IsNeedReorientCropT1Img = 1;
Cfg.IsRemoveFirstTimePoints = 1;  Cfg.RemoveFirstTimePoints = 10;
Cfg.IsSliceTiming = 1;
Cfg.SliceTiming.SliceNumber = 0;  Cfg.SliceTiming.SliceOrder = [];  Cfg.SliceTiming.ReferenceSlice = 0;
Cfg.IsRealign = 1;
Cfg.IsNeedReorientFunImgInteractively = 0;
Cfg.IsNeedT1CoregisterToFun = 1;
Cfg.IsSegment   = 2;                              % New Segment
Cfg.IsDARTEL    = 1;                              % 建组模板 + VBM 标准化
Cfg.IsNormalize = 3;                              % DARTEL 标准化
Cfg.Normalize.Timing = 'OnFunctionalData';
Cfg.Normalize.BoundingBox = [-90 -126 -72; 90 90 108];
Cfg.Normalize.VoxSize = [3 3 3];
Cfg.IsSmooth = 1;  Cfg.Smooth.Timing = 'OnFunctionalData';  Cfg.Smooth.FWHM = [6 6 6];
Cfg.IsCovremove = 0;  Cfg.IsFilter = 0;  Cfg.IsDetrend = 0;
Cfg.IsCalALFF = 0; Cfg.IsCalReHo = 0; Cfg.IsCalDegreeCentrality = 0; Cfg.IsCalFC = 0;
Cfg.IsExtractROISignals = 0; Cfg.IsCalVMHC = 0; Cfg.IsCWAS = 0;
Cfg.MaskFile = 'Default';
Cfg.IsAllowGUI = 0;
save('<work>\cfg.mat','Cfg');
DPARSFA_run('<work>\cfg.mat','','',0);
```

注意：
- DARTEL 要求所有被试一起跑（组模板来自 `SubjectID{1}` 目录下的 `Template_6.nii`，见 DPARSFA_run.m:2423-2430、3162-3169），被试集合变化必须整批重跑。
- 本预设计算链：`FunRaw → FunImg → FunImgA → FunImgAR → FunImgARW → FunImgARWS`（W 来自 DARTEL，S 为普通平滑）。`T1ImgNewSegment/` 下另存 `Template_6*`、`u_*`、`c1..c3`、`rc1/rc2` 及 VBM 结果。

---

## 预设 C：快速功能像质控（只做 realign + 头动指标）

适用：数据体检、决定要不要剔除被试；几秒到几分钟一个被试，不产生标准化数据。

```matlab
% ---- 预设 C ----
load(fullfile('D:\Software\DPABI','DPARSF','Jobmats','Template_Blank.mat'));
Cfg.WorkingDir = '<work>';  Cfg.DataProcessDir = '<work>';  Cfg.SubjectID = {'S01'};
Cfg.FunctionalSessionNumber = 1;
Cfg.TimePoints = 0;  Cfg.TR = 0;
Cfg.IsNeedConvertFunDCM2IMG = 1;      % 已是 NIfTI 则置 0，StartingDirName 用 'FunImg'
Cfg.IsRemoveFirstTimePoints = 1;  Cfg.RemoveFirstTimePoints = 5;
Cfg.IsSliceTiming = 0;
Cfg.IsRealign = 1;
Cfg.IsCalVoxelSpecificHeadMotion = 1;         % 额外体素级 TDvox/FDvox 图
Cfg.IsNeedT1CoregisterToFun = 0;  Cfg.IsSegment = 0;  Cfg.IsDARTEL = 0;
Cfg.IsNormalize = 0;  Cfg.IsSmooth = 0;  Cfg.IsBet = 0;  Cfg.IsAutoMask = 0;
Cfg.IsCovremove = 0;  Cfg.IsFilter = 0;  Cfg.IsDetrend = 0;  Cfg.IsScrubbing = 0;
Cfg.IsCalALFF = 0; Cfg.IsCalReHo = 0; Cfg.IsCalDegreeCentrality = 0; Cfg.IsCalFC = 0;
Cfg.IsExtractROISignals = 0; Cfg.IsCalVMHC = 0; Cfg.IsCWAS = 0;
Cfg.IsAllowGUI = 0;
save('<work>\cfg.mat','Cfg');
DPARSFA_run('<work>\cfg.mat','','',0);
```

产出（Runner 直接读）：
- `RealignParameter/HeadMotion.tsv`：每被试 20 列头动指标（max/mean 平移旋转、mean RMS、FD_VanDijk、FD_Power、FD_Power>0.5/0.2 计数与百分比、FD_Jenkinson）
- `RealignParameter/ExcludeSubjectsAccordingToMaxHeadMotion.txt`：按 3.0/2.5/…/0.5 mm & degree 阈值列的候选剔除名单
- `RealignParameter/<subj>/{rp_*.txt, mean*.nii, FD_Power_*.txt, FD_Jenkinson_*.txt, FD_VanDijk_*.txt}`
- `FunImgR/<subj>/r*`、`<prefix>VoxelSpecificHeadMotion/<subj>/`、`Results/MeanVoxelSpecificHeadMotion_Mean{TD,FD}vox/`

---

## 三套预设开关对照

| 步骤 | A 经典 | B 仅预处理(DARTEL) | C 快速QC |
|---|---|---|---|
| DICOM→NIfTI | ✔ | ✔ | ✔（可关） |
| Crop T1（生成 co*） | ✔ | ✔ | — |
| RemoveFirstTimePoints | 10 | 10 | 5 |
| SliceTiming | ✔ | ✔ | ✘ |
| Realign | ✔ | ✔ | ✔ |
| VoxelSpecificHeadMotion | ✘ | ✘ | ✔ |
| T1→Fun Coreg | ✔ | ✔ | ✘ |
| Segment | 2（统一分割） | 2（New Segment） | ✘ |
| DARTEL | ✘ | ✔ | ✘ |
| Normalize | 2 / OnFunctionalData | 3 / OnFunctionalData | ✘ |
| Smooth | 1 / OnFunctionalData / [4 4 4] | 1 / OnFunctionalData / [6 6 6] | ✘ |
| Covremove | AfterNormalize, Friston24, WM+CSF | ✘ | ✘ |
| Filter | AfterNormalize 0.01–0.1 | ✘ | ✘ |
| ALFF / ReHo / DC / FC | ✔ / ✔ / ✔ / ✔ | ✘ | ✘ |
| 典型产物 | FunImgARWSCF + Results* | FunImgARWS + T1ImgNewSegment | FunImgR + RealignParameter |

（"统一分割"在 SPM12 中即 `IsSegment=2` 的 `spm.spatial.preproc` 新分割；旧分割为 `IsSegment=1` 走 `spm.tools.oldseg`。）
