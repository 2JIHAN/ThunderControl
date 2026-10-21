#include "DockGestureBridge.h"
#include <mach/mach_time.h>
#include <stdint.h>
#include <math.h>

#include <stdlib.h>
#include <string.h>
static const CGEventField kCGEventGestureSwipePositionX = 125;
static const CGEventField kCGEventGestureSwipePositionY = 126;
static const CGEventField kCGEventGestureSwipeMask = 115;
static const CGEventField kCGEventRawIOHIDPayload = 4205;
#include "Vendor/iss_payload.inc"

// Deliberately recognize ONLY the suffix form emitted by the inspected ISS
// augmentation. Do not parse undocumented arbitrary CGEvent record streams.
bool DGHasISCRawSuffix(CFDataRef data) {
    if (!data) return false;
    CFIndex length = CFDataGetLength(data);
    if (length < 4 || length > 65536) return false;
    const uint8_t *b = CFDataGetBytePtr(data);
    if (b[0] || b[1] || b[2] || b[3] != 2) return false;
    const size_t sizes[] = {
        sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData),
        sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData) + sizeof(IOHIDVelocityEventData)
    };
    for (size_t i = 0; i < 2; ++i) {
        size_t n = sizes[i];
        if ((size_t)length < n + 8) continue;
        size_t at = (size_t)length - n - 4;
        if ((((size_t)b[at] << 8) | b[at+1]) != n ||
            (((unsigned)b[at+2] << 8) | b[at+3]) != 4205) continue;
        IOHIDSystemQueueElementHeader h;
        IOHIDFluidTouchGestureData f;
        memcpy(&h, b + at + 4, sizeof(h));
        memcpy(&f, b + at + 4 + sizeof(h), sizeof(f));
        if (h.attribute_length || h.event_count != i + 1 ||
            f.base.size != sizeof(f) || f.base.type != 23 ||
            f.gesture_motion != 1 || f.gesture_flavor != 3) continue;
        if (i) {
            IOHIDVelocityEventData v;
            memcpy(&v, b + at + 4 + sizeof(h) + sizeof(f), sizeof(v));
            if (v.base.size != sizeof(v) || v.base.type != 9 || v.base.depth != 1) continue;
        }
        return true;
    }
    return false;
}
CGEventRef DGCreateMemoryFixture(void) {
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGEventSetIntegerValueField(e, 55, 30);
    CGEventSetIntegerValueField(e, 110, 23);
    CGEventSetIntegerValueField(e, 123, 1);
    CGEventSetIntegerValueField(e, 132, 2);
    CGEventSetDoubleValueField(e, 124, 0.25);
    CGEventRef result = augment_dock_swipe_event(e);
    CFRelease(e);
    return result;
}
CGEventRef DGEventFromData(CFDataRef data) {
    if (!data || CFDataGetLength(data) < 4 || CFDataGetLength(data) > 65536) return NULL;
    return CGEventCreateFromData(kCFAllocatorDefault, data);
}
static CGEventRef make_motion_event(int motion, int phase, double progress, double vx, double vy) {
    if (!isfinite(progress) || fabs(progress) > 1 || !isfinite(vx) || fabs(vx) > 10000 || !isfinite(vy) || fabs(vy) > 10000) return NULL;

    if (phase != 1 && phase != 2 && phase != 4 && phase != 8) return NULL;
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGEventSetIntegerValueField(e, 55, 30);
    CGEventSetIntegerValueField(e, 110, 23);
    CGEventSetIntegerValueField(e, 123, motion);
    CGEventSetIntegerValueField(e, 132, phase);
    CGEventSetIntegerValueField(e, 134, phase);
    CGEventSetDoubleValueField(e, 138, 3.0);
    CGEventSetDoubleValueField(e, 169, (double)mach_absolute_time());
    CGEventSetDoubleValueField(e, 125, 0.1);
    CGEventSetDoubleValueField(e, 124, progress);
    CGEventSetDoubleValueField(e, 129, vx);
    CGEventSetDoubleValueField(e, 130, vy);
    CGEventRef result = augment_dock_swipe_event(e);
    CFRelease(e);
    return result;
}

CGEventRef DGMakeEvent(int phase, double p, double x, double y) { return make_motion_event(1, phase, p, x, y); }
CGEventRef DGMakeExperimentalVerticalEvent(int phase, double p, double x, double y) { return make_motion_event(2, phase, p, x, y); }
