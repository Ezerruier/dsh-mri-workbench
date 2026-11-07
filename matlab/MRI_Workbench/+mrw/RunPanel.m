classdef RunPanel < handle
% RunPanel  “运行与日志”页面：运行前检查、启动/取消、进度条、实时日志
%
% 用法：
%   p = mrw.RunPanel(parent, callbacks)
%   callbacks 字段（function handle，均可省略）:
%     OnStart        开始运行
%     OnCancel       取消运行
%     OnCheck        运行前检查
%     OnSaveCfg      保存配置
%     OnLoadCfg      导入配置
%     OnOpenOutput   打开输出目录
%     OnOpenRunDir   打开运行目录

    properties (Access = private)
        Parent
        Cb = struct()
        SummaryArea
        CheckList
        StatusLabel
        ProgressLabel
        ElapsedLabel
        LogArea
        RunDir = ''
        RunDirLabel
        StartBtn
        CancelBtn
        Running = false
        Progress = 0
        LogLines = {}
    end

    methods

        function obj = RunPanel(parent, callbacks)
            obj.Parent = parent;
            if nargin >= 2 && isstruct(callbacks)
                obj.Cb = callbacks;
            end
            obj.buildUI();
        end

        function setSummary(obj, txt)
            if ischar(txt), txt = {txt}; end
            if isempty(txt), txt = {''}; end
            obj.SummaryArea.Value = txt;
        end

        function setChecks(obj, rep)
            % rep: mrw.CfgBuilder.validate 的返回值
            items = {};
            if isstruct(rep) && isfield(rep, 'checks')
                for i = 1:numel(rep.checks)
                    c = rep.checks(i);
                    switch c.Level
                        case 'error', pre = '[错误] ';
                        case 'warn',  pre = '[提醒] ';
                        otherwise,    pre = '[通过] ';
                    end
                    items{end+1} = [pre c.Name '：' c.Message]; %#ok<AGROW>
                end
            end
            if isempty(items)
                items = {'（尚未检查）'};
            end
            obj.CheckList.Items = items;
            try
                obj.CheckList.Value = items{1};
            catch
                obj.CheckList.Value = 1;
            end
            if isstruct(rep) && isfield(rep, 'ok') && ~rep.ok
                obj.StatusLabel.Text = '配置存在错误，请先修正';
                obj.StatusLabel.FontColor = mrw.UiKit.colors().err;
            else
                obj.StatusLabel.Text = '配置检查通过，可以开始运行';
                obj.StatusLabel.FontColor = mrw.UiKit.colors().ok;
            end
        end

        function setRunning(obj, tf)
            obj.Running = logical(tf);
            if tf
                obj.StartBtn.Enable = 'off';
                obj.CancelBtn.Enable = 'on';
                obj.Progress = 0;
                obj.setProgress(0, '正在启动后台进程…');
                obj.ElapsedLabel.Text = '已用时：0 秒';
            else
                obj.StartBtn.Enable = 'on';
                obj.CancelBtn.Enable = 'off';
            end
        end

        function setProgress(obj, frac, msg)
            frac = max(0, min(1, double(frac)));
            obj.Progress = frac;
            n = 24;
            filled = round(frac * n);
            bar = [repmat(char(9608), 1, filled) repmat(char(9617), 1, n-filled)];
            color = mrw.UiKit.colors().accent;
            if frac >= 1
                obj.ProgressLabel.Text = sprintf('%s  100%%', bar);
                obj.ProgressLabel.FontColor = mrw.UiKit.colors().ok;
            else
                obj.ProgressLabel.Text = sprintf('%s  %d%%', bar, round(frac*100));
                obj.ProgressLabel.FontColor = color;
            end
            if nargin >= 3 && ~isempty(msg)
                obj.StatusLabel.Text = msg;
                obj.StatusLabel.FontColor = mrw.UiKit.colors().text;
            end
        end

        function setStatus(obj, st)
            if ~isstruct(st) || ~isfield(st, 'State'), return; end
            switch st.State
                case 'running'
                    obj.StatusLabel.FontColor = mrw.UiKit.colors().accentDark;
                case 'finished'
                    obj.StatusLabel.FontColor = mrw.UiKit.colors().ok;
                case {'failed', 'cancelled'}
                    obj.StatusLabel.FontColor = mrw.UiKit.colors().err;
            end
            msg = st.Message;
            if isfield(st, 'Phases') && ~isempty(st.Phases)
                msg = sprintf('%s（当前阶段：%s）', msg, st.Phases{end});
            end
            obj.StatusLabel.Text = msg;
            if isfield(st, 'Progress')
                obj.setProgress(st.Progress, '');
            end
            if isfield(st, 'Elapsed')
                obj.ElapsedLabel.Text = ['已用时：' mrw.UiKit.fmtSeconds(st.Elapsed)];
            end
        end

        function appendLog(obj, txt)
            if isempty(txt), return; end
            lines = regexp(txt, '\r\n|\n|\r', 'split');
            if ~isempty(lines) && isempty(lines{end})
                lines(end) = [];
            end
            obj.LogLines = [obj.LogLines, lines];
            if numel(obj.LogLines) > 4000
                obj.LogLines = obj.LogLines(end-2000:end);
            end
            obj.LogArea.Value = obj.LogLines;
            try
                scroll(obj.LogArea, 'bottom');
            catch
                try
                    obj.LogArea.Value = obj.LogLines;
                catch
                end
            end
        end

        function clearLog(obj)
            obj.LogLines = {};
            obj.LogArea.Value = {''};
        end

        function setRunDir(obj, d)
            obj.RunDir = d;
            try
                if ~isempty(d)
                    obj.RunDirLabel.Text = ['日志文件：' fullfile(d, 'run.log')];
                end
            catch
            end
        end

        function refreshElapsed(obj, sec)
            obj.ElapsedLabel.Text = ['已用时：' mrw.UiKit.fmtSeconds(sec)];
        end
    end

    methods (Access = private)

        function buildUI(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            g = uigridlayout(obj.Parent, [4 1]);
            g.RowHeight = {128, 150, 'fit', '1x'};
            g.Padding = [12 12 12 12];
            g.RowSpacing = 10;
            g.BackgroundColor = c.bg;

            % --- 方案摘要 ---
            p1 = mrw.UiKit.card(g, '当前预处理方案（由左侧参数面板实时生成）');
            g1 = uigridlayout(p1, [1 1]);
            g1.Padding = [10 8 10 8];
            g1.BackgroundColor = c.panel;
            obj.SummaryArea = uitextarea(g1, 'Editable', 'off', ...
                'FontName', f.name, 'FontSize', f.base, 'BackgroundColor', c.panelAlt, ...
                'Value', {'（请在“预处理参数”页配置）'});

            % --- 检查结果 ---
            p2 = mrw.UiKit.card(g, '运行前检查');
            gl2 = uigridlayout(p2, [1 2]);
            gl2.ColumnWidth = {'1x', 150};
            gl2.Padding = [10 8 10 8];
            gl2.BackgroundColor = c.panel;
            obj.CheckList = uilistbox(gl2, 'Items', {'（尚未检查）'}, 'FontName', f.name, ...
                'FontSize', f.small, 'ValueChangedFcn', @(s, e) obj.showCheckDetail());
            box2 = uigridlayout(gl2, [5 1]);
            box2.RowHeight = {'fit', 'fit', 'fit', 'fit', '1x'};
            box2.Padding = [0 0 0 0];
            box2.BackgroundColor = c.panel;
            obj.StatusLabel = uilabel(box2, 'Text', '尚未检查', 'FontName', f.name, ...
                'FontSize', f.base, 'FontWeight', 'bold');
            obj.ProgressLabel = uilabel(box2, 'Text', '', 'FontName', f.mono, ...
                'FontSize', f.base, 'FontColor', c.accent);
            obj.ElapsedLabel = uilabel(box2, 'Text', '已用时：--', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);
            b1 = uibutton(box2, 'Text', '运行前检查', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnCheck'));
            b2 = uibutton(box2, 'Text', '保存配置…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnSaveCfg'));
            btnGrid = uigridlayout(box2, [1 2]);
            btnGrid.Padding = [0 0 0 0];
            btnGrid.ColumnWidth = {'1x', '1x'};
            btnGrid.BackgroundColor = c.panel;
            b1.Parent = btnGrid;
            b2.Parent = btnGrid;

            % --- 运行控制 ---
            p3 = mrw.UiKit.card(g, '运行控制');
            gl3 = uigridlayout(p3, [1 6]);
            gl3.ColumnWidth = {130, 130, 130, 130, 120, '1x'};
            gl3.Padding = [10 8 10 8];
            gl3.BackgroundColor = c.panel;
            obj.StartBtn = uibutton(gl3, 'Text', [mrw.UiKit.glyphs().run ' 开始预处理'], ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.accent, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnStart'));
            obj.CancelBtn = uibutton(gl3, 'Text', [mrw.UiKit.glyphs().stop ' 取消运行'], ...
                'FontName', f.name, 'FontSize', f.base, 'Enable', 'off', ...
                'BackgroundColor', [1 1 1], 'FontColor', c.err, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnCancel'));
            uibutton(gl3, 'Text', '导入配置…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnLoadCfg'));
            uibutton(gl3, 'Text', '打开输出目录', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnOpenOutput'));
            uibutton(gl3, 'Text', '打开人工QC', 'FontName', f.name, ...
                'BackgroundColor', c.ok, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnOpenQC'));

            % --- 日志 ---
            p4 = mrw.UiKit.card(g, '运行日志（DPARSFA 引擎实时输出）');
            gl4 = uigridlayout(p4, [2 1]);
            gl4.RowHeight = {'1x', 'fit'};
            gl4.Padding = [10 8 10 8];
            gl4.BackgroundColor = c.panel;
            obj.LogArea = uitextarea(gl4, 'Editable', 'off', 'FontName', f.mono, ...
                'FontSize', 11, 'BackgroundColor', [0.07 0.08 0.10], ...
                'FontColor', [0.85 0.90 0.85], 'Value', {'（等待运行…）'});
            bar = uigridlayout(gl4, [1 4]);
            bar.ColumnWidth = {'fit', 'fit', 'fit', '1x'};
            bar.Padding = [0 0 0 0];
            bar.BackgroundColor = c.panel;
            uibutton(bar, 'Text', '清空日志', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.clearLog());
            uibutton(bar, 'Text', '打开运行目录', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.fire('OnOpenRunDir'));
            obj.RunDirLabel = uilabel(bar, 'Text', '日志文件：（尚未运行）', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);
        end

        function fire(obj, name)
            if isfield(obj.Cb, name) && ~isempty(obj.Cb.(name))
                try
                    feval(obj.Cb.(name));
                catch err
                    errordlg(sprintf('操作失败：%s', err.message), '错误');
                end
            end
        end

        function showCheckDetail(obj)
            v = obj.CheckList.Value;
            idx = find(strcmp(obj.CheckList.Items, v), 1);
            if isempty(idx), return; end
        end
    end
end
