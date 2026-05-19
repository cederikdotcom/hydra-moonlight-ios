//
//  HydraPairSession.h
//  hydra-moonlight-ios
//
//  Wraps PairManager to expose a simple pairing API to HydraHeadiPad Swift code.
//  Handles the GameStream crypto handshake on port 47989 and submits the PIN
//  to Sunshine's management API on port 47990 with Basic Auth credentials.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^HydraPairCompletion)(NSData * _Nullable serverCert, NSError * _Nullable error);

@interface HydraPairSession : NSObject

/// Pair with the Sunshine server at the given host IP.
/// sunshineUsername / sunshinePassword are the Sunshine web-UI credentials
/// used to submit the PIN via Basic Auth to /api/pin on port 47990.
/// completion is called on the main queue with the DER server cert on success,
/// or nil + error on failure. alreadyPaired resolves as success with nil cert.
- (instancetype)initWithHost:(NSString *)host
           sunshineUsername:(NSString *)sunshineUsername
           sunshinePassword:(NSString *)sunshinePassword;

- (void)pairWithCompletion:(HydraPairCompletion)completion;

@end

NS_ASSUME_NONNULL_END
