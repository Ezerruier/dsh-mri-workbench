function test_preprocess_panel()
% test_preprocess_panel  预处理参数面板 PreprocessPanel 的自动化测试
%
% 运行方式（项目根目录）：
%   & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch ...
%       "cd('...\MRI_Workbench'); addpath(pwd); test_preprocess_panel"
%
% 覆盖内容：
%   1. 构造性能（约 100 个字段 / 400+ 控件 < 2 秒）
%   2. 默认 State 与 CfgSchema.defaults() 一致
%   3. setState / getState 往返、getState 深拷贝
%   4. applyDetected 自动填充、reset 保留 WorkingDir/SubjectID
%   5. DependsOn 联动：bool / enum 变化后 isFieldEnabled 正确
%   6. vector 文本解析（合法/非法/维度错误），非法输入不崩溃、不改状态
%   7. 字段搜索、全部字段 highlightKey（切换选项卡+闪烁）不报错
%   8. Changed / RequestSubjectEdit / 预设 / 运行按钮回调
%   9. exportapp 截图 3 张（默认页/高级选项页/搜索候选页）

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root);
    addpath(here);

    fprintf('=== PreprocessPanel 组件测试 ===\n');
    fprintf('MATLAB %s\n', version);

    failures = 0;
    changedCount = 0;
    subjectEditCount = 0;
    presetCalled = '';
    runCalled = 0;

    % ------------------------------------------------------------------
    % 1. 构造
    % ------------------------------------------------------------------
    fig = mrw.UiKit.newFigure('PreprocessPanel 测试', [1280 860]);
    fig.Position = [60 30 1280 860];
    gl = uigridlayout(fig, [1 1]);
    gl.Padding = [0 0 0 0];
    gl.BackgroundColor = mrw.UiKit.colors().bg;
    container = uipanel(gl, 'BorderType', 'none', ...
        'BackgroundColor', mrw.UiKit.colors().bg);

    t0 = tic;
    p = mrw.PreprocessPanel(container, struct( ...
        'PresetNames', {{'默认标准流程', '快速检查'}}, ...
        'PresetSelectedFcn', @(name) onPreset(name), ...
        'RunRequestedFcn', @() onRun()));
    buildT = toc(t0);
    addlistener(p, 'Changed', @(s, e) onChanged());
    addlistener(p, 'RequestSubjectEdit', @(s, e) onSubjectEdit());

    fprintf('构造耗时：外部计时 %.2f s / 面板内部计时 %.2f s\n', ...
        buildT, p.BuildSeconds);
    fprintf('字段数：%d，UI 控件数：%d，版本：%s\n', ...
        p.FieldCount, p.ControlCount, p.Version);
    check(p.BuildSeconds < 2.0, sprintf('构造性能 < 2 s（实际 %.2f s）', p.BuildSeconds));
    check(p.FieldCount == numel(mrw.CfgSchema.entries()), '字段数与 CfgSchema 一致');
    check(p.ControlCount > 300, sprintf('创建控件数 > 300（实际 %d）', p.ControlCount));
    check(numel(p.PresetNames) == 2, '预设名称已载入');

    % ------------------------------------------------------------------
    % 2. 默认 State
    % ------------------------------------------------------------------
    def = mrw.CfgSchema.defaults();
    st = p.getState();
    diffs = diffAgainstSchema(def, st);
    check(isempty(diffs), '默认 State 与 CfgSchema.defaults() 一致');
    if ~isempty(diffs)
        fprintf('      不一致字段：%s\n', strjoin(diffs, ', '));
    end

    % ------------------------------------------------------------------
    % 3. setState / getState
    % ------------------------------------------------------------------
    custom = def;
    custom.WorkingDir = 'D:\MRI_Study\RestingState';
    custom.TR = 2.5;
    custom.TimePoints = 240;
    custom.IsSliceTiming = 1;
    custom.SliceTiming.SliceNumber = 32;
    custom.SliceTiming.SliceOrder = [1:2:33, 2:2:32];
    custom.IsRealign = 1;
    custom.IsSegment = 2;
    custom.IsDARTEL = 1;
    custom.IsNormalize = 3;
    custom.Normalize.VoxSize = [2 2 2];
    custom.Normalize.BoundingBox = [-90 -126 -72; 90 90 108];
    custom.IsSmooth = 2;
    custom.Smooth.FWHM = [4 4 4];
    custom.IsCovremove = 1;
    custom.IsFilter = 1;
    custom.Filter.ALowPass_HighCutoff = 0.08;
    custom.Covremove.WholeBrain.IsRemove = 1;
    custom.IsCalALFF = 1;
    custom.IsCalReHo = 1;
    custom.SubjectID = {'S01', 'S02', 'S03'};
    p.setState(custom);
    st2 = p.getState();
    diffs2 = diffAgainstSchema(custom, st2);
    check(isempty(diffs2), 'setState / getState 往返一致');
    if ~isempty(diffs2)
        fprintf('      不一致字段：%s\n', strjoin(diffs2, ', '));
    end
    st3 = p.getState();
    st3.TR = 99;
    check(p.getState().TR ~= 99, 'getState 返回深拷贝（外部修改不影响面板）');
    cBefore = changedCount;
    p.setState(def);
    check(changedCount == cBefore, 'setState 不触发 Changed（避免外部监听回环）');
    p.setState(custom);
    check(~isempty(strfind(p.SummaryText, '时间层校正')) && ...
          ~isempty(strfind(p.SummaryText, 'ALFF/fALFF')), ...
        ['已启用步骤摘要正确：' p.SummaryText]);

    % ------------------------------------------------------------------
    % 4. applyDetected / reset
    % ------------------------------------------------------------------
    c0 = changedCount;
    det = struct('WorkingDir', 'E:\Data\Subj', 'StartingDirName', 'FunRaw', ...
        'FunctionalSessionNumber', 2, 'TR', 2.0, 'TimePoints', 240, ...
        'SliceNumber', 33, 'SubjectIDs', {{'Subject01', 'Subject02'}});
    p.applyDetected(det);
    sd = p.getState();
    okDet = strcmp(sd.WorkingDir, det.WorkingDir) && ...
        strcmp(sd.DataProcessDir, det.WorkingDir) && ...
        strcmp(sd.StartingDirName, 'FunRaw') && ...
        sd.FunctionalSessionNumber == 2 && sd.TR == 2.0 && ...
        sd.TimePoints == 240 && sd.SliceTiming.SliceNumber == 33 && ...
        isequal(sd.SubjectID, {'Subject01', 'Subject02'});
    check(okDet, 'applyDetected 自动填充目录/会话数/TR/时间点/层数/受试者');
    check(changedCount > c0, 'applyDetected 触发 Changed 事件');

    wdKeep = p.getState().WorkingDir;
    idsKeep = p.getState().SubjectID;
    p.reset();
    sr = p.getState();
    check(sr.TR == 0 && sr.IsSliceTiming == 0 && sr.IsNormalize == 0, ...
        'reset 恢复 schema 默认值');
    check(strcmp(sr.WorkingDir, wdKeep) && isequal(sr.SubjectID, idsKeep), ...
        'reset 保留 WorkingDir / SubjectID');

    % ------------------------------------------------------------------
    % 5. DependsOn 联动
    % ------------------------------------------------------------------
    p.reset();
    p.setFieldValue('IsSliceTiming', true);
    check(p.isFieldEnabled('SliceTiming.SliceOrder') && ...
          p.isFieldEnabled('SliceTiming.SliceNumber') && ...
          p.isFieldEnabled('SliceTiming.ReferenceSlice'), ...
        'IsSliceTiming=1 时层序/层数/参考层可用');
    ctrlOrder = findobj(fig, 'Tag', 'SliceTiming.SliceOrder');
    check(~isempty(ctrlOrder) && strcmp(ctrlOrder(1).Enable, 'on'), ...
        '依赖满足时层序控件 Enable=on');
    p.setFieldValue('IsSliceTiming', false);
    check(~p.isFieldEnabled('SliceTiming.SliceOrder') && ...
          ~p.isFieldEnabled('SliceTiming.SliceNumber'), ...
        'IsSliceTiming=0 时层序/层数禁用');
    check(~isempty(ctrlOrder) && strcmp(ctrlOrder(1).Enable, 'off'), ...
        '依赖不满足时层序控件 Enable=off');

    p.setFieldValue('IsFilter', true);
    check(p.isFieldEnabled('Filter.ALowPass_HighCutoff') && ...
          p.isFieldEnabled('Filter.AHighPass_LowCutoff'), ...
        'IsFilter=1 时滤波参数可用');
    p.setFieldValue('IsFilter', false);
    check(~p.isFieldEnabled('Filter.ALowPass_HighCutoff'), 'IsFilter=0 时滤波参数禁用');

    p.setFieldValue('IsSegment', 2);
    check(p.isFieldEnabled('IsDARTEL') && ...
          p.isFieldEnabled('Segment.AffineRegularisationInSegmentation'), ...
        'IsSegment=2 时 DARTEL 与仿射正则化可用');
    check(p.getState().IsSegment == 2, 'enum 数值型字段写回 State 正确');
    p.setFieldValue('IsSegment', 0);
    check(~p.isFieldEnabled('IsDARTEL'), 'IsSegment=0 时 DARTEL 禁用');

    p.setFieldValue('IsNormalize', 2);
    check(p.isFieldEnabled('IsSmooth') && p.isFieldEnabled('Normalize.VoxSize'), ...
        'IsNormalize>0 时平滑/体素大小可用');
    p.setFieldValue('IsSmooth', true);
    check(p.isFieldEnabled('Smooth.FWHM'), 'IsSmooth>0 时 FWHM 可用');
    p.setFieldValue('IsSmooth', false);
    check(~p.isFieldEnabled('Smooth.FWHM'), 'IsSmooth=0 时 FWHM 禁用');
    p.setFieldValue('IsCovremove', true);
    p.setFieldValue('Covremove.IsHeadMotionScrubbingRegressors', true);
    check(p.isFieldEnabled('Covremove.HeadMotionScrubbingRegressors.FDThreshold'), ...
        '三级依赖（scrubbing FD 阈值）可用');
    check(~p.isFieldEnabled('CalFC.ROIDef'), '未启用 FC/ROI 时 ROI 定义为禁用');

    % 悬停提示（术语库缺失时必须降级为 标签+英文+默认值，且不为空）
    tipEdit = findobj(fig, 'Tag', 'TR');
    tipLabel = findobj(fig, 'Tag', 'lbl:IsSliceTiming');
    check(~isempty(tipEdit) && ischar(tipEdit(1).Tooltip) && ...
          ~isempty(strfind(tipEdit(1).Tooltip, 'TR')), '控件悬停提示已设置（含英文术语）');
    check(~isempty(tipLabel) && ischar(tipLabel(1).Tooltip) && ...
          ~isempty(tipLabel(1).Tooltip), '中文标签悬停提示已设置');
    tipVec = findobj(fig, 'Tag', 'SliceTiming.SliceOrder');
    check(~isempty(tipVec) && ~isempty(strfind(tipVec(1).Tooltip, '输入格式')), ...
        'vector 控件悬停提示包含输入格式说明');

    % ------------------------------------------------------------------
    % 6. vector 解析
    % ------------------------------------------------------------------
    p.reset();
    okV = p.setFieldValue('SliceTiming.SliceOrder', '1:2:33, 2:2:32');
    vOrder = p.getState().SliceTiming.SliceOrder;
    check(okV && numel(vOrder) == 33 && vOrder(1) == 1 && vOrder(end) == 32, ...
        'vector 解析：1:2:33, 2:2:32 → 1×33');
    okV = p.setFieldValue('Normalize.VoxSize', '2 2 2');
    check(okV && isequal(p.getState().Normalize.VoxSize, [2 2 2]), ...
        'vector 解析：2 2 2 → 1×3');
    okV = p.setFieldValue('Normalize.BoundingBox', '[-90 -126 -72; 90 90 108]');
    check(okV && isequal(size(p.getState().Normalize.BoundingBox), [2 3]) && ...
          isequal(p.getState().Normalize.BoundingBox, [-90 -126 -72; 90 90 108]), ...
        'vector 解析：2×3 包围盒');
    okBad = p.setFieldValue('Normalize.VoxSize', 'abc');
    okBad2 = p.setFieldValue('Normalize.VoxSize', '1 2');
    check(~okBad && ~okBad2, '非法/维度错误的 vector 输入被拒绝且不崩溃');
    check(isequal(p.getState().Normalize.VoxSize, [2 2 2]), ...
        '非法输入不改变 State');
    okBad3 = p.setFieldValue('Normalize.VoxSize', '[1 2 3]');
    check(okBad3 && isequal(p.getState().Normalize.VoxSize, [1 2 3]), ...
        '带方括号的合法 vector 输入可用');

    % ------------------------------------------------------------------
    % 7. 搜索 / highlightKey
    % ------------------------------------------------------------------
    ks = p.searchFields('TR');
    check(iscell(ks) && ~isempty(ks) && numel(ks) <= 12, ...
        sprintf('搜索 "TR" 返回 %d 条候选', numel(ks)));
    ks2 = p.searchFields('滤波');
    check(~isempty(ks2), sprintf('中文关键词 "滤波" 返回 %d 条候选', numel(ks2)));
    ks3 = p.searchFields('不存在的字段xyz');
    check(isempty(ks3) && isempty(p.SearchResults), '无匹配搜索返回空且不崩溃');
    p.hideSearchResults();
    p.searchFields('');
    check(isempty(p.SearchResults), '空搜索收起候选面板');

    S = mrw.CfgSchema.entries();
    hiFail = {};
    for i = 1:numel(S)
        try
            okh = p.highlightKey(S(i).Key);
            if ~okh, hiFail{end+1} = S(i).Key; end %#ok<AGROW>
        catch ME
            hiFail{end+1} = sprintf('%s(%s)', S(i).Key, ME.message); %#ok<AGROW>
        end
    end
    check(isempty(hiFail), sprintf('全部 %d 个字段 highlightKey 不报错', numel(S)));
    if ~isempty(hiFail)
        fprintf('      失败：%s\n', strjoin(hiFail, ', '));
    end
    check(p.highlightKey('IsFilter'), 'highlightKey 未知/已知字段返回正确');
    check(~p.highlightKey('NoSuchKey'), 'highlightKey 未知 Key 安全返回 false');
    pause(1.7);   % 等待闪烁计时器恢复，避免截图带高亮

    % ------------------------------------------------------------------
    % 8. 事件与按钮回调
    % ------------------------------------------------------------------
    c1 = changedCount;
    p.setFieldValue('IsRealign', true);
    check(changedCount > c1, 'setFieldValue 触发 Changed 事件');

    btn = findobj(fig, 'Tag', 'subjects:SubjectID');
    check(~isempty(btn), '找到"管理受试者列表"按钮');
    if ~isempty(btn)
        try
            cb = btn(1).ButtonPushedFcn;
            cb(btn(1), []);
        catch ME
            check(false, ['受试者按钮回调异常：' ME.message]);
        end
        check(subjectEditCount > 0, 'RequestSubjectEdit 事件触发');
    end

    dd = findobj(fig, 'Tag', 'presetDropdown');
    check(~isempty(dd), '找到预设下拉框');
    if ~isempty(dd)
        try
            dd(1).Value = '快速检查';
            cb = dd(1).ValueChangedFcn;
            cb(dd(1), []);
        catch ME
            check(false, ['预设回调异常：' ME.message]);
        end
        check(strcmp(presetCalled, '快速检查'), '预设选择回调收到预设名称');
    end

    rb = findobj(fig, 'Tag', 'runButton');
    check(~isempty(rb), '找到"开始预处理"按钮（传入了 RunRequestedFcn）');
    if ~isempty(rb)
        try
            cb = rb(1).ButtonPushedFcn;
            cb(rb(1), []);
        catch ME
            check(false, ['运行按钮回调异常：' ME.message]);
        end
        check(runCalled > 0, 'RunRequestedFcn 被调用');
    end

    % ------------------------------------------------------------------
    % 9. 截图（用全新面板，保证默认收起状态干净）
    % ------------------------------------------------------------------
    shotDir = here;
    fig2 = mrw.UiKit.newFigure('PreprocessPanel 截图', [1280 860]);
    fig2.Position = [60 30 1280 860];
    gl2 = uigridlayout(fig2, [1 1]);
    gl2.Padding = [0 0 0 0];
    gl2.BackgroundColor = mrw.UiKit.colors().bg;
    container2 = uipanel(gl2, 'BorderType', 'none', ...
        'BackgroundColor', mrw.UiKit.colors().bg);
    p2 = mrw.PreprocessPanel(container2, struct( ...
        'PresetNames', {{'默认标准流程', '快速检查'}}, ...
        'PresetSelectedFcn', @(name) disp(name), ...
        'RunRequestedFcn', @() disp('run')));
    show = mrw.CfgSchema.defaults();
    show.WorkingDir = 'D:\MRI_Study\RestingState';
    show.TR = 2.0;
    show.TimePoints = 240;
    show.IsRemoveFirstTimePoints = 1;
    show.RemoveFirstTimePoints = 10;
    show.IsSliceTiming = 1;
    show.SliceTiming.SliceNumber = 33;
    show.IsRealign = 1;
    show.IsSegment = 2;
    show.IsDARTEL = 1;
    show.IsNormalize = 3;
    show.IsSmooth = 2;
    show.IsCovremove = 1;
    show.IsFilter = 1;
    show.IsCalALFF = 1;
    show.IsCalReHo = 1;
    show.IsCalDegreeCentrality = 1;
    show.SubjectID = {'S01', 'S02', 'S03'};
    p2.setState(show);
    p2.highlightKey('TR');                   % 基础设置页，等待闪烁结束
    pause(1.7);
    drawnow;
    pause(0.3);
    saveShot(fig2, fullfile(shotDir, 'out_preprocess_panel.png'));
    p2.highlightKey('IsCovremove');          % 回归与滤波页（参数最密集）
    pause(1.7);
    drawnow;
    pause(0.3);
    saveShot(fig2, fullfile(shotDir, 'out_preprocess_panel_regress.png'));
    p2.highlightKey('Normalize.Timing');     % 标准化与平滑页 + 展开高级选项
    pause(1.7);
    drawnow;
    pause(0.3);
    saveShot(fig2, fullfile(shotDir, 'out_preprocess_panel_advanced.png'));
    p2.searchFields('滤波');                 % 打开搜索候选面板
    drawnow;
    pause(0.3);
    saveShot(fig2, fullfile(shotDir, 'out_preprocess_panel_search.png'));

    % ------------------------------------------------------------------
    % 收尾
    % ------------------------------------------------------------------
    try, close(fig); catch, end
    try, close(fig2); catch, end
    fprintf('\n=== 测试结果：%d 项失败 ===\n', failures);
    if failures > 0
        error('test_preprocess_panel:Failed', '有 %d 项测试未通过', failures);
    end
    fprintf('全部测试通过。\n');
    fprintf('截图：%s\n', fullfile(shotDir, 'out_preprocess_panel.png'));
    fprintf('      %s\n', fullfile(shotDir, 'out_preprocess_panel_regress.png'));
    fprintf('      %s\n', fullfile(shotDir, 'out_preprocess_panel_advanced.png'));
    fprintf('      %s\n', fullfile(shotDir, 'out_preprocess_panel_search.png'));

    % ---------------------- 嵌套辅助函数 ----------------------
    function check(cond, msg)
        if cond
            fprintf('  [通过] %s\n', msg);
        else
            failures = failures + 1;
            fprintf('  [失败] %s\n', msg);
        end
    end

    function onChanged()
        changedCount = changedCount + 1;
    end

    function onSubjectEdit()
        subjectEditCount = subjectEditCount + 1;
    end

    function onPreset(name)
        presetCalled = name;
    end

    function onRun()
        runCalled = runCalled + 1;
    end

    function diffs = diffAgainstSchema(ref, tgt)
        S = mrw.CfgSchema.entries();
        diffs = {};
        for ii = 1:numel(S)
            a = mrw.CfgSchema.getKey(ref, S(ii).Key);
            b = mrw.CfgSchema.getKey(tgt, S(ii).Key);
            if ~valueEqual(a, b)
                diffs{end+1} = S(ii).Key; %#ok<AGROW>
            end
        end
    end

    function tf = valueEqual(a, b)
        if ischar(a) && ischar(b)
            tf = strcmp(a, b);
        elseif iscell(a) && iscell(b)
            if numel(a) ~= numel(b)
                tf = false;
            else
                tf = true;
                for jj = 1:numel(a)
                    if ~valueEqual(a{jj}, b{jj})
                        tf = false;
                        return;
                    end
                end
            end
        elseif islogical(a) || islogical(b)
            tf = isequal(logical(a), logical(b));
        else
            tf = isequal(a, b);
        end
    end

    function saveShot(f, path)
        try
            exportapp(f, path);
            if exist(path, 'file') == 2
                d = dir(path);
                fprintf('  [截图] %s（%d 字节）\n', path, d.bytes);
                if d.bytes < 8000
                    fprintf('  [警告] 截图文件偏小，可能渲染异常\n');
                end
            else
                fprintf('  [警告] 未生成截图：%s\n', path);
            end
        catch ME
            fprintf('  [警告] -batch 下 exportapp 截图失败（已跳过）：%s\n', ME.message);
        end
    end
end
