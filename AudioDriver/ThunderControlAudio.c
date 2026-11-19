// Loopback HAL output device for ThunderControl. Apps play into the device's
// output side; ThunderControl reads the same samples from its input side and
// sends them to the connected Mac. The device exists only while ThunderControl
// has set a peer name through the plug-in's custom property.
#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStreamOut = 3, kObjStreamIn = 4 };
// Custom plug-in property: CFString peer name. Empty string removes the device.
enum { kPeerNameSelector = 'tcpn' };

#define kRate 48000.0
#define kChannels 2
#define kPeriod 16384
#define kRing 16384
#define kDeviceUID "local.experimental.ThunderControl.Audio"

static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount = 1;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static CFStringRef gDeviceName;  // NULL while no peer is connected
static pid_t gOwnerPID;
static UInt32 gIORunning;
static UInt64 gAnchorHostTime, gTimestampCount;
static Float64 gTicksPerFrame;
static float gRing[kRing * kChannels];

static AudioStreamBasicDescription Format(void) {
  AudioStreamBasicDescription f = {0};
  f.mSampleRate = kRate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
  f.mBytesPerPacket = f.mBytesPerFrame = sizeof(float) * kChannels;
  f.mFramesPerPacket = 1;
  f.mChannelsPerFrame = kChannels;
  f.mBitsPerChannel = 32;
  return f;
}

static Boolean DevicePresent(void) {
  pthread_mutex_lock(&gLock);
  Boolean present = gDeviceName != NULL;
  pthread_mutex_unlock(&gLock);
  return present;
}

// PropertiesChanged must not run on the thread that is servicing a HAL call.
static void NotifyLater(AudioObjectID obj, AudioObjectPropertySelector a, AudioObjectPropertySelector b) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    AudioObjectPropertyAddress addrs[2] = {
      { a, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
      { b, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain } };
    if (gHost) gHost->PropertiesChanged(gHost, obj, b ? 2 : 1, addrs);
  });
}

static void SetPeerName(CFStringRef name, pid_t owner) {
  pthread_mutex_lock(&gLock);
  Boolean wasPresent = gDeviceName != NULL;
  if (gDeviceName) CFRelease(gDeviceName);
  gDeviceName = NULL;
  if (name && CFStringGetLength(name) > 0) {
    gDeviceName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (ThunderControl)"), name);
    gOwnerPID = owner;
  } else {
    gOwnerPID = 0;
  }
  Boolean present = gDeviceName != NULL;
  pthread_mutex_unlock(&gLock);
  if (present && wasPresent) NotifyLater(kObjDevice, kAudioObjectPropertyName, 0);
  if (wasPresent && !present) NotifyLater(kObjDevice, kAudioDevicePropertyDeviceIsAlive, 0);
  if (present != wasPresent) NotifyLater(kObjPlugIn, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyOwnedObjects);
}

// If ThunderControl quits or crashes without clearing the name, remove the
// device so apps do not keep playing into a Mac nobody is listening to.
static void WatchOwner(void) {
  dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
  dispatch_source_set_event_handler(t, ^{
    pthread_mutex_lock(&gLock);
    pid_t owner = gOwnerPID;
    pthread_mutex_unlock(&gLock);
    if (owner > 0 && kill(owner, 0) != 0 && errno == ESRCH) SetPeerName(NULL, 0);
  });
  dispatch_resume(t);
}

static HRESULT QueryInterface(void *drv, REFIID iid, LPVOID *out);
static ULONG AddRef(void *drv) { return ++gRefCount; }
static ULONG Release(void *drv) { return gRefCount ? --gRefCount : 0; }
static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef h) {
  gHost = h;
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  gTicksPerFrame = (1e9 * tb.denom / tb.numer) / kRate;
  WatchOwner();
  return 0;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return 0; }
static OSStatus RemoveClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return 0; }
static OSStatus PerformConfig(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { return 0; }
static OSStatus AbortConfig(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { return 0; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
  switch (obj) {
  case kObjPlugIn:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyResourceBundle: case kAudioObjectPropertyCustomPropertyInfoList:
    case kPeerNameSelector: return true;
    }
    return false;
  case kObjDevice:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyPreferredChannelsForStereo: return true;
    }
    return false;
  case kObjStreamOut: case kObjStreamIn:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: return true;
    }
    return false;
  }
  return false;
}

