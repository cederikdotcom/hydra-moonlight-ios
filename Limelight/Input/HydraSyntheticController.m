//
//  HydraSyntheticController.m
//  Moonlight / hydra-moonlight-ios
//

#import "HydraSyntheticController.h"
#import "ControllerSupport.h"
#import "Controller.h"
#import "Limelight.h"
#import "HydraLog.h"

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

// A script may not pin the virtual gamepad for an unreasonable time. These
// agree with the limits the cluster enforces before it queues a script; they
// are repeated here because this layer must stand on its own if it is ever
// driven from somewhere else.
static const NSInteger HydraSyntheticControllerMaximumStepMilliseconds = 10000;
static const NSUInteger HydraSyntheticControllerMaximumSteps = 64;

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
    for (id step in steps) {
        if (![step isKindOfClass:[NSDictionary class]]) {
            HydraLog(@"HydraSyntheticController: refusing the script, a step is not a dictionary");
            return NO;
        }
        id buttons = ((NSDictionary *)step)[@"buttons"];
        if (buttons == nil) {
            continue;
        }
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
