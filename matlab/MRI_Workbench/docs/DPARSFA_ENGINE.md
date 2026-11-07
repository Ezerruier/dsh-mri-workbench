# DPARSF Advanced Edition（DPARSFA）预处理引擎源码研究

> 目标读者：负责工作台 `mrw.CfgSchema` / `mrw.CfgBuilder` / `mrw.Runner` / `mrw.headlessRunner` 的工程师。
> 本文所有关键结论都标注源码依据；行号均指 **D:\Software\DPABI**（Release `V10.0_260625`）下的文件。
> 配套辅助表（机器可读）：
> - [reference/cfg_fields.tsv](reference/cfg_fields.tsv)：Cfg 字段全表，**131 行**（9 列，含类型/默认/含义/生效条件/坑/源码依据）
> - [reference/run_checks.tsv](reference/run_checks.tsv)：运行前/运行中/运行后校验与失败模式矩阵（22 项，含实测结果）
> - [reference/presets.md](reference/presets.md)：三套可直接运行的 Cfg 预设（经典 / 仅预处理+DARTEL / 快速 QC）
> - [reference/templates_diff.tsv](reference/templates_diff.tsv)：14 个 Jobmats 模板相对 Template_Blank 的全部差异
> - [reference/gui_tag_map.tsv](reference/gui_tag_map.tsv)：原生 GUI 控件 Tag ↔ Cfg 字段映射（含置信度）
> - [reference/experiments.md](reference/experiments.md)：9 组验证实验的命令、结论与原始输出索引（可复现）
> - `tests/tmp_engine_scout/`（开发期临时产物，未随仓库发布）：本文全部验证实验的脚本、日志与输出树（t1_probe / t2_run / t2b_args / t3_errors / t4_figdump / t5_questdlg / t6b_recipe / t7_spawn）

研究日期：2026-11-05；执行环境：MATLAB R2026a（26.1.0.3203278）、SPM12（`spm('Ver')` 返回 **SPM26**）、DPABI V10.0_260625，全部实验在开发期临时目录（`tests/tmp_engine_scout/`，未随仓库发布）内完成，未改动 DPABI 安装目录。

---

## 0. 结论速览（给 Runner 的 12 条硬事实）

1. **可以无 GUI 后台运行**：`matlab.exe -logfile <log> -batch "run('<headlessRunner.m>')"` 已实测跑完一个真实（合成数据）Realign 流程并打印 `Congratulations, the running of DPARSFA is done!!! :)`（`DPARSFA_run.m:5126`）。
2. **Cfg 的 .mat 文件里变量名必须叫 `Cfg`**：`DPARSFA_run.m:34-37` 先 `load` 再取 `Cfg`；叫别的名字会抛 `MATLAB:UndefinedFunction`。
3. **`IsAllowGUI` 必须传数值 `0`**（或 `Cfg.IsAllowGUI=0`）；传字符串 `'0'` 在未编译 MATLAB 里是字符，`if IsAllowGUI` 为真（`double('0')=48`），交互分支仍会执行（`DPARSFA_run.m:51-56`，实测 t2b）。
4. **引擎不做任何启动前校验**：WorkingDir 不存在时死在第一个 `cd()`；`SubjectID={}` 则**静默空跑并打印成功标志**（实测 A/C）。校验必须由 Runner 完成。
5. **`questdlg` 在无 co* T1 时会在 headless 下直接报错**（`-batch` 非交互模式不允许阻塞对话框，实测 t5，报错点 `DPARSFA_run.m:1752`），不会挂起，但会整批失败。
6. **`questdlg` 共 5 处，其中 4 处不受 `IsAllowGUI` 保护**：`:435, :1641, :1752, :2186`（第 5 处 `:1239` 位于 `:1210` 的 IsAllowGUI 保护块内）。这些 co* T1 确认框是“无 GUI 运行”最大的坑。
7. **`TR=0` 必须能从 NIfTI 头读到 `pixdim[4]`**，否则在 `:562` 抛 `Can NOT retrieve the TR information from the NIfTI images`；读到则自动写 `TRInfo.tsv`（实测 t6b：TRSet=2.5）。
8. **并行由 `headlessRunner` 显式控制**：源码里 55 个 `parfor` 在本机默认偏好下会抢先自动建池（实测 24 worker，忽略 `ParallelWorkersNumber`）。工作台已改为：`ParallelWorkersNumber=0` 时关闭自动建池→串行；`N>0` 时由 `headlessRunner` 先按 `min(N, 物理核心数, 被试数)` 显式 `parpool('Processes', N)`（引擎 `:1704-1717` 因已有池而跳过；实测 2 worker 池生效，见 `tests/test_parallel_pool_lead.m`）。
9. **完成标志只有一句日志**，没有状态文件、没有锁文件、没有 per-subject 结果清单；Runner 必须自己写 `status.json` 并解析日志（规则见 §5.4）。
10. **异常分两类**：未捕获的 MATLAB 异常/SPM 作业失败 → 进程退出码 1；`Error` cell 型错误（时间点数不符）→ 打印 `Error in ...` 后提前 `return`，**退出码仍可能是 0**。
11. **输出目录名由 `StartingDirName` 逐级追加后缀决定**：A/R/W/S/D/F/C/B/sym，追加顺序由各步骤的 `Timing` 决定（完整表见 §4.2），`FunImgARWSCF` 这种组合必须能被 Runner 正确拼出。
12. **DARTEL/分割/标准化都依赖结构像链与组内所有被试**：DARTEL 的 `Template_6.*` 只从 `SubjectID{1}` 目录找（`:2423-2430, :3162-3169`），中途加减被试必须整批重跑。

---

## 1. 引擎定位与调用链

### 1.1 文件清单（可读性）

| 路径 | 行数/大小 | 作用 | 可读性 |
|---|---|---|---|
| `D:\Software\DPABI\dpabi.m` | — | DPABI 总入口；`Release='V10.0_260625'`（dpabi.m:58） | 可读 |
| `D:\Software\DPABI\DPARSF\DPARSFA_run.m` | 5127 行 / 352 KB | **Advanced Edition 全部预处理逻辑**，本文研究主体 | 可读 |
| `D:\Software\DPABI\DPARSF\DPARSF_run.m` | 115 行 | Basic Edition 包装器：读模板 → 字段映射 → 调 `DPARSFA_run` | 可读 |
| `D:\Software\DPABI\DPARSF\DPARSFA_RerunWithGSR.m` | 107 行 | 已处理数据“带 GSR 重跑”的官方范式，含目录后缀推导、`global st` 清理 | 可读 |
| `D:\Software\DPABI\DPARSF\DPARSFA.p` | 14 KB | GUI 主回调（Save/Load/各控件同步逻辑） | **不可读（P-code）** |
| `D:\Software\DPABI\DPARSF\DPARSFA.fig` | 79 KB | GUI 布局（119 个 uicontrol/uipanel，已 dump） | 可用 `hgload` 读 |
| `D:\Software\DPABI\DPARSF\SubGUIs\*.m/.fig` | 6 组 | 子界面（Nuisance/FieldMap/ROI/Scrubbing/ReorientThreQC），`.m` 可读 | 可读 |
| `D:\Software\DPABI\DPARSF\Jobmats\*.mat` | 31 个（含 14 个 `Template_*.mat`） | SPM `matlabbatch` 模板（切片/realign/分割/DARTEL/标准化/平滑…），运行时 `load` 后改字段再 `spm_jobman('run')` | 可用 `load` 读 |
| `D:\Software\DPABI\DPARSF\Subfunctions\y_*.m` | 30 个 | 算法实现（`y_alff_falff`、`y_reho`、`y_SCA`、`y_RegressOutImgCovariates`…） | 可读 |
| `D:\Software\DPABI\Utilities\y_Convert_BIDS2DPARSF.m` | — | BIDS → DPARSF 目录结构 | 可读 |

### 1.2 三个入口

```
dpabi.m（GUI 总入口）
  ├─ DPARSFA（Advanced，DPARSFA.p 回调）──► DPARSFA_run(Cfg, WorkingDir, SubjectListFile, IsAllowGUI)
  └─ DPARSF （Basic，DPARSF.p 回调）   ──► DPARSF_run(CfgBasic) ──► DPARSFA_run(Cfg)

脚本方式（推荐给工作台）：
  DPARSFA_run('<...>/cfg.mat', '', '', 0)
```

- `DPARSFA_run.m:1` 签名：`function [Error, AutoDataProcessParameter]=DPARSFA_run(AutoDataProcessParameter,WorkingDir,SubjectListFile,IsAllowGUI)`；4 个参数**全部可选**（内部用 `exist(...,'var')` 判断）。
- `DPARSF_run.m:16-18` 先 `load(Jobmats/Template_CalculateInMNISpace_TraditionalOrder.mat)` 作为底版，再逐字段拷贝 `CfgBasic`，最后 `DPARSF_run.m:113` `[Error]=DPARSFA_run(Cfg)`。
- **重要**：`DPARSF_run` 调用 `DPARSFA_run` 时**只传 1 个参数**，因此 `IsAllowGUI` 走缺省值 1（`DPARSFA_run.m:239-241`）。Basic Edition **无法**关掉 GUI 交互，不适合 Runner；工作台应统一走 `DPARSFA_run`。
- `DPARSF_run` 的字段映射有几个“隐藏语义”：
  - `DPARSF_run.m:40-53`：由 `CfgBasic.IsNormalize` 自动决定 `IsNeedT1CoregisterToFun/IsSegment/IsDARTEL`（1→全关；2→coreg+segment(1)；3→coreg+segment(2)+DARTEL）。
  - `DPARSF_run.m:65`：`Cfg.Covremove.HeadMotion = 4*CfgBasic.Covremove.HeadMotion` —— Basic 里 `1` 会变成 Advanced 的 `4`（Friston 24）。
  - `DPARSF_run.m:73`：`IsCalALFF = CfgBasic.IsCalALFF || CfgBasic.IsCalfALFF`（历史 fALFF 开关合并）。
  - `DPARSF_run.m:95-104`：`IsNormalize==0` 时强制关闭 reorient/Bet/AutoMask/coreg/segment/DARTEL。
  - `DPARSF_run.m:107-108`：强制关闭 VMHC 与对称模板标准化（Basic 不支持）。

### 1.3 运行期数据流（核心心智模型）

```
<DataProcessDir>/<前缀><StartingDirName>/<SubjID>/*.nii
        │ 每一步：把本步结果写到  <前缀><StartingDirName><后缀>/<SubjID>/
        │ 然后 StartingDirName += 后缀（A,R,C,F,W,S,D,B,sym）
        ▼
Results/<measure>_<当前StartingDirName>/   ← 指标图（ALFF/ReHo/DC/FC/…）
ResultsW / ResultsWS                        ← 仅当 Normalize/Smooth.Timing='OnResults'
```

- 所有路径都由 `DataProcessDir` 字符串拼接（不是 `WorkingDir`）；`WorkingDir` 只用于兜底赋给 `DataProcessDir`（`DPARSFA_run.m:39-42,82-84`）。
- 每个功能像步骤都按同一模式工作：`cd` 到 `DataProcessDir/<sessionPrefix><StartingDirName>/<SubjID>` → 收集 `*.img`，否则 `*.nii.gz`（单文件先 gunzip）否则 `*.nii` → 3D（多文件）或 4D（单文件）组装 `FileList` → 改 Jobmat → `spm_jobman('run')` → 按文件名前缀（`r*`/`a*`/`w*`/`s*`/`rp*`/`mean*`）移动到新目录。示例见 `:692-721`（切片）、`:960-1003`（realign）、`:3323-3360`（平滑）。
- 因此 **Runner 若要“续跑”**，只要把 `StartingDirName` 设成上一次停止时的目录名即可；这是官方设计（`DPARSFA_RerunWithGSR.m:18-48` 就是这么做的）。
- 注意 `cd()` 共 68 处，函数返回后 MATLAB 的当前目录是“最后一个 cd 的位置”；脚本不要依赖 `pwd()`。

---

## 2. 后台启动配方（可直接照抄）

### 2.1 已验证的最小命令（独立进程 + 日志文件）

```bat
:: 在 cmd / PowerShell 中（工作台 Runner 用 system()/Start-Process 等价命令）
"D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe" ^
  -logfile "<仓库>\matlab\MRI_Workbench\runs\<runId>\log.txt" ^
  -batch "run('<仓库>\matlab\MRI_Workbench\runs\<runId>\headlessRunner.m')"
```

实测结论（开发期脚本 `tests/tmp_engine_scout/t2_run.m`、`t7_spawn.m`，未随仓库发布）：

| 事实 | 结果 |
|---|---|
| MATLAB 启动开销 | 每次 `-batch` 约 **9–12 s**（`t1_probe` 8.8 s；`t7` 子进程 12 s 内完成） |
| `-logfile` 位置 | 放在 `-batch` **前后都可以**，均能捕获 `disp`、`warning`、未捕获 error |
| 退出码 | 成功 `0`，未捕获异常 `1`（PowerShell `$LASTEXITCODE`/MATLAB `system()` 一致） |
| 日志编码 | **系统本地编码（本机 GBK）**；中文 warning 在日志里是乱码，ASCII 消息正常。解析必须只匹配 ASCII |
| 输出目录 | 必须绝对路径；含空格的路径整体加双引号即可 |
| 从 MATLAB 内分离启动 | `system('start "" /B "<matlab.exe>" -logfile "<log>" -batch "run(''<script>'')"')`，实测 **0.08 s 返回**，子进程独立完成（`t7_spawn.m`） |

> 如果不想用 `-batch` 的规范 `run(...)`，也可以 `-batch "cd('runs\xxx'); headlessRunner"`（`t7_spawn` 使用的方式）。两者等价；`run()` 形式对含空格路径更稳。

### 2.2 `headlessRunner.m` 骨架（参考实现，调用方式均经实测；骨架本身未在工作台内联调）

