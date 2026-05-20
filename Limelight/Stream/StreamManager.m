//
//  StreamManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamManager.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Utils.h"
#import "HydraLog.h"

#import "StreamView.h"
#import "ServerInfoResponse.h"
#import "AppListResponse.h"
#import "TemporaryApp.h"
#import "HttpResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"

#include <Limelight.h>

@implementation StreamManager {
    StreamConfiguration* _config;

    UIView* _renderView;
    id<ConnectionCallbacks> _callbacks;
    Connection* _connection;
}

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callbacks {
    self = [super init];
    _config = config;
    _renderView = view;
    _callbacks = callbacks;
    _config.riKey = [Utils randomBytes:16];
    _config.riKeyId = arc4random();
    return self;
}

- (void)main {
    HydraLog(@"StreamManager: main START — host=%@ app=%@ httpsPort=%d", _config.host, _config.appName, _config.httpsPort);

    [CryptoManager generateKeyPairUsingSSL];
    HydraLog(@"StreamManager: crypto ready — making serverinfo HTTPS to %@:%d...", _config.host, _config.httpsPort);

    HttpManager* hMan = [[HttpManager alloc] initWithAddress:_config.host httpsPort:_config.httpsPort
                                                     serverCert:_config.serverCert];

    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                       fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    NSString* pairStatus = [serverInfoResp getStringTag:@"PairStatus"];
    NSString* appversion = [serverInfoResp getStringTag:@"appversion"];
    NSString* gfeVersion = [serverInfoResp getStringTag:@"GfeVersion"];
    NSString* serverState = [serverInfoResp getStringTag:@"state"];
    HydraLog(@"StreamManager: serverinfo done — statusCode=%d pairStatus=%@ state=%@ appVersion=%@",
             serverInfoResp.statusCode, pairStatus, serverState, appversion);

    if (![serverInfoResp isStatusOk]) {
        HydraLog(@"StreamManager: serverinfo FAILED — %@", serverInfoResp.statusMessage);
        [_callbacks launchFailed:serverInfoResp.statusMessage];
        return;
    }
    else if (pairStatus == NULL || appversion == NULL || serverState == NULL) {
        HydraLog(@"StreamManager: serverinfo missing fields — pairStatus=%@ appversion=%@ state=%@", pairStatus, appversion, serverState);
        [_callbacks launchFailed:@"Failed to connect to PC"];
        return;
    }

    if (![pairStatus isEqualToString:@"1"]) {
        HydraLog(@"StreamManager: not paired — pairStatus=%@", pairStatus);
        [_callbacks launchFailed:@"Device not paired to PC"];
        return;
    }

    // Only perform this check on GFE (as indicated by MJOLNIR in state value)
    if ((_config.width > 4096 || _config.height > 4096) && [serverState containsString:@"MJOLNIR"]) {
        NSString* codecSupport = [serverInfoResp getStringTag:@"ServerCodecModeSupport"];
        if (codecSupport == nil || !([codecSupport intValue] & 0x200)) {
            [_callbacks launchFailed:@"Your host PC's GPU doesn't support streaming video resolutions over 4K."];
            return;
        }
    }

    // Populate the config's version fields from serverinfo
    _config.appVersion = appversion;
    _config.gfeVersion = gfeVersion;

    // serverCodecModeSupport is required by LiStartConnection — it returns -1 immediately if 0.
    // The upstream UI flow sets this from the cached TemporaryHost after discovery; we must set it
    // here from the live serverinfo response since we bypass the host discovery state machine.
    NSString* codecSupportStr = [serverInfoResp getStringTag:@"ServerCodecModeSupport"];
    _config.serverCodecModeSupport = codecSupportStr ? [codecSupportStr intValue] : 0x1; // 0x1 = SCM_H264 fallback
    HydraLog(@"StreamManager: serverCodecModeSupport=%d (from serverinfo: %@)", _config.serverCodecModeSupport, codecSupportStr);

    if (_config.appName.length > 0) {
        HydraLog(@"StreamManager: making applist HTTPS...");
        AppListResponse *appListResp = [[AppListResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appListResp
            withUrlRequest:[hMan newAppListRequest]]];
        HydraLog(@"StreamManager: applist done — statusCode=%d", appListResp.statusCode);
        if ([appListResp isStatusOk]) {
            NSArray *apps = [appListResp getAppList];
            HydraLog(@"StreamManager: applist has %lu apps", (unsigned long)apps.count);
            for (TemporaryApp *app in apps) {
                if ([app.name isEqualToString:_config.appName]) {
                    _config.appID = app.id;
                    break;
                }
            }
        } else {
            HydraLog(@"StreamManager: applist FAILED — statusCode=%d", appListResp.statusCode);
        }
        HydraLog(@"StreamManager: resolved appID='%@' for app='%@'", _config.appID, _config.appName);
        Log(LOG_I, @"Launching appID '%@' for app '%@'", _config.appID, _config.appName);
    }

    NSString* sessionUrl;
    if ([serverState hasSuffix:@"_SERVER_BUSY"]) {
        HydraLog(@"StreamManager: server BUSY — resuming app appID=%@...", _config.appID);
        if (![self resumeApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    } else {
        HydraLog(@"StreamManager: server IDLE — launching app appID=%@...", _config.appID);
        if (![self launchApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    }

    _config.rtspSessionUrl = sessionUrl;
    HydraLog(@"StreamManager: launch/resume OK — sessionUrl=%@ — dispatching LiStartConnection to main queue", sessionUrl);

    dispatch_async(dispatch_get_main_queue(), ^{
        HydraLog(@"StreamManager: [main queue] creating VideoDecoderRenderer + Connection (VPN=%@)...",
                 [Utils isActiveNetworkVPN] ? @"YES" : @"NO");
        VideoDecoderRenderer* renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView callbacks:self->_callbacks streamAspectRatio:(float)self->_config.width / (float)self->_config.height useFramePacing:self->_config.useFramePacing];
        self->_connection = [[Connection alloc] initWithConfig:self->_config renderer:renderer connectionCallbacks:self->_callbacks];
        NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
        [opQueue addOperation:self->_connection];
        HydraLog(@"StreamManager: [main queue] Connection enqueued — LiStartConnection will run on bg thread");
    });
}

- (void) stopStream
{
    [_connection terminate];
}

- (BOOL) launchApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HydraLog(@"StreamManager: /launch HTTPS request starting (appID=%@, timeout=60s)...", _config.appID);
    HttpResponse* launchResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:launchResp withUrlRequest:[hMan newLaunchOrResumeRequest:@"launch" config:_config]]];
    NSString *gameSession = [launchResp getStringTag:@"gamesession"];
    HydraLog(@"StreamManager: /launch response — statusCode=%d gameSession=%@", launchResp.statusCode, gameSession);
    if (![launchResp isStatusOk]) {
        HydraLog(@"StreamManager: /launch FAILED — statusCode=%d message=%@", launchResp.statusCode, launchResp.statusMessage);
        [_callbacks launchFailed:launchResp.statusMessage];
        Log(LOG_E, @"Failed Launch Response: %@", launchResp.statusMessage);
        return FALSE;
    } else if (gameSession == NULL || [gameSession isEqualToString:@"0"]) {
        HydraLog(@"StreamManager: /launch FAILED — gameSession null or zero");
        [_callbacks launchFailed:@"Failed to launch app"];
        Log(LOG_E, @"Failed to parse game session");
        return FALSE;
    }
    *sessionUrl = [launchResp getStringTag:@"sessionUrl0"];
    HydraLog(@"StreamManager: /launch OK — gameSession=%@ sessionUrl=%@", gameSession, *sessionUrl);
    return TRUE;
}

