# tests/node — 离线 Node 自测

本目录是 `dsh-mri-workbench` 的**离线自测套件**：直接 `import` 插件根目录的 `index.mjs`，或用一个最小的
假 React / 假 DSH Client 上下文执行 `client.js` 的真实渲染函数，用来验证 Host 侧纯函数、`/mri`
命令、工具接线和页面渲染逻辑。

**不启动** DSH、MATLAB、浏览器，也不需要 DPABI / SPM / 真实 NIfTI 数据；在 ubuntu CI 上可完整运行。

## 运行

要求 Node.js ≥ 22（CI 用 22 与 24 两个版本）。在仓库根目录执行：

```bash
node tests/node/run-all.mjs
```

`run-all.mjs` 会递归发现 `tests/node/` 下所有 `.mjs` 测试脚本（跳过 `fixtures/` 与本文件所在的
`run-all.mjs`），用当前 Node 可执行文件逐个运行，输出：

```text
PASS tests/node/qc_state_test.mjs (20 checks)
...
PASS 全部 14 个测试脚本（合计 148 项检查）
```

任一脚本失败会打印 `FAIL <name>` 及其输出尾部，并以非零退出码结束（CI 据此失败）。

也可以单独运行某个脚本，例如：

```bash
node tests/node/qc_state_test.mjs
node tests/node/qc_dsh_test/test-qc-dsh.mjs
```

脚本内部一律用 `fileURLToPath(import.meta.url)` 解析自身与仓库根目录，**从任何工作目录运行结果相同**。
除 `fixtures/` 中的合成样例与临时目录（系统临时目录 / `tests/node/tmp_scan_history`，测试结束会清理）
外，不读写本机真实工作区状态（不依赖、也不创建仓库根下的 `.mri-workbench/`）。

## 测试清单

| 脚本 | 检查数 | 覆盖内容 |
| --- | ---: | --- |
| `qc_state_test.mjs` | 20 | 人工 QC 窗口实时状态（`mri_workbench_qcstate` / `/mri qcstate`）：注册与描述、合法/缺字段/损坏/过期 JSON、schema 不匹配、字段偏差容错、时区标记、`updatedAt` 缺失回退文件时间、无损 JSON |
| `qc_dsh_test/test-qc-dsh.mjs` | 19 | 人工 QC 评分解析与摘要（`buildQcSummary` / `renderQcSummary`）：UTF-8 BOM / GBK / CRLF TSV、无表头容错、HeadMotion 第 21 列 MeanFD、受试者自然排序、阈值文件（`ManualQC_thresholds.json`）、缺文件分支、`jsonSafe` |
| `qc_dsh_test/test-apply-wiring.mjs` | 15 | 人工 QC 工具/命令接线（mock DSH Host ctx）：`mri_workbench_qc` 参数与输出、`/mri qcstatus`、`/mri qc`、`/mri help`、系统提示、旧工具兼容、`inject`、`dispose` |
| `results_test.mjs` | 14 | 头动结果解读（`mri_workbench_results` / `mri_workbench_censor`）：HeadMotion.tsv + 逐帧 FD 解析、组摘要、阈值分层、最大头动排除名单、scrubbing 邻域扩展、导出坏帧清单、`/mri results` / `resultsjson` / `censor` |
| `results_card_test.mjs` | 13 | ⑤ 头动结果卡渲染（假 React + 假 Client ctx）：表格/曲线/解释、勾选与表格行多选、指标切换、阈值切换重新请求、分级着色、坏帧预览（FD 类型/阈值/前后扩展）、导出与 scrubbing/spike 参数覆盖合并 |
| `param_dialog_test.mjs` | 9 | 参数弹窗 Host 数据通道（`mri_workbench_params` / `mri_workbench_overrides` / `/mri paramsjson`）：CfgSchema 条目与中文 tip、分组、覆盖保存/清空、help 与系统提示 |
| `param_dialog_render_test.mjs` | 9 | 参数弹窗渲染级：5 个预设、7 个分组、字段中文名/English/key、悬停 tooltip、枚举下拉、应用覆盖、关闭恢复 |
| `param_dialog_dep_test.mjs` | 6 | 参数依赖联动回归：父开关勾选后子字段立即解禁、bool 覆盖按 MATLAB 兼容的 1/0 保存、旧布尔覆盖 `value:true` 重新打开弹窗仍满足依赖 |
| `worker_select_test.mjs` | 3 | ② 预处理配置卡「并行 worker 数」下拉框：选项渲染、选 4 保存 `ParallelWorkersNumber=4` 且保留其他覆盖、选串行移除该项覆盖 |
| `scan_history_test.mjs` | 6 | 扫描结果的「目录处理历史」：`FunImg*` 目录名解码（层校正/头动校正/Scrubbing/多 session/VMHC 后缀）、阶段链与受试者数、结果目录说明、续跑建议文本 |
| `start_entry_test.mjs` | 7 | DSH 开始页入口与原生主面板接线：slot 注册、中英文入口按钮、只切换面板不执行命令、复用当前空白会话、返回开始页、无会话提示、已有会话标签页 |
| `browse_dir_test.mjs` | 9 | ① 数据索引卡「浏览…」目录选择：原生桥/`uiWorkspace.pickDirectory` 回退、取消不改输入、等待期禁用、错误提示、zh/en 文案 key 对齐 |
| `output_error_color_test.mjs` | 7 | 执行输出错误行红色渲染：中文「错误：」小节、失败摘要行、英文 Error/Warning、`状态=error` 不误染、取消失败提示、文本逐字不变 |
| `t1_crop_ui_test.mjs` | 11 | 「T1 裁剪兼容模式」下拉框（auto/old_dcm2nii/no_crop）渲染与参数覆盖写入，以及 `mri_workbench_prepare` 输出中 T1 裁剪兼容行只在非 auto 时出现 |

