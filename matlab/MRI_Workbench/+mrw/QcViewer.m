classdef QcViewer
% QcViewer  独立“人工 QC”窗口（可缩放查看 + DPARSF 兼容 1–5 分人工评分）
%
% 用法:
%   mrw.QcViewer.open()                       % 打开后手动选择工作目录
%   mrw.QcViewer.open(workDir)                % 指定 DPARSF 工作目录
%   mrw.QcViewer.open(workDir, 'Norm')        % 直接进入标准化检查
%
% 说明:
%   - 内部使用 mrw.QcPanel（与主工作台第 6 页同一个组件）；
%   - 评分写入 <workDir>/QC/RawT1ImgQC.tsv、RawFunImgQC.tsv、NormalizationQC.tsv，
%     格式与 DPARSF 一致，可被 DPABI_QC_TOOL 读取；
%   - 普通滚轮切层；Ctrl+滚轮缩放；单击定位；拖拽平移。
%   - [－][1:1][＋][适应] 与双击适应作用于活动视图。

    methods (Static)

        function fig = open(workDir, modality)
            if nargin < 1 || isempty(workDir)
                workDir = '';
            end
            if nargin < 2 || isempty(modality)
                modality = 'T1';
            end
            here = fileparts(mfilename('fullpath'));   % .../+mrw
            proj = fileparts(here);                     % .../MRI_Workbench
            addpath(proj);
            try
                mrw.Dpabi.ensurePath();
            catch
            end

            fig = mrw.UiKit.newFigure('人工 QC — 可缩放查看与 1–5 分评分', [1440 900]);
            fig.CloseRequestFcn = @(s, e) local_close(s);
            try
                fig.Theme = 'light';
            catch
            end

            panel = [];
            if exist('mrw.QcPanel', 'class') == 8
                try
                    panel = mrw.QcPanel(fig, struct('WorkingDir', workDir, ...
                        'Modality', modality, 'Footer', true));
                catch err
                    warning('mrw:QcViewer:panel', 'QcPanel 初始化失败：%s', err.message);
                end
            end
            if isempty(panel)
                gl = uigridlayout(fig, [1 1]);
                gl.Padding = [20 20 20 20];
                uilabel(gl, 'Text', ['人工 QC 面板不可用：请确认 MRI_Workbench/+mrw/QcPanel.m 已就绪。' ...
                    newline '（若刚更新工作台，请在 MATLAB 中重新 addpath 后重试）'], ...
                    'FontName', mrw.UiKit.fonts().name, 'FontSize', 13, ...
                    'FontColor', mrw.UiKit.colors().err, 'VerticalAlignment', 'top');
            else
                try
                    setappdata(fig, 'MRW_QcPanel', panel);
                catch
                end
            end
        end
    end
end

function local_close(fig)
% 关闭窗口时清理「Agent 实时指导」状态文件（DSH 侧会提示窗口未打开）
try
    p = getappdata(fig, 'MRW_QcPanel');
    if ~isempty(p)
        try
            st = p.getState();
            wd = st.WorkingDir;
            if ischar(wd) && ~isempty(wd)
                f = fullfile(wd, 'QC', '.qcviewer_state.json');
                if exist(f, 'file') == 2
                    try, delete(f); catch, end
                end
            end
        catch
        end
    end
catch
end
try
    delete(fig);
catch
end
end
