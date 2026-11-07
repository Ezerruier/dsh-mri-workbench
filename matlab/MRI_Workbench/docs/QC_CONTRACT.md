# 人工 QC 功能 — 协作契约（含 v3 修订）

> 目标：在神经影像工作台中新增「人工 QC」：**可缩放的图像查看 + DPARSF 兼容的 1–5 分人工评分与评语**，覆盖 DPARSF 的人工 QC 场景：
> ① T1 原始像 QC（DPARSF `QC/RawT1ImgQC.tsv`）
> ② 功能像平均像 QC（DPARSF `QC/RawFunImgQC.tsv`，使用 `RealignParameter/<subj>/mean*`）
> ③ 标准化 QC（`QC/NormalizationQC.tsv`，显示 wFun/wT1/wGM，叠加 DPABI MNI 边缘模板轮廓）
> 并支持阈值筛选、导出通过被试名单（参考 `DPABI_QC_TOOL`）。
>
> 参考实现（只读）：`D:\Software\DPABI\QualityControl\`（`y_spm_image.m`、`w_QCScore.m`、`y_QC_Normalization.m`、`DPABI_QC_TOOL.m`）、`D:\Software\DPABI\DPARSF\SubGUIs\ReorientThreQC.m`。
> 评分语义与 DPARSF 完全一致：**1 = Very Poor(很差) … 5 = Very Good(很好)**；评语自由文本。

## 0. 环境与写入范围

- 仓库根目录即 DSH 插件根；工作台 `matlab/MRI_Workbench/`（MATLAB package `+mrw`）。
- MATLAB R2026a；DPABI `D:\Software\DPABI`、SPM12 `D:\Software\spm12` 已在路径中（`mrw.Dpabi.ensurePath()` 可确保）。
- UI 统一用 `mrw.UiKit`（`colors/fonts/card/tip/newFigure`）与 uifigure 组件；中文标签，控件加 Tooltip。
- 写入范围：
  - qc-engineer：`matlab/MRI_Workbench/+mrw/QcModel.m`、`matlab/MRI_Workbench/tests/qc_fixture.m`、`matlab/MRI_Workbench/tests/test_qc_model.m`
  - qc-ui：`matlab/MRI_Workbench/+mrw/QcPanel.m`、`matlab/MRI_Workbench/tests/test_qc_panel.m`（及测试截图 PNG）
  - qc-dsh：`index.mjs`、`client.js`、`README.md`、`docs/VERIFICATION.md`
  - Lead：`+mrw/QcViewer.m`、`WorkbenchApp.m`、`RunPanel.m`、MATLAB 工作台文档
  任何写范围外修改先发消息给 Lead。

## 1. `mrw.QcModel`（静态类，qc-engineer 实现）

### 1.1 模态与文件发现

`info = mrw.QcModel.discover(workDir)`

```
info.WorkingDir char
info.Ok logical（工作目录存在且至少一个模态可用）
info.Message char
info.Modalities struct array，字段：
    Key        'T1' | 'Fun' | 'Norm'
    LabelZh    'T1 原始像' | '功能平均像' | '标准化检查'
    Available  logical
    SubjectIDs cellstr（有可用图像的受试者，按自然排序）
    Missing    cellstr（缺图像的受试者，若能从其他模态/QC TSV 推断）
    TSVFile    char（QC/RawT1ImgQC.tsv | QC/RawFunImgQC.tsv | QC/NormalizationQC.tsv）
