classdef QcReorient
% QcReorient  把显示变换写入独立副本；原始文件始终只读。
    methods (Static)
        function result = apply(source, workDir, subject, viewInfo, method, resampled)
            if nargin < 5, method = 'header-only'; end
            if nargin < 6, resampled = struct(); end
            source = char(source); workDir = char(workDir); subject = char(subject);
            method = char(method);
            if ~ismember(method, {'header-only', 'resample'})
                error('QcReorient:Method', '写出方式必须是 header-only 或 resample。');
            end
            if exist(source, 'file') ~= 2 || exist(workDir, 'dir') ~= 7
                error('QcReorient:Path', '源图像或工作目录不存在。');
            end
            if isempty(subject) || ismember(subject, {'.', '..'}) || ...
                    ~isempty(regexp(subject, '[<>:"/\\|?*\x00-\x1f]', 'once')) || ...
                    ismember(subject(end), [' ' '.'])
                error('QcReorient:Subject', '受试者名称不能包含路径或非法文件名字符。');
            end
            if ~isstruct(viewInfo) || ~isfield(viewInfo, 'DisplayMatrix')
                error('QcReorient:Transform', '缺少当前显示变换矩阵。');
            end
            A = double(viewInfo.DisplayMatrix);
            mrw.QcReorient.validateMatrix(A);
            if isfield(viewInfo, 'IsNative') && viewInfo.IsNative
                error('QcReorient:Native', '原生显示没有待应用的变换；请先设置原点、配平或手动变换。');
            end
            [~, name, ext] = fileparts(source);
            compressed = strcmpi(ext, '.gz') && endsWith(lower(name), '.nii');
            paired = ismember(lower(ext), {'.img', '.hdr'});
            if ~(compressed || paired || strcmpi(ext, '.nii'))
                error('QcReorient:Format', '仅支持 .nii、.nii.gz 与 .img/.hdr 成对图像。');
            end
            source = char(java.io.File(source).getCanonicalPath());
            originals = mrw.QcReorient.sourceFiles(source, paired, compressed);
            before = mrw.QcReorient.summaries(originals);
            parent = fullfile(workDir, 'QC', 'Reorient', subject);
            if exist(parent, 'dir') ~= 7
                [ok, msg] = mkdir(parent);
                if ~ok, error('QcReorient:Output', '无法创建输出目录：%s', msg); end
            end
            stage = tempname(parent);
            [ok, msg] = mkdir(stage);
            if ~ok, error('QcReorient:Output', '无法创建暂存目录：%s', msg); end
            cleanup = onCleanup(@() mrw.QcReorient.removeStage(stage)); %#ok<NASGU>
            [~, unique] = fileparts(stage);
            runName = [datestr(now, 'yyyymmdd_HHMMSSFFF') '_' unique]; %#ok<TNOW1,DATST>
            outputDir = fullfile(parent, runName);
            for k = 1:numel(originals)
                [~, b, e] = fileparts(originals{k});
                copyfile(originals{k}, fullfile(stage, [b e]));
            end
            [~, b, e] = fileparts(source);
            stagedSource = fullfile(stage, [b e]);
            if compressed
                unpacked = gunzip(stagedSource, stage);
                stagedSource = unpacked{1};
            elseif paired
                stagedSource = fullfile(stage, [b '.img']);
            end
            volumes = spm_vol(stagedSource);
            if numel(volumes) ~= 1
                error('QcReorient:FourD', ['当前显示为四维数据的时间平均，不能隐式修改整个四维图像。' ...
                    '请先另存所需的三维图像。']);
            end
            input = nifti(stagedSource);
            pixels = double(input.dat);
            payloadBefore = mrw.QcReorient.hashFile(input.dat.fname, input.dat.offset);
            sourceMatrix = double(volumes.mat);
            sidecars = dir(fullfile(stage, '*.mat'));
            for k = 1:numel(sidecars), delete(fullfile(stage, sidecars(k).name)); end
            [~, imageBase, imageExt] = fileparts(stagedSource);
            if strcmp(method, 'header-only')
                targetMatrix = A * sourceMatrix;
                output = input;
                output.extras = struct();
                outName = [imageBase lower(imageExt)];
            else
                if ~isstruct(resampled) || ~isfield(resampled, 'Data') || ~isfield(resampled, 'Mat') || ...
                        ~isnumeric(resampled.Data) || ~isreal(resampled.Data) || ...
                        isempty(resampled.Data) || ndims(resampled.Data) > 3 || any(~isfinite(resampled.Data(:)))
                    error('QcReorient:Resample', '重采样数据无效；必须使用当前 QcView 显示网格。');
                end
                targetMatrix = double(resampled.Mat);
                outName = [imageBase '_resampled.nii'];
                output = nifti();
                output.dat = file_array(fullfile(stage, outName), size(resampled.Data), 'FLOAT32-LE', 352, 1, 0);
                output.descrip = 'MRI Workbench QC display-grid resampled copy';
            end
            mrw.QcReorient.validateMatrix(targetMatrix);
            R = targetMatrix(1:3, 1:3);
            R = R ./ sqrt(sum(R.^2, 1));
            if max(abs(R.' * R - eye(3)), [], 'all') >= 1e-6
                error('QcReorient:Shear', '此几何含剪切，qform 无法无损表示；请使用“重采样体素副本”。');
            end
            % SPM mat/mat0 接受 1-based；SPM 自行编码 0-based sform/qform。
            output.mat = targetMatrix;
            output.mat0 = targetMatrix;
            output.mat_intent = 'Aligned';
            output.mat0_intent = 'Aligned';
            [expectedSform, expectedQform, expectedZeroBased] = mrw.QcReorient.encodedGeometry(output);
            create(output);
            if strcmp(method, 'resample')
                output.dat(:,:,:) = single(resampled.Data);
                staged = dir(stage);
                for k = 1:numel(staged)
                    if ~staged(k).isdir && ~strcmp(staged(k).name, outName)
                        delete(fullfile(stage, staged(k).name));
                    end
                end
            end
            checkFile = fullfile(stage, outName);
            checkNifti = nifti(checkFile);
            checkVol = spm_vol(checkFile);
            mrw.QcReorient.validateMatrix(checkVol.mat);
            mrw.QcReorient.validateMatrix(checkNifti.mat0);
            matrixError = max(abs(checkVol.mat - targetMatrix), [], 'all');
            qformError = max(abs(checkNifti.mat0 - targetMatrix), [], 'all');
            sformReadbackError = max(abs(checkVol.mat - expectedSform), [], 'all');
            qformReadbackError = max(abs(checkNifti.mat0 - expectedQform), [], 'all');
            if sformReadbackError >= 1e-6 || qformReadbackError >= 1e-6
                error('QcReorient:Verify', '输出头与预期编码不一致，未发布输出。');
            end
            raw = checkNifti.hdr;
            if raw.sform_code == 0 || raw.qform_code == 0
                error('QcReorient:Verify', 'qform/sform 代码无效，未发布输出。');
            end
            formError = max(abs(checkNifti.mat - checkNifti.mat0), [], 'all');
            dims = size(pixels);
            if strcmp(method, 'resample'), dims = size(resampled.Data); end
            worldToleranceMm = 0.001;
            sformWorldError = mrw.QcReorient.cornerErrorMm(checkVol.mat, targetMatrix, dims);
            qformWorldError = mrw.QcReorient.cornerErrorMm(checkNifti.mat0, targetMatrix, dims);
            formWorldError = mrw.QcReorient.cornerErrorMm(checkNifti.mat, checkNifti.mat0, dims);
            if max([sformWorldError, qformWorldError, formWorldError]) > worldToleranceMm
                error('QcReorient:Precision', ['NIfTI 头编码后全视野坐标偏差超出 %.3g mm 上限' ...
                    '（sform %.3g、qform %.3g、互差 %.3g mm）；' ...
                    '未发布输出，原图像不变。请使用重采样。'], ...
                    worldToleranceMm, sformWorldError, qformWorldError, formWorldError);
            end
            readBack = spm_read_vols(checkVol);
            yReadVerified = false;
            if exist('y_Read', 'file') == 2
                [yData, yHeader] = y_Read(checkFile);
                if ~isequaln(yData, readBack) || any(~isfinite(yHeader.mat(:))) || ...
                        max(abs(yHeader.mat - expectedSform), [], 'all') >= 1e-6
                    error('QcReorient:Verify', 'DPABI y_Read 校验失败，未发布输出。');
                end
                yReadVerified = true;
            end
            ni = niftiinfo(checkFile);
            if isempty(ni.ImageSize)
                error('QcReorient:Verify', 'MATLAB niftiinfo 无法读取输出图像。');
            end
            niftiInfoError = max(abs(ni.Transform.T.' - expectedZeroBased), [], 'all');
            if ~isreal(ni.Transform.T) || any(~isfinite(ni.Transform.T(:))) || niftiInfoError >= 1e-6
                error('QcReorient:Verify', 'MATLAB niftiinfo 几何校验失败，未发布输出。');
            end
            payloadAfter = mrw.QcReorient.hashFile(checkNifti.dat.fname, checkNifti.dat.offset);
            if strcmp(method, 'header-only')
                if ~strcmp(payloadBefore, payloadAfter) || ~isequaln(pixels, readBack)
                    error('QcReorient:Verify', '只改头模式的像素校验失败，未发布输出。');
                end
            elseif ~isequaln(single(readBack), single(resampled.Data))
                error('QcReorient:Verify', '重采样副本的像素校验失败，未发布输出。');
            end
            if compressed && strcmp(method, 'header-only')
                delete(fullfile(stage, [b e]));
                packed = gzip(checkFile, stage);
                delete(checkFile);
                [~, b2, e2] = fileparts(packed{1});
                outName = [b2 e2];
            end
            after = mrw.QcReorient.summaries(originals);
            if ~isequal(before, after)
                error('QcReorient:SourceChanged', '源文件在操作期间发生变化，未发布输出。');
            end
            outputFile = fullfile(outputDir, outName);
            verification = struct('SformMaxError', matrixError, 'QformMaxError', qformError, ...
                'QformSformMaxError', formError, ...
                'SformReadbackMaxError', sformReadbackError, 'QformReadbackMaxError', qformReadbackError, ...
                'WorldToleranceMm', worldToleranceMm, 'SformWorldMaxErrorMm', sformWorldError, ...
                'QformWorldMaxErrorMm', qformWorldError, 'QformSformWorldMaxErrorMm', formWorldError, ...
                'PixelPayloadBeforeSHA256', payloadBefore, 'PixelPayloadAfterSHA256', payloadAfter, ...
                'HeaderOnlyPixelsUnchanged', strcmp(method, 'header-only'), ...
                'SpmVolVerified', true, 'YReadVerified', yReadVerified, 'NiftiInfoVerified', true, ...
                'NiftiInfoMaxError', niftiInfoError);
            if strcmp(method, 'resample')
                inputDim = [size(pixels) 1 1 1]; outputDim = [size(resampled.Data) 1 1 1];
                [ii,jj,kk] = ndgrid([1 inputDim(1)], [1 inputDim(2)], [1 inputDim(3)]);
                displayCorners = A * sourceMatrix * [ii(:).'; jj(:).'; kk(:).'; ones(1,8)];
                [ii,jj,kk] = ndgrid([1 outputDim(1)], [1 outputDim(2)], [1 outputDim(3)]);
                outputCorners = checkVol.mat * [ii(:).'; jj(:).'; kk(:).'; ones(1,8)];
                originalBounds = [min(displayCorners(1:3,:),[],2), max(displayCorners(1:3,:),[],2)];
                outputBounds = [min(outputCorners(1:3,:),[],2), max(outputCorners(1:3,:),[],2)];
                verification.ResampleGridMaxShiftMm = max(abs(outputBounds - originalBounds), [], 'all');
            end
            log = struct('SchemaVersion', 2, 'SourceFile', source, 'OutputFile', outputFile, ...
                'Subject', subject, 'Method', method, 'Display', viewInfo, 'DisplayMatrix', A, ...
                'SourceMatrix', sourceMatrix, 'RequestedOutputMatrix', targetMatrix, ...
                'OutputMatrix', double(checkVol.mat), 'OutputQformMatrix', double(checkNifti.mat0), ...
                'UTC', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''')), ...
                'MATLABVersion', version, 'SourceBefore', before, 'SourceAfter', after, ...
                'Verification', verification, ...
                'Rollback', '删除此批次输出目录并继续使用 SourceFile；原图像无需恢复。');
            generated = dir(stage); generated = generated(~[generated.isdir]);
            paths = arrayfun(@(x) fullfile(stage, x.name), generated, 'UniformOutput', false);
            outputHashes = mrw.QcReorient.summaries(paths);
            for k = 1:numel(outputHashes)
                [~, bb, ee] = fileparts(outputHashes(k).File);
                outputHashes(k).File = fullfile(outputDir, [bb ee]);
            end
            log.OutputFiles = outputHashes;
            logName = 'reorient_log.json';
            fid = fopen(fullfile(stage, logName), 'w', 'n', 'UTF-8');
            if fid < 0, error('QcReorient:Log', '无法写入重定位日志，未发布输出。'); end
            logCleanup = onCleanup(@() closeFile(fid)); %#ok<NASGU>
            count = fprintf(fid, '%s\n', jsonencode(log, 'PrettyPrint', true));
            if count < 1 || fclose(fid) ~= 0
                error('QcReorient:Log', '重定位日志写入失败，未发布输出。');
            end
            clear logCleanup
            if exist(outputDir, 'file') || exist(outputDir, 'dir')
                error('QcReorient:Conflict', '输出批次名称已存在，未覆盖；请重试以生成新批次。');
            end
            [ok, msg] = movefile(stage, outputDir);
            if ~ok, error('QcReorient:Publish', '发布输出失败：%s', msg); end
            result = struct('OutputFile', outputFile, 'OutputDir', outputDir, ...
                'LogFile', fullfile(outputDir, logName), 'Method', method, ...
                'Matrix', double(checkVol.mat), 'Verification', verification);
        end

        function digest = hashFile(file, offset)
            if nargin < 2, offset = 0; end
            fid = fopen(file, 'r');
            if fid < 0, error('QcReorient:Hash', '无法读取校验文件：%s', file); end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            if fseek(fid, offset, 'bof') ~= 0, error('QcReorient:Hash', '像素偏移无效。'); end
            md = java.security.MessageDigest.getInstance('SHA-256');
            while ~feof(fid)
                block = fread(fid, 1024 * 1024, '*uint8');
                if ~isempty(block), md.update(typecast(block, 'int8')); end
            end
            [msg, err] = ferror(fid);
            if err, error('QcReorient:Hash', '文件校验读取失败：%s', msg); end
            digest = lower(reshape(dec2hex(typecast(md.digest(), 'uint8'), 2).', 1, []));
        end
    end

    methods (Static, Access = private)
        function [sform, qform, zeroBased] = encodedGeometry(output)
            % NIfTI-1 serializes geometry as float32; NIfTI-2 uses float64.
            encoded = struct(output);
            if encoded.hdr.sizeof_hdr == 348
                fields = {'srow_x','srow_y','srow_z','pixdim','quatern_b','quatern_c','quatern_d', ...
                    'qoffset_x','qoffset_y','qoffset_z'};
                for k = 1:numel(fields)
                    encoded.hdr.(fields{k}) = double(single(encoded.hdr.(fields{k})));
                end
            end
            header = nifti(encoded);
            sform = double(header.mat); qform = double(header.mat0);
            mrw.QcReorient.validateMatrix(sform); mrw.QcReorient.validateMatrix(qform);
            % niftiinfo returns the 0-based affine in the header's spatial units.
            zeroBased = [encoded.hdr.srow_x; encoded.hdr.srow_y; encoded.hdr.srow_z; 0 0 0 1];
        end

        function err = cornerErrorMm(actual, target, dims)
            dims = [dims 1 1 1];
            [i,j,k] = ndgrid([0.5 dims(1)+0.5], [0.5 dims(2)+0.5], [0.5 dims(3)+0.5]);
            delta = (actual-target)*[i(:).'; j(:).'; k(:).'; ones(1,8)];
            err = max(vecnorm(delta(1:3,:), 2, 1));
        end

        function validateMatrix(M)
            if ~isequal(size(M), [4 4]) || ~isreal(M) || any(~isfinite(M(:))) || ...
                    max(abs(M(4,:) - [0 0 0 1])) > 1e-10 || abs(det(M(1:3,1:3))) < 1e-12
                error('QcReorient:Transform', '变换必须是有限、可逆的 4×4 仿射矩阵。');
            end
        end

        function paths = sourceFiles(source, paired, compressed)
            [p, b, ~] = fileparts(source);
            if compressed, [~, b] = fileparts(b); end
            if paired
                paths = {fullfile(p, [b '.img']), fullfile(p, [b '.hdr'])};
            else
                paths = {source};
            end
            sidecar = fullfile(p, [b '.mat']);
            if exist(sidecar, 'file') == 2, paths{end+1} = sidecar; end
            for k = 1:numel(paths)
                if exist(paths{k}, 'file') ~= 2
                    error('QcReorient:Pair', '成对图像不完整：%s', paths{k});
                end
            end
        end

        function entries = summaries(paths)
            entries = struct('File', {}, 'Bytes', {}, 'SHA256', {});
            for k = 1:numel(paths)
                d = dir(paths{k});
                if isempty(d), error('QcReorient:Hash', '校验文件已不存在：%s', paths{k}); end
                entries(k) = struct('File', paths{k}, 'Bytes', d.bytes, ...
                    'SHA256', mrw.QcReorient.hashFile(paths{k})); %#ok<AGROW>
            end
        end

        function removeStage(stage)
            % 仅删除本调用创建的、未发布的暂存目录。
            if exist(stage, 'dir') == 7, rmdir(stage, 's'); end
        end
    end
end

function closeFile(fid)
    try, fclose(fid); catch, end
end
