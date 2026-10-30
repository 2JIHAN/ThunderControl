#import <VideoToolbox/VideoToolbox.h>
#import <AppKit/AppKit.h>
static void F15Encoded(void *,void *,OSStatus,VTEncodeInfoFlags,CMSampleBufferRef);
static OSStatus F15Create(CFAllocatorRef a,int32_t w,int32_t h,CMVideoCodecType c,CFDictionaryRef s,CFDictionaryRef p,CFAllocatorRef b,VTCompressionOutputCallback cb,void *ctx,VTCompressionSessionRef *out){
  (void)cb;return VTCompressionSessionCreate(a,w,h,c,s,p,b,F15Encoded,ctx,out);
}
#define VTCompressionSessionCreate F15Create
#define main F15ProductionMain
#include "../DisplaySenderHelper/DisplaySenderHelper.m"
#undef main
#undef VTCompressionSessionCreate
static CMSampleBufferRef F15Sample;
static CMTime F15Expected;
static uint64_t F15Ordinal,F15Sequence;
static unsigned F15Errors,F15EncodedCount,F15DecodedCount;
static void F15Check(BOOL ok,const char *label){if(!ok){fprintf(stderr,"F15 FAIL %s\n",label);F15Errors++;}}
static void F15Encoded(void *ctx,void *source,OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample){
  (void)ctx;EncodeTicket ticket=*(EncodeTicket*)source;free(source);
  F15Check(status==noErr&&!(flags&kVTEncodeInfo_FrameDropped)&&sample&&CMSampleBufferDataIsReady(sample),"encode callback status/drop/sample");
  F15Check(ticket.sequence==F15Sequence,"submission cookie order");
  F15Check(ticket.captureSequence==F15Ordinal,"capture ordinal remains PTS numerator");
  if(sample){F15Check(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),F15Expected)==0,"numeric PTS preserved across native timescale normalization");F15Check(CMTimeCompare(CMSampleBufferGetDuration(sample),CMTimeMake(1,targetFPS))==0,"nominal duration preserved");F15Sample=(CMSampleBufferRef)CFRetain(sample);F15EncodedCount++;}
  atomic_fetch_sub(&inFlight,1);
}
static void F15Decoded(void *ctx,void *source,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration){
  (void)ctx;(void)source;(void)duration;
  F15Check(status==noErr&&!(flags&kVTDecodeInfo_FrameDropped)&&image,"decode callback status/drop/image");
  F15Check(CMTimeCompare(pts,F15Expected)==0,"decoded PTS preserved");
  if(image){CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);uint8_t *p=CVPixelBufferGetBaseAddress(image);size_t row=CVPixelBufferGetBytesPerRow(image);F15Check(CVPixelBufferGetWidth(image)==PixelWidth&&CVPixelBufferGetHeight(image)==PixelHeight,"decoded dimensions");
    for(unsigned y=32;y<PixelHeight;y+=97)for(unsigned x=32;x<PixelWidth;x+=101){uint8_t *v=p+y*row+4*x;F15Check(abs(v[0]-40)<22&&abs(v[1]-100)<22&&abs(v[2]-180)<22,"decoded color content");}
    CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);F15DecodedCount++;}
}
int main(void){@autoreleasepool{
  synthetic=YES;static const VideoFormat format={640,480,1};negotiatedFormat=&format;
  CVPixelBufferRef pixel=NULL;F15Check(CVPixelBufferCreate(NULL,PixelWidth,PixelHeight,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pixel)==noErr,"pixel allocation");if(!pixel)return 2;
  CVPixelBufferLockBaseAddress(pixel,0);for(unsigned y=0;y<PixelHeight;y++){uint8_t *p=(uint8_t*)CVPixelBufferGetBaseAddress(pixel)+y*CVPixelBufferGetBytesPerRow(pixel);for(unsigned x=0;x<PixelWidth;x++){p[4*x]=40;p[4*x+1]=100;p[4*x+2]=180;p[4*x+3]=255;}}CVPixelBufferUnlockBaseAddress(pixel,0);
  CMVideoCodecType codecs[]={kCMVideoCodecType_H264,kCMVideoCodecType_HEVC,kCMVideoCodecType_AppleProRes422Proxy,kCMVideoCodecType_AppleProRes422LT};unsigned available=0;
  for(unsigned c=0;c<4;c++)for(unsigned reset=0;reset<2;reset++){
    codecCount=1;codecIndex=0;CodecPreference[0]=codecs[c];experimentalRateControl=NO;
    if(!InitEncoder()){fprintf(stderr,"F15 UNAVAILABLE codec=%s reset=%u\n",CodecName(codecs[c]),reset);break;}available++;
    VTDecompressionSessionRef decoder=NULL;uint64_t ordinals[]={reset?120:0,reset?121:1,reset?132:12,reset?133:13};
    for(unsigned i=0;i<4;i++){
      double idleStart=Now();if(i==3)usleep(100000);
      if(i==3)F15Check(Now()-idleStart>=0.09,"real idle gap exceeds nominal PTS spacing");
      F15Sequence=submittedSequence;F15Ordinal=ordinals[i];F15Expected=CMTimeMake(F15Ordinal,targetFPS);F15Sample=NULL;unsigned before=F15EncodedCount;
      SubmitAt(pixel,F15Expected,Now());F15Check(VTCompressionSessionCompleteFrames(encoder,kCMTimeInvalid)==noErr,"complete frames");F15Check(F15EncodedCount==before+1&&atomic_load(&inFlight)==0,"one output per submission");if(!F15Sample)continue;
      CMTime out=CMSampleBufferGetPresentationTimeStamp(F15Sample);fprintf(stderr,"F15 metadata codec=%s reset=%u ordinal=%llu pts=%lld/%d duration=%lld/%d bytes=%zu\n",CodecName(codecs[c]),reset,(unsigned long long)F15Ordinal,(long long)out.value,out.timescale,(long long)CMSampleBufferGetDuration(F15Sample).value,CMSampleBufferGetDuration(F15Sample).timescale,CMSampleBufferGetTotalSampleSize(F15Sample));
      if(!decoder){VTDecompressionOutputCallbackRecord callback={F15Decoded,NULL};OSStatus s=VTDecompressionSessionCreate(NULL,CMSampleBufferGetFormatDescription(F15Sample),NULL,(__bridge CFDictionaryRef)@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)},&callback,&decoder);F15Check(s==noErr&&decoder,"decoder create");}
      if(decoder){unsigned decoded=F15DecodedCount;VTDecodeInfoFlags flags=0;F15Check(VTDecompressionSessionDecodeFrame(decoder,F15Sample,0,NULL,&flags)==noErr,"decode submit");F15Check(VTDecompressionSessionWaitForAsynchronousFrames(decoder)==noErr,"decode drain");F15Check(F15DecodedCount==decoded+1,"one decoded output per encoded frame");}
      CFRelease(F15Sample);F15Sample=NULL;
    }
    if(decoder){VTDecompressionSessionInvalidate(decoder);CFRelease(decoder);}VTCompressionSessionInvalidate(encoder);CFRelease(encoder);encoder=NULL;
  }
  F15Check(available>=2,"at least one codec and reset tested");
  F15Check(!CMTIME_IS_NUMERIC(kCMTimeInvalid)&&!CMTIME_IS_NUMERIC(kCMTimeIndefinite)&&!CMTIME_IS_NUMERIC(kCMTimePositiveInfinity),"bad source time is not a clock");
  F15Check(CMTimeCompare(CMTimeMake(1,60),CMTimeMake(1000,60000))==0,"timescale equivalence");
  CVPixelBufferRelease(pixel);fprintf(stderr,"F15 %s sessions=%u encoded=%u decoded=%u errors=%u unchangedOrdinalPTS=yes idleGapNotWallClock=yes\n",F15Errors?"FAIL":"PASS",available,F15EncodedCount,F15DecodedCount,F15Errors);return F15Errors?1:0;
}}
