//
//  HydraStreamSession.m
//  Moonlight / hydra-moonlight-ios
//

#import "HydraStreamSession.h"
#import "HydraLog.h"
#import "StreamFrameViewController.h"
#import "StreamConfiguration.h"

// ── Global ObjC→AppLogger bridge ──────────────────────────────────────────────
// Survives across session teardowns; safe to set once at app start and forget.
static void (^_hydraLogCallback)(NSString *);

void HydraSetGlobalLogCallback(void (^callback)(NSString *)) {
    _hydraLogCallback = callback ? [callback copy] : nil;
}

void HydraLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[HydraLog] %@", msg);
    void (^cb)(NSString *) = _hydraLogCallback;
    if (cb) { cb(msg); }
}
// ─────────────────────────────────────────────────────────────────────────────

// VIDEO_FORMAT flags from moonlight-common-c (Moonlight.h)
#ifndef VIDEO_FORMAT_H264
#define VIDEO_FORMAT_H264  0x0001
#define VIDEO_FORMAT_H265  0x0100
#endif

@interface HydraStreamSession () <NSURLSessionDelegate>
@property (nonatomic, strong) StreamFrameViewController *streamVC;
@property (nonatomic, weak)   UIViewController *presenter;
@property (nonatomic, weak)   UIButton *exitButton;
// Stored at start so stop() can send /cancel even before LiStartConnection ran.
@property (nonatomic, strong) NSString *sunshineHost;
@property (nonatomic, assign) unsigned short sunshineHttpsPort;
@property (nonatomic, strong) NSData *sunshineServerCert;
@end

@implementation HydraStreamSession

+ (void)setGlobalLogCallback:(void (^)(NSString *))callback {
    HydraSetGlobalLogCallback(callback);
}

- (void)startWithHost:(NSString *)host
              appName:(NSString *)appName
                width:(int)width
               height:(int)height
          bitrateKbps:(int)bitrateKbps
           serverCert:(NSData *)serverCert
            presenter:(UIViewController *)presenter {

    HydraLog(@"HydraStreamSession: startWithHost host=%@ app=%@ %dx%d %dkbps cert=%luB",
             host, appName, width, height, bitrateKbps, (unsigned long)serverCert.length);
    self.presenter = presenter;
    self.sunshineHost = host;
    self.sunshineHttpsPort = 47984;
    self.sunshineServerCert = serverCert;

    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.host       = host;
    config.httpsPort  = 47984; // Sunshine HTTPS GameStream port; 47989 is HTTP-only
    config.appName    = appName;
    config.appID      = @"0"; // resolved server-side by Sunshine via app name
    config.width      = width;
    config.height     = height;
    config.frameRate  = 60;
    config.bitRate    = bitrateKbps;
    config.serverCert = serverCert;

    // Force H.264 — HEVC causes a silent DR_NEED_IDR loop with certain NVENC
    // configurations (RTX 4000+/Blackwell) where iOS VideoToolbox rejects the
    // VPS/SPS/PPS but moonlight-common-c keeps requesting IDR frames indefinitely.
    // Re-enable HEVC (VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) once stream is confirmed.
    config.supportedVideoFormats = VIDEO_FORMAT_H264;

    config.audioConfiguration = 1; // stereo
    config.useFramePacing     = YES;
    config.optimizeGameSettings = NO;
    config.playAudioOnPC      = NO;
    config.multiController    = NO;

    StreamFrameViewController *vc = [[StreamFrameViewController alloc] init];
    vc.streamConfig = config;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    self.streamVC = vc;

    __weak HydraStreamSession *weakSelf = self;
    vc.hydraErrorCallback = ^(NSString *title, NSString *message) {
        HydraStreamSession *s = weakSelf;
        if (!s) return;
        NSString *combined = [NSString stringWithFormat:@"%@: %@", title, message];
        NSError *error = [NSError errorWithDomain:@"HydraStream" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: combined}];
        if ([s.delegate respondsToSelector:@selector(streamSessionDidFailWithError:)]) {
            [s.delegate streamSessionDidFailWithError:error];
        }
    };

    vc.hydraStageStarted = ^(NSString *stage) {
        HydraStreamSession *s = weakSelf;
        if (!s) return;
        if ([s.delegate respondsToSelector:@selector(streamSessionStageStarted:)]) {
            [s.delegate streamSessionStageStarted:stage];
        }
    };

    vc.hydraConnectionStartedCallback = ^{
        HydraStreamSession *s = weakSelf;
        if (!s) return;
        if ([s.delegate respondsToSelector:@selector(streamSessionConnectionStarted)]) {
            [s.delegate streamSessionConnectionStarted];
        }
    };

    vc.hydraApplicationResignActiveCallback = ^{
        HydraStreamSession *s = weakSelf;
        if (!s) return;
        if ([s.delegate respondsToSelector:@selector(streamSessionApplicationResignActive)]) {
            [s.delegate streamSessionApplicationResignActive];
        }
    };

    // returnToMainFrame in the upstream Moonlight VC only pops a navigation stack.
    // Since we present it as a modal, that call is a no-op. This block receives that
    // signal instead and calls stop() which properly dismisses the VC and fires
    // streamSessionDidStop, resetting the Swift state machine.
    vc.hydraReturnToMainFrame = ^{
        HydraStreamSession *s = weakSelf;
        if (!s) return;
        [s stop];
    };

    HydraLog(@"HydraStreamSession: presenting StreamFrameViewController (dispatching to main)...");
    dispatch_async(dispatch_get_main_queue(), ^{
        [presenter presentViewController:vc animated:NO completion:^{
            HydraLog(@"HydraStreamSession: StreamFrameViewController presented — StreamManager running");
            [self addExitMenuToVC:vc];
            if ([self.delegate respondsToSelector:@selector(streamSessionDidConnect)]) {
                [self.delegate streamSessionDidConnect];
            }
        }];
    });
}

