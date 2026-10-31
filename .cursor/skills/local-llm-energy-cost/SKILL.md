---
name: local-llm-energy-cost
description: Measures a local LLM's GPU power draw and speed under llama.cpp, then computes electricity cost per hour and per task, and break-even points against hosted models' published per-task prices. Use when the user asks what running a local model costs, whether local is cheaper than a hosted model, the break-even point, or wants to measure GPU power or tokens per second for a GGUF model.
---

# Local LLM energy cost

All scripts live in this repository. Run them; don't reimplement the arithmetic.

## Workflow

```
- [ ] 1. Rate per kWh from the user's bill
- [ ] 2. config.psd1 set up
- [ ] 3. Power sampler available
- [ ] 4. Measurement run
- [ ] 5. Cost tables generated
- [ ] 6. Answer with caveats
```

**1. Rate.** Ask for the bill's line items if you don't have a rate. Add every per-kWh charge in both the delivery and supply sections, apply percentage surcharges, and leave out fixed monthly fees. If only one section is given, ask for the other: supply is often billed separately and can be close to half the rate.

**2. Config.** Copy `config.example.psd1` to `config.psd1`. Set:
- `ServerExe` and `Model` (any GGUF).
- `ServerArgs`: the flags the user actually serves with, so the measurement matches real use.
- `PowerSource`:
  - `amd-adlx` for Windows with AMD;
  - `amd-sysfs` for Linux with AMD;
  - `nvidia-smi` for NVIDIA on Windows or Linux;
  - `macos-powermetrics` for Apple Silicon.
- `BoardPowerFactor`: for AMD, the card's rated board power ÷ chip power limit (TGP), because AMD drivers report chip power only. For NVIDIA, 1.0. For macOS, 1.0, and say the result is a lower bound: GPU only, with no unified memory or CPU.
- `RatePerKwh`.

For a second model, use a separate file such as `config-modelname.psd1`, which is also git-ignored.

**3. Sampler.** Windows with AMD: run `power/amd-adlx/build.ps1` once. It clones the ADLX headers at a pinned commit and builds `gpupower.exe`. The other sources need nothing extra. On Linux and macOS, the scripts need PowerShell 7 (`pwsh`). On macOS, warn the user that a sudo password prompt will appear for powermetrics.

**4. Measure.** Stop any other `llama-server` first; the script refuses to run otherwise. Then run `scripts/Measure-Power.ps1 [-Config <file>]`. It takes 3–6 minutes. It starts its own key-less server on a random localhost port, so never pass the user's API key. If the server exits during load, the context doesn't fit in VRAM: lower `-c` in `ServerArgs`, and keep `-PromptLines` × 21 tokens below the context size. `-Quick` only checks that the setup works.

**5. Tables.** Run `scripts/Get-EnergyCost.ps1 -Results results/raw/<timestamp>.json [-Config <file>]`. To compare against the shipped baselines, run it on the files in `results/examples/` with the user's config.

**6. Answer.** Lead with cost per hour and break-even hours against the hosted model the user cares about. Then state the caveats that apply:
- Card power only, not the whole PC.
- Hosted per-task prices are only comparable within one benchmark.
- Hosted prices date quickly. Check the `Hosted` list against the sources in the config comments before quoting it.
- A weaker model that fails a task costs the hosted price as well. Speed and success rate usually matter more than electricity.

## Gotchas

- Before blaming the model for slow prompt reading, measure with flash attention both on and off. On RDNA2 (RX 6000) cards, which lack matrix cores, flash attention made prompt reading at 16K depth about 8× slower. Turning it off requires an f16 KV cache, which uses more VRAM.
- `decode_deep` is a short burst and can read faster than `decode_short`. Treat the two as a range, not as a trend.
- Models without a published per-task cost go in `PerToken` and are compared per million output tokens. Include cache discounts: agent loops re-read most of their input.
- When the user brings their own model, keep the baselines in `results/examples/` for comparison and measure theirs with the same `-PromptLines`.
