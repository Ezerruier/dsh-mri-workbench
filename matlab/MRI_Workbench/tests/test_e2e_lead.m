function test_e2e_lead
% 端到端验收测试：自动扫描 -> 应用索引 -> 套预设 -> 运行前检查 -> 后台运行 DPARSFA -> 结束
% 数据为运行时生成的合成 NIfTI（FunRaw/<Subj>/rest.nii）
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
addpath(here);
outDir = fullfile(here, 'out_e2e');
if exist(outDir, 'dir') ~= 7, mkdir(outDir); end
fid = fopen(fullfile(outDir, 'log.txt'), 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});
app = [];

try
    % ---------- 1) 生成合成数据（NIfTI, DPARSF 布局：FunRaw/<subj>/） ----------
    base = fullfile(here, 'tmp_e2e');
    if exist(base, 'dir') == 7, rmdir(base, 's'); end
    mkdir(base);
    wb = fullfile(base, 'MyStudy');
    nVol = 16; dims = [16 16 8];
    [X, Y, Z] = ndgrid(-8:7, -8:7, -4:3);
    brain = exp(-(X.^2 + Y.^2 + Z.^2) / 20);
    subs = {'Sub01', 'Sub02', 'Sub03'};
    for s = 1:numel(subs)
        fd = fullfile(wb, 'FunRaw', subs{s});
        mkdir(fd);
        vol = zeros([dims nVol], 'single');
        for t = 1:nVol
            img = interp3(brain, X + 0.2*sin(t/3+s), Y + 0.1*cos(t/4), Z, 'linear', 0);
            vol(:, :, :, t) = single(img + 0.02*randn(dims));
        end
        lead_make_nifti(vol, fullfile(fd, 'rest.nii'), [2 2 2], 2);
    end
    say('合成数据: %s（%d 被试 × %d 时间点）', wb, numel(subs), nVol);

    % ---------- 2) 启动工作台 ----------
    app = mrw.WorkbenchApp();
    drawnow;
    say('工作台启动完成');

    % ---------- 3) 自动扫描 ----------
    app.DataPanel.setRoot(wb);
    app.DataPanel.scan(wb, 4);
    t0 = tic; idx = [];
    while toc(t0) < 120
        pause(1);
        idx = app.DataPanel.getIndex();
        if ~isempty(idx), break; end
    end
    if isempty(idx)
        error('自动扫描超时：未获得索引');
    end
    say('扫描完成: layout=%s subjects=%d dir=%s', idx.Layout, numel(idx.Subjects), idx.LayoutName);
    say('Detected: wd=%s start=%s TR=%g TP=%g slices=%g', idx.Detected.WorkingDir, ...
        idx.Detected.StartingDirName, idx.Detected.TR, idx.Detected.TimePoints, idx.Detected.SliceNumber);
    for i = 1:numel(idx.Subjects)
        s = idx.Subjects(i);
        say('  subj=%s fun=%s type=%s TP=%g TR=%g', s.ID, s.FunDirs{1}, s.FunType, s.TimePoints, s.TR);
    end

    % ---------- 4) 应用索引 + 预设 ----------
    app.applyScanIndex(idx);
    drawnow;
    st = app.PrepPanel.getState();
    say('应用后状态: wd=%s subjNum=%d start=%s conv=%d/%d TP=%g TR=%g', ...
        st.WorkingDir, numel(st.SubjectID), st.StartingDirName, ...
        st.IsNeedConvertFunDCM2IMG, st.IsNeedConvertT1DCM2IMG, st.TimePoints, st.TR);
    P = mrw.CfgBuilder.presets();
    presetName = P(4).Name;   % 快速质控
    app.applyPreset(presetName);
    drawnow;
    st = app.PrepPanel.getState();
    say('预设应用: %s', presetName);
    say('预设后: remove=%d/%d realign=%d norm=%g', ...
        st.IsRemoveFirstTimePoints, st.RemoveFirstTimePoints, st.IsRealign, st.IsNormalize);

    % ---------- 5) 保存截图（预处理页） ----------
    app.showPage(2); drawnow; pause(0.4);
    try
        exportapp(app.Fig, fullfile(outDir, 'page2_after_scan.png'));
        say('预处理页截图已保存');
    catch err
        say('截图失败: %s', err.message);
    end

    % ---------- 6) 运行前检查 ----------
    app.showPage(3); drawnow;
    Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
    rep = mrw.CfgBuilder.validate(Cfg, idx.Detected);
    say('运行前检查: %s', rep.summary);
    for i = 1:numel(rep.errors), say('  ERR: %s', rep.errors{i}); end
    for i = 1:numel(rep.warnings), say('  WARN: %s', rep.warnings{i}); end
    if ~rep.ok
        error('运行前检查未通过，终止 E2E');
    end

    % ---------- 7) 启动运行并等待 ----------
    try
        app.startRun();
    catch err
        say('startRun 抛出异常: %s', err.message);
    end
    pause(1);
    say('startRun 后: Runner empty=%d, state=%s', isempty(app.Runner), app.runStatus().State);
    drawnow;
    pause(1);
    t0 = tic; lastState = '';
    while toc(t0) < 240
        pause(2);
        s = app.runStatus();
        if ~strcmp(s.State, lastState)
            say('[%5.0fs] state=%s progress=%.2f msg=%s', toc(t0), s.State, s.Progress, s.Message);
            lastState = s.State;
        end
        if any(strcmp(s.State, {'finished', 'failed', 'cancelled'})), break; end
    end
    s = app.runStatus();
    if ~isfield(s, 'Elapsed'), s.Elapsed = 0; end
    if ~isfield(s, 'Phases'), s.Phases = {}; end
    say('最终状态: %s | 用时 %.1f 秒 | %s', s.State, s.Elapsed, s.Message);
    if isfield(s, 'Phases')
        for i = 1:numel(s.Phases), say('  phase: %s', s.Phases{i}); end
    end

    % ---------- 8) 截图运行页 + 输出检查 ----------
    drawnow; pause(0.5);
    try
        exportapp(app.Fig, fullfile(outDir, 'page3_after_run.png'));
        say('运行页截图已保存');
    catch err
        say('运行页截图失败: %s', err.message);
    end
    dd = dir(fullfile(wb, 'RealignParameter'));
    say('RealignParameter 条目数: %d', numel(dd));
    hm = dir(fullfile(wb, 'RealignParameter', 'HeadMotion.tsv'));
    say('HeadMotion.tsv 存在: %d', ~isempty(hm));
    hd = dir(fullfile(wb, 'FunRawR'));
    say('FunRawR 目录存在: %d', ~isempty(hd));

    if ~strcmp(s.State, 'finished')
        error('运行未成功完成：%s', s.Message);
    end
    say('E2E_RESULT=SUCCESS');
catch err
    say('E2E_EXCEPTION: %s', err.message);
    for k = 1:min(numel(err.stack), 8)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
    say('E2E_RESULT=FAILED');
end

try
    if ~isempty(app) && isvalid(app.Fig)
        delete(app.Fig);
    end
catch
end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end
