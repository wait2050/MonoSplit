#ifndef MONOSPLIT_DSP_H
#define MONOSPLIT_DSP_H
#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>
#include "MonoSplitPCM.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MSProcessor MSProcessor;
typedef struct MSPlan MSPlan;
MSProcessor *ms_create(double sample_rate);
void ms_destroy(MSProcessor *processor);
MSPlan *ms_plan_create(void);
/// Coefficients are flattened [b0,b1,b2,a1,a2], at most 28 sections per branch.
void ms_plan_channel(MSPlan *plan, int channel, const double *coefficients, int sections, double gain, double delay_ms);
/// Single control-thread producer. Also reclaims plans retired by the audio thread.
void ms_publish(MSProcessor *processor, MSPlan *plan);
void ms_collect(MSProcessor *processor);
/// Configure before rendering. Flattened physical output channels map to branch 0/1/2 or -1.
void ms_route(MSProcessor *processor, int tap_first_channel, const int32_t *outputs, int count);
/// Optional managed input. Configure before starting the IOProc; owner outlives it.
void ms_bridge_input(MSProcessor *processor, MSPCM *bridge);
/// All render calls are single-consumer, allocation-free and lock-free.
void ms_render_audio(MSProcessor *processor, const AudioBufferList *input, AudioBufferList *output);
void ms_process_planar(MSProcessor *processor, const float *left, const float *right, float *woofer, float *full_range, float *builtin, int frames);
void ms_meter(MSProcessor *processor, float *peaks, float *input_peak, float *limiter_reduction_db, uint64_t *frames, uint64_t *faults);
#ifdef __cplusplus
}
#endif
#endif
