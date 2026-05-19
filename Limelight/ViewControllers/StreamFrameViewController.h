//
//  StreamFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamConfiguration.h"
#import "StreamView.h"

#import <UIKit/UIKit.h>

#if TARGET_OS_TV
@import GameController;

@interface StreamFrameViewController : GCEventViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#else
@interface StreamFrameViewController : UIViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#endif
@property (nonatomic) StreamConfiguration* streamConfig;
// Called before the error alert when launchFailed:/stageFailed:/connectionTerminated: fires.
// HydraStreamSession sets this to route the error message back to the Swift layer.
@property (nonatomic, copy) void(^hydraErrorCallback)(NSString *title, NSString *message);
// Called by returnToMainFrame instead of popToRootViewControllerAnimated when set.
// HydraStreamSession sets this to properly dismiss the modal and notify the Swift layer.
@property (nonatomic, copy) void(^hydraReturnToMainFrame)(void);

-(void)updatePreferredDisplayMode:(BOOL)streamActive;

@end
