#include "HaloAudio.h"
#include <stdatomic.h>
#include <string.h>
#include <math.h>

#define kRingFrames 32768            // power of two, ≈0.68 s at 48 kHz
#define kRingMask (kRingFrames - 1)

static float gRing[kRingFrames * 2];
static _Atomic unsigned long long gWritten = 0;   // frames written by the input side

// Output side only
static double gReadPos = 0;          // absolute position in source frames
static double gFill = 0;             // smoothed source frames available
static int gPrimed = 0;
static double gTarget = 1024;        // source frames to keep buffered
static double gBaseRatio = 1;        // source rate / destination rate
static _Atomic unsigned gUnderruns = 0;
static _Atomic double gFillMs = 0;

static AudioDeviceID gSource = 0, gDest = 0;
static AudioDeviceIOProcID gInProc = NULL, gOutProc = NULL;
static double gSourceRate = 48000, gDestRate = 48000;
static _Atomic int gRunning = 0;

static OSStatus InputProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                          const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                          void* client) {
    (void)device; (void)now; (void)inputTime; (void)output; (void)outputTime; (void)client;
    if (!input || input->mNumberBuffers == 0) return 0;
    const AudioBuffer* b = &input->mBuffers[0];
    if (!b->mData || b->mNumberChannels == 0) return 0;
    UInt32 ch = b->mNumberChannels;
    UInt32 frames = b->mDataByteSize / (ch * sizeof(float));
    const float* src = b->mData;
    unsigned long long w = atomic_load_explicit(&gWritten, memory_order_relaxed);
    for (UInt32 i = 0; i < frames; i++) {
        unsigned long long k = ((w + i) & kRingMask) * 2;
        float l = src[i * ch];
        float r = ch > 1 ? src[i * ch + 1] : l;
        gRing[k] = l;
        gRing[k + 1] = r;
    }
    atomic_store_explicit(&gWritten, w + frames, memory_order_release);
    return 0;
}

static inline float Sample(long long frame, int c) {
    return gRing[((unsigned long long)frame & kRingMask) * 2 + c];
}

// Cubic Hermite interpolation between frames p1 and p2.
static inline float Hermite(float p0, float p1, float p2, float p3, float t) {
    float a = -0.5f * p0 + 1.5f * p1 - 1.5f * p2 + 0.5f * p3;
    float b = p0 - 2.5f * p1 + 2.0f * p2 - 0.5f * p3;
    float c = -0.5f * p0 + 0.5f * p2;
    return ((a * t + b) * t + c) * t + p1;
}

static void Silence(AudioBufferList* out) {
    for (UInt32 i = 0; i < out->mNumberBuffers; i++)
        if (out->mBuffers[i].mData) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
}

static OSStatus OutputProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                           const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                           void* client) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)client;
    if (!output || output->mNumberBuffers == 0 || !output->mBuffers[0].mData) return 0;
    UInt32 ch0 = output->mBuffers[0].mNumberChannels ? output->mBuffers[0].mNumberChannels : 1;
    UInt32 frames = output->mBuffers[0].mDataByteSize / (ch0 * sizeof(float));
    unsigned long long written = atomic_load_explicit(&gWritten, memory_order_acquire);
    double avail = (double)written - gReadPos;
    double need = frames * gBaseRatio * 1.01 + 4;

    if (!gPrimed) {
        if (avail < gTarget + need) { Silence(output); return 0; }
        gReadPos = (double)written - gTarget - need;
        gFill = gTarget;
        gPrimed = 1;
        avail = (double)written - gReadPos;
    }
    if (avail < need || avail > kRingFrames - 4096) {
        // Ran dry (or fell hopelessly behind): start over from a fresh buffer.
        if (avail < need) atomic_fetch_add(&gUnderruns, 1);
        gPrimed = 0;
        Silence(output);
        return 0;
    }

    // Gentle speed correction (at most ±0.2 %, inaudible) steers the buffer back to its target.
    gFill = gFill * 0.98 + avail * 0.02;
    double err = (gFill - (gTarget + need)) / gTarget;
    if (err > 1) err = 1;
    if (err < -1) err = -1;
    double ratio = gBaseRatio * (1 + 0.002 * err);
    atomic_store_explicit(&gFillMs, gFill / gSourceRate * 1000, memory_order_relaxed);

    double pos = gReadPos;
    int interleaved = output->mNumberBuffers == 1;
    for (UInt32 i = 0; i < frames; i++) {
        long long f = (long long)floor(pos);
        float t = (float)(pos - (double)f);
        float l = Hermite(Sample(f - 1, 0), Sample(f, 0), Sample(f + 1, 0), Sample(f + 2, 0), t);
        float r = Hermite(Sample(f - 1, 1), Sample(f, 1), Sample(f + 1, 1), Sample(f + 2, 1), t);
        if (interleaved) {
            float* d = output->mBuffers[0].mData;
            if (ch0 == 1) {
                d[i] = 0.5f * (l + r);
            } else {
                d[i * ch0] = l;
                d[i * ch0 + 1] = r;
                for (UInt32 c = 2; c < ch0; c++) d[i * ch0 + c] = 0;
            }
        } else {
            for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
                float* d = output->mBuffers[b].mData;
                if (!d) continue;
                d[i] = b == 0 ? l : b == 1 ? r : 0;
            }
        }
        pos += ratio;
    }
    gReadPos = pos;
    return 0;
}

