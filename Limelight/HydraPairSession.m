//
//  HydraPairSession.m
//  hydra-moonlight-ios
//

#import "HydraPairSession.h"
#import "PairManager.h"
#import "HttpManager.h"
#import "CryptoManager.h"

@interface HydraPairSession () <PairCallback>
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *sunshineUsername;
@property (nonatomic, copy) NSString *sunshinePassword;
@property (nonatomic, copy) HydraPairCompletion completion;
@end

@implementation HydraPairSession

- (instancetype)initWithHost:(NSString *)host
           sunshineUsername:(NSString *)sunshineUsername
           sunshinePassword:(NSString *)sunshinePassword {
    self = [super init];
    if (self) {
        _host = host;
        _sunshineUsername = sunshineUsername;
        _sunshinePassword = sunshinePassword;
    }
    return self;
}

- (void)pairWithCompletion:(HydraPairCompletion)completion {
    self.completion = completion;

    // Ensure a client key+cert exists (no-op if already generated).
    [CryptoManager generateKeyPairUsingSSL];

    NSData *clientCert = [CryptoManager readCertFromFile];

    // GameStream HTTP pairing runs on port 47989.
    NSString *hostPortString = [NSString stringWithFormat:@"%@:47989", self.host];
    HttpManager *httpManager = [[HttpManager alloc] initWithAddress:hostPortString
                                                          httpsPort:47990
                                                         serverCert:nil];

    PairManager *pairManager = [[PairManager alloc] initWithManager:httpManager
                                                         clientCert:clientCert
                                                           callback:self];

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:pairManager];
}

// MARK: - PairCallback

- (void)startPairing:(NSString *)PIN {
    // Submit the PIN to Sunshine's HTTPS management API with Basic Auth.
    // This runs on PairManager's background thread — use a semaphore to block
    // until the submission completes so PairManager can continue the handshake.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:47990/api/pin", self.host]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString *credentials = [[NSString stringWithFormat:@"%@:%@", self.sunshineUsername, self.sunshinePassword]
                              dataUsingEncoding:NSUTF8StringEncoding].base64EncodedString;
    [req setValue:[NSString stringWithFormat:@"Basic %@", credentials] forHTTPHeaderField:@"Authorization"];

    NSString *body = [NSString stringWithFormat:@"{\"pin\":\"%@\"}", PIN];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    // Bypass Sunshine's self-signed cert for the PIN submission.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    InsecurePinDelegate *delegate = [[InsecurePinDelegate alloc] init];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                         delegate:delegate
                                                    delegateQueue:nil];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
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
@interface InsecurePinDelegate : NSObject <NSURLSessionDelegate>
@end

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
