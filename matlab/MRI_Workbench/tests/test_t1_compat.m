function test_t1_compat()
%TEST_T1_COMPAT T1 裁剪兼容模式（旧版 dcm2nii / 免裁剪直通）自包含测试
%
% 背景：DPABI 的 T1 裁剪改用 dcm2niix（只支持 DICOM 输入），T1Img 只有 NIfTI
% 时不会生成 c*/co*，无界面模式在 questdlg 处报错。本测试验证工作台两种
% 兼容模式（mrw.T1Compat）以及 CfgSchema/CfgBuilder 的接线。
%
% 用法（项目根目录）：matlab -batch "addpath('tests'); test_t1_compat"
% 输出逐项 [ok]/[FAIL]，最后一行形如 "PASS n/n"。
% 注意：old_dcm2nii 用例会真实调用 DPABI 自带的旧版 dcm2nii.exe（本机有）。

    here = fileparts(mfilename('fullpath'));
    projectRoot = fileparts(here);
    addpath(projectRoot);
    addpath(here);

    state = struct('Total', 0, 'Passed', 0, 'Failures', {{}});
    tmpRoot = fullfile(tempdir, sprintf('mrw_t1compat_%s', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'))));
    if mkdir(tmpRoot) ~= 1 && exist(tmpRoot, 'dir') ~= 7
        error('无法创建测试临时目录：%s', tmpRoot);
    end
    cleanupObj = onCleanup(@() safeRemoveDir(tmpRoot)); %#ok<NASGU>
    fprintf('test temp root: %s\n', tmpRoot);

    runSafe('Schema', @sectionSchema);
    runSafe('T1Compat-apply', @sectionApply);
    runSafe('CfgBuilder-build', @sectionBuild);
    runSafe('CfgBuilder-validate', @sectionValidate);
    runSafe('Headless-integration', @sectionHeadlessIntegration);

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
    function check(cond, name)
        state.Total = state.Total + 1;
        if ~isempty(cond) && isequal(all(logical(cond(:))), true)
            state.Passed = state.Passed + 1;
            fprintf('  [ok] %s\n', name);
        else
            state.Failures{end+1} = name;
            fprintf('  [FAIL] %s\n', name);
        end
    end

    function runSafe(sectionName, fcn)
        fprintf('\n== %s ==\n', sectionName);
        try
            fcn();
        catch err
            state.Total = state.Total + 1;
            state.Failures{end+1} = sprintf('%s: unexpected error (%s)', sectionName, err.message);
            fprintf('  [FAIL] %s: %s\n', sectionName, err.message);
        end
    end

    function tf = hasMsg(list, pattern)
        tf = false;
        for k = 1:numel(list)
            if ~isempty(regexp(char(list{k}), pattern, 'once'))
                tf = true;
                return
            end
        end
    end

    % ------------------------------------------------------------------
    function sectionSchema()
        S = mrw.CfgSchema.entries();
        e = [];
        for k = 1:numel(S)
            if strcmp(S(k).Key, 'T1CropCompat'), e = S(k); break; end
        end
        check(~isempty(e), 'Schema: T1CropCompat 存在');
        if isempty(e), return; end
        check(strcmp(e.Group, '结构像处理'), 'Schema: 分组=结构像处理');
        check(strcmp(e.Type, 'enum'), 'Schema: 类型=enum');
        check(strcmp(mrw.T1Compat.normalizeMode(e.Default), 'auto'), 'Schema: 默认 auto');
        vals = {e.Options.Value};
        check( isequal(sort(vals), sort({'auto', 'old_dcm2nii', 'no_crop'})), ...
            'Schema: 三个枚举值 auto/old_dcm2nii/no_crop');
        st = mrw.CfgSchema.defaults();
        check(strcmp(mrw.CfgSchema.getKey(st, 'T1CropCompat'), 'auto'), ...
            'Schema: defaults() 包含 T1CropCompat=auto');
        check(~isempty(mrw.T1Compat.oldDcm2niiExe()), ...
            'Schema: 本机 DPABI 自带旧版 dcm2nii.exe 可用');
    end

    % ------------------------------------------------------------------
    function sectionApply()
        % 模式归一化
        check(strcmp(mrw.T1Compat.normalizeMode('old-dcm2nii'), 'old_dcm2nii'), 'Mode: old-dcm2nii -> old_dcm2nii');
        check(strcmp(mrw.T1Compat.normalizeMode('No_Crop'), 'no_crop'), 'Mode: No_Crop -> no_crop');
        check(strcmp(mrw.T1Compat.normalizeMode('whatever'), 'auto'), 'Mode: 未知值 -> auto');
        check(strcmp(mrw.T1Compat.normalizeMode(''), 'auto'), 'Mode: 空 -> auto');

        % auto：不干预
        wdAuto = fullfile(tmpRoot, 'auto');
        mkT1(wdAuto, 'A01');
        CfgA = baseCfg(wdAuto, {'A01'}, 'auto', 1);
        [outA, ~] = mrw.T1Compat.apply(CfgA, []);
        check(outA.IsNeedReorientCropT1Img == 1, 'apply(auto): 不改动 IsNeedReorientCropT1Img');
        check(~hasAnyCropped(fullfile(wdAuto, 'T1Img', 'A01')), 'apply(auto): 不生成 c* 文件');

        % old_dcm2nii：真实裁剪
        wdOld = fullfile(tmpRoot, 'old');
        mkT1(wdOld, 'S01');
        CfgO = baseCfg(wdOld, {'S01'}, 'old_dcm2nii', 1);
        [outO, msgsO] = mrw.T1Compat.apply(CfgO, []);
        dOld = dir(fullfile(wdOld, 'T1Img', 'S01', 'c*.nii'));
        check(~isempty(dOld), 'apply(old_dcm2nii): 生成 c* 裁剪文件');
        check(outO.IsNeedReorientCropT1Img == 0, 'apply(old_dcm2nii): 关闭 DPARSF 裁剪步骤');
        check(hasMsg(msgsO, '旧版 dcm2nii'), 'apply(old_dcm2nii): 日志包含旧版 dcm2nii');
        check(hasMsg(msgsO, '已生成裁剪文件'), 'apply(old_dcm2nii): 日志包含生成文件');
        if ~isempty(dOld)
            check(dOld(1).bytes > 0, 'apply(old_dcm2nii): 裁剪文件非空');
        end

        % 已有 c* 时跳过
        [outO2, msgsO2] = mrw.T1Compat.apply(CfgO, []);
        check(hasMsg(msgsO2, '跳过裁剪'), 'apply(old_dcm2nii): 已有 c* 时跳过');
        dOld2 = dir(fullfile(wdOld, 'T1Img', 'S01', 'c*.nii'));
        check(numel(dOld2) == numel(dOld), 'apply(old_dcm2nii): 跳过时不重复生成');

        % no_crop：直通复制
        wdNo = fullfile(tmpRoot, 'nocrop');
        mkT1(wdNo, 'S02');
        CfgN = baseCfg(wdNo, {'S02'}, 'no_crop', 1);
        [outN, msgsN] = mrw.T1Compat.apply(CfgN, []);
        srcN = fullfile(wdNo, 'T1Img', 'S02', 'T1.nii');
        dstN = fullfile(wdNo, 'T1Img', 'S02', 'cT1.nii');
        check(exist(dstN, 'file') == 2, 'apply(no_crop): 生成 c* 直通文件');
        check(outN.IsNeedReorientCropT1Img == 0, 'apply(no_crop): 关闭 DPARSF 裁剪步骤');
        check(hasMsg(msgsN, '未裁剪直通文件'), 'apply(no_crop): 日志说明直通（未裁剪）');
        sinfo = dir(srcN); dinfo = dir(dstN);
        check(sinfo.bytes == dinfo.bytes, 'apply(no_crop): 直通文件与原始 T1 字节数一致');

        % 缺 T1Img / 多 T1 文件
        wdErr = fullfile(tmpRoot, 'err');
        mkdir(fullfile(wdErr, 'T1Img', 'E01'));
        CfgE = baseCfg(wdErr, {'E01'}, 'old_dcm2nii', 1);
        okErr = false;
        try
            mrw.T1Compat.apply(CfgE, []);
        catch err
            okErr = ~isempty(regexp(err.message, '没有 T1 NIfTI 文件', 'once'));
        end
        check(okErr, 'apply(old_dcm2nii): 缺 T1 文件时给出中文错误');

        wdMulti = fullfile(tmpRoot, 'multi');
        mkT1(wdMulti, 'M01');
        lead_make_nifti(ones(8, 8, 8), fullfile(wdMulti, 'T1Img', 'M01', 'T1b.nii'), [1 1 1], 2);
        CfgM = baseCfg(wdMulti, {'M01'}, 'no_crop', 1);
        okMulti = false;
        try
            mrw.T1Compat.apply(CfgM, []);
        catch err
            okMulti = ~isempty(regexp(err.message, '多个 T1 文件|2 个 T1 文件', 'once'));
        end
        check(okMulti, 'apply(no_crop): 多个 T1 文件时给出中文错误');

        % t1Needed=false 时跳过
        CfgSkip = baseCfg(wdAuto, {'A01'}, 'old_dcm2nii', 0);
        CfgSkip.IsSegment = 0; CfgSkip.IsBet = 0;
        CfgSkip.IsNeedT1CoregisterToFun = 0; CfgSkip.IsDARTEL = 0;
        [outS, msgsS] = mrw.T1Compat.apply(CfgSkip, []);
        check(outS.IsNeedReorientCropT1Img == 0, 'apply: 流程不需要 T1 时关闭裁剪步骤');
        check(hasMsg(msgsS, '已跳过'), 'apply: 流程不需要 T1 时日志说明跳过');

        % T1Raw DICOM 转换模式：自动生成 co*，兼容层应跳过
        CfgDcm = baseCfg(wdAuto, {'A01'}, 'old_dcm2nii', 1);
        CfgDcm.IsNeedConvertT1DCM2IMG = 1;
        [outD, msgsD] = mrw.T1Compat.apply(CfgDcm, []);
        check(outD.IsNeedReorientCropT1Img == 0, 'apply: DICOM 转换模式关闭裁剪步骤');
        check(hasMsg(msgsD, 'DICOM 转换') && hasMsg(msgsD, '跳过'), ...
            'apply: DICOM 转换模式日志说明跳过');
    end

    % ------------------------------------------------------------------
    function sectionBuild()
        wd = fullfile(tmpRoot, 'build');
        mkWorkdir(wd, 'S01');
        st = mrw.CfgBuilder.defaultState();
        st.WorkingDir = wd;
        st.DataProcessDir = wd;
        st.SubjectID = {'S01'};
        st.StartingDirName = 'FunImg';
        st.TR = 2; st.TimePoints = 16;
        st.IsNormalize = 2;
        st.IsSegment = 2;
        st.IsDARTEL = 0;
        st.IsBet = 1;
        st.IsNeedT1CoregisterToFun = 0;
        st.IsNeedReorientCropT1Img = 1;

        st.T1CropCompat = 'auto';
        CfgA = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        check(strcmp(CfgA.T1CropCompat, 'auto'), 'build(auto): Cfg 保留 T1CropCompat=auto');
        check(CfgA.IsNeedReorientCropT1Img == 1, 'build(auto): 保留 IsNeedReorientCropT1Img');

        st.T1CropCompat = 'old_dcm2nii';
        CfgO = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        check(strcmp(CfgO.T1CropCompat, 'old_dcm2nii'), 'build(old): Cfg.T1CropCompat=old_dcm2nii');
        check(CfgO.IsNeedReorientCropT1Img == 0, 'build(old): 关闭 DPARSF 裁剪步骤');

        st.T1CropCompat = 'no_crop';
        CfgN = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        check(strcmp(CfgN.T1CropCompat, 'no_crop'), 'build(no_crop): Cfg.T1CropCompat=no_crop');
        check(CfgN.IsNeedReorientCropT1Img == 0, 'build(no_crop): 关闭 DPARSF 裁剪步骤');

        % 不需要 T1 的流程不受影响
        st2 = st;
        st2.IsNormalize = 1;
        st2.IsSegment = 0; st2.IsBet = 0; st2.IsDARTEL = 0;
        st2.IsNeedT1CoregisterToFun = 0; st2.IsNeedReorientCropT1Img = 0;
        st2.T1CropCompat = 'old_dcm2nii';
        Cfg2 = mrw.CfgBuilder.build(st2, struct('AllowGUI', false));
        check(Cfg2.IsNeedReorientCropT1Img == 0, 'build: 无需 T1 时兼容模式不强行启用裁剪');
    end

    % ------------------------------------------------------------------
    function sectionValidate()
        wd = fullfile(tmpRoot, 'validate');
        mkWorkdir(wd, 'S01');
        st = mrw.CfgBuilder.defaultState();
        st.WorkingDir = wd;
        st.DataProcessDir = wd;
        st.SubjectID = {'S01'};
        st.StartingDirName = 'FunImg';
        st.TR = 2; st.TimePoints = 16;
        st.IsNormalize = 2;
        st.IsSegment = 2;
        st.IsDARTEL = 0;
        st.IsBet = 1;
        st.IsNeedT1CoregisterToFun = 0;
        st.IsNeedReorientCropT1Img = 1;

        % auto + 裁剪开关：NIfTI T1 + dcm2niix 不支持 -> 明确 error，提示改用兼容模式
        st.T1CropCompat = 'auto';
        Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        rep = mrw.CfgBuilder.validate(Cfg);
        check(hasMsg(rep.errors, 'dcm2niix') && hasMsg(rep.errors, 'T1 裁剪兼容模式'), ...
            'validate(auto 裁剪+纯 NIfTI): 报错并提示改用 T1 裁剪兼容模式');

        % auto + 不裁剪：无 co* -> 原有 error（提示勾选裁剪/兼容模式）
        st.IsNeedReorientCropT1Img = 0;
        Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        rep = mrw.CfgBuilder.validate(Cfg);
        check(hasMsg(rep.errors, '无 co\*') && hasMsg(rep.errors, 'T1 裁剪兼容模式'), ...
            'validate(auto 不裁剪+无 co*): 报错并提示兼容模式');

        % old_dcm2nii：无 T1 相关 error，预检说明旧版 dcm2nii 可用
        st.T1CropCompat = 'old_dcm2nii';
        Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        rep = mrw.CfgBuilder.validate(Cfg);
        check(~hasMsg(rep.errors, 'co\*') && ~hasMsg(rep.errors, 'dcm2niix'), ...
            'validate(old_dcm2nii): 无 co*/dcm2niix 相关 error');
        check(hasMsg({rep.checks.Message}, '旧版 dcm2nii'), ...
            'validate(old_dcm2nii): 检查项说明使用旧版 dcm2nii');

        % no_crop：无 co* error，并 warn 说明未裁剪直通需 QC
        st.T1CropCompat = 'no_crop';
        Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
        rep = mrw.CfgBuilder.validate(Cfg);
        check(~hasMsg(rep.errors, 'co\*'), 'validate(no_crop): 无 co* error');
        check(hasMsg(rep.warnings, '免裁剪') && hasMsg(rep.warnings, 'QC'), ...
            'validate(no_crop): warn 提示未裁剪直通需 QC');
    end

    % ------------------------------------------------------------------
    function sectionHeadlessIntegration()
        % 校验 headlessRunner 源码中已接线（不实际跑 DPARSF）
        f = fullfile(projectRoot, '+mrw', 'headlessRunner.m');
        txt = fileread(f);
        check(~isempty(strfind(txt, 'mrw.T1Compat.apply')), ...
            'headlessRunner: 调用 mrw.T1Compat.apply');
        check(~isempty(strfind(txt, 'T1CropCompat')), ...
            'headlessRunner: 处理/移除 T1CropCompat 字段');
        % cli 结果字段
        cliTxt = fileread(fullfile(projectRoot, '+mrw', 'cli.m'));
        check(~isempty(strfind(cliTxt, 'res.t1CropCompat')), 'cli: 输出 t1CropCompat');
        check(~isempty(strfind(cliTxt, 'res.t1CropCompatLabel')), 'cli: 输出 t1CropCompatLabel');
        check(~isempty(strfind(cliTxt, 'res.t1CropPlan')), 'cli: 输出 t1CropPlan');
    end

    % ---------------------- helpers ----------------------
    function Cfg = baseCfg(wd, ids, mode, cropFlag)
        Cfg = struct();
        Cfg.WorkingDir = wd;
        Cfg.DataProcessDir = wd;
        Cfg.SubjectID = ids;
        Cfg.IsSegment = 2;
        Cfg.IsNeedT1CoregisterToFun = 0;
        Cfg.IsDARTEL = 0;
        Cfg.IsBet = 0;
        Cfg.IsApplyDownloadedReorientMats = 0;
        Cfg.IsNeedReorientCropT1Img = cropFlag;
        Cfg.T1CropCompat = mode;
    end

    function mkT1(wd, subj)
        t1dir = fullfile(wd, 'T1Img', subj);
        if exist(t1dir, 'dir') ~= 7, mkdir(t1dir); end
        [X, Y, Z] = ndgrid(-4:3, -4:3, -4:3);
        brain = single(exp(-(X.^2 + Y.^2 + Z.^2) / 10));
        lead_make_nifti(brain, fullfile(t1dir, 'T1.nii'), [2 2 2], 2);
    end

    function mkWorkdir(wd, subj)
        mkT1(wd, subj);
        fundir = fullfile(wd, 'FunImg', subj);
        if exist(fundir, 'dir') ~= 7, mkdir(fundir); end
        vol = zeros(8, 8, 8, 16, 'single');
        [X, Y, Z] = ndgrid(-4:3, -4:3, -4:3);
        base = single(exp(-(X.^2 + Y.^2 + Z.^2) / 10));
        for t = 1:16
            vol(:, :, :, t) = base;
        end
        lead_make_nifti(vol, fullfile(fundir, 'rest.nii'), [2 2 2], 2);
    end

    function tf = hasAnyCropped(t1dir)
        tf = mrw.T1Compat.hasCroppedFile(t1dir);
    end

    function safeRemoveDir(p)
        try
            if exist(p, 'dir') == 7
                rmdir(p, 's');
            end
        catch
        end
    end
end
