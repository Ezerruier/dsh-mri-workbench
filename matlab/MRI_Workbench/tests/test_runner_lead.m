function test_runner_lead
% 后台运行集成测试：生成小型合成数据集 -> mrw.Runner -> 独立 MATLAB 进程执行 DPARSFA_run
% 验证：进程启动、日志回流、进度解析、结束状态、输出文件
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
addpath(here);
outFile = fullfile(here, 'out_runner.txt');
fid = fopen(outFile, 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});

try
    % 1) 清理并生成合成数据
    base = fullfile(here, 'tmp_runner');
    if exist(base, 'dir') == 7
        rmdir(base, 's');
    end
    mkdir(base);
    nVol = 16; nRemove = 10;
    dims = [16 16 8];
    wb = fullfile(base, 'dataset');
    say('生成合成数据: %s', wb);
    [X, Y, Z] = ndgrid(-8:7, -8:7, -4:3);
    baseBrain = exp(-(X.^2 + Y.^2 + Z.^2) / 20);
    for s = 1:2
        subj = sprintf('Sub%02d', s);
        fd = fullfile(wb, 'FunRaw', subj);
        mkdir(fd);
        vol = zeros([dims nVol], 'single');
        for t = 1:nVol
            dx = 0.2 * sin(t/3) * (s == 1) + 0.1 * (s == 2);
            dy = 0.15 * cos(t/4);
            img = interp3(baseBrain, X + dx, Y + dy, Z, 'linear', 0);
            img = img + 0.02 * randn(dims);
            vol(:, :, :, t) = single(img);
        end
        lead_make_nifti(vol, fullfile(fd, 'rest.nii'), [2 2 2], 2);
    end
    say('每被试 %d 个时间点，%dx%dx%d', nVol, dims(1), dims(2), dims(3));

    % 2) 构建配置：快速质控预设（删前10点 + 头动校正）
    st = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), '快速质控（仅转换+头动校正）');
    st.WorkingDir = wb;
    st.DataProcessDir = wb;   % DPARSF 引擎从 DataProcessDir 读取原始数据并写结果，通常与工作目录相同
    st.SubjectID = {'Sub01', 'Sub02'};
    st.TR = 2;
    st.TimePoints = nVol;
    st.IsRemoveFirstTimePoints = 1;
    st.RemoveFirstTimePoints = nRemove;
    Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
    say('Cfg: steps=%s', mrw.CfgBuilder.enabledSteps(Cfg));
    rep = mrw.CfgBuilder.validate(Cfg);
    say('validate: %s', rep.summary);
    for i = 1:numel(rep.errors), say('  ERR %s', rep.errors{i}); end
    if ~rep.ok
        error('配置校验失败，终止测试');
    end

    % 3) Runner 启动
    r = mrw.Runner(fullfile(base, 'runs'));
    logTail = '';
    lastMsg = '';
    r.OnLog = @(txt) fprintf('%s', txt);
    r.OnStatus = @(s) fprintf('[status] state=%s progress=%.2f msg=%s\n', s.State, s.Progress, s.Message);
    r.OnFinish = @(s) fprintf('[finish] state=%s elapsed=%.1f msg=%s\n', s.State, s.Elapsed, s.Message);
    r.start(Cfg, struct('RunName', 'smoketest', 'AllowGUI', false));
    say('Runner 已启动，RunDir=%s', r.RunDir);

    % 4) 等待结束（最长 15 分钟）
    t0 = tic;
    lastReport = 0;
    while r.Running && toc(t0) < 900
        pause(2);
        if toc(t0) - lastReport > 20
            lastReport = toc(t0);
            stt = r.getStatus();
            say('[等待 %.0fs] state=%s progress=%.2f phases=%d', ...
                toc(t0), stt.State, stt.Progress, numel(stt.Phases));
        end
    end
    stt = r.getStatus();
    say('最终状态: %s | 耗时 %.1f 秒 | message=%s', stt.State, stt.Elapsed, stt.Message);
    say('检测到阶段数: %d', numel(stt.Phases));
    for i = 1:numel(stt.Phases), say('  phase: %s', stt.Phases{i}); end

    % 5) 日志与状态文件
    L = dir(fullfile(r.RunDir, '*'));
    say('RunDir 文件:');
    for i = 1:numel(L)
        if ~L(i).isdir
            say('  %s (%d bytes)', L(i).name, L(i).bytes);
        end
    end
    stFile = mrw.Runner.lastStatus(r.RunDir);
    if ~isempty(stFile)
        say('status.json: %s', jsonencode(stFile));
    end
    logTxt = fileread(r.LogFile);
    say('run.log 长度=%d 字符', numel(logTxt));
    say('日志末尾 1200 字符:');
    say('%s', logTxt(max(1, end-1200):end));

    % 6) 输出数据检查
    say('输出目录树:');
    dd = dir(fullfile(wb, 'Results'));
    for i = 1:min(numel(dd), 20)
        say('  %s', dd(i).name);
    end
    ra = dir(fullfile(wb, 'Results', 'RealignParameter', 'Sub01'));
    say('Sub01 RealignParameter 文件数=%d', numel(ra));
    say('FINAL_STATE=%s', stt.State);
    say('DONE');
catch err
    say('EXCEPTION: %s', err.message);
    for k = 1:min(numel(err.stack), 10)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end
