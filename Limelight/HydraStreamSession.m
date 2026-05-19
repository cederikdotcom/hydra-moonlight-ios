//
//  HydraStreamSession.m
//  Moonlight / hydra-moonlight-ios
//

#import "HydraStreamSession.h"
#import "StreamFrameViewController.h"
#import "StreamConfiguration.h"

// VIDEO_FORMAT flags from moonlight-common-c (Moonlight.h)
#ifndef VIDEO_FORMAT_H264
#define VIDEO_FORMAT_H264  0x0001
#define VIDEO_FORMAT_H265  0x0100
#endif

@interface HydraStreamSession ()
@property (nonatomic, strong) StreamFrameViewController *streamVC;
@property (nonatomic, weak)   UIViewController *presenter;
@end

@implementation HydraStreamSession

- (void)startWithHost:(NSString *)host
              appName:(NSString *)appName
                width:(int)width
               height:(int)height
          bitrateKbps:(int)bitrateKbps
           serverCert:(NSData *)serverCert
            presenter:(UIViewController *)presenter {

    self.presenter = presenter;

    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.host       = host;
    config.httpsPort  = 47989;
    config.appName    = appName;
    config.appID      = @"0"; // resolved server-side by Sunshine via app name
    config.width      = width;
    config.height     = height;
    config.frameRate  = 60;
    config.bitRate    = bitrateKbps;
    config.serverCert = serverCert;

    // Prefer HEVC (hardware decoded on all A9+ iPads), fall back to H264
    if (@available(iOS 11.0, *)) {
        config.supportedVideoFormats = VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264;
    } else {
        config.supportedVideoFormats = VIDEO_FORMAT_H264;
    }

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

    dispatch_async(dispatch_get_main_queue(), ^{
        [presenter presentViewController:vc animated:NO completion:^{
            if ([self.delegate respondsToSelector:@selector(streamSessionDidConnect)]) {
                [self.delegate streamSessionDidConnect];
            }
        }];
    });
}

- (void)stop {
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
