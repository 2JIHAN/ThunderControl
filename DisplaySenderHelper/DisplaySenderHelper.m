#import <CoreText/CoreText.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <poll.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <sys/wait.h>
#import <errno.h>
#import <assert.h>
#import <pthread.h>
#import <limits.h>
#import <math.h>
#import <time.h>
#import <stdarg.h>

// Private interfaces isolated in a process-owned display helper. See notices.
@interface CGVirtualDisplayDescriptor:NSObject
@property unsigned int vendorID,productID,serialNum,serialNumber,maxPixelsWide,maxPixelsHigh;
@property(strong) NSString *name;
@property CGSize sizeInMillimeters;
@property CGPoint redPrimary,greenPrimary,bluePrimary,whitePoint;
@property(strong) dispatch_queue_t queue;
@end
@interface CGVirtualDisplayMode:NSObject
-(id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings:NSObject
@property unsigned int hiDPI,rotation;
@property(strong) NSArray *modes;
@end
@interface CGVirtualDisplay:NSObject
-(id)initWithDescriptor:(CGVirtualDisplayDescriptor*)descriptor;
-(BOOL)applySettings:(CGVirtualDisplaySettings*)settings;
@property(readonly) unsigned int displayID;
@end

// Bounded security/lifecycle boundaries (see RELEASE-0.8.20 notes):
//  * Supports 1..7 independent physical displays plus their mirror sets, total
//    online including the OWNED virtual display must stay <=8.
//  * PRESERVES physical display settings. Instantiating a private
//    CGVirtualDisplay perturbs the pre-create physical mirror set as an OS
//    side effect (observed field-wise: main/active/mirrors/bounds/modeIDs/
//    pixelSizes all flip). To undo that side effect we snapshot the
//    authoritative pre-create state (per display: id, mirror relationship,
//    active, bounds, retained CGDisplayMode, pixel size) and REASSERT each
//    display's own pre-create mode + mirrorOf + origin inside the SAME
//    CGBegin/Complete transaction that configures the owned virtual. Mirror
//    relationships are reasserted field-by-field, not forced to any topology
//    (no hardcoded "all mirror-to-main").
//    Transaction order is the proven 0.8.19 path generalized to multiple
//    pre-create roots (no mode writes; mode writes on inactive aliases are
//    rejected by CoreGraphics, and the OS restores modes once the mirror
//    group's root is restored):
//      1) mirrorOf(NULL) for every pre-create ROOT (unmirror the OS-induced
//         perturbation but leave aliases alone until step 3)
//      2) origin for every pre-create ROOT at its pre-create bounds.origin
//      3) mirrorOf(root) for every pre-create ALIAS (re-attach to the SAME
//         pre-create root, not forced-to-main)
//      4) owned: mirrorOf(NULL) + validated saved origin or outside originalUnion
//    CGConfigureDisplayOrigin on a currently-mirrored display removes it
//    from the mirror set, so aliases are never given origin writes;
//    aliases inherit position from their re-attached root.
//  * ID-set guard requires the online set to equal baselineIDs union
//    {ownedID} exactly before the reassertion transaction. External hotplug
//    ADDITIONS are rejected (we don't clobber an unknown display's state)
//    and external REMOVALS are rejected (we can't preserve what's gone).
//  * Setup commit uses kCGConfigureForSession, not kCGConfigureForAppOnly, so
//    the restored physical state is not rolled back at process exit; the
//    owned virtual itself is still cleaned up by CGVirtualDisplay dealloc.
//    Later legitimate user OS edits are therefore not overwritten by us.
//  * NO post-start physical replays. The reconfig callback never touches
//    physical configuration. Ordinary main-change / other-display add/
//    remove / rearrangement after startup are reported via owned-only
//    invalidation but never trigger a physical write.
//  * External hotplug/removal of a baseline display BEFORE the setup commit
//    aborts the helper (no partial preservation).
//  * The owned virtual displayID + SCContentFilter is identity-locked.
//    Capture is bound to the SCDisplay matching ownedID; no other display is
//    captured even transiently.
//  * Display reconfig callback does NOT exit; it suspends new-frame
//    submission and marks owned invalid. A dedicated watchdog revalidates
//    owned-only properties under a tiny mutex that serializes the epoch
//    bump + bounded-invalid stamp with proof publication.
//  * Bounded invalid-owned-state tolerance fails closed after 5 seconds. No
//    blanket guard-disable.
//  * Encoded frames that have already left the encoder are not synthetically
//    dropped (would break H.264 reference chains). They came from the
//    identity-locked owned filter and remain safe to emit.
//  * Parent's 0.5s heartbeat continues through the 12s raw-input pause, so
//    helper keeps the 5s heartbeat tolerance (tight hung-parent cutoff).
//  * Guards still enforced every frame: parent heartbeat, console session +
//    secure-event-input, TCC screen-capture, owned present/active/unique
//    mode/non-mirrored.
//  * Owned object destruction removes the owned screen; the helper never
//    rolls back user geometry on exit.
static const size_t MaxPayload=4*1024*1024;
static const uint64_t BoundedOwnedInvalidNS=5000000000ULL; // 5s
static const uint64_t BoundedProofStaleNS=250000000ULL;    // 250ms owned proof freshness (stale proof only pauses submit; no need to relax)
static const double   BoundedHeartbeatSec=5.0;             // parent sends 0.5s heartbeats through pauses; keep tight hung-parent cutoff
static atomic_uint inFlight=0,maximumInFlight=0;
static atomic_bool topologyArmed=false,ownedValid=false;
static atomic_uint emitted=0,encoderDropped=0,capturesSuspended=0,reconfigEpoch=0,proofEpoch=0;
static atomic_ullong ownedValidatedNS=0,ownedInvalidSinceNS=0;
// Serializes the OS-reconfiguration callback's epoch bump + invalid-stamp
// against the watchdog's post-OwnedSafe publication (epoch recheck + proof
// publish + bounded-invalid timer clear). The mutex is NEVER held across any
// CoreGraphics display read (OwnedSafe runs lock-free). Contention is bounded
// by the watchdog's 50ms poll cadence and the rarity of OS reconfigs.
static pthread_mutex_t publishMutex=PTHREAD_MUTEX_INITIALIZER;
static BOOL synthetic=NO,benchmark=NO,legacyEncoder=NO,experimentalRateControl=NO,benchmarkSpeed=NO,captureBenchmark=NO,captureLegacy=NO,nativeYUV=NO;
// Assigned once, before any API/encoder/capture call; pointee is immutable for
// the entire process lifetime. No live format changes are supported.
typedef struct { unsigned width,height,pixelScale; } VideoFormat;
static const VideoFormat DefaultFormat={1920,1080,1};
static const VideoFormat *negotiatedFormat=&DefaultFormat;
#define StreamWidth (negotiatedFormat->width)
#define StreamHeight (negotiatedFormat->height)
#define PixelWidth (StreamWidth*negotiatedFormat->pixelScale)
#define PixelHeight (StreamHeight*negotiatedFormat->pixelScale)
static BOOL FormatValid(VideoFormat f){
  if(f.width<640 || f.width>1920 || f.height<480 || f.height>1440 ||
     (f.pixelScale!=1 && f.pixelScale!=2))return NO;
  if(f.pixelScale==1 && ((f.width&1) || (f.height&1)))return NO;
  // Validate logical bounds and scale before multiplication. All products
  // below are bounded (including the encoded ceil-macroblock allocation).
  unsigned pw=f.width*f.pixelScale,ph=f.height*f.pixelScale;
  return f.width*f.height<=2073600 && pw*ph<=(f.pixelScale==2?8294400u:2073600u) &&
    ((pw+15)/16)*((ph+15)/16)<=(f.pixelScale==2?34560u:8704u) &&
    f.width>=f.height && 5*f.width<=12*f.height;
}
typedef struct { unsigned width,height; } VirtualModeSize;
// Pure configuration plan, not display proof. Validate BEFORE multiplying.
// Current macOS needs the physical anchor first to expose an exact 2x mode.
// The logical mode remains last; only exact CG logical/backing proof may arm.
static unsigned VirtualModePlan(VideoFormat f,VirtualModeSize modes[2]){
  if(!FormatValid(f))return 0;
  if(f.pixelScale==2){
    modes[0]=(VirtualModeSize){f.width*2,f.height*2};
    modes[1]=(VirtualModeSize){f.width,f.height};
    return 2;
  }
  modes[0]=(VirtualModeSize){f.width,f.height};return 1;
}
static BOOL StartupModeChooseAllowed(BOOL detachedCommit,BOOL baselineOK,BOOL exactSet,BOOL unmirrored,BOOL armed){
  return detachedCommit && baselineOK && exactSet && unmirrored && !armed;
}
static BOOL StartupModeTargetAllowed(uint32_t target,uint32_t owned,BOOL physical){
  return owned!=0 && target==owned && !physical;
}
static BOOL ParseDecimal(const char *text,unsigned *value){
  if(!text || !*text)return NO;
  unsigned result=0;
  for(const unsigned char *c=(const unsigned char*)text;*c;c++){
    if(*c<'0' || *c>'9')return NO;
    unsigned digit=*c-'0';
    if(result>(UINT_MAX-digit)/10)return NO;
    result=result*10+digit;
  }
  *value=result;return YES;
}
typedef struct { BOOL requested; int32_t x,y; } OwnedOrigin;
static BOOL ParseOriginDecimal(const char *text,int32_t *value){
  if(!text || !*text)return NO;
  BOOL negative=*text=='-';if(negative)text++;
  unsigned magnitude=0;
  if(!ParseDecimal(text,&magnitude) || magnitude>1000000)return NO;
  *value=negative?-(int32_t)magnitude:(int32_t)magnitude;return YES;
}
// Pure exact-order grammar: MODE [--size W H] [--scale 1|2] [--origin X Y]. Only stream
// accepts origin. Duplicate, unknown, reversed or trailing options fail closed.
static BOOL ParseInvocation(int argc,const char **argv,VideoFormat *format,OwnedOrigin *origin){
  if(argc<2)return NO;
  BOOL stream=!strcmp(argv[1],"--stream");
  BOOL sizable=stream || !strcmp(argv[1],"--synthetic") || !strcmp(argv[1],"--identity-probe");
  BOOL known=sizable || !strcmp(argv[1],"--selftest") || !strcmp(argv[1],"--event-pump-selftest") || !strcmp(argv[1],"--probe") ||
    !strcmp(argv[1],"--benchmark-old") || !strcmp(argv[1],"--benchmark-new") ||
    !strcmp(argv[1],"--benchmark-ratecontrol");
  if(!known)return NO;
  VideoFormat candidate=DefaultFormat;OwnedOrigin saved={NO,0,0};int i=2;
  if(i<argc && !strcmp(argv[i],"--size")){
    if(!sizable || argc-i<3 || !ParseDecimal(argv[i+1],&candidate.width) ||
       !ParseDecimal(argv[i+2],&candidate.height))return NO;
    i+=3;
  }
  if(i<argc && !strcmp(argv[i],"--scale")){
    if(!sizable || argc-i<2 || !ParseDecimal(argv[i+1],&candidate.pixelScale))return NO;
    i+=2;
  }
  if(i<argc && !strcmp(argv[i],"--origin")){
    if(!stream || argc-i<3 || !ParseOriginDecimal(argv[i+1],&saved.x) ||
       !ParseOriginDecimal(argv[i+2],&saved.y))return NO;
    saved.requested=YES;i+=3;
  }
  if(i!=argc || !FormatValid(candidate))return NO;
  *format=candidate;*origin=saved;return YES;
}
static BOOL ParseArguments(int argc,const char **argv,VideoFormat *format){
  OwnedOrigin ignored;return ParseInvocation(argc,argv,format,&ignored);
}
// Pure snapshot geometry. No live display reads or mutations. Aliases may
// block overlap, but only an active physical root may supply a shared edge.
typedef struct { CGRect bounds; BOOL active,root; } PlacementPhysical;
static BOOL PlacementRectSane(CGRect r){
  double x=r.origin.x,y=r.origin.y,w=r.size.width,h=r.size.height;
  return isfinite(x) && isfinite(y) && isfinite(w) && isfinite(h) && w>0 && h>0 &&
    x>=-1000000 && y>=-1000000 && x<=1000000 && y<=1000000 &&
    w<=2000000 && h<=2000000 && x+w<=1000000 && y+h<=1000000;
}
static BOOL SavedOriginValid(OwnedOrigin saved,VideoFormat format,const PlacementPhysical *physical,uint32_t count){
  if(!saved.requested || !FormatValid(format) || !physical || !count || count>8)return NO;
  CGRect candidate=CGRectMake(saved.x,saved.y,format.width,format.height);
  if(!PlacementRectSane(candidate))return NO;
  double l=CGRectGetMinX(candidate),r=CGRectGetMaxX(candidate),t=CGRectGetMinY(candidate),b=CGRectGetMaxY(candidate);
  BOOL sharesEdge=NO;
  for(uint32_t i=0;i<count;i++){
    CGRect p=physical[i].bounds;if(!PlacementRectSane(p))return NO;
    double pl=CGRectGetMinX(p),pr=CGRectGetMaxX(p),pt=CGRectGetMinY(p),pb=CGRectGetMaxY(p);
    double sharedX=fmin(r,pr)-fmax(l,pl),sharedY=fmin(b,pb)-fmax(t,pt);
    if(sharedX>0 && sharedY>0)return NO;
    if(physical[i].active && physical[i].root &&
       (((r==pl || l==pr) && sharedY>0) || ((b==pt || t==pb) && sharedX>0)))sharesEdge=YES;
  }
  return sharesEdge;
}
// Pure first-use default: owned virtual screen left of all physical bounds,
// vertically centered on the original physical main. No physical writes.
static OwnedOrigin DefaultOwnedOrigin(VideoFormat format,const PlacementPhysical *physical,uint32_t count,CGRect main){
  OwnedOrigin none={NO,0,0};
  if(!FormatValid(format)||!physical||!count||count>8||!PlacementRectSane(main))return none;
  double left=INFINITY;for(uint32_t i=0;i<count;i++){if(!PlacementRectSane(physical[i].bounds))return none;left=fmin(left,CGRectGetMinX(physical[i].bounds));}
  double x=left-format.width,y=round(CGRectGetMidY(main)-(double)format.height/2);
  if(!isfinite(x)||!isfinite(y)||x!=round(x)||x<INT32_MIN||x>INT32_MAX||y<INT32_MIN||y>INT32_MAX)return none;
  OwnedOrigin result={YES,(int32_t)x,(int32_t)y};return SavedOriginValid(result,format,physical,count)?result:none;
}
static int targetFPS=60;
// One stable display identity per macOS user. The valid uid_t domain maps
// injectively to nonzero uint32 serials; no random, format, peer or PID input.
// Keep vendor/product and this mapping stable across future app versions.
static const unsigned OwnedDisplayVendor=505,OwnedDisplayProduct=0x6001;
static unsigned StableDisplaySerial(uid_t user){return user==(uid_t)UINT32_MAX?0:(uint32_t)user+1u;}
static BOOL SameDisplayIdentity(unsigned vendor,unsigned product,unsigned serial,unsigned wanted){
  return wanted && vendor==OwnedDisplayVendor && product==OwnedDisplayProduct && serial==wanted;
}
// Held until process exit (including _exit/signal paths). Never unlink the
// lock file: unlinking a held inode permits another process to bypass flock.
static int identityLockFD=-1;
static int AcquireDisplayIdentityLock(const char *directory,uid_t owner){
  int dir=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(dir<0)return -1;
  struct stat info;
  if(fstat(dir,&info)||!S_ISDIR(info.st_mode)||info.st_uid!=owner||(info.st_mode&022)){close(dir);return -1;}
  int fd=openat(dir,"display.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);close(dir);
  if(fd<0)return -1;
  if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_uid!=owner||info.st_nlink!=1||(info.st_mode&022)||flock(fd,LOCK_EX|LOCK_NB)){
    close(fd);return -1;
  }
  return fd;
}
static int AcquireUserDisplayIdentityLock(void){
  if(getuid()!=geteuid())return -1;
  NSString *directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ThunderControl/VirtualDisplay"];
  if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return -1;
  return AcquireDisplayIdentityLock(directory.fileSystemRepresentation,geteuid());
}
static BOOL DisplayIdentityAvailable(unsigned serial){
  CGDirectDisplayID ids[32];uint32_t count=0;
  if(!serial||CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess||count>32)return NO;
  for(uint32_t i=0;i<count;i++){
    unsigned vendor=CGDisplayVendorNumber(ids[i]),product=CGDisplayModelNumber(ids[i]),other=CGDisplaySerialNumber(ids[i]);
    if(SameDisplayIdentity(vendor,product,other,serial) ||
       (vendor==OwnedDisplayVendor && product==OwnedDisplayProduct && !other))return NO;
  }
  return YES; // Never adopt an existing display or randomize on collision.
}
static pid_t parentPID=0;
static double latencies[1024],frameAges[1024];
static BOOL tuning=NO,tuneBaselineProfile=NO,tuneHighBitrate=NO;
static const char *tuneLabel="unchanged";
static uint64_t lastCaptureSequence=0;
static double pendingCaptureAt[2],lastReadyAt=0,lastReadyCaptureAt=0,ageArea=0,ageDuration=0;
static unsigned latencyCount=0;
static BOOL lowLatencyRateControl=NO,maxDelayZero=NO,speedPriority=NO;
static CGDirectDisplayID originalID=0,ownedID=0;
static CGRect originalBounds,originalUnion,ownedInitialBounds;
static uint32_t baselineCount=0;
// Full read-only snapshot of each pre-create physical display. Reasserted as
// a single transaction with owned creation; never replayed after startup.
static struct {
  CGDirectDisplayID id;
  CGDirectDisplayID mirror;      // kCGNullDirectDisplay if not mirroring
  bool active;
  CGRect bounds;
  CGDisplayModeRef mode;         // retained until startup verification completes
  size_t pixelWidth,pixelHeight;
} baseline[8];
static CGDisplayModeRef ownedInitialMode=NULL;
static VTCompressionSessionRef encoder=NULL;
static dispatch_queue_t frameQueue;
static double Now(void){return NSProcessInfo.processInfo.systemUptime;}
// Diagnostics are observation-only: fixed storage, no locks, no retries, no I/O
// except one best-effort nonblocking stderr write. Never changes stdout flags.
static atomic_ullong diagEagain=0,diagTruncated=0,diagPartial=0,diagFailed=0;
static atomic_ullong diagCallbacks=0,diagComplete=0,diagIdle=0,diagBlank=0,diagOther=0;
static atomic_ullong diagStatusDrops=0,diagReplaced=0,diagBusy=0,diagSuspended=0,diagNoPixel=0;
static atomic_ullong diagGapMaxUS=0,diagGapCount=0,diagGapSumUS=0;
static BOOL diagEnabled=NO;
static uint64_t DiagUS(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (uint64_t)t.tv_sec*1000000ULL+(uint64_t)t.tv_nsec/1000;}
static BOOL DiagNonblocking(int fd){int flags=fcntl(fd,F_GETFL);return flags>=0 && fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0;}
static BOOL DiagIdentifier(const char *s){if(!s||!*s)return NO;for(;*s;s++)if(!((*s>='a'&&*s<='z')||(*s>='0'&&*s<='9')||*s=='_'))return NO;return YES;}
// Internal formats contain numeric integer values only. A truncated line is
// discarded whole, rather than emitting a malformed record or a second write.
static const uint64_t DiagNoSequence=UINT64_MAX;
static int DiagFormat(char *line,size_t capacity,const char *stage,uint64_t seq,uint64_t capture,const char *format,va_list args){
  if(!DiagIdentifier(stage))return -1;
  int n=snprintf(line,capacity,"TC_DIAG stage=%s ",stage);
  if(n<0||(size_t)n>=capacity)return -1;
  if(seq!=DiagNoSequence){int added=snprintf(line+n,capacity-(size_t)n,"seq=%llu ",(unsigned long long)seq);if(added<0||(size_t)added>=capacity-(size_t)n)return -1;n+=added;}
  if(capture){int added=snprintf(line+n,capacity-(size_t)n,"capture=%llu ",(unsigned long long)capture);if(added<0||(size_t)added>=capacity-(size_t)n)return -1;n+=added;}
  int tail=vsnprintf(line+n,capacity-(size_t)n,format,args);
  if(tail<0||(size_t)tail>=capacity-(size_t)n-1)return -1;
  n+=tail;line[n++]='\n';line[n]=0;return n;
}
static void DiagWriteResult(ssize_t result,size_t n,int error){
  if(result<0){if(error==EAGAIN||error==EWOULDBLOCK)atomic_fetch_add(&diagEagain,1);else atomic_fetch_add(&diagFailed,1);}
  else if((size_t)result!=n)atomic_fetch_add(&diagPartial,1);
}
static void DiagWrite(int fd,const char *line,size_t n){
  int saved=errno;ssize_t result=write(fd,line,n);int error=errno;
  DiagWriteResult(result,n,error);errno=saved;
}
static void Diag(const char *stage,uint64_t seq,uint64_t capture,const char *format,...) __attribute__((format(printf,4,5)));
static void Diag(const char *stage,uint64_t seq,uint64_t capture,const char *format,...){
  if(!diagEnabled)return;int saved=errno;
  char line[_POSIX_PIPE_BUF];va_list args;va_start(args,format);int n=DiagFormat(line,sizeof(line),stage,seq,capture,format,args);va_end(args);
  if(n<0)atomic_fetch_add(&diagTruncated,1);else DiagWrite(STDERR_FILENO,line,(size_t)n);errno=saved;
}
#define DU(x) ((unsigned long long)(x))
static void DiagPeriodic(void){
  static uint64_t previous=0;uint64_t now=DiagUS();if(now-previous<2000000)return;previous=now;
  Diag("capture_aggregate",DiagNoSequence,0,"us=%llu callbacks=%llu complete=%llu idle=%llu blank=%llu other=%llu",DU(now),DU(atomic_load(&diagCallbacks)),DU(atomic_load(&diagComplete)),DU(atomic_load(&diagIdle)),DU(atomic_load(&diagBlank)),DU(atomic_load(&diagOther)));
  Diag("capture_drop_aggregate",DiagNoSequence,0,"us=%llu status_drop=%llu replaced=%llu busy=%llu suspended=%llu no_pixel=%llu emitted=%u codec_dropped=%u in_flight=%u",DU(now),DU(atomic_load(&diagStatusDrops)),DU(atomic_load(&diagReplaced)),DU(atomic_load(&diagBusy)),DU(atomic_load(&diagSuspended)),DU(atomic_load(&diagNoPixel)),atomic_load(&emitted),atomic_load(&encoderDropped),atomic_load(&inFlight));
  Diag("capture_gap_aggregate",DiagNoSequence,0,"us=%llu gap_count=%llu gap_sum_us=%llu gap_max_us=%llu",DU(now),DU(atomic_exchange(&diagGapCount,0)),DU(atomic_exchange(&diagGapSumUS,0)),DU(atomic_exchange(&diagGapMaxUS,0)));
  Diag("diagnostics_aggregate",DiagNoSequence,0,"us=%llu eagain=%llu truncated=%llu partial=%llu failed=%llu",DU(now),DU(atomic_load(&diagEagain)),DU(atomic_load(&diagTruncated)),DU(atomic_load(&diagPartial)),DU(atomic_load(&diagFailed)));
}
// Only diagnostic metadata follows the existing mailbox/ticket/order window.
static _Thread_local uint64_t diagSourceOrdinal=0,diagSourceUS=0;
static uint64_t diagLatestOrdinal=0,diagLatestUS=0;
// Stable FNV-1a/32 of the existing constant failure reason's UTF-8 bytes.
// Offline lookup: enumerate Fail("...") literals and compute this same hash;
// neither reason text nor any captured/input content enters structured output.
static uint32_t DiagReasonCode(const char *reason){uint32_t hash=2166136261u;for(const unsigned char *p=(const unsigned char*)reason;*p;p++){hash^=*p;hash*=16777619u;}return hash;}
static void Fail(const char *reason){if(diagEnabled)Diag("helper_failure",DiagNoSequence,0,"reason_code=%u us=%llu",DiagReasonCode(reason),DU(DiagUS()));fprintf(stderr,"Display sender stopped: %s\n",reason);fflush(stderr);_exit(1);}
static void SignalStop(int sig){(void)sig;_exit(2);}
// Secure Input restricts OS input delivery, not authenticated video. Do not
// disable/bypass it or tear down the virtual display when a password field opens.
static BOOL SessionValuesSafe(id on,id login,id locked,BOOL secureInput){
  (void)secureInput;
  return on && login && CFGetTypeID((__bridge CFTypeRef)on)==CFBooleanGetTypeID() && CFGetTypeID((__bridge CFTypeRef)login)==CFBooleanGetTypeID() && [on boolValue] && [login boolValue] && (!locked || CFGetTypeID((__bridge CFTypeRef)locked)==CFBooleanGetTypeID()) && ![locked boolValue];
}
static BOOL SessionSafe(void){
  NSDictionary *d=CFBridgingRelease(CGSessionCopyCurrentDictionary());
  id on=d[(__bridge NSString*)kCGSessionOnConsoleKey],login=d[(__bridge NSString*)kCGSessionLoginDoneKey],locked=d[@"CGSSessionScreenIsLocked"];
  return SessionValuesSafe(on,login,locked,IsSecureEventInputEnabled());
}
static BOOL ModeSame(CGDisplayModeRef a,CGDisplayModeRef b){
  return a && b && CGDisplayModeGetIODisplayModeID(a)==CGDisplayModeGetIODisplayModeID(b) && CGDisplayModeGetWidth(a)==CGDisplayModeGetWidth(b) && CGDisplayModeGetHeight(a)==CGDisplayModeGetHeight(b) && CGDisplayModeGetPixelWidth(a)==CGDisplayModeGetPixelWidth(b) && CGDisplayModeGetPixelHeight(a)==CGDisplayModeGetPixelHeight(b) && CGDisplayModeGetRefreshRate(a)==CGDisplayModeGetRefreshRate(b) && CGDisplayModeGetIOFlags(a)==CGDisplayModeGetIOFlags(b);
}
// Capture the authoritative read-only snapshot of PHYSICAL displays at startup.
// Required: 1..7 online (plus later owned virtual = <=8), 1..7 active, valid
// main. Each physical display's mirror / active / bounds / mode / pixelSize
// is retained for in-transaction reassertion; general multi-display and
// mirror-group layouts are supported field-by-field, never policy-forced.
static void ReleaseBaselineModes(void){
  for(uint32_t i=0;i<baselineCount;i++)if(baseline[i].mode){CGDisplayModeRelease(baseline[i].mode);baseline[i].mode=NULL;}
}
static BOOL BaselineSupported(void){
  CGDirectDisplayID online[32],active[32];uint32_t onlineCount=0,activeCount=0;
  if(CGGetOnlineDisplayList(32,online,&onlineCount)!=kCGErrorSuccess)return NO;
  if(onlineCount<1 || onlineCount>7)return NO; // leave room for 1 owned virtual (total <=8)
  if(CGGetActiveDisplayList(32,active,&activeCount)!=kCGErrorSuccess)return NO;
  if(activeCount<1 || activeCount>7)return NO;
  originalID=CGMainDisplayID();if(!originalID)return NO;
  BOOL mainOnline=NO,mainActive=NO;
  for(uint32_t i=0;i<onlineCount;i++)mainOnline|=online[i]==originalID;
  for(uint32_t i=0;i<activeCount;i++)mainActive|=active[i]==originalID;
  if(!mainOnline || !mainActive)return NO;
  originalBounds=CGDisplayBounds(originalID);
  CGRect unionRect=CGRectNull;BOOL any=NO;
  baselineCount=onlineCount;
  for(uint32_t i=0;i<onlineCount;i++){
    CGDirectDisplayID id=online[i];
    baseline[i].id=id;
    baseline[i].mirror=CGDisplayMirrorsDisplay(id);
    baseline[i].active=CGDisplayIsActive(id)!=0;
    baseline[i].bounds=CGDisplayBounds(id);
    baseline[i].mode=CGDisplayCopyDisplayMode(id);
    if(!baseline[i].mode){baselineCount=i;ReleaseBaselineModes();baselineCount=0;return NO;}
    baseline[i].pixelWidth=CGDisplayModeGetPixelWidth(baseline[i].mode);
    baseline[i].pixelHeight=CGDisplayModeGetPixelHeight(baseline[i].mode);
    // Union only the authoritative visible rectangle for non-mirrored actives.
    // Mirrored sibling displays occupy the primary's rect, so skip to avoid
    // double-counting; the primary itself is already included.
    if(baseline[i].active && baseline[i].mirror==kCGNullDirectDisplay){
      unionRect=any?CGRectUnion(unionRect,baseline[i].bounds):baseline[i].bounds;any=YES;
    }
  }
  if(!any)unionRect=originalBounds;
  originalUnion=unionRect;return YES;
}
// Verifies that every baseline display is still online and its mirror /
// active / bounds / mode / pixel size still match the pre-create snapshot.
// Also requires main unchanged. Called only inside the startup transaction's
// post-commit settle; NOT a hot-path probe and NOT invoked post-start.
static BOOL StartupOnlineExact(void){
  CGDirectDisplayID ids[32];uint32_t n=0;
  if(CGGetOnlineDisplayList(32,ids,&n)!=kCGErrorSuccess || n!=baselineCount+1 || n>8)return NO;
  BOOL foundOwned=NO;
  for(uint32_t j=0;j<n;j++){
    BOOL known=ids[j]==ownedID;if(known)foundOwned=YES;
    for(uint32_t i=0;!known && i<baselineCount;i++)if(ids[j]==baseline[i].id)known=YES;
    if(!known)return NO;
  }
  for(uint32_t i=0;i<baselineCount;i++){
    BOOL found=NO;for(uint32_t j=0;j<n;j++)if(ids[j]==baseline[i].id)found=YES;
    if(!found)return NO;
  }
  return foundOwned;
}
static BOOL BaselinePreserved(void){
  if(CGMainDisplayID()!=originalID)return NO;
  CGDirectDisplayID ids[32];uint32_t n=0;
  if(CGGetOnlineDisplayList(32,ids,&n)!=kCGErrorSuccess||n>8)return NO;
  for(uint32_t i=0;i<baselineCount;i++){
    BOOL present=NO;for(uint32_t j=0;j<n;j++)if(ids[j]==baseline[i].id){present=YES;break;}
    if(!present)return NO;
    CGDirectDisplayID id=baseline[i].id;
    if(CGDisplayMirrorsDisplay(id)!=baseline[i].mirror)return NO;
    if((bool)(CGDisplayIsActive(id)!=0)!=baseline[i].active)return NO;
    if(!CGRectEqualToRect(CGDisplayBounds(id),baseline[i].bounds))return NO;
    CGDisplayModeRef m=CGDisplayCopyDisplayMode(id);if(!m)return NO;
    BOOL ok=ModeSame(m,baseline[i].mode) && CGDisplayModeGetPixelWidth(m)==baseline[i].pixelWidth && CGDisplayModeGetPixelHeight(m)==baseline[i].pixelHeight;
    CGDisplayModeRelease(m);if(!ok)return NO;
  }
  return YES;
}
// Owned-only validation: never consults other displays' geometry. Fails safe
// if owned ID isn't present/active/unique/non-mirrored or if its mode drifted
// from the mode we actually applied at setup.
static BOOL OwnedSafe(void){
  if(!ownedID || ownedID==originalID)return NO;
  for(uint32_t i=0;i<baselineCount;i++)if(baseline[i].id==ownedID)return NO;
  CGDirectDisplayID ids[32];uint32_t n=0;
  if(CGGetOnlineDisplayList(32,ids,&n)!=kCGErrorSuccess || n==0 || n>8)return NO;
  BOOL present=NO;for(uint32_t i=0;i<n;i++)if(ids[i]==ownedID){present=YES;break;}
  if(!present)return NO;
  if(!CGDisplayIsActive(ownedID))return NO;
  if(CGDisplayIsInMirrorSet(ownedID))return NO;
  if(CGDisplayMirrorsDisplay(ownedID)!=kCGNullDirectDisplay)return NO;
  CGRect b=CGDisplayBounds(ownedID);
  if(b.size.width!=StreamWidth || b.size.height!=StreamHeight)return NO;
  CGDisplayModeRef m=CGDisplayCopyDisplayMode(ownedID);if(!m)return NO;
  BOOL ok=CGDisplayModeGetWidth(m)==StreamWidth && CGDisplayModeGetHeight(m)==StreamHeight && CGDisplayModeGetPixelWidth(m)==PixelWidth && CGDisplayModeGetPixelHeight(m)==PixelHeight;
  if(ok && ownedInitialMode)ok=ModeSame(m,ownedInitialMode);
  CGDisplayModeRelease(m);return ok;
}
// Diagnostics are not proof: only OwnedSafe and strict startup gates authorize ARM.
static void OwnedHiDPIDiagnostic(const char *phase,BOOL enumerate){
  CGDisplayModeRef current=CGDisplayCopyDisplayMode(ownedID);
  BOOL logical=current && CGDisplayModeGetWidth(current)==StreamWidth && CGDisplayModeGetHeight(current)==StreamHeight;
  BOOL pixel=current && CGDisplayModeGetPixelWidth(current)==PixelWidth && CGDisplayModeGetPixelHeight(current)==PixelHeight;
  if(current)CGDisplayModeRelease(current);
  CFIndex count=0;unsigned logicalCount=0,pixelCount=0,bothCount=0,ratioCount=0;
  if(enumerate){
    NSDictionary *options=@{(__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes:@YES};
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(ownedID,(__bridge CFDictionaryRef)options);
    if(modes){count=MIN(CFArrayGetCount(modes),4096);for(CFIndex i=0;i<count;i++){
      CGDisplayModeRef m=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
      size_t w=CGDisplayModeGetWidth(m),h=CGDisplayModeGetHeight(m),pw=CGDisplayModeGetPixelWidth(m),ph=CGDisplayModeGetPixelHeight(m);
      BOOL l=w==StreamWidth && h==StreamHeight,p=pw==PixelWidth && ph==PixelHeight;
      logicalCount+=l;pixelCount+=p;bothCount+=l&&p;
      ratioCount+=w && h && pw%2==0 && ph%2==0 && pw/2==w && ph/2==h;
    }CFRelease(modes);}
  }
  fprintf(stderr,"Owned HiDPI proof: phase=%s ownedMirrorSet=%s logicalMatch=%s pixelMatch=%s modesEnumerated=%s modeCount=%ld exactModeFound=%s logicalMatchCount=%u pixelMatchCount=%u bothCount=%u twoXRatioCount=%u\n",phase,CGDisplayIsInMirrorSet(ownedID)?"yes":"no",logical?"yes":"no",pixel?"yes":"no",enumerate?"yes":"no",(long)count,(bothCount || (logical&&pixel))?"yes":"no",logicalCount,pixelCount,bothCount,ratioCount);
}
// Pure, injectable predicate for bounded-time failure (unit-testable).
static inline BOOL BoundedInvalidFatal(uint64_t sinceNS,uint64_t nowNS){
  return sinceNS!=0 && nowNS>sinceNS && (nowNS-sinceNS)>BoundedOwnedInvalidNS;
}
static inline BOOL BoundedHeartbeatFatal(double lastSec,double nowSec){
  return (nowSec-lastSec)>BoundedHeartbeatSec;
}
// FastGuard enforces fast-path invariants on every hot-path call. Reconfig
// transients (origin change, main change, add/remove of OTHER displays) do not
// trip FastGuard so long as owned remains valid; FastGuard only fails closed
// when the bounded invalid-owned window elapses.
static void FastGuard(void){
  if(synthetic)return;
  if(parentPID<=1 || getppid()!=parentPID || kill(parentPID,0)!=0)Fail("parent unavailable");
  if(atomic_load(&topologyArmed)){
    uint64_t since=atomic_load(&ownedInvalidSinceNS),now=(uint64_t)(Now()*1e9);
    if(BoundedInvalidFatal(since,now))Fail("display owned invalid too long");
  }
}
static void Guard(void){if(!synthetic){FastGuard();if(!SessionSafe())Fail("session changed");}}
// Returns YES when the hot path may encode a new frame: ownership proven fresh
// AND bound to the current reconfig epoch. A Reconfigured callback that fires
// between OwnedSafe() and the watchdog's state stores bumps reconfigEpoch; the
// stale proof (proofEpoch < reconfigEpoch) is rejected here even if
// ownedValidatedNS looks fresh and ownedValid was overwritten to true.
static BOOL CanSubmitFrame(void){
  if(!atomic_load(&topologyArmed))return YES; // pre-arming synthetic/benchmark
  if(!atomic_load(&ownedValid))return NO;
  if(atomic_load(&proofEpoch)!=atomic_load(&reconfigEpoch))return NO;
  uint64_t proof=atomic_load(&ownedValidatedNS),now=(uint64_t)(Now()*1e9);
  if(!proof || now<proof || now-proof>BoundedProofStaleNS)return NO;
  return YES;
}
static void Reconfigured(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void *ctx){
  (void)display;(void)flags;(void)ctx;
  if(!atomic_load(&topologyArmed))return;
  // Mark owned invalid; the watchdog re-validates owned-only properties and
  // reclears ownedInvalidSinceNS on success. Non-fatal: ordinary OS position
  // changes, main changes, other-display add/remove do not kill the helper.
  // The epoch bump + first-stamp CAS are serialized with the watchdog's
  // publish branch so a callback firing between watchdog's post-check and
  // its CAS cannot leak a stale clear of the bounded-invalid timer.
  pthread_mutex_lock(&publishMutex);
  atomic_fetch_add(&reconfigEpoch,1);
  atomic_store(&ownedValid,false);
  uint64_t now=(uint64_t)(Now()*1e9);
  uint64_t expected=0;
  // Only stamp the first invalidation so the bounded window measures from the
  // actual loss of proof. Later callbacks keep the earliest stamp.
  atomic_compare_exchange_strong(&ownedInvalidSinceNS,&expected,now);
  pthread_mutex_unlock(&publishMutex);
}
// Only byte framing is protected by this lock. Never query WindowServer while held.
static pthread_mutex_t writeMutex=PTHREAD_MUTEX_INITIALIZER;
static int outputFD=STDOUT_FILENO; // changed only by isolated offline selftest
static atomic_uint cursorBusyDropped=0,cursorPipeDropped=0,capturesReplacedBeforeEncode=0;
typedef struct {double guardMs,lockMs,pipeMs;} OutputTiming;
static _Thread_local OutputTiming outputTiming;
static void OutputWithGuard(NSData *payload,void (^guard)(void),int fd){
  if(!payload.length || payload.length>MaxPayload)Fail("frame bounds");
  double guardStarted=Now();
  guard(); // fresh safety check BEFORE acquiring the byte writer
  outputTiming.guardMs=(Now()-guardStarted)*1000;
  uint32_t be=CFSwapInt32HostToBig((uint32_t)payload.length);
  NSMutableData *framed=[NSMutableData dataWithBytes:&be length:4];[framed appendData:payload];
  double lockStarted=Now();pthread_mutex_lock(&writeMutex);
  double pipeStarted=Now();outputTiming.lockMs=(pipeStarted-lockStarted)*1000;
  const uint8_t *p=framed.bytes;size_t left=framed.length;double deadline=Now()+2;
  while(left){
    FastGuard();if(Now()>deadline)Fail("output stalled");
    ssize_t n=write(fd,p,left);
    if(n>0){p+=n;left-=(size_t)n;continue;}
    if(n<0&&errno==EINTR)continue;
    if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){struct pollfd pollFD={fd,POLLOUT,0};if(poll(&pollFD,1,50)<0&&errno!=EINTR)Fail("output poll");continue;}
    Fail("output closed");
  }
  outputTiming.pipeMs=(Now()-pipeStarted)*1000;
  pthread_mutex_unlock(&writeMutex);
}
static void Output(NSData *payload){OutputWithGuard(payload,^{Guard();},outputFD);}
// Cursor metadata is a 23-byte framed message, below POSIX's minimum PIPE_BUF.
// One nonblocking atomic write, or skip: cursor traffic never waits behind video.
static BOOL TryCursorOutput(NSData *packet,uint64_t sampledEpoch,void (^guard)(void),int fd){
  _Static_assert(23<=_POSIX_PIPE_BUF,"cursor message must be an atomic pipe write");
  if(packet.length!=19)Fail("cursor frame bounds");
  guard(); // no OS calls after the try-lock, and no waiting that ages this proof
  int result=pthread_mutex_trylock(&writeMutex);
  if(result==EBUSY){atomic_fetch_add(&cursorBusyDropped,1);return NO;}
  if(result!=0)Fail("cursor writer lock");
  uint8_t bytes[23];uint32_t size=CFSwapInt32HostToBig(19);memcpy(bytes,&size,4);memcpy(bytes+4,packet.bytes,19);
  if(sampledEpoch!=atomic_load(&reconfigEpoch)||!CanSubmitFrame())memset(bytes+13,0,10);
  FastGuard();ssize_t count=write(fd,bytes,sizeof(bytes));int error=errno;
  pthread_mutex_unlock(&writeMutex);
  if(count==(ssize_t)sizeof(bytes))return YES;
  if(count<0&&(error==EAGAIN||error==EWOULDBLOCK||error==EINTR)){atomic_fetch_add(&cursorPipeDropped,1);return NO;}
  Fail("cursor atomic output");return NO;
}
// Only frameQueue owns this PRE-ENCODE mailbox. Encoded dependency frames are never discarded.
static unsigned encodingSlots=1;
static CVPixelBufferRef latestCapture=NULL;
static CMTime latestCapturePTS;
static double latestCaptureAt=0;
static void DrainCapture(void);
typedef struct {uint64_t next;bool ready[2];uint64_t sequence[2];} EncodedOrderWindow;
static EncodedOrderWindow outputOrder={0};
static NSData *pendingEncoded[2];
static pthread_mutex_t outputMutex=PTHREAD_MUTEX_INITIALIZER;
static void AppendU64(NSMutableData *data,uint64_t n){n=CFSwapInt64HostToBig(n);[data appendBytes:&n length:8];}
// Public read-only APIs, sampled on MAIN. No event tap, Accessibility request,
// cursor warp, hide/unhide, or input ownership change. Unknown shapes use arrow.
static void PublishCursor(void){
  static uint64_t sequence=0;static double sampled=0;double now=Now();
  if(now-sampled<1.0/60.0)return;sampled=now;
  if(sequence==UINT64_MAX)Fail("cursor sequence exhausted");
  BOOL visible=NO;uint8_t shape=0;uint32_t x=0,y=0;uint64_t sampledEpoch=atomic_load(&reconfigEpoch);
  if(CanSubmitFrame() && atomic_load(&topologyArmed)){
    uint64_t topologyBefore=atomic_load(&reconfigEpoch);
    CGEventRef event=CGEventCreate(NULL);
    if(event){CGPoint p=CGEventGetLocation(event);CFRelease(event);CGRect b=CGDisplayBounds(ownedID);
      if(isfinite(p.x)&&isfinite(p.y)&&b.size.width>0&&b.size.height>0&&CGRectContainsPoint(b,p)){
        visible=YES;x=(uint32_t)llround((p.x-b.origin.x)/b.size.width*1000000);y=(uint32_t)llround((p.y-b.origin.y)/b.size.height*1000000);
        NSCursor *cursor=NSCursor.currentSystemCursor;
        if([cursor isEqual:NSCursor.IBeamCursor])shape=1;
        else if([cursor isEqual:NSCursor.crosshairCursor])shape=2;
        else if([cursor isEqual:NSCursor.pointingHandCursor])shape=3;
        else if([cursor isEqual:NSCursor.closedHandCursor])shape=4;
        if(topologyBefore!=atomic_load(&reconfigEpoch)||!CanSubmitFrame()){visible=NO;shape=0;x=0;y=0;}
      }
    }
  }
  uint8_t kind=7,v=visible?1:0;NSMutableData *packet=[NSMutableData dataWithBytes:&kind length:1];AppendU64(packet,sequence++);
  [packet appendBytes:&v length:1];[packet appendBytes:&shape length:1];x=CFSwapInt32HostToBig(x);y=CFSwapInt32HostToBig(y);[packet appendBytes:&x length:4];[packet appendBytes:&y length:4];
  // Guard inside TryCursorOutput retains the authoritative live session check.
  // Its atomic owned-epoch recheck hides any stale cursor before output.
  (void)TryCursorOutput(packet,sampledEpoch,^{Guard();},outputFD);
}
static uint64_t submittedSequence=0;
// HEVC test builds (-DTC_HEVC): the retina H.264 encode took 14.5-17ms per frame with wide
// run-to-run spread; HEVC measured 15.3ms with a tighter tail. Video packets then use kind 9
// (VPS, SPS, PPS) instead of kind 2 (SPS, PPS). Kinds 3 and 8 are handshake messages.
#ifdef TC_HEVC
#define TC_IS_HEVC 1
#define TC_CODEC_TYPE kCMVideoCodecType_HEVC
#else
#define TC_IS_HEVC 0
#define TC_CODEC_TYPE kCMVideoCodecType_H264
#endif
typedef struct {double started,capturedAt;uint64_t sequence,captureSequence;uint64_t diagOrdinal,diagCapturedUS,diagAdmissionUS;} EncodeTicket;
static EncodeTicket diagPendingTickets[2];
static BOOL OrderAccept(EncodedOrderWindow *order,uint64_t sequence,unsigned slots){
  if(slots<1||slots>2||sequence<order->next||sequence-order->next>=slots)return NO;
  unsigned index=sequence%2;if(order->ready[index])return NO;
  order->ready[index]=true;order->sequence[index]=sequence;return YES;
}
static BOOL OrderTake(EncodedOrderWindow *order,uint64_t *sequence){
  unsigned index=order->next%2;if(!order->ready[index]||order->sequence[index]!=order->next)return NO;
  *sequence=order->next;order->ready[index]=false;order->next++;return YES;
}
static BOOL ReserveEncoding(void){
  unsigned count=atomic_load(&inFlight);
  while(count<encodingSlots){if(atomic_compare_exchange_weak(&inFlight,&count,count+1)){atomic_store(&maximumInFlight,MAX(atomic_load(&maximumInFlight),count+1));return YES;}}
  return NO;
}
static dispatch_queue_t WriterQueue(void){
  static dispatch_queue_t queue;static dispatch_once_t once;
  dispatch_once(&once,^{queue=dispatch_queue_create("local.ThunderControl.display.writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));});
  return queue;
}
typedef struct {uint64_t count;double sum,max;} SourceTiming;
static void RecordSourceTiming(SourceTiming *s,double ms){s->count++;s->sum+=ms;s->max=fmax(s->max,ms);}
static SourceTiming writerWaitTiming,writerGuardTiming,writerLockTiming,writerPipeTiming,writerCadence;
static uint64_t outputGaps25=0,outputGaps50=0;static double previousOutputAt=0,lastSourceLogAt=0;
static void FinishEncoded(NSData *ready,uint64_t sequence,double captured,double completedAt,EncodeTicket diagnostic){
  // Only this serial queue runs blocking session checks and framed video I/O.
  // Queued/writing frames retain their existing two-slot inFlight budget.
  if(ready){
    if(benchmark){double at=Now();if(lastReadyAt>0 && sequence>=60){double span=at-lastReadyAt;ageArea+=(lastReadyAt-lastReadyCaptureAt)*span+span*span/2;ageDuration+=span;}lastReadyAt=at;lastReadyCaptureAt=captured;}
    double outputStarted=Now();
    Diag("pipe_start",sequence,diagnostic.diagOrdinal,"us=%llu capture_us=%llu",DU(DiagUS()),DU(diagnostic.diagCapturedUS));
    if(!benchmark)Output(ready);
    Diag("pipe_complete",sequence,diagnostic.diagOrdinal,"us=%llu capture_us=%llu delivered=%u",DU(DiagUS()),DU(diagnostic.diagCapturedUS),!benchmark);
    if(!synthetic){
      double at=Now();RecordSourceTiming(&writerWaitTiming,(outputStarted-completedAt)*1000);
      RecordSourceTiming(&writerGuardTiming,outputTiming.guardMs);RecordSourceTiming(&writerLockTiming,outputTiming.lockMs);RecordSourceTiming(&writerPipeTiming,outputTiming.pipeMs);
      if(previousOutputAt>0){double gap=(at-previousOutputAt)*1000;RecordSourceTiming(&writerCadence,gap);if(gap>25)outputGaps25++;if(gap>50)outputGaps50++;}previousOutputAt=at;
    }
    atomic_fetch_add(&emitted,1);
  } else {atomic_fetch_add(&encoderDropped,1);Diag("encoder_drop",sequence,diagnostic.diagOrdinal,"us=%llu",DU(DiagUS()));}
  if(atomic_fetch_sub(&inFlight,1)==0)Fail("encoding count underflow");
  if(frameQueue)dispatch_async(frameQueue,^{@autoreleasepool{DrainCapture();}});
  double at=Now();if(!synthetic && ready && at-lastSourceLogAt>=2){
    lastSourceLogAt=at;
    fprintf(stderr,"Source output aggregate: sequence=%llu frames=%u callbackToWriterMs[mean=%.3f max=%.3f] guardMs[mean=%.3f max=%.3f] byteLockMs[mean=%.3f max=%.3f] pipeMs[mean=%.3f max=%.3f] outputIntervalMs[mean=%.3f max=%.3f] gapsOver25=%llu gapsOver50=%llu replacedBeforeEncode=%u cursorBusySkipped=%u cursorPipeSkipped=%u inFlight=%u slots=%u contentMayBeIdle=true panelUnmeasured=true\n",(unsigned long long)sequence,atomic_load(&emitted),writerWaitTiming.sum/writerWaitTiming.count,writerWaitTiming.max,writerGuardTiming.sum/writerGuardTiming.count,writerGuardTiming.max,writerLockTiming.sum/writerLockTiming.count,writerLockTiming.max,writerPipeTiming.sum/writerPipeTiming.count,writerPipeTiming.max,writerCadence.count?writerCadence.sum/writerCadence.count:0,writerCadence.max,(unsigned long long)outputGaps25,(unsigned long long)outputGaps50,atomic_load(&capturesReplacedBeforeEncode),atomic_load(&cursorBusyDropped),atomic_load(&cursorPipeDropped),atomic_load(&inFlight),encodingSlots);
  }
}
static double pendingCompletedAt[2];
static void PublishEncoded(NSData *packet,EncodeTicket ticket,BOOL dropped){
  // At most TWO encoded outputs (including queued/writing) exist. Submissions
  // are not released until their ordered pipe write completes. No reference
  // frame is evicted and no OS/pipe wait runs under this ordering mutex.
  pthread_mutex_lock(&outputMutex);
  if(!OrderAccept(&outputOrder,ticket.sequence,encodingSlots))Fail("encoded ordering");
  unsigned slot=ticket.sequence%2;
  diagPendingTickets[slot]=ticket;
  pendingEncoded[slot]=packet;pendingCaptureAt[slot]=ticket.capturedAt;pendingCompletedAt[slot]=Now();
  if(benchmark && !dropped && latencyCount<1024){latencies[latencyCount]=(Now()-ticket.started)*1000;frameAges[latencyCount]=(Now()-ticket.capturedAt)*1000;latencyCount++;lastCaptureSequence=MAX(lastCaptureSequence,ticket.captureSequence);}
  uint64_t sequence=0;
  while(OrderTake(&outputOrder,&sequence)){
    unsigned index=sequence%2;NSData *ready=pendingEncoded[index];pendingEncoded[index]=nil;
    double captured=pendingCaptureAt[index],completedAt=pendingCompletedAt[index];
    EncodeTicket diagnostic=diagPendingTickets[index];
    // Dispatch while still ordered; jobs retain packets, not capture buffers.
    dispatch_async(WriterQueue(),^{@autoreleasepool{FinishEncoded(ready,sequence,captured,completedAt,diagnostic);}});
  }
  pthread_mutex_unlock(&outputMutex);
}
static void Encoded(void *ctx,void *source,OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample){
  (void)ctx;
  @autoreleasepool {
    if(!source)Fail("encoder ticket");EncodeTicket ticket=*(EncodeTicket*)source;free(source);
    Diag("encoded_callback",ticket.sequence,ticket.diagOrdinal,"us=%llu capture_us=%llu admission_us=%llu status=%u flags=%u",DU(DiagUS()),DU(ticket.diagCapturedUS),DU(ticket.diagAdmissionUS),(unsigned)status,(unsigned)flags);
    if(status==noErr && (flags&kVTEncodeInfo_FrameDropped)){PublishEncoded(nil,ticket,YES);return;}
    if(status!=noErr || !sample || !CMSampleBufferDataIsReady(sample))Fail("encoder output");
    CMFormatDescriptionRef fmt=CMSampleBufferGetFormatDescription(sample);
#ifdef TC_HEVC
    const uint8_t *vps=NULL,*sps=NULL,*pps=NULL;size_t vn=0,sn=0,pn=0,count=0;int header=0;
    if(!fmt || CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt,0,&vps,&vn,&count,&header)!=noErr || header!=4 || count<3 || CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt,1,&sps,&sn,NULL,NULL)!=noErr || CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt,2,&pps,&pn,NULL,NULL)!=noErr || !vn||!sn||!pn||vn>UINT16_MAX||sn>UINT16_MAX||pn>UINT16_MAX)Fail("encoder parameters");
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);size_t n=block?CMBlockBufferGetDataLength(block):0;
    if(!n||n>MaxPayload-40-vn-sn-pn)Fail("encoded size");
    uint8_t kind=9;NSMutableData *packet=[NSMutableData dataWithBytes:&kind length:1];
    uint16_t size=CFSwapInt16HostToBig((uint16_t)vn);[packet appendBytes:&size length:2];[packet appendBytes:vps length:vn];
    size=CFSwapInt16HostToBig((uint16_t)sn);[packet appendBytes:&size length:2];[packet appendBytes:sps length:sn];
    size=CFSwapInt16HostToBig((uint16_t)pn);[packet appendBytes:&size length:2];[packet appendBytes:pps length:pn];
#else
    const uint8_t *sps=NULL,*pps=NULL;size_t sn=0,pn=0,count=0;int header=0;
    if(!fmt || CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,0,&sps,&sn,&count,&header)!=noErr || header!=4 || count<2 || CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,1,&pps,&pn,NULL,NULL)!=noErr || !sn||!pn||sn>UINT16_MAX||pn>UINT16_MAX)Fail("encoder parameters");
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);size_t n=block?CMBlockBufferGetDataLength(block):0;
    if(!n||n>MaxPayload-38-sn-pn)Fail("encoded size");
    uint8_t kind=2;NSMutableData *packet=[NSMutableData dataWithBytes:&kind length:1];
    uint16_t size=CFSwapInt16HostToBig((uint16_t)sn);[packet appendBytes:&size length:2];[packet appendBytes:sps length:sn];
    size=CFSwapInt16HostToBig((uint16_t)pn);[packet appendBytes:&size length:2];[packet appendBytes:pps length:pn];
