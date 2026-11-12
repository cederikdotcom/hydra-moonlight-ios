//
//  HydraFrameCapture.m
//  Moonlight / hydra-moonlight-ios
//
//  See HydraFrameCapture.h for why this exists (issue 1162).
//
//  Thread ownership, which is the whole of the risk here:
//
//    requestFrameWithCompletion:   main thread. Arms the flag.
//    offerIDRSampleBuffer:         main thread, from submitDecodeBuffer:.
//                                  One atomic boolean read, then a retain and
//                                  a dispatch_async. Nothing else.
//    the decode and the conversion private serial queue.
//    finishGeneration:...          main thread, always, exactly once.
//
//  submitDecodeBuffer: runs on the main thread because Connection.m sets
//  CAPABILITY_PULL_RENDERER, so the renderer owns the frame loop through a
//  CADisplayLink on the main run loop. The hazard is therefore not a data race
//  but the display link budget, 16.6 ms at 60 frames per second with frame
//  pacing on. Slow work there drops frames in front of a visitor, so no work
//  beyond a retain happens on that thread.
//

#import "HydraFrameCapture.h"

#import "HydraLog.h"

#import <VideoToolbox/VideoToolbox.h>

NSString *const HydraFrameCaptureErrorDomain = @"HydraFrameCapture";

// A key frame arrives within a few frame intervals of the request. Two seconds
// is far longer than that, and still inside the window the cluster gives an
// admin screenshot before it answers 504.
static const NSTimeInterval HydraFrameCaptureDeadlineSeconds = 2.0;

// Carries one decode out of the VideoToolbox callback. Lives on the stack of
// the serial queue frame that owns the session, so it needs no lock.
typedef struct {
    CVImageBufferRef imageBuffer;
    OSStatus status;
} HydraFrameCaptureDecodeResult;

static void HydraFrameCaptureDecodeOutput(void *decompressionOutputRefCon,
                                          void *sourceFrameRefCon,
                                          OSStatus status,
                                          VTDecodeInfoFlags infoFlags,
                                          CVImageBufferRef imageBuffer,
                                          CMTime presentationTimeStamp,
                                          CMTime presentationDuration) {
    HydraFrameCaptureDecodeResult *result = (HydraFrameCaptureDecodeResult *)sourceFrameRefCon;
    if (result == NULL) {
        return;
    }

    result->status = status;
    if (status == noErr && imageBuffer != NULL) {
        result->imageBuffer = CVPixelBufferRetain(imageBuffer);
    }
}

@interface HydraFrameCapture ()

@property (nonatomic, strong) dispatch_queue_t decodeQueue;

// Written on the main thread, read on the main thread from inside
// submitDecodeBuffer:. Atomic so that read is a single instruction.
@property (atomic, assign) BOOL frameWanted;

// Main thread only. Non-nil exactly while a request is outstanding, which is
// also what makes a request refuse a second one.
@property (nonatomic, copy, nullable) HydraFrameCaptureCompletion pendingCompletion;

// Bumped by every request. The deadline block carries the generation it was
// armed for, so a deadline that fires after its frame arrived finds a
// mismatch and does nothing.
@property (nonatomic, assign) NSUInteger generation;

@end

@implementation HydraFrameCapture

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _decodeQueue = dispatch_queue_create("com.experiencenet.hydraheadipad.framecapture",
                                             DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)requestFrameWithCompletion:(HydraFrameCaptureCompletion)completion {
    NSAssert([NSThread isMainThread], @"HydraFrameCapture must be asked from the main thread");

    if (self.pendingCompletion != nil) {
        HydraLog(@"HydraFrameCapture: refusing a request, one is already waiting for a key frame");
        completion(nil, [self errorWithCode:HydraFrameCaptureErrorBusy
                                description:@"a frame capture is already waiting for a key frame"]);
        return NO;
    }

    self.generation += 1;
    self.pendingCompletion = completion;
    self.frameWanted = YES;

    NSUInteger generation = self.generation;
    __weak HydraFrameCapture *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(HydraFrameCaptureDeadlineSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HydraFrameCapture *capture = weakSelf;
        if (capture == nil) {
            return;
        }
        [capture finishGeneration:generation
                            image:nil
                            error:[capture errorWithCode:HydraFrameCaptureErrorTimedOut
                                             description:@"no key frame arrived within two seconds"]];
    });

    return YES;
}

