#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Carbon/Carbon.h>
typedef struct {size_t w,h,pw,ph;double hz;uint32_t flags,id;} TestMode;
static TestMode saved={1920,1080,3840,2160,30,7,67},drift={1920,1080,1920,1080,120,7,64},fresh={1920,1080,3840,2160,30,7,67};
static TestMode *current=&drift;
static BOOL topologyOK=YES,onlineOK=YES,available=YES,configureOK=YES;
static unsigned begins,writes,commits,cancels;
static CGDirectDisplayID TestMain(void){return topologyOK?1:3;}
static CGError TestOnline(uint32_t max,CGDirectDisplayID *ids,uint32_t *n){(void)max;ids[0]=1;ids[1]=2;ids[2]=99;*n=onlineOK?3:2;return kCGErrorSuccess;}
static CGDirectDisplayID TestMirror(CGDirectDisplayID d){return d==2?1:0;}
static uint32_t TestActive(CGDirectDisplayID d){(void)d;return 1;}
static CGRect TestBounds(CGDirectDisplayID d){(void)d;return CGRectMake(0,0,1920,1080);}
static CGDisplayModeRef TestCopy(CGDirectDisplayID d){(void)d;return (CGDisplayModeRef)current;}
static CFArrayRef TestAll(CGDirectDisplayID d,CFDictionaryRef options){(void)d;(void)options;const void *v[]={&fresh};return CFArrayCreate(NULL,v,available?1:0,NULL);}
static CGError TestBegin(CGDisplayConfigRef *c){begins++;*c=(CGDisplayConfigRef)1;return kCGErrorSuccess;}
static CGError TestConfigure(CGDisplayConfigRef c,CGDirectDisplayID d,CGDisplayModeRef m,CFDictionaryRef o){(void)c;(void)o;writes++;if(d!=1 || m!=(CGDisplayModeRef)&fresh || !configureOK)return kCGErrorFailure;current=&fresh;return kCGErrorSuccess;}
static CGError TestComplete(CGDisplayConfigRef c,CGConfigureOption o){(void)c;(void)o;commits++;return kCGErrorSuccess;}
static CGError TestCancel(CGDisplayConfigRef c){(void)c;cancels++;return kCGErrorSuccess;}
#define CGMainDisplayID TestMain
#define CGGetOnlineDisplayList TestOnline
#define CGDisplayMirrorsDisplay TestMirror
#define CGDisplayIsActive TestActive
#define CGDisplayBounds TestBounds
#define CGDisplayCopyDisplayMode TestCopy
#define CGDisplayCopyAllDisplayModes TestAll
#define CGDisplayModeGetWidth(m) (((TestMode *)(m))->w)
#define CGDisplayModeGetHeight(m) (((TestMode *)(m))->h)
#define CGDisplayModeGetPixelWidth(m) (((TestMode *)(m))->pw)
#define CGDisplayModeGetPixelHeight(m) (((TestMode *)(m))->ph)
#define CGDisplayModeGetRefreshRate(m) (((TestMode *)(m))->hz)
#define CGDisplayModeGetIOFlags(m) (((TestMode *)(m))->flags)
#define CGDisplayModeGetIODisplayModeID(m) (((TestMode *)(m))->id)
#define CGDisplayModeRetain(m) (m)
#define CGDisplayModeRelease(m) ((void)(m))
#define CGBeginDisplayConfiguration TestBegin
#define CGConfigureDisplayWithDisplayMode TestConfigure
#define CGCompleteDisplayConfiguration TestComplete
#define CGCancelDisplayConfiguration TestCancel
#define main ProductionMain
#include "../DisplaySenderHelper/DisplaySenderHelper.m"
#undef main
static void Reset(void){
  originalID=1;ownedID=99;baselineCount=2;topologyOK=onlineOK=available=configureOK=YES;
  current=&drift;begins=writes=commits=cancels=0;atomic_store(&topologyArmed,false);
  for(unsigned i=0;i<2;i++){baseline[i].id=i+1;baseline[i].mirror=i?1:0;baseline[i].active=true;baseline[i].bounds=CGRectMake(0,0,1920,1080);baseline[i].mode=(CGDisplayModeRef)&saved;baseline[i].pixelWidth=3840;baseline[i].pixelHeight=2160;}
}
int main(int argc,const char **argv){@autoreleasepool {
  if(argc!=2 || strcmp(argv[1],"--selftest"))return 2;
  int failed=0;
#define EXPECT(c,n) do{BOOL ok=(c);fprintf(stderr,"%s %s\n",ok?"PASS":"FAIL",n);failed+=!ok;}while(0)
  Reset();EXPECT(RestoreStartupRootModes() && writes==1 && commits==1 && current==&fresh,"fresh-root-mode-restores-drift");
  Reset();fresh.id=88;EXPECT(RestoreStartupRootModes() && writes==1 && !BaselinePreserved(YES),"fresh-selection-ignores-id-but-strict-readback-rejects-id-drift");fresh.id=67;
  Reset();current=&saved;EXPECT(RestoreStartupRootModes() && !begins && !writes,"no-drift-no-transaction");
  Reset();topologyOK=NO;EXPECT(!RestoreStartupRootModes() && !writes,"changed-main-no-write");
  Reset();onlineOK=NO;EXPECT(!RestoreStartupRootModes() && !writes,"changed-online-no-write");
  Reset();baseline[1].mirror=0;EXPECT(!RestoreStartupRootModes() && !writes,"changed-mirror-no-write");
  Reset();baseline[1].active=false;EXPECT(!RestoreStartupRootModes() && !writes,"changed-active-no-write");
  Reset();baseline[1].bounds.origin.x=10;EXPECT(!RestoreStartupRootModes() && !writes,"changed-bounds-no-write");
  Reset();atomic_store(&topologyArmed,true);EXPECT(!RestoreStartupRootModes() && !writes,"armed-no-write");
  Reset();available=NO;EXPECT(!RestoreStartupRootModes() && !writes,"missing-fresh-match-no-write");
  Reset();fresh.flags=8;EXPECT(!RestoreStartupRootModes() && !writes,"different-ioflags-no-write");fresh.flags=7;
  Reset();configureOK=NO;EXPECT(!RestoreStartupRootModes() && cancels==1 && !commits,"configure-failure-cancels");
  fprintf(stderr,"%s display baseline recovery (offline CoreGraphics doubles)\n",failed?"FAIL":"PASS");return failed?5:0;
}}
