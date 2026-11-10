#include "MonoSplitDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace {
static_assert(std::atomic<void *>::is_always_lock_free, "Audio plan handoff requires lock-free pointers");
static_assert(std::atomic<float>::is_always_lock_free, "Audio meters require lock-free atomics");
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio counters require lock-free atomics");
constexpr int branches = 3;
constexpr int maxSections = 28;
struct Section {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    double process(double input) {
        double result = b0 * input + z1;
        z1 = b1 * input - a1 * result + z2;
        z2 = b2 * input - a2 * result;
        // Prevent slow denormal arithmetic on long filter tails.
        if (std::abs(z1) < 1e-30) z1 = 0;
        if (std::abs(z2) < 1e-30) z2 = 0;
        return result;
    }
};
struct Chain {
    Section sections[maxSections];
    int count = 0;
    double gain = 0, delayMS = 0;
    double process(double input) {
        for (int i = 0; i < count; ++i) input = sections[i].process(input);
        return input;
    }
    bool sameFilters(const Chain &other) const {
        if (count != other.count) return false;
        for (int i = 0; i < count; ++i) {
            const auto &a = sections[i]; const auto &b = other.sections[i];
            if (a.b0 != b.b0 || a.b1 != b.b1 || a.b2 != b.b2 || a.a1 != b.a1 || a.a2 != b.a2) return false;
        }
        return true;
    }
};
struct Delay {
    std::vector<double> history;
    int write = 0, valid = 0, current = 0, next = 0, progress = 0, fadeFrames;
    explicit Delay(double rate): history(static_cast<int>(std::ceil(rate * 2)) + 1, 0), fadeFrames(std::max(1, static_cast<int>(rate * .01))) {}
    double process(double input, int target) {
        const int capacity = static_cast<int>(history.size());
        target = std::clamp(target, 0, capacity - 1);
        if (valid == 0) current = next = target;
        if (current == next && target != current) { next = target; progress = 0; }
        history[write] = input;
        valid = std::min(valid + 1, capacity);
        double a = current < valid ? history[(write - current + capacity) % capacity] : 0;
        double result = a;
        if (current != next) {
            double b = next < valid ? history[(write - next + capacity) % capacity] : 0;
            result += (b - a) * static_cast<double>(progress + 1) / fadeFrames;
            if (++progress >= fadeFrames) { current = next; progress = 0; }
        }
        write = (write + 1) % capacity;
        return result;
    }
};
float readChannel(const AudioBufferList *list, int channel, int frame) {
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const auto &buffer = list->mBuffers[i];
        const int channels = static_cast<int>(buffer.mNumberChannels);
        if (channel < channels) {
            const auto index = static_cast<size_t>(frame) * channels + channel;
            if (buffer.mData && (index + 1) * sizeof(float) <= buffer.mDataByteSize) return static_cast<const float *>(buffer.mData)[index];
            return 0;
        }
        channel -= channels;
    }
    return 0;
}
}

struct MSPlan {
    Chain channels[branches];
    MSPlan *retiredNext = nullptr;
};

