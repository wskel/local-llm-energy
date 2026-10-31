<#
.SYNOPSIS
Measures GPU power and speed while a llama.cpp server generates text and reads a long prompt.
Writes results/raw/<timestamp>.json (for Get-EnergyCost.ps1) and the raw power samples as CSV.

.DESCRIPTION
Runs on Windows PowerShell 5.1 and on PowerShell 7 (Windows, Linux, macOS).

Starts its own llama-server on a random localhost port with no API key and no web UI, so nothing
is exposed and no secrets are needed. Stop any other llama-server first: two servers would share
the GPU and skew both speed and power.

Phases:
  decode_short  generate -GenerateTokens tokens from a short prompt
  prefill       read a synthetic prompt of -PromptLines lines (about 21 tokens per line)
  decode_deep   generate -DeepTokens tokens right after that prompt, i.e. at depth

.EXAMPLE
./scripts/Measure-Power.ps1 -Quick     # about 2 minutes, checks the setup works
./scripts/Measure-Power.ps1            # 3-6 minutes on a mid-range card
#>
param(
    [string]$Config = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.psd1'),
    [int]$GenerateTokens = 2500,
    [int]$PromptLines = 700,
    [int]$DeepTokens = 300,
    [switch]$Quick
)
$ErrorActionPreference = 'Stop'
$onWindows = $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows
$cfg = Import-PowerShellDataFile $Config
if ($Quick) { $GenerateTokens = 400; $PromptLines = 200; $DeepTokens = 150 }
if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    throw 'Another llama-server is running. Stop it first so it does not share the GPU or skew the power readings.'
}
foreach ($f in $cfg.ServerExe, $cfg.Model) { if (-not (Test-Path $f)) { throw "Not found: $f (check config.psd1)" } }

$root = Split-Path $PSScriptRoot -Parent
$rawDir = Join-Path (Join-Path $root 'results') 'raw'
New-Item -ItemType Directory -Force $rawDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $rawDir "$stamp-power.csv"
$port = Get-Random -Minimum 20000 -Maximum 40000
function UnixMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Starts a background process without a console window on Windows; elsewhere sends its output to a log.
function Start-Quiet([string]$file, [string[]]$arguments, [string]$log) {
    if ($onWindows) { return Start-Process $file -ArgumentList $arguments -PassThru -WindowStyle Hidden }
    Start-Process $file -ArgumentList $arguments -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
}

