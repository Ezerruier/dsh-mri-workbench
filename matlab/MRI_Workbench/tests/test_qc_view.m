function test_qc_view()
% test_qc_view  人工 QC 显示几何引擎 mrw.QcView + 逐帧 FD 的自包含测试（-batch 可运行）
%
% 运行：
%   matlab -batch "cd('<仓库>\matlab\MRI_Workbench'); addpath(pwd); addpath('tests'); test_qc_view"
%
% 覆盖（设计契约 docs/QC_UI_V2_CONTRACT.md §3.4 / §4）：
%   * 构造/空体积/无效输入不抛异常；
%   * native 模式切片采用 SPM world-space 方向（三平面与显示网格一致）（三方向、clamp、缺省层、
%     SliceLabel/SliceCount/SliceIndex/ImageSize）；
%   * 坐标往返（voxel↔world↔display，native/origin/acpc/manual/flip）；
%   * 手动 6 自由度平移/旋转矩阵与契约公式一致；LR/AP/IS 翻转；
%   * 原点校准（setOriginAtWorld）与显示变换；
%   * AC-PC：AC→display 原点、PC→display -Y（后方）、距离保持、角度/距离/旋转字段、
%     AC=PC 失败消息（'AC 与 PC 距离过小，无法配平'）；
%   * 非 native 重采样在网格对齐时与 native 图像一致（验证 interp3 采样几何）；
%   * 三正交一致性：同一十字线下三种方向切片中十字线像素位置互相一致（≤1 px）；
%   * setSliceIndex/currentSliceIndex 联动、montage n×n tile 布局与 Highlight；
%   * getInfo 契约字段；方向轴标签；
%   * 性能（100 次 native 切片 < 1 s；三正交一次重绘 < 0.4 s）；
%   * QcModel.loadFdSeries / headMotionSeries 与 qc_fixture 的逐帧 FD 文件。
%
% 输出末尾打印 "PASS xx/xx"（全部通过）或 "FAIL xx/xx" 并抛错（-batch 退出码非 0）。
%
% 编写：view-engine（MRI 静息态工作台 v2）。

    t0 = tic;
    nPass = 0;
    nTotal = 0;
    fails = {};
    base = '';
    volT1 = [];
    hdrT1 = [];

    fprintf('==== test_qc_view: QcView display geometry + FD series ====\n');
    fprintf('MATLAB %s | pwd=%s\n', version, pwd);

    section('environment', @secEnvironment);
    section('fixture', @secFixture);
    section('construct/empty', @secConstruct);
    section('native SPM orientation', @secNative);
    section('asymmetric orientation and oblique grid', @secOrientation);
    section('planeInfo native', @secPlaneInfoNative);
    section('coordinate roundtrip', @secCoord);
    section('manual/flips', @secManual);
    section('origin mode', @secOrigin);
    section('resample vs native', @secResample);
    section('AC-PC', @secAcPc);
    section('triple consistency', @secTriple);
    section('slice index/crosshair', @secSliceIndex);
    section('montage', @secMontage);
    section('getInfo fields', @secGetInfo);
    section('invalid inputs', @secInvalid);
    section('FD series', @secFd);
    section('performance', @secPerf);

    elapsed = toc(t0);
    fprintf('\n==== test_qc_view: %d/%d checks passed in %.1f s ====\n', ...
        nPass, nTotal, elapsed);
    if isempty(fails) && nPass == nTotal && nTotal > 0
        fprintf('PASS %d/%d\n', nPass, nTotal);
    else
        fprintf('FAIL %d/%d\n', nPass, nTotal);
        for i = 1:numel(fails)
            fprintf('  - %s\n', fails{i});
        end
        error('test_qc_view: %d/%d 项检查失败（详见上方 FAIL 列表）', ...
            nTotal - nPass, nTotal);
    end

    % =====================================================================
    % 各测试段（嵌套函数，共享 base / 计数器）
    % =====================================================================

    function secEnvironment()
        check(~isempty(which('mrw.QcView')), 'env: mrw.QcView on path');
        check(~isempty(which('mrw.QcModel')), 'env: mrw.QcModel on path');
        check(exist('qc_fixture', 'file') == 2, 'env: qc_fixture available');
        check(~isempty(which('DPABI.m')), 'env: DPABI on path');
        check(~isempty(which('spm_vol')), 'env: SPM12 on path');
    end

    function secFixture()
        base = qc_fixture();
        fprintf('       fixture base = %s\n', base);
        check(ischar(base) && exist(base, 'dir') == 7, 'fixture: base dir exists');
        subs = {'Sub01', 'Sub02', 'Sub03'};
        okFd = true;
        for i = 1:numel(subs)
            f1 = fullfile(base, 'RealignParameter', subs{i}, ...
                sprintf('FD_Jenkinson_%s.txt', subs{i}));
            f2 = fullfile(base, 'RealignParameter', subs{i}, ...
                sprintf('FD_Power_%s.txt', subs{i}));
            if exist(f1, 'file') ~= 2 || exist(f2, 'file') ~= 2
                okFd = false;
            end
        end
        check(okFd, 'fixture: 3 subjects have FD_Jenkinson/FD_Power files');
        % 原有 fixture 语义未变（T1 / HeadMotion 21 列）
        check(exist(fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'), 'file') == 2, ...
            'fixture: original T1 files kept');
        check(nLines(fullfile(base, 'RealignParameter', subs{1}, ...
            'FD_Jenkinson_Sub01.txt')) == 60, 'fixture: FD Jenkinson ~60 frames');
        check(nLines(fullfile(base, 'RealignParameter', subs{2}, ...
            'FD_Power_Sub02.txt')) == 60, 'fixture: FD Power ~60 frames');
        fid = fopen(fullfile(base, 'RealignParameter', 'HeadMotion.tsv'), 'r', 'n', 'UTF-8');
        h = fgetl(fid);
        fclose(fid);
        check(numel(strsplit(h, sprintf('\t'))) == 21, ...
            'fixture: HeadMotion.tsv still 21 columns');
        % 读取 T1 体数据（后续大量测试复用）
        [volT1, hdrT1, infT1] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1Img', 'Sub01', 'coT1.nii'));
        fprintf('       T1 volume = %s, source = %s\n', mat2str(size(volT1)), infT1.Source);
        check(~isempty(volT1) && isequal(size(volT1), [64 64 30]), ...
            'fixture: T1 volume 64x64x30 readable');
        check(isequal(size(hdrT1.mat), [4 4]) && all(isfinite(hdrT1.mat(:))), ...
            'fixture: T1 hdr.mat valid 4x4');
    end

    function secConstruct()
        v0 = mrw.QcView();
        check(~v0.hasVolume(), 'construct: empty QcView hasVolume=false');
        [img, si] = v0.slice('axial', 3);
        check(isempty(img) && ~isempty(si.Message), ...
            'construct: empty slice -> [] + Chinese message');
        check(si.SliceCount == 0 && si.SliceIndex == 0, ...
            'construct: empty slice count/index zero');
        pi0 = v0.planeInfo('coronal');
        check(~isempty(pi0.Message), 'construct: empty planeInfo has message');
        [~, mi0] = v0.montage('axial', 3);
        check(isempty(mi0.ImageSize) || all(mi0.ImageSize == 0), ...
            'construct: empty montage image empty');
        check(~isempty(mi0.Message), 'construct: empty montage has message');
        info0 = v0.getInfo();
        check(~info0.HasVolume && ~isempty(info0.Message), ...
            'construct: empty getInfo -> HasVolume=false + message');
        check(isequal(size(info0.DisplayMatrix), [4 4]), ...
            'construct: empty getInfo DisplayMatrix 4x4');
        check(v0.currentSliceIndex('axial') == 1, ...
            'construct: empty currentSliceIndex=1');
        check(isequal(v0.getCrosshair(), [1 1 1]), 'construct: empty crosshair [1 1 1]');
        check(isempty(v0.voxelToWorld([1 1 1])), ...
            'construct: empty voxelToWorld -> []');

        % 仅有体数据：hdr 无效时按 1mm/eye 显示，不报错
        v1 = mrw.QcView(rand(8, 8, 6));
        check(v1.hasVolume() && isequal(v1.getInfo().Dim, [8 8 6]), ...
            'construct: volume without hdr accepted');
        check(~isempty(v1.getInfo().Message), ...
            'construct: volume without hdr -> invalid-hdr notice');
        check(~isempty(v1.getInfo().Message), ...
            'construct: invalid hdr gives Chinese message');
        [img1, si1] = v1.slice('axial');
        check(isequal(size(img1), [8 8]) && si1.IsNative, ...
            'construct: invalid hdr still slices (native)');
        check(norm(v1.voxelToWorld([2 3 4]) - [2 3 4]) < 1e-12, ...
            'construct: invalid hdr world == voxel (1mm, eye)');

        % hdr.mat 为 NaN -> 不抛异常
        v2 = mrw.QcView(rand(5, 5, 4), struct('mat', nan(4)));
        check(v2.hasVolume() && ~isempty(v2.getInfo().Message), ...
            'construct: NaN hdr.mat graceful');
        v3 = mrw.QcView(rand(8, 8, 4, 3), struct('mat', eye(4)));
        check(v3.hasVolume() && isequal(v3.getInfo().Dim, [8 8 4]), ...
            'construct: 4D volume averaged to 3D');
        v4 = mrw.QcView([], []);
        check(~v4.hasVolume(), 'construct: empty inputs accepted');
        % 2D 体积（dim3=1）
        vD = mrw.QcView(rand(10, 10), struct('mat', eye(4)));
        check(vD.hasVolume(), 'construct: 2D volume padded to 10x10x1');
        [imgD, ~] = vD.slice('axial');
        check(isequal(size(imgD), [10 10]), 'construct: 2D volume slices');
        vD.setOriginAtWorld([0 0 0]);
        [imgD2, siD2] = vD.slice('axial');
        check(isequal(size(imgD2), [10 10]) && isempty(siD2.Message), ...
            'construct: degenerate volume resampled without error');
    end

    function secNative()
        v = mrw.QcView(volT1, hdrT1);
        info0 = v.getInfo();
        check(v.hasVolume(), 'native: hasVolume');
        check(isequal(v.getInfo().Dim, [64 64 30]), 'native: Dim 64x64x30');
        check(strcmp(info0.Mode, 'native') && info0.IsNative, ...
            'native: initial Mode/IsNative');
        center = max(1, round(([64 64 30] + 1) / 2));
        check(isequal(v.getCrosshair(), center), ...
            'native: crosshair at volume center');
        check(norm(info0.CrosshairWorld - v.voxelToWorld(center)) < 1e-12, ...
            'native: getInfo CrosshairWorld');
        labels = {'axial', 'coronal', 'sagittal'};
        for i = 1:3
            o = labels{i};
            slAll = mrw.QcModel.makeSlice(volT1, o, 1);
            total = slAll.SliceCount;
            check(total > 0, sprintf('native(%s): makeSlice total', o));
            ks = [1, round((total + 1) / 2), total, 999, -5, NaN];
            for j = 1:numel(ks)
                [img, si] = v.slice(o, ks(j));
                sl = mrw.QcModel.makeSlice(volT1, o, ks(j));
                check(isequal(img, spmSlice(sl.Image, o)), ...
                    sprintf('native(%s): SPM-oriented native pixels for k=%g', o, ks(j)));
                check(si.SliceIndex == sl.SliceIndex && si.SliceCount == sl.SliceCount, ...
                    sprintf('native(%s): index/count match k=%g', o, ks(j)));
                check(strcmp(si.SliceLabel, sl.SliceLabel), ...
                    sprintf('native(%s): SliceLabel match k=%g', o, ks(j)));
                check(isequal(si.ImageSize, size(spmSlice(sl.Image, o))), ...
                    sprintf('native(%s): ImageSize match k=%g', o, ks(j)));
                check(si.IsNative, sprintf('native(%s): IsNative true', o));
            end
            [imgD, siD] = v.slice(o);
            slD = mrw.QcModel.makeSlice(volT1, o);
            check(isequal(imgD, spmSlice(slD.Image, o)) && siD.SliceIndex == slD.SliceIndex, ...
                sprintf('native(%s): default slice follows middle crosshair', o));
        end
        % 返回类型/尺寸
        [imgA, ~] = v.slice('axial');
        check(isa(imgA, 'double') && isequal(size(imgA), [64 64]), ...
            'native: axial double 64x64');
        [imgC, ~] = v.slice('coronal');
        check(isequal(size(imgC), [30 64]), 'native: coronal size [30 64]');
        [imgS, ~] = v.slice('sagittal');
        check(isequal(size(imgS), [30 64]), 'native: sagittal size [30 64]');
        % 中文别名与大小写
        [~, siCn] = v.slice('冠状', 20);
        check(strcmp(siCn.Orientation, 'coronal'), 'native: Chinese orientation alias');
        [~, siUp] = v.slice('AXIAL', 5);
        check(strcmp(siUp.Orientation, 'axial'), 'native: case-insensitive orientation');
    end

    function secPlaneInfoNative()
        v = mrw.QcView(volT1, hdrT1);
        info0 = v.getInfo();
        dims = info0.Dim;
        T1mat = hdrT1.mat;
        cases = {'axial', 1, 2, [dims(2), dims(1)]; ...
            'coronal', 1, 3, [dims(3), dims(1)]; ...
            'sagittal', 2, 3, [dims(3), dims(2)]};
        for i = 1:size(cases, 1)
            o = cases{i, 1};
            cA = cases{i, 2};
            rA = cases{i, 3};
            expSize = cases{i, 4};
            pi = v.planeInfo(o);
            fprintf('       planeInfo(%s): size=%s XLim=[%.2f %.2f] YLim=[%.2f %.2f] px=%.3f\n', ...
                o, mat2str(pi.ImageSize), pi.XLim(1), pi.XLim(2), ...
                pi.YLim(1), pi.YLim(2), pi.PixelSize);
            check(pi.IsNative && pi.SliceCount > 0, ...
                sprintf('planeInfo(%s): IsNative and count', o));
            check(isequal(pi.ImageSize, expSize), ...
                sprintf('planeInfo(%s): ImageSize', o));
            check(pi.SliceIndex == v.currentSliceIndex(o), ...
                sprintf('planeInfo(%s): SliceIndex = current', o));
            T = pi.PixelToDisplay;
            check(isequal(size(T), [3 3]) && all(isfinite(T(:))), ...
                sprintf('planeInfo(%s): PixelToDisplay 3x3 finite', o));
            nc = pi.ImageSize(2);
            nr = pi.ImageSize(1);
            expX = [T(cA, 1) * 0.5 + T(cA, 3), T(cA, 1) * (nc + 0.5) + T(cA, 3)];
            expY = [T(rA, 2) * 0.5 + T(rA, 3), T(rA, 2) * (nr + 0.5) + T(rA, 3)];
            check(norm(pi.XLim - expX) < 1e-9, ...
                sprintf('planeInfo(%s): XLim half-pixel display range', o));
            check(norm(pi.YLim - expY) < 1e-9, ...
                sprintf('planeInfo(%s): YLim half-pixel display range', o));
            % XLim 跨度 = 像素数 × 每像素 display mm
            check(abs(abs(pi.XLim(2) - pi.XLim(1)) - nc * norm(T(:, 1))) < 1e-9, ...
                sprintf('planeInfo(%s): XLim span in display mm', o));
            check(abs(abs(pi.YLim(2) - pi.YLim(1)) - nr * norm(T(:, 2))) < 1e-9, ...
                sprintf('planeInfo(%s): YLim span in display mm', o));
            % PixelToDisplay 与 voxelToDisplay 一致（native 逐像素精确）
            k = pi.SliceIndex;
            check(norm(v.voxelToDisplay(nativeVox(o, 5, 7, k, dims)) - ...
                (T * [5; 7; 1]).') < 1e-9, ...
                sprintf('planeInfo(%s): PixelToDisplay matches voxelToDisplay', o));
            check(norm(v.voxelToDisplay(nativeVox(o, nc, nr, k, dims)) - ...
                (T * [nc; nr; 1]).') < 1e-9, ...
                sprintf('planeInfo(%s): PixelToDisplay last pixel', o));
        end
        % SPM World Space：axial +X/+Y；coronal +X/+Z；sagittal -Y/+Z。
        piA = v.planeInfo('axial');
        check(strcmp(piA.XAxisLabel, expLabel(T1mat(1:3, 1))), ...
            'planeInfo(axial): XAxisLabel from +X (columns)');
        check(strcmp(piA.YAxisLabel, expLabel(T1mat(1:3, 2))), ...
            'planeInfo(axial): YAxisLabel from +Y (rows)');
        piC = v.planeInfo('coronal');
        check(strcmp(piC.XAxisLabel, expLabel(T1mat(1:3, 1))), ...
            'planeInfo(coronal): XAxisLabel from i axis');
        check(strcmp(piC.YAxisLabel, expLabel(T1mat(1:3, 3))), ...
            'planeInfo(coronal): YAxisLabel from +Z');
        piS = v.planeInfo('sagittal');
        check(strcmp(piS.XAxisLabel, expLabel(-T1mat(1:3, 2))), ...
            'planeInfo(sagittal): XAxisLabel from -Y');
        check(strcmp(piS.YAxisLabel, expLabel(T1mat(1:3, 3))), ...
            'planeInfo(sagittal): YAxisLabel from +Z');
        % coronal/sagittal 上方为 superior（YDir normal）。
        if T1mat(3, 3) > 0
            check(piC.YLim(2) > piC.YLim(1) && piS.YLim(2) > piS.YLim(1), ...
                'planeInfo: coronal/sagittal YLim ascending (SPM superior up)');
        end
    end

    function secOrientation()
        D = zeros(11, 13, 9);
        D(3, 7, 5) = 11; % L
        D(6, 11, 5) = 22; % A
        D(6, 7, 8) = 33; % S
        h = struct('mat', [1 0 0 -6;0 1 0 -7;0 0 1 -5;0 0 0 1], ...
            'voxSize', [1 1 1]);
        v = mrw.QcView(D, h); v.setCrosshair([6 7 5]);
        for transformed = [false true]
            if transformed, v.setOriginAtWorld([0 0 0]); end
            [a, ai] = v.slice('axial'); [c, ci] = v.slice('coronal'); [sg, si] = v.slice('sagittal');
            check(a(7,3) == 11 && a(11,6) == 22, 'SPM axial: L left, A up (YDir normal)');
            check(c(5,3) == 11 && c(8,6) == 33, 'SPM coronal: L left, S up');
            check(sg(5,3) == 22 && sg(8,7) == 33, 'SPM sagittal: A left, S up');
            check(strcmp(ai.XAxisLabel,'L→R') && strcmp(ai.YAxisLabel,'P→A'), 'SPM axial axis labels');
            check(strcmp(ci.XAxisLabel,'L→R') && strcmp(ci.YAxisLabel,'I→S'), 'SPM coronal axis labels');
            check(strcmp(si.XAxisLabel,'A→P') && strcmp(si.YAxisLabel,'I→S'), 'SPM sagittal axis labels');
        end
        [out, M] = v.resampledVolume();
        check(isequal(out, D) && norm(M-h.mat,'fro') < 1e-10, 'display volume: aligned data and 1-based affine');
        v.setManual([2 -3 4], [0 0 0]);
        [out, M] = v.resampledVolume();
        check(norm(out(:)-D(:)) < 1e-9 && norm(M(1:3,4) - (h.mat(1:3,4)+[2;-3;4])) < 1e-9, ...
            'display volume: translation preserves data and moves affine');
        R = rotX(15) * rotZ(-7);
        ob = h; ob.mat(1:3,1:3) = R;
        v = mrw.QcView(D, ob); v.setCrosshair([6 7 5]);
        pi = v.planeInfo('axial');
        check(pi.IsNative && pi.ImageSize(1) > 13, 'oblique native: world grid uses full header rotation');
        [a, ai] = v.slice('axial');
        T = pi.PixelToDisplay; [cc,rr] = meshgrid(1:size(a,2),1:size(a,1));
        q = ob.mat \ [T*[cc(:).';rr(:).';ones(1,numel(cc))];ones(1,numel(cc))];
        expected = interpn(D,reshape(q(1,:),size(a)),reshape(q(2,:),size(a)),reshape(q(3,:),size(a)),'linear',0);
        check(norm(a-expected,'fro') < 1e-10, 'oblique native: independent world-to-voxel sampling matches');
        v.setOriginAtWorld([0 0 0]); b=v.slice('axial',ai.SliceIndex);
        check(norm(a-b,'fro') < 1e-10, 'oblique native/non-native identical with identity transform');
        v.setInterpolation('nearest'); b=v.slice('axial',ai.SliceIndex);
        nearest = interpn(D,reshape(q(1,:),size(a)),reshape(q(2,:),size(a)), ...
            reshape(q(3,:),size(a)),'nearest',0);
        check(isequal(b,nearest), 'oblique nearest: independent nearest-neighbour sampling matches');
        [out,M] = v.resampledVolume();
        check(isequal(out(:,:,ai.SliceIndex).',b) && all(isfinite(M(:))), ...
            'resampledVolume uses actual nearest display grid');
        zeroBased = M * [eye(4,3) [1;1;1;1]];
        check(isequal(double(single(zeroBased)),zeroBased) && ...
            isequal(double(single(M-1))+1,M), ...
            'resampled grid affine is jointly float32 representable in 0/1-based form');
        neg=h; neg.mat(1,1)=-1; neg.mat(1,4)=6;
        v=mrw.QcView(D,neg); v.setCrosshair([6 7 5]); a=v.slice('axial');
        check(a(7,9)==11, 'negative source X scale: source landmark placed at correct world side');
    end

    function secCoord()
        v = mrw.QcView(volT1, hdrT1);
        pts = [1 1 1; 10.5 20.25 5.5; 64 32 15; 32 64 30];
        w = v.voxelToWorld(pts);
        back = v.worldToVoxel(w);
        check(norm(back - pts, 'fro') < 1e-9, 'coord: voxel->world->voxel roundtrip');
        d = v.voxelToDisplay(pts);
        back2 = v.displayToVoxel(d);
        check(norm(back2 - pts, 'fro') < 1e-9, 'coord: voxel->display->voxel roundtrip');
        w4 = v.voxelToWorld([10 20 5 1]);
        check(norm(w4 - v.voxelToWorld([10 20 5])) < 1e-12, ...
            'coord: homogeneous [x y z 1] input supported');
        check(isempty(v.voxelToWorld([])) && isempty(v.voxelToWorld('abc')), ...
            'coord: invalid input -> []');
        check(isempty(v.worldToVoxel(nan(1, 3))), 'coord: NaN input -> []');
        % N×3 批量
        P3 = v.voxelToWorld([1 2 3; 4 5 6]);
        check(isequal(size(P3), [2 3]) && ...
            norm(P3 - [v.voxelToWorld([1 2 3]); v.voxelToWorld([4 5 6])]) < 1e-12, ...
            'coord: Nx3 batch transform');
        % origin 模式往返
        v.setOriginAtWorld([1.5 -2.5 3.25]);
        d2 = v.voxelToDisplay([11 22 13]);
        check(norm(v.displayToVoxel(d2) - [11 22 13]) < 1e-9, ...
            'coord: origin mode display roundtrip');
        % acpc 模式往返
        v.setAcPc([20 30 10], [26 38 12]);
        d3 = v.voxelToDisplay([15 18 9]);
        check(norm(v.displayToVoxel(d3) - [15 18 9]) < 1e-8, ...
            'coord: acpc mode display roundtrip');
        % manual + flips 模式往返
        v.setManual([3 -2 1], [11 22 33]);
        v.setFlips(true, false, true);
        d4 = v.voxelToDisplay([12 13 14]);
        check(norm(v.displayToVoxel(d4) - [12 13 14]) < 1e-8, ...
            'coord: manual/hip mode display roundtrip');
    end

    function secManual()
        v = mrw.QcView(volT1, hdrT1);
        mat = hdrT1.mat;
        p = [10 20 5];
        w = v.voxelToWorld(p);
        % 纯平移
        info = v.setManual([5 -3 2], [0 0 0]);
        check(info.Ok, 'manual: setManual ok');
        check(~info.IsNative, 'manual: manual !=0 -> IsNative false');
        A = info.DisplayMatrix;
        check(norm(A(1:3, 4) - [5; -3; 2]) < 1e-12 && ...
            norm(A(1:3, 1:3) - eye(3), 'fro') < 1e-12, ...
            'manual: pure translation matrix T(t)');
        check(norm(v.voxelToDisplay(p) - (w + [5 -3 2])) < 1e-12, ...
            'manual: pure translation shifts display');
        % 纯旋转 Rz(90)
        info = v.setManual([0 0 0], [0 0 90]);
        A = info.DisplayMatrix;
        expR = [0 -1 0; 1 0 0; 0 0 1];
        check(norm(A(1:3, 1:3) - expR, 'fro') < 1e-9, ...
            'manual: yaw 90 -> Rz(90)');
        expD = expR * w(:);
        check(norm(v.voxelToDisplay(p) - expD.') < 1e-9, ...
            'manual: yaw 90 rotates display');
        % 组合：A = T(t) * Rz(yaw)*Ry(roll)*Rx(pitch)
        t = [1 2 3];
        r = [10 20 30];
        info = v.setManual(t, r);
        expA = eye(4);
        expA(1:3, 1:3) = rotZ(r(3)) * rotY(r(2)) * rotX(r(1));
        expA(1:3, 4) = t(:);
        check(norm(info.DisplayMatrix - expA, 'fro') < 1e-9, ...
            'manual: A = T*Rz*Ry*Rx matches contract');
        check(norm(v.voxelToDisplay(p) - (expA(1:3, 1:3) * w(:) + t(:)).') < 1e-9, ...
            'manual: combined transform applied to world point');
        % 无效输入
        before = v.getInfo().DisplayMatrix;
        infoBad = v.setManual([1 2], [0 0 0]);
        check(~infoBad.Ok && ~isempty(infoBad.Message), ...
            'manual: invalid translation rejected with message');
        check(norm(v.getInfo().DisplayMatrix - before, 'fro') < 1e-12, ...
            'manual: invalid input leaves state unchanged');
        % 翻转
        v.setManual([0 0 0], [0 0 0]);
        infoF = v.setFlips(true, false, false);
        check(infoF.Ok && infoF.Flips.LR && ~infoF.Flips.AP && ~infoF.Flips.IS, ...
            'flips: setFlips(true,false,false)');
        A = infoF.DisplayMatrix;
        check(norm(A(1:3, 1:3) - diag([-1 1 1]), 'fro') < 1e-12, ...
            'flips: LR flip matrix diag([-1 1 1])');
        dP = v.voxelToDisplay(p);
        wP = v.voxelToWorld(p);
        check(abs(dP(1) + wP(1)) < 1e-12, ...
            'flips: LR flips display X only');
        check(strcmp(v.planeInfo('axial').XAxisLabel, expLabel(-mat(1:3, 1))), ...
            'flips: LR -> axial XAxisLabel reversed');
        check(strcmp(v.planeInfo('axial').YAxisLabel, expLabel(mat(1:3, 2))), ...
            'flips: LR -> axial YAxisLabel unchanged');
        infoF = v.setFlips(false, true, true);
        check(infoF.Flips.AP && infoF.Flips.IS && ~infoF.Flips.LR, ...
            'flips: setFlips(false,true,true)');
        A = infoF.DisplayMatrix;
        check(norm(A(1:3, 1:3) - diag([1 -1 -1]), 'fro') < 1e-12, ...
            'flips: AP+IS flip matrix');
        % 无效翻转
        infoBad = v.setFlips(1, 2, 'x');
        check(~infoBad.Ok && ~isempty(infoBad.Message), ...
            'flips: invalid arguments rejected with message');
        % 重置
        infoR = v.resetDisplay();
        check(infoR.Ok && strcmp(infoR.Mode, 'native') && infoR.IsNative && ...
            ~any(infoR.Flips.LR) && ~any(infoR.Manual.TranslationMm), ...
            'flips: resetDisplay restores native/centered');
        check(isequal(v.getCrosshair(), max(1, round(([64 64 30] + 1) / 2))), ...
            'flips: resetDisplay centers crosshair');
    end

    function secOrigin()
        v = mrw.QcView(volT1, hdrT1);
        origin = [1.5 -2 3.25];
        info = v.setOriginAtWorld(origin);
        check(info.Ok && strcmp(info.Mode, 'origin'), ...
            'origin: setOriginAtWorld -> Mode=origin');
        check(~info.IsNative, 'origin: non-zero origin -> IsNative false');
        A = info.DisplayMatrix;
        check(norm(A(1:3, 4) + origin(:)) < 1e-12, ...
            'origin: A = T(-originWorld)');
        w = v.voxelToWorld([20 30 10]);
        check(norm(v.voxelToDisplay([20 30 10]) - (w - origin)) < 1e-12, ...
            'origin: display = world - origin');
        % 十字线与切片序号仍以 voxel 为准
        v.setCrosshair([20 30 10]);
        labels = {'axial', 'coronal', 'sagittal'};
        for i = 1:numel(labels)
            o = labels{i};
            idx = v.currentSliceIndex(o);
            [img, si] = v.slice(o, idx);
            check(~isempty(img) && si.SliceCount >= 1 && ...
                idx >= 1 && idx <= si.SliceCount, ...
                sprintf('origin(%s): currentSliceIndex/slice valid', o));
            d = v.getInfo().CrosshairDisplay;
            p = si.CrosshairPixel;
            cA = displayColAxis(o);
            rA = displayRowAxis(o);
            colCoord = si.XLim(1) + (p(1) - 0.5) * diff(si.XLim) / si.ImageSize(2);
            rowCoord = pixelRowToCoord(si, p(2));
            check(abs(colCoord - d(cA)) <= 1.0 * si.PixelSize, ...
                sprintf('origin(%s): crosshair col pixel maps to display', o));
            check(abs(rowCoord - d(rA)) <= 1.5 * si.PixelSize, ...
                sprintf('origin(%s): crosshair row pixel maps to display', o));
        end
        % 无效原点
        infoBad = v.setOriginAtWorld([1 2]);
        check(~infoBad.Ok && ~isempty(infoBad.Message), ...
            'origin: invalid origin rejected');
        v.resetDisplay();
    end

    function secResample()
        % 原点取 [0 0 0]（A=I）时，重采样网格与体素网格对齐：
        % 非 native 切片应与 native 切片逐元素一致（验证 interp3 采样几何正确）
        v = mrw.QcView(volT1, hdrT1);
        v.setOriginAtWorld([0 0 0]);
        labels = {'axial', 'coronal', 'sagittal'};
        for i = 1:numel(labels)
            o = labels{i};
            idx = v.currentSliceIndex(o);
            [imgR, siR] = v.slice(o, idx);
            slN = mrw.QcModel.makeSlice(volT1, o, idx);
            check(~siR.IsNative, sprintf('resample(%s): IsNative false in origin mode', o));
            check(isequal(size(imgR), size(spmSlice(slN.Image, o))), ...
                sprintf('resample(%s): size matches native', o));
            check(norm(double(imgR) - double(spmSlice(slN.Image, o)), 'fro') < 1e-6, ...
                sprintf('resample(%s): values equal native (aligned grid)', o));
        end
        % 翻转后应与 native 沿相应轴翻转一致（LR 翻转 display X = axial 列方向）
        v.setOriginAtWorld([0 0 0]);
        v.setFlips(true, false, false);
        idx = v.currentSliceIndex('axial');
        imgF = v.slice('axial', idx);
        slN = mrw.QcModel.makeSlice(volT1, 'axial', idx);
        check(norm(double(imgF) - fliplr(double(spmSlice(slN.Image, 'axial'))), 'fro') < 1e-6, ...
            'resample: LR flip equals fliplr(native axial)');
        % 非整数原点：应产生插值且不报错
        v.resetDisplay();
        v.setOriginAtWorld([0.25 -0.25 0.5]);
        [imgI, siI] = v.slice('axial');
        check(~isempty(imgI) && all(isfinite(imgI(:))) && isempty(siI.Message), ...
            'resample: fractional origin interpolates without error');
        % 插值方法（面板 平滑/最近邻 下拉）
        v.setInterpolation('nearest');
        check(strcmp(v.Interpolation, 'nearest'), ...
            'interp: setInterpolation nearest');
        [imgNea, siNea] = v.slice('axial');
        check(~isempty(imgNea) && isempty(siNea.Message), ...
            'interp: nearest-neighbour resampling works');
        v.setInterpolation('bogus');
        check(strcmp(v.Interpolation, 'nearest'), ...
            'interp: invalid interpolation ignored');
        v.setInterpolation('linear');
        check(strcmp(v.Interpolation, 'linear'), ...
            'interp: setInterpolation linear');
        v.resetDisplay();
    end

    function secAcPc()
        [volW, hdrW] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
        check(~isempty(volW) && isequal(size(volW), [91 109 91]), ...
            'acpc: MNI volume 91x109x91 readable');
        v = mrw.QcView(volW, hdrW);
        ac = [46 55 47];
        acw = v.voxelToWorld(ac);
        fprintf('       AC world = %s\n', mat2str(acw, 6));
        check(norm(acw - [0 -18 20]) < 1e-6, ...
            'acpc: fixture AC world = [0 -18 20]');
        pcwTarget = [10 -38 25];
        pc = v.worldToVoxel(pcwTarget);
        check(norm(pc - [51 45 49.5]) < 1e-6, 'acpc: PC voxel from target world');
        dExp = norm(pcwTarget - acw);
        info = v.setAcPc(ac, pc);
        check(info.Ok, 'acpc: setAcPc ok');
        check(strcmp(info.Mode, 'acpc'), 'acpc: Mode=acpc');
        check(norm(info.ACVoxel - ac) < 1e-12 && norm(info.PCVoxel - pc) < 1e-9, ...
            'acpc: AC/PC voxels recorded');
        check(norm(info.ACWorld - acw) < 1e-9 && ...
            norm(info.PCWorld - pcwTarget) < 1e-6, 'acpc: AC/PC world recorded');
        check(abs(info.ACPC.distanceMm - dExp) < 1e-6, ...
            sprintf('acpc: distance = %.6f mm', dExp));
        angExp = acosd(max(-1, min(1, -(pcwTarget(2) - acw(2)) / dExp)));
        check(abs(info.ACPC.angleDeg - angExp) < 1e-6, ...
            sprintf('acpc: angle = %.6f deg', angExp));
        check(numel(info.ACPC.rotationDeg) == 3 && ...
            all(isfinite(info.ACPC.rotationDeg)), 'acpc: rotationDeg finite 1x3');
        check(norm(info.ACPC.translationMm - (-acw)) < 1e-9, ...
            'acpc: translationMm = -ACWorld');
        % 几何断言：AC -> display≈[0 0 0]，PC -> display 方向≈-Y，距离保持
        dAC = v.voxelToDisplay(ac);
        dPC = v.voxelToDisplay(pc);
        fprintf('       AC display=%s PC display=%s\n', ...
            mat2str(dAC, 4), mat2str(dPC, 4));
        check(norm(dAC) < 1e-9, 'acpc: AC maps to display origin');
        check(abs(dPC(1)) < 1e-9 && abs(dPC(3)) < 1e-9 && dPC(2) < 0, ...
            'acpc: PC maps to display -Y (posterior)');
        check(abs(dPC(2) + dExp) < 1e-6 && ...
            abs(norm(dPC - dAC) - dExp) < 1e-6, 'acpc: distance preserved in display');
        % 十字线仍以 voxel 为准
        v.setCrosshair(ac);
        labels = {'axial', 'coronal', 'sagittal'};
        for i = 1:numel(labels)
            o = labels{i};
            idx = v.currentSliceIndex(o);
            [img, si] = v.slice(o, idx);
            check(~isempty(img) && isempty(si.Message), ...
                sprintf('acpc(%s): slice works after alignment', o));
        end
        % AC=PC 失败
        before = v.getInfo().DisplayMatrix;
        infoBad = v.setAcPc(ac, ac);
        check(~infoBad.Ok, 'acpc: AC=PC fails (Ok=false)');
        check(strcmp(infoBad.Message, 'AC 与 PC 距离过小，无法配平'), ...
            'acpc: AC=PC exact Chinese message');
        check(norm(v.getInfo().DisplayMatrix - before, 'fro') < 1e-12, ...
            'acpc: failure keeps previous display matrix');
        % 世界距离 < 1e-6 mm
        pcTiny = v.worldToVoxel(acw + [1e-7 0 0]);
        infoTiny = v.setAcPc(ac, pcTiny);
        check(~infoTiny.Ok && ~isempty(infoTiny.Message), ...
            'acpc: world distance < 1e-6 mm rejected');
        % 无效输入
        infoInv = v.setAcPc('a', [1 2 3]);
        check(~infoInv.Ok && ~isempty(infoInv.Message), 'acpc: invalid input rejected');
        % 清除配平
        infoClr = v.clearAcPc();
        check(infoClr.Ok && strcmp(infoClr.Mode, 'native') && ...
            isempty(infoClr.ACVoxel) && isempty(infoClr.PCVoxel), ...
            'acpc: clearAcPc restores native');
        check(norm(infoClr.DisplayMatrix - eye(4), 'fro') < 1e-12, ...
            'acpc: clearAcPc display matrix identity');

        % 用户实测 AC/PC：后方略低的 PC 只需约11°配平，不应旋转169°而倒置头部。
        userAc = [4.075202941894517 14.083642225999114 0.8790846604567406];
        userPc = [4.075202941894503 -21.449396573580202 -5.889113206129792];
        userMat = eye(4); userMat(1:3, 4) = -32;
        userView = mrw.QcView(zeros(64, 64, 64), struct('mat', userMat));
        userAcVoxel = userView.worldToVoxel(userAc);
        userPcVoxel = userView.worldToVoxel(userPc);
        userInfo = userView.setAcPc(userAcVoxel, userPcVoxel);
        userR = userInfo.DisplayMatrix(1:3, 1:3);
        userDistance = norm(userPc-userAc);
        check(norm(userView.voxelToDisplay(userAcVoxel)) < 1e-9 && ...
            norm(userView.voxelToDisplay(userPcVoxel) - [0 -userDistance 0]) < 1e-9, ...
            'acpc real posterior-PC regression: AC origin and PC negative Y');
        check(abs(userInfo.ACPC.angleDeg - 10.7842978675626) < 1e-9, ...
            'acpc real posterior-PC regression: alignment angle about 10.78deg, not 169.22deg');
        check(norm(userR.'*userR-eye(3), 'fro') < 1e-12 && abs(det(userR)-1) < 1e-12, ...
            'acpc real posterior-PC regression: proper orthogonal rotation without reflection');
        check(userR(1,1) > 0.99 && userR(2,2) > 0.9 && userR(3,3) > 0.9, ...
            'acpc real posterior-PC regression: right/anterior/superior directions remain upright');
        clickVoxel = userAcVoxel + [5 -4 3];
        check(norm(userView.displayToVoxel(userView.voxelToDisplay(clickVoxel)) - clickVoxel) < 1e-9, ...
            'acpc real posterior-PC regression: display click coordinates invert to original voxel');
        userView.setCrosshair(clickVoxel);
        for orientation = {'axial', 'coronal', 'sagittal'}
            [~, si] = userView.slice(orientation{1});
            displayPoint = userView.voxelToDisplay(clickVoxel);
            col = si.XLim(1) + (si.CrosshairPixel(1)-0.5)*diff(si.XLim)/si.ImageSize(2);
            row = pixelRowToCoord(si, si.CrosshairPixel(2));
            check(abs(col-displayPoint(displayColAxis(orientation{1}))) <= si.PixelSize && ...
                abs(row-displayPoint(displayRowAxis(orientation{1}))) <= si.PixelSize, ...
                sprintf('acpc real posterior-PC regression: %s crosshair pixel/world mapping', orientation{1}));
        end
    end

    function secTriple()
        [volW, hdrW] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
        v = mrw.QcView(volW, hdrW);
        v.setAcPc([46 55 47], [51 45 49.5]);
        v.setCrosshair([46 55 47]);
        d = v.getInfo().CrosshairDisplay;
        labels = {'axial', 'coronal', 'sagittal'};
        infoS = cell(1, 3);
        pixS = zeros(1, 3);
        for i = 1:3
            o = labels{i};
            idx = v.currentSliceIndex(o);
            [img, si] = v.slice(o, idx);
            infoS{i} = si;
            pixS(i) = si.PixelSize;
            check(~isempty(img), sprintf('triple(%s): slice non-empty', o));
            % 十字线像素应在图像范围内（允许半像素边界）
            check(si.CrosshairPixel(1) >= 1 - 0.5 && ...
                si.CrosshairPixel(1) <= si.ImageSize(2) + 0.5 && ...
                si.CrosshairPixel(2) >= 1 - 0.5 && ...
                si.CrosshairPixel(2) <= si.ImageSize(1) + 0.5, ...
                sprintf('triple(%s): crosshair pixel inside image', o));
            % 像素→display 重建
            p = si.CrosshairPixel;
            colCoord = si.XLim(1) + (p(1) - 0.5) * diff(si.XLim) / si.ImageSize(2);
            rowCoord = pixelRowToCoord(si, p(2));
            switch o
                case 'axial'
                    % 列 = display X，行 = display Y
                    check(abs(colCoord - d(1)) <= si.PixelSize && ...
                        abs(rowCoord - d(2)) <= si.PixelSize, ...
                        'triple(axial): crosshair pixel -> display (<=1 px)');
                case 'coronal'
                    check(abs(colCoord - d(1)) <= si.PixelSize && ...
                        abs(rowCoord - d(3)) <= si.PixelSize, ...
                        'triple(coronal): crosshair pixel -> display (<=1 px)');
                otherwise
                    check(abs(colCoord - d(2)) <= si.PixelSize && ...
                        abs(rowCoord - d(3)) <= si.PixelSize, ...
                        'triple(sagittal): crosshair pixel -> display (<=1 px)');
            end
        end
        % 三种方向中共享 display 轴的像素下标必须一致：
        %   axial 列 & coronal 列 = X；axial 行 & sagittal 反向列 = Y；
        %   coronal 行 & sagittal 行 = Z（升序）
        a = infoS{1};  % axial
        c = infoS{2};  % coronal
        s = infoS{3};  % sagittal
        check(abs(a.CrosshairPixel(1) - c.CrosshairPixel(1)) <= 1, ...
            'triple: axial col == coronal col (display X, <=1 px)');
        check(abs(a.CrosshairPixel(2) + s.CrosshairPixel(1) - s.ImageSize(2) - 1) <= 1, ...
            'triple: axial row == reversed sagittal col (display Y, <=1 px)');
        check(abs(c.CrosshairPixel(2) - s.CrosshairPixel(2)) <= 1, ...
            'triple: coronal row == sagittal row (display Z, <=1 px)');
        % display 点反算体素应在十字线附近（切片法向取整 <= 半像素）
        dpt = [a.CrosshairPixel(1) * 0 + d(1), d(2), d(3)];
        vv = v.displayToVoxel(dpt);
        check(norm(vv - [46 55 47]) <= 1.0, ...
            'triple: crosshair display -> voxel within 1 voxel');
        % native 模式的同类一致性（fixture T1，用非对称十字线以区分行列）
        v2 = mrw.QcView(volT1, hdrT1);
        v2.setCrosshair([20 40 16]);
        [~, sA] = v2.slice('axial');
        [~, sC] = v2.slice('coronal');
        [~, sS] = v2.slice('sagittal');
        check(isequal(sA.CrosshairPixel, [20 40]), ...
            'triple(native axial): crosshair pixel [col=20 row=40] (+X/+Y)');
        check(isequal(sC.CrosshairPixel, [20 16]), ...
            'triple(native coronal): crosshair pixel [col=20 row=16] (+X/+Z)');
        check(isequal(sS.CrosshairPixel, [25 16]), ...
            'triple(native sagittal): crosshair pixel [col=25 row=16] (-Y/+Z)');
        check(abs(sA.CrosshairPixel(1) - sC.CrosshairPixel(1)) <= 1 && ...
            abs(sA.CrosshairPixel(2) + sS.CrosshairPixel(1) - 65) <= 1 && ...
            abs(sC.CrosshairPixel(2) - sS.CrosshairPixel(2)) <= 1, ...
            'triple(native): crosshair pixel consistent across orientations');
        check(sC.CrosshairPixel(2) == 16, ...
            'triple(native coronal): row follows +Z convention');
    end

    function secSliceIndex()
        v = mrw.QcView(volT1, hdrT1);
        v.setSliceIndex('axial', 5);
        c = v.getCrosshair();
        check(c(3) == 5 && v.currentSliceIndex('axial') == 5, ...
            'sliceIndex: axial set to 5');
        [~, si] = v.slice('axial');
        check(si.SliceIndex == 5, 'sliceIndex: default slice follows crosshair');
        v.setSliceIndex('coronal', 999);
        c = v.getCrosshair();
        check(c(2) == 64 && v.currentSliceIndex('coronal') == 64, ...
            'sliceIndex: coronal clamp to 64');
        v.setSliceIndex('sagittal', -5);
        c = v.getCrosshair();
        check(c(1) == 1 && v.currentSliceIndex('sagittal') == 1, ...
            'sliceIndex: sagittal clamp to 1');
        before = v.getCrosshair();
        v.setSliceIndex('axial', NaN);
        check(isequal(v.getCrosshair(), before), ...
            'sliceIndex: invalid index leaves crosshair unchanged');
        v.setCrosshair([999 -5 15]);
        check(isequal(v.getCrosshair(), [64 1 15]), ...
            'sliceIndex: setCrosshair clamps out-of-range');
        % 非 native 模式：设置序号后 currentSliceIndex 应回到同一序号
        v.setOriginAtWorld([0 0 0]);
        v.setCrosshair([20 30 10]);
        labels = {'axial', 'coronal', 'sagittal'};
        for i = 1:numel(labels)
            o = labels{i};
            v.setSliceIndex(o, 7);
            check(v.currentSliceIndex(o) == 7, ...
                sprintf('sliceIndex(%s): transformed mode roundtrip', o));
            [img, si] = v.slice(o);
            check(~isempty(img) && si.SliceIndex == 7, ...
                sprintf('sliceIndex(%s): slice at idx 7', o));
        end
        v.resetDisplay();
    end

    function secMontage()
        v = mrw.QcView(volT1, hdrT1);
        [m, mi] = v.montage('axial', 5);
        fprintf('       montage axial: size=%s N=%d tiles=%d highlight=%d\n', ...
            mat2str(mi.ImageSize), mi.N, mi.TileCount, mi.Highlight);
        check(isequal(mi.ImageSize, [5 * 64, 5 * 64]), ...
            'montage: 5x5 axial image size');
        check(mi.N == 5 && mi.TileCount == 25 && numel(mi.Tiles) == 25, ...
            'montage: N=5, 25 tiles');
        check(strcmp(mi.Orientation, 'axial') && mi.SliceCount == 30, ...
            'montage: orientation/count');
        t1 = mi.Tiles(1);
        check(t1.Row == 1 && t1.Col == 1 && t1.Height == 64 && t1.Width == 64, ...
            'montage: tile 1 Row/Col/Height/Width');
        check(mi.Tiles(2).Row == 1 && mi.Tiles(2).Col == 2, ...
            'montage: tile 2 Row=1 Col=2');
        check(mi.Tiles(6).Row == 2 && mi.Tiles(6).Col == 1, ...
            'montage: tile 6 Row=2 Col=1 (row-major layout)');
        check(issorted([mi.Tiles.SliceIndex]), 'montage: slice indices increasing');
        check(all([mi.Tiles.SliceIndex] >= 1 & [mi.Tiles.SliceIndex] <= 30), ...
            'montage: slice indices in range');
        [~, slPX] = v.slice('axial', mi.Tiles(1).SliceIndex);
        check(norm(mi.Tiles(1).XLim - slPX.XLim) < 1e-12, ...
            'montage: tile 1 XLim matches slice info');
        % 第一个 tile 内容 == 对应切片
        [sl1, ~] = v.slice('axial', mi.Tiles(1).SliceIndex);
        check(isequal(m(1:64, 1:64), sl1), 'montage: tile 1 content equals slice');
        tlast = mi.Tiles(end);
        [slL, ~] = v.slice('axial', tlast.SliceIndex);
        rows = (tlast.Row - 1) * 64 + (1:64);
        cols = (tlast.Col - 1) * 64 + (1:64);
        check(isequal(m(rows, cols), slL), 'montage: last tile content equals slice');
        % Highlight 对应当前切片
        check(mi.Highlight >= 1 && mi.Highlight <= 25, 'montage: Highlight in range');
        check(abs(mi.Tiles(mi.Highlight).SliceIndex - v.currentSliceIndex('axial')) <= 1, ...
            'montage: Highlight matches current crosshair slice');
        % n 自动缩小（30 层最多 5x5）
        [~, mi10] = v.montage('axial', 10);
        check(mi10.N == 5 && mi10.TileCount == 25, ...
            'montage: n clamped by slice count');
        [m2, mi2] = v.montage('axial', 2);
        check(mi2.N == 2 && isequal(size(m2), [2 * 64, 2 * 64]), ...
            'montage: n=2 works');
        [mc, mic] = v.montage('coronal', 5);
        check(mic.N == 5 && isequal(size(mc), [5 * 30, 5 * 64]), ...
            'montage: coronal tile image size');
        [~, mi0] = mrw.QcView().montage('axial', 3);
        check(~isempty(mi0.Message), 'montage: empty view returns Chinese message');
    end

    function secGetInfo()
        v = mrw.QcView(volT1, hdrT1);
        info = v.getInfo();
        need = {'Mode', 'HasVolume', 'IsNative', 'CrosshairVoxel', 'CrosshairWorld', ...
            'CrosshairDisplay', 'ACVoxel', 'ACWorld', 'PCVoxel', 'PCWorld', ...
            'ACPC', 'DisplayMatrix', 'Manual', 'Flips', 'Dim', 'VoxSize', ...
            'Message', 'Slices'};
        missing = {};
        for i = 1:numel(need)
            if ~isfield(info, need{i})
                missing{end+1} = need{i}; %#ok<AGROW>
            end
        end
        check(isempty(missing), sprintf('getInfo: required fields (missing=%s)', ...
            strjoin(missing, ',')));
        check(strcmp(info.Mode, 'native') && info.HasVolume && info.IsNative, ...
            'getInfo: mode/hasVolume/isNative');
        check(isequal(info.CrosshairVoxel, v.getCrosshair()), ...
            'getInfo: CrosshairVoxel');
        check(norm(info.CrosshairWorld - v.voxelToWorld(v.getCrosshair())) < 1e-12, ...
            'getInfo: CrosshairWorld');
        check(norm(info.CrosshairDisplay - v.voxelToDisplay(v.getCrosshair())) < 1e-12, ...
            'getInfo: CrosshairDisplay');
        acpcNeed = {'distanceMm', 'angleDeg', 'rotationDeg', 'translationMm'};
        okAcpc = all(isfield(info.ACPC, acpcNeed));
        check(okAcpc && isnan(info.ACPC.distanceMm), ...
            'getInfo: ACPC fields, NaN before AC-PC');
        check(all(isfield(info.Manual, {'TranslationMm', 'RotationDeg'})), ...
            'getInfo: Manual fields');
        check(all(isfield(info.Flips, {'LR', 'AP', 'IS'})), ...
            'getInfo: Flips fields');
        check(isequal(size(info.DisplayMatrix), [4 4]), 'getInfo: DisplayMatrix 4x4');
        check(isequal(info.Dim, [64 64 30]) && numel(info.VoxSize) == 3, ...
            'getInfo: Dim/VoxSize');
        check(all(isfield(info.Slices, {'axial', 'coronal', 'sagittal'})), ...
            'getInfo: Slices per orientation');
        check(info.Slices.axial.Count == 30 && info.Slices.coronal.Count == 64 && ...
            info.Slices.sagittal.Count == 64, 'getInfo: Slices Count');
        check(info.Slices.coronal.Index == v.currentSliceIndex('coronal'), ...
            'getInfo: Slices Index');
        v.setFlips(true, false, false);
        info = v.getInfo();
        check(info.Flips.LR && ~info.Flips.AP, 'getInfo: Flips reflected');
        v.setManual([1 2 3], [4 5 6]);
        info = v.getInfo();
        check(norm(info.Manual.TranslationMm - [1 2 3]) < 1e-12 && ...
            norm(info.Manual.RotationDeg - [4 5 6]) < 1e-12, ...
            'getInfo: Manual reflected');
        % 空视图消息
        infoE = mrw.QcView().getInfo();
        check(~infoE.HasVolume && ~isempty(infoE.Message), ...
            'getInfo: empty view Chinese message');
        % hasAcPc
        v.resetDisplay();
        check(~v.hasAcPc(), 'getInfo: hasAcPc false before AC-PC');
        v.setAcPc([10 20 10], [10 30 10]);
        check(v.hasAcPc(), 'getInfo: hasAcPc true after AC-PC');
    end

    function secInvalid()
        v0 = mrw.QcView();
        calls0 = { @() v0.slice('nonsense', 3), @() v0.slice(123), ...
            @() v0.slice('axial', 'abc'), @() v0.planeInfo([]), ...
            @() v0.planeInfo(42), @() v0.montage([], 3), ...
            @() v0.setCrosshair('x'), @() v0.setCrosshair([1 2]), ...
            @() v0.setSliceIndex('axial', []), @() v0.setSliceIndex([], 3), ...
            @() v0.setManual([1 2], [0 0 0]), @() v0.setManual([0 0 0], [1 2 3 4]), ...
            @() v0.setFlips('x', 0, 0), @() v0.setOriginAtWorld([]), ...
            @() v0.setAcPc([], []), @() v0.clearAcPc(), @() v0.resetDisplay(), ...
            @() v0.getInfo(), @() v0.getCrosshair(), ...
            @() v0.currentSliceIndex('axial'), @() v0.voxelToWorld([]), ...
            @() v0.worldToVoxel('x'), @() v0.voxelToDisplay([1 2]), ...
            @() v0.displayToVoxel(nan(1, 3))};
        thrown = '';
        for i = 1:numel(calls0)
            try
                calls0{i}();
            catch err
                thrown = sprintf('#%d %s', i, err.message);
            end
        end
        check(isempty(thrown), sprintf('invalid: empty view calls never throw (%s)', thrown));

        v = mrw.QcView(volT1, hdrT1);
        calls1 = { @() v.slice(123), @() v.slice('axial', 'abc'), ...
            @() v.planeInfo([]), @() v.setCrosshair(struct()), ...
            @() v.setSliceIndex('axial', 'x'), @() v.setManual([1 2 3], [1 2]), ...
            @() v.setFlips(true, 2, 'x'), @() v.setOriginAtWorld('x'), ...
            @() v.setAcPc('a', 'b'), @() v.setAcPc([1 2 3], [1 1 1]), ...
            @() v.montage('axial', -3), @() v.montage('axial', 'x')};
        thrown = '';
        for i = 1:numel(calls1)
            try
                calls1{i}();
            catch err
                thrown = sprintf('#%d %s', i, err.message);
            end
        end
        check(isempty(thrown), sprintf('invalid: loaded view calls never throw (%s)', thrown));
        % setAcPc 失败会返回中文消息
        infoBad = v.setAcPc([1 1 1], [1 1 1]);
        check(~infoBad.Ok && ~isempty(infoBad.Message), ...
            'invalid: setAcPc invalid coords returns message');
        % 全零体数据
        vz = mrw.QcView(zeros(6, 6, 6), struct('mat', eye(4)));
        [imgz, siz] = vz.slice('axial');
        check(isequal(size(imgz), [6 6]) && all(imgz(:) == 0) && isempty(siz.Message), ...
            'invalid: all-zero volume slices fine');
        vz.setOriginAtWorld([1 1 1]);
        [imgz2, ~] = vz.slice('axial');
        check(isequal(size(imgz2), [6 6]), 'invalid: all-zero volume resamples fine');
        % 体数据含 NaN/Inf：采样结果应被清理为 0
        V = rand(8, 8, 8);
        V(2, 3, 4) = NaN;
        V(5, 5, 5) = Inf;
        vn = mrw.QcView(V, struct('mat', eye(4)));
        vn.setOriginAtWorld([0 0 0]);
        [imgn, ~] = vn.slice('axial', 4);
        check(all(isfinite(imgn(:))), 'invalid: NaN/Inf sampled volume -> finite image');
    end

    function secFd()
        fd = mrw.QcModel.loadFdSeries(base, 'Sub01');
        fprintf('       FD(Jenkinson,Sub01): n=%d mean=%.4f thr=%.2f\n', ...
            numel(fd.Values), mean(fd.Values), fd.DefaultThreshold);
        check(fd.Available, 'fd: Sub01 Jenkinson available');
        check(strcmp(fd.Type, 'FD_Jenkinson'), 'fd: default type FD_Jenkinson');
        check(abs(fd.DefaultThreshold - 0.2) < 1e-12, ...
            'fd: Jenkinson default threshold 0.2');
        check(numel(fd.Values) == 60, 'fd: Sub01 60 frames');
        check(nnz(fd.Values > fd.DefaultThreshold) == 2, ...
            'fd: Sub01 has 2 bad frames (>0.2)');
        check(~isempty(strfind(fd.File, 'FD_Jenkinson_Sub01.txt')), ...
            'fd: File path recorded');
        check(isempty(fd.Message), 'fd: available file -> no message');
        check(isequal(fd.ID, 'Sub01'), 'fd: ID recorded');
        fd2 = mrw.QcModel.loadFdSeries(base, 'Sub02', 'FD_Power');
        check(fd2.Available && strcmp(fd2.Type, 'FD_Power'), ...
            'fd: FD_Power type');
        check(abs(fd2.DefaultThreshold - 0.5) < 1e-12, ...
            'fd: Power default threshold 0.5');
        check(numel(fd2.Values) == 60 && nnz(fd2.Values > 0.5) == 2, ...
            'fd: Sub02 Power 60 frames with 2 bad frames');
        fd3 = mrw.QcModel.loadFdSeries(base, 'Sub03', 'FD_Power');
        check(nnz(fd3.Values > 0.5) == 3, 'fd: Sub03 Power 3 bad frames');
        fd4 = mrw.QcModel.loadFdSeries(base, 'Sub03');
        check(nnz(fd4.Values > 0.2) == 4, 'fd: Sub03 Jenkinson 4 bad frames');
        % 缺失文件
        fdV = mrw.QcModel.loadFdSeries(base, 'Sub01', 'FD_VanDijk');
        check(~fdV.Available && ~isempty(fdV.Message), ...
            'fd: missing VanDijk -> Available=false + message');
        check(abs(fdV.DefaultThreshold - 0.2) < 1e-12, ...
            'fd: VanDijk threshold 0.2 even if missing');
        fdX = mrw.QcModel.loadFdSeries(base, 'Sub99');
        check(~fdX.Available && ~isempty(fdX.Message), 'fd: missing subject graceful');
        fdNoDir = mrw.QcModel.loadFdSeries(fullfile(base, 'no_such_dir'), 'Sub01');
        check(~fdNoDir.Available && ~isempty(fdNoDir.Message), ...
            'fd: missing workdir graceful');
        fdNoId = mrw.QcModel.loadFdSeries(base);
        check(~fdNoId.Available && ~isempty(fdNoId.Message), ...
            'fd: missing subject id graceful');
        fdAlias = mrw.QcModel.loadFdSeries(base, 'Sub01', 'jenkinson');
        check(fdAlias.Available && strcmp(fdAlias.Type, 'FD_Jenkinson'), ...
            'fd: alias jenkinson normalized');
        fdUnk = mrw.QcModel.loadFdSeries(base, 'Sub01', 'bogus');
        check(fdUnk.Available && strcmp(fdUnk.Type, 'FD_Jenkinson'), ...
            'fd: unknown type falls back to Jenkinson');
        check(~isempty(fdUnk.Message), 'fd: unknown type gives message');
        % 通配兜底：文件名不完全匹配 <ID>
        td = tempname();
        mkdir(fullfile(td, 'RealignParameter', 'SubX'));
        f = fullfile(td, 'RealignParameter', 'SubX', 'FD_Jenkinson_SubX_log.txt');
        fid = fopen(f, 'w');
        fprintf(fid, '0.10\n0.20\n0.30\n');
        fclose(fid);
        fdWild = mrw.QcModel.loadFdSeries(td, 'SubX');
        check(fdWild.Available && numel(fdWild.Values) == 3, ...
            'fd: wildcard fallback finds renamed file');
        % 直接放在 RealignParameter/ 下 + 空白/逗号混合分隔
        td2 = tempname();
        mkdir(fullfile(td2, 'RealignParameter'));
        f = fullfile(td2, 'RealignParameter', 'FD_Power_SubY.txt');
        fid = fopen(f, 'w');
        fprintf(fid, '0.11 0.22,0.33\n0.44\n');
        fclose(fid);
        fdMix = mrw.QcModel.loadFdSeries(td2, 'SubY', 'FD_Power');
        check(fdMix.Available && numel(fdMix.Values) == 4, ...
            'fd: file directly in RealignParameter parsed');
        check(norm(fdMix.Values - [0.11 0.22 0.33 0.44]) < 1e-12, ...
            'fd: whitespace/comma mixed parsing');
        % 空文件
        f = fullfile(td, 'RealignParameter', 'SubX', 'FD_Power_SubX.txt');
        fid = fopen(f, 'w');
        fprintf(fid, '\n\n');
        fclose(fid);
        fdEmpty = mrw.QcModel.loadFdSeries(td, 'SubX', 'FD_Power');
        check(~fdEmpty.Available && ~isempty(fdEmpty.Message), ...
            'fd: empty file graceful');
        % 批量
        hm = mrw.QcModel.headMotionSeries(base);
        check(hm.Available && isequal(hm.IDs, {'Sub01', 'Sub02', 'Sub03'}), ...
            'fd: headMotionSeries IDs available');
        check(numel(hm.FD_Jenkinson) == 3 && numel(hm.FD_Power) == 3 && ...
            numel(hm.FD_VanDijk) == 3, 'fd: headMotionSeries cell counts');
        check(numel(hm.FD_Jenkinson{1}) == 60 && numel(hm.FD_Power{2}) == 60, ...
            'fd: headMotionSeries values');
        check(all(cellfun(@isempty, hm.FD_VanDijk)), ...
            'fd: headMotionSeries VanDijk cells empty (missing)');
        check(abs(hm.Thresholds.FD_Jenkinson - 0.2) < 1e-12 && ...
            abs(hm.Thresholds.FD_Power - 0.5) < 1e-12, ...
            'fd: headMotionSeries thresholds');
        hm2 = mrw.QcModel.headMotionSeries(base, {'Sub02', 'Sub01'});
        check(isequal(hm2.IDs, {'Sub01', 'Sub02'}), ...
            'fd: headMotionSeries input IDs natural sorted');
        hm3 = mrw.QcModel.headMotionSeries(fullfile(base, 'no_such'));
        check(~hm3.Available && ~isempty(hm3.Message), ...
            'fd: headMotionSeries missing workdir graceful');
        try, rmdir(td, 's'); catch, end %#ok<CTCH>
        try, rmdir(td2, 's'); catch, end %#ok<CTCH>
    end

    function secPerf()
        v = mrw.QcView(volT1, hdrT1);
        v.slice('axial');   % 预热
        t = tic;
        for i = 1:100
            v.slice('axial', mod(i, 30) + 1);
        end
        t100 = toc(t);
        fprintf('       perf: 100 native slices = %.4f s\n', t100);
        check(t100 < 1.0, sprintf('perf: 100 native slices < 1 s (%.4f s)', t100));
        v.slice('coronal'); v.slice('sagittal');
        t = tic;
        v.slice('axial', v.currentSliceIndex('axial'));
        v.slice('coronal', v.currentSliceIndex('coronal'));
        v.slice('sagittal', v.currentSliceIndex('sagittal'));
        tTri = toc(t);
        fprintf('       perf: native triple redraw = %.4f s\n', tTri);
        check(tTri < 0.4, sprintf('perf: native triple redraw < 0.4 s (%.4f s)', tTri));
        % 非 native（AC-PC 配平后，MNI 91x109x91）三正交重绘
        [volW, hdrW] = mrw.QcModel.loadVolume( ...
            fullfile(base, 'T1ImgNewSegment', 'Sub01', 'wT1.nii'));
        v2 = mrw.QcView(volW, hdrW);
        v2.setAcPc([46 55 47], [51 45 49.5]);
        v2.setCrosshair([46 55 47]);
        v2.slice('axial', v2.currentSliceIndex('axial'));   % 预热网格缓存
        t = tic;
        v2.slice('axial', v2.currentSliceIndex('axial'));
        v2.slice('coronal', v2.currentSliceIndex('coronal'));
        v2.slice('sagittal', v2.currentSliceIndex('sagittal'));
        tTri2 = toc(t);
        fprintf('       perf: acpc triple redraw (91x109x91) = %.4f s\n', tTri2);
        check(tTri2 < 0.4, sprintf('perf: acpc triple redraw < 0.4 s (%.4f s)', tTri2));
        % montage 性能（5x5 native）
        t = tic;
        v.montage('axial', 5);
        tMon = toc(t);
        fprintf('       perf: 5x5 montage = %.4f s\n', tMon);
        check(tMon < 2.0, sprintf('perf: montage < 2 s (%.4f s)', tMon));
    end

    % =====================================================================
    % 计数器与断言
    % =====================================================================

    function check(cond, label)
        nTotal = nTotal + 1;
        ok = false;
        try
            ok = ~isempty(cond) && all(cond(:));
        catch
            ok = false;
        end
        if ok
            nPass = nPass + 1;
            fprintf('[ok]   %s\n', label);
        else
            fails{end + 1} = label; %#ok<AGROW>
            fprintf('[FAIL] %s\n', label);
        end
    end

    function fail(label)
        nTotal = nTotal + 1;
        fails{end + 1} = label; %#ok<AGROW>
        fprintf('[FAIL] %s\n', label);
    end

    function section(name, fn)
        fprintf('\n-- %s --\n', name);
        try
            fn();
        catch err
            nTotal = nTotal + 1;
            msg = regexprep(err.message, '\s+', ' ');
            fails{end + 1} = sprintf('section %s error: %s', name, msg); %#ok<AGROW>
            fprintf('[FAIL] section %s error: %s\n', name, msg);
        end
    end
end

% =========================================================================
% 文件级辅助函数
% =========================================================================

function n = nLines(filePath)
% 统计非空行数
    n = 0;
    fid = fopen(filePath, 'r');
    if fid < 0
        n = -1;
        return;
    end
    while true
        ln = fgetl(fid);
        if ~ischar(ln)
            break;
        end
        if ~isempty(strtrim(ln))
            n = n + 1;
        end
    end
    fclose(fid);
end

function img = spmSlice(legacy, o)
    switch o
        case 'axial', img = legacy.';
        case 'coronal', img = flipud(legacy);
        otherwise, img = fliplr(flipud(legacy));
    end
end

function vox = nativeVox(o, col, row, k, dims)
    switch o
        case 'axial', vox = [col, row, k];
        case 'coronal', vox = [col, k, row];
        otherwise, vox = [k, dims(2) - col + 1, row];
    end
end

function cA = displayColAxis(o)
    cA = 1;
    if strcmp(o, 'sagittal'), cA = 2; end
end

function rA = displayRowAxis(o)
    rA = 3;
    if strcmp(o, 'axial'), rA = 2; end
end

function c = pixelRowToCoord(si, row)
    c = si.YLim(1) + (row - 0.5) * diff(si.YLim) / si.ImageSize(1);
end

function lab = expLabel(w)
% 由世界方向向量得到期望的显示轴标签（与契约约定一致）
    lab = '—';
    if isempty(w) || numel(w) < 3 || any(~isfinite(w(1:3)))
        return;
    end
    w = w(1:3);
    if norm(w) < 1e-12
        return;
    end
    [~, ax] = max(abs(w));
    switch ax
        case 1
            if w(1) >= 0
                lab = 'L→R';
            else
                lab = 'R→L';
            end
        case 2
            if w(2) >= 0
                lab = 'P→A';
            else
                lab = 'A→P';
            end
        otherwise
            if w(3) >= 0
                lab = 'I→S';
            else
                lab = 'S→I';
            end
    end
end

function R = rotX(deg)
    a = deg * pi / 180;
    R = [1 0 0; 0 cos(a) -sin(a); 0 sin(a) cos(a)];
end

function R = rotY(deg)
    a = deg * pi / 180;
    R = [cos(a) 0 sin(a); 0 1 0; -sin(a) 0 cos(a)];
end

function R = rotZ(deg)
    a = deg * pi / 180;
    R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
end