```matlab
function headlessRunner(cfgFile, statusFile)
% 在独立 MATLAB 进程中执行一次 DPARSFA 预处理；只依赖 cfgFile 与 DPABI/SPM 安装路径。
% 约定：cfgFile 内变量名必须是 Cfg（DPARSFA_run.m:34-37）。
    if nargin < 2, statusFile = ''; end
    % 1) 路径（幂等；用户 path 里通常已有，显式加一遍抗环境差异）
    dpabiRoot = 'D:\Software\DPABI';
    addpath(genpath(dpabiRoot));                 % DPABI 文档要求 add with subfolders
    % spm 路径通常已由用户 path 提供；如需可 addpath(genpath('D:\Software\spm12'))
    assert(~isempty(which('DPABI.m')), 'DPABI 不在 MATLAB 路径上');
    assert(~isempty(which('spm.m')),   'SPM 不在 MATLAB 路径上');

    % 2) 读 Cfg（变量名必须是 Cfg）
    S = load(cfgFile);
    assert(isfield(S, 'Cfg'), 'cfg 文件中缺少变量 Cfg');
    Cfg = S.Cfg;

    % 3) 无 GUI 模式：必须是数值 0（字符串 '0' 是坑，见 t2b）
    Cfg.IsAllowGUI = 0;
    % 4) 清理 SPM 全局（DPARSFA_RerunWithGSR.m:103-104 同款操作）
    global st; st = []; clear st;   %#ok<GVMIS>

    % 5) 运行并落盘状态
    st = struct('State','running','Started',datestr(now,30), ...
                'CfgFile',cfgFile,'Matlab',version,'Pid',feature('getpid'));
    writeStatus(statusFile, st);
    t0 = tic;
    try
        [Error, CfgOut] = DPARSFA_run(cfgFile, '', '', 0);   % 传 Cfg 文件路径亦可
        st.ElapsedSec = toc(t0);
        st.SubjectNum = CfgOut.SubjectNum;
        if isempty(Error)
            st.State = 'done';
        else
            st.State = 'failed'; st.Errors = Error;
        end
    catch ME
        st.ElapsedSec = toc(t0);
        st.State = 'failed';
        st.ErrorIdentifier = ME.identifier;
        st.ErrorMessage = ME.message;
    end
    st.Finished = datestr(now,30);
    writeStatus(statusFile, st);
    if ~strcmp(st.State,'done')
        if ~isfield(st,'ErrorMessage') || isempty(st.ErrorMessage)
            st.ErrorMessage = 'DPARSFA_run 返回了非空 Error（见 status.Errors）';
        end
        writeStatus(statusFile, st);
        error('mrw:headless:failed', '%s', st.ErrorMessage);   % 让 -batch 进程以退出码 1 结束
    end
    fprintf('HEADLESS_RUNNER_STATE=%s\n', st.State);   % 追加一行 ASCII 便于日志解析
end

function writeStatus(f, s)
    if isempty(f), return; end
    fid = fopen(f, 'w'); fprintf(fid, '%s', jsonencode(s)); fclose(fid);
end
```

要点：
- **不要**在 headlessRunner 里再调用 `DPARSF_run`（Basic），它没有 `IsAllowGUI` 通道（§1.2）。
- 不要假设运行结束时的 `pwd`；`cd()` 遍布引擎。
- 一次 `-batch` 只跑一次 `DPARSFA_run`。引擎没有“干净退出”状态，进程内二次调用会有全局状态残留（`global st`、parpool、cwd）。

### 2.3 调用形式与参数覆盖

| 调用形式 | 行为 | 依据 |
|---|---|---|
| `DPARSFA_run(Cfg)` | 用 Cfg 全部字段；`IsAllowGUI` 缺省 = 1 | `:239-241` |
| `DPARSFA_run(cfgFile)` | `load` 后取变量 `Cfg`（**变量名必须为 Cfg**） | `:34-37`，实测 t2 反向验证 |
| `DPARSFA_run(cfgFile, workingDir)` | 同时覆盖 `Cfg.WorkingDir` 与 `Cfg.DataProcessDir`（非空才覆盖） | `:39-42`，实测 t2b D |
| `DPARSFA_run(cfgFile, wd, subjectListFile)` | 再用文本文件（每行一个 ID，`textscan('%s\n')`）覆盖 `SubjectID` | `:44-49` |
| `DPARSFA_run(cfgFile, wd, slf, 0)` | 数值 0 才算关闭 GUI | `:51-56`，实测 t2b B/C |

### 2.4 `IsAllowGUI=0` 到底关掉了什么

| 被 `IsAllowGUI` 保护的行为 | 行号 |
|---|---|
| 交互重定向 T1（`y_spm_image` + `uiwait` + QC 评分） | `:1210` 起整块（`:1288-1300`） |
| 交互重定向功能像 | `:1329` 起整块（`:1403-1415`） |
| 交互 QC 阈值过滤被试（`ReorientThreQC` GUI，会**改写 SubjectID**） | `:1507-1525` |
| coreg 后交互重定向 | `:1940` 起整块 |
| 交互定义 ROI（`inputdlg` + `y_spm_image`） | `:4195` 起整块（`:4203,4222`） |
| 标准化检查图 `PicturesForChkNormalization/*.tif`（功能像阶段） | `:3264-3308` |
| 标准化检查图（Results 阶段） | `:4945-4988` |

**未受 `IsAllowGUI` 保护、headless 下会致命**的对话框（`-batch` 下直接抛“非交互模式不支持阻塞对话框”错误，实测 t5 落在 `:1752`；另外 10 处 `errordlg` 与之一同触发）：

| 位置 | 场景 |
|---|---|
| `:435` | `IsApplyDownloadedReorientMats=1` 且 T1Img 无 `c*`/`*Crop*`（无 IsAllowGUI 保护） |
| `:1239` | 交互重定向 T1（位于 `:1210` 的保护块内，仅 GUI 模式可达；**不属于无保护**） |
| `:1641` | `IsBet=1` 且 T1 无 `c*`（无保护） |
| `:1752` | `IsNeedT1CoregisterToFun=1` 且 T1 无 `c*`（无保护，**本机实测触发点**） |
| `:2186` | `IsSegment>=1` 且 T1 无 `c*`（无保护） |

> 结论：**工作台绝不能靠“无 GUI 自动跳过”来处理 T1**。Runner 必须在启动前保证每个被试的 `T1Img/<ID>/` 里恰好有一个 `c*`/`co*`/`*Crop*` 文件，或设置 `IsNeedReorientCropT1Img=1` 让引擎先生成 `co*`，或设置 `IsBIDStoDPARSF=1`（该分支会内部置 `UseNoCoT1Image=1` 跳过弹窗，`:104-105`）。
> 另一种绕过：由 Runner 在 `DownloadedReorientMats/` 场景外**不启用** T1 链；但这限制太多。

### 2.5 SPM / 全局状态 / 并行注意事项

- **SPM 初始化**：无需显式 `spm('defaults','FMRI')`。`DPARSFA_run.m:73` 会 `spm('Ver')` 触发 SPM 初始化；随后 `spm_jobman('run')` 直接可用（实测 12 个体素的 Realign 完整跑通）。
- **SPM 版本解析**：`:72-78` 取 `spm('Ver')` 末两位数字转 double。本机返回 `SPM26` → `SPMversion=26`，所有 `SPMversion>=12` 的新接口分支生效。换 SPM 版本会改变走 oldseg/oldnorm 还是新接口。
- **SPM 全局 `st`**：`DPARSFA_RerunWithGSR.m:103-104` 明确写了 `global st; st=[]; clear st;`；headlessRunner 建议同样清理。
- **并行**：`ParallelWorkersNumber` 在 DPARSFA_run 内只在 `PCTVer=ver('distcomp')` 非空且**当前没有池**时 `parpool(N)`（`:1699-1717`）；但 55 个 `parfor` 在默认并行偏好下会**抢先自动建池**（实测 24 worker），因此单靠该字段不可控。工作台 `headlessRunner` 已显式处理：`N=0` 时 `ps.Pool.AutoCreate=false` → parfor 串行；`N>0` 时同样关自动建池，并按 `min(N,物理核心数,被试数)` 先建固定大小池（失败则回退串行并写日志）；引擎的建池分支此时因已有池而跳过。副作用：并行模式下日志会出现 DPARSF 的 `parfor` 变量作用域警告（如 `SliceOrder`/`RefFile`/`DirImg`，见 §5.2），属引擎既有行为；内存小（如 24GB）时应限制 N，避免 worker 抢内存。
- **`ver('distcomp')` 在 R2026a 触发弃用警告**（会出现在日志里，不影响功能）；未来 MATLAB 删除该函数后 `ParallelWorkersNumber` 可能失效。
- **外部工具依赖**（决定某些开关能否用）：`IsNeedConvertFunDCM2IMG/IsNeedConvertT1DCM2IMG/IsNeedReorientCropT1Img` → `DPABI\DPARSF\dcm2nii\dcm2niix.exe`（`y_Call_dcm2nii.m:35-53`）；`IsBet` → Windows 用 DPABI 自带 bet（`y_Call_bet.m:48-`），Linux/Mac 用 FSL bet 或 docker；`IsAutoMask` → docker 或 `w_Automask`（`:2097-2122`）。工作台应在 CfgBuilder 里按可用性禁用/提示。
- **日志里的 SPM 噪声**：`spm_jobman` 会在控制台打印 `Initialising batch system... done.`、`Lshuffle = cfg_entry object ...` 等对象转储（实测 transcript 见 §5.2），属正常输出，解析器必须容忍。

## 3. Cfg 结构总览与字段全表

### 3.1 字段盘点（源码口径）

- `DPARSFA_run.m` 中 `AutoDataProcessParameter.<字段>` 共出现 **72 个不同的顶层字段**（含只读/输出字段）；`Template_Blank.mat` 的 `Cfg` 有 **58 个顶层字段 / 99 个叶子字段**。
- `Template_Blank` 是 `Template_CalculateInMNISpace_TraditionalOrder` 等所有模板的**字段超集**（实测 diff 中没有任何 basic 模板独有字段），也覆盖了 `DPARSF_run` 需要的全部基础字段。**CfgBuilder 的最佳策略：`load Template_Blank.mat` 后覆盖目标字段**，可天然规避 §3.1.2 的缺省值陷阱。
- 引擎用 `isfield` 兜底的字段共 40 个（`DPARSFA_run.m:82-241`），其余字段缺失时会直接“变量/字段不存在”报错。两类字段清单如下。

#### 3.1.1 有 `isfield` 兜底的字段（缺失也不会报错）

| 字段 | 缺省 | 行 | 字段 | 缺省 | 行 |
|---|---|---|---|---|---|
| `DataProcessDir` | `=WorkingDir` | 82-84 | `IsWarpMasksIntoIndividualSpace` | 0 | 176-178 |
| `FunctionalSessionNumber` | 1 | 92-94 | `IsDetrend` | 0 | 179-181 |
| `IsNeedConvertFunDCM2IMG` | 0 | 95-97 | `IsCalALFF` | 0 | 185-187 |
| `IsNeedConvertT1DCM2IMG` | 0 | 98-100 | `IsScrubbing` | 0 | 191-193 |
| `IsBIDStoDPARSF` | 0 | 102-106 | `IsCalReHo`（+`CalReHo.SmoothReHo=0`） | 0 | 194-200 |
| `IsApplyDownloadedReorientMats` | 0 | 109-111 | `IsCalDegreeCentrality` | 0 | 202-204 |
| `RemoveFirstTimePoints` | 0 | 115-117 | `IsCalFC` | 0 | 205-207 |
| `IsSliceTiming` | 0 | 118-120 | `CalFC.ROIDef` / `CalFC.ROISelectedIndex` | `{}` / `[]` | 208-217 |
| `IsRealign` | 0 | 121-123 | `IsExtractROISignals` | 0 | 218-220 |
| `IsCalVoxelSpecificHeadMotion` | 0 | 124-126 | `IsDefineROIInteractively` | 0 | 221-223 |
| `IsNeedReorientFunImgInteractively` | 0 | 127-129 | `IsExtractAALTC` | 0 | 224-226 |
| `IsNeedReorientCropT1Img` | 0 | 134-136 | `IsNormalizeToSymmetricGroupT1Mean` | 0 | 227-229 |
| `IsNeedReorientT1ImgInteractively` | 0 | 137-139 | `IsSmoothBeforeVMHC` | 0 | 230-232 |
| `IsBet` | 0 | 140-142 | `IsCalVMHC` | 0 | 233-235 |
| `IsAutoMask` | 0 | 143-145 | `IsCWAS` | 0 | 236-238 |
| `IsNeedT1CoregisterToFun` | 0 | 146-148 | `IsAllowGUI` | **1** | 239-241 |
| `IsNeedReorientInteractivelyAfterCoreg` | 0 | 149-151 | `MaskFile` | `'Default'` | 173-175 |
| `IsSegment` | 0 | 152-154 | `IsFilter` | 0 | 161-163 |
| `IsDARTEL` | 0 | 155-157 | `IsNormalize` | 0 | 164-166 |
| `IsCovremove` | 0 | 158-160 | `IsSmooth` | 0 | 170-172 |

#### 3.1.2 没有兜底、Cfg 必须显式存在的字段

`WorkingDir`、`SubjectID`、`TimePoints`、`TR`（用 `isfield(TR)` 保护，见 `:512`）、`StartingDirName`、`SliceTiming` 子树、`Segment.AffineRegularisationInSegmentation`、`Normalize` 子树、`Smooth` 子树、`Covremove` 子树（启用回归时）、`Filter` 子树（启用滤波时）、`CalALFF` 子树（启用 ALFF 时）、`CalDegreeCentrality` 子树、`CWAS` 子树、`FieldMap` 子树（启用场图时）、`SpecialMode`（`isfield` 保护，缺省按 1 处理）。

> 这些字段在 `Template_Blank.mat` 里都有（除了 `FieldMap`、`SpecialMode`，它们本来就用 `isfield` 判定）。所以“模板 + 覆盖”是最稳的 CfgBuilder 实现。

#### 3.1.3 只读/输出字段（Runner 不要写入，可读取）

| 字段 | 何时写 | 行 |
|---|---|---|
| `SubjectNum` | 函数开头由 `length(SubjectID)` 计算；QC 阈值过滤时还会被改写 | 59, 1507-1525 |
| `TRSet` | `TR==0` 时从 NIfTI 头/`TRInfo.tsv` 填充 | 527-621 |
| `MaskFileForEachSubject` | 掩膜确定后 | 3609-3631 |
| `QC.RawT1ImgQC.{QCScore,QCComment}`、`QC.RawFunImgQC.*` | 仅 GUI 交互重定向时 | 1295-1296, 1410-1411 |
| `CalFC.ROIDefForEachSubject` | ROI 展开后 | 4406 |
| `Covremove.OtherCovariatesROIForEachSubject` | 其他协变量展开后 | 2801, 3710 |
| `ROICenter_/ROIRadius_/ROINumber_DefinedInteractively` | 交互定义 ROI 后 | 4227-4229 |

#### 3.1.4 历史上无效、但旧 Cfg / 旧模板里可能残留的字段

`DPARSFVersion`（引擎不读）、`IsRemoveFirstTimePoints`（引擎 0 命中，真正生效的是 `RemoveFirstTimePoints>0`）、`IsNeedConvert4DFunInto3DImg`、`IsNeedUnzipT1IntoT1Img`、`IsDelFilesBeforeNormalize`、`IsDelDetrendedFiles`、`IsExtractAALTC`、`IsCalfALFF`、`SliceTiming.TR/TA`、`Filter.AMaskFilename/ARetrend/ASamplePeriod`、`CalALFF.ASamplePeriod`、`Covremove.WholeBrain.Method/IsBothWithWithoutGSR`。CfgSchema 可以收录但必须标注“不生效”，避免用户以为改了有用。

