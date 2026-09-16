#import "TatwoCEFBridge.h"
#import "TatwoBrowserStagingLoopback.h"

static NSString *const TatwoCEFErrorDomain = @"com.tatwo.ultrawork.cef";

@implementation TatwoCEFApplication

+ (void)load {
    @autoreleasepool {
        (void)TatwoBrowserStagingLoopbackRuntimePort();
    }
}

- (BOOL)isHandlingSendEvent {
    return _tatwoHandlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _tatwoHandlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    // Preserve the same nested-event semantics as CefScopedSendingEvent without
    // importing or linking CEF in the default build.
    BOOL previousValue = _tatwoHandlingSendEvent;
    _tatwoHandlingSendEvent = YES;
    @try {
        [super sendEvent:event];
    } @finally {
        _tatwoHandlingSendEvent = previousValue;
    }
}

@end

@implementation TatwoCEFBrowserView
#pragma mark - W57c Unavailable bridge never fills
- (void)fillCredentialUsername:(NSString *)u password:(NSString *)p formID:(NSString *)f navigationGeneration:(uint64_t)g {}
#pragma mark - W58
- (BOOL)prepareAgentLogin { return NO; }
- (void)cancelAgentLogin {}
- (NSDictionary *)agentLoginState { return @{@"phase": @"failed", @"error": @"ai_login_engine_unavailable"}; }
- (BOOL)fillCredentialForAgentUsername:(NSString *)u password:(NSString *)p formID:(NSString *)f navigationGeneration:(uint64_t)g { return NO; }
#pragma mark - W58 End
#pragma mark - W59
- (BOOL)fillOneTimeCodeForAgent:(NSString *)code navigationGeneration:(uint64_t)g { return NO; }
- (BOOL)prepareAgentPasswordChange { return NO; }
- (BOOL)fillAgentPasswordChangeCurrent:(NSString *)old newPassword:(NSString *)next navigationGeneration:(uint64_t)g { return NO; }
- (BOOL)submitAgentPasswordChange:(uint64_t)g { return NO; }
#pragma mark - W59 End
#pragma mark - W57c End
- (TatwoCEFBrowserActor)browserActor { return TatwoCEFBrowserActorAgent; }
- (BOOL)agentControlled { return YES; }
- (BOOL)humanPreferencesDeferred { return NO; }
- (void)beginAgentInteraction {}
- (BOOL)restoreHumanInteraction { return NO; }

- (nullable instancetype)initWithFrame:(NSRect)frame
                    persistentProfile:(nullable NSString *)persistentProfile
                            initialURL:(NSString *)initialURL
                                 error:(NSError * _Nullable * _Nullable)error {
  return [self initWithFrame:frame persistentProfile:persistentProfile initialURL:initialURL actor:TatwoCEFBrowserActorAgent error:error];
}

- (nullable instancetype)initWithFrame:(NSRect)frame
                    persistentProfile:(nullable NSString *)persistentProfile
                            initialURL:(NSString *)initialURL
                                 actor:(TatwoCEFBrowserActor)actor
                                 error:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:TatwoCEFErrorDomain
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         @"Chromium runtime unavailable"
                                 }];
    }
    return nil;
}

- (BOOL)canShareRequestContext {
    return NO;
}

- (BOOL)preventsAutomaticSleep { return NO; }
- (BOOL)currentDocumentIsPDF { return NO; }

- (nullable instancetype)initWithFrame:(NSRect)frame
                   sharingContextWith:(TatwoCEFBrowserView *)source
                           initialURL:(NSString *)initialURL
                                error:(NSError * _Nullable * _Nullable)error {
  return [self initWithFrame:frame sharingContextWith:source initialURL:initialURL actor:TatwoCEFBrowserActorAgent error:error];
}

- (nullable instancetype)initWithFrame:(NSRect)frame
                   sharingContextWith:(TatwoCEFBrowserView *)source
                           initialURL:(NSString *)initialURL
                                actor:(TatwoCEFBrowserActor)actor
                                 error:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:TatwoCEFErrorDomain
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         @"Chromium runtime unavailable"
                                 }];
    }
    return nil;
}

- (BOOL)canGoBack {
    return NO;
}

- (BOOL)canGoForward {
    return NO;
}

- (nullable NSString *)currentURLString {
    return nil;
}

- (uint64_t)navigationGeneration { return 0; }
- (void)captureVisibleSnapshotWithCompletion:(TatwoCEFBrowserSnapshotHandler)completion {
    completion(nil, @"snapshot_unavailable");
}
- (BOOL)sendClickAtPoint:(NSPoint)point navigationGeneration:(uint64_t)generation { return NO; }
- (void)clickElement:(NSString *)elementID atPoint:(NSPoint)point
       expectedRect:(NSRect)rect viewportSize:(NSSize)viewport
       navigationGeneration:(uint64_t)generation
       dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
       completion:(TatwoCEFBrowserInputHandler)completion {
    // No backend means no probe, gate invocation, or native input.
    completion(NO, @"browser_unavailable");
}
- (BOOL)sendScrollDeltaY:(int)deltaY navigationGeneration:(uint64_t)generation { return NO; }
- (BOOL)sendAgentPointer:(NSPoint)point phase:(int)phase navigationGeneration:(uint64_t)generation { return NO; }
- (void)releaseAgentPointer {}
- (BOOL)sendAgentKey:(unsigned short)code windowsCode:(int)windowsCode
         characters:(NSString *)characters unmodified:(NSString *)unmodified
          modifiers:(NSUInteger)modifiers phase:(int)phase navigationGeneration:(uint64_t)generation { return NO; }