static double NominalRate(AudioDeviceID d) {
    Float64 r = 0;
    UInt32 s = sizeof r;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(d, &a, 0, NULL, &s, &r);
    return r > 0 ? r : 48000;
}

static UInt32 BufferFrames(AudioDeviceID d, AudioObjectPropertyScope scope) {
    UInt32 v = 512, s = sizeof v;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize, scope, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(d, &a, 0, NULL, &s, &v);
    return v;
}

static void SetBufferFrames(AudioDeviceID d, UInt32 frames) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof frames, &frames);
}

OSStatus halo_forward_start(AudioDeviceID source, AudioDeviceID destination) {
    halo_forward_stop();
    gSource = source;
    gDest = destination;
    gSourceRate = NominalRate(source);
    gDestRate = NominalRate(destination);
    gBaseRatio = gSourceRate / gDestRate;

    // Small buffers on the virtual side keep the forwarding delay low; the speaker keeps its own.
    SetBufferFrames(source, 256);
    UInt32 inFrames = BufferFrames(source, kAudioObjectPropertyScopeInput);
    UInt32 outFrames = BufferFrames(destination, kAudioObjectPropertyScopeOutput);
    // Enough to cover one input chunk arriving just after an output callback, plus jitter.
    gTarget = inFrames + outFrames * gBaseRatio * 0.5 + 0.004 * gSourceRate;

    atomic_store(&gWritten, 0);
    gReadPos = 0;
    gFill = 0;
    gPrimed = 0;
    atomic_store(&gUnderruns, 0);
    atomic_store(&gFillMs, 0);
    memset(gRing, 0, sizeof gRing);

    OSStatus e = AudioDeviceCreateIOProcID(source, InputProc, NULL, &gInProc);
    if (e) { gInProc = NULL; return e; }
    e = AudioDeviceCreateIOProcID(destination, OutputProc, NULL, &gOutProc);
    if (e) { halo_forward_stop(); return e; }
    e = AudioDeviceStart(source, gInProc);
    if (e) { halo_forward_stop(); return e; }
    e = AudioDeviceStart(destination, gOutProc);
    if (e) { halo_forward_stop(); return e; }
    atomic_store(&gRunning, 1);
    return 0;
}

void halo_forward_stop(void) {
    atomic_store(&gRunning, 0);
    if (gInProc) {
        AudioDeviceStop(gSource, gInProc);
        AudioDeviceDestroyIOProcID(gSource, gInProc);
        gInProc = NULL;
    }
    if (gOutProc) {
        AudioDeviceStop(gDest, gOutProc);
        AudioDeviceDestroyIOProcID(gDest, gOutProc);
        gOutProc = NULL;
    }
}

int halo_forward_running(void) { return atomic_load(&gRunning); }
double halo_forward_buffer_ms(void) { return atomic_load_explicit(&gFillMs, memory_order_relaxed); }
unsigned halo_forward_underruns(void) { return atomic_load(&gUnderruns); }
