classdef ScanEngine
    %SCANENGINE 数据目录自动扫描与索引引擎
    %
    %   扫描一个数据根目录，自动识别 DPARSF / BIDS / 通用 NIfTI / DICOM 数据布局，
    %   枚举受试者、功能像/结构像目录，并从 NIfTI 头或 BIDS JSON sidecar 中提取
    %   TR、时间点、层数、体素大小，最终给出可直接填入 DPARSFA 预处理配置
    %   （Cfg.WorkingDir / Cfg.StartingDirName / Cfg.FunctionalSessionNumber /
    %   Cfg.SubjectID / Cfg.TR / Cfg.TimePoints / Cfg.SliceTiming.SliceNumber）的
    %   索引结构。本模块替代原生 DPARSFA 中“一步一步手动指定工作目录”的流程。
    %
    %   用法：
    %       addpath('MRI_Workbench');
    %       idx = mrw.ScanEngine.scan('D:\Study\RestingState', opts);
    %
    %   opts（struct，可省略字段）：
    %       MaxDepth        最大扫描深度（默认 6，根目录深度为 0）
    %       ProgressFcn     进度回调 @(msg)，可为空
    %       IncludeDICOM    是否统计/识别 DICOM 数据（默认 true）
    %       IncludeBIDS     是否识别 BIDS 布局（默认 true）
    %       IncludeNIfTI    是否识别通用 NIfTI 布局（默认 true）
    %
    %   返回 idx 字段见 docs/CONTRACT.md 2.2：
    %       Root, Layout, LayoutName, Subjects, Detected, Warnings, Errors, Stats
    %   Detected 中除契约字段外还包含 Lead 追加的 IsBIDS（逻辑值，用于
    %   Cfg.IsBIDStoDPARSF），不删改已有字段。
    %
    %   受试者字段语义（2026-11 Lead 按 DPABI 源码更正）：
    %     - DPARSF 标准布局下 Subject.Dir = session1 功能像目录，
    %       如 <WorkingDir>/FunRaw/Sub01；FunDirs 为各 session 的受试者目录；
    %       AnatDir 为 <WorkingDir>/T1Raw/Sub01（无则 ''）。
    %     - BIDS / 通用 NIfTI / DICOM 布局下 Subject.Dir 为受试者目录。
    %
    %   识别规则要点：
    %     - DPARSF 支持两种目录习惯：
    %         (a) DPABI 标准（dirFirst，DPARSFA_run.m 实际使用，也是 Lead 确认的约定）：
    %                 <WorkingDir>/FunRaw/<subj>/…、<WorkingDir>/S2_FunRaw/<subj>/…、
    %                 <WorkingDir>/T1Raw/<subj>/…、<WorkingDir>/FunImgARW/<subj>/…
    %             WorkingDir = 模态目录（FunRaw 等）的父目录。
    %         (b) 受试者优先（subjectFirst，CONTRACT 2.2 原写法，作为兼容）：
    %                 <root>/<subj>/FunRaw/…、<root>/<subj>/S2_FunRaw/…、
    %                 <root>/<subj>/T1Raw/…
    %       两种都自动识别；多 session 前缀为 "S2_""S3_"…，已处理起始目录
    %       （FunImg*）按“session 数最多、其次名字最短”选择实际起始目录名。
    %       FunRaw 下直接是文件、没有受试者子目录时按单被试处理并给 warning。
    %     - 扫描根目录本身也可能就是一个 DPARSF 功能像目录（例如直接扫描
    %       <WorkingDir>\FunImgARB 查看中间结果或准备续跑）：此时按“根目录 =
    %       模态/阶段目录”解释，WorkingDir 取其上级目录、StartingDirName 取该
    %       目录名（去掉 S2_ 前缀），受试者取该目录下含图像文件的子目录，并
    %       从子目录的 NIfTI 头读取 TR/时间点/层数（续跑模式）。
    %     - BIDS：<WorkingDir>/BIDS/sub-*/[ses-*/]func/*_bold.nii*、
    %       anat/*_T1w.nii*；从同名 JSON sidecar 读取 RepetitionTime（秒），
    %       失败再用 NIfTI 头。扫描根本身就是 BIDS 数据集根时，WorkingDir 取其
    %       上级目录，根目录名不规范时给 warning。
    %     - 通用 NIfTI：目录中 4D .nii(.gz) 视为功能像；3D 且层数较多、体素不过大
    %       （或文件名含 T1/Anat/MPR）视为结构像；受试者目录取“含功能像的目录或其父目录”，
    %       Detected.WorkingDir 取包含各受试者的那一层，并提示整理成 FunRaw 结构。
    %     - DICOM：优先按 FunRaw 等命名；否则统计每目录 .dcm/.ima 数量，张数最多者
    %       视为功能像序列。用 spm_dicom_headers（在路径中时）或 dicominfo 抽样读取
    %       TR/层数/时间点，失败则置 NaN 并给出中文 warning（容错）。
    %     - 性能：不逐文件读头；大目录只保留抽样文件名并统计数量，抽样读头。
    %     - 支持中文路径、*.nii.gz、大小写不敏感扩展名。
    %
    %   本类不依赖 SPM / Image Processing Toolbox（DICOM 增强为可选），不联网。

    properties (Constant, Access = private)
        % 每个目录最多缓存的 NIfTI 文件名个数（超出后只计数，避免大目录占内存）
        MaxNameList = 400;
        % 每个 DICOM 目录抽样的最多文件数
        MaxDicomSample = 12;
        % 每个目录最多缓存的 JSON 文件名个数
        MaxJsonList = 40;
        % 每个 NIfTI 目录抽样读头的基准文件数
        SampleHeaderNum = 4;
        % 至少包含多少张 DICOM 才视为一个“序列”目录
        MinDicomSeriesFiles = 3;
        % 扫描时跳过的目录名（不区分大小写）
        SkipDirNames = {'$RECYCLE.BIN', 'System Volume Information', '__pycache__', ...
            'derivatives', 'sourcedata'};
    end

    methods (Static)
        function idx = scan(rootDir, opts)
            %SCAN 扫描数据根目录并返回索引结构
            %   idx = mrw.ScanEngine.scan(rootDir)
            %   idx = mrw.ScanEngine.scan(rootDir, opts)

            tStart = tic;
            idx = mrw.ScanEngine.emptyIndex();
            if nargin < 2 || isempty(opts)
                o = mrw.ScanEngine.normalizeOptions();
            else
                o = mrw.ScanEngine.normalizeOptions(opts);
            end
            ctx = mrw.ScanEngine.newContext(o);

            try
                % ---------- 入参校验 ----------
                if nargin < 1 || isempty(rootDir)
                    idx.Errors{end+1} = '未提供数据根目录。';
                    idx.Stats.Elapsed = toc(tStart);
                    return
                end
                if isstring(rootDir) && isscalar(rootDir)
                    rootDir = char(rootDir);
                end
                if ~ischar(rootDir) || isempty(rootDir)
                    idx.Errors{end+1} = '根目录参数必须是字符向量或标量字符串。';
                    idx.Stats.Elapsed = toc(tStart);
                    return
                end
                rootDir = mrw.ScanEngine.absolutePath(rootDir);
                idx.Root = rootDir;
                if exist(rootDir, 'dir') ~= 7
                    idx.Errors{end+1} = ['根目录不存在或不是文件夹：' rootDir];
                    idx.Stats.Elapsed = toc(tStart);
                    return
                end

                % ---------- 目录树扫描 ----------
                mrw.ScanEngine.report(o, '开始扫描数据目录…');
                tree = mrw.ScanEngine.collectTree(rootDir, o);
                ctx.Root = rootDir;
                ctx.Dirs = tree.Dirs;
                ctx.Map = tree.Map;
                ctx.Children = tree.Children;
                idx.Stats.DirsScanned = tree.DirsScanned;
                idx.Stats.FilesScanned = tree.FilesScanned;
                mrw.ScanEngine.report(o, sprintf('目录扫描完成：%d 个目录 / %d 个文件。', ...
                    tree.DirsScanned, tree.FilesScanned));

                % ---------- 布局识别 ----------
                dpPlan = mrw.ScanEngine.analyzeDPARSF(ctx);
                bidsPlan = mrw.ScanEngine.emptyBidsPlan();
                if o.IncludeBIDS
                    bidsPlan = mrw.ScanEngine.analyzeBIDS(ctx);
                end

                if dpPlan.Found
                    idx.Layout = 'DPARSF';
                    res = mrw.ScanEngine.buildDPARSF(ctx, dpPlan);
                elseif bidsPlan.Found
                    idx.Layout = 'BIDS';
                    res = mrw.ScanEngine.buildBIDS(ctx, bidsPlan);
                else
                    niiPlan = mrw.ScanEngine.analyzeNiftiPlan(ctx, o);
                    dcmPlan = mrw.ScanEngine.analyzeDicomPlan(ctx, o);
                    hasNii = o.IncludeNIfTI && niiPlan.Found;
                    hasDcm = o.IncludeDICOM && dcmPlan.Found;
                    if hasNii && hasDcm
                        idx.Layout = 'MIXED';
                    elseif hasNii
                        idx.Layout = 'NIFTI';
                    elseif hasDcm
                        idx.Layout = 'DICOM';
                    else
                        idx.Layout = 'UNKNOWN';
                    end
                    res = mrw.ScanEngine.buildGeneric(ctx, o, niiPlan, dcmPlan, idx.Layout);
                end
                idx.LayoutName = mrw.ScanEngine.layoutName(idx.Layout);
                if dpPlan.Found && strcmp(dpPlan.Variant, 'rootModal') && ...
                        strcmp(idx.Layout, 'DPARSF')
                    idx.LayoutName = mrw.ScanEngine.rootModalLayoutName(dpPlan.StartingDirName);
                end

                % ---------- 汇总 ----------
                subs = mrw.ScanEngine.sortSubjects(res.Subjects);
                idx.Subjects = subs;
                idx.Detected = mrw.ScanEngine.buildDetected(subs, res.WorkingDir, ...
                    res.StartingDirName, res.IsBIDS);

                warnings = [tree.Warnings, res.Warnings, mrw.ScanEngine.consistencyWarnings(subs)];
                if strcmp(idx.Layout, 'UNKNOWN')
                    if isempty(subs)
                        warnings{end+1} = '未能识别数据布局（DPARSF/BIDS/NIfTI/DICOM），请检查目录结构或扫描深度。';
                    end
                elseif isempty(subs)
                    warnings{end+1} = '已识别数据布局，但未在该目录中找到受试者数据。';
                end
                idx.Warnings = warnings;

                mrw.ScanEngine.report(o, sprintf('识别完成：布局 %s，共 %d 名受试者。', ...
                    idx.Layout, numel(subs)));
            catch err
                idx.Errors{end+1} = ['扫描过程发生异常：' err.message];
            end
            idx.Stats.Elapsed = toc(tStart);
        end
    end

    methods (Static, Access = private)
        % ==================================================================
        % 基础工具：参数、空结构、路径、排序
        % ==================================================================
        function o = normalizeOptions(opts)
            %NORMALIZEOPTIONS 合并默认参数，忽略未知字段与非法值
            o = struct('MaxDepth', 6, 'ProgressFcn', [], ...
                'IncludeDICOM', true, 'IncludeBIDS', true, 'IncludeNIfTI', true);
            if nargin < 1 || isempty(opts) || ~isstruct(opts)
                return
            end
            names = fieldnames(o);
            for k = 1:numel(names)
                nm = names{k};
                if ~isfield(opts, nm)
                    continue
                end
                v = opts.(nm);
                if strcmp(nm, 'MaxDepth')
                    if isnumeric(v) && isscalar(v) && isfinite(v) && v >= 0
                        o.MaxDepth = floor(double(v));
                    end
                elseif strcmp(nm, 'ProgressFcn')
                    if isempty(v) || isa(v, 'function_handle')
                        o.ProgressFcn = v;
                    end
                else
                    if (islogical(v) || isnumeric(v)) && isscalar(v)
                        o.(nm) = logical(v);
                    end
                end
            end
        end

        function ctx = newContext(o)
            %NEWCONTEXT 构造扫描上下文（含各类缓存，Map 为句柄对象可跨函数共享）
            ctx = struct();
            ctx.Opts = o;
            ctx.Root = '';
            ctx.Dirs = [];
            ctx.Map = containers.Map('KeyType', 'char', 'ValueType', 'double');
            ctx.Children = containers.Map('KeyType', 'char', 'ValueType', 'any');
            ctx.HeaderCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            ctx.DirClassCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            ctx.DicomCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function report(o, msg)
            %REPORT 调用进度回调（回调异常不影响扫描）
            if isempty(o.ProgressFcn)
                return
            end
            try
                o.ProgressFcn(msg);
            catch
                % 忽略进度回调内部错误
            end
        end

        function idx = emptyIndex()
            %EMPTYINDEX 构造字段齐全的空索引（字段顺序与契约一致）
            idx = struct();
            idx.Root = '';
            idx.Layout = 'UNKNOWN';
            idx.LayoutName = '未识别的数据目录';
            idx.Subjects = mrw.ScanEngine.emptySubjects();
            idx.Detected = mrw.ScanEngine.emptyDetected();
            idx.Warnings = {};
            idx.Errors = {};
            idx.Stats = struct('Elapsed', 0, 'DirsScanned', 0, 'FilesScanned', 0);
        end

        function s = emptySubjects()
            %EMPTYSUBJECTS 字段齐全的空受试者结构数组
            s = struct( ...
                'ID', {}, 'Dir', {}, 'FunDirs', {}, 'AnatDir', {}, ...
                'FunType', {}, 'AnatType', {}, ...
                'FunFileCount', {}, 'AnatFileCount', {}, ...
                'TimePoints', {}, 'TR', {}, 'SliceNumber', {}, 'VoxelSize', {}, ...
                'Sessions', {}, 'HasAnat', {}, 'Status', {}, 'Messages', {});
        end

        function d = emptyDetected()
            %EMPTYDETECTED 字段齐全的空 Detected 结构
            %   末尾的 IsBIDS 为 Lead 追加字段（不删改已有字段）。
            d = struct( ...
                'WorkingDir', '', ...
                'StartingDirName', 'FunRaw', ...
                'FunctionalSessionNumber', 1, ...
                'TR', NaN, ...
                'TimePoints', NaN, ...
                'SliceNumber', NaN, ...
                'SubjectIDs', {{}}, ...
                'IsBIDS', false);
        end

        function r = emptyDirRec()
            %EMPTYDIRREC 空目录记录（用于 struct 数组初始化）
            r = struct('Path', '', 'Name', '', 'Parent', '', 'Depth', 0, ...
                'SubDirs', {{}}, ...
                'Nii', {{}}, 'NiiCount', 0, ...
                'NiiGz', {{}}, 'NiiGzCount', 0, ...
                'Hdr', {{}}, 'HdrCount', 0, ...
                'DicomCount', 0, 'DicomSample', {{}}, ...
                'Json', {{}}, 'FileCount', 0);
        end

        function s = emptySpecs()
            %EMPTYSPECS 空受试者规格（analyze* -> build* 之间传递的中间结构）
            s = struct('ID', {}, 'Dir', {}, 'FunDirs', {}, 'AnatDir', {}, ...
                'Kind', {}, 'ExtraMessages', {});
        end

        function spec = makeSpec(id, dirPath, funDirs, anatDir, kind, extraMsgs)
            %MAKESPEC 构造一个受试者规格
            spec = struct();
            spec.ID = id;
            spec.Dir = dirPath;
            spec.FunDirs = funDirs;
            spec.AnatDir = anatDir;
            spec.Kind = kind;
            spec.ExtraMessages = extraMsgs;
        end

        function p = absolutePath(p)
            %ABSOLUTEPATH 相对路径补全为绝对路径，并统一分隔符
            if isstring(p)
                p = char(p);
            end
            if ispc
                p = strrep(p, '/', '\');
            end
            isAbs = false;
            if numel(p) >= 2
                isAbs = (p(2) == ':') || (p(1) == '\' && p(2) == '\') || (p(1) == '/');
            end
            if ~isAbs
                p = fullfile(pwd, p);
            end
            while numel(p) > 3 && (p(end) == filesep || p(end) == '/')
                p(end) = [];
            end
        end

        function tf = pathEquals(a, b)
            %PATHEQUALS 路径比较（Windows 下大小写不敏感）
            if ispc
                tf = strcmpi(a, b);
            else
                tf = strcmp(a, b);
            end
        end

        function key = cacheKey(p)
            %CACHEKEY 缓存键（Windows 下转小写，避免大小写差异）
            if ispc
                key = lower(p);
            else
                key = p;
            end
        end

        function n = baseName(p)
            %BASENAME 取路径最后一段目录名
            [~, n] = fileparts(p);
            if isempty(n)
                n = p;
            end
        end

        function tf = endsWithName(lowName, suffix)
            %ENDSWITHNAME 大小写不敏感的后缀判断（入参已转小写）
            tf = numel(lowName) >= numel(suffix) && ...
                strcmp(lowName(end - numel(suffix) + 1:end), suffix);
        end

        function c = sortNatural(c)
            %SORTNATURAL 对 cellstr 做“自然排序”（S2 排在 S10 之前）
            if numel(c) < 2
                return
            end
            keys = cell(size(c));
            for k = 1:numel(c)
                keys{k} = mrw.ScanEngine.naturalKey(c{k});
            end
            [~, order] = sort(keys);
            c = c(order);
        end

        function k = naturalKey(s)
            %NATURALKEY 自然排序键：数字段补零，文本段转小写
            parts = regexp(char(s), '(\d+)|(\D+)', 'tokens');
            k = '';
            for i = 1:numel(parts)
                tok = parts{i}{1};
                if ~isempty(regexp(tok, '^\d+$', 'once'))
                    k = [k, sprintf('%012.0f', str2double(tok))]; %#ok<AGROW>
                else
                    k = [k, lower(tok)]; %#ok<AGROW>
                end
            end
        end

        function subs = sortSubjects(subs)
            %SORTSUBJECTS 按受试者 ID 自然排序
            if numel(subs) < 2
                return
            end
            ids = {subs.ID};
            keys = cell(size(ids));
            for k = 1:numel(ids)
                keys{k} = mrw.ScanEngine.naturalKey(ids{k});
            end
            [~, order] = sort(keys);
            subs = subs(order);
        end

        function v = modeOfValues(values)
            %MODEOFVALUES 取出现次数最多的有限数值；并列时取最先出现者；无则 NaN
            v = NaN;
            vals = double(values(:));
            vals = vals(isfinite(vals));
            if isempty(vals)
                return
            end
            [uniq, ~] = unique(vals, 'stable');
            counts = zeros(size(uniq));
            for k = 1:numel(uniq)
                counts(k) = sum(vals == uniq(k));
            end
            [~, best] = max(counts);
            v = uniq(best);
        end

        function s = modeOfStrings(c)
            %MODEOFSTRINGS 取出现次数最多的字符串；并列取最先出现者
            s = '';
            if isempty(c)
                return
            end
            vals = cell(1, numel(c));
            counts = zeros(1, numel(c));
            nValid = 0;
            for i = 1:numel(c)
                j = find(strcmpi(vals(1:nValid), c{i}), 1);
                if isempty(j)
                    nValid = nValid + 1;
                    vals{nValid} = c{i};
                    counts(nValid) = 1;
                else
                    counts(j) = counts(j) + 1;
                end
            end
            [~, m] = max(counts(1:nValid));
            s = vals{m};
        end

        function msgs = addUniqueMsg(msgs, msg)
            %ADDUNIQUEMSG 追加不重复的中文提示
            if ~any(strcmp(msgs, msg))
                msgs{end+1} = msg;
            end
        end

        % ==================================================================
        % 目录树扫描
        % ==================================================================
        function tree = collectTree(rootDir, o)
            %COLLECTTREE 广度优先扫描目录树，统计每个目录的文件构成
            %   只统计文件名与数量；NIfTI 文件名最多缓存 MaxNameList 个，
            %   DICOM 只缓存 MaxDicomSample 个抽样名，避免大目录占用内存。
            tree = struct();
            tree.Warnings = {};
            tree.Dirs = mrw.ScanEngine.emptyDirRec();
            tree.Map = containers.Map('KeyType', 'char', 'ValueType', 'double');
            tree.Children = containers.Map('KeyType', 'char', 'ValueType', 'any');
            tree.DirsScanned = 0;
            tree.FilesScanned = 0;

            stackPaths = {rootDir};
            stackDepths = 0;
            nVisited = 0;

            while ~isempty(stackPaths)
                p = stackPaths{end};
                d = stackDepths(end);
                stackPaths(end) = [];
                stackDepths(end) = [];

                rec = mrw.ScanEngine.scanOneDir(p, d);
                nVisited = nVisited + 1;

                tree.Dirs(end+1) = rec;
                k = numel(tree.Dirs);
                tree.Map(mrw.ScanEngine.cacheKey(p)) = k;
                tree.FilesScanned = tree.FilesScanned + rec.FileCount;

                % 子目录入栈
                if d < o.MaxDepth
                    for s = 1:numel(rec.SubDirs)
                        stackPaths{end+1} = fullfile(p, rec.SubDirs{s}); %#ok<AGROW>
                        stackDepths(end+1) = d + 1; %#ok<AGROW>
                    end
                end

                if mod(nVisited, 20) == 0
                    mrw.ScanEngine.report(o, sprintf('正在扫描目录…（已扫描 %d 个）', nVisited));
                end
            end

            tree.DirsScanned = nVisited;

            % 建立 父目录 -> 子目录索引 的映射（供子目录枚举使用）
            for k = 1:numel(tree.Dirs)
                pk = mrw.ScanEngine.cacheKey(tree.Dirs(k).Parent);
                if isKey(tree.Children, pk)
                    tree.Children(pk) = [tree.Children(pk), k];
                else
                    tree.Children(pk) = k;
                end
            end
        end

        function rec = scanOneDir(p, depth)
            %SCANONEDIR 读取单个目录的条目并统计文件类型
            rec = mrw.ScanEngine.emptyDirRec();
            rec.Path = p;
            rec.Name = mrw.ScanEngine.baseName(p);
            rec.Parent = fileparts(p);
            rec.Depth = depth;
            try
                e = dir(p);
            catch
                e = [];
            end
            if isempty(e)
                return
            end
            subDirs = {};
            for k = 1:numel(e)
                nm = e(k).name;
                if strcmp(nm, '.') || strcmp(nm, '..')
                    continue
                end
                if e(k).isdir
                    if nm(1) ~= '.' && ~any(strcmpi(nm, mrw.ScanEngine.SkipDirNames))
                        subDirs{end+1} = nm; %#ok<AGROW>
                    end
                    continue
                end
                % 隐藏文件不计入
                if nm(1) == '.'
                    continue
                end
                rec.FileCount = rec.FileCount + 1;
                low = lower(nm);
                if mrw.ScanEngine.endsWithName(low, '.nii.gz')
                    rec.NiiGzCount = rec.NiiGzCount + 1;
                    if numel(rec.NiiGz) < mrw.ScanEngine.MaxNameList
                        rec.NiiGz{end+1} = nm;
                    end
                elseif mrw.ScanEngine.endsWithName(low, '.nii')
                    rec.NiiCount = rec.NiiCount + 1;
                    if numel(rec.Nii) < mrw.ScanEngine.MaxNameList
                        rec.Nii{end+1} = nm;
                    end
                elseif mrw.ScanEngine.endsWithName(low, '.hdr')
                    rec.HdrCount = rec.HdrCount + 1;
                    if numel(rec.Hdr) < mrw.ScanEngine.MaxNameList
                        rec.Hdr{end+1} = nm;
                    end
                elseif mrw.ScanEngine.endsWithName(low, '.dcm') || ...
                        mrw.ScanEngine.endsWithName(low, '.ima') || ...
                        mrw.ScanEngine.endsWithName(low, '.dicom')
                    rec.DicomCount = rec.DicomCount + 1;
                    if numel(rec.DicomSample) < mrw.ScanEngine.MaxDicomSample
                        rec.DicomSample{end+1} = nm;
                    end
                elseif mrw.ScanEngine.endsWithName(low, '.json')
                    if numel(rec.Json) < mrw.ScanEngine.MaxJsonList
                        rec.Json{end+1} = nm;
                    end
                end
            end
            rec.SubDirs = subDirs;
        end

        function idx = findRec(ctx, p)
            %FINDREC 按路径查找目录记录索引（找不到返回 0）
            idx = 0;
            key = mrw.ScanEngine.cacheKey(p);
            if isKey(ctx.Map, key)
                idx = ctx.Map(key);
            end
        end

        function tf = isDirRec(ctx, p)
            %ISDIRREC 路径是否对应扫描到的目录记录
            tf = mrw.ScanEngine.findRec(ctx, p) > 0;
        end

        function recIdxs = childRecs(ctx, parentPath)
            %CHILDRECS 返回某目录的直接子目录记录索引
            recIdxs = [];
            key = mrw.ScanEngine.cacheKey(parentPath);
            if isKey(ctx.Children, key)
                recIdxs = ctx.Children(key);
            end
        end

        % ==================================================================
        % NIfTI 头抽样与目录分类
        % ==================================================================
        function names = niftiNames(rec)
            %NIFTINAMES 目录内 NIfTI 文件名（.nii/.nii.gz/.hdr）；列表被截断时重新列目录
            names = [rec.Nii, rec.NiiGz, rec.Hdr];
            truncated = numel(rec.Nii) < rec.NiiCount || ...
                numel(rec.NiiGz) < rec.NiiGzCount || numel(rec.Hdr) < rec.HdrCount;
            if truncated
                allNames = mrw.ScanEngine.listFileNames(rec.Path);
                keep = false(size(allNames));
                for k = 1:numel(allNames)
                    low = lower(allNames{k});
                    keep(k) = mrw.ScanEngine.endsWithName(low, '.nii') || ...
                        mrw.ScanEngine.endsWithName(low, '.nii.gz') || ...
                        mrw.ScanEngine.endsWithName(low, '.hdr');
                end
                names = allNames(keep);
            end
        end

        function names = listFileNames(dirPath)
            %LISTFILENAMES 列出目录内所有文件名（不含子目录）
            names = {};
            try
                d = dir(dirPath);
            catch
                return
            end
            if isempty(d)
                return
            end
            names = {d(~[d.isdir]).name};
        end

        function names = matchingNiftiNames(rec, pattern)
            %MATCHINGNIFTINAMES 目录内名字匹配正则的 NIfTI 文件（大小写不敏感）
            allNames = mrw.ScanEngine.niftiNames(rec);
            if isempty(allNames)
                names = {};
                return
            end
            keep = false(size(allNames));
            for k = 1:numel(allNames)
                keep(k) = ~isempty(regexp(allNames{k}, pattern, 'once', 'ignorecase'));
            end
            names = allNames(keep);
        end

        function idx = spreadIndices(n, k)
            %SPREADINDICES 从 1..n 中均匀抽取至多 k 个下标（含首尾）
            idx = [];
            if n <= 0 || k <= 0
                return
            end
            if n <= k
                idx = 1:n;
                return
            end
            idx = unique(round(linspace(1, n, k)));
        end

        function info = readHeaderCached(ctx, filePath)
            %READHEADERCACHED 带缓存的 NIfTI 头读取
            key = mrw.ScanEngine.cacheKey(filePath);
            if isKey(ctx.HeaderCache, key)
                info = ctx.HeaderCache(key);
                return
            end
            info = mrw.NiftiHeader.read(filePath);
            ctx.HeaderCache(key) = info;
        end

        function cls = classOfDir(ctx, rec)
            %CLASSOFDIR 目录的 NIfTI 分类结果（带缓存）
            key = mrw.ScanEngine.cacheKey(rec.Path);
            if isKey(ctx.DirClassCache, key)
                cls = ctx.DirClassCache(key);
                return
            end
            cls = mrw.ScanEngine.classifyNiftiDir(ctx, rec);
            ctx.DirClassCache(key) = cls;
        end

        function cls = classifyNiftiDir(ctx, rec)
            %CLASSIFYNIFTIDIR 抽样读头，判断目录内是否存在 4D 功能像 / 3D 结构像
            %   返回字段：
            %     IsFunc      是否含 4D 功能像
            %     IsAnat      是否含 3D T1 样结构像
            %     FuncInfo    代表性功能像头（首/时间点最多者）
            %     AnatInfo    代表性结构像头
            %     AnyInfo     第一个可读头
            %     SampleCount 成功读取的头数量
            %     ReadFail    读取失败的头数量
            cls = struct('IsFunc', false, 'IsAnat', false, ...
                'FuncInfo', [], 'AnatInfo', [], 'AnyInfo', [], ...
                'SampleCount', 0, 'ReadFail', 0);
            names = mrw.ScanEngine.niftiNames(rec);
            if isempty(names)
                return
            end
            % 抽样：优先抽文件名像结构像（T1/Anat）的，再均匀抽其它
            hint = false(size(names));
            for k = 1:numel(names)
                hint(k) = mrw.ScanEngine.nameLooksAnat(names{k});
            end
            hintIdx = find(hint);
            hintIdx = hintIdx(1:min(numel(hintIdx), mrw.ScanEngine.SampleHeaderNum));
            pick = hintIdx;
            need = mrw.ScanEngine.SampleHeaderNum * 2 - numel(pick);
            others = setdiff(1:numel(names), pick, 'stable');
            if need > 0 && ~isempty(others)
                sub = mrw.ScanEngine.spreadIndices(numel(others), need);
                pick = [pick, others(sub)];
            end
            pick = unique(pick);
            bestTP = 0;
            for k = 1:numel(pick)
                info = mrw.ScanEngine.readHeaderCached(ctx, ...
                    fullfile(rec.Path, names{pick(k)}));
                if ~info.ReadOK
                    cls.ReadFail = cls.ReadFail + 1;
                    continue
                end
                cls.SampleCount = cls.SampleCount + 1;
                if isempty(cls.AnyInfo)
                    cls.AnyInfo = info;
                end
                if isfinite(info.TimePoints) && info.TimePoints > 1
                    if info.TimePoints > bestTP
                        cls.FuncInfo = info;
                        bestTP = info.TimePoints;
                    end
                    cls.IsFunc = true;
                elseif isempty(cls.AnatInfo) && ...
                        (mrw.ScanEngine.isAnatLikeInfo(info) || mrw.ScanEngine.nameLooksAnat(names{pick(k)}))
                    if ~(isfinite(info.TimePoints) && info.TimePoints > 1)
                        cls.AnatInfo = info;
                        cls.IsAnat = true;
                    end
                end
            end
        end

        function tf = isAnatLikeInfo(info)
            %ISANATLIKEINFO 头信息是否像 3D T1 结构像
            tf = false;
            if ~info.ReadOK
                return
            end
            if isfinite(info.TimePoints) && info.TimePoints > 1
                return
            end
            if ~isfinite(info.SliceNumber) || info.SliceNumber < 16
                return
            end
            if all(isfinite(info.VoxSize)) && max(info.VoxSize) > 4
                return
            end
            tf = true;
        end

        function tf = nameLooksAnat(fileName)
            %NAMELOOKSANAT 文件名是否含结构像提示词
            tf = ~isempty(regexp(fileName, ...
                '(^|[_\-\s\.])(t1|t1w|anat|mprage|spgr|mpr|结构|解剖)', 'once', 'ignorecase'));
        end

        % ==================================================================
        % DICOM 抽样解析
        % ==================================================================
        function probe = probeDicom(ctx, rec)
            %PROBEDICOM 抽样解析 DICOM 目录的 TR / 层数 / 时间点 / 体素
            %   优先用 spm_dicom_headers（SPM 在路径中时），否则尝试 dicominfo；
            %   全部失败时返回 OK=false + 中文提示，调用方据此置 NaN（容错）。
            key = mrw.ScanEngine.cacheKey(rec.Path);
            if isKey(ctx.DicomCache, key)
                probe = ctx.DicomCache(key);
                return
            end
            probe = struct('OK', false, 'TR', NaN, 'SliceNumber', NaN, ...
                'TimePoints', NaN, 'VoxelSize', nan(1, 3), 'Message', '');
            names = rec.DicomSample;
            if isempty(names)
                probe.Message = 'DICOM 目录中没有可抽样的文件。';
                ctx.DicomCache(key) = probe;
                return
            end
            files = cellfun(@(n) fullfile(rec.Path, n), names, 'UniformOutput', false);

            hdrCell = mrw.ScanEngine.readDicomHeaders(files);
            if isempty(hdrCell)
                probe.Message = '无法解析 DICOM 头（可能不是有效 DICOM 文件，或缺少 SPM/dicominfo），TR/层数/时间点已置为未知。';
                ctx.DicomCache(key) = probe;
                return
            end

            h = hdrCell{1};
            tr = NaN;
            slices = NaN;
            vox = nan(1, 3);
            if isfield(h, 'RepetitionTime') && isnumeric(h.RepetitionTime) && ...
                    isscalar(h.RepetitionTime) && isfinite(double(h.RepetitionTime)) && ...
                    double(h.RepetitionTime) > 0
                tr = double(h.RepetitionTime) / 1000; % DICOM 单位为毫秒
            end
            if isfield(h, 'ImagesInAcquisition') && isnumeric(h.ImagesInAcquisition) && ...
                    isscalar(h.ImagesInAcquisition) && isfinite(double(h.ImagesInAcquisition)) && ...
                    double(h.ImagesInAcquisition) > 0
                slices = double(h.ImagesInAcquisition);
            end
            if isfield(h, 'PixelSpacing') && isnumeric(h.PixelSpacing) && numel(h.PixelSpacing) >= 2
                vox(1) = double(h.PixelSpacing(2));
                vox(2) = double(h.PixelSpacing(1));
            end
            if isfield(h, 'SliceThickness') && isnumeric(h.SliceThickness) && ...
                    isscalar(h.SliceThickness) && isfinite(double(h.SliceThickness))
                vox(3) = double(h.SliceThickness);
            end

            % 时间点估计：总张数 / 每卷层数（能整除时）
            tp = NaN;
            if isfinite(slices) && slices >= 1 && rec.DicomCount > 0
                ratio = rec.DicomCount / slices;
                if abs(ratio - round(ratio)) < 1e-6 && round(ratio) >= 1
                    tp = round(ratio);
                end
            end

            probe.TR = tr;
            probe.SliceNumber = slices;
            probe.TimePoints = tp;
            probe.VoxelSize = vox;
            probe.OK = isfinite(tr) || isfinite(slices);
            if ~probe.OK
                probe.Message = 'DICOM 头中没有找到 TR/层数信息，TR/层数/时间点已置为未知。';
            end
            ctx.DicomCache(key) = probe;
        end

        function hdrCell = readDicomHeaders(files)
            %READDICOMHEADERS 用 SPM 或 Image Processing Toolbox 读取 DICOM 头
            %   返回 cell（每元素一个 struct），失败返回空 cell。
            hdrCell = {};
            ws = [];
            if exist('spm_dicom_headers', 'file') == 2
                try
                    ws = warning('off', 'all');
                    res = spm_dicom_headers(files);
                    if ~isempty(ws)
                        warning(ws);
                        ws = [];
                    end
                    hdrCell = mrw.ScanEngine.normalizeDicomHeaders(res);
                catch
                    if ~isempty(ws)
                        try %#ok<*CTCH>
                            warning(ws);
                        catch
                        end
                    end
                    hdrCell = {};
                end
            end
            if isempty(hdrCell) && exist('dicominfo', 'file') == 2
                for k = 1:numel(files)
                    try
                        h = dicominfo(files{k}); %#ok<*DCOMI>
                        if isstruct(h) && ~isempty(h)
                            hdrCell{end+1} = h; %#ok<AGROW>
                        end
                    catch
                        % 单个文件解析失败不影响其它文件
                    end
                end
            end
        end

        function out = normalizeDicomHeaders(res)
            %NORMALIZEDICOMHEADERS 把 spm_dicom_headers 的返回值统一为 struct 的 cell
            out = {};
            if isempty(res)
                return
            end
            if isstruct(res)
                for k = 1:numel(res)
                    out{k} = res(k); %#ok<AGROW>
                end
            elseif iscell(res)
                for k = 1:numel(res)
                    h = res{k};
                    if isstruct(h) && ~isempty(h)
                        out{end+1} = h(1); %#ok<AGROW>
                    end
                end
            end
        end

        % ==================================================================
        % DPARSF 布局分析
        % ==================================================================
        function plan = emptyDpPlan()
            %EMPTYDPLAN 空 DPARSF 分析结果
            plan = struct('Found', false, 'Variant', '', ...
                'StartingDirName', 'FunRaw', ...
                'Subjects', mrw.ScanEngine.emptySpecs(), ...
                'Warnings', {{}}, 'WorkingDir', '');
        end

        function plan = analyzeDPARSF(ctx)
            %ANALYZEDPARSF 识别 DPARSF 目录结构（仅目录名分析，不读文件头）
            plan = mrw.ScanEngine.emptyDpPlan();
            plan.WorkingDir = ctx.Root;
            dirs = ctx.Dirs;
            if isempty(dirs)
                return
            end

            % ---------- 根目录本身就是 DPARSF 功能像目录 ----------
            % 例如把扫描根目录直接指向 <WorkingDir>\FunImgARB（查看中间结果 /
            % 只补步骤续跑时常见）：不能把它当成上级工作目录里的“嵌套功能像
            % 目录”，否则会把上级目录名误当受试者，且读不到 TR/时间点/层数。
            [rootIsFun, rootBase, rootSession] = ...
                mrw.ScanEngine.isFunctionalDirName(mrw.ScanEngine.baseName(ctx.Root));
            if rootIsFun
                parentOfRoot = fileparts(ctx.Root);
                childIdxs = mrw.ScanEngine.childRecs(ctx, ctx.Root);
                hasSubjectDirs = false;
                for c = childIdxs
                    nm = dirs(c).Name;
                    if mrw.ScanEngine.isFunctionalDirName(nm) || ...
                            mrw.ScanEngine.isAnatDirName(nm)
                        continue
                    end
                    if dirs(c).FileCount > 0 || dirs(c).NiiCount + dirs(c).NiiGzCount + ...
                            dirs(c).HdrCount + dirs(c).DicomCount > 0
                        hasSubjectDirs = true;
                        break
                    end
                end
                if hasSubjectDirs && ~isempty(parentOfRoot) && ...
                        exist(parentOfRoot, 'dir') == 7 && ...
                        ~mrw.ScanEngine.pathEquals(parentOfRoot, ctx.Root)
                    plan.Variant = 'rootModal';
                    plan.WorkingDir = parentOfRoot;
                    plan.StartingDirName = rootBase;
                    plan = mrw.ScanEngine.planRootModal(ctx, plan, rootBase, rootSession);
                    plan.Found = true;
                    return
                end
            end

            % 收集功能像/结构像目录
            funcEntries = struct('RecIndex', {}, 'Base', {}, 'Session', {});
            anatEntries = struct('RecIndex', {}, 'Base', {}, 'Session', {});
            for k = 1:numel(dirs)
                nm = dirs(k).Name;
                [isFun, fBase, fSess] = mrw.ScanEngine.isFunctionalDirName(nm);
                if isFun
                    funcEntries(end+1) = struct('RecIndex', k, 'Base', fBase, 'Session', fSess); %#ok<AGROW>
                    continue
                end
                [isAnat, aBase, aSess] = mrw.ScanEngine.isAnatDirName(nm);
                if isAnat
                    anatEntries(end+1) = struct('RecIndex', k, 'Base', aBase, 'Session', aSess); %#ok<AGROW>
                end
            end
            if isempty(funcEntries)
                return
            end

            % 判定目录习惯：dirFirst（DPABI 标准）还是 subjectFirst（受试者优先）
            isTop = false(1, numel(funcEntries));
            isNested = false(1, numel(funcEntries));
            for i = 1:numel(funcEntries)
                parent = dirs(funcEntries(i).RecIndex).Parent;
                if mrw.ScanEngine.pathEquals(parent, ctx.Root)
                    isTop(i) = true;
                else
                    isNested(i) = true;
                end
            end
            topHasSubjects = false;
            for i = find(isTop)
                if ~isempty(dirs(funcEntries(i).RecIndex).SubDirs)
                    topHasSubjects = true;
                    break
                end
            end

            if any(isTop) && topHasSubjects
                plan.Variant = 'dirFirst';
                plan = mrw.ScanEngine.planDirFirst(ctx, plan, funcEntries(isTop), anatEntries);
            elseif any(isNested)
                plan.Variant = 'subjectFirst';
                plan = mrw.ScanEngine.planSubjectFirst(ctx, plan, funcEntries(isNested));
            elseif any(isTop)
                % 根目录本身就是受试者目录：<root>/FunRaw/<files>
                plan.Variant = 'dirFirstSingle';
                plan = mrw.ScanEngine.planSingleSubject(ctx, plan, funcEntries(isTop), anatEntries);
            else
                return
            end
            % 只要识别到 DPARSF 目录结构就认为布局成立（即使受试者列表为空）
            plan.Found = true;
        end

        function [chosenBase, sessionMap] = chooseBaseFamily(entries)
            %CHOOSEBASEFAMILY 从功能像目录集合中选择起始目录（家族）
            %   规则：优先 FunRaw；否则 session 数最多；再并列时取名字最短者。
            %   sessionMap 为按 session 号升序排列的 struct 数组（Session, RecIndex）。
            chosenBase = 'FunRaw';
            sessionMap = struct('Session', {}, 'RecIndex', {});
            if isempty(entries)
                return
            end
            keys = {};
            groups = {};
            for i = 1:numel(entries)
                low = lower(entries(i).Base);
                g = find(strcmp(keys, low), 1);
                if isempty(g)
                    keys{end+1} = low; %#ok<AGROW>
                    groups{end+1} = i; %#ok<AGROW>
                else
                    groups{g}(end+1) = i; %#ok<AGROW>
                end
            end
            bestG = 0;
            bestScore = [];
            for g = 1:numel(groups)
                idxs = groups{g};
                nSess = numel(unique([entries(idxs).Session]));
                isRaw = strcmp(keys{g}, 'funraw');
                baseLen = numel(entries(idxs(1)).Base);
                score = [double(isRaw), nSess, -baseLen];
                if bestG == 0 || mrw.ScanEngine.scoreBetter(score, bestScore)
                    bestG = g;
                    bestScore = score;
                end
            end
            idxs = groups{bestG};
            chosenBase = entries(idxs(1)).Base;
            sessions = unique([entries(idxs).Session]);
            sessions = sort(sessions);
            for s = sessions
                for i = idxs
                    if entries(i).Session == s
                        sessionMap(end+1) = struct('Session', s, 'RecIndex', entries(i).RecIndex); %#ok<AGROW>
                        break
                    end
                end
            end
        end

        function tf = scoreBetter(a, b)
            %SCOREBETTER 分数向量按字典序比较（a 是否优于 b）
            tf = false;
            for k = 1:numel(a)
                if a(k) > b(k)
                    tf = true;
                    return
                elseif a(k) < b(k)
                    return
                end
            end
        end

        function plan = planDirFirst(ctx, plan, funcEntries, anatEntries)
            %PLANDIRFIRST 生成“目录名在前”布局（<root>/FunRaw/<subj>/）的受试者规格
            dirs = ctx.Dirs;
            [base, sessionMap] = mrw.ScanEngine.chooseBaseFamily(funcEntries);
            plan.StartingDirName = base;
            mrw.ScanEngine.report(ctx.Opts, sprintf( ...
                'DPARSF 布局：起始目录 "%s"，共 %d 个 session 目录。', base, numel(sessionMap)));

            % 受试者列表取自 session 号最小的功能像目录的子目录
            subjNames = dirs(sessionMap(1).RecIndex).SubDirs;
            if isempty(subjNames)
                plan.Warnings{end+1} = '功能像目录下没有找到受试者子目录。';
                return
            end
            % 根目录层的结构像目录（T1Raw / AnatRaw / T1Img）
            anatRootRecs = [];
            for i = 1:numel(anatEntries)
                if mrw.ScanEngine.pathEquals(dirs(anatEntries(i).RecIndex).Parent, ctx.Root)
                    anatRootRecs(end+1) = anatEntries(i).RecIndex; %#ok<AGROW>
                end
            end

            for n = 1:numel(subjNames)
                subjName = subjNames{n};
                funDirs = {};
                for s = 1:numel(sessionMap)
                    p = fullfile(dirs(sessionMap(s).RecIndex).Path, subjName);
                    if mrw.ScanEngine.isDirRec(ctx, p)
                        funDirs{end+1} = p; %#ok<AGROW>
                    end
                end
                if isempty(funDirs)
                    continue
                end
                extra = cell(1, 1);
                nExtra = 0;
                if numel(funDirs) < numel(sessionMap)
                    nExtra = nExtra + 1;
                    extra{nExtra} = sprintf('该受试者缺少部分 session 目录（期望 %d 个，实际 %d 个）。', ...
                        numel(sessionMap), numel(funDirs));
                end
                extra = extra(1:nExtra);
                anatCands = {};
                for a = 1:numel(anatRootRecs)
                    p = fullfile(dirs(anatRootRecs(a)).Path, subjName);
                    if mrw.ScanEngine.isDirRec(ctx, p)
                        anatCands{end+1} = p; %#ok<AGROW>
                    end
                end
                anatDir = mrw.ScanEngine.pickPreferredAnat(anatCands);
                % Subject.Dir 语义（Lead 2026-11 更正）：取 session1 功能像目录
                plan.Subjects(end+1) = mrw.ScanEngine.makeSpec(subjName, funDirs{1}, ...
                    funDirs, anatDir, 'DPARSF', extra);
            end

            % 多个起始目录家族时的提示
            bases = unique(lower({funcEntries.Base}));
            if numel(bases) > 1
                plan.Warnings{end+1} = sprintf(['检测到多个功能像起始目录（%s），' ...
                    '已按规则选择 "%s" 作为 StartingDirName。'], ...
                    strjoin(unique({funcEntries.Base}), '/' ), base);
            end
        end

        function plan = planSubjectFirst(ctx, plan, funcEntries)
            %PLANSUBJECTFIRST 生成“受试者在前”布局（<root>/<subj>/FunRaw/）的受试者规格
            dirs = ctx.Dirs;
            parents = {};
            for i = 1:numel(funcEntries)
                parent = dirs(funcEntries(i).RecIndex).Parent;
                if ~any(strcmpi(parents, parent))
                    parents{end+1} = parent; %#ok<AGROW>
                end
            end
            parents = mrw.ScanEngine.sortNatural(parents);
            bases = {};
            for p = 1:numel(parents)
                subjDir = parents{p};
                idxs = [];
                for i = 1:numel(funcEntries)
                    if mrw.ScanEngine.pathEquals(dirs(funcEntries(i).RecIndex).Parent, subjDir)
                        idxs(end+1) = i; %#ok<AGROW>
                    end
                end
                entries = funcEntries(idxs);
                [base, sessionMap] = mrw.ScanEngine.chooseBaseFamily(entries);
                bases{end+1} = base; %#ok<AGROW>
                funDirs = {};
                for s = 1:numel(sessionMap)
                    funDirs{end+1} = dirs(sessionMap(s).RecIndex).Path; %#ok<AGROW>
                end
                % 结构像目录：受试者目录直接子目录中的 T1Raw/T1Img/AnatRaw
                anatCands = {};
                childIdxs = mrw.ScanEngine.childRecs(ctx, subjDir);
                for c = childIdxs
                    [isAnat, ~, ~] = mrw.ScanEngine.isAnatDirName(dirs(c).Name);
                    if isAnat
                        anatCands{end+1} = dirs(c).Path; %#ok<AGROW>
                    end
                end
                % 兼容嵌套：如果结构像目录位于受试者目录外面（极少见），不再检索
                anatDir = mrw.ScanEngine.pickPreferredAnat(anatCands);
                id = mrw.ScanEngine.baseName(subjDir);
                % Subject.Dir 语义（Lead 2026-11 更正）：取 session1 功能像目录
                plan.Subjects(end+1) = mrw.ScanEngine.makeSpec(id, funDirs{1}, ...
                    funDirs, anatDir, 'DPARSF', {});
            end
            plan.StartingDirName = mrw.ScanEngine.modeOfStrings(bases);
            if isempty(plan.StartingDirName)
                plan.StartingDirName = 'FunRaw';
            end
            if numel(unique(lower(bases))) > 1
                plan.Warnings{end+1} = sprintf(['各受试者使用的功能像起始目录不一致（%s），' ...
                    'Detected.StartingDirName 取多数值 "%s"。'], ...
                    strjoin(unique(bases), '/'), plan.StartingDirName);
            end
        end

        function plan = planSingleSubject(ctx, plan, funcEntries, anatEntries)
            %PLANSINGLESUBJECT 根目录本身是受试者目录（<root>/FunRaw/）时的规格
            dirs = ctx.Dirs;
            [base, sessionMap] = mrw.ScanEngine.chooseBaseFamily(funcEntries);
            plan.StartingDirName = base;
            funDirs = {};
            for s = 1:numel(sessionMap)
                funDirs{end+1} = dirs(sessionMap(s).RecIndex).Path; %#ok<AGROW>
            end
            anatCands = {};
            for i = 1:numel(anatEntries)
                if mrw.ScanEngine.pathEquals(dirs(anatEntries(i).RecIndex).Parent, ctx.Root)
                    anatCands{end+1} = dirs(anatEntries(i).RecIndex).Path; %#ok<AGROW>
                end
            end
            anatDir = mrw.ScanEngine.pickPreferredAnat(anatCands);
            id = mrw.ScanEngine.baseName(ctx.Root);
            extra = {['检测到 <根目录>/FunRaw 下直接是文件、没有受试者子目录：' ...
                '已按“根目录是单个受试者目录”处理，SubjectID 取根目录名，' ...
                'Detected.WorkingDir 取其上级目录；若根目录本身就是 WorkingDir，请手动修正。']};
            plan.Subjects(end+1) = mrw.ScanEngine.makeSpec(id, funDirs{1}, funDirs, ...
                anatDir, 'DPARSF', extra);
            parent = fileparts(ctx.Root);
            if ~isempty(parent) && exist(parent, 'dir') == 7
                plan.WorkingDir = parent;
                plan.Warnings{end+1} = ['数据根目录就是受试者目录，已把 WorkingDir 自动设为上级目录：' parent];
            else
                plan.Warnings{end+1} = '数据根目录就是受试者目录，但无法推断上级 WorkingDir，请手动设置。';
            end
        end

        function plan = planRootModal(ctx, plan, rootBase, rootSession)
            %PLANROOTMODAL 扫描根目录本身就是 DPARSF 功能像目录时的规格
            %   WorkingDir = 根目录上级；StartingDirName = 根目录名（Base）；
            %   受试者 = 根目录下含图像文件的子目录；结构像尝试同级的
            %   T1Raw/T1Img/AnatRaw/<受试者>（上级工作目录内）。
            dirs = ctx.Dirs;
            rootPath = ctx.Root;
            childIdxs = mrw.ScanEngine.childRecs(ctx, rootPath);

            % 上级工作目录里与根目录同级的结构像目录（T1Raw / T1Img / AnatRaw）
            anatNames = {};
            try
                parentEntries = dir(plan.WorkingDir);
            catch
                parentEntries = [];
            end
            for k = 1:numel(parentEntries)
                nm = parentEntries(k).name;
                if parentEntries(k).isdir && ~any(strcmp(nm, {'.', '..'}))
                    [isAnat, ~, ~] = mrw.ScanEngine.isAnatDirName(nm);
                    if isAnat
                        anatNames{end+1} = nm; %#ok<AGROW>
                    end
                end
            end

            nSubj = 0;
            for c = childIdxs
                nm = dirs(c).Name;
                if mrw.ScanEngine.isFunctionalDirName(nm) || ...
                        mrw.ScanEngine.isAnatDirName(nm)
                    continue
                end
                hasFiles = dirs(c).NiiCount + dirs(c).NiiGzCount + ...
                    dirs(c).HdrCount + dirs(c).DicomCount > 0;
                if ~hasFiles
                    continue
                end
                anatCands = {};
                for a = 1:numel(anatNames)
                    p = fullfile(plan.WorkingDir, anatNames{a}, nm);
                    if exist(p, 'dir') == 7
                        anatCands{end+1} = p; %#ok<AGROW>
                    end
                end
                anatDir = mrw.ScanEngine.pickPreferredAnat(anatCands);
                plan.Subjects(end+1) = mrw.ScanEngine.makeSpec(nm, dirs(c).Path, ...
                    {dirs(c).Path}, anatDir, 'DPARSF', {});
                nSubj = nSubj + 1;
            end

            if nSubj == 0
                plan.Warnings{end+1} = sprintf( ...
                    '根目录 "%s" 是 DPARSF 功能像目录，但其中没有找到受试者数据。', rootBase);
            end
            isProcessed = ~isempty(regexp(rootBase, '^FunImg', 'once', 'ignorecase'));
            if isProcessed
                plan.Warnings{end+1} = sprintf(['扫描根目录本身就是已处理的 DPARSF 功能像阶段目录 "%s"：' ...
                    '已按“查看中间结果 / 只补步骤续跑”解释，WorkingDir 自动取其上级目录 "%s"，' ...
                    'StartingDirName=%s。'], rootBase, plan.WorkingDir, rootBase);
            else
                plan.Warnings{end+1} = sprintf(['扫描根目录本身就是 DPARSF 功能像目录 "%s"：' ...
                    'WorkingDir 自动取其上级目录 "%s"，StartingDirName=%s。'], ...
                    rootBase, plan.WorkingDir, rootBase);
            end
            if rootSession > 1
                plan.Warnings{end+1} = sprintf(['根目录是 session %d 专属目录（%s）：' ...
                    '如要续跑多 session 数据，建议改扫描完整工作目录 "%s"。'], ...
                    rootSession, mrw.ScanEngine.baseName(rootPath), plan.WorkingDir);
            end
        end

        function p = pickPreferredAnat(cands)
            %PICKPREFERREDANAT 按 T1Raw > T1Img > AnatRaw 的顺序选择结构像目录
            p = '';
            if isempty(cands)
                return
            end
            pref = {'t1raw', 't1img', 'anatraw'};
            for i = 1:numel(pref)
                for k = 1:numel(cands)
                    [~, nm] = fileparts(cands{k});
                    low = lower(nm);
                    if strcmp(low, pref{i}) || strncmp(low, pref{i}, numel(pref{i}))
                        p = cands{k};
                        return
                    end
                end
            end
            p = cands{1};
        end

        function [tf, base, session] = isFunctionalDirName(name)
            %ISFUNCTIONALDIRNAME 目录名是否 DPARSF 功能像起始目录
            %   FunRaw、FunImg、FunImgARW… ；可带 session 前缀 S2_/S3_…
            %   同时返回去掉前缀的 base 与 session 号。
            session = mrw.ScanEngine.sessionNumberOf(name);
            base = mrw.ScanEngine.stripSessionPrefix(name);
            tf = ~isempty(regexp(base, '^FunRaw$', 'once', 'ignorecase')) || ...
                ~isempty(regexp(base, '^FunImg[A-Za-z0-9]*$', 'once', 'ignorecase'));
        end

        function [tf, base, session] = isAnatDirName(name)
            %ISANATDIRNAME 目录名是否 DPARSF 结构像目录
            %   T1Raw、T1Img、AnatRaw（可带 session 前缀），DPARSFA 实际只认 T1Raw，
            %   其它作为兼容别名。
            session = mrw.ScanEngine.sessionNumberOf(name);
            base = mrw.ScanEngine.stripSessionPrefix(name);
            tf = ~isempty(regexp(base, '^T1Raw$', 'once', 'ignorecase')) || ...
                ~isempty(regexp(base, '^T1Img[A-Za-z0-9]*$', 'once', 'ignorecase')) || ...
                ~isempty(regexp(base, '^AnatRaw[A-Za-z0-9]*$', 'once', 'ignorecase'));
        end

        function n = sessionNumberOf(name)
            %SESSIONNUMBEROF 从 "S2_" 前缀提取 session 号（无前缀为 1）
            n = 1;
            tok = regexp(name, '^S(\d+)_', 'tokens', 'once', 'ignorecase');
            if ~isempty(tok)
                v = str2double(tok{1});
                if isfinite(v) && v >= 1
                    n = v;
                end
            end
        end

        function base = stripSessionPrefix(name)
            %STRIPSESSIONPREFIX 去掉 "S2_/" 这类 session 前缀
            base = name;
            tok = regexp(name, '^S\d+_(.+)$', 'tokens', 'once', 'ignorecase');
            if ~isempty(tok)
                base = tok{1};
            end
        end

        % ==================================================================
        % BIDS 布局分析
        % ==================================================================
        function plan = emptyBidsPlan()
            %EMPTYBIDSPLAN 空 BIDS 分析结果
            plan = struct('Found', false, 'Subjects', mrw.ScanEngine.emptySpecs(), ...
                'Warnings', {{}}, 'WorkingDir', '');
        end

        function plan = analyzeBIDS(ctx)
            %ANALYZEBIDS 识别 BIDS 布局（仅目录与文件名分析，不读文件头）
            %   DPARSFA 的 BIDS 约定：<WorkingDir>/BIDS/sub-*/[ses-*/]func|anat/…
            %   另外兼容“扫描根本身就是 BIDS 数据集根”（含 sub-* 目录）的情况：
            %   此时 WorkingDir 取扫描根的上级目录，并在根目录名不是 BIDS 时给 warning。
            plan = mrw.ScanEngine.emptyBidsPlan();
            plan.WorkingDir = ctx.Root;
            dirs = ctx.Dirs;

            % ---- 1) 找名为 BIDS 的数据集根（深度 1~2，且子目录含 sub-*）----
            bidsRoot = '';
            cand = [];
            for k = 1:numel(dirs)
                if dirs(k).Depth < 1 || dirs(k).Depth > 2
                    continue
                end
                if ~strcmpi(dirs(k).Name, 'BIDS')
                    continue
                end
                if mrw.ScanEngine.hasSubjSubdir(ctx, k)
                    cand(end+1) = k; %#ok<AGROW>
                end
            end
            if ~isempty(cand)
                depths = [dirs(cand).Depth];
                [~, ord] = sort(depths);
                bidsRootIdx = cand(ord(1));
                bidsRoot = dirs(bidsRootIdx).Path;
                plan.WorkingDir = dirs(bidsRootIdx).Parent;
            end

            % ---- 2) 否则看扫描根自身是否就是 BIDS 数据集根 ----
            if isempty(bidsRoot)
                rootIdx = mrw.ScanEngine.findRec(ctx, ctx.Root);
                if rootIdx > 0 && mrw.ScanEngine.hasSubjSubdir(ctx, rootIdx)
                    bidsRoot = ctx.Root;
                    parent = fileparts(ctx.Root);
                    if ~isempty(parent) && exist(parent, 'dir') == 7
                        plan.WorkingDir = parent;
                    else
                        plan.WorkingDir = ctx.Root;
                    end
                    if ~strcmpi(mrw.ScanEngine.baseName(ctx.Root), 'BIDS')
                        plan.Warnings{end+1} = ['检测到 BIDS 数据集根目录直接位于扫描根目录：' ...
                            'DPARSFA 需要 <WorkingDir>/BIDS 结构，已把 Detected.WorkingDir 设为上级目录；' ...
                            '建议把 BIDS 根目录命名为 BIDS，或手动设置 IsBIDStoDPARSF / WorkingDir。'];
                    end
                else
                    return
                end
            end

            % ---- 3) 枚举 bidsRoot 下的 sub-* 受试者 ----
            foundAny = false;
            subjIdxs = mrw.ScanEngine.childRecs(ctx, bidsRoot);
            for k = subjIdxs
                nm = dirs(k).Name;
                if isempty(regexp(nm, '^sub-[^\\/]+$', 'once', 'ignorecase'))
                    continue
                end
                spec = mrw.ScanEngine.analyzeBidsSubject(ctx, k);
                if ~isempty(spec.FunDirs)
                    foundAny = true;
                    plan.Subjects(end+1) = spec;
                elseif ~isempty(spec.AnatDir)
                    plan.Warnings{end+1} = sprintf('BIDS 受试者 %s 缺少 BOLD 功能像，已跳过。', spec.ID);
                end
            end
            plan.Found = foundAny;
        end

        function tf = hasSubjSubdir(ctx, recIdx)
            %HASSUBJSUBDIR 目录的直接子目录中是否存在 sub-* 受试者目录
            tf = false;
            dirs = ctx.Dirs;
            childIdxs = mrw.ScanEngine.childRecs(ctx, dirs(recIdx).Path);
            for c = childIdxs
                if ~isempty(regexp(dirs(c).Name, '^sub-[^\\/]+$', 'once', 'ignorecase'))
                    tf = true;
                    return
                end
            end
        end

        function spec = analyzeBidsSubject(ctx, subjRecIdx)
            %ANALYZEBIDSSUBJECT 分析单个 BIDS 受试者的 func/anat 目录
            dirs = ctx.Dirs;
            subjDir = dirs(subjRecIdx).Path;
            id = dirs(subjRecIdx).Name;
            funDirs = {};
            anatCands = {};

            % session 目录（无 ses-* 时把受试者目录本身当作唯一 session）
            sesIdxs = [];
            childIdxs = mrw.ScanEngine.childRecs(ctx, subjDir);
            for c = childIdxs
                if ~isempty(regexp(dirs(c).Name, '^ses-[^\\/]+$', 'once', 'ignorecase'))
                    sesIdxs(end+1) = c; %#ok<AGROW>
                end
            end
            if isempty(sesIdxs)
                sesBases = {subjDir};
            else
                sesBases = cell(1, numel(sesIdxs));
                sesKeys = cell(1, numel(sesIdxs));
                for s = 1:numel(sesIdxs)
                    sesBases{s} = dirs(sesIdxs(s)).Path;
                    sesKeys{s} = mrw.ScanEngine.naturalKey(dirs(sesIdxs(s)).Name);
                end
                [~, order] = sort(sesKeys);
                sesBases = sesBases(order);
            end

            for s = 1:numel(sesBases)
                base = sesBases{s};
                % func 子目录；没有 func 子目录时允许 BOLD 直接放在 session 目录下
                funcDir = mrw.ScanEngine.findBidsSubdir(ctx, base, 'func');
                if isempty(funcDir)
                    r0 = mrw.ScanEngine.findRec(ctx, base);
                    if r0 > 0 && ~isempty(mrw.ScanEngine.matchingNiftiNames(dirs(r0), ...
                            '_bold\.nii(\.gz)?$'))
                        funcDir = base;
                    end
                end
                if ~isempty(funcDir)
                    recIdx = mrw.ScanEngine.findRec(ctx, funcDir);
                    if recIdx > 0
                        boldNames = mrw.ScanEngine.matchingNiftiNames(dirs(recIdx), ...
                            '_bold\.nii(\.gz)?$');
                        if ~isempty(boldNames)
                            funDirs{end+1} = funcDir; %#ok<AGROW>
                        end
                    end
                end
                anatDir = mrw.ScanEngine.findBidsSubdir(ctx, base, 'anat');
                if ~isempty(anatDir)
                    aRec = mrw.ScanEngine.findRec(ctx, anatDir);
                    if aRec > 0
                        t1Names = mrw.ScanEngine.matchingNiftiNames(dirs(aRec), ...
                            '_T1w\.nii(\.gz)?$');
                        if ~isempty(t1Names)
                            anatCands{end+1} = anatDir; %#ok<AGROW>
                        end
                    end
                end
            end
            anatDir = '';
            if ~isempty(anatCands)
                anatDir = anatCands{1};
            end
            spec = mrw.ScanEngine.makeSpec(id, subjDir, funDirs, anatDir, 'BIDS', {});
        end

        function dirPath = findBidsSubdir(ctx, baseDir, kind)
            %FINDBIDSSUBDIR 在 BIDS session/受试者目录下查找 func 或 anat 子目录
            dirPath = '';
            dirs = ctx.Dirs;
            childIdxs = mrw.ScanEngine.childRecs(ctx, baseDir);
            for c = childIdxs
                if strcmpi(dirs(c).Name, kind)
                    dirPath = dirs(c).Path;
                    return
                end
            end
        end

        % ==================================================================
        % 通用 NIfTI / DICOM 布局分析
        % ==================================================================
        function plan = emptyNiiPlan()
            %EMPTYNIIPLAN 空通用 NIfTI 分析结果
            plan = struct('Found', false, 'FuncDirRecs', [], ...
                'AnatDirRecs', [], 'Warnings', {{}});
        end

        function plan = analyzeNiftiPlan(ctx, o)
            %ANALYZENIFTIPLAN 找出通用 NIfTI 布局中的功能像/结构像目录
            plan = mrw.ScanEngine.emptyNiiPlan();
            if ~o.IncludeNIfTI
                return
            end
            dirs = ctx.Dirs;
            funcRecs = [];
            anatRecs = [];
            sampleFail = 0;
            for k = 1:numel(dirs)
                if dirs(k).NiiCount + dirs(k).NiiGzCount + dirs(k).HdrCount == 0
                    continue
                end
                cls = mrw.ScanEngine.classOfDir(ctx, dirs(k));
                if cls.IsFunc
                    funcRecs(end+1) = k; %#ok<AGROW>
                end
                if cls.IsAnat
                    anatRecs(end+1) = k; %#ok<AGROW>
                end
                if cls.SampleCount == 0 && cls.ReadFail > 0
                    sampleFail = sampleFail + 1;
                end
            end
            plan.FuncDirRecs = funcRecs;
            plan.AnatDirRecs = anatRecs;
            plan.Found = ~isempty(funcRecs);
            if sampleFail > 0
                plan.Warnings{end+1} = sprintf('有 %d 个目录的 NIfTI 头全部读取失败，未计入功能像/结构像。', sampleFail);
            end
        end

        function plan = analyzeDicomPlan(ctx, o)
            %ANALYZEDICOMPLAN 找出 DICOM 序列目录
            plan = struct('Found', false, 'SeriesRecs', [], 'Warnings', {{}});
            if ~o.IncludeDICOM
                return
            end
            dirs = ctx.Dirs;
            seriesRecs = [];
            smallDirs = 0;
            for k = 1:numel(dirs)
                if dirs(k).DicomCount >= mrw.ScanEngine.MinDicomSeriesFiles
                    seriesRecs(end+1) = k; %#ok<AGROW>
                elseif dirs(k).DicomCount > 0
                    smallDirs = smallDirs + 1;
                end
            end
            plan.SeriesRecs = seriesRecs;
            plan.Found = ~isempty(seriesRecs);
            if plan.Found && smallDirs > 0
                plan.Warnings{end+1} = sprintf('有 %d 个目录含少量 DICOM 文件（<%d 张），未视为序列。', ...
                    smallDirs, mrw.ScanEngine.MinDicomSeriesFiles);
            end
        end

        % ==================================================================
        % 受试者组装（公共）
        % ==================================================================
        function subj = assembleSubject(spec, ctx, o)
            %ASSEMBLESUBJECT 由受试者规格计算完整 Subject 字段、状态与中文提示
            subj = mrw.ScanEngine.emptySubjects();
            % 0x0 结构数组不能直接点赋值，先创建第 1 个元素
            subj(1).ID = spec.ID;
            subj.Dir = spec.Dir;
            subj.FunDirs = spec.FunDirs;
            subj.AnatDir = spec.AnatDir;
            msgs = spec.ExtraMessages;
            tr = NaN;
            tp = NaN;
            sl = NaN;
            vox = nan(1, 3);

            if strcmp(spec.Kind, 'BIDS')
                % ---------- BIDS：只统计 BOLD / T1w ----------
                [funCount, firstDir, firstBold] = mrw.ScanEngine.bidsCountFun(ctx, spec.FunDirs);
                funType = '';
                if funCount > 0
                    funType = 'BIDS';
                end
                [anatCount, anatType] = mrw.ScanEngine.bidsCountAnat(ctx, spec.AnatDir);
                if funCount > 0
                    [tr, tp, sl, vox, metaMsgs] = mrw.ScanEngine.bidsMeta(ctx, firstDir, firstBold);
                    for m = 1:numel(metaMsgs)
                        msgs = mrw.ScanEngine.addUniqueMsg(msgs, metaMsgs{m});
                    end
                end
            else
                % ---------- DPARSF / 通用：按目录内文件统计 ----------
                [funCount, funType] = mrw.ScanEngine.countAndTypeDirs(ctx, o, spec.FunDirs);
                anatCount = 0;
                anatType = '';
                if ~isempty(spec.AnatDir)
                    [anatCount, anatType] = mrw.ScanEngine.countAnatInDir(ctx, o, spec.AnatDir);
                end
                if funCount > 0
                    fh = mrw.ScanEngine.pickFuncHeader(ctx, o, spec.FunDirs);
                    tr = fh.TR;
                    tp = fh.TimePoints;
                    sl = fh.SliceNumber;
                    vox = fh.VoxelSize;
                    for m = 1:numel(fh.Messages)
                        msgs = mrw.ScanEngine.addUniqueMsg(msgs, fh.Messages{m});
                    end
                end
            end

            % 自动检测的 TR 做一次四舍五入：NIfTI pixdim[4] 是 float32，常见
            % 2.0000014 这类浮点噪声；保留 4 位小数（0.1 ms）足够，并避免页面/
            % 配置里出现 2.0000014305114746 这样的长串。
            if isfinite(tr)
                tr = round(tr * 1e4) / 1e4;
            end
            subj.FunFileCount = funCount;
            subj.AnatFileCount = anatCount;
            subj.FunType = funType;
            subj.AnatType = anatType;
            subj.HasAnat = ~isempty(spec.AnatDir);
            subj.TimePoints = tp;
            subj.TR = tr;
            subj.SliceNumber = sl;
            subj.VoxelSize = vox;
            subj.Sessions = numel(spec.FunDirs);
            if subj.Sessions < 1
                subj.Sessions = 1;
            end

            % ---------- 状态与中文提示 ----------
            status = 'ok';
            if funCount <= 0
                status = 'error';
                msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                    '未找到功能像数据（请检查数据目录，或 IncludeNIfTI / IncludeDICOM 开关）。');
            else
                if ~subj.HasAnat
                    status = 'warn';
                    msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                        '缺少结构像（T1Raw/AnatRaw/T1w），无法完成结构像分割与配准。');
                end
                if ~isfinite(tr)
                    status = 'warn';
                    msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                        '无法确定 TR（重复时间），请在预处理配置中手动确认。');
                end
                if ~isfinite(tp)
                    status = 'warn';
                    msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                        '无法确定时间点（TimePoints），请在预处理配置中手动确认。');
                end
                if ~isfinite(sl)
                    status = 'warn';
                    msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                        '无法确定层数（SliceNumber），请在预处理配置中手动确认。');
                end
            end
            subj.Status = status;
            subj.Messages = msgs;
        end

        function [count, type] = countAndTypeDirs(ctx, o, dirPaths)
            %COUNTANDTYPEDIRS 统计目录集合中启用的图像文件数并合并文件类型
            count = 0;
            types = {};
            for i = 1:numel(dirPaths)
                recIdx = mrw.ScanEngine.findRec(ctx, dirPaths{i});
                if recIdx == 0
                    continue
                end
                rec = ctx.Dirs(recIdx);
                if o.IncludeNIfTI
                    count = count + rec.NiiCount + rec.NiiGzCount + rec.HdrCount;
                end
                if o.IncludeDICOM
                    count = count + rec.DicomCount;
                end
                t = mrw.ScanEngine.dirTypeOf(rec, o);
                if ~isempty(t)
                    types{end+1} = t; %#ok<AGROW>
                end
            end
            type = mrw.ScanEngine.combineTypes(types);
        end

        function t = dirTypeOf(rec, o)
            %DIRTYPEOF 目录的数据类型：'NIfTI' | 'DICOM' | 'MIXED' | ''
            hasN = o.IncludeNIfTI && (rec.NiiCount + rec.NiiGzCount + rec.HdrCount) > 0;
            hasD = o.IncludeDICOM && rec.DicomCount > 0;
            if hasN && hasD
                t = 'MIXED';
            elseif hasN
                t = 'NIfTI';
            elseif hasD
                t = 'DICOM';
            else
                t = '';
            end
        end

        function t = combineTypes(types)
            %COMBINETYPES 合并多个目录类型：全同取该类型，不同取 MIXED
            t = '';
            if isempty(types)
                return
            end
            uniq = unique(types);
            if isscalar(uniq)
                t = uniq{1};
            else
                t = 'MIXED';
            end
        end

        function [count, type] = countAnatInDir(ctx, o, anatDir)
            %COUNTANATINDIR 统计结构像目录中的结构像文件数（优先只数 T1 样文件）
            count = 0;
            type = '';
            recIdx = mrw.ScanEngine.findRec(ctx, anatDir);
            if recIdx == 0
                % 根目录=功能像目录（续跑模式）时，结构像可能位于扫描根目录之外
                % （上级工作目录的 T1Raw/T1Img）：按需现读该目录的文件构成。
                if exist(anatDir, 'dir') ~= 7
                    return
                end
                rec = mrw.ScanEngine.scanOneDir(anatDir, 0);
            else
                rec = ctx.Dirs(recIdx);
            end
            type = mrw.ScanEngine.dirTypeOf(rec, o);
            if o.IncludeDICOM && rec.DicomCount > 0 && ~o.IncludeNIfTI
                count = rec.DicomCount;
                return
            end
            if rec.NiiCount + rec.NiiGzCount + rec.HdrCount == 0
                if o.IncludeDICOM
                    count = rec.DicomCount;
                end
                return
            end
            names = mrw.ScanEngine.niftiNames(rec);
            hit = false(size(names));
            for k = 1:numel(names)
                hit(k) = mrw.ScanEngine.nameLooksAnat(names{k});
            end
            if any(hit)
                count = sum(hit);
            else
                count = rec.NiiCount + rec.NiiGzCount + rec.HdrCount;
            end
        end

        function info = pickFuncHeader(ctx, o, funDirs)
            %PICKFUNCHEADER 从功能像目录中提取 TR / 时间点 / 层数 / 体素
            %   先按 NIfTI 抽样读头；读不到再尝试 DICOM 头；都没有则 NaN。
            info = struct('TR', NaN, 'TimePoints', NaN, 'SliceNumber', NaN, ...
                'VoxelSize', nan(1, 3), 'Messages', {{}});
            % ---------- NIfTI ----------
            if o.IncludeNIfTI
                tried = 0;
                for i = 1:numel(funDirs)
                    recIdx = mrw.ScanEngine.findRec(ctx, funDirs{i});
                    if recIdx == 0
                        continue
                    end
                    rec = ctx.Dirs(recIdx);
                    if rec.NiiCount + rec.NiiGzCount + rec.HdrCount == 0
                        continue
                    end
                    tried = tried + 1;
                    cls = mrw.ScanEngine.classOfDir(ctx, rec);
                    if ~isempty(cls.FuncInfo)
                        info.TR = cls.FuncInfo.TR;
                        info.TimePoints = cls.FuncInfo.TimePoints;
                        info.SliceNumber = cls.FuncInfo.SliceNumber;
                        info.VoxelSize = cls.FuncInfo.VoxSize;
                        return
                    elseif ~isempty(cls.AnyInfo)
                        % 3D 序列：按“一卷一个文件”估算时间点
                        info.TR = cls.AnyInfo.TR;
                        info.SliceNumber = cls.AnyInfo.SliceNumber;
                        info.VoxelSize = cls.AnyInfo.VoxSize;
                        nImg = rec.NiiCount + rec.NiiGzCount + rec.HdrCount;
                        if nImg > 1
                            info.TimePoints = nImg;
                        else
                            info.TimePoints = cls.AnyInfo.TimePoints;
                        end
                        info.Messages{end+1} = '功能像为 3D 序列，时间点按文件数量估算。';
                        return
                    end
                    if cls.ReadFail > 0
                        info.Messages = mrw.ScanEngine.addUniqueMsg(info.Messages, ...
                            sprintf('目录 %s 的 NIfTI 头解析失败。', rec.Path));
                    end
                    if tried >= 3
                        break
                    end
                end
            end
            % ---------- DICOM ----------
            if o.IncludeDICOM
                for i = 1:numel(funDirs)
                    recIdx = mrw.ScanEngine.findRec(ctx, funDirs{i});
                    if recIdx == 0
                        continue
                    end
                    rec = ctx.Dirs(recIdx);
                    if rec.DicomCount == 0
                        continue
                    end
                    probe = mrw.ScanEngine.probeDicom(ctx, rec);
                    info.TR = probe.TR;
                    info.TimePoints = probe.TimePoints;
                    info.SliceNumber = probe.SliceNumber;
                    info.VoxelSize = probe.VoxelSize;
                    if ~isempty(probe.Message)
                        info.Messages = mrw.ScanEngine.addUniqueMsg(info.Messages, probe.Message);
                    end
                    return
                end
            end
        end

        function [count, firstDir, firstName] = bidsCountFun(ctx, funDirs)
            %BIDSCOUNTFUN 统计 BIDS BOLD 文件数，并返回第一个 BOLD 文件位置
            count = 0;
            firstDir = '';
            firstName = '';
            for i = 1:numel(funDirs)
                recIdx = mrw.ScanEngine.findRec(ctx, funDirs{i});
                if recIdx == 0
                    continue
                end
                names = mrw.ScanEngine.matchingNiftiNames(ctx.Dirs(recIdx), ...
                    '_bold\.nii(\.gz)?$');
                count = count + numel(names);
                if isempty(firstDir) && ~isempty(names)
                    names = mrw.ScanEngine.sortNatural(names);
                    firstDir = funDirs{i};
                    firstName = names{1};
                end
            end
        end

        function [count, type] = bidsCountAnat(ctx, anatDir)
            %BIDSCOUNTANAT 统计 BIDS T1w 文件数
            count = 0;
            type = '';
            if isempty(anatDir)
                return
            end
            recIdx = mrw.ScanEngine.findRec(ctx, anatDir);
            if recIdx == 0
                return
            end
            names = mrw.ScanEngine.matchingNiftiNames(ctx.Dirs(recIdx), ...
                '_T1w\.nii(\.gz)?$');
            count = numel(names);
            if count > 0
                type = 'BIDS';
            end
        end

        function [tr, tp, sl, vox, msgs] = bidsMeta(ctx, funDir, boldName)
            %BIDSMETA 读取 BIDS BOLD 的 TR（JSON sidecar 优先）/时间点/层数/体素
            tr = NaN;
            tp = NaN;
            sl = NaN;
            vox = nan(1, 3);
            msgs = {};
            if isempty(funDir) || isempty(boldName)
                return
            end
            filePath = fullfile(funDir, boldName);
            info = mrw.ScanEngine.readHeaderCached(ctx, filePath);
            if info.ReadOK
                tp = info.TimePoints;
                sl = info.SliceNumber;
                vox = info.VoxSize;
                tr = info.TR;
            else
                msgs{end+1} = 'BOLD NIfTI 头解析失败，时间点/层数/TR 未知。';
            end

            % 同名 JSON sidecar
            jsonPath = regexprep(filePath, '(?i)\.nii(\.gz)?$', '.json');
            if exist(jsonPath, 'file') == 2
                try
                    meta = jsondecode(fileread(jsonPath));
                    if isfield(meta, 'RepetitionTime') && ...
                            isnumeric(meta.RepetitionTime) && isscalar(meta.RepetitionTime)
                        v = double(meta.RepetitionTime);
                        if isfinite(v) && v > 0
                            tr = v;
                        end
                    end
                catch
                    if isfinite(tr)
                        msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                            'BIDS JSON sidecar 解析失败，TR 改用 NIfTI 头信息。');
                    else
                        msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                            'BIDS JSON sidecar 解析失败，TR 未知。');
                    end
                end
            else
                msgs = mrw.ScanEngine.addUniqueMsg(msgs, ...
                    '未找到 BIDS BOLD JSON sidecar，TR 取自 NIfTI 头信息。');
            end
        end

        % ==================================================================
        % 各布局构建：规格 -> 完整 Subjects
        % ==================================================================
        function res = emptyRes(workingDir)
            %EMPTYRES 空构建结果
            res = struct('Subjects', mrw.ScanEngine.emptySubjects(), ...
                'StartingDirName', 'FunRaw', 'IsBIDS', false, ...
                'Warnings', {{}}, 'WorkingDir', workingDir);
        end

        function res = buildDPARSF(ctx, plan)
            %BUILDDPARSF 填充 DPARSF 受试者的统计与头信息
            o = ctx.Opts;
            res = mrw.ScanEngine.emptyRes(plan.WorkingDir);
            res.StartingDirName = plan.StartingDirName;
            res.Warnings = plan.Warnings;
            for i = 1:numel(plan.Subjects)
                res.Subjects(end+1) = mrw.ScanEngine.assembleSubject(plan.Subjects(i), ctx, o);
                if mod(i, 20) == 0
                    mrw.ScanEngine.report(o, sprintf('正在读取受试者头信息…（%d/%d）', ...
                        i, numel(plan.Subjects)));
                end
            end
            if isempty(plan.Subjects)
                res.Warnings{end+1} = '检测到 DPARSF 目录结构，但没有可用的受试者。';
            end
        end

        function res = buildBIDS(ctx, plan)
            %BUILDBIDS 填充 BIDS 受试者的统计与头信息
            o = ctx.Opts;
            res = mrw.ScanEngine.emptyRes(plan.WorkingDir);
            res.StartingDirName = 'FunRaw';
            res.IsBIDS = true;
            res.Warnings = plan.Warnings;
            for i = 1:numel(plan.Subjects)
                res.Subjects(end+1) = mrw.ScanEngine.assembleSubject(plan.Subjects(i), ctx, o);
            end
        end

        function res = buildGeneric(ctx, o, niiPlan, dcmPlan, layout)
            %BUILDGENERIC 构建通用 NIfTI / DICOM / MIXED 布局的受试者
            res = mrw.ScanEngine.emptyRes(ctx.Root);
            res.StartingDirName = 'FunRaw';
            res.Warnings = [niiPlan.Warnings, dcmPlan.Warnings];
            specs = mrw.ScanEngine.emptySpecs();
            specMap = containers.Map('KeyType', 'char', 'ValueType', 'double');

            % ---------- 1) NIfTI 功能像目录 -> 受试者 ----------
            if o.IncludeNIfTI && niiPlan.Found
                for i = 1:numel(niiPlan.FuncDirRecs)
                    rec = ctx.Dirs(niiPlan.FuncDirRecs(i));
                    subjDir = mrw.ScanEngine.subjectDirForDir(ctx, rec);
                    [specs, specMap] = mrw.ScanEngine.getOrAddSpec(specs, specMap, ...
                        subjDir, 'NIFTI');
                    si = specMap(mrw.ScanEngine.cacheKey(subjDir));
                    if ~any(strcmp(specs(si).FunDirs, rec.Path))
                        specs(si).FunDirs{end+1} = rec.Path;
                    end
                end
            end

            % ---------- 2) DICOM 序列目录 -> 受试者 ----------
            if o.IncludeDICOM && dcmPlan.Found
                for i = 1:numel(dcmPlan.SeriesRecs)
                    rec = ctx.Dirs(dcmPlan.SeriesRecs(i));
                    subjDir = mrw.ScanEngine.subjectDirForDir(ctx, rec);
                    [specs, specMap] = mrw.ScanEngine.getOrAddSpec(specs, specMap, ...
                        subjDir, 'DICOM');
                    si = specMap(mrw.ScanEngine.cacheKey(subjDir));
                    if ~any(strcmp(specs(si).FunDirs, rec.Path))
                        specs(si).FunDirs{end+1} = rec.Path;
                    end
                end
            end

            % ---------- 3) 每个受试者：挑选功能序列、补结构像 ----------
            for si = 1:numel(specs)
                specs(si) = mrw.ScanEngine.refineGenericSpec(ctx, o, specs(si));
            end

            for i = 1:numel(specs)
                res.Subjects(end+1) = mrw.ScanEngine.assembleSubject(specs(i), ctx, o);
            end

            % ---------- 4) WorkingDir = 包含各受试者的那一层（受试者目录的公共父目录） ----------
            if ~isempty(specs)
                parents = cell(1, numel(specs));
                for i = 1:numel(specs)
                    parents{i} = fileparts(specs(i).Dir);
                end
                uniq = unique(parents);
                if isscalar(uniq) && ~isempty(uniq{1}) && exist(uniq{1}, 'dir') == 7
                    res.WorkingDir = uniq{1};
                end
            end
            if ~strcmp(layout, 'UNKNOWN')
                res.Warnings{end+1} = ['该目录不是 DPARSF 标准结构（<WorkingDir>/FunRaw/<受试者>/），' ...
                    '无法直接用于 DPARSFA 预处理；建议整理成 FunRaw/<受试者> 结构后重新扫描。'];
            end
            if isempty(specs) && ~strcmp(layout, 'UNKNOWN')
                res.Warnings{end+1} = '识别到数据文件，但没有组合出受试者结构。';
            end
        end

        function spec = refineGenericSpec(ctx, o, spec)
            %REFINEGENERICSPEC 通用布局下细化单个受试者：功能序列选择、结构像定位
            dirs = ctx.Dirs;
            if isempty(spec.FunDirs)
                return
            end
            % ---- 纯 DICOM 序列目录（目录内没有 NIfTI 文件）----
            dcmSeries = []; % spec.FunDirs 中的下标
            for i = 1:numel(spec.FunDirs)
                recIdx = mrw.ScanEngine.findRec(ctx, spec.FunDirs{i});
                if recIdx == 0
                    continue
                end
                rec = dirs(recIdx);
                if rec.NiiCount + rec.NiiGzCount + rec.HdrCount == 0 && rec.DicomCount > 0
                    dcmSeries(end+1) = i; %#ok<AGROW>
                end
            end
            % 一个受试者含多个 DICOM 序列时，只保留张数最多的作为功能像
            if numel(dcmSeries) > 1
                counts = zeros(1, numel(dcmSeries));
                for i = 1:numel(dcmSeries)
                    recIdx = mrw.ScanEngine.findRec(ctx, spec.FunDirs{dcmSeries(i)});
                    counts(i) = dirs(recIdx).DicomCount;
                end
                [~, keepRel] = max(counts);
                keepAbs = dcmSeries(keepRel);
                removeAbs = setdiff(dcmSeries, keepAbs);
                spec.FunDirs(removeAbs) = [];
                spec.ExtraMessages = mrw.ScanEngine.addUniqueMsg(spec.ExtraMessages, ...
                    sprintf('检测到 %d 个 DICOM 序列，已选择张数最多的作为功能像。', ...
                    numel(dcmSeries)));
            end

            % ---- 结构像定位 ----
            if isempty(spec.AnatDir)
                [anatDir, extra] = mrw.ScanEngine.findGenericAnat(ctx, o, spec);
                spec.AnatDir = anatDir;
                for m = 1:numel(extra)
                    spec.ExtraMessages = mrw.ScanEngine.addUniqueMsg(spec.ExtraMessages, extra{m});
                end
            end
        end

        function subjDir = subjectDirForDir(ctx, rec)
            %SUBJECTDIRFORDIR 依据“受试者目录 = 含功能像的目录或其父目录”推断受试者目录
            if mrw.ScanEngine.pathEquals(rec.Path, ctx.Root)
                subjDir = rec.Path;
            elseif mrw.ScanEngine.pathEquals(rec.Parent, ctx.Root)
                subjDir = rec.Path;
            else
                subjDir = rec.Parent;
            end
        end

        function [specs, specMap] = getOrAddSpec(specs, specMap, subjDir, kind)
            %GETORADDSPEC 取得（或新建）某受试者目录的规格
            key = mrw.ScanEngine.cacheKey(subjDir);
            if isKey(specMap, key)
                return
            end
            spec = mrw.ScanEngine.makeSpec(mrw.ScanEngine.baseName(subjDir), subjDir, ...
                {}, '', kind, {});
            specs(end+1) = spec;
            specMap(key) = numel(specs);
        end

        function [anatDir, msgs] = findGenericAnat(ctx, o, spec)
            %FINDGENERICANAT 通用布局下寻找受试者的结构像目录
            %   候选：受试者目录自身、其直接子目录、名字像 T1 的 DICOM 序列。
            anatDir = '';
            msgs = {};
            dirs = ctx.Dirs;
            cands = {};
            scores = [];
            % 1) 受试者目录自身
            recIdx = mrw.ScanEngine.findRec(ctx, spec.Dir);
            if recIdx > 0
                cls = mrw.ScanEngine.classOfDir(ctx, dirs(recIdx));
                if cls.IsAnat
                    cands{end+1} = spec.Dir;
                    scores(end+1) = 4 + 2 * double(mrw.ScanEngine.nameLooksAnat(dirs(recIdx).Name));
                end
            end
            % 2) 直接子目录
            childIdxs = mrw.ScanEngine.childRecs(ctx, spec.Dir);
            for c = childIdxs
                rec = dirs(c);
                if rec.NiiCount + rec.NiiGzCount + rec.HdrCount == 0
                    % DICOM 序列：名字像 T1 也可作结构像
                    if o.IncludeDICOM && rec.DicomCount >= mrw.ScanEngine.MinDicomSeriesFiles && ...
                            mrw.ScanEngine.nameLooksAnat(rec.Name)
                        cands{end+1} = rec.Path; %#ok<AGROW>
                        scores(end+1) = 3; %#ok<AGROW>
                    end
                    continue
                end
                if any(strcmp(spec.FunDirs, rec.Path))
                    % 与功能像同目录时仍需判断是否同时含 3D 结构像
                    cls = mrw.ScanEngine.classOfDir(ctx, rec);
                    if cls.IsAnat
                        cands{end+1} = rec.Path; %#ok<AGROW>
                        scores(end+1) = 3; %#ok<AGROW>
                    end
                    continue
                end
                cls = mrw.ScanEngine.classOfDir(ctx, rec);
                if cls.IsAnat
                    cands{end+1} = rec.Path; %#ok<AGROW>
                    scores(end+1) = 2 + 3 * double(mrw.ScanEngine.nameLooksAnat(rec.Name)); %#ok<AGROW>
                end
            end
            % 3) 与功能像同目录的混合情况已在 1)/2) 覆盖
            if isempty(cands)
                return
            end
            [~, best] = max(scores);
            anatDir = cands{best};
            if numel(cands) > 1
                msgs{end+1} = '存在多个疑似结构像目录，已选择最像 T1 的一个。';
            end
        end

        % ==================================================================
        % 结果汇总：Detected、一致性提示、布局名称
        % ==================================================================
        function det = buildDetected(subs, workingDir, startingDirName, isBIDS)
            %BUILDDETECTED 汇总可直接填入 DPARSFA Cfg 的检测参数
            det = mrw.ScanEngine.emptyDetected();
            if isempty(workingDir)
                workingDir = '';
            end
            det.WorkingDir = workingDir;
            if ~isempty(startingDirName)
                det.StartingDirName = startingDirName;
            end
            det.IsBIDS = logical(isBIDS);
            if isempty(subs)
                return
            end
            det.SubjectIDs = {subs.ID};
            % Lead 约定：TR / TimePoints / SliceNumber 取第一受试者（session1）的值；
            % 若第一受试者未知（NaN），则退化为各受试者的多数值。
            det.TR = mrw.ScanEngine.pickFirstOrMode(subs(1).TR, [subs.TR]);
            det.TimePoints = mrw.ScanEngine.pickFirstOrMode(subs(1).TimePoints, [subs.TimePoints]);
            det.SliceNumber = mrw.ScanEngine.pickFirstOrMode(subs(1).SliceNumber, [subs.SliceNumber]);
            sessions = [subs.Sessions];
            if ~isempty(sessions)
                det.FunctionalSessionNumber = max(sessions);
            end
        end

        function v = pickFirstOrMode(firstValue, allValues)
            %PICKFIRSTORMODE 优先取第一受试者的值；为 NaN 时取多数值
            if isfinite(firstValue)
                v = firstValue;
            else
                v = mrw.ScanEngine.modeOfValues(allValues);
            end
        end

        function warnings = consistencyWarnings(subs)
            %CONSISTENCYWARNINGS 跨受试者的一致性检查提示
            warnings = {};
            if numel(subs) < 2
                return
            end
            sessions = [subs.Sessions];
            if numel(unique(sessions)) > 1
                warnings{end+1} = sprintf(['各受试者功能像 session 数不一致（%s），' ...
                    'Detected.FunctionalSessionNumber 取最大值 %d。'], ...
                    mrw.ScanEngine.describeValues(sessions), max(sessions));
            end
            tr = [subs.TR];
            tr = tr(isfinite(tr));
            if numel(unique(tr)) > 1
                warnings{end+1} = sprintf(['各受试者 TR 不一致（%s），' ...
                    'Detected.TR 取第一受试者的值。'], mrw.ScanEngine.describeValues(tr));
            end
            tp = [subs.TimePoints];
            tp = tp(isfinite(tp));
            if numel(unique(tp)) > 1
                warnings{end+1} = sprintf(['各受试者时间点不一致（%s），' ...
                    'Detected.TimePoints 取第一受试者的值。'], mrw.ScanEngine.describeValues(tp));
            end
            sl = [subs.SliceNumber];
            sl = sl(isfinite(sl));
            if numel(unique(sl)) > 1
                warnings{end+1} = sprintf(['各受试者层数不一致（%s），' ...
                    'Detected.SliceNumber 取第一受试者的值。'], mrw.ScanEngine.describeValues(sl));
            end
        end

        function s = describeValues(values)
            %DESCRIBEVALUES 把数值列表转成 "2, 2, 3" 形式的短字符串
            values = double(values(:));
            parts = cell(1, numel(values));
            for k = 1:numel(values)
                parts{k} = sprintf('%g', values(k));
            end
            s = strjoin(parts, ', ');
        end

        function name = rootModalLayoutName(startingDirName)
            %ROOTMODALLAYOUTNAME 根目录本身就是 DPARSF 功能像目录时的中文布局名
            if ~isempty(regexp(startingDirName, '^FunRaw$', 'once', 'ignorecase'))
                name = sprintf('DPARSF 功能像原始目录（%s）', startingDirName);
            else
                name = sprintf('DPARSF 已处理阶段目录（%s，续跑模式）', startingDirName);
            end
        end

        function name = layoutName(layout)
            %LAYOUTNAME 布局的中文描述
            switch layout
                case 'DPARSF'
                    name = 'DPARSF 标准目录（FunRaw/AnatRaw）';
                case 'BIDS'
                    name = 'BIDS 标准目录（sub-*/func、anat）';
                case 'NIFTI'
                    name = '通用 NIfTI 目录（4D 功能像）';
                case 'DICOM'
                    name = 'DICOM 序列目录';
                case 'MIXED'
                    name = '混合格式目录（NIfTI + DICOM）';
                otherwise
                    name = '未识别的数据目录';
            end
        end
    end
end