```

文件选择优先级（尽量参照 DPARSF）：

- `T1`：`<wd>/T1Img/<subj>/c*.nii*`（含 co*）→ `*Crop*.nii*` → `*.nii*` → `.img`；选第一个。
- `Fun`：`<wd>/RealignParameter/<subj>/mean*.nii*`（DPARSF 的 RawFunImgQC 用的就是该平均像）→ `mean*.img`；若没有则用 `<wd>/FunImg/<subj>/*.nii*` 并计算时间维平均（`info.Subjects(i).ComputedMean=true`，提示"自动计算平均像"）。
- `Norm`：
  - 首选功能像标准化：`<wd>/RealignParameter/<subj>/wmean*.nii*`
  - T1 标准化：`<wd>/T1ImgNewSegment/<subj>/w*.nii*`（排除 `wc*`），若无则 `<wd>/T1ImgSegment/<subj>/w*.nii*`（排除 `wc*`）
  - GM：`<wd>/T1ImgNewSegment/<subj>/wc1*.nii*`（或 `T1ImgSegment`）
  - `discover` 的 Norm.SubjectIDs = 上述三类中任一存在的受试者并集；`subjects()` 返回每个受试者可用子图类型。

`S = mrw.QcModel.subjects(workDir, modalityKey)`，struct array 字段：

```
ID char; Files struct array? 简化：
Available logical
File char（默认显示文件）
FileKind char（'T1'|'FunMean'|'Fun4DMean'|'NormFun'|'NormT1'|'NormGM'）
Candidates struct array（可选：Which='Fun'|'T1'|'GM'，File）
Message char
```

### 1.2 读写图像

`[vol, hdr, info] = mrw.QcModel.loadVolume(filePath)`

- 支持 `.nii`、`.nii.gz`、`.img/.hdr`；4D 自动按第 4 维平均（`info.Mean4D=true`，`info.TimePoints=n`）。
- `vol`：3D double（`squeeze` 后）。
- `hdr`：至少包含 `.mat`（4x4，图像体素→世界 mm）、`.dim`（1x3）、`.voxSize`（1x3）；优先 `y_Read`（DPABI），失败回退 `spm_vol/spm_read_vols`（SPM）或 `niftiread/niftiinfo`。
- `info`：`.File .Dim .VoxSize .TimePoints .Mean4D .Source('y_Read'|'spm'|'niftiread') .Message`。
- 读不到时 `vol=[]`、`info.Message` 说明原因，不抛异常（UI 显示错误）。

### 1.3 切片与轮廓

`sl = mrw.QcModel.makeSlice(vol, orientation, sliceIndex)`

- orientation：`'axial'|'coronal'|'sagittal'`；sliceIndex 从 1 开始，越界自动 clamp。
- 返回：`.Image`（2D double）、`.Orientation`、`.SliceIndex`、`.SliceCount`、`.SliceLabel`（如 "Axial z=31/61"）。
- 约定（重要，QcPanel 与边缘叠加一致）：
  - axial：`Image = vol(:,:,k)'`? **不转置**：`Image = vol(:,:,k)`，显示时 rows=y、cols=x。
  - coronal：`Image = squeeze(vol(:,j,:))'`（rows=z、cols=x，z 向上为正：`flipud`）。
  - sagittal：`Image = squeeze(vol(i,:,:))'`（rows=z、cols=y，`flipud`）。
  若在实现中采用不同约定，必须在文件头注释写清，并保证 `edgeSliceFor` 与 QcPanel 使用同一约定。

`edge = mrw.QcModel.edgeSliceFor(hdr, orientation, sliceIndex, imageSize)`（或 `edgeSliceFor(hdr, vol, orientation, sliceIndex)`）

- 读取 DPABI 模板：`<DPABI>/Templates/Edge_mni_icbm152_AllTissues_tal_nlin_asym_09c_YCG.nii`（用 `mrw.Dpabi.root()` 定位）；缓存（persistent）。
- 用图像 `hdr.mat` 的体素→mm 映射、边缘模板 `hdr.mat` 的逆映射，经线性插值重采样到该切片网格，返回 2D double 轮廓权重（0–1，>0.05 视作轮廓），尺寸与 `makeSlice.Image` 一致。
- 失败时返回 `zeros(size)` 并给 warning，不崩溃。
- 另提供 `p = mrw.QcModel.mniEdgeFile()`、`p = mrw.QcModel.mniTemplateFile()`（ch2.nii）。

### 1.4 评分 TSV（DPARSF 兼容）

- `scores = mrw.QcModel.loadScores(workDir, modalityKey)`：返回 struct array，字段 `ID`、`Score`（double，未评分=NaN）、`Comment`；文件不存在返回空 struct。
- `ok = mrw.QcModel.saveScore(workDir, modalityKey, subjectID, score, comment)`：
  - 写 `QC/RawT1ImgQC.tsv` / `QC/RawFunImgQC.tsv` / `QC/NormalizationQC.tsv`
  - **格式必须与 DPARSF 一致**：首行 `Subject ID<TAB>QC Score<TAB>QC Comment`，每行一个受试者，Tab 分隔，UTF-8（中文评语用 UTF-8；同时 `loadScores` 要能读 DPARSF 生成的同格式文件）。
  - 合并已有行（保留其他受试者），按文件原顺序；score 必须 1–5 的整数（否则返回 false 并给原因）。
  - 目录不存在时创建 `QC/`。
- `prog = mrw.QcModel.progress(workDir)`：struct，含 `.T1/.Fun/.Norm` 三个 `.Scored/.Total/.Mean`，以及 `.AllScored`。
- 阈值与名单（参考 DPABI_QC_TOOL）：
  - `thr = mrw.QcModel.loadThresholds(workDir)` / `mrw.QcModel.saveThresholds(workDir, thr)`：
    `thr = struct('T1Min',3,'FunMin',3,'NormMin',3,'UseT1',true,'UseFun',true,'UseNorm',true,'MaxMeanFD',0.2,'UseMeanFD',false)`；持久化到 `QC/ManualQC_thresholds.json`。
  - `list = mrw.QcModel.exportPassList(workDir, outFile, thr)`：返回通过名单 cellstr，并写文本文件（每行一个 ID）；T1/Fun/Norm 均按分数过滤，MeanFD 可选。
- `hm = mrw.QcModel.loadHeadMotion(workDir)`：解析 `RealignParameter/HeadMotion.tsv`；返回 struct：
  `hm.Available`、`hm.IDs` cellstr、`hm.MeanFD` double（对应 DPARSF 第 21 列 mean FD_Jenkinson）、`hm.MaxTrans`（可选）、`hm.Table`（原始 table/矩阵，用于显示）。
- `st = mrw.QcModel.settings()`/`labels()` 之类的辅助可选。

### 1.5 测试数据（qc-engineer 提供 `tests/qc_fixture.m`）

```matlab
function base = qc_fixture()
% 生成合成"已预处理"数据集并返回工作目录；可重复调用（每次重建到 tempdir 下唯一目录）
```

要求生成（3 名受试者 `Sub01..Sub03`，文件名与 DPARSF 布局一致）：
```
<base>/T1Img/SubXX/coT1.nii                3D 64x64x30（blob）
<base>/RealignParameter/SubXX/meanSubXX.nii 3D
<base>/RealignParameter/SubXX/wmeanSubXX.nii 3D（MNI 尺寸 91x109x91 2mm，便于边缘叠加）
<base>/T1ImgNewSegment/SubXX/wT1.nii        3D 91x109x91
<base>/T1ImgNewSegment/SubXX/wc1.nii        3D
<base>/RealignParameter/HeadMotion.tsv      表头 21 列（与 DPARSF一致），3 行数据
<base>/QC/（空）
```
NIfTI 头用 `tests/lead_make_nifti.m`（已存在，写 3D/4D float32；mat 为 diag(vox)）生成；MNI 尺寸图像请用 `vox=[2 2 2]`、mat 平移到 [-90 –126 –72] 附近以接近 MNI 空间（可给 lead_make_nifti 扩展 mat 参数？不要改别人文件——可在 fixture 内自己写头或先用 lead_make_nifti 生成后再用 `spm_get_space` 改 mat；SPM 可用）。
测试覆盖：discover/subjects/loadVolume（含 4D 平均）、makeSlice 三方向、edgeSliceFor 尺寸一致、saveScore→loadScores 往返、已有行合并、progress、threshold/exportPassList、HeadMotion 解析。

## 2. `mrw.QcPanel`（UI 组件，qc-ui 实现）

```matlab
classdef QcPanel < handle
    properties (SetAccess = private) Parent; end
    events Changed   % 评分保存/受试者切换/模态切换后触发
    methods
        function obj = QcPanel(parent, opts)
        % opts: struct，可选字段 WorkingDir(''), Modality('T1'), Footer(true)
        function setWorkingDir(obj, workDir)
        function refresh(obj)               % 重新发现数据/评分并刷新界面
        function setModality(obj, key)      % 'T1'|'Fun'|'Norm'
        function setSubject(obj, subjIDORindex)
        function setOrientation(obj, orient)
        function setSliceIndex(obj, idx)
        function f = setZoomFactor(obj, f)  % f>=0.5；1=适应窗口；返回实际 f
        function f = getZoomFactor(obj)
        function setWindow(obj, lowPct, highPct) % 0–100 百分位
        function setOverlayVisible(obj, tf) % 标准化模态的模板轮廓
        function saveCurrentScore(obj)      % 写入 QcModel；成功后自动下一人（可配置）
        function nextSubject(obj); function prevSubject(obj)
        function st = getState(obj) % struct: WorkingDir/Modality/SubjectID/Score/Comment/SliceIndex/Zoom/Progress
        function list = exportPassList(obj, filePath) % 调 QcModel，返回 cellstr
    end
end
```

UI 要求（中文，带英文副标题与 Tooltip）：

- 顶部工具条：工作目录（只读/可浏览）、[重新扫描]；模态下拉：`T1 原始像 / 功能平均像 / 标准化检查`；进度标签"已评分 3/20"。
- 左列（约 240px）：受试者表格（uitable：受试者、评分、评语?），支持行选择；`上一人/下一人` 按钮；筛选复选框"仅显示未评分"；阈值下拉 T1/Fun/Norm 最低分（默认 3）。
- 中间：图像 `uiaxes`（占最大空间）：
  - **必须可缩放**：v3 使用 figure 回调，普通滚轮切层、Ctrl+滚轮锚点缩放、拖拽平移；禁用内置 `zoomInteraction/panInteraction` 防止抢事件。按钮 `[－][1:1][＋][适应]` 控制活动视图，显示各视图倍数；`setZoomFactor` 保持当前视野中心，`getZoomFactor` 返回相对适应窗口的倍数。
  - 切片滑条 + 方向下拉（横断/冠状/矢状）；键盘 ↑/↓ 或鼠标滚轮+修饰键可切换切片（若实现，需说明）。
  - 窗宽窗位：低/高百分位双滑条或两个数值框（0–100，默认 2/98），[自动窗宽] 按钮。
  - 标准化检查：默认叠加 MNI 边缘轮廓（红色/黄色高亮，可开关、透明度可调），可切换 wFun / wT1 / wGM。
  - 十字线（可选）：中心十字，可开关。
  - 图像标题：受试者 · 模态 · 文件名 · 切片位置；空数据显示中文占位提示。
- 右列（约 260px）：
  - 评分：5 个单选 `1 很差 / 2 差 / 3 一般 / 4 好 / 5 很好`（默认 3 或已保存值）；
  - 评语 textarea；
  - [保存并下一人] [跳过]；
  - 显示设置：模板轮廓开关、透明度滑条、窗宽自动按钮、方向/缩放重置；
  - 若 `mrw.QcModel.loadHeadMotion` 可用，显示当前受试者 Mean FD 与"超过阈值"提醒。
- 底部状态栏：三模态评分进度汇总 + 当前任务提示；`opts.Footer=false` 时不显示。
- 加载失败/无数据时显示提示文字，不崩溃。

性能：切换受试者/切片 < 1.5 s（小数据）；缓存最近 3 个 volume。

测试（qc-ui 提供 `tests/test_qc_panel.m`，-batch 可跑）：
- 用 `qc_fixture()` 造数据 → `QcPanel` 构造 → 断言默认模态/受试者/评分空；
- `setZoomFactor(2.5)` → `getZoomFactor`≈2.5，axes `XLim` 宽度缩小；`setZoomFactor(1)` 复原；
- `setSliceIndex`/`setOrientation` 不报错，`getState` 反映；
- `setWindow(5,95)` 生效；
- 模拟评分保存：`saveCurrentScore` 后 `QcModel.loadScores` 能读到，TSV 头与列正确；
- 切换模态/阈值筛选不报错；
- `exportapp` 生成至少 3 张截图：`tests/out_qc_panel_default.png`、`out_qc_panel_zoom.png`（≥2.5 倍）、`out_qc_panel_norm.png`（标准化+轮廓）；用 `read_image` 自查布局并迭代一次。

## 3. `mrw.QcViewer`（Lead 实现，供 DSH/外部启动）

```matlab
classdef QcViewer
    methods (Static)
        function fig = open(workDir, modality) % modality 可选，默认 'T1'
    end
end
```
uifigure 1200x820 + QcPanel；窗口标题"人工QC — 可缩放"；关闭时释放。

## 4. DSH 插件扩展（qc-dsh 实现）

在现有 `dsh-mri-workbench` 插件上增加人工 QC 能力（不改已有工具契约）：

1. Host 工具 `mri_workbench_qc`：参数 `{ workDir?: string }`；不启动 MATLAB，直接读：
   - `QC/RawT1ImgQC.tsv`、`QC/RawFunImgQC.tsv`、`QC/NormalizationQC.tsv`（若存在）
   - `RealignParameter/HeadMotion.tsv`
   返回/渲染：各模态已评分数量/总数/平均分/低分（≤2）受试者列表、MeanFD 超阈值名单、最近评语；工作目录解析同现有工具（默认取最近一次 prepare 的 WorkingDir 或 `mri_workbench_status` 里的工作目录）。
2. 命令 `/mri qc [workDir]`：用独立 MATLAB 桌面进程打开 `mrw.QcViewer.open(workDir, 'T1')`（命令返回提示"已在 MATLAB 打开可缩放人工 QC 窗口"）；若未给 workDir 用最近配置的工作目录。
3. 系统提示中补充一句：预处理完成后用户可能要求人工 QC；用 `mri_workbench_qc` 汇总评分，低分提示复核；需要人工看图时用 `/mri qc` 打开 MATLAB 可缩放查看器（不要在对话里伪造 QC 结论）。
4. Client「MRI 工作台」页新增"人工 QC"卡片：按钮 [刷新 QC 评分]（执行 `/mri qc`? 不——刷新用 `/mri qcsummary` 或直接 status 命令？按现有命令通道：新增 `/mri qcstatus` 返回文本）与 [打开 MATLAB 人工 QC]（`/mri qc`），输出复用现有 output 区域。新增命令 `qcstatus`（返回与工具相同的摘要文本），`qc` 打开查看器。
5. 更新 `README.md` 与 `docs/VERIFICATION.md`（新增人工 QC 章节、命令、限制）。
6. 只改上述 4 个文件；改完 `node --check` 通过；工具/命令的 Host 逻辑用 Node 单测或手工模拟数据验证（可在临时目录放示例 TSV 直接调用内部读取函数？函数未导出则至少用 node --check + Lead 重载后实测）。

## 5. 验收标准

- `tests/test_qc_model.m`：全绿，覆盖 1.5 所列。
- `tests/test_qc_panel.m`：全绿，3 张截图可读，缩放在截图中可辨（视野明显小于默认）。
- Lead 集成：`WorkbenchApp` 新增「⑥ 人工QC」页可打开、可评分并写入 TSV；`RunPanel` 增加「打开人工QC」按钮；全模块回归测试通过（原 6 个测试 + 新增 QC 测试）。
- DSH：插件重载后 `mri_workbench_qc` 工具可用并返回摘要；`/mri qc` 命令在用户 MATLAB 中打开查看器（视觉验证受限，需说明）。
- 不改 DPABI 安装目录；评分文件与 DPARSF 兼容；中文评语无乱码。

## 6. 参考：DPARSF/DPABI 人工 QC 事实（已核源码）

- 评分：1–5；`y_spm_image.m:452-468`；评语 `:474`。
- 原始 T1 QC：`T1Img/<subj>/c*` 首张，`DPARSFA_run.m:1287-1291`；分数写 `QC/RawT1ImgQC.tsv`（`:1304-1318`）。
- 原始功能 QC：`RealignParameter/<subj>/mean*`，`DPARSFA_run.m:1392-1406`；写 `QC/RawFunImgQC.tsv`（`:1418-1432`）。
- 标准化 QC：`y_QC_Normalization.m`：wT1（`T1ImgNewSegment/w*` 排除 wc）、wFun（`RealignParameter/wmean*`）、wGM（`wc1*`），叠加 DPABI `Templates/Edge_...nii`，写 `QC/NormalizationQC.tsv`。
- 阈值：`SubGUIs/ReorientThreQC.m`：T1/Fun 阈值默认 3；`DPABI_QC_TOOL.m:440-464` 用 `Score>=阈值` 过滤，`:493-521` 头动/覆盖率阈值，`:466-492` 导出被试名单。
- MeanFD 取 `RealignParameter/HeadMotion.tsv` 第 21 列（`DPABI_QC_TOOL.m:404-429`）。

## 7. v2 增补（2026-11-07，三正交 / 校准 / FD 联动 / Agent 实时指导）

v2 在 v1 之上新增显示几何引擎、三正交视图、原点/AC-PC/方位校准、多切片网格、FD 曲线联动、排序筛选与状态 JSON；**v1 §1–§6 的接口与行为保持不变**（`QcPanel` 旧公共方法、评分 TSV 格式、`QcViewer.open(workDir, modality)` 均兼容）。

1. `mrw.QcView`（新建，纯计算无 UI，`+mrw/QcView.m`）
   - 坐标：voxel（1-based 连续）→ world（`hdr.mat` mm）→ display（显示变换 A 后 mm）。
   - 变换：`A = F * M_manual * M_base`；`M_base` 为 `native`（I）/`origin`（T(-originWorld)）/`acpc`（R_acpc*T(-acWorld)）；`M_manual` = 平移 mm 与 pitch/roll/yaw 旋转（`Rz*Ry*Rx`，度）；`F` 为 LR/AP/IS 翻转对角阵。**只影响显示，不写回 NIfTI**。
   - 公共方法：`setVolume/hasVolume/slice/planeInfo/currentSliceIndex/setSliceIndex/montage/setCrosshair/getCrosshair/voxelToWorld/worldToVoxel/voxelToDisplay/displayToVoxel/setOriginAtWorld/setAcPc/clearAcPc/setManual/setFlips/setInterpolation/resetDisplay/getInfo`。
   - v3 起 `native` 与非 native 统一采用 SPM world-space 方向；`QcModel.makeSlice` 保持低层原始切片契约，正常 UI 由 `QcView` 渲染；`getInfo()` 返回 Mode/HasVolume/DisplayMatrix/Crosshair*/AC/PC/ACPC/Manual/Flips/Dim/VoxSize 等。
   - AC-PC 语义：AC→display 原点、PC→display 后方（-Y）、距离保持，采用右(+X)/前(+Y)/上(+Z)约定；不能把PC旋到+Y而把正常脑部倒置。AC=PC 或距离 <1e-6 mm 拒绝并给中文 `Message`。
