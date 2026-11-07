classdef CfgBuilder
% CfgBuilder  由 UI 状态构建 DPARSFA 可执行的 Cfg 结构体，并提供预设/校验/摘要/存取
%
% 设计:
%   state  - 与 Cfg 同构的嵌套 struct，字段集合见 mrw.CfgSchema
%   build  - 以 DPABI 官方 Template_Blank.mat 为基线，写入 state 并做一致性修正
%   Cfg    - 可直接传给 DPARSFA_run(Cfg, [], [], 0) 的结构体
%
% 用法:
%   st   = mrw.CfgBuilder.defaultState();
%   Cfg  = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
%   rep  = mrw.CfgBuilder.validate(Cfg);
%   mrw.CfgBuilder.saveCfg(Cfg, 'mycfg.mat');

    methods (Static)

        function st = defaultState()
            % UI 初始状态：schema 默认值 + 数据相关字段留空
            st = mrw.CfgSchema.defaults();
            st.WorkingDir = '';
            st.DataProcessDir = '';
            st.SubjectID = {};
            st.IsAllowGUI = logical(mrw.Settings.get('AllowGUI'));
        end

        function P = presets()
            % 返回预设 struct array：Name/Desc/Overrides（Overrides 为嵌套部分状态）
            P = struct('Name', {}, 'Desc', {}, 'Overrides', {});
            P(end+1) = struct('Name', '经典静息态（DARTEL 全流程）', ...
                'Desc', '删前10点 → 头动校正 → T1 统一分割+DARTEL 标准化 → 平滑 4mm → 协变量回归 → 0.01–0.1Hz 滤波 → ALFF/fALFF、ReHo；适合有 T1 结构像的常规静息态研究', ...
                'Overrides', mrw.CfgBuilder.presetClassic());
            P(end+1) = struct('Name', '仅功能像（EPI 模板标准化，无结构像）', ...
                'Desc', '删前10点 → 头动校正 → EPI 模板直接标准化 → 平滑 4mm → 0.01–0.1Hz 滤波 → ALFF/fALFF；适合只有功能像、无 T1 的数据', ...
                'Overrides', mrw.CfgBuilder.presetNoT1());
            P(end+1) = struct('Name', 'BIDS 数据一键预处理', ...
                'Desc', '自动把 BIDS 转成 DPARSF 结构 → 经典 DARTEL 全流程（含平滑/回归/滤波/ALFF/ReHo）', ...
                'Overrides', mrw.CfgBuilder.presetBIDS());
            P(end+1) = struct('Name', '快速质控（仅转换+头动校正）', ...
                'Desc', '只做 DICOM 转换、删前10点、头动校正；最快，用于检查数据质量和头动', ...
                'Overrides', mrw.CfgBuilder.presetQC());
            P(end+1) = struct('Name', '空白（仅补步骤/续跑）', ...
                'Desc', '所有处理与指标步骤默认关闭（不会删除数据）；用于在已有中间结果上补做某一步：先把「起始目录名」设为已有阶段目录（如 FunImgAR），再只勾选要补的步骤（如 Scrubbing、ALFF、ReHo）并设置相应参数。若要从原始数据完整重跑，请先恢复原始数据，避免重复删除初始时间点。', ...
                'Overrides', mrw.CfgBuilder.presetBlank());
        end

        function st = applyPreset(baseState, presetName)
            % 在 baseState 上应用预设（保留数据相关字段：工作目录/受试者/时间点/TR/扫描信息）
            st = baseState;
            P = mrw.CfgBuilder.presets();
            idx = [];
            for i = 1:numel(P)
                if strcmp(P(i).Name, presetName)
                    idx = i;
                    break;
                end
            end
            if isempty(idx)
                return;
            end
            ov = P(idx).Overrides;
            keys = fieldnames(ov);
            for i = 1:numel(keys)
                f = keys{i};
                v = ov.(f);
                if isstruct(v) && isfield(st, f) && isstruct(st.(f))
                    st.(f) = mrw.CfgBuilder.mergeState(st.(f), v);
                else
                    st.(f) = v;
                end
            end
        end

        function Cfg = build(st, runOpts)
            % 从 UI 状态构建 DPARSFA Cfg
            if nargin < 2, runOpts = struct(); end
            if ~isfield(runOpts, 'AllowGUI'), runOpts.AllowGUI = logical(mrw.Settings.get('AllowGUI')); end

            % 1) 基线：DPABI 官方模板（若可用），否则从 schema 默认值兜底
            Cfg = mrw.Dpabi.blankTemplate();
            if isempty(Cfg)
                Cfg = struct();
                Cfg.DPARSFVersion = 'V5.5_250415';
            end
            if ~isfield(Cfg, 'DPARSFVersion') || isempty(Cfg.DPARSFVersion)
                Cfg.DPARSFVersion = 'V5.5_250415';
            end

            % 2) 写入全部 schema 字段
            S = mrw.CfgSchema.entries();
            for i = 1:numel(S)
                v = mrw.CfgSchema.getKey(st, S(i).Key);
                if isempty(v) && ~(ischar(v) && ~isempty(v))
                    % 空值（''、[]、{}）也允许写入，维持结构完整
                end
                Cfg = mrw.CfgSchema.setKey(Cfg, S(i).Key, v);
            end

            % 3) 数据相关字段
            Cfg.WorkingDir = strtrim(char(st.WorkingDir));
            if isfield(st, 'DataProcessDir') && ~isempty(st.DataProcessDir)
                Cfg.DataProcessDir = strtrim(char(st.DataProcessDir));
            else
                Cfg.DataProcessDir = Cfg.WorkingDir;
            end
            ids = st.SubjectID;
            if ischar(ids), ids = {ids}; end
            ids = ids(:)';
            Cfg.SubjectID = ids;
            Cfg.SubjectNum = numel(ids);
            Cfg.IsAllowGUI = double(logical(runOpts.AllowGUI));
            Cfg.StartingDirName = char(st.StartingDirName);

            % 4) 一致性修正（对齐 DPARSF_run 的行为）
            Cfg = mrw.CfgBuilder.reconcile(Cfg);

            % 4b) T1 裁剪兼容模式：非 auto 模式由工作台运行前处理（旧版 dcm2nii
            %     真实裁剪 / 未裁剪 T1 直通），这里关闭 DPARSF 自带的 dcm2niix 裁剪步骤。
            Cfg = mrw.CfgBuilder.applyT1Compat(Cfg);

            % 5) 保留引擎需要但 schema 未列出的字段（模板已有，这里补齐默认）
            if ~isfield(Cfg, 'TRSet'), Cfg.TRSet = zeros(max(1, numel(ids)), max(1, Cfg.FunctionalSessionNumber)); end
            if ~isfield(Cfg.CalFC, 'ROISelectedIndex'), Cfg.CalFC.ROISelectedIndex = []; end
        end

        function Cfg = reconcile(Cfg)
            % 与 DPARSF_run.m 相同的规则：不做标准化时关闭结构像相关步骤
            if Cfg.IsNormalize == 0
                Cfg.IsNeedT1CoregisterToFun = 0;
                Cfg.IsSegment = 0;
                Cfg.IsDARTEL = 0;
                Cfg.IsNeedReorientFunImgInteractively = 0;
                Cfg.IsNeedReorientT1ImgInteractively = 0;
                Cfg.IsNeedReorientCropT1Img = 0;
                Cfg.IsBet = 0;
                Cfg.IsAutoMask = 0;
                Cfg.IsNeedReorientInteractivelyAfterCoreg = 0;
            end
            if Cfg.IsSegment == 0
                Cfg.IsDARTEL = 0;
            end
            if Cfg.IsSegment == 0
                Cfg.IsNeedT1CoregisterToFun = 0;
            end
            if Cfg.IsNormalize > 0 && Cfg.IsSegment == 0 && Cfg.IsNormalize ~= 1
                % 标准化模式2/3必须有分割；这里保持用户选择，交给 validate 报错
            end
            if Cfg.IsSmooth == 2 && Cfg.IsDARTEL == 0
                Cfg.IsSmooth = 1;   % DARTEL 平滑不可用则退化为普通平滑
            end
            if Cfg.IsNormalize == 0
                Cfg.IsWarpMasksIntoIndividualSpace = 0;
            end
            if Cfg.IsCalVMHC == 0
                Cfg.IsSmoothBeforeVMHC = 0;
            end
            if Cfg.IsAllowGUI == 0
                % 后台进程不弹交互窗（否则会阻塞）
                Cfg.IsNeedReorientFunImgInteractively = 0;
                Cfg.IsNeedReorientT1ImgInteractively = 0;
                Cfg.IsNeedReorientInteractivelyAfterCoreg = 0;
                Cfg.IsDefineROIInteractively = 0;
            end
            % 引擎只看 RemoveFirstTimePoints 数值，勾选状态需同步
            if ~Cfg.IsRemoveFirstTimePoints
                Cfg.RemoveFirstTimePoints = 0;
            elseif Cfg.RemoveFirstTimePoints <= 0
                Cfg.IsRemoveFirstTimePoints = 0;
            end
            % 协变量回归/滤波的时机一致性
            if Cfg.IsCovremove == 1 && Cfg.IsNormalize == 0 && strcmpi(Cfg.Covremove.Timing, 'AfterNormalize')
                Cfg.Covremove.Timing = 'AfterRealign';
            end
            if Cfg.IsFilter == 1 && Cfg.IsNormalize == 0 && strcmpi(Cfg.Filter.Timing, 'AfterNormalize')
                Cfg.Filter.Timing = 'BeforeNormalize'; %#ok<*NBRAK2>
            end
        end

        function Cfg = applyT1Compat(Cfg)
            %APPLYT1COMPAT 把 T1 裁剪兼容模式写入 Cfg（运行前处理由 headlessRunner 执行）
            %   auto         保持 DPARSF 默认流程（可能因 dcm2niix 只支持 DICOM 而失败）；
            %   old_dcm2nii  运行前用旧版 dcm2nii 对 NIfTI T1 真实裁剪；
            %   no_crop      运行前把未裁剪 T1 复制为 c* 直通文件。
            %   两种非 auto 模式都关闭 DPARSF 自己的裁剪步骤（避免 dcm2niix 再跑）。
            mode = 'auto';
            if isfield(Cfg, 'T1CropCompat')
                mode = mrw.T1Compat.normalizeMode(Cfg.T1CropCompat);
            end
            Cfg.T1CropCompat = mode;
            if strcmp(mode, 'auto')
                return
            end
            if mrw.T1Compat.t1Needed(Cfg)
                Cfg.IsNeedReorientCropT1Img = 0;
            end
        end

        function rep = validate(Cfg, detected)
            % 运行前检查；返回 rep.ok / rep.checks / rep.errors / rep.warnings
            %   checks 为 struct array: Name, Level('ok'|'warn'|'error'), Message
            if nargin < 2, detected = []; end
            checks = struct('Name', {}, 'Level', {}, 'Message', {});
            add = @(nm, lv, msg) struct('Name', nm, 'Level', lv, 'Message', msg);

            wd = Cfg.WorkingDir;
            if isempty(wd) || exist(wd, 'dir') ~= 7
                checks(end+1) = add('工作目录', 'error', '工作目录不存在或未指定，请先扫描/选择数据目录。');
            else
                checks(end+1) = add('工作目录', 'ok', wd);
            end

            dpd = Cfg.DataProcessDir;
            if isempty(dpd), dpd = wd; end
            if ~isempty(dpd)
                parent = fileparts(dpd);
                if exist(dpd, 'dir') == 7
                    checks(end+1) = add('处理输出目录', 'ok', dpd);
                elseif isempty(parent) || exist(parent, 'dir') == 7
                    checks(end+1) = add('处理输出目录', 'warn', ['输出目录尚不存在，运行时会创建：' dpd]);
                else
                    checks(end+1) = add('处理输出目录', 'error', ['输出目录父路径不存在：' parent]);
                end
            end

            ids = Cfg.SubjectID;
            if isempty(ids)
                checks(end+1) = add('受试者列表', 'error', '受试者列表为空：请先扫描数据或手动添加受试者。');
            else
                checks(end+1) = add('受试者列表', 'ok', sprintf('共 %d 名受试者', numel(ids)));
            end

            % 目录结构（BIDS 模式跳过；DPARSF 约定：<WorkingDir>/<起始目录名>/<受试者ID>/）
            if ~isempty(wd) && exist(wd, 'dir') == 7 && ~isempty(ids) && ~Cfg.IsBIDStoDPARSF
                missing = 0; missingAnat = 0; missingSess = 0;
                for i = 1:numel(ids)
                    funDir = fullfile(wd, Cfg.StartingDirName, ids{i});
                    if exist(funDir, 'dir') ~= 7
                        missing = missing + 1;
                        continue;
                    end
                    if ~mrw.CfgBuilder.subjectHasAnat(wd, ids{i})
                        missingAnat = missingAnat + 1;
                    end
                    for s = 2:max(1, Cfg.FunctionalSessionNumber)
                        sessDir = fullfile(wd, sprintf('S%d_%s', s, Cfg.StartingDirName), ids{i});
                        if exist(sessDir, 'dir') ~= 7
                            missingSess = missingSess + 1;
                        end
                    end
                end
                if missing > 0
                    checks(end+1) = add('数据目录结构', 'error', ...
                        sprintf('%d 名受试者缺少 %s/%s 目录（DPARSF 约定：<工作目录>/%s/<受试者ID>）', ...
                        missing, Cfg.StartingDirName, '受试者ID', Cfg.StartingDirName));
                else
                    checks(end+1) = add('数据目录结构', 'ok', ...
                        sprintf('全部受试者均存在 %s/<受试者ID> 目录', Cfg.StartingDirName));
                end
                if missingSess > 0
                    checks(end+1) = add('多 session 结构', 'error', ...
                        sprintf('%d 个 S2..Sn 功能像目录缺失（FunctionalSessionNumber=%d）', missingSess, Cfg.FunctionalSessionNumber));
                elseif Cfg.FunctionalSessionNumber > 1
                    checks(end+1) = add('多 session 结构', 'ok', sprintf('%d 个 session 目录完整', Cfg.FunctionalSessionNumber));
                end
                if Cfg.IsNormalize >= 2 && missingAnat > 0
                    checks(end+1) = add('结构像 T1', 'error', ...
                        sprintf('%d 名受试者缺少 T1 结构像目录（T1Raw/<受试者ID>），但标准化模式 %d 需要 T1', missingAnat, Cfg.IsNormalize));
                elseif Cfg.IsNormalize >= 2
                    checks(end+1) = add('结构像 T1', 'ok', '全部受试者均有 T1 结构像');
                end
            end

            % 时间参数
            if Cfg.TR > 0
                if Cfg.TR < 0.1 || Cfg.TR > 20
                    checks(end+1) = add('TR', 'warn', sprintf('TR=%g 秒看起来异常（常规 0.5–4 秒）', Cfg.TR));
                else
                    checks(end+1) = add('TR', 'ok', sprintf('TR = %g 秒', Cfg.TR));
                end
            else
                checks(end+1) = add('TR', 'ok', 'TR=0：运行时自动从 NIfTI/DICOM 读取');
            end
            if Cfg.TimePoints > 0 && Cfg.TimePoints < 5
                checks(end+1) = add('时间点数', 'warn', sprintf('时间点仅 %d 个，过少（建议 ≥ 10）', Cfg.TimePoints));
            elseif Cfg.TimePoints > 0
                checks(end+1) = add('时间点数', 'ok', sprintf('%d 个时间点', Cfg.TimePoints));
            else
                checks(end+1) = add('时间点数', 'ok', 'TimePoints=0：运行时自动检测');
            end
            if Cfg.IsRemoveFirstTimePoints && Cfg.RemoveFirstTimePoints > 0 && ...
                    Cfg.TimePoints > 0 && Cfg.RemoveFirstTimePoints >= Cfg.TimePoints - 5
                checks(end+1) = add('删除初始时间点', 'error', ...
                    sprintf('要删除 %d 个时间点，但总时间点只有 %d 个', Cfg.RemoveFirstTimePoints, Cfg.TimePoints));
            end

            % ---- 输入数据类型 / T1 形态 / TR（headless 关键，避免引擎内部 questdlg 直接报错）----
            if ~isempty(wd) && exist(wd, 'dir') == 7 && ~isempty(ids) && ~Cfg.IsBIDStoDPARSF
                id1 = ids{1};
                funDir1 = fullfile(wd, Cfg.StartingDirName, id1);
                nDcm = 0; nNii = 0;
                if exist(funDir1, 'dir') == 7
                    nDcm = mrw.CfgBuilder.countExt(funDir1, {'.dcm', '.ima', '.DCM', '.IMA'});
                    nNii = mrw.CfgBuilder.countExt(funDir1, {'.nii', '.nii.gz', '.img'});
                end
                if exist(funDir1, 'dir') == 7
                    if nDcm > 0 && Cfg.IsNeedConvertFunDCM2IMG == 0
                        checks(end+1) = add('输入数据类型', 'error', ...
                            sprintf('检测到 DICOM 文件但未启用“功能像 DICOM→NIfTI”，引擎会按 NIfTI 读取而失败'));
                    elseif nNii > 0 && Cfg.IsNeedConvertFunDCM2IMG == 1
                        checks(end+1) = add('输入数据类型', 'error', ...
                            '检测到 NIfTI 数据但启用了“功能像 DICOM→NIfTI”；请关闭该开关（起始目录名改为实际目录，如 FunImg）');
                    elseif nDcm == 0 && nNii == 0
                        checks(end+1) = add('输入数据类型', 'error', ...
                            sprintf('受试者 %s 的 %s 目录内没有可识别的 DICOM/NIfTI 文件', id1, Cfg.StartingDirName));
                    elseif nNii > 0 && Cfg.TR == 0 && exist('mrw.NiftiHeader', 'class') == 8
                        % NIfTI 头 TR 静态检查：TR=0 且头无 timing 时引擎会硬 error
                        try
                            fNii = mrw.CfgBuilder.firstNifti(funDir1);
                            if ~isempty(fNii)
                                h = mrw.NiftiHeader.read(fNii);
                                if h.ReadOK && (isnan(h.TR) || h.TR <= 0)
                                    checks(end+1) = add('TR', 'error', ...
                                        'NIfTI 头中没有有效 TR（pixdim4<=0），请在“基础设置”手动填写 TR');
                                elseif h.ReadOK
                                    checks(end+1) = add('TR', 'ok', ...
                                        sprintf('将从 NIfTI 头自动读取 TR=%.4g 秒', h.TR));
                                end
                            end
                        catch
                        end
                    end
                end

                % T1 结构像链：headless 下引擎会用 questdlg 询问无 co* 的 T1，直接报错
                t1needed = Cfg.IsNeedT1CoregisterToFun || Cfg.IsSegment > 0 || Cfg.IsDARTEL == 1 || ...
                    Cfg.IsBet == 1 || Cfg.IsApplyDownloadedReorientMats == 1;
                t1Mode = 'auto';
                if isfield(Cfg, 'T1CropCompat')
                    t1Mode = mrw.T1Compat.normalizeMode(Cfg.T1CropCompat);
                end
                if t1needed
                    if Cfg.IsNeedConvertT1DCM2IMG == 1
                        missT1 = 0;
                        for i = 1:numel(ids)
                            dT1 = fullfile(wd, 'T1Raw', ids{i});
                            if exist(dT1, 'dir') ~= 7 || ...
                                    mrw.CfgBuilder.countExt(dT1, {'.dcm', '.ima', '.DCM', '.IMA'}) == 0
                                missT1 = missT1 + 1;
                            end
                        end
                        if missT1 > 0
                            checks(end+1) = add('结构像 T1', 'error', ...
                                sprintf('%d 名受试者缺少 T1Raw/<受试者ID>/ 下的 DICOM 结构像', missT1));
                        else
                            checks(end+1) = add('结构像 T1', 'ok', 'T1Raw DICOM 将在转换阶段自动生成 co* 结构像');
                        end
                        if Cfg.IsNeedReorientCropT1Img == 1
                            checks(end+1) = add('T1 裁剪', 'warn', ...
                                'DICOM 转换已自动生成 co* 结构像，再启用“结构像裁剪”可能产生重复 T1 文件，建议关闭');
                        end
                        if ~strcmp(t1Mode, 'auto')
                            checks(end+1) = add('T1 裁剪兼容', 'warn', ...
                                '已启用 T1Raw DICOM 转换（dcm2niix 可处理 DICOM 并自动生成 co*），T1 裁剪兼容模式将被忽略');
                        end
                    else
                        missT1 = 0; badCo = 0; multiT1 = 0; cropNiiBad = 0; needCrop = 0; haveCo = 0;
                        for i = 1:numel(ids)
                            t1dir = fullfile(wd, 'T1Img', ids{i});
                            if exist(t1dir, 'dir') ~= 7
                                missT1 = missT1 + 1;
                                continue;
                            end
                            nCo = mrw.CfgBuilder.countPattern(t1dir, {'c*.nii', 'co*.nii', '*Crop*.nii', 'c*.img'});
                            nAll = mrw.CfgBuilder.countExt(t1dir, {'.nii', '.nii.gz', '.img'});
                            if nCo > 0
                                haveCo = haveCo + 1;
                            elseif nAll > 0
                                needCrop = needCrop + 1;
                            end
                            if nCo == 0 && nAll == 1
                                if Cfg.IsNeedReorientCropT1Img == 1
                                    % 裁剪步骤调用 dcm2niix，只支持 DICOM；NIfTI T1 不会生成 c*/co*
                                    cropNiiBad = cropNiiBad + 1;
                                else
                                    badCo = badCo + 1;
                                end
                            elseif nCo == 0 && nAll > 1
                                multiT1 = multiT1 + 1;
                            end
                        end
                        if missT1 > 0
                            checks(end+1) = add('结构像 T1', 'error', ...
                                sprintf('%d 名受试者缺少 T1Img/<受试者ID>/ 结构像（未启用 DICOM 转换时必须预先放好 NIfTI）', missT1));
                        end
                        if multiT1 > 0
                            checks(end+1) = add('T1 形态', 'error', ...
                                sprintf('%d 名受试者的 T1Img 中有多个 T1 文件且无 co*，请只保留一个 T1 文件', multiT1));
                        end
                        switch t1Mode
                            case 'old_dcm2nii'
                                exe = mrw.T1Compat.oldDcm2niiExe();
                                if isempty(exe)
                                    checks(end+1) = add('T1 裁剪兼容', 'error', ...
                                        ['未找到 DPABI 自带的旧版 dcm2nii.exe（<DPABI>/DPARSF/dcm2nii/dcm2nii.exe）；' ...
                                        '请检查 DPABI 安装，或改用“免裁剪”模式']);
                                else
                                    checks(end+1) = add('T1 裁剪兼容', 'ok', ...
                                        ['旧版 dcm2nii 可用：运行前对 NIfTI T1 重定向+裁剪生成 c*/co*' ...
                                        sprintf('（待处理 %d 名，已有 c* %d 名；不依赖 dcm2niix）', needCrop, haveCo)]);
                                    if needCrop == 0
                                        checks(end+1) = add('T1 形态', 'ok', 'T1Img 结构像形态正常（存在 co*/Crop 文件）');
                                    end
                                    if any(double(wd) > 127)
                                        checks(end+1) = add('T1 裁剪兼容', 'warn', ...
                                            '工作目录含中文/非 ASCII 字符，旧版 dcm2nii 可能无法处理该路径，建议使用纯英文路径');
                                    end
                                end
                            case 'no_crop'
                                if needCrop == 0
                                    checks(end+1) = add('T1 形态', 'ok', 'T1Img 结构像形态正常（存在 co*/Crop 文件）');
                                else
                                    checks(end+1) = add('T1 裁剪兼容', 'warn', ...
                                        sprintf(['免裁剪模式：运行前会把 %d 名受试者的未裁剪 T1 复制为 c* 直通文件' ...
                                        '（不重定向/去颈，仅避免后台确认框）；后续分割/标准化质量需人工 QC'], needCrop));
                                end
                            otherwise
                                if badCo > 0
                                    checks(end+1) = add('T1 形态', 'error', ...
                                        sprintf(['%d 名受试者的 T1Img 中只有原始 T1（无 co*），后台运行会弹出确认框并直接失败；' ...
                                        '请勾选“结构像处理 → 结构像裁剪（去颈）”并改用 T1 裁剪兼容模式（旧版 dcm2nii / 免裁剪）'], badCo));
                                end
                                if cropNiiBad > 0
                                    checks(end+1) = add('T1 裁剪兼容', 'error', ...
                                        sprintf(['%d 名受试者的 T1 是 NIfTI，但“结构像裁剪”步骤调用的是 dcm2niix（只支持 DICOM），' ...
                                        '不会生成 c*/co*，无界面运行会在 BET/分割处因无法弹确认框而失败；' ...
                                        '请把「T1 裁剪兼容模式」改为“旧版 dcm2nii（可裁剪 NIfTI）”或“免裁剪”'], cropNiiBad));
                                end
                                if badCo == 0 && cropNiiBad == 0 && multiT1 == 0 && missT1 == 0
                                    checks(end+1) = add('T1 形态', 'ok', 'T1Img 结构像形态正常（存在 co*/Crop 文件）');
                                end
                        end
                    end
                end
            end


            % ---- 已处理目录 / 续跑预检：避免在已处理数据上重复处理、重复删点或 rp 文件冲突 ----
            steps = mrw.CfgBuilder.summary(Cfg);
            if numel(steps) == 1 && strcmp(steps{1}, '未启用任何处理步骤')
                steps = {};
            end
            if isempty(steps)
                checks(end+1) = add('可执行步骤', 'warn', ...
                    '当前配置没有启用任何步骤（空白预设「空白（仅补步骤/续跑）」需要再勾选要补做的步骤）。');
            end
            if ~isempty(wd) && exist(wd, 'dir') == 7
                stageInfo = mrw.CfgBuilder.detectStageDirs(wd);
                stageNames = {stageInfo.Name};
                processedNames = {};
                for k = 1:numel(stageInfo)
                    if ~isempty(stageInfo(k).Suffix)
                        processedNames{end+1} = stageInfo(k).Name; %#ok<AGROW>
                    end
                end
                hasRealignParamDir = exist(fullfile(wd, 'RealignParameter'), 'dir') == 7;
                hasProcessed = ~isempty(processedNames) || hasRealignParamDir;
                if numel(stageInfo) > 0
                    desc = cell(1, numel(stageInfo));
                    for k = 1:numel(stageInfo)
                        desc{k} = sprintf('%s = %s（%d 名受试者）', stageInfo(k).Name, ...
                            mrw.CfgBuilder.describeStageDir(stageInfo(k).Base, stageInfo(k).Suffix), ...
                            stageInfo(k).SubjectCount);
                    end
                    if numel(stageInfo) > 1
                        checks(end+1) = add('已处理目录', 'ok', ...
                            ['工作目录中的功能像阶段目录：' strjoin(desc, '；')]);
                    end
                end
                if hasProcessed
                    itemText = strjoin(stageNames, '、');
                    if isempty(itemText), itemText = 'RealignParameter'; end
                    startSuffix = mrw.CfgBuilder.funDirSuffix(Cfg.StartingDirName);
                    suggestDir = '';
                    if ~isempty(processedNames), suggestDir = processedNames{end}; end
                    if isempty(startSuffix)
                        if Cfg.IsRemoveFirstTimePoints && Cfg.RemoveFirstTimePoints > 0
                            checks(end+1) = add('重复处理风险', 'error', ...
                                sprintf(['工作目录已有处理阶段目录（%s），但当前从 "%s" 重新执行「删除初始时间点」：该步骤会原地改写起始目录数据，' ...
                                '已删除过的数据会被再次删除。请先恢复原始数据或关闭该步骤；只想补步骤时，把「起始目录名」设为已有阶段目录%s并只勾选要补的步骤。'], ...
                                itemText, Cfg.StartingDirName, mrw.CfgBuilder.suggestText(suggestDir)));
                        elseif ~isempty(steps)
                            checks(end+1) = add('重复处理风险', 'warn', ...
                                sprintf(['工作目录已有处理阶段目录（%s），当前仍从 "%s" 重新执行：%s。若并非有意重跑，' ...
                                '请把「起始目录名」设为已有阶段目录%s并关闭之前的步骤，否则会重复处理并可能与旧文件混用。'], ...
                                itemText, Cfg.StartingDirName, strjoin(steps, ' → '), mrw.CfgBuilder.suggestText(suggestDir)));
                        end
                    else
                        if Cfg.IsRemoveFirstTimePoints && Cfg.RemoveFirstTimePoints > 0
                            checks(end+1) = add('重复处理风险', 'error', ...
                                sprintf(['「起始目录名」%s 已是处理后的数据，仍启用「删除初始时间点」：该步骤会再次原地裁剪该目录数据，请关闭。'], ...
                                Cfg.StartingDirName));
                        elseif ~isempty(steps)
                            checks(end+1) = add('续跑模式', 'ok', ...
                                sprintf('从阶段目录 %s 继续，将执行：%s', Cfg.StartingDirName, strjoin(steps, ' → ')));
                        end
                    end
                end
                % rp 文件冲突：重跑头动校正会因 rp 个数>1 让 FD 计算调用 y_FD_Jenkinson 报「输入参数太多」
                if ~isempty(ids)
                    dupMsg = {};
                    for i = 1:numel(ids)
                        rpCount = mrw.CfgBuilder.countPattern(fullfile(wd, 'RealignParameter', ids{i}), {'rp*.txt'});
                        if rpCount > 1
                            dupMsg{end+1} = sprintf('%s（%d 个）', ids{i}, rpCount); %#ok<AGROW>
                        end
                    end
                    if ~isempty(dupMsg)
                        if Cfg.IsRealign
                            checks(end+1) = add('rp 文件冲突', 'error', ...
                                sprintf(['RealignParameter 中 %d 名受试者存在多个 rp*.txt（%s）。重跑头动校正会把新 rp 文件移动到同一目录，' ...
                                '随后 FD 计算会报「输入参数太多」。请先清理旧 rp 文件，或改用续跑方式（起始目录名指向已处理阶段目录）。'], ...
                                numel(dupMsg), strjoin(dupMsg, '、')));
                        else
                            checks(end+1) = add('rp 文件冲突', 'warn', ...
                                sprintf(['RealignParameter 中 %d 名受试者存在多个 rp*.txt（%s）。当前未重跑头动校正，' ...
                                '但建议清理旧文件，避免后续步骤误用。'], numel(dupMsg), strjoin(dupMsg, '、')));
                        end
                    end
                end
                % Scrubbing 依赖已算好的 FD 文件
                if Cfg.IsScrubbing && ~isempty(ids)
                    fdType = Cfg.Scrubbing.FDType;
                    missFD = {};
                    for i = 1:numel(ids)
                        fdDir = fullfile(wd, 'RealignParameter', ids{i});
                        found = [];
                        if exist(fdDir, 'dir') == 7
                            found = dir(fullfile(fdDir, sprintf('*%s_%s.txt', fdType, ids{i})));
                        end
                        if isempty(found), missFD{end+1} = ids{i}; end %#ok<AGROW>
                    end
                    if ~isempty(missFD)
                        checks(end+1) = add('Scrubbing 依赖', 'error', ...
                            sprintf(['%d 名受试者缺少 %s FD 文件（RealignParameter/<受试者>/%s_<受试者>.txt）：' ...
                            'Scrubbing 需要先完成头动校正。若数据已预处理，请把「起始目录名」指向已做头动校正的阶段目录（如 FunImgAR）。缺失：%s'], ...
                            numel(missFD), fdType, fdType, strjoin(missFD, '、')));
                    else
                        checks(end+1) = add('Scrubbing 依赖', 'ok', sprintf('%s FD 文件齐全', fdType));
                    end
                end
            end


            % 时间层校正
            if Cfg.IsSliceTiming
                sn = Cfg.SliceTiming.SliceNumber;
                so = Cfg.SliceTiming.SliceOrder;
                rs = Cfg.SliceTiming.ReferenceSlice;
                if sn <= 0
                    checks(end+1) = add('时间层校正', 'warn', ...
                        '层数未设置（0）：引擎将假设隔层扫描 [1:2:N,2:2:N] 并自动取参考层，请务必确认层序正确！');
                else
                    if numel(so) ~= sn
                        checks(end+1) = add('时间层校正', 'error', ...
                            sprintf('层序长度（%d）与层数（%d）不一致', numel(so), sn));
                    elseif max(so) > sn || min(so) < 1
                        checks(end+1) = add('时间层校正', 'error', '层序取值超出 1..层数 范围');
                    elseif ~isequal(sort(so(:))', 1:sn)
                        checks(end+1) = add('时间层校正', 'warn', '层序不是 1..层数 的排列，请核对');
                    else
                        checks(end+1) = add('时间层校正', 'ok', sprintf('层数=%d，参考层=%g', sn, rs));
                    end
                    if rs ~= 0 && (rs < 1 || rs > sn)
                        checks(end+1) = add('参考层', 'error', sprintf('参考层 %g 超出 1..%d', rs, sn));
                    end
                end
            end

            % 标准化 / 分割 / DARTEL
            if Cfg.IsNormalize > 0
                vs = double(Cfg.Normalize.VoxSize);
                if numel(vs) ~= 3 || any(vs <= 0)
                    checks(end+1) = add('体素大小', 'error', sprintf('输出体素大小无效：%s', mat2str(vs)));
                end
                bb = double(Cfg.Normalize.BoundingBox);
                if ~isequal(size(bb), [2 3]) || any(bb(2,:) <= bb(1,:))
                    checks(end+1) = add('包围盒', 'error', '输出包围盒格式应为 2×3 且 max>min');
                end
                if Cfg.IsNormalize == 2 && Cfg.IsSegment == 0
                    checks(end+1) = add('标准化', 'error', '标准化模式 2（T1 分割信息）需要先做脑组织分割');
                end
                if Cfg.IsNormalize == 3 && Cfg.IsDARTEL == 0
                    checks(end+1) = add('标准化', 'error', '标准化模式 3 需要启用 DARTEL');
                end
                if Cfg.IsDARTEL == 1 && Cfg.IsSegment ~= 2
                    checks(end+1) = add('DARTEL', 'error', 'DARTEL 需要"统一分割(New Segment)"');
                end
            elseif Cfg.IsCalVMHC
                checks(end+1) = add('VMHC', 'warn', 'VMHC 通常需要先标准化到 MNI 空间，当前未开启标准化');
            end

            % 平滑
            if Cfg.IsSmooth > 0
                fw = double(Cfg.Smooth.FWHM);
                if numel(fw) ~= 3 || any(fw <= 0)
                    checks(end+1) = add('平滑核', 'error', sprintf('FWHM 无效：%s（应为 [x y z] 正数）', mat2str(fw)));
                end
            end

            % 回归 / 滤波
            if Cfg.IsCovremove
                if strcmpi(Cfg.Covremove.Timing, 'AfterNormalize') && Cfg.IsNormalize == 0
                    checks(end+1) = add('协变量回归', 'error', '回归时机为"标准化后"，但未开启标准化');
                end
                if ~ismember(Cfg.Covremove.HeadMotion, [1 2 3 4 11 12 13 14])
                    checks(end+1) = add('头动模型', 'error', '头动模型取值应为 1–4（或 11–14 体素特异模型）');
                end
                roi = Cfg.Covremove.OtherCovariatesROI;
                if ~isempty(roi)
                    miss = mrw.CfgBuilder.missingFiles(roi);
                    if miss > 0
                        checks(end+1) = add('其他协变量', 'error', sprintf('%d 个协变量 ROI 文件不存在', miss));
                    end
                end
            end
            if Cfg.IsFilter
                if Cfg.Filter.AHighPass_LowCutoff < 0 || Cfg.Filter.ALowPass_HighCutoff <= 0
                    checks(end+1) = add('滤波', 'error', '滤波截止频率必须为正数');
                elseif Cfg.Filter.AHighPass_LowCutoff >= Cfg.Filter.ALowPass_HighCutoff
                    checks(end+1) = add('滤波', 'error', sprintf('高通(%.3f) 必须小于低通(%.3f)', ...
                        Cfg.Filter.AHighPass_LowCutoff, Cfg.Filter.ALowPass_HighCutoff));
                elseif Cfg.Filter.ALowPass_HighCutoff > 0.5
                    checks(end+1) = add('滤波', 'warn', sprintf('低通截止 %.2f Hz 偏高（常规 0.08–0.1 Hz）', Cfg.Filter.ALowPass_HighCutoff));
                end
            end

            % 引擎实现限制/实验性功能提醒
            if Cfg.IsCovremove && (strcmpi(Cfg.Covremove.WM.Method, 'CompCor') || ...
                    strcmpi(Cfg.Covremove.CSF.Method, 'CompCor'))
                checks(end+1) = add('CompCor', 'warn', ...
                    '引擎对 WM+CSF CompCor 统一做一次 PCA，实际使用 CSF.CompCorPCNum；WM.CompCorPCNum 不生效');
            end
            if Cfg.IsCovremove && Cfg.Covremove.HeadMotion >= 11 && ~Cfg.IsCalVoxelSpecificHeadMotion
                checks(end+1) = add('头动模型', 'error', ...
                    '头动模型 11–14 为体素特异模型，需要先勾选“体素特异头动指标”');
            end
            if Cfg.IsCWAS
                checks(end+1) = add('CWAS', 'warn', ...
                    'CWAS 为实验性功能，官方引擎调用参数可能不匹配；建议先小样本验证或关闭');
            end
            if isfield(Cfg, 'IsExtractAALTC') && Cfg.IsExtractAALTC
                checks(end+1) = add('AAL 时间序列', 'warn', ...
                    '当前版本引擎未找到 IsExtractAALTC 的计算实现；请改用 CalFC.ROIDef + 提取 ROI 时间序列');
            end
            % 外部工具（dcm2niix/dcm2nii/BET）对非 ASCII 路径兼容性差
            t1ModeWarn = 'auto';
            if isfield(Cfg, 'T1CropCompat')
                t1ModeWarn = mrw.T1Compat.normalizeMode(Cfg.T1CropCompat);
            end
            if (Cfg.IsNeedConvertFunDCM2IMG || Cfg.IsNeedConvertT1DCM2IMG || Cfg.IsBet || ...
                    Cfg.IsNeedReorientCropT1Img || ~strcmp(t1ModeWarn, 'auto')) && any(double(wd) > 127)
                checks(end+1) = add('路径字符', 'warn', ...
                    '工作目录含中文/非 ASCII 字符，调用 dcm2niix/dcm2nii/BET 等外部工具时可能失败，建议使用纯英文路径');
            end

            % 指标计算
            if Cfg.IsCalFC || Cfg.IsExtractROISignals
                roi = Cfg.CalFC.ROIDef;
                if isempty(roi)
                    checks(end+1) = add('ROI 定义', 'error', '启用 FC/ROI 提取但未定义任何 ROI');
                else
                    miss = mrw.CfgBuilder.missingFiles(roi);
                    if miss > 0
                        checks(end+1) = add('ROI 定义', 'error', sprintf('%d 个 ROI 定义文件不存在', miss));
                    else
                        checks(end+1) = add('ROI 定义', 'ok', sprintf('%d 个 ROI 定义', numel(roi)));
                    end
                end
            end
            if Cfg.IsCalVMHC && Cfg.IsNormalize > 0 && ~Cfg.IsNormalizeToSymmetricGroupT1Mean
                checks(end+1) = add('VMHC', 'warn', '建议勾选"标准化到对称模板"以进行 VMHC 分析');
            end
            if Cfg.IsCalVMHC && isfield(Cfg, 'IsSmoothBeforeVMHC') && Cfg.IsSmoothBeforeVMHC && Cfg.IsSmooth == 0
                % 允许：VMHC 前单独平滑
            end

            % 掩膜
            if isfield(Cfg, 'MaskFile') && ~isempty(Cfg.MaskFile) && ~strcmpi(Cfg.MaskFile, 'Default')
                if exist(Cfg.MaskFile, 'file') ~= 2
                    checks(end+1) = add('脑掩膜', 'error', sprintf('掩膜文件不存在：%s', Cfg.MaskFile));
                end
            end

            % 并行
            if isfield(Cfg, 'ParallelWorkersNumber') && Cfg.ParallelWorkersNumber > 0
                try
                    hasPCT = license('test', 'Distrib_Computing_Toolbox') == 1;
                catch
                    hasPCT = false;
                end
                if ~hasPCT
                    checks(end+1) = add('并行', 'warn', '未安装 Parallel Computing Toolbox，并行设置不会生效');
                else
                    nSubj = numel(Cfg.SubjectID);
                    if Cfg.ParallelWorkersNumber > nSubj
                        checks(end+1) = add('并行', 'warn', sprintf( ...
                            '并行进程数 %d 超过被试数 %d，运行时将按 %d 运行', ...
                            Cfg.ParallelWorkersNumber, nSubj, nSubj));
                    elseif Cfg.ParallelWorkersNumber > 32
                        checks(end+1) = add('并行', 'warn', sprintf('并行进程数 %d 过大', Cfg.ParallelWorkersNumber));
                    end
                end
            end

            % 交互选项在后台运行时的风险
            interactive = Cfg.IsNeedReorientFunImgInteractively || Cfg.IsNeedReorientT1ImgInteractively || ...
                Cfg.IsNeedReorientInteractivelyAfterCoreg || Cfg.IsDefineROIInteractively;
            if interactive && ~Cfg.IsAllowGUI
                checks(end+1) = add('交互选项', 'warn', '已选择交互式步骤，但后台运行会自动跳过它们；如需交互请用"打开原生 DPARSFA 界面"');
            end

            if isstruct(detected) && isfield(detected, 'TR') && ~isempty(detected.TR) && ...
                    ~isnan(detected.TR) && Cfg.TR == 0
                checks(end+1) = add('自动检测', 'ok', sprintf('扫描建议：TR=%g 秒，时间点=%g', ...
                    detected.TR, detected.TimePoints));
            end

            rep = struct();
            rep.checks = checks;
            lv = {checks.Level};
            rep.errors = {checks(strcmp(lv, 'error')).Message};
            rep.warnings = {checks(strcmp(lv, 'warn')).Message};
            rep.ok = isempty(rep.errors);
            nOk = sum(strcmp(lv, 'ok')); nWarn = sum(strcmp(lv, 'warn')); nErr = numel(rep.errors);
            if rep.ok && nWarn == 0
                rep.summary = sprintf('检查通过（%d 项）', nOk);
            elseif rep.ok
                rep.summary = sprintf('检查通过，但有 %d 项提醒', nWarn);
            else
                rep.summary = sprintf('发现 %d 个错误、%d 项提醒', nErr, nWarn);
            end
        end

        function s = summary(Cfg)
            % 已启用步骤的中文摘要（cellstr）
            s = {};
            if Cfg.IsBIDStoDPARSF, s{end+1} = 'BIDS→DPARSF 结构'; end
            if Cfg.IsNeedConvertFunDCM2IMG, s{end+1} = '功能像 DICOM→NIfTI'; end
            if Cfg.IsNeedConvertT1DCM2IMG, s{end+1} = '结构像 DICOM→NIfTI'; end
            if Cfg.IsRemoveFirstTimePoints && Cfg.RemoveFirstTimePoints > 0
                s{end+1} = sprintf('删除前 %d 个时间点', Cfg.RemoveFirstTimePoints);
            end
            if Cfg.IsSliceTiming, s{end+1} = '时间层校正'; end
            if Cfg.IsRealign, s{end+1} = '头动校正'; end
            if Cfg.IsNeedReorientCropT1Img, s{end+1} = '结构像裁剪'; end
            if Cfg.IsBet, s{end+1} = 'BET 去颅骨'; end
            if Cfg.IsNeedT1CoregisterToFun, s{end+1} = 'T1 配准到功能像'; end
            switch Cfg.IsSegment
                case 1, s{end+1} = '旧版分割';
                case 2, s{end+1} = '统一分割';
            end
            if Cfg.IsDARTEL, s{end+1} = 'DARTEL 配准'; end
            if Cfg.IsNormalize > 0
                switch Cfg.IsNormalize
                    case 1, nm = 'EPI 模板标准化';
                    case 2, nm = 'T1 分割信息标准化';
                    case 3, nm = 'DARTEL 标准化';
                end
                s{end+1} = nm;
            end
            if Cfg.IsSmooth > 0
                s{end+1} = sprintf('平滑 %gmm', Cfg.Smooth.FWHM(1));
            end
            if Cfg.IsCovremove, s{end+1} = '协变量回归'; end
            if Cfg.IsFilter
                s{end+1} = sprintf('带通滤波 %.2f–%.2fHz', Cfg.Filter.AHighPass_LowCutoff, Cfg.Filter.ALowPass_HighCutoff);
            end
            if Cfg.IsDetrend, s{end+1} = '去趋势'; end
            if Cfg.IsCalALFF, s{end+1} = 'ALFF/fALFF'; end
            if Cfg.IsCalReHo, s{end+1} = 'ReHo'; end
            if Cfg.IsCalDegreeCentrality, s{end+1} = '度中心性'; end
            if Cfg.IsExtractROISignals, s{end+1} = 'ROI 时间序列'; end
            if Cfg.IsCalFC, s{end+1} = '功能连接'; end
            if Cfg.IsCalVMHC, s{end+1} = 'VMHC'; end
            if Cfg.IsScrubbing, s{end+1} = 'Scrubbing'; end
            if Cfg.IsCWAS, s{end+1} = 'CWAS'; end
            if isempty(s), s = {'未启用任何处理步骤'}; end
        end

        function n = estimateSteps(Cfg)
            % 估计引擎会打印多少个处理阶段（用于进度条）
            s = mrw.CfgBuilder.summary(Cfg);
            n = numel(s);
            % 实际日志中部分步骤会打印两条消息（Setup + 搬运/执行）
            if Cfg.IsSliceTiming, n = n + 1; end
            if Cfg.IsRealign, n = n + 1; end
            if Cfg.IsCovremove, n = n + 1; end
            if Cfg.IsNormalize > 0, n = n + 1; end
            n = max(1, n);
        end

        function saveCfg(Cfg, filePath)
            % 保存为 .mat（变量名 Cfg，与 DPABI 的 Load 兼容）
            State = mrw.CfgSchema.stateFromCfg(Cfg);
            Meta = struct('SavedAt', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
                'SavedBy', 'MRI_Workbench');
            save(filePath, 'Cfg', 'State', 'Meta');
        end

        function [Cfg, State, Meta] = loadCfg(filePath)
            S = load(filePath);
            if isfield(S, 'Cfg')
                Cfg = S.Cfg;
            elseif isfield(S, 'AutoDataProcessParameter')
                Cfg = S.AutoDataProcessParameter;
            else
                error('CfgBuilder: 文件中未找到 Cfg 变量：%s', filePath);
            end
            if isfield(S, 'State') && isstruct(S.State)
                State = S.State;
            else
                State = mrw.CfgSchema.stateFromCfg(Cfg);
            end
            if isfield(S, 'Meta')
                Meta = S.Meta;
            else
                Meta = struct();
            end
            % 兼容：DPABI 的 Cfg 可能没有 schema 新字段
            defs = mrw.CfgBuilder.defaultState();
            S2 = mrw.CfgSchema.entries();
            for i = 1:numel(S2)
                v = mrw.CfgSchema.getKey(State, S2(i).Key);
                if isempty(v)
                    State = mrw.CfgSchema.setKey(State, S2(i).Key, mrw.CfgSchema.getKey(defs, S2(i).Key));
                end
            end
        end

        function m = enabledSteps(Cfg)
            % 与 summary 相同，返回 char（单行，用 → 连接）
            s = mrw.CfgBuilder.summary(Cfg);
            m = strjoin(s, ' → ');
        end
    end

    methods (Static, Access = private)
        function st = mergeState(st, ov)
            % 递归合并部分状态
            if ~isstruct(ov) || ~isstruct(st)
                st = ov;
                return;
            end
            fn = fieldnames(ov);
            for i = 1:numel(fn)
                f = fn{i};
                if isstruct(ov.(f)) && isfield(st, f) && isstruct(st.(f))
                    st.(f) = mrw.CfgBuilder.mergeState(st.(f), ov.(f));
                else
                    st.(f) = ov.(f);
                end
            end
        end

        function tf = subjectHasAnat(wd, subjID)
            % DPARSF 约定：结构像位于 <wd>/T1Raw/<subjID>（兼容 AnatRaw / T1Img / T1ImgRaw）
            tf = false;
            cands = {'T1Raw', 'AnatRaw', 'T1Img', 'T1ImgRaw'};
            for i = 1:numel(cands)
                d = fullfile(wd, cands{i}, subjID);
                if exist(d, 'dir') == 7
                    tf = true;
                    return;
                end
            end
            % 兼容 co* 结构像等平铺文件
            try
                f = [dir(fullfile(wd, 'T1Raw', subjID, 'co*.nii*')); ...
                     dir(fullfile(wd, 'T1Raw', subjID, 'T1*.nii*'))];
                tf = ~isempty(f);
            catch
            end
        end

        function n = missingFiles(list)
            n = 0;
            if ischar(list), list = {list}; end
            for i = 1:numel(list)
                item = list{i};
                if ischar(item) && strncmpi(item, 'ROI', 3)
                    continue;   % 形如 'ROI Center...' 的内部定义，不按文件检查
                end
                if ischar(item) && exist(item, 'file') ~= 2
                    n = n + 1;
                end
            end
        end

        function n = countExt(folder, exts)
            % 统计目录下指定扩展名的文件数（大小写不敏感；.nii.gz 按整体匹配）
            n = 0;
            if exist(folder, 'dir') ~= 7, return; end
            try
                d = dir(folder);
                names = {d(~[d.isdir]).name};
                low = lower(names);
                for i = 1:numel(low)
                    for k = 1:numel(exts)
                        e = lower(exts{k});
                        if numel(low{i}) > numel(e) && strcmp(low{i}(end-numel(e)+1:end), e)
                            n = n + 1;
                            break;
                        end
                    end
                end
            catch
            end
        end

        function n = countPattern(folder, patterns)
            % 用通配符统计文件数
            n = 0;
            if exist(folder, 'dir') ~= 7, return; end
            for i = 1:numel(patterns)
                try
                    d = dir(fullfile(folder, patterns{i}));
                    n = n + numel(d);
                catch
                end
            end
        end

        function f = firstNifti(folder)
            % 找目录内第一个功能像 NIfTI 文件（.nii / .nii.gz）
            f = '';
            if exist(folder, 'dir') ~= 7, return; end
            try
                d = [dir(fullfile(folder, '*.nii')); dir(fullfile(folder, '*.nii.gz'))];
                if ~isempty(d)
                    f = fullfile(folder, d(1).name);
                end
            catch
            end
        end

        function info = detectStageDirs(wd)
            % 扫描工作目录中的 DPARSF 功能像阶段目录（FunRaw / FunImg*，支持 S2_ 前缀）
            % 返回 struct array：Name/Base/Suffix/SubjectCount/IsScrubbing
            info = struct('Name', {}, 'Base', {}, 'Suffix', {}, 'SubjectCount', {}, 'IsScrubbing', {});
            if isempty(wd) || exist(wd, 'dir') ~= 7, return; end
            L = dir(wd);
            for k = 1:numel(L)
                if ~L(k).isdir || isempty(L(k).name) || L(k).name(1) == '.'
                    continue;
                end
                nm = L(k).name;
                baseName = regexprep(nm, '^S\d+_', '');
                if strcmpi(baseName, 'FunRaw')
                    base = 'FunRaw';
                    suffix = '';
                elseif ~isempty(regexp(baseName, '^FunImg[A-Za-z]*$', 'once'))
                    base = 'FunImg';
                    suffix = baseName(7:end);
                else
                    continue;
                end
                subjCount = 0;
                sub = dir(fullfile(wd, nm));
                for q = 1:numel(sub)
                    if sub(q).isdir && ~isempty(sub(q).name) && sub(q).name(1) ~= '.'
                        subjCount = subjCount + 1;
                    end
                end
                info(end+1) = struct('Name', nm, 'Base', base, 'Suffix', suffix, ...
                    'SubjectCount', subjCount, 'IsScrubbing', ~isempty(regexp(suffix, 'B$', 'once'))); %#ok<AGROW>
            end
        end

        function text = describeStageDir(base, suffix)
            % 把 FunImg/FunRaw + 后缀字母翻译成中文处理步骤（与 DPARSFA_run 的追加顺序一致）
            if strcmpi(base, 'FunRaw')
                text = '原始功能像（DICOM）';
                return;
            end
            text = '功能像 NIfTI 起始数据';
            i = 1;
            while i <= numel(suffix)
                tok = '';
                if strncmp(suffix(i:end), 'sym', 3)
                    tok = 'sym';
                end
                if ~isempty(tok)
                    label = 'VMHC 对称化';
                    i = i + 3;
                else
                    tok = suffix(i);
                    switch tok
                        case 'A', label = '时间层校正';
                        case 'R', label = '头动校正';
                        case 'C', label = '协变量回归';
                        case 'W', label = '标准化';
                        case 'S', label = '平滑';
                        case 'F', label = '滤波';
                        case 'D', label = '去线性趋势';
                        case 'B', label = 'Scrubbing';
                        otherwise, label = '';
                    end
                    i = i + 1;
                end
                if isempty(label)
                    text = [text ' → 未知后缀']; %#ok<AGROW>
                    break;
                end
                text = [text ' → ' label]; %#ok<AGROW>
            end
        end

        function suffix = funDirSuffix(name)
            % 从起始目录名提取功能像阶段后缀（FunImgAR -> AR；FunImg/FunRaw -> ''）
            suffix = '';
            nm = regexprep(char(name), '^S\d+_', '');
            if strncmpi(nm, 'FunImg', 6)
                suffix = nm(7:end);
            end
        end

        function t = suggestText(dirName)
            % 续跑提示里的“（如 FunImgAR）”片段；目录为空时返回空串
            if isempty(dirName)
                t = '';
            else
                t = ['（如 ' char(dirName) '）'];
            end
        end

        function ov = presetClassic()
            ov = struct();
            ov.IsNeedConvertFunDCM2IMG = 0;
            ov.IsNeedConvertT1DCM2IMG = 0;
            ov.IsRemoveFirstTimePoints = 1;
            ov.RemoveFirstTimePoints = 10;
            ov.IsSliceTiming = 0;
            ov.IsRealign = 1;
            ov.IsNeedT1CoregisterToFun = 1;
            ov.IsSegment = 2;
            ov.IsDARTEL = 1;
            ov.IsNormalize = 3;
            ov.Normalize = struct('Timing', 'OnFunctionalData', ...
                'BoundingBox', [-90 -126 -72; 90 90 108], 'VoxSize', [3 3 3]);
            ov.IsSmooth = 1;
            ov.Smooth = struct('Timing', 'OnFunctionalData', 'FWHM', [4 4 4]);
            ov.IsCovremove = 1;
            ov.Covremove = struct('Timing', 'AfterRealign', 'PolynomialTrend', 1, ...
                'HeadMotion', 4, 'IsHeadMotionScrubbingRegressors', 0);
            ov.IsFilter = 1;
            ov.Filter = struct('Timing', 'AfterNormalize', ...
                'ALowPass_HighCutoff', 0.1, 'AHighPass_LowCutoff', 0.01, 'AAddMeanBack', 'Yes');
            ov.IsDetrend = 0;
            ov.IsCalALFF = 1;
            ov.IsCalReHo = 1;
            ov.IsCalDegreeCentrality = 0;
            ov.IsExtractROISignals = 0;
            ov.IsCalFC = 0;
            ov.IsCalVMHC = 0;
            ov.IsScrubbing = 0;
        end

        function ov = presetNoT1()
            ov = struct();
            ov.IsNeedConvertFunDCM2IMG = 0;
            ov.IsRemoveFirstTimePoints = 1;
            ov.RemoveFirstTimePoints = 10;
            ov.IsSliceTiming = 0;
            ov.IsRealign = 1;
            ov.IsNeedT1CoregisterToFun = 0;
            ov.IsSegment = 0;
            ov.IsDARTEL = 0;
            ov.IsNormalize = 1;
            ov.Normalize = struct('Timing', 'OnFunctionalData', ...
                'BoundingBox', [-90 -126 -72; 90 90 108], 'VoxSize', [3 3 3]);
            ov.IsSmooth = 1;
            ov.Smooth = struct('Timing', 'OnFunctionalData', 'FWHM', [4 4 4]);
            ov.IsCovremove = 0;
            ov.IsFilter = 1;
            ov.Filter = struct('Timing', 'AfterNormalize', ...
                'ALowPass_HighCutoff', 0.1, 'AHighPass_LowCutoff', 0.01, 'AAddMeanBack', 'Yes');
            ov.IsCalALFF = 1;
            ov.IsCalReHo = 0;
            ov.IsCalDegreeCentrality = 0;
        end

        function ov = presetBIDS()
            ov = mrw.CfgBuilder.presetClassic();
            ov.IsBIDStoDPARSF = 1;
            ov.IsNeedConvertFunDCM2IMG = 0;
            ov.IsNeedConvertT1DCM2IMG = 0;
        end

        function ov = presetQC()
            ov = struct();
            ov.IsNeedConvertFunDCM2IMG = 0;
            ov.IsRemoveFirstTimePoints = 1;
            ov.RemoveFirstTimePoints = 10;
            ov.IsSliceTiming = 0;
            ov.IsRealign = 1;
            ov.IsNeedT1CoregisterToFun = 0;
            ov.IsSegment = 0;
            ov.IsDARTEL = 0;
            ov.IsNormalize = 0;
            ov.IsSmooth = 0;
            ov.IsCovremove = 0;
            ov.IsFilter = 0;
            ov.IsDetrend = 0;
            ov.IsCalALFF = 0;
            ov.IsCalReHo = 0;
            ov.IsCalDegreeCentrality = 0;
            ov.IsExtractROISignals = 0;
            ov.IsCalFC = 0;
            ov.IsCalVMHC = 0;
            ov.IsScrubbing = 0;
        end

        function ov = presetBlank()
            % 空白/续跑预设：所有会改动数据的步骤与指标默认关闭（不删除、不重做）
            ov = struct();
            ov.IsNeedConvertFunDCM2IMG = 0;
            ov.IsNeedConvertT1DCM2IMG = 0;
            ov.IsBIDStoDPARSF = 0;
            ov.IsRemoveFirstTimePoints = 0;
            ov.RemoveFirstTimePoints = 0;
            ov.IsSliceTiming = 0;
            ov.IsRealign = 0;
            ov.IsNeedReorientFunImgInteractively = 0;
            ov.IsNeedReorientT1ImgInteractively = 0;
            ov.IsNeedReorientCropT1Img = 0;
            ov.IsNeedT1CoregisterToFun = 0;
            ov.IsNeedReorientInteractivelyAfterCoreg = 0;
            ov.IsBet = 0;
            ov.IsAutoMask = 0;
            ov.IsSegment = 0;
            ov.IsDARTEL = 0;
            ov.IsNormalize = 0;
            ov.IsWarpMasksIntoIndividualSpace = 0;
            ov.IsSmooth = 0;
            ov.IsCovremove = 0;
            ov.IsFilter = 0;
            ov.IsDetrend = 0;
            ov.IsCalVoxelSpecificHeadMotion = 0;
            ov.IsCalALFF = 0;
            ov.IsCalReHo = 0;
            ov.IsCalDegreeCentrality = 0;
            ov.IsExtractROISignals = 0;
            ov.IsCalFC = 0;
            ov.IsCalVMHC = 0;
            ov.IsScrubbing = 0;
            ov.IsCWAS = 0;
        end
    end
end
