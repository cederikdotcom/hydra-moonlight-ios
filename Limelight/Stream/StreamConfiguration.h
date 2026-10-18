//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface StreamConfiguration : NSObject

@property NSString* host;
@property unsigned short httpsPort;
@property NSString* appVersion;
@property NSString* gfeVersion;
@property NSString* appID;
@property NSString* appName;
@property NSString* rtspSessionUrl;
@property int serverCodecModeSupport;
@property int width;
@property int height;
@property int frameRate;
@property int bitRate;
@property int riKeyId;
@property NSData* riKey;
@property int gamepadMask;
@property BOOL optimizeGameSettings;
@property BOOL playAudioOnPC;
@property BOOL swapABXYButtons;
@property int audioConfiguration;
@property int supportedVideoFormats;
@property BOOL multiController;
@property BOOL useFramePacing;
@property NSData* serverCert;

// Video packet payload size, or 0 to let Connection.m choose.
//
// Set this when the body is reached THROUGH A TUNNEL. Moonlight picks 1392
// unless it detects a local VPN, but 1392 plus Sunshine's RTP and NV headers
// makes a datagram of roughly 1440 bytes, which does not fit a 1420-byte
// WireGuard MTU. Every video packet is then split into exactly two IP
// fragments, and losing either half loses the whole packet. Measured on
// cosmic: 2.000 fragments per datagram, and the client requesting a keyframe
// 21 times in 30 seconds.
//
// A tunnel provided by the venue router is invisible to isActiveNetworkVPN,
// so the head has to say so itself.
@property int packetSizeOverride;

@end
