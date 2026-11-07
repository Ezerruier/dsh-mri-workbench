function cli(action, resultFile, varargin)
% mrw.cli  供 DSH 插件（或任意外部进程）调用的无界面命令行桥
%
% 用法（在 MATLAB -batch 中，resultFile 为 UTF-8 JSON 结果文件）:
%   mrw.cli('env',     '<result.json>')
%   mrw.cli('presets', '<result.json>')
%   mrw.cli('scan',    '<result.json>', '<rootDir>', '<index.json>', 6)
%   mrw.cli('prepare', '<result.json>', '<index.json>', '<preset 序号或名称>', '<overrides.json>', '<outDir>')
%   mrw.cli('schema',  '<result.json>')   % 导出 CfgSchema 全部可调字段（供 DSH 页面手动覆盖参数）
%
% 说明:
%   - 所有结果（含中文）写入 resultFile（UTF-8），便于外部进程可靠解析；
%     标准输出只打印一行 ASCII 标记: MRW_RESULT_FILE <path>
%   - resultFile 不可写时回退为 stdout 标记块 MRW_RESULT_BEGIN/END。
%   - 本函数不执行预处理；DPARSF 预处理由 mrw.headlessRunner 在独立 MATLAB
%     进程中调用官方 DPARSFA_run 完成（DSH 插件用后台 Job 承载）。

root = fileparts(fileparts(mfilename('fullpath')));   % .../MRI_Workbench
addpath(root);

if nargin < 1 || isempty(action), action = 'env'; end
if nargin < 2 || isempty(resultFile), resultFile = ''; end

res = struct('ok', false, 'action', char(action), 'error', '');
try
    switch lower(char(action))
        case 'env'
            res = cliEnv();
        case 'presets'
            P = mrw.CfgBuilder.presets();
            res = struct('ok', true, 'action', 'presets', 'presets', {{P.Name}});
        case 'schema'
            res = cliSchema();
        case 'scan'
            if numel(varargin) < 2
                error('scan 需要参数: rootDir, indexOutFile [, maxDepth]');
            end
            maxDepth = 6;
            if numel(varargin) >= 3 && ~isempty(varargin{3})
                maxDepth = double(varargin{3});
            end
            res = cliScan(char(varargin{1}), char(varargin{2}), maxDepth);
        case 'prepare'
            if numel(varargin) < 4
                error('prepare 需要参数: indexFile, preset, overridesJsonFile, outDir');
            end
            res = cliPrepare(char(varargin{1}), char(varargin{2}), ...
                char(varargin{3}), char(varargin{4}));
        otherwise
            error('未知动作: %s（可用: env/presets/schema/scan/prepare）', char(action));
    end
catch err
    res = struct('ok', false, 'action', char(action), 'error', err.message);
    try
        res.stack = struct('name', {err.stack.name}, 'line', {err.stack.line});
    catch
    end
end

% 结果落盘（UTF-8），stdout 仅打印 ASCII 标记
json = jsonencode(res);
wrote = false;
if ~isempty(resultFile)
    try
        outDir = fileparts(resultFile);
        if ~isempty(outDir) && exist(outDir, 'dir') ~= 7
            mkdir(outDir);
        end
        fid = fopen(resultFile, 'w', 'n', 'UTF-8');
        if fid > 0
            fwrite(fid, json);
            fclose(fid);
            wrote = true;
        end
    catch
    end
end
if wrote
    fprintf('MRW_RESULT_FILE %s\n', resultFile);
else
    fprintf('MRW_RESULT_BEGIN\n%s\nMRW_RESULT_END\n', json);
end
end

% ------------------------------------------------------------------------
function res = cliEnv()
st = mrw.Dpabi.status();
P = mrw.CfgBuilder.presets();
res = struct();
res.ok = st.HasDpabi && st.HasSpm && st.HasEngine;
res.action = 'env';
res.dpabiRoot = st.DpabiRoot;
res.dpabiVersion = st.DpabiVersion;
res.spmRoot = st.SpmRoot;
res.matlabVersion = st.MatlabVersion;
res.hasDpabi = st.HasDpabi;
res.hasSpm = st.HasSpm;
res.hasEngine = st.HasEngine;
res.pct = st.PCT;
res.message = st.Message;
res.presets = {P.Name};
res.workbenchRoot = fileparts(fileparts(mfilename('fullpath')));
end

% ------------------------------------------------------------------------
function res = cliScan(rootDir, indexOutFile, maxDepth)
if exist(rootDir, 'dir') ~= 7
    error('数据根目录不存在: %s', rootDir);
end
t0 = tic;
idx = mrw.ScanEngine.scan(rootDir, struct('MaxDepth', maxDepth));
elapsed = toc(t0);

outDir = fileparts(indexOutFile);
if ~isempty(outDir) && exist(outDir, 'dir') ~= 7
    mkdir(outDir);
