classdef UiKit
% UiKit  工作台 UI 基础组件与主题（uifigure / App Designer 风格）
%
% 用法：
%   c = mrw.UiKit.colors();  f = mrw.UiKit.fonts();
%   fig = mrw.UiKit.newFigure('静息态 MRI 分析工作台', [1440 900]);
%   p = mrw.UiKit.card(parent, '数据索引');
%   mrw.UiKit.tip(ctrl, '鼠标悬停说明文本');
%
% 约定：所有控件均使用 uifigure 体系（uigridlayout / uipanel / uibutton / ...），
% 字体统一为微软雅黑，避免中文显示问题。

    methods (Static)

        function c = colors()
            c = struct( ...
                'bg',        [0.965 0.969 0.976], ...
                'panel',     [1.000 1.000 1.000], ...
                'panelAlt',  [0.949 0.953 0.965], ...
                'header',    [0.145 0.239 0.369], ...
                'header2',   [0.192 0.325 0.478], ...
                'accent',    [0.129 0.400 0.674], ...
                'accentDark',[0.071 0.267 0.478], ...
                'text',      [0.110 0.122 0.141], ...
                'muted',     [0.420 0.447 0.502], ...
                'border',    [0.839 0.855 0.878], ...
                'ok',        [0.086 0.639 0.290], ...
                'warn',      [0.851 0.596 0.055], ...
                'err',       [0.812 0.184 0.153], ...
                'okBg',      [0.878 0.949 0.902], ...
                'warnBg',    [0.992 0.941 0.804], ...
                'errBg',     [0.973 0.878 0.871], ...
                'accentBg',  [0.890 0.929 0.969]);
        end

        function f = fonts()
            f = struct('name', '微软雅黑', 'mono', 'Consolas', ...
                'small', 11, 'base', 12, 'medium', 13, 'large', 15, 'title', 18);
        end

        function g = glyphs()
            g = struct('scan', char(8635), 'ok', char(10003), 'warn', char(9888), ...
                'err', char(10005), 'run', char(9654), 'stop', char(9632), ...
                'folder', char(128193), 'save', char(128190), 'info', char(9432), ...
                'back', char(8592), 'next', char(8594), 'refresh', char(8635), ...
                'brain', char(129504), 'gear', char(9881), 'help', char(10067));
        end

        function fig = newFigure(titleText, size, varargin)
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            p = inputParser;
            addParameter(p, 'Position', [80 60 size(1) size(2)], @(x) isnumeric(x) && numel(x) == 4);
            parse(p, varargin{:});
            fig = uifigure('Name', titleText, 'Position', p.Results.Position, ...
                'Color', c.bg, 'Visible', 'on');
            try
                fig.Theme = 'light';
            catch
            end
            try
                fig.FontName = f.name;
                fig.FontSize = f.base;
            catch
            end
            try
                movegui(fig, 'center');
            catch
            end
        end

        function p = card(parent, titleText, varargin)
            % 白色卡片式 uipanel（父容器可为 uigridlayout 或 uipanel）
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            p = uipanel(parent, 'Title', titleText, 'FontName', f.name, ...
                'FontSize', f.medium, 'FontWeight', 'bold', ...
                'BackgroundColor', c.panel, 'ForegroundColor', c.text, ...
                'BorderType', 'line', 'HighlightColor', c.border);
            if ~isempty(varargin)
                set(p, varargin{:});
            end
        end

        function g = grid(parent, rows, cols, varargin)
            c = mrw.UiKit.colors();
            g = uigridlayout(parent, [rows cols]);
            g.RowSpacing = 8;
            g.ColumnSpacing = 10;
            g.Padding = [10 10 10 10];
            g.BackgroundColor = c.panel;
            % 注意：uigridlayout 没有 FontName/FontSize 属性（R2026a），字体请设在子控件上
            if ~isempty(varargin)
                set(g, varargin{:});
            end
        end

        function t = tip(comp, text)
            % 给控件设置悬停提示（支持多行）
            if isempty(text), return; end
            try
                comp.Tooltip = text;
            catch
                try
                    set(comp, 'TooltipString', text);
                catch
                end
            end
            if nargout > 0, t = comp; end
        end

        function h = heading(parent, text, varargin)
            f = mrw.UiKit.fonts();
            c = mrw.UiKit.colors();
            h = uilabel(parent, 'Text', text, 'FontName', f.name, ...
                'FontSize', f.large, 'FontWeight', 'bold', 'FontColor', c.text);
            if ~isempty(varargin), set(h, varargin{:}); end
        end

        function h = subHeading(parent, text, varargin)
            f = mrw.UiKit.fonts();
            c = mrw.UiKit.colors();
            h = uilabel(parent, 'Text', text, 'FontName', f.name, ...
                'FontSize', f.medium, 'FontWeight', 'bold', 'FontColor', c.accentDark);
            if ~isempty(varargin), set(h, varargin{:}); end
        end

        function l = text(parent, text, varargin)
            f = mrw.UiKit.fonts();
            c = mrw.UiKit.colors();
            l = uilabel(parent, 'Text', text, 'FontName', f.name, ...
                'FontSize', f.base, 'FontColor', c.text);
            if ~isempty(varargin), set(l, varargin{:}); end
        end

        function b = badge(parent, text, kind)
            % kind: 'ok' | 'warn' | 'err' | 'info' | 'plain'
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            switch kind
                case 'ok',    bg = c.okBg;    fg = c.ok;
                case 'warn',  bg = c.warnBg;  fg = [0.58 0.38 0.0];
                case 'err',   bg = c.errBg;   fg = c.err;
                case 'info',  bg = c.accentBg; fg = c.accentDark;
                otherwise,    bg = c.panelAlt; fg = c.muted;
            end
            b = uilabel(parent, 'Text', text, 'FontName', f.name, 'FontSize', f.small, ...
                'FontColor', fg, 'BackgroundColor', bg, ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'center');
            try
                b.Padding = [8 2 8 2];
            catch
            end
        end

        function b = button(parent, text, varargin)
            % 标准按钮；kind: 'primary' | 'normal' | 'danger'
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            p = inputParser;
            addParameter(p, 'kind', 'normal');
            addParameter(p, 'Icon', '');
            addParameter(p, 'Callback', []);
            parse(p, varargin{:});
            switch p.Results.kind
                case 'primary'
                    bg = c.accent; fg = [1 1 1]; bold = 'bold';
                case 'danger'
                    bg = c.err; fg = [1 1 1]; bold = 'bold';
                otherwise
                    bg = [1 1 1]; fg = c.text; bold = 'normal';
            end
            b = uibutton(parent, 'Text', text, 'FontName', f.name, ...
                'FontSize', f.base, 'FontWeight', bold, ...
                'BackgroundColor', bg, 'FontColor', fg, ...
                'ButtonPushedFcn', p.Results.Callback);
            if ~isempty(p.Results.Icon)
                try
                    b.Icon = p.Results.Icon;
                catch
                end
            end
        end

        function l = fieldLabel(parent, text, required)
            % 参数表单左侧标签
            c = mrw.UiKit.colors();
            f = mrw.UiKit.fonts();
            t = text;
            if nargin >= 3 && required
                t = [text ' *'];
            end
            l = uilabel(parent, 'Text', t, 'FontName', f.name, ...
                'FontSize', f.base, 'FontColor', c.text, ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'center');
            if nargin >= 3 && required
                % 必填项用强调色
                l.FontColor = c.accentDark;
            end
        end

        function s = fmtSeconds(sec)
            if ~isfinite(sec), s = '--'; return; end
            if sec < 60
                s = sprintf('%.1f 秒', sec);
            elseif sec < 3600
                s = sprintf('%d 分 %02d 秒', floor(sec/60), round(mod(sec, 60)));
            else
                s = sprintf('%d 时 %02d 分', floor(sec/3600), round(mod(sec, 3600)/60));
            end
        end

        function s = fmtCount(n)
            if ~isfinite(n), s = '--'; return; end
            if n >= 10000
                s = sprintf('%.1f 万', n/10000);
            else
                s = sprintf('%d', round(n));
            end
        end

        function s = wrapTooltip(lines, maxWidth)
            % 把多行文本按最大宽度折行（MATLAB tooltip 换行）
            if nargin < 2, maxWidth = 46; end
            out = {};
            for i = 1:numel(lines)
                ln = lines{i};
                while numel(ln) > maxWidth
                    cut = maxWidth;
                    % 尽量在标点/空格处断行
                    seg = ln(1:cut);
                    p = find(ismember(seg, ['，。；、 ' ' ']), 1, 'last');
                    if ~isempty(p) && p > maxWidth*0.45
                        cut = p;
                    end
                    out{end+1} = strtrim(ln(1:cut)); %#ok<AGROW>
                    ln = strtrim(ln(cut+1:end));
                end
                out{end+1} = ln; %#ok<AGROW>
            end
            s = strjoin(out, sprintf('\n'));
        end
    end
end
