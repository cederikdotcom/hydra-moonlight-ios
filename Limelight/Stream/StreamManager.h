//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"

@class VideoDecoderRenderer;

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;

- (NSString*) getStatsOverlayText;
- (NSDictionary *) streamStatsSnapshot;

// The renderer for this stream, so a head side screenshot can reach the one
// object that holds the display layer (issue 1162). Nil until the connection
// has been created on the main queue, and it stays nil for a stream that never
// got that far. Nothing else reaches the renderer: Connection keeps it alive
// through a file static, which is not an accessor.
@property (nonatomic, readonly, nullable) VideoDecoderRenderer *hydraVideoRenderer;

@end