### 3.2 Cfg 字段全表（131 行，按类别）

> 列说明：“依据”为 `DPARSFA_run.m` 行号（`:` 前缀）或 `DPARSF_run.m`/其它文件；“默认”取自 `Template_Blank.mat`（若写“字段不存在”表示模板里没有该字段、由 `isfield` 兜底）；“何时生效”给出启用条件。完整可机读版见 [reference/cfg_fields.tsv](reference/cfg_fields.tsv)。

#### 全局

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `DPARSFVersion` | char，如 'V5.5_250415' | 模板内 'V5.5_250415' | 配置版本标记 | 永不生效（引擎不读） | DPABI 安装版为 V10.0_260625，但模板里仍写 V5.5_250415；改它没有任何作用 | DPARSFA_run.m 全文无引用 |
| `WorkingDir` | char 绝对路径 | 模板内是无意义的开发机路径 | 工作目录（用户数据根目录） | 全部步骤 | 引擎不校验存在性；目录缺失时在第一个 cd 处抛 MATLAB:cd:NonExistentFolder | :39-42,82-84 |
| `DataProcessDir` | char 绝对路径 | 缺省=WorkingDir | 真正读写数据的根目录 | 全部步骤 | 与 WorkingDir 可指向不同位置；引擎所有路径都用它拼接；位置参数 WorkingDir 会同时覆盖两者 | :39-42,82-84 |
| `SubjectID` | cellstr | {} | 被试 ID 列表（同时是目录名） | 全部步骤 | 空 cell 不报错并打印 Congratulations（静默空跑，实验 C）；顺序需与目录一致 | :44-49,59 |
| `SubjectNum` | double（只读输出） | 运行时=length(SubjectID) | 被试数 | 运行时赋值 | 不要作为输入；引擎会覆盖 | :59 |
| `FunctionalSessionNumber` | double ≥1 | 1 | 功能像 session 数 | 全部功能像步骤 | 第 2 个 session 起目录必须叫 S2_FunRaw、S3_FunRaw…；不是索引 0 | :92-94,250-253 |
| `StartingDirName` | char | 'FunRaw'（模板） | 起始目录名 | 所有步骤的输入目录 | 支持续跑：FunImg/FunImgA/FunImgAR/FunImgARW…；启用 DICOM 转换或 BIDS 时引擎强制改为 FunImg | :278,334,816,1053,3024,3246,3447,3475,3966,4054,4096,4623,4689,4942,5118 |
| `TimePoints` | double | 0 | 期望时间点数，0=不校验 | 删首点/切片/realign/标准化/平滑前校验 | >0 且与实际不符时写入 Error cell 并在该步后提前 return（不抛异常）；0 时完全不检查 | :635-677,975,3055,3338,4558 |
| `TR` | double 秒 | 0（模板） | 重复时间 | 切片时间、滤波、ALFF、detrend | TR=0 时强制从 NIfTI 头取；头无 timing.tspace 则硬 error 'Can NOT retrieve the TR information from the NIfTI images'（实验 B） | :512-623,791-797,3000,4028 |
| `TRSet` | double 矩阵（输出） | 无 | 每被试每 session 的 TR | TR=0 时自动填充 | Runner 可从返回 Cfg.TRSet 做 QC/日志 | :527-621 |
| `IsAllowGUI` | double 0/1 | 字段缺失时=1 | 0=无 GUI 模式：跳过交互重定向、QC 阈值 GUI 与标准化检查图 | 交互/出图步骤 | 必须传数值 0；传字符串 '0' 在未编译 MATLAB 中为真（double('0')=48，实验 t2b） | :51-56,239-241,1210,1329,1507,1940,3264,4195,4945 |
| `ParallelWorkersNumber` | double | 0 | 并行池 worker 数（0=串行） | 工作台 `headlessRunner` 在 DPARSFA_run 前按 `min(N,物理核心,被试数)` 显式建池；引擎 `:1704-1717` 的 `parpool(N)` 仅在无池时兜底 | 0 不留池→parfor 串行；N 会被上限截断；建池失败自动回退串行并写日志（实测 2 worker 生效） | :1699-1717 |

#### 输入

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsNeedConvertFunDCM2IMG` | double 0/1 | 0 | 功能像 DICOM→NIfTI（dcm2niix 输出到 FunImg/<subj>） | 最前，之后 StartingDirName 强制 FunImg | 需 DPABI/DPARSF/dcm2nii/dcm2niix.exe；DirDCM(3) 取第一个文件，遇到隐藏文件/`.DS_Store` 逻辑脆弱 | :95-97,256-279 |
| `IsNeedConvertT1DCM2IMG` | double 0/1 | 0 | T1 DICOM→NIfTI 到 T1Img/<subj> | 最前 | dcm2niix 不会生成 co*；后续仍可能触发 co* 检查 | :98-100,282-302 |
| `IsNeedReorientCropT1Img` | double 0/1 | 0 | 对 T1Img 里的 NIfTI 再跑 dcm2niix -r Y -x Y，生成 co* 头位/裁剪图 | 转换后、其他 T1 步骤前 | 生成 co* T1 的正规途径，可消除 co* 缺失导致的 headless 弹窗错误 | :134-136,338-360 |
| `IsBIDStoDPARSF` | double 0/1 | 0 | 从 <DataProcessDir>/BIDS 重建 DPARSF 目录结构（FunImg/T1Img/FieldMap） | 最前 | =1 时引擎内部置 UseNoCoT1Image=1（跳过 co* 确认），但要求 BIDS 目录结构存在 | :102-106,331-335 |
| `IsApplyDownloadedReorientMats` | double 0/1 | 0 | 应用 DownloadedReorientMats/ 下预置的 *_ReorientFunImgMat.mat / *_ReorientT1ImgMat.mat | 最前之一 | 目录或文件缺失时静默跳过；该段还有未受 IsAllowGUI 保护的 questdlg（run:435） | :109-111,364-504 |
| `IsNeedConvert4DFunInto3DImg` | —（历史字段） | 无 | 4D→3D 转换开关（代码已注释） | 永不生效 | 4D NIfTI 原生支持；写入无影响 | :112-114（注释） |
| `IsNeedUnzipT1IntoT1Img` | —（历史字段） | 无 | T1 解压开关（已注释） | 永不生效 | 解压逻辑已内置到各步骤 | :131-133（注释） |
| `IsDelFilesBeforeNormalize` | —（历史字段） | 无 | 标准化前删中间文件（已注释） | 永不生效 | 保留中间文件便于断点续跑 | :167-169,3249-3261（注释） |
| `IsDelDetrendedFiles` | —（历史字段） | 无 | 删除 detrend 文件（已注释） | 永不生效 | — | :182-184（注释） |
| `SpecialMode` | double 1/2/3 | 不存在（等价 1） | 1=人；2=猴；3=鼠（切换 TPM/标准化模板/出图底图） | 分割、标准化、出图 | 2/3 需要 DPABI/Templates 下对应模板；Blank 模板无此字段 | :2296-2300,3106-3113,3187-3218,3273-3278 |

#### 时间

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsRemoveFirstTimePoints` | double 0/1 | 0 | GUI 开关；引擎不读 | 不生效 | 真正生效条件只有 RemoveFirstTimePoints>0；两者不一致时以数值为准 | DPARSFA_run.m 全文 0 命中 |
| `RemoveFirstTimePoints` | double ≥0 | 0 | 删除每个 run 前 N 个时间点 | 切片时间之前 | 删除后会把 TimePoints 减 N（run:677）；3D/4D 与 .img 分支行为不同；续跑时不要重复设置 | :115-117,627-678 |
| `IsSliceTiming` | double 0/1 | 0 | 切片时间校正（SPM temporal.st） | realign 之前 | 开启后 StartingDirName 追加 'A'；SliceNumber=0 时依赖 SliceOrderInfo.tsv 或 BIDS json，否则用高风险默认交错序 | :118-120,685-817 |
| `SliceTiming.SliceNumber` | double | 0 | 层数；0=从 NIfTI 头自动读取 | SliceTiming 开启时 | =0 且无 SliceOrderInfo.tsv 时假设 [1:2:N,2:2:N]，参考层=so(ceil(N/2))（run:727-782） | :727-789 |
| `SliceTiming.SliceOrder` | double 向量 | [1:2:33,2:2:32]（33 层示例） | 层采集顺序（1-based） | SliceNumber>0 时使用 | 长度必须等于 SliceNumber，否则 SPM 抛 matlabbatch:run:jobfailederr（实验 E）；模板是 33 层示例，直接沿用极易出错 | :749-769,787-788 |
| `SliceTiming.ReferenceSlice` | double | 0 | 参考层 | SliceNumber>0 时使用 | 0 合法（第一层）；SliceNumber=0 时被自动覆盖为 so(ceil(N/2)) | :782,788 |
| `SliceTiming.TR` | —（历史字段） | 无 | 历史 TR 字段 | 永不生效（DPARSF_run 会复制，引擎不读） | 不要把 TR 写在这里，用顶层 Cfg.TR | :85-91（注释）;DPARSF_run.m:31 |
| `SliceTiming.TA` | —（历史字段） | 无 | 历史 TA 字段 | 永不生效 | 同 SliceTiming.TR | DPARSF_run.m:32 |

#### 头动

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsRealign` | double 0/1 | 0 | SPM realign estimate&reslice | 最早的功能像步骤 | 开启后后缀 'R'；rp_*.txt、mean*.nii 移入 RealignParameter/<subj>；该步产生 FD_Power/FD_Jenkinson/FD_VanDijk | :121-123,951-1153 |
| `IsCalVoxelSpecificHeadMotion` | double 0/1 | 0 | 体素级头动 HMvox_X/Y/Z 与 TDvox/FDvox | realign 之后 | Covremove.HeadMotion 取 11-14 时必需；依赖 RealignParameter/mean* | :124-126,1160-1204 |
| `IsNeedReorientFunImgInteractively` | double 0/1 | 0 | 交互重定向功能像（GUI） | realign 后 | IsAllowGUI=0 时整块被跳过（不报错，静默不做） | :127-129,1327-1499 |
| `IsNeedReorientT1ImgInteractively` | double 0/1 | 0 | 交互重定向 T1，产生 ReorientMats/*.mat 与 QC 评分 | 结构像步骤前 | 要求 T1Img 目录已存在（run:1210）；IsAllowGUI=0 跳过 | :137-139,1208-1324 |
| `IsNeedReorientInteractivelyAfterCoreg` | double 0/1 | 0 | coreg 后交互重定向 | coreg 后 | IsAllowGUI=0 跳过 | :149-151,1938-2075 |

#### 结构

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsBet` | double 0/1 | 0 | 脑提取（Windows 用 DPABI 内置 bet；Linux/Mac 用 FSL bet 或 docker） | realign 后（功能像）+ 结构像 | 输出 T1ImgBet/<subj>/Bet_*；T1 端会先做 co* 检查，headless 下无 co* 会硬报错 | :140-142,1528-1696 |
| `IsAutoMask` | double 0/1 | 0 | 自动脑掩膜（docker 3dAutomask 或 w_Automask） | coreg 后 | 依赖 docker 或本地 w_Automask；输出 Masks/AutoMasks/；WholeBrain.Mask='AutoMask' 时需要它 | :143-145,2082-2130 |
| `IsNeedT1CoregisterToFun` | double 0/1 | 0 | T1 配准到功能空间（SPM coreg.estimate） | realign/bet 后 | 缺 T1Img→cd 硬错误（实验 D）；无 co* 且 T1Img 存在→questdlg，headless 下硬报错（实验 t5）；无 mean 功能像时会现算（仅单 session） | :146-148,1721-1933 |
| `IsSegment` | double 0/1/2 | 0 | 1=旧分割（T1ImgSegment, seg_sn.mat）；2=New Segment（T1ImgNewSegment, seg_sn.mat） | coreg 后；无 T1ImgCoreg 时直接用 T1Img | SPM12 下走 spm.tools.oldseg / spm.spatial.preproc；失败被 try/catch 后重新 error('Error detected during segmentation...') | :152-154,2134-2379 |
| `Segment.AffineRegularisationInSegmentation` | char 'mni'/'eastern'/'subj' | 'mni' | 仿射正则化类型 | 分割 | 猴模式(SpecialMode=2)强制 'subj'；东亚脑用 'eastern' | :2286,2334,2298 |
| `IsDARTEL` | double 0/1 | 0 | DARTEL 建模板 + VBM 结果 MNI 标准化 | Segment(2) 后 | 无 T1ImgNewSegment→cd 硬错误；模板/流场只在 SubjectID{1} 目录找 Template_6.*，被试集合变更后需重跑 | :155-157,2385-2451 |

#### 场图

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `FieldMap.IsNeedConvertDCM2IMG` | double 0/1 | 字段不存在 | 场图 DICOM→NIfTI | 最前 | 需 FieldMap/<measure>Raw 目录 | :304-328 |
| `FieldMap.IsCalculateVDM` | double 0/1 | 不存在 | 计算 VDM | 场图转换后 | 依赖 BIDS json 的 EchoTime/PhaseEncodingDirection/EffectiveEchoSpacing 等 | :825-947 |
| `FieldMap.DataFormat` | char 'PhaseDiff' 或其他 | 不存在 | 场图数据布局（PhaseDiff+Magnitude 或 Phase1/2+Magnitude1/2） | VDM/realign | 只有 'PhaseDiff' 被特判，其余都按 Phase1/2 分支 | :831,872,940 |
| `FieldMap.EPIBasedFieldMap` | double 0/1 | 不存在 | 写入 VDM epifm 参数 | VDM | — | :916 |
| `FieldMap.TE1` | double 秒；0=自动读 json | 不存在 | 回波时间 1 | VDM | 0 时先读 PhaseDiff json 的 EchoTime1，再退回 Magnitude1 json 的 EchoTime | :840-854,887-893 |
| `FieldMap.TE2` | double 秒；0=自动读 json | 不存在 | 回波时间 2 | VDM | 同上（EchoTime2 / Magnitude2） | :855-869,894-900 |
| `FieldMap.IsFieldMapCorrectionUnwarpRealign` | double 0/1 | 不存在 | realign 换成 RealignUnwarp 并带 VDM | realign | 需先算 VDM 并存在 FunFieldMap/VDMImg；字段缺失时等 realign 分支不进入 | :954-996 |