合计 148 项检查。检查数为各脚本自带汇总行（`全部通过：N 项检查` / `N/N PASS`）的原始计数，请勿在
移植时删减断言；新增检查时同步更新本表。

## Fixtures

所有 fixture 均已提交为**静态文件**，CI 不需要执行任何生成脚本。

> 注意：`fixtures/` 下部分受试者目录（如 `sample/FunRaw/Sub01/`）本身是空目录，git 不跟踪空目录，
> 因此每个空目录内都有一个空文件 `.gitkeep` 用于占位。**不要删除这些 `.gitkeep`**，否则 CI/新克隆的
> checkout 里目录会消失，人工 QC 样例的受试者发现与「空工作目录」用例会失效。

- `fixtures/qc_dsh_test/sample/`、`sample2/`、`sample3/`
  - 人工 QC 解析用例。`sample` 含 5 名受试者，`QC/RawT1ImgQC.tsv` 为 **UTF-8 BOM + CRLF**，
    `QC/RawFunImgQC.tsv` 为 **GBK + CRLF**（模拟中文 Windows 上 DPARSF 的写法），
    `QC/NormalizationQC.tsv` 只有表头，`RealignParameter/HeadMotion.tsv` 为 DPARSF 21 列格式；
    `sample2` = `sample` + `QC/ManualQC_thresholds.json`（T1Min=4、MaxMeanFD=0.3、UseMeanFD=true）；
    `sample3` 只有 `FunRaw/Sub01`（缺 QC/ 与 RealignParameter/）。
  - `fixtures/qc_dsh_test/fixtures.json` + `make_fixtures.ps1` 为**再生成参考**：
    `make_fixtures.ps1` 仅在 Windows PowerShell 下使用（ASCII-only，中文内容在 fixtures.json 中），
    在 `fixtures/qc_dsh_test/` 目录内重新生成 `sample*`。生成后请按二进制原样提交，不要用编辑器重存
    （BOM/GBK/CRLF 会被破坏，GBK 用例将失去意义）。
