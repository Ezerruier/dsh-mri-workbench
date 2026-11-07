classdef NativePatch
% NativePatch  原生 DPABI / DPARSF 界面汉化 + 鼠标悬停解释（动态、可逆、零安装改动）
%
% 背景：DPABI 的主界面由 .fig 布局 + 加密 .p 回调组成，不能修改安装目录下的任何文件。
%       本类在原生窗口打开之后，动态地把可安全翻译的控件 String 改成中文，并给控件
%       设置中文 TooltipString（鼠标悬停显示术语概述）。所有改动都记录原值，
%       可随时完全还原；任何一步失败都被 try/catch 隔离，不影响原界面功能。
%
% 用法：
%   addpath('C:\...\MRI_Workbench');
%   mrw.NativePatch.patchAll();        % 汉化当前已打开的全部原生窗口
%   mrw.NativePatch.unpatchAll();      % 还原英文
%   s = mrw.NativePatch.patchFigure(fig);
%   tf = mrw.NativePatch.isPatched(fig);
%
% 中文标签来自 resources/native_labels.tsv（列：Figure, Tag, Style, English, Chinese,
% GlossaryKey）。Tooltip 优先用 mrw.Glossary（resources/glossary.tsv）；术语库缺失时
% 自动降级为“中文标签（English）”式简短提示，不报错。
%
% 安全规则（详见 docs/NATIVE_PATCH.md）：
%   * 只改 text / panel / pushbutton / checkbox / radiobutton（及 togglebutton）的
%     显示文字；popupmenu 的 String 一律不动（它的选项常被回调按字符串依赖），
%     只给它加 Tooltip；edit / listbox 的文字是数据，也不动。
%   * 只有“控件的当前文字 == 标签表里的 English 原文”时才翻译，绝不覆盖认不出的
%     文字；因此可安全地重复调用（幂等）。
%   * 原始 String / Tooltip 存于 figure 的 appdata（'mrwNativePatch'），unpatch 时
%     逐项还原；不写 DPABI 安装目录，不依赖 DPABI 内部句柄变量。
%
% 参见：mrw.NativeLaunch（打开原生窗口并自动监视新图窗）。

    methods (Static)

        % ================================================================
        % 公共 API
        % ================================================================

        function out = patchAll(varargin)
            % patchAll()  扫描并汉化当前所有可识别的原生 DPABI/DPARSF 窗口。
            %
            % 可选参数（名/值）：
            %   'Silent'  (false)  为 true 时不在命令行打印摘要。
            %
            % 返回聚合统计结构体（字段见 patchFigure），另有：
            %   FiguresScanned / FiguresPatched / Details（每图统计 struct array）
            p = inputParser;
            p.addParameter('Silent', false, @(x) islogical(x) || isnumeric(x));
            p.parse(varargin{:});
            silent = logical(p.Results.Silent);

            t0 = tic;
            out = struct('FiguresScanned', 0, 'FiguresPatched', 0, ...
                'Matched', 0, 'Translated', 0, 'AlreadyPatched', 0, ...
                'Tooltips', 0, 'Skipped', 0, 'Errors', 0, ...
                'Elapsed', 0, 'Details', []);
            details = [];

            figs = mrw.NativePatch.allFigures();
            out.FiguresScanned = numel(figs);
            for k = 1:numel(figs)
                f = figs(k);
                try
                    if ~mrw.NativePatch.isUsableFigure(f), continue; end
                    if isempty(mrw.NativePatch.keyForFigure(f)), continue; end
                    s = mrw.NativePatch.patchFigure(f);
                    out.FiguresPatched = out.FiguresPatched + 1;
                    out.Matched = out.Matched + s.Matched;
                    out.Translated = out.Translated + s.Translated;
                    out.AlreadyPatched = out.AlreadyPatched + s.AlreadyPatched;
                    out.Tooltips = out.Tooltips + s.Tooltips;
                    out.Skipped = out.Skipped + s.Skipped;
                    out.Errors = out.Errors + s.Errors;
                    if isempty(details), details = s; else, details(end+1) = s; end %#ok<AGROW>
                catch ME
                    out.Errors = out.Errors + 1;
                    if ~silent
                        fprintf('[NativePatch] 跳过图窗（%s）：%s\n', ...
                            mrw.NativePatch.safeName(f), ME.message);
                    end
                end
            end
            out.Details = details;
            out.Elapsed = toc(t0);

            if ~silent
                fprintf(['[NativePatch] 扫描 %d 个图窗，汉化 %d 个窗口：' ...
                    '翻译 %d 个控件，Tooltip %d 个，已汉化 %d，跳过 %d，异常 %d，耗时 %.1f ms\n'], ...
                    out.FiguresScanned, out.FiguresPatched, out.Translated, ...
                    out.Tooltips, out.AlreadyPatched, out.Skipped, out.Errors, ...
                    out.Elapsed * 1000);
            end
        end

        function s = patchFigure(fig)
            % patchFigure(fig)  汉化单个图窗；无法识别时返回零统计（不抛异常）。
            s = mrw.NativePatch.emptyStats();
            t0 = tic;
            try
                if ~mrw.NativePatch.isUsableFigure(fig)
                    s.Elapsed = toc(t0);
                    return;
                end
                key = mrw.NativePatch.keyForFigure(fig);
                s.Key = key;
                s.Name = mrw.NativePatch.safeName(fig);
                if isempty(key)
                    s.Elapsed = toc(t0);
                    return;
                end

                T = mrw.NativePatch.loadLabels();
                rows = T(strcmp({T.Figure}, key));
                if isempty(rows)
                    s.Elapsed = toc(t0);
                    return;
                end
                idx = mrw.NativePatch.figureIndex(key);

                % 收集候选控件：uicontrol 全部 + uipanel/uibuttongroup（Title）
                cands = [findall(fig, 'Type', 'uicontrol'); ...
                         findall(fig, 'Type', 'uipanel'); ...
                         findall(fig, 'Type', 'uibuttongroup')];

                rec = mrw.NativePatch.getRecord(fig);
                if isempty(rec)
                    rec = struct('FigureKey', key, 'Items', {{}});
                end

                for k = 1:numel(cands)
                    h = cands(k);
                    s.Found = s.Found + 1;
                    try
                        [rec, s] = mrw.NativePatch.patchOne(h, idx, rec, s);
                    catch ME
                        s.Errors = s.Errors + 1;
                        if isempty(s.LastError), s.LastError = ME.message; end
                    end
                end

                if ~isempty(rec.Items)
                    rec.FigureKey = key;
                    setappdata(fig, 'mrwNativePatch', rec);
                end
            catch ME
                s.Errors = s.Errors + 1;
                s.LastError = ME.message;
            end
            s.Elapsed = toc(t0);
        end

        function s = unpatchFigure(fig)
            % unpatchFigure(fig)  还原单个图窗的全部改动。
            s = struct('Restored', 0, 'Errors', 0, 'Elapsed', 0, 'Key', '');
            t0 = tic;
            try
                if isempty(fig) || ~isvalid(fig), s.Elapsed = toc(t0); return; end
                if ~isappdata(fig, 'mrwNativePatch'), s.Elapsed = toc(t0); return; end
                rec = getappdata(fig, 'mrwNativePatch');
                s.Key = rec.FigureKey;
                items = rec.Items;
                for k = 1:numel(items)
                    it = items{k};
                    try
                        if isempty(it.Handle) || ~isvalid(it.Handle), continue; end
                        if ~isempty(it.Prop) && ischar(it.Orig)
                            if mrw.NativePatch.setPropValue(it.Handle, it.Prop, it.Orig)
                                s.Restored = s.Restored + 1;
                            end
                        end
                        if it.TipChanged
                            if mrw.NativePatch.setTipRaw(it.Handle, it.OrigTip)
                                s.Restored = s.Restored + 1;
                            end
                        end
                    catch
                        s.Errors = s.Errors + 1;
                    end
                end
                try
                    rmappdata(fig, 'mrwNativePatch');
                catch
                end
            catch
                s.Errors = s.Errors + 1;
            end
            s.Elapsed = toc(t0);
        end

        function out = unpatchAll(varargin)
            % unpatchAll()  还原所有已汉化图窗。
            p = inputParser;
            p.addParameter('Silent', false, @(x) islogical(x) || isnumeric(x));
            p.parse(varargin{:});
            silent = logical(p.Results.Silent);

            t0 = tic;
            out = struct('FiguresRestored', 0, 'Restored', 0, 'Errors', 0, ...
                'Elapsed', 0, 'Details', []);
            details = [];
            figs = mrw.NativePatch.allFigures();
            for k = 1:numel(figs)
                f = figs(k);
                try
                    if ~mrw.NativePatch.isUsableFigure(f), continue; end
                    if ~isappdata(f, 'mrwNativePatch'), continue; end
                    s = mrw.NativePatch.unpatchFigure(f);
                    out.FiguresRestored = out.FiguresRestored + 1;
                    out.Restored = out.Restored + s.Restored;
                    out.Errors = out.Errors + s.Errors;
                    if isempty(details), details = s; else, details(end+1) = s; end %#ok<AGROW>
                catch
                    out.Errors = out.Errors + 1;
                end
            end
            out.Details = details;
            out.Elapsed = toc(t0);
            if ~silent
                fprintf('[NativePatch] 还原 %d 个窗口、%d 处文字/Tooltip（异常 %d），耗时 %.1f ms\n', ...
                    out.FiguresRestored, out.Restored, out.Errors, out.Elapsed * 1000);
            end
        end

        function tf = isPatched(fig)
            % isPatched(fig)  该图窗是否被本类汉化过（存在原始值记录）。
            tf = false;
            try
                if ~mrw.NativePatch.isUsableFigure(fig)
                    return;
                end
                tf = isappdata(fig, 'mrwNativePatch');
                if tf
                    rec = getappdata(fig, 'mrwNativePatch');
                    tf = isstruct(rec) && isfield(rec, 'Items') && ~isempty(rec.Items);
                end
            catch
                tf = false;
            end
        end

        % ================================================================
        % 资源 / 识别 / 调试辅助
        % ================================================================

        function T = labels()
            % labels()  返回已解析的 native_labels.tsv（struct array）。
            T = mrw.NativePatch.loadLabels();
        end

        function n = labelCount(figKey)
            % labelCount(figKey)  某原生窗口的标签行数；figKey 省略时返回总行数。
            T = mrw.NativePatch.loadLabels();
            if nargin < 1 || isempty(figKey)
                n = numel(T);
            else
                n = sum(strcmp({T.Figure}, char(figKey)));
            end
        end

        function key = keyForFigure(fig)
            % keyForFigure(fig)  返回 native_labels.tsv 中的 Figure 标识；识别不了返回 ''。
            key = '';
            try
                if ~mrw.NativePatch.isUsableFigure(fig)
                    return;
                end
                tag = char(mrw.NativePatch.safeGet(fig, 'Tag', ''));
                nm = char(mrw.NativePatch.safeGet(fig, 'Name', ''));
                key = mrw.NativePatch.identify(tag, nm, fig);
                if ~isempty(key) && mrw.NativePatch.labelCount(key) == 0
                    key = '';
                end
            catch
                key = '';
            end
        end

        function reset()
            % reset()  清空标签缓存（修改 native_labels.tsv 后调用，无需重启 MATLAB）。
            try
                clear mrw.NativePatch.loadLabels
            catch
            end
            try
                clear mrw.NativePatch.figureIndex
            catch
            end
        end

        function names = knownFigures()
            % knownFigures()  返回标签表覆盖的原生窗口标识（去重、保持顺序）。
            T = mrw.NativePatch.loadLabels();
            names = {};
            for k = 1:numel(T)
                if ~any(strcmp(T(k).Figure, names))
                    names{end+1} = T(k).Figure; %#ok<AGROW>
                end
            end
        end
    end

    % ====================================================================
    % 内部实现
    % ====================================================================
    methods (Static, Access = private)

        function s = emptyStats()
            s = struct('Key', '', 'Name', '', 'Found', 0, 'Matched', 0, ...
                'Translated', 0, 'AlreadyPatched', 0, 'Tooltips', 0, ...
                'Skipped', 0, 'Errors', 0, 'Elapsed', 0, 'LastError', '');
        end

        function figs = allFigures()
            figs = zeros(0, 1);
            try
                figs = findall(groot, 'Type', 'figure');
            catch
                try
                    figs = findall(0, 'Type', 'figure');
                catch
                end
            end
        end

        function tf = isUsableFigure(fig)
            tf = false;
            try
                tf = ~isempty(fig) && isscalar(fig) && isvalid(fig) && ...
                    isgraphics(fig) && strcmp(get(fig, 'Type'), 'figure');
            catch
                tf = false;
            end
        end

        function nm = safeName(fig)
            nm = '';
            try
                nm = char(mrw.NativePatch.safeGet(fig, 'Name', ''));
            catch
            end
            if isempty(nm)
                try
                    nm = char(mrw.NativePatch.safeGet(fig, 'Tag', ''));
                catch
                end
            end
        end

        function v = safeGet(h, prop, dflt)
            v = dflt;
            try
                v = get(h, prop);
            catch
            end
        end

        function key = identify(tag, nm, fig)
            % 先按 Tag（最稳），再按窗口标题，最后对通用 Tag 用特征子控件兜底。
            tag = strtrim(char(tag));
            nm = strtrim(char(nm));
            key = '';
            switch tag
                case 'figureDPABI',              key = 'dpabi'; return;
                case 'figureDPARSFmain',         key = 'DPARSF_main'; return;
                case 'figDPARSFAMain',           key = 'DPARSFA'; return;
                case 'figDPARSFMain',            key = 'DPARSF'; return;
                case 'DPARSF_FieldMap',          key = 'DPARSF_FieldMap'; return;
                case 'figScrubbingSetting',      key = 'DPARSF_ScrubbingSetting_gui'; return;
                case 'figureThresholingQuality', key = 'ReorientThreQC'; return;
            end
            nmLower = lower(nm);
            switch nmLower
                case 'dpabi'
                    key = 'dpabi'; return;
                case 'fieldmap settings'
                    key = 'DPARSF_FieldMap'; return;
                case 'nuisance setting'
                    key = 'DPARSF_NuisanceSetting'; return;
                case {'roi templates', 'roi template'}
                    key = 'DPARSF_ROI_Template'; return;
                case 'scrubbing settings'
                    key = 'DPARSF_ScrubbingSetting_gui'; return;
                case 'thresholing quality'
                    key = 'ReorientThreQC'; return;
            end
            % 标题只对“足够具体”的短语兜底，避免误识别用户自己的图窗
            if ~isempty(strfind(nmLower, 'nuisance setting')) %#ok<STREMP>
                key = 'DPARSF_NuisanceSetting'; return;
            end
            if ~isempty(strfind(nmLower, 'roi template')) || ...
                    ~isempty(strfind(nmLower, 'roi 模板')) %#ok<STREMP>
                key = 'DPARSF_ROI_Template'; return;
            end
            if ~isempty(strfind(nmLower, 'fieldmap settings')) %#ok<STREMP>
                key = 'DPARSF_FieldMap'; return;
            end
            if ~isempty(strfind(nmLower, 'scrubbing settings')) %#ok<STREMP>
                key = 'DPARSF_ScrubbingSetting_gui'; return;
            end
            if ~isempty(strfind(nmLower, 'thresholing quality')) %#ok<STREMP>
                key = 'ReorientThreQC'; return;
            end
            if ~isempty(fig) && isscalar(fig) && isvalid(fig)
                if ~isempty(findobj(fig, 'Tag', 'pushbuttonAAL')) || ...
                        ~isempty(findobj(fig, 'Tag', 'pushbuttonHOA'))
                    key = 'DPARSF_ROI_Template'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'Data2')) || ...
                        ~isempty(findobj(fig, 'Tag', 'If_EPIBased'))
                    key = 'DPARSF_FieldMap'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'radiobuttonFD_Power')) || ...
                        ~isempty(findobj(fig, 'Tag', 'rtnM1'))
                    key = 'DPARSF_ScrubbingSetting_gui'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'pushbuttonAdvanced')) && ...
                        ~isempty(findobj(fig, 'Tag', 'pushbuttonBasic'))
                    key = 'DPARSF_ChooseGUI'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'checkboxFun')) && ...
                        ~isempty(findobj(fig, 'Tag', 'checkboxT1'))
                    key = 'ReorientThreQC'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'WMButton')) || ...
                        ~isempty(findobj(fig, 'Tag', 'CSFButton'))
                    key = 'DPARSF_NuisanceSetting'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'pushbutton_DPARSFmain'))
                    key = 'dpabi'; return;
                end
                if ~isempty(findobj(fig, 'Tag', 'figureDPARSFMain'))
                    key = 'DPARSF'; return;
                end
            end
        end

        % ---------------- 标签表解析 ----------------

        function T = loadLabels()
            persistent cache
            if ~isempty(cache)
                T = cache;
                return;
            end
            T = mrw.NativePatch.emptyLabels();
            fp = mrw.NativePatch.labelsFile();
            if exist(fp, 'file') ~= 2
                cache = T;
                return;
            end
            fid = -1;
            try
                fid = fopen(fp, 'r', 'n', 'UTF-8');
                if fid < 0, cache = T; return; end
                first = true;
                while true
                    ln = fgetl(fid);
                    if ~ischar(ln), break; end
                    if first
                        first = false;
                        if ~isempty(ln) && double(ln(1)) == 65279
                            ln = ln(2:end);   % 去 BOM
                        end
                        continue;             % 跳过表头
                    end
                    if isempty(strtrim(ln)), continue; end
                    parts = strsplit(ln, sprintf('\t'), 'CollapseDelimiters', false);
                    if numel(parts) < 5, continue; end
                    while numel(parts) < 6, parts{end+1} = ''; end %#ok<AGROW>
                    e = struct('Figure', strtrim(parts{1}), 'Tag', strtrim(parts{2}), ...
                        'Style', lower(strtrim(parts{3})), 'English', strtrim(parts{4}), ...
                        'Chinese', strtrim(parts{5}), 'GlossaryKey', strtrim(parts{6}));
                    T(end+1) = e; %#ok<AGROW>
                end
            catch
                % 解析失败：返回已读到的部分（不抛异常）
            end
            try
                if fid > 0, fclose(fid); end
            catch
            end
            cache = T;
        end

        function T = emptyLabels()
            T = struct('Figure', {}, 'Tag', {}, 'Style', {}, 'English', {}, ...
                'Chinese', {}, 'GlossaryKey', {});
        end

        function fp = labelsFile()
            here = fileparts(mfilename('fullpath'));   % .../+mrw
            root = fileparts(here);                    % .../MRI_Workbench
            fp = fullfile(root, 'resources', 'native_labels.tsv');
        end

        function idx = figureIndex(key)
            % 每图索引：Tag -> 行号；(Style|English) -> 行号（兜底匹配用）
            persistent cache
            if isempty(cache)
                cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            end
            if isKey(cache, key)
                idx = cache(key);
                return;
            end
            T = mrw.NativePatch.loadLabels();
            rows = T(strcmp({T.Figure}, key));
            tagMap = containers.Map('KeyType', 'char', 'ValueType', 'double');
            enMap = containers.Map('KeyType', 'char', 'ValueType', 'double');
            for k = 1:numel(rows)
                tg = rows(k).Tag;
                if isempty(tg), continue; end
                if ~isKey(tagMap, tg)
                    tagMap(tg) = k;
                end
                if ~isempty(rows(k).English)
                    mk = [rows(k).Style '|' upper(rows(k).English)];
                    if ~isKey(enMap, mk)
                        enMap(mk) = k;
                    end
                end
            end
            idx = struct('Rows', rows, 'TagMap', tagMap, 'EnMap', enMap);
            cache(key) = idx;
        end

        % ---------------- 单控件处理 ----------------

        function [rec, s] = patchOne(h, idx, rec, s)
            typ = char(mrw.NativePatch.safeGet(h, 'Type', ''));
            isPanel = any(strcmp(typ, {'uipanel', 'uibuttongroup'}));
            if isPanel
                style = 'panel';
                prop = 'Title';
                cur = mrw.NativePatch.safeGet(h, prop, '');
            else
                style = lower(char(mrw.NativePatch.safeGet(h, 'Style', '')));
                prop = 'String';
                cur = mrw.NativePatch.safeGet(h, prop, '');
            end

            % ---- 1) 找标签行（先按 Tag，再按 Style+English 兜底）
            entry = [];
            if any(strcmp(typ, {'uicontrol', 'uipanel', 'uibuttongroup'}))
                tg = char(mrw.NativePatch.safeGet(h, 'Tag', ''));
                if ~isempty(tg) && isKey(idx.TagMap, tg)
                    cand = idx.Rows(idx.TagMap(tg));
                    if mrw.NativePatch.styleCompatible(cand.Style, style)
                        entry = cand;
                        s.Matched = s.Matched + 1;
                    end
                end
                if isempty(entry) && ischar(cur) && ~isempty(strtrim(cur))
                    entry = mrw.NativePatch.lookupEnglish(idx, style, cur);
                    if ~isempty(entry), s.Matched = s.Matched + 1; end
                end
            end

            recIdx = mrw.NativePatch.findItem(rec, h);

            % ---- 2) 翻译 String / Title
            if ~isempty(entry) && mrw.NativePatch.styleTranslatable(style) && ...
                    ~isempty(entry.Chinese) && ~strcmp(entry.Chinese, entry.English)
                if ischar(cur)
                    if strcmp(cur, entry.Chinese)
                        s.AlreadyPatched = s.AlreadyPatched + 1;
                    elseif mrw.NativePatch.sameText(cur, entry.English)
                        if mrw.NativePatch.setPropValue(h, prop, entry.Chinese)
                            rec = mrw.NativePatch.recordString(rec, recIdx, h, prop, cur);
                            s.Translated = s.Translated + 1;
                        end
                    else
                        % 标签可能被 DPABI 动态改写：只按“当前文字”再查一次，认不出就不动
                        e2 = mrw.NativePatch.lookupEnglish(idx, style, cur);
                        if ~isempty(e2) && ~isempty(e2.Chinese) && ...
                                ~strcmp(e2.Chinese, e2.English) && ...
                                mrw.NativePatch.sameText(cur, e2.English)
                            if mrw.NativePatch.setPropValue(h, prop, e2.Chinese)
                                rec = mrw.NativePatch.recordString(rec, recIdx, h, prop, cur);
                                s.Translated = s.Translated + 1;
                            end
                        else
                            s.Skipped = s.Skipped + 1;
                        end
                    end
                else
                    s.Skipped = s.Skipped + 1;   % cell/多行：不翻译
                end
            end

            % ---- 3) Tooltip（所有可读控件，含 popupmenu / edit / listbox）
            recIdx = mrw.NativePatch.findItem(rec, h);
            tip = mrw.NativePatch.desiredTip(entry, style, cur);
            if ~isempty(tip)
                curTip = mrw.NativePatch.getTipRaw(h);
                skip = false;
                if recIdx > 0
                    it = rec.Items{recIdx};
                    if isfield(it, 'TipChanged') && it.TipChanged && ...
                            isfield(it, 'TipNew') && strcmp(curTip, it.TipNew)
                        skip = true;   % 已设置且未被外部改动
                    end
                end
                if ~skip
                    origTip = curTip;
                    if recIdx > 0 && rec.Items{recIdx}.TipChanged
                        origTip = rec.Items{recIdx}.OrigTip;
                    end
                    fullTip = tip;
                    if ~isempty(strtrim(origTip)) && ~strcmp(origTip, tip)
                        fullTip = sprintf('%s\n\n原始英文提示：%s', tip, origTip);
                    end
                    if numel(fullTip) > 700
                        fullTip = [fullTip(1:700) '…'];
                    end
                    if ~strcmp(curTip, fullTip) && mrw.NativePatch.setTipRaw(h, fullTip)
                        rec = mrw.NativePatch.recordTip(rec, recIdx, h, origTip, fullTip);
                        s.Tooltips = s.Tooltips + 1;
                    end
                end
            elseif isempty(entry) && ischar(cur) && ~isempty(strtrim(cur)) && ...
                    mrw.NativePatch.styleTranslatable(style)
                % 未匹配到标签行：仍按“英文原文”查术语库，查到就给 Tooltip
                tip2 = mrw.NativePatch.glossaryTip(mrw.NativePatch.cleanEnglish(cur));
                if ~isempty(tip2)
                    curTip = mrw.NativePatch.getTipRaw(h);
                    if ~strcmp(curTip, tip2)
                        origTip = curTip;
                        if recIdx > 0 && rec.Items{recIdx}.TipChanged
                            origTip = rec.Items{recIdx}.OrigTip;
                        end
                        if mrw.NativePatch.setTipRaw(h, tip2)
                            rec = mrw.NativePatch.recordTip(rec, recIdx, h, origTip, tip2);
                            s.Tooltips = s.Tooltips + 1;
                        end
                    end
                end
            end
        end

        function tf = styleCompatible(rowStyle, actualStyle)
            rs = lower(char(rowStyle));
            if strcmp(rs, 'panel')
                tf = any(strcmp(actualStyle, {'panel', 'uipanel', 'uibuttongroup'}));
                return;
            end
            tf = strcmp(rs, actualStyle);
        end

        function tf = styleTranslatable(style)
            tf = any(strcmp(style, {'text', 'pushbutton', 'checkbox', ...
                'radiobutton', 'togglebutton', 'panel'}));
        end

        function tf = sameText(a, b)
            % 宽松相等：完全一致或仅首尾空白不同
            tf = false;
            if ~ischar(a) || ~ischar(b), return; end
            tf = strcmp(a, b) || strcmp(strtrim(a), strtrim(b));
        end

        function e = lookupEnglish(idx, style, cur)
            e = [];
            if ~ischar(cur) || isempty(cur), return; end
            mk = [style '|' upper(strtrim(cur))];
            if isKey(idx.EnMap, mk)
                e = idx.Rows(idx.EnMap(mk));
            end
        end

        function tip = desiredTip(entry, style, cur)
            % 生成期望的 Tooltip：术语库 > 术语库英文别名 > “中文（English）”简版
            tip = '';
            if ~isempty(entry)
                if ~isempty(entry.GlossaryKey)
                    tip = mrw.NativePatch.glossaryTip(entry.GlossaryKey);
                end
                if isempty(tip) && ~isempty(entry.English)
                    tip = mrw.NativePatch.glossaryTip(mrw.NativePatch.cleanEnglish(entry.English));
                end
                if isempty(tip) && ~isempty(entry.Chinese) && ...
                        ~strcmp(entry.Chinese, entry.English)
                    if isempty(entry.English)
                        tip = entry.Chinese;
                    else
                        tip = sprintf('%s（%s）', entry.Chinese, entry.English);
                    end
                end
            end
            if isempty(tip) && ischar(cur) && ~isempty(strtrim(cur)) && ...
                    mrw.NativePatch.styleTranslatable(style)
                tip = mrw.NativePatch.glossaryTip(mrw.NativePatch.cleanEnglish(cur));
            end
            if ~ischar(tip), tip = ''; end
        end

        function key = cleanEnglish(txt)
            % "TR (s):" -> "TR"；"Reorient T1*" -> "Reorient T1"
            key = '';
            if ~ischar(txt), return; end
            key = strtrim(txt);
            if isempty(key), return; end
            key = regexprep(key, '\s*[：:]\s*$', '');
            key = regexprep(key, '\s*\*+\s*$', '');
            key = regexprep(key, '\s*\(.*\)\s*$', '');
            key = strtrim(key);
        end

        function t = glossaryTip(key)
            t = '';
            try
                if ~isempty(key) && exist('mrw.Glossary', 'class') == 8
                    t = mrw.Glossary.tooltip(key);
                end
            catch
                t = '';
            end
            if ~ischar(t), t = ''; end
        end

        % ---------------- Tooltip / 属性读写 ----------------

        function t = getTipRaw(h)
            % 新版 uicontrol/uipanel 只有 Tooltip 属性；旧版用 TooltipString。
            t = '';
            try
                if isprop(h, 'Tooltip')
                    t = get(h, 'Tooltip');
                elseif isprop(h, 'TooltipString')
                    t = get(h, 'TooltipString');
                end
            catch
                t = '';
            end
            if ~ischar(t), t = ''; end
        end

        function ok = setTipRaw(h, txt)
            ok = false;
            if ~ischar(txt), return; end
            try
                if isprop(h, 'Tooltip')
                    set(h, 'Tooltip', txt);
                    ok = true;
                    return;
                end
            catch
            end
            try
                set(h, 'TooltipString', txt);
                ok = true;
            catch
            end
        end

        function ok = setPropValue(h, prop, val)
            ok = false;
            try
                set(h, prop, val);
                ok = true;
            catch
            end
        end

        % ---------------- 原始值记录 ----------------

        function idx = findItem(rec, h)
            idx = 0;
            if isempty(rec) || ~isstruct(rec) || ~isfield(rec, 'Items'), return; end
            items = rec.Items;
            for k = 1:numel(items)
                try
                    if isequal(items{k}.Handle, h)
                        idx = k;
                        return;
                    end
                catch
                end
            end
        end

        function rec = recordString(rec, idx, h, prop, orig)
            if idx > 0
                % 已有记录（可能只记过 Tooltip）：补上 String 原值
                it = rec.Items{idx};
                if isempty(it.Prop)
                    it.Prop = prop;
                    it.Orig = orig;
                    rec.Items{idx} = it;
                end
                return;
            end
            it = struct('Handle', h, 'Prop', prop, 'Orig', orig, ...
                'TipChanged', false, 'OrigTip', '', 'TipNew', '');
            rec.Items{end+1} = it;
        end

        function rec = recordTip(rec, idx, h, origTip, newTip)
            if idx > 0
                it = rec.Items{idx};
                if ~it.TipChanged
                    it.TipChanged = true;
                    it.OrigTip = origTip;
                    it.TipNew = newTip;
                    rec.Items{idx} = it;
                elseif ~strcmp(it.TipNew, newTip)
                    it.TipNew = newTip;   % 动态刷新提示文字，原值不变
                    rec.Items{idx} = it;
                end
                return;
            end
            it = struct('Handle', h, 'Prop', '', 'Orig', '', ...
                'TipChanged', true, 'OrigTip', origTip, 'TipNew', newTip);
            rec.Items{end+1} = it;
        end

        function rec = getRecord(fig)
            rec = [];
            try
                if isappdata(fig, 'mrwNativePatch')
                    r = getappdata(fig, 'mrwNativePatch');
                    if isstruct(r) && isfield(r, 'Items')
                        rec = r;
                    end
                end
            catch
                rec = [];
            end
        end
    end
end
