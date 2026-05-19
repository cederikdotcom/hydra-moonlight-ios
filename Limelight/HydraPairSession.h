//
//  HydraPairSession.h
//  hydra-moonlight-ios
//
//  Wraps PairManager to expose a simple pairing API to HydraHeadiPad Swift code.
//  Handles the GameStream crypto handshake on port 47989/47984 and submits the
//  PIN directly to Sunshine's web UI at https://<host>:47990/api/pin using
//  HTTP Basic auth (Sunshine credentials) and a custom delegate that accepts
//  the self-signed certificate.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^HydraPairCompletion)(NSData * _Nullable serverCert, NSError * _Nullable error);

@interface HydraPairSession : NSObject

/// Pair with the Sunshine server at the given host IP.
/// host              — IP or hostname of the Sunshine body (e.g. "10.10.0.5")
/// sunshineUsername  — Sunshine web UI username (e.g. "sunshine")
/// sunshinePassword  — Sunshine web UI password
/// completion is called on the main queue with the DER server cert on success,
/// or nil + error on failure. alreadyPaired resolves as success with nil cert.
- (instancetype)initWithHost:(NSString *)host
          sunshineUsername:(NSString *)username
          sunshinePassword:(NSString *)password;

- (void)pairWithCompletion:(HydraPairCompletion)completion;

@end

NS_ASSUME_NONNULL_END
