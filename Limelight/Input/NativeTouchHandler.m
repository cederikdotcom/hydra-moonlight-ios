//
//  NativeTouchHandler.m
//  Moonlight / hydra-moonlight-ios
//

#import "NativeTouchHandler.h"

#include <Limelight.h>

@implementation NativeTouchHandler {
    StreamView* view;

    // UITouch* (as NSValue pointer) → NSNumber (uint32_t pointer ID)
    NSMutableDictionary<NSValue*, NSNumber*> *touchPointerIds;

    // Touches sent via LiSendTouchEvent (vs. mouse fallback)
    NSMutableSet<NSValue*> *nativeTouches;

    uint32_t nextPointerId;
}

- (id)initWithView:(StreamView*)v {
    self = [self init];
    view = v;
    touchPointerIds = [[NSMutableDictionary alloc] init];
    nativeTouches = [[NSMutableSet alloc] init];
    nextPointerId = 0;
    return self;
}

- (NSValue*)keyForTouch:(UITouch*)touch {
    return [NSValue valueWithPointer:(__bridge const void*)touch];
}

- (uint32_t)assignPointerIdForTouch:(UITouch*)touch {
    NSValue *key = [self keyForTouch:touch];
    uint32_t pid = nextPointerId++;
    touchPointerIds[key] = @(pid);
    return pid;
}

- (uint32_t)pointerIdForTouch:(UITouch*)touch {
    NSNumber *n = touchPointerIds[[self keyForTouch:touch]];
    return n ? [n unsignedIntValue] : UINT32_MAX;
}

- (void)forgetTouch:(UITouch*)touch {
    NSValue *key = [self keyForTouch:touch];
    [touchPointerIds removeObjectForKey:key];
    [nativeTouches removeObject:key];
}

- (CGPoint)normalizedPointForTouch:(UITouch*)touch {
    CGPoint viewPoint = [touch locationInView:view];
    CGPoint videoPoint = [view adjustCoordinatesForVideoArea:viewPoint];
    CGSize videoSize = [view getVideoAreaSize];
    return CGPointMake(videoPoint.x / videoSize.width, videoPoint.y / videoSize.height);
}

- (float)pressureForTouch:(UITouch*)touch {
    if (touch.maximumPossibleForce > 0) {
        return (float)(touch.force / touch.maximumPossibleForce);
    }
    return 0.0f;
}

- (BOOL)isNativeTouch:(UITouch*)touch {
    return [nativeTouches containsObject:[self keyForTouch:touch]];
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
    BOOL nativeSupported = (LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0;

    for (UITouch *touch in touches) {
        uint32_t pointerId = [self assignPointerIdForTouch:touch];

        if (nativeSupported) {
            [nativeTouches addObject:[self keyForTouch:touch]];
            CGPoint normalized = [self normalizedPointForTouch:touch];
            LiSendTouchEvent(LI_TOUCH_EVENT_DOWN, pointerId,
                             normalized.x, normalized.y,
                             [self pressureForTouch:touch],
                             0.0f, 0.0f, LI_ROT_UNKNOWN);
        } else {
            // Pre-connection fallback: absolute mouse, single finger only
            if ([[event allTouches] count] == 1) {
                [view updateCursorLocation:[touch locationInView:view] isMouse:NO];
                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
            }
        }
    }
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
    for (UITouch *touch in touches) {
        if ([self isNativeTouch:touch]) {
            uint32_t pointerId = [self pointerIdForTouch:touch];
            if (pointerId == UINT32_MAX) continue;
            CGPoint normalized = [self normalizedPointForTouch:touch];
            LiSendTouchEvent(LI_TOUCH_EVENT_MOVE, pointerId,
                             normalized.x, normalized.y,
                             [self pressureForTouch:touch],
                             0.0f, 0.0f, LI_ROT_UNKNOWN);
        } else {
            [view updateCursorLocation:[touch locationInView:view] isMouse:NO];
        }
    }
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
    BOOL allEnded = ([[event allTouches] count] == [touches count]);

    for (UITouch *touch in touches) {
        if ([self isNativeTouch:touch]) {
            uint32_t pointerId = [self pointerIdForTouch:touch];
            if (pointerId != UINT32_MAX) {
                CGPoint normalized = [self normalizedPointForTouch:touch];
                LiSendTouchEvent(LI_TOUCH_EVENT_UP, pointerId,
                                 normalized.x, normalized.y,
                                 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
            }
        } else if (allEnded) {
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        }
        [self forgetTouch:touch];
    }
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
    BOOL releasedFallbackButton = NO;
    for (UITouch *touch in touches) {
        if ([self isNativeTouch:touch]) {
            uint32_t pointerId = [self pointerIdForTouch:touch];
            if (pointerId != UINT32_MAX) {
                LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL, pointerId,
                                 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
            }
        } else if (!releasedFallbackButton) {
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            releasedFallbackButton = YES;
        }
        [self forgetTouch:touch];
    }
}

@end
