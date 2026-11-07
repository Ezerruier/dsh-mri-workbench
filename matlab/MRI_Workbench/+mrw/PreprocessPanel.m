classdef PreprocessPanel < handle
% PreprocessPanel  DPARSFA 预处理参数面板（全中文、悬停解释、按流程分组）
%
% 组件由主 App 嵌入到任意 uifigure 容器（推荐 uipanel）中使用。
% 所有字段元数据来自 mrw.CfgSchema（不要在本类中硬编码字段清单/标签/默认值）：
%   - 每个 Group 一个子选项卡，顺序取 CfgSchema.groups()
%   - 每个字段一个表单行（左列中文标签 + 英文小字副标签，右列控件）
%   - 悬停提示由 mrw.Glossary.tooltipFromEntry 生成，术语库缺失时自动降级
%   - DependsOn 由 CfgSchema.enabled 判断，刷新时禁用控件并置灰标签
%   - Advanced 字段收进所在页底部的“高级选项”折叠区（默认收起）
%
% 用法：
%   p = mrw.PreprocessPanel(parentPanel, struct( ...
%           'PresetNames', {{'默认标准流程','快速检查'}}, ...
%           'PresetSelectedFcn', @(name) onPreset(name), ...
%           'RunRequestedFcn', @() onRun()));
%   st = p.getState();           % 深拷贝的嵌套状态（与 CfgSchema.defaults() 同构）
%   p.setState(st);              % 外部整表刷新
%   p.applyDetected(det);        % 用 ScanEngine 的 idx.Detected 自动填目录/TR/层数等
%   p.highlightKey('IsFilter');  % 切换到所属选项卡并闪烁 1.5 秒
%
% 事件：
%   Changed             任意参数变化后触发
%   RequestSubjectEdit  用户点击“管理受试者列表”时触发（由主 App 打开数据页/对话框）
%
% 额外便捷方法（非契约必需，供主 App/测试使用）：
%   searchFields(query)  程序化触发字段搜索，返回匹配的 Key 列表
%   hideSearchResults()  收起搜索候选面板
%   setFieldValue(key,v) 程序化设置单个字段（走与用户操作相同的校验/联动通路）
%   isFieldEnabled(key)  查询字段当前是否满足依赖条件
%
% 注意：setState 不触发 Changed（避免与外部监听形成回环）；reset/applyDetected/
% 用户操作会触发 Changed。

    properties (SetAccess = private)
        Parent       = []         % 父容器
        State        = struct()   % 与 Cfg 同构的嵌套 struct（所有 schema 字段均有值）
        FieldCount   = 0          % 字段数（= numel(CfgSchema.entries())）
        ControlCount = 0          % 本面板创建的 UI 控件数量（不含容器/布局）
        BuildSeconds = 0          % 构造耗时（秒）
        SearchResults = {}        % 最近一次搜索命中的 Key 列表
        SummaryText  = ''         % 当前“已启用步骤摘要”
        PresetNames  = {}         % 可用的预设名称
        Version      = '1.0.0'
    end

    properties (Access = private)
        Options
        Schema
        Root
        ToolbarPanel
        PresetDropdown
        SearchField
        ResetButton
        SummaryLabel
        ResultsPanel
        ResultsHeader
        ResultsList
        Tabs
        Pages        = []
        RowMap       = []         % containers.Map: Key -> RowList 下标
        RowList      = []         % 所有表单行的句柄与状态
        PagesReady   = false
        LastViewport = [1000 560]
        FlashTimer   = []
        FlashRow     = 0
        FooterLabel
        RunButton
    end

    events
        Changed
        RequestSubjectEdit
    end

    % ==================================================================
    %  公共接口
    % ==================================================================
    methods
        function obj = PreprocessPanel(parent, options)
            if nargin < 1 || isempty(parent)
                error('PreprocessPanel:Parent', '必须提供父容器（uipanel / uifigure 等）。');
            end
            if nargin < 2 || isempty(options), options = struct(); end
            obj.Parent  = parent;
            obj.Options = obj.normalizeOptions(options);
            obj.PresetNames = obj.Options.PresetNames;
            obj.Schema  = mrw.CfgSchema.entries();
            obj.FieldCount = numel(obj.Schema);
            obj.State   = mrw.CfgSchema.defaults();
            obj.RowMap  = containers.Map('KeyType', 'char', 'ValueType', 'double');

            t0 = tic;
            obj.buildShell();
            obj.buildPages();
            obj.PagesReady = true;
            for gi = 1:numel(obj.Pages)
                obj.relayoutPage(gi);
            end
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
            obj.resetSearchUI();
            obj.BuildSeconds = toc(t0);
            obj.updateControlCount();
        end

        function st = getState(obj)
            % 返回 State 深拷贝（MATLAB struct 值语义，天然深拷贝）
            st = obj.State;
        end

        function setState(obj, st)
            % 外部整表刷新：缺失字段沿用 schema 默认值，保持控件同步
            if isempty(st) || ~isstruct(st), return; end
            base = mrw.CfgSchema.defaults();
            S = obj.Schema;
            for i = 1:numel(S)
                if hasFieldPath(st, S(i).Key)
                    v = mrw.CfgSchema.getKey(st, S(i).Key);
                    base = mrw.CfgSchema.setKey(base, S(i).Key, v);
                end
            end
            obj.State = base;
            obj.syncControls();
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
        end

        function applyDetected(obj, det)
            % 用 ScanEngine 的 idx.Detected 自动填充可推断参数
            if isempty(det) || ~isstruct(det), return; end
            wd = detField(det, 'WorkingDir');
            if ischar(wd) && ~isempty(wd)
                obj.State = mrw.CfgSchema.setKey(obj.State, 'WorkingDir', wd);
                dpd = detField(det, 'DataProcessDir');
                if ~ischar(dpd) || isempty(dpd), dpd = wd; end
                obj.State = mrw.CfgSchema.setKey(obj.State, 'DataProcessDir', dpd);
            end
            sd = detField(det, 'StartingDirName');
            if ischar(sd) && ~isempty(sd)
                obj.State = mrw.CfgSchema.setKey(obj.State, 'StartingDirName', sd);
            end
            fsn = detField(det, 'FunctionalSessionNumber');
            if isnumeric(fsn) && isscalar(fsn) && isfinite(fsn) && fsn > 0
                obj.State = mrw.CfgSchema.setKey(obj.State, 'FunctionalSessionNumber', round(double(fsn)));
            end
            tr = detField(det, 'TR');
            if isnumeric(tr) && isscalar(tr) && isfinite(tr) && tr > 0
                obj.State = mrw.CfgSchema.setKey(obj.State, 'TR', double(tr));
            end
            tp = detField(det, 'TimePoints');
            if isnumeric(tp) && isscalar(tp) && isfinite(tp) && tp > 0
                obj.State = mrw.CfgSchema.setKey(obj.State, 'TimePoints', round(double(tp)));
            end
            sn = detField(det, 'SliceNumber');
            if isempty(sn)
                nested = detField(det, 'SliceTiming');
                if isstruct(nested), sn = detField(nested, 'SliceNumber'); end
            end
            if isnumeric(sn) && isscalar(sn) && isfinite(sn) && sn > 0
                obj.State = mrw.CfgSchema.setKey(obj.State, 'SliceTiming.SliceNumber', round(double(sn)));
            end
            ids = detField(det, 'SubjectIDs');
            if ~isempty(ids)
                if ischar(ids)
                    ids = {ids};
                elseif isstring(ids)
                    ids = cellstr(ids);
                elseif iscell(ids)
                    ids = cellfun(@(x) char(x), ids, 'UniformOutput', false);
                else
                    ids = {};
                end
                if ~isempty(ids)
                    obj.State = mrw.CfgSchema.setKey(obj.State, 'SubjectID', ids);
                end
            end
            obj.syncControls();
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
            obj.notifyChanged();
        end

        function reset(obj)
            % 恢复 schema 默认值（保留工作目录与受试者列表）
            keepWd  = mrw.CfgSchema.getKey(obj.State, 'WorkingDir');
            keepSid = mrw.CfgSchema.getKey(obj.State, 'SubjectID');
            obj.State = mrw.CfgSchema.defaults();
            if ~isempty(keepWd) || ischar(keepWd)
                obj.State = mrw.CfgSchema.setKey(obj.State, 'WorkingDir', keepWd);
            end
            obj.State = mrw.CfgSchema.setKey(obj.State, 'SubjectID', keepSid);
            obj.syncControls();
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
            obj.notifyChanged();
        end

        function refreshEnables(obj)
            % 按 DependsOn 刷新所有行的 Enable / 置灰 / 悬停提示
            n = numel(obj.RowList);
            for idx = 1:n
                tf = mrw.CfgSchema.enabled(obj.RowList(idx).Entry, obj.State);
                obj.RowList(idx).Enabled = tf;
                obj.applyRowStyle(idx);
            end
        end

        function ok = highlightKey(obj, key)
            % 切换到字段所属选项卡并闪烁高亮 1.5 秒
            ok = false;
            if isempty(key) || ~ischar(key), return; end
            try
                entry = mrw.CfgSchema.get(key);
            catch
                return;
            end
            gi = find(strcmp({obj.Pages.Group}, entry.Group), 1);
            if isempty(gi), return; end
            idx = obj.rowIndex(key);
            if isempty(idx), return; end
            try
                obj.Tabs.SelectedTab = obj.Pages(gi).Tab;
            catch
            end
            if obj.RowList(idx).Advanced && ~obj.Pages(gi).Expanded
                obj.setAdvExpanded(gi, true);
            end
            obj.relayoutPage(gi);
            obj.flashRow(idx);
            try
                obj.FooterLabel.Text = sprintf('已定位到「%s · %s」，可在页面中上下滚动查看', ...
                    entry.Group, entry.Label);
            catch
            end
            ok = true;
        end

        % ---------- 额外便捷方法 ----------
        function keys = searchFields(obj, query)
            % 程序化搜索：输入 >=1 字符时显示候选面板并返回匹配 Key（最多 12 条）
            keys = {};
            if nargin < 2 || isempty(query), query = ''; end
            if isstring(query), query = char(query); end
            if ~ischar(query), return; end
            q = lower(strtrim(query));
            obj.SearchResults = {};
            if isempty(q)
                obj.hideSearchResults();
                return;
            end
            S = obj.Schema;
            n = numel(S);
            scores = inf(1, n);
            for i = 1:n
                hay = lower([S(i).Key ' ' S(i).Label ' ' S(i).EN ' ' S(i).Group]);
                if ~isempty(strfind(hay, q)) %#ok<STREMP>
                    scores(i) = 0;
                    continue;
                end
                g = obj.glossaryText(S(i).Key);
                if ~isempty(g) && ~isempty(strfind(lower(g), q)) %#ok<STREMP>
                    scores(i) = 1;
                end
            end
            hit = find(isfinite(scores));
            total = numel(hit);
            if total == 0
                obj.showResults('未找到匹配字段，请尝试其他关键词', {}, {});
                return;
            end
            [~, ord] = sort(scores(hit));
            hit = hit(ord);
            hit = hit(1:min(12, numel(hit)));
            items = cell(1, numel(hit));
            keys  = cell(1, numel(hit));
            for k = 1:numel(hit)
                i = hit(k);
                items{k} = sprintf('%s · %s（%s）', S(i).Group, S(i).Label, S(i).EN);
                keys{k}  = S(i).Key;
            end
            obj.SearchResults = keys;
            if total > numel(hit)
                hdr = sprintf('匹配到 %d 项，显示前 %d 项，点击跳转', total, numel(hit));
            else
                hdr = sprintf('匹配到 %d 项，点击跳转', total);
            end
            obj.showResults(hdr, items, keys);
        end

        function hideSearchResults(obj)
            try
                obj.ResultsPanel.Visible = 'off';
                rh = obj.Root.RowHeight;
                rh{2} = 0;
                obj.Root.RowHeight = rh;
            catch
            end
            obj.SearchResults = {};
        end

        function tf = setFieldValue(obj, key, value)
            % 程序化设置单个字段（与用户操作走同一校验与联动通路）
            tf = false;
            idx = obj.rowIndex(key);
            if isempty(idx), return; end
            row = obj.RowList(idx);
            entry = row.Entry;
            switch entry.Type
                case 'vector'
                    if ischar(value) || isstring(value)
                        [v, okp, msg] = parseVectorText(entry.Key, char(value));
                        if ~okp
                            obj.markInvalid(idx, msg);
                            return;
                        end
                        value = v;
                    elseif isnumeric(value)
                        [value, okp, ~] = validateVectorShape(entry.Key, value);
                        if ~okp, return; end
                    else
                        return;
                    end
                case 'bool'
                    value = double(logical(value));
                case {'int', 'double'}
                    if ~isnumeric(value) || ~isscalar(value), return; end
                    value = double(value);
                case {'text', 'dir', 'file', 'maskfile'}
                    value = char(value);
                case 'roi'
                    if ischar(value) || isstring(value)
                        value = splitROI(char(value));
                    elseif iscell(value)
                        value = cellfun(@(x) char(x), value, 'UniformOutput', false);
                    else
                        return;
                    end
                case 'enum'
                    if islogical(value), value = double(value); end
                    if ~isValidEnumValue(entry, value), return; end
                case 'subjects'
                    if ischar(value)
                        value = {value};
                    elseif isstring(value)
                        value = cellstr(value);
                    elseif ~iscell(value)
                        return;
                    end
            end
            obj.State = mrw.CfgSchema.setKey(obj.State, key, value);
            obj.clearInvalid(idx);
            obj.syncRow(idx);
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
            obj.notifyChanged();
            tf = true;
        end

        function tf = isFieldEnabled(obj, key)
            tf = false;
            idx = obj.rowIndex(key);
            if isempty(idx), return; end
            tf = mrw.CfgSchema.enabled(obj.RowList(idx).Entry, obj.State);
        end
    end

    % ==================================================================
    %  界面搭建
    % ==================================================================
    methods (Access = private)

        function o = normalizeOptions(~, options)
            o = struct('PresetNames', {{}}, 'PresetSelectedFcn', [], 'RunRequestedFcn', []);
            if ~isstruct(options), return; end
            f = fieldnames(options);
            for i = 1:numel(f)
                o.(f{i}) = options.(f{i});
            end
            if isstring(o.PresetNames)
                o.PresetNames = cellstr(o.PresetNames);
            elseif ~iscell(o.PresetNames)
                o.PresetNames = {};
            end
            o.PresetNames = o.PresetNames(:)';
        end

        function buildShell(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();

            obj.Root = uigridlayout(obj.Parent, [4 1]);
            obj.Root.RowHeight = {112, 0, '1x', 34};
            obj.Root.ColumnWidth = {'1x'};
            obj.Root.RowSpacing = 8;
            obj.Root.Padding = [12 10 12 10];
            obj.Root.BackgroundColor = c.bg;

            % ---------- 顶部工具条 ----------
            tb = uipanel(obj.Root, 'BorderType', 'line', 'HighlightColor', c.border, ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text);
            tb.Layout.Row = 1;
            obj.ToolbarPanel = tb;
            tg = uigridlayout(tb, [2 6]);
            tg.RowHeight = {36, 32};
            tg.ColumnWidth = {44, 200, 44, 300, '1x', 112};
            tg.Padding = [14 8 14 6];
            tg.RowSpacing = 8;
            tg.ColumnSpacing = 8;
            tg.BackgroundColor = c.panel;

            lblPreset = uilabel(tg, 'Text', '预设', 'FontName', f.name, 'FontSize', f.base, ...
                'FontColor', c.text, 'HorizontalAlignment', 'right');
            lblPreset.Layout.Row = 1; lblPreset.Layout.Column = 1;
            mrw.UiKit.tip(lblPreset, '参数预设：由主程序提供的常用参数组合，选择后自动填充。');

            items = {'— 选择预设 —'};
            if ~isempty(obj.Options.PresetNames)
                items = [items, obj.Options.PresetNames];
            end
            obj.PresetDropdown = uidropdown(tg, 'Items', items, 'FontName', f.name, ...
                'FontSize', f.base, 'Value', items{1}, 'Tag', 'presetDropdown', ...
                'ValueChangedFcn', @(s, e) obj.onPresetChanged());
            obj.PresetDropdown.Layout.Row = 1;
            obj.PresetDropdown.Layout.Column = 2;
            if numel(items) <= 1
                obj.PresetDropdown.Enable = 'off';
                mrw.UiKit.tip(obj.PresetDropdown, '当前没有可用预设（由主程序通过 PresetNames 提供）。');
            else
                mrw.UiKit.tip(obj.PresetDropdown, ...
                    '选择预设可快速套用一组预处理参数；具体套用逻辑由主程序执行。');
            end

            lblSearch = uilabel(tg, 'Text', '搜索', 'FontName', f.name, 'FontSize', f.base, ...
                'FontColor', c.text, 'HorizontalAlignment', 'right');
            lblSearch.Layout.Row = 1; lblSearch.Layout.Column = 3;
            mrw.UiKit.tip(lblSearch, '按字段中文名、英文名、分组或术语解释搜索参数。');

            obj.SearchField = uieditfield(tg, 'text', 'FontName', f.name, 'FontSize', f.base, ...
                'Placeholder', '搜索参数名 / 英文名 / 关键词…', 'Tag', 'searchField', ...
                'ValueChangingFcn', @(s, e) obj.onSearchChanged(), ...
                'ValueChangedFcn', @(s, e) obj.onSearchChanged());
            obj.SearchField.Layout.Row = 1;
            obj.SearchField.Layout.Column = 4;
            mrw.UiKit.tip(obj.SearchField, ...
                '输入至少 1 个字符，下方会出现匹配字段候选（最多 12 条）；点击候选会跳转并高亮该参数。');

            obj.ResetButton = mrw.UiKit.button(tg, '恢复默认', 'kind', 'normal', ...
                'Callback', @(s, e) obj.onResetPressed());
            obj.ResetButton.Layout.Row = 1;
            obj.ResetButton.Layout.Column = 6;
            obj.ResetButton.Tag = 'resetButton';
            mrw.UiKit.tip(obj.ResetButton, ...
                '恢复所有参数的 schema 默认值（保留工作目录与受试者列表，不改变外部数据）。');

            % 摘要条
            sumPanel = uipanel(tg, 'BorderType', 'none', 'BackgroundColor', c.accentBg);
            sumPanel.Layout.Row = 2;
            sumPanel.Layout.Column = [1 6];
            sg = uigridlayout(sumPanel, [1 1]);
            sg.Padding = [10 2 10 2];
            sg.BackgroundColor = c.accentBg;
            obj.SummaryLabel = uilabel(sg, 'Text', '将执行：', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.accentDark, ...
                'BackgroundColor', c.accentBg, 'VerticalAlignment', 'center', ...
                'Tag', 'summaryLabel');
            mrw.UiKit.tip(obj.SummaryLabel, ...
                '根据当前勾选的处理步骤自动生成的流程摘要；未启用任何步骤时显示“仅整理数据”。');

            % ---------- 搜索候选面板（默认高度 0） ----------
            rp = uipanel(obj.Root, 'BorderType', 'line', 'HighlightColor', c.border, ...
                'BackgroundColor', c.panel, 'Visible', 'off');
            rp.Layout.Row = 2;
            obj.ResultsPanel = rp;
            rg = uigridlayout(rp, [2 1]);
            rg.RowHeight = {20, '1x'};
            rg.Padding = [14 6 14 8];
            rg.RowSpacing = 4;
            rg.BackgroundColor = c.panel;
            obj.ResultsHeader = uilabel(rg, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel);
            obj.ResultsList = uilistbox(rg, 'Items', {}, 'ItemsData', {}, ...
                'FontName', f.name, 'FontSize', f.base, 'Tag', 'resultsList', ...
                'ValueChangedFcn', @(s, e) obj.onResultPicked());
            mrw.UiKit.tip(obj.ResultsList, '点击候选字段会切换到对应选项卡并高亮该参数。');

            % ---------- 选项卡主体 ----------
            obj.Tabs = uitabgroup(obj.Root);
            obj.Tabs.Layout.Row = 3;
            obj.Tabs.FontName = f.name;
            obj.Tabs.FontSize = f.base;
            obj.Tabs.SelectionChangedFcn = @(s, e) obj.onTabChanged();

            % ---------- 底部信息条 ----------
            fp = uipanel(obj.Root, 'BorderType', 'none', 'BackgroundColor', c.bg);
            fp.Layout.Row = 4;
            cols = {'1x'};
            if ~isempty(obj.Options.RunRequestedFcn), cols = {'1x', 150}; end
            fg = uigridlayout(fp, [1 numel(cols)]);
            fg.ColumnWidth = cols;
            fg.Padding = [6 0 6 0];
            fg.ColumnSpacing = 8;
            fg.BackgroundColor = c.bg;
            obj.FooterLabel = uilabel(fg, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.bg);
            obj.FooterLabel.Layout.Row = 1;
            obj.FooterLabel.Layout.Column = 1;
            if ~isempty(obj.Options.RunRequestedFcn)
                obj.RunButton = mrw.UiKit.button(fg, '开始预处理', 'kind', 'primary', ...
                    'Callback', @(s, e) obj.onRunPressed());
                obj.RunButton.Layout.Row = 1;
                obj.RunButton.Layout.Column = 2;
                obj.RunButton.Tag = 'runButton';
                mrw.UiKit.tip(obj.RunButton, ...
                    '使用当前参数启动 DPARSF 预处理（具体执行由主程序负责）。');
            end
        end

        function buildPages(obj)
            groups = mrw.CfgSchema.groups();
            nG = numel(groups);
            obj.Pages = repmat(emptyPageStruct(), nG, 1);
            for gi = 1:nG
                obj.buildPage(gi, groups{gi});
            end
        end

        function buildPage(obj, gi, group)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            page = emptyPageStruct();
            page.Group = group;

            tab = uitab(obj.Tabs, 'Title', group);
            fillg = uigridlayout(tab, [1 1]);
            fillg.Padding = [0 0 0 0];
            fillg.RowSpacing = 0;
            fillg.ColumnSpacing = 0;
            fillg.BackgroundColor = c.bg;

            scroll = uipanel(fillg, 'Scrollable', 'on', 'BorderType', 'none', ...
                'BackgroundColor', c.bg);
            try, scroll.AutoResizeChildren = 'off'; catch, end
            scroll.SizeChangedFcn = @(s, e) obj.onPageResized(gi);

            content = uipanel(scroll, 'Units', 'pixels', 'BorderType', 'line', ...
                'HighlightColor', c.border, 'BackgroundColor', c.panel, ...
                'Position', [14, 12, 800, 500]);
            try, content.AutoResizeChildren = 'off'; catch, end

            E = mrw.CfgSchema.groupEntries(group);
            isAdv = logical([E.Advanced]);
            if ~any(~isAdv)
                isAdv(:) = false;   % 整页都是高级字段时不再折叠，直接平铺
            end
            normalEntries = E(~isAdv);
            advEntries    = E(isAdv);
            nAdv = numel(advEntries);

            page.Tab = tab;
            page.Fill = fillg;
            page.Scroll = scroll;
            page.Content = content;

            page.Title = uilabel(content, 'Text', group, 'FontName', f.name, ...
                'FontSize', f.large, 'FontWeight', 'bold', 'FontColor', c.text, ...
                'BackgroundColor', c.panel, 'Tag', 'pageTitle');
            page.Desc = uilabel(content, 'Text', groupDescription(group), ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            if nAdv > 0
                cnt = sprintf('共 %d 项参数 · 高级 %d 项', numel(E), nAdv);
            else
                cnt = sprintf('共 %d 项参数', numel(E));
            end
            page.Count = uilabel(content, 'Text', cnt, 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, ...
                'HorizontalAlignment', 'right', 'BackgroundColor', c.panel);
            page.Sep = uipanel(content, 'BorderType', 'none', 'BackgroundColor', c.border);

            if nAdv > 0
                page.Toggle = uibutton(content, 'Text', '', 'FontName', f.name, ...
                    'FontSize', f.small, 'FontColor', c.accentDark, ...
                    'BackgroundColor', c.panelAlt, ...
                    'ButtonPushedFcn', @(s, e) obj.onAdvToggle(gi));
                try, page.Toggle.FontWeight = 'bold'; catch, end
                mrw.UiKit.tip(page.Toggle, ...
                    '展开/收起本页的高级参数（默认收起，避免界面过于拥挤）。');
                page.AdvPanel = uipanel(content, 'BorderType', 'line', ...
                    'HighlightColor', c.border, 'BackgroundColor', c.panelAlt, ...
                    'Visible', 'off');
                try, page.AdvPanel.AutoResizeChildren = 'off'; catch, end
            end

            page.Built = true;
            page.Viewport = obj.LastViewport;
            obj.Pages(gi) = page;

            for k = 1:numel(normalEntries)
                obj.addRow(gi, normalEntries(k), false);
            end
            for k = 1:numel(advEntries)
                obj.addRow(gi, advEntries(k), true);
            end
            page = obj.Pages(gi);
            obj.applyAdvState(gi);
            obj.Pages(gi) = page;
        end

        function row = addRow(obj, gi, entry, isAdvanced)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            page = obj.Pages(gi);
            if isAdvanced
                parent = page.AdvPanel;
                bg = c.panelAlt;
            else
                parent = page.Content;
                bg = c.panel;
            end

            idx = numel(obj.RowList) + 1;
            row = struct();
            row.Entry     = entry;
            row.Page      = gi;
            row.Advanced  = logical(isAdvanced);
            row.Key       = entry.Key;
            row.ZH        = [];
            row.EN        = [];
            row.Ctrl      = [];
            row.Aux       = [];
            row.Hint      = [];
            row.BaseTip   = obj.tooltipFor(entry);
            row.HintBase  = hintForKey(entry);
            row.Enabled   = true;
            row.Invalid   = false;
            row.InvalidMsg = '';

            row.ZH = uilabel(parent, 'Text', entry.Label, 'FontName', f.name, ...
                'FontSize', f.base, 'FontColor', c.text, 'BackgroundColor', bg, ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'center', ...
                'Tag', ['lbl:' entry.Key]);
            row.EN = uilabel(parent, 'Text', entry.EN, 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', bg, ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'center', ...
                'Tag', ['en:' entry.Key]);
            row.Hint = uilabel(parent, 'Text', row.HintBase, 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', bg, ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'center', ...
                'Tag', ['hint:' entry.Key]);
            mrw.UiKit.tip(row.ZH, row.BaseTip);
            mrw.UiKit.tip(row.EN, row.BaseTip);
            mrw.UiKit.tip(row.Hint, row.BaseTip);

            v = mrw.CfgSchema.getKey(obj.State, entry.Key);
            switch entry.Type
                case 'bool'
                    row.Ctrl = uicheckbox(parent, 'Text', '启用', 'Value', isTrue(v), ...
                        'FontName', f.name, 'FontSize', f.small, 'FontColor', c.text, ...
                        'Tag', entry.Key, ...
                        'ValueChangedFcn', @(s, e) obj.onRowChanged(idx));

                case 'enum'
                    labels = {entry.Options.Label};
                    raw    = {entry.Options.Value};
                    if ~isempty(raw) && all(cellfun(@isnumeric, raw))
                        data = cell2mat(raw);
                    else
                        data = cellfun(@(x) char(x), raw, 'UniformOutput', false);
                    end
                    cur = enumValueOrDefault(data, v);
                    row.Ctrl = uidropdown(parent, 'Items', labels, 'ItemsData', data, ...
                        'Value', cur, 'FontName', f.name, 'FontSize', f.base, ...
                        'Tag', entry.Key, ...
                        'ValueChangedFcn', @(s, e) obj.onRowChanged(idx));

                case {'int', 'double'}
                    if isempty(v) || ~isnumeric(v) || ~isscalar(v), v = 0; end
                    if strcmp(entry.Type, 'int')
                        row.Ctrl = uieditfield(parent, 'numeric', 'Value', double(v), ...
                            'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%.0f', ...
                            'FontName', f.name, 'FontSize', f.base, 'ValueChangedFcn', ...
                            @(s, e) obj.onRowChanged(idx));
                    else
                        row.Ctrl = uieditfield(parent, 'numeric', 'Value', double(v), ...
                            'ValueDisplayFormat', '%.6g', ...
                            'FontName', f.name, 'FontSize', f.base, 'ValueChangedFcn', ...
                            @(s, e) obj.onRowChanged(idx));
                    end
                    row.Ctrl.Tag = entry.Key;

                case 'vector'
                    row.Ctrl = uieditfield(parent, 'text', 'Value', vectorToText(v), ...
                        'FontName', f.name, 'FontSize', f.base, 'Tag', entry.Key, ...
                        'ValueChangedFcn', @(s, e) obj.onRowChanged(idx));

                case {'text', 'dir', 'file', 'maskfile'}
                    if ~ischar(v), v = ''; end
                    row.Ctrl = uieditfield(parent, 'text', 'Value', v, ...
                        'FontName', f.name, 'FontSize', f.base, 'Tag', entry.Key, ...
                        'ValueChangedFcn', @(s, e) obj.onRowChanged(idx));
                    if ~strcmp(entry.Type, 'text')
                        row.Aux = uibutton(parent, 'Text', '浏览…', 'FontName', f.name, ...
                            'FontSize', f.small, 'Tag', ['browse:' entry.Key], ...
                            'ButtonPushedFcn', @(s, e) obj.onBrowse(idx));
                    end

                case 'roi'
                    row.Ctrl = uieditfield(parent, 'text', 'Value', joinROI(v), ...
                        'FontName', f.name, 'FontSize', f.base, 'Tag', entry.Key, ...
                        'ValueChangedFcn', @(s, e) obj.onRowChanged(idx));
                    row.Aux = uibutton(parent, 'Text', '多选…', 'FontName', f.name, ...
                        'FontSize', f.small, 'Tag', ['browse:' entry.Key], ...
                        'ButtonPushedFcn', @(s, e) obj.onBrowse(idx));

                case 'subjects'
                    row.Ctrl = uilabel(parent, 'Text', '尚未选择受试者', 'FontName', f.name, ...
                        'FontSize', f.base, 'FontColor', c.text, ...
                        'BackgroundColor', bg, 'HorizontalAlignment', 'left', ...
                        'VerticalAlignment', 'center', 'Tag', entry.Key);
                    row.Aux = uibutton(parent, 'Text', '管理受试者列表', 'FontName', f.name, ...
                        'FontSize', f.small, 'Tag', ['subjects:' entry.Key], ...
                        'ButtonPushedFcn', @(s, e) obj.onManageSubjects());

                otherwise
                    row.Ctrl = uieditfield(parent, 'text', 'Value', '', 'FontName', f.name, ...
                        'FontSize', f.base, 'Tag', entry.Key);
            end

            mrw.UiKit.tip(row.Ctrl, row.BaseTip);
            for k = 1:numel(row.Aux)
                mrw.UiKit.tip(row.Aux(k), row.BaseTip);
            end
            if strcmp(entry.Type, 'subjects')
                mrw.UiKit.tip(row.Aux, '打开受试者列表管理（由主程序打开数据页或对话框）。');
            end

            if isempty(obj.RowList)
                obj.RowList = row;
            else
                obj.RowList(end+1) = row;
            end
            obj.RowMap(entry.Key) = idx;
            if isAdvanced
                page.RowsAdv(end+1) = idx;
            else
                page.RowsNormal(end+1) = idx;
            end
            obj.Pages(gi) = page;
            obj.syncRow(idx);
            obj.syncSubjectsIfNeeded(idx);
        end

        function syncSubjectsIfNeeded(obj, idx)
            if strcmp(obj.RowList(idx).Entry.Type, 'subjects')
                obj.syncSubjects(idx, mrw.CfgSchema.getKey(obj.State, 'SubjectID'));
            end
        end
    end

    % ==================================================================
    %  布局
    % ==================================================================
    methods (Access = private)

        function onPageResized(obj, gi)
            if ~obj.PagesReady, return; end
            try
                page = obj.Pages(gi);
                p = page.Scroll.InnerPosition;
                if numel(p) == 4 && p(3) > 320 && p(4) > 200
                    page.Viewport = [p(3) p(4)];
                    obj.Pages(gi) = page;
                    obj.LastViewport = page.Viewport;
                    obj.relayoutPage(gi);
                end
            catch
            end
        end

        function onTabChanged(obj)
            if ~obj.PagesReady, return; end
            try
                tab = obj.Tabs.SelectedTab;
                for gi = 1:numel(obj.Pages)
                    if isequal(obj.Pages(gi).Tab, tab)
                        obj.relayoutPage(gi);
                        return;
                    end
                end
            catch
            end
        end

        function relayoutPage(obj, gi)
            if isempty(obj.Pages) || gi < 1 || gi > numel(obj.Pages), return; end
            page = obj.Pages(gi);
            if ~page.Built || isempty(page.Content) || ~isvalid(page.Content), return; end

            [vw, vh] = obj.pageViewport(page);
            if vw < 360, vw = obj.LastViewport(1); end
            if vh < 240, vh = obj.LastViewport(2); end
            page.Viewport = [vw vh];
            obj.LastViewport = [vw vh];

            margin = 14;
            scrollAllow = 22;
            cardW = max(560, round(vw) - 2 * margin - scrollAllow);
            cardX = max(0, round((vw - cardW) / 2));

            rowH = 50; gap = 6; step = rowH + gap; headerH = 66; padBottom = 14;
            nN = numel(page.RowsNormal);
            nA = numel(page.RowsAdv);

            bodyBottom = headerH + nN * rowH + max(0, nN - 1) * gap;
            advTop = bodyBottom + 14;
            advPanelTop = 0; advPanelH = 0;
            neededH = advTop;
            if nA > 0
                neededH = advTop + 34;
                advPanelTop = advTop + 34 + 10;
                advPanelH = 20 + nA * rowH + max(0, nA - 1) * gap;
                if page.Expanded
                    neededH = advPanelTop + advPanelH;
                end
            end
            neededH = neededH + padBottom;

            viewH = max(220, round(vh) - 24);
            cardH = max(neededH, viewH);
            cardY = round(vh) - 12 - cardH;
            try
                page.Content.Position = [cardX, cardY, cardW, cardH];
            catch
                page.Content.Position = [cardX, 12, cardW, cardH];
            end

            obj.setPos(page.Title, [18, cardH - 30, 320, 22]);
            obj.setPos(page.Count, [cardW - 190, cardH - 30, 172, 20]);
            obj.setPos(page.Desc, [18, cardH - 50, max(120, cardW - 40), 16]);
            obj.setPos(page.Sep, [18, cardH - 62, max(80, cardW - 36), 1]);

            topOff = headerH;
            for k = 1:nN
                obj.positionRow(page.RowsNormal(k), cardH, cardW, topOff);
                topOff = topOff + step;
            end

            if nA > 0
                obj.setPos(page.Toggle, [18, cardH - advTop - 34, 330, 34]);
                try
                    page.AdvPanel.Position = [14, cardH - advPanelTop - advPanelH, ...
                        max(120, cardW - 28), advPanelH];
                catch
                end
                frameW = max(120, cardW - 28);
                for k = 1:nA
                    topOffAdv = 10 + (k - 1) * step;
                    obj.positionRow(page.RowsAdv(k), advPanelH, frameW, topOffAdv);
                end
            end
            obj.Pages(gi) = page;
        end

        function [vw, vh] = pageViewport(obj, page)
            vw = page.Viewport(1);
            vh = page.Viewport(2);
            if ~obj.PagesReady, return; end
            try
                p = page.Scroll.InnerPosition;
                if numel(p) == 4 && p(3) > 320 && p(4) > 200
                    vw = p(3); vh = p(4);
                end
            catch
            end
        end

        function positionRow(obj, idx, frameH, frameW, topOffset)
            row = obj.RowList(idx);
            if isempty(row.Ctrl) || ~isvalid(row.Ctrl), return; end
            rowH = 50; ctrlH = 24;
            topY = frameH - topOffset;
            zhY = topY - 22;
            enY = topY - 38;
            labelW = 240;
            obj.setPos(row.ZH, [18, zhY, labelW, 18]);
            obj.setPos(row.EN, [18, enY, labelW, 14]);

            ctrlX = 272;
            ctrlY = topY - 37;
            avail = max(160, frameW - ctrlX - 22);
            e = row.Entry;
            baseHint = ~isempty(row.HintBase);
            switch e.Type
                case 'bool'
                    hintW = 120; ctrlW = min(90, avail);
                case 'enum'
                    hintW = 170; ctrlW = min(340, max(150, avail - hintW - 20));
                case {'int', 'double'}
                    hintW = 170; ctrlW = min(180, max(120, avail - hintW - 20));
                case 'vector'
                    hintW = 170; ctrlW = min(520, max(180, avail - hintW - 20));
                case 'text'
                    hintW = 170; ctrlW = min(400, max(160, avail - hintW - 20));
                case 'dir'
                    hintW = baseHint * 170;
                    ctrlW = max(220, avail - 100 - hintW - 10);
                case {'file', 'maskfile'}
                    hintW = baseHint * 170;
                    ctrlW = max(200, avail - 100 - hintW - 10);
                case 'roi'
                    hintW = baseHint * 170;
                    ctrlW = max(180, avail - 120 - hintW - 10);
                case 'subjects'
                    hintW = 0;
                    ctrlW = min(300, max(180, avail - 190));
                otherwise
                    hintW = 0; ctrlW = min(320, avail);
            end
            ctrlW = max(60, min(ctrlW, avail));
            obj.setPos(row.Ctrl, [ctrlX, ctrlY, ctrlW, ctrlH]);

            cursor = ctrlX + ctrlW + 8;
            for k = 1:numel(row.Aux)
                if strcmp(e.Type, 'subjects')
                    w = 166;
                elseif strcmp(e.Type, 'roi')
                    w = 96;
                else
                    w = 84;
                end
                obj.setPos(row.Aux(k), [cursor, ctrlY, w, ctrlH]);
                cursor = cursor + w + 6;
            end
            hintX = cursor + 6;
            hintW2 = max(0, frameW - hintX - 16);
            obj.setPos(row.Hint, [hintX, ctrlY + 3, hintW2, 18]);
        end

        function setPos(~, h, pos)
            if isempty(h) || ~isvalid(h), return; end
            try
                h.Position = pos;
            catch
            end
        end

        function setAdvExpanded(obj, gi, tf)
            page = obj.Pages(gi);
            if isempty(page.Toggle) || page.Expanded == tf, return; end
            page.Expanded = tf;
            obj.Pages(gi) = page;
            obj.applyAdvState(gi);
            obj.relayoutPage(gi);
        end

        function onAdvToggle(obj, gi)
            page = obj.Pages(gi);
            if isempty(page.Toggle), return; end
            obj.setAdvExpanded(gi, ~page.Expanded);
        end

        function applyAdvState(obj, gi)
            page = obj.Pages(gi);
            if isempty(page.Toggle) || ~isvalid(page.Toggle) || isempty(page.AdvPanel)
                return;
            end
            nAdv = numel(page.RowsAdv);
            if page.Expanded
                page.Toggle.Text = sprintf('▾ 收起高级选项（%d 项）', nAdv);
                try, page.AdvPanel.Visible = 'on'; catch, end
            else
                page.Toggle.Text = sprintf('▸ 高级选项（%d 项，已收起）', nAdv);
                try, page.AdvPanel.Visible = 'off'; catch, end
            end
            obj.Pages(gi) = page;
        end
    end

    % ==================================================================
    %  控件取值 / 状态同步 / 样式
    % ==================================================================
    methods (Access = private)

        function onRowChanged(obj, idx)
            [v, ok, msg] = obj.readRowValue(idx);
            if ~ok
                obj.markInvalid(idx, msg);
                return;
            end
            obj.clearInvalid(idx);
            entry = obj.RowList(idx).Entry;
            obj.State = mrw.CfgSchema.setKey(obj.State, entry.Key, v);
            obj.refreshEnables();
            obj.updateSummary();
            obj.updateFooterInfo();
            obj.notifyChanged();
        end

        function [v, ok, msg] = readRowValue(obj, idx)
            row = obj.RowList(idx);
            entry = row.Entry;
            v = []; ok = true; msg = '';
            switch entry.Type
                case 'bool'
                    v = double(logical(row.Ctrl.Value));
                case 'enum'
                    v = row.Ctrl.Value;
                case {'int', 'double'}
                    v = row.Ctrl.Value;
                    if isempty(v) || ~isnumeric(v) || ~isscalar(v)
                        ok = false; msg = '请输入数值';
                    else
                        v = double(v);
                    end
                case 'vector'
                    [v, ok, msg] = parseVectorText(entry.Key, char(row.Ctrl.Value));
                case {'text', 'dir', 'file', 'maskfile'}
                    v = char(row.Ctrl.Value);
                case 'roi'
                    v = splitROI(char(row.Ctrl.Value));
                otherwise
                    v = char(row.Ctrl.Value);
            end
        end

        function syncControls(obj)
            for idx = 1:numel(obj.RowList)
                obj.syncRow(idx);
            end
        end

        function syncRow(obj, idx)
            row = obj.RowList(idx);
            v = mrw.CfgSchema.getKey(obj.State, row.Entry.Key);
            switch row.Entry.Type
                case 'bool'
                    try, row.Ctrl.Value = isTrue(v); catch, end
                case 'enum'
                    try
                        row.Ctrl.Value = v;
                    catch
                        % 值不在可选项内：保持原样，避免破坏界面
                    end
                case {'int', 'double'}
                    if isempty(v) || ~isnumeric(v) || ~isscalar(v), v = 0; end
                    try, row.Ctrl.Value = double(v); catch, end
                case 'vector'
                    try, row.Ctrl.Value = vectorToText(v); catch, end
                case {'text', 'dir', 'file', 'maskfile'}
                    if ~ischar(v), v = ''; end
                    try, row.Ctrl.Value = v; catch, end
                case 'roi'
                    try, row.Ctrl.Value = joinROI(v); catch, end
                case 'subjects'
                    obj.syncSubjects(idx, v);
            end
        end

        function syncSubjects(obj, idx, v)
            row = obj.RowList(idx);
            ids = normalizeIDList(v);
            n = numel(ids);
            if n == 0
                txt = '尚未选择受试者';
            else
                preview = strjoin(ids(1:min(3, n)), '、');
                if n > 3, preview = [preview ' 等']; end
                txt = sprintf('%d 名受试者：%s', n, preview);
            end
            try, row.Ctrl.Text = txt; catch, end
            try
                if n > 0
                    row.Ctrl.Tooltip = sprintf('共 %d 名受试者：\n%s', n, strjoin(ids, '、'));
                else
                    row.Ctrl.Tooltip = [row.BaseTip newline '（当前为空：在数据页扫描目录或手动添加）'];
                end
            catch
            end
        end

        function markInvalid(obj, idx, msg)
            obj.RowList(idx).Invalid = true;
            obj.RowList(idx).InvalidMsg = msg;
            obj.applyRowStyle(idx);
        end

        function clearInvalid(obj, idx)
            obj.RowList(idx).Invalid = false;
            obj.RowList(idx).InvalidMsg = '';
            obj.applyRowStyle(idx);
        end

        function applyRowStyle(obj, idx)
            row = obj.RowList(idx);
            c = mrw.UiKit.colors();
            tf = row.Enabled;
            baseBg = obj.rowBaseBg(row);
            if tf
                zhC = c.text; enC = c.muted; hintC = c.muted;
            else
                zhC = c.muted; enC = [0.63 0.65 0.70]; hintC = [0.63 0.65 0.70];
            end
            tip = row.BaseTip;
            if row.Invalid
                tip = sprintf('输入无效：%s\n\n%s', row.InvalidMsg, tip);
            end
            if ~tf
                tip = sprintf('【当前不可用：依赖条件未满足】\n%s', tip);
            end
            obj.styleHandle(row.ZH, tf, baseBg, zhC, tip);
            obj.styleHandle(row.EN, tf, baseBg, enC, tip);
            ctrlBg = c.panel;
            ctrlFg = c.text;
            if row.Invalid
                ctrlBg = c.errBg;
                ctrlFg = c.err;
            end
            obj.styleHandle(row.Ctrl, tf, ctrlBg, ctrlFg, tip);
            for k = 1:numel(row.Aux)
                obj.styleHandle(row.Aux(k), tf, [], c.text, tip);
            end
            hintText = row.HintBase;
            if row.Invalid
                hintText = ['输入无效：' row.InvalidMsg];
                hintC = c.err;
            end
            obj.styleHandle(row.Hint, true, baseBg, hintC, tip);
            try
                row.Hint.Text = hintText;
                row.Hint.Visible = onOff(~isempty(hintText));
            catch
            end
        end

        function styleHandle(~, h, tf, bg, fg, tip)
            if isempty(h) || ~isvalid(h), return; end
            try, h.Enable = onOff(tf); catch, end
            if ~isempty(bg)
                try, h.BackgroundColor = bg; catch, end
            end
            if ~isempty(fg)
                try, h.FontColor = fg; catch, end
            end
            if ~isempty(tip)
                try, h.Tooltip = tip; catch, end
            end
        end

        function bg = rowBaseBg(~, row)
            c = mrw.UiKit.colors();
            if row.Advanced
                bg = c.panelAlt;
            else
                bg = c.panel;
            end
        end

        function idx = rowIndex(obj, key)
            idx = [];
            if isempty(key) || ~ischar(key), return; end
            if isKey(obj.RowMap, key)
                idx = obj.RowMap(key);
            end
        end

        function t = tooltipFor(obj, entry)
            t = '';
            try
                t = mrw.Glossary.tooltipFromEntry(entry);
            catch
                t = '';
            end
            if isempty(t)
                t = sprintf('%s（%s）\n默认：%s', entry.Label, entry.EN, ...
                    defaultValueText(entry.Default));
            end
            if strcmp(entry.Type, 'vector')
                t = sprintf('%s\n\n输入格式：空格/逗号分隔，或冒号表达式；如 4 4 4、1:2:33、[-90 -126 -72; 90 90 108]', t);
            end
        end

        function s = glossaryText(obj, key)
            s = '';
            try
                e = mrw.Glossary.get(key);
                if isempty(e), return; end
                s = [e.ZH ' ' e.EN ' ' e.Tip ' ' e.Advice];
            catch
            end
        end
    end

    % ==================================================================
    %  交互回调
    % ==================================================================
    methods (Access = private)

        function onPresetChanged(obj)
            try
                v = obj.PresetDropdown.Value;
            catch
                return;
            end
            names = obj.Options.PresetNames;
            if isempty(names), return; end
            items = obj.PresetDropdown.Items;
            k = find(strcmp(items, v), 1);
            if isempty(k) || k <= 1, return; end
            name = names{k - 1};
            if ~isempty(obj.Options.PresetSelectedFcn)
                try
                    feval(obj.Options.PresetSelectedFcn, name);
                catch ME
                    obj.reportCallbackError('预设选择', ME);
                end
            end
            try
                obj.PresetDropdown.Value = items{1};
            catch
            end
        end

        function onSearchChanged(obj)
            try
                q = obj.SearchField.Value;
            catch
                q = '';
            end
            obj.searchFields(q);
        end

        function onResultPicked(obj)
            try
                v = obj.ResultsList.Value;
            catch
                return;
            end
            if isempty(v) || ~ischar(v), return; end
            try
                obj.SearchField.Value = '';
            catch
            end
            obj.hideSearchResults();
            obj.highlightKey(v);
        end

        function resetSearchUI(obj)
            try
                obj.SearchField.Value = '';
            catch
            end
            obj.hideSearchResults();
        end

        function showResults(obj, headerText, items, keys)
            try, obj.ResultsHeader.Text = headerText; catch, end
            try
                obj.ResultsList.ItemsData = {};
                obj.ResultsList.Items = items;
                obj.ResultsList.ItemsData = keys;
                if isempty(items)
                    obj.ResultsList.Visible = 'off';
                else
                    obj.ResultsList.Visible = 'on';
                end
            catch
                try, obj.ResultsList.Visible = 'off'; catch, end
            end
            n = numel(items);
            if n == 0
                H = 64;
            else
                H = min(330, 40 + 24 * n);
            end
            try
                rh = obj.Root.RowHeight;
                rh{2} = H;
                obj.Root.RowHeight = rh;
                obj.ResultsPanel.Visible = 'on';
            catch
            end
        end

        function onResetPressed(obj)
            obj.reset();
        end

        function onRunPressed(obj)
            if isempty(obj.Options.RunRequestedFcn), return; end
            try
                feval(obj.Options.RunRequestedFcn);
            catch ME
                obj.reportCallbackError('开始预处理', ME);
            end
        end

        function onManageSubjects(obj)
            try
                obj.notify('RequestSubjectEdit');
            catch ME
                obj.reportCallbackError('管理受试者列表', ME);
            end
        end

        function onBrowse(obj, idx)
            row = obj.RowList(idx);
            entry = row.Entry;
            cur = '';
            try, cur = char(row.Ctrl.Value); catch, end
            try
                startDir = obj.browseStartDir(cur);
                switch entry.Type
                    case 'dir'
                        d = uigetdir(startDir, sprintf('选择：%s', entry.Label));
                        if isequal(d, 0) || isempty(d), return; end
                        row.Ctrl.Value = d;
                        obj.onRowChanged(idx);
                    case {'file', 'maskfile'}
                        flt = {'*.nii;*.nii.gz;*.img;*.hdr', 'NIfTI 图像 (*.nii, *.nii.gz, *.img)'; ...
                               '*.*', '所有文件 (*.*)'};
                        [fn, fp] = uigetfile(flt, sprintf('选择：%s', entry.Label), startDir);
                        if isequal(fn, 0) || isempty(fn), return; end
                        row.Ctrl.Value = fullfile(fp, fn);
                        obj.onRowChanged(idx);
                    case 'roi'
                        [fn, fp] = uigetfile( ...
                            {'*.nii;*.nii.gz;*.img;*.hdr;*.mat;*.txt', ...
                             'ROI 定义 (*.nii, *.img, *.mat, *.txt)'; '*.*', '所有文件 (*.*)'}, ...
                            sprintf('选择：%s（可多选）', entry.Label), startDir, 'MultiSelect', 'on');
                        if isequal(fn, 0) || isempty(fn), return; end
                        if ischar(fn), fn = {fn}; end
                        newFiles = cellfun(@(x) fullfile(fp, x), fn, 'UniformOutput', false);
                        oldFiles = splitROI(char(row.Ctrl.Value));
                        allFiles = [oldFiles, newFiles];
                        row.Ctrl.Value = strjoin(allFiles, '; ');
                        obj.onRowChanged(idx);
                end
            catch ME
                obj.reportCallbackError('浏览/选择文件', ME);
            end
        end

        function sb = browseStartDir(~, cur)
            sb = pwd;
            try
                if ~isempty(cur) && ~any(strcmpi(cur, {'Default', 'default'}))
                    if exist(cur, 'dir') == 7
                        sb = cur;
                    elseif exist(cur, 'file') == 2
                        sb = fileparts(cur);
                    end
                end
            catch
            end
        end

        function reportCallbackError(~, what, ME)
            fprintf(2, '[PreprocessPanel] %s 回调失败：%s\n', what, ME.message);
        end

        function notifyChanged(obj)
            try
                notify(obj, 'Changed');
            catch
            end
        end
    end

    % ==================================================================
    %  摘要 / 页脚 / 闪烁 / 计数
    % ==================================================================
    methods (Access = private)

        function updateSummary(obj)
            steps = obj.stepsFromState();
            n = numel(steps);
            if n == 0
                s = '将执行：仅整理数据（尚未启用任何处理步骤）';
            else
                s = sprintf('将执行 %d 步：%s', n, strjoin(steps, ' → '));
                if numel(s) > 120
                    s = [s(1:119) '…'];
                end
            end
            obj.SummaryText = s;
            try
                obj.SummaryLabel.Text = s;
                obj.SummaryLabel.Tooltip = s;
            catch
            end
            obj.updateFooterInfo();
        end

        function steps = stepsFromState(obj)
            st = obj.State;
            steps = {};
            if isTrue(mrw.CfgSchema.getKey(st, 'IsSliceTiming')),  steps{end+1} = '时间层校正'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsRealign')),      steps{end+1} = '头动校正'; end
            seg = mrw.CfgSchema.getKey(st, 'IsSegment');
            if isnumeric(seg) && seg > 0, steps{end+1} = '脑组织分割'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsDARTEL')),       steps{end+1} = 'DARTEL 配准'; end
            nz = mrw.CfgSchema.getKey(st, 'IsNormalize');
            if isnumeric(nz) && nz > 0
                switch double(nz)
                    case 1, steps{end+1} = 'EPI 模板标准化';
                    case 2, steps{end+1} = '基于 T1 分割标准化';
                    case 3, steps{end+1} = 'DARTEL 标准化';
                    otherwise, steps{end+1} = '空间标准化';
                end
            end
            sm = mrw.CfgSchema.getKey(st, 'IsSmooth');
            if isnumeric(sm) && sm > 0
                if sm >= 2
                    steps{end+1} = 'DARTEL 平滑';
                else
                    steps{end+1} = '平滑';
                end
            end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCovremove')), steps{end+1} = '协变量回归'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsFilter')),    steps{end+1} = '滤波'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsDetrend')),   steps{end+1} = '去线性趋势'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCalALFF')),   steps{end+1} = 'ALFF/fALFF'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCalReHo')),   steps{end+1} = 'ReHo'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCalDegreeCentrality')), steps{end+1} = 'DC'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsExtractROISignals')),   steps{end+1} = 'ROI 时间序列'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCalFC')),     steps{end+1} = 'FC'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCalVMHC')),   steps{end+1} = 'VMHC'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsScrubbing')), steps{end+1} = 'Scrubbing'; end
            if isTrue(mrw.CfgSchema.getKey(st, 'IsCWAS')),      steps{end+1} = 'CWAS'; end
        end

        function updateFooterInfo(obj)
            if isempty(obj.FooterLabel) || ~isvalid(obj.FooterLabel), return; end
            ids = normalizeIDList(mrw.CfgSchema.getKey(obj.State, 'SubjectID'));
            if isempty(ids)
                sub = '受试者：未选择';
            else
                sub = sprintf('受试者：%d 名', numel(ids));
            end
            obj.FooterLabel.Text = sprintf('%s · 共 %d 项参数 · 鼠标悬停参数可查看中文解释', ...
                sub, obj.FieldCount);
        end

        function flashRow(obj, idx)
            obj.endFlash();
            if idx < 1 || idx > numel(obj.RowList), return; end
            row = obj.RowList(idx);
            c = mrw.UiKit.colors();
            try
                row.ZH.BackgroundColor = c.warnBg;
                row.EN.BackgroundColor = c.warnBg;
                row.Hint.BackgroundColor = c.warnBg;
            catch
            end
            try, row.Ctrl.BackgroundColor = c.warnBg; catch, end
            for k = 1:numel(row.Aux)
                try, row.Aux(k).BackgroundColor = c.warnBg; catch, end
            end
            obj.FlashRow = idx;
            try
                t = timer('ExecutionMode', 'singleShot', 'StartDelay', 1.5, ...
                    'TimerFcn', @(s, e) obj.onFlashTimer());
                obj.FlashTimer = t;
                start(t);
            catch
                obj.FlashTimer = [];
            end
        end

        function endFlash(obj)
            t = obj.FlashTimer;
            obj.FlashTimer = [];
            if isempty(t), return; end
            try
                if isvalid(t)
                    stop(t);
                    delete(t);
                end
            catch
            end
            idx = obj.FlashRow;
            obj.FlashRow = 0;
            if idx >= 1 && idx <= numel(obj.RowList)
                try, obj.applyRowStyle(idx); catch, end
            end
            try, obj.updateFooterInfo(); catch, end
        end

        function onFlashTimer(obj)
            t = obj.FlashTimer;
            obj.FlashTimer = [];
            try
                if ~isempty(t) && isvalid(t)
                    stop(t);
                    delete(t);
                end
            catch
            end
            idx = obj.FlashRow;
            obj.FlashRow = 0;
            if idx >= 1 && idx <= numel(obj.RowList)
                try, obj.applyRowStyle(idx); catch, end
            end
            try, obj.updateFooterInfo(); catch, end
        end

        function updateControlCount(obj)
            try
                h = findall(obj.Root);
                cls = arrayfun(@(x) class(x), h, 'UniformOutput', false);
                isCtl = ~cellfun(@isempty, regexp(cls, '^matlab\.ui\.control\.', 'once'));
                obj.ControlCount = sum(isCtl);
            catch
                obj.ControlCount = numel(obj.RowList) * 4;
            end
        end

        function delete(obj)
            try
                if ~isempty(obj.FlashTimer) && isvalid(obj.FlashTimer)
                    stop(obj.FlashTimer);
                    delete(obj.FlashTimer);
                end
            catch
            end
        end
    end