static OSStatus IsSettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
  if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
  *out = obj == kObjPlugIn && a->mSelector == kPeerNameSelector;
  return 0;
}

static UInt32 StreamsFor(AudioObjectPropertyScope s, AudioObjectID ids[2]) {
  UInt32 n = 0;
  if (s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeInput) ids[n++] = kObjStreamIn;
  if (s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeOutput) ids[n++] = kObjStreamOut;
  return n;
}

#define PUT(T, v) do { if (size < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T *)data = (v); *used = sizeof(T); return 0; } while (0)

static OSStatus GetData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                        UInt32 qs, const void *q, UInt32 size, UInt32 *used, void *data) {
  AudioObjectID ids[2]; UInt32 n;
  switch (obj) {
  case kObjPlugIn:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("ThunderControl"));
    case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
      if (!DevicePresent()) { *used = 0; return 0; }
      PUT(AudioObjectID, kObjDevice);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
      CFStringRef uid = qs == sizeof(CFStringRef) ? *(CFStringRef *)q : NULL;
      Boolean match = uid && DevicePresent() && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo;
      PUT(AudioObjectID, match ? kObjDevice : kAudioObjectUnknown);
    }
    case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
    case kAudioObjectPropertyCustomPropertyInfoList: {
      AudioServerPlugInCustomPropertyInfo info = { kPeerNameSelector, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone };
      PUT(AudioServerPlugInCustomPropertyInfo, info);
    }
    case kPeerNameSelector: {
      pthread_mutex_lock(&gLock);
      CFStringRef name = gDeviceName ? CFStringCreateCopy(NULL, gDeviceName) : CFSTR("");
      pthread_mutex_unlock(&gLock);
      PUT(CFStringRef, name);
    }
    }
    break;
  case kObjDevice:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjPlugIn);
    case kAudioObjectPropertyName: {
      pthread_mutex_lock(&gLock);
      CFStringRef name = gDeviceName ? CFStringCreateCopy(NULL, gDeviceName) : CFSTR("ThunderControl");
      pthread_mutex_unlock(&gLock);
      PUT(CFStringRef, name);
    }
    case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("ThunderControl"));
    case kAudioDevicePropertyDeviceUID: PUT(CFStringRef, CFSTR(kDeviceUID));
    case kAudioDevicePropertyModelUID: PUT(CFStringRef, CFSTR("local.experimental.ThunderControl.Audio.Model"));
    case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: PUT(AudioObjectID, kObjDevice);
    case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, DevicePresent());
    case kAudioDevicePropertyDeviceIsRunning: PUT(UInt32, gIORunning > 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, 1);
    // System sounds stay on the local Mac.
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
    case kAudioDevicePropertyLatency: PUT(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
    case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
      n = StreamsFor(a->mScope, ids);
      if (size < n * sizeof(AudioObjectID)) n = size / sizeof(AudioObjectID);
      memcpy(data, ids, n * sizeof(AudioObjectID)); *used = n * sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyControlList: *used = 0; return 0;
    case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: { AudioValueRange r = {kRate, kRate}; PUT(AudioValueRange, r); }
    case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kPeriod);
    case kAudioDevicePropertyPreferredChannelsForStereo:
      if (size < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
      ((UInt32 *)data)[0] = 1; ((UInt32 *)data)[1] = 2; *used = 2 * sizeof(UInt32); return 0;
    }
    break;
  case kObjStreamOut: case kObjStreamIn:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjDevice);
    case kAudioObjectPropertyOwnedObjects: *used = 0; return 0;
    case kAudioStreamPropertyIsActive: PUT(UInt32, 1);
    case kAudioStreamPropertyDirection: PUT(UInt32, obj == kObjStreamIn ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
      PUT(UInt32, obj == kObjStreamIn ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
    case kAudioStreamPropertyLatency: PUT(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, Format());
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
      AudioStreamRangedDescription r = { Format(), { kRate, kRate } };
      PUT(AudioStreamRangedDescription, r);
    }
    }
    break;
  }
  return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                            UInt32 qs, const void *q, UInt32 *out) {
  if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
  switch (a->mSelector) {
  case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyStreams:
    if (obj == kObjPlugIn) { *out = DevicePresent() ? sizeof(AudioObjectID) : 0; return 0; }
    if (obj == kObjDevice) { AudioObjectID ids[2]; *out = StreamsFor(a->mScope, ids) * sizeof(AudioObjectID); return 0; }
    *out = 0; return 0;
  case kAudioObjectPropertyControlList: *out = 0; return 0;
  case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
  case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle: case kPeerNameSelector:
    *out = sizeof(CFStringRef); return 0;
  case kAudioObjectPropertyCustomPropertyInfoList: *out = sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
  case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return 0;
  }
  UInt8 scratch[128]; UInt32 used = 0;
  OSStatus e = GetData(d, obj, pid, a, qs, q, sizeof scratch, &used, scratch);
  *out = used;
  return e;
}

