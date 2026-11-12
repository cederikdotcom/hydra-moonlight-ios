//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"
#import "HydraFrameCapture.h"

#include "Limelight.h"

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

// The three Hydra additions behind an admin screenshot that shows the game
// rather than a black rectangle (issue 1162). All three are main thread only,
// and all three refuse while no key frame has been shown yet.

// Asks the host for a key frame and decodes it a second time into a picture.
// Returns NO, having called the completion with an error, when there is
// nothing to capture or a capture is already waiting.
- (BOOL)hydraCaptureVideoFrameWithCompletion:(HydraFrameCaptureCompletion)completion;

// The display layer's rectangle in window coordinates: where the picture sits
// inside the letterbox. Read from the live layer rather than recomputed, so
// rotation needs no second opinion. CGRectNull when there is no picture.
- (CGRect)hydraVideoRectInWindow;

// Runs `block` with the display layer's background colour cleared, then puts
// black back whatever happens.
//
// This is what lets drawHierarchy leave a transparent hole where the video is,
// instead of painting the layer's own black over the frame underneath. On
// screen it changes nothing: the layer's bounds are the aspect fit rectangle
// and its videoGravity is Resize, so decoded content covers the layer exactly
// and this colour is never visible during a stream.
- (void)hydraRunWithVideoBackgroundClear:(void (NS_NOESCAPE ^)(void))block;

// Abandons a waiting capture. Called when the stream stops.
- (void)hydraCancelPendingCapture;

@end
