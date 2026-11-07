function test_native_patch
% test_native_patch  原生 DPABI 界面汉化模块（mrw.NativePatch / mrw.NativeLaunch）测试
%
% 运行方式（-batch，独立 MATLAB 进程，不触碰用户已打开的 MATLAB 窗口）：
%   & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch ^
%       "cd('C:\...\MRI_Workbench'); addpath(pwd); addpath(fullfile(pwd,'tests')); test_native_patch"
%
% 测试内容：
%   1) resources/native_labels.tsv 结构与覆盖率（DPARSFA 全部 119 个 uicontrol 都有行）
%   2) 用 openfig 打开真实 dpabi.fig / DPARSF_main.fig / DPARSFA.fig，
%      断言翻译生效、popupmenu String 不变、unpatch 后逐控件与原始值完全一致
%   3) patchAll / unpatchAll 多窗口批量、幂等、isPatched
%   4) NativeLaunch 打开窗口（不启动 DPARSFA.p）、timer 监视器自动汉化
%   5) 安全性：未识别的文字不被覆盖；异常不影响原界面
%   6) 性能与截图产物（截图写到 %TEMP%\mrw_native_patch_test\，供 read_image 检查中文渲染）
%
% 注意：不启动 DPARSFA.p 的 GUI（内部可能 uiwait），只 openfig 读取 DPARSFA.fig；
%       不修改 D:\Software\DPABI 下任何文件。

    root = fileparts(fileparts(mfilename('fullpath')));
    if exist(fullfile(root, '+mrw'), 'dir') ~= 7
        root = pwd;
    end
    addpath(root);
    outDir = fullfile(tempdir, 'mrw_native_patch_test');
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    global NATIVE_PATCH_TEST %#ok<GVMIS>
    NATIVE_PATCH_TEST = struct('Check', 0, 'Fail', 0, 'Figs', {{}});

    fprintf('\n================ NativePatch 测试 ================\n');
    fprintf('项目根  : %s\n', root);
    fprintf('MATLAB  : %s\n', version);
    fprintf('输出目录: %s\n', outDir);

    cleanupObj = onCleanup(@() local_cleanup()); %#ok<NASGU>

    % ---------------------------------------------------------------
    % 0) 资源文件结构与规则
    % ---------------------------------------------------------------
    T = mrw.NativePatch.labels();
    check(numel(T) == 208, sprintf('native_labels.tsv 应有 208 行，实际 %d', numel(T)));
    check(mrw.NativePatch.labelCount('DPARSFA') == 119, ...
        sprintf('DPARSFA 应有 119 行，实际 %d', mrw.NativePatch.labelCount('DPARSFA')));
    check(mrw.NativePatch.labelCount('dpabi') == 15, ...
        sprintf('dpabi 应有 15 行，实际 %d', mrw.NativePatch.labelCount('dpabi')));
    check(mrw.NativePatch.labelCount('DPARSF_main') == 6, ...
        sprintf('DPARSF_main 应有 6 行，实际 %d', mrw.NativePatch.labelCount('DPARSF_main')));
    check(numel(mrw.NativePatch.knownFigures()) == 9, ...
        sprintf('应覆盖 9 个原生窗口，实际 %d', numel(mrw.NativePatch.knownFigures())));

    keys = cell(numel(T), 1);
    for k = 1:numel(T), keys{k} = [T(k).Figure '#' T(k).Tag]; end
    check(numel(unique(keys)) == numel(keys), '标签表存在重复的 Figure+Tag 行');

    validStyles = {'text', 'pushbutton', 'checkbox', 'radiobutton', 'edit', ...
        'popupmenu', 'listbox', 'panel'};
    for k = 1:numel(T)
        check(any(strcmp(T(k).Style, validStyles)), ...
            sprintf('未知 Style: %s (Figure=%s Tag=%s)', T(k).Style, T(k).Figure, T(k).Tag));
        if strcmp(T(k).Style, 'edit')
            check(isempty(T(k).Chinese), sprintf('edit 控件不应翻译文字: %s', T(k).Tag));
        end
        if ~isempty(T(k).Chinese) && ~strcmp(T(k).Chinese, T(k).English)
            codes = double(T(k).Chinese);
            hasCJK = any((codes >= 19968 & codes <= 40959) | (codes >= 13312 & codes <= 19903));
            check(hasCJK, sprintf('中文标签不含 CJK 字符: %s -> %s', T(k).Tag, T(k).Chinese));
        end
    end

    expDpabi = local_expected_translations(T, 'dpabi');
    expMain = local_expected_translations(T, 'DPARSF_main');
    expA = local_expected_translations(T, 'DPARSFA');
    fprintf('预期翻译控件数: dpabi=%d, DPARSF_main=%d, DPARSFA=%d\n', expDpabi, expMain, expA);
    check(expA >= 80, 'DPARSFA 可翻译控件数异常（<80）');

    % ---------------------------------------------------------------
    % 1) DPARSFA.fig 覆盖率：每个 uicontrol 都能在标签表中找到行
    % ---------------------------------------------------------------
    figA = local_openfig(local_figure_path('DPARSFA'));
    uA = findall(figA, 'Type', 'uicontrol');
    check(numel(uA) == 119, sprintf('DPARSFA.fig 应有 119 个 uicontrol，实际 %d', numel(uA)));
    rowsA = T(strcmp({T.Figure}, 'DPARSFA'));
    nMatch = 0;
    for k = 1:numel(uA)
        tg = get(uA(k), 'Tag');
        st = lower(get(uA(k), 'Style'));
        idx = find(strcmp({rowsA.Tag}, tg), 1);
        if ~isempty(idx) && strcmp(rowsA(idx).Style, st)
            nMatch = nMatch + 1;
        end
    end
    check(nMatch == 119, sprintf('DPARSFA 控件覆盖率应为 119/119，实际 %d/119', nMatch));
    fprintf('DPARSFA 控件覆盖率: %d/119\n', nMatch);
    local_close(figA);

    % ---------------------------------------------------------------
    % 2) dpabi.fig 真实翻译 / 幂等 / 还原
    % ---------------------------------------------------------------
    fprintf('\n--- dpabi.fig ---\n');
    fig = local_openfig(local_figure_path('dpabi'));
    [origStr, origTip] = local_snapshot(fig);
    t0 = tic;
    s = mrw.NativePatch.patchFigure(fig);
    tPatchDpabi = toc(t0);
    check(strcmp(s.Key, 'dpabi'), 'dpabi 图窗识别错误');
    check(s.Found == 15, sprintf('dpabi 应扫描 15 个控件，实际 %d', s.Found));
    check(s.Matched == 15, sprintf('dpabi 标签匹配应为 15，实际 %d', s.Matched));
    check(s.Translated == expDpabi, sprintf('dpabi 翻译数应为 %d，实际 %d', expDpabi, s.Translated));
    check(s.Errors == 0, sprintf('dpabi 翻译异常 %d 个', s.Errors));
    check(mrw.NativePatch.isPatched(fig), 'isPatched(dpabi) 应为 true');
    check(strcmp(get(findobj(fig, 'Tag', 'pushbuttonGradientAnalysis'), 'String'), '梯度分析'), ...
        'dpabi 梯度分析按钮未翻译');
    check(strcmp(get(findobj(fig, 'Tag', 'pushbutton_QC'), 'String'), '质量控制'), ...
        'dpabi 质量控制按钮未翻译');
    check(~isempty(local_get_tip(findobj(fig, 'Tag', 'pushbuttonGradientAnalysis'))), ...
        'dpabi 按钮缺少 Tooltip');

    s2 = mrw.NativePatch.patchFigure(fig);
    check(s2.Translated == 0, '重复 patch 应为幂等（Translated=0）');
    check(s2.AlreadyPatched >= expDpabi, '重复 patch 应识别为已汉化');

    u = mrw.NativePatch.unpatchFigure(fig);
    check(u.Errors == 0, 'dpabi 还原出现异常');
    check(~mrw.NativePatch.isPatched(fig), 'isPatched(dpabi) 还原后应为 false');
    local_check_restore(fig, origStr, origTip, 'dpabi');
    fprintf('dpabi: translated=%d tooltips=%d, patch=%.1fms, 还原逐控件一致\n', ...
        s.Translated, s.Tooltips, tPatchDpabi * 1000);
    local_close(fig);

    % ---------------------------------------------------------------
    % 3) DPARSF_main.fig 真实翻译 / 还原
    % ---------------------------------------------------------------
    fprintf('\n--- DPARSF_main.fig ---\n');
    fig = local_openfig(local_figure_path('DPARSF_main'));
    [origStr, origTip] = local_snapshot(fig);
    s = mrw.NativePatch.patchFigure(fig);
    check(strcmp(s.Key, 'DPARSF_main'), 'DPARSF_main 图窗识别错误');
    check(s.Translated == expMain, ...
        sprintf('DPARSF_main 翻译数应为 %d，实际 %d', expMain, s.Translated));
    check(s.Errors == 0, 'DPARSF_main 翻译异常');
    check(strcmp(get(findobj(fig, 'Tag', 'pushbutton_DPARSFA'), 'String'), 'DPARSF 高级版'), ...
        'DPARSF 高级版按钮未翻译');
    check(strcmp(get(findobj(fig, 'Tag', 'pushbutton_VBM'), 'String'), 'VBM 分析'), ...
        'VBM 按钮未翻译');
    u = mrw.NativePatch.unpatchFigure(fig);
    check(u.Errors == 0, 'DPARSF_main 还原异常');
    local_check_restore(fig, origStr, origTip, 'DPARSF_main');
    fprintf('DPARSF_main: translated=%d tooltips=%d, 还原逐控件一致\n', s.Translated, s.Tooltips);
    local_close(fig);

    % ---------------------------------------------------------------
    % 4) 三个窗口 patchAll / 安全规则 / unpatchAll
    % ---------------------------------------------------------------
    fprintf('\n--- patchAll（dpabi + DPARSF_main + DPARSFA）---\n');
    figD = local_openfig(local_figure_path('dpabi'));
    figM = local_openfig(local_figure_path('DPARSF_main'));
    figA = local_openfig(local_figure_path('DPARSFA'));
    [oD, tD] = local_snapshot(figD);
    [oM, tM] = local_snapshot(figM);
    [oA, tA] = local_snapshot(figA);

    popOrig = get(findobj(figA, 'Tag', 'popupmenuTemplateParameters'), 'String');
    listOrig = get(findobj(figA, 'Tag', 'listSubjectID'), 'String');
    editOrig = {get(findobj(figA, 'Tag', 'editTR'), 'String'), ...
                get(findobj(figA, 'Tag', 'editRemoveFirstTimePoints'), 'String'), ...
                get(findobj(figA, 'Tag', 'edtBandHigh'), 'String'), ...
                get(findobj(figA, 'Tag', 'edtBandLow'), 'String')};

    t0 = tic;
    all = mrw.NativePatch.patchAll('Silent', true);
    tPatchAll = toc(t0);
    check(all.FiguresPatched == 3, sprintf('patchAll 应汉化 3 个窗口，实际 %d', all.FiguresPatched));
    check(all.Translated == expDpabi + expMain + expA, ...
        sprintf('patchAll 翻译总数应为 %d，实际 %d', expDpabi + expMain + expA, all.Translated));
    check(all.Errors == 0, sprintf('patchAll 出现 %d 个异常', all.Errors));
    check(mrw.NativePatch.isPatched(figD) && mrw.NativePatch.isPatched(figM) && ...
        mrw.NativePatch.isPatched(figA), 'patchAll 后三个窗口都应标记为已汉化');

    expectTags = {
        'checkboxRealign',                    '头动校正'
        'checkboxSliceTiming',                '时间层校正'
        'checkboxNormalize',                  '标准化'
        'checkboxSmooth',                     '平滑'
        'checkboxCovremoveAfterNormalize',    '协变量回归'
        'checkbox_IsAutoMask',                '自动脑掩膜'
        'checkbox_IsBet',                     '去颅'
        'checkboxSmoothBeforeVMHC',           '先平滑'
        'checkboxReorientCropT1Img',          '裁剪去颈'
        'pushbuttonRun',                      '运行'
        'pushbuttonQuit',                     '退出'
        'textTR',                             'TR(秒):'
        'textSliceOrder',                     '层顺序:'
        'textTimepoints',                     '时间点数:'
        'txtWorkingDir',                      '工作目录:'
        'txtDPARSF_all',                      '静息态功能磁共振数据处理助手'
        'checkboxCalALFF',                    'ALFF+fALFF'
        'checkboxNewSegment_DARTEL',          '新分割 + DARTEL'
        'radiobuttonNormalize_T1',            'T1 统一分割标准化'
        };
    for k = 1:size(expectTags, 1)
        h = findobj(figA, 'Tag', expectTags{k, 1});
        check(~isempty(h), sprintf('找不到控件 %s', expectTags{k, 1}));
        got = get(h, 'String');
        check(strcmp(got, expectTags{k, 2}), ...
            sprintf('控件 %s 期望 [%s] 实际 [%s]', expectTags{k, 1}, expectTags{k, 2}, got));
    end

    % popupmenu / listbox / edit 的 String 绝不能被改
    check(isequal(get(findobj(figA, 'Tag', 'popupmenuTemplateParameters'), 'String'), popOrig), ...
        'popupmenu 的 String 被修改（禁止！）');
    check(isequal(get(findobj(figA, 'Tag', 'listSubjectID'), 'String'), listOrig), ...
        'listbox 的 String 被修改（禁止！）');
    uAll = findall(figA, 'Type', 'uicontrol');
    editHs = uAll(strcmp(get(uAll, 'Style'), 'edit'));
    check(numel(editHs) >= 19, sprintf('DPARSFA edit 控件数异常: %d', numel(editHs)));
    editVals = get(editHs, 'String');
    if ~iscell(editVals), editVals = {editVals}; end
    for k = 1:numel(editOrig)
        check(any(cellfun(@(x) isequal(x, editOrig{k}), editVals)), ...
            sprintf('edit 控件的数值文字被修改（禁止！）: %s', num2str(editOrig{k})));
    end
    tipPopup = local_get_tip(findobj(figA, 'Tag', 'popupmenuTemplateParameters'));
    check(~isempty(tipPopup), 'popupmenu 缺少 Tooltip（应只加提示、不改 String）');
    fprintf('popupmenu String 未变，Tooltip=%d 字符\n', numel(tipPopup));

    % Tooltip 覆盖：翻译过的控件都应有提示；术语库存在时 edit 也应有提示
    hasGlossary = exist(fullfile(root, 'resources', 'glossary.tsv'), 'file') == 2;
    nTip = 0;
    for k = 1:size(expectTags, 1)
        if ~isempty(local_get_tip(findobj(figA, 'Tag', expectTags{k, 1}))), nTip = nTip + 1; end
    end
    check(nTip == size(expectTags, 1), ...
        sprintf('关键控件 Tooltip 覆盖 %d/%d', nTip, size(expectTags, 1)));
    tipTR = local_get_tip(findobj(figA, 'Tag', 'editTR'));
    if hasGlossary
        check(~isempty(tipTR), '术语库存在时 editTR 应有 Tooltip');
    end
    hSn = findobj(figA, 'Tag', 'editSliceNumber');
    check(~isempty(strfind(local_get_tip(hSn), 'CAUTIOUS')), ...
        'editSliceNumber 的原始英文警告 Tooltip 丢失');

    % 幂等
    all2 = mrw.NativePatch.patchAll('Silent', true);
    check(all2.Translated == 0, '第二次 patchAll 应幂等（Translated=0）');
    check(all2.AlreadyPatched >= expDpabi + expMain + expA, '第二次 patchAll 未识别已汉化控件');

    % 截图产物（供 read_image 检查中文渲染，不写入项目目录）
    shot1 = fullfile(outDir, 'native_patch_DPARSF_main.png');
    shot2 = fullfile(outDir, 'native_patch_DPARSFA.png');
    try
        exportapp(figM, shot1);
        exportapp(figA, shot2);
        check(exist(shot1, 'file') == 2 && dir(shot1).bytes > 1000, 'DPARSF_main 截图生成失败');
        check(exist(shot2, 'file') == 2 && dir(shot2).bytes > 1000, 'DPARSFA 截图生成失败');
        fprintf('截图: %s (%d B)\n      %s (%d B)\n', shot1, dir(shot1).bytes, ...
            shot2, dir(shot2).bytes);
    catch ME
        check(false, sprintf('截图失败: %s', ME.message));
    end

    % unpatchAll 还原
    u = mrw.NativePatch.unpatchAll('Silent', true);
    check(u.FiguresRestored == 3, sprintf('unpatchAll 应还原 3 个窗口，实际 %d', u.FiguresRestored));
    check(u.Errors == 0, 'unpatchAll 出现异常');
    check(~mrw.NativePatch.isPatched(figD) && ~mrw.NativePatch.isPatched(figM) && ...
        ~mrw.NativePatch.isPatched(figA), 'unpatchAll 后仍标记为已汉化');
    local_check_restore(figD, oD, tD, 'dpabi');
    local_check_restore(figM, oM, tM, 'DPARSF_main');
    local_check_restore(figA, oA, tA, 'DPARSFA');
    fprintf('patchAll: 3 窗口 / 翻译 %d / 耗时 %.1f ms；unpatchAll 全部逐控件与原始值一致\n', ...
        all.Translated, tPatchAll * 1000);

    % ---------------------------------------------------------------
    % 5) 安全性：不覆盖认不出的文字；无标签图窗不报错
    % ---------------------------------------------------------------
    fprintf('\n--- 安全性 ---\n');
    hVBM = findobj(figM, 'Tag', 'pushbutton_VBM');
    set(hVBM, 'String', 'Custom Tool XYZ');
    s = mrw.NativePatch.patchFigure(figM);
    check(s.Errors == 0, '未知文字场景出现异常');
    check(strcmp(get(hVBM, 'String'), 'Custom Tool XYZ'), '未识别的文字被覆盖（不安全！）');
    check(s.Skipped >= 1, '未识别文字未计入 Skipped');
    fprintf('认不出的按钮文字保持原样，Skipped=%d\n', s.Skipped);
    mrw.NativePatch.unpatchAll('Silent', true);

    fUnknown = local_openfig('');
    u = uicontrol(fUnknown, 'Style', 'pushbutton', 'String', 'Hello', 'Position', [10 10 80 24]);
    s = mrw.NativePatch.patchFigure(fUnknown);
    check(isempty(s.Key) && s.Translated == 0 && s.Errors == 0, ...
        '未知图窗 patchFigure 不应有副作用');
    check(strcmp(get(u, 'String'), 'Hello'), '未知图窗的控件被修改');
    check(~mrw.NativePatch.isPatched(fUnknown), '未知图窗不应被标记为已汉化');
    local_close(fUnknown);

    fFake = local_openfig('');
    set(fFake, 'Tag', 'figureDPABI', 'Name', 'dpabi');
    s = mrw.NativePatch.patchFigure(fFake);
    check(strcmp(s.Key, 'dpabi') && s.Found == 0 && s.Errors == 0, ...
        '空的原生图窗 patchFigure 应零异常');
    mrw.NativePatch.unpatchFigure(fFake);
    local_close(fFake);

    % 用户自己的窗口标题含 ROI 字样、但没有 DPABI 特征控件 -> 不应误识别/误翻译
    fUser = local_openfig('');
    set(fUser, 'Name', 'ROI masks for my study', 'Tag', 'figure1');
    uBtn = uicontrol(fUser, 'Style', 'pushbutton', 'String', 'AAL atlas', ...
        'Position', [10 10 110 24]);
    s = mrw.NativePatch.patchFigure(fUser);
    check(isempty(s.Key), '用户窗口被误识别为 DPABI 子界面');
    check(strcmp(get(uBtn, 'String'), 'AAL atlas'), '用户窗口文字被误翻译');
    mrw.NativePatch.unpatchFigure(fUser);
    local_close(fUser);
    local_close(figD); local_close(figM); local_close(figA);

    % ---------------------------------------------------------------
    % 6) NativeLaunch：openfig 打开 + 自动汉化；timer 监视器
    % ---------------------------------------------------------------
    fprintf('\n--- NativeLaunch ---\n');
    fMain = mrw.NativeLaunch.openDPARSFMain('AutoMonitor', false, 'Silent', true);
    register_fig(fMain);
    check(~isempty(fMain) && isvalid(fMain), 'NativeLaunch.openDPARSFMain 未返回有效图窗');
    check(mrw.NativePatch.isPatched(fMain), 'openDPARSFMain 后未自动汉化');
    check(strcmp(get(findobj(fMain, 'Tag', 'pushbutton_DPARSFA'), 'String'), 'DPARSF 高级版'), ...
        'openDPARSFMain 打开的窗口未汉化');
    check(strcmp(get(fMain, 'Name'), 'DPARSF'), 'DPARSF_main 窗口标题应为 DPARSF');
    fprintf('openDPARSFMain: 已打开并自动汉化（标题 DPARSF）\n');
    mrw.NativePatch.unpatchAll('Silent', true);
    local_close(fMain);

    fDpabi = mrw.NativeLaunch.openDPABI('AutoMonitor', false, 'Silent', true);
    register_fig(fDpabi);
    check(~isempty(fDpabi) && isvalid(fDpabi), 'NativeLaunch.openDPABI 未返回有效图窗');
    check(mrw.NativePatch.isPatched(fDpabi), 'openDPABI 后未自动汉化');
    check(strcmp(get(fDpabi, 'Name'), 'DPABI'), 'DPABI 主窗口标题应为 DPABI');
    fprintf('openDPABI: 已打开并自动汉化（标题 DPABI）\n');
    mrw.NativePatch.unpatchAll('Silent', true);
    local_close(fDpabi);

    nTimers = mrw.NativeLaunch.stopPatchMonitor();
    mrw.NativeLaunch.startPatchMonitor(3);
    check(mrw.NativeLaunch.isPatchMonitorRunning(), 'startPatchMonitor 后监视器未运行');
    fMon = local_openfig(local_figure_path('DPARSF_main'));
    patched = false;
    for w = 1:8
        pause(0.4);
        drawnow;
        if mrw.NativePatch.isPatched(fMon), patched = true; break; end
    end
    check(patched, 'timer 监视器未在 3.2s 内自动汉化新图窗');
    nStop = mrw.NativeLaunch.stopPatchMonitor();
    check(nStop >= 1, 'stopPatchMonitor 未清理 timer');
    check(~mrw.NativeLaunch.isPatchMonitorRunning(), 'stopPatchMonitor 后监视器仍在运行');
    check(mrw.NativePatch.isPatched(fMon), '监视器汉化结果丢失');
    fprintf('timer 监视器: 自动汉化新窗口成功，清理 %d 个 timer（此前清理 %d）\n', nStop, nTimers);
    mrw.NativePatch.unpatchAll('Silent', true);
    local_close(fMon);

    % openDPARSFA 的模板解析（用不存在的模板触发错误，不会真正启动 DPARSFA.p GUI）
    tplErr = '';
    try
        mrw.NativeLaunch.openDPARSFA('NoSuchTemplate_ZZZ', 'AutoMonitor', false, 'Silent', true);
    catch ME
        tplErr = ME.message;
    end
    check(~isempty(strfind(tplErr, 'Template_Blank')) || ~isempty(strfind(tplErr, '可用模板')), ...
        'openDPARSFA 模板错误信息未列出可用模板');
    check(~mrw.NativeLaunch.isPatchMonitorRunning(), '模板解析失败后不应残留监视器');
    fprintf('openDPARSFA 模板解析: 非法模板错误信息正常，无残留监视器\n');

    % ---------------------------------------------------------------
    % 7) 性能
    % ---------------------------------------------------------------
    fprintf('\n--- 性能 ---\n');
    mrw.NativePatch.reset();
    mrw.NativePatch.patchAll('Silent', true);   % 预热标签缓存
    figA = local_openfig(local_figure_path('DPARSFA'));
    t0 = tic; s = mrw.NativePatch.patchFigure(figA); t1 = toc(t0);
    check(s.Translated == expA, ...
        sprintf('性能测试中 DPARSFA 翻译数应为 %d，实际 %d', expA, s.Translated));
    check(t1 < 2.0, sprintf('DPARSFA 单窗汉化耗时过长: %.2fs', t1));
    t0 = tic; mrw.NativePatch.unpatchFigure(figA); t2 = toc(t0);
    check(t2 < 1.0, sprintf('DPARSFA 还原耗时过长: %.2fs', t2));
    fprintf('DPARSFA 单窗: 汉化 %.1f ms / 还原 %.1f ms（%d 控件）\n', ...
        t1 * 1000, t2 * 1000, s.Found);
    local_close(figA);

    mrw.NativeLaunch.stopPatchMonitor();
    mrw.NativePatch.unpatchAll('Silent', true);

    % ---------------------------------------------------------------
    % 汇总
    % ---------------------------------------------------------------
    fprintf('\n================ 结果：%d 项断言，%d 失败 ================\n', ...
        NATIVE_PATCH_TEST.Check, NATIVE_PATCH_TEST.Fail);
    if NATIVE_PATCH_TEST.Fail > 0
        error('test_native_patch:failed', '有 %d 项断言失败', NATIVE_PATCH_TEST.Fail);
    end
    fprintf('TEST PASSED\n');