end

% ======================================================================
%  文件内局部函数（纯函数，供类方法使用）
% ======================================================================

function p = emptyPageStruct()
p = struct('Group', '', 'Tab', [], 'Fill', [], 'Scroll', [], ...
    'Content', [], 'Title', [], 'Desc', [], 'Count', [], 'Sep', [], ...
    'Toggle', [], 'AdvPanel', [], 'RowsNormal', [], 'RowsAdv', [], ...
    'Expanded', false, 'Built', false, 'Viewport', [1000 560]);
end

function s = groupDescription(group)
switch group
    case '基础设置'
        s = '数据目录、受试者列表与时间参数';
    case '时间层与头动'
        s = '删除初始时间点、时间层校正与头动校正';
    case '结构像处理'
        s = '原点调整、去颅骨、脑组织分割与 DARTEL';
    case '标准化与平滑'
        s = '空间标准化、掩膜文件与平滑参数';
    case '回归与滤波'
        s = '协变量回归、带通滤波与去线性趋势';
    case '指标计算'
        s = 'ALFF/fALFF、ReHo、DC、FC、VMHC 等指标';
    case '高级与运行'
        s = '特殊模式、交互选项与并行设置';
    otherwise
        s = '本组参数与默认值说明';
end
end

function s = hintForKey(entry)
s = '';
isVec = strcmp(entry.Type, 'vector');
switch entry.Key
    case 'TR'
        s = '0 = 自动读取';
    case 'TimePoints'
        s = '0 = 自动读取';
    case 'SliceTiming.SliceNumber'
        s = '0 = 自动读取';
    case 'SliceTiming.ReferenceSlice'
        s = '0 = 自动选择';
    case 'StartingDirName'
        s = '如 FunRaw';
    case 'SliceTiming.SliceOrder'
        s = '1×N，如 1:2:33, 2:2:32';
    case 'Normalize.VoxSize'
        s = '3 个数值，如 3 3 3';
    case 'Smooth.FWHM'
        s = '3 个数值，如 4 4 4';
    case 'Normalize.BoundingBox'
        s = '2×3 矩阵，起始; 终止';
    case 'MaskFile'
        s = 'Default = SPM 自带';
    case 'CalFC.ROIDef'
        s = '分号分隔多个 ROI';
    case 'Covremove.OtherCovariatesROI'
        s = '分号分隔多个 ROI';
    case 'CWAS.Regressors'
        s = '分号分隔多个文件';
    case 'ParallelWorkersNumber'
        s = '0 = 关闭并行';
    otherwise
        if isVec
            s = '支持空格/分号/冒号写法';
        end
