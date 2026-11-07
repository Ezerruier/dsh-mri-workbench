classdef DataPanel < handle
% DataPanel  “数据索引”页面：自动搜索/索引数据目录（替代 DPARSF 手动逐步指定工作目录）
%
% 功能:
%   - 选择搜索根目录后后台扫描，自动识别 DPARSF(FunRaw/T1Raw/S2_FunRaw)、BIDS、
%     NIfTI、DICOM 布局；
%   - 自动提取受试者、功能/结构像目录、TR、时间点、层数；
%   - 提供“应用到预处理参数”按钮，把检测结果一键填入参数面板。
%
% 回调:
%   callbacks.OnApply(idx)     把扫描结果应用到预处理参数页
%   callbacks.OnStatus(msg)    状态文字更新

    properties (Access = private)
        Parent
        Cb = struct()
        RootField
        DepthDrop
        ScanBtn
        StatusLabel
        HintLabel
        Table
        SummaryArea
        InfoLabel
        Future = []
        ScanTimer = []
        Scanning = false
        Index = []
    end

    methods

        function obj = DataPanel(parent, callbacks)
            obj.Parent = parent;
            if nargin >= 2 && isstruct(callbacks)
                obj.Cb = callbacks;
            end
            obj.buildUI();
            try
                lastRoot = mrw.Settings.get('LastDataRoot');
                if ~isempty(lastRoot) && exist(lastRoot, 'dir') == 7
                    obj.RootField.Value = lastRoot;
                end
                obj.DepthDrop.Value = mrw.Settings.get('ScanMaxDepth');
            catch
            end
        end

        function setRoot(obj, d)
            if ischar(d) && ~isempty(d)
                obj.RootField.Value = d;
            end
        end

        function idx = getIndex(obj)
            idx = obj.Index;
        end

        function scan(obj, root, depth)
            if obj.Scanning
                return;
            end
            if nargin < 2 || isempty(root)
                root = strtrim(obj.RootField.Value);
            end
            if nargin < 3 || isempty(depth)
                depth = obj.DepthDrop.Value;
            end
            if isempty(root) || exist(root, 'dir') ~= 7
                errordlg('请先选择一个存在的数据根目录。', '目录无效');
                return;
            end
            obj.RootField.Value = root;
            obj.setScanning(true, '正在扫描目录，请稍候…');
            try
                mrw.Settings.set('LastDataRoot', root);
            catch
            end
            opts = struct('MaxDepth', depth);
            try
                pool = backgroundPool;
                obj.Future = parfeval(pool, @mrw.ScanEngine.scan, 1, root, opts);
                obj.ScanTimer = timer('ExecutionMode', 'fixedSpacing', ...
                    'Period', 0.5, 'BusyMode', 'drop', 'Name', 'mrwScanTimer', ...
                    'TimerFcn', @(t, e) obj.pollScan());
                start(obj.ScanTimer);
            catch
                % 后台池不可用：同步扫描兜底
                try
                    idx = mrw.ScanEngine.scan(root, opts);
                    obj.onScanDone(idx);
                catch err
                    obj.setScanning(false, ['扫描失败：' err.message]);
                    errordlg(sprintf('扫描失败：%s', err.message), '扫描错误');
                end
            end
        end
    end

    methods (Access = private)

        function buildUI(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            g = uigridlayout(obj.Parent, [2 1]);
            g.RowHeight = {'fit', '1x'};
            g.Padding = [12 12 12 12];
            g.RowSpacing = 10;
            g.BackgroundColor = c.bg;

            % --- 搜索卡 ---
            p1 = mrw.UiKit.card(g, '自动搜索索引（无需再一步步手动指定工作目录）');
            gl = uigridlayout(p1, [3 1]);
            gl.RowHeight = {'fit', 'fit', 'fit'};
            gl.Padding = [10 8 10 8];
            gl.BackgroundColor = c.panel;

            row1 = uigridlayout(gl, [1 7]);
            row1.ColumnWidth = {'fit', '1x', 90, 'fit', 80, 130, '1x'};
            row1.Padding = [0 0 0 0];
            row1.BackgroundColor = c.panel;
            uilabel(row1, 'Text', '搜索根目录：', 'FontName', f.name, 'FontWeight', 'bold');
            obj.RootField = uieditfield(row1, 'text', 'FontName', f.name, ...
                'Placeholder', '例如 D:\Data\MyStudy（其下包含 FunRaw/T1Raw 或 BIDS）');
            uibutton(row1, 'Text', '浏览…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.browseRoot());
            uilabel(row1, 'Text', '扫描深度：', 'FontName', f.name);
            obj.DepthDrop = uidropdown(row1, 'Items', {'2','3','4','5','6','7','8','10'}, ...
                'Value', '6', 'FontName', f.name);
            obj.ScanBtn = uibutton(row1, 'Text', [mrw.UiKit.glyphs().scan ' 开始自动扫描'], ...
                'FontName', f.name, 'FontWeight', 'bold', ...
                'BackgroundColor', c.accent, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.scan());
            obj.InfoLabel = uilabel(row1, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);

            obj.HintLabel = uilabel(gl, 'Text', ...
                ['自动识别：① DPARSF 布局（FunRaw/T1Raw、S2_FunRaw 多 session） ② BIDS（BIDS/sub-*） ' ...
                 '③ 通用 NIfTI ④ DICOM；并自动读取 TR / 时间点 / 层数 / 结构像配对。'], ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted);
            try, obj.HintLabel.WordWrap = 'on'; catch, end
            obj.StatusLabel = uilabel(gl, 'Text', '尚未扫描。选择数据根目录后点击“开始自动扫描”。', ...
                'FontName', f.name, 'FontSize', f.base, 'FontColor', c.text);

            % --- 结果卡 ---
            p2 = mrw.UiKit.card(g, '扫描结果与索引');
            g2 = uigridlayout(p2, [2 2]);
            g2.RowHeight = {'1x', 120};
            g2.ColumnWidth = {'1x', 300};
            g2.Padding = [10 8 10 8];
            g2.BackgroundColor = c.panel;

            cols = {'受试者', '功能像目录', '结构像目录', '数据类型', 'Session', ...
                '时间点', 'TR (s)', '层数', '状态'};
            obj.Table = uitable(g2, 'Data', cell(0, numel(cols)), ...
                'ColumnName', cols, 'RowName', {}, ...
                'ColumnWidth', {90, 280, 200, 80, 70, 70, 70, 60, 220}, ...
                'FontName', f.name, 'FontSize', f.small);
            obj.Table.Layout.Row = 1;
            obj.Table.Layout.Column = [1 2];

            sp = uigridlayout(g2, [2 1]);
            sp.RowHeight = {'1x', 'fit'};
            sp.Padding = [6 0 0 0];
            sp.BackgroundColor = c.panelAlt;
            obj.SummaryArea = uitextarea(sp, 'Editable', 'off', 'FontName', f.name, ...
                'FontSize', f.small, 'BackgroundColor', c.panelAlt, ...
                'Value', {'（扫描后显示检测摘要）'});
            btns = uigridlayout(sp, [1 3]);
            btns.ColumnWidth = {'1x', '1x', '1x'};
            btns.Padding = [0 0 0 0];
            btns.BackgroundColor = c.panelAlt;
            uibutton(btns, 'Text', '应用到预处理参数', 'FontName', f.name, ...
                'FontWeight', 'bold', 'BackgroundColor', c.ok, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.applyIndex());
            uibutton(btns, 'Text', '打开数据目录', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.openDir());
            uibutton(btns, 'Text', '导出索引 JSON', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.exportIndex());

            % 摘要列放在结果卡右侧
        end

        function browseRoot(obj)
            startDir = obj.RootField.Value;
            if isempty(startDir) || exist(startDir, 'dir') ~= 7
                startDir = pwd;
            end
            d = uigetdir(startDir, '选择包含 MRI 数据的根目录');
            if ischar(d) && ~isequal(d, 0)
                obj.RootField.Value = d;
            end
        end

        function pollScan(obj)
            if isempty(obj.Future)
                obj.stopTimer();
                return;
            end
            try
                st = obj.Future.State;
            catch
                obj.stopTimer();
                return;
            end
            switch st
                case 'finished'
                    try
                        idx = fetchOutputs(obj.Future);
                    catch err
                        obj.stopTimer();
                        obj.setScanning(false, ['扫描失败：' err.message]);
                        return;
                    end
                    obj.stopTimer();
                    obj.onScanDone(idx);
                case 'failed'
                    err = obj.Future.Error;
                    obj.stopTimer();
                    obj.setScanning(false, ['扫描失败：' err.message]);
                    errordlg(sprintf('扫描失败：%s', err.message), '扫描错误');
            end
        end

        function stopTimer(obj)
            try
                if ~isempty(obj.ScanTimer) && isvalid(obj.ScanTimer)
                    stop(obj.ScanTimer);
                    delete(obj.ScanTimer);
                end
            catch
            end
            obj.ScanTimer = [];
            obj.Future = [];
        end

        function setScanning(obj, tf, msg)
            obj.Scanning = logical(tf);
            if tf
                obj.ScanBtn.Enable = 'off';
                obj.ScanBtn.Text = '扫描中…';
                obj.StatusLabel.Text = msg;
                obj.StatusLabel.FontColor = mrw.UiKit.colors().accentDark;
            else
                obj.ScanBtn.Enable = 'on';
                obj.ScanBtn.Text = [mrw.UiKit.glyphs().scan ' 开始自动扫描'];
            end
            if nargin >= 3 && ~isempty(msg)
                obj.StatusLabel.Text = msg;
            end
        end

        function onScanDone(obj, idx)
            obj.Index = idx;
            obj.setScanning(false, sprintf('扫描完成：%d 名受试者，%s，用时 %.1f 秒', ...
                numel(idx.Subjects), idx.LayoutName, idx.Stats.Elapsed));
            obj.StatusLabel.FontColor = mrw.UiKit.colors().ok;
            obj.refreshTable();
            obj.showSummary();
            obj.fire('OnStatus', sprintf('扫描完成：%s（%d 名受试者）', idx.LayoutName, numel(idx.Subjects)));
        end

        function refreshTable(obj)
            idx = obj.Index;
            if isempty(idx)
                obj.Table.Data = cell(0, 9);
                return;
            end
            n = numel(idx.Subjects);
            data = cell(n, 9);
            for i = 1:n
                s = idx.Subjects(i);
                data{i,1} = s.ID;
                if isempty(s.FunDirs)
                    data{i,2} = '';
                else
                    data{i,2} = s.FunDirs{1};
                end
                data{i,3} = s.AnatDir;
                data{i,4} = s.FunType;
                data{i,5} = s.Sessions;
                data{i,6} = fmtNum(s.TimePoints);
                data{i,7} = fmtNum(s.TR);
                data{i,8} = fmtNum(s.SliceNumber);
                if isempty(s.Messages)
                    data{i,9} = s.Status;
                else
                    data{i,9} = [s.Status '：' s.Messages{1}];
                end
            end
            obj.Table.Data = data;
        end

        function showSummary(obj)
            idx = obj.Index;
            if isempty(idx)
                obj.SummaryArea.Value = {'（扫描后显示检测摘要）'};
                return;
            end
            d = idx.Detected;
            lines = {};
            lines{end+1} = ['布局：' idx.LayoutName '（' idx.Layout '）']; %#ok<AGROW>
            lines{end+1} = ['建议工作目录：' d.WorkingDir]; %#ok<AGROW>
            lines{end+1} = ['起始目录名：' d.StartingDirName]; %#ok<AGROW>
            lines{end+1} = sprintf('受试者数：%d    功能性 session 数：%d', ...
                numel(idx.Subjects), d.FunctionalSessionNumber); %#ok<AGROW>
            lines{end+1} = sprintf('自动检测：TR=%s 秒，时间点=%s，层数=%s', ...
                fmtNum(d.TR), fmtNum(d.TimePoints), fmtNum(d.SliceNumber)); %#ok<AGROW>
            if isfield(d, 'IsBIDS') && d.IsBIDS
                lines{end+1} = '数据类型：BIDS（预处理时需勾选 “BIDS 数据转 DPARSF 结构”）'; %#ok<AGROW>
            end
            if ~isempty(idx.Warnings)
                lines{end+1} = sprintf('提醒（%d）：', numel(idx.Warnings)); %#ok<AGROW>
                for i = 1:min(numel(idx.Warnings), 8)
                    lines{end+1} = ['  - ' idx.Warnings{i}]; %#ok<AGROW>
                end
            end
            if ~isempty(idx.Errors)
                lines{end+1} = sprintf('错误（%d）：', numel(idx.Errors)); %#ok<AGROW>
                for i = 1:min(numel(idx.Errors), 5)
                    lines{end+1} = ['  - ' idx.Errors{i}]; %#ok<AGROW>
                end
            end
            obj.SummaryArea.Value = lines;
        end

        function applyIndex(obj)
            if isempty(obj.Index)
                errordlg('请先扫描数据目录。', '尚未扫描');
                return;
            end
            obj.fire('OnApply', obj.Index);
        end

        function openDir(obj)
            d = '';
            if ~isempty(obj.Index)
                d = obj.Index.Detected.WorkingDir;
            else
                d = obj.RootField.Value;
            end
            if ischar(d) && exist(d, 'dir') == 7
                if ispc
                    system(['explorer "' d '"']);
                else
                    system(['xdg-open "' d '" &']);
                end
            end
        end

        function exportIndex(obj)
            if isempty(obj.Index)
                errordlg('请先扫描数据目录。', '尚未扫描');
                return;
            end
            [fn, fp] = uiputfile('*.json', '导出索引 JSON', ...
                fullfile(pwd, 'mrw_index.json'));
            if isequal(fn, 0), return; end
            try
                json = jsonencode(obj.Index, 'PrettyPrint', true);
                fid = fopen(fullfile(fp, fn), 'w', 'n', 'UTF-8');
                fwrite(fid, json);
                fclose(fid);
                obj.fire('OnStatus', ['索引已导出：' fullfile(fp, fn)]);
            catch err
                errordlg(sprintf('导出失败：%s', err.message), '导出错误');
            end
        end

        function fire(obj, name, arg)
            if isfield(obj.Cb, name) && ~isempty(obj.Cb.(name))
                try
                    if nargin >= 3
                        feval(obj.Cb.(name), arg);
                    else
                        feval(obj.Cb.(name));
                    end
                catch err
                    errordlg(sprintf('操作失败：%s', err.message), '错误');
                end
            end
        end
    end
end

function s = fmtNum(v)
if isempty(v) || (isnumeric(v) && any(isnan(v)))
    s = '--';
elseif ischar(v)
    s = v;
else
    s = sprintf('%g', v);
end
end
