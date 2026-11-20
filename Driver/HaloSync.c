// Halo Sync: a virtual Core Audio output device whose only job is to report the true delay of the
// speaker behind it. Apps that keep video in step with audio (Safari, QuickTime, TV, AVFoundation
// players) hold the picture back by the latency the output device reports. Bluetooth speakers report
// far less than they really have, so video runs ahead of the sound. Halo routes the system output
// through this device, forwards the audio to the real speaker, and sets this device's latency to the
// measured end-to-end delay.
//
// The device is a stereo loopback: what apps play on its output comes back on its input, where
// Halo reads it. Latency is set by Halo through the custom property 'hlat' (milliseconds, CFNumber)
// and kept across restarts in the plug-in's storage. Volume and mute are plain state that Halo mirrors
// to the real speaker, so the volume keys keep working.
//
// Written against <CoreAudio/AudioServerPlugIn.h>, following the structure of Apple's NullAudio sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

// MARK: - Constants

#define kFactoryUUID        "88CD87B4-90B3-42BC-9379-5864E66A00A7"
#define kDeviceUID          "HaloSync_UID"
#define kDeviceModelUID     "HaloSync_ModelUID"
#define kDeviceName         "Halo Sync"
#define kManufacturer       "Halo"
#define kChannels           2
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kZeroTimeStampFrames 16384      // period of the device clock
#define kLoopFrames         65536       // loopback buffer (≈1.4 s at 48 kHz)
#define kCustomLatency      'hlat'
#define kActionRate         1
#define kActionLatency      2
#define kMinDb              (-64.0f)

enum {
    kObjectID_PlugIn  = kAudioObjectPlugInObject,
    kObjectID_Device  = 2,
    kObjectID_InStream  = 3,
    kObjectID_OutStream = 4,
    kObjectID_Volume  = 5,
    kObjectID_Mute    = 6,
};

static const Float64 kRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kRateCount (sizeof(kRates) / sizeof(kRates[0]))

// MARK: - State

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

static Float64 gSampleRate = 48000.0;
static Float64 gPendingRate = 48000.0;
static Float64 gLatencyMs = 0.0;
static Float64 gPendingLatencyMs = 0.0;
static Float32 gVolume = 1.0f;
static UInt32 gMute = 0;
static UInt32 gInActive = 1, gOutActive = 1;

static UInt32 gIOCount = 0;
static Float64 gTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;
static Float32 gLoop[kLoopFrames * kChannels];

// MARK: - Helpers

static Float64 HostTicksPerSecond(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
}

static UInt32 LatencyFrames(void) {
    Float64 f = gLatencyMs * gSampleRate / 1000.0;
    return f > 0 ? (UInt32)(f + 0.5) : 0;
}

static AudioStreamBasicDescription Format(Float64 rate) {
    AudioStreamBasicDescription d;
    memset(&d, 0, sizeof d);
    d.mSampleRate = rate;
    d.mFormatID = kAudioFormatLinearPCM;
    d.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    d.mBytesPerPacket = kBytesPerFrame;
    d.mFramesPerPacket = 1;
    d.mBytesPerFrame = kBytesPerFrame;
    d.mChannelsPerFrame = kChannels;
    d.mBitsPerChannel = 32;
    return d;
}

static Boolean IsSupportedRate(Float64 r) {
    for (UInt32 i = 0; i < kRateCount; i++) if (kRates[i] == r) return true;
    return false;
}

static Float32 ScalarToDb(Float32 s) {
    if (s <= 0.0001f) return kMinDb;
    Float32 db = 40.0f * log10f(s);
    return db < kMinDb ? kMinDb : (db > 0 ? 0 : db);
}

static Float32 DbToScalar(Float32 db) {
    if (db <= kMinDb) return 0;
    if (db > 0) db = 0;
    return powf(10.0f, db / 40.0f);
}

static void Notify(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    if (!gHost) return;
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, obj, 1, &a);
}

// MARK: - Interface declarations

static HRESULT QueryInterface(void*, REFIID, LPVOID*);
static ULONG AddRef(void*);
static ULONG Release(void*);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient,
    RemoveDeviceClient, PerformConfigChange, AbortConfigChange, HasProperty, IsPropertySettable,
    GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory and COM

