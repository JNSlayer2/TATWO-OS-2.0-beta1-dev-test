#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TatwoCEFBrowserPhase) {
    TatwoCEFBrowserPhaseBlank = 0,
    TatwoCEFBrowserPhaseCreating = 1,
    TatwoCEFBrowserPhaseLoading = 2,
    TatwoCEFBrowserPhaseCommitted = 3,
    TatwoCEFBrowserPhaseFinished = 4,
    TatwoCEFBrowserPhaseBlockedBySecurity = 5,
    TatwoCEFBrowserPhaseNavigationFailed = 6,
    TatwoCEFBrowserPhaseRendererFailed = 7,
    TatwoCEFBrowserPhaseStartupFailed = 8,
    TatwoCEFBrowserPhaseClosed = 9,
};

typedef NS_ENUM(NSInteger, TatwoCEFBrowserErrorKind) {
    TatwoCEFBrowserErrorKindNone = 0,
    TatwoCEFBrowserErrorKindSecurity = 1,
    TatwoCEFBrowserErrorKindNavigation = 2,
    TatwoCEFBrowserErrorKindRenderer = 3,
    TatwoCEFBrowserErrorKindStartup = 4,
};

typedef void (^TatwoCEFBrowserStateHandler)(
    NSString * _Nullable committedMainFrameURLString,
    uint64_t navigationGeneration,
    BOOL canGoBack,
    BOOL canGoForward,
    BOOL isLoading,
    TatwoCEFBrowserPhase phase,
    NSInteger httpStatusCode,
    TatwoCEFBrowserErrorKind errorKind,
    NSInteger errorCode,
    NSString * _Nullable visibleError);
typedef void (^TatwoCEFBrowserCloseHandler)(void);
typedef void (^TatwoCEFOriginDataClearHandler)(
    BOOL cookiesCleared,
    BOOL originStorageCleared,
    BOOL httpResponseCacheUnsupported,
    NSError * _Nullable error);
typedef void (^TatwoCEFBrowserSnapshotHandler)(
    NSString * _Nullable sanitizedSnapshotJSONString,
    NSString * _Nullable errorCode);
typedef void (^TatwoCEFBrowserInputHandler)(BOOL completed, NSString * _Nullable errorCode);
/// Revalidates the originating request and orders one synchronous enqueue with
/// local Stop. Invoke dispatch inline at most once; return NO when revoked.
/// The bridge also rejects retained/late or duplicate invocations of dispatch.
typedef BOOL (^TatwoCEFBrowserInputDispatchGate)(dispatch_block_t dispatch);
typedef void (^TatwoCEFWebMCPToolsHandler)(
    NSString * webMCPToolsSnapshotJSONString);
typedef void (^TatwoCEFWebMCPInvocationHandler)(
    NSString * _Nullable resultJSONString,
    NSString * _Nullable errorCode);

typedef NS_ENUM(NSInteger, TatwoCEFOriginDataClearErrorCode) {
    TatwoCEFOriginDataClearErrorRuntimeUnavailable = 30,
    TatwoCEFOriginDataClearErrorInvalidOrigin = 31,
    TatwoCEFOriginDataClearErrorInvalidPersistentProfile = 32,
    TatwoCEFOriginDataClearErrorCookieManagerUnavailable = 33,
    TatwoCEFOriginDataClearErrorCookieVisitRejected = 34,
    TatwoCEFOriginDataClearErrorMaintenanceBrowserCreationFailed = 35,
    TatwoCEFOriginDataClearErrorStorageCommandRejected = 36,
    TatwoCEFOriginDataClearErrorStorageCommandFailed = 37,
    TatwoCEFOriginDataClearErrorTimedOut = 38,
};

