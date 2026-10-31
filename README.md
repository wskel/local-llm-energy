# local-llm-energy

What does it cost in electricity to run a coding agent on your own GPU, and when would a hosted model have been cheaper?

This measures your card's real power draw and speed while a local model works, then turns that and your electricity rate into cost per hour, cost per task and break-even points against published hosted prices. It works with any GGUF model that llama.cpp can serve.

## Requirements

- Windows with PowerShell 5.1 or 7
- A llama.cpp `llama-server` build and a GGUF model
- Power readings from one of:
  - **AMD:** the Adrenalin driver, plus Visual Studio Build Tools (C++ workload) and git, to build the small ADLX sampler
  - **NVIDIA:** `nvidia-smi`, which comes with the driver (this path is written but not yet tested on real hardware)

## Quick start

```powershell
Copy-Item config.example.psd1 config.psd1     # then edit paths, flags, rate
./power/amd-adlx/build.ps1                    # AMD only
./scripts/Measure-Power.ps1                   # 3-6 minutes; stop other llama-server instances first
./scripts/Get-EnergyCost.ps1 -Results results/raw/<timestamp>.json
```

`Get-EnergyCost.ps1` prints Markdown tables. Pass `-RatePerKwh` to try another rate without editing the config.

### Getting your rate

Add up every per-kWh line on your bill, delivery and supply, and apply any percentage surcharges. Leave out fixed monthly fees, because running a model doesn't change them. Many bills put supply in a separate section or come from a separate supplier, so check you have both.

## What gets measured

`Measure-Power.ps1` starts its own `llama-server` on a random localhost port, with no API key and no web UI, and samples GPU power every 200 ms through three phases:

| Phase | What it does |
|---|---|
| `decode_short` | Generates 2,500 tokens from a short prompt |
| `prefill` | Reads a synthetic prompt of about 15K tokens (`-PromptLines` sets the size) |
| `decode_deep` | Generates 300 tokens right after that prompt, so at depth |

The cost calculator then uses:

- energy per token = card watts ÷ tokens per second
- task energy = output tokens × generation energy + new input tokens × prompt energy
- break-even hours = hosted price per task ÷ (card kW × rate)

Power stays roughly constant whatever the model is doing, so break-even mostly comes down to how many hours the local model has to run.

## Baselines: RX 6800, Windows 10

Measured with this repo's scripts on llama.cpp b12019 plus two unmerged Vulkan speed patches (PRs #29772 and #30139), with flash attention off. The raw results are in [`results/examples/`](results/examples/).

| Model | File size | Context | Generation | Prompt reading (about 13K tokens) | Chip power while generating |
|---|--:|--:|--:|--:|--:|
| Ternary Bonsai 2 27B (`Q2_0`) | 7.1 GB | 64K | 24.3 tok/s | 183 tok/s | 166 W |
| Qwen3.8 27B (Unsloth `UD-Q3_K_XL`) | 12.2 GB | 16K* | 25.1 tok/s | 268 tok/s | 227 W |

\* At 12.2 GB, this file only fits a 16K context with flash attention off on a 16 GB card.

AMD reports chip power only. These results use a board-power factor of 1.23, from the reference RX 6800's 250 W board and 203 W chip ratings, to estimate the whole card. The measured card is an XFX partner model with a higher power limit (Qwen read 227 W at the chip), so treat the whole-card figures as roughly ±10%. A plug-in meter gives the exact number.

## Caveats

- **Card power only.** The rest of the PC isn't counted. If the PC would be on anyway, that's the right comparison; otherwise use a plug-in meter.
- **Compare hosted prices within one benchmark.** CursorBench and the Artificial Analysis Index use different tasks, so their per-task costs aren't comparable with each other. Prices also change: refresh `Hosted` in your config.
- **Cost per attempt isn't cost per solved task.** A weaker local model that fails more often can still cost you the hosted price on top. In practice the electricity is rarely the deciding factor; your time and success rate are.
- **Flash attention depends on the card.** On RDNA2 (RX 6000) cards, which have no matrix cores, turning flash attention off made prompt reading at 16K depth 8.6× faster. On NVIDIA and newer AMD cards it's usually the other way round, so measure both.
- **Quick mode (`-Quick`) is for checking your setup works.** Use full runs for numbers you publish.

## Using it from Cursor

The skill in `.cursor/skills/local-llm-energy-cost/` walks an agent through the whole workflow. Open this repo in Cursor and ask something like "what does running my local model cost?"
