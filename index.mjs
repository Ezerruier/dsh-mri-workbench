import { spawn } from 'node:child_process';
import { existsSync, promises as fsp, readFileSync, readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import path from 'node:path';

/**
 * dsh-mri-workbench — Host half.
 *
 * 把 MRI_Workbench（MATLAB/DPABI/DPARSF）无界面后端接到 DSH：
 *  - 数据扫描（mrw.ScanEngine）
 *  - 预处理配置生成与运行前校验（mrw.CfgBuilder）
 *  - 后台启动官方 DPARSFA_run（mrw.headlessRunner），以 DSH 后台 Job 承载实时日志
 *  - 状态/日志/取消/环境检查
 * 预处理计算全部发生在 MATLAB 独立进程，本插件只做编排。
 */

export const inject = ['tools', 'systemPrompt', 'commands'];

const PRESETS = [
  '经典静息态（DARTEL 全流程）',
  '仅功能像（EPI 模板标准化，无结构像）',
  'BIDS 数据一键预处理',
  '快速质控（仅转换+头动校正）',
  '空白（仅补步骤/续跑）',
];

const DEFAULT_MATLAB_CANDIDATES = [
  'D:\\Program Files\\Matlab\\MatlabR2026a\\bin\\matlab.exe',
  'D:\\Program Files\\Matlab\\MatlabR2025b\\bin\\matlab.exe',
  'D:\\Program Files\\Matlab\\MatlabR2025a\\bin\\matlab.exe',
  'C:\\Program Files\\MATLAB\\R2026a\\bin\\matlab.exe',
  'C:\\Program Files\\MATLAB\\R2025b\\bin\\matlab.exe',
  'C:\\Program Files\\MATLAB\\R2025a\\bin\\matlab.exe',
];

const isWin = process.platform === 'win32';

function fwd(p) {
  return String(p).replaceAll('\\', '/');
}

function matlabQuote(p) {
  return fwd(p).replaceAll("'", "''");
}

function nowStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${String(d.getMilliseconds()).padStart(3, '0')}`;
}

function decodeConsole(buf) {
  try {
    return new TextDecoder('gbk', { fatal: false }).decode(buf);
  } catch {
    return Buffer.from(buf).toString('utf8');
  }
}

function tailText(file, maxBytes = 24000) {
  try {
    const st = statSync(file);
    if (!st.isFile() || st.size === 0) return '';
    const start = Math.max(0, st.size - maxBytes);
    const fd = openSync(file, 'r');
    const buf = Buffer.alloc(st.size - start);
    readSync(fd, buf, 0, buf.length, start);
    closeSync(fd);
    return buf.toString('utf8');
  } catch {
    return '';
  }
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return undefined;
  }
}

// ------------------------------------------------------------------
// 人工 QC：Node 侧只读解析（不启动 MATLAB）
//
// 评分文件与 DPARSF 完全兼容（见 MRI_Workbench/docs/QC_CONTRACT.md §1.4）：
//   QC/RawT1ImgQC.tsv、QC/RawFunImgQC.tsv、QC/NormalizationQC.tsv
//   首行 Subject ID<TAB>QC Score<TAB>QC Comment；1=很差 … 5=很好；未评分写作 NaN。
//   DPARSF 用 fopen(...,'w') 在中文 Windows 上可能写成 GBK，读取时做 UTF-8/GBK 自适应。
//   RealignParameter/HeadMotion.tsv 第 21 列（mean FD_Jenkinson）为 MeanFD。
// 这些函数导出仅为离线自测（tests/node/qc_dsh_test），插件运行不依赖导出。
// ------------------------------------------------------------------

const QC_MODALITIES = [
  { key: 'T1', label: 'T1 原始像', file: 'RawT1ImgQC.tsv', minKey: 'T1Min' },
  { key: 'Fun', label: '功能平均像', file: 'RawFunImgQC.tsv', minKey: 'FunMin' },
  { key: 'Norm', label: '标准化检查', file: 'NormalizationQC.tsv', minKey: 'NormMin' },
];

const QC_DEFAULT_MIN_SCORE = 3;
const QC_DEFAULT_MAX_MEAN_FD = 0.2;

const WORKDIR_SOURCE_LABELS = {
  argument: '工具参数/命令行指定',
  prepare: '最近一次「生成配置」的工作目录',
  scan: '最近一次「数据扫描」的工作目录',
  'prep-state': '最新 prepare 目录内的 state.json',
  'scan-result': '.mri-workbench/scan-result.json',
  index: '.mri-workbench/index.json',
  'workspace-fallback': '当前会话工作区（回退）',
};

/** 把任意值转换为 JSON-safe：去掉 undefined/函数，非有限数字（NaN/Infinity）→ null。 */
export function jsonSafe(value) {
  if (value === undefined || typeof value === 'function' || typeof value === 'symbol') return undefined;
  if (value === null) return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) return value.map((item) => {
    const safe = jsonSafe(item);
    return safe === undefined ? null : safe;
  });
  if (typeof value === 'object') {
    const out = {};
    for (const [key, item] of Object.entries(value)) {
      const safe = jsonSafe(item);
      if (safe !== undefined) out[key] = safe;
    }
    return out;
  }
  return String(value);
}

function decodeTextBytes(buf) {
  if (!Buffer.isBuffer(buf)) return String(buf ?? '');
  let text = buf.toString('utf8');
  if (text.includes('\uFFFD')) {
    // 非法 UTF-8 序列 → 尝试 GBK（DPARSF 在中文 Windows 上可能用系统编码写 TSV）
    try {
      text = new TextDecoder('gbk', { fatal: false }).decode(buf);
    } catch {
      /* 保留 UTF-8 解码结果 */
    }
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  return text;
}

function readTextFile(file) {
  try {
    const st = statSync(file);
    if (!st.isFile()) return { ok: false, message: '不是普通文件' };
    return { ok: true, size: st.size, text: decodeTextBytes(readFileSync(file)) };
  } catch (err) {
    return { ok: false, message: String(err?.message ?? err) };
  }
}

function splitQcLine(line) {
  const parts = String(line).split('\t');
  return {
    id: (parts[0] ?? '').trim(),
    scoreRaw: (parts.length > 1 ? parts[1] : '').trim(),
    comment: parts.length > 2 ? parts.slice(2).join('\t').trim() : '',
  };
}

function parseQcNumber(raw) {
  const text = String(raw ?? '').trim();
  if (!text || /^(nan|na|n\/a|-|none|null)$/i.test(text)) return null;
  const value = Number(text.replace(',', '.'));
  return Number.isFinite(value) ? value : null;
}

/** 读取 DPARSF 兼容的评分 TSV。文件不存在时 exists=false，不抛异常。 */
export function readQcTsv(file) {
  const out = { exists: false, file, rows: [], message: '' };
  const read = readTextFile(file);
  if (!read.ok) {
    out.message = read.message;
    return out;
  }
  out.exists = true;
  let headerSeen = false;
  for (const line of read.text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const cells = splitQcLine(line);
    if (!headerSeen) {
      headerSeen = true;
      // 只把 DPARSF 的 "Subject ID"/"QC Score" 当成表头，避免误吞 Subject01 这类真实受试者 ID
      if (/^subject\s*id$/i.test(cells.id) || /^(qc\s*)?score$/i.test(cells.scoreRaw)) continue;
    }
    if (!cells.id) continue;
    out.rows.push({ id: cells.id, score: parseQcNumber(cells.scoreRaw), comment: cells.comment });
  }
  return out;
}

/** 读取 RealignParameter/HeadMotion.tsv（MeanFD = 表头 mean FD_Jenkinson 列，通常第 21 列）。 */
export function parseHeadMotionTsv(file) {
  const out = { available: false, file, ids: [], meanFD: [], columnIndex: null, message: '' };
  const read = readTextFile(file);
  if (!read.ok) {
    out.message = read.message;
    return out;
  }
  out.available = true;
  const lines = read.text.split(/\r?\n/).filter((line) => line.trim() !== '');
  if (!lines.length) {
    out.message = '文件为空';
    return out;
  }
  const headerCells = lines[0].split('\t').map((cell) => cell.trim().toLowerCase());
  const looksLikeHeader = /^subject\s*id$/i.test(headerCells[0] ?? '') ||
    headerCells.some((cell) => cell.includes('max(abs(') || cell.includes('qc score'));
  let columnIndex = headerCells.findIndex((cell) => cell.includes('fd_jenkinson'));
  let firstDataLine = 1;
  if (columnIndex < 0) {
    // 无 FD_Jenkinson 表头：按 DPARSF 21 列约定取第 21 列，否则取最后一列
    columnIndex = headerCells.length >= 21 ? 20 : Math.max(0, headerCells.length - 1);
    if (!looksLikeHeader) firstDataLine = 0; // 没有表头：首行即数据
  }
  out.columnIndex = columnIndex;
  for (let i = firstDataLine; i < lines.length; i++) {
    const cells = lines[i].split('\t');
    const id = (cells[0] ?? '').trim();
    if (!id) continue;
    out.ids.push(id);
    out.meanFD.push(parseQcNumber(cells[columnIndex]));
  }
  return out;
}

function sortIdList(ids) {
  return [...ids].sort((a, b) => a.localeCompare(b, 'zh-Hans-CN', { numeric: true, sensitivity: 'base' }));
}

/** 从 DPARSF 输出目录（Fun/T1/Realign 前缀及 Results）的受试者子目录推断受试者 ID。 */
export function discoverSubjectIds(workDir) {
  const ids = new Set();
  let entries;
  try {
    entries = readdirSync(workDir, { withFileTypes: true });
  } catch {
    return [];
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const name = entry.name;
    if (name.startsWith('.') || name === 'QC') continue;
    if (!/^(Fun|T1|Realign)/i.test(name) && name !== 'Results') continue;
    try {
      for (const child of readdirSync(path.join(workDir, name), { withFileTypes: true })) {
        if (child.isDirectory() && !child.name.startsWith('.')) ids.add(child.name);
      }
    } catch {
      /* 忽略不可读目录 */
    }
  }
  return sortIdList([...ids]);
}

// ------------------------------------------------------------------
// DPARSF 目录处理历史：说明工作目录里各阶段目录的数据经过哪些处理
// （FunImg* 后缀按 DPARSFA_run.m 中 StartingDirName 的追加顺序解码）
// ------------------------------------------------------------------

/** DPARSF 功能像目录后缀 → 处理步骤（字母按实际运行顺序追加到目录名）。 */
const DPARSF_FUN_DIR_SUFFIXES = {
  A: '时间层校正（Slice Timing）',
  R: '头动校正（Realign）',
  C: '协变量回归（Nuisance Covariates Regression）',
  W: '标准化（Normalization）',
  S: '平滑（Smoothing）',
  F: '滤波（Filtering）',
  D: '去线性趋势（Detrend）',
  B: 'Scrubbing（坏帧剔除/插值）',
  sym: 'VMHC 对称化（Symmetrize）',
};

const DPARSF_FUN_DIR_BASES = {
  FunImg: '功能像 NIfTI 起始数据',
  FunRaw: '原始功能像（DICOM）目录',
};

const DPARSF_WORKDIR_EXTRA_DIRS = {
  RealignParameter: '头动校正参数与 FD 曲线（rp_*.txt、mean*.nii、FD_Jenkinson/FD_Power/FD_VanDijk_*.txt、HeadMotion.tsv、ExcludeSubjects*.txt）',
  VoxelSpecificHeadMotion: '体素特异头动图像（TDvox/FDvox；需开启 IsCalVoxelSpecificHeadMotion）',
  Results: '指标计算结果（ALFF/ReHo/DC/FC 等；子目录名带处理链后缀）',
  Masks: '分割/标准化生成的掩膜',
  T1Img: '结构像 NIfTI（T1 原始/转换数据）',
  FunRaw: '原始功能像目录（通常为 DICOM，转换后才有 FunImg）',
  ScrubbingPreview: '工作台导出的坏帧清单（本插件生成，不是 DPARSF 产物）',
};

function countSubjectDirs(dir) {
  try {
    let n = 0;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory() && !entry.name.startsWith('.')) n += 1;
    }
    return n;
  } catch {
    return 0;
  }
}

/**
 * 解析 DPARSF 功能像阶段目录名（FunImg、FunImgA、FunImgAR、FunImgARB；支持 S2_ 多 session 前缀）。
 * 返回：sessionPrefix / base / suffix / steps / stepText / isScrubbingOutput / depth；无法识别时返回 null。
 */
export function decodeDparsfFunDir(name) {
  const decodedName = String(name ?? '');
  const sessionMatch = /^(S\d+_)(.*)$/.exec(decodedName);
  const sessionPrefix = sessionMatch ? sessionMatch[1] : '';
  const baseAndSuffix = sessionMatch ? sessionMatch[2] : decodedName;
  const baseMatch = /^(FunRaw|FunImg)(.*)$/.exec(baseAndSuffix);
  if (!baseMatch) return null;
  const base = baseMatch[1];
  const suffix = baseMatch[2];
  const steps = [];
  for (let i = 0; i < suffix.length; ) {
    const token = suffix.startsWith('sym', i) ? 'sym' : (/^[A-Za-z]$/.test(suffix[i]) ? suffix[i] : '');
    const label = DPARSF_FUN_DIR_SUFFIXES[token];
    if (!label) {
      steps.push({ token: suffix.slice(i), label: `未知后缀「${suffix.slice(i)}」`, unknown: true });
      break;
    }
    steps.push({ token, label });
    i += token.length;
  }
  const baseLabel = DPARSF_FUN_DIR_BASES[base];
  const stepText = steps.length
    ? `${baseLabel} → ${steps.map((step) => step.label).join(' → ')}`
    : baseLabel;
  return {
    name: decodedName,
    sessionPrefix,
    base,
    suffix,
    steps,
    stepText,
    isScrubbingOutput: steps.some((step) => step.token === 'B'),
    depth: steps.length,
  };
}

/**
 * 汇总工作目录里 DPARSF 阶段目录（FunImg*）与常见结果目录，生成「数据经过哪些处理」的结构化说明。
 * 不入库、不启动 MATLAB，只读取目录结构。
 * @param {string} workDir DPARSF 工作目录
 * @param {{ startingDirName?: string }} [options] 扫描得到的功能像起始目录名（用于确定主处理链）
 */
export function buildProcessingHistory(workDir, options = {}) {
  const result = {
    workDir: workDir ?? '',
    startingDirName: options.startingDirName ?? null,
    stages: [],
    chain: [],
    otherDirs: [],
    suggestedStartingDirName: null,
    hint: '',
  };
  if (!workDir || !existsSync(workDir)) return result;
  let entries;
  try {
    entries = readdirSync(workDir, { withFileTypes: true });
  } catch {
    return result;
  }
  const names = entries.filter((entry) => entry.isDirectory() && !entry.name.startsWith('.')).map((entry) => entry.name);
  for (const name of names) {
    const decoded = decodeDparsfFunDir(name);
    if (!decoded) continue;
    result.stages.push({ ...decoded, subjectCount: countSubjectDirs(path.join(workDir, name)) });
  }
  result.stages.sort((a, b) => (a.depth - b.depth)
    || a.sessionPrefix.localeCompare(b.sessionPrefix)
    || a.name.localeCompare(b.name));
  const stageNames = new Set(result.stages.map((stage) => stage.name));
  // 主处理链：与扫描起始目录同 session 前缀的家族；否则取无前缀家族 / 第一个家族
  const wantedPrefix = (() => {
    const match = /^(S\d+_)/.exec(String(result.startingDirName ?? ''));
    if (match) return match[1];
    if (result.stages.some((stage) => !stage.sessionPrefix)) return '';
    return result.stages[0]?.sessionPrefix ?? '';
  })();
  result.chain = result.stages
    .filter((stage) => stage.sessionPrefix === wantedPrefix)
    .sort((a, b) => (a.depth - b.depth) || a.name.localeCompare(b.name))
    .map((stage) => stage.name);
  for (const name of names) {
    if (!Object.prototype.hasOwnProperty.call(DPARSF_WORKDIR_EXTRA_DIRS, name)) continue;
    if (stageNames.has(name)) continue; // FunRaw 等同时是阶段目录时不重复说明
    result.otherDirs.push({ name, note: DPARSF_WORKDIR_EXTRA_DIRS[name] });
  }
  const lastStage = result.chain.length > 1 ? result.chain[result.chain.length - 1] : null;
  if (lastStage) {
    const onlyScrubbing = lastStage.endsWith('B') && lastStage.length > 'FunImg'.length + 1;
    const previousStage = onlyScrubbing ? lastStage.slice(0, -1) : lastStage;
    result.suggestedStartingDirName = previousStage;
    result.hint = `扫描默认使用 ${result.startingDirName ?? result.chain[0]}（起始数据）。只想补做某项处理时，可把参数「起始目录名」设为相应阶段目录并关闭之前的步骤`
      + (onlyScrubbing
        ? `（例如只补 Scrubbing：起始目录名=${previousStage}，关闭删初始点/层校正/头动校正）`
        : `（例如从 ${lastStage} 继续补后续步骤）`)
      + '；完整重跑请先恢复原始数据，避免重复「删除初始时间点」和 rp 文件重名导致的错误。';
  } else if (result.chain.length === 1) {
    result.hint = '当前只检测到一个功能像阶段目录；若该目录跑过「删除初始时间点」，其帧数已被原地裁剪，完整重跑前请先恢复原始数据。';
  }
  return result;
}

/** 把 buildProcessingHistory 的结果渲染成「执行输出」里的说明行（纯文本，每项一行）。 */
export function renderProcessingHistory(history) {
  if (!history || !Array.isArray(history.stages) || history.stages.length === 0) return [];
  const lines = [];
  const chain = Array.isArray(history.chain) ? history.chain : [];
  if (chain.length >= 2) lines.push(`- 数据目录处理历史：${chain.join(' → ')}`);
  else if (chain.length === 1) lines.push(`- 数据目录处理历史：${chain[0]}（当前只有起始阶段）`);
  for (const stage of history.stages) {
    const subjects = stage.subjectCount > 0 ? `${stage.subjectCount} 名受试者` : '无受试者子目录';
    const scrubNote = stage.isScrubbingOutput ? '；输出文件 <受试者>/<受试者>_4DVolume.nii' : '';
    const baseNote = !stage.steps.length && stage.base === 'FunImg' ? '；「删除初始时间点」会原地改写此目录' : '';
    lines.push(`  · ${stage.name}：${stage.stepText}（${subjects}${scrubNote}${baseNote}）`);
  }
  for (const dir of Array.isArray(history.otherDirs) ? history.otherDirs : []) {
    lines.push(`  · ${dir.name}：${dir.note}`);
  }
  lines.push('- 文件命名：阶段目录内的 4D NIfTI 由 SPM/DPARSF 按前缀命名（a=层校正、r=头动校正、w=标准化、s=平滑）；Scrubbing 输出为 <受试者>_4DVolume.nii。');
  if (history.hint) lines.push(`- 提示：${history.hint}`);
  return lines;
}

function positiveNumber(value, fallback) {
  const n = typeof value === 'number' ? value : Number(String(value ?? '').trim());
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function roundNumber(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function minScoreFor(minKey, thresholds) {
  const raw = thresholds?.[minKey];
  const n = typeof raw === 'number' ? raw : Number(String(raw ?? '').trim());
  return Number.isFinite(n) && n >= 1 && n <= 5 ? n : QC_DEFAULT_MIN_SCORE;
}

function readHeadMotion(workDir) {
  const realignDir = path.join(workDir, 'RealignParameter');
  const candidates = [];
  const exact = path.join(realignDir, 'HeadMotion.tsv');
  if (existsSync(exact)) {
    candidates.push(exact);
  } else {
    try {
      const names = readdirSync(realignDir).filter((name) => /headmotion\.tsv$/i.test(name)).sort();
      for (const name of names) candidates.push(path.join(realignDir, name));
    } catch {
      /* RealignParameter 不存在 */
    }
  }
  const file = candidates[0] ?? null;
  const tsv = file
    ? parseHeadMotionTsv(file)
    : { available: false, ids: [], meanFD: [], columnIndex: null, message: '文件不存在' };
  const relFile = file ? path.relative(workDir, file).replaceAll('\\', '/') : null;
  return { file, relFile, tsv, candidates };
}

/**
 * 汇总某个 DPARSF 工作目录的人工 QC 状态（只读，不启动 MATLAB）。
 * @param {string} workDir DPARSF 工作目录（含 QC/、RealignParameter/）
 * @param {{ subjectIDs?: string[] }} [options] 状态/索引中已知的受试者 ID（用于计算“总数”）
 */
export function buildQcSummary(workDir, options = {}) {
  const dir = path.resolve(String(workDir ?? ''));
  const qcDir = path.join(dir, 'QC');
  const warnings = [];
  const thresholdsFile = path.join(qcDir, 'ManualQC_thresholds.json');
  const thresholds = readJson(thresholdsFile) ?? {};
  const fdThreshold = positiveNumber(thresholds.MaxMeanFD, QC_DEFAULT_MAX_MEAN_FD);
  const useMeanFD = typeof thresholds.UseMeanFD === 'boolean' ? thresholds.UseMeanFD : null;
  const thresholdSource = existsSync(thresholdsFile) ? 'QC/ManualQC_thresholds.json' : 'default';

  const extraIDs = Array.isArray(options.subjectIDs)
    ? options.subjectIDs.map((id) => String(id ?? '').trim()).filter(Boolean)
    : [];
  const subjectSet = new Set(extraIDs);

  const files = QC_MODALITIES.map((modality) => {
    const file = path.join(qcDir, modality.file);
    const tsv = readQcTsv(file);
    return { modality, file, tsv };
  });
  for (const item of files) {
    for (const row of item.tsv.rows) if (row.id) subjectSet.add(row.id);
  }

  const headMotionRaw = readHeadMotion(dir);
  for (const id of headMotionRaw.tsv.ids) if (id) subjectSet.add(id);

  const discovered = discoverSubjectIds(dir);
  for (const id of discovered) subjectSet.add(id);

  const subjectIDs = sortIdList([...subjectSet]);
  const subjectTotal = subjectIDs.length;

  const modalities = files.map(({ modality, file, tsv }) => {
    const scoredRows = tsv.rows.filter((row) => row.score !== null);
    const scoredIds = new Set(scoredRows.map((row) => row.id));
    const scores = scoredRows.map((row) => row.score);
    const meanScore = scores.length ? roundNumber(scores.reduce((a, b) => a + b, 0) / scores.length, 2) : null;
    const minScore = minScoreFor(modality.minKey, thresholds);
    const lowScores = scoredRows.filter((row) => row.score <= 2).map((row) => ({ id: row.id, score: row.score }));
    const belowThreshold = scoredRows
      .filter((row) => row.score < minScore)
      .map((row) => ({ id: row.id, score: row.score, minScore }))
      .filter((row) => !lowScores.some((low) => low.id === row.id))
      .map((row) => ({ id: row.id, score: row.score }));
    const uniqueScored = scoredIds.size;
    const total = Math.max(subjectTotal, uniqueScored);
    const recentComments = tsv.rows
      .filter((row) => row.comment !== '')
      .slice(-5)
      .map((row) => ({ id: row.id, score: row.score, comment: row.comment }));
    return {
      key: modality.key,
      label: modality.label,
      relFile: `QC/${modality.file}`,
      tsvFile: file,
      available: tsv.exists,
      rows: tsv.rows.length,
      scored: uniqueScored,
      total,
      unscored: Math.max(0, total - uniqueScored),
      meanScore,
      minScore,
      lowScores,
      belowThreshold,
      unscoredIDs: subjectIDs.filter((id) => !scoredIds.has(id)),
      recentComments,
      readMessage: tsv.exists ? tsv.message || null : null,
    };
  });

  const hmRows = headMotionRaw.tsv.ids
    .map((id, index) => ({ id, meanFD: headMotionRaw.tsv.meanFD[index] ?? null }))
    .filter((row) => row.meanFD !== null);
  const fdValues = hmRows.map((row) => row.meanFD);
  const headMotion = {
    available: headMotionRaw.tsv.available,
    relFile: headMotionRaw.relFile,
    files: headMotionRaw.candidates.map((file) => path.relative(dir, file).replaceAll('\\', '/')),
    threshold: fdThreshold,
    thresholdSource,
    useMeanFD,
    subjectCount: hmRows.length,
    rows: hmRows,
    over: hmRows.filter((row) => row.meanFD >= fdThreshold),
    minMeanFD: fdValues.length ? roundNumber(Math.min(...fdValues)) : null,
    maxMeanFD: fdValues.length ? roundNumber(Math.max(...fdValues)) : null,
    meanOfMeanFD: fdValues.length ? roundNumber(fdValues.reduce((a, b) => a + b, 0) / fdValues.length) : null,
    readMessage: headMotionRaw.tsv.available ? headMotionRaw.tsv.message || null : null,
  };

  const availableCount = modalities.filter((modality) => modality.available).length;
  if (!existsSync(qcDir)) warnings.push('未找到 QC/ 目录：尚未进行人工 QC（或工作目录不是 DPARSF 输出目录）。');
  if (!availableCount) warnings.push('未找到任何人工 QC 评分 TSV（QC/RawT1ImgQC.tsv、RawFunImgQC.tsv、NormalizationQC.tsv）。');
  if (headMotionRaw.candidates.length > 1) {
    warnings.push(`RealignParameter 下发现 ${headMotionRaw.candidates.length} 个 HeadMotion.tsv（多 session？），已使用 ${headMotion.relFile}。`);
  }
  if (subjectTotal === 0) warnings.push('未能确定受试者总数：目录中既没有 DPARSF 受试者子目录，也没有评分/头动记录。');
  if (existsSync(thresholdsFile) && useMeanFD === false) {
    warnings.push('QC/ManualQC_thresholds.json 中 UseMeanFD=false：MeanFD 阈值默认不参与自动筛选，此处仅作提示。');
  }
  if (!existsSync(qcDir) && !existsSync(path.join(dir, 'RealignParameter')) && discovered.length === 0) {
    warnings.push('目录下未发现 QC/、RealignParameter/ 或 DPARSF 输出目录，可能不是 DPARSF 工作目录。');
  }

  return {
    workDir: dir,
    qcDir,
    hasQcDir: existsSync(qcDir),
    hasScores: availableCount > 0,
    scoredFileCount: availableCount,
    subjectTotal,
    subjectIDs,
    modalities,
    headMotion,
    warnings,
  };
}

function formatQcScore(value) {
  if (value === null || value === undefined) return '—';
  return Number.isInteger(value) ? String(value) : Number(value).toFixed(1);
}

function formatQcFD(value) {
  if (value === null || value === undefined) return '—';
  return Number(value).toFixed(3);
}

function truncateQcText(text, max = 50) {
  const clean = String(text ?? '').replace(/\s+/g, ' ').trim();
  return clean.length > max ? `${clean.slice(0, max)}…` : clean;
}

/** 把 buildQcSummary/opQc 的结果渲染为中文摘要文本（工具、/mri qcstatus、页面共用）。 */
export function renderQcSummary(result) {
  const res = result ?? {};
  const lines = ['人工 QC 摘要'];
  if (res.workDir) lines.push(`- 工作目录：${res.workDir}`);
  if (res.workDirSource) {
    lines.push(`- 工作目录来源：${WORKDIR_SOURCE_LABELS[res.workDirSource] ?? res.workDirSource}`);
  }
  if (res.subjectTotal !== undefined) lines.push(`- 受试者总数：${res.subjectTotal} 名`);
  lines.push('');
  for (const modality of Array.isArray(res.modalities) ? res.modalities : []) {
    if (!modality.available) {
      lines.push(`${modality.label}：未找到 ${modality.relFile}（尚未进行该模态人工 QC）`);
      continue;
    }
    const pct = modality.total > 0 ? Math.round((modality.scored / modality.total) * 100) : 0;
    lines.push(
      `${modality.label}（${modality.relFile}）：已评分 ${modality.scored}/${modality.total}（${pct}%），平均分 ${formatQcScore(modality.meanScore)}`,
    );
    if (modality.lowScores?.length) {
      lines.push(`  · 低分（≤2）：${modality.lowScores.map((row) => `${row.id}（${formatQcScore(row.score)} 分）`).join('；')}`);
    }
    if (modality.belowThreshold?.length) {
      lines.push(
        `  · 低于配置阈值（Min=${modality.minScore}）：${modality.belowThreshold.map((row) => `${row.id}（${formatQcScore(row.score)} 分）`).join('；')}`,
      );
    }
    if (modality.unscoredIDs?.length) {
      lines.push(`  · 未评分（${modality.unscoredIDs.length}）：${modality.unscoredIDs.join('、')}`);
    }
    if (modality.recentComments?.length) {
      lines.push(
        `  · 最近评语：${modality.recentComments.map((row) => `${row.id}「${truncateQcText(row.comment)}」`).join('；')}`,
      );
    }
  }
  const hm = res.headMotion;
  if (hm) {
    if (hm.available) {
      const note = hm.useMeanFD === false ? '；阈值文件 UseMeanFD=false，仅作提示' : '';
      lines.push(`头动（${hm.relFile}）：MeanFD 阈值 ${hm.threshold} mm${note}`);
      if (hm.over?.length) {
        lines.push(
          `  · MeanFD 超阈值（≥ ${hm.threshold} mm）：${hm.over.map((row) => `${row.id}（${formatQcFD(row.meanFD)}）`).join('；')}`,
        );
      } else {
        lines.push(`  · 全部 ${hm.subjectCount} 名受试者 MeanFD 未超阈值`);
      }
      if (hm.subjectCount > 0) {
        lines.push(`  · MeanFD 范围 ${formatQcFD(hm.minMeanFD)}–${formatQcFD(hm.maxMeanFD)}，平均 ${formatQcFD(hm.meanOfMeanFD)}`);
      }
    } else {
      lines.push('头动：未找到 RealignParameter/HeadMotion.tsv（预处理尚未完成头动校正？）');
    }
  }
  if (res.warnings?.length) {
    lines.push('', '注意：');
    for (const warning of res.warnings) lines.push(`- ${warning}`);
  }
  lines.push('');
  if (res.hasScores) {
    lines.push('提示：低分（≤2）或未评分受试者建议人工复核；运行 /mri qc 可在 MATLAB 中打开可缩放人工 QC 查看器。');
  } else {
    lines.push(
      '提示：尚未找到已保存的人工 QC 评分。运行 /mri qc 打开 MATLAB 可缩放人工 QC 查看器开始评分；保存后重新执行 /mri qcstatus 或 mri_workbench_qc 查看汇总。',
    );
  }
  return lines.join('\n');
}

// ------------------------------------------------------------------
// 人工 QC 窗口实时状态（<workDir>/QC/.qcviewer_state.json）——DSH 侧只读读取
//
// 状态文件由 MATLAB 人工 QC 窗口（mrw.QcPanel）在窗口操作后自动写出，
// schema 见 docs/VERIFICATION.md §27（人工 QC 窗口 v2 状态）。这里只读文件、不启动 MATLAB：
// 文件缺失 / JSON 损坏 / 超过 30 分钟未更新都返回中文提示，不抛异常。
// Agent 用法：先 matlab_snapshot 截图看「显示是否正常」，再读本状态拿精确数值
// （十字线体素/世界 mm、AC/PC、显示矩阵、窗宽、叠加、FD、评分）做实时指导。
// ------------------------------------------------------------------

const QC_STATE_SCHEMA = 'mrw.qcviewer.state.v2';
const QC_STATE_VERSION = 2;
const QC_STATE_MAX_AGE_MINUTES = 30;
const QC_STATE_FILE_NAME = '.qcviewer_state.json';
const QC_STATE_VALUES_PREVIEW = 60;

const QC_STATE_MODALITY_LABELS = { T1: 'T1 原始像', Fun: '功能平均像', Norm: '标准化检查' };
const QC_STATE_VIEW_MODE_LABELS = { single: '单视图', triple: '三正交', montage: '多切片网格' };
const QC_STATE_ORIENTATION_LABELS = { axial: '水平位（轴位）', coronal: '冠状位', sagittal: '矢状位' };
const QC_STATE_DISPLAY_MODE_LABELS = {
  native: '原始方位（native）',
  origin: '以十字线设原点',
  acpc: 'AC-PC 配平',
};
const QC_STATE_FILTER_LABELS = {
  all: '全部',
  unscored: '仅未评分',
  scored: '已评分',
  low: '低分（≤阈值）',
  fd: 'MeanFD 超阈值',
};
const QC_STATE_SORT_LABELS = {
  id: '受试者 ID',
  scoreasc: '评分↑',
  scoredesc: '评分↓',
  meanfdasc: 'MeanFD↑',
  meanfddesc: 'MeanFD↓',
};

/** 依次尝试多个字段名（先精确、再忽略大小写），返回第一个非 undefined/null 的值。 */
function qcPick(source, keys) {
  if (!source || typeof source !== 'object' || Array.isArray(source)) return undefined;
  for (const key of keys) {
    const value = source[key];
    if (value !== undefined && value !== null) return value;
  }
  const byLower = new Map();
  for (const key of Object.keys(source)) byLower.set(key.toLowerCase(), key);
  for (const key of keys) {
    const actual = byLower.get(String(key).toLowerCase());
    if (actual === undefined) continue;
    const value = source[actual];
    if (value !== undefined && value !== null) return value;
  }
  return undefined;
}

function qcNumber(value) {
  if (value === null || value === undefined || typeof value === 'boolean') return null;
  if (typeof value === 'string' && value.trim() === '') return null;
  const n = typeof value === 'number' ? value : Number(String(value).trim());
  return Number.isFinite(n) ? n : null;
}

function qcBoolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  const text = String(value ?? '').trim().toLowerCase();
  if (!text) return null;
  if (['true', 'yes', 'on', '1', '是', '开'].includes(text)) return true;
  if (['false', 'no', 'off', '0', '否', '关'].includes(text)) return false;
  return null;
}

function qcVector(value, length = 3) {
  if (Array.isArray(value)) {
    const out = value.slice(0, length).map(qcNumber);
    return out.length === length && out.every((item) => item !== null) ? out : null;
  }
  if (value && typeof value === 'object') {
    const ordered = ['x', 'y', 'z']
      .map((key) => qcNumber(qcPick(value, [key, key.toUpperCase()])));
    if (ordered.every((item) => item !== null)) return ordered;
    const indexed = ['i', 'j', 'k'].map((key) => qcNumber(qcPick(value, [key, key.toUpperCase()])));
    if (indexed.every((item) => item !== null)) return indexed;
  }
  return null;
}

function qcMatrix4(value) {
  if (Array.isArray(value) && value.length === 16 && value.every((item) => qcNumber(item) !== null)) {
    const flat = value.map(qcNumber);
    return [0, 1, 2, 3].map((row) => flat.slice(row * 4, row * 4 + 4));
  }
  if (!Array.isArray(value) || value.length !== 4) return null;
  const rows = value.map((row) => (Array.isArray(row) && row.length === 4 ? row.map(qcNumber) : null));
  if (rows.some((row) => !row || row.some((item) => item === null))) return null;
  return rows;
}

function qcNumText(value, digits = 2) {
  const n = qcNumber(value);
  return n === null ? '—' : n.toFixed(digits);
}

function qcVecText(vec, digits = 2) {
  if (!Array.isArray(vec) || !vec.length) return null;
  return vec
    .map((value) => {
      const n = qcNumber(value);
      if (n === null) return '—';
      return Number.isInteger(n) ? String(n) : n.toFixed(digits);
    })
    .join(', ');
}

/** 解析 updatedAt：支持 ISO 字符串（含时区）、UNIX 秒/毫秒与 MATLAB datenum。 */
function qcParseTime(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    if (value > 1e12) return value; // 毫秒时间戳
    if (value > 1e8) return value * 1000; // 秒时间戳
    if (value > 1e5) return (value - 719529) * 86400000; // MATLAB datenum
    return null;
  }
  if (typeof value !== 'string') return null;
  const text = value.trim();
  if (!text) return null;
  const isoish = text.replace(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)/, '$1T$2');
  let ms = Date.parse(isoish);
  if (!Number.isFinite(ms)) ms = Date.parse(text.replace(/\//g, '-'));
  return Number.isFinite(ms) ? ms : null;
}

/** 把 updatedAt 的墙钟时间（去掉时区标记）按本地时间解读——用于修正 MATLAB 端时区标记错误。 */
function qcParseNaiveLocal(value) {
  if (typeof value !== 'string') return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/.exec(value.trim());
  if (!match) return null;
  const ms = new Date(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6] ?? 0),
  ).getTime();
  return Number.isFinite(ms) ? ms : null;
}

function qcResolveUpdatedAt(value, fallbackMs) {
  const parsed = qcParseTime(value);
  if (parsed !== null) {
    let ms = parsed;
    let ageMinutes = (Date.now() - parsed) / 60000;
    let note = null;
    // 时间戳落在未来 >5 分钟：多半是时区标记写错（例如 MATLAB 端把本地时间标成 -00:00）。
    // 此时按「墙钟即本地时间」再解读一次，若年龄更合理则采用，并提示差异。
    if (ageMinutes < -5 && typeof value === 'string') {
      const naive = qcParseNaiveLocal(value);
      if (naive !== null) {
        const naiveAge = (Date.now() - naive) / 60000;
        if (naiveAge >= -5) {
          ms = naive;
          ageMinutes = naiveAge;
          note = `updatedAt 的时区标记看起来有误（${value.trim()}：按标记解读会把状态时间算到未来），已按本地时间解读计算新鲜度（约 ${Math.round(naiveAge)} 分钟前）。`;
        }
      }
    }
    return {
      text: typeof value === 'string' ? value.trim() : new Date(ms).toISOString(),
      source: 'updatedAt',
      ageMinutes,
      note,
    };
  }
  if (Number.isFinite(fallbackMs)) {
    return {
      text: new Date(fallbackMs).toISOString(),
      source: 'file-mtime',
      ageMinutes: (Date.now() - fallbackMs) / 60000,
      note: null,
    };
  }
  return { text: null, source: null, ageMinutes: null, note: null };
}

function qcNormalizeViewMode(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) return { key: null, raw: null, label: null };
  const lower = raw.toLowerCase();
  const table = {
    single: 'single', one: 'single', '单视图': 'single',
    triple: 'triple', three: 'triple', ortho: 'triple', orthogonal: 'triple', '3': 'triple', '三正交': 'triple', '三视图': 'triple',
    montage: 'montage', multi: 'montage', multiSlice: 'montage', grid: 'montage', '多切片': 'montage', '多切片网格': 'montage',
  };
  let key = table[raw] ?? table[lower];
  if (!key) {
    // 兼容面板直接写中文标签（如「三正交（轴/冠/矢）」「多切片网格」）
    if (raw.includes('三正交') || lower.includes('ortho') || lower.includes('triple')) key = 'triple';
    else if (raw.includes('多切片') || lower.includes('montage') || lower.includes('multi') || lower.includes('grid')) key = 'montage';
    else if (raw.includes('单视图') || lower.includes('single')) key = 'single';
    else key = raw;
  }
  return { key, raw, label: QC_STATE_VIEW_MODE_LABELS[key] ?? raw };
}

function qcNormalizeOrientation(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) return { key: null, raw: null, label: null };
  const lower = raw.toLowerCase();
  const table = {
    axial: 'axial', transverse: 'axial', '横断': 'axial', '水平位': 'axial', '轴位': 'axial', '水平面': 'axial',
    coronal: 'coronal', '冠状': 'coronal', '冠状位': 'coronal',
    sagittal: 'sagittal', '矢状': 'sagittal', '矢状位': 'sagittal',
  };
  let key = table[raw] ?? table[lower];
  if (!key) {
    if (raw.includes('轴') || raw.includes('横断') || raw.includes('水平') || lower.includes('axial')) key = 'axial';
    else if (raw.includes('冠') || lower.includes('coronal')) key = 'coronal';
    else if (raw.includes('矢') || lower.includes('sagittal')) key = 'sagittal';
    else key = raw;
  }
  return { key, raw, label: QC_STATE_ORIENTATION_LABELS[key] ?? raw };
}

function qcNormalizeDisplayMode(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) return { key: null, raw: null, label: null };
  const lower = raw.toLowerCase();
  const table = {
    native: 'native', 原始: 'native', '原始方位': 'native',
    origin: 'origin', 原点: 'origin', '原点校准': 'origin',
    acpc: 'acpc', 'ac-pc': 'acpc', acpc配平: 'acpc',
  };
  let key = table[raw] ?? table[lower];
  if (!key) {
    if (lower.includes('acpc') || lower.includes('ac-pc') || raw.includes('配平')) key = 'acpc';
    else if (lower.includes('origin') || raw.includes('原点')) key = 'origin';
    else if (lower.includes('native') || raw.includes('原始')) key = 'native';
    else key = raw;
  }
  return { key, raw, label: QC_STATE_DISPLAY_MODE_LABELS[key] ?? raw };
}

/** 筛选值归一化：兼容契约键（all/unscored/...）与面板中文标签（仅未评分/已评分/低分≤阈值/MeanFD 超阈值）。 */
function qcNormalizeFilter(value) {
  const raw = typeof value === 'string' ? value.trim() : (value === null || value === undefined ? '' : String(value));
  if (!raw) return { key: null, raw: null, label: null };
  const lower = raw.toLowerCase();
  const exact = {
    all: 'all', 全部: 'all',
    unscored: 'unscored', '仅未评分': 'unscored', 未评分: 'unscored',
    scored: 'scored', '已评分': 'scored',
    low: 'low', lowscore: 'low', 低分: 'low', '低分≤阈值': 'low',
    fd: 'fd', meanfd: 'fd', 'meanfd 超阈值': 'fd', meanfd超阈值: 'fd',
  };
  let key = exact[raw] ?? exact[lower];
  if (!key) {
    if (raw.includes('全部') || lower === 'all') key = 'all';
    else if (raw.includes('未评分')) key = 'unscored';
    else if (raw.includes('低分')) key = 'low';
    else if (lower.includes('meanfd') || raw.includes('头动')) key = 'fd';
    else if (raw.includes('已评分')) key = 'scored';
    else key = raw;
  }
  return { key, raw, label: QC_STATE_FILTER_LABELS[key] ?? raw };
}

/** 排序值归一化：兼容契约键（id/scoreAsc/...）与面板中文标签（受试者 ID/评分↑/MeanFD↓）。 */
function qcNormalizeSort(value) {
  const raw = typeof value === 'string' ? value.trim() : (value === null || value === undefined ? '' : String(value));
  if (!raw) return { key: null, raw: null, label: null };
  const lower = raw.toLowerCase();
  const exact = {
    id: 'id', '受试者 id': 'id', '受试者id': 'id',
    scoreasc: 'scoreasc', '评分↑': 'scoreasc',
    scoredesc: 'scoredesc', '评分↓': 'scoredesc',
    meanfdasc: 'meanfdasc', 'meanfd↑': 'meanfdasc',
    meanfddesc: 'meanfddesc', 'meanfd↓': 'meanfddesc',
  };
  let key = exact[raw] ?? exact[lower];
  if (!key) {
    const descending = /↓|降|desc/i.test(raw);
    if (lower.includes('meanfd') || raw.includes('头动')) key = descending ? 'meanfddesc' : 'meanfdasc';
    else if (lower.includes('score') || raw.includes('评分') || raw.includes('受试者')) {
      if (raw.includes('受试者')) key = 'id';
      else key = descending ? 'scoredesc' : 'scoreasc';
    } else key = 'id';
  }
  return { key, raw, label: QC_STATE_SORT_LABELS[key] ?? raw };
}

function qcNormalizeProgress(value) {
  const out = {};
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, item] of Object.entries(value)) {
      if (item && typeof item === 'object' && !Array.isArray(item)) {
        out[key] = {
          scored: qcNumber(qcPick(item, ['scored', 'Scored', 'done', 'Done'])),
          total: qcNumber(qcPick(item, ['total', 'Total', 'count', 'Count'])),
        };
      } else {
        const scored = qcNumber(item);
        if (scored !== null) out[key] = { scored, total: null };
      }
    }
  }
  for (const key of ['T1', 'Fun', 'Norm']) {
    if (!out[key]) out[key] = { scored: null, total: null };
  }
  return out;
}

function qcNormalizeSlices(value) {
  const out = { axial: null, coronal: null, sagittal: null };
  if (!value || typeof value !== 'object' || Array.isArray(value)) return out;
  for (const orientation of ['axial', 'coronal', 'sagittal']) {
    const item = qcPick(value, [orientation, QC_STATE_ORIENTATION_LABELS[orientation] ?? orientation]);
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
    out[orientation] = {
      index: qcNumber(qcPick(item, ['index', 'Index', 'current', 'sliceIndex'])),
      count: qcNumber(qcPick(item, ['count', 'Count', 'total', 'Counts'])),
    };
  }
  return out;
}

/** 读取并归一化人工 QC 窗口状态 JSON；缺文件/损坏/过期都返回中文提示、不抛异常。 */
export function readQcViewerState(workDir, options = {}) {
  const maxAgeMinutes = positiveNumber(options.maxAgeMinutes, QC_STATE_MAX_AGE_MINUTES);
  const rawWorkDir = typeof workDir === 'string' ? workDir.trim() : '';
  const result = {
    available: false,
    workDir: rawWorkDir ? path.resolve(rawWorkDir) : null,
    stateFile: null,
    stateFileRel: null,
    found: false,
    schema: null,
    schemaExpected: QC_STATE_SCHEMA,
    schemaMatches: null,
    version: null,
    versionExpected: QC_STATE_VERSION,
    updatedAt: null,
    updatedAtSource: null,
    ageMinutes: null,
    maxAgeMinutes,
    stale: false,
    subject: { id: null, index: null, count: null },
    modality: null,
    modalityLabel: null,
    file: null,
    view: { mode: null, modeRaw: null, modeLabel: null, activeOrientation: null, activeOrientationLabel: null },
    crosshair: { voxel: null, world: null, display: null },
    slices: { axial: null, coronal: null, sagittal: null },
    display: {
      mode: null,
      modeLabel: null,
      hasVolume: null,
      matrix: null,
      acVoxel: null,
      acWorld: null,
      pcVoxel: null,
      pcWorld: null,
      distanceMm: null,
      angleDeg: null,
      manualTranslationMm: null,
      manualRotationDeg: null,
      flips: { lr: null, ap: null, is: null },
      message: null,
    },
    viewSettings: { window: null, clim: null, colormap: null, interp: null, zoom: null, crosshairVisible: null },
    overlay: { visible: null, alpha: null, normKind: null },
    score: { current: null, saved: null },
    headMotion: {
      fdType: null,
      fdThreshold: null,
      valueCount: 0,
      values: [],
      valuesTruncated: false,
      meanFD: null,
      maxFD: null,
      badFrames: [],
      badFrameCount: 0,
      badRatio: null,
      maxTranslation: null,
      maxRotation: null,
    },
    filter: null,
    filterLabel: null,
    sort: null,
    sortLabel: null,
    progress: qcNormalizeProgress(undefined),
    stateMessage: null,
    message: '',
    warnings: [],
  };
  if (!rawWorkDir) {
    result.message = '未提供工作目录：请先扫描数据或生成配置，或显式传入 workDir。';
    return result;
  }
  const dir = result.workDir;
  const candidates = [path.join(dir, 'QC', QC_STATE_FILE_NAME), path.join(dir, QC_STATE_FILE_NAME)];
  let stateFile = null;
  for (const candidate of candidates) {
    try {
      if (existsSync(candidate)) {
        stateFile = candidate;
        break;
      }
    } catch {
      /* ignore */
    }
  }
  if (!stateFile) {
    result.message = `MATLAB 人工 QC 窗口未打开或尚未操作：未找到 QC/${QC_STATE_FILE_NAME}（工作目录：${dir}）。请在 MATLAB 人工 QC 窗口中操作一次（切换受试者/切片/视图、调整十字线或 AC-PC、评分），窗口会自动写出状态文件；也可点窗口工具条「复制状态给 Agent」把当前状态粘贴到对话。`;
    return result;
  }
  result.found = true;
  result.stateFile = stateFile;
  result.stateFileRel = path.relative(dir, stateFile).replaceAll('\\', '/');
  if (stateFile !== candidates[0]) {
    result.warnings.push(`未找到 QC/${QC_STATE_FILE_NAME}，已读取工作目录根下的 ${QC_STATE_FILE_NAME}（非契约位置）。`);
  }
  let stat;
  try {
    stat = statSync(stateFile);
  } catch (err) {
    result.message = `状态文件不可读：${err?.message ?? err}`;
    return result;
  }
  if (!stat.isFile()) {
    result.message = `状态路径 ${result.stateFileRel} 不是普通文件。`;
    return result;
  }
  let text;
  try {
    text = readFileSync(stateFile, 'utf8');
  } catch (err) {
    result.message = `状态文件读取失败：${err?.message ?? err}（MATLAB 可能正在写入，请稍后重试）。`;
    return result;
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (err) {
    result.message = `状态文件存在但 JSON 解析失败：${err?.message ?? err}。正常写入为「先写 .json.tmp 再原子替换」，通常不会读到半截文件；请稍后重试，或在 QC 窗口点「复制状态给 Agent」把当前状态直接粘贴到对话。`;
    result.warnings.push('状态文件内容不是合法 JSON，未读取任何显示状态。');
    return result;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    result.message = '状态文件内容不是 JSON 对象（期望 mrw.qcviewer.state.v2），未读取任何显示状态。';
    return result;
  }
  result.available = true;

  // schema / version 兼容性
  const schema = qcPick(raw, ['schema', 'Schema']);
  result.schema = typeof schema === 'string' ? schema : null;
  result.version = qcNumber(qcPick(raw, ['version', 'Version']));
  if (result.schema) {
    result.schemaMatches = result.schema === QC_STATE_SCHEMA;
    if (!result.schemaMatches) {
      result.warnings.push(`状态文件 schema=${result.schema}，与 DSH 侧期望的 ${QC_STATE_SCHEMA} 不一致：可能来自更新/更旧版本的 QC 窗口；已按兼容方式读取，缺失字段显示「—」。`);
    }
  } else {
    result.warnings.push(`状态文件缺少 schema 字段（期望 ${QC_STATE_SCHEMA}）：可能是旧版 QC 窗口写出，已按兼容方式读取。`);
  }
  if (result.version !== null && result.version !== QC_STATE_VERSION) {
    result.warnings.push(`状态文件 version=${result.version}（期望 ${QC_STATE_VERSION}）。`);
  }

  // 更新时间 / 过期判断（updatedAt 优先，缺失时退回文件修改时间）
  const time = qcResolveUpdatedAt(qcPick(raw, ['updatedAt', 'updated_at', 'UpdatedAt']), stat.mtimeMs);
  result.updatedAt = time.text;
  result.updatedAtSource = time.source;
  result.ageMinutes = time.ageMinutes;
  if (time.note) result.warnings.push(time.note);
  if (time.source === 'file-mtime') {
    result.warnings.push('状态文件缺少可解析的 updatedAt，已改用文件修改时间判断是否过期。');
  }
  if (time.ageMinutes !== null) {
    if (time.ageMinutes < -5) {
      result.warnings.push(`状态文件更新时间看起来在未来（约 ${Math.round(-time.ageMinutes)} 分钟后）：请检查系统时钟/时区是否一致。`);
    } else if (time.ageMinutes > maxAgeMinutes) {
      result.stale = true;
      result.warnings.push(`状态文件已超过 ${maxAgeMinutes} 分钟未更新（最后更新：${time.text}，约 ${Math.round(time.ageMinutes)} 分钟前）：MATLAB 人工 QC 窗口可能已关闭或未再操作，显示/校准信息可能已过期；请先在 QC 窗口操作一次后重试。`);
    }
  }

  // 受试者 / 模态 / 文件
  const subjectRaw = qcPick(raw, ['subject']) ?? {};
  result.subject.id = qcPick(raw, ['subjectID', 'SubjectID', 'subjectId', 'subjectId'])
    ?? qcPick(subjectRaw, ['id', 'ID', 'Id', 'subjectID'])
    ?? null;
  result.subject.index = qcNumber(qcPick(raw, ['subjectIndex', 'SubjectIndex', 'subjectIdx'])
    ?? qcPick(subjectRaw, ['index', 'Index', 'idx']));
  result.subject.count = qcNumber(qcPick(raw, ['subjectCount', 'SubjectCount', 'totalSubjects'])
    ?? qcPick(subjectRaw, ['count', 'Count', 'total']));
  result.modality = qcPick(raw, ['modality', 'Modality', 'modal']) ?? null;
  result.modalityLabel = qcPick(raw, ['modalityLabel', 'ModalityLabel'])
    ?? (result.modality ? QC_STATE_MODALITY_LABELS[result.modality] ?? String(result.modality) : null);
  result.file = qcPick(raw, ['file', 'File', 'fileName', 'filename']) ?? null;

  // 视图模式 / 活动方向
  const viewMode = qcNormalizeViewMode(qcPick(raw, ['viewMode', 'ViewMode', 'mode']));
  result.view.mode = viewMode.key;
  result.view.modeRaw = viewMode.raw;
  result.view.modeLabel = viewMode.label;
  const active = qcNormalizeOrientation(qcPick(raw, ['activeOrientation', 'ActiveOrientation', 'orientation']));
  result.view.activeOrientation = active.key;
  result.view.activeOrientationLabel = active.label;

  // 十字线（兼容顶层 crosshairVoxel / 嵌套 crosshair 两种写法）
  const crosshairRaw = qcPick(raw, ['crosshair', 'crosshairInfo']) ?? qcPick(raw.view, ['crosshair']) ?? {};
  result.crosshair.voxel = qcVector(qcPick(raw, ['crosshairVoxel']) ?? qcPick(crosshairRaw, ['voxel', 'Voxel', 'voxelIndex']));
  result.crosshair.world = qcVector(qcPick(raw, ['crosshairWorld']) ?? qcPick(crosshairRaw, ['world', 'World', 'worldMm']));
  result.crosshair.display = qcVector(qcPick(raw, ['crosshairDisplay']) ?? qcPick(crosshairRaw, ['display', 'Display', 'displayMm']));

  // 切片（顶层 slices；部分实现放在 view.slices）
  result.slices = qcNormalizeSlices(qcPick(raw, ['slices', 'Slices']) ?? qcPick(raw.view, ['slices']));

  // 显示变换（顶层 display；AC-PC 兼容 display.acpc 嵌套）
  const displayRaw = qcPick(raw, ['display', 'displayInfo', 'qcDisplay']) ?? qcPick(raw.view, ['display']) ?? {};
  const acpcRaw = qcPick(displayRaw, ['acpc', 'ACPC', 'acPc']) ?? qcPick(raw, ['acpc', 'ACPC']) ?? {};
  const displayMode = qcNormalizeDisplayMode(qcPick(displayRaw, ['mode', 'Mode', 'displayMode']));
  result.display.mode = displayMode.key;
  result.display.modeLabel = displayMode.label;
  const hasVolume = qcBoolean(qcPick(displayRaw, ['hasVolume', 'HasVolume']));
  result.display.hasVolume = hasVolume;
  result.display.matrix = qcMatrix4(qcPick(displayRaw, ['matrix', 'Matrix', 'displayMatrix']))
    ?? qcMatrix4(qcPick(raw, ['displayMatrix', 'DisplayMatrix']));
  result.display.acVoxel = qcVector(qcPick(displayRaw, ['acVoxel']) ?? qcPick(acpcRaw, ['acVoxel', 'ACVoxel']));
  result.display.acWorld = qcVector(qcPick(displayRaw, ['acWorld']) ?? qcPick(acpcRaw, ['acWorld', 'ACWorld']));
  result.display.pcVoxel = qcVector(qcPick(displayRaw, ['pcVoxel']) ?? qcPick(acpcRaw, ['pcVoxel', 'PCVoxel']));
  result.display.pcWorld = qcVector(qcPick(displayRaw, ['pcWorld']) ?? qcPick(acpcRaw, ['pcWorld', 'PCWorld']));
  result.display.distanceMm = qcNumber(qcPick(displayRaw, ['distanceMm', 'acpcDistanceMm'])
    ?? qcPick(acpcRaw, ['distanceMm', 'DistanceMm', 'distance', 'ACPC.distanceMm']));
  result.display.angleDeg = qcNumber(qcPick(displayRaw, ['angleDeg'])
    ?? qcPick(acpcRaw, ['angleDeg', 'AngleDeg', 'angle']));
  const manualRaw = qcPick(displayRaw, ['manual', 'Manual']) ?? {};
  result.display.manualTranslationMm = qcVector(qcPick(displayRaw, ['manualTranslationMm', 'translationMm'])
    ?? qcPick(manualRaw, ['translationMm', 'TranslationMm', 'translation']));
  result.display.manualRotationDeg = qcVector(qcPick(displayRaw, ['manualRotationDeg', 'rotationDeg'])
    ?? qcPick(manualRaw, ['rotationDeg', 'RotationDeg', 'rotation']));
  const flipsRaw = qcPick(displayRaw, ['flips', 'Flips']) ?? qcPick(raw, ['flips']) ?? {};
  result.display.flips = {
    lr: qcBoolean(qcPick(flipsRaw, ['lr', 'LR', 'flipLR'])) ?? qcBoolean(qcPick(displayRaw, ['flipLR'])),
    ap: qcBoolean(qcPick(flipsRaw, ['ap', 'AP', 'flipAP'])) ?? qcBoolean(qcPick(displayRaw, ['flipAP'])),
    is: qcBoolean(qcPick(flipsRaw, ['is', 'IS', 'flipIS'])) ?? qcBoolean(qcPick(displayRaw, ['flipIS'])),
  };
  result.display.message = qcPick(displayRaw, ['message', 'Message']) ?? null;

  // 窗宽 / 色阶 / 插值 / 缩放 / 十字线开关（顶层；兼容 viewSettings 嵌套）
  const viewSettingsRaw = qcPick(raw, ['viewSettings', 'view']) ?? {};
  const windowRaw = qcPick(raw, ['window', 'windowRange', 'windowLowHigh']) ?? qcPick(viewSettingsRaw, ['window']);
  if (Array.isArray(windowRaw) && windowRaw.length >= 2) {
    result.viewSettings.window = [qcNumber(windowRaw[0]), qcNumber(windowRaw[1])];
  } else if (windowRaw && typeof windowRaw === 'object') {
    const low = qcNumber(qcPick(windowRaw, ['low', 'Low', 'min', 'lo']));
    const high = qcNumber(qcPick(windowRaw, ['high', 'High', 'max', 'hi']));
    result.viewSettings.window = [low, high];
  }
  const climRaw = qcPick(raw, ['clim', 'CLim', 'colorLim']) ?? qcPick(viewSettingsRaw, ['clim']);
  if (Array.isArray(climRaw) && climRaw.length >= 2) {
    result.viewSettings.clim = [qcNumber(climRaw[0]), qcNumber(climRaw[1])];
  } else if (climRaw && typeof climRaw === 'object') {
    result.viewSettings.clim = [
      qcNumber(qcPick(climRaw, ['low', 'min'])),
      qcNumber(qcPick(climRaw, ['high', 'max'])),
    ];
  }
  result.viewSettings.colormap = qcPick(raw, ['colormap', 'Colormap', 'cmap', 'colorMap']) ?? qcPick(viewSettingsRaw, ['colormap']) ?? null;
  result.viewSettings.interp = qcPick(raw, ['interp', 'Interp', 'interpolation', 'Interpolation']) ?? qcPick(viewSettingsRaw, ['interp']) ?? null;
  result.viewSettings.zoom = qcNumber(qcPick(raw, ['zoom', 'Zoom', 'zoomFactor']) ?? qcPick(viewSettingsRaw, ['zoom']));
  const crosshairVisible = qcBoolean(qcPick(raw, ['crosshairVisible', 'CrosshairVisible', 'showCrosshair']) ?? qcPick(viewSettingsRaw, ['crosshairVisible']));
  result.viewSettings.crosshairVisible = crosshairVisible;

  // 叠加（模板轮廓）
  const overlayRaw = qcPick(raw, ['overlay', 'Overlay', 'templateOverlay']) ?? qcPick(displayRaw, ['overlay']) ?? {};
  if (overlayRaw && typeof overlayRaw === 'object' && !Array.isArray(overlayRaw)) {
    result.overlay.visible = qcBoolean(qcPick(overlayRaw, ['visible', 'Visible', 'show', 'Show', 'on']));
    result.overlay.alpha = qcNumber(qcPick(overlayRaw, ['alpha', 'Alpha', 'opacity', 'Opacity']));
    result.overlay.normKind = qcPick(overlayRaw, ['normKind', 'NormKind', 'kind', 'Kind', 'type', 'Type', 'subKind']) ?? null;
  }

  // 评分
  const scoreRaw = qcPick(raw, ['score', 'Score']);
  if (scoreRaw && typeof scoreRaw === 'object' && !Array.isArray(scoreRaw)) {
    result.score.current = qcNumber(qcPick(scoreRaw, ['current', 'Current', 'value', 'Value']));
    result.score.saved = qcNumber(qcPick(scoreRaw, ['saved', 'Saved', 'savedScore']));
  } else {
    result.score.current = qcNumber(scoreRaw);
  }
  if (result.score.current === null) {
    result.score.current = qcNumber(qcPick(raw, ['scoreCurrent', 'currentScore']));
  }

  // 头动 / FD（schema 用 headMotion；getState 的字段名是 FD，两种都兼容）
  const hmRaw = qcPick(raw, ['headMotion', 'HeadMotion', 'FD', 'fd', 'motion']) ?? {};
  result.headMotion.fdType = qcPick(hmRaw, ['fdType', 'FDType', 'type', 'Type']) ?? null;
  result.headMotion.fdThreshold = qcNumber(qcPick(hmRaw, ['fdThreshold', 'FDThreshold', 'threshold', 'Threshold']));
  const valuesRaw = qcPick(hmRaw, ['values', 'Values', 'fdValues', 'series', 'FDValues']);
  if (Array.isArray(valuesRaw)) {
    const values = valuesRaw.map(qcNumber).filter((value) => value !== null);
    result.headMotion.valueCount = values.length;
    result.headMotion.values = values.slice(0, QC_STATE_VALUES_PREVIEW);
    result.headMotion.valuesTruncated = values.length > QC_STATE_VALUES_PREVIEW;
  }
  result.headMotion.meanFD = qcNumber(qcPick(hmRaw, ['meanFD', 'MeanFD', 'meanFd']));
  result.headMotion.maxFD = qcNumber(qcPick(hmRaw, ['maxFD', 'MaxFD', 'maxFd']));
  const badFramesRaw = qcPick(hmRaw, ['badFrames', 'BadFrames']);
  if (Array.isArray(badFramesRaw)) {
    result.headMotion.badFrames = badFramesRaw.map(qcNumber).filter((value) => value !== null);
  }
  result.headMotion.badFrameCount = result.headMotion.badFrames.length;
  result.headMotion.badRatio = qcNumber(qcPick(hmRaw, ['badRatio', 'BadRatio', 'ratio']));
  result.headMotion.maxTranslation = qcNumber(qcPick(hmRaw, ['maxTranslation', 'MaxTranslation', 'maxTranslationMm']));
  result.headMotion.maxRotation = qcNumber(qcPick(hmRaw, ['maxRotation', 'MaxRotation', 'maxRotationDeg']));

  // 筛选 / 排序
  const filter = qcNormalizeFilter(qcPick(raw, ['filter', 'Filter']));
  result.filter = filter.key;
  result.filterLabel = filter.label;
  const sort = qcNormalizeSort(qcPick(raw, ['sort', 'Sort']));
  result.sort = sort.key;
  result.sortLabel = sort.label;

  // 评分进度与窗口消息
  result.progress = qcNormalizeProgress(qcPick(raw, ['progress', 'Progress']));
  result.stateMessage = qcPick(raw, ['message', 'Message']) ?? null;

  if (result.stale) {
    result.message = '状态文件已过期：MATLAB 人工 QC 窗口可能已关闭或未再操作';
  } else {
    result.message = '已读取 MATLAB 人工 QC 窗口状态';
  }
  return result;
}

/** 把 readQcViewerState 的结果渲染为中文摘要（工具、/mri qcstate 共用）。 */
export function renderQcState(result) {
  const res = result ?? {};
  const lines = ['人工 QC 窗口状态（MATLAB 实时状态）'];
  if (res.workDir) {
    const source = res.workDirSource ? `（来源：${WORKDIR_SOURCE_LABELS[res.workDirSource] ?? res.workDirSource}）` : '';
    lines.push(`- 工作目录：${res.workDir}${source}`);
  }
  if (!res.available) {
    lines.push(`- 状态：${res.message || '未读取到 MATLAB 人工 QC 窗口状态'}`);
    if (res.found && res.stateFileRel) lines.push(`- 状态文件：${res.stateFileRel}（存在但不可用）`);
    else lines.push(`- 状态文件：QC/${QC_STATE_FILE_NAME}（不存在）`);
    lines.push('', '怎么做：');
    lines.push('- 在 MATLAB 打开人工 QC 窗口（/mri qc 或页面 ④「打开 MATLAB 人工 QC」），操作一次（切换受试者/切片/视图、调整十字线或 AC-PC、评分）后窗口会自动写出状态文件；');
    lines.push('- 或点窗口工具条「复制状态给 Agent」，把剪贴板里的状态直接粘贴到对话；');
    lines.push('- Agent 建议先 matlab_snapshot 截图，再读本状态拿精确数值（仅截图无法得到十字线体素/世界 mm、AC-PC 距离角度、显示矩阵等）；');
    lines.push('- 本工具只读状态文件，不启动 MATLAB，也不代表 QC 评分结论。');
    if (res.warnings?.length) lines.push('', '提醒：\n- ' + res.warnings.join('\n- '));
    return lines.join('\n');
  }

  if (res.updatedAt) {
    const age = res.ageMinutes === null
      ? ''
      : (res.ageMinutes < -5 ? '（时间标记可疑，未按相对时间显示）' : `（约 ${Math.max(0, Math.round(res.ageMinutes))} 分钟前）`);
    const source = res.updatedAtSource === 'file-mtime' ? ' [按文件修改时间]' : '';
    lines.push(`- 最后更新：${res.updatedAt}${age}${source}`);
  }
  if (res.schema) {
    const mismatch = res.schemaMatches === false ? '（与 DSH 期望版本不一致，已兼容读取）' : '';
    lines.push(`- 状态版本：${res.schema}${mismatch}`);
  }
  lines.push('');
  const subject = res.subject ?? {};
  const indexText = Number.isFinite(subject.index)
    ? `（第 ${subject.index}/${Number.isFinite(subject.count) ? subject.count : '?'} 名）`
    : '';
  const modalityText = res.modalityLabel || res.modality ? ` · 模态 ${res.modalityLabel ?? res.modality}` : '';
  lines.push(`- 受试者：${subject.id ?? '—'}${indexText}${modalityText}`);
  if (res.file) lines.push(`- 当前文件：${res.file}`);
  const view = res.view ?? {};
  const modeText = view.modeLabel ?? view.mode ?? '—';
  const activeText = view.activeOrientation ? `（活动方向：${view.activeOrientationLabel ?? view.activeOrientation}）` : '';
  lines.push(`- 视图模式：${modeText}${activeText}`);
  const ch = res.crosshair ?? {};
  const chVoxel = qcVecText(ch.voxel);
  const chWorld = qcVecText(ch.world);
  const chDisplay = qcVecText(ch.display);
  lines.push(`- 十字线：体素 (${chVoxel ?? '—'})；世界 (${chWorld ?? '—'}) mm；显示 (${chDisplay ?? '—'}) mm`);
  const slices = res.slices ?? {};
  const sliceBits = ['axial', 'coronal', 'sagittal']
    .filter((orientation) => slices[orientation])
    .map((orientation) => {
      const item = slices[orientation];
      const label = QC_STATE_ORIENTATION_LABELS[orientation] ?? orientation;
      return `${label} ${Number.isFinite(item.index) ? item.index : '—'}/${Number.isFinite(item.count) ? item.count : '—'}`;
    });
  if (sliceBits.length) lines.push(`- 当前切片：${sliceBits.join('；')}`);
  const dp = res.display ?? {};
  const displayBits = [`显示模式：${dp.modeLabel ?? dp.mode ?? '—'}`];
  if (dp.hasVolume === false) displayBits.push('尚未加载图像');
  if (dp.distanceMm !== null && dp.distanceMm !== undefined) displayBits.push(`AC-PC 距离 ${qcNumText(dp.distanceMm, 2)} mm`);
  if (dp.angleDeg !== null && dp.angleDeg !== undefined) displayBits.push(`配平角度 ${qcNumText(dp.angleDeg, 2)}°`);
  const acText = qcVecText(dp.acVoxel);
  const pcText = qcVecText(dp.pcVoxel);
  if (acText || pcText) displayBits.push(`AC (${acText ?? '—'}) / PC (${pcText ?? '—'})（体素）`);
  if (qcVecText(dp.manualTranslationMm)) displayBits.push(`手动平移 (${qcVecText(dp.manualTranslationMm)}) mm`);
  if (qcVecText(dp.manualRotationDeg)) displayBits.push(`手动旋转 (${qcVecText(dp.manualRotationDeg)})°`);
  const flips = dp.flips ?? {};
  const flipNames = [];
  if (flips.lr === true) flipNames.push('左右');
  if (flips.ap === true) flipNames.push('前后');
  if (flips.is === true) flipNames.push('上下');
  if (flipNames.length) displayBits.push(`翻转：${flipNames.join('/')}`);
  lines.push(`- ${displayBits.join('；')}`);
  if (Array.isArray(dp.matrix)) {
    const matrixText = dp.matrix
      .map((row) => `[${row.map((value) => (Number.isFinite(value) ? Number(value).toFixed(2) : '—')).join(', ')}]`)
      .join(', ');
    lines.push(`- 显示矩阵（4x4，作用于世界 mm）：[${matrixText}]`);
  }
  if (dp.message) lines.push(`- 显示层消息：${dp.message}`);
  const vs = res.viewSettings ?? {};
  const vsBits = [];
  if (Array.isArray(vs.window) && vs.window.some((value) => Number.isFinite(value))) {
    vsBits.push(`窗宽 ${qcNumText(vs.window[0], 0)}–${qcNumText(vs.window[1], 0)}%`);
  }
  if (Array.isArray(vs.clim) && vs.clim.some((value) => Number.isFinite(value))) {
    vsBits.push(`色阶范围 ${qcNumText(vs.clim[0], 0)}–${qcNumText(vs.clim[1], 0)}`);
  }
  if (vs.colormap) vsBits.push(`色阶 ${vs.colormap}`);
  if (vs.interp) vsBits.push(`插值 ${vs.interp}`);
  if (Number.isFinite(vs.zoom)) vsBits.push(`缩放 ${qcNumText(vs.zoom, 2)}×`);
  if (vs.crosshairVisible === true) vsBits.push('十字线显示');
  if (vs.crosshairVisible === false) vsBits.push('十字线隐藏');
  if (vsBits.length) lines.push(`- 显示设置：${vsBits.join('；')}`);
  const overlay = res.overlay ?? {};
  if (overlay.visible === true || overlay.visible === false || Number.isFinite(overlay.alpha)) {
    const overlayBits = [];
    overlayBits.push(overlay.visible === false ? '叠加隐藏' : '叠加显示');
    if (Number.isFinite(overlay.alpha)) overlayBits.push(`透明度 ${qcNumText(overlay.alpha, 2)}`);
    if (overlay.normKind) overlayBits.push(`标准化图 ${overlay.normKind}`);
    lines.push(`- 模板轮廓叠加：${overlayBits.join('，')}`);
  }
  const score = res.score ?? {};
  lines.push(`- 评分：当前 ${score.current === null || score.current === undefined ? '—' : `${score.current} 分`}；已保存 ${score.saved === null || score.saved === undefined ? '—' : `${score.saved} 分`}`);
  const hm = res.headMotion ?? {};
  if (hm.fdType || hm.valueCount > 0 || hm.meanFD !== null) {
    const bits = [`FD 类型 ${hm.fdType ?? '—'}`, `阈值 ${qcNumText(hm.fdThreshold, 2)} mm`];
    if (hm.meanFD !== null && hm.meanFD !== undefined) bits.push(`MeanFD ${qcNumText(hm.meanFD, 3)}`);
    if (hm.maxFD !== null && hm.maxFD !== undefined) bits.push(`最大 FD ${qcNumText(hm.maxFD, 3)}`);
    if (hm.valueCount > 0) {
      const ratio = Number.isFinite(hm.badRatio) ? `（${(hm.badRatio * 100).toFixed(1)}%）` : '';
      bits.push(`坏帧 ${hm.badFrameCount}/${hm.valueCount}${ratio}`);
      if (hm.badFrameCount) {
        const shown = hm.badFrames.slice(0, 12).join('、');
        bits.push(`坏帧帧号 ${shown}${hm.badFrameCount > 12 ? '…' : ''}`);
      }
    }
    if (hm.maxTranslation !== null && hm.maxTranslation !== undefined) bits.push(`最大平移 ${qcNumText(hm.maxTranslation, 2)} mm`);
    if (hm.maxRotation !== null && hm.maxRotation !== undefined) bits.push(`最大旋转 ${qcNumText(hm.maxRotation, 2)}°`);
    if (hm.valuesTruncated) bits.push(`（逐帧曲线共 ${hm.valueCount} 帧，此处仅摘要）`);
    lines.push(`- 头动/曲线：${bits.join('；')}`);
  }
  if (res.filterLabel || res.sortLabel) {
    lines.push(`- 筛选/排序：${res.filterLabel ?? '—'} / ${res.sortLabel ?? '—'}`);
  }
  const progress = res.progress ?? {};
  const progressBits = ['T1', 'Fun', 'Norm']
    .filter((key) => progress[key])
    .map((key) => {
      const item = progress[key];
      return `${key} ${Number.isFinite(item.scored) ? item.scored : '—'}/${Number.isFinite(item.total) ? item.total : '—'}`;
    });
  if (progressBits.length) lines.push(`- 评分进度：${progressBits.join('；')}`);
  if (res.stateMessage) lines.push(`- 窗口消息：${res.stateMessage}`);
  lines.push('');
  if (res.stale) {
    lines.push(`注意：状态已超过 ${res.maxAgeMinutes ?? QC_STATE_MAX_AGE_MINUTES} 分钟未更新，可能已过期——请先在 QC 窗口操作一次；以下数值仅供参考。`);
  }
  lines.push('提示：以上数值来自 MATLAB QC 窗口写出的状态文件，精确坐标/AC-PC/窗宽以这里为准；matlab_snapshot 截图用于判断图像显示是否正常（三正交是否联动、轮廓是否贴合等）。显示层变换（原点/AC-PC/翻转/旋转）只影响显示，不改写 NIfTI。');
  if (res.warnings?.length) lines.push('', '提醒：\n- ' + res.warnings.join('\n- '));
  return lines.join('\n');
}

function uniquePhases(text) {
  const out = [];
  const seen = new Set();
  const re = /([^\r\n:]{3,100}?):\s*([^\s:]{1,80})\s+OK/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const phase = m[1].trim();
    if (phase && !seen.has(phase)) {
      seen.add(phase);
      out.push(phase);
    }
  }
  return out;
}

export function apply(ctx) {
  /** @type {Map<string, any>} session id -> workbench state */
  const states = new Map();

  const logger = ctx.logger ?? { info() {}, warn() {}, error() {} };

  const getState = (agentId) => {
    if (!agentId) return {};
    let s = states.get(agentId);
    if (!s) {
      s = { overrides: [] };
      states.set(agentId, s);
    }
    if (!Array.isArray(s.overrides)) s.overrides = [];
    return s;
  };

  const getService = (name) => {
    try {
      return ctx.get(name);
    } catch {
      return undefined;
    }
  };

  async function resolveWorkspace(agent, signal) {
    const wd = getService('workingDirectory');
    if (wd && agent) {
      try {
        const dir = await wd.ensure(agent, signal);
        if (dir && existsSync(dir)) return dir;
      } catch {
        /* fall through */
      }
    }
    return process.cwd();
  }

  function resolveWorkbenchRoot(workspace) {
    const candidates = [
      process.env.MRI_WORKBENCH_ROOT,
      path.join(workspace, 'MRI_Workbench'),
    ].filter(Boolean);
    for (const c of candidates) {
      const p = path.resolve(c);
      if (existsSync(path.join(p, 'StartWorkbench.m')) && existsSync(path.join(p, '+mrw', 'cli.m'))) return p;
    }
    throw new Error(
      '未找到 MRI_Workbench 目录。请把工作台放在当前工作区的 MRI_Workbench/，或设置环境变量 MRI_WORKBENCH_ROOT。',
    );
  }

  function resolveMatlab() {
    const candidates = [process.env.MATLAB_EXE, ...DEFAULT_MATLAB_CANDIDATES].filter(Boolean);
    for (const c of candidates) {
      try {
        if (c && existsSync(c)) return c;
      } catch {
        /* ignore */
      }
    }
    // 兜底：扫描 D:\Program Files\Matlab 下最新安装
    try {
      const base = 'D:\\Program Files\\Matlab';
      const versions = readdirSync(base).filter((n) => n.startsWith('MatlabR')).sort().reverse();
      for (const v of versions) {
        const exe = path.join(base, v, 'bin', 'matlab.exe');
        if (existsSync(exe)) return exe;
      }
    } catch {
      /* ignore */
    }
    return '';
  }

  function workbenchPaths(state, workspace) {
    const wbRoot = resolveWorkbenchRoot(workspace);
    const dataRoot = path.join(workspace, '.mri-workbench');
    const indexFile = path.join(dataRoot, 'index.json');
    const scanResultFile = path.join(dataRoot, 'scan-result.json');
    return { wbRoot, dataRoot, indexFile, scanResultFile };
  }

  function runMatlabFile(exe, wbRoot, statement, { timeoutMs = 180000, signal } = {}) {
    return new Promise((resolve) => {
      const child = spawn(exe, ['-batch', statement], {
        cwd: wbRoot,
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let stdout = '';
      let stderr = '';
      const cap = 512 * 1024;
      const onData = (chunk, isErr) => {
        const text = decodeConsole(chunk);
        if (isErr) stderr = (stderr + text).slice(-cap);
        else stdout = (stdout + text).slice(-cap);
      };
      child.stdout?.on('data', (c) => onData(c, false));
      child.stderr?.on('data', (c) => onData(c, true));
      let settled = false;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        signal?.removeEventListener?.('abort', onAbort);
        resolve(result);
      };
      const onAbort = () => {
        try {
          if (isWin) spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
          else child.kill('SIGKILL');
        } catch {
          /* ignore */
        }
        finish({ code: -1, stdout, stderr: stderr + '\n[已取消]' });
      };
      signal?.addEventListener?.('abort', onAbort);
      const timer = setTimeout(() => {
        try {
          if (isWin) spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
          else child.kill('SIGKILL');
        } catch {
          /* ignore */
        }
        finish({ code: -1, stdout, stderr: stderr + `\n[超时 ${Math.round(timeoutMs / 1000)} 秒]` });
      }, Math.max(1000, timeoutMs));
      child.on('error', (err) => finish({ code: -1, stdout, stderr: stderr + '\n' + String(err?.message ?? err) }));
      child.on('exit', (code) => finish({ code: typeof code === 'number' ? code : -1, stdout, stderr }));
    });
  }

  function parseCliResult(stdout) {
    const marker = /MRW_RESULT_FILE\s+(.+?)\s*$/m.exec(stdout);
    if (marker) {
      const file = marker[1].trim();
      const value = readJson(file);
      if (value) return value;
      return { ok: false, error: `无法读取 CLI 结果文件：${file}` };
    }
    const block = /MRW_RESULT_BEGIN\s*([\s\S]*?)\s*MRW_RESULT_END/.exec(stdout);
    if (block) {
      try {
        return JSON.parse(block[1]);
      } catch (err) {
        return { ok: false, error: `解析 CLI 输出失败：${err.message}` };
      }
    }
    return { ok: false, error: 'CLI 未返回结果标记（MATLAB 可能启动失败）' };
  }

  // ------------------------------------------------------------------
  // 手动参数覆盖（CfgSchema overrides）
  //   - 页面「参数覆盖」/ 命令 /mri overrides set 把 [{key,value}] 存到会话状态
  //   - 「生成配置并校验」时与工具参数 overrides 合并后交给 MATLAB cli prepare
  // ------------------------------------------------------------------
  function decodeBase64Utf8(text) {
    try {
      return Buffer.from(String(text ?? ''), 'base64').toString('utf8');
    } catch {
      return '';
    }
  }

  function normalizeOverrides(value) {
    const list = [];
    const seen = new Map();
    const skipped = [];
    const items = Array.isArray(value) ? value : [];
    for (const item of items) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        skipped.push(String(item));
        continue;
      }
      const key = typeof item.key === 'string' ? item.key.trim() : '';
      if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$/.test(key)) {
        skipped.push(key || '(空 key)');
        continue;
      }
      if (!Object.prototype.hasOwnProperty.call(item, 'value')) {
        skipped.push(`${key}（缺少 value）`);
        continue;
      }
      const safe = jsonSafe(item.value);
      if (safe === undefined) {
        skipped.push(`${key}（值无效）`);
        continue;
      }
      if (seen.has(key)) list[seen.get(key)] = { key, value: safe };
      else {
        seen.set(key, list.length);
        list.push({ key, value: safe });
      }
    }
    return { list, skipped };
  }

  function mergeOverrides(base, extra) {
    const map = new Map();
    for (const item of Array.isArray(base) ? base : []) if (item && item.key) map.set(item.key, item.value);
    for (const item of Array.isArray(extra) ? extra : []) if (item && item.key) map.set(item.key, item.value);
    return [...map.entries()].map(([key, value]) => ({ key, value }));
  }

  function describeValue(value) {
    try {
      const s = JSON.stringify(value);
      return s === undefined ? 'null' : s;
    } catch {
      return String(value);
    }
  }

  function dependsArray(dep) {
    if (!dep) return [];
    if (Array.isArray(dep)) return dep;
    if (Array.isArray(dep.Conds)) return dep.Conds;
    if (dep.Conds && typeof dep.Conds === 'object') return [dep.Conds];
    if (dep.Key) return [dep];
    return [];
  }

  /** 读取工作台 resources/glossary.tsv 的悬停解释（Key → Tip），供参数弹窗 tooltip 使用。 */
  function loadGlossaryTips(workbenchRoot) {
    const tips = new Map();
    const file = path.join(workbenchRoot, 'resources', 'glossary.tsv');
    try {
      const text = readFileSync(file, 'utf8');
      const lines = text.split(/\r?\n/);
      if (!lines.length) return tips;
      const header = lines[0].split('\t').map((s) => s.trim().toLowerCase());
      const iKey = header.indexOf('key');
      const iTip = header.indexOf('tip');
      if (iKey < 0 || iTip < 0) return tips;
      for (const line of lines.slice(1)) {
        if (!line.trim()) continue;
        const cols = line.split('\t');
        const key = (cols[iKey] ?? '').trim();
        const tip = (cols[iTip] ?? '').trim();
        if (key && tip) tips.set(key, tip);
      }
    } catch {
      /* glossary 缺失时不影响参数列表 */
    }
    return tips;
  }

  async function ensurePrepareState(agentId) {
    const st = getState(agentId);
    if (st.cfgPath && existsSync(st.cfgPath)) return st;
    // 插件重启后的恢复：使用 .mri-workbench/prep 下最新的 Cfg.mat
    try {
      const prepRoot = path.join(st.workspace ?? process.cwd(), '.mri-workbench', 'prep');
      if (existsSync(prepRoot)) {
        const dirs = (await fsp.readdir(prepRoot)).sort().reverse();
        for (const d of dirs) {
          const cfg = path.join(prepRoot, d, 'Cfg.mat');
          if (existsSync(cfg)) {
            st.cfgPath = cfg;
            st.prepareDir = path.join(prepRoot, d);
            // 尽量恢复 prepare 结果（ok/errors 用于阻止运行未通过预检的配置）
            try {
              const saved = JSON.parse(await fsp.readFile(path.join(st.prepareDir, 'cli-result.json'), 'utf8'));
              st.prepare = {
                preset: saved.preset,
                subjectCount: saved.subjectCount,
                workingDir: saved.workingDir,
                startingDirName: saved.startingDirName,
                steps: saved.steps,
                summary: saved.summary,
                ok: saved.ok === true,
                errors: Array.isArray(saved.errors) ? saved.errors : [],
                warnings: Array.isArray(saved.warnings) ? saved.warnings : [],
              };
            } catch {
              /* 旧目录没有 cli-result.json 时忽略 */
            }
            return st;
          }
        }
      }
    } catch {
      /* ignore */
    }
    throw new Error('尚未生成预处理配置：请先扫描数据并执行「生成配置并校验」。');
  }

  async function latestRunDir(workspace) {
    try {
      const runsRoot = path.join(workspace, '.mri-workbench', 'runs');
      if (!existsSync(runsRoot)) return '';
      const dirs = (await fsp.readdir(runsRoot)).sort().reverse();
      for (const d of dirs) {
        const dir = path.join(runsRoot, d);
        if (existsSync(path.join(dir, 'status.json')) || existsSync(path.join(dir, 'run.log'))) return dir;
      }
    } catch {
      /* ignore */
    }
    return '';
  }

  // ------------------------------------------------------------------
  // 核心操作
  // ------------------------------------------------------------------
  async function opEnv(agent) {
    const workspace = await resolveWorkspace(agent);
    const out = { kind: 'mri-workbench', action: 'env' };
    try {
      const wbRoot = resolveWorkbenchRoot(workspace);
      out.workbenchRoot = wbRoot;
      out.workbenchExists = true;
    } catch (err) {
      out.workbenchExists = false;
      out.workbenchError = String(err.message ?? err);
    }
    const matlab = resolveMatlab();
    out.matlabExe = matlab;
    out.matlabExists = !!matlab && existsSync(matlab);
    for (const [key, p] of [
      ['dpabi', process.env.DPABI_ROOT || 'D:\\Software\\DPABI'],
      ['spm', process.env.SPM_ROOT || 'D:\\Software\\spm12'],
    ]) {
      out[`${key}Root`] = p;
      out[`${key}Exists`] = existsSync(p);
    }
    out.presets = PRESETS;
    out.workspace = workspace;
    out.ok = out.workbenchExists && out.matlabExists && out.dpabiExists && out.spmExists;
    return out;
  }

  async function opScan(agent, args, signal) {
    const workspace = await resolveWorkspace(agent, signal);
    const { wbRoot, dataRoot, indexFile, scanResultFile } = workbenchPaths({}, workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const rootDir = path.resolve(String(args.root ?? '').trim());
    if (!rootDir || !existsSync(rootDir)) throw new Error(`数据根目录不存在：${rootDir || '(空)'}`);
    const maxDepth = Number.isFinite(Number(args.maxDepth)) ? Math.max(1, Math.min(20, Number(args.maxDepth))) : 6;
    await fsp.mkdir(dataRoot, { recursive: true });
    const statement =
      `addpath('${matlabQuote(wbRoot)}'); ` +
      `mrw.cli('scan','${matlabQuote(scanResultFile)}','${matlabQuote(rootDir)}','${matlabQuote(indexFile)}',${maxDepth});`;
    const run = await runMatlabFile(matlab, wbRoot, statement, { timeoutMs: 180000, signal });
    const res = parseCliResult(run.stdout);
    if (!res.ok) throw new Error(res.error || run.stderr.slice(-1500) || '扫描失败');
    // 目录处理历史：解释工作目录里 FunImg* 阶段目录/结果目录各自经过哪些处理（纯目录读取，不启动 MATLAB）
    res.processingHistory = buildProcessingHistory(res.workingDir || rootDir, { startingDirName: res.startingDirName });
    const st = getState(agent?.id);
    st.workspace = workspace;
    st.indexPath = res.indexPath;
    st.lastRoot = rootDir;
    st.scan = {
      layout: res.layout,
      layoutName: res.layoutName,
      subjectCount: res.subjectCount,
      workingDir: res.workingDir,
      startingDirName: res.startingDirName,
      functionalSessionNumber: res.functionalSessionNumber,
      tr: res.tr,
      timePoints: res.timePoints,
      sliceNumber: res.sliceNumber,
      isBIDS: res.isBIDS,
      subjects: res.subjects,
    };
    return { kind: 'mri-workbench', action: 'scan', ...res, workspace };
  }

  async function opPrepare(agent, args, signal) {
    const workspace = await resolveWorkspace(agent, signal);
    const st = getState(agent?.id);
    const { wbRoot, indexFile } = workbenchPaths(st, workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const idxPath = args.indexPath && existsSync(String(args.indexPath)) ? String(args.indexPath) : st.indexPath || indexFile;
    if (!idxPath || !existsSync(idxPath)) throw new Error('尚未扫描数据集：请先执行「开始扫描」。');
    let presetIndex = Number(args.preset ?? args.presetIndex ?? 0);
    if (!Number.isFinite(presetIndex) || presetIndex < 1 || presetIndex > PRESETS.length) presetIndex = 1;
    const prepDir = path.join(workspace, '.mri-workbench', 'prep', nowStamp());
    const overridesFile = path.join(prepDir, 'overrides.json');
    const storedOverrides = Array.isArray(st.overrides) ? st.overrides : [];
    const requestedOverrides = Array.isArray(args.overrides) ? args.overrides : [];
    const overrides = mergeOverrides(storedOverrides, requestedOverrides);
    await fsp.mkdir(prepDir, { recursive: true });
    await fsp.writeFile(overridesFile, JSON.stringify(overrides), 'utf8');
    const resultFile = path.join(prepDir, 'cli-result.json');
    const statement =
      `addpath('${matlabQuote(wbRoot)}'); ` +
      `mrw.cli('prepare','${matlabQuote(resultFile)}','${matlabQuote(idxPath)}','${presetIndex}','${matlabQuote(overridesFile)}','${matlabQuote(prepDir)}');`;
    const run = await runMatlabFile(matlab, wbRoot, statement, { timeoutMs: 180000, signal });
    const res = parseCliResult(run.stdout);
    if (!res.cfgPath) throw new Error(res.error || run.stderr.slice(-1500) || '生成配置失败');
    st.workspace = workspace;
    st.cfgPath = res.cfgPath;
    st.prepareDir = prepDir;
    st.prepare = {
      preset: res.preset,
      subjectCount: res.subjectCount,
      workingDir: res.workingDir,
      startingDirName: res.startingDirName,
      steps: res.steps,
      summary: res.summary,
      ok: res.ok === true,
      errors: Array.isArray(res.errors) ? res.errors : [],
      warnings: Array.isArray(res.warnings) ? res.warnings : [],
      overrides,
      overrideCount: overrides.length,
    };
    return {
      kind: 'mri-workbench',
      action: 'prepare',
      ...res,
      overrides,
      overrideCount: overrides.length,
      storedOverrideCount: storedOverrides.length,
      workspace,
    };
  }

  // ------------------------------------------------------------------
  // 可调参数（CfgSchema）读取：首次启动一次 MATLAB 导出 schema 并缓存
  // ------------------------------------------------------------------
  async function opSchema(agent, args = {}, signal) {
    const workspace = await resolveWorkspace(agent, signal);
    const st = getState(agent?.id);
    const cacheFile = path.join(workspace, '.mri-workbench', 'schema.json');
    if (!args.refresh && existsSync(cacheFile)) {
      const cached = readJson(cacheFile);
      if (cached && cached.version === 3 && Array.isArray(cached.entries) && cached.entries.length) {
        st.workspace = workspace;
        return {
          ok: true,
          action: 'schema',
          cached: true,
          workspace,
          count: cached.count ?? cached.entries.length,
          groups: normalizeGroups(cached.groups),
          entries: cached.entries,
          overrides: st.overrides ?? [],
        };
      }
    }
    const wbRoot = resolveWorkbenchRoot(workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const dataRoot = path.join(workspace, '.mri-workbench');
    await fsp.mkdir(dataRoot, { recursive: true });
    const resultFile = path.join(dataRoot, 'schema.cli.json');
    const statement =
      `addpath('${matlabQuote(wbRoot)}'); ` +
      `mrw.cli('schema','${matlabQuote(resultFile)}');`;
    const run = await runMatlabFile(matlab, wbRoot, statement, { timeoutMs: 180000, signal });
    const res = parseCliResult(run.stdout);
    if (!res || !res.ok || !Array.isArray(res.entries)) {
      throw new Error(res?.error || run.stderr.slice(-1200) || '读取 CfgSchema 可调参数失败');
    }
    // 合并 glossary.tsv 的中文悬停解释（字段级 tooltip）
    const tips = loadGlossaryTips(wbRoot);
    const entries = res.entries.map((e) => ({ ...e, tip: tips.get(e.key) || '' }));
    try {
      await fsp.writeFile(
        cacheFile,
        JSON.stringify({ version: 3, count: res.count, groups: normalizeGroups(res.groups), entries }),
        'utf8',
      );
    } catch {
      /* 缓存失败不影响本次结果 */
    }
    st.workspace = workspace;
    return {
      ok: true,
      action: 'schema',
      cached: false,
      workspace,
      count: res.count,
      groups: normalizeGroups(res.groups),
      entries,
      overrides: st.overrides ?? [],
    };
  }

  async function opParams(agent, args = {}, signal) {
    const schema = await opSchema(agent, { refresh: !!args.refresh }, signal);
    const filter = String(args.filter ?? '').trim();
    const needle = filter.toLowerCase();
    let entries = schema.entries;
    if (needle) {
      entries = entries.filter((e) =>
        [e.key, e.label, e.en, e.group].some((x) => String(x ?? '').toLowerCase().includes(needle)),
      );
    }
    const st = getState(agent?.id);
    return {
      ok: true,
      action: 'params',
      workspace: schema.workspace,
      cached: schema.cached,
      filter,
      count: entries.length,
      total: schema.count,
      groups: schema.groups,
      entries,
      overrides: st.overrides ?? [],
    };
  }

  // ------------------------------------------------------------------
  // 会话级参数覆盖（页面/命令与 Agent 共用）
  // ------------------------------------------------------------------
  async function opOverrides(agent, args = {}) {
    const st = getState(agent?.id);
    const action = String(args.action ?? 'show').toLowerCase();
    if (action === 'clear' || action === 'reset') {
      st.overrides = [];
      return { ok: true, action: 'overrides', op: 'clear', overrides: [] };
    }
    if (action === 'set' || action === 'apply') {
      let input = args.overrides;
      if (typeof args.json === 'string' && args.json.trim()) {
        try {
          input = JSON.parse(args.json);
        } catch (err) {
          throw new Error(`参数覆盖不是合法 JSON：${err.message}`);
        }
      }
      const { list, skipped } = normalizeOverrides(input);
      st.overrides = list;
      return { ok: true, action: 'overrides', op: 'set', overrides: list, skipped };
    }
    return { ok: true, action: 'overrides', op: 'show', overrides: st.overrides ?? [] };
  }

  async function opStatus(agent) {
    const workspace = await resolveWorkspace(agent);
    const st = getState(agent?.id);
    if (!st.workspace) st.workspace = workspace;
    if ((!st.runDir || !existsSync(st.runDir)) && workspace) {
      const latest = await latestRunDir(workspace);
      if (latest) {
        st.runDir = latest;
        st.logPath = path.join(latest, 'run.log');
        st.statusPath = path.join(latest, 'status.json');
      }
    }
    const out = {
      kind: 'mri-workbench',
      action: 'status',
      workspace,
      configured: !!st.cfgPath && existsSync(st.cfgPath),
      hasRun: false,
      state: 'idle',
      message: '尚未运行预处理',
      phases: [],
      logTail: '',
    };
    if (st.cfgPath && existsSync(st.cfgPath)) {
      out.cfgPath = st.cfgPath;
      if (st.prepare) out.prepare = st.prepare;
    }
    if (!st.runDir || !existsSync(st.runDir)) {
      return out;
    }
    out.hasRun = true;
    out.runDir = st.runDir;
    out.logPath = st.logPath;
    out.statusPath = st.statusPath;
    const status = (st.statusPath && readJson(st.statusPath)) || undefined;
    if (status) {
      out.state = String(status.State ?? 'running');
      out.message = String(status.Message ?? '');
      if (status.UpdatedAt) out.statusUpdatedAt = String(status.UpdatedAt);
      const elapsed = Number(status.Elapsed);
      if (Number.isFinite(elapsed)) out.elapsedSeconds = elapsed;
    }
    const log = tailText(st.logPath, 48000);
    out.logTail = log.slice(-8000);
    out.phases = uniquePhases(log);
    const jobs = getService('jobs');
    if (st.jobId && jobs && agent?.id) {
      try {
        const view = jobs.get(st.jobId, agent.id);
        out.job = {
          id: view.id,
          status: view.status,
          label: view.label,
          progress: view.progress ?? '',
          detail: view.detail ?? '',
          outputBytes: view.output?.total ?? 0,
        };
        // status.json 缺失时（例如刚启动或被取消），用 Job 状态推导运行状态
        const hasStatusFile = st.statusPath && existsSync(st.statusPath);
        if (!hasStatusFile) {
          const map = {
            running: ['running', '预处理正在运行'],
            stopping: ['cancelling', '正在取消运行'],
            completed: ['finished', '预处理完成'],
            killed: ['cancelled', '预处理已被取消'],
            failed: ['failed', view.detail ?? '预处理失败'],
          };
          const mapped = map[view.status] ?? ['running', '预处理正在运行'];
          out.state = mapped[0];
          out.message = mapped[1];
        }
      } catch {
        out.job = { id: st.jobId, status: 'unknown' };
      }
    } else if (st.jobId) {
      out.job = { id: st.jobId, status: 'unknown' };
    }
    return out;
  }

  function buildJob(agent, st, workspace, exe, wbRoot) {
    const statement =
      `addpath('${matlabQuote(wbRoot)}'); ` +
      `mrw.headlessRunner('${matlabQuote(st.cfgPath)}','${matlabQuote(st.logPath)}','${matlabQuote(st.statusPath)}',0);`;
    return {
      kind: 'bash',
      label: `MATLAB · DPARSF 预处理 · ${st.prepare?.subjectCount ?? '?'} 名受试者`,
      owner: agent.id,
      outputLimitBytes: 16 * 1024 * 1024,
      output: [
        {
          channel: 'stdout',
          read(fromByte) {
            try {
              const size = statSync(st.logPath).size;
              if (size <= fromByte) return { text: '', nextOffset: fromByte, lossy: false };
              const len = Math.min(size - fromByte, 512 * 1024);
              const fd = openSync(st.logPath, 'r');
              const buf = Buffer.alloc(len);
              readSync(fd, buf, 0, len, fromByte);
              closeSync(fd);
              return { text: buf.toString('utf8'), nextOffset: fromByte + len, lossy: size - fromByte > len };
            } catch {
              return { text: '', nextOffset: fromByte, lossy: false };
            }
          },
        },
      ],
      run(job) {
        const child = spawn(exe, ['-batch', statement], {
          cwd: wbRoot,
          windowsHide: true,
          stdio: ['ignore', 'ignore', 'pipe'],
        });
        let stderr = '';
        let lastProgress = '';
        let cancelled = false;
        child.stderr?.on('data', (chunk) => {
          stderr = (stderr + decodeConsole(chunk)).slice(-24000);
        });
        const timer = setInterval(() => {
          try {
            const log = tailText(st.logPath, 8192);
            const phases = uniquePhases(log);
            const last = phases[phases.length - 1];
            if (last && last !== lastProgress) {
              lastProgress = last;
              job.updateProgress(`阶段：${last}`);
            } else if (!last) {
              const line = log.split(/\r?\n/).filter(Boolean).pop() ?? '';
              if (line && line !== lastProgress) {
                lastProgress = line;
                job.updateProgress(line);
              }
            }
          } catch {
            /* ignore */
          }
        }, 2000);
        const done = new Promise((resolve) => {
          let settled = false;
          const settle = (code, hint) => {
            if (settled) return;
            settled = true;
            clearInterval(timer);
            if (cancelled) {
              resolve({ status: 'killed', detail: '用户取消（MATLAB 进程树已终止）' });
              return;
            }
            const status = readJson(st.statusPath) ?? {};
            const state = String(status.State ?? '');
            if (state === 'finished') {
              resolve({ status: 'completed', result: status.Message || '预处理完成' });
            } else if (state === 'failed') {
              resolve({
                status: 'failed',
                detail: `${status.Message || '预处理失败'}${stderr ? `\n${stderr.slice(-800)}` : ''}`,
              });
            } else if (code === 0) {
              resolve({ status: 'completed', result: status.Message || '进程正常退出' });
            } else {
              resolve({
                status: 'failed',
                detail: `${hint || `MATLAB 退出码 ${code}`}${status.Message ? `：${status.Message}` : ''}${stderr ? `\n${stderr.slice(-800)}` : ''}`,
              });
            }
          };
          child.on('error', (err) => settle(-1, `无法启动 MATLAB：${String(err?.message ?? err)}`));
          child.on('exit', (code, sig) => {
            if (sig === 'SIGTERM' || sig === 'SIGKILL') settle(-9, 'MATLAB 进程被终止');
            else settle(typeof code === 'number' ? code : -1);
          });
        });
        return {
          cancel() {
            cancelled = true;
            try {
              if (isWin && child.pid) {
                spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
              } else {
                child.kill('SIGKILL');
              }
            } catch {
              /* ignore */
            }
          },
          done,
        };
      },
    };
  }

  async function opStart(agent, exec) {
    const workspace = await resolveWorkspace(agent, exec?.signal);
    const st = await ensurePrepareState(agent?.id);
    // 预检 fail-safe：检查未通过或没有任何可执行步骤时阻止启动，避免在已处理数据上重复处理
    if (st.prepare && st.prepare.ok === false) {
      const errors = Array.isArray(st.prepare.errors) ? st.prepare.errors.filter(Boolean) : [];
      throw new Error(`运行前检查未通过，已阻止启动：${errors[0] ?? '请修正配置错误后重新「生成配置并校验」。'}`);
    }
    if (st.prepare && Array.isArray(st.prepare.steps)) {
      const realSteps = st.prepare.steps.filter((s) => s && !String(s).includes('未启用任何处理步骤'));
      if (realSteps.length === 0) {
        throw new Error('当前配置没有启用任何步骤（空白/续跑预设需要先勾选要补做的步骤），已阻止启动。');
      }
    }
    const { wbRoot } = workbenchPaths(st, workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const runDir = path.join(workspace, '.mri-workbench', 'runs', nowStamp());
    await fsp.mkdir(runDir, { recursive: true });
    st.workspace = workspace;
    st.runDir = runDir;
    st.logPath = path.join(runDir, 'run.log');
    st.statusPath = path.join(runDir, 'status.json');
    st.startedAt = new Date().toISOString();
    st.jobId = '';
    let jobId = '';
    const jobs = getService('jobs');
    if (jobs && agent?.id) {
      try {
        jobId = String(jobs.start(buildJob(agent, st, workspace, matlab, wbRoot)));
      } catch (err) {
        logger.warn?.(`dsh-mri-workbench: 无法创建 DSH 后台 Job：${err?.message ?? err}，改用独立进程`);
      }
    }
    if (!jobId) {
      // 兜底：没有 jobs 服务时，独立进程写入日志文件，状态仍可轮询。
      const statement =
        `addpath('${matlabQuote(wbRoot)}'); ` +
        `mrw.headlessRunner('${matlabQuote(st.cfgPath)}','${matlabQuote(st.logPath)}','${matlabQuote(st.statusPath)}',0);`;
      const child = spawn(matlab, ['-batch', statement], {
        cwd: wbRoot,
        windowsHide: true,
        detached: true,
        stdio: 'ignore',
      });
      child.unref();
      st.pid = child.pid;
    }
    st.jobId = jobId;
    return {
      kind: 'mri-workbench',
      action: 'start',
      ok: true,
      jobId,
      runDir,
      logPath: st.logPath,
      subjectCount: st.prepare?.subjectCount ?? null,
      preset: st.prepare?.preset ?? null,
      hint: jobId
        ? '预处理已在后台启动。实时日志显示在会话顶部的「后台任务」列表（Jobs），也可以调用 mri_workbench_wait 等待并获取进度。'
        : '预处理已在独立 MATLAB 进程中启动。可调用 mri_workbench_status 轮询进度。',
    };
  }

  async function opCancel(agent) {
    const st = getState(agent?.id);
    const jobs = getService('jobs');
    if (st.jobId && jobs && agent?.id) {
      try {
        const result = jobs.kill(st.jobId, agent.id, '用户取消 MRI 预处理');
        return { kind: 'mri-workbench', action: 'cancel', ok: true, jobId: st.jobId, result };
      } catch (err) {
        return { kind: 'mri-workbench', action: 'cancel', ok: false, error: String(err?.message ?? err) };
      }
    }
    if (st.pid) {
      try {
        spawn('taskkill', ['/PID', String(st.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
        return { kind: 'mri-workbench', action: 'cancel', ok: true, pid: st.pid };
      } catch (err) {
        return { kind: 'mri-workbench', action: 'cancel', ok: false, error: String(err?.message ?? err) };
      }
    }
    return { kind: 'mri-workbench', action: 'cancel', ok: false, error: '当前没有正在运行的预处理任务' };
  }

  async function opWait(agent, args) {
    const st = getState(agent?.id);
    if (!st.runDir) throw new Error('尚未启动预处理任务');
    const jobs = getService('jobs');
    const timeoutMs = Math.max(1000, Math.min(600000, Number(args?.timeoutSec ?? 60) * 1000));
    if (st.jobId && jobs && agent?.id) {
      try {
        const view = await jobs.wait(st.jobId, timeoutMs, agent.id);
        const status = await opStatus(agent);
        const result = {
          kind: 'mri-workbench',
          action: 'wait',
          ok: true,
          jobStatus: view.status,
          state: status.state,
          message: status.message,
          phases: status.phases,
          logTail: status.logTail,
        };
        if (status.elapsedSeconds !== undefined) result.elapsedSeconds = status.elapsedSeconds;
        return result;
      } catch (err) {
        const status = await opStatus(agent);
        return {
          kind: 'mri-workbench',
          action: 'wait',
          ok: false,
          error: String(err?.message ?? err),
          state: status.state,
          logTail: status.logTail,
        };
      }
    }
    // 无 Job：轮询状态文件
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const status = readJson(st.statusPath) ?? {};
      if (status.State === 'finished' || status.State === 'failed') break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    return { kind: 'mri-workbench', action: 'wait', ok: true, ...(await opStatus(agent)) };
  }

  async function opOpenGui(agent) {
    const workspace = await resolveWorkspace(agent);
    const wbRoot = resolveWorkbenchRoot(workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const child = spawn(matlab, ['-r', `"cd('${matlabQuote(wbRoot)}'); StartWorkbench"`], {
      cwd: wbRoot,
      windowsHide: false,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
    return {
      kind: 'mri-workbench',
      action: 'open',
      ok: true,
      message: '已启动 MATLAB 桌面版工作台（StartWorkbench）。若 MATLAB 窗口尚未出现，请等待数秒。',
    };
  }

  // ------------------------------------------------------------------
  // 人工 QC：工作目录推导 / 摘要 / MATLAB 查看器（Host = Node 只读解析为主）
  // ------------------------------------------------------------------
  async function readLatestPrepState(workspace) {
    const prepRoot = path.join(workspace, '.mri-workbench', 'prep');
    try {
      if (!existsSync(prepRoot)) return undefined;
      const dirs = (await fsp.readdir(prepRoot)).sort().reverse();
      for (const dirName of dirs) {
        const stateFile = path.join(prepRoot, dirName, 'state.json');
        if (existsSync(stateFile)) {
          const state = readJson(stateFile);
          if (state) return { stateFile, state };
        }
      }
    } catch {
      /* ignore */
    }
    return undefined;
  }

  function pushSubjectIds(value, out) {
    if (typeof value === 'string') {
      const id = value.trim();
      if (id) out.push(id);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) pushSubjectIds(item, out);
      return;
    }
    if (value && typeof value === 'object') pushSubjectIds(value.id ?? value.ID ?? '', out);
  }

  function findKeyDeep(obj, keys, depth = 0) {
    if (!obj || typeof obj !== 'object' || depth > 6) return undefined;
    for (const [key, value] of Object.entries(obj)) {
      if (keys.includes(key) && typeof value === 'string' && value.trim()) return value;
    }
    for (const value of Object.values(obj)) {
      if (value && typeof value === 'object') {
        const found = findKeyDeep(value, keys, depth + 1);
        if (found) return found;
      }
    }
    return undefined;
  }

  /** 解析人工 QC 使用的工作目录：显式参数 → 最近 prepare/scan → 落盘 state/索引 → 会话工作区。 */
  async function resolveQcWorkDir(agent, explicit) {
    const workspace = await resolveWorkspace(agent);
    const st = getState(agent?.id);
    if (!st.workspace) st.workspace = workspace;
    const subjectIDs = [];
    const existingDir = (dir, source) => {
      if (typeof dir !== 'string' || !dir.trim()) return undefined;
      const resolved = path.resolve(dir.trim());
      try {
        if (existsSync(resolved) && statSync(resolved).isDirectory()) return { workDir: resolved, source };
      } catch {
        /* ignore */
      }
      return undefined;
    };

    if (typeof explicit === 'string' && explicit.trim()) {
      const found = existingDir(explicit, 'argument');
      if (!found) throw new Error(`工作目录不存在或不是目录：${explicit}`);
      return { ...found, workspace, subjectIDs };
    }

    let found = existingDir(st.prepare?.workingDir, 'prepare') || existingDir(st.scan?.workingDir, 'scan');
    if (found) {
      pushSubjectIds(st.scan?.subjects, subjectIDs);
      return { ...found, workspace, subjectIDs };
    }

    const prep = await readLatestPrepState(workspace);
    if (prep?.state) {
      found = existingDir(prep.state.WorkingDir, 'prep-state') || existingDir(prep.state.DataProcessDir, 'prep-state');
      pushSubjectIds(prep.state.SubjectID, subjectIDs);
      if (found) return { ...found, workspace, subjectIDs };
    }

    const scanResult = readJson(path.join(workspace, '.mri-workbench', 'scan-result.json'));
    found = existingDir(findKeyDeep(scanResult, ['workingDir', 'WorkingDir']), 'scan-result');
    pushSubjectIds(scanResult?.subjects, subjectIDs);
    if (found) return { ...found, workspace, subjectIDs };

    const index = readJson(path.join(workspace, '.mri-workbench', 'index.json'));
    found = existingDir(findKeyDeep(index, ['WorkingDir', 'workingDir']), 'index');
    pushSubjectIds(index?.Subjects, subjectIDs);
    if (found) return { ...found, workspace, subjectIDs };

    return { workDir: workspace, source: 'workspace-fallback', workspace, subjectIDs };
  }

  async function opQc(agent, args = {}) {
    const resolved = await resolveQcWorkDir(agent, args?.workDir);
    const summary = buildQcSummary(resolved.workDir, { subjectIDs: resolved.subjectIDs });
    const warnings = [...(summary.warnings ?? [])];
    if (resolved.source === 'workspace-fallback') {
      warnings.push('未能从最近一次扫描/配置推导出工作目录，已回退到当前会话工作区；如不是 DPARSF 工作目录，请显式传入 workDir。');
    }
    return {
      kind: 'mri-workbench',
      action: 'qc',
      ok: true,
      workspace: resolved.workspace,
      workDirSource: resolved.source,
      message: summary.hasScores ? '已汇总人工 QC 评分' : '尚未找到人工 QC 评分文件',
      ...summary,
      warnings,
    };
  }

  /** 用独立 MATLAB 桌面进程打开 mrw.QcViewer.open(workDir, 'T1')（可缩放人工 QC 窗口）。 */
  async function opOpenQcViewer(agent, explicitWorkDir) {
    const workspace = await resolveWorkspace(agent);
    const wbRoot = resolveWorkbenchRoot(workspace);
    const matlab = resolveMatlab();
    if (!matlab || !existsSync(matlab)) throw new Error('未找到 matlab.exe，请设置环境变量 MATLAB_EXE。');
    const viewerFile = path.join(wbRoot, '+mrw', 'QcViewer.m');
    if (!existsSync(viewerFile)) {
      throw new Error(`人工 QC 查看器尚未安装：缺少 ${viewerFile}。请更新 MRI_Workbench 后重试。`);
    }
    const resolved = await resolveQcWorkDir(agent, explicitWorkDir);
    const statement = `addpath('${matlabQuote(wbRoot)}'); mrw.QcViewer.open('${matlabQuote(resolved.workDir)}','T1');`;
    const child = spawn(matlab, ['-r', statement], {
      cwd: wbRoot,
      windowsHide: false,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
    const sourceLabel = WORKDIR_SOURCE_LABELS[resolved.source] ?? resolved.source;
    const notes = [
      '已在 MATLAB 桌面进程中打开「人工 QC — 可缩放查看」窗口（默认 T1 原始像）。',
      `- 工作目录：${resolved.workDir}（来源：${sourceLabel}）`,
      '- 若 MATLAB 窗口未立即出现，请等待数秒（首次启动较慢）。',
      '- 评分与评语请在 MATLAB 窗口内保存；保存后点页面「刷新 QC 评分」或执行 /mri qcstatus 查看汇总。',
      '- 对话中的 mri_workbench_qc 只汇总已保存的评分，不会伪造 QC 结论。',
    ];
    if (resolved.source === 'workspace-fallback') {
      notes.push('- 注意：未找到最近配置的工作目录，查看器中暂用当前会话工作区；可在窗口内改选工作目录。');
    }
    return {
      kind: 'mri-workbench',
      action: 'qc-open',
      ok: true,
      workDir: resolved.workDir,
      workDirSource: resolved.source,
      matlabExe: matlab,
      message: notes.join('\n'),
    };
  }

  /** 读取 MATLAB 人工 QC 窗口写出的实时状态（<workDir>/QC/.qcviewer_state.json，不启动 MATLAB）。 */
  async function opQcState(agent, args = {}) {
    let resolved;
    try {
      resolved = await resolveQcWorkDir(agent, args?.workDir);
    } catch (err) {
      return {
        kind: 'mri-workbench',
        action: 'qcstate',
        ok: false,
        available: false,
        workDir: typeof args?.workDir === 'string' ? args.workDir : null,
        stateFile: null,
        stateFileRel: null,
        found: false,
        message: `工作目录不可用：${err?.message ?? err}。可先执行 /mri scan 或 /mri prepare 确定工作目录，或显式传入 workDir。`,
        warnings: [],
      };
    }
    const result = readQcViewerState(resolved.workDir);
    const warnings = [...(result.warnings ?? [])];
    if (resolved.source === 'workspace-fallback') {
      warnings.push('未能从最近一次扫描/配置推导出工作目录，已回退到当前会话工作区；如不是 DPARSF 工作目录，请显式传入 workDir。');
    }
    return {
      kind: 'mri-workbench',
      action: 'qcstate',
      ok: true,
      workspace: resolved.workspace,
      workDirSource: resolved.source,
      ...result,
      workDir: result.workDir ?? resolved.workDir,
      warnings,
    };
  }

  // ------------------------------------------------------------------
  // 头动结果解读：RealignParameter/HeadMotion.tsv + 逐帧 FD 曲线（纯 Node 只读，不启动 MATLAB）
  // ------------------------------------------------------------------
  const HEAD_MOTION_FIELDS = [
    { title: 'max(abs(Tx))', key: 'maxTx', zh: 'X 方向最大平移', unit: 'mm', digits: 3 },
    { title: 'max(abs(Ty))', key: 'maxTy', zh: 'Y 方向最大平移', unit: 'mm', digits: 3 },
    { title: 'max(abs(Tz))', key: 'maxTz', zh: 'Z 方向最大平移', unit: 'mm', digits: 3 },
    { title: 'max(abs(Rx))', key: 'maxRx', zh: '绕 X 轴最大旋转', unit: '°', digits: 3 },
    { title: 'max(abs(Ry))', key: 'maxRy', zh: '绕 Y 轴最大旋转', unit: '°', digits: 3 },
    { title: 'max(abs(Rz))', key: 'maxRz', zh: '绕 Z 轴最大旋转', unit: '°', digits: 3 },
    { title: 'mean(abs(Tx))', key: 'meanTx', zh: 'X 方向平均平移', unit: 'mm', digits: 3 },
    { title: 'mean(abs(Ty))', key: 'meanTy', zh: 'Y 方向平均平移', unit: 'mm', digits: 3 },
    { title: 'mean(abs(Tz))', key: 'meanTz', zh: 'Z 方向平均平移', unit: 'mm', digits: 3 },
    { title: 'mean(abs(Rx))', key: 'meanRx', zh: '绕 X 轴平均旋转', unit: '°', digits: 3 },
    { title: 'mean(abs(Ry))', key: 'meanRy', zh: '绕 Y 轴平均旋转', unit: '°', digits: 3 },
    { title: 'mean(abs(Rz))', key: 'meanRz', zh: '绕 Z 轴平均旋转', unit: '°', digits: 3 },
    { title: 'mean RMS', key: 'meanRMS', zh: '平均平移向量长度', unit: 'mm', digits: 3 },
    { title: 'mean relative RMS (mean FD_VanDijk)', key: 'meanFDVanDijk', zh: '平均相对 RMS（FD_VanDijk）', unit: 'mm', digits: 3 },
    { title: 'mean FD_Power', key: 'meanFDPower', zh: '平均 FD_Power', unit: 'mm', digits: 3 },
    { title: 'Number of FD_Power>0.5', key: 'nFDPower05', zh: 'FD_Power>0.5 的帧数', unit: '帧', digits: 0 },
    { title: 'Percent of FD_Power>0.5', key: 'pctFDPower05', zh: 'FD_Power>0.5 的帧占比（0–1 比例）', unit: '', digits: 4, percentFraction: true },
    { title: 'Number of FD_Power>0.2', key: 'nFDPower02', zh: 'FD_Power>0.2 的帧数', unit: '帧', digits: 0 },
    { title: 'Percent of FD_Power>0.2', key: 'pctFDPower02', zh: 'FD_Power>0.2 的帧占比（0–1 比例）', unit: '', digits: 4, percentFraction: true },
    { title: 'mean FD_Jenkinson', key: 'meanFDJenkinson', zh: '平均 FD_Jenkinson', unit: 'mm', digits: 3 },
  ];

  const HEAD_MOTION_EXPLANATIONS = {
    overview: [
      '这些数字来自 DPARSF 头动校正后的 RealignParameter/HeadMotion.tsv 与逐帧 FD 文件（每名受试者一个目录）。',
      'Tx/Ty/Tz 是相对参考帧的平移（mm），Rx/Ry/Rz 是旋转（度）。max 表示整段扫描的最大绝对值，mean 表示平均绝对值——max 用来发现偶发大动作，mean 反映整体头动水平。',
      'mean FD_Jenkinson（平均 Jenkinson 帧位移）是相邻帧相对位移的均方根（mm，FSL 口径，旋转按 80 mm 半径折算），DPABI 通常拿它做组分析前的参考阈值（常用 0.2 mm，不是硬性诊断线）。',
      'mean FD_Power 是相邻帧位移绝对值之和（旋转按 50 mm 半径折算，mm）；表格中的 Number/Percent of FD_Power>0.2/0.5 表示超过常用坏点阈值的帧数与占比（DPABI 表里 Percent 存的是 0–1 比例，本页面显示时换算成 %）。',
      'mean RMS 是平移向量长度的均值；mean relative RMS（FD_VanDijk）只看平移向量的帧间变化。',
      '体素特异头动指标（TDvox/FDvox）不在 TSV 里，而是图像：VoxelSpecificHeadMotion/<受试者>/ 与 Results/MeanVoxelSpecificHeadMotion_*，可用 DPABI/查看器打开。',
      '页面里的“提示”是按均值和坏点占比做的启发式解读，只用于快速识别需要回看的受试者，不替代人工 QC 评分。',
    ],
    thresholdNote: '参考阈值：mean FD_Jenkinson 常用 0.2 mm；FD_Power 常用 0.2 / 0.5 mm。不同文献/研究可自定义，务必在方法里写清楚并全组一致。',
    exclusionNote: 'DPARSF 还会按“最大头动”写出 ExcludeSubjectsAccordingToMaxHeadMotion.txt（3.0/2.5/2.0/1.5/1.0/0.5 mm 与度），列出各标准下会被排除的受试者；这是按单帧最大动作的筛查，不等于最终入组决定。',
  };

  // 经验分级参考（仅用于快速定位需要回看的受试者，不是诊断/入组标准）
  const HEAD_MOTION_GRADING = {
    maxTranslation: [
      { max: 1.0, level: 'ok', label: '≤1.0 mm 可接受' },
      { max: 2.0, level: 'attention', label: '1.0–2.0 mm 需关注' },
      { max: 3.0, level: 'warn', label: '2.0–3.0 mm 偏大' },
      { max: null, level: 'bad', label: '>3.0 mm 较大' },
    ],
    maxRotation: [
      { max: 1.0, level: 'ok', label: '≤1.0° 可接受' },
      { max: 2.0, level: 'attention', label: '1.0–2.0° 需关注' },
      { max: 3.0, level: 'warn', label: '2.0–3.0° 偏大' },
      { max: null, level: 'bad', label: '>3.0° 较大' },
    ],
    badFrameRatio: [
      { max: 5, level: 'ok', label: '≤5% 少' },
      { max: 15, level: 'attention', label: '5–15% 中等' },
      { max: 30, level: 'warn', label: '15–30% 偏高' },
      { max: null, level: 'bad', label: '>30% 高' },
    ],
  };

  const HEAD_MOTION_REFERENCES = {
    maxTranslation: {
      label: '最大平移',
      unit: 'mm',
      tiers: HEAD_MOTION_GRADING.maxTranslation,
    },
    maxRotation: {
      label: '最大旋转',
      unit: '°',
      tiers: HEAD_MOTION_GRADING.maxRotation,
    },
    badFrameRatio: {
      label: '坏帧比例（FD_Power>0.2）',
      unit: '%',
      tiers: HEAD_MOTION_GRADING.badFrameRatio,
    },
    gradingNote: '平移/旋转分级取自 DPARSF 常用的最大头动排除档位（1.0/2.0/3.0 mm 与度）的简化；坏帧比例分级为工作台经验参考（非文献共识），不同研究可自定义阈值，请在方法中写明并在组内保持一致。以上只用于快速定位需要回看的受试者，不替代人工 QC 或最终入组决定。',
  };

  const HEAD_MOTION_SCRUBBING_NOTES = [
    'Scrubbing（censor）= 按逐帧 FD 阈值标记坏帧，再在指标计算/回归阶段剔除或插值；常用每帧阈值是 FD_Jenkinson > 0.2 mm 或 FD_Power > 0.5 mm（不同研究可自定义，需在方法里写明）。',
    'DPABI/DPARSF 做法一（缩短序列）：Cfg.IsScrubbing=1，配合 Scrubbing.FDType（FD_Jenkinson/FD_Power）、Scrubbing.FDThreshold、Scrubbing.ScrubbingMethod（cut=删除；nearest/linear/spline/pchip=插值，序列长度不变）。',
    'DPABI/DPARSF 做法二（不缩短序列）：Covremove.IsHeadMotionScrubbingRegressors=1，把坏帧做成逐帧回归量；与做法一不要同时开启。',
    '邻域扩展：Scrubbing.PreviousPoints/LaterPoints 可把坏帧前后若干帧一并标记（头动伪影常波及相邻帧），但会减少有效帧数。',
    '坏帧比例高（如 >20–30%）时，剔除/插值只能部分挽救；建议结合 mean FD、最大头动与人工 QC 综合判断。',
  ];

  const HEAD_MOTION_SCRUBBING_FIELDS = [
    { key: 'IsScrubbing', zh: '启用 scrubbing（剔除/插值坏帧）', type: 'bool' },
    { key: 'Scrubbing.FDType', zh: 'FD 类型', type: 'enum', options: ['FD_Jenkinson', 'FD_Power'] },
    { key: 'Scrubbing.FDThreshold', zh: '每帧 FD 阈值', type: 'double', unit: 'mm' },
    { key: 'Scrubbing.ScrubbingMethod', zh: '坏帧处理方式', type: 'enum', options: ['cut', 'nearest', 'linear', 'spline', 'pchip'] },
    { key: 'Scrubbing.PreviousPoints', zh: '向前扩展帧数', type: 'int' },
    { key: 'Scrubbing.LaterPoints', zh: '向后扩展帧数', type: 'int' },
    { key: 'Covremove.IsHeadMotionScrubbingRegressors', zh: '回归量方式（不缩短序列）', type: 'bool' },
  ];

  function gradeHeadMotionValue(value, tiers) {
    if (!Number.isFinite(value)) return { level: 'unknown', label: '无数据' };
    for (const tier of tiers) {
      if (tier.max === null || value <= tier.max) return { level: tier.level, label: tier.label };
    }
    return { level: 'unknown', label: '无数据' };
  }

  function gradeHeadMotionSubject(subject) {
    const metrics = subject.metrics || {};
    const badFrameRatio = Number.isFinite(metrics.pctFDPower02) ? metrics.pctFDPower02 * 100 : null;
    return {
      maxTranslation: gradeHeadMotionValue(subject.maxTranslation, HEAD_MOTION_GRADING.maxTranslation),
      maxRotation: gradeHeadMotionValue(subject.maxRotation, HEAD_MOTION_GRADING.maxRotation),
      badFrameRatio: gradeHeadMotionValue(badFrameRatio, HEAD_MOTION_GRADING.badFrameRatio),
    };
  }

  function normalizeMeanFdThreshold(value) {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) return 0.2;
    return Math.min(5, Math.max(0.01, n));
  }

  function parseHeadMotionTable(workDir) {
    const file = path.join(workDir, 'RealignParameter', 'HeadMotion.tsv');
    const empty = { exists: false, file, header: [], fields: [], subjects: [], message: '' };
    const read = readTextFile(file);
    if (!read.ok) return { ...empty, message: read.message };
    const lines = read.text.split(/\r?\n/).filter((line) => line.trim() !== '');
    if (!lines.length) return { ...empty, exists: true, message: '文件为空' };
    const header = lines[0].split('\t').map((cell) => cell.trim());
    const fields = [];
    for (let i = 1; i < header.length; i++) {
      const meta = HEAD_MOTION_FIELDS.find((f) => f.title === header[i]) || {
        key: `col${i}`, zh: header[i], unit: '', digits: 3,
      };
      fields.push({ ...meta, index: i, title: header[i] });
    }
    const subjects = [];
    for (let li = 1; li < lines.length; li++) {
      const cells = lines[li].split('\t');
      const id = (cells[0] ?? '').trim();
      if (!id) continue;
      const metrics = {};
      for (const f of fields) metrics[f.key] = parseQcNumber(cells[f.index]);
      subjects.push({ id, metrics });
    }
    return { exists: true, file, header, fields, subjects, message: '' };
  }

  function parseNumericSeries(file) {
    const read = readTextFile(file);
    if (!read.ok) return null;
    const values = read.text.split(/[\s,;]+/).map(parseQcNumber).filter((v) => v !== null);
    return values.length ? values : null;
  }

  function findFdSeriesFiles(workDir, subjectId) {
    const baseDir = path.join(workDir, 'RealignParameter', subjectId);
    const out = { jenkinson: null, power: null, vandijk: null, files: {} };
    let names = [];
    try {
      names = readdirSync(baseDir);
    } catch {
      return out;
    }
    const pick = (prefix) => names.find((name) => name.startsWith(prefix) && name.toLowerCase().endsWith('.txt'));
    for (const [key, prefix] of [['jenkinson', 'FD_Jenkinson_'], ['power', 'FD_Power_'], ['vandijk', 'FD_VanDijk_']]) {
      const name = pick(prefix);
      if (!name) continue;
      const file = path.join(baseDir, name);
      const values = parseNumericSeries(file);
      if (values) {
        out[key] = values;
        out.files[key] = file;
      }
    }
    return out;
  }

  function thinSeries(values, target = 600) {
    if (!Array.isArray(values) || values.length <= target) return values;
    const step = values.length / target;
    const out = [];
    for (let k = 0; k < target; k++) {
      out.push(values[Math.min(values.length - 1, Math.round(k * step))]);
    }
    return out;
  }

  function parseExcludeSubjectsFile(workDir) {
    const file = path.join(workDir, 'RealignParameter', 'ExcludeSubjectsAccordingToMaxHeadMotion.txt');
    const read = readTextFile(file);
    if (!read.ok) return { exists: false, file, groups: [] };
    const groups = [];
    let current = null;
    for (const line of read.text.split(/\r?\n/)) {
      const text = line.trim();
      if (!text) continue;
      const match = text.match(/^Excluding Criteria:\s*(.+)$/i);
      if (match) {
        current = { criteria: match[1].trim(), subjects: [] };
        groups.push(current);
        continue;
      }
      if (current && !/^none$/i.test(text)) current.subjects.push(text);
    }
    return { exists: true, file, groups };
  }

  function maxOfMetric(metrics, keys) {
    let best = 0;
    for (const key of keys) {
      const value = Number(metrics[key]);
      if (Number.isFinite(value)) best = Math.max(best, Math.abs(value));
    }
    return best;
  }

  function headMotionVerdict(metrics, threshold) {
    const mean = Number.isFinite(metrics.meanFDJenkinson) ? metrics.meanFDJenkinson : null;
    const pctOver02 = Number.isFinite(metrics.pctFDPower02) ? metrics.pctFDPower02 * 100 : null;
    const maxTranslation = maxOfMetric(metrics, ['maxTx', 'maxTy', 'maxTz']);
    const maxRotation = maxOfMetric(metrics, ['maxRx', 'maxRy', 'maxRz']);
    let level = 'unknown';
    let label = '缺少均值';
    if (mean !== null) {
      if (mean <= 0.1) { level = 'ok'; label = '头动较小'; }
      else if (mean <= threshold) { level = 'attention'; label = '处于常见可接受范围'; }
      else if (mean <= 0.5) { level = 'warn'; label = '偏大，建议关注'; }
      else { level = 'bad'; label = '较大，建议人工复核'; }
      if (pctOver02 !== null && pctOver02 > 20) {
        if (level === 'ok') { level = 'attention'; label = '均值较小，但坏点比例偏高'; }
      }
    }
    const reasons = [];
    if (mean !== null) reasons.push(`mean FD_Jenkinson ${mean.toFixed(3)} mm（参考阈值 ${threshold} mm）`);
    if (pctOver02 !== null) reasons.push(`FD_Power>0.2 的帧占 ${pctOver02.toFixed(1)}%${pctOver02 > 20 ? '（偏高）' : ''}`);
    if (maxTranslation || maxRotation) {
      reasons.push(`最大平移 ${maxTranslation.toFixed(2)} mm、最大旋转 ${maxRotation.toFixed(2)}°`);
    }
    if (maxTranslation > 3 || maxRotation > 3) {
      reasons.push('单帧最大平移/旋转超过 3 mm/3°，建议回看原始图像确认是否为伪影');
    }
    return { level, label, reasons, threshold, maxTranslation, maxRotation };
  }

  function buildHeadMotionSummary(subjects, threshold) {
    const values = subjects.map((s) => s.metrics.meanFDJenkinson).filter((v) => Number.isFinite(v));
    const sorted = [...values].sort((a, b) => a - b);
    const mean = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
    const median = sorted.length
      ? (sorted.length % 2 ? sorted[(sorted.length - 1) / 2] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2)
      : null;
    const overThreshold = subjects
      .filter((s) => Number.isFinite(s.metrics.meanFDJenkinson) && s.metrics.meanFDJenkinson >= threshold)
      .map((s) => s.id);
    let worstSubject = null;
    let worstValue = -Infinity;
    for (const sub of subjects) {
      const value = Number(sub.metrics.meanFDJenkinson);
      if (Number.isFinite(value) && value > worstValue) {
        worstValue = value;
        worstSubject = sub.id;
      }
    }
    return {
      count: subjects.length,
      mean,
      median,
      max: sorted.length ? sorted[sorted.length - 1] : null,
      min: sorted.length ? sorted[0] : null,
      threshold,
      overThreshold,
      worstSubject,
    };
  }

  function buildHeadMotionResults(workDir, opts = {}) {
    const threshold = normalizeMeanFdThreshold(opts.threshold);
    const table = parseHeadMotionTable(workDir);
    const exclude = parseExcludeSubjectsFile(workDir);
    const realignDir = path.join(workDir, 'RealignParameter');
    if (!table.exists || !table.subjects.length) {
      return {
        available: false,
        workDir,
        threshold,
        message: table.message
          ? `未找到可读的 RealignParameter/HeadMotion.tsv：${table.message}`
          : '未找到 RealignParameter/HeadMotion.tsv —— 头动校正（IsRealign=1）完成后才会有该文件。',
        files: { headMotionTsv: table.file, realignParameterDir: realignDir },
        excludedByMaxMotion: exclude.groups,
        explanations: HEAD_MOTION_EXPLANATIONS,
        warnings: [],
      };
    }
    const subjects = table.subjects.map((row) => {
      const series = findFdSeriesFiles(workDir, row.id);
      const verdict = headMotionVerdict(row.metrics, threshold);
      const frames = series.jenkinson?.length ?? series.power?.length ?? null;
      const subject = {
        id: row.id,
        metrics: row.metrics,
        maxTranslation: verdict.maxTranslation,
        maxRotation: verdict.maxRotation,
        verdict,
        frames,
        series: {
          jenkinson: thinSeries(series.jenkinson),
          power: thinSeries(series.power),
          vandijk: thinSeries(series.vandijk),
        },
        seriesFiles: series.files,
      };
      subject.grades = gradeHeadMotionSubject(subject);
      return subject;
    });
    const summary = buildHeadMotionSummary(subjects, threshold);
    const warnings = [];
    if (subjects.some((s) => !s.series.jenkinson?.length)) {
      warnings.push('部分受试者缺少逐帧 FD_Jenkinson 文件（RealignParameter/<受试者>/FD_Jenkinson_*.txt），曲线可能为空。');
    }
    const voxelDir = path.join(workDir, 'VoxelSpecificHeadMotion');
    const resultsDir = path.join(workDir, 'Results');
    return {
      available: true,
      workDir,
      threshold,
      message: `已读取 ${subjects.length} 名受试者的头动指标与逐帧 FD 曲线`,
      files: {
        headMotionTsv: table.file,
        realignParameterDir: realignDir,
        excludeFile: exclude.exists ? exclude.file : null,
        voxelSpecificDir: existsSync(voxelDir) ? voxelDir : null,
        resultsDir: existsSync(resultsDir) ? resultsDir : null,
      },
      fields: table.fields.map((f) => ({
        key: f.key, title: f.title, zh: f.zh, unit: f.unit, digits: f.digits,
        percentFraction: !!f.percentFraction,
      })),
      subjects,
      summary,
      defaultSubjectId: summary.worstSubject ?? subjects[0]?.id ?? null,
      excludedByMaxMotion: exclude.groups,
      references: HEAD_MOTION_REFERENCES,
      scrubbing: { notes: HEAD_MOTION_SCRUBBING_NOTES, fields: HEAD_MOTION_SCRUBBING_FIELDS },
      explanations: HEAD_MOTION_EXPLANATIONS,
      warnings,
    };
  }

  async function opResults(agent, args = {}) {
    const resolved = await resolveQcWorkDir(agent, args?.workDir);
    const result = buildHeadMotionResults(resolved.workDir, { threshold: args?.threshold });
    const warnings = [...(result.warnings ?? [])];
    if (resolved.source === 'workspace-fallback') {
      warnings.push('未能从最近一次扫描/配置推导出工作目录，已回退到当前会话工作区；如不是 DPARSF 工作目录，请显式传入 workDir。');
    }
    return {
      kind: 'mri-workbench',
      action: 'results',
      ok: true,
      workspace: resolved.workspace,
      workDir: resolved.workDir,
      workDirSource: resolved.source,
      ...result,
      warnings,
    };
  }

  function numText(value, digits = 3) {
    const n = Number(value);
    return Number.isFinite(n) ? n.toFixed(digits) : '—';
  }

  function renderResults(res) {
    const lines = [
      'DPARSF 头动结果解读（RealignParameter）',
      `- 工作目录：${res.workDir}（来源：${WORKDIR_SOURCE_LABELS[res.workDirSource] ?? res.workDirSource}）`,
    ];
    if (!res.available) {
      lines.push(`- 状态：${res.message ?? '未找到头动结果'}`);
      lines.push('- 说明：需要先完成头动校正（IsRealign=1）；结果文件为 RealignParameter/HeadMotion.tsv 与每名受试者的 FD_*.txt。');
      if (strList(res.warnings).length) lines.push('提醒：\n- ' + strList(res.warnings).join('\n- '));
      return lines.join('\n');
    }
    const s = res.summary;
    lines.push(`- 受试者：${res.subjects.length} 名；每名帧数：${res.subjects[0]?.frames ?? '?'}`);
    lines.push(`- 组均值 mean FD_Jenkinson：${numText(s.mean, 3)} mm（中位数 ${numText(s.median, 3)}，最大 ${numText(s.max, 3)}${s.worstSubject ? `，${s.worstSubject}` : ''}）`);
    lines.push(s.overThreshold.length
      ? `- MeanFD ≥ ${res.threshold} mm（DPABI QC 默认参考阈值）：${s.overThreshold.join('、')}`
      : `- MeanFD ≥ ${res.threshold} mm：无`);
    lines.push('', '每名受试者的头动指标：');
    lines.push('受试者 | mean FD_Jenkinson(mm) | mean FD_Power(mm) | 最大平移(mm) | 最大旋转(°) | FD_Power>0.2 帧数/占比 | 提示');
    const sorted = [...res.subjects].sort((a, b) => (b.metrics.meanFDJenkinson ?? -1) - (a.metrics.meanFDJenkinson ?? -1));
    for (const sub of sorted) {
      const m = sub.metrics;
      const pct = Number.isFinite(m.pctFDPower02) ? `${numText(m.pctFDPower02 * 100, 1)}%` : '—';
      lines.push(`${sub.id} | ${numText(m.meanFDJenkinson, 3)} | ${numText(m.meanFDPower, 3)} | ${numText(sub.maxTranslation, 2)} | ${numText(sub.maxRotation, 2)} | ${numText(m.nFDPower02, 0)} 帧 / ${pct} | ${sub.verdict.label}`);
    }
    lines.push('', '说明与判读参考：');
    for (const para of res.explanations.overview) lines.push(`- ${para}`);
    if (res.references) {
      lines.push('', '经验分级参考（启发式，不是诊断/入组标准）：');
      for (const key of ['maxTranslation', 'maxRotation', 'badFrameRatio']) {
        const ref = res.references[key];
        if (!ref) continue;
        lines.push(`- ${ref.label}（${ref.unit}）：${(ref.tiers || []).map((t) => t.label).join('；')}`);
      }
      lines.push(`- 说明：${res.references.gradingNote}`);
    }
    if (res.scrubbing?.notes?.length) {
      lines.push('', 'Scrubbing / Censor（坏帧处理）说明：');
      for (const note of res.scrubbing.notes) lines.push(`- ${note}`);
    }
    lines.push('', '注意：以上“提示/分级”是基于阈值与坏点占比的启发式解读，不替代人工 QC 评分；DPABI 人工评分请用 /mri qc 或页面 ④。');
    if (res.excludedByMaxMotion?.length) {
      lines.push('', 'DPARSF 最大头动排除名单（ExcludeSubjectsAccordingToMaxHeadMotion.txt）：');
      for (const group of res.excludedByMaxMotion) {
        lines.push(`- ${group.criteria}：${group.subjects.length ? group.subjects.join('、') : '无'}`);
      }
    }
    if (res.files?.voxelSpecificDir) {
      lines.push('', `体素特异头动图像（TDvox/FDvox）：${res.files.voxelSpecificDir}`);
    }
    if (strList(res.warnings).length) lines.push('', '提醒：\n- ' + strList(res.warnings).join('\n- '));
    return lines.join('\n');
  }

  // ------------------------------------------------------------------
  // Scrubbing / Censor：按逐帧 FD 阈值生成坏帧清单（可导出给后续分析）
  // ------------------------------------------------------------------
  function normalizeFdType(value) {
    const text = String(value ?? '').toLowerCase();
    if (text === 'power' || text === 'fd_power' || text === 'fdpower' || text === 'fd-power') return 'power';
    return 'jenkinson';
  }

  function normalizeCensorThreshold(value) {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) return 0.2;
    return Math.min(5, Math.max(0.01, n));
  }

  function clampInt(value, min, max, fallback = 0) {
    const n = Math.round(Number(value));
    if (!Number.isFinite(n)) return fallback;
    return Math.min(max, Math.max(min, n));
  }

  function buildCensorPlan(workDir, opts = {}) {
    const fdType = normalizeFdType(opts.fdType);
    const threshold = normalizeCensorThreshold(opts.threshold);
    const previous = clampInt(opts.previous, 0, 12, 0);
    const later = clampInt(opts.later, 0, 12, 0);
    const table = parseHeadMotionTable(workDir);
    if (!table.exists || !table.subjects.length) {
      return {
        available: false,
        workDir,
        fdType,
        threshold,
        previous,
        later,
        subjects: [],
        message: table.message
          ? `未找到可读的 RealignParameter/HeadMotion.tsv：${table.message}`
          : '未找到 RealignParameter/HeadMotion.tsv —— 头动校正完成后才能生成坏帧清单。',
      };
    }
    const subjects = table.subjects.map((row) => {
      const series = findFdSeriesFiles(workDir, row.id);
      const values = fdType === 'power' ? series.power : series.jenkinson;
      const total = values?.length ?? 0;
      const flagged = new Set();
      if (values && total) {
        for (let i = 0; i < total; i++) {
          if (!(Number.isFinite(values[i]) && values[i] > threshold)) continue;
          const frame = i + 1;
          for (let offset = -previous; offset <= later; offset++) {
            const target = frame + offset;
            if (target >= 1 && target <= total) flagged.add(target);
          }
        }
      }
      const frames = [...flagged].sort((a, b) => a - b);
      return {
        id: row.id,
        frames,
        count: frames.length,
        total,
        percent: total ? (frames.length / total) * 100 : null,
        meanFDJenkinson: row.metrics.meanFDJenkinson,
        meanFDPower: row.metrics.meanFDPower,
        maxTranslation: maxOfMetric(row.metrics, ['maxTx', 'maxTy', 'maxTz']),
        maxRotation: maxOfMetric(row.metrics, ['maxRx', 'maxRy', 'maxRz']),
      };
    });
    const summary = {
      subjects: subjects.length,
      subjectsWithBadFrames: subjects.filter((s) => s.count > 0).length,
      totalBadFrames: subjects.reduce((sum, s) => sum + s.count, 0),
      framesPerSubject: subjects[0]?.total ?? null,
    };
    return {
      available: true,
      workDir,
      fdType,
      threshold,
      previous,
      later,
      subjects,
      summary,
      message: `已按 ${fdType === 'power' ? 'FD_Power' : 'FD_Jenkinson'} > ${threshold} mm 标记 ${subjects.length} 名受试者的坏帧`
        + (previous || later ? `（向前 ${previous} / 向后 ${later} 帧扩展）` : ''),
    };
  }

  async function opCensorExport(agent, args = {}) {
    const resolved = await resolveQcWorkDir(agent, typeof args.workDir === 'string' ? args.workDir : undefined);
    const plan = buildCensorPlan(resolved.workDir, args);
    const warnings = [];
    if (resolved.source === 'workspace-fallback') {
      warnings.push('未能从最近一次扫描/配置推导出工作目录，已回退到当前会话工作区；如不是 DPARSF 工作目录，请显式传入 workDir。');
    }
    if (!plan.available) {
      return { kind: 'mri-workbench', action: 'censor', ok: true, ...plan, workDirSource: resolved.source, warnings };
    }
    const folder = [
      plan.fdType === 'power' ? 'FD_Power' : 'FD_Jenkinson',
      `${String(plan.threshold).replace(/\./g, 'p')}mm`,
      plan.previous || plan.later ? `prev${plan.previous}_later${plan.later}` : '',
    ].filter(Boolean).join('_');
    const exportDir = path.join(resolved.workDir, 'ScrubbingPreview', folder);
    await fsp.mkdir(exportDir, { recursive: true });
    const rows = [['Subject ID', 'nBadFrames', 'totalFrames', 'percentBad', 'badFrames(1-based)']];
    for (const subject of plan.subjects) {
      const file = path.join(exportDir, `${subject.id}_censor_frames.txt`);
      await fsp.writeFile(file, subject.frames.length ? subject.frames.join('\n') + '\n' : '', 'utf8');
      rows.push([
        subject.id,
        subject.count,
        subject.total,
        subject.percent === null ? '' : subject.percent.toFixed(2),
        subject.frames.join(','),
      ]);
    }
    const summaryFile = path.join(exportDir, 'censor_summary.tsv');
    await fsp.writeFile(summaryFile, rows.map((row) => row.join('\t')).join('\n') + '\n', 'utf8');
    return {
      kind: 'mri-workbench',
      action: 'censor',
      ok: true,
      ...plan,
      workDirSource: resolved.source,
      exportDir,
      summaryFile,
      warnings,
      message: `已导出 ${plan.subjects.length} 名受试者的坏帧清单`,
    };
  }

  async function opCensor(agent, args = {}) {
    if (args.export === true) return opCensorExport(agent, args);
    const resolved = await resolveQcWorkDir(agent, typeof args.workDir === 'string' ? args.workDir : undefined);
    const plan = buildCensorPlan(resolved.workDir, args);
    const warnings = [];
    if (resolved.source === 'workspace-fallback') {
      warnings.push('未能从最近一次扫描/配置推导出工作目录，已回退到当前会话工作区；如不是 DPARSF 工作目录，请显式传入 workDir。');
    }
    return {
      kind: 'mri-workbench',
      action: 'censor',
      ok: true,
      ...plan,
      workDirSource: resolved.source,
      warnings,
    };
  }

  function renderCensor(res) {
    const lines = ['DPARSF Scrubbing / Censor 坏帧清单'];
    if (res.workDirSource) lines.push(`- 工作目录：${res.workDir}（来源：${WORKDIR_SOURCE_LABELS[res.workDirSource] ?? res.workDirSource}）`);
    else lines.push(`- 工作目录：${res.workDir}`);
    lines.push(`- FD 类型：${res.fdType === 'power' ? 'FD_Power' : 'FD_Jenkinson'}；每帧阈值：${numText(res.threshold, 2)} mm；邻域扩展：前 ${res.previous} / 后 ${res.later} 帧`);
    if (!res.available) {
      lines.push(`- 状态：${res.message ?? '未找到头动结果'}`);
      return lines.join('\n');
    }
    const s = res.summary || {};
    lines.push(`- 受试者：${s.subjects ?? '?'} 名；每名帧数：${s.framesPerSubject ?? '?'}；有坏帧的受试者：${s.subjectsWithBadFrames ?? '?'} 名；坏帧合计：${s.totalBadFrames ?? '?'} 帧`);
    lines.push('', '每名受试者的坏帧（帧号为删点后序列的 1-based 帧号）：');
    lines.push('受试者 | 坏帧数 | 坏帧比例 | 前 12 个帧号');
    const sorted = [...(res.subjects || [])].sort((a, b) => (b.percent ?? -1) - (a.percent ?? -1));
    for (const subject of sorted) {
      const pct = subject.percent === null ? '—' : `${numText(subject.percent, 1)}%`;
      const head = subject.frames.slice(0, 12).join(', ')
        + (subject.frames.length > 12 ? ` …（共 ${subject.frames.length} 帧）` : '');
      lines.push(`${subject.id} | ${subject.count} | ${pct} | ${head || '—'}`);
    }
    lines.push('', '说明：');
    for (const note of HEAD_MOTION_SCRUBBING_NOTES) lines.push(`- ${note}`);
    if (res.previous || res.later) {
      lines.push(`- 本清单已按“前 ${res.previous} / 后 ${res.later} 帧”邻域扩展；导出文件即为扩展后的帧号。`);
    }
    if (res.exportDir) {
      lines.push('', `已导出：${res.exportDir}`, `汇总表：${res.summaryFile}`);
    }
    if (strList(res.warnings).length) lines.push('', '提醒：\n- ' + strList(res.warnings).join('\n- '));
    return lines.join('\n');
  }

  // ------------------------------------------------------------------
  // 文本渲染（供 Agent 阅读；命令/UI 也复用）
  // ------------------------------------------------------------------
  function renderEnv(env) {
    const lines = [
      'MRI 工作台环境检查',
      `- MATLAB：${env.matlabExists ? env.matlabExe : '未找到（设置 MATLAB_EXE）'}`,
      `- 工作台目录：${env.workbenchExists ? env.workbenchRoot : `未找到（${env.workbenchError ?? ''}）`}`,
      `- DPABI：${env.dpabiExists ? env.dpabiRoot : '未找到'}`,
      `- SPM12：${env.spmExists ? env.spmRoot : '未找到'}`,
      `- 预设：${(env.presets ?? []).map((p, i) => `${i + 1}. ${p}`).join('；')}`,
    ];
    return lines.join('\n');
  }

  function renderScan(res) {
    const subs = Array.isArray(res.subjects) ? res.subjects : [];
    const lines = [
      `数据扫描完成：${res.layoutName ?? res.layout}（${res.subjectCount} 名受试者）`,
      `- 工作目录：${res.workingDir}`,
      `- 起始目录名：${res.startingDirName}；session 数：${res.functionalSessionNumber}`,
      `- 自动检测：TR=${res.tr ?? '未知'} 秒，时间点=${res.timePoints ?? '未知'}，层数=${res.sliceNumber ?? '未知'}`,
      `- 数据类型：${res.isBIDS ? 'BIDS' : subs[0]?.funType ?? '未知'}`,
    ];
    for (const s of subs.slice(0, 12)) {
      lines.push(`  · ${s.id}：${s.funType}，时间点=${s.timePoints ?? '?'}，TR=${s.tr ?? '?'}，状态=${s.status}`);
    }
    if (subs.length > 12) lines.push(`  · … 其余 ${subs.length - 12} 名受试者省略`);
    const warnings = strList(res.warnings);
    if (warnings.length) lines.push(`提醒（${warnings.length}）：${warnings.slice(0, 5).join('；')}`);
    const historyLines = renderProcessingHistory(res.processingHistory);
    if (historyLines.length) lines.push('', ...historyLines);
    return lines.join('\n');
  }

  function strList(value) {
    return (Array.isArray(value) ? value : []).filter((x) => typeof x === 'string' && x.trim() !== '');
  }

  /** MATLAB 的 cellstr 经 jsonencode 可能变成 [["a","b"]]；统一成字符串数组。 */
  function normalizeGroups(value) {
    if (!Array.isArray(value)) return [];
    if (value.length && Array.isArray(value[0])) return normalizeGroups(value[0]);
    return value.filter((x) => typeof x === 'string');
  }

  function renderPrepare(res) {
    const lines = [
      `预处理配置：${res.summary || (res.ok ? '检查通过' : '检查未通过')}`,
      `- 预设：${res.preset || '自定义'}`,
      `- 数据目录：${res.workingDir}`,
      `- 受试者：${res.subjectCount} 名；起始目录：${res.startingDirName}；TR=${res.tr}，时间点=${res.timePoints}`,
    ];
    const realSteps = strList(res.steps).filter((step) => !String(step).includes('未启用任何处理步骤'));
    lines.push(realSteps.length
      ? `- 将执行 ${realSteps.length} 步：${realSteps.join(' → ')}`
      : '- 将执行 0 步：未启用任何处理步骤（空白/续跑预设，请先勾选要补做的步骤）');
    // T1 裁剪兼容模式（Cfg.T1CropCompat）：非 auto 时说明运行前会做什么，便于用户判断结果来源
    if (res.t1CropCompat && res.t1CropCompat !== 'auto') {
      const label = res.t1CropCompatLabel || res.t1CropCompat;
      lines.push(res.t1CropPlan
        ? `- T1 裁剪兼容：${label}（${res.t1CropPlan}）`
        : `- T1 裁剪兼容：${label}`);
    }
    lines.push(`- Cfg：${res.cfgPath}`);
    if (Array.isArray(res.overrides) && res.overrides.length) {
      lines.push(`- 参数覆盖（${res.overrides.length} 项）：${res.overrides.map((o) => `${o.key}=${describeValue(o.value)}`).join('；')}`);
    }
    const errors = strList(res.errors);
    const warnings = strList(res.warnings);
    if (errors.length) lines.push('错误：\n- ' + errors.join('\n- '));
    if (warnings.length) lines.push('提醒：\n- ' + warnings.join('\n- '));
    return lines.join('\n');
  }

  function renderParams(res) {
    const entries = Array.isArray(res.entries) ? res.entries : [];
    const lines = [
      `可调 Cfg 参数：${res.total ?? entries.length} 项${res.filter ? `，筛选「${res.filter}」得到 ${res.count} 项` : ''}${res.cached ? '（使用缓存 schema）' : '（已从 MATLAB CfgSchema 读取）'}`,
    ];    const ovs = Array.isArray(res.overrides) ? res.overrides : [];
    lines.push(
      ovs.length
        ? `- 当前参数覆盖 ${ovs.length} 项：${ovs.map((o) => `${o.key}=${describeValue(o.value)}`).join('；')}`
        : '- 当前无参数覆盖（默认按预设生成）',
    );
    const groups = normalizeGroups(res.groups);
    let shown = 0;
    for (const group of groups) {
      const list = entries.filter((e) => e.group === group);
      if (!list.length) continue;
      lines.push('', `【${group}】`);
      for (const e of list) {
        if (shown >= 120) break;
        const deps = dependsArray(e.dependsOn)
          .map((c) => `${c.Key}${c.Op ?? '='}${describeValue(c.Value)}`.replace('==', '='))
          .filter(Boolean);
        lines.push(
          `- ${e.key} = ${describeValue(e.default)}（${e.label} / ${e.en}；类型 ${e.type}${e.advanced ? '；高级' : ''}${deps.length ? `；启用条件 ${deps.join(' 且 ')}` : ''}）`,
        );
        shown += 1;
      }
      if (shown >= 120) break;
    }
    if (entries.length > shown) lines.push('', `… 其余 ${entries.length - shown} 项已省略（可用 /mri params <关键词> 筛选）。`);
    lines.push(
      '',
      '手动调整方式：',
      '1) 页面「② 预处理配置」→「参数覆盖」填 JSON 数组后点「应用覆盖」，再「生成配置并校验」；',
      '2) 命令：/mri prepare <预设序号> TR=2 IsRemoveFirstTimePoints=true（会与已保存覆盖合并）；',
      '3) 覆盖项按 CfgSchema 路径（如 SliceTiming.SliceOrder）写入，值与 JSON 一致。',
    );
    return lines.join('\n');
  }

  function renderOverrides(res) {
    const list = Array.isArray(res.overrides) ? res.overrides : [];
    const lines = [`参数覆盖：${list.length} 项`];
    if (!list.length) {
      lines.push('- （空）可在页面「参数覆盖」填写 JSON 数组后点「应用覆盖」，或 /mri overrides set <base64>。');
    } else {
      for (const o of list) lines.push(`- ${o.key} = ${describeValue(o.value)}`);
    }
    if (res.op === 'set') lines.push('', '已保存；下一次「生成配置并校验」或 /mri prepare 会应用这些覆盖。');
    if (res.op === 'clear') lines.push('', '已清空参数覆盖，之后按预设默认值生成。');
    const skipped = Array.isArray(res.skipped) ? res.skipped : [];
    if (skipped.length) lines.push('', `忽略的无效项：${skipped.slice(0, 8).join('；')}`);
    return lines.join('\n');
  }

  function renderStatus(s) {
    const lines = [
      `MRI 工作台状态：${s.state}${s.job ? `（Job ${s.job.status}）` : ''}`,
      `- 说明：${s.message || '—'}`,
    ];
    if (s.prepare) lines.push(`- 当前配置：${s.prepare.preset ?? '自定义'} · ${s.prepare.subjectCount ?? '?'} 名受试者`);
    if (s.elapsedSeconds !== undefined) lines.push(`- 已用时：${Math.round(Number(s.elapsedSeconds))} 秒`);
    if (s.phases?.length) lines.push(`- 已完成阶段（${s.phases.length}）：${s.phases.join(' → ')}`);
    if (s.job?.progress) lines.push(`- 当前进度：${s.job.progress}`);
    if (s.job?.detail) lines.push(`- Job 详情：${s.job.detail}`);
    if (s.runDir) lines.push(`- 运行目录：${s.runDir}`);
    if (s.logTail) lines.push('\n最近日志（尾部）：\n' + s.logTail.split(/\r?\n/).slice(-20).join('\n'));
    return lines.join('\n');
  }

  function out(value, text) {
    return {
      schema: { type: 'object', additionalProperties: true },
      render: () => [{ type: 'text', text: text || JSON.stringify(value) }],
    };
  }

  function tool(name, description, properties, required, handler, render) {
    const parameters = { type: 'object', properties, required, additionalProperties: false };
    ctx.effect(() =>
      ctx.tools.register({
        name,
        description,
        parameters,
        output: { schema: { type: 'object', additionalProperties: true }, render: (args, value) => [{ type: 'text', text: render ? render(args, value) : JSON.stringify(value) }] },
        async execute(args, exec) {
          const value = await handler(args ?? {}, exec ?? {});
          // DSH 工具输出必须是 lossless JSON：去掉 undefined、NaN/Infinity 等非法值
          return jsonSafe(value);
        },
      }),
    );
  }

  // ------------------------------------------------------------------
  // Agent 工具
  // ------------------------------------------------------------------
  tool(
    'mri_workbench_env',
    'Check the local MRI workbench environment (MATLAB, DPABI, SPM12, presets) before scanning or running. Fast, no MATLAB startup.',
    {},
    [],
    async (_args, exec) => opEnv(exec.agent),
    (_a, env) => renderEnv(env),
  );
  tool(
    'mri_workbench_scan',
    'Scan a root directory for resting-state MRI data (DPARSF FunRaw/T1Raw layout, BIDS, plain NIfTI or DICOM) and return subjects plus auto-detected TR/TimePoints/slice number. Also explains the processing history of existing DPARSF stage directories (FunImg*/RealignParameter/Results): which steps (slice timing, realign, scrubbing, ...) produced each directory, so the user can tell what processing the data has already gone through. User must confirm the directory.',
    { root: { type: 'string', description: 'Absolute root directory to scan, e.g. D:\\Data\\MyStudy' }, maxDepth: { type: 'integer', minimum: 1, maximum: 20, description: 'Recursion depth (default 6)' } },
    ['root'],
    async (args, exec) => opScan(exec.agent, args, exec.signal),
    (_a, res) => renderScan(res),
  );
  tool(
    'mri_workbench_prepare',
    'Build a DPARSF Cfg from the latest scan and a preset, apply overrides, run the preflight validation and save Cfg.mat. Does not start preprocessing. Preset 5 is a blank/continuation preset (all steps off) for adding one step to existing intermediate results. The preflight also detects already-processed stage directories (FunImg*) and reports errors/warnings for double-processing risks, rp-file collisions, and missing FD files when continuing from a processed StartingDirName. If T1Img contains only NIfTI T1 files (no c*/co*), DPARSF\'s dcm2niix-based crop cannot produce c*/co* and a headless run fails at a hidden confirmation dialog; pass overrides [{key:"T1CropCompat",value:"old_dcm2nii"}] so the workbench crops the NIfTI T1 with DPABI\'s legacy dcm2nii before the run (real c*/co*), or value "no_crop" to copy the uncropped T1 as a c* pass-through (segmentation quality needs manual QC).',
    {
      preset: { type: 'integer', minimum: 1, maximum: 5, description: 'Preset number from mri_workbench_env: 1 classic DARTEL, 2 functional-only, 3 BIDS, 4 quick QC, 5 blank (all steps off, for adding one step to existing intermediate results / continuation)' },
      overrides: { type: 'array', description: 'Optional CfgSchema overrides: [{key,value}]', items: { type: 'object', properties: { key: { type: 'string' }, value: {} }, required: ['key'] } },
    },
    [],
    async (args, exec) => opPrepare(exec.agent, args, exec.signal),
    (_a, res) => renderPrepare(res),
  );
  tool(
    'mri_workbench_start',
    'Start DPARSF preprocessing in the background (official DPARSFA_run via a detached MATLAB process, exposed as a DSH background Job with live output). Requires a prepared configuration; refuses to start when the preflight reported errors or the configuration has no enabled steps.',
    {},
    [],
    async (_args, exec) => opStart(exec.agent, exec),
  );
  tool(
    'mri_workbench_status',
    'Read the current MRI workbench run state: status.json, phases parsed from the log, job status, and the log tail.',
    {},
    [],
    async (_args, exec) => opStatus(exec.agent),
    (_a, s) => renderStatus(s),
  );
  tool(
    'mri_workbench_wait',
    'Wait up to timeoutSec for the running DPARSF job to finish or timeout, then return state, phases and log tail. Use after mri_workbench_start for live progress reporting.',
    { timeoutSec: { type: 'integer', minimum: 1, maximum: 600, description: 'Maximum wait in seconds (default 60)' } },
    [],
    async (args, exec) => opWait(exec.agent, args),
    (_a, s) => renderStatus(s),
  );
  tool(
    'mri_workbench_cancel',
    'Cancel the running DPARSF preprocessing job and kill its MATLAB process tree.',
    {},
    [],
    async (_args, exec) => opCancel(exec.agent),
  );
  tool(
    'mri_workbench_open_gui',
    'Open the MATLAB desktop version of the workbench (StartWorkbench) so the user can inspect tooltips and detailed UI on the MATLAB side.',
    {},
    [],
    async (_args, exec) => opOpenGui(exec.agent),
  );
  tool(
    'mri_workbench_qc',
    'Summarize saved manual QC scores without starting MATLAB. Parses DPARSF-compatible TSVs under the DPARSF working directory: QC/RawT1ImgQC.tsv, QC/RawFunImgQC.tsv, QC/NormalizationQC.tsv (1-5 scores, DPARSF format) and RealignParameter/HeadMotion.tsv (mean FD_Jenkinson). Returns per-modality scored/total/mean, low scores (<=2), unscored and below-threshold subjects, MeanFD over threshold, recent comments, and warnings. Defaults to the working directory of the latest prepared configuration; pass workDir to inspect another dataset. This only reads files: never fabricate QC conclusions yourself.',
    {
      workDir: {
        type: 'string',
        description: 'DPARSF working directory containing QC/ and RealignParameter/. Defaults to the working directory of the latest prepared configuration (or last scan).',
      },
    },
    [],
    async (args, exec) => opQc(exec.agent, args),
    (_a, res) => renderQcSummary(res),
  );

  tool(
    'mri_workbench_qcstate',
    'Read the live state of the MATLAB manual-QC viewer window from <workDir>/QC/.qcviewer_state.json (does not start MATLAB). Use this together with matlab_snapshot when the user asks what the MATLAB manual-QC window currently shows, or how to calibrate it: take a real screenshot first, then read this state to get the exact subject/modality, view mode (single/triple/montage), active orientation, crosshair voxel + world mm, display mode and AC-PC distance/angle plus manual translation/rotation/flips, display matrix, window/clim/colormap/interp/zoom, template-overlay settings, FD type with bad frames, score and scoring progress, filter/sort and update time. Give guidance from these values and never describe the state from imagination. If the state file is missing, corrupt or stale (>30 min without update) it returns a Chinese hint that the MATLAB QC window is not open / not operated yet instead of throwing. Defaults to the working directory of the latest prepared configuration; pass workDir to inspect another dataset.',
    {
      workDir: {
        type: 'string',
        description: 'DPARSF working directory containing QC/.qcviewer_state.json. Defaults to the working directory of the latest prepared configuration (or last scan).',
      },
    },
    [],
    async (args, exec) => opQcState(exec.agent, args),
    (_a, res) => renderQcState(res),
  );

  tool(
    'mri_workbench_results',
    'Explain and visualize DPARSF head-motion results without starting MATLAB. Reads RealignParameter/HeadMotion.tsv plus per-subject FD_Jenkinson/FD_Power/FD_VanDijk time series, and returns per-subject metrics (mean FD, max translation/rotation, bad-frame counts), per-frame curves, a plain-Chinese explanation of every column, rule-based attention hints, and the DPARSF max-head-motion exclusion list; the Web page uses the same data for tables and FD curve charts. Defaults to the working directory of the latest prepared configuration; pass workDir to inspect another dataset. Hints are heuristic and never replace manual QC scoring.',
    {
      workDir: {
        type: 'string',
        description: 'DPARSF working directory containing RealignParameter/. Defaults to the working directory of the latest prepared configuration (or last scan).',
      },
      threshold: {
        type: 'number',
        minimum: 0.01,
        maximum: 5,
        description: 'Reference threshold for mean FD_Jenkinson in mm (default 0.2).',
      },
    },
    [],
    async (args, exec) => opResults(exec.agent, args),
    (_a, res) => renderResults(res),
  );

  tool(
    'mri_workbench_censor',
    'Mark and optionally export scrubbing (censor) frames from DPARSF per-frame FD files without starting MATLAB. Reads RealignParameter/<subject>/FD_Jenkinson_*.txt or FD_Power_*.txt, flags frames whose FD exceeds the threshold (optionally extending to previous/later frames), and returns per-subject bad-frame indices (1-based, after initial-point removal), counts/percent plus a scrubbing explanation (DPABI IsScrubbing options and the regression-regressor alternative). With export=true it also writes <workDir>/ScrubbingPreview/<FDtype>_<threshold>/<subject>_censor_frames.txt and censor_summary.tsv. Defaults to the working directory of the latest prepared configuration.',
    {
      workDir: {
        type: 'string',
        description: 'DPARSF working directory containing RealignParameter/. Defaults to the working directory of the latest prepared configuration (or last scan).',
      },
      fdType: {
        type: 'string',
        enum: ['FD_Jenkinson', 'FD_Power'],
        description: 'FD type used for censoring (default FD_Jenkinson; FD_Power often uses 0.5 mm).',
      },
      threshold: {
        type: 'number',
        minimum: 0.01,
        maximum: 5,
        description: 'Per-frame FD threshold in mm (default 0.2 for FD_Jenkinson, commonly 0.5 for FD_Power).',
      },
      previous: {
        type: 'integer',
        minimum: 0,
        maximum: 12,
        description: 'Also censor N frames before each bad frame (default 0).',
      },
      later: {
        type: 'integer',
        minimum: 0,
        maximum: 12,
        description: 'Also censor N frames after each bad frame (default 0).',
      },
      export: {
        type: 'boolean',
        description: 'Write per-subject censor frame files and censor_summary.tsv under <workDir>/ScrubbingPreview/ (default false).',
      },
    },
    [],
    async (args, exec) => opCensor(exec.agent, args),
    (_a, res) => renderCensor(res),
  );

  tool(
    'mri_workbench_params',
    'List the adjustable DPARSF Cfg parameters from the workbench CfgSchema (key, group, Chinese label, English name, type, default, enum options, dependencies, advanced). Reads a cached schema and starts MATLAB only once on first use. Use it to discover keys before passing overrides to mri_workbench_prepare, or when the user asks which configuration options can be adjusted manually.',
    {
      filter: { type: 'string', description: 'Optional keyword to filter by key / Chinese label / English name / group, e.g. "平滑" or "SliceTiming"' },
      refresh: { type: 'boolean', description: 'Re-read CfgSchema from MATLAB instead of using the cached schema' },
    },
    [],
    async (args, exec) => opParams(exec.agent, args, exec.signal),
    (_a, res) => renderParams(res),
  );
  tool(
    'mri_workbench_overrides',
    'Show, set or clear manual Cfg parameter overrides for this session. Overrides are stored in session state and merged into the next mri_workbench_prepare call (and /mri prepare), taking precedence over the preset. Values follow JSON; keys are CfgSchema paths such as TR, IsSliceTiming or SliceTiming.SliceOrder. This never fabricates results: it only stores the values the user asked for.',
    {
      action: { type: 'string', enum: ['show', 'set', 'clear'], description: 'show current overrides, set a new list, or clear all' },
      overrides: {
        type: 'array',
        description: 'When action=set: [{key,value}] list of CfgSchema overrides',
        items: {
          type: 'object',
          properties: { key: { type: 'string' }, value: {} },
          required: ['key'],
        },
      },
    },
    ['action'],
    async (args, exec) => opOverrides(exec.agent, args),
    (_a, res) => renderOverrides(res),
  );

  // ------------------------------------------------------------------
  // 人类命令 /mri（Client UI 通过 ctx.remote.commands.execute 调用同一套操作）
  // ------------------------------------------------------------------
  function parseCommandInput(raw) {
    const text = String(raw ?? '').trim();
    const tokens = [];
    const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
    let m;
    while ((m = re.exec(text)) !== null) tokens.push(m[1] ?? m[2] ?? m[3]);
    return tokens;
  }

  function toText(value) {
    return typeof value === 'string' ? value : JSON.stringify(value);
  }

  async function handleCommand(invocation) {
    const tokens = parseCommandInput(invocation.rawInput);
    const sub = (tokens.shift() ?? 'help').toLowerCase();
    const agent = invocation.agent;
    switch (sub) {
      case 'help':
        return [
          'MRI 静息态工作台命令：',
          '/mri env                       检查环境',
          '/mri presets                   列出预设',
          '/mri scan <目录> [深度]        扫描并索引数据集',
          '/mri prepare <预设序号> [k=v …] 生成配置并做运行前校验（会先应用已保存的参数覆盖）',
          '/mri params [关键词]            列出可调 Cfg 参数（key/中文名/默认值/类型；首次启动一次 MATLAB 读 CfgSchema）',
          '/mri overrides                 查看已保存的参数覆盖',
          '/mri overrides set <base64>    应用参数覆盖（base64(JSON 数组 [{key,value}])）',
          '/mri overrides clear           清空参数覆盖',
          '/mri run                       后台启动 DPARSF 预处理（实时日志见会话顶部 Jobs）',
          '/mri status                    查看运行状态/阶段/日志尾部',
          '/mri cancel                    取消运行',
          '/mri open                      打开 MATLAB 桌面版工作台',
          '/mri qc [工作目录]             打开 MATLAB 可缩放人工 QC 查看器（1–5 分评分；缺省用最近配置目录）',
          '/mri qcstatus [工作目录]       汇总已保存的人工 QC 评分（不启动 MATLAB）',
          '/mri qcstate [工作目录]        读取 MATLAB 人工 QC 窗口的实时状态（十字线/AC-PC/显示矩阵/窗宽/叠加/FD/评分；不启动 MATLAB，供 Agent 配合截图做实时指导）',
          '/mri results [工作目录]        解读并可视化头动结果（HeadMotion.tsv + 逐帧 FD，不启动 MATLAB）',
          '/mri censor [jenkinson|power] [阈值] [prev=N] [later=N] [工作目录]  按逐帧 FD 生成坏帧（scrubbing/censor）清单并导出到 ScrubbingPreview/（prev/later = 坏帧前/后扩展帧数，对应 Scrubbing.PreviousPoints/LaterPoints）',
          '/mri help                      显示帮助',
        ].join('\n');
      case 'env':
        return renderEnv(await opEnv(agent));
      case 'presets':
        return PRESETS.map((p, i) => `${i + 1}. ${p}`).join('\n');
      case 'scan': {
        const root = tokens[0];
        const depth = Number(tokens[1]);
        if (!root) return '用法：/mri scan <数据根目录> [深度]';
        return renderScan(await opScan(agent, { root, maxDepth: Number.isFinite(depth) ? depth : 6 }, invocation.signal));
      }
      case 'paramsjson': {
        const res = await opParams(agent, {}, invocation.signal);
        return JSON.stringify({
          ok: true,
          count: res.count,
          total: res.total,
          groups: res.groups,
          entries: res.entries,
          overrides: res.overrides,
        });
      }
      case 'params': {
        return renderParams(await opParams(agent, { filter: tokens[0] }, invocation.signal));
      }
      case 'overrides': {
        const action = (tokens[0] ?? 'show').toLowerCase();
        if (action === 'set') {
          const payload = tokens[1];
          if (!payload) return '用法：/mri overrides set <base64(JSON 数组 [{key,value}])>。可先 /mri params 查看可调字段。';
          const json = decodeBase64Utf8(payload);
          if (!String(json ?? '').trim()) return '参数覆盖 payload 为空或 base64 解码失败。';
          try {
            return renderOverrides(await opOverrides(agent, { action: 'set', json }));
          } catch (err) {
            return `参数覆盖无效：${err?.message ?? err}`;
          }
        }
        if (action === 'clear' || action === 'reset') {
          return renderOverrides(await opOverrides(agent, { action: 'clear' }));
        }
        return renderOverrides(await opOverrides(agent, { action: 'show' }));
      }
      case 'prepare': {
        const presetNum = Number(tokens[0] ?? 1);
        const overrides = [];
        for (const t of tokens.slice(1)) {
          const i = t.indexOf('=');
          if (i > 0) {
            const key = t.slice(0, i);
            const raw = t.slice(i + 1);
            let value = raw;
            try {
              value = JSON.parse(raw);
            } catch {
              value = raw;
            }
            overrides.push({ key, value });
          }
        }
        return renderPrepare(await opPrepare(agent, { preset: presetNum, overrides }, invocation.signal));
      }
      case 'run': {
        const res = await opStart(agent, { signal: invocation.signal });
        return [
          `已在后台启动预处理（Job：${res.jobId || '独立进程'}）`,
          `- 受试者：${res.subjectCount ?? '?'}，预设：${res.preset ?? '自定义'}`,
          `- 运行目录：${res.runDir}`,
          '- 实时日志：会话顶部「后台任务」列表；也可 /mri status 或让 Agent 调用 mri_workbench_wait。',
        ].join('\n');
      }
      case 'status':
        return renderStatus(await opStatus(agent));
      case 'cancel': {
        const res = await opCancel(agent);
        return res.ok ? '已请求取消当前预处理任务。' : `取消失败：${res.error}`;
      }
      case 'open': {
        const res = await opOpenGui(agent);
        return res.message;
      }
      case 'qc': {
        const res = await opOpenQcViewer(agent, tokens[0]);
        return res.message;
      }
      case 'qcstatus': {
        return renderQcSummary(await opQc(agent, { workDir: tokens[0] }));
      }
      case 'qcstate': {
        return renderQcState(await opQcState(agent, { workDir: tokens[0] }));
      }
      case 'resultsjson': {
        const arg = tokens[0];
        const numeric = arg !== undefined && Number.isFinite(Number(arg));
        const res = await opResults(agent, numeric ? { threshold: Number(arg) } : { workDir: arg });
        return JSON.stringify({
          ok: true,
          ...res,
          workDirSourceLabel: WORKDIR_SOURCE_LABELS[res.workDirSource] ?? res.workDirSource,
        });
      }
      case 'results': {
        const arg = tokens[0];
        const numeric = arg !== undefined && Number.isFinite(Number(arg));
        return renderResults(await opResults(agent, numeric ? { threshold: Number(arg) } : { workDir: arg }));
      }
      case 'censor': {
        let fdType = 'jenkinson';
        let threshold = 0.2;
        let previous = 0;
        let later = 0;
        let workDir;
        for (const token of tokens) {
          const lower = token.toLowerCase();
          // 邻域扩展：prev=N / previous=N / later=N（对应 Scrubbing.PreviousPoints / LaterPoints）
          const expand = /^(prev|previous|later)\s*=\s*(-?\d+)$/i.exec(lower);
          if (expand) {
            const value = clampInt(expand[2], 0, 12, 0);
            if (expand[1] === 'later') later = value;
            else previous = value;
          } else if (lower === 'jenkinson' || lower === 'fd_jenkinson' || lower === 'fd-jenkinson') fdType = 'jenkinson';
          else if (lower === 'power' || lower === 'fd_power' || lower === 'fd-power') fdType = 'power';
          else if (Number.isFinite(Number(token)) && threshold === 0.2) threshold = Number(token);
          else workDir = token;
        }
        return renderCensor(await opCensorExport(agent, { workDir, fdType, threshold, previous, later }));
      }
      default:
        return `未知子命令：${sub}。发送 /mri help 查看用法。`;
    }
  }

  ctx.effect(() =>
    ctx.commands.register({
      name: 'mri',
      description: 'MRI 静息态工作台：扫描数据集、生成/校验 DPARSF 配置、后台运行与查看进度、人工 QC 评分汇总与 MATLAB 人工 QC 窗口实时状态',
      input: { hint: 'scan <目录> | prepare <预设> [k=v] | params [关键词] | overrides [set <base64>|clear] | run | status | cancel | results [目录] | censor [jenkinson|power] [阈值] [prev=N] [later=N] | qc [工作目录] | qcstatus | qcstate | env | open' },
      handler: async (invocation) => {
        try {
          const text = toText(await handleCommand(invocation));
          return { kind: 'success', text };
        } catch (err) {
          return { kind: 'error', text: `MRI 工作台操作失败：${err?.message ?? err}` };
        }
      },
    }),
  );

  // ------------------------------------------------------------------
  // 系统提示
  // ------------------------------------------------------------------
  ctx.effect(() =>
    ctx.systemPrompt.section({
      name: 'dsh-mri-workbench',
      order: 9040,
      text: [
        'MRI 静息态工作台（DPABI/DPARSF，MATLAB 后台计算）。',
        '当用户要求扫描数据、生成/检查预处理配置、启动/取消 DPARSF 预处理、查看进度或结果时，使用 mri_workbench_* 工具：先 mri_workbench_env 检查环境，再 mri_workbench_scan（目录需用户确认），mri_workbench_prepare 生成配置并做运行前校验，mri_workbench_start 启动后台任务，随后用 mri_workbench_wait 或 job_output 获取实时日志并用中文汇报当前阶段、已完成被试与错误；取消用 mri_workbench_cancel。',
        '预处理由独立 MATLAB 进程调用官方 DPARSFA_run 完成；不要伪造进度、结果或 MATLAB 状态。用户询问 MATLAB/DPARSF/SPM 当前画面或 QC 时，先用 matlab_snapshot 抓取真实截图再回答。不要声称执行了未执行的操作。',
        'T1 结构像兼容：DPABI 的结构像裁剪步骤调用 dcm2niix（只支持 DICOM），当 T1Img 里只有 NIfTI T1（无 c*/co*）时后台运行会在隐藏确认框处失败；预检会报错提示。此时用 mri_workbench_prepare 的 overrides [{key:"T1CropCompat",value:"old_dcm2nii"}]（旧版 dcm2nii 真实重定向+裁剪生成 c*/co*）或 value "no_crop"（未裁剪 T1 复制为 c* 直通，分割质量需人工 QC），页面 ② 卡也有同名下拉。不要隐瞒所用裁剪方式及其质量影响。',
        '配置参数可以手动调整：用 mri_workbench_params 查看全部可调 Cfg 字段（key/中文名/默认值/类型/依赖），用 mri_workbench_overrides 保存用户要求的覆盖项（key 为 CfgSchema 路径，如 TR、IsSliceTiming、SliceTiming.SliceOrder），然后 mri_workbench_prepare 会自动合并覆盖再生成配置并校验；页面「参数覆盖」和 /mri prepare <预设> k=v 等价。不要擅自替用户改参数，先确认用户意图。',
        '预处理完成后用户可能要求人工 QC：用 mri_workbench_qc（纯 Node 读取，不启动 MATLAB）汇总 DPARSF 兼容评分（1–5 分）各模态已评分/总数/平均分、低分（≤2）、未评分与 MeanFD 超阈值名单；低分或漏评要提示人工复核。需要人工看图评分时，让用户执行 /mri qc 或在页面点「打开 MATLAB 人工 QC」启动可缩放查看器；不得在对话中伪造 QC 评分或代替用户下结论。',
        '用户询问 MATLAB 人工 QC 当前画面/如何校准/AC-PC/方位时：先用 matlab_snapshot 抓真实截图判断显示是否正常（三正交是否联动、轮廓是否贴合等），再调用 mri_workbench_qcstate（或执行 /mri qcstate，纯 Node 读取 <workDir>/QC/.qcviewer_state.json，不启动 MATLAB）获取精确状态——受试者/模态、视图模式、活动方向、十字线体素与世界 mm、显示模式（native/原点/AC-PC）、AC-PC 距离与角度、手动平移/旋转/翻转、显示矩阵、窗宽色阶、叠加、FD 类型与坏帧、评分与进度——并据此给实时指导；不得凭空描述状态。状态文件缺失/损坏/超过 30 分钟未更新时会给出中文提示（MATLAB QC 窗口未打开或尚未操作），应让用户先在 QC 窗口操作一次或点「复制状态给 Agent」，不要编造。三正交/原点校准/AC-PC 配平/方位校准/多切片网格/FD 曲线联动/受试者排序筛选等新功能在页面 ④ 有说明。',
        '用户看不懂 DPARSF 结果表格时，用 mri_workbench_results（纯 Node 读取，不启动 MATLAB）读取 RealignParameter/HeadMotion.tsv 与逐帧 FD 曲线，按“每列是什么 → 本批数据组均值/最大/超阈值受试者 → 逐人提示”解释，并引导用户用页面 ⑤「头动结果解读与可视化」查看表格与 FD 曲线；提示是启发式参考，不能冒充人工 QC 结论。',
        '用户要做 scrubbing/censor 或导出坏帧清单时，用 mri_workbench_censor（纯 Node 读取，不启动 MATLAB；可用 export=true 写 <workDir>/ScrubbingPreview/）按 FD_Jenkinson/FD_Power 阈值生成每名受试者的坏帧帧号（删点后 1-based）；可传 previous/later 扩展坏帧前后帧数（对应 DPABI 的 Scrubbing.PreviousPoints/LaterPoints，页面 ⑤ 坏帧卡也有「向前/向后扩展帧数」选择，命令行用 /mri censor … prev=N later=N）；并解释 DPABI 的 IsScrubbing（cut/nearest/linear/spline/pchip）与 Covremove.IsHeadMotionScrubbingRegressors 两种做法；页面 ⑤ 的「Scrubbing 方式」还可选 spike（= 头动 scrubbing 回归量 Covremove.IsHeadMotionScrubbingRegressors，每坏帧一个回归量、不缩短序列，写入覆盖时与 IsScrubbing 互斥，且要求流程包含协变量回归 IsCovremove=1）；是否启用 scrubbing/spike 属于研究方案决定，不要替用户默认开启。',
      ].join('\n'),
    }),
  );

  logger.info?.('DSH_MRI_WORKBENCH_HOST_APPLY');
  return () => {
    logger.info?.('DSH_MRI_WORKBENCH_HOST_DISPOSE');
  };
}