struct MSProcessor {
    double rate, smoothing, release;
    int fadeFrames, fadePosition = 0;
    std::atomic<MSPlan *> pending{nullptr}, retired{nullptr};
    MSPlan *active = nullptr, *old = nullptr;
    Delay delays[branches];
    double gains[branches] = {0, 0, 0};
    double limiterGain = 1;
    std::atomic<float> peaks[branches];
    std::atomic<float> inputPeak{0};
    std::atomic<float> reduction{0};
    std::atomic<uint64_t> frameCount{0}, faults{0};
    int tapFirstChannel = 0, outputCount = 0;
    int32_t outputMap[192];
    MSPCM *bridgeInput = nullptr;
    float bridgeSamples[16384 * 2];
    explicit MSProcessor(double sampleRate): rate(sampleRate), smoothing(1 - std::exp(-1 / (rate * .01))), release(std::exp(-1 / (rate * .08))), fadeFrames(std::max(1, static_cast<int>(rate * .02))), delays{Delay(rate), Delay(rate), Delay(rate)} {
        for (auto &peak : peaks) peak.store(0);
        std::fill(std::begin(outputMap), std::end(outputMap), -1);
    }
    void retire(MSPlan *plan) {
        if (!plan) return;
        auto head = retired.load(std::memory_order_relaxed);
        do { plan->retiredNext = head; } while (!retired.compare_exchange_weak(head, plan, std::memory_order_release, std::memory_order_relaxed));
    }
    void beginBlock() {
        if (old) return;
        auto plan = pending.exchange(nullptr, std::memory_order_acquire);
        if (!plan) return;
        if (active) {
            for (int c = 0; c < branches; ++c) {
                if (plan->channels[c].sameFilters(active->channels[c])) {
                    for (int s = 0; s < plan->channels[c].count; ++s) {
                        plan->channels[c].sections[s].z1 = active->channels[c].sections[s].z1;
                        plan->channels[c].sections[s].z2 = active->channels[c].sections[s].z2;
                    }
                }
            }
        }
        old = active;
        active = plan;
        fadePosition = 0;
    }
    void sample(float left, float right, float *values) {
        if (!std::isfinite(left) || !std::isfinite(right)) {
            left = right = 0;
            faults.fetch_add(1, std::memory_order_relaxed);
        }
        const double mono = (static_cast<double>(left) + right) * .5;
        double maxPeak = 0;
        double delayedValues[branches];
        for (int c = 0; c < branches; ++c) {
            double value = active ? active->channels[c].process(mono) : 0;
            if (old) {
                double previous = old->channels[c].process(mono);
                const double mix = static_cast<double>(fadePosition + 1) / fadeFrames;
                value = previous + (value - previous) * mix;
            }
            const double targetGain = active ? active->channels[c].gain : 0;
            gains[c] += (targetGain - gains[c]) * smoothing;
            if (!std::isfinite(value)) {
                value = 0;
                faults.fetch_add(1, std::memory_order_relaxed);
            }
            const int targetDelay = active ? static_cast<int>(std::llround(active->channels[c].delayMS * rate / 1000)) : 0;
            delayedValues[c] = delays[c].process(value, targetDelay) * gains[c];
            if (!std::isfinite(delayedValues[c])) { delayedValues[c] = 0; faults.fetch_add(1, std::memory_order_relaxed); }
            maxPeak = std::max(maxPeak, std::abs(delayedValues[c]));
        }
        const double target = maxPeak > .98 ? .98 / maxPeak : 1;
        limiterGain = target < limiterGain ? target : release * limiterGain + (1 - release) * target;
        // Release can never exceed the current sample's safe gain.
        limiterGain = std::min(limiterGain, target);
        for (int c = 0; c < branches; ++c) values[c] = static_cast<float>(delayedValues[c] * limiterGain);
        if (old && ++fadePosition >= fadeFrames) { retire(old); old = nullptr; }
    }
    void publishMeters(const float *blockPeaks, int frames, float sourcePeak) {
        for (int c = 0; c < branches; ++c) {
            float previous = peaks[c].load(std::memory_order_relaxed);
            while (previous < blockPeaks[c] && !peaks[c].compare_exchange_weak(previous, blockPeaks[c], std::memory_order_relaxed)) {}
        }
        float previousInput = inputPeak.load(std::memory_order_relaxed);
        while (previousInput < sourcePeak && !inputPeak.compare_exchange_weak(previousInput, sourcePeak, std::memory_order_relaxed)) {}
        reduction.store(static_cast<float>(-20 * std::log10(std::max(limiterGain, 1e-12))), std::memory_order_relaxed);
        frameCount.fetch_add(frames, std::memory_order_relaxed);
    }
};

