//
//  HydraStreamSession.m
//  Moonlight / hydra-moonlight-ios
//

#import "HydraStreamSession.h"
#import "HydraLog.h"
#import "StreamFrameViewController.h"
#import "StreamConfiguration.h"
#import "HttpManager.h"

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

// VIDEO_FORMAT and AUDIO_CONFIGURATION flags from moonlight-common-c (Limelight.h)
#ifndef VIDEO_FORMAT_H264
#define VIDEO_FORMAT_H264  0x0001
#define VIDEO_FORMAT_H265  0x0100
#define MAKE_AUDIO_CONFIGURATION(ch, mask) (((mask) << 16) | ((ch) << 8) | 0xCA)
#define AUDIO_CONFIGURATION_STEREO MAKE_AUDIO_CONFIGURATION(2, 0x3)
#endif

@interface HydraStreamSession ()
@property (nonatomic, strong) StreamFrameViewController *streamVC;
@property (nonatomic, weak)   UIViewController *presenter;
@property (nonatomic, weak)   UIButton *exitButton;
// Stored at start so stop() can send /cancel even before LiStartConnection ran.
@property (nonatomic, strong) NSString *sunshineHost;
@property (nonatomic, assign) unsigned short sunshineHttpsPort;
@property (nonatomic, strong) NSData *sunshineServerCert;
@property (nonatomic, assign) BOOL stopRequested;
@property (nonatomic, strong) NSError *terminalError;
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
    self.stopRequested = NO;
    self.terminalError = nil;
    self.presenter = presenter;
    self.sunshineHost = host;
    if (self.portBase <= 0) { self.portBase = 47989; }
    self.sunshineHttpsPort = self.portBase - 5;
    self.sunshineServerCert = serverCert;

    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.host       = host;
    config.httpsPort  = self.portBase - 5; // GameStream HTTPS; portBase itself is HTTP-only
    config.appName    = appName;
    config.appID      = @"0"; // resolved server-side by Sunshine via app name
    config.width      = width;
    config.height     = height;
    config.frameRate  = 60;
    config.bitRate    = bitrateKbps;
    config.serverCert = serverCert;
    config.packetSizeOverride = self.packetSizeOverride;
    if (self.packetSizeOverride > 0) {
        HydraLog(@"HydraStreamSession: tunnelled body, packet size %d", self.packetSizeOverride);
    }

    // Force H.264 — HEVC causes a silent DR_NEED_IDR loop with certain NVENC
    // configurations (RTX 4000+/Blackwell) where iOS VideoToolbox rejects the
    // VPS/SPS/PPS but moonlight-common-c keeps requesting IDR frames indefinitely.
    // Re-enable HEVC (VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) once stream is confirmed.
    config.supportedVideoFormats = VIDEO_FORMAT_H264;

    config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    config.useFramePacing     = YES;
    config.optimizeGameSettings = YES;
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
        // Keep the Swift state in streaming until cancellation has finished.
        // Otherwise the error screen can launch a successor before the old
        // body's delayed /cancel reaches Sunshine.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s.stopRequested) return;
            s.terminalError = error;
            [s stop];
        });
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
    if (self.viewMicrophoneCallback) {
        void (^cb)(void) = self.viewMicrophoneCallback;
        [alert addAction:[UIAlertAction actionWithTitle:@"Microphone"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { cb(); }]];
    }
    if (self.viewDiagnosticsCallback) {
        void (^cb)(void) = self.viewDiagnosticsCallback;
        [alert addAction:[UIAlertAction actionWithTitle:@"Stream diagnostics"
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

// Use Moonlight's paired TLS client identity and pinned server certificate.
// An ordinary NSURLSession presents no client certificate, so Sunshine rejects
// /cancel and keeps the app alive even after the video connection has ended.
// Runs on a worker queue; stop does not return the user to the catalog until
// this bounded attempt has completed.
- (void)sendCancelToSunshine {
    if (!self.sunshineHost || self.sunshineHttpsPort == 0) return;
    HttpManager *manager = [[HttpManager alloc] initWithAddress:self.sunshineHost
                                                    httpsPort:self.sunshineHttpsPort
                                                   serverCert:self.sunshineServerCert];
    NSMutableURLRequest *request = [[manager newQuitAppRequest] mutableCopy];
    if (!request) return;
    request.timeoutInterval = 3;
    HttpResponse *response = [[HttpResponse alloc] init];
    [manager executeRequestSynchronously:[HttpRequest requestForResponse:response withUrlRequest:request]];
    HydraLog(@"Sunshine /cancel completed: status=%d message=%@", response.statusCode, response.statusMessage);
}

- (NSDictionary *)streamStatsSnapshot {
    return [self.streamVC streamStatsSnapshot];
}

- (void)finishStop {
    self.streamVC = nil;
    if (self.terminalError && [self.delegate respondsToSelector:@selector(streamSessionDidFailWithError:)]) {
        [self.delegate streamSessionDidFailWithError:self.terminalError];
    } else if ([self.delegate respondsToSelector:@selector(streamSessionDidStop)]) {
        [self.delegate streamSessionDidStop];
    }
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopRequested) return;
        self.stopRequested = YES;
        HydraLog(@"HydraStreamSession: stopping — authenticated /cancel before returning to menu");
        [self.streamVC hydraStop];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self sendCancelToSunshine];
            dispatch_async(dispatch_get_main_queue(), ^{
                // Dismiss the presenter, including any open exit action sheet.
                UIViewController *presenting = self.streamVC.presentingViewController;
                if (presenting) {
                    [presenting dismissViewControllerAnimated:NO completion:^{ [self finishStop]; }];
                } else {
                    [self finishStop];
                }
            });
        });
    });
}

@end
