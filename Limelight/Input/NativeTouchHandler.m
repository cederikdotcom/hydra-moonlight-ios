//
//  NativeTouchHandler.m
//  Moonlight / hydra-moonlight-ios
//

#import "NativeTouchHandler.h"

#include <Limelight.h>

@implementation NativeTouchHandler {
    StreamView* view;
    BOOL mousePressActive;
}

- (id)initWithView:(StreamView*)v {
    self = [self init];
    view = v;
    mousePressActive = NO;
    return self;
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
    NSUInteger allTouchCount = [[event allTouches] count];

    if (allTouchCount == 1) {
        UITouch *touch = [touches anyObject];
        [view updateCursorLocation:[touch locationInView:view] isMouse:NO];
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        mousePressActive = YES;
    } else if (mousePressActive) {
        // Second finger arrived while mouse was held — cancel the active press
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        mousePressActive = NO;
    }
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [touches anyObject];
        [view updateCursorLocation:[touch locationInView:view] isMouse:NO];
    }
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
    if ([[event allTouches] count] == [touches count]) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        mousePressActive = NO;
    }
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

@end
