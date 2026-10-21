#ifndef DOCK_GESTURE_BRIDGE_H
#define DOCK_GESTURE_BRIDGE_H
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
// No event tap, capture, posting, private functions, or permission requests.
bool DGHasISCRawSuffix(CFDataRef data);
CGEventRef DGEventFromData(CFDataRef data) CF_RETURNS_RETAINED;
CGEventRef DGMakeEvent(int phase, double progress, double vx, double vy) CF_RETURNS_RETAINED;

CGEventRef DGCreateMemoryFixture(void) CF_RETURNS_RETAINED;
CGEventRef DGMakeExperimentalVerticalEvent(int phase, double progress, double vx, double vy) CF_RETURNS_RETAINED;
#endif
