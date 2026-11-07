function test_qc_layout()
% 布局几何自检；真实桌面文字/遮挡验收另行截图，不由本测试替代。
    here = fileparts(mfilename('fullpath'));
    addpath(fileparts(here)); addpath(here);
    base = qc_fixture();
    f = uifigure('Position', [30 30 1440 900]);
    p = mrw.QcPanel(f, struct('WorkingDir', base, 'Footer', true));
    cleanup = onCleanup(@() closePanel(p, f)); %#ok<NASGU>
    p.setSliceIndex(12);
    toggle = findobj(f, 'Tag', 'qcFdToggle'); body = findobj(f, 'Tag', 'qcFdBody');
    assert(strcmp(body.Visible, 'off'), '默认收起FD辅助区');
    feval(toggle.ButtonPushedFcn, toggle, []); settle();
    assert(strcmp(body.Visible, 'on'), '实际展开回调显示FD辅助区');
    fdType = findobj(f, 'Tag', 'qcFdType'); threshold = findobj(f, 'Tag', 'qcFdThreshold');
    fdType.Value = 'FD_Power'; feval(fdType.ValueChangedFcn, fdType, []);
    threshold.Value = 0.35; feval(threshold.ValueChangedFcn, threshold, []);
    st = p.getState();
    assert(strcmp(st.FD.Type, 'FD_Power') && st.FD.Threshold == 0.35 && ...
        ~isempty(st.FD.Values), '展开后原FD类型/阈值控件仍可用');
    feval(toggle.ButtonPushedFcn, toggle, []); settle();
    assert(strcmp(body.Visible, 'off') && strcmp(fdType.Value, 'FD_Power') && ...
        threshold.Value == 0.35, '收起FD保留类型和阈值');
    feval(toggle.ButtonPushedFcn, toggle, []); settle();
    assert(strcmp(body.Visible, 'on') && strcmp(fdType.Enable, 'on') && ...
        strcmp(threshold.Enable, 'on'), '再次展开可继续操作原控件');
    feval(toggle.ButtonPushedFcn, toggle, []);
    p.setFdType('FD_Jenkinson'); p.setFdThreshold(0.2); settle();
    modes = {'single', 'triple', 'montage'};
    saved = cell(1, 3);
    for k = 1:3
        p.setViewMode(modes{k}); p.setZoomFactor(1); settle();
        axes = viewAxes(p, modes{k});
        saved{k} = cell(1, numel(axes));
        for j = 1:numel(axes)
            ax = axes{j}; wh = plotSize(ax);
            assert(isequal(ax.DataAspectRatio, [1 1 1]), '图像须保持等比例');
            saved{k}{j} = {ax, ax.XLim, ax.YLim, ax.XDir, ax.YDir};
            fprintf('QC_LAYOUT %s/%d actual=%.1fx%.1f inner=%.1fx%.1f logical px\n', ...
                modes{k}, j, wh, ax.InnerPosition(3:4));
            if k == 1
                assert(min(wh) >= 450, '默认单视图实际图像短边应至少450px');
            elseif k == 2
                assert(prod(wh) >= 45000, '三正交每幅实际图像面积应至少45000px^2');
            else
                im = findobj(ax, 'Type', 'image');
                assert(isequal(size(im(1).CData), [320 320]), 'fixture保持5x5共25格');
                assert(min(wh / 5) >= 80, '默认多切片每tile短边应至少80px');
            end
        end
    end
    crosshair = p.getCrosshairVoxel();
    arrangements = cell(1, 3); windowIndex = 0;
    for windowSize = [2400 1000 1440; 650 1100 900]
        windowIndex = windowIndex + 1;
        pos = f.Position; pos(3:4) = windowSize'; f.Position = pos; settle();
        for repeat = 1:2
            for k = 1:3
                p.setViewMode(modes{k}); settle();
                axes = viewAxes(p, modes{k});
                for j = 1:numel(axes)
                    ax = axes{j}; prior = saved{k}{j};
                    wh = plotSize(ax);
                    fprintf(['QC_LAYOUT resize requested=%dx%d actualFigure=%.1fx%.1f repeat=%d %s/%d ' ...
                        'actual=%.1fx%.1f inner=%.1fx%.1f grid=%.1fx%.1f row=%s col=%s XLim=%s YLim=%s\n'], ...
                        windowSize, f.Position(3:4), repeat, modes{k}, j, wh, ...
                        ax.InnerPosition(3:4), ax.Parent.Position(3:4), ...
                        mat2str(ax.Layout.Row), mat2str(ax.Layout.Column), mat2str(ax.XLim), mat2str(ax.YLim));
                    assert(isequal(ax, prior{1}), '切换/缩放窗口应复用axes');
                    assert(max(abs(ax.XLim - prior{2})) <= 1e-9 && max(abs(ax.YLim - prior{3})) <= 1e-9 && ...
                        strcmp(ax.XDir, prior{4}) && strcmp(ax.YDir, prior{5}), ...
                        '布局变化不得改变完整视野、比例或显示方向');
                    assert(all(wh > 80), '窗口缩放后每幅图仍有有效绘图区');
                end
                if k == 2
                    arrangements{windowIndex} = cellfun(@(ax) ...
                        {ax.Layout.Row, ax.Layout.Column}, axes, 'UniformOutput', false);
                end
            end
        end
    end
    assert(~isequal(arrangements{1}, arrangements{2}) && ~isequal(arrangements{1}, arrangements{3}) && ...
        ~isequal(arrangements{2}, arrangements{3}), '三正交宽/高/默认窗口须覆盖三种排列');
    assert(norm(crosshair - p.getCrosshairVoxel(), Inf) <= 1e-9, '布局/模式切换不得移动十字线');
    dlg = p.openAlignDialog(); settle();
    content = findobj(dlg.Figure, 'Tag', 'qcAlignContent');
    footer = findobj(dlg.Figure, 'Tag', 'qcAlignFooter');
    assert(isscalar(content) && strcmp(content.Scrollable, 'on'), '校准正文须可滚动');
    for windowSize = [640 650; 830 500]
        pos = dlg.Figure.Position; pos(3:4) = windowSize'; dlg.Figure.Position = pos; settle();
        checkDialogGrids(dlg.Figure);
        for tag = {'qcAlignReset', 'qcAlignApplyData', 'qcAlignClose'}
            button = findobj(dlg.Figure, 'Tag', tag{1});
            r = getpixelposition(button, true);
            assert(isequal(button.Parent, footer) && r(2) >= 0 && ...
                r(2) + r(4) <= windowSize(2) + 1 && r(4) >= 28, '底部操作须始终可见可点');
        end
    end
    fprintf('QC_LAYOUT dialog figure=%s content=%s footer=%s\n', ...
        mat2str(dlg.Figure.Position), mat2str(content.Position), mat2str(footer.Position));
    assert(sum([content.RowHeight{:}]) + content.RowSpacing * 7 > dlg.Figure.InnerPosition(4), ...
        '小窗口正文应保留行高并启用滚动，不能压缩控件');
    hint = findobj(dlg.Figure, 'Tag', 'qcAlignHint');
    matrix = findobj(dlg.Figure, 'Tag', 'qcAlignMatrix');
    before = matrix.Position;
    hint.Value = repmat({'长状态提示不应挤压矩阵和操作按钮。'}, 12, 1); settle();
    assert(isequal(before, matrix.Position) && matrix.Position(4) >= 90, ...
        '多行矩阵和长状态提示各自保留空间');
    scroll(content, 'bottom'); settle(); scroll(content, 'top'); settle();
    dlg.close();
    panels = {ancestor(findobj(f, 'Tag', 'qcBrowse'), 'uipanel'), ancestor(p.Axes, 'uipanel')};
    delete(p);
    for panel = panels
        callback = panel{1}.SizeChangedFcn;
        if ~isempty(callback), callback(panel{1}, []); end
    end
    f.Position(3) = 1100; settle();
    fprintf('TEST_QC_LAYOUT_PASS\n');