2. `mrw.QcAlignDialog`（新建，modeless 对话框，`+mrw/QcAlignDialog.m`）
   - 只读坐标读数；「以十字线设显示原点」「把当前位置设为 AC/PC」「应用 AC-PC 配平」「清除配平」；6 个平移/旋转 numeric +「应用微调/清零微调」；左右/前后/上下翻转；显示矩阵与模式只读；`close()/delete()` 幂等清理监听器。
   - 只调用 `QcPanel` 公共方法：`getViewInfo/getState/setCrosshairVoxel/getCrosshairVoxel/setOriginAtCrosshair/setACPC/clearACPC/setManualOrientation/setFlips/resetOrientation` 等。
3. `mrw.QcPanel` v2 新增公共接口（旧接口不变）
   - 视图/状态：`setViewMode('single'|'triple'|'montage')`、`setCrosshairVoxel`、`getCrosshairVoxel`、`getViewInfo`、`refreshViews`。
   - 校准：`setOriginAtCrosshair`、`setACPC(acVoxel, pcVoxel)`、`clearACPC`、`setManualOrientation(tMm, rDeg)`、`setFlips`、`resetOrientation`。
   - 状态导出：`exportState(filePath)`，并在状态变化后自动原子写 `<workDir>/QC/.qcviewer_state.json`（失败静默）；`getState()` 增补 ViewMode/ActiveOrientation/CrosshairVoxel/CrosshairWorld/CrosshairDisplay/Display/AxesHandles/FD/Filter/Sort/StateFile 等。
   - 布局：工具条（视图模式/复制状态给 Agent）、左列（筛选/排序 + 受试者|评分|MeanFD）、中列（单视图/三正交 2×2/多切片网格 + 色阶/插值/十字线/坐标读数/方位校准）、右列（评分 + 显示设置 + 校准摘要）、底部 FD 曲线条（类型/阈值/统计/坏帧/低分警示）。
