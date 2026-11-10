// SPDX-License-Identifier: 0BSD
// Copyright (c) 2026 wait2050
#ifndef MONOSPLIT_PCM_H
#define MONOSPLIT_PCM_H
#include <CoreAudio/CoreAudioTypes.h>
#ifdef __cplusplus
extern "C" {
#endif
// Wire protocol v1. Keep the standalone copy in FineTune identical.
typedef struct MSPCM MSPCM;
MSPCM *mspcm_create(const char *path, double sample_rate);
MSPCM *mspcm_open_writer(const char *path, double sample_rate);
void mspcm_close(MSPCM *bridge);
// Control thread only: reclaim tracks whose sending process has exited.
void mspcm_reap(MSPCM *bridge);
// RT entry points: bounded, no allocation, locks, syscalls, or file I/O.
void mspcm_mix(MSPCM *bridge, float *stereo, int frames);
int mspcm_write(MSPCM *bridge, const AudioBufferList *audio, int left, int right);
#ifdef __cplusplus
}
#endif
#endif