end

% ====================================================================
% 局部辅助函数
% ====================================================================

function check(cond, msg)
    global NATIVE_PATCH_TEST %#ok<GVMIS>
    if isempty(NATIVE_PATCH_TEST)
        NATIVE_PATCH_TEST = struct('Check', 0, 'Fail', 0, 'Figs', {{}});
    end
    NATIVE_PATCH_TEST.Check = NATIVE_PATCH_TEST.Check + 1;
    if cond
        return;
    end
    NATIVE_PATCH_TEST.Fail = NATIVE_PATCH_TEST.Fail + 1;
    fprintf(2, '[FAIL] %s\n', msg);
    st = dbstack('-completenames');
    if numel(st) >= 2
        fprintf(2, '       位于 %s:%d\n', st(2).file, st(2).line);
    end
end

function n = local_expected_translations(T, figKey)
    rows = T(strcmp({T.Figure}, figKey));
    translateStyles = {'text', 'pushbutton', 'checkbox', 'radiobutton', 'togglebutton', 'panel'};
    n = 0;
    for k = 1:numel(rows)
        if any(strcmp(rows(k).Style, translateStyles)) && ...
                ~isempty(rows(k).English) && ~isempty(rows(k).Chinese) && ...
                ~strcmp(rows(k).Chinese, rows(k).English)
            n = n + 1;
        end
    end
