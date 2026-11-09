//
//  HydraSyntheticController.h
//  Moonlight / hydra-moonlight-ios
//
//  Runs a scripted controller sequence through the same path a physical
//  gamepad uses, so the body receives input it cannot tell apart from a person
//  holding the controller in front of the iPad (issue 1155).
//

#import <Foundation/Foundation.h>

@class ControllerSupport;

NS_ASSUME_NONNULL_BEGIN

/// A script may only name the buttons the virtual gamepad declares to the host
/// when it reports its arrival: a, b, x, y, up, down, left, right,
/// left_shoulder, right_shoulder, start, back, left_stick_button and
/// right_stick_button. The names are spelled in full. A name outside that set
/// is refused rather than dropped, because a button that silently does nothing
/// is harder to notice than a refusal. The table itself stays private to the
/// implementation, next to the flag each name maps to.
@interface HydraSyntheticController : NSObject

- (instancetype)initWithControllerSupport:(ControllerSupport *)controllerSupport;

/// Runs a sequence of steps and returns immediately. The steps run on a
/// private serial queue, so one script never overlaps another and a long
/// script never blocks the main thread.
///
/// Each step is a dictionary. A step either holds a controller state for
/// `hold_milliseconds` and then returns the controller to neutral, or it rests
/// at neutral for `wait_milliseconds`.
///
/// Recognised keys: `buttons` (an array of names), `left_trigger`,
/// `right_trigger`, `left_stick_x`, `left_stick_y`, `right_stick_x`,
/// `right_stick_y`, `hold_milliseconds`, `wait_milliseconds`.
///
/// Returns NO without running anything when a step names a button this virtual
/// gamepad does not declare. The reason is written to the log.
- (BOOL)runSteps:(NSArray<NSDictionary<NSString *, id> *> *)steps;

/// Puts the virtual gamepad back to neutral at once and abandons anything
/// still queued. Called when a stream ends so that no button is left held.
- (void)releaseEverything;

@end

NS_ASSUME_NONNULL_END
