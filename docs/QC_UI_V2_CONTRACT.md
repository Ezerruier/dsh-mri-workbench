# QC UI v2 设计契约（MATLAB 人工 QC 窗口升级）

> 本文件是 Lead 与队友之间的接口契约，**以本文件为准**。实现遇到契约未覆盖的细节，
> 由实现者自行决定并在完成报告中说明；需要改契约时先发消息给 Lead，不要单方面改接口。
>
> 目标：把 MATLAB 的「人工 QC」窗口（`mrw.QcPanel` / `mrw.QcViewer`）从
> 「单切片 + 1–5 分」升级为接近神经影像查看器的人工 QC 工作台：
> 三正交联动、原点/AC-PC 配平、方位调整、多切片网格、FD 曲线与评分联动、
> 排序筛选、以及把当前显示状态交给 DSH Agent 做实时指导。

> 备注（公开仓库）：本文档最初是开发期的接口契约，现作为 QC UI v2 的设计说明保留；
> 文中的「Lead / 队友 / 所有权表」指当时的开发协作分工，与使用方式无关。本地绝对路径与
> 受试者编号已做脱敏处理。

## 0. 用户原始需求（2026-11-07）

1. 「矢、冠、水平面一同展示」→ 三正交联动视图（同一 3D 体素十字线）。
2. 「原点校准」→ 十字线体素/世界 mm 坐标；从十字线设显示原点。
3. 「前联合后联合配平」→ 拾取 AC/PC，计算 AC-PC 配平（显示层，不修改文件）。
4. 「调整图片方位」→ 6 自由度手动平移/旋转、左右/上下/前后翻转、色阶、插值；
   以及多切片网格视图。
5. 「目前的 QC 图像窗口少了很多功能」→ 补 FD 曲线/头动联动、受试者表排序筛选、
   多切片网格、快捷键、状态输出等。
6. 「Agent 实时指导显影情况」→ QC 窗口自动写状态 JSON（当前受试者/模态/十字线/
   AC-PC/显示矩阵/窗宽/叠加/评分），DSH 侧新增工具/命令读取，配合
   `matlab_snapshot` 截图，Agent 可实时指导；新增「复制状态给 Agent」按钮。

## 1. 文件所有权（写范围，禁止越界）

| 角色 | 独占写范围 |
|---|---|
| view-engine | `matlab/MRI_Workbench/+mrw/QcView.m`（新建）、`matlab/MRI_Workbench/+mrw/QcModel.m`、`matlab/matlab/MRI_Workbench/tests/qc_fixture.m`、`matlab/matlab/MRI_Workbench/tests/test_qc_view.m`（新建） |
| panel-ui | `matlab/MRI_Workbench/+mrw/QcPanel.m`、`matlab/MRI_Workbench/+mrw/QcAlignDialog.m`（新建）、`matlab/MRI_Workbench/+mrw/QcViewer.m`、`matlab/matlab/MRI_Workbench/tests/test_qc_panel.m`、`matlab/matlab/MRI_Workbench/tests/test_qc_integration_lead.m` |
| dsh-bridge | `index.mjs`、`client.js`、`README.md`、`docs/VERIFICATION.md`、`matlab/MRI_Workbench/docs/人工QC使用说明.md`、`matlab/MRI_Workbench/docs/人工QC验证记录.md`、`tests/node/qc_state_test.mjs`（新建） |
| Lead | `docs/QC_UI_V2_CONTRACT.md`、`matlab/matlab/MRI_Workbench/tests/test_qc_ui_v2_accept.m`（新建）、`matlab/matlab/MRI_Workbench/tests/test_all_lead.m`、`matlab/MRI_Workbench/docs/QC_CONTRACT.md`、最终集成与真机验证 |

> 不允许修改：`D:\Software\DPABI`、`D:\Software\spm12`、用户研究数据、任何 `*.tsv` 评分文件（除测试 fixture 自己生成）。
> 展示层变换（AC-PC/旋转/翻转）**只影响显示**，不得写回 NIfTI。

