classdef WorkbenchApp < handle
% WorkbenchApp  静息态 MRI 分析工作台主程序（MATLAB uifigure）
%
% 页面:
%   ① 数据索引    自动搜索/索引数据目录（替代 DPARSF 手动逐步指定）
%   ② 预处理参数  中文参数面板（悬停解释），由 mrw.PreprocessPanel 提供
%   ③ 运行与日志  后台调用 DPARSFA_run，实时日志/进度，可取消
%   ④ 术语库      中英文术语检索 + 解释
%   ⑤ 设置与帮助  环境检测、路径、原生 DPABI/DPARSF 入口（含汉化补丁）
%   ⑥ 人工QC      可缩放图像查看 + DPARSF 兼容 1–5 分人工评分
%
% 启动方式: 在 MATLAB 中运行  StartWorkbench

    properties
        Fig
        Env = struct()
        Pages = {}
        NavList
        DataPanel
        PrepPanel
        RunPanel
        GlossaryPanel
        SettingsPanel
        QcPanel = []
        Runner = []
        ScanIndex = []
        LastCfg = []
        HeaderBadges = struct()
        StatusLabel
        NavStatusLabel
        TitleLabels = {}
    end

    methods

        function obj = WorkbenchApp()
            here = fileparts(mfilename('fullpath'));
            projRoot = fileparts(here);
            addpath(projRoot);
            obj.Env = mrw.Dpabi.status();
            try
                mrw.Dpabi.ensurePath();
            catch
            end
            obj.buildUI();
            obj.refreshEnvUI();
            try
                setappdata(obj.Fig, 'MRW_WorkbenchApp', obj);
            catch
            end
        end
        function showPage(obj, idx)
            % 公共接口：切换页面（1 数据索引 / 2 预处理 / 3 运行 / 4 术语库 / 5 设置 / 6 人工QC）
            obj.switchPage(idx);
        end

        function openQc(obj)
            % 公共接口：打开「人工 QC」页并同步当前工作目录
            obj.switchPage(6);
        end

        function qp = qcPanel(obj)
            % 公共接口：返回人工 QC 面板句柄（可能为空）
            qp = obj.QcPanel;
        end

        function refreshEnvironment(obj)
            % 公共接口：重新检测并在界面刷新环境状态
            try
                mrw.Dpabi.resetCache();
                mrw.Dpabi.ensurePath();
            catch
            end
            obj.refreshEnvUI();
        end

        function idx = currentScanIndex(obj)
            % 公共接口：当前数据索引
            idx = obj.ScanIndex;
        end

        function applyScanIndex(obj, idx)
            % 公共接口：把数据索引应用到预处理参数（同“应用到预处理参数”按钮）
            obj.onScanApplied(idx);
        end

        function applyPreset(obj, name)
            % 公共接口：应用预设
            obj.onPresetSelected(name);
        end

        function startRun(obj)
            % 公共接口：开始预处理（同“开始预处理”按钮）
            obj.onStartRun();
        end

        function cancelRun(obj)
            % 公共接口：取消运行（无确认对话框，供脚本/测试使用）
            if ~isempty(obj.Runner) && isa(obj.Runner, 'mrw.Runner') && obj.Runner.Running
                obj.Runner.cancel();
            end
        end

        function st = runStatus(obj)
            % 公共接口：当前运行状态
            if ~isempty(obj.Runner) && isa(obj.Runner, 'mrw.Runner')
                st = obj.Runner.getStatus();
            else
                st = struct('State', 'idle', 'Message', '空闲', 'Progress', 0, ...
                    'Elapsed', 0, 'Phases', {{}});
            end
        end
    end

    methods (Access = private)

        % ================= 构建界面 =================
        function buildUI(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            obj.Fig = mrw.UiKit.newFigure('MRI 静息态分析工作台（DPABI / DPARSF）', [1500 920]);
            obj.Fig.CloseRequestFcn = @(s, e) obj.onClose();

            main = uigridlayout(obj.Fig, [3 1]);
            main.RowHeight = {76, '1x', 30};
            main.Padding = [0 0 0 0];
            main.RowSpacing = 0;
            main.BackgroundColor = c.bg;

            % ---------- 顶部标题栏 ----------
            header = uipanel(main, 'BorderType', 'none', 'BackgroundColor', c.header);
            header.Layout.Row = 1;
            hg = uigridlayout(header, [1 4]);
            hg.ColumnWidth = {'fit', 360, '1x', 'fit'};
            hg.Padding = [18 8 18 8];
            hg.BackgroundColor = c.header;

            titleBox = uigridlayout(hg, [2 1]);
            titleBox.RowHeight = {'fit', 'fit'};
            titleBox.Padding = [0 0 0 0];
            titleBox.BackgroundColor = c.header;
            t1 = uilabel(titleBox, 'Text', '静息态 MRI 分析工作台', 'FontName', f.name, ...
                'FontSize', 20, 'FontWeight', 'bold', 'FontColor', [1 1 1]);
            t2 = uilabel(titleBox, 'Text', '自动数据索引 · 中文参数界面 · 悬停解释 · 人工QC · DPARSFA 预处理引擎', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', [0.78 0.85 0.92]);

            badgeBox = uigridlayout(hg, [2 2]);
            badgeBox.RowHeight = {'fit', 'fit'};
            badgeBox.ColumnWidth = {'1x', '1x'};
            badgeBox.Padding = [10 2 0 2];
            badgeBox.BackgroundColor = c.header;
            obj.HeaderBadges.dpabi = uilabel(badgeBox, 'Text', 'DPABI: 检测中…', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', [0.9 0.95 1]);
            obj.HeaderBadges.spm = uilabel(badgeBox, 'Text', 'SPM12: 检测中…', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', [0.9 0.95 1]);
            obj.HeaderBadges.engine = uilabel(badgeBox, 'Text', 'DPARSFA 引擎: 检测中…', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', [0.9 0.95 1]);
            obj.HeaderBadges.parallel = uilabel(badgeBox, 'Text', '并行: 检测中…', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', [0.9 0.95 1]);

            btnBox = uigridlayout(hg, [1 5]);
            btnBox.ColumnWidth = {150, 150, 104, 104, 96};
            btnBox.Padding = [0 0 0 0];
            btnBox.BackgroundColor = c.header;
            uibutton(btnBox, 'Text', '打开原生 DPABI', 'FontName', f.name, ...
                'BackgroundColor', c.header2, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.openNative('dpabi'));
            uibutton(btnBox, 'Text', '原生 DPARSF 高级版', 'FontName', f.name, ...
                'BackgroundColor', c.header2, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.openNative('dparsfa'));
            uibutton(btnBox, 'Text', '人工QC', 'FontName', f.name, ...
                'BackgroundColor', c.ok, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.openQc());
            uibutton(btnBox, 'Text', '术语库', 'FontName', f.name, ...
                'BackgroundColor', c.accent, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.switchPage(4));
            uibutton(btnBox, 'Text', '设置', 'FontName', f.name, ...
                'BackgroundColor', c.accent, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(s, e) obj.switchPage(5));

            % ---------- 主体：左侧导航 + 右侧页面 ----------
            body = uigridlayout(main, [1 2]);
            body.ColumnWidth = {216, '1x'};
            body.Padding = [10 10 10 6];
            body.ColumnSpacing = 10;
            body.BackgroundColor = c.bg;

            navPanel = uipanel(body, 'BorderType', 'none', 'BackgroundColor', c.panel);
            navG = uigridlayout(navPanel, [4 1]);
            navG.RowHeight = {'fit', '1x', 'fit', 'fit'};
            navG.Padding = [10 12 10 12];
            navG.RowSpacing = 8;
            navG.BackgroundColor = c.panel;
            uilabel(navG, 'Text', '工作流程', 'FontName', f.name, ...
                'FontSize', f.medium, 'FontWeight', 'bold', 'FontColor', c.muted);
            obj.NavList = uilistbox(navG, 'Items', { ...
                '① 数据索引（自动搜索）', ...
                '② 预处理参数', ...
                '③ 运行与日志', ...
                '④ 术语库 / 悬停解释', ...
                '⑤ 设置与帮助', ...
                '⑥ 人工QC（可缩放）'}, ...
                'FontName', f.name, 'FontSize', f.medium, ...
                'ValueChangedFcn', @(s, e) obj.onNavChanged());
            obj.NavList.Value = '① 数据索引（自动搜索）';
            obj.NavStatusLabel = uilabel(navG, 'Text', '提示：先扫描数据目录，自动填写工作目录与受试者列表', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted);
            try, obj.NavStatusLabel.WordWrap = 'on'; catch, end
            navFoot = uigridlayout(navG, [1 1]);
            navFoot.Padding = [0 0 0 0];
            navFoot.BackgroundColor = c.panel;
            obj.NavStatusLabel.Layout.Row = 3;

            content = uipanel(body, 'BorderType', 'none', 'BackgroundColor', c.bg);
            contentGrid = uigridlayout(content, [1 1]);
            contentGrid.Padding = [0 0 0 0];
            contentGrid.BackgroundColor = c.bg;
            obj.Pages = cell(1, 6);
            for i = 1:6
                pg = uipanel(contentGrid, 'BorderType', 'none', 'BackgroundColor', c.bg);
                pg.Layout.Row = 1;
                pg.Layout.Column = 1;
                pg.Visible = 'off';
                obj.Pages{i} = pg;
            end

            % --- ① 数据索引 ---
            obj.DataPanel = mrw.DataPanel(obj.Pages{1}, struct( ...
                'OnApply', @(idx) obj.onScanApplied(idx), ...
                'OnStatus', @(msg) obj.setStatus(msg)));

            % --- ② 预处理参数 ---
            try
                mrw.Dpabi.ensurePath();
                P = mrw.CfgBuilder.presets();
                presetNames = {P.Name};
            catch
                presetNames = {};
            end
            try
                obj.PrepPanel = mrw.PreprocessPanel(obj.Pages{2}, struct( ...
                    'PresetNames', {presetNames}, ...
                    'PresetSelectedFcn', @(name) obj.onPresetSelected(name), ...
                    'RunRequestedFcn', @() obj.onStartRun()));
                addlistener(obj.PrepPanel, 'Changed', @(s, e) obj.onPrepChanged());
                addlistener(obj.PrepPanel, 'RequestSubjectEdit', @(s, e) obj.onSubjectEdit());
            catch err
                fallback = uipanel(obj.Pages{2}, 'BorderType', 'none', 'BackgroundColor', c.bg);
                gl = uigridlayout(fallback, [1 1]);
                gl.Padding = [20 20 20 20];
                uilabel(gl, 'Text', ['预处理参数面板加载失败：' err.message], ...
                    'FontName', f.name, 'FontSize', f.base, 'FontColor', c.err, ...
                    'VerticalAlignment', 'top');
                obj.PrepPanel = [];
            end

            % --- ③ 运行与日志 ---
            obj.RunPanel = mrw.RunPanel(obj.Pages{3}, struct( ...
                'OnStart', @() obj.onStartRun(), ...
                'OnCancel', @() obj.onCancelRun(), ...
                'OnCheck', @() obj.onCheckCfg(), ...
                'OnSaveCfg', @() obj.onSaveCfg(), ...
                'OnLoadCfg', @() obj.onLoadCfg(), ...
                'OnOpenOutput', @() obj.onOpenOutput(), ...
                'OnOpenQC', @() obj.openQc(), ...
                'OnOpenRunDir', @() obj.onOpenRunDir()));

            % --- ④ 术语库 ---
            obj.GlossaryPanel = mrw.GlossaryPanel(obj.Pages{4});

            % --- ⑤ 设置与帮助 ---
            obj.SettingsPanel = mrw.SettingsPanel(obj.Pages{5}, struct( ...
                'OnStatus', @(msg) obj.setStatus(msg)));

            % --- ⑥ 人工 QC（可缩放查看 + DPARSF 兼容评分） ---
            obj.QcPanel = [];
            if exist('mrw.QcPanel', 'class') == 8
                try
                    obj.QcPanel = mrw.QcPanel(obj.Pages{6}, struct( ...
                        'WorkingDir', obj.qcWorkingDir(), ...
                        'Modality', 'T1', 'Footer', true));
                    try
                        addlistener(obj.QcPanel, 'Changed', @(s, e) obj.setStatus('人工QC评分已更新', 'ok'));
                    catch
                    end
                catch err
                    obj.showQcFallback(['人工QC面板初始化失败：' err.message]);
                end
            else
                obj.showQcFallback('人工QC组件尚未就绪（+mrw/QcPanel.m）');
            end

            % ---------- 底部状态栏 ----------
            statusPanel = uipanel(main, 'BorderType', 'none', 'BackgroundColor', c.panelAlt);
            sg = uigridlayout(statusPanel, [1 3]);
            sg.ColumnWidth = {'1x', 320, 160};
            sg.Padding = [14 2 14 2];
            sg.BackgroundColor = c.panelAlt;
            obj.StatusLabel = uilabel(sg, 'Text', '就绪', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted);
            uilabel(sg, 'Text', '数据不会离开本机 · 所有计算由 DPABI 官方引擎执行', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'HorizontalAlignment', 'right');
            uilabel(sg, 'Text', ['MATLAB ' version], ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'HorizontalAlignment', 'right');

            obj.switchPage(1);
            obj.onPrepChanged();
        end

        % ================= 环境与状态 =================
        function refreshEnvUI(obj)
            st = mrw.Dpabi.status();
            obj.Env = st;
            c = mrw.UiKit.colors();
            b = obj.HeaderBadges;
            if st.HasDpabi
                b.dpabi.Text = sprintf('DPABI %s：已就绪', st.DpabiVersion);
                b.dpabi.FontColor = [0.72 0.95 0.78];
            else
                b.dpabi.Text = 'DPABI：未找到 → 请到“设置”指定路径';
                b.dpabi.FontColor = [1 0.78 0.72];
            end
            if st.HasSpm
                b.spm.Text = 'SPM12：已就绪';
                b.spm.FontColor = [0.72 0.95 0.78];
            else
                b.spm.Text = 'SPM12：未找到';
                b.spm.FontColor = [1 0.78 0.72];
            end
            if st.HasEngine
                b.engine.Text = 'DPARSFA 引擎：已就绪';
                b.engine.FontColor = [0.72 0.95 0.78];
            else
                b.engine.Text = 'DPARSFA 引擎：未就绪';
                b.engine.FontColor = [1 0.78 0.72];
            end
            if st.PCT
                b.parallel.Text = '并行工具箱：已安装';
                b.parallel.FontColor = [0.72 0.95 0.78];
            else
                b.parallel.Text = '并行工具箱：未安装';
                b.parallel.FontColor = [0.85 0.85 0.85];
            end
            obj.setStatus(st.Message);
        end

        function onNavChanged(obj)
            items = obj.NavList.Items;
            idx = find(strcmp(items, obj.NavList.Value), 1);
            if isempty(idx), idx = 1; end
            obj.switchPage(idx);
        end

        function switchPage(obj, idx)
            for i = 1:numel(obj.Pages)
                if isempty(obj.Pages{i}), continue; end
                obj.Pages{i}.Visible = 'off';
            end
            if idx >= 1 && idx <= numel(obj.Pages) && ~isempty(obj.Pages{idx})
                obj.Pages{idx}.Visible = 'on';
            end
            if ~isempty(obj.NavList)
                items = obj.NavList.Items;
                if idx <= numel(items)
                    obj.NavList.Value = items{idx};
                end
            end
            if idx == 3
                obj.onPrepChanged();
            end
            if idx == 4 && ~isempty(obj.GlossaryPanel)
                try, obj.GlossaryPanel.refresh(); catch, end
            end
            if idx == 5 && ~isempty(obj.SettingsPanel)
                try, obj.SettingsPanel.refreshEnv(); catch, end
            end
            if idx == 6 && ~isempty(obj.QcPanel)
                try
                    wd = obj.qcWorkingDir();
                    cur = '';
                    try
                        st = obj.QcPanel.getState();
                        if isfield(st, 'WorkingDir'), cur = st.WorkingDir; end
                    catch
                    end
                    if ~isempty(wd) && ~strcmp(cur, wd)
                        obj.QcPanel.setWorkingDir(wd);
                    else
                        obj.QcPanel.refresh();
                    end
                catch err
                    obj.setStatus(['人工QC刷新失败：' err.message], 'warn');
                end
            end
        end

        function wd = qcWorkingDir(obj)
            % 推断人工 QC 应使用的工作目录：优先预处理面板，其次扫描结果
            wd = '';
            try
                if ~isempty(obj.PrepPanel)
                    st = obj.PrepPanel.getState();
                    if isfield(st, 'WorkingDir') && ~isempty(st.WorkingDir)
                        wd = char(st.WorkingDir);
                    end
                end
            catch
            end
            if isempty(wd) && ~isempty(obj.ScanIndex) && isfield(obj.ScanIndex, 'Detected')
                try
                    wd = char(obj.ScanIndex.Detected.WorkingDir);
                catch
                end
            end
        end

        function showQcFallback(obj, msg)
            % 人工QC组件不可用时的占位提示（不阻塞主工作台）
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            gl = uigridlayout(obj.Pages{6}, [1 1]);
            gl.Padding = [20 20 20 20];
            gl.BackgroundColor = c.bg;
            uilabel(gl, 'Text', sprintf(['%s\n\n请确认工作台 +mrw/QcPanel.m 与 +mrw/QcModel.m 已就绪，' ...
                '并在 MATLAB 中重新 addpath 工作台目录后重启工作台。'], msg), ...
                'FontName', f.name, 'FontSize', f.base, 'FontColor', c.err, ...
                'VerticalAlignment', 'top', 'WordWrap', 'on');
        end

        function setStatus(obj, msg, kind)
            if nargin < 3, kind = 'info'; end
            c = mrw.UiKit.colors();
            obj.StatusLabel.Text = msg;
            switch kind
                case 'ok',   obj.StatusLabel.FontColor = c.ok;
                case 'warn', obj.StatusLabel.FontColor = [0.6 0.4 0.0];
                case 'err',  obj.StatusLabel.FontColor = c.err;
                otherwise,   obj.StatusLabel.FontColor = c.muted;
            end
            drawnow limitrate;
        end

        % ================= 数据索引 =================
        function onScanApplied(obj, idx)
            obj.ScanIndex = idx;
            d = idx.Detected;
            if isempty(obj.PrepPanel)
                obj.setStatus('预处理面板不可用，无法应用检测结果', 'err');
                return;
            end
            try
                st = obj.PrepPanel.getState();
                % 应用检测到的数据参数
                st.WorkingDir = d.WorkingDir;
                st.DataProcessDir = d.WorkingDir;   % DPARSF 引擎读写同一根目录
                st.StartingDirName = d.StartingDirName;
                st.FunctionalSessionNumber = d.FunctionalSessionNumber;
                st.SubjectID = d.SubjectIDs;
                if isfield(d, 'TimePoints') && ~isempty(d.TimePoints) && ~isnan(d.TimePoints) && d.TimePoints > 0
                    st.TimePoints = d.TimePoints;
                end
                if isfield(d, 'TR') && ~isempty(d.TR) && ~isnan(d.TR) && d.TR > 0
                    st.TR = d.TR;
                end
                if isfield(d, 'SliceNumber') && ~isempty(d.SliceNumber) && ~isnan(d.SliceNumber) && d.SliceNumber > 0
                    st.SliceTiming.SliceNumber = d.SliceNumber;
                end
                % 数据形态决定转换开关
                if isfield(d, 'IsBIDS') && d.IsBIDS
                    st.IsBIDStoDPARSF = 1;
                end
                ft = '';
                anatDir = '';
                if ~isempty(idx.Subjects)
                    ft = idx.Subjects(1).FunType;
                    anatDir = idx.Subjects(1).AnatDir;
                end
                isDicom = any(strcmpi(ft, 'DICOM'));
                if isDicom
                    st.IsNeedConvertFunDCM2IMG = 1;
                    st.IsNeedConvertT1DCM2IMG = 1;
                    st.IsNeedReorientCropT1Img = 0;   % dcm2niix 转换已自动生成 co*
                else
                    st.IsNeedConvertFunDCM2IMG = 0;
                    st.IsNeedConvertT1DCM2IMG = 0;
                    st.IsNeedReorientCropT1Img = 0;
                    if ~isempty(anatDir) && contains(lower(anatDir), 't1img')
                        % 已有 NIfTI 结构像（T1Img）时，后台运行需先裁剪生成 co*，否则引擎会弹确认框
                        st.IsNeedReorientCropT1Img = 1;
                    end
                end
                if isfield(d, 'IsBIDS') && d.IsBIDS
                    st.IsNeedReorientCropT1Img = 0;   % BIDS 模式引擎内部会处理 T1w，不会弹框
                end
                obj.PrepPanel.setState(st);
                obj.PrepPanel.applyDetected(d);
                obj.NavStatusLabel.Text = sprintf('已从扫描结果填入：%s / %d 名受试者', d.StartingDirName, numel(idx.Subjects));
                obj.setStatus(sprintf('检测结果已应用到预处理参数（%d 名受试者）', numel(idx.Subjects)), 'ok');
                obj.onPrepChanged();
                obj.switchPage(2);
            catch err
                obj.setStatus(['应用检测结果失败：' err.message], 'err');
            end
        end

        function onSubjectEdit(obj)
            if isempty(obj.PrepPanel)
                return;
            end
            try
                st = obj.PrepPanel.getState();
                ids = st.SubjectID;
                if ischar(ids), ids = {ids}; end
                d = uifigure('Name', '管理受试者列表', 'Position', [500 300 420 400]);
                g = uigridlayout(d, [3 1]);
                g.RowHeight = {'fit', '1x', 'fit'};
                uilabel(g, 'Text', '每行一个受试者编号（应与 <工作目录>/<起始目录名>/ 下的子目录名一致）', ...
                    'FontName', mrw.UiKit.fonts().name, 'FontSize', 11);
                ta = uitextarea(g, 'Value', ids(:)', 'FontName', mrw.UiKit.fonts().mono);
                bg = uigridlayout(g, [1 2]);
                bg.ColumnWidth = {'1x', '1x'};
                uibutton(bg, 'Text', '取消', 'ButtonPushedFcn', @(s, e) delete(d));
                uibutton(bg, 'Text', '确定', 'BackgroundColor', mrw.UiKit.colors().accent, ...
                    'FontColor', [1 1 1], 'ButtonPushedFcn', @(s, e) obj.applySubjectEdit(d, ta));
                uiwait(d);
            catch err
                obj.setStatus(['编辑受试者失败：' err.message], 'err');
            end
        end

        function applySubjectEdit(obj, d, ta)
            try
                val = ta.Value;
                if ischar(val), val = {val}; end
                val = strtrim(val);
                val = val(~cellfun(@isempty, val));
                st = obj.PrepPanel.getState();
                st.SubjectID = val(:)';
                obj.PrepPanel.setState(st);
                obj.setStatus(sprintf('受试者列表已更新为 %d 人', numel(val)), 'ok');
                obj.onPrepChanged();
            catch err
                obj.setStatus(['更新受试者失败：' err.message], 'err');
            end
            delete(d);
        end

        % ================= 预处理参数 =================
        function onPresetSelected(obj, name)
            if isempty(obj.PrepPanel), return; end
            try
                st = obj.PrepPanel.getState();
                st = mrw.CfgBuilder.applyPreset(st, name);
                obj.PrepPanel.setState(st);
                obj.setStatus(['已应用预设：' name], 'ok');
                obj.onPrepChanged();
            catch err
                obj.setStatus(['应用预设失败：' err.message], 'err');
            end
        end

        function onPrepChanged(obj)
            if isempty(obj.PrepPanel) || isempty(obj.RunPanel)
                return;
            end
            try
                Cfg = obj.buildCfg();
                if isempty(Cfg), return; end
                obj.LastCfg = Cfg;
                lines = obj.summaryLines(Cfg);
                obj.RunPanel.setSummary(lines);
            catch err
                obj.RunPanel.setSummary({['配置构建失败：' err.message]});
            end
        end

        function lines = summaryLines(obj, Cfg)
            c = mrw.UiKit.colors();
            lines = {};
            wd = Cfg.WorkingDir;
            if isempty(wd), wd = '（未设置，请先在“数据索引”扫描或手动填写）'; end
            lines{end+1} = ['工作目录：' wd]; %#ok<AGROW>
            lines{end+1} = sprintf('受试者：%d 名    功能像 session：%d    起始目录：%s', ...
                numel(Cfg.SubjectID), Cfg.FunctionalSessionNumber, Cfg.StartingDirName); %#ok<AGROW>
            dataInfo = sprintf('时间点：%s    TR：%s 秒', fmtv(Cfg.TimePoints), fmtv(Cfg.TR)); %#ok<NASGU>
            lines{end+1} = sprintf('时间点：%s    TR：%s 秒（0=自动检测）', fmtv(Cfg.TimePoints), fmtv(Cfg.TR)); %#ok<AGROW>
            steps = mrw.CfgBuilder.summary(Cfg);
            lines{end+1} = ['将执行：' strjoin(steps, ' → ')]; %#ok<AGROW>
        end

        function Cfg = buildCfg(obj)
            Cfg = [];
            if isempty(obj.PrepPanel), return; end
            st = obj.PrepPanel.getState();
            try
                allowGUI = logical(mrw.Settings.get('AllowGUI'));
            catch
                allowGUI = false;
            end
            Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', allowGUI));
        end

        % ================= 运行控制 =================
        function onCheckCfg(obj)
            try
                Cfg = obj.buildCfg();
                if isempty(Cfg)
                    obj.alertDialog('预处理参数面板不可用。', '无法检查');
                    return;
                end
                obj.LastCfg = Cfg;
                rep = mrw.CfgBuilder.validate(Cfg, obj.scanDetected());
                obj.RunPanel.setChecks(rep);
                obj.RunPanel.setSummary(obj.summaryLines(Cfg));
                obj.switchPage(3);
                obj.setStatus(rep.summary, ternary(rep.ok, 'ok', 'err'));
            catch err
                obj.alertDialog(sprintf('检查失败：%s', err.message), '检查错误');
            end
        end

        function onStartRun(obj)
            if ~isempty(obj.Runner) && isa(obj.Runner, 'mrw.Runner') && obj.Runner.Running
                obj.setStatus('已有预处理任务在运行中', 'warn');
                obj.switchPage(3);
                return;
            end
            try
                Cfg = obj.buildCfg();
                if isempty(Cfg)
                    obj.alertDialog('预处理参数面板不可用。', '无法运行');
                    return;
                end
                obj.LastCfg = Cfg;
                rep = mrw.CfgBuilder.validate(Cfg, obj.scanDetected());
                obj.RunPanel.setChecks(rep);
                obj.RunPanel.setSummary(obj.summaryLines(Cfg));
                obj.switchPage(3);
                if ~rep.ok
                    msg = strjoin(rep.errors(1:min(numel(rep.errors), 6)), sprintf('\n'));
                    obj.alertDialog(sprintf('运行前检查未通过：\n%s\n\n请回到“预处理参数”修正后重试。', msg), '无法开始');
                    obj.setStatus('运行前检查未通过', 'err');
                    return;
                end
                runsDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'runs');
                obj.Runner = mrw.Runner(runsDir);
                obj.Runner.OnLog = @(txt) obj.onRunnerLog(txt);
                obj.Runner.OnStatus = @(st) obj.onRunnerStatus(st);
                obj.Runner.OnFinish = @(st) obj.onRunnerFinish(st);
                runName = ['run_' datestr(now, 'yyyymmdd_HHMMSS')];
                obj.RunPanel.clearLog();
                obj.RunPanel.setRunning(true);
                obj.RunPanel.setProgress(0, '正在启动后台进程…');
                obj.RunPanel.setRunDir(fullfile(runsDir, runName));
                obj.Runner.start(Cfg, struct('RunName', runName, 'AllowGUI', false));
                obj.setStatus('预处理任务已启动（独立后台进程）', 'ok');
            catch err
                msg = sprintf('启动预处理失败：%s', err.message);
                try
                    for k = 1:min(numel(err.stack), 8)
                        msg = sprintf('%s\n    at %s (line %d)', msg, err.stack(k).name, err.stack(k).line); %#ok<AGROW>
                    end
                catch
                end
                obj.setStatus('启动失败', 'err');
                obj.alertDialog(msg, '启动错误');
                obj.RunPanel.setRunning(false);
            end
        end

        function onCancelRun(obj)
            if isempty(obj.Runner) || ~obj.Runner.Running
                return;
            end
            choice = questdlg('确定要取消当前预处理任务吗？后台进程将被终止，已生成的部分结果可能不完整。', ...
                '取消运行', '继续运行', '确定取消', '继续运行');
            if strcmp(choice, '确定取消')
                obj.Runner.cancel();
                obj.setStatus('已请求取消运行', 'warn');
            end
        end

        function onRunnerLog(obj, txt)
            try
                obj.RunPanel.appendLog(txt);
            catch
            end
        end

        function onRunnerStatus(obj, st)
            try
                obj.RunPanel.setStatus(st);
            catch
            end
        end

        function onRunnerFinish(obj, st)
            try
                obj.RunPanel.setRunning(false);
                obj.RunPanel.setStatus(st);
                obj.RunPanel.setRunDir(obj.Runner.RunDir);
                if strcmp(st.State, 'finished')
                    obj.setStatus(sprintf('预处理完成，用时 %s', mrw.UiKit.fmtSeconds(st.Elapsed)), 'ok');
                elseif strcmp(st.State, 'cancelled')
                    obj.setStatus('预处理已取消', 'warn');
                else
                    obj.setStatus(['预处理失败：' st.Message], 'err');
                end
                try
                    mrw.Settings.addRecentRun(obj.Runner.RunDir);
                catch
                end
            catch err
                obj.setStatus(['运行结束处理异常：' err.message], 'err');
            end
        end

        function det = scanDetected(obj)
            det = [];
            if ~isempty(obj.ScanIndex) && isfield(obj.ScanIndex, 'Detected')
                det = obj.ScanIndex.Detected;
            end
        end

        % ================= 配置存取 =================
        function onSaveCfg(obj)
            try
                if isempty(obj.LastCfg)
                    obj.onPrepChanged();
                end
                Cfg = obj.LastCfg;
                d = mrw.Dpabi.root();
                startDir = fullfile(d, 'DPARSF', 'Jobmats');
                if exist(startDir, 'dir') ~= 7, startDir = pwd; end
                [fn, fp] = uiputfile('*.mat', '保存 DPARSFA 配置（可被原生 DPARSFA 载入）', ...
                    fullfile(startDir, ['DPARSF_Config_' datestr(now, 'yyyymmdd_HHMM') '.mat']));
                if isequal(fn, 0), return; end
                mrw.CfgBuilder.saveCfg(Cfg, fullfile(fp, fn));
                obj.setStatus(['配置已保存：' fullfile(fp, fn)], 'ok');
            catch err
                obj.alertDialog(sprintf('保存配置失败：%s', err.message), '保存错误');
            end
        end

        function onLoadCfg(obj)
            try
                [fn, fp] = uigetfile('*.mat', '载入 DPARSFA 配置');
                if isequal(fn, 0), return; end
                [Cfg, State, Meta] = mrw.CfgBuilder.loadCfg(fullfile(fp, fn));
                obj.LastCfg = Cfg;
                if ~isempty(obj.PrepPanel)
                    obj.PrepPanel.setState(State);
                end
                obj.onPrepChanged();
                obj.switchPage(2);
                obj.setStatus(['已载入配置：' fn], 'ok');
                if isstruct(Meta) && isfield(Meta, 'SavedAt')
                    obj.setStatus(['已载入配置：' fn '（保存于 ' Meta.SavedAt '）'], 'ok');
                end
            catch err
                obj.alertDialog(sprintf('载入配置失败：%s', err.message), '载入错误');
            end
        end

        function onOpenOutput(obj)
            d = '';
            if ~isempty(obj.LastCfg) && isfield(obj.LastCfg, 'DataProcessDir')
                d = obj.LastCfg.DataProcessDir;
            end
            if isempty(d) && ~isempty(obj.LastCfg) && isfield(obj.LastCfg, 'WorkingDir')
                d = obj.LastCfg.WorkingDir;
            end
            if ischar(d) && exist(d, 'dir') == 7
                system(['explorer "' d '"']);
            else
                obj.setStatus('输出目录尚不存在', 'warn');
            end
        end

        function onOpenRunDir(obj)
            if ~isempty(obj.Runner) && ~isempty(obj.Runner.RunDir) && exist(obj.Runner.RunDir, 'dir') == 7
                system(['explorer "' obj.Runner.RunDir '"']);
            else
                runsDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'runs');
                if exist(runsDir, 'dir') == 7
                    system(['explorer "' runsDir '"']);
                end
            end
        end

        % ================= 原生界面 =================
        function openNative(obj, which)
            try
                switch which
                    case 'dpabi'
                        mrw.Dpabi.launchDPABI();
                        obj.setStatus('已打开原生 DPABI 界面（如启用汉化会自动翻译并添加悬停解释）', 'ok');
                    case 'dparsfa'
                        mrw.Dpabi.launchDPARSFA('Blank');
                        obj.setStatus('已打开原生 DPARSF 高级版界面', 'ok');
                    case 'dparsf'
                        mrw.Dpabi.launchDPARSFMain();
                        obj.setStatus('已打开原生 DPARSF 经典版界面', 'ok');
                end
            catch err
                obj.alertDialog(sprintf('打开原生界面失败：%s', err.message), '错误');
            end
        end

        % ================= 关闭 =================
        function onClose(obj)
            try
                if ~isempty(obj.Runner) && isa(obj.Runner, 'mrw.Runner') && obj.Runner.Running
                    choice = questdlg('后台预处理任务仍在运行，关闭工作台会终止该任务。确定关闭吗？', ...
                        '确认关闭', '保持打开', '终止并关闭', '保持打开');
                    if ~strcmp(choice, '终止并关闭')
                        return;
                    end
                    obj.Runner.cancel();
                end
            catch
            end
            try
                delete(obj.Fig);
            catch
            end
        end

        function alertDialog(obj, msg, titleText)
            % headless 环境（-batch）下 errordlg 会报错，统一降级为控制台输出
            fprintf('[工作台] %s：%s\n', titleText, msg);
            try
                if ~mrw.WorkbenchApp.isBatchMode()
                    obj.alertDialog(msg, titleText);
                end
            catch
            end
        end
    end

    methods (Static, Access = private)
        function tf = isBatchMode()
            tf = false;
            try
                tf = batchStartupOptionUsed();
            catch
                try
                    tf = ~usejava('desktop');
                catch
                end
            end
        end
    end
end

function s = fmtv(v)
if isempty(v)
    s = '--';
elseif isnumeric(v) && ~isnan(v) && v == 0
    s = '0（自动）';
else
    s = num2str(v);
end
end

function r = ternary(cond, a, b)
if cond, r = a; else, r = b; end
end