/// Application host used by Tatwo bundles.
///
/// The real CEF bridge declares conformance to CEF's required macOS
/// `CefAppProtocol`. The unavailable bridge keeps the same Objective-C class
/// available so non-CEF bundles remain launchable with the shared
/// `NSPrincipalClass` value.
@interface TatwoCEFApplication : NSApplication {
@private
    BOOL _tatwoHandlingSendEvent;
}

- (BOOL)isHandlingSendEvent;
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;

@end

/// Thin AppKit surface backed by the Chromium Embedded Framework.
///
/// This type is implemented by the real CEF bridge only when the package is
/// built with a verified TATWO_CEF_ROOT and TATWO_CEF_WRAPPER_LIBRARY. The
/// default build contains a fail-closed unavailable implementation instead.
@interface TatwoCEFBrowserView : NSView {
@package
    void *_cefState;
}

@property(nonatomic, copy, nullable) TatwoCEFBrowserStateHandler stateHandler;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, copy, readonly, nullable) NSString *currentURLString;
@property(nonatomic, readonly) uint64_t navigationGeneration;
@property(nonatomic, copy, nullable)
    TatwoCEFWebMCPToolsHandler webMCPToolsHandler;

- (nullable instancetype)initWithFrame:(NSRect)frame
                    persistentProfile:(nullable NSString *)persistentProfile
                            initialURL:(NSString *)initialURL
                                 error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

/// A normal tab with its own browser/history, using the already secured context.
@property(nonatomic, readonly) BOOL canShareRequestContext;
- (nullable instancetype)initWithFrame:(NSRect)frame
                   sharingContextWith:(TatwoCEFBrowserView *)source
                           initialURL:(NSString *)initialURL
                                error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)loadURLString:(NSString *)urlString;
/// Agent navigation: retains the URL/gate pair through asynchronous startup.
/// Invoke without an outer input lock; the gate guards the actual native send.
- (void)loadURLString:(NSString *)urlString
        dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate;
/// Captures this view, never whichever page most recently committed globally.
- (void)captureVisibleSnapshotWithCompletion:(TatwoCEFBrowserSnapshotHandler)completion;
/// Integral CEF view coordinates use the viewport's top-left origin.
/// Rejects fractional/out-of-int-range points and stale/closed pages.
- (BOOL)sendClickAtPoint:(NSPoint)point navigationGeneration:(uint64_t)generation
    NS_SWIFT_NAME(sendClick(at:navigationGeneration:));
/// Agent click: re-resolves the observed element and hit in an isolated world,
/// then gates real native down/up. No outer input lock or missing-gate fallback.
/// Refuses currently unverified page/pinch-zoom coordinate mappings.
- (void)clickElement:(NSString *)elementID atPoint:(NSPoint)point
       expectedRect:(NSRect)rect viewportSize:(NSSize)viewport
       navigationGeneration:(uint64_t)generation
       dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
       completion:(TatwoCEFBrowserInputHandler)completion
    NS_SWIFT_NAME(clickElement(_:at:expectedRect:viewportSize:navigationGeneration:dispatchGate:completion:));
- (BOOL)sendScrollDeltaY:(int)deltaY navigationGeneration:(uint64_t)generation
    NS_SWIFT_NAME(sendScrollDeltaY(_:navigationGeneration:));
/// One native stage per host authorization gate. Release methods are cleanup
/// only and retain the original browser host, even across navigation/revocation.
- (BOOL)sendAgentPointer:(NSPoint)point phase:(int)phase navigationGeneration:(uint64_t)generation;
- (void)releaseAgentPointer;
- (BOOL)sendAgentKey:(unsigned short)code windowsCode:(int)windowsCode
         characters:(NSString *)characters unmodified:(NSString *)unmodified
          modifiers:(NSUInteger)modifiers phase:(int)phase navigationGeneration:(uint64_t)generation;
