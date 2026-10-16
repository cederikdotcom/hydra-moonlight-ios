//
//  HydraPairSession.m
//  hydra-moonlight-ios
//

#import "HydraPairSession.h"
#import "PairManager.h"
#import "HttpManager.h"
#import "CryptoManager.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>

// Forward declaration so InsecurePinDelegate can be used inside -startPairing:
@interface InsecurePinDelegate : NSObject <NSURLSessionDelegate>
@end

// Defined below -startPairing:, which calls it.
static NSDictionary *HydraResolvePendingPairing(NSURLSession *session,
                                                NSString *host,
                                                NSString *authorization);

/// The local source address this head uses to reach `host`.
///
/// Connecting a datagram socket sends nothing on the wire; it only asks the
/// kernel to pick a route and bind a source address, which is exactly the
/// value Sunshine recorded for our in-flight handshake. Returns nil when the
/// route cannot be resolved, in which case the caller must not identify its
/// own pending pairing by address.
static NSString *HydraLocalAddressTo(NSString *host) {
    if (host.length == 0) {
        return nil;
    }
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;

    struct addrinfo *result = NULL;
    if (getaddrinfo(host.UTF8String, "47990", &hints, &result) != 0 || result == NULL) {
        return nil;
    }

    NSString *local = nil;
    int fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (fd >= 0) {
        if (connect(fd, result->ai_addr, result->ai_addrlen) == 0) {
            struct sockaddr_storage addr = {0};
            socklen_t len = sizeof(addr);
            if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0) {
                char buf[INET6_ADDRSTRLEN] = {0};
                if (addr.ss_family == AF_INET) {
                    struct sockaddr_in *v4 = (struct sockaddr_in *)&addr;
                    if (inet_ntop(AF_INET, &v4->sin_addr, buf, sizeof(buf))) {
                        local = [NSString stringWithUTF8String:buf];
                    }
                } else if (addr.ss_family == AF_INET6) {
                    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&addr;
                    if (inet_ntop(AF_INET6, &v6->sin6_addr, buf, sizeof(buf))) {
                        local = [NSString stringWithUTF8String:buf];
                    }
                }
            }
        }
        close(fd);
    }
    freeaddrinfo(result);
    return local;
}

/// Pick this head's pending pairing out of the list Sunshine reports.
///
/// Filtering is by source address when the body reports one, never by name:
/// every Moonlight derived head sends the same hardcoded devicename `roth`,
/// so a name match would pick an arbitrary head's session. More than one
/// candidate returns nil rather than choosing, because posting our PIN
/// against another client's pairing id pairs the wrong device, and the
/// symptom is a phase 4 rejection indistinguishable from an unrelated bug.
static NSDictionary *HydraSelectPendingPairing(NSArray *pairings, NSString *localAddress) {
    if (pairings.count == 0) {
        return nil;
    }
    NSMutableArray *candidates = [NSMutableArray array];
    BOOL anyAddress = NO;
    for (id entry in pairings) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *identifier = entry[@"id"];
        if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
            continue;  // No usable id: skip rather than guess.
        }
        if ([entry[@"address"] isKindOfClass:[NSString class]]) {
            anyAddress = YES;
        }
        [candidates addObject:entry];
    }
    if (localAddress.length > 0 && anyAddress) {
        NSMutableArray *matched = [NSMutableArray array];
        for (NSDictionary *entry in candidates) {
            if ([entry[@"address"] isEqual:localAddress]) {
                [matched addObject:entry];
            }
        }
        candidates = matched;
    }
    if (candidates.count == 1) {
        return candidates.firstObject;
    }
    if (candidates.count > 1) {
        NSLog(@"[HydraPairSession] refusing to guess among %lu pending pairings",
              (unsigned long)candidates.count);
    }
    return nil;
}

