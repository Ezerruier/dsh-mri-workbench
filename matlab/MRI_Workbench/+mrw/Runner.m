classdef Runner < handle
% Runner  以独立 MATLAB 进程在后台执行 DPARSFA_run，并实时回传日志/进度
%
% 为什么用独立进程：
%   - DPARSFA_run 长时间运行且会修改 SPM 全局状态，放在 App 进程内会冻结界面；
%   - 独立进程可直接取消（杀进程树），且崩溃不影响工作台；
%   - 日志通过 diary 落盘，App 用 timer 增量读取显示。
%
% 用法:
%   r = mrw.Runner(fullfile(projRoot,'runs'));
%   r.OnLog    = @(txt) fprintf('%s', txt);
%   r.OnStatus = @(st) disp(st.Progress);
%   r.OnFinish = @(st) disp(st.State);
%   r.start(Cfg, struct('RunName','run1','AllowGUI',false));

    properties
        RunRoot = ''
        RunDir = ''
        CfgFile = ''
        LogFile = ''
        StatusFile = ''
        ConsoleLog = ''
        Proc = []
        TimerObj = []
        Running = false
        StartTime = []
        LastLogLen = 0
        LogBuf = ''          % 最近若干日志（供 UI 初次刷新）
        Status = struct()
        Cfg = []
        ExpectedSteps = 1
        SubjectTotal = 0
        Phases = {}
        OnLog = []
        OnStatus = []
        OnFinish = []
    end

    methods

        function obj = Runner(runRoot)
            here = fileparts(mfilename('fullpath'));
            projRoot = fileparts(here);
            if nargin < 1 || isempty(runRoot)
                runRoot = fullfile(projRoot, 'runs');
            end
            obj.RunRoot = runRoot;
            if exist(obj.RunRoot, 'dir') ~= 7
                try, mkdir(obj.RunRoot); catch, end
            end
        end

        function start(obj, Cfg, opts)
            if nargin < 3, opts = struct(); end
            if obj.Running
                error('Runner: 已有正在运行的预处理任务，请先等待或取消。');
            end
            if ~isfield(opts, 'RunName') || isempty(opts.RunName)
                opts.RunName = ['run_' datestr(now, 'yyyymmdd_HHMMSS')];
            end
            if ~isfield(opts, 'AllowGUI'), opts.AllowGUI = false; end

            obj.Cfg = Cfg;
            obj.RunDir = fullfile(obj.RunRoot, opts.RunName);
            if exist(obj.RunDir, 'dir') ~= 7
                mkdir(obj.RunDir);
            end
            obj.CfgFile = fullfile(obj.RunDir, 'Cfg.mat');
            obj.LogFile = fullfile(obj.RunDir, 'run.log');
            obj.StatusFile = fullfile(obj.RunDir, 'status.json');
            obj.ConsoleLog = fullfile(obj.RunDir, 'matlab_console.log');

            % 保存 Cfg（含 State/Meta，便于复用与导入原生 DPARSFA）
            try
                mrw.CfgBuilder.saveCfg(Cfg, obj.CfgFile);
            catch
                S = struct('Cfg', Cfg);
                save(obj.CfgFile, '-struct', 'S');
            end

            % 初始状态文件
            st = struct('State', 'running', 'Message', '正在启动后台 MATLAB 进程…', ...
                'StartedAt', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
                'FinishedAt', '', 'Elapsed', 0, 'Pid', 0, ...
                'CfgFile', obj.CfgFile, 'LogFile', obj.LogFile);
            obj.writeStatusFile(st);
            obj.Status = st;

            % 创建日志文件（diary 会覆盖写；这里先确保父目录与空文件存在）
            fid = fopen(obj.LogFile, 'w');
            if fid > 0, fclose(fid); end

            obj.ExpectedSteps = max(1, mrw.CfgBuilder.estimateSteps(Cfg));
            obj.SubjectTotal = numel(Cfg.SubjectID);
            obj.Phases = {};
            obj.LastLogLen = 0;
            obj.LogBuf = '';
            obj.StartTime = tic;

            % 启动独立 MATLAB 进程
            projRoot = fileparts(fileparts(mfilename('fullpath')));
            ps = mrw.Runner.projectRoot();
            stmt = sprintf('addpath(''%s''); mrw.headlessRunner(''%s'',''%s'',''%s'',%d);', ...
                mrw.Runner.esc(ps), mrw.Runner.esc(obj.CfgFile), ...
                mrw.Runner.esc(obj.LogFile), mrw.Runner.esc(obj.StatusFile), ...
                double(logical(opts.AllowGUI)));
            matlabExe = fullfile(matlabroot, 'bin', 'matlab.exe');
            if exist(matlabExe, 'file') ~= 2
                matlabExe = fullfile(matlabroot, 'bin', 'matlab');
            end
            args = sprintf('-batch "%s" -logfile "%s"', stmt, mrw.Runner.esc(obj.ConsoleLog));

            try
                psi = System.Diagnostics.ProcessStartInfo();
                psi.FileName = matlabExe;
                psi.Arguments = args;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden;
                psi.WorkingDirectory = projRoot;
                obj.Proc = System.Diagnostics.Process.Start(psi);
            catch err
                obj.Running = false;
                st = obj.Status;
                st.State = 'failed';
                st.Message = sprintf('无法启动后台 MATLAB 进程：%s', err.message);
                st.FinishedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
                obj.writeStatusFile(st);
                obj.Status = st;
                if ~isempty(obj.OnFinish), obj.OnFinish(st); end
                return;
            end

            try
                st.Pid = double(obj.Proc.Id);
            catch
            end
            st.Message = '后台 MATLAB 进程已启动，正在初始化 DPABI…';
            obj.writeStatusFile(st);
            obj.Status = st;
            obj.Running = true;
            if ~isempty(obj.OnLog)
                obj.OnLog(sprintf('[工作台] 已启动后台 MATLAB（PID %d）\n[工作台] 运行目录：%s\n', ...
                    st.Pid, obj.RunDir));
            end

            % 定时读取日志/状态
            obj.TimerObj = timer('ExecutionMode', 'fixedSpacing', 'Period', 1.0, ...
                'BusyMode', 'drop', 'TimerFcn', @(t, e) obj.tick(), ...
                'Name', 'mrwRunnerTimer');
            start(obj.TimerObj);
            obj.tick();
        end

        function cancel(obj)
            if ~obj.Running
                return;
            end
            try
                pid = double(obj.Proc.Id);
                system(sprintf('taskkill /PID %d /T /F', pid));
            catch
                try, obj.Proc.Kill(); catch, end
            end
            obj.stopTimer();
            st = obj.Status;
            st.State = 'cancelled';
            st.Message = '用户已取消运行（后台进程已终止）';
            st.FinishedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
            st.Elapsed = toc(obj.StartTime);
            obj.writeStatusFile(st);
            obj.Status = st;
            obj.Running = false;
            if ~isempty(obj.OnLog), obj.OnLog('\n[工作台] 已取消运行。\n'); end
            if ~isempty(obj.OnFinish), obj.OnFinish(st); end
        end

        function st = getStatus(obj)
            st = obj.Status;
            if isempty(st)
                st = struct('State', 'idle', 'Message', '空闲', 'Progress', 0);
                return;
            end
            if obj.Running
                st.Elapsed = toc(obj.StartTime);
            end
            if ~isfield(st, 'Progress')
                st.Progress = 0;
            end
            if ~isfield(st, 'Phases'), st.Phases = obj.Phases; end
            st.SubjectTotal = obj.SubjectTotal;
        end

        function delete(obj)
            obj.stopTimer();
        end
    end

    methods (Access = private)

        function tick(obj)
            if isempty(obj.Proc)
                return;
            end
            % 1) 增量读取日志
            try
                newTxt = obj.readNewLog();
                if ~isempty(newTxt)
                    obj.LogBuf = [obj.LogBuf newTxt];
                    if numel(obj.LogBuf) > 200000
                        obj.LogBuf = obj.LogBuf(end-100000:end);
                    end
                    obj.parseProgress(newTxt);
                    if ~isempty(obj.OnLog), obj.OnLog(newTxt); end
                end
            catch
            end

            % 2) 读取进程退出码
            exited = false;
            exitCode = NaN;
            try
                exited = obj.Proc.HasExited;
                if exited, exitCode = double(obj.Proc.ExitCode); end
            catch
                exited = true;
            end

            % 3) 读取状态文件（进程可能已写完最终状态）
            diskSt = obj.readStatusFile();

            if ~exited
                st = obj.Status;
                if ~isempty(diskSt) && isfield(diskSt, 'State')
                    if ~strcmp(diskSt.State, 'running')
                        st = diskSt;
                    elseif isfield(diskSt, 'Message') && ~isempty(diskSt.Message)
                        st.Message = diskSt.Message;
                    end
                end
                st.Running = true;
                st.Elapsed = toc(obj.StartTime);
                st.Progress = obj.computeProgress();
                st.Phases = obj.Phases;
                st.SubjectTotal = obj.SubjectTotal;
                obj.Status = st;
                if ~isempty(obj.OnStatus), obj.OnStatus(st); end
                return;
            end

            % 4) 进程已退出：确定最终状态
            obj.stopTimer();
            try, clear obj.Proc; catch, end
            obj.Proc = [];
            st = struct();
            if ~isempty(diskSt)
                st = diskSt;
            end
            if ~isfield(st, 'State') || isempty(st.State)
                st.State = 'finished';
            end
            if ~isfield(st, 'Message') || isempty(st.Message)
                st.Message = '流程结束';
            end
            if strcmp(st.State, 'running') || isempty(st.State)
                if ~isnan(exitCode) && exitCode == 0
                    st.State = 'finished';
                    st.Message = '后台进程正常退出';
                else
                    st.State = 'failed';
                    st.Message = sprintf('后台进程异常退出（exit code %g），请查看日志', exitCode);
                end
            end
            st.FinishedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
            st.Elapsed = toc(obj.StartTime);
            st.Progress = 1.0;
            st.Phases = obj.Phases;
            st.SubjectTotal = obj.SubjectTotal;
            obj.Status = st;
            obj.Running = false;
            obj.writeStatusFile(st);
            % 读最后一段日志
            try
                newTxt = obj.readNewLog();
                if ~isempty(newTxt)
                    obj.LogBuf = [obj.LogBuf newTxt];
                    if ~isempty(obj.OnLog), obj.OnLog(newTxt); end
                end
            catch
            end
            if ~isempty(obj.OnStatus), obj.OnStatus(st); end
            if ~isempty(obj.OnFinish), obj.OnFinish(st); end
        end

        function parseProgress(obj, newTxt) %#ok<INUSD>
            % DPARSFA 的进度输出经常不带换行（如 "Realign Setup:Sub01 OKRealign Setup:Sub02 OK"），
            % 因此对累计日志做全局匹配，而不是按行解析。
            txt = obj.LogBuf;
            if numel(txt) > 400000
                txt = txt(end-200000:end);
            end
            toks = regexp(txt, '([^\r\n:]{3,100}?):\s*([^\s:]{1,80})\s+OK', 'tokens');
            phases = {};
            for i = 1:numel(toks)
                ph = strtrim(toks{i}{1});
                if isempty(ph), continue; end
                if ~any(strcmp(phases, ph))
                    phases{end+1} = ph; %#ok<AGROW>
                end
            end
            obj.Phases = phases;
        end

        function p = computeProgress(obj)
            nPh = numel(obj.Phases);
            nExp = max(1, obj.ExpectedSteps);
            p = min(0.98, nPh / nExp);
            if obj.SubjectTotal > 0 && nPh > 0
                p = min(0.98, max(p, 0.05));
            end
        end

        function txt = readNewLog(obj)
            txt = '';
            if exist(obj.LogFile, 'file') ~= 2
                return;
            end
            try
                full = fileread(obj.LogFile);
            catch
                return;
            end
            if numel(full) <= obj.LastLogLen
                return;
            end
            txt = full(obj.LastLogLen+1:end);
            obj.LastLogLen = numel(full);
        end

        function st = readStatusFile(obj)
            st = [];
            if exist(obj.StatusFile, 'file') ~= 2
                return;
            end
            try
                txt = fileread(obj.StatusFile);
                st = jsondecode(txt);
            catch
                st = [];
            end
        end

        function writeStatusFile(obj, st)
            try
                if ~isfield(st, 'Progress') || isempty(st.Progress), st.Progress = 0; end
                txt = jsonencode(st);
                fid = fopen(obj.StatusFile, 'w', 'n', 'UTF-8');
                if fid > 0
                    fwrite(fid, txt);
                    fclose(fid);
                end
            catch
            end
        end

        function stopTimer(obj)
            try
                if ~isempty(obj.TimerObj) && isvalid(obj.TimerObj)
                    stop(obj.TimerObj);
                    delete(obj.TimerObj);
                end
            catch
            end
            obj.TimerObj = [];
        end
    end

    methods (Static)

        function root = projectRoot()
            here = fileparts(mfilename('fullpath'));   % +mrw
            root = fileparts(here);                     % MRI_Workbench
        end

        function s = esc(s)
            % 转义单引号，供 MATLAB 语句中的字符串字面量使用
            s = strrep(s, '''', '''''');
        end

        function st = lastStatus(runDir)
            st = [];
            f = fullfile(runDir, 'status.json');
            if exist(f, 'file') == 2
                try
                    st = jsondecode(fileread(f));
                catch
                end
            end
        end

        function L = listRuns(runRoot)
            % 列出运行目录（按时间倒序），返回 struct array: Name, Dir, Time, State, Message
            if nargin < 1 || isempty(runRoot)
                root0 = fileparts(fileparts(mfilename('fullpath')));
                runRoot = fullfile(root0, 'runs');
            end
            L = struct('Name', {}, 'Dir', {}, 'Time', {}, 'State', {}, 'Message', {});
            if exist(runRoot, 'dir') ~= 7, return; end
            d = dir(runRoot);
            for i = 1:numel(d)
                if ~d(i).isdir || strcmp(d(i).name, '.') || strcmp(d(i).name, '..')
                    continue;
                end
                e.Name = d(i).name;
                e.Dir = fullfile(runRoot, d(i).name);
                e.Time = datestr(d(i).datenum, 'yyyy-mm-dd HH:MM:SS');
                st = mrw.Runner.lastStatus(e.Dir);
                if isempty(st)
                    e.State = 'unknown';
                    e.Message = '';
                else
                    e.State = st.State;
                    if isfield(st, 'Message'), e.Message = st.Message; else, e.Message = ''; end
                end
                L(end+1) = e; %#ok<AGROW>
            end
            if ~isempty(L)
                [~, idx] = sort([d(3:end).datenum], 'descend');
                L = L(idx);
            end
        end
    end
end
