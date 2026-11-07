classdef T1Compat
%T1COMPAT T1 结构像裁剪兼容处理（旧版 dcm2nii 真实裁剪 / 免裁剪直通）
%
% 背景（2026-11 实测）：DPABI 自 191121 起把「结构像重定向+裁剪」改为调用
% dcm2niix，而 dcm2niix 只接受 DICOM 输入。当 T1Img/<受试者>/ 里只有
% T1.nii（NIfTI）时，裁剪步骤不会生成 c*/co*，随后 DPARSFA_run 在 BET /
% 分割/标准化阶段用 questdlg 询问「是否使用未裁剪的 T1」；无界面运行无法
% 弹窗，直接报错退出（DPARSFA_run.m 第 1641 行附近）。
%
% 工作台提供两种「运行前」兼容模式（Cfg.T1CropCompat）：
%   auto         不干预，保持 DPARSF 默认行为；
%   old_dcm2nii  使用 DPABI 自带的旧版 dcm2nii.exe（Chris Rorden 2016，
%                支持 NIfTI 输入）对 T1 做重定向+裁剪，真实生成 c*/co*；
%   no_crop      不做裁剪：把原始 T1 复制为 c* 直通文件（不重定向/去颈），
%                让 DPARSF 认为已有裁剪结果继续运行（分割质量需人工 QC）。
%
% 两种非 auto 模式都会把 Cfg.IsNeedReorientCropT1Img 置 0，避免 DPARSF
% 再次用 dcm2niix 重跑裁剪；Cfg.T1CropCompat 本身是工作台字段，调用方在
% 传给 DPARSFA_run 前应删除（DPARSF 不识别）。
%
% 用法（headlessRunner 在 DPARSFA_run 之前执行）：
%   [Cfg, msgs] = mrw.T1Compat.apply(Cfg, @(m) fprintf('[工作台] %s\n', m));

    properties (Constant)
        MODES = {'auto', 'old_dcm2nii', 'no_crop'};
        % 与 DPABI y_Call_dcm2nii 的裁剪调用保持一致（旧版 dcm2nii 参数：
        % -g N 不压缩 / -m N 不手工选择输出格式 / -n Y 输出 .nii /
        % -r Y 重定向 / -v N 不逐卷转换 / -x Y 重定向并裁剪 3D NIfTI）
        CROP_OPTION = '-g N -m N -n Y -r Y -v N -x Y';
    end

    methods (Static)
        function mode = normalizeMode(value)
            %NORMALIZEMODE 把任意输入归一化为 auto|old_dcm2nii|no_crop
            mode = 'auto';
            if isempty(value)
                return
            end
            if isstring(value) && isscalar(value)
                value = char(value);
            end
            if ~ischar(value)
                return
            end
            v = lower(strtrim(value));
            v = strrep(v, '-', '_');
            switch v
                case {'old_dcm2nii', 'old', 'dcm2nii', 'old_dcm2nii_crop'}
                    mode = 'old_dcm2nii';
                case {'no_crop', 'nocrop', 'skip_crop', 'uncropped', 'passthrough'}
                    mode = 'no_crop';
                otherwise
                    mode = 'auto';
            end
        end

        function label = labelOf(mode)
            %LABELOF 模式中文短标签（用于页面/预检提示）
            switch mrw.T1Compat.normalizeMode(mode)
                case 'old_dcm2nii'
                    label = '旧版 dcm2nii';
                case 'no_crop'
                    label = '免裁剪';
                otherwise
                    label = '自动（DPARSF 默认）';
            end
        end

        function plan = planOf(mode)
            %PLANOF 运行前具体动作说明（auto 返回空串）
            switch mrw.T1Compat.normalizeMode(mode)
                case 'old_dcm2nii'
                    plan = '运行前对 NIfTI T1 重定向+裁剪生成 c*/co*，不依赖 dcm2niix';
                case 'no_crop'
                    plan = '运行前把未裁剪 T1 复制为 c* 直通文件（不重定向/去颈），分割质量需人工 QC';
                otherwise
                    plan = '';
            end
        end

        function exe = oldDcm2niiExe()
            %OLDDCM2NIIEXE DPABI 自带旧版 dcm2nii.exe 的绝对路径（不存在返回 ''）
            exe = '';
            dparsfDir = fileparts(which('DPARSFA_run.m'));
            if isempty(dparsfDir)
                return
            end
            p = fullfile(dparsfDir, 'dcm2nii', 'dcm2nii.exe');
            if exist(p, 'file') == 2
                exe = p;
            end
        end

        function tf = t1Needed(Cfg)
            %T1NEEDED 当前配置是否需要 T1 结构像链（与 CfgBuilder.validate 一致）
            get = @(f, d) mrw.T1Compat.fieldOr(Cfg, f, d);
            tf = logical(get('IsNeedT1CoregisterToFun', 0)) || ...
                double(get('IsSegment', 0)) > 0 || ...
                double(get('IsDARTEL', 0)) == 1 || ...
                double(get('IsBet', 0)) == 1 || ...
                double(get('IsApplyDownloadedReorientMats', 0)) == 1;
        end

        function tf = hasCroppedFile(t1dir)
            %HASCROPPEDFILE 目录内是否已有 DPARSF 认可的 c*/co*/*Crop* 文件
            tf = false;
            if exist(t1dir, 'dir') ~= 7
                return
            end
            patterns = {'c*.nii', 'c*.nii.gz', '*Crop*.nii', 'c*.img'};
            for k = 1:numel(patterns)
                if ~isempty(dir(fullfile(t1dir, patterns{k})))
                    tf = true;
                    return
                end
            end
        end

        function [Cfg, msgs] = apply(Cfg, logFcn)
            %APPLY 按 Cfg.T1CropCompat 执行运行前兼容处理
            %   [Cfg, msgs] = apply(Cfg) 或 apply(Cfg, @(msg) ...)
            %   返回更新后的 Cfg 与中文日志（调用方负责打印/记录）。
            if nargin < 2
                logFcn = [];
            end
            msgs = {};
            mode = 'auto';
            if isfield(Cfg, 'T1CropCompat')
                mode = mrw.T1Compat.normalizeMode(Cfg.T1CropCompat);
            end
            Cfg.T1CropCompat = mode;
            if strcmp(mode, 'auto')
                msgs = mrw.T1Compat.logLine(msgs, ...
                    'T1 裁剪兼容模式：自动（保持 DPARSF 默认裁剪流程，不干预）', logFcn);
                return
            end
            if ~mrw.T1Compat.t1Needed(Cfg)
                Cfg.IsNeedReorientCropT1Img = 0;
                msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                    'T1 裁剪兼容模式：%s；当前流程不需要 T1（未启用分割/配准/DARTEL/BET），已跳过。', ...
                    mode), logFcn);
                return
            end
            % T1Raw DICOM 转换路线由 dcm2niix 处理 DICOM 并自动生成 co*，无需本兼容层
            if double(mrw.T1Compat.fieldOr(Cfg, 'IsNeedConvertT1DCM2IMG', 0)) == 1
                Cfg.IsNeedReorientCropT1Img = 0;
                msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                    'T1 裁剪兼容模式：%s；检测到已启用 T1Raw DICOM 转换（转换阶段会自动生成 co*），本兼容模式跳过。', ...
                    mode), logFcn);
                return
            end

            dpd = Cfg.WorkingDir;
            if isfield(Cfg, 'DataProcessDir') && ~isempty(Cfg.DataProcessDir)
                dpd = Cfg.DataProcessDir;
            end
            ids = Cfg.SubjectID;
            if ischar(ids)
                ids = {ids};
            end
            if isempty(ids)
                error('T1 裁剪兼容：受试者列表为空，无法处理 T1Img。');
            end
            t1Root = fullfile(dpd, 'T1Img');
            if exist(t1Root, 'dir') ~= 7
                error('T1 裁剪兼容：找不到 T1Img 目录（%s）。若使用 T1Raw DICOM 转换，请先关闭本兼容模式。', t1Root);
            end

            % 兼容处理完成后再交给 DPARSF：关闭 DPARSF 自己的裁剪步骤（dcm2niix）
            Cfg.IsNeedReorientCropT1Img = 0;
            if strcmp(mode, 'old_dcm2nii')
                exe = mrw.T1Compat.oldDcm2niiExe();
                if isempty(exe)
                    error(['T1 裁剪兼容：未找到 DPABI 自带的旧版 dcm2nii.exe（<DPABI>/DPARSF/dcm2nii/dcm2nii.exe）。' ...
                        '请检查 DPABI 安装，或改用“免裁剪”模式。']);
                end
                msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                    'T1 裁剪兼容：使用旧版 dcm2nii 对 NIfTI T1 重定向+裁剪（%s）', exe), logFcn);
                for i = 1:numel(ids)
                    id = char(ids{i});
                    t1dir = fullfile(t1Root, id);
                    if exist(t1dir, 'dir') ~= 7
                        error('T1 裁剪兼容：受试者 %s 缺少 T1Img 目录（%s）。', id, t1dir);
                    end
                    if mrw.T1Compat.hasCroppedFile(t1dir)
                        msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                            '  · %s：已有 c*/Crop 文件，跳过裁剪', id), logFcn);
                        continue
                    end
                    [files, names] = mrw.T1Compat.t1Files(t1dir);
                    if isempty(files)
                        error('T1 裁剪兼容：受试者 %s 的 T1Img 目录中没有 T1 NIfTI 文件。', id);
                    end
                    if numel(files) > 1
                        error('T1 裁剪兼容：受试者 %s 的 T1Img 目录中有 %d 个 T1 文件（%s），无法确定裁剪对象；请只保留一个。', ...
                            id, numel(files), strjoin(names, '、'));
                    end
                    [newFile, out] = mrw.T1Compat.runOldDcm2niiCrop(exe, files{1}, t1dir);
                    if isempty(newFile)
                        tail = strtrim(out);
                        if numel(tail) > 600
                            tail = tail(max(1, numel(tail) - 600):end);
                        end
                        error('T1 裁剪兼容：受试者 %s 用旧版 dcm2nii 裁剪后仍未生成 c* 文件。命令输出：\n%s', id, tail);
                    end
                    msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                        '  · %s：已生成裁剪文件 %s', id, mrw.T1Compat.baseName(newFile)), logFcn);
                end
                msgs = mrw.T1Compat.logLine(msgs, ...
                    'T1 裁剪兼容：旧版 dcm2nii 处理完成；DPARSF 裁剪步骤已关闭，避免 dcm2niix 再次运行。', logFcn);
            else
                % no_crop：复制未裁剪 T1 为 c* 直通文件
                msgs = mrw.T1Compat.logLine(msgs, ...
                    'T1 裁剪兼容：免裁剪模式（不重定向/去颈，复制 T1 为 c* 直通文件）', logFcn);
                for i = 1:numel(ids)
                    id = char(ids{i});
                    t1dir = fullfile(t1Root, id);
                    if exist(t1dir, 'dir') ~= 7
                        error('T1 裁剪兼容：受试者 %s 缺少 T1Img 目录（%s）。', id, t1dir);
                    end
                    if mrw.T1Compat.hasCroppedFile(t1dir)
                        msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                            '  · %s：已有 c*/Crop 文件，跳过直通复制', id), logFcn);
                        continue
                    end
                    [files, names] = mrw.T1Compat.t1Files(t1dir);
                    if isempty(files)
                        error('T1 裁剪兼容：受试者 %s 的 T1Img 目录中没有 T1 NIfTI 文件。', id);
                    end
                    if numel(files) > 1
                        error('T1 裁剪兼容：受试者 %s 的 T1Img 目录中有 %d 个 T1 文件（%s），请只保留一个。', ...
                            id, numel(files), strjoin(names, '、'));
                    end
                    src = files{1};
                    [base, ext] = mrw.T1Compat.splitName(src);
                    dst = fullfile(t1dir, ['c' base ext]);
                    if exist(dst, 'file') == 2
                        error('T1 裁剪兼容：目标直通文件已存在但不符合 c* 命名检测，请检查：%s', dst);
                    end
                    [okCopy, msgCopy] = copyfile(src, dst);
                    if ~okCopy
                        error('T1 裁剪兼容：复制 T1 到 c* 失败（%s）：%s', msgCopy, dst);
                    end
                    msgs = mrw.T1Compat.logLine(msgs, sprintf( ...
                        '  · %s：已生成未裁剪直通文件 %s（未重定向/去颈，后续分割质量请人工 QC）', ...
                        id, mrw.T1Compat.baseName(dst)), logFcn);
                end
                msgs = mrw.T1Compat.logLine(msgs, ...
                    'T1 裁剪兼容：免裁剪直通处理完成；DPARSF 裁剪步骤已关闭。', logFcn);
            end
        end

        function [files, names] = t1Files(t1dir)
            %T1FILES 目录内可作为裁剪输入的 T1 文件（按 DPARSF 优先级：.nii.gz > .nii > .img）
            %   排除已有裁剪产物（c*/co*/*Crop*）与 BET/均值等派生文件。
            files = {};
            names = {};
            if exist(t1dir, 'dir') ~= 7
                return
            end
            patterns = {'*.nii.gz', '*.nii', '*.img'};
            for p = 1:numel(patterns)
                d = dir(fullfile(t1dir, patterns{p}));
                for k = 1:numel(d)
                    if d(k).isdir
                        continue
                    end
                    nm = d(k).name;
                    low = lower(nm);
                    if low(1) == 'c'
                        continue
                    end
                    if ~isempty(strfind(low, 'crop')) || ...
                            ~isempty(strfind(low, 'bet_')) || ...
                            ~isempty(strfind(low, 'mean'))
                        continue
                    end
                    files{end+1} = fullfile(t1dir, nm); %#ok<AGROW>
                    names{end+1} = nm; %#ok<AGROW>
                end
                if ~isempty(files)
                    return
                end
            end
        end

        function [newFile, output] = runOldDcm2niiCrop(exe, inputFile, outDir)
            %RUNOLDDCM2NICROP 调用旧版 dcm2nii 对单个 NIfTI T1 做重定向+裁剪
            %   旧版 dcm2nii 对 NIfTI 输入会把结果写在输入文件同目录（c<name>.nii）；
            %   返回本次新生成的 c* 文件路径与命令输出（失败时 newFile=''）。
            newFile = '';
            output = '';
            toolDir = fileparts(exe);
            workFile = inputFile;
            tempFile = '';
            if ~isempty(regexp(lower(inputFile), '\.nii\.gz$', 'once'))
                tempFile = mrw.T1Compat.gunzipToTemp(inputFile);
                workFile = tempFile;
            elseif ~isempty(regexp(lower(inputFile), '\.img$', 'once'))
                error('T1 裁剪兼容：暂不支持 Analyze(.img/.hdr) 格式的 T1，请先转换为 .nii。');
            end
            before = mrw.T1Compat.listCropped(outDir);
            oldDir = pwd;
            try
                cd(toolDir);
                cmd = sprintf('"%s" %s -o "%s" "%s"', exe, ...
                    mrw.T1Compat.CROP_OPTION, outDir, workFile);
                [status, output] = system(cmd);
            catch err
                cd(oldDir);
                mrw.T1Compat.removeTemp(tempFile);
                rethrow(err);
            end
            cd(oldDir);
            if ~isnumeric(status)
                status = -1;
            end
            after = mrw.T1Compat.listCropped(outDir);
            newOnes = setdiff(after, before);
            if isempty(newOnes)
                % 有些 dcm2nii 版本会覆盖同名 c* 文件：退化为检查是否已有 c*
                if mrw.T1Compat.hasCroppedFile(outDir)
                    [cand, ~] = mrw.T1Compat.firstCropped(outDir);
                    newFile = cand;
                elseif ~isempty(regexp(output, 'no need to delete slices|Crop 3D quitting', 'once'))
                    % dcm2nii 判断无需裁剪（图像已紧贴脑边界）：直接把该 T1 复制为
                    % c* 直通文件，保证 DPARSF 能找到裁剪产物（与“无需裁剪”语义一致）。
                    [base, ext] = mrw.T1Compat.splitName(workFile);
                    dst = fullfile(outDir, ['c' base ext]);
                    [okCopy, ~] = copyfile(workFile, dst);
                    if okCopy
                        newFile = dst;
                        output = [output sprintf('\n[工作台] dcm2nii 判断无需裁剪，已把 T1 复制为 %s', ...
                            mrw.T1Compat.baseName(dst))];
                    end
                end
            else
                newFile = fullfile(outDir, newOnes{end});
            end
            mrw.T1Compat.removeTemp(tempFile);
        end

        function out = listCropped(t1dir)
            %LISTCROPPED 目录内 c*/co*/*Crop* 文件名（cellstr）
            out = {};
            if exist(t1dir, 'dir') ~= 7
                return
            end
            patterns = {'c*.nii', 'c*.nii.gz', '*Crop*.nii', 'c*.img'};
            for k = 1:numel(patterns)
                d = dir(fullfile(t1dir, patterns{k}));
                for j = 1:numel(d)
                    if ~d(j).isdir
                        out{end+1} = d(j).name; %#ok<AGROW>
                    end
                end
            end
            out = unique(out);
        end

        function [file, name] = firstCropped(t1dir)
            %FIRSTCROPPED 目录内第一个 c*/Crop 文件（排序后）
            file = '';
            name = '';
            names = mrw.T1Compat.sortNames(mrw.T1Compat.listCropped(t1dir));
            if isempty(names)
                return
            end
            name = names{1};
            file = fullfile(t1dir, name);
        end

        function p = gunzipToTemp(niiGz)
            %GUNZIPTOTEMP 把 .nii.gz 解压到同目录临时 .nii，返回临时文件路径
            [base, ~] = mrw.T1Compat.splitName(niiGz);
            outDir = fileparts(niiGz);
            target = fullfile(outDir, [base '.nii']);
            if exist(target, 'file') == 2
                % 已有同名 .nii：直接使用（可能是此前 gzip 的还原结果）
                p = target;
                return
            end
            gunzip(niiGz);
            if exist(target, 'file') ~= 2
                error('T1 裁剪兼容：解压 .nii.gz 失败：%s', niiGz);
            end
            p = target;
        end
    end

    methods (Static, Access = private)
        function v = fieldOr(s, f, d)
            v = d;
            if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
                v = s.(f);
            end
        end

        function msgs = logLine(msgs, msg, logFcn)
            msgs{end+1} = msg;
            if ~isempty(logFcn)
                try
                    logFcn(msg);
                catch
                end
            end
        end

        function emit(logFcn, msg)
            if ~isempty(logFcn)
                try
                    logFcn(msg);
                catch
                end
            end
        end

        function names = sortNames(names)
            if isempty(names)
                return
            end
            try
                names = sort(names);
            catch
            end
        end

        function [base, ext] = splitName(fileName)
            %SPLITNAME 拆分文件名与扩展名（支持 .nii.gz）
            [~, name, ext] = fileparts(fileName);
            if strcmpi(ext, '.gz') && numel(name) > 4 && strcmpi(name(end-3:end), '.nii')
                base = name(1:end-4);
                ext = '.nii.gz';
            else
                base = name;
            end
        end

        function removeTemp(filePath)
            %REMOVETEMP 删除临时解压文件（不存在时静默）
            try
                if ~isempty(filePath) && exist(filePath, 'file') == 2
                    delete(filePath);
                end
            catch
            end
        end

        function n = baseName(fileName)
            [base, ext] = mrw.T1Compat.splitName(fileName);
            n = [base ext];
        end
    end
end
