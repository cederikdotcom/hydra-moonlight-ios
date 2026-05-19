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
    // Submit the PIN directly to Sunshine's web UI at https://<host>:47990/api/pin.
    // Port 47990 is network-accessible (not localhost-only) once the iPad is on
    // WireGuard, so we can POST directly with HTTP Basic auth and accept the
    // self-signed cert via InsecurePinDelegate.
    // This runs on PairManager's background thread — use a semaphore to block
    // until the submission completes so PairManager can continue the handshake.
    NSString *urlStr = [NSString stringWithFormat:@"https://%@:47990/api/pin", self.host];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // HTTP Basic auth: base64(username:password)
    NSString *credentials = [NSString stringWithFormat:@"%@:%@",
                             self.sunshineUsername, self.sunshinePassword];
    NSData *credentialsData = [credentials dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64Credentials = [credentialsData base64EncodedStringWithOptions:0];
    [req setValue:[NSString stringWithFormat:@"Basic %@", base64Credentials]
        forHTTPHeaderField:@"Authorization"];

    NSString *body = [NSString stringWithFormat:@"{\"pin\":\"%@\"}", PIN];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    InsecurePinDelegate *delegate = [[InsecurePinDelegate alloc] init];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                          delegate:delegate
                                                     delegateQueue:nil];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
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
