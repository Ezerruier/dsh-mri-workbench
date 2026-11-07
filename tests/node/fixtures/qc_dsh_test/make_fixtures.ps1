# Generate dsh-mri-workbench manual-QC self-test fixtures.
#   run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\node\fixtures\qc_dsh_test\make_fixtures.ps1
# (regeneration reference only; the generated sample*/ dirs are committed as static fixtures
#  and CI never runs this script)
# This script is ASCII-only on purpose (Windows PowerShell 5.1 would mis-decode
# non-ASCII source without a BOM); all Chinese content lives in fixtures.json (UTF-8).
# Output:
#   sample/  5 subjects; T1 QC = UTF-8 BOM + CRLF; Fun QC = GBK (DPARSF on zh-CN Windows);
#            NormalizationQC.tsv header only; HeadMotion.tsv in DPARSF 21-column format
#   sample2/ sample + QC/ManualQC_thresholds.json (T1Min=4, MaxMeanFD=0.3, UseMeanFD=true)
#   sample3/ only FunRaw/Sub01 (missing QC/ and RealignParameter/)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }

$dataPath = Join-Path $here 'fixtures.json'
$data = [System.IO.File]::ReadAllText($dataPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
$gbk = [System.Text.Encoding]::GetEncoding(936)

function New-Dir([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Write-Text([string]$path, [string]$text, $encoding) {
    $dir = Split-Path -Parent $path
    if ($dir) { New-Dir $dir }
    [System.IO.File]::WriteAllText($path, $text, $encoding)
}

function Resolve-Encoding([string]$name) {
    switch ($name) {
        'utf8bom' { return $utf8Bom }
        'gbk' { return $gbk }
        default { return $utf8 }
    }
}

$samples = @(
    (Join-Path $here 'sample'),
    (Join-Path $here 'sample2'),
    (Join-Path $here 'sample3')
)
foreach ($sample in $samples) {
    if (Test-Path -LiteralPath $sample) { Remove-Item -LiteralPath $sample -Recurse -Force }
}

# ---------------------------------------------------------------- sample/
$base = Join-Path $here 'sample'
foreach ($id in $data.subjectIDs) {
    New-Dir (Join-Path $base "FunRaw\$id")
    New-Dir (Join-Path $base "T1Raw\$id")
    New-Dir (Join-Path $base "RealignParameter\$id")
}

foreach ($property in $data.qcFiles.PSObject.Properties) {
    $spec = $property.Value
    $text = (($spec.lines -join $spec.eol) + $spec.eol)
    $target = Join-Path $base ($spec.relativePath -replace '/', '\')
    Write-Text $target $text (Resolve-Encoding $spec.encoding)
}

$hm = $data.headMotion
$hmLines = @($hm.header -join "`t")
foreach ($row in $hm.rows) {
    $cells = @($row.id) + (@('1.000000e+00') * 19) + @($row.meanFD)
    $hmLines += ($cells -join "`t")
}
$hmText = (($hmLines -join "`r`n") + "`r`n")
Write-Text (Join-Path $base 'RealignParameter\HeadMotion.tsv') $hmText $utf8

# --------------------------------------------------------------- sample2/
$base2 = Join-Path $here 'sample2'
Copy-Item -LiteralPath $base -Destination $base2 -Recurse
Write-Text (Join-Path $base2 'QC\ManualQC_thresholds.json') $data.thresholdsJson $utf8

# --------------------------------------------------------------- sample3/
$base3 = Join-Path $here 'sample3'
foreach ($relative in $data.sample3SubjectDirs) {
    New-Dir (Join-Path $base3 ($relative -replace '/', '\'))
}

Write-Host ("Fixtures generated: " + $base + " ; " + $base2 + " ; " + $base3)
