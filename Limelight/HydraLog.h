// HydraLog.h — global ObjC→AppLogger bridge.
// Logs go to NSLog (device console) AND, if a callback is registered, to the in-app log viewer.
// Import this header in any ObjC file that needs diagnostic logging.
// No UIKit dependency — safe to import from deep inside the streaming stack.

#pragma once
#import <Foundation/Foundation.h>

// Log a message to NSLog and (if registered) to the Swift AppLogger.
// Format and varargs match NSLog. Thread-safe.
void HydraLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

// Register the Swift-side AppLogger callback. Call once at app launch.
// Subsequent calls replace the existing callback. Safe to call from any thread.
void HydraSetGlobalLogCallback(void (^callback)(NSString *message));
