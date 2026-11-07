classdef QcPanel < handle
% QcPanel  可缩放人工 QC 面板（参考 DPARSF/DPABI 的 QC 工具）
%
% 设计目标（QC_CONTRACT v1 第 2 节）：
%   - 左列受试者表（约 240px）+ 中间可缩放图像 + 右列 1-5 分评分栏（约 260px）
%   - 普通滚轮切层、Ctrl+滚轮缩放、单击十字线、拖拽平移；三正交独立范围
%     并配套 [－][1:1][＋][适应] 按钮与倍数标签
%   - 切片滑条、方向下拉（横断/冠状/矢状）；窗宽低/高百分位（默认 2/98）
%   - 标准化模态叠加 DPABI MNI 边缘模板轮廓（来自 mrw.QcModel.edgeSliceFor）
%   - 1-5 分人工评分 + 评语，写入 DPARSF 兼容的 QC/*.tsv
%   - 全中文（英文副标题）、每个交互控件有 Tooltip、UiKit 主题
%
% 缩放实现（重要，测试断言依赖此语义）：
%   坐标约定：QcView 统一世界/显示 mm 网格，imagesc 使用像素中心、范围使用像素边界，
%   并固定 DataAspectRatio=[1 1 1]（DataAspectRatioMode=manual），因此 1 倍
%   （适应窗口）时图像完整显示在 axes 内（可能留黑边），不依赖 axes 像素尺寸。
%   setZoomFactor(f)：作用于活动视图，保留平移中心，把 XLim/YLim 宽度缩到 1/f
%   （f=1 即整幅切片 = 适应窗口，f>=0.5）。
%   getZoomFactor()：由活动视图完整世界范围与 XLim/YLim 的宽度比反推倍数，
%   因此用户用滚轮/拖拽交互后再读取仍然准确，不依赖内部计数变量。
%
% 键盘：图像所在 figure 的 WindowKeyPressFcn 被链式接管（保存并恢复原回调）：
%   ↑/↓ 切换切片，←/→ 切换受试者，Home/End 首/末切片。
%   文本框/下拉框获得焦点时不拦截按键。注意这是可选增强，需在真实 GUI 生效。
%
% 依赖：mrw.QcModel（静态数据模型）、mrw.UiKit（主题）、mrw.Glossary（术语提示）。
%       所有 QcModel 调用均 try/catch 包裹：模型/文件缺失时显示中文提示而不崩溃。
%
% 用法：
%   p = mrw.QcPanel(parent, struct('WorkingDir', wd, 'Modality', 'T1', 'Footer', true));
%   st = p.getState();
%   f  = p.setZoomFactor(2.5);      % 返回实际倍数
%   list = p.exportPassList('D:\out\pass.txt');
%
% 事件：
%   Changed  评分保存 / 受试者切换 / 模态切换后触发
%
% 版本 1.0.0（qc-ui，2026-11）

    properties (SetAccess = private)
        Parent       = []          % 父容器
        Axes         = []          % 图像 axes（供主程序/测试读取交互与范围）
        BuildSeconds = 0           % 构造耗时（秒，含首次数据加载）
        ControlCount = 0           % 交互控件数量（按钮/下拉/编辑框/滑条/表格/单选）
        Version      = '2.0.0'
    end

    properties (Access = private)
        % ---- 选项与主题 ----
        Options = struct()
        Colors  = struct()
        Fonts   = struct()
        % ---- 外壳 ----
        Root        = []
        Toolbar     = []
        ToolbarGrid = []
        TitleLabel  = []
        WorkdirField = []
        BrowseButton = []
        RescanButton = []
        ModalityDropdown = []
        ProgressBadge = []
        MainGrid = []
        % ---- 左列 ----
        LeftPanel = []
        LeftGrid = []
        ListSummaryLabel = []
        SubjectTable = []
        PrevButton = []
        NextButton = []
        OnlyUnscoredCheck = []
        ThresholdDropdown = []
        ExportButton = []
        LeftHintLabel = []
        % ---- 中间 ----
        CenterPanel = []
        CenterGrid = []
        SubjectTitleLabel = []
        FileTitleLabel = []
        OrientationDropdown = []
        SliceSlider = []
        SliceField = []
        SliceCountLabel = []
        ZoomOutButton = []
        ZoomOneButton = []
        ZoomInButton = []
        ZoomFitButton = []
        ZoomLabel = []
        ZoomHintLabel = []
        WinLowField = []
        WinHighField = []
        ClimLabel = []
        WindowToolsGrid = []
        DisplayToolsGrid = []
        % ---- 右列 ----
        RightPanel = []
        RightGrid = []
        ScoreSubtitle = []
        ScoreGroup = []
        ScoreRadios = {}
        CommentLabel = []
        CommentArea = []
        SaveButton = []
        SkipButton = []
        DisplayHeading = []
        AutoWindowButton = []
        ResetViewButton = []
        OverlayCheck = []
        OverlayAlphaLabel = []
        OverlayAlphaSlider = []
        NormKindDropdown = []
        MeanFDLabel = []
        ProgressLabel = []
        % ---- v2：工具条（视图模式 / 复制状态） ----
        ViewModeDropdown = []
        CopyStateButton = []
        % ---- v2：中列视图容器与三正交 / 多切片 ----
        ViewHost = []
        SingleViewGrid = []
        TripleViewGrid = []
        MontageViewGrid = []
        TripleAxes = struct('Axial', [], 'Coronal', [], 'Sagittal', [])
        TripleImages = struct('Axial', [], 'Coronal', [], 'Sagittal', [])
        TripleCross = struct('Axial', [], 'Coronal', [], 'Sagittal', [])
        SingleCross = []
        SingleInfo = struct()
        TripleInfo = struct('Axial', struct(), 'Coronal', struct(), 'Sagittal', struct())
        TripleInfoLabel = []
        TripleInfoPanel = []
        MontageAxes = []
        MontageImageHandle = []
        MontageInfo = struct()
        CrosshairCheck = []
        ColormapDropdown = []
        InterpDropdown = []
        AlignButton = []
        ResetAlignButton = []
        CoordLabel = []
        ViewMode = 'single'
        ActiveOrientation = 'axial'
        CrosshairVoxel = []
        CrosshairVisible = true
        ColormapName = 'gray'
        InterpMethod = 'linear'
        TripleBuilt = false
        MontageBuilt = false
        % ---- v2：左列筛选 / 排序 ----
        FilterDropdown = []
        SortDropdown = []
        FilterMode = 'all'
        SortMode = 'id'
        % ---- v2：右列方位校准摘要 ----
        AlignHeading = []
        AlignSummaryLabel = []
        % ---- v2：底部头动条（FD 曲线） ----
        MotionPanel = []
        MotionLayout = []
        MotionBody = []
        FdToggle = []
        FdExpanded = false
        FdAxes = []
        FdTitleLabel = []
        FdTypeDropdown = []
        FdThresholdField = []
        FdStatsLabel = []
        FdLine = []
        FdThreshLine = []
        FdBadLine = []
        FdType = 'FD_Jenkinson'
        FdThreshold = 0.2
        Fd = struct('Available', false, 'Values', [], 'Type', 'FD_Jenkinson', ...
            'Threshold', 0.2, 'MeanFD', NaN, 'MaxFD', NaN, 'BadFrames', [], ...
            'BadRatio', 0, 'Message', '')
        % ---- v2：显示引擎 / 状态文件 / 校准对话框 ----
        View = []
        ViewKey = ''
        AlignDialog = []
        StateFile = ''
        StateWriteTic = []
        LastExportedState = struct()
        UpdatingViewUI = false
        UpdatingFilterUI = false
        UpdatingFdUI = false
        % ---- 底部 ----
        FooterPanel = []
        FooterGrid = []
        FooterProgressLabel = []
        MessageLabel = []
        VersionLabel = []
        % ---- 监听器 / 键盘 ----
        LimListenerX = []
        LimListenerY = []
        FigureHandle = []
        KeyPressHandler = []
        PrevWindowKeyPressFcn = []
        PreviousMouseCallbacks = struct()
        MouseCallbacks = struct()
        MouseDrag = struct()
        PendingSlice = []
        SliceBusy = false
        % ---- 数据状态 ----
        WorkDir = ''
        ModalityKey = 'T1'
        Discover = []
        ModelProgress = []
        Thresholds = struct()
        HeadMotion = struct()
        SubjectList = {}                            % cell of struct: ID/Available/File/FileKind/Message/Candidates
        FilteredIdx = []                            % 显示用：SubjectList 的下标
        Scores = struct('ID', {}, 'Score', {}, 'Comment', {})
        % ---- 选择/视图状态 ----
        SubjectIndex = 0
        SubjectID = ''
        Orientation = 'axial'
        SliceIndex = 1
        SliceCount = 1
        MinScore = 3
        Score = 3
        Comment = ''
        Zoom = 1
        WindowLowPct = 2
        WindowHighPct = 98
        OverlayVisible = true
        OverlayAlpha = 0.55
        NormKind = 'Fun'
        HasImage = false
        ImageSize = [0 0]
        FullXLim = [0 1]
        FullYLim = [0 1]
        Clim = [0 1]
        CurrentImage = []
        CurrentEdge = []
        CurrentSliceLabel = ''
        MainImage = []
        OverlayImage = []
        % ---- 卷缓存（最近 3 个）----
        CacheMap = []
        CacheOrder = {}
        EdgeCache = []
        % ---- 守卫 / 标记 ----
        Built = false
        Constructing = true
        UpdatingAxes = false
        UpdatingSliceUI = false
        UpdatingTable = false
        LastModelError = ''
        Message = ''
        AutoNext = true
    end

    events
        Changed
    end

    % ==================================================================
    %  公共接口（契约 + 少量测试辅助）
    % ==================================================================
    methods
        function obj = QcPanel(parent, options)
            if nargin < 1 || isempty(parent) || ~isvalid(parent)
                error('QcPanel:Parent', '必须提供有效的父容器（uipanel / uigridlayout 等）。');
            end
            if nargin < 2 || isempty(options)
                options = struct();
            end
            obj.Parent = parent;
            obj.Colors = mrw.UiKit.colors();
            obj.Fonts  = mrw.UiKit.fonts();
            obj.Options = obj.normalizeOptions(options);
            obj.AutoNext = obj.Options.AutoNext;
            if ~isempty(obj.Options.WorkingDir)
                obj.WorkDir = char(obj.Options.WorkingDir);
            end
            obj.ModalityKey = normalizeModalityKey(obj.Options.Modality);
            if isempty(obj.ModalityKey)
                obj.ModalityKey = 'T1';
            end
            obj.CacheMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.EdgeCache = containers.Map('KeyType', 'char', 'ValueType', 'any');

            obj.Constructing = true;
            t0 = tic;
            obj.buildShell();
            obj.buildLeft();
            obj.buildCenter();
            obj.buildRight();
            obj.buildMotion();
            if obj.Options.Footer
                obj.buildFooter();
            else
                try
                    rh = obj.Root.RowHeight;
                    rh{4} = 0;
                    obj.Root.RowHeight = rh;
                catch
                end
            end
            obj.Built = true;
            obj.attachKeyboard();
            if ~isempty(obj.WorkDir)
                try, obj.WorkdirField.Value = obj.WorkDir; catch, end
            end
            obj.doRefresh(true);
            obj.Constructing = false;
            obj.BuildSeconds = toc(t0);
            obj.ControlCount = obj.countInteractiveControls();
            obj.syncFilterSortUi();
            obj.syncFdUi();
            obj.syncViewModeUI();
            obj.updateAlignSummary();
            obj.updateCoordLabel();
            try
                obj.writeStateNow();
            catch
            end
        end

        function setWorkingDir(obj, workDir)
            % 设置工作目录并重新扫描（空字符串=清空）
            if isstring(workDir)
                workDir = char(workDir);
            elseif ~ischar(workDir)
                workDir = '';
            end
            obj.WorkDir = strtrim(workDir);
            try, obj.WorkdirField.Value = obj.WorkDir; catch, end
            obj.clearCache();
            obj.SubjectID = '';
            obj.SubjectIndex = 0;
            obj.SliceIndex = 0;
            obj.SliceCount = 1;
            obj.Zoom = 1;
            obj.Scores = struct('ID', {}, 'Score', {}, 'Comment', {});
            obj.SubjectList = {};
            obj.FilteredIdx = [];
            obj.ModelProgress = [];
            obj.doRefresh(true);
        end

        function refresh(obj)
            % 重新发现数据/评分并刷新界面
            obj.clearCache();
            obj.doRefresh(false);
        end

        function setModality(obj, key)
            % 切换模态：'T1' | 'Fun' | 'Norm'
            k = normalizeModalityKey(key);
            if isempty(k)
                return;
            end
            same = strcmp(k, obj.ModalityKey);
            obj.ModalityKey = k;
            if ~same
                obj.SubjectID = '';
                obj.SubjectIndex = 0;
                obj.SliceIndex = 0;
                obj.Zoom = 1;
            end
            try
                if any(strcmp(obj.ModalityDropdown.ItemsData, k))
                    obj.ModalityDropdown.Value = k;
                end
            catch
            end
            obj.doRefresh(~same);
        end

        function setSubject(obj, subjIDORindex)
            % 按受试者 ID（char）或 SubjectList 下标（numeric）切换
            if isempty(obj.SubjectList)
                obj.setMessage('没有可用受试者');
                return;
            end
            idx = 0;
            if isnumeric(subjIDORindex) && isscalar(subjIDORindex) && isfinite(subjIDORindex)
                idx = round(double(subjIDORindex));
                idx = max(1, min(numel(obj.SubjectList), idx));
            elseif ischar(subjIDORindex) || isstring(subjIDORindex)
                ids = obj.subjectIDs();
                k = find(strcmp(ids, char(subjIDORindex)), 1);
                if ~isempty(k)
                    idx = k;
                else
                    obj.setMessage(sprintf('受试者不存在：%s', char(subjIDORindex)));
                    return;
                end
            end
            if idx < 1
                return;
            end
            changed = idx ~= obj.SubjectIndex;
            obj.selectSubjectIndex(idx, true);
            if changed
                obj.updateMeanFDUi();
                obj.notifyChangedIfReady();
            end
        end

        function setOrientation(obj, orient)
            % 切片方向：'axial' | 'coronal' | 'sagittal'（也接受中文）
            o = normalizeOrientationValue(orient);
            if isempty(o)
                return;
            end
            obj.Orientation = o;
            try
                if any(strcmp(obj.OrientationDropdown.ItemsData, o))
                    obj.UpdatingViewUI = true;
                    obj.OrientationDropdown.Value = o;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            if strcmp(obj.ViewMode, 'triple')
                obj.setActiveOrientation(o);
                return;
            end
            if strcmp(obj.ViewMode, 'montage')
                obj.renderMontage();
                obj.maybeWriteState();
                return;
            end
            if ~isempty(obj.currentSubject())
                obj.loadCurrentSlice(false);
            end
            obj.maybeWriteState();
        end

        function setSliceIndex(obj, idx)
            % 切片序号（1 起，越界 clamp）；三正交/多切片模式下控制活动视图方向
            if ~isnumeric(idx) || ~isscalar(idx) || ~isfinite(idx)
                return;
            end
            v = round(double(idx));
            if strcmp(obj.ViewMode, 'triple') && obj.TripleBuilt
                o = obj.ActiveOrientation;
                n = obj.viewSliceCount(o);
                if isempty(n) || ~isfinite(n) || n < 1
                    n = max(1, obj.SliceCount);
                end
                v = max(1, min(round(n), v));
                if obj.ensureView()
                    try, obj.View.setSliceIndex(o, v); catch, end
                    try, obj.CrosshairVoxel = double(obj.View.getCrosshair()); catch, end
                end
                obj.SliceIndex = v;
                obj.SliceCount = round(n);
                obj.renderTriple();
                obj.syncSliceUI();
                obj.maybeWriteState();
                return;
            end
            if strcmp(obj.ViewMode, 'montage') && obj.MontageBuilt
                o = obj.Orientation;
                n = obj.viewSliceCount(o);
                if isempty(n) || ~isfinite(n) || n < 1
                    n = max(1, obj.SliceCount);
                end
                v = max(1, min(round(n), v));
                if obj.ensureView()
                    try, obj.View.setSliceIndex(o, v); catch, end
                    try, obj.CrosshairVoxel = double(obj.View.getCrosshair()); catch, end
                else
                    c = obj.getCrosshairVoxel();
                    dims = obj.currentVolumeDims();
                    if ~isempty(c) && ~isempty(dims) && all(isfinite(c))
                        switch o
                            case 'axial'
                                c(3) = max(1, min(dims(3), v));
                            case 'coronal'
                                c(2) = max(1, min(dims(2), v));
                            otherwise
                                c(1) = max(1, min(dims(1), v));
                        end
                        obj.CrosshairVoxel = double(c(:).');
                    end
                end
                obj.SliceIndex = v;
                obj.SliceCount = round(n);
                obj.renderMontage();
                obj.syncSliceUI();
                obj.maybeWriteState();
                return;
            end
            if obj.SliceCount < 1
                obj.SliceIndex = max(1, v);
                return;
            end
            v = max(1, min(obj.SliceCount, v));
            if v == obj.SliceIndex && obj.HasImage
                return;
            end
            obj.SliceIndex = v;
            if ~isempty(obj.currentSubject())
                obj.loadCurrentSlice(false);
            else
                obj.syncSliceUI();
            end
            obj.maybeWriteState();
        end

        function f = setZoomFactor(obj, f)
            % 设置缩放倍数（f>=0.5；1=适应窗口）；返回实际生效倍数
            obj.applyZoom(f);
            f = obj.Zoom;
        end

        function f = getZoomFactor(obj)
            % 当前缩放倍数（相对适应窗口，1=完整显示）；由 axes 范围反推
            if ~obj.HasImage
                f = obj.Zoom;
                if ~isnumeric(f) || ~isscalar(f) || ~isfinite(f) || f <= 0
                    f = 1;
                end
                return;
            end
            f = obj.computeZoomFactor();
            if ~isnumeric(f) || ~isscalar(f) || ~isfinite(f) || f <= 0
                f = 1;
            end
        end

        function setWindow(obj, lowPct, highPct)
            % 窗宽显示的低/高百分位（0-100）
            if nargin < 3 || isempty(highPct)
                highPct = obj.WindowHighPct;
            end
            if ~isnumeric(lowPct) || ~isscalar(lowPct) || ~isfinite(lowPct), return; end
            if ~isnumeric(highPct) || ~isscalar(highPct) || ~isfinite(highPct), return; end
            lo = max(0, min(100, round(double(lowPct))));
            hi = max(0, min(100, round(double(highPct))));
            if lo >= hi
                if lo >= 100
                    lo = 99;
                    hi = 100;
                else
                    hi = min(100, lo + 1);
                end
            end
            obj.WindowLowPct = lo;
            obj.WindowHighPct = hi;
            obj.syncWindowUI();
            obj.applyWindowToAxes();
        end

        function setOverlayVisible(obj, tf)
            % 标准化模态的 MNI 模板轮廓开关
            obj.OverlayVisible = logical(tf);
            try, obj.OverlayCheck.Value = obj.OverlayVisible; catch, end
            if ~strcmp(obj.ModalityKey, 'Norm')
                return;
            end
            if ~obj.HasImage
                return;
            end
            if obj.OverlayVisible && (isempty(obj.CurrentEdge) || ~any(obj.CurrentEdge(:) > 0.05))
                obj.loadCurrentSlice(false);
                return;
            end
            obj.refreshOverlay();
            obj.updateImageTitle(obj.currentFile());
        end

        function ok = saveCurrentScore(obj)
            % 保存当前评分与评语到 QcModel（DPARSF 兼容 TSV），成功后自动下一人
            ok = false;
            s = obj.currentSubject();
            if isempty(s) || isempty(obj.SubjectID)
                obj.setMessage('未选择受试者，无法保存评分');
                return;
            end
            score = obj.readScoreSelection();
            if score < 1 || score > 5 || score ~= round(score)
                obj.setMessage(sprintf('评分必须是 1-5 的整数（当前 %s）', num2str(score)));
                return;
            end
            comment = obj.readComment();
            if isempty(obj.WorkDir)
                obj.setMessage('尚未选择工作目录，无法保存评分');
                return;
            end
            [ok, msg] = obj.modelSaveScore(obj.WorkDir, obj.ModalityKey, s.ID, score, comment);
            ok = isequal(logical(ok), true);
            if ok
                obj.setScoreInCache(s.ID, score, comment);
                obj.Score = score;
                obj.Comment = comment;
                obj.setMessage(sprintf('已保存 %s：%d 分（%s）', s.ID, score, obj.modalityLabel()));
                obj.rebuildTable();
                obj.updateProgressUI();
                obj.updateFooter();
                obj.updateFdCurve();
                obj.notifyChangedIfReady();
                if obj.AutoNext
                    obj.nextSubject();
                end
            else
                if isempty(msg)
                    msg = obj.LastModelError;
                end
                if isempty(msg)
                    msg = 'QcModel.saveScore 返回 false';
                end
                obj.setMessage(sprintf('保存失败：%s', msg));
            end
        end

        function nextSubject(obj)
            % 下一人（在当前筛选列表中移动，到末尾不环绕）
            if isempty(obj.FilteredIdx)
                obj.setMessage('没有可切换的受试者（可能被“仅显示未评分”筛选掉了）');
                return;
            end
            pos = find(obj.FilteredIdx == obj.SubjectIndex, 1);
            if isempty(pos)
                pos = 0;
            end
            if pos >= numel(obj.FilteredIdx)
                obj.setMessage('已是最后一位受试者');
                return;
            end
            obj.selectSubjectIndex(obj.FilteredIdx(pos + 1), true);
            obj.updateMeanFDUi();
            obj.updateFooter();
            obj.notifyChangedIfReady();
        end

        function prevSubject(obj)
            % 上一人
            if isempty(obj.FilteredIdx)
                obj.setMessage('没有可切换的受试者（可能被“仅显示未评分”筛选掉了）');
                return;
            end
            pos = find(obj.FilteredIdx == obj.SubjectIndex, 1);
            if isempty(pos)
                pos = numel(obj.FilteredIdx) + 1;
            end
            if pos <= 1
                obj.setMessage('已是第一位受试者');
                return;
            end
            obj.selectSubjectIndex(obj.FilteredIdx(pos - 1), true);
            obj.updateMeanFDUi();
            obj.updateFooter();
            obj.notifyChangedIfReady();
        end

        function st = getState(obj)
            % 返回当前界面状态（含缩放/切片/评分/进度）
            st = struct();
            st.WorkingDir   = obj.WorkDir;
            st.Modality     = obj.ModalityKey;
            st.SubjectID    = obj.SubjectID;
            st.Score        = obj.Score;          % 右侧当前选择的分数（默认 3）
            st.SavedScore   = obj.savedScoreFor(obj.SubjectID);  % 已保存分数（未评分=NaN）
            st.Comment      = obj.Comment;
            st.SliceIndex   = obj.SliceIndex;
            st.SliceCount   = obj.SliceCount;
            st.SliceLabel   = obj.CurrentSliceLabel;
            st.Orientation  = obj.Orientation;
            st.Zoom         = obj.getZoomFactor();
            st.Window       = [obj.WindowLowPct obj.WindowHighPct];
            st.OverlayVisible = obj.OverlayVisible;
            st.OverlayAlpha   = obj.OverlayAlpha;
            st.NormKind       = obj.NormKind;
            st.MinScore       = obj.MinScore;
            st.OnlyUnscored   = obj.onlyUnscoredValue();
            st.AutoNext       = obj.AutoNext;
            st.HasImage       = obj.HasImage;
            st.Progress       = obj.progressSummary();
            st.SubjectCount   = numel(obj.SubjectList);
            st.VisibleSubjectCount = numel(obj.FilteredIdx);
            st.Message        = obj.Message;
            st.ControlCount   = obj.ControlCount;
            st.BuildSeconds   = obj.BuildSeconds;
            % ---- v2 增补字段（向后兼容，契约 §5.6 / §7） ----
            st.ViewMode = obj.ViewMode;
            st.ActiveOrientation = obj.ActiveOrientation;
            cp = obj.getCrosshairVoxel();
            st.CrosshairVoxel = cp;
            [cw, cd] = obj.crosshairWorldDisplay(cp);
            vi = obj.getViewInfo();
            st.CrosshairWorld = cw;
            st.CrosshairDisplay = cd;
            [manT, manR] = manualFromInfo(vi);
            fl = flipsFromInfo(vi);
            acpc = fieldAny(vi, {'ACPC'}, struct());
            disp = struct();
            disp.Mode = lower(char(fieldAny(vi, {'Mode'}, 'native')));
            disp.HasVolume = logical(fieldAny(vi, {'HasVolume'}, false));
            dm = fieldAny(vi, {'DisplayMatrix'}, eye(4));
            if isnumeric(dm) && numel(dm) >= 16
                disp.DisplayMatrix = double(reshape(dm(1:16), 4, 4));
            else
                disp.DisplayMatrix = eye(4);
            end
            disp.ACVoxel = vecOrEmpty(fieldAny(vi, {'ACVoxel'}, []), 3);
            disp.PCVoxel = vecOrEmpty(fieldAny(vi, {'PCVoxel'}, []), 3);
            disp.ACWorld = vecOrEmpty(fieldAny(vi, {'ACWorld'}, []), 3);
            disp.PCWorld = vecOrEmpty(fieldAny(vi, {'PCWorld'}, []), 3);
            disp.ACPC = struct( ...
                'distanceMm', double(fieldAny(acpc, {'distanceMm', 'DistanceMm'}, NaN)), ...
                'angleDeg', double(fieldAny(acpc, {'angleDeg', 'AngleDeg'}, NaN)), ...
                'rotationDeg', manR, 'translationMm', manT);
            disp.Manual = struct('TranslationMm', manT, 'RotationDeg', manR);
            disp.Flips = struct('LR', logical(fl(1)), 'AP', logical(fl(2)), 'IS', logical(fl(3)));
            disp.Message = char(fieldAny(vi, {'Message'}, ''));
            st.Display = disp;
            st.Colormap = obj.ColormapName;
            st.Interp = obj.InterpMethod;
            st.CrosshairVisible = logical(obj.CrosshairVisible);
            st.Filter = obj.FilterMode;
            st.Sort = obj.SortMode;
            st.StateFile = obj.StateFile;
            st.AxesHandles = struct('Single', obj.Axes, ...
                'Axial', obj.TripleAxes.Axial, 'Coronal', obj.TripleAxes.Coronal, ...
                'Sagittal', obj.TripleAxes.Sagittal, 'Montage', obj.MontageAxes, ...
                'Fd', obj.FdAxes);
            fd = obj.Fd;
            vals = [];
            if isstruct(fd) && isfield(fd, 'Values') && ~isempty(fd.Values)
                vals = double(fd.Values(:).');
            end
            bad = [];
            if ~isempty(vals)
                bad = find(vals > obj.FdThreshold);
            end
            % MeanFD 与窗口显示/通过名单一致：取 HeadMotion.tsv 第 21 列（mean FD_Jenkinson）；
            % 缺失时才退回逐帧序列均值。MaxFD/BadFrames/BadRatio 为逐帧序列口径。
            seriesMeanFD = NaN;
            maxFD = NaN;
            if ~isempty(vals)
                seriesMeanFD = mean(vals);
                maxFD = max(vals);
            end
            [tsvMeanFD, maxT, maxR] = obj.hmStatsForSubject(obj.SubjectID);
            meanFD = tsvMeanFD;
            if ~isfinite(meanFD)
                meanFD = seriesMeanFD;
            end
            st.FD = struct('Type', obj.FdType, 'Threshold', obj.FdThreshold, ...
                'Available', logical(isstruct(fd) && isfield(fd, 'Available') && ...
                logical(fieldOr(fd, 'Available', false))), ...
                'File', char(fieldOr(fd, 'File', '')), ...
                'Message', char(fieldOr(fd, 'Message', '')), ...
                'Values', vals, 'MeanFD', meanFD, 'SeriesMeanFD', seriesMeanFD, ...
                'BadFrames', bad, ...
                'BadRatio', numel(bad) / max(1, numel(vals)), ...
                'MeanFDSource', 'HeadMotion.tsv#meanFD_Jenkinson', ...
                'MaxFD', maxFD, 'MaxTranslation', maxT, 'MaxRotation', maxR);
            st.ViewInfo = vi;
        end

        function list = exportPassList(obj, filePath)
            % 调用 QcModel.exportPassList（按各模态最低分与 MeanFD 阈值）
            list = {};
            if isempty(obj.WorkDir)
                obj.setMessage('尚未选择工作目录，无法导出通过名单');
                return;
            end
            if nargin < 2 || isempty(filePath)
                filePath = fullfile(obj.WorkDir, 'QC', 'PassList.txt');
            end
            thr = obj.mergeThresholds(obj.Thresholds);
            field = sprintf('%sMin', obj.ModalityKey);
            try
                thr.(field) = obj.MinScore;
            catch
            end
            res = obj.modelCall('exportPassList', obj.WorkDir, filePath, thr);
            err = obj.LastModelError;
            list = {};
            if iscell(res)
                list = res(:)';
            elseif ischar(res) && ~isempty(res)
                list = {res};
            elseif isstring(res)
                list = cellstr(res)';
            end
            if isempty(err)
                obj.setMessage(sprintf('已导出通过名单：%s（%d 人）', filePath, numel(list)));
            else
                obj.setMessage(sprintf('导出失败：%s', err));
            end
        end

        % ---------------- 便捷设置（测试/主程序用，非契约必需） ----------------
        function setScore(obj, v)
            if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
                return;
            end
            v = round(double(v));
            if v < 1 || v > 5
                return;
            end
            obj.Score = v;
            obj.selectScoreRadio(v);
        end

        function setComment(obj, txt)
            obj.Comment = toTextValue(txt);
            try, obj.CommentArea.Value = obj.Comment; catch, end
        end

        function setOverlayAlpha(obj, a)
            if ~isnumeric(a) || ~isscalar(a) || ~isfinite(a)
                return;
            end
            obj.OverlayAlpha = max(0, min(1, double(a)));
            try, obj.OverlayAlphaSlider.Value = obj.OverlayAlpha; catch, end
            if ~isempty(obj.OverlayImage) && isvalid(obj.OverlayImage) && ~isempty(obj.CurrentEdge)
                try
                    obj.OverlayImage.AlphaData = obj.OverlayAlpha * double(obj.CurrentEdge > 0.05);
                catch
                end
            end
        end

        function setNormKind(obj, kind)
            % 标准化子图：'Fun' | 'T1' | 'GM'
            if ~any(strcmp({'Fun', 'T1', 'GM'}, kind))
                return;
            end
            obj.NormKind = kind;
            try
                if any(strcmp(obj.NormKindDropdown.ItemsData, kind))
                    obj.NormKindDropdown.Value = kind;
                end
            catch
            end
            if strcmp(obj.ModalityKey, 'Norm')
                obj.loadCurrentSlice(false);
            end
        end

        function setFilterOnlyUnscored(obj, tf)
            if logical(tf)
                obj.setFilter('unscored');
            elseif strcmp(obj.FilterMode, 'unscored')
                obj.setFilter('all');
            else
                obj.syncFilterSortUi();
            end
        end

        function setThreshold(obj, v)
            if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
                return;
            end
            v = max(1, min(5, round(double(v))));
            obj.MinScore = v;
            try, obj.ThresholdDropdown.Value = v; catch, end
            try
                obj.Thresholds.(sprintf('%sMin', obj.ModalityKey)) = v;
            catch
            end
            obj.rebuildTable();
        end

        function setAutoNext(obj, tf)
            obj.AutoNext = logical(tf);
        end

        function ids = getSubjectIDs(obj)
            ids = obj.subjectIDs();
        end

        function file = getCurrentFile(obj)
            file = obj.currentFile();
        end
    end

    % ==================================================================
    %  界面搭建
    % ==================================================================
    methods (Access = private)

        function o = normalizeOptions(~, options)
            o = struct('WorkingDir', '', 'Modality', 'T1', 'Footer', true, 'AutoNext', true);
            if ~isstruct(options)
                return;
            end
            f = fieldnames(options);
            for i = 1:numel(f)
                if isfield(o, f{i})
                    o.(f{i}) = options.(f{i});
                end
            end
            if isstring(o.WorkingDir)
                o.WorkingDir = char(o.WorkingDir);
            elseif ~ischar(o.WorkingDir)
                o.WorkingDir = '';
            end
            o.Footer = logical(o.Footer);
            o.AutoNext = logical(o.AutoNext);
        end

        function buildShell(obj)
            c = obj.Colors;
            f = obj.Fonts;

            % FD 默认收起，把主要高度留给完整切片；展开后保留原曲线与控件。
            obj.Root = uigridlayout(obj.Parent, [4 1]);
            obj.Root.RowHeight = {44, '1x', 32, 28};
            obj.Root.ColumnWidth = {'1x'};
            obj.Root.RowSpacing = 4;
            obj.Root.Padding = [12 8 12 8];
            obj.Root.BackgroundColor = c.bg;
            obj.Root.Tag = 'qcRoot';

            % ---------------- 顶部工具条 ----------------
            tb = uipanel(obj.Root, 'BorderType', 'line', 'HighlightColor', c.border, ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text);
            tb.Layout.Row = 1;
            obj.Toolbar = tb;

            tg = uigridlayout(tb, [1 8]);
            tg.RowHeight = {'1x'};
            tg.ColumnWidth = {196, '1x', 74, 84, 168, 148, 132, 118};
            tg.Padding = [12 4 12 4];
            tg.RowSpacing = 0;
            tg.ColumnSpacing = 8;
            tg.BackgroundColor = c.panel;
            obj.ToolbarGrid = tg;

            obj.TitleLabel = uilabel(tg, 'Text', '人工 QC（Manual QC）', ...
                'FontName', f.name, 'FontSize', f.large, 'FontWeight', 'bold', ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            obj.TitleLabel.Layout.Row = 1;
            obj.TitleLabel.Layout.Column = 1;
            mrw.UiKit.tip(obj.TitleLabel, ['可缩放人工 QC 面板（参考 DPARSF / DPABI_QC_TOOL）。' newline ...
                '评分 1=很差 … 5=很好，写入 QC/*.tsv 与 DPARSF 兼容。' newline ...
                '图像支持滚轮缩放、拖拽平移、[－][1:1][＋][适应] 按钮。']);

            obj.WorkdirField = uieditfield(tg, 'text', 'Editable', 'off', ...
                'FontName', f.name, 'FontSize', f.small, 'BackgroundColor', c.panelAlt, ...
                'FontColor', c.text, 'Value', '', 'Tag', 'qcWorkDir');
            obj.WorkdirField.Layout.Row = 1;
            obj.WorkdirField.Layout.Column = 2;
            mrw.UiKit.tip(obj.WorkdirField, ['当前 QC 工作目录（DPARSF 预处理输出目录）。' newline ...
                '可含 T1Img / RealignParameter / T1ImgNewSegment 与 QC/*.tsv。']);

            obj.BrowseButton = mrw.UiKit.button(tg, '浏览…', 'Callback', @(s, e) obj.onBrowseWorkdir());
            obj.BrowseButton.Layout.Row = 1;
            obj.BrowseButton.Layout.Column = 3;
            obj.BrowseButton.Tag = 'qcBrowse';
            mrw.UiKit.tip(obj.BrowseButton, '选择 DPARSF 预处理工作目录（含 T1Img / RealignParameter 等子目录）。');

            obj.RescanButton = mrw.UiKit.button(tg, '重新扫描', 'Callback', @(s, e) obj.onRescan());
            obj.RescanButton.Layout.Row = 1;
            obj.RescanButton.Layout.Column = 4;
            obj.RescanButton.Tag = 'qcRescan';
            mrw.UiKit.tip(obj.RescanButton, '重新扫描目录与 QC 评分 TSV，刷新受试者列表、进度与当前图像。');

            obj.ModalityDropdown = uidropdown(tg, ...
                'Items', {'T1 原始像', '功能平均像', '标准化检查'}, ...
                'ItemsData', {'T1', 'Fun', 'Norm'}, 'Value', 'T1', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcModality', ...
                'ValueChangedFcn', @(s, e) obj.onModalityChanged());
            obj.ModalityDropdown.Layout.Row = 1;
            obj.ModalityDropdown.Layout.Column = 5;
            mrw.UiKit.tip(obj.ModalityDropdown, ['切换 QC 模态（对应 DPARSF 的三个 QC 表）：' newline ...
                'T1 原始像 → QC/RawT1ImgQC.tsv；功能平均像 → QC/RawFunImgQC.tsv；' newline ...
                '标准化检查 → QC/NormalizationQC.tsv（默认叠加 MNI 模板轮廓）。']);

            obj.ViewModeDropdown = uidropdown(tg, ...
                'Items', {'单视图', '三正交（轴/冠/矢）', '多切片网格'}, ...
                'ItemsData', {'single', 'triple', 'montage'}, 'Value', 'single', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcViewMode', ...
                'ValueChangedFcn', @(s, e) obj.onViewModeChanged());
            obj.ViewModeDropdown.Layout.Row = 1;
            obj.ViewModeDropdown.Layout.Column = 6;
            mrw.UiKit.tip(obj.ViewModeDropdown, mrw.UiKit.wrapTooltip({ ...
                '图像区视图模式：', ...
                '单视图 = 传统单切片（v1 行为，缩放/平移）；', ...
                '三正交（轴/冠/矢）= 三方向联动 + 十字线，位置与校准摘要在评分栏下方；', ...
                '多切片网格 = 当前方向的等间隔切片拼图，点击 tile 选层。'}));

            obj.CopyStateButton = mrw.UiKit.button(tg, '复制状态给 Agent', ...
                'Callback', @(s, e) obj.onCopyStatePressed());
            obj.CopyStateButton.Layout.Row = 1;
            obj.CopyStateButton.Layout.Column = 7;
            obj.CopyStateButton.Tag = 'qcCopyState';
            mrw.UiKit.tip(obj.CopyStateButton, mrw.UiKit.wrapTooltip({ ...
                '把当前 QC 状态（受试者/模态/视图模式/十字线/AC-PC/窗宽/叠加/FD/评分）', ...
                '复制为 JSON 文本到剪贴板，可在 DSH 对话里让 Agent 读取并给实时指导。', ...
                '同时自动写入 <工作目录>/QC/.qcviewer_state.json。'}));

            obj.ProgressBadge = mrw.UiKit.badge(tg, '已评分 —', 'plain');
            obj.ProgressBadge.Layout.Row = 1;
            obj.ProgressBadge.Layout.Column = 8;
            obj.ProgressBadge.Tag = 'qcProgressBadge';
            mrw.UiKit.tip(obj.ProgressBadge, '当前模态已评分人数 / 可用受试者人数（评分进度）。');

            % ---------------- 主体三列 ----------------
            obj.MainGrid = uigridlayout(obj.Root, [1 3]);
            obj.MainGrid.RowHeight = {'1x'};
            obj.MainGrid.ColumnWidth = {240, '1x', 262};
            obj.MainGrid.RowSpacing = 0;
            obj.MainGrid.ColumnSpacing = 8;
            obj.MainGrid.Padding = [0 0 0 0];
            obj.MainGrid.BackgroundColor = c.bg;
            obj.MainGrid.Layout.Row = 2;
            tb.AutoResizeChildren = 'off';
            tb.SizeChangedFcn = @(~,~) obj.layoutToolbar();
        end

        function buildLeft(obj)
            c = obj.Colors;
            f = obj.Fonts;

            p = uipanel(obj.MainGrid, 'Title', '受试者列表（Subjects）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            p.Layout.Row = 1;
            p.Layout.Column = 1;
            obj.LeftPanel = p;

            g = uigridlayout(p, [8 1]);
            g.RowHeight = {20, '1x', 30, 26, 26, 26, 30, 24};
            g.ColumnWidth = {'1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 6;
            g.BackgroundColor = c.panel;
            obj.LeftGrid = g;

            obj.ListSummaryLabel = uilabel(g, 'Text', '共 0 人', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel);
            obj.ListSummaryLabel.Layout.Row = 1;
            mrw.UiKit.tip(obj.ListSummaryLabel, '受试者总数 / 已评分人数 / 未评分人数（当前模态）。');

            obj.SubjectTable = uitable(g, ...
                'ColumnName', {'受试者', '评分', 'MeanFD'}, ...
                'ColumnWidth', {78, 42, '1x'}, 'RowName', {}, ...
                'Data', cell(0, 3), ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcSubjectTable');
            obj.SubjectTable.Layout.Row = 2;
            try
                if isprop(obj.SubjectTable, 'SelectionChangedFcn')
                    obj.SubjectTable.SelectionChangedFcn = @(s, e) obj.onTableSelection(e);
                else
                    obj.SubjectTable.CellSelectionCallback = @(s, e) obj.onTableSelection(e);
                end
            catch
                try
                    obj.SubjectTable.CellSelectionCallback = @(s, e) obj.onTableSelection(e);
                catch
                end
            end
            mrw.UiKit.tip(obj.SubjectTable, ['受试者列表：点击行切换当前受试者。' newline ...
                '评分列显示已保存的 1-5 分（— 表示未评分）；红色 = 低分（≤2 或低于当前最低分阈值）。']);

            pg = uigridlayout(g, [1 2]);
            pg.RowHeight = {'1x'};
            pg.ColumnWidth = {'1x', '1x'};
            pg.Padding = [0 0 0 0];
            pg.ColumnSpacing = 6;
            pg.BackgroundColor = c.panel;
            pg.Layout.Row = 3;
            obj.PrevButton = mrw.UiKit.button(pg, '← 上一人', 'Callback', @(s, e) obj.prevSubject());
            obj.PrevButton.Tag = 'qcPrevButton';
            mrw.UiKit.tip(obj.PrevButton, '切换到上一位受试者（当前受试者的未保存评语会保留在界面）。');
            obj.NextButton = mrw.UiKit.button(pg, '下一人 →', 'Callback', @(s, e) obj.nextSubject());
            obj.NextButton.Tag = 'qcNextButton';
            mrw.UiKit.tip(obj.NextButton, '切换到下一位受试者（不保存当前评分；保存请用右侧“保存并下一人”）。');

            % v2：筛选 + 排序（契约 §5.2）
            fsg = uigridlayout(g, [1 4]);
            fsg.RowHeight = {'1x'};
            fsg.ColumnWidth = {30, '1x', 30, '1x'};
            fsg.Padding = [0 0 0 0];
            fsg.ColumnSpacing = 4;
            fsg.BackgroundColor = c.panel;
            fsg.Layout.Row = 4;
            lblF = uilabel(fsg, 'Text', '筛', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lblF, '受试者列表筛选条件（对表格行生效，不影响已保存评分）。');
            obj.FilterDropdown = uidropdown(fsg, ...
                'Items', {'全部', '仅未评分', '已评分', '低分≤阈值', 'MeanFD 超阈值'}, ...
                'ItemsData', {'all', 'unscored', 'scored', 'low', 'meanfd'}, ...
                'Value', 'all', 'FontName', f.name, 'FontSize', f.small, ...
                'Tag', 'qcFilter', 'ValueChangedFcn', @(s, e) obj.onFilterChanged());
            obj.FilterDropdown.Layout.Column = 2;
            mrw.UiKit.tip(obj.FilterDropdown, mrw.UiKit.wrapTooltip({ ...
                '筛选受试者列表：全部 / 仅未评分 / 已评分 /', ...
                '低分≤阈值（评分 ≤ 下方“最低分”阈值）/ MeanFD 超阈值（默认 0.2 mm）。', ...
                '与“仅显示未评分”复选框联动。'}));
            lblS = uilabel(fsg, 'Text', '排', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            lblS.Layout.Column = 3;
            mrw.UiKit.tip(lblS, '受试者列表排序方式（不影响评分/图像）。');
            obj.SortDropdown = uidropdown(fsg, ...
                'Items', {'受试者 ID', '评分↑', '评分↓', 'MeanFD↑', 'MeanFD↓'}, ...
                'ItemsData', {'id', 'score_asc', 'score_desc', 'meanfd_asc', 'meanfd_desc'}, ...
                'Value', 'id', 'FontName', f.name, 'FontSize', f.small, ...
                'Tag', 'qcSort', 'ValueChangedFcn', @(s, e) obj.onSortChanged());
            obj.SortDropdown.Layout.Column = 4;
            mrw.UiKit.tip(obj.SortDropdown, mrw.UiKit.wrapTooltip({ ...
                '排序：受试者 ID（自然排序）/ 评分升序 / 评分降序 /', ...
                'MeanFD 升序 / MeanFD 降序；没有评分或头动数据的受试者排在最后。'}));

            obj.OnlyUnscoredCheck = uicheckbox(g, 'Text', '仅显示未评分（Only unscored）', ...
                'Value', false, 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'Tag', 'qcOnlyUnscored', ...
                'ValueChangedFcn', @(s, e) obj.onOnlyUnscoredChanged());
            obj.OnlyUnscoredCheck.Layout.Row = 5;
            mrw.UiKit.tip(obj.OnlyUnscoredCheck, '只列出尚未评分的受试者，便于快速补评；勾选等价于把上方筛选切到“仅未评分”。');

            obj.ThresholdDropdown = uidropdown(g, ...
                'Items', {'最低分：1', '最低分：2', '最低分：3', '最低分：4', '最低分：5'}, ...
                'ItemsData', [1 2 3 4 5], 'Value', 3, ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcThreshold', ...
                'ValueChangedFcn', @(s, e) obj.onThresholdChanged());
            obj.ThresholdDropdown.Layout.Row = 6;
            mrw.UiKit.tip(obj.ThresholdDropdown, ['当前模态的最低通过分（默认 3，参考 DPABI_QC_TOOL：Score >= 阈值 通过）。' newline ...
                '用于“导出通过名单”，并在表格中把低分受试者标红。']);

            obj.ExportButton = mrw.UiKit.button(g, '导出通过名单（Export）', ...
                'Callback', @(s, e) obj.onExportPressed());
            obj.ExportButton.Layout.Row = 7;
            obj.ExportButton.Tag = 'qcExportButton';
            mrw.UiKit.tip(obj.ExportButton, ['按 T1/功能/标准化最低分（以及可选 MeanFD 阈值）导出通过被试名单。' newline ...
                '文本格式每行一个 ID，写入你选择的文件。']);

            obj.LeftHintLabel = uilabel(g, 'Text', '提示：点击行切换受试者', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            obj.LeftHintLabel.Layout.Row = 8;
            mrw.UiKit.tip(obj.LeftHintLabel, '也可用 ←/→ 方向键切换受试者（需图像窗口获得焦点）。');
        end

        function buildCenter(obj)
            c = obj.Colors;
            f = obj.Fonts;
            minusChar = char(65293);   % 全角减号 －

            p = uipanel(obj.MainGrid, 'Title', '图像（Image · 单视图 / 三正交 / 多切片网格）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            p.Layout.Row = 1;
            p.Layout.Column = 2;
            obj.CenterPanel = p;

            % 行：标题 / 视图区 / 切片 / 缩放 / 窗宽 / 显示工具 / 坐标读数
            g = uigridlayout(p, [7 1]);
            g.RowHeight = {24, '1x', 30, 30, 30, 34, 24};
            g.ColumnWidth = {'1x'};
            g.Padding = [6 6 6 6];
            g.RowSpacing = 4;
            g.BackgroundColor = c.panel;
            obj.CenterGrid = g;

            % 图像标题（受试者 · 模态 | 文件 · 切片）
            tg = uigridlayout(g, [1 2]);
            tg.RowHeight = {'1x'};
            tg.ColumnWidth = {'1x', 340};
            tg.Padding = [0 0 0 0];
            tg.ColumnSpacing = 6;
            tg.BackgroundColor = c.panel;
            tg.Layout.Row = 1;
            obj.SubjectTitleLabel = uilabel(tg, 'Text', '未选择受试者', ...
                'FontName', f.name, 'FontSize', f.base, 'FontWeight', 'bold', ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(obj.SubjectTitleLabel, '当前受试者与模态（例如 Sub01 · T1 原始像）。');
            obj.FileTitleLabel = uilabel(tg, 'Text', '', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'HorizontalAlignment', 'right', 'BackgroundColor', c.panel);
            obj.FileTitleLabel.Layout.Column = 2;
            mrw.UiKit.tip(obj.FileTitleLabel, '当前显示文件、切片位置（如 Axial z=31/61）、视图模式以及是否叠加模板轮廓。');

            % ---- 视图区容器：单视图 / 三正交 / 多切片（3 行互斥，避免重叠布局） ----
            obj.ViewHost = uigridlayout(g, [3 1]);
            obj.ViewHost.RowHeight = {'1x', 0, 0};
            obj.ViewHost.ColumnWidth = {'1x'};
            obj.ViewHost.Padding = [0 0 0 0];
            obj.ViewHost.RowSpacing = 0;
            obj.ViewHost.ColumnSpacing = 0;
            obj.ViewHost.BackgroundColor = c.panel;
            obj.ViewHost.Layout.Row = 2;
            obj.ViewHost.Tag = 'qcViewHost';

            obj.SingleViewGrid = uigridlayout(obj.ViewHost, [1 1]);
            obj.SingleViewGrid.RowHeight = {'1x'};
            obj.SingleViewGrid.ColumnWidth = {'1x'};
            obj.SingleViewGrid.Padding = [0 0 0 0];
            obj.SingleViewGrid.BackgroundColor = c.panel;
            obj.SingleViewGrid.Layout.Row = 1;
            obj.SingleViewGrid.Tag = 'qcSingleView';

            obj.Axes = uiaxes(obj.SingleViewGrid);
            obj.Axes.Tag = 'qcImageAxes';
            obj.configureAxes();
            mrw.UiKit.tip(obj.Axes, ['图像查看区：滚轮缩放（ZoomInteraction）、拖拽平移（PanInteraction）；' newline ...
                '也可用下方 [－][1:1][＋][适应] 按钮，倍数标签实时显示相对适应窗口的比例。' newline ...
                '↑/↓ 切换切片（需图像窗口获得焦点）；三正交/多切片视图用顶部「视图模式」切换。']);

            % 切片行：方向 + 滑条 + 序号
            sg = uigridlayout(g, [1 5]);
            sg.RowHeight = {'1x'};
            sg.ColumnWidth = {36, 112, '1x', 58, 56};
            sg.Padding = [0 0 0 0];
            sg.ColumnSpacing = 6;
            sg.BackgroundColor = c.panel;
            sg.Layout.Row = 3;
            lbl = uilabel(sg, 'Text', '方向', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lbl, '切片方向：横断位 Axial / 冠状位 Coronal / 矢状位 Sagittal。');
            obj.OrientationDropdown = uidropdown(sg, ...
                'Items', {'横断位 Axial', '冠状位 Coronal', '矢状位 Sagittal'}, ...
                'ItemsData', {'axial', 'coronal', 'sagittal'}, 'Value', 'axial', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcOrientation', ...
                'ValueChangedFcn', @(s, e) obj.onOrientationChanged());
            obj.OrientationDropdown.Layout.Column = 2;
            mrw.UiKit.tip(obj.OrientationDropdown, '切换切片方向；切片序号会自动 clamp 到新方向的有效范围。');

            obj.SliceSlider = uislider(sg, 'Limits', [1 60], 'Value', 30, ...
                'MajorTicks', [], 'MinorTicks', [], 'Tag', 'qcSliceSlider', ...
                'ValueChangingFcn', @(s, e) obj.onSliceSliderChanging(e), ...
                'ValueChangedFcn', @(s, e) obj.onSliceSliderChanged(e));
            obj.SliceSlider.Layout.Column = 3;
            mrw.UiKit.tip(obj.SliceSlider, '拖动切换切片（也可用 ↑/↓ 方向键）；序号从 1 开始。');

            obj.SliceField = uieditfield(sg, 'numeric', 'Value', 1, ...
                'Limits', [1 10000], 'RoundFractionalValues', 'on', ...
                'ValueDisplayFormat', '%.0f', 'FontName', f.name, ...
                'FontSize', f.small, 'Tag', 'qcSliceField', ...
                'ValueChangedFcn', @(s, e) obj.onSliceFieldChanged());
            obj.SliceField.Layout.Column = 4;
            mrw.UiKit.tip(obj.SliceField, '直接输入切片序号（从 1 开始，越界自动 clamp）。');

            obj.SliceCountLabel = uilabel(sg, 'Text', '/ 60', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel);
            obj.SliceCountLabel.Layout.Column = 5;
            mrw.UiKit.tip(obj.SliceCountLabel, '当前方向的总切片数。');

            % 缩放行：[－][1:1][＋][适应] + 倍数
            zg = uigridlayout(g, [1 6]);
            zg.RowHeight = {'1x'};
            zg.ColumnWidth = {34, 44, 34, 56, 100, '1x'};
            zg.Padding = [0 0 0 0];
            zg.ColumnSpacing = 6;
            zg.BackgroundColor = c.panel;
            zg.Layout.Row = 4;
            obj.ZoomOutButton = mrw.UiKit.button(zg, minusChar, 'Callback', @(s, e) obj.onZoomOut());
            obj.ZoomOutButton.Tag = 'qcZoomOut';
            mrw.UiKit.tip(obj.ZoomOutButton, '缩小图像（以图像中心为锚点，步进约 20%）。');
            obj.ZoomOneButton = mrw.UiKit.button(zg, '1:1', 'Callback', @(s, e) obj.onZoomOne());
            obj.ZoomOneButton.Tag = 'qcZoomOne';
            obj.ZoomOneButton.Layout.Column = 2;
            mrw.UiKit.tip(obj.ZoomOneButton, '按 1:1 像素显示（一个图像体素对应一个屏幕像素）；大图会放大、小图会缩小。');
            obj.ZoomInButton = mrw.UiKit.button(zg, '＋', 'Callback', @(s, e) obj.onZoomIn());
            obj.ZoomInButton.Tag = 'qcZoomIn';
            obj.ZoomInButton.Layout.Column = 3;
            mrw.UiKit.tip(obj.ZoomInButton, '放大活动视图（保留当前中心，步进约 25%）；Ctrl+滚轮以指针为锚点缩放。');
            obj.ZoomFitButton = mrw.UiKit.button(zg, '适应', 'Callback', @(s, e) obj.onZoomFit());
            obj.ZoomFitButton.Layout.Column = 4;
            obj.ZoomFitButton.Tag = 'qcZoomFit';
            mrw.UiKit.tip(obj.ZoomFitButton, '恢复到适应窗口：完整显示整幅切片，缩放倍数 = 1.00×。');
            obj.ZoomLabel = uilabel(zg, 'Text', '缩放 1.00×', 'FontName', f.name, ...
                'FontSize', f.small, 'FontWeight', 'bold', 'FontColor', c.accentDark, ...
                'BackgroundColor', c.panel, 'Tag', 'qcZoomLabel');
            obj.ZoomLabel.Layout.Column = 5;
            mrw.UiKit.tip(obj.ZoomLabel, '当前缩放倍数（相对适应窗口）；滚轮缩放/拖拽后实时更新。');
            obj.ZoomHintLabel = uilabel(zg, 'Text', '滚轮切层 · Ctrl+滚轮缩放 · 拖拽平移', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            obj.ZoomHintLabel.Layout.Column = 6;
            mrw.UiKit.tip(obj.ZoomHintLabel, '普通滚轮切层；Ctrl+滚轮以指针为锚点缩放；单击移动十字线；拖拽平移；双击恢复适应。三正交各视图独立缩放。');

            % 窗宽行：低/高百分位 + 当前显示范围
            wg = uigridlayout(g, [1 5]);
            wg.RowHeight = {'1x'};
            wg.ColumnWidth = {52, 56, 36, 56, '1x'};
            wg.Padding = [0 0 0 0];
            wg.ColumnSpacing = 6;
            wg.BackgroundColor = c.panel;
            wg.Layout.Row = 5;
            obj.WindowToolsGrid = wg;
            lbl = uilabel(wg, 'Text', '窗宽低', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lbl, '窗宽显示的低百分位（0-100，默认 2）：低于该百分位的灰度显示为最暗。');
            obj.WinLowField = uieditfield(wg, 'numeric', 'Value', 2, ...
                'Limits', [0 100], 'RoundFractionalValues', 'on', ...
                'ValueDisplayFormat', '%.0f', 'FontName', f.name, ...
                'FontSize', f.small, 'Tag', 'qcWinLow', ...
                'ValueChangedFcn', @(s, e) obj.onWindowFieldChanged());
            obj.WinLowField.Layout.Column = 2;
            mrw.UiKit.tip(obj.WinLowField, '窗宽低百分位（0-100，默认 2）。减小可提高暗部对比，增大可抑制暗部噪声。');
            lbl2 = uilabel(wg, 'Text', '高', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            lbl2.Layout.Column = 3;
            mrw.UiKit.tip(lbl2, '窗宽显示的高百分位（0-100，默认 98）：高于该百分位的灰度显示为最亮。');
            obj.WinHighField = uieditfield(wg, 'numeric', 'Value', 98, ...
                'Limits', [0 100], 'RoundFractionalValues', 'on', ...
                'ValueDisplayFormat', '%.0f', 'FontName', f.name, ...
                'FontSize', f.small, 'Tag', 'qcWinHigh', ...
                'ValueChangedFcn', @(s, e) obj.onWindowFieldChanged());
            obj.WinHighField.Layout.Column = 4;
            mrw.UiKit.tip(obj.WinHighField, '窗宽高百分位（0-100，默认 98）。增大可显示更亮的结构，减小可提高高信号对比。');
            obj.ClimLabel = uilabel(wg, 'Text', '显示范围 —', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel, ...
                'Tag', 'qcClimLabel');
            obj.ClimLabel.Layout.Column = 5;
            mrw.UiKit.tip(obj.ClimLabel, '由百分位换算出的实际显示灰度范围（窗宽窗位）。');

            % v2：显示工具行（色阶 / 插值 / 十字线 / 方位校准 / 重置方位）
            dg = uigridlayout(g, [1 9]);
            dg.RowHeight = {'1x'};
            dg.ColumnWidth = {34, 92, 34, 96, 112, 96, 92, '1x', 0};
            dg.Padding = [0 0 0 0];
            dg.ColumnSpacing = 5;
            dg.BackgroundColor = c.panel;
            dg.Layout.Row = 6;
            obj.DisplayToolsGrid = dg;
            lb1 = uilabel(dg, 'Text', '色阶', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lb1, '图像色阶（灰阶 / 热色 / jet 彩色）；只影响显示，不改写图像。');
            obj.ColormapDropdown = uidropdown(dg, ...
                'Items', {'灰阶', '热色', 'jet 彩色'}, ...
                'ItemsData', {'gray', 'hot', 'jet'}, 'Value', 'gray', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcColormap', ...
                'ValueChangedFcn', @(s, e) obj.onColormapChanged());
            obj.ColormapDropdown.Layout.Column = 2;
            mrw.UiKit.tip(obj.ColormapDropdown, '图像色阶：灰阶（默认，DPABI 风格）/ 热色 / jet 彩色（便于看强度分布）。');
            lb2 = uilabel(dg, 'Text', '插值', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            lb2.Layout.Column = 3;
            mrw.UiKit.tip(lb2, '显示插值方式（线性 / 最近邻）；仅三正交、多切片和显示变换后的单视图生效。');
            obj.InterpDropdown = uidropdown(dg, ...
                'Items', {'线性插值', '最近邻'}, ...
                'ItemsData', {'linear', 'nearest'}, 'Value', 'linear', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcInterp', ...
                'ValueChangedFcn', @(s, e) obj.onInterpChanged());
            obj.InterpDropdown.Layout.Column = 4;
            mrw.UiKit.tip(obj.InterpDropdown, '显示插值：线性（平滑）或最近邻（保边界）；非 native 显示模式时生效。');
            obj.CrosshairCheck = uicheckbox(dg, 'Text', '显示十字线', ...
                'Value', true, 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'Tag', 'qcCrosshairCheck', ...
                'ValueChangedFcn', @(s, e) obj.onCrosshairChecked());
            obj.CrosshairCheck.Layout.Column = 5;
            mrw.UiKit.tip(obj.CrosshairCheck, mrw.UiKit.wrapTooltip({ ...
                '三正交视图中显示/隐藏联动十字线（X 键快捷切换）。', ...
                '十字线位置 = 当前 3D 体素位置；点击任一视图可移动十字线。'}));
            obj.AlignButton = mrw.UiKit.button(dg, '方位校准…', ...
                'Callback', @(s, e) obj.openAlignDialog());
            obj.AlignButton.Layout.Column = 6;
            obj.AlignButton.Tag = 'qcAlignButton';
            mrw.UiKit.tip(obj.AlignButton, mrw.UiKit.wrapTooltip({ ...
                '打开“方位校准”对话框：三正交下拾取 AC/PC 做 AC-PC 配平、', ...
                '以十字线设显示原点、手动平移/旋转、左右/前后/上下翻转。', ...
                '所有调整只影响显示，不改写 NIfTI/DPABI 数据。'}));
            obj.ResetAlignButton = mrw.UiKit.button(dg, '重置方位', ...
                'Callback', @(s, e) obj.onResetAlignPressed());
            obj.ResetAlignButton.Layout.Column = 7;
            obj.ResetAlignButton.Tag = 'qcResetAlign';
            mrw.UiKit.tip(obj.ResetAlignButton, '清除 AC-PC/原点/平移/旋转/翻转，恢复 native 显示（R 键快捷操作；不修改图像文件）。');
            dg.Tag = 'qcDisplayTools';
            lb1.Tag = 'qcColormapLabel';
            lb2.Tag = 'qcInterpLabel';

            % v2：坐标读数行
            obj.CoordLabel = uilabel(g, 'Text', '体素 (—, —, —) · 世界 (—, —, —) mm · 显示 (—, —, —) mm', ...
                'FontName', f.mono, 'FontSize', f.small, 'FontColor', c.accentDark, ...
                'BackgroundColor', c.panel, 'Tag', 'qcCoordLabel');
            obj.CoordLabel.Layout.Row = 7;
            mrw.UiKit.tip(obj.CoordLabel, mrw.UiKit.wrapTooltip({ ...
                '当前十字线（或单视图切片）坐标：', ...
                '体素 = 1-based 连续体素坐标 [i j k]；', ...
                '世界 = 由 hdr.mat 换算的 mm 坐标；显示 = 经 AC-PC/原点/平移旋转/翻转后的 mm 坐标。'}));
        end

        function buildRight(obj)
            c = obj.Colors;
            f = obj.Fonts;

            p = uipanel(obj.MainGrid, 'Title', '人工评分（Rating）', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            p.Layout.Row = 1;
            p.Layout.Column = 3;
            obj.RightPanel = p;

            g = uigridlayout(p, [21 1]);
            g.RowHeight = {18, 118, 14, 56, 28, 22, 2, 18, 24, 20, 22, 22, 2, 24, 26, ...
                90, 2, 18, 40, 56, 0};
            g.ColumnWidth = {'1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 6;
            g.BackgroundColor = c.panel;
            g.Scrollable = 'on';
            obj.RightGrid = g;

            obj.ScoreSubtitle = uilabel(g, 'Text', '评分（1 很差 – 5 很好）', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            obj.ScoreSubtitle.Layout.Row = 1;
            mrw.UiKit.tip(obj.ScoreSubtitle, 'DPARSF 评分语义：1 = Very Poor（很差）… 5 = Very Good（很好）。');

            obj.ScoreGroup = uibuttongroup(g, 'Title', '', 'BorderType', 'line', ...
                'HighlightColor', c.border, 'BackgroundColor', c.panelAlt);
            obj.ScoreGroup.Layout.Row = 2;
            try, obj.ScoreGroup.AutoResizeChildren = 'off'; catch, end
            try
                obj.ScoreGroup.SelectionChangedFcn = @(s, e) obj.onScoreChanged();
            catch
            end
            scoreLabels = {'1 很差（Very Poor）', '2 差（Poor）', '3 一般（Fair）', ...
                '4 好（Good）', '5 很好（Very Good）'};
            obj.ScoreRadios = cell(1, 5);
            for k = 1:5
                rb = uiradiobutton(obj.ScoreGroup, 'Text', scoreLabels{k}, ...
                    'FontName', f.name, 'FontSize', f.small, 'FontColor', c.text, ...
                    'Tag', sprintf('qcScore%d', k));
                rb.UserData = k;
                obj.ScoreRadios{k} = rb;
                mrw.UiKit.tip(rb, sprintf(['人工评分 %d 分（%s）。' newline ...
                    '评分随“保存并下一人”写入 QC/*.tsv，补评可随时修改。'], ...
                    k, scoreLabels{k}(find(scoreLabels{k} == '（', 1) + 1:end)));
            end
            try
                obj.ScoreGroup.SizeChangedFcn = @(s, e) obj.layoutScoreRadios();
            catch
            end
            obj.layoutScoreRadios();
            try, obj.ScoreGroup.SelectedObject = obj.ScoreRadios{3}; catch, end

            obj.CommentLabel = uilabel(g, 'Text', '评语（Comment）', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            obj.CommentLabel.Layout.Row = 3;
            mrw.UiKit.tip(obj.CommentLabel, '自由文本评语，写入 QC TSV 第 3 列（UTF-8，DPARSF 兼容）。');

            obj.CommentArea = uitextarea(g, 'Placeholder', '记录伪影、配准/标准化问题、处理建议…', ...
                'FontName', f.name, 'FontSize', f.small, 'Value', '', ...
                'Tag', 'qcComment');
            obj.CommentArea.Layout.Row = 4;
            mrw.UiKit.tip(obj.CommentArea, ['自由评语：记录头动伪影、配准/标准化问题、建议等。' newline ...
                '保存时随评分写入 QC/*.tsv 的 QC Comment 列。']);

            obj.SaveButton = mrw.UiKit.button(g, '保存并下一人（Save & Next）', ...
                'kind', 'primary', 'Callback', @(s, e) obj.onSavePressed());
            obj.SaveButton.Layout.Row = 5;
            obj.SaveButton.Tag = 'qcSaveButton';
            mrw.UiKit.tip(obj.SaveButton, '保存当前受试者的评分与评语到 QC TSV，并自动切换到下一位受试者。');

            obj.SkipButton = mrw.UiKit.button(g, '跳过（Skip）', 'Callback', @(s, e) obj.onSkipPressed());
            obj.SkipButton.Layout.Row = 6;
            obj.SkipButton.Tag = 'qcSkipButton';
            mrw.UiKit.tip(obj.SkipButton, '跳过当前受试者（不写入评分），切换到下一位；之后可再回来补评。');

            sep1 = uipanel(g, 'BorderType', 'none', 'BackgroundColor', c.border);
            sep1.Layout.Row = 7;

            obj.DisplayHeading = uilabel(g, 'Text', '显示设置（Display）', ...
                'FontName', f.name, 'FontSize', f.small, 'FontWeight', 'bold', ...
                'FontColor', c.accentDark, 'BackgroundColor', c.panel);
            obj.DisplayHeading.Layout.Row = 8;
            mrw.UiKit.tip(obj.DisplayHeading, '窗宽自动、视图重置、标准化模板轮廓与透明度等显示选项。');

            dg = uigridlayout(g, [1 2]);
            dg.RowHeight = {'1x'};
            dg.ColumnWidth = {'1x', '1x'};
            dg.Padding = [0 0 0 0];
            dg.ColumnSpacing = 6;
            dg.BackgroundColor = c.panel;
            dg.Layout.Row = 9;
            obj.AutoWindowButton = mrw.UiKit.button(dg, '自动窗宽', 'Callback', @(s, e) obj.onAutoWindow());
            obj.AutoWindowButton.Tag = 'qcAutoWindow';
            mrw.UiKit.tip(obj.AutoWindowButton, ['自动窗宽：按当前切片最小-最大灰度显示' newline ...
                '（低/高百分位 = 0/100），用于快速查看完整动态范围。']);
            obj.ResetViewButton = mrw.UiKit.button(dg, '重置视图', 'Callback', @(s, e) obj.onResetView());
            obj.ResetViewButton.Layout.Column = 2;
            obj.ResetViewButton.Tag = 'qcResetView';
            mrw.UiKit.tip(obj.ResetViewButton, '重置方向（横断位）、切片（中间层）与缩放（适应窗口）。');

            obj.OverlayCheck = uicheckbox(g, 'Text', '叠加 MNI 模板轮廓（Overlay）', ...
                'Value', true, 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'Tag', 'qcOverlayCheck', ...
                'ValueChangedFcn', @(s, e) obj.onOverlayChecked());
            obj.OverlayCheck.Layout.Row = 10;
            mrw.UiKit.tip(obj.OverlayCheck, ['叠加 DPABI 的 MNI 边缘模板轮廓（黄色高亮），用于检查标准化效果。' newline ...
                '仅“标准化检查”模态可用，默认开启。']);

            ag = uigridlayout(g, [1 2]);
            ag.RowHeight = {'1x'};
            ag.ColumnWidth = {60, '1x'};
            ag.Padding = [0 0 0 0];
            ag.ColumnSpacing = 6;
            ag.BackgroundColor = c.panel;
            ag.Layout.Row = 11;
            obj.OverlayAlphaLabel = uilabel(ag, 'Text', '透明度', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(obj.OverlayAlphaLabel, '模板轮廓透明度：0 = 完全透明，1 = 完全不透明（可拖动滑条调节）。');
            obj.OverlayAlphaSlider = uislider(ag, 'Limits', [0 1], 'Value', 0.55, ...
                'MajorTicks', [], 'MinorTicks', [], 'Tag', 'qcOverlayAlpha', ...
                'ValueChangingFcn', @(s, e) obj.onOverlayAlphaChanging(e), ...
                'ValueChangedFcn', @(s, e) obj.onOverlayAlphaChanging(e));
            obj.OverlayAlphaSlider.Layout.Column = 2;
            mrw.UiKit.tip(obj.OverlayAlphaSlider, '模板轮廓透明度（0–1）；建议 0.4–0.7 便于同时观察图像与轮廓。');

            obj.NormKindDropdown = uidropdown(g, ...
                'Items', {'功能像 wFun', 'T1 结构像 wT1', '灰质 wGM'}, ...
                'ItemsData', {'Fun', 'T1', 'GM'}, 'Value', 'Fun', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcNormKind', ...
                'ValueChangedFcn', @(s, e) obj.onNormKindChanged());
            obj.NormKindDropdown.Layout.Row = 12;
            mrw.UiKit.tip(obj.NormKindDropdown, ['标准化子图类型：' newline ...
                'wFun = RealignParameter/wmean*（功能像）；wT1 = T1ImgNewSegment/w*（结构像）；' newline ...
                'wGM = T1ImgNewSegment/wc1*（灰质分割）。分别对应 DPABI 标准化 QC 的三类图。']);

            sep2 = uipanel(g, 'BorderType', 'none', 'BackgroundColor', c.border);
            sep2.Layout.Row = 13;

            obj.MeanFDLabel = uilabel(g, 'Text', 'Mean FD：无数据', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel, ...
                'Tag', 'qcMeanFD');
            obj.MeanFDLabel.Layout.Row = 14;
            mrw.UiKit.tip(obj.MeanFDLabel, ['当前受试者平均帧位移 Mean FD（RealignParameter/HeadMotion.tsv 第 21 列）。' newline ...
                '超过阈值（默认 0.2 mm）时红色提示复核。']);

            obj.ProgressLabel = uilabel(g, 'Text', '尚未评分（选择 1–5 分后保存）', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel, 'Tag', 'qcRatingProgress');
            obj.ProgressLabel.Layout.Row = 15;
            mrw.UiKit.tip(obj.ProgressLabel, '当前模态已评分人数/总人数与平均分。');

            % v2：方位校准摘要（只读，显示 AC-PC / 显示变换状态）
            sep3 = uipanel(g, 'BorderType', 'none', 'BackgroundColor', c.border);
            sep3.Layout.Row = 17;
            obj.AlignHeading = uilabel(g, 'Text', '方位与显示变换（Align）', ...
                'FontName', f.name, 'FontSize', f.small, 'FontWeight', 'bold', ...
                'FontColor', c.accentDark, 'BackgroundColor', c.panel);
            obj.AlignHeading.Layout.Row = 18;
            mrw.UiKit.tip(obj.AlignHeading, mrw.UiKit.wrapTooltip({ ...
                '当前显示方位状态（只读）：显示模式 / AC-PC 距离与角度 / 平移旋转 / 翻转。', ...
                '点击评分栏“方位校准…”打开对话框调整；所有调整只影响显示。'}));
            obj.AlignSummaryLabel = uilabel(g, 'Text', '显示模式：native · 未做 AC-PC 配平', ...
                'FontName', f.mono, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel, 'Tag', 'qcAlignSummary', ...
                'VerticalAlignment', 'top');
            obj.AlignSummaryLabel.Layout.Row = 19;
            try, obj.AlignSummaryLabel.WordWrap = 'on'; catch, end
            mrw.UiKit.tip(obj.AlignSummaryLabel, '只读摘要：显示模式、AC/PC 坐标、AC-PC 距离/角度、平移(mm)/旋转(度) 与翻转状态。');

            % 低频显示设置使用评分栏的可滚动空间，不再压低图像绘图区。
            dg = obj.DisplayToolsGrid;
            dg.Parent = g; dg.Layout.Row = 16; dg.Layout.Column = 1;
            dg.RowHeight = {28, 26, 28}; dg.RowSpacing = 4;
            obj.CrosshairCheck.Layout.Row = 2; obj.CrosshairCheck.Layout.Column = [1 4];
            obj.AlignButton.Layout.Row = 3; obj.AlignButton.Layout.Column = [1 2];
            obj.ResetAlignButton.Layout.Row = 3; obj.ResetAlignButton.Layout.Column = [3 4];
            dg.ColumnWidth = {34, '1x', 34, '1x'};
            wg = obj.WindowToolsGrid;
            wg.Parent = g; wg.Layout.Row = 20; wg.Layout.Column = 1;
            wg.RowHeight = {28, 20}; wg.RowSpacing = 4;
            obj.ClimLabel.Layout.Row = 2; obj.ClimLabel.Layout.Column = [1 4];
            wg.ColumnWidth = {52, 56, 36, '1x'};
            rh = obj.CenterGrid.RowHeight; rh{5} = 0; rh{6} = 0;
            obj.CenterGrid.RowHeight = rh;
        end

        function buildFooter(obj)
            c = obj.Colors;
            f = obj.Fonts;

            fp = uipanel(obj.Root, 'BorderType', 'none', 'BackgroundColor', c.bg);
            fp.Layout.Row = 4;
            obj.FooterPanel = fp;

            g = uigridlayout(fp, [1 3]);
            g.RowHeight = {'1x'};
            g.ColumnWidth = {'1x', 420, 180};
            g.Padding = [4 0 4 0];
            g.ColumnSpacing = 10;
            g.BackgroundColor = c.bg;
            obj.FooterGrid = g;

            obj.FooterProgressLabel = uilabel(g, 'Text', '评分进度（Progress）：—', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.bg, 'Tag', 'qcFooterProgress');
            obj.FooterProgressLabel.Layout.Column = 1;
            mrw.UiKit.tip(obj.FooterProgressLabel, '三个模态的评分进度汇总（T1 / 功能 / 标准化），来自 QC TSV。');

            obj.MessageLabel = uilabel(g, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.accentDark, ...
                'BackgroundColor', c.bg, 'Tag', 'qcMessage');
            obj.MessageLabel.Layout.Column = 2;
            mrw.UiKit.tip(obj.MessageLabel, '最近一次操作的状态提示（保存/导出/错误原因等）。');

            obj.VersionLabel = uilabel(g, 'Text', ['QcPanel v' obj.Version], ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'HorizontalAlignment', 'right', 'BackgroundColor', c.bg);
            obj.VersionLabel.Layout.Column = 3;
            mrw.UiKit.tip(obj.VersionLabel, 'QcPanel 版本号（可缩放人工 QC UI 组件）。');
        end

        function configureAxes(obj)
            c = obj.Colors;
            f = obj.Fonts;
            ax = obj.Axes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            try, ax.Color = [0.078 0.086 0.106]; catch, end
            try, ax.XColor = c.border; ax.YColor = c.border; catch, end
            try, ax.XTick = []; ax.YTick = []; catch, end
            try, ax.Box = 'on'; catch, end
            try, ax.FontName = f.name; ax.FontSize = f.small; catch, end
            try, ax.Toolbar.Visible = 'off'; catch, end
            try, ax.LooseInset = [0 0 0 0]; catch, end
            try
                ax.XLimMode = 'manual';
                ax.YLimMode = 'manual';
                ax.DataAspectRatio = [1 1 1];
                ax.DataAspectRatioMode = 'manual';
            catch
            end
            % 统一 figure 回调，避免默认滚轮缩放抢占切层事件。
            try, disableDefaultInteractivity(ax); catch, end
            try, ax.Interactions = []; catch, end
            % 交互（滚轮/拖拽）改变范围后同步倍数标签
            try
                obj.LimListenerX = addlistener(ax, 'XLim', 'PostSet', @(s, e) obj.onAxesLimPostSet());
                obj.LimListenerY = addlistener(ax, 'YLim', 'PostSet', @(s, e) obj.onAxesLimPostSet());
            catch
            end
        end
    end

    % ==================================================================
    %  数据发现 / 刷新 / 受试者选择
    % ==================================================================
    methods (Access = private)

        function doRefresh(obj, resetZoom)
            if nargin < 2
                resetZoom = false;
            end
            obj.Discover = [];
            obj.ModelProgress = [];
            if isempty(obj.WorkDir)
                obj.applyEmptyState('尚未选择工作目录。请点击「浏览…」选择 DPARSF 预处理工作目录（含 T1Img / RealignParameter 等）。');
                return;
            end

            obj.Discover = obj.modelCall('discover', obj.WorkDir);
            discoverErr = obj.LastModelError;
            thr = obj.modelCall('loadThresholds', obj.WorkDir);
            obj.Thresholds = obj.mergeThresholds(thr);
            hm = obj.modelCall('loadHeadMotion', obj.WorkDir);
            if isstruct(hm) && isfield(hm, 'Available')
                obj.HeadMotion = hm;
            else
                obj.HeadMotion = struct('Available', false, 'IDs', {{}}, 'MeanFD', [], 'MaxTrans', [], 'Message', '');
            end
            obj.ModelProgress = obj.modelCall('progress', obj.WorkDir);

            if isempty(obj.Discover) || ~isstruct(obj.Discover) || ~isOkStruct(obj.Discover)
                msg = '';
                if isstruct(obj.Discover) && isfield(obj.Discover, 'Message') && ...
                        ischar(obj.Discover.Message) && ~isempty(obj.Discover.Message)
                    msg = obj.Discover.Message;
                elseif ~isempty(discoverErr)
                    msg = sprintf('数据模型 mrw.QcModel 不可用：%s', discoverErr);
                elseif exist(obj.WorkDir, 'dir') ~= 7
                    msg = sprintf('工作目录不存在：%s', obj.WorkDir);
                else
                    msg = '工作目录中未发现可用 QC 数据（T1Img / RealignParameter / T1ImgNewSegment）。';
                end
                obj.applyEmptyState(msg);
                return;
            end

            % 当前模态不可用则自动切到第一个可用模态
            avail = obj.availableModalityKeys();
            if ~isempty(avail) && ~any(strcmp(avail, obj.ModalityKey))
                obj.ModalityKey = avail{1};
            end
            obj.refreshModalityDropdown();
            obj.SubjectList = obj.normalizeSubjects(obj.modelCall('subjects', obj.WorkDir, obj.ModalityKey));
            obj.Scores = obj.normalizeScores(obj.modelCall('loadScores', obj.WorkDir, obj.ModalityKey));

            if isempty(obj.SubjectList)
                obj.applyEmptyState(sprintf('%s：没有找到可用受试者（检查 QC 目录结构或图像文件）。', obj.modalityLabel()));
                return;
            end

            obj.rebuildFilteredIndices();
            obj.rebuildTable();

            % 尽量保持当前受试者（切换模态时同名受试者仍选中）
            keepID = obj.SubjectID;
            target = 0;
            if ~isempty(keepID)
                ids = obj.subjectIDs();
                k = find(strcmp(ids, keepID), 1);
                if ~isempty(k)
                    target = k;
                end
            end
            if target < 1
                if ~isempty(obj.FilteredIdx)
                    target = obj.FilteredIdx(1);
                else
                    target = 1;
                end
            elseif isempty(obj.FilteredIdx) || isempty(find(obj.FilteredIdx == target, 1))
                if ~isempty(obj.FilteredIdx)
                    target = obj.FilteredIdx(1);
                else
                    target = 1;
                end
            end
            obj.selectSubjectIndex(target, resetZoom);
            obj.updateProgressUI();
            obj.updateMeanFDUi();
            obj.updateAvailabilityUI();
            obj.setMessage(sprintf('已加载 %d 名受试者（%s）', numel(obj.SubjectList), obj.modalityLabel()));
            obj.updateFooter();
            obj.notifyChangedIfReady();
        end

        function applyEmptyState(obj, msg)
            obj.SubjectList = {};
            obj.FilteredIdx = [];
            obj.Scores = struct('ID', {}, 'Score', {}, 'Comment', {});
            obj.SubjectIndex = 0;
            obj.SubjectID = '';
            obj.SliceIndex = 0;
            obj.SliceCount = 0;
            obj.Zoom = 1;
            obj.CurrentSliceLabel = '';
            obj.refreshModalityDropdown();
            obj.rebuildTable();
            obj.updateTableSelection();
            obj.showPlaceholder(msg);
            try
                obj.SubjectTitleLabel.Text = '未选择受试者';
                obj.FileTitleLabel.Text = '';
            catch
            end
            obj.updateScoreUI();
            obj.updateMeanFDUi();
            obj.updateAvailabilityUI();
            obj.updateProgressUI();
            obj.updateProgressLabelEmpty();
            obj.CrosshairVoxel = [];
            obj.ViewKey = '';
            obj.Fd = fdBaseStruct(obj.FdType, obj.FdThreshold);
            obj.updateFdCurve();
            obj.refreshSecondaryViews();
            obj.setControlsEnabled(false);
            obj.Message = msg;
            obj.updateFooter();
            obj.notifyChangedIfReady();
        end

        function refreshModalityDropdown(obj)
            keys = {'T1', 'Fun', 'Norm'};
            baseLabels = {'T1 原始像', '功能平均像', '标准化检查'};
            labels = baseLabels;
            if isstruct(obj.Discover) && isfield(obj.Discover, 'Modalities')
                avail = obj.availableModalityKeys();
                for i = 1:numel(keys)
                    if ~any(strcmp(avail, keys{i}))
                        labels{i} = [baseLabels{i} '（无数据）'];
                    end
                end
            end
            try
                obj.ModalityDropdown.Items = labels;
                obj.ModalityDropdown.ItemsData = keys;
                obj.ModalityDropdown.Value = obj.ModalityKey;
            catch
            end
        end

        function keys = availableModalityKeys(obj)
            keys = {};
            if ~isstruct(obj.Discover) || ~isfield(obj.Discover, 'Modalities') || ~isstruct(obj.Discover.Modalities)
                return;
            end
            M = obj.Discover.Modalities;
            for i = 1:numel(M)
                if isfield(M(i), 'Key') && isfield(M(i), 'Available') && logical(fieldOr(M(i), 'Available', false))
                    k = normalizeModalityKey(M(i).Key);
                    if ~isempty(k)
                        keys{end+1} = k; %#ok<AGROW>
                    end
                end
            end
        end

        function subjects = normalizeSubjects(~, S)
            subjects = {};
            if isempty(S) || ~isstruct(S)
                return;
            end
            for i = 1:numel(S)
                rec = S(i);
                id = fieldOr(rec, 'ID', '');
                if ~ischar(id) || isempty(id)
                    id = sprintf('Subject%02d', i);
                end
                tf = true;
                if isfield(rec, 'Available')
                    tf = logical(fieldOr(rec, 'Available', true));
                end
                file = fieldOr(rec, 'File', '');
                if ~ischar(file), file = ''; end
                kind = fieldOr(rec, 'FileKind', '');
                if ~ischar(kind), kind = ''; end
                msg = fieldOr(rec, 'Message', '');
                if ~ischar(msg), msg = ''; end
                cands = {};
                if isfield(rec, 'Candidates') && ~isempty(rec.Candidates)
                    cset = rec.Candidates;
                    if isstruct(cset)
                        for j = 1:numel(cset)
                            w = fieldOr(cset(j), 'Which', '');
                            fp = fieldOr(cset(j), 'File', '');
                            if ischar(w) && ~isempty(w)
                                cands{end+1} = struct('Which', w, 'File', char(fp)); %#ok<AGROW>
                            end
                        end
                    elseif iscell(cset)
                        for j = 1:numel(cset)
                            if isstruct(cset{j})
                                w = fieldOr(cset{j}, 'Which', '');
                                fp = fieldOr(cset{j}, 'File', '');
                                if ischar(w) && ~isempty(w)
                                    cands{end+1} = struct('Which', w, 'File', char(fp)); %#ok<AGROW>
                                end
                            end
                        end
                    end
                end
                if isempty(cands) && ~isempty(kind)
                    switch kind
                        case 'NormFun'
                            cands = {struct('Which', 'Fun', 'File', file)};
                        case 'NormT1'
                            cands = {struct('Which', 'T1', 'File', file)};
                        case 'NormGM'
                            cands = {struct('Which', 'GM', 'File', file)};
                    end
                end
                subjects{end+1} = struct('ID', id, 'Available', tf, 'File', file, ...
                    'FileKind', kind, 'Message', msg, 'Candidates', {cands}); %#ok<AGROW>
            end
        end

        function sc = normalizeScores(~, S)
            sc = struct('ID', {}, 'Score', {}, 'Comment', {});
            if isempty(S) || ~isstruct(S)
                return;
            end
            for i = 1:numel(S)
                rec = S(i);
                id = fieldOr(rec, 'ID', '');
                if ~ischar(id) || isempty(id), continue; end
                v = NaN;
                if isfield(rec, 'Score') && isnumeric(rec.Score) && isscalar(rec.Score) && isfinite(rec.Score)
                    v = double(rec.Score);
                end
                cm = fieldOr(rec, 'Comment', '');
                if ~ischar(cm), cm = ''; end
                sc(end+1) = struct('ID', id, 'Score', v, 'Comment', cm); %#ok<AGROW>
            end
        end

        function thr = mergeThresholds(~, t)
            thr = struct('T1Min', 3, 'FunMin', 3, 'NormMin', 3, ...
                'UseT1', true, 'UseFun', true, 'UseNorm', true, ...
                'MaxMeanFD', 0.2, 'UseMeanFD', false);
            if ~isstruct(t)
                return;
            end
            f = fieldnames(thr);
            for i = 1:numel(f)
                if isfield(t, f{i}) && ~isempty(t.(f{i}))
                    try, thr.(f{i}) = t.(f{i}); catch, end
                end
            end
        end

        function ids = subjectIDs(obj)
            n = numel(obj.SubjectList);
            ids = cell(1, n);
            for i = 1:n
                ids{i} = obj.SubjectList{i}.ID;
            end
        end

        function s = currentSubject(obj)
            s = [];
            if obj.SubjectIndex >= 1 && obj.SubjectIndex <= numel(obj.SubjectList)
                s = obj.SubjectList{obj.SubjectIndex};
            end
        end

        function cands = normCandidates(obj, s)
            cands = {};
            if isempty(s), return; end
            if isfield(s, 'Candidates') && ~isempty(s.Candidates)
                cands = s.Candidates;
            end
            if isempty(cands) && isfield(s, 'FileKind') && ~isempty(s.FileKind)
                switch s.FileKind
                    case 'NormFun', cands = {struct('Which', 'Fun', 'File', s.File)};
                    case 'NormT1',  cands = {struct('Which', 'T1', 'File', s.File)};
                    case 'NormGM',  cands = {struct('Which', 'GM', 'File', s.File)};
                end
            end
        end

        function file = currentFile(obj)
            file = '';
            s = obj.currentSubject();
            if isempty(s), return; end
            if strcmp(obj.ModalityKey, 'Norm')
                cands = obj.normCandidates(s);
                for i = 1:numel(cands)
                    if strcmp(cands{i}.Which, obj.NormKind)
                        file = cands{i}.File;
                        break;
                    end
                end
                if isempty(file) && ~isempty(cands)
                    file = cands{1}.File;
                end
            else
                if isfield(s, 'File')
                    file = s.File;
                end
            end
            if ~ischar(file), file = ''; end
        end

        function selectSubjectIndex(obj, idx, resetZoom)
            if nargin < 3
                resetZoom = true;
            end
            if idx < 1 || idx > numel(obj.SubjectList)
                return;
            end
            obj.SubjectIndex = idx;
            s = obj.SubjectList{idx};
            obj.SubjectID = s.ID;
            obj.SliceIndex = 0;      % 0 => loadCurrentSlice 取中间层
            if resetZoom
                obj.Zoom = 1;
            end
            obj.ViewKey = '';        % 体数据变化：让 mrw.QcView 重建
            obj.CrosshairVoxel = [];
            obj.updateScoreUI();
            obj.loadCurrentSlice(resetZoom);
            obj.rebuildTable();
            obj.updateTableSelection();
            obj.updateFdCurve();
        end

        function rebuildFilteredIndices(obj)
            n = numel(obj.SubjectList);
            if n < 1
                obj.FilteredIdx = [];
                return;
            end
            mask = obj.filterMask();
            idx = find(mask);
            idx = obj.sortFilteredIndices(idx);
            obj.FilteredIdx = idx(:);
        end
    end

    % ==================================================================
    %  图像加载与绘制
    % ==================================================================
    methods (Access = private)

        function clearCache(obj)
            obj.EdgeCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            try
                if ~isempty(obj.CacheMap)
                    remove(obj.CacheMap, obj.CacheMap.keys());
                end
            catch
            end
            obj.CacheOrder = {};
        end

        function [vol, hdr, info] = getVolume(obj, file)
            vol = [];
            hdr = struct();
            info = struct();
            if isempty(file)
                return;
            end
            key = [obj.ModalityKey '|' char(file)];
            try
                if ~isempty(obj.CacheMap) && isKey(obj.CacheMap, key)
                    v = obj.CacheMap(key);
                    vol = v.Vol;
                    hdr = v.Hdr;
                    info = v.Info;
                    return;
                end
            catch
            end
            [vol, hdr, info] = obj.modelCall('loadVolume', file);
            if isempty(vol)
                return;
            end
            if ~isstruct(hdr), hdr = struct(); end
            if ~isstruct(info), info = struct(); end
            try
                obj.CacheMap(key) = struct('Vol', vol, 'Hdr', hdr, 'Info', info);
                obj.CacheOrder{end+1} = key; %#ok<AGROW>
                while numel(obj.CacheOrder) > 3
                    old = obj.CacheOrder{1};
                    obj.CacheOrder(1) = [];
                    if isKey(obj.CacheMap, old)
                        remove(obj.CacheMap, old);
                    end
                end
            catch
            end
        end

        function n = sliceCountForVolume(obj, vol)
            d = size(vol);
            switch obj.Orientation
                case 'coronal'
                    n = d(2);
                case 'sagittal'
                    n = d(1);
                otherwise
                    n = d(3);
            end
            if isempty(n) || ~isfinite(n) || n < 1
                n = 1;
            end
        end

        function loadCurrentSlice(obj, resetZoom)
            if nargin < 2
                resetZoom = false;
            end
            s = obj.currentSubject();
            if isempty(s)
                obj.showPlaceholder('未选择受试者');
                return;
            end
            file = obj.currentFile();
            if isempty(file)
                obj.showPlaceholder(sprintf('%s：该受试者没有可用图像文件', obj.SubjectID));
                return;
            end
            [vol, hdr, info] = obj.getVolume(file);
            if isempty(vol)
                msg = '读取图像失败';
                if isstruct(info) && isfield(info, 'Message') && ischar(info.Message) && ~isempty(info.Message)
                    msg = sprintf('读取图像失败：%s', info.Message);
                elseif ~isempty(obj.LastModelError)
                    msg = sprintf('读取图像失败：%s', obj.LastModelError);
                end
                obj.showPlaceholder(msg);
                return;
            end
            useEngine = obj.ensureView();
            obj.SliceCount = max(1, obj.sliceCountForVolume(vol));
            if useEngine
                obj.SliceCount = obj.viewSliceCount(obj.Orientation);
            end
            req = obj.SliceIndex;
            if req < 1 || req > obj.SliceCount
                req = max(1, round(obj.SliceCount / 2));
            end
            plane = struct();
            if useEngine
                obj.View.setSliceIndex(obj.Orientation, req);
                obj.CrosshairVoxel = double(obj.View.getCrosshair());
                [im, plane] = obj.View.slice(obj.Orientation, req);
                sl = struct('Image', im, 'SliceIndex', plane.SliceIndex, ...
                    'SliceCount', plane.SliceCount, 'SliceLabel', plane.SliceLabel);
            else
                sl = obj.modelCall('makeSlice', vol, obj.Orientation, req);
            end
            if isempty(sl) || ~isstruct(sl) || ~isfield(sl, 'Image') || isempty(sl.Image)
                obj.showPlaceholder('切片生成失败（makeSlice 返回空）');
                return;
            end
            img = double(sl.Image);
            if ndims(img) > 2
                img = img(:, :, 1);
            end
            obj.SliceIndex = max(1, round(double(fieldOr(sl, 'SliceIndex', req))));
            obj.SliceCount = max(1, round(double(fieldOr(sl, 'SliceCount', obj.SliceCount))));
            obj.CurrentSliceLabel = fieldOr(sl, 'SliceLabel', ...
                sprintf('%s %d/%d', obj.orientationLabel(), obj.SliceIndex, obj.SliceCount));
            if ~ischar(obj.CurrentSliceLabel), obj.CurrentSliceLabel = ''; end
            obj.CurrentImage = img;
            sd = size(img);
            obj.ImageSize = [sd(1) sd(2)];
            obj.SingleInfo = plane;
            edge = [];
            if strcmp(obj.ModalityKey, 'Norm') && obj.OverlayVisible
                edge = obj.edgeFor(hdr, vol, img);
            end
            obj.CurrentEdge = edge;
            obj.drawImage(img, edge);
            obj.updateImageTitle(file);
            obj.syncSliceUI();
            obj.setControlsEnabled(true);
            if resetZoom
                obj.applyZoom(1);
            else
                obj.Zoom = obj.computeZoomFactor();
                obj.syncZoomUI();
            end
            if strcmp(obj.ViewMode, 'single')
                % 单视图切片变化时同步显示引擎十字线（保证状态 JSON 十字线与画面一致）
                try
                    if obj.ensureView()
                        obj.View.setSliceIndex(obj.Orientation, max(1, round(obj.SliceIndex)));
                        q = obj.View.getCrosshair();
                        if isnumeric(q) && numel(q) >= 3 && all(isfinite(double(q(1:3))))
                            obj.CrosshairVoxel = double(q(1:3));
                        end
                    end
                catch
                end
            end
            obj.refreshSecondaryViews();
        end

        function edge = edgeFor(obj, hdr, vol, img)
            sz = size(img);
            edge = [];
            if ~isempty(fieldnames(obj.SingleInfo)) && obj.ensureView()
                % 复用模型的模板缓存，把显示平面转成虚拟 axial 体素网格后采样。
                plane = obj.View.planeInfo(obj.Orientation);
                vi = obj.View.getInfo();
                T = plane.PixelToDisplay;
                W = vi.DisplayMatrix \ [T; 0 0 1];
                key = [obj.ViewKey '|' sprintf('%.12g,', [W(:); sz(:)])];
                if isKey(obj.EdgeCache, key), edge = obj.EdgeCache(key); return; end
                normal = cross(W(1:3, 1), W(1:3, 2));
                normal = normal / max(norm(normal), eps);
                ph = struct('dim', [sz(2) sz(1) 1], 'mat', ...
                    [W(1:3, 1:2), normal, W(1:3, 3) - normal; 0 0 0 1]);
                edge = obj.modelCall('edgeSliceFor', ph, 'axial', 1, [sz(2) sz(1)]);
                edge = edge.';
                if obj.EdgeCache.Count >= 96
                    keys = obj.EdgeCache.keys(); remove(obj.EdgeCache, keys{1});
                end
                obj.EdgeCache(key) = edge;
                return;
            end
            e = obj.modelCall('edgeSliceFor', hdr, obj.Orientation, obj.SliceIndex, sz);
            if isnumeric(e) && ~isempty(e) && isequal(size(e), sz)
                edge = double(e);
            end
            if isempty(edge)
                % 兼容契约中的另一种签名 edgeSliceFor(hdr, vol, orientation, sliceIndex)
                e2 = obj.modelCall('edgeSliceFor', hdr, vol, obj.Orientation, obj.SliceIndex);
                if isnumeric(e2) && ~isempty(e2) && isequal(size(e2), sz)
                    edge = double(e2);
                end
            end
            if isempty(edge)
                edge = zeros(sz);
            end
        end

        function drawImage(obj, img, edge)
            ax = obj.Axes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            obj.UpdatingAxes = true;
            oldX = ax.XLim; oldY = ax.YLim;
            oldFull = [obj.FullXLim obj.FullYLim];
            nr = size(img, 1);
            nc = size(img, 2);
            obj.ImageSize = [nr nc];
            xl = fieldAny(obj.SingleInfo, {'XLim'}, [0.5 nc + 0.5]);
            yl = fieldAny(obj.SingleInfo, {'YLim'}, [0.5 nr + 0.5]);
            obj.FullXLim = sort(xl);
            obj.FullYLim = sort(yl);
            obj.HasImage = true;
            keepLimits = isequal(oldFull, [obj.FullXLim obj.FullYLim]) && ...
                isequal(getappdata(ax, 'QcViewKey'), obj.ViewKey);
            if isempty(obj.MainImage) || ~isvalid(obj.MainImage)
                cla(ax); hold(ax, 'on');
                obj.MainImage = imagesc(ax, pixelCenters(xl, nc), pixelCenters(yl, nr), img);
                hold(ax, 'off');
            else
                obj.MainImage.CData = img;
                obj.MainImage.XData = pixelCenters(xl, nc);
                obj.MainImage.YData = pixelCenters(yl, nr);
            end
            obj.MainImage.HitTest = 'off'; obj.MainImage.PickableParts = 'none';
            try, obj.MainImage.CDataMapping = 'scaled'; catch, end
            try, colormap(ax, obj.colormapData()); catch, end
            if obj.OverlayVisible && ~isempty(edge) && any(edge(:) > 0.05)
                if isempty(obj.OverlayImage) || ~isvalid(obj.OverlayImage)
                    obj.OverlayImage = obj.addOverlayImage(edge);
                else
                    obj.OverlayImage.AlphaData = obj.OverlayAlpha * double(edge > 0.05);
                    obj.OverlayImage.XData = pixelCenters(xl, nc);
                    obj.OverlayImage.YData = pixelCenters(yl, nr);
                    if ~isequal(size(obj.OverlayImage.CData, 1), nr) || ~isequal(size(obj.OverlayImage.CData, 2), nc)
                        delete(obj.OverlayImage); obj.OverlayImage = obj.addOverlayImage(edge);
                    end
                end
            elseif ~isempty(obj.OverlayImage) && isvalid(obj.OverlayImage)
                delete(obj.OverlayImage); obj.OverlayImage = [];
            end
            try, hold(ax, 'off'); catch, end
            [lo, hi] = obj.windowLimits(img);
            obj.Clim = [lo hi];
            try, ax.CLim = [lo hi]; catch, end
            try
                obj.applyViewLimits(ax, xl, yl);
                if keepLimits, ax.XLim = oldX; ax.YLim = oldY; end
                setappdata(ax, 'QcViewKey', obj.ViewKey);
                xlabel(ax, fieldAny(obj.SingleInfo, {'XAxisLabel'}, ''), 'Color', obj.Colors.muted);
                ylabel(ax, fieldAny(obj.SingleInfo, {'YAxisLabel'}, ''), 'Color', obj.Colors.muted);
            catch
            end
            obj.UpdatingAxes = false;
            obj.drawSingleCrosshair();
            obj.syncWindowUI();
        end

        function drawSingleCrosshair(obj)
            % 单视图十字线：与三正交/多切片共享同一体素十字线（显示层）
            if ~logical(obj.CrosshairVisible) || ~obj.HasImage
                obj.clearSingleCrosshair();
                return;
            end
            ax = obj.Axes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            cp = [];
            try
                [x, y] = obj.tripleCrossPosition(tripleFieldName(obj.Orientation), obj.SingleInfo);
                cp = [x y];
            catch
                cp = [];
            end
            if isempty(cp) || any(~isfinite(cp))
                return;
            end
            try
                if numel(obj.SingleCross) == 2 && all(isvalid(obj.SingleCross))
                    obj.SingleCross(1).Value = cp(1); obj.SingleCross(2).Value = cp(2);
                    return;
                end
                h1 = xline(ax, cp(1), 'Color', [1 0.85 0.20], 'LineWidth', 1);
                h2 = yline(ax, cp(2), 'Color', [1 0.85 0.20], 'LineWidth', 1);
                try, h1.HitTest = 'off'; h2.HitTest = 'off'; catch, end
                try, h1.PickableParts = 'none'; h2.PickableParts = 'none'; catch, end
                obj.SingleCross = [h1 h2];
            catch
                obj.SingleCross = [];
            end
        end

        function clearSingleCrosshair(obj)
            if isempty(obj.SingleCross)
                return;
            end
            for kk = 1:numel(obj.SingleCross)
                try
                    if isvalid(obj.SingleCross(kk))
                        delete(obj.SingleCross(kk));
                    end
                catch
                end
            end
            obj.SingleCross = [];
        end

        function ov = addOverlayImage(obj, edge)
            ov = [];
            ax = obj.Axes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            [nr, nc] = size(edge);
            rgb = zeros(nr, nc, 3);
            rgb(:, :, 1) = 1.00;
            rgb(:, :, 2) = 0.82;
            rgb(:, :, 3) = 0.16;
            try
                hold(ax, 'on');
                xl = fieldAny(obj.SingleInfo, {'XLim'}, obj.FullXLim);
                yl = fieldAny(obj.SingleInfo, {'YLim'}, obj.FullYLim);
                ov = imagesc(ax, pixelCenters(xl, nc), pixelCenters(yl, nr), rgb);
                ov.AlphaData = obj.OverlayAlpha * double(edge > 0.05);
                try, uistack(ov, 'top'); catch, end
                if ~isempty(obj.MainImage) && isvalid(obj.MainImage)
                    try, uistack(obj.MainImage, 'bottom'); catch, end
                end
                hold(ax, 'off');
            catch
                ov = [];
            end
        end

        function refreshOverlay(obj)
            if isempty(obj.Axes) || ~isvalid(obj.Axes)
                return;
            end
            if ~isempty(obj.OverlayImage) && isvalid(obj.OverlayImage)
                try, delete(obj.OverlayImage); catch, end
            end
            obj.OverlayImage = [];
            if obj.OverlayVisible && strcmp(obj.ModalityKey, 'Norm') && ...
                    ~isempty(obj.CurrentEdge) && any(obj.CurrentEdge(:) > 0.05)
                obj.OverlayImage = obj.addOverlayImage(obj.CurrentEdge);
            end
            % 重画后把范围恢复（imagesc 可能触发自动范围）
            obj.applyZoom(obj.Zoom);
        end

        function [lo, hi] = windowLimits(obj, img)
            loP = obj.WindowLowPct;
            hiP = obj.WindowHighPct;
            v = img(isfinite(img));
            if isempty(v)
                lo = 0;
                hi = 1;
                return;
            end
            lo = pctLocal(v, loP);
            hi = pctLocal(v, hiP);
            if ~isfinite(lo) || ~isfinite(hi) || hi <= lo
                lo = min(v);
                hi = max(v);
            end
            if hi <= lo
                hi = lo + 1;
            end
        end

        function applyWindowToAxes(obj)
            if ~obj.HasImage || isempty(obj.CurrentImage)
                return;
            end
            [lo, hi] = obj.windowLimits(obj.CurrentImage);
            obj.Clim = [lo hi];
            try, obj.Axes.CLim = [lo hi]; catch, end
            obj.syncWindowUI();
        end

        function showPlaceholder(obj, msg)
            obj.HasImage = false;
            obj.ImageSize = [0 0];
            obj.CurrentImage = [];
            obj.CurrentEdge = [];
            obj.MainImage = [];
            obj.OverlayImage = [];
            obj.FullXLim = [0 1];
            obj.FullYLim = [0 1];
            ax = obj.Axes;
            if ~isempty(ax) && isvalid(ax)
                obj.UpdatingAxes = true;
                try, cla(ax); catch, end
                try
                    ax.XLim = [0 1];
                    ax.YLim = [0 1];
                    ax.CLim = [0 1];
                    hold(ax, 'on');
                    text(ax, 0.5, 0.5, wrapChars(msg, 26), 'Units', 'normalized', ...
                        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                        'Color', [0.78 0.81 0.86], 'FontName', obj.Fonts.name, ...
                        'FontSize', 13, 'Interpreter', 'none');
                    hold(ax, 'off');
                catch
                end
                obj.UpdatingAxes = false;
            end
            obj.syncSliceUI();
            obj.syncZoomUI();
            try, obj.ClimLabel.Text = '显示范围 —'; catch, end
            obj.setMessage(msg);
            obj.refreshSecondaryViews();
        end

        function updateImageTitle(obj, file)
            sub = obj.SubjectID;
            if isempty(sub), sub = '—'; end
            try
                obj.SubjectTitleLabel.Text = sprintf('%s · %s', sub, obj.modalityLabel());
            catch
            end
            extra = '';
            if strcmp(obj.ModalityKey, 'Norm')
                extra = sprintf(' · %s', normKindLabelFor(obj.NormKind));
                if obj.OverlayVisible && ~isempty(obj.CurrentEdge) && any(obj.CurrentEdge(:) > 0.05)
                    extra = [extra ' · 模板轮廓']; %#ok<AGROW>
                end
            end
            try
                obj.FileTitleLabel.Text = sprintf('%s · %s%s', shortFileName(file), ...
                    obj.CurrentSliceLabel, extra);
            catch
            end
        end
    end

    % ==================================================================
    %  缩放 / 窗宽 / 同步 UI
    % ==================================================================
    methods (Access = private)

        function applyZoom(obj, f)
            if ~isnumeric(f) || ~isscalar(f) || ~isfinite(f) || f <= 0
                f = 1;
            end
            f = max(0.5, min(40, double(f)));
            [ax, xl, yl] = obj.activeViewGeometry();
            if obj.HasImage && ~isempty(ax) && isvalid(ax)
                cx = mean(ax.XLim);
                cy = mean(ax.YLim);
                if f == 1, cx = mean(xl); cy = mean(yl); end
                w = diff(xl) / f;
                h = diff(yl) / f;
                obj.UpdatingAxes = true;
                try
                    ax.XLim = [cx - w / 2, cx + w / 2];
                    ax.YLim = [cy - h / 2, cy + h / 2];
                catch
                end
                obj.UpdatingAxes = false;
            end
            obj.Zoom = obj.computeZoomFactor();
            obj.syncZoomUI();
        end

        function f = computeZoomFactor(obj)
            f = obj.Zoom;
            [ax, xl, yl] = obj.activeViewGeometry();
            if ~obj.HasImage || isempty(ax) || ~isvalid(ax)
                f = 1;
                return;
            end
            try
                w = abs(diff(ax.XLim));
                h = abs(diff(ax.YLim));
                if w <= eps || h <= eps
                    return;
                end
                f2 = sqrt((diff(xl) / w) * (diff(yl) / h));
                if isfinite(f2) && f2 > 0
                    f = f2;
                end
            catch
            end
        end

        function f = pixelOneZoom(obj)
            f = 1;
            [ax, ~, ~, imageSize] = obj.activeViewGeometry();
            if obj.HasImage && ~isempty(ax) && isvalid(ax)
                try
                    pos = ax.InnerPosition;
                    if numel(pos) == 4 && pos(3) > 10 && pos(4) > 10
                        nc = max(1, imageSize(2));
                        nr = max(1, imageSize(1));
                        scale = min(pos(3) / nc, pos(4) / nr);
                        if scale > 0
                            f = 1 / scale;
                        end
                    end
                catch
                end
            end
            f = max(0.5, min(40, f));
        end

        function [ax, xl, yl, imageSize] = activeViewGeometry(obj)
            ax = obj.Axes; xl = obj.FullXLim; yl = obj.FullYLim;
            imageSize = obj.ImageSize;
            if strcmp(obj.ViewMode, 'triple') && obj.TripleBuilt
                fld = tripleFieldName(obj.ActiveOrientation);
                ax = obj.TripleAxes.(fld);
                info = obj.TripleInfo.(fld);
                xl = sort(fieldAny(info, {'XLim'}, xl));
                yl = sort(fieldAny(info, {'YLim'}, yl));
                imageSize = fieldAny(info, {'ImageSize'}, imageSize);
            end
        end

        function onAxesLimPostSet(obj)
            if obj.UpdatingAxes || ~obj.Built || obj.Constructing || ~obj.HasImage
                return;
            end
            obj.Zoom = obj.computeZoomFactor();
            obj.syncZoomUI();
        end

        function syncZoomUI(obj)
            if isempty(obj.ZoomLabel) || ~isvalid(obj.ZoomLabel)
                return;
            end
            f = obj.computeZoomFactor();
            if ~isfinite(f)
                f = 1;
            end
            if abs(f - 1) < 0.005
                txt = '缩放 1.00×';
            else
                txt = sprintf('缩放 %.2f×', f);
            end
            try, obj.ZoomLabel.Text = txt; catch, end
            if strcmp(obj.ViewMode, 'triple') && obj.TripleBuilt
                fields = {'Axial', 'Coronal', 'Sagittal'};
                for k = 1:3
                    ax = obj.TripleAxes.(fields{k});
                    info = obj.TripleInfo.(fields{k});
                    if isempty(fieldnames(info)), continue; end
                    z = sqrt(abs(diff(info.XLim) * diff(info.YLim)) / ...
                        (diff(ax.XLim) * diff(ax.YLim)));
                    o = orientationFromFieldName(fields{k});
                    marker = ''; color = obj.Colors.text;
                    if strcmp(o, obj.ActiveOrientation), marker = ' · 活动'; color = obj.Colors.accentDark; end
                    title(ax, sprintf('%s %d/%d · %.2f×%s', tripleLabel(o), ...
                        info.SliceIndex, info.SliceCount, z, marker), ...
                        'Interpreter', 'none', 'Color', color, 'FontSize', 9);
                end
            end
        end

        function syncSliceUI(obj)
            if isempty(obj.SliceSlider) || ~isvalid(obj.SliceSlider)
                return;
            end
            obj.UpdatingSliceUI = true;
            lim = [1 max(2, round(obj.SliceCount))];
            v = max(1, min(lim(2), round(obj.SliceIndex)));
            try
                if ~isequal(obj.SliceSlider.Limits, lim)
                    obj.SliceSlider.Limits = lim;
                end
                obj.SliceSlider.Value = v;
                obj.SliceSlider.Enable = onOff(obj.HasImage);
            catch
            end
            try
                obj.SliceField.Value = max(1, round(obj.SliceIndex));
                obj.SliceField.Enable = onOff(obj.HasImage);
            catch
            end
            try
                obj.SliceCountLabel.Text = sprintf('/ %d', max(1, round(obj.SliceCount)));
            catch
            end
            obj.UpdatingSliceUI = false;
        end

        function syncWindowUI(obj)
            try, obj.WinLowField.Value = obj.WindowLowPct; catch, end
            try, obj.WinHighField.Value = obj.WindowHighPct; catch, end
            try
                obj.ClimLabel.Text = sprintf('显示 %.4g – %.4g', obj.Clim(1), obj.Clim(2));
            catch
            end
        end

        function updateScoreUI(obj)
            sc = obj.scoreFor(obj.SubjectID);
            obj.Comment = sc.Comment;
            try, obj.CommentArea.Value = obj.Comment; catch, end
            v = sc.Score;
            if ~(isnumeric(v) && isscalar(v) && isfinite(v) && v >= 1 && v <= 5)
                v = 3;
            end
            obj.Score = round(v);
            obj.selectScoreRadio(obj.Score);
        end

        function selectScoreRadio(obj, v)
            k = max(1, min(5, round(v)));
            if numel(obj.ScoreRadios) >= k && ~isempty(obj.ScoreRadios{k})
                try, obj.ScoreGroup.SelectedObject = obj.ScoreRadios{k}; catch, end
            end
        end

        function v = readScoreSelection(obj)
            v = obj.Score;
            try
                sel = obj.ScoreGroup.SelectedObject;
                if ~isempty(sel) && isprop(sel, 'UserData') && isnumeric(sel.UserData) && isscalar(sel.UserData)
                    v = double(sel.UserData);
                end
            catch
            end
            if ~(v >= 1 && v <= 5)
                v = 3;
            end
        end

        function s = readComment(obj)
            s = '';
            try
                s = toTextValue(obj.CommentArea.Value);
            catch
            end
            obj.Comment = s;
        end

        function updateTableSelection(obj)
            if isempty(obj.SubjectTable) || ~isvalid(obj.SubjectTable)
                return;
            end
            row = find(obj.FilteredIdx == obj.SubjectIndex, 1);
            if isempty(row)
                return;
            end
            obj.UpdatingTable = true;
            try, obj.SubjectTable.Selection = [row 1]; catch, end
            obj.UpdatingTable = false;
        end

        function setControlsEnabled(obj, tf)
            tf = logical(tf);
            basic = {obj.SubjectTable, obj.PrevButton, obj.NextButton, obj.SliceSlider, ...
                obj.SliceField, obj.ZoomOutButton, obj.ZoomOneButton, obj.ZoomInButton, ...
                obj.ZoomFitButton, obj.WinLowField, obj.WinHighField, obj.AutoWindowButton, ...
                obj.ResetViewButton, obj.SaveButton, obj.SkipButton, obj.ExportButton, ...
                obj.ThresholdDropdown, obj.OnlyUnscoredCheck, obj.ViewModeDropdown, ...
                obj.CopyStateButton, obj.FilterDropdown, obj.SortDropdown, ...
                obj.ColormapDropdown, obj.InterpDropdown, obj.CrosshairCheck, ...
                obj.AlignButton, obj.ResetAlignButton, obj.FdTypeDropdown, obj.FdThresholdField};
            for i = 1:numel(basic)
                setEnable(basic{i}, tf);
            end
            isNorm = strcmp(obj.ModalityKey, 'Norm');
            setEnable(obj.OverlayCheck, tf && isNorm);
            setEnable(obj.OverlayAlphaSlider, tf && isNorm);
            setEnable(obj.NormKindDropdown, tf && isNorm);
        end

        function layoutScoreRadios(obj)
            % uiradiobutton 在 R2026a 没有 Units 属性：按 uibuttongroup 实际像素高度
            % 手工排布 5 个单选按钮（组固定 150px 高，且 AutoResizeChildren=off）。
            if isempty(obj.ScoreGroup) || ~isvalid(obj.ScoreGroup) || isempty(obj.ScoreRadios)
                return;
            end
            h = 150;
            w = 236;
            try
                pos = obj.ScoreGroup.InnerPosition;
                if numel(pos) == 4 && pos(3) > 40 && pos(4) > 40
                    w = pos(3);
                    h = pos(4);
                else
                    pos = obj.ScoreGroup.Position;
                    if numel(pos) == 4 && pos(3) > 40 && pos(4) > 40
                        w = pos(3);
                        h = pos(4);
                    end
                end
            catch
            end
            n = numel(obj.ScoreRadios);
            rowH = max(18, floor((h - 8) / n));
            for k = 1:n
                rb = obj.ScoreRadios{k};
                if isempty(rb) || ~isvalid(rb)
                    continue;
                end
                y = h - 4 - k * rowH;
                try
                    rb.Position = [8, max(2, y), max(60, w - 16), rowH - 2];
                catch
                end
            end
        end

        function syncNormKindUI(obj)
            s = obj.currentSubject();
            cands = obj.normCandidates(s);
            if isempty(cands)
                return;
            end
            which = cell(1, numel(cands));
            for i = 1:numel(cands)
                which{i} = cands{i}.Which;
            end
            labels = cell(1, numel(which));
            for i = 1:numel(which)
                labels{i} = normKindItemLabel(which{i});
            end
            try
                obj.NormKindDropdown.Items = labels;
                obj.NormKindDropdown.ItemsData = which;
                if ~any(strcmp(which, obj.NormKind))
                    obj.NormKind = which{1};
                end
                obj.NormKindDropdown.Value = obj.NormKind;
            catch
            end
        end

        function updateAvailabilityUI(obj)
            isNorm = strcmp(obj.ModalityKey, 'Norm');
            h = obj.RightGrid.RowHeight;
            if numel(h) >= 12
                if isNorm
                    h{10} = 24;
                    h{11} = 30;
                    h{12} = 28;
                else
                    h{10} = 0;
                    h{11} = 0;
                    h{12} = 0;
                end
                try, obj.RightGrid.RowHeight = h; catch, end
            end
            try, obj.OverlayCheck.Value = obj.OverlayVisible; catch, end
            try, obj.OverlayAlphaSlider.Value = obj.OverlayAlpha; catch, end
            if isNorm
                obj.syncNormKindUI();
            end
        end
    end

    % ==================================================================
    %  评分 / 进度 / 表格 / 状态提示
    % ==================================================================
    methods (Access = private)

        function sc = scoreFor(obj, id)
            sc = struct('Score', NaN, 'Comment', '');
            if isempty(id)
                return;
            end
            for i = 1:numel(obj.Scores)
                if strcmp(obj.Scores(i).ID, id)
                    sc.Score = obj.Scores(i).Score;
                    sc.Comment = obj.Scores(i).Comment;
                    return;
                end
            end
        end

        function v = savedScoreFor(obj, id)
            sc = obj.scoreFor(id);
            v = sc.Score;
            if ~isfinite(v)
                v = NaN;
            end
        end

        function setScoreInCache(obj, id, score, comment)
            for i = 1:numel(obj.Scores)
                if strcmp(obj.Scores(i).ID, id)
                    obj.Scores(i).Score = score;
                    obj.Scores(i).Comment = comment;
                    return;
                end
            end
            obj.Scores(end+1) = struct('ID', id, 'Score', score, 'Comment', comment);
        end

        function n = countScored(obj)
            n = 0;
            for i = 1:numel(obj.Scores)
                if isfield(obj.Scores(i), 'Score') && isfinite(obj.Scores(i).Score)
                    n = n + 1;
                end
            end
        end

        function m = meanScore(obj)
            vals = [];
            for i = 1:numel(obj.Scores)
                if isfield(obj.Scores(i), 'Score') && isfinite(obj.Scores(i).Score)
                    vals(end+1) = obj.Scores(i).Score; %#ok<AGROW>
                end
            end
            if isempty(vals)
                m = NaN;
            else
                m = mean(vals);
            end
        end

        function p = progressSummary(obj)
            keys = {'T1', 'Fun', 'Norm'};
            p = struct();
            for i = 1:numel(keys)
                p.(keys{i}) = struct('Scored', 0, 'Total', 0, 'Mean', NaN);
            end
            mp = obj.ModelProgress;
            usedModel = false;
            if isstruct(mp)
                for i = 1:numel(keys)
                    k = keys{i};
                    if isfield(mp, k) && isstruct(mp.(k))
                        q = mp.(k);
                        if isfield(q, 'Scored') && isnumeric(q.Scored) && isscalar(q.Scored)
                            p.(k).Scored = double(q.Scored);
                            usedModel = true;
                        end
                        if isfield(q, 'Total') && isnumeric(q.Total) && isscalar(q.Total)
                            p.(k).Total = double(q.Total);
                        end
                        if isfield(q, 'Mean') && isnumeric(q.Mean) && isscalar(q.Mean)
                            p.(k).Mean = double(q.Mean);
                        end
                    end
                end
            end
            % 当前模态以界面内数据为准（保证保存后立即更新）
            cur = p.(obj.ModalityKey);
            cur.Scored = obj.countScored();
            cur.Total = numel(obj.SubjectList);
            cur.Mean = obj.meanScore();
            p.(obj.ModalityKey) = cur;
            % 模型 progress 不可用时，退化为逐个模态读评分文件
            if ~usedModel && isstruct(obj.Discover) && isOkStruct(obj.Discover)
                for i = 1:numel(keys)
                    k = keys{i};
                    if strcmp(k, obj.ModalityKey)
                        continue;
                    end
                    sc = obj.modelCall('loadScores', obj.WorkDir, k);
                    scores = obj.normalizeScores(sc);
                    tot = 0;
                    meanV = NaN;
                    if isstruct(obj.Discover) && isfield(obj.Discover, 'Modalities')
                        M = obj.Discover.Modalities;
                        for j = 1:numel(M)
                            if isfield(M(j), 'Key') && strcmp(normalizeModalityKey(M(j).Key), k) && ...
                                    isfield(M(j), 'SubjectIDs')
                                ids = M(j).SubjectIDs;
                                if iscell(ids), tot = numel(ids); end
                            end
                        end
                    end
                    if tot < numel(scores)
                        tot = numel(scores);
                    end
                    vals = [];
                    for j = 1:numel(scores)
                        if isfinite(scores(j).Score)
                            vals(end+1) = scores(j).Score; %#ok<AGROW>
                        end
                    end
                    if ~isempty(vals)
                        meanV = mean(vals);
                    end
                    p.(k) = struct('Scored', numel(vals), 'Total', tot, 'Mean', meanV);
                end
            end
        end

        function updateProgressUI(obj)
            p = obj.progressSummary();
            cur = p.(obj.ModalityKey);
            c = obj.Colors;
            if cur.Total > 0
                try, obj.ProgressBadge.Text = sprintf('已评分 %d/%d', cur.Scored, cur.Total); catch, end
                if cur.Scored >= cur.Total
                    bg = c.okBg;
                    fg = c.ok;
                elseif cur.Scored > 0
                    bg = c.accentBg;
                    fg = c.accentDark;
                else
                    bg = c.panelAlt;
                    fg = c.muted;
                end
                try
                    obj.ProgressBadge.BackgroundColor = bg;
                    obj.ProgressBadge.FontColor = fg;
                catch
                end
            else
                try
                    obj.ProgressBadge.Text = '已评分 —';
                    obj.ProgressBadge.BackgroundColor = c.panelAlt;
                    obj.ProgressBadge.FontColor = c.muted;
                catch
                end
            end
            if cur.Total > 0 && isfinite(cur.Mean)
                try
                    obj.ProgressLabel.Text = sprintf('已评分 %d / %d 人 · 平均 %.2f 分', ...
                        cur.Scored, cur.Total, cur.Mean);
                catch
                end
            elseif cur.Total > 0
                try, obj.ProgressLabel.Text = sprintf('已评分 %d / %d 人', cur.Scored, cur.Total); catch, end
            else
                obj.updateProgressLabelEmpty();
            end
            txt = sprintf('评分进度（Progress）：T1 %d/%d · 功能 %d/%d · 标准化 %d/%d', ...
                p.T1.Scored, p.T1.Total, p.Fun.Scored, p.Fun.Total, p.Norm.Scored, p.Norm.Total);
            try, obj.FooterProgressLabel.Text = txt; catch, end
        end

        function updateProgressLabelEmpty(obj)
            try
                obj.ProgressLabel.Text = '尚未评分（选择 1–5 分后保存）';
            catch
            end
        end

        function updateMeanFDUi(obj)
            c = obj.Colors;
            txt = 'Mean FD：无数据';
            color = c.muted;
            hm = obj.HeadMotion;
            if isstruct(hm) && isfield(hm, 'Available') && logical(fieldOr(hm, 'Available', false)) && ...
                    isfield(hm, 'IDs') && isfield(hm, 'MeanFD') && ~isempty(obj.SubjectID)
                ids = hm.IDs;
                if isstring(ids)
                    ids = cellstr(ids);
                elseif ischar(ids)
                    ids = {ids};
                end
                if iscell(ids)
                    k = find(strcmp(ids, obj.SubjectID), 1);
                    if ~isempty(k) && numel(hm.MeanFD) >= k && isfinite(hm.MeanFD(k))
                        val = double(hm.MeanFD(k));
                        thr = 0.2;
                        if isfield(obj.Thresholds, 'MaxMeanFD') && isnumeric(obj.Thresholds.MaxMeanFD) && ...
                                isscalar(obj.Thresholds.MaxMeanFD) && isfinite(obj.Thresholds.MaxMeanFD)
                            thr = double(obj.Thresholds.MaxMeanFD);
                        end
                        txt = sprintf('Mean FD = %.4f mm（阈值 %.2f）', val, thr);
                        if val > thr
                            txt = sprintf('%s\n⚠ 超过阈值，建议复核', txt);
                            color = c.err;
                        else
                            color = c.ok;
                        end
                    elseif ~isempty(k)
                        txt = 'Mean FD：该受试者无头动数据';
                    end
                end
            end
            try
                obj.MeanFDLabel.Text = txt;
                obj.MeanFDLabel.FontColor = color;
            catch
            end
        end

        function rebuildTable(obj)
            if isempty(obj.SubjectTable) || ~isvalid(obj.SubjectTable)
                return;
            end
            n = numel(obj.FilteredIdx);
            rows = cell(n, 3);
            lowRows = [];
            fdBadRows = [];
            curRow = 0;
            thrFD = obj.meanFDThreshold();
            for k = 1:n
                i = obj.FilteredIdx(k);
                s = obj.SubjectList{i};
                sc = obj.scoreFor(s.ID);
                rows{k, 1} = s.ID;
                if isfinite(sc.Score)
                    rows{k, 2} = sprintf('%d', round(sc.Score));
                else
                    rows{k, 2} = '—';
                end
                fd = obj.meanFDFor(s.ID);
                if isfinite(fd)
                    rows{k, 3} = sprintf('%.3f', fd);
                    if fd > thrFD
                        fdBadRows(end+1) = k; %#ok<AGROW>
                    end
                else
                    rows{k, 3} = '—';
                end
                if i == obj.SubjectIndex
                    curRow = k;
                end
                if isfinite(sc.Score) && (sc.Score <= 2 || sc.Score < obj.MinScore)
                    lowRows(end+1) = k; %#ok<AGROW>
                end
            end
            obj.UpdatingTable = true;
            try
                obj.SubjectTable.Data = rows;
            catch
            end
            obj.UpdatingTable = false;
            try, obj.SubjectTable.removeStyle(); catch, end
            c = obj.Colors;
            try
                if ~isempty(lowRows)
                    st = uistyle('FontColor', c.err, 'FontWeight', 'bold');
                    for r = lowRows
                        addStyle(obj.SubjectTable, st, 'row', r);
                    end
                end
                if ~isempty(fdBadRows)
                    stFD = uistyle('FontColor', c.err, 'FontWeight', 'bold');
                    for r = fdBadRows
                        addStyle(obj.SubjectTable, stFD, 'cell', [r 3]);
                    end
                end
                if curRow > 0
                    st2 = uistyle('BackgroundColor', c.accentBg, 'FontWeight', 'bold');
                    addStyle(obj.SubjectTable, st2, 'row', curRow);
                end
            catch
            end
            total = numel(obj.SubjectList);
            scored = obj.countScored();
            try
                obj.ListSummaryLabel.Text = sprintf('共 %d 人 · 已评分 %d · 未评分 %d · 显示 %d', ...
                    total, scored, max(0, total - scored), n);
            catch
            end
            if n == 0 && total > 0
                try, obj.LeftHintLabel.Text = '当前筛选下没有受试者'; catch, end
            else
                try, obj.LeftHintLabel.Text = '提示：点击行切换受试者'; catch, end
            end
        end

        function updateFooter(obj)
            if isempty(obj.FooterPanel) || ~isvalid(obj.FooterPanel)
                return;
            end
            obj.updateProgressUI();
            try, obj.MessageLabel.Text = obj.Message; catch, end
            try, obj.VersionLabel.Text = ['QcPanel v' obj.Version]; catch, end
        end

        function setMessage(obj, msg)
            if isstring(msg)
                msg = char(msg);
            elseif ~ischar(msg)
                msg = '';
            end
            obj.Message = msg;
            if ~isempty(obj.MessageLabel) && isvalid(obj.MessageLabel)
                try, obj.MessageLabel.Text = msg; catch, end
            end
        end

        function varargout = modelCall(obj, name, varargin)
            % 调用 mrw.QcModel.<name>（失败时返回空并记录 LastModelError）
            obj.LastModelError = '';
            fname = ['mrw.QcModel.' name];
            if nargout == 0
                try
                    feval(fname, varargin{:});
                catch ME
                    obj.LastModelError = ME.message;
                end
                return;
            end
            varargout = cell(1, nargout);
            try
                [varargout{:}] = feval(fname, varargin{:});
            catch ME
                obj.LastModelError = ME.message;
                for k = 1:nargout
                    varargout{k} = [];
                end
            end
        end

        function [ok, msg] = modelSaveScore(obj, varargin)
            ok = false;
            msg = '';
            obj.LastModelError = '';
            try
                [ok, msg] = feval('mrw.QcModel.saveScore', varargin{:});
            catch ME
                obj.LastModelError = ME.message;
                % 兼容只返回 1 个输出的实现
                try
                    ok = feval('mrw.QcModel.saveScore', varargin{:});
                    msg = '';
                    obj.LastModelError = '';
                catch ME2
                    obj.LastModelError = ME2.message;
                    ok = false;
                    msg = ME2.message;
                end
            end
            if ~ischar(msg)
                msg = '';
            end
        end
    end

    % ==================================================================
    %  交互回调
    % ==================================================================
    methods (Access = private)

        function onBrowseWorkdir(obj)
            d = '';
            try
                d = uigetdir(obj.WorkDir, '选择 DPARSF 预处理工作目录');
            catch
                d = '';
            end
            if ischar(d) && ~isempty(d)
                obj.setWorkingDir(d);
            end
        end

        function onRescan(obj)
            obj.clearCache();
            obj.doRefresh(false);
        end

        function onModalityChanged(obj)
            try
                v = obj.ModalityDropdown.Value;
            catch
                return;
            end
            obj.setModality(v);
        end

        function onTableSelection(obj, e)
            if obj.UpdatingTable
                return;
            end
            idx = [];
            try, idx = e.Indices; catch, end
            if isempty(idx)
                return;
            end
            row = idx(1, 1);
            if row < 1 || row > numel(obj.FilteredIdx)
                return;
            end
            target = obj.FilteredIdx(row);
            if target == obj.SubjectIndex
                return;
            end
            obj.selectSubjectIndex(target, true);
            obj.updateMeanFDUi();
            obj.updateFooter();
            obj.notifyChangedIfReady();
        end

        function onSliceSliderChanging(obj, e)
            if obj.UpdatingSliceUI
                return;
            end
            v = [];
            try, v = e.Value; catch, end
            if isempty(v)
                try, v = obj.SliceSlider.Value; catch, end
            end
            obj.PendingSlice = v;
            if obj.SliceBusy, return; end
            obj.SliceBusy = true;
            try
                while ~isempty(obj.PendingSlice)
                    value = obj.PendingSlice; obj.PendingSlice = [];
                    obj.setSliceIndex(value);
                    drawnow limitrate;
                end
            catch err
                obj.SliceBusy = false;
                rethrow(err);
            end
            obj.SliceBusy = false;
        end

        function onSliceSliderChanged(obj, e)
            if obj.UpdatingSliceUI
                return;
            end
            v = [];
            try, v = e.Value; catch, end
            if isempty(v)
                try, v = obj.SliceSlider.Value; catch, end
            end
            obj.setSliceIndex(v);
            obj.PendingSlice = [];
            obj.writeStateNow();
        end

        function onSliceFieldChanged(obj)
            try
                v = obj.SliceField.Value;
            catch
                return;
            end
            obj.setSliceIndex(v);
        end

        function onOrientationChanged(obj)
            if obj.UpdatingViewUI
                return;
            end
            try
                v = obj.OrientationDropdown.Value;
            catch
                return;
            end
            obj.setOrientation(v);
        end

        function onZoomIn(obj)
            obj.setZoomFactor(obj.getZoomFactor() * 1.25);
        end

        function onZoomOut(obj)
            obj.setZoomFactor(obj.getZoomFactor() / 1.25);
        end

        function onZoomOne(obj)
            obj.setZoomFactor(obj.pixelOneZoom());
        end

        function onZoomFit(obj)
            obj.setZoomFactor(1);
        end

        function onWindowFieldChanged(obj)
            try
                lo = obj.WinLowField.Value;
                hi = obj.WinHighField.Value;
            catch
                return;
            end
            obj.setWindow(lo, hi);
        end

        function onAutoWindow(obj)
            obj.setWindow(0, 100);
        end

        function onResetView(obj)
            obj.Orientation = 'axial';
            try, obj.OrientationDropdown.Value = 'axial'; catch, end
            obj.SliceIndex = 0;
            obj.Zoom = 1;
            if ~isempty(obj.currentSubject())
                obj.loadCurrentSlice(true);
            end
        end

        function onOverlayChecked(obj)
            try
                tf = obj.OverlayCheck.Value;
            catch
                tf = obj.OverlayVisible;
            end
            obj.setOverlayVisible(tf);
        end

        function onOverlayAlphaChanging(obj, e)
            a = [];
            try, a = e.Value; catch, end
            if isempty(a)
                try, a = obj.OverlayAlphaSlider.Value; catch, end
            end
            obj.setOverlayAlpha(a);
            try
                obj.updateImageTitle(obj.currentFile());
            catch
            end
        end

        function onNormKindChanged(obj)
            try
                v = obj.NormKindDropdown.Value;
            catch
                return;
            end
            obj.setNormKind(v);
        end

        function onScoreChanged(obj)
            obj.Score = obj.readScoreSelection();
        end

        function onSavePressed(obj)
            obj.saveCurrentScore();
        end

        function onSkipPressed(obj)
            obj.setMessage(sprintf('已跳过 %s（未评分）', obj.SubjectID));
            obj.nextSubject();
        end

        function onOnlyUnscoredChanged(obj)
            if obj.UpdatingFilterUI
                return;
            end
            try
                tf = obj.OnlyUnscoredCheck.Value;
            catch
                tf = false;
            end
            obj.setFilterOnlyUnscored(tf);
        end

        function onThresholdChanged(obj)
            try
                v = obj.ThresholdDropdown.Value;
            catch
                return;
            end
            obj.setThreshold(v);
        end

        function onExportPressed(obj)
            filePath = '';
            try
                defaultDir = obj.WorkDir;
                if isempty(defaultDir)
                    defaultDir = pwd;
                elseif exist(fullfile(defaultDir, 'QC'), 'dir') == 7
                    defaultDir = fullfile(defaultDir, 'QC');
                end
                [fn, pth] = uiputfile({'*.txt', '文本名单 (*.txt)'}, ...
                    '导出通过名单', fullfile(defaultDir, 'PassList.txt'));
                if isequal(fn, 0)
                    return;
                end
                filePath = fullfile(pth, fn);
            catch
                filePath = '';
            end
            if isempty(filePath)
                filePath = fullfile(obj.WorkDir, 'QC', 'PassList.txt');
            end
            obj.exportPassList(filePath);
        end
    end

    % ==================================================================
    %  键盘 / 生命周期 / 统计
    % ==================================================================
    methods (Access = private)

        function attachKeyboard(obj)
            fig = obj.findFigure();
            if isempty(fig)
                return;
            end
            obj.FigureHandle = fig;
            names = {'WindowScrollWheelFcn', 'WindowButtonDownFcn', ...
                'WindowButtonMotionFcn', 'WindowButtonUpFcn'};
            for k = 1:numel(names)
                name = names{k};
                obj.PreviousMouseCallbacks.(name) = fig.(name);
                obj.MouseCallbacks.(name) = @(s, e) obj.onMouseEvent(name, s, e);
                fig.(name) = obj.MouseCallbacks.(name);
            end
            try
                if isprop(fig, 'WindowKeyPressFcn')
                    obj.PrevWindowKeyPressFcn = fig.WindowKeyPressFcn;
                    obj.KeyPressHandler = @(s, e) obj.onWindowKeyPress(s, e);
                    fig.WindowKeyPressFcn = obj.KeyPressHandler;
                end
            catch
            end
            try
                addlistener(obj, 'ObjectBeingDestroyed', @(s, e) obj.onBeingDestroyed());
            catch
            end
        end

        function fig = findFigure(obj)
            fig = [];
            h = obj.Parent;
            for k = 1:20
                if isempty(h)
                    break;
                end
                if isa(h, 'matlab.ui.Figure')
                    fig = h;
                    return;
                end
                try
                    if isprop(h, 'Parent')
                        h = h.Parent;
                    else
                        h = [];
                    end
                catch
                    h = [];
                end
            end
        end

        function onWindowKeyPress(obj, src, evt)
            % 先调用原 figure 回调（链式，不破坏主程序快捷键）
            if ~isempty(obj.PrevWindowKeyPressFcn)
                try
                    feval(obj.PrevWindowKeyPressFcn, src, evt);
                catch
                end
            end
            if obj.Constructing || ~obj.Built
                return;
            end
            cur = [];
            try, cur = gcbo; catch, end
            if ~isempty(cur)
                if (isa(cur, 'matlab.ui.control.EditField') || ...
                        isa(cur, 'matlab.ui.control.NumericEditField') || ...
                        isa(cur, 'matlab.ui.control.TextArea') || ...
                        isa(cur, 'matlab.ui.control.DropDown') || ...
                        isa(cur, 'matlab.ui.control.ListBox') || ...
                        isa(cur, 'matlab.ui.control.Spinner'))
                    return;
                end
            end
            key = '';
            try, key = evt.Key; catch, end
            isTriple = strcmp(obj.ViewMode, 'triple');
            switch key
                case 'uparrow'
                    obj.setSliceIndex(obj.SliceIndex - 1);
                case 'downarrow'
                    obj.setSliceIndex(obj.SliceIndex + 1);
                case 'leftarrow'
                    obj.prevSubject();
                case 'rightarrow'
                    obj.nextSubject();
                case 'home'
                    obj.setSliceIndex(1);
                case 'end'
                    obj.setSliceIndex(obj.SliceCount);
                case 'a'
                    if isTriple
                        obj.setActiveOrientation('axial');
                    end
                case 'c'
                    if isTriple
                        obj.setActiveOrientation('coronal');
                    end
                case 's'
                    if isTriple
                        obj.setActiveOrientation('sagittal');
                    end
                case 'x'
                    obj.setCrosshairVisible(~obj.CrosshairVisible);
                case 'r'
                    obj.resetOrientation();
                case {'1', '2', '3', '4', '5'}
                    obj.setScore(str2double(key));
                    obj.notifyChangedIfReady();
                case 'return'
                    obj.saveCurrentScore();
            end
        end

        function onMouseEvent(obj, name, src, evt)
            if obj.Constructing || ~obj.Built, return; end
            [ax, o, point, pixel] = obj.pointerTarget(evt);
            dragging = ~isempty(fieldnames(obj.MouseDrag));
            if strcmp(name, 'WindowScrollWheelFcn') && ~isempty(ax)
                if strcmp(obj.ViewMode, 'triple'), obj.setActiveOrientation(o, false); end
                count = evt.VerticalScrollCount;
                modifiers = src.CurrentModifier;
                try, modifiers = evt.Modifier; catch, end
                if any(strcmpi(modifiers, 'control'))
                    old = obj.getZoomFactor();
                    z = max(0.5, min(40, old * 1.2 ^ (-count)));
                    factor = z / old;
                    ax.XLim = point(1) + (ax.XLim - point(1)) / factor;
                    ax.YLim = point(2) + (ax.YLim - point(2)) / factor;
                    obj.Zoom = obj.computeZoomFactor(); obj.syncZoomUI();
                else
                    obj.setSliceIndex(obj.SliceIndex + count);
                end
                obj.writeStateNow();
                return;
            elseif strcmp(name, 'WindowButtonDownFcn') && ~isempty(ax)
                if strcmp(obj.ViewMode, 'triple'), obj.setActiveOrientation(o, false); end
                selection = src.SelectionType;
                try, selection = evt.SelectionType; catch, end
                if strcmp(selection, 'open')
                    obj.applyZoom(1); obj.MouseDrag = struct(); return;
                elseif ~strcmp(selection, 'normal')
                    return;
                end
                obj.MouseDrag = struct('Axes', ax, 'Orientation', o, 'Point', point, ...
                    'Pixel', pixel, 'XLim', ax.XLim, 'YLim', ax.YLim, 'Moved', false);
                obj.syncZoomUI();
                return;
            elseif dragging && any(strcmp(name, {'WindowButtonMotionFcn', 'WindowButtonUpFcn'}))
                drag = obj.MouseDrag;
                if isempty(pixel), pixel = src.CurrentPoint; end
                delta = pixel - drag.Pixel;
                drag.Moved = drag.Moved || norm(delta) >= 3;
                ax = drag.Axes;
                if drag.Moved && isvalid(ax)
                    pos = ax.InnerPosition;
                    pixelsPerUnit = min(pos(3) / diff(drag.XLim), pos(4) / diff(drag.YLim));
                    sx = 1; sy = 1;
                    if strcmp(ax.XDir, 'reverse'), sx = -1; end
                    if strcmp(ax.YDir, 'reverse'), sy = -1; end
                    ax.XLim = drag.XLim - sx * delta(1) / max(eps, pixelsPerUnit);
                    ax.YLim = drag.YLim - sy * delta(2) / max(eps, pixelsPerUnit);
                    obj.Zoom = obj.computeZoomFactor(); obj.syncZoomUI();
                end
                obj.MouseDrag = drag;
                if strcmp(name, 'WindowButtonUpFcn')
                    obj.MouseDrag = struct();
                    if ~drag.Moved
                        obj.clickViewAt(drag.Orientation, drag.Point(1), drag.Point(2));
                    end
                    obj.writeStateNow();
                end
                return;
            end
            previous = obj.PreviousMouseCallbacks.(name);
            if ~isempty(previous)
                if iscell(previous), feval(previous{1}, src, evt, previous{2:end});
                else, feval(previous, src, evt); end
            end
        end

        function [ax, o, point, pixel] = pointerTarget(obj, evt)
            ax = []; o = obj.Orientation; point = []; pixel = [];
            h = [];
            try, h = evt.HitObject; catch, end
            if isempty(h), try, h = hittest(obj.FigureHandle); catch, end, end
            if ~isempty(h)
                try
                    if isa(h, 'matlab.ui.control.UIAxes'), candidate = h;
                    else, candidate = ancestor(h, 'axes'); end
                    if strcmp(obj.ViewMode, 'single') && isequal(candidate, obj.Axes)
                        ax = candidate;
                    elseif strcmp(obj.ViewMode, 'triple')
                        fields = {'Axial', 'Coronal', 'Sagittal'};
                        for k = 1:3
                            if isequal(candidate, obj.TripleAxes.(fields{k}))
                                ax = candidate; o = orientationFromFieldName(fields{k}); break;
                            end
                        end
                    end
                catch
                end
            end
            pixel = obj.FigureHandle.CurrentPoint;
            if isstruct(evt) && isfield(evt, 'PixelPosition'), pixel = evt.PixelPosition; end
            if isempty(ax), return; end
            % WindowMouseData.Point 是 figure 像素，不能作为世界/显示 mm 坐标。
            cp = ax.CurrentPoint; point = cp(1, 1:2);
            if isstruct(evt) && isfield(evt, 'DataPoint'), point = evt.DataPoint; end
            if numel(point) < 2 || any(~isfinite(point)), ax = []; end
        end

        function onBeingDestroyed(obj)
            for panel = {obj.Toolbar, obj.CenterPanel}
                if ~isempty(panel{1}) && isvalid(panel{1})
                    panel{1}.SizeChangedFcn = [];
                end
            end
            try
                names = fieldnames(obj.MouseCallbacks);
                for k = 1:numel(names)
                    name = names{k};
                    if isvalid(obj.FigureHandle) && isequal(obj.FigureHandle.(name), obj.MouseCallbacks.(name))
                        obj.FigureHandle.(name) = obj.PreviousMouseCallbacks.(name);
                    end
                end
            catch
            end
            try
                if ~isempty(obj.AlignDialog) && isvalid(obj.AlignDialog)
                    try, obj.AlignDialog.close(); catch, end
                end
            catch
            end
            try
                fig = obj.FigureHandle;
                if ~isempty(fig) && isvalid(fig) && isprop(fig, 'WindowKeyPressFcn')
                    cur = fig.WindowKeyPressFcn;
                    same = false;
                    try
                        same = isequal(cur, obj.KeyPressHandler);
                    catch
                    end
                    if same
                        fig.WindowKeyPressFcn = obj.PrevWindowKeyPressFcn;
                    end
                end
            catch
            end
        end

        function n = countInteractiveControls(obj)
            n = 0;
            if isempty(obj.Root) || ~isvalid(obj.Root)
                return;
            end
            types = {'uibutton', 'uidropdown', 'uieditfield', 'uicheckbox', ...
                'uislider', 'uitable', 'uiradiobutton', 'uitextarea'};
            hs = findall(obj.Root);
            for i = 1:numel(hs)
                try
                    t = get(hs(i), 'Type');
                catch
                    continue;
                end
                if any(strcmp(t, types))
                    n = n + 1;
                end
            end
        end
    end

    % ==================================================================
    %  小工具（label / 名称）
    % ==================================================================
    methods (Access = private)
        function s = modalityLabel(obj)
            s = modalityLabelFor(obj.ModalityKey);
        end

        function s = orientationLabel(obj)
            switch obj.Orientation
                case 'coronal'
                    s = 'Coronal';
                case 'sagittal'
                    s = 'Sagittal';
                otherwise
                    s = 'Axial';
            end
        end

        function notifyChangedIfReady(obj)
            if obj.Constructing
                return;
            end
            try
                notify(obj, 'Changed');
            catch
            end
            obj.writeStateNow();
        end

        function tf = onlyUnscoredValue(obj)
            tf = false;
            try
                tf = logical(obj.OnlyUnscoredCheck.Value);
            catch
            end
        end

        function tf = isNormAvailable(obj)
            tf = false;
            if ~strcmp(obj.ModalityKey, 'Norm')
                return;
            end
            s = obj.currentSubject();
            cands = obj.normCandidates(s);
            tf = ~isempty(cands);
        end
    end

    % ==================================================================
    %  v2 公共接口（契约 §5.6：视图模式 / 十字线 / 校准 / 状态输出）
    % ==================================================================
    methods

        function setViewMode(obj, mode)
            % 视图模式：'single'（单视图，v1 行为）| 'triple'（三正交）| 'montage'（多切片网格）
            m = normalizeViewMode(mode);
            if isempty(m)
                return;
            end
            changed = ~strcmp(m, obj.ViewMode);
            obj.ViewMode = m;
            obj.syncViewModeUI();
            if obj.Built
                if strcmp(m, 'single')
                    obj.syncCrosshairFromSingleSlice();
                    if ~isempty(obj.currentSubject())
                        obj.loadCurrentSlice(false);
                    end
                else
                    obj.refreshViews();
                end
            end
            if changed
                obj.setMessage(sprintf('视图模式：%s', viewModeLabel(m)));
                obj.notifyChangedIfReady();
            else
                obj.maybeWriteState();
            end
        end

        function setActiveOrientation(obj, orient, doRender)
            % 三正交模式下的活动方向：'axial' | 'coronal' | 'sagittal'（也接受中文）
            if nargin < 3
                doRender = true;
            end
            o = normalizeOrientationValue(orient);
            if isempty(o)
                return;
            end
            if ~strcmp(obj.ViewMode, 'triple')
                obj.setOrientation(o);
                return;
            end
            obj.ActiveOrientation = o;
            obj.Orientation = o;
            obj.syncSliceStateForOrientation(o);
            try
                if ~isempty(obj.OrientationDropdown) && isvalid(obj.OrientationDropdown) && ...
                        any(strcmp(obj.OrientationDropdown.ItemsData, o))
                    obj.UpdatingViewUI = true;
                    obj.OrientationDropdown.Value = o;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            obj.syncSliceUI();
            if doRender
                obj.renderTriple();
                obj.maybeWriteState();
            end
        end

        function setCrosshairVoxel(obj, v)
            % 设置 3D 十字线体素坐标 [i j k]（1-based 连续坐标，自动 clamp）
            if ~isnumeric(v) || numel(v) < 3 || any(~isfinite(double(v(1:3))))
                return;
            end
            v = double(v(1:3));
            if obj.ensureView()
                try
                    obj.View.setCrosshair(v);
                    p = obj.View.getCrosshair();
                    if isnumeric(p) && numel(p) >= 3
                        v = double(p(1:3));
                    end
                catch
                end
            else
                dims = obj.currentVolumeDims();
                if ~isempty(dims)
                    v = min(max(v, 1), dims);
                end
            end
            obj.CrosshairVoxel = double(v(:).');
            if strcmp(obj.ViewMode, 'single')
                obj.syncSliceToCrosshair();
                if ~isempty(obj.currentSubject())
                    obj.loadCurrentSlice(false);
                end
            else
                obj.refreshViews();
            end
            obj.maybeWriteState();
        end

        function p = getCrosshairVoxel(obj)
            % 当前十字线体素坐标 [i j k]（与 mrw.QcView.getCrosshair 同源，避免缓存漂移）
            p = [];
            if obj.ensureView()
                try
                    q = obj.View.getCrosshair();
                    if isnumeric(q) && numel(q) >= 3 && all(isfinite(double(q(1:3))))
                        p = double(q(1:3));
                        obj.CrosshairVoxel = p(:).';
                    end
                catch
                end
            end
            if isempty(p)
                p = obj.CrosshairVoxel;
            end
            if isempty(p) || numel(p) < 3 || any(~isfinite(double(p(1:3))))
                dims = obj.currentVolumeDims();
                if isempty(dims)
                    p = [NaN NaN NaN];
                else
                    p = round((dims + 1) / 2);
                end
            end
            p = double(p(:).');
        end

        function ok = setOriginAtCrosshair(obj)
            % 以当前十字线（世界 mm）为显示原点（base='origin'，只影响显示）
            ok = false;
            if ~obj.ensureView()
                obj.setMessage('显示引擎 mrw.QcView 未就绪，无法设置显示原点');
                return;
            end
            try
                p = obj.getCrosshairVoxel();
                w = obj.View.voxelToWorld(p);
                w = double(w(1:3));
                obj.View.setOriginAtWorld(w);
                ok = true;
                obj.setMessage(sprintf('已以十字线设显示原点（世界坐标 %s mm；仅影响显示）%s', fmtVec3(w, '%.1f'), obj.transformHint()));
            catch ME
                obj.setMessage(sprintf('设置显示原点失败：%s', ME.message));
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function ok = setACPC(obj, acVoxel, pcVoxel)
            % 用 AC / PC 体素坐标做 AC-PC 配平（显示层，不修改文件）
            ok = false;
            if ~obj.ensureView()
                obj.setMessage('显示引擎 mrw.QcView 未就绪，无法做 AC-PC 配平');
                obj.refreshViews();
                obj.notifyChangedIfReady();
                return;
            end
            try
                try
                    r = obj.View.setAcPc(acVoxel, pcVoxel); %#ok<NASGU>
                catch
                    r = [];
                end
                info = obj.getViewInfo();
                mode = lower(char(fieldAny(info, {'Mode'}, 'native')));
                acpc = fieldAny(info, {'ACPC'}, struct());
                d = double(fieldAny(acpc, {'distanceMm', 'DistanceMm'}, NaN));
                ang = double(fieldAny(acpc, {'angleDeg'}, NaN));
                ok = strcmp(mode, 'acpc');
                if ok
                    obj.setMessage(sprintf('AC-PC 配平完成：距离 %.2f mm · 角度 %.1f°（仅影响显示）%s', d, ang, obj.transformHint()));
                else
                    msg = char(fieldAny(info, {'Message'}, ''));
                    if isempty(msg)
                        msg = 'AC 与 PC 距离过小或坐标无效，配平失败';
                    end
                    obj.setMessage(sprintf('AC-PC 配平失败：%s', msg));
                end
            catch ME
                obj.setMessage(sprintf('AC-PC 配平失败：%s', ME.message));
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function clearACPC(obj)
            % 清除 AC-PC 配平，回到原生显示（保留手动平移/旋转/翻转）
            if obj.ensureView()
                try
                    obj.View.clearAcPc();
                    obj.setMessage('已清除 AC-PC 配平');
                catch ME
                    obj.setMessage(sprintf('清除 AC-PC 失败：%s', ME.message));
                end
            else
                obj.setMessage('显示引擎 mrw.QcView 未就绪，无法清除 AC-PC');
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function ok = setManualOrientation(obj, tMm, rDeg)
            % 手动显示变换：平移 mm（右/前/上）、旋转 pitch/roll/yaw（度）
            ok = false;
            if nargin < 3 || ~isnumeric(tMm) || numel(tMm) < 3 || ...
                    ~isnumeric(rDeg) || numel(rDeg) < 3
                return;
            end
            tMm = double(tMm(1:3));
            rDeg = double(rDeg(1:3));
            if any(~isfinite([tMm rDeg]))
                return;
            end
            if ~obj.ensureView()
                obj.setMessage('显示引擎 mrw.QcView 未就绪，无法设置手动方位');
                return;
            end
            try
                obj.View.setManual(tMm, rDeg);
                ok = true;
                obj.setMessage(sprintf('已应用手动微调：平移 %s mm · 旋转 %s°（仅影响显示）%s', ...
                    fmtVec3(tMm, '%.1f'), fmtVec3(rDeg, '%.1f'), obj.transformHint()));
            catch ME
                obj.setMessage(sprintf('应用手动微调失败：%s', ME.message));
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function ok = setFlips(obj, flipLR, flipAP, flipIS)
            % 显示翻转：左右 / 前后 / 上下
            ok = false;
            if ~obj.ensureView()
                obj.setMessage('显示引擎 mrw.QcView 未就绪，无法设置翻转');
                return;
            end
            try
                obj.View.setFlips(logical(flipLR), logical(flipAP), logical(flipIS));
                ok = true;
                obj.setMessage(sprintf('显示翻转：左右=%s 前后=%s 上下=%s（仅影响显示）%s', ...
                    tfText(flipLR), tfText(flipAP), tfText(flipIS), obj.transformHint()));
            catch ME
                obj.setMessage(sprintf('设置翻转失败：%s', ME.message));
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function fl = getFlips(obj)
            % 返回 [左右 前后 上下] 逻辑值
            vi = obj.getViewInfo();
            fl = flipsFromInfo(vi);
        end

        function resetOrientation(obj)
            % 重置所有显示变换（native + 十字线回中心）
            if obj.ensureView()
                try
                    obj.View.resetDisplay();
                    p = obj.View.getCrosshair();
                    if isnumeric(p) && numel(p) >= 3
                        obj.CrosshairVoxel = double(p(1:3));
                    end
                    obj.setMessage(['已重置方位：恢复 native 显示（未修改图像文件）' obj.transformHint()]);
                catch ME
                    obj.setMessage(sprintf('重置方位失败：%s', ME.message));
                end
            else
                obj.setMessage('显示引擎 mrw.QcView 未就绪；已重置视图（无显示变换可清除）');
            end
            obj.refreshViews();
            obj.notifyChangedIfReady();
        end

        function setCrosshairVisible(obj, tf)
            % 三正交十字线开关
            obj.CrosshairVisible = logical(tf);
            try
                if ~isempty(obj.CrosshairCheck) && isvalid(obj.CrosshairCheck)
                    obj.UpdatingViewUI = true;
                    obj.CrosshairCheck.Value = obj.CrosshairVisible;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            if strcmp(obj.ViewMode, 'triple')
                obj.renderTriple();
            else
                obj.refreshViews();
            end
            if strcmp(obj.ViewMode, 'single')
                obj.drawSingleCrosshair();
            end
            obj.maybeWriteState();
        end

        function setColormap(obj, name)
            % 图像色阶：'gray' | 'hot' | 'jet'
            n = normalizeColormapName(name);
            if isempty(n)
                return;
            end
            obj.ColormapName = n;
            try
                if ~isempty(obj.ColormapDropdown) && isvalid(obj.ColormapDropdown) && ...
                        any(strcmp(obj.ColormapDropdown.ItemsData, n))
                    obj.UpdatingViewUI = true;
                    obj.ColormapDropdown.Value = n;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            obj.refreshViews();
            obj.maybeWriteState();
        end

        function setInterp(obj, method)
            % 显示插值：'linear' | 'nearest'（仅非 native 显示模式生效）
            m = normalizeInterpName(method);
            if isempty(m)
                return;
            end
            obj.InterpMethod = m;
            obj.applyViewInterp();
            try
                if ~isempty(obj.InterpDropdown) && isvalid(obj.InterpDropdown) && ...
                        any(strcmp(obj.InterpDropdown.ItemsData, m))
                    obj.UpdatingViewUI = true;
                    obj.InterpDropdown.Value = m;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            obj.refreshViews();
            obj.maybeWriteState();
        end

        function setFilter(obj, mode)
            % 受试者列表筛选：all|unscored|scored|low|meanfd
            fm = normalizeFilterMode(mode);
            if isempty(fm)
                return;
            end
            obj.FilterMode = fm;
            obj.syncFilterSortUi();
            obj.rebuildFilteredIndices();
            obj.rebuildTable();
            obj.updateTableSelection();
            obj.maybeWriteState();
        end

        function setSort(obj, mode)
            % 受试者列表排序：id|score_asc|score_desc|meanfd_asc|meanfd_desc
            sm = normalizeSortMode(mode);
            if isempty(sm)
                return;
            end
            obj.SortMode = sm;
            obj.syncFilterSortUi();
            obj.rebuildFilteredIndices();
            obj.rebuildTable();
            obj.updateTableSelection();
            obj.maybeWriteState();
        end

        function setFdType(obj, fdType)
            % 逐帧 FD 类型：FD_Jenkinson | FD_Power | FD_VanDijk
            t = normalizeFdType(fdType);
            if isempty(t)
                return;
            end
            obj.FdType = t;
            obj.FdThreshold = fdDefaultThreshold(t);
            obj.syncFdUi();
            obj.updateFdCurve();
            obj.notifyChangedIfReady();
        end

        function setFdThreshold(obj, v)
            % 坏帧 FD 阈值（mm）
            if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
                return;
            end
            obj.FdThreshold = max(0.01, min(5, double(v)));
            obj.syncFdUi();
            obj.updateFdCurve();
            obj.maybeWriteState();
        end

        function info = getViewInfo(obj)
            % 显示几何信息（优先 mrw.QcView.getInfo；引擎缺失时返回降级信息）
            if obj.ensureView()
                try
                    info = obj.View.getInfo();
                    if isstruct(info) && isfield(info, 'HasVolume') && logical(info.HasVolume)
                        try
                            c = double(fieldAny(info, {'CrosshairVoxel'}, []));
                            if numel(c) >= 3 && all(isfinite(c(1:3)))
                                obj.CrosshairVoxel = c(1:3);
                            end
                        catch
                        end
                        return;
                    end
                catch
                end
            end
            info = obj.fallbackViewInfo();
        end

        function refreshViews(obj)
            % 按当前视图模式重绘（单视图 / 三正交 / 多切片网格）
            switch obj.ViewMode
                case 'triple'
                    obj.renderTriple();
                case 'montage'
                    obj.renderMontage();
                otherwise
                    if ~isempty(obj.currentSubject())
                        obj.loadCurrentSlice(false);
                    end
            end
            obj.updateCoordLabel();
            obj.updateAlignSummary();
            obj.maybeWriteState();
        end

        function out = exportState(obj, filePath)
            % 把当前 QC 状态写为 schema v2 JSON（默认 <workDir>/QC/.qcviewer_state.json）
            out = obj.buildStateJson();
            obj.LastExportedState = out;
            if nargin < 2 || isempty(filePath)
                filePath = obj.defaultStateFile();
            end
            if isempty(filePath)
                return;
            end
            try
                filePath = char(filePath);
                obj.writeJsonAtomic(filePath, out);
                obj.StateFile = filePath;
            catch
            end
        end

        function result = applyCurrentToData(obj, method)
            % 仅显式确认后的当前图像写出；源文件和显示预览保持不变。
            if nargin < 2, method = 'header-only'; end
            if ~obj.ensureView()
                error('mrw:QcPanel:noVolume', '未加载当前图像，无法应用到数据。');
            end
            payload = struct();
            if strcmp(method, 'resample')
                [data, mat] = obj.View.resampledVolume();
                payload = struct('Data', data, 'Mat', mat);
            end
            result = mrw.QcReorient.apply(obj.currentFile(), obj.WorkDir, ...
                obj.SubjectID, obj.getViewInfo(), method, payload);
        end

        function dlg = openAlignDialog(obj)
            % 打开（或置顶）方位校准对话框；返回 mrw.QcAlignDialog 句柄
            dlg = [];
            try
                if ~isempty(obj.AlignDialog)
                    figOk = false;
                    if isvalid(obj.AlignDialog)
                        try
                            figOk = ~isempty(obj.AlignDialog.Figure) && ...
                                isvalid(obj.AlignDialog.Figure);
                        catch
                            figOk = false;
                        end
                        if figOk
                            dlg = obj.AlignDialog;
                            try, dlg.raise(); catch, end
                            return;
                        end
                    end
                    % 已关闭/已删除（外部 delete 或关闭按钮）：重建
                    obj.AlignDialog = [];
                end
            catch
                try, obj.AlignDialog = []; catch, end
            end
            try
                dlg = mrw.QcAlignDialog(obj);
                obj.AlignDialog = dlg;
            catch ME
                obj.AlignDialog = [];
                obj.setMessage(sprintf('打开方位校准对话框失败：%s', ME.message));
            end
        end

        function ok = clickViewAt(obj, orient, x, y)
            % 测试/辅助入口：在指定视图（或当前方向多切片网格）的 data 坐标 (x,y) 点击
            ok = false;
            if ~isnumeric(x) || ~isscalar(x) || ~isfinite(x) || ...
                    ~isnumeric(y) || ~isscalar(y) || ~isfinite(y)
                return;
            end
            if strcmp(obj.ViewMode, 'montage')
                ok = obj.clickMontageAt(x, y);
                return;
            end
            o = normalizeOrientationValue(orient);
            if isempty(o) || ~any(strcmp(obj.ViewMode, {'single', 'triple'}))
                return;
            end
            if strcmp(obj.ViewMode, 'triple'), obj.setActiveOrientation(o, false); end
            if obj.ensureView()
                fld = tripleFieldName(o);
                if strcmp(obj.ViewMode, 'single'), info = obj.SingleInfo;
                else, info = obj.TripleInfo.(fld); end
                if isempty(fieldnames(info))
                    try
                        info = obj.viewInfoSafe();
                    catch
                        info = struct();
                    end
                end
                d = obj.clickToDisplayPoint(o, info, x, y);
                if ~isempty(d)
                    try
                        v = obj.View.displayToVoxel(d);
                        v = double(v(1:3));
                        if all(isfinite(v))
                            obj.setCrosshairVoxel(v);
                            ok = true;
                            return;
                        end
                    catch
                    end
                end
            end
            % 降级：原生像素映射
            v = obj.fallbackClickToVoxel(o, x, y);
            if ~isempty(v)
                obj.setCrosshairVoxel(v);
                ok = true;
            end
        end
    end

    methods (Access = private)

        % ---------------- v2：底部头动条（FD 曲线，契约 §5.5） ----------------
        function buildMotion(obj)
            c = obj.Colors;
            f = obj.Fonts;

            fp = uipanel(obj.Root, 'Title', '', ...
                'FontName', f.name, 'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            fp.Layout.Row = 3;
            fp.Tag = 'qcMotionPanel';
            obj.MotionPanel = fp;

            outer = uigridlayout(fp, [2 1]);
            outer.RowHeight = {28, 0};
            outer.ColumnWidth = {'1x'};
            outer.Padding = [2 1 2 1];
            outer.RowSpacing = 0;
            outer.BackgroundColor = c.panel;
            obj.MotionLayout = outer;
            obj.FdToggle = mrw.UiKit.button(outer, '展开头动与 FD 曲线（Head Motion · FD）', ...
                'Callback', @(~,~) obj.toggleFd());
            obj.FdToggle.Tag = 'qcFdToggle';
            obj.FdToggle.Layout.Row = 1;
            mrw.UiKit.tip(obj.FdToggle, '展开或收起逐帧 FD 曲线、FD 类型、坏帧阈值和头动统计；收起时保留当前设置。');
            g = uigridlayout(outer, [1 2]);
            g.Layout.Row = 2;
            g.Tag = 'qcFdBody';
            g.Visible = 'off';
            obj.MotionBody = g;
            g.RowHeight = {'1x'};
            g.ColumnWidth = {330, '1x'};
            g.Padding = [8 4 8 4];
            g.ColumnSpacing = 10;
            g.BackgroundColor = c.panel;

            cg = uigridlayout(g, [5 1]);
            cg.RowHeight = {20, 28, 28, '1x', 18};
            cg.ColumnWidth = {'1x'};
            cg.Padding = [0 0 0 0];
            cg.RowSpacing = 4;
            cg.BackgroundColor = c.panel;
            cg.Layout.Column = 1;

            obj.FdTitleLabel = uilabel(cg, 'Text', 'FD 曲线：未选择受试者', ...
                'FontName', f.name, 'FontSize', f.small, 'FontWeight', 'bold', ...
                'FontColor', c.text, 'BackgroundColor', c.panel, 'Tag', 'qcFdTitle');
            obj.FdTitleLabel.Layout.Row = 1;
            mrw.UiKit.tip(obj.FdTitleLabel, mrw.UiKit.wrapTooltip({ ...
                '当前受试者的逐帧 FD 曲线标题（受试者 ID · FD 类型 · 坏帧阈值）。', ...
                '已保存评分 ≤2 分时标题变红并附“⚠ 低分需复核”提示（确定性提示，不代替人工 QC 结论）。'}));

            tg = uigridlayout(cg, [1 2]);
            tg.RowHeight = {'1x'};
            tg.ColumnWidth = {64, '1x'};
            tg.Padding = [0 0 0 0];
            tg.ColumnSpacing = 6;
            tg.BackgroundColor = c.panel;
            tg.Layout.Row = 2;
            lbT = uilabel(tg, 'Text', 'FD 类型', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lbT, '逐帧 FD 类型：Jenkinson（默认阈值 0.2 mm）/ Power（默认 0.5 mm）/ VanDijk。');
            obj.FdTypeDropdown = uidropdown(tg, ...
                'Items', {'FD_Jenkinson', 'FD_Power', 'FD_VanDijk'}, ...
                'ItemsData', {'FD_Jenkinson', 'FD_Power', 'FD_VanDijk'}, ...
                'Value', 'FD_Jenkinson', 'FontName', f.name, 'FontSize', f.small, ...
                'Tag', 'qcFdType', 'ValueChangedFcn', @(s, e) obj.onFdTypeChanged());
            obj.FdTypeDropdown.Layout.Column = 2;
            mrw.UiKit.tip(obj.FdTypeDropdown, mrw.UiKit.wrapTooltip({ ...
                '切换逐帧 FD 文件类型（RealignParameter/<ID>/FD_<类型>_<ID>.txt）。', ...
                '切换后坏帧阈值自动恢复该类型默认值：Jenkinson/VanDijk 0.2 mm、Power 0.5 mm。'}));

            wg = uigridlayout(cg, [1 2]);
            wg.RowHeight = {'1x'};
            wg.ColumnWidth = {64, '1x'};
            wg.Padding = [0 0 0 0];
            wg.ColumnSpacing = 6;
            wg.BackgroundColor = c.panel;
            wg.Layout.Row = 3;
            lbW = uilabel(wg, 'Text', '坏帧阈值', 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', c.text, 'BackgroundColor', c.panel);
            mrw.UiKit.tip(lbW, '逐帧坏帧判定阈值（mm）：FD > 阈值视为坏帧，在曲线上标红点。');
            obj.FdThresholdField = uieditfield(wg, 'numeric', 'Value', 0.2, ...
                'Limits', [0.01 5], 'ValueDisplayFormat', '%.2f', ...
                'FontName', f.name, 'FontSize', f.small, 'Tag', 'qcFdThreshold', ...
                'ValueChangedFcn', @(s, e) obj.onFdThresholdChanged());
            obj.FdThresholdField.Layout.Column = 2;
            mrw.UiKit.tip(obj.FdThresholdField, mrw.UiKit.wrapTooltip({ ...
                '坏帧阈值（mm，0.01–5）：逐帧 FD 超过该值的帧记为坏帧，在曲线上以红点显示。', ...
                '常用 0.2 mm（Jenkinson）或 0.5 mm（Power）；是否剔除坏帧由研究方案决定，本面板只显示。'}));

            obj.FdStatsLabel = uilabel(cg, 'Text', '—', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, 'BackgroundColor', c.panel, ...
                'Tag', 'qcFdStats', 'VerticalAlignment', 'top');
            obj.FdStatsLabel.Layout.Row = 4;
            try, obj.FdStatsLabel.WordWrap = 'on'; catch, end
            mrw.UiKit.tip(obj.FdStatsLabel, mrw.UiKit.wrapTooltip({ ...
                '统计：MeanFD、最大 FD、坏帧数/占比（逐帧 FD 文件），', ...
                '最大平移/旋转（RealignParameter/HeadMotion.tsv）。'}));

            hint = uilabel(cg, 'Text', '曲线：蓝线 = 逐帧 FD；红虚线 = 阈值；红点 = 坏帧', ...
                'FontName', f.name, 'FontSize', f.small, 'FontColor', c.muted, ...
                'BackgroundColor', c.panel);
            hint.Layout.Row = 5;
            mrw.UiKit.tip(hint, '提示：切换受试者/表格行时曲线自动同步；FD 值来自 RealignParameter 的逐帧 FD 文件。');

            ax = uiaxes(g);
            ax.Layout.Column = 2;
            ax.Tag = 'qcFdAxes';
            try, ax.Color = [0.078 0.086 0.106]; catch, end
            try, ax.XColor = c.border; ax.YColor = c.border; catch, end
            try, ax.FontName = f.name; ax.FontSize = f.small; catch, end
            try, ax.Box = 'on'; catch, end
            try, ax.Toolbar.Visible = 'off'; catch, end
            try, disableDefaultInteractivity(ax); catch, end
            try, ax.Interactions = []; catch, end
            try
                xlabel(ax, '帧号（删点后 1-based）', 'FontName', f.name, 'FontSize', f.small);
                ylabel(ax, 'FD (mm)', 'FontName', f.name, 'FontSize', f.small);
                title(ax, 'FD 曲线', 'FontName', f.name, 'FontSize', f.small);
                grid(ax, 'on');
            catch
            end
            obj.FdAxes = ax;
            mrw.UiKit.tip(ax, mrw.UiKit.wrapTooltip({ ...
                '逐帧 FD 曲线：折线 = FD 值，红色虚线 = 坏帧阈值，红点 = 坏帧。', ...
                '横轴帧号为删点后 1-based；与评分联动：当前受试者已保存评分 ≤2 时标题红色警示。'}));
        end

        function toggleFd(obj)
            obj.FdExpanded = ~obj.FdExpanded;
            heights = obj.Root.RowHeight;
            if obj.FdExpanded
                heights{3} = 220;
                obj.MotionLayout.RowHeight = {28, '1x'};
                obj.MotionBody.Visible = 'on';
                obj.FdToggle.Text = '收起头动与 FD 曲线（Head Motion · FD）';
            else
                heights{3} = 32;
                obj.MotionLayout.RowHeight = {28, 0};
                obj.MotionBody.Visible = 'off';
                obj.FdToggle.Text = '展开头动与 FD 曲线（Head Motion · FD）';
            end
            obj.Root.RowHeight = heights;
        end

        function syncFdUi(obj)
            try
                if ~isempty(obj.FdTypeDropdown) && isvalid(obj.FdTypeDropdown) && ...
                        any(strcmp(obj.FdTypeDropdown.ItemsData, obj.FdType))
                    obj.UpdatingFdUI = true;
                    obj.FdTypeDropdown.Value = obj.FdType;
                    obj.UpdatingFdUI = false;
                end
            catch
            end
            try
                if ~isempty(obj.FdThresholdField) && isvalid(obj.FdThresholdField)
                    obj.UpdatingFdUI = true;
                    obj.FdThresholdField.Value = obj.FdThreshold;
                    obj.UpdatingFdUI = false;
                end
            catch
            end
        end

        function fd = loadFdSeries(obj, subjectID, fdType)
            % 优先 QcModel.loadFdSeries（契约 §4），缺失时面板内兜底扫描文件
            fd = fdBaseStruct(fdType, fdDefaultThreshold(fdType));
            fd.ID = subjectID;
            if isempty(subjectID) || isempty(obj.WorkDir)
                fd.Message = '未选择受试者或工作目录';
                return;
            end
            r = [];
            try
                if exist('mrw.QcModel', 'class') == 8
                    r = mrw.QcModel.loadFdSeries(obj.WorkDir, subjectID, fdType);
                end
            catch
                r = [];
            end
            if isstruct(r) && isfield(r, 'Available') && logical(fieldOr(r, 'Available', false))
                vals = double(r.Values(:).');
                vals = vals(isfinite(vals));
                if ~isempty(vals)
                    fd.Available = true;
                    fd.Values = vals;
                    fd.File = char(fieldAny(r, {'File'}, ''));
                    fd.Message = char(fieldAny(r, {'Message'}, ''));
                    dt = double(fieldAny(r, {'DefaultThreshold'}, NaN));
                    if isfinite(dt) && dt > 0
                        fd.DefaultThreshold = dt;
                    end
                    return;
                end
            end
            [file, vals] = obj.scanFdFile(subjectID, fdType);
            if ~isempty(file) && ~isempty(vals)
                fd.Available = true;
                fd.Values = vals;
                fd.File = file;
            else
                fd.Message = sprintf('未找到 %s 逐帧 FD 文件（RealignParameter/%s/FD_%s_%s.txt）', ...
                    fdType, subjectID, fdType, subjectID);
            end
        end

        function [file, vals] = scanFdFile(obj, subjectID, fdType)
            file = '';
            vals = [];
            if isempty(obj.WorkDir) || exist(obj.WorkDir, 'dir') ~= 7
                return;
            end
            dirs = {fullfile(obj.WorkDir, 'RealignParameter', subjectID), ...
                fullfile(obj.WorkDir, 'RealignParameter')};
            pats = {sprintf('FD_%s_%s.txt', fdType, subjectID), ...
                sprintf('FD_%s_%s*.txt', fdType, subjectID), ...
                sprintf('FD_%s_*.txt', fdType), ...
                sprintf('FD_%s*.txt', fdType)};
            for d = 1:numel(dirs)
                if exist(dirs{d}, 'dir') ~= 7
                    continue;
                end
                for p = 1:numel(pats)
                    cand = dir(fullfile(dirs{d}, pats{p}));
                    for i = 1:numel(cand)
                        f = fullfile(cand(i).folder, cand(i).name);
                        v = obj.readFdValues(f);
                        if ~isempty(v)
                            file = f;
                            vals = v;
                            return;
                        end
                    end
                end
            end
        end

        function v = readFdValues(~, filePath)
            v = [];
            try
                txt = fileread(filePath);
            catch
                return;
            end
            nums = regexp(txt, '[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?', 'match');
            if isempty(nums)
                return;
            end
            v = str2double(nums);
            v = v(isfinite(v));
            if isempty(v)
                return;
            end
            v = double(v(:).');
        end

        function [meanFD, maxT, maxR] = hmStatsForSubject(obj, sid)
            meanFD = NaN;
            maxT = NaN;
            maxR = NaN;
            hm = obj.HeadMotion;
            if ~isstruct(hm) || ~isfield(hm, 'Available') || isempty(sid)
                return;
            end
            if ~logical(fieldOr(hm, 'Available', false))
                return;
            end
            ids = fieldOr(hm, 'IDs', {});
            if isstring(ids)
                ids = cellstr(ids);
            elseif ischar(ids)
                ids = {ids};
            end
            if ~iscell(ids) || isempty(ids)
                return;
            end
            k = find(strcmp(ids, sid), 1);
            if isempty(k)
                return;
            end
            mf = fieldOr(hm, 'MeanFD', []);
            if numel(mf) >= k && isfinite(mf(k))
                meanFD = double(mf(k));
            end
            mt = fieldOr(hm, 'MaxTrans', []);
            if numel(mt) >= k && isfinite(mt(k))
                maxT = double(mt(k));
            end
            tb = fieldOr(hm, 'Table', []);
            if isnumeric(tb) && size(tb, 1) >= k && size(tb, 2) >= 6
                rr = tb(k, 4:6);
                rr = rr(isfinite(rr));
                if ~isempty(rr)
                    maxR = max(abs(rr));
                end
            end
        end

        function updateFdCurve(obj)
            if isempty(obj.FdAxes) || ~isvalid(obj.FdAxes)
                return;
            end
            ax = obj.FdAxes;
            try, cla(ax); catch, end
            obj.FdLine = [];
            obj.FdThreshLine = [];
            obj.FdBadLine = [];
            sid = obj.SubjectID;
            if isempty(sid)
                obj.Fd = fdBaseStruct(obj.FdType, obj.FdThreshold);
                try, title(ax, 'FD 曲线 · 未选择受试者', 'Interpreter', 'none'); catch, end
                obj.setFdTitle('FD 曲线：未选择受试者', false);
                obj.setFdStats('MeanFD — · 最大 FD — · 坏帧 — · 最大平移/旋转 —', false);
                return;
            end
            fd = obj.loadFdSeries(sid, obj.FdType);
            fd.Threshold = obj.FdThreshold;
            obj.Fd = fd;
            if ~fd.Available || isempty(fd.Values)
                try
                    title(ax, sprintf('%s · %s', sid, fdTypeLabel(obj.FdType)), 'Interpreter', 'none');
                    text(ax, 0.5, 0.5, wrapChars(['无逐帧 FD 数据：' fd.Message], 30), ...
                        'Units', 'normalized', 'HorizontalAlignment', 'center', ...
                        'VerticalAlignment', 'middle', 'Color', [0.78 0.81 0.86], ...
                        'FontName', obj.Fonts.name, 'FontSize', 10, 'Interpreter', 'none');
                catch
                end
                obj.setFdTitle(sprintf('FD 曲线 · %s · 无数据', sid), false);
                obj.setFdStats(fd.Message, false);
                return;
            end
            vals = double(fd.Values(:).');
            n = numel(vals);
            thr = obj.FdThreshold;
            bad = find(vals > thr);
            meanFD = mean(vals);
            maxFD = max(vals);
            ratio = numel(bad) / max(1, n);
            obj.Fd.MeanFD = meanFD;
            obj.Fd.MaxFD = maxFD;
            obj.Fd.BadFrames = bad;
            obj.Fd.BadRatio = ratio;
            try
                hold(ax, 'on');
                obj.FdLine = plot(ax, 1:n, vals, '-', ...
                    'Color', obj.Colors.accent, 'LineWidth', 1.2);
                obj.FdThreshLine = plot(ax, [1 max(2, n)], [thr thr], '--', ...
                    'Color', obj.Colors.err, 'LineWidth', 1.0);
                if ~isempty(bad)
                    obj.FdBadLine = plot(ax, bad, vals(bad), 'o', 'MarkerSize', 4, ...
                        'MarkerFaceColor', obj.Colors.err, 'MarkerEdgeColor', obj.Colors.err);
                end
                hold(ax, 'off');
                xlim(ax, [1 max(2, n)]);
                ylim(ax, [0 max(maxFD * 1.18, thr * 1.35)]);
            catch
            end
            saved = obj.savedScoreFor(sid);
            lowWarning = isfinite(saved) && saved <= 2;
            ttl = sprintf('%s · %s（阈值 %.2f mm）', sid, fdTypeLabel(obj.FdType), thr);
            labelTxt = sprintf('FD 曲线 · %s', sid);
            if lowWarning
                ttl = [ttl ' · ⚠ 低分需复核']; %#ok<AGROW>
                labelTxt = [labelTxt ' · ⚠ 低分需复核']; %#ok<AGROW>
            end
            try, title(ax, ttl, 'Interpreter', 'none'); catch, end
            obj.setFdTitle(labelTxt, lowWarning);
            [tsvMeanFD, maxT, maxR] = obj.hmStatsForSubject(sid);
            statsTxt = sprintf(['MeanFD(TSV) %.4f mm · 序列均值 %.4f mm · 最大 FD %.4f mm\n' ...
                '坏帧 %d/%d（%.1f%%）· 最大平移 %.3f mm · 最大旋转 %.3f°'], ...
                tsvMeanFD, meanFD, maxFD, numel(bad), n, ratio * 100, maxT, maxR);
            obj.setFdStats(statsTxt, lowWarning);
        end

        function setFdTitle(obj, txt, warn)
            if isempty(obj.FdTitleLabel) || ~isvalid(obj.FdTitleLabel)
                return;
            end
            try
                obj.FdTitleLabel.Text = txt;
                if logical(warn)
                    obj.FdTitleLabel.FontColor = obj.Colors.err;
                    obj.FdTitleLabel.FontWeight = 'bold';
                else
                    obj.FdTitleLabel.FontColor = obj.Colors.text;
                    obj.FdTitleLabel.FontWeight = 'bold';
                end
            catch
            end
        end

        function setFdStats(obj, txt, warn)
            if isempty(obj.FdStatsLabel) || ~isvalid(obj.FdStatsLabel)
                return;
            end
            try
                obj.FdStatsLabel.Text = toTextValue(txt);
                if logical(warn)
                    obj.FdStatsLabel.FontColor = obj.Colors.err;
                else
                    obj.FdStatsLabel.FontColor = obj.Colors.muted;
                end
            catch
            end
        end

        function onFdTypeChanged(obj)
            if obj.UpdatingFdUI
                return;
            end
            v = '';
            try, v = obj.FdTypeDropdown.Value; catch, end
            t = normalizeFdType(v);
            if isempty(t) || strcmp(t, obj.FdType)
                return;
            end
            obj.FdType = t;
            obj.FdThreshold = fdDefaultThreshold(t);
            obj.syncFdUi();
            obj.updateFdCurve();
            obj.writeStateNow();
        end

        function onFdThresholdChanged(obj)
            if obj.UpdatingFdUI
                return;
            end
            v = [];
            try, v = obj.FdThresholdField.Value; catch, end
            if isempty(v) || ~isnumeric(v) || ~isfinite(v)
                return;
            end
            obj.FdThreshold = max(0.01, min(5, double(v)));
            obj.syncFdUi();
            obj.updateFdCurve();
            obj.writeStateNow();
        end

        % ---------------- v2：筛选 / 排序（契约 §5.2） ----------------
        function syncFilterSortUi(obj)
            try
                if ~isempty(obj.FilterDropdown) && isvalid(obj.FilterDropdown) && ...
                        any(strcmp(obj.FilterDropdown.ItemsData, obj.FilterMode))
                    obj.UpdatingFilterUI = true;
                    obj.FilterDropdown.Value = obj.FilterMode;
                    obj.UpdatingFilterUI = false;
                end
            catch
            end
            try
                if ~isempty(obj.SortDropdown) && isvalid(obj.SortDropdown) && ...
                        any(strcmp(obj.SortDropdown.ItemsData, obj.SortMode))
                    obj.UpdatingFilterUI = true;
                    obj.SortDropdown.Value = obj.SortMode;
                    obj.UpdatingFilterUI = false;
                end
            catch
            end
            try
                if ~isempty(obj.OnlyUnscoredCheck) && isvalid(obj.OnlyUnscoredCheck)
                    obj.UpdatingFilterUI = true;
                    obj.OnlyUnscoredCheck.Value = strcmp(obj.FilterMode, 'unscored');
                    obj.UpdatingFilterUI = false;
                end
            catch
            end
        end

        function mask = filterMask(obj)
            n = numel(obj.SubjectList);
            mask = true(1, n);
            if n == 0 || strcmp(obj.FilterMode, 'all')
                return;
            end
            thr = obj.meanFDThreshold();
            for i = 1:n
                id = obj.SubjectList{i}.ID;
                sc = obj.scoreFor(id);
                switch obj.FilterMode
                    case 'unscored'
                        mask(i) = ~isfinite(sc.Score);
                    case 'scored'
                        mask(i) = isfinite(sc.Score);
                    case 'low'
                        mask(i) = isfinite(sc.Score) && sc.Score <= obj.MinScore;
                    case 'meanfd'
                        v = obj.meanFDFor(id);
                        mask(i) = isfinite(v) && v > thr;
                    otherwise
                        mask(i) = true;
                end
            end
        end

        function v = meanFDFor(obj, id)
            v = NaN;
            hm = obj.HeadMotion;
            if ~isstruct(hm) || ~isfield(hm, 'Available') || ~logical(fieldOr(hm, 'Available', false))
                return;
            end
            ids = fieldOr(hm, 'IDs', {});
            if isstring(ids)
                ids = cellstr(ids);
            elseif ischar(ids)
                ids = {ids};
            end
            if ~iscell(ids)
                return;
            end
            k = find(strcmp(ids, id), 1);
            mf = fieldOr(hm, 'MeanFD', []);
            if ~isempty(k) && numel(mf) >= k && isfinite(mf(k))
                v = double(mf(k));
            end
        end

        function thr = meanFDThreshold(obj)
            thr = 0.2;
            if isfield(obj.Thresholds, 'MaxMeanFD') && isnumeric(obj.Thresholds.MaxMeanFD) && ...
                    isscalar(obj.Thresholds.MaxMeanFD) && isfinite(obj.Thresholds.MaxMeanFD)
                thr = double(obj.Thresholds.MaxMeanFD);
            end
        end

        function idx = sortFilteredIndices(obj, idx)
            idx = idx(:)';
            n = numel(idx);
            if n <= 1
                return;
            end
            keys = inf(1, n);
            switch obj.SortMode
                case 'score_asc'
                    for k = 1:n
                        s = obj.scoreFor(obj.SubjectList{idx(k)}.ID);
                        if isfinite(s.Score)
                            keys(k) = s.Score;
                        end
                    end
                case 'score_desc'
                    for k = 1:n
                        s = obj.scoreFor(obj.SubjectList{idx(k)}.ID);
                        if isfinite(s.Score)
                            keys(k) = -s.Score;
                        end
                    end
                case 'meanfd_asc'
                    for k = 1:n
                        v = obj.meanFDFor(obj.SubjectList{idx(k)}.ID);
                        if isfinite(v)
                            keys(k) = v;
                        end
                    end
                case 'meanfd_desc'
                    for k = 1:n
                        v = obj.meanFDFor(obj.SubjectList{idx(k)}.ID);
                        if isfinite(v)
                            keys(k) = -v;
                        end
                    end
                otherwise
                    % 受试者 ID 自然排序
                    ids = cell(1, n);
                    for k = 1:n
                        ids{k} = obj.SubjectList{idx(k)}.ID;
                    end
                    sortedIds = naturalSortLocal(ids);
                    out = zeros(1, n);
                    used = false(1, n);
                    for k = 1:n
                        pos = find(strcmp(ids, sortedIds{k}), 1);
                        if isempty(pos) || used(pos)
                            pos = find(~used, 1);
                        end
                        used(pos) = true;
                        out(k) = idx(pos);
                    end
                    idx = out;
                    return;
            end
            [~, ord] = sort(keys);
            idx = idx(ord);
        end

        function onFilterChanged(obj)
            if obj.UpdatingFilterUI
                return;
            end
            v = '';
            try, v = obj.FilterDropdown.Value; catch, end
            obj.setFilter(v);
        end

        function onSortChanged(obj)
            if obj.UpdatingFilterUI
                return;
            end
            v = '';
            try, v = obj.SortDropdown.Value; catch, end
            obj.setSort(v);
        end

        % ---------------- v2：视图模式 UI 同步 / 回调 ----------------
        function syncViewModeUI(obj)
            try
                if ~isempty(obj.ViewModeDropdown) && isvalid(obj.ViewModeDropdown) && ...
                        any(strcmp(obj.ViewModeDropdown.ItemsData, obj.ViewMode))
                    obj.UpdatingViewUI = true;
                    obj.ViewModeDropdown.Value = obj.ViewMode;
                    obj.UpdatingViewUI = false;
                end
            catch
            end
            if isempty(obj.ViewHost) || ~isvalid(obj.ViewHost)
                return;
            end
            switch obj.ViewMode
                case 'triple'
                    if ~obj.TripleBuilt
                        obj.buildTripleView();
                    end
                case 'montage'
                    if ~obj.MontageBuilt
                        obj.buildMontageView();
                    end
                otherwise
            end
            % 三个视图容器各占一行，用 RowHeight 互斥显示（同一格多个 child 会被平分高度）
            try
                switch obj.ViewMode
                    case 'triple'
                        obj.ViewHost.RowHeight = {0, '1x', 0};
                    case 'montage'
                        obj.ViewHost.RowHeight = {0, 0, '1x'};
                    otherwise
                        obj.ViewHost.RowHeight = {'1x', 0, 0};
                end
            catch
            end
            try
                setVisible(obj.SingleViewGrid, strcmp(obj.ViewMode, 'single'));
                setVisible(obj.TripleViewGrid, strcmp(obj.ViewMode, 'triple'));
                setVisible(obj.MontageViewGrid, strcmp(obj.ViewMode, 'montage'));
                setVisible(obj.TripleInfoPanel, strcmp(obj.ViewMode, 'triple'));
                rh = obj.RightGrid.RowHeight;
                if strcmp(obj.ViewMode, 'triple'), rh{21} = 180; else, rh{21} = 0; end
                obj.RightGrid.RowHeight = rh;
            catch
            end
            obj.layoutTripleViews();
            obj.syncViewModeTitle();
        end

        function layoutToolbar(obj)
            if isempty(obj.ProgressBadge) || ~isvalid(obj.ToolbarGrid), return; end
            controls = {obj.TitleLabel, obj.WorkdirField, obj.BrowseButton, obj.RescanButton, ...
                obj.ModalityDropdown, obj.ViewModeDropdown, obj.CopyStateButton, obj.ProgressBadge};
            rh = obj.Root.RowHeight;
            if obj.Toolbar.InnerPosition(3) < 1260
                obj.ToolbarGrid.RowHeight = {'1x', '1x'};
                for k = 1:8
                    controls{k}.Layout.Row = ceil(k/4);
                    controls{k}.Layout.Column = mod(k-1,4)+1;
                end
                obj.ToolbarGrid.ColumnWidth = {196, '1x', 132, 118};
                rh{1} = 80;
            else
                obj.ToolbarGrid.ColumnWidth = {196, '1x', 74, 84, 168, 148, 132, 118};
                for k = 1:8
                    controls{k}.Layout.Row = 1;
                    controls{k}.Layout.Column = k;
                end
                obj.ToolbarGrid.RowHeight = {'1x'};
                rh{1} = 44;
            end
            if ~isequal(obj.Root.RowHeight, rh), obj.Root.RowHeight = rh; end
        end

        function syncViewModeTitle(obj)
            try
                switch obj.ViewMode
                    case 'triple'
                        obj.FileTitleLabel.Text = sprintf('三正交 · 活动%s · 十字线 %s', ...
                            tripleLabel(obj.ActiveOrientation), fmtVec3(obj.getCrosshairVoxel(), '%.0f'));
                    case 'montage'
                        obj.FileTitleLabel.Text = sprintf('多切片网格 · %s · 第 %d/%d 层', ...
                            tripleLabel(obj.Orientation), obj.SliceIndex, obj.SliceCount);
                    otherwise
                        % 单视图由 updateImageTitle 负责
                end
            catch
            end
        end

        function onViewModeChanged(obj)
            if obj.UpdatingViewUI
                return;
            end
            v = 'single';
            try, v = obj.ViewModeDropdown.Value; catch, end
            obj.setViewMode(v);
        end

        function onColormapChanged(obj)
            if obj.UpdatingViewUI
                return;
            end
            v = 'gray';
            try, v = obj.ColormapDropdown.Value; catch, end
            obj.setColormap(v);
        end

        function onInterpChanged(obj)
            if obj.UpdatingViewUI
                return;
            end
            v = 'linear';
            try, v = obj.InterpDropdown.Value; catch, end
            obj.setInterp(v);
        end

        function onCrosshairChecked(obj)
            if obj.UpdatingViewUI
                return;
            end
            tf = true;
            try, tf = logical(obj.CrosshairCheck.Value); catch, end
            obj.setCrosshairVisible(tf);
        end

        function onResetAlignPressed(obj)
            obj.resetOrientation();
        end

        function onCopyStatePressed(obj)
            try
                s = obj.buildStateJson();
                txt = jsonencode(s);
            catch ME
                obj.setMessage(sprintf('生成 QC 状态摘要失败：%s', ME.message));
                return;
            end
            copied = false;
            try
                clipboard('copy', txt);
                copied = true;
            catch
            end
            try
                f = obj.defaultStateFile();
                if ~isempty(f)
                    obj.writeJsonAtomic(f, s);
                    obj.StateFile = f;
                end
            catch
            end
            if copied
                obj.setMessage('已复制当前 QC 状态；可在 DSH 对话中让 Agent 读取实时指导（同时写入 QC/.qcviewer_state.json）');
            else
                obj.setMessage('已写入 QC/.qcviewer_state.json（剪贴板不可用）；可在 DSH 对话中让 Agent 读取实时指导');
            end
            obj.updateFooter();
        end

        % ---------------- v2：状态 JSON（契约 §7） ----------------
        function f = defaultStateFile(obj)
            f = '';
            if isempty(obj.WorkDir) || exist(obj.WorkDir, 'dir') ~= 7
                return;
            end
            qcDir = fullfile(obj.WorkDir, 'QC');
            if exist(qcDir, 'dir') ~= 7
                try, mkdir(qcDir); catch, end
            end
            if exist(qcDir, 'dir') ~= 7
                return;
            end
            f = fullfile(qcDir, '.qcviewer_state.json');
        end

        function s = buildStateJson(obj)
            st = obj.getState();
            vi = obj.getViewInfo();
            c = obj.getCrosshairVoxel();
            [cw, cd] = obj.crosshairWorldDisplay(c);
            mode = lower(char(fieldAny(vi, {'Mode'}, 'native')));
            acpc = fieldAny(vi, {'ACPC'}, struct());
            [manT, manR] = manualFromInfo(vi);
            fl = flipsFromInfo(vi);
            s = struct();
            s.schema = 'mrw.qcviewer.state.v2';
            s.version = 2;
            s.updatedAt = nowIsoLocal();
            s.workDir = obj.WorkDir;
            s.modality = obj.ModalityKey;
            s.modalityLabel = obj.modalityLabel();
            s.subjectID = obj.SubjectID;
            s.subjectIndex = obj.SubjectIndex;
            s.subjectCount = numel(obj.SubjectList);
            s.file = obj.currentFile();
            s.viewMode = obj.ViewMode;
            s.activeOrientation = obj.ActiveOrientation;
            s.crosshairVoxel = vecOrEmpty(c, 3);
            s.crosshairWorld = vecOrEmpty(cw, 3);
            s.crosshairDisplay = vecOrEmpty(cd, 3);
            dm = fieldAny(vi, {'DisplayMatrix'}, eye(4));
            if ~isnumeric(dm) || numel(dm) < 16
                dm = eye(4);
            end
            s.display = struct( ...
                'mode', mode, ...
                'hasVolume', logical(fieldAny(vi, {'HasVolume'}, false)), ...
                'matrix', double(reshape(dm(1:16), 4, 4)), ...
                'acVoxel', vecOrEmpty(fieldAny(vi, {'ACVoxel'}, []), 3), ...
                'pcVoxel', vecOrEmpty(fieldAny(vi, {'PCVoxel'}, []), 3), ...
                'acWorld', vecOrEmpty(fieldAny(vi, {'ACWorld'}, []), 3), ...
                'pcWorld', vecOrEmpty(fieldAny(vi, {'PCWorld'}, []), 3), ...
                'distanceMm', double(fieldAny(acpc, {'distanceMm', 'DistanceMm'}, NaN)), ...
                'angleDeg', double(fieldAny(acpc, {'angleDeg', 'AngleDeg'}, NaN)), ...
                'manualTranslationMm', manT, ...
                'manualRotationDeg', manR, ...
                'flips', struct('lr', logical(fl(1)), 'ap', logical(fl(2)), 'is', logical(fl(3))), ...
                'message', char(fieldAny(vi, {'Message'}, '')));
            orients = {'axial', 'coronal', 'sagittal'};
            slices = struct();
            dims = obj.currentVolumeDims();
            for i = 1:numel(orients)
                o = orients{i};
                idx = [];
                cnt = [];
                if obj.ensureView()
                    try, idx = double(obj.View.currentSliceIndex(o)); catch, end
                    cnt = obj.viewSliceCount(o);
                end
                if isempty(idx) || ~isfinite(idx) || isempty(cnt) || ~isfinite(cnt)
                    if ~isempty(dims)
                        switch o
                            case 'axial'
                                idx = max(1, min(dims(3), round(c(3))));
                                cnt = dims(3);
                            case 'coronal'
                                idx = max(1, min(dims(2), round(c(2))));
                                cnt = dims(2);
                            otherwise
                                idx = max(1, min(dims(1), round(c(1))));
                                cnt = dims(1);
                        end
                    else
                        idx = 1;
                        cnt = 0;
                    end
                end
                slices.(o) = struct('index', double(round(idx)), 'count', double(round(cnt)));
            end
            s.slices = slices;
            s.window = double(st.Window);
            s.clim = double(vecOrEmpty(obj.Clim, 2));
            s.colormap = obj.ColormapName;
            s.interp = obj.InterpMethod;
            s.zoom = double(st.Zoom);
            s.crosshairVisible = logical(obj.CrosshairVisible);
            s.overlay = struct('visible', logical(obj.OverlayVisible), ...
                'alpha', double(obj.OverlayAlpha), 'normKind', obj.NormKind);
            saved = obj.savedScoreFor(obj.SubjectID);
            if ~isfinite(saved)
                saved = NaN;
            end
            s.score = struct('current', double(obj.Score), 'saved', double(saved));
            fd = obj.Fd;
            vals = [];
            if isstruct(fd) && isfield(fd, 'Values') && ~isempty(fd.Values)
                vals = double(fd.Values(:).');
            end
            [tsvMeanFD, maxT, maxR] = obj.hmStatsForSubject(obj.SubjectID);
            seriesMeanFD = NaN;
            maxFD = NaN;
            bad = zeros(1, 0);
            if ~isempty(vals)
                seriesMeanFD = mean(vals);
                maxFD = max(vals);
                bad = find(vals > obj.FdThreshold);
            end
            % meanFD 与窗口/通过名单一致：HeadMotion.tsv 第 21 列；缺失时退回序列均值
            meanFD = tsvMeanFD;
            if ~isfinite(meanFD)
                meanFD = seriesMeanFD;
            end
            s.headMotion = struct( ...
                'fdType', obj.FdType, 'fdThreshold', double(obj.FdThreshold), ...
                'values', vals, 'meanFD', double(meanFD), ...
                'seriesMeanFD', double(seriesMeanFD), ...
                'meanFDSource', 'HeadMotion.tsv#meanFD_Jenkinson', ...
                'maxFD', double(maxFD), ...
                'badFrames', double(bad), ...
                'badRatio', numel(bad) / max(1, numel(vals)), ...
                'maxTranslation', double(maxT), 'maxRotation', double(maxR));
            s.filter = obj.FilterMode;
            s.sort = obj.SortMode;
            ps = obj.progressSummary();
            keys = {'T1', 'Fun', 'Norm'};
            prog = struct();
            for i = 1:numel(keys)
                q = ps.(keys{i});
                prog.(keys{i}) = struct('scored', double(q.Scored), 'total', double(q.Total));
            end
            s.progress = prog;
            s.message = obj.Message;
        end

        function writeStateNow(obj)
            if obj.Constructing || isempty(obj.WorkDir)
                return;
            end
            f = obj.defaultStateFile();
            if isempty(f)
                return;
            end
            try
                s = obj.buildStateJson();
                obj.writeJsonAtomic(f, s);
                obj.StateFile = f;
            catch
            end
        end

        function maybeWriteState(obj)
            if obj.Constructing || isempty(obj.WorkDir)
                return;
            end
            if ~isempty(obj.StateWriteTic) && toc(obj.StateWriteTic) < 0.2
                return;
            end
            obj.StateWriteTic = tic;
            obj.writeStateNow();
        end

        function writeJsonAtomic(~, filePath, s)
            txt = '';
            try
                txt = jsonencode(s);
            catch
                return;
            end
            if isempty(txt) || ~ischar(txt)
                return;
            end
            tmp = [filePath '.tmp'];
            fid = fopen(tmp, 'w', 'n', 'UTF-8');
            if fid < 0
                return;
            end
            ok = false;
            try
                fwrite(fid, txt, 'char');
                fclose(fid);
                ok = true;
            catch
                try, fclose(fid); catch, end
            end
            if ~ok
                return;
            end
            try
                movefile(tmp, filePath, 'f');
            catch
                try, delete(tmp); catch, end
            end
        end
    end

    methods (Access = private)

        % ---------------- v2：三正交视图（契约 §5.3） ----------------
        function buildTripleView(obj)
            c = obj.Colors;
            f = obj.Fonts;
            g = uigridlayout(obj.ViewHost, [1 3]);
            g.RowHeight = {'1x'};
            g.ColumnWidth = {'1x', '1x', '1x'};
            g.Padding = [0 0 0 0];
            g.RowSpacing = 4;
            g.ColumnSpacing = 4;
            g.BackgroundColor = c.panel;
            g.Tag = 'qcTripleView';
            g.Layout.Row = 2;
            obj.TripleViewGrid = g;
            specs = {'Axial', 'axial', '水平位 Axial'; ...
                'Coronal', 'coronal', '冠状位 Coronal'; ...
                'Sagittal', 'sagittal', '矢状位 Sagittal'};
            obj.TripleAxes = struct('Axial', [], 'Coronal', [], 'Sagittal', []);
            obj.TripleImages = struct('Axial', [], 'Coronal', [], 'Sagittal', []);
            obj.TripleCross = struct('Axial', [], 'Coronal', [], 'Sagittal', []);
            obj.TripleInfo = struct('Axial', struct(), 'Coronal', struct(), 'Sagittal', struct());
            for i = 1:3
                fld = specs{i, 1};
                orient = specs{i, 2};
                ax = uiaxes(g);
                ax.Layout.Row = 1;
                ax.Layout.Column = i;
                ax.Tag = ['qcTriple' fld];
                obj.configureTripleAxes(ax);
                ax.ButtonDownFcn = [];
                mrw.UiKit.tip(ax, mrw.UiKit.wrapTooltip({ ...
                    [specs{i, 3} '视图（三正交联动）'], ...
                    '十字线显示当前 3D 体素；点击图像可把十字线移到该位置并把本视图设为活动视图。', ...
                    '↑/↓ 或下方滑条移动活动视图的切片；A/C/S 键切换活动方向。'}));
                obj.TripleAxes.(fld) = ax;
            end
            ip = uipanel(obj.RightGrid, 'BorderType', 'line', 'HighlightColor', c.border, ...
                'BackgroundColor', c.panelAlt, 'ForegroundColor', c.text, ...
                'FontName', f.name, 'FontSize', f.small);
            ip.Layout.Row = 21;
            ip.Layout.Column = 1;
            ip.Tag = 'qcTripleInfo';
            obj.TripleInfoPanel = ip;
            ig = uigridlayout(ip, [1 1]);
            ig.RowHeight = {'1x'};
            ig.ColumnWidth = {'1x'};
            ig.Padding = [8 6 8 6];
            ig.RowSpacing = 4;
            ig.BackgroundColor = c.panelAlt;
            obj.TripleInfoLabel = uilabel(ig, 'Text', '—', 'FontName', f.mono, ...
                'FontSize', f.small, 'FontColor', c.text, 'BackgroundColor', c.panelAlt, ...
                'VerticalAlignment', 'top', 'Tag', 'qcTripleInfoText');
            obj.TripleInfoLabel.Layout.Row = 1;
            try, obj.TripleInfoLabel.WordWrap = 'on'; catch, end
            mrw.UiKit.tip(obj.TripleInfoLabel, mrw.UiKit.wrapTooltip({ ...
                '体素 / 世界 mm / 显示 mm 坐标、显示模式（native / origin / acpc）、', ...
                'AC-PC 距离与角度、平移(mm)/旋转(度)、翻转状态。'}));
            obj.TripleBuilt = true;
            obj.CenterPanel.AutoResizeChildren = 'off';
            obj.CenterPanel.SizeChangedFcn = @(~,~) obj.layoutTripleViews();
        end

        function layoutTripleViews(obj)
            if ~obj.TripleBuilt || ~isvalid(obj.TripleViewGrid), return; end
            g = obj.TripleViewGrid;
            % Panel resize callbacks precede the browser's child-grid layout update.
            ip = obj.CenterPanel.InnerPosition;
            rows = obj.CenterGrid.RowHeight;
            fixed = cellfun(@isnumeric, rows);
            activeRows = numel(rows) - sum(cellfun(@(r) isnumeric(r) && r == 0, rows));
            padding = obj.CenterGrid.Padding;
            wh = ip(3:4) - [sum(padding([1 3])), ...
                sum(padding([2 4])) + sum([rows{fixed}]) + obj.CenterGrid.RowSpacing*(activeRows-1)];
            if any(wh <= 0), return; end
            fields = {'Axial','Coronal','Sagittal'};
            ratios = [0.8 0.8 1.1];
            for k = 1:3
                info = obj.TripleInfo.(fields{k});
                if isfield(info,'XLim') && isfield(info,'YLim')
                    ratios(k) = abs(diff(info.XLim)/diff(info.YLim));
                end
            end
            % Compare the actual equal-aspect image areas, including axes decoration space.
            sizes = [repmat([(wh(1)-8)/3-24, wh(2)-40],3,1); ...
                repmat([wh(1)-24, (wh(2)-8)/3-40],3,1); ...
                (wh(1)-4)/2-24, wh(2)-40; ...
                repmat([(wh(1)-4)/2-24, (wh(2)-4)/2-40],2,1)];
            scores = zeros(1,3);
            for candidate = 1:3
                rect = max(1,sizes((candidate-1)*3+(1:3),:));
                widths = min(rect(:,1)', rect(:,2)'.*ratios);
                heights = min(rect(:,2)', rect(:,1)'./ratios);
                scores(candidate) = min(widths.*heights);
            end
            [~, best] = max(scores);
            if isequal(g.UserData,best), return; end
            g.UserData = best;
            if best == 1
                g.ColumnWidth = {'1x','1x','1x'};
                for k = 1:3
                    obj.TripleAxes.(fields{k}).Layout.Row = 1;
                    obj.TripleAxes.(fields{k}).Layout.Column = k;
                end
                g.RowHeight = {'1x'};
            elseif best == 2
                g.RowHeight = {'1x','1x','1x'};
                for k = 1:3
                    obj.TripleAxes.(fields{k}).Layout.Column = 1;
                    obj.TripleAxes.(fields{k}).Layout.Row = k;
                end
                g.ColumnWidth = {'1x'};
            else
                g.ColumnWidth = {'1x','1x'};
                obj.TripleAxes.Axial.Layout.Row = [1 2]; obj.TripleAxes.Axial.Layout.Column = 1;
                obj.TripleAxes.Coronal.Layout.Row = 1; obj.TripleAxes.Coronal.Layout.Column = 2;
                obj.TripleAxes.Sagittal.Layout.Row = 2; obj.TripleAxes.Sagittal.Layout.Column = 2;
                g.RowHeight = {'1x','1x'};
            end
        end

        function configureTripleAxes(obj, ax)
            c = obj.Colors;
            f = obj.Fonts;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            try, ax.Color = [0.078 0.086 0.106]; catch, end
            try, ax.XColor = c.border; ax.YColor = c.border; catch, end
            try, ax.XTick = []; ax.YTick = []; catch, end
            try, ax.Box = 'on'; catch, end
            try, ax.FontName = f.name; ax.FontSize = f.small; catch, end
            try, ax.Toolbar.Visible = 'off'; catch, end
            try, ax.LooseInset = [0 0 0 0]; catch, end
            try
                ax.XLimMode = 'manual';
                ax.YLimMode = 'manual';
                ax.DataAspectRatio = [1 1 1];
                ax.DataAspectRatioMode = 'manual';
            catch
            end
            try, disableDefaultInteractivity(ax); catch, end
            try, ax.Interactions = []; catch, end
        end

        function renderTriple(obj)
            if ~obj.TripleBuilt
                return;
            end
            orients = {'axial', 'coronal', 'sagittal'};
            fields = {'Axial', 'Coronal', 'Sagittal'};
            file = obj.currentFile();
            vol = [];
            if ~isempty(file)
                [vol, ~] = obj.getVolume(file);
            end
            dims = obj.currentVolumeDims();
            if isempty(vol) || isempty(dims)
                for i = 1:3
                    obj.drawTripleMessage(fields{i}, '无图像');
                end
                obj.updateTripleInfoLabel();
                return;
            end
            useEngine = obj.ensureView();
            for i = 1:3
                fld = fields{i};
                o = orients{i};
                ax = obj.TripleAxes.(fld);
                if isempty(ax) || ~isvalid(ax)
                    continue;
                end
                if useEngine
                    obj.renderTripleEngineSlice(fld, o);
                else
                    obj.renderTripleFallbackSlice(fld, o, vol);
                end
                try
                    if strcmp(o, obj.ActiveOrientation)
                        ax.XColor = obj.Colors.accent;
                        ax.YColor = obj.Colors.accent;
                        ax.LineWidth = 1.5;
                    else
                        ax.XColor = obj.Colors.muted;
                        ax.YColor = obj.Colors.muted;
                        ax.LineWidth = 0.5;
                    end
                catch
                end
            end
            obj.syncSliceStateFromView(useEngine);
            obj.layoutTripleViews();
            obj.syncSliceUI();
            obj.updateCoordLabel();
            obj.updateAlignSummary();
            obj.updateTripleInfoLabel();
            obj.syncViewModeTitle();
            obj.Zoom = obj.computeZoomFactor();
            obj.syncZoomUI();
        end

        function renderTripleEngineSlice(obj, fld, o)
            ax = obj.TripleAxes.(fld);
            cur = [];
            try, cur = double(obj.View.currentSliceIndex(o)); catch, cur = []; end
            if isempty(cur) || ~isfinite(cur)
                cur = 1;
            end
            [img, info] = obj.viewSlice(o, cur);
            if isempty(img)
                obj.drawTripleMessage(fld, char(fieldAny(info, {'Message'}, '切片生成失败')));
                return;
            end
            oldInfo = obj.TripleInfo.(fld);
            keepLimits = isfield(oldInfo, 'XLim') && isfield(oldInfo, 'YLim') && ...
                isequal(oldInfo.XLim, info.XLim) && isequal(oldInfo.YLim, info.YLim) && ...
                isequal(getappdata(ax, 'QcViewKey'), obj.ViewKey);
            oldX = ax.XLim; oldY = ax.YLim;
            obj.TripleInfo.(fld) = info;
            xl = numericRow(fieldAny(info, {'XLim'}, []), 2, []);
            yl = numericRow(fieldAny(info, {'YLim'}, []), 2, []);
            if isempty(xl)
                xl = [0.5, size(img, 2) + 0.5];
            end
            if isempty(yl)
                yl = [0.5, size(img, 1) + 0.5];
            end
            [lo, hiC] = obj.windowLimits(img);
            obj.UpdatingAxes = true;
            h = [];
            try
                h = obj.TripleImages.(fld);
                if isempty(h) || ~isvalid(h)
                    cla(ax); hold(ax, 'on');
                    h = imagesc(ax, pixelCenters(xl, size(img, 2)), pixelCenters(yl, size(img, 1)), img);
                    hold(ax, 'off');
                else
                    h.CData = img;
                    h.XData = pixelCenters(xl, size(img, 2));
                    h.YData = pixelCenters(yl, size(img, 1));
                end
                h.HitTest = 'off'; h.PickableParts = 'none';
                try, h.CDataMapping = 'scaled'; catch, end
                try, colormap(ax, obj.colormapData()); catch, end
                ax.CLim = [lo hiC];
                obj.applyViewLimits(ax, xl, yl);
                if keepLimits, ax.XLim = oldX; ax.YLim = oldY; end
                setappdata(ax, 'QcViewKey', obj.ViewKey);
                xlabel(ax, fieldAny(info, {'XAxisLabel'}, ''), 'Color', obj.Colors.muted);
                ylabel(ax, fieldAny(info, {'YAxisLabel'}, ''), 'Color', obj.Colors.muted);
                obj.drawTripleCrosshair(fld, info, xl, yl);
                hold(ax, 'off');
            catch
            end
            obj.UpdatingAxes = false;
            obj.TripleImages.(fld) = h;
            if strcmp(o, obj.ActiveOrientation)
                obj.Clim = [lo hiC];
            end
        end

        function renderTripleFallbackSlice(obj, fld, o, vol)
            dims = size(vol);
            c = obj.getCrosshairVoxel();
            if isempty(c) || any(~isfinite(c))
                c = round((dims + 1) / 2);
            end
            switch o
                case 'axial'
                    idx = max(1, min(dims(3), round(c(3))));
                    total = dims(3);
                case 'coronal'
                    idx = max(1, min(dims(2), round(c(2))));
                    total = dims(2);
                otherwise
                    idx = max(1, min(dims(1), round(c(1))));
                    total = dims(1);
            end
            sl = obj.modelCall('makeSlice', vol, o, idx);
            if isempty(sl) || ~isstruct(sl) || ~isfield(sl, 'Image') || isempty(sl.Image)
                obj.drawTripleMessage(fld, '切片生成失败');
                return;
            end
            img = double(sl.Image);
            if ~ismatrix(img)
                img = reshape(img, size(img, 1), []);
            end
            nr = size(img, 1);
            nc = size(img, 2);
            xl = [0.5, nc + 0.5];
            yl = [0.5, nr + 0.5];
            [lo, hiC] = obj.windowLimits(img);
            ax = obj.TripleAxes.(fld);
            obj.UpdatingAxes = true;
            h = [];
            try
                cla(ax);
                hold(ax, 'on');
                h = imagesc(ax, xl, yl, img);
                try, colormap(ax, obj.colormapData()); catch, end
                ax.CLim = [lo hiC];
                obj.applyViewLimits(ax, xl, yl);
                obj.drawTripleCrosshairFallback(fld, o, dims, xl, yl);
                hold(ax, 'off');
            catch
            end
            obj.UpdatingAxes = false;
            obj.TripleImages.(fld) = h;
            obj.TripleInfo.(fld) = struct('Message', '降级显示（showv 引擎未就绪）');
            if strcmp(o, obj.ActiveOrientation)
                obj.Clim = [lo hiC];
            end
            try
                title(ax, sprintf('%s %d/%d · 降级', tripleLabel(o), idx, total), ...
                    'Interpreter', 'none', 'Color', [0.85 0.87 0.90], 'FontSize', 9);
            catch
            end
        end

        function drawTripleMessage(obj, fld, msg)
            ax = obj.TripleAxes.(fld);
            obj.drawTripleMessageAxes(ax, msg);
            obj.TripleImages.(fld) = [];
            obj.TripleInfo.(fld) = struct();
        end

        function drawTripleMessageAxes(obj, ax, msg)
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            obj.UpdatingAxes = true;
            try
                cla(ax);
                ax.XLim = [0 1];
                ax.YLim = [0 1];
                ax.CLim = [0 1];
                try, colormap(ax, obj.colormapData()); catch, end
                hold(ax, 'on');
                text(ax, 0.5, 0.5, wrapChars(msg, 24), 'Units', 'normalized', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                    'Color', [0.78 0.81 0.86], 'FontName', obj.Fonts.name, ...
                    'FontSize', 12, 'Interpreter', 'none');
                hold(ax, 'off');
            catch
            end
            obj.UpdatingAxes = false;
        end

        function drawTripleCrosshair(obj, fld, info, xl, yl)
            ax = obj.TripleAxes.(fld);
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            old = obj.TripleCross.(fld);
            if ~logical(obj.CrosshairVisible)
                for k = 1:numel(old), if isvalid(old(k)), delete(old(k)); end, end
                obj.TripleCross.(fld) = [];
                return;
            end
            [x, y] = obj.tripleCrossPosition(fld, info);
            if ~isfinite(x) || ~isfinite(y)
                return;
            end
            c = obj.Colors.warn;
            try
                if numel(old) == 2 && all(isvalid(old))
                    old(1).XData = [x x]; old(1).YData = yl;
                    old(2).XData = xl; old(2).YData = [y y];
                    return;
                end
                hold(ax, 'on');
                h1 = plot(ax, [x x], yl, '-', 'Color', c, 'LineWidth', 0.8);
                h2 = plot(ax, xl, [y y], '-', 'Color', c, 'LineWidth', 0.8);
                set([h1 h2], 'HitTest', 'off', 'PickableParts', 'none');
                try, uistack(h1, 'top'); uistack(h2, 'top'); catch, end
                hold(ax, 'off');
                obj.TripleCross.(fld) = [h1 h2];
            catch
            end
        end

        function drawTripleCrosshairFallback(obj, fld, o, dims, xl, yl)
            ax = obj.TripleAxes.(fld);
            old = obj.TripleCross.(fld);
            for k = 1:numel(old)
                try
                    if isvalid(old(k))
                        delete(old(k));
                    end
                catch
                end
            end
            obj.TripleCross.(fld) = [];
            if ~logical(obj.CrosshairVisible)
                return;
            end
            c = obj.getCrosshairVoxel();
            if isempty(c) || any(~isfinite(c))
                return;
            end
            switch o
                case 'axial'
                    x = c(2);
                    y = c(1);
                case 'coronal'
                    x = c(1);
                    y = dims(3) - c(3) + 1;
                otherwise
                    x = c(2);
                    y = dims(3) - c(3) + 1;
            end
            if x < xl(1) || x > xl(2) || y < yl(1) || y > yl(2)
                return;
            end
            cc = obj.Colors.warn;
            try
                hold(ax, 'on');
                h1 = plot(ax, [x x], yl, '-', 'Color', cc, 'LineWidth', 0.8);
                h2 = plot(ax, xl, [y y], '-', 'Color', cc, 'LineWidth', 0.8);
                try, uistack(h1, 'top'); uistack(h2, 'top'); catch, end
                hold(ax, 'off');
                obj.TripleCross.(fld) = [h1 h2];
            catch
            end
        end

        function [x, y] = tripleCrossPosition(obj, fld, info)
            x = NaN;
            y = NaN;
            if ~isstruct(info) || isempty(fieldnames(info))
                return;
            end
            xl = numericRow(fieldAny(info, {'XLim'}, []), 2, []);
            yl = numericRow(fieldAny(info, {'YLim'}, []), 2, []);
            isz = numericRow(fieldAny(info, {'ImageSize'}, []), 2, []);
            cp = numericRow(fieldAny(info, {'CrosshairPixel'}, []), 2, []);
            if ~isempty(cp) && ~isempty(isz) && ~isempty(xl) && ~isempty(yl) && ...
                    isz(1) > 0 && isz(2) > 0
                x = xl(1) + (cp(1) - 0.5) * (xl(2) - xl(1)) / isz(2);
                y = yl(1) + (cp(2) - 0.5) * (yl(2) - yl(1)) / isz(1);
                if isfinite(x) && isfinite(y)
                    return;
                end
            end
            o = orientationFromFieldName(fld);
            d = numericRow(fieldAny(info, {'CrosshairDisplay'}, []), 3, []);
            if isempty(d) && obj.ensureView()
                try
                    v = obj.getCrosshairVoxel();
                    d = numericRow(double(obj.View.voxelToDisplay(v)), 3, []);
                catch
                    d = [];
                end
            end
            if isempty(d)
                return;
            end
            [axX, axY] = defaultPlaneAxes(o);
            x = d(axX);
            y = d(axY);
        end

        function d = clickToDisplayPoint(obj, o, info, x, y)
            d = [];
            if ~obj.ensureView()
                return;
            end
            d = numericRow(fieldAny(info, {'CrosshairDisplay'}, []), 3, []);
            if isempty(d)
                try
                    vi = obj.View.getInfo();
                    d = numericRow(fieldAny(vi, {'CrosshairDisplay'}, []), 3, []);
                catch
                    d = [];
                end
            end
            if isempty(d)
                return;
            end
            [axX, axY] = defaultPlaneAxes(o);
            dn = numericRow(fieldAny(info, {'SliceCoord'}, []), 1, []);
            axN = setdiff(1:3, [axX axY], 'stable');
            if isempty(axN)
                return;
            end
            axN = axN(1);
            d(axX) = double(x);
            d(axY) = double(y);
            if ~isempty(dn) && isfinite(dn)
                d(axN) = double(dn);
            end
        end

        function v = fallbackClickToVoxel(obj, o, x, y)
            v = [];
            dims = obj.currentVolumeDims();
            if isempty(dims)
                return;
            end
            c = obj.getCrosshairVoxel();
            if isempty(c) || any(~isfinite(c))
                c = round((dims + 1) / 2);
            end
            switch o
                case 'axial'
                    i = round(y);
                    j = round(x);
                    k = c(3);
                case 'coronal'
                    i = round(x);
                    j = c(2);
                    k = dims(3) - round(y) + 1;
                otherwise
                    i = c(1);
                    j = round(x);
                    k = dims(3) - round(y) + 1;
            end
            v = [min(max(i, 1), dims(1)), min(max(j, 1), dims(2)), min(max(k, 1), dims(3))];
            v = double(v);
        end

        function onTripleAxesClicked(obj, orient, evt)
            if nargin < 3
                evt = [];
            end
            if obj.UpdatingViewUI || obj.Constructing
                return;
            end
            fld = tripleFieldName(orient);
            ax = obj.TripleAxes.(fld);
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            x = [];
            y = [];
            cp = [];
            try, cp = ax.CurrentPoint; catch, cp = []; end
            if ~isempty(cp) && size(cp, 1) >= 1 && numel(cp) >= 2 && ...
                    all(isfinite(cp(1, 1:2)))
                x = cp(1, 1);
                y = cp(1, 2);
            end
            if isempty(x) && ~isempty(evt)
                try
                    ip = evt.IntersectionPoint;
                    if numel(ip) >= 2 && all(isfinite(ip(1:2)))
                        x = ip(1);
                        y = ip(2);
                    end
                catch
                end
            end
            if isempty(x)
                return;
            end
            obj.clickViewAt(orient, x, y);
        end

        % ---------------- v2：多切片网格（契约 §5.3） ----------------
        function buildMontageView(obj)
            c = obj.Colors;
            f = obj.Fonts;
            g = uigridlayout(obj.ViewHost, [1 1]);
            g.Padding = [0 0 0 0];
            g.RowSpacing = 0;
            g.ColumnSpacing = 0;
            g.BackgroundColor = c.panel;
            g.Tag = 'qcMontageView';
            g.Layout.Row = 3;
            obj.MontageViewGrid = g;
            ax = uiaxes(g);
            ax.Tag = 'qcMontageAxes';
            obj.configureTripleAxes(ax);
            try
                ax.ButtonDownFcn = @(s, e) obj.onMontageClicked(e);
            catch
            end
            obj.MontageAxes = ax;
            mrw.UiKit.tip(ax, mrw.UiKit.wrapTooltip({ ...
                '多切片网格：当前方向（“方向”下拉）的等间隔切片拼图。', ...
                '点击任一 tile 选择该层并设为当前切片；↑/↓ 或滑条逐层移动。'}));
            obj.MontageBuilt = true;
        end

        function renderMontage(obj)
            if ~obj.MontageBuilt
                return;
            end
            ax = obj.MontageAxes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            o = obj.Orientation;
            file = obj.currentFile();
            vol = [];
            if ~isempty(file)
                [vol, ~] = obj.getVolume(file);
            end
            dims = obj.currentVolumeDims();
            if isempty(vol) || isempty(dims)
                obj.drawTripleMessageAxes(ax, '无图像');
                obj.updateCoordLabel();
                return;
            end
            n = obj.montageN(o, dims);
            m = struct();
            img = [];
            if obj.ensureView()
                try
                    [img, m] = obj.View.montage(o, n);
                catch
                    img = [];
                    m = struct();
                end
            end
            if isempty(img)
                [img, m] = obj.fallbackMontage(o, dims, vol, n);
            end
            if isempty(img)
                obj.drawTripleMessageAxes(ax, '多切片生成失败');
                return;
            end
            obj.MontageInfo = m;
            [cur, total, hiTile] = obj.montageSelection(o, m);
            obj.MontageInfo.Highlight = hiTile;
            nr = size(img, 1);
            nc = size(img, 2);
            [lo, hiC] = obj.windowLimits(img);
            obj.UpdatingAxes = true;
            h = [];
            try
                cla(ax);
                hold(ax, 'on');
                h = imagesc(ax, [0.5 nc + 0.5], [0.5 nr + 0.5], img);
                try, h.CDataMapping = 'scaled'; catch, end
                try, colormap(ax, obj.colormapData()); catch, end
                ax.CLim = [lo hiC];
                ax.XLim = [0.5 nc + 0.5];
                ax.YLim = [0.5 nr + 0.5];
                obj.drawMontageTiles(ax, m, hiTile);
                hold(ax, 'off');
            catch
            end
            obj.UpdatingAxes = false;
            obj.MontageImageHandle = h;
            obj.Clim = [lo hiC];
            obj.SliceIndex = max(1, round(cur));
            if isempty(total) || ~isfinite(total) || total < 1
                total = numel(fieldOr(m, 'Tiles', []));
            end
            obj.SliceCount = max(1, round(double(total)));
            obj.syncWindowUI();
            obj.syncSliceUI();
            nActual = double(fieldOr(m, 'N', n));
            if ~isfinite(nActual) || nActual < 1
                nActual = n;
            end
            try
                title(ax, sprintf('多切片网格 · %s · %d×%d · 当前第 %d/%d 层', ...
                    tripleLabel(o), round(nActual), round(nActual), ...
                    obj.SliceIndex, obj.SliceCount), ...
                    'Interpreter', 'none', 'Color', [0.85 0.87 0.90], 'FontSize', 10);
            catch
            end
            obj.updateCoordLabel();
            obj.updateAlignSummary();
            obj.syncViewModeTitle();
        end

        function n = montageN(obj, o, dims)
            if isempty(dims)
                n = 3;
                return;
            end
            switch o
                case 'axial'
                    total = dims(3);
                case 'coronal'
                    total = dims(2);
                otherwise
                    total = dims(1);
            end
            n = max(2, ceil(sqrt(max(1, total))));
            n = min(n, 6);
        end

        function [cur, total, hiTile] = montageSelection(obj, o, m)
            dims = obj.currentVolumeDims();
            total = [];
            if ~isempty(dims)
                switch o
                    case 'axial'
                        total = dims(3);
                    case 'coronal'
                        total = dims(2);
                    otherwise
                        total = dims(1);
                end
            end
            cur = [];
            if obj.ensureView()
                try
                    cur = round(double(obj.View.currentSliceIndex(o)));
                catch
                    cur = [];
                end
            end
            if isempty(cur) || ~isfinite(cur) || cur < 1
                c = obj.getCrosshairVoxel();
                if ~isempty(c) && all(isfinite(c))
                    switch o
                        case 'axial'
                            cur = round(c(3));
                        case 'coronal'
                            cur = round(c(2));
                        otherwise
                            cur = round(c(1));
                    end
                else
                    cur = 1;
                end
            end
            hiTile = [];
            if isstruct(m) && isfield(m, 'Tiles') && ~isempty(m.Tiles)
                best = inf;
                for k = 1:numel(m.Tiles)
                    si = double(fieldOr(m.Tiles(k), 'SliceIndex', NaN));
                    if isfinite(si) && abs(si - cur) < best
                        best = abs(si - cur);
                        hiTile = k;
                    end
                end
            end
            if ~isempty(total) && isfinite(total) && total >= 1
                cur = min(max(1, cur), total);
            end
        end

        function [img, info] = fallbackMontage(obj, o, dims, vol, n)
            img = [];
            info = struct('Orientation', o, 'N', n, 'ImageSize', [0 0], ...
                'SliceCount', 0, 'Highlight', [], 'Message', '', ...
                'Tiles', struct('SliceIndex', {}, 'Row', {}, 'Col', {}, ...
                'Height', {}, 'Width', {}, 'XLim', {}, 'YLim', {}));
            switch o
                case 'axial'
                    total = dims(3);
                case 'coronal'
                    total = dims(2);
                otherwise
                    total = dims(1);
            end
            n = max(1, min(n, max(1, total)));
            idxs = unique(round(linspace(1, total, n)));
            first = obj.modelCall('makeSlice', vol, o, idxs(1));
            if isempty(first) || ~isstruct(first) || ~isfield(first, 'Image') || isempty(first.Image)
                return;
            end
            tile = double(first.Image);
            if ~ismatrix(tile)
                tile = reshape(tile, size(tile, 1), []);
            end
            [nr, nc] = size(tile);
            img = zeros(n * nr, n * nc);
            for r = 1:n
                for c = 1:n
                    k = (r - 1) * n + c;
                    if k > numel(idxs)
                        continue;
                    end
                    if k == 1
                        im = tile;
                    else
                        sl = obj.modelCall('makeSlice', vol, o, idxs(k));
                        if isempty(sl) || ~isstruct(sl) || ~isfield(sl, 'Image') || isempty(sl.Image)
                            continue;
                        end
                        im = double(sl.Image);
                        if ~ismatrix(im)
                            im = reshape(im, size(im, 1), []);
                        end
                        if ~isequal(size(im), [nr nc])
                            continue;
                        end
                    end
                    rr = (r - 1) * nr + 1;
                    cc = (c - 1) * nc + 1;
                    img(rr:rr + nr - 1, cc:cc + nc - 1) = im;
                    info.Tiles(k) = struct('SliceIndex', idxs(k), 'Row', rr, 'Col', cc, ...
                        'Height', nr, 'Width', nc, 'XLim', [0.5 nc + 0.5], ...
                        'YLim', [0.5 nr + 0.5]);
                end
            end
            info.ImageSize = [n * nr, n * nc];
            info.SliceCount = total;
        end

        function k = montageTileAt(obj, m, x, y)
            k = [];
            if ~isstruct(m) || ~isfield(m, 'Tiles') || isempty(m.Tiles)
                return;
            end
            tiles = m.Tiles;
            n = double(fieldOr(m, 'N', round(sqrt(numel(tiles)))));
            if ~isfinite(n) || n < 1
                n = round(sqrt(numel(tiles)));
            end
            % QcView.montage：Tiles(k).Row/Col 为 tile 行列索引（1..n），
            % Height/Width 为 tile 像素高宽；面板按像素坐标绘制 montage。
            for i = 1:numel(tiles)
                t = tiles(i);
                r = double(fieldOr(t, 'Row', NaN));
                c0 = double(fieldOr(t, 'Col', NaN));
                h = double(fieldOr(t, 'Height', NaN));
                w = double(fieldOr(t, 'Width', NaN));
                if any(~isfinite([r c0 h w]))
                    continue;
                end
                x0 = (c0 - 1) * w + 0.5;
                x1 = x0 + w;
                y0 = (r - 1) * h + 0.5;
                y1 = y0 + h;
                if x >= x0 && x <= x1 && y >= y0 && y <= y1
                    k = i;
                    return;
                end
            end
            % 兜底：按 n×n 网格推算
            isz = numericRow(fieldOr(m, 'ImageSize', []), 2, []);
            if numel(isz) >= 2 && n >= 1 && all(isz > 0)
                h = isz(1) / n;
                w = isz(2) / n;
                c = max(1, min(n, ceil((x - 0.5) / w)));
                r = max(1, min(n, ceil((y - 0.5) / h)));
                kk = (r - 1) * n + c;
                if kk >= 1 && kk <= numel(tiles)
                    k = kk;
                end
            end
        end

        function drawMontageTiles(obj, ax, m, hiTile)
            if ~isstruct(m) || ~isfield(m, 'Tiles') || isempty(m.Tiles)
                return;
            end
            for i = 1:numel(m.Tiles)
                t = m.Tiles(i);
                r = double(fieldOr(t, 'Row', NaN));
                c0 = double(fieldOr(t, 'Col', NaN));
                h = double(fieldOr(t, 'Height', NaN));
                w = double(fieldOr(t, 'Width', NaN));
                if any(~isfinite([r c0 h w]))
                    continue;
                end
                % Tiles(k).Row/Col 是 tile 索引（1..n）；换算为像素矩形
                x0 = (c0 - 1) * w + 1;
                y0 = (r - 1) * h + 1;
                if ~isempty(hiTile) && isscalar(hiTile) && isfinite(hiTile) && i == round(hiTile)
                    col = obj.Colors.err;
                    lw = 2;
                else
                    col = obj.Colors.border;
                    lw = 0.5;
                end
                try
                    plot(ax, [x0 x0 + w x0 + w x0 x0], [y0 y0 y0 + h y0 + h y0], '-', ...
                        'Color', col, 'LineWidth', lw);
                catch
                end
                si = double(fieldOr(t, 'SliceIndex', i));
                try
                    text(ax, x0 + 4, y0 + 12, sprintf('%d', si), ...
                        'Color', [0.72 0.75 0.80], 'FontSize', 7, ...
                        'FontName', obj.Fonts.name);
                catch
                end
            end
        end

        function onMontageClicked(obj, evt)
            if nargin < 2
                evt = [];
            end
            if obj.UpdatingAxes || obj.Constructing
                return;
            end
            ax = obj.MontageAxes;
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            x = [];
            y = [];
            cp = [];
            try, cp = ax.CurrentPoint; catch, cp = []; end
            if ~isempty(cp) && numel(cp) >= 2 && all(isfinite(cp(1, 1:2)))
                x = cp(1, 1);
                y = cp(1, 2);
            end
            if isempty(x) && ~isempty(evt)
                try
                    ip = evt.IntersectionPoint;
                    if numel(ip) >= 2 && all(isfinite(ip(1:2)))
                        x = ip(1);
                        y = ip(2);
                    end
                catch
                end
            end
            if isempty(x)
                return;
            end
            obj.clickMontageAt(x, y);
        end

        function ok = clickMontageAt(obj, x, y)
            ok = false;
            if ~strcmp(obj.ViewMode, 'montage')
                return;
            end
            m = obj.MontageInfo;
            if ~isstruct(m) || ~isfield(m, 'Tiles') || isempty(m.Tiles)
                return;
            end
            k = obj.montageTileAt(m, x, y);
            if isempty(k)
                return;
            end
            t = m.Tiles(k);
            si = double(fieldOr(t, 'SliceIndex', k));
            if ~isfinite(si)
                return;
            end
            o = obj.Orientation;
            if obj.ensureView()
                try
                    obj.View.setSliceIndex(o, si);
                    p = obj.View.getCrosshair();
                    if isnumeric(p) && numel(p) >= 3
                        obj.CrosshairVoxel = double(p(1:3));
                    end
                catch
                end
            else
                c = obj.getCrosshairVoxel();
                dims = obj.currentVolumeDims();
                if ~isempty(c) && ~isempty(dims) && all(isfinite(c))
                    switch o
                        case 'axial'
                            c(3) = max(1, min(dims(3), round(si)));
                        case 'coronal'
                            c(2) = max(1, min(dims(2), round(si)));
                        otherwise
                            c(1) = max(1, min(dims(1), round(si)));
                    end
                    obj.CrosshairVoxel = double(c(:).');
                end
            end
            obj.SliceIndex = max(1, round(si));
            obj.renderMontage();
            ok = true;
            obj.maybeWriteState();
        end

        % ---------------- v2：显示引擎 / 坐标 / 状态同步 ----------------
        function tf = ensureView(obj)
            tf = false;
            try
                have = exist('mrw.QcView', 'class') == 8;
            catch
                have = false;
            end
            if ~have
                if ~isempty(obj.View)
                    obj.View = [];
                end
                obj.ViewKey = '';
                return;
            end
            file = obj.currentFile();
            if isempty(file)
                return;
            end
            key = [obj.ModalityKey '|' char(file)];
            if ~isempty(obj.View) && strcmp(obj.ViewKey, key)
                try
                    if obj.View.hasVolume()
                        tf = true;
                        return;
                    end
                catch
                end
            end
            [vol, hdr] = obj.getVolume(file);
            if isempty(vol)
                return;
            end
            v = [];
            try
                v = mrw.QcView(vol, hdr);
            catch
                try
                    v = mrw.QcView();
                    v.setVolume(vol, hdr);
                catch
                    v = [];
                end
            end
            if isempty(v)
                return;
            end
            obj.View = v;
            obj.ViewKey = key;
            try
                p = v.getCrosshair();
                if isnumeric(p) && numel(p) >= 3 && all(isfinite(double(p(1:3))))
                    obj.CrosshairVoxel = double(p(1:3));
                end
            catch
            end
            obj.applyViewInterp();
            tf = true;
        end

        function [img, info] = viewSlice(obj, orient, idx)
            img = [];
            info = struct();
            if ~obj.ensureView()
                return;
            end
            try
                [img, info] = obj.View.slice(orient, idx);
            catch
                img = [];
                info = struct();
            end
            if ~isnumeric(img) || ~ismatrix(img)
                img = [];
            end
            if ~isstruct(info)
                info = struct();
            end
        end

        function n = viewSliceCount(obj, orient)
            n = [];
            if obj.ensureView()
                try
                    pi = obj.View.planeInfo(orient);
                    n = double(fieldAny(pi, {'SliceCount'}, []));
                catch
                    n = [];
                end
            end
            if isempty(n) || ~isfinite(n) || n < 1
                dims = obj.currentVolumeDims();
                if ~isempty(dims)
                    switch orient
                        case 'axial'
                            n = dims(3);
                        case 'coronal'
                            n = dims(2);
                        otherwise
                            n = dims(1);
                    end
                end
            end
        end

        function dims = currentVolumeDims(obj)
            dims = [];
            if ~isempty(obj.View) && ~isempty(obj.ViewKey)
                key = [obj.ModalityKey '|' char(obj.currentFile())];
                if strcmp(obj.ViewKey, key)
                    try
                        info = obj.View.getInfo();
                        d = double(fieldAny(info, {'Dim'}, []));
                        if numel(d) >= 3 && all(isfinite(d(1:3))) && all(d(1:3) > 0)
                            dims = double(d(1:3));
                            return;
                        end
                    catch
                    end
                end
            end
            file = obj.currentFile();
            if isempty(file)
                return;
            end
            [vol, hdr] = obj.getVolume(file);
            if ~isempty(vol)
                dims = double(size(vol));
            elseif isstruct(hdr) && isfield(hdr, 'dim') && numel(hdr.dim) >= 3
                d = double(hdr.dim(1:3));
                if all(isfinite(d)) && all(d > 0)
                    dims = d;
                end
            end
        end

        function info = fallbackViewInfo(obj)
            info = struct();
            info.Mode = 'native';
            info.HasVolume = false;
            dims = [];
            hdr = struct();
            file = obj.currentFile();
            if ~isempty(file)
                [vol, hdr] = obj.getVolume(file);
                if ~isempty(vol)
                    dims = double(size(vol));
                    info.HasVolume = true;
                end
            end
            c = obj.CrosshairVoxel;
            if isempty(c) || numel(c) < 3 || any(~isfinite(double(c(1:3))))
                if isempty(dims)
                    c = [NaN NaN NaN];
                else
                    c = round((dims + 1) / 2);
                end
            end
            c = double(c(1:3));
            w = c;
            if isstruct(hdr) && isfield(hdr, 'mat') && isnumeric(hdr.mat) && ...
                    size(hdr.mat, 1) >= 3 && size(hdr.mat, 2) >= 4
                try
                    w = double(hdr.mat) * [c(1:3), 1].';
                    w = double(w(1:3)).';
                catch
                    w = c;
                end
            end
            info.CrosshairVoxel = c;
            info.CrosshairWorld = w;
            info.CrosshairDisplay = w;
            info.ACVoxel = [];
            info.ACWorld = [];
            info.PCVoxel = [];
            info.PCWorld = [];
            info.ACPC = struct('distanceMm', NaN, 'angleDeg', NaN, ...
                'rotationDeg', [0 0 0], 'translationMm', [0 0 0]);
            info.DisplayMatrix = eye(4);
            info.Manual = struct('TranslationMm', [0 0 0], 'Translation', [0 0 0], ...
                'RotationDeg', [0 0 0], 'Rotation', [0 0 0]);
            info.Flips = struct('LR', false, 'AP', false, 'IS', false);
            info.Dim = dims;
            if isstruct(hdr) && isfield(hdr, 'voxSize') && numel(hdr.voxSize) >= 3
                info.VoxSize = abs(double(hdr.voxSize(1:3)));
            else
                info.VoxSize = [1 1 1];
            end
            if info.HasVolume
                info.Message = '显示引擎 mrw.QcView 未就绪：三正交按原生像素显示（降级模式）';
            else
                info.Message = '显示引擎 mrw.QcView 未就绪且无可用体数据';
            end
        end

        function info = viewInfoSafe(obj)
            info = struct();
            if obj.ensureView()
                try
                    v = obj.View.getInfo();
                    if isstruct(v)
                        info = v;
                        return;
                    end
                catch
                end
            end
            info = obj.fallbackViewInfo();
        end

        function applyViewInterp(obj)
            if ~obj.ensureView()
                return;
            end
            names = {'Interpolation', 'Interp', 'InterpMethod', 'SliceInterp', 'Sampling'};
            for i = 1:numel(names)
                try
                    if isprop(obj.View, names{i})
                        try
                            obj.View.(names{i}) = obj.InterpMethod;
                        catch
                            if strcmp(obj.InterpMethod, 'nearest')
                                obj.View.(names{i}) = 'nearest';
                            else
                                obj.View.(names{i}) = 'linear';
                            end
                        end
                        return;
                    end
                catch
                end
            end
        end

        function m = colormapData(obj)
            switch obj.ColormapName
                case 'hot'
                    m = hot(256);
                case 'jet'
                    m = jet(256);
                otherwise
                    m = gray(256);
            end
        end

        function syncSliceStateForOrientation(obj, o)
            if obj.ensureView()
                try
                    idx = double(obj.View.currentSliceIndex(o));
                    if isfinite(idx) && idx >= 1
                        obj.SliceIndex = round(idx);
                    end
                catch
                end
                n = obj.viewSliceCount(o);
                if ~isempty(n) && isfinite(n) && n >= 1
                    obj.SliceCount = round(n);
                end
                return;
            end
            dims = obj.currentVolumeDims();
            c = obj.getCrosshairVoxel();
            if isempty(dims) || isempty(c) || any(~isfinite(c))
                return;
            end
            switch o
                case 'axial'
                    obj.SliceIndex = max(1, min(dims(3), round(c(3))));
                    obj.SliceCount = dims(3);
                case 'coronal'
                    obj.SliceIndex = max(1, min(dims(2), round(c(2))));
                    obj.SliceCount = dims(2);
                otherwise
                    obj.SliceIndex = max(1, min(dims(1), round(c(1))));
                    obj.SliceCount = dims(1);
            end
        end

        function syncSliceStateFromView(obj, useEngine)
            o = obj.ActiveOrientation;
            if useEngine
                try
                    idx = double(obj.View.currentSliceIndex(o));
                    if isfinite(idx) && idx >= 1
                        obj.SliceIndex = round(idx);
                    end
                catch
                end
                n = obj.viewSliceCount(o);
                if ~isempty(n) && isfinite(n) && n >= 1
                    obj.SliceCount = round(n);
                end
                return;
            end
            obj.syncSliceStateForOrientation(o);
        end

        function syncCrosshairFromSingleSlice(obj)
            if obj.ensureView()
                obj.View.setSliceIndex(obj.Orientation, obj.SliceIndex);
                obj.CrosshairVoxel = double(obj.View.getCrosshair());
                return;
            end
            dims = obj.currentVolumeDims();
            if isempty(dims)
                return;
            end
            c = obj.getCrosshairVoxel();
            if isempty(c) || any(~isfinite(c))
                c = round((dims + 1) / 2);
            end
            switch obj.Orientation
                case 'axial'
                    c(3) = max(1, min(dims(3), round(obj.SliceIndex)));
                case 'coronal'
                    c(2) = max(1, min(dims(2), round(obj.SliceIndex)));
                otherwise
                    c(1) = max(1, min(dims(1), round(obj.SliceIndex)));
            end
            obj.CrosshairVoxel = double(c(:).');
            if obj.ensureView()
                try, obj.View.setCrosshair(obj.CrosshairVoxel); catch, end
            end
        end

        function syncSliceToCrosshair(obj)
            if obj.ensureView()
                obj.SliceIndex = obj.View.currentSliceIndex(obj.Orientation);
                obj.SliceCount = obj.viewSliceCount(obj.Orientation);
                return;
            end
            dims = obj.currentVolumeDims();
            if isempty(dims)
                return;
            end
            c = obj.getCrosshairVoxel();
            if isempty(c) || any(~isfinite(c))
                return;
            end
            switch obj.Orientation
                case 'axial'
                    obj.SliceIndex = max(1, min(dims(3), round(c(3))));
                    obj.SliceCount = dims(3);
                case 'coronal'
                    obj.SliceIndex = max(1, min(dims(2), round(c(2))));
                    obj.SliceCount = dims(2);
                otherwise
                    obj.SliceIndex = max(1, min(dims(1), round(c(1))));
                    obj.SliceCount = dims(1);
            end
        end

        function updateTripleInfoLabel(obj)
            if isempty(obj.TripleInfoLabel) || ~isvalid(obj.TripleInfoLabel)
                return;
            end
            vi = obj.getViewInfo();
            c = obj.getCrosshairVoxel();
            [manT, manR] = manualFromInfo(vi);
            fl = flipsFromInfo(vi);
            mode = lower(char(fieldAny(vi, {'Mode'}, 'native')));
            acpc = fieldAny(vi, {'ACPC'}, struct());
            d = double(fieldAny(acpc, {'distanceMm', 'DistanceMm'}, NaN));
            ang = double(fieldAny(acpc, {'angleDeg', 'AngleDeg'}, NaN));
            w = numericRow(fieldAny(vi, {'CrosshairWorld'}, []), 3, []);
            dd = numericRow(fieldAny(vi, {'CrosshairDisplay'}, []), 3, []);
            notReady = ~isempty(strfind(char(fieldAny(vi, {'Message'}, '')), '未就绪'));
            hasVol = logical(fieldAny(vi, {'HasVolume'}, false));
            lines = {sprintf('位置与校准 · 体素 %s · %s', fmtVec3(c, '%.1f'), alignModeLabelZh(mode)), ...
                sprintf('世界 %s mm · 显示 %s mm', fmtVec3(w, '%.1f'), fmtVec3(dd, '%.1f'))};
            if isfinite(d)
                acpcText = sprintf('AC-PC %.2f mm / %.1f°', d, ang);
            else
                acpcText = 'AC-PC 未配平';
            end
            lines{3} = sprintf('%s · 平移 %s · 旋转 %s · 翻转 %d/%d/%d', ...
                acpcText, fmtVec3(manT, '%.0f'), fmtVec3(manR, '%.0f'), fl);
            if notReady || ~hasVol, lines{1} = [lines{1} ' · 引擎未就绪']; end
            try
                obj.TripleInfoLabel.Text = strjoin(lines, newline);
            catch
            end
        end

        function updateCoordLabel(obj)
            if isempty(obj.CoordLabel) || ~isvalid(obj.CoordLabel)
                return;
            end
            c = obj.getCrosshairVoxel();
            vi = obj.getViewInfo();
            w = numericRow(fieldAny(vi, {'CrosshairWorld'}, []), 3, []);
            d = numericRow(fieldAny(vi, {'CrosshairDisplay'}, []), 3, []);
            if isempty(w) && ~isempty(c) && obj.ensureView()
                try, w = numericRow(double(obj.View.voxelToWorld(c)), 3, []); catch, w = []; end
            end
            if isempty(d) && ~isempty(c) && obj.ensureView()
                try, d = numericRow(double(obj.View.voxelToDisplay(c)), 3, []); catch, d = []; end
            end
            try
                obj.CoordLabel.Text = sprintf('体素 %s · 世界 %s mm · 显示 %s mm', ...
                    fmtVec3(c, '%.1f'), fmtVec3(w, '%.1f'), fmtVec3(d, '%.1f'));
            catch
            end
        end

        function updateAlignSummary(obj)
            if isempty(obj.AlignSummaryLabel) || ~isvalid(obj.AlignSummaryLabel)
                return;
            end
            vi = obj.getViewInfo();
            mode = lower(char(fieldAny(vi, {'Mode'}, 'native')));
            acpc = fieldAny(vi, {'ACPC'}, struct());
            d = double(fieldAny(acpc, {'distanceMm', 'DistanceMm'}, NaN));
            ang = double(fieldAny(acpc, {'angleDeg', 'AngleDeg'}, NaN));
            [manT, manR] = manualFromInfo(vi);
            fl = flipsFromInfo(vi);
            lines = {};
            lines{end+1} = sprintf('显示模式：%s', alignModeLabelZh(mode));
            if isfinite(d)
                lines{end+1} = sprintf('AC-PC %.2f mm · %.1f°', d, ang);
            else
                lines{end+1} = 'AC-PC：未配平';
            end
            lines{end+1} = sprintf('平移 %s mm', fmtVec3(manT, '%.1f'));
            lines{end+1} = sprintf('旋转 %s°', fmtVec3(manR, '%.1f'));
            lines{end+1} = sprintf('翻转 L-R:%s A-P:%s I-S:%s', ...
                tfText(fl(1)), tfText(fl(2)), tfText(fl(3)));
            try
                obj.AlignSummaryLabel.Text = strjoin(lines, newline);
                if strcmp(mode, 'native') && all(abs(manT) < 1e-6) && ...
                        all(abs(manR) < 1e-6) && ~any(fl)
                    obj.AlignSummaryLabel.FontColor = obj.Colors.muted;
                else
                    obj.AlignSummaryLabel.FontColor = obj.Colors.accentDark;
                end
            catch
            end
        end
    end

    methods (Access = private)

        function refreshSecondaryViews(obj)
            % 单视图之外（三正交 / 多切片）的增量刷新入口
            if strcmp(obj.ViewMode, 'triple')
                obj.renderTriple();
            elseif strcmp(obj.ViewMode, 'montage')
                obj.renderMontage();
            end
        end

        function applyViewLimits(obj, ax, xl, yl)
            % 设置 axes 显示范围；QcView 的 coronal/sagittal YLim 为降序（display Z 降序），
            % 而 MATLAB 的 XLim/YLim 必须递增，用 XDir/YDir 反转表达方向。
            if isempty(ax) || ~isvalid(ax)
                return;
            end
            if isempty(numericRow(xl, 2, []))
                return;
            end
            if xl(1) <= xl(2)
                try, ax.XDir = 'normal'; catch, end
                try, ax.XLim = [xl(1), xl(2)]; catch, end
            else
                try, ax.XDir = 'reverse'; catch, end
                try, ax.XLim = [xl(2), xl(1)]; catch, end
            end
            if isempty(yl) || numel(yl) < 2 || any(~isfinite(double(yl(1:2))))
                return;
            end
            if yl(1) <= yl(2)
                try, ax.YDir = 'normal'; catch, end
                try, ax.YLim = [yl(1), yl(2)]; catch, end
            else
                try, ax.YDir = 'reverse'; catch, end
                try, ax.YLim = [yl(2), yl(1)]; catch, end
            end
        end

        function s = transformHint(obj)
            s = '（单视图、三正交和网格使用相同显示几何）';
        end

        function [w, d] = crosshairWorldDisplay(obj, c)
            % 由同一个十字线体素派生世界/显示 mm 坐标（保证状态 JSON 三项同源）
            w = [];
            d = [];
            if ~isnumeric(c) || numel(c) < 3 || any(~isfinite(double(c(1:3))))
                return;
            end
            c = double(c(1:3));
            if obj.ensureView()
                try, w = numericRow(double(obj.View.voxelToWorld(c)), 3, []); catch, w = []; end
                try, d = numericRow(double(obj.View.voxelToDisplay(c)), 3, []); catch, d = []; end
            end
            if isempty(w) || isempty(d)
                vi = obj.getViewInfo();
                if isempty(w)
                    w = numericRow(fieldAny(vi, {'CrosshairWorld'}, []), 3, []);
                end
                if isempty(d)
                    d = numericRow(fieldAny(vi, {'CrosshairDisplay'}, []), 3, []);
                end
            end
        end
    end
end

% ======================================================================
%  局部函数
% ======================================================================
function k = normalizeModalityKey(key)
    k = '';
    if ischar(key) || isstring(key)
        s = upper(strtrim(char(key)));
        switch s
            case {'T1', 'T1RAW', 'T1 原始像', 'T1原始像'}
                k = 'T1';
            case {'FUN', 'FUNCTIONAL', '功能平均像', '功能像'}
                k = 'Fun';
            case {'NORM', 'NORMALIZATION', '标准化检查', '标准化'}
                k = 'Norm';
        end
    end
end

function v = pixelCenters(limits, count)
    step = diff(limits) / count;
    v = [limits(1) + step / 2, limits(2) - step / 2];
end

function o = normalizeOrientationValue(orient)
    o = '';
    if ischar(orient) || isstring(orient)
        s = lower(strtrim(char(orient)));
        switch s
            case {'axial', 'ax', '横断', '横断位', '横断面'}
                o = 'axial';
            case {'coronal', 'cor', '冠状', '冠状位', '冠状面'}
                o = 'coronal';
            case {'sagittal', 'sag', '矢状', '矢状位', '矢状面'}
                o = 'sagittal';
        end
    end
end

function s = modalityLabelFor(k)
    switch k
        case 'Fun'
            s = '功能平均像';
        case 'Norm'
            s = '标准化检查';
        otherwise
            s = 'T1 原始像';
    end
end

function s = normKindLabelFor(k)
    switch k
        case 'T1'
            s = 'wT1';
        case 'GM'
            s = 'wGM';
        otherwise
            s = 'wFun';
    end
end

function s = normKindItemLabel(k)
    switch k
        case 'T1'
            s = 'T1 结构像 wT1';
        case 'GM'
            s = '灰质 wGM';
        otherwise
            s = '功能像 wFun';
    end
end

function v = fieldOr(s, name, default)
    v = default;
    if isstruct(s) && isfield(s, name)
        v = s.(name);
        if isempty(v) && ~ischar(default)
            v = default;
        end
    end
end

function tf = isOkStruct(s)
    tf = false;
    if ~isstruct(s) || ~isfield(s, 'Ok')
        return;
    end
    try
        tf = isequal(logical(s.Ok), true);
    catch
        tf = false;
    end
end

function s = shortFileName(p)
    s = '';
    if ~ischar(p) || isempty(p)
        return;
    end
    [~, nm, ext] = fileparts(p);
    if strcmpi(ext, '.gz')
        [~, nm2, ext2] = fileparts(nm);
        s = [nm2 ext2 ext];
    else
        s = [nm ext];
    end
end

function s = shortComment(txt, maxLen)
    if nargin < 2
        maxLen = 16;
    end
    s = '';
    if ~ischar(txt) || isempty(txt)
        return;
    end
    s = regexprep(txt, '\s+', ' ');
    if numel(s) > maxLen
        s = [s(1:maxLen) '…'];
    end
end

function v = pctLocal(x, p)
    x = x(isfinite(x));
    if isempty(x)
        v = 0;
        return;
    end
    x = sort(x(:));
    if numel(x) == 1
        v = x(1);
        return;
    end
    p = max(0, min(100, p));
    idx = 1 + (numel(x) - 1) * p / 100;
    lo = floor(idx);
    hi = ceil(idx);
    if lo == hi
        v = x(lo);
    else
        v = x(lo) + (x(hi) - x(lo)) * (idx - lo);
    end
end

function s = onOff(tf)
    if logical(tf)
        s = 'on';
    else
        s = 'off';
    end
end

function c = wrapChars(s, width)
    if nargin < 2
        width = 26;
    end
    c = {''};
    if isstring(s)
        s = char(s);
    end
    if ~ischar(s) || isempty(s)
        return;
    end
    lines = regexp(s, '\r\n|\n|\r', 'split');
    out = {};
    for i = 1:numel(lines)
        ln = lines{i};
        if isempty(ln)
            out{end+1} = ''; %#ok<AGROW>
            continue;
        end
        while numel(ln) > width
            out{end+1} = ln(1:width); %#ok<AGROW>
            ln = ln(width + 1:end);
        end
        out{end+1} = ln; %#ok<AGROW>
    end
    if isempty(out)
        out = {''};
    end
    c = out;
end

function s = toTextValue(v)
    s = '';
    if ischar(v)
        s = v;
    elseif isstring(v)
        s = char(strjoin(v, sprintf('\n')));
    elseif iscell(v)
        parts = cell(1, numel(v));
        for i = 1:numel(v)
            parts{i} = char(v{i});
        end
        s = strjoin(parts, sprintf('\n'));
    end
end

function setEnable(h, tf)
    if isempty(h) || ~isvalid(h)
        return;
    end
    try
        h.Enable = onOff(tf);
    catch
    end
end

function setVisible(h, tf)
    if isempty(h) || ~isvalid(h)
        return;
    end
    try
        h.Visible = onOff(tf);
    catch
    end
end

% ---------------------- v2 局部辅助函数 ----------------------
function m = normalizeViewMode(v)
    m = '';
    if ischar(v) || isstring(v)
        switch lower(strtrim(char(v)))
            case {'single', 'mono', '单视图', '单切片'}
                m = 'single';
            case {'triple', 'ortho', '三正交', '三正交视图', '三视图'}
                m = 'triple';
            case {'montage', 'grid', '多切片网格', '多切片', '网格'}
                m = 'montage';
        end
    end
end

function s = viewModeLabel(m)
    switch m
        case 'triple'
            s = '三正交（轴/冠/矢）';
        case 'montage'
            s = '多切片网格';
        otherwise
            s = '单视图';
    end
end

function n = normalizeColormapName(v)
    n = '';
    if ischar(v) || isstring(v)
        switch lower(strtrim(char(v)))
            case {'gray', 'grey', '灰阶', '灰度'}
                n = 'gray';
            case {'hot', '热色', '热'}
                n = 'hot';
            case {'jet', 'jet 彩色', '彩色'}
                n = 'jet';
        end
    end
end

function m = normalizeInterpName(v)
    m = '';
    if ischar(v) || isstring(v)
        switch lower(strtrim(char(v)))
            case {'linear', '线性', '线性插值'}
                m = 'linear';
            case {'nearest', '最近邻', '最近邻插值', '最近'}
                m = 'nearest';
        end
    end
end

function f = normalizeFilterMode(v)
    f = '';
    if ischar(v) || isstring(v)
        switch lower(strtrim(char(v)))
            case {'all', '全部'}
                f = 'all';
            case {'unscored', '仅未评分', '未评分'}
                f = 'unscored';
            case {'scored', '已评分'}
                f = 'scored';
            case {'low', '低分', '低分≤阈值', '低分<=阈值'}
                f = 'low';
            case {'meanfd', 'mean fd', 'meanfd 超阈值', '超阈值'}
                f = 'meanfd';
        end
    end
end

function s = normalizeSortMode(v)
    s = '';
    if ischar(v) || isstring(v)
        switch lower(strtrim(char(v)))
            case {'id', '受试者 id', '受试者'}
                s = 'id';
            case {'score_asc', '评分↑', '评分升序'}
                s = 'score_asc';
            case {'score_desc', '评分↓', '评分降序'}
                s = 'score_desc';
            case {'meanfd_asc', 'meanfd↑', 'meanfd 升序'}
                s = 'meanfd_asc';
            case {'meanfd_desc', 'meanfd↓', 'meanfd 降序'}
                s = 'meanfd_desc';
        end
    end
end

function t = normalizeFdType(v)
    t = '';
    if ischar(v) || isstring(v)
        switch upper(strtrim(char(v)))
            case {'FD_JENKINSON', 'JENKINSON', 'FDJENKINSON'}
                t = 'FD_Jenkinson';
            case {'FD_POWER', 'POWER', 'FDPOWER'}
                t = 'FD_Power';
            case {'FD_VANDIJK', 'VANDIJK', 'FD_VAN_DIJK'}
                t = 'FD_VanDijk';
        end
    end
end

function s = fdTypeLabel(t)
    switch t
        case 'FD_Power'
            s = 'FD_Power';
        case 'FD_VanDijk'
            s = 'FD_VanDijk';
        otherwise
            s = 'FD_Jenkinson';
    end
end

function thr = fdDefaultThreshold(t)
    switch t
        case 'FD_Power'
            thr = 0.5;
        otherwise
            thr = 0.2;
    end
end

function fd = fdBaseStruct(fdType, defaultThr)
    fd = struct('Available', false, 'ID', '', 'Type', fdType, ...
        'Values', [], 'File', '', 'DefaultThreshold', defaultThr, ...
        'Threshold', defaultThr, 'MeanFD', NaN, 'MaxFD', NaN, ...
        'BadFrames', [], 'BadRatio', 0, 'Message', '');
end

function fld = tripleFieldName(orient)
    switch orient
        case 'coronal'
            fld = 'Coronal';
        case 'sagittal'
            fld = 'Sagittal';
        otherwise
            fld = 'Axial';
    end
end

function o = orientationFromFieldName(fld)
    switch fld
        case 'Coronal'
            o = 'coronal';
        case 'Sagittal'
            o = 'sagittal';
        otherwise
            o = 'axial';
    end
end

function s = tripleLabel(o)
    switch o
        case 'coronal'
            s = '冠状位 Coronal';
        case 'sagittal'
            s = '矢状位 Sagittal';
        otherwise
            s = '水平位 Axial';
    end
end

function ax = axisFromLabel(lab)
    % 由 QcView 的 XAxisLabel/YAxisLabel（如 'L→R' / 'S→I'）推断 display 轴序号
    ax = [];
    if isempty(lab) || ~ischar(lab)
        return;
    end
    c = upper(strtrim(lab));
    if isempty(c)
        return;
    end
    switch c(1)
        case {'L', 'R'}
            ax = 1;
        case {'P', 'A'}
            ax = 2;
        case {'I', 'S'}
            ax = 3;
        otherwise
            switch c(1)
                case 'X'
                    ax = 1;
                case 'Y'
                    ax = 2;
                case 'Z'
                    ax = 3;
            end
    end
end

function [axX, axY] = defaultPlaneAxes(orient)
    switch orient
        case 'coronal'
            axX = 1;
            axY = 3;
        case 'sagittal'
            axX = 2;
            axY = 3;
        otherwise
            axX = 1;
            axY = 2;
    end
end

function s = alignModeLabelZh(mode)
    switch lower(char(mode))
        case 'origin'
            s = 'origin（显示原点）';
        case 'acpc'
            s = 'acpc（AC-PC 配平）';
        otherwise
            s = 'native（原生）';
    end
end

function s = tfText(tf)
    if logical(tf)
        s = '是';
    else
        s = '否';
    end
end

function s = fmtVec3(v, fmt)
    s = '(—, —, —)';
    if nargin < 2 || isempty(fmt)
        fmt = '%.1f';
    end
    if ~isnumeric(v)
        return;
    end
    v = double(v(:).');
    if numel(v) < 3 || any(~isfinite(v(1:3)))
        return;
    end
    s = sprintf(['(' fmt ', ' fmt ', ' fmt ')'], v(1), v(2), v(3));
end

function v = vecOrEmpty(v, n)
    if ~isnumeric(v) || numel(v) < n
        v = [];
        return;
    end
    v = double(v(1:n));
    if any(~isfinite(v))
        v = [];
        return;
    end
    v = v(:).';
end

function v = numericRow(v, n, default)
    if ~isnumeric(v) || numel(v) < n
        v = default;
        return;
    end
    v = double(v(1:n));
    if any(~isfinite(v))
        v = default;
        return;
    end
    v = v(:).';
end

function v = fieldAny(s, names, default)
    v = default;
    if ~isstruct(s)
        return;
    end
    for i = 1:numel(names)
        if isfield(s, names{i})
            val = s.(names{i});
            if ~isempty(val)
                v = val;
                return;
            end
        end
    end
end

function [t, r] = manualFromInfo(info)
    t = [0 0 0];
    r = [0 0 0];
    if ~isstruct(info)
        return;
    end
    tv = [];
    rv = [];
    if isfield(info, 'Manual') && isstruct(info.Manual)
        m = info.Manual;
        tv = fieldAny(m, {'TranslationMm', 'Translation', 'TranslationMM', 'translationMm'}, []);
        rv = fieldAny(m, {'RotationDeg', 'Rotation', 'rotationDeg'}, []);
    end
    if isempty(tv)
        tv = fieldAny(info, {'ManualTranslationMm', 'ManualTranslation', 'TranslationMm'}, []);
    end
    if isempty(rv)
        rv = fieldAny(info, {'ManualRotationDeg', 'ManualRotation', 'RotationDeg'}, []);
    end
    t = numericRow(tv, 3, [0 0 0]);
    r = numericRow(rv, 3, [0 0 0]);
end

function fl = flipsFromInfo(info)
    fl = [false false false];
    if ~isstruct(info) || ~isfield(info, 'Flips')
        return;
    end
    f = info.Flips;
    if islogical(f) && numel(f) >= 3
        fl = logical(f(1:3));
        return;
    end
    if isnumeric(f) && numel(f) >= 3
        fl = logical(f(1:3));
        return;
    end
    if isstruct(f)
        lr = fieldAny(f, {'LR', 'lr', 'FlipLR', 'LeftRight'}, false);
        ap = fieldAny(f, {'AP', 'ap', 'FlipAP', 'AnteriorPosterior'}, false);
        is = fieldAny(f, {'IS', 'is', 'FlipIS', 'InferiorSuperior'}, false);
        fl = [logical(lr), logical(ap), logical(is)];
    end
end

function s = nowIsoLocal()
    % 本地时间 ISO 8601（带真实时区偏移；失败时退化为无偏移本地时间）
    s = '';
    try
        d = datetime('now', 'TimeZone', 'local');
        s = char(datetime(d, 'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX'));
    catch
        s = '';
    end
    if isempty(s)
        try
            d = datetime('now', 'TimeZone', 'UTC');
            s = char(datetime(d, 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));
        catch
            s = '';
        end
    end
    if isempty(s)
        s = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
    end
end

function off = localUtcOffsetHours()
    off = 8;
    try
        d = datetime('now', 'TimeZone', 'local');
        d2 = datetime('now', 'TimeZone', 'UTC');
        off = hours(d - d2);
    catch
    end
end

function sorted = naturalSortLocal(ids)
    % 自然排序（Sub2 排在 Sub10 之前）
    sorted = ids;
    if isempty(ids)
        return;
    end
    n = numel(ids);
    keys = cell(1, n);
    for i = 1:n
        keys{i} = naturalKeyLocal(ids{i});
    end
    try
        [~, ord] = sort(keys);
        sorted = ids(ord);
    catch
    end
end

function k = naturalKeyLocal(s)
    k = '';
    if isstring(s)
        s = char(s);
    end
    if ~ischar(s) || isempty(s)
        return;
    end
    i = 1;
    while i <= numel(s)
        if isstrprop(s(i), 'digit')
            j = i;
            while j <= numel(s) && isstrprop(s(j), 'digit')
                j = j + 1;
            end
            k = [k sprintf('%012d', str2double(s(i:j - 1)))]; %#ok<AGROW>
            i = j;
        else
            k = [k lower(s(i))]; %#ok<AGROW>
            i = i + 1;
        end
    end
end