extern "C" {
MSProcessor *ms_create(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return nullptr;
    return new MSProcessor(rate);
}
void ms_collect(MSProcessor *processor) {
    if (!processor) return;
    auto plan = processor->retired.exchange(nullptr, std::memory_order_acquire);
    while (plan) { auto next = plan->retiredNext; delete plan; plan = next; }
}
void ms_destroy(MSProcessor *processor) {
    if (!processor) return;
    // Caller must stop and destroy its IOProc before releasing the processor.
    ms_collect(processor);
    delete processor->pending.exchange(nullptr);
    delete processor->active;
    delete processor->old;
    delete processor;
}
MSPlan *ms_plan_create(void) { return new MSPlan(); }
void ms_plan_channel(MSPlan *plan, int channel, const double *coefficients, int sections, double gain, double delayMS) {
    if (!plan || channel < 0 || channel >= branches) return;
    auto &chain = plan->channels[channel];
    chain.count = std::clamp(sections, 0, maxSections);
    chain.gain = std::isfinite(gain) ? gain : 0;
    chain.delayMS = std::isfinite(delayMS) ? std::clamp(delayMS, 0.0, 2000.0) : 0;
    for (int s = 0; s < chain.count; ++s) {
        const auto *c = coefficients + s * 5;
        chain.sections[s] = {c[0], c[1], c[2], c[3], c[4], 0, 0};
    }
}
void ms_publish(MSProcessor *processor, MSPlan *plan) {
    auto replaced = processor->pending.exchange(plan, std::memory_order_acq_rel);
    delete replaced;
    ms_collect(processor);
}
void ms_route(MSProcessor *processor, int first, const int32_t *outputs, int count) {
    processor->tapFirstChannel = first;
    processor->outputCount = std::clamp(count, 0, 192);
    std::copy(outputs, outputs + processor->outputCount, processor->outputMap);
}
void ms_bridge_input(MSProcessor *processor, MSPCM *bridge) { processor->bridgeInput = bridge; }
void ms_process_planar(MSProcessor *processor, const float *left, const float *right, float *woofer, float *fullRange, float *builtin, int frames) {
    processor->beginBlock();
    float blockPeaks[branches] = {0, 0, 0};
    float sourcePeak = 0;
    float *outputs[branches] = {woofer, fullRange, builtin};
    for (int f = 0; f < frames; ++f) {
        float values[branches];
        const float l = left ? left[f] : 0, r = right ? right[f] : 0;
        const float mono = static_cast<float>((static_cast<double>(l) + r) * .5);
        if (std::isfinite(mono)) sourcePeak = std::max(sourcePeak, std::abs(mono));
        processor->sample(l, r, values);
        for (int c = 0; c < branches; ++c) {
            if (outputs[c]) outputs[c][f] = values[c];
            blockPeaks[c] = std::max(blockPeaks[c], std::abs(values[c]));
        }
    }
    processor->publishMeters(blockPeaks, frames, sourcePeak);
}
void ms_render_audio(MSProcessor *processor, const AudioBufferList *input, AudioBufferList *output) {
    processor->beginBlock();
    int frames = 0;
    bool hasOutput = false;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        auto &buffer = output->mBuffers[b];
        if (buffer.mData) std::memset(buffer.mData, 0, buffer.mDataByteSize);
        if (buffer.mData && buffer.mNumberChannels > 0) {
            const int available = buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels);
            frames = hasOutput ? std::min(frames, available) : available;
            hasOutput = true;
        }
    }
    float blockPeaks[branches] = {0, 0, 0};
    float sourcePeak = 0;
    if (processor->bridgeInput) mspcm_mix(processor->bridgeInput, processor->bridgeSamples, std::min(frames, 16384));
    for (int f = 0; f < frames; ++f) {
        float values[branches];
        const float l = processor->bridgeInput ? (f < 16384 ? processor->bridgeSamples[f * 2] : 0) : readChannel(input, processor->tapFirstChannel, f);
        const float r = processor->bridgeInput ? (f < 16384 ? processor->bridgeSamples[f * 2 + 1] : 0) : readChannel(input, processor->tapFirstChannel + 1, f);
        const float mono = static_cast<float>((static_cast<double>(l) + r) * .5);
        if (std::isfinite(mono)) sourcePeak = std::max(sourcePeak, std::abs(mono));
        processor->sample(l, r, values);
        for (int c = 0; c < branches; ++c) blockPeaks[c] = std::max(blockPeaks[c], std::abs(values[c]));
        int flatChannel = 0;
        for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
            auto &buffer = output->mBuffers[b];
            for (UInt32 c = 0; c < buffer.mNumberChannels; ++c, ++flatChannel) {
                int branch = flatChannel < processor->outputCount ? processor->outputMap[flatChannel] : -1;
                if (branch >= 0 && branch < branches && buffer.mData) static_cast<float *>(buffer.mData)[static_cast<size_t>(f) * buffer.mNumberChannels + c] = values[branch];
            }
        }
    }
    processor->publishMeters(blockPeaks, frames, sourcePeak);
}
void ms_meter(MSProcessor *processor, float *peaks, float *inputPeak, float *reduction, uint64_t *frames, uint64_t *faults) {
    for (int c = 0; c < branches; ++c) peaks[c] = processor->peaks[c].exchange(0, std::memory_order_relaxed);
    *inputPeak = processor->inputPeak.exchange(0, std::memory_order_relaxed);
    *reduction = processor->reduction.load(std::memory_order_relaxed);
    *frames = processor->frameCount.load(std::memory_order_relaxed);
    *faults = processor->faults.load(std::memory_order_relaxed);
}
}