## 2. 运行环境与测试方式

- MATLAB：`D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe`（DPABI/SPM12 已在保存路径中）。
- 单测命令（项目根目录 `<repo>\matlab\MRI_Workbench`）：
  ```
  & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch "cd('<repo>\matlab\MRI_Workbench'); addpath(pwd); addpath('tests'); test_xxx"
  ```
- 已有测试：`tests/test_qc_model.m`、`tests/test_qc_panel.m`、`tests/test_qc_integration_lead.m`，
  数据由 `tests/qc_fixture.m` 合成（3 名受试者；T1 64x64x30；MNI 91x109x91；HeadMotion.tsv 21 列）。
- 测试脚本风格：函数内 `check(cond, msg)` 累计失败、最后打印 `PASS/FAIL`；UI 测试用
  `mrw.UiKit.newFigure` + `exportapp` 输出 PNG 到 `tests/`。新增测试必须可 `-batch` 跑通。
- 中文 UI：所有新控件必须中文标签 + `mrw.UiKit.tip` 中文 Tooltip（`test_qc_panel` 会检查
  所有交互控件都有 Tooltip）。
- 性能：QcPanel 构造 < 3 s（fixture 数据）；单切片重绘目标 < 150 ms；三正交一次重绘目标 < 400 ms。
- 不改 `mrw.UiKit`/`mrw.Glossary`/`WorkbenchApp`（除非 Lead 另行批准）。

## 3. `mrw.QcView`（view-engine 实现，panel-ui 只按此接口调用）

`+mrw/QcView.m`，`classdef QcView < handle`，**纯计算、无 UI 依赖**。

### 3.1 坐标约定

- voxel：1-based 连续坐标 `[i j k]`（与 `QcModel.makeSlice`/SPM 一致）。
- world：mm；由 `hdr.mat`（4x4，1-based 体素→mm，SPM 约定）定义。
- display：`world` 经显示变换 `A`（4x4，作用于 world 齐次坐标）后的 mm 坐标。
- `A = F * M_manual * M_base`：
  - `M_base`：`native` = I；`origin` = `T(-originWorld)`；`acpc` = `R_acpc * T(-acWorld)`。
  - `M_manual`：`T(translationMm) * R(pitch, roll, yaw)`（角度用**度**；旋转顺序固定为
    `R = Rz(yaw) * Ry(roll) * Rx(pitch)`，右手系）。
  - `F`：翻转对角阵，`flipLR` → diag([-1 1 1 1])，`flipAP` → diag([1 -1 1 1])，
    `flipIS` → diag([1 1 -1 1])（只影响显示）。
- 若 `hdr.mat` 无效：构造不报错，按 `M=eye(4)`、voxel size 1mm 显示，`getInfo().Message` 说明。
- 体素尺寸 `voxSize = sqrt(sum(hdr.mat(1:3,1:3).^2,1))`；无效时 `[1 1 1]`。

### 3.2 显示采样网格（用于非 native 模式）

- 取体积 8 个角点经 `A*M0` 变换到 display，得到 `[xmin xmax; ymin ymax; zmin zmax]`。
- 采样间距 `pix = max(min(voxSize(voxSize>0)), range_max/512)`；无效时 1mm。
- 每个方向 `SliceCount(orientation)` 与 `SliceIndex` 均按 display 轴定义（1-based）：
  axial 沿 display Z、coronal 沿 display Y、sagittal 沿 display X。
- 图像返回 `img` 为 double 2D，行=Y 方向、列=X 方向，`imshow`/`imagesc` 语义由 panel 处理；
  QcView 用 `interp3(X,Y,Z,V, x,y,z, method)` 采样，越界填 0（NaN 也填 0）。
- `info.XLim`/`info.YLim` 为 display mm 的图像半像素外扩范围（用于 `imagesc` 的
  `XData`/`YData`；panel 用 `imagesc(ax, info.XLim, info.YLim, img)`）。
