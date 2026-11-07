function app = StartWorkbench(varargin)
% StartWorkbench  启动静息态 MRI 分析工作台
%
% 用法:
%   StartWorkbench            % 启动界面（保持打开）
%   app = StartWorkbench;     % 返回 App 句柄（便于脚本控制/测试）
%
% 说明:
%   - 自动把 MRI_Workbench 加入 MATLAB 路径；
%   - 自动定位 DPABI/SPM12（若不在路径中会尝试 addpath）；
%   - 工作台通过独立 MATLAB 进程调用官方 DPARSFA_run 引擎执行预处理。

here = fileparts(mfilename('fullpath'));
addpath(here);
try
    mrw.Dpabi.ensurePath();
catch
end
try
    mrw.Settings.load();
catch
end

app = mrw.WorkbenchApp();
if nargout == 0
    % 无输出参数时，把 App 引用挂到图窗 appdata，避免被回收
    try
        setappdata(app.Fig, 'MRW_WorkbenchApp', app);
    catch
    end
    clear app;
else
    try
        setappdata(app.Fig, 'MRW_WorkbenchApp', app);
    catch
    end
end
end
