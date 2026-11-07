function test_qc_panel()
% test_qc_panel  人工 QC 面板 mrw.QcPanel 自动化测试（v1 语义 + v2 新功能，-batch 可跑）
%
% 运行方式（项目根目录）：
%   & 'D:\Program Files\Matlab\MatlabR2026a\bin\matlab.exe' -batch ...
%       "cd('...\MRI_Workbench'); addpath(pwd); addpath('tests'); test_qc_panel"
%
% 覆盖内容：
%   v1（不回退）：
%     1. 构造性能与默认状态；每个交互控件都有 Tooltip
%     2. axes 真正可缩放（zoomInteraction+panInteraction、setZoomFactor/getZoomFactor）
%     3. 切片滑条/方向下拉/越界 clamp；窗宽百分位
%     4. MeanFD 显示与超阈值提醒
%     5. 评分保存 → DPARSF 兼容 TSV → loadScores 读回 → 自动下一人
%     6. 模态切换 T1/Fun/Norm、标准化子图、模板轮廓开关/透明度
%     7. “仅显示未评分”筛选、阈值下拉、exportPassList
%     8. 无数据/目录不存在中文提示不崩溃
%     9. 切换受试者/切片性能
%   v2（契约 §5/§7）：
%    10. 三正交视图：3 个 axes + 第四格信息面板；活动方向；十字线点击改变体素
%    11. 坐标读数 / getViewInfo；原点校准 / AC-PC 配平 / 清除 / 手动微调 / 翻转 / 重置
%    12. 多切片网格：montage axes、点击 tile 选层
%    13. FD 曲线：轴对象、折线/阈值线/坏帧点、类型切换、阈值、低分联动警示
%    14. 筛选 / 排序（评分、MeanFD 列 + 红色超阈值）
%    15. 状态 JSON：exportState + 自动 <workDir>/QC/.qcviewer_state.json（schema v2 字段）
%    16. QcAlignDialog：控件 Tooltip、拾取 AC/PC/应用/清除、面板销毁后不报错
%    17. 三正交重绘性能（< 0.4 s/次）
%    18. 截图：单视图 / 缩放 / 标准化 / 三正交 / AC-PC / 多切片 / FD 低分联动
%
% 说明：需要 tests/qc_fixture.m 生成合成 DPARSF 数据；若 fixture 尚无逐帧 FD 文件，
%       本测试会在该临时 fixture 目录补写合成 FD 文件（不改 qc_fixture.m）。

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root);
    addpath(here);

    fprintf('=== QcPanel 人工 QC 面板测试（v1 + v2） ===\n');
    fprintf('MATLAB %s\n', version);

    failures = 0;
    nAssertions = 0;
    changedCount = 0;

    % ------------------------------------------------------------------
    % 1. 数据 + 构造
    % ------------------------------------------------------------------
    base = qc_fixture();
    fprintf('测试数据：%s\n', base);
    ensureFdFixture(base);

    fig = mrw.UiKit.newFigure('QcPanel 测试', [1360 900]);
    fig.Position = [30 20 1360 900];
    gl = uigridlayout(fig, [1 1]);
    gl.Padding = [0 0 0 0];
    gl.BackgroundColor = mrw.UiKit.colors().bg;
    container = uipanel(gl, 'BorderType', 'none', ...
        'BackgroundColor', mrw.UiKit.colors().bg);

    t0 = tic;
    p = mrw.QcPanel(container, struct('WorkingDir', base, 'Modality', 'T1', ...
        'Footer', true));
    buildT = toc(t0);
    addlistener(p, 'Changed', @(s, e) onChanged());

    fprintf('构造耗时：外部 %.2f s / 面板内部 %.2f s\n', buildT, p.BuildSeconds);
    fprintf('交互控件数：%d，版本：%s\n', p.ControlCount, p.Version);
    check(p.BuildSeconds < 3.0, sprintf('构造性能 < 3 s（实际 %.2f s）', p.BuildSeconds));
    check(p.ControlCount >= 35, sprintf('交互控件数 >= 35（实际 %d）', p.ControlCount));
    check(~isempty(p.Axes) && isvalid(p.Axes), '图像 axes 已创建（可被测试读取）');
    check(~isempty(p.getSubjectIDs()) && numel(p.getSubjectIDs()) == 3, ...
        sprintf('发现 3 名受试者：%s', strjoin(p.getSubjectIDs(), ', ')));
    check(strcmp(p.Version, '2.0.0'), sprintf('面板版本 v2（%s）', p.Version));

    % ------------------------------------------------------------------
    % 2. 默认状态
    % ------------------------------------------------------------------
    st = p.getState();
    check(strcmp(st.WorkingDir, base), '工作目录与 fixture 一致');
    check(strcmp(st.Modality, 'T1'), '默认模态 = T1 原始像');
    check(strcmp(st.SubjectID, 'Sub01'), sprintf('默认选中第一位受试者（%s）', st.SubjectID));
    check(isnan(st.SavedScore), '默认受试者尚无已保存评分（SavedScore=NaN）');
    check(st.Score == 3, '右侧评分单选默认 3 分');
    check(strcmp(st.Orientation, 'axial'), '默认方向 = 横断位 axial');
    check(isequal(st.Window, [2 98]), '默认窗宽百分位 = [2 98]');
    check(abs(st.Zoom - 1) < 1e-9, sprintf('默认缩放 = 1.00×（实际 %.3f）', st.Zoom));
    check(st.HasImage, '默认已成功加载图像');
    check(st.SliceIndex >= 1 && st.SliceIndex <= st.SliceCount, ...
        sprintf('默认切片合法（%d/%d）', st.SliceIndex, st.SliceCount));
    check(st.Progress.T1.Total == 3, '进度包含 3 名 T1 受试者');
    check(strcmp(st.ViewMode, 'single'), '默认视图模式 = 单视图');
    check(strcmp(st.Filter, 'all') && strcmp(st.Sort, 'id'), '默认筛选/排序 = 全部/ID');

    % 每个交互控件都必须有 Tooltip
    [nCtrl, missingTips] = countTips(fig);
    check(isempty(missingTips), sprintf('全部 %d 个交互控件均有中文 Tooltip', nCtrl));
    if ~isempty(missingTips)
        fprintf('      缺 Tooltip：%s\n', strjoin(missingTips, ', '));
    end
    check(nCtrl == p.ControlCount, sprintf('控件计数一致（%d = %d）', nCtrl, p.ControlCount));

    % ------------------------------------------------------------------
    % 3. 真正可缩放
    % ------------------------------------------------------------------
    nInt = 0;
    intCls = {};
    try
        ints = p.Axes.Interactions;
        nInt = numel(ints);
        for i = 1:nInt
            try
                intCls{end+1} = class(ints(i)); %#ok<AGROW>
            catch
            end
        end
    catch
    end
    intJoined = lower(strjoin(intCls, ' '));
    check(nInt == 0 && ~isempty(fig.WindowScrollWheelFcn) && ...
        ~isempty(fig.WindowButtonMotionFcn) && ~isempty(fig.WindowButtonUpFcn), ...
        '已安装自定义切层/缩放/平移回调并关闭抢占事件的默认交互');

    ax = p.Axes;
    w0 = diff(ax.XLim);
    h0 = diff(ax.YLim);
    cx0 = mean(ax.XLim);
    cy0 = mean(ax.YLim);
    fAct = p.setZoomFactor(2.5);
    fGet = p.getZoomFactor();
    check(abs(fAct - 2.5) < 1e-6, sprintf('setZoomFactor(2.5) 返回实际 %.6f', fAct));
    check(abs(fGet - 2.5) < 1e-6, sprintf('getZoomFactor()≈2.5（实际 %.6f）', fGet));
    check(diff(ax.XLim) < w0, '缩放后 axes XLim 宽度变窄');
    check(abs(diff(ax.XLim) - w0 / 2.5) < 1e-6, ...
        sprintf('XLim 宽度 = 默认/2.5（%.4f → %.4f）', w0, diff(ax.XLim)));
    check(abs(diff(ax.YLim) - h0 / 2.5) < 1e-6, ...
        sprintf('YLim 宽度 = 默认/2.5（%.4f → %.4f）', h0, diff(ax.YLim)));
    check(abs(mean(ax.XLim) - cx0) < 1e-9 && abs(mean(ax.YLim) - cy0) < 1e-9, ...
        '以图像中心为锚点缩放（中心不变）');
    ax.XLim = cx0 + [-w0 / 4, w0 / 4];
    ax.YLim = cy0 + [-h0 / 4, h0 / 4];
    check(abs(p.getZoomFactor() - 2) < 1e-6, ...
        sprintf('滚轮式范围变化后 getZoomFactor≈2（实际 %.6f）', p.getZoomFactor()));
    p.setZoomFactor(1);
    check(abs(diff(ax.XLim) - w0) < 1e-6 && abs(diff(ax.YLim) - h0) < 1e-6, ...
        'setZoomFactor(1) 恢复适应窗口范围');
    check(abs(p.getZoomFactor() - 1) < 1e-6, '适应窗口时 getZoomFactor = 1');
    fMin = p.setZoomFactor(0.01);
    check(abs(fMin - 0.5) < 1e-9, sprintf('setZoomFactor 下限 0.5（实际 %.3f）', fMin));
    p.setZoomFactor(1);

    check(pressButton(fig, 'qcZoomIn'), '[＋] 按钮存在并可回调');
    check(p.getZoomFactor() > 1.2, sprintf('[＋] 按钮后放大（%.2f×）', p.getZoomFactor()));
    check(pressButton(fig, 'qcZoomFit'), '[适应] 按钮存在并可回调');
    check(abs(p.getZoomFactor() - 1) < 1e-6, '[适应] 按钮恢复 1.00×');

    % ------------------------------------------------------------------
    % 4. 切片 / 方向（v1 语义）
    % ------------------------------------------------------------------
    st = p.getState();
    mid = round(st.SliceCount / 2);
    p.setSliceIndex(5);
    check(p.getState().SliceIndex == 5, 'setSliceIndex(5) 生效');
    p.setSliceIndex(99999);
    check(p.getState().SliceIndex == p.getState().SliceCount, ...
        sprintf('越界切片 clamp 到末尾（%d）', p.getState().SliceIndex));

    p.setOrientation('coronal');
    stC = p.getState();
    check(strcmp(stC.Orientation, 'coronal'), 'setOrientation(''coronal'') 生效');
    check(stC.SliceCount == 64, sprintf('冠状位切片数 = 64（实际 %d）', stC.SliceCount));
    check(~isempty(strfind(stC.SliceLabel, 'Coronal')), ...
        sprintf('切片标签为冠状位：%s', stC.SliceLabel));
    p.setOrientation('sagittal');
    check(strcmp(p.getState().Orientation, 'sagittal'), 'setOrientation(''sagittal'') 生效');
    check(p.getState().SliceCount == 64, '矢状位切片数 = 64');
    p.setOrientation('axial');
    check(strcmp(p.getState().Orientation, 'axial') && p.getState().SliceCount == 30, ...
        '切回横断位（30 层）');
    p.setSliceIndex(mid);
    check(p.getState().SliceIndex == mid, '方向切换后切片索引仍有效');

    % ------------------------------------------------------------------
    % 5. 窗宽窗位
    % ------------------------------------------------------------------
    clim0 = p.Axes.CLim;
    p.setWindow(5, 95);
    stW = p.getState();
    climW = p.Axes.CLim;
    check(isequal(stW.Window, [5 95]), 'setWindow(5,95) 反映在 getState().Window');
    check(climW(1) >= clim0(1) - 1e-9 && climW(2) <= clim0(2) + 1e-9 && ~isequal(climW, clim0), ...
        sprintf('5/95 百分位显示范围比 2/98 更窄（提高对比）[%.2f %.2f] ⊂ [%.2f %.2f]', ...
        climW(1), climW(2), clim0(1), clim0(2)));
    check(abs(getTagValue(fig, 'qcWinLow') - 5) < 1e-9 && ...
        abs(getTagValue(fig, 'qcWinHigh') - 95) < 1e-9, '窗宽数值框同步为 5/95');
    check(pressButton(fig, 'qcAutoWindow'), '[自动窗宽] 按钮存在并可回调');
    check(isequal(p.getState().Window, [0 100]), '自动窗宽 = 0/100 百分位（全动态范围）');
    p.setWindow(2, 98);
    check(isequal(p.getState().Window, [2 98]), '恢复默认窗宽 2/98');

    % ------------------------------------------------------------------
    % 6. MeanFD 显示与超阈值提醒
    % ------------------------------------------------------------------
    p.setSubject(1);
    fdText = getTagText(fig, 'qcMeanFD');
    check(~isempty(strfind(fdText, '0.0800')), ...
        sprintf('Sub01 MeanFD 显示 0.0800（实际：%s）', strrep(fdText, newline, ' ')));
    p.setSubject(2);
    fdText = getTagText(fig, 'qcMeanFD');
    check(~isempty(strfind(fdText, '0.2500')) && ~isempty(strfind(fdText, '超过')), ...
        sprintf('Sub02 MeanFD 0.2500 超阈值提醒（实际：%s）', strrep(fdText, newline, ' ')));
    p.setSubject(1);

    % ------------------------------------------------------------------
    % 7. 评分保存 → TSV → loadScores → 自动下一人
    % ------------------------------------------------------------------
    p.setSubject(1);
    check(strcmp(p.getState().SubjectID, 'Sub01'), '定位到 Sub01');
    c0 = changedCount;
    p.setScore(4);
    p.setComment('头动伪影明显，建议复核');
    ok = p.saveCurrentScore();
    check(isequal(ok, true), 'saveCurrentScore 返回 true');
    check(changedCount > c0, '保存评分触发 Changed 事件');
    scores = mrw.QcModel.loadScores(base, 'T1');
    k = find(strcmp({scores.ID}, 'Sub01'), 1);
    check(~isempty(k), 'QcModel.loadScores 能读到 Sub01');
    check(~isempty(k) && scores(k).Score == 4, 'loadScores 读回评分 4');
    check(~isempty(k) && strcmp(scores(k).Comment, '头动伪影明显，建议复核'), ...
        sprintf('loadScores 读回中文评语：%s', ifelseStr(isempty(k), '', scores(k).Comment)));
    tsv = fullfile(base, 'QC', 'RawT1ImgQC.tsv');
    check(exist(tsv, 'file') == 2, sprintf('写出 DPARSF 兼容 TSV：%s', tsv));
    if exist(tsv, 'file') == 2
        lines = regexp(fileread(tsv), '\r\n|\n', 'split');
        expectHeader = sprintf('Subject ID\tQC Score\tQC Comment');
        check(~isempty(lines) && strcmp(lines{1}, expectHeader), ...
            sprintf('TSV 首行与 DPARSF 一致：%s', ifelseStr(isempty(lines), '', lines{1})));
        check(numel(lines) >= 2 && ~isempty(strfind(lines{2}, 'Sub01')), ...
            'TSV 含 Sub01 数据行');
    end
    stA = p.getState();
    check(strcmp(stA.SubjectID, 'Sub02'), ...
        sprintf('保存后自动下一人（%s）', stA.SubjectID));
    check(stA.Progress.T1.Scored == 1 && stA.Progress.T1.Total == 3, ...
        sprintf('评分进度 T1 = 1/3（实际 %d/%d）', ...
        stA.Progress.T1.Scored, stA.Progress.T1.Total));
    badgeTxt = getTagText(fig, 'qcProgressBadge');
    check(~isempty(strfind(badgeTxt, '1/3')), ...
        sprintf('顶部进度徽标显示 1/3（实际：%s）', badgeTxt));
    p.setSubject(1);
    stB = p.getState();
    check(stB.SavedScore == 4 && stB.Score == 4, ...
        sprintf('切回 Sub01 还原已保存评分（SavedScore=%g）', stB.SavedScore));
    check(strcmp(stB.Comment, '头动伪影明显，建议复核'), '切回后评语框还原已保存评语');

    % ------------------------------------------------------------------
    % 8. 模态切换 / 标准化轮廓
    % ------------------------------------------------------------------
    c1 = changedCount;
    p.setModality('Fun');
    stF = p.getState();
    check(strcmp(stF.Modality, 'Fun'), '切换到功能平均像模态');
    check(strcmp(stF.SubjectID, 'Sub01'), '切换模态后保持同一受试者（Sub01）');
    check(stF.HasImage, '功能平均像成功显示');
    check(changedCount > c1, '模态切换触发 Changed 事件');

    p.setModality('Norm');
    stN = p.getState();
    check(strcmp(stN.Modality, 'Norm'), '切换到标准化检查模态');
    check(stN.HasImage, '标准化图像成功显示');
    check(stN.OverlayVisible, '标准化模态默认叠加模板轮廓');
    check(any(strcmp({'Fun', 'T1', 'GM'}, stN.NormKind)), ...
        sprintf('标准化子图类型有效（%s）', stN.NormKind));
    nImgOverlay = countImages(p.Axes);
    check(nImgOverlay >= 1, sprintf('标准化图像已绘制（image 对象 %d 个）', nImgOverlay));
    fprintf('      [信息] 标准化+轮廓 image 对象数 = %d（2 = 主图+轮廓）\n', nImgOverlay);
    kinds = {'T1', 'GM', 'Fun'};
    switchOk = true;
    for kk = 1:numel(kinds)
        try
            p.setNormKind(kinds{kk});
            switchOk = switchOk && strcmp(p.getState().NormKind, kinds{kk});
        catch ME
            switchOk = false;
            fprintf('      子图切换异常（%s）：%s\n', kinds{kk}, ME.message);
        end
    end
    check(switchOk, '标准化子图可切换 wFun / wT1 / wGM 且状态同步');
    p.setOverlayVisible(false);
    check(~p.getState().OverlayVisible && countImages(p.Axes) <= 1, ...
        '关闭模板轮廓后仅剩主图');
    p.setOverlayVisible(true);
    check(p.getState().OverlayVisible, '重新打开模板轮廓');
    p.setOverlayAlpha(0.65);
    check(abs(p.getState().OverlayAlpha - 0.65) < 1e-9, '轮廓透明度 0.65 生效');
    check(abs(getTagValue(fig, 'qcOverlayAlpha') - 0.65) < 1e-9, '透明度滑条同步 0.65');
    p.setModality('T1');
    check(strcmp(p.getState().Modality, 'T1'), '切回 T1 模态');

    % ------------------------------------------------------------------
    % 9. 筛选 / 阈值 / 导出通过名单（v1 语义）
    % ------------------------------------------------------------------
    p.setFilterOnlyUnscored(true);
    stFil = p.getState();
    check(stFil.OnlyUnscored, '“仅显示未评分”复选框状态同步');
    check(strcmp(stFil.Filter, 'unscored'), '筛选下拉联动为“仅未评分”');
    check(stFil.VisibleSubjectCount == 2, ...
        sprintf('筛选后剩 2 名未评分（实际 %d）', stFil.VisibleSubjectCount));
    tbl = findobj(fig, 'Tag', 'qcSubjectTable');
    check(~isempty(tbl) && size(tbl(1).Data, 1) == 2, '受试者表格只显示 2 行');
    p.setFilterOnlyUnscored(false);
    check(p.getState().VisibleSubjectCount == 3, '取消筛选后恢复 3 名受试者');
    check(strcmp(p.getState().Filter, 'all'), '取消勾选后筛选下拉回到“全部”');

    p.setThreshold(5);
    check(p.getState().MinScore == 5, '阈值下拉 5 生效');
    check(abs(getTagValue(fig, 'qcThreshold') - 5) < 1e-9, '阈值下拉控件同步 5');
    p.setThreshold(3);
    check(p.getState().MinScore == 3, '阈值恢复默认 3');

    thr0 = mrw.QcModel.loadThresholds(base);
    thr0.UseT1 = true;
    thr0.UseFun = false;
    thr0.UseNorm = false;
    thr0.UseMeanFD = false;
    thr0.T1Min = 3;
    [thrOk, thrMsg] = mrw.QcModel.saveThresholds(base, thr0);
    check(isequal(thrOk, true), sprintf('测试前置：写入门限文件（%s）', thrMsg));
    p.refresh();
    outList = fullfile(tempdir, 'mrw_qc_panel_passlist_test.txt');
    if exist(outList, 'file') == 2
        delete(outList);
    end
    list = p.exportPassList(outList);
    check(iscell(list), 'exportPassList 返回 cellstr');
    check(exist(outList, 'file') == 2, sprintf('通过名单文件已写出：%s', outList));
    check(any(strcmp(list, 'Sub01')), ...
        sprintf('名单包含 T1 评分 4 分的 Sub01（%d 人：%s）', numel(list), strjoin(list, ', ')));
    check(~any(strcmp(list, 'Sub02')), '未评分的 Sub02 不在名单中');

    % ------------------------------------------------------------------
    % 10. 无数据 / 目录不存在：中文提示不崩溃
    % ------------------------------------------------------------------
    fig2 = mrw.UiKit.newFigure('QcPanel 空数据测试', [1000 640]);
    gl2 = uigridlayout(fig2, [1 1]);
    gl2.Padding = [0 0 0 0];
    c2 = uipanel(gl2, 'BorderType', 'none');
    badDir = fullfile(tempdir, 'mrw_qc_panel_no_such_dir_xyz');
    p2 = [];
    try
        p2 = mrw.QcPanel(c2, struct('WorkingDir', badDir, 'Footer', true));
        okNoData = true;
    catch ME
        okNoData = false;
        fprintf('      空数据构造异常：%s\n', ME.message);
    end
    check(okNoData, '工作目录不存在时构造不崩溃');
    if okNoData
        st2 = p2.getState();
        check(~st2.HasImage, '无数据时不显示图像');
        check(~isempty(st2.Message) && any(double(st2.Message) > 127), ...
            sprintf('无数据时显示中文提示：%s', st2.Message));
        check(isnan(st2.SavedScore) && strcmp(st2.SubjectID, ''), '无数据时无受试者/评分');
        check(~st2.FD.Available && isempty(st2.FD.Values), '无数据时 FD 状态为空');
    end
    fig3 = mrw.UiKit.newFigure('QcPanel 未选目录测试', [1000 640]);
    gl3 = uigridlayout(fig3, [1 1]);
    gl3.Padding = [0 0 0 0];
    c3 = uipanel(gl3, 'BorderType', 'none');
    try
        p3 = mrw.QcPanel(c3, struct('WorkingDir', '', 'Footer', false));
        check(~p3.getState().HasImage, '未选择工作目录时构造不崩溃且显示占位提示');
        check(isempty(findobj(fig3, 'Tag', 'qcFooterProgress')), ...
            'opts.Footer=false 时不显示底部状态栏');
        check(isempty(p3.getState().StateFile), '无工作目录时不写状态文件');
    catch ME
        check(false, ['空工作目录构造异常：' ME.message]);
    end

    % ------------------------------------------------------------------
    % 11. 性能：切换受试者 / 切片（v1）
    % ------------------------------------------------------------------
    p.setModality('T1');
    p.setSubject(1);
    tSw = tic;
    p.setSubject(2);
    tSubj = toc(tSw);
    tSw = tic;
    p.setSubject(3);
    tSubj3 = toc(tSw);
    p.setSubject(1);
    tSw = tic;
    for kk = 1:5
        p.setSliceIndex(mod(mid + kk, p.getState().SliceCount - 1) + 1);
    end
    tSlice = toc(tSw) / 5;
    fprintf('切换受试者耗时：%.3f s / %.3f s（<1.5 s）\n', tSubj, tSubj3);
    fprintf('切换切片平均耗时：%.3f s（<1.5 s）\n', tSlice);
    check(tSubj < 1.5 && tSubj3 < 1.5, '切换受试者 < 1.5 s');
    check(tSlice < 1.5, '切换切片 < 1.5 s');

    % ==================================================================
    %  v2 新功能
    % ==================================================================

    % ------------------------------------------------------------------
    % 12. 三正交视图 + 十字线
    % ------------------------------------------------------------------
    p.setModality('T1');
    p.setSubject(1);
    p.setWindow(2, 98);
    check(~isempty(findobj(fig, 'Tag', 'qcViewMode')), '工具条视图模式下拉存在（Tag=qcViewMode）');
    check(~isempty(findobj(fig, 'Tag', 'qcCopyState')), ...
        '工具条“复制状态给 Agent”按钮存在（Tag=qcCopyState）');
    p.setViewMode('triple');
    drawnow;
    stT = p.getState();
    check(strcmp(stT.ViewMode, 'triple'), 'setViewMode(''triple'') 生效');
    check(any(strcmp({'axial', 'coronal', 'sagittal'}, stT.ActiveOrientation)), ...
        sprintf('三正交活动方向有效（%s）', stT.ActiveOrientation));
    axA = stT.AxesHandles.Axial;
    axC = stT.AxesHandles.Coronal;
    axS = stT.AxesHandles.Sagittal;
    check(~isempty(axA) && isvalid(axA) && ~isempty(axC) && isvalid(axC) && ...
        ~isempty(axS) && isvalid(axS), '三正交 3 个 axes 已创建且有效');
    check(countImages(axA) >= 1 && countImages(axC) >= 1 && countImages(axS) >= 1, ...
        '三正交 3 个方向均已绘制切图');
    infoPanel = findobj(fig, 'Tag', 'qcTripleInfo');
    check(~isempty(infoPanel), '第四格“位置与校准信息”面板存在');
    infoTxt = getTagText(fig, 'qcTripleInfoText');
    check(~isempty(strfind(infoTxt, '体素')) && ~isempty(strfind(infoTxt, '显示')), ...
        sprintf('第四格信息文本含体素/显示坐标（%s）', strrep(infoTxt, newline, ' | ')));
    check(~isempty(strfind(getTagText(fig, 'qcCoordLabel'), '体素')), ...
        '坐标读数行显示体素坐标');

    vi0 = p.getViewInfo();
    check(isstruct(vi0) && isfield(vi0, 'HasVolume') && isfield(vi0, 'CrosshairVoxel'), ...
        'getViewInfo 返回契约字段');
    c0v = p.getCrosshairVoxel();
    check(isnumeric(c0v) && numel(c0v) == 3 && all(isfinite(c0v)), ...
        sprintf('十字线体素有效：%s', fmtVecQc(c0v, '%.1f')));

    % 设置十字线（联动三正交）
    p.setCrosshairVoxel([20 44 9]);
    cSet = p.getCrosshairVoxel();
    check(abs(cSet(1) - 20) < 1.5 && abs(cSet(2) - 44) < 1.5 && abs(cSet(3) - 9) < 1.5, ...
        sprintf('setCrosshairVoxel([20 44 9]) 生效（实际 %s）', fmtVecQc(cSet, '%.1f')));
    stT = p.getState();
    check(isequal(size(stT.CrosshairVoxel), [1 3]), 'getState().CrosshairVoxel 为 1x3');
    check(~isempty(stT.CrosshairWorld) || ~isempty(stT.Display.ACPC), ...
        'getState() 含世界坐标/Display 信息');

    % 点击三正交视图改变十字线（调用与鼠标点击同一内部处理逻辑）
    before = p.getCrosshairVoxel();
    axC = p.getState().AxesHandles.Coronal;
    xl = axC.XLim;
    yl = axC.YLim;
    clicked = p.clickViewAt('coronal', mean(xl), mean(yl) + 0.2 * diff(yl));
    after = p.getCrosshairVoxel();
    check(clicked, '三正交点击处理返回成功');
    check(~isequal(round(before * 10), round(after * 10)), ...
        sprintf('点击冠视图后十字线体素变化（%s → %s）', ...
        fmtVecQc(before, '%.1f'), fmtVecQc(after, '%.1f')));
    check(strcmp(p.getState().ActiveOrientation, 'coronal'), ...
        '点击后活动方向更新为冠视图方向');

    % 活动方向切换 + 滑条/键盘语义
    p.setActiveOrientation('sagittal');
    check(strcmp(p.getState().ActiveOrientation, 'sagittal'), 'setActiveOrientation(''sagittal'') 生效');
    check(p.getState().SliceCount >= 1, '活动方向切片总数有效');
    nSl = p.getState().SliceCount;
    p.setSliceIndex(min(5, nSl));
    drawnow;
    check(p.getState().SliceIndex == min(5, nSl), ...
        sprintf('三正交下滑条 setSliceIndex 生效（%d/%d）', p.getState().SliceIndex, nSl));
    p.setActiveOrientation('axial');

    % 十字线开关
    p.setCrosshairVisible(false);
    check(~p.getState().CrosshairVisible, '关闭十字线状态同步');
    p.setCrosshairVisible(true);
    check(p.getState().CrosshairVisible, '重新打开十字线');

    % 色阶 / 插值
    p.setColormap('hot');
    check(strcmp(p.getState().Colormap, 'hot'), 'setColormap(''hot'') 生效');
    p.setInterp('nearest');
    check(strcmp(p.getState().Interp, 'nearest'), 'setInterp(''nearest'') 生效');
    p.setColormap('gray');
    p.setInterp('linear');

    % 三正交重绘性能
    tTri = tic;
    nTri = 0;
    for kk = 1:3
        p.setCrosshairVoxel([10 + 5 * kk, 20 + 4 * kk, 8 + 2 * kk]);
        nTri = nTri + 1;
    end
    tTriAvg = toc(tTri) / max(1, nTri);
    fprintf('三正交重绘平均耗时：%.3f s（目标 < 0.4 s）\n', tTriAvg);
    check(tTriAvg < 0.4, sprintf('三正交重绘 < 0.4 s（实际 %.3f s）', tTriAvg));

    % 截图：三正交 + 十字线
    p.setCrosshairVoxel([20 44 9]);
    p.setActiveOrientation('axial');
    drawnow;
    pause(0.4);
    shotTriple = fullfile(here, 'out_qc_panel_triple.png');
    saveShot(fig, shotTriple);

    % ------------------------------------------------------------------
    % 13. 原点校准 / AC-PC 配平 / 手动微调 / 翻转 / 重置
    % ------------------------------------------------------------------
    st0 = p.getState();
    check(strcmp(st0.Display.Mode, 'native'), '初始显示模式 = native');
    ac = [32 32 20];
    pc = [32 32 10];
    okAcpc = p.setACPC(ac, pc);
    drawnow;
    stAp = p.getState();
    if okAcpc
        check(strcmp(stAp.Display.Mode, 'acpc'), 'AC-PC 配平后显示模式 = acpc');
        dMm = stAp.Display.ACPC.distanceMm;
        check(isfinite(dMm) && abs(dMm - 10) < 1.5, ...
            sprintf('AC-PC 距离 ≈ 10 mm（实际 %.2f）', dMm));
        check(isfinite(stAp.Display.ACPC.angleDeg), 'AC-PC 角度为有限值');
        p.setViewMode('triple');
        drawnow;
        pause(0.4);
        shotAcpc = fullfile(here, 'out_qc_panel_acpc.png');
        saveShot(fig, shotAcpc);
    else
        check(false, sprintf('AC-PC 配平失败（需要 mrw.QcView 显示引擎）：%s', stAp.Message));
        shotAcpc = '';
    end
    p.clearACPC();
    check(strcmp(p.getState().Display.Mode, 'native'), 'clearACPC 恢复 native 显示');

    okOrigin = p.setOriginAtCrosshair();
    if okOrigin
        check(strcmp(p.getState().Display.Mode, 'origin'), '以十字线设原点后显示模式 = origin');
        p.clearACPC();
        check(strcmp(p.getState().Display.Mode, 'native'), '清除后回到 native');
    else
        check(false, 'setOriginAtCrosshair 失败（需要 mrw.QcView 显示引擎）');
    end

    okMan = p.setManualOrientation([2 -1 3], [5 0 -4]);
    stMan = p.getState();
    [manT, manR] = manualFromState(stMan);
    check(okMan && abs(manT(1) - 2) < 1e-6 && abs(manT(3) - 3) < 1e-6, ...
        sprintf('手动平移生效：%s mm', fmtVecQc(manT, '%.2f')));
    check(abs(manR(1) - 5) < 1e-6 && abs(manR(3) + 4) < 1e-6, ...
        sprintf('手动旋转生效：%s 度', fmtVecQc(manR, '%.2f')));
    okFlip = p.setFlips(true, false, true);
    fl = p.getFlips();
    check(okFlip && fl(1) && ~fl(2) && fl(3), sprintf('显示翻转生效（L-R=%d A-P=%d I-S=%d）', fl(1), fl(2), fl(3)));
    p.resetOrientation();
    stR = p.getState();
    [manT2, manR2] = manualFromState(stR);
    check(all(abs(manT2) < 1e-6) && all(abs(manR2) < 1e-6), 'resetOrientation 清零平移/旋转');
    check(strcmp(stR.Display.Mode, 'native'), 'resetOrientation 回到 native 显示');
    fl2 = p.getFlips();
    check(~any(fl2), 'resetOrientation 清除翻转');
    axTxt = getTagText(fig, 'qcAlignSummary');
    check(~isempty(strfind(axTxt, '显示模式')), ...
        sprintf('右列方位校准摘要文本：%s', strrep(axTxt, newline, ' | ')));

    % ------------------------------------------------------------------
    % 14. 多切片网格（montage）
    % ------------------------------------------------------------------
    p.setViewMode('montage');
    drawnow;
    stM = p.getState();
    check(strcmp(stM.ViewMode, 'montage'), 'setViewMode(''montage'') 生效');
    axM = stM.AxesHandles.Montage;
    check(~isempty(axM) && isvalid(axM), '多切片网格 axes 已创建');
    check(countImages(axM) >= 1, sprintf('多切片网格已绘制（image 对象 %d 个）', countImages(axM)));
    check(stM.SliceCount == 30, sprintf('多切片切片总数 = 30（实际 %d）', stM.SliceCount));
    oldSlice = stM.SliceIndex;
    xl = axM.XLim;
    yl = axM.YLim;
    okTile = p.clickViewAt('axial', xl(2) - max(2, 0.02 * diff(xl)), mean(yl));
    stM2 = p.getState();
    check(okTile && stM2.SliceIndex ~= oldSlice, ...
        sprintf('点击 montage tile 选层（%d → %d）', oldSlice, stM2.SliceIndex));
    drawnow;
    pause(0.3);
    shotMontage = fullfile(here, 'out_qc_panel_montage.png');
    saveShot(fig, shotMontage);
    p.setViewMode('single');
    check(strcmp(p.getState().ViewMode, 'single'), '切回单视图');
    check(p.getState().HasImage, '切回单视图后图像仍显示');

    % ------------------------------------------------------------------
    % 15. FD 曲线（类型 / 阈值 / 坏帧 / 低分联动）
    % ------------------------------------------------------------------
    p.setSubject(1);
    drawnow;
    stFd = p.getState();
    check(strcmp(stFd.FD.Type, 'FD_Jenkinson'), '默认 FD 类型 = FD_Jenkinson');
    check(stFd.FD.Threshold > 0, sprintf('FD 坏帧阈值有效（%.2f mm）', stFd.FD.Threshold));
    check(stFd.FD.Available || numel(stFd.FD.Values) >= 40, ...
        sprintf('已加载逐帧 FD（%d 个值）', numel(stFd.FD.Values)));
    check(numel(stFd.FD.Values) >= 40, ...
        sprintf('FD 值数量 >= 40（实际 %d）', numel(stFd.FD.Values)));
    vals = stFd.FD.Values;
    expBad = find(vals > stFd.FD.Threshold);
    check(isequal(stFd.FD.BadFrames, expBad), ...
        sprintf('坏帧 = FD>阈值的帧（%d 个）', numel(expBad)));
    % MeanFD 必须与窗口/通过名单一致：HeadMotion.tsv 第 21 列（fixture Sub01 = 0.0800）
    check(isfield(stFd.FD, 'MeanFD') && abs(stFd.FD.MeanFD - 0.08) < 1e-9, ...
        sprintf('getState().FD.MeanFD = HeadMotion.tsv 0.0800（%.4f）', stFd.FD.MeanFD));
    check(isfield(stFd.FD, 'SeriesMeanFD') && ...
        abs(stFd.FD.SeriesMeanFD - mean(vals)) < 1e-9, ...
        sprintf('getState().FD.SeriesMeanFD = 逐帧序列均值（%.4f）', stFd.FD.SeriesMeanFD));
    check(isfield(stFd.FD, 'MeanFDSource') && ...
        ~isempty(strfind(stFd.FD.MeanFDSource, 'HeadMotion.tsv')), ...
        sprintf('getState().FD.MeanFDSource 标明来源（%s）', stFd.FD.MeanFDSource));
    check(abs(stFd.FD.MaxFD - max(vals)) < 1e-9, ...
        sprintf('MaxFD 保持逐帧序列口径（%.4f）', stFd.FD.MaxFD));
    axFd = stFd.AxesHandles.Fd;
    check(~isempty(axFd) && isvalid(axFd), 'FD 曲线 uiaxes 存在');
    lineObjs = findobj(axFd, 'Type', 'line');
    check(numel(lineObjs) >= 3, ...
        sprintf('FD 曲线含折线/阈值线/坏帧点（%d 条 line 对象）', numel(lineObjs)));
    fdTitle = getTagText(fig, 'qcFdTitle');
    check(~isempty(strfind(fdTitle, 'Sub01')), sprintf('FD 标题含受试者 ID（%s）', fdTitle));
    statsTxt = getTagText(fig, 'qcFdStats');
    check(~isempty(strfind(statsTxt, 'MeanFD')) && ~isempty(strfind(statsTxt, '坏帧')), ...
        sprintf('FD 统计文本完整（%s）', strrep(statsTxt, newline, ' | ')));
    check(~isempty(strfind(statsTxt, '序列均值')), 'FD 统计文本区分 TSV MeanFD 与逐帧序列均值');
    check(~isempty(strfind(statsTxt, '最大平移')) && ~isempty(strfind(statsTxt, '最大旋转')), ...
        'FD 统计含最大平移/旋转');

    p.setFdThreshold(0.1);
    stFd2 = p.getState();
    check(abs(stFd2.FD.Threshold - 0.1) < 1e-9, 'setFdThreshold(0.1) 生效');
    check(numel(stFd2.FD.BadFrames) >= numel(expBad), '阈值降低后坏帧数不减少');
    p.setFdType('FD_Power');
    stFd3 = p.getState();
    check(strcmp(stFd3.FD.Type, 'FD_Power'), 'setFdType(''FD_Power'') 生效');
    check(abs(stFd3.FD.Threshold - 0.5) < 1e-9, ...
        sprintf('切换 FD_Power 后阈值自动为 0.5（实际 %.2f）', stFd3.FD.Threshold));
    p.setFdType('FD_VanDijk');
    stFd4 = p.getState();
    check(~stFd4.FD.Available || numel(stFd4.FD.Values) > 0, ...
        'FD_VanDijk 缺失文件时优雅处理（不崩溃）');
    if ~stFd4.FD.Available
        check(~isempty(stFd4.FD.Values) == false, 'FD_VanDijk 无文件时 Values 为空');
        statsTxt2 = getTagText(fig, 'qcFdStats');
        check(any(double(statsTxt2) > 127), 'FD 无文件时显示中文提示');
    end
    p.setFdType('FD_Jenkinson');
    check(abs(p.getState().FD.Threshold - 0.2) < 1e-9, '切回 FD_Jenkinson 阈值恢复 0.2');

    % 低分联动：Sub02 保存 2 分后切回，FD 标题应红字警示
    p.setSubject(2);
    p.setScore(2);
    okLow = p.saveCurrentScore();
    check(isequal(okLow, true), '保存 Sub02 的 2 分评分（低分联动前置）');
    p.setSubject(2);
    drawnow;
    lowTitle = getTagText(fig, 'qcFdTitle');
    check(~isempty(strfind(lowTitle, '低分')), ...
        sprintf('低分受试者 FD 标题含红色警示（%s）', lowTitle));
    hTitle = findobj(fig, 'Tag', 'qcFdTitle');
    redWarn = false;
    if ~isempty(hTitle)
        try
            fc = hTitle(1).FontColor;
            redWarn = isnumeric(fc) && fc(1) > 0.6 && fc(2) < 0.5;
        catch
        end
    end
    check(redWarn, '低分警示标题使用红色字体');
    drawnow;
    pause(0.4);
    shotFdLow = fullfile(here, 'out_qc_panel_fd_low.png');
    saveShot(fig, shotFdLow);

    % ------------------------------------------------------------------
    % 16. 筛选 / 排序（评分、MeanFD 列）
    % ------------------------------------------------------------------
    p.setFilter('all');
    p.setSort('id');
    tbl = findobj(fig, 'Tag', 'qcSubjectTable');
    check(~isempty(tbl), '受试者表存在');
    if ~isempty(tbl)
        cn = tbl(1).ColumnName;
        check(iscell(cn) && numel(cn) == 3 && strcmp(cn{1}, '受试者') && ...
            strcmp(cn{2}, '评分') && strcmp(cn{3}, 'MeanFD'), ...
            sprintf('表格列为 受试者|评分|MeanFD（实际 %s）', strjoin(cn, '|')));
        data = tbl(1).Data;
        check(size(data, 2) == 3 && ~isempty(strfind(data{1, 3}, '0.080')), ...
            sprintf('MeanFD 列显示数值（第一行 %s）', data{1, 3}));
    end

    p.setFilter('low');
    stLow = p.getState();
    check(stLow.VisibleSubjectCount == 1, ...
        sprintf('低分筛选（≤3）显示 1 人（Sub02=2；Sub01=4 排除；实际 %d）', ...
        stLow.VisibleSubjectCount));
    p.setFilter('scored');
    check(p.getState().VisibleSubjectCount == 2, '已评分筛选显示 2 人（Sub01、Sub02）');
    p.setFilter('unscored');
    check(p.getState().VisibleSubjectCount == 1, ...
        sprintf('未评分筛选显示 1 人（Sub03；实际 %d）', p.getState().VisibleSubjectCount));
    p.setFilter('meanfd');
    check(p.getState().VisibleSubjectCount == 2, ...
        sprintf('MeanFD 超阈值筛选显示 2 人（Sub02、Sub03；实际 %d）', ...
        p.getState().VisibleSubjectCount));
    p.setFilter('all');

    p.setSort('score_desc');
    tbl = findobj(fig, 'Tag', 'qcSubjectTable');
    data = tbl(1).Data;
    check(strcmp(data{1, 1}, 'Sub01'), ...
        sprintf('按评分降序第一行 = Sub01（实际 %s）', data{1, 1}));
    p.setSort('score_asc');
    data = tbl(1).Data;
    check(strcmp(data{1, 1}, 'Sub02'), ...
        sprintf('按评分升序第一行 = Sub02（2 分；实际 %s）', data{1, 1}));
    p.setSort('meanfd_desc');
    data = findobj(fig, 'Tag', 'qcSubjectTable');
    data = data(1).Data;
    check(strcmp(data{1, 1}, 'Sub03'), ...
        sprintf('按 MeanFD 降序第一行 = Sub03（0.450；实际 %s）', data{1, 1}));
    p.setSort('meanfd_asc');
    data = findobj(fig, 'Tag', 'qcSubjectTable');
    data = data(1).Data;
    check(strcmp(data{1, 1}, 'Sub01'), ...
        sprintf('按 MeanFD 升序第一行 = Sub01（0.080；实际 %s）', data{1, 1}));
    p.setSort('id');
    data = findobj(fig, 'Tag', 'qcSubjectTable');
    data = data(1).Data;
    check(strcmp(data{1, 1}, 'Sub01'), '按 ID 排序恢复 Sub01 在首位');

    % ------------------------------------------------------------------
    % 17. 状态 JSON（exportState + 自动写入）
    % ------------------------------------------------------------------
    p.setFilter('all');
    p.setSort('id');
    p.setSubject(1);
    p.setViewMode('triple');
    p.setCrosshairVoxel([21 43 11]);
    drawnow;
    stateFile = fullfile(base, 'QC', '.qcviewer_state.json');
    check(exist(stateFile, 'file') == 2, ...
        sprintf('自动状态文件存在：%s', stateFile));
    stAuto = p.getState();
    check(~isempty(stAuto.StateFile) && exist(stAuto.StateFile, 'file') == 2, ...
        sprintf('getState().StateFile 指向实际文件（%s）', stAuto.StateFile));
    outState = fullfile(tempdir, 'mrw_qc_panel_state_export.json');
    if exist(outState, 'file') == 2
        delete(outState);
    end
    p.exportState(outState);
    check(exist(outState, 'file') == 2, sprintf('exportState 写出 JSON：%s', outState));
    j = jsondecode(fileread(stateFile));
    check(strcmp(j.schema, 'mrw.qcviewer.state.v2'), ...
        sprintf('状态 schema = mrw.qcviewer.state.v2（%s）', j.schema));
    check(j.version == 2, '状态 version = 2');
    check(strcmp(j.workDir, base), '状态 workDir 正确');
    check(isfield(j, 'subjectID') && strcmp(j.subjectID, 'Sub01'), '状态 subjectID = Sub01');
    check(isfield(j, 'viewMode') && strcmp(j.viewMode, 'triple'), '状态 viewMode = triple');
    check(isfield(j, 'crosshairVoxel') && numel(j.crosshairVoxel) == 3, ...
        '状态 crosshairVoxel 为 3 元数组');
    check(isfield(j, 'display') && isfield(j.display, 'mode'), '状态含 display.mode');
    check(isfield(j, 'display') && isfield(j.display, 'matrix'), '状态含 display.matrix 4x4');
    check(isfield(j, 'slices') && isfield(j.slices, 'axial') && ...
        isfield(j.slices.axial, 'index') && isfield(j.slices.axial, 'count'), ...
        '状态含 slices.axial.index/count');
    check(isfield(j, 'window') && numel(j.window) == 2, '状态含 window 窗宽百分位');
    check(isfield(j, 'colormap') && isfield(j, 'interp'), '状态含 colormap/interp');
    check(isfield(j, 'overlay') && isfield(j.overlay, 'visible'), '状态含 overlay');
    check(isfield(j, 'score') && isfield(j.score, 'current'), '状态含 score.current');
    check(isfield(j, 'headMotion') && isfield(j.headMotion, 'fdType') && ...
        isfield(j.headMotion, 'values') && numel(j.headMotion.values) >= 40, ...
        '状态含 headMotion.values（逐帧 FD）');
    % headMotion.meanFD 必须 = HeadMotion.tsv 第 21 列（与窗口一致）；seriesMeanFD = 逐帧均值
    check(isfield(j.headMotion, 'meanFD') && abs(j.headMotion.meanFD - 0.08) < 1e-9, ...
        sprintf('headMotion.meanFD = HeadMotion.tsv 0.0800（%.4f）', j.headMotion.meanFD));
    check(isfield(j.headMotion, 'seriesMeanFD') && ...
        abs(j.headMotion.seriesMeanFD - mean(double(j.headMotion.values))) < 1e-9, ...
        sprintf('headMotion.seriesMeanFD = 逐帧序列均值（%.4f）', j.headMotion.seriesMeanFD));
    check(isfield(j.headMotion, 'meanFDSource') && ...
        ~isempty(strfind(j.headMotion.meanFDSource, 'HeadMotion.tsv')), ...
        sprintf('headMotion.meanFDSource 标明来源（%s）', j.headMotion.meanFDSource));
    check(isfield(j.headMotion, 'maxFD') && isfinite(j.headMotion.maxFD), ...
        sprintf('headMotion.maxFD 为序列最大值（%.4f）', j.headMotion.maxFD));
    check(isfield(j, 'progress') && isfield(j.progress, 'T1'), '状态含 progress.T1');
    check(isfield(j, 'filter') && isfield(j, 'sort'), '状态含 filter/sort');
    check(isfield(j, 'updatedAt') && ~isempty(j.updatedAt), '状态含 updatedAt 时间戳');
    ts = char(j.updatedAt);
    tsOk = ~isempty(regexp(ts, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)?$', 'once'));
    check(tsOk, sprintf('updatedAt 为 ISO 8601（%s）', ts));
    check(isempty(strfind(ts, '-00:00')), 'updatedAt 不使用错误的 -00:00 偏移');
    % 十字线三项同源：体素/世界/显示由同一个体素派生（fixture hdr.mat≈1mm 时世界≈体素）
    cv = double(j.crosshairVoxel(:).');
    cw = double(j.crosshairWorld(:).');
    check(numel(cv) == 3 && numel(cw) == 3 && ...
        max(abs(cw - cv)) < 2.0, ...
        sprintf('crosshairVoxel 与 crosshairWorld 同源（%s / %s）', ...
        fmtVecQc(cv, '%.1f'), fmtVecQc(cw, '%.1f')));
    j2 = jsondecode(fileread(outState));
    check(strcmp(j2.subjectID, 'Sub01') && strcmp(j2.viewMode, 'triple'), ...
        'exportState 指定路径内容与当前状态一致');
    % display.matrix 语义：与 getViewInfo().DisplayMatrix 一致（不能转置）
    p.setManualOrientation([1 2 3], [10 20 30]);
    outState2 = fullfile(tempdir, 'mrw_qc_panel_state_matrix.json');
    if exist(outState2, 'file') == 2
        delete(outState2);
    end
    p.exportState(outState2);
    jM = jsondecode(fileread(outState2));
    viM = p.getViewInfo();
    Mexp = double(viM.DisplayMatrix);
    check(isequal(size(jM.display.matrix), [4 4]) && ...
        max(abs(double(jM.display.matrix(:)) - Mexp(:))) < 1e-9, ...
        'display.matrix 与 getViewInfo().DisplayMatrix 完全一致（未转置）');
    p.resetOrientation();
    % 状态文件写入为合法 JSON（可再次解析）且原子写入不留 .tmp
    check(exist([stateFile '.tmp'], 'file') ~= 2, '状态 JSON 原子写入（无残留 .tmp）');

    % ------------------------------------------------------------------
    % 18. QcAlignDialog（方位校准对话框）
    % ------------------------------------------------------------------
    dlg = p.openAlignDialog();
    check(~isempty(dlg) && isvalid(dlg), 'openAlignDialog 返回对话框对象');
    check(isvalid(dlg.Figure), '方位校准对话框窗口已创建');
    [nCtrlD, missingD] = countTips(dlg.Figure);
    check(isempty(missingD), sprintf('对话框 %d 个交互控件均有 Tooltip', nCtrlD));
    if ~isempty(missingD)
        fprintf('      对话框缺 Tooltip：%s\n', strjoin(missingD, ', '));
    end
    % 通过对话框按钮拾取 AC/PC 并应用配平
    p.setCrosshairVoxel([32 32 20]);
    check(pressButton(dlg.Figure, 'qcAlignPickAc'), '对话框“把当前位置设为 AC”按钮存在');
    p.setCrosshairVoxel([32 32 10]);
    check(pressButton(dlg.Figure, 'qcAlignPickPc'), '对话框“把当前位置设为 PC”按钮存在');
    check(pressButton(dlg.Figure, 'qcAlignApplyACPC'), '对话框“应用 AC-PC 配平”按钮存在');
    drawnow;
    stDlg = p.getState();
    check(strcmp(stDlg.Display.Mode, 'acpc'), ...
        sprintf('对话框应用 AC-PC 后显示模式 = acpc（%s）', stDlg.Display.Mode));
    check(pressButton(dlg.Figure, 'qcAlignClearACPC'), '对话框“清除配平”按钮存在');
    check(strcmp(p.getState().Display.Mode, 'native'), '对话框清除配平后恢复 native');
    % 手动微调字段 + 应用
    setTagValue(dlg.Figure, 'qcAlignTrans1', 3);
    setTagValue(dlg.Figure, 'qcAlignRot2', 6);
    check(pressButton(dlg.Figure, 'qcAlignApplyManual'), '对话框“应用微调”按钮存在');
    drawnow;
    [manTdlg, manRdlg] = manualFromState(p.getState());
    check(abs(manTdlg(1) - 3) < 1e-6 && abs(manRdlg(2) - 6) < 1e-6, ...
        '对话框应用手动平移/旋转生效');
    check(pressButton(dlg.Figure, 'qcAlignClearManual'), '对话框“清零微调”按钮存在');
    [manTdlg2, manRdlg2] = manualFromState(p.getState());
    check(all(abs(manTdlg2) < 1e-6) && all(abs(manRdlg2) < 1e-6), '对话框清零微调生效');
    % 翻转复选框
    hFlip = findobj(dlg.Figure, 'Tag', 'qcAlignFlipLR');
    check(~isempty(hFlip), '对话框左右翻转复选框存在');
    if ~isempty(hFlip)
        hFlip(1).Value = true;
        try
            cb = hFlip(1).ValueChangedFcn;
            cb(hFlip(1), []);
        catch
        end
        drawnow;
        flDialog = p.getFlips();
        check(flDialog(1), '对话框左右翻转生效');
    end
    check(pressButton(dlg.Figure, 'qcAlignReset'), '对话框“重置全部方位”按钮存在');
    fl3 = p.getFlips();
    check(~any(fl3), '对话框重置全部方位清除翻转');
    dlg.close();
    check(isempty(dlg.Figure), '对话框关闭后 Figure 清空');

    % close 后可重新打开（openAlignDialog 不应返回已关闭实例）
    dlgRe = p.openAlignDialog();
    check(~isempty(dlgRe) && isvalid(dlgRe) && ~isempty(dlgRe.Figure) && ...
        isvalid(dlgRe.Figure), 'close 后可重新打开校准对话框');
    % 外部 delete(dlg)（不经过关闭按钮）后面板事件不得报“对象无效/已删除”
    delete(dlgRe);
    lastwarn('');
    p.setSubject(2);
    p.setSubject(1);
    p.refresh();
    drawnow;
    [wmsg, wid] = lastwarn; %#ok<ASGLU>
    badWarn = ~isempty(wmsg) && ...
        (~isempty(strfind(wmsg, '删除')) || ~isempty(strfind(wmsg, '无效')) || ...
        ~isempty(strfind(wmsg, 'Invalid')) || ~isempty(strfind(wmsg, 'deleted')));
    check(~badWarn, sprintf('外部 delete(dlg) 后面板事件无已删除对象警告（warn=%s）', wmsg));
    dlgRe2 = p.openAlignDialog();
    check(~isempty(dlgRe2) && isvalid(dlgRe2) && ~isempty(dlgRe2.Figure) && ...
        isvalid(dlgRe2.Figure), 'delete(dlg) 后仍可重新打开校准对话框');
    % 直接 delete 也应只清理一次且不报错
    delete(dlgRe2);
    check(true, 'delete(dlg) 幂等清理不报错');

    % 面板销毁后对话框不报错（边界）
    if okNoData
        try
            dlg2 = p2.openAlignDialog();
            check(isvalid(dlg2.Figure), '空数据面板也能打开校准对话框');
            delete(p2);
            drawnow;
            errDlg = false;
            try
                dlg2.refresh();
            catch
                errDlg = true;
            end
            check(~errDlg, '面板销毁后对话框 refresh 不报错');
            check(isempty(dlg2.Figure), '面板销毁后对话框自动关闭');
        catch ME
            check(false, ['面板销毁后对话框异常：' ME.message]);
        end
    end

    % delete 对话框对象后再删除面板：不得有收尾警告（避免 DestroyListener 访问已删除对象）
    dlgDel = p.openAlignDialog();
    if ~isempty(dlgDel) && isvalid(dlgDel)
        delete(dlgDel);
    end
    lastwarn('');
    p.setSubject(2);
    p.setSubject(1);
    drawnow;
    [wmsg2, wid2] = lastwarn; %#ok<ASGLU>
    badWarn2 = ~isempty(wmsg2) && ...
        (~isempty(strfind(wmsg2, '删除')) || ~isempty(strfind(wmsg2, '无效')) || ...
        ~isempty(strfind(wmsg2, 'Invalid')) || ~isempty(strfind(wmsg2, 'deleted')));
    check(~badWarn2, sprintf('面板收尾事件无已删除对话框警告（warn=%s）', wmsg2));

    % ------------------------------------------------------------------
    % 19. 截图：单视图 / 缩放 / 标准化（v1）+ v2 已拍 4 张
    % ------------------------------------------------------------------
    p.setViewMode('single');
    p.setModality('T1');
    p.setSubject(1);
    p.setOrientation('axial');
    p.setSliceIndex(mid);
    p.setWindow(2, 98);
    p.setZoomFactor(1);
    p.setFilterOnlyUnscored(false);
    p.setThreshold(3);
    p.setScore(4);
    drawnow;
    pause(0.6);
    shotDefault = fullfile(here, 'out_qc_panel_default.png');
    saveShot(fig, shotDefault);

    p.setZoomFactor(3.0);
    drawnow;
    pause(0.4);
    check(p.getZoomFactor() >= 2.5, ...
        sprintf('缩放截图倍数 %.2f× >= 2.5', p.getZoomFactor()));
    shotZoom = fullfile(here, 'out_qc_panel_zoom.png');
    saveShot(fig, shotZoom);

    p.setModality('Norm');
    p.setNormKind('Fun');
    p.setOverlayVisible(true);
    p.setOverlayAlpha(0.65);
    stNorm = p.getState();
    p.setSliceIndex(round(stNorm.SliceCount / 2));
    p.setZoomFactor(1);
    drawnow;
    pause(0.6);
    shotNorm = fullfile(here, 'out_qc_panel_norm.png');
    saveShot(fig, shotNorm);
    p.setModality('T1');

    shots = {shotDefault, shotZoom, shotNorm, shotTriple, shotAcpc, shotMontage, shotFdLow};
    names = {'单视图', '缩放', '标准化+轮廓', '三正交+十字线', 'AC-PC 配平', ...
        '多切片网格', 'FD 曲线+低分联动'};
    for i = 1:numel(shots)
        if isempty(shots{i})
            check(false, sprintf('%s 截图未生成（%s）', names{i}, '依赖失败'));
            continue;
        end
        okShot = exist(shots{i}, 'file') == 2;
        bytes = 0;
        if okShot
            d = dir(shots{i});
            bytes = d.bytes;
        end
        check(okShot && bytes > 8000, ...
            sprintf('%s截图存在且非空：%s（%d 字节）', names{i}, shots{i}, bytes));
    end

    % ------------------------------------------------------------------
    % 20. 收尾
    % ------------------------------------------------------------------
    try, close(fig); catch, end
    try, close(fig2); catch, end
    try, close(fig3); catch, end
    fprintf('\n=== 测试结果：%d 项失败 / 共 %d 项断言 ===\n', failures, nAssertions);
    if failures > 0
        error('test_qc_panel:Failed', '有 %d 项测试未通过', failures);
    end
    fprintf('全部测试通过。\n');
    for i = 1:numel(shots)
        if ~isempty(shots{i})
            fprintf('截图：%s\n', shots{i});
        end
    end

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

    function onChanged()
        changedCount = changedCount + 1;
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
            fprintf('  [警告] exportapp 截图失败：%s\n', ME.message);
        end
    end
end

% ======================================================================
%  文件级辅助函数
% ======================================================================
function [n, missing] = countTips(fig)
    n = 0;
    missing = {};
    types = {'uibutton', 'uidropdown', 'uieditfield', 'uicheckbox', ...
        'uislider', 'uitable', 'uiradiobutton', 'uitextarea'};
    hs = findall(fig);
    for i = 1:numel(hs)
        try
            t = get(hs(i), 'Type');
        catch
            continue;
        end
        if ~any(strcmp(t, types))
            continue;
        end
        n = n + 1;
        tip = '';
        try
            tip = hs(i).Tooltip;
        catch
        end
        if ~ischar(tip) || isempty(tip)
            label = t;
            try
                if isprop(hs(i), 'Tag') && ~isempty(hs(i).Tag)
                    label = [t ':' hs(i).Tag];
                end
            catch
            end
            missing{end+1} = label; %#ok<AGROW>
        end
    end
end

function n = countImages(ax)
    n = 0;
    if isempty(ax) || ~isvalid(ax)
        return;
    end
    try
        imgs = findobj(ax, 'Type', 'image');
        n = numel(imgs);
    catch
    end
end

function txt = getTagText(fig, tag)
    txt = '';
    h = findobj(fig, 'Tag', tag);
    if isempty(h)
        return;
    end
    try
        if isprop(h(1), 'Text')
            txt = h(1).Text;
        elseif isprop(h(1), 'Value')
            txt = h(1).Value;
        end
    catch
    end
    if ~ischar(txt)
        try
            txt = mat2str(txt);
        catch
            txt = '';
        end
    end
end

function v = getTagValue(fig, tag)
    v = NaN;
    h = findobj(fig, 'Tag', tag);
    if isempty(h)
        return;
    end
    try
        v = h(1).Value;
    catch
    end
    if ~isnumeric(v) || ~isscalar(v)
        v = NaN;
    end
end

function setTagValue(fig, tag, val)
    h = findobj(fig, 'Tag', tag);
    if isempty(h)
        return;
    end
    try
        h(1).Value = val;
    catch
    end
end

function ok = pressButton(fig, tag)
    ok = false;
    h = findobj(fig, 'Tag', tag);
    if isempty(h)
        return;
    end
    try
        cb = h(1).ButtonPushedFcn;
        if ~isempty(cb)
            cb(h(1), []);
        end
        ok = true;
    catch
    end
end

function [t, r] = manualFromState(st)
    t = [0 0 0];
    r = [0 0 0];
    if ~isstruct(st) || ~isfield(st, 'Display') || ~isstruct(st.Display)
        return;
    end
    if isfield(st.Display, 'Manual') && isstruct(st.Display.Manual)
        tv = st.Display.Manual.TranslationMm;
        rv = st.Display.Manual.RotationDeg;
        if isnumeric(tv) && numel(tv) >= 3
            t = double(tv(1:3));
        end
        if isnumeric(rv) && numel(rv) >= 3
            r = double(rv(1:3));
        end
    end
end

function s = ifelseStr(cond, a, b)
    if cond
        s = a;
    else
        s = b;
    end
end

function s = fmtVecQc(v, fmt)
    % 格式化 1xN 数值向量（替代 mat2str 的格式化输出）
    if nargin < 2 || isempty(fmt)
        fmt = '%.1f';
    end
    if ~isnumeric(v) || isempty(v)
        s = '[]';
        return;
    end
    s = ['[' strtrim(sprintf([fmt ' '], double(v(:).'))) ']'];
end

% ----------------------------------------------------------------------
%  逐帧 FD 测试数据兜底（仅当 view-engine 的 qc_fixture 未提供时写入）
% ----------------------------------------------------------------------
function ensureFdFixture(base)
    subs = {'Sub01', 'Sub02', 'Sub03'};
    for i = 1:numel(subs)
        id = subs{i};
        d = fullfile(base, 'RealignParameter', id);
        if exist(d, 'dir') ~= 7
            try, mkdir(d); catch, end
        end
        fJ = fullfile(d, sprintf('FD_Jenkinson_%s.txt', id));
        if exist(fJ, 'file') ~= 2
            writeFdFile(fJ, syntheticFd('FD_Jenkinson', i));
        end
        fP = fullfile(d, sprintf('FD_Power_%s.txt', id));
        if exist(fP, 'file') ~= 2
            writeFdFile(fP, syntheticFd('FD_Power', i));
        end
    end
end

function v = syntheticFd(kind, subjIdx)
    n = 60;
    v = 0.03 + 0.01 * sin((1:n) / 7) + 0.002 * subjIdx;
    switch kind
        case 'FD_Power'
            v = 0.08 + 0.03 * sin((1:n) / 9) + 0.01 * subjIdx;
            badIdx = [20 45];
            badVal = [0.65 0.58];
        otherwise
            badIdx = [10 25 40] + subjIdx;
            badVal = [0.31 0.35 0.28] + 0.02 * subjIdx;
    end
    v = max(v, 0.005);
    v(badIdx) = badVal;
end

function writeFdFile(filePath, v)
    fid = fopen(filePath, 'w', 'n', 'UTF-8');
    if fid < 0
        return;
    end
    try
        fprintf(fid, '%.6f\n', v);
        fclose(fid);
    catch
        try, fclose(fid); catch, end
    end
end