- **native 模式必须与 `QcModel.makeSlice` 完全一致**（直接切片，不重采样），保证 v1 测试与
  性能不变：`SliceCount` 分别为 dim3/dim2/dim1，冻结 makeSlice 的转置约定。

### 3.3 公共方法（签名固定）

```matlab
function obj = QcView(vol, hdr)              % 均可选；空则后续 setVolume
function setVolume(obj, vol, hdr)            % 重置显示变换为 native/中心十字线
function tf = hasVolume(obj)
function [img, info] = slice(obj, orientation, sliceIndex)
%   orientation: 'axial'|'coronal'|'sagittal'（大小写/中文别名可接受）
%   sliceIndex: 1..SliceCount，缺省/越界自动 clamp
%   info 字段（至少）：
%     .Orientation .SliceIndex .SliceCount .ImageSize [nr nc] .PixelSize
%     .XLim [x1 x2] .YLim [y1 y2] .SliceLabel ('Axial z=30/64')
%     .Message .IsNative .XAxisLabel .YAxisLabel  % 如 'L→R' / 'P→A' 由变换自动推断
function info = planeInfo(obj, orientation)  % 只返回网格信息（不采样）
function idx = currentSliceIndex(obj, orientation)     % 十字线所在切片的显示序号
function setSliceIndex(obj, orientation, idx)          % 沿该方向移动十字线（等价鼠标滚切片）
function [img, info] = montage(obj, orientation, n)    % n×n 等间隔切片拼图
%   info.Tiles(k) = struct('SliceIndex', k, 'Row', r, 'Col', c, 'Height', h, 'Width', w,
%                          'XLim',[..], 'YLim',[..]) ；info.Highlight = 当前十字线所在 tile 序号
%   info.ImageSize / .SliceCount / .Message / .Orientation / .N
function setCrosshair(obj, voxel)            % [i j k] 连续 1-based，clamp 到体积内
function p = getCrosshair(obj)               % [i j k]
function p = voxelToWorld(obj, p) ; function p = worldToVoxel(obj, p)
function p = voxelToDisplay(obj, p) ; function p = displayToVoxel(obj, p)  % p 可为 [x y z] 或 [x y z 1]
function setOriginAtWorld(obj, originWorld)  % base='origin'
function setAcPc(obj, acVoxel, pcVoxel)      % base='acpc'；失败返回 info.Message（不抛异常）
function clearAcPc(obj)                      % base 回 native，保留 manual/flips？
function setManual(obj, translationMm, rotationDeg)  % 1x3,1x3；'manual' 不是 base 模式，是叠加项
function setFlips(obj, flipLR, flipAP, flipIS)
function resetDisplay(obj)                   % base=native、manual=0、flips=false、十字线中心
function info = getInfo(obj)
%   info 至少包含：.Mode ('native'|'origin'|'acpc') .HasVolume
%     .CrosshairVoxel .CrosshairWorld .CrosshairDisplay
%     .ACVoxel .ACWorld .PCVoxel .PCWorld .ACPC.distanceMm .ACPC.angleDeg
%     .ACPC.rotationDeg .ACPC.translationMm .DisplayMatrix(4x4) .Manual .Flips
%     .Dim .VoxSize .Message
```

### 3.4 边界与质量要求

- 所有方法对空体积/无效参数不抛异常，返回空值 + `info.Message` 中文原因。
- AC=PC 或距离 < 1e-6 mm：配平失败，`Message='AC 与 PC 距离过小，无法配平'`。
- AC-PC 配平后：`ACWorld` 映射到 display≈[0 0 0]，`PC` 的 display 方向≈-Y（后方），距离保持。2026-11-08勘误：原稿写成+Y，与右/前/上坐标约定冲突，会把正常后方PC旋转接近180°；以当前 `matlab/MRI_Workbench/docs/QC_CONTRACT.md` 为准。
- 十字线在配平后仍以 voxel 为准；`currentSliceIndex` 等自动换算。
- 三正交一致性：同一十字线下，`slice('axial',currentSliceIndex(...))` 的十字线像素位置
  在三种方向的 `info` 中一致（误差 ≤ 1 像素）。