end
fid = fopen(indexOutFile, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入索引文件: %s', indexOutFile);
end
fwrite(fid, jsonencode(idx));
fclose(fid);

subs = struct('id', {}, 'timePoints', {}, 'tr', {}, 'sliceNumber', {}, ...
    'funType', {}, 'sessions', {}, 'status', {});
for i = 1:numel(idx.Subjects)
    s = idx.Subjects(i);
    subs(i).id = s.ID;
    subs(i).timePoints = s.TimePoints;
    subs(i).tr = s.TR;
    subs(i).sliceNumber = s.SliceNumber;
    subs(i).funType = s.FunType;
    subs(i).sessions = s.Sessions;
    subs(i).status = s.Status;
end

res = struct();
res.ok = true;
res.action = 'scan';
res.root = rootDir;
res.indexPath = indexOutFile;
res.layout = idx.Layout;
res.layoutName = idx.LayoutName;
res.subjectCount = numel(idx.Subjects);
res.subjects = subs;
res.workingDir = idx.Detected.WorkingDir;
res.startingDirName = idx.Detected.StartingDirName;
res.functionalSessionNumber = idx.Detected.FunctionalSessionNumber;
res.tr = idx.Detected.TR;
res.timePoints = idx.Detected.TimePoints;
res.sliceNumber = idx.Detected.SliceNumber;
res.isBIDS = false;
if isfield(idx.Detected, 'IsBIDS')
    res.isBIDS = logical(idx.Detected.IsBIDS);
end
res.warnings = idx.Warnings;
res.errors = idx.Errors;
res.elapsedSeconds = elapsed;
end

% ------------------------------------------------------------------------
function res = cliPrepare(indexFile, presetName, overridesFile, outDir)
if exist(indexFile, 'file') ~= 2
    error('索引文件不存在: %s', indexFile);
end
idx = jsondecode(fileread(indexFile));
if exist(outDir, 'dir') ~= 7
    mkdir(outDir);
end

% 1) 状态：默认值 + 预设 + 扫描检测结果
st = mrw.CfgBuilder.defaultState();
P = mrw.CfgBuilder.presets();
appliedPreset = '';
if ~isempty(presetName) && ~strcmp(presetName, '-')
    presetIdx = str2double(presetName);
    if ~isnan(presetIdx) && presetIdx >= 1 && presetIdx <= numel(P)
        appliedPreset = P(round(presetIdx)).Name;
    else
        appliedPreset = presetName;
    end
    st = mrw.CfgBuilder.applyPreset(st, appliedPreset);
end
if isstruct(idx) && isfield(idx, 'Detected')
    d = idx.Detected;
    st.WorkingDir = d.WorkingDir;
    st.DataProcessDir = d.WorkingDir;
    st.StartingDirName = d.StartingDirName;
    if isfield(d, 'FunctionalSessionNumber') && d.FunctionalSessionNumber >= 1
        st.FunctionalSessionNumber = d.FunctionalSessionNumber;
    end
    if isfield(d, 'SubjectIDs')
        ids = d.SubjectIDs;
        if ischar(ids), ids = {ids}; end
        if isstring(ids), ids = cellstr(ids); end
        if ~iscell(ids), ids = {}; end
        st.SubjectID = ids(:)';
    end
    if isfield(d, 'TR') && ~isempty(d.TR) && isfinite(d.TR) && d.TR > 0
        st.TR = d.TR;
    end
    if isfield(d, 'TimePoints') && ~isempty(d.TimePoints) && isfinite(d.TimePoints) && d.TimePoints > 0
        st.TimePoints = d.TimePoints;
    end
    if isfield(d, 'SliceNumber') && ~isempty(d.SliceNumber) && isfinite(d.SliceNumber) && d.SliceNumber > 0
        st.SliceTiming.SliceNumber = d.SliceNumber;
    end
    isBIDS = false;
    if isfield(d, 'IsBIDS'), isBIDS = logical(d.IsBIDS); end
    if isBIDS
        st.IsBIDStoDPARSF = 1;
        st.IsNeedConvertFunDCM2IMG = 0;
        st.IsNeedConvertT1DCM2IMG = 0;
        st.IsNeedReorientCropT1Img = 0;
    else
        funType = '';
        anatDir = '';
        if isfield(idx, 'Subjects') && ~isempty(idx.Subjects)
            if isfield(idx.Subjects, 'FunType'), funType = idx.Subjects(1).FunType; end
            if isfield(idx.Subjects, 'AnatDir'), anatDir = idx.Subjects(1).AnatDir; end
        end
        if any(strcmpi(funType, {'DICOM'}))
            st.IsNeedConvertFunDCM2IMG = 1;
            st.IsNeedConvertT1DCM2IMG = 1;
            st.IsNeedReorientCropT1Img = 0;
        else
            st.IsNeedConvertFunDCM2IMG = 0;
            st.IsNeedConvertT1DCM2IMG = 0;
            st.IsNeedReorientCropT1Img = 0;
            if ischar(anatDir) && contains(lower(anatDir), 't1img')
                st.IsNeedReorientCropT1Img = 1;
            end
        end
    end