end

function fp = local_figure_path(key)
    root = mrw.NativeLaunch.dpabiRoot();
    switch key
        case 'dpabi',       fp = fullfile(root, 'dpabi.fig');
        case 'DPARSF_main', fp = fullfile(root, 'DPARSF', 'DPARSF_main.fig');
        case 'DPARSFA',     fp = fullfile(root, 'DPARSF', 'DPARSFA.fig');
        otherwise,          error('未知窗口 %s', key);
    end
end

function fig = local_openfig(pathOrEmpty)
% 打开原生图窗并登记（cleanup 时只关闭测试自己打开的窗口）
    if isempty(pathOrEmpty)
        fig = figure('Visible', 'off');
    else
        fig = openfig(pathOrEmpty, 'new', 'invisible');
        drawnow;
    end
    register_fig(fig);
end

function register_fig(fig)
    global NATIVE_PATCH_TEST %#ok<GVMIS>
    if isempty(NATIVE_PATCH_TEST)
        NATIVE_PATCH_TEST = struct('Check', 0, 'Fail', 0, 'Figs', {{}});
    end
    if ~isempty(fig) && isvalid(fig)
        NATIVE_PATCH_TEST.Figs{end+1} = fig;
    end
end

function [origStr, origTip] = local_snapshot(fig)
% 记录图窗内全部 uicontrol / uipanel 的 String(Title) 与 Tooltip 原值
    hs = [findall(fig, 'Type', 'uicontrol'); findall(fig, 'Type', 'uipanel'); ...
          findall(fig, 'Type', 'uibuttongroup')];
    origStr = cell(numel(hs), 3);
    origTip = cell(numel(hs), 2);
    for k = 1:numel(hs)
        h = hs(k);
        typ = get(h, 'Type');
        if strcmp(typ, 'uicontrol')
            prop = 'String';
        else
            prop = 'Title';
        end
        origStr{k, 1} = h;
        origStr{k, 2} = prop;
        origStr{k, 3} = get(h, prop);
        origTip{k, 1} = h;
        origTip{k, 2} = local_get_tip(h);
    end
