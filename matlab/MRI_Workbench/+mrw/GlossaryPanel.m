classdef GlossaryPanel < handle
% GlossaryPanel  “术语库”页面：中英文对照 + 悬停解释内容检索（支持分类筛选）
%
% 数据来自 resources/glossary.tsv（由 mrw.Glossary 读取）。用户在预处理参数页
% 悬停看到的解释，都来自这里；也可以直接检索学习 DPABI 英文术语。

    properties (Access = private)
        Parent
        SearchField
        CategoryDrop
        CountLabel
        Table
        DetailArea
        SourceLabel
        Rows = struct('Key', {}, 'EN', {}, 'ZH', {}, 'Tip', {}, 'Category', {})
    end

    methods

        function obj = GlossaryPanel(parent)
            obj.Parent = parent;
            obj.buildUI();
            obj.refresh();
        end

        function refresh(obj)
            query = '';
            if ~isempty(obj.SearchField) && ischar(obj.SearchField.Value)
                query = obj.SearchField.Value;
            end
            cat = '全部';
            if ~isempty(obj.CategoryDrop) && ischar(obj.CategoryDrop.Value)
                cat = obj.CategoryDrop.Value;
            end
            rows = mrw.Glossary.search(query);
            if ~strcmp(cat, '全部') && ~isempty(rows)
                rows = rows(strcmp({rows.Category}, cat));
            end
            obj.Rows = rows;
            n = numel(rows);
            obj.CountLabel.Text = sprintf('共 %d 条', n);
            if n == 0
                obj.Table.Data = cell(1, 4);
                obj.DetailArea.Value = {'没有匹配的术语。试试输入英文或中文关键词，例如 realign / 头动 / DARTEL / 滤波。'};
                return;
            end
            data = cell(n, 4);
            for i = 1:n
                data{i,1} = rows(i).Category;
                data{i,2} = rows(i).ZH;
                data{i,3} = rows(i).EN;
                data{i,4} = rows(i).Key;
            end
            obj.Table.Data = data;
            try
                obj.Table.ColumnWidth = {90, 170, 230, '1x'};
            catch
            end
            % 默认显示第一条
            obj.showDetail(1);
        end
    end

    methods (Access = private)

        function buildUI(obj)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            g = uigridlayout(obj.Parent, [2 1]);
            g.RowHeight = {'fit', '1x'};
            g.Padding = [12 12 12 12];
            g.RowSpacing = 10;
            g.BackgroundColor = c.bg;

            % 搜索卡
            p1 = mrw.UiKit.card(g, '术语检索（中英文对照 + 解释）');
            gl1 = uigridlayout(p1, [1 6]);
            gl1.ColumnWidth = {'fit', 320, 130, 'fit', 120, '1x'};
            gl1.Padding = [10 8 10 8];
            gl1.BackgroundColor = c.panel;
            uilabel(gl1, 'Text', '关键词：', 'FontName', f.name);
            obj.SearchField = uieditfield(gl1, 'text', 'Placeholder', '例如 realign、头动、filter、ALFF', ...
                'FontName', f.name, 'ValueChangedFcn', @(s, e) obj.refresh());
            uilabel(gl1, 'Text', '分类：', 'FontName', f.name);
            cats = ['全部', mrw.Glossary.categoryNames()];
            obj.CategoryDrop = uidropdown(gl1, 'Items', cats, 'Value', '全部', ...
                'FontName', f.name, 'ValueChangedFcn', @(s, e) obj.refresh());
            uibutton(gl1, 'Text', '搜索', 'FontName', f.name, ...
                'ButtonPushedFcn', @(s, e) obj.refresh());
            obj.CountLabel = uilabel(gl1, 'Text', '共 0 条', 'FontName', f.name, ...
                'FontColor', c.muted, 'HorizontalAlignment', 'right');

            % 表格 + 详情
            p2 = mrw.UiKit.card(g, '结果');
            gl2 = uigridlayout(p2, [1 2]);
            gl2.ColumnWidth = {'1.35x', '1x'};
            gl2.Padding = [10 8 10 8];
            gl2.BackgroundColor = c.panel;
            obj.Table = uitable(gl2, 'Data', cell(1,4), ...
                'ColumnName', {'分类', '中文', 'English', '字段 Key'}, ...
                'ColumnWidth', {88, 170, 220, 265}, ...
                'FontName', f.name, 'FontSize', f.small, ...
                'RowName', {}, 'CellSelectionCallback', @(s, e) obj.onSelect(e));
            obj.Table.Layout.Column = 1;
            dp = uipanel(gl2, 'Title', '术语解释（与参数悬停内容一致）', ...
                'FontName', f.name, 'FontSize', f.base, 'BackgroundColor', c.panelAlt);
            dp.Layout.Column = 2;
            dg = uigridlayout(dp, [2 1]);
            dg.RowHeight = {'1x', 'fit'};
            dg.Padding = [8 8 8 8];
            dg.BackgroundColor = c.panelAlt;
            obj.DetailArea = uitextarea(dg, 'Editable', 'off', 'FontName', f.name, ...
                'FontSize', f.base, 'BackgroundColor', c.panelAlt, 'Value', {''});
            obj.SourceLabel = uilabel(dg, 'Text', '', 'FontName', f.name, ...
                'FontSize', f.small, 'FontColor', c.muted, ...
                'VerticalAlignment', 'top');
            try, obj.SourceLabel.WordWrap = 'on'; catch, end
        end

        function onSelect(obj, e)
            if isempty(e.Indices), return; end
            row = e.Indices(1, 1);
            obj.showDetail(row);
        end

        function showDetail(obj, row)
            if row < 1 || row > numel(obj.Rows)
                return;
            end
            r = obj.Rows(row);
            e = mrw.Glossary.get(r.Key);
            lines = {};
            lines{end+1} = sprintf('%s（%s）', r.ZH, r.EN); %#ok<AGROW>
            lines{end+1} = ''; %#ok<AGROW>
            if ~isempty(e)
                lines{end+1} = e.Tip; %#ok<AGROW>
                lines{end+1} = ''; %#ok<AGROW>
                if ~isempty(e.Default), lines{end+1} = ['默认值：' e.Default]; end %#ok<AGROW>
                if ~isempty(e.Advice),  lines{end+1} = ['推荐：' e.Advice]; end %#ok<AGROW>
                lines{end+1} = ''; %#ok<AGROW>
                lines{end+1} = ['字段 Key：' r.Key]; %#ok<AGROW>
                lines{end+1} = ['分类：' r.Category]; %#ok<AGROW>
                obj.SourceLabel.Text = ['来源：' e.Source];
            else
                lines{end+1} = r.Tip; %#ok<AGROW>
                obj.SourceLabel.Text = [];
            end
            obj.DetailArea.Value = lines;
        end
    end
end
