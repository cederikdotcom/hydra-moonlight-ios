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

/// Sunshine's `port` setting on the body, which every other port is derived
/// from: HTTP is portBase, the web API is portBase+1, GameStream HTTPS is
/// portBase-5.
///
/// A body that serves several heads at once runs one Sunshine instance per
/// slot, each on its own family, so a head that assumes the stock 47989 can
/// only ever reach slot 0. Defaults to 47989, so a head told nothing behaves
/// exactly as it always has.
@property (nonatomic, assign) int portBase;

- (void)pairWithCompletion:(HydraPairCompletion)completion;

@end

NS_ASSUME_NONNULL_END
