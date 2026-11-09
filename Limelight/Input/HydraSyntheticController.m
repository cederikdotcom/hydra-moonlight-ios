//
//  HydraSyntheticController.m
//  Moonlight / hydra-moonlight-ios
//

#import "HydraSyntheticController.h"
#import "ControllerSupport.h"
#import "Controller.h"
#import "Limelight.h"
#import "HydraLog.h"

#include <string.h>
#include <unistd.h>

// The virtual gamepad reports its arrival to the host through the branch in
// ControllerSupport reportControllerArrival: that handles a Controller with no
// GCController behind it. That branch declares an Xbox style pad supporting
// exactly these fourteen buttons. Sending a button the pad never declared is
// not worth the risk, so the vocabulary here matches that declaration exactly.
// If that declaration ever grows, grow this table and the cluster's name list
// with it.
static NSString *const HydraSyntheticControllerButtonNames[] = {
    @"a", @"b", @"x", @"y",
    @"up", @"down", @"left", @"right",
    @"left_shoulder", @"right_shoulder",
    @"start", @"back",
    @"left_stick_button", @"right_stick_button",
};
static const NSUInteger HydraSyntheticControllerButtonNameCount = 14;

static const int HydraSyntheticControllerButtonFlags[] = {
    A_FLAG, B_FLAG, X_FLAG, Y_FLAG,
    UP_FLAG, DOWN_FLAG, LEFT_FLAG, RIGHT_FLAG,
    LB_FLAG, RB_FLAG,
    PLAY_FLAG, BACK_FLAG,
    LS_CLK_FLAG, RS_CLK_FLAG,
};

// The keyboard half, issue 1159. A script could press fourteen buttons and
// move the sticks, and could not produce a character, which stopped it at
// every text field in an experience.
//
// Key codes are Windows virtual key codes, which is what LiSendKeyboardEvent
// takes. StreamView.m already sends them that way for the on screen keyboard,
// with 0x0d for Return and 0x08 for Backspace, so this table follows the same
// precedent rather than inventing a second convention.
//
// The arrow keys are deliberately NOT named "up", "down", "left" and "right".
// Those four names already mean the d-pad in this vocabulary, and the sender
// script writes a step as a word, where "up:50" is a d-pad press. A shared
// name would quietly turn a keyboard step into a gamepad step.
static NSString *const HydraSyntheticControllerKeyNames[] = {
    @"enter", @"escape", @"backspace", @"tab", @"space",
    @"delete", @"insert",
    @"home", @"end", @"page_up", @"page_down",
    @"arrow_up", @"arrow_down", @"arrow_left", @"arrow_right",
    @"function_one", @"function_two", @"function_three", @"function_four",
    @"function_five", @"function_six", @"function_seven", @"function_eight",
    @"function_nine", @"function_ten", @"function_eleven", @"function_twelve",
};
static const short HydraSyntheticControllerKeyCodes[] = {
    0x0d, 0x1b, 0x08, 0x09, 0x20,
    0x2e, 0x2d,
    0x24, 0x23, 0x21, 0x22,
    0x26, 0x28, 0x25, 0x27,
    0x70, 0x71, 0x72, 0x73,
    0x74, 0x75, 0x76, 0x77,
    0x78, 0x79, 0x7a, 0x7b,
};
static const NSUInteger HydraSyntheticControllerKeyNameCount = 27;

// A script may not pin the virtual gamepad for an unreasonable time, and may
// not turn a keyboard into a file transfer. These agree with the limits the
// cluster enforces before it queues a script; they are repeated here because
// this layer must stand on its own if it is ever driven from somewhere else.
//
// Text is measured in UTF-8 bytes, which is what LiSendUtf8TextEvent carries
// and what the cluster counts, so the two layers give the same answer for an
// accent or an emoji.
static const NSInteger HydraSyntheticControllerMaximumStepMilliseconds = 10000;
static const NSUInteger HydraSyntheticControllerMaximumSteps = 64;
static const NSUInteger HydraSyntheticControllerMaximumTextBytesPerStep = 256;
static const NSUInteger HydraSyntheticControllerMaximumTextBytesPerScript = 1024;
static const NSUInteger HydraSyntheticControllerMaximumModifiersPerStep = 4;

@interface HydraSyntheticController ()
@property (nonatomic, weak) ControllerSupport *controllerSupport;
@property (nonatomic, strong) dispatch_queue_t runQueue;
// Written by the caller and read on the run queue, so it stays atomic.
@property (atomic, assign) BOOL abandonRequested;
@end

