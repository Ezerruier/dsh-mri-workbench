function headlessRunner(cfgFile, logFile, statusFile, allowGUI)
% headlessRunner  在独立 MATLAB 进程中执行 DPARSFA 预处理（由 mrw.Runner 调用）
%
% 用法（由工作台自动生成命令行）:
%   matlab -batch "addpath('<proj>'); mrw.headlessRunner('<cfg.mat>','<run.log>','<status.json>',0)"
%
% 说明:
%   - 所有输出写入 diary(logFile)，工作台用 timer 增量读取并显示；
%   - statusFile 为 JSON 状态（state/message/finishedAt），供工作台判断结束；
%   - 不弹出任何交互窗口；DPARSFA_run 的 IsAllowGUI 由 allowGUI 参数控制。

if nargin < 4 || isempty(allowGUI)
    allowGUI = 0;
end
allowGUI = double(logical(allowGUI));

% 保证日志文件可写
fid = fopen(logFile, 'w');
if fid < 0
    error('headlessRunner: 无法创建日志文件 %s', logFile);
end
fclose(fid);

diary(logFile);
diary on;
startTic = tic;
fprintf('[工作台] ================================================\n');
fprintf('[工作台] 后台预处理进程启动：%s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
fprintf('[工作台] MATLAB %s | %s\n', version, computer);
fprintf('[工作台] 配置：%s\n', cfgFile);
fprintf('[工作台] 允许交互(IsAllowGUI)：%d\n', allowGUI);

cleanupObj = onCleanup(@() local_finish_log()); %#ok<NASGU>

try
    % 1) 路径与 DPABI 环境
    here = fileparts(mfilename('fullpath'));       % +mrw
    projRoot = fileparts(here);                     % MRI_Workbench
    addpath(projRoot);
    [okPath, dpabiRoot, spmRoot] = local_ensure_paths();
    if ~okPath
        error('headlessRunner: DPABI/SPM 未就绪（DPABI=%s, SPM=%s）', dpabiRoot, spmRoot);
    end

    % 1b) 外部工具 PATH：DPABI 自带的 bet/dcm2nii 由 y_Call_bet/y_Call_dcm2nii
    %     先 cd 进工具目录再用 !tool 调用，依赖 cmd 搜索当前目录；本机若带
    %     NoDefaultCurrentDirectoryInExePath=1（DSH 启动的子进程会继承），
    %     cmd 不搜索当前目录，工具就会报“不是内部或外部命令”。
    %     这里显式把工具目录前置进 PATH；必须在创建并行池之前执行，worker 才会继承。
    toolDirs = {fullfile(dpabiRoot, 'DPARSF', 'bet'), fullfile(dpabiRoot, 'DPARSF', 'dcm2nii')};
    toolDirs = toolDirs(cellfun(@(d) exist(d, 'dir') == 7, toolDirs));
    if ~isempty(toolDirs)
        setenv('PATH', [strjoin(toolDirs, ';') ';' getenv('PATH')]);
        fprintf('[工作台] 外部工具 PATH 前置：%s\n', strjoin(toolDirs, '; '));
    else
        fprintf('[工作台] 警告：未找到 DPABI 的 bet/dcm2nii 目录，BET/结构像裁剪可能失败\n');
    end

    % 2) 载入 Cfg
    S = load(cfgFile);
    if isfield(S, 'Cfg')
        Cfg = S.Cfg;
    elseif isfield(S, 'AutoDataProcessParameter')
        Cfg = S.AutoDataProcessParameter;
    else
        error('headlessRunner: 配置文件中没有 Cfg 变量');
    end
    if ~isfield(Cfg, 'DataProcessDir') || isempty(Cfg.DataProcessDir)
        Cfg.DataProcessDir = Cfg.WorkingDir;
    end
    fprintf('[工作台] 工作目录：%s\n', Cfg.WorkingDir);
    fprintf('[工作台] 输出目录：%s\n', Cfg.DataProcessDir);
    fprintf('[工作台] 受试者：%d 名（%s）\n', numel(Cfg.SubjectID), strjoin(Cfg.SubjectID(:)', ', '));
    fprintf('[工作台] 步骤：%s\n', strjoin(mrw.CfgBuilder.summary(Cfg), ' → '));

    % 2b) T1 裁剪兼容（旧版 dcm2nii 真实裁剪 / 免裁剪 c* 直通）
    %     必须在 DPARSFA_run 之前完成：DPABI 的裁剪步骤已改用 dcm2niix（只支持 DICOM），
    %     T1Img 里只有 T1.nii 时不会生成 c*/co*；随后引擎在无界面模式下会因 questdlg
    %     无法弹窗而直接失败（DPARSFA_run.m:1641 附近）。
    try
        [Cfg, t1Msgs] = mrw.T1Compat.apply(Cfg, @(m) fprintf('[工作台] %s\n', m));
        for k = 1:numel(t1Msgs)
            fprintf('[工作台] %s\n', t1Msgs{k});
        end
    catch errT1
        error('T1 裁剪兼容处理失败：%s', errT1.message);
    end
    if isfield(Cfg, 'T1CropCompat')
        Cfg = rmfield(Cfg, 'T1CropCompat');   % 工作台字段，DPARSF 不识别
    end

    % 3) 并行设置
    %    DPARSFA_run 的多个 parfor（最早出现在“删除初始时间点”）在没有并行池时会触发
    %    MATLAB 自动建池，而默认池大小是本机全部核心（本机实测 24 worker）——这会忽略
    %    ParallelWorkersNumber 并抢占内存。因此 N>0 时由这里显式建固定大小的池；
    %    N=0 时关闭自动建池，parfor 串行执行。
    poolWorkers = 0;
    try
        if isfield(Cfg, 'ParallelWorkersNumber') && ~isempty(Cfg.ParallelWorkersNumber)
            poolWorkers = round(double(Cfg.ParallelWorkersNumber));
        end
        if ~isfinite(poolWorkers) || poolWorkers < 0
            poolWorkers = 0;
        end
        ps = parallel.Settings;
        if poolWorkers > 0
            ps.Pool.AutoCreate = false;   % 禁止 parfor 抢先创建默认大小的池
            nCores = feature('numcores');
            nSubj = numel(Cfg.SubjectID);
            if ~isfinite(nCores) || nCores < 1, nCores = 1; end
            capped = min([poolWorkers, nCores, max(nSubj, 1)]);
            if capped < poolWorkers
                fprintf('[工作台] 并行数 %d 超过“物理核心(%d)/被试数(%d)”上限，自动调整为 %d\n', ...
                    poolWorkers, nCores, nSubj, capped);
            end
            poolWorkers = capped;
            if poolWorkers <= 1
                fprintf('[工作台] 并行数 <=1，parfor 串行执行（不创建并行池）\n');
            else
                try
                    oldPool = gcp('nocreate');
                    if ~isempty(oldPool), delete(oldPool); end
                    try
                        pool = parpool('Processes', poolWorkers);
                    catch
                        pool = parpool(poolWorkers);   % 兼容默认 profile 名称不同的环境
                    end
                    fprintf('[工作台] 并行：已创建 %d worker 并行池（物理核心 %d，被试 %d 名）\n', ...
                        pool.NumWorkers, nCores, nSubj);
                catch errPool
                    fprintf('[工作台] 警告：创建 %d worker 并行池失败（%s），改为串行执行\n', ...
                        poolWorkers, errPool.message);
                end
            end
        else
            ps.Pool.AutoCreate = false;
            fprintf('[工作台] 未启用并行（ParallelWorkersNumber=0），parfor 串行执行\n');
        end
    catch errPar
        fprintf('[工作台] 警告：并行设置不可用（%s），按串行执行\n', errPar.message);
    end

    % 4) 初始化 SPM 与工作目录
    try
        spm('defaults', 'fmri');
        spm_jobman('initcfg');
    catch err
        fprintf('[工作台] 警告：SPM 初始化异常（%s），继续尝试运行\n', err.message);
    end
    if exist(Cfg.DataProcessDir, 'dir') == 7
        cd(Cfg.DataProcessDir);
    end

    local_write_status(statusFile, 'running', '正在执行 DPARSFA 预处理…');
    fprintf('[工作台] ---------- 开始调用 DPARSFA_run ----------\n');

    % 5) 执行：完全走 DPABI 官方引擎（与原生 GUI 的 Run 等价）
    %    DPARSFA_run 的第二个输出/第一个输出 Error 可能非空（引擎内部记录但不抛出），
    %    必须显式检查，否则会被误判为成功。
    [ErrorOut, CfgOut] = DPARSFA_run(Cfg, [], [], allowGUI); %#ok<ASGLU>
    if ~isempty(ErrorOut)
        msgs = {};
        if iscell(ErrorOut)
            for k = 1:numel(ErrorOut)
                if ischar(ErrorOut{k}), msgs{end+1} = ErrorOut{k}; end %#ok<AGROW>
            end
        elseif ischar(ErrorOut)
            msgs = {ErrorOut};
        else
            msgs = {'DPARSFA_run 返回非空 Error'};
        end
        fprintf(2, '\n[工作台] DPARSFA_run 返回错误（%d 条）：\n', numel(msgs));
        for k = 1:min(numel(msgs), 20)
            fprintf(2, '  - %s\n', msgs{k});
        end
        error('DPARSFA_run 报告 %d 条错误：%s', numel(msgs), strjoin(msgs(1:min(numel(msgs),3)), '；'));
    end

    elapsed = toc(startTic);
    fprintf('[工作台] ---------- DPARSFA_run 正常返回 ----------\n');
    fprintf('[工作台] 总耗时：%.1f 秒（%.1f 分钟）\n', elapsed, elapsed/60);
    fprintf('[工作台] 结果目录：%s\n', Cfg.DataProcessDir);
    local_write_status(statusFile, 'finished', sprintf('预处理完成，用时 %.1f 分钟', elapsed/60));
    fprintf('[工作台] 状态：finished\n');