void* HaloSync_Create(CFAllocatorRef allocator, CFUUIDRef requestedType);
void* HaloSync_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT QueryInterface(void* driver, REFIID iid, LPVOID* out) {
    if (driver != gDriverRef || !out) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex);
        gRefCount++;
        pthread_mutex_unlock(&gMutex);
        *out = gDriverRef;
        r = S_OK;
    }
    CFRelease(requested);
    return r;
}

static ULONG AddRef(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return r;
}

static ULONG Release(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return r;
}

// MARK: - Plug-in lifecycle

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host;
    gTicksPerFrame = HostTicksPerSecond() / gSampleRate;

    CFPropertyListRef stored = NULL;
    if (gHost->CopyFromStorage(gHost, CFSTR("latencyMs"), &stored) == 0 && stored) {
        if (CFGetTypeID(stored) == CFNumberGetTypeID()) {
            Float64 v = 0;
            CFNumberGetValue((CFNumberRef)stored, kCFNumberFloat64Type, &v);
            if (v >= 0 && v < 2000) gLatencyMs = gPendingLatencyMs = v;
        }
        CFRelease(stored);
    }
    stored = NULL;
    if (gHost->CopyFromStorage(gHost, CFSTR("sampleRate"), &stored) == 0 && stored) {
        if (CFGetTypeID(stored) == CFNumberGetTypeID()) {
            Float64 v = 0;
            CFNumberGetValue((CFNumberRef)stored, kCFNumberFloat64Type, &v);
            if (IsSupportedRate(v)) { gSampleRate = gPendingRate = v; gTicksPerFrame = HostTicksPerSecond() / v; }
        }
        CFRelease(stored);
    }
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* c) {
    (void)c;
    return (d == gDriverRef && dev == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* c) {
    (void)c;
    return (d == gDriverRef && dev == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static void Store(CFStringRef key, Float64 value) {
    if (!gHost) return;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &value);
    gHost->WriteToStorage(gHost, key, n);
    CFRelease(n);
}

static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)info;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (action == kActionRate) {
        gSampleRate = gPendingRate;
        gTicksPerFrame = HostTicksPerSecond() / gSampleRate;
    } else if (action == kActionLatency) {
        gLatencyMs = gPendingLatencyMs;
    }
    Float64 rate = gSampleRate, latency = gLatencyMs;
    pthread_mutex_unlock(&gMutex);
    if (action == kActionRate) Store(CFSTR("sampleRate"), rate);
    if (action == kActionLatency) Store(CFSTR("latencyMs"), latency);
    return 0;
}

static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)action; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

// MARK: - Properties
//
// One function answers both "how big" (out == NULL) and "give me the data".

#define REPLY(type, value) do { \
        if (out) { if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type*)out = (value); } \
        *outSize = sizeof(type); return 0; } while (0)

#define REPLY_CF(expr) do { \
        if (out) { if (inSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError; *(CFTypeRef*)out = (expr); } \
        *outSize = sizeof(CFTypeRef); return 0; } while (0)

