classdef CfgSchema
% CfgSchema  DPARSFA 预处理配置字段的元数据（单一数据源）
%
% 本类集中定义工作台 UI 使用的全部 DPARSFA Cfg 字段：
%   Key        - Cfg 中的路径，如 'SliceTiming.SliceOrder'（点号表示嵌套）
%   Group      - UI 分组（中文），决定参数面板的子选项卡
%   Label      - 中文短标签（UI 主文字）
%   EN         - 英文原术语（与 DPABI 界面/文档对应）
%   Type       - 控件类型：bool|enum|int|double|vector|text|dir|file|maskfile|roi|subjects
%   Default    - 默认值
%   Options    - enum 的可选项（struct array: Label/Value）
%   DependsOn  - 启用条件（struct array: Key/Op/Value，多个为 AND，OR 用同一条中的 '|' 表示）
%   Advanced   - 是否属于高级选项（UI 可折叠）
%
% 说明：本文件由 Lead 维护；新增字段请同步 resources/glossary.tsv（术语解释）。

    methods (Static)

        function S = entries()
            persistent cache
            if ~isempty(cache)
                S = cache;
                return;
            end

            % 列: Key, Group, Label, EN, Type, Default, Options, DependsOn, Advanced
            R = {
                % ---------------- 基础设置 ----------------
                'WorkingDir',                '基础设置', '工作目录',                 'Working Directory',              'dir',     '',                           '', '', 0
                'DataProcessDir',            '基础设置', '处理输出目录（默认=工作目录）','Data Process Directory',       'dir',     '',                           '', '', 1
                'StartingDirName',           '基础设置', '起始目录名',               'Starting Directory Name',        'text',    'FunRaw',                     '', '', 0
                'FunctionalSessionNumber',   '基础设置', '功能像 session 数',        'Functional Sessions #',          'int',     1,                            '', '', 0
                'TimePoints',                '基础设置', '时间点数（0=自动读取）',   'Time Points',                    'int',     0,                            '', '', 0
                'TR',                        '基础设置', '重复时间 TR（秒，0=自动）','TR',                             'double',  0,                            '', '', 0
                'SubjectID',                 '基础设置', '受试者列表',               'Subject ID List',                'subjects',{},                           '', '', 0
                'IsNeedConvertFunDCM2IMG',   '基础设置', '功能像 DICOM 转 NIfTI',    'Convert Functional DICOM to NIfTI','bool',   0,                            '', '', 0
                'IsNeedConvertT1DCM2IMG',    '基础设置', '结构像 DICOM 转 NIfTI',    'Convert T1 DICOM to NIfTI',      'bool',    0,                            '', '', 0
                'IsBIDStoDPARSF',            '基础设置', 'BIDS 数据转 DPARSF 结构',  'BIDS to DPARSF',                 'bool',    0,                            '', '', 0

                % ---------------- 时间层与头动 ----------------
                'IsRemoveFirstTimePoints',   '时间层与头动', '删除初始时间点',        'Remove First Time Points',       'bool',    0,                            '', '', 0
                'RemoveFirstTimePoints',     '时间层与头动', '删除个数',              'Number of Time Points to Remove','int',     0,                            '', 'IsRemoveFirstTimePoints=1', 0
                'IsSliceTiming',             '时间层与头动', '时间层校正',            'Slice Timing',                   'bool',    0,                            '', '', 0
                'SliceTiming.SliceNumber',   '时间层与头动', '层数（0=自动）',        'Slice Number',                   'int',     0,                            '', 'IsSliceTiming=1', 0
                'SliceTiming.SliceOrder',    '时间层与头动', '层采集顺序',            'Slice Order',                    'vector',  [1:2:33,2:2:32],             '', 'IsSliceTiming=1', 0
                'SliceTiming.ReferenceSlice','时间层与头动', '参考层（0=自动）',      'Reference Slice',                'int',     0,                            '', 'IsSliceTiming=1', 0
                'IsRealign',                 '时间层与头动', '头动校正（Realign）',   'Realign (Head Motion Correction)','bool',    0,                           '', '', 0
                'IsCalVoxelSpecificHeadMotion','时间层与头动','体素特异头动指标',      'Voxel-Specific Head Motion',     'bool',    0,                            '', 'IsRealign=1', 1

                % ---------------- 结构像处理 ----------------
                'IsNeedReorientFunImgInteractively','结构像处理','交互调整功能像原点', 'Reorient Functional Images Interactively','bool',0,                       '', 'IsAllowGUI=1', 1
                'IsNeedReorientT1ImgInteractively', '结构像处理','交互调整结构像原点', 'Reorient T1 Images Interactively','bool',    0,                            '', 'IsAllowGUI=1', 1
                'IsNeedReorientCropT1Img',   '结构像处理', '结构像裁剪（去颈部空气）', 'Reorient and Crop T1',          'bool',    0,                            '', '', 0
                'T1CropCompat',              '结构像处理', 'T1 裁剪兼容模式',        'T1 Crop Compatibility',          'enum',    'auto', 'auto:自动（DPARSF 默认）|old_dcm2nii:旧版 dcm2nii（可裁剪 NIfTI）|no_crop:免裁剪（未裁剪 T1 直通，需 QC）', '', 0
                'IsBet',                     '结构像处理', 'BET 去颅骨',             'BET (FSL)',                      'bool',    0,                            '', '', 0
                'IsAutoMask',                '结构像处理', '自动脑掩膜 AutoMask',    'AutoMask',                       'bool',    0,                            '', '', 1
                'IsNeedT1CoregisterToFun',   '结构像处理', 'T1 配准到功能像',        'T1 Coreg to Fun',                'bool',    0,                            '', '', 0
                'IsNeedReorientInteractivelyAfterCoreg','结构像处理','配准后交互调整','Reorient After Coregistration', 'bool',    0,                            '', 'IsAllowGUI=1', 1
                'IsSegment',                 '结构像处理', '脑组织分割',             'Segmentation',                   'enum',    0, '0:不分割|1:旧版分割(Old Segment)|2:统一分割(New Segment)', '', 0
                'Segment.AffineRegularisationInSegmentation','结构像处理','仿射正则化人群','Affine Regularisation in Segmentation','enum','mni','mni:欧美人群(MNI)|eastern:东亚人群(Eastern)|subj:个体自身模板(实验性)','IsSegment=2',0
                'IsDARTEL',                  '结构像处理', 'DARTEL 配准',            'DARTEL',                         'bool',    0,                            '', 'IsSegment=2', 0

                % ---------------- 标准化与平滑 ----------------
                'IsNormalize',               '标准化与平滑', '空间标准化',            'Normalize',                      'enum',    0, '0:不标准化|1:EPI 模板直接标准化|2:基于 T1 分割信息标准化|3:DARTEL 标准化', '', 0
                'Normalize.Timing',          '标准化与平滑', '标准化阶段',            'Normalize Timing',               'enum',    'OnFunctionalData', 'OnFunctionalData:功能像阶段标准化|OnResults:指标结果阶段标准化', 'IsNormalize>0', 1
                'Normalize.BoundingBox',     '标准化与平滑', '输出包围盒',            'Bounding Box',                   'vector',  [-90 -126 -72; 90 90 108], '', 'IsNormalize>0', 0
                'Normalize.VoxSize',         '标准化与平滑', '输出体素大小 (mm)',     'Voxel Size',                     'vector',  [3 3 3],                     '', 'IsNormalize>0', 0
                'MaskFile',                  '标准化与平滑', '脑掩膜文件',            'Mask File',                      'maskfile','Default',                    '', '', 0
                'IsWarpMasksIntoIndividualSpace','标准化与平滑','掩膜反算到个体空间', 'Warp Masks into Individual Space','bool',   0,                            '', '', 1
                'IsSmooth',                  '标准化与平滑', '平滑',                  'Smooth',                         'enum',    0, '0:不平滑|1:普通平滑|2:DARTEL 平滑', 'IsNormalize>0', 0
                'Smooth.Timing',             '标准化与平滑', '平滑阶段',              'Smooth Timing',                  'enum',    'OnFunctionalData', 'OnFunctionalData:功能像阶段平滑|OnResults:指标结果阶段平滑', 'IsSmooth>0', 1
                'Smooth.FWHM',               '标准化与平滑', '平滑核 FWHM (mm)',      'FWHM',                           'vector',  [4 4 4],                     '', 'IsSmooth>0', 0

                % ---------------- 回归与滤波 ----------------
                'IsCovremove',               '回归与滤波', '协变量回归',             'Nuisance Covariates Regression', 'bool',    0,                            '', '', 0
                'Covremove.Timing',          '回归与滤波', '回归阶段',               'Nuisance Regression Timing',     'enum',    'AfterRealign', 'AfterRealign:头动校正后（个体空间）|AfterNormalize:标准化后（MNI 空间）', 'IsCovremove=1', 0
                'Covremove.PolynomialTrend', '回归与滤波', '多项式趋势阶数',         'Polynomial Trend',               'enum',    1, '0:常数|1:常数+线性|2:+二次|3:+三次', 'IsCovremove=1', 0
                'Covremove.HeadMotion',      '回归与滤波', '头动模型',               'Head Motion Model',              'enum',    4, '1:6 参数（当前点）|2:12 参数（当前+前一点）|3:18 参数（当前+平方）|4:Friston 24 参数', 'IsCovremove=1', 0
                'Covremove.IsHeadMotionScrubbingRegressors','回归与滤波','头动 scrubbing 回归量','Head Motion Scrubbing Regressors','bool',0,                    '', 'IsCovremove=1', 1
                'Covremove.HeadMotionScrubbingRegressors.FDType','回归与滤波','FD 类型','FD Type','enum','FD_Jenkinson','FD_Power:Power FD|FD_Jenkinson:Jenkinson FD','Covremove.IsHeadMotionScrubbingRegressors=1',1
                'Covremove.HeadMotionScrubbingRegressors.FDThreshold','回归与滤波','FD 阈值','FD Threshold','double',0.2,'','Covremove.IsHeadMotionScrubbingRegressors=1',1
                'Covremove.HeadMotionScrubbingRegressors.PreviousPoints','回归与滤波','向前扩展时间点','Previous Points','int',0,'','Covremove.IsHeadMotionScrubbingRegressors=1',1
                'Covremove.HeadMotionScrubbingRegressors.LaterPoints','回归与滤波','向后扩展时间点','Later Points','int',0,'','Covremove.IsHeadMotionScrubbingRegressors=1',1
                'Covremove.WM.IsRemove',     '回归与滤波', '白质信号回归',           'White Matter Signal',            'bool',    1,                            '', 'IsCovremove=1', 0
                'Covremove.WM.Mask',         '回归与滤波', '白质掩膜来源',           'WM Mask Source',                 'enum',    'SPM', 'SPM:SPM 组织概率图|Segment:个体分割结果', 'Covremove.WM.IsRemove=1', 1
                'Covremove.WM.MaskThreshold','回归与滤波', '白质掩膜阈值',           'WM Mask Threshold',              'double',  0.99,                         '', 'Covremove.WM.IsRemove=1', 1
                'Covremove.WM.Method',       '回归与滤波', '白质信号提取方法',       'WM Signal Method',               'enum',    'Mean', 'Mean:感兴趣区平均信号|CompCor:CompCor 主成分', 'Covremove.WM.IsRemove=1', 1
                'Covremove.WM.CompCorPCNum', '回归与滤波', '白质 CompCor 主成分数',  'WM CompCor PC Number',           'int',     5,                            '', 'Covremove.WM.Method=CompCor', 1
                'Covremove.CSF.IsRemove',    '回归与滤波', '脑脊液信号回归',         'CSF Signal',                     'bool',    1,                            '', 'IsCovremove=1', 0
                'Covremove.CSF.Mask',        '回归与滤波', '脑脊液掩膜来源',         'CSF Mask Source',                'enum',    'SPM', 'SPM:SPM 组织概率图|Segment:个体分割结果', 'Covremove.CSF.IsRemove=1', 1
                'Covremove.CSF.MaskThreshold','回归与滤波','脑脊液掩膜阈值',         'CSF Mask Threshold',             'double',  0.99,                         '', 'Covremove.CSF.IsRemove=1', 1
                'Covremove.CSF.Method',      '回归与滤波', '脑脊液信号提取方法',     'CSF Signal Method',              'enum',    'Mean', 'Mean:感兴趣区平均信号|CompCor:CompCor 主成分', 'Covremove.CSF.IsRemove=1', 1
                'Covremove.CSF.CompCorPCNum', '回归与滤波', '脑脊液 CompCor 主成分数','CSF CompCor PC Number',         'int',     5,                            '', 'Covremove.CSF.Method=CompCor', 1
                'Covremove.WholeBrain.IsRemove','回归与滤波','全脑信号回归（GSR）',  'Global Signal Regression',       'bool',    0,                            '', 'IsCovremove=1', 0
                'Covremove.WholeBrain.Mask', '回归与滤波', '全脑掩膜来源',           'Global Signal Mask',             'enum',    'SPM', 'SPM:SPM 脑掩膜|AutoMask:AutoMask 自动掩膜', 'Covremove.WholeBrain.IsRemove=1', 1
                'Covremove.WholeBrain.Method','回归与滤波','全脑信号提取方法',      'Global Signal Method',           'enum',    'Mean', 'Mean:全脑平均信号', 'Covremove.WholeBrain.IsRemove=1', 1
                'Covremove.OtherCovariatesROI','回归与滤波','其他协变量 ROI/文件',   'Other Covariates ROI',           'roi',     {},                           '', 'IsCovremove=1', 1
                'Covremove.IsAddMeanBack',   '回归与滤波', '回归后加回均值',         'Add Mean Back',                  'bool',    0,                            '', 'IsCovremove=1', 0
                'IsFilter',                  '回归与滤波', '理想带通滤波',           'Filter (Ideal Band-pass)',       'bool',    0,                            '', '', 0
                'Filter.Timing',             '回归与滤波', '滤波阶段',               'Filter Timing',                  'enum',    'AfterNormalize', 'BeforeNormalize:标准化前|AfterNormalize:标准化后', 'IsFilter=1', 1
                'Filter.ALowPass_HighCutoff','回归与滤波', '低通截止频率 (Hz)',      'Low-pass Cutoff',                'double',  0.1,                          '', 'IsFilter=1', 0
                'Filter.AHighPass_LowCutoff','回归与滤波', '高通截止频率 (Hz)',      'High-pass Cutoff',               'double',  0.01,                         '', 'IsFilter=1', 0
                'Filter.AAddMeanBack',       '回归与滤波', '滤波后加回均值',         'Add Mean Back (Filter)',         'enum',    'Yes', 'Yes:是（保留信号幅度信息）|No:否', 'IsFilter=1', 1
                'IsDetrend',                 '回归与滤波', '去线性趋势',             'Detrend',                        'bool',    0,                            '', '', 0

                % ---------------- 指标计算 ----------------
                'IsCalALFF',                 '指标计算', 'ALFF / fALFF',            'ALFF and fALFF',                 'bool',    0,                            '', '', 0
                'CalALFF.AHighPass_LowCutoff','指标计算','ALFF 高通截止 (Hz)',      'ALFF High-pass Cutoff',          'double',  0.01,                         '', 'IsCalALFF=1', 0
                'CalALFF.ALowPass_HighCutoff','指标计算','ALFF 低通截止 (Hz)',      'ALFF Low-pass Cutoff',           'double',  0.1,                          '', 'IsCalALFF=1', 0
                'IsCalReHo',                 '指标计算', 'ReHo（局部一致性）',      'ReHo',                           'bool',    0,                            '', '', 0
                'CalReHo.ClusterNVoxel',     '指标计算', 'ReHo 邻域体素数',         'ReHo Cluster Size',              'enum',    27, '7:7 体素|19:19 体素|27:27 体素', 'IsCalReHo=1', 0
                'CalReHo.SmoothReHo',        '指标计算', '平滑 ReHo 结果',          'Smooth ReHo',                    'bool',    0,                            '', 'IsCalReHo=1', 1
                'IsCalDegreeCentrality',     '指标计算', '度中心性 (DC)',           'Degree Centrality',              'bool',    0,                            '', '', 0
                'CalDegreeCentrality.rThreshold','指标计算','DC 相关阈值 r',         'DC r Threshold',                 'double',  0.25,                         '', 'IsCalDegreeCentrality=1', 0
                'IsExtractROISignals',       '指标计算', '提取 ROI 时间序列',       'Extract ROI Signals / Time Courses','bool',  0,                            '', '', 0
                'CalFC.ROIDef',              '指标计算', 'ROI 定义（文件/球坐标）', 'ROI Definition',                 'roi',     {},                           '', 'IsExtractROISignals=1|IsCalFC=1', 0
                'CalFC.IsMultipleLabel',     '指标计算', 'ROI 为多标签掩膜',        'Multiple Label ROI',             'bool',    0,                            '', 'IsExtractROISignals=1|IsCalFC=1', 1
                'IsCalFC',                   '指标计算', '功能连接 (FC)',           'Functional Connectivity',        'bool',    0,                            '', '', 0
                'IsDefineROIInteractively',  '指标计算', '交互式定义 ROI',          'Define ROI Interactively',       'bool',    0,                            '', 'IsAllowGUI=1', 1
                'IsExtractAALTC',            '指标计算', '提取 AAL 模板时间序列',   'Extract AAL Time Courses',       'bool',    0,                            '', '', 1
                'IsCalVMHC',                 '指标计算', 'VMHC（镜像同伦连接）',    'VMHC',                           'bool',    0,                            '', '', 0
                'IsSmoothBeforeVMHC',        '指标计算', 'VMHC 前平滑',             'Smooth before VMHC',             'bool',    0,                            '', 'IsCalVMHC=1', 1
                'IsNormalizeToSymmetricGroupT1Mean','指标计算','标准化到对称模板',  'Normalize to Symmetric Template','bool',    0,                            '', 'IsCalVMHC=1', 1
                'IsScrubbing',               '指标计算', '头动 Scrubbing（剔除坏点）','Scrubbing',                     'bool',    0,                            '', '', 0
                'Scrubbing.FDType',          '指标计算', 'FD 类型',                 'FD Type',                        'enum',    'FD_Jenkinson', 'FD_Power:Power FD|FD_Jenkinson:Jenkinson FD', 'IsScrubbing=1', 1
                'Scrubbing.FDThreshold',     '指标计算', 'FD 阈值',                 'FD Threshold',                   'double',  0.2,                          '', 'IsScrubbing=1', 0
                'Scrubbing.PreviousPoints',  '指标计算', '向前扩展时间点',          'Previous Points',                'int',     0,                            '', 'IsScrubbing=1', 1
                'Scrubbing.LaterPoints',     '指标计算', '向后扩展时间点',          'Later Points',                   'int',     0,                            '', 'IsScrubbing=1', 1
                'Scrubbing.ScrubbingMethod', '指标计算', '坏点处理方式',            'Scrubbing Method',               'enum',    'cut', 'cut:直接剔除|nearest:最近邻插值|linear:线性插值|spline:样条插值|pchip:PCHIP 插值', 'IsScrubbing=1', 1
                'IsCWAS',                    '指标计算', 'CWAS 分析',               'CWAS',                           'bool',    0,                            '', '', 1
                'CWAS.iter',                 '指标计算', 'CWAS 迭代次数',           'CWAS Iterations',                'int',     0,                            '', 'IsCWAS=1', 1
                'CWAS.Regressors',           '指标计算', 'CWAS 回归量',             'CWAS Regressors',                'roi',     {},                           '', 'IsCWAS=1', 1

                % ---------------- 高级与运行 ----------------
                'SpecialMode',               '高级与运行', '特殊模式（物种/先验）',  'Special Mode',                   'enum',    0, '0:标准人类|1:旧版分割（老年脑）|2:猕猴|3:大鼠', '', 1
                'IsAllowGUI',                '高级与运行', '允许交互弹窗（需要图形界面）','Allow GUI',                  'bool',    0,                            '', '', 1
                'IsApplyDownloadedReorientMats','高级与运行','应用已保存的重定向矩阵','Apply Downloaded Reorient Mats','bool',   0,                            '', '', 1
                'ParallelWorkersNumber',     '高级与运行', '并行进程数（0=关闭）',    'Parallel Workers #',             'int',     0,                            '', '', 1
            };

            n = size(R, 1);
            S = repmat(struct('Key','','Group','','Label','','EN','','Type','','Default',[], ...
                'Options',struct('Label',{},'Value',{}), ...
                'DependsOn',struct('Conds',{}), ...
                'Advanced',false,'GlossaryKey',''), n, 1);
            for i = 1:n
                S(i).Key         = R{i,1};
                S(i).Group       = R{i,2};
                S(i).Label       = R{i,3};
                S(i).EN          = R{i,4};
                S(i).Type        = R{i,5};
                S(i).Default     = R{i,6};
                S(i).Options     = mrw.CfgSchema.parseOptions(R{i,7});
                S(i).DependsOn   = mrw.CfgSchema.parseDepends(R{i,8});
                S(i).Advanced    = logical(R{i,9});
                S(i).GlossaryKey = R{i,1};
            end
            cache = S;
        end

        function g = groups()
            S = mrw.CfgSchema.entries();
            [~, ia] = unique({S.Group}, 'stable');
            g = {S(ia).Group};
        end

        function e = get(key)
            S = mrw.CfgSchema.entries();
            e = [];
            for i = 1:numel(S)
                if strcmp(S(i).Key, key)
                    e = S(i);
                    return;
                end
            end
            error('CfgSchema: 未定义字段 %s', key);
        end

        function S = groupEntries(group)
            S = mrw.CfgSchema.entries();
            S = S(strcmp({S.Group}, group));
        end

        function st = defaults()
            % 返回与 Cfg 同构的默认状态结构体
            S = mrw.CfgSchema.entries();
            st = struct();
            for i = 1:numel(S)
                st = mrw.CfgSchema.setKey(st, S(i).Key, S(i).Default);
            end
        end

        function st = stateFromCfg(Cfg)
            % 从已有 DPARSF/DPARSFA Cfg 结构体生成 UI 状态（缺失字段用默认值）
            S = mrw.CfgSchema.entries();
            st = mrw.CfgSchema.defaults();
            for i = 1:numel(S)
                v = mrw.CfgSchema.getKey(Cfg, S(i).Key);
                if ~isempty(v)
                    st = mrw.CfgSchema.setKey(st, S(i).Key, v);
                end
            end
        end

        function v = getKey(st, path)
            % 按点号路径取嵌套结构体字段，不存在返回 []
            parts = strsplit(path, '.');
            v = st;
            for k = 1:numel(parts)
                if isstruct(v) && isfield(v, parts{k})
                    v = v.(parts{k});
                else
                    v = [];
                    return;
                end
            end
        end

        function st = setKey(st, path, v)
            % 按点号路径写入嵌套结构体字段
            parts = strsplit(path, '.');
            st = mrw.CfgSchema.setKeyRec(st, parts, v);
        end

        function tf = enabled(entry, st)
            % 依据 DependsOn 判断该字段在当前状态下是否可用
            tf = true;
            if isempty(entry.DependsOn)
                return;
            end
            D = entry.DependsOn;
            for g = 1:numel(D)
                conds = D(g).Conds;
                anyOK = false;
                for k = 1:numel(conds)
                    v = mrw.CfgSchema.getKey(st, conds(k).Key);
                    if mrw.CfgSchema.cmpVal(v, conds(k).Op, conds(k).Value)
                        anyOK = true;
                        break;
                    end
                end
                if ~anyOK
                    tf = false;
                    return;
                end
            end
        end

        function opts = parseOptions(spec)
            opts = struct('Label', {}, 'Value', {});
            if isempty(spec) || ~ischar(spec)
                return;
            end
            items = strsplit(spec, '|');
            for k = 1:numel(items)
                it = items{k};
                if isempty(it), continue; end
                p = strfind(it, ':');
                if isempty(p)
                    val = it; lab = it;
                else
                    val = strtrim(it(1:p(1)-1));
                    lab = strtrim(it(p(1)+1:end));
                end
                num = str2double(val);
                if ~isnan(num)
                    opts(end+1) = struct('Label', lab, 'Value', num); %#ok<AGROW>
                else
                    opts(end+1) = struct('Label', lab, 'Value', val); %#ok<AGROW>
                end
            end
        end
    end

    methods (Static, Access = private)
        function st = setKeyRec(st, parts, v)
            if numel(parts) == 1
                st.(parts{1}) = v;
            else
                f = parts{1};
                if ~isstruct(st) || ~isfield(st, f) || ~isstruct(st.(f))
                    st.(f) = struct();
                end
                st.(f) = mrw.CfgSchema.setKeyRec(st.(f), parts(2:end), v);
            end
        end

        function D = parseDepends(spec)
            % 返回 struct array；每个元素为一个 AND 条件组，组内 Conds 为 OR 备选
            D = struct('Conds', {});
            if isempty(spec) || ~ischar(spec)
                return;
            end
            items = strsplit(spec, ';');
            for k = 1:numel(items)
                it = strtrim(items{k});
                if isempty(it), continue; end
                alts = strsplit(it, '|');   % 同一条件内 OR：任一条满足即可启用
                conds = struct('Key', {}, 'Op', {}, 'Value', {});
                for j = 1:numel(alts)
                    tok = strtrim(alts{j});
                    if isempty(tok), continue; end
                    [key, op, val] = mrw.CfgSchema.splitCond(tok);
                    conds(end+1) = struct('Key', key, 'Op', op, 'Value', val); %#ok<AGROW>
                end
                if ~isempty(conds)
                    D(end+1) = struct('Conds', conds); %#ok<AGROW>
                end
            end
        end

        function tf = cmpVal(v, op, ref)
            tf = false;
            if isempty(v), return; end
            if islogical(v)
                v = double(v);
            end
            if isnumeric(v) && isnumeric(ref)
                switch op
                    case '=',  tf = (v == ref);
                    case '>',  tf = (v > ref);
                    case '<',  tf = (v < ref);
                    case '>=', tf = (v >= ref);
                    case '<=', tf = (v <= ref);
                    case '!=', tf = (v ~= ref);
                end
            else
                if strcmp(op, '=')
                    tf = strcmpi(char(v), char(ref));
                elseif strcmp(op, '!=')
                    tf = ~strcmpi(char(v), char(ref));
                end
            end
        end

        function [key, op, val] = splitCond(tok)
            pats = {'>=', '<=', '==', '~=', '=', '>', '<'};
            for p = 1:numel(pats)
                pth = strfind(tok, pats{p});
                if ~isempty(pth)
                    key = strtrim(tok(1:pth(1)-1));
                    op = pats{p};
                    if strcmp(op, '=='), op = '='; end
                    if strcmp(op, '~='), op = '!='; end
                    val = strtrim(tok(pth(1)+numel(pats{p}):end));
                    num = str2double(val);
                    if ~isnan(num)
                        val = num;
                    end
                    return;
                end
            end
            key = tok; op = '='; val = [];
        end
    end
end
