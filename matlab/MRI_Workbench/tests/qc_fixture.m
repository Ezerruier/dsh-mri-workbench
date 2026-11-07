function base = qc_fixture(varargin)
% qc_fixture  生成合成「已预处理」DPARSF 数据集（人工 QC 测试用数据）
%
%   base = qc_fixture()        新建 tempdir 下唯一目录并生成数据，返回工作目录
%   base = qc_fixture(tag)     使用固定名字 mrw_qc_fixture_<tag>（会先清理旧目录）
%
% 生成布局（3 名受试者 Sub01..Sub03，目录名与 DPARSF 完全一致）：
%   <base>/T1Img/SubXX/coT1.nii                 3D 64x64x30 强度 blob
%   <base>/RealignParameter/SubXX/meanSubXX.nii 3D 64x64x30（DPARSF 功能平均像）
%   <base>/RealignParameter/SubXX/wmeanSubXX.nii 3D 91x109x91（MNI 2mm 空间）
%   <base>/T1ImgNewSegment/SubXX/wT1.nii         3D 91x109x91（MNI 2mm 空间）
%   <base>/T1ImgNewSegment/SubXX/wc1.nii         3D 91x109x91（灰质，MNI 2mm）
%   <base>/RealignParameter/HeadMotion.tsv       DPARSF 21 列表头 + 3 行数据
%   <base>/RealignParameter/SubXX/FD_Jenkinson_SubXX.txt  60 帧逐帧 FD（含超阈值帧）
%   <base>/RealignParameter/SubXX/FD_Power_SubXX.txt      60 帧逐帧 FD（阈值 0.5 mm）
%   <base>/QC/                                    空目录
%
% 说明：
%   * NIfTI 文件由 tests/lead_make_nifti.m 写出（float32、mat=diag(vox)），
%     其中 91x109x91 的图像随后用 SPM 的 spm_get_space 改写 hdr.mat 为
%     标准 MNI 2mm 仿射 [2 0 0 -92; 0 2 0 -128; 0 0 2 -74; 0 0 0 1]，
%     以便 mrw.QcModel.edgeSliceFor 能把 DPABI Edge 模板（193x229x193/1mm）
%     重采样出非空轮廓。若 SPM 不可用，则退化为直接改写 NIfTI-1 sform 字节。
%   * 每次调用生成唯一目录，避免并行 MATLAB（例如 UI 测试与数据模型测试）
%     互相删除数据；同一 MATLAB 会话内上一次生成的目录会在下次调用时清理。
%   * 本函数不依赖 DPABI，只要求 MATLAB 基础函数；SPM 可选。
%
% 编写：qc-engineer（MRI 静息态工作台）。

    % ---------- 1) 准备（唯一/固定）输出目录 ----------
    persistent lastDir
    if nargin >= 1 && ~isempty(varargin{1})
        tag = char(varargin{1});
        tag = regexprep(tag, '[^\w\-]', '_');
        base = fullfile(tempdir, ['mrw_qc_fixture_' tag]);
    else
        % 清理本进程上一次生成的目录（不同 MATLAB 进程互不影响）
        if ~isempty(lastDir) && exist(lastDir, 'dir') == 7
            try
                rmdir(lastDir, 's');
            catch
            end
        end
        stamp = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
        base = fullfile(tempdir, sprintf('mrw_qc_fixture_%s_%04d', stamp, randi(9999)));
    end
    if exist(base, 'dir') == 7
        try
            rmdir(base, 's');
        catch
        end
    end
    [st, msg] = mkdir(base);
    if ~st
        error('qc_fixture: 无法创建测试目录 %s（%s）', base, msg);
    end
    lastDir = base;

    subs = {'Sub01', 'Sub02', 'Sub03'};
    mniMat = [2 0 0 -92; 0 2 0 -128; 0 0 2 -74; 0 0 0 1];
    dimsSmall = [64 64 30];
    dimsMni = [91 109 91];

    % ---------- 2) 逐受试者生成图像 ----------
    for i = 1:numel(subs)
        sid = subs{i};
        % 每名受试者做轻微差异，便于肉眼区分
        sh = 0.9 + 0.1 * i;

        % T1 原始像（64x64x30）
        V = mrw_fixture_blob(dimsSmall, [32.5 32.5 15.5], [25 21 11], 700 * sh, 2.2);
        d = fullfile(base, 'T1Img', sid);
        mkdir(d);
        lead_make_nifti(V, fullfile(d, 'coT1.nii'), [1 1 1], 2);

        % 功能平均像（64x64x30）
        V = mrw_fixture_blob(dimsSmall, [32.5 32.5 16.0], [28 25 13], 480 * sh, 2.8);
        d = fullfile(base, 'RealignParameter', sid);
        mkdir(d);
        lead_make_nifti(V, fullfile(d, sprintf('mean%s.nii', sid)), [3 3 3], 2);

        % 功能像标准化平均像（MNI 2mm 91x109x91）
        V = mrw_fixture_blob(dimsMni, [46 55 47], [36 44 30], 520 * sh, 2.4);
        f = fullfile(d, sprintf('wmean%s.nii', sid));
        lead_make_nifti(V, f, [2 2 2], 2);
        mrw_fixture_set_affine(f, mniMat);

        % T1 标准化像（MNI 2mm 91x109x91）
        V = mrw_fixture_blob(dimsMni, [46 55 47], [38 47 33], 900 * sh, 2.0);
        d2 = fullfile(base, 'T1ImgNewSegment', sid);
        mkdir(d2);
        f = fullfile(d2, 'wT1.nii');
        lead_make_nifti(V, f, [2 2 2], 2);
        mrw_fixture_set_affine(f, mniMat);

        % 灰质分割（MNI 2mm，壳状分布）
        Vo = mrw_fixture_blob(dimsMni, [46 55 47], [38 47 33], 600 * sh, 1.6);
        Vi = mrw_fixture_blob(dimsMni, [46 55 47], [26 33 23], 900 * sh, 3.0);
        V = max(Vo - 0.75 * Vi, 0);
        f = fullfile(d2, 'wc1.nii');
        lead_make_nifti(V, f, [2 2 2], 2);
        mrw_fixture_set_affine(f, mniMat);
    end

    % ---------- 3) HeadMotion.tsv（DPARSF 21 列格式） ----------
    % 第 21 列 mean FD_Jenkinson 特意设计为 0.08 / 0.25 / 0.45，
    % 便于测试阈值 0.2 mm 的 MeanFD 过滤逻辑。
    % 注意：MATLAB 单引号字符串不解析 \t/\n，必须用 sprintf 生成制表符和换行
    header = sprintf(['Subject ID\tmax(abs(Tx))\tmax(abs(Ty))\tmax(abs(Tz))' ...
        '\tmax(abs(Rx))\tmax(abs(Ry))\tmax(abs(Rz))' ...
        '\tmean(abs(Tx))\tmean(abs(Ty))\tmean(abs(Tz))' ...
        '\tmean(abs(Rx))\tmean(abs(Ry))\tmean(abs(Rz))' ...
        '\tmean RMS\tmean relative RMS (mean FD_VanDijk)\tmean FD_Power' ...
        '\tNumber of FD_Power>0.5\tPercent of FD_Power>0.5' ...
        '\tNumber of FD_Power>0.2\tPercent of FD_Power>0.2' ...
        '\tmean FD_Jenkinson\n']);
    data = [ ...
        0.120 0.090 0.150  0.0100 0.0080 0.0120 ...
        0.045 0.038 0.052  0.0032 0.0028 0.0041 ...
        0.0500 0.0600 0.0500  0 0.0  0 0.0  0.080 ; ...
        0.310 0.280 0.360  0.0260 0.0240 0.0300 ...
        0.120 0.110 0.140  0.0090 0.0085 0.0105 ...
        0.1500 0.1900 0.1700  0 0.0  2 6.7  0.250 ; ...
        0.520 0.480 0.610  0.0450 0.0410 0.0520 ...
        0.210 0.190 0.240  0.0160 0.0150 0.0180 ...
        0.2600 0.3300 0.3100  1 3.3  5 16.7  0.450 ];
    fid = fopen(fullfile(base, 'RealignParameter', 'HeadMotion.tsv'), 'w', 'n', 'UTF-8');
    if fid < 0
        error('qc_fixture: 无法写 HeadMotion.tsv');
    end
    fprintf(fid, '%s', header);
    for i = 1:numel(subs)
        fprintf(fid, '%s', subs{i});
        fprintf(fid, '\t%g', data(i, :));
        fprintf(fid, '\n');
    end
    fclose(fid);

    % ---------- 3b) 逐帧 FD 文件（QcView/FD 曲线测试用） ----------
    % 每名受试者 60 帧；Jenkinson 阈值 0.2 mm、Power 阈值 0.5 mm。
    % 超阈值帧数：Sub01=2 / Sub02=3 / Sub03=4（Jenkinson）与 1 / 2 / 3（Power），
    % 便于断言坏帧计数与曲线红点。未额外生成 FD_VanDijk（留作缺失文件兜底测试）。
    nFrames = 60;
    for i = 1:numel(subs)
        sid = subs{i};
        % 基础值 < 阈值（确定性模式，避免随机）
        jBase = 0.02 + 0.06 * (mod((1:nFrames) * 13, 7) / 6);
        pBase = 0.04 + 0.12 * (mod((1:nFrames) * 11, 5) / 4);
        switch i
            case 1
                jBad = struct('Idx', [10 42], 'Val', [0.31 0.28]);
                pBad = struct('Idx', 20, 'Val', 0.72);
            case 2
                jBad = struct('Idx', [7 23 51], 'Val', [0.35 0.26 0.45]);
                pBad = struct('Idx', [5 30], 'Val', [0.60 0.80]);
            otherwise
                jBad = struct('Idx', [15 33 47 58], 'Val', [0.22 0.31 0.27 0.25]);
                pBad = struct('Idx', [12 40 55], 'Val', [0.90 0.55 0.66]);
        end
        jVals = jBase;
        pVals = pBase;
        jVals(jBad.Idx) = jBad.Val;
        pVals(pBad.Idx) = pBad.Val;
        mrw_fixture_write_values(fullfile(base, 'RealignParameter', sid, ...
            sprintf('FD_Jenkinson_%s.txt', sid)), jVals);
        mrw_fixture_write_values(fullfile(base, 'RealignParameter', sid, ...
            sprintf('FD_Power_%s.txt', sid)), pVals);
    end

    % ---------- 4) 空 QC 目录 ----------
    mkdir(fullfile(base, 'QC'));

    % 自检：确保关键文件存在（避免测试拿到半成品数据）
    must = { ...
        fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'), ...
        fullfile(base, 'RealignParameter', 'Sub02', 'meanSub02.nii'), ...
        fullfile(base, 'RealignParameter', 'Sub03', 'wmeanSub03.nii'), ...
        fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'), ...
        fullfile(base, 'T1ImgNewSegment', 'Sub02', 'wc1.nii'), ...
        fullfile(base, 'RealignParameter', 'HeadMotion.tsv'), ...
        fullfile(base, 'RealignParameter', 'Sub01', 'FD_Jenkinson_Sub01.txt'), ...
        fullfile(base, 'RealignParameter', 'Sub02', 'FD_Power_Sub02.txt'), ...
        fullfile(base, 'RealignParameter', 'Sub03', 'FD_Jenkinson_Sub03.txt')};
    for i = 1:numel(must)
        if exist(must{i}, 'file') ~= 2
            error('qc_fixture: 数据生成失败，缺少 %s', must{i});
        end
    end