@implementation HydraSyntheticController

- (instancetype)initWithControllerSupport:(ControllerSupport *)controllerSupport {
    self = [super init];
    if (self) {
        _controllerSupport = controllerSupport;
        _runQueue = dispatch_queue_create("com.experiencenet.hydraheadipad.syntheticcontroller",
                                          DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// Returns the flag for a button name, or 0 when the name is not one this
// virtual gamepad declares.
static int HydraSyntheticControllerFlagForName(NSString *name) {
    for (NSUInteger index = 0; index < HydraSyntheticControllerButtonNameCount; index++) {
        if ([HydraSyntheticControllerButtonNames[index] isEqualToString:name]) {
            return HydraSyntheticControllerButtonFlags[index];
        }
    }
    return 0;
}

// Returns the Windows virtual key code for a key name, or 0 when the name is
// not one a script may use. A letter or a digit is named by itself, so that a
// modifier combination such as control and a reads the way an operator says
// it. Only lowercase is accepted, because the cluster accepts only lowercase,
// and the two layers must refuse the same scripts.
static short HydraSyntheticControllerKeyCodeForName(NSString *name) {
    for (NSUInteger index = 0; index < HydraSyntheticControllerKeyNameCount; index++) {
        if ([HydraSyntheticControllerKeyNames[index] isEqualToString:name]) {
            return HydraSyntheticControllerKeyCodes[index];
        }
    }
    if (name.length == 1) {
        unichar character = [name characterAtIndex:0];
        if (character >= 'a' && character <= 'z') {
            return (short)(character - 'a' + 0x41);
        }
        if (character >= '0' && character <= '9') {
            return (short)(character - '0' + 0x30);
        }
    }
    return 0;
}

// Returns the modifier bit for a modifier name, or 0 when the name is unknown.
static char HydraSyntheticControllerModifierForName(NSString *name) {
    if ([name isEqualToString:@"shift"])   { return MODIFIER_SHIFT; }
    if ([name isEqualToString:@"control"]) { return MODIFIER_CTRL; }
    if ([name isEqualToString:@"alt"])     { return MODIFIER_ALT; }
    if ([name isEqualToString:@"meta"])    { return MODIFIER_META; }
    return 0;
}

// Returns the Windows virtual key code of the modifier key itself, so it can
// be held down around the key the script asked for. KeyboardSupport.m uses
// exactly these codes for a hardware keyboard, and sendLowLevelEvent: holds
// the modifier key down the same way. A bare modifier byte is not enough on
// every host, so this follows the path that already works.
static short HydraSyntheticControllerModifierKeyCodeForName(NSString *name) {
    if ([name isEqualToString:@"shift"])   { return 0x10; }
    if ([name isEqualToString:@"control"]) { return 0x11; }
    if ([name isEqualToString:@"alt"])     { return 0x12; }
    if ([name isEqualToString:@"meta"])    { return 0x5B; }
    return 0;
}

// Reads a signed stick axis, clamped to the range the wire format carries.
static short HydraSyntheticControllerAxis(NSDictionary *step, NSString *key) {
    NSNumber *value = step[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return 0;
    }
    NSInteger raw = value.integerValue;
    if (raw < -32768) { raw = -32768; }
    if (raw > 32767) { raw = 32767; }
    return (short)raw;
}

static unsigned char HydraSyntheticControllerTrigger(NSDictionary *step, NSString *key) {
    NSNumber *value = step[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return 0;
    }
    NSInteger raw = value.integerValue;
    if (raw < 0) { raw = 0; }
    if (raw > 255) { raw = 255; }
    return (unsigned char)raw;
}

- (BOOL)runSteps:(NSArray<NSDictionary<NSString *, id> *> *)steps {
    if (steps.count == 0) {
        HydraLog(@"HydraSyntheticController: nothing to run, the script has no steps");
        return NO;
    }
    if (steps.count > HydraSyntheticControllerMaximumSteps) {
        HydraLog(@"HydraSyntheticController: refusing a script of %lu steps, the limit is %ld",
                 (unsigned long)steps.count, (unsigned long)HydraSyntheticControllerMaximumSteps);
        return NO;
    }

    // Check every button name before running anything. A script that is half
    // applied and then abandoned leaves the game in a state nobody asked for,
    // so the whole script is refused instead.
    // The cluster validates a script before it queues it, so a malformed one
    // should never arrive. It is checked again here because this layer must
    // stand on its own, and because a wrong type reaching fast enumeration
    // would take the application down rather than refuse the script.
    NSUInteger totalTextBytes = 0;
    for (id eachStep in steps) {
        if (![eachStep isKindOfClass:[NSDictionary class]]) {
            HydraLog(@"HydraSyntheticController: refusing the script, a step is not a dictionary");
            return NO;
        }
        NSDictionary *step = (NSDictionary *)eachStep;

        id buttons = step[@"buttons"];
        if (buttons != nil) {
            if (![buttons isKindOfClass:[NSArray class]]) {
                HydraLog(@"HydraSyntheticController: refusing the script, buttons is not a list");
                return NO;
            }
            for (id name in (NSArray *)buttons) {
                if (![name isKindOfClass:[NSString class]] ||
                    HydraSyntheticControllerFlagForName((NSString *)name) == 0) {
                    HydraLog(@"HydraSyntheticController: refusing the script, "
                             @"the virtual gamepad has no button named %@", name);
                    return NO;
                }
            }
        }

        // The keyboard half, issue 1159.
        id text = step[@"text"];
        if (text != nil) {
            if (![text isKindOfClass:[NSString class]]) {
                HydraLog(@"HydraSyntheticController: refusing the script, text is not a string");
                return NO;
            }
            NSUInteger bytes = [(NSString *)text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (bytes > HydraSyntheticControllerMaximumTextBytesPerStep) {
                HydraLog(@"HydraSyntheticController: refusing the script, one step holds %lu "
                         @"bytes of text and the limit is %lu",
                         (unsigned long)bytes,
                         (unsigned long)HydraSyntheticControllerMaximumTextBytesPerStep);
                return NO;
            }
            totalTextBytes += bytes;
        }

        id keyName = step[@"key"];
        if (keyName != nil) {
            if (![keyName isKindOfClass:[NSString class]]) {
                HydraLog(@"HydraSyntheticController: refusing the script, key is not a string");
                return NO;
            }
            if (HydraSyntheticControllerKeyCodeForName((NSString *)keyName) == 0) {
                HydraLog(@"HydraSyntheticController: refusing the script, there is no key named "
                         @"%@ (an arrow key is arrow_up, arrow_down, arrow_left or arrow_right)",
                         keyName);
                return NO;
            }
        }
        if (text != nil && keyName != nil) {
            HydraLog(@"HydraSyntheticController: refusing the script, "
                     @"a step sets both text and key");
            return NO;
        }

        id modifiers = step[@"modifiers"];
        if (modifiers != nil) {
            if (![modifiers isKindOfClass:[NSArray class]]) {
                HydraLog(@"HydraSyntheticController: refusing the script, "
                         @"modifiers is not a list");
                return NO;
            }
            if (keyName == nil) {
                HydraLog(@"HydraSyntheticController: refusing the script, a step sets modifiers "
                         @"and no key, and a modifier needs a key to hold");
                return NO;
            }
            if (((NSArray *)modifiers).count > HydraSyntheticControllerMaximumModifiersPerStep) {
                HydraLog(@"HydraSyntheticController: refusing the script, a step holds more than "
                         @"%lu modifiers",
                         (unsigned long)HydraSyntheticControllerMaximumModifiersPerStep);
                return NO;
            }
            for (id name in (NSArray *)modifiers) {
                if (![name isKindOfClass:[NSString class]] ||
                    HydraSyntheticControllerModifierForName((NSString *)name) == 0) {
                    HydraLog(@"HydraSyntheticController: refusing the script, there is no "
                             @"modifier named %@, the modifiers are shift, control, alt and meta",
                             name);
                    return NO;
                }
            }
        }
    }
    if (totalTextBytes > HydraSyntheticControllerMaximumTextBytesPerScript) {
        HydraLog(@"HydraSyntheticController: refusing the script, it holds %lu bytes of text "
                 @"and the limit for one script is %lu",
                 (unsigned long)totalTextBytes,
                 (unsigned long)HydraSyntheticControllerMaximumTextBytesPerScript);
        return NO;
    }

    self.abandonRequested = NO;
    NSArray<NSDictionary<NSString *, id> *> *scriptSteps = [steps copy];

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.runQueue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf executeSteps:scriptSteps];
        }
    });
    return YES;
}