end

function settle()
    % UI figure 的 Chromium 布局在 drawnow 返回后仍需一次异步提交。
    drawnow; pause(0.75); drawnow;
end

function axes = viewAxes(p, mode)
    st = p.getState(); h = st.AxesHandles;
    switch mode
        case 'single', axes = {h.Single};
        case 'triple', axes = {h.Axial, h.Coronal, h.Sagittal};
        otherwise, axes = {h.Montage};
    end
end

function wh = plotSize(ax)
    units = ax.Units; ax.Units = 'pixels';
    pos = ax.InnerPosition; ax.Units = units;
    ratio = diff(ax.XLim) / diff(ax.YLim) * ax.DataAspectRatio(2) / ax.DataAspectRatio(1);
    width = min(pos(3), pos(4) * ratio);
    wh = [width, width / ratio];
end

function checkDialogGrids(fig)
    grids = findall(fig, '-isa', 'matlab.ui.container.GridLayout');
    for g = grids'
        fixed = cellfun(@(v) isnumeric(v), g.RowHeight);
        if ~strcmp(g.Scrollable, 'on')
            needed = sum([g.RowHeight{fixed}]) + g.RowSpacing * (numel(g.RowHeight) - 1) + sum(g.Padding([2 4]));
            assert(needed <= g.Position(4) + 1, '校准面板须为标题/行高/间距留足空间');
        end
        children = g.Children;
        for i = 1:numel(children)
            a = children(i).Position;
            assert(all(a(3:4) > 0), '所有校准控件须有有效尺寸');
            for j = i+1:numel(children)
                b = children(j).Position;
                overlap = min(a(1:2) + a(3:4), b(1:2) + b(3:4)) - max(a(1:2), b(1:2));
                assert(~all(overlap > 1), '同层校准控件不可互相遮挡: %s/%s %s 与 %s %s', ...
                    g.Tag, children(i).Tag, mat2str(a), children(j).Tag, mat2str(b));
            end
        end
    end
end

function closePanel(p, f)
    if isvalid(p), delete(p); end
    if isvalid(f), delete(f); end
end
