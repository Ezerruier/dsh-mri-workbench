function test_core_lead
% Lead 核心模块冒烟测试：CfgSchema / CfgBuilder / Dpabi / Runner(静态) / Glossary
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
out = fullfile(here, 'out_core.txt');
fid = fopen(out, 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});

try
    % --- Dpabi ---
    st0 = mrw.Dpabi.status();
    say('Dpabi.root=%s', st0.DpabiRoot);
    say('Dpabi.version=%s', st0.DpabiVersion);
    say('SpmRoot=%s', st0.SpmRoot);
    say('HasDpabi=%d HasSpm=%d HasEngine=%d OnPath(dpabi=%d spm=%d) PCT=%d', ...
        st0.HasDpabi, st0.HasSpm, st0.HasEngine, st0.DpabiOnPath, st0.SpmOnPath, st0.PCT);
    say('ensurePath=%d', mrw.Dpabi.ensurePath());

    % --- Schema ---
    S = mrw.CfgSchema.entries();
    say('schema entries=%d groups=%d', numel(S), numel(mrw.CfgSchema.groups()));
    keys = {S.Key};
    say('unique keys=%d', numel(unique(keys)));
    d = mrw.CfgSchema.defaults();
    say('defaults.IsNormalize=%g defaults.Covremove.HeadMotion=%g', ...
        d.IsNormalize, d.Covremove.HeadMotion);
    say('enum options: IsNormalize=%d IsSegment=%d IsSmooth=%d', ...
        numel(mrw.CfgSchema.get('IsNormalize').Options), ...
        numel(mrw.CfgSchema.get('IsSegment').Options), ...
        numel(mrw.CfgSchema.get('IsSmooth').Options));
    stt = mrw.CfgBuilder.defaultState();
    say('IsSliceTiming disabled? %d', mrw.CfgSchema.enabled(mrw.CfgSchema.get('SliceTiming.SliceNumber'), stt));
    stt.IsSliceTiming = 1;
    say('after enabling IsSliceTiming: %d', mrw.CfgSchema.enabled(mrw.CfgSchema.get('SliceTiming.SliceNumber'), stt));

    % --- CfgBuilder base ---
    base = mrw.Dpabi.blankTemplate();
    if isempty(base)
        say('WARN blankTemplate empty');
    else
        say('blankTemplate fields=%d version=%s', numel(fieldnames(base)), base.DPARSFVersion);
    end
    Cfg = mrw.CfgBuilder.build(mrw.CfgBuilder.defaultState());
    need = {'WorkingDir','DataProcessDir','SubjectID','TimePoints','TR','IsSliceTiming', ...
        'SliceTiming','IsRealign','IsNormalize','Normalize','IsSmooth','Smooth', ...
        'IsCovremove','Covremove','IsFilter','Filter','IsCalALFF','CalALFF', ...
        'IsCalReHo','CalReHo','CalFC','IsCalFC','IsAllowGUI','FunctionalSessionNumber', ...
        'StartingDirName','ParallelWorkersNumber'};
    miss = {};
    for i = 1:numel(need)
        if ~isfield(Cfg, need{i}), miss{end+1} = need{i}; end
    end
    say('Cfg missing fields: [%s]', strjoin(miss, ','));
    say('Cfg.SubjectNum=%d IsAllowGUI=%g SliceOrderLen=%d', ...
        Cfg.SubjectNum, Cfg.IsAllowGUI, numel(Cfg.SliceTiming.SliceOrder));

    % --- Preset + validate ---
    st2 = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), '经典静息态（DARTEL 全流程）');
    st2.WorkingDir = 'C:\__mrw_nonexist__';
    st2.DataProcessDir = st2.WorkingDir;
    st2.SubjectID = {'S01','S02'};
    st2.TR = 2; st2.TimePoints = 200;
    Cfg2 = mrw.CfgBuilder.build(st2, struct('AllowGUI', false));
    say('preset steps: %s', mrw.CfgBuilder.enabledSteps(Cfg2));
    say('preset flags: norm=%g seg=%g dartel=%g smooth=%g cov=%g filt=%g alff=%g reho=%g allowGUI=%g', ...
        Cfg2.IsNormalize, Cfg2.IsSegment, Cfg2.IsDARTEL, Cfg2.IsSmooth, ...
        Cfg2.IsCovremove, Cfg2.IsFilter, Cfg2.IsCalALFF, Cfg2.IsCalReHo, Cfg2.IsAllowGUI);
    rep = mrw.CfgBuilder.validate(Cfg2);
    say('validate ok=%d summary=%s', rep.ok, rep.summary);
    for i = 1:min(numel(rep.errors), 6), say('  ERR: %s', rep.errors{i}); end
    for i = 1:min(numel(rep.warnings), 6), say('  WARN: %s', rep.warnings{i}); end

    % --- 一致性：不做标准化时关闭 T1 步骤 ---
    st3 = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), '快速质控（仅转换+头动校正）');
    st3.WorkingDir = pwd; st3.SubjectID = {'A'};
    Cfg3 = mrw.CfgBuilder.build(st3);
    say('QC preset: seg=%g dartel=%g norm=%g smooth=%g cov=%g', ...
        Cfg3.IsSegment, Cfg3.IsDARTEL, Cfg3.IsNormalize, Cfg3.IsSmooth, Cfg3.IsCovremove);

    % --- 滤波校验（错误应被抓住） ---
    st4 = mrw.CfgBuilder.applyPreset(mrw.CfgBuilder.defaultState(), '经典静息态（DARTEL 全流程）');
    st4.WorkingDir = pwd; st4.SubjectID = {'A'};
    st4.Filter.AHighPass_LowCutoff = 0.2;
    Cfg4 = mrw.CfgBuilder.build(st4);
    rep4 = mrw.CfgBuilder.validate(Cfg4);
    say('bad-filter detected: ok=%d errors=%d', rep4.ok, numel(rep4.errors));

    % --- 保存/加载往返 ---
    tmp = [tempname '.mat'];
    mrw.CfgBuilder.saveCfg(Cfg2, tmp);
    [CfgL, StateL, MetaL] = mrw.CfgBuilder.loadCfg(tmp);
    say('save/load: subjects=%d norm=%g hasState=%d hasMeta=%d', ...
        numel(CfgL.SubjectID), CfgL.IsNormalize, isstruct(StateL), isstruct(MetaL));
    delete(tmp);

    % --- Glossary / Settings / Runner 静态 ---
    say('glossary count=%d', mrw.Glossary.count());
    say('settings file=%s', mrw.Settings.filePath());
    say('runner projectRoot=%s', mrw.Runner.projectRoot());
    L = mrw.Runner.listRuns();
    say('runs listed=%d', numel(L));

    say('DONE');
catch err
    say('EXCEPTION: %s', err.message);
    for k = 1:min(numel(err.stack), 8)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end