#### 标准化

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsNormalize` | double 0/1/2/3/4 | 0 | 1=EPI 模板；2=分割 seg_sn.mat；3=DARTEL；4=T1 模板（鼠） | 与 Normalize.Timing 联动 | 0=不标准化；>0 才需要 T1 链；DPARSF_run 会据此自动设置 coreg/segment/DARTEL | :164-166,3030-3310,4727-4994 |
| `Normalize.Timing` | char 'OnFunctionalData'/'OnResults' | 'OnResults' | 功能像阶段标准化，还是只对 Results 指标标准化 | IsNormalize>0 时 | 'OnResults' 不改变功能像目录；ALFF/ReHo 等指标若在 MNI 空间计算通常需 'OnFunctionalData' | :3031,4732 |
| `Normalize.BoundingBox` | 2x3 double | [-90 -126 -72;90 90 108] | 标准化输出边界 | 标准化与结果标准化 | 体素尺寸变化时需同步 VoxSize；鼠模式模板里是 NaN | :3102-3103,3159-3160,3370,4809 |
| `Normalize.VoxSize` | 1x3 double | [3 3 3] | 输出体素大小 | 标准化、DARTEL 平滑 | IsSmooth==2（DARTEL 平滑）也用它 | :3103,3160,3371,4859 |
| `IsSmooth` | double 0/1/2 | 0 | 1=SPM 平滑；2=DARTEL 平滑 | 与 Smooth.Timing 联动 | 2 需要 DARTEL/T1ImgNewSegment；平滑后后缀 'S' | :170-172,3318-3448,4998-5120 |
| `Smooth.Timing` | char 'OnFunctionalData'/'OnResults' | 'OnResults' | 平滑阶段 | IsSmooth≥1 时 | 结果平滑只作用于 Results 下指标图（含 m/z 图） | :3319,4999 |
| `Smooth.FWHM` | 1x3 double | [4 4 4] | 高斯核 FWHM mm | 平滑 | ReHo 平滑（CalReHo.SmoothReHo=1）也用这个 FWHM | :3357,4142 |
| `IsWarpMasksIntoIndividualSpace` | double 0/1 | 0 | 掩膜回原空间，在个体空间计算指标/回归 | 依赖分割或 DARTEL | 0 时在 MNI 空间重采样掩膜（AllResampled_*）；1 时要求 WarpedMasks 或分割产物 | :176-178,2575-2683,3567-3631 |
| `MaskFile` | char 'Default'/''/绝对路径 | 'Default' | 脑掩膜（计算指标与回归用） | 指标计算、回归 | 'Default'=Templates/BrainMask_05_91x109x91；用户路径不存在时后续 y_Read 报错 | :173-175,3573-3631 |

#### 回归

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsCovremove` | double 0/1 | 0 | 协变量回归总开关 | 位置由 Covremove.Timing 决定 | 必须与 Timing 配套；AfterNormalize 需要标准化产物与 MNI 掩膜 | :158-160,2489,2807,3487,3716 |
| `Covremove.Timing` | char 'AfterRealign'/'AfterNormalize' | 'AfterRealign' | 回归时机 | IsCovremove=1 时 | 影响目录后缀顺序：AfterRealign→C 早期追加；AfterNormalize→W 先于 C | :2489,2807,3487,3716 |
| `Covremove.PolynomialTrend` | double 0-3 | 1 | 多项式趋势阶数（0=常数，1=+线性，2=+二次，3=+三次） | 回归 | — | :2821,3730 |
| `Covremove.HeadMotion` | double 1/2/3/4/11-14 | 4 | 头动回归模型：1=当前 6 参数；2=当前+上一时刻；3=当前+平方；4=Friston24；11-14=体素级模型 | 回归（需要 realign 产物；11-14 还需体素级头动） | 11-14 时 ImgCovModel=值-10；>4 需要 IsCalVoxelSpecificHeadMotion=1，否则找不到 HMvox_* | :2826-2850,3738-3788 |
| `Covremove.WM.IsRemove` | double 0/1 | 1 | 白质信号是否回归 | 回归 | — | :2889-2924,3828-3879 |
| `Covremove.WM.Mask` | char 'SPM'/'Segment' | 'SPM' | 白质掩膜来源 | 回归 | 'SPM'=Templates/WhiteMask_09_91x109x91（或 Warped/AllResampled）；'Segment'=分割 c2 阈值化图 | :2890-2893,2920-2923,3829-3832 |
| `Covremove.WM.MaskThreshold` | double | 0.99 | 分割掩膜阈值 | Mask='Segment' 时 | — | :2544,3540 |
| `Covremove.WM.Method` | char 'Mean'/'CompCor' | 'Mean' | 白质信号提取方法 | 回归 | CompCor 用 y_CompCor_PC；PC 数取自 CSF.CompCorPCNum（共用字段） | :2889-2911,3858-3866 |
| `Covremove.WM.CompCorPCNum` | double | 5 | CompCor PC 数 | Method='CompCor' 时 | 代码实际用 Cfg.Covremove.CSF.CompCorPCNum（run:2907,3862），WM 自己的值不生效 | :2907,3862 |
| `Covremove.CSF.IsRemove` | double 0/1 | 1 | CSF 信号是否回归 | 回归 | — | :2896-2931,3835-3884 |
| `Covremove.CSF.Mask` | char 'SPM'/'Segment' | 'SPM' | CSF 掩膜来源 | 回归 | — | :2897-2900,2926-2930 |
| `Covremove.CSF.MaskThreshold` | double | 0.99 | 分割掩膜阈值 | Mask='Segment' 时 | — | :2563,3558 |
| `Covremove.CSF.Method` | char 'Mean'/'CompCor' | 'Mean' | CSF 提取方法 | 回归 | — | :2896-2911 |
| `Covremove.CSF.CompCorPCNum` | double | 5 | CompCor PC 数（WM/CSF 实际共用） | Method='CompCor' 时 | WM 和 CSF 同时 CompCor 时 PCs 合并后都按此数量取 | :2907,3862 |
| `Covremove.WholeBrain.IsRemove` | double 0/1 | 0 | 全脑信号（GSR）是否回归 | 回归 | =1 即 GSR，与主流静息态惯例冲突，需明确告知用户 | :2935-2941,3889-3919 |
| `Covremove.WholeBrain.Mask` | char 'SPM'/'AutoMask' | 'SPM' | 全脑掩膜来源 | WholeBrain.IsRemove=1 时 | 'AutoMask' 需要 IsAutoMask=1 产物 | :2936-2939,3890-3893 |
| `Covremove.WholeBrain.Method` | char 'Mean' | 'Mean' | 全脑信号提取方法 | GSR | 代码直接取 Mean；该字段基本无效 | :2935-2941 |
| `Covremove.WholeBrain.IsBothWithWithoutGSR` | double 0/1 | 0 | 先无 GSR 再带 GSR 重跑（GUI 专用） | 引擎不读 | 只被 GUI/DPARSFA_RerunWithGSR.m 使用；写进 Cfg 无效果 | DPARSFA_run.m 全文 0 命中 |
| `Covremove.OtherCovariatesROI` | cell | [] | 其他协变量 ROI：球 [x y z r]、文件或 txt 列表 | Timing 对应阶段 | 支持 'Covariables_List:' txt 指向每被试文件；txt 需放在最后 | :2690-2802,3638-3711 |
| `Covremove.OtherCovariatesROIForEachSubject` | cell（输出） | 无 | 每被试展开后的 ROI 列表 | 运行时生成 | 不要作为输入 | :2801,3710 |
| `Covremove.IsHeadMotionScrubbingRegressors` | double 0/1 | 0 | 把坏时间点作为单独回归量（scrubbing regressors） | 回归时 | 依赖 FDType 对应的 FD 文件存在（RealignParameter/<subj>/FD_*.txt） | :2854-2884,3791-3821 |
| `Covremove.HeadMotionScrubbingRegressors.FDType` | char 'FD_Power'/'FD_Jenkinson' | 'FD_Jenkinson' | FD 类型 | scrubbing regressors/Scrubbing | 文件名由 FDType 直接拼接，拼错会 load 失败 | :2857,4067 |
| `Covremove.HeadMotionScrubbingRegressors.FDThreshold` | double | 0.2 | FD 阈值 | 同上 | — | :2862,3799 |
| `Covremove.HeadMotionScrubbingRegressors.PreviousPoints` | double | 0 | 坏点前扩展点数 | 同上 | — | :2865-2869 |
| `Covremove.HeadMotionScrubbingRegressors.LaterPoints` | double | 0 | 坏点后扩展点数 | 同上 | — | :2870-2875 |
| `Covremove.IsAddMeanBack` | double 0/1 | 0 | 回归后把均值加回，保留原始对比度 | 回归 | — | :2961,3940 |

#### 滤波

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsFilter` | double 0/1 | 0 | 理想带通滤波（y_bandpass） | 位置由 Filter.Timing 决定 | 开启后后缀 'F'；ALFF 在 AfterNormalize 滤波之前计算（band 独立） | :161-163,2992-3026,4023-4056 |
| `Filter.Timing` | char 'BeforeNormalize'/'AfterNormalize' | 'AfterNormalize' | 滤波时机 | IsFilter=1 时 | 影响后缀顺序与是否作用于 MNI 数据 | :2993,4024 |
| `Filter.ALowPass_HighCutoff` | double Hz | 0.1 | 低通上限（高频截止） | 滤波 | 与 AHighPass_LowCutoff 顺序易混：字段名里 ALowPass=低通 | :3006,4036 |
| `Filter.AHighPass_LowCutoff` | double Hz | 0.01 | 高通下限（低频截止） | 滤波 | — | :3007,4037 |
| `Filter.AAddMeanBack` | char 'Yes'/'No' | 'Yes' | 滤波后加回均值 | 滤波 | 字符串型，不是 0/1 | :3008,4038 |
| `Filter.AMaskFilename` | —（历史字段） | 无 | 滤波掩膜（已不使用） | 永不生效 | 滤波调用固定传空掩膜（run:3009） | :3009（注释 3004-3009） |
| `Filter.ARetrend` | —（历史字段） | 无 | 滤波时是否 detrend（已注释） | 永不生效 | detrend 由 IsDetrend / 回归多项式项负责 | :4038（注释） |
| `Filter.ASamplePeriod` | —（历史字段） | 无 | 采样周期（已注释） | 永不生效 | 用 Cfg.TR | :85-91（注释） |
| `IsDetrend` | double 0/1 | 0 | 线性去趋势 | y_bandpass 之前 | 开启后后缀 'D'；若回归中已含线性趋势通常不必开 | :179-181,3455-3476 |

#### 擦洗

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsScrubbing` | double 0/1 | 0 | 按 FD 删除/插值坏时间点 | 指标计算之前（AfterPreprocessing） | 输出 FunImg…B/<subj>/<subj>_4DVolume.nii；后缀 'B' | :191-193,4060-4098 |
| `Scrubbing.Timing` | char 'AfterPreprocessing' | 'AfterPreprocessing' | 擦洗时机 | IsScrubbing=1 时 | 其他值不生效 | :4061 |
| `Scrubbing.FDType` | char 'FD_Power'/'FD_Jenkinson' | 'FD_Jenkinson' | FD 类型 | 擦洗 | 按名字拼文件路径，须与 realign 产出一致 | :4067 |
| `Scrubbing.FDThreshold` | double | 0.2 | FD 阈值 | 擦洗 | — | :4071 |
| `Scrubbing.PreviousPoints` | double | 0 | 坏点前扩展 | 擦洗 | — | :4074-4078 |
| `Scrubbing.LaterPoints` | double | 0 | 坏点后扩展 | 擦洗 | — | :4079-4084 |
| `Scrubbing.ScrubbingMethod` | char 'cut'/'nearest'/'linear'/'spline'/'pchip' | 'cut' | 坏点处理方式（丢弃或插值） | 擦洗 | y_Scrubbing 的第 4 参数 | :4088-4091 |

