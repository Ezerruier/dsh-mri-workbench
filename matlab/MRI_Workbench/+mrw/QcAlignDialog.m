classdef QcAlignDialog < handle
% QcAlignDialog  方位校准对话框（AC-PC 配平 / 显示原点 / 手动微调 / 翻转）
%
% 用法：
%   dlg = mrw.QcAlignDialog(panel);      % panel 为 mrw.QcPanel
%   dlg.close();                          % 关闭（面板不受影响）
%
% 说明：
%   - modeless uifigure；只调用 mrw.QcPanel 的公共方法（不碰私有属性）；
%   - 面板销毁后对话框自动失效/关闭，不报错；
%   - 坐标读数随面板 Changed 事件（保存评分/切换受试者/模态等）刷新；
%   - 显示变换默认仅预览；“应用到数据…”确认后另存副本，原始文件不变。
%
% 版本 2.0.0（qc-ui v2，2026-11）

    properties (SetAccess = private)
        Panel  = []      % 所属 mrw.QcPanel
        Figure = []      % 对话框 uifigure
    end

    properties (Access = private)
        Colors = struct()
        Fonts  = struct()
        ChangedListener = []
        DestroyListener = []
        Closing = false
        Syncing = false
        ACVoxel = []
        PCVoxel = []
        % ---- 读数 ----
        VoxelLabel = []
        WorldLabel = []
        DisplayLabel = []
        ModeLabel = []
        AcLabel = []
        PcLabel = []
        AcPcLabel = []
        MatrixLabel = []
        HintLabel = []
        % ---- 控件 ----
        OriginButton = []
        PickAcButton = []
        PickPcButton = []
        ApplyAcPcButton = []
        ClearAcPcButton = []
        TransFields = {}
        RotFields = {}
        ApplyManualButton = []
        ClearManualButton = []
        FlipLRCheck = []
        FlipAPCheck = []
        FlipISCheck = []
        ResetButton = []
        CloseButton = []
        ApplyDataButton = []
        ApplyDataFigure = []
    end

    methods

        function obj = QcAlignDialog(panel)
            if nargin < 1 || isempty(panel) || ~isvalid(panel)
                error('QcAlignDialog:Panel', '必须提供有效的 mrw.QcPanel 句柄。');
            end
            obj.Panel = panel;
            obj.Colors = mrw.UiKit.colors();
            obj.Fonts = mrw.UiKit.fonts();
            obj.build();
            try
                obj.ChangedListener = addlistener(panel, 'Changed', @(s, e) obj.refresh());
            catch
            end
            try
                obj.DestroyListener = addlistener(panel, 'ObjectBeingDestroyed', @(s, e) obj.close());
            catch
            end
            obj.refresh();
        end

        function raise(obj)
            % 置顶对话框
            try
                if ~isempty(obj.Figure) && isvalid(obj.Figure)
                    figure(obj.Figure);
                end
            catch
            end
        end

        function close(obj)
            % 关闭对话框（幂等；面板销毁后调用也不报错）
            try
                obj.cleanupNow();
            catch
            end
        end

        function delete(obj)
            % 支持外部 delete(dlg)（不经过关闭按钮）：
            % 先删监听器/图窗，再让 MATLAB 完成对象销毁，避免面板 Changed
            % 回调访问已删除对话框产生“对象无效或已删除”警告。幂等。
            try
                obj.cleanupNow();
            catch
            end
        end

        function tf = isValid(obj)
            tf = false;
            try
                tf = ~obj.Closing && ~isempty(obj.Figure) && isvalid(obj.Figure);
            catch
                tf = false;
            end
        end

        function refresh(obj)
            % 从面板公共接口读取状态刷新读数（面板已销毁时安全关闭）
            if obj.Closing || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return;
            end
            try
                if isempty(obj.Panel) || ~isvalid(obj.Panel)
                    obj.close();
                    return;
                end
            catch
                obj.close();
                return;
            end
            obj.Syncing = true;
            try
                vi = obj.Panel.getViewInfo();
                st = obj.Panel.getState();
                mode = char(fieldOrLocal(vi, 'Mode', 'native'));
                if ~ischar(mode) || isempty(mode)
                    mode = 'native';
                end
                cv = [];
                try, cv = obj.Panel.getCrosshairVoxel(); catch, end
                cw = fieldLocal(vi, {'CrosshairWorld'});
                cd = fieldLocal(vi, {'CrosshairDisplay'});
                setLabel(obj.VoxelLabel, sprintf('体素：%s', fmtVec3Local(cv)));
                setLabel(obj.WorldLabel, sprintf('世界：%s mm', fmtVec3Local(cw)));
                setLabel(obj.DisplayLabel, sprintf('显示：%s mm', fmtVec3Local(cd)));
                setLabel(obj.ModeLabel, sprintf('显示模式：%s', alignModeLabelLocal(mode)));
                acpc = fieldOrLocal(vi, 'ACPC', struct());
                d = double(fieldLocal(acpc, {'distanceMm', 'DistanceMm'}, NaN));
                acV = fieldLocal(vi, {'ACVoxel'});
                pcV = fieldLocal(vi, {'PCVoxel'});
                if isempty(obj.ACVoxel) && isnumeric(acV) && numel(acV) >= 3
                    obj.ACVoxel = double(acV(1:3));
                end
                if isempty(obj.PCVoxel) && isnumeric(pcV) && numel(pcV) >= 3
                    obj.PCVoxel = double(pcV(1:3));
                end
                setLabel(obj.AcLabel, sprintf('AC 位置：%s', fmtVec3Local(obj.ACVoxel)));
                setLabel(obj.PcLabel, sprintf('PC 位置：%s', fmtVec3Local(obj.PCVoxel)));
                if isfinite(d)
                    ang = double(fieldLocal(acpc, {'angleDeg', 'AngleDeg'}, NaN));
                    setLabel(obj.AcPcLabel, sprintf('AC-PC 距离 %.2f mm · 仰角 %.1f°', d, ang));
                elseif ~isempty(obj.ACVoxel) && ~isempty(obj.PCVoxel)
                    setLabel(obj.AcPcLabel, 'AC/PC 已拾取，点击“应用 AC-PC 配平”生效');
                else
                    setLabel(obj.AcPcLabel, 'AC-PC：未配平（先拾取 AC 与 PC）');
                end
                setButtonEnable(obj.ApplyAcPcButton, ~isempty(obj.ACVoxel) && ~isempty(obj.PCVoxel));
                dm = fieldLocal(vi, {'DisplayMatrix'});
                if isnumeric(dm) && numel(dm) >= 16
                    M = double(reshape(dm(1:16), 4, 4));
                else
                    M = eye(4);
                end
                setLabel(obj.MatrixLabel, sprintf('显示矩阵 A（world→display）：\n%s', matSummaryLocal(M)));
                % 手动平移 / 旋转
                [t, r] = manualLocal(vi);
                for i = 1:min(3, numel(obj.TransFields))
                    obj.TransFields{i}.Value = t(i);
                end
                for i = 1:min(3, numel(obj.RotFields))
                    obj.RotFields{i}.Value = r(i);
                end
                % 翻转
                fl = flipsLocal(vi);
                obj.FlipLRCheck.Value = logical(fl(1));
                obj.FlipAPCheck.Value = logical(fl(2));
                obj.FlipISCheck.Value = logical(fl(3));
                setButtonEnable(obj.ApplyDataButton, logical(fieldOrLocal(vi, 'HasVolume', false)) && ...
                    ~logical(fieldOrLocal(vi, 'IsNative', true)));
                msg = char(fieldOrLocal(vi, 'Message', ''));
                if isempty(msg)
                    msg = char(fieldOrLocal(st, 'Message', ''));
                end
                setLabel(obj.HintLabel, msg);
            catch
            end
            obj.Syncing = false;
        end
    end

    methods (Access = private)

        function cleanupNow(obj)
            % 统一清理：删监听器 + 关图窗（幂等；close/delete 共用）
            if obj.Closing
                return;
            end
            obj.Closing = true;
            if ~isempty(obj.ApplyDataFigure) && isvalid(obj.ApplyDataFigure)
                delete(obj.ApplyDataFigure);
            end
            try
                if ~isempty(obj.ChangedListener) && isvalid(obj.ChangedListener)
                    delete(obj.ChangedListener);
                end
            catch
            end
            try
                if ~isempty(obj.DestroyListener) && isvalid(obj.DestroyListener)
                    delete(obj.DestroyListener);
                end
            catch
            end
            obj.ChangedListener = [];
            obj.DestroyListener = [];
            try
                if ~isempty(obj.Figure) && isvalid(obj.Figure)
                    delete(obj.Figure);
                end
            catch
            end
            obj.Figure = [];
        end

        function build(obj)
            c = obj.Colors;
            f = obj.Fonts;
            fig = mrw.UiKit.newFigure('方位校准（AC-PC / 原点 / 手动）', [640 830]);
            obj.Figure = fig;
            fig.CloseRequestFcn = @(s, e) obj.close();

            root = uigridlayout(fig, [2 1]);
            root.RowHeight = {'1x', 36};
            root.Padding = [12 10 12 10];
            root.RowSpacing = 8;
            root.BackgroundColor = c.bg;
            root.Tag = 'qcAlignLayout';
            g = uigridlayout(root, [8 1]);
            % 面板行高包含标题栏；小窗口滚动正文，底部操作保持可见。
            g.RowHeight = {34, 106, 30, 140, 98, 30, 58, 212};
            g.ColumnWidth = {600};
            g.Padding = [0 0 0 0];
            g.RowSpacing = 6;
            g.BackgroundColor = c.bg;
            g.Tag = 'qcAlignContent';
            g.Scrollable = 'on';
            fig.AutoResizeChildren = 'off';
            fig.SizeChangedFcn = @(~, ~) set(g, 'ColumnWidth', {max(580, fig.Position(3) - 40)});

            top = uilabel(g, 'Text', ['说明：默认仅预览；“应用到数据…”经确认后另存副本。' ...
                'AC/PC 需在三正交视图中人工拾取。'], 'WordWrap', 'on', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.bg);
            top.Layout.Row = 1;
            mrw.UiKit.tip(top, '预览不写文件；只有点击“应用到数据…”并确认才另存独立副本，原图像始终不改。');

            % ---- 坐标读数 ----
            pp = uipanel(g, 'Title', '坐标读数（随面板刷新）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            pp.Layout.Row = 2;
            pg = uigridlayout(pp, [3 1]);
            pg.RowHeight = {22, 22, 22};
            pg.Padding = [8 4 8 4];
            pg.RowSpacing = 2;
            pg.BackgroundColor = c.panel;
            obj.VoxelLabel = uilabel(pg, 'Text', '体素：(—, —, —)', 'FontName', f.mono, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.VoxelLabel.Layout.Row = 1;
            mrw.UiKit.tip(obj.VoxelLabel, '当前十字线体素坐标 [i j k]（1-based，连续坐标）。');
            obj.WorldLabel = uilabel(pg, 'Text', '世界：(—, —, —) mm', 'FontName', f.mono, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.WorldLabel.Layout.Row = 2;
            mrw.UiKit.tip(obj.WorldLabel, '由 NIfTI hdr.mat 换算的世界 mm 坐标（不使用显示变换）。');
            obj.DisplayLabel = uilabel(pg, 'Text', '显示：(—, —, —) mm', 'FontName', f.mono, ...
                'FontSize', f.small, 'FontColor', c.accentDark, 'BackgroundColor', c.panel);
            obj.DisplayLabel.Layout.Row = 3;
            mrw.UiKit.tip(obj.DisplayLabel, '经 AC-PC/原点/平移旋转/翻转后的显示 mm 坐标。');

            obj.OriginButton = mrw.UiKit.button(g, '以十字线设显示原点', ...
                'Callback', @(s, e) obj.onSetOrigin());
            obj.OriginButton.Layout.Row = 3;
            obj.OriginButton.Tag = 'qcAlignOrigin';
            mrw.UiKit.tip(obj.OriginButton, '把当前十字线所在世界坐标设为显示原点（对应 QcView.setOriginAtWorld；仅显示）。');

            % ---- AC-PC ----
            ap = uipanel(g, 'Title', 'AC-PC 配平（前/后联合）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            ap.Layout.Row = 4;
            ag = uigridlayout(ap, [4 1]);
            ag.RowHeight = {20, 20, 28, 28};
            ag.Padding = [8 4 8 4];
            ag.RowSpacing = 3;
            ag.BackgroundColor = c.panel;
            obj.AcLabel = uilabel(ag, 'Text', 'AC 位置：(—, —, —)', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.AcLabel.Layout.Row = 1;
            mrw.UiKit.tip(obj.AcLabel, '已拾取的 AC（前联合）体素坐标。');
            obj.PcLabel = uilabel(ag, 'Text', 'PC 位置：(—, —, —)', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.PcLabel.Layout.Row = 2;
            mrw.UiKit.tip(obj.PcLabel, '已拾取的 PC（后联合）体素坐标。');
            pk = uigridlayout(ag, [1 2]);
            pk.RowHeight = {'1x'};
            pk.ColumnWidth = {'1x', '1x'};
            pk.Padding = [0 0 0 0];
            pk.ColumnSpacing = 6;
            pk.BackgroundColor = c.panel;
            pk.Layout.Row = 3;
            obj.PickAcButton = mrw.UiKit.button(pk, '把当前位置设为 AC', ...
                'Callback', @(s, e) obj.onPickAc());
            obj.PickAcButton.Tag = 'qcAlignPickAc';
            mrw.UiKit.tip(obj.PickAcButton, '把当前十字线位置记为 AC（前联合）；可在三正交视图中先点击定位。');
            obj.PickPcButton = mrw.UiKit.button(pk, '把当前位置设为 PC', ...
                'Callback', @(s, e) obj.onPickPc());
            obj.PickPcButton.Layout.Column = 2;
            obj.PickPcButton.Tag = 'qcAlignPickPc';
            mrw.UiKit.tip(obj.PickPcButton, '把当前十字线位置记为 PC（后联合）；可在三正交视图中先点击定位。');
            ap2 = uigridlayout(ag, [1 2]);
            ap2.RowHeight = {'1x'};
            ap2.ColumnWidth = {'1x', '1x'};
            ap2.Padding = [0 0 0 0];
            ap2.ColumnSpacing = 6;
            ap2.BackgroundColor = c.panel;
            ap2.Layout.Row = 4;
            obj.ApplyAcPcButton = mrw.UiKit.button(ap2, '应用 AC-PC 配平', ...
                'kind', 'primary', 'Callback', @(s, e) obj.onApplyAcPc());
            obj.ApplyAcPcButton.Tag = 'qcAlignApplyACPC';
            mrw.UiKit.tip(obj.ApplyAcPcButton, '用 AC→原点、PC→后方（-Y）做显示配平；保持右(+X)/前(+Y)/上(+Z)约定（只影响显示，不改文件）。');
            obj.ClearAcPcButton = mrw.UiKit.button(ap2, '清除配平', ...
                'Callback', @(s, e) obj.onClearAcPc());
            obj.ClearAcPcButton.Layout.Column = 2;
            obj.ClearAcPcButton.Tag = 'qcAlignClearACPC';
            mrw.UiKit.tip(obj.ClearAcPcButton, '清除 AC-PC 配平并恢复 native 显示（保留手动平移/旋转/翻转）。');

            % ---- 手动微调 ----
            mp = uipanel(g, 'Title', '手动微调（显示层）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            mp.Layout.Row = 5;
            mg = uigridlayout(mp, [2 1]);
            mg.RowHeight = {30, 30};
            mg.Padding = [8 4 8 4];
            mg.RowSpacing = 4;
            mg.BackgroundColor = c.panel;
            tg = uigridlayout(mg, [1 2]);
            tg.RowHeight = {'1x'};
            tg.ColumnWidth = {132, '1x'};
            tg.Padding = [0 0 0 0];
            tg.ColumnSpacing = 6;
            tg.BackgroundColor = c.panel;
            tg.Layout.Row = 1;
            lt = uilabel(tg, 'Text', '平移 右/前/上 (mm)', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lt, '显示平移：右(+X)/前(+Y)/上(+Z)，单位 mm；只影响本次显示。');
            obj.TransFields = obj.buildNumFields(tg, 'qcAlignTrans', [0 0 0], [-100 100], ...
                '手动平移（mm）：右/前/上；只影响显示，不写回图像。');
            rg = uigridlayout(mg, [1 2]);
            rg.RowHeight = {'1x'};
            rg.ColumnWidth = {132, '1x'};
            rg.Padding = [0 0 0 0];
            rg.ColumnSpacing = 6;
            rg.BackgroundColor = c.panel;
            rg.Layout.Row = 2;
            lr = uilabel(rg, 'Text', '旋转 pitch/roll/yaw (°)', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lr, '显示旋转：pitch/roll/yaw，单位度（旋转顺序 Rz*Ry*Rx，右手系）。');
            obj.RotFields = obj.buildNumFields(rg, 'qcAlignRot', [0 0 0], [-180 180], ...
                '手动旋转（度）：pitch/roll/yaw；只影响显示，不写回图像。');

            ab = uigridlayout(g, [1 2]);
            ab.RowHeight = {'1x'};
            ab.ColumnWidth = {'1x', '1x'};
            ab.Padding = [0 0 0 0];
            ab.ColumnSpacing = 6;
            ab.BackgroundColor = c.bg;
            ab.Layout.Row = 6;
            obj.ApplyManualButton = mrw.UiKit.button(ab, '应用微调', ...
                'Callback', @(s, e) obj.onApplyManual());
            obj.ApplyManualButton.Tag = 'qcAlignApplyManual';
            mrw.UiKit.tip(obj.ApplyManualButton, '应用上方平移/旋转数值到显示（world mm / 度；不修改图像文件）。');
            obj.ClearManualButton = mrw.UiKit.button(ab, '清零微调', ...
                'Callback', @(s, e) obj.onClearManual());
            obj.ClearManualButton.Layout.Column = 2;
            obj.ClearManualButton.Tag = 'qcAlignClearManual';
            mrw.UiKit.tip(obj.ClearManualButton, '把平移/旋转清零（恢复无手动变换）。');

            % ---- 翻转 ----
            fp = uipanel(g, 'Title', '显示翻转', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            fp.Layout.Row = 7;
            fg = uigridlayout(fp, [1 3]);
            fg.RowHeight = {'1x'};
            fg.ColumnWidth = {'1x', '1x', '1x'};
            fg.Padding = [8 4 8 4];
            fg.ColumnSpacing = 6;
            fg.BackgroundColor = c.panel;
            obj.FlipLRCheck = uicheckbox(fg, 'Text', '左右翻转', 'Value', false, ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.text, ...
                'Tag', 'qcAlignFlipLR', ...
                'ValueChangedFcn', @(s, e) obj.onFlipChanged());
            mrw.UiKit.tip(obj.FlipLRCheck, '左右翻转（放射学↔神经学视角），只影响显示。');
            obj.FlipAPCheck = uicheckbox(fg, 'Text', '前后翻转', 'Value', false, ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.text, ...
                'Tag', 'qcAlignFlipAP', ...
                'ValueChangedFcn', @(s, e) obj.onFlipChanged());
            obj.FlipAPCheck.Layout.Column = 2;
            mrw.UiKit.tip(obj.FlipAPCheck, '前后翻转（A↔P），只影响显示。');
            obj.FlipISCheck = uicheckbox(fg, 'Text', '上下翻转', 'Value', false, ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.text, ...
                'Tag', 'qcAlignFlipIS', ...
                'ValueChangedFcn', @(s, e) obj.onFlipChanged());
            obj.FlipISCheck.Layout.Column = 3;
            mrw.UiKit.tip(obj.FlipISCheck, '上下翻转（S↔I），只影响显示。'); 

            % ---- 只读显示信息 ----
            ip = uipanel(g, 'Title', '显示状态（只读）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            ip.Layout.Row = 8;
            ig = uigridlayout(ip, [4 1]);
            ig.RowHeight = {22, 22, 90, 36};
            ig.Padding = [8 4 8 4];
            ig.RowSpacing = 2;
            ig.BackgroundColor = c.panel;
            obj.ModeLabel = uilabel(ig, 'Text', '显示模式：native（原生）', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.ModeLabel.Layout.Row = 1;
            mrw.UiKit.tip(obj.ModeLabel, '当前显示模式：native / origin（显示原点）/ acpc（AC-PC 配平）。');
            obj.AcPcLabel = uilabel(ig, 'Text', 'AC-PC：未配平', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.AcPcLabel.Layout.Row = 2;
            mrw.UiKit.tip(obj.AcPcLabel, 'AC-PC 距离与角度（来自 mrw.QcView.getInfo）。');
            obj.MatrixLabel = uilabel(ig, 'Text', '显示矩阵 A（world→display）：\n—', ...
                'FontName', f.mono, 'FontSize', f.base, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel, 'VerticalAlignment', 'top');
            obj.MatrixLabel.Layout.Row = 3;
            obj.MatrixLabel.Tag = 'qcAlignMatrix';
            mrw.UiKit.tip(obj.MatrixLabel, '4x4 显示矩阵摘要（world→display，仅显示层）。');
            obj.HintLabel = uitextarea(ig, 'Value', {''}, 'Editable', 'off', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.accentDark, ...
                'BackgroundColor', c.panel);
            obj.HintLabel.Layout.Row = 4;
            obj.HintLabel.Tag = 'qcAlignHint';
            mrw.UiKit.tip(obj.HintLabel, '最近一次校准操作的状态提示（失败原因也显示在这里）。');

            cb = uigridlayout(root, [1 3]);
            cb.RowHeight = {'1x'};
            cb.ColumnWidth = {'1x', '1x', '1x'};
            cb.Padding = [0 0 0 0];
            cb.ColumnSpacing = 6;
            cb.BackgroundColor = c.bg;
            cb.Tag = 'qcAlignFooter';
            cb.Layout.Row = 2;
            obj.ResetButton = mrw.UiKit.button(cb, '重置全部方位', ...
                'Callback', @(s, e) obj.onResetAll());
            obj.ResetButton.Tag = 'qcAlignReset';
            mrw.UiKit.tip(obj.ResetButton, '清除 AC-PC/原点/平移旋转/翻转，恢复 native 显示（不修改图像文件）。');
            obj.ApplyDataButton = mrw.UiKit.button(cb, '应用到数据…', 'Callback', @(s, e) obj.onApplyToData());
            obj.ApplyDataButton.Layout.Column = 2;
            obj.ApplyDataButton.Tag = 'qcAlignApplyData';
            mrw.UiKit.tip(obj.ApplyDataButton, '另存当前受试者、当前模态、当前图像的变换副本。原生显示无变换时禁用；请先设置原点、配平或微调。');
            obj.CloseButton = mrw.UiKit.button(cb, '关闭', 'Callback', @(s, e) obj.close());
            obj.CloseButton.Layout.Column = 3;
            obj.CloseButton.Tag = 'qcAlignClose';
            mrw.UiKit.tip(obj.CloseButton, '关闭方位校准对话框（不影响人工 QC 面板与已保存评分）。');
        end

        function fields = buildNumFields(obj, parent, tagPrefix, defaults, lims, tipText)
            f = mrw.UiKit.fonts();
            sg = uigridlayout(parent, [1 3]);
            sg.RowHeight = {'1x'};
            sg.ColumnWidth = {'1x', '1x', '1x'};
            sg.Padding = [0 0 0 0];
            sg.ColumnSpacing = 4;
            sg.BackgroundColor = mrw.UiKit.colors().panel;
            sg.Layout.Column = 2;
            fields = cell(1, 3);
            for i = 1:3
                ed = uieditfield(sg, 'numeric', 'Value', defaults(i), ...
                    'Limits', lims, 'ValueDisplayFormat', '%.1f', ...
                    'FontName', f.name, 'FontSize', f.small, ...
                    'Tag', sprintf('%s%d', tagPrefix, i), ...
                    'ValueChangedFcn', @(s, e) obj.onManualFieldChanged());
                ed.Layout.Column = i;
                mrw.UiKit.tip(ed, tipText);
                fields{i} = ed;
            end
        end

        % ---------------- 回调 ----------------
        function onApplyToData(obj)
            if obj.Syncing || ~obj.panelOk(), return; end
            if ~isempty(obj.ApplyDataFigure) && isvalid(obj.ApplyDataFigure)
                figure(obj.ApplyDataFigure); return;
            end
            st = obj.Panel.getState(); vi = obj.Panel.getViewInfo();
            source = obj.Panel.getCurrentFile();
            if logical(fieldOrLocal(vi, 'IsNative', true)), return; end
            confirm = mrw.UiKit.newFigure('应用到数据 — 确认独立副本', [780 620]);
            obj.ApplyDataFigure = confirm;
            confirm.WindowStyle = 'modal';
            grid = uigridlayout(confirm, [5 1]);
            grid.RowHeight = {24, '1x', 32, 62, 32};
            grid.Padding = [12 12 12 12]; grid.BackgroundColor = obj.Colors.bg;
            scope = uilabel(grid, 'Text', '范围：仅当前受试者、当前模态、当前显示图像。', ...
                'FontName', obj.Fonts.name, 'FontColor', obj.Colors.text);
            mrw.UiKit.tip(scope, '其它图像或中间产物需单独应用或重跑受影响步骤，否则几何可能不一致。');
            summary = uitextarea(grid, 'Editable', 'off', 'FontName', obj.Fonts.mono, ...
                'FontSize', 12, 'Tag', 'qcApplySummary'); summary.Layout.Row = 2;
            mrw.UiKit.tip(summary, '核对源文件、完整显示变换矩阵、写出方式与输出位置。');
            advanced = uicheckbox(grid, 'Text', '高级：重采样体素副本（插值有损、不可逆、体积变化）', ...
                'Value', false, 'FontName', obj.Fonts.name, 'FontSize', obj.Fonts.base, ...
                'Tag', 'qcApplyResample', 'ValueChangedFcn', @(s,e) updateSummary());
            advanced.Layout.Row = 3;
            mrw.UiKit.tip(advanced, '默认关闭：只重写副本的 qform/sform，像素完全不变。开启后按显示网格插值，另存 _resampled.nii。');
            note = uilabel(grid, 'Text', ['其它图像/中间产物需单独应用或重跑受影响步骤，否则几何可能不一致。' ...
                '原文件不变；回退：删除本批次输出目录并继续使用原文件。每批次附 reorient_log.json。'], ...
                'WordWrap', 'on', 'FontName', obj.Fonts.name, 'FontColor', obj.Colors.muted);
            note.Layout.Row = 4; mrw.UiKit.tip(note, '已有输出不覆盖；每次使用新的时间批次目录。未通过完整校验不会发布副本。');
            buttons = uigridlayout(grid, [1 2]); buttons.Layout.Row = 5;
            buttons.Padding = [0 0 0 0]; buttons.ColumnWidth = {'1x', '1x'};
            cancel = mrw.UiKit.button(buttons, '取消', 'Callback', @(s,e) delete(confirm));
            mrw.UiKit.tip(cancel, '取消此次写出，所有原图像与显示预览保持不变。');
            write = mrw.UiKit.button(buttons, '确认写出副本', 'kind', 'primary', 'Callback', @(s,e) writeCopy());
            write.Layout.Column = 2; write.Tag = 'qcApplyConfirm';
            mrw.UiKit.tip(write, '校验后在独立批次目录发布副本与日志；绝不覆盖源文件。');
            updateSummary();

            function updateSummary()
                [t,r] = manualLocal(vi); fl = flipsLocal(vi);
                mode = alignModeLabelLocal(fieldOrLocal(vi, 'Mode', 'native'));
                methodLabel = '只重写 NIfTI 头（新文件；像素不变）';
                suffix = '原文件名（.nii/.nii.gz/.img+.hdr）';
                if advanced.Value
                    methodLabel = '重采样体素副本（插值有损、不可逆、体积变化）';
                    suffix = '原文件名_resampled.nii';
                end
                output = fullfile(st.WorkingDir, 'QC', 'Reorient', st.SubjectID, '<唯一时间批次>', suffix);
                summary.Value = splitlines(sprintf(['受试者：%s\n模态：%s\n源文件：%s\n显示模式：%s\n' ...
                    '手动平移 (mm)：%s\n手动旋转 (度)：%s\n翻转 左右/前后/上下：%d / %d / %d\n' ...
                    '完整显示矩阵 A（世界→显示；写出几何为 A × 原始几何）：\n%s\n方式：%s\n' ...
                    '头编码全视野坐标偏差上限：0.001 mm（超限不发布输出）\n输出：%s'], ...
                    st.SubjectID, st.Modality, source, mode, fmtVec3Local(t), fmtVec3Local(r), ...
                    fl(1), fl(2), fl(3), matSummaryLocal(vi.DisplayMatrix), methodLabel, output));
            end

            function writeCopy()
                write.Enable = 'off'; drawnow;
                try
                    current = obj.Panel.getViewInfo();
                    currentState = obj.Panel.getState();
                    if ~strcmp(source, obj.Panel.getCurrentFile()) || ~isequal(vi.DisplayMatrix, current.DisplayMatrix) || ...
                            ~strcmp(st.WorkingDir, currentState.WorkingDir)
                        error('QcAlignDialog:Changed', '当前图像或变换已变化，请关闭确认窗口后重新打开。');
                    end
                    method = 'header-only'; if advanced.Value, method = 'resample'; end
                    result = obj.Panel.applyCurrentToData(method);
                    maxError = max([result.Verification.SformWorldMaxErrorMm, ...
                        result.Verification.QformWorldMaxErrorMm, result.Verification.QformSformWorldMaxErrorMm]);
                    summary.Value = {['已写出：' result.OutputFile]; ['日志：' result.LogFile]; ...
                        sprintf('头编码全视野最大坐标偏差：%.6g mm（上限0.001 mm）。', maxError); ...
                        '原文件哈希与大小不变；SPM、DPABI 和 MATLAB 读取校验通过。'; ...
                        '回退：删除上述批次目录，并继续使用原图像。'};
                    advanced.Enable = 'off'; write.Text = '写出完成'; cancel.Text = '关闭';
                    setLabel(obj.HintLabel, '已另存变换副本与日志；原文件不变。');
                catch err
                    write.Enable = 'on';
                    uialert(confirm, err.message, '未写出副本');
                end
            end
        end

        function onSetOrigin(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            obj.Panel.setOriginAtCrosshair();
            obj.refresh();
        end

        function onPickAc(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            try
                obj.ACVoxel = obj.Panel.getCrosshairVoxel();
            catch
                obj.ACVoxel = [];
            end
            obj.refresh();
        end

        function onPickPc(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            try
                obj.PCVoxel = obj.Panel.getCrosshairVoxel();
            catch
                obj.PCVoxel = [];
            end
            obj.refresh();
        end

        function onApplyAcPc(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            if isempty(obj.ACVoxel) || isempty(obj.PCVoxel)
                setLabel(obj.HintLabel, '请先拾取 AC 与 PC（把当前位置设为 AC / PC）');
                return;
            end
            try
                obj.Panel.setACPC(obj.ACVoxel, obj.PCVoxel);
            catch
            end
            obj.refresh();
        end

        function onClearAcPc(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            obj.ACVoxel = [];
            obj.PCVoxel = [];
            try
                obj.Panel.clearACPC();
            catch
            end
            obj.refresh();
        end

        function onApplyManual(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            try
                t = [obj.TransFields{1}.Value, obj.TransFields{2}.Value, obj.TransFields{3}.Value];
                r = [obj.RotFields{1}.Value, obj.RotFields{2}.Value, obj.RotFields{3}.Value];
                obj.Panel.setManualOrientation(t, r);
            catch
            end
            obj.refresh();
        end

        function onClearManual(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            try
                obj.Panel.setManualOrientation([0 0 0], [0 0 0]);
            catch
            end
            obj.refresh();
        end

        function onFlipChanged(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            try
                obj.Panel.setFlips(obj.FlipLRCheck.Value, obj.FlipAPCheck.Value, obj.FlipISCheck.Value);
            catch
            end
            obj.refresh();
        end

        function onManualFieldChanged(obj)
            if obj.Syncing
                return;
            end
            % 字段改动后不自动应用（需点“应用微调”），避免误操作。
        end

        function onResetAll(obj)
            if obj.Syncing || ~obj.panelOk()
                return;
            end
            obj.ACVoxel = [];
            obj.PCVoxel = [];
            try
                obj.Panel.resetOrientation();
            catch
            end
            obj.refresh();
        end

        function ok = panelOk(obj)
            ok = false;
            try
                ok = ~isempty(obj.Panel) && isvalid(obj.Panel);
            catch
                ok = false;
            end
            if ~ok && ~obj.Closing
                obj.close();
            end
        end
    end
end

% ======================================================================
%  局部函数
% ======================================================================
function v = fieldOrLocal(s, name, default)
    v = default;
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    end
end

function v = fieldLocal(s, names, default)
    if nargin < 3
        default = [];
    end
    v = default;
    if ~isstruct(s)
        return;
    end
    for i = 1:numel(names)
        if isfield(s, names{i}) && ~isempty(s.(names{i}))
            v = s.(names{i});
            return;
        end
    end
end

function setLabel(h, txt)
    if isempty(h) || ~isvalid(h)
        return;
    end
    try
        if isprop(h, 'Text')
            h.Text = txt;
        else
            h.Value = splitlines(string(txt));
        end
    catch
    end
end

function setButtonEnable(h, tf)
    if isempty(h) || ~isvalid(h)
        return;
    end
    try
        if logical(tf)
            h.Enable = 'on';
        else
            h.Enable = 'off';
        end
    catch
    end
end

function s = fmtVec3Local(v)
    s = '(—, —, —)';
    if ~isnumeric(v)
        return;
    end
    v = double(v(:).');
    if numel(v) < 3 || any(~isfinite(v(1:3)))
        return;
    end
    s = sprintf('(%.1f, %.1f, %.1f)', v(1), v(2), v(3));
end

function s = alignModeLabelLocal(mode)
    switch lower(char(mode))
        case 'origin'
            s = 'origin（显示原点）';
        case 'acpc'
            s = 'acpc（AC-PC 配平）';
        otherwise
            s = 'native（原生）';
    end
end

function [t, r] = manualLocal(info)
    t = [0 0 0];
    r = [0 0 0];
    if ~isstruct(info)
        return;
    end
    tv = [];
    rv = [];
    if isfield(info, 'Manual') && isstruct(info.Manual)
        tv = fieldLocal(info.Manual, {'TranslationMm', 'Translation', 'translationMm'});
        rv = fieldLocal(info.Manual, {'RotationDeg', 'Rotation', 'rotationDeg'});
    end
    if isempty(tv)
        tv = fieldLocal(info, {'ManualTranslationMm', 'TranslationMm'});
    end
    if isempty(rv)
        rv = fieldLocal(info, {'ManualRotationDeg', 'RotationDeg'});
    end
    if isnumeric(tv) && numel(tv) >= 3 && all(isfinite(double(tv(1:3))))
        t = double(tv(1:3));
    end
    if isnumeric(rv) && numel(rv) >= 3 && all(isfinite(double(rv(1:3))))
        r = double(rv(1:3));
    end
end

function fl = flipsLocal(info)
    fl = [false false false];
    if ~isstruct(info) || ~isfield(info, 'Flips')
        return;
    end
    f = info.Flips;
    if (islogical(f) || isnumeric(f)) && numel(f) >= 3
        fl = logical(f(1:3));
        return;
    end
    if isstruct(f)
        lr = fieldLocal(f, {'LR', 'lr'}, false);
        ap = fieldLocal(f, {'AP', 'ap'}, false);
        is = fieldLocal(f, {'IS', 'is'}, false);
        fl = [logical(lr), logical(ap), logical(is)];
    end
end

function s = matSummaryLocal(M)
    lines = cell(1, 4);
    for i = 1:4
        lines{i} = sprintf('% .9g % .9g % .9g % .9g', M(i, 1), M(i, 2), M(i, 3), M(i, 4));
    end
    s = strjoin(lines, newline);
end
