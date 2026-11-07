classdef Dpabi
% Dpabi  DPABI/SPM 定位、路径初始化、版本信息、模板、原生界面启动
%
% 依赖: 已安装 DPABI (含 DPARSFA_run.m) 与 SPM12；本类只读 DPABI 安装目录，
%       不修改任何文件。用户 MATLAB 保存的路径通常已包含它们，此时无需 addpath。
%
% 用法:
%   mrw.Dpabi.ensurePath();     % 确保 DPABI/SPM 在路径中
%   st = mrw.Dpabi.status();    % 环境状态（供 UI 显示）
%   mrw.Dpabi.launchDPABI();    % 打开原生 DPABI 主界面
%   mrw.Dpabi.launchDPARSFA('Template_Blank'); % 打开原生 DPARSFA 高级版

    methods (Static)

        function root = root()
            % DPABI 根目录（已在路径中 -> 用户设置 -> 常见位置 -> 空）
            persistent cache
            if ~isempty(cache)
                root = cache;
                return;
            end
            root = '';
            % 1) 已在路径中
            try
                w = which('dpabi.m');
                if ~isempty(w)
                    root = fileparts(w);
                end
            catch
            end
            % 2) 用户设置
            if isempty(root)
                try
                    r = mrw.Settings.get('DpabiRoot');
                    if ~isempty(r) && exist(fullfile(r, 'dpabi.m'), 'file') == 2
                        root = r;
                    end
                catch
                end
            end
            % 3) 常见位置候选
            if isempty(root)
                candidates = {};
                try
                    candidates = mrw.Settings.get('AutoDetectPaths');
                catch
                end
                if ~iscell(candidates), candidates = {}; end
                candidates = [candidates(:)', {'D:\Software\DPABI', 'C:\Software\DPABI', ...
                    'D:\DPABI', 'C:\DPABI', 'D:\Program Files\DPABI', ...
                    'C:\Program Files\DPABI', 'D:\Matlab\Toolbox\DPABI'}];
                for i = 1:numel(candidates)
                    if exist(fullfile(candidates{i}, 'dpabi.m'), 'file') == 2
                        root = candidates{i};
                        break;
                    end
                end
            end
            cache = root;
        end

        function resetCache()
            % 清空根目录探测缓存（用户修改路径后调用）
            clear mrw.Dpabi
        end

        function root = spmRoot()
            root = '';
            try
                w = which('spm.m');
                if ~isempty(w)
                    root = fileparts(w);
                end
            catch
            end
            if isempty(root)
                try
                    r = mrw.Settings.get('SpmRoot');
                    if ~isempty(r) && exist(fullfile(r, 'spm.m'), 'file') == 2
                        root = r;
                    end
                catch
                end
            end
            if isempty(root)
                for base = {'D:\Software\spm12', 'C:\Software\spm12', 'D:\spm12', 'C:\spm12'}
                    if exist(fullfile(base{1}, 'spm.m'), 'file') == 2
                        root = base{1};
                        break;
                    end
                end
            end
        end

        function dv = version()
            % DPABI 版本号（从 dpabi.m 的 Release= 解析），未知返回 ''
            dv = '';
            r = mrw.Dpabi.root();
            if isempty(r), return; end
            try
                txt = fileread(fullfile(r, 'dpabi.m'));
                tok = regexp(txt, 'Release\s*=\s*''([^'']+)''', 'tokens', 'once');
                if ~isempty(tok)
                    dv = tok{1};
                end
            catch
            end
        end

        function st = status()
            % 环境状态结构体，供 UI 顶部状态条使用
            st = struct('DpabiRoot', '', 'SpmRoot', '', 'DpabiVersion', '', ...
                'HasDpabi', false, 'HasSpm', false, 'HasEngine', false, ...
                'DpabiOnPath', false, 'SpmOnPath', false, ...
                'MatlabVersion', version, 'PCT', false, 'Message', '');
            st.DpabiRoot = mrw.Dpabi.root();
            st.SpmRoot = mrw.Dpabi.spmRoot();
            st.HasDpabi = ~isempty(st.DpabiRoot);
            st.HasSpm = ~isempty(st.SpmRoot);
            st.HasEngine = exist('DPARSFA_run', 'file') == 2 || ...
                (~isempty(st.DpabiRoot) && exist(fullfile(st.DpabiRoot, 'DPARSF', 'DPARSFA_run.m'), 'file') == 2);
            try
                st.DpabiOnPath = ~isempty(which('dpabi.m'));
                st.SpmOnPath = ~isempty(which('spm.m'));
            catch
            end
            st.DpabiVersion = mrw.Dpabi.version();
            try
                st.PCT = license('test', 'Distrib_Computing_Toolbox') == 1;
            catch
            end
            if ~st.HasDpabi
                st.Message = '未找到 DPABI，请在“设置”中手动指定 DPABI 根目录';
            elseif ~st.HasSpm
                st.Message = '未找到 SPM12，请安装 SPM12 或指定其根目录';
            elseif ~st.HasEngine
                st.Message = '未找到 DPARSFA_run.m，DPABI 安装可能不完整';
            else
                st.Message = '环境就绪';
            end
        end

        function ok = ensurePath()
            % 确保 DPABI 全路径 + SPM12 在 MATLAB 搜索路径中
            ok = false;
            r = mrw.Dpabi.root();
            if isempty(r)
                return;
            end
            try
                if isempty(which('dpabi.m'))
                    addpath(genpath(r));
                else
                    if exist(fullfile(r, 'DPARSF'), 'dir') == 7 && isempty(which('DPARSFA_run.m'))
                        addpath(genpath(fullfile(r, 'DPARSF')));
                    end
                    addpath(fullfile(r));
                end
            catch
            end
            s = mrw.Dpabi.spmRoot();
            if ~isempty(s) && isempty(which('spm.m'))
                try
                    addpath(genpath(s));
                catch
                end
            end
            ok = ~isempty(which('DPARSFA_run.m')) && ~isempty(which('spm.m'));
        end

        function t = templates()
            % 返回 DPARSF 任务模板列表 struct array: Name, File, Desc
            t = struct('Name', {}, 'File', {}, 'Desc', {});
            r = mrw.Dpabi.root();
            if isempty(r), return; end
            d = fullfile(r, 'DPARSF', 'Jobmats');
            if exist(d, 'dir') ~= 7, return; end
            f = dir(fullfile(d, 'Template_*.mat'));
            descs = mrw.Dpabi.templateDescriptions();
            for i = 1:numel(f)
                nm = regexprep(f(i).name, '^Template_', '');
                nm = regexprep(nm, '\.mat$', '');
                e.Name = nm;
                e.File = fullfile(f(i).folder, f(i).name);
                if isKey(descs, nm)
                    e.Desc = descs(nm);
                else
                    e.Desc = nm;
                end
                t(end+1) = e; %#ok<AGROW>
            end
        end

        function Cfg = blankTemplate()
            % 载入 DPARSF 官方 Template_Blank.mat 中的 Cfg（含全部字段与默认值）
            Cfg = [];
            r = mrw.Dpabi.root();
            if isempty(r), return; end
            f = fullfile(r, 'DPARSF', 'Jobmats', 'Template_Blank.mat');
            if exist(f, 'file') ~= 2, return; end
            try
                S = load(f);
                if isfield(S, 'Cfg')
                    Cfg = S.Cfg;
                end
            catch
                Cfg = [];
            end
        end

        function launchDPABI()
            % 打开原生 DPABI 主界面（优先用 NativeLaunch：打开后自动汉化 + 悬停解释）
            mrw.Dpabi.ensurePath();
            if exist('mrw.NativeLaunch', 'class') == 8
                try
                    mrw.NativeLaunch.openDPABI();
                    return;
                catch
                end
            end
            figs = mrw.Dpabi.findFigure('DPABI');
            if ~isempty(figs)
                try, figure(figs(1)); catch, end
                mrw.Dpabi.afterOpenPatch();
                return;
            end
            try
                dpabi;
            catch err
                errordlg(sprintf('无法启动 DPABI 主界面：%s', err.message), '启动失败');
                return;
            end
            mrw.Dpabi.afterOpenPatch();
        end

        function launchDPARSFA(templateName)
            % 打开原生 DPARSFA 高级版界面。templateName 如 'Blank' 或 'Template_Blank'
            mrw.Dpabi.ensurePath();
            if nargin < 1 || isempty(templateName)
                templateName = 'Template_Blank';
            end
            if exist('mrw.NativeLaunch', 'class') == 8
                try
                    mrw.NativeLaunch.openDPARSFA(templateName);
                    return;
                catch
                end
            end
            if isempty(regexp(templateName, '^Template_', 'once'))
                templateName = ['Template_' templateName];
            end
            f = fullfile(mrw.Dpabi.root(), 'DPARSF', 'Jobmats', [templateName '.mat']);
            if exist(f, 'file') ~= 2
                if exist(templateName, 'file') == 2
                    f = templateName;
                else
                    errordlg(sprintf('未找到 DPARSF 模板：%s', f), '模板缺失');
                    return;
                end
            end
            figs = mrw.Dpabi.findFigure('DPARSFA');
            if ~isempty(figs)
                try, figure(figs(1)); catch, end
                mrw.Dpabi.afterOpenPatch();
                return;
            end
            try
                DPARSFA(f); %#ok<*DPABI>
            catch err
                errordlg(sprintf('无法启动 DPARSFA 界面：%s', err.message), '启动失败');
                return;
            end
            mrw.Dpabi.afterOpenPatch();
        end

        function launchDPARSFMain()
            mrw.Dpabi.ensurePath();
            if exist('mrw.NativeLaunch', 'class') == 8
                try
                    mrw.NativeLaunch.openDPARSFMain();
                    return;
                catch
                end
            end
            try
                DPARSF_main; %#ok<*DPABI>
            catch err
                errordlg(sprintf('无法启动 DPARSF 界面：%s', err.message), '启动失败');
            end
            mrw.Dpabi.afterOpenPatch();
        end

        function figs = findFigure(name)
            % 按图窗 Name/Tag 查找已打开的 DPABI 相关图窗
            figs = gobjects(0);
            try
                all = findall(0, 'Type', 'figure');
                for i = 1:numel(all)
                    nm = '';
                    tg = '';
                    try, nm = get(all(i), 'Name'); catch, end
                    try, tg = get(all(i), 'Tag'); catch, end
                    if contains(lower(nm), lower(name)) || contains(lower(tg), lower(name))
                        figs(end+1) = all(i); %#ok<AGROW>
                    end
                end
            catch
            end
        end
    end

    methods (Static, Access = private)
        function afterOpenPatch()
            % 若启用了原生界面汉化，则触发一次汉化（模块由 NativePatch 提供）
            try
                if mrw.Settings.get('NativePatch') && exist('mrw.NativePatch', 'class') == 8
                    mrw.NativePatch.patchAll();
                end
            catch
            end
        end

        function m = templateDescriptions()
            m = containers.Map('KeyType', 'char', 'ValueType', 'char');
            m('Blank') = '空白配置（全部关闭）';
            m('CalculateInMNISpace_TraditionalOrder') = '在 MNI 空间计算指标（传统顺序）';
            m('CalculateInMNISpace_Warp_DARTEL') = '在 MNI 空间计算指标（DARTEL 变形）';
            m('CalculateInMNISpace_Warp_UnifiedSegment') = '在 MNI 空间计算指标（统一分割变形）';
            m('CalculateInOriginalSpace_Warp_DARTEL') = '在个体空间计算指标（DARTEL 变形）';
            m('CalculateInOriginalSpace_Warp_UnifiedSegment') = '在个体空间计算指标（统一分割变形）';
            m('CalculateReHoDC') = 'ReHo / 度中心性计算';
            m('IntraoperativeProcessing') = '术中数据预处理';
            m('MonkeyProcessing') = '猕猴数据预处理';
            m('RatProcessing') = '大鼠数据预处理';
            m('TaskfMRIPreprocessing') = '任务态 fMRI 预处理';
            m('V4_CalculateInMNISpace_Warp_DARTEL') = 'V4 兼容：MNI 空间指标（DARTEL）';
            m('VBM_NewSegmentDARTEL') = 'VBM（New Segment + DARTEL）';
            m('VBM_UnifiedSegment') = 'VBM（统一分割）';
        end
    end
end
