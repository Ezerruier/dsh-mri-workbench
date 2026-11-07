function test_qc_model()
% test_qc_model  人工 QC 数据模型 mrw.QcModel 的自包含测试（-batch 可运行）
%
% 运行：
%   matlab -batch "cd('<项目根>\MRI_Workbench'); addpath(pwd); addpath('tests'); test_qc_model"
%
% 覆盖（对应 docs/QC_CONTRACT.md 1.5）：
%   fixture / discover（含自然排序、Missing、无目录、仅 TSV 推断）/ subjects
%   （T1、Fun、Norm、FunImg 4D 回退）/ loadVolume（.nii、.nii.gz、4D 平均、
%   缺失与损坏文件）/ makeSlice（三方向、clamp、缺省中间层、空数据）/
%   edgeSliceFor（真实 DPABI Edge 模板重采样、三方向尺寸一致且非空、失败兜底、
%   兼容旧签名）/ 评分 TSV（往返、合并、覆盖、非法分数、DPARSF 格式与 UTF-8）/
%   progress / 阈值 json / exportPassList（评分过滤、MeanFD 过滤、导出文件）/
%   loadHeadMotion（21 列解析）/ labels / settings。
%
% 输出末尾打印 "PASS xx/xx"（全部通过）或 "FAIL xx/xx" 并抛错（-batch 退出码非 0）。
%
% 编写：qc-engineer（MRI 静息态工作台）。

    t0 = tic;
    nPass = 0;
    nTotal = 0;
    fails = {};
    base = '';

    fprintf('==== test_qc_model: manual QC data model (mrw.QcModel) ====\n');
    fprintf('MATLAB %s | pwd=%s\n', version, pwd);

    section('environment', @secEnvironment);
    section('fixture', @secFixture);
    section('discover', @secDiscover);
    section('subjects', @secSubjects);
    section('loadVolume', @secLoadVolume);
    section('makeSlice', @secMakeSlice);
    section('edgeSliceFor', @secEdgeSlice);
    section('scoring TSV', @secScoring);
    section('progress', @secProgress);
    section('thresholds', @secThresholds);
    section('exportPassList', @secExport);
    section('loadHeadMotion', @secHeadMotion);
    section('labels/settings', @secLabels);
    section('fixture repeatability', @secFixtureRepeat);

    elapsed = toc(t0);
    fprintf('\n==== test_qc_model: %d/%d checks passed in %.1f s ====\n', ...
        nPass, nTotal, elapsed);
    if isempty(fails) && nPass == nTotal && nTotal > 0
        fprintf('PASS %d/%d\n', nPass, nTotal);
    else
        fprintf('FAIL %d/%d\n', nPass, nTotal);
        for i = 1:numel(fails)
            fprintf('  - %s\n', fails{i});
        end
        error('test_qc_model: %d/%d 项检查失败（详见上方 FAIL/错误列表）', ...
            nTotal - nPass, nTotal);
    end

    % =====================================================================
    % 各测试段（嵌套函数，共享 base 与计数器）
    % =====================================================================

    function secEnvironment()
        check(~isempty(which('mrw.QcModel')), 'env: mrw.QcModel on path');
        check(~isempty(which('DPABI.m')), 'env: DPABI on path');
        check(~isempty(which('spm_vol')), 'env: SPM12 on path');
        check(~isempty(which('y_Read')), 'env: DPABI y_Read available');
        p = mrw.QcModel.mniEdgeFile();
        fprintf('       edge template = %s\n', p);
        check(~isempty(p) && exist(p, 'file') == 2, 'env: DPABI Edge template exists');
        check(~isempty(strfind(p, 'Edge_mni_icbm152_AllTissues')), ...
            'env: edge template is the DPABI AllTissues template');
        pt = mrw.QcModel.mniTemplateFile();
        fprintf('       mni template  = %s\n', pt);
        check(~isempty(pt) && exist(pt, 'file') == 2, 'env: DPABI ch2.nii exists');
    end

    function secFixture()
        base = qc_fixture();
        fprintf('       fixture base = %s\n', base);
        check(ischar(base) && exist(base, 'dir') == 7, 'fixture: base dir exists');
        check(exist(fullfile(base, 'QC'), 'dir') == 7, 'fixture: empty QC dir exists');
        check(exist(fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'), 'file') == 2, ...
            'fixture: T1Img/Sub01/coT1.nii exists');
        check(exist(fullfile(base, 'RealignParameter', 'Sub02', 'meanSub02.nii'), 'file') == 2, ...
            'fixture: RealignParameter/Sub02/meanSub02.nii exists');
        check(exist(fullfile(base, 'RealignParameter', 'Sub03', 'wmeanSub03.nii'), 'file') == 2, ...
            'fixture: RealignParameter/Sub03/wmeanSub03.nii exists');
        check(exist(fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'), 'file') == 2, ...
            'fixture: T1ImgNewSegment/Sub01/wT1.nii exists');
        check(exist(fullfile(base, 'T1ImgNewSegment', 'Sub03', 'wc1.nii'), 'file') == 2, ...
            'fixture: T1ImgNewSegment/Sub03/wc1.nii exists');
        % MNI 2mm 仿射是否正确写入头
        try
            V = spm_vol(fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
            expect = [2 0 0 -92; 0 2 0 -128; 0 0 2 -74; 0 0 0 1];
            M = V.mat;
            check(isequal(V.dim(:)', [91 109 91]), 'fixture: wT1 dim 91x109x91');
            check(max(abs(M(:) - expect(:))) < 1e-3, ...
                'fixture: wT1 hdr.mat is MNI 2mm affine');
        catch err
            fail(sprintf('fixture: spm_vol check error (%s)', err.message));
        end
        % HeadMotion 表头应为 21 列
        try
            fid = fopen(fullfile(base, 'RealignParameter', 'HeadMotion.tsv'), 'r', 'n', 'UTF-8');
            h = fgetl(fid);
            fclose(fid);
            parts = strsplit(h, sprintf('\t'));
            check(numel(parts) == 21, 'fixture: HeadMotion.tsv has 21 header columns');
        catch
            fail('fixture: read HeadMotion.tsv header');
        end
    end

    function secDiscover()
        if isempty(base), fail('discover: skipped (no fixture)'); return; end
        info = mrw.QcModel.discover(base);
        check(ischar(info.WorkingDir) && strcmpi(info.WorkingDir, base), ...
            'discover: WorkingDir is base');
        check(info.Ok, 'discover: Ok=true');
        check(ischar(info.Message) && ~isempty(info.Message), 'discover: Message non-empty');
        check(numel(info.Modalities) == 3, 'discover: 3 modalities');
        check(isequal({info.Modalities.Key}, {'T1', 'Fun', 'Norm'}), ...
            'discover: modality keys T1/Fun/Norm');
        check(isequal({info.Modalities.LabelZh}, ...
            {'T1 原始像', '功能平均像', '标准化检查'}), ...
            'discover: Chinese labels');
        check(all([info.Modalities.Available]), 'discover: all modalities available');
        expSubs = {'Sub01', 'Sub02', 'Sub03'};
        check(isequal(info.Modalities(1).SubjectIDs, expSubs), ...
            'discover: T1 SubjectIDs natural order');
        check(isequal(info.Modalities(2).SubjectIDs, expSubs), ...
            'discover: Fun SubjectIDs');
        check(isequal(info.Modalities(3).SubjectIDs, expSubs), ...
            'discover: Norm SubjectIDs');
        check(all(cellfun(@isempty, {info.Modalities.Missing})), ...
            'discover: Missing empty');
        check(strcmp(info.Modalities(1).TSVFile, fullfile('QC', 'RawT1ImgQC.tsv')), ...
            'discover: T1 TSVFile relative path');
        check(strcmp(info.Modalities(2).TSVFile, fullfile('QC', 'RawFunImgQC.tsv')), ...
            'discover: Fun TSVFile relative path');
        check(strcmp(info.Modalities(3).TSVFile, fullfile('QC', 'NormalizationQC.tsv')), ...
            'discover: Norm TSVFile relative path');
        check(isequal(info.SubjectIDs, expSubs), 'discover: info.SubjectIDs union');

        % 不存在的目录：Ok=false 且给中文提示
        info2 = mrw.QcModel.discover(fullfile(base, 'no_such_dir_xyz'));
        check(~info2.Ok && ~isempty(info2.Message), ...
            'discover: missing dir -> Ok=false + message');
        check(isempty(info2.SubjectIDs), 'discover: missing dir -> no subjects');

        % 自然排序：Sub2 < Sub10
        td = tempname();
        mkdir(fullfile(td, 'T1Img', 'Sub10'));
        mkdir(fullfile(td, 'T1Img', 'Sub2'));
        mkdir(fullfile(td, 'T1Img', 'Sub1'));
        info3 = mrw.QcModel.discover(td);
        check(isequal(info3.SubjectIDs, {'Sub1', 'Sub2', 'Sub10'}), ...
            'discover: natural sort Sub2 before Sub10');
        rmdir(td, 's');

        % 只有 QC TSV 的工作目录：能推断受试者并填入 Missing
        td = tempname();
        mkdir(fullfile(td, 'QC'));
        f = fullfile(td, 'QC', 'RawT1ImgQC.tsv');
        fid = fopen(f, 'w', 'n', 'UTF-8');
        fprintf(fid, 'Subject ID\tQC Score\tQC Comment\r\n');
        fprintf(fid, 'Sub01\t4\tok\r\n');
        fprintf(fid, 'Sub02\t2\tmotion\r\n');
        fclose(fid);
        info4 = mrw.QcModel.discover(td);
        check(isequal(info4.SubjectIDs, {'Sub01', 'Sub02'}), ...
            'discover: subjects inferred from QC TSV');
        check(~info4.Modalities(1).Available, 'discover: TSV-only -> T1 unavailable');
        check(isequal(info4.Modalities(1).Missing, {'Sub01', 'Sub02'}), ...
            'discover: TSV-only -> Missing inferred');
        rmdir(td, 's');
    end

    function secSubjects()
        if isempty(base), fail('subjects: skipped (no fixture)'); return; end
        S = mrw.QcModel.subjects(base, 'T1');
        check(numel(S) == 3, 'subjects(T1): 3 records');
        check(all([S.Available]), 'subjects(T1): all available');
        check(~isempty(strfind(S(1).File, 'coT1.nii')), 'subjects(T1): default file coT1.nii');
        check(strcmp(S(1).FileKind, 'T1'), 'subjects(T1): FileKind=T1');
        check(numel(S(1).Candidates) == 1 && strcmp(S(1).Candidates(1).Which, 'T1'), ...
            'subjects(T1): 1 candidate Which=T1');
        check(isequal({S.ID}, {'Sub01', 'Sub02', 'Sub03'}), 'subjects(T1): IDs');

        Sf = mrw.QcModel.subjects(base, 'Fun');
        check(strcmp(Sf(1).FileKind, 'FunMean'), 'subjects(Fun): FileKind=FunMean');
        check(~isempty(strfind(Sf(1).File, 'meanSub01')), 'subjects(Fun): mean file chosen');
        check(~Sf(1).ComputedMean, 'subjects(Fun): no auto mean needed');

        Sn = mrw.QcModel.subjects(base, 'Norm');
        check(strcmp(Sn(1).FileKind, 'NormFun'), 'subjects(Norm): default FileKind=NormFun');
        check(numel(Sn(1).Candidates) == 3, 'subjects(Norm): 3 candidate sub-images');
        check(isequal({Sn(1).Candidates.Which}, {'Fun', 'T1', 'GM'}), ...
            'subjects(Norm): candidate order Fun/T1/GM');
        check(~isempty(strfind(Sn(1).Candidates(2).File, 'wT1')), ...
            'subjects(Norm): T1 candidate is wT1');
        check(~isempty(strfind(Sn(1).Candidates(3).File, 'wc1')), ...
            'subjects(Norm): GM candidate is wc1');

        % FunImg 4D 回退（仅 FunImg 的临时工作目录）
        td = tempname();
        mkdir(fullfile(td, 'FunImg', 'Sub01'));
        D4 = zeros(10, 8, 5, 4);
        for t = 1:4
            D4(:, :, :, t) = t;
        end
        lead_make_nifti(D4, fullfile(td, 'FunImg', 'Sub01', 'rest.nii'), [2 2 2], 2);
        infoF = mrw.QcModel.discover(td);
        check(infoF.Modalities(2).Available, 'discover: FunImg 4D fallback available');
        Sf2 = mrw.QcModel.subjects(td, 'Fun');
        check(strcmp(Sf2(1).FileKind, 'Fun4DMean'), ...
            'subjects(Fun): 4D fallback FileKind=Fun4DMean');
        check(Sf2(1).ComputedMean, 'subjects(Fun): 4D fallback ComputedMean=true');
        rmdir(td, 's');

        % 空目录
        td = tempname();
        mkdir(td);
        S0 = mrw.QcModel.subjects(td, 'T1');
        check(isempty(S0), 'subjects: empty workdir -> empty struct');
        rmdir(td, 's');
    end

    function secLoadVolume()
        if isempty(base), fail('loadVolume: skipped (no fixture)'); return; end
        f = fullfile(base, 'T1Img', 'Sub01', 'coT1.nii');
        [vol, hdr, inf] = mrw.QcModel.loadVolume(f);
        fprintf('       nii source = %s\n', inf.Source);
        check(isempty(inf.Message), 'loadVolume: .nii no error');
        check(isequal(size(vol), [64 64 30]), 'loadVolume: .nii size 64x64x30');
        check(isa(vol, 'double'), 'loadVolume: vol is double');
        check(isequal(inf.Dim, [64 64 30]), 'loadVolume: info.Dim');
        check(strcmp(inf.Source, 'y_Read'), 'loadVolume: y_Read is first choice');
        check(isequal(size(hdr.mat), [4 4]) && all(isfinite(hdr.mat(:))), ...
            'loadVolume: hdr.mat valid 4x4');
        check(isequal(size(hdr.dim), [1 3]), 'loadVolume: hdr.dim 1x3');
        check(isequal(size(hdr.voxSize), [1 3]), 'loadVolume: hdr.voxSize 1x3');
        check(~inf.Mean4D && inf.TimePoints == 1, 'loadVolume: 3D TimePoints=1');

        % .nii.gz 读取
        gzDir = tempname();
        mkdir(gzDir);
        g = gzip(f, gzDir);
        if iscell(g), gzFile = g{1}; else, gzFile = g; end
        sibling = fullfile(gzDir, 'coT1.nii');
        fid = fopen(sibling, 'w'); fwrite(fid, uint8([11 22 33 44]), 'uint8'); fclose(fid);
        [volGz, hdrGz, infGz] = mrw.QcModel.loadVolume(gzFile);
        fprintf('       nii.gz source = %s\n', infGz.Source);
        check(~isempty(volGz) && isequal(size(volGz), [64 64 30]), ...
            'loadVolume: .nii.gz readable with same size');
        check(max(abs(volGz(:) - vol(:))) < 1e-4, 'loadVolume: .nii.gz data identical');
        check(~isempty(infGz.Source), 'loadVolume: .nii.gz info.Source set');
        check(strcmp(hdrGz.File, gzFile) && strcmp(infGz.File, gzFile), ...
            'loadVolume: .nii.gz preserves original source path');
        siblingBytes = [];
        if exist(sibling, 'file') == 2
            fid = fopen(sibling, 'r'); siblingBytes = fread(fid, Inf, '*uint8').'; fclose(fid);
        end
        check(isequal(siblingBytes, uint8([11 22 33 44])), ...
            'loadVolume: .nii.gz never overwrites/deletes existing sibling .nii');
        rmdir(gzDir, 's');

        % 4D 时间平均
        td = tempname();
        mkdir(td);
        D4 = zeros(8, 6, 4, 5);
        for t = 1:5
            D4(:, :, :, t) = t;
        end
        f4 = fullfile(td, 'rest4d.nii');
        lead_make_nifti(D4, f4, [2 2 2], 2);
        [vol4, hdr4, inf4] = mrw.QcModel.loadVolume(f4);
        check(isequal(size(vol4), [8 6 4]), 'loadVolume: 4D reduced to 3D');
        check(inf4.Mean4D && inf4.TimePoints == 5, ...
            'loadVolume: 4D info.Mean4D=true TimePoints=5');
        check(max(abs(vol4(:) - 3)) < 1e-4, 'loadVolume: 4D time mean correct');
        check(isequal(size(hdr4.mat), [4 4]), 'loadVolume: 4D hdr.mat kept');
        rmdir(td, 's');

        % 缺失文件与损坏文件：优雅失败
        [volB, hdrB, infB] = mrw.QcModel.loadVolume(fullfile(base, 'nope.nii'));
        check(isempty(volB) && ~isempty(infB.Message), ...
            'loadVolume: missing file -> empty vol + message');
        check(any(isnan(hdrB.mat(:))), 'loadVolume: missing file -> hdr.mat NaN');
        td = tempname();
        mkdir(td);
        bad = fullfile(td, 'bad.nii');
        fid = fopen(bad, 'w');
        fwrite(fid, uint8([1 2 3 4 5 6 7 8]), 'uint8');
        fclose(fid);
        % 用 evalc 捕获 SPM 对坏文件打印的调试信息，保持测试输出整洁
        [~, volC, ~, infC] = evalc('mrw.QcModel.loadVolume(bad)');
        check(isempty(volC) && ~isempty(infC.Message), ...
            'loadVolume: corrupt file -> empty vol + message');
        rmdir(td, 's');
    end

    function secMakeSlice()
        if isempty(base), fail('makeSlice: skipped (no fixture)'); return; end
        [vol, ~, ~] = mrw.QcModel.loadVolume(fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'));
        sl = mrw.QcModel.makeSlice(vol, 'axial', 10);
        check(isequal(size(sl.Image), [64 64]), 'makeSlice(axial): size 64x64');
        check(isequal(sl.Image, vol(:, :, 10)), 'makeSlice(axial): equals vol(:,:,k)');
        check(strcmp(sl.SliceLabel, 'Axial z=10/30'), 'makeSlice(axial): label');
        check(sl.SliceCount == 30 && sl.SliceIndex == 10, ...
            'makeSlice(axial): SliceIndex/SliceCount');
        check(strcmp(sl.Orientation, 'axial') && isempty(sl.Message), ...
            'makeSlice(axial): orientation/message');

        sl2 = mrw.QcModel.makeSlice(vol, 'coronal', 20);
        check(isequal(size(sl2.Image), [30 64]), 'makeSlice(coronal): size [z x]');
        check(isequal(sl2.Image, flipud(squeeze(vol(:, 20, :)).')), ...
            'makeSlice(coronal): flipud(squeeze(...)) formula');
        check(strcmp(sl2.SliceLabel, 'Coronal y=20/64'), 'makeSlice(coronal): label');

        sl3 = mrw.QcModel.makeSlice(vol, 'sagittal', 5);
        check(isequal(size(sl3.Image), [30 64]), 'makeSlice(sagittal): size [z x]');
        check(isequal(sl3.Image, flipud(squeeze(vol(5, :, :)).')), ...
            'makeSlice(sagittal): flipud(squeeze(...)) formula');
        check(strcmp(sl3.SliceLabel, 'Sagittal x=5/64'), 'makeSlice(sagittal): label');

        slc = mrw.QcModel.makeSlice(vol, 'axial', 999);
        check(slc.SliceIndex == 30, 'makeSlice: upper clamp');
        slc2 = mrw.QcModel.makeSlice(vol, 'axial', -5);
        check(slc2.SliceIndex == 1, 'makeSlice: lower clamp');
        slm = mrw.QcModel.makeSlice(vol, 'axial');
        check(slm.SliceIndex == round((30 + 1) / 2), ...
            'makeSlice: default middle slice (round((n+1)/2))');
        sle = mrw.QcModel.makeSlice([], 'axial', 3);
        check(isempty(sle.Image) && sle.SliceCount == 0 && ~isempty(sle.Message), ...
            'makeSlice: empty vol graceful');
        slz = mrw.QcModel.makeSlice(vol, '冠状', 5);
        check(strcmp(slz.Orientation, 'coronal'), 'makeSlice: Chinese orientation name');

        % 91x109x91 体积的三方向尺寸
        [volW, ~, ~] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
        check(isequal(size(mrw.QcModel.makeSlice(volW, 'axial', 46).Image), [91 109]), ...
            'makeSlice(91x109x91): axial [91 109]');
        check(isequal(size(mrw.QcModel.makeSlice(volW, 'coronal', 55).Image), [91 91]), ...
            'makeSlice(91x109x91): coronal [91 91]');
        check(isequal(size(mrw.QcModel.makeSlice(volW, 'sagittal', 46).Image), [91 109]), ...
            'makeSlice(91x109x91): sagittal [91 109]');
    end

    function secEdgeSlice()
        if isempty(base), fail('edgeSliceFor: skipped (no fixture)'); return; end
        [volW, hdrW, ~] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
        orientations = {'axial', 'coronal', 'sagittal'};
        for i = 1:numel(orientations)
            o = orientations{i};
            sl = mrw.QcModel.makeSlice(volW, o);
            e = mrw.QcModel.edgeSliceFor(hdrW, o, sl.SliceIndex, size(sl.Image));
            mx = max(e(:));
            fprintf('       edge(%s) size=%s max=%.4f nnz>0.05=%d\n', ...
                o, mat2str(size(e)), mx, nnz(e > 0.05));
            check(isequal(size(e), size(sl.Image)), ...
                sprintf('edgeSliceFor(%s): same size as makeSlice.Image', o));
            check(all(isfinite(e(:))), ...
                sprintf('edgeSliceFor(%s): finite values', o));
            check(mx > 0.05, ...
                sprintf('edgeSliceFor(%s): non-empty contour (max=%.3f)', o, mx));
            check(all(e(:) >= 0) && all(e(:) <= 1), ...
                sprintf('edgeSliceFor(%s): weights in [0,1]', o));
        end
        % 兼容旧签名 (hdr, vol, orientation, sliceIndex)
        e2 = mrw.QcModel.edgeSliceFor(hdrW, volW, 'coronal', 55);
        check(isequal(size(e2), [91 91]), ...
            'edgeSliceFor: compatible (hdr,vol,orientation,sliceIndex) signature');
        e2b = mrw.QcModel.edgeSliceFor(hdrW, volW, 'axial', 46);
        check(max(e2b(:)) > 0.05, 'edgeSliceFor: compatible signature yields contour');
        % 失败路径：hdr.mat 无效 -> zeros + warning，不崩溃
        ws = warning('off', 'mrw:QcModel:edgeTemplate');
        eBad = mrw.QcModel.edgeSliceFor(struct('mat', nan(4), 'dim', [91 109 91]), ...
            'axial', 46, [91 109]);
        warning(ws);
        check(isequal(size(eBad), [91 109]) && all(eBad(:) == 0), ...
            'edgeSliceFor: invalid hdr.mat -> zeros, no throw');
        % 失败路径：模板不可用模拟（此处验证 imageSize 不一致时的兜底）
        ws = warning('off', 'mrw:QcModel:edgeTemplate');
        eMis = mrw.QcModel.edgeSliceFor(hdrW, 'axial', 46, [10 10]);
        warning(ws);
        check(isequal(size(eMis), [10 10]) && all(eMis(:) == 0), ...
            'edgeSliceFor: mismatched imageSize -> zeros(imageSize)');
        % 轮廓中心区域应与脑部大致重合（定量证据：轴向中心层 > 200 个轮廓点）
        sl = mrw.QcModel.makeSlice(volW, 'axial', 46);
        e = mrw.QcModel.edgeSliceFor(hdrW, 'axial', 46, size(sl.Image));
        nEdge = nnz(e > 0.05);
        check(nEdge > 200, sprintf('edgeSliceFor: center slice contour points=%d (>200)', nEdge));
    end

    function secScoring()
        if isempty(base), fail('scoring: skipped (no fixture)'); return; end
        fT1 = fullfile(base, 'QC', 'RawT1ImgQC.tsv');
        sc0 = mrw.QcModel.loadScores(base, 'T1');
        check(isempty(sc0) && isfield(sc0, 'ID') && isfield(sc0, 'Score') && ...
            isfield(sc0, 'Comment'), 'scores: missing TSV -> empty struct with fields');

        [ok, msg] = mrw.QcModel.saveScore(base, 'T1', 'Sub01', 4, '图像清晰，无伪影');
        check(ok && isempty(msg), 'scores: saveScore Sub01 score 4 ok');
        check(exist(fT1, 'file') == 2, 'scores: RawT1ImgQC.tsv written');

        % 表头与 3 列格式
        fid = fopen(fT1, 'r', 'n', 'UTF-8');
        l1 = fgetl(fid);
        fclose(fid);
        check(strcmp(l1, sprintf('Subject ID\tQC Score\tQC Comment')), ...
            'scores: header matches DPARSF exactly');
        raw = fileread(fT1);
        lines = regexp(raw, '\r\n|\n|\r', 'split');
        lines = lines(~cellfun(@isempty, lines));
        ncolOK = true;
        for i = 1:numel(lines)
            p = strsplit(lines{i}, sprintf('\t'));
            if numel(p) ~= 3, ncolOK = false; end
        end
        check(ncolOK, 'scores: every row has 3 tab-separated columns');

        sc = mrw.QcModel.loadScores(base, 'T1');
        check(numel(sc) == 1 && strcmp(sc(1).ID, 'Sub01') && sc(1).Score == 4, ...
            'scores: roundtrip ID/Score');
        check(strcmp(sc(1).Comment, '图像清晰，无伪影'), ...
            'scores: Chinese comment roundtrip (UTF-8)');
        % UTF-8 落盘字节证据（注意关闭文件句柄，否则后续 fixture 目录无法清理）
        try
            fid = fopen(fT1, 'r');
            b = fread(fid, Inf, '*uint8')';
            fclose(fid);
            u = unicode2native('图像清晰', 'UTF-8');
            hit = strfind(double(b), double(u));
            check(~isempty(hit), 'scores: comment stored as UTF-8 bytes');
        catch err
            fail(sprintf('scores: UTF-8 byte check error (%s)', err.message));
        end

        % 合并 + 覆盖（保持原行序）
        mrw.QcModel.saveScore(base, 'T1', 'Sub02', 2, '运动伪影明显');
        mrw.QcModel.saveScore(base, 'T1', 'Sub01', 5, '复核后改判');
        sc = mrw.QcModel.loadScores(base, 'T1');
        check(numel(sc) == 2, 'scores: re-score does not add duplicate row');
        check(strcmp(sc(1).ID, 'Sub01') && sc(1).Score == 5 && ...
            strcmp(sc(1).Comment, '复核后改判'), 'scores: overwrite keeps original order');
        check(strcmp(sc(2).ID, 'Sub02') && sc(2).Score == 2, ...
            'scores: other subject row preserved');
        mrw.QcModel.saveScore(base, 'T1', 'Sub03', 3, '一般');
        sc = mrw.QcModel.loadScores(base, 'T1');
        check(numel(sc) == 3 && sc(3).Score == 3, 'scores: append new subject');

        % 非法评分
        [ok0, m0] = mrw.QcModel.saveScore(base, 'T1', 'Sub03', 0, 'x');
        check(~ok0 && ~isempty(m0), 'scores: score 0 rejected with message');
        ok6 = mrw.QcModel.saveScore(base, 'T1', 'Sub03', 6, 'x');
        check(~ok6, 'scores: score 6 rejected');
        okf = mrw.QcModel.saveScore(base, 'T1', 'Sub03', 2.5, 'x');
        check(~okf, 'scores: fractional score rejected');
        sc = mrw.QcModel.loadScores(base, 'T1');
        check(numel(sc) == 3 && sc(3).Score == 3, 'scores: rejected scores did not change file');
        [okNoDir, mNoDir] = mrw.QcModel.saveScore(fullfile(base, 'no_such'), 'T1', 'X', 3, '');
        check(~okNoDir && ~isempty(mNoDir), 'scores: missing workdir rejected with message');

        % Fun / Norm TSV 文件名
        mrw.QcModel.saveScore(base, 'Fun', 'Sub01', 4, '');
        mrw.QcModel.saveScore(base, 'Norm', 'Sub01', 5, '');
        check(exist(fullfile(base, 'QC', 'RawFunImgQC.tsv'), 'file') == 2, ...
            'scores: RawFunImgQC.tsv filename');
        check(exist(fullfile(base, 'QC', 'NormalizationQC.tsv'), 'file') == 2, ...
            'scores: NormalizationQC.tsv filename');

        % 模拟 DPARSF 生成的 TSV（CRLF、未评分 NaN）可被读取
        td = tempname();
        mkdir(fullfile(td, 'QC'));
        fdp = fullfile(td, 'QC', 'RawT1ImgQC.tsv');
        fid = fopen(fdp, 'w', 'n', 'UTF-8');
        fprintf(fid, 'Subject ID\tQC Score\tQC Comment\r\n');
        fprintf(fid, 'Sub01\t4\tok\r\n');
        fprintf(fid, 'Sub02\t2\tmotion\r\n');
        fprintf(fid, 'Sub03\tNaN\t\r\n');
        fclose(fid);
        sdp = mrw.QcModel.loadScores(td, 'T1');
        check(numel(sdp) == 3, 'scores: DPARSF-style TSV parsed (3 rows)');
        check(sdp(1).Score == 4 && sdp(2).Score == 2, 'scores: DPARSF-style scores parsed');
        check(isnan(sdp(3).Score), 'scores: NaN score -> unscored (NaN)');
        % 合并保存到 DPARSF 文件后仍保持 3 列
        ok = mrw.QcModel.saveScore(td, 'T1', 'Sub02', 3, 'revised');
        sdp = mrw.QcModel.loadScores(td, 'T1');
        check(ok && numel(sdp) == 3 && sdp(2).Score == 3, ...
            'scores: merge into DPARSF-style file works');
        rmdir(td, 's');

        % 中途状态：只有 T1 全部评完，Fun/Norm 未评 -> AllScored=false
        prog = mrw.QcModel.progress(base);
        check(prog.T1.Scored == 3 && prog.T1.Total == 3, ...
            'progress: T1 fully scored before Fun/Norm');
        check(~prog.AllScored, 'progress: AllScored=false when Fun/Norm unscored');

        % 完成 Fun / Norm 评分，构造后续 export 测试的评分矩阵
        mrw.QcModel.saveScore(base, 'Fun', 'Sub02', 3, '');
        mrw.QcModel.saveScore(base, 'Fun', 'Sub03', 1, '');
        mrw.QcModel.saveScore(base, 'Norm', 'Sub02', 3, '');
        mrw.QcModel.saveScore(base, 'Norm', 'Sub03', 2, '');
    end

    function secProgress()
        if isempty(base), fail('progress: skipped (no fixture)'); return; end
        prog = mrw.QcModel.progress(base);
        check(prog.T1.Scored == 3 && prog.T1.Total == 3, 'progress: T1 3/3');
        check(abs(prog.T1.Mean - (5 + 2 + 3) / 3) < 1e-9, ...
            sprintf('progress: T1 mean=%.3f', prog.T1.Mean));
        check(prog.Fun.Scored == 3 && prog.Fun.Total == 3, 'progress: Fun 3/3');
        check(abs(prog.Fun.Mean - (4 + 3 + 1) / 3) < 1e-9, ...
            sprintf('progress: Fun mean=%.3f', prog.Fun.Mean));
        check(prog.Norm.Scored == 3 && prog.Norm.Total == 3, 'progress: Norm 3/3');
        check(prog.AllScored, 'progress: AllScored=true');
        check(isfield(prog, 'T1') && isfield(prog.T1, 'Scored') && ...
            isfield(prog.T1, 'Total') && isfield(prog.T1, 'Mean'), ...
            'progress: struct fields Scored/Total/Mean');

        td = tempname();
        mkdir(td);
        prog0 = mrw.QcModel.progress(td);
        check(prog0.T1.Total == 0 && ~prog0.AllScored && isnan(prog0.T1.Mean), ...
            'progress: empty workdir -> 0/0, no crash');
        rmdir(td, 's');
    end

    function secThresholds()
        if isempty(base), fail('thresholds: skipped (no fixture)'); return; end
        thr = mrw.QcModel.loadThresholds(base);
        def = struct('T1Min', 3, 'FunMin', 3, 'NormMin', 3, ...
            'UseT1', true, 'UseFun', true, 'UseNorm', true, ...
            'MaxMeanFD', 0.2, 'UseMeanFD', false);
        check(isequal(thr, def), 'thresholds: defaults match contract');
        thr2 = thr;
        thr2.T1Min = 4;
        thr2.UseFun = false;
        thr2.UseMeanFD = true;
        thr2.MaxMeanFD = 0.3;
        [ok, msg] = mrw.QcModel.saveThresholds(base, thr2);
        check(ok && isempty(msg), 'thresholds: saveThresholds ok');
        jf = fullfile(base, 'QC', 'ManualQC_thresholds.json');
        check(exist(jf, 'file') == 2, 'thresholds: json file written');
        thr3 = mrw.QcModel.loadThresholds(base);
        check(thr3.T1Min == 4 && thr3.UseFun == false && ...
            thr3.UseMeanFD == true && abs(thr3.MaxMeanFD - 0.3) < 1e-12, ...
            'thresholds: json roundtrip');
        check(thr3.FunMin == 3 && thr3.UseT1 == true, ...
            'thresholds: unmodified fields kept');
        % 损坏 json -> 静默回退默认值
        fid = fopen(jf, 'w');
        fprintf(fid, '{not-valid-json');
        fclose(fid);
        thr4 = mrw.QcModel.loadThresholds(base);
        check(isequal(thr4, def), 'thresholds: corrupt json -> defaults');
        % 恢复默认阈值文件
        ok = mrw.QcModel.saveThresholds(base, def);
        check(ok, 'thresholds: restore defaults ok');
    end

    function secExport()
        if isempty(base), fail('exportPassList: skipped (no fixture)'); return; end
        def = mrw.QcModel.loadThresholds(base);
        % 三模态均 >= 3：只有 Sub01（T1=5,Fun=4,Norm=5）
        thrA = def;
        outA = fullfile(base, 'QC', 'passA.txt');
        [listA, msgA] = mrw.QcModel.exportPassList(base, outA, thrA);
        check(isempty(msgA) && isequal(listA, {'Sub01'}), ...
            'export: all modalities >=3 -> Sub01');
        check(exist(outA, 'file') == 2, 'export: pass list file written');
        txt = fileread(outA);
        lines = regexp(txt, '\r\n|\n|\r', 'split');
        lines = lines(~cellfun(@isempty, lines));
        check(numel(lines) == 1 && strcmp(strtrim(lines{1}), 'Sub01'), ...
            'export: file content one subject per line');

        % 阈值降到 2：Sub01, Sub02（Sub03 Fun=1 不通过）
        thrB = def;
        thrB.T1Min = 2;
        thrB.FunMin = 2;
        thrB.NormMin = 2;
        listB = mrw.QcModel.exportPassList(base, '', thrB);
        check(isequal(listB, {'Sub01', 'Sub02'}), ...
            'export: thresholds 2 -> Sub01,Sub02');

        % 再加 MeanFD < 0.2：只剩 Sub01（Sub02=0.25, Sub03=0.45）
        thrC = thrB;
        thrC.UseMeanFD = true;
        thrC.MaxMeanFD = 0.2;
        listC = mrw.QcModel.exportPassList(base, '', thrC);
        check(isequal(listC, {'Sub01'}), 'export: MeanFD filter -> Sub01');

        % 关闭所有模态过滤 -> 全部 3 人
        thrD = def;
        thrD.UseT1 = false;
        thrD.UseFun = false;
        thrD.UseNorm = false;
        listD = mrw.QcModel.exportPassList(base, '', thrD);
        check(isequal(listD, {'Sub01', 'Sub02', 'Sub03'}), ...
            'export: no modality filter -> all subjects');

        % 输出到不存在的子目录也能创建
        outE = fullfile(base, 'QC', 'sub', 'passE.txt');
        listE = mrw.QcModel.exportPassList(base, outE, thrB);
        check(isequal(listE, {'Sub01', 'Sub02'}) && exist(outE, 'file') == 2, ...
            'export: create output subdirectory');

        % 无工作目录 -> 空名单 + 中文提示
        [listF, msgF] = mrw.QcModel.exportPassList(fullfile(base, 'no_such'), '', def);
        check(isempty(listF) && ~isempty(msgF), 'export: missing workdir graceful');
    end

    function secHeadMotion()
        if isempty(base), fail('headmotion: skipped (no fixture)'); return; end
        hm = mrw.QcModel.loadHeadMotion(base);
        check(hm.Available, 'headmotion: Available=true');
        check(isequal(hm.IDs, {'Sub01', 'Sub02', 'Sub03'}), 'headmotion: IDs');
        check(size(hm.Table, 1) == 3 && size(hm.Table, 2) == 20, ...
            'headmotion: Table 3x20 numeric');
        check(max(abs(hm.MeanFD - [0.08; 0.25; 0.45])) < 1e-9, ...
            'headmotion: MeanFD from 21st column');
        check(numel(hm.MaxTrans) == 3 && all(isfinite(hm.MaxTrans)) && ...
            hm.MaxTrans(3) > hm.MaxTrans(1), 'headmotion: MaxTrans per subject');
        check(numel(hm.Header) == 21, 'headmotion: header 21 columns');
        check(~isempty(strfind(hm.File, 'HeadMotion.tsv')), 'headmotion: File recorded');

        td = tempname();
        mkdir(td);
        hm2 = mrw.QcModel.loadHeadMotion(td);
        check(~hm2.Available && ~isempty(hm2.Message), ...
            'headmotion: missing file -> graceful message');
        rmdir(td, 's');
    end

    function secLabels()
        L = mrw.QcModel.labels();
        check(numel(L.Modalities) == 3 && numel(L.Scores) == 5 && ...
            numel(L.Orientations) == 3, 'labels: structure counts');
        check(strcmp(L.Scores(1).LabelZh, '很差') && ...
            strcmp(L.Scores(5).LabelZh, '很好'), 'labels: 1-5 Chinese labels');
        check(strcmp(L.Modalities(3).LabelZh, '标准化检查'), ...
            'labels: modality Chinese labels');
        st = mrw.QcModel.settings();
        check(st.ScoreMin == 1 && st.ScoreMax == 5 && st.DefaultScore == 3, ...
            'settings: score range');
        check(st.HasDpabiTemplate && ~isempty(st.EdgeTemplate), ...
            'settings: DPABI template available');
        t1 = mrw.QcModel.tsvFile(base, 'T1');
        check(~isempty(strfind(t1, 'RawT1ImgQC.tsv')), 'tsvFile: T1 path');
    end

    function secFixtureRepeat()
        % 可重复调用：新目录唯一、内容重新生成、上一目录被清理
        if isempty(base), fail('fixtureRepeat: skipped (no fixture)'); return; end
        oldBase = base;
        base2 = qc_fixture();
        check(ischar(base2) && exist(base2, 'dir') == 7, ...
            'fixture: repeat call returns existing dir');
        check(~strcmpi(base2, oldBase), 'fixture: repeat call uses a new unique dir');
        check(exist(oldBase, 'dir') ~= 7, 'fixture: previous fixture dir cleaned');
        check(exist(fullfile(base2, 'T1ImgNewSegment', 'Sub02', 'wT1.nii'), 'file') == 2, ...
            'fixture: repeat call regenerates full data');
        base = base2;
        try
            rmdir(base2, 's');
        catch
        end
    end

    % =====================================================================
    % 计数器与断言
    % =====================================================================

    function check(cond, label)
        nTotal = nTotal + 1;
        ok = false;
        try
            ok = ~isempty(cond) && all(cond(:));
        catch
            ok = false;
        end
        if ok
            nPass = nPass + 1;
            fprintf('[ok]   %s\n', label);
        else
            fails{end+1} = label; %#ok<AGROW>
            fprintf('[FAIL] %s\n', label);
        end
    end

    function fail(label)
        nTotal = nTotal + 1;
        fails{end+1} = label; %#ok<AGROW>
        fprintf('[FAIL] %s\n', label);
    end

    function section(name, fn)
        fprintf('\n-- %s --\n', name);
        try
            fn();
        catch err
            nTotal = nTotal + 1;
            msg = regexprep(err.message, '\s+', ' ');
            fails{end+1} = sprintf('section %s error: %s', name, msg); %#ok<AGROW>
            fprintf('[FAIL] section %s error: %s\n', name, msg);
        end
    end
end
