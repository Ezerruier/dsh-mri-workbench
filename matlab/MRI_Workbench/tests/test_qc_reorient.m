function test_qc_reorient
% 输出事务、原始像素保护、独立 SPM/DPABI/MATLAB 读取及格式覆盖。
    here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
    work = tempname(); mkdir(work);
    cleanup = onCleanup(@() rmdir(work, 's')); %#ok<NASGU>
    count = 0;
    D = reshape(single(1:315), [7 9 5]);
    M = diag([2 3 4 1]); M(1:3,4) = [-8; -15; -12];
    source = fullfile(work, 'original.nii');
    makeImage(source, D, M);
    hashProbe = fullfile(work, 'hash.txt');
    fid = fopen(hashProbe, 'w'); fprintf(fid, 'abc'); fclose(fid);
    check(strcmp(mrw.QcReorient.hashFile(hashProbe), ...
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'), 'SHA256 known vector');
    hashBefore = mrw.QcReorient.hashFile(source);
    info = dir(source); bytesBefore = info.bytes;
    A = diag([-1 1 -1 1]); A(1:3,4) = [8; -4; 2];
    vi = struct('DisplayMatrix', A, 'IsNative', false, 'Mode', 'native', ...
        'Manual', struct('TranslationMm', [8 -4 2], 'RotationDeg', [0 0 0]), ...
        'Flips', struct('LR', true, 'AP', false, 'IS', true));
    result = mrw.QcReorient.apply(source, work, 'Sub01', vi);
    check(strcmp(result.Method, 'header-only'), 'default header-only');
    check(strcmp(mrw.QcReorient.hashFile(source), hashBefore), 'source SHA256 unchanged');
    info = dir(source); check(info.bytes == bytesBefore, 'source size unchanged');
    check(contains(result.OutputDir, fullfile('QC', 'Reorient', 'Sub01')), 'fixed output parent');
    check(~strcmp(source, result.OutputFile) && exist(result.LogFile, 'file') == 2, 'copy and log published together');
    target = A * M;
    verifyOutput(result.OutputFile, D, target, true);
    log = jsondecode(fileread(result.LogFile));
    check(strcmp(log.SourceBefore.SHA256, log.SourceAfter.SHA256), 'log source hash before/after');
    check(strcmp(log.Verification.PixelPayloadBeforeSHA256, log.Verification.PixelPayloadAfterSHA256), 'raw pixel payload identical');
    check(strcmp(log.OutputFiles.SHA256, mrw.QcReorient.hashFile(result.OutputFile)), 'log output hash');
    again = mrw.QcReorient.apply(source, work, 'Sub01', vi);
    check(~strcmp(again.OutputDir, result.OutputDir), 'existing output gets unique batch');
    check(exist(result.OutputFile, 'file') == 2, 'existing output retained');
    reflected = vi; reflected.DisplayMatrix = diag([-1 1 1 1]);
    reflection = mrw.QcReorient.apply(source, work, 'Reflect', reflected);
    verifyOutput(reflection.OutputFile, D, reflected.DisplayMatrix * M, true);
    reflectedNifti = nifti(reflection.OutputFile);
    check(reflectedNifti.hdr.pixdim(1) == -1, 'reflection encoded with negative qfac');
    rotated = vi; rotated.DisplayMatrix = [0 -1 0 0; 1 0 0 0; 0 0 1 0; 0 0 0 1];
    rotation = mrw.QcReorient.apply(source, work, 'Rotate', rotated);
    verifyOutput(rotation.OutputFile, D, rotated.DisplayMatrix * M, true);

    fractionalView = mrw.QcView(double(D), struct('mat', M));
    fractionalView.setManual([123.45678912 -98.76543219 45.6789123], [3.25 -5.5 7.75]);
    fractionalInfo = fractionalView.getInfo();
    fractional = mrw.QcReorient.apply(source, work, 'Fractional', fractionalInfo);
    check(max(fractional.Verification.SformMaxError, fractional.Verification.QformMaxError) > 1e-6, ...
        'ordinary fractional rigid transform exceeds old coefficient threshold');
    verifyQuantized(fractional, fractionalInfo.DisplayMatrix * M, source);

    meterSource = fullfile(work, 'meter.nii'); copyfile(source, meterSource);
    meterNifti = nifti(meterSource); meterStruct = struct(meterNifti);
    meterStruct.hdr.xyzt_units = uint8(1); meterNifti = nifti(meterStruct);
    meterNifti.mat = M; meterNifti.mat0 = M; create(meterNifti);
    meterInfo = vi; meterInfo.DisplayMatrix = eye(4); meterInfo.DisplayMatrix(1,4) = 2;
    meterHash = mrw.QcReorient.hashFile(meterSource);
    meter = mrw.QcReorient.apply(meterSource, work, 'MeterUnits', meterInfo);
    verifyQuantized(meter, meterInfo.DisplayMatrix * meterNifti.mat, meterSource);
    check(strcmp(mrw.QcReorient.hashFile(meterSource), meterHash), 'meter source hash unchanged');
    check(bitand(nifti(meter.OutputFile).hdr.xyzt_units, 7) == 1, 'native meter units preserved');

    gzdir = fullfile(work, 'gzip'); mkdir(gzdir);
    zipped = gzip(source, gzdir); gzSource = zipped{1};
    gzHash = mrw.QcReorient.hashFile(gzSource);
    % 若读写器误在源目录解压，会破坏这个同名文件。
    sibling = fullfile(gzdir, 'original.nii');
    fid = fopen(sibling, 'w'); fwrite(fid, uint8([17 29 233 251]), 'uint8'); fclose(fid);
    siblingHash = mrw.QcReorient.hashFile(sibling);
    gzResult = mrw.QcReorient.apply(gzSource, work, 'SubGz', vi);
    check(endsWith(gzResult.OutputFile, '.nii.gz'), 'gzip output keeps compressed format');
    check(strcmp(mrw.QcReorient.hashFile(gzSource), gzHash), 'gzip source unchanged');
    check(strcmp(mrw.QcReorient.hashFile(sibling), siblingHash), 'gzip sibling .nii untouched');
    unpackDir = fullfile(work, 'unpack'); mkdir(unpackDir);
    unpacked = gunzip(gzResult.OutputFile, unpackDir);
    verifyOutput(unpacked{1}, D, target, true);
    gzNi = niftiinfo(gzResult.OutputFile);
    check(isequal(gzNi.ImageSize, [7 9 5]), 'MATLAB reads compressed output');

    pairFile = fullfile(work, 'pair.img'); makeImage(pairFile, D, M);
    pairHdr = fullfile(work, 'pair.hdr');
    pairHash = mrw.QcReorient.hashFile(pairFile); hdrHash = mrw.QcReorient.hashFile(pairHdr);
    pairResult = mrw.QcReorient.apply(pairHdr, work, 'SubPair', vi);
    check(endsWith(pairResult.OutputFile, '.img'), 'paired input via hdr produces paired output');
    check(exist(strrep(pairResult.OutputFile, '.img', '.hdr'), 'file') == 2, 'paired header published');
    check(strcmp(mrw.QcReorient.hashFile(pairFile), pairHash) && strcmp(mrw.QcReorient.hashFile(pairHdr), hdrHash), 'both pair sources unchanged');
    verifyOutput(pairResult.OutputFile, D, target, true);
    mat = repmat(M, [1 1 2]); mat(1:3,4,1) = [-6; -12; -4];
    sidecar = fullfile(work, 'pair.mat'); save(sidecar, 'mat');
    sidecarHash = mrw.QcReorient.hashFile(sidecar);
    sidecarResult = mrw.QcReorient.apply(pairFile, work, 'Sidecar', vi);
    verifyOutput(sidecarResult.OutputFile, D, A * mat(:,:,1), true);
    check(strcmp(mrw.QcReorient.hashFile(sidecar), sidecarHash), 'source SPM sidecar unchanged');
    check(exist(strrep(sidecarResult.OutputFile, '.img', '.mat'), 'file') ~= 2, 'new header has no stale overriding sidecar');

    missing = fullfile(work, 'missing.img'); copyfile(pairFile, missing);
    expectError(@() mrw.QcReorient.apply(missing, work, 'MissingPair', vi), 'QcReorient:Pair');
    expectError(@() mrw.QcReorient.apply(source, work, '..', vi), 'QcReorient:Subject');
    expectError(@() mrw.QcReorient.apply(source, work, 'Sub01', vi, 'unknown'), 'QcReorient:Method');
    native = vi; native.IsNative = true;
    expectError(@() mrw.QcReorient.apply(source, work, 'Sub01', native), 'QcReorient:Native');
    bad = vi; bad.DisplayMatrix(1,1) = NaN;
    expectError(@() mrw.QcReorient.apply(source, work, 'Sub01', bad), 'QcReorient:Transform');
    shear = vi; shear.DisplayMatrix = eye(4); shear.DisplayMatrix(1,2) = 0.2;
    expectError(@() mrw.QcReorient.apply(source, work, 'FailShear', shear), 'QcReorient:Shear');
    leftovers = dir(fullfile(work, 'QC', 'Reorient', 'FailShear'));
    check(all(ismember({leftovers.name}, {'.', '..'})), 'failed transaction leaves no output/stage');
    precision = vi; precision.DisplayMatrix(1,4) = 1e7 + 0.123456789;
    expectError(@() mrw.QcReorient.apply(source, work, 'FailPrecision', precision), 'QcReorient:Precision');
    leftovers = dir(fullfile(work, 'QC', 'Reorient', 'FailPrecision'));
    check(all(ismember({leftovers.name}, {'.', '..'})), 'precision failure rolls back');
    check(strcmp(mrw.QcReorient.hashFile(source), hashBefore), 'failed transactions leave source unchanged');
    f4 = fullfile(work, 'fourD.nii'); makeImage(f4, cat(4, D, D), M);
    expectError(@() mrw.QcReorient.apply(f4, work, 'FourD', vi), 'QcReorient:FourD');

    view = mrw.QcView(double(D), struct('mat', M, 'voxSize', [2 3 4]));
    view.setManual([4 -2 6], [0 0 0]);
    [resampled, resampledMat] = view.resampledVolume();
    res = mrw.QcReorient.apply(source, work, 'Resample', view.getInfo(), 'resample', ...
        struct('Data', resampled, 'Mat', resampledMat));
    check(endsWith(res.OutputFile, '_resampled.nii'), 'resampling uses distinct filename');
    verifyOutput(res.OutputFile, single(resampled), resampledMat, false);
    check(strcmp(mrw.QcReorient.hashFile(source), hashBefore), 'resampling source unchanged');
    check(~res.Verification.HeaderOnlyPixelsUnchanged, 'resampling log declares changed pixels');
    expectError(@() mrw.QcReorient.apply(source, work, 'BadResample', vi, 'resample'), 'QcReorient:Resample');

    uiWork = fullfile(work, 'ui'); mkdir(fullfile(uiWork, 'T1Img', 'SubUI'));
    uiSource = fullfile(uiWork, 'T1Img', 'SubUI', 'cT1.nii');
    makeImage(uiSource, D, M); uiHash = mrw.QcReorient.hashFile(uiSource);
    mkdir(fullfile(uiWork, 'T1Img', 'SubOther'));
    makeImage(fullfile(uiWork, 'T1Img', 'SubOther', 'cT1.nii'), D, M);
    fig = mrw.QcViewer.open(uiWork, 'T1');
    figCleanup = onCleanup(@() delete(fig)); %#ok<NASGU>
    panel = getappdata(fig, 'MRW_QcPanel');
    panel.setSubject('SubUI');
    dialog = mrw.QcAlignDialog(panel);
    dialogCleanup = onCleanup(@() dialog.close()); %#ok<NASGU>
    button = findall(dialog.Figure, 'Tag', 'qcAlignApplyData');
    check(strcmp(button.Enable, 'off'), 'native apply button disabled');
    panel.setManualOrientation([2 0 0], [0 0 0]); dialog.refresh();
    check(strcmp(button.Enable, 'on'), 'manual transform enables apply button');
    button.ButtonPushedFcn(button, []); drawnow;
    confirm = findall(groot, 'Type', 'figure', 'Name', '应用到数据 — 确认独立副本');
    check(numel(confirm) == 1, 'apply opens confirmation summary');
    checkbox = findall(confirm, 'Tag', 'qcApplyResample');
    check(~checkbox.Value, 'advanced resampling unchecked by default');
    summary = findall(confirm, 'Tag', 'qcApplySummary');
    text = strjoin(summary.Value, newline);
    check(contains(text, 'SubUI') && contains(text, '完整显示矩阵') && contains(text, '只重写 NIfTI'), 'summary identifies source/transform/default method');
    delete(confirm);
    check(exist(fullfile(uiWork, 'QC', 'Reorient'), 'dir') ~= 7, 'cancel publishes nothing');
    button.ButtonPushedFcn(button, []); drawnow;
    confirm = findall(groot, 'Type', 'figure', 'Name', '应用到数据 — 确认独立副本');
    write = findall(confirm, 'Tag', 'qcApplyConfirm');
    write.ButtonPushedFcn(write, []); drawnow;
    check(strcmp(write.Text, '写出完成') && strcmp(write.Enable, 'off'), 'explicit confirm publishes validated copy');
    check(numel(dir(fullfile(uiWork, 'QC', 'Reorient', 'SubUI', '*', 'reorient_log.json'))) == 1, 'UI writes one independent log');
    check(strcmp(mrw.QcReorient.hashFile(uiSource), uiHash), 'UI write leaves original hash unchanged');
    delete(confirm);
    button.ButtonPushedFcn(button, []); drawnow;
    confirm = findall(groot, 'Type', 'figure', 'Name', '应用到数据 — 确认独立副本');
    write = findall(confirm, 'Tag', 'qcApplyConfirm');
    panel.setManualOrientation([3 0 0], [0 0 0]);
    write.ButtonPushedFcn(write, []); drawnow;
    check(strcmp(write.Enable, 'on') && numel(dir(fullfile(uiWork, 'QC', 'Reorient', 'SubUI', '*', 'reorient_log.json'))) == 1, ...
        'stale transform confirmation rejects write');
    delete(confirm);
    button.ButtonPushedFcn(button, []); drawnow;
    confirm = findall(groot, 'Type', 'figure', 'Name', '应用到数据 — 确认独立副本');
    write = findall(confirm, 'Tag', 'qcApplyConfirm');
    panel.setSubject('SubOther'); write.ButtonPushedFcn(write, []); drawnow;
    check(strcmp(write.Enable, 'on') && exist(fullfile(uiWork, 'QC', 'Reorient', 'SubOther'), 'dir') ~= 7, ...
        'stale source confirmation rejects write');
    delete(confirm);
    panel.resetOrientation(); dialog.refresh();
    check(strcmp(button.Enable, 'off'), 'reset disables data application again');
    fprintf('TEST_QC_REORIENT_PASS assertions=%d\n', count);

    function verifyOutput(file, expected, expectedMat, unchanged)
        n = nifti(file); v = spm_vol(file);
        check(max(abs(v.mat - expectedMat), [], 'all') < 1e-6, 'SPM mat precision <1e-6');
        check(max(abs(n.mat0 - expectedMat), [], 'all') < 1e-6, 'qform precision <1e-6');
        check(max(abs(n.mat - n.mat0), [], 'all') < 1e-6, 'qform/sform consistent');
        raw = n.hdr; check(raw.qform_code == 2 && raw.sform_code == 2, 'both forms use aligned code');
        zeroBased = expectedMat * [eye(4,3) [1 1 1 1].'];
        sform = [double(raw.srow_x); double(raw.srow_y); double(raw.srow_z); 0 0 0 1];
        check(max(abs(sform - zeroBased), [], 'all') < 1e-6, 'raw sform is 0-based');
        check(isequaln(single(spm_read_vols(v)), single(expected)), 'SPM output voxel values');
        [y, h] = y_Read(file);
        check(isequaln(single(y), single(expected)) && max(abs(h.mat - expectedMat), [], 'all') < 1e-6, 'DPABI output data/geometry');
        ni = niftiinfo(file); check(isequal(ni.ImageSize, size(expected)), 'MATLAB niftiinfo output dimensions');
        check(max(abs(ni.Transform.T.' - zeroBased), [], 'all') < 1e-6, 'independent niftiinfo 0-based geometry');
        if unchanged
            original = nifti(source);
            check(isequaln(double(n.raw), double(original.raw)), 'unscaled raw array unchanged');
        end
    end

    function verifyQuantized(result, requested, originalFile)
        n = nifti(result.OutputFile); v = spm_vol(result.OutputFile);
        check(max(abs(v.mat - result.Matrix), [], 'all') < 1e-12, 'result matrix is actual written sform');
        [y, h] = y_Read(result.OutputFile);
        check(isequaln(single(spm_read_vols(v)), D) && isequaln(single(y), D), ...
            'fractional header-only preserves SPM and DPABI voxel values');
        check(max(abs(h.mat - v.mat), [], 'all') < 1e-6, 'DPABI geometry matches written header');
        ni = niftiinfo(result.OutputFile); raw = n.hdr;
        nativeZeroBased = [double(raw.srow_x); double(raw.srow_y); double(raw.srow_z); 0 0 0 1];
        check(max(abs(ni.Transform.T.' - nativeZeroBased), [], 'all') < 1e-6, ...
            'MATLAB geometry matches native-unit 0-based sform');
        check(raw.sform_code == 2 && raw.qform_code == 2, 'quantized forms retain valid aligned codes');
        [i,j,k] = ndgrid([0.5 7.5], [0.5 9.5], [0.5 5.5]);
        corners = [i(:).'; j(:).'; k(:).'; ones(1,8)];
        matrices = {v.mat-requested, n.mat0-requested, n.mat0-v.mat};
        errors = zeros(1,3);
        for q = 1:3
            displacement = matrices{q} * corners;
            errors(q) = max(sqrt(sum(displacement(1:3,:).^2, 1)));
        end
        check(all(isfinite(errors)) && all(errors <= 0.001), 'all FOV boundary corners stay within 0.001mm');
        log = jsondecode(fileread(result.LogFile)); verified = log.Verification;
        check(log.SchemaVersion == 2 && max(abs(log.RequestedOutputMatrix-requested), [], 'all') < 1e-12, ...
            'log distinguishes requested double geometry');
        check(max(abs(log.OutputMatrix-v.mat), [], 'all') < 1e-12 && ...
            max(abs(log.OutputQformMatrix-n.mat0), [], 'all') < 1e-12, 'log records both actual geometries');
        check(verified.WorldToleranceMm == 0.001 && max(abs(errors - ...
            [verified.SformWorldMaxErrorMm verified.QformWorldMaxErrorMm verified.QformSformWorldMaxErrorMm])) < 1e-12, ...
            'logged coordinate errors match independent corner calculation');
        check(verified.SformReadbackMaxError < 1e-6 && verified.QformReadbackMaxError < 1e-6 && ...
            verified.NiftiInfoMaxError < 1e-6, 'strict encoded-header readback verification retained');
        check(strcmp(verified.PixelPayloadBeforeSHA256, verified.PixelPayloadAfterSHA256), ...
            'fractional header-only payload hash unchanged');
        check(strcmp(log.SourceBefore.SHA256, log.SourceAfter.SHA256) && ...
            strcmp(log.SourceAfter.SHA256, mrw.QcReorient.hashFile(originalFile)), 'fractional source hash unchanged');
        fprintf('QUANTIZED_HEADER sform=%.9g qform=%.9g world_mm=%s\n', ...
            verified.SformMaxError, verified.QformMaxError, mat2str(errors, 9));
    end

    function check(ok, label)
        count = count + 1;
        assert(ok, 'test_qc_reorient:Failed', '%s', label);
    end

    function expectError(call, id)
        caught = false;
        try, call(); catch e, caught = strcmp(e.identifier, id); if ~caught, rethrow(e); end, end
        check(caught, ['expected error ' id]);
    end
end

function makeImage(path, data, mat)
    n = nifti(); n.dat = file_array(path, size(data), 'FLOAT32-LE', 0, 1, 0);
    n.mat = mat; n.mat0 = mat; n.mat_intent = 'Aligned'; n.mat0_intent = 'Aligned';
    create(n); n.dat(:,:,:,:) = single(data);
end
