<#
.SYNOPSIS
Turns a power measurement (from Measure-Power.ps1) and your electricity rate into
cost-per-task and break-even tables, printed as Markdown.

.EXAMPLE
./scripts/Get-EnergyCost.ps1 -Results results/2026-10-31-rx6800-bonsai.json
#>
param(
    [Parameter(Mandatory)][string]$Results,
    [string]$Config = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.psd1'),
    [double]$RatePerKwh
)
$ErrorActionPreference = 'Stop'
$r = Get-Content $Results -Raw | ConvertFrom-Json
$cfg = Import-PowerShellDataFile $Config
$rate = if ($PSBoundParameters.ContainsKey('RatePerKwh')) { $RatePerKwh } else { $cfg.RatePerKwh }
$factor = [double]$r.board_power_factor
$p = $r.phases

# Non-ASCII characters built from code points: Windows PowerShell 5 misreads them in BOM-less UTF-8 files.
$cent = [char]0xA2; $dash = [char]0x2013
function Money([double]$usd) { if ($usd -lt 1) { "{0:N1}$cent" -f ($usd * 100) } else { '${0:N2}' -f $usd } }
function Span([double]$s) {
    $h = [Math]::Floor($s / 3600); $m = [Math]::Round(($s % 3600) / 60)
    if ($m -eq 60) { $h++; $m = 0 }
    if ($h -gt 0) { '{0} h {1:00} min' -f $h, $m } else { '{0} min' -f $m }
}
function Range($a, $b) { if ($a -eq $b) { $a } else { "$a $dash $b" } }

# Two scenarios: short context, and the deep-context speeds (agent contexts grow during a task).
$scenarios = foreach ($name in 'short', 'deep') {
    $dec = if ($name -eq 'short') { $p.decode_short } else { $p.decode_deep }
    $pre = if ($name -eq 'deep' -and $p.prefill_deep) { $p.prefill_deep } else { $p.prefill }
    $decW = $dec.chip_w * $factor; $preW = $pre.chip_w * $factor
    [pscustomobject]@{
        name = $name
        decW = $decW; preW = $preW
        decJ = $decW / $dec.tps; preJ = $preW / $pre.tps        # joules per token
        decS = 1 / $dec.tps;    preS = 1 / $pre.tps             # seconds per token
    }
}

function TaskFigures($s, [double]$out, [double]$in) {
    $kwh = ($out * $s.decJ + $in * $s.preJ) / 3.6e6
    [pscustomobject]@{ kwh = $kwh; cost = $kwh * $rate; secs = $out * $s.decS + $in * $s.preS }
}

$S = $scenarios[0]; $D = $scenarios[1]
"## Inputs"
""
"- Rate: `$$rate per kWh"
"- Model: $($r.model) on $($r.gpu), measured $($r.date)"
"- Power: chip readings x $factor for the whole card ($($r.power_source))"
"- Generation: {0:N1} tok/s at {1:N0} W (short context), {2:N1} tok/s at {3:N0} W (about {4:N0} tokens deep)" -f $p.decode_short.tps, $S.decW, $p.decode_deep.tps, $D.decW, $p.decode_deep.depth
"- Prompt reading: {0:N0} tok/s at {1:N0} W ({2:N0}-token prompt)" -f $p.prefill.tps, $S.preW, $p.prefill.tokens
if ($p.prefill_deep) { "- Prompt reading, deep: {0:N0} tok/s ({1:N0}-token prompt)" -f $p.prefill_deep.tps, $p.prefill_deep.tokens }
""
"## Cost per hour of running"
""
"| Phase | Card power | Cost per hour |"
"|---|--:|--:|"
"| Generating | {0:N0} W | {1} |" -f $S.decW, (Money ($S.decW / 1000 * $rate))
"| Reading prompt | {0:N0} W | {1} |" -f $S.preW, (Money ($S.preW / 1000 * $rate))
""
"## Cost per task (short context $dash deep context)"
""
"| Task (output / new input) | Energy | Cost | Running time |"
"|---|--:|--:|--:|"
foreach ($t in $cfg.Tasks) {
    $a = TaskFigures $S $t.Output $t.Input; $b = TaskFigures $D $t.Output $t.Input
    "| {0}k / {1}k | {2} kWh | {3} | {4} |" -f ($t.Output / 1000), ($t.Input / 1000),
        (Range ('{0:N2}' -f $a.kwh) ('{0:N2}' -f $b.kwh)), (Range (Money $a.cost) (Money $b.cost)), (Range (Span $a.secs) (Span $b.secs))
}
""
"## Break-even against hosted cost per task"
""
"Input is counted at $($cfg.InputRatio)x output. 'Hours' is how long the local model must run on one task to cost as much as one hosted task. Only compare rows within the same benchmark: their tasks differ."
$perM = foreach ($s in $S, $D) { TaskFigures $s 1e6 (1e6 * $cfg.InputRatio) }
foreach ($group in ($cfg.Hosted | Group-Object { $_.Benchmark })) {
    ""
    "### $($group.Name)"
    ""
    "| Hosted model | Cost per task | Hours | Local output tokens |"
    "|---|--:|--:|--:|"
    foreach ($h in ($group.Group | Sort-Object { $_.Price })) {
        $tok = $perM | ForEach-Object { $h.Price / $_.cost } | Sort-Object
        $hrs = $perM | ForEach-Object { $h.Price / $_.cost * $_.secs / 3600 } | Sort-Object
        "| {0} | `${1:N2} | {2} | {3} |" -f $h.Name, $h.Price,
            (Range ('{0:N0}' -f $hrs[0]) ('{0:N0}' -f $hrs[1])), (Range ('{0:N2}M' -f $tok[0]) ('{0:N2}M' -f $tok[1]))
    }
}
""
"## Per million output tokens"
""
"Includes $($cfg.InputRatio)M input tokens per 1M output. Hosted input is shown at full price and, where a cache discount exists, with all input as cache hits."
""
"| | Cost per 1M output tokens |"
"|---|--:|"
"| Local (electricity) | {0} |" -f (Range (Money $perM[0].cost) (Money $perM[1].cost))
foreach ($t in $cfg.PerToken) {
    $full = $t.Output + $cfg.InputRatio * $t.Input
    $cached = $t.Output + $cfg.InputRatio * $t.Input * (1 - $t.CacheDiscount)
    "| {0} | {1} |" -f $t.Name, (Range (Money $cached) (Money $full))
}
