function test_qc_interaction_v3()
% 回调级交互验收；evt 中的坐标替身只替代硬件命中，不跳过实际回调。
    addpath(fileparts(fileparts(mfilename('fullpath'))));
    base = qc_fixture();
    f = uifigure('Visible', 'off', 'Position', [20 20 1360 900]);
    p = mrw.QcPanel(f, struct('WorkingDir', base));
    cleanup = onCleanup(@() closePanel(p, f)); %#ok<NASGU>
    n = 0;
    p.setSliceIndex(12); ax = p.Axes;
    fire('WindowScrollWheelFcn', ax, [19 39], [100 100], 1, {});
    check(p.getState().SliceIndex == 13, '普通滚轮切层');
    beforeSlice = p.getState().SliceIndex;
    oldX = ax.XLim; oldY = ax.YLim; anchor = [19 39];
    fire('WindowScrollWheelFcn', ax, anchor, [100 100], -1, {'control'});
    check(p.getZoomFactor() > 1.1 && p.getState().SliceIndex == beforeSlice, 'Ctrl+滚轮仅缩放');
    check(max(abs((anchor(1)-oldX)/diff(oldX) - (anchor(1)-ax.XLim)/diff(ax.XLim))) < 1e-9, '缩放锚点 X 保持');
    check(max(abs((anchor(2)-oldY)/diff(oldY) - (anchor(2)-ax.YLim)/diff(ax.YLim))) < 1e-9, '缩放锚点 Y 保持');
    click(ax, [19 39]);
    check(norm(p.getCrosshairVoxel() - [20 40 13], Inf) <= 1, '单视图点击世界坐标到体素');
    j = jsondecode(fileread(fullfile(base,'QC','.qcviewer_state.json')));
    check(norm(j.crosshairVoxel(:)' - p.getCrosshairVoxel(), Inf) < 1e-6, '点击后状态 JSON 同步');
    cp=ax.CurrentPoint;
    expected=min(max([cp(1,1:2)+1,13],1),[64 64 30]);
    realLikeEvent=table(ax,[1e6 1e6],'VariableNames',{'HitObject','Point'});
    feval(f.WindowButtonDownFcn,f,realLikeEvent);
    feval(f.WindowButtonUpFcn,f,realLikeEvent);
    check(norm(p.getCrosshairVoxel()-expected,Inf)<=1, ...
        '真实形态事件对象的 Point 像素被忽略，点击读取 axes.CurrentPoint');
    p.setViewMode('triple'); p.setCrosshairVoxel([20 40 13]);
    st = p.getState(); a = st.AxesHandles.Axial; c = st.AxesHandles.Coronal; s = st.AxesHandles.Sagittal;
    cX = c.XLim; sX = s.XLim;
    fire('WindowScrollWheelFcn', a, [19 39], [100 100], -1, {'control'});
    aX = a.XLim; aY = a.YLim;
    check(isequal(c.XLim,cX) && isequal(s.XLim,sX), '三视图独立缩放');
    fire('WindowScrollWheelFcn', c, [19 12], [200 100], 1, {});
    check(strcmp(p.getState().ActiveOrientation,'coronal') && p.getState().SliceIndex == 41, '指针所在冠状视图切层并激活');
    check(isequal(a.XLim,aX) && isequal(a.YLim,aY), '切层保留其它视图缩放');
    cross = p.getCrosshairVoxel(); oldCX = c.XLim;
    fire('WindowButtonDownFcn', c, [19 12], [200 100], 0, {});
    fire('WindowButtonMotionFcn', c, [19 12], [225 118], 0, {});
    fire('WindowButtonUpFcn', c, [19 12], [225 118], 0, {});
    check(isequal(p.getCrosshairVoxel(),cross) && ~isequal(c.XLim,oldCX), '拖拽只平移而不移动十字线');
    click(c, [24 17]);
    check(norm(p.getCrosshairVoxel()-[25 41 18],Inf)<=1, '缩放平移后点击仍准确');
    p.setActiveOrientation('sagittal');
    zoomButton = findobj(f,'Tag','qcZoomIn'); feval(zoomButton.ButtonPushedFcn,zoomButton,[]);
    check(p.getZoomFactor()>1.1 && isequal(a.XLim,aX), '缩放按钮只改变活动矢状视图');
    fitButton = findobj(f,'Tag','qcZoomFit'); feval(fitButton.ButtonPushedFcn,fitButton,[]);
    check(abs(p.getZoomFactor()-1)<1e-6, '适应按钮恢复活动视图');
    fire('WindowScrollWheelFcn', a, [24 40], [100 100], -1, {'control'});
    e = event(a,[24 40],[100 100],0,{}); e.SelectionType='open';
    feval(f.WindowButtonDownFcn,f,e);
    check(abs(p.getZoomFactor()-1)<1e-6, '双击恢复适应');
    info = findobj(f,'Tag','qcTripleInfoText');
    check(numel(regexp(info.Text,'\n','split')) <= 3, '位置与校准摘要最多三行');
    p.setManualOrientation([2 -1 3],[0 0 90]);
    p.setCrosshairVoxel([25 41 13]);
    [~,hdr]=mrw.QcModel.loadVolume(p.getCurrentFile());
    vi=p.getViewInfo(); target=[17 23 13]; display=vi.DisplayMatrix*hdr.mat*[target 1]';
    click(a, display(1:2)');
    check(norm(p.getCrosshairVoxel()-target,Inf)<=1, '旋转后按显示平面轴映射点击而不依赖解剖标签');
    p.resetOrientation();
    p.setViewMode('single'); p.setModality('Norm');
    check(numel(findobj(p.Axes,'Type','image')) == 2, '世界显示平面保留标准化模板轮廓');
    p.setOverlayVisible(false); p.setOrientation('sagittal'); p.setOverlayVisible(true);
    images=findobj(p.Axes,'Type','image');
    check(numel(images)==2 && isequal(images(1).XData,images(2).XData) && ...
        isequal(images(1).YData,images(2).YData), '新建矢状模板轮廓使用与主图相同的有向坐标');
    p.setModality('T1'); p.setOrientation('axial');
    slider=findobj(f,'Tag','qcSliceSlider');
    if isempty(slider), slider=findobj(f,'Type','uislider'); slider=slider(1); end
    for value=8:12
        feval(slider.ValueChangingFcn,slider,struct('Value',value));
    end
    feval(slider.ValueChangedFcn,slider,struct('Value',13));
    j=jsondecode(fileread(fullfile(base,'QC','.qcviewer_state.json')));
    check(p.getState().SliceIndex==13 && j.slices.axial.index==13, '滑条合并更新后最终画面与状态正确');
    h=findobj(p.Axes,'Type','image');
    times=zeros(1,12);
    for k=1:12, t=tic; p.setSliceIndex(k+1); times(k)=toc(t); end
    check(isequal(h,findobj(p.Axes,'Type','image')), '单视图复用 image 句柄');
    singleMs=mean(times)*1000;
    check(singleMs<=50, sprintf('合成 native 单视图 %.2f ms <=50ms',singleMs));
    p.setViewMode('triple'); p.setActiveOrientation('axial');
    h=findobj(p.getState().AxesHandles.Axial,'Type','image');
    for k=1:12, t=tic; p.setSliceIndex(k+1); times(k)=toc(t); end
    tripleMs=mean(times)*1000;
    check(isequal(h,findobj(p.getState().AxesHandles.Axial,'Type','image')), '三正交复用 image 句柄');
    check(tripleMs<=150, sprintf('合成 native 三正交 %.2f ms <=150ms',tripleMs));
    fprintf('PERFORMANCE fixture single=%.2fms triple=%.2fms (mean, n=12, callback excludes drawnow)\n',singleMs,tripleMs);
    fprintf('PASS %d/%d test_qc_interaction_v3\n',n,n);

    function click(axis, point)
        fire('WindowButtonDownFcn',axis,point,[100 100],0,{});
        fire('WindowButtonUpFcn',axis,point,[101 101],0,{});
    end
    function fire(name,axis,point,pixel,count,mods)
        feval(f.(name),f,event(axis,point,pixel,count,mods));
    end
    function e=event(axis,point,pixel,count,mods)
        e=struct('HitObject',axis,'DataPoint',point,'Point',[1e6 1e6],'PixelPosition',pixel, ...
            'VerticalScrollCount',count,'Modifier',{mods},'SelectionType','normal');
    end
    function check(ok, message)
        n=n+1; assert(ok,'test_qc_interaction_v3:Failed',message);
        fprintf('PASS %s\n',message);
    end
end

function closePanel(p,f)
    if isvalid(p), delete(p); end
    if isvalid(f), delete(f); end
end
