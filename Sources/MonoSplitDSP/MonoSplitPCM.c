// SPDX-License-Identifier: 0BSD
// Copyright (c) 2026 wait2050
#include "MonoSplitPCM.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>

// SPSC ring per application renderer. A track is reused only after the reader
// acknowledges retirement; counters never reset while the mapping is live.
enum { track_count = 64, capacity = 16384, magic = 0x4D535031 };
enum { free_track = 0, claiming = 1, retired = 3 };
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "PCM transport requires lock-free interprocess atomics");
typedef struct {
    _Atomic uint64_t state;
    _Atomic uint64_t read;
    _Atomic uint64_t written;
    float samples[capacity * 2];
} Track;
typedef struct {
    uint32_t signature, version;
    double rate;
    _Atomic uint32_t running;
    Track tracks[track_count];
} Shared;
struct MSPCM {
    Shared *shared;
    int writer, server, slot;
    int primed[track_count];
};

static MSPCM *map_file(int fd) {
    void *memory = mmap(NULL, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (memory == MAP_FAILED) return NULL;
    MSPCM *bridge = calloc(1, sizeof(MSPCM));
    if (!bridge) { munmap(memory, sizeof(Shared)); return NULL; }
    bridge->shared = memory;
    bridge->slot = -1;
    return bridge;
}
MSPCM *mspcm_create(const char *path, double rate) {
    if (!isfinite(rate) || rate < 8000 || rate > 192000) return NULL;
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NULL;
    if (ftruncate(fd, sizeof(Shared)) != 0) { close(fd); unlink(path); return NULL; }
    MSPCM *bridge = map_file(fd);
    if (!bridge) { unlink(path); return NULL; }
    Shared *shared = bridge->shared;
    bridge->server = 1;
    memset(shared, 0, sizeof(*shared)); // Fault in pages before the IOProc starts.
    shared->signature = magic;
    shared->version = 1;
    shared->rate = rate;
    for (int i = 0; i < track_count; ++i) {
        atomic_init(&shared->tracks[i].state, free_track);
        atomic_init(&shared->tracks[i].read, 0);
        atomic_init(&shared->tracks[i].written, 0);
    }
    atomic_init(&shared->running, 1);
    return bridge;
}
MSPCM *mspcm_open_writer(const char *path, double rate) {
    int fd = open(path, O_RDWR | O_NOFOLLOW);
    if (fd < 0) return NULL;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        info.st_size != sizeof(Shared) || (info.st_mode & 077) != 0) { close(fd); return NULL; }
    MSPCM *bridge = map_file(fd);
    if (!bridge) return NULL;
    Shared *shared = bridge->shared;
    if (shared->signature != magic || shared->version != 1 || shared->rate != rate ||
        !atomic_load_explicit(&shared->running, memory_order_acquire)) {
        mspcm_close(bridge); return NULL;
    }
    bridge->writer = 1;
    for (int i = 0; i < track_count; ++i) {
        uint64_t expected = free_track;
        Track *track = &shared->tracks[i];
        if (atomic_compare_exchange_strong_explicit(&track->state, &expected, claiming,
                                                    memory_order_acq_rel, memory_order_relaxed)) {
            bridge->slot = i;
            const uint64_t token = ((uint64_t)getpid() << 32) | (arc4random() | 4U);
            atomic_store_explicit(&track->state, token, memory_order_release);
            return bridge;
        }
    }
    mspcm_close(bridge);
    return NULL;
}
void mspcm_close(MSPCM *bridge) {
    if (!bridge) return;
    if (bridge->writer && bridge->slot >= 0) {
        atomic_store_explicit(&bridge->shared->tracks[bridge->slot].state, retired, memory_order_release);
    } else if (bridge->server) {
        atomic_store_explicit(&bridge->shared->running, 0, memory_order_release);
    }
    munmap(bridge->shared, sizeof(Shared));
    free(bridge);
}
void mspcm_reap(MSPCM *bridge) {
    if (!bridge || bridge->writer) return;
    for (int i = 0; i < track_count; ++i) {
        Track *track = &bridge->shared->tracks[i];
        uint64_t expected = atomic_load_explicit(&track->state, memory_order_acquire);
        if (expected > retired && kill((pid_t)(expected >> 32), 0) != 0 && errno == ESRCH) {
            atomic_compare_exchange_strong_explicit(&track->state, &expected, retired,
                                                    memory_order_release, memory_order_relaxed);
        }
    }
}
void mspcm_mix(MSPCM *bridge, float *stereo, int frames) {
    if (!stereo || frames <= 0 || frames > capacity) return;
    memset(stereo, 0, (size_t)frames * 2 * sizeof(float));
    if (!bridge || bridge->writer) return;
    // 40 ms of preroll tolerates callback scheduling differences on the shared
    // physical clock. No resampling: senders must use this exact clock and rate.
    const int preroll = (int)(bridge->shared->rate * .040);
    for (int i = 0; i < track_count; ++i) {
        Track *track = &bridge->shared->tracks[i];
        const uint64_t state = atomic_load_explicit(&track->state, memory_order_acquire);
        if (state == retired) {
            atomic_store_explicit(&track->read, atomic_load_explicit(&track->written, memory_order_acquire), memory_order_release);
            bridge->primed[i] = 0;
            atomic_store_explicit(&track->state, free_track, memory_order_release);
            continue;
        }
        if (state <= retired) continue;
        const uint64_t read = atomic_load_explicit(&track->read, memory_order_relaxed);
        const uint64_t written = atomic_load_explicit(&track->written, memory_order_acquire);
        const uint64_t available = written - read;
        if (available > capacity) continue;
        if (!bridge->primed[i] && available < (uint64_t)(preroll + frames)) continue;
        bridge->primed[i] = 1;
        const int count = available < (uint64_t)frames ? (int)available : frames;
        for (int f = 0; f < count; ++f) {
            const size_t offset = (size_t)((read + f) % capacity) * 2;
            stereo[f * 2] += track->samples[offset];
            stereo[f * 2 + 1] += track->samples[offset + 1];
        }
        atomic_store_explicit(&track->read, read + count, memory_order_release);
        if (count < frames) bridge->primed[i] = 0;
    }
}
static float read_channel(const AudioBufferList *audio, int channel, int frame) {
    for (uint32_t b = 0; b < audio->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &audio->mBuffers[b];
        if (channel < (int)buffer->mNumberChannels) {
            const size_t index = (size_t)frame * buffer->mNumberChannels + channel;
            if (buffer->mData && (index + 1) * sizeof(float) <= buffer->mDataByteSize) {
                const float value = ((const float *)buffer->mData)[index];
                return isfinite(value) ? value : 0;
            }
            return 0;
        }
        channel -= buffer->mNumberChannels;
    }
    return 0;
}
int mspcm_write(MSPCM *bridge, const AudioBufferList *audio, int left, int right) {
    if (!bridge || !bridge->writer || bridge->slot < 0 || !audio || left < 0 || right < 0 ||
        !atomic_load_explicit(&bridge->shared->running, memory_order_acquire)) return 0;
    int frames = capacity;
    for (uint32_t b = 0; b < audio->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &audio->mBuffers[b];
        if (!buffer->mNumberChannels) continue;
        const int count = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (count < frames) frames = count;
    }
    if (!audio->mNumberBuffers || frames <= 0) return 0;
    Track *track = &bridge->shared->tracks[bridge->slot];
    const uint64_t written = atomic_load_explicit(&track->written, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&track->read, memory_order_acquire);
    if (written - read > capacity || (uint64_t)frames > capacity - (written - read)) return 0;
    for (int f = 0; f < frames; ++f) {
        const size_t offset = (size_t)((written + f) % capacity) * 2;
        track->samples[offset] = read_channel(audio, left, f);
        track->samples[offset + 1] = read_channel(audio, right, f);
    }
    atomic_store_explicit(&track->written, written + frames, memory_order_release);
    return frames;
}
