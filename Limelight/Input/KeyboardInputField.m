//
//  KeyboardInputField.m
//  Moonlight
//
//  Created by Cameron Gutman on 12/2/22.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "KeyboardInputField.h"

#import "HydraLog.h"

@implementation KeyboardInputField

- (UIEditingInteractionConfiguration) editingInteractionConfiguration {
    // Suppress the Undo menu that appears with a 3 finger tap
    return UIEditingInteractionConfigurationNone;
}

// Issue 1153. This field is a zero sized buffer that collects keystrokes while
// the keyboard is open. It is not a control, and it must never be a focus
// target. On iPadOS a connected game controller can drive the UIKit focus
// engine, and a focusable text field inside the stream view is then one button
// press away from raising the keyboard over the game.
//
// `becomeFirstResponder` is a different mechanism and is unaffected, so the
// three finger tap and the in stream menu still open the keyboard as before.
- (BOOL) canBecomeFocused {
    return NO;
}

// Diagnostic for issue 1153. Every route into the keyboard passes through here,
// including any route the system takes on its own. Compare this line with the
// "Keyboard: opening" line that `toggleKeyboard` writes: if this appears
// WITHOUT one, the application did not ask for the keyboard and the system
// raised it.
- (BOOL) becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    HydraLog(@"Keyboard: capture field became first responder (accepted %@)",
             accepted ? @"YES" : @"NO");
    return accepted;
}

- (BOOL) resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    HydraLog(@"Keyboard: capture field resigned first responder (%@)",
             resigned ? @"YES" : @"NO");
    return resigned;
}

@end