end

function local_check_restore(fig, origStr, origTip, label)
    hs = [findall(fig, 'Type', 'uicontrol'); findall(fig, 'Type', 'uipanel'); ...
          findall(fig, 'Type', 'uibuttongroup')];
    check(numel(hs) == size(origStr, 1), sprintf('%s 还原后控件数变化', label));
    bad = 0;
    for k = 1:size(origStr, 1)
        h = origStr{k, 1};
        if ~isvalid(h), continue; end
        cur = get(h, origStr{k, 2});
        if ~isequal(cur, origStr{k, 3})
            bad = bad + 1;
            if bad <= 5
                fprintf(2, '[FAIL] %s 还原不一致 %s\n', label, get(h, 'Tag'));
            end
        end
    end
    check(bad == 0, sprintf('%s 还原后 %d 个控件文字与原始不一致', label, bad));
    bad = 0;
    for k = 1:size(origTip, 1)
        h = origTip{k, 1};
        if ~isvalid(h), continue; end
        cur = local_get_tip(h);
        if ~strcmp(cur, origTip{k, 2})
            bad = bad + 1;
            if bad <= 5
                fprintf(2, '[FAIL] %s 还原后 Tooltip 不一致 %s\n', label, get(h, 'Tag'));
            end
        end
    end
    check(bad == 0, sprintf('%s 还原后 %d 个控件 Tooltip 与原始不一致', label, bad));
end

function t = local_get_tip(h)
    t = '';
    try
        if isprop(h, 'Tooltip')
            t = get(h, 'Tooltip');
        elseif isprop(h, 'TooltipString')
            t = get(h, 'TooltipString');
        end
    catch
        t = '';
    end
    if ~ischar(t), t = ''; end
end

function local_close(fig)
    try
        if ~isempty(fig) && isvalid(fig)
            close(fig, 'force');
        end
    catch
        try
            delete(fig);
        catch
        end
    end
end

function local_cleanup()
    global NATIVE_PATCH_TEST %#ok<GVMIS>
    try, mrw.NativeLaunch.stopPatchMonitor(); catch, end
    try
        if ~isempty(NATIVE_PATCH_TEST) && isfield(NATIVE_PATCH_TEST, 'Figs')
            figs = NATIVE_PATCH_TEST.Figs;
            for k = 1:numel(figs)
                try
                    if isvalid(figs{k})
                        try, mrw.NativePatch.unpatchFigure(figs{k}); catch, end
                        local_close(figs{k});
                    end
                catch
                end
            end
        end
    catch
    end
end