- 单元测试 `tests/test_qc_view.m` 覆盖：native 与 makeSlice 一致；坐标往返误差；
  AC-PC 几何（映射/距离/角度）；手动旋转/平移；翻转；montage tile 布局；
  非法输入；性能（100 次 native 切片 < 1 s，三正交重绘 < 0.4 s）。

## 4. `mrw.QcModel` 增补（view-engine）

保留现有方法签名与行为完全不变，只新增：

```matlab
function fd = loadFdSeries(workDir, subjectID, fdType)
% fdType: 'FD_Jenkinson'（默认）|'FD_Power'|'FD_VanDijk'
% 读取 RealignParameter/<ID>/FD_<type>_<ID>.txt（*通配兜底），每行/每列一个数值；
% 返回 .Available .ID .Type .Values(1xN double) .File .DefaultThreshold
%   （Jenkinson/VanDijk 默认 0.2 mm，Power 默认 0.5 mm）.Message
% 文件缺失返回 Available=false + 中文 Message，不报错。
function hm = headMotionSeries(workDir, subjectIDs)
% 批量：hm.IDs .FD_Jenkinson .FD_Power .FD_VanDijk（cell of 1xN 或 []）.Available
% 供面板表格/曲线一次性取数（可选，若 panel 直接用 loadFdSeries 也可）。
```

`tests/qc_fixture.m` 增补：为 3 名受试者写 `RealignParameter/<ID>/FD_Jenkinson_<ID>.txt`、
`FD_Power_<ID>.txt`（如 60 个数值，含 2–4 个超阈值帧，便于断言坏帧计数），
并在 `qc_fixture` 返回值不变的前提下追加文件。

## 5. QcPanel v2 布局与功能（panel-ui）

窗口建议 `[1440 900]`（QcViewer 默认；主工作台嵌入时自适应）。`Root` 行：
`44 工具条 / '1x' 主体 / 168 头动条（可折叠）/ 28 页脚`；主体三列：
`300 左 / '1x' 中 / 300 右`。

### 5.1 工具条（保持现有 + 新增）

`人工 QC` 标题、工作目录、浏览…、重新扫描、模态下拉、已评分数 badge、
**视图模式下拉**（`单视图/三正交/多切片网格`，Tag `qcViewMode`）、
**复制状态给 Agent** 按钮（Tag `qcCopyState`，写剪贴板 + 提示）。

### 5.2 左列

现有内容 + **筛选下拉**（`全部/仅未评分/已评分/低分≤阈值/MeanFD 超阈值`，Tag `qcFilter`）
+ **排序下拉**（`受试者 ID/评分↑/评分↓/MeanFD↑/MeanFD↓`，Tag `qcSort`）。
受试者表列改为 `受试者 | 评分 | MeanFD`（去掉评语列；评语仍在右列编辑；MeanFD 超阈值红色）。
保留「仅显示未评分」复选框（作为筛选快捷方式，和筛选下拉联动）与阈值下拉、导出按钮。
`rebuildFilteredIndices` 按筛选+排序生成 `FilteredIdx`；`getState().VisibleSubjectCount` 语义不变。

### 5.3 中列（图像区）

- 图像标题行：受试者 · 模态 | 文件名 · 视图说明。
- **图像区改为 uigridlayout 容器**：`单视图` 只显示 `obj.Axes`（保持旧行为/旧断言）；
  `三正交` 显示 2x2：水平位(左上)/冠状位(右上)/矢状位(左下)/第四格为**位置与校准信息面板**
  （体素、世界 mm、显示 mm、AC-PC 状态、显示模式）；`多切片网格` 显示一个 axes 的 montage。
  三正交 axes 各自有标题（Axial z=x/y 等）、十字线（开关，Tag `qcCrosshairCheck`）、
  鼠标点击设置十字线（`displayToVoxel`）。三正交的切片滚动用「活动视图」+ 现有滑条/方向键：
  点击某视图后它成为活动视图，滑条与 ↑/↓ 控制它的切片；`getState()` 给出活动方向。
