// GFSK waveform synthesis for FT8/FT4, adapted from ft8_lib demo/gen_ft8.c
// (MIT license, Kārlis Goba). Modified to use heap allocation instead of
// variable-length arrays: at 48 kHz an FT8 transmission needs ~2.4 MB for
// the phase ramp, far beyond small thread stacks.
#include "gfsk.h"

#include <math.h>
#include <stdlib.h>

#define GFSK_CONST_K 5.336446f ///< == pi * sqrt(2 / log(2))

/// Computes a GFSK smoothing pulse, truncated at 3 symbol lengths.
/// @param[out] pulse Output array of 3 * n_spsym samples
static void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse)
{
    for (int i = 0; i < 3 * n_spsym; ++i)
    {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = GFSK_CONST_K * symbol_bt * (t + 0.5f);
        float arg2 = GFSK_CONST_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

int synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt,
               float symbol_period, int signal_rate, float* signal)
{
    int n_spsym = (int)(0.5f + signal_rate * symbol_period); // Samples per symbol
    int n_wave = n_sym * n_spsym;                            // Number of output samples
    float hmod = 1.0f;

    // Smoothed frequency waveform: (nsym+2)*n_spsym samples,
    // first and last symbols extended.
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    float* dphi = malloc(sizeof(float) * (n_wave + 2 * n_spsym));
    float* pulse = malloc(sizeof(float) * 3 * n_spsym);
    if (dphi == NULL || pulse == NULL)
    {
        free(dphi);
        free(pulse);
        return -1;
    }

    // Shift frequency up by f0
    for (int i = 0; i < n_wave + 2 * n_spsym; ++i)
    {
        dphi[i] = 2 * M_PI * f0 / signal_rate;
    }

    gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < n_sym; ++i)
    {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
        {
            dphi[j + ib] += dphi_peak * symbols[i] * pulse[j];
        }
    }

    // Dummy symbols at beginning and end with tone values equal to 1st and
    // last symbol, respectively.
    for (int j = 0; j < 2 * n_spsym; ++j)
    {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * symbols[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * symbols[n_sym - 1];
    }

    // Calculate and insert the audio waveform
    float phi = 0;
    for (int k = 0; k < n_wave; ++k)
    { // Don't include dummy symbols
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }

    // Apply envelope shaping to the first and last symbols
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i)
    {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }

    free(dphi);
    free(pulse);
    return 0;
}