- (void)offerIDRSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // The steady state cost of this whole feature, once per key frame.
    if (!self.frameWanted) {
        return;
    }
    if (sampleBuffer == NULL) {
        return;
    }

    // This frame is the one. Clear the flag before anything else, so a second
    // key frame arriving while this one decodes is left alone.
    self.frameWanted = NO;

    NSUInteger generation = self.generation;
    CFRetain(sampleBuffer);

    __weak HydraFrameCapture *weakSelf = self;
    dispatch_async(self.decodeQueue, ^{
        HydraFrameCapture *capture = weakSelf;
        if (capture != nil) {
            [capture decodeSampleBuffer:sampleBuffer generation:generation];
        }
        CFRelease(sampleBuffer);
    });
}

- (void)cancelPendingRequest {
    // Unlike the other two entry points this one is called from the connection
    // thread, through DrStop, so it hops before it reads pendingCompletion.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cancelPendingRequest];
        });
        return;
    }

    if (self.pendingCompletion == nil) {
        return;
    }

    HydraLog(@"HydraFrameCapture: abandoning a waiting request, the stream is going away");
    [self finishGeneration:self.generation
                     image:nil
                     error:[self errorWithCode:HydraFrameCaptureErrorTimedOut
                                   description:@"the stream ended before a key frame arrived"]];
}

#pragma mark - The decode, on the private serial queue

- (void)decodeSampleBuffer:(CMSampleBufferRef)originalSampleBuffer generation:(NSUInteger)generation {
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();

    // VideoToolbox reads the access units through one pointer.
    // submitDecodeBuffer: builds the frame buffer out of block buffer
    // REFERENCES, one per NALU, which AVSampleBufferDisplayLayer is happy to
    // take and which CMBlockBufferGetDataPointer cannot serve. Flatten it
    // here, on this queue, where copying a few hundred kilobytes costs
    // nothing and the main thread has already been let go.
    CMSampleBufferRef sampleBuffer = [self contiguousCopyOf:originalSampleBuffer];
    if (sampleBuffer == NULL) {
        [self failGeneration:generation
                        code:HydraFrameCaptureErrorDecodeFailed
                 description:@"the key frame could not be flattened for the decoder"];
        return;
    }

    UIImage *image = nil;
    HydraFrameCaptureErrorCode failureCode = HydraFrameCaptureErrorDecodeFailed;
    NSString *failure = nil;

    CMVideoFormatDescriptionRef formatDescription =
        (CMVideoFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);

    if (formatDescription == NULL) {
        failure = @"the key frame carried no format description";
    }
    else if (![self decodesCodec:CMFormatDescriptionGetMediaSubType(formatDescription)]) {
        // The format description carries the codec, so HEVC needs nothing
        // beyond this gate when HydraStreamSession widens
        // supportedVideoFormats. AV1 is refused rather than mis-decoded: its
        // format description is built by hand in this fork and has never been
        // through this path.
        failureCode = HydraFrameCaptureErrorUnsupportedCodec;
        failure = [NSString stringWithFormat:@"the stream codec %u is not one this capture decodes",
                                             (unsigned int)CMFormatDescriptionGetMediaSubType(formatDescription)];
    }
    else {
        NSDictionary *destinationAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };

        HydraFrameCaptureDecodeResult result = { NULL, noErr };
        VTDecompressionOutputCallbackRecord callbackRecord = { HydraFrameCaptureDecodeOutput, NULL };
        VTDecompressionSessionRef session = NULL;

        OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                       formatDescription,
                                                       NULL,
                                                       (__bridge CFDictionaryRef)destinationAttributes,
                                                       &callbackRecord,
                                                       &session);
        if (status != noErr || session == NULL) {
            failure = [NSString stringWithFormat:@"VTDecompressionSessionCreate failed: %d", (int)status];
        }
        else {
            // No decode flags, so the callback has run by the time this
            // returns. The wait is belt and braces for a decoder that
            // promotes it to asynchronous anyway.
            status = VTDecompressionSessionDecodeFrame(session, sampleBuffer, 0, &result, NULL);
            if (status == noErr) {
                status = VTDecompressionSessionWaitForAsynchronousFrames(session);
            }

            VTDecompressionSessionInvalidate(session);
            CFRelease(session);

            if (status == noErr) {
                status = result.status;
            }

            if (status != noErr || result.imageBuffer == NULL) {
                failure = [NSString stringWithFormat:@"decoding the key frame failed: %d", (int)status];
            }
            else {
                CGImageRef cgImage = NULL;
                status = VTCreateCGImageFromCVPixelBuffer(result.imageBuffer, NULL, &cgImage);
                if (status != noErr || cgImage == NULL) {
                    failure = [NSString stringWithFormat:@"converting the key frame failed: %d", (int)status];
                }
                else {
                    image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
                    CGImageRelease(cgImage);
                }
            }

            if (result.imageBuffer != NULL) {
                CVPixelBufferRelease(result.imageBuffer);
            }
        }
    }

    CFRelease(sampleBuffer);

    if (image == nil) {
        [self failGeneration:generation code:failureCode description:failure];
        return;
    }

    HydraLog(@"HydraFrameCapture: decoded a %.0f by %.0f key frame in %.0f ms",
             image.size.width, image.size.height,
             (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0);

    [self finishGeneration:generation image:image error:nil];
}

