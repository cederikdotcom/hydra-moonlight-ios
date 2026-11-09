//
//  HydraSyntheticController.h
//  Moonlight / hydra-moonlight-ios
//
//  Runs a scripted controller sequence through the same path a physical
//  gamepad uses, so the body receives input it cannot tell apart from a person
//  holding the controller in front of the iPad (issue 1155). A step can also
//  type text or press a named key, which reaches the host as a keyboard event
//  (issue 1159).
//
//  This is NOT a credential channel. A script arrives as JSON from the
//  cluster, which holds it in memory, and the sender script prints it. Use it
//  for menus, search boxes, chat and in-game text, never for a password.
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
///
/// A `key` step names a key instead: `enter`, `escape`, `backspace`, `tab`,
/// `space`, `delete`, `insert`, `home`, `end`, `page_up`, `page_down`,
/// `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `function_one` to
/// `function_twelve`, any single lowercase letter, or any single digit.
///
/// The arrow keys are deliberately not called `up`, `down`, `left` and
/// `right`. Those four names already mean the d-pad, and a shared name would
/// quietly turn a keyboard step into a gamepad step.
@interface HydraSyntheticController : NSObject

- (instancetype)initWithControllerSupport:(ControllerSupport *)controllerSupport;

/// Runs a sequence of steps and returns immediately. The steps run on a
/// private serial queue, so one script never overlaps another and a long
/// script never blocks the main thread.
///
/// Each step is a dictionary. A step either holds a state for
/// `hold_milliseconds` and then returns to neutral, or it rests at neutral for
/// `wait_milliseconds`.
///
/// Recognised keys: `buttons` (an array of names), `left_trigger`,
/// `right_trigger`, `left_stick_x`, `left_stick_y`, `right_stick_x`,
/// `right_stick_y`, `text`, `key`, `modifiers` (`shift`, `control`, `alt`,
/// `meta`), `hold_milliseconds`, `wait_milliseconds`.
///
/// `text` types a run of characters. `key` presses one named key, holds it for
/// `hold_milliseconds` and releases it. A step may not hold both, and may not
/// mix a keyboard field with a gamepad field, because one hold cannot mean two
/// things. Both need a live stream: a keyboard event goes to the host.
///
/// Returns NO without running anything when a step names a button this virtual
/// gamepad does not declare, names a key or a modifier that does not exist, or
/// carries more text than the caps allow (256 UTF-8 bytes in one step, 1024 in
/// one script). The reason is written to the log. The text itself is never
/// logged.
- (BOOL)runSteps:(NSArray<NSDictionary<NSString *, id> *> *)steps;

/// Puts the virtual gamepad back to neutral at once and abandons anything
/// still queued. Called when a stream ends so that no button is left held.
- (void)releaseEverything;

@end

NS_ASSUME_NONNULL_END