4. 状态 JSON（`schema = "mrw.qcviewer.state.v2"`，写入 `<workDir>/QC/.qcviewer_state.json`）
   - 顶层：`updatedAt`（本地时区 ISO 8601，如 `+08:00`）/`workDir`/`modality`/`subjectID`/`subjectIndex`/`subjectCount`/`file`/`viewMode`/`activeOrientation`/`crosshairVoxel|World|Display`/`display`（mode/matrix/acVoxel/pcVoxel/acWorld/pcWorld/distanceMm/angleDeg/manualTranslationMm/manualRotationDeg/flips/hasVolume/message）/`slices`/`window`/`clim`/`colormap`/`interp`/`zoom`/`crosshairVisible`/`overlay`/`score`/`headMotion`/`filter`/`sort`/`progress`/`message`。
   - `headMotion`：`fdType`/`fdThreshold`/逐帧 `values`/`meanFD`（HeadMotion.tsv 第 21 列，与窗口一致）/`seriesMeanFD`（逐帧均值）/`meanFDSource`/`maxFD`/`badFrames`/`badRatio`/`maxTranslation`/`maxRotation`。
   - 写入方式：先写 `.json.tmp` 再原子替换；查看器关闭时删除该文件（表示窗口已关闭）。
5. DSH 侧
   - Host 工具 `mri_workbench_qcstate` 与命令 `/mri qcstate [workDir]`：纯 Node 读状态 JSON，不启动 MATLAB；缺文件/损坏/过期（>30 min）/schema 不一致均中文提示或容错；输出结构化 JSON + 中文摘要。
   - 系统提示：用户询问 MATLAB 人工 QC 当前画面时，先 `matlab_snapshot` 截图，再 `mri_workbench_qcstate` 读精确状态，据此指导；不得凭空描述。
   - 页面 ④ 卡：hint 更新 + 新按钮「读取 MATLAB QC 状态」；中英文 locale。
