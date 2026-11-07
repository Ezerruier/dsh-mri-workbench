function test_qc_ui_v2_accept()
% test_qc_ui_v2_accept  QC UI v2 独立验收（Lead 编写，不轻信实现者单测）
%
% 目的：按 docs/QC_UI_V2_CONTRACT.md 的公共接口，做跨模块端到端验收：
%   QcView 几何引擎 + QcPanel 三正交/AC-PC/多切片/FD/排序筛选/状态 JSON +
%   QcAlignDialog + 边界容错 + 截图。
%
% 运行（项目根目录）：
%   & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch ...
%       "cd('...\MRI_Workbench'); addpath(pwd); addpath('tests'); test_qc_ui_v2_accept"
%
% 说明：依赖 tests/qc_fixture.m 生成合成 DPARSF 数据；截图写入 tests/。

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root);
    addpath(here);

    fprintf('=== QC UI v2 独立验收（Lead acceptance） ===\n');
    fprintf('MATLAB %s\n', version);

    failures = 0;
    nAssertions = 0;

    base = qc_fixture();
    fprintf('测试数据：%s\n', base);

    % ==================================================================
    % 1. 构造 + v2 状态字段
    % ==================================================================
    fig = mrw.UiKit.newFigure('QC UI v2 验收', [1440 900]);
    fig.Position = [40 20 1440 900];
    gl = uigridlayout(fig, [1 1]);
    gl.Padding = [0 0 0 0];
    gl.BackgroundColor = mrw.UiKit.colors().bg;
    container = uipanel(gl, 'BorderType', 'none', ...
        'BackgroundColor', mrw.UiKit.colors().bg);

    t0 = tic;
    p = mrw.QcPanel(container, struct('WorkingDir', base, 'Modality', 'T1', ...
        'Footer', true));
    buildT = toc(t0);
    fprintf('构造耗时：%.2f s，控件数：%d，版本：%s\n', buildT, p.ControlCount, p.Version);
    check(buildT < 6.0, sprintf('面板构造 < 6 s（实际 %.2f s）', buildT));
    check(isprop(p, 'Version') && ~isempty(p.Version), '面板有 Version 属性');

    st = p.getState();
    check(isfield(st, 'ViewMode'), 'getState 含 ViewMode（v2 字段）');
    check(isfield(st, 'Display'), 'getState 含 Display（QcView 信息）');
    check(isfield(st, 'CrosshairVoxel'), 'getState 含 CrosshairVoxel');
    check(isfield(st, 'FD') && isfield(st.FD, 'Values'), 'getState 含 FD 曲线数据');
    check(isfield(st, 'Filter') && isfield(st, 'Sort'), 'getState 含 Filter/Sort');
    check(ischar(st.ViewMode) || isstring(st.ViewMode), 'ViewMode 为字符串');

    vi = p.getViewInfo();
    check(isstruct(vi) && isfield(vi, 'HasVolume') && vi.HasVolume, ...
        'getViewInfo 返回有效几何信息（HasVolume=true）');
    check(isfield(vi, 'DisplayMatrix') && isequal(size(vi.DisplayMatrix), [4 4]), ...
        'getViewInfo.DisplayMatrix 为 4x4');
    check(isfield(vi, 'CrosshairVoxel') && numel(vi.CrosshairVoxel) == 3, ...
        'getViewInfo.CrosshairVoxel 为 1x3');

    % ==================================================================
    % 2. 三正交模式 + 联动十字线
    % ==================================================================
    p.setViewMode('triple');
    st = p.getState();
    check(strcmp(st.ViewMode, 'triple'), 'setViewMode(triple) 生效');
    axAll = findall(fig, 'Type', 'axes');
    imAll = findall(fig, 'Type', 'image');
    fprintf('三正交模式：axes=%d，image=%d\n', numel(axAll), numel(imAll));
    check(numel(axAll) >= 4, sprintf('三正交模式 axes >= 4（实际 %d）', numel(axAll)));
    check(numel(imAll) >= 3, sprintf('三正交模式至少 3 幅图（实际 %d）', numel(imAll)));

    % 三视图各自的标题/切片标签应包含 3 个方向
    txt = collect_text(fig);
    hasA = contains_any(txt, {'水平', '横断', 'Axial'});
    hasC = contains_any(txt, {'冠状', 'Coronal'});
    hasS = contains_any(txt, {'矢状', 'Sagittal'});
    check(hasA && hasC && hasS, '三正交视图标题包含水平/冠状/矢状三个方向');

    % 十字线点击/设置：三视图图像内容随十字线改变
    cDataBefore = get_image_cdata(fig);
    p.setCrosshairVoxel([20 22 12]);
    drawnow;
    vi2 = p.getViewInfo();
    check(norm(double(vi2.CrosshairVoxel(:)') - [20 22 12]) < 1.5, ...
        sprintf('setCrosshairVoxel 生效（实际 [%g %g %g]）', vi2.CrosshairVoxel));
    cDataAfter = get_image_cdata(fig);
    check(~isequal(cDataBefore, cDataAfter), '三视图图像随十字线位置更新');

    % 越界十字线：clamp 且不崩溃
    try
        p.setCrosshairVoxel([-50 1e6 0]);
        drawnow;
        vi3 = p.getViewInfo();
        check(all(isfinite(vi3.CrosshairVoxel)) && all(vi3.CrosshairVoxel >= 0), ...
            '越界十字线被 clamp 到体积内且不崩溃');
    catch ME
        check(false, ['越界十字线异常：' ME.message]);
        vi3 = vi2;
    end
    p.setCrosshairVoxel(vi2.CrosshairVoxel);

    % 十字线开关
    chk = findall(fig, 'Tag', 'qcCrosshairCheck');
    check(~isempty(chk), '存在十字线开关（Tag=qcCrosshairCheck）');
    if ~isempty(chk)
        try
            oldVal = chk(1).Value;
            chk(1).Value = ~oldVal;
            feval(chk(1).ValueChangedFcn, chk(1), struct('Value', chk(1).Value, ...
                'Source', chk(1), 'OldValue', oldVal));
            drawnow;
            check(islogical(chk(1).Value) && chk(1).Value == ~oldVal, '十字线开关可切换');
            chk(1).Value = oldVal;
            feval(chk(1).ValueChangedFcn, chk(1), struct('Value', oldVal, ...
                'Source', chk(1), 'OldValue', ~oldVal));
        catch ME
            check(false, ['十字线开关回调异常：' ME.message]);
        end
    end

    % ==================================================================
    % 3. AC-PC 配平（显示层）
    % ==================================================================
    p.setViewMode('triple');
    p.setCrosshairVoxel([20 22 17]);
    ac = [20 28 17];   % 体素间距1mm；PC位于AC后方12mm（-Y）
    pc = [20 16 17];
    try
        p.setACPC(ac, pc);
        drawnow;
        stA = p.getState();
        viA = p.getViewInfo();
        check(strcmp(stA.Display.Mode, 'acpc'), 'setACPC 后 Display.Mode = acpc');
        check(isfield(viA, 'ACPC') && abs(viA.ACPC.distanceMm - 12) < 1.0, ...
            sprintf('AC-PC 距离 ≈ 12 mm（实际 %.2f）', viA.ACPC.distanceMm));
        check(~isequal(viA.DisplayMatrix, eye(4)), 'AC-PC 后显示矩阵不再是单位阵');
        % 用 QcView 直接验证 AC/PC 几何（AC→display 原点，PC→后方-Y）
        [t1vol, t1hdr] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'));
        V = mrw.QcView(t1vol, t1hdr);
        V.setCrosshair([20 22 17]);
        V.setAcPc(ac, pc);
        acD = V.voxelToDisplay(ac);
        pcD = V.voxelToDisplay(pc);
        check(norm(acD(:)') < 0.5, ...
            sprintf('AC 映射到显示原点（实际 [%g %g %g]）', acD));
        check(pcD(2) < 0 && abs(pcD(1)) < 0.5 && abs(pcD(3)) < 0.5, ...
            sprintf('PC 映射到 -Y 轴（实际 [%g %g %g]）', pcD));
    catch ME
        check(false, ['AC-PC 配平异常：' ME.message]);
    end

    % 手动方位微调 + 重置
    try
        p.setManualOrientation([2 -1 3], [5 -4 2]);
        viM = p.getViewInfo();
        manT = field_local(viM, {'Manual', 'TranslationMm'});
        if isempty(manT)
            manT = field_local(viM, {'Manual', 'translationMm'});
        end
        manR = field_local(viM, {'Manual', 'RotationDeg'});
        if isempty(manR)
            manR = field_local(viM, {'Manual', 'rotationDeg'});
        end
        check(~isempty(manT) && any(abs(manT) > 0.1), '手动平移参数进入显示变换');
        check(~isempty(manR) && any(abs(manR) > 0.1), '手动旋转参数进入显示变换');
        p.resetOrientation();
        viR = p.getViewInfo();
        check(strcmp(viR.Mode, 'native'), 'resetOrientation 后回到 native');
        I4 = eye(4);
        check(max(abs(viR.DisplayMatrix(:) - I4(:))) < 1e-9, ...
            'resetOrientation 后显示矩阵为单位阵');
    catch ME
        check(false, ['手动方位/重置异常：' ME.message]);
    end

    % ==================================================================
    % 4. 多切片网格
    % ==================================================================
    try
        p.setViewMode('montage');
        drawnow;
        stM = p.getState();
        check(strcmp(stM.ViewMode, 'montage'), 'setViewMode(montage) 生效');
        axM = findall(fig, 'Type', 'axes');
        imM = findall(fig, 'Type', 'image');
        check(numel(axM) >= 2 && numel(imM) >= 1, ...
            sprintf('多切片模式仍有图像（axes=%d,image=%d）', numel(axM), numel(imM)));
        % 图像数据尺寸应大于单切片（拼图）
        big = 0;
        for ii = 1:numel(imM)
            cd = get(imM(ii), 'CData');
            if numel(cd) > 4 * 64 * 30 / 25
                big = big + 1;
            end
        end
        check(big >= 1, '多切片网格存在拼图图像');
    catch ME
        check(false, ['多切片网格异常：' ME.message]);
    end

    % ==================================================================
    % 5. FD 曲线与头动联动
    % ==================================================================
    try
        p.setViewMode('single');
        p.setSubject(1);
        drawnow;
        % 单视图十字线开关（v2：单视图也应绘制十字线，不能只有三正交）
        p.setCrosshairVisible(true);
        drawnow;
        nClOn = numel(findall(fig, 'Type', 'constantline'));
        check(nClOn >= 2, sprintf('单视图开启十字线后有 2 条线（实际 %d）', nClOn));
        p.setCrosshairVisible(false);
        drawnow;
        nClOff = numel(findall(fig, 'Type', 'constantline'));
        check(nClOff < nClOn, '单视图关闭十字线后线条消失');
        p.setCrosshairVisible(true);
        drawnow;
        stF = p.getState();
        check(isfield(stF.FD, 'Type') && ~isempty(stF.FD.Type), 'FD 类型存在');
        check(numel(stF.FD.Values) > 10, ...
            sprintf('FD 逐帧序列非空（%d 帧）', numel(stF.FD.Values)));
        % MeanFD 必须与窗口显示（HeadMotion.tsv 第21列）一致；序列均值另存
        check(abs(stF.FD.MeanFD - 0.08) < 1e-6, ...
            sprintf('Sub01 MeanFD 与 HeadMotion.tsv 一致（%.4f）', stF.FD.MeanFD));
        if isfield(stF.FD, 'SeriesMeanFD')
            check(abs(stF.FD.SeriesMeanFD - mean(stF.FD.Values)) < 1e-6, ...
                sprintf('SeriesMeanFD 与逐帧序列均值一致（%.4f）', stF.FD.SeriesMeanFD));
        end
        thr = stF.FD.Threshold;
        expectedBad = find(stF.FD.Values >= thr);
        if isfield(stF.FD, 'BadFrames')
            check(isequal(sort(stF.FD.BadFrames(:)'), sort(expectedBad(:)')), ...
                sprintf('坏帧列表与阈值一致（阈值 %.2f mm）', thr));
        end
        % FD 曲线 axes 存在且有线条
        fdAx = findall(fig, 'Tag', 'qcFdAxes');
        check(~isempty(fdAx), '存在 FD 曲线 axes（Tag=qcFdAxes）');
        if ~isempty(fdAx) && isprop(fdAx(1), 'Children')
            nLines = numel(findobj(fdAx(1), 'Type', 'line'));
            check(nLines >= 1, sprintf('FD 曲线已绘制线条（%d 条）', nLines));
        end
        % 切换受试者：MeanFD 联动
        p.setSubject(2);
        stF2 = p.getState();
        check(abs(stF2.FD.MeanFD - 0.25) < 1e-6, ...
            sprintf('切换受试者后 FD 联动（Sub02 MeanFD=%.4f）', stF2.FD.MeanFD));
        p.setSubject(1);
    catch ME
        check(false, ['FD 曲线/头动联动异常：' ME.message]);
    end

    % ==================================================================
    % 6. 排序 / 筛选
    % ==================================================================
    try
        p.setViewMode('single');
        p.setModality('T1');
        p.setFilterOnlyUnscored(false);
        stAll = p.getState();
        nAll = stAll.VisibleSubjectCount;
        check(nAll == 3, sprintf('默认显示全部 3 名受试者（实际 %d）', nAll));

        fdrop = findall(fig, 'Tag', 'qcFilter');
        check(~isempty(fdrop), '存在筛选下拉（Tag=qcFilter）');
        if ~isempty(fdrop) && isprop(fdrop(1), 'ValueChangedFcn') && ...
                ~isempty(fdrop(1).ValueChangedFcn)
            f = fdrop(1);
            items = f.ItemsData;
            % 选择「已评分」筛选：初始无人评分 → 0 人
            target = find(contains(lower(string(items)), 'scored') & ...
                ~contains(lower(string(items)), 'unscored'), 1);
            if isempty(target), target = 1; end
            oldVal = f.Value;
            if iscell(items), f.Value = items{target}; else, f.Value = items(target); end
            feval(f.ValueChangedFcn, f, struct('Value', f.Value, ...
                'Source', f, 'OldValue', oldVal));
            drawnow;
            stScored = p.getState();
            check(isfield(stScored, 'Filter') && ~isempty(stScored.Filter), ...
                '筛选下拉触发了状态更新');
            % 恢复全部
            f.Value = oldVal;
            feval(f.ValueChangedFcn, f, struct('Value', f.Value, ...
                'Source', f, 'OldValue', oldVal));
            drawnow;
        end

        sdrop = findall(fig, 'Tag', 'qcSort');
        check(~isempty(sdrop), '存在排序下拉（Tag=qcSort）');
        if ~isempty(sdrop) && isprop(sdrop(1), 'ValueChangedFcn') && ...
                ~isempty(sdrop(1).ValueChangedFcn)
            s = sdrop(1);
            items = s.ItemsData;
            target = find(contains(lower(string(items)), 'meanfd') | ...
                contains(lower(string(items)), 'fd'), 1);
            if isempty(target), target = numel(items); end
            oldVal = s.Value;
            if iscell(items), s.Value = items{target}; else, s.Value = items(target); end
            feval(s.ValueChangedFcn, s, struct('Value', s.Value, ...
                'Source', s, 'OldValue', oldVal));
            drawnow;
            stSort = p.getState();
            check(isfield(stSort, 'Sort') && ~isempty(stSort.Sort), '排序下拉触发了状态更新');
            s.Value = oldVal;
            feval(s.ValueChangedFcn, s, struct('Value', s.Value, ...
                'Source', s, 'OldValue', oldVal));
            drawnow;
        end
    catch ME
        check(false, ['排序/筛选异常：' ME.message]);
    end

    % ==================================================================
    % 7. 状态 JSON（给 Agent 实时指导）
    % ==================================================================
    stateFile = fullfile(base, 'QC', '.qcviewer_state.json');
    tmpJson = fullfile(tempdir, sprintf('qc_state_%d.json', round(rand() * 1e9)));
    try
        p.setViewMode('triple');
        p.setCrosshairVoxel([20 22 17]);
        p.setACPC([20 22 22], [20 22 10]);
        drawnow;
        p.exportState(tmpJson);
        check(exist(tmpJson, 'file') == 2, 'exportState 写出 JSON 文件');
        J = jsondecode(fileread(tmpJson));
        check(isfield(J, 'schema') && contains(string(J.schema), 'qcviewer.state.v2'), ...
            '状态 JSON schema = mrw.qcviewer.state.v2');
        check(isfield(J, 'crosshairVoxel') && numel(J.crosshairVoxel) == 3, ...
            '状态 JSON 含 crosshairVoxel');
        check(isfield(J, 'display') && isfield(J.display, 'matrix'), ...
            '状态 JSON 含 display.matrix');
        check(isfield(J, 'viewMode') && ~isempty(J.viewMode), '状态 JSON 含 viewMode');
        check(isfield(J, 'headMotion') && isfield(J.headMotion, 'fdType'), ...
            '状态 JSON 含 headMotion');
        check(isfield(J, 'progress'), '状态 JSON 含 progress');
        check(isfield(J, 'subjectID') && ~isempty(J.subjectID), '状态 JSON 含 subjectID');
        % 自动状态文件：面板操作后应存在
        check(exist(stateFile, 'file') == 2, ...
            sprintf('面板自动写状态文件：%s', stateFile));
        if exist(stateFile, 'file') == 2
            J2 = jsondecode(fileread(stateFile));
            check(isfield(J2, 'schema'), '自动状态文件 JSON 可解析');
        end
    catch ME
        check(false, ['状态 JSON 异常：' ME.message]);
    end

    % ==================================================================
    % 8. 方位校准对话框
    % ==================================================================
    try
        d = mrw.QcAlignDialog(p);
        drawnow;
        check(~isempty(d), 'QcAlignDialog 构造成功');
        dialFigs = findall(groot, 'Type', 'figure');
        found = false;
        for ii = 1:numel(dialFigs)
            nm = get(dialFigs(ii), 'Name');
            if contains(string(nm), '方位校准')
                found = true;
            end
        end
        check(found, '方位校准对话框窗口存在');
        % 对话框中的按钮/输入控件应有中文 Tooltip（抽查）
        nCtrl = 0; nMissing = 0;
        types = {'uibutton', 'uidropdown', 'uieditfield', 'uicheckbox', ...
            'uislider', 'uiradiobutton'};
        for tt = 1:numel(types)
            hs = findall(groot, 'Type', types{tt});
            for hh = 1:numel(hs)
                % 只统计方位校准窗口后的控件
                f = ancestor(hs(hh), 'figure');
                if isempty(f) || ~contains(string(get(f, 'Name')), '方位校准')
                    continue;
                end
                nCtrl = nCtrl + 1;
                if isempty(get(hs(hh), 'Tooltip'))
                    nMissing = nMissing + 1;
                end
            end
        end
        fprintf('方位校准对话框：控件 %d，缺 Tooltip %d\n', nCtrl, nMissing);
        check(nCtrl >= 8, sprintf('方位校准对话框控件 >= 8（实际 %d）', nCtrl));
        check(nMissing == 0, sprintf('方位校准对话框控件均有 Tooltip（缺 %d）', nMissing));
        try, delete(d); catch, end
        for ii = 1:numel(dialFigs)
            if isvalid(dialFigs(ii)) && contains(string(get(dialFigs(ii), 'Name')), '方位校准')
                delete(dialFigs(ii));
            end
        end
    catch ME
        check(false, ['方位校准对话框异常：' ME.message]);
    end

    % ==================================================================
    % 9. 边界容错
    % ==================================================================
    try
        vErr = mrw.QcView([], []);
        check(isfield(vErr.getInfo(), 'HasVolume') && ~vErr.getInfo().HasVolume, ...
            'QcView 空体积构造不崩溃且 HasVolume=false');
        [eImg, eInfo] = vErr.slice('axial', 1);
        check(isempty(eImg) && isstruct(eInfo) && isfield(eInfo, 'Message') && ...
            ~isempty(eInfo.Message), 'QcView 空体积切片返回中文提示');
    catch ME
        check(false, ['QcView 边界异常：' ME.message]);
    end
    try
        p.setACPC([1 1 1], [1 1 1]);   % AC=PC 应失败但不崩溃
        drawnow;
        check(true, 'AC=PC 配平失败时不崩溃');
    catch ME
        check(false, ['AC=PC 配平异常：' ME.message]);
    end

    % ==================================================================
    % 10. 截图（真实渲染）
    % ==================================================================
    p.setViewMode('triple');
    p.setCrosshairVoxel([20 22 17]);
    p.setACPC([20 22 22], [20 22 10]);
    drawnow;
    pause(0.5);
    shot1 = fullfile(here, 'out_qc_v2_accept_triple_acpc.png');
    save_shot(fig, shot1);

    p.resetOrientation();
    p.setViewMode('montage');
    drawnow;
    pause(0.5);
    shot2 = fullfile(here, 'out_qc_v2_accept_montage.png');
    save_shot(fig, shot2);

    p.setViewMode('single');
    p.setModality('Norm');
    p.setNormKind('Fun');
    p.setOverlayVisible(true);
    drawnow;
    pause(0.5);
    shot3 = fullfile(here, 'out_qc_v2_accept_norm_fd.png');
    save_shot(fig, shot3);

    for sPath = {shot1, shot2, shot3}
        if exist(sPath{1}, 'file') == 2
            d = dir(sPath{1});
            check(d.bytes > 20000, sprintf('截图非空：%s（%d 字节）', ...
                sPath{1}, d.bytes));
        else
            check(false, sprintf('缺少截图：%s', sPath{1}));
        end
    end

    % ==================================================================
    % 收尾
    % ==================================================================
    try, close(fig); catch, end
    try, delete(tmpJson); catch, end
    fprintf('\n=== 验收结果：%d 项失败 / 共 %d 项断言 ===\n', failures, nAssertions);
    if failures > 0
        error('test_qc_ui_v2_accept:Failed', '有 %d 项验收断言未通过', failures);
    end
    fprintf('全部验收通过。\n');

    % ---------------------- 嵌套辅助函数 ----------------------
    function check(cond, msg)
        nAssertions = nAssertions + 1;
        if cond
            fprintf('  [通过] %s\n', msg);
        else
            failures = failures + 1;
            fprintf('  [失败] %s\n', msg);
        end
    end

    function t = collect_text(f)
        t = '';
        labs = findall(f, 'Type', 'uilabel');
        for ii = 1:numel(labs)
            t = [t ' ' char(get(labs(ii), 'Text'))]; %#ok<AGROW>
        end
        % 面板标题（uipanel Title）
        pnls = findall(f, 'Type', 'uipanel');
        for ii = 1:numel(pnls)
            t = [t ' ' char(get(pnls(ii), 'Title'))]; %#ok<AGROW>
        end
        % axes 标题（三正交视图标题画在 axes.Title）
        axs = findall(f, 'Type', 'axes');
        for ii = 1:numel(axs)
            try
                ttl = get(axs(ii), 'Title');
                if ~isempty(ttl) && isprop(ttl, 'String')
                    t = [t ' ' char(string(ttl.String))]; %#ok<AGROW>
                end
            catch
            end
        end
        % axes 内 text 对象
        txts = findall(f, 'Type', 'text');
        for ii = 1:numel(txts)
            try
                t = [t ' ' char(string(get(txts(ii), 'String')))]; %#ok<AGROW>
            catch
            end
        end
    end

    function v = field_local(st, names)
        % 按候选字段路径取值（如 {'Manual','TranslationMm'}），找不到返回 []
        v = [];
        try
            v = st.(names{1});
            for k = 2:numel(names)
                v = v.(names{k});
            end
        catch
            v = [];
        end
    end

    function tf = contains_any(txt, pats)
        tf = false;
        for ii = 1:numel(pats)
            if contains(string(txt), pats{ii})
                tf = true;
                return;
            end
        end
    end

    function c = get_image_cdata(f)
        ims = findall(f, 'Type', 'image');
        c = {};
        for ii = 1:numel(ims)
            c{end+1} = get(ims(ii), 'CData'); %#ok<AGROW>
        end
    end

    function save_shot(f, path)
        try
            exportapp(f, path);
            if exist(path, 'file') == 2
                d = dir(path);
                fprintf('  [截图] %s（%d 字节）\n', path, d.bytes);
            else
                fprintf('  [警告] 未生成截图：%s\n', path);
            end
        catch ME
            fprintf('  [警告] exportapp 截图失败：%s\n', ME.message);
        end
    end
end