- (void)releaseAgentKey {}
- (void)checkAgentFocusWithNavigationGeneration:(uint64_t)generation
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate completion:(TatwoCEFBrowserInputHandler)completion {
  completion(NO, @"browser_unavailable");
}
- (void)selectValue:(NSString *)value elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion {
  completion(NO, @"browser_unavailable");
}
- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    completion:(TatwoCEFBrowserInputHandler)completion {
    completion(NO, @"browser_unavailable");
}
- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion {
    // Unavailable is not authority to invoke the supplied dispatch gate.
    completion(NO, @"browser_unavailable");
}
- (void)loadURLString:(NSString *)urlString {}
- (void)loadURLString:(NSString *)urlString
        dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate {
    // No native backend exists; do not consume an agent's dispatch attempt.
}
#pragma mark - W57a
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase {}
- (void)stopFinding {}
- (double)zoomLevel { return 0; }
- (void)setZoomLevel:(double)level {}
- (void)stopLoading {}
- (void)performContextEdit:(NSString *)kind {}
- (void)downloadImageURL:(NSString *)url {}
- (BOOL)cancelDownloadIdentifier:(NSString *)identifier { return NO; }
- (BOOL)pauseDownloadIdentifier:(NSString *)identifier { return NO; }
- (BOOL)resumeDownloadIdentifier:(NSString *)identifier { return NO; }
- (BOOL)retryDownloadURL:(NSString *)url { return NO; }
- (BOOL)resetCurrentDownloadPermission { return NO; }
#pragma mark - W57a end
- (void)goBack {}
#pragma mark - W57d
- (void)cancelWebFeatures { if (self.onWebFeaturesInvalidated) self.onWebFeaturesInvalidated(); }
- (void)exitContentFullscreen {}
- (void)printPage {}
- (void)printToPDFWithCompletion:(void (^)(NSString * _Nullable))completion { completion(nil); }
- (void)downloadCurrentPDFWithCompletion:(void (^)(NSString * _Nullable))completion { completion(nil); }
#pragma mark - W57d End
- (void)goForward {}
- (void)reload {}
- (void)invokeWebMCPToolNamed:(NSString *)toolName
                argumentsJSON:(NSString *)argumentsJSON
         navigationGeneration:(uint64_t)navigationGeneration
                   completion:(TatwoCEFWebMCPInvocationHandler)completion {
    completion(nil, @"webmcp_runtime_unavailable");
}
- (void)closeBrowser {}
- (void)closeBrowserWithCompletion:
    (nullable TatwoCEFBrowserCloseHandler)completion {
    if (completion != nil) {
        completion();
    }
}

@end

@implementation TatwoCEFRuntime
#pragma mark - W60
+ (NSDictionary<NSString *, id> *)processDiagnostics { return @{}; }
+ (void)configureRendererProcessLimit:(NSInteger)limit {}
#pragma mark - W60 End

+ (BOOL)compiled {
    return NO;
}

+ (NSString *)engineIdentifier {
    return @"unavailable";
}

+ (NSString *)runtimeVersion {
    return @"unavailable";
}

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
               helperExecutablePath:(NSString *)helperExecutablePath
                        logFilePath:(NSString *)logFilePath
               bundledDenyListPath:(NSString *)bundledDenyListPath
                              error:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:TatwoCEFErrorDomain
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         @"Chromium runtime unavailable"
                                 }];
    }
    return NO;
}

+ (BOOL)supportsOriginScopedSiteDataClearing {
    return NO;
}

+ (BOOL)supportsOriginScopedHTTPResponseCacheClearing {
    return NO;
}

+ (BOOL)supportsChromiumWebMCP {
    return NO;
}

+ (void)clearDataForOrigin:(NSString *)origin
         persistentProfile:(NSString *)persistentProfile
                completion:(TatwoCEFOriginDataClearHandler)completion {
    completion(NO, NO, YES, [NSError errorWithDomain:TatwoCEFErrorDomain
                                                code:1
                                            userInfo:@{
                                                NSLocalizedDescriptionKey:
                                                    @"Chromium runtime unavailable"
                                            }]);
}

+ (void)captureActiveVisibleSnapshotWithCompletion:
    (TatwoCEFBrowserSnapshotHandler)completion {
    completion(nil, @"snapshot_unavailable");
}

+ (void)shutdown {}

@end

int TatwoCEFExecuteSubprocess(void) {
    return -1;
}

BOOL TatwoCEFURLPolicyAllowsURLString(NSString *urlString) {
    @try {
        return TatwoBrowserStagingLoopbackAllows(
            [NSURLComponents componentsWithString:urlString],
            TatwoBrowserStagingLoopbackRuntimePort());
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL TatwoCEFResolvedURLPolicyAllowsURLString(NSString *urlString) {
    // No DNS exception: the only allowed endpoint is already a numeric literal.
    return TatwoCEFURLPolicyAllowsURLString(urlString);
}

NSString *TatwoCEFOriginForURLString(NSString *urlString) {
    return nil;
}

BOOL TatwoCEFHostSwitchIsDenied(NSString *switchName) {
    return NO;
}
