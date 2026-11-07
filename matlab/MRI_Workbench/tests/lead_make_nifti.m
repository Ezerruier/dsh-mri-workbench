function lead_make_nifti(data, filePath, voxSize, tr)
% lead_make_nifti  直接按 NIfTI-1 规范写单文件 .nii（测试用，不依赖任何工具箱）
%   data    : 3D 或 4D 数值数组 [x y z (t)]
%   filePath: 输出 .nii 路径
%   voxSize : 1x3 体素大小 mm（默认 [2 2 2]）
%   tr      : 重复时间秒，写入 pixdim(4)，默认 2
if nargin < 3 || isempty(voxSize), voxSize = [2 2 2]; end
if nargin < 4 || isempty(tr), tr = 2; end
data = single(data);
dims = size(data);
if numel(dims) < 3, dims(3) = 1; end
if numel(dims) < 4, dims(4) = 1; end

hdr = zeros(1, 348, 'uint8');
hdr = setv(hdr, 0, 348, 'int32');              % sizeof_hdr（NIfTI 偏移 0）
% dim[8] @ 40
dimv = [4 dims(1:4) 1 1 1];
for k = 1:8
    hdr = setv(hdr, 40 + (k-1)*2, dimv(k), 'int16');
end
hdr = setv(hdr, 70, 16, 'int16');              % datatype FLOAT32
hdr = setv(hdr, 72, 32, 'int16');              % bitpix
% pixdim[8] @ 76
pix = [1 voxSize(1) voxSize(2) voxSize(3) tr 0 0 0];
for k = 1:8
    hdr = setv(hdr, 76 + (k-1)*4, pix(k), 'float32');
end
hdr = setv(hdr, 108, 352, 'float32');          % vox_offset
hdr = setv(hdr, 112, 1, 'float32');            % scl_slope
hdr = setv(hdr, 116, 0, 'float32');            % scl_inter
hdr(124) = uint8(0);                            % xyzt_units: mm + sec（低 3 位=2mm, 高 3 位=1sec -> 8+2=10）
hdr = setv(hdr, 123, 10, 'uint8');
hdr = setv(hdr, 124, 1, 'float32');            % cal_max
hdr = setv(hdr, 252, 0, 'int16');              % qform_code
hdr = setv(hdr, 254, 1, 'int16');              % sform_code
M = diag([voxSize(1) voxSize(2) voxSize(3) 1]);
for r = 1:3
    off = 280 + (r-1)*16;
    for c = 1:4
        hdr = setv(hdr, off + (c-1)*4, M(r,c), 'float32');
    end
end
hdr(345) = uint8('n');                          % magic @344: 'n+1\0'
hdr(346) = uint8('+');
hdr(347) = uint8('1');
hdr(348) = uint8(0);

fid = fopen(filePath, 'w', 'l');
if fid < 0
    error('无法写入文件：%s', filePath);
end
fwrite(fid, hdr, 'uint8');
fwrite(fid, zeros(1, 4, 'uint8'), 'uint8');     % 对齐到 352
fwrite(fid, permute(data, [2 1 3 4]), 'float32');
fclose(fid);
end

function buf = setv(buf, offset, value, prec)
switch prec
    case 'int16'
        bytes = typecast(int16(value), 'uint8');
    case 'int32'
        bytes = typecast(int32(value), 'uint8');
    case 'float32'
        bytes = typecast(single(value), 'uint8');
    case 'uint8'
        bytes = typecast(uint8(value), 'uint8');
    otherwise
        error('setv: 不支持的类型 %s', prec);
end
buf(offset+1:offset+numel(bytes)) = bytes;
end