6. 测试与验收
   - `tests/test_qc_view.m`（QcView 几何/AC-PC/montage/性能，367 断言）、`tests/test_qc_panel.m`（v1 回归 + v2 253 断言 + 7 截图）、`tests/test_qc_integration_lead.m`（状态 JSON/三正交）、`tests/test_qc_ui_v2_accept.m`（Lead 跨模块验收 65 断言 + 3 截图）。
   - `test_all_lead` 现为 10/10；真实 MATLAB 桌面 + 真实 DPARSF 数据（`MyStudy`）真机验收见 `docs/VERIFICATION.md` §28 与 `matlab/MRI_Workbench/docs/人工QC验证记录.md` §5.5。
   - 限制：AC/PC 由人工拾取，不自动检测；默认显示变换不落盘；v3 单视图与三正交使用同一世界坐标显示变换。


## 8. v3 方向与显示网格修订（2026-11-07）

真实 `cT1.nii` 含斜切仿射。v2 把 voxel i/j 直接当成图像行/列，并把降序 Z 的图像配成反转 Y 轴，导致横断旋转和上下方向错误。v3 的显示基准为本机 `spm_image` → `spm_orthviews` World Space（mode=1，与 DPABI `y_spm_image` 相同）：

| 平面 | 图像列递增 | 图像行递增 | 屏幕左→右 / 下→上 |
|---|---|---|---|
| 横断 axial | display +X | display +Y | L→R / P→A |
| 冠状 coronal | display +X | display +Z | L→R / I→S |
| 矢状 sagittal | display -Y | display +Z | A→P / I→S |

