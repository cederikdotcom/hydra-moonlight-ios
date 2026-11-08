//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;
// Opens the on screen keyboard when it is closed, closes it when it is open.
//
// Two callers: the three finger tap in `touchesBegan`, and the Keyboard row in
// the in stream menu that `HydraStreamSession` builds. Exactly one place knows
// how to raise the keyboard, so the gesture and the menu can never drift apart
// (issue #1149).
- (void) toggleKeyboard;
- (void) toggleKeyboardFromSource:(NSString *)source;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
- (CGPoint)adjustCoordinatesForVideoArea:(CGPoint)location;
- (CGSize)getVideoAreaSize;
#endif

@end
