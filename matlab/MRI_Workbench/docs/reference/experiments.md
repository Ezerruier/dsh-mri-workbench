# 引擎验证实验记录（可复现）

全部实验脚本位于开发期临时目录（`tests/tmp_engine_scout/`，未随仓库发布），输出在 `out/`。统一调用方式（脚本路径换成本机实际位置）：

```powershell
$m = "D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe"
& $m -batch "run('<脚本路径>\t2_run.m')"
```

| # | 脚本 | 目的 | 关键结论 | 关键输出文件 |
|---|---|---|---|---|
| 1 | `t1_probe.m` | 环境与模板盘点 | MATLAB R2026a / SPM26 / DPABI V10.0_260625；`which DPABI.m`、`which spm.m` 可解析；Template_Blank=58 顶层/99 叶子；14 个模板的字段差异 | `out/env.txt`、`out/template_fields.tsv`、`out/template_diff.tsv` |
| 2 | `t2_run.m` | **真实最小 headless 运行**：合成 12 个 3D NIfTI + Realign only + IsAllowGUI=0 | 进程内调用成功，日志含 `Congratulations, the running of DPARSFA is done!!! :)`；耗时 **35.5 s**；自动建 **24 worker** parpool；.mat 变量名必须为 `Cfg`（第二次调用故意用 `Cfg2` 命名 → `MATLAB:UndefinedFunction`，反向证明） | `out/run1_console.txt`、`out/run1_result.txt`、`out/run1_tree.txt` |
| 3 | `t2b_args.m` | 调用约定与参数陷阱 | `IsAllowGUI` 传字符串 `'0'` → 变成 char、`if` 为真（48）；传数值 0 正常；第 2 位置参数 WorkingDir 可覆盖（不校验存在性）；Cfg 无 `TR` 字段 + 全步骤关闭时不报错 | `out/run2_args.txt` |
| 4 | `t3_errors.m` | 失败模式（5 组） | A 不存在的 WorkingDir → `MATLAB:cd:NonExistentFolder`（硬错误）；B `TR=0` 且头无 timing → `Can NOT retrieve the TR information from the NIfTI images`；C `SubjectID={}` → **静默成功**（打印 Congratulations，返回空 Error）；D 缺 T1Img → cd 硬错误；E SliceOrder 长度与 SliceNumber 不符 → `matlabbatch:run:jobfailederr`（SPM：`Mismatch between number of slices and length of 'sliceorder' vector.`） | `out/run3_errors.txt`、`out/run3_console.txt` |
| 5 | `t4_figdump.m` | dump `DPARSFA.fig` 全部控件 | 119 个 uicontrol（checkbox 46 / pushbutton 11 / radiobutton 16 / edit 19 / text 25 / popupmenu 1 / listbox 1），含 Tag/String/Enable/ParentTag/Position/Callback；popupmenu 的 9 个模板名 | `out/fig_controls.tsv`、`out/fig_popupmenu.txt` |
| 6 | `t5_questdlg.m`（带 100 s 超时监控） | 无 co* T1 时 headless 行为 | **不挂起**：`-batch` 非交互模式禁止阻塞对话框，在 `DPARSFA_run.m:1752` 抛错，进程退出码 1 | `out/run5_console.txt`、`out/run5_stdout.txt.err` |
| 7 | `t6b_recipe.m` | `TR=0` 自动读 NIfTI 头 | 成功：`TRSet=2.5`，生成 `TRInfo.tsv`（`S01 2.5 10 8 1 1 1`）；附带给出“4D NIfTI + timing.tspace”的构造配方（`nifti` + `file_array` + `N.timing.tspace` + `create`） | `out/run6_recipe.txt`、`out/run6_console.txt` |
| 8 | `t7_spawn.m` | 从 MATLAB 内分离启动子 MATLAB | `system('start "" /B "<matlab.exe>" -logfile ... -batch "run(...)"')` **0.08 s 返回**；子进程 12 s 内独立完成并写日志 | `out/run7_spawn.txt`、`out/child_log.txt` |
| 9 | `-logfile` 行为（PowerShell 直测） | MATLAB 日志与退出码 | `-logfile` 放在 `-batch` 前后均可；成功退出码 0、未捕获 error 退出码 1；日志为系统本地编码（中文 warning 乱码，ASCII 正常） | `out/test_logfile.log`、`out/test_logfile2.log` |

说明：
- 全部实验使用**运行时生成的合成 NIfTI**，不含真实被试数据；所有临时数据在开发期临时目录（`tests/tmp_engine_scout/`，未随仓库发布）内。
- 未修改 `D:\Software\DPABI` 任何文件；未使用用户交互式 MATLAB 会话（全部独立 `-batch` 进程）。
- 实验用的 24-worker parpool 是 MATLAB 对 `parfor` 的自动建池行为（非 `ParallelWorkersNumber` 参数触发）。