- **方位校准…** 按钮（Tag `qcAlignButton`）打开 `mrw.QcAlignDialog`（见 §6）。
- 快捷按钮：`重置方位`（Tag `qcResetAlign`，等价 `View.resetDisplay` + 刷新）。
- 现有方向下拉、切片滑条/输入、缩放按钮、窗宽窗位保留；单视图行为与 v1 一致。
- 新增 **色阶下拉**（灰阶/热色/jet，Tag `qcColormap`；默认灰阶）与
  **平滑/最近邻插值下拉**（Tag `qcInterp`，仅非 native 模式生效，默认线性）。
- 新增 **坐标读数行**：`体素 (i,j,k)` / `世界 (x,y,z) mm` / `显示 (x',y',z') mm`（Tag `qcCoordLabel`）。

### 5.4 右列

保留评分区（1–5 单选、评语、保存并下一人、跳过）与显示设置（自动窗宽、重置视图、
模板轮廓开关/透明度、标准化子图下拉）。
新增 **方位校准摘要**：当前显示模式、AC-PC 距离/角度、平移/旋转值（只读，Tag `qcAlignSummary`）。
**方位校准…** 按钮也可放这里（两处都行，Tag 唯一即可）。

### 5.5 底部头动条（新增，Tag `qcMotionPanel`）

- `uiaxes` 逐帧 FD 曲线（Tag `qcFdAxes`）：当前受试者 FD 值折线 + 阈值红虚线 + 坏帧红点；
  x 轴帧号（删点后 1-based）、y 轴 mm。
- 下拉 `FD 类型`（FD_Jenkinson/FD_Power/FD_VanDijk，Tag `qcFdType`）与
  坏帧阈值数字框（默认随类型 0.2/0.5，Tag `qcFdThreshold`）。
- 统计文本：MeanFD、最大 FD、坏帧数/占比、最大平移/旋转（来自 `HeadMotion.tsv`）。
- 表格行/上一人/下一人切换时曲线同步；曲线标题含受试者 ID。
- 与评分联动：低分（≤2）时曲线标题加红色警示文字（确定性，不伪造结论）。

### 5.6 状态文件与「Agent 实时指导」

- 公共方法 `out = exportState(filePath)`：把 `getState()`+QcView 信息写成 JSON（见 §7）；
  内部在 `notifyChangedIfReady` 时自动写 `<workDir>/QC/.qcviewer_state.json`（失败静默，
  不弹窗；工作目录为空时跳过）。
- `getState()` 增补字段（向后兼容，旧字段全保留）：
  `.ViewMode` `.ActiveOrientation` `.CrosshairVoxel` `.CrosshairWorld` `.CrosshairDisplay`
  `.Display`（QcView.getInfo() 的裁剪版本：Mode/HasVolume/ACPC/Manual/Flips/DisplayMatrix/Message）
  `.FD`（.Type/.Threshold/.Values/.MeanFD/.BadFrames/.BadRatio/.MaxFD/.MaxTranslation/.MaxRotation）
  `.Filter` `.Sort` `.VisibleSubjectCount` `.AxesHandles`（若有）`.StateFile`
- 工具栏「复制状态给 Agent」：`clipboard('copy', jsonencode(摘要))` + 页脚提示
  「已复制当前 QC 状态；可在 DSH 对话中让 Agent 读取实时指导」。
- 新公共方法供 QcAlignDialog 调用：
  `setViewMode(mode)`、`setCrosshairVoxel(v)`、`getCrosshairVoxel()`、
  `setOriginAtCrosshair()`、`setACPC(acVoxel, pcVoxel)`、`clearACPC()`、
  `setManualOrientation(tMm, rDeg)`、`resetOrientation()`、`getViewInfo()`、
  `refreshViews()`、`exportState(filePath)`。

