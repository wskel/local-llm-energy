# Copy to config.psd1 (git-ignored) and edit.
@{
    # llama.cpp server binary and GGUF model to measure.
    ServerExe  = 'C:/llm/llama.cpp/llama-server.exe'
    Model      = 'C:/llm/models/model.gguf'

    # Extra server flags, exactly as you serve the model day to day.
    # On RDNA2 (RX 6000) flash attention is much slower for long prompts, so '-fa','off' is used there.
    # On NVIDIA and newer AMD cards, measure both; 'on' is usually faster.
    ServerArgs = @('-ngl', '999', '-fa', 'off', '-c', '65536', '-np', '1')

    # 'amd-adlx' (Windows, AMD driver) or 'nvidia-smi'.
    PowerSource = 'amd-adlx'

    # AMD's driver reports GPU chip power only. Set this to your card's rated board power divided by
    # its chip power limit (TGP) to estimate the whole card, e.g. RX 6800: 250 W / 203 W = 1.23.
    # nvidia-smi already reports board power: leave at 1.0.
    BoardPowerFactor = 1.0

    # Your marginal price per kWh: add every per-kWh line on the bill (delivery AND supply),
    # apply percentage surcharges, and leave out fixed monthly fees.
    RatePerKwh = 0.15

    # New input tokens per output token in a typical agent task.
    InputRatio = 1.2

    # Task sizes to price (output tokens / new input tokens).
    Tasks = @(
        @{ Output = 40000;  Input = 50000 }
        @{ Output = 81000;  Input = 100000 }
        @{ Output = 160000; Input = 200000 }
        @{ Output = 500000; Input = 500000 }
    )

    # Hosted cost per task to break even against, as published by a benchmark. Tasks differ between
    # benchmarks, so only compare within one Benchmark group. Figures read 2026-10-31; refresh them.
    #   CursorBench 4.0: https://cursor.com/cursorbench
    #   Artificial Analysis Intelligence Index v5.0 (top setting): https://artificialanalysis.ai
    Hosted = @(
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Claude Haiku 5.5 High';    Price = 0.32 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'GPT-5.6 Luna Extra High';  Price = 0.44 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Composer 2.5';             Price = 0.68 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Claude Sonnet 5.5 High';   Price = 1.20 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Grok 4.7 Low';             Price = 1.58 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'GPT-5.6 Sol High';         Price = 2.85 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Claude Opus 5.5 High';     Price = 3.97 }
        @{ Benchmark = 'CursorBench 4.0'; Name = 'Grok 4.7 Extra High';      Price = 6.01 }
        @{ Benchmark = 'AA Index v5.0';   Name = 'Claude Haiku 5.5 (max)';   Price = 0.41 }
        @{ Benchmark = 'AA Index v5.0';   Name = 'GPT-6.1 Terra (max)';      Price = 0.96 }
        @{ Benchmark = 'AA Index v5.0';   Name = 'GPT-6.1 Sol (max)';        Price = 1.27 }
        @{ Benchmark = 'AA Index v5.0';   Name = 'Qwen3.8 27B (xhigh), API'; Price = 3.53 }
        @{ Benchmark = 'AA Index v5.0';   Name = 'Claude Opus 5.5 (max)';    Price = 10.04 }
    )

    # Models with no published per-task cost: compared per token instead (USD per million tokens).
    # CacheDiscount is the share of input price saved on cache hits; agent loops re-read most input.
    PerToken = @(
        @{ Name = 'Mercury 2.5 (Inception API)'; Input = 0.20; Output = 0.75; CacheDiscount = 0.90 }
        @{ Name = 'Composer 2.5';                Input = 0.50; Output = 2.50; CacheDiscount = 0 }
    )
}
