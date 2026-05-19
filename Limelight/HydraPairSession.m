//
//  HydraPairSession.m
//  hydra-moonlight-ios
//

#import "HydraPairSession.h"
#import "PairManager.h"
#import "HttpManager.h"
#import "CryptoManager.h"

// Forward declaration so InsecurePinDelegate can be used inside -startPairing:
@interface InsecurePinDelegate : NSObject <NSURLSessionDelegate>
@end

@interface HydraPairSession () <PairCallback>
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *clusterURL;
@property (nonatomic, copy) NSString *bodyNodeID;
@property (nonatomic, copy) NSString *headToken;
@property (nonatomic, copy) HydraPairCompletion completion;
@end

@implementation HydraPairSession

- (instancetype)initWithHost:(NSString *)host
                  clusterURL:(NSString *)clusterURL
                  bodyNodeID:(NSString *)bodyNodeID
                   headToken:(NSString *)headToken {
    self = [super init];
    if (self) {
        _host = host;
        _clusterURL = clusterURL;
        _bodyNodeID = bodyNodeID;
        _headToken  = headToken;
    }
    return self;
}

- (void)pairWithCompletion:(HydraPairCompletion)completion {
    self.completion = completion;

    // Ensure a client key+cert exists (no-op if already generated).
    [CryptoManager generateKeyPairUsingSSL];

    NSData *clientCert = [CryptoManager readCertFromFile];

    // GameStream HTTP pairing runs on port 47989.
    // httpsPort:0 lets HttpManager auto-discover the HTTPS port (47984) from
    // the HTTP /serverinfo response. Passing 47990 (Sunshine's web UI port)
    // was wrong — PairManager couldn't get the server cert and never sent /pair.
    NSString *hostPortString = [NSString stringWithFormat:@"%@:47989", self.host];
    HttpManager *httpManager = [[HttpManager alloc] initWithAddress:hostPortString
                                                          httpsPort:0
                                                         serverCert:nil];

    PairManager *pairManager = [[PairManager alloc] initWithManager:httpManager
                                                         clientCert:clientCert
                                                           callback:self];

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:pairManager];
}

// MARK: - PairCallback

- (void)startPairing:(NSString *)PIN {
    // Submit the PIN via HydraCluster's sunshine-pin proxy endpoint.
    // Sunshine's web UI (port 47990) is localhost-only, so iOS clients cannot
    // reach it directly. HydraCluster execs the submission on the body machine
    // where localhost:47990 is always reachable.
    // This runs on PairManager's background thread — use a semaphore to block
    // until the submission completes so PairManager can continue the handshake.
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/v1/nodes/%@/sunshine-pin",
                        self.clusterURL, self.bodyNodeID];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.headToken]
        forHTTPHeaderField:@"Authorization"];

    NSString *body = [NSString stringWithFormat:@"{\"pin\":\"%@\"}", PIN];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
}

- (void)pairSuccessful:(NSData *)serverCert {
    HydraPairCompletion completion = self.completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(serverCert, nil);
    });
}

- (void)pairFailed:(NSString *)message {
    HydraPairCompletion completion = self.completion;
    NSError *error = [NSError errorWithDomain:@"HydraPairSession"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, error);
    });
}

- (void)alreadyPaired {
    // Already paired — treat as success with no cert (caller uses cached cert).
    HydraPairCompletion completion = self.completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion([NSData data], nil);
    });
}

@end

// Accepts Sunshine's self-signed certificate for the PIN submission request.
@implementation InsecurePinDelegate
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end