end
end

function tf = isTrue(v)
tf = false;
if isempty(v), return; end
if islogical(v) || isnumeric(v)
    tf = any(v(:) ~= 0);
end
end

function tf = onOff(b)
if b
    tf = 'on';
else
    tf = 'off';
end
end

function s = defaultValueText(v)
if iscell(v)
    s = sprintf('%d 项', numel(v));
elseif ischar(v)
    if isempty(v), s = '空'; else, s = v; end
elseif isnumeric(v) && isscalar(v)
    s = num2str(v);
elseif isnumeric(v)
    s = mat2str(v);
elseif isempty(v)
    s = '空';
else
    s = class(v);
end
end

function s = vectorToText(v)
s = '';
if isempty(v), return; end
if ~isnumeric(v) && ~islogical(v)
    if ischar(v), s = v; end
    return;
end
if isvector(v)
    s = compressNumericRow(reshape(v, 1, []));
else
    rows = cell(1, size(v, 1));
    for r = 1:size(v, 1)
        rows{r} = compressNumericRow(v(r, :));
    end
    s = strjoin(rows, '; ');
end
end

function s = compressNumericRow(v)
n = numel(v);
parts = cell(1, 0);
i = 1;
while i <= n
    if i + 2 <= n
        d = v(i + 1) - v(i);
        if d ~= 0
            j = i + 1;
            while j + 1 <= n && (v(j + 1) - v(j)) == d
                j = j + 1;
            end
            if j - i + 1 >= 3
                parts{end+1} = sprintf('%s:%s:%s', ...
                    num2str(v(i)), num2str(d), num2str(v(j))); %#ok<AGROW>
                i = j + 1;
                continue;
            end
        end
    end
    parts{end+1} = num2str(v(i)); %#ok<AGROW>
    i = i + 1;