# Each power source starts sampling into $csv and returns a stop action plus a parser that yields
# objects { ms = milliseconds since $t0; w = watts }.
switch ($cfg.PowerSource) {
    'amd-adlx' {
        if (-not $onWindows) { throw "PowerSource 'amd-adlx' is Windows-only; on Linux use 'amd-sysfs'." }
        $sampler = Join-Path $root 'power/amd-adlx/gpupower.exe'
        if (-not (Test-Path $sampler)) { throw 'gpupower.exe missing: run power/amd-adlx/build.ps1 first.' }
        $startSampler = {
            $script:samplerT0 = UnixMs
            $p = Start-Quiet $sampler @('0', '200', "`"$csv`"") "$csv.log"
            { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }.GetNewClosure()
        }
        $parse = { Import-Csv $csv | ForEach-Object { [pscustomobject]@{ ms = [double]$_.ms + ($script:samplerT0 - $t0ms); w = [double]$_.gpu_power_w } } }
    }
    'nvidia-smi' {
        $startSampler = {
            $p = Start-Quiet 'nvidia-smi' @('--query-gpu=timestamp,power.draw', '--format=csv,noheader,nounits', '-lms', '200', '-f', "`"$csv`"") "$csv.log"
            { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }.GetNewClosure()
        }
        $parse = {
            Get-Content $csv | Where-Object { $_ -match ',' } | ForEach-Object {
                $c = $_ -split ',\s*'
                $ts = [datetime]::ParseExact($c[0].Trim(), 'yyyy/MM/dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
                [pscustomobject]@{ ms = ([DateTimeOffset]$ts).ToUnixTimeMilliseconds() - $t0ms; w = [double]$c[1] }
            }
        }
    }
    'amd-sysfs' {
        # Linux amdgpu driver. Like ADLX on Windows, RDNA cards report chip power here.
        $hw = Get-ChildItem /sys/class/drm/card*/device/hwmon/hwmon*/power1_average, /sys/class/drm/card*/device/hwmon/hwmon*/power1_input -ErrorAction SilentlyContinue |
              Where-Object { (Get-Content (Join-Path $_.Directory 'name') -ErrorAction SilentlyContinue) -eq 'amdgpu' } | Select-Object -First 1
        if (-not $hw) { throw 'No amdgpu power sensor found under /sys/class/drm/card*/device/hwmon.' }
        $startSampler = {
            $job = Start-ThreadJob -ArgumentList $hw.FullName, $csv -ScriptBlock {
                param($sensor, $out)
                'unix_ms,w' | Set-Content $out
                while ($true) {
                    $uw = [double](Get-Content $sensor)
                    "$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()),$($uw / 1e6)" | Add-Content $out
                    Start-Sleep -Milliseconds 200
                }
            }
            { Stop-Job $job; Remove-Job $job -Force }.GetNewClosure()
        }
        $parse = { Import-Csv $csv | ForEach-Object { [pscustomobject]@{ ms = [double]$_.unix_ms - $t0ms; w = [double]$_.w } } }
    }
    'macos-powermetrics' {
        # Apple Silicon. powermetrics needs root, so sudo asks for the password once up front.
        # It reports GPU power only; unified memory and CPU are not included.
        & sudo -v
        if ($LASTEXITCODE) { throw 'sudo is required for powermetrics.' }
        $startSampler = {
            $script:samplerT0 = UnixMs
            $p = Start-Process sudo -ArgumentList @('powermetrics', '--samplers', 'gpu_power', '-i', '200') -PassThru -RedirectStandardOutput $csv -RedirectStandardError "$csv.err"
            { & sudo pkill -INT -f 'powermetrics --samplers gpu_power'; Start-Sleep 1 }.GetNewClosure()
        }
        $parse = {
            # Each sample starts with "*** Sampled system activity (...) (200.53ms elapsed) ***"; accumulate elapsed time.
            $elapsed = 0.0
            foreach ($line in Get-Content $csv) {
                if ($line -match '\(([\d.]+)ms elapsed\)') { $elapsed += [double]$Matches[1] }
                elseif ($line -match '^GPU Power:\s*([\d.]+)\s*mW') {
                    [pscustomobject]@{ ms = $script:samplerT0 + $elapsed - $t0ms; w = [double]$Matches[1] / 1000 }
                }
            }
        }
    }
    default { throw "Unknown PowerSource '$($cfg.PowerSource)'. Use amd-adlx, amd-sysfs, nvidia-smi or macos-powermetrics." }
}

$server = Start-Quiet $cfg.ServerExe (@('-m', "`"$($cfg.Model)`"") + $cfg.ServerArgs + @('--host', '127.0.0.1', '--port', $port, '--no-webui')) (Join-Path $rawDir "$stamp-server.log")
$stopSampler = $null
try {
    $ok = $false
    for ($i = 0; $i -lt 300 -and -not $ok; $i++) {
        Start-Sleep 1
        if ($server.HasExited) { throw 'llama-server exited during load; run it by hand with the same flags to see why (often: context too large for VRAM).' }
        try { $ok = (Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 2).status -eq 'ok' } catch {}
    }
    if (-not $ok) { throw 'llama-server did not become ready within 5 minutes.' }
    Start-Sleep 3

    $t0ms = UnixMs
    $stopSampler = & $startSampler
    Start-Sleep 6   # idle baseline with the model loaded

    function Invoke-Phase([string]$content, [int]$maxTokens) {
        $start = (UnixMs) - $t0ms
        $body = @{ messages = @(@{ role = 'user'; content = $content }); max_tokens = $maxTokens
                   temperature = 0.7; reasoning_effort = 'none' } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3600
        [pscustomobject]@{ start = $start; end = (UnixMs) - $t0ms; t = $r.timings }
    }
    Write-Output 'phase 1/2: generating...'
    $gen = Invoke-Phase 'Write a detailed, well-commented Python module implementing a small task queue with retries, exponential backoff, persistence to SQLite and a command-line interface. Include unit tests.' $GenerateTokens
    Write-Output 'phase 2/2: reading a long prompt, then generating at depth...'
    $filler = (1..$PromptLines | ForEach-Object { "Line $_ of the config: option_$_ = value_$($_ * 7)" }) -join "`n"
    $long = Invoke-Phase "$filler`n`nWhat is the value of option_$([int]($PromptLines / 2))? Then write a Python function that parses a .env file into a dict." $DeepTokens
    Start-Sleep 1
}
finally {
    if ($stopSampler) { & $stopSampler }
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}

Start-Sleep 1
$samples = @(& $parse)
if (-not $samples) { throw "No power samples were recorded; check $csv." }
function Get-AvgPower([double]$from, [double]$to) {
    # Trim the edges so ramp-up and ramp-down samples don't dilute the phase.
    $w = $samples | Where-Object { $_.ms -ge $from + 500 -and $_.ms -le $to - 300 }
    if (-not $w) { $w = $samples | Where-Object { $_.ms -ge $from -and $_.ms -le $to } }
    [Math]::Round(($w | Measure-Object w -Average).Average, 1)
}

$gpuName = if ($cfg.GpuName) { $cfg.GpuName }
    elseif ($onWindows) { (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|Radeon|NVIDIA|GeForce|RTX' } | Select-Object -First 1).Name }
    elseif ($cfg.PowerSource -eq 'nvidia-smi') { (& nvidia-smi --query-gpu=name --format=csv,noheader | Select-Object -First 1) }
    elseif ($IsMacOS) { (& sysctl -n machdep.cpu.brand_string) }
    else { 'unknown (set GpuName in config)' }

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