- (BOOL)decodesCodec:(FourCharCode)codec {
    return codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC;
}

// Returns a retained sample buffer whose data is readable through one pointer,
// or NULL. The caller releases it.
- (CMSampleBufferRef)contiguousCopyOf:(CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED {
    CMBlockBufferRef source = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (source == NULL) {
        return NULL;
    }

    if (CMBlockBufferIsRangeContiguous(source, 0, 0)) {
        CFRetain(sampleBuffer);
        return sampleBuffer;
    }

    CMBlockBufferRef contiguous = NULL;
    OSStatus status = CMBlockBufferCreateContiguous(kCFAllocatorDefault, source, kCFAllocatorDefault,
                                                    NULL, 0, 0, 0, &contiguous);
    if (status != noErr || contiguous == NULL) {
        HydraLog(@"HydraFrameCapture: CMBlockBufferCreateContiguous failed: %d", (int)status);
        return NULL;
    }

    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);

    CMSampleBufferRef copy = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       contiguous,
                                       CMSampleBufferGetFormatDescription(sampleBuffer),
                                       1, 1, &timing, 0, NULL,
                                       &copy);
    CFRelease(contiguous);

    if (status != noErr || copy == NULL) {
        HydraLog(@"HydraFrameCapture: CMSampleBufferCreateReady failed: %d", (int)status);
        return NULL;
    }

    return copy;
}

#pragma mark - Finishing, always on the main thread and always once

- (void)failGeneration:(NSUInteger)generation
                  code:(HydraFrameCaptureErrorCode)code
           description:(NSString *)description {
    HydraLog(@"HydraFrameCapture: %@", description);
    [self finishGeneration:generation
                     image:nil
                     error:[self errorWithCode:code description:description]];
}

- (void)finishGeneration:(NSUInteger)generation
                   image:(nullable UIImage *)image
                   error:(nullable NSError *)error {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishGeneration:generation image:image error:error];
        });
        return;
    }

    // A newer request owns this object, or this one has already been answered.
    if (generation != self.generation || self.pendingCompletion == nil) {
        return;
    }

    HydraFrameCaptureCompletion completion = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.frameWanted = NO;
    completion(image, error);
}

- (NSError *)errorWithCode:(HydraFrameCaptureErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:HydraFrameCaptureErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