end
s = strjoin(parts, ', ');
end

function [v, ok, msg] = parseVectorText(key, txt)
v = []; ok = false; msg = '格式无效';
txt = strtrim(txt);
if isempty(txt)
    msg = '不能为空';
    return;
end
if isempty(regexp(txt, '^[\d\s,;:.\[\]\-+eE]+$', 'once'))
    msg = '仅支持数值/空格/逗号/分号/冒号';
    return;
end
try
    vv = str2num(txt); %#ok<ST2NM>
catch
    msg = '无法解析为数值';
    return;
end
if isempty(vv) || ~isnumeric(vv)
    msg = '无法解析为数值';
    return;
end
[v, ok, msg] = validateVectorShape(key, vv);
end

function [v, ok, msg] = validateVectorShape(key, vv)
v = []; ok = false; msg = '维度不符合要求';
if isempty(vv) || ~isnumeric(vv), return; end
switch key
    case 'SliceTiming.SliceOrder'
        if isvector(vv)
            v = reshape(vv, 1, []);
            ok = true; msg = '';
        else
            msg = '应为 1×N 向量';
        end
    case {'Normalize.VoxSize', 'Smooth.FWHM'}
        if numel(vv) == 3 && (isvector(vv) || isequal(size(vv), [1 3]) || isequal(size(vv), [3 1]))
            v = reshape(vv, 1, 3);
            ok = true; msg = '';
        else
            msg = '应为 3 个数值';
        end
    case 'Normalize.BoundingBox'
        if isequal(size(vv), [2 3])
            v = vv; ok = true; msg = '';
        elseif numel(vv) == 6 && isvector(vv)
            v = reshape(vv, 2, 3); ok = true; msg = '';
        else
            msg = '应为 2×3 矩阵';
        end
    otherwise
        if isvector(vv)
            v = reshape(vv, 1, []);
            ok = true; msg = '';
        elseif isnumeric(vv)
            v = vv; ok = true; msg = '';
        end
