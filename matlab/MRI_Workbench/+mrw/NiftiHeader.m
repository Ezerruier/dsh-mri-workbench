classdef NiftiHeader
    %NIFTIHEADER NIfTI-1 / NIfTI-2 文件头解析（只读文件头，不加载图像数据）
    %
    %   本类用于自动扫描索引模块的快速元数据提取，不依赖 SPM 或
    %   Image Processing Toolbox，只用 MATLAB 基础文件 I/O。
    %
    %   支持的文件形式：
    %     - .nii          NIfTI-1 或 NIfTI-2 单文件
    %     - .nii.gz       gunzip 到临时目录后读取，调用结束后自动清理临时文件
    %     - .hdr + .img   NIfTI-1 / Analyze 7.5 双文件（传入 .hdr 或 .img 均可）
    %     - 大小端字节序（通过 sizeof_hdr 的字节模式自动判定）
    %
    %   用法：
    %     info = mrw.NiftiHeader.read('D:\data\sub01\rest.nii.gz');
    %
    %   返回 struct 字段（契约见 docs/CONTRACT.md 2.1）：
    %     File          char       绝对路径
    %     Format        char       'nii' | 'nii.gz' | 'hdr/img'
    %     Dim           1x8 double NIfTI dim 数组（原样）
    %     VoxSize       1x3 double 体素大小 mm（未知为 NaN）
    %     TR            double     pixdim[4] 换算为秒；<=0 或未知为 NaN
    %     TimePoints    double     dim[4]（4D 时）或 1
    %     SliceNumber   double     dim[3]
    %     DatatypeName  char       如 'float32'
    %     ReadOK        logical    是否解析成功
    %     Message       char       失败原因（中文）；成功时通常为空
    %
    %   注：上面 Dim/TR/TimePoints/SliceNumber 沿用 CONTRACT 的 NIfTI 规范
    %   0 基下标写法；MATLAB 中实际取值为 Dim(5)=dim[4]、Dim(4)=dim[3]、
    %   pixdim(5)=pixdim[4]。
    %
    %   注意：本类只读取头信息，不读取/校验图像数据体（vox_offset 之后的数据）。

    properties (Constant, Access = private)
        % NIfTI-1 头长度（字节）
        NIFTI1_SIZE = 348;
        % NIfTI-2 头长度（字节）
        NIFTI2_SIZE = 540;
        % sizeof_hdr = 348 按大端字节排列后，按小端规则解读得到的数值
        BE_MARKER_348 = 1543569408;
        % sizeof_hdr = 540 按大端字节排列后，按小端规则解读得到的数值
        BE_MARKER_540 = 469893120;
    end

    methods (Static)
        function info = read(filePath)
            %READ 读取单个 NIfTI 头信息
            %   info = mrw.NiftiHeader.read(filePath)
            %   filePath 可以是绝对路径或相对路径（相对当前工作目录）。
            %   解析失败不抛异常，而是返回 ReadOK=false 且 Message 为中文原因。

            info = mrw.NiftiHeader.emptyInfo();
            cleanupObj = []; %#ok<NASGU> 由 onCleanup 在函数返回时自动清理临时目录

            try
                % ---------- 入参校验 ----------
                if nargin < 1 || isempty(filePath)
                    info.Message = '未提供文件路径。';
                    return
                end
                if isstring(filePath) && isscalar(filePath)
                    filePath = char(filePath);
                end
                if ~ischar(filePath) || isempty(filePath)
                    info.Message = '文件路径必须是字符向量或标量字符串。';
                    return
                end

                filePath = mrw.NiftiHeader.absolutePath(filePath);
                info.File = filePath;

                if exist(filePath, 'file') ~= 2
                    info.Message = ['文件不存在或不是普通文件：' filePath];
                    return
                end

                % ---------- 解析实际要读的头文件（必要时解压 .gz） ----------
                [fmt, headerFile, tmpDir] = mrw.NiftiHeader.resolveFile(filePath);
                if ~isempty(tmpDir)
                    % 用 onCleanup 保证无论成功或异常都会删除临时解压目录
                    cleanupObj = onCleanup(@() mrw.NiftiHeader.removeDir(tmpDir));
                end
                info.Format = fmt;

                if isempty(headerFile) || exist(headerFile, 'file') ~= 2
                    info.Message = ['未能定位可读取的头文件：' filePath];
                    return
                end

                % ---------- 解析头内容 ----------
                info = mrw.NiftiHeader.parseHeader(headerFile, info);
            catch err
                info.ReadOK = false;
                info.Message = ['解析 NIfTI 头失败：' err.message];
            end
        end
    end

    methods (Static, Access = private)
        function info = emptyInfo()
            %EMPTYINFO 构造字段齐全的空结果（字段顺序与契约一致）
            info = struct( ...
                'File', '', ...
                'Format', '', ...
                'Dim', nan(1, 8), ...
                'VoxSize', nan(1, 3), ...
                'TR', NaN, ...
                'TimePoints', NaN, ...
                'SliceNumber', NaN, ...
                'DatatypeName', '', ...
                'ReadOK', false, ...
                'Message', '');
        end

        function p = absolutePath(p)
            %ABSOLUTEPATH 把相对路径补全为绝对路径（不做 .. 归一化）
            if isstring(p)
                p = char(p);
            end
            if ispc
                % Windows 下统一使用反斜杠，避免 / 与 \ 混用导致路径比较失败
                p = strrep(p, '/', '\');
            end
            isAbs = false;
            if numel(p) >= 2
                % 盘符路径（C:\...）或 UNC 路径（\\server\share\...）
                isAbs = (p(2) == ':') || (p(1) == '\' && p(2) == '\') || (p(1) == '/');
            end
            if ~isAbs
                p = fullfile(pwd, p);
            end
            % 去掉末尾多余的分隔符（保留 "C:\" 这类根路径）
            while numel(p) > 3 && (p(end) == filesep || p(end) == '/')
                p(end) = [];
            end
        end

        function [fmt, headerFile, tmpDir] = resolveFile(filePath)
            %RESOLVEFILE 依据扩展名决定格式、实际头文件路径及临时目录
            %   tmpDir 非空时表示读取的是解压后的临时文件，调用方负责清理。

            fmt = '';
            tmpDir = '';
            low = lower(filePath);

            if mrw.NiftiHeader.endsWithName(low, '.nii.gz')
                fmt = 'nii.gz';
                [headerFile, tmpDir] = mrw.NiftiHeader.gunzipToFile(filePath);
            elseif mrw.NiftiHeader.endsWithName(low, '.hdr.gz')
                fmt = 'hdr/img';
                [headerFile, tmpDir] = mrw.NiftiHeader.gunzipToFile(filePath);
            elseif mrw.NiftiHeader.endsWithName(low, '.img.gz')
                % .img.gz：解压 .img 的同时尝试找到同名 .hdr（可能也是 .hdr.gz）
                fmt = 'hdr/img';
                [imgFile, tmpDir] = mrw.NiftiHeader.gunzipToFile(filePath);
                if isempty(imgFile)
                    headerFile = '';
                    return
                end
                headerFile = mrw.NiftiHeader.findPairHdr(imgFile);
                if isempty(headerFile)
                    % 尝试同目录的 .hdr.gz
                    [d, base] = fileparts(imgFile);
                    gzHdr = fullfile(d, [base '.hdr.gz']);
                    if exist(gzHdr, 'file') == 2 && isempty(tmpDir)
                        [headerFile, extraTmp] = mrw.NiftiHeader.gunzipToFile(gzHdr);
                        tmpDir = extraTmp;
                    end
                end
            elseif mrw.NiftiHeader.endsWithName(low, '.nii')
                fmt = 'nii';
                headerFile = filePath;
            elseif mrw.NiftiHeader.endsWithName(low, '.hdr')
                fmt = 'hdr/img';
                headerFile = filePath;
            elseif mrw.NiftiHeader.endsWithName(low, '.img')
                fmt = 'hdr/img';
                headerFile = mrw.NiftiHeader.findPairHdr(filePath);
            elseif mrw.NiftiHeader.endsWithName(low, '.gz')
                % 其它 .gz：解压后按内容判定（结果写入临时目录）
                [tmpFile, tmpDir] = mrw.NiftiHeader.gunzipToFile(filePath);
                headerFile = tmpFile;
            else
                % 未知扩展名：先按 NIfTI 内容尝试解析，Format 由 magic 判定
                fmt = '';
                headerFile = filePath;
            end
        end

        function tf = endsWithName(lowName, suffix)
            %ENDSWITHNAME 大小写不敏感的后缀判断（入参需已转小写）
            tf = numel(lowName) >= numel(suffix) && ...
                strcmp(lowName(end - numel(suffix) + 1:end), suffix);
        end

        function [outFile, tmpDir] = gunzipToFile(srcFile)
            %GUNZIPTOTEMPFILE 解压单个 .gz 到新建临时目录，返回解压后的文件路径
            tmpDir = tempname();
            [ok, msg] = mkdir(tmpDir);
            if ~ok
                error('无法创建临时目录（%s）：%s', tmpDir, msg);
            end
            try
                res = gunzip(srcFile, tmpDir);
            catch err
                mrw.NiftiHeader.removeDir(tmpDir);
                error('解压 .gz 文件失败：%s', err.message);
            end
            % gunzip 的返回值在 R2026a 中可能是 char 或 cellstr，逐个兜底
            cand = '';
            if ischar(res)
                cand = res;
            elseif iscell(res) && ~isempty(res)
                for k = 1:numel(res)
                    if ischar(res{k}) && exist(res{k}, 'file') == 2
                        cand = res{k};
                        break
                    end
                end
            elseif isstring(res) && ~isempty(res)
                cand = char(res(1));
            end
            if isempty(cand) || exist(cand, 'file') ~= 2
                % 若返回值不可用，则在临时目录中寻找唯一解压出的文件
                d = dir(tmpDir);
                d = d(~[d.isdir] & ~ismember({d.name}, {'.', '..'}));
                if isempty(d)
                    mrw.NiftiHeader.removeDir(tmpDir);
                    error('解压 .gz 后未在临时目录中找到文件。');
                end
                cand = fullfile(tmpDir, d(1).name);
            end
            outFile = cand;
        end

        function hdrFile = findPairHdr(imgPath)
            %FINDPAIRHDR 为 .img 查找同名 .hdr（大小写不敏感）
            hdrFile = '';
            folder = fileparts(imgPath);
            [~, base] = fileparts(imgPath);
            if isempty(folder)
                folder = pwd;
            end
            d = dir(folder);
            wanted = [base '.hdr'];
            for k = 1:numel(d)
                if ~d(k).isdir && strcmpi(d(k).name, wanted)
                    hdrFile = fullfile(folder, d(k).name);
                    return
                end
            end
        end

        function info = parseHeader(headerFile, info)
            %PARSEHEADER 读取并解析头字节，填充 info 各字段

            % ---------- 判定头长度标记、字节序、NIfTI 版本 ----------
            fid = fopen(headerFile, 'r');
            if fid < 0
                error('无法打开文件：%s', headerFile);
            end
            raw = fread(fid, 4, 'uint8=>double');
            fclose(fid);
            if numel(raw) < 4
                error('文件过小（不足 4 字节），无法读取 NIfTI 头。');
            end
            marker = raw(1) + 256 * raw(2) + 65536 * raw(3) + 16777216 * raw(4);
            switch marker
                case mrw.NiftiHeader.NIFTI1_SIZE
                    version = 1;
                    endian = 'ieee-le';
                case mrw.NiftiHeader.BE_MARKER_348
                    version = 1;
                    endian = 'ieee-be';
                case mrw.NiftiHeader.NIFTI2_SIZE
                    version = 2;
                    endian = 'ieee-le';
                case mrw.NiftiHeader.BE_MARKER_540
                    version = 2;
                    endian = 'ieee-be';
                otherwise
                    error('不是有效的 NIfTI 头（sizeof_hdr 标记 %d 无法识别）。', marker);
            end

            % ---------- 按判定出的字节序读取头字段 ----------
            fid = fopen(headerFile, 'r', endian);
            if fid < 0
                error('无法以 %s 字节序打开文件：%s', endian, headerFile);
            end
            try
                if version == 1
                    dim = mrw.NiftiHeader.readVals(fid, 40, 8, 'int16=>double');
                    datatypeCode = mrw.NiftiHeader.readVals(fid, 70, 1, 'int16=>double');
                    pixdim = mrw.NiftiHeader.readVals(fid, 76, 8, 'single=>double');
                    xyztUnits = mrw.NiftiHeader.readVals(fid, 123, 1, 'uint8=>double');
                    magic = mrw.NiftiHeader.readVals(fid, 344, 4, 'char=>char');
                else
                    dim = mrw.NiftiHeader.readVals(fid, 16, 8, 'int64=>double');
                    datatypeCode = mrw.NiftiHeader.readVals(fid, 12, 1, 'int16=>double');
                    pixdim = mrw.NiftiHeader.readVals(fid, 104, 8, 'double=>double');
                    xyztUnits = mrw.NiftiHeader.readVals(fid, 500, 1, 'int32=>double');
                    magic = mrw.NiftiHeader.readVals(fid, 4, 8, 'char=>char');
                end
            catch err
                fclose(fid);
                error('读取头字段失败：%s', err.message);
            end
            fclose(fid);

            % ---------- 维度校验 ----------
            if numel(dim) < 8 || any(~isfinite(dim(1:8)))
                error('头信息不完整：dim 字段读取失败。');
            end
            dim = double(dim(1:8));
            dim0 = dim(1);
            if dim0 < 1 || dim0 > 7
                error('无效的维度信息：dim(1)=%g（应为 1..7）。', dim0);
            end
            info.Dim = dim;

            % ---------- 体素大小（mm） ----------
            if numel(pixdim) < 8 || any(~isfinite(pixdim(1:8)))
                error('头信息不完整：pixdim 字段读取失败。');
            end
            voxSize = abs(double(pixdim(2:4)));
            voxSize(voxSize <= 0) = NaN;
            info.VoxSize = voxSize;

            % ---------- TR：NIfTI 规范 pixdim[4]（0 基下标），MATLAB 中为 pixdim(5) ----------
            % 按 xyzt_units 换算为秒
            tr = NaN;
            if isfinite(pixdim(5)) && pixdim(5) > 0
                tr = double(pixdim(5));
                temporalUnit = 0;
                if ~isempty(xyztUnits) && isfinite(xyztUnits)
                    % xyzt_units 的第 3-5 位为时间单位：1=秒 2=毫秒 3=微秒 4=Hz 5=ppm 6=rad/s
                    temporalUnit = floor(bitand(round(double(xyztUnits)), 56) / 8);
                end
                switch temporalUnit
                    case 2
                        tr = tr / 1000;
                    case 3
                        tr = tr / 1e6;
                    case {4, 5, 6}
                        % 频率/相位类单位无法换算为秒
                        tr = NaN;
                    otherwise
                        % 0（未声明）或 1（秒）按秒处理
                end
            end
            if ~isfinite(tr) || tr <= 0
                tr = NaN;
            end
            info.TR = tr;

            % ---------- 时间点与层数 ----------
            % 注意：NIfTI 规范中 dim[3] 为层数、dim[4] 为时间点（0 基下标），
            % 对应 MATLAB 中的 dim(4) 与 dim(5)。
            if dim0 >= 4
                if dim(5) >= 1 && isfinite(dim(5))
                    info.TimePoints = dim(5);
                else
                    info.TimePoints = NaN;
                end
            else
                info.TimePoints = 1;
            end
            if dim0 >= 3 && dim(4) >= 1 && isfinite(dim(4))
                info.SliceNumber = dim(4);
            else
                info.SliceNumber = NaN;
            end

            % ---------- 数据类型名称 ----------
            info.DatatypeName = mrw.NiftiHeader.datatypeName(datatypeCode);

            % ---------- Format 兜底（扩展名无法判定时按 magic 推断） ----------
            if isempty(info.Format)
                isSingle = (version == 2) || (numel(magic) >= 3 && strcmp(magic(1:3), 'n+1'));
                if isSingle
                    info.Format = 'nii';
                else
                    info.Format = 'hdr/img';
                end
            end

            % ---------- magic 合法性提示（Analyze 头仍按兼容方式解析） ----------
            info.ReadOK = true;
            info.Message = '';
            if version == 1
                m3 = magic;
                if numel(m3) >= 3
                    m3 = m3(1:3);
                end
                if ~strcmp(m3, 'n+1') && ~strcmp(m3, 'ni1')
                    info.Message = '文件头 magic 非标准 NIfTI（可能是 Analyze 7.5 格式），已按兼容方式解析。';
                end
            else
                if numel(magic) < 3 || ~strcmp(magic(1:3), 'n+2')
                    info.Message = '文件头 magic 非标准 NIfTI-2，已按兼容方式解析。';
                end
            end
        end

        function v = readVals(fid, offset, count, precision)
            %READVALS 从偏移处读取若干个数值（已按 fopen 指定的字节序解码）
            v = [];
            if fseek(fid, offset, 'bof') ~= 0
                return
            end
            v = fread(fid, count, precision);
            v = v(:).';
        end

        function name = datatypeName(code)
            %DATATYPENAME NIfTI 数据类型码 -> 可读名称
            switch code
                case 0
                    name = 'unknown';
                case 1
                    name = 'binary';
                case 2
                    name = 'uint8';
                case 4
                    name = 'int16';
                case 8
                    name = 'int32';
                case 16
                    name = 'float32';
                case 32
                    name = 'complex64';
                case 64
                    name = 'float64';
                case 128
                    name = 'rgb24';
                case 256
                    name = 'int8';
                case 512
                    name = 'uint16';
                case 768
                    name = 'uint32';
                case 1024
                    name = 'int64';
                case 1280
                    name = 'uint64';
                case 1536
                    name = 'float128';
                case 1792
                    name = 'complex128';
                case 2048
                    name = 'complex256';
                case 2304
                    name = 'rgba32';
                otherwise
                    name = sprintf('unknown(%d)', code);
            end
        end

        function removeDir(p)
            %REMOVEDIR 静默删除临时目录
            if isempty(p) || exist(p, 'dir') ~= 7
                return
            end
            try
                rmdir(p, 's');
            catch
                % 临时目录清理失败不影响解析结果
            end
        end
    end
end