- (void)releaseAgentKey;
- (void)checkAgentFocusWithNavigationGeneration:(uint64_t)generation
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate completion:(TatwoCEFBrowserInputHandler)completion;
- (void)selectValue:(NSString *)value elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion;
/// Fixed DOM-node-bound text operation; text is data, never executable source.
- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    completion:(TatwoCEFBrowserInputHandler)completion;
/// Agent path: every native continuation must use this same originating gate.
/// No missing-gate fallback; the older overload is for non-agent host callers.
- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)invokeWebMCPToolNamed:(NSString *)toolName
                argumentsJSON:(NSString *)argumentsJSON
         navigationGeneration:(uint64_t)navigationGeneration
                   completion:(TatwoCEFWebMCPInvocationHandler)completion;
- (void)closeBrowser;
- (void)closeBrowserWithCompletion:
    (nullable TatwoCEFBrowserCloseHandler)completion;

@end

/// Process-wide CEF lifecycle. The bridge intentionally exposes the engine
/// identifier so UI and acceptance evidence cannot confuse WebKit with CEF.
@interface TatwoCEFRuntime : NSObject

@property(class, nonatomic, readonly) BOOL compiled;
@property(class, nonatomic, copy, readonly) NSString *engineIdentifier;
@property(class, nonatomic, copy, readonly) NSString *runtimeVersion;
/// Cookies and selected origin storage can be cleared without profile-wide
/// mutation. HTTP response-cache clearing remains a separate unsupported
/// capability in CEF 151.
@property(class, nonatomic, readonly) BOOL supportsOriginScopedSiteDataClearing;
@property(class, nonatomic, readonly)
    BOOL supportsOriginScopedHTTPResponseCacheClearing;
/// True only when the compiled CEF renderer hook is active in the initialized
/// runtime. Non-CEF builds and shut-down runtimes report NO.
@property(class, nonatomic, readonly) BOOL supportsChromiumWebMCP;

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
               helperExecutablePath:(NSString *)helperExecutablePath
                        logFilePath:(NSString *)logFilePath
               bundledDenyListPath:(NSString *)bundledDenyListPath
                              error:(NSError * _Nullable * _Nullable)error;
+ (void)clearDataForOrigin:(NSString *)origin
         persistentProfile:(NSString *)persistentProfile
                completion:(TatwoCEFOriginDataClearHandler)completion;
/// Captures the active committed main frame through CEF's internal DevTools
/// DOMSnapshot domain. Failure is fail-closed: no page-main-world JavaScript,
/// raw DOM, HTML, cookies, storage, form values, or screenshot fallback.
+ (void)captureActiveVisibleSnapshotWithCompletion:
    (TatwoCEFBrowserSnapshotHandler)completion;
+ (void)shutdown;

@end

/// Entry point used only by the separately bundled CEF helper executable.
FOUNDATION_EXPORT int TatwoCEFExecuteSubprocess(void);

/// CEF's own canonical-host policy probe. Tests must build the real bridge
/// (`TATWO_ENABLE_CEF=1`) before treating a positive result as CEF coverage.
FOUNDATION_EXPORT BOOL TatwoCEFURLPolicyAllowsURLString(NSString *urlString);

/// Applies the bridge's preflight DNS resolution policy in addition to the
/// canonical-host policy. The unavailable bridge always returns NO.
FOUNDATION_EXPORT BOOL
TatwoCEFResolvedURLPolicyAllowsURLString(NSString *urlString);

/// Returns a normalized HTTP(S) origin or nil for missing, malformed, or
/// non-network URLs. This parser is exception-safe on current Foundation.
FOUNDATION_EXPORT NSString * _Nullable
TatwoCEFOriginForURLString(NSString * _Nullable urlString);

/// Uses the same deny-list as the real Chromium command-line hook. The
/// unavailable bridge always returns NO so non-CEF builds cannot masquerade as
/// coverage of the real Chromium host argv boundary.
FOUNDATION_EXPORT BOOL TatwoCEFHostSwitchIsDenied(NSString *switchName);

NS_ASSUME_NONNULL_END