// Runs on the private serial queue.
- (void)executeSteps:(NSArray<NSDictionary<NSString *, id> *> *)steps {
    HydraLog(@"HydraSyntheticController: running a script of %lu steps",
             (unsigned long)steps.count);

    NSUInteger stepNumber = 0;
    for (NSDictionary<NSString *, id> *step in steps) {
        stepNumber++;

        // The weak reference is read again at every step rather than held for
        // the whole script. A stream that ends mid script takes ControllerSupport
        // with it, and sending controller events after the connection stopped is
        // not something to risk for the sake of finishing a sequence.
        ControllerSupport *support = self.controllerSupport;
        Controller *gamepad = [support getOscController];
        if (support == nil || gamepad == nil) {
            HydraLog(@"HydraSyntheticController: the stream ended at step %lu of %lu",
                     (unsigned long)stepNumber, (unsigned long)steps.count);
            return;
        }
        if (self.abandonRequested) {
            HydraLog(@"HydraSyntheticController: abandoned at step %lu of %lu",
                     (unsigned long)stepNumber, (unsigned long)steps.count);
            [self holdNeutralOn:gamepad through:support];
            return;
        }

        NSInteger waitMilliseconds = [step[@"wait_milliseconds"] integerValue];
        NSInteger holdMilliseconds = [step[@"hold_milliseconds"] integerValue];

        if (waitMilliseconds > 0) {
            [self holdNeutralOn:gamepad through:support];
            [self sleepMilliseconds:waitMilliseconds];
            continue;
        }
        if (holdMilliseconds <= 0) {
            HydraLog(@"HydraSyntheticController: step %lu has no duration, skipping it",
                     (unsigned long)stepNumber);
            continue;
        }

        // A keyboard step goes straight to the host, below the gamepad. The
        // live reference was checked above, so the connection is still up.
        // The gamepad is left at neutral, which is why a step may not mix the
        // two: a key and a button in one step would need one hold to mean two
        // different things.
        NSString *text = step[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
            [self typeText:text atStep:stepNumber of:steps.count];
            [self sleepMilliseconds:holdMilliseconds];
            continue;
        }
        NSString *keyName = step[@"key"];
        if ([keyName isKindOfClass:[NSString class]] && keyName.length > 0) {
            [self pressKeyNamed:keyName
                  withModifiers:step[@"modifiers"]
                forMilliseconds:holdMilliseconds
                         atStep:stepNumber
                             of:steps.count];
            continue;
        }

        int buttonFlags = 0;
        for (NSString *name in step[@"buttons"]) {
            buttonFlags |= HydraSyntheticControllerFlagForName(name);
        }

        [support updateButtonFlags:gamepad flags:buttonFlags];
        [support updateLeftStick:gamepad
                              x:HydraSyntheticControllerAxis(step, @"left_stick_x")
                              y:HydraSyntheticControllerAxis(step, @"left_stick_y")];
        [support updateRightStick:gamepad
                               x:HydraSyntheticControllerAxis(step, @"right_stick_x")
                               y:HydraSyntheticControllerAxis(step, @"right_stick_y")];
        [support updateTriggers:gamepad
                           left:HydraSyntheticControllerTrigger(step, @"left_trigger")
                          right:HydraSyntheticControllerTrigger(step, @"right_trigger")];

        // updateFinished is the method a physical gamepad also ends its update
        // with. It is the single place that calls LiSendMultiControllerEvent,
        // and it is where the exit combination is detected, so a scripted
        // combination reaches the host and the head own handling alike.
        [support updateFinished:gamepad];

        [self sleepMilliseconds:holdMilliseconds];

        // Release before the next step, and read the reference once more: the
        // step we just held may have been the exit combination, which ends the
        // stream from under us.
        ControllerSupport *stillLive = self.controllerSupport;
        Controller *stillLiveGamepad = [stillLive getOscController];
        if (stillLive != nil && stillLiveGamepad != nil) {
            [self holdNeutralOn:stillLiveGamepad through:stillLive];
        }
    }

    HydraLog(@"HydraSyntheticController: script finished");
}

