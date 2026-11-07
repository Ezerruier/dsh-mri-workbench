classdef QcView < handle
% QcView  人工 QC 图像显示几何引擎（纯计算、无 UI 依赖）
%
% 用途：
%   为 mrw.QcPanel / mrw.QcViewer 的三正交联动、原点校准、AC-PC 配平、方位微调、
%   翻转、多切片网格等显示功能提供统一的「体素 ↔ 世界 mm ↔ 显示 mm」几何与
%   2D 切片采样。所有显示变换只影响显示，不写回 NIfTI。
%
% 坐标约定（与设计契约 docs/QC_UI_V2_CONTRACT.md §3.1 一致）：
%   * voxel ：1-based 连续坐标 [i j k]（与 mrw.QcModel.makeSlice / SPM 一致）。
%   * world ：mm，由 hdr.mat（4x4，1-based 体素→mm，SPM 约定）定义。
%   * display：world 经显示变换 A 后的 mm 坐标；A = F * M_manual * M_base，
%       M_base: native=I；origin=T(-originWorld)；acpc=R_acpc*T(-acWorld)
%       M_manual = T(translationMm) * Rz(yaw)*Ry(roll)*Rx(pitch)（角度为度）
%       F = 翻转对角阵（flipLR/flipAP/flipIS 分别翻转 display X/Y/Z）
%
% 显示方向以 SPM/DPABI orthviews 的 World Space / mode=1 为基准：
%   axial：列=+display X，行=+display Y；coronal：列=+X，行=+Z；
%   sagittal：列=-display Y，行=+Z。axes.YDir='normal'，矢状 XDir='reverse'。
% native 表示 A=I；正对角原始仿射直接取片，其它仿射（含斜切）按世界网格采样。
% 所有其它显示模式复用同一方向约定、角点边界和缓存的 griddedInterpolant。
% info.XLim/YLim 为半像素外扩边界；imagesc 的 XData/YData 应由边界换算为像素中心。
% planeInfo.PixelToDisplay：[col;row;1] → display [x;y;z]；坐标单位为 mm。
% resampledVolume 返回实际显示网格 [X,Y,Z] 的 3D 数据及 SPM 1-based 仿射；不写文件。
% 插值默认为 linear（可 setInterpolation('nearest')），越界填 0。
%
% 用法：
%   v = mrw.QcView(vol, hdr);                 % 也可空构造后 setVolume
%   [img, info] = v.slice('axial');           % 缺省取十字线所在层
%   [img, info] = v.slice('coronal', 20);
%   v.setCrosshair([32 32 16]);               % 联动三正交
%   v.setOriginAtWorld([0 0 0]);              % 原点校准（显示层）
%   v.setAcPc(acVoxel, pcVoxel);               % AC-PC 配平（显示层）
%   v.setManual([1 0 0], [0 0 90]);           % 6 自由度微调
%   v.setFlips(true, false, false);
%   [m, mi] = v.montage('axial', 5);          % 5x5 等间隔切片拼图
%   info = v.getInfo();                        % 状态（供面板/状态 JSON）
%
% 约定：所有方法对空体积/无效参数不抛异常，返回空值 + 中文 info.Message。
%
% 编写：view-engine（MRI 静息态工作台 v2）。

    properties (Access = public)
        Interpolation = 'linear';   % 非 native 重采样插值：'linear' | 'nearest'
    end

    properties (Access = private)
        Vol = [];
        Dim = [0 0 0];
        VoxSize = [1 1 1];
        Mat = zeros(4);
        MatValid = false;
        HdrFile = '';
        Mode = 'native';
        OriginWorld = [0 0 0];
        ACVoxel = [];
        PCVoxel = [];
        ACWorld = [];
        PCWorld = [];
        ManualT = [0 0 0];
        ManualR = [0 0 0];
        FlipLR = false;
        FlipAP = false;
        FlipIS = false;
        Crosshair = [1 1 1];
        Cache = [];
        CacheValid = false;
        Sampler = [];
        SamplerMethod = '';
        LastMessage = '';
    end

    methods

        % =================================================================
        % 构造 / 体数据
        % =================================================================

        function obj = QcView(vol, hdr)
            % QcView  构造显示几何引擎（vol/hdr 可选；空则后续 setVolume）
            if nargin >= 1 && ~isempty(vol)
                if nargin >= 2
                    obj.setVolume(vol, hdr);
                else
                    obj.setVolume(vol);
                end
            end
        end

        function setVolume(obj, vol, hdr)
            % setVolume  设置体数据与头信息；重置显示变换为 native、十字线居中
            obj.Vol = [];
            obj.Sampler = [];
            obj.SamplerMethod = '';
            obj.Dim = [0 0 0];
            obj.VoxSize = [1 1 1];
            obj.Mat = eye(4);
            obj.MatValid = false;
            obj.HdrFile = '';
            obj.Mode = 'native';
            obj.OriginWorld = [0 0 0];
            obj.ACVoxel = [];
            obj.PCVoxel = [];
            obj.ACWorld = [];
            obj.PCWorld = [];
            obj.ManualT = [0 0 0];
            obj.ManualR = [0 0 0];
            obj.FlipLR = false;
            obj.FlipAP = false;
            obj.FlipIS = false;
            obj.Crosshair = [1 1 1];
            obj.LastMessage = '';
            obj.invalidate();

            if nargin < 2 || isempty(vol) || ~isnumeric(vol) || ~isreal(vol)
                obj.LastMessage = '未提供有效的 3D 体数据。';
                return;
            end
            try
                D = double(vol);
            catch
                obj.LastMessage = '体数据无法转换为 double。';
                return;
            end
            sz = size(D);
            while numel(sz) < 3
                sz(end + 1) = 1; %#ok<AGROW>
            end
            if numel(sz) > 3
                extra = prod(sz(4:end));
                if extra > 1
                    D = reshape(D, sz(1), sz(2), sz(3), extra);
                    D = mean(D, 4);
                else
                    D = reshape(D, sz(1), sz(2), sz(3));
                end
            end
            if any(sz(1:3) < 1)
                obj.LastMessage = '体数据尺寸无效。';
                return;
            end
            obj.Vol = D;
            obj.Dim = double(sz(1:3));
            vs = [1 1 1];

            % ---- 头信息 ----
            M = [];
            if nargin >= 3 && isstruct(hdr)
                if isfield(hdr, 'File') && ischar(hdr.File)
                    obj.HdrFile = hdr.File;
                end
                if isfield(hdr, 'mat') && isnumeric(hdr.mat) && ...
                        isequal(size(hdr.mat), [4 4]) && all(isfinite(hdr.mat(:))) && ...
                        abs(det(double(hdr.mat(1:3, 1:3)))) > 1e-12
                    M = double(hdr.mat);
                end
                if isfield(hdr, 'voxSize') && isnumeric(hdr.voxSize) && ...
                        numel(hdr.voxSize) >= 3 && all(isfinite(hdr.voxSize(1:3)))
                    vs = double(hdr.voxSize(1:3));
                    vs = vs(:).';
                end
            end
            if isempty(M)
                obj.Mat = eye(4);
                obj.MatValid = false;
                obj.VoxSize = [1 1 1];
                if nargin >= 3 && ~isempty(hdr)
                    obj.LastMessage = '图像头信息 hdr.mat 无效，已按体素 1 mm 等间距显示。';
                end
            else
                obj.Mat = M;
                obj.MatValid = true;
                if any(~isfinite(vs)) || all(vs <= 0)
                    vs = sqrt(sum(M(1:3, 1:3) .^ 2, 1));
                end
                vs(~isfinite(vs)) = 1;
                vs(vs <= 0) = 1;
                obj.VoxSize = vs;
            end

            % 十字线居中
            obj.Crosshair = max(1, round((obj.Dim + 1) / 2));
            obj.invalidate();
        end

        function tf = hasVolume(obj)
            % hasVolume  是否已加载非空 3D 体数据
            tf = ~isempty(obj.Vol) && isnumeric(obj.Vol) && ...
                numel(obj.Dim) == 3 && all(obj.Dim >= 1);
            if ~tf
                tf = false;
            else
                tf = logical(tf);
            end
        end

        function setInterpolation(obj, method)
            % setInterpolation  设置非 native 重采样插值方法（'linear' | 'nearest'）
            %   非法值忽略（保持原值）；正对角 native 直接切片，不受影响。
            m = '';
            if ischar(method)
                m = lower(strtrim(method));
            elseif isstring(method) && isscalar(method)
                m = lower(strtrim(char(method)));
            end
            if any(strcmp(m, {'linear', 'nearest'}))
                obj.Interpolation = m;
            end
        end

        % =================================================================
        % 切片 / 网格信息 / 十字线联动
        % =================================================================

        function [img, info] = slice(obj, orientation, sliceIndex)
            % slice  生成指定方向、指定层号的 2D 切片（越界自动 clamp）
            %   [img, info] = obj.slice(orientation)
            %   [img, info] = obj.slice(orientation, sliceIndex)
            %   orientation: 'axial'|'coronal'|'sagittal'（大小写/中文别名可接受）
            %   sliceIndex 缺省取十字线所在的世界显示层；所有模式采用 SPM 方向。
            info = obj.emptySliceInfo();
            img = [];
            if nargin < 3
                sliceIndex = [];
            end
            if ~obj.hasVolume()
                info.Message = '未加载图像体积，无法生成切片。';
                return;
            end
            try
                [o, total, letter, labelEn] = obj.normalizeOrientation(orientation, obj.Dim);
                g = obj.planeGeometry(o, sliceIndex);
                if ~g.Valid
                    info.Orientation = o;
                    info.Message = g.Message;
                    return;
                end
                k = g.SliceIndex;
                if g.DirectNative
                    switch o
                        case 'axial'
                            img = obj.Vol(:, :, k).';
                        case 'coronal'
                            img = reshape(obj.Vol(:, k, :), obj.Dim(1), obj.Dim(3)).';
                        otherwise
                            img = fliplr(reshape(obj.Vol(k, :, :), obj.Dim(2), obj.Dim(3)).');
                    end
                    img = double(img);
                    if ~ismatrix(img)
                        img = reshape(img, size(img, 1), []);
                    end
                else
                    img = obj.samplePlane(o, g, k);
                    if isempty(img)
                        img = zeros(g.ImageSize);
                    end
                end
                info.Orientation = o;
                info.SliceIndex = k;
                info.SliceCount = g.SliceCount;
                info.ImageSize = size(img);
                info.PixelSize = g.PixelSize;
                info.XLim = g.XLim;
                info.YLim = g.YLim;
                info.SliceLabel = sprintf('%s %s=%d/%d', labelEn, letter, k, g.SliceCount);
                info.IsNative = g.IsNative;
                info.XAxisLabel = g.XAxisLabel;
                info.YAxisLabel = g.YAxisLabel;
                info.SliceCoord = g.SliceCoord;
                info.CrosshairVoxel = obj.Crosshair;
                info.CrosshairDisplay = obj.voxelToDisplay(obj.Crosshair);
                info.CrosshairPixel = obj.crosshairPixel(o, g);
                info.Message = '';
            catch err
                info.Message = sprintf('生成切片失败：%s', obj.errText(err));
            end
        end

        function info = planeInfo(obj, orientation)
            % planeInfo  返回指定方向的显示网格信息（不采样）
            info = obj.emptyPlaneInfo();
            if ~obj.hasVolume()
                info.Message = '未加载图像体积，无法生成切片网格。';
                return;
            end
            try
                [o, ~, ~, ~] = obj.normalizeOrientation(orientation, obj.Dim);
                g = obj.planeGeometry(o);
                info.Orientation = o;
                info.SliceIndex = g.SliceIndex;
                info.SliceCount = g.SliceCount;
                info.ImageSize = g.ImageSize;
                info.PixelSize = g.PixelSize;
                info.XLim = g.XLim;
                info.YLim = g.YLim;
                info.IsNative = g.IsNative;
                info.XAxisLabel = g.XAxisLabel;
                info.YAxisLabel = g.YAxisLabel;
                info.SliceCoord = g.SliceCoord;
                info.PixelToDisplay = g.T;
                info.Message = g.Message;
            catch err
                info.Message = sprintf('生成切片网格失败：%s', obj.errText(err));
            end
        end

        function idx = currentSliceIndex(obj, orientation)
            % currentSliceIndex  十字线所在切片的显示序号（1-based）
            idx = 1;
            if ~obj.hasVolume()
                return;
            end
            try
                [o, total] = obj.normalizeOrientation(orientation, obj.Dim);
                total = max(total, 1);
                g = obj.getGrid();
                if ~g.Valid
                    idx = min(max(round((total + 1) / 2), 1), total);
                    return;
                end
                d = obj.voxelToDisplay(obj.Crosshair);
                switch o
                    case 'axial'
                        vals = g.zaxis;
                        v = d(3);
                    case 'coronal'
                        vals = g.yaxis;
                        v = d(2);
                    otherwise
                        vals = g.xaxis;
                        v = d(1);
                end
                idx = round(obj.indexOnValues(vals, v));
                idx = min(max(idx, 1), max(numel(vals), 1));
            catch
                idx = 1;
            end
        end

        function setSliceIndex(obj, orientation, idx)
            % setSliceIndex  沿指定方向移动十字线（等价鼠标滚切片）
            if ~obj.hasVolume()
                obj.LastMessage = '未加载图像体积，无法移动切片。';
                return;
            end
            if nargin < 3 || ~isnumeric(idx) || ~isscalar(idx) || ~isfinite(idx)
                obj.LastMessage = '切片序号无效（需要 1..SliceCount 的数值）。';
                return;
            end
            try
                [o, total] = obj.normalizeOrientation(orientation, obj.Dim);
                total = max(total, 1);
                k = min(max(round(double(idx)), 1), total);
                g = obj.getGrid();
                if ~g.Valid
                    obj.LastMessage = g.Message;
                    return;
                end
                switch o
                    case 'axial'
                        vals = g.zaxis;
                        normalAxis = 3;
                    case 'coronal'
                        vals = g.yaxis;
                        normalAxis = 2;
                    otherwise
                        vals = g.xaxis;
                        normalAxis = 1;
                end
                k = min(max(k, 1), max(numel(vals), 1));
                d = obj.voxelToDisplay(obj.Crosshair);
                d(normalAxis) = vals(k);
                vox = obj.displayToVoxel(d);
                if ~isempty(vox)
                    obj.setCrosshair(vox);
                end
            catch err
                obj.LastMessage = sprintf('移动切片失败：%s', obj.errText(err));
            end
        end

        function [img, info] = montage(obj, orientation, n)
            % montage  n×n 等间隔切片拼图（缺省 n=5；切片数不足时自动缩小 n）
            info = obj.emptyMontageInfo();
            img = [];
            if ~obj.hasVolume()
                info.Message = '未加载图像体积，无法生成多切片网格。';
                return;
            end
            try
                [o, ~, ~, ~] = obj.normalizeOrientation(orientation, obj.Dim);
                if nargin < 3 || isempty(n) || ~isnumeric(n) || ~isscalar(n) || ~isfinite(n)
                    n = 5;
                end
                n = min(max(round(double(n)), 1), 10);
                total = obj.sliceCountFor(o);
                if total < 1
                    info.Message = '该方向没有可用切片。';
                    info.Orientation = o;
                    return;
                end
                n = min(n, max(1, floor(sqrt(total))));
                nt = n * n;
                idxs = round(linspace(1, total, nt));
                idxs = min(max(idxs, 1), total);
                [sl0, si0] = obj.slice(o, idxs(1));
                if isempty(sl0)
                    info.Message = si0.Message;
                    info.Orientation = o;
                    return;
                end
                nr = size(sl0, 1);
                nc = size(sl0, 2);
                img = zeros(nr * n, nc * n);
                Tiles = struct('SliceIndex', {}, 'Row', {}, 'Col', {}, ...
                    'Height', {}, 'Width', {}, 'XLim', {}, 'YLim', {});
                for r = 1:n
                    for c = 1:n
                        t = (r - 1) * n + c;
                        [sl, si] = obj.slice(o, idxs(t));
                        if isempty(sl)
                            sl = zeros(nr, nc);
                        end
                        if ~isequal(size(sl), [nr nc])
                            sl = zeros(nr, nc);
                        end
                        rows = (r - 1) * nr + (1:nr);
                        cols = (c - 1) * nc + (1:nc);
                        img(rows, cols) = sl;
                        Tiles(t) = struct('SliceIndex', si.SliceIndex, ...
                            'Row', r, 'Col', c, 'Height', nr, 'Width', nc, ...
                            'XLim', si.XLim, 'YLim', si.YLim);
                    end
                end
                info.Orientation = o;
                info.N = n;
                info.SliceCount = total;
                info.Tiles = Tiles;
                info.TileCount = nt;
                info.ImageSize = size(img);
                info.XLim = si0.XLim;
                info.YLim = si0.YLim;
                info.PixelSize = si0.PixelSize;
                info.IsNative = si0.IsNative;
                info.XAxisLabel = si0.XAxisLabel;
                info.YAxisLabel = si0.YAxisLabel;
                target = obj.currentSliceIndex(o);
                [~, highlight] = min(abs([Tiles.SliceIndex] - target));
                info.Highlight = highlight;
                info.Message = '';
            catch err
                info.Message = sprintf('生成多切片网格失败：%s', obj.errText(err));
            end
        end

        function setCrosshair(obj, voxel)
            % setCrosshair  设置十字线（连续 1-based 体素坐标，clamp 到体积内）
            v = obj.validateVec3(voxel);
            if isempty(v)
                obj.LastMessage = '十字线体素坐标无效（需要 1x3 数值向量）。';
                return;
            end
            if ~obj.hasVolume()
                obj.LastMessage = '未加载图像体积，无法设置十字线。';
                return;
            end
            v = min(max(v(:).', [1 1 1]), obj.Dim);
            obj.Crosshair = v;
            obj.LastMessage = '';
        end

        function p = getCrosshair(obj)
            % getCrosshair  当前十字线体素坐标 [i j k]
            p = obj.Crosshair;
            if ~obj.hasVolume()
                p = [1 1 1];
                return;
            end
            p = min(max(p(:).', [1 1 1]), obj.Dim);
        end

        % =================================================================
        % 坐标变换
        % =================================================================

        function p = voxelToWorld(obj, p)
            % voxelToWorld  体素（1-based）→ 世界 mm
            if ~obj.hasVolume()
                p = [];
                return;
            end
            p = obj.applyAffine(obj.Mat, p);
        end

        function p = worldToVoxel(obj, p)
            % worldToVoxel  世界 mm → 体素（1-based）
            if ~obj.hasVolume()
                p = [];
                return;
            end
            if obj.MatValid && abs(det(obj.Mat(1:3, 1:3))) > 1e-12
                p = obj.applyAffine(inv(obj.Mat), p);
            else
                p = obj.applyAffine(obj.Mat, p);
            end
        end

        function p = voxelToDisplay(obj, p)
            % voxelToDisplay  体素（1-based）→ 显示 mm
            if ~obj.hasVolume()
                p = [];
                return;
            end
            w = obj.voxelToWorld(p);
            p = obj.applyAffine(obj.displayMatrix(), w);
        end

        function p = displayToVoxel(obj, p)
            % displayToVoxel  显示 mm → 体素（1-based）
            if ~obj.hasVolume()
                p = [];
                return;
            end
            A = obj.displayMatrix();
            if abs(det(A(1:3, 1:3))) > 1e-12
                w = obj.applyAffine(inv(A), p);
            else
                w = p;
            end
            p = obj.worldToVoxel(w);
        end

        % =================================================================
        % 显示变换（原点 / AC-PC / 手动 / 翻转）
        % =================================================================

        function info = setOriginAtWorld(obj, originWorld)
            % setOriginAtWorld  以世界 mm 点作为显示原点（base='origin'）
            info = obj.getInfo();
            info.Ok = false;
            v = obj.validateVec3(originWorld);
            if isempty(v)
                info.Message = '显示原点无效（需要 1x3 数值向量，单位 mm）。';
                return;
            end
            if ~obj.hasVolume()
                info.Message = '未加载图像体积，无法设置显示原点。';
                return;
            end
            obj.OriginWorld = v(:).';
            obj.Mode = 'origin';
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        function info = setAcPc(obj, acVoxel, pcVoxel)
            % setAcPc  拾取 AC/PC 体素坐标并做 AC-PC 显示配平（base='acpc'）
            %   AC → display≈[0 0 0]，PC → display 方向≈-Y（后方），距离保持；
            %   失败（坐标无效或 AC/PC 距离 < 1e-6 mm）返回 info.Ok=false + 中文 Message。
            info = obj.getInfo();
            info.Ok = false;
            if ~obj.hasVolume()
                info.Message = '未加载图像体积，无法设置 AC-PC。';
                return;
            end
            ac = obj.validateVec3(acVoxel);
            pc = obj.validateVec3(pcVoxel);
            if isempty(ac) || isempty(pc)
                info.Message = 'AC/PC 体素坐标无效（需要 1x3 数值向量）。';
                return;
            end
            acw = obj.voxelToWorld(ac);
            pcw = obj.voxelToWorld(pc);
            if isempty(acw) || isempty(pcw)
                info.Message = 'AC/PC 坐标无法换算到世界坐标。';
                return;
            end
            d = norm(pcw(:) - acw(:));
            if ~isfinite(d) || d < 1e-6
                info.Message = 'AC 与 PC 距离过小，无法配平';
                return;
            end
            obj.ACVoxel = ac(:).';
            obj.PCVoxel = pc(:).';
            obj.ACWorld = acw(:).';
            obj.PCWorld = pcw(:).';
            obj.Mode = 'acpc';
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        function info = clearAcPc(obj)
            % clearAcPc  清除 AC-PC 配平（base 回 native；保留手动微调/翻转）
            obj.ACVoxel = [];
            obj.PCVoxel = [];
            obj.ACWorld = [];
            obj.PCWorld = [];
            obj.Mode = 'native';
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        function info = setManual(obj, translationMm, rotationDeg)
            % setManual  手动 6 自由度微调（平移 mm + 旋转度，叠加在 base 之上）
            info = obj.getInfo();
            info.Ok = false;
            t = obj.validateVec3(translationMm);
            r = obj.validateVec3(rotationDeg);
            if isempty(t) || isempty(r)
                info.Message = '平移/旋转参数无效（需要各 1x3 数值向量，单位 mm/度）。';
                return;
            end
            obj.ManualT = t(:).';
            obj.ManualR = r(:).';
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        function info = setFlips(obj, flipLR, flipAP, flipIS)
            % setFlips  左右/前后/上下翻转（只影响显示）
            info = obj.getInfo();
            info.Ok = false;
            a = obj.validateLogical(flipLR);
            b = obj.validateLogical(flipAP);
            c = obj.validateLogical(flipIS);
            if isempty(a) || isempty(b) || isempty(c)
                info.Message = '翻转参数无效（需要逻辑标量）。';
                return;
            end
            obj.FlipLR = a;
            obj.FlipAP = b;
            obj.FlipIS = c;
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        function info = resetDisplay(obj)
            % resetDisplay  重置方位：base=native、manual=0、flips=false、十字线居中
            obj.Mode = 'native';
            obj.OriginWorld = [0 0 0];
            obj.ACVoxel = [];
            obj.PCVoxel = [];
            obj.ACWorld = [];
            obj.PCWorld = [];
            obj.ManualT = [0 0 0];
            obj.ManualR = [0 0 0];
            obj.FlipLR = false;
            obj.FlipAP = false;
            obj.FlipIS = false;
            if obj.hasVolume()
                obj.Crosshair = max(1, round((obj.Dim + 1) / 2));
            else
                obj.Crosshair = [1 1 1];
            end
            obj.LastMessage = '';
            obj.invalidate();
            info = obj.getInfo();
            info.Ok = true;
        end

        % =================================================================
        % 状态
        % =================================================================

        function info = getInfo(obj)
            % getInfo  返回当前显示状态（模式/十字线/AC-PC/矩阵/手动/翻转/尺寸/消息）
            info = struct();
            A = obj.displayMatrix();
            info.Mode = obj.Mode;
            info.HasVolume = obj.hasVolume();
            info.IsNative = obj.isNativeMode();
            info.Dim = obj.Dim;
            info.VoxSize = obj.VoxSize;
            info.DisplayMatrix = A;
            info.OriginWorld = obj.OriginWorld;
            info.Manual = struct('TranslationMm', obj.ManualT, ...
                'RotationDeg', obj.ManualR);
            info.Flips = struct('LR', obj.FlipLR, 'AP', obj.FlipAP, 'IS', obj.FlipIS);
            if obj.hasVolume()
                p = obj.getCrosshair();
                info.CrosshairVoxel = p;
                info.CrosshairWorld = obj.voxelToWorld(p);
                info.CrosshairDisplay = obj.voxelToDisplay(p);
            else
                info.CrosshairVoxel = [];
                info.CrosshairWorld = [];
                info.CrosshairDisplay = [];
            end
            info.ACVoxel = obj.ACVoxel;
            info.ACWorld = obj.ACWorld;
            info.PCVoxel = obj.PCVoxel;
            info.PCWorld = obj.PCWorld;
            d = NaN;
            ang = NaN;
            rotd = [0 0 0];
            trans = [0 0 0];
            if ~isempty(obj.ACWorld) && ~isempty(obj.PCWorld) && ...
                    ~isempty(obj.ACVoxel) && ~isempty(obj.PCVoxel)
                v = obj.PCWorld(:) - obj.ACWorld(:);
                d = norm(v);
                if isfinite(d) && d > 1e-12
                    cosv = max(-1, min(1, -v(2) / d));
                    ang = acosd(cosv);
                end
                R = obj.acpcRotation();
                rotd = obj.rotToEulerDeg(R(1:3, 1:3));
                trans = -obj.ACWorld(:).';
            end
            info.ACPC = struct('distanceMm', d, 'angleDeg', ang, ...
                'rotationDeg', rotd, 'translationMm', trans);
            % 三方向切片序号/数量（供面板状态输出）
            S = struct();
            keys = {'axial', 'coronal', 'sagittal'};
            for i = 1:3
                try
                    cnt = obj.sliceCountFor(keys{i});
                    idx = obj.currentSliceIndex(keys{i});
                catch
                    cnt = 0;
                    idx = 0;
                end
                S.(keys{i}) = struct('Index', idx, 'Count', cnt);
            end
            info.Slices = S;
            msg = '';
            if ~obj.hasVolume()
                msg = '未加载图像体积。';
            elseif ~obj.MatValid
                msg = '图像头信息 hdr.mat 无效，已按体素 1 mm 等间距显示。';
            end
            if ~isempty(obj.LastMessage)
                if isempty(msg)
                    msg = obj.LastMessage;
                else
                    msg = sprintf('%s %s', msg, obj.LastMessage);
                end
            end
            info.Message = msg;
            info.Ok = true;
        end

        function [vol, mat] = resampledVolume(obj)
            % 输出 [display X,Y,Z] 网格；mat 为 SPM 1-based 体素到 display mm。
            grid = obj.getGrid();
            if ~grid.Valid
                error('mrw:QcView:resample', '无法导出显示网格：%s', grid.Message);
            end
            nx = numel(grid.xaxis); ny = numel(grid.yaxis); nz = numel(grid.zaxis);
            vol = zeros(nx, ny, nz);
            for k = 1:nz
                [sl, info] = obj.slice('axial', k);
                if isempty(sl) || ~isempty(info.Message)
                    error('mrw:QcView:resample', '显示网格第 %d 层采样失败。', k);
                end
                vol(:, :, k) = sl.';
            end
            axes3 = {grid.xaxis, grid.yaxis, grid.zaxis};
            mat = eye(4);
            for d = 1:3
                step = grid.pix;
                if numel(axes3{d}) > 1, step = axes3{d}(2) - axes3{d}(1); end
                mat(d, d) = step;
                mat(d, 4) = axes3{d}(1) - step;
            end
        end

        function tf = hasAcPc(obj)
            % hasAcPc  是否已设置 AC/PC 配平
            tf = ~isempty(obj.ACVoxel) && ~isempty(obj.PCVoxel);
        end

    end

    % =====================================================================
    % 内部实现
    % =====================================================================

    methods (Access = private)

        % ---------------- 方向/尺寸 ----------------

        function [o, total, letter, labelEn] = normalizeOrientation(~, orientation, dims)
            if nargin < 3 || numel(dims) < 3 || any(~isfinite(dims(1:3)))
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

        function n = sliceCountFor(obj, orientation)
            n = 0;
            if ~obj.hasVolume()
                return;
            end
            try
                [o, total] = obj.normalizeOrientation(orientation, obj.Dim);
                g = obj.getGrid();
                if ~g.Valid
                    n = max(total, 1);
                    return;
                end
                switch o
                    case 'axial'
                        n = numel(g.zaxis);
                    case 'coronal'
                        n = numel(g.yaxis);
                    otherwise
                        n = numel(g.xaxis);
                end
                n = max(n, 1);
            catch
                n = 0;
            end
        end

        % ---------------- 显示矩阵 ----------------

        function tf = isNativeMode(obj)
            tf = false;
            if ~obj.hasVolume()
                return;
            end
            tf = strcmp(obj.Mode, 'native') && ...
                all(abs(obj.ManualT) < 1e-12) && all(abs(obj.ManualR) < 1e-12) && ...
                ~obj.FlipLR && ~obj.FlipAP && ~obj.FlipIS;
        end

        function tf = canDirectSlice(obj)
            R = obj.Mat(1:3, 1:3);
            tf = obj.isNativeMode() && all(diag(R) > 0) && ...
                norm(R - diag(diag(R)), 'fro') < 1e-10;
        end

        function A = displayMatrix(obj)
            Mb = eye(4);
            switch obj.Mode
                case 'origin'
                    Mb = obj.translation4(-obj.OriginWorld);
                case 'acpc'
                    if ~isempty(obj.ACWorld) && ~isempty(obj.PCWorld)
                        R = obj.acpcRotation();
                        Mb = R * obj.translation4(-obj.ACWorld(:).');
                    end
                otherwise
                    Mb = eye(4);
            end
            Mm = obj.translation4(obj.ManualT) * obj.manualRotation();
            F = obj.flipMatrix();
            A = F * Mm * Mb;
        end

        function M = manualRotation(obj)
            rx = obj.rotX(obj.ManualR(1));
            ry = obj.rotY(obj.ManualR(2));
            rz = obj.rotZ(obj.ManualR(3));
            M = rz * ry * rx;
        end

        function F = flipMatrix(obj)
            d = [1 1 1];
            if obj.FlipLR
                d(1) = -1;
            end
            if obj.FlipAP
                d(2) = -1;
            end
            if obj.FlipIS
                d(3) = -1;
            end
            F = diag([d 1]);
        end

        function R = acpcRotation(obj)
            % SPM/RAS 的 +Y 是前方；PC 在 AC 后方，应旋到 display -Y。
            R = eye(4);
            if isempty(obj.ACWorld) || isempty(obj.PCWorld)
                return;
            end
            v = obj.PCWorld(:) - obj.ACWorld(:);
            d = norm(v);
            if ~isfinite(d) || d < 1e-12
                return;
            end
            v = v / d;
            t = [0; -1; 0];
            c = max(-1, min(1, dot(v, t)));
            ax = cross(v, t);
            s = norm(ax);
            if s < 1e-12
                if c > 0
                    R = eye(4);
                else
                    R = obj.rotAbout([1; 0; 0], pi);
                end
            else
                R = obj.rotAbout(ax / s, atan2(s, c));
            end
        end

        function R = rotAbout(~, axis, angDegRad)
            % 右手系绕任意轴旋转（angDegRad 为弧度）
            x = axis(1);
            y = axis(2);
            z = axis(3);
            n = sqrt(x * x + y * y + z * z);
            if n < 1e-12
                R = eye(4);
                return;
            end
            x = x / n;
            y = y / n;
            z = z / n;
            C = cos(angDegRad);
            S = sin(angDegRad);
            V = 1 - C;
            r = [x * x * V + C, x * y * V - z * S, x * z * V + y * S; ...
                y * x * V + z * S, y * y * V + C, y * z * V - x * S; ...
                z * x * V - y * S, z * y * V + x * S, z * z * V + C];
            R = eye(4);
            R(1:3, 1:3) = r;
        end

        function M = rotX(~, deg)
            a = deg * pi / 180;
            M = eye(4);
            M(2, 2) = cos(a);
            M(2, 3) = -sin(a);
            M(3, 2) = sin(a);
            M(3, 3) = cos(a);
        end

        function M = rotY(~, deg)
            a = deg * pi / 180;
            M = eye(4);
            M(1, 1) = cos(a);
            M(1, 3) = sin(a);
            M(3, 1) = -sin(a);
            M(3, 3) = cos(a);
        end

        function M = rotZ(~, deg)
            a = deg * pi / 180;
            M = eye(4);
            M(1, 1) = cos(a);
            M(1, 2) = -sin(a);
            M(2, 1) = sin(a);
            M(2, 2) = cos(a);
        end

        function T = translation4(~, v)
            T = eye(4);
            if numel(v) >= 3
                T(1:3, 4) = double(v(1:3));
            end
        end

        function e = rotToEulerDeg(~, R)
            % 按契约旋转顺序 R = Rz(yaw)*Ry(roll)*Rx(pitch) 反解 [pitch roll yaw]（度）
            e = [0 0 0];
            if ~isequal(size(R), [3 3]) || any(~isfinite(R(:)))
                return;
            end
            s = -R(3, 1);
            s = max(-1, min(1, s));
            roll = asin(s);
            if abs(cos(roll)) > 1e-8
                pitch = atan2(R(3, 2), R(3, 3));
                yaw = atan2(R(2, 1), R(1, 1));
            else
                pitch = atan2(-R(2, 3), R(2, 2));
                yaw = 0;
            end
            e = [pitch, roll, yaw] * 180 / pi;
        end

        % ---------------- 显示采样网格 ----------------

        function invalidate(obj)
            obj.Cache = [];
            obj.CacheValid = false;
        end

        function g = getGrid(obj)
            % 计算（并缓存）display 采样网格：轴向量 / pix / display→voxel 逆矩阵
            if obj.CacheValid && isstruct(obj.Cache)
                g = obj.Cache;
                return;
            end
            g = struct('Valid', false, 'Message', '', 'A', eye(4), ...
                'Minv', eye(4), 'xaxis', [0 1], 'yaxis', [0 1], 'zaxis', [0 1], ...
                'pix', 1, 'Dim', [0 0 0]);
            obj.Cache = g;
            obj.CacheValid = true;
            if ~obj.hasVolume()
                g.Message = '未加载图像体积。';
                obj.Cache = g;
                return;
            end
            try
                A = obj.displayMatrix();
                Mdisp = A * obj.Mat;
                g.A = A;
                if abs(det(Mdisp(1:3, 1:3))) < 1e-12
                    g.Message = '显示矩阵不可逆，无法重采样。';
                    obj.Cache = g;
                    return;
                end
                g.Minv = inv(Mdisp);
                dims = obj.Dim;
                ii = [1 dims(1) 1 dims(1) 1 dims(1) 1 dims(1)];
                jj = [1 1 dims(2) dims(2) 1 1 dims(2) dims(2)];
                kk = [1 1 1 1 dims(3) dims(3) dims(3) dims(3)];
                P = A * (obj.Mat * [ii; jj; kk; ones(1, 8)]);
                lo = min(P(1:3, :), [], 2);
                hi = max(P(1:3, :), [], 2);
                rng = hi - lo;
                vs = obj.VoxSize(:).';
                pos = vs(vs > 0);
                if isempty(pos)
                    base = max(rng) / 512;
                else
                    base = min(pos);
                end
                pix = max(base, max(rng) / 512);
                if ~isfinite(pix) || pix <= 0
                    pix = 1;
                end
                g.pix = pix;
                axes3 = cell(1, 3);
                for d = 1:3
                    r = rng(d);
                    if ~isfinite(r) || r <= 0
                        axes3{d} = lo(d);
                    else
                        n = max(2, round(r / pix) + 1);
                        axes3{d} = linspace(lo(d), hi(d), n);
                    end
                end
                if obj.canDirectSlice()
                    for d = 1:3
                        axes3{d} = obj.Mat(d, d) * (1:dims(d)) + obj.Mat(d, 4);
                    end
                else
                    origins = cellfun(@(v) v(1), axes3);
                    steps = repmat(pix,1,3);
                    for d = 1:3
                        if numel(axes3{d}) > 1, steps(d) = axes3{d}(2) - axes3{d}(1); end
                    end
                    % 同一二进制格点使显示/导出网格的 0/1-based 仿射均可由 float32 精确表示。
                    scale = max([1 abs(origins) abs(origins - steps)]) + max(abs(steps)) + 1;
                    quantum = 2 ^ (floor(log2(scale)) - 23);
                    steps = round(steps / quantum) * quantum;
                    origins = round(origins / quantum) * quantum;
                    if any(steps <= 0)
                        g.Message = '图像坐标范围过大，NIfTI-1 精度无法表示当前体素网格。';
                        obj.Cache = g;
                        return;
                    end
                    for d = 1:3
                        axes3{d} = origins(d) + (0:numel(axes3{d})-1) * steps(d);
                    end
                end
                g.xaxis = axes3{1};
                g.yaxis = axes3{2};
                g.zaxis = axes3{3};
                g.Dim = dims;
                g.Valid = true;
                g.Message = '';
                obj.Cache = g;
            catch err
                g.Valid = false;
                g.Message = sprintf('生成显示采样网格失败：%s', obj.errText(err));
                obj.Cache = g;
            end
        end

        function g = planeGeometry(obj, orientation, sliceIndex)
            % SPM world space: axial +X/+Y, coronal +X/+Z, sagittal -Y/+Z.
            g = struct('Valid', false, 'Message', '', 'Orientation', 'axial', ...
                'SliceIndex', 1, 'SliceCount', 0, 'ImageSize', [0 0], ...
                'PixelSize', 1, 'XLim', [0 0], 'YLim', [0 0], 'T', zeros(3), ...
                'SliceCoord', 0, 'ColDisplayAxis', 1, 'RowDisplayAxis', 2, ...
                'NormalDisplayAxis', 3, 'ColValues', [], 'RowValues', [], ...
                'NormalValues', [], 'IsNative', obj.isNativeMode(), ...
                'DirectNative', obj.canDirectSlice(), 'XAxisLabel', '', 'YAxisLabel', '');
            grid = obj.getGrid();
            if ~grid.Valid
                g.Message = grid.Message;
                return;
            end
            [o, ~] = obj.normalizeOrientation(orientation, obj.Dim);
            g.Orientation = o;
            switch o
                case 'axial'
                    g.ColValues = grid.xaxis;
                    g.RowValues = grid.yaxis;
                    g.NormalValues = grid.zaxis;
                case 'coronal'
                    g.RowDisplayAxis = 3;
                    g.NormalDisplayAxis = 2;
                    g.ColValues = grid.xaxis;
                    g.RowValues = grid.zaxis;
                    g.NormalValues = grid.yaxis;
                otherwise
                    g.ColDisplayAxis = 2;
                    g.RowDisplayAxis = 3;
                    g.NormalDisplayAxis = 1;
                    g.ColValues = grid.yaxis(end:-1:1);
                    g.RowValues = grid.zaxis;
                    g.NormalValues = grid.xaxis;
            end
            g.SliceCount = numel(g.NormalValues);
            if nargin < 3 || isempty(sliceIndex) || ~isnumeric(sliceIndex) || ...
                    ~isscalar(sliceIndex) || ~isfinite(sliceIndex)
                k = obj.currentSliceIndex(o);
            else
                k = round(double(sliceIndex));
            end
            k = min(max(k, 1), g.SliceCount);
            g.SliceIndex = k;
            nc = numel(g.ColValues);
            nr = numel(g.RowValues);
            g.ImageSize = [nr, nc];
            dx = grid.pix;
            dy = grid.pix;
            if nc > 1, dx = (g.ColValues(end) - g.ColValues(1)) / (nc - 1); end
            if nr > 1, dy = (g.RowValues(end) - g.RowValues(1)) / (nr - 1); end
            xoff = g.ColValues(1) - dx;
            yoff = g.RowValues(1) - dy;
            g.XLim = [dx * 0.5 + xoff, dx * (nc + 0.5) + xoff];
            g.YLim = [dy * 0.5 + yoff, dy * (nr + 0.5) + yoff];
            g.PixelSize = grid.pix;
            g.SliceCoord = g.NormalValues(k);
            T = zeros(3);
            T(g.ColDisplayAxis, 1) = dx;
            T(g.RowDisplayAxis, 2) = dy;
            T(g.ColDisplayAxis, 3) = xoff;
            T(g.RowDisplayAxis, 3) = yoff;
            T(g.NormalDisplayAxis, 3) = g.SliceCoord;
            g.T = T;
            A = obj.displayMatrix();
            g.XAxisLabel = obj.labelForWorld(A(1:3, 1:3) \ T(:, 1));
            g.YAxisLabel = obj.labelForWorld(A(1:3, 1:3) \ T(:, 2));
            g.Valid = true;
        end

        function p = crosshairPixel(obj, ~, g)
            p = [1, 1];
            if ~obj.hasVolume() || ~g.Valid, return; end
            d = obj.voxelToDisplay(obj.getCrosshair());
            p = [obj.indexOnValues(g.ColValues, d(g.ColDisplayAxis)), ...
                obj.indexOnValues(g.RowValues, d(g.RowDisplayAxis))];
        end

        function img = samplePlane(obj, o, g, k)
            % display 网格 → interp3 重采样（越界/NaN 填 0；方法由 Interpolation 决定）
            img = [];
            grid = obj.getGrid();
            if ~grid.Valid
                return;
            end
            dims = obj.Dim;
            Minv = grid.Minv;
            nr = numel(g.RowValues);
            nc = numel(g.ColValues);
            n = nr * nc;
            % 构造 display 坐标网格：列沿 ColDisplayAxis、行沿 RowDisplayAxis、法向固定
            [cc, rr] = meshgrid(1:nc, 1:nr);
            colv = g.ColValues(:).';
            rowv = g.RowValues(:).';
            D = zeros(3, n);
            D(g.ColDisplayAxis, :) = colv(cc(:)).';
            D(g.RowDisplayAxis, :) = rowv(rr(:)).';
            D(g.NormalDisplayAxis, :) = g.NormalValues(k);
            % display → voxel（连续 1-based）
            Vo = Minv(1:3, :) * [D; ones(1, n)];
            vi = reshape(Vo(1, :), nr, nc);
            vj = reshape(Vo(2, :), nr, nc);
            vk = reshape(Vo(3, :), nr, nc);
            % 采样：interp3 向量网格约定 X↔V 第 2 维（j），Y↔第 1 维（i），Z↔第 3 维（k）
            method = obj.Interpolation;
            if ~any(strcmp(method, {'linear', 'nearest'}))
                method = 'linear';
            end
            if any(dims < 2)
                img = obj.nearestSample(obj.Vol, dims, vi, vj, vk);
            else
                try
                    if isempty(obj.Sampler) || ~strcmp(obj.SamplerMethod, method)
                        obj.Sampler = griddedInterpolant({1:dims(1), 1:dims(2), 1:dims(3)}, ...
                            obj.Vol, method, 'none');
                        obj.SamplerMethod = method;
                    end
                    img = obj.Sampler(vi, vj, vk);
                catch
                    img = obj.nearestSample(obj.Vol, dims, vi, vj, vk);
                end
            end
            img = double(img);
            img(~isfinite(img)) = 0;
            if ~ismatrix(img)
                img = reshape(img, size(img, 1), []);
            end
        end

        function img = nearestSample(~, V, dims, vi, vj, vk)
            % 最近邻兜底采样（退化/异常网格时使用）
            ii = min(max(round(vi), 1), dims(1));
            jj = min(max(round(vj), 1), dims(2));
            kk = min(max(round(vk), 1), dims(3));
            lin = sub2ind(dims, ii, jj, kk);
            img = reshape(V(lin), size(vi));
            outside = vi < 1 | vi > dims(1) | vj < 1 | vj > dims(2) | vk < 1 | vk > dims(3);
            img(outside) = 0;
        end

        % ---------------- 通用辅助 ----------------

        function p = applyAffine(obj, M, p)
            % 对 1x3/3x1/1x4 或 Nx3/Nx4 点集施加 4x4 仿射；非法输入返回 []
            if isempty(p) || ~isnumeric(p) || ~isreal(p)
                p = [];
                return;
            end
            try
                if isvector(p)
                    n = numel(p);
                    if n == 3
                        q = M * [double(p(:)); 1];
                        p = q(1:3).';
                    elseif n == 4
                        v = double(p(:));
                        if abs(v(4)) < eps
                            v(4) = 1;
                        end
                        q = M * v;
                        p = q(1:3).';
                    else
                        p = [];
                    end
                    if ~isempty(p) && any(~isfinite(p(:)))
                        p = [];
                    end
                    return;
                end
                if size(p, 2) == 3
                    q = M * [double(p).'; ones(1, size(p, 1))];
                    p = q(1:3, :).';
                elseif size(p, 2) == 4
                    q = M * double(p).';
                    p = q(1:3, :).';
                else
                    p = [];
                end
            catch
                p = [];
            end
            if obj.isemptyOrInvalid(p)
                p = [];
            end
        end

        function tf = isemptyOrInvalid(~, p)
            tf = isempty(p) || ~isnumeric(p) || any(~isfinite(p(:)));
        end

        function v = validateVec3(~, v)
            if nargin < 2 || isempty(v) || ~isnumeric(v) || ~isreal(v)
                v = [];
                return;
            end
            v = double(v(:).');
            if numel(v) < 3 || any(~isfinite(v(1:3)))
                v = [];
                return;
            end
            v = v(1:3);
        end

        function b = validateLogical(~, b)
            if islogical(b) && isscalar(b)
                b = logical(b);
            elseif isnumeric(b) && isscalar(b) && isfinite(b)
                b = logical(b ~= 0);
            else
                b = [];
            end
        end

        function idx = indexOnValues(~, vals, v)
            % 把 display 坐标换算成 1-based 连续像素序号
            idx = 1;
            if isempty(vals) || numel(vals) < 1 || isempty(v) || ~isfinite(v)
                return;
            end
            if numel(vals) < 2
                return;
            end
            step = vals(2) - vals(1);
            if ~isfinite(step) || abs(step) < 1e-12
                return;
            end
            idx = 1 + (v - vals(1)) / step;
        end

        function lab = labelForWorld(~, w)
            % 世界方向向量 → 显示轴标签（如 'L→R' / 'P→A' / 'I→S'）
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

        function s = errText(~, err)
            if isa(err, 'MException')
                s = err.message;
            else
                s = '未知错误';
            end
            s = regexprep(s, '\s+', ' ');
        end

        % ---------------- 空结构模板 ----------------

        function info = emptySliceInfo(obj)
            info = struct('Orientation', 'axial', 'SliceIndex', 0, ...
                'SliceCount', 0, 'ImageSize', [0 0], 'PixelSize', 1, ...
                'XLim', [0 0], 'YLim', [0 0], 'SliceLabel', '无数据', ...
                'Message', '', 'IsNative', false, 'XAxisLabel', '', ...
                'YAxisLabel', '', 'SliceCoord', 0, 'CrosshairPixel', [1 1], ...
                'CrosshairVoxel', [1 1 1], 'CrosshairDisplay', [0 0 0]);
            if ~obj.hasVolume()
                info.CrosshairVoxel = [];
                info.CrosshairDisplay = [];
            end
        end

        function info = emptyPlaneInfo(obj)
            info = struct('Orientation', 'axial', 'SliceIndex', 0, ...
                'SliceCount', 0, 'ImageSize', [0 0], 'PixelSize', 1, ...
                'XLim', [0 0], 'YLim', [0 0], 'IsNative', false, ...
                'XAxisLabel', '', 'YAxisLabel', '', 'SliceCoord', 0, ...
                'PixelToDisplay', zeros(3), 'Message', '');
            if ~obj.hasVolume()
                info.Message = '未加载图像体积。';
            end
        end

        function info = emptyMontageInfo(~)
            info = struct('Orientation', 'axial', 'N', 0, 'SliceCount', 0, ...
                'Tiles', struct('SliceIndex', {}, 'Row', {}, 'Col', {}, ...
                'Height', {}, 'Width', {}, 'XLim', {}, 'YLim', {}), ...
                'TileCount', 0, 'ImageSize', [0 0], 'XLim', [0 0], ...
                'YLim', [0 0], 'PixelSize', 1, 'IsNative', false, ...
                'XAxisLabel', '', 'YAxisLabel', '', 'Highlight', 0, 'Message', '');
        end
    end
end
