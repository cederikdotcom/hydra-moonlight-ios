//
//  HydraStreamSession.h
//  Moonlight / hydra-moonlight-ios
//
//  Hydra integration entry point. Provides a simple API for HydraHeadiPad
//  to start and stop a GameStream session without touching internal Moonlight
//  state machines directly.
//

#import <UIKit/UIKit.h>

@protocol HydraStreamSessionDelegate <NSObject>
- (void)streamSessionDidConnect;
- (void)streamSessionDidStop;
- (void)streamSessionDidFailWithError:(NSError *)error;
@optional
// Diagnostic callbacks — forward moonlight-common-c events to AppLogger.
- (void)streamSessionStageStarted:(NSString *)stage;
- (void)streamSessionConnectionStarted;
- (void)streamSessionApplicationResignActive;
@end

@interface HydraStreamSession : NSObject

@property (nonatomic, weak) id<HydraStreamSessionDelegate> delegate;

// Register the global ObjC→AppLogger callback. Call once at app launch.
// Logs from ALL sessions flow through this regardless of per-session delegate state.
+ (void)setGlobalLogCallback:(void (^)(NSString *message))callback;

// Present a full-screen stream to the given host and app.
// host         — IP address (LAN or WireGuard) of the Sunshine body
// appName      — experience name as registered in Sunshine (e.g. "mercator-talks")
// width/height — stream resolution (1920x1080 landscape, 1080x1920 portrait)
// bitrateKbps  — 150000 for LAN, 25000 for WireGuard
// serverCert   — DER-encoded cert obtained during pairing (nil to skip cert pinning)
// presenter    — UIViewController to present the stream on top of
- (void)startWithHost:(NSString *)host
              appName:(NSString *)appName
                width:(int)width
               height:(int)height
          bitrateKbps:(int)bitrateKbps
           serverCert:(NSData *)serverCert
            presenter:(UIViewController *)presenter;

// Disconnect and dismiss the stream view.
- (void)stop;

@end