- (BOOL) resumeApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HydraLog(@"StreamManager: /resume HTTPS request starting (appID=%@, timeout=60s)...", _config.appID);
    HttpResponse* resumeResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resumeResp withUrlRequest:[hMan newLaunchOrResumeRequest:@"resume" config:_config]]];
    NSString* resume = [resumeResp getStringTag:@"resume"];
    HydraLog(@"StreamManager: /resume response — statusCode=%d resume=%@", resumeResp.statusCode, resume);
    if (![resumeResp isStatusOk]) {
        HydraLog(@"StreamManager: /resume FAILED — statusCode=%d message=%@", resumeResp.statusCode, resumeResp.statusMessage);
        [_callbacks launchFailed:resumeResp.statusMessage];
        Log(LOG_E, @"Failed Resume Response: %@", resumeResp.statusMessage);
        return FALSE;
    } else if (resume == NULL || [resume isEqualToString:@"0"]) {
        HydraLog(@"StreamManager: /resume FAILED — resume null or zero");
        [_callbacks launchFailed:@"Failed to resume app"];
        Log(LOG_E, @"Failed to parse resume response");
        return FALSE;
    }
    *sessionUrl = [resumeResp getStringTag:@"sessionUrl0"];
    HydraLog(@"StreamManager: /resume OK — sessionUrl=%@", *sessionUrl);
    return TRUE;
}

