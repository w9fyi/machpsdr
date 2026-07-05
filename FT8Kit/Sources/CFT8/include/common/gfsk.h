// GFSK waveform synthesis for FT8/FT4, adapted from ft8_lib demo/gen_ft8.c
// (MIT license, Kārlis Goba). Modified to use heap allocation so it is safe
// to call from threads with small stacks.
#ifndef _INCLUDE_GFSK_H_
#define _INCLUDE_GFSK_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define FT8_SYMBOL_BT 2.0f ///< symbol smoothing filter bandwidth factor (BT)
#define FT4_SYMBOL_BT 1.0f ///< symbol smoothing filter bandwidth factor (BT)

/// Synthesize GFSK-shaped audio for a tone sequence.
/// @param[in] symbols Array of tones (0-7 for FT8, 0-3 for FT4)
/// @param[in] n_sym Number of symbols
/// @param[in] f0 Audio frequency in Hz of tone 0
/// @param[in] symbol_bt Smoothing bandwidth (FT8_SYMBOL_BT / FT4_SYMBOL_BT)
/// @param[in] symbol_period Symbol duration in seconds
/// @param[in] signal_rate Output sample rate in Hz
/// @param[out] signal Output buffer; must hold n_sym * round(signal_rate * symbol_period) samples
/// @return 0 on success, -1 on allocation failure
int synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt,
               float symbol_period, int signal_rate, float* signal);

#ifdef __cplusplus
}
#endif

#endif // _INCLUDE_GFSK_H_
