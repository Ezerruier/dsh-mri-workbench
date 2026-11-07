function test_scan_engine()
%TEST_SCAN_ENGINE 自动扫描索引模块（NiftiHeader + ScanEngine）自包含测试
%
%   本脚本在运行时向 tempdir 生成合成数据集（直接 fwrite NIfTI-1/NIfTI-2 头，
%   以及假的 .dcm 文件），不依赖真实 MRI 数据、不依赖 SPM / Image Processing
%   Toolbox（SPM 在路径中时只作为 DICOM 增强），可重复运行，结束后自动清理
%   临时目录。测试输出行使用 ASCII 标签，避免控制台编码问题。
%
%   用法（在项目根目录下）：
%       addpath('tests'); test_scan_engine
%   或：
%       matlab -batch "cd('...MRI_Workbench'); addpath('tests'); test_scan_engine"
%
%   输出：逐项 [ok]/[FAIL]，最后一行形如 “PASS 96/96”。

    here = fileparts(mfilename('fullpath'));
    projectRoot = fileparts(here);
    addpath(projectRoot);
    addpath(here);

    % ---------- 测试状态（嵌套函数共享） ----------
    state = struct('Total', 0, 'Passed', 0, 'Failures', {{}});

    tmpRoot = fullfile(tempdir, sprintf('mrw_scantest_%s', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'))));
    [mkOK, mkMsg] = mkdir(tmpRoot);
    if ~mkOK
        error('无法创建测试临时目录：%s（%s）', tmpRoot, mkMsg);
    end
    cleanupObj = onCleanup(@() safeRemoveDir(tmpRoot));

    fprintf('test temp root: %s\n', tmpRoot);

    runSafe('NiftiHeader', @sectionNiftiHeader);
    runSafe('ScanEngine-DPARSF', @sectionDPARSF);
    runSafe('ScanEngine-RootModal', @sectionRootModal);
    runSafe('ScanEngine-BIDS', @sectionBIDS);
    runSafe('ScanEngine-NIfTI', @sectionNiftiGeneric);
    runSafe('ScanEngine-DICOM', @sectionDicom);
    runSafe('ScanEngine-Mixed-Depth-Options', @sectionMixedDepthOptions);
    runSafe('ScanEngine-Performance', @sectionPerformance);
    runSafe('ScanEngine-Interface', @sectionInterface);

    % ---------- 汇总 ----------
    fprintf('\n---- test summary ----\n');
    if isempty(state.Failures)
        fprintf('PASS %d/%d\n', state.Passed, state.Total);
    else
        fprintf('FAIL %d/%d (%d passed)\n', state.Total - state.Passed, state.Total, state.Passed);
        for k = 1:numel(state.Failures)
            fprintf('  not passed: %s\n', state.Failures{k});
        end
    end

    % ======================================================================
    % 嵌套函数：断言、section 执行、各测试 section
    % ======================================================================
    function check(cond, name)
        %CHECK 记录一条断言结果
        state.Total = state.Total + 1;
        if ~isempty(cond) && isequal(all(logical(cond(:))), true)
            state.Passed = state.Passed + 1;
            fprintf('  [ok] %s\n', name);
        else
            state.Failures{end+1} = name;
            fprintf('  [FAIL] %s\n', name);
        end
    end

    function checkClose(val, expected, tol, name)
        %CHECKCLOSE 数值近似比较（NaN 也视为相等）
        ok = isnumeric(val) && isequal(size(val), size(expected));
        if ok
            bothNaN = isnan(val) & isnan(expected);
            ok = all(bothNaN(:) | abs(val(:) - expected(:)) <= tol);
        end
        check(ok, name);
    end

    function runSafe(sectionName, fcn)
        %RUNSAFE 执行一个测试 section，异常时记录失败但不中断后续 section
        fprintf('\n== %s ==\n', sectionName);
        before = state.Total;
        try
            fcn();
        catch err
            check(false, sprintf('%s: no unexpected error (%s)', sectionName, err.message));
        end
        fprintf('  -- section checks: %d\n', state.Total - before);
    end

    % ------------------------------------------------------------------
    % 1. NIfTI 头解析
    % ------------------------------------------------------------------
    function sectionNiftiHeader()
        niiDir = fullfile(tmpRoot, '中文路径 测试', 'NIfTI头');

        % ---- 1.1 标准 NIfTI-1 单文件 .nii（float32，4D，TR=2s，32 层） ----
        f1 = fullfile(niiDir, 'rest4d.nii');
        writeNifti1(f1, [2 2 32 20], [2 2 4 2], 16);
        info = mrw.NiftiHeader.read(f1);
        expectedFields = {'File', 'Format', 'Dim', 'VoxSize', 'TR', ...
            'TimePoints', 'SliceNumber', 'DatatypeName', 'ReadOK', 'Message'};
        check(isequal(fieldnames(info), expectedFields(:)), 'NIfTI: contract fields and order');
        check(info.ReadOK && islogical(info.ReadOK), 'NIfTI: ReadOK true (logical)');
        check(strcmp(info.Format, 'nii'), 'NIfTI: Format nii');
        check(isAbsPath(info.File), 'NIfTI: File absolute path');
        check(info.File(end) == 'i', 'NIfTI: File points to source file');
        check(isequal(size(info.Dim), [1 8]), 'NIfTI: Dim is 1x8');
        checkClose(info.Dim(1:5), [4 2 2 32 20], 0, 'NIfTI: Dim values');
        checkClose(info.VoxSize, [2 2 4], 1e-9, 'NIfTI: VoxSize');
        checkClose(info.TR, 2, 1e-9, 'NIfTI: TR seconds');
        checkClose(info.TimePoints, 20, 0, 'NIfTI: TimePoints');
        checkClose(info.SliceNumber, 32, 0, 'NIfTI: SliceNumber');
        check(strcmp(info.DatatypeName, 'float32'), 'NIfTI: DatatypeName float32');
        check(isempty(info.Message), 'NIfTI: Message empty on success');

        % ---- 1.2 .nii.gz ----
        gz = makeGzFile(fullfile(niiDir, 'rest4d.nii'));
        info = mrw.NiftiHeader.read(gz);
        check(info.ReadOK && strcmp(info.Format, 'nii.gz'), 'NIfTI: .nii.gz ReadOK + Format');
        checkClose(info.TR, 2, 1e-9, 'NIfTI: .nii.gz TR');
        checkClose(info.Dim(1:5), [4 2 2 32 20], 0, 'NIfTI: .nii.gz Dim');
        checkClose(info.TimePoints, 20, 0, 'NIfTI: .nii.gz TimePoints');

        % ---- 1.3 .hdr + .img 双文件（传 .hdr 与传 .img 都应可读） ----
        f3 = fullfile(niiDir, 'pair3d.hdr');
        writeNiftiPair(f3, [16 16 32], [1 1 1 0], 4);
        info = mrw.NiftiHeader.read(f3);
        check(info.ReadOK && strcmp(info.Format, 'hdr/img'), 'NIfTI: hdr/img ReadOK + Format');
        checkClose(info.Dim(1:4), [3 16 16 32], 0, 'NIfTI: hdr/img Dim');
        checkClose(info.TimePoints, 1, 0, 'NIfTI: hdr/img TimePoints=1');
        checkClose(info.SliceNumber, 32, 0, 'NIfTI: hdr/img SliceNumber');
        check(strcmp(info.DatatypeName, 'int16'), 'NIfTI: hdr/img DatatypeName int16');
        infoImg = mrw.NiftiHeader.read(fullfile(niiDir, 'pair3d.img'));
        check(infoImg.ReadOK && strcmp(infoImg.Format, 'hdr/img'), 'NIfTI: reading .img resolves .hdr');

        % ---- 1.4 NIfTI-2 ----
        f4 = fullfile(niiDir, 'nifti2.nii');
        writeNifti2(f4, [2 2 30 12], [3 3 3 3], 64);
        info = mrw.NiftiHeader.read(f4);
        check(info.ReadOK, 'NIfTI: NIfTI-2 ReadOK');
        checkClose(info.Dim(1:5), [4 2 2 30 12], 0, 'NIfTI: NIfTI-2 Dim');
        checkClose(info.VoxSize, [3 3 3], 1e-9, 'NIfTI: NIfTI-2 VoxSize');
        checkClose(info.TR, 3, 1e-9, 'NIfTI: NIfTI-2 TR');
        checkClose(info.TimePoints, 12, 0, 'NIfTI: NIfTI-2 TimePoints');
        check(strcmp(info.DatatypeName, 'float64'), 'NIfTI: NIfTI-2 DatatypeName float64');

        % ---- 1.5 大端 NIfTI-1 ----
        f5 = fullfile(niiDir, 'bigendian.nii');
        writeNifti1(f5, [2 2 32 20], [2 2 4 2], 16, 'BigEndian', true);
        info = mrw.NiftiHeader.read(f5);
        check(info.ReadOK, 'NIfTI: big-endian ReadOK');
        checkClose(info.Dim(1:5), [4 2 2 32 20], 0, 'NIfTI: big-endian Dim');
        checkClose(info.TR, 2, 1e-9, 'NIfTI: big-endian TR');

        % ---- 1.6 TR 未知（pixdim(5)=0） -> NaN；3D 时间点为 1 ----
        f6 = fullfile(niiDir, 'notr.nii');
        writeNifti1(f6, [4 4 20], [2 2 2 0], 16);
        info = mrw.NiftiHeader.read(f6);
        check(info.ReadOK && isnan(info.TR), 'NIfTI: TR unknown is NaN');
        checkClose(info.TimePoints, 1, 0, 'NIfTI: 3D TimePoints=1');

        % ---- 1.7 时间单位毫秒（xyzt_units = mm + msec） ----
        f7 = fullfile(niiDir, 'msec.nii');
        writeNifti1(f7, [2 2 32 10], [2 2 4 2000], 16, 'XYZTUnits', 18);
        info = mrw.NiftiHeader.read(f7);
        checkClose(info.TR, 2, 1e-9, 'NIfTI: msec TR converted to seconds');

        % ---- 1.8 体素大小未知（pixdim(2:4)=0） -> NaN ----
        f8 = fullfile(niiDir, 'novox.nii');
        writeNifti1(f8, [4 4 4], [0 0 0 0], 16);
        info = mrw.NiftiHeader.read(f8);
        check(all(isnan(info.VoxSize)), 'NIfTI: unknown voxel size is NaN');

        % ---- 1.9 大端 NIfTI-2 ----
        f9 = fullfile(niiDir, 'nifti2be.nii');
        writeNifti2(f9, [2 2 30 12], [3 3 3 3], 64, 'BigEndian', true);
        info = mrw.NiftiHeader.read(f9);
        check(info.ReadOK && abs(info.TR - 3) < 1e-9, 'NIfTI: big-endian NIfTI-2');

        % ---- 1.10 缺失文件 / 损坏文件：优雅失败 ----
        info = mrw.NiftiHeader.read(fullfile(niiDir, '不存在的文件.nii'));
        check(~info.ReadOK && ~isempty(info.Message) && isAbsPath(info.File), ...
            'NIfTI: missing file fails gracefully');

        fBad = fullfile(niiDir, 'corrupt.nii');
        fid = fopen(fBad, 'w');
        fwrite(fid, uint8(1:100), 'uint8');
        fclose(fid);
        info = mrw.NiftiHeader.read(fBad);
        check(~info.ReadOK && ischar(info.Message) && ~isempty(info.Message), ...
            'NIfTI: corrupt file fails gracefully');

        % ---- 1.11 大写扩展名 + 中文文件名 ----
        f11 = fullfile(niiDir, '静息 像.NII');
        writeNifti1(f11, [2 2 32 20], [2 2 4 2], 16);
        info = mrw.NiftiHeader.read(f11);
        check(info.ReadOK && strcmp(info.Format, 'nii'), 'NIfTI: uppercase extension');
        check(abs(info.TR - 2) < 1e-9, 'NIfTI: Chinese file name readable');

        % ---- 1.12 字段类型 ----
        check(ischar(info.File) && ischar(info.Format) && ischar(info.DatatypeName) && ...
            ischar(info.Message) && islogical(info.ReadOK), 'NIfTI: char/logical field types');
        check(isequal(size(info.Dim), [1 8]) && isequal(size(info.VoxSize), [1 3]), ...
            'NIfTI: Dim/VoxSize shapes');
    end

    % ------------------------------------------------------------------
    % 2. DPARSF 布局
    % ------------------------------------------------------------------
    function sectionDPARSF()
        % ---- (a) DPABI 标准布局（dirFirst）：<root>/FunRaw/<subj>/ ----
        dpRoot = fullfile(tmpRoot, '中文路径 测试', 'DPARSF_标准布局');
        % S01：两个 session，结构像在 T1Raw
        writeNifti1(fullfile(dpRoot, 'FunRaw', 'S01', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(dpRoot, 'S2_FunRaw', 'S01', 'rest2.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(dpRoot, 'T1Raw', 'S01', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        % S02：两个 session，结构像在 AnatRaw
        writeNifti1(fullfile(dpRoot, 'FunRaw', 'S02', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(dpRoot, 'S2_FunRaw', 'S02', 'rest2.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(dpRoot, 'AnatRaw', 'S02', 'T1.nii'), [16 16 32], [1 1 1 0], 4);

        progressLog = makeLog();
        idx = mrw.ScanEngine.scan(dpRoot, struct('ProgressFcn', @(m) appendLog(progressLog, m)));
        check(strcmp(idx.Layout, 'DPARSF'), 'DPARSF: Layout detected');
        check(strcmp(idx.LayoutName, 'DPARSF 标准目录（FunRaw/AnatRaw）'), 'DPARSF: LayoutName');
        check(strcmp(idx.Root, dpRoot) || isAbsPath(idx.Root), 'DPARSF: Root absolute');
        if numel(idx.Subjects) ~= 2
            check(false, 'DPARSF: expected 2 subjects (section aborted)');
            return
        end
        check(numel(idx.Subjects) == 2, 'DPARSF: 2 subjects');
        check(isequal({idx.Subjects.ID}, {'S01', 'S02'}), 'DPARSF: subject IDs sorted');
        s1 = idx.Subjects(1);
        s2 = idx.Subjects(2);
        check(strcmp(s1.Dir, fullfile(dpRoot, 'FunRaw', 'S01')) && ...
            strcmp(s2.Dir, fullfile(dpRoot, 'FunRaw', 'S02')), ...
            'DPARSF: Dir = session1 functional dir');
        check(isequal(s1.FunDirs, {fullfile(dpRoot, 'FunRaw', 'S01'), ...
            fullfile(dpRoot, 'S2_FunRaw', 'S01')}), 'DPARSF: FunDirs session order');
        check(isequal(s2.FunDirs, {fullfile(dpRoot, 'FunRaw', 'S02'), ...
            fullfile(dpRoot, 'S2_FunRaw', 'S02')}), 'DPARSF: FunDirs session 2');
        check(strcmp(s1.AnatDir, fullfile(dpRoot, 'T1Raw', 'S01')), 'DPARSF: T1Raw anat dir');
        check(strcmp(s2.AnatDir, fullfile(dpRoot, 'AnatRaw', 'S02')), 'DPARSF: AnatRaw fallback');
        check(s1.HasAnat && s2.HasAnat && islogical(s1.HasAnat), 'DPARSF: HasAnat logical true');
        check(strcmp(s1.FunType, 'NIfTI') && strcmp(s1.AnatType, 'NIfTI'), 'DPARSF: FunType/AnatType NIfTI');
        checkClose([s1.TimePoints s2.TimePoints], [20 20], 0, 'DPARSF: TimePoints');
        checkClose([s1.TR s2.TR], [2 2], 1e-9, 'DPARSF: TR');
        checkClose([s1.SliceNumber s2.SliceNumber], [32 32], 0, 'DPARSF: SliceNumber');
        checkClose(s1.VoxelSize, [2 2 4], 1e-9, 'DPARSF: VoxelSize');
        check(isequal([s1.Sessions s2.Sessions], [2 2]), 'DPARSF: Sessions');
        check(strcmp(s1.Status, 'ok') && strcmp(s2.Status, 'ok'), 'DPARSF: subject status ok');
        check(s1.FunFileCount == 2 && s2.FunFileCount == 2, 'DPARSF: FunFileCount');
        check(s1.AnatFileCount == 1 && s2.AnatFileCount == 1, 'DPARSF: AnatFileCount');
        det = idx.Detected;
        check(strcmp(det.WorkingDir, dpRoot), 'DPARSF: Detected.WorkingDir');
        check(strcmp(det.StartingDirName, 'FunRaw'), 'DPARSF: Detected.StartingDirName');
        check(det.FunctionalSessionNumber == 2, 'DPARSF: Detected.FunctionalSessionNumber');
        checkClose(det.TR, 2, 1e-9, 'DPARSF: Detected.TR');
        checkClose(det.TimePoints, 20, 0, 'DPARSF: Detected.TimePoints');
        checkClose(det.SliceNumber, 32, 0, 'DPARSF: Detected.SliceNumber');
        check(isequal(det.SubjectIDs, {'S01', 'S02'}), 'DPARSF: Detected.SubjectIDs');
        check(isequal(det.IsBIDS, false) && islogical(det.IsBIDS), 'DPARSF: Detected.IsBIDS false');
        check(progressLog.Count >= 3, 'DPARSF: progress callback called');
        check(idx.Stats.FilesScanned >= 6 && idx.Stats.DirsScanned >= 8, 'DPARSF: Stats counts');
        check(isempty(idx.Errors), 'DPARSF: no errors');
        check(isempty(idx.Warnings), 'DPARSF: no warnings for clean dataset');

        % ---- (b) 受试者优先布局（subjectFirst）：<root>/<subj>/FunRaw/ ----
        sfRoot = fullfile(tmpRoot, 'DPARSF_受试者优先');
        writeNifti1(fullfile(sfRoot, 'A01', 'FunRaw', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(sfRoot, 'A01', 'AnatRaw', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        writeNifti1(fullfile(sfRoot, 'A02', 'FunRaw', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(sfRoot, 'A02', 'S2_FunRaw', 'rest2.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(sfRoot, 'A02', 'T1Raw', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        idx = mrw.ScanEngine.scan(sfRoot);
        check(strcmp(idx.Layout, 'DPARSF'), 'DPARSF(subjectFirst): Layout detected');
        if numel(idx.Subjects) ~= 2
            check(false, 'DPARSF(subjectFirst): expected 2 subjects (section aborted)');
            return
        end
        check(isequal({idx.Subjects.ID}, {'A01', 'A02'}), 'DPARSF(subjectFirst): subject IDs');
        sA = findSubject(idx, 'A01');
        sB = findSubject(idx, 'A02');
        check(~isempty(sA) && strcmp(sA.Dir, fullfile(sfRoot, 'A01', 'FunRaw')), ...
            'DPARSF(subjectFirst): Dir = session1 functional dir');
        check(~isempty(sA) && sA.Sessions == 1, 'DPARSF(subjectFirst): A01 sessions=1');
        check(~isempty(sB) && sB.Sessions == 2, 'DPARSF(subjectFirst): A02 sessions=2');
        check(~isempty(sB) && isequal(sB.FunDirs, {fullfile(sfRoot, 'A02', 'FunRaw'), ...
            fullfile(sfRoot, 'A02', 'S2_FunRaw')}), 'DPARSF(subjectFirst): A02 FunDirs');
        check(~isempty(sA) && strcmp(sA.AnatDir, fullfile(sfRoot, 'A01', 'AnatRaw')), ...
            'DPARSF(subjectFirst): AnatRaw dir');
        check(strcmp(idx.Detected.StartingDirName, 'FunRaw'), 'DPARSF(subjectFirst): StartingDirName');
        check(idx.Detected.FunctionalSessionNumber == 2, ...
            'DPARSF(subjectFirst): Detected sessions = max');
        check(strcmp(idx.Detected.WorkingDir, sfRoot), 'DPARSF(subjectFirst): WorkingDir');

        % ---- (c) 已处理目录 FunImg*（取最短前缀 FunImg） ----
        procRoot = fullfile(tmpRoot, 'DPARSF_已处理');
        writeNifti1(fullfile(procRoot, 'P01', 'FunImg', 'bold.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(procRoot, 'P01', 'FunImgARW', 'bold.nii'), [2 2 32 20], [2 2 4 2], 16);
        idx = mrw.ScanEngine.scan(procRoot);
        check(strcmp(idx.Layout, 'DPARSF'), 'DPARSF(processed): Layout detected');
        check(strcmp(idx.Detected.StartingDirName, 'FunImg'), ...
            'DPARSF(processed): shortest prefix FunImg chosen');
        check(isscalar(idx.Subjects) && idx.Subjects(1).Sessions == 1, ...
            'DPARSF(processed): 1 subject 1 session');
        check(isscalar(idx.Subjects) && isequal(idx.Subjects(1).FunDirs, ...
            {fullfile(procRoot, 'P01', 'FunImg')}), 'DPARSF(processed): FunDirs = FunImg');

        % ---- (d) 只有 FunImgARW 时使用实际名 ----
        procRoot2 = fullfile(tmpRoot, 'DPARSF_仅ARW');
        writeNifti1(fullfile(procRoot2, 'P02', 'FunImgARW', 'bold.nii'), [2 2 32 20], [2 2 4 2], 16);
        idx = mrw.ScanEngine.scan(procRoot2);
        check(strcmp(idx.Detected.StartingDirName, 'FunImgARW'), ...
            'DPARSF(processed): actual name FunImgARW');
    end

    % ------------------------------------------------------------------
    % 3. 扫描根目录本身就是 DPARSF 功能像目录（续跑模式）
    % ------------------------------------------------------------------
    function sectionRootModal()
        % ---- (a) 根目录 = 已处理阶段目录 FunImgARB ----
        wd = fullfile(tmpRoot, '中文路径 测试', '续跑工作目录');
        stage = fullfile(wd, 'FunImgARB');
        writeNifti1(fullfile(stage, 'S01', 'S01_4DVolume.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(stage, 'S02', 'S02_4DVolume.nii'), [2 2 32 20], [2 2 4 2.0000014], 16);
        writeNifti1(fullfile(wd, 'T1Img', 'S01', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        writeNifti1(fullfile(wd, 'T1Img', 'S02', 'T1.nii'), [16 16 32], [1 1 1 0], 4);

        idx = mrw.ScanEngine.scan(stage);
        check(strcmp(idx.Layout, 'DPARSF'), 'RootModal(FunImgARB): Layout DPARSF');
        check(strcmp(idx.LayoutName, 'DPARSF 已处理阶段目录（FunImgARB，续跑模式）'), ...
            'RootModal(FunImgARB): LayoutName');
        if numel(idx.Subjects) ~= 2
            check(false, 'RootModal(FunImgARB): expected 2 subjects (section aborted)');
            return
        end
        check(numel(idx.Subjects) == 2, 'RootModal(FunImgARB): 2 subjects');
        check(isequal({idx.Subjects.ID}, {'S01', 'S02'}), 'RootModal(FunImgARB): subject IDs');
        det = idx.Detected;
        check(strcmp(det.WorkingDir, wd), 'RootModal(FunImgARB): WorkingDir = parent');
        check(strcmp(det.StartingDirName, 'FunImgARB'), 'RootModal(FunImgARB): StartingDirName');
        check(det.FunctionalSessionNumber == 1, 'RootModal(FunImgARB): sessions=1');
        checkClose([det.TR det.TimePoints det.SliceNumber], [2 20 32], 1e-9, ...
            'RootModal(FunImgARB): Detected TR/TP/Slice');
        check(isequal(det.SubjectIDs, {'S01', 'S02'}), 'RootModal(FunImgARB): Detected SubjectIDs');
        s1 = findSubject(idx, 'S01');
        check(~isempty(s1), 'RootModal(FunImgARB): S01 found');
        check(strcmp(s1.Dir, fullfile(stage, 'S01')) && ...
            isequal(s1.FunDirs, {fullfile(stage, 'S01')}), ...
            'RootModal(FunImgARB): Dir/FunDirs');
        check(strcmp(s1.FunType, 'NIfTI'), 'RootModal(FunImgARB): FunType NIfTI');
        checkClose([s1.TR s1.TimePoints s1.SliceNumber], [2 20 32], 1e-9, ...
            'RootModal(FunImgARB): S01 header values');
        check(strcmp(s1.AnatDir, fullfile(wd, 'T1Img', 'S01')), ...
            'RootModal(FunImgARB): anat from sibling T1Img');
        check(s1.HasAnat && s1.AnatFileCount == 1 && strcmp(s1.AnatType, 'NIfTI'), ...
            'RootModal(FunImgARB): anat counted');
        check(strcmp(s1.Status, 'ok'), 'RootModal(FunImgARB): status ok');
        s2 = findSubject(idx, 'S02');
        check(~isempty(s2) && s2.TR == 2, ...
            'RootModal(FunImgARB): TR rounded to 2 (no float32 noise)');
        check(any(hasMsg(idx.Warnings, '续跑')), 'RootModal(FunImgARB): continue-mode warning');
        check(isempty(idx.Errors), 'RootModal(FunImgARB): no errors');

        % ---- (b) 根目录 = 原始功能像目录 FunRaw（假 DICOM） ----
        rawWd = fullfile(tmpRoot, '原始工作目录');
        writeFakeDicom(fullfile(rawWd, 'FunRaw', 'R01'), 'I', 5);
        writeFakeDicom(fullfile(rawWd, 'FunRaw', 'R02'), 'I', 5);
        writeNifti1(fullfile(rawWd, 'T1Raw', 'R01', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        writeNifti1(fullfile(rawWd, 'T1Raw', 'R02', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        idx = mrw.ScanEngine.scan(fullfile(rawWd, 'FunRaw'));
        check(strcmp(idx.Layout, 'DPARSF'), 'RootModal(FunRaw): Layout DPARSF');
        check(strcmp(idx.LayoutName, 'DPARSF 功能像原始目录（FunRaw）'), ...
            'RootModal(FunRaw): LayoutName');
        check(strcmp(idx.Detected.WorkingDir, rawWd), 'RootModal(FunRaw): WorkingDir = parent');
        check(strcmp(idx.Detected.StartingDirName, 'FunRaw'), ...
            'RootModal(FunRaw): StartingDirName FunRaw');
        check(isequal(sort({idx.Subjects.ID}), {'R01', 'R02'}), 'RootModal(FunRaw): subjects');
        r1 = findSubject(idx, 'R01');
        check(~isempty(r1) && strcmp(r1.AnatDir, fullfile(rawWd, 'T1Raw', 'R01')), ...
            'RootModal(FunRaw): anat noted');
        check(~isempty(r1) && strcmp(r1.FunType, 'DICOM'), 'RootModal(FunRaw): FunType DICOM');

        % ---- (c) 防护：根目录名恰好像 FunImg，但实际是工作目录 ----
        weirdWd = fullfile(tmpRoot, '名字像阶段目录的工作目录', 'FunImg');
        writeNifti1(fullfile(weirdWd, 'FunRaw', 'W01', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(weirdWd, 'T1Raw', 'W01', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        idx = mrw.ScanEngine.scan(weirdWd);
        check(strcmp(idx.Layout, 'DPARSF'), 'RootModal(guard): Layout DPARSF');
        check(strcmp(idx.LayoutName, 'DPARSF 标准目录（FunRaw/AnatRaw）'), ...
            'RootModal(guard): standard LayoutName');
        check(strcmp(idx.Detected.WorkingDir, weirdWd), ...
            'RootModal(guard): WorkingDir = scanned root');
        check(strcmp(idx.Detected.StartingDirName, 'FunRaw'), ...
            'RootModal(guard): StartingDirName FunRaw');
        check(isequal({idx.Subjects.ID}, {'W01'}), 'RootModal(guard): subject W01');

        % ---- (d) 回归：扫描上级工作目录仍按 dirFirst 工作 ----
        idx = mrw.ScanEngine.scan(wd);
        check(strcmp(idx.Layout, 'DPARSF'), 'RootModal(workdir): Layout DPARSF');
        check(strcmp(idx.Detected.WorkingDir, wd), 'RootModal(workdir): WorkingDir = wd');
        check(strcmp(idx.Detected.StartingDirName, 'FunImgARB'), ...
            'RootModal(workdir): StartingDirName FunImgARB');
        check(numel(idx.Subjects) == 2, 'RootModal(workdir): 2 subjects');
        checkClose(idx.Detected.TR, 2, 1e-9, 'RootModal(workdir): TR from stage NIfTI');
    end

    % ------------------------------------------------------------------
    % 3. BIDS 布局
    % ------------------------------------------------------------------
    function sectionBIDS()
        % DPARSFA 的 BIDS 约定：<WorkingDir>/BIDS/sub-*/...
        bidsWork = fullfile(tmpRoot, 'BIDS工作目录');
        bidsRoot = fullfile(bidsWork, 'BIDS');
        writeTextFile(fullfile(bidsRoot, 'dataset_description.json'), '{"Name":"mrw test"}');
        % sub-001：ses-01，JSON sidecar TR=2.5（NIfTI 头里故意写 2.0，验证 JSON 优先）
        bold1 = fullfile(bidsRoot, 'sub-001', 'ses-01', 'func', ...
            'sub-001_ses-01_task-rest_bold.nii');
        writeNifti1(bold1, [2 2 32 20], [2 2 4 2], 16);
        makeGzFile(bold1);
        writeTextFile(fullfile(bidsRoot, 'sub-001', 'ses-01', 'func', ...
            'sub-001_ses-01_task-rest_bold.json'), '{"RepetitionTime": 2.5}');
        writeNifti1(fullfile(bidsRoot, 'sub-001', 'ses-01', 'anat', ...
            'sub-001_ses-01_T1w.nii'), [16 16 40], [1 1 1 0], 4);
        % sub-002：无 ses-* 目录，无 JSON -> TR 取自 NIfTI 头
        writeNifti1(fullfile(bidsRoot, 'sub-002', 'func', ...
            'sub-002_task-rest_bold.nii'), [2 2 32 20], [2 2 4 2.5], 16);
        writeNifti1(fullfile(bidsRoot, 'sub-002', 'anat', ...
            'sub-002_T1w.nii'), [16 16 40], [1 1 1 0], 4);
        % sub-003：JSON 损坏 -> TR 回退 NIfTI 头（2.2）
        writeNifti1(fullfile(bidsRoot, 'sub-003', 'func', ...
            'sub-003_task-rest_bold.nii'), [2 2 32 20], [2 2 4 2.2], 16);
        writeTextFile(fullfile(bidsRoot, 'sub-003', 'func', ...
            'sub-003_task-rest_bold.json'), '{ this is not valid json');
        writeNifti1(fullfile(bidsRoot, 'sub-003', 'anat', ...
            'sub-003_T1w.nii'), [16 16 40], [1 1 1 0], 4);

        idx = mrw.ScanEngine.scan(bidsWork);
        check(strcmp(idx.Layout, 'BIDS'), 'BIDS: Layout detected');
        check(~isempty(regexp(idx.LayoutName, 'BIDS', 'once')), 'BIDS: LayoutName');
        check(strcmp(idx.Detected.WorkingDir, bidsWork), ...
            'BIDS: Detected.WorkingDir = parent of BIDS dir');
        check(isequal(idx.Detected.IsBIDS, true) && islogical(idx.Detected.IsBIDS), ...
            'BIDS: Detected.IsBIDS true');
        if numel(idx.Subjects) ~= 3
            check(false, 'BIDS: expected 3 subjects (section aborted)');
            return
        end
        check(numel(idx.Subjects) == 3, 'BIDS: 3 subjects');
        check(isequal({idx.Subjects.ID}, {'sub-001', 'sub-002', 'sub-003'}), 'BIDS: subject IDs');
        s1 = findSubject(idx, 'sub-001');
        s2 = findSubject(idx, 'sub-002');
        s3 = findSubject(idx, 'sub-003');
        check(~isempty(s1) && strcmp(s1.FunType, 'BIDS'), 'BIDS: FunType BIDS');
        check(~isempty(s1) && strcmp(s1.AnatType, 'BIDS') && s1.HasAnat, 'BIDS: AnatType BIDS');
        check(~isempty(s1) && isequal(s1.FunDirs, ...
            {fullfile(bidsRoot, 'sub-001', 'ses-01', 'func')}), 'BIDS: FunDirs func dir');
        check(~isempty(s1) && isequal(s1.AnatDir, ...
            fullfile(bidsRoot, 'sub-001', 'ses-01', 'anat')), 'BIDS: AnatDir anat dir');
        checkClose(s1.TR, 2.5, 1e-9, 'BIDS: TR from JSON sidecar priority');
        checkClose([s1.TimePoints s2.TimePoints s3.TimePoints], [20 20 20], 0, 'BIDS: TimePoints');
        checkClose([s1.SliceNumber s2.SliceNumber s3.SliceNumber], [32 32 32], 0, 'BIDS: SliceNumber');
        checkClose(s2.TR, 2.5, 1e-9, 'BIDS: TR from NIfTI header when JSON missing');
        check(hasMsg(s2.Messages, 'JSON'), 'BIDS: message about missing JSON');
        checkClose(s3.TR, 2.2, 1e-6, 'BIDS: TR fallback when JSON corrupt');
        check(hasMsg(s3.Messages, 'JSON'), 'BIDS: message about corrupt JSON');
        check(~isempty(s1) && s1.Sessions == 1 && ~isempty(s2) && s2.Sessions == 1, 'BIDS: Sessions');
        check(~isempty(s1) && s1.FunFileCount == 1, 'BIDS: FunFileCount bold only');
        check(~isempty(idx.Warnings), 'BIDS: inconsistent TR warning');
        check(strcmp(idx.Detected.StartingDirName, 'FunRaw'), 'BIDS: Detected.StartingDirName default');
        check(idx.Detected.FunctionalSessionNumber == 1, 'BIDS: Detected sessions');
        checkClose(idx.Detected.TR, 2.5, 1e-9, 'BIDS: Detected.TR first subject');
        check(isequal(idx.Detected.SubjectIDs, {idx.Subjects.ID}), 'BIDS: Detected.SubjectIDs');
        check(strcmp(s1.Status, 'ok'), 'BIDS: subject status ok');
        check(idx.Stats.FilesScanned >= 9, 'BIDS: Stats.FilesScanned');

        % ---- 扫描根本身就是 BIDS 数据集根（非标准命名）----
        directBids = fullfile(tmpRoot, 'BIDS直接根');
        writeNifti1(fullfile(directBids, 'sub-004', 'func', ...
            'sub-004_task-rest_bold.nii'), [2 2 32 20], [2 2 4 2.5], 16);
        idxDirect = mrw.ScanEngine.scan(directBids);
        check(strcmp(idxDirect.Layout, 'BIDS') && isscalar(idxDirect.Subjects), ...
            'BIDS: scan root itself is BIDS dataset');
        check(strcmp(idxDirect.Detected.WorkingDir, tmpRoot), ...
            'BIDS: root-level BIDS WorkingDir = parent');
        check(isequal(idxDirect.Detected.IsBIDS, true), 'BIDS: root-level IsBIDS true');
        check(hasMsg(idxDirect.Warnings, 'BIDS'), 'BIDS: warning about BIDS dir naming');
    end

    % ------------------------------------------------------------------
    % 4. 通用 NIfTI 布局
    % ------------------------------------------------------------------
    function sectionNiftiGeneric()
        niiRoot = fullfile(tmpRoot, '通用NIfTI');
        writeNifti1(fullfile(niiRoot, '受试者甲', '静息态.nii'), [2 2 30 15], [3 3 4 3], 16);
        writeNifti1(fullfile(niiRoot, '受试者甲', 'T1.nii'), [16 16 40], [1 1 1 0], 4);
        writeNifti1(fullfile(niiRoot, '受试者乙', 'rest.nii'), [2 2 30 15], [3 3 4 3], 16);

        idx = mrw.ScanEngine.scan(niiRoot);
        check(strcmp(idx.Layout, 'NIFTI'), 'NIfTI: Layout detected');
        check(~isempty(regexp(idx.LayoutName, 'NIfTI', 'once')), 'NIfTI: LayoutName');
        if numel(idx.Subjects) ~= 2
            check(false, 'NIfTI: expected 2 subjects (section aborted)');
            return
        end
        check(numel(idx.Subjects) == 2, 'NIfTI: 2 subjects');
        sA = findSubject(idx, '受试者甲');
        sB = findSubject(idx, '受试者乙');
        check(~isempty(sA) && ~isempty(sB), 'NIfTI: Chinese subject IDs');
        check(~isempty(sA) && strcmp(sA.FunType, 'NIfTI'), 'NIfTI: FunType NIfTI');
        check(~isempty(sA) && sA.HasAnat && strcmp(sA.AnatDir, fullfile(niiRoot, '受试者甲')), ...
            'NIfTI: anat found in subject dir');
        check(~isempty(sA) && sA.AnatFileCount == 1, 'NIfTI: AnatFileCount only T1-like');
        checkClose(sA.TR, 3, 1e-9, 'NIfTI: TR');
        checkClose(sA.TimePoints, 15, 0, 'NIfTI: TimePoints');
        checkClose(sA.SliceNumber, 30, 0, 'NIfTI: SliceNumber');
        checkClose(sA.VoxelSize, [3 3 4], 1e-9, 'NIfTI: VoxelSize');
        check(~isempty(sA) && sA.Sessions == 1 && strcmp(sA.Status, 'ok'), 'NIfTI: subject ok');
        check(~isempty(sB) && ~sB.HasAnat && strcmp(sB.Status, 'warn'), ...
            'NIfTI: missing anat -> warn');
        check(~isempty(sB) && hasMsg(sB.Messages, '结构像'), 'NIfTI: missing anat message');
        check(strcmp(idx.Detected.WorkingDir, niiRoot), 'NIfTI: Detected.WorkingDir');
        checkClose(idx.Detected.TR, 3, 1e-9, 'NIfTI: Detected.TR');
        checkClose(idx.Detected.TimePoints, 15, 0, 'NIfTI: Detected.TimePoints');
        checkClose(idx.Detected.SliceNumber, 30, 0, 'NIfTI: Detected.SliceNumber');
        check(idx.Detected.FunctionalSessionNumber == 1, 'NIfTI: Detected sessions');
        check(numel(idx.Detected.SubjectIDs) == 2, 'NIfTI: Detected.SubjectIDs');
        check(isequal(idx.Detected.IsBIDS, false), 'NIfTI: Detected.IsBIDS false');
        check(hasMsg(idx.Warnings, 'DPARSF'), 'NIfTI: warning to reorganize into FunRaw layout');

        % IncludeNIfTI=false 时不再识别通用 NIfTI 布局
        idx2 = mrw.ScanEngine.scan(niiRoot, struct('IncludeNIfTI', false));
        check(strcmp(idx2.Layout, 'UNKNOWN') && numel(idx2.Subjects) == 0, ...
            'NIfTI: IncludeNIfTI=false disables layout');
    end

    % ------------------------------------------------------------------
    % 5. DICOM 布局（假 .dcm 文件，验证计数与容错降级）
    % ------------------------------------------------------------------
    function sectionDicom()
        dcmRoot = fullfile(tmpRoot, 'DICOM数据');
        writeFakeDicom(fullfile(dcmRoot, '受试者D', '功能序列'), 'IM', 120);
        writeFakeDicom(fullfile(dcmRoot, '受试者D', 'T1序列'), 'T1', 40);

        idx = mrw.ScanEngine.scan(dcmRoot);
        check(strcmp(idx.Layout, 'DICOM'), 'DICOM: Layout detected');
        check(~isempty(regexp(idx.LayoutName, 'DICOM', 'once')), 'DICOM: LayoutName');
        if numel(idx.Subjects) ~= 1
            check(false, 'DICOM: expected 1 subject (section aborted)');
            return
        end
        s = idx.Subjects(1);
        check(strcmp(s.ID, '受试者D'), 'DICOM: subject ID');
        check(strcmp(s.FunType, 'DICOM'), 'DICOM: FunType');
        check(s.FunFileCount == 120, 'DICOM: FunFileCount = slice count');
        check(strcmp(s.AnatType, 'DICOM') && s.HasAnat, 'DICOM: AnatType + HasAnat');
        check(s.AnatFileCount == 40, 'DICOM: AnatFileCount');
        check(s.Sessions == 1, 'DICOM: Sessions');
        check(isnan(s.TR), 'DICOM: TR unknown is NaN');
        check(isnan(s.TimePoints), 'DICOM: TimePoints unknown is NaN');
        check(isnan(s.SliceNumber), 'DICOM: SliceNumber unknown is NaN');
        check(all(isnan(s.VoxelSize)), 'DICOM: VoxelSize NaN');
        check(strcmp(s.Status, 'warn'), 'DICOM: status warn');
        check(hasMsg(s.Messages, 'DICOM'), 'DICOM: parse failure message');
        check(isnan(idx.Detected.TR) && isnan(idx.Detected.TimePoints) && ...
            isnan(idx.Detected.SliceNumber), 'DICOM: Detected NaN values');
        check(isequal(idx.Detected.SubjectIDs, {'受试者D'}), 'DICOM: Detected.SubjectIDs');
        check(strcmp(idx.Detected.WorkingDir, dcmRoot), 'DICOM: Detected.WorkingDir');
        check(isequal(idx.Detected.IsBIDS, false), 'DICOM: Detected.IsBIDS false');

        % IncludeDICOM=false：DICOM 数据被忽略
        idx2 = mrw.ScanEngine.scan(dcmRoot, struct('IncludeDICOM', false));
        check(strcmp(idx2.Layout, 'UNKNOWN') && numel(idx2.Subjects) == 0, ...
            'DICOM: IncludeDICOM=false disables layout');
        check(~isempty(idx2.Warnings), 'DICOM: warning when no layout recognized');

        % DPARSF 布局内的 DICOM 数据
        dcmDpRoot = fullfile(tmpRoot, 'DPARSF_DICOM');
        writeFakeDicom(fullfile(dcmDpRoot, 'S01', 'FunRaw'), 'f', 80);
        writeFakeDicom(fullfile(dcmDpRoot, 'S01', 'T1Raw'), 't', 20);
        idx3 = mrw.ScanEngine.scan(dcmDpRoot);
        check(strcmp(idx3.Layout, 'DPARSF'), 'DICOM-DPARSF: Layout detected');
        if numel(idx3.Subjects) ~= 1
            check(false, 'DICOM-DPARSF: expected 1 subject (section aborted)');
            return
        end
        s3 = idx3.Subjects(1);
        check(strcmp(s3.FunType, 'DICOM') && strcmp(s3.AnatType, 'DICOM'), ...
            'DICOM-DPARSF: types');
        check(s3.FunFileCount == 80 && s3.AnatFileCount == 20, 'DICOM-DPARSF: file counts');
        check(isnan(s3.TR) && isnan(s3.TimePoints), 'DICOM-DPARSF: unknown TR/TP NaN');
        check(strcmp(s3.Status, 'warn'), 'DICOM-DPARSF: status warn');
    end

    % ------------------------------------------------------------------
    % 6. 混合格式、扫描深度、参数容错
    % ------------------------------------------------------------------
    function sectionMixedDepthOptions()
        % ---- (a) MIXED：同一受试者目录混有 NIfTI 与 DICOM ----
        mixRoot = fullfile(tmpRoot, '混合格式');
        writeNifti1(fullfile(mixRoot, '受试者E', 'rest.nii'), [2 2 30 15], [3 3 4 3], 16);
        writeFakeDicom(fullfile(mixRoot, '受试者E'), 'IM', 30);
        idx = mrw.ScanEngine.scan(mixRoot);
        check(strcmp(idx.Layout, 'MIXED'), 'MIXED: Layout detected');
        if numel(idx.Subjects) ~= 1
            check(false, 'MIXED: expected 1 subject (section aborted)');
            return
        end
        s = idx.Subjects(1);
        check(strcmp(s.FunType, 'MIXED'), 'MIXED: FunType MIXED');
        check(s.FunFileCount == 31, 'MIXED: FunFileCount = nii + dcm');
        checkClose(s.TR, 3, 1e-9, 'MIXED: TR from NIfTI');
        checkClose(s.TimePoints, 15, 0, 'MIXED: TimePoints from NIfTI');
        check(strcmp(s.Status, 'warn') && hasMsg(s.Messages, '结构像'), ...
            'MIXED: missing anat warning');

        % ---- (b) MaxDepth 限制 ----
        depthRoot = fullfile(tmpRoot, '深度限制');
        writeNifti1(fullfile(depthRoot, '受试者', '深1', '深2', 'rest.nii'), ...
            [2 2 30 15], [3 3 4 3], 16);
        idxDeep = mrw.ScanEngine.scan(depthRoot);
        check(isscalar(idxDeep.Subjects) && strcmp(idxDeep.Subjects(1).ID, '深1'), ...
            'Depth: default MaxDepth finds nested subject');
        idxShallow = mrw.ScanEngine.scan(depthRoot, struct('MaxDepth', 2));
        check(strcmp(idxShallow.Layout, 'UNKNOWN') && numel(idxShallow.Subjects) == 0, ...
            'Depth: MaxDepth=2 excludes deeper data');
        check(idxShallow.Stats.DirsScanned == 3, 'Depth: DirsScanned limited by MaxDepth');

        % ---- (c) 非法/未知 opts 字段被容忍；进度回调抛错不影响扫描 ----
        dpRoot = fullfile(tmpRoot, '中文路径 测试', 'DPARSF_标准布局');
        idxOpt = mrw.ScanEngine.scan(dpRoot, struct('MaxDepth', 'bad', 'UnknownField', 1));
        check(strcmp(idxOpt.Layout, 'DPARSF') && numel(idxOpt.Subjects) == 2, ...
            'Options: invalid/unknown fields tolerated');
        idxBoom = mrw.ScanEngine.scan(dpRoot, ...
            struct('ProgressFcn', @(m) error('mrw:test', 'progress callback error')));
        check(strcmp(idxBoom.Layout, 'DPARSF') && numel(idxBoom.Subjects) == 2 && ...
            isempty(idxBoom.Errors), 'Options: throwing ProgressFcn ignored');
        idxNoOpts = mrw.ScanEngine.scan(dpRoot);
        check(numel(idxNoOpts.Subjects) == 2, 'Options: opts omitted works');
    end

    % ------------------------------------------------------------------
    % 7. 性能：含 1200 个文件的目录
    % ------------------------------------------------------------------
    function sectionPerformance()
        bigRoot = fullfile(tmpRoot, '大目录性能');
        bigDir = fullfile(bigRoot, '受试者大', '功能序列');
        writeFakeDicom(bigDir, 'IM', 1200);
        idx = mrw.ScanEngine.scan(bigRoot);
        check(strcmp(idx.Layout, 'DICOM'), 'Perf: layout DICOM');
        check(idx.Stats.FilesScanned >= 1200, 'Perf: FilesScanned >= 1200');
        check(idx.Stats.DirsScanned >= 3, 'Perf: DirsScanned');
        check(idx.Stats.Elapsed < 10, 'Perf: elapsed < 10s');
        check(idx.Stats.Elapsed > 0, 'Perf: elapsed positive');
        check(isscalar(idx.Subjects) && idx.Subjects(1).FunFileCount == 1200, ...
            'Perf: subject file count');
        fprintf('  (perf info: %d files / %d dirs, scan elapsed %.3f s)\n', ...
            idx.Stats.FilesScanned, idx.Stats.DirsScanned, idx.Stats.Elapsed);
    end

    % ------------------------------------------------------------------
    % 8. 接口契约与边界情况
    % ------------------------------------------------------------------
    function sectionInterface()
        dpRoot = fullfile(tmpRoot, '中文路径 测试', 'DPARSF_标准布局');
        idx = mrw.ScanEngine.scan(dpRoot);

        expectedTop = {'Root', 'Layout', 'LayoutName', 'Subjects', 'Detected', ...
            'Warnings', 'Errors', 'Stats'};
        expectedSubj = {'ID', 'Dir', 'FunDirs', 'AnatDir', 'FunType', 'AnatType', ...
            'FunFileCount', 'AnatFileCount', 'TimePoints', 'TR', 'SliceNumber', ...
            'VoxelSize', 'Sessions', 'HasAnat', 'Status', 'Messages'};
        expectedDet = {'WorkingDir', 'StartingDirName', 'FunctionalSessionNumber', ...
            'TR', 'TimePoints', 'SliceNumber', 'SubjectIDs', 'IsBIDS'};
        expectedStats = {'Elapsed', 'DirsScanned', 'FilesScanned'};

        check(isequal(fieldnames(idx), expectedTop(:)), 'Contract: idx fields and order');
        check(isequal(fieldnames(idx.Subjects), expectedSubj(:)), ...
            'Contract: Subject fields and order');
        check(isequal(fieldnames(idx.Detected), expectedDet(:)), ...
            'Contract: Detected fields and order');
        check(isequal(fieldnames(idx.Stats), expectedStats(:)), ...
            'Contract: Stats fields and order');
        check(ischar(idx.Root) && ischar(idx.Layout) && ischar(idx.LayoutName), ...
            'Contract: char fields');
        check(isstruct(idx.Subjects) && isstruct(idx.Detected) && isstruct(idx.Stats), ...
            'Contract: struct fields');
        check(iscell(idx.Warnings) && iscell(idx.Errors), 'Contract: cell warnings/errors');
        check(any(strcmp(idx.Layout, {'DPARSF', 'BIDS', 'NIFTI', 'DICOM', 'MIXED', 'UNKNOWN'})), ...
            'Contract: Layout enum');
        s = idx.Subjects(1);
        check(ischar(s.ID) && ischar(s.Dir) && ischar(s.AnatDir) && ...
            ischar(s.FunType) && ischar(s.AnatType), 'Contract: subject char fields');
        check(iscell(s.FunDirs) && iscell(s.Messages), 'Contract: subject cell fields');
        check(isnumeric(s.FunFileCount) && isnumeric(s.AnatFileCount) && ...
            isnumeric(s.Sessions) && isnumeric(s.TimePoints) && isnumeric(s.TR) && ...
            isnumeric(s.SliceNumber), 'Contract: subject numeric fields');
        check(isequal(size(s.VoxelSize), [1 3]) && isnumeric(s.VoxelSize), ...
            'Contract: VoxelSize 1x3 double');
        check(islogical(s.HasAnat), 'Contract: HasAnat logical');
        check(any(strcmp(s.Status, {'ok', 'warn', 'error'})), 'Contract: Status enum');
        check(isnumeric(idx.Detected.FunctionalSessionNumber) && ...
            isnumeric(idx.Detected.TR) && isnumeric(idx.Detected.TimePoints) && ...
            isnumeric(idx.Detected.SliceNumber), 'Contract: Detected numeric fields');
        check(iscellstr(idx.Detected.SubjectIDs), 'Contract: Detected.SubjectIDs cellstr');
        check(ischar(idx.Detected.WorkingDir) && ischar(idx.Detected.StartingDirName), ...
            'Contract: Detected char fields');
        check(islogical(idx.Detected.IsBIDS), 'Contract: Detected.IsBIDS logical');
        check(isnumeric(idx.Stats.Elapsed) && isnumeric(idx.Stats.DirsScanned) && ...
            isnumeric(idx.Stats.FilesScanned), 'Contract: Stats numeric');

        % ---- 缺失根目录 ----
        idxMissing = mrw.ScanEngine.scan(fullfile(tmpRoot, '不存在的目录'));
        check(strcmp(idxMissing.Layout, 'UNKNOWN'), 'Edge: missing root -> UNKNOWN');
        check(~isempty(idxMissing.Errors), 'Edge: missing root -> Errors');
        check(numel(idxMissing.Subjects) == 0, 'Edge: missing root -> no subjects');
        check(isequal(fieldnames(idxMissing), expectedTop(:)), 'Edge: missing root fields intact');
        check(idxMissing.Detected.FunctionalSessionNumber == 1 && ...
            isnan(idxMissing.Detected.TR) && isequal(idxMissing.Detected.IsBIDS, false), ...
            'Edge: missing root Detected defaults');

        % ---- 空目录 ----
        emptyRoot = fullfile(tmpRoot, '空目录');
        mkdir(emptyRoot);
        idxEmpty = mrw.ScanEngine.scan(emptyRoot);
        check(strcmp(idxEmpty.Layout, 'UNKNOWN') && numel(idxEmpty.Subjects) == 0, ...
            'Edge: empty dir -> UNKNOWN no subjects');
        check(~isempty(idxEmpty.Warnings) && isempty(idxEmpty.Errors), ...
            'Edge: empty dir -> warning only');

        % ---- 根目录本身是受试者目录（<root>/FunRaw/<files>）----
        singleRoot = fullfile(tmpRoot, '单个受试者目录', 'S99');
        writeNifti1(fullfile(singleRoot, 'FunRaw', 'rest.nii'), [2 2 32 20], [2 2 4 2], 16);
        writeNifti1(fullfile(singleRoot, 'T1Raw', 'T1.nii'), [16 16 32], [1 1 1 0], 4);
        idxSingle = mrw.ScanEngine.scan(singleRoot);
        check(strcmp(idxSingle.Layout, 'DPARSF') && isscalar(idxSingle.Subjects), ...
            'Edge: root is subject dir -> DPARSF');
        check(isscalar(idxSingle.Subjects) && strcmp(idxSingle.Subjects(1).ID, 'S99'), ...
            'Edge: root is subject dir -> ID is root name');
        check(isscalar(idxSingle.Subjects) && strcmp(idxSingle.Subjects(1).Dir, ...
            fullfile(singleRoot, 'FunRaw')), 'Edge: root is subject dir -> Dir = FunRaw');
        check(strcmp(idxSingle.Detected.WorkingDir, fileparts(singleRoot)), ...
            'Edge: root is subject dir -> WorkingDir = parent');
        check(strcmp(idxSingle.Detected.StartingDirName, 'FunRaw'), ...
            'Edge: root is subject dir -> StartingDirName');
        check(isscalar(idxSingle.Subjects) && hasMsg(idxSingle.Subjects(1).Messages, 'WorkingDir'), ...
            'Edge: root is subject dir -> warning about WorkingDir');
    end
end

% ======================================================================
% 本地工具函数
% ======================================================================
function safeRemoveDir(p)
%SAFEREMOVEDIR 静默删除临时目录
if isempty(p) || exist(p, 'dir') ~= 7
    return
end
try
    rmdir(p, 's');
catch
    % 清理失败不影响测试结果
end
end

function tf = isAbsPath(p)
%ISABSPATH 判断是否绝对路径（Windows 盘符 / UNC / POSIX 根）
if ~ischar(p) || isempty(p)
    tf = false;
    return
end
tf = (numel(p) >= 2 && p(2) == ':') || p(1) == filesep || p(1) == '/';
end

function log = makeLog()
%MAKELOG 创建用于收集进度消息的句柄容器
log = containers.Map('KeyType', 'double', 'ValueType', 'any');
end

function log = appendLog(log, msg)
%APPENDLOG 向句柄容器追加一条消息（供匿名回调使用）
log(log.Count + 1) = msg;
end

function s = findSubject(idx, id)
%FINDSUBJECT 按 ID 查找受试者，找不到返回空
s = [];
for k = 1:numel(idx.Subjects)
    if strcmp(idx.Subjects(k).ID, id)
        s = idx.Subjects(k);
        return
    end
end
end

function tf = hasMsg(msgs, pattern)
%HASMSG 判断中文提示 cell 中是否有匹配正则的条目
tf = false;
if isempty(msgs) || ~iscell(msgs)
    return
end
for k = 1:numel(msgs)
    if ischar(msgs{k}) && ~isempty(regexp(msgs{k}, pattern, 'once', 'ignorecase'))
        tf = true;
        return
    end
end
end

function writeTextFile(filePath, content)
%WRITETEXTFILE 写入文本文件（自动创建父目录）
folder = fileparts(filePath);
if ~isempty(folder) && ~exist(folder, 'dir')
    mkdir(folder);
end
fid = fopen(filePath, 'w');
if fid < 0
    error('无法写入测试文本文件：%s', filePath);
end
fprintf(fid, '%s', content);
fclose(fid);
end

function writeFakeDicom(dirPath, prefix, n)
%WRITEFAKE DICOM 生成 n 个假 .dcm 文件（内容非 DICOM，用于测试计数与容错）
if ~exist(dirPath, 'dir')
    mkdir(dirPath);
end
payload = uint8(repmat([0 1 2 3 4 5 6 7], 1, 16)); % 128 字节
for k = 1:n
    fid = fopen(fullfile(dirPath, sprintf('%s%04d.dcm', prefix, k)), 'w');
    if fid >= 0
        fwrite(fid, payload, 'uint8');
        fclose(fid);
    end
end
end

function writeNifti1(filePath, dims, pixdim, datatypeCode, varargin)
%WRITENIFTI1 生成用于测试的最小 NIfTI-1 文件（.nii 或 .hdr）
%   dims        1xN 图像尺寸
%   pixdim      1xN 体素大小(mm)，第 4 个元素为 TR（秒）
%   datatypeCode NIfTI 数据类型码
%   名值对：'BigEndian'、'XYZTUnits'、'Magic'、'WriteData'（默认 true）
p = struct('BigEndian', false, 'XYZTUnits', 10, 'Magic', 'n+1', 'WriteData', true);
for k = 1:2:numel(varargin)
    p.(varargin{k}) = varargin{k + 1};
end
be = logical(p.BigEndian);
if ~exist(fileparts(filePath), 'dir')
    mkdir(fileparts(filePath));
end
h = zeros(1, 348, 'uint8');
h(1:4) = intBytes(348, 'int32', be);
dim8 = padVector([numel(dims), dims(:).'], 8, 1);
h(41:56) = intBytes(dim8, 'int16', be);
h(71:72) = intBytes(datatypeCode, 'int16', be);
h(73:74) = intBytes(bitpixFor(datatypeCode), 'int16', be);
pd8 = padVector([1, pixdim(:).'], 8, 1);
h(77:108) = intBytes(pd8, 'single', be);
if p.WriteData
    h(109:112) = intBytes(352, 'single', be);
else
    h(109:112) = intBytes(0, 'single', be);
end
h(124) = uint8(p.XYZTUnits);
magic = p.Magic;
h(345:348) = uint8([double(magic(1:3)), 0]);
fid = fopen(filePath, 'w');
if fid < 0
    error('无法写入测试文件：%s', filePath);
end
fwrite(fid, h, 'uint8');
if p.WriteData
    fwrite(fid, zeros(1, 4, 'uint8'), 'uint8'); % 4 字节 extension flag
    dataBytes = prod(dims) * bitpixFor(datatypeCode) / 8;
    if dataBytes > 0 && dataBytes <= 4e6
        fwrite(fid, zeros(1, dataBytes, 'uint8'), 'uint8');
    end
end
fclose(fid);
end

function writeNifti2(filePath, dims, pixdim, datatypeCode, varargin)
%WRITENIFTI2 生成用于测试的最小 NIfTI-2 文件
p = struct('BigEndian', false, 'XYZTUnits', 10);
for k = 1:2:numel(varargin)
    p.(varargin{k}) = varargin{k + 1};
end
be = logical(p.BigEndian);
if ~exist(fileparts(filePath), 'dir')
    mkdir(fileparts(filePath));
end
h = zeros(1, 540, 'uint8');
h(1:4) = intBytes(540, 'int32', be);
h(5:12) = uint8([110, 43, 50, 0, 13, 10, 26, 10]); % 'n+2' + 0 + CR LF 0x1A LF
h(13:14) = intBytes(datatypeCode, 'int16', be);
h(15:16) = intBytes(bitpixFor(datatypeCode), 'int16', be);
dim8 = padVector([numel(dims), dims(:).'], 8, 1);
h(17:80) = intBytes(dim8, 'int64', be);
pd8 = padVector([1, pixdim(:).'], 8, 1);
h(105:168) = intBytes(pd8, 'double', be);
h(169:176) = intBytes(544, 'int64', be);
h(501:504) = intBytes(p.XYZTUnits, 'int32', be);
fid = fopen(filePath, 'w');
if fid < 0
    error('无法写入测试文件：%s', filePath);
end
fwrite(fid, h, 'uint8');
fwrite(fid, zeros(1, 4, 'uint8'), 'uint8');
dataBytes = prod(dims) * bitpixFor(datatypeCode) / 8;
if dataBytes > 0 && dataBytes <= 4e6
    fwrite(fid, zeros(1, dataBytes, 'uint8'), 'uint8');
end
fclose(fid);
end

function writeNiftiPair(hdrPath, dims, pixdim, datatypeCode, varargin)
%WRITENIFTIPAIR 生成 .hdr + .img 双文件（Analyze/NIfTI-1 配对格式）
if ~exist(fileparts(hdrPath), 'dir')
    mkdir(fileparts(hdrPath));
end
writeNifti1(hdrPath, dims, pixdim, datatypeCode, 'Magic', 'ni1', ...
    'WriteData', false, varargin{:});
[imgDir, imgBase] = fileparts(hdrPath);
imgPath = fullfile(imgDir, [imgBase '.img']);
fid = fopen(imgPath, 'w');
if fid < 0
    error('无法写入测试文件：%s', imgPath);
end
dataBytes = prod(dims) * bitpixFor(datatypeCode) / 8;
if dataBytes > 0 && dataBytes <= 4e6
    fwrite(fid, zeros(1, dataBytes, 'uint8'), 'uint8');
end
fclose(fid);
end

function gzPath = makeGzFile(filePath)
%MAKEGZFILE 用 MATLAB gzip 生成 .nii.gz 并删除原始 .nii
gzPath = [filePath '.gz'];
if exist(gzPath, 'file') == 2
    delete(gzPath);
end
gzip(filePath);
if exist(gzPath, 'file') ~= 2
    error('gzip 失败：%s', filePath);
end
delete(filePath);
end

function v = padVector(v, n, fillValue)
%PADVECTOR 把行向量补齐到长度 n
v = v(:).';
if numel(v) < n
    v = [v, fillValue * ones(1, n - numel(v))];
elseif numel(v) > n
    v = v(1:n);
end
end

function n = bitpixFor(datatypeCode)
%BITPIXFOR NIfTI 数据类型码 -> 位宽
switch datatypeCode
    case 1
        n = 1;
    case {2, 256}
        n = 8;
    case {4, 512}
        n = 16;
    case {8, 768, 16, 32}
        n = 32;
    case {64, 1024, 1280, 1792}
        n = 64;
    otherwise
        n = 32;
end
end

function b = intBytes(v, cls, be)
%INTBYTES 把整数值转换为指定文件字节序的字节流
x = feval(cls, v);
if be
    x = swapbytes(x);
end
b = typecast(x, 'uint8');
end