- (void)addExitMenuToVC:(UIViewController *)vc {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *icon = [UIImage systemImageNamed:@"ellipsis.circle.fill"];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium];
    [btn setImage:[icon imageByApplyingSymbolConfiguration:config] forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    btn.layer.cornerRadius = 22;
    btn.clipsToBounds = YES;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:btn];
    [vc.view bringSubviewToFront:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [btn.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:16],
        [btn.widthAnchor constraintEqualToConstant:44],
        [btn.heightAnchor constraintEqualToConstant:44],
    ]];
    __weak HydraStreamSession *weakSelf = self;
    __weak UIButton *weakBtn = btn;
    [btn addTarget:weakSelf action:@selector(exitMenuTapped) forControlEvents:UIControlEventTouchUpInside];
    self.exitButton = btn;
}

- (void)exitMenuTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (self.viewLogsCallback) {
        void (^cb)(void) = self.viewLogsCallback;
        [alert addAction:[UIAlertAction actionWithTitle:@"View logs"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { cb(); }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Exit experience"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [self stop]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    // iPad requires a source for the action sheet popover
    alert.popoverPresentationController.sourceView = self.exitButton;
    alert.popoverPresentationController.sourceRect = self.exitButton.bounds;
    [self.streamVC presentViewController:alert animated:YES completion:nil];
}

// Sends GET /cancel to Sunshine so it terminates the app session immediately.
// Called from stop() regardless of whether LiStartConnection ran. Without this
// Sunshine keeps streaming until its own timeout (~30-60s) when the client
// disconnects mid-launch (before the RTSP control channel was established).
- (void)sendCancelToSunshine {
    if (!self.sunshineHost || self.sunshineHttpsPort == 0) return;
    NSString *urlString = [NSString stringWithFormat:@"https://%@:%u/cancel?uniqueid=0123456789ABCDEF",
                           self.sunshineHost, self.sunshineHttpsPort];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 3;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:self
                                                     delegateQueue:nil];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        Log(LOG_D, @"Sunshine /cancel: %@ %@", resp, error);
        [session invalidateAndCancel];
    }] resume];
}

// Accept Sunshine's self-signed cert for the /cancel request.
// This is a fire-and-forget operational call; cert pinning failure would just
// mean Sunshine keeps streaming until its own timeout, which is worse.
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)stop {
    HydraLog(@"HydraStreamSession: stop() called — sending /cancel + dismissing VC");
    [self sendCancelToSunshine];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.streamVC && self.streamVC.presentingViewController) {
            [self.streamVC dismissViewControllerAnimated:NO completion:^{
                self.streamVC = nil;
                if ([self.delegate respondsToSelector:@selector(streamSessionDidStop)]) {
                    [self.delegate streamSessionDidStop];
                }
            }];
        } else {
            self.streamVC = nil;
            if ([self.delegate respondsToSelector:@selector(streamSessionDidStop)]) {
                [self.delegate streamSessionDidStop];
            }
        }
    });
}

@end
