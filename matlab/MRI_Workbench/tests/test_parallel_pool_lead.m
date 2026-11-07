function test_parallel_pool_lead
% test_parallel_pool_lead  验证 ParallelWorkersNumber>0 时 headlessRunner 真正按设定建池
% 场景：2 名合成被试、16 个时间点、快速质控预设（删前 10 点 + 头动校正）
%       ParallelWorkersNumber=6（超过被试数 2）→ 应自动下调为 2 并建 2-worker 池，
%       而不是让 parfor 自动建本机默认的 24-worker 池。
% 运行：matlab -batch "addpath('<tests目录>'); test_parallel_pool_lead"
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
addpath(here);
outFile = fullfile(here, 'out_parallel_pool.txt');
fid = fopen(outFile, 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});
ok = false;

try
    % 1) 合成数据（与 test_runner_lead 相同的极小数据）
    base = fullfile(here, 'tmp_parallel_pool');
    if exist(base, 'dir') == 7
        rmdir(base, 's');
    end
    mkdir(base);
    nVol = 16; nRemove = 10; dims = [16 16 8];
    wb = fullfile(base, 'dataset');
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
    say('合成数据：2 被试 × %d 时间点，%dx%dx%d', nVol, dims(1), dims(2), dims(3));

    % 2) Cfg：快速质控预设 + 请求 6 worker（应被下调到被试数 2）
    st = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), '快速质控（仅转换+头动校正）');
    st.WorkingDir = wb;
    st.DataProcessDir = wb;
    st.SubjectID = {'Sub01', 'Sub02'};
    st.TR = 2;
    st.TimePoints = nVol;
    st.IsRemoveFirstTimePoints = 1;
    st.RemoveFirstTimePoints = nRemove;
    st.ParallelWorkersNumber = 6;
    Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
    rep = mrw.CfgBuilder.validate(Cfg);
    say('validate: %s', rep.summary);
    if ~rep.ok
        error('配置校验失败：%s', strjoin(rep.errors, '；'));
    end
    say('Cfg.ParallelWorkersNumber=%d，SubjectNum=%d', Cfg.ParallelWorkersNumber, Cfg.SubjectNum);

    % 3) 后台运行
    r = mrw.Runner(fullfile(base, 'runs'));
    r.OnLog = @(txt) fprintf('%s', txt);
    r.OnStatus = @(s) fprintf('[status] state=%s progress=%.2f msg=%s\n', s.State, s.Progress, s.Message);
    r.start(Cfg, struct('RunName', 'pooltest', 'AllowGUI', false));
    say('Runner 已启动，RunDir=%s', r.RunDir);

    t0 = tic;
    while r.Running && toc(t0) < 900
        pause(2);
    end
    stt = r.getStatus();
    say('最终状态：%s | 耗时 %.1f 秒 | %s', stt.State, stt.Elapsed, stt.Message);

    % 4) 日志断言
    logTxt = fileread(r.LogFile);
    say('run.log 长度=%d 字符', numel(logTxt));
    tail = logTxt(max(1, end-1500):end);
    say('日志末尾：\n%s', tail);

    local_assert(~isempty(strfind(logTxt, '自动调整为 2')), ...
        '缺少“并行数超限自动下调为 2”的日志');
    local_assert(~isempty(strfind(logTxt, '已创建 2 worker 并行池')), ...
        '缺少“已创建 2 worker 并行池”的日志');
    local_assert(isempty(strfind(logTxt, '24 个工作单元')), ...
        '日志出现 24 worker 自动建池，说明 ParallelWorkersNumber 未生效');
    local_assert(isempty(strfind(logTxt, '24 worker')), ...
        '日志出现 24 worker，说明 ParallelWorkersNumber 未生效');
    local_assert(strcmp(stt.State, 'finished'), sprintf('运行未成功结束：%s（%s）', stt.State, stt.Message));
    say('PARALLEL_POOL_TEST=SUCCESS');
    ok = true;
catch err
    say('EXCEPTION: %s', err.message);
    for k = 1:min(numel(err.stack), 10)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
end
fclose(fid);
if ~ok
    error('test_parallel_pool_lead 失败，详见 %s', outFile);
end
end

function local_assert(cond, msg)
if ~cond
    error('断言失败：%s', msg);
end
end

function local_say(fid, fmt, varargin)
msg = sprintf(fmt, varargin{:});
fprintf('%s\n', msg);
fprintf(fid, '%s\n', msg);
end