catch err
    elapsed = toc(startTic);
    fprintf(2, '\n[工作台] 运行失败：%s\n', err.message);
    try
        for k = 1:min(numel(err.stack), 8)
            fprintf(2, '    at %s (行 %d)\n', err.stack(k).name, err.stack(k).line);
        end
    catch
    end
    local_write_status(statusFile, 'failed', sprintf('%s（用时 %.1f 分钟，详见日志）', err.message, elapsed/60));
    fprintf('[工作台] 状态：failed\n');
end

diary off;
end

% ---------- local helpers ----------
function local_finish_log()
try
    diary off;
catch
end
end

function [ok, dpabiRoot, spmRoot] = local_ensure_paths()
ok = false;
dpabiRoot = '';
spmRoot = '';
try
    mrw.Dpabi.ensurePath();
    dpabiRoot = mrw.Dpabi.root();
    spmRoot = mrw.Dpabi.spmRoot();
    ok = ~isempty(which('DPARSFA_run.m')) && ~isempty(which('spm.m'));
catch
    try
        dpabiRoot = mrw.Dpabi.root();
    catch
    end
end
end

function local_write_status(statusFile, state, message)
try
    st = struct('State', state, 'Message', message, ...
        'UpdatedAt', datestr(now, 'yyyy-mm-dd HH:MM:SS'), 'Pid', feature('getpid'));
    txt = jsonencode(st);
    fid = fopen(statusFile, 'w', 'n', 'UTF-8');
    if fid > 0
        fwrite(fid, txt);
        fclose(fid);
    end
catch
end
end