`native` 表示显示变换 A=I，不再承诺与 `QcModel.makeSlice.Image` 逐元素相同。正对角仿射可无插值取片；斜切、负轴或置换仿射使用 A*hdr.mat 的逆矩阵采样世界正交网格；原始 `hdr.mat` 完整保留。`origin`/AC-PC/手动/翻转使用相同平面方向。`QcModel.makeSlice` 与其低层模板轮廓接口保留原始转置契约，以兼容外部调用。

`QcView.planeInfo` 的 `PixelToDisplay` 将连续 `[col;row;1]` 精确映射到 display mm；`XLim/YLim` 表示半像素外扩边界，`imagesc` 必须使用像素中心作为 XData/YData；axes 使用 YDir normal，矢状使用 XDir reverse。十字线与拾取依据完整映射，不从源体素行列猜测。

新增 `[vol,mat] = QcView.resampledVolume()`：输出当前实际显示网格，数组维度为 display `[X,Y,Z]`，`mat` 为 SPM 1-based 体素到 display mm 仿射。方法不写文件；没有有效网格时抛出中文错误，供应用数据服务在发布前处理。网格与插值器按体积/变换缓存，移动十字线或切层不清空缓存。

方向回归使用独立非对称体：已知 L/A/S 亮点、负 X 轴、斜切仿射与独立 `interpn` 计算，覆盖 native/non-native 方向、坐标和导出网格。

