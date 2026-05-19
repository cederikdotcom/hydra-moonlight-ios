//
//  DataManager.m
//  hydra-moonlight-ios
//
// Replacement for the upstream Moonlight DataManager which used Core Data via
// AppDelegate.managedObjectContext. HydraHeadiPad uses a SwiftUI @main App,
// not an AppDelegate subclass, so Core Data is unavailable. Since we never
// show Moonlight's host/app browser UI, we only need:
//   - getSettings: returns hardcoded defaults; StreamFrameViewController reads
//     absoluteTouchMode, statsOverlay, and framerate from this.
//   - getUniqueId / updateUniqueId: persists the Moonlight client UUID in
//     NSUserDefaults so it survives across launches (Sunshine tracks this for
//     pairing).
// All host/app persistence methods are no-ops.

#import "DataManager.h"
#import "TemporarySettings.h"
#import "OnScreenControls.h"

static NSString * const kUniqueIdKey = @"HydraLimelightUniqueId";

@implementation DataManager

- (id)init {
    return [super init];
}

- (TemporarySettings *)getSettings {
    TemporarySettings *settings = [[TemporarySettings alloc] init];
    // These values are overridden by StreamConfiguration anyway.
    // StreamFrameViewController reads absoluteTouchMode, statsOverlay, framerate.
    settings.bitrate        = @(15000);
    settings.framerate      = @(60);
    settings.height         = @(1080);
    settings.width          = @(1920);
    settings.audioConfig    = @(1);   // stereo
    settings.preferredCodec = CODEC_PREF_AUTO;
    settings.useFramePacing = YES;
    settings.playAudioOnPC  = NO;
    settings.enableHdr      = NO;
    settings.optimizeGames  = NO;
    settings.multiController    = NO;
    settings.swapABXYButtons    = NO;
    settings.onscreenControls   = @(OnScreenControlsLevelOff);
    settings.btMouseSupport     = NO;
    settings.absoluteTouchMode  = NO;
    settings.statsOverlay       = NO;
    settings.uniqueId           = [self getUniqueId];
    return settings;
}

- (NSString *)getUniqueId {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kUniqueIdKey];
}

- (void)updateUniqueId:(NSString *)uniqueId {
    [[NSUserDefaults standardUserDefaults] setObject:uniqueId forKey:kUniqueIdKey];
}

// Host/app persistence — not used in Hydra kiosk mode.
- (void)saveSettingsWithBitrate:(NSInteger)bitrate framerate:(NSInteger)framerate
                         height:(NSInteger)height width:(NSInteger)width
                    audioConfig:(NSInteger)audioConfig onscreenControls:(NSInteger)onscreenControls
                  optimizeGames:(BOOL)optimizeGames multiController:(BOOL)multiController
                swapABXYButtons:(BOOL)swapABXYButtons audioOnPC:(BOOL)audioOnPC
                 preferredCodec:(uint32_t)preferredCodec useFramePacing:(BOOL)useFramePacing
                      enableHdr:(BOOL)enableHdr btMouseSupport:(BOOL)btMouseSupport
              absoluteTouchMode:(BOOL)absoluteTouchMode statsOverlay:(BOOL)statsOverlay {}
- (NSArray *)getHosts                                         { return @[]; }
- (void)updateHost:(TemporaryHost *)host                      {}
- (void)updateAppsForExistingHost:(TemporaryHost *)host       {}
- (void)removeHost:(TemporaryHost *)host                      {}
- (void)removeApp:(TemporaryApp *)app                         {}

@end