end

% 2) 覆盖项（JSON 数组 [{key,value}]，key 为 CfgSchema 路径）
appliedOverrides = struct('key', {}, 'value', {});
if exist(overridesFile, 'file') == 2
    txt = fileread(overridesFile);
    if ~isempty(strtrim(txt))
        try
            ov = jsondecode(txt);
            if isstruct(ov) && isfield(ov, 'overrides'), ov = ov.overrides; end
            for i = 1:numel(ov)
                item = ov(i);
                if isstruct(item) && isfield(item, 'key') && isfield(item, 'value')
                    st = mrw.CfgSchema.setKey(st, char(item.key), item.value);
                    appliedOverrides(end+1) = struct('key', char(item.key), 'value', item.value); %#ok<AGROW>
                end
            end
        catch err
            warning('mrw:cli:overrides', '解析覆盖参数失败：%s', err.message);
        end
    end
end

% 3) 构建与校验
Cfg = mrw.CfgBuilder.build(st, struct('AllowGUI', false));
rep = mrw.CfgBuilder.validate(Cfg, idx.Detected);
steps = mrw.CfgBuilder.summary(Cfg);

cfgPath = fullfile(outDir, 'Cfg.mat');
save(cfgPath, 'Cfg', 'st');

stateFile = fullfile(outDir, 'state.json');
fid = fopen(stateFile, 'w', 'n', 'UTF-8');
fwrite(fid, jsonencode(st));
fclose(fid);

checksFile = fullfile(outDir, 'checks.json');
chk = struct('name', {}, 'level', {}, 'message', {});
for i = 1:numel(rep.checks)
    chk(i).name = rep.checks(i).Name;
    chk(i).level = rep.checks(i).Level;
    chk(i).message = rep.checks(i).Message;
end
checksOut = struct('ok', rep.ok, 'summary', rep.summary, ...
    'errors', {rep.errors}, 'warnings', {rep.warnings}, 'checks', chk);
fid = fopen(checksFile, 'w', 'n', 'UTF-8');
fwrite(fid, jsonencode(checksOut));
fclose(fid);

res = struct();
res.ok = rep.ok;
res.action = 'prepare';
res.preset = appliedPreset;
res.cfgPath = cfgPath;
res.stateFile = stateFile;
res.checksFile = checksFile;
res.summary = rep.summary;
res.errors = rep.errors;
res.warnings = rep.warnings;
res.steps = steps;
res.stepCount = numel(steps);
res.overrides = appliedOverrides;
res.overrideCount = numel(appliedOverrides);
res.subjectCount = numel(Cfg.SubjectID);
res.subjectIDs = Cfg.SubjectID;
res.workingDir = Cfg.WorkingDir;
res.startingDirName = Cfg.StartingDirName;
res.tr = Cfg.TR;
res.timePoints = Cfg.TimePoints;
res.checks = chk;

% T1 裁剪兼容模式（页面/Agent 展示用）：auto / old_dcm2nii / no_crop
t1Mode = 'auto';
if isfield(Cfg, 'T1CropCompat')
    t1Mode = mrw.T1Compat.normalizeMode(Cfg.T1CropCompat);
end
res.t1CropCompat = t1Mode;
res.t1CropCompatLabel = mrw.T1Compat.labelOf(t1Mode);
res.t1CropPlan = mrw.T1Compat.planOf(t1Mode);
res.t1CropIsAction = ~strcmp(t1Mode, 'auto') && mrw.T1Compat.t1Needed(Cfg);
end

function res = cliSchema()
% 导出 CfgSchema 全部可调字段（key/group/label/en/type/default/options/dependsOn/advanced）
% DSH 页面用它提供“手动调整参数”的字段列表，避免 Host 侧硬编码字段。
S = mrw.CfgSchema.entries();
E = repmat(struct('key', '', 'group', '', 'label', '', 'en', '', 'type', '', ...
    'default', [], 'options', {{}}, 'dependsOn', {{}}, 'advanced', false), numel(S), 1);
for i = 1:numel(S)
    E(i).key = S(i).Key;
    E(i).group = S(i).Group;
    E(i).label = S(i).Label;
    E(i).en = S(i).EN;
    E(i).type = S(i).Type;
    d = S(i).Default;
    if iscell(d) && isempty(d), d = []; end
    E(i).default = d;
    opts = cell(1, numel(S(i).Options));
    for j = 1:numel(S(i).Options)
        opts{j} = struct('label', S(i).Options(j).Label, 'value', S(i).Options(j).Value);
    end
    E(i).options = opts;
    E(i).dependsOn = S(i).DependsOn;
    E(i).advanced = logical(S(i).Advanced);
end
res = struct('ok', true, 'action', 'schema', 'count', numel(S), 'entries', E);
res.groups = mrw.CfgSchema.groups();
end
