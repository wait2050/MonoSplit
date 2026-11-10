#include "MonoSplitPCM.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static void send_block(MSPCM *writer, float value) {
    float samples[1024 * 2];
    for (int i = 0; i < 1024; ++i) { samples[i * 2] = value; samples[i * 2 + 1] = -value; }
    AudioBufferList audio = { .mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}} };
    assert(mspcm_write(writer, &audio, 0, 1) == 1024);
}
static void check(const float *samples, float value, int frames) {
    for (int i = 0; i < frames; ++i) {
        assert(fabsf(samples[i * 2] - value) < .00001f);
        assert(fabsf(samples[i * 2 + 1] + value) < .00001f);
    }
}
int main(void) {
    char directory[] = "/tmp/monosplit-pcm-tests.XXXXXX";
    assert(mkdtemp(directory));
    char path[256];
    snprintf(path, sizeof(path), "%s/session.pcm", directory);
    MSPCM *server = mspcm_create(path, 48000);
    assert(server && !mspcm_create(path, 48000));
    assert(!mspcm_open_writer(path, 44100)); // Failed opens cannot stop the server.
    MSPCM *a = mspcm_open_writer(path, 48000);
    MSPCM *b = mspcm_open_writer(path, 48000);
    assert(a && b);
    for (int i = 0; i < 4; ++i) { send_block(a, .1f); send_block(b, .2f); }
    float output[1024 * 2];
    for (int i = 0; i < 4; ++i) { mspcm_mix(server, output, 1024); check(output, .3f, 1024); }
    mspcm_mix(server, output, 1024); check(output, 0, 1024);
    // Underrun starts a new preroll; old samples are never replayed.
    send_block(a, .4f);
    mspcm_mix(server, output, 1024); check(output, 0, 1024);
    mspcm_close(a); mspcm_close(b);
    mspcm_mix(server, output, 1024);
    for (int i = 0; i < 256; ++i) {
        MSPCM *writer = mspcm_open_writer(path, 48000);
        assert(writer);
        mspcm_close(writer);
        mspcm_mix(server, output, 1024);
    }
    // Actual second process writes through a separate mmap. Reaping a crashed
    // sender releases its slot, and the next sender sees empty counters.
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        MSPCM *writer = mspcm_open_writer(path, 48000);
        assert(writer);
        for (int i = 0; i < 4; ++i) send_block(writer, .125f);
        _exit(0); // Deliberately omit cleanup to exercise crash recovery.
    }
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    mspcm_mix(server, output, 1024); check(output, .125f, 1024);
    mspcm_reap(server);
    mspcm_mix(server, output, 1024); check(output, 0, 1024);
    a = mspcm_open_writer(path, 48000);
    assert(a);
    mspcm_close(server);
    float samples[2] = {1, 1};
    AudioBufferList audio = { .mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}} };
    assert(mspcm_write(a, &audio, 0, 1) == 0);
    mspcm_close(a);
    assert(!mspcm_open_writer(path, 48000));
    unlink(path); rmdir(directory);
    puts("PCM bridge: mix, stereo, preroll, underrun, slot reuse, cross-process and crash recovery passed");
    return 0;
}
