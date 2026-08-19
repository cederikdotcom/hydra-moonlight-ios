//
//  NativeTouchHandler.m
//  Moonlight / hydra-moonlight-ios
//

#import "NativeTouchHandler.h"

#include <Limelight.h>

@implementation NativeTouchHandler {
    StreamView* view;
    NSMutableDictionary<NSValue*, NSNumber*>* pointerIds;
    uint32_t nextPointerId;
    BOOL useMouseFallback;
    BOOL mousePressActive;
}

- (id)initWithView:(StreamView*)v {
    self = [self init];
    view = v;
    pointerIds = [[NSMutableDictionary alloc] init];
    nextPointerId = 1;
    useMouseFallback = NO;
    mousePressActive = NO;
    return self;
}

// Returns NO when the host rejected the event as unsupported, which switches
// the whole session to the mouse fallback path.
- (BOOL)sendTouchEvent:(uint8_t)eventType forTouch:(UITouch*)touch {
    NSValue* key = [NSValue valueWithNonretainedObject:touch];
    NSNumber* pointerId = pointerIds[key];
    if (eventType == LI_TOUCH_EVENT_DOWN) {
        pointerId = @(nextPointerId++);
        pointerIds[key] = pointerId;
    }
    if (pointerId == nil) {
        // MOVE/UP for a touch whose DOWN we never sent (e.g. it began during
        // fallback probing) — nothing to reference on the host, drop it.
        return YES;
    }
    if (eventType == LI_TOUCH_EVENT_UP || eventType == LI_TOUCH_EVENT_CANCEL) {
        [pointerIds removeObjectForKey:key];
    }

    CGPoint location = [view adjustCoordinatesForVideoArea:[touch locationInView:view]];
    CGSize videoSize = [view getVideoAreaSize];
    float x = MIN(MAX(location.x / videoSize.width, 0.0f), 1.0f);
    float y = MIN(MAX(location.y / videoSize.height, 0.0f), 1.0f);

    float pressure;
    if (eventType == LI_TOUCH_EVENT_UP || eventType == LI_TOUCH_EVENT_CANCEL) {
        pressure = 0.0f;
    } else if (touch.maximumPossibleForce > 0 && touch.force > 0) {
        pressure = MIN(touch.force / touch.maximumPossibleForce, 1.0f);
    } else {
        // Digitizers without force reporting still have a finger in contact
        pressure = 0.5f;
    }

    int err = LiSendTouchEvent(eventType, [pointerId unsignedIntValue], x, y, pressure,
                               0.0f, 0.0f, LI_ROT_UNKNOWN);
    if (err == LI_ERR_UNSUPPORTED) {
        [pointerIds removeAllObjects];
        return NO;
    }
    return YES;
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
    if (useMouseFallback) {
        [self mouseTouchesBegan:touches withEvent:event];
        return;
    }
    for (UITouch* touch in touches) {
        if (![self sendTouchEvent:LI_TOUCH_EVENT_DOWN forTouch:touch]) {
            Log(LOG_I, @"Host does not support touch events, falling back to mouse emulation");
            useMouseFallback = YES;
            [self mouseTouchesBegan:touches withEvent:event];
            return;
        }
    }
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
    if (useMouseFallback) {
        [self mouseTouchesMoved:touches withEvent:event];
        return;
    }
    for (UITouch* touch in touches) {
        [self sendTouchEvent:LI_TOUCH_EVENT_MOVE forTouch:touch];
    }
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
    if (useMouseFallback) {
        [self mouseTouchesEnded:touches withEvent:event];
        return;
    }
    for (UITouch* touch in touches) {
        [self sendTouchEvent:LI_TOUCH_EVENT_UP forTouch:touch];
    }
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
    if (useMouseFallback) {
        [self mouseTouchesEnded:touches withEvent:event];
        return;
    }
    for (UITouch* touch in touches) {
        [self sendTouchEvent:LI_TOUCH_EVENT_CANCEL forTouch:touch];
    }
}

#pragma mark - Absolute mouse fallback (hosts without LI_FF_PEN_TOUCH_EVENTS)

- (void)mouseTouchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
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

- (void)mouseTouchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [touches anyObject];
        [view updateCursorLocation:[touch locationInView:view] isMouse:NO];
    }
}

- (void)mouseTouchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
    if ([[event allTouches] count] == [touches count]) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        mousePressActive = NO;
    }
}

@end