end
end

function cur = enumValueOrDefault(data, v)
cur = [];
if isempty(data), return; end
if isnumeric(data)
    if isnumeric(v) && isscalar(v) && any(data == v)
        cur = v;
    else
        cur = data(1);
    end
else
    if ischar(v) && any(strcmp(data, v))
        cur = v;
    else
        cur = data{1};
    end
end
end

function tf = isValidEnumValue(entry, value)
tf = false;
if islogical(value), value = double(value); end
opts = entry.Options;
if isempty(opts), return; end
raw = {opts.Value};
if all(cellfun(@isnumeric, raw))
    data = cell2mat(raw);
    tf = isnumeric(value) && isscalar(value) && any(data == value);
else
    data = cellfun(@(x) char(x), raw, 'UniformOutput', false);
    tf = ischar(value) && any(strcmp(data, value));
end
end

function ids = normalizeIDList(v)
ids = {};
if isempty(v), return; end
if ischar(v)
    if ~isempty(v), ids = {v}; end
elseif isstring(v)
    ids = cellstr(v);
elseif iscell(v)
    ids = cellfun(@(x) char(x), v, 'UniformOutput', false);
    ids = ids(~cellfun(@isempty, ids));
end
end

function c = splitROI(txt)
c = {};
if isempty(txt), return; end
if iscell(txt)
    c = cellfun(@(x) strtrim(char(x)), txt, 'UniformOutput', false);
    c = c(~cellfun(@isempty, c));
    return;
end
parts = regexp(char(txt), '[;\r\n]+', 'split');
parts = cellfun(@(x) strtrim(x), parts, 'UniformOutput', false);
c = parts(~cellfun(@isempty, parts));
end

function s = joinROI(v)
if isempty(v)
    s = '';
elseif ischar(v)
    s = v;
elseif isstring(v)
    s = strjoin(cellstr(v), '; ');
elseif iscell(v)
    s = strjoin(cellfun(@(x) char(x), v, 'UniformOutput', false), '; ');
else
    s = '';
end
end

function tf = hasFieldPath(st, path)
tf = true;
parts = strsplit(path, '.');
cur = st;
for k = 1:numel(parts)
    if isstruct(cur) && isfield(cur, parts{k})
        cur = cur.(parts{k});
    else
        tf = false;
        return;
    end
end
end

function v = detField(det, name)
v = [];
if isstruct(det) && isfield(det, name)
    v = det.(name);
end
end
