//
//  HydraPairSession.h
//  hydra-moonlight-ios
//
//  Wraps PairManager to expose a simple pairing API to HydraHeadiPad Swift code.
//  Handles the GameStream crypto handshake on port 47989/47984 and submits the
//  PIN via HydraCluster's /api/v1/nodes/{bodyID}/sunshine-pin proxy endpoint,
//  since Sunshine's web UI (port 47990) only accepts localhost connections.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^HydraPairCompletion)(NSData * _Nullable serverCert, NSError * _Nullable error);

@interface HydraPairSession : NSObject

/// Pair with the Sunshine server at the given host IP.
/// clusterURL   — base URL of HydraCluster (e.g. "https://hydracluster.experiencenet.com")
/// bodyNodeID   — the body's HydraCluster node ID (e.g. "node-4c2be4b0"), used to
///                route the PIN through the cluster's sunshine-pin proxy endpoint.
/// headToken    — the head's bearer token for authenticating to HydraCluster.
/// completion is called on the main queue with the DER server cert on success,
/// or nil + error on failure. alreadyPaired resolves as success with nil cert.
- (instancetype)initWithHost:(NSString *)host
                  clusterURL:(NSString *)clusterURL
                  bodyNodeID:(NSString *)bodyNodeID
                   headToken:(NSString *)headToken;

- (void)pairWithCompletion:(HydraPairCompletion)completion;

@end

NS_ASSUME_NONNULL_END