- (NSString*) getStatsOverlayText {
    video_stats_t stats;
    
    if (!_connection) {
        return nil;
    }
    
    if (![_connection getVideoStats:&stats]) {
        return nil;
    }
    
    uint32_t rtt, variance;
    NSString* latencyString;
    if (LiGetEstimatedRttInfo(&rtt, &variance)) {
        latencyString = [NSString stringWithFormat:@"%u ms (variance: %u ms)", rtt, variance];
    }
    else {
        latencyString = @"N/A";
    }
    
    NSString* hostProcessingString;
    if (stats.framesWithHostProcessingLatency != 0) {
        hostProcessingString = [NSString stringWithFormat:@"\nHost processing latency min/max/avg: %.1f/%.1f/%.1f ms",
                                stats.minHostProcessingLatency / 10.f,
                                stats.maxHostProcessingLatency / 10.f,
                                (float)stats.totalHostProcessingLatency / stats.framesWithHostProcessingLatency / 10.f];
    }
    else {
        hostProcessingString = @"";
    }
    
    float interval = stats.endTime - stats.startTime;
    return [NSString stringWithFormat:@"Video stream: %dx%d %.2f FPS (Codec: %@)\nFrames dropped by your network connection: %.2f%%\nAverage network latency: %@%@",
            _config.width,
            _config.height,
            stats.totalFrames / interval,
            [_connection getActiveCodecName],
            stats.networkDroppedFrames / interval,
            latencyString,
            hostProcessingString];
}

- (NSDictionary *) streamStatsSnapshot {
    if (!_connection) {
        return nil;
    }

    video_stats_t stats;
    if (![_connection getVideoStats:&stats]) {
        return nil;
    }

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];

    uint32_t rtt, variance;
    if (LiGetEstimatedRttInfo(&rtt, &variance)) {
        snapshot[@"rttMs"] = @(rtt);
        snapshot[@"rttVarianceMs"] = @(variance);
    }

    float interval = stats.endTime - stats.startTime;
    if (interval > 0) {
        snapshot[@"fps"] = @(stats.totalFrames / interval);
        snapshot[@"networkDropPercent"] = @(stats.networkDroppedFrames / interval * 100.0f);
    }

    if (stats.framesWithHostProcessingLatency > 0) {
        snapshot[@"hostLatencyMinMs"] = @(stats.minHostProcessingLatency / 10.f);
        snapshot[@"hostLatencyMaxMs"] = @(stats.maxHostProcessingLatency / 10.f);
        snapshot[@"hostLatencyAvgMs"] = @((float)stats.totalHostProcessingLatency / stats.framesWithHostProcessingLatency / 10.f);
    }

    NSString *codec = [_connection getActiveCodecName];
    if (codec) {
        snapshot[@"codec"] = codec;
    }
    snapshot[@"width"]  = @(_config.width);
    snapshot[@"height"] = @(_config.height);

    snapshot[@"pendingAudioFrames"]     = @(LiGetPendingAudioFrames());
    snapshot[@"pendingAudioDurationMs"] = @(LiGetPendingAudioDuration());

    return [snapshot copy];
}

@end