- `fixtures/results_fixture/`
  - 头动结果用例：`RealignParameter/HeadMotion.tsv`（3 名受试者）+ 每名受试者 10 帧的
    `FD_Jenkinson_*.txt` / `FD_Power_*.txt` / `FD_VanDijk_*.txt` + 最大头动排除名单文件；
    `empty/` 用于「没有 RealignParameter」分支。测试会临时写入 `ScrubbingPreview/` 并在结束时清理。
- `fixtures/schema.json`
  - MATLAB `CfgSchema` 的导出缓存（`version: 3`，98 个可调参数、7 个分组、含 glossary 中文 `tip`），
    供参数弹窗渲染测试离线使用。测试会把它复制进一个临时会话工作区的 `.mri-workbench/schema.json`，
    等价于工作台首次运行 MATLAB 后写入的缓存。
  - 重新生成方法：在装有 MATLAB + DPABI/SPM 的机器上打开工作台读取一次参数
    （Agent 调用 `mri_workbench_params`（可加 `refresh: true`），或页面「参数设置…」），
    然后把它写到会话工作区的 `<workspace>/.mri-workbench/schema.json` 原样复制到这里。

## 平台相关（Windows-only）说明

- `qc_dsh_test/test-apply-wiring.mjs`：「原工具 mri_workbench_env / status 仍可执行」这一项中
  `env.matlabExists === true` 是 **Windows 本机开发环境断言**（开发机装有 MATLAB）。在
  `process.platform !== 'win32'`（含 CI ubuntu）时改为打印一行
  `SKIP  matlabExists===true 是 Windows 本机开发环境断言；CI ubuntu 无 MATLAB，改校验字段类型`
  并只校验 `matlabExists` / `matlabExe` 的字段类型——**不删除检查、不降低检查数**。
  该脚本用 `MRI_WORKBENCH_ROOT` 指向仓库内的 `matlab/MRI_Workbench`（部署时工作台位于
  会话工作区的 `MRI_Workbench/`，两者等价），并用独立临时目录作为会话工作区，避免受本机
  `.mri-workbench/` 运行状态影响。
- `qc_dsh_test/test-apply-wiring.mjs`：「`/mri qc <不存在的目录>`」这一项在 Windows 上断言命中
  「工作目录不存在」（MATLAB 可用时目录校验先触发）；ubuntu CI 没有 MATLAB，命令会先报
  「未找到 matlab」，因此非 Windows 环境改为接受 `工作目录不存在` 或 `未找到 matlab` 两条预期
  错误分支之一并打印 `SKIP` 说明，**检查数与 kind=error / 「MRI 工作台操作失败」断言不变**。
- `fixtures/qc_dsh_test/make_fixtures.ps1` 只适用于 Windows PowerShell，仅作再生成参考（CI 不运行）。
- 其余脚本不依赖操作系统；测试数据里出现的目录/文件路径均为假数据字符串，不访问真实文件系统。

## CI

`.github/workflows/ci.yml` 在 push 到 `main` 与 pull_request 时，用 ubuntu-latest + Node 22/24 执行：
`node --check index.mjs`、`node --check client.js`、校验 `package.json` / `locale/en.json` /
`locale/zh.json` 为合法 JSON，然后运行 `node tests/node/run-all.mjs`。

## 维护约定

- 新测试脚本放在 `tests/node/` 下（可按组放进子目录），文件名以 `_test.mjs` 或 `test-*.mjs` 结尾即可被
  `run-all.mjs` 自动发现；不要把它命名为 `run-all.mjs`。
- 测试不得依赖本机 MATLAB / DSH / 真实数据，也不得读写仓库根目录的 `.mri-workbench/` 运行状态；
  需要缓存/临时文件时使用系统临时目录或 `fixtures/` 内的临时子目录，并在结束处清理。
- 测试不得包含本机绝对路径（如用户目录）；涉及路径行为的断言请用相对 fixture 或明确的假数据。
