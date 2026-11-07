classdef QcModel
    % QcModel  人工 QC 数据模型（DPARSF/DPABI QualityControl 兼容）
    %
    % 用途：
    %   为「人工 QC」界面（mrw.QcPanel / mrw.QcViewer）提供只读的数据发现、
    %   NIfTI 读取、切片与标准化轮廓生成，以及与 DPARSF 完全兼容的
    %   1–5 分人工评分（1=很差 … 5=很好）、阈值和「通过名单」的持久化。
    %
    % 设计约定（与 docs/QC_CONTRACT.md 第 1 节一致）：
    %   * 全部为静态方法，无全局状态；所有失败路径返回空值 + 中文
    %     info.Message / warning，不向调用者抛出未捕获异常（UI 可直接显示提示）。
    %   * 图像读取优先 DPABI y_Read，其次 SPM12 spm_vol/spm_read_vols，
    %     最后 MATLAB niftiread；支持 .nii / .nii.gz / .img+.hdr；
    %     4D 数据自动按时间维平均（info.Mean4D=true, info.TimePoints=n）。
    %   * hdr.mat 为 4x4「1-based 体素坐标 → 世界 mm」仿射（SPM 约定，
    %     与 spm_vol().mat / y_Read() 返回头一致）。
    %   * makeSlice 的切片转置约定（QcPanel 与 edgeSliceFor 必须一致）：
    %       axial   : Image = vol(:,:,k)                      （不转置）
    %       coronal : Image = flipud(squeeze(vol(:,j,:)).')   （rows=z，向上为正）
    %       sagittal: Image = flipud(squeeze(vol(i,:,:)).')   （rows=z，向上为正）
    %   * 评分 TSV 与 DPARSF 一致：首行
    %     "Subject ID<TAB>QC Score<TAB>QC Comment"，之后每行一个受试者，
    %     Tab 分隔；本类写 UTF-8，读取时 UTF-8 优先、系统编码兜底。
    %   * 标准化轮廓使用 DPABI 模板
    %     Templates/Edge_mni_icbm152_AllTissues_tal_nlin_asym_09c_YCG.nii
    %     （真实 193x229x193 / 1mm，按图像 hdr.mat 与模板 hdr.mat 的仿射关系
    %     线性重采样到当前切片网格）。
    %
    % 用法：
    %   info  = mrw.QcModel.discover(workDir);
    %   S     = mrw.QcModel.subjects(workDir, 'T1');
    %   [vol, hdr, info] = mrw.QcModel.loadVolume(file);
    %   sl    = mrw.QcModel.makeSlice(vol, 'axial', 30);
    %   edge  = mrw.QcModel.edgeSliceFor(hdr, 'axial', 30, size(sl.Image));
    %   scores = mrw.QcModel.loadScores(workDir, 'T1');
    %   ok    = mrw.QcModel.saveScore(workDir, 'T1', 'Sub01', 4, '图像清晰');
    %   prog  = mrw.QcModel.progress(workDir);
    %   thr   = mrw.QcModel.loadThresholds(workDir);
    %   list  = mrw.QcModel.exportPassList(workDir, 'pass.txt', thr);
    %
    % 参考（只读）：DPABI QualityControl/y_spm_image.m（1–5 分）、
    %   y_QC_Normalization.m（wFun/wT1/wGM + Edge 模板）、DPABI_QC_TOOL.m
    %   （阈值/名单）、DPARSF/DPARSFA_run.m（QC TSV 与文件选择）。
    %
    % 编写：qc-engineer（MRI 静息态工作台）。

    methods (Static)

        % =================================================================
        % 1.1 模态与文件发现
        % =================================================================

        function info = discover(workDir)
            % discover  扫描 DPARSF 工作目录，发现三种人工 QC 模态可用性
            %   info = mrw.QcModel.discover(workDir)
            %   返回 info.WorkingDir / Ok / Message / Modalities(1x3)，
            %   另附 info.SubjectIDs（所有可推断受试者的并集，方便 UI 判断缺失）。
            info = struct();
            info.WorkingDir = mrw.QcModel.absPath(workDir);
            info.Ok = false;
            info.Message = '';
            info.Modalities = mrw.QcModel.emptyModalities();
            info.SubjectIDs = {};
            wd = info.WorkingDir;
            if isempty(wd)
                info.Message = '未指定工作目录。';
                return;
            end
            if exist(wd, 'dir') ~= 7
                info.Message = sprintf('工作目录不存在或不是文件夹：%s', wd);
                return;
            end
            % 受试者来源：DPARSF 各数据目录 + 已有 QC TSV
            ids = mrw.QcModel.scanSubjectDirs(wd);
            tsvIds = mrw.QcModel.scanTsvIds(wd);
            allIds = mrw.QcModel.naturalSort([ids, tsvIds]);
            info.SubjectIDs = allIds;
            nAvail = zeros(1, 3);
            for k = 1:3
                key = info.Modalities(k).Key;
                avail = {};
                for i = 1:numel(allIds)
                    if mrw.QcModel.subjectAvailable(wd, key, allIds{i})
                        avail{end+1} = allIds{i}; %#ok<AGROW>
                    end
                end
                avail = mrw.QcModel.naturalSort(avail);
                info.Modalities(k).Available = ~isempty(avail);
                info.Modalities(k).SubjectIDs = avail;
                info.Modalities(k).Missing = mrw.QcModel.naturalSort(setdiff(allIds, avail));
                nAvail(k) = numel(avail);
            end
            info.Ok = any(nAvail > 0);
            if ~info.Ok
                info.Message = ['未在 T1Img / RealignParameter / T1ImgNewSegment 等 ' ...
                    'DPARSF 目录中发现可用图像。'];
            else
                info.Message = sprintf(['发现 %d 名受试者：T1 原始像 %d 可用，' ...
                    '功能平均像 %d 可用，标准化检查 %d 可用。'], ...
                    numel(allIds), nAvail(1), nAvail(2), nAvail(3));
            end
        end

        function S = subjects(workDir, modalityKey)
            % subjects  返回某模态下逐受试者的文件明细
            %   S = mrw.QcModel.subjects(workDir, modalityKey)
            %   S 为 struct array（按受试者自然排序），字段：
            %     ID / Available / File / FileKind / Candidates / Message
            %     （Fun 模态额外 ComputedMean，表示需对 FunImg 4D 自动平均）
            %   FileKind: 'T1' | 'FunMean' | 'Fun4DMean' | 'NormFun' | 'NormT1' | 'NormGM'
            if nargin < 2 || isempty(modalityKey)
                modalityKey = 'T1';
            end
            key = mrw.QcModel.canonKey(modalityKey);
            wd = mrw.QcModel.absPath(workDir);
            S = mrw.QcModel.emptySubjects();
            if isempty(wd) || exist(wd, 'dir') ~= 7
                return;
            end
            ids = mrw.QcModel.naturalSort([mrw.QcModel.scanSubjectDirs(wd), ...
                mrw.QcModel.scanTsvIds(wd)]);
            for i = 1:numel(ids)
                r = mrw.QcModel.emptySubject();
                r.ID = ids{i};
                switch key
                    case 'T1'
                        f = mrw.QcModel.t1File(wd, ids{i});
                        if ~isempty(f)
                            r.Available = true;
                            r.File = f;
                            r.FileKind = 'T1';
                            r.Candidates = struct('Which', {'T1'}, 'File', {f});
                        else
                            r.Message = '未找到 T1 原始像（T1Img/<受试者>/c*.nii）。';
                        end
                    case 'Fun'
                        [f, kind, cm, msg] = mrw.QcModel.funFile(wd, ids{i});
                        if ~isempty(f)
                            r.Available = true;
                            r.File = f;
                            r.FileKind = kind;
                            r.ComputedMean = cm;
                            r.Candidates = struct('Which', {'Fun'}, 'File', {f});
                            r.Message = msg;
                        else
                            r.Message = msg;
                        end
                    otherwise
                        C = mrw.QcModel.normCandidates(wd, ids{i});
                        r.Candidates = C;
                        if ~isempty(C)
                            r.Available = true;
                            r.File = C(1).File;
                            switch C(1).Which
                                case 'Fun'
                                    r.FileKind = 'NormFun';
                                case 'T1'
                                    r.FileKind = 'NormT1';
                                otherwise
                                    r.FileKind = 'NormGM';
                            end
                        else
                            r.Message = '未找到标准化图像（wmean* / wT1 / wc1*）。';
                        end
                end
                S(i) = r;
            end
        end

        % =================================================================
        % 1.2 读写图像
        % =================================================================

        function [vol, hdr, info] = loadVolume(filePath)
            % loadVolume  读取 NIfTI 体数据（.nii / .nii.gz / .img+.hdr）
            %   [vol, hdr, info] = mrw.QcModel.loadVolume(filePath)
            %   vol : 3D double（4D 自动按时间维平均）
            %   hdr : .mat（4x4，1-based 体素→mm）/.dim（1x3）/.voxSize（1x3）/.File
            %   info: .File .Dim .VoxSize .TimePoints .Mean4D .Source .Message .Ok
            %   读取失败时 vol=[]、hdr.mat=NaN、info.Message 为中文原因，不抛异常。
            info = mrw.QcModel.emptyVolumeInfo('');
            hdr = mrw.QcModel.emptyHdr();
            vol = [];
            if nargin < 1 || isempty(filePath)
                info.Message = '未提供图像文件路径。';
                return;
            end
            if isstring(filePath) && isscalar(filePath)
                filePath = char(filePath);
            end
            if ~ischar(filePath)
                info.Message = '图像路径必须是字符向量。';
                return;
            end
            p = mrw.QcModel.absPath(filePath);
            info.File = p;
            if isempty(p)
                info.Message = '图像路径为空。';
                return;
            end
            if exist(p, 'file') ~= 2
                info.Message = sprintf('图像文件不存在：%s', p);
                return;
            end
            errMsgs = {};

            % y_Read 会在源目录解压并删除同名 .nii；所有读取器统一使用临时副本。
            originalPath = p;
            if ~isempty(regexpi(p, '\.nii\.gz$', 'once'))
                try
                    [p, readTempDir] = mrw.QcModel.gunzipToTemp(p);
                    readCleanup = onCleanup(@() mrw.QcModel.removeDir(readTempDir)); %#ok<NASGU>
                catch err
                    info.Message = sprintf('临时解压图像失败：%s', err.message);
                    return;
                end
            end

            % --- 1) DPABI y_Read（首选） ---
            if exist('y_Read', 'file') == 2
                try
                    [D, H] = y_Read(p);
                    [vol, hdr, nTp, mean4d] = mrw.QcModel.finalizeVolume(D, H, originalPath);
                    info = mrw.QcModel.fillVolumeInfo(info, vol, hdr, nTp, mean4d, 'y_Read');
                    return;
                catch err
                    errMsgs{end+1} = ['y_Read：' err.message]; %#ok<AGROW>
                    vol = [];
                    hdr = mrw.QcModel.emptyHdr();
                end
            end

            % --- 2) SPM12 spm_vol / spm_read_vols ---
            if exist('spm_vol', 'file') == 2 && exist('spm_read_vols', 'file') == 2
                try
                    V = spm_vol(p);
                    if isempty(V)
                        error('spm_vol 未返回有效头信息');
                    end
                    D = spm_read_vols(V);
                    [vol, hdr, nTp, mean4d] = mrw.QcModel.finalizeVolume(D, V(1), originalPath);
                    info = mrw.QcModel.fillVolumeInfo(info, vol, hdr, nTp, mean4d, 'spm');
                    return;
                catch err
                    errMsgs{end+1} = ['spm：' err.message]; %#ok<AGROW>
                    vol = [];
                    hdr = mrw.QcModel.emptyHdr();
                end
            end

            % --- 3) MATLAB niftiread 兜底 ---
            if exist('niftiread', 'file') == 2
                tmpDir = '';
                try
                    q = p;
                    if ~isempty(regexpi(p, '\.gz$', 'once'))
                        [q, tmpDir] = mrw.QcModel.gunzipToTemp(p);
                    end
                    ni = niftiinfo(q);
                    D = niftiread(ni);
                    M = mrw.QcModel.niftiTransform(ni);
                    if isempty(M)
                        M = mrw.QcModel.niftiSformFromFile(q);
                    end
                    H = struct('mat', M, 'dim', size(D));
                    [vol, hdr, nTp, mean4d] = mrw.QcModel.finalizeVolume(D, H, originalPath);
                    info = mrw.QcModel.fillVolumeInfo(info, vol, hdr, nTp, mean4d, 'niftiread');
                    mrw.QcModel.removeDir(tmpDir);
                    return;
                catch err
                    errMsgs{end+1} = ['niftiread：' err.message]; %#ok<AGROW>
                    mrw.QcModel.removeDir(tmpDir);
                    vol = [];
                    hdr = mrw.QcModel.emptyHdr();
                end
            end

            info.Message = sprintf('读取图像失败（%s）：%s', strjoin(errMsgs, '；'), p);
        end

        % =================================================================
        % 1.3 切片与标准化轮廓
        % =================================================================

        function sl = makeSlice(vol, orientation, sliceIndex)
            % makeSlice  从 3D 体数据取一个 2D 切片
            %   sl = mrw.QcModel.makeSlice(vol, orientation, sliceIndex)
            %   转置约定见类文件头；sliceIndex 越界自动 clamp，缺省取中间层。
            sl = struct('Image', [], 'Orientation', 'axial', 'SliceIndex', 0, ...
                'SliceCount', 0, 'SliceLabel', '无数据', 'Message', '');
            if nargin < 1 || isempty(vol) || ~isnumeric(vol) || ndims(vol) ~= 3
                sl.Message = '体数据为空或不是 3D 矩阵，无法切片。';
                return;
            end
            dims = size(vol);
            [o, total, letter, labelEn] = mrw.QcModel.orientationInfo(orientation, dims);
            if nargin < 3 || isempty(sliceIndex) || ~isnumeric(sliceIndex) || ...
                    ~isscalar(sliceIndex) || ~isfinite(sliceIndex)
                k = round((total + 1) / 2);
            else
                k = round(double(sliceIndex));
            end
            k = min(max(k, 1), total);
            switch o
                case 'axial'
                    img = vol(:, :, k);
                case 'coronal'
                    img = flipud(squeeze(vol(:, k, :)).');
                otherwise
                    img = flipud(squeeze(vol(k, :, :)).');
            end
            img = double(img);
            if ~ismatrix(img)
                img = reshape(img, size(img, 1), []);
            end
            sl.Image = img;
            sl.Orientation = o;
            sl.SliceIndex = k;
            sl.SliceCount = total;
            sl.SliceLabel = sprintf('%s %s=%d/%d', labelEn, letter, k, total);
            sl.Message = '';
        end

        function edge = edgeSliceFor(hdr, varargin)
            % edgeSliceFor  把 DPABI MNI 边缘模板重采样到当前切片网格
            %   edge = mrw.QcModel.edgeSliceFor(hdr, orientation, sliceIndex, imageSize)
            %   edge = mrw.QcModel.edgeSliceFor(hdr, vol, orientation, sliceIndex)
            %   返回与 makeSlice 的 .Image 同尺寸的 2D double 轮廓权重（0–1，
            %   >0.05 视作轮廓）；失败时返回 zeros(imageSize) 并给 warning。
            orientation = 'axial';
            sliceIndex = [];
            imageSize = [];
            vol = [];
            if isempty(varargin)
                warning('mrw:QcModel:edgeTemplate', 'edgeSliceFor 缺少方向参数，返回空轮廓。');
                edge = [];
                return;
            end
            if isnumeric(varargin{1}) && ~isempty(varargin{1}) && ndims(varargin{1}) == 3
                % 兼容 (hdr, vol, orientation, sliceIndex) 形式
                vol = varargin{1};
                if numel(varargin) >= 2, orientation = varargin{2}; end
                if numel(varargin) >= 3, sliceIndex = varargin{3}; end
                sl = mrw.QcModel.makeSlice(vol, orientation, sliceIndex);
                orientation = sl.Orientation;
                sliceIndex = sl.SliceIndex;
                imageSize = size(sl.Image);
            else
                orientation = varargin{1};
                if numel(varargin) >= 2, sliceIndex = varargin{2}; end
                if numel(varargin) >= 3, imageSize = varargin{3}; end
            end

            % 体数据尺寸（用于确定切片平面上的体素索引）
            dims = [];
            if isstruct(hdr) && isfield(hdr, 'dim') && numel(hdr.dim) >= 3
                d = double(hdr.dim(1:3));
                if all(isfinite(d)) && all(d > 0)
                    dims = round(d);
                end
            end
            if isempty(dims) && ~isempty(vol)
                dims = size(vol);
            end
            [o, total, ~, ~] = mrw.QcModel.orientationInfo(orientation, ...
                max([dims, ones(1, 3)], [], 'omitnan'));
            if ~isempty(dims)
                switch o
                    case 'axial'
                        expected = [dims(1), dims(2)];
                    case 'coronal'
                        expected = [dims(3), dims(1)];
                    otherwise
                        expected = [dims(3), dims(2)];
                end
            else
                expected = [];
            end
            if isempty(imageSize)
                imageSize = expected;
            end
            if isempty(imageSize) || numel(imageSize) ~= 2
                warning('mrw:QcModel:edgeTemplate', '无法确定切片网格尺寸，返回空轮廓。');
                edge = zeros(max(imageSize, 1));
                return;
            end
            imageSize = double(imageSize(:).');
            if isempty(expected) || ~isequal(imageSize, double(expected))
                warning('mrw:QcModel:edgeTemplate', ...
                    '图像尺寸 %s 与 hdr.dim 推断的 %s 不一致，返回空轮廓。', ...
                    mat2str(imageSize), mat2str(expected));
                edge = zeros(imageSize);
                return;
            end

            % 图像仿射必须有效
            M = mrw.QcModel.hdrMat(hdr);
            if isempty(M)
                warning('mrw:QcModel:edgeTemplate', ...
                    '图像 hdr.mat 无效，无法重采样标准化轮廓，返回空轮廓。');
                edge = zeros(imageSize);
                return;
            end

            % 模板（persistent 缓存）
            T = mrw.QcModel.templateData();
            if ~T.ok
                warning('mrw:QcModel:edgeTemplate', '标准化轮廓不可用：%s', T.msg);
                edge = zeros(imageSize);
                return;
            end

            % 按 makeSlice 的转置约定建立体素索引网格
            switch o
                case 'axial'
                    k = min(max(round(sliceIndex), 1), dims(3));
                    [I, J] = ndgrid(1:dims(1), 1:dims(2));
                    K = k * ones(size(I));
                case 'coronal'
                    j = min(max(round(sliceIndex), 1), dims(2));
                    [Kf, I] = ndgrid(1:dims(3), 1:dims(1));
                    K = dims(3) - Kf + 1;
                    J = j * ones(size(K));
                otherwise
                    i = min(max(round(sliceIndex), 1), dims(1));
                    [Kf, J] = ndgrid(1:dims(3), 1:dims(2));
                    K = dims(3) - Kf + 1;
                    I = i * ones(size(K));
            end

            % 图像体素 -> 世界 mm
            X = M(1, 1) * I + M(1, 2) * J + M(1, 3) * K + M(1, 4);
            Y = M(2, 1) * I + M(2, 2) * J + M(2, 3) * K + M(2, 4);
            Z = M(3, 1) * I + M(3, 2) * J + M(3, 3) * K + M(3, 4);
            % 世界 mm -> 边缘模板体素，再线性插值
            iT = T.invMat;
            Tx = iT(1, 1) * X + iT(1, 2) * Y + iT(1, 3) * Z + iT(1, 4);
            Ty = iT(2, 1) * X + iT(2, 2) * Y + iT(2, 3) * Z + iT(2, 4);
            Tz = iT(3, 1) * X + iT(3, 2) * Y + iT(3, 3) * Z + iT(3, 4);
            try
                E = T.F(Tx, Ty, Tz);
            catch err
                warning('mrw:QcModel:edgeTemplate', '重采样标准化轮廓失败：%s', err.message);
                edge = zeros(imageSize);
                return;
            end
            edge = double(E);
            edge(~isfinite(edge)) = 0;
            edge = min(max(edge, 0), 1);
        end

        function p = mniEdgeFile()
            % mniEdgeFile  DPABI 标准化边缘模板的绝对路径（找不到返回 ''）
            persistent cache
            if ~isempty(cache)
                p = cache;
                return;
            end
            p = mrw.QcModel.templatePath( ...
                'Edge_mni_icbm152_AllTissues_tal_nlin_asym_09c_YCG.nii');
            if ~isempty(p)
                cache = p;
            end
        end

        function p = mniTemplateFile()
            % mniTemplateFile  DPABI MNI 模板 ch2.nii 的绝对路径（找不到返回 ''）
            persistent cache
            if ~isempty(cache)
                p = cache;
                return;
            end
            p = mrw.QcModel.templatePath('ch2.nii');
            if ~isempty(p)
                cache = p;
            end
        end

        % =================================================================
        % 1.4 评分 TSV（DPARSF 兼容）、进度、阈值与通过名单
        % =================================================================

        function scores = loadScores(workDir, modalityKey)
            % loadScores  读取某模态的人工 QC 评分
            %   scores = mrw.QcModel.loadScores(workDir, modalityKey)
            %   struct array：ID / Score（未评分为 NaN）/ Comment；文件不存在返回空。
            if nargin < 2 || isempty(modalityKey)
                modalityKey = 'T1';
            end
            scores = mrw.QcModel.emptyScores();
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                return;
            end
            f = mrw.QcModel.tsvFile(wd, modalityKey);
            if isempty(f) || exist(f, 'file') ~= 2
                return;
            end
            scores = mrw.QcModel.readScoreRows(f);
        end

        function [ok, msg] = saveScore(workDir, modalityKey, subjectID, score, comment)
            % saveScore  写入/更新一个受试者的人工 QC 评分（DPARSF 兼容 TSV）
            %   [ok, msg] = mrw.QcModel.saveScore(workDir, modalityKey, subjectID, score, comment)
            %   合并已有行（保留其他受试者与行序），同一受试者重复评分时覆盖。
            %   score 必须为 1–5 的整数，否则 ok=false 且 msg 为中文原因。
            ok = false;
            msg = '';
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                msg = '工作目录不存在，无法保存评分。';
                return;
            end
            if nargin < 4
                msg = '缺少评分值。';
                return;
            end
            if ~isnumeric(score) || ~isscalar(score) || ~isfinite(score) || ...
                    score ~= round(score) || score < 1 || score > 5
                msg = '评分必须是 1–5 的整数（1=很差，5=很好）。';
                return;
            end
            if nargin < 5 || isempty(comment)
                comment = '';
            end
            if isstring(comment) && isscalar(comment)
                comment = char(comment);
            end
            if ~ischar(comment)
                msg = '评语必须是文本。';
                return;
            end
            if nargin < 3 || isempty(subjectID)
                msg = '受试者编号为空。';
                return;
            end
            if isstring(subjectID) && isscalar(subjectID)
                subjectID = char(subjectID);
            end
            if ~ischar(subjectID) || isempty(strtrim(subjectID))
                msg = '受试者编号无效。';
                return;
            end
            sid = strtrim(subjectID);
            if any(double(sid) == 9) || any(double(sid) == 10) || any(double(sid) == 13)
                msg = '受试者编号不能包含制表符或换行符。';
                return;
            end
            comment = mrw.QcModel.sanitizeComment(comment);
            f = mrw.QcModel.tsvFile(wd, modalityKey);
            qcDir = fullfile(wd, 'QC');
            if exist(qcDir, 'dir') ~= 7
                [st, m] = mkdir(qcDir);
                if ~st
                    msg = sprintf('无法创建 QC 目录：%s', m);
                    return;
                end
            end
            rows = mrw.QcModel.emptyScores();
            if exist(f, 'file') == 2
                rows = mrw.QcModel.readScoreRows(f);
            end
            found = false;
            for i = 1:numel(rows)
                if strcmpi(rows(i).ID, sid)
                    rows(i).Score = double(score);
                    rows(i).Comment = comment;
                    found = true;
                    break;
                end
            end
            if ~found
                r = struct('ID', sid, 'Score', double(score), 'Comment', comment);
                rows(end+1) = r;
            end
            ok = mrw.QcModel.writeScoreRows(f, rows);
            if ~ok
                msg = sprintf('写入评分文件失败：%s', f);
            end
        end

        function prog = progress(workDir)
            % progress  三种模态的评分进度汇总
            %   prog.T1/.Fun/.Norm 各有 .Scored/.Total/.Mean；另有 .AllScored。
            wd = mrw.QcModel.absPath(workDir);
            info = mrw.QcModel.discover(wd);
            keys = {'T1', 'Fun', 'Norm'};
            prog = struct();
            anyTotal = false;
            allDone = true;
            wd2 = info.WorkingDir;
            for k = 1:numel(keys)
                key = keys{k};
                scores = mrw.QcModel.loadScores(wd2, key);
                ids = info.Modalities(k).SubjectIDs;
                if ~isempty(scores)
                    ids = [ids, {scores.ID}];
                end
                ids = mrw.QcModel.naturalSort(ids);
                nScored = 0;
                vals = [];
                for i = 1:numel(ids)
                    idx = find(strcmpi({scores.ID}, ids{i}), 1);
                    if ~isempty(idx) && isfinite(scores(idx).Score) && ...
                            scores(idx).Score >= 1 && scores(idx).Score <= 5
                        nScored = nScored + 1;
                        vals(end+1) = scores(idx).Score; %#ok<AGROW>
                    end
                end
                if isempty(vals)
                    meanScore = NaN;
                else
                    meanScore = mean(vals);
                end
                prog.(key) = struct('Scored', nScored, 'Total', numel(ids), ...
                    'Mean', meanScore);
                if numel(ids) > 0
                    anyTotal = true;
                    if nScored < numel(ids)
                        allDone = false;
                    end
                end
            end
            prog.AllScored = anyTotal && allDone;
        end

        function thr = loadThresholds(workDir)
            % loadThresholds  读取 QC/ManualQC_thresholds.json（缺省/损坏时用默认值）
            thr = mrw.QcModel.defaultThresholds();
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                return;
            end
            f = fullfile(wd, 'QC', 'ManualQC_thresholds.json');
            if exist(f, 'file') ~= 2
                return;
            end
            try
                txt = mrw.QcModel.readText(f);
                j = jsondecode(txt);
                thr = mrw.QcModel.mergeThresholds(thr, j);
            catch
                % 文件损坏/格式不符：静默退回默认阈值（UI 不应崩溃）
            end
        end

        function [ok, msg] = saveThresholds(workDir, thr)
            % saveThresholds  保存阈值到 QC/ManualQC_thresholds.json
            ok = false;
            msg = '';
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                msg = '工作目录不存在，无法保存阈值。';
                return;
            end
            thr = mrw.QcModel.mergeThresholds(mrw.QcModel.defaultThresholds(), thr);
            qcDir = fullfile(wd, 'QC');
            if exist(qcDir, 'dir') ~= 7
                [st, m] = mkdir(qcDir);
                if ~st
                    msg = sprintf('无法创建 QC 目录：%s', m);
                    return;
                end
            end
            f = fullfile(qcDir, 'ManualQC_thresholds.json');
            fid = -1;
            try
                txt = jsonencode(thr);
                fid = fopen(f, 'w', 'n', 'UTF-8');
                if fid < 0
                    error('无法打开文件写入');
                end
                fprintf(fid, '%s\n', txt);
                fclose(fid);
                fid = -1;
                ok = true;
            catch err
                if fid >= 0
                    try, fclose(fid); catch, end %#ok<CTCH>
                end
                msg = sprintf('保存阈值失败：%s', err.message);
            end
        end

        function [list, msg] = exportPassList(workDir, outFile, thr)
            % exportPassList  按评分/阈值筛选通过被试并导出文本名单
            %   [list, msg] = mrw.QcModel.exportPassList(workDir, outFile, thr)
            %   规则参考 DPABI_QC_TOOL：各模态 Score>=最小分 才通过；
            %   可选 MeanFD < MaxMeanFD；每行一个受试者写入 outFile（UTF-8）。
            list = {};
            msg = '';
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                msg = '工作目录不存在。';
                return;
            end
            if nargin < 3 || isempty(thr)
                thr = mrw.QcModel.loadThresholds(wd);
            end
            thr = mrw.QcModel.mergeThresholds(mrw.QcModel.defaultThresholds(), thr);
            info = mrw.QcModel.discover(wd);
            cand = info.SubjectIDs;
            keys = {'T1', 'Fun', 'Norm'};
            useFlds = {'UseT1', 'UseFun', 'UseNorm'};
            minFlds = {'T1Min', 'FunMin', 'NormMin'};
            for k = 1:3
                if ~thr.(useFlds{k})
                    continue;
                end
                scores = mrw.QcModel.loadScores(wd, keys{k});
                if isempty(scores) && isempty(info.Modalities(k).SubjectIDs)
                    continue;   % 该模态完全没有数据：不参与过滤
                end
                keep = false(1, numel(cand));
                for i = 1:numel(cand)
                    idx = find(strcmpi({scores.ID}, cand{i}), 1);
                    if ~isempty(idx) && isfinite(scores(idx).Score) && ...
                            scores(idx).Score >= thr.(minFlds{k})
                        keep(i) = true;
                    end
                end
                cand = cand(keep);
            end
            if thr.UseMeanFD
                hm = mrw.QcModel.loadHeadMotion(wd);
                if hm.Available
                    keep = false(1, numel(cand));
                    for i = 1:numel(cand)
                        idx = find(strcmpi(hm.IDs, cand{i}), 1);
                        if ~isempty(idx) && isfinite(hm.MeanFD(idx)) && ...
                                hm.MeanFD(idx) < thr.MaxMeanFD
                            keep(i) = true;
                        end
                    end
                    cand = cand(keep);
                end
            end
            list = mrw.QcModel.naturalSort(cand);
            if nargin >= 2 && ~isempty(outFile)
                if isstring(outFile) && isscalar(outFile)
                    outFile = char(outFile);
                end
                try
                    if ~ischar(outFile)
                        error('输出路径必须是字符向量');
                    end
                    outFile = mrw.QcModel.absPath(outFile);
                    parent = fileparts(outFile);
                    if ~isempty(parent) && exist(parent, 'dir') ~= 7
                        mkdir(parent);
                    end
                    fid = fopen(outFile, 'w', 'n', 'UTF-8');
                    if fid < 0
                        error('无法打开文件写入');
                    end
                    for i = 1:numel(list)
                        fprintf(fid, '%s\n', list{i});
                    end
                    fclose(fid);
                catch err
                    msg = sprintf('写入通过名单失败：%s', err.message);
                end
            end
        end

        function hm = loadHeadMotion(workDir)
            % loadHeadMotion  解析 RealignParameter/HeadMotion.tsv（DPARSF 21 列）
            %   返回 .Available .IDs .MeanFD（第 21 列 mean FD_Jenkinson）
            %   .MaxTrans（平移列 2–4 的最大绝对值，mm）.Table .Header .File .Message
            hm = struct('Available', false, 'IDs', {{}}, 'MeanFD', [], ...
                'MaxTrans', [], 'Table', [], 'Header', {{}}, 'File', '', 'Message', '');
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                hm.Message = '工作目录不存在。';
                return;
            end
            f = fullfile(wd, 'RealignParameter', 'HeadMotion.tsv');
            if exist(f, 'file') ~= 2
                d = dir(fullfile(wd, 'RealignParameter', '*HeadMotion.tsv'));
                if isempty(d)
                    hm.Message = '未找到 RealignParameter/HeadMotion.tsv（尚未进行头动估计）。';
                    return;
                end
                f = fullfile(d(1).folder, d(1).name);
            end
            hm.File = f;
            try
                lines = mrw.QcModel.readLines(f);
                keep = ~cellfun(@(s) isempty(strtrim(s)), lines);
                lines = lines(keep);
                if isempty(lines)
                    hm.Message = 'HeadMotion.tsv 为空。';
                    return;
                end
                header = strsplit(strtrim(lines{1}), sprintf('\t'));
                nCol = numel(header) - 1;
                if nCol < 1
                    nCol = 20;
                end
                ids = {};
                dataRows = cell(1, 0);
                for i = 2:numel(lines)
                    parts = strsplit(strtrim(lines{i}), sprintf('\t'));
                    if numel(parts) < 2
                        continue;
                    end
                    sid = strtrim(parts{1});
                    if isempty(sid)
                        continue;
                    end
                    ids{end+1} = sid; %#ok<AGROW>
                    vals = nan(1, nCol);
                    nCopy = min(numel(parts) - 1, nCol);
                    for c = 1:nCopy
                        vals(c) = str2double(strtrim(parts{c + 1}));
                    end
                    dataRows{end+1} = vals; %#ok<AGROW>
                end
                if isempty(ids)
                    hm.Message = 'HeadMotion.tsv 中没有数据行。';
                    return;
                end
                hm.Header = header;
                hm.IDs = ids(:).';
                hm.Table = cell2mat(dataRows(:));
                nNum = size(hm.Table, 2);
                if nNum >= 20
                    hm.MeanFD = hm.Table(:, 20);
                else
                    hm.MeanFD = nan(numel(ids), 1);
                    hm.Message = sprintf(['HeadMotion.tsv 列数偏少（%d 列），' ...
                        '无法解析 mean FD_Jenkinson。'], nNum + 1);
                end
                if nNum >= 3
                    hm.MaxTrans = max(abs(hm.Table(:, 1:3)), [], 2);
                else
                    hm.MaxTrans = nan(numel(ids), 1);
                end
                hm.Available = true;
            catch err
                hm.Message = sprintf('解析 HeadMotion.tsv 失败：%s', err.message);
            end
        end

        function fd = loadFdSeries(workDir, subjectID, fdType)
            % loadFdSeries  读取某受试者的逐帧 FD 时间序列（DPARSF RealignParameter）
            %   fd = mrw.QcModel.loadFdSeries(workDir, subjectID, fdType)
            %   fdType: 'FD_Jenkinson'（默认）| 'FD_Power' | 'FD_VanDijk'
            %   读取 RealignParameter/<ID>/FD_<type>_<ID>.txt（*通配兜底），每行/每列一个数值。
            %   返回 .Available .ID .Type .Values(1xN double) .File .DefaultThreshold
            %        .Message（Jenkinson/VanDijk 默认阈值 0.2 mm，Power 默认 0.5 mm）。
            %   文件缺失/为空时 Available=false + 中文 Message，不报错。
            fd = mrw.QcModel.emptyFdSeries();
            if nargin < 3 || isempty(fdType)
                fdType = 'FD_Jenkinson';
            end
            [type, thr, typeMsg] = mrw.QcModel.fdTypeInfo(fdType);
            fd.Type = type;
            fd.DefaultThreshold = thr;
            fd.Message = typeMsg;
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                fd.Message = '工作目录不存在，无法读取 FD 文件。';
                return;
            end
            if nargin < 2 || isempty(subjectID)
                fd.Message = '未指定受试者编号，无法读取 FD 文件。';
                return;
            end
            if isstring(subjectID) && isscalar(subjectID)
                subjectID = char(subjectID);
            end
            if ~ischar(subjectID) || isempty(strtrim(subjectID))
                fd.Message = '受试者编号无效。';
                return;
            end
            sid = strtrim(subjectID);
            fd.ID = sid;
            f = mrw.QcModel.fdValueFile(wd, sid, type);
            if isempty(f)
                fd.Message = sprintf(['未找到 %s 的 %s 逐帧 FD 文件' ...
                    '（RealignParameter/%s/%s_%s.txt）。'], sid, type, sid, type, sid);
                return;
            end
            fd.File = f;
            vals = mrw.QcModel.readFdValues(f);
            if isempty(vals)
                fd.Message = sprintf('FD 文件为空或无法解析数值：%s', f);
                return;
            end
            fd.Values = vals(:).';
            fd.Available = true;
        end

        function hm = headMotionSeries(workDir, subjectIDs)
            % headMotionSeries  批量读取多名受试者的三种逐帧 FD（供面板表格/曲线一次取数）
            %   hm = mrw.QcModel.headMotionSeries(workDir, subjectIDs)
            %   返回 .IDs（cell 1xN）.FD_Jenkinson .FD_Power .FD_VanDijk（cell 1xN，
            %   缺失为 []）.Available（是否存在任一 FD 文件）.Thresholds .Message
            types = {'FD_Jenkinson', 'FD_Power', 'FD_VanDijk'};
            hm = struct();
            hm.IDs = {};
            for t = 1:numel(types)
                hm.(types{t}) = {};
            end
            hm.Available = false;
            hm.Thresholds = struct('FD_Jenkinson', 0.2, 'FD_Power', 0.5, ...
                'FD_VanDijk', 0.2);
            hm.Message = '';
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd) || exist(wd, 'dir') ~= 7
                hm.Message = '工作目录不存在，无法读取 FD 序列。';
                return;
            end
            ids = {};
            if nargin >= 2 && ~isempty(subjectIDs)
                try
                    if ischar(subjectIDs)
                        ids = {subjectIDs};
                    elseif isstring(subjectIDs)
                        ids = cellstr(subjectIDs(:).');
                    elseif iscell(subjectIDs)
                        ids = subjectIDs;
                    end
                catch
                    ids = {};
                end
                clean = {};
                for i = 1:numel(ids)
                    if ischar(ids{i}) && ~isempty(strtrim(ids{i}))
                        clean{end+1} = strtrim(ids{i}); %#ok<AGROW>
                    end
                end
                ids = clean;
            end
            if isempty(ids)
                d = dir(fullfile(wd, 'RealignParameter'));
                for i = 1:numel(d)
                    if d(i).isdir && ~strcmp(d(i).name, '.') && ~strcmp(d(i).name, '..')
                        ids{end+1} = d(i).name; %#ok<AGROW>
                    end
                end
            end
            ids = mrw.QcModel.naturalSort(ids);
            hm.IDs = ids;
            anyAvail = false;
            for t = 1:numel(types)
                cellVals = cell(1, numel(ids));
                for i = 1:numel(ids)
                    fd = mrw.QcModel.loadFdSeries(wd, ids{i}, types{t});
                    if fd.Available
                        cellVals{i} = fd.Values;
                        anyAvail = true;
                    else
                        cellVals{i} = [];
                    end
                end
                hm.(types{t}) = cellVals;
            end
            hm.Available = anyAvail;
            if ~anyAvail
                hm.Message = '未找到任何逐帧 FD 文件（RealignParameter/<受试者>/FD_*.txt）。';
            end
        end

        % =================================================================
        % 辅助：标签 / 默认设置 / TSV 路径
        % =================================================================

        function L = labels()
            % labels  返回中文/英文显示标签（供 UI 统一复用）
            L = struct();
            L.Modalities = repmat(struct('Key', '', 'LabelZh', '', 'LabelEn', '', ...
                'TSV', ''), 1, 3);
            mods = {'T1', 'Fun', 'Norm'};
            zh = {'T1 原始像', '功能平均像', '标准化检查'};
            en = {'T1 raw image', 'Mean functional image', 'Normalization check'};
            tsv = {'RawT1ImgQC.tsv', 'RawFunImgQC.tsv', 'NormalizationQC.tsv'};
            for i = 1:3
                L.Modalities(i).Key = mods{i};
                L.Modalities(i).LabelZh = zh{i};
                L.Modalities(i).LabelEn = en{i};
                L.Modalities(i).TSV = tsv{i};
            end
            L.Scores = repmat(struct('Value', 0, 'LabelZh', '', 'LabelEn', ''), 1, 5);
            scoreZh = {'很差', '差', '一般', '好', '很好'};
            scoreEn = {'Very Poor', 'Poor', 'Fair', 'Good', 'Very Good'};
            for i = 1:5
                L.Scores(i).Value = i;
                L.Scores(i).LabelZh = scoreZh{i};
                L.Scores(i).LabelEn = scoreEn{i};
            end
            L.Orientations = repmat(struct('Key', '', 'LabelZh', '', 'LabelEn', ''), 1, 3);
            ori = {'axial', 'coronal', 'sagittal'};
            oZh = {'横断', '冠状', '矢状'};
            oEn = {'Axial', 'Coronal', 'Sagittal'};
            for i = 1:3
                L.Orientations(i).Key = ori{i};
                L.Orientations(i).LabelZh = oZh{i};
                L.Orientations(i).LabelEn = oEn{i};
            end
            L.ScoreMeaning = '1 = 很差 … 5 = 很好（与 DPARSF/DPABI 一致）';
        end

        function st = settings()
            % settings  返回默认设置（评分范围、默认阈值、模板可用性）
            st = struct();
            st.ScoreMin = 1;
            st.ScoreMax = 5;
            st.DefaultScore = 3;
            st.DefaultOrientation = 'axial';
            st.Thresholds = mrw.QcModel.defaultThresholds();
            st.EdgeTemplate = mrw.QcModel.mniEdgeFile();
            st.MniTemplate = mrw.QcModel.mniTemplateFile();
            st.HasDpabiTemplate = ~isempty(st.EdgeTemplate);
        end

        function f = tsvFile(workDir, modalityKey)
            % tsvFile  某模态评分 TSV 的绝对路径（工作目录为空时返回 ''）
            if nargin < 2 || isempty(modalityKey)
                modalityKey = 'T1';
            end
            wd = mrw.QcModel.absPath(workDir);
            if isempty(wd)
                f = '';
                return;
            end
            f = fullfile(wd, 'QC', mrw.QcModel.tsvName(mrw.QcModel.canonKey(modalityKey)));
        end
    end

    % =====================================================================
    % 私有实现
    % =====================================================================
    methods (Static, Access = private)

        % ---------- 基础结构 ----------

        function M = emptyModalities()
            % 三种模态的固定顺序空结构（契约 1.1）
            M = repmat(struct('Key', '', 'LabelZh', '', 'Available', false, ...
                'SubjectIDs', {{}}, 'Missing', {{}}, 'TSVFile', ''), 1, 3);
            keys = {'T1', 'Fun', 'Norm'};
            labels = {'T1 原始像', '功能平均像', '标准化检查'};
            tsv = {'RawT1ImgQC.tsv', 'RawFunImgQC.tsv', 'NormalizationQC.tsv'};
            for i = 1:3
                M(i).Key = keys{i};
                M(i).LabelZh = labels{i};
                M(i).Available = false;
                M(i).SubjectIDs = {};
                M(i).Missing = {};
                M(i).TSVFile = fullfile('QC', tsv{i});
            end
        end

        function r = emptySubject()
            r = struct('ID', '', 'Available', false, 'File', '', ...
                'FileKind', '', 'Candidates', struct('Which', {}, 'File', {}), ...
                'Message', '', 'ComputedMean', false);
        end

        function S = emptySubjects()
            S = struct('ID', {}, 'Available', {}, 'File', {}, 'FileKind', {}, ...
                'Candidates', {}, 'Message', {}, 'ComputedMean', {});
        end

        function s = emptyScores()
            s = struct('ID', {}, 'Score', {}, 'Comment', {});
        end

        function h = emptyHdr()
            h = struct('mat', nan(4), 'dim', nan(1, 3), 'voxSize', nan(1, 3), 'File', '');
        end

        function info = emptyVolumeInfo(filePath)
            info = struct('File', filePath, 'Dim', nan(1, 3), 'VoxSize', nan(1, 3), ...
                'TimePoints', NaN, 'Mean4D', false, 'Source', '', 'Message', '', 'Ok', false);
        end

        function thr = defaultThresholds()
            thr = struct('T1Min', 3, 'FunMin', 3, 'NormMin', 3, ...
                'UseT1', true, 'UseFun', true, 'UseNorm', true, ...
                'MaxMeanFD', 0.2, 'UseMeanFD', false);
        end

        function thr = mergeThresholds(thr, override)
            % 用 override 中的合法字段覆盖默认阈值结构
            if isempty(override) || ~isstruct(override)
                return;
            end
            mins = {'T1Min', 'FunMin', 'NormMin'};
            uses = {'UseT1', 'UseFun', 'UseNorm'};
            for i = 1:numel(mins)
                if isfield(override, mins{i})
                    v = override.(mins{i});
                    if isnumeric(v) && isscalar(v) && isfinite(v)
                        thr.(mins{i}) = min(max(round(double(v)), 1), 5);
                    end
                end
            end
            for i = 1:numel(uses)
                if isfield(override, uses{i})
                    v = override.(uses{i});
                    if (islogical(v) || isnumeric(v)) && isscalar(v) && ~isempty(v)
                        thr.(uses{i}) = logical(v);
                    end
                end
            end
            if isfield(override, 'MaxMeanFD')
                v = override.MaxMeanFD;
                if isnumeric(v) && isscalar(v) && isfinite(v) && v >= 0
                    thr.MaxMeanFD = double(v);
                end
            end
            if isfield(override, 'UseMeanFD')
                v = override.UseMeanFD;
                if (islogical(v) || isnumeric(v)) && isscalar(v) && ~isempty(v)
                    thr.UseMeanFD = logical(v);
                end
            end
        end

        % ---------- 键名/路径 ----------

        function k = canonKey(key)
            % 模态键归一化为 'T1' | 'Fun' | 'Norm'（缺省 T1）
            k = 'T1';
            if nargin < 1 || isempty(key)
                return;
            end
            try
                s = lower(strtrim(char(key)));
            catch
                return;
            end
            switch s
                case {'t1', 'rawt1', 'rawt1imgqc', 't1img'}
                    k = 'T1';
                case {'fun', 'funmean', 'rawfun', 'rawfunimgqc', 'functional', 'funimg'}
                    k = 'Fun';
                case {'norm', 'normalization', 'normalizationqc', 'normalize', '标准化'}
                    k = 'Norm';
                otherwise
                    k = 'T1';
            end
        end

        function name = tsvName(key)
            switch mrw.QcModel.canonKey(key)
                case 'Fun'
                    name = 'RawFunImgQC.tsv';
                case 'Norm'
                    name = 'NormalizationQC.tsv';
                otherwise
                    name = 'RawT1ImgQC.tsv';
            end
        end

        function p = absPath(p)
            % 相对路径补全为绝对路径；空输入返回 ''，非法类型返回 ''
            if isstring(p) && isscalar(p)
                p = char(p);
            end
            if ~ischar(p)
                p = '';
                return;
            end
            p = strtrim(p);
            if isempty(p)
                return;
            end
            isAbs = false;
            if numel(p) >= 2
                isAbs = (p(2) == ':') || (p(1) == '\' && p(2) == '\') || p(1) == '/';
            end
            if ~isAbs
                p = fullfile(pwd, p);
            end
        end

        function tf = isDirPath(p)
            tf = ~isempty(p) && exist(p, 'dir') == 7;
        end

        function p = templatePath(name)
            % 在 DPABI 安装目录中定位 Templates/<name>
            p = '';
            roots = {};
            try
                r = mrw.Dpabi.root();
                if ~isempty(r)
                    roots{end+1} = r; %#ok<AGROW>
                end
            catch
            end
            try
                w = which('DPABI.m');
                if ~isempty(w)
                    roots{end+1} = fileparts(w); %#ok<AGROW>
                end
            catch
            end
            roots = [roots, {'D:\Software\DPABI', 'C:\Software\DPABI', ...
                'D:\DPABI', 'C:\DPABI'}]; %#ok<AGROW>
            for i = 1:numel(roots)
                if isempty(roots{i})
                    continue;
                end
                f = fullfile(roots{i}, 'Templates', name);
                if exist(f, 'file') == 2
                    p = f;
                    return;
                end
            end
        end

        % ---------- 受试者/文件发现 ----------

        function ids = scanSubjectDirs(workDir)
            % 从 DPARSF 常见数据目录收集受试者子目录名
            roots = {'T1Img', 'RealignParameter', 'T1ImgNewSegment', ...
                'T1ImgSegment', 'FunImg', 'FunRawImg', 'T1RawImg', 'T1Raw'};
            ids = {};
            for i = 1:numel(roots)
                d = fullfile(workDir, roots{i});
                if exist(d, 'dir') ~= 7
                    continue;
                end
                e = dir(d);
                for j = 1:numel(e)
                    if e(j).isdir && ~strcmp(e(j).name, '.') && ~strcmp(e(j).name, '..')
                        ids{end+1} = e(j).name; %#ok<AGROW>
                    end
                end
            end
            ids = mrw.QcModel.uniqueStable(ids);
        end

        function ids = scanTsvIds(workDir)
            % 从已有 QC TSV 推断受试者（用于 fill Missing）
            ids = {};
            names = {'RawT1ImgQC.tsv', 'RawFunImgQC.tsv', 'NormalizationQC.tsv'};
            for i = 1:numel(names)
                f = fullfile(workDir, 'QC', names{i});
                if exist(f, 'file') ~= 2
                    continue;
                end
                rows = mrw.QcModel.readScoreRows(f);
                for j = 1:numel(rows)
                    ids{end+1} = rows(j).ID; %#ok<AGROW>
                end
            end
            ids = mrw.QcModel.uniqueStable(ids);
        end

        function tf = subjectAvailable(workDir, key, id)
            switch key
                case 'T1'
                    tf = ~isempty(mrw.QcModel.t1File(workDir, id));
                case 'Fun'
                    tf = ~isempty(mrw.QcModel.funFile(workDir, id));
                otherwise
                    tf = ~isempty(mrw.QcModel.normCandidates(workDir, id));
            end
        end

        function f = t1File(workDir, id)
            % T1 原始像：T1Img/<subj>/c*.nii* → *Crop*.nii* → *.nii* → .img
            f = '';
            folder = fullfile(workDir, 'T1Img', id);
            if exist(folder, 'dir') ~= 7
                return;
            end
            f = mrw.QcModel.pickFirst(folder, {'c*.nii', 'c*.nii.gz', 'c*.img', 'c*.hdr'});
            if ~isempty(f)
                return;
            end
            f = mrw.QcModel.pickFirst(folder, {'*Crop*.nii', '*Crop*.nii.gz', ...
                '*Crop*.img', '*Crop*.hdr'});
            if ~isempty(f)
                return;
            end
            f = mrw.QcModel.pickFirst(folder, {'*.nii', '*.nii.gz', '*.img', '*.hdr'});
        end

        function [f, kind, computedMean, msg] = funFile(workDir, id)
            % 功能像：RealignParameter/<subj>/mean*（DPARSF 的 RawFunImgQC 用它）；
            % 否则 FunImg/<subj> 的 4D 原始像（读取时自动时间平均）。
            f = '';
            kind = '';
            computedMean = false;
            msg = '';
            folder = fullfile(workDir, 'RealignParameter', id);
            if exist(folder, 'dir') == 7
                f = mrw.QcModel.pickFirst(folder, {'mean*.nii', 'mean*.nii.gz', ...
                    'mean*.img', 'mean*.hdr'});
            end
            if ~isempty(f)
                kind = 'FunMean';
                return;
            end
            funDirs = {'FunImg', 'FunRawImg'};
            for i = 1:numel(funDirs)
                folder = fullfile(workDir, funDirs{i}, id);
                if exist(folder, 'dir') ~= 7
                    continue;
                end
                f = mrw.QcModel.pickFirst(folder, {'*.nii', '*.nii.gz', '*.img', '*.hdr'});
                if ~isempty(f)
                    kind = 'Fun4DMean';
                    computedMean = true;
                    msg = '未找到 RealignParameter/mean*，将自动计算功能像时间平均。';
                    return;
                end
            end
            msg = '未找到功能平均像（RealignParameter/<受试者>/mean*）或 FunImg 4D 数据。';
        end

        function C = normCandidates(workDir, id)
            % 标准化 QC 子图：wFun（wmean*）> wT1（w*，排除 wc*）> wGM（wc1*）
            C = struct('Which', {}, 'File', {});
            folder = fullfile(workDir, 'RealignParameter', id);
            f = mrw.QcModel.pickFirst(folder, {'wmean*.nii', 'wmean*.nii.gz', ...
                'wmean*.img', 'wmean*.hdr'});
            if ~isempty(f)
                C(end+1) = struct('Which', 'Fun', 'File', f); %#ok<AGROW>
            end
            folder = mrw.QcModel.segFolder(workDir, id);
            if isempty(folder)
                return;
            end
            f = mrw.QcModel.pickWFile(folder);
            if ~isempty(f)
                C(end+1) = struct('Which', 'T1', 'File', f); %#ok<AGROW>
            end
            f = mrw.QcModel.pickFirst(folder, {'wc1*.nii', 'wc1*.nii.gz', ...
                'wc1*.img', 'wc1*.hdr'});
            if ~isempty(f)
                C(end+1) = struct('Which', 'GM', 'File', f); %#ok<AGROW>
            end
        end

        function folder = segFolder(workDir, id)
            % 分割目录：优先 T1ImgNewSegment，其次 T1ImgSegment
            folder = '';
            names = {'T1ImgNewSegment', 'T1ImgSegment'};
            for i = 1:numel(names)
                f = fullfile(workDir, names{i}, id);
                if exist(f, 'dir') == 7
                    folder = f;
                    return;
                end
            end
        end

        function f = pickFirst(folder, patterns)
            % 按 patterns 顺序返回第一个匹配文件（同一 pattern 内按名称排序）
            f = '';
            if isempty(folder) || exist(folder, 'dir') ~= 7
                return;
            end
            for i = 1:numel(patterns)
                d = dir(fullfile(folder, patterns{i}));
                names = {};
                for j = 1:numel(d)
                    if d(j).isdir
                        continue;
                    end
                    names{end+1} = d(j).name; %#ok<AGROW>
                end
                if isempty(names)
                    continue;
                end
                [~, order] = sort(lower(names));
                f = fullfile(folder, names{order(1)});
                return;
            end
        end

        function f = pickWFile(folder)
            % 在分割目录中挑 wT1（w* 且排除 wc1/wc2/wc3）
            f = '';
            if isempty(folder) || exist(folder, 'dir') ~= 7
                return;
            end
            patterns = {'w*.nii', 'w*.nii.gz', 'w*.img', 'w*.hdr'};
            for i = 1:numel(patterns)
                d = dir(fullfile(folder, patterns{i}));
                names = {};
                for j = 1:numel(d)
                    if d(j).isdir
                        continue;
                    end
                    nm = d(j).name;
                    if ~isempty(regexpi(nm, '^wc', 'once'))
                        continue;   % 排除灰质/白质/脑脊液 wc*
                    end
                    names{end+1} = nm; %#ok<AGROW>
                end
                if isempty(names)
                    continue;
                end
                [~, order] = sort(lower(names));
                f = fullfile(folder, names{order(1)});
                return;
            end
        end

        % ---------- 排序/去重 ----------

        function c = uniqueStable(c)
            if isempty(c)
                c = {};
                return;
            end
            c = c(:).';
            out = {};
            for i = 1:numel(c)
                s = char(c{i});
                if isempty(s)
                    continue;
                end
                dup = false;
                for j = 1:numel(out)
                    if strcmp(out{j}, s)
                        dup = true;
                        break;
                    end
                end
                if ~dup
                    out{end+1} = s; %#ok<AGROW>
                end
            end
            c = out;
        end

        function c = naturalSort(c)
            % 自然排序：Sub2 在 Sub10 之前
            c = mrw.QcModel.uniqueStable(c);
            if numel(c) <= 1
                return;
            end
            keys = cell(1, numel(c));
            for i = 1:numel(c)
                keys{i} = mrw.QcModel.naturalKey(char(c{i}));
            end
            [~, order] = sort(keys);
            c = c(order);
        end

        function k = naturalKey(s)
            parts = regexp(char(s), '\d+|\D+', 'match');
            k = '';
            for i = 1:numel(parts)
                p = parts{i};
                if ~isempty(regexp(p, '^\d+$', 'once'))
                    k = [k sprintf('%012d', str2double(p))]; %#ok<AGROW>
                else
                    k = [k lower(p)]; %#ok<AGROW>
                end
            end
        end

        % ---------- 图像读取辅助 ----------

        function [vol, hdr, nTp, mean4d] = finalizeVolume(D, H, filePath)
            % 统一 3D/4D 处理：4D 按最后一维（时间）平均；统一 hdr
            if isempty(D)
                error('读取结果为空');
            end
            sz = size(D);
            while numel(sz) < 3
                sz(end+1) = 1; %#ok<AGROW>
            end
            mean4d = false;
            nTp = 1;
            if numel(sz) > 3
                extra = prod(sz(4:end));
                if extra > 1
                    nTp = extra;
                    D = reshape(D, sz(1), sz(2), sz(3), nTp);
                    vol = mean(double(D), 4);
                    mean4d = true;
                else
                    D = reshape(D, sz(1), sz(2), sz(3));
                    vol = double(D);
                end
            else
                vol = double(D);
            end
            vol = double(vol);
            hdr = mrw.QcModel.headerFrom(H, size(vol));
            hdr.File = filePath;
        end

        function hdr = headerFrom(H, dims)
            % 从 SPM/y_Read 头构造契约要求的 hdr（.mat/.dim/.voxSize）
            hdr = mrw.QcModel.emptyHdr();
            hdr.dim = double(dims(1:3));
            M = [];
            if isstruct(H) && isfield(H, 'mat') && isnumeric(H.mat) && ...
                    isequal(size(H.mat), [4 4]) && all(isfinite(H.mat(:)))
                M = double(H.mat);
            elseif isstruct(H) && isfield(H, 'Transform') && isnumeric(H.Transform) && ...
                    isequal(size(H.Transform), [4 4]) && all(isfinite(H.Transform(:)))
                M = double(H.Transform);
            end
            if isempty(M)
                return;
            end
            hdr.mat = M;
            vs = sqrt(sum(M(1:3, 1:3) .^ 2, 1));
            hdr.voxSize = max(vs, 0);
        end

        function M = hdrMat(hdr)
            % 提取有效 4x4 图像仿射；无效返回 []
            M = [];
            if ~isstruct(hdr) || ~isfield(hdr, 'mat') || ~isnumeric(hdr.mat)
                return;
            end
            if ~isequal(size(hdr.mat), [4 4]) || ~all(isfinite(hdr.mat(:)))
                return;
            end
            M = double(hdr.mat);
        end

        function info = fillVolumeInfo(info, vol, hdr, nTp, mean4d, source)
            info.Dim = double(size(vol));
            info.VoxSize = hdr.voxSize;
            info.TimePoints = nTp;
            info.Mean4D = logical(mean4d);
            info.Source = source;
            info.Message = '';
            info.Ok = true;
        end

        function M = niftiTransform(ni)
            % niftiread 兜底路径的仿射（尽量换算为 1-based 体素→mm）
            % R2026a 的 niftiinfo.Transform 可能是 affine3d 对象而非 4x4 数值，
            % 这里统一尝试多种形式；全部失败返回 []。
            M = [];
            if ~isstruct(ni)
                return;
            end
            if isfield(ni, 'Transform')
                T = ni.Transform;
                M = mrw.QcModel.asAffine4(T);
                if ~isempty(M)
                    return;
                end
            end
            if isfield(ni, 'Sform') && isstruct(ni.Sform)
                T = zeros(4);
                try
                    T(1, :) = double(ni.Sform.SrowX);
                    T(2, :) = double(ni.Sform.SrowY);
                    T(3, :) = double(ni.Sform.SrowZ);
                    T(4, 4) = 1;
                catch
                    T = zeros(4);
                end
                if isequal(size(T), [4 4]) && all(isfinite(T(:))) && any(T(:))
                    % NIfTI sform 用 0-based 体素坐标；换算成 SPM 的 1-based 约定
                    M = T;
                    M(1:3, 4) = M(1:3, 4) - M(1:3, 1:3) * [1; 1; 1];
                    return;
                end
            end
            if isfield(ni, 'PixelDimensions') && numel(ni.PixelDimensions) >= 3
                pd = double(ni.PixelDimensions(1:3));
                if all(isfinite(pd)) && all(pd > 0)
                    M = diag([pd, 1]);
                end
            end
        end

        function M = asAffine4(T)
            % 把 affine2d/affine3d 对象或 4x4 数值统一成 4x4 double
            M = [];
            if isempty(T)
                return;
            end
            if isnumeric(T) && isequal(size(T), [4 4]) && all(isfinite(T(:)))
                M = double(T);
                return;
            end
            try
                if isprop(T, 'T')
                    cand = double(T.T);
                    if isequal(size(cand), [4 4]) && all(isfinite(cand(:)))
                        M = cand;
                        return;
                    end
                end
            catch
            end
            try
                if isfield(T, 'T')
                    cand = double(T.T);
                    if isequal(size(cand), [4 4]) && all(isfinite(cand(:)))
                        M = cand;
                    end
                end
            catch
            end
        end

        function M = niftiSformFromFile(p)
            % 从 NIfTI-1 头字节直接读取 sform（1-based 换算），作为最后的兜底
            M = [];
            fid = fopen(p, 'r');
            if fid < 0
                return;
            end
            try
                raw = fread(fid, 348, 'uint8=>double');
                if numel(raw) < 348
                    fclose(fid);
                    return;
                end
                fclose(fid);
                marker = raw(1) + 256 * raw(2) + 65536 * raw(3) + 16777216 * raw(4);
                if marker ~= 348
                    return;   % 只处理小端 NIfTI-1
                end
                sformCode = raw(255) + 256 * raw(256);      % 偏移 254（0-based）
                if raw(255) > 127, sformCode = sformCode - 65536; end
                if sformCode <= 0
                    return;
                end
                srow = typecast(uint8(raw(281:328)), 'single');   % 偏移 280 起 12 个 float32
                T = double(reshape(srow, 4, 3).');
                T = [T; 0 0 0 1];
                if ~all(isfinite(T(:)))
                    return;
                end
                % NIfTI sform 为 0-based 体素坐标；SPM 约定为 1-based
                T(1:3, 4) = T(1:3, 4) - T(1:3, 1:3) * [1; 1; 1];
                M = T;
            catch
                try, fclose(fid); catch, end %#ok<CTCH>
            end
        end

        function [q, tmpDir] = gunzipToTemp(p)
            % 解压 .gz 到临时目录（niftiread 兜底时使用）
            tmpDir = tempname();
            mkdir(tmpDir);
            res = gunzip(p, tmpDir);
            q = '';
            if ischar(res) && exist(res, 'file') == 2
                q = res;
            elseif iscell(res)
                for i = 1:numel(res)
                    if ischar(res{i}) && exist(res{i}, 'file') == 2
                        q = res{i};
                        break;
                    end
                end
            elseif isstring(res) && ~isempty(res)
                q = char(res(1));
            end
            if isempty(q)
                d = dir(tmpDir);
                d = d(~[d.isdir] & ~ismember({d.name}, {'.', '..'}));
                if isempty(d)
                    error('解压 .gz 后未找到文件：%s', p);
                end
                q = fullfile(tmpDir, d(1).name);
            end
        end

        function removeDir(p)
            if isempty(p) || exist(p, 'dir') ~= 7
                return;
            end
            try
                rmdir(p, 's');
            catch
            end
        end

        % ---------- 切片/轮廓辅助 ----------

        function [o, total, letter, labelEn] = orientationInfo(orientation, dims)
            % 方向归一化；dims 为 1x3（非法时用 1 兜底）
            if nargin < 2 || numel(dims) < 3 || any(~isfinite(dims(1:3)))
                dims = [1 1 1];
            end
            dims = abs(round(double(dims(1:3))));
            dims(dims < 1) = 1;
            s = '';
            if ischar(orientation)
                s = lower(strtrim(orientation));
            elseif isstring(orientation) && isscalar(orientation)
                s = lower(strtrim(char(orientation)));
            end
            switch s
                case {'coronal', '冠状', '冠位', 'cor'}
                    o = 'coronal';
                    total = dims(2);
                    letter = 'y';
                    labelEn = 'Coronal';
                case {'sagittal', '矢状', '矢位', 'sag'}
                    o = 'sagittal';
                    total = dims(1);
                    letter = 'x';
                    labelEn = 'Sagittal';
                otherwise
                    o = 'axial';
                    total = dims(3);
                    letter = 'z';
                    labelEn = 'Axial';
            end
        end

        function T = templateData()
            % 加载并缓存 DPABI Edge 模板及其仿射/插值器（persistent）
            persistent cache
            if ~isempty(cache) && isfield(cache, 'ok') && cache.ok
                T = cache;
                return;
            end
            cache = struct('ok', false, 'vol', [], 'mat', eye(4), ...
                'invMat', eye(4), 'F', [], 'msg', '');
            p = mrw.QcModel.mniEdgeFile();
            if isempty(p)
                cache.msg = '未找到 DPABI Templates/Edge_mni_icbm152_AllTissues_tal_nlin_asym_09c_YCG.nii';
                T = cache;
                return;
            end
            try
                [vol, hdr, info] = mrw.QcModel.loadVolume(p);
                if isempty(vol)
                    error('%s', info.Message);
                end
                cache.vol = single(vol);
                cache.mat = double(hdr.mat);
                cache.invMat = inv(cache.mat);
                cache.F = griddedInterpolant({1:size(vol, 1), 1:size(vol, 2), ...
                    1:size(vol, 3)}, cache.vol, 'linear', 'none');
                cache.ok = true;
            catch err
                cache.ok = false;
                cache.msg = sprintf('读取 DPABI 边缘模板失败：%s', err.message);
            end
            T = cache;
        end

        % ---------- TSV 读写辅助 ----------

        function rows = readScoreRows(filePath)
            % 解析 DPARSF 兼容评分 TSV（容错：坏行跳过）
            rows = mrw.QcModel.emptyScores();
            if isempty(filePath) || exist(filePath, 'file') ~= 2
                return;
            end
            try
                lines = mrw.QcModel.readLines(filePath);
            catch
                return;
            end
            for i = 1:numel(lines)
                ln = lines{i};
                if i == 1
                    if ~isempty(ln) && double(ln(1)) == 65279   % UTF-8 BOM
                        ln = ln(2:end);
                    end
                    if isempty(strtrim(ln))
                        continue;
                    end
                    low = lower(strtrim(ln));
                    if ~isempty(strfind(low, 'subject')) || ...
                            ~isempty(strfind(low, 'qc score')) %#ok<STREMP>
                        continue;   % 表头
                    end
                end
                ln = strtrim(ln);
                if isempty(ln)
                    continue;
                end
                parts = strsplit(ln, sprintf('\t'));
                if numel(parts) < 2
                    continue;
                end
                sid = strtrim(parts{1});
                if isempty(sid)
                    continue;
                end
                if strcmpi(sid, 'Subject ID') || strcmpi(sid, 'subject')
                    continue;
                end
                row = struct('ID', sid, 'Score', NaN, 'Comment', '');
                sv = str2double(strtrim(parts{2}));
                if isfinite(sv)
                    row.Score = sv;
                end
                if numel(parts) >= 3
                    row.Comment = strtrim(strjoin(parts(3:end), sprintf('\t')));
                end
                rows(end+1) = row; %#ok<AGROW>
            end
        end

        function ok = writeScoreRows(filePath, rows)
            % 按 DPARSF 格式写评分 TSV（Tab 分隔、UTF-8、首行表头）
            ok = false;
            fid = -1;
            try
                fid = fopen(filePath, 'w', 'n', 'UTF-8');
                if fid < 0
                    return;
                end
                fprintf(fid, 'Subject ID\tQC Score\tQC Comment\n');
                for i = 1:numel(rows)
                    sid = char(rows(i).ID);
                    sc = rows(i).Score;
                    if isfinite(sc)
                        scStr = sprintf('%g', sc);
                    else
                        scStr = 'NaN';
                    end
                    cmt = mrw.QcModel.sanitizeComment(rows(i).Comment);
                    fprintf(fid, '%s\t%s\t%s\n', sid, scStr, cmt);
                end
                fclose(fid);
                fid = -1;
                ok = true;
            catch
                if fid >= 0
                    try, fclose(fid); catch, end %#ok<CTCH>
                end
                ok = false;
            end
        end

        function lines = readLines(filePath)
            % UTF-8 优先、系统编码兜底地读取文本行
            lines = {};
            if isempty(filePath) || exist(filePath, 'file') ~= 2
                return;
            end
            try
                lines = mrw.QcModel.readLinesWithEncoding(filePath, 'UTF-8');
            catch
                lines = {};
                return;
            end
            txt = strjoin(lines, sprintf('\n'));
            if any(double(txt) == 65533)   % U+FFFD：说明不是 UTF-8
                try
                    alt = mrw.QcModel.readLinesWithEncoding(filePath, '');
                    if ~isempty(alt)
                        lines = alt;
                    end
                catch
                end
            end
        end

        function lines = readLinesWithEncoding(filePath, encoding)
            lines = {};
            if isempty(encoding)
                fid = fopen(filePath, 'r');
            else
                fid = fopen(filePath, 'r', 'n', encoding);
            end
            if fid < 0
                error('无法打开文本文件：%s', filePath);
            end
            try
                while true
                    ln = fgetl(fid);
                    if ~ischar(ln)
                        break;
                    end
                    lines{end+1} = ln; %#ok<AGROW>
                end
                fclose(fid);
            catch err
                try, fclose(fid); catch, end %#ok<CTCH>
                rethrow(err);
            end
        end

        function txt = readText(filePath)
            lines = mrw.QcModel.readLines(filePath);
            txt = strjoin(lines, sprintf('\n'));
        end

        % ---------- 逐帧 FD 辅助 ----------

        function fd = emptyFdSeries()
            fd = struct('Available', false, 'ID', '', 'Type', 'FD_Jenkinson', ...
                'Values', zeros(1, 0), 'File', '', 'DefaultThreshold', 0.2, ...
                'Message', '');
        end

        function [type, thr, msg] = fdTypeInfo(fdType)
            % FD 类型归一化 + 默认坏帧阈值（Jenkinson/VanDijk 0.2，Power 0.5）
            type = 'FD_Jenkinson';
            thr = 0.2;
            msg = '';
            s = '';
            try
                if ischar(fdType)
                    s = lower(strtrim(fdType));
                elseif isstring(fdType) && isscalar(fdType)
                    s = lower(strtrim(char(fdType)));
                elseif ~isempty(fdType)
                    s = lower(strtrim(char(fdType)));
                end
            catch
                s = '';
            end
            s = strrep(strrep(s, ' ', ''), '-', '_');
            switch s
                case {'', 'fd_jenkinson', 'jenkinson', 'fdjenkinson'}
                    type = 'FD_Jenkinson';
                    thr = 0.2;
                case {'fd_power', 'power', 'fdpower'}
                    type = 'FD_Power';
                    thr = 0.5;
                case {'fd_vandijk', 'vandijk', 'van_dijk', 'fdvandijk'}
                    type = 'FD_VanDijk';
                    thr = 0.2;
                otherwise
                    msg = '无法识别的 FD 类型，已按 FD_Jenkinson 读取。';
            end
        end

        function f = fdValueFile(workDir, sid, type)
            % 在 RealignParameter/<ID>/ 与 RealignParameter/ 中定位逐帧 FD 文件
            f = '';
            f = mrw.QcModel.fdLookupIn(fullfile(workDir, 'RealignParameter', sid), type, sid);
            if isempty(f)
                f = mrw.QcModel.fdLookupIn(fullfile(workDir, 'RealignParameter'), type, sid);
            end
        end

        function f = fdLookupIn(folder, type, sid)
            % 先精确名，再同目录同类型文件中「文件名包含受试者 ID」的通配兜底；
            % 避免同目录有多个受试者 FD 文件时把别人的文件当成该受试者的。
            f = '';
            if exist(folder, 'dir') ~= 7
                return;
            end
            exact = fullfile(folder, sprintf('%s_%s.txt', type, sid));
            if exist(exact, 'file') == 2
                f = exact;
                return;
            end
            d = dir(fullfile(folder, [type '*.txt']));
            names = {};
            for j = 1:numel(d)
                if d(j).isdir
                    continue;
                end
                names{end+1} = d(j).name; %#ok<AGROW>
            end
            if isempty(names)
                return;
            end
            [~, order] = sort(lower(names));
            names = names(order);
            for j = 1:numel(names)
                if ~isempty(strfind(lower(names{j}), lower(sid)))
                    f = fullfile(folder, names{j});
                    return;
                end
            end
            if numel(names) == 1
                f = fullfile(folder, names{1});
            end
        end

        function vals = readFdValues(filePath)
            % 解析逐帧 FD 文本（每行/每列一个数值；容错空白与逗号/分号分隔）
            vals = zeros(1, 0);
            if isempty(filePath) || exist(filePath, 'file') ~= 2
                return;
            end
            try
                lines = mrw.QcModel.readLines(filePath);
            catch
                return;
            end
            out = zeros(1, 0);
            for i = 1:numel(lines)
                ln = strtrim(lines{i});
                if isempty(ln)
                    continue;
                end
                parts = regexp(ln, '[,\s;]+', 'split');
                parts = parts(~cellfun(@isempty, parts));
                for j = 1:numel(parts)
                    v = str2double(parts{j});
                    if isfinite(v)
                        out(end+1) = v; %#ok<AGROW>
                    end
                end
            end
            vals = out(:).';
        end

        function c = sanitizeComment(c)
            % 评语不能包含 Tab/换行（保证 TSV 每行 3 列）
            if isstring(c) && isscalar(c)
                c = char(c);
            end
            if ~ischar(c)
                c = '';
                return;
            end
            c = strrep(c, sprintf('\r\n'), ' ');
            c = strrep(c, sprintf('\n'), ' ');
            c = strrep(c, sprintf('\r'), ' ');
            c = strrep(c, sprintf('\t'), ' ');
            c = strtrim(c);
        end
    end
end
