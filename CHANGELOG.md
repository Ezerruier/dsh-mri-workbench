# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-08

Initial public release: DSH plugin (`dsh-mri-workbench`) plus the bundled
MATLAB GUI workbench (`matlab/MRI_Workbench`).

### Added — DSH plugin

- Conversation-view page **「MRI 工作台」** with five cards: ① dataset indexing,
  ② preprocessing configuration, ③ run/status, ④ manual QC, ⑤ head-motion results.
- Agent tools: `mri_workbench_env`, `mri_workbench_scan`, `mri_workbench_prepare`,
  `mri_workbench_start`, `mri_workbench_status`, `mri_workbench_wait`,
  `mri_workbench_cancel`, `mri_workbench_open_gui`, `mri_workbench_qc`,
  `mri_workbench_qcstate`, `mri_workbench_results`, `mri_workbench_censor`,
  `mri_workbench_params`, `mri_workbench_overrides`.
- Slash commands under `/mri` (`env`, `scan`, `presets`, `params`, `overrides`,
  `prepare`, `run`, `status`, `cancel`, `open`, `qc`, `qcstatus`, `qcstate`,
  `results`, `censor`, `help`).
- DPARSF configuration preparation with preflight validation: processed-stage
  directory detection, `rp*.txt` collisions, continuation (`StartingDirName`)
  dependency checks, T1-crop compatibility modes (`auto` / `old_dcm2nii` / `no_crop`).
- Background DPARSF preprocessing via a detached MATLAB process calling the
  official `DPARSFA_run`, streamed into DSH background Jobs with live logs,
  progress phases and cancel support.
- Parametric DPARSF-style parameter dialog with grouped navigation, Chinese/English
  labels, hover explanations, dependency gating, search and advanced options;
  session parameter overrides shared by UI, tools and commands.
- Manual QC: DPARSF-compatible scoring TSVs (`QC/RawT1ImgQC.tsv`,
  `QC/RawFunImgQC.tsv`, `QC/NormalizationQC.tsv`), summary tool (5-point scale,
  low scores, MeanFD threshold), and `mri_workbench_qcstate` for reading the live
  MATLAB QC viewer state (`QC/.qcviewer_state.json`).
- Head-motion results card/tool: per-subject metrics from
  `RealignParameter/HeadMotion.tsv` + per-frame FD curves, column explanations,
  heuristic grading, multi-subject FD overlays.
- Scrubbing/censor preview: `FD_Jenkinson`/`FD_Power` thresholds, previous/later
  frame expansion, export to `ScrubbingPreview/`, `IsScrubbing`/`Spike regression`
  parameter overrides.
- New-session entry point 「打开 MRI 工作台」 and `/mri` slash commands.
- Offline Node self-tests (`tests/node/`) and GitHub Actions CI.

### Added — MATLAB workbench (`matlab/MRI_Workbench`)

- `StartWorkbench` GUI with six pages: data index, preprocessing parameters,
  run/log, glossary, settings, manual QC.
- Automatic dataset scanning/indexing (DPARSF `FunRaw`/`T1Raw`, BIDS, generic
  NIfTI, DICOM) with TR / time-point / slice auto-detection.
- 98 Cfg fields with Chinese labels and hover explanations, 5 presets, preflight
  checks, parallel worker support, T1 crop compatibility (`old_dcm2nii` / `no_crop`).
- Manual QC viewer v2: single/triple-orthogonal/montage views, crosshair voxel and
  world coordinates, origin/AC-PC alignment (display-only), orientation calibration,
  window/level, colormap, template overlay, FD curve linkage, subject sorting and
  filtering, DPARSF-compatible 1–5 scoring with comments, and live state JSON.
- Native DPARSF UI localization/hover explanations without modifying DPABI files.
- MATLAB test scripts under `matlab/MRI_Workbench/tests/`.

[0.1.0]: https://github.com/Ezerruier/dsh-mri-workbench/releases/tag/v0.1.0
