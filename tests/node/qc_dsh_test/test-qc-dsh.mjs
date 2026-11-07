// dsh-mri-workbench 人工 QC 解析/摘要离线自测
// 前置（可选，样例已作为静态 fixture 提交）: pwsh -File tests/node/fixtures/qc_dsh_test/make_fixtures.ps1
// 运行: node tests/node/qc_dsh_test/test-qc-dsh.mjs
// 直接 import 插件 Host 模块导出的纯函数（不启动 DSH、不启动 MATLAB）。
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  buildQcSummary,
  renderQcSummary,
  readQcTsv,
  parseHeadMotionTsv,
  discoverSubjectIds,
  jsonSafe,
} from '../../../index.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
// 静态 fixture 位于 tests/node/fixtures/qc_dsh_test/（由 fixtures.json + make_fixtures.ps1 生成后提交）。
const fixturesDir = path.resolve(here, '..', 'fixtures', 'qc_dsh_test');
const sample1 = path.join(fixturesDir, 'sample');
const sample2 = path.join(fixturesDir, 'sample2');
const sample3 = path.join(fixturesDir, 'sample3');

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`PASS  ${name}`);
  } catch (err) {
    console.error(`FAIL  ${name}`);
    throw err;
  }
}

function assertLossless(value, label, where = '$') {
  if (value === undefined) throw new Error(`${label}: undefined at ${where}`);
  if (typeof value === 'number') {
    assert.ok(Number.isFinite(value), `${label}: non-finite number at ${where} (${value})`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertLossless(item, label, `${where}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) assertLossless(item, label, `${where}.${key}`);
  }
}

if (!existsSync(sample1) || !existsSync(sample2) || !existsSync(sample3)) {
  console.error('缺少样例目录：请先运行 pwsh -File tests/node/fixtures/qc_dsh_test/make_fixtures.ps1（或恢复提交的静态 fixture）');
  process.exit(2);
}

// ------------------------------------------------------------------
// 1. TSV 解析（UTF-8 BOM + CRLF）
// ------------------------------------------------------------------
const t1File = path.join(sample1, 'QC', 'RawT1ImgQC.tsv');
const funFile = path.join(sample1, 'QC', 'RawFunImgQC.tsv');
const normFile = path.join(sample1, 'QC', 'NormalizationQC.tsv');
const hmFile = path.join(sample1, 'RealignParameter', 'HeadMotion.tsv');

check('T1 TSV：表头/行数/NaN→未评分/中文评语（UTF-8 BOM+CRLF）', () => {
  const tsv = readQcTsv(t1File);
  assert.equal(tsv.exists, true);
  assert.equal(tsv.rows.length, 5);
  assert.deepEqual(tsv.rows.map((row) => row.id), ['Sub01', 'Sub02', 'Sub03', 'Sub04', 'Sub10']);
  assert.deepEqual(tsv.rows.map((row) => row.score), [5, 2, null, 4, 3]);
  assert.equal(tsv.rows[0].comment, '图像清晰，无伪影');
  assert.equal(tsv.rows[2].comment, '');
});

check('Fun TSV：GBK 编码中文评语自动解码', () => {
  const tsv = readQcTsv(funFile);
  assert.equal(tsv.exists, true);
  assert.equal(tsv.rows[1].comment, '信号丢失严重');
  assert.equal(tsv.rows[4].comment, '伪影明显');
  for (const row of tsv.rows) assert.ok(!row.comment.includes('\uFFFD'), `评语出现乱码：${row.comment}`);
});

check('缺失 TSV 不抛异常（exists=false）', () => {
  const tsv = readQcTsv(path.join(sample1, 'QC', 'DoesNotExist.tsv'));
  assert.equal(tsv.exists, false);
  assert.deepEqual(tsv.rows, []);
});

check('无表头 TSV：Subject01 数据行不被误判为表头', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'dsh-qc-'));
  const file = path.join(dir, 'headerless.tsv');
  try {
    writeFileSync(file, 'Subject01\t4\t无表头数据行\nSub02\tNaN\t\n', 'utf8');
    const tsv = readQcTsv(file);
    assert.deepEqual(tsv.rows.map((row) => row.id), ['Subject01', 'Sub02']);
    assert.deepEqual(tsv.rows.map((row) => row.score), [4, null]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

check('NormalizationQC 只有表头：exists=true、0 行', () => {
  const tsv = readQcTsv(normFile);
  assert.equal(tsv.exists, true);
  assert.equal(tsv.rows.length, 0);
});

// ------------------------------------------------------------------
// 2. HeadMotion.tsv（DPARSF 21 列，%e 格式）
// ------------------------------------------------------------------
check('HeadMotion TSV：第 21 列 mean FD_Jenkinson 解析', () => {
  const hm = parseHeadMotionTsv(hmFile);
  assert.equal(hm.available, true);
  assert.equal(hm.columnIndex, 20);
  assert.deepEqual(hm.ids, ['Sub01', 'Sub02', 'Sub03', 'Sub04', 'Sub10']);
  const expected = [0.05, 0.35, 0.12, 0.22, 0.08];
  hm.meanFD.forEach((value, index) => {
    assert.ok(Math.abs(value - expected[index]) < 1e-9, `MeanFD[${index}]=${value}`);
  });
});

// ------------------------------------------------------------------
// 3. 受试者目录发现（自然排序）
// ------------------------------------------------------------------
check('discoverSubjectIds：FunRaw/T1Raw/RealignParameter 去重 + 自然排序', () => {
  assert.deepEqual(discoverSubjectIds(sample1), ['Sub01', 'Sub02', 'Sub03', 'Sub04', 'Sub10']);
});

// ------------------------------------------------------------------
// 4. 摘要汇总（默认阈值）
// ------------------------------------------------------------------
const summary = buildQcSummary(sample1);
const byKey = Object.fromEntries(summary.modalities.map((modality) => [modality.key, modality]));

check('摘要：受试者总数 = 5（目录发现）', () => {
  assert.equal(summary.subjectTotal, 5);
  assert.equal(summary.hasScores, true);
  assert.equal(summary.scoredFileCount, 3);
});

check('摘要：T1 已评分 4/5、平均 3.5、低分 Sub02、未评分 Sub03', () => {
  assert.equal(byKey.T1.available, true);
  assert.equal(byKey.T1.scored, 4);
  assert.equal(byKey.T1.total, 5);
  assert.equal(byKey.T1.unscored, 1);
  assert.equal(byKey.T1.meanScore, 3.5);
  assert.deepEqual(byKey.T1.lowScores, [{ id: 'Sub02', score: 2 }]);
  assert.deepEqual(byKey.T1.unscoredIDs, ['Sub03']);
  assert.equal(byKey.T1.recentComments.length, 4);
  assert.equal(byKey.T1.recentComments[0].comment, '图像清晰，无伪影');
});

check('摘要：Fun 已评分 4/5、平均 2.5、低分 Sub02+Sub10', () => {
  assert.equal(byKey.Fun.scored, 4);
  assert.equal(byKey.Fun.meanScore, 2.5);
  assert.deepEqual(byKey.Fun.lowScores, [
    { id: 'Sub02', score: 1 },
    { id: 'Sub10', score: 2 },
  ]);
  assert.deepEqual(byKey.Fun.unscoredIDs, ['Sub03']);
});

check('摘要：Norm 文件存在但 0 评分 → meanScore=null、全部未评分', () => {
  assert.equal(byKey.Norm.available, true);
  assert.equal(byKey.Norm.scored, 0);
  assert.equal(byKey.Norm.meanScore, null);
  assert.deepEqual(byKey.Norm.unscoredIDs, ['Sub01', 'Sub02', 'Sub03', 'Sub04', 'Sub10']);
});

check('摘要：HeadMotion 默认阈值 0.2 → 超阈值 Sub02/Sub04、范围 0.05–0.35', () => {
  assert.equal(summary.headMotion.available, true);
  assert.equal(summary.headMotion.threshold, 0.2);
  assert.equal(summary.headMotion.thresholdSource, 'default');
  assert.deepEqual(summary.headMotion.over.map((row) => row.id), ['Sub02', 'Sub04']);
  assert.deepEqual(summary.headMotion.over.map((row) => row.meanFD), [0.35, 0.22]);
  assert.equal(summary.headMotion.minMeanFD, 0.05);
  assert.equal(summary.headMotion.maxMeanFD, 0.35);
  assert.ok(Math.abs(summary.headMotion.meanOfMeanFD - 0.164) < 1e-9);
});

// ------------------------------------------------------------------
// 5. 阈值文件（sample2）：T1Min=4 / MaxMeanFD=0.3 / UseMeanFD=true
// ------------------------------------------------------------------
const summary2 = buildQcSummary(sample2);

check('阈值文件：MaxMeanFD=0.3 → 仅 Sub02 超阈值；UseMeanFD 透传', () => {
  assert.equal(summary2.headMotion.threshold, 0.3);
  assert.equal(summary2.headMotion.thresholdSource, 'QC/ManualQC_thresholds.json');
  assert.equal(summary2.headMotion.useMeanFD, true);
  assert.deepEqual(summary2.headMotion.over.map((row) => row.id), ['Sub02']);
});

check('阈值文件：T1Min=4 → 低于配置阈值名单含 Sub10（低分不重复列出）', () => {
  const t1 = summary2.modalities.find((modality) => modality.key === 'T1');
  assert.equal(t1.minScore, 4);
  assert.deepEqual(t1.belowThreshold, [{ id: 'Sub10', score: 3 }]);
});

// ------------------------------------------------------------------
// 6. 缺文件分支（sample3）
// ------------------------------------------------------------------
const summary3 = buildQcSummary(sample3);

check('缺文件：hasScores=false、各模态 available=false、warnings 非空', () => {
  assert.equal(summary3.hasScores, false);
  assert.equal(summary3.subjectTotal, 1);
  for (const modality of summary3.modalities) {
    assert.equal(modality.available, false);
    assert.equal(modality.scored, 0);
  }
  assert.equal(summary3.headMotion.available, false);
  assert.ok(summary3.warnings.length >= 2);
});

// ------------------------------------------------------------------
// 7. 渲染文本（工具 render / /mri qcstatus 共用）
// ------------------------------------------------------------------
check('渲染：包含每模态进度、低分、未评分、MeanFD 超阈值、最近评语', () => {
  const text = renderQcSummary({ ...summary, workDirSource: 'prepare' });
  assert.ok(text.includes('人工 QC 摘要'));
  assert.ok(text.includes('工作目录来源：最近一次「生成配置」的工作目录'));
  assert.ok(text.includes('受试者总数：5 名'));
  assert.ok(text.includes('T1 原始像（QC/RawT1ImgQC.tsv）：已评分 4/5（80%），平均分 3.5'));
  assert.ok(text.includes('低分（≤2）：Sub02（2 分）'));
  assert.ok(text.includes('未评分（1）：Sub03'));
  assert.ok(text.includes('最近评语：Sub01「图像清晰，无伪影」'));
  assert.ok(text.includes('功能平均像（QC/RawFunImgQC.tsv）：已评分 4/5（80%），平均分 2.5'));
  assert.ok(text.includes('MeanFD 超阈值（≥ 0.2 mm）：Sub02（0.350）；Sub04（0.220）'));
  assert.ok(text.includes('低于配置阈值（Min=3）') === false, '默认阈值下低分已覆盖，不应重复列 belowThreshold');
});

check('渲染：阈值文件说明 + 低分提示', () => {
  const text2 = renderQcSummary({ ...summary2, workDirSource: 'prep-state' });
  assert.ok(text2.includes('阈值文件 UseMeanFD=false') === false, 'UseMeanFD=true 不应提示禁用');
  assert.ok(text2.includes('低于配置阈值（Min=4）：Sub10（3 分）'));
  assert.ok(text2.includes('低分（≤2）或未评分受试者建议人工复核'));
});

check('渲染：无评分时给出打开查看器提示', () => {
  const text3 = renderQcSummary(summary3);
  assert.ok(text3.includes('未找到 QC/RawT1ImgQC.tsv'));
  assert.ok(text3.includes('尚未找到已保存的人工 QC 评分'));
  assert.ok(text3.includes('/mri qc'));
});

// ------------------------------------------------------------------
// 8. JSON-safe：undefined 剔除、NaN/Infinity → null、可无损往返
// ------------------------------------------------------------------
check('JSON-safe：undefined/NaN/Infinity 处理 + 摘要可无损 JSON 往返', () => {
  assertLossless(summary, 'buildQcSummary 原始结果');
  const safe = jsonSafe({
    ...summary,
    workDirSource: 'prepare',
    optional: undefined,
    badNumber: Number.NaN,
    nested: { missing: undefined, infinity: Number.POSITIVE_INFINITY },
  });
  assertLossless(safe, 'jsonSafe 结果');
  assert.equal(Object.prototype.hasOwnProperty.call(safe, 'optional'), false);
  assert.equal(safe.badNumber, null);
  assert.equal(safe.nested.infinity, null);
  const roundtrip = JSON.parse(JSON.stringify(safe));
  assert.deepEqual(roundtrip, safe);
});

// ------------------------------------------------------------------
// 输出摘要样例（便于人工检查）
// ------------------------------------------------------------------
console.log('\n================ 渲染样例：sample/（默认阈值） ================');
console.log(renderQcSummary({ ...summary, workDirSource: 'prepare' }));
console.log('\n================ 渲染样例：sample3/（无评分文件） ================');
console.log(renderQcSummary(summary3));

console.log(`\n全部通过：${passed} 项检查`);