@interface HydraPairSession () <PairCallback>
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *sunshineUsername;
@property (nonatomic, copy) NSString *sunshinePassword;
@property (nonatomic, copy) HydraPairCompletion completion;
@property (nonatomic, assign) BOOL hasAttemptedUnpair;
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

    NSMutableURLRequest *capturedReq = req;
    NSString *capturedHost = self.host;
    NSString *capturedAuth = [NSString stringWithFormat:@"Basic %@", base64Credentials];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        InsecurePinDelegate *delegate = [[InsecurePinDelegate alloc] init];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                              delegate:delegate
                                                         delegateQueue:nil];

        // Two generations of Sunshine want different bodies, and the fleet
        // runs both. 2025.924 and earlier accept {"pin": ...}. 2026.914
        // requires a server minted 32 hex character pairing_id plus a name,
        // and rejects the bare form with HTTP 400 "pairing_id must contain
        // exactly 32 hexadecimal characters". Every cloud body runs 2026.914,
        // so without the id this head cannot pair with the hyperscaler at all.
        //
        // The id is not the uniqueid. The server mints it during getservercert
        // and never returns it to the GameStream client, so the authenticated
        // web API is the only way to learn it. The 0.3 s delay above has just
        // guaranteed getservercert is pending, which is when the entry appears.
        NSDictionary *pending = HydraResolvePendingPairing(session, capturedHost, capturedAuth);

        NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:PIN forKey:@"pin"];
        if (pending != nil) {
            payload[@"pairing_id"] = pending[@"id"];
            // Echo back the name the server itself recorded rather than
            // guessing one. 2026.914 does not validate it against the pending
            // entry, but guessing a value the server never recorded would be a
            // worse default for builds that do.
            if ([pending[@"name"] isKindOfClass:[NSString class]]) {
                payload[@"name"] = pending[@"name"];
            }
            NSLog(@"[HydraPairSession] pairing id minted by %@, posting the extended PIN body", capturedHost);
        }

        NSError *encodeError = nil;
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&encodeError];
        if (bodyData == nil) {
            NSLog(@"[HydraPairSession] could not encode the PIN body: %@", encodeError);
            return;
        }
        capturedReq.HTTPBody = bodyData;

        [[session dataTaskWithRequest:capturedReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[HydraPairSession] PIN submission error: %@", error);
                return;
            }
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code < 200 || code > 299) {
                // Newer Sunshine explains the refusal in the body, and that
                // sentence is the difference between a one-line fix and a day
                // of guessing. Log it rather than just the status code.
                NSString *text = data.length > 0
                    ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                    : @"";
                NSLog(@"[HydraPairSession] PIN submission failed (HTTP %ld): %@", (long)code, text);
            }
        }] resume];
    });
}

/// This head's pending pairing from GET /api/pin, or nil when the body does
/// not mint one.
///
/// Any refusal reads as "this body has no pending-pairing concept" and the
/// caller falls back to the legacy bare-pin body, rather than failing a pair
/// that never needed an id. The status is logged so a real server fault stays
/// visible instead of being silently absorbed.
static NSDictionary *HydraResolvePendingPairing(NSURLSession *session,
                                                NSString *host,
                                                NSString *authorization) {
    NSString *urlStr = [NSString stringWithFormat:@"https://%@:47990/api/pin", host];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 20;
    [req setValue:authorization forHTTPHeaderField:@"Authorization"];

    __block NSDictionary *selected = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error != nil) {
            NSLog(@"[HydraPairSession] pending pairings unavailable on %@: %@, using the legacy PIN post",
                  host, error.localizedDescription);
            dispatch_semaphore_signal(done);
            return;
        }
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (code < 200 || code > 299) {
            NSLog(@"[HydraPairSession] pending pairings unavailable on %@: HTTP %ld, using the legacy PIN post",
                  host, (long)code);
            dispatch_semaphore_signal(done);
            return;
        }
        // The envelope {"pairings":[{"address","id","name"}]} is wire verified
        // against a 2026.914 body. Every field is still read defensively: one
        // verified build is not every build, and a response shaped unlike this
        // must read as "no pending pairings" rather than fail the pair.
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            id pairings = ((NSDictionary *)parsed)[@"pairings"];
            if ([pairings isKindOfClass:[NSArray class]]) {
                selected = HydraSelectPendingPairing(pairings, HydraLocalAddressTo(host));
            }
        }
        dispatch_semaphore_signal(done);
    }] resume];

    // Bounded wait: this already runs on a background queue, and a body that
    // cannot answer within the request timeout gets the legacy payload.
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(21 * NSEC_PER_SEC)));
    return selected;
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
    // alreadyPaired returns no server cert. In the normal flow the caller has a
    // cached cert from a prior pair, so returning empty Data is fine. But if no
    // cached cert exists (e.g. after resetEnrollment with same client key still on
    // disk), we must unpair first so the next pair attempt goes through the full
    // handshake and returns the server cert.
    if (self.hasAttemptedUnpair) {
        // Guard: unpair already tried — return empty cert and let caller handle it.
        HydraPairCompletion completion = self.completion;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSData data], nil);
        });
        return;
    }
    self.hasAttemptedUnpair = YES;

    // Must use the same uniqueId as HttpManager (hardcoded throughout the Moonlight library).
    // HydraHeadiPad never calls IdManager.getUniqueId, so the UserDefaults key is never set;
    // reading it would produce an empty string and Sunshine would ignore the unpair request.
    NSString *uniqueId = @"0123456789ABCDEF";
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:47989/unpair?uniqueid=%@", self.host, uniqueId];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLSession *session = [NSURLSession sharedSession];
    HydraPairSession *strongSelf = self;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Re-pair regardless of whether unpair succeeded — worst case we get alreadyPaired
        // again and the guard above returns empty Data.
        [strongSelf pairWithCompletion:strongSelf.completion];
    }] resume];
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
