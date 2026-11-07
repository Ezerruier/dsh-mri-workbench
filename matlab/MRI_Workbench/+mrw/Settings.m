classdef Settings
% Settings  工作台本地设置（JSON 持久化到 MRI_Workbench/config/settings.json）
%
% 用法:
%   s = mrw.Settings.load();            % struct
%   v = mrw.Settings.get('DpabiRoot');  % 单值
%   mrw.Settings.set('DpabiRoot', 'D:\Software\DPABI');
%
% 默认值可被用户设置覆盖；文件损坏时自动回退默认值，不阻塞启动。

    methods (Static)

        function d = defaults()
            d = struct( ...
                'DpabiRoot',        '', ...
                'SpmRoot',          '', ...
                'LastDataRoot',     '', ...
                'LastRunRoot',      '', ...
                'AutoDetectPaths',  {{'D:\Software\DPABI', 'C:\Software\DPABI', ...
                                      'D:\Program Files\MATLAB\DPABI', 'D:\DPABI'}}, ...
                'NativePatch',      true, ...
                'ShowAdvanced',     false, ...
                'ScanMaxDepth',     6, ...
                'AllowGUI',         false, ...
                'Language',         'zh', ...
                'RecentRuns',       {{}}, ...
                'Version',          1);
        end

        function p = filePath()
            here = fileparts(mfilename('fullpath'));   % .../+mrw
            root = fileparts(here);                     % .../MRI_Workbench
            p = fullfile(root, 'config', 'settings.json');
        end

        function s = load()
            persistent cache
            if ~isempty(cache)
                s = cache;
                return;
            end
            s = mrw.Settings.defaults();
            fp = mrw.Settings.filePath();
            if exist(fp, 'file') == 2
                try
                    raw = fileread(fp);
                    u = jsondecode(raw);
                    fn = fieldnames(u);
                    for i = 1:numel(fn)
                        if isfield(s, fn{i})
                            s.(fn{i}) = u.(fn{i});
                        end
                    end
                catch
                    % 损坏的设置文件：保留默认值
                end
            end
            cache = s;
        end

        function v = get(key, defaultVal)
            s = mrw.Settings.load();
            if isfield(s, key)
                v = s.(key);
            elseif nargin >= 2
                v = defaultVal;
            else
                v = [];
            end
        end

        function set(key, val)
            s = mrw.Settings.load();
            s.(key) = val;
            mrw.Settings.commit(s);
            clear mrw.Settings
        end

        function commit(s)
            % 保存整个设置结构体（公共入口）
            mrw.Settings.saveToFile(s);
            clear mrw.Settings
        end

        function addRecentRun(runDir)
            s = mrw.Settings.load();
            r = s.RecentRuns;
            if ~iscell(r), r = {}; end
            r = [ {runDir}, r(:)' ];
            if numel(r) > 10
                r = r(1:10);
            end
            s.RecentRuns = r;
            mrw.Settings.commit(s);
        end
    end

    methods (Static, Access = private)
        function saveToFile(s)
            fp = mrw.Settings.filePath();
            d = fileparts(fp);
            if exist(d, 'dir') ~= 7
                mkdir(d);
            end
            try
                txt = jsonencode(s, 'PrettyPrint', true);
                fid = fopen(fp, 'w', 'n', 'UTF-8');
                if fid > 0
                    fwrite(fid, txt);
                    fclose(fid);
                end
            catch
            end
        end
    end
end
