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
@property (nonatomic, copy) NSString *sunshineUsername;
@property (nonatomic, copy) NSString *sunshinePassword;
@property (nonatomic, copy) HydraPairCompletion completion;
@end

@implementation HydraPairSession

- (instancetype)initWithHost:(NSString *)host
          sunshineUsername:(NSString *)username
          sunshinePassword:(NSString *)password {
    self = [super init];
    if (self) {
        _host             = host;
        _sunshineUsername = username;
        _sunshinePassword = password;
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
    // Submit the PIN to Sunshine's web UI at https://<host>:47990/api/pin.
    //
    // Timing is critical: Sunshine only accepts the PIN from /api/pin when a
    // /pair?phrase=getservercert request is already pending. PairManager calls
    // startPairing: BEFORE it sends getservercert (it calls startPairing: first,
    // then /serverinfo, then getservercert). Blocking here means the PIN arrives
    // at Sunshine before any getservercert is in-flight — Sunshine ignores it and
    // the getservercert request then waits forever for a PIN that never comes.
    //
    // Fix: return immediately so PairManager's thread proceeds to send /serverinfo
    // and /pair?getservercert. After a short delay the PIN is submitted on a
    // background queue, arriving at Sunshine while getservercert is pending.
    // This mirrors hydraheadflatscreen's approach: launch Moonlight → wait 1-2s
    // for getservercert to reach Sunshine → then POST the PIN.
    NSString *urlStr = [NSString stringWithFormat:@"https://%@:47990/api/pin", self.host];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString *credentials = [NSString stringWithFormat:@"%@:%@",
                             self.sunshineUsername, self.sunshinePassword];
    NSData *credentialsData = [credentials dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64Credentials = [credentialsData base64EncodedStringWithOptions:0];
    [req setValue:[NSString stringWithFormat:@"Basic %@", base64Credentials]
        forHTTPHeaderField:@"Authorization"];

    NSString *body = [NSString stringWithFormat:@"{\"pin\":\"%@\"}", PIN];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableURLRequest *capturedReq = req;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        InsecurePinDelegate *delegate = [[InsecurePinDelegate alloc] init];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                              delegate:delegate
                                                         delegateQueue:nil];
        [[session dataTaskWithRequest:capturedReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[HydraPairSession] PIN submission error: %@", error);
            }
        }] resume];
    });
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