// Types a run of text as one UTF-8 text event, which is how the on screen
// keyboard in StreamView.m sends a string the host cannot express as plain key
// events. The host decides where the characters land, so this needs a text
// field with focus in the experience, exactly as a person typing would.
//
// Runs on the private serial queue.
- (void)typeText:(NSString *)text atStep:(NSUInteger)stepNumber of:(NSUInteger)stepCount {
    const char *utf8Text = [text UTF8String];
    if (utf8Text == NULL) {
        HydraLog(@"HydraSyntheticController: step %lu of %lu could not be encoded as UTF-8",
                 (unsigned long)stepNumber, (unsigned long)stepCount);
        return;
    }
    size_t length = strlen(utf8Text);

    // The text itself is never logged. It is operator input that travels in
    // the clear through the cluster, and a log that repeats it would be one
    // more place it lands.
    HydraLog(@"HydraSyntheticController: typing %lu bytes of text at step %lu of %lu",
             (unsigned long)length, (unsigned long)stepNumber, (unsigned long)stepCount);
    LiSendUtf8TextEvent(utf8Text, (unsigned int)length);
}

// Presses a named key, holds it, and releases it.
//
// A modifier is held as its own key around the key press, and is also carried
// in the modifier byte. That is what sendLowLevelEvent: in StreamView.m does
// for a hardware keyboard, and a host that only watches the modifier keys
// would miss a bare modifier byte.
//
// Runs on the private serial queue.
- (void)pressKeyNamed:(NSString *)keyName
        withModifiers:(id)modifierNames
      forMilliseconds:(NSInteger)holdMilliseconds
               atStep:(NSUInteger)stepNumber
                   of:(NSUInteger)stepCount {
    short keyCode = HydraSyntheticControllerKeyCodeForName(keyName);
    if (keyCode == 0) {
        HydraLog(@"HydraSyntheticController: step %lu of %lu names no key this head knows",
                 (unsigned long)stepNumber, (unsigned long)stepCount);
        return;
    }

    char modifierByte = 0;
    NSMutableArray<NSNumber *> *modifierKeyCodes = [NSMutableArray array];
    if ([modifierNames isKindOfClass:[NSArray class]]) {
        for (id name in (NSArray *)modifierNames) {
            if (![name isKindOfClass:[NSString class]]) {
                continue;
            }
            char bit = HydraSyntheticControllerModifierForName((NSString *)name);
            short modifierKeyCode = HydraSyntheticControllerModifierKeyCodeForName((NSString *)name);
            if (bit == 0 || modifierKeyCode == 0) {
                continue;
            }
            modifierByte |= bit;
            [modifierKeyCodes addObject:@(modifierKeyCode)];
        }
    }

    HydraLog(@"HydraSyntheticController: pressing key %@ with %lu modifier(s) at step %lu of %lu",
             keyName, (unsigned long)modifierKeyCodes.count,
             (unsigned long)stepNumber, (unsigned long)stepCount);

    for (NSNumber *modifierKeyCode in modifierKeyCodes) {
        LiSendKeyboardEvent(modifierKeyCode.shortValue, KEY_ACTION_DOWN, modifierByte);
    }
    LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, modifierByte);

    [self sleepMilliseconds:holdMilliseconds];

    // The release always runs, even when the hold was cut short by an abandon
    // or by the stream ending. A key left down on the host is worse than a
    // late release: nothing else will ever lift it.
    LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, modifierByte);
    for (NSNumber *modifierKeyCode in [modifierKeyCodes reverseObjectEnumerator]) {
        LiSendKeyboardEvent(modifierKeyCode.shortValue, KEY_ACTION_UP, modifierByte);
    }
}