#endif
    NSUInteger offset=packet.length;[packet increaseLengthBy:n];
    if(CMBlockBufferCopyDataBytes(block,0,n,(uint8_t*)packet.mutableBytes+offset)!=noErr)Fail("encoded copy");
    if(!synthetic){
      uint8_t envelopeKind=6;NSMutableData *envelope=[NSMutableData dataWithBytes:&envelopeKind length:1];
      AppendU64(envelope,ticket.sequence);AppendU64(envelope,(uint64_t)(ticket.capturedAt*1000000));
      AppendU64(envelope,(uint64_t)(ticket.started*1000000));AppendU64(envelope,(uint64_t)(Now()*1000000));[envelope appendData:packet];packet=envelope;
    }
    PublishEncoded(packet,ticket,NO);
  }
}
typedef struct {unsigned slots,bitrateFactor;BOOL lowLatency,speedPriority;} LiveEncoderPolicy;
static LiveEncoderPolicy ResponseFirstPolicy(VideoFormat format){
  return format.pixelScale==2 ? (LiveEncoderPolicy){2,9,YES,NO} : (LiveEncoderPolicy){1,6,NO,YES};
}
static BOOL LiveVideoMode(const char *mode){return !strcmp(mode,"--stream") || !strcmp(mode,"--synthetic");}
static BOOL ReferenceLimitVerified(OSStatus set,OSStatus read,CFTypeRef value){
  return set==noErr && read==noErr && value && CFGetTypeID(value)==CFNumberGetTypeID() && [(__bridge NSNumber*)value intValue]==1;
}
static BOOL ReadBool(CFStringRef key){CFTypeRef v=NULL;OSStatus e=VTSessionCopyProperty(encoder,key,NULL,&v);BOOL result=e==noErr&&v&&CFEqual(v,kCFBooleanTrue);if(v)CFRelease(v);return result;}
static void InitEncoder(void){
  lowLatencyRateControl=NO;maxDelayZero=NO;speedPriority=NO;
  NSMutableDictionary *spec=[@{(__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
  if(experimentalRateControl)spec[(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl]=@YES;
  NSDictionary *attrs=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(nativeYUV?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:kCVPixelFormatType_32BGRA)};
  OSStatus created=VTCompressionSessionCreate(NULL,PixelWidth,PixelHeight,TC_CODEC_TYPE,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)attrs,NULL,Encoded,NULL,&encoder);
  lowLatencyRateControl=experimentalRateControl && created==noErr && encoder!=NULL;
  if((created!=noErr||!encoder) && experimentalRateControl){
    if(encoder){VTCompressionSessionInvalidate(encoder);CFRelease(encoder);encoder=NULL;}
    [spec removeObjectForKey:(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl];
    created=VTCompressionSessionCreate(NULL,PixelWidth,PixelHeight,TC_CODEC_TYPE,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)attrs,NULL,Encoded,NULL,&encoder);
  }
  if(created!=noErr||!encoder)Fail("hardware encoder unavailable");
  CFStringRef profile=TC_IS_HEVC?kVTProfileLevel_HEVC_Main_AutoLevel:negotiatedFormat->pixelScale==2?(tuneBaselineProfile?kVTProfileLevel_H264_Baseline_5_2:kVTProfileLevel_H264_High_5_2):kVTProfileLevel_H264_Baseline_4_2;
  unsigned bitrate=negotiatedFormat->pixelScale==2?MIN(64000000u,MAX(16000000u,PixelWidth*PixelHeight*(tuneHighBitrate?9u:6u))):8000000u;
  NSDictionary *props=@{(__bridge NSString*)kVTCompressionPropertyKey_RealTime:@YES,(__bridge NSString*)kVTCompressionPropertyKey_AllowFrameReordering:@NO,(__bridge NSString*)kVTCompressionPropertyKey_ProfileLevel:(__bridge NSString*)profile,(__bridge NSString*)kVTCompressionPropertyKey_ExpectedFrameRate:@(targetFPS),(__bridge NSString*)kVTCompressionPropertyKey_MaxKeyFrameInterval:@(targetFPS),(__bridge NSString*)kVTCompressionPropertyKey_AverageBitRate:@(bitrate)};
  if(VTSessionSetProperties(encoder,(__bridge CFDictionaryRef)props)!=noErr)Fail("encoder setup");
  if(experimentalRateControl){
    OSStatus referenceStatus=VTSessionSetProperty(encoder,kVTCompressionPropertyKey_ReferenceBufferCount,(__bridge CFTypeRef)@1);
    CFTypeRef references=NULL;OSStatus referenceRead=VTSessionCopyProperty(encoder,kVTCompressionPropertyKey_ReferenceBufferCount,NULL,&references);
    fprintf(stderr,"Reference capability: setStatus=%d readStatus=%d actual=%d\n",(int)referenceStatus,(int)referenceRead,references&&CFGetTypeID(references)==CFNumberGetTypeID()?[(__bridge NSNumber*)references intValue]:-999);
    BOOL referenceVerified=ReferenceLimitVerified(referenceStatus,referenceRead,references);
    if(references)CFRelease(references);
    if(lowLatencyRateControl && !referenceVerified){
      fprintf(stderr,"Low latency fallback: referenceLimitUnverified=yes decoderBoundsUnchanged=yes\n");
      VTCompressionSessionInvalidate(encoder);CFRelease(encoder);encoder=NULL;experimentalRateControl=NO;InitEncoder();return;
    }
  }
  if(!legacyEncoder){
    OSStatus delayStatus=VTSessionSetProperty(encoder,kVTCompressionPropertyKey_MaxFrameDelayCount,(__bridge CFTypeRef)@0);
    CFTypeRef actual=NULL;OSStatus copied=VTSessionCopyProperty(encoder,kVTCompressionPropertyKey_MaxFrameDelayCount,NULL,&actual);
    maxDelayZero=copied==noErr && actual && CFGetTypeID(actual)==CFNumberGetTypeID() && [(__bridge NSNumber*)actual intValue]==0;
    fprintf(stderr,"Delay capability: setZeroStatus=%d readStatus=%d actual=%d\n",(int)delayStatus,(int)copied,actual&&CFGetTypeID(actual)==CFNumberGetTypeID()?[(__bridge NSNumber*)actual intValue]:-999);
    if(actual)CFRelease(actual);
    // Some hardware low-latency encoders do not expose MaxFrameDelayCount.
    // Accept only the requested low-latency encoder OR verified delay-zero;
    // report unsupported optional property instead of claiming it was applied.
    if(!lowLatencyRateControl && !maxDelayZero)Fail("bounded low-latency encoding unavailable");
    if(negotiatedFormat->pixelScale==1 || benchmarkSpeed)if(@available(macOS 14.0,*)){OSStatus speed=VTSessionSetProperty(encoder,kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,kCFBooleanTrue);speedPriority=speed==noErr&&ReadBool(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality);}
  }
  if(VTCompressionSessionPrepareToEncodeFrames(encoder)!=noErr)Fail("encoder prepare");
  CFTypeRef hardwareValue=NULL;OSStatus hardwareStatus=VTSessionCopyProperty(encoder,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,NULL,&hardwareValue);
  fprintf(stderr,"Hardware capability: readStatus=%d value=%s\n",(int)hardwareStatus,hardwareValue&&CFEqual(hardwareValue,kCFBooleanTrue)?"true":"false/unavailable");
  BOOL hardware=hardwareStatus==noErr&&hardwareValue&&CFEqual(hardwareValue,kCFBooleanTrue);if(hardwareValue)CFRelease(hardwareValue);
  // RequireHardwareAcceleratedVideoEncoder was mandatory in both creation paths.
  // The low-latency wrapper may not expose its optional introspection key.
  if(!hardware && hardwareStatus!=kVTPropertyNotSupportedErr)Fail("hardware encoder required");
  fprintf(stderr,"Encoder: hardwareRequired=yes lowLatencyRateControl=%s maxFrameDelayZero=%s speedPriority=%s targetFPS=%d legacyConfiguration=%s\n",lowLatencyRateControl?"accepted":"fallback/not-requested",maxDelayZero?"verified":legacyEncoder?"not-requested":"unsupported",speedPriority?"verified":"unsupported/not-requested",targetFPS,legacyEncoder?"yes":"no");
}
static void SubmitAt(CVPixelBufferRef pixel,CMTime pts,double capturedAt){
  uint64_t diagGuardStartUS=DiagUS();Guard();uint64_t diagGuardUS=DiagUS()-diagGuardStartUS; // observation only
  // Bounded transient: drop BEFORE encode when owned proof is not fresh. Does
  // not touch encoded reference frames already queued; never leaks a physical
  // display frame because the SCStream filter is identity-bound to ownedID.
  if(!CanSubmitFrame()){atomic_fetch_add(&capturesSuspended,1);atomic_fetch_add(&diagSuspended,1);Diag("capture_suspended",DiagNoSequence,diagSourceOrdinal,"us=%llu",DU(DiagUS()));return;}
  if(!ReserveEncoding()){atomic_fetch_add(&diagBusy,1);Diag("encoder_busy_drop",DiagNoSequence,diagSourceOrdinal,"us=%llu",DU(DiagUS()));return;} // Bounded count; latest capture waits outside codec.
  if(CVPixelBufferGetWidth(pixel)!=PixelWidth||CVPixelBufferGetHeight(pixel)!=PixelHeight||CVPixelBufferGetPixelFormatType(pixel)!=(nativeYUV?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:kCVPixelFormatType_32BGRA))Fail("capture dimensions or pixel format");
  if(submittedSequence>=UINT64_MAX-2)Fail("encoding sequence exhausted");
  EncodeTicket *ticket=malloc(sizeof(EncodeTicket));if(!ticket)Fail("encoder ticket allocation");
  *ticket=(EncodeTicket){.started=Now(),.capturedAt=capturedAt,.sequence=submittedSequence++,.captureSequence=(uint64_t)pts.value,.diagOrdinal=diagSourceOrdinal,.diagCapturedUS=diagSourceUS,.diagAdmissionUS=DiagUS()};VTEncodeInfoFlags flags=0;
  // Callback may synchronously free ticket: keep only a value copy for tracing.
  EncodeTicket diagnostic=*ticket;
  Diag("encoder_admission",diagnostic.sequence,diagnostic.diagOrdinal,"us=%llu capture_us=%llu in_flight=%u slots=%u guard_us=%llu submit_entry_us=%llu",DU(diagnostic.diagAdmissionUS),DU(diagnostic.diagCapturedUS),atomic_load(&inFlight),encodingSlots,DU(diagGuardUS),DU(diagGuardStartUS));
  Diag("encode_call_start",diagnostic.sequence,diagnostic.diagOrdinal,"us=%llu",DU(DiagUS()));
  OSStatus diagnosticStatus=VTCompressionSessionEncodeFrame(encoder,pixel,pts,CMTimeMake(1,targetFPS),NULL,ticket,&flags);
  Diag("encode_call_end",diagnostic.sequence,diagnostic.diagOrdinal,"us=%llu status=%u flags=%u",DU(DiagUS()),(unsigned)diagnosticStatus,(unsigned)flags);
  if(diagnosticStatus!=noErr)Fail("encode failed");
}
static void Submit(CVPixelBufferRef pixel,CMTime pts){SubmitAt(pixel,pts,Now());}
static void DrainCapture(void){
  if(atomic_load(&inFlight)>=encodingSlots || !latestCapture)return;
  CVPixelBufferRef pixel=latestCapture;CMTime pts=latestCapturePTS;latestCapture=NULL;
  uint64_t savedOrdinal=diagSourceOrdinal,savedUS=diagSourceUS;
  diagSourceOrdinal=diagLatestOrdinal;diagSourceUS=diagLatestUS;
  SubmitAt(pixel,pts,latestCaptureAt);CVPixelBufferRelease(pixel);
  diagSourceOrdinal=savedOrdinal;diagSourceUS=savedUS;
}
static void OfferCaptureAt(CVPixelBufferRef pixel,CMTime pts,double capturedAt){
  // At most one pending source image; replacement occurs BEFORE H264 encoding.
  // Keeping the last damage frame also prevents a frozen final cursor/window
  // position when ScreenCaptureKit sends only idle frames after motion stops.
  if(latestCapture){atomic_fetch_add(&capturesReplacedBeforeEncode,1);atomic_fetch_add(&diagReplaced,1);Diag("capture_replaced",DiagNoSequence,diagLatestOrdinal,"us=%llu replacement_capture=%llu",DU(DiagUS()),DU(diagSourceOrdinal));CVPixelBufferRelease(latestCapture);}
  diagLatestOrdinal=diagSourceOrdinal;diagLatestUS=diagSourceUS;
  latestCapture=CVPixelBufferRetain(pixel);latestCapturePTS=pts;latestCaptureAt=capturedAt;DrainCapture();
}
static void OfferCapture(CVPixelBufferRef pixel,CMTime pts){OfferCaptureAt(pixel,pts,Now());}
// Observation-only SCStream frame metadata helpers (pure; no capture/pixel access).
// display_avail=0 means DisplayTime absent/not NSNumber (ticks reported as 0).
// dirty_count=-1 means DirtyRects absent/not NSArray. raw_status=-1 means absent.
static BOOL DiagDisplayTicks(NSDictionary *info,uint64_t *ticks){id v=info[SCStreamFrameInfoDisplayTime];if(![v isKindOfClass:[NSNumber class]]){*ticks=0;return NO;}*ticks=[(NSNumber*)v unsignedLongLongValue];return YES;}
static long long DiagDirtyCount(NSDictionary *info){id v=info[SCStreamFrameInfoDirtyRects];return [v isKindOfClass:[NSArray class]]?(long long)[(NSArray*)v count]:-1;}
static long long DiagRawStatus(NSDictionary *info){id v=info[SCStreamFrameInfoStatus];return [v isKindOfClass:[NSNumber class]]?[(NSNumber*)v longLongValue]:-1;}
@interface FrameSink:NSObject<SCStreamOutput,SCStreamDelegate>
@property int64_t sequence;
@end
@implementation FrameSink
-(void)stream:(SCStream*)stream didStopWithError:(NSError*)error{(void)stream;(void)error;Fail("capture stopped");}
-(void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type{
  (void)stream;@autoreleasepool {
    uint64_t diagEntryUS=DiagUS();
    FastGuard();
    uint64_t ordinal=atomic_fetch_add(&diagCallbacks,1)+1,callbackUS=DiagUS();uint64_t diagFastGuardUS=callbackUS-diagEntryUS;
    static uint64_t previousUS=0;uint64_t gap=previousUS?callbackUS-previousUS:0;previousUS=callbackUS;
    if(gap){atomic_fetch_add(&diagGapCount,1);atomic_fetch_add(&diagGapSumUS,gap);uint64_t maximum=atomic_load(&diagGapMaxUS);if(gap>maximum)(void)atomic_compare_exchange_strong(&diagGapMaxUS,&maximum,gap); }
    if(type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample)){atomic_fetch_add(&diagOther,1);atomic_fetch_add(&diagStatusDrops,1);Diag("capture_callback",DiagNoSequence,ordinal,"us=%llu gap_us=%llu status_class=3 entry_us=%llu fastguard_us=%llu",DU(callbackUS),DU(gap),DU(diagEntryUS),DU(diagFastGuardUS));return;}
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,false);
    NSDictionary *info=[(__bridge NSArray*)a firstObject];NSNumber *status=info[SCStreamFrameInfoStatus];
    unsigned statusClass=!status?3:status.integerValue==SCFrameStatusComplete?0:status.integerValue==SCFrameStatusIdle?1:status.integerValue==SCFrameStatusBlank?2:3;
    atomic_fetch_add(statusClass==0?&diagComplete:statusClass==1?&diagIdle:statusClass==2?&diagBlank:&diagOther,1);
    {CMTime diagPTS=CMSampleBufferGetPresentationTimeStamp(sample);BOOL ptsOK=CMTIME_IS_VALID(diagPTS);uint64_t ticks=0;BOOL ticksOK=DiagDisplayTicks(info,&ticks);
    Diag("capture_callback",DiagNoSequence,ordinal,"us=%llu gap_us=%llu status_class=%u raw_status=%lld pts_ok=%u pts_value=%lld pts_scale=%d display_avail=%u display_ticks=%llu dirty_count=%lld entry_us=%llu fastguard_us=%llu",DU(callbackUS),DU(gap),statusClass,DiagRawStatus(info),ptsOK?1u:0u,ptsOK?(long long)diagPTS.value:0LL,ptsOK?(int)diagPTS.timescale:0,ticksOK?1u:0u,DU(ticks),DiagDirtyCount(info),DU(diagEntryUS),DU(diagFastGuardUS));}
    if(!status||status.integerValue!=SCFrameStatusComplete){atomic_fetch_add(&diagStatusDrops,1);return;}
    diagSourceOrdinal=ordinal;diagSourceUS=callbackUS;
    CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sample);if(pixel)OfferCapture(pixel,CMTimeMake(self.sequence++,targetFPS));
    else {atomic_fetch_add(&diagNoPixel,1);Diag("capture_no_pixel",DiagNoSequence,ordinal,"us=%llu",DU(DiagUS()));}
    diagSourceOrdinal=0;diagSourceUS=0;
  }
}
@end
static BOOL API(void){
  NSDictionary *m=@{@"CGVirtualDisplayDescriptor":@[@"setVendorID:",@"setProductID:",@"setSerialNum:",@"setSerialNumber:",@"setName:",@"setMaxPixelsWide:",@"setMaxPixelsHigh:",@"setSizeInMillimeters:",@"setQueue:",@"setRedPrimary:",@"setGreenPrimary:",@"setBluePrimary:",@"setWhitePoint:"],@"CGVirtualDisplayMode":@[@"initWithWidth:height:refreshRate:"],@"CGVirtualDisplaySettings":@[@"setHiDPI:",@"setRotation:",@"setModes:"],@"CGVirtualDisplay":@[@"initWithDescriptor:",@"applySettings:",@"displayID"]};
  for(NSString *name in m){Class c=NSClassFromString(name);if(!c)return NO;for(NSString *sel in m[name])if(!class_getInstanceMethod(c,NSSelectorFromString(sel)))return NO;}return YES;
}
// Pure monotonic deadline policy. Guard work consumes the requested budget too.
static double PumpWait(double deadline,double now){
  if(!isfinite(deadline)||!isfinite(now))return 0;
  double remaining=deadline-now;
  return remaining>0?fmin(0.025,remaining):0;
}
static void Pump(double t){@autoreleasepool {
  if(!isfinite(t)||t<=0)return;
  double deadline=Now()+t;
  while(PumpWait(deadline,Now())>0){
    Guard();
    double remaining=PumpWait(deadline,Now());
    if(remaining<=0)break;
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:remaining];
    if(NSApp){
      // A registered AppKit process must drain its application event queue.
      // NSRunLoop alone services CF sources but leaves AppKit events queued,
      // allowing WindowServer to mark the otherwise-live helper unresponsive.
      NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
      if(event)[NSApp sendEvent:event];
    } else {
      [NSRunLoop.currentRunLoop runUntilDate:until];
    }
  }
}}
// Pump has its own inner pool, but diagnostics/cursor/session work after Pump
// must also drain every iteration instead of accumulating in main's outer pool.
// Keep the whole iteration (including deadline checks) inside the same boundary.
static void RunPooledIteration(void (NS_NOESCAPE ^body)(void)){
  @autoreleasepool {body();}
}
static void StartWatchdog(void){
  pid_t parent=getppid();parentPID=parent;if(parent<=1)Fail("parent unavailable");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{@autoreleasepool {
    double heartbeat=Now();uint8_t buf[128];
    for(;;){@autoreleasepool {
      double now=Now();
      if(getppid()!=parent||kill(parent,0)!=0)Fail("parent unavailable");
      if(BoundedHeartbeatFatal(heartbeat,now))Fail("parent heartbeat expired");
      // No SessionSafe here: hot path already samples session every frame. The
      // watchdog is for owned-only revalidation + heartbeat tolerance.
      if(atomic_load(&topologyArmed)){
        // Snapshot the reconfig epoch BEFORE the lock-free OwnedSafe() read.
        // Then enter publishMutex to recheck epoch and publish atomically with
        // respect to Reconfigured. Even in the exact race the parent flagged
        // (nonzero stampBefore + reconfig between afterEpoch read and timer
        // CAS), the under-lock recheck forces the else-branch and the bounded
        // invalid timer is never falsely cleared.
        unsigned beforeEpoch=atomic_load(&reconfigEpoch);
        BOOL safe=OwnedSafe(); // Lock-free: never hold publishMutex across CG reads.
        uint64_t stamp=(uint64_t)(now*1e9);BOOL fatal=NO;
        pthread_mutex_lock(&publishMutex);
        unsigned afterEpoch=atomic_load(&reconfigEpoch);
        if(safe && beforeEpoch==afterEpoch){
          atomic_store(&ownedValidatedNS,stamp);
          atomic_store(&proofEpoch,beforeEpoch);
          atomic_store(&ownedValid,true);
          // Under lock, Reconfigured cannot run concurrently. Any reconfig that
          // raced before this branch already bumped afterEpoch > beforeEpoch,
          // so we only enter here when no stamp changed since snapshot. Hence
          // an unconditional store is safe and simpler than a CAS-ping.
          atomic_store(&ownedInvalidSinceNS,0);
        } else {
          atomic_store(&ownedValid,false);
          uint64_t expected=0;
          atomic_compare_exchange_strong(&ownedInvalidSinceNS,&expected,stamp);
          fatal=BoundedInvalidFatal(atomic_load(&ownedInvalidSinceNS),stamp);
        }
        pthread_mutex_unlock(&publishMutex);
        if(fatal)Fail("display owned invalid too long");
      }
      struct pollfd fd={STDIN_FILENO,POLLIN,0};int r=poll(&fd,1,50);
      if(r<0&&errno!=EINTR)Fail("heartbeat poll");
      if(r>0){ssize_t rn=read(STDIN_FILENO,buf,sizeof(buf));if(rn>0)heartbeat=Now();else if(rn==0)Fail("parent closed");else if(errno!=EAGAIN&&errno!=EINTR)Fail("heartbeat read");}
      if(!CGPreflightScreenCaptureAccess())Fail("capture permission revoked");
    }}
  }});
}
static CVPixelBufferRef PatternPixel(unsigned n){
  CVPixelBufferRef pixel=NULL;NSDictionary *attrs=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
  OSType type=nativeYUV?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:kCVPixelFormatType_32BGRA;
  if(CVPixelBufferCreate(NULL,PixelWidth,PixelHeight,type,(__bridge CFDictionaryRef)attrs,&pixel)!=kCVReturnSuccess)Fail("pattern allocation");
  if(CVPixelBufferLockBaseAddress(pixel,0)!=kCVReturnSuccess)Fail("pattern lock");
  if(nativeYUV){
    uint8_t *luma=CVPixelBufferGetBaseAddressOfPlane(pixel,0),*uv=CVPixelBufferGetBaseAddressOfPlane(pixel,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(pixel,0),cs=CVPixelBufferGetBytesPerRowOfPlane(pixel,1);
    for(unsigned y=0;y<PixelHeight;y++)for(unsigned x=0;x<PixelWidth;x++){
      int b=(x+n*17)%256,g=(y+n*29)%256,r=((x/80+y/80+n)%2)?230:25;
      luma[y*ys+x]=(uint8_t)(16+((47*r+157*g+16*b+128)>>8));
    }
    for(unsigned y=0;y<PixelHeight;y+=2)for(unsigned x=0;x<PixelWidth;x+=2){
      int r=0,g=0,b=0;
      for(unsigned dy=0;dy<2;dy++)for(unsigned dx=0;dx<2;dx++){b+=(x+dx+n*17)%256;g+=(y+dy+n*29)%256;r+=(((x+dx)/80+(y+dy)/80+n)%2)?230:25;}
      r=(r+2)/4;g=(g+2)/4;b=(b+2)/4;
      uv[(y/2)*cs+x]=(uint8_t)(128+((-26*r-87*g+112*b+128)>>8));
      uv[(y/2)*cs+x+1]=(uint8_t)(128+((112*r-102*g-10*b+128)>>8));
    }
    CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
  }else{
    uint8_t *base=CVPixelBufferGetBaseAddress(pixel);size_t stride=CVPixelBufferGetBytesPerRow(pixel);
    for(unsigned y=0;y<PixelHeight;y++)for(unsigned x=0;x<PixelWidth;x++){uint8_t *q=base+y*stride+x*4;q[0]=(x+n*17)%256;q[1]=(y+n*29)%256;q[2]=((x/80+y/80+n)%2)?230:25;q[3]=255;}
  }
  if(tuning && !benchmark && !nativeYUV){
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixel),PixelWidth,PixelHeight,8,CVPixelBufferGetBytesPerRow(pixel),space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);CGColorSpaceRelease(space);
    if(!context)Fail("quality pattern context");
    CGContextSetRGBFillColor(context,1,1,1,1);CGContextFillRect(context,CGRectMake(64,64,MIN(1800u,PixelWidth-128),500));
    for(unsigned row=0;row<5;row++){
      CTFontRef font=CTFontCreateWithName(CFSTR("Helvetica"),22+row*4,NULL);
      NSDictionary *attributes=@{(__bridge id)kCTFontAttributeName:(__bridge id)font,(__bridge id)kCTForegroundColorFromContextAttributeName:@YES};
      NSAttributedString *text=[[NSAttributedString alloc]initWithString:@"ThunderControl Retina 2x 0123456789 AaBbCc Small text clarity" attributes:attributes];
      CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
      CGContextSetRGBFillColor(context,0,0,0,1);CGContextSetTextPosition(context,90,120+row*78);CTLineDraw(line,context);CFRelease(line);CFRelease(font);
    }
    CGContextRelease(context);
  }
  if(tuning && !benchmark && !nativeYUV && !strcmp(tuneLabel,"baseline")){
    const char *directory=getenv("TC_TUNE_REFERENCE_DIRECTORY");
    if(directory){
      char file[2048];int length=snprintf(file,sizeof(file),"%s/frame%u.bgra",directory,n);if(length<0 || (size_t)length>=sizeof(file))Fail("reference path");
      int fd=open(file,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)Fail("reference file");
      uint32_t header[3]={CFSwapInt32HostToBig(PixelWidth),CFSwapInt32HostToBig(PixelHeight),CFSwapInt32HostToBig((uint32_t)CVPixelBufferGetBytesPerRow(pixel))};
      if(write(fd,header,sizeof(header))!=sizeof(header))Fail("reference header");
      const uint8_t *bytes=CVPixelBufferGetBaseAddress(pixel);size_t left=CVPixelBufferGetBytesPerRow(pixel)*PixelHeight;
      while(left){ssize_t count=write(fd,bytes,left);if(count<0&&errno==EINTR)continue;if(count<=0)Fail("reference write");bytes+=count;left-=(size_t)count;}
      if(close(fd)!=0)Fail("reference close");
    }
  }
  CVPixelBufferUnlockBaseAddress(pixel,0);return pixel;
}
static int Synthetic(void){
  InitEncoder();uint8_t id[5]={1,0,0,0,0};Output([NSData dataWithBytes:id length:5]);
  for(int n=0;n<8;n++){@autoreleasepool {
    CVPixelBufferRef pixel=PatternPixel((unsigned)n);
    double deadline=Now()+3;while(atomic_load(&inFlight)>=encodingSlots){if(Now()>deadline)Fail("encoder timeout");usleep(200);}
    Submit(pixel,CMTimeMake(n,targetFPS));CVPixelBufferRelease(pixel);
  }}
  double finalDeadline=Now()+3;while(atomic_load(&inFlight)){if(Now()>finalDeadline)Fail("encoder final timeout");usleep(200);}
  if(atomic_load(&emitted)!=8)Fail("synthetic frame count");VTCompressionSessionInvalidate(encoder);CFRelease(encoder);
  fprintf(stderr,"PASS synthetic hardware H264 negotiatedFormatValid=yes frames=8 maximumInFlight=%u perFrameFlush=no; no display capture or network\n",atomic_load(&maximumInFlight));return 0;
}
static int CompareDouble(const void *a,const void *b){double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);}
static int Benchmark(void){
  InitEncoder();
  CVPixelBufferRef pixels[8]={0};for(unsigned n=0;n<8;n++)pixels[n]=PatternPixel(n);
  if(captureBenchmark)frameQueue=dispatch_queue_create("local.ThunderControl.capture.benchmark",DISPATCH_QUEUE_SERIAL);
  double start=Now();BOOL stalled=NO;unsigned submitted=0;
  // Both configurations offered the same60Hz generated pattern. Legacy keeps
  // its actual0.8.17 expectedFPS30; no per-frame CompleteFrames shortcut.
  for(unsigned i=0;i<600;i++){
    double due=start+(double)i/60;while(Now()<due)usleep(200);
    if(captureBenchmark){CVPixelBufferRef pixel=pixels[i%8];CMTime pts=CMTimeMake(i,targetFPS);dispatch_sync(frameQueue,^{if(captureLegacy)Submit(pixel,pts);else OfferCaptureAt(pixel,pts,due);});submitted++;}
    else {Submit(pixels[i%8],CMTimeMake(i,targetFPS));submitted++;
      double deadline=Now()+1;while(atomic_load(&inFlight)&&Now()<deadline)usleep(200);
      if(atomic_load(&inFlight)){stalled=YES;break;}}
  }
  if(captureBenchmark){
    double deadline=Now()+3;BOOL busy=YES;
    while(busy && Now()<deadline){__block BOOL pending=NO;dispatch_sync(frameQueue,^{pending=latestCapture!=NULL;});busy=atomic_load(&inFlight)||pending;if(busy)usleep(200);}
    stalled=busy;
  }
  {
  }
  double elapsed=Now()-start;
  // No further callback array access after invalidation has drained the encoder.
  VTCompressionSessionInvalidate(encoder);CFRelease(encoder);encoder=NULL;
  for(int i=0;i<8;i++)CVPixelBufferRelease(pixels[i]);
  unsigned n=latencyCount;double sum=0,max=0;for(unsigned i=0;i<n;i++){sum+=latencies[i];if(latencies[i]>max)max=latencies[i];}
  qsort(latencies,n,sizeof(double),CompareDouble);
  printf("BENCHMARK config=%s offeredFPS=60 submitted=%u callbacks=%u codecDrops=%u elapsedMs=%.3f callbackFPS=%.3f meanEncodeMs=%.3f p95EncodeMs=%.3f maxEncodeMs=%.3f pipelineStalled=%s perFrameFlush=no realCapture=no network=no\n",captureBenchmark?(encodingSlots>1?(nativeYUV?"capture-nv12-2slots":"capture-2slots"):captureLegacy?"capture-drop":"capture-latest"):legacyEncoder?"legacy":benchmarkSpeed?"speed":"quality",submitted,n,atomic_load(&encoderDropped),elapsed*1000,n/elapsed,n?sum/n:0,n?latencies[(n*95+99)/100-1]:0,max,stalled?"yes":"no");
  double ageSum=0;for(unsigned i=0;i<n;i++)ageSum+=frameAges[i];qsort(frameAges,n,sizeof(double),CompareDouble);
  printf("FRESHNESS profile=%s slots=%u speed=%s rateControl=%s baselineProfile=%s meanAgeMs=%.3f p95AgeMs=%.3f lastCapture=%llu finalExpected=599\n",tuneLabel,encodingSlots,speedPriority?"verified":"off/unsupported",lowLatencyRateControl?"accepted":"off/fallback",tuneBaselineProfile?"yes":"no",n?ageSum/n:0,n?frameAges[(n*95+99)/100-1]:0,(unsigned long long)lastCaptureSequence);
  printf("ENCODED_AOI profile=%s meanMs=%.3f windowMs=%.3f; warmup60outputsExcluded=yes no_decode_network_panel\n",tuneLabel,ageDuration>0 ? ageArea/ageDuration*1000:0,ageDuration*1000);
  return stalled?4:0;
}
// Pure field-by-field comparator for a mocked physical baseline snapshot vs.
// a mocked observed snapshot (same shape as the harness ScreenState). Returns
// first mismatch field name, or NULL if all fields match for all entries.
// Used only by --selftest; NOT invoked by the live preservation path (that
// uses live CoreGraphics reads in BaselinePreserved()).
typedef struct {uint32_t id,mirror;bool active;int32_t x,y,w,h;size_t pw,ph;int32_t modeID;} MockDisplay;
static const char *MockBaselineMismatch(const MockDisplay *base,const MockDisplay *obs,uint32_t count){
  for(uint32_t i=0;i<count;i++){
    if(base[i].id!=obs[i].id)return "id";
    if(base[i].mirror!=obs[i].mirror)return "mirror";
    if(base[i].active!=obs[i].active)return "active";
    if(base[i].x!=obs[i].x||base[i].y!=obs[i].y||base[i].w!=obs[i].w||base[i].h!=obs[i].h)return "bounds";
    if(base[i].pw!=obs[i].pw||base[i].ph!=obs[i].ph)return "pixelSize";
    if(base[i].modeID!=obs[i].modeID)return "modeID";
  }
  return NULL;
}
// Pure predicate: should display at index i receive a CGConfigureDisplayOrigin
// write during the setup transaction? Per CGDisplayConfiguration.h, writing
// origin on a currently-mirroring display removes it from the mirror set, so
// aliases MUST NOT receive origin writes. Only pre-create roots do.
static inline bool MockShouldWriteOrigin(const MockDisplay *d){return d->mirror==0;}
// Pure predicate: does the online ID set exactly equal baseline union {owned}?
// Must reject external additions, baseline removals, and owned-missing.
static bool MockOnlineExact(const uint32_t *baseIDs,uint32_t baseCount,uint32_t owned,const uint32_t *online,uint32_t onlineCount){
  if(onlineCount!=baseCount+1)return false;
  bool ownedSeen=false;for(uint32_t j=0;j<onlineCount;j++)if(online[j]==owned){ownedSeen=true;break;}
  if(!ownedSeen)return false;
  for(uint32_t i=0;i<baseCount;i++){bool p=false;for(uint32_t j=0;j<onlineCount;j++)if(online[j]==baseIDs[i]){p=true;break;}if(!p)return false;}
  for(uint32_t j=0;j<onlineCount;j++){bool k=online[j]==owned;for(uint32_t i=0;!k&&i<baseCount;i++)if(online[j]==baseIDs[i])k=true;if(!k)return false;}
  return true;
}
// --selftest: pure, offline validation of the bounded-helper state machine.
// Touches NO displays, NO CoreGraphics mutations, NO network, NO encoder.
// Exercises BoundedInvalidFatal / BoundedHeartbeatFatal + Reconfigured
// invariants + CanSubmitFrame transitions + preservation-policy field
// coverage on a simulated clock and mocked baseline snapshots.
// Offline pipe/concurrency fixtures. No display, capture, session or input APIs.
static BOOL TestReadExact(int fd,void *bytes,size_t length){
  uint8_t *p=bytes;double deadline=Now()+2;
  while(length && Now()<deadline){ssize_t n=read(fd,p,length);if(n>0){p+=n;length-=(size_t)n;continue;}if(n==0)return NO;if(errno==EINTR)continue;if(errno!=EAGAIN&&errno!=EWOULDBLOCK)return NO;struct pollfd pf={fd,POLLIN,0};if(poll(&pf,1,20)<0&&errno!=EINTR)return NO;}
  return length==0;
}
static NSData *TestReadPacket(int fd){uint32_t be=0;if(!TestReadExact(fd,&be,4))return nil;uint32_t n=CFSwapInt32BigToHost(be);if(!n||n>64)return nil;NSMutableData *data=[NSMutableData dataWithLength:n];return TestReadExact(fd,data.mutableBytes,n)?data:nil;}
static BOOL TestPipe(int fd[2]){if(pipe(fd))return NO;for(int n=0;n<2;n++)if(fcntl(fd[n],F_SETFL,fcntl(fd[n],F_GETFL)|O_NONBLOCK)<0){close(fd[0]);close(fd[1]);return NO;}return YES;}
static NSData *TestCursorPacket(void){uint8_t bytes[19]={7};bytes[9]=1;bytes[10]=2;return [NSData dataWithBytes:bytes length:19];}
static BOOL TestCursorGuardIsolation(void){
  int fd[2];if(!TestPipe(fd))return NO;
  dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
  dispatch_group_t done=dispatch_group_create();__block BOOL cursor=NO;int writeFD=fd[1];
  dispatch_group_async(done,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
    cursor=TryCursorOutput(TestCursorPacket(),atomic_load(&reconfigEpoch),^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));},writeFD);
  }});
  BOOL ok=dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
  uint8_t video[2]={2,42};OutputWithGuard([NSData dataWithBytes:video length:2],^{},fd[1]);
  NSData *first=TestReadPacket(fd[0]);ok=ok&&[first isEqual:[NSData dataWithBytes:video length:2]];
  // The video completed while the simulated OS cursor query was still blocked.
  dispatch_semaphore_signal(release);
  ok=(dispatch_group_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0)&&ok;
  NSData *second=TestReadPacket(fd[0]);ok=ok&&cursor&&second.length==19&&((const uint8_t*)second.bytes)[0]==7;
  close(fd[0]);close(fd[1]);return ok;
}
static BOOL TestCursorBusyAndEpoch(void){
  int fd[2];if(!TestPipe(fd))return NO;
  dispatch_group_t done=dispatch_group_create();__block BOOL sent=YES;int writeFD=fd[1];
  pthread_mutex_lock(&writeMutex);
  dispatch_group_async(done,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{sent=TryCursorOutput(TestCursorPacket(),atomic_load(&reconfigEpoch),^{},writeFD);}});
  BOOL ok=dispatch_group_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
  pthread_mutex_unlock(&writeMutex);
  ok=ok&&!sent;
  // An invalidated geometry proof cannot publish a visible stale cursor.
  ok=TryCursorOutput(TestCursorPacket(),atomic_load(&reconfigEpoch)+1,^{},fd[1])&&ok;
  NSData *hidden=TestReadPacket(fd[0]);ok=ok&&hidden.length==19;
  if(hidden.length==19)for(NSUInteger n=9;n<19;n++)ok=ok&&((const uint8_t*)hidden.bytes)[n]==0;
  close(fd[0]);close(fd[1]);return ok;
}
static BOOL TestWriterBackpressureOrdering(void){
  int fd[2];if(!TestPipe(fd))return NO;
  uint8_t filler[512]={0};size_t filled=0;for(;;){ssize_t n=write(fd[1],filler,sizeof(filler));if(n>0){filled+=(size_t)n;continue;}if(n<0&&errno==EINTR)continue;break;}
  // A full pipe drops the atomic cursor message instead of polling or tearing it.
  BOOL ok=!TryCursorOutput(TestCursorPacket(),atomic_load(&reconfigEpoch),^{},fd[1]);
  unsigned savedSlots=encodingSlots;int savedFD=outputFD;outputFD=fd[1];encodingSlots=2;
  atomic_store(&inFlight,0);atomic_store(&emitted,0);outputOrder=(EncodedOrderWindow){0};
  ok=ReserveEncoding()&&ReserveEncoding()&&ok;
  uint8_t zero[2]={2,0},one[2]={2,1};double now=Now();
  PublishEncoded([NSData dataWithBytes:one length:2],(EncodeTicket){.sequence=1,.started=now,.capturedAt=now},NO);
  PublishEncoded([NSData dataWithBytes:zero length:2],(EncodeTicket){.sequence=0,.started=now,.capturedAt=now},NO);
  // Both callbacks returned despite the blocked writer; no third slot is freed.
  ok=ok&&atomic_load(&inFlight)==2&&!ReserveEncoding();
  while(filled){size_t n=MIN(filled,sizeof(filler));if(!TestReadExact(fd[0],filler,n)){ok=NO;break;}filled-=n;}
  NSData *a=TestReadPacket(fd[0]),*b=TestReadPacket(fd[0]);
  ok=ok&&[a isEqual:[NSData dataWithBytes:zero length:2]]&&[b isEqual:[NSData dataWithBytes:one length:2]];
  double deadline=Now()+2;while(atomic_load(&inFlight)&&Now()<deadline)usleep(100);
  ok=ok&&atomic_load(&inFlight)==0&&atomic_load(&emitted)==2;
  dispatch_sync(WriterQueue(),^{});outputFD=savedFD;encodingSlots=savedSlots;outputOrder=(EncodedOrderWindow){0};
  atomic_store(&emitted,0);atomic_store(&inFlight,0);atomic_store(&maximumInFlight,0);
  close(fd[0]);close(fd[1]);return ok;
}
// Offline lifetime sentinel: an autoreleasing store deliberately leaves its
// last ownership in the current pool, just like autoreleased framework results.
@interface HelperIterationTestSentinel:NSObject
@property(assign) unsigned *deallocations;
@end
@implementation HelperIterationTestSentinel
-(void)dealloc {if(_deallocations)(*_deallocations)++;}
@end
static BOOL TestIterationAutoreleaseBoundary(void){
  __block unsigned destroyed=0;__block BOOL ok=YES;
  __block __weak HelperIterationTestSentinel *weakSentinel=nil;
  // Control: the sentinel must survive the local variable's scope and Pump's
  // nested pool, so this fixture would catch a missing iteration boundary.
  @autoreleasepool {
    ^{
      __autoreleasing HelperIterationTestSentinel *sentinel=[HelperIterationTestSentinel new];
      sentinel.deallocations=&destroyed;weakSentinel=sentinel;
    }();
    Pump(0);ok=weakSentinel!=nil&&destroyed==0;
  }
  ok=ok&&weakSentinel==nil&&destroyed==1;
  for(unsigned n=0;n<1024;n++){
    RunPooledIteration(^{
      __autoreleasing HelperIterationTestSentinel *sentinel=[HelperIterationTestSentinel new];
      sentinel.deallocations=&destroyed;weakSentinel=sentinel;
      Pump(0);ok=ok&&weakSentinel!=nil&&destroyed==n+1;
    });
    // Must drain before the next iteration, while main's outer pool is alive.
    ok=ok&&weakSentinel==nil&&destroyed==n+2;
  }
  return ok;
}
// Optional GUI-session regression: application-local synthetic event only.
// No window, virtual display, capture, network or CG input posting.
@interface HelperPumpTestApplication:NSApplication
@property BOOL sawPumpTestEvent;
@end
@implementation HelperPumpTestApplication
-(void)sendEvent:(NSEvent*)event {
  if(event.type==NSEventTypeApplicationDefined && event.subtype==0x5443){self.sawPumpTestEvent=YES;return;}
  [super sendEvent:event];
}
@end
// The helper lives inside the app bundle and registers with the SAME bundle id,
// so "quit app id …" (AppleScript, installers) may be routed here instead of the
// main app. A helper exit then looks like a video failure and the parent resumes
// video while the user is actually quitting. Lifecycle belongs to the parent
// (pipe/heartbeat/parent-exit), so a quit Apple event is acknowledged and ignored.
@interface HelperQuitEventSink:NSObject
@property(nonatomic) unsigned ignored;
-(void)handleQuit:(NSAppleEventDescriptor*)event withReply:(NSAppleEventDescriptor*)reply;
@end
@implementation HelperQuitEventSink
-(void)handleQuit:(NSAppleEventDescriptor*)event withReply:(NSAppleEventDescriptor*)reply{(void)event;(void)reply;self.ignored++;fprintf(stderr,"Display helper ignored a quit Apple event; the parent app owns helper lifetime\n");}
@end
static HelperQuitEventSink *helperQuitSink=nil;
static void InstallHelperQuitSink(void){
  if(!helperQuitSink)helperQuitSink=[HelperQuitEventSink new];
  [[NSAppleEventManager sharedAppleEventManager] setEventHandler:helperQuitSink andSelector:@selector(handleQuit:withReply:) forEventClass:kCoreEventClass andEventID:kAEQuitApplication];
}
static int EventPumpSelfTest(void){
  HelperPumpTestApplication *app=[HelperPumpTestApplication sharedApplication];
  [app setActivationPolicy:NSApplicationActivationPolicyProhibited];[app finishLaunching];
  NSEvent *event=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0x5443 data1:0 data2:0];
  if(!event)return 5;[app postEvent:event atStart:NO];RunPooledIteration(^{Pump(.1);});
  fprintf(stderr,"%s helper AppKit event pump: local event delivered, no window/display/capture/input posting\n",app.sawPumpTestEvent?"PASS":"FAIL");
  InstallHelperQuitSink();
  NSAppleEventDescriptor *target=[NSAppleEventDescriptor descriptorWithProcessIdentifier:getpid()];
  NSAppleEventDescriptor *quit=[NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:kAEQuitApplication targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
  AppleEvent rawReply={typeNull,NULL};
  [[NSAppleEventManager sharedAppleEventManager] dispatchRawAppleEvent:quit.aeDesc withRawReply:&rawReply handlerRefCon:(SRefCon)&rawReply];
  AEDisposeDesc(&rawReply);
  BOOL quitIgnored=helperQuitSink.ignored==1;
  fprintf(stderr,"%s helper quit Apple event routed to ignoring sink; parent owns lifetime\n",quitIgnored?"PASS":"FAIL");
  return app.sawPumpTestEvent&&quitIgnored?0:5;
}
static BOOL TestDisplayIdentityLock(void){
  char directory[PATH_MAX];
  int length=snprintf(directory,sizeof(directory),"%s/tc-identity.XXXXXX",NSTemporaryDirectory().fileSystemRepresentation);
  if(length<0||(size_t)length>=sizeof(directory)||!mkdtemp(directory))return NO;
  char path[PATH_MAX],other[PATH_MAX];
  snprintf(path,sizeof(path),"%s/display.lock",directory);snprintf(other,sizeof(other),"%s/other",directory);
  int first=AcquireDisplayIdentityLock(directory,geteuid()),second=-1;BOOL ok=first>=0;
  if(first>=0){
    second=AcquireDisplayIdentityLock(directory,geteuid());ok=ok&&second<0;if(second>=0)close(second);
    pid_t child=fork();
    if(child==0){close(first);int fd=AcquireDisplayIdentityLock(directory,geteuid());if(fd>=0)close(fd);_exit(fd<0?0:1);}
    int status=0;pid_t waited=-1;if(child>0){do{waited=waitpid(child,&status,0);}while(waited<0&&errno==EINTR);}
    ok=ok&&child>0&&waited==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0;
    close(first);
    second=AcquireDisplayIdentityLock(directory,geteuid());ok=ok&&second>=0;if(second>=0)close(second);
  }
  ok=ok&&AcquireDisplayIdentityLock(directory,geteuid()+1)<0;
  unlink(path);BOOL linked=symlink("/dev/null",path)==0;
  second=AcquireDisplayIdentityLock(directory,geteuid());ok=ok&&linked&&second<0;if(second>=0)close(second);unlink(path);
  int temp=open(other,O_WRONLY|O_CREAT|O_EXCL,0600);if(temp>=0)close(temp);
  linked=temp>=0&&link(other,path)==0;
  second=AcquireDisplayIdentityLock(directory,geteuid());ok=ok&&linked&&second<0;if(second>=0)close(second);
  unlink(path);unlink(other);chmod(directory,0777);
  second=AcquireDisplayIdentityLock(directory,geteuid());ok=ok&&second<0;if(second>=0)close(second);
  chmod(directory,0700);unlink(path);rmdir(directory);return ok;
}
// Offline diagnostic checks: no capture/display/encoder APIs invoked.
static int TestDiagFormat(char *line,size_t capacity,const char *stage,uint64_t seq,uint64_t capture,const char *format,...){
  va_list args;va_start(args,format);int n=DiagFormat(line,capacity,stage,seq,capture,format,args);va_end(args);return n;
}
static BOOL TestDiagnosticRecords(void){
  struct {char line[_POSIX_PIPE_BUF];char sentinel;} bounded={.sentinel=73};
  int n=TestDiagFormat(bounded.line,sizeof(bounded.line),"encode_call_end",UINT64_MAX-1,UINT64_MAX,"us=%llu status=%u flags=%u",DU(UINT64_MAX),UINT_MAX,UINT_MAX);
  if(n<=0||n>=_POSIX_PIPE_BUF||bounded.sentinel!=73||bounded.line[n-1]!='\n')return NO;
  // Parse the exact public key=value grammar and decimal-only values.
  char *state=NULL;char *token=strtok_r(bounded.line," \n",&state);if(!token||strcmp(token,"TC_DIAG"))return NO;
  unsigned fields=0;while((token=strtok_r(NULL," \n",&state))){char *equal=strchr(token,'=');if(!equal)return NO;*equal=0;if(!DiagIdentifier(token))return NO;
    if(!strcmp(token,"stage")){if(strcmp(equal+1,"encode_call_end"))return NO;}
    else {const char *v=equal+1;if(!*v)return NO;for(;*v;v++)if(*v<'0'||*v>'9')return NO;}fields++;
  }
  if(fields!=6)return NO;
  if(TestDiagFormat(bounded.line,sizeof(bounded.line),"bad stage",0,0,"us=0")>=0)return NO;
  if(TestDiagFormat(bounded.line,sizeof(bounded.line),"bounds",0,0,"us=%0600u",0)>=0||bounded.sentinel!=73)return NO;
  if(TestDiagFormat(bounded.line,1,"bounds",0,0,"us=0")>=0)return NO;
  unsigned long long truncated=atomic_load(&diagTruncated);
  Diag("bounds",DiagNoSequence,0,"us=%0600u",0);
  if(diagEnabled&&atomic_load(&diagTruncated)!=truncated+1)return NO;
  int stdoutFlags=fcntl(STDOUT_FILENO,F_GETFL);
  int fd[2];if(pipe(fd))return NO;BOOL ok=DiagNonblocking(fd[1])&&fcntl(STDOUT_FILENO,F_GETFL)==stdoutFlags;
  char filler[_POSIX_PIPE_BUF]={0};while(ok){ssize_t count=write(fd[1],filler,sizeof(filler));if(count<0){ok=errno==EAGAIN||errno==EWOULDBLOCK;break;}if(count==0){ok=NO;break;}}
  unsigned long long before=atomic_load(&diagEagain);errno=EDOM;DiagWrite(fd[1],"test\n",5);
  ok=ok&&errno==EDOM&&atomic_load(&diagEagain)==before+1;
  // Drain once enough space is available, then verify a later summary exposes
  // the cumulative loss despite the earlier failed diagnostic write.
  ok=ok&&DiagNonblocking(fd[0]);while(read(fd[0],filler,sizeof(filler))>0){}
  n=TestDiagFormat(bounded.line,sizeof(bounded.line),"diagnostics_aggregate",0,0,"eagain=%llu",DU(atomic_load(&diagEagain)));
  if(n<=0)ok=NO;else {DiagWrite(fd[1],bounded.line,(size_t)n);char readback[_POSIX_PIPE_BUF];ssize_t got=read(fd[0],readback,sizeof(readback));ok=ok&&got==n&&!memcmp(readback,bounded.line,(size_t)n);}
  close(fd[0]);close(fd[1]);
  unsigned long long partial=atomic_load(&diagPartial),failed=atomic_load(&diagFailed);
  DiagWriteResult(2,5,0);DiagWriteResult(-1,5,EINTR);
  return ok&&atomic_load(&diagPartial)==partial+1&&atomic_load(&diagFailed)==failed+1;
}
static int SelfTest(void){
  int failures=0;
  #define CHECK(cond,name) do{if(!(cond)){fprintf(stderr,"FAIL %s\n",name);failures++;}else fprintf(stderr,"PASS %s\n",name);}while(0)

  CHECK(StableDisplaySerial(501)==502 && StableDisplaySerial(501)==StableDisplaySerial(501),"display-identity-stable-across-starts");
  CHECK(StableDisplaySerial(501)!=StableDisplaySerial(502),"display-identity-separated-by-user");
  CHECK(StableDisplaySerial(0)==1 && StableDisplaySerial((uid_t)UINT32_MAX-1)==UINT32_MAX && StableDisplaySerial((uid_t)UINT32_MAX)==0,"display-identity-nonzero-and-invalid-user-fails-closed");
  CHECK(SameDisplayIdentity(505,0x6001,502,502) && !SameDisplayIdentity(506,0x6001,502,502) && !SameDisplayIdentity(505,0x6002,502,502) && !SameDisplayIdentity(505,0x6001,503,502) && !SameDisplayIdentity(505,0x6001,0,0),"display-identity-collision-exact-match");
  CHECK(TestDisplayIdentityLock(),"display-identity-lock-cross-process-release-symlink-hardlink-permissions");
  CHECK(TestCursorGuardIsolation(),"cursor-slow-guard-does-not-lock-video");
  CHECK(TestCursorBusyAndEpoch(),"cursor-busy-skips-and-stale-epoch-hides");
  CHECK(DiagReasonCode("")==2166136261u && DiagReasonCode("a")==0xe40c292cu && DiagReasonCode("foobar")==0xbf9cf968u && DiagReasonCode("output stalled")==DiagReasonCode("output stalled"),"diagnostics-failure-fnv1a32-known-stable");
  CHECK(TestDiagnosticRecords(),"diagnostics-bounds-identifiers-numeric-parser-nonblocking-loss-visibility");
  CHECK(TestWriterBackpressureOrdering(),"writer-backpressure-callbacks-return-two-slot-bound-and-order");

  CHECK(TestIterationAutoreleaseBoundary(),"iteration-autorelease-sentinel-control-and-1024-drains");
  CHECK(PumpWait(1,0)==0.025,"pump-long-wait-capped-25ms");
  CHECK(PumpWait(1,1)==0 && PumpWait(1,2)==0 && PumpWait(-1,0)==0,"pump-expired-negative-no-wait");
  CHECK(PumpWait(INFINITY,0)==0 && PumpWait(NAN,0)==0 && PumpWait(1,INFINITY)==0 && PumpWait(1,NAN)==0 && PumpWait(-INFINITY,0)==0,"pump-nonfinite-fails-closed");
  CHECK(fabs(PumpWait(1.0/60.0,0)-1.0/60.0)<1e-12,"pump-60hz-not-rounded-to-25ms");
  CHECK(fabs(PumpWait(1.0/60.0,0.010)-(1.0/60.0-0.010))<1e-12,"pump-guard-cost-consumes-deadline");
  CHECK(PumpWait(1.0/60.0,0.020)==0 && fabs(PumpWait(0.030,0.025)-0.005)<1e-12,"pump-final-leftover-no-oversleep");

  CHECK(SessionValuesSafe(@YES,@YES,@NO,NO) && SessionValuesSafe(@YES,@YES,@NO,YES),"password-secure-input-preserves-video");
  CHECK(!SessionValuesSafe(@YES,@YES,@YES,NO) && !SessionValuesSafe(@YES,@YES,@YES,YES),"screen-lock-still-stops-video");
  CHECK(!SessionValuesSafe(@NO,@YES,@NO,YES) && !SessionValuesSafe(@YES,@NO,@NO,YES) && !SessionValuesSafe(nil,@YES,@NO,YES) && !SessionValuesSafe(@YES,nil,@NO,YES),"inactive-unknown-session-still-stops-video");
  CHECK(!SessionValuesSafe(@1,@YES,@NO,YES) && !SessionValuesSafe(@YES,@1,@NO,YES) && !SessionValuesSafe(@YES,@YES,@1,YES),"malformed-session-state-fails-closed");
  CHECK(!StartupModeChooseAllowed(NO,YES,YES,YES,NO),"startup-mode-cannot-choose-before-detach-commit");
  CHECK(StartupModeChooseAllowed(YES,YES,YES,YES,NO),"startup-mode-choose-after-detach-before-arm");
  CHECK(!StartupModeChooseAllowed(YES,YES,YES,YES,YES),"startup-mode-no-post-arm-write");
  CHECK(!StartupModeChooseAllowed(YES,NO,YES,YES,NO) && !StartupModeChooseAllowed(YES,YES,NO,YES,NO) && !StartupModeChooseAllowed(YES,YES,YES,NO,NO),"startup-mode-requires-baseline-exactset-unmirrored");
  CHECK(StartupModeTargetAllowed(99,99,NO) && !StartupModeTargetAllowed(10,99,YES) && !StartupModeTargetAllowed(99,99,YES),"startup-second-transaction-owned-only");
  VirtualModeSize modePlan[2]={{0,0},{0,0}};
  CHECK(VirtualModePlan((VideoFormat){1512,945,2},modePlan)==2 &&
    modePlan[0].width==3024 && modePlan[0].height==1890 &&
    modePlan[1].width==1512 && modePlan[1].height==945,"mode-plan-odd-hidpi-anchor-first-logical-last");
  CHECK(VirtualModePlan((VideoFormat){1808,1130,2},modePlan)==2 &&
    modePlan[0].width==3616 && modePlan[0].height==2260 &&
    modePlan[1].width==1808 && modePlan[1].height==1130,"mode-plan-macbook-hidpi-anchor-first-logical-last");
  CHECK(VirtualModePlan(DefaultFormat,modePlan)==1 &&
    modePlan[0].width==1920 && modePlan[0].height==1080,"mode-plan-legacy-single");
  CHECK(VirtualModePlan((VideoFormat){UINT_MAX,UINT_MAX,2},modePlan)==0,"mode-plan-overflow-rejected-before-multiplication");
  CHECK(VirtualModePlan((VideoFormat){1512,945,1},modePlan)==0 &&
    VirtualModePlan((VideoFormat){1512,945,UINT_MAX},modePlan)==0,"mode-plan-invalid-format-rejected");
  // Format/parser tests are pure and cannot create a display or encoder.
  CHECK(FormatValid((VideoFormat){1920,1080,1}),"format-standard");
  CHECK(FormatValid((VideoFormat){640,480,1}),"format-minimum");
  CHECK(FormatValid((VideoFormat){1440,1440,1}),"format-square-pixel-limit");
  CHECK(FormatValid((VideoFormat){1920,800,1}),"format-aspect-upper-bound");
  CHECK(FormatValid((VideoFormat){1600,1000,1}),"format-macbook-16-10");
  CHECK(FormatValid((VideoFormat){1600,1040,1}),"format-macbook-20-13");
  CHECK(FormatValid((VideoFormat){1920,1024,1}),"format-macroblock-aligned");
  CHECK(!FormatValid((VideoFormat){1920,1160,1}),"format-macroblock-and-pixel-over-budget");
  const VideoFormat rejectedFormats[]={ {638,480,1},{1922,800,1},{640,478,1},{1440,1442,1},
    {641,480,1},{1600,1001,1},{1442,1440,1},{640,642,1},{1920,798,1},{UINT_MAX,UINT_MAX,1} };
  for(size_t i=0;i<sizeof(rejectedFormats)/sizeof(*rejectedFormats);i++)
    CHECK(!FormatValid(rejectedFormats[i]),"format-reject-invalid-limit");
  const char *legacyStream[]={"helper","--stream"};
  const char *legacySynthetic[]={"helper","--synthetic"};
  VideoFormat parsedFormat={0,0,1};
  CHECK(ParseArguments(2,legacyStream,&parsedFormat) && parsedFormat.width==1920 && parsedFormat.height==1080,"parse-legacy-stream-default");
  CHECK(ParseArguments(2,legacySynthetic,&parsedFormat) && parsedFormat.width==1920 && parsedFormat.height==1080,"parse-legacy-synthetic-default");
  const char *sized[]={"helper","--stream","--size","1600","1040"};
  CHECK(ParseArguments(5,sized,&parsedFormat) && parsedFormat.width==1600 && parsedFormat.height==1040,"parse-sized-stream");
  const char *sizedSynthetic[]={"helper","--synthetic","--size","1600","1000"};
  CHECK(ParseArguments(5,sizedSynthetic,&parsedFormat),"parse-sized-synthetic");
  const char *badNumbers[]={"","-640","+640"," 640","640 ","640x","640.0","0x280","4294967296","18446744073709551616"};
  for(size_t i=0;i<sizeof(badNumbers)/sizeof(*badNumbers);i++){
    const char *bad[]={"helper","--stream","--size",badNumbers[i],"480"};
    CHECK(!ParseArguments(5,bad,&parsedFormat),"parse-reject-nondecimal-or-overflow");
    const char *badHeight[]={"helper","--synthetic","--size","640",badNumbers[i]};
    CHECK(!ParseArguments(5,badHeight,&parsedFormat),"parse-reject-invalid-height-token");
  }
  const char *duplicate[]={"helper","--stream","--size","640","480","--size","640","480"};
  CHECK(!ParseArguments(8,duplicate,&parsedFormat),"parse-reject-duplicate");
  CHECK(!ParseArguments(1,legacyStream,&parsedFormat),"parse-reject-missing-mode");
  CHECK(!ParseArguments(4,sized,&parsedFormat),"parse-reject-missing-height");
  const char *trailing[]={"helper","--stream","--size","640","480","extra"};
  CHECK(!ParseArguments(6,trailing,&parsedFormat),"parse-reject-trailing");
  const char *badModes[]={"--benchmark-old","--benchmark-new","--benchmark-ratecontrol","--probe","--selftest","--unknown"};
  for(size_t i=0;i<sizeof(badModes)/sizeof(*badModes);i++){
    const char *bad[]={"helper",badModes[i],"--size","640","480"};
    CHECK(!ParseArguments(5,bad,&parsedFormat),"parse-reject-sized-unsupported-mode");
  }
  const char *wrongOption[]={"helper","--stream","--stream","640","480"};
  CHECK(!ParseArguments(5,wrongOption,&parsedFormat),"parse-reject-duplicate-mode");

  // Exhaustively compare each bounded integer pair with the Swift contract.
  BOOL contractMatches=YES;
  for(unsigned w=638;w<=1922;w++)for(unsigned h=478;h<=1442;h++){
    BOOL reference=w>=640 && w<=1920 && h>=480 && h<=1440 && w%2==0 && h%2==0 &&
      w*h<=2073600 && ((w+15)/16)*((h+15)/16)<=8704 &&
      (double)w/h>=1.0 && (double)w/h<=2.4;
    if(FormatValid((VideoFormat){w,h,1})!=reference)contractMatches=NO;
  }
  CHECK(contractMatches,"format-exhaustive-swift-contract-parity");
  const char *badSizes[][2]={{"639","480"},{"1922","800"},{"640","479"},{"1440","1442"},
    {"641","480"},{"1600","1001"},{"1442","1440"},{"640","642"},{"1920","798"},{"4294967295","480"}};
  for(size_t i=0;i<sizeof(badSizes)/sizeof(*badSizes);i++){
    const char *bad[]={"helper","--synthetic","--size",badSizes[i][0],badSizes[i][1]};
    CHECK(!ParseArguments(5,bad,&parsedFormat),"parse-reject-invalid-format-budget");
  }

  BOOL hidpiContractMatches=YES;
  for(unsigned w=638;w<=1922;w++)for(unsigned h=478;h<=1442;h++){
    uint64_t pw=(uint64_t)w*2,ph=(uint64_t)h*2;
    BOOL reference=w>=640 && w<=1920 && h>=480 && h<=1440 &&
      (uint64_t)w*h<=2073600 && pw*ph<=8294400 && ((pw+15)/16)*((ph+15)/16)<=34560 &&
      (double)w/h>=1.0 && (double)w/h<=2.4;
    if(FormatValid((VideoFormat){w,h,2})!=reference)hidpiContractMatches=NO;
  }
  CHECK(hidpiContractMatches,"format-exhaustive-hidpi-contract");
  CHECK(FormatValid((VideoFormat){1512,945,2}),"format-odd-logical-hidpi");
  CHECK(FormatValid((VideoFormat){1808,1130,2}),"format-macbook-hidpi");
  CHECK(!FormatValid((VideoFormat){1920,1080,0}) && !FormatValid((VideoFormat){640,480,UINT_MAX}),"format-invalid-scale");
  const char *scaled[]={"helper","--synthetic","--size","1512","945","--scale","2"};
  CHECK(ParseArguments(7,scaled,&parsedFormat) && parsedFormat.pixelScale==2,"parse-odd-hidpi");
  const char *scaleTokens[]={"0","3","-1","+2","2.0"," 2","2 ","","4294967296","18446744073709551616"};
  for(size_t i=0;i<sizeof(scaleTokens)/sizeof(*scaleTokens);i++){
    const char *bad[]={"helper","--synthetic","--scale",scaleTokens[i]};
    CHECK(!ParseArguments(4,bad,&parsedFormat),"parse-invalid-scale");
  }
  const char *explicitOne[]={"helper","--synthetic","--size","640","480","--scale","1"};
  const char *oddOne[]={"helper","--synthetic","--size","1512","945","--scale","1"};
  const char *scaleOnly[]={"helper","--synthetic","--scale","2"};
  const char *scaleOrigin[]={"helper","--synthetic","--scale","2","--origin","0","0"};
  CHECK(ParseArguments(7,explicitOne,&parsedFormat) && parsedFormat.pixelScale==1,"parse-explicit-scale-one");
  CHECK(!ParseArguments(7,oddOne,&parsedFormat),"parse-odd-scale-one-rejected");
  CHECK(ParseArguments(4,scaleOnly,&parsedFormat) && parsedFormat.width==1920 && parsedFormat.pixelScale==2,"parse-unsized-scale-two");
  CHECK(!ParseArguments(7,scaleOrigin,&parsedFormat),"parse-hidpi-synthetic-origin-rejected");
  for(size_t i=0;i<sizeof(badModes)/sizeof(*badModes);i++){
    const char *bad[]={"helper",badModes[i],"--scale","2"};
    CHECK(!ParseArguments(4,bad,&parsedFormat),"parse-scale-unsupported-mode");
  }
  const char *doubleScale[]={"helper","--stream","--scale","2","--scale","1"};
  const char *reversedScale[]={"helper","--stream","--scale","2","--size","1512","945"};
  const char *afterOrigin[]={"helper","--stream","--origin","0","0","--scale","2"};
  CHECK(!ParseArguments(6,doubleScale,&parsedFormat),"parse-duplicate-scale");
  CHECK(!ParseArguments(7,reversedScale,&parsedFormat),"parse-scale-before-size-rejected");
  CHECK(!ParseArguments(7,afterOrigin,&parsedFormat),"parse-scale-after-origin-rejected");
  CHECK(!ParseArguments(3,doubleScale,&parsedFormat),"parse-missing-scale");
  OwnedOrigin parsedSaved;
  const char *scaledOrigin[]={"helper","--stream","--size","1512","945","--scale","2","--origin","-1512","0"};
  CHECK(ParseInvocation(10,scaledOrigin,&parsedFormat,&parsedSaved) && parsedFormat.pixelScale==2 && parsedSaved.x==-1512,"parse-hidpi-origin-logical");
  const char *originOnly[]={"helper","--stream","--origin","-640","0"};
  CHECK(ParseInvocation(5,originOnly,&parsedFormat,&parsedSaved) && parsedSaved.requested && parsedSaved.x==-640 && parsedSaved.y==0 && parsedFormat.width==1920,"origin-parse-unsized-negative");
  const char *sizedOrigin[]={"helper","--stream","--size","640","480","--origin","1000000","-1000000"};
  CHECK(ParseInvocation(8,sizedOrigin,&parsedFormat,&parsedSaved) && parsedSaved.x==1000000 && parsedSaved.y==-1000000,"origin-parse-sized-bounded-limits");
  const char *badOriginTokens[]={"","-","+1"," 1","1 ","1.0","0x10","--1","1000001","-1000001","2147483648","-2147483649","4294967296","18446744073709551616","１"};
  for(size_t i=0;i<sizeof(badOriginTokens)/sizeof(*badOriginTokens);i++){
    const char *badX[]={"helper","--stream","--origin",badOriginTokens[i],"0"};
    const char *badY[]={"helper","--stream","--origin","0",badOriginTokens[i]};
    CHECK(!ParseInvocation(5,badX,&parsedFormat,&parsedSaved),"origin-reject-invalid-x");
    CHECK(!ParseInvocation(5,badY,&parsedFormat,&parsedSaved),"origin-reject-invalid-y");
  }
  const char *syntheticOrigin[]={"helper","--synthetic","--origin","0","0"};
  const char *sizedSyntheticOrigin[]={"helper","--synthetic","--size","640","480","--origin","0","0"};
  CHECK(!ParseInvocation(5,syntheticOrigin,&parsedFormat,&parsedSaved),"origin-reject-synthetic");
  CHECK(!ParseInvocation(8,sizedSyntheticOrigin,&parsedFormat,&parsedSaved),"origin-reject-sized-synthetic");
  const char *duplicateOrigin[]={"helper","--stream","--origin","0","0","--origin","1","1"};
  CHECK(!ParseInvocation(8,duplicateOrigin,&parsedFormat,&parsedSaved),"origin-reject-duplicate");
  const char *reverseOptions[]={"helper","--stream","--origin","0","0","--size","640","480"};
  CHECK(!ParseInvocation(8,reverseOptions,&parsedFormat,&parsedSaved),"origin-reject-reversed-options");
  const char *originTrailing[]={"helper","--stream","--origin","0","0","extra"};
  CHECK(!ParseInvocation(6,originTrailing,&parsedFormat,&parsedSaved),"origin-reject-trailing");
  CHECK(!ParseInvocation(4,originOnly,&parsedFormat,&parsedSaved),"origin-reject-missing-y");
  CHECK(ParseInvocation(2,legacyStream,&parsedFormat,&parsedSaved) && !parsedSaved.requested,"origin-legacy-not-requested");
  const VideoFormat placementFormat={640,480,1};
  const PlacementPhysical placementRoot={CGRectMake(0,0,640,480),YES,YES};
  const OwnedOrigin adjacentOrigins[]={ {YES,640,0},{YES,-640,0},{YES,0,-480},{YES,0,480},{YES,640,-479} };
  for(size_t i=0;i<sizeof(adjacentOrigins)/sizeof(*adjacentOrigins);i++)
    CHECK(SavedOriginValid(adjacentOrigins[i],placementFormat,&placementRoot,1),"origin-geometry-shared-edge-all-directions");
  const OwnedOrigin staleOrigins[]={ {YES,0,0},{YES,639,0},{YES,640,480},{YES,-640,-480},{YES,641,0},{YES,0,481},{YES,1000000,0},{YES,INT32_MAX,0},{YES,INT32_MIN,0},{NO,640,0} };
  for(size_t i=0;i<sizeof(staleOrigins)/sizeof(*staleOrigins);i++)
    CHECK(!SavedOriginValid(staleOrigins[i],placementFormat,&placementRoot,1),"origin-geometry-stale-overlap-point-gap-or-extent");
  const PlacementPhysical negativeRoot={CGRectMake(-1000,-500,640,480),YES,YES};
  CHECK(SavedOriginValid((OwnedOrigin){YES,-360,-500},placementFormat,&negativeRoot,1),"origin-geometry-negative-desktop");
  const PlacementPhysical inactiveRoot={placementRoot.bounds,NO,YES};
  const PlacementPhysical mirrorAlias={placementRoot.bounds,YES,NO};
  CHECK(!SavedOriginValid(adjacentOrigins[0],placementFormat,&inactiveRoot,1),"origin-geometry-no-edge-from-inactive");
  CHECK(!SavedOriginValid(adjacentOrigins[0],placementFormat,&mirrorAlias,1),"origin-geometry-no-edge-from-alias");
  const PlacementPhysical overlappingOther[]={placementRoot,{CGRectMake(1000,0,640,480),YES,YES}};
  CHECK(!SavedOriginValid(adjacentOrigins[0],placementFormat,overlappingOther,2),"origin-geometry-overlap-other-physical");
  const PlacementPhysical invalidRect={CGRectMake(NAN,0,640,480),YES,YES};
  CHECK(!SavedOriginValid(adjacentOrigins[0],placementFormat,&invalidRect,1),"origin-geometry-reject-nonfinite");
  const PlacementPhysical invalidExtent={CGRectMake(1000000,0,640,480),YES,YES};
  CHECK(!SavedOriginValid(adjacentOrigins[0],placementFormat,&invalidExtent,1),"origin-geometry-reject-physical-extent");
  CHECK(!SavedOriginValid(adjacentOrigins[0],(VideoFormat){641,480,1},&placementRoot,1),"origin-geometry-reject-invalid-mode");


  OwnedOrigin defaultLeft=DefaultOwnedOrigin(placementFormat,&placementRoot,1,placementRoot.bounds);
  CHECK(defaultLeft.requested && defaultLeft.x==-640 && defaultLeft.y==0,"default-owned-left-centered");
  const PlacementPhysical oddRoot={CGRectMake(-1000,-501,1200,901),YES,YES};
  OwnedOrigin oddLeft=DefaultOwnedOrigin((VideoFormat){800,600,2},&oddRoot,1,oddRoot.bounds);
  CHECK(oddLeft.requested && oddLeft.x==-1800 && fabs((double)oddLeft.y+350.5)<=0.5,"default-owned-logical-negative-odd-center");
  CHECK(!DefaultOwnedOrigin(placementFormat,&inactiveRoot,1,inactiveRoot.bounds).requested,"default-owned-no-inactive-anchor");
  const PlacementPhysical staggered[]={placementRoot,{CGRectMake(-640,2000,640,480),YES,YES}};
  CHECK(!DefaultOwnedOrigin(placementFormat,staggered,2,placementRoot.bounds).requested,"default-owned-staggered-no-valid-portal");
  const PlacementPhysical edgeRoot={CGRectMake(-1000000,0,640,480),YES,YES};
  CHECK(!DefaultOwnedOrigin(placementFormat,&edgeRoot,1,edgeRoot.bounds).requested,"default-owned-bounded-overflow-reject");

  // Bounded invalid-owned window: 0 -> never fatal; <=5s -> non-fatal; >5s fatal.
  CHECK(!BoundedInvalidFatal(0,0),"invalid-never-when-zero");
  CHECK(!BoundedInvalidFatal(100,100),"invalid-non-fatal-same-time");
  CHECK(!BoundedInvalidFatal(100,100+4999999999ULL),"invalid-non-fatal-under-5s");
  CHECK(!BoundedInvalidFatal(100,100+5000000000ULL),"invalid-non-fatal-at-5s-boundary");
  CHECK(BoundedInvalidFatal(100,100+5000000001ULL),"invalid-fatal-just-past-5s");
  CHECK(BoundedInvalidFatal(100,100+10000000000ULL),"invalid-fatal-far-past-5s");
  // Monotonic protection: now<since should not report fatal (clock skew).
  CHECK(!BoundedInvalidFatal(1000,500),"invalid-no-fatal-on-reverse-clock");

  // Heartbeat tolerance: 5s, since parent emits 0.5s heartbeats continuously
  // through the 12s raw-input pause (no hung-parent relaxation needed).
  CHECK(!BoundedHeartbeatFatal(0,0),"heartbeat-non-fatal-zero");
  CHECK(!BoundedHeartbeatFatal(0,4.9),"heartbeat-non-fatal-under-5s");
  CHECK(!BoundedHeartbeatFatal(0,5),"heartbeat-non-fatal-at-5s-boundary");
  CHECK(BoundedHeartbeatFatal(0,5.001),"heartbeat-fatal-just-past-5s");

  // CanSubmitFrame transitions in armed state (epoch-bound proof).
  atomic_store(&topologyArmed,false);
  atomic_store(&reconfigEpoch,0);atomic_store(&proofEpoch,0);
  CHECK(CanSubmitFrame(),"can-submit-when-not-armed");
  atomic_store(&topologyArmed,true);
  atomic_store(&ownedValid,false);atomic_store(&ownedValidatedNS,0);
  atomic_store(&reconfigEpoch,0);atomic_store(&proofEpoch,0);
  CHECK(!CanSubmitFrame(),"cannot-submit-when-armed-and-invalid");
  atomic_store(&ownedValid,true);atomic_store(&ownedValidatedNS,0);
  CHECK(!CanSubmitFrame(),"cannot-submit-without-fresh-proof");
  atomic_store(&ownedValid,true);atomic_store(&ownedValidatedNS,(uint64_t)(Now()*1e9));
  CHECK(CanSubmitFrame(),"can-submit-with-fresh-proof");
  // Epoch binding: an old proof must not resume frames after a reconfig bumps
  // the epoch, even if ownedValidatedNS is fresh and ownedValid is still true
  // (i.e. the watchdog overwrote state after a Reconfigured but before the
  // proof could be re-bound to the new epoch).
  atomic_store(&reconfigEpoch,5);atomic_store(&proofEpoch,5);
  atomic_store(&ownedValid,true);
  atomic_store(&ownedValidatedNS,(uint64_t)(Now()*1e9));
  CHECK(CanSubmitFrame(),"can-submit-when-proof-epoch-matches");
  atomic_fetch_add(&reconfigEpoch,1); // simulate Reconfigured bump
  CHECK(!CanSubmitFrame(),"stale-proof-epoch-rejects-after-reconfig");
  // Even if a subsequent racing writer re-stamped ownedValid/validatedNS
  // without rebinding proofEpoch, the submit must still be refused.
  atomic_store(&ownedValid,true);
  atomic_store(&ownedValidatedNS,(uint64_t)(Now()*1e9));
  CHECK(!CanSubmitFrame(),"racing-restore-without-epoch-rebind-rejected");
  // Rebinding proofEpoch to the current reconfigEpoch restores admission.
  atomic_store(&proofEpoch,atomic_load(&reconfigEpoch));
  CHECK(CanSubmitFrame(),"rebinding-proof-epoch-restores-admission");

  // Reconfigured callback must NOT exit, must flip owned invalid, must stamp
  // the invalid-since timestamp exactly once (earliest wins), and must bump
  // the reconfig epoch so any in-flight proof becomes stale.
  atomic_store(&topologyArmed,true);
  atomic_store(&ownedValid,true);
  atomic_store(&ownedInvalidSinceNS,0);
  unsigned epochBefore=atomic_load(&reconfigEpoch);
  Reconfigured(0,0,NULL);
  CHECK(!atomic_load(&ownedValid),"reconfig-marks-owned-invalid");
  CHECK(atomic_load(&reconfigEpoch)==epochBefore+1,"reconfig-bumps-epoch");
  uint64_t first=atomic_load(&ownedInvalidSinceNS);
  CHECK(first!=0,"reconfig-stamps-invalid-since");
  Reconfigured(0,0,NULL);
  CHECK(atomic_load(&ownedInvalidSinceNS)==first,"reconfig-preserves-earliest-stamp");
  CHECK(atomic_load(&reconfigEpoch)==epochBefore+2,"reconfig-bumps-epoch-again");

  // Reconfigured must be a no-op before arming (ordinary startup topology
  // changes shouldn't poison a not-yet-armed helper).
  atomic_store(&topologyArmed,false);
  atomic_store(&ownedValid,true);atomic_store(&ownedInvalidSinceNS,0);
  unsigned preArmEpoch=atomic_load(&reconfigEpoch);
  Reconfigured(0,0,NULL);
  CHECK(atomic_load(&ownedValid)==true,"reconfig-noop-before-arm");
  CHECK(atomic_load(&ownedInvalidSinceNS)==0,"reconfig-no-stamp-before-arm");
  CHECK(atomic_load(&reconfigEpoch)==preArmEpoch,"reconfig-no-epoch-bump-before-arm");

  // Preservation-policy coverage: every field in the harness ScreenState
  // comparison must be detected as a mismatch, so our pre-create snapshot +
  // in-transaction reassert must cover each of them (id/mirror/active/
  // bounds/pixelSize/modeID). This mirrors harness-side ScreenState equality
  // field-for-field; it does NOT change what the live BaselinePreserved()
  // checks, which goes through CoreGraphics directly.
  const MockDisplay base2[2]={
    {.id=1,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100},
    {.id=2,.mirror=1,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100},
  };
  CHECK(MockBaselineMismatch(base2,base2,2)==NULL,"preserve-exact-match-reports-no-mismatch");
  MockDisplay obs=base2[1];obs.mirror=0; // sibling unmirrored (the H1 side effect)
  const MockDisplay perturbMirror[2]={base2[0],obs};
  CHECK(MockBaselineMismatch(base2,perturbMirror,2) && !strcmp(MockBaselineMismatch(base2,perturbMirror,2),"mirror"),"preserve-detects-mirror-flip");
  const MockDisplay perturbActive[2]={ {.id=1,.mirror=0,.active=false,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100}, base2[1] };
  CHECK(MockBaselineMismatch(base2,perturbActive,2) && !strcmp(MockBaselineMismatch(base2,perturbActive,2),"active"),"preserve-detects-active-flip");
  const MockDisplay perturbBounds[2]={ {.id=1,.mirror=0,.active=true,.x=10,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100}, base2[1] };
  CHECK(MockBaselineMismatch(base2,perturbBounds,2) && !strcmp(MockBaselineMismatch(base2,perturbBounds,2),"bounds"),"preserve-detects-bounds-change");
  const MockDisplay perturbPixel[2]={ {.id=1,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=3840,.ph=2160,.modeID=100}, base2[1] };
  CHECK(MockBaselineMismatch(base2,perturbPixel,2) && !strcmp(MockBaselineMismatch(base2,perturbPixel,2),"pixelSize"),"preserve-detects-pixelsize-change");
  const MockDisplay perturbMode[2]={ {.id=1,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=999}, base2[1] };
  CHECK(MockBaselineMismatch(base2,perturbMode,2) && !strcmp(MockBaselineMismatch(base2,perturbMode,2),"modeID"),"preserve-detects-modeid-change");
  const MockDisplay perturbId[2]={ {.id=42,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100}, base2[1] };
  CHECK(MockBaselineMismatch(base2,perturbId,2) && !strcmp(MockBaselineMismatch(base2,perturbId,2),"id"),"preserve-detects-id-change-external-hotplug-removal");
  // Mirror-group integrity: a mirror pair preserved field-for-field (both
  // entries unchanged) must report no mismatch. We don't hardcode a mirror
  // topology; whatever the pre-create relationship was, we match it exactly.
  CHECK(MockBaselineMismatch(base2,base2,2)==NULL,"preserve-mirror-pair-exact-match");
  // Non-mirror baseline: all mirrors==0 for all displays. Preservation still
  // field-by-field; no implicit mirror enforcement.
  const MockDisplay independent[2]={
    {.id=1,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100},
    {.id=2,.mirror=0,.active=true,.x=1920,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=200},
  };
  CHECK(MockBaselineMismatch(independent,independent,2)==NULL,"preserve-independent-pair-exact-match");
  const MockDisplay independentPerturbed[2]={ independent[0], {.id=2,.mirror=1,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=200} };
  const char *m=MockBaselineMismatch(independent,independentPerturbed,2);
  CHECK(m && !strcmp(m,"mirror"),"preserve-detects-forced-mirror-on-independent-baseline");

  // Transaction ordering policy: aliases must NOT receive origin writes.
  const MockDisplay root={.id=1,.mirror=0,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100};
  const MockDisplay alias={.id=2,.mirror=1,.active=true,.x=0,.y=0,.w=1920,.h=1080,.pw=1920,.ph=1080,.modeID=100};
  CHECK(MockShouldWriteOrigin(&root),"root-receives-origin-write");
  CHECK(!MockShouldWriteOrigin(&alias),"alias-never-receives-origin-write");

  // ID-set exactness guard.
  const uint32_t baseIDs[2]={10,11};
  { const uint32_t online[3]={10,11,99}; CHECK(MockOnlineExact(baseIDs,2,99,online,3),"online-equals-baseline-plus-owned"); }
  { const uint32_t online[4]={10,11,99,55}; CHECK(!MockOnlineExact(baseIDs,2,99,online,4),"rejects-external-hotplug-addition"); }
  { const uint32_t online[2]={10,99};       CHECK(!MockOnlineExact(baseIDs,2,99,online,2),"rejects-baseline-removal"); }
  { const uint32_t online[2]={10,11};       CHECK(!MockOnlineExact(baseIDs,2,99,online,2),"rejects-owned-missing"); }
  { const uint32_t online[3]={10,11,55};    CHECK(!MockOnlineExact(baseIDs,2,99,online,3),"rejects-owned-mis-id"); }

  {EncodedOrderWindow order={0};uint64_t sequence=99;
    CHECK(!OrderAccept(&order,2,2),"order-outside-two-frame-window");
    CHECK(OrderAccept(&order,1,2),"order-second-callback-first");
    CHECK(!OrderTake(&order,&sequence),"order-never-emits-future-reference-first");
    CHECK(!OrderAccept(&order,1,2),"order-duplicate-rejected");
    CHECK(OrderAccept(&order,0,2),"order-first-callback");
    CHECK(OrderTake(&order,&sequence)&&sequence==0,"order-publishes-zero-first");
    CHECK(OrderTake(&order,&sequence)&&sequence==1,"order-publishes-one-second");
    CHECK(!OrderAccept(&order,0,2),"order-old-callback-rejected");
    CHECK(!OrderTake(&order,&sequence),"order-empty");
    unsigned savedSlots=encodingSlots;encodingSlots=2;atomic_store(&inFlight,0);
    CHECK(ReserveEncoding()&&ReserveEncoding(),"reserve-two");
    CHECK(!ReserveEncoding()&&atomic_load(&inFlight)==2,"reserve-never-exceeds-two");
    atomic_store(&inFlight,0);encodingSlots=savedSlots;
  }
  {LiveEncoderPolicy retina=ResponseFirstPolicy((VideoFormat){1512,950,2}),legacy=ResponseFirstPolicy((VideoFormat){1920,1080,1});
    CHECK(retina.slots==2 && retina.bitrateFactor==9 && retina.lowLatency && !retina.speedPriority,"live-response-first-retina");
    CHECK(legacy.slots==1 && !legacy.lowLatency && legacy.speedPriority,"legacy-response-policy-preserved");
    CHECK(LiveVideoMode("--stream")&&LiveVideoMode("--synthetic"),"live-profile-only-explicit-modes");
    CHECK(!LiveVideoMode("--benchmark-tune")&&!LiveVideoMode("--synthetic-tune"),"tuning-cannot-change-live-mode-selection");
    CHECK(ReferenceLimitVerified(noErr,noErr,(__bridge CFTypeRef)@1),"low-latency-ref-one-proof");
    CHECK(!ReferenceLimitVerified(noErr,noErr,(__bridge CFTypeRef)@8),"low-latency-ref-eight-falls-back");
    CHECK(!ReferenceLimitVerified(-12900,noErr,(__bridge CFTypeRef)@1),"low-latency-rejected-set-falls-back");
    CHECK(!ReferenceLimitVerified(noErr,-12900,NULL),"low-latency-missing-readback-falls-back");
    {NSDictionary *d=@{SCStreamFrameInfoStatus:@1,SCStreamFrameInfoDisplayTime:@123456789012ULL,SCStreamFrameInfoDirtyRects:@[@1,@2]},*e=@{};uint64_t t=7;
     CHECK(DiagRawStatus(d)==1&&DiagRawStatus(e)==-1,"diag-meta-raw-status");
     CHECK(DiagDisplayTicks(d,&t)&&t==123456789012ULL&&!DiagDisplayTicks(e,&t)&&t==0,"diag-meta-display-ticks");
     CHECK(DiagDirtyCount(d)==2&&DiagDirtyCount(e)==-1,"diag-meta-dirty-count");
     char line[_POSIX_PIPE_BUF];int n=snprintf(line,sizeof(line),"TC_DIAG stage=capture_callback capture=%llu us=%llu gap_us=%llu status_class=%u raw_status=%lld pts_ok=%u pts_value=%lld pts_scale=%d display_avail=%u display_ticks=%llu dirty_count=%lld entry_us=%llu fastguard_us=%llu\n",DU(UINT64_MAX),DU(UINT64_MAX),DU(UINT64_MAX),3u,-1LL,1u,-9223372036854775807LL,-1000000000,1u,DU(UINT64_MAX),-1LL,DU(UINT64_MAX),DU(UINT64_MAX));
     CHECK(n>0&&n<(int)sizeof(line)-1&&n<=512,"diag-meta-worst-case-line-fits");}
  }
  #undef CHECK
  fprintf(stderr,"%s selftest bounded-helper state machine + preservation policy (offline, no display mutation)\n",failures?"FAIL":"PASS");
  return failures?5:0;
}
int main(int argc,const char **argv){@autoreleasepool {
  diagEnabled=DiagNonblocking(STDERR_FILENO);
  VideoFormat parsed;OwnedOrigin parsedOrigin;
  const char *parseArgs[argc];for(int i=0;i<argc;i++)parseArgs[i]=argv[i];
  if(argc>=2 && (!strcmp(argv[1],"--benchmark-tune")||!strcmp(argv[1],"--synthetic-tune")||!strcmp(argv[1],"--benchmark-nv12")||!strcmp(argv[1],"--benchmark-pipeline")||!strcmp(argv[1],"--benchmark-capture-old")||!strcmp(argv[1],"--benchmark-capture-latest")||!strcmp(argv[1],"--benchmark-new")||!strcmp(argv[1],"--benchmark-speed")||!strcmp(argv[1],"--benchmark-ratecontrol")))parseArgs[1]="--synthetic";
  if(!ParseInvocation(argc,parseArgs,&parsed,&parsedOrigin)){fprintf(stderr,"Invalid helper arguments or video format\n");return 2;}
  const VideoFormat sessionFormat=parsed;
  const OwnedOrigin savedOrigin=parsedOrigin;
  negotiatedFormat=&sessionFormat; // Single assignment before any concurrency/API use.
  if(!strcmp(argv[1],"--selftest")){synthetic=YES;return SelfTest();}
  if(!strcmp(argv[1],"--event-pump-selftest")){synthetic=YES;return EventPumpSelfTest();}
  // Read-only diagnostic: no AppKit launch, display/capture APIs or lock file.
  if(!strcmp(argv[1],"--identity-probe")){
    unsigned serial=StableDisplaySerial(getuid());if(!serial)return 2;
    printf("identity-v1 vendor=%u product=%u serial=%u\n",OwnedDisplayVendor,OwnedDisplayProduct,serial);return 0;
  }
  if(!strcmp(argv[1],"--probe")){
    BOOL api=API();fprintf(stderr,"Virtual display API %s; capture permission %s\n",api?"available":"unavailable",CGPreflightScreenCaptureAccess()?"granted":"not granted");
    CGDirectDisplayID online[32],active[32];uint32_t onlineCount=0,activeCount=0;
    CGError onlineStatus=CGGetOnlineDisplayList(32,online,&onlineCount),activeStatus=CGGetActiveDisplayList(32,active,&activeCount);
    fprintf(stderr,"Topology probe: onlineStatus=%d onlineCount=%u activeStatus=%d activeCount=%u\n",onlineStatus,onlineCount,activeStatus,activeCount);
    if(onlineStatus==kCGErrorSuccess && onlineCount<=32)for(uint32_t i=0;i<onlineCount;i++){
      CGDirectDisplayID id=online[i];BOOL listedActive=NO;if(activeStatus==kCGErrorSuccess && activeCount<=32)for(uint32_t j=0;j<activeCount;j++)listedActive|=active[j]==id;
      fprintf(stderr,"Online display index=%u main=%s active=%s listedActive=%s mirrorSet=%s mirrorsOther=%s builtin=%s vendor=%u model=%u\n",i,CGMainDisplayID()==id?"yes":"no",CGDisplayIsActive(id)?"yes":"no",listedActive?"yes":"no",CGDisplayIsInMirrorSet(id)?"yes":"no",CGDisplayMirrorsDisplay(id)!=kCGNullDirectDisplay?"yes":"no",CGDisplayIsBuiltin(id)?"yes":"no",CGDisplayVendorNumber(id),CGDisplayModelNumber(id));
    }
    fprintf(stderr,"Supported physical baseline=%s\n",BaselineSupported()?"yes":"no");
    return api && onlineStatus==kCGErrorSuccess && activeStatus==kCGErrorSuccess?0:3;
  }
  nativeYUV=!strcmp(argv[1],"--benchmark-nv12");
  encodingSlots=negotiatedFormat->pixelScale==2?2:1;
  if(!strcmp(argv[1],"--benchmark-capture-old")||!strcmp(argv[1],"--benchmark-capture-latest"))encodingSlots=1;
  captureBenchmark=nativeYUV||!strcmp(argv[1],"--benchmark-pipeline")||!strcmp(argv[1],"--benchmark-capture-old")||!strcmp(argv[1],"--benchmark-capture-latest");captureLegacy=!strcmp(argv[1],"--benchmark-capture-old");
  benchmarkSpeed=!strcmp(argv[1],"--benchmark-speed");experimentalRateControl=!strcmp(argv[1],"--benchmark-ratecontrol");benchmark=captureBenchmark||benchmarkSpeed||experimentalRateControl||!strcmp(argv[1],"--benchmark-old")||!strcmp(argv[1],"--benchmark-new");legacyEncoder=!strcmp(argv[1],"--benchmark-old");targetFPS=legacyEncoder?30:60;// 60Hz virtual display (same as 70.4): the 72Hz trial is removed.
  tuning=!strcmp(argv[1],"--benchmark-tune")||!strcmp(argv[1],"--synthetic-tune");
  if(tuning){
    const char *profile=getenv("TC_TUNE_PROFILE");if(!profile)profile="baseline";
    if(!strcmp(profile,"baseline")){tuneLabel="baseline";encodingSlots=2;}
    else if(!strcmp(profile,"single")){tuneLabel="single";encodingSlots=1;}
    else if(!strcmp(profile,"single-speed")){tuneLabel="single-speed";encodingSlots=1;benchmarkSpeed=YES;}
    else if(!strcmp(profile,"single-rate")){tuneLabel="single-rate";encodingSlots=1;experimentalRateControl=YES;}
    else if(!strcmp(profile,"single-speed-rate")){tuneLabel="single-speed-rate";encodingSlots=1;benchmarkSpeed=YES;experimentalRateControl=YES;}
    else if(!strcmp(profile,"single-baseline")){tuneLabel="single-baseline";encodingSlots=1;tuneBaselineProfile=YES;}
    else if(!strcmp(profile,"two-rate-hq")){tuneLabel="two-rate-hq";encodingSlots=2;experimentalRateControl=YES;tuneHighBitrate=YES;}
    else if(!strcmp(profile,"two-rate")){tuneLabel="two-rate";encodingSlots=2;experimentalRateControl=YES;}
    else if(!strcmp(profile,"two-speed")){tuneLabel="two-speed";encodingSlots=2;benchmarkSpeed=YES;}
    else {fprintf(stderr,"Unknown tuning profile\n");return 2;}
    if(!strcmp(argv[1],"--benchmark-tune")){captureBenchmark=YES;benchmark=YES;}
  }
  if(LiveVideoMode(argv[1])){LiveEncoderPolicy policy=ResponseFirstPolicy(*negotiatedFormat);encodingSlots=policy.slots;experimentalRateControl=policy.lowLatency;benchmarkSpeed=policy.speedPriority;tuneHighBitrate=policy.bitrateFactor==9;}
  synthetic=benchmark||!strcmp(argv[1],"--synthetic")||!strcmp(argv[1],"--synthetic-tune");if(!synthetic&&strcmp(argv[1],"--stream"))return 2;
  signal(SIGPIPE,SIG_IGN);signal(SIGTERM,SignalStop);signal(SIGINT,SignalStop);signal(SIGALRM,SignalStop);
  int flags=fcntl(STDOUT_FILENO,F_GETFL);if(flags<0||fcntl(STDOUT_FILENO,F_SETFL,flags|O_NONBLOCK)<0)Fail("output flags");
  if(synthetic){alarm(20);return benchmark?Benchmark():Synthetic();}
  struct stat input,output;if(fstat(STDIN_FILENO,&input)||fstat(STDOUT_FILENO,&output)||!S_ISFIFO(input.st_mode)||!S_ISFIFO(output.st_mode))Fail("parent pipes required");
  if(!API()||!CGPreflightScreenCaptureAccess()||!SessionSafe())Fail("capture prerequisites unavailable");
  const unsigned displaySerial=StableDisplaySerial(getuid());if(!displaySerial)Fail("invalid display identity user");
  identityLockFD=AcquireUserDisplayIdentityLock();if(identityLockFD<0)Fail("display identity in use or lock unavailable");
  if(!DisplayIdentityAvailable(displaySerial))Fail("display identity already online or unavailable");
  // Early lifecycle contract line: parent reads stderr via launchHelper and
  // logs each line. State the bounded contract as counts/booleans only; no
  // display IDs, origins, counts of specific displays or geometry are logged.
  fprintf(stderr,"Bounded display helper 0.8.30.7: appKitEventsDrained=yes stableDisplayIdentity=perUserV1 singleOwnerLock=processLifetime startupHiDPIModePhase=postDetach ownedModeTxn=ownedOnly physicalBaselineBounded=yes preservesPhysicalSettings=yes reassertPrecreateOnlyInOwnStartupTxn=yes postStartPhysicalReplay=no setupScope=session ownedResolutionSessionFixed=yes ownedNonMirroredRequired=yes reconfigFatal=no newFrameSubmissionSuspendedDuringInvalid=yes encodedOwnedFramesInFlightEmitted=yes capturesPhysicalOtherDisplay=no rollsBackUserGeometryOnExit=no\n");
  StartWatchdog();
  if(!BaselineSupported())Fail("unsupported physical display baseline");
  PlacementPhysical placementPhysical[8];
  for(uint32_t i=0;i<baselineCount;i++)placementPhysical[i]=(PlacementPhysical){baseline[i].bounds,baseline[i].active,baseline[i].mirror==kCGNullDirectDisplay};
  const BOOL savedOriginApplied=SavedOriginValid(savedOrigin,sessionFormat,placementPhysical,baselineCount);
  const OwnedOrigin ownedOrigin=savedOriginApplied?savedOrigin:DefaultOwnedOrigin(sessionFormat,placementPhysical,baselineCount,originalBounds);
  if(!ownedOrigin.requested)Fail("no safe default owned display placement");
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
  InstallHelperQuitSink(); // after finishLaunching, which installs AppKit's default quit handler
  void (^stop)(NSNotification*)=^(NSNotification *note){(void)note;Fail("session notification");};
  [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil usingBlock:stop];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:nil usingBlock:stop];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceSessionDidResignActiveNotification object:nil queue:nil usingBlock:stop];
  [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsLocked" object:nil queue:nil usingBlock:stop];
  InitEncoder();
  CGVirtualDisplayDescriptor *d=[[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc]init];d.vendorID=OwnedDisplayVendor;d.productID=OwnedDisplayProduct;
  d.serialNum=displaySerial;d.serialNumber=displaySerial;d.name=@"ThunderControl MacBook Extension";
  d.queue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);d.maxPixelsWide=PixelWidth;d.maxPixelsHigh=PixelHeight;double ppi=negotiatedFormat->pixelScale==2?220.0:96.0;d.sizeInMillimeters=CGSizeMake(PixelWidth*25.4/ppi,PixelHeight*25.4/ppi);
  d.redPrimary=CGPointMake(.64,.33);d.greenPrimary=CGPointMake(.30,.60);d.bluePrimary=CGPointMake(.15,.06);d.whitePoint=CGPointMake(.3127,.3290);
  CGVirtualDisplay * __attribute__((objc_precise_lifetime)) display=[[NSClassFromString(@"CGVirtualDisplay") alloc]initWithDescriptor:d];if(!display)Fail("virtual display unavailable");
  CGVirtualDisplaySettings *settings=[[NSClassFromString(@"CGVirtualDisplaySettings") alloc]init];settings.hiDPI=negotiatedFormat->pixelScale==2?1:0;settings.rotation=0;
  VirtualModeSize plannedModes[2];unsigned modeCount=VirtualModePlan(sessionFormat,plannedModes);
  if(!modeCount)Fail("virtual mode plan unavailable");
  NSMutableArray *virtualModes=[NSMutableArray arrayWithCapacity:modeCount];
  for(unsigned i=0;i<modeCount;i++){
    CGVirtualDisplayMode *mode=[[NSClassFromString(@"CGVirtualDisplayMode") alloc]initWithWidth:plannedModes[i].width height:plannedModes[i].height refreshRate:targetFPS];
    if(!mode)Fail("virtual mode unavailable");[virtualModes addObject:mode];
  }
  settings.modes=virtualModes;
  if(![display applySettings:settings])Fail("virtual mode rejected");ownedID=display.displayID;if(!ownedID||ownedID==originalID)Fail("display identity");
  for(uint32_t i=0;i<baselineCount;i++)if(ownedID==baseline[i].id)Fail("display identity collision");
  Pump(.5);
  // Exact-set ID guard: online MUST equal baselineIDs union {ownedID}. Any
  // external hotplug ADDITION or baseline REMOVAL aborts (we don't clobber
  // an unknown display, and we can't preserve a vanished one).
  {
    CGDirectDisplayID ids[32];uint32_t n=0;
    if(CGGetOnlineDisplayList(32,ids,&n)!=kCGErrorSuccess)Fail("online enumerate");
    if(n!=baselineCount+1)Fail("online count mismatch");
    BOOL ownedPresent=NO;
    for(uint32_t j=0;j<n;j++)if(ids[j]==ownedID){ownedPresent=YES;break;}
    if(!ownedPresent)Fail("owned display missing after creation");
    for(uint32_t i=0;i<baselineCount;i++){
      BOOL present=NO;for(uint32_t j=0;j<n;j++)if(ids[j]==baseline[i].id){present=YES;break;}
      if(!present)Fail("baseline display missing after owned creation");
    }
    for(uint32_t j=0;j<n;j++){
      BOOL known=ids[j]==ownedID;
      for(uint32_t i=0;!known && i<baselineCount;i++)if(ids[j]==baseline[i].id)known=YES;
      if(!known)Fail("unexpected external display during owned creation");
    }
  }
  if(negotiatedFormat->pixelScale==2)OwnedHiDPIDiagnostic("before_detach",NO);
  // Validate only against authoritative PRE-CREATE baseline geometry. The
  // exact-set creation gate above remains mandatory; stale saved placement
  // falls back to the safe centered-left default and never writes physical modes.
  // Placement was validated against the pre-create snapshot before creation.
  // First startup transaction. 0.8.19 proven path, generalized to multiple
  // pre-create roots. No physical mode writes (OS restores modes once mirror group
  // roots are restored; mode writes on inactive aliases are rejected).
  //   S1. mirrorOf(NULL) for every pre-create ROOT (undo OS perturbation)
  //   S2. origin for every pre-create ROOT at its pre-create bounds.origin
  //   S3. mirrorOf(baseline[i].mirror) for every pre-create ALIAS
  //   S4. owned mirrorOf(NULL)
  //   S5. owned validated saved origin, otherwise centered left default
  //   S6. CGComplete
  // No hardcoded mirror-to-main policy; alias root targets come from the
  // captured baseline[i].mirror as-is. Stage + CGError are logged on
  // failure without any display IDs or coordinates.
  const char *stage="S0:begin";CGError ce=kCGErrorSuccess;
  CGDisplayConfigRef config=NULL;if(CGBeginDisplayConfiguration(&config)!=kCGErrorSuccess){fprintf(stderr,"Display sender configure failure stage=%s cgErrorCode=%d\n",stage,ce);Fail("display configuration");}
  stage="S1:rootDetach";
  for(uint32_t i=0;i<baselineCount && ce==kCGErrorSuccess;i++)
    if(baseline[i].mirror==kCGNullDirectDisplay)
      ce=CGConfigureDisplayMirrorOfDisplay(config,baseline[i].id,kCGNullDirectDisplay);
  if(ce==kCGErrorSuccess){stage="S2:rootOrigin";
    for(uint32_t i=0;i<baselineCount && ce==kCGErrorSuccess;i++)
      if(baseline[i].mirror==kCGNullDirectDisplay)
        ce=CGConfigureDisplayOrigin(config,baseline[i].id,(int32_t)baseline[i].bounds.origin.x,(int32_t)baseline[i].bounds.origin.y);
  }
  if(ce==kCGErrorSuccess){stage="S3:aliasMirror";
    for(uint32_t i=0;i<baselineCount && ce==kCGErrorSuccess;i++)
      if(baseline[i].mirror!=kCGNullDirectDisplay)
        ce=CGConfigureDisplayMirrorOfDisplay(config,baseline[i].id,baseline[i].mirror);
  }
  if(ce==kCGErrorSuccess){stage="S4:ownedMirrorNull";
    ce=CGConfigureDisplayMirrorOfDisplay(config,ownedID,kCGNullDirectDisplay);
  }
  if(ce==kCGErrorSuccess){stage="S5:ownedOrigin";
    int32_t ox=ownedOrigin.x,oy=ownedOrigin.y;
    ce=CGConfigureDisplayOrigin(config,ownedID,ox,oy);
  }
  if(ce!=kCGErrorSuccess){fprintf(stderr,"Display sender configure failure stage=%s cgErrorCode=%d\n",stage,ce);CGCancelDisplayConfiguration(config);Fail("owned+baseline configuration");}
  stage="S6:complete";CGError ccErr=CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
  if(ccErr!=kCGErrorSuccess){fprintf(stderr,"Display sender configure failure stage=%s cgErrorCode=%d\n",stage,ccErr);Fail("owned+baseline commit");}
  fprintf(stderr,"Owned initial placement: restoredRequested=%s restoredApplied=%s\n",savedOrigin.requested?"yes":"no",savedOriginApplied?"yes":"no");
  // Session scope: preserved physical state must NOT revert at process exit
  // (it is already the user's state). Owned virtual is still destroyed by
  // CGVirtualDisplay dealloc regardless of config scope.
  // Bounded settle AFTER the transaction so CoreGraphics finishes propagating
  // the owned display's mode table and physical reasserts; retrieving
  // ownedInitialMode before this settle intermittently returned NULL on real
  // hardware.
  Pump(1);ownedInitialBounds=CGDisplayBounds(ownedID);
  // Retain the owned mode as the authoritative read-only reference. OwnedSafe
  // compares live modes against this reference; drift fails validation. On
  // any post-commit failure below, we drop the owned virtual and attempt a
  // best-effort restore of the baseline before Fail(); baseline mode CFRefs
  // are retained through this failure cleanup.
  const char *postFail=NULL;
  // Detach/preserve FIRST. While creation is mirrored, CoreGraphics can expose
  // the mirror group's effective modes rather than the owned Retina modes.
  BOOL detachedCommit=YES;
  if(negotiatedFormat->pixelScale==2)OwnedHiDPIDiagnostic("after_detach",YES);
  if(!BaselinePreserved())postFail="physical baseline preservation";
  else if(!StartupOnlineExact())postFail="startup online set mismatch";
  if(!postFail && negotiatedFormat->pixelScale==2){
    BOOL unmirrored=!CGDisplayIsInMirrorSet(ownedID) && CGDisplayMirrorsDisplay(ownedID)==kCGNullDirectDisplay;
    if(!StartupModeChooseAllowed(detachedCommit,YES,YES,unmirrored,atomic_load(&topologyArmed)))postFail="owned startup mode phase";
    else {
      CGDisplayModeRef current=CGDisplayCopyDisplayMode(ownedID);
      BOOL logical=current && CGDisplayModeGetWidth(current)==StreamWidth && CGDisplayModeGetHeight(current)==StreamHeight;
      BOOL pixels=current && CGDisplayModeGetPixelWidth(current)==PixelWidth && CGDisplayModeGetPixelHeight(current)==PixelHeight;
      if(current)CGDisplayModeRelease(current);
      CGDisplayModeRef requested=NULL;
      NSDictionary *options=@{(__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes:@YES};
      CFArrayRef modes=CGDisplayCopyAllDisplayModes(ownedID,(__bridge CFDictionaryRef)options);
      CFIndex count=modes?CFArrayGetCount(modes):0;
      if(modes){for(CFIndex i=0;i<count;i++){
        CGDisplayModeRef candidate=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
        if(CGDisplayModeGetWidth(candidate)==StreamWidth && CGDisplayModeGetHeight(candidate)==StreamHeight &&
           CGDisplayModeGetPixelWidth(candidate)==PixelWidth && CGDisplayModeGetPixelHeight(candidate)==PixelHeight){requested=CGDisplayModeRetain(candidate);break;}
      }CFRelease(modes);}
      if(!(logical&&pixels) && !requested)postFail="exact owned HiDPI mode unavailable";
      else if(!(logical&&pixels)){
        BOOL physicalTarget=NO;for(uint32_t i=0;i<baselineCount;i++)if(baseline[i].id==ownedID)physicalTarget=YES;
        if(!StartupModeTargetAllowed(ownedID,ownedID,physicalTarget))postFail="owned startup mode target";
        else {
          // SECOND STARTUP transaction: owned mode + validated owned origin ONLY.
          // No physical replay here, nor any transaction after topologyArmed.
          CGDisplayConfigRef modeConfig=NULL;
          if(CGBeginDisplayConfiguration(&modeConfig)!=kCGErrorSuccess)postFail="owned HiDPI configuration";
          else {
            CGError modeError=CGConfigureDisplayWithDisplayMode(modeConfig,ownedID,requested,NULL);
            if(modeError==kCGErrorSuccess){
              int32_t ox=ownedOrigin.x,oy=ownedOrigin.y;
              modeError=CGConfigureDisplayOrigin(modeConfig,ownedID,ox,oy);
            }
            if(modeError!=kCGErrorSuccess){CGCancelDisplayConfiguration(modeConfig);postFail="owned HiDPI configuration";}
            else if(CGCompleteDisplayConfiguration(modeConfig,kCGConfigureForSession)!=kCGErrorSuccess)postFail="owned HiDPI commit";
          }
        }
      }
      // Keep the exact owned mode retained THROUGH commit/cancel.
      if(requested)CGDisplayModeRelease(requested);
      if(!postFail){Pump(1);ownedInitialBounds=CGDisplayBounds(ownedID);OwnedHiDPIDiagnostic("after_selection",YES);}
    }
  }
  if(!postFail && !StartupOnlineExact())postFail="startup online set mismatch";
  if(!postFail && !BaselinePreserved())postFail="physical baseline preservation";
  ownedInitialMode=CGDisplayCopyDisplayMode(ownedID);
  if(!postFail && !ownedInitialMode)postFail="owned mode unavailable";
  if(!postFail && fabs(CGDisplayModeGetRefreshRate(ownedInitialMode)-targetFPS)>0.01)postFail="owned refresh rate not accepted";
  if(!postFail)fprintf(stderr,"Source supply trial: ownedRefreshHz=%.3f encoderExpectedFPS=%d captureRequestedFPS=%d receiverTargetUnchanged=60 repeatInsertion=no\n",CGDisplayModeGetRefreshRate(ownedInitialMode),targetFPS,targetFPS*2);
  if(!postFail && !OwnedSafe())postFail="owned display verification";
  if(postFail){
    if(ownedInitialMode){CGDisplayModeRelease(ownedInitialMode);ownedInitialMode=NULL;}
    display=nil; // release retained CGVirtualDisplay so the OS removes it
    for(int s=0;s<20;s++)usleep(50000); // ~1s settle without Guard() reentry
    // Best-effort baseline-only reassertion (no owned writes, no mode
    // writes). Same ordering as the setup transaction. Baseline mode CFRefs
    // remain retained in case diagnostics or a later path needs them.
    const char *rstage="rS0:begin";CGError rce=kCGErrorSuccess;
    CGDisplayConfigRef rconfig=NULL;
    if(CGBeginDisplayConfiguration(&rconfig)!=kCGErrorSuccess){fprintf(stderr,"Display sender rollback failure stage=%s cgErrorCode=%d\n",rstage,rce);Fail(postFail);}
    rstage="rS1:rootDetach";
    for(uint32_t i=0;i<baselineCount && rce==kCGErrorSuccess;i++)
      if(baseline[i].mirror==kCGNullDirectDisplay)
        rce=CGConfigureDisplayMirrorOfDisplay(rconfig,baseline[i].id,kCGNullDirectDisplay);
    if(rce==kCGErrorSuccess){rstage="rS2:rootOrigin";
      for(uint32_t i=0;i<baselineCount && rce==kCGErrorSuccess;i++)
        if(baseline[i].mirror==kCGNullDirectDisplay)
          rce=CGConfigureDisplayOrigin(rconfig,baseline[i].id,(int32_t)baseline[i].bounds.origin.x,(int32_t)baseline[i].bounds.origin.y);
    }
    if(rce==kCGErrorSuccess){rstage="rS3:aliasMirror";
      for(uint32_t i=0;i<baselineCount && rce==kCGErrorSuccess;i++)
        if(baseline[i].mirror!=kCGNullDirectDisplay)
          rce=CGConfigureDisplayMirrorOfDisplay(rconfig,baseline[i].id,baseline[i].mirror);
    }
    if(rce!=kCGErrorSuccess){fprintf(stderr,"Display sender rollback failure stage=%s cgErrorCode=%d\n",rstage,rce);CGCancelDisplayConfiguration(rconfig);Fail(postFail);}
    rstage="rS6:complete";CGError rccErr=CGCompleteDisplayConfiguration(rconfig,kCGConfigureForSession);
    if(rccErr!=kCGErrorSuccess)fprintf(stderr,"Display sender rollback failure stage=%s cgErrorCode=%d\n",rstage,rccErr);
    Fail(postFail);
  }
  // Baseline modes have served their purpose; policy prohibits any post-start
  // physical replay, so release the retained CFRefs now (success path only).
  ReleaseBaselineModes();
  if(CGDisplayRegisterReconfigurationCallback(Reconfigured,NULL)!=kCGErrorSuccess)Fail("display observer");
  // Publish initial proof BEFORE arming so no window exists where
  // topologyArmed is true but proofEpoch doesn't match reconfigEpoch.
  atomic_store(&ownedValidatedNS,(uint64_t)(Now()*1e9));
  atomic_store(&proofEpoch,atomic_load(&reconfigEpoch));
  atomic_store(&ownedValid,true);
  atomic_store(&ownedInvalidSinceNS,0);
  atomic_store(&topologyArmed,true);
  fprintf(stderr,"Owned virtual display armed: ownedResolutionVerified=yes ownedNonMirroredVerified=yes ownedPlacementInitialVerified=yes baselineBoundedVerified=yes physicalBaselinePreservedVerified=yes\n");
  uint8_t kind=1;uint32_t idBE=CFSwapInt32HostToBig(ownedID);NSMutableData *identity=[NSMutableData dataWithBytes:&kind length:1];[identity appendBytes:&idBE length:4];Output(identity);
  __block BOOL ready=NO;__block SCShareableContent *content=nil;
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *value,NSError *error){dispatch_async(dispatch_get_main_queue(),^{if(error)Fail("capture enumeration");content=value;ready=YES;});}];
  double deadline=Now()+4;while(!ready){if(Now()>deadline)Fail("capture enumeration timeout");Pump(.025);}
  SCDisplay *target=nil;for(SCDisplay *item in content.displays)if(item.displayID==ownedID)target=item;
  // SCShareableContent.h documents SCDisplay width/height in POINTS, not pixels.
  // CG proves the native backing scale; Submit independently checks every actual
  // captured pixel buffer. A requested output size alone is never HiDPI proof.
  if(!target||target.width!=StreamWidth||target.height!=StreamHeight || !OwnedSafe())Fail("owned capture display missing");
  fprintf(stderr,"Capture contract: logical=%ux%u physical=%ux%u scale=%u nativeCGVerified=yes SCDisplayPointsVerified=yes\n",StreamWidth,StreamHeight,PixelWidth,PixelHeight,negotiatedFormat->pixelScale);
  SCContentFilter *filter=[[SCContentFilter alloc]initWithDisplay:target excludingWindows:@[]];
  SCStreamConfiguration *cfg=[SCStreamConfiguration new];cfg.width=PixelWidth;cfg.height=PixelHeight;cfg.pixelFormat=kCVPixelFormatType_32BGRA;cfg.minimumFrameInterval=CMTimeMake(1,targetFPS*2);cfg.queueDepth=3;cfg.showsCursor=NO;cfg.capturesAudio=NO;
  FrameSink * __attribute__((objc_precise_lifetime)) sink=[FrameSink new];SCStream * __attribute__((objc_precise_lifetime)) stream=[[SCStream alloc]initWithFilter:filter configuration:cfg delegate:sink];
  frameQueue=dispatch_queue_create("local.ThunderControl.display.capture",DISPATCH_QUEUE_SERIAL);NSError *error=nil;
  if(![stream addStreamOutput:sink type:SCStreamOutputTypeScreen sampleHandlerQueue:frameQueue error:&error])Fail("capture output setup");
  [stream startCaptureWithCompletionHandler:^(NSError *err){if(err)Fail("capture start");}];
  // Strong references remain alive for whole process; exit is the cleanup boundary.
  // Capture filter identity is locked to ownedID: non-owned displays are never
  // reachable through this stream, regardless of OS topology transients.
  double firstFrameDeadline=Now()+8;__block double encodeDeadline=0;__block unsigned lastProgress=0;
  for(;;){RunPooledIteration(^{Pump(1.0/60.0);DiagPeriodic();PublishCursor();if(!atomic_load(&emitted)&&Now()>firstFrameDeadline)Fail("first frame timeout");if(atomic_load(&inFlight)){unsigned progress=atomic_load(&emitted)+atomic_load(&encoderDropped);if(!encodeDeadline||progress!=lastProgress){encodeDeadline=Now()+5;lastProgress=progress;}if(Now()>encodeDeadline)Fail("encode timeout");}else encodeDeadline=0;});}
  (void)display;(void)stream;(void)sink;
}}