#### 指标

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsCalALFF` | double 0/1 | 0 | 计算 ALFF/fALFF/m/z 图 | Results 阶段 | 依赖 MaskFileForEachSubject；ALFF 的 band 独立于 Filter | :185-187,3972-4020 |
| `CalALFF.AHighPass_LowCutoff` | double Hz | 0.01 | ALFF 高通下限 | ALFF | — | :3990-3995 |
| `CalALFF.ALowPass_HighCutoff` | double Hz | 0.1 | ALFF 低通上限 | ALFF | — | :3990-3995 |
| `IsCalReHo` | double 0/1 | 0 | 计算 ReHo/mReHo/zReHo | Results 阶段 | 依赖 mask；ReHo 在滤波之后计算 | :194-200,4103-4149 |
| `CalReHo.ClusterNVoxel` | double 7/19/27 | 27 | KCC 邻域体素数 | ReHo | 只能取 7/19/27（GUI 三个单选） | :4111-4114 |
| `CalReHo.SmoothReHo` | double 0/1 | 0 | ReHo 结果再做一次平滑 | ReHo | 用 Smooth.FWHM（run:4142） | :4132-4145 |
| `IsCalDegreeCentrality` | double 0/1 | 0 | 度中心性（加权/二值正相关和） | Results 阶段 | 阈值 rThreshold 只影响加权网络的边 | :202-204,4153-4188 |
| `CalDegreeCentrality.rThreshold` | double | 0.25 | DC 相关阈值 | DC | — | :4162 |
| `IsCalFC` | double 0/1 | 0 | 种子点功能连接（y_SCA，r→z） | Results 阶段 | 必须给 CalFC.ROIDef，否则不计算 | :205-217,4412-4431 |
| `CalFC.IsMultipleLabel` | double 0/1 | 0 | ROI 文件多标签：逐标签提取/计算 | FC/ROI 提取 | — | :4425,4449 |
| `CalFC.ROIDef` | cell | [] | ROI 定义：球 [x y z r]、掩膜文件、时间序列、txt 列表 | FC/ROI 提取 | 球坐标须与当前空间（MNI/个体）一致；txt 里 'Seed_Time_Course_List:'/'Seed_ROI_List:'/'Covariables_List:' 有特殊语义 | :4250-4407 |
| `CalFC.ROISelectedIndex` | cell | {} | 只选部分 ROI 索引 | FC/ROI 提取 | 与 ROIDef 顺序对应 | :4425,4449 |
| `CalFC.ROIDefForEachSubject` | cell（输出） | 无 | 每被试展开后的 ROI 定义 | 运行时生成 | 不要作为输入 | :4406 |
| `IsExtractROISignals` | double 0/1 | 0 | 提取 ROI 时间序列 + 质心 | Results 阶段 | 同样依赖 CalFC.ROIDef；输出 Results/ROISignals_*/ | :218-220,4436-4461 |
| `IsDefineROIInteractively` | double 0/1 | 0 | 交互定义球形 ROI（GUI） | FC 之前 | 要求 IsAllowGUI=1 且 T1ImgCoreg；headless 下整块跳过 | :221-223,4194-4245 |
| `ROICenter_DefinedInteractively` | cell（输出） | 无 | 交互定义 ROI 中心 | 运行时生成 | 不要作为输入 | :4227 |
| `ROIRadius_DefinedInteractively` | double 矩阵（输出） | 无 | 交互定义 ROI 半径 | 运行时生成 | 不要作为输入 | :4228 |
| `ROINumber_DefinedInteractively` | double（输出） | 无 | 交互 ROI 数量 | 运行时生成 | 不要作为输入 | :4229,4252-4254 |
| `IsCalVMHC` | double 0/1 | 0 | 镜像同伦连接（VMHC/zVMHC） | Results 阶段 | 需要对称模板标准化（IsNormalizeToSymmetricGroupT1Mean=1）时效果最好 | :233-235,4697-4720 |
| `IsNormalizeToSymmetricGroupT1Mean` | double 0/1 | 0 | 先建组 T1 均值对称模板再标准化（VMHC 前） | VMHC 前 | 需要 T1ImgSegment/T1ImgNewSegment 的正常化 T1（w*） | :227-229,4487-4625 |
| `IsSmoothBeforeVMHC` | double 0/1 | 0 | VMHC 计算前对功能像平滑 | VMHC 前 | 用 Smooth.FWHM；后缀 'S' | :230-232,4628-4690 |
| `IsCWAS` | double 0/1 | 0 | CWAS 分析（MNI 4mm、单 session） | Results 阶段 | 代码固定只跑 iFunSession=1 | :236-238,4468-4481 |
| `CWAS.Regressors` | matrix | [] | CWAS 回归量 | CWAS | — | :4477 |
| `CWAS.iter` | double | 0 | CWAS 迭代次数 | CWAS | — | :4478 |
| `IsExtractAALTC` | double 0/1 | 0 | 历史字段（AAL 时间序列） | 永不生效 | 只出现在默认值设置里 | :224-226 |
| `QC.RawT1ImgQC.QCScore` | double（输出） | 无 | 交互 T1 重定向的 QC 评分 | 仅 GUI 交互时 | IsAllowGUI=0 时永远为空；写入 QC/RawT1ImgQC.tsv | :1295,1306-1318 |
| `QC.RawT1ImgQC.QCComment` | cell（输出） | 无 | QC 备注 | 仅 GUI 交互时 | 同上 | :1296,1315 |
| `QC.RawFunImgQC.QCScore` | double（输出） | 无 | 交互功能像重定向 QC | 仅 GUI 交互时 | 同上；写入 QC/RawFunImgQC.tsv | :1410,1420-1432 |
| `QC.RawFunImgQC.QCComment` | cell（输出） | 无 | QC 备注 | 仅 GUI 交互时 | 同上 | :1411,1429 |
| `MaskFileForEachSubject` | cell（输出） | 无 | 每被试实际使用的掩膜文件 | 指标计算/回归 | 运行时由 MaskFile + IsWarpMasksIntoIndividualSpace 决定，不要作为输入 | :3609-3631 |

#### 历史

| Cfg路径 | 类型/取值 | 默认 | 中文含义 | 何时生效 | 常见坑 | 依据 |
|---|---|---|---|---|---|---|
| `IsCalfALFF` | double 0/1 | 无 | 旧版 fALFF 独立开关 | 永不生效 | 现 IsCalALFF 同时算 ALFF+fALFF；老 Cfg 可能带此字段，忽略即可 | :188-189（注释） |
| `CalALFF.ASamplePeriod` | — | 无 | 旧版采样周期 | 永不生效 | 用 Cfg.TR；老 Cfg 里可能残留 | :88-90（注释） |

### 3.3 非 Cfg 输入参数（函数位置参数）

| 参数 | 类型 | 语义 | 覆盖关系 | 依据 |
|---|---|---|---|---|
| 第 1 参数 `AutoDataProcessParameter` | struct 或 char | Cfg 结构；若为 char 则当作 .mat 路径 `load` | —（**变量名必须是 Cfg**） | `DPARSFA_run.m:34-37` |
| 第 2 参数 `WorkingDir` | char | 覆盖工作目录 | 同时覆盖 `Cfg.WorkingDir` 和 `Cfg.DataProcessDir` | `:39-42` |
| 第 3 参数 `SubjectListFile` | char | 被试列表文本文件（每行一个 ID，`textscan('%s\n')`） | 覆盖 `Cfg.SubjectID` | `:44-49` |
| 第 4 参数 `IsAllowGUI` | 数值 0/1（**不要传字符串**） | 0=无 GUI | 覆盖 `Cfg.IsAllowGUI` | `:51-56` |

### 3.4 返回值

`[Error, AutoDataProcessParameter] = DPARSFA_run(...)`：

- `Error`：初始 `[]`；出错时变成 **cell 列向量**，元素形如 `'Error in Realign, time point number doesn''t match: S01'`（`:636,706,975,3048,3338,4558,4646`）。空 cell 与 `[]` 都表示“没有记录到错误”，**但空 SubjectID 也会返回空 Error**（静默空跑），不能只凭 Error 判断成功。
- 第二个返回值是**被引擎就地修改过的 Cfg**（`StartingDirName` 最终会变成 `'Results'` 或 `'ResultsW'` 等，`SubjectID` 可能被 QC 过滤，`TRSet`/`MaskFileForEachSubject` 被填充）。不要把它当“原配置”回写。
- 示例（实测 t2）：`Error=[]`，`CfgOut.SubjectNum=1`，`CfgOut.StartingDirName='Results'`，`CfgOut.IsAllowGUI=0`。

---

## 4. 目录与文件约定

### 4.1 输入目录树（DPARSF 布局）

```
<DataProcessDir>/
  FunRaw/<SubjID>/                 ← 功能像原始（DICOM 或 NIfTI），或 S2_FunRaw、S3_FunRaw…
  T1Raw/<SubjID>/                  ← T1 原始 DICOM（IsNeedConvertT1DCM2IMG=1 时）
  T1Img/<SubjID>/                  ← T1 NIfTI；后续步骤优先找 c*/co*/*Crop*
  FieldMap/<measure>{Raw,Img}/<SubjID>/   ← measure ∈ PhaseDiff/Magnitude1/Magnitude2/Phase1/Phase2
  FunFieldMap/<measure>/<SubjID>/  ← VDM 计算实际读取的位置（注意与 FieldMap 不同，见坑 #5）
  BIDS/                            ← IsBIDStoDPARSF=1 时的输入；处理后会生成 FunImg/T1Img/…
  DownloadedReorientMats/          ← IsApplyDownloadedReorientMats=1：<SubjID>_Reorient{Fun,T1}ImgMat.mat
  TRInfo.tsv                       ← 可选输入（TR=0 时优先读取）
  SliceOrderInfo.tsv               ← 可选输入（切片顺序）
  TRSet.txt                        ← 旧版输入（已废弃，仍兼容）
```

要点：

> ⚠ **目录方向容易写反**：DPARSF 的布局是 **`<DataProcessDir>/FunRaw/<SubjID>/`**（“模态目录在前、被试目录在后”），依据 `DPARSFA_run.m:259,263,286-294`（`[DataProcessDir,filesep,'FunRaw',filesep,SubjectID{i}]`）。不是 `<WorkDir>/<SubjID>/FunRaw/`。另外源码里只有 `T1Raw`/`T1Img`，**没有 `AnatRaw`**；`y_Convert_BIDS2DPARSF` 的输出同样遵循“模态在前”。

- **DICOM**：引擎取 `FunRaw/<ID>/` 的 `dir()` 第 3 项（`.DS_Store` 时为第 4 项）作为“第一个文件”交给 `dcm2niix` 处理整个目录（`:263-272`、`:288-297`）。因此该目录里**只能放 DICOM**，混入 nii/json 会改变 `dir` 顺序甚至被误当 DICOM。
- **NIfTI**：每个被试目录可以是“单个 4D `.nii`/`.nii.gz`”或“多个 3D `.nii`/`.img+.hdr`”；代码优先 `*.img`，否则 `*.nii.gz`（单文件先 gunzip 再删），否则 `*.nii`。**两种格式不要混放**（`:551-558, 693-702`）。
- **多 session**：session 1 目录无前缀；session `i≥2` 必须是 `<DataProcessDir>/S{i}_FunRaw/<SubjID>/`（`:250-253`）。功能像与结构像的 session 前缀规则只作用于功能像。
- **BIDS**：`IsBIDStoDPARSF=1` 时调用 `y_Convert_BIDS2DPARSF(<DataProcessDir>/BIDS, <DataProcessDir>, SubjectID)`，复制 `sub-*/[ses-*/]anat/*_T1w.nii*` → `T1Img/`、`func/*.nii*` + 同名 `.json` → `FunImg/`（`y_Convert_BIDS2DPARSF.m:22-75`），随后 `StartingDirName` 强制 `'FunImg'`（`:334`）。BIDS 分支还会把 json 保留下来供切片时间/场图使用。
- **T1 命名要求**：所有结构像相关步骤都按 `c*.img` → `c*.nii.gz` → `c*.nii` → `*Crop*.nii` 的顺序找 T1（`:410-421, 1414-1421`）；找不到时进入 questdlg（headless 致命）。**`co*` 是 dcm2niix 的 crop+reorient 产物，是 DPARSF 期望的 T1 形态**。
- **TRInfo.tsv / SliceOrderInfo.tsv** 放在 `DataProcessDir` 根目录，不是被试目录。

### 4.2 `StartingDirName` 的字母缩写与后缀追加顺序（Runner 必读）

官方文档给出的缩写：**A** 切片时间、**R** realign、**W** 标准化、**S** 平滑、**D** detrend、**F** 滤波、**C** 协变量回归、**B** scrubbing、**sym** 对称模板标准化。
但**追加顺序不是字母序，而是代码执行顺序**，且受各步骤 `Timing` 影响。完整顺序（源码顺序）：

| # | 后缀 | 条件 | 行号 |
|---|---|---|---|
| 1 | `A` | `IsSliceTiming==1` | 816 |
| 2 | `R` | `IsRealign==1` | 1053 |
| 3 | `C` | `IsCovremove==1 && Covremove.Timing=='AfterRealign'` | 2987 |
| 4 | `F` | `IsFilter==1 && Filter.Timing=='BeforeNormalize'` | 3024 |
| 5 | `W` | `IsNormalize>0 && Normalize.Timing=='OnFunctionalData'` | 3246 |
| 6 | `S` | `IsSmooth>=1 && Smooth.Timing=='OnFunctionalData'` | 3447 |
| 7 | `D` | `IsDetrend==1` | 3475 |
| 8 | `C` | `IsCovremove==1 && Covremove.Timing=='AfterNormalize'` | 3966 |
| 9 | `F` | `IsFilter==1 && Filter.Timing=='AfterNormalize'` | 4054 |
| 10 | `B` | `IsScrubbing==1` | 4096 |
| 11 | `sym` | `IsNormalizeToSymmetricGroupT1Mean==1` | 4623 |
| 12 | `S` | `IsSmoothBeforeVMHC==1` | 4689 |
| 13 | （重置为 `Results`） | 无条件 | 4729 |
| 14 | `W` | `IsNormalize>0 && Normalize.Timing=='OnResults'` | 4942 |
| 15 | `S` | `IsSmooth>=1 && Smooth.Timing=='OnResults'` | 5118 |

推论：
- 经典预设（回归/滤波都在标准化后）= `FunRaw → FunImgA → FunImgAR → FunImgARW → FunImgARWS → FunImgARWSC → FunImgARWSCF`。
- `template_CalculateReHoDC` 的 `StartingDirName='FunImgARCW'` 说明它把回归放在 realign 之后（`AfterRealign`），因此 C 在 W 之前。
- 只要 `IsNeedConvertFunDCM2IMG==1` 或 `IsBIDStoDPARSF==1`，`FunRaw` 在第一段之后就被强制改成 `FunImg`（`:278, :334`），之后才是 A/R/…。
- Runner 做“从某一步续跑”时，直接把 `StartingDirName` 设成上表拼出的目录名；引擎会从该目录继续，不会重跑前面的步骤。

### 4.3 输出目录与文件（按步骤）

| 步骤 | 产物目录/文件（相对 `DataProcessDir`） | 依据 |
|---|---|---|
| DICOM→NIfTI | `FunImg/<ID>/*.nii`、`T1Img/<ID>/*.nii` | 261-274, 286-299 |
| Crop T1 | `T1Img/<ID>/co*.nii`（或 `*Crop*.nii`） | 340-360 |
| TR 采集 | `TRInfo.tsv`（列：Subject ID、各 session TR、Slice Number、Time Points、Voxel Size） | 583-618 |
| 删首点 | 就地覆盖原目录文件 | 628-678 |
| 切片时间 | `<prefix>FunImgA/<ID>/{a*,aa*}` | 804-816 |
| Realign | `<prefix>FunImgAR/<ID>/r*`；`RealignParameter/<ID>/{rp_*.txt,mean*.nii,FD_Power_*.txt,FD_Jenkinson_*.txt,FD_VanDijk_*.txt}`；`RealignParameter/HeadMotion.{tsv,mat}`；`RealignParameter/ExcludeSubjectsAccordingToMaxHeadMotion.txt`；`RealignParameter/*.ps`（若产生） | 1006-1053, 1056-1151 |
| 体素级头动 | `<prefix>VoxelSpecificHeadMotion/<ID>/`；`Results/MeanVoxelSpecificHeadMotion_Mean{TD,FD}vox/Mean*_<ID>.nii` | 1177-1199 |
| Bet | `RealignParameter/<ID>/Bet_mean*.img`；`T1ImgBet/<ID>/Bet_*` | 1599-1603, 1684-1690 |
| T1→Fun coreg | `T1ImgCoreg/<ID>/*` | 1772-1807 |
| AutoMask | `Masks/AutoMasks/[prefix]AutoMask_<ID>.nii` | 2085-2095 |
| Segment | `T1ImgSegment/<ID>/`（`c1-c3`、`*seg_sn.mat`、`*seg_inv_sn.mat`）或 `T1ImgNewSegment/<ID>/`（`c1-c3`、`rc1/rc2`、`u_*`、`*seg_sn.mat`、`Template_6.*`、`Template_6_2mni.mat`） | 2135-2403 |
| DARTEL | `T1ImgNewSegment/<ID>/Template_6*`、`u_*`、`Template_6_2mni.mat`；VBM 结果（`wc1/wc2/wc3`、`w*T1`） | 2385-2451 |
| 分割掩膜（功能空间） | `Masks/SegmentationMasks/FunSpace_[ThrdMask_]<ID>_{WM,CSF}.nii` | 2528-2563 |
| 掩膜回原空间 | `Masks/WarpedMasks/<ID>_{Brain,Csf,White,Grey}Mask*.nii`、`OtherCovariateROI_*`、`FCROI_*`、`ROIDefinedInteractively_*` | 2579-2683, 4250-4407 |
| 回归 | `<prefix><当前Dir>C/<ID>/` 下的回归后功能像；`<prefix><当前Dir>Covs/{ROISignals_<ID>.txt,Covariables<ID>.{mat,txt}}` | 2949-2987, 3928-3966 |
| 滤波 | `<...>F/<ID>/` | 3013-3026, 4043-4056 |
| 标准化（功能像） | `<...>W/<ID>/w*`；`PicturesForChkNormalization/<ID>.tif`（仅 IsAllowGUI=1） | 3237-3308 |
| 平滑（功能像） | `<...>S/<ID>/s*` | 3432-3447 |
| Detrend | `<...>D/<ID>/` | 3464-3476 |
| Scrubbing | `<...>B/<ID>/<ID>_4DVolume.nii` | 4086-4096 |
| 指标计算 | `Results/ALFF_<Dir>/{ALFF,fALFF,mALFF,mfALFF,zALFF,zfALFF}Map_<ID>.nii`；`Results/fALFF_<Dir>/*`；`Results/ReHo_<Dir>/{ReHo,mReHo,zReHo}Map_<ID>.nii`；`Results/DegreeCentrality_<Dir>/*Map_<ID>.nii`；`Results/FC_<Dir>/FCMap_<ID>*`；`Results/ROISignals_<Dir>/{<ID>*,ROI_CenterOfMass_<ID>*,…}`；`Results/CWAS_<Dir>/CWAS.nii`；`Results/VMHC_<Dir>/{VMHC,zVMHC}Map_<ID>.nii` | 3977-4019, 4106-4148, 4156-4187, 4415-4431, 4440-4459, 4471-4478, 4700-4716 |
| 结果标准化/平滑 | `ResultsW/<measure>/`；`ResultsWS/<measure>/` | 4934-4942, 5105-5118 |
| 对称模板 | `SymmetricGroupT1MeanTemplate/{GroupT1MeanTemplate,SymmetricGroupT1MeanTemplate}.nii` | 4492-4538 |
| 交互相关 | `ReorientMats/<ID>_{ReorientT1ImgMat,ReorientFunImgMat,ReorientT1FunAfterCoregMat}.mat`；`QC/Raw{T1,Fun}ImgQC.tsv`；`ROI_DefinedInteractively.tsv` | 1258-1318, 1384-1432, 1987-2007, 4233-4243 |

### 4.4 关键文本文件格式

**`TRInfo.tsv`**（实测 t6b 生成，`:583-618`）：
```
Subject ID	TR	Slice Number	Time Points	Voxel Size
S01	2.5	10	8	1 1 1
```
多 session 时表头变为 `S2_TR`、`S2_Slice Number`…（`:585-597`）。若该文件已存在且 `TR==0`，引擎改为读取它并要求当前每个被试都在表内（`:515-537`）。

**`SliceOrderInfo.tsv`**（输入，`:736-771`）：第 1 列 Subject ID，第 2..N 列为各 session 的切片序定义，取值 `IA/IA2/ID/ID2/SA/SD`，或一个“可被 `load` 的文本文件路径”。行顺序必须与被试顺序一致，否则 `:745-747` 报错。

**`HeadMotion.tsv`**（`:1121-1129`）：21 列，第 1 列 Subject ID，其余依次为 max(|Tx..Rz|)、mean(|Tx..Rz|)、mean RMS、mean FD_VanDijk、mean FD_Power、FD_Power>0.5 计数/百分比、FD_Power>0.2 计数/百分比、mean FD_Jenkinson（表头见 `:1123`）。这是工作台“快速 QC”最该直接展示的表。

**`ExcludeSubjectsAccordingToMaxHeadMotion.txt`**（`:1132-1150`）：按 3.0→0.5 mm/deg、步长 0.5 列出每个阈值下的候选剔除被试。

---

## 5. 运行流程与日志

### 5.1 步骤执行顺序（引擎实际顺序；含触发条件）

| # | 步骤 | 触发 | 行号 |
|---|---|---|---|
| 1 | 功能像 DICOM→NIfTI | `IsNeedConvertFunDCM2IMG==1` | 256-279 |
| 2 | T1 DICOM→NIfTI | `IsNeedConvertT1DCM2IMG==1` | 282-302 |
| 3 | FieldMap DICOM→NIfTI | `isfield(FieldMap) && FieldMap.IsNeedConvertDCM2IMG==1` | 304-328 |
| 4 | BIDS→DPARSF | `IsBIDStoDPARSF==1` | 331-335 |
| 5 | T1 crop/reorient | `IsNeedReorientCropT1Img==1` | 338-360 |
| 6 | 应用下载的重定向矩阵 | `IsApplyDownloadedReorientMats==1` | 364-504 |
| 7 | TR 采集 + `TRInfo.tsv` | `isfield(TR) && TR==0`（且起始目录不是 T1） | 510-624 |
| 8 | 删首时间点 | `RemoveFirstTimePoints>0` | 627-682 |
| 9 | 切片时间校正 | `IsSliceTiming==1` | 685-821 |
| 10 | FieldMap VDM | `FieldMap.IsCalculateVDM==1` | 825-947 |
| 11 | Realign + 头动指标 | `IsRealign==1` | 951-1157 |
| 12 | 体素级头动 | `IsCalVoxelSpecificHeadMotion==1` | 1160-1204 |
| 13 | 交互重定向 T1 | `IsNeedReorientT1ImgInteractively==1 && IsAllowGUI && T1Img 存在` | 1208-1324 |
| 14 | 交互重定向功能像 | `IsNeedReorientFunImgInteractively==1 && IsAllowGUI` | 1327-1503 |
| 15 | 按交互 QC 阈值过滤被试（**改写 SubjectID**） | 12/13 任一为真且 `IsAllowGUI` | 1506-1525 |
| 16 | Bet | `IsBet==1` | 1528-1696 |
| 17 | 建立 parpool（工作台已在 headlessRunner 预建；此处为无池兜底） | PCT 存在且 `ParallelWorkersNumber~=0` | 1699-1717 |
| 18 | T1→Fun coreg | `IsNeedT1CoregisterToFun==1` | 1721-1933 |
| 19 | coreg 后交互重定向 | `IsNeedReorientInteractivelyAfterCoreg==1 && IsAllowGUI` | 1938-2078 |
| 20 | AutoMask | `IsAutoMask==1` | 2082-2130 |
| 21 | 分割（旧/新） | `IsSegment>=1` | 2134-2379 |
| 22 | DARTEL（建模板+标准化 VBM） | `IsDARTEL==1` | 2385-2451 |
| 23 | 统一分割的 T1 标准化 | `IsSegment==1` | 2458-2479 |
| 24 | 分割掩膜→功能空间 | `IsCovremove && Timing=='AfterRealign'` | 2489-2568 |
| 25 | 掩膜回个体空间 | `IsWarpMasksIntoIndividualSpace==1` 或（回归 AfterRealign） | 2579-2683 |
| 26 | 其他协变量 ROI 回个体空间 | `IsCovremove && (AfterRealign || IsWarpMasksIntoIndividualSpace)` | 2688-2803 |
| 27 | 回归（AfterRealign） | `IsCovremove && Timing=='AfterRealign'` | 2807-2989 |
| 28 | 滤波（BeforeNormalize） | `IsFilter && Timing=='BeforeNormalize'` | 2993-3026 |
| 29 | 标准化（功能像） | `IsNormalize>0 && Timing=='OnFunctionalData'` | 3031-3314 |
| 30 | 平滑（功能像） | `IsSmooth>=1 && Timing=='OnFunctionalData'` | 3319-3452 |
| 31 | Detrend | `IsDetrend==1` | 3457-3476 |
| 32 | 分割掩膜→MNI 功能空间 | `IsCovremove && Timing=='AfterNormalize'` | 3487-3563 |
| 33 | 掩膜重采样（MNI 空间计算时） | `IsWarpMasksIntoIndividualSpace==0 && 任一指标/回归` | 3571-3606 |
| 34 | 每被试掩膜确定 | 无条件（生成输出字段） | 3609-3631 |
| 35 | 其他协变量 ROI 重采样 | `IsCovremove && AfterNormalize && IsWarpMasksIntoIndividualSpace==0` | 3636-3712 |
| 36 | 回归（AfterNormalize） | `IsCovremove && Timing=='AfterNormalize'` | 3716-3968 |
| 37 | ALFF/fALFF | `IsCalALFF==1` | 3973-4020 |
| 38 | 滤波（AfterNormalize） | `IsFilter && Timing=='AfterNormalize'` | 4024-4056 |
| 39 | Scrubbing | `IsScrubbing==1 && Timing=='AfterPreprocessing'` | 4060-4098 |
| 40 | ReHo | `IsCalReHo==1` | 4103-4149 |
| 41 | Degree Centrality | `IsCalDegreeCentrality==1` | 4153-4188 |
| 42 | 交互定义 ROI | `IsDefineROIInteractively==1 && IsAllowGUI` | 4194-4245 |
| 43 | 生成每被试 ROI 掩膜 | `~isempty(CalFC.ROIDef) || IsDefineROIInteractively` | 4250-4407 |
| 44 | FC（SCA） | `IsCalFC==1` | 4412-4431 |
| 45 | 提取 ROI 时间序列 | `IsExtractROISignals==1` | 4436-4461 |
| 46 | CWAS | `IsCWAS==1`（固定只跑 session 1） | 4468-4481 |
| 47 | 对称模板标准化 | `IsNormalizeToSymmetricGroupT1Mean==1` | 4487-4625 |
| 48 | VMHC 前平滑 | `IsSmoothBeforeVMHC==1` | 4628-4690 |
| 49 | VMHC | `IsCalVMHC==1` | 4697-4720 |
| 50 | 结果标准化（OnResults） | `IsNormalize>0 && Timing=='OnResults'` | 4732-4990 |
| 51 | 结果平滑（OnResults） | `IsSmooth>=1 && Timing=='OnResults'` | 4998-5120 |
| 52 | 完成标志 | 无条件（走到函数末尾） | 5126 |

> 注意第 7 步在第 8 步之前：**`TR=0` 的自动读取发生在删首时间点之前**，读取的是原始时间点数；`RemoveFirstTimePoints` 之后 `Cfg.TimePoints` 才减 N（`:677`）。

### 5.2 实测日志样本（真实 transcript；输出文件为开发期临时产物，未随仓库发布）

```
[警告: 文件: D:\Software\DPABI\DPARSF\DPARSFA_run.m 行: 751 列: 29
临时变量 'SliceOrder' 将在 parfor 循环的每次迭代开始时被清除。…]            ← MATLAB 本地化警告，可忽略
正在使用 'Processes' 配置文件启动并行池(parpool)...
已连接到具有 24 个工作单元的并行池。                                          ← 自动建池（ParallelWorkersNumber=0 也会发生）
Realign Setup:S01 OK                                                          ← 步骤消息（ASCII）
Initialising batch system... done.
Lshuffle =                                                                    ← SPM 批处理内部对象转储，噪声
cfg_entry object: 1-by-1
…
------------------------------------------------------------------------
05-Nov-2026 23:24:51 - Running job #1
------------------------------------------------------------------------
05-Nov-2026 23:24:51 - Running 'Realign: Estimate & Reslice'
SPM26: spm_realign                                 23:24:52 - 05/11/2026
========================================================================
Completed                               :          23:24:52 - 05/11/2026
…
05-Nov-2026 23:24:52 - Done    'Realign: Estimate & Reslice'
Moving Head Motion Corrected Files:S01 OK                                     ← 步骤消息
[警告: 对 ver('distcomp') 的支持将在以后的版本中删除。请改用 ver('parallel')。]
Congratulations, the running of DPARSFA is done!!! :)                        ← 唯一完成标志
```

**进度条/waitbar 行为**：`DPARSFA_run.m` 全文 **没有 waitbar/进度条调用**（`waitbar`/`spm_progress_bar` 0 命中），`IsAllowGUI=0` 与否都不显示进度；进度只能从日志推断。SPM 作业内部也不打印百分比，只打印模块开始/完成时间戳。因此 Runner 的进度条只能是“步骤级 + 被试级”的估算（见 §5.4）。

实测时长：12 个时间点 × 16×16×10 合成数据、仅 Realign、24-worker 自动池，**35.5 s**（含 MATLAB 启动与建池）。

### 5.3 完成/失败判定

| 判定 | 依据 |
|---|---|
| 成功 | 退出码 0 **且** 日志含 `Congratulations, the running of DPARSFA is done!!! :)`（`:5126`）**且** 日志无 `Error in ` 行 **且** 无 `Job execution failed` |
| 记录型错误（可能仍退出 0） | 日志出现 `Error in ` 开头的 Error cell 内容；引擎在该步骤结束后 `disp(Error); return`（`:679-682, :818-821, :1154-1157, :3311-3314, :3449-3452, :4991-4994, :5121-5124`），**不会打印 Congratulations** |
| 硬失败 | MATLAB 退出码 1，日志含 `{` 包起来的错误文本 + `错误使用 …`/`Error using …` 堆栈；SPM 作业失败还会打印 `Failed  '<模块>'` 与 `The following modules did not run:` |
| 静默空跑 | 打印 `Congratulations` 但什么都没做（`SubjectID={}`，实测 C）。必须靠“产物存在性 + 声明的被试数”二次校验 |
| 被中断 | 无完成标志、无退出码（进程被杀）→ Runner 自行判定 `killed` |

### 5.4 日志解析规则（Runner 可直接采用）

1. **只匹配 ASCII 文本**：DPARSF/SPM 的消息是 ASCII；MATLAB 的 `warning`/`error` 前缀会被本地化（中文/乱码），不要依赖中文。日志文件用 `-logfile` 写出时是系统本地编码（GBK），`fileread` 读入后中文会乱码，但 ASCII 部分不受影响。
2. **步骤状态机**：维护“当前步骤索引”，只在命中列表里**向前**推进（步骤顺序见 §5.1）；同一行可同时命中“步骤消息”和“被试完成”。
3. **被试完成数**：不要用行数，用“命中的 SubjectID 集合”。因为 `parfor` 的执行顺序不确定，且同一步骤会打印多条消息（如 Realign 有 Setup/Moving 两条）。
4. **进度百分比**：引擎不提供；建议用 `已完成步骤数/总启用步骤数` 为主、当前步骤内被试完成数为辅，并向用户标注“估算”。
5. **错误聚合**：`Error in ` 开头的行收集为记录型错误；`Job execution failed` / `The following modules did not run` / `This subject failed segmentation:` 为致命；`Mismatch between number of slices` 是切片顺序配置错。
6. **忽略噪声**：`Initialising batch system... done.`、`Lshuffle = cfg_entry object` 之后的整对象转储、`Running job #N`、SPM 的 `====` 行、本地化 warning。可只保留“命中规则表”的行，其余放 debug 级日志。
7. **保留原文**：把原始日志整份落盘（`runs/<id>/log.txt`），解析结果另存 `status.json`，便于复盘。

参考伪代码：

```matlab
% STEPS: N×2 cell {needle, key}，按执行顺序排列
state = struct('stepIdx',0,'stepKey','','doneSubjects',{{}},'errors',{{}},'fatal',false,'done',false);
subjectIDs = Cfg.SubjectID;
while ~feof(fid)
    line = fgetl(fid);  if ~ischar(line), break; end
    if contains(line, 'Congratulations, the running of DPARSFA is done!!! :)')
        state.done = true; continue
    end
    for k = state.stepIdx+1 : size(STEPS,1)         % 只向前推进
        if contains(line, STEPS{k,1})
            state.stepIdx = k; state.stepKey = STEPS{k,2}; break
        end
    end
    for s = 1:numel(subjectIDs)
        if contains(line, subjectIDs{s})
            state.doneSubjects{end+1} = subjectIDs{s};
        end
    end
    if contains(line, 'Error in '),                 state.errors{end+1} = line; end
    if contains(line, 'Job execution failed') || contains(line, 'The following modules did not run') ...
            || contains(line, 'This subject failed segmentation:')
        state.fatal = true;
    end
end
```

**步骤消息针（needle）表**（`contains` 即可，顺序即 §5.1）：

| 步骤 key | needle |
|---|---|
| DICOM_FUN | `Converting Functional Images:` |
| DICOM_T1 | `Converting T1 Images:` |
| DICOM_FIELDMAP | `Converting FieldMap ` |
| CROP_T1 | `Reorienting and Cropping Images:` |
| APPLY_MATS | `Apply Downloaded Reorient Mats` |
| REMOVE_FIRST | `Removing First ` |
| SLICE_TIMING | `Slice Timing Setup:` |
| SLICE_MOVE | `Moving Slice Timing Corrected Files:` |
| FIELD_VDM | `Calculate VDM for FieldMap Correction Setup:` |
| REALIGN | `Realign Setup:` |
| REALIGN_MOVE | `Moving Head Motion Corrected Files:` |
| VOXEL_HM | `Generate voxel specific head motion:` |
| REORIENT_T1 | `Reorienting T1 Image Interactively` |
| REORIENT_FUN | `Reorienting Functional Images Interactively` |
| BET | `Bet begin` / `Bet finished` |
| COREG | `Coregister Setup:` |
| AUTOMASK | `Generating AutoMasks` |
| SEGMENT | `Segment Setup:` |
| DARTEL_CREATE | `Running DARTEL: Create Template.` |
| DARTEL_VBM | `Running DARTEL: Normalize to MNI space for VBM.` |
| NORM_T1 | `Normalize-Write T1 Image:` |
| REGRESS | `Regressing out covariates for subject` |
| COV_MOVE | `Moving Coviables Removed Files:` |
| FILTER_MOVE | `Moving Filtered Files:` |
| NORMALIZE | `Normalize:` / `Normalize-Write:` / `Normalization by using DARTEL:` |
| NORM_MOVE | `Moving Normalized Files:` |
| QC_PICTURE | `Generating the pictures for checking normalization` |
| SMOOTH | `Smooth:` / `Smooth by using DARTEL:` |
| SMOOTH_MOVE | `Moving Smoothed Files:` |
| DETREND_MOVE | `Moving Dtrended Files:` |
| SYMMETRIC | `Normalize to symmetric group T1 mean Template:` |
| NORM_RESULTS | `Normalizing the resutls into MNI space...` |
| SMOOTH_RESULTS | `Smoothing the resutls...` |

> 注意 `Smooth:` 是 `Smooth:` 的子串，也会匹配 `Smooth by using DARTEL:`；映射到同一个 key 即可。

---

## 6. 运行前校验与失败模式

完整 22 项矩阵（触发条件 / 实际行为 / 源码依据 / 实测状态 / Runner 动作）见 [reference/run_checks.tsv](reference/run_checks.tsv)。下面是 Runner **必须实现**的最小校验清单。

### 6.1 启动前（拒绝非法任务，不要交给 DPARSFA）

```
[环境]
□ isfolder(DPABI 安装目录) && ~isempty(which('DPABI.m'))
□ ~isempty(which('spm.m'))
□ 若 IsNeedConvertFunDCM2IMG/IsNeedConvertT1DCM2IMG/IsNeedReorientCropT1Img：
    isfile(<DPABI>\DPARSF\dcm2nii\dcm2niix.exe)
[目录与数据]
□ isfolder(Cfg.WorkingDir) && isfolder(Cfg.DataProcessDir) && 可写
□ 非空 SubjectID 且长度>0；每个 ID 对应目录 <DP>/<prefix><StartingDirName>/<ID> 存在（或 DICOM: <DP>/<prefix>FunRaw/<ID>）
□ FunctionalSessionNumber>=1；i>=2 时 <DP>/S{i}_FunRaw/<ID>（或对应 StartingDirName）存在
□ 每被试能解析到功能像：4D .nii(.gz) 1 个，或 3D 序列 >=2 个，或 DICOM 文件 >=1 个
[时间信息]
□ TR>0 或 每被试 NIfTI 头 pixdim[4]>0（否则 :562 硬 error）
□ TR==0 且 <DP>/TRInfo.tsv 已存在 → 确认表内覆盖所有被试（:515-537）
□ TimePoints>0 时与 4D dim(4)/3D 文件数一致（否则 Error cell + 提前 return）
□ IsSliceTiming：SliceNumber>0 → numel(SliceOrder)==SliceNumber（否则 SPM 报错）；
   SliceNumber==0 → 必须存在 SliceOrderInfo.tsv 或 BIDS json，否则警告“将使用 [1:2:N,2:2:N]”
□ SliceTiming.ReferenceSlice 在 1..SliceNumber（或 0）
[结构像链]
□ 若 IsBet/IsNeedT1CoregisterToFun/IsSegment>=1/IsDARTEL/IsApplyDownloadedReorientMats：
    每被试 T1Img/<ID>/ 内恰好 1 个 c*/co*/*Crop* 文件；
    否则：要么提示用户开启 IsNeedReorientCropT1Img=1（从 T1Img 的 nii 生成 co*），
          要么提示补齐 T1Img；**不要指望引擎自动跳过**（questdlg 在 -batch 下直接报错）
□ IsNeedT1CoregisterToFun/IsSegment：T1 序列可读（≥1 个卷）
□ IsSegment==2 或 IsDARTEL：结果目录 T1ImgNewSegment 的父目录可写
□ IsDARTEL==1：若为续跑，检查 T1ImgNewSegment/<SubjectID{1}>/Template_6.* 与每被试 u_* 已存在
□ IsNormalize==2：续跑时每被试 T1ImgSegment/<ID>/*seg_sn.mat 存在
□ IsNormalize==3：续跑时每被试 T1ImgNewSegment/<ID>/u_* 存在
[依赖一致性]
□ IsCovremove && Timing=='AfterNormalize' && IsNormalize==0 → 警告（无 MNI 数据可回归）
□ Covremove.HeadMotion>=11 && IsCalVoxelSpecificHeadMotion==0 → 拒绝
□ 枚举白名单：Covremove.Timing/Filter.Timing/Normalize.Timing/Smooth.Timing/Scrubbing.Timing/
   Scrubbing.ScrubbingMethod/FDType/Mask(SPM|Segment|AutoMask)/IsSegment(0|1|2)/IsNormalize(0..4)
□ MaskFile!='Default' && ~isfile(MaskFile) → 拒绝
□ CalFC.ROIDef 中每个文件路径 isfile → 否则拒绝
□ 交互开关（IsNeedReorient*、IsDefineROIInteractively）在 headless 下必须为 0，或强制 IsAllowGUI=0（会被静默跳过）
□ 同一 DataProcessDir 没有另一个正在运行的 DPARSFA（引擎无锁）
```

### 6.2 启动后（运行中/结束后）

```
□ 进程退出码 == 0
□ 日志含 'Congratulations, the running of DPARSFA is done!!! :)'
□ 日志不含 'Error in '、'Job execution failed'、'The following modules did not run'、'This subject failed segmentation:'
□ 日志中被试完成集合 ⊇ Cfg.SubjectID
□ 按启用步骤检查产物目录存在且非空（§4.3 的目录表）
□ RealignParameter/HeadMotion.tsv 行数 == SubjectNum（若做了 realign）
□ 每被试 RealignParameter/<ID>/rp_*.txt 存在（若做了 realign）
□ 若做了指标计算：Results/<measure>_<Dir>/ 下每被试至少一个文件
```

### 6.3 已知“行为不友好但不算 bug”的失败（Runner 要提前拦截）

| 现象 | 原因 | 拦截方式 |
|---|---|---|
| `MATLAB:cd:NonExistentFolder` | 起始目录/被试目录/T1 目录不存在 | 目录校验 |
| `Can NOT retrieve the TR information` | `TR=0` 且头无 timing | TR 校验 |
| `matlabbatch:run:jobfailederr` | SPM 作业失败（切片序长度、图像损坏等） | 参数校验 + 捕获退出码 |
| 非交互模式不支持阻塞对话框 | 5 处未受保护的 `questdlg` | T1 命名校验 |
| 打印 Congratulations 但没处理任何数据 | SubjectID 为空 | 空列表校验 |
| `Index exceeds the number of array elements` | 续跑时缺 `seg_sn.mat`/`Template_6.*`/`DirImg` 为空 | 续跑前置校验 |

---

## 7. 推荐预设

三套可直接运行的完整 Cfg 代码见 [reference/presets.md](reference/presets.md)：

| 预设 | 用途 | 关键开关 | 预期目录链 |
|---|---|---|---|
| **A 经典静息态预处理** | 常规静息态全流程（含 ALFF/ReHo/DC/FC） | DICOM→NIfTI、Crop T1、删 10 点、切片+realign、统一分割(2)、标准化(2, OnFunctionalData)、平滑(1, OnFunctionalData)、回归 AfterNormalize、滤波 AfterNormalize、ALFF/ReHo/DC/FC/ROI | `FunImgA→AR→ARW→ARWS→ARWSC→ARWSCF`，`Results/*_FunImgARWSC(F)` |
| **B 仅功能像预处理 + DARTEL** | 只产出标准空间 4D 数据 | New Segment(2)+DARTEL、标准化(3)、平滑(1)、关闭回归/滤波/指标 | `FunImgA→AR→ARW→ARWS`，`T1ImgNewSegment/*` |
| **C 快速功能像质控** | 几秒~几分钟/被试，只评头动 | 删首点 5、Realign、VoxelSpecificHeadMotion，关闭 T1/标准化/指标 | `FunImgR`、`RealignParameter/*`、`VoxelSpecificHeadMotion/*` |

预设编写约定（重要）：
1. 一律 `load Template_Blank.mat` 后覆盖，`save(cfgFile,'Cfg')`（变量名必须是 `Cfg`）。
2. 显式 `Cfg.IsAllowGUI = 0`（数值）。
3. 切片顺序：`SliceNumber=0` 时依赖 `SliceOrderInfo.tsv`/BIDS json，否则使用高风险默认交错序；工作台应在 UI 里强制用户确认。
4. `IsRemoveFirstTimePoints` 只影响 GUI 显示，**真正生效的是 `RemoveFirstTimePoints`**（§3.1.4）。

---

## 8. 参考实现调研（GitHub / 官方文档）

### 8.1 `qizou97/DPABI_without_GUI`（唯一的公开“DPABI 无 GUI”先行项目）

- 仓库：<https://github.com/qizou97/DPABI_without_GUI>
- README：<https://github.com/qizou97/DPABI_without_GUI/blob/main/README.md>
- 基于 **DPABI_V6.1_220101**（我们的环境是 V10.0_260625，行号与细节有差异，结论仍适用）。
- 它的做法（README 摘要）：
  1. **改源码**：把 `DPARSFA_run.m` 里 5 处 `questdlg`（无 co* T1 时的确认框）改成 `if IsAllowGUI==0 → UseNoCoT1Image=1; disp('WARNING...')`；把两处 `if IsAllowGUI % Generate the pictures only if GUI is allowed` 注释掉，强制生成 `PicturesForChkNormalization`。
  2. **提交脚本 `dpabi_noGUI(Cfg_file, work_dir, StartingDirName, ROI_alias_name)`**：从 `work_dir/StartingDirName` 列目录构建 `SubjectID`，`load(Cfg_file)`（GUI 保存的 mat 里变量名是 `Cfg`），设置 `Cfg.WorkingDir=''`、`Cfg.DataProcessDir=''`、`Cfg.StartingDirName`，按需注入 `Cfg.CalFC.ROIDef`，然后 `diary(log_file)` + `DPARSFA_run(Cfg, work_dir, '', 0)`。
  3. **Basic Edition（`DPARSF_run.m`）额外改 3 行**把 `IsNeedReorientFunImgInteractively / IsNeedReorientT1ImgInteractively / IsAllowGUI` 从 `CfgBasic` 透传到 `Cfg`。
- 可借鉴的坑：① co* T1 弹窗；② 标准化检查图被 `IsAllowGUI` 关掉；③ Basic Edition 不透传 IsAllowGUI；④ GUI 保存的 mat 变量名必须是 `Cfg`；⑤ 用 `diary` 落日志。
- **本项目不能改 D:\Software\DPABI**（CONTRACT §3），因此对应策略是：
  - 用 §6.1 的启动前校验替代 5 处 questdlg 补丁；
  - 标准化检查图在 headless 下不生成（`:3264, :4945`），工作台自己用 DPABI Viewer/自绘替代，不追求与原版一致；
  - Runner 统一走 `DPARSFA_run`，不走 Basic。

### 8.2 官方文档

- <http://rfmri.deepbrain.com/content/configurations-dparsfarun>：**官方 Cfg 字段说明**（与本机 V10.0 基本一致；少数字段名/默认值有版本差异，如官方示例 `CalReHo.SmoothReHo`、`Filter.AAddMeanBack='Yes'`）。文中 “Set to 0 if want to set automatically”“Will be skipped if Cfg.IsAllowGUI set to 0” 与源码完全对应。
- <http://rfmri.deepbrain.com/content/run-dparsf-command-line>：官方推荐的命令行方式 = GUI 保存 Cfg 为 `.mat`，然后 `DPARSFA_run('XXX.mat')`，或 `DPARSFA_run('/XXX.mat',WorkingDir,SubjectListFile,IsAllowGUI)`。
- <http://rfmri.deepbrain.com/content/dpabidparsf-stand-alone-version-record>：官方 Stand-Alone（编译版）也用 `DPARSFA_run` 脚本方式；编译版里 `IsAllowGUI` 是字符串，源码 `DPARSFA_run.m:52-54` 用 `isdeployed` 判断后 `str2num`——这解释了为什么许多老脚本用字符串 `'0'`；**在未编译 MATLAB 里必须传数值**。
- CSDN 原始方案（README 引用）：<https://blog.csdn.net/sinat_35907936/article/details/113425845>

### 8.3 与官方 Stand-Alone 的关系

DPABI 提供编译版（MATLAB Runtime），可在无 MATLAB 的机器上跑；工作台选择的是“独立 MATLAB 进程 + `-batch`”路线（本机有完整 MATLAB R2026a），优点是可复用用户 MATLAB 路径与并行池，缺点是每个 run 有 ~10 s MATLAB 启动开销。两者都调用同一个 `DPARSFA_run`。

---

## 9. 原生 GUI 控件 Tag ↔ Cfg 字段映射

- 主界面 `DPARSFA.fig` 共 **119 个 uicontrol**（用 `hgload` 递归 dump，开发期脚本 `tests/tmp_engine_scout/t4_figdump.m` 与结果 `out/fig_controls.tsv`（119 行；均为开发期临时产物，未随仓库发布），与另一份开发期控件 dump 条数一致；我们的 dump 额外保留了 Position/ParentTag/Callback 便于分析层级）。主回调 `DPARSFA.p` 是 P-code，**无法直接读出映射**，因此主界面映射按“Tag 命名 + 控件文案 + 源码语义”推断并标注置信度。
- **子界面 `.m` 可读，映射是确证的**：
  - `SubGUIs/DPARSF_NuisanceSetting.m:125-182`：`WMButton→Covremove.WM.IsRemove`、`MethodPopup→WM/CSF.Method`、`WMMaskPopup/CSFMaskPopup→Mask`、`WMThrdEntry/CSFThrdEntry→MaskThreshold`、`edit_PCNumber→CSF.CompCorPCNum`（WM 也复用它）、`WholeBrainButton→WholeBrain.IsRemove`、`checkboxBothWithWithoutGSR→WholeBrain.IsBothWithWithoutGSR`、`WholeBrainMaskPopup→WholeBrain.Mask`。
  - `SubGUIs/DPARSF_ScrubbingSetting_gui.m:128-136`：`editFDThreshold→Scrubbing.FDThreshold`、`rtnM1..M5→Scrubbing.ScrubbingMethod`（cut/nearest/linear/spline/pchip）。
  - `SubGUIs/DPARSF_ROI_Template.m:60-146`：`checkboxMultiLabel→CalFC.IsMultipleLabel`；内置 AAL/HarvardOxford/CC200 按钮直接写 `CalFC.ROIDef`。
- 可信度最高的主界面映射（完整表见 [reference/gui_tag_map.tsv](reference/gui_tag_map.tsv)）：
  - 高：`edtWorkingDir→WorkingDir`、`editTR→TR`、`editTimePoints→TimePoints`、`editFunctionalSessionNumber→FunctionalSessionNumber`、`editStartingDirName→StartingDirName`、`checkboxRealign→IsRealign`、`checkboxSliceTiming→IsSliceTiming`、`editSliceNumber/Order/ReferenceSlice→SliceTiming.*`、`checkbox_IsBet→IsBet`、`checkbox_IsAutoMask→IsAutoMask`、`checkboxSmooth→IsSmooth`、`editFWHM→Smooth.FWHM`、`checkboxCalALFF→IsCalALFF`、`checkboxCalReHo→IsCalReHo`、`radiobuttonReHo27/19/7→CalReHo.ClusterNVoxel`、`checkboxDetrend→IsDetrend`、`checkboxWarpMasksIntoIndividualSpace→IsWarpMasksIntoIndividualSpace`、`checkboxCalVMHC→IsCalVMHC`、`checkboxCWAS→IsCWAS`、`checkboxScrubbing→IsScrubbing`、`checkboxHeadMotionScrubbingRegressors→Covremove.IsHeadMotionScrubbingRegressors`、`checkboxCovremoveIsAddMeanBack→Covremove.IsAddMeanBack`、`rbtnDefaultMask/rbtnNullMask/rbtnUserMask→MaskFile`。
  - 中/低（需要实测 GUI 才能确认）：\`Normalize Derivatives/Smooth Derivatives\` 两个复选框与 `Normalize.Timing/Smooth.Timing` 的精确互动；`Rigid-body 6/Derivative 12/Friston 24/Voxel-specific 3/Voxel-specific 12` 五个单选分别写 `Covremove.HeadMotion` 的哪个值（源码支持 1/2/3/4/11-14，GUI 只暴露 5 个，推断为 1/2/4/13/14）；`checkboxSegment` vs `checkboxNewSegment_DARTEL` 与 `IsSegment=1/2` 的对应；两套 `Nuisance Covariates Regression`/`Filter` 复选框与 `Timing` 的对应。
- 结论：工作台若要“原生界面汉化”（CONTRACT §2.4），应只翻译 `text/checkbox/radiobutton/pushbutton` 的 String，并给所有控件加 Tooltip；不要试图从 `.p` 里推断回调，映射以本表 + 实机点击验证为准。

---

## 10. 对 CfgSchema / CfgBuilder / Runner 的落地建议

### 10.1 CfgSchema

- 直接以 [reference/cfg_fields.tsv](reference/cfg_fields.tsv) 为数据源：`Key / Type / Default / Meaning / When / Pitfall / Source`。
- 增加机器可校验的元数据（建议在 `+mrw/CfgSchema.m` 内以结构体或第二张表维护）：
  - `enum`：`Covremove.Timing={'AfterRealign','AfterNormalize'}`、`Filter.Timing={'BeforeNormalize','AfterNormalize'}`、`Normalize.Timing={'OnFunctionalData','OnResults'}`、`Smooth.Timing={'OnFunctionalData','OnResults'}`、`Scrubbing.Timing={'AfterPreprocessing'}`、`Scrubbing.ScrubbingMethod={'cut','nearest','linear','spline','pchip'}`、`Covremove.*.FDType={'FD_Power','FD_Jenkinson'}`、`Covremove.{WM,CSF}.Mask={'SPM','Segment'}`、`WholeBrain.Mask={'SPM','AutoMask'}`、`IsSegment={0,1,2}`、`IsNormalize={0,1,2,3,4}`、`IsSmooth={0,1,2}`、`IsAllowGUI={0,1}`、`Covremove.PolynomialTrend={0,1,2,3}`、`Covremove.HeadMotion={1,2,3,4,11,12,13,14}`、`Segment.AffineRegularisationInSegmentation={'mni','eastern','subj'}`。
  - `dependsOn`：
    - `Covremove.HeadMotion∈11..14 → IsCalVoxelSpecificHeadMotion==1`
    - `Covremove.Timing=='AfterNormalize' → IsNormalize>0`
    - `IsDARTEL==1 → IsSegment==2`（GUI 语义；引擎不强制，但 DARTEL 需要 NewSegment 产物）
    - `IsNormalize∈{2,3} → T1 链（IsNeedT1CoregisterToFun+IsSegment）`
    - `CalFC.ROIDef/IsExtractROISignals → IsCalFC/IsExtractROISignals≥1`
    - `Smooth.Timing=='OnResults' → IsNormalize>0`（否则 Results 下没有可平滑图，除指标图）
  - `readOnly=true`：§3.1.3 的输出字段。
  - `deprecated=true`：§3.1.4 的历史字段（UI 不展示，加载旧 Cfg 时静默保留）。
- 数组字段注意形状：`Normalize.BoundingBox` 2×3、`Normalize.VoxSize`/`Smooth.FWHM` 1×3、`SliceTiming.SliceOrder` 1×N、`CalFC.ROISelectedIndex` cell、`CalFC.ROIDef` cell（元素可为 1×4 球、文件路径 char、时间序列矩阵）。

### 10.2 CfgBuilder

1. **基底**：`S = load(fullfile(dpabiRoot,'DPARSF','Jobmats','Template_Blank.mat')); Cfg = S.Cfg;`，再覆盖；不要从空 struct 拼。
2. 强制写出：`WorkingDir`、`DataProcessDir`、`SubjectID`、`StartingDirName`、`FunctionalSessionNumber`、`TimePoints`、`TR`、`IsAllowGUI=0`。
3. GUI 语义同步：`IsRemoveFirstTimePoints` 与 `RemoveFirstTimePoints` 一起设置（虽然引擎只读后者，但原生 GUI/存档保持一致性）。
4. 保存：`save(cfgFile,'Cfg')`（**变量名固定 `Cfg`**）；同时保存一份 `cfg.json`（`jsonencode`）供工作台 UI 与审计使用。
5. 路径：所有路径用绝对路径（引擎 `cd`/`fullfile` 拼接）；中文/空格路径理论上支持（字符串拼接），但外部工具（dcm2niix/bet）未见测试 —— 建议 Runner 在路径含非 ASCII 时给出警告。

### 10.3 Runner（`mrw.Runner` + `mrw.headlessRunner`）

建议的生命周期：
1. **校验**（§6.1）→ 失败立即返回中文原因，不启动 MATLAB。
2. **准备**：建 `runs/<runId>/`，写 `cfg.mat`、`cfg.json`、`status.json`，把 Run 信息（被试、步骤、预计产物）落盘。
3. **启动**：`system('start "" /B "<matlab.exe>" -logfile "<log.txt>" -batch "run(''<headlessRunner.m>'')"')`（实测 0.08 s 返回）或阻塞式 `system` + 异步线程。
4. **监控**：定时读 `log.txt` 增量（记录字节偏移；文件可能被 MATLAB 缓冲，可容忍 1–2 s 延迟），按 §5.4 更新步骤与被试完成集合；`status.json` 由 headlessRunner 在开始/结束各写一次，运行中间由 Runner 侧写。
5. **结束**：等退出码；按 §5.3 判定；写最终 `status.json`；失败时把日志尾部 + 错误摘要回显到工作台。
6. **取消**：`taskkill /PID <pid> /T /F`（必须 `/T`，parpool worker 是子进程）；标记 `killed`；提示“中间产物已保留，可用 StartingDirName 续跑”。
7. **续跑**：由 UI 选择“从步骤 X 续跑”，Runner 计算 §4.2 的后缀串并设置 `StartingDirName`。

`status.json` 建议 schema：

```json
{
  "runId": "20261105-2324-7f3a",
  "state": "running|done|failed|killed",
  "pid": 12345,
  "matlabVersion": "26.1.0.3203278 (R2026a)",
  "dpabiRelease": "V10.0_260625",
  "cfgFile": "runs/.../cfg.mat",
  "logFile": "runs/.../log.txt",
  "startedAt": "2026-11-05T23:24:17+08:00",
  "finishedAt": null,
  "exitCode": null,
  "subjectIDs": ["S01","S02"],
  "subjectTotal": 2,
  "subjectDone": 1,
  "step": { "index": 11, "key": "REALIGN", "label": "Realign", "subjectDoneInStep": 1 },
  "stepsTotal": 17,
  "warnings": 3,
  "errors": [],
  "fatal": false,
  "lastLineAt": "2026-11-05T23:24:52+08:00",
  "lastLine": "Realign Setup:S01 OK",
  "products": { "FunImgAR": "FunRawR", "RealignParameter": true }
}
```

其它工程注意：
- 不要在同一 `DataProcessDir` 并发跑两个 DPARSFA（无锁，中间目录/文件名冲突）。
- 每个 run 独立 `-logfile`；`-batch` 进程退出后 parpool 随进程销毁，不会残留 worker。
- 并行规模由 `headlessRunner` 显式建池并写日志（`[工作台] 并行：已创建 N worker 并行池`）；`ParallelWorkersNumber=0` 时 parfor 串行。取证见 `tests/test_parallel_pool_lead.m`（2 被试请求 6 worker → 自动降为 2，日志无 24 worker 自动池）。
- 日志文件可能很大（每被试多行），Runner 只保留解析结果 + 原始日志按 run 归档即可。

---

## 11. 遗留不确定项（按风险排序）

1. **`DPARSFA.p` 不可读**：GUI 的 Save/Load 是否对 Cfg 做归一化（例如把 `IsRemoveFirstTimePoints=0` 时把 `RemoveFirstTimePoints` 清 0、把 `Timing` 与复选框同步）无法确认。工作台 CfgBuilder 必须自己保证一致性（§10.2）。
2. **五个头动模型单选框的取值**：源码支持 `Covremove.HeadMotion` 1/2/3/4/11-14，GUI 只有 5 个单选；推断为 1（Rigid-body 6）/2（Derivative 12）/4（Friston 24）/13（Voxel-specific 3）/14（Voxel-specific 12），`3`（current+squares）与 `11/12` 可能只能通过 Cfg 设置。需要在原生 GUI 上实测点击-保存-比对 mat 才能确认（本次未做，避免干扰用户 MATLAB 会话）。
3. **`Normalize Derivatives` / `Smooth Derivatives` 复选框**与 `Normalize.Timing/Smooth.Timing` 的精确互动（`OnResults` 是“只对结果做”还是“功能像+结果都做”）未实测。源码显示两种 Timing 是互斥分支（`:3031` vs `:4732`、`:3319` vs `:4999`），即选 `OnResults` 时功能像**不做**标准化/平滑。
4. **FieldMap 目录不一致**：转换步骤写 `FieldMap/<measure>Img`（`:309-322`），而 VDM 计算读 `FunFieldMap/<measure>`（`:832-884`），BIDS 转换也写 `FieldMap/`。二者没有自动衔接，可能是 V10.0 的遗留 bug；用场图前需人工把数据放到 `FunFieldMap/`。**需在真实场图数据上确认**。
5. **`questdlg` 在旧式 `-r`/`-nodisplay` 启动下是否会挂起**：本次只验证了 `-batch`（会直接报错，不挂起）。若工作台将来用 `-r` 启动，必须重新验证。
6. **parfor 自动建池已由工作台接管**：`headlessRunner` 总是关闭 `parallel.Settings.Pool.AutoCreate` 并按需显式建池，因此不再受用户 MATLAB Parallel Preferences 影响；仅当 `parpool` 创建失败（如 PCT 缺失/内存不足）时回退为串行（日志有警告）。
7. **中文/空格/网络路径未实测**：所有实验用 ASCII 本地路径。代码层面是字符串拼接，但 `y_Call_dcm2nii`/`y_Call_bet` 通过 `!` 调外部 exe，路径含空格/中文可能失败；建议 Runner 明确提示。
8. **DPARSF Basic Edition 的完整 Cfg 字段集**：由 `DPARSF_run.m:20-111` 反推（约 35 个字段），但 `DPARSF.p` 不可读，无法确认 Basic GUI 还有哪些隐藏字段。工作台若不做 Basic 可忽略。
9. **`IsNeedConvert4DFunInto3DImg` 等历史字段在原生 GUI 中是否仍被写入**：源码已注释，但 GUI 存档可能仍带这些字段，属于“无害残留”。
10. **QC 阈值过滤（`:1506-1525`）的默认阈值**：`ReorientThreQC` 默认 `IsThreT1=1, ThreT1=3, IsThreFun=1, ThreFun=3`（`SubGUIs/ReorientThreQC.m:47-52`），但这只会在 GUI 交互模式下触发，且会**静默缩小 SubjectID**。工作台如果启用交互重定向，必须在运行后核对实际被试列表。