// Sleeps in short slices so that a long hold does not delay the teardown of a
// stream that ended, and so that releaseEverything takes effect promptly.
- (void)sleepMilliseconds:(NSInteger)milliseconds {
    if (milliseconds > HydraSyntheticControllerMaximumStepMilliseconds) {
        milliseconds = HydraSyntheticControllerMaximumStepMilliseconds;
    }
    const NSInteger sliceMilliseconds = 25;
    NSInteger slept = 0;
    while (slept < milliseconds) {
        if (self.abandonRequested) {
            return;
        }
        NSInteger slice = MIN(sliceMilliseconds, milliseconds - slept);
        usleep((useconds_t)(slice * 1000));
        slept += slice;
    }
}

- (void)holdNeutralOn:(Controller *)gamepad through:(ControllerSupport *)support {
    [support updateButtonFlags:gamepad flags:0];
    [support updateLeftStick:gamepad x:0 y:0];
    [support updateRightStick:gamepad x:0 y:0];
    [support updateTriggers:gamepad left:0 right:0];
    [support updateFinished:gamepad];
}

- (void)releaseEverything {
    self.abandonRequested = YES;

    ControllerSupport *support = self.controllerSupport;
    Controller *gamepad = [support getOscController];
    if (support == nil || gamepad == nil) {
        return;
    }
    [self holdNeutralOn:gamepad through:support];
    HydraLog(@"HydraSyntheticController: released every button on request");
}

@end