### 5.7 快捷键（图像 figure 获得焦点、非文本框时）

`↑/↓` 活动视图切片；`←/→` 受试者；`Home/End` 首末切片；`1–5` 评分；
`Enter` 保存并下一人；`A/C/S` 切换为水平/冠状/矢状活动视图（三正交模式）；
`X` 十字线开关；`R` 重置方位。v1 的键盘行为保留。

## 6. `mrw.QcAlignDialog`（panel-ui）

`+mrw/QcAlignDialog.m`，modeless `uifigure`（`mrw.UiKit.newFigure`），标题
「方位校准（AC-PC / 原点 / 手动）」；构造 `mrw.QcAlignDialog(panel)`，
面板为 `mrw.QcPanel`（只调用 §5.6 公共方法，不碰私有属性）。

UI 内容：
- 坐标读数：体素/世界/显示 mm（随面板 `Changed` 事件刷新）。
- 按钮：`以十字线设原点`、`把当前位置设为 AC`、`把当前位置设为 PC`、`应用 AC-PC 配平`、
  `清除配平`；显示 AC/PC 坐标、AC-PC 距离、配平后 AC 角度/旋转值。
- 6 个 numeric field：平移（右/前/上，mm）、旋转（pitch/roll/yaw，度）；`应用微调` `清零微调`。
- 翻转复选框：左右翻转（放射学↔神经学）、前后翻转、上下翻转。
- 只读显示 4x4 显示矩阵摘要、当前显示模式、说明文字
  「所有调整仅影响显示，不改写图像文件」。
- 控件全部中文 + Tooltip；关闭不销毁面板；面板销毁后对话框自动失效不报错。

## 7. 状态 JSON schema v2（写入 `<workDir>/QC/.qcviewer_state.json`）

```json
{
  "schema": "mrw.qcviewer.state.v2",
  "version": 2,
  "updatedAt": "2026-11-07T21:30:00+08:00",
  "workDir": "D:\\Data\\MyStudy",
  "modality": "T1",
  "modalityLabel": "T1 原始像",
  "subjectID": "Sub01",
  "subjectIndex": 1,
  "subjectCount": 3,
  "file": "T1Img/Sub01/coT1.nii",
  "viewMode": "triple",
  "activeOrientation": "axial",
  "crosshairVoxel": [32, 32, 15],
  "crosshairWorld": [-0.5, 12.3, 8.4],
  "crosshairDisplay": [-0.5, 12.3, 8.4],
  "display": {
    "mode": "acpc", "hasVolume": true,
    "matrix": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
    "acVoxel": [32,32,18], "pcVoxel": [32,32,10],
    "acWorld": [0,0,0], "pcWorld": [0,18,0],
    "distanceMm": 18.0, "angleDeg": 0.0,
    "manualTranslationMm": [0,0,0], "manualRotationDeg": [0,0,0],
    "flips": {"lr": false, "ap": false, "is": false},
    "message": ""
  },
  "slices": {"axial": {"index": 15, "count": 30},
             "coronal": {"index": 32, "count": 64},
             "sagittal": {"index": 32, "count": 64}},
  "window": [2, 98],
  "clim": [0.0, 1000.0],
  "colormap": "gray",
  "interp": "linear",
  "zoom": 1.0,
  "crosshairVisible": true,
  "overlay": {"visible": true, "alpha": 0.55, "normKind": "Fun"},
  "score": {"current": 3, "saved": null},
  "headMotion": {
    "fdType": "FD_Jenkinson", "fdThreshold": 0.2,
    "values": [0.01, 0.02, 0.31, 0.05],
    "meanFD": 0.08, "maxFD": 0.31, "badFrames": [3], "badRatio": 0.05,
    "maxTranslation": 1.2, "maxRotation": 0.6
  },
  "filter": "all", "sort": "id",
  "progress": {"T1": {"scored": 1, "total": 3}, "Fun": {"scored": 0, "total": 3},
               "Norm": {"scored": 0, "total": 3}},
  "message": ""
}
```
- `values` 长度可能较长（逐帧）；完整值可写，Agent 读取时只展示摘要。
- 写入原子性：先写 `.json.tmp` 再 `movefile` 覆盖；失败静默。
- DSH 侧读取时兼容缺失字段；`schema` 不匹配时提示版本。

