//
//  NativeTouchHandler.h
//  Moonlight / hydra-moonlight-ios
//

#import "StreamView.h"

NS_ASSUME_NONNULL_BEGIN

// Sends native multi-touch events via LiSendTouchEvent() for Sunshine hosts that
// support LI_FF_PEN_TOUCH_EVENTS. Falls back to absolute mouse position events
// for hosts that don't (or before the connection is fully established).
@interface NativeTouchHandler : UIResponder

- (id)initWithView:(StreamView*)view;

@end

NS_ASSUME_NONNULL_END
