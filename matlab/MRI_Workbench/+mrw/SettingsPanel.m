classdef SettingsPanel < handle
% SettingsPanel  “设置与帮助”页面：环境检测、DPABI/SPM 路径、运行选项、原生界面入口
%
% 负责:
%   - 显示 DPABI/SPM/MATLAB/并行工具箱环境状态；
%   - 手动指定 DPABI/SPM 根目录并保存到 config/settings.json；
%   - 原生界面汉化开关、允许交互开关、扫描深度；
%   - 一键打开原生 DPABI / DPARSF 界面（自动应用汉化补丁）。

    properties (Access = private)
        Parent
        Cb = struct()
        DpabiEdit
        SpmEdit
        DataRootEdit
        EnvGrid
        EnvLabels = struct()
        NativePatchCheck
        AllowGUICheck
        DepthField
        VersionLabel
        AboutArea
    end

    methods

        function obj = SettingsPanel(parent, callbacks)
            obj.Parent = parent;
            if nargin >= 2 && isstruct(callbacks)
                obj.Cb = callbacks;
            end
            obj.buildUI();
            obj.refreshEnv();
        end

        function refreshEnv(obj)
            st = mrw.Dpabi.status();
            s = mrw.Settings.load();
            c = mrw.UiKit.colors();
            pairs = { ...
                obj.EnvLabels.a, st.HasDpabi, sprintf('DPABI：%s', obj.orUnknown(st.DpabiRoot)); ...
                obj.EnvLabels.b, st.HasSpm,  sprintf('SPM12：%s', obj.orUnknown(st.SpmRoot)); ...
                obj.EnvLabels.c, st.HasEngine, 'DPARSFA 引擎：DPARSFA_run.m'; ...
                obj.EnvLabels.d, st.PCT, '并行工具箱（PCT）'};
            for i = 1:size(pairs, 1)
                lb = pairs{i,1};
                ok = logical(pairs{i,2});
                if ok
                    lb.Text = ['● ' pairs{i,3}];
                    lb.FontColor = c.ok;
                else
                    lb.Text = ['○ ' pairs{i,3} '（未就绪）'];
                    lb.FontColor = c.err;
                end
            end
            obj.VersionLabel.Text = sprintf('DPABI 版本：%s     MATLAB：%s', ...
                obj.orUnknown(st.DpabiVersion), st.MatlabVersion);
            if isempty(obj.DpabiEdit.Value) && ~isempty(st.DpabiRoot)
                obj.DpabiEdit.Value = st.DpabiRoot;
            end
            if isempty(obj.SpmEdit.Value) && ~isempty(st.SpmRoot)
                obj.SpmEdit.Value = st.SpmRoot;
            end
            obj.NativePatchCheck.Value = logical(s.NativePatch);
            obj.AllowGUICheck.Value = logical(s.AllowGUI);
            obj.DepthField.Value = s.ScanMaxDepth;
            if isempty(obj.DataRootEdit.Value)
                obj.DataRootEdit.Value = s.LastDataRoot;
            end
            obj.AboutArea.Value = { ...
                'MRI 静息态分析工作台（MATLAB + DPABI/DPARSF + SPM12）', ...
                '', ...
                '本工作台不修改 DPABI 安装文件，所有预处理计算由官方 DPARSFA_run.m 引擎完成。', ...
                '界面中每个参数都有鼠标悬停解释（内容来自 resources/glossary.tsv），', ...
                '可在“术语库”页面检索中英文对照。', ...
                '', ...
                '工作流程：① 数据索引（自动扫描）→ ② 预处理参数 → ③ 运行与日志。', ...
                '如需 DPABI 原生高级功能（交互重定向、FieldMap、ROI 交互定义等），', ...
                '可点击上方“打开原生 DPARSF 高级版”，打开后会自动汉化界面并添加悬停解释。'};
        end
    end

    methods (Access = private)

        function buildUI(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            g = uigridlayout(obj.Parent, [4 1]);
            g.RowHeight = {'fit', 'fit', 'fit', '1x'};
            g.Padding = [12 12 12 12];
            g.RowSpacing = 10;
            g.BackgroundColor = c.bg;

            % 环境状态
            p1 = mrw.UiKit.card(g, '环境状态');
            pg = uigridlayout(p1, [2 1]);
            pg.RowHeight = {'fit', 'fit'};
            pg.Padding = [10 8 10 8];
            pg.BackgroundColor = c.panel;
            obj.EnvGrid = uigridlayout(pg, [2 2]);
            obj.EnvGrid.ColumnWidth = {'1x', '1x'};
            obj.EnvGrid.RowHeight = {26, 26};
            obj.EnvGrid.Padding = [0 0 0 0];
            obj.EnvGrid.BackgroundColor = c.panel;
            obj.EnvLabels.a = uilabel(obj.EnvGrid, 'Text', '检测中…', 'FontName', f.name);
            obj.EnvLabels.b = uilabel(obj.EnvGrid, 'Text', '', 'FontName', f.name);
            obj.EnvLabels.c = uilabel(obj.EnvGrid, 'Text', '', 'FontName', f.name);
            obj.EnvLabels.d = uilabel(obj.EnvGrid, 'Text', '', 'FontName', f.name);
            obj.VersionLabel = uilabel(pg, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);
            % 环境状态占位（具体文字由 refreshEnv 填充）

            % 路径设置
            p2 = mrw.UiKit.card(g, '路径设置（留空=自动探测）');
            gl2 = uigridlayout(p2, [4 3]);
            gl2.ColumnWidth = {150, '1x', 90};
            gl2.RowHeight = {28, 28, 28, 28};
            gl2.Padding = [10 8 10 8];
            gl2.BackgroundColor = c.panel;
            uilabel(gl2, 'Text', 'DPABI 根目录：', 'FontName', f.name);
            obj.DpabiEdit = uieditfield(gl2, 'text', 'FontName', f.name);
            uibutton(gl2, 'Text', '浏览…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.browseDir(obj.DpabiEdit, '选择 DPABI 根目录'));
            uilabel(gl2, 'Text', 'SPM12 根目录：', 'FontName', f.name);
            obj.SpmEdit = uieditfield(gl2, 'text', 'FontName', f.name);
            uibutton(gl2, 'Text', '浏览…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.browseDir(obj.SpmEdit, '选择 SPM12 根目录'));
            uilabel(gl2, 'Text', '默认数据根目录：', 'FontName', f.name);
            obj.DataRootEdit = uieditfield(gl2, 'text', 'FontName', f.name);
            uibutton(gl2, 'Text', '浏览…', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.browseDir(obj.DataRootEdit, '选择默认数据根目录'));
            uilabel(gl2, 'Text', '', 'FontName', f.name);
            uibutton(gl2, 'Text', '保存路径并重新检测环境', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.savePaths());
            uilabel(gl2, 'Text', '保存后立即生效', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);

            % 选项 + 原生界面入口
            p3 = mrw.UiKit.card(g, '运行选项与原生界面');
            gl3 = uigridlayout(p3, [2 1]);
            gl3.RowHeight = {'fit', 'fit'};
            gl3.Padding = [10 8 10 8];
            gl3.BackgroundColor = c.panel;
            opts = uigridlayout(gl3, [1 5]);
            opts.ColumnWidth = {'1x', '1x', 160, 140, '1x'};
            opts.Padding = [0 4 0 4];
            opts.BackgroundColor = c.panel;
            obj.NativePatchCheck = uicheckbox(opts, 'Text', '原生界面汉化 + 悬停解释', ...
                'FontName', f.name, 'Value', true, ...
                'ValueChangedFcn', @(s, e) obj.saveOptions());
            obj.AllowGUICheck = uicheckbox(opts, 'Text', '后台运行允许交互弹窗（不推荐）', ...
                'FontName', f.name, 'Value', false, ...
                'ValueChangedFcn', @(s, e) obj.saveOptions());
            uilabel(opts, 'Text', '扫描最大深度：', 'FontName', f.name, ...
                'HorizontalAlignment', 'right');
            obj.DepthField = uieditfield(opts, 'numeric', 'Limits', [1 20], ...
                'RoundFractionalValues', 'on', 'Value', 6, ...
                'ValueChangedFcn', @(s, e) obj.saveOptions());
            uilabel(opts, 'Text', '', 'FontName', f.name);
            launch = uigridlayout(gl3, [1 4]);
            launch.ColumnWidth = {180, 180, 180, '1x'};
            launch.Padding = [0 4 0 4];
            launch.BackgroundColor = c.panel;
            uibutton(launch, 'Text', '打开原生 DPABI 主界面', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.launchNative('dpabi'));
            uibutton(launch, 'Text', '打开原生 DPARSF 高级版', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.launchNative('dparsfa'));
            uibutton(launch, 'Text', '打开原生 DPARSF 经典版', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.launchNative('dparsf'));
            uilabel(launch, 'Text', '打开后自动汉化界面（如已启用）；鼠标悬停查看术语解释', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted);

            % 关于
            p4 = mrw.UiKit.card(g, '关于 / 使用提示');
            g4 = uigridlayout(p4, [1 1]);
            g4.Padding = [10 8 10 8];
            g4.BackgroundColor = c.panel;
            obj.AboutArea = uitextarea(g4, 'Editable', 'off', 'FontName', f.name, ...
                'FontSize', f.base, 'BackgroundColor', c.panel, ...
                'Value', {'加载中…'});
        end

        function savePaths(obj)
            s = mrw.Settings.load();
            s.DpabiRoot = strtrim(obj.DpabiEdit.Value);
            s.SpmRoot = strtrim(obj.SpmEdit.Value);
            s.LastDataRoot = strtrim(obj.DataRootEdit.Value);
            mrw.Settings.commit(s);
            mrw.Dpabi.resetCache();
            mrw.Dpabi.ensurePath();
            obj.refreshEnv();
            obj.notifyStatus('路径已保存，环境已重新检测');
        end

        function saveOptions(obj)
            s = mrw.Settings.load();
            s.NativePatch = logical(obj.NativePatchCheck.Value);
            s.AllowGUI = logical(obj.AllowGUICheck.Value);
            s.ScanMaxDepth = obj.DepthField.Value;
            mrw.Settings.commit(s);
            obj.notifyStatus('运行选项已保存');
        end

        function launchNative(obj, which)
            try
                switch which
                    case 'dpabi'
                        mrw.Dpabi.launchDPABI();
                    case 'dparsfa'
                        mrw.Dpabi.launchDPARSFA('Blank');
                    case 'dparsf'
                        mrw.Dpabi.launchDPARSFMain();
                end
            catch err
                errordlg(sprintf('打开原生界面失败：%s', err.message), '错误');
            end
        end

        function notifyStatus(obj, msg)
            if isfield(obj.Cb, 'OnStatus') && ~isempty(obj.Cb.OnStatus)
                try, feval(obj.Cb.OnStatus, msg); catch, end
            end
        end

        function browseDir(obj, edit, titleText)
            d = uigetdir(edit.Value, titleText);
            if ischar(d) && ~isequal(d, 0)
                edit.Value = d;
            end
        end
    end

    methods (Static, Access = private)
        function t = orUnknown(v)
            if isempty(v), t = '未找到'; else, t = v; end
        end
    end
end
