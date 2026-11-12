//
//  HydraFrameCapture.h
//  Moonlight / hydra-moonlight-ios
//
//  Turns one key frame of the live stream into a picture, so an admin
//  screenshot of an iPad kiosk shows the game instead of a black rectangle
//  (issue 1162).
//
//  Why a second decoder is needed at all. The video is in an
//  AVSampleBufferDisplayLayer. submitDecodeBuffer: hands that layer a
//  CMSampleBuffer holding compressed H.264 access units; the layer decodes
//  internally and never gives the pixels back, and the render server
//  composites it, so neither drawHierarchy nor CALayer.render(in:) can read it.
//  There is no decoded pixel buffer anywhere in this process to tap. A head
//  side capture therefore has to decode one frame a second time with a session
//  this application owns.
//
//  This is scoped to interface verification: proving what the person in front
//  of the iPad sees. It is NOT a way to operate a head remotely, and it is not
//  the way to ask what an experience is rendering. The body captures its own
//  desktop, that lane is cheaper, it serves every head type, and it works when
//  the head is asleep or absent.
//
//  The cost is real and is why the caller rate limits this. One capture spends
//  a key frame on the wire and starts a VTDecompressionSession. Peak memory is
//  about 12 MB for a few tens of milliseconds.
//

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const HydraFrameCaptureErrorDomain;

typedef NS_ENUM(NSInteger, HydraFrameCaptureErrorCode) {
    /// A request is already waiting for a key frame. Only one is allowed at a
    /// time, so a stuck request can never queue a second decoder behind it.
    HydraFrameCaptureErrorBusy = 1,
    /// No IDR frame arrived within the deadline. The caller gets this rather
    /// than waiting on a stream that may never deliver one.
    HydraFrameCaptureErrorTimedOut = 2,
    /// The stream is in a codec this capture path does not decode.
    HydraFrameCaptureErrorUnsupportedCodec = 3,
    /// VideoToolbox refused the session, the frame, or the conversion.
    HydraFrameCaptureErrorDecodeFailed = 4,
    /// There is no picture to capture: no live stream, or a stream that has
    /// not shown its first key frame yet.
    HydraFrameCaptureErrorNoPicture = 5,
};

typedef void (^HydraFrameCaptureCompletion)(UIImage *_Nullable image, NSError *_Nullable error);

/// Owned by VideoDecoderRenderer, which offers it every IDR frame it enqueues.
///
/// Steady state cost is one atomic boolean read per key frame, inside the
/// branch submitDecodeBuffer: already takes for an IDR. Nothing else happens on
/// the main thread: the frame is retained and handed to a private serial queue,
/// and the decode, the conversion and the release all happen there.
@interface HydraFrameCapture : NSObject

/// Arms the capture and returns YES when the next IDR frame will be taken.
///
/// Returns NO when a request is already waiting, and calls `completion` with a
/// HydraFrameCaptureErrorBusy error. The caller is expected to ask for a key
/// frame right after this returns YES; this object does not touch the
/// connection.
///
/// `completion` is always called exactly once, on the main thread, with either
/// an image or an error. Call this on the main thread.
- (BOOL)requestFrameWithCompletion:(HydraFrameCaptureCompletion)completion;

/// Offers an IDR sample buffer that has just been enqueued for display.
///
/// Returns at once unless a request is waiting. Call this on the main thread,
/// from inside submitDecodeBuffer:, with a sample buffer whose format
/// description is the one it was created with. The buffer is retained here, so
/// the caller keeps its own release.
- (void)offerIDRSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// Abandons a waiting request, reporting a timeout to whoever asked. Called
/// when the stream stops, so a request can never outlive the stream it was
/// made against.
- (void)cancelPendingRequest;

@end

NS_ASSUME_NONNULL_END
