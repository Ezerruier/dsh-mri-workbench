classdef NativeLaunch
% NativeLaunch  从代码打开原生 DPABI / DPARSF 界面，并自动汉化新出现的窗口
%
% DPABI 的界面文件（.fig）与加密回调（.p）不能改动；本类只调用官方 .fig / 官方函数
% 打开窗口，然后在图窗出现后用 mrw.NativePatch 动态汉化 + 加中文悬停说明。
%
% 用法：
%   addpath('C:\...\MRI_Workbench');
%   mrw.NativeLaunch.openDPABI();          % 打开 DPABI 主界面（自动汉化 + 监视子窗口）
%   mrw.NativeLaunch.openDPARSFMain();     % 打开 DPARSF（经典版）入口
%   mrw.NativeLaunch.openDPARSFA();                     % 打开 DPARSFA 空白界面
%   mrw.NativeLaunch.openDPARSFA('Template_Blank');      % 打开 DPARSFA 并载入模板
%   mrw.NativeLaunch.stopPatchMonitor();   % 停掉自动监视（30 秒后也会自动停）
%
% 自动监视：打开窗口后启动一个 timer（默认 30 秒，每 0.5 秒扫描一次），对新出现的
% 原生窗口自动调用 mrw.NativePatch.patchAll()。这样即使用户接着点开 DPARSFA 的
% 子界面（Nuisance Setting、FieldMap、ROI Templates、Scrubbing 等），也会被自动汉化。
% 可用 'AutoMonitor', false 关闭；用 startPatchMonitor(seconds) 手动启动。
%
% 说明：
%   * 打开 dpabi / DPARSF_main 使用 openfig + 手动补 logo，避免 dpabi.m OpeningFcn
%     的在线版本检查（webread）在无网络时拖慢启动；callbacks 仍由官方 .m 提供，功能不变。
%   * openDPARSFA 调用官方 DPARSFA(.p)（可能内部 uiwait），因此先启动监视 timer，
%     以便在等待期间汉化新窗口。
%   * 不写入 DPABI 安装目录。

    methods (Static)

        % ================================================================
        % 打开原生界面
        % ================================================================

        function fig = openDPABI(varargin)
            % openDPABI()  打开（或激活已有的）DPABI 主界面并汉化。
            op = mrw.NativeLaunch.parseOpenOpts(varargin{:});
            fig = mrw.NativeLaunch.openNativeFigure('dpabi', 'DPABI', op);
        end

        function fig = openDPARSFMain(varargin)
            % openDPARSFMain()  打开（或激活已有的）DPARSF 经典版入口并汉化。
            op = mrw.NativeLaunch.parseOpenOpts(varargin{:});
            fig = mrw.NativeLaunch.openNativeFigure('DPARSF_main', 'DPARSF', op);
        end

        function fig = openDPARSFA(templateName, varargin)
            % openDPARSFA([templateName])  打开 DPARSFA 高级版界面并汉化。
            %
            % templateName 可为：空（空白界面）、模板短名（如 'Template_Blank'、
            % 'Template_VBM_NewSegmentDARTEL'）或 .mat 完整路径。
            %
            % 注意：DPARSFA(.p) 内部可能使用 uiwait 等待用户关闭窗口，因此本函数在调用
            % 官方函数前就启动 patch 监视器；函数返回时窗口可能已被关闭。
            if nargin < 1, templateName = ''; end
            op = mrw.NativeLaunch.parseOpenOpts(varargin{:});

            % 已经打开：直接激活 + 汉化
            fig = mrw.NativeLaunch.findOpenFigure('DPARSFA');
            if ~isempty(fig)
                try
                    mrw.NativePatch.patchFigure(fig);
                    figure(fig);
                catch
                end
                if op.AutoMonitor, mrw.NativeLaunch.startPatchMonitor(op.MonitorSeconds); end
                return;
            end

            if op.AutoMonitor
                mrw.NativeLaunch.startPatchMonitor(op.MonitorSeconds);
            end

            try
                if isempty(templateName)
                    mrw.NativeLaunch.callDPARSFA();
                else
                    tp = mrw.NativeLaunch.resolveTemplate(templateName);
                    mrw.NativeLaunch.callDPARSFA(tp);
                end
            catch ME
                % 启动失败：别让监视器空转，保留原始错误上下文
                if op.AutoMonitor
                    mrw.NativeLaunch.stopPatchMonitor();
                end
                rethrow(ME);
            end

            % 官方函数返回后再补一次（无 uiwait 时窗口已经就绪）
            try
                mrw.NativePatch.patchAll('Silent', true);
            catch
            end
            fig = mrw.NativeLaunch.findOpenFigure('DPARSFA');
            if ~op.Silent && ~isempty(fig)
                fprintf('[NativeLaunch] 已打开 DPARSFA 界面，自动汉化完成。\n');
            end
        end

        % ================================================================
        % Patch 监视器（timer）
        % ================================================================

        function t = startPatchMonitor(seconds, varargin)
            % startPatchMonitor(seconds)  启动新图窗自动汉化监视；seconds 默认 30。
            if nargin < 1 || isempty(seconds), seconds = 30; end
            seconds = max(1, min(600, double(seconds)));
            tag = 'mrwNativePatchMonitor';
            mrw.NativeLaunch.stopPatchMonitor();
            t = timer('Tag', tag, 'Name', 'mrw Native Patch Monitor', ...
                'ExecutionMode', 'fixedRate', 'Period', 0.5, ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(obj, evt) mrw.NativeLaunch.monitorTick(obj), ... %#ok<INUSD>
                'ErrorFcn', @(obj, evt) mrw.NativeLaunch.monitorAfterError(obj), ...
                'UserData', struct('StartClock', clock, 'Duration', seconds));
            try
                set(t, 'StopFcn', @(obj, evt) mrw.NativeLaunch.deleteMonitor(obj)); %#ok<INUSD>
            catch
            end
            start(t);
        end

        function n = stopPatchMonitor()
            % stopPatchMonitor()  停掉并删除监视器；返回被清理的 timer 个数。
            n = 0;
            try
                ts = timerfindall('Tag', 'mrwNativePatchMonitor');
                for k = 1:numel(ts)
                    try, stop(ts(k)); catch, end
                    try, delete(ts(k)); catch, end
                    n = n + 1;
                end
            catch
            end
        end

        function tf = isPatchMonitorRunning()
            % isPatchMonitorRunning()  监视器是否在运行。
            tf = false;
            try
                ts = timerfindall('Tag', 'mrwNativePatchMonitor');
                for k = 1:numel(ts)
                    if strcmp(get(ts(k), 'Running'), 'on')
                        tf = true;
                        return;
                    end
                end
            catch
            end
        end

        function monitorTick(t)
            % monitorTick(t)  timer 回调：定期 patchAll，到时自动停止（内部使用）。
            try
                if isempty(t) || ~isvalid(t), return; end
                ud = get(t, 'UserData');
                if ~isstruct(ud) || ~isfield(ud, 'StartClock'), return; end
                if etime(clock, ud.StartClock) >= ud.Duration
                    mrw.NativeLaunch.stopPatchMonitor();
                    return;
                end
                mrw.NativePatch.patchAll('Silent', true);
            catch
                % 监视器出错绝不能影响用户界面
            end
        end

        % ================================================================
        % 辅助
        % ================================================================

        function p = dpabiRoot()
            % dpabiRoot()  返回 DPABI 安装目录（优先 which('dpabi.m')）。
            persistent cache
            if ~isempty(cache), p = cache; return; end
            cands = {};
            try
                w = which('dpabi.m');
                if ~isempty(w), cands{end+1} = fileparts(w); end
            catch
            end
            env = getenv('DPABI_HOME');
            if ~isempty(env), cands{end+1} = env; end
            cands = [cands, {'D:\Software\DPABI', 'C:\Program Files\DPABI', ...
                'C:\DPABI', 'D:\DPABI'}];
            for k = 1:numel(cands)
                try
                    if exist(fullfile(cands{k}, 'dpabi.fig'), 'file') == 2
                        cache = cands{k};
                        p = cache;
                        return;
                    end
                catch
                end
            end
            error('mrw:NativeLaunch:noDPABI', ...
                ['找不到 DPABI 安装目录。请先把 DPABI 加入 MATLAB 路径 ' ...
                 '（保证 which(''dpabi.m'') 可解析），或设置环境变量 DPABI_HOME。']);
        end

        function fp = figureFile(key)
            % figureFile(key)  原生窗口标识 -> .fig 绝对路径。
            root = mrw.NativeLaunch.dpabiRoot();
            switch char(key)
                case 'dpabi'
                    fp = fullfile(root, 'dpabi.fig');
                case 'DPARSF_main'
                    fp = fullfile(root, 'DPARSF', 'DPARSF_main.fig');
                case 'DPARSF'
                    fp = fullfile(root, 'DPARSF', 'DPARSF.fig');
                case 'DPARSFA'
                    fp = fullfile(root, 'DPARSF', 'DPARSFA.fig');
                case 'DPARSF_FieldMap'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'DPARSF_FieldMap.fig');
                case 'DPARSF_NuisanceSetting'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'DPARSF_NuisanceSetting.fig');
                case 'DPARSF_ROI_Template'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'DPARSF_ROI_Template.fig');
                case 'DPARSF_ScrubbingSetting_gui'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'DPARSF_ScrubbingSetting_gui.fig');
                case 'ReorientThreQC'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'ReorientThreQC.fig');
                case 'DPARSF_ChooseGUI'
                    fp = fullfile(root, 'DPARSF', 'SubGUIs', 'DPARSF_ChooseGUI.fig');
                otherwise
                    error('mrw:NativeLaunch:badKey', '未知原生窗口标识：%s', char(key));
            end
        end

        function figs = findOpenFigure(key)
            % findOpenFigure(key)  查找已打开的原生窗口（按 tag/标题识别）。
            figs = [];
            try
                hs = findall(groot, 'Type', 'figure');
                for k = numel(hs):-1:1
                    h = hs(k);
                    try
                        if isvalid(h) && strcmp(mrw.NativePatch.keyForFigure(h), char(key))
                            figs = h;
                            return;
                        end
                    catch
                    end
                end
            catch
            end
        end

        function names = templates()
            % templates()  列出 DPARSF/Jobmats 下可用模板短名（不含 .mat）。
            names = {};
            try
                d = fullfile(mrw.NativeLaunch.dpabiRoot(), 'DPARSF', 'Jobmats');
                fs = dir(fullfile(d, 'Template_*.mat'));
                for k = 1:numel(fs)
                    [~, nm] = fileparts(fs(k).name);
                    names{end+1} = nm; %#ok<AGROW>
                end
                names = sort(names);
            catch
                names = {};
            end
        end
    end

    methods (Static, Access = private)

        function op = parseOpenOpts(varargin)
            p = inputParser;
            p.addParameter('AutoMonitor', true, @(x) islogical(x) || isnumeric(x));
            p.addParameter('MonitorSeconds', 30, @(x) isnumeric(x) && isscalar(x));
            p.addParameter('Silent', false, @(x) islogical(x) || isnumeric(x));
            p.parse(varargin{:});
            op = struct('AutoMonitor', logical(p.Results.AutoMonitor), ...
                'MonitorSeconds', double(p.Results.MonitorSeconds), ...
                'Silent', logical(p.Results.Silent));
        end

        function fig = openNativeFigure(key, windowTitle, op)
            % 已打开则激活；否则 openfig + 补 logo + 汉化 + 启动监视器。
            fig = mrw.NativeLaunch.findOpenFigure(key);
            if ~isempty(fig)
                try, figure(fig); catch, end
                try, mrw.NativePatch.patchFigure(fig); catch, end
                if op.AutoMonitor
                    mrw.NativeLaunch.startPatchMonitor(op.MonitorSeconds);
                end
                return;
            end

            fp = mrw.NativeLaunch.figureFile(key);
            if exist(fp, 'file') ~= 2
                error('mrw:NativeLaunch:missingFig', '找不到界面文件：%s', fp);
            end
            fig = openfig(fp, 'new', 'visible');
            drawnow;
            try, set(fig, 'Name', windowTitle); catch, end
            try, movegui(fig, 'center'); catch, end

            % 原 OpeningFcn 会显示 Logo；openfig 不执行它，这里补上（失败无妨）
            try
                switch key
                    case 'dpabi'
                        mrw.NativeLaunch.paintLogo(fig, fullfile(mrw.NativeLaunch.dpabiRoot(), 'Logo', 'dpabi.png'));
                    case 'DPARSF_main'
                        mrw.NativeLaunch.paintLogo(fig, fullfile(mrw.NativeLaunch.dpabiRoot(), 'Logo', 'DPARSF.png'));
                end
            catch
            end

            try
                s = mrw.NativePatch.patchFigure(fig);
                if ~op.Silent
                    fprintf(['[NativeLaunch] 已打开 %s：翻译 %d 个控件、Tooltip %d 个' ...
                        '（窗口标题：%s）。\n'], key, s.Translated, s.Tooltips, ...
                        char(mrw.NativeLaunch.safeName(fig)));
                end
            catch
            end

            if op.AutoMonitor
                mrw.NativeLaunch.startPatchMonitor(op.MonitorSeconds);
            end
        end

        function paintLogo(fig, logoPath)
            if exist(logoPath, 'file') ~= 2, return; end
            ax = findobj(fig, 'Tag', 'axes_logo');
            if isempty(ax), ax = findobj(fig, 'Type', 'axes'); end
            if isempty(ax), return; end
            ax = ax(1);
            try
                [A, map, alpha] = imread(logoPath); %#ok<ASGLU>
            catch
                return;
            end
            try
                old = get(groot, 'CurrentFigure'); %#ok<NASGU>
            catch
            end
            try
                axes(ax); %#ok<LAXES>
                h = imshow(A, map);
                if ~isempty(alpha)
                    try, set(h, 'AlphaData', alpha); catch, end
                end
                try, set(ax, 'XTick', [], 'YTick', [], 'Box', 'off'); catch, end
            catch
                % 没有 Image Processing Toolbox / imshow 出错时忽略
            end
        end

        function tp = resolveTemplate(templateName)
            % 模板短名/文件名 -> Jobmats 下 .mat 绝对路径
            % 兼容 'Template_Blank' / 'Template_Blank.mat' / 'Blank' / 'VBM_NewSegmentDARTEL'
            nm = char(templateName);
            if exist(nm, 'file') == 2
                tp = nm;
                return;
            end
            base = regexprep(nm, '\.mat$', '');
            d = fullfile(mrw.NativeLaunch.dpabiRoot(), 'DPARSF', 'Jobmats');
            cands = {fullfile(d, [base '.mat'])};
            if isempty(regexp(base, '^Template_', 'once'))
                cands{end+1} = fullfile(d, ['Template_' base '.mat']);
            end
            for k = 1:numel(cands)
                if exist(cands{k}, 'file') == 2
                    tp = cands{k};
                    return;
                end
            end
            lst = mrw.NativeLaunch.templates();
            error('mrw:NativeLaunch:noTemplate', ...
                '找不到模板 %s。可用模板：%s', nm, strjoin(lst, ', '));
        end

        function callDPARSFA(templatePath)
            % 调用官方 DPARSFA（加密 .p）；不存在时给出清晰错误。
            if exist('DPARSFA', 'file') ~= 2
                error('mrw:NativeLaunch:noDPARSFA', ...
                    ['MATLAB 路径上找不到 DPARSFA（DPABI 的 DPARSF 目录是否已加入路径？）。' ...
                     '请先 addpath 加入 DPABI 根目录及其 DPARSF 子目录。']);
            end
            if nargin >= 1 && ~isempty(templatePath)
                feval('DPARSFA', templatePath);
            else
                feval('DPARSFA');
            end
        end

        function deleteMonitor(t)
            % StopFcn：删除 timer 自身（避免残留）
            try
                if ~isempty(t) && isvalid(t)
                    delete(t);
                end
            catch
            end
        end

        function monitorAfterError(t)
            try
                mrw.NativeLaunch.stopPatchMonitor();
                delete(t);
            catch
            end
        end

        function nm = safeName(fig)
            nm = '';
            try
                nm = char(get(fig, 'Name'));
            catch
            end
        end
    end
end
