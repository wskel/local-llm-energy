<#
.SYNOPSIS
Measures GPU power and speed while a llama.cpp server generates text and reads a long prompt.
Writes results/raw/<timestamp>.json (for Get-EnergyCost.ps1) and the raw power samples as CSV.

.DESCRIPTION
Starts its own llama-server on a random localhost port with no API key and no web UI, so nothing
is exposed and no secrets are needed. Stop any other llama-server first: two servers would share
the GPU and skew both speed and power.

Phases:
  decode_short  generate -GenerateTokens tokens from a short prompt
  prefill       read a synthetic prompt of -PromptLines lines (about 21 tokens per line)
  decode_deep   generate -DeepTokens tokens right after that prompt, i.e. at depth

.EXAMPLE
./scripts/Measure-Power.ps1 -Quick     # about 2 minutes, rough numbers
./scripts/Measure-Power.ps1            # about 6 minutes on a mid-range card
#>
param(
    [string]$Config = (Join-Path $PSScriptRoot '..\config.psd1'),
    [int]$GenerateTokens = 2500,
    [int]$PromptLines = 700,
    [int]$DeepTokens = 300,
    [switch]$Quick
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile $Config
if ($Quick) { $GenerateTokens = 400; $PromptLines = 200; $DeepTokens = 150 }
if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    throw 'Another llama-server is running. Stop it first so it does not share the GPU or skew the power readings.'
}
foreach ($f in $cfg.ServerExe, $cfg.Model) { if (-not (Test-Path $f)) { throw "Not found: $f (check config.psd1)" } }

$root = Split-Path $PSScriptRoot -Parent
$rawDir = Join-Path $root 'results\raw'
New-Item -ItemType Directory -Force $rawDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $rawDir "$stamp-power.csv"
$port = Get-Random -Minimum 20000 -Maximum 40000

switch ($cfg.PowerSource) {
    'amd-adlx' {
        $sampler = Join-Path $root 'power\amd-adlx\gpupower.exe'
        if (-not (Test-Path $sampler)) { throw 'gpupower.exe missing: run power/amd-adlx/build.ps1 first.' }
        $samplerArgs = @('0', '200', "`"$csv`"")
    }
    'nvidia-smi' {
        $sampler = 'nvidia-smi'
        $samplerArgs = @('--query-gpu=timestamp,power.draw,utilization.gpu', '--format=csv,noheader,nounits', '-lms', '200', '-f', "`"$csv`"")
    }
    default { throw "Unknown PowerSource '$($cfg.PowerSource)'" }
}

$server = Start-Process $cfg.ServerExe -PassThru -WindowStyle Hidden -ArgumentList (
    @('-m', "`"$($cfg.Model)`"") + $cfg.ServerArgs + @('--host', '127.0.0.1', '--port', $port, '--no-webui'))
$samplerProc = $null
try {
    $ok = $false
    for ($i = 0; $i -lt 300 -and -not $ok; $i++) {
        Start-Sleep 1
        if ($server.HasExited) { throw 'llama-server exited during load; run it by hand with the same flags to see why.' }
        try { $ok = (Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 2).status -eq 'ok' } catch {}
    }
    if (-not $ok) { throw 'llama-server did not become ready within 5 minutes.' }
    Start-Sleep 3

    $t0 = Get-Date
    $samplerProc = Start-Process $sampler -ArgumentList $samplerArgs -PassThru -WindowStyle Hidden
    Start-Sleep 6   # idle baseline with the model loaded

    function Invoke-Phase([string]$content, [int]$maxTokens) {
        $start = ((Get-Date) - $t0).TotalMilliseconds
        $body = @{ messages = @(@{ role = 'user'; content = $content }); max_tokens = $maxTokens
                   temperature = 0.7; reasoning_effort = 'none' } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3600
        [pscustomobject]@{ start = $start; end = ((Get-Date) - $t0).TotalMilliseconds; t = $r.timings }
    }
    Write-Output 'phase 1/2: generating...'
    $gen = Invoke-Phase 'Write a detailed, well-commented Python module implementing a small task queue with retries, exponential backoff, persistence to SQLite and a command-line interface. Include unit tests.' $GenerateTokens
    Write-Output 'phase 2/2: reading a long prompt, then generating at depth...'
    $filler = (1..$PromptLines | ForEach-Object { "Line $_ of the config: option_$_ = value_$($_ * 7)" }) -join "`n"
    $long = Invoke-Phase "$filler`n`nWhat is the value of option_$([int]($PromptLines / 2))? Then write a Python function that parses a .env file into a dict." $DeepTokens
    Start-Sleep 1
}
finally {
    if ($samplerProc -and -not $samplerProc.HasExited) { Stop-Process -Id $samplerProc.Id -Force }
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}

Start-Sleep 1
$samples = if ($cfg.PowerSource -eq 'amd-adlx') {
    Import-Csv $csv | ForEach-Object { [pscustomobject]@{ ms = [double]$_.ms; w = [double]$_.gpu_power_w } }
} else {
    Get-Content $csv | Where-Object { $_ -match ',' } | ForEach-Object {
        $c = $_ -split ',\s*'
        $ts = [datetime]::ParseExact($c[0].Trim(), 'yyyy/MM/dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        [pscustomobject]@{ ms = ($ts - $t0).TotalMilliseconds; w = [double]$c[1] }
    }
}
function Get-AvgPower([double]$from, [double]$to) {
    # Trim the edges so ramp-up and ramp-down samples don't dilute the phase.
    $w = $samples | Where-Object { $_.ms -ge $from + 500 -and $_.ms -le $to - 300 }
    if (-not $w) { $w = $samples | Where-Object { $_.ms -ge $from -and $_.ms -le $to } }
    [Math]::Round(($w | Measure-Object w -Average).Average, 1)
}

$gpuName = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|Radeon|NVIDIA|GeForce|RTX' } | Select-Object -First 1).Name
$result = [ordered]@{
    date = (Get-Date -Format 'yyyy-MM-dd')
    gpu = $gpuName
    model = Split-Path $cfg.Model -Leaf
    server_args = ($cfg.ServerArgs -join ' ')
    power_source = $cfg.PowerSource
    board_power_factor = $cfg.BoardPowerFactor
    idle_chip_w = Get-AvgPower 0 5500
    phases = [ordered]@{
        decode_short = [ordered]@{ tps = [Math]::Round($gen.t.predicted_per_second, 2); tokens = $gen.t.predicted_n
                                   chip_w = Get-AvgPower ($gen.end - $gen.t.predicted_ms) $gen.end }
        prefill      = [ordered]@{ tps = [Math]::Round($long.t.prompt_per_second, 2); tokens = $long.t.prompt_n
                                   chip_w = Get-AvgPower $long.start ($long.start + $long.t.prompt_ms) }
        decode_deep  = [ordered]@{ tps = [Math]::Round($long.t.predicted_per_second, 2); tokens = $long.t.predicted_n
                                   depth = $long.t.prompt_n; chip_w = Get-AvgPower ($long.end - $long.t.predicted_ms) $long.end }
    }
}
$json = Join-Path $rawDir "$stamp.json"
$result | ConvertTo-Json -Depth 5 | Set-Content $json -Encoding UTF8
Write-Output "wrote $json"
$result.phases | ConvertTo-Json -Depth 4
