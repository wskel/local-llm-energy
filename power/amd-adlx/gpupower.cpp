// Samples AMD GPU power through ADLX and writes one CSV row per sample.
// Usage: gpupower.exe <seconds, 0 = until killed> <interval_ms> <out.csv>
#include "SDK/ADLXHelper/Windows/Cpp/ADLXHelper.h"
#include "SDK/Include/IPerformanceMonitoring.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

using namespace adlx;

int main(int argc, char** argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 10;
    int intervalMs = argc > 2 ? atoi(argv[2]) : 200;
    const char* outPath = argc > 3 ? argv[3] : "gpupower.csv";

    if (ADLX_FAILED(g_ADLX.Initialize())) { fprintf(stderr, "ADLX init failed (AMD driver missing?)\n"); return 1; }

    IADLXGPUListPtr gpus;
    IADLXGPUPtr gpu;
    IADLXPerformanceMonitoringServicesPtr perf;
    IADLXGPUMetricsSupportPtr support;
    if (ADLX_FAILED(g_ADLX.GetSystemServices()->GetGPUs(&gpus)) || ADLX_FAILED(gpus->At(gpus->Begin(), &gpu)) ||
        ADLX_FAILED(g_ADLX.GetSystemServices()->GetPerformanceMonitoringServices(&perf)) ||
        ADLX_FAILED(perf->GetSupportedGPUMetrics(gpu, &support)))
    {
        fprintf(stderr, "ADLX GPU or metrics unavailable\n");
        return 1;
    }

    const char* name = nullptr;
    gpu->Name(&name);
    adlx_bool hasPower = false, hasTbp = false;
    support->IsSupportedGPUPower(&hasPower);
    support->IsSupportedGPUTotalBoardPower(&hasTbp);
    printf("gpu=%s gpu_power=%d total_board_power=%d\n", name ? name : "?", hasPower, hasTbp);

    FILE* out = fopen(outPath, "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", outPath); return 1; }
    fprintf(out, "ms,gpu_power_w,board_power_w,gpu_usage_pct\n");
    fflush(out);

    auto start = std::chrono::steady_clock::now();
    while (seconds == 0 || std::chrono::steady_clock::now() - start < std::chrono::seconds(seconds))
    {
        IADLXGPUMetricsPtr m;
        if (ADLX_SUCCEEDED(perf->GetCurrentGPUMetrics(gpu, &m)))
        {
            double p = -1, t = -1, u = -1;
            if (hasPower) m->GPUPower(&p);
            if (hasTbp) m->GPUTotalBoardPower(&t);
            m->GPUUsage(&u);
            long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
            fprintf(out, "%lld,%.1f,%.1f,%.0f\n", ms, p, t, u);
            fflush(out);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));
    }
    fclose(out);
    return 0;
}
