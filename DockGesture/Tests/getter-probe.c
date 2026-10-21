// Standalone research only. Not part of production bridge.
// Getter ABI inspected in CGEventHIDEventBridge.m declaration:
// extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef); Copy ownership.
// No MMF implementation or pointer offsets copied.
#include "../DockGestureBridge.h"
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    typedef CFTypeRef (*CopyFn)(CGEventRef);
    CopyFn copy = (CopyFn)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
    printf("getter exported: %s\n", copy ? "yes" : "no");
    if (!copy) return 0;
    CGEventRef e = DGMakeExperimentalVerticalEvent(2, 0.25, 0, 1);
    if (!e) { puts("fixture unavailable"); return 0; }
    CFTypeRef hid = copy(e);
    printf("synthetic vertical attached HID: %s\n", hid ? "nonnull" : "nil");
    puts("HID type: unknown (SDK declaration unavailable; no guessed getter ABI)");
    if (hid) CFRelease(hid);
    CFRelease(e);
    return 0;
}