## 8. DSH 侧（dsh-bridge）

1. `index.mjs` 新增 **Host 工具 `mri_workbench_qcstate`**（不启动 MATLAB）：
   参数 `workDir?`；解析状态 JSON（复用 `resolveQcWorkDir`/`buildQcSummary` 风格），
   返回渲染文本：模态/受试者/视图模式/十字线体素+世界 mm/显示模式/AC-PC 距离与角度/
   平移旋转值/窗宽色阶/叠加/FD 类型与坏帧/评分进度/更新时间；
   文件不存在或过期（>30 min 且无更新）时中文提示「MATLAB QC 窗口未打开或尚未操作」。
   再新增 `mri_workbench_qcstate` 的 `renderQcState` 摘要函数。
2. `index.mjs` 新增命令 `/mri qcstate [工作目录]`（用户可用，文本同工具）。
3. 插件系统提示（`index.mjs` 的 `PROMPT`/`systemPrompt` 段落，搜索「人工 QC」）补充：
   「用户询问 MATLAB 人工 QC 当前画面/如何校准/AC-PC/方位时：先 `matlab_snapshot` 截图，
   再调 `mri_workbench_qcstate` 获取精确状态（十字线、AC/PC、显示矩阵、窗宽、叠加），
   据此给实时指导；不得凭空描述状态。三正交/AC-PC/多切片等新功能在页 ④ 有说明。」
4. `client.js` 页面 ④ 卡：hint 文案更新（三正交/AC-PC/方位校准/多切片/FD 联动/排序筛选/
   复制状态给 Agent）；新增按钮「读取 MATLAB QC 状态」（`/mri qcstate`，Tag `qc-state`）。
5. 文档：
   - `matlab/MRI_Workbench/docs/人工QC使用说明.md` 重写/新增章节：三正交、十字线、原点校准、
     AC-PC 配平、方位调整、多切片网格、FD 曲线与头动联动、排序筛选、导出、
     「Agent 实时指导」用法（DSH 工具/命令/截图）、限制（显示层非破坏性、AC/PC 需人工拾取）。
   - `matlab/MRI_Workbench/docs/人工QC验证记录.md` 追加 v2 记录（谁、日期、测试、截图、限制）。
   - `README.md` §人工 QC 更新；`docs/VERIFICATION.md` 追加本次条目
     （改动文件、测试结果命令与输出、HMR/刷新方式、限制）。
6. 后端测试：`tests/node/qc_state_test.mjs`（Node）——用 fixture 写合法/缺字段/损坏/过期 JSON，
   断言工具/命令输出包含关键字段且不崩溃；`node --check index.mjs client.js` 为 0。

## 9. 验收标准（Lead 复核）

1. `test_qc_view.m`、`test_qc_panel.m`、`test_qc_model.m`、`test_qc_integration_lead.m` 全部 PASS；
   `test_all_lead.m` 10/10（含原有 8 项不回退；新增 test_qc_view / test_qc_ui_v2_accept）。
2. 新截图（tests/ 下）：单视图、三正交+十字线、AC-PC 配平后、多切片网格、FD 曲线+低分联动。
3. 真机验证：MATLAB 桌面打开 `mrw.QcViewer.open(<fixture>)`，人工可见三正交/校准对话框/
   FD 曲线，且 `matlab_snapshot` 能截到；DSH 工具能读到状态 JSON。
4. 无数据/无 AC 拾取/工作目录不存在等边界：中文提示、不崩溃。
5. 不改 DPABI/SPM/研究数据；显示变换不落盘（状态 JSON 除外，位于 QC/ 目录）。