重采样显示网格（包括斜切 native）的步长和首体素中心统一舍入到可由 NIfTI-1 float32 精确表示的二进制格点；显示与高级导出复用完全相同的缓存网格。这样避免 NIfTI 0/1-based 转换导致 qform/sform 平移差异。舍入误差会随索引累积，常见约 200 格点的脑影像范围内远小于 0.01 mm；正对角 native 的无插值取片保留原始精确体素中心。输出日志中的矩阵是写出副本的精确几何，不得声称重采样副本与原始像素相同。

## v3 显式应用到数据（新增服务契约）

- `result = mrw.QcPanel.applyCurrentToData(method)`，method 为 `header-only`（默认）或 `resample`；对话框在核对摘要并确认后才调用。范围严格为当前受试者、当前模态、当前显示文件。原始文件不覆盖，4D 时间平均预览明确拒绝。
- `mrw.QcReorient.apply(source, workDir, subject, viewInfo, method, resampled)` 负责事务。`viewInfo.DisplayMatrix` 为实际 4×4 world→display 仿射；只改头目标 SPM 几何为 `A * sourceMat`。重采样 payload 为 `struct('Data', data, 'Mat', mat)`，来自 QcView.resampledVolume。
- 默认输出 `<workDir>/QC/Reorient/<subject>/<唯一时间批次>/<原文件名>`；重采样输出 `_resampled.nii`。支持 nii、nii.gz、img/hdr；已存在批次不覆盖。暂存、完整校验、日志落盘后整体重命名目录发布。任一步失败只清理本次暂存目录。
- qform/sform codes 均有效，1-based↔0-based 由 SPM NIfTI 编码器处理。NIfTI-1 几何字段按 float32 编码（NIfTI-2 为 float64）：先从写前头字段求预期编码几何，SPM/qform/DPABI/niftiinfo 读回与预期编码的矩阵误差仍须 `<1e-6`；niftiinfo 使用0-based原空间单位矩阵比较。实际 sform、qform 相对理想双精度目标及彼此的全视野边界8角点欧氏距离均须 `<=0.001 mm`，这是产品数值误差上限，不是NIfTI标准规定。剪切、非实数/非有限几何、超出该物理误差上限仍拒绝并回滚，不能只靠编码读回相符就放行。原文件始终不变。
- 原文件 SHA-256/大小前后相同；header-only 原始像素 payload 哈希和读取后的体素强度逐元素相同。SPM、DPABI y_Read（可用时）、niftiinfo 验证读取；压缩/成对格式在隔离暂存中处理。重采样使用显示实际采样网格并记录 `ResampleGridMaxShiftMm`。
- 每批次 `reorient_log.json`（SchemaVersion=2）记录输入/输出、方法、时间、MATLAB、哈希、校验与回退。`RequestedOutputMatrix` 保存理想目标，`OutputMatrix`/`OutputQformMatrix` 保存实际读回的 sform/qform，`result.Matrix` 也是实际 sform；Verification 分别记录矩阵编码读回误差及全视野坐标偏差(mm)。继续使用 SourceFile 即可回退；其它图像/中间产物需单独应用或重跑受影响步骤。
- 状态 schema 保持 `mrw.qcviewer.state.v2`，不新增必需字段；导出日志独立于状态快照。QC 预览不自动改成输出文件，防止二次应用。
- `QcModel.loadVolume(.nii.gz)` 所有 reader 先使用独立临时解压路径并在完成后清理；禁止 y_Read 在原目录解压或删除同名 `.nii`。

## v3 鼠标与性能验收补充

- figure 的实际鼠标回调统一处理：普通滚轮切层，Ctrl+滚轮以指针为锚点缩放，单击释放时定位，累计移动达到3像素后仅平移；双击适应。三正交按命中轴设活动方向，每轴独立保留 limits。
- `[－][1:1][＋][适应]` 控制活动轴，所有方向标题标注缩放；控件中文且有 UiKit.tip。位置/校准信息最多三行，移至图像区域底部紧凑行。
- 单图与三图复用图像/十字线句柄；体积、采样器、显示网格和模板/边缘按需缓存。滑条 changing 合并待处理值并使用 drawnow limitrate，changed 强制最终值及状态文件。
- 性能须报告实际 setSliceIndex 回调耗时，并把 drawnow/桌面显示提交耗时单列，不能以纯引擎计时冒充桌面端到端帧率。
