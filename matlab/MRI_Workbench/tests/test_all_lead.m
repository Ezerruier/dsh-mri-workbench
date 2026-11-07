function test_all_lead
% 全模块验收：依次运行各队友/Lead 的测试脚本，输出汇总
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
addpath(here);
outFile = fullfile(here, 'out_all.txt');
fid = fopen(outFile, 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});

tests = { ...
    'test_scan_engine',      '数据扫描引擎（NiftiHeader/ScanEngine）'; ...
    'test_native_patch',     '原生 DPABI 界面汉化（NativePatch）'; ...
    'test_preprocess_panel', '预处理参数面板（PreprocessPanel）'; ...
    'test_qc_model',         '人工 QC 数据模型（QcModel/TSV/轮廓/FD）'; ...
    'test_qc_view',          'QC 显示几何引擎（QcView 三正交/AC-PC/montage）'; ...
    'test_qc_panel',         '可缩放人工 QC 面板 v2（三正交/校准/FD/截图）'; ...
    'test_core_lead',        '核心模块（CfgSchema/CfgBuilder/Dpabi/Glossary）'; ...
    'test_runner_lead',      '后台运行器（Runner + 真实 DPARSFA_run）'; ...
    'test_app_lead',         '主界面（WorkbenchApp 6 页面截图）'; ...
    'test_qc_ui_v2_accept',  'QC UI v2 Lead 独立验收（跨模块/状态 JSON/截图）'; ...
    };
results = struct('Name', {}, 'OK', {}, 'Seconds', {}, 'Error', {});
say('================ 全模块验收开始 ================');
for i = 1:size(tests, 1)
    nm = tests{i,1};
    desc = tests{i,2};
    say('');
    say('>>> [%d/%d] %s —— %s', i, size(tests,1), nm, desc);
    t0 = tic;
    ok = true; errMsg = '';
    try
        feval(nm);
    catch err
        ok = false;
        errMsg = err.message;
        say('    异常：%s', err.message);
        for k = 1:min(numel(err.stack), 6)
            say('      at %s line %d', err.stack(k).name, err.stack(k).line);
        end
    end
    sec = toc(t0);
    % 让测试留下的图窗/计时器不影响后续
    try
        close all force;
        drawnow;
    catch
    end
    results(end+1) = struct('Name', nm, 'OK', ok, 'Seconds', sec, 'Error', errMsg); %#ok<AGROW>
    say('<<< %s 用时 %.1f 秒，%s', nm, sec, ternary(ok, 'PASS', 'FAIL'));
end

say('');
say('================ 汇总 ================');
pass = 0;
for i = 1:numel(results)
    r = results(i);
    say('%-28s %-4s %7.1f 秒  %s', r.Name, ternary(r.OK, 'PASS', 'FAIL'), r.Seconds, r.Error);
    if r.OK, pass = pass + 1; end
end
say('总计：%d/%d 通过', pass, numel(results));
if pass == numel(results)
    say('ALL_TESTS_PASS');
else
    say('SOME_TESTS_FAILED');
end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end

function r = ternary(cond, a, b)
if cond, r = a; else, r = b; end
end