end

% =========================================================================
% 局部辅助函数
% =========================================================================

function V = mrw_fixture_blob(dims, center, radii, amp, softness)
% 生成各向异性高斯 blob（single，便于直接写 float32 NIfTI）
    x = single(1:dims(1)).';
    y = single(1:dims(2));
    z = reshape(single(1:dims(3)), 1, 1, []);
    r2 = ((x - center(1)) / radii(1)) .^ 2 ...
        + ((y - center(2)) / radii(2)) .^ 2 ...
        + ((z - center(3)) / radii(3)) .^ 2;
    V = single(amp) * exp(-single(softness) * r2);
    V(r2 > 12) = 0;
end

function mrw_fixture_write_values(filePath, vals)
% 把数值向量逐行写入文本文件（UTF-8，每行一个数）——逐帧 FD 文件格式
    fid = fopen(filePath, 'w', 'n', 'UTF-8');
    if fid < 0
        error('qc_fixture: 无法写 FD 文件 %s', filePath);
    end
    fprintf(fid, '%.6f\n', vals(:).');
    fclose(fid);
end

function mrw_fixture_set_affine(filePath, M)
% 把 1-based 体素→mm 仿射 M 写入 NIfTI 头（优先 spm_get_space）
    if exist('spm_get_space', 'file') == 2
        try
            spm_get_space(filePath, M);
            return;
        catch
            % SPM 不可用/失败时走下面的字节级兜底
        end
    end
    mrw_fixture_write_sform(filePath, M);
end

function mrw_fixture_write_sform(filePath, M)
% 直接改写 NIfTI-1 文件的 sform 头字节（1-based mat -> 0-based sform）
    S = double(M);
    S(1:3, 4) = S(1:3, 4) + S(1:3, 1:3) * [1; 1; 1];
    fid = fopen(filePath, 'r+');
    if fid < 0
        error('qc_fixture: 无法打开 %s 修改头信息', filePath);
    end
    try
        fseek(fid, 252, 'bof');
        fwrite(fid, int16(0), 'int16');        % qform_code = 0
        fseek(fid, 254, 'bof');
        fwrite(fid, int16(1), 'int16');        % sform_code = 1
        fseek(fid, 280, 'bof');
        fwrite(fid, single([S(1, :) S(2, :) S(3, :)]), 'float32');  % srow_x/y/z
        fclose(fid);
    catch err
        try
            fclose(fid);
        catch
        end
        rethrow(err);
    end
end
