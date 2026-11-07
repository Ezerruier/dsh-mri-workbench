function test_qc_integration_lead
% 人工 QC 集成测试：QcViewer 独立窗口 + WorkbenchApp 第 6 页 + 评分往返
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
addpath(here);
outDir = fullfile(here, 'out_qc_integration');
if exist(outDir, 'dir') ~= 7, mkdir(outDir); end
fid = fopen(fullfile(outDir, 'log.txt'), 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});
app = []; fig = [];
try
    base = qc_fixture();
    say('fixture: %s', base);

    % ---------- 1) 独立 QcViewer ----------
    fig = mrw.QcViewer.open(base, 'T1');
    drawnow; pause(0.6);
    say('QcViewer 图窗可用: %d', isvalid(fig));
    p = [];
    try, p = getappdata(fig, 'MRW_QcPanel'); catch, end
    say('QcViewer 内嵌 QcPanel: %d', ~isempty(p));
    if ~isempty(p)
        st = p.getState();
        say('QcPanel.WorkingDir=%s Modality=%s Subject=%s', st.WorkingDir, st.Modality, st.SubjectID);
        say('QcPanel.ViewMode=%s Version=%s', st.ViewMode, p.Version);
        assert(strcmp(st.WorkingDir, base), 'QcPanel 工作目录不一致');
        assert(strcmp(st.ViewMode, 'single'), 'QcPanel v2 默认视图模式不是 single');
        f1 = p.setZoomFactor(2.5);
        f2 = p.getZoomFactor();
        say('zoom after setZoomFactor(2.5): %.2f / get=%.2f', f1, f2);
        assert(abs(f2 - 2.5) < 0.2, '缩放未生效');
        p.setSliceIndex(8);
        p.setOrientation('coronal');
        drawnow;
        % v2：状态 JSON 自动写入 + 三正交切换
        sf = fullfile(base, 'QC', '.qcviewer_state.json');
        say('v2 状态 JSON 存在=%d（%s）', exist(sf, 'file') == 2, sf);
        assert(exist(sf, 'file') == 2, 'QcPanel v2 未自动写入 QC/.qcviewer_state.json');
        p.setViewMode('triple');
        drawnow;
        stTri = p.getState();
        say('三正交: mode=%s active=%s cross=%s', stTri.ViewMode, ...
            stTri.ActiveOrientation, mat2str(stTri.CrosshairVoxel, 3));
        assert(strcmp(stTri.ViewMode, 'triple'), 'QcPanel v2 三正交切换失败');
        p.setViewMode('single');
        % 评分往返
        p.setScore(4);
        p.setComment('集成测试评语');
        ok = p.saveCurrentScore();
        sc = mrw.QcModel.loadScores(base, 'T1');
        idx = find(strcmp({sc.ID}, 'Sub01'), 1);
        say('saveCurrentScore ok=%d; 读回 Sub01: score=%g comment=%s', ...
            ok, sc(idx).Score, sc(idx).Comment);
        assert(ok && idx > 0 && sc(idx).Score == 4, '评分写回失败');
        try
            exportapp(fig, fullfile(outDir, 'viewer_zoom.png'));
            say('QcViewer 截图已保存');
        catch err
            say('QcViewer 截图失败: %s', err.message);
        end
    end
    try, delete(fig); catch, end
    fig = [];

    % ---------- 2) WorkbenchApp 第 6 页 ----------
    app = mrw.WorkbenchApp();
    drawnow; pause(0.6);
    say('主工作台页面数: %d; QcPanel 可用: %d', numel(app.Pages), ~isempty(app.qcPanel()));
    app.showPage(6);
    drawnow; pause(0.4);
    if ~isempty(app.qcPanel())
        app.qcPanel().setWorkingDir(base);
        drawnow; pause(0.4);
        st = app.qcPanel().getState();
        say('主界面人工QC页: WorkingDir=%s Subject=%s', st.WorkingDir, st.SubjectID);
        assert(strcmp(st.WorkingDir, base), '主界面人工QC未同步工作目录');
        try
            exportapp(app.Fig, fullfile(outDir, 'page6_qc.png'));
            say('第 6 页截图已保存');
        catch err
            say('第 6 页截图失败: %s', err.message);
        end
    end
    delete(app.Fig);
    app = [];
    say('QC_INTEGRATION_RESULT=SUCCESS');
catch err
    say('QC_INTEGRATION_RESULT=FAILED: %s', err.message);
    for k = 1:min(numel(err.stack), 8)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
end
try, if ~isempty(fig) && isvalid(fig), delete(fig); end, catch, end
try, if ~isempty(app) && isvalid(app.Fig), delete(app.Fig); end, catch, end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end
