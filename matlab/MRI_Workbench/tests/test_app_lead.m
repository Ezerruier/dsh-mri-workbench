function test_app_lead
% 工作台 UI 冒烟测试：在 -batch 下创建主窗口、切换页面、导出截图
here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
outDir = fullfile(here, 'out_app');
if exist(outDir, 'dir') ~= 7, mkdir(outDir); end
fid = fopen(fullfile(outDir, 'log.txt'), 'w', 'n', 'UTF-8');
say = @(fmt, varargin) local_say(fid, fmt, varargin{:});

app = [];
try
    say('构造 WorkbenchApp…');
    t0 = tic;
    app = mrw.WorkbenchApp();
    drawnow;
    pause(1.0);
    drawnow;
    say('构造完成，用时 %.1f 秒', toc(t0));
    say('页面数量: %d', numel(app.Pages));
    say('PreprocessPanel 可用: %d', ~isempty(app.PrepPanel));
    say('ScanEngine 类存在: %d', exist('mrw.ScanEngine', 'class') == 8);
    say('Glossary 条数: %d', mrw.Glossary.count());

    % 页面截图
    items = app.NavList.Items;
    names = {'page1_data', 'page2_prep', 'page3_run', 'page4_glossary', 'page5_settings', 'page6_qc'};
    for i = 1:numel(items)
        app.showPage(i);
        drawnow;
        pause(0.4);
        drawnow;
        fn = fullfile(outDir, [names{i} '.png']);
        ok = false;
        try
            exportapp(app.Fig, fn);
            ok = true;
        catch
            try
                print(app.Fig, fn, '-dpng', '-r100');
                ok = true;
            catch
            end
        end
        say('截图 %s: ok=%d, exists=%d', names{i}, ok, exist(fn, 'file') == 2);
    end

    % 关闭窗口（不应报错）
    delete(app.Fig);
    say('DONE');
catch err
    say('EXCEPTION: %s', err.message);
    for k = 1:min(numel(err.stack), 10)
        say('  at %s line %d', err.stack(k).name, err.stack(k).line);
    end
    try
        if ~isempty(app) && isvalid(app.Fig)
            delete(app.Fig);
        end
    catch
    end
end
fclose(fid);
end

function local_say(fid, fmt, varargin)
    msg = sprintf(fmt, varargin{:});
    fprintf('%s\n', msg);
    fprintf(fid, '%s\n', msg);
end
