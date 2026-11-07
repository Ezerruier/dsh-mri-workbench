classdef Glossary
% Glossary  术语库：读取 resources/glossary.tsv，提供中英文/解释/悬停提示查询
%
% 数据文件列（TAB 分隔，UTF-8，首行表头）：
%   Key      Cfg 字段路径（如 SliceTiming.SliceOrder）或 term:<英文术语>
%   EN       英文术语
%   ZH       中文名
%   Tip      2~5 句中文概述（鼠标悬停显示）
%   Category 分类
%   Default  默认值说明
%   Advice   推荐设置
%   Source   来源 URL / 文档出处

    methods (Static)

        function M = load()
            persistent cache
            if ~isempty(cache)
                M = cache;
                return;
            end
            M = containers.Map('KeyType', 'char', 'ValueType', 'any');
            fp = mrw.Glossary.filePath();
            if exist(fp, 'file') ~= 2
                cache = M;
                return;
            end
            try
                txt = fileread(fp);
            catch
                cache = M;
                return;
            end
            lines = regexp(txt, '\r\n|\n|\r', 'split');
            if isempty(lines), cache = M; return; end
            if ~isempty(lines{1}) && double(lines{1}(1)) == 65279
                lines{1} = lines{1}(2:end);
            end
            for i = 2:numel(lines)
                ln = lines{i};
                if isempty(strtrim(ln)), continue; end
                parts = strsplit(ln, sprintf('\t'), 'CollapseDelimiters', false);
                if numel(parts) < 4, continue; end
                while numel(parts) < 8, parts{end+1} = ''; end %#ok<AGROW>
                e = struct('Key', strtrim(parts{1}), 'EN', strtrim(parts{2}), ...
                    'ZH', strtrim(parts{3}), 'Tip', strtrim(parts{4}), ...
                    'Category', strtrim(parts{5}), 'Default', strtrim(parts{6}), ...
                    'Advice', strtrim(parts{7}), 'Source', strtrim(parts{8}));
                if ~isempty(e.Key)
                    M(e.Key) = e;
                end
                if ~isempty(e.EN)
                    M(['EN:' upper(e.EN)]) = e;
                end
            end
            cache = M;
        end

        function e = get(key)
            M = mrw.Glossary.load();
            e = [];
            if isempty(key) || ~ischar(key), return; end
            if isKey(M, key)
                e = M(key);
                return;
            end
            if isKey(M, ['EN:' upper(key)])
                e = M(['EN:' upper(key)]);
            end
        end

        function tf = has(key)
            tf = ~isempty(mrw.Glossary.get(key));
        end

        function t = tooltip(key)
            % 生成多行悬停文本：中文名（英文）+ 概述 + 默认/建议 + 来源
            e = mrw.Glossary.get(key);
            if isempty(e)
                t = '';
                return;
            end
            title = e.ZH;
            if ~isempty(e.EN)
                title = sprintf('%s（%s）', title, e.EN);
            end
            lines = {title};
            if ~isempty(e.Tip)
                lines{end+1} = e.Tip; %#ok<AGROW>
            end
            if ~isempty(e.Default)
                lines{end+1} = ['默认：' e.Default]; %#ok<AGROW>
            end
            if ~isempty(e.Advice)
                lines{end+1} = ['建议：' e.Advice]; %#ok<AGROW>
            end
            t = mrw.UiKit.wrapTooltip(lines, 44);
            if ~isempty(t)
                maxLen = 420;
                if numel(t) > maxLen
                    t = [t(1:maxLen) '…'];
                end
            end
        end

        function t = tooltipFromEntry(entry)
            % 优先用术语库；没有则用 schema 字段信息生成基础提示
            if isfield(entry, 'GlossaryKey') && ~isempty(entry.GlossaryKey)
                t = mrw.Glossary.tooltip(entry.GlossaryKey);
                if ~isempty(t), return; end
            end
            if isfield(entry, 'Key')
                t = mrw.Glossary.tooltip(entry.Key);
                if ~isempty(t), return; end
            end
            t = sprintf('%s（%s）\n默认：%s', entry.Label, entry.EN, ...
                mrw.Glossary.valueText(entry.Default));
        end

        function s = valueText(v)
            if isempty(v)
                s = '空';
            elseif ischar(v)
                s = v;
            elseif isnumeric(v) && isscalar(v)
                s = num2str(v);
            elseif isnumeric(v)
                s = mat2str(v);
            elseif iscell(v)
                s = sprintf('%d 项', numel(v));
            else
                s = class(v);
            end
        end

        function T = search(query)
            % 按关键词检索，返回 struct array（供术语库表格显示）
            M = mrw.Glossary.load();
            keys = M.keys();
            all = struct('Key', {}, 'EN', {}, 'ZH', {}, 'Tip', {}, 'Category', {});
            seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            for i = 1:numel(keys)
                k = keys{i};
                if strncmp(k, 'EN:', 3), continue; end
                e = M(k);
                if isempty(e.Key), continue; end
                if isKey(seen, e.Key), continue; end
                seen(e.Key) = true;
                all(end+1) = struct('Key', e.Key, 'EN', e.EN, 'ZH', e.ZH, ...
                    'Tip', e.Tip, 'Category', e.Category); %#ok<AGROW>
            end
            if nargin < 1 || isempty(strtrim(query))
                T = all;
                return;
            end
            q = lower(strtrim(query));
            keep = false(1, numel(all));
            for i = 1:numel(all)
                hay = lower([all(i).Key ' ' all(i).EN ' ' all(i).ZH ' ' all(i).Tip ' ' all(i).Category]);
                keep(i) = ~isempty(strfind(hay, q)); %#ok<STREMP>
            end
            T = all(keep);
        end

        function n = count()
            n = numel(mrw.Glossary.search(''));
        end

        function p = filePath()
            here = fileparts(mfilename('fullpath'));      % .../+mrw
            root = fileparts(here);                        % .../MRI_Workbench
            p = fullfile(root, 'resources', 'glossary.tsv');
        end

        function t = categoryNames()
            t = {'数据整理', '时间层与头动', '结构像处理', '标准化与平滑', ...
                '回归与滤波', '指标计算', '术语', '界面'};
        end
    end
end