static OSStatus ReplyIDs(const AudioObjectID* ids, UInt32 count, UInt32 inSize, UInt32* outSize, void* out) {
    if (out) {
        UInt32 n = inSize / sizeof(AudioObjectID);
        if (n > count) n = count;
        memcpy(out, ids, n * sizeof(AudioObjectID));
        *outSize = n * sizeof(AudioObjectID);
    } else {
        *outSize = count * sizeof(AudioObjectID);
    }
    return 0;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                               UInt32 inSize, UInt32* outSize, void* out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: REPLY(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: REPLY(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: REPLY(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: REPLY_CF(CFSTR(kManufacturer));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[] = { kObjectID_Device };
        return ReplyIDs(ids, 1, inSize, outSize, out);
    }
    case kAudioPlugInPropertyBoxList: *outSize = 0; return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qSize < sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef*)q;
        AudioObjectID r = (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) ? kObjectID_Device : kAudioObjectUnknown;
        REPLY(AudioObjectID, r);
    }
    case kAudioPlugInPropertyResourceBundle: REPLY_CF(CFSTR(""));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* out) {
    AudioObjectPropertyScope scope = a->mScope;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: REPLY(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: REPLY(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: REPLY(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName: REPLY_CF(CFSTR(kDeviceName));
    case kAudioObjectPropertyManufacturer: REPLY_CF(CFSTR(kManufacturer));
    case kAudioDevicePropertyDeviceUID: REPLY_CF(CFSTR(kDeviceUID));
    case kAudioDevicePropertyModelUID: REPLY_CF(CFSTR(kDeviceModelUID));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams: {
        Boolean controls = a->mSelector == kAudioObjectPropertyOwnedObjects;
        AudioObjectID ids[4];
        UInt32 n = 0;
        if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) ids[n++] = kObjectID_InStream;
        if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) {
            ids[n++] = kObjectID_OutStream;
            if (controls) { ids[n++] = kObjectID_Volume; ids[n++] = kObjectID_Mute; }
        }
        return ReplyIDs(ids, n, inSize, outSize, out);
    }
    case kAudioObjectPropertyControlList: {
        AudioObjectID ids[] = { kObjectID_Volume, kObjectID_Mute };
        return ReplyIDs(ids, 2, inSize, outSize, out);
    }
    case kAudioDevicePropertyTransportType: REPLY(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID ids[] = { kObjectID_Device };
        return ReplyIDs(ids, 1, inSize, outSize, out);
    }
    case kAudioDevicePropertyClockDomain: REPLY(UInt32, 0);
    case kAudioDevicePropertyClockIsStable: REPLY(UInt32, 1);
    case kAudioDevicePropertyDeviceIsAlive: REPLY(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gMutex);
        UInt32 running = gIOCount > 0;
        pthread_mutex_unlock(&gMutex);
        REPLY(UInt32, running);
    }
    // Usable as the speaker, never picked as the default microphone or for alert sounds.
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: REPLY(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: REPLY(UInt32, 0);
    case kAudioDevicePropertyIsHidden: REPLY(UInt32, 0);
    case kAudioDevicePropertyLatency: {
        pthread_mutex_lock(&gMutex);
        UInt32 frames = scope == kAudioObjectPropertyScopeOutput ? LatencyFrames() : 0;
        pthread_mutex_unlock(&gMutex);
        REPLY(UInt32, frames);
    }
    case kAudioDevicePropertySafetyOffset: REPLY(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: REPLY(UInt32, kZeroTimeStampFrames);
    case kAudioDevicePropertyNominalSampleRate: {
        pthread_mutex_lock(&gMutex);
        Float64 r = gSampleRate;
        pthread_mutex_unlock(&gMutex);
        REPLY(Float64, r);
    }
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        UInt32 count = kRateCount;
        if (out) {
            UInt32 n = inSize / sizeof(AudioValueRange);
            if (n > count) n = count;
            AudioValueRange* r = out;
            for (UInt32 i = 0; i < n; i++) { r[i].mMinimum = kRates[i]; r[i].mMaximum = kRates[i]; }
            *outSize = n * sizeof(AudioValueRange);
        } else {
            *outSize = count * sizeof(AudioValueRange);
        }
        return 0;
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        *outSize = 2 * sizeof(UInt32);
        if (out) {
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)out)[0] = 1; ((UInt32*)out)[1] = 2;
        }
        return 0;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
        *outSize = size;
        if (out) {
            if (inSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = out;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        }
        return 0;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        *outSize = sizeof(AudioServerPlugInCustomPropertyInfo);
        if (out) {
            if (inSize < sizeof(AudioServerPlugInCustomPropertyInfo)) { *outSize = 0; return 0; }
            AudioServerPlugInCustomPropertyInfo* i = out;
            i->mSelector = kCustomLatency;
            i->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            i->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
        }
        return 0;
    }
    case kCustomLatency: {
        pthread_mutex_lock(&gMutex);
        Float64 ms = gLatencyMs;
        pthread_mutex_unlock(&gMutex);
        REPLY_CF(CFNumberCreate(NULL, kCFNumberFloat64Type, &ms));
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* out) {
    Boolean input = obj == kObjectID_InStream;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: REPLY(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: REPLY(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: REPLY(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
    case kAudioStreamPropertyIsActive: {
        pthread_mutex_lock(&gMutex);
        UInt32 v = input ? gInActive : gOutActive;
        pthread_mutex_unlock(&gMutex);
        REPLY(UInt32, v);
    }
    case kAudioStreamPropertyDirection: REPLY(UInt32, input ? 1 : 0);
    case kAudioStreamPropertyTerminalType: REPLY(UInt32, input ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: REPLY(UInt32, 1);
    case kAudioStreamPropertyLatency: REPLY(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        pthread_mutex_lock(&gMutex);
        AudioStreamBasicDescription f = Format(gSampleRate);
        pthread_mutex_unlock(&gMutex);
        REPLY(AudioStreamBasicDescription, f);
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        UInt32 count = kRateCount;
        if (out) {
            UInt32 n = inSize / sizeof(AudioStreamRangedDescription);
            if (n > count) n = count;
            AudioStreamRangedDescription* r = out;
            for (UInt32 i = 0; i < n; i++) {
                r[i].mFormat = Format(kRates[i]);
                r[i].mSampleRateRange.mMinimum = kRates[i];
                r[i].mSampleRateRange.mMaximum = kRates[i];
            }
            *outSize = n * sizeof(AudioStreamRangedDescription);
        } else {
            *outSize = count * sizeof(AudioStreamRangedDescription);
        }
        return 0;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ControlProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* out) {
    Boolean volume = obj == kObjectID_Volume;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: REPLY(AudioClassID, volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: REPLY(AudioClassID, volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: REPLY(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
    case kAudioControlPropertyScope: REPLY(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: REPLY(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    default: break;
    }
    if (volume) {
        switch (a->mSelector) {
        case kAudioLevelControlPropertyScalarValue: {
            pthread_mutex_lock(&gMutex);
            Float32 v = gVolume;
            pthread_mutex_unlock(&gMutex);
            REPLY(Float32, v);
        }
        case kAudioLevelControlPropertyDecibelValue: {
            pthread_mutex_lock(&gMutex);
            Float32 v = ScalarToDb(gVolume);
            pthread_mutex_unlock(&gMutex);
            REPLY(Float32, v);
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange r = { kMinDb, 0 };
            REPLY(AudioValueRange, r);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (out) { if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; *(Float32*)out = ScalarToDb(*(Float32*)out); }
            *outSize = sizeof(Float32); return 0;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (out) { if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; *(Float32*)out = DbToScalar(*(Float32*)out); }
            *outSize = sizeof(Float32); return 0;
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (a->mSelector == kAudioBooleanControlPropertyValue) {
        pthread_mutex_lock(&gMutex);
        UInt32 v = gMute;
        pthread_mutex_unlock(&gMutex);
        REPLY(UInt32, v);
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                         UInt32 inSize, UInt32* outSize, void* out) {
    switch (obj) {
    case kObjectID_PlugIn: return PlugInProperty(a, qSize, q, inSize, outSize, out);
    case kObjectID_Device: return DeviceProperty(a, inSize, outSize, out);
    case kObjectID_InStream:
    case kObjectID_OutStream: return StreamProperty(obj, a, inSize, outSize, out);
    case kObjectID_Volume:
    case kObjectID_Mute: return ControlProperty(obj, a, inSize, outSize, out);
    default: return kAudioHardwareBadObjectError;
    }
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || !a) return false;
    // Qualified look-ups need a qualifier to compute their reply, but they exist all the same.
    if (obj == kObjectID_PlugIn && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) return true;
    UInt32 size = 0;
    return Property(obj, a, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    (void)pid;
    if (d != gDriverRef || !a || !out) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (obj) {
    case kObjectID_Device:
        *out = a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kCustomLatency;
        break;
    case kObjectID_InStream:
    case kObjectID_OutStream:
        *out = a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat
            || a->mSelector == kAudioStreamPropertyPhysicalFormat;
        break;
    case kObjectID_Volume:
        *out = a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue;
        break;
    case kObjectID_Mute:
        *out = a->mSelector == kAudioBooleanControlPropertyValue;
        break;
    default:
        *out = false;
    }
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                    UInt32 qSize, const void* q, UInt32* outSize) {
    (void)pid;
    if (d != gDriverRef || !a || !outSize) return kAudioHardwareIllegalOperationError;
    if (obj == kObjectID_PlugIn && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
        *outSize = sizeof(AudioObjectID);
        return 0;
    }
    return Property(obj, a, qSize, q, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qSize, const void* q, UInt32 inSize, UInt32* outSize, void* out) {
    (void)pid;
    if (d != gDriverRef || !a || !outSize || !out) return kAudioHardwareIllegalOperationError;
    return Property(obj, a, qSize, q, inSize, outSize, out);
}

static OSStatus RequestRate(Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gMutex);
    Boolean same = rate == gSampleRate;
    gPendingRate = rate;
    pthread_mutex_unlock(&gMutex);
    if (same) return 0;
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, kActionRate, NULL);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qSize, const void* q, UInt32 inSize, const void* in) {
    (void)pid; (void)qSize; (void)q;
    if (d != gDriverRef || !a || !in) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kObjectID_Device:
        if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
            if (inSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            return RequestRate(*(const Float64*)in);
        }
        if (a->mSelector == kCustomLatency) {
            if (inSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            CFPropertyListRef v = *(const CFPropertyListRef*)in;
            if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
            Float64 ms = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberFloat64Type, &ms);
            if (ms < 0 || ms > 2000) return kAudioHardwareIllegalOperationError;
            pthread_mutex_lock(&gMutex);
            Boolean same = fabs(ms - gLatencyMs) < 0.5;
            gPendingLatencyMs = ms;
            pthread_mutex_unlock(&gMutex);
            if (same) return 0;
            return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, kActionLatency, NULL);
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_InStream:
    case kObjectID_OutStream:
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            if (inSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gMutex);
            if (obj == kObjectID_InStream) gInActive = *(const UInt32*)in != 0; else gOutActive = *(const UInt32*)in != 0;
            pthread_mutex_unlock(&gMutex);
            Notify(obj, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal);
            return 0;
        }
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* f = in;
            AudioStreamBasicDescription want = Format(f->mSampleRate);
            if (f->mFormatID != want.mFormatID || f->mChannelsPerFrame != want.mChannelsPerFrame
                || f->mBitsPerChannel != want.mBitsPerChannel || (f->mFormatFlags & kAudioFormatFlagIsFloat) == 0)
                return kAudioDeviceUnsupportedFormatError;
            return RequestRate(f->mSampleRate);
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Volume: {
        if (inSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 v = *(const Float32*)in;
        Float32 scalar = a->mSelector == kAudioLevelControlPropertyScalarValue ? v
            : a->mSelector == kAudioLevelControlPropertyDecibelValue ? DbToScalar(v) : -1;
        if (scalar < 0) return kAudioHardwareUnknownPropertyError;
        if (scalar > 1) scalar = 1;
        pthread_mutex_lock(&gMutex);
        gVolume = scalar;
        pthread_mutex_unlock(&gMutex);
        AudioObjectPropertyAddress changed[2] = {
            { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        gHost->PropertiesChanged(gHost, kObjectID_Volume, 2, changed);
        return 0;
    }
    case kObjectID_Mute:
        if (a->mSelector != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
        if (inSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gMutex);
        gMute = *(const UInt32*)in != 0;
        pthread_mutex_unlock(&gMutex);
        Notify(kObjectID_Mute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
        return 0;
    default:
        return kAudioHardwareBadObjectError;
    }
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount == 0) {
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gLoop, 0, sizeof gLoop);
    }
    gIOCount++;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    Float64 ticksPerPeriod = gTicksPerFrame * kZeroTimeStampFrames;
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerPeriod);
    if (next <= now) gTimeStampCount++;
    *outSampleTime = (Float64)(gTimeStampCount * kZeroTimeStampFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                  Boolean* outWill, Boolean* outInPlace) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWill) *outWill = will;
    if (outInPlace) *outInPlace = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo* cycle) {
    (void)client; (void)op; (void)frames; (void)cycle;
    return (d == gDriverRef && dev == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames,
                               const AudioServerPlugInIOCycleInfo* cycle) {
    (void)client; (void)op; (void)frames; (void)cycle;
    return (d == gDriverRef && dev == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

// Output frames are stored at their sample time; the input reads the same sample times back (which the
// HAL always asks for after they were written) and clears them, so a stopped player turns into silence.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client,
                              UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* main, void* secondary) {
    (void)client; (void)stream; (void)secondary;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!main || frames == 0) return 0;
    Float32* buf = main;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        if (cycle->mOutputTime.mSampleTime < 0) return 0;
        UInt64 start = (UInt64)cycle->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) {
            UInt64 k = ((start + i) % kLoopFrames) * kChannels;
            gLoop[k] = buf[i * kChannels];
            gLoop[k + 1] = buf[i * kChannels + 1];
        }
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        if (cycle->mInputTime.mSampleTime < 0) { memset(buf, 0, frames * kBytesPerFrame); return 0; }
        UInt64 start = (UInt64)cycle->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) {
            UInt64 k = ((start + i) % kLoopFrames) * kChannels;
            buf[i * kChannels] = gLoop[k];
            buf[i * kChannels + 1] = gLoop[k + 1];
            gLoop[k] = 0;
            gLoop[k + 1] = 0;
        }
    }
    return 0;
}
