function test_processed_dir_checks()
% test_processed_dir_checks  已处理目录/续跑预检 + 空白预设的自动化测试
%
% 运行方式（MRI_Workbench 目录）：
%   & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch ...
%       "cd('<...>\MRI_Workbench'); addpath(pwd); test_processed_dir_checks"
%
% 覆盖：
%   1. 预设列表含第 5 个「空白（仅补步骤/续跑）」，空白预设关闭全部处理步骤
%   2. 已处理目录 + 从 FunImg 重跑「删除初始时间点」→ error（重复删点风险）
%   3. 已处理目录 + 从 FunImg 重跑其它步骤 → warn（重复处理风险）
%   4. 多个 rp*.txt 且会重跑头动校正 → error（rp 文件冲突）
%   5. 续跑模式（StartingDirName=FunImgAR + 只开 Scrubbing）→ ok，FD 依赖通过
%   6. 续跑模式缺少 FD 文件 → error
%   7. 空白配置（无步骤）→ warn
%   8. 干净目录（只有 FunImg）不出现重复处理/rp 冲突提示

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root);
    addpath(here);

    fprintf('=== 已处理目录/续跑预检 + 空白预设测试 ===\n');
    fprintf('MATLAB %s\n', version);

    failures = 0;
    tmp1 = [tempname, '_mrw_processed'];
    tmp2 = [tempname, '_mrw_clean'];
    mkdir(tmp1);
    mkdir(tmp2);
    cleanupObj = onCleanup(@() localCleanup(tmp1, tmp2)); %#ok<NASGU>

    ids = {'Sub01', 'Sub02'};
    stageDirs = {'FunImg', 'FunImgA', 'FunImgAR', 'FunImgARB'};

    % ---------------- 构造“已处理”目录 ----------------
    for s = 1:numel(stageDirs)
        for i = 1:numel(ids)
            mkdir(fullfile(tmp1, stageDirs{s}, ids{i}));
        end
    end
    for i = 1:numel(ids)
        % 起始目录/续跑目录内放一个空 .nii，避免“输入数据类型”检查误报
        for s = 1:numel(stageDirs)
            fclose(fopen(fullfile(tmp1, stageDirs{s}, ids{i}, 'bold.nii'), 'w'));
        end
        mkdir(fullfile(tmp1, 'T1Img', ids{i}));
        rpDir = fullfile(tmp1, 'RealignParameter', ids{i});
        mkdir(rpDir);
        fclose(fopen(fullfile(rpDir, 'rp_a.txt'), 'w'));
        fclose(fopen(fullfile(rpDir, 'rp_b.txt'), 'w'));
        fclose(fopen(fullfile(rpDir, sprintf('FD_Jenkinson_%s.txt', ids{i})), 'w'));
        fclose(fopen(fullfile(rpDir, sprintf('FD_Power_%s.txt', ids{i})), 'w'));
    end

    % ---------------- 构造“干净”目录（只有 FunImg） ----------------
    for i = 1:numel(ids)
        mkdir(fullfile(tmp2, 'FunImg', ids{i}));
        fclose(fopen(fullfile(tmp2, 'FunImg', ids{i}, 'bold.nii'), 'w'));
    end

    % ---------------- 1. 预设列表与空白预设 ----------------
    P = mrw.CfgBuilder.presets();
    check(numel(P) == 5, sprintf('预设数量应为 5（实际 %d）', numel(P)));
    expected = {'经典静息态（DARTEL 全流程）', '仅功能像（EPI 模板标准化，无结构像）', ...
        'BIDS 数据一键预处理', '快速质控（仅转换+头动校正）', '空白（仅补步骤/续跑）'};
    for k = 1:numel(expected)
        check(strcmp(P(k).Name, expected{k}), sprintf('第 %d 个预设名称应为「%s」', k, expected{k}));
    end
    stBlank = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), P(5).Name);
    check(~stBlank.IsRemoveFirstTimePoints && ~stBlank.IsSliceTiming && ~stBlank.IsRealign && ...
        ~stBlank.IsNormalize && ~stBlank.IsSmooth && ~stBlank.IsCovremove && ...
        ~stBlank.IsFilter && ~stBlank.IsDetrend && ~stBlank.IsScrubbing, ...
        '空白预设应关闭全部处理步骤');

    % ---------------- 2/4. 从 FunImg 重跑：重复删点 + rp 冲突 ----------------
    st = baseState(tmp1, ids);
    st.IsRemoveFirstTimePoints = 1;
    st.RemoveFirstTimePoints = 10;
    st.IsRealign = 1;
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(hasCheck(rep, '已处理目录'), '应给出已处理目录说明');
    check(hasCheck(rep, '重复处理风险', 'error'), '从 FunImg 重跑删初始点应报 error');
    check(hasCheck(rep, 'rp 文件冲突', 'error'), '多个 rp 文件且重跑头动校正应报 error');
    check(~rep.ok, '存在 error 时 rep.ok 应为 false');

    % ---------------- 3. 从 FunImg 重跑其它步骤：仅 warn ----------------
    st = baseState(tmp1, ids);
    st.IsSmooth = 1;
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(hasCheck(rep, '重复处理风险', 'warn'), '从 FunImg 重跑其它步骤应报 warn');
    check(~hasCheck(rep, '重复处理风险', 'error'), '未删初始点时不应把重复处理升级为 error');
    check(hasCheck(rep, 'rp 文件冲突', 'warn'), '未重跑头动校正时 rp 冲突应为 warn');

    % ---------------- 5. 续跑模式：From FunImgAR + 只开 Scrubbing ----------------
    st = baseState(tmp1, ids);
    st.StartingDirName = 'FunImgAR';
    st.IsScrubbing = 1;
    st.Scrubbing.FDType = 'FD_Jenkinson';
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(hasCheck(rep, '续跑模式', 'ok'), '续跑模式应给出 ok 提示');
    check(hasCheck(rep, 'Scrubbing 依赖', 'ok'), 'FD 文件齐全时 Scrubbing 依赖应为 ok');
    check(~hasCheck(rep, '重复处理风险', 'error'), '续跑模式不应误报重复处理 error');
    check(~hasCheck(rep, 'rp 文件冲突', 'error'), '未重跑头动校正时不应把 rp 冲突升级为 error');

    % ---------------- 6. 续跑模式缺 FD 文件 → error ----------------
    delete(fullfile(tmp1, 'RealignParameter', 'Sub02', 'FD_Jenkinson_Sub02.txt'));
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(hasCheck(rep, 'Scrubbing 依赖', 'error'), '缺少 FD 文件时应报 error');
    check(~rep.ok, '缺少 FD 时应 rep.ok=false');

    % ---------------- 7. 空白配置（无步骤） ----------------
    st = baseState(tmp1, ids);
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(hasCheck(rep, '可执行步骤', 'warn'), '无任何步骤时应提示「可执行步骤」warn');

    % ---------------- 8. 干净目录不出现重复处理/冲突提示 ----------------
    st = baseState(tmp2, ids);
    rep = mrw.CfgBuilder.validate(mrw.CfgBuilder.build(st, struct('AllowGUI', false)));
    check(~hasCheck(rep, '重复处理风险'), '干净目录不应出现重复处理提示');
    check(~hasCheck(rep, 'rp 文件冲突'), '干净目录不应出现 rp 冲突提示');

    % ---------------- 汇总 ----------------
    if failures == 0
        fprintf('\n全部通过\n');
    else
        fprintf('\n%d 项失败\n', failures);
        error('test_processed_dir_checks: %d 项失败', failures);
    end

    % ---------------- 嵌套辅助函数 ----------------
    function st = baseState(wd, subjIDs)
        st = mrw.CfgBuilder.defaultState();
        st.WorkingDir = wd;
        st.DataProcessDir = wd;
        st.SubjectID = subjIDs;
        st.StartingDirName = 'FunImg';
        st.TimePoints = 100;
        st.TR = 2;
        st.FunctionalSessionNumber = 1;
    end

    function tf = hasCheck(rep, name, level)
        if nargin < 3, level = ''; end
        tf = false;
        for c = 1:numel(rep.checks)
            if strcmp(rep.checks(c).Name, name) && (isempty(level) || strcmp(rep.checks(c).Level, level))
                tf = true;
                return;
            end
        end
    end

    function check(cond, msg)
        if cond
            fprintf('PASS  %s\n', msg);
        else
            failures = failures + 1;
            fprintf('FAIL  %s\n', msg);
        end
    end
end

function localCleanup(varargin)
for k = 1:numel(varargin)
    d = varargin{k};
    if exist(d, 'dir') == 7
        try
            rmdir(d, 's');
        catch
        end
    end
end
end