static OSStatus SetData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                        UInt32 qs, const void *q, UInt32 size, const void *data) {
  if (obj != kObjPlugIn || a->mSelector != kPeerNameSelector) return kAudioHardwareUnknownPropertyError;
  if (size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
  CFStringRef name = *(CFStringRef *)data;
  if (name && CFGetTypeID(name) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
  if (name && CFStringGetLength(name) > 96) return kAudioHardwareIllegalOperationError;
  SetPeerName(name, pid);
  return 0;
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client) {
  pthread_mutex_lock(&gLock);
  if (gIORunning++ == 0) { gAnchorHostTime = mach_absolute_time(); gTimestampCount = 0; memset(gRing, 0, sizeof gRing); }
  pthread_mutex_unlock(&gLock);
  return 0;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client) {
  pthread_mutex_lock(&gLock);
  if (gIORunning) gIORunning--;
  pthread_mutex_unlock(&gLock);
  return 0;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, Float64 *st, UInt64 *ht, UInt64 *seed) {
  UInt64 now = mach_absolute_time();
  Float64 ticksPerPeriod = gTicksPerFrame * kPeriod;
  UInt64 next = gAnchorHostTime + (UInt64)((gTimestampCount + 1) * ticksPerPeriod);
  if (next <= now) gTimestampCount++;
  *st = gTimestampCount * (Float64)kPeriod;
  *ht = gAnchorHostTime + (UInt64)(gTimestampCount * ticksPerPeriod);
  *seed = 1;
  return 0;
}

static OSStatus WillDoIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, UInt32 op, Boolean *will, Boolean *inPlace) {
  *will = op == kAudioServerPlugInIOOperationWriteMix || op == kAudioServerPlugInIOOperationReadInput;
  *inPlace = true;
  return 0;
}
static OSStatus BeginIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }
static OSStatus EndIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }

// Output and input share sample time, so input at time t returns what was
// mixed for output time t. Read slots are cleared so silence follows a stop.
static OSStatus DoIO(AudioServerPlugInDriverRef d, AudioObjectID obj, AudioObjectID stream, UInt32 client, UInt32 op,
                     UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *main, void *second) {
  float *buf = main;
  if (op == kAudioServerPlugInIOOperationWriteMix) {
    UInt64 t = (UInt64)ci->mOutputTime.mSampleTime;
    for (UInt32 i = 0; i < frames; i++) memcpy(&gRing[((t + i) % kRing) * kChannels], &buf[i * kChannels], sizeof(float) * kChannels);
  } else if (op == kAudioServerPlugInIOOperationReadInput) {
    UInt64 t = (UInt64)ci->mInputTime.mSampleTime;
    for (UInt32 i = 0; i < frames; i++) {
      float *slot = &gRing[((t + i) % kRing) * kChannels];
      memcpy(&buf[i * kChannels], slot, sizeof(float) * kChannels);
      memset(slot, 0, sizeof(float) * kChannels);
    }
  }
  return 0;
}

static AudioServerPlugInDriverInterface gInterface = {
  NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddClient, RemoveClient,
  PerformConfig, AbortConfig, HasProperty, IsSettable, GetDataSize, GetData, SetData,
  StartIO, StopIO, GetZeroTimeStamp, WillDoIO, BeginIO, DoIO, EndIO
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;

static HRESULT QueryInterface(void *drv, REFIID iid, LPVOID *out) {
  CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
  Boolean ok = CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID);
  CFRelease(req);
  if (!ok) { *out = NULL; return E_NOINTERFACE; }
  gRefCount++;
  *out = &gInterfacePtr;
  return S_OK;
}

void *ThunderControlAudioFactory(CFAllocatorRef alloc, CFUUIDRef type) {
  return CFEqual(type, kAudioServerPlugInTypeUUID) ? &gInterfacePtr : NULL;
}
