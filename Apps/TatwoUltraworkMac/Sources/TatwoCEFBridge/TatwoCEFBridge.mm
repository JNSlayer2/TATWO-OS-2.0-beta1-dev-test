#import "TatwoCEFBridge.h"
#import "TatwoBrowserStagingLoopback.h"

#include <arpa/inet.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_set>
#include <vector>

#pragma mark - W57a
#include "include/cef_context_menu_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_keyboard_handler.h"
#pragma mark - W57a end
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_preference.h"
#include "include/cef_process_message.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/cef_version.h"
#include "include/cef_values.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#pragma mark - W57d
#include "include/cef_dialog_handler.h"
// Pure, deliberately reduced Chrome UA for the pinned Chromium 151 runtime.
// This is compatibility metadata, not a promise that an identity provider accepts CEF.
constexpr const char *W57dUserAgent() {
  return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
}
static_assert(CHROME_VERSION_MAJOR == 151, "Review W57d UA when upgrading Chromium");
namespace { void W57dInvalidate(TatwoCEFBrowserView *view); }
#pragma mark - W57d End

@interface TatwoCEFApplication () <CefAppProtocol>
@end

@interface TatwoCEFBrowserView () <NSWindowDelegate>
- (void)startBrowserIfReady;
- (void)queueOrDispatchURLString:(NSString *)urlString
 pendingDispatchGate:(nullable TatwoCEFBrowserInputDispatchGate)dispatchGate;
- (nullable instancetype)initForPopupWithFrame:(NSRect)frame
                                        opener:(TatwoCEFBrowserView *)opener
                                       popupID:(int)popupID NS_DESIGNATED_INITIALIZER;
@end

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
  // CEF's macOS message pump queries this state from nested event loops.
  // CefScopedSendingEvent preserves and restores the previous value instead of
  // flattening nested sendEvent calls into an incorrect single boolean toggle.
  CefScopedSendingEvent scoped_sending_event;
  [super sendEvent:event];
}

@end

namespace {

NSString *const kTatwoCEFErrorDomain = @"com.tatwo.ultrawork.cef";
NSString *const kSecurityNavigationError =
    @"安全限制：僅允許公開 http 或 https 網址";
NSString *const kPopupBlockedError =
    @"安全限制：已封鎖新視窗或外部開啟";
NSString *const kDownloadBlockedError =
    @"安全限制：內建瀏覽器不接受下載";
NSString *const kPermissionBlockedError =
    @"安全限制：已拒絕相機、麥克風、位置或其他敏感權限";
NSString *const kCertificateBlockedError =
    @"安全限制：網站憑證無效，已拒絕連線";
NSString *const kAuthenticationBlockedError =
    @"安全限制：已拒絕網站 HTTP 認證挑戰";
NSString *const kPrivacyStrictStartupError =
    @"Chromium 隱私防線無法完整啟用，已停止建立瀏覽器";

std::unique_ptr<CefScopedLibraryLoader> g_library_loader;
CefRefPtr<CefApp> g_application;
std::atomic_bool g_initialized{false};
// W60b: supplied by the same Swift policy as the browser admission budget.
// Zero means no application override; Chromium still enforces its own model.
std::atomic<int> g_renderer_process_limit{0};
dispatch_source_t g_message_pump_idle_timer = nil;
std::atomic_bool g_shutdown{false};
std::atomic_bool g_shutdown_requested{false};
std::atomic<uint64_t> g_message_pump_generation{0};
std::atomic<uint64_t> g_navigation_trace_sequence{0};
std::atomic<uint64_t> g_mount_generation_seed{0};
std::atomic<uint64_t> g_origin_data_clear_operation_seed{0};
std::atomic<uint64_t> g_resource_decision_seed{0};
std::atomic<size_t> g_resource_decisions_in_flight{0};
std::atomic<uint64_t> g_stale_callback_drop_count{0};
std::atomic_bool g_webrtc_ip_policy_configured{false};
std::atomic<uint64_t> g_host_blocked_request_count{0};
std::atomic<uint64_t> g_host_blocked_main_frame_count{0};
std::atomic<uint64_t> g_host_blocked_subresource_count{0};
std::atomic_bool g_webmcp_renderer_hook_active{false};

constexpr uint32_t kBrowserNetworkSecurityPolicyVersion = 1;
constexpr const char *kWebRTCIPHandlingPolicy =
    "disable_non_proxied_udp";

NSColor *TatwoCEFOpaquePanelBackgroundNSColor() {
  NSColor *source =
      [[NSColor windowBackgroundColor]
          colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (source == nil) {
    source = [NSColor colorWithSRGBRed:0.14 green:0.14 blue:0.15 alpha:1];
  }
  CGFloat red = 0;
  CGFloat green = 0;
  CGFloat blue = 0;
  CGFloat alpha = 1;
  [source getRed:&red green:&green blue:&blue alpha:&alpha];
  // Keep the resize gap opaque and never pure white, even in Light mode.
  return [NSColor colorWithSRGBRed:std::min<CGFloat>(red, 0.92)
                            green:std::min<CGFloat>(green, 0.92)
                             blue:std::min<CGFloat>(blue, 0.92)
                            alpha:1];
}


struct BrowserHostDenyListSnapshot;
std::shared_ptr<const BrowserHostDenyListSnapshot> g_host_deny_list;

void AppendCEFEmbeddingTelemetryLine(NSString *line);

class MessagePumpFollowUpGate {
 public:
  bool TryBegin() {
    bool expected = false;
    if (running_.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acquire,
            std::memory_order_relaxed)) {
      return true;
    }
    pending_follow_up_.store(true, std::memory_order_release);
    return false;
  }

  bool EndAndTakeFollowUp() {
    // Release the active slot before consuming the pending bit. A kick racing
    // with teardown can then either become the next active tick or leave one
    // deduplicated follow-up request; it cannot be lost behind running=true.
    running_.store(false, std::memory_order_release);
    return pending_follow_up_.exchange(false, std::memory_order_acq_rel);
  }

 private:
  std::atomic_bool running_{false};
  std::atomic_bool pending_follow_up_{false};
};

MessagePumpFollowUpGate g_message_pump_follow_up_gate;

class MessagePumpHostKickQueueGate {
 public:
  bool TryQueue() {
    bool expected = false;
    return queued_.compare_exchange_strong(
        expected,
        true,
        std::memory_order_acquire,
        std::memory_order_relaxed);
  }

  void EndQueue() {
    queued_.store(false, std::memory_order_release);
  }

 private:
  std::atomic_bool queued_{false};
};

MessagePumpHostKickQueueGate g_message_pump_host_kick_queue_gate;

// Context creation can finish after the last vendor wake. Reuse the loading
// timer during startup, without pretending a page is already loading.
bool HasActiveBrowserPumpWork(bool is_loading, bool is_creating,
                              bool context_ready, bool context_blocked,
                              bool creation_pending) {
  return is_loading ||
         (is_creating && !context_blocked &&
          (!context_ready || creation_pending));
}

class LoadingActiveMessagePumpGate {
 public:
  uint64_t Start() {
    if (!active_) {
      active_ = true;
      generation_ += 1;
    }
    return generation_;
  }

  bool Stop() {
    if (!active_) {
      return false;
    }
    active_ = false;
    generation_ += 1;
    return true;
  }

  bool CanTick(uint64_t generation,
               bool is_loading,
               bool close_requested,
               bool initialized,
               bool shutdown) const {
    return active_ &&
           generation == generation_ &&
           is_loading &&
           !close_requested &&
           initialized &&
           !shutdown;
  }

  void RecordTick() { tick_count_ += 1; }

  bool active() const { return active_; }
  uint64_t generation() const { return generation_; }
  uint64_t tick_count() const { return tick_count_; }

 private:
  bool active_ = false;
  uint64_t generation_ = 0;
  uint64_t tick_count_ = 0;
};

std::atomic<uint64_t> g_message_pump_schedule_count{0};
std::atomic<uint64_t> g_message_pump_do_work_count{0};
std::atomic<int64_t> g_message_pump_last_schedule_ms{0};
std::atomic<int64_t> g_message_pump_last_do_work_ms{0};
std::atomic<int64_t> g_message_pump_last_requested_delay_ms{0};
std::atomic<int64_t> g_message_pump_last_normalized_delay_ms{0};
std::atomic<uint64_t> g_message_pump_last_generation{0};
std::atomic<uint64_t> g_message_pump_last_summary_event_count{0};
std::atomic<int64_t> g_message_pump_last_summary_ms{0};
std::atomic<uint64_t> g_message_pump_detail_event_count{0};
std::atomic<uint64_t> g_loading_pump_stale_tick_drop_count{0};
NSString *g_embedding_telemetry_path;
int g_helper_telemetry_descriptor = -1;
id g_termination_observer;
NSMutableSet<TatwoCEFBrowserView *> *g_closing_views;
NSHashTable<TatwoCEFBrowserView *> *g_live_browser_views;
__weak TatwoCEFBrowserView *g_active_committed_browser_view;
constexpr size_t kCEFHelperRoleCount = 6;
enum class CEFHelperRole : size_t {
  kGPU = 0,
  kRenderer = 1,
  kNetwork = 2,
  kStorage = 3,
  kUtility = 4,
  kOther = 5,
};
std::array<std::atomic<uint64_t>, kCEFHelperRoleCount>
    g_helper_role_launch_counts{};

const char *const kDeniedHostSwitches[] = {
    "remote-debugging-port",
    "remote-debugging-address",
    "remote-debugging-pipe",
    "remote-allow-origins",
    "user-data-dir",
    "no-sandbox",
    "disable-web-security",
    "allow-running-insecure-content",
    "allow-insecure-localhost",
    "ignore-certificate-errors",
    "disable-site-isolation-trials",
    "disable-features",
};

NSError *MakeError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:kTatwoCEFErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

CefString ToCefString(NSString *value) {
  CefString converted;
  if (value.length > 0) {
    const char *utf8 = value.UTF8String;
    converted.FromString(utf8, strlen(utf8));
  }
  return converted;
}

NSString *FromCefString(const CefString &value) {
  const std::string utf8 = value.ToString();
  return [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *ResolveCEFHelperExecutablePath(NSString *hint_path) {
  if (hint_path.length == 0 || !hint_path.isAbsolutePath) {
    return nil;
  }

  // Swift supplies a path inside the signed helper bundle rather than trusting
  // command-line input. Resolve the bundle's declared CFBundleExecutable so
  // packaging may rename the copied helper binary while CEF still receives the
  // exact executable path it requires.
  NSString *macos_directory = hint_path.stringByDeletingLastPathComponent;
  NSString *contents_directory =
      macos_directory.stringByDeletingLastPathComponent;
  NSString *helper_bundle_path =
      contents_directory.stringByDeletingLastPathComponent
          .stringByStandardizingPath.stringByResolvingSymlinksInPath;
  if (![helper_bundle_path.pathExtension.lowercaseString
          isEqualToString:@"app"]) {
    return nil;
  }

  NSString *frameworks_path =
      NSBundle.mainBundle.privateFrameworksPath.stringByStandardizingPath
          .stringByResolvingSymlinksInPath;
  NSString *expected_prefix =
      [frameworks_path stringByAppendingString:@"/"];
  if (frameworks_path.length == 0 ||
      ![helper_bundle_path hasPrefix:expected_prefix]) {
    return nil;
  }

  NSBundle *helper_bundle = [NSBundle bundleWithPath:helper_bundle_path];
  NSString *resolved_path =
      helper_bundle.executablePath.stringByStandardizingPath
          .stringByResolvingSymlinksInPath;
  NSString *helper_macos_prefix =
      [[helper_bundle_path stringByAppendingPathComponent:@"Contents/MacOS"]
          stringByAppendingString:@"/"];
  if (resolved_path.length == 0 ||
      ![resolved_path hasPrefix:helper_macos_prefix] ||
      ![NSFileManager.defaultManager isExecutableFileAtPath:resolved_path]) {
    return nil;
  }
  return resolved_path;
}

bool IsPrivateIPv4(NSString *host) {
  in_addr address{};
  // inet_aton intentionally accepts every IPv4 spelling Chromium accepts,
  // including one-part decimal, shortened dotted, and hexadecimal forms.
  // Using inet_pton here lets 2130706433, 127.1, and 0x7f000001 bypass a
  // loopback check before Chromium canonicalizes them.
  if (inet_aton(host.UTF8String, &address) != 1) {
    return false;
  }
  const uint32_t value = ntohl(address.s_addr);
  const uint8_t first = static_cast<uint8_t>((value >> 24) & 0xff);
  const uint8_t second = static_cast<uint8_t>((value >> 16) & 0xff);
  const uint8_t third = static_cast<uint8_t>((value >> 8) & 0xff);
  if (first == 0 || first == 10 || first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 0) ||
      (first == 192 && second == 168) ||
      (first == 198 && second >= 18 && second <= 19) ||
      (first == 192 && second == 0 && third == 2) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113)) {
    return true;
  }
  return first >= 224;
}

bool IsPrivateIPv6(NSString *host) {
  in6_addr address{};
  if (inet_pton(AF_INET6, host.UTF8String, &address) != 1) {
    return false;
  }
  const uint8_t *bytes = address.s6_addr;
  bool all_zero = true;
  for (size_t index = 0; index < 16; ++index) {
    all_zero = all_zero && bytes[index] == 0;
  }
  if (all_zero) {
    return true;
  }
  bool loopback = true;
  for (size_t index = 0; index < 15; ++index) {
    loopback = loopback && bytes[index] == 0;
  }
  if (loopback && bytes[15] == 1) {
    return true;
  }
  if ((bytes[0] & 0xfe) == 0xfc ||
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) ||
      bytes[0] == 0xff) {
    return true;
  }
  if (bytes[0] == 0x20 && bytes[1] == 0x01 &&
      bytes[2] == 0x0d && bytes[3] == 0xb8) {
    return true;
  }
  bool ipv4_mapped = true;
  for (size_t index = 0; index < 10; ++index) {
    ipv4_mapped = ipv4_mapped && bytes[index] == 0;
  }
  if (ipv4_mapped && bytes[10] == 0xff && bytes[11] == 0xff) {
    in_addr embedded{};
    memcpy(&embedded.s_addr, bytes + 12, sizeof(embedded.s_addr));
    const uint32_t value = ntohl(embedded.s_addr);
    const uint8_t first = static_cast<uint8_t>((value >> 24) & 0xff);
    const uint8_t second = static_cast<uint8_t>((value >> 16) & 0xff);
    const uint8_t third = static_cast<uint8_t>((value >> 8) & 0xff);
    return first == 0 || first == 10 || first == 127 ||
           (first == 100 && second >= 64 && second <= 127) ||
           (first == 169 && second == 254) ||
           (first == 172 && second >= 16 && second <= 31) ||
           (first == 192 && second == 0) ||
           (first == 192 && second == 168) ||
           (first == 198 && second >= 18 && second <= 19) ||
           (first == 192 && second == 0 && third == 2) ||
           (first == 198 && second == 51 && third == 100) ||
           (first == 203 && second == 0 && third == 113) ||
           first >= 224;
  }
  return false;
}

NSURLComponents *SafeURLComponents(NSString *url_string) {
  if (![url_string isKindOfClass:NSString.class] ||
      url_string.length == 0) {
    return nil;
  }
  @try {
    return [NSURLComponents
        componentsWithString:url_string
        encodingInvalidCharacters:YES];
  } @catch (NSException *exception) {
    return nil;
  }
}

NSString *CanonicalHost(NSString *url_string) {
  NSURLComponents *components = SafeURLComponents(url_string);
  NSString *host = components.host.lowercaseString;
  if (host.length == 0) {
    return nil;
  }
  host = [host stringByTrimmingCharactersInSet:
                   [NSCharacterSet characterSetWithCharactersInString:@"[]"]];
  while ([host hasSuffix:@"."]) {
    host = [host substringToIndex:host.length - 1];
  }
  return host.length > 0 ? host : nil;
}

bool IsAllowedURLString(NSString *url_string) {
  NSURLComponents *components = SafeURLComponents(url_string);
  NSString *scheme = components.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] &&
      ![scheme isEqualToString:@"https"]) {
    return false;
  }
  NSString *host = CanonicalHost(url_string);
  if (host == nil) {
    return false;
  }
  NSArray<NSString *> *blocked_suffixes = @[
    @"localhost", @".localhost", @"local", @".local", @"home.arpa",
    @".home.arpa", @"internal", @".internal", @"lan", @".lan"
  ];
  for (NSString *suffix in blocked_suffixes) {
    if ([suffix hasPrefix:@"."]) {
      if ([host hasSuffix:suffix]) {
        return false;
      }
    } else if ([host isEqualToString:suffix]) {
      return false;
    }
  }
  if (TatwoBrowserStagingLoopbackAllows(
          components, TatwoBrowserStagingLoopbackRuntimePort())) {
    return true;
  }
  return !IsPrivateIPv4(host) && !IsPrivateIPv6(host);
}

bool SocketAddressIsPrivate(const sockaddr *address) {
  if (address == nullptr) {
    return true;
  }
  char presentation[INET6_ADDRSTRLEN] = {};
  if (address->sa_family == AF_INET) {
    const auto *ipv4 = reinterpret_cast<const sockaddr_in *>(address);
    if (inet_ntop(AF_INET, &ipv4->sin_addr, presentation,
                  sizeof(presentation)) == nullptr) {
      return true;
    }
    return IsPrivateIPv4(
        [NSString stringWithUTF8String:presentation]);
  }
  if (address->sa_family == AF_INET6) {
    const auto *ipv6 = reinterpret_cast<const sockaddr_in6 *>(address);
    if (inet_ntop(AF_INET6, &ipv6->sin6_addr, presentation,
                  sizeof(presentation)) == nullptr) {
      return true;
    }
    return IsPrivateIPv6(
        [NSString stringWithUTF8String:presentation]);
  }
  return true;
}

enum class PublicAddressResult { kPublic, kNonPublic, kDNSFailure };

PublicAddressResult ResolvePublicAddressResult(NSString *url_string) {
  NSString *host = CanonicalHost(url_string);
  if (host == nil) {
    return PublicAddressResult::kDNSFailure;
  }
  // Only an exact numeric endpoint skips the private-literal rejection.
  // DNS names resolving to loopback still use SocketAddressIsPrivate unchanged.
  // No source-origin grant: every redirected/resource URL is checked anew.
  if (TatwoBrowserStagingLoopbackAllows(
          SafeURLComponents(url_string), TatwoBrowserStagingLoopbackRuntimePort())) {
    return PublicAddressResult::kPublic;
  }
  if (IsPrivateIPv4(host) || IsPrivateIPv6(host)) {
    return PublicAddressResult::kNonPublic;
  }

  // Public literals need no second resolver pass.
  in_addr ipv4{};
  in6_addr ipv6{};
  if (inet_aton(host.UTF8String, &ipv4) == 1 ||
      inet_pton(AF_INET6, host.UTF8String, &ipv6) == 1) {
    return PublicAddressResult::kPublic;
  }

  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_ADDRCONFIG;
  addrinfo *result = nullptr;
  const int status = getaddrinfo(host.UTF8String, nullptr, &hints, &result);
  if (status != 0 || result == nullptr) {
    if (result != nullptr) {
      freeaddrinfo(result);
    }
    return PublicAddressResult::kDNSFailure;
  }

  bool saw_address = false;
  bool all_public = true;
  for (addrinfo *entry = result; entry != nullptr; entry = entry->ai_next) {
    if (entry->ai_family != AF_INET && entry->ai_family != AF_INET6) {
      continue;
    }
    saw_address = true;
    if (SocketAddressIsPrivate(entry->ai_addr)) {
      all_public = false;
      break;
    }
  }
  freeaddrinfo(result);
  if (!saw_address) return PublicAddressResult::kDNSFailure;
  return all_public ? PublicAddressResult::kPublic
                    : PublicAddressResult::kNonPublic;
}

bool ResolvesOnlyToPublicAddresses(NSString *url_string) {
  return ResolvePublicAddressResult(url_string) == PublicAddressResult::kPublic;
}

bool IsAllowedResolvedURLString(NSString *url_string) {
  return IsAllowedURLString(url_string) &&
         ResolvesOnlyToPublicAddresses(url_string);
}

bool URLHasCredentials(NSString *url_string) {
  NSURLComponents *components = SafeURLComponents(url_string);
  return components.user != nil || components.password != nil;
}

NSString *OriginForURLString(NSString *url_string) {
  NSURLComponents *components = SafeURLComponents(url_string);
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host.lowercaseString;
  NSMutableCharacterSet *invalid_host_characters =
      [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
  [invalid_host_characters
      formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
  if ((![scheme isEqualToString:@"http"] &&
       ![scheme isEqualToString:@"https"]) ||
      host.length == 0 ||
      [host rangeOfCharacterFromSet:invalid_host_characters].location !=
          NSNotFound) {
    return nil;
  }
  NSNumber *port = components.port;
  if (([scheme isEqualToString:@"http"] &&
       port.integerValue == 80) ||
      ([scheme isEqualToString:@"https"] &&
       port.integerValue == 443)) {
    port = nil;
  }
  NSURLComponents *origin = [[NSURLComponents alloc] init];
  origin.scheme = scheme;
  origin.host = host;
  origin.port = port;
  origin.path = @"";
  origin.query = nil;
  origin.fragment = nil;
  origin.user = nil;
  origin.password = nil;
  return origin.string;
}

bool IsSameOrigin(NSString *first_url, NSString *second_url) {
  NSString *first_origin = OriginForURLString(first_url);
  NSString *second_origin = OriginForURLString(second_url);
  return first_origin.length > 0 &&
         [first_origin isEqualToString:second_origin];
}

bool IsCommonCountryCodeSecondLevelDomain(NSString *label) {
  const char *const common_labels[] = {
      "ac", "co", "com", "edu", "gov", "net", "org",
  };
  for (const char *candidate : common_labels) {
    if ([label isEqualToString:
                   [NSString stringWithUTF8String:candidate]]) {
      return true;
    }
  }
  return false;
}

NSString *RegistrableDomainForHost(NSString *raw_host) {
  NSString *host = raw_host.lowercaseString;
  if (host.length == 0 ||
      IsPrivateIPv4(host) ||
      IsPrivateIPv6(host)) {
    return host;
  }
  NSArray<NSString *> *labels =
      [host componentsSeparatedByString:@"."];
  if (labels.count <= 2) {
    return host;
  }
  NSString *top_level = labels.lastObject;
  NSString *second_level = labels[labels.count - 2];
  const NSUInteger suffix_count =
      top_level.length == 2 &&
              IsCommonCountryCodeSecondLevelDomain(second_level) &&
              labels.count >= 3
          ? 3
          : 2;
  return [[labels subarrayWithRange:
                      NSMakeRange(labels.count - suffix_count,
                                  suffix_count)]
      componentsJoinedByString:@"."];
}

bool IsSameSite(NSString *request_url, NSString *first_party_url) {
  NSURLComponents *request = SafeURLComponents(request_url);
  NSURLComponents *first_party = SafeURLComponents(first_party_url);
  NSString *request_scheme = request.scheme.lowercaseString;
  NSString *first_party_scheme = first_party.scheme.lowercaseString;
  NSString *request_host = request.host.lowercaseString;
  NSString *first_party_host = first_party.host.lowercaseString;
  if (request_scheme.length == 0 ||
      ![request_scheme isEqualToString:first_party_scheme] ||
      request_host.length == 0 ||
      first_party_host.length == 0) {
    return false;
  }
  return [RegistrableDomainForHost(request_host)
      isEqualToString:RegistrableDomainForHost(first_party_host)];
}

bool URLHostIsIPAddress(NSString *url_string) {
  NSString *host = CanonicalHost(url_string);
  if (host.length == 0) {
    return false;
  }
  in_addr ipv4 {};
  in6_addr ipv6 {};
  return inet_aton(host.UTF8String, &ipv4) == 1 ||
         inet_pton(AF_INET6, host.UTF8String, &ipv6) == 1;
}

NSString *CanonicalDenyListEntry(NSString *raw_entry) {
  if (![raw_entry isKindOfClass:NSString.class]) {
    return nil;
  }
  NSString *trimmed =
      [raw_entry stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (trimmed.length == 0 ||
      [trimmed rangeOfCharacterFromSet:
                   [NSCharacterSet
                       characterSetWithCharactersInString:@"/:@?#"]]
              .location != NSNotFound ||
      [trimmed rangeOfCharacterFromSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet]
              .location != NSNotFound) {
    return nil;
  }
  NSString *host = trimmed.lowercaseString;
  while ([host hasSuffix:@"."]) {
    host = [host substringToIndex:host.length - 1];
  }
  NSURLComponents *components =
      SafeURLComponents([@"https://" stringByAppendingString:host]);
  return components.host.length > 0 ? host : nil;
}

struct BrowserHostDenyListSnapshot {
  std::unordered_set<std::string> exact_hosts;
  std::unordered_set<std::string> suffix_hosts;
  // The bundled list is large; keep extra provenance only for custom rules.
  std::map<std::string, std::string> custom_exact_sources;
  std::map<std::string, std::string> custom_suffix_sources;
  size_t bundled_exact_count = 0;
  size_t bundled_suffix_count = 0;
  size_t admin_exact_count = 0;
  size_t admin_suffix_count = 0;
  size_t user_exact_count = 0;
  size_t user_suffix_count = 0;

  NSString *BlockingSource(NSString *raw_host) const {
    if (raw_host.length == 0) {
      return nil;
    }
    NSString *canonical = raw_host.lowercaseString;
    while ([canonical hasSuffix:@"."]) {
      canonical = [canonical substringToIndex:canonical.length - 1];
    }
    const char *utf8 = canonical.UTF8String;
    if (utf8 == nullptr) {
      return nil;
    }
    const std::string host(utf8);
    if (exact_hosts.contains(host)) {
      auto source = custom_exact_sources.find(host);
      return source == custom_exact_sources.end() ? @"內建名單"
          : [NSString stringWithUTF8String:source->second.c_str()];
    }
    if (suffix_hosts.contains(host)) {
      auto source = custom_suffix_sources.find(host);
      return source == custom_suffix_sources.end() ? @"內建名單"
          : [NSString stringWithUTF8String:source->second.c_str()];
    }
    size_t dot = host.find('.');
    while (dot != std::string::npos) {
      const std::string suffix = host.substr(dot + 1);
      if (suffix_hosts.contains(suffix)) {
        auto source = custom_suffix_sources.find(suffix);
        return source == custom_suffix_sources.end() ? @"內建名單"
            : [NSString stringWithUTF8String:source->second.c_str()];
      }
      dot = host.find('.', dot + 1);
    }
    return nil;
  }

  bool Blocks(NSString *raw_host) const {
    return raw_host.length == 0 || raw_host.UTF8String == nullptr ||
           BlockingSource(raw_host) != nil;
  }
};

enum class DenyListFileStatus {
  kMissing,
  kLoaded,
  kInvalid,
};

DenyListFileStatus ReadBoundedRegularFile(NSString *path,
                                          off_t maximum_bytes,
                                          NSData **data) {
  if (data != nullptr) {
    *data = nil;
  }
  struct stat metadata {};
  if (lstat(path.fileSystemRepresentation, &metadata) != 0) {
    return errno == ENOENT ? DenyListFileStatus::kMissing
                           : DenyListFileStatus::kInvalid;
  }
  if (!S_ISREG(metadata.st_mode) ||
      metadata.st_size <= 0 ||
      metadata.st_size > maximum_bytes) {
    return DenyListFileStatus::kInvalid;
  }
  const int descriptor =
      open(path.fileSystemRepresentation,
           O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    return DenyListFileStatus::kInvalid;
  }
  struct stat opened_metadata {};
  if (fstat(descriptor, &opened_metadata) != 0 ||
      !S_ISREG(opened_metadata.st_mode) ||
      opened_metadata.st_dev != metadata.st_dev ||
      opened_metadata.st_ino != metadata.st_ino ||
      opened_metadata.st_size != metadata.st_size) {
    close(descriptor);
    return DenyListFileStatus::kInvalid;
  }
  NSMutableData *buffer =
      [NSMutableData dataWithLength:
                         static_cast<NSUInteger>(metadata.st_size)];
  uint8_t *bytes = static_cast<uint8_t *>(buffer.mutableBytes);
  ssize_t offset = 0;
  while (offset < metadata.st_size) {
    const ssize_t count =
        read(descriptor,
             bytes + offset,
             static_cast<size_t>(metadata.st_size - offset));
    if (count <= 0) {
      close(descriptor);
      return DenyListFileStatus::kInvalid;
    }
    offset += count;
  }
  close(descriptor);
  if (data != nullptr) {
    *data = buffer;
  }
  return DenyListFileStatus::kLoaded;
}

bool MergeDenyListJSON(
    NSData *data,
    BrowserHostDenyListSnapshot *snapshot,
    size_t *exact_count,
    size_t *suffix_count,
    NSString *custom_source = nil) {
  if (data.length == 0 || snapshot == nullptr) {
    return false;
  }
  NSError *json_error = nil;
  id object =
      [NSJSONSerialization JSONObjectWithData:data
                                      options:0
                                        error:&json_error];
  if (json_error != nil ||
      ![object isKindOfClass:NSDictionary.class]) {
    return false;
  }
  NSDictionary *document = object;
  if (![document[@"schema"]
          isEqualToString:@"TatwoBrowserHostDenyListV1"]) {
    return false;
  }
  NSArray *exact_hosts = document[@"exactHosts"];
  NSArray *suffix_hosts = document[@"suffixes"];
  if (![exact_hosts isKindOfClass:NSArray.class] ||
      ![suffix_hosts isKindOfClass:NSArray.class]) {
    return false;
  }
  BrowserHostDenyListSnapshot layer;
  for (NSArray *entries in @[ exact_hosts, suffix_hosts ]) {
    for (id raw_entry in entries) {
      NSString *host = CanonicalDenyListEntry(raw_entry);
      if (host.length == 0) {
        return false;
      }
      const char *utf8 = host.UTF8String;
      if (utf8 == nullptr) {
        return false;
      }
      if (entries == exact_hosts) {
        layer.exact_hosts.insert(utf8);
      } else {
        layer.suffix_hosts.insert(utf8);
      }
    }
  }
  snapshot->exact_hosts.insert(
      layer.exact_hosts.begin(), layer.exact_hosts.end());
  snapshot->suffix_hosts.insert(
      layer.suffix_hosts.begin(), layer.suffix_hosts.end());
  if (custom_source != nil) {
    for (const auto &host : layer.exact_hosts) {
      snapshot->custom_exact_sources[host] = custom_source.UTF8String;
    }
    for (const auto &host : layer.suffix_hosts) {
      snapshot->custom_suffix_sources[host] = custom_source.UTF8String;
    }
  }
  if (exact_count != nullptr) {
    *exact_count = layer.exact_hosts.size();
  }
  if (suffix_count != nullptr) {
    *suffix_count = layer.suffix_hosts.size();
  }
  return true;
}

std::shared_ptr<const BrowserHostDenyListSnapshot>
LoadHostDenyListSnapshot(NSString *root_cache_path,
                         NSString *bundled_deny_list_path,
                         NSError **error) {
  auto snapshot =
      std::make_shared<BrowserHostDenyListSnapshot>();
  NSString *runtime_root =
      root_cache_path.stringByDeletingLastPathComponent;
  NSString *security_root =
      [runtime_root stringByAppendingPathComponent:@"browser-security"];
  struct DenyListLayer {
    __unsafe_unretained NSString *path;
    bool required;
    off_t maximum_bytes;
    size_t *exact_count;
    size_t *suffix_count;
  };
  DenyListLayer layers[] = {
      {
          bundled_deny_list_path,
          true,
          16 * 1024 * 1024,
          &snapshot->bundled_exact_count,
          &snapshot->bundled_suffix_count,
      },
      {
          [security_root
              stringByAppendingPathComponent:@"admin-deny-list.json"],
          false,
          1024 * 1024,
          &snapshot->admin_exact_count,
          &snapshot->admin_suffix_count,
      },
      {
          [security_root
              stringByAppendingPathComponent:@"user-deny-list.json"],
          false,
          1024 * 1024,
          &snapshot->user_exact_count,
          &snapshot->user_suffix_count,
      },
  };
  for (const DenyListLayer &layer : layers) {
    NSData *data = nil;
    const DenyListFileStatus status =
        ReadBoundedRegularFile(
            layer.path, layer.maximum_bytes, &data);
    if (status == DenyListFileStatus::kMissing &&
        !layer.required) {
      continue;
    }
    if (status != DenyListFileStatus::kLoaded ||
        !MergeDenyListJSON(
            data,
            snapshot.get(),
            layer.exact_count,
            layer.suffix_count,
            layer.exact_count == &snapshot->admin_exact_count ? @"管理員名單"
              : layer.exact_count == &snapshot->user_exact_count ? @"使用者名單"
              : nil)) {
      if (error != nullptr) {
        *error = MakeError(
            15,
            @"Chromium 本機封鎖名單無法安全載入");
      }
      return nullptr;
    }
  }
  return snapshot;
}

struct BrowserRequestPolicySnapshot {
  bool sends_global_privacy_control = true;
  bool reduces_cross_origin_referrers = true;
  bool blocks_third_party_cookies = true;
  bool privacy_strict = true;
  bool human = false;
  bool ad_block = true;
  std::shared_ptr<const BrowserHostDenyListSnapshot> host_deny_list;
};

bool ApplyPrivacyStrictRequestContextPreferences(
    CefRefPtr<CefRequestContext> request_context,
    TatwoCEFBrowserActor actor = TatwoCEFBrowserActorAgent) {
  struct BooleanPreference {
    const char *name;
    bool required_for_privacy_strict;
  };
  const BooleanPreference disabled_preferences[] = {
      {"credentials_enable_service", false},
      {"profile.password_manager_enabled", false},
      {"autofill.credit_card_enabled", false},
      {"autofill.profile_enabled", false},
      {"ssl.error_override_allowed", true},
  };
  if (!request_context) {
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=security_capability event=preference_failed "
             "policyVersion=%u preference=request_context "
             "reason=context_unavailable",
            kBrowserNetworkSecurityPolicyVersion]);
    return false;
  }
  for (const BooleanPreference &preference : disabled_preferences) {
    if (!request_context->CanSetPreference(preference.name)) {
      AppendCEFEmbeddingTelemetryLine(
          [NSString stringWithFormat:
              @"phase=security_capability event=preference_unavailable "
               "policyVersion=%u preference=%s requiredForPrivacyStrict=%d",
              kBrowserNetworkSecurityPolicyVersion,
              preference.name,
              preference.required_for_privacy_strict ? 1 : 0]);
      if (preference.required_for_privacy_strict) {
        return false;
      }
      continue;
    }
    CefRefPtr<CefValue> value = CefValue::Create();
    if (!value || !value->SetBool(actor == TatwoCEFBrowserActorHuman && !preference.required_for_privacy_strict)) {
      AppendCEFEmbeddingTelemetryLine(
          [NSString stringWithFormat:
              @"phase=security_capability event=preference_failed "
               "policyVersion=%u preference=%s reason=value_unavailable",
              kBrowserNetworkSecurityPolicyVersion,
              preference.name]);
      return false;
    }
    CefString error;
    if (!request_context->SetPreference(
            preference.name, value, error)) {
      AppendCEFEmbeddingTelemetryLine(
          [NSString stringWithFormat:
              @"phase=security_capability event=preference_failed "
               "policyVersion=%u preference=%s reason=set_rejected",
              kBrowserNetworkSecurityPolicyVersion,
              preference.name]);
      return false;
    }
  }
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=security_capability event=preferences_configured "
           "policyVersion=%u passwordSaving=%d creditCardAutofill=%d "
           "addressAutofill=%d sslErrorOverride=0",
          kBrowserNetworkSecurityPolicyVersion,
          actor == TatwoCEFBrowserActorHuman, actor == TatwoCEFBrowserActorHuman,
          actor == TatwoCEFBrowserActorHuman]);
  return true;
}

class TatwoPrivacyStrictRequestContextHandler final
    : public CefRequestContextHandler {
 public:
  using Completion =
      std::function<void(CefRefPtr<CefRequestContext>, bool)>;

  explicit TatwoPrivacyStrictRequestContextHandler(
      Completion completion, TatwoCEFBrowserActor actor = TatwoCEFBrowserActorAgent)
      : completion_(std::move(completion)), actor_(actor) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    const bool configured =
        ApplyPrivacyStrictRequestContextPreferences(request_context, actor_);
    if (completion_) {
      auto completion = std::move(completion_);
      completion(request_context, configured);
    }
  }

  void Cancel() { completion_ = nullptr; }

 private:
  Completion completion_;
  TatwoCEFBrowserActor actor_;
  IMPLEMENT_REFCOUNTING(TatwoPrivacyStrictRequestContextHandler);
};

BrowserRequestPolicySnapshot ActorRequestPolicy(TatwoCEFBrowserView *owner) {
  BrowserRequestPolicySnapshot policy;
  policy.host_deny_list = g_host_deny_list;
  policy.human = owner && owner.browserActor == TatwoCEFBrowserActorHuman && !owner.agentControlled;
  policy.blocks_third_party_cookies = !policy.human || owner.blocksThirdPartyCookies;
  policy.ad_block = !owner || owner.adBlock;
  return policy;
}

// Human navigation is provisional: OnBeforeResourceLoad must still obtain
// private-network consent before any bytes are fetched, including DNS aliases.
bool IsActorURLAllowed(const BrowserRequestPolicySnapshot &policy, NSString *url) {
  if (!policy.human) return IsAllowedURLString(url);
  NSString *scheme = SafeURLComponents(url).scheme.lowercaseString;
  return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && CanonicalHost(url).length > 0;
}

bool IsDeniedByLocalHostList(
    const BrowserRequestPolicySnapshot &policy,
    NSString *url_string) {
  NSString *host = CanonicalHost(url_string);
  return !policy.host_deny_list ||
         (policy.ad_block && policy.host_deny_list->Blocks(host));
}

bool IsMainFrameRequest(CefRefPtr<CefRequest> request) {
  // A main frame also owns images, scripts and beacons. Only the document
  // request may replace the entire page with an error.
  return request && request->GetResourceType() == RT_MAIN_FRAME;
}

class ResourceNavigationEpoch {
 public:
  uint64_t Capture() const { return value_.load(std::memory_order_acquire); }
  void Advance() { value_.fetch_add(1, std::memory_order_acq_rel); }
  bool IsCurrent(uint64_t expected) const { return Capture() == expected; }
 private:
  std::atomic<uint64_t> value_{1};
};

struct ResourceErrorContext {
  std::shared_ptr<ResourceNavigationEpoch> epoch;
  uint64_t generation;
  uint64_t mount_generation;
};

NSString *ResourceBlockMessage(const BrowserRequestPolicySnapshot &policy,
                                NSString *url_string) {
  if (!policy.host_deny_list) {
    return @"瀏覽器封鎖名單尚未就緒，無法檢查此網址";
  }
  if (!IsAllowedURLString(url_string)) {
    NSString *scheme = SafeURLComponents(url_string).scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
      return @"安全限制：只允許 HTTP 或 HTTPS 網址";
    }
    return @"安全限制：網址無效，或目標位於本機／私有網路";
  }
  if (URLHasCredentials(url_string)) {
    return @"安全限制：網址不可包含帳號或密碼";
  }
  NSString *host = CanonicalHost(url_string);
  return [NSString stringWithFormat:@"安全限制：%@ 命中%@", host,
          policy.host_deny_list->BlockingSource(host) ?: @"本機網域封鎖名單"];
}

bool IsDeniedHostSwitch(NSString *switch_name) {
  if (switch_name.length == 0) {
    return false;
  }
  NSString *normalized = switch_name.lowercaseString;
  while ([normalized hasPrefix:@"-"]) {
    normalized = [normalized substringFromIndex:1];
  }
  for (const char *denied : kDeniedHostSwitches) {
    if ([normalized isEqualToString:[NSString stringWithUTF8String:denied]]) {
      return true;
    }
  }
  return false;
}

bool IsAllowedURL(const CefString &url) {
  return IsAllowedURLString(FromCefString(url));
}

bool IsAllowedResolvedURL(const CefString &url) {
  return IsAllowedResolvedURLString(FromCefString(url));
}

NSString *SnapshotOrigin(NSString *url_string) {
  NSURLComponents *components = SafeURLComponents(url_string);
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host.lowercaseString;
  if ((![scheme isEqualToString:@"http"] &&
       ![scheme isEqualToString:@"https"]) ||
      host.length == 0) {
    return nil;
  }
  NSNumber *port = components.port;
  BOOL default_port =
      ([scheme isEqualToString:@"http"] && port.integerValue == 80) ||
      ([scheme isEqualToString:@"https"] && port.integerValue == 443);
  return port != nil && !default_port
      ? [NSString stringWithFormat:@"%@://%@:%@", scheme, host, port]
      : [NSString stringWithFormat:@"%@://%@", scheme, host];
}

NSString *SnapshotStringAt(NSArray *strings, id index_value) {
  if (![index_value respondsToSelector:@selector(integerValue)]) {
    return @"";
  }
  NSInteger index = [index_value integerValue];
  return index >= 0 && index < (NSInteger)strings.count &&
                 [strings[index] isKindOfClass:NSString.class]
      ? strings[index]
      : @"";
}

id SnapshotArrayValue(NSArray *values, NSInteger index) {
  return index >= 0 && index < (NSInteger)values.count
      ? values[index]
      : nil;
}

NSString *SnapshotElementID(NSArray *backend_ids, NSInteger node_index) {
  id value = SnapshotArrayValue(backend_ids, node_index);
  if (![value isKindOfClass:NSNumber.class] ||
      !std::isfinite([value doubleValue]) ||
      [value doubleValue] != [value longLongValue] ||
      [value longLongValue] <= 0 || [value longLongValue] > INT32_MAX) {
    return nil;
  }
  return [NSString stringWithFormat:@"cef-%lld", [value longLongValue]];
}

NSString *SnapshotShortLabel(NSString *label) {
  NSString *trimmed = [(label ?: @"") stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return trimmed.length > 160
      ? [trimmed substringWithRange:[trimmed rangeOfComposedCharacterSequencesForRange:
          NSMakeRange(0, 160)]]
      : trimmed;
}

id SnapshotRareValue(NSDictionary *rare, NSInteger node_index) {
  NSArray *indices = [rare[@"index"] isKindOfClass:NSArray.class]
      ? rare[@"index"]
      : @[];
  NSArray *values = [rare[@"value"] isKindOfClass:NSArray.class]
      ? rare[@"value"]
      : @[];
  NSUInteger position =
      [indices indexOfObjectPassingTest:^BOOL(
          id value, NSUInteger unused, BOOL *stop) {
        return [value respondsToSelector:@selector(integerValue)] &&
               [value integerValue] == node_index;
      }];
  return position == NSNotFound ? nil : SnapshotArrayValue(values, position);
}

NSDictionary<NSString *, NSString *> *SnapshotAttributes(
    NSDictionary *nodes,
    NSArray *strings,
    NSInteger node_index) {
  NSArray *all_attributes =
      [nodes[@"attributes"] isKindOfClass:NSArray.class]
          ? nodes[@"attributes"]
          : @[];
  NSArray *attribute_indices =
      [SnapshotArrayValue(all_attributes, node_index)
          isKindOfClass:NSArray.class]
          ? SnapshotArrayValue(all_attributes, node_index)
          : @[];
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  for (NSUInteger index = 0; index + 1 < attribute_indices.count; index += 2) {
    NSString *name =
        SnapshotStringAt(strings, attribute_indices[index]).lowercaseString;
    if (name.length == 0) {
      continue;
    }
    attributes[name] =
        SnapshotStringAt(strings, attribute_indices[index + 1]);
  }
  return attributes;
}

NSString *SnapshotSafePath(NSString *url_string, NSString *base_url) {
  NSURL *base = [NSURL URLWithString:base_url];
  NSURL *url = [NSURL URLWithString:url_string relativeToURL:base].absoluteURL;
  NSString *origin = SnapshotOrigin(url.absoluteString);
  if (origin.length == 0) {
    return nil;
  }
  NSURLComponents *components =
      [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
  NSString *path = components.percentEncodedPath;
  return path.length == 0 ? @"/" : path;
}

double SnapshotCSSNumber(NSString *value, double fallback) {
  if (value.length == 0) {
    return fallback;
  }
  NSScanner *scanner = [NSScanner scannerWithString:value];
  double parsed = fallback;
  return [scanner scanDouble:&parsed] ? parsed : fallback;
}

bool SnapshotInstructionLike(NSString *text) {
  NSString *lower = text.lowercaseString;
  for (NSString *phrase in @[
         @"ignore previous", @"ignore above", @"system message",
         @"developer message", @"reveal secret", @"api key",
         @"access token", @"disable safety", @"bypass safety",
         @"download", @"upload", @"payment", @"password", @"agent",
         @"忽略之前", @"忽略以上", @"系統訊息", @"系统消息", @"洩露",
         @"泄露", @"停用安全", @"下載", @"下载", @"上傳", @"上传",
         @"付款", @"支付", @"密碼", @"密码", @"代理",
       ]) {
    if ([lower containsString:phrase]) {
      return true;
    }
  }
  return false;
}

// Web document canvas, not the native shell/resize-gap color. Keep this in
// sync with the explicit CEF browser background below.
constexpr uint32_t kBrowserDocumentBackgroundColor = 0xFFFFFFFF;

bool SnapshotParseColor(NSString *css, double rgba[4]) {
  NSString *value =
      [css.lowercaseString stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([value isEqualToString:@"transparent"]) {
    rgba[0] = rgba[1] = rgba[2] = 0;
    rgba[3] = 0;
    return true;
  }
  NSRegularExpression *expression =
      [NSRegularExpression regularExpressionWithPattern:
          @"rgba?\\(\\s*([0-9.]+)[, ]+\\s*([0-9.]+)[, ]+\\s*"
           "([0-9.]+)(?:\\s*[,/]\\s*([0-9.]+))?\\s*\\)"
                                                options:0
                                                  error:nil];
  NSTextCheckingResult *match =
      [expression firstMatchInString:value
                             options:0
                               range:NSMakeRange(0, value.length)];
  if (match == nil) {
    return false;
  }
  for (NSUInteger index = 0; index < 3; ++index) {
    rgba[index] =
        [[value substringWithRange:[match rangeAtIndex:index + 1]]
            doubleValue] / 255.0;
  }
  rgba[3] = [match rangeAtIndex:4].location == NSNotFound
      ? 1.0
      : [[value substringWithRange:[match rangeAtIndex:4]] doubleValue];
  return true;
}

double SnapshotLinearColor(double value) {
  return value <= 0.04045 ? value / 12.92
                          : pow((value + 0.055) / 1.055, 2.4);
}

double SnapshotContrast(NSString *foreground,
                        NSString *background,
                        double text_opacity) {
  double fg[4];
  double bg[4];
  if (!SnapshotParseColor(foreground, fg) ||
      !SnapshotParseColor(background, bg)) {
    return 21.0;
  }
  // DOMSnapshot's blended background can still be transparent: composite it
  // onto the same opaque canvas CEF actually paints before measuring contrast.
  const double background_alpha = std::clamp(bg[3], 0.0, 1.0);
  for (NSUInteger index = 0; index < 3; ++index) {
    const double canvas =
        ((kBrowserDocumentBackgroundColor >> (16 - 8 * index)) & 0xFF) / 255.0;
    bg[index] = bg[index] * background_alpha + canvas * (1.0 - background_alpha);
  }
  double alpha = std::clamp(fg[3] * text_opacity, 0.0, 1.0);
  double composite[3];
  for (NSUInteger index = 0; index < 3; ++index) {
    composite[index] = fg[index] * alpha + bg[index] * (1.0 - alpha);
  }
  auto luminance = [](double color[3]) {
    return 0.2126 * SnapshotLinearColor(color[0]) +
           0.7152 * SnapshotLinearColor(color[1]) +
           0.0722 * SnapshotLinearColor(color[2]);
  };
  double fg_luminance = luminance(composite);
  double bg_luminance = luminance(bg);
  return (std::max(fg_luminance, bg_luminance) + 0.05) /
         (std::min(fg_luminance, bg_luminance) + 0.05);
}

NSMutableDictionary *SnapshotExcludedCounts() {
  return [@{
    @"crossOriginFrames": @0,
    @"hidden": @0,
    @"ariaHidden": @0,
    @"opacity": @0,
    @"tinyText": @0,
    @"offscreen": @0,
    @"clipped": @0,
    @"occluded": @0,
    @"lowContrast": @0,
    @"sensitiveFields": @0,
    @"instructionLike": @0,
    @"unicodeScalars": @0,
    @"truncatedBlocks": @0,
    @"truncatedLinks": @0,
    @"truncatedForms": @0,
  } mutableCopy];
}

void SnapshotIncrement(NSMutableDictionary *counts, NSString *key) {
  counts[key] = @([counts[key] integerValue] + 1);
}

bool SnapshotNodeHasHiddenAncestor(
    NSInteger node_index,
    NSDictionary *nodes,
    NSArray *strings,
    NSArray *parents,
    NSString **reason) {
  std::set<NSInteger> visited;
  while (node_index >= 0 && visited.find(node_index) == visited.end()) {
    visited.insert(node_index);
    NSDictionary *attributes =
        SnapshotAttributes(nodes, strings, node_index);
    if (attributes[@"hidden"] != nil || attributes[@"inert"] != nil) {
      *reason = @"hidden";
      return true;
    }
    NSString *aria_hidden = attributes[@"aria-hidden"];
    if ([aria_hidden.lowercaseString isEqualToString:@"true"]) {
      *reason = @"ariaHidden";
      return true;
    }
    id parent = SnapshotArrayValue(parents, node_index);
    node_index = [parent respondsToSelector:@selector(integerValue)]
        ? [parent integerValue]
        : -1;
  }
  return false;
}

bool SnapshotNodeRelated(NSInteger first,
                         NSInteger second,
                         NSArray *parents) {
  auto is_ancestor = ^bool(NSInteger ancestor, NSInteger child) {
    std::set<NSInteger> visited;
    while (child >= 0 && visited.find(child) == visited.end()) {
      if (child == ancestor) {
        return true;
      }
      visited.insert(child);
      id parent = SnapshotArrayValue(parents, child);
      child = [parent respondsToSelector:@selector(integerValue)]
          ? [parent integerValue]
          : -1;
    }
    return false;
  };
  return is_ancestor(first, second) || is_ancestor(second, first);
}

NSString *BuildVisibleSnapshotJSON(NSDictionary *result,
                                   NSString *committed_url,
                                   uint64_t navigation_generation,
                                   NSSize viewport_size,
                                   NSString **error_code) {
  NSArray *strings = [result[@"strings"] isKindOfClass:NSArray.class]
      ? result[@"strings"]
      : nil;
  NSArray *documents = [result[@"documents"] isKindOfClass:NSArray.class]
      ? result[@"documents"]
      : nil;
  NSString *committed_origin = SnapshotOrigin(committed_url);
  if (strings == nil || documents.count == 0) {
    *error_code = @"snapshot_parse_failed";
    return nil;
  }
  NSDictionary *document =
      [documents.firstObject isKindOfClass:NSDictionary.class]
          ? documents.firstObject
          : nil;
  NSString *document_url =
      SnapshotStringAt(strings, document[@"documentURL"]);
  if (document == nil || committed_origin.length == 0 ||
      ![SnapshotOrigin(document_url) isEqualToString:committed_origin] ||
      navigation_generation == 0) {
    *error_code = @"navigation_binding_unavailable";
    return nil;
  }
  NSDictionary *nodes =
      [document[@"nodes"] isKindOfClass:NSDictionary.class]
          ? document[@"nodes"]
          : nil;
  NSDictionary *layout =
      [document[@"layout"] isKindOfClass:NSDictionary.class]
          ? document[@"layout"]
          : nil;
  NSArray *layout_nodes =
      [layout[@"nodeIndex"] isKindOfClass:NSArray.class]
          ? layout[@"nodeIndex"]
          : nil;
  NSArray *bounds = [layout[@"bounds"] isKindOfClass:NSArray.class]
      ? layout[@"bounds"]
      : nil;
  NSArray *styles = [layout[@"styles"] isKindOfClass:NSArray.class]
      ? layout[@"styles"]
      : nil;
  NSArray *parents = [nodes[@"parentIndex"] isKindOfClass:NSArray.class]
      ? nodes[@"parentIndex"]
      : nil;
  if (nodes == nil || layout_nodes == nil || bounds == nil ||
      styles == nil || parents == nil) {
    *error_code = @"snapshot_parse_failed";
    return nil;
  }

  NSArray *node_names = [nodes[@"nodeName"] isKindOfClass:NSArray.class]
      ? nodes[@"nodeName"]
      : @[];
  NSArray *backend_ids =
      [nodes[@"backendNodeId"] isKindOfClass:NSArray.class]
          ? nodes[@"backendNodeId"]
          : @[];
  NSArray *layout_text = [layout[@"text"] isKindOfClass:NSArray.class]
      ? layout[@"text"]
      : @[];
  NSArray *paint_orders =
      [layout[@"paintOrders"] isKindOfClass:NSArray.class]
          ? layout[@"paintOrders"]
          : @[];
  NSArray *blended_backgrounds =
      [layout[@"blendedBackgroundColors"] isKindOfClass:NSArray.class]
          ? layout[@"blendedBackgroundColors"]
          : @[];
  NSArray *text_opacities =
      [layout[@"textColorOpacities"] isKindOfClass:NSArray.class]
          ? layout[@"textColorOpacities"]
          : @[];
  NSDictionary *text_boxes =
      [document[@"textBoxes"] isKindOfClass:NSDictionary.class]
          ? document[@"textBoxes"]
          : @{};
  NSArray *text_box_layout_indices =
      [text_boxes[@"layoutIndex"] isKindOfClass:NSArray.class]
          ? text_boxes[@"layoutIndex"]
          : @[];
  NSArray *text_box_bounds =
      [text_boxes[@"bounds"] isKindOfClass:NSArray.class]
          ? text_boxes[@"bounds"]
          : @[];
  double scroll_x = [document[@"scrollOffsetX"] doubleValue];
  double scroll_y = [document[@"scrollOffsetY"] doubleValue];
  double viewport_width = std::max(1.0, viewport_size.width);
  double viewport_height = std::max(1.0, viewport_size.height);
  NSRect viewport =
      NSMakeRect(scroll_x, scroll_y, viewport_width, viewport_height);

  NSMutableDictionary<NSNumber *, NSNumber *> *node_to_layout =
      [NSMutableDictionary dictionary];
  for (NSUInteger row = 0; row < layout_nodes.count; ++row) {
    node_to_layout[@([layout_nodes[row] integerValue])] = @(row);
  }
  auto style_for = ^NSString *(NSInteger node_index, NSUInteger slot) {
    NSNumber *row_number = node_to_layout[@(node_index)];
    if (row_number == nil) {
      return @"";
    }
    NSArray *row_styles =
        [SnapshotArrayValue(styles, row_number.integerValue)
            isKindOfClass:NSArray.class]
            ? SnapshotArrayValue(styles, row_number.integerValue)
            : @[];
    return SnapshotStringAt(strings, SnapshotArrayValue(row_styles, slot));
  };
  auto cumulative_opacity = ^double(NSInteger node_index) {
    double opacity = 1.0;
    std::set<NSInteger> visited;
    while (node_index >= 0 && visited.find(node_index) == visited.end()) {
      visited.insert(node_index);
      opacity *= std::clamp(
          SnapshotCSSNumber(style_for(node_index, 3), 1.0), 0.0, 1.0);
      id parent = SnapshotArrayValue(parents, node_index);
      node_index = [parent respondsToSelector:@selector(integerValue)]
          ? [parent integerValue]
          : -1;
    }
    return opacity;
  };
  NSMutableSet<NSNumber *> *visible_text_rows = [NSMutableSet set];
  for (NSUInteger index = 0; index < text_box_layout_indices.count &&
       index < text_box_bounds.count; ++index) {
    NSArray *box = [text_box_bounds[index] isKindOfClass:NSArray.class]
        ? text_box_bounds[index] : @[];
    if (box.count < 4) continue;
    NSRect text_rect = NSMakeRect([box[0] doubleValue], [box[1] doubleValue],
        [box[2] doubleValue], [box[3] doubleValue]);
    if (!NSIsEmptyRect(NSIntersectionRect(text_rect, viewport))) {
      [visible_text_rows addObject:@([text_box_layout_indices[index] integerValue])];
    }
  }
  auto has_visible_text_rect = ^bool(NSUInteger layout_row) {
    return [visible_text_rows containsObject:@(layout_row)];
  };

  auto is_occluded = ^bool(NSUInteger row, NSInteger node_index, NSRect rect) {
    if (paint_orders.count != layout_nodes.count) return true;
    NSInteger paint_order = [SnapshotArrayValue(paint_orders, row) integerValue];
    NSRect visible_rect = NSIntersectionRect(rect, viewport);
    NSPoint center = NSMakePoint(NSMidX(visible_rect), NSMidY(visible_rect));
    for (NSUInteger other = 0; other < layout_nodes.count; ++other) {
      if (other == row ||
          [SnapshotArrayValue(paint_orders, other) integerValue] <= paint_order) continue;
      NSArray *other_bounds = [SnapshotArrayValue(bounds, other) isKindOfClass:NSArray.class]
          ? SnapshotArrayValue(bounds, other) : @[];
      if (other_bounds.count < 4) continue;
      NSRect other_rect = NSMakeRect([other_bounds[0] doubleValue], [other_bounds[1] doubleValue],
          [other_bounds[2] doubleValue], [other_bounds[3] doubleValue]);
      NSInteger other_node = [layout_nodes[other] integerValue];
      if (!NSPointInRect(center, other_rect) ||
          SnapshotNodeRelated(node_index, other_node, parents)) continue;
      NSString *hidden_reason = nil;
      if (SnapshotNodeHasHiddenAncestor(other_node, nodes, strings, parents, &hidden_reason) ||
          [style_for(other_node, 0) isEqualToString:@"none"] ||
          [style_for(other_node, 1) isEqualToString:@"hidden"] ||
          cumulative_opacity(other_node) < 0.1) continue;
      double rgba[4];
      BOOL opaque = SnapshotParseColor(style_for(other_node, 6), rgba) && rgba[3] >= 0.9;
      NSString *other_name = SnapshotStringAt(strings,
          SnapshotArrayValue(node_names, other_node)).uppercaseString;
      if (opaque || [@[@"IMG", @"CANVAS", @"VIDEO", @"IFRAME"] containsObject:other_name]) return true;
    }
    return false;
  };

  NSMutableDictionary *counts = SnapshotExcludedCounts();
  counts[@"crossOriginFrames"] = @(MAX(0, (NSInteger)documents.count - 1));
  NSMutableSet<NSString *> *risk_flags = [NSMutableSet set];
  if (documents.count > 1) {
    [risk_flags addObject:@"crossOriginFrameExcluded"];
  }
  if (paint_orders.count != layout_nodes.count) {
    [risk_flags addObject:@"occlusionUnverified"];
  }
  NSMutableArray *blocks = [NSMutableArray array];
  NSMutableArray *links = [NSMutableArray array];
  NSMutableArray *controls = [NSMutableArray array];
  NSMutableDictionary<NSNumber *, NSMutableString *> *visible_labels =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSMutableDictionary *> *elements_by_node =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSNumber *> *label_targets =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSMutableDictionary *> *forms_by_id =
      [NSMutableDictionary dictionary];
  NSUInteger emitted_text_bytes = 0;
  NSUInteger emitted_fields = 0;

  for (NSUInteger row = 0; row < layout_nodes.count; ++row) {
    NSInteger node_index = [layout_nodes[row] integerValue];
    NSArray *raw_bounds =
        [SnapshotArrayValue(bounds, row) isKindOfClass:NSArray.class]
            ? SnapshotArrayValue(bounds, row)
            : @[];
    if (raw_bounds.count < 4) {
      SnapshotIncrement(counts, @"clipped");
      continue;
    }
    NSRect rect = NSMakeRect(
        [raw_bounds[0] doubleValue], [raw_bounds[1] doubleValue],
        [raw_bounds[2] doubleValue], [raw_bounds[3] doubleValue]);
    NSString *hidden_reason = nil;
    if (SnapshotNodeHasHiddenAncestor(
            node_index, nodes, strings, parents, &hidden_reason)) {
      SnapshotIncrement(counts, hidden_reason);
      continue;
    }
    NSString *display = style_for(node_index, 0).lowercaseString;
    NSString *visibility = style_for(node_index, 1).lowercaseString;
    NSString *content_visibility =
        style_for(node_index, 2).lowercaseString;
    if ([display isEqualToString:@"none"] ||
        (![visibility isEqualToString:@"visible"] &&
         visibility.length > 0) ||
        [content_visibility isEqualToString:@"hidden"]) {
      SnapshotIncrement(counts, @"hidden");
      continue;
    }
    double opacity = cumulative_opacity(node_index);
    if (opacity < 0.1) {
      SnapshotIncrement(counts, @"opacity");
      continue;
    }
    if (rect.size.width <= 0 || rect.size.height <= 0 ||
        fabs(rect.origin.x) > 1000000 || fabs(rect.origin.y) > 1000000) {
      SnapshotIncrement(counts, @"clipped");
      continue;
    }
    NSString *clip = style_for(node_index, 7).lowercaseString;
    NSString *clip_path = style_for(node_index, 8).lowercaseString;
    if ([clip containsString:@"rect(0"] ||
        [clip_path containsString:@"inset(50%"] ||
        [clip_path containsString:@"circle(0"]) {
      SnapshotIncrement(counts, @"clipped");
      continue;
    }
    NSRect intersection = NSIntersectionRect(rect, viewport);
    if (NSIsEmptyRect(intersection)) {
      SnapshotIncrement(counts, @"offscreen");
      continue;
    }

    NSString *node_name =
        SnapshotStringAt(
            strings, SnapshotArrayValue(node_names, node_index))
            .uppercaseString;
    NSDictionary *attributes =
        SnapshotAttributes(nodes, strings, node_index);
    NSString *backend_id = SnapshotElementID(backend_ids, node_index);
    NSDictionary *safe_rect = @{
      @"x": @(rect.origin.x - scroll_x),
      @"y": @(rect.origin.y - scroll_y),
      @"width": @(rect.size.width),
      @"height": @(rect.size.height),
    };
    NSString *text =
        SnapshotStringAt(strings, SnapshotArrayValue(layout_text, row));
    const bool actionable = [@[@"A", @"INPUT", @"TEXTAREA", @"SELECT", @"BUTTON", @"SUMMARY"]
        containsObject:node_name] || [attributes[@"role"] isEqualToString:@"button"];
    const bool node_occluded = (actionable || text.length > 0 || [node_name isEqualToString:@"IMG"])
        && is_occluded(row, node_index, rect);
    // Never turn editable contents into readable text or button labels.
    NSInteger text_ancestor = node_index;
    std::set<NSInteger> text_ancestors;
    while (text_ancestor >= 0 &&
           text_ancestors.insert(text_ancestor).second) {
      NSString *ancestor_name = SnapshotStringAt(
          strings, SnapshotArrayValue(node_names, text_ancestor)).uppercaseString;
      NSDictionary *ancestor_attributes =
          SnapshotAttributes(nodes, strings, text_ancestor);
      NSString *editable = ancestor_attributes[@"contenteditable"];
      if ([@[@"INPUT", @"TEXTAREA", @"SELECT"] containsObject:ancestor_name] ||
          (editable != nil && ![editable.lowercaseString isEqualToString:@"false"])) {
        text = @"";
        SnapshotIncrement(counts, @"sensitiveFields");
        break;
      }
      id parent = SnapshotArrayValue(parents, text_ancestor);
      text_ancestor = [parent respondsToSelector:@selector(integerValue)]
          ? [parent integerValue] : -1;
    }
    NSString *kind = @"text";
    if ([node_name isEqualToString:@"IMG"]) {
      text = attributes[@"alt"] ?: @"";
      kind = @"alt";
      if (text.length > 160 || SnapshotInstructionLike(text)) {
        if (text.length > 0) {
          SnapshotIncrement(counts, @"instructionLike");
          [risk_flags addObject:@"instructionLikeContent"];
        }
        text = @"";
      }
    }
    BOOL text_rect_verified =
        [kind isEqualToString:@"alt"] || text.length == 0 ||
        has_visible_text_rect(row);
    if (!text_rect_verified) {
      SnapshotIncrement(counts, @"clipped");
      text = @"";
    }
    if (text.length > 0) {
      if (SnapshotCSSNumber(style_for(node_index, 4), 16.0) < 2.0) {
        SnapshotIncrement(counts, @"tinyText");
      } else {
        NSString *foreground = style_for(node_index, 5);
        NSString *background =
            SnapshotStringAt(
                strings, SnapshotArrayValue(blended_backgrounds, row));
        if (background.length == 0) {
          background = style_for(node_index, 6);
        }
        double text_opacity =
            [SnapshotArrayValue(text_opacities, row)
                    respondsToSelector:@selector(doubleValue)]
                ? [SnapshotArrayValue(text_opacities, row) doubleValue]
                : 1.0;
        double contrast =
            SnapshotContrast(foreground, background, text_opacity);
        bool low_contrast = contrast < 3.0;
        bool quarantined = node_occluded;
        if (contrast < 1.5) {
          SnapshotIncrement(counts, @"lowContrast");
          [risk_flags addObject:@"lowContrastContentExcluded"];
          quarantined = true;
        } else if (low_contrast) {
          SnapshotIncrement(counts, @"lowContrast");
          [risk_flags addObject:@"lowContrastContentExcluded"];
          quarantined = true;
        }
        if (node_occluded) SnapshotIncrement(counts, @"occluded");
        NSUInteger text_bytes =
            [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (blocks.count >= 2000 ||
            emitted_text_bytes + text_bytes > 256 * 1024) {
          SnapshotIncrement(counts, @"truncatedBlocks");
          [risk_flags addObject:@"truncated"];
        } else {
          emitted_text_bytes += text_bytes;
          [blocks addObject:@{
            @"elementID": backend_id ?:
                [NSString stringWithFormat:@"text-%ld", (long)node_index],
            @"text": text,
            @"kind": kind,
            @"sourceOrigin": committed_origin,
            @"rect": safe_rect,
            @"lowContrast": @(low_contrast),
            @"quarantined": @(quarantined),
          }];
          if (!quarantined) {
            // Walk ancestors of already-admitted text once; never scan raw
            // nodeValue, form values, or the whole DOM again for each button.
            NSInteger ancestor = node_index;
            std::set<NSInteger> visited;
            while (ancestor >= 0 && visited.insert(ancestor).second) {
              NSString *name = SnapshotStringAt(
                  strings, SnapshotArrayValue(node_names, ancestor)).uppercaseString;
              NSDictionary *attrs = SnapshotAttributes(nodes, strings, ancestor);
              if ([@[@"A", @"BUTTON", @"LABEL", @"SUMMARY"] containsObject:name] ||
                  [attrs[@"role"] isEqualToString:@"button"]) {
                NSMutableString *label = visible_labels[@(ancestor)];
                if (label == nil) {
                  label = [NSMutableString string];
                  visible_labels[@(ancestor)] = label;
                }
                if (label.length < 160) {
                  if (label.length > 0) [label appendString:@" "];
                  [label appendString:SnapshotShortLabel(text)];
                }
                if ([name isEqualToString:@"LABEL"] &&
                    [attrs[@"for"] length] > 0) {
                  label_targets[attrs[@"for"]] = @(ancestor);
                }
              }
              id parent = SnapshotArrayValue(parents, ancestor);
              ancestor = [parent respondsToSelector:@selector(integerValue)]
                  ? [parent integerValue] : -1;
            }
          }
        }
      }
    }

    if (node_occluded) continue;
    if (backend_id == nil) {
      // Node-array offsets are not CDP backendNodeIds and cannot be selectors.
      [risk_flags addObject:@"elementIdentityUnavailable"];
      continue;
    }
    if ([node_name isEqualToString:@"A"]) {
      NSString *href = attributes[@"href"];
      NSString *destination_origin =
          SnapshotOrigin(
              [NSURL URLWithString:href relativeToURL:
                  [NSURL URLWithString:document_url]].absoluteURL
                  .absoluteString);
      NSString *path = SnapshotSafePath(href, document_url);
      if (destination_origin.length > 0 && path.length > 0) {
        NSString *label = text.length > 0
            ? text
            : (attributes[@"aria-label"] ?: attributes[@"title"] ?: @"");
        if (links.count >= 512) {
          SnapshotIncrement(counts, @"truncatedLinks");
          [risk_flags addObject:@"truncated"];
        } else {
          NSMutableDictionary *link = [@{
            @"elementID": backend_id,
            @"label": SnapshotShortLabel(label),
            @"sourceOrigin": committed_origin,
            @"destinationOrigin": destination_origin,
            @"destinationPath": path,
            @"rect": safe_rect,
          } mutableCopy];
          [links addObject:link];
          elements_by_node[@(node_index)] = link;
        }
      }
    }

    if ([@[@"INPUT", @"TEXTAREA", @"SELECT", @"BUTTON"]
            containsObject:node_name]) {
      NSString *type = [attributes[@"type"] lowercaseString];
      if (type.length == 0) {
        type = [node_name isEqualToString:@"INPUT"] ? @"text" :
            ([node_name isEqualToString:@"BUTTON"] ? @"submit" : node_name.lowercaseString);
      }
      NSString *label =
          attributes[@"aria-label"] ?: attributes[@"placeholder"] ?:
          attributes[@"title"] ?: @"";
      NSString *sensitive_probe =
          [NSString stringWithFormat:@"%@ %@ %@ %@ %@",
              type, attributes[@"autocomplete"] ?: @"", label,
              attributes[@"name"] ?: @"", attributes[@"id"] ?: @""]
              .lowercaseString;
      BOOL sensitive =
          [sensitive_probe containsString:@"password"] ||
          [sensitive_probe containsString:@"one-time"] ||
          [sensitive_probe containsString:@"otp"] ||
          [sensitive_probe containsString:@"cc-"] ||
          [sensitive_probe containsString:@"credit"] ||
          [sensitive_probe containsString:@"card number"] ||
          [sensitive_probe containsString:@"security code"] ||
          [sensitive_probe containsString:@"token"];
      NSInteger form_node = node_index;
      std::set<NSInteger> form_ancestors;
      while (form_node >= 0 && form_ancestors.insert(form_node).second) {
        NSString *ancestor_name =
            SnapshotStringAt(
                strings, SnapshotArrayValue(node_names, form_node))
                .uppercaseString;
        if ([ancestor_name isEqualToString:@"FORM"]) {
          break;
        }
        id parent = SnapshotArrayValue(parents, form_node);
        form_node = [parent respondsToSelector:@selector(integerValue)]
            ? [parent integerValue]
            : -1;
      }
      NSString *form_id = SnapshotElementID(backend_ids, form_node) ?:
          [NSString stringWithFormat:@"implicit-%@", backend_id];
      if (emitted_fields >= 512) {
        SnapshotIncrement(counts, @"truncatedForms");
        [risk_flags addObject:@"truncated"];
        continue;
      }
      NSMutableDictionary *form = forms_by_id[form_id];
      if (form == nil) {
        if (forms_by_id.count >= 32) {
          SnapshotIncrement(counts, @"truncatedForms");
          [risk_flags addObject:@"truncated"];
          continue;
        }
        NSDictionary *form_attributes = form_node >= 0
            ? SnapshotAttributes(nodes, strings, form_node)
            : @{};
        NSString *action_url =
            [NSURL URLWithString:form_attributes[@"action"] ?: document_url
                  relativeToURL:[NSURL URLWithString:document_url]]
                .absoluteURL.absoluteString;
        form = [@{
          @"elementID": form_id,
          @"sourceOrigin": committed_origin,
          @"actionOrigin": SnapshotOrigin(action_url) ?: committed_origin,
          @"method":
              [(form_attributes[@"method"] ?: @"GET") uppercaseString],
          @"fields": [NSMutableArray array],
          @"rect": safe_rect,
        } mutableCopy];
        forms_by_id[form_id] = form;
      }
      NSMutableDictionary *field = [@{
        @"elementID": backend_id,
        @"type": type,
        @"label": SnapshotShortLabel(label),
        @"sensitive": @(sensitive),
        @"disabled": @(attributes[@"disabled"] != nil ||
            [attributes[@"aria-disabled"] isEqualToString:@"true"]),
        @"readOnly": @(attributes[@"readonly"] != nil),
        @"rect": safe_rect,
      } mutableCopy];
      [form[@"fields"] addObject:field];
      ++emitted_fields;
      elements_by_node[@(node_index)] = field;
    }
    NSString *input_type = [attributes[@"type"] lowercaseString];
    if ([node_name isEqualToString:@"BUTTON"] ||
        [node_name isEqualToString:@"SELECT"] ||
        [attributes[@"draggable"] isEqualToString:@"true"] ||
        [node_name isEqualToString:@"SUMMARY"] ||
        [attributes[@"role"] isEqualToString:@"button"] ||
        ([node_name isEqualToString:@"INPUT"] &&
         [@[@"submit", @"button", @"reset", @"checkbox", @"radio"]
             containsObject:input_type])) {
      if (controls.count >= 512) {
        [risk_flags addObject:@"truncated"];
      } else {
        NSMutableDictionary *control = elements_by_node[@(node_index)];
        if (control == nil) {
          control = [@{
            @"elementID": backend_id,
            @"label": SnapshotShortLabel(attributes[@"aria-label"] ?:
                attributes[@"title"]),
            @"rect": safe_rect,
            @"disabled": @(attributes[@"disabled"] != nil ||
                [attributes[@"aria-disabled"] isEqualToString:@"true"]),
          } mutableCopy];
          elements_by_node[@(node_index)] = control;
        }
        control[@"kind"] = [@[@"checkbox", @"radio"] containsObject:input_type]
            ? input_type : [node_name isEqualToString:@"SELECT"] ? @"select"
            : [attributes[@"draggable"] isEqualToString:@"true"] ? @"draggable" : @"button";
        [controls addObject:control];
      }
    }
  }

  for (NSNumber *node_number in elements_by_node) {
    NSMutableDictionary *element = elements_by_node[node_number];
    NSInteger node_index = node_number.integerValue;
    NSString *label = [element[@"label"] length] > 0
        ? element[@"label"] : visible_labels[node_number];
    NSDictionary *attributes = SnapshotAttributes(nodes, strings, node_index);
    if (label.length == 0) {
      NSNumber *label_node = label_targets[attributes[@"id"] ?: @""];
      if (label_node != nil) label = visible_labels[label_node];
    }
    if (label.length == 0) {
      // A wrapping LABEL can describe an input without an HTML id.
      NSInteger ancestor = [SnapshotArrayValue(parents, node_index) integerValue];
      std::set<NSInteger> visited;
      while (ancestor >= 0 && visited.insert(ancestor).second) {
        NSString *name = SnapshotStringAt(
            strings, SnapshotArrayValue(node_names, ancestor)).uppercaseString;
        if ([name isEqualToString:@"LABEL"]) {
          label = visible_labels[@(ancestor)];
          break;
        }
        id parent = SnapshotArrayValue(parents, ancestor);
        ancestor = [parent respondsToSelector:@selector(integerValue)]
            ? [parent integerValue] : -1;
      }
    }
    if (label.length == 0) label = attributes[@"name"] ?: @"";
    element[@"label"] = SnapshotShortLabel(label);
    if (element[@"sensitive"] != nil) {
      NSString *probe = label.lowercaseString;
      for (NSString *phrase in @[@"password", @"one-time", @"otp", @"cc-",
            @"credit", @"card number", @"security code", @"token"]) {
        if ([probe containsString:phrase]) element[@"sensitive"] = @YES;
      }
    }
  }
  NSArray *sorted_flags =
      [risk_flags.allObjects sortedArrayUsingSelector:
          @selector(compare:)];
  NSDictionary *snapshot = @{
    @"schema": @"TatwoCEFVisibleSnapshotV1",
    @"origin": committed_origin,
    @"title": SnapshotShortLabel(SnapshotStringAt(strings, document[@"title"])),
    @"navigationGeneration": @(navigation_generation),
    @"viewport": @{
      @"width": @(viewport_width),
      @"height": @(viewport_height),
      @"scrollX": @(scroll_x),
      @"scrollY": @(scroll_y),
    },
    @"blocks": blocks,
    @"links": links,
    @"controls": controls,
    @"forms": forms_by_id.allValues,
    @"excludedCounts": counts,
    @"riskFlags": sorted_flags,
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  if (json == nil) {
    *error_code = @"snapshot_parse_failed";
    return nil;
  }
  return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

struct BrowserState;

void PublishVisibleError(TatwoCEFBrowserView *view,
                         NSString *message,
                         TatwoCEFBrowserErrorKind kind,
                         NSInteger code,
                         TatwoCEFBrowserPhase phase);
void PublishResourceError(TatwoCEFBrowserView *view,
                          ResourceErrorContext context,
                          NSString *message,
                          bool dns_failure = false);
void PublishState(TatwoCEFBrowserView *view);
void UpdateLoadingState(TatwoCEFBrowserView *view, bool is_loading);
void PublishMainFrameLoadStart(TatwoCEFBrowserView *view);
void PublishMainFrameLoadEnd(TatwoCEFBrowserView *view,
                             CefRefPtr<CefFrame> frame,
                             int http_status_code);
void PublishMainFrameCommit(TatwoCEFBrowserView *view,
                            const CefString &url);
void InvalidateSecurityDocumentEpoch(TatwoCEFBrowserView *view,
                                     NSString *reason);
bool HasVisibleSecurityError(TatwoCEFBrowserView *view);
void CompleteBrowserClose(TatwoCEFBrowserView *view, BrowserState *state);
void DriveBrowserClose(TatwoCEFBrowserView *view,
                       BrowserState *state,
                       uint64_t generation);
void LogBrowserEmbeddingSnapshot(TatwoCEFBrowserView *view,
                                 CefRefPtr<CefBrowser> browser,
                                 NSString *phase,
                                 bool force);
void SynchronizeBrowserGeometry(TatwoCEFBrowserView *view,
                                CefRefPtr<CefBrowser> browser);
void RequestBrowserCompositorDisplay(TatwoCEFBrowserView *view,
                                     CefRefPtr<CefBrowser> browser,
                                     NSString *reason);
uint64_t BeginNavigationFrameTelemetry(TatwoCEFBrowserView *view,
                                       BrowserState *state,
                                       NSString *reason);
void BeginRendererNavigationIfNeeded(TatwoCEFBrowserView *view);
void FinishNavigationFrameTelemetry(TatwoCEFBrowserView *view);
void InvalidateWebMCPForRendererTermination(
    TatwoCEFBrowserView *view);
bool IsActiveMountCallback(TatwoCEFBrowserView *view,
                           uint64_t expected_generation,
                           NSString *event);
bool IsPermissionReplyLive(TatwoCEFBrowserView *view, uint64_t expected_mount, uint64_t expected_navigation_generation);
void StartLoadingActiveMessagePump(TatwoCEFBrowserView *view,
                                   uint64_t expected_generation,
                                   NSString *reason);
void StopLoadingActiveMessagePump(TatwoCEFBrowserView *view,
                                  uint64_t expected_generation,
                                  NSString *reason);

constexpr NSUInteger kCEFEmbeddingTelemetryMaximumLineLength = 4096;
constexpr int64_t kCEFMessagePumpSummaryMinimumIntervalMilliseconds = 5000;
constexpr uint64_t kCEFMessagePumpSummaryMinimumEventDelta = 128;
constexpr int64_t kCEFLoadingActivePumpIntervalMilliseconds = 1000 / 30;
constexpr NSUInteger kCEFBrowserCloseMaximumAttempts = 64;
constexpr int64_t kCEFBrowserCloseRetryDelayMilliseconds = 100;

dispatch_queue_t CEFEmbeddingTelemetryQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    queue = dispatch_queue_create(
        "com.tatwo.ultrawork.cef.embedding-telemetry",
        DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

int64_t MonotonicMilliseconds() {
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return static_cast<int64_t>(now.tv_sec) * 1000 +
         static_cast<int64_t>(now.tv_nsec / 1000000);
}

NSString *SanitizeTelemetryToken(NSString *value, NSString *fallback) {
  if (value.length == 0) {
    return fallback;
  }
  static NSCharacterSet *allowed;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
             "0123456789._->,"];
  });
  NSMutableString *sanitized =
      [NSMutableString stringWithCapacity:value.length];
  for (NSUInteger index = 0; index < value.length; ++index) {
    unichar character = [value characterAtIndex:index];
    [sanitized appendString:
        [allowed characterIsMember:character]
            ? [NSString stringWithCharacters:&character length:1]
            : @"_"];
  }
  return sanitized.length > 0 ? sanitized : fallback;
}

NSString *TelemetryRect(NSRect rect) {
  return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                                    rect.origin.x,
                                    rect.origin.y,
                                    rect.size.width,
                                    rect.size.height];
}

void ConfigureCEFEmbeddingTelemetry(NSString *cef_log_file_path) {
  // The dedicated append-only file must remain beside CEF's configured log.
  // Never infer a user home, profile path, or staging root independently.
  if (cef_log_file_path.length == 0 ||
      !cef_log_file_path.isAbsolutePath) {
    g_embedding_telemetry_path = nil;
    return;
  }
  NSString *log_directory =
      cef_log_file_path.stringByDeletingLastPathComponent
          .stringByStandardizingPath;
  if (log_directory.length == 0 || !log_directory.isAbsolutePath) {
    g_embedding_telemetry_path = nil;
    return;
  }
  g_embedding_telemetry_path =
      [[log_directory
          stringByAppendingPathComponent:@"cef-embedding-telemetry.log"]
          copy];
  setenv("TATWO_CEF_EMBEDDING_TELEMETRY_PATH",
         g_embedding_telemetry_path.fileSystemRepresentation,
         1);
}

int OpenCEFEmbeddingTelemetryDescriptor(NSString *path) {
  if (path.length == 0) {
    return -1;
  }
  const int descriptor = open(
      path.fileSystemRepresentation,
      O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    return -1;
  }
  struct stat file_status {};
  if (fstat(descriptor, &file_status) != 0 ||
      !S_ISREG(file_status.st_mode)) {
    close(descriptor);
    return -1;
  }
  return descriptor;
}

void WriteCEFEmbeddingTelemetryPayloadToDescriptor(
    int descriptor,
    NSData *payload) {
  if (descriptor < 0 || payload.length == 0) {
    return;
  }
  const uint8_t *bytes =
      static_cast<const uint8_t *>(payload.bytes);
  size_t remaining = payload.length;
  while (remaining > 0) {
    const ssize_t written = write(descriptor, bytes, remaining);
    if (written > 0) {
      bytes += written;
      remaining -= static_cast<size_t>(written);
      continue;
    }
    if (written < 0 && errno == EINTR) {
      continue;
    }
    break;
  }
}

void WriteCEFEmbeddingTelemetryPayload(NSString *path, NSData *payload) {
  if (payload.length == 0) {
    return;
  }
  // O_APPEND gives each bounded single-line record one append position.
  // O_NOFOLLOW and the regular-file check prevent following a replaced leaf.
  const int descriptor = OpenCEFEmbeddingTelemetryDescriptor(path);
  if (descriptor < 0) {
    return;
  }
  WriteCEFEmbeddingTelemetryPayloadToDescriptor(descriptor, payload);
  close(descriptor);
}

NSData *CEFEmbeddingTelemetryPayload(NSString *line) {
  if (line.length == 0) {
    return nil;
  }
  NSCharacterSet *newlines = NSCharacterSet.newlineCharacterSet;
  NSString *single_line =
      [[line componentsSeparatedByCharactersInSet:newlines]
          componentsJoinedByString:@"_"];
  if (single_line.length > kCEFEmbeddingTelemetryMaximumLineLength) {
    single_line =
        [single_line substringToIndex:kCEFEmbeddingTelemetryMaximumLineLength];
  }
  return [[single_line stringByAppendingString:@"\n"]
      dataUsingEncoding:NSUTF8StringEncoding];
}

void AppendCEFEmbeddingTelemetryLineSynchronously(NSString *line) {
  WriteCEFEmbeddingTelemetryPayload(
      [g_embedding_telemetry_path copy],
      CEFEmbeddingTelemetryPayload(line));
}

void AppendCEFEmbeddingTelemetryLine(NSString *line) {
  NSString *path = [g_embedding_telemetry_path copy];
  NSData *payload = CEFEmbeddingTelemetryPayload(line);
  if (path.length == 0 || payload.length == 0) {
    return;
  }
  dispatch_async(CEFEmbeddingTelemetryQueue(), ^{
    WriteCEFEmbeddingTelemetryPayload(path, payload);
  });
}

void RecordHostBlocklistRequest(bool is_main_frame,
                                cef_resource_type_t resource_type) {
  const uint64_t total =
      g_host_blocked_request_count.fetch_add(
          1, std::memory_order_relaxed) + 1;
  const uint64_t main_frames = is_main_frame
      ? g_host_blocked_main_frame_count.fetch_add(
            1, std::memory_order_relaxed) + 1
      : g_host_blocked_main_frame_count.load(
            std::memory_order_relaxed);
  const uint64_t subresources = is_main_frame
      ? g_host_blocked_subresource_count.load(
            std::memory_order_relaxed)
      : g_host_blocked_subresource_count.fetch_add(
            1, std::memory_order_relaxed) + 1;
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=adblock event=request_blocked totalCount=%llu "
           "mainFrameCount=%llu subresourceCount=%llu resourceType=%d",
          total,
          main_frames,
          subresources,
          static_cast<int>(resource_type)]);
}

void LogBrowserLifecycle(NSString *event, NSInteger code = 0) {
  // Lifecycle-only telemetry: never include URL, profile path, cookies, or
  // other session data in this log.
  NSString *safe_event =
      SanitizeTelemetryToken(event, @"unknown");
  NSString *line =
      [NSString stringWithFormat:@"phase=lifecycle event=%@ code=%ld",
                                 safe_event,
                                 (long)code];
  AppendCEFEmbeddingTelemetryLine(line);
  NSLog(@"[TatwoCEF] %@", line);
}

void LogBrowserNavigationTrace(NSString *event,
                               NSInteger code = 0,
                               bool is_loading = false) {
  // Main-frame progress only. Never include URL, page title, profile path,
  // request headers, cookies, user text, or error strings. This bounded trace
  // lets a white/loading surface distinguish host navigation, policy,
  // commit/load callbacks, and a renderer that never reaches completion.
  const uint64_t sequence =
      g_navigation_trace_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=navigation_trace event=%@ sequence=%llu "
           "monotonicMs=%lld code=%ld isLoading=%d",
          SanitizeTelemetryToken(event, @"unknown"),
          sequence,
          MonotonicMilliseconds(),
          (long)code,
          is_loading ? 1 : 0]);
}

void LogBrowserTimeline(NSString *event,
                        uint64_t mount_generation,
                        NSInteger code = 0,
                        bool is_loading = false) {
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=navigation_timeline event=%@ sequence=%llu "
           "monotonicMs=%lld mountGeneration=%llu staleCallbackDrops=%llu "
           "code=%ld isLoading=%d",
          SanitizeTelemetryToken(event, @"unknown"),
          g_navigation_trace_sequence.fetch_add(
              1, std::memory_order_relaxed) + 1,
          MonotonicMilliseconds(),
          mount_generation,
          g_stale_callback_drop_count.load(std::memory_order_relaxed),
          (long)code,
          is_loading ? 1 : 0]);
}

struct CEFHelperRoleTelemetry {
  CEFHelperRole role;
  NSString *token;
};

CEFHelperRoleTelemetry CEFHelperRoleFromCommandLine(
    CefRefPtr<CefCommandLine> command_line) {
  if (!command_line) {
    return {CEFHelperRole::kOther, @"other"};
  }
  NSString *process_type =
      FromCefString(command_line->GetSwitchValue("type")).lowercaseString;
  if ([process_type isEqualToString:@"gpu-process"]) {
    return {CEFHelperRole::kGPU, @"gpu"};
  }
  if ([process_type isEqualToString:@"renderer"]) {
    return {CEFHelperRole::kRenderer, @"renderer"};
  }
  if ([process_type isEqualToString:@"utility"]) {
    NSString *utility_subtype =
        FromCefString(
            command_line->GetSwitchValue("utility-sub-type")).lowercaseString;
    if ([utility_subtype containsString:@"networkservice"]) {
      return {CEFHelperRole::kNetwork, @"utility_network"};
    }
    if ([utility_subtype containsString:@"storageservice"]) {
      return {CEFHelperRole::kStorage, @"utility_storage"};
    }
    return {CEFHelperRole::kUtility, @"utility_other"};
  }
  return {CEFHelperRole::kOther, @"other"};
}

CEFHelperRoleTelemetry CurrentCEFHelperRole() {
  NSString *process_type = nil;
  NSString *utility_subtype = nil;
  const int argument_count = *_NSGetArgc();
  char **arguments = *_NSGetArgv();
  for (int index = 0; index < argument_count; ++index) {
    NSString *argument =
        [NSString stringWithUTF8String:arguments[index]];
    if ([argument hasPrefix:@"--type="]) {
      process_type =
          [[argument substringFromIndex:7] lowercaseString];
    } else if ([argument hasPrefix:@"--utility-sub-type="]) {
      utility_subtype =
          [[argument substringFromIndex:19] lowercaseString];
    }
  }
  if ([process_type isEqualToString:@"gpu-process"]) {
    return {CEFHelperRole::kGPU, @"gpu"};
  }
  if ([process_type isEqualToString:@"renderer"]) {
    return {CEFHelperRole::kRenderer, @"renderer"};
  }
  if ([process_type isEqualToString:@"utility"]) {
    if ([utility_subtype containsString:@"networkservice"]) {
      return {CEFHelperRole::kNetwork, @"utility_network"};
    }
    if ([utility_subtype containsString:@"storageservice"]) {
      return {CEFHelperRole::kStorage, @"utility_storage"};
    }
    return {CEFHelperRole::kUtility, @"utility_other"};
  }
  return {CEFHelperRole::kOther, @"other"};
}

void ConfigureCEFHelperProcessTelemetry(NSString *role) {
  const char *telemetry_path =
      getenv("TATWO_CEF_EMBEDDING_TELEMETRY_PATH");
  if (telemetry_path == nullptr || telemetry_path[0] != '/') {
    return;
  }
  g_embedding_telemetry_path =
      [[NSString stringWithUTF8String:telemetry_path] copy];
  g_helper_telemetry_descriptor =
      OpenCEFEmbeddingTelemetryDescriptor(g_embedding_telemetry_path);
  WriteCEFEmbeddingTelemetryPayloadToDescriptor(
      g_helper_telemetry_descriptor,
      CEFEmbeddingTelemetryPayload(
          [NSString stringWithFormat:
              @"phase=helper_process event=spawn role=%@",
              SanitizeTelemetryToken(role, @"other")]));
}

int CompleteCEFHelperProcessTelemetry(NSString *role, int exit_code) {
  WriteCEFEmbeddingTelemetryPayloadToDescriptor(
      g_helper_telemetry_descriptor,
      CEFEmbeddingTelemetryPayload(
          [NSString stringWithFormat:
              @"phase=helper_process event=exit role=%@ "
               "exitCode=%d signal=0",
              SanitizeTelemetryToken(role, @"other"),
              exit_code]));
  if (g_helper_telemetry_descriptor >= 0) {
    close(g_helper_telemetry_descriptor);
    g_helper_telemetry_descriptor = -1;
  }
  return exit_code;
}

#pragma mark - W60 Bounded renderer health (no page text or error_string)
std::mutex g_w60_health_mutex;
NSMutableArray<NSDictionary *> *g_w60_renderer_terminations;
uint64_t g_w60_renderer_termination_count = 0;

NSString *W60TerminationStatus(CefRequestHandler::TerminationStatus status) {
  switch (status) {
    case TS_ABNORMAL_TERMINATION: return @"TS_ABNORMAL_TERMINATION";
    case TS_PROCESS_WAS_KILLED: return @"TS_PROCESS_WAS_KILLED";
    case TS_PROCESS_CRASHED: return @"TS_PROCESS_CRASHED";
    case TS_PROCESS_OOM: return @"TS_PROCESS_OOM";
    case TS_LAUNCH_FAILED: return @"TS_LAUNCH_FAILED";
    case TS_INTEGRITY_FAILURE: return @"TS_INTEGRITY_FAILURE";
    default: return @"TS_OTHER";
  }
}

void W60RecordRendererTermination(CefRefPtr<CefBrowser> browser,
                                  CefRequestHandler::TerminationStatus status,
                                  int code, uint64_t mount) {
  NSString *host = @"unknown";
  if (browser && browser->GetMainFrame()) {
    NSURLComponents *url = [NSURLComponents componentsWithString:
        FromCefString(browser->GetMainFrame()->GetURL())];
    // Only a host, never userinfo/path/query/fragment or Chromium's error text.
    if (url.host.length > 0) host = SanitizeTelemetryToken(url.host.lowercaseString, @"unknown");
  }
  NSString *reason = W60TerminationStatus(status);
  uint64_t count;
  {
    std::lock_guard<std::mutex> lock(g_w60_health_mutex);
    count = ++g_w60_renderer_termination_count;
    if (!g_w60_renderer_terminations) g_w60_renderer_terminations = [NSMutableArray array];
    [g_w60_renderer_terminations addObject:@{
      @"status": reason, @"code": @(code), @"host": host,
      @"mountGeneration": @(mount), @"time": @([[NSDate date] timeIntervalSince1970])
    }];
    if (g_w60_renderer_terminations.count > 10) [g_w60_renderer_terminations removeObjectAtIndex:0];
  }
  AppendCEFEmbeddingTelemetryLine([NSString stringWithFormat:
      @"phase=renderer_terminated status=%@ statusCode=%d code=%d url=%@ mountGeneration=%llu terminationCallbackCount=%llu",
      reason, static_cast<int>(status), code, host, mount, count]);
}

NSDictionary<NSString *, id> *W60ProcessDiagnostics() {
  std::lock_guard<std::mutex> lock(g_w60_health_mutex);
  return @{
    @"launchCounts": @{
      @"gpu": @(g_helper_role_launch_counts[0].load()),
      @"renderer": @(g_helper_role_launch_counts[1].load()),
      @"network": @(g_helper_role_launch_counts[2].load()),
      @"utility": @(g_helper_role_launch_counts[3].load() + g_helper_role_launch_counts[4].load()),
      @"other": @(g_helper_role_launch_counts[5].load())
    },
    @"terminationCallbackCount": @(g_w60_renderer_termination_count),
    @"recentTerminations": g_w60_renderer_terminations ? [g_w60_renderer_terminations copy] : @[]
  };
}
#pragma mark - W60 End

void LogRendererTermination(CefRequestHandler::TerminationStatus status,
                            int error_code) {
  // Keep renderer diagnostics numeric and session-agnostic. In particular,
  // never emit error_string because Chromium may include page-specific data.
  NSLog(@"[TatwoCEF] lifecycle=renderer_terminated status=%d code=%d",
        static_cast<int>(status), error_code);
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=lifecycle event=renderer_terminated status=%d code=%d",
          static_cast<int>(status),
          error_code]);
}

void MaybeLogMessagePumpSummary(NSString *reason) {
  const uint64_t schedule_count =
      g_message_pump_schedule_count.load(std::memory_order_relaxed);
  const uint64_t do_work_count =
      g_message_pump_do_work_count.load(std::memory_order_relaxed);
  const uint64_t event_count = schedule_count + do_work_count;
  const int64_t now_ms = MonotonicMilliseconds();
  const uint64_t previous_event_count =
      g_message_pump_last_summary_event_count.load(std::memory_order_relaxed);
  const int64_t previous_summary_ms =
      g_message_pump_last_summary_ms.load(std::memory_order_relaxed);
  const bool first_summary = previous_event_count == 0;
  if (!first_summary &&
      (event_count - previous_event_count <
           kCEFMessagePumpSummaryMinimumEventDelta ||
       now_ms - previous_summary_ms <
           kCEFMessagePumpSummaryMinimumIntervalMilliseconds)) {
    return;
  }
  uint64_t expected_event_count = previous_event_count;
  if (!g_message_pump_last_summary_event_count.compare_exchange_strong(
          expected_event_count,
          event_count,
          std::memory_order_relaxed)) {
    return;
  }
  g_message_pump_last_summary_ms.store(now_ms, std::memory_order_relaxed);
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=message_pump_summary reason=%@ scheduleCount=%llu "
           "doWorkCount=%llu lastScheduleMonotonicMs=%lld "
           "lastDoWorkMonotonicMs=%lld requestedDelayMs=%lld "
           "normalizedDelayMs=%lld generation=%llu",
          SanitizeTelemetryToken(reason, @"unknown"),
          schedule_count,
          do_work_count,
          g_message_pump_last_schedule_ms.load(std::memory_order_relaxed),
          g_message_pump_last_do_work_ms.load(std::memory_order_relaxed),
          g_message_pump_last_requested_delay_ms.load(
              std::memory_order_relaxed),
          g_message_pump_last_normalized_delay_ms.load(
              std::memory_order_relaxed),
          g_message_pump_last_generation.load(std::memory_order_relaxed)]);
}

bool CanRunScheduledMessagePump(
    uint64_t scheduled_generation,
    uint64_t current_generation,
    bool initialized,
    bool shutdown) {
  return scheduled_generation == current_generation &&
         initialized &&
         !shutdown;
}

bool CanRunImmediateMessagePump(bool initialized, bool shutdown) {
  return initialized && !shutdown;
}

struct MessagePumpRunResult {
  bool did_run;
  bool should_schedule_follow_up;
};

template <typename Work>
MessagePumpRunResult RunMessagePumpWorkOnMainThread(
    MessagePumpFollowUpGate &gate,
    Work &&work) {
  if (!gate.TryBegin()) {
    return {false, false};
  }
  NSCAssert(NSThread.isMainThread,
            @"CEF message pump work must run on the main thread");
  work();
  return {true, gate.EndAndTakeFollowUp()};
}

template <typename RunNow, typename QueueHostKick>
bool DeliverImmediateMessagePumpWork(
    bool is_main_thread,
    RunNow &&run_now,
    QueueHostKick &&queue_host_kick) {
  if (is_main_thread) {
    run_now();
    return true;
  }
  queue_host_kick();
  return false;
}

template <typename Enqueue>
bool QueueImmediateMessagePumpWork(
    MessagePumpHostKickQueueGate &gate,
    Enqueue &&enqueue) {
  if (!gate.TryQueue()) {
    return false;
  }
  enqueue();
  return true;
}

void ScheduleCEFMessagePumpWork(int64_t delay_ms);

bool RunCEFMessagePumpWorkOnMainThread() {
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load()) {
    return false;
  }
  const MessagePumpRunResult result =
      RunMessagePumpWorkOnMainThread(
          g_message_pump_follow_up_gate, [] {
            CefDoMessageLoopWork();
            g_message_pump_do_work_count.fetch_add(
                1, std::memory_order_relaxed);
            g_message_pump_last_do_work_ms.store(
                MonotonicMilliseconds(), std::memory_order_relaxed);
            const uint64_t detail_event =
                g_message_pump_detail_event_count.fetch_add(
                    1, std::memory_order_relaxed) + 1;
            if (detail_event <= 64) {
              AppendCEFEmbeddingTelemetryLine(
                  [NSString stringWithFormat:
                      @"phase=message_pump_detail event=do_work "
                       "detailSequence=%llu scheduleCount=%llu "
                       "doWorkCount=%llu generation=%llu",
                      detail_event,
                      g_message_pump_schedule_count.load(
                          std::memory_order_relaxed),
                      g_message_pump_do_work_count.load(
                          std::memory_order_relaxed),
                      g_message_pump_generation.load(
                          std::memory_order_relaxed)]);
            }
            MaybeLogMessagePumpSummary(@"do_work");
          });
  if (result.should_schedule_follow_up &&
      g_initialized.load() &&
      !g_shutdown.load()) {
    // Never recurse synchronously when CEF or a host action requests another
    // tick while CefDoMessageLoopWork is active. One generation-coalesced
    // main-queue delivery drains the deduplicated follow-up.
    ScheduleCEFMessagePumpWork(0);
  }
  return result.did_run;
}

#pragma mark - W60 Opt-in five-second runtime probe
void W60StartRuntimePumpProbe() {
  const char *enabled = getenv("TATWO_CEF_PUMP_PROBE");
  if (!enabled || strcmp(enabled, "1") != 0) return;
  static bool started = false;
  if (started) return;
  started = true;
  const int64_t start = MonotonicMilliseconds();
  const uint64_t work = g_message_pump_do_work_count.load();
  __block uint64_t wakeups = 0;
  CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, kCFRunLoopAfterWaiting, true, 0,
      ^(CFRunLoopObserverRef, CFRunLoopActivity) { ++wakeups; });
  if (!observer) return;
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
  AppendCEFEmbeddingTelemetryLine(@"phase=w60_pump_probe event=begin requestedDurationMs=5000");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    AppendCEFEmbeddingTelemetryLine([NSString stringWithFormat:
        @"phase=w60_pump_probe event=end pid=%d durationMs=%lld doWorkCount=%llu mainWakeups=%llu",
        getpid(), MonotonicMilliseconds() - start,
        g_message_pump_do_work_count.load() - work, wakeups]);
  });
}
#pragma mark - W60 End

#pragma mark - W60 Scheduled pump (no loading or idle cadence)
// Main-queue owned, one replaceable vendor deadline. Immediate requests and
// host kicks are independent; a newer positive delay cannot erase either.
dispatch_source_t g_w60_vendor_timer = nil;
dispatch_source_t g_w60_overdue_timer = nil;

void W60CancelVendorTimers() {
  for (dispatch_source_t timer : {g_w60_vendor_timer, g_w60_overdue_timer}) {
    if (timer) dispatch_source_cancel(timer);
  }
  g_w60_vendor_timer = nil;
  g_w60_overdue_timer = nil;
}

void StartCEFMessagePumpIdleTimer() {
  W60StartRuntimePumpProbe();
  // Intentionally no idle timer. OnScheduleMessagePumpWork is authoritative.
}

void StopCEFMessagePumpIdleTimer() {
  NSCAssert(NSThread.isMainThread, @"CEF timer must stop on main thread");
  W60CancelVendorTimers();
}

void ScheduleCEFMessagePumpWork(int64_t delay_ms) {
  const int64_t delay = std::max<int64_t>(delay_ms, 0);
  const uint64_t generation = delay > 0
      ? g_message_pump_generation.fetch_add(1, std::memory_order_relaxed) + 1
      : g_message_pump_generation.load(std::memory_order_relaxed);
  const int64_t requested_at = MonotonicMilliseconds();
  g_message_pump_schedule_count.fetch_add(1, std::memory_order_relaxed);
  g_message_pump_last_schedule_ms.store(requested_at, std::memory_order_relaxed);
  g_message_pump_last_requested_delay_ms.store(delay_ms, std::memory_order_relaxed);
  g_message_pump_last_normalized_delay_ms.store(delay, std::memory_order_relaxed);
  g_message_pump_last_generation.store(generation, std::memory_order_relaxed);
  MaybeLogMessagePumpSummary(@"schedule");
  // Reserve room for the one-shot overdue safety net, without overflow or
  // shortening a CEF deadline that cannot be represented by dispatch_time.
  constexpr int64_t maximum = INT64_MAX / NSEC_PER_MSEC - 250;
  const bool representable = delay <= maximum;
  const dispatch_time_t deadline = representable
      ? dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC) : DISPATCH_TIME_FOREVER;
  const dispatch_time_t overdue = representable
      ? dispatch_time(DISPATCH_TIME_NOW, (delay + 250) * NSEC_PER_MSEC) : DISPATCH_TIME_FOREVER;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (delay == 0) {
      RunCEFMessagePumpWorkOnMainThread();
      return;
    }
    if (generation != g_message_pump_generation.load(std::memory_order_relaxed)) return;
    W60CancelVendorTimers();
    if (!representable || !g_initialized.load() || g_shutdown.load() || g_shutdown_requested.load()) return;
    dispatch_block_t deliver = ^{
      if (generation != g_message_pump_generation.load(std::memory_order_relaxed) ||
          !g_w60_vendor_timer) return;
      const int64_t lateness = MonotonicMilliseconds() - requested_at - delay;
      W60CancelVendorTimers(); // Clear before CEF: a reentrant schedule owns new timers.
      if (lateness >= 250) {
        AppendCEFEmbeddingTelemetryLine([NSString stringWithFormat:
            @"phase=message_pump_overdue event=recover generation=%llu overdueMs=%lld",
            generation, lateness]);
      }
      RunCEFMessagePumpWorkOnMainThread();
    };
    g_w60_vendor_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_w60_vendor_timer, deadline, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_w60_vendor_timer, deliver);
    dispatch_resume(g_w60_vendor_timer);
    // No repeating watchdog. It exists only while a positive CEF request is
    // pending, and may recover that request only >=250ms beyond its deadline.
    g_w60_overdue_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_w60_overdue_timer, overdue, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_w60_overdue_timer, ^{
      if (MonotonicMilliseconds() - requested_at - delay >= 250) deliver();
    });
    dispatch_resume(g_w60_overdue_timer);
  });
}
#pragma mark - W60 End

void QueueImmediateCEFMessagePumpWorkOnMainQueue() {
  QueueImmediateMessagePumpWork(
      g_message_pump_host_kick_queue_gate, [] {
        dispatch_async(dispatch_get_main_queue(), ^{
          g_message_pump_host_kick_queue_gate.EndQueue();
          RunCEFMessagePumpWorkOnMainThread();
        });
      });
}

void ScheduleImmediateCEFMessagePumpWork(NSString *reason) {
  // Host-side CEF API calls can arrive after the last vendor-scheduled pump
  // has gone idle. A host kick must not share the vendor generation: a later
  // OnScheduleMessagePumpWork callback is allowed to cancel a vendor timer, but
  // must not cancel either a direct main-thread iteration or the host's queued
  // main-thread block before it reaches CEF.
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=message_pump_host_kick reason=%@",
          SanitizeTelemetryToken(reason, @"unknown")]);
  DeliverImmediateMessagePumpWork(
      NSThread.isMainThread,
      [] { RunCEFMessagePumpWorkOnMainThread(); },
      [] { QueueImmediateCEFMessagePumpWorkOnMainQueue(); });
}

constexpr size_t kWebMCPMaximumToolNameBytes = 128;
constexpr size_t kWebMCPMaximumDescriptionBytes = 8192;
constexpr size_t kWebMCPMaximumSchemaBytes = 65536;
constexpr size_t kWebMCPMaximumPayloadBytes = 1024 * 1024;
constexpr int kWebMCPMaximumJSONDepth = 16;
constexpr const char *kWebMCPRegisterMessage = "tatwo.webmcp.register";
constexpr const char *kWebMCPUnregisterMessage = "tatwo.webmcp.unregister";
constexpr const char *kWebMCPInvalidateMessage = "tatwo.webmcp.invalidate";
constexpr const char *kWebMCPCapabilityMessage = "tatwo.webmcp.capability";
constexpr const char *kWebMCPInvokeMessage = "tatwo.webmcp.invoke";
constexpr const char *kWebMCPResultMessage = "tatwo.webmcp.result";
constexpr const char *kWebMCPErrorMessage = "tatwo.webmcp.error";

CefRefPtr<CefValue> V8ValueToCEFValue(
    CefRefPtr<CefV8Value> value,
    int depth) {
  if (!value || depth > kWebMCPMaximumJSONDepth) {
    return nullptr;
  }
  CefRefPtr<CefValue> result = CefValue::Create();
  if (value->IsNull() || value->IsUndefined()) {
    result->SetNull();
    return result;
  }
  if (value->IsBool()) {
    result->SetBool(value->GetBoolValue());
    return result;
  }
  if (value->IsInt()) {
    result->SetInt(value->GetIntValue());
    return result;
  }
  if (value->IsUInt() || value->IsDouble()) {
    result->SetDouble(value->GetDoubleValue());
    return result;
  }
  if (value->IsString()) {
    result->SetString(value->GetStringValue());
    return result;
  }
  if (value->IsArray()) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    const int length = std::min(value->GetArrayLength(), 4096);
    for (int index = 0; index < length; ++index) {
      CefRefPtr<CefValue> child =
          V8ValueToCEFValue(value->GetValue(index), depth + 1);
      if (!child || !list->SetValue(index, child)) {
        return nullptr;
      }
    }
    result->SetList(list);
    return result;
  }
  if (value->IsObject() && !value->IsFunction() && !value->IsPromise()) {
    std::vector<CefString> keys;
    if (!value->GetKeys(keys) || keys.size() > 4096) {
      return nullptr;
    }
    CefRefPtr<CefDictionaryValue> dictionary =
        CefDictionaryValue::Create();
    for (const CefString &key : keys) {
      CefRefPtr<CefValue> child =
          V8ValueToCEFValue(value->GetValue(key), depth + 1);
      if (!child || !dictionary->SetValue(key, child)) {
        return nullptr;
      }
    }
    result->SetDictionary(dictionary);
    return result;
  }
  return nullptr;
}

CefRefPtr<CefV8Value> CEFValueToV8Value(
    CefRefPtr<CefValue> value,
    int depth) {
  if (!value || depth > kWebMCPMaximumJSONDepth) {
    return nullptr;
  }
  switch (value->GetType()) {
    case VTYPE_NULL:
      return CefV8Value::CreateNull();
    case VTYPE_BOOL:
      return CefV8Value::CreateBool(value->GetBool());
    case VTYPE_INT:
      return CefV8Value::CreateInt(value->GetInt());
    case VTYPE_DOUBLE:
      return CefV8Value::CreateDouble(value->GetDouble());
    case VTYPE_STRING:
      return CefV8Value::CreateString(value->GetString());
    case VTYPE_LIST: {
      CefRefPtr<CefListValue> list = value->GetList();
      if (!list || list->GetSize() > 4096) {
        return nullptr;
      }
      CefRefPtr<CefV8Value> array =
          CefV8Value::CreateArray(static_cast<int>(list->GetSize()));
      for (size_t index = 0; index < list->GetSize(); ++index) {
        CefRefPtr<CefV8Value> child =
            CEFValueToV8Value(list->GetValue(index), depth + 1);
        if (!child || !array->SetValue(static_cast<int>(index), child)) {
          return nullptr;
        }
      }
      return array;
    }
    case VTYPE_DICTIONARY: {
      CefRefPtr<CefDictionaryValue> dictionary = value->GetDictionary();
      if (!dictionary) {
        return nullptr;
      }
      CefDictionaryValue::KeyList keys;
      if (!dictionary->GetKeys(keys) || keys.size() > 4096) {
        return nullptr;
      }
      CefRefPtr<CefV8Value> object =
          CefV8Value::CreateObject(nullptr, nullptr);
      for (const CefString &key : keys) {
        CefRefPtr<CefV8Value> child =
            CEFValueToV8Value(dictionary->GetValue(key), depth + 1);
        if (!child ||
            !object->SetValue(
                key, child, V8_PROPERTY_ATTRIBUTE_NONE)) {
          return nullptr;
        }
      }
      return object;
    }
    default:
      return nullptr;
  }
}

bool IsBoundedWebMCPString(
    const CefString &value,
    size_t maximum_bytes,
    bool allows_empty) {
  const std::string utf8 = value.ToString();
  return (allows_empty || !utf8.empty()) &&
         utf8.size() <= maximum_bytes;
}

void SendWebMCPRendererReply(
    CefRefPtr<CefFrame> frame,
    const char *message_name,
    const CefString &invocation_id,
    const CefString &payload) {
  if (!frame) {
    return;
  }
  CefRefPtr<CefProcessMessage> message =
      CefProcessMessage::Create(message_name);
  CefRefPtr<CefListValue> arguments = message->GetArgumentList();
  arguments->SetString(0, invocation_id);
  arguments->SetString(1, payload);
  frame->SendProcessMessage(PID_BROWSER, message);
}

class TatwoWebMCPRenderProcessHandler;

class TatwoWebMCPBindingHandler final : public CefV8Handler {
 public:
  TatwoWebMCPBindingHandler(
      CefRefPtr<TatwoWebMCPRenderProcessHandler> owner,
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context,
      CefString context_id)
      : owner_(owner),
        browser_(browser),
        frame_(frame),
        context_(context),
        context_id_(std::move(context_id)) {}

  bool Execute(
      const CefString &name,
      CefRefPtr<CefV8Value> object,
      const CefV8ValueList &arguments,
      CefRefPtr<CefV8Value> &retval,
      CefString &exception) override;

 private:
  CefRefPtr<TatwoWebMCPRenderProcessHandler> owner_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefFrame> frame_;
  CefRefPtr<CefV8Context> context_;
  CefString context_id_;
  IMPLEMENT_REFCOUNTING(TatwoWebMCPBindingHandler);
};

class TatwoWebMCPPromiseReplyHandler final : public CefV8Handler {
 public:
  TatwoWebMCPPromiseReplyHandler(
      CefRefPtr<CefFrame> frame,
      CefString invocation_id,
      bool success)
      : frame_(frame),
        invocation_id_(std::move(invocation_id)),
        success_(success) {}

  bool Execute(
      const CefString &name,
      CefRefPtr<CefV8Value> object,
      const CefV8ValueList &arguments,
      CefRefPtr<CefV8Value> &retval,
      CefString &exception) override {
    if (success_) {
      CefRefPtr<CefV8Value> value =
          arguments.empty() ? CefV8Value::CreateNull() : arguments.front();
      CefRefPtr<CefValue> cef_value = V8ValueToCEFValue(value, 0);
      if (!cef_value) {
        SendWebMCPRendererReply(
            frame_,
            kWebMCPErrorMessage,
            invocation_id_,
            "webmcp_result_not_json_serializable");
      } else {
        CefString json = CefWriteJSON(cef_value, JSON_WRITER_DEFAULT);
        if (!IsBoundedWebMCPString(
                json, kWebMCPMaximumPayloadBytes, true)) {
          SendWebMCPRendererReply(
              frame_,
              kWebMCPErrorMessage,
              invocation_id_,
              "webmcp_result_too_large");
        } else {
          SendWebMCPRendererReply(
              frame_, kWebMCPResultMessage, invocation_id_, json);
        }
      }
    } else {
      CefString reason("webmcp_execute_rejected");
      if (!arguments.empty() && arguments.front()->IsString()) {
        reason = arguments.front()->GetStringValue();
      }
      if (!IsBoundedWebMCPString(reason, 1024, false)) {
        reason = "webmcp_execute_rejected";
      }
      SendWebMCPRendererReply(
          frame_, kWebMCPErrorMessage, invocation_id_, reason);
    }
    retval = CefV8Value::CreateUndefined();
    return true;
  }

 private:
  CefRefPtr<CefFrame> frame_;
  CefString invocation_id_;
  const bool success_;
  IMPLEMENT_REFCOUNTING(TatwoWebMCPPromiseReplyHandler);
};

#pragma mark - W57c Dedicated password renderer channel
// Never route these messages through WebMCP, DOM snapshots, diagnostics or telemetry.
constexpr const char *kPasswordConfigureMessage = "tatwo.password.configure";
constexpr const char *kPasswordFillMessage = "tatwo.password.fill";
constexpr const char *kPasswordEventMessage = "tatwo.password.event";
void W57cInvalidate(TatwoCEFBrowserView *view, bool reload, bool preserve_submission);
void W57cLoadEnd(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, int status);
bool W57cBrowserMessage(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefProcessMessage> message);

// Evaluated as a fixed factory. The callback and credentials are V8 arguments, not
// source interpolation or globals. Mirrors EmbeddedBrowserPasswordFormMetadataExtractor's
// password_form/action-origin checks without changing its metadata-only contract.
constexpr const char *kW57cPasswordScript = R"W57C(
(function(report, expectedOrigin) {
  'use strict';
  let active = true, nextID = 0, lastForm = null, lastTime = 0;
  const forms = new Map();
  const originOK = () => active && location.protocol === 'https:' && location.origin === expectedOrigin;
  const tokens = e => String(e.autocomplete || '').toLowerCase().split(/\s+/);
  const visible = e => e instanceof HTMLInputElement && e.isConnected && !e.disabled &&
    !e.readOnly && e.type !== 'hidden' && !e.hidden && e.getClientRects().length > 0 &&
    getComputedStyle(e).visibility === 'visible' && getComputedStyle(e).display !== 'none';
  const usernameOK = e => visible(e) && ['text', 'email', 'tel'].includes(e.type) &&
    !tokens(e).some(t => ['one-time-code', 'new-password', 'current-password'].includes(t));
  const passwordOK = e => visible(e) && e.type === 'password' &&
    !tokens(e).includes('new-password') && !tokens(e).includes('one-time-code');
  const actionOK = form => {
    try {
      const action = new URL(form.action || location.href, document.baseURI);
      return action.protocol === 'https:' && !action.username && !action.password &&
        action.origin === expectedOrigin;
    } catch (_) { return false; }
  };
  const fields = form => {
    if (!form || !form.isConnected || !actionOK(form)) return null;
    const inputs = Array.from(form.elements);
    // Registration/reset forms never get a saved login or a save/update prompt.
    if (inputs.some(e => e instanceof HTMLInputElement && tokens(e).includes('new-password'))) return null;
    const passwords = inputs.filter(passwordOK);
    if (passwords.length !== 1) return null;
    const users = inputs.filter(usernameOK);
    const username = users.find(e => tokens(e).includes('username')) ||
      users.find(e => e.type === 'email') || users[0];
    return username ? {username, password: passwords[0]} : null;
  };
  const submit = form => {
    if (!originOK()) return;
    const pair = fields(form);
    if (!pair || !pair.password.value) return;
    const now = performance.now();
    if (lastForm === form && now - lastTime < 750) return; // Enter + submit coalescing, no secret cache.
    lastForm = form; lastTime = now;
    report('submitted', String(pair.username.value), String(pair.password.value));
  };
  const onSubmit = event => { if (event.isTrusted) submit(event.target); };
  const onEnter = event => {
    if (event.isTrusted && event.key === 'Enter' && !event.isComposing &&
        event.target instanceof HTMLInputElement) submit(event.target.form);
  };
  document.addEventListener('submit', onSubmit, true);
  document.addEventListener('keydown', onEnter, true);
  return {
    scan() {
      if (!originOK()) return;
      const passwordForms = Array.from(document.forms).filter(form =>
        Array.from(form.elements).some(e => e instanceof HTMLInputElement && e.type === 'password'));
      // This conservative completion signal rejects 200 responses that still show a login form.
      report('scanned', passwordForms.length ? '1' : '0');
      for (const form of passwordForms) {
        const pair = fields(form);
        if (!pair) continue;
        const id = 'w57c-' + (++nextID);
        forms.set(id, {form, ...pair, prefilled: String(pair.username.value)});
        report('detected', id, id + '-username', id + '-password', String(pair.username.value));
      }
    },
    fill(id, username, password) {
      if (!originOK()) return false;
      const item = forms.get(id);
      if (!item || !item.form.isConnected || !actionOK(item.form)) return false;
      const pair = fields(item.form);
      if (!pair || pair.username !== item.username || pair.password !== item.password ||
          pair.username.form !== item.form || pair.password.form !== item.form ||
          pair.password.type !== 'password' || pair.username.type === 'hidden' ||
          pair.password.value || String(pair.username.value) !== item.prefilled) return false;
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(pair.username, username);
      setter.call(pair.password, password);
      for (const element of [pair.username, pair.password]) {
        element.dispatchEvent(new Event('input', {bubbles: true}));
        element.dispatchEvent(new Event('change', {bubbles: true}));
      }
      forms.delete(id); // One approved fill, no submit.
      return true;
    },
    stop() {
      active = false; forms.clear(); lastForm = null;
      document.removeEventListener('submit', onSubmit, true);
      document.removeEventListener('keydown', onEnter, true);
    }
  };
})
)W57C";

class W57cPasswordBinding final : public CefV8Handler {
 public:
  W57cPasswordBinding(CefRefPtr<CefFrame> frame, CefString generation,
                     CefString token, CefString origin)
      : frame_(frame), generation_(generation), token_(token), origin_(origin) {}
  bool Execute(const CefString &, CefRefPtr<CefV8Value>, const CefV8ValueList &values,
               CefRefPtr<CefV8Value> &retval, CefString &) override {
    retval = CefV8Value::CreateUndefined();
    if (!frame_ || !frame_->IsValid() || !frame_->IsMain() || values.empty() || values.size() > 5 ||
        !values[0]->IsString()) return true;
    const auto kind = values[0]->GetStringValue();
    if (kind != "detected" && kind != "submitted" && kind != "scanned") return true;
    auto message = CefProcessMessage::Create(kPasswordEventMessage);
    auto args = message->GetArgumentList();
    args->SetString(0, generation_);
    args->SetString(1, token_);
    args->SetString(2, origin_);
    for (size_t i = 0; i < values.size(); ++i) {
      if (!values[i]->IsString() || values[i]->GetStringValue().ToString().size() > (i == 2 && kind == "submitted" ? 16384 : 4096)) return true;
      args->SetString(3 + i, values[i]->GetStringValue());
    }
    frame_->SendProcessMessage(PID_BROWSER, message);
    return true;
  }
 private:
  CefRefPtr<CefFrame> frame_;
  CefString generation_, token_, origin_;
  IMPLEMENT_REFCOUNTING(W57cPasswordBinding);
};

class W57cPasswordRenderer {
  struct Page {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> controller;
    CefString generation, token, url;
  };
  std::map<int, Page> pages_;
  void Call(Page &page, const char *name, const CefV8ValueList &args = {}) {
    if (!page.context || !page.context->IsValid() || !page.context->Enter()) return;
    auto function = page.controller->GetValue(name);
    if (function && function->IsFunction())
      function->ExecuteFunctionWithContext(page.context, page.controller, args);
    page.context->Exit();
  }
 public:
  void Release(CefRefPtr<CefBrowser> browser, CefRefPtr<CefV8Context> context = nullptr) {
    if (!browser) return;
    auto it = pages_.find(browser->GetIdentifier());
    if (it == pages_.end() || (context && !it->second.context->IsSame(context))) return;
    Call(it->second, "stop");
    pages_.erase(it);
  }
  bool Receive(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
               CefProcessId source, CefRefPtr<CefProcessMessage> message) {
    if (!message || (message->GetName() != kPasswordConfigureMessage &&
                     message->GetName() != kPasswordFillMessage)) return false;
    if (source != PID_BROWSER || !browser || !frame || !frame->IsMain() || !frame->IsValid()) return true;
    auto args = message->GetArgumentList();
    if (!args || args->GetSize() < 4) return true;
    const auto generation = args->GetString(0), token = args->GetString(1);
    if (message->GetName() == kPasswordConfigureMessage) {
      Release(browser);
      if (args->GetSize() != 6 || !args->GetBool(4) || token.empty() ||
          args->GetString(3) != frame->GetURL()) return true; // human/agent state comes only from browser.
      auto context = frame->GetV8Context();
      if (!context || !context->IsValid() || !context->Enter()) return true;
      CefRefPtr<CefV8Value> factory;
      CefRefPtr<CefV8Exception> exception;
      if (!context->Eval(kW57cPasswordScript, "tatwo-password-assist", 1, factory, exception) ||
          !factory || !factory->IsFunction()) { context->Exit(); return true; }
      CefV8ValueList input{
        CefV8Value::CreateFunction("passwordAssist", new W57cPasswordBinding(frame, generation, token, args->GetString(2))),
        CefV8Value::CreateString(args->GetString(2))
      };
      auto controller = factory->ExecuteFunctionWithContext(context, nullptr, input);
      context->Exit();
      if (!controller || !controller->IsObject()) return true;
      auto &page = pages_[browser->GetIdentifier()];
      page = {context, controller, generation, token, args->GetString(3)};
      Call(page, "scan");
      return true;
    }
    auto it = pages_.find(browser->GetIdentifier());
    if (args->GetSize() != 7 || it == pages_.end()) return true;
    auto &page = it->second;
    auto context = frame->GetV8Context();
    if (page.generation != generation || page.token != token || page.url != frame->GetURL() ||
        !context || !page.context->IsSame(context)) return true;
    Call(page, "fill", {CefV8Value::CreateString(args->GetString(4)),
                        CefV8Value::CreateString(args->GetString(5)),
                        CefV8Value::CreateString(args->GetString(6))});
    return true;
  }
};
#pragma mark - W57c End

#pragma mark - W58 Agent-only credential channel (no WebMCP or source interpolation)
constexpr const char *kAILoginConfigure = "tatwo.ai-login.configure";
constexpr const char *kAILoginFill = "tatwo.ai-login.fill";
constexpr const char *kAILoginEvent = "tatwo.ai-login.event";
void W58Invalidate(TatwoCEFBrowserView *view, bool preserve_result);
void W58LoadEnd(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, int status);
bool W58BrowserMessage(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, CefRefPtr<CefProcessMessage> message);
constexpr const char *kW58AgentLoginScript = R"W58(
(function(expectedOrigin) {
  'use strict';
  let bound = null;
  const originOK = () => location.protocol === 'https:' && location.origin === expectedOrigin;
  const visible = e => e instanceof HTMLInputElement && e.isConnected && !e.disabled && !e.readOnly &&
    !e.hidden && e.type !== 'hidden' && e.getClientRects().length > 0 &&
    getComputedStyle(e).visibility === 'visible' && getComputedStyle(e).display !== 'none';
  const tokens = e => String(e.autocomplete || '').toLowerCase().split(/\s+/);
  const otp = () => Array.from(document.querySelectorAll('input')).some(e => visible(e) &&
    (tokens(e).includes('one-time-code') || /(?:^|[-_])(otp|totp|2fa|verification[-_]?code)(?:$|[-_])/i.test(e.name || e.id || '')));
  const actionOK = form => {
    try {
      const a = new URL(form.action || location.href, document.baseURI);
      // GET would put a password into history/URL metadata. Never fill it.
      return String(form.method).toLowerCase() === 'post' && a.protocol === 'https:' &&
        a.origin === expectedOrigin && !a.username && !a.password;
    } catch (_) { return false; }
  };
  const fields = form => {
    if (!form || !form.isConnected || !actionOK(form)) return null;
    const elements = Array.from(form.elements);
    if (elements.some(e => tokens(e).includes('new-password') || tokens(e).includes('one-time-code'))) return null;
    const pw = elements.filter(e => visible(e) && e.type === 'password');
    const users = elements.filter(e => visible(e) && ['text','email','tel'].includes(e.type));
    const user = users.find(e => tokens(e).includes('username')) || users.find(e => e.type === 'email') || users[0];
    return pw.length === 1 && user && user.form === form && pw[0].form === form ? {user, password: pw[0]} : null;
  };
  return {
    scan(completed) {
      bound = null;
      if (!originOK()) return {error:'ai_login_stale_page'};
      if (otp() || /(?:^|\/)(?:2fa|totp|mfa|two-factor|challenge)(?:\/|$)/i.test(location.pathname))
        return {error:'ai_login_two_factor_required'};
      const forms = Array.from(document.forms);
      if (completed) {
        if (forms.some(f => Array.from(f.elements).some(e => visible(e) && e.type === 'password')))
          return {error:'ai_login_rejected'};
        return {formID:'', title:String(document.title || '').slice(0,200)};
      }
      const candidates = forms.map(form => ({form, pair:fields(form)})).filter(e => e.pair);
      if (candidates.length !== 1) return {error: candidates.length ? 'ai_login_ambiguous_form' : 'ai_login_no_form'};
      const {form, pair} = candidates[0];
      if (pair.password.value) return {error:'ai_login_nonempty_form'};
      bound = {form, ...pair, prefilled:String(pair.user.value)};
      return {formID:'w58-login'};
    },
    fill(id, username, password) {
      const item = bound;
      bound = null; // Single use, including rejected and throwing attempts.
      if (!originOK() || otp() || id !== 'w58-login' || !item) return false;
      const pair = fields(item.form);
      if (!pair || pair.user !== item.user || pair.password !== item.password || pair.password.value ||
          String(pair.user.value) !== item.prefilled || (item.prefilled && item.prefilled !== username)) return false;
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const submit = HTMLFormElement.prototype.requestSubmit;
      if (typeof submit !== 'function') return false;
      try {
        setter.call(pair.user, username);
        setter.call(pair.password, password);
        for (const e of [pair.user,pair.password]) {
          e.dispatchEvent(new Event('input',{bubbles:true}));
          e.dispatchEvent(new Event('change',{bubbles:true}));
        }
        // Input handlers can detach fields/change action. Revalidate before submit.
        const current = fields(item.form);
        if (!originOK() || !current || current.user !== pair.user || current.password !== pair.password ||
            pair.password.type !== 'password' || !item.form.checkValidity()) {
          setter.call(pair.password, ''); return false;
        }
        submit.call(item.form);
        // Native form submission has captured its entry list. Do not leave an AI
        // password in the DOM while a cancelled/async submit waits or times out.
        setter.call(pair.password, '');
        return true;
      } catch (_) { setter.call(pair.password, ''); return false; }
    }
  };
})
)W58";

class W58AgentLoginRenderer {
  struct Page {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> controller;
    CefString generation, token, url;
  };
  std::map<int, Page> pages_;
 public:
  void Release(CefRefPtr<CefBrowser> browser, CefRefPtr<CefV8Context> context = nullptr) {
    if (!browser) return;
    auto it = pages_.find(browser->GetIdentifier());
    if (it != pages_.end() && (!context || it->second.context->IsSame(context))) pages_.erase(it);
  }
  bool Receive(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
               CefProcessId source, CefRefPtr<CefProcessMessage> message) {
    if (!message || (message->GetName() != kAILoginConfigure && message->GetName() != kAILoginFill)) return false;
    if (source != PID_BROWSER || !browser || !frame || !frame->IsMain() || !frame->IsValid()) return true;
    auto args = message->GetArgumentList();
    if (!args || args->GetSize() < 5) return true;
    const auto generation = args->GetString(0), token = args->GetString(1);
    auto context = frame->GetV8Context();
    if (message->GetName() == kAILoginConfigure) {
      Release(browser);
      if (args->GetSize() != 5 || args->GetInt(4) == 2 || token.empty()) return true;
      if (args->GetString(3) != frame->GetURL() || !context || !context->IsValid() || !context->Enter()) return true;
      CefRefPtr<CefV8Value> factory;
      CefRefPtr<CefV8Exception> exception;
      if (!context->Eval(kW58AgentLoginScript, "tatwo-ai-login", 1, factory, exception) ||
          !factory || !factory->IsFunction()) { context->Exit(); return true; }
      auto controller = factory->ExecuteFunctionWithContext(context, nullptr,
        {CefV8Value::CreateString(args->GetString(2))});
      if (!controller || !controller->IsObject()) { context->Exit(); return true; }
      pages_[browser->GetIdentifier()] = {context, controller, generation, token, frame->GetURL()};
      auto scan = controller->GetValue("scan");
      auto result = scan && scan->IsFunction() ? scan->ExecuteFunctionWithContext(context, controller,
        {CefV8Value::CreateBool(args->GetInt(4) == 1)}) : nullptr;
      auto reply = CefProcessMessage::Create(kAILoginEvent);
      auto out = reply->GetArgumentList();
      out->SetString(0, generation); out->SetString(1, token);
      out->SetString(2, args->GetInt(4) == 1 ? "complete" : "ready");
      for (int i = 0; i < 3; ++i) {
        auto value = result && result->IsObject() ? result->GetValue(i == 0 ? "formID" : i == 1 ? "error" : "title") : nullptr;
        out->SetString(3+i, value && value->IsString() ? value->GetStringValue() : "");
      }
      if (!result || !result->IsObject()) out->SetString(4, "ai_login_no_form");
      context->Exit();
      frame->SendProcessMessage(PID_BROWSER, reply);
      return true;
    }
    auto it = pages_.find(browser->GetIdentifier());
    if (args->GetSize() != 7 || it == pages_.end()) return true;
    auto page = it->second;
    pages_.erase(it);
    if (page.generation != generation || page.token != token || page.url != frame->GetURL() ||
        !context || !page.context->IsSame(context) || !context->IsValid() || !context->Enter()) return true;
    auto fill = page.controller->GetValue("fill");
    auto result = fill && fill->IsFunction() ? fill->ExecuteFunctionWithContext(context, page.controller,
      {CefV8Value::CreateString(args->GetString(4)), CefV8Value::CreateString(args->GetString(5)),
       CefV8Value::CreateString(args->GetString(6))}) : nullptr;
    const bool success = result && result->IsBool() && result->GetBoolValue();
    context->Exit();
    if (!success) {
      auto reply = CefProcessMessage::Create(kAILoginEvent);
      auto out = reply->GetArgumentList();
      out->SetString(0, generation); out->SetString(1, token); out->SetString(2, "failed");
      out->SetString(3, ""); out->SetString(4, "ai_login_form_changed"); out->SetString(5, "");
      frame->SendProcessMessage(PID_BROWSER, reply);
    }
    return true;
  }
};
#pragma mark - W58 End
class TatwoWebMCPRenderProcessHandler final
    : public CefRenderProcessHandler {
 public:
  struct Tool {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> execute;
    CefRefPtr<CefFrame> frame;
    CefString context_id;
  };

  void OnWebKitInitialized() override {
    g_webmcp_renderer_hook_active.store(
        true, std::memory_order_release);
  }

  void OnContextCreated(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context) override {
    if (!browser || !frame || !frame->IsMain() || !context) {
      return;
    }
    CefRefPtr<CefV8Value> global = context->GetGlobal();
    CefRefPtr<CefV8Value> document =
        global ? global->GetValue("document") : nullptr;
    if (!document || !document->IsObject()) {
      return;
    }
    CefRefPtr<TatwoWebMCPBindingHandler> handler =
        new TatwoWebMCPBindingHandler(
            this,
            browser,
            frame,
            context,
            ToCefString(NSUUID.UUID.UUIDString.lowercaseString));
    CefRefPtr<CefV8Value> model_context =
        CefV8Value::CreateObject(nullptr, nullptr);
    const bool register_installed = model_context->SetValue(
        "registerTool",
        CefV8Value::CreateFunction("registerTool", handler),
        V8_PROPERTY_ATTRIBUTE_READONLY);
    const bool unregister_installed = model_context->SetValue(
        "unregisterTool",
        CefV8Value::CreateFunction("unregisterTool", handler),
        V8_PROPERTY_ATTRIBUTE_READONLY);
    const bool marker_installed = model_context->SetValue(
        "__tatwoWebMCP",
        CefV8Value::CreateBool(true),
        V8_PROPERTY_ATTRIBUTE_READONLY);
    // W3C WebMCP surface is navigator.modelContext; document.modelContext stays as the
    // TATWO-internal alias. When Chromium ships a native navigator.modelContext that
    // refuses SetValue, take it over with defineProperty so pages always reach TATWO.
    const bool document_installed = document->SetValue(
        "modelContext",
        model_context,
        V8_PROPERTY_ATTRIBUTE_READONLY);
    CefRefPtr<CefV8Value> navigator =
        global ? global->GetValue("navigator") : nullptr;
    bool navigator_installed = navigator && navigator->IsObject() &&
        navigator->SetValue(
            "modelContext",
            model_context,
            V8_PROPERTY_ATTRIBUTE_READONLY);
    if (!navigator_installed && document_installed) {
      frame->ExecuteJavaScript(
          "try{Object.defineProperty(navigator,'modelContext',"
          "{value:document.modelContext,configurable:true,writable:false});}"
          "catch(e){}",
          frame->GetURL(),
          0);
      navigator_installed = true;  // best effort; the marker below lets pages verify
    }
    const bool context_installed = document_installed && navigator_installed;
    if (!register_installed || !unregister_installed ||
        !marker_installed || !context_installed) {
      return;
    }
    CefRefPtr<CefProcessMessage> capability =
        CefProcessMessage::Create(kWebMCPCapabilityMessage);
    capability->GetArgumentList()->SetBool(0, true);
    frame->SendProcessMessage(PID_BROWSER, capability);
  }

  void OnContextReleased(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context) override {
#pragma mark - W57c Release password references with their document
    password_renderer_.Release(browser, context);
#pragma mark - W57c End
#pragma mark - W58
    ai_login_renderer_.Release(browser, context);
#pragma mark - W58 End
    if (!browser || !frame || !frame->IsMain()) {
      return;
    }
    std::set<std::string> released_context_ids;
    for (auto iterator = tools_.begin(); iterator != tools_.end();) {
      if (iterator->second.context &&
          iterator->second.context->IsSame(context)) {
        released_context_ids.insert(
            iterator->second.context_id.ToString());
        iterator = tools_.erase(iterator);
      } else {
        ++iterator;
      }
    }
    for (const std::string &context_id : released_context_ids) {
      CefRefPtr<CefProcessMessage> message =
          CefProcessMessage::Create(kWebMCPInvalidateMessage);
      message->GetArgumentList()->SetString(0, context_id);
      frame->SendProcessMessage(PID_BROWSER, message);
    }
  }

  bool OnProcessMessageReceived(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefProcessId source_process,
      CefRefPtr<CefProcessMessage> message) override {
#pragma mark - W57c Dedicated renderer dispatch before WebMCP
    if (password_renderer_.Receive(browser, frame, source_process, message)) return true;
#pragma mark - W57c End
#pragma mark - W58
    if (ai_login_renderer_.Receive(browser, frame, source_process, message)) return true;
#pragma mark - W58 End
    if (source_process != PID_BROWSER || !browser || !frame ||
        !frame->IsMain() || !message ||
        message->GetName() != kWebMCPInvokeMessage) {
      return false;
    }
    CefRefPtr<CefListValue> arguments = message->GetArgumentList();
    const CefString invocation_id = arguments->GetString(0);
    const CefString tool_name = arguments->GetString(1);
    const CefString arguments_json = arguments->GetString(2);
    const CefString context_id = arguments->GetString(3);
    auto iterator =
        tools_.find(ContextKey(
            browser,
            frame,
            context_id.ToString(),
            tool_name.ToString()));
    if (iterator == tools_.end()) {
      SendWebMCPRendererReply(
          frame,
          kWebMCPErrorMessage,
          invocation_id,
          "webmcp_tool_unavailable");
      return true;
    }
    CefRefPtr<CefValue> parsed =
        CefParseJSON(arguments_json, JSON_PARSER_RFC);
    CefRefPtr<CefV8Value> input = CEFValueToV8Value(parsed, 0);
    Tool tool = iterator->second;
    if (!input || !tool.context || !tool.context->IsValid() ||
        !tool.execute || !tool.execute->IsFunction() ||
        !tool.context->Enter()) {
      SendWebMCPRendererReply(
          frame,
          kWebMCPErrorMessage,
          invocation_id,
          "webmcp_invoke_invalid_context");
      return true;
    }
    CefV8ValueList execute_arguments;
    execute_arguments.push_back(input);
    CefRefPtr<CefV8Value> result =
        tool.execute->ExecuteFunctionWithContext(
            tool.context, nullptr, execute_arguments);
    if (!result) {
      tool.context->Exit();
      SendWebMCPRendererReply(
          frame,
          kWebMCPErrorMessage,
          invocation_id,
          "webmcp_execute_failed");
      return true;
    }
    if (result->IsPromise()) {
      CefRefPtr<CefV8Value> then_function = result->GetValue("then");
      if (!then_function || !then_function->IsFunction()) {
        tool.context->Exit();
        SendWebMCPRendererReply(
            frame,
            kWebMCPErrorMessage,
            invocation_id,
            "webmcp_promise_unavailable");
        return true;
      }
      CefV8ValueList then_arguments;
      then_arguments.push_back(CefV8Value::CreateFunction(
          "tatwoWebMCPResolve",
          new TatwoWebMCPPromiseReplyHandler(
              frame, invocation_id, true)));
      then_arguments.push_back(CefV8Value::CreateFunction(
          "tatwoWebMCPReject",
          new TatwoWebMCPPromiseReplyHandler(
              frame, invocation_id, false)));
      CefRefPtr<CefV8Value> chained =
          then_function->ExecuteFunction(result, then_arguments);
      tool.context->Exit();
      if (!chained) {
        SendWebMCPRendererReply(
            frame,
            kWebMCPErrorMessage,
            invocation_id,
            "webmcp_promise_attach_failed");
      }
      return true;
    }
    CefRefPtr<CefValue> cef_result = V8ValueToCEFValue(result, 0);
    tool.context->Exit();
    if (!cef_result) {
      SendWebMCPRendererReply(
          frame,
          kWebMCPErrorMessage,
          invocation_id,
          "webmcp_result_not_json_serializable");
      return true;
    }
    CefString result_json =
        CefWriteJSON(cef_result, JSON_WRITER_DEFAULT);
    if (!IsBoundedWebMCPString(
            result_json, kWebMCPMaximumPayloadBytes, true)) {
      SendWebMCPRendererReply(
          frame,
          kWebMCPErrorMessage,
          invocation_id,
          "webmcp_result_too_large");
      return true;
    }
    SendWebMCPRendererReply(
        frame, kWebMCPResultMessage, invocation_id, result_json);
    return true;
  }

  bool RegisterTool(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context,
      const CefString &context_id,
      CefRefPtr<CefV8Value> definition,
      CefString &exception) {
    if (!definition || !definition->IsObject()) {
      exception = "registerTool requires a tool definition object";
      return false;
    }
    CefRefPtr<CefV8Value> name_value = definition->GetValue("name");
    CefRefPtr<CefV8Value> execute = definition->GetValue("execute");
    if (!name_value || !name_value->IsString() ||
        !execute || !execute->IsFunction() ||
        !IsBoundedWebMCPString(
            name_value->GetStringValue(),
            kWebMCPMaximumToolNameBytes,
            false)) {
      exception = "registerTool requires a bounded name and execute function";
      return false;
    }
    CefString description;
    CefRefPtr<CefV8Value> description_value =
        definition->GetValue("description");
    if (description_value && description_value->IsString()) {
      description = description_value->GetStringValue();
    }
    if (!IsBoundedWebMCPString(
            description, kWebMCPMaximumDescriptionBytes, true)) {
      exception = "registerTool description is too large";
      return false;
    }
    CefRefPtr<CefValue> schema = CefValue::Create();
    schema->SetDictionary(CefDictionaryValue::Create());
    CefRefPtr<CefV8Value> schema_value =
        definition->GetValue("inputSchema");
    if (schema_value && !schema_value->IsUndefined()) {
      schema = V8ValueToCEFValue(schema_value, 0);
      if (!schema || schema->GetType() != VTYPE_DICTIONARY) {
        exception = "registerTool inputSchema must be a JSON object";
        return false;
      }
    }
    CefString schema_json =
        CefWriteJSON(schema, JSON_WRITER_DEFAULT);
    if (!IsBoundedWebMCPString(
            schema_json, kWebMCPMaximumSchemaBytes, false)) {
      exception = "registerTool inputSchema is too large";
      return false;
    }
    const CefString tool_name = name_value->GetStringValue();
    tools_[ContextKey(
        browser,
        frame,
        context_id.ToString(),
        tool_name.ToString())] = {
        context, execute, frame, context_id};
    CefRefPtr<CefProcessMessage> message =
        CefProcessMessage::Create(kWebMCPRegisterMessage);
    CefRefPtr<CefListValue> message_arguments =
        message->GetArgumentList();
    message_arguments->SetString(0, tool_name);
    message_arguments->SetString(1, description);
    message_arguments->SetString(2, schema_json);
    message_arguments->SetString(3, frame->GetURL());
    message_arguments->SetString(4, context_id);
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

  bool UnregisterTool(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString &context_id,
      const CefString &tool_name) {
    const bool removed =
        tools_.erase(
            ContextKey(
                browser,
                frame,
                context_id.ToString(),
                tool_name.ToString())) > 0;
    CefRefPtr<CefProcessMessage> message =
        CefProcessMessage::Create(kWebMCPUnregisterMessage);
    CefRefPtr<CefListValue> arguments = message->GetArgumentList();
    arguments->SetString(0, tool_name);
    arguments->SetString(1, frame->GetURL());
    arguments->SetString(2, context_id);
    frame->SendProcessMessage(PID_BROWSER, message);
    return removed;
  }

 private:
  static std::string ContextKey(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const std::string &context_id,
      const std::string &tool_name) {
    return std::to_string(browser ? browser->GetIdentifier() : 0) +
           ":" +
           (frame ? frame->GetIdentifier().ToString() : "0") +
           ":" +
           context_id +
           ":" +
           tool_name;
  }

  std::map<std::string, Tool> tools_;
#pragma mark - W57c Renderer-owned, never process-global credential state
  W57cPasswordRenderer password_renderer_;
#pragma mark - W57c End
#pragma mark - W58
  W58AgentLoginRenderer ai_login_renderer_;
#pragma mark - W58 End
  IMPLEMENT_REFCOUNTING(TatwoWebMCPRenderProcessHandler);
};

bool TatwoWebMCPBindingHandler::Execute(
    const CefString &name,
    CefRefPtr<CefV8Value> object,
    const CefV8ValueList &arguments,
    CefRefPtr<CefV8Value> &retval,
    CefString &exception) {
  if (name == "registerTool") {
    if (arguments.size() != 1 ||
        !owner_->RegisterTool(
            browser_,
            frame_,
            context_,
            context_id_,
            arguments.front(),
            exception)) {
      return true;
    }
    retval = CefV8Value::CreateBool(true);
    return true;
  }
  if (name == "unregisterTool") {
    if (arguments.size() != 1 || !arguments.front()->IsString()) {
      exception = "unregisterTool requires one tool name";
      return true;
    }
    retval = CefV8Value::CreateBool(
        owner_->UnregisterTool(
            browser_,
            frame_,
            context_id_,
            arguments.front()->GetStringValue()));
    return true;
  }
  return false;
}

class TatwoBrowserProcessApp final : public CefApp,
                                     public CefBrowserProcessHandler {
 public:
  TatwoBrowserProcessApp()
      : render_process_handler_(
            new TatwoWebMCPRenderProcessHandler()) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return render_process_handler_;
  }

  void OnBeforeCommandLineProcessing(
      const CefString &process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    // These switches configure the browser process. Pinned CEF explicitly
    // warns that mutating command-line arguments for non-browser processes can
    // cause undefined behavior, including utility-process crashes.
    if (!process_type.empty()) {
      return;
    }
    for (const char *switch_name : kDeniedHostSwitches) {
      command_line->RemoveSwitch(switch_name);
    }
    // W60b: Chromium treats this as a soft process-reuse hint; site isolation
    // can exceed it. The actual hard browser budget lives above the bridge.
    command_line->RemoveSwitch("renderer-process-limit");
    const int renderer_limit = g_renderer_process_limit.load();
    if (renderer_limit > 0) {
      command_line->AppendSwitchWithValue("renderer-process-limit",
                                         std::to_string(renderer_limit));
    }
    // Do not enable process-per-site: it broadens same-site failure/contention
    // sharing with unmeasured benefit here. Never disable site isolation.
    command_line->AppendSwitch("disable-background-networking");
    command_line->AppendSwitch("disable-breakpad");
    command_line->AppendSwitch("disable-component-update");
    command_line->AppendSwitch("disable-default-apps");
    command_line->AppendSwitch("disable-extensions");
    command_line->AppendSwitchWithValue(
        "webrtc-ip-handling-policy",
        kWebRTCIPHandlingPolicy);
    command_line->AppendSwitchWithValue(
        "disable-features",
        "AutofillServerCommunication,MediaRouter,WebBluetooth,WebHID,"
        "WebNFC,WebOTP,WebSerial,WebUSB");
    command_line->AppendSwitch("disable-sync");
    command_line->AppendSwitch("metrics-recording-only");
    command_line->AppendSwitch("no-default-browser-check");
    command_line->AppendSwitch("no-first-run");
    g_webrtc_ip_policy_configured.store(
        command_line->HasSwitch("webrtc-ip-handling-policy") &&
            command_line->GetSwitchValue("webrtc-ip-handling-policy") ==
                kWebRTCIPHandlingPolicy,
        std::memory_order_release);
  }

  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override {
    const CEFHelperRoleTelemetry helper =
        CEFHelperRoleFromCommandLine(command_line);
    const uint64_t launch_count =
        g_helper_role_launch_counts[static_cast<size_t>(helper.role)]
            .fetch_add(1, std::memory_order_relaxed) + 1;
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=helper_process event=launch role=%@ "
             "launchCount=%llu countScope=role launchMeaning=attempt_not_restart",
            helper.token,
            launch_count]);
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    ScheduleCEFMessagePumpWork(delay_ms);
  }

 private:
  CefRefPtr<TatwoWebMCPRenderProcessHandler> render_process_handler_;
  IMPLEMENT_REFCOUNTING(TatwoBrowserProcessApp);
};

class TatwoThirdPartyCookieAccessFilter final
    : public CefCookieAccessFilter {
 public:
  TatwoThirdPartyCookieAccessFilter(
      bool blocks_third_party_cookies,
      NSString *request_initiator)
      : blocks_third_party_cookies_(blocks_third_party_cookies),
        request_initiator_([request_initiator copy]) {}

  bool CanSendCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     const CefCookie &cookie) override {
    return AllowsCookie(request);
  }

  bool CanSaveCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     CefRefPtr<CefResponse> response,
                     const CefCookie &cookie) override {
    return AllowsCookie(request);
  }

 private:
  bool AllowsCookie(CefRefPtr<CefRequest> request) const {
    if (!blocks_third_party_cookies_) {
      return true;
    }
    if (!request) {
      return false;
    }
    if (request->GetResourceType() == RT_MAIN_FRAME) {
      return true;
    }
    NSString *request_url = FromCefString(request->GetURL());
    NSString *first_party =
        FromCefString(request->GetFirstPartyForCookies());
    if (first_party.length == 0) {
      first_party = request_initiator_;
    }
    return IsSameSite(request_url, first_party);
  }

  const bool blocks_third_party_cookies_;
  NSString *request_initiator_;
  IMPLEMENT_REFCOUNTING(TatwoThirdPartyCookieAccessFilter);
};

class TatwoPendingResourceDecision final {
 public:
  explicit TatwoPendingResourceDecision(CefRefPtr<CefCallback> callback)
      : callback_(callback) {}

  void Resolve(bool allow) {
    CefRefPtr<CefCallback> callback = callback_;
    callback_ = nullptr;
    if (!callback) {
      return;
    }
    if (allow) {
      callback->Continue();
    } else {
      callback->Cancel();
    }
  }

  void CancelForShutdown() { Resolve(false); }

 private:
  CefRefPtr<CefCallback> callback_;
};

std::mutex g_pending_resource_decisions_mutex;
std::map<uint64_t, std::unique_ptr<TatwoPendingResourceDecision>>
    g_pending_resource_decisions;

bool RegisterPendingResourceDecision(
    CefRefPtr<CefCallback> callback,
    uint64_t *decision_id) {
  if (!callback || decision_id == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(
      g_pending_resource_decisions_mutex);
  if (g_shutdown_requested.load() || g_shutdown.load()) {
    return false;
  }
  const uint64_t identifier =
      g_resource_decision_seed.fetch_add(
          1, std::memory_order_relaxed) + 1;
  g_pending_resource_decisions.emplace(
      identifier,
      std::make_unique<TatwoPendingResourceDecision>(callback));
  *decision_id = identifier;
  return true;
}

void CompletePendingResourceDecision(uint64_t decision_id, bool allow) {
  std::unique_ptr<TatwoPendingResourceDecision> decision;
  {
    std::lock_guard<std::mutex> lock(
        g_pending_resource_decisions_mutex);
    auto iterator =
        g_pending_resource_decisions.find(decision_id);
    if (iterator == g_pending_resource_decisions.end()) {
      return;
    }
    decision = std::move(iterator->second);
    g_pending_resource_decisions.erase(iterator);
    g_resource_decisions_in_flight.fetch_add(
        1, std::memory_order_relaxed);
  }
  decision->Resolve(
      allow && !g_shutdown_requested.load() && !g_shutdown.load());
  decision.reset();
  g_resource_decisions_in_flight.fetch_sub(
      1, std::memory_order_relaxed);
}

void CancelPendingResourceDecisionsForShutdown() {
  std::vector<std::unique_ptr<TatwoPendingResourceDecision>> decisions;
  {
    std::lock_guard<std::mutex> lock(
        g_pending_resource_decisions_mutex);
    decisions.reserve(g_pending_resource_decisions.size());
    for (auto &entry : g_pending_resource_decisions) {
      decisions.push_back(std::move(entry.second));
    }
    g_pending_resource_decisions.clear();
  }
  for (const std::unique_ptr<TatwoPendingResourceDecision> &decision :
       decisions) {
    if (decision) {
      decision->CancelForShutdown();
    }
  }
}

size_t PendingResourceDecisionCount() {
  std::lock_guard<std::mutex> lock(
      g_pending_resource_decisions_mutex);
  return g_pending_resource_decisions.size() +
         g_resource_decisions_in_flight.load(
             std::memory_order_relaxed);
}

class TatwoResourceRequestHandler final : public CefResourceRequestHandler {
 public:
  TatwoResourceRequestHandler(
      TatwoCEFBrowserView *owner,
      NSString *request_initiator,
      BrowserRequestPolicySnapshot policy,
      ResourceErrorContext error_context)
      : owner_(owner),
        request_initiator_([request_initiator copy]),
        policy_(std::move(policy)),
        error_context_(std::move(error_context)) {}

  CefRefPtr<CefCookieAccessFilter> GetCookieAccessFilter(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) override {
    return new TatwoThirdPartyCookieAccessFilter(
        policy_.blocks_third_party_cookies,
        request_initiator_);
  }

  cef_return_value_t OnBeforeResourceLoad(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) override {
    NSString *request_url = FromCefString(request->GetURL());
    const bool is_main_frame = IsMainFrameRequest(request);
    const bool local_deny =
        IsDeniedByLocalHostList(policy_, request_url);
    if (local_deny) {
      RecordHostBlocklistRequest(
          is_main_frame,
          request->GetResourceType());
    }
    if (URLHasCredentials(request_url) ||
        !IsActorURLAllowed(policy_, request_url) ||
        local_deny) {
      if (is_main_frame) {
        LogBrowserNavigationTrace(
            @"main_resource_blocked", ERR_BLOCKED_BY_CLIENT, true);
        PublishResourceError(owner_, error_context_,
                             ResourceBlockMessage(policy_, request_url));
      }
      return RV_CANCEL;
    }

    if (policy_.sends_global_privacy_control) {
      request->SetHeaderByName("Sec-GPC", "1", true);
    }
    if (policy_.reduces_cross_origin_referrers) {
      NSString *referrer =
          FromCefString(request->GetReferrerURL());
      if (referrer.length > 0 &&
          !IsSameOrigin(referrer, request_url)) {
        NSString *origin = OriginForURLString(referrer);
        if (origin.length > 0) {
          request->SetReferrer(
              ToCefString(origin),
              REFERRER_POLICY_ORIGIN);
        }
      }
    }

    if (is_main_frame) {
      LogBrowserNavigationTrace(@"main_resource_allowed", 0, true);
    }
    if (URLHostIsIPAddress(request_url) && IsAllowedURLString(request_url)) {
      return RV_CONTINUE;
    }

    // DNS runs outside the IO-thread request callback. Every resource type,
    // including service workers and redirects, waits for a public-address
    // decision; failure or a private result cancels instead of falling back.
    uint64_t decision_id = 0;
    if (!RegisterPendingResourceDecision(callback, &decision_id)) {
      return RV_CANCEL;
    }
    __weak TatwoCEFBrowserView *weak_owner = owner_;
    const ResourceErrorContext error_context = error_context_;
    const bool human = policy_.human;
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          const PublicAddressResult result =
              ResolvePublicAddressResult(request_url);
          if (human && (result == PublicAddressResult::kNonPublic ||
                        !IsAllowedURLString(request_url))) {
            dispatch_async(dispatch_get_main_queue(), ^{
              TatwoCEFBrowserView *owner = weak_owner;
              if (!owner || !IsActiveMountCallback(owner, error_context.mount_generation, @"private_network_request") ||
                  !ActorRequestPolicy(owner).human ||
                  !error_context.epoch->IsCurrent(error_context.generation) ||
                  !owner.onPrivateNetworkRequested) {
                CompletePendingResourceDecision(decision_id, false);
                return;
              }
              owner.onPrivateNetworkRequested(CanonicalHost(request_url), ^(BOOL allowed) {
                const bool current = IsActiveMountCallback(weak_owner, error_context.mount_generation, @"private_network_decision") &&
                    ActorRequestPolicy(weak_owner).human &&
                    error_context.epoch->IsCurrent(error_context.generation);
                CompletePendingResourceDecision(decision_id, allowed && current);
              });
            });
            return;
          }
          const bool allow = result == PublicAddressResult::kPublic;
          if (!allow && is_main_frame) {
            const bool dns_failure = result == PublicAddressResult::kDNSFailure;
            PublishResourceError(
                weak_owner, error_context,
                dns_failure ? @"無法解析網站位址，請檢查網路或稍後重試"
                            : @"安全限制：網站解析到本機或私有網路位址",
                dns_failure);
          }
          CompletePendingResourceDecision(decision_id, allow);
        });
    return RV_CONTINUE_ASYNC;
  }

  void OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse> response,
                          CefString &new_url) override {
    NSString *redirect_url = FromCefString(new_url);
    const bool local_deny =
        IsDeniedByLocalHostList(policy_, redirect_url);
    if (URLHasCredentials(redirect_url) ||
        !IsActorURLAllowed(policy_, redirect_url) ||
        local_deny) {
      if (IsMainFrameRequest(request)) {
        PublishResourceError(owner_, error_context_,
                             ResourceBlockMessage(policy_, redirect_url));
      }
      new_url = "about:blank";
    }
  }

  void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefRequest> request,
                           bool &allow_os_execution) override {
    allow_os_execution = false;
  }

 private:
  __weak TatwoCEFBrowserView *owner_;
  NSString *request_initiator_;
  const BrowserRequestPolicySnapshot policy_;
  const ResourceErrorContext error_context_;
  IMPLEMENT_REFCOUNTING(TatwoResourceRequestHandler);
};

// Metadata callbacks are bound to the exact native mount and navigation.
class TatwoFaviconCallback final : public CefDownloadImageCallback {
 public:
  TatwoFaviconCallback(TatwoCEFBrowserView *owner, uint64_t mount,
                       uint64_t generation, NSString *url)
      : owner_(owner), mount_(mount), generation_(generation), url_(url) {}
  void OnDownloadImageFinished(const CefString &, int status, CefRefPtr<CefImage> image) override {
    TatwoCEFBrowserView *owner = owner_;
    if (!IsActiveMountCallback(owner, mount_, @"favicon") ||
        owner.navigationGeneration != generation_ || ![owner.currentURLString isEqualToString:url_] ||
        status >= 400 || !image || image->IsEmpty()) return;
    int width = 0, height = 0;
    auto png = image->GetAsPNG(1.0, true, width, height);
    if (!png || png->GetSize() > 256 * 1024) return;
    NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    if (owner.pageMetadataHandler) owner.pageMetadataHandler(url_, generation_, nil, data);
  }
 private:
  __weak TatwoCEFBrowserView *owner_;
  uint64_t mount_, generation_;
  NSString *url_;
  IMPLEMENT_REFCOUNTING(TatwoFaviconCallback);
};

class TatwoClient final : public CefClient,
                          public CefDevToolsMessageObserver,
                          public CefDisplayHandler,
                          public CefDownloadHandler,
                          public CefLifeSpanHandler,
                          public CefLoadHandler,
                          public CefPermissionHandler,
#pragma mark - W57d
                          public CefDialogHandler,
#pragma mark - W57d End
#pragma mark - W57a
                          public CefContextMenuHandler,
                          public CefFindHandler,
                          public CefKeyboardHandler,
#pragma mark - W57a end
                          public CefRequestHandler {
 public:
  explicit TatwoClient(TatwoCEFBrowserView *owner,
                       uint64_t mount_generation)
      : owner_(owner), mount_generation_(mount_generation) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

#pragma mark - W57d
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode,
      const CefString &title, const CefString &default_file_path,
      const std::vector<CefString> &accept_filters,
      const std::vector<CefString> &accept_extensions,
      const std::vector<CefString> &accept_descriptions,
      CefRefPtr<CefFileDialogCallback> callback) override;
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    CEF_REQUIRE_UI_THREAD();
    if (!IsActiveMountCallback(owner_, mount_generation_, @"fullscreen")) return;
    if (fullscreen && (!ActorRequestPolicy(owner_).human || !owner_.onFullscreenModeChange ||
        !owner_.window || owner_.isHiddenOrHasHiddenAncestor)) {
      browser->GetHost()->ExitFullscreen(true);
      return;
    }
    if (owner_.onFullscreenModeChange) owner_.onFullscreenModeChange(fullscreen);
  }
  void W57dCancel();
  void W57dDownloadUpdate(CefRefPtr<CefDownloadItem> item);
  CefRefPtr<CefFileDialogCallback> file_dialog_callback_;
  uint64_t file_dialog_serial_ = 0;
  uint64_t web_features_serial_ = 0;
  bool pdf_print_pending_ = false;
  NSString *pdf_download_url_;
  NSString *pdf_download_path_;
  uint32_t pdf_download_id_ = 0;
  void (^pdf_download_completion_)(NSString * _Nullable) = nil;
#pragma mark - W57d End

#pragma mark - W57a
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event,
                    CefEventHandle os_event, bool *is_keyboard_shortcut) override {
#pragma mark - W57d
    // Synthetic agent key events never invoke host menus or native dialogs.
    if (os_event && ActorRequestPolicy(owner_).human && event.type == KEYEVENT_RAWKEYDOWN) {
      if (event.windows_key_code == 27 && browser->GetHost()->IsFullscreen()) {
        [owner_ exitContentFullscreen];
        return true; // Fullscreen has priority even when a form field has focus.
      }
      if ((event.modifiers & EVENTFLAG_COMMAND_DOWN) &&
          !(event.modifiers & (EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN))) {
        const bool shift = event.modifiers & EVENTFLAG_SHIFT_DOWN;
        NSString *kind = nil;
        if (event.windows_key_code == 80) kind = shift ? @"printPDF" : @"print";
        else if (!shift) {
          switch (event.windows_key_code) {
            case 76: kind = @"focusAddress"; break;
            case 84: kind = @"newTab"; break;
            case 87: kind = @"closeTab"; break;
            case 82: kind = @"reload"; break;
          }
        }
        if (kind && owner_.onDailyShortcut) {
          if (browser->GetHost()->IsFullscreen()) [owner_ exitContentFullscreen];
          if (is_keyboard_shortcut) *is_keyboard_shortcut = true;
          owner_.onDailyShortcut(kind);
          return true; // Do not send host shortcuts to page JavaScript.
        }
      }
    }
#pragma mark - W57d End
    if (!ActorRequestPolicy(owner_).human || event.type != KEYEVENT_RAWKEYDOWN) return false;
    if (event.windows_key_code == 27 && event.modifiers == 0 && !event.focus_on_editable_field) {
      // W57a-fix: the host decides (close the find bar first, else stop loading).
      if (owner_.onDailyShortcut) { owner_.onDailyShortcut(@"escape"); return true; }
      browser->StopLoad(); return true;
    }
    if (!(event.modifiers & EVENTFLAG_COMMAND_DOWN) ||
        (event.modifiers & (EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN))) return false;
    const int key = event.windows_key_code;
    const bool shift = event.modifiers & EVENTFLAG_SHIFT_DOWN;
    const bool shortcut = (key == 84 && shift) || key == 187 ||
        (!shift && (key == 219 || key == 221 || key == 70 || key == 189 || (key >= 48 && key <= 57)));
#pragma mark - W57d
    // Keep W57a's browser shortcuts ahead of app-wide menu equivalents.
    // Other app commands go to AppKit before JS, with no sendEvent recursion.
    // Unclaimed editing keys and Tab retain Chromium's normal behavior.
    if (!shortcut && os_event &&
        [NSApp.mainMenu performKeyEquivalent:(__bridge NSEvent *)os_event]) return true;
#pragma mark - W57d End
    if (!shortcut || !os_event) return false;
    // Native CEF input does not necessarily reach SwiftUI key equivalents. The callback
    // enters the same focus-scoped actions as the hidden Buttons; no menu recursion.
    if (!owner_.onDailyShortcut) return false;
    NSString *kind = nil;
    if (key == 84) kind = @"reopen";
    else if (key == 219) kind = @"back";
    else if (key == 221) kind = @"forward";
    else if (key == 70) kind = @"find";
    else if (key == 187) kind = @"zoomIn";
    else if (key == 189) kind = @"zoomOut";
    else if (key == 48) kind = @"zoomReset";
    else kind = [NSString stringWithFormat:@"tab%d", key - 48];
    owner_.onDailyShortcut(kind);
    return true;
  }
  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                    const CefRect &selection, int active, bool final_update) override {
    if (ActorRequestPolicy(owner_).human && owner_.onFindResult)
      owner_.onFindResult(count, active);
  }
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model) override {
    model->Clear();
    if (!owner_ || owner_.browserActor == TatwoCEFBrowserActorAgent || owner_.agentControlled) return;
    if (!params->GetLinkUrl().empty()) {
      model->AddItem(26501, "在新分頁開啟"); model->AddItem(26502, "拷貝連結");
    }
    if (params->GetMediaType() == CM_MEDIATYPE_IMAGE) {
      model->AddItem(26503, "拷貝圖片網址"); model->AddItem(26504, "另存圖片…");
    }
    if (params->IsEditable()) {
      model->AddItem(26505, "剪下"); model->AddItem(26506, "拷貝");
      model->AddItem(26507, "貼上"); model->AddItem(26508, "全選");
    } else if (!params->GetSelectionText().empty()) {
      model->AddItem(26506, "拷貝");
    }
    if (!params->GetSelectionText().empty()) {
      NSString *title = [NSString stringWithFormat:@"用 %@ 搜尋", owner_.contextSearchEngineTitle ?: @"Google"];
      model->AddItem(26509, ToCefString(title));
    }
    model->AddSeparator();
    model->AddItem(26510, "返回"); model->SetEnabled(26510, browser->CanGoBack());
    model->AddItem(26511, "前進"); model->SetEnabled(26511, browser->CanGoForward());
    model->AddItem(26512, "重新載入");
#pragma mark - W57d
    model->AddSeparator();
    model->AddItem(26513, "列印…");
    model->AddItem(26514, "列印備援：PDF → 系統預覽");
    NSString *page = FromCefString(browser->GetMainFrame()->GetURL());
    if ([[NSURL URLWithString:page].path.pathExtension.lowercaseString isEqualToString:@"pdf"])
      model->AddItem(26515, "下載 PDF 並用系統預覽開啟");
#pragma mark - W57d End
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefContextMenuParams> params, int command, EventFlags flags) override {
#pragma mark - W57d
    if (command >= 26513 && command <= 26515) {
      if (ActorRequestPolicy(owner_).human && owner_.onDailyShortcut)
        owner_.onDailyShortcut(command == 26513 ? @"print" : command == 26514 ? @"printPDF" : @"openPDF");
      return true;
    }
#pragma mark - W57d End
    if (!ActorRequestPolicy(owner_).human || !owner_.onContextMenuAction) return true;
    NSString *kind = nil, *value = @"";
    switch (command) {
      case 26501: kind = @"open"; value = FromCefString(params->GetLinkUrl()); break;
      case 26502: kind = @"copyURL"; value = FromCefString(params->GetLinkUrl()); break;
      case 26503: kind = @"copyURL"; value = FromCefString(params->GetSourceUrl()); break;
      case 26504: kind = @"download"; value = FromCefString(params->GetSourceUrl()); break;
      case 26505: kind = @"cut"; break;
      case 26506: kind = @"copy"; value = FromCefString(params->GetSelectionText()); break;
      case 26507: kind = @"paste"; break;
      case 26508: kind = @"selectAll"; break;
      case 26509: kind = @"search"; value = FromCefString(params->GetSelectionText()); break;
      case 26510: kind = @"back"; break;
      case 26511: kind = @"forward"; break;
      case 26512: kind = @"reload"; break;
      default: return false;
    }
    if ([kind isEqualToString:@"open"]) {
      auto policy = ActorRequestPolicy(owner_);
      if (URLHasCredentials(value) || !IsActorURLAllowed(policy, value) || IsDeniedByLocalHostList(policy, value)) return true;
    }
    owner_.onContextMenuAction(kind, value);
    return true;
  }
#pragma mark - W57a end

  void InvalidateResourceErrors() { resource_epoch_->Advance(); }
  void DetachOwner() { InvalidateResourceErrors(); owner_ = nil; }

  void AbandonPendingCreation() {
    InvalidateResourceErrors();
    close_late_browser_ = true;
    owner_ = nil;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void CaptureVisibleSnapshot(
      CefRefPtr<CefBrowser> browser,
      NSString *committed_url,
      uint64_t navigation_generation,
      NSSize viewport_size,
      TatwoCEFBrowserSnapshotHandler completion);
  void CancelPendingBrowserOperations();
  void CheckAgentFocus(CefRefPtr<CefBrowser> browser, uint64_t generation,
                      TatwoCEFBrowserInputDispatchGate gate, TatwoCEFBrowserInputHandler completion) {
    BeginNodeInput(browser, 1, NodeInputKind::focus, nil, false, NSZeroPoint, NSZeroRect,
                   NSZeroSize, generation, gate, completion);
  }
  void SelectValue(CefRefPtr<CefBrowser> browser, int node, NSString *value, uint64_t generation,
                   TatwoCEFBrowserInputDispatchGate gate, TatwoCEFBrowserInputHandler completion) {
    BeginNodeInput(browser, node, NodeInputKind::select, value, false, NSZeroPoint, NSZeroRect,
                   NSZeroSize, generation, gate, completion);
  }
  void TypeText(CefRefPtr<CefBrowser> browser, int backend_node_id,
                NSString *text, uint64_t generation, bool submit,
                TatwoCEFBrowserInputDispatchGate dispatch_gate,
                TatwoCEFBrowserInputHandler completion);
  void ClickElement(CefRefPtr<CefBrowser> browser, int backend_node_id,
                    NSPoint point, NSRect expected_rect, NSSize viewport,
                    uint64_t generation,
                    TatwoCEFBrowserInputDispatchGate dispatch_gate,
                    TatwoCEFBrowserInputHandler completion);
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override;
  bool OnProcessMessageReceived(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefProcessId source_process,
      CefRefPtr<CefProcessMessage> message) override;
  void InvokeWebMCPTool(
      CefRefPtr<CefBrowser> browser,
      NSString *tool_name,
      NSString *arguments_json,
      uint64_t navigation_generation,
      TatwoCEFWebMCPInvocationHandler completion);
  void CancelPendingWebMCPInvocations(NSString *error_code);

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString &target_url,
                     const CefString &target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures &popup_features,
                     CefWindowInfo &window_info,
                     CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override;

  bool CanDownload(CefRefPtr<CefBrowser> browser,
                   const CefString &url,
                   const CefString &request_method) override {
    if (ActorRequestPolicy(owner_).human) return true;
    PublishVisibleError(owner_,
                        kDownloadBlockedError,
                        TatwoCEFBrowserErrorKindSecurity,
                        ERR_BLOCKED_BY_CLIENT,
                        TatwoCEFBrowserPhaseBlockedBySecurity);
    return false;
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> item, const CefString &suggested_name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (!ActorRequestPolicy(owner_).human) return true;
    NSString *name = FromCefString(suggested_name).lastPathComponent;
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) name = @"download";
    // Exclusive reservation prevents overwriting existing files or following a
    // pre-existing symlink. CEF may write only this newly reserved destination.
    NSString *root = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [root stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) {
      name = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, name];
      path = [root stringByAppendingPathComponent:name];
      fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    }
    if (fd < 0) return true;
    close(fd);
#pragma mark - W57d
    if (pdf_download_completion_ && !pdf_download_path_ &&
        [pdf_download_url_ isEqualToString:FromCefString(item->GetOriginalUrl())]) {
      pdf_download_id_ = item->GetId();
      pdf_download_path_ = path;
    }
#pragma mark - W57d End
    callback->Continue(ToCefString(path), false);
    return true;
  }

  void OnDownloadUpdated(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> download_item,
      CefRefPtr<CefDownloadItemCallback> callback) override {
#pragma mark - W57d
    W57dDownloadUpdate(download_item);
#pragma mark - W57d End
    if (ActorRequestPolicy(owner_).human) {
      NSString *filename = FromCefString(download_item->GetFullPath()).lastPathComponent;
      if (!filename.length) filename = FromCefString(download_item->GetSuggestedFileName()).lastPathComponent;
      NSString *identifier = [NSString stringWithFormat:@"%d-%u", browser->GetIdentifier(), download_item->GetId()];
      if (owner_.onDownloadProgress) owner_.onDownloadProgress(identifier, filename,
          download_item->GetReceivedBytes(), download_item->GetTotalBytes(), download_item->IsComplete());
      return;
    }
    callback->Cancel();
    PublishVisibleError(owner_,
                        kDownloadBlockedError,
                        TatwoCEFBrowserErrorKindSecurity,
                        ERR_BLOCKED_BY_CLIENT,
                        TatwoCEFBrowserPhaseBlockedBySecurity);
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"on_before_browse")) {
      return true;
    }
    NSString *request_url = FromCefString(request->GetURL());
    // OAuth may create an empty, same-origin popup before assigning its HTTPS
    // destination. about:blank is inert, not permission to fetch a private URL.
    if (browser && browser->IsPopup() &&
        [request_url isEqualToString:@"about:blank"]) {
      return false;
    }
    if (IsMainFrameRequest(request) && !is_redirect) {
      InvalidateResourceErrors();
    }
    BrowserRequestPolicySnapshot policy = ActorRequestPolicy(owner_);
    const bool local_deny =
        IsDeniedByLocalHostList(policy, request_url);
    if (URLHasCredentials(request_url) ||
        !IsActorURLAllowed(policy, request_url) ||
        local_deny) {
      if (frame && frame->IsMain()) {
        LogBrowserNavigationTrace(
            @"main_navigation_blocked", ERR_BLOCKED_BY_CLIENT, true);
        PublishVisibleError(owner_,
                            ResourceBlockMessage(policy, request_url),
                            TatwoCEFBrowserErrorKindSecurity,
                            ERR_BLOCKED_BY_CLIENT,
                            TatwoCEFBrowserPhaseBlockedBySecurity);
      }
      return true;
    }
    if (frame && frame->IsMain()) {
      BeginRendererNavigationIfNeeded(owner_);
      LogBrowserNavigationTrace(
          is_redirect ? @"main_navigation_redirect_allowed"
                      : @"main_navigation_allowed",
          0,
          true);
      LogBrowserTimeline(
          is_redirect ? @"navigation_redirect_accepted"
                      : @"navigation_accepted",
          mount_generation_,
          0,
          true);
    }
    return false;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString &target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    NSString *url = FromCefString(target_url);
    BrowserRequestPolicySnapshot policy = ActorRequestPolicy(owner_);
    const bool allow = user_gesture && !URLHasCredentials(url) &&
        IsActorURLAllowed(policy, url) && !IsDeniedByLocalHostList(policy, url);
    if (!allow) LogBrowserLifecycle(@"popup_blocked");
#pragma mark - W57a
    if (policy.human) {
      if (allow && owner_.onPopupRequested) owner_.onPopupRequested(url);
      return true; // handled: background registry tab, no native popup or opener navigation
    }
#pragma mark - W57a end
    // Allowed new-window requests still pass through OnBeforePopup. A rejected
    // popup must not replace the opener's valid document with an error overlay.
    return !allow;
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString &request_initiator,
      bool &disable_default_handling) override {
    if (is_download && !ActorRequestPolicy(owner_).human) {
      disable_default_handling = true;
      PublishVisibleError(owner_,
                          kDownloadBlockedError,
                          TatwoCEFBrowserErrorKindSecurity,
                          ERR_BLOCKED_BY_CLIENT,
                          TatwoCEFBrowserPhaseBlockedBySecurity);
    }
    BrowserRequestPolicySnapshot policy = ActorRequestPolicy(owner_);
    return new TatwoResourceRequestHandler(
        owner_,
        FromCefString(request_initiator),
        std::move(policy),
        {resource_epoch_, resource_epoch_->Capture(), mount_generation_});
  }

  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                          const CefString &origin_url,
                          bool is_proxy,
                          const CefString &host,
                          int port,
                          const CefString &realm,
                          const CefString &scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    PublishVisibleError(
        owner_,
        kAuthenticationBlockedError,
        TatwoCEFBrowserErrorKindSecurity,
        ERR_ACCESS_DENIED,
        TatwoCEFBrowserPhaseBlockedBySecurity);
    return false;
  }

  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString &request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override {
    NSString *host = CanonicalHost(FromCefString(request_url));
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=security_capability event=certificate_error_denied "
             "code=%d host=%@",
            static_cast<int>(cert_error),
            SanitizeTelemetryToken(host, @"unknown")]);
    PublishVisibleError(
        owner_,
        kCertificateBlockedError,
        TatwoCEFBrowserErrorKindSecurity,
        cert_error,
        TatwoCEFBrowserPhaseBlockedBySecurity);
    return false;
  }

  bool OnSelectClientCertificate(
      CefRefPtr<CefBrowser> browser,
      bool is_proxy,
      const CefString &host,
      int port,
      const X509CertificateList &certificates,
      CefRefPtr<CefSelectClientCertificateCallback> callback) override {
    callback->Select(nullptr);
    PublishVisibleError(
        owner_,
        kAuthenticationBlockedError,
        TatwoCEFBrowserErrorKindSecurity,
        ERR_ACCESS_DENIED,
        TatwoCEFBrowserPhaseBlockedBySecurity);
    return true;
  }

  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (ActorRequestPolicy(owner_).human && owner_.onPermissionRequested) {
      NSMutableArray<NSString *> *names = [NSMutableArray array];
      if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [names addObject:@"相機"];
      if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [names addObject:@"麥克風"];
      if (requested_permissions & ~(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)) { callback->Cancel(); return true; }
      __weak TatwoCEFBrowserView *weak_owner = owner_;
      const uint64_t mount = mount_generation_;
      const uint64_t generation = owner_.navigationGeneration;
      owner_.onPermissionRequested(FromCefString(requesting_origin), [names componentsJoinedByString:@"／"], ^(BOOL decision) {
        TatwoCEFBrowserView *owner = weak_owner;
        const bool allowed = decision && IsPermissionReplyLive(owner, mount, generation);
        callback->Continue(allowed ? requested_permissions : 0);
        ScheduleImmediateCEFMessagePumpWork(@"permission_decision");
      });
      return true;
    }
    callback->Cancel();
    PublishVisibleError(owner_,
                        kPermissionBlockedError,
                        TatwoCEFBrowserErrorKindSecurity,
                        ERR_ACCESS_DENIED,
                        TatwoCEFBrowserPhaseBlockedBySecurity);
    return true;
  }

  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (ActorRequestPolicy(owner_).human && owner_.onPermissionRequested) {
      NSMutableArray<NSString *> *names = [NSMutableArray array];
      if (requested_permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM) [names addObject:@"相機"];
      if (requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM) [names addObject:@"麥克風"];
      if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) [names addObject:@"位置"];
      if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) [names addObject:@"通知"];
      if (requested_permissions & ~(CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM | CEF_PERMISSION_TYPE_GEOLOCATION | CEF_PERMISSION_TYPE_NOTIFICATIONS)) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
      __weak TatwoCEFBrowserView *weak_owner = owner_;
      const uint64_t mount = mount_generation_;
      const uint64_t generation = owner_.navigationGeneration;
      owner_.onPermissionRequested(FromCefString(requesting_origin), [names componentsJoinedByString:@"／"], ^(BOOL decision) {
        TatwoCEFBrowserView *owner = weak_owner;
        const bool allowed = decision && IsPermissionReplyLive(owner, mount, generation);
        callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        ScheduleImmediateCEFMessagePumpWork(@"permission_decision");
      });
      return true;
    }
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    PublishVisibleError(owner_,
                        kPermissionBlockedError,
                        TatwoCEFBrowserErrorKindSecurity,
                        ERR_ACCESS_DENIED,
                        TatwoCEFBrowserPhaseBlockedBySecurity);
    return true;
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool is_loading,
                            bool can_go_back,
                            bool can_go_forward) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"loading_state_change")) {
      return;
    }
    LogBrowserNavigationTrace(
        @"loading_state_changed", 0, is_loading);
    UpdateLoadingState(owner_, is_loading);
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"load_start")) {
      return;
    }
    if (!frame || !frame->IsMain()) {
      return;
    }
    LogBrowserNavigationTrace(@"main_frame_load_start", 0, true);
    PublishMainFrameLoadStart(owner_);
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"load_end")) {
      return;
    }
    if (frame && frame->IsMain()) {
      TatwoCEFBrowserView *owner = owner_;
      FinishNavigationFrameTelemetry(owner);
      StopLoadingActiveMessagePump(
          owner, mount_generation_, @"main_frame_load_end");
      LogBrowserNavigationTrace(
          @"main_frame_load_end", http_status_code, false);
      LogBrowserTimeline(
          @"main_frame_load_end",
          mount_generation_,
          http_status_code,
          false);
      PublishMainFrameLoadEnd(owner, frame, http_status_code);
#pragma mark - W57c Scan only after human main_frame_load_end
      W57cLoadEnd(owner, frame, http_status_code);
#pragma mark - W57c End
#pragma mark - W58
      W58LoadEnd(owner, frame, http_status_code);
#pragma mark - W58 End
      RequestBrowserCompositorDisplay(
          owner, browser, @"main_frame_load_end");
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    TatwoCEFBrowserView *owner = owner_;
    if (!IsActiveMountCallback(owner, mount_generation_, @"title") || !owner.pageMetadataHandler) return;
    NSString *url = owner.currentURLString;
    if (url.length) owner.pageMetadataHandler(url, owner.navigationGeneration, FromCefString(title), nil);
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                         const std::vector<CefString> &urls) override {
    TatwoCEFBrowserView *owner = owner_;
    if (!IsActiveMountCallback(owner, mount_generation_, @"favicon_url") ||
        !owner.pageMetadataHandler || urls.empty() || !owner.currentURLString.length) return;
    NSString *imageURL = FromCefString(urls.front());
    const auto policy = ActorRequestPolicy(owner);
    if (URLHasCredentials(imageURL) || !IsActorURLAllowed(policy, imageURL) ||
        IsDeniedByLocalHostList(policy, imageURL)) return;
    // Use this browser's secured request context, not URLSession or a global fetch.
    browser->GetHost()->DownloadImage(urls.front(), true, 32, false,
        new TatwoFaviconCallback(owner, mount_generation_, owner.navigationGeneration, owner.currentURLString));
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"address_change")) {
      return;
    }
    if (frame->IsMain()) {
      LogBrowserNavigationTrace(@"main_frame_commit", 0, true);
      LogBrowserTimeline(
          @"main_frame_commit",
          mount_generation_,
          0,
          true);
      PublishMainFrameCommit(owner_, url);
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode error_code,
                   const CefString &error_text,
                   const CefString &failed_url) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"load_error")) {
      return;
    }
    if (!frame || !frame->IsMain()) {
      return;
    }
    // Chromium aborts the previous load when navigation changes. Explicit
    // policy errors are published by the request handler with its own epoch.
    if (error_code == ERR_ABORTED) {
      return;
    }
    FinishNavigationFrameTelemetry(owner_);
    StopLoadingActiveMessagePump(
        owner_, mount_generation_, @"main_frame_load_error");
    LogBrowserNavigationTrace(
        @"main_frame_load_error", error_code, false);
    TatwoCEFBrowserView *owner = owner_;
    if (HasVisibleSecurityError(owner)) {
      PublishState(owner);
      return;
    }
    PublishVisibleError(owner,
                        @"頁面載入失敗，請檢查網址或網路後重試",
                        TatwoCEFBrowserErrorKindNavigation,
                        error_code,
                        TatwoCEFBrowserPhaseNavigationFailed);
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override {
    if (!IsActiveMountCallback(
            owner_, mount_generation_, @"renderer_terminated")) {
      return;
    }
#pragma mark - W60
    W60RecordRendererTermination(browser, status, error_code, mount_generation_);
    W57dInvalidate(owner_); // Only the active mount may revoke current UI work.
#pragma mark - W60 End
    StopLoadingActiveMessagePump(
        owner_, mount_generation_, @"renderer_terminated");
    LogRendererTermination(status, error_code);
#pragma mark - W57c Renderer failure revokes pending credentials
    W57cInvalidate(owner_, false, false);
#pragma mark - W57c End
#pragma mark - W58
    W58Invalidate(owner_, false);
#pragma mark - W58 End
    InvalidateWebMCPForRendererTermination(owner_);
    InvalidateSecurityDocumentEpoch(
        owner_, @"renderer_terminated");
    PublishVisibleError(owner_,
                        @"Chromium renderer 已停止，請重新載入",
                        TatwoCEFBrowserErrorKindRenderer,
                        error_code,
                        TatwoCEFBrowserPhaseRendererFailed);
  }

 private:
  enum class NodeInputKind { text, click, select, focus };
  enum class TypeStage {
    idle, readingFrame, creatingWorld, resolvingNode, applyingText,
    readingClickMetrics, locatingHit, resolvingHit, checkingClick, dispatchingClick
  };
  void FinishVisibleSnapshot(NSString *json, NSString *error_code);
  void SnapshotTimedOut(int message_id);
  void OnTypeTextResult(CefRefPtr<CefBrowser> browser, bool success,
                        const void *result, size_t result_size);
  int DispatchTypeCommand(CefRefPtr<CefBrowser> browser, const char *method,
                          CefRefPtr<CefDictionaryValue> params);
  void BeginNodeInput(CefRefPtr<CefBrowser> browser, int backend_node_id,
                      NodeInputKind kind, NSString *text, bool submit,
                      NSPoint point, NSRect expected_rect, NSSize viewport,
                      uint64_t generation,
                      TatwoCEFBrowserInputDispatchGate dispatch_gate,
                      TatwoCEFBrowserInputHandler completion);
  BOOL DispatchCheckedClick(CefRefPtr<CefBrowser> browser);
  void FinishTypeText(BOOL completed, NSString *error_code);

  __weak TatwoCEFBrowserView *owner_;
  const uint64_t mount_generation_;
  const std::shared_ptr<ResourceNavigationEpoch> resource_epoch_ =
      std::make_shared<ResourceNavigationEpoch>();
  CefRefPtr<CefRegistration> snapshot_devtools_registration_;
  TatwoCEFBrowserSnapshotHandler snapshot_completion_;
  NSString *snapshot_committed_url_;
  uint64_t snapshot_navigation_generation_ = 0;
  NSSize snapshot_viewport_size_ = NSZeroSize;
  int snapshot_message_id_ = 0;
  CefRefPtr<CefRegistration> type_devtools_registration_;
  CefRefPtr<CefBrowser> type_browser_;
  TatwoCEFBrowserInputHandler type_completion_;
  TatwoCEFBrowserInputDispatchGate type_dispatch_gate_;
  NSString *type_text_;
  NSString *type_committed_url_;
  NSString *type_object_group_;
  NSString *type_frame_id_;
  NSString *type_target_object_id_;
  uint64_t type_navigation_generation_ = 0;
  uint64_t type_request_serial_ = 0;
  int type_message_id_ = 0;
  int type_backend_node_id_ = 0;
  int type_context_id_ = 0;
  // One shared single-flight resolver slot; the legacy type_ prefix is retained.
  // Kind and stage are explicit, not a Boolean overloaded between input types.
  NodeInputKind type_kind_ = NodeInputKind::text;
  TypeStage type_stage_ = TypeStage::idle;
  NSPoint type_click_point_ = NSZeroPoint;
  NSRect type_click_rect_ = NSZeroRect;
  NSSize type_click_viewport_ = NSZeroSize;
  bool type_submit_ = false;
  bool close_late_browser_ = false;
  std::map<std::string, TatwoCEFWebMCPInvocationHandler>
      webmcp_invocations_;
  IMPLEMENT_REFCOUNTING(TatwoClient);
};

struct BrowserState {
#pragma mark - W57a
  std::string find_text;
  bool find_match_case = false;
#pragma mark - W57a end
  CefRefPtr<CefBrowserHost> agent_pointer_host;
  CefMouseEvent agent_pointer_event;
  CefRefPtr<CefBrowserHost> agent_key_host;
  CefKeyEvent agent_key_event;
  CefRefPtr<TatwoClient> client;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRequestContext> request_context;
  CefRefPtr<TatwoPrivacyStrictRequestContextHandler> request_context_handler;
  NSString *pending_error;
  NSString *pending_url;
  TatwoCEFBrowserInputDispatchGate pending_navigation_gate;
  NSString *committed_url;
  NSMutableArray *close_handlers;
  NSTimer *loading_active_pump_timer;
  NSString *last_embedding_signature;
  NSString *last_screen_info_signature;
  NSInteger http_status_code = 0;
  NSInteger error_code = 0;
  TatwoCEFBrowserPhase phase = TatwoCEFBrowserPhaseBlank;
  TatwoCEFBrowserErrorKind error_kind = TatwoCEFBrowserErrorKindNone;
  bool is_loading = false;
  bool parent_mismatch_reported = false;
  bool creation_attempted = false;
  bool creation_pending = false;
  bool close_requested = false;
  bool close_completed = false;
  bool close_retry_scheduled = false;
  bool geometry_layer_ready_logged = false;
  bool request_context_security_ready = false;
  bool request_context_security_blocked = false;
  LoadingActiveMessagePumpGate loading_active_pump_gate;
  uint64_t mount_generation = 0;
  uint64_t navigation_generation = 0;
  uint64_t security_navigation_generation = 0;
  uint64_t document_epoch = 0;
  uint64_t first_frame_presented_generation = 0;
  uint64_t close_generation = 0;
  NSUInteger close_retry_attempt = 0;
  bool document_epoch_valid = false;
  bool navigation_in_flight = false;
#pragma mark - W57c Navigation-bound password capability (no values)
  NSString *password_assist_token;
  bool password_assist_scan_pending = false;
  int password_assist_status = 0;
#pragma mark - W57c End
#pragma mark - W58 Native metadata only; secret lifetime ends at renderer dispatch
  NSString *ai_login_token, *ai_login_form, *ai_login_error, *ai_login_title, *ai_login_origin;
  NSString *ai_login_phase = @"idle";
  bool ai_login_awaiting_load = false;
#pragma mark - W58 End
  NSMutableDictionary<NSString *, NSDictionary *> *webmcp_tools;
  NSMutableDictionary<NSString *, NSDictionary *> *pending_webmcp_tools;
  NSMutableArray<TatwoCEFBrowserView *> *popup_views;
  __weak TatwoCEFBrowserView *opener;
  NSWindow *popup_window;
  int popup_id = -1;
};

bool HasActiveBrowserPumpWork(const BrowserState *state) {
  return HasActiveBrowserPumpWork(
      state->is_loading, state->phase == TatwoCEFBrowserPhaseCreating,
      state->request_context_security_ready,
      state->request_context_security_blocked, state->creation_pending);
}

BrowserState *State(TatwoCEFBrowserView *view) {
  return view == nil
      ? nullptr
      : static_cast<BrowserState *>(view->_cefState);
}

#pragma mark - W57c Browser-side credential gates
bool W57cHumanPage(TatwoCEFBrowserView *view, BrowserState *state) {
  return NSThread.isMainThread && view && state && state->browser && !state->close_requested &&
      view.browserActor == TatwoCEFBrowserActorHuman && !view.agentControlled &&
      view.passwordAssistEnabled;
}

void W57cInvalidate(TatwoCEFBrowserView *view, bool reload, bool preserve_submission) {
  BrowserState *state = State(view);
  if (!state) return;
  state->password_assist_token = nil;
  state->password_assist_scan_pending = false;
  if (state->browser && state->browser->GetMainFrame()) {
    auto message = CefProcessMessage::Create(kPasswordConfigureMessage);
    auto args = message->GetArgumentList();
    args->SetString(0, std::to_string(state->navigation_generation));
    args->SetString(1, "");
    args->SetString(2, "");
    args->SetString(3, "");
    args->SetBool(4, false);
    args->SetBool(5, false);
    state->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
  }
  if (view.onPasswordAssistInvalidated) view.onPasswordAssistInvalidated(reload, preserve_submission);
}

void W57cLoadEnd(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, int status) {
  BrowserState *state = State(view);
  if (!W57cHumanPage(view, state) || !frame || !frame->IsMain() ||
      state->navigation_generation == 0 || state->navigation_in_flight) return;
  NSString *url = FromCefString(frame->GetURL());
  NSString *origin = OriginForURLString(url);
  if (origin.length == 0 || ![origin hasPrefix:@"https://"] ||
      ![OriginForURLString(state->committed_url) isEqualToString:origin]) {
    W57cInvalidate(view, false, false);
    return;
  }
  // Duplicate CEF load-end notifications cannot reinstall listeners or repeat a prompt.
  if (state->password_assist_token.length) return;
  state->password_assist_token = NSUUID.UUID.UUIDString;
  state->password_assist_scan_pending = true;
  state->password_assist_status = status;
  auto message = CefProcessMessage::Create(kPasswordConfigureMessage);
  auto args = message->GetArgumentList();
  args->SetString(0, std::to_string(state->navigation_generation));
  args->SetString(1, ToCefString(state->password_assist_token));
  args->SetString(2, ToCefString(origin));
  args->SetString(3, frame->GetURL());
  args->SetBool(4, true); // Never sent for agent actor or agentControlled.
  args->SetBool(5, true);
  frame->SendProcessMessage(PID_RENDERER, message);
}

bool W57cBrowserMessage(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefProcessMessage> message) {
  if (!message || message->GetName() != kPasswordEventMessage) return false;
  BrowserState *state = State(view);
  auto args = message->GetArgumentList();
  if (!W57cHumanPage(view, state) || !frame || !frame->IsMain() || !args ||
      args->GetSize() < 5 || state->navigation_in_flight || !state->password_assist_token.length ||
      args->GetString(0).ToString() != std::to_string(state->navigation_generation) ||
      args->GetString(1) != ToCefString(state->password_assist_token)) return true;
  NSString *origin = FromCefString(args->GetString(2));
  if (![origin isEqualToString:OriginForURLString(state->committed_url)] ||
      ![origin isEqualToString:OriginForURLString(FromCefString(frame->GetURL()))]) return true;
  const auto kind = args->GetString(3);
  if (kind == "scanned" && args->GetSize() == 5) {
    if (!state->password_assist_scan_pending) return true;
    state->password_assist_scan_pending = false;
    if (view.onPasswordAssistPageLoaded) view.onPasswordAssistPageLoaded(
        origin, state->navigation_generation,
        state->password_assist_status >= 200 && state->password_assist_status < 300,
        args->GetString(4) != "0");
  } else if (kind == "detected" && args->GetSize() == 8 && !state->password_assist_scan_pending) {
    for (size_t i = 4; i < 8; ++i)
      if (args->GetString(i).ToString().size() > 4096) return true;
    if (view.onLoginFormDetected) view.onLoginFormDetected(
        origin, FromCefString(args->GetString(4)), FromCefString(args->GetString(5)),
        FromCefString(args->GetString(6)), FromCefString(args->GetString(7)));
  } else if (kind == "submitted" && args->GetSize() == 6) {
    if (args->GetString(4).ToString().size() > 4096 ||
        args->GetString(5).ToString().size() > 16384) return true;
    if (view.onCredentialSubmitted) view.onCredentialSubmitted(
        origin, FromCefString(args->GetString(4)), FromCefString(args->GetString(5)));
  }
  return true;
}
#pragma mark - W57c End

#pragma mark - W58 Native agent gates and next-load result
bool W58AgentPage(TatwoCEFBrowserView *view, BrowserState *state) {
  return NSThread.isMainThread && view && state && state->browser && !state->close_requested &&
    view.browserActor == TatwoCEFBrowserActorAgent;
}
void W58Invalidate(TatwoCEFBrowserView *view, bool preserve_result) {
  auto state = State(view);
  if (!state) return;
  state->ai_login_token = nil; state->ai_login_form = nil;
  if (!preserve_result || !state->ai_login_awaiting_load) {
    state->ai_login_awaiting_load = false;
    state->ai_login_phase = @"idle"; state->ai_login_error = nil; state->ai_login_title = nil;
    state->ai_login_origin = nil;
  }
  if (state->browser && state->browser->GetMainFrame()) {
    auto message = CefProcessMessage::Create(kAILoginConfigure);
    auto args = message->GetArgumentList();
    for (int i = 0; i < 4; ++i) args->SetString(i, "");
    args->SetInt(4, 2);
    state->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
  }
}
bool W58Scan(TatwoCEFBrowserView *view, bool completed) {
  auto state = State(view);
  if (!W58AgentPage(view, state) || state->navigation_in_flight || state->navigation_generation == 0) return false;
  auto frame = state->browser->GetMainFrame();
  NSString *origin = OriginForURLString(state->committed_url);
  if (!frame || !frame->IsValid() || ![origin hasPrefix:@"https://"] ||
      ![origin isEqualToString:OriginForURLString(FromCefString(frame->GetURL()))]) return false;
  if (completed && ![origin isEqualToString:state->ai_login_origin]) return false;
  if (!completed) state->ai_login_origin = origin;
  state->ai_login_token = NSUUID.UUID.UUIDString;
  state->ai_login_form = nil;
  state->ai_login_phase = completed ? @"checking" : @"preparing";
  auto message = CefProcessMessage::Create(kAILoginConfigure);
  auto args = message->GetArgumentList();
  args->SetString(0, std::to_string(state->navigation_generation));
  args->SetString(1, ToCefString(state->ai_login_token));
  args->SetString(2, ToCefString(origin)); args->SetString(3, frame->GetURL());
  args->SetInt(4, completed ? 1 : 0);
  frame->SendProcessMessage(PID_RENDERER, message);
  return true;
}
void W58LoadEnd(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, int status) {
  auto state = State(view);
  if (!W58AgentPage(view, state) || !frame || !frame->IsMain() || !state->ai_login_awaiting_load ||
      state->ai_login_token.length) return;
  if (![OriginForURLString(FromCefString(frame->GetURL())) isEqualToString:state->ai_login_origin]) {
    state->ai_login_error = @"ai_login_origin_changed_do_not_replay"; state->ai_login_phase = @"failed";
    state->ai_login_awaiting_load = false;
    return;
  }
  if (status < 200 || status >= 300 || !W58Scan(view, true)) {
    state->ai_login_error = @"ai_login_load_failed"; state->ai_login_phase = @"failed";
    state->ai_login_awaiting_load = false;
  }
}
bool W58BrowserMessage(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame, CefRefPtr<CefProcessMessage> message) {
  if (!message || message->GetName() != kAILoginEvent) return false;
  auto state = State(view);
  auto args = message->GetArgumentList();
  if (!W58AgentPage(view, state) || !frame || !frame->IsMain() || !args || args->GetSize() != 6 ||
      state->navigation_in_flight || !state->ai_login_token.length ||
      args->GetString(0).ToString() != std::to_string(state->navigation_generation) ||
      args->GetString(1) != ToCefString(state->ai_login_token) ||
      ![OriginForURLString(state->committed_url) isEqualToString:OriginForURLString(FromCefString(frame->GetURL()))]) return true;
  for (size_t i = 2; i < 6; ++i) if (args->GetString(i).ToString().size() > 4096) return true;
  NSString *phase = FromCefString(args->GetString(2));
  if (([phase isEqualToString:@"ready"] && ![state->ai_login_phase isEqualToString:@"preparing"]) ||
      ([phase isEqualToString:@"complete"] && ![state->ai_login_phase isEqualToString:@"checking"])) return true;
  NSString *error = FromCefString(args->GetString(4));
  NSSet *errors = [NSSet setWithArray:@[@"ai_login_stale_page", @"ai_login_two_factor_required",
    @"ai_login_rejected", @"ai_login_ambiguous_form", @"ai_login_no_form", @"ai_login_nonempty_form", @"ai_login_form_changed"]];
  if (error.length) {
    state->ai_login_error = [errors containsObject:error] ? error : @"ai_login_failed";
    state->ai_login_phase = @"failed"; state->ai_login_awaiting_load = false;
  } else if ([phase isEqualToString:@"ready"] && args->GetString(3) == "w58-login") {
    state->ai_login_form = @"w58-login"; state->ai_login_phase = @"ready";
  } else if ([phase isEqualToString:@"complete"]) {
    state->ai_login_title = FromCefString(args->GetString(5));
    state->ai_login_phase = @"complete"; state->ai_login_awaiting_load = false;
  }
  return true;
}
#pragma mark - W58 End

BrowserState *CreateBrowserState(TatwoCEFBrowserView *view) {
  BrowserState *state = new BrowserState();
  view->_cefState = state;
  state->mount_generation =
      g_mount_generation_seed.fetch_add(1, std::memory_order_relaxed) + 1;
  state->client = new TatwoClient(view, state->mount_generation);
  state->close_handlers = [NSMutableArray array];
  state->webmcp_tools = [NSMutableDictionary dictionary];
  state->pending_webmcp_tools = [NSMutableDictionary dictionary];
  state->popup_views = [NSMutableArray array];
  state->phase = TatwoCEFBrowserPhaseCreating;
  if (g_live_browser_views == nil) {
    g_live_browser_views = [NSHashTable weakObjectsHashTable];
  }
  [g_live_browser_views addObject:view];
  return state;
}

bool TatwoClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
    const CefString &target_url, const CefString &target_frame_name,
    WindowOpenDisposition target_disposition, bool user_gesture,
    const CefPopupFeatures &popup_features, CefWindowInfo &window_info,
    CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
    CefRefPtr<CefDictionaryValue> &extra_info, bool *no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserView *opener = owner_;
  BrowserState *parent = State(opener);
  NSString *url = FromCefString(target_url);
  if (ActorRequestPolicy(opener).human) {
    BrowserRequestPolicySnapshot human_policy = ActorRequestPolicy(opener);
    if (parent && !parent->close_requested && !URLHasCredentials(url) &&
        IsActorURLAllowed(human_policy, url) && !IsDeniedByLocalHostList(human_policy, url) &&
        opener.onPopupRequested) opener.onPopupRequested(url);
    return true; // Swift owns new tabs; never spawn an unmanaged native window.
  }
  const bool blank = url.length == 0 || [url isEqualToString:@"about:blank"];
  BrowserRequestPolicySnapshot policy;
  policy.host_deny_list = g_host_deny_list;
  if (!parent || !parent->browser || !browser ||
      !parent->browser->IsSame(browser) || parent->close_requested ||
      !user_gesture || (!blank && (URLHasCredentials(url) ||
        !IsAllowedURLString(url) || IsDeniedByLocalHostList(policy, url)))) {
    LogBrowserLifecycle(@"popup_blocked");
    return true;
  }
  NSRect visible = (opener.window.screen ?: NSScreen.mainScreen).visibleFrame;
  const CGFloat width = std::min(visible.size.width,
      (CGFloat)std::clamp(popup_features.widthSet ? popup_features.width : 680, 320, 1200));
  const CGFloat height = std::min(visible.size.height - 40,
      (CGFloat)std::clamp(popup_features.heightSet ? popup_features.height : 680, 320, 1000));
  NSRect bounds = NSMakeRect(0, 0, width, height);
  TatwoCEFBrowserView *popup =
      [[TatwoCEFBrowserView alloc] initForPopupWithFrame:bounds opener:opener popupID:popup_id];
  if (popup == nil) return true;
  BrowserState *state = State(popup);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:bounds
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
      backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.delegate = popup;
  window.title = OriginForURLString(blank ? parent->committed_url : url) ?: @"新視窗";
  state->popup_window = window;
  [parent->popup_views addObject:popup];
  window.contentView = popup;
  popup.wantsLayer = YES;
  window_info.SetAsChild((__bridge CefWindowHandle)popup,
                        CefRect(0, 0, (int)width, (int)height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  client = state->client;
  settings.javascript_close_windows = STATE_ENABLED;
  settings.javascript_access_clipboard = STATE_DISABLED;
  settings.javascript_dom_paste = STATE_DISABLED;
  settings.background_color = kBrowserDocumentBackgroundColor;
  // Keep Chromium's opener relationship and inherited request context. Creating
  // an unrelated browser or forcing no_javascript_access would break OAuth.
  [window center];
  [window makeKeyAndOrderFront:nil];
  LogBrowserLifecycle(@"popup_accepted");
  return false;
}

void TatwoClient::OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) {
  CEF_REQUIRE_UI_THREAD();
  BrowserState *parent = State(owner_);
  if (!parent || !parent->browser || !browser ||
      !parent->browser->IsSame(browser)) return;
  for (TatwoCEFBrowserView *popup in [parent->popup_views copy]) {
    BrowserState *state = State(popup);
    if (state && state->popup_id == popup_id && !state->browser) {
      state->creation_pending = false;
      LogBrowserLifecycle(@"popup_aborted");
      if (state->close_requested) CompleteBrowserClose(popup, state);
      else [popup closeBrowser];
    }
  }
}

void PublishWebMCPToolsSnapshot(
    TatwoCEFBrowserView *view,
    BrowserState *state) {
  if (view == nil || state == nullptr) {
    return;
  }
  NSString *origin = OriginForURLString(state->committed_url);
  if (origin.length == 0) {
    AppendCEFEmbeddingTelemetryLine(
        @"phase=webmcp event=webmcp_origin_unresolved");
    return;
  }
  TatwoCEFWebMCPToolsHandler handler = view.webMCPToolsHandler;
  if (handler == nil) {
    return;
  }
  NSArray<NSString *> *names =
      [state->webmcp_tools.allKeys
          sortedArrayUsingSelector:@selector(compare:)];
  NSMutableArray<NSDictionary *> *tools =
      [NSMutableArray arrayWithCapacity:names.count];
  for (NSString *name in names) {
    NSDictionary *tool = state->webmcp_tools[name];
    if (tool != nil) {
      [tools addObject:tool];
    }
  }
  NSDictionary *snapshot = @{
    @"schema": @"TatwoCEFWebMCPToolsSnapshotV1",
    @"origin": origin,
    @"navigationGeneration": @(state->navigation_generation),
    @"tools": tools,
  };
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:snapshot
                                       options:NSJSONWritingSortedKeys
                                         error:nil];
  if (data == nil) {
    return;
  }
  NSString *json =
      [[NSString alloc] initWithData:data
                           encoding:NSUTF8StringEncoding];
  if (json != nil) {
    handler(json);
  }
}

void InvalidateWebMCPTools(
    TatwoCEFBrowserView *view,
    BrowserState *state) {
  if (state == nullptr) {
    return;
  }
  [state->webmcp_tools removeAllObjects];
  [state->pending_webmcp_tools removeAllObjects];
  PublishWebMCPToolsSnapshot(view, state);
}

void ActivatePendingWebMCPToolsForCommit(
    TatwoCEFBrowserView *view,
    BrowserState *state,
    NSString *committed_url) {
  if (state == nullptr) {
    return;
  }
  [state->webmcp_tools removeAllObjects];
  for (NSString *name in state->pending_webmcp_tools.allKeys) {
    NSDictionary *tool = state->pending_webmcp_tools[name];
    NSString *origin = tool[@"origin"];
    NSNumber *generation = tool[@"navigationGeneration"];
    if ([origin isEqualToString:OriginForURLString(committed_url)] &&
        [generation isEqualToNumber:@(state->navigation_generation)]) {
      state->webmcp_tools[name] = tool;
    }
  }
  [state->pending_webmcp_tools removeAllObjects];
  PublishWebMCPToolsSnapshot(view, state);
}

void BeginRendererNavigationIfNeeded(TatwoCEFBrowserView *view) {
  BrowserState *state = State(view);
  if (state != nullptr && !state->navigation_in_flight) {
    BeginNavigationFrameTelemetry(
        view, state, @"renderer_navigation");
  }
}

void FinishNavigationFrameTelemetry(TatwoCEFBrowserView *view) {
  BrowserState *state = State(view);
  if (state != nullptr) {
    state->navigation_in_flight = false;
  }
}

void InvalidateWebMCPForRendererTermination(
    TatwoCEFBrowserView *view) {
  BrowserState *state = State(view);
  if (state == nullptr) {
    return;
  }
  if (state->client) {
    state->client->CancelPendingWebMCPInvocations(
        @"webmcp_renderer_terminated");
  }
  InvalidateWebMCPTools(view, state);
}

// Fixed function in the host's isolated world, never in the page world.
// The caller supplies only structured data. Resolve the node into that same
// world so page-owned JS properties/prototypes are not our validation runtime.
static const char kTatwoSafeFocus[] = R"TATWOJS((()=>{
  let el=document.activeElement;
  while (el && el.shadowRoot) el=el.shadowRoot.activeElement;
  if (!el || !el.isConnected || el.matches('iframe,frame,object,embed')
      || !['input','textarea','select','button','a','body'].includes(el.localName)
      || (el.localName==='body' && el.matches(':focus'))) return false;
  const hints=[el.type,el.autocomplete,el.name,el.id,el.getAttribute('aria-label'),el.getAttribute('placeholder')].join(' ').toLowerCase();
  return !/password|one-time|otp|cc-|credit|card.number|security.code|token/.test(hints);
})())TATWOJS";

static const char kTatwoSelectNode[] = R"TATWOJS(function(value, unused, expectedURL) {
  const el=this;
  if (window.top!==window || location.href!==expectedURL || !(el instanceof HTMLSelectElement)
      || !el.isConnected || el.ownerDocument!==document || el.disabled || el.multiple) return false;
  const hints=[el.autocomplete,el.name,el.id,el.getAttribute('aria-label')].join(' ').toLowerCase();
  if (/password|one-time|otp|cc-|credit|card.number|security.code|token/.test(hints)) return false;
  const r=el.getBoundingClientRect(), hit=document.elementFromPoint(
    (Math.max(0,r.left)+Math.min(innerWidth,r.right))/2,
    (Math.max(0,r.top)+Math.min(innerHeight,r.bottom))/2);
  if (!hit || !(el===hit || el.contains(hit)) || r.width<=0 || r.height<=0) return false;
  const options=[...el.options].filter(o=>o.value===value);
  if (options.length!==1 || options[0].disabled || options[0].parentElement.disabled) return false;
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(el,value);
  el.dispatchEvent(new Event('input',{bubbles:true}));
  el.dispatchEvent(new Event('change',{bubbles:true}));
  return true;
})TATWOJS";

static const char kTatwoTypeIntoNode[] = R"TATWOJS(function(text, submit, expectedURL) {
  const el = this;
  const allowed = () => {
    if (window.top !== window || location.href !== expectedURL) return false;
    if (!el || !el.isConnected || el.ownerDocument !== document) return false;
    const tag = String(el.tagName || '').toUpperCase();
    const type = String(el.type || 'text').toLowerCase();
    if (tag !== 'TEXTAREA' && (tag !== 'INPUT' || !['text','search','email','url','tel','number'].includes(type))) return false;
    if (el.disabled || el.readOnly) return false;
    const probe = [type, el.autocomplete, el.name, el.id, el.placeholder,
      el.getAttribute('aria-label'), el.title].join(' ').toLowerCase();
    return !/password|one-time|otp|cc-|credit|card number|security code|token/.test(probe);
  };
  if (!allowed()) return false;
  const inputType = el.type, tag = el.tagName, form = el.form;
  // Named form controls can shadow form.action/method/target even in an
  // isolated world. Read native accessors, not named-property lookups.
  const formValue = name => form
    ? Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, name).get.call(form) : '';
  const formAction = formValue('action'), formMethod = formValue('method');
  const formTarget = formValue('target'), formEncoding = formValue('enctype');
  const unchanged = () => allowed() && el.type === inputType && el.tagName === tag
    && el.form === form && (!form || (
      Object.getOwnPropertyDescriptor(Node.prototype, 'isConnected').get.call(form)
      && Object.getOwnPropertyDescriptor(Node.prototype, 'ownerDocument').get.call(form) === document
      && formValue('action') === formAction && formValue('method') === formMethod
      && formValue('target') === formTarget && formValue('enctype') === formEncoding));
  if (submit && !form) return false;
  HTMLElement.prototype.focus.call(el, {preventScroll:true});
  if (!unchanged()) return false;
  const proto = String(el.tagName).toUpperCase() === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
  setter.call(el, text);
  EventTarget.prototype.dispatchEvent.call(el, new Event('input', {bubbles:true}));
  if (!unchanged()) return false;
  EventTarget.prototype.dispatchEvent.call(el, new Event('change', {bubbles:true}));
  if (!unchanged()) return false;
  if (submit) HTMLFormElement.prototype.requestSubmit.call(form);
  return true;
})TATWOJS";

// Read-only probe on the observed node, with the native hit node resolved into
// the same isolated world. This never synthesizes a click. The following native
// down/up remains separately gated; this is not a cross-process atomic promise.
static const char kTatwoCheckClickNode[] = R"TATWOJS(function(hit, point, rect, viewport, expectedURL) {
  const target = this;
  if (window.top !== window || location.href !== expectedURL
      || !(target instanceof Element) || !target.isConnected || target.ownerDocument !== document)
    return false;
  if (!(hit instanceof Element)) hit = hit && hit.parentElement;
  if (!(hit instanceof Element) || !hit.isConnected || hit.ownerDocument !== document) return false;
  // JS assignedSlot intentionally hides closed-root assignments. Pinned Blink
  // checkVisibility walks flat-tree ancestors, including those hidden slots.
  // Use its non-feature-gated opacity/visibility options; no permissive fallback.
  // It rejects opacity:0, not our cumulative 0.1 threshold or visual occlusion.
  const nativeVisibility = Element.prototype.checkVisibility;
  if (typeof nativeVisibility !== 'function') return false;
  const visibilityOptions = {checkOpacity:true, checkVisibilityCSS:true, contentVisibilityAuto:true};
  if (nativeVisibility.call(target,visibilityOptions) !== true
      || (hit !== target && nativeVisibility.call(hit,visibilityOptions) !== true)) return false;
  // CEF view points and CSS points are not interchangeable under arbitrary
  // page/pinch zoom. Refuse that unverified mapping, rather than guess.
  if (Math.abs(innerWidth-viewport[0]) >= 0.5 || Math.abs(innerHeight-viewport[1]) >= 0.5
      || (visualViewport && (visualViewport.scale !== 1
          || visualViewport.offsetLeft !== 0 || visualViewport.offsetTop !== 0))) return false;
  const current = Element.prototype.getBoundingClientRect.call(target);
  const actual = [current.x,current.y,current.width,current.height];
  if (!actual.every(Number.isFinite) || actual.some((value,i)=>Math.abs(value-rect[i]) > 1/64)
      || point[0] < Math.max(0,current.left) || point[0] >= Math.min(innerWidth,current.right)
      || point[1] < Math.max(0,current.top) || point[1] >= Math.min(innerHeight,current.bottom)) return false;
  if (target.matches(':disabled,[aria-disabled="true"]') || target.disabled) return false;
  const hints=[target.type,target.autocomplete,target.name,target.id,
    target.getAttribute('aria-label'),target.getAttribute('placeholder')].join(' ').toLowerCase();
  if (/password|one-time|otp|cc-|credit|card.number|security.code|token/.test(hints)) return false;
  const parent = node => node.assignedSlot || node.parentElement
    || (node.getRootNode() instanceof ShadowRoot ? node.getRootNode().host : null);
  // A nested span is a legitimate hit for its button, but a distinct nested
  // actionable control is not permission to click the observed outer control.
  let node=hit, reached=false, opacity=1;
  for (let depth=0; node && depth<64; ++depth,node=parent(node)) {
    const style=getComputedStyle(node);
    opacity*=Number(style.opacity);
    if (node.hidden || style.display === 'none' || style.visibility !== 'visible'
        || style.contentVisibility === 'hidden' || !Number.isFinite(opacity) || opacity < 0.1) return false;
    if (node === target) { reached=true; break; }
    if (node.matches('a[href],button,input,textarea,select,summary,label,[role="button"],[role="link"],[onclick]')
        || node.isContentEditable) return false;
  }
  if (!reached) return false;
  // Continue above the target without counting its opacity twice.
  node=parent(target);
  for (let depth=0; node && depth<64; ++depth,node=parent(node)) {
    const style=getComputedStyle(node);
    opacity*=Number(style.opacity);
    if (node.hidden || style.display === 'none' || style.visibility !== 'visible'
        || style.contentVisibility === 'hidden' || !Number.isFinite(opacity) || opacity < 0.1) return false;
  }
  if (node) return false;
  // Verify each retargeting boundary. Starting with a CDP-resolved hit gives
  // access to its actual root, including a closed/UA shadow root; do not just
  // accept a host because document.elementFromPoint returned that host.
  node=hit;
  for (let depth=0; node && depth<64; ++depth) {
    const root=node.getRootNode();
    if (root !== document && !(root instanceof ShadowRoot)) return false;
    const probe=root === document ? Document.prototype.elementFromPoint : ShadowRoot.prototype.elementFromPoint;
    if (typeof probe !== 'function' || probe.call(root,point[0],point[1]) !== node) return false;
    if (root === document) return true;
    node=root.host;
  }
  return false;
})TATWOJS";

bool BrowserInputIsCurrent(TatwoCEFBrowserView *view, uint64_t generation) {
  BrowserState *state = State(view);
  return NSThread.isMainThread && g_initialized.load() && !g_shutdown.load() &&
      !g_shutdown_requested.load() && view.window != nil && view.window.isVisible &&
      !view.window.isMiniaturized && view.bounds.size.width > 0 && view.bounds.size.height > 0 &&
      !view.isHiddenOrHasHiddenAncestor && state != nullptr && state->browser &&
      !state->close_requested && !state->navigation_in_flight &&
      generation > 0 && state->navigation_generation == generation &&
      (state->phase == TatwoCEFBrowserPhaseCommitted ||
       state->phase == TatwoCEFBrowserPhaseFinished);
}

// Only non-agent host navigation may omit the gate. The public agent overload
// rejects nil before reaching this helper. Do not hold an outer session lock.
BOOL DispatchBrowserNavigation(TatwoCEFBrowserView *view,
                               TatwoCEFBrowserInputDispatchGate gate,
                               dispatch_block_t enqueue) {
  if (!NSThread.isMainThread) return NO;
  if (gate == nil) { enqueue(); return YES; }
  BrowserState *original_state = State(view);
  if (!original_state) return NO;
  const uint64_t mount_generation = original_state->mount_generation;
  CefRefPtr<CefBrowser> original_browser = original_state->browser;
  __weak TatwoCEFBrowserView *weak_view = view;
  BOOL (^is_current)(void) = ^BOOL {
    TatwoCEFBrowserView *owner = weak_view;
    BrowserState *state = State(owner);
    if (!state || state != original_state ||
        state->mount_generation != mount_generation ||
        state->close_requested || state->request_context_security_blocked ||
        !state->request_context_security_ready || g_shutdown_requested.load() ||
        !g_initialized.load() || g_shutdown.load() ||
        owner.window == nil || !owner.window.isVisible ||
        owner.window.isMiniaturized || owner.isHiddenOrHasHiddenAncestor ||
        owner.bounds.size.width < 1 || owner.bounds.size.height < 1) return NO;
    if (original_browser
            ? (!state->browser || !state->browser->IsSame(original_browser))
            : !!state->browser) return NO;
    return YES;
  };
  // A hidden/unready view is not even an attempted native send. Check again
  // inside the originating gate, immediately before the actual enqueue.
  if (!is_current()) return NO;
  __block BOOL accepting = YES;
  __block BOOL invoked = NO;
  __block BOOL dispatched = NO;
  const BOOL authorized = gate(^{
    if (!NSThread.isMainThread || !accepting || invoked) return;
    invoked = YES;
    if (!is_current()) return;
    dispatched = YES;
    enqueue();
  });
  // A retained block must not access native state or enqueue after return.
  accepting = NO;
  return authorized && dispatched;
}

int TatwoClient::DispatchTypeCommand(
    CefRefPtr<CefBrowser> browser, const char *method,
    CefRefPtr<CefDictionaryValue> params) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserInputDispatchGate gate = type_dispatch_gate_;
  if (gate == nil || !browser) return 0;
  __weak TatwoCEFBrowserView *weak_owner = owner_;
  const uint64_t generation = type_navigation_generation_;
  const uint64_t serial = type_request_serial_;
  const TypeStage stage = type_stage_;
  const NodeInputKind kind = type_kind_;
  TatwoClient *original_client = this;
  NSString *expected_url = type_committed_url_;
  __block BOOL accepting = YES;
  __block BOOL invoked = NO;
  __block int message_id = 0;
  // The outer host gate takes its input-owner lock around only this enqueue.
  // Never retain that lock across a DevTools response or call it recursively.
  const BOOL authorized = gate(^{
    if (!NSThread.isMainThread || !accepting || invoked) return;
    invoked = YES;
    TatwoCEFBrowserView *owner = weak_owner;
    BrowserState *state = State(owner);
    if (!BrowserInputIsCurrent(owner, generation) || !state ||
        !state->browser || !state->browser->IsSame(browser) ||
        !state->client || state->client.get() != original_client ||
        state->client->type_completion_ == nil ||
        state->client->type_request_serial_ != serial ||
        state->client->type_stage_ != stage ||
        state->client->type_kind_ != kind ||
        ![state->committed_url isEqualToString:expected_url]) return;
    message_id = browser->GetHost()->ExecuteDevToolsMethod(0, method, params);
  });
  // A gate may not stash this block and send input after this call returns.
  accepting = NO;
  return authorized ? message_id : 0;
}

void TatwoClient::TypeText(CefRefPtr<CefBrowser> browser, int backend_node_id,
                           NSString *text, uint64_t generation, bool submit,
                           TatwoCEFBrowserInputDispatchGate dispatch_gate,
                           TatwoCEFBrowserInputHandler completion) {
  BeginNodeInput(browser, backend_node_id, NodeInputKind::text, text, submit,
                 NSZeroPoint, NSZeroRect, NSZeroSize, generation,
                 dispatch_gate, completion);
}

void TatwoClient::ClickElement(CefRefPtr<CefBrowser> browser, int backend_node_id,
                                NSPoint point, NSRect expected_rect, NSSize viewport,
                                uint64_t generation,
                                TatwoCEFBrowserInputDispatchGate dispatch_gate,
                                TatwoCEFBrowserInputHandler completion) {
  BeginNodeInput(browser, backend_node_id, NodeInputKind::click, nil, false,
                 point, expected_rect, viewport, generation,
                 dispatch_gate, completion);
}

void TatwoClient::BeginNodeInput(CefRefPtr<CefBrowser> browser, int backend_node_id,
                                 NodeInputKind kind, NSString *text, bool submit,
                                 NSPoint point, NSRect expected_rect, NSSize viewport,
                                 uint64_t generation,
                                 TatwoCEFBrowserInputDispatchGate dispatch_gate,
                                 TatwoCEFBrowserInputHandler completion) {
  CEF_REQUIRE_UI_THREAD();
  BrowserState *state = State(owner_);
  if (!BrowserInputIsCurrent(owner_, generation) || !browser ||
      !state || !state->browser || !state->browser->IsSame(browser) ||
      state->committed_url.length == 0 ||
      backend_node_id <= 0 || type_completion_ != nil ||
      snapshot_completion_ != nil || dispatch_gate == nil) {
    completion(NO, @"browser_field_target_unavailable");
    return;
  }
  if (kind == NodeInputKind::click &&
      (!std::isfinite(point.x) || !std::isfinite(point.y) ||
       point.x < 0 || point.y < 0 ||
       point.x != std::floor(point.x) || point.y != std::floor(point.y) ||
       point.x > std::numeric_limits<int>::max() ||
       point.y > std::numeric_limits<int>::max() ||
       !std::isfinite(expected_rect.origin.x) || !std::isfinite(expected_rect.origin.y) ||
       !std::isfinite(expected_rect.size.width) || !std::isfinite(expected_rect.size.height) ||
       expected_rect.size.width <= 0 || expected_rect.size.height <= 0 ||
       !std::isfinite(NSMaxX(expected_rect)) || !std::isfinite(NSMaxY(expected_rect)) ||
       !std::isfinite(viewport.width) || !std::isfinite(viewport.height) ||
       viewport.width <= 0 || viewport.height <= 0 ||
       !NSEqualSizes(viewport, owner_.bounds.size) ||
       point.x >= viewport.width || point.y >= viewport.height ||
       point.x < NSMinX(expected_rect) || point.x >= NSMaxX(expected_rect) ||
       point.y < NSMinY(expected_rect) || point.y >= NSMaxY(expected_rect) ||
       browser->GetHost()->GetZoomLevel() != 0)) {
    completion(NO, @"browser_native_click_point_unavailable");
    return;
  }
  type_devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
  if (!type_devtools_registration_) {
    completion(NO, @"browser_unavailable");
    return;
  }
  type_completion_ = [completion copy];
  type_dispatch_gate_ = [dispatch_gate copy];
  type_browser_ = browser;
  type_text_ = [text copy];
  type_committed_url_ = [state->committed_url copy];
  type_object_group_ = [@"tatwo-browser-input:" stringByAppendingString:NSUUID.UUID.UUIDString];
  type_navigation_generation_ = generation;
  type_submit_ = submit;
  type_backend_node_id_ = backend_node_id;
  type_kind_ = kind;
  type_click_point_ = point;
  type_click_rect_ = expected_rect;
  type_click_viewport_ = viewport;
  type_stage_ = TypeStage::readingFrame;
  const uint64_t serial = ++type_request_serial_;
  auto params = CefDictionaryValue::Create();
  // CDP frame IDs are not CefFrame identifiers. Ask the exact browser for its
  // current root frame, then create an isolated world with no universal access.
  type_message_id_ = DispatchTypeCommand(browser, "Page.getFrameTree", params);
  if (!type_message_id_) {
    FinishTypeText(NO, @"browser_field_target_unavailable");
    return;
  }
  __weak TatwoCEFBrowserView *weak_owner = owner_;
  const uint64_t mount = mount_generation_;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    TatwoCEFBrowserView *owner = weak_owner;
    if (!IsActiveMountCallback(owner, mount, @"type_timeout")) return;
    BrowserState *state = State(owner);
    if (state && state->client && state->client->type_request_serial_ == serial &&
        state->client->type_completion_ != nil) {
      state->client->FinishTypeText(NO, @"browser_action_result_unavailable");
    }
  });
  ScheduleImmediateCEFMessagePumpWork(@"browser_type");
}

BOOL TatwoClient::DispatchCheckedClick(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserInputDispatchGate gate = type_dispatch_gate_;
  if (gate == nil || !browser || type_kind_ != NodeInputKind::click ||
      type_stage_ != TypeStage::dispatchingClick) return NO;
  const uint64_t serial = type_request_serial_;
  const uint64_t generation = type_navigation_generation_;
  const NSPoint point = type_click_point_;
  const NSSize viewport = type_click_viewport_;
  NSString *expected_url = type_committed_url_;
  TatwoClient *original_client = this;
  __weak TatwoCEFBrowserView *weak_owner = owner_;
  __block BOOL accepting = YES, invoked = NO, sent = NO;
  const BOOL authorized = gate(^{
    if (!NSThread.isMainThread || !accepting || invoked) return;
    invoked = YES;
    TatwoCEFBrowserView *owner = weak_owner;
    BrowserState *state = State(owner);
    if (!BrowserInputIsCurrent(owner, generation) || !state ||
        !state->client || state->client.get() != original_client ||
        state->client->type_completion_ == nil ||
        state->client->type_request_serial_ != serial ||
        state->client->type_kind_ != NodeInputKind::click ||
        state->client->type_stage_ != TypeStage::dispatchingClick ||
        !state->browser || !state->browser->IsSame(browser) ||
        ![state->committed_url isEqualToString:expected_url] ||
        !NSEqualSizes(owner.bounds.size, viewport) ||
        browser->GetHost()->GetZoomLevel() != 0) return;
    sent = [owner sendClickAtPoint:point navigationGeneration:generation];
  });
  accepting = NO;
  return authorized && sent;
}

void TatwoClient::OnTypeTextResult(CefRefPtr<CefBrowser> browser, bool success,
                                   const void *result, size_t result_size) {
  BrowserState *state = State(owner_);
  if (!BrowserInputIsCurrent(owner_, type_navigation_generation_) || !state ||
      (!state->browser || !browser || !state->browser->IsSame(browser)) ||
      !type_browser_ || !type_browser_->IsSame(browser) ||
      ![state->committed_url isEqualToString:type_committed_url_] ||
      !success || !result || !result_size || result_size > 1024 * 1024) {
    FinishTypeText(NO, @"browser_action_result_unavailable");
    return;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithBytes:result length:result_size] options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) {
    FinishTypeText(NO, @"browser_action_result_unavailable");
    return;
  }
  if (type_stage_ == TypeStage::readingFrame) {
    NSDictionary *tree = [parsed[@"frameTree"] isKindOfClass:NSDictionary.class] ? parsed[@"frameTree"] : nil;
    NSDictionary *frame = [tree[@"frame"] isKindOfClass:NSDictionary.class] ? tree[@"frame"] : nil;
    NSString *frame_id = frame[@"id"];
    if (![frame_id isKindOfClass:NSString.class] || frame_id.length == 0 ||
        frame_id.length > 1024 || frame[@"parentId"] != nil) {
      FinishTypeText(NO, @"browser_field_target_unavailable");
      return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetString("frameId", ToCefString(frame_id));
    params->SetString("worldName", "TATWOComputerUseInputV1");
    // The spelling is the pinned CDP protocol's, not a typo to normalize.
    params->SetBool("grantUniveralAccess", false);
    type_frame_id_ = [frame_id copy];
    type_stage_ = TypeStage::creatingWorld;
    type_message_id_ = DispatchTypeCommand(browser, "Page.createIsolatedWorld", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_type_world");
    return;
  }
  if (type_stage_ == TypeStage::creatingWorld) {
    id context = parsed[@"executionContextId"];
    if (![context isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)context) == CFBooleanGetTypeID()) {
      FinishTypeText(NO, @"browser_field_target_unavailable");
      return;
    }
    const double context_id = [context doubleValue];
    if (!std::isfinite(context_id) || context_id <= 0 ||
        context_id > std::numeric_limits<int>::max() || std::floor(context_id) != context_id) {
      FinishTypeText(NO, @"browser_field_target_unavailable");
      return;
    }
    auto params = CefDictionaryValue::Create();
    type_context_id_ = static_cast<int>(context_id);
    if (type_kind_ == NodeInputKind::focus) {
      params->SetString("expression", kTatwoSafeFocus);
      params->SetInt("contextId", type_context_id_);
      params->SetBool("returnByValue", true);
      params->SetBool("silent", true);
      type_stage_ = TypeStage::applyingText;
      type_message_id_ = DispatchTypeCommand(browser, "Runtime.evaluate", params);
      if (!type_message_id_) FinishTypeText(NO, @"browser_focus_unavailable");
      else ScheduleImmediateCEFMessagePumpWork(@"browser_focus_check");
      return;
    }
    params->SetInt("backendNodeId", type_backend_node_id_);
    params->SetInt("executionContextId", static_cast<int>(context_id));
    params->SetString("objectGroup", ToCefString(type_object_group_));
    type_stage_ = TypeStage::resolvingNode;
    type_message_id_ = DispatchTypeCommand(browser, "DOM.resolveNode", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_type_resolve");
    return;
  }
  if (type_stage_ == TypeStage::resolvingNode) {
    NSDictionary *object = [parsed[@"object"] isKindOfClass:NSDictionary.class] ? parsed[@"object"] : nil;
    NSString *object_id = object[@"objectId"];
    if (![object_id isKindOfClass:NSString.class] || object_id.length == 0 ||
        ![object[@"type"] isEqual:@"object"] || ![object[@"subtype"] isEqual:@"node"]) {
      FinishTypeText(NO, @"browser_field_target_unavailable");
      return;
    }
    if (type_kind_ == NodeInputKind::click) {
      type_target_object_id_ = [object_id copy];
      auto params = CefDictionaryValue::Create();
      type_stage_ = TypeStage::readingClickMetrics;
      type_message_id_ = DispatchTypeCommand(browser, "Page.getLayoutMetrics", params);
      if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
      else ScheduleImmediateCEFMessagePumpWork(@"browser_click_metrics");
      return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetString("objectId", ToCefString(object_id));
    params->SetString("functionDeclaration", type_kind_ == NodeInputKind::select ? kTatwoSelectNode : kTatwoTypeIntoNode);
    params->SetBool("returnByValue", true);
    params->SetBool("silent", true);
    params->SetBool("userGesture", true);
    auto arguments = CefListValue::Create();
    auto text = CefDictionaryValue::Create();
    text->SetString("value", ToCefString(type_text_));
    arguments->SetDictionary(0, text);
    auto submit = CefDictionaryValue::Create();
    submit->SetBool("value", type_submit_);
    arguments->SetDictionary(1, submit);
    auto url = CefDictionaryValue::Create();
    url->SetString("value", ToCefString(type_committed_url_));
    arguments->SetDictionary(2, url);
    params->SetList("arguments", arguments);
    type_stage_ = TypeStage::applyingText;
    type_message_id_ = DispatchTypeCommand(browser, "Runtime.callFunctionOn", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_type_node");
    return;
  }
  if (type_stage_ == TypeStage::readingClickMetrics && type_kind_ == NodeInputKind::click) {
    NSDictionary *viewport = [parsed[@"cssVisualViewport"] isKindOfClass:NSDictionary.class]
        ? parsed[@"cssVisualViewport"] : nil;
    NSArray<NSString *> *keys = @[@"pageX", @"pageY", @"offsetX", @"offsetY", @"scale"];
    double metrics[5];
    for (NSUInteger index = 0; index < keys.count; ++index) {
      id value = viewport[keys[index]];
      if (![value isKindOfClass:NSNumber.class] ||
          CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
          !std::isfinite([value doubleValue])) {
        FinishTypeText(NO, @"browser_native_click_point_unavailable"); return;
      }
      metrics[index] = [value doubleValue];
    }
    if (metrics[2] != 0 || metrics[3] != 0 || metrics[4] != 1) {
      FinishTypeText(NO, @"browser_native_click_point_unavailable"); return;
    }
    // Pinned Blink getNodeForLocation converts document CSS coordinates to the
    // frame by subtracting the scroll offset. Never pass viewport points as-is.
    // CDP accepts only integers here; rounded lookup is a candidate hit, not
    // proof. The isolated probe below re-hits the exact native viewport point.
    const double document_x = std::round(type_click_point_.x + metrics[0]);
    const double document_y = std::round(type_click_point_.y + metrics[1]);
    if (!std::isfinite(document_x) || !std::isfinite(document_y) ||
        document_x < std::numeric_limits<int>::min() ||
        document_y < std::numeric_limits<int>::min() ||
        document_x > std::numeric_limits<int>::max() ||
        document_y > std::numeric_limits<int>::max()) {
      FinishTypeText(NO, @"browser_native_click_point_unavailable"); return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetInt("x", static_cast<int>(document_x));
    params->SetInt("y", static_cast<int>(document_y));
    params->SetBool("includeUserAgentShadowDOM", true);
    params->SetBool("ignorePointerEventsNone", false);
    type_stage_ = TypeStage::locatingHit;
    type_message_id_ = DispatchTypeCommand(browser, "DOM.getNodeForLocation", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_click_hit");
    return;
  }
  if (type_stage_ == TypeStage::locatingHit && type_kind_ == NodeInputKind::click) {
    id hit_id = parsed[@"backendNodeId"];
    if (![hit_id isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)hit_id) == CFBooleanGetTypeID() ||
        !std::isfinite([hit_id doubleValue]) || [hit_id doubleValue] <= 0 ||
        [hit_id doubleValue] > std::numeric_limits<int>::max() ||
        std::floor([hit_id doubleValue]) != [hit_id doubleValue] ||
        ![parsed[@"frameId"] isEqual:type_frame_id_]) {
      FinishTypeText(NO, @"browser_click_target_unavailable"); return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetInt("backendNodeId", [hit_id intValue]);
    params->SetInt("executionContextId", type_context_id_);
    params->SetString("objectGroup", ToCefString(type_object_group_));
    type_stage_ = TypeStage::resolvingHit;
    type_message_id_ = DispatchTypeCommand(browser, "DOM.resolveNode", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_click_resolve_hit");
    return;
  }
  if (type_stage_ == TypeStage::resolvingHit && type_kind_ == NodeInputKind::click) {
    NSDictionary *object = [parsed[@"object"] isKindOfClass:NSDictionary.class] ? parsed[@"object"] : nil;
    NSString *object_id = object[@"objectId"];
    if (![object_id isKindOfClass:NSString.class] || object_id.length == 0 ||
        ![object[@"type"] isEqual:@"object"] || ![object[@"subtype"] isEqual:@"node"] ||
        type_target_object_id_.length == 0) {
      FinishTypeText(NO, @"browser_click_target_unavailable"); return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetString("objectId", ToCefString(type_target_object_id_));
    params->SetString("functionDeclaration", kTatwoCheckClickNode);
    params->SetBool("returnByValue", true);
    params->SetBool("silent", true);
    auto arguments = CefListValue::Create();
    auto hit = CefDictionaryValue::Create();
    hit->SetString("objectId", ToCefString(object_id));
    arguments->SetDictionary(0, hit);
    const double values[][4] = {
      {type_click_point_.x, type_click_point_.y, 0, 0},
      {type_click_rect_.origin.x, type_click_rect_.origin.y, type_click_rect_.size.width, type_click_rect_.size.height},
      {type_click_viewport_.width, type_click_viewport_.height, 0, 0},
    };
    for (size_t index = 0; index < 3; ++index) {
      auto list = CefListValue::Create();
      for (size_t item = 0; item < (index == 1 ? 4u : 2u); ++item)
        list->SetDouble(item, values[index][item]);
      auto argument = CefDictionaryValue::Create();
      argument->SetList("value", list);
      arguments->SetDictionary(index + 1, argument);
    }
    auto url = CefDictionaryValue::Create();
    url->SetString("value", ToCefString(type_committed_url_));
    arguments->SetDictionary(4, url);
    params->SetList("arguments", arguments);
    type_stage_ = TypeStage::checkingClick;
    type_message_id_ = DispatchTypeCommand(browser, "Runtime.callFunctionOn", params);
    if (!type_message_id_) FinishTypeText(NO, @"browser_action_result_unavailable");
    else ScheduleImmediateCEFMessagePumpWork(@"browser_click_check");
    return;
  }
  if (type_stage_ == TypeStage::checkingClick && type_kind_ == NodeInputKind::click) {
    NSDictionary *value = [parsed[@"result"] isKindOfClass:NSDictionary.class] ? parsed[@"result"] : nil;
    if (parsed[@"exceptionDetails"] != nil || ![value[@"type"] isEqual:@"boolean"] ||
        ![value[@"value"] isEqual:@YES]) {
      FinishTypeText(NO, @"browser_click_target_unavailable"); return;
    }
    type_stage_ = TypeStage::dispatchingClick;
    const BOOL sent = DispatchCheckedClick(browser);
    FinishTypeText(sent, sent ? nil : @"browser_action_result_unavailable");
    return;
  }
  if (type_stage_ != TypeStage::applyingText || type_kind_ == NodeInputKind::click) {
    FinishTypeText(NO, @"browser_action_result_unavailable");
    return;
  }
  NSDictionary *value = [parsed[@"result"] isKindOfClass:NSDictionary.class] ? parsed[@"result"] : nil;
  const BOOL completed = parsed[@"exceptionDetails"] == nil &&
      [value[@"type"] isEqual:@"boolean"] && [value[@"value"] isEqual:@YES];
  FinishTypeText(completed, completed ? nil : @"browser_field_target_unavailable");
}

void TatwoClient::FinishTypeText(BOOL completed, NSString *error_code) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserInputHandler completion = type_completion_;
  CefRefPtr<CefBrowser> original_browser = type_browser_;
  NSString *object_group = type_object_group_;
  type_completion_ = nil;
  type_dispatch_gate_ = nil;
  type_browser_ = nullptr;
  type_text_ = nil;
  type_committed_url_ = nil;
  type_object_group_ = nil;
  type_frame_id_ = nil;
  type_target_object_id_ = nil;
  type_navigation_generation_ = 0;
  type_message_id_ = 0;
  type_backend_node_id_ = 0;
  type_context_id_ = 0;
  type_kind_ = NodeInputKind::text;
  type_stage_ = TypeStage::idle;
  type_click_point_ = NSZeroPoint;
  type_click_rect_ = NSZeroRect;
  type_click_viewport_ = NSZeroSize;
  type_submit_ = false;
  type_devtools_registration_ = nullptr;
  BrowserState *state = State(owner_);
  if (state && state->browser && original_browser && object_group.length > 0 &&
      state->browser->IsSame(original_browser) &&
      !state->close_requested && !g_shutdown_requested.load()) {
    auto params = CefDictionaryValue::Create();
    params->SetString("objectGroup", ToCefString(object_group));
    original_browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.releaseObjectGroup", params);
  }
  if (completion) completion(completed, error_code);
}

void TatwoClient::CaptureVisibleSnapshot(
    CefRefPtr<CefBrowser> browser,
    NSString *committed_url,
    uint64_t navigation_generation,
    NSSize viewport_size,
    TatwoCEFBrowserSnapshotHandler completion) {
  CEF_REQUIRE_UI_THREAD();
  if (snapshot_completion_ != nil || type_completion_ != nil || browser == nullptr ||
      committed_url.length == 0 || navigation_generation == 0 ||
      viewport_size.width < 1 || viewport_size.height < 1) {
    completion(nil, @"snapshot_unavailable");
    return;
  }
  snapshot_devtools_registration_ =
      browser->GetHost()->AddDevToolsMessageObserver(this);
  if (!snapshot_devtools_registration_) {
    completion(nil, @"snapshot_unavailable");
    return;
  }

  CefRefPtr<CefListValue> computed_styles = CefListValue::Create();
  const char *style_names[] = {
      "display", "visibility", "content-visibility", "opacity",
      "font-size", "color", "background-color", "clip", "clip-path",
      "overflow", "transform",
  };
  for (size_t index = 0; index < std::size(style_names); ++index) {
    computed_styles->SetString(index, style_names[index]);
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetList("computedStyles", computed_styles);
  params->SetBool("includePaintOrder", true);
  params->SetBool("includeDOMRects", true);
  params->SetBool("includeBlendedBackgroundColors", true);
  params->SetBool("includeTextColorOpacities", true);

  snapshot_completion_ = [completion copy];
  snapshot_committed_url_ = [committed_url copy];
  snapshot_navigation_generation_ = navigation_generation;
  snapshot_viewport_size_ = viewport_size;
  snapshot_message_id_ = browser->GetHost()->ExecuteDevToolsMethod(
      0, "DOMSnapshot.captureSnapshot", params);
  if (snapshot_message_id_ == 0) {
    FinishVisibleSnapshot(nil, @"snapshot_unavailable");
    return;
  }
  const int pending_message_id = snapshot_message_id_;
  __weak TatwoCEFBrowserView *weak_owner = owner_;
  const uint64_t expected_mount_generation = mount_generation_;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        TatwoCEFBrowserView *owner = weak_owner;
        if (!IsActiveMountCallback(
                owner,
                expected_mount_generation,
                @"snapshot_timeout")) {
          return;
        }
        BrowserState *state = State(owner);
        if (state != nullptr && state->client) {
          state->client->SnapshotTimedOut(pending_message_id);
        }
      });
  // A snapshot is host work even when page loading has already gone idle.
  // Match input dispatch: wake CEF to deliver the CDP command/result rather
  // than waiting for an unrelated navigation to restart the message pump.
  ScheduleImmediateCEFMessagePumpWork(@"browser_snapshot");
}

void TatwoClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                         int message_id,
                                         bool success,
                                         const void *result,
                                         size_t result_size) {
  CEF_REQUIRE_UI_THREAD();
  if (type_completion_ != nil && message_id == type_message_id_) {
    OnTypeTextResult(browser, success, result, result_size);
    return;
  }
  if (message_id != snapshot_message_id_ || snapshot_completion_ == nil) {
    return;
  }
  TatwoCEFBrowserView *owner = owner_;
  BrowserState *state = State(owner);
  if (!success || result == nullptr || result_size == 0) {
    FinishVisibleSnapshot(nil, @"snapshot_unavailable");
    return;
  }
  if (state == nullptr || (!state->browser || !browser || !state->browser->IsSame(browser)) ||
      state->navigation_generation != snapshot_navigation_generation_ ||
      ![state->committed_url isEqualToString:snapshot_committed_url_]) {
    FinishVisibleSnapshot(nil, @"navigation_binding_unavailable");
    return;
  }
  NSData *data = [NSData dataWithBytes:result length:result_size];
  NSError *parse_error = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:data
                                               options:0
                                                 error:&parse_error];
  if (![parsed isKindOfClass:NSDictionary.class] || parse_error != nil) {
    FinishVisibleSnapshot(nil, @"snapshot_parse_failed");
    return;
  }
  NSString *error_code = nil;
  NSString *json = BuildVisibleSnapshotJSON(
      parsed,
      snapshot_committed_url_,
      snapshot_navigation_generation_,
      snapshot_viewport_size_,
      &error_code);
  FinishVisibleSnapshot(json, error_code);
}

void TatwoClient::SnapshotTimedOut(int message_id) {
  CEF_REQUIRE_UI_THREAD();
  if (snapshot_completion_ != nil && snapshot_message_id_ == message_id) {
    FinishVisibleSnapshot(nil, @"snapshot_timeout");
  }
}

void TatwoClient::FinishVisibleSnapshot(NSString *json,
                                        NSString *error_code) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserSnapshotHandler completion = snapshot_completion_;
  snapshot_completion_ = nil;
  snapshot_devtools_registration_ = nullptr;
  snapshot_committed_url_ = nil;
  snapshot_navigation_generation_ = 0;
  snapshot_viewport_size_ = NSZeroSize;
  snapshot_message_id_ = 0;
  if (completion != nil) {
    completion(json, error_code);
  }
}

void TatwoClient::CancelPendingBrowserOperations() {
  CEF_REQUIRE_UI_THREAD();
  if (type_completion_ != nil) {
    FinishTypeText(NO, @"browser_action_result_unavailable");
  }
  if (snapshot_completion_ != nil || snapshot_devtools_registration_) {
    FinishVisibleSnapshot(nil, @"snapshot_unavailable");
  }
}

bool TatwoClient::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  if (source_process != PID_RENDERER || !browser || !frame ||
      !frame->IsMain() || !message ||
      !IsActiveMountCallback(
          owner_, mount_generation_, @"webmcp_process_message")) {
    return false;
  }
  TatwoCEFBrowserView *owner = owner_;
  BrowserState *state = State(owner);
  if (state == nullptr || !state->browser ||
      !state->browser->IsSame(browser) || state->close_requested) {
    return false;
  }
  const CefString message_name = message->GetName();
#pragma mark - W57c Consume credentials before generic WebMCP handling
  if (W57cBrowserMessage(owner, frame, message)) return true;
#pragma mark - W57c End
#pragma mark - W58
  if (W58BrowserMessage(owner, frame, message)) return true;
#pragma mark - W58 End
  CefRefPtr<CefListValue> arguments = message->GetArgumentList();
  if (message_name == kWebMCPCapabilityMessage) {
    if (arguments && arguments->GetBool(0)) {
      g_webmcp_renderer_hook_active.store(
          true, std::memory_order_release);
    }
    return true;
  }
  if (message_name == kWebMCPRegisterMessage) {
    if (!arguments || arguments->GetSize() < 5) {
      return true;
    }
    NSString *tool_name = FromCefString(arguments->GetString(0));
    NSString *description = FromCefString(arguments->GetString(1));
    NSString *schema_json = FromCefString(arguments->GetString(2));
    NSString *source_url = FromCefString(arguments->GetString(3));
    NSString *context_id = FromCefString(arguments->GetString(4));
    NSString *source_origin = OriginForURLString(source_url);
    NSString *committed_origin =
        OriginForURLString(state->committed_url);
    if (tool_name.length == 0 || schema_json.length == 0 ||
        source_origin.length == 0 || context_id.length == 0 ||
        state->navigation_generation == 0) {
      return true;
    }
    NSDictionary *tool = @{
      @"name": tool_name,
      @"description": description ?: @"",
      @"inputSchemaJSON": schema_json,
      @"origin": source_origin,
      @"navigationGeneration": @(state->navigation_generation),
      @"contextID": context_id,
    };
    if ([source_origin isEqualToString:committed_origin]) {
      state->webmcp_tools[tool_name] = tool;
      [state->pending_webmcp_tools removeObjectForKey:tool_name];
    } else if (state->navigation_in_flight) {
      state->pending_webmcp_tools[tool_name] = tool;
    } else {
      return true;
    }
    PublishWebMCPToolsSnapshot(owner, state);
    return true;
  }
  if (message_name == kWebMCPUnregisterMessage) {
    if (!arguments || arguments->GetSize() < 1) {
      return true;
    }
    NSString *tool_name = FromCefString(arguments->GetString(0));
    NSString *context_id = arguments->GetSize() > 2
        ? FromCefString(arguments->GetString(2))
        : @"";
    NSDictionary *active_tool = state->webmcp_tools[tool_name];
    NSDictionary *pending_tool =
        state->pending_webmcp_tools[tool_name];
    if (context_id.length == 0 ||
        [active_tool[@"contextID"] isEqualToString:context_id]) {
      [state->webmcp_tools removeObjectForKey:tool_name];
    }
    if (context_id.length == 0 ||
        [pending_tool[@"contextID"] isEqualToString:context_id]) {
      [state->pending_webmcp_tools removeObjectForKey:tool_name];
    }
    PublishWebMCPToolsSnapshot(owner, state);
    return true;
  }
  if (message_name == kWebMCPInvalidateMessage) {
    NSString *context_id =
        arguments && arguments->GetSize() > 0
        ? FromCefString(arguments->GetString(0))
        : @"";
    if (context_id.length == 0) {
      CancelPendingWebMCPInvocations(
          @"webmcp_navigation_changed");
      InvalidateWebMCPTools(owner, state);
    } else {
      CancelPendingWebMCPInvocations(
          @"webmcp_context_released");
      NSArray<NSString *> *active_names =
          [state->webmcp_tools.allKeys copy];
      for (NSString *name in active_names) {
        NSDictionary *active_tool = state->webmcp_tools[name];
        if ([active_tool[@"contextID"] isEqualToString:context_id]) {
          [state->webmcp_tools removeObjectForKey:name];
        }
      }
      NSArray<NSString *> *pending_names =
          [state->pending_webmcp_tools.allKeys copy];
      for (NSString *name in pending_names) {
        NSDictionary *pending_tool =
            state->pending_webmcp_tools[name];
        if ([pending_tool[@"contextID"] isEqualToString:context_id]) {
          [state->pending_webmcp_tools removeObjectForKey:name];
        }
      }
      PublishWebMCPToolsSnapshot(owner, state);
    }
    return true;
  }
  if (message_name == kWebMCPResultMessage ||
      message_name == kWebMCPErrorMessage) {
    if (!arguments || arguments->GetSize() < 2) {
      return true;
    }
    const std::string invocation_id =
        arguments->GetString(0).ToString();
    auto iterator = webmcp_invocations_.find(invocation_id);
    if (iterator == webmcp_invocations_.end()) {
      return true;
    }
    TatwoCEFWebMCPInvocationHandler completion = iterator->second;
    webmcp_invocations_.erase(iterator);
    NSString *payload = FromCefString(arguments->GetString(1));
    if (message_name == kWebMCPResultMessage) {
      completion(payload, nil);
    } else {
      completion(nil, payload.length > 0
          ? payload
          : @"webmcp_execute_failed");
    }
    return true;
  }
  return false;
}

void TatwoClient::InvokeWebMCPTool(
    CefRefPtr<CefBrowser> browser,
    NSString *tool_name,
    NSString *arguments_json,
    uint64_t navigation_generation,
    TatwoCEFWebMCPInvocationHandler completion) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserView *owner = owner_;
  BrowserState *state = State(owner);
  NSDictionary *tool =
      state == nullptr ? nil : state->webmcp_tools[tool_name];
  if (owner == nil || state == nullptr || !browser ||
      !state->browser || !state->browser->IsSame(browser) ||
      state->close_requested ||
      navigation_generation == 0 ||
      state->navigation_generation != navigation_generation ||
      tool == nil ||
      ![tool[@"navigationGeneration"]
          isEqualToNumber:@(navigation_generation)] ||
      ![tool[@"origin"]
          isEqualToString:OriginForURLString(state->committed_url)]) {
    completion(nil, @"webmcp_navigation_binding_unavailable");
    return;
  }
  NSData *arguments_data =
      [arguments_json dataUsingEncoding:NSUTF8StringEncoding];
  id parsed_arguments = arguments_data == nil
      ? nil
      : [NSJSONSerialization JSONObjectWithData:arguments_data
                                        options:0
                                          error:nil];
  if (parsed_arguments == nil ||
      arguments_data.length > kWebMCPMaximumPayloadBytes) {
    completion(nil, @"webmcp_arguments_invalid");
    return;
  }
  NSString *invocation_id =
      NSUUID.UUID.UUIDString.lowercaseString;
  webmcp_invocations_[invocation_id.UTF8String] = [completion copy];
  CefRefPtr<CefProcessMessage> message =
      CefProcessMessage::Create(kWebMCPInvokeMessage);
  CefRefPtr<CefListValue> message_arguments =
      message->GetArgumentList();
  message_arguments->SetString(0, ToCefString(invocation_id));
  message_arguments->SetString(1, ToCefString(tool_name));
  message_arguments->SetString(2, ToCefString(arguments_json));
  message_arguments->SetString(
      3, ToCefString(tool[@"contextID"]));
  CefRefPtr<CefFrame> main_frame = browser->GetMainFrame();
  if (!main_frame) {
    webmcp_invocations_.erase(invocation_id.UTF8String);
    completion(nil, @"webmcp_renderer_unavailable");
    return;
  }
  main_frame->SendProcessMessage(PID_RENDERER, message);
  __weak TatwoCEFBrowserView *weak_owner = owner;
  const uint64_t expected_mount_generation = mount_generation_;
  const std::string expected_invocation_id = invocation_id.UTF8String;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
        TatwoCEFBrowserView *active_owner = weak_owner;
        if (!IsActiveMountCallback(
                active_owner,
                expected_mount_generation,
                @"webmcp_invocation_timeout")) {
          return;
        }
        BrowserState *active_state = State(active_owner);
        if (active_state == nullptr || !active_state->client) {
          return;
        }
        auto pending =
            active_state->client->webmcp_invocations_.find(
                expected_invocation_id);
        if (pending == active_state->client->webmcp_invocations_.end()) {
          return;
        }
        TatwoCEFWebMCPInvocationHandler timed_out = pending->second;
        active_state->client->webmcp_invocations_.erase(pending);
        timed_out(nil, @"webmcp_invocation_timed_out");
      });
}

void TatwoClient::CancelPendingWebMCPInvocations(NSString *error_code) {
  CEF_REQUIRE_UI_THREAD();
  std::map<std::string, TatwoCEFWebMCPInvocationHandler> pending;
  pending.swap(webmcp_invocations_);
  for (const auto &entry : pending) {
    entry.second(nil, error_code);
  }
}

uint64_t BeginNavigationFrameTelemetry(TatwoCEFBrowserView *view,
                                       BrowserState *state,
                                       NSString *reason) {
  if (view == nil || state == nullptr || state->close_requested) {
    return 0;
  }
  const uint64_t navigation_generation = ++state->navigation_generation;
#pragma mark - W57d
  W57dInvalidate(view);
#pragma mark - W57d End
#pragma mark - W57c Revoke old document before navigation, retain only submitted form navigation
  W57cInvalidate(view, [reason isEqualToString:@"reload"],
                 [reason isEqualToString:@"renderer_navigation"]);
#pragma mark - W57c End
#pragma mark - W58
  W58Invalidate(view, [reason isEqualToString:@"renderer_navigation"]);
#pragma mark - W58 End
  state->navigation_in_flight = true;
  if (state->client) {
    state->client->InvalidateResourceErrors();
    state->client->CancelPendingBrowserOperations();
    state->client->CancelPendingWebMCPInvocations(
        @"webmcp_navigation_changed");
  }
  InvalidateWebMCPTools(view, state);
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=navigation_frame event=begin reason=%@ "
           "mountGeneration=%llu navigationGeneration=%llu",
          SanitizeTelemetryToken(reason, @"unknown"),
          state->mount_generation,
          navigation_generation]);
  return navigation_generation;
}

bool IsActiveMountCallback(TatwoCEFBrowserView *view,
                           uint64_t expected_generation,
                           NSString *event);

// W45-fix: a late human permission reply is only honoured while the mount is live,
// the page has not navigated, close has not been requested and the actor is still human.
bool IsPermissionReplyLive(TatwoCEFBrowserView *view,
                           uint64_t expected_mount,
                           uint64_t expected_navigation_generation) {
  if (!IsActiveMountCallback(view, expected_mount, @"permission_decision")) return false;
  BrowserState *state = State(view);
  if (state == nullptr || state->close_requested) return false;
  return view.navigationGeneration == expected_navigation_generation &&
         ActorRequestPolicy(view).human;
}

bool IsActiveMountCallback(TatwoCEFBrowserView *view,
                           uint64_t expected_generation,
                           NSString *event) {
  BrowserState *state = view == nil ? nullptr : State(view);
  if (state != nullptr &&
      state->mount_generation == expected_generation &&
      !state->close_completed) {
    return true;
  }
  const uint64_t stale_count =
      g_stale_callback_drop_count.fetch_add(
          1, std::memory_order_relaxed) + 1;
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=mount_generation event=stale_callback_dropped "
           "callback=%@ expectedGeneration=%llu activeGeneration=%llu "
           "staleCallbackDrops=%llu",
          SanitizeTelemetryToken(event, @"unknown"),
          expected_generation,
          state == nullptr ? 0 : state->mount_generation,
          stale_count]);
  return false;
}

#pragma mark - W60 Loading lifecycle compatibility (no timer)
void StopLoadingActiveMessagePump(TatwoCEFBrowserView *view,
                                  uint64_t expected_generation,
                                  NSString *reason) {
  NSCAssert(NSThread.isMainThread, @"CEF loading lifecycle is main-thread owned");
  if (!IsActiveMountCallback(view, expected_generation, @"loading_active_pump_stop")) return;
  BrowserState *state = State(view);
  state->loading_active_pump_gate.Stop();
  [state->loading_active_pump_timer invalidate];
  state->loading_active_pump_timer = nil;
}

void StartLoadingActiveMessagePump(TatwoCEFBrowserView *view,
                                   uint64_t expected_generation,
                                   NSString *reason) {
  // Call sites keep their lifecycle boundary, but must never start polling.
  // Host API kicks and CEF scheduling, not isLoading, drive the message loop.
  if (!IsActiveMountCallback(view, expected_generation, @"loading_active_pump_start")) return;
}
#pragma mark - W60 End

void CompleteBrowserClose(TatwoCEFBrowserView *view, BrowserState *state);

void ScheduleBrowserCloseRetry(TatwoCEFBrowserView *view,
                               BrowserState *state,
                               uint64_t generation) {
  if (view == nil || state == nullptr || State(view) != state ||
      state->close_completed || !state->close_requested ||
      state->close_generation != generation ||
      state->close_retry_scheduled) {
    return;
  }
  state->close_retry_scheduled = true;
  __weak TatwoCEFBrowserView *weak_view = view;
  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          kCEFBrowserCloseRetryDelayMilliseconds * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        TatwoCEFBrowserView *retry_view = weak_view;
        BrowserState *retry_state =
            retry_view == nil ? nullptr : State(retry_view);
        if (retry_state == nullptr || retry_state != state ||
            retry_state->close_completed ||
            !retry_state->close_requested ||
            retry_state->close_generation != generation) {
          return;
        }
        retry_state->close_retry_scheduled = false;
        if (retry_state->close_retry_attempt >=
            kCEFBrowserCloseMaximumAttempts) {
          LogBrowserLifecycle(
              @"close_retry_exhausted",
              static_cast<NSInteger>(retry_state->close_retry_attempt));
          if (!retry_state->browser && retry_state->creation_pending) {
            // CreateBrowser accepted the request, but CEF never returned
            // OnAfterCreated. There is no native browser to close, so waiting
            // forever would pin the Swift coordinator and its profile lease.
            // Complete the host-side close fail-closed after the bounded pump
            // budget. The client remains retained by CEF and will immediately
            // close a browser if the delayed callback eventually arrives.
            retry_state->creation_pending = false;
            if (retry_state->client) {
              retry_state->client->AbandonPendingCreation();
            }
            LogBrowserLifecycle(@"pending_create_close_failed_closed");
            CompleteBrowserClose(retry_view, retry_state);
          }
          return;
        }
        DriveBrowserClose(
            retry_view, retry_state, generation);
      });
}

void DriveBrowserClose(TatwoCEFBrowserView *view,
                       BrowserState *state,
                       uint64_t generation) {
  if (view == nil || state == nullptr || State(view) != state ||
      state->close_completed || !state->close_requested ||
      state->close_generation != generation) {
    return;
  }
  if (state->close_retry_attempt >= kCEFBrowserCloseMaximumAttempts) {
    return;
  }
  state->close_retry_attempt += 1;
  LogBrowserLifecycle(
      @"close_retry",
      static_cast<NSInteger>(state->close_retry_attempt));
  // Arm the bounded watchdog before CloseBrowser or the immediate pump. CEF
  // may synchronously reach OnBeforeClose and delete BrowserState.
  ScheduleBrowserCloseRetry(view, state, generation);

  CefRefPtr<CefBrowser> browser = state->browser;
  if (browser) {
    browser->GetHost()->CloseBrowser(true);
  }
  ScheduleImmediateCEFMessagePumpWork(
      browser ? @"close_browser" : @"close_browser_pending_create");
}

NSString *ViewAncestry(NSView *view) {
  NSMutableArray<NSString *> *entries = [NSMutableArray array];
  NSView *current = view;
  for (NSInteger depth = 0; current != nil && depth < 10; ++depth) {
    [entries addObject:
        SanitizeTelemetryToken(NSStringFromClass(current.class), @"unknown")];
    current = current.superview;
  }
  return [entries componentsJoinedByString:@">"];
}

NSString *DirectSubviewClasses(NSView *view) {
  if (view == nil || view.subviews.count == 0) {
    return @"none";
  }
  NSMutableArray<NSString *> *entries = [NSMutableArray array];
  for (NSView *subview in view.subviews) {
    [entries addObject:
        SanitizeTelemetryToken(NSStringFromClass(subview.class), @"unknown")];
  }
  return [entries componentsJoinedByString:@","];
}

NSString *LayerClassName(NSView *view) {
  return view.layer == nil
             ? @"none"
             : SanitizeTelemetryToken(
                   NSStringFromClass(view.layer.class), @"unknown");
}

void LogBrowserEmbeddingSnapshot(TatwoCEFBrowserView *view,
                                 CefRefPtr<CefBrowser> browser,
                                 NSString *phase,
                                 bool force) {
  if (view == nil) {
    return;
  }
  if (!NSThread.isMainThread) {
    __weak TatwoCEFBrowserView *weak_view = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      TatwoCEFBrowserView *main_view = weak_view;
      BrowserState *state =
          main_view == nil ? nullptr : State(main_view);
      LogBrowserEmbeddingSnapshot(
          main_view,
          state == nullptr ? nullptr : state->browser,
          phase,
          force);
    });
    return;
  }

  CefWindowHandle handle = nullptr;
  if (browser && browser->GetHost()) {
    handle = browser->GetHost()->GetWindowHandle();
  }
  NSView *child = handle == nullptr ? nil : (__bridge NSView *)handle;
  NSWindow *window = view.window;
  const BOOL child_parent_matches =
      child != nil && child.superview == view;
  NSString *signature = [NSString
      stringWithFormat:
          @"parentFrame=%@ parentBounds=%@ parentHidden=%d "
           "parentHiddenAncestor=%d parentWantsLayer=%d parentLayer=%@ "
           "parentWindow=%ld parentWindowNumber=%ld "
           "parentWindowVisible=%d childClass=%@ "
           "childFrame=%@ childBounds=%@ childHidden=%d "
           "childHiddenAncestor=%d childWantsLayer=%d childLayer=%@ "
           "childParentMatches=%d childWindow=%ld childWindowNumber=%ld",
          TelemetryRect(view.frame),
          TelemetryRect(view.bounds),
          view.hidden,
          view.hiddenOrHasHiddenAncestor,
          view.wantsLayer,
          LayerClassName(view),
          (long)(window == nil ? 0 : window.windowNumber),
          (long)(window == nil ? 0 : window.windowNumber),
          window.visible,
          child == nil
              ? @"none"
              : SanitizeTelemetryToken(
                    NSStringFromClass(child.class), @"unknown"),
          child == nil ? @"none" : TelemetryRect(child.frame),
          child == nil ? @"none" : TelemetryRect(child.bounds),
          child.hidden,
          child.hiddenOrHasHiddenAncestor,
          child.wantsLayer,
          LayerClassName(child),
          child_parent_matches,
          (long)(child.window == nil ? 0 : child.window.windowNumber),
          (long)(child.window == nil ? 0 : child.window.windowNumber)];
  BrowserState *state = State(view);
  if (state != nullptr &&
      !state->geometry_layer_ready_logged &&
      child != nil &&
      child_parent_matches &&
      view.layer != nil &&
      child.layer != nil &&
      window.visible) {
    state->geometry_layer_ready_logged = true;
    LogBrowserTimeline(
        @"geometry_layer_ready",
        state->mount_generation,
        0,
        state->is_loading);
  }
  if (!force && state != nullptr &&
      [state->last_embedding_signature isEqualToString:signature]) {
    return;
  }
  if (state != nullptr) {
    state->last_embedding_signature = [signature copy];
  }
  // Geometry-only diagnostics. Never include URL, profile paths, cookies,
  // page titles, user text, or other session data.
  NSString *ancestry = ViewAncestry(view);
  NSString *direct_subview_classes = DirectSubviewClasses(view);
  NSString *line =
      [NSString stringWithFormat:
          @"phase=%@ %@ ancestry=%@ viewAncestry=%@ "
           "subviews=%@ directSubviewClasses=%@",
          SanitizeTelemetryToken(phase, @"unknown"),
          signature,
          ancestry,
          ancestry,
          direct_subview_classes,
          direct_subview_classes];
  AppendCEFEmbeddingTelemetryLine(line);
  NSLog(@"[TatwoCEF] embedding %@", line);
}

void SynchronizeBrowserGeometry(TatwoCEFBrowserView *view,
                                CefRefPtr<CefBrowser> browser) {
  if (view == nil || !browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) {
    return;
  }
  LogBrowserEmbeddingSnapshot(view, browser, @"geometry_before", false);
  CefWindowHandle handle = host->GetWindowHandle();
  if (handle != nullptr) {
    NSView *child = (__bridge NSView *)handle;
    BrowserState *state = State(view);
    if (child.superview == view) {
      if (state != nullptr) {
        state->parent_mismatch_reported = false;
      }
      // For a normal windowed browser CEF owns attachment of the native child
      // returned by GetWindowHandle(). Only size that direct child. Reparenting
      // the compositor host here can detach Chromium-owned view state and hides
      // the exact host-contract failure that runtime diagnostics must expose.
      child.frame = NSMakeRect(0, 0,
                               std::max<CGFloat>(1, view.bounds.size.width),
                               std::max<CGFloat>(1, view.bounds.size.height));
      child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      child.hidden = NO;

      // This is a windowed browser with an external, client-provided root.
      // WasResized is OSR-only. NotifyScreenInfoChanged is the CEF contract
      // that refreshes screen position, scale and root bounds for this host.
      NSRect window_rect = [view convertRect:view.bounds toView:nil];
      NSRect screen_rect =
          view.window == nil
              ? NSZeroRect
              : [view.window convertRectToScreen:window_rect];
      const CGFloat backing_scale =
          view.window == nil ? 1 : view.window.backingScaleFactor;
      NSString *screen_info_signature =
          [NSString stringWithFormat:@"%@|%.3f|%@",
              TelemetryRect(screen_rect),
              backing_scale,
              TelemetryRect(child.frame)];
      if (state == nullptr ||
          ![state->last_screen_info_signature
              isEqualToString:screen_info_signature]) {
        if (state != nullptr) {
          state->last_screen_info_signature =
              [screen_info_signature copy];
        }
        host->NotifyScreenInfoChanged();
        AppendCEFEmbeddingTelemetryLine(
            @"phase=screen_info_notified reason=external_root_geometry");
      }
    } else {
      if (state == nullptr || !state->parent_mismatch_reported) {
        LogBrowserLifecycle(@"child_parent_mismatch");
        LogBrowserEmbeddingSnapshot(
            view, browser, @"child_parent_mismatch", true);
        if (state != nullptr) {
          state->parent_mismatch_reported = true;
        }
      }
    }
  }
  LogBrowserEmbeddingSnapshot(view, browser, @"geometry_after", false);
}

void RequestBrowserCompositorDisplay(TatwoCEFBrowserView *view,
                                     CefRefPtr<CefBrowser> browser,
                                     NSString *reason) {
  if (view == nil || !browser) {
    return;
  }
  if (!NSThread.isMainThread) {
    __weak TatwoCEFBrowserView *weak_view = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      TatwoCEFBrowserView *main_view = weak_view;
      BrowserState *state =
          main_view == nil ? nullptr : State(main_view);
      RequestBrowserCompositorDisplay(
          main_view,
          state == nullptr ? nullptr : state->browser,
          reason);
    });
    return;
  }

  BrowserState *state = State(view);
  if (state == nullptr || !state->browser ||
      !state->browser->IsSame(browser) || state->close_requested) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  CefWindowHandle handle = host ? host->GetWindowHandle() : nullptr;
  NSView *child = handle == nullptr ? nil : (__bridge NSView *)handle;
  if (child == nil || child.superview != view) {
    return;
  }

  // CEF's macOS windowed host requests display for both CefBrowserHostView and
  // its WebContents native child when it installs them. With an external parent
  // that installation can precede propagation of the supplied root's backing
  // layer, consuming the one-shot invalidation before the compositor is
  // displayable. Re-issue the same AppKit contract after attachment/main-frame
  // completion; do not reload, reparent, delay, or switch to OSR.
  [child setNeedsDisplay:YES];
  for (NSView *native_content_view in child.subviews) {
    [native_content_view setNeedsDisplay:YES];
  }
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=compositor_display_requested reason=%@",
          SanitizeTelemetryToken(reason, @"unknown")]);
  const uint64_t navigation_generation = state->navigation_generation;
  if ([reason isEqualToString:@"main_frame_load_end"] &&
      navigation_generation > 0 &&
      state->first_frame_presented_generation !=
          navigation_generation) {
    const uint64_t mount_generation = state->mount_generation;
    __weak TatwoCEFBrowserView *weak_view = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      TatwoCEFBrowserView *presented_view = weak_view;
      if (!IsActiveMountCallback(
              presented_view,
              mount_generation,
              @"first_frame_presented")) {
        return;
      }
      BrowserState *presented_state = State(presented_view);
      if (presented_state->navigation_generation !=
          navigation_generation) {
        AppendCEFEmbeddingTelemetryLine(
            [NSString stringWithFormat:
                @"phase=navigation_frame event=stale_presentation_dropped "
                 "mountGeneration=%llu expectedNavigationGeneration=%llu "
                 "activeNavigationGeneration=%llu",
                mount_generation,
                navigation_generation,
                presented_state->navigation_generation]);
        return;
      }
      CefRefPtr<CefBrowser> presented_browser = presented_state->browser;
      CefWindowHandle presented_handle =
          presented_browser && presented_browser->GetHost()
              ? presented_browser->GetHost()->GetWindowHandle()
              : nullptr;
      NSView *presented_child =
          presented_handle == nullptr
              ? nil
              : (__bridge NSView *)presented_handle;
      if (presented_child == nil ||
          presented_child.superview != presented_view ||
          presented_child.window == nil ||
          presented_child.hiddenOrHasHiddenAncestor ||
          presented_child.layer == nil) {
        return;
      }
      presented_state->first_frame_presented_generation =
          navigation_generation;
      LogBrowserTimeline(
          @"first_frame_presented",
          mount_generation,
          presented_state->http_status_code,
          false);
      AppendCEFEmbeddingTelemetryLine(
          [NSString stringWithFormat:
              @"phase=navigation_frame event=presented "
               "mountGeneration=%llu navigationGeneration=%llu",
              mount_generation,
              navigation_generation]);
    });
  }
}

void PublishStateNow(TatwoCEFBrowserView *view) {
  if (view == nil) {
    return;
  }
  BrowserState *state = State(view);
  if (state && state->popup_window) {
    NSString *origin = OriginForURLString(state->committed_url);
    if (origin.length == 0) origin = @"新視窗";
    state->popup_window.title = state->pending_error.length > 0
        ? [NSString stringWithFormat:@"%@ — %@", origin, state->pending_error]
        : origin;
  }
  CefRefPtr<CefBrowser> browser = state ? state->browser : nullptr;
  BOOL can_go_back = browser ? browser->CanGoBack() : NO;
  BOOL can_go_forward = browser ? browser->CanGoForward() : NO;
  TatwoCEFBrowserStateHandler handler = view.stateHandler;
  if (handler != nil) {
    handler(state ? state->committed_url : nil,
            state ? state->navigation_generation : 0,
            can_go_back,
            can_go_forward,
            state ? state->is_loading : NO,
            state ? state->phase : TatwoCEFBrowserPhaseClosed,
            state ? state->http_status_code : 0,
            state ? state->error_kind : TatwoCEFBrowserErrorKindNone,
            state ? state->error_code : 0,
            state ? state->pending_error : nil);
  }
}

void PublishState(TatwoCEFBrowserView *view) {
  if (view == nil) {
    return;
  }
  if (NSThread.isMainThread) {
    PublishStateNow(view);
    return;
  }
  __weak TatwoCEFBrowserView *weak_view = view;
  dispatch_async(dispatch_get_main_queue(), ^{
    PublishStateNow(weak_view);
  });
}

void MutateStateOnMain(TatwoCEFBrowserView *view,
                       void (^mutation)(BrowserState *)) {
  if (view == nil) {
    return;
  }
  void (^work)(void) = ^{
    BrowserState *state = State(view);
    if (state == nullptr || state->close_completed) {
      return;
    }
    mutation(state);
    PublishStateNow(view);
  };
  if (NSThread.isMainThread) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

void InvalidateSecurityDocumentEpoch(TatwoCEFBrowserView *view,
                                     NSString *reason) {
  MutateStateOnMain(view, ^(BrowserState *state) {
    state->document_epoch_valid = false;
    if (state->document_epoch < std::numeric_limits<uint64_t>::max()) {
      state->document_epoch += 1;
    }
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=document_epoch event=invalidated reason=%@ "
             "navigationGeneration=%llu documentEpoch=%llu",
            SanitizeTelemetryToken(reason, @"unknown"),
            state->security_navigation_generation,
            state->document_epoch]);
  });
}

void PublishVisibleError(TatwoCEFBrowserView *view,
                         NSString *message,
                         TatwoCEFBrowserErrorKind kind,
                         NSInteger code,
                         TatwoCEFBrowserPhase phase) {
  MutateStateOnMain(view, ^(BrowserState *state) {
    StopLoadingActiveMessagePump(
        view, state->mount_generation, @"visible_error");
    state->is_loading = false;
    state->phase = phase;
    state->error_kind = kind;
    state->error_code = code;
    state->pending_error = [message copy];
  });
}

void PublishResourceError(TatwoCEFBrowserView *view,
                          ResourceErrorContext context,
                          NSString *message,
                          bool dns_failure) {
  __weak TatwoCEFBrowserView *weak_view = view;
  dispatch_async(dispatch_get_main_queue(), ^{
    TatwoCEFBrowserView *active_view = weak_view;
    BrowserState *state = active_view == nil ? nullptr : State(active_view);
    // Check at delivery, not when DNS finishes: a new navigation can begin
    // while this main-queue callback is waiting. Never touch UI state on IO.
    if (!context.epoch || !context.epoch->IsCurrent(context.generation) ||
        !state || state->mount_generation != context.mount_generation ||
        state->close_requested || state->close_completed) {
      return;
    }
    // This request is still current. Finish its cancelled navigation here,
    // where epoch/mount checks prevent an old abort from stopping a newer one.
    FinishNavigationFrameTelemetry(active_view);
    PublishVisibleError(
        active_view, message,
        dns_failure ? TatwoCEFBrowserErrorKindNavigation
                    : TatwoCEFBrowserErrorKindSecurity,
        dns_failure ? ERR_NAME_NOT_RESOLVED : ERR_BLOCKED_BY_CLIENT,
        dns_failure ? TatwoCEFBrowserPhaseNavigationFailed
                    : TatwoCEFBrowserPhaseBlockedBySecurity);
  });
}

void UpdateLoadingState(TatwoCEFBrowserView *view, bool is_loading) {
  MutateStateOnMain(view, ^(BrowserState *state) {
    state->is_loading = is_loading;
    // Browser-level loading includes late iframes. Main-frame callbacks own
    // document phase; background resources must not make a readable page unusable.
    if (is_loading &&
        state->phase != TatwoCEFBrowserPhaseCommitted &&
        state->phase != TatwoCEFBrowserPhaseFinished &&
        state->phase != TatwoCEFBrowserPhaseBlockedBySecurity &&
        state->phase != TatwoCEFBrowserPhaseNavigationFailed &&
        state->phase != TatwoCEFBrowserPhaseRendererFailed) {
      state->phase = TatwoCEFBrowserPhaseLoading;
    }
    if (is_loading) {
      StartLoadingActiveMessagePump(
          view, state->mount_generation, @"loading_state_active");
    } else {
      StopLoadingActiveMessagePump(
          view, state->mount_generation, @"loading_state_idle");
    }
  });
}

void PublishMainFrameLoadStart(TatwoCEFBrowserView *view) {
  MutateStateOnMain(view, ^(BrowserState *state) {
    state->is_loading = true;
    state->phase = TatwoCEFBrowserPhaseLoading;
    state->http_status_code = 0;
    state->error_kind = TatwoCEFBrowserErrorKindNone;
    state->error_code = 0;
    state->pending_error = nil;
    StartLoadingActiveMessagePump(
        view, state->mount_generation, @"main_frame_load_start");
  });
}

void PublishMainFrameLoadEnd(TatwoCEFBrowserView *view,
                             CefRefPtr<CefFrame> frame,
                             int http_status_code) {
  NSString *url = frame ? FromCefString(frame->GetURL()) : nil;
  MutateStateOnMain(view, ^(BrowserState *state) {
    StopLoadingActiveMessagePump(
        view, state->mount_generation, @"main_frame_load_end_publish");
    state->is_loading = false;
    state->phase = TatwoCEFBrowserPhaseFinished;
    state->http_status_code = http_status_code;
    state->committed_url = [url copy];
    state->error_kind = TatwoCEFBrowserErrorKindNone;
    state->error_code = 0;
    state->pending_error = nil;
  });
}

void PublishMainFrameCommit(TatwoCEFBrowserView *view,
                            const CefString &url) {
  NSString *committed_url = FromCefString(url);
  MutateStateOnMain(view, ^(BrowserState *state) {
    if (state->security_navigation_generation ==
            std::numeric_limits<uint64_t>::max() ||
        state->document_epoch ==
            std::numeric_limits<uint64_t>::max()) {
      state->document_epoch_valid = false;
      state->is_loading = false;
      state->phase = TatwoCEFBrowserPhaseBlockedBySecurity;
      state->error_kind = TatwoCEFBrowserErrorKindSecurity;
      state->error_code = ERR_BLOCKED_BY_CLIENT;
      state->pending_error = kPrivacyStrictStartupError;
      return;
    }
    state->security_navigation_generation += 1;
    state->document_epoch += 1;
    state->document_epoch_valid = true;
    state->committed_url = [committed_url copy];
    state->phase = TatwoCEFBrowserPhaseCommitted;
    state->error_kind = TatwoCEFBrowserErrorKindNone;
    state->error_code = 0;
    state->pending_error = nil;
    ActivatePendingWebMCPToolsForCommit(
        view, state, committed_url);
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=document_epoch event=main_frame_committed "
             "navigationGeneration=%llu documentEpoch=%llu",
            state->security_navigation_generation,
            state->document_epoch]);
    g_active_committed_browser_view = view;
  });
}

bool HasVisibleSecurityError(TatwoCEFBrowserView *view) {
  BrowserState *state = State(view);
  return state != nullptr &&
         state->error_kind == TatwoCEFBrowserErrorKindSecurity;
}

void PublishCreationTimeoutIfPending(TatwoCEFBrowserView *view,
                                    bool waiting_for_context = false) {
  BrowserState *initial_state = State(view);
  if (!initial_state || initial_state->close_requested ||
      initial_state->close_completed) return;
  const uint64_t mount_generation = initial_state->mount_generation;
  __weak TatwoCEFBrowserView *weak_view = view;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
        TatwoCEFBrowserView *view = weak_view;
        if (!IsActiveMountCallback(
                view, mount_generation, @"startup_timeout")) return;
        BrowserState *state = State(view);
        const bool pending = waiting_for_context
            ? !state->request_context_security_ready
            : state->creation_pending;
        if (!pending || state->close_requested ||
            state->request_context_security_blocked ||
            state->phase != TatwoCEFBrowserPhaseCreating) {
          return;
        }
        if (waiting_for_context) {
          // A late readiness callback must not revive a timed-out startup.
          state->request_context_security_blocked = true;
          if (state->request_context_handler) {
            state->request_context_handler->Cancel();
            state->request_context_handler = nullptr;
          }
        }
        PublishVisibleError(
            view,
            @"Chromium 啟動逾時，個人資料或子程序無法初始化",
            TatwoCEFBrowserErrorKindStartup,
            ERR_TIMED_OUT,
            TatwoCEFBrowserPhaseStartupFailed);
      });
}

void CompleteBrowserClose(TatwoCEFBrowserView *view, BrowserState *state) {
  if (view == nil || state == nullptr || state->close_completed ||
      State(view) != state) {
    return;
  }
  StopLoadingActiveMessagePump(
      view, state->mount_generation, @"close_completed");
  state->document_epoch_valid = false;
  if (state->document_epoch < std::numeric_limits<uint64_t>::max()) {
    state->document_epoch += 1;
  }
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=document_epoch event=invalidated reason=close "
           "navigationGeneration=%llu documentEpoch=%llu",
          state->security_navigation_generation,
          state->document_epoch]);
  state->close_completed = true;
  LogBrowserLifecycle(@"close_completed");
  state->phase = TatwoCEFBrowserPhaseClosed;
  state->is_loading = false;
  if (state->client) {
    state->client->CancelPendingBrowserOperations();
    state->client->CancelPendingWebMCPInvocations(
        @"webmcp_browser_closed");
    InvalidateWebMCPTools(view, state);
    state->client->DetachOwner();
  }
  if (state->request_context_handler) {
    state->request_context_handler->Cancel();
    state->request_context_handler = nullptr;
  }
  if (g_active_committed_browser_view == view) {
    g_active_committed_browser_view = nil;
  }
  state->browser = nullptr;
  state->request_context = nullptr;
  state->client = nullptr;
  NSWindow *popup_window = state->popup_window;
  BrowserState *opener = State(state->opener);
  if (opener) [opener->popup_views removeObjectIdenticalTo:view];
  for (TatwoCEFBrowserView *popup in [state->popup_views copy]) {
    [popup closeBrowser];
  }
  NSArray *handlers = [state->close_handlers copy];
  view->_cefState = nullptr;
  [g_closing_views removeObject:view];
  [g_live_browser_views removeObject:view];
  delete state;
  if (popup_window) {
    popup_window.delegate = nil;
    popup_window.contentView = nil;
    [popup_window close];
  }
  for (TatwoCEFBrowserCloseHandler handler in handlers) {
    handler();
  }
}

void TatwoClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  TatwoCEFBrowserView *owner = owner_;
  if (owner == nil) {
    if (close_late_browser_) {
      LogBrowserLifecycle(@"late_browser_closed_after_pending_timeout");
      browser->GetHost()->CloseBrowser(true);
      ScheduleImmediateCEFMessagePumpWork(
          @"late_browser_close_after_pending_timeout");
    }
    return;
  }
  if (!IsActiveMountCallback(
          owner, mount_generation_, @"on_after_created")) {
    LogBrowserLifecycle(@"stale_browser_closed_after_created");
    browser->GetHost()->CloseBrowser(true);
    ScheduleImmediateCEFMessagePumpWork(
        @"stale_browser_close_after_created");
    return;
  }
  if (owner != nil) {
    BrowserState *state = State(owner);
    if (state) {
      state->browser = browser;
      state->creation_pending = false;
      state->pending_error = nil;
      state->phase = TatwoCEFBrowserPhaseLoading;
      state->is_loading = true;
      state->error_kind = TatwoCEFBrowserErrorKindNone;
      state->error_code = 0;
      LogBrowserNavigationTrace(@"browser_created", 0, true);
      LogBrowserTimeline(
          @"on_after_created",
          state->mount_generation,
          0,
          true);
      LogBrowserLifecycle(@"on_after_created");
      StartLoadingActiveMessagePump(
          owner, state->mount_generation, @"on_after_created");
      if (state->close_requested) {
        // Pending creation may have consumed its bounded pump budget before an
        // actual CefBrowser existed. Move to a fresh generation so stale
        // pending-create timers cannot race the real-browser close watchdog.
        state->close_generation += 1;
        state->close_retry_attempt = 0;
        state->close_retry_scheduled = false;
        LogBrowserLifecycle(@"close_after_created");
        DriveBrowserClose(
            owner, state, state->close_generation);
        return;
      }
      SynchronizeBrowserGeometry(owner, browser);
      [owner setNeedsLayout:YES];
      RequestBrowserCompositorDisplay(
          owner, browser, @"on_after_created");
      LogBrowserEmbeddingSnapshot(owner, browser, @"on_after_created", true);
      __weak TatwoCEFBrowserView *weak_owner = owner;
      const uint64_t delayed_mount_generation = mount_generation_;
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
          dispatch_get_main_queue(), ^{
            TatwoCEFBrowserView *delayed_owner = weak_owner;
            if (!IsActiveMountCallback(
                    delayed_owner,
                    delayed_mount_generation,
                    @"on_after_created_500ms")) {
              return;
            }
            BrowserState *delayed_state = State(delayed_owner);
            LogBrowserEmbeddingSnapshot(
                delayed_owner,
                delayed_state->browser,
                @"on_after_created_500ms",
                true);
          });
      NSString *pending_url = [state->pending_url copy];
      TatwoCEFBrowserInputDispatchGate pending_gate =
          [state->pending_navigation_gate copy];
      state->pending_url = nil;
      state->pending_navigation_gate = nil;
      if (pending_url.length > 0) {
        BeginNavigationFrameTelemetry(
            owner, state, @"pending_navigation");
        const BOOL dispatched = DispatchBrowserNavigation(owner, pending_gate, ^{
          browser->GetMainFrame()->LoadURL(ToCefString(pending_url));
        });
        if (!dispatched) {
          PublishVisibleError(owner, @"瀏覽器操作已撤回，請重新觀察後再試。",
                              TatwoCEFBrowserErrorKindNavigation, ERR_ABORTED,
                              TatwoCEFBrowserPhaseNavigationFailed);
        }
        ScheduleImmediateCEFMessagePumpWork(@"pending_navigation");
      }
    }
  }
  PublishState(owner);
}

bool TatwoClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  TatwoCEFBrowserView *owner = owner_;
  BrowserState *state = State(owner);
  if (!state || !state->browser || !browser ||
      !state->browser->IsSame(browser)) {
    return false;
  }
  NSView *native_view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  if (native_view == nil || native_view.superview != owner) {
    return false;
  }
  // Alloy's default closes the entire top-level NSWindow. This embedded page
  // owns only the CEF child view; its deallocation triggers WindowDestroyed
  // and the real OnBeforeClose callback. Never fabricate host completion.
  CefRefPtr<TatwoClient> keep_alive = this;
  LogBrowserLifecycle(@"native_child_close");
  [native_view removeFromSuperview];
  return true;
}

void TatwoClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
#pragma mark - W57d
  W57dInvalidate(owner_);
#pragma mark - W57d End
  CancelPendingBrowserOperations();
  CancelPendingWebMCPInvocations(@"webmcp_browser_closed");
  TatwoCEFBrowserView *owner = owner_;
  if (owner != nil) {
    BrowserState *state = State(owner);
    if (state && state->browser && state->browser->IsSame(browser)) {
      LogBrowserLifecycle(@"on_before_close");
      CompleteBrowserClose(owner, state);
    }
  }
}

#pragma mark - W57d
bool W57dCurrent(TatwoCEFBrowserView *view, uint64_t generation) {
  return view && view.browserActor == TatwoCEFBrowserActorHuman && !view.agentControlled &&
      view.window && !view.isHiddenOrHasHiddenAncestor && BrowserInputIsCurrent(view, generation);
}

void TatwoClient::W57dCancel() {
  ++web_features_serial_; // Revoke even if a page becomes human again before an old reply.
  ++file_dialog_serial_;
  auto file_callback = file_dialog_callback_;
  file_dialog_callback_ = nullptr;
  auto pdf_completion = pdf_download_completion_;
  pdf_download_completion_ = nil;
  pdf_download_url_ = nil;
  pdf_download_path_ = nil;
  pdf_print_pending_ = false;
  if (file_callback) file_callback->Cancel();
  if (pdf_completion) pdf_completion(nil);
}

void W57dInvalidate(TatwoCEFBrowserView *view) {
  // Revoke Swift presentation first; cancelling CEF may invoke a PDF completion inline.
  if (view.onWebFeaturesInvalidated) view.onWebFeaturesInvalidated();
  auto *state = State(view);
  if (state && state->client) state->client->W57dCancel();
  [view exitContentFullscreen];
}

bool TatwoClient::OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode,
    const CefString &title, const CefString &default_file_path,
    const std::vector<CefString> &accept_filters,
    const std::vector<CefString> &accept_extensions,
    const std::vector<CefString> &accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  const uint64_t generation = owner_.navigationGeneration;
  if (!W57dCurrent(owner_, generation) || !owner_.onFileDialog || file_dialog_callback_ ||
      mode < FILE_DIALOG_OPEN || mode >= FILE_DIALOG_NUM_VALUES) {
    callback->Cancel();
    return true; // Never fall through to CEF's default picker, especially for agents.
  }
  file_dialog_callback_ = callback;
  const uint64_t serial = web_features_serial_;
  const uint64_t dialog_serial = ++file_dialog_serial_;
  NSMutableArray<NSString *> *filters = [NSMutableArray array];
  for (const auto &filter : accept_filters) [filters addObject:FromCefString(filter)];
  CefRefPtr<TatwoClient> client = this;
  owner_.onFileDialog(mode, FromCefString(title), FromCefString(default_file_path),
      filters, mode == FILE_DIALOG_OPEN_MULTIPLE, ^(NSArray<NSString *> *paths) {
    // Swift's native sheet replies on main; a stale/duplicate response cannot select files.
    dispatch_block_t reply = ^{
      if (client->web_features_serial_ != serial || client->file_dialog_serial_ != dialog_serial ||
          !client->file_dialog_callback_) return;
      auto pending = client->file_dialog_callback_;
      client->file_dialog_callback_ = nullptr;
      // Consume before Continue, which may synchronously reenter CEF.
      std::vector<CefString> selected;
      if (W57dCurrent(client->owner_, generation) &&
          (mode == FILE_DIALOG_OPEN_MULTIPLE || paths.count == 1)) {
        for (NSString *path in paths) {
          if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) { selected.clear(); break; }
          selected.push_back(ToCefString(path));
        }
      }
      if (selected.empty()) pending->Cancel();
      else pending->Continue(selected);
      ScheduleImmediateCEFMessagePumpWork(@"file_dialog_reply");
    };
    if (NSThread.isMainThread) reply();
    else dispatch_async(dispatch_get_main_queue(), reply);
  });
  return true;
}

// Only a completed regular .pdf reserved by this browser can be offered to Preview.
bool W57dIsPDF(NSString *path) {
  if (![path.pathExtension.lowercaseString isEqualToString:@"pdf"]) return false;
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
  if (fd < 0) return false;
  struct stat info {};
  char header[5] {};
  const bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
      read(fd, header, sizeof(header)) == sizeof(header) && std::string(header, 5) == "%PDF-";
  close(fd);
  return valid;
}

void TatwoClient::W57dDownloadUpdate(CefRefPtr<CefDownloadItem> item) {
  if (!pdf_download_completion_ || !pdf_download_path_ || item->GetId() != pdf_download_id_ ||
      (!item->IsComplete() && !item->IsCanceled() && item->IsInProgress())) return;
  auto completion = pdf_download_completion_;
  NSString *path = pdf_download_path_;
  pdf_download_completion_ = nil;
  pdf_download_path_ = nil;
  pdf_download_url_ = nil;
  const bool current = W57dCurrent(owner_, owner_.navigationGeneration);
  completion(current && item->IsComplete() &&
      [path isEqualToString:FromCefString(item->GetFullPath())] && W57dIsPDF(path) ? path : nil);
}

// CefPrintHandler is Linux-only in the pinned SDK; macOS uses the native Print().
class W57dPDFPrintCallback final : public CefPdfPrintCallback {
 public:
  explicit W57dPDFPrintCallback(std::function<void(bool)> completion)
      : completion_(std::move(completion)) {}
  void OnPdfPrintFinished(const CefString &path, bool ok) override { completion_(ok); }
 private:
  std::function<void(bool)> completion_;
  IMPLEMENT_REFCOUNTING(W57dPDFPrintCallback);
};
#pragma mark - W57d End

class TatwoLambdaCompletion final : public CefCompletionCallback {
 public:
  explicit TatwoLambdaCompletion(std::function<void()> callback)
      : callback_(std::move(callback)) {}

  void OnComplete() override {
    if (callback_) {
      auto callback = std::move(callback_);
      callback();
    }
  }

  void Cancel() { callback_ = nullptr; }

 private:
  std::function<void()> callback_;
  IMPLEMENT_REFCOUNTING(TatwoLambdaCompletion);
};

class TatwoDeletingCookieVisitor final : public CefCookieVisitor {
 public:
  explicit TatwoDeletingCookieVisitor(std::function<void()> completion)
      : completion_(std::move(completion)) {}

  ~TatwoDeletingCookieVisitor() override {
    if (completion_) {
      auto completion = std::move(completion_);
      completion();
    }
  }

  bool Visit(const CefCookie &cookie,
             int count,
             int total,
             bool &deleteCookie) override {
    // VisitUrlCookies has already constrained this visit by scheme, host,
    // domain and path. includeHttpOnly=true is supplied by the caller.
    deleteCookie = true;
    return true;
  }

  void CancelCompletion() { completion_ = nullptr; }

 private:
  std::function<void()> completion_;
  IMPLEMENT_REFCOUNTING(TatwoDeletingCookieVisitor);
};

class TatwoOriginDataClearOperation;
void ReleaseOriginDataClearOperation(
    TatwoOriginDataClearOperation *operation);
void TimeoutOriginDataClearOperation(uint64_t operation_id);

class TatwoOriginDataClearOperation final
    : public CefClient,
      public CefLifeSpanHandler,
      public CefDevToolsMessageObserver {
 public:
  TatwoOriginDataClearOperation(
      NSString *origin,
      NSString *persistent_profile,
      TatwoCEFOriginDataClearHandler completion)
      : origin_([origin copy]),
        persistent_profile_([persistent_profile copy]),
        completion_([completion copy]),
        operation_id_(
            g_origin_data_clear_operation_seed.fetch_add(
                1, std::memory_order_relaxed) + 1) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
    return this;
  }

  void Start() {
    const uint64_t operation_id = operation_id_;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
          TimeoutOriginDataClearOperation(operation_id);
        });
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = ToCefString(persistent_profile_);
    settings.persist_session_cookies = true;
    CefRefPtr<TatwoOriginDataClearOperation> self = this;
    request_context_handler_ =
        new TatwoPrivacyStrictRequestContextHandler(
            [self](
                CefRefPtr<CefRequestContext> request_context,
                bool configured) {
              self->RequestContextInitialized(
                  request_context, configured);
            });
    request_context_ = CefRequestContext::CreateContext(
        settings,
        request_context_handler_);
    if (!request_context_) {
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieManagerUnavailable,
          @"Chromium request context unavailable"));
      return;
    }
  }

  void RequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context,
      bool configured) {
    request_context_handler_ = nullptr;
    if (finished_.load()) {
      return;
    }
    if (!request_context_ ||
        !request_context_->IsSame(request_context)) {
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieManagerUnavailable,
          kPrivacyStrictStartupError));
      return;
    }
    if (!configured) {
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieManagerUnavailable,
          kPrivacyStrictStartupError));
      return;
    }

    CefRefPtr<TatwoOriginDataClearOperation> self = this;
    cookie_manager_ = request_context_->GetCookieManager(
        new TatwoLambdaCompletion([self]() {
          self->BeginCookieClear();
        }));
    if (!cookie_manager_) {
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieManagerUnavailable,
          @"Chromium cookie manager unavailable"));
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (finished_.load()) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    browser_ = browser;
    devtools_registration_ =
        browser->GetHost()->AddDevToolsMessageObserver(this);
    if (!devtools_registration_) {
      FailStorage(MakeError(
          TatwoCEFOriginDataClearErrorStorageCommandRejected,
          @"Chromium DevTools observer unavailable"));
      return;
    }

    CefRefPtr<CefDictionaryValue> params =
        CefDictionaryValue::Create();
    params->SetString("origin", ToCefString(origin_));
    params->SetString(
        "storageTypes",
        "local_storage,indexeddb,service_workers,cache_storage");
    storage_message_id_ = browser->GetHost()->ExecuteDevToolsMethod(
        0,
        "Storage.clearDataForOrigin",
        params);
    if (storage_message_id_ == 0) {
      FailStorage(MakeError(
          TatwoCEFOriginDataClearErrorStorageCommandRejected,
          @"Chromium origin storage command was not submitted"));
    }
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    browser_ = nullptr;
    devtools_registration_ = nullptr;
    if (maintenance_window_ != nil) {
      [maintenance_window_ close];
      maintenance_window_ = nil;
    }
    Finish(pending_error_);
  }

  void PrepareForRuntimeShutdown() {
    if (finished_.load()) {
      return;
    }
    pending_error_ = MakeError(
        TatwoCEFOriginDataClearErrorRuntimeUnavailable,
        @"Chromium runtime is shutting down");
    storage_message_id_ = 0;
    devtools_registration_ = nullptr;
    if (browser_) {
      browser_->GetHost()->CloseBrowser(true);
    }
  }

  uint64_t operation_id() const { return operation_id_; }

  void Timeout() {
    if (finished_.load()) {
      return;
    }
    NSError *error = MakeError(
        TatwoCEFOriginDataClearErrorTimedOut,
        @"Chromium origin data clear timed out");
    pending_error_ = error;
    if (browser_) {
      browser_->GetHost()->CloseBrowser(true);
    } else {
      Finish(error);
    }
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (finished_.load() || message_id != storage_message_id_) {
      return;
    }
    storage_message_id_ = 0;
    if (success) {
      origin_storage_cleared_ = true;
    } else {
      pending_error_ = MakeError(
          TatwoCEFOriginDataClearErrorStorageCommandFailed,
          @"Chromium origin storage clear failed");
    }
    browser->GetHost()->CloseBrowser(true);
  }

 private:
  void BeginCookieClear() {
    if (finished_.load()) {
      return;
    }
    CefRefPtr<TatwoOriginDataClearOperation> self = this;
    CefRefPtr<TatwoDeletingCookieVisitor> visitor =
        new TatwoDeletingCookieVisitor([self]() {
          self->CookieVisitFinished();
        });
    const bool accepted = cookie_manager_->VisitUrlCookies(
        ToCefString(origin_),
        true,
        visitor);
    if (!accepted) {
      visitor->CancelCompletion();
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieVisitRejected,
          @"Chromium URL-scoped cookie visit was rejected"));
    }
  }

  void CookieVisitFinished() {
    if (finished_.load()) {
      return;
    }
    CefRefPtr<TatwoOriginDataClearOperation> self = this;
    const bool accepted = cookie_manager_->FlushStore(
        new TatwoLambdaCompletion([self]() {
          self->cookies_cleared_ = true;
          self->BeginOriginStorageClear();
        }));
    if (!accepted) {
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorCookieVisitRejected,
          @"Chromium cookie deletion could not be flushed"));
    }
  }

  void BeginOriginStorageClear() {
    if (finished_.load()) {
      return;
    }
    maintenance_window_ =
        [[NSWindow alloc]
            initWithContentRect:NSMakeRect(-10000, -10000, 1, 1)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
    maintenance_window_.releasedWhenClosed = NO;
    maintenance_window_.ignoresMouseEvents = YES;
    maintenance_window_.alphaValue = 0;
    NSView *maintenance_view =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    maintenance_window_.contentView = maintenance_view;

    CefWindowInfo window_info;
    window_info.SetAsChild(
        (__bridge CefWindowHandle)maintenance_view,
        CefRect(0, 0, 1, 1));
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings browser_settings;
    browser_settings.javascript_close_windows = STATE_DISABLED;
    browser_settings.javascript_access_clipboard = STATE_DISABLED;
    browser_settings.javascript_dom_paste = STATE_DISABLED;
    const bool created = CefBrowserHost::CreateBrowser(
        window_info,
        this,
        "about:blank",
        browser_settings,
        nullptr,
        request_context_);
    if (!created) {
      [maintenance_window_ close];
      maintenance_window_ = nil;
      Finish(MakeError(
          TatwoCEFOriginDataClearErrorMaintenanceBrowserCreationFailed,
          @"Chromium maintenance browser creation failed"));
    }
  }

  void FailStorage(NSError *error) {
    pending_error_ = error;
    if (browser_) {
      browser_->GetHost()->CloseBrowser(true);
    } else {
      Finish(error);
    }
  }

  void Finish(NSError *error) {
    if (finished_.exchange(true)) {
      return;
    }
    TatwoCEFOriginDataClearHandler completion = completion_;
    completion_ = nil;
    if (completion != nil) {
      completion(
          cookies_cleared_,
          origin_storage_cleared_,
          YES,
          error);
    }
    if (request_context_handler_) {
      request_context_handler_->Cancel();
      request_context_handler_ = nullptr;
    }
    cookie_manager_ = nullptr;
    request_context_ = nullptr;
    ReleaseOriginDataClearOperation(this);
  }

  NSString *origin_;
  NSString *persistent_profile_;
  TatwoCEFOriginDataClearHandler completion_;
  NSWindow *maintenance_window_;
  NSError *pending_error_;
  CefRefPtr<TatwoPrivacyStrictRequestContextHandler>
      request_context_handler_;
  CefRefPtr<CefRequestContext> request_context_;
  CefRefPtr<CefCookieManager> cookie_manager_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_registration_;
  std::atomic_bool finished_{false};
  int storage_message_id_ = 0;
  const uint64_t operation_id_;
  bool cookies_cleared_ = false;
  bool origin_storage_cleared_ = false;
  IMPLEMENT_REFCOUNTING(TatwoOriginDataClearOperation);
};

std::vector<CefRefPtr<TatwoOriginDataClearOperation>>
    g_origin_data_clear_operations;

void RetainOriginDataClearOperation(
    CefRefPtr<TatwoOriginDataClearOperation> operation) {
  g_origin_data_clear_operations.push_back(operation);
}

void ReleaseOriginDataClearOperation(
    TatwoOriginDataClearOperation *operation) {
  g_origin_data_clear_operations.erase(
      std::remove_if(
          g_origin_data_clear_operations.begin(),
          g_origin_data_clear_operations.end(),
          [operation](
              const CefRefPtr<TatwoOriginDataClearOperation> &candidate) {
            return candidate.get() == operation;
          }),
      g_origin_data_clear_operations.end());
}

void TimeoutOriginDataClearOperation(uint64_t operation_id) {
  auto iterator = std::find_if(
      g_origin_data_clear_operations.begin(),
      g_origin_data_clear_operations.end(),
      [operation_id](
          const CefRefPtr<TatwoOriginDataClearOperation> &candidate) {
        return candidate && candidate->operation_id() == operation_id;
      });
  if (iterator != g_origin_data_clear_operations.end()) {
    (*iterator)->Timeout();
  }
}

constexpr int64_t kCEFShutdownDrainBudgetMilliseconds = 2000;

NSUInteger LiveBrowserReferenceCount() {
  return g_live_browser_views.count + g_closing_views.count;
}

bool CEFBridgeReferencesReleasedForShutdown() {
  return LiveBrowserReferenceCount() == 0 &&
         g_origin_data_clear_operations.empty() &&
         PendingResourceDecisionCount() == 0;
}

void PrepareCEFReferencesForShutdown() {
  g_active_committed_browser_view = nil;
  CancelPendingResourceDecisionsForShutdown();

  NSMutableOrderedSet<TatwoCEFBrowserView *> *views =
      [NSMutableOrderedSet orderedSet];
  [views addObjectsFromArray:g_live_browser_views.allObjects];
  [views addObjectsFromArray:g_closing_views.allObjects];
  for (TatwoCEFBrowserView *view in views) {
    [view closeBrowser];
  }

  std::vector<CefRefPtr<TatwoOriginDataClearOperation>> operations =
      g_origin_data_clear_operations;
  for (const CefRefPtr<TatwoOriginDataClearOperation> &operation :
       operations) {
    if (operation) {
      operation->PrepareForRuntimeShutdown();
    }
  }
}

bool DrainCEFReferencesForShutdown() {
  PrepareCEFReferencesForShutdown();
  const int64_t deadline =
      MonotonicMilliseconds() + kCEFShutdownDrainBudgetMilliseconds;
  do {
    if (CEFBridgeReferencesReleasedForShutdown()) {
      return true;
    }
    CefDoMessageLoopWork();
    usleep(1000);
  } while (MonotonicMilliseconds() < deadline);
  return CEFBridgeReferencesReleasedForShutdown();
}

}  // namespace

NSString *TatwoCEFOriginForURLString(NSString *urlString) {
  return OriginForURLString(urlString);
}

extern "C" uint64_t TatwoCEFMessagePumpGateRepeatedKickProbe(
    uint32_t kicks) {
  MessagePumpFollowUpGate gate;
  uint64_t do_work_count = 0;
  uint64_t follow_up_schedule_count = 0;

  if (gate.TryBegin()) {
    ++do_work_count;
  }
  for (uint32_t index = 0; index < kicks; ++index) {
    if (gate.TryBegin()) {
      ++do_work_count;
    }
  }
  if (gate.EndAndTakeFollowUp()) {
    ++follow_up_schedule_count;
    if (gate.TryBegin()) {
      ++do_work_count;
      if (gate.EndAndTakeFollowUp()) {
        ++follow_up_schedule_count;
      }
    }
  }

  return (do_work_count << 32) | follow_up_schedule_count;
}

extern "C" bool TatwoCEFMessagePumpShutdownLateBlockProbe(void) {
  constexpr uint64_t kCurrentGeneration = 17;
  return CanRunScheduledMessagePump(
             kCurrentGeneration,
             kCurrentGeneration,
             true,
             false) &&
         !CanRunScheduledMessagePump(
             kCurrentGeneration - 1,
             kCurrentGeneration,
             true,
             false) &&
         !CanRunScheduledMessagePump(
             kCurrentGeneration,
             kCurrentGeneration,
             false,
             false) &&
         !CanRunScheduledMessagePump(
             kCurrentGeneration,
             kCurrentGeneration,
             true,
             true);
}

extern "C" uint64_t TatwoCEFMessagePumpImmediateInterleavingProbe(void) {
  MessagePumpFollowUpGate gate;
  uint64_t do_work_count = 0;
  uint64_t vendor_schedule_count = 0;

  // Model the live failure ordering: a host kick occurs on the main thread,
  // then a vendor callback requests a newer generation before a queued host
  // block could run. The immediate delivery must already have reached do-work;
  // the vendor request remains a separate scheduled operation.
  DeliverImmediateMessagePumpWork(
      true,
      [&] {
        const MessagePumpRunResult result =
            RunMessagePumpWorkOnMainThread(
                gate, [&] { ++do_work_count; });
        if (result.should_schedule_follow_up) {
          ++vendor_schedule_count;
        }
      },
      [&] { ++vendor_schedule_count; });
  ++vendor_schedule_count;

  return (do_work_count << 32) | vendor_schedule_count;
}

extern "C" uint64_t TatwoCEFMessagePumpQueuedHostKickProbe(void) {
  MessagePumpFollowUpGate work_gate;
  MessagePumpHostKickQueueGate host_queue_gate;
  uint64_t do_work_count = 0;
  uint64_t host_queue_count = 0;
  uint64_t vendor_schedule_count = 0;
  std::function<void()> queued_host_kick;

  // Model a host kick that is not already executing on the main thread. The
  // queued host block must remain independent from the vendor generation so a
  // newer OnScheduleMessagePumpWork request cannot erase this first tick.
  DeliverImmediateMessagePumpWork(
      false,
      [&] {
        const MessagePumpRunResult result =
            RunMessagePumpWorkOnMainThread(
                work_gate, [&] { ++do_work_count; });
        if (result.should_schedule_follow_up) {
          ++vendor_schedule_count;
        }
      },
      [&] {
        QueueImmediateMessagePumpWork(
            host_queue_gate, [&] {
              ++host_queue_count;
              queued_host_kick = [&] {
                host_queue_gate.EndQueue();
                const MessagePumpRunResult result =
                    RunMessagePumpWorkOnMainThread(
                        work_gate, [&] { ++do_work_count; });
                if (result.should_schedule_follow_up) {
                  ++vendor_schedule_count;
                }
              };
            });
      });
  ++vendor_schedule_count;
  if (queued_host_kick) {
    queued_host_kick();
  }

  return (do_work_count << 32) |
         ((host_queue_count & 0xffff) << 16) |
         (vendor_schedule_count & 0xffff);
}

extern "C" uint64_t TatwoCEFMessagePumpFirstScheduleDeliveryProbe(void) {
  MessagePumpFollowUpGate gate;
  constexpr uint64_t kFirstGeneration = 1;
  uint64_t schedule_count = 1;
  uint64_t do_work_count = 0;

  if (CanRunScheduledMessagePump(
          kFirstGeneration,
          kFirstGeneration,
          true,
          false)) {
    const MessagePumpRunResult result =
        RunMessagePumpWorkOnMainThread(
            gate, [&] { ++do_work_count; });
    if (result.should_schedule_follow_up) {
      ++schedule_count;
    }
  }
  return (schedule_count << 32) | do_work_count;
}

extern "C" uint64_t TatwoCEFMessagePumpTwoImmediateSchedulesProbe(void) {
  MessagePumpFollowUpGate gate;
  constexpr uint64_t kFirstGeneration = 1;
  constexpr uint64_t kSecondGeneration = 2;
  uint64_t schedule_count = 2;
  uint64_t do_work_count = 0;

  // The first immediate request would be rejected by delayed-timer generation
  // cancellation after a second request arrives. Immediate delivery must use
  // only runtime liveness, so both queued requests remain independently valid.
  if (!CanRunScheduledMessagePump(
          kFirstGeneration,
          kSecondGeneration,
          true,
          false) &&
      CanRunImmediateMessagePump(true, false)) {
    const MessagePumpRunResult result =
        RunMessagePumpWorkOnMainThread(
            gate, [&] { ++do_work_count; });
    if (result.should_schedule_follow_up) {
      ++schedule_count;
    }
  }
  if (CanRunImmediateMessagePump(true, false)) {
    const MessagePumpRunResult result =
        RunMessagePumpWorkOnMainThread(
            gate, [&] { ++do_work_count; });
    if (result.should_schedule_follow_up) {
      ++schedule_count;
    }
  }
  return (schedule_count << 32) | do_work_count;
}

extern "C" uint64_t TatwoCEFMessagePumpLoadingActiveLifecycleProbe(void) {
  LoadingActiveMessagePumpGate gate;
  const uint64_t first_generation = gate.Start();
  uint64_t active_tick_count = 0;
  for (uint64_t index = 0; index < 3; ++index) {
    if (gate.CanTick(
            first_generation, true, false, true, false)) {
      gate.RecordTick();
      active_tick_count += 1;
    }
  }

  gate.Stop();
  const uint64_t idle_tick_count =
      gate.CanTick(first_generation, false, false, true, false) ? 1 : 0;

  const uint64_t second_generation = gate.Start();
  const uint64_t fresh_generation_tick_count =
      second_generation != first_generation &&
              gate.CanTick(second_generation, true, false, true, false)
          ? 1
          : 0;
  gate.Stop();
  const uint64_t terminal_tick_count =
      (gate.CanTick(second_generation, true, true, true, false) ? 1 : 0) +
      (gate.CanTick(second_generation, true, false, true, true) ? 1 : 0);

  return ((active_tick_count & 0xffff) << 48) |
         ((idle_tick_count & 0xffff) << 32) |
         ((fresh_generation_tick_count & 0xffff) << 16) |
         (terminal_tick_count & 0xffff);
}

@interface TatwoCEFBrowserView ()
@property(atomic, readwrite) BOOL agentControlled;
@property(atomic, readwrite) BOOL humanPreferencesDeferred;
@end

@implementation TatwoCEFBrowserView
@synthesize browserActor = _browserActor;
@synthesize agentControlled = _agentControlled;
#pragma mark - W57c Native assist setting and fill
@synthesize passwordAssistEnabled = _passwordAssistEnabled;
- (void)setPasswordAssistEnabled:(BOOL)enabled {
  if (!NSThread.isMainThread || _passwordAssistEnabled == enabled) return;
  _passwordAssistEnabled = enabled;
  W57cInvalidate(self, false, false);
  BrowserState *state = State(self);
  if (enabled && state && state->browser && !state->is_loading && state->http_status_code > 0)
    W57cLoadEnd(self, state->browser->GetMainFrame(), (int)state->http_status_code);
}

- (void)fillCredentialUsername:(NSString *)u password:(NSString *)p formID:(NSString *)f navigationGeneration:(uint64_t)g {
  BrowserState *state = State(self);
  if (!W57cHumanPage(self, state) || self.browserActor != TatwoCEFBrowserActorHuman ||
      self.agentControlled || state->navigation_in_flight || g == 0 ||
      state->navigation_generation != g || !state->password_assist_token.length ||
      state->password_assist_scan_pending || !p.length || !f.length ||
      [u lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4096 ||
      [p lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384 || f.length > 128) return;
  auto frame = state->browser->GetMainFrame();
  NSString *origin = OriginForURLString(state->committed_url);
  if (!frame || !frame->IsValid() || ![origin hasPrefix:@"https://"] ||
      ![origin isEqualToString:OriginForURLString(FromCefString(frame->GetURL()))]) return;
  auto message = CefProcessMessage::Create(kPasswordFillMessage);
  auto args = message->GetArgumentList();
  args->SetString(0, std::to_string(g));
  args->SetString(1, ToCefString(state->password_assist_token));
  args->SetString(2, ToCefString(origin));
  args->SetString(3, frame->GetURL());
  args->SetString(4, ToCefString(f));
  args->SetString(5, ToCefString(u));
  args->SetString(6, ToCefString(p));
  frame->SendProcessMessage(PID_RENDERER, message);
  // No payload in source strings or logs; the host kick's reason is constant.
  ScheduleImmediateCEFMessagePumpWork(@"password_assist");
}
#pragma mark - W57c End
#pragma mark - W58 Native-only AI login API
- (BOOL)prepareAgentLogin {
  W58Invalidate(self, false);
  return W58Scan(self, false);
}
- (void)cancelAgentLogin { W58Invalidate(self, false); }
- (NSDictionary *)agentLoginState {
  auto state = State(self);
  if (!W58AgentPage(self, state)) return @{@"phase": @"failed", @"error": @"ai_login_human_tab_denied"};
  // Strip query/fragment and URL credentials; no page forms or values are exported.
  NSURLComponents *url = [NSURLComponents componentsWithString:self.currentURLString ?: @""];
  url.query = nil; url.fragment = nil; url.user = nil; url.password = nil;
  return @{@"phase": state->ai_login_phase ?: @"idle", @"formID": state->ai_login_form ?: @"",
    @"generation": @(state->navigation_generation), @"error": state->ai_login_error ?: @"",
    @"finalURL": url.string ?: @"", @"title": state->ai_login_title ?: @""};
}
- (BOOL)fillCredentialForAgentUsername:(NSString *)u password:(NSString *)p formID:(NSString *)f navigationGeneration:(uint64_t)g {
  auto state = State(self);
  if (!W58AgentPage(self, state) || self.browserActor != TatwoCEFBrowserActorAgent ||
      state->navigation_in_flight || g == 0 || state->navigation_generation != g ||
      ![state->ai_login_phase isEqualToString:@"ready"] || !state->ai_login_form.length ||
      ![state->ai_login_form isEqualToString:f] || !state->ai_login_token.length || !p.length ||
      [u lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4096 ||
      [p lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384) return NO;
  auto frame = state->browser->GetMainFrame();
  NSString *origin = OriginForURLString(state->committed_url);
  if (!frame || !frame->IsValid() || ![origin hasPrefix:@"https://"] ||
      ![origin isEqualToString:OriginForURLString(FromCefString(frame->GetURL()))]) return NO;
  auto message = CefProcessMessage::Create(kAILoginFill);
  auto args = message->GetArgumentList();
  args->SetString(0, std::to_string(g)); args->SetString(1, ToCefString(state->ai_login_token));
  args->SetString(2, ToCefString(origin)); args->SetString(3, frame->GetURL());
  args->SetString(4, ToCefString(f)); args->SetString(5, ToCefString(u)); args->SetString(6, ToCefString(p));
  state->ai_login_form = nil; state->ai_login_phase = @"submitted"; state->ai_login_awaiting_load = true;
  frame->SendProcessMessage(PID_RENDERER, message);
  ScheduleImmediateCEFMessagePumpWork(@"ai_login");
  return YES;
}
#pragma mark - W58 End
- (void)beginAgentInteraction {
  if (!NSThread.isMainThread || self.agentControlled) return;
  self.agentControlled = YES;
#pragma mark - W57d
  W57dInvalidate(self);
#pragma mark - W57d End
#pragma mark - W57c Agent takeover invalidates queued Island replies and renderer listeners
  W57cInvalidate(self, false, false);
#pragma mark - W57c End
  self.humanPreferencesDeferred = NO;
  BrowserState *state = State(self);
  if (state) {
    state->client->InvalidateResourceErrors();
    if (state->request_context_security_ready &&
        !ApplyPrivacyStrictRequestContextPreferences(state->request_context, TatwoCEFBrowserActorAgent)) {
      state->request_context_security_blocked = true;
      [self closeBrowser]; // Never dispatch agent input with human-only credentials prefs.
    }
  }
}


- (BOOL)restoreHumanInteraction {
  if (!NSThread.isMainThread || (!self.agentControlled && !self.humanPreferencesDeferred) ||
      self.browserActor != TatwoCEFBrowserActorHuman) return NO;
  BrowserState *state = State(self);
  if (!state || state->close_requested || !state->request_context_security_ready ||
      state->request_context_security_blocked) return NO;
  // Preferences belong to the context: never enable credentials for an agent sibling.
  bool agent_sibling = false;
  for (TatwoCEFBrowserView *other in g_live_browser_views.allObjects) {
    BrowserState *sibling = State(other);
    if (other != self && sibling && !sibling->close_completed && sibling->request_context &&
        sibling->request_context->IsSame(state->request_context) &&
        (other.agentControlled || other.browserActor == TatwoCEFBrowserActorAgent)) {
      agent_sibling = true;
      break;
    }
  }
  if (!self.agentControlled && agent_sibling) return NO; // Wait without per-keystroke telemetry.
  // App bridge has waited for agent methods to finish and the quiet period.
  // Complete pending callbacks under the strict actor before changing prefs.
  if (state->client) {
    state->client->CancelPendingBrowserOperations();
    state->client->CancelPendingWebMCPInvocations(@"human_takeover");
    state->client->InvalidateResourceErrors();
  }
  // Existing resource handlers retain their strict snapshot; subsequent requests
  // obtain a new ActorRequestPolicy snapshot. Never promote an in-flight handler.
  self.agentControlled = NO;
  if (!agent_sibling && !ApplyPrivacyStrictRequestContextPreferences(state->request_context, TatwoCEFBrowserActorHuman)) {
    self.agentControlled = YES; // fail closed while native close drains
    state->request_context_security_blocked = true;
    [self closeBrowser];
    return NO;
  }
  self.humanPreferencesDeferred = agent_sibling;
  AppendCEFEmbeddingTelemetryLine([NSString stringWithFormat:
      @"phase=actor_recovery actor=human prefs=%@", agent_sibling ? @"strict_shared_context" : @"human"]);
  return YES;
}


- (nullable instancetype)initForPopupWithFrame:(NSRect)frame
                                        opener:(TatwoCEFBrowserView *)opener
                                       popupID:(int)popupID {
  self = [super initWithFrame:frame];
  BrowserState *parent = State(opener);
  if (!self || !parent || !parent->request_context ||
      !parent->request_context_security_ready || parent->close_requested) return nil;
  // W45-fix: a popup inherits its opener's actor and resource policy; without this the
  // snapshot read adBlock/cookie defaults (NO) and skipped the host deny list.
  _browserActor = opener.browserActor;
  _blocksThirdPartyCookies = opener.blocksThirdPartyCookies;
  _adBlock = opener.adBlock;
  BrowserState *state = CreateBrowserState(self);
  state->request_context = parent->request_context;
  state->request_context_security_ready = true;
  state->creation_attempted = true;
  state->creation_pending = true;
  state->opener = opener;
  state->popup_id = popupID;
  return self;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  BrowserState *state = State(self);
  if (!state || state->popup_window != sender) return YES;
  [self closeBrowser];
  return NO;
}

- (void)windowWillClose:(NSNotification *)notification {
  BrowserState *state = State(self);
  if (state && state->popup_window == notification.object) [self closeBrowser];
}

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
  self = [super initWithFrame:frame];
  if (self == nil) {
    return nil;
  }
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load()) {
    if (error != nullptr) {
      *error = MakeError(20, @"Chromium runtime unavailable");
    }
    return nil;
  }
  _browserActor = actor;
  _blocksThirdPartyCookies = YES;
  _adBlock = YES;
  BrowserRequestPolicySnapshot initial_policy = ActorRequestPolicy(self);
  const bool initial_local_deny =
      IsDeniedByLocalHostList(initial_policy, initialURL);
  // Only the exact inert constructor URL is allowed here. Do not relax the
  // public navigation/resource URL policy for about:, data:, file:, or variants.
  const bool initial_blank = [initialURL isEqualToString:@"about:blank"];
  if (!initial_blank && (URLHasCredentials(initialURL) ||
      !IsActorURLAllowed(initial_policy, initialURL) ||
      initial_local_deny)) {
    if (error != nullptr) {
      *error = MakeError(
          21,
          ResourceBlockMessage(initial_policy, initialURL));
    }
    return nil;
  }

  BrowserState *state = CreateBrowserState(self);
  state->pending_url = [initialURL copy];
  state->phase = TatwoCEFBrowserPhaseCreating;
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=mount_generation event=activated "
           "activeGeneration=%llu staleCallbackDrops=%llu",
          state->mount_generation,
          g_stale_callback_drop_count.load(std::memory_order_relaxed)]);

  CefRequestContextSettings context_settings;
  if (persistentProfile.length > 0) {
    CefString(&context_settings.cache_path) =
        ToCefString(persistentProfile);
    context_settings.persist_session_cookies = true;
  }
  __weak TatwoCEFBrowserView *weak_self = self;
  const uint64_t mount_generation = state->mount_generation;
  state->request_context_handler =
      new TatwoPrivacyStrictRequestContextHandler(
          [weak_self, mount_generation](
              CefRefPtr<CefRequestContext> request_context,
              bool configured) {
            TatwoCEFBrowserView *owner = weak_self;
            if (!IsActiveMountCallback(
                    owner,
                    mount_generation,
                    @"request_context_initialized")) {
              return;
            }
            BrowserState *active_state = State(owner);
            active_state->request_context_handler = nullptr;
            if (!active_state->request_context ||
                !active_state->request_context->IsSame(
                    request_context)) {
              active_state->request_context_security_blocked = true;
              AppendCEFEmbeddingTelemetryLine(
                  [NSString stringWithFormat:
                      @"phase=security_capability "
                       "event=preference_failed policyVersion=%u "
                       "preference=request_context "
                       "reason=context_mismatch",
                      kBrowserNetworkSecurityPolicyVersion]);
              PublishVisibleError(
                  owner,
                  kPrivacyStrictStartupError,
                  TatwoCEFBrowserErrorKindSecurity,
                  23,
                  TatwoCEFBrowserPhaseBlockedBySecurity);
              return;
            }
            // An agent can be queued while the human context is initializing.
            // Reapply the stricter policy before publishing readiness.
            if (owner.agentControlled && configured) {
              configured = ApplyPrivacyStrictRequestContextPreferences(request_context, TatwoCEFBrowserActorAgent);
            }
            if (!configured) {
              active_state->request_context_security_blocked = true;
              PublishVisibleError(
                  owner,
                  kPrivacyStrictStartupError,
                  TatwoCEFBrowserErrorKindSecurity,
                  23,
                  TatwoCEFBrowserPhaseBlockedBySecurity);
              return;
            }
            active_state->request_context_security_ready = true;
            active_state->request_context_security_blocked = false;
            [owner startBrowserIfReady];
            PublishState(owner);
          }, actor);
  state->request_context =
      CefRequestContext::CreateContext(
          context_settings,
          state->request_context_handler);
  if (!state->request_context) {
    state->client->DetachOwner();
    state->request_context_handler->Cancel();
    state->request_context_handler = nullptr;
    delete state;
    _cefState = nullptr;
    if (error != nullptr) {
      *error = MakeError(22, @"Chromium request context creation failed");
    }
    return nil;
  }
  // Creating a request context is a host action too: bootstrap its asynchronous
  // readiness callback even when the vendor message pump was already idle.
  StartLoadingActiveMessagePump(self, state->mount_generation, @"request_context_create");
  PublishCreationTimeoutIfPending(self, true);
  ScheduleImmediateCEFMessagePumpWork(@"request_context_create");

  return self;
}

- (BOOL)canShareRequestContext {
  BrowserState *state = State(self);
  return state && state->request_context &&
      state->request_context_security_ready &&
      !state->request_context_security_blocked && !state->close_requested;
}

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
  self = [super initWithFrame:frame];
  if (!self) return nil;
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load() || !source.canShareRequestContext ||
      source.browserActor != actor || (source.agentControlled && actor == TatwoCEFBrowserActorHuman)) {
    if (error) *error = MakeError(20, @"Chromium request context unavailable");
    return nil;
  }
  _browserActor = actor;
  _blocksThirdPartyCookies = YES;
  _adBlock = YES;
  BrowserRequestPolicySnapshot initial_policy = ActorRequestPolicy(self);
  const bool initial_local_deny =
      IsDeniedByLocalHostList(initial_policy, initialURL);
  const bool initial_blank = [initialURL isEqualToString:@"about:blank"];
  if (!initial_blank && (URLHasCredentials(initialURL) ||
      !IsActorURLAllowed(initial_policy, initialURL) || initial_local_deny)) {
    if (error) *error = MakeError(
        21, ResourceBlockMessage(initial_policy, initialURL));
    return nil;
  }
  BrowserState *state = CreateBrowserState(self);
  state->pending_url = [initialURL copy];
  state->phase = TatwoCEFBrowserPhaseCreating;
  // New normal browser: never inherit popup creation flags or an opener.
  // CefRefPtr keeps the context alive when the original tab is closed.
  state->request_context = State(source)->request_context;
  state->request_context_security_ready = true;
  StartLoadingActiveMessagePump(self, state->mount_generation, @"tab_create");
  PublishCreationTimeoutIfPending(self, true);
  ScheduleImmediateCEFMessagePumpWork(@"tab_create");
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self closeBrowser];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  NSNotificationCenter *notifications =
      [NSNotificationCenter defaultCenter];
  [notifications removeObserver:self
                           name:NSWindowDidMoveNotification
                         object:nil];
  [notifications removeObserver:self
                           name:NSWindowDidResizeNotification
                         object:nil];
  [notifications removeObserver:self
                           name:NSWindowDidChangeScreenNotification
                         object:nil];
  [notifications removeObserver:self
                           name:NSWindowDidChangeBackingPropertiesNotification
                         object:nil];
  if (self.window != nil) {
    for (NSNotificationName name in @[
           NSWindowDidMoveNotification,
           NSWindowDidResizeNotification,
           NSWindowDidChangeScreenNotification,
           NSWindowDidChangeBackingPropertiesNotification,
         ]) {
      [notifications addObserver:self
                        selector:@selector(hostWindowGeometryDidChange:)
                            name:name
                          object:self.window];
    }
  }
  LogBrowserEmbeddingSnapshot(
      self,
      State(self) == nullptr ? nullptr : State(self)->browser,
      @"view_did_move_to_window",
      true);
  [self startBrowserIfReady];
  BrowserState *state = State(self);
  if (state != nullptr && state->browser) {
    SynchronizeBrowserGeometry(self, state->browser);
  }
}

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  LogBrowserEmbeddingSnapshot(
      self,
      State(self) == nullptr ? nullptr : State(self)->browser,
      @"view_did_move_to_superview",
      true);
  [self startBrowserIfReady];
  PublishState(self);
}

- (void)hostWindowGeometryDidChange:(NSNotification *)notification {
  BrowserState *state = State(self);
  if (state == nullptr || !state->browser || state->close_requested) {
    return;
  }
  SynchronizeBrowserGeometry(self, state->browser);
}

- (void)startBrowserIfReady {
  NSAssert(NSThread.isMainThread,
           @"CEF browser creation must start on the main thread");
  BrowserState *state = State(self);
  if (!state || !state->request_context_security_ready ||
      state->request_context_security_blocked ||
      g_shutdown_requested.load() ||
      state->close_requested || state->creation_attempted ||
      state->browser || self.window == nil || self.bounds.size.width < 1 ||
      self.bounds.size.height < 1) {
    return;
  }
  if (state->pending_navigation_gate != nil &&
      (!self.window.isVisible || self.window.isMiniaturized ||
       self.isHiddenOrHasHiddenAncestor)) return;

  // CEF layer-backs the root content view when it creates the NSWindow itself,
  // but an embedded browser supplies parent_view and skips that branch. The
  // direct client-provided parent is the compositor attachment boundary, so
  // layer-back this TatwoCEFBrowserView itself before SetAsChild. Backing only
  // an ancestor leaves the native CefBrowserHostView attached below a
  // non-layer-owning direct parent and can consume its first display before the
  // layer hierarchy reaches the child.
  NSView *content_view = self.window.contentView;
  [content_view setWantsLayer:YES];
  [self setWantsLayer:YES];
  self.layer.backgroundColor =
      TatwoCEFOpaquePanelBackgroundNSColor().CGColor;
  LogBrowserEmbeddingSnapshot(self, nullptr, @"before_create", true);
  state->creation_attempted = true;
  state->creation_pending = true;
  NSString *creation_url = [state->pending_url copy];
  TatwoCEFBrowserInputDispatchGate creation_gate =
      [state->pending_navigation_gate copy];
  state->pending_url = nil;
  state->pending_navigation_gate = nil;

  CefWindowInfo window_info;
  const int width =
      std::max(1, static_cast<int>(self.bounds.size.width));
  const int height =
      std::max(1, static_cast<int>(self.bounds.size.height));
  window_info.SetAsChild((__bridge CefWindowHandle)self,
                         CefRect(0, 0, width, height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;
  browser_settings.javascript_close_windows = STATE_DISABLED;
  browser_settings.javascript_access_clipboard = STATE_DISABLED;
  browser_settings.javascript_dom_paste = STATE_DISABLED;
  browser_settings.background_color = kBrowserDocumentBackgroundColor;

  // CEF requires windowed browser creation to be initiated on its
  // browser-process UI thread, which is this AppKit main thread in the external
  // message-pump integration. Use the asynchronous factory so startBrowserIfReady
  // returns without blocking the UI while CEF creates the native child.
  //
  // A creation-pending view remains closeable: closeBrowserWithCompletion keeps
  // the view/client alive in g_closing_views, and OnAfterCreated immediately
  // closes the returned browser when close_requested is already set. The
  // persistent profile lease is therefore released only by the normal
  // OnBeforeClose completion, preserving one live mount per profile without a
  // synchronous create, nested run loop, busy wait, or semaphore.
  if (creation_url.length > 0) {
    BeginNavigationFrameTelemetry(
        self, state, @"browser_creation_navigation");
  }
  __block bool create_accepted = false;
  DispatchBrowserNavigation(self, creation_gate, ^{
    create_accepted = CefBrowserHost::CreateBrowser(
        window_info, state->client, ToCefString(creation_url),
        browser_settings, nullptr, state->request_context);
  });
  // The factory's result is authoritative. A gate's return cannot undo an
  // already accepted creation, including an eventual OnAfterCreated callback.
  if (!create_accepted) {
    state->creation_pending = false;
    LogBrowserLifecycle(@"create_rejected");
    PublishVisibleError(self,
                        @"Chromium 瀏覽器建立失敗，請重試",
                        TatwoCEFBrowserErrorKindStartup,
                        ERR_FAILED,
                        TatwoCEFBrowserPhaseStartupFailed);
    return;
  }
  LogBrowserLifecycle(@"create_accepted");
  LogBrowserTimeline(
      @"browser_create_accepted",
      state->mount_generation,
      0,
      true);
  LogBrowserEmbeddingSnapshot(self, nullptr, @"create_accepted", true);
  StartLoadingActiveMessagePump(self, state->mount_generation, @"browser_create_accepted");
  ScheduleImmediateCEFMessagePumpWork(@"browser_create_accepted");
  PublishCreationTimeoutIfPending(self);
}

- (void)layout {
  [super layout];
  [self startBrowserIfReady];
  BrowserState *state = State(self);
  if (!state || !state->browser) {
    return;
  }
  SynchronizeBrowserGeometry(self, state->browser);
  LogBrowserEmbeddingSnapshot(self, state->browser, @"layout", false);
}

- (BOOL)canGoBack {
  BrowserState *state = State(self);
  return state && state->browser ? state->browser->CanGoBack() : NO;
}

- (BOOL)canGoForward {
  BrowserState *state = State(self);
  return state && state->browser ? state->browser->CanGoForward() : NO;
}

- (nullable NSString *)currentURLString {
  BrowserState *state = State(self);
  return state == nullptr ? nil : state->committed_url;
}

- (uint64_t)navigationGeneration {
  BrowserState *state = State(self);
  return state ? state->navigation_generation : 0;
}

- (void)captureVisibleSnapshotWithCompletion:
    (TatwoCEFBrowserSnapshotHandler)completion {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self captureVisibleSnapshotWithCompletion:completion];
    });
    return;
  }
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load()) {
    completion(nil, @"snapshot_unavailable");
    return;
  }
  TatwoCEFBrowserView *view = self;
  BrowserState *state = State(view);
  if (view == nil || view.window == nil || state == nullptr ||
      state->browser == nullptr || state->client == nullptr ||
      state->close_requested || state->committed_url.length == 0 ||
      state->navigation_generation == 0 ||
      (state->phase != TatwoCEFBrowserPhaseCommitted &&
       state->phase != TatwoCEFBrowserPhaseFinished)) {
    completion(nil, @"snapshot_unavailable");
    return;
  }
  NSString *main_frame_url =
      FromCefString(state->browser->GetMainFrame()->GetURL());
  if (![SnapshotOrigin(main_frame_url)
          isEqualToString:SnapshotOrigin(state->committed_url)]) {
    completion(nil, @"navigation_binding_unavailable");
    return;
  }
  state->client->CaptureVisibleSnapshot(
      state->browser,
      state->committed_url,
      state->navigation_generation,
      view.bounds.size,
      completion);
}


- (BOOL)sendClickAtPoint:(NSPoint)point navigationGeneration:(uint64_t)generation {
  if (!BrowserInputIsCurrent(self, generation) || !std::isfinite(point.x) ||
      !std::isfinite(point.y) || point.x < 0 || point.y < 0 ||
      point.x != std::floor(point.x) || point.y != std::floor(point.y) ||
      point.x > std::numeric_limits<int>::max() ||
      point.y > std::numeric_limits<int>::max() ||
      point.x >= self.bounds.size.width || point.y >= self.bounds.size.height) return NO;
  // The host already selected a representable point inside the observed target.
  // Never silently truncate a different fractional point at this final boundary.
  auto host = State(self)->browser->GetHost();
  CefMouseEvent event;
  event.x = static_cast<int>(point.x);
  event.y = static_cast<int>(point.y);
  host->SendMouseClickEvent(event, MBT_LEFT, false, 1);
  host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
  ScheduleImmediateCEFMessagePumpWork(@"browser_click");
  return YES;
}

- (void)clickElement:(NSString *)elementID atPoint:(NSPoint)point
       expectedRect:(NSRect)rect viewportSize:(NSSize)viewport
       navigationGeneration:(uint64_t)generation
       dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
       completion:(TatwoCEFBrowserInputHandler)completion {
  if (!BrowserInputIsCurrent(self, generation) || dispatchGate == nil ||
      ![elementID hasPrefix:@"cef-"]) {
    completion(NO, @"browser_click_target_unavailable"); return;
  }
  NSString *number = [elementID substringFromIndex:4];
  const long long backend_id = number.longLongValue;
  if (number.length == 0 || number.length > 10 || backend_id <= 0 ||
      backend_id > std::numeric_limits<int>::max() ||
      ![elementID isEqualToString:[NSString stringWithFormat:@"cef-%lld", backend_id]]) {
    completion(NO, @"browser_click_target_unavailable"); return;
  }
  BrowserState *state = State(self);
  if (!state->client) { completion(NO, @"browser_unavailable"); return; }
  state->client->ClickElement(state->browser, static_cast<int>(backend_id),
      point, rect, viewport, generation, dispatchGate, completion);
}

- (BOOL)sendAgentPointer:(NSPoint)point phase:(int)phase navigationGeneration:(uint64_t)generation {
  if (!BrowserInputIsCurrent(self, generation) || phase < 0 || phase > 2 ||
      !std::isfinite(point.x) || !std::isfinite(point.y) || point.x < 0 || point.y < 0 ||
      point.x >= self.bounds.size.width || point.y >= self.bounds.size.height ||
      point.x > std::numeric_limits<int>::max() || point.y > std::numeric_limits<int>::max()) return NO;
  BrowserState *state = State(self);
  auto host = state->browser->GetHost();
  if (host->GetZoomLevel() != 0) return NO;
  if ((phase == 0 && state->agent_pointer_host) ||
      (phase != 0 && (!state->agent_pointer_host || state->agent_pointer_host != host))) return NO;
  CefMouseEvent event;
  event.x = static_cast<int>(point.x);
  event.y = static_cast<int>(point.y);
  event.modifiers = phase == 2 ? 0 : EVENTFLAG_LEFT_MOUSE_BUTTON;
  state->agent_pointer_event = event;
  if (phase == 0) {
    state->agent_pointer_host = host;
    host->SendMouseClickEvent(event, MBT_LEFT, false, 1);
  } else if (phase == 1) host->SendMouseMoveEvent(event, false);
  else {
    host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
    state->agent_pointer_host = nullptr;
  }
  ScheduleImmediateCEFMessagePumpWork(@"browser_pointer");
  return YES;
}

- (void)releaseAgentPointer {
  if (!NSThread.isMainThread) return;
  BrowserState *state = State(self);
  if (!state || !state->agent_pointer_host) return;
  auto host = state->agent_pointer_host;
  state->agent_pointer_host = nullptr;
  auto event = state->agent_pointer_event;
  event.modifiers = 0;
  host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
  ScheduleImmediateCEFMessagePumpWork(@"browser_pointer_release");
}

- (BOOL)sendAgentKey:(unsigned short)code windowsCode:(int)windowsCode
         characters:(NSString *)characters unmodified:(NSString *)unmodified
          modifiers:(NSUInteger)modifiers phase:(int)phase navigationGeneration:(uint64_t)generation {
  if (!BrowserInputIsCurrent(self, generation) || phase < 0 || phase > 2 ||
      characters.length != 1 || unmodified.length != 1 ||
      (modifiers & NSEventModifierFlagFunction)) return NO;
  BrowserState *state = State(self);
  auto host = state->browser->GetHost();
  if ((phase == 0 && state->agent_key_host) ||
      (phase != 0 && (!state->agent_key_host || state->agent_key_host != host))) return NO;
  CefKeyEvent event;
  event.type = phase == 0 ? KEYEVENT_RAWKEYDOWN : phase == 1 ? KEYEVENT_CHAR : KEYEVENT_KEYUP;
  event.native_key_code = code;
  event.windows_key_code = windowsCode;
  event.character = [characters characterAtIndex:0];
  event.unmodified_character = [unmodified characterAtIndex:0];
  event.modifiers = 0;
  if (modifiers & NSEventModifierFlagCommand) event.modifiers |= EVENTFLAG_COMMAND_DOWN;
  if (modifiers & NSEventModifierFlagShift) event.modifiers |= EVENTFLAG_SHIFT_DOWN;
  if (modifiers & NSEventModifierFlagOption) event.modifiers |= EVENTFLAG_ALT_DOWN;
  if (modifiers & NSEventModifierFlagControl) event.modifiers |= EVENTFLAG_CONTROL_DOWN;
  if (phase == 0) { state->agent_key_host = host; state->agent_key_event = event; }
  // Navigation/function keys and shortcuts do not insert their character.
  if (phase != 1 || (!(modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
                     event.character < 0xF700 && windowsCode != 8 && windowsCode != 27))
    host->SendKeyEvent(event);
  if (phase == 2) state->agent_key_host = nullptr;
  ScheduleImmediateCEFMessagePumpWork(@"browser_key");
  return YES;
}

- (void)releaseAgentKey {
  if (!NSThread.isMainThread) return;
  BrowserState *state = State(self);
  if (!state || !state->agent_key_host) return;
  auto host = state->agent_key_host;
  state->agent_key_host = nullptr;
  auto event = state->agent_key_event;
  event.type = KEYEVENT_KEYUP;
  host->SendKeyEvent(event);
  ScheduleImmediateCEFMessagePumpWork(@"browser_key_release");
}

- (void)checkAgentFocusWithNavigationGeneration:(uint64_t)generation
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate completion:(TatwoCEFBrowserInputHandler)completion {
  if (!BrowserInputIsCurrent(self, generation) || !State(self)->client || !dispatchGate) {
    completion(NO, @"browser_focus_unavailable"); return;
  }
  State(self)->client->CheckAgentFocus(State(self)->browser, generation, dispatchGate, completion);
}

- (void)selectValue:(NSString *)value elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion {
  if (!BrowserInputIsCurrent(self, generation) || !State(self)->client || !dispatchGate ||
      ![elementID hasPrefix:@"cef-"]) { completion(NO, @"browser_select_unavailable"); return; }
  const long long node = [[elementID substringFromIndex:4] longLongValue];
  if (node <= 0 || node > std::numeric_limits<int>::max() ||
      ![elementID isEqualToString:[NSString stringWithFormat:@"cef-%lld", node]]) {
    completion(NO, @"browser_select_unavailable"); return;
  }
  State(self)->client->SelectValue(State(self)->browser, static_cast<int>(node), value, generation, dispatchGate, completion);
}

- (BOOL)sendScrollDeltaY:(int)deltaY navigationGeneration:(uint64_t)generation {
  if (!BrowserInputIsCurrent(self, generation) || deltaY == std::numeric_limits<int>::min()) return NO;
  // Pinned CEF 151's macOS SendMouseWheelEvent routes through the mouse-event
  // path, slicing off wheel deltas. Use Chromium's native input command on this
  // exact browser instead; no JS, global event posting, or focus change.
  auto params = CefDictionaryValue::Create();
  params->SetString("type", "mouseWheel");
  params->SetDouble("x", self.bounds.size.width / 2);
  params->SetDouble("y", self.bounds.size.height / 2);
  params->SetDouble("deltaX", 0);
  params->SetDouble("deltaY", deltaY);
  const int request = State(self)->browser->GetHost()->ExecuteDevToolsMethod(
      0, "Input.dispatchMouseEvent", params);
  if (request == 0) return NO;
  ScheduleImmediateCEFMessagePumpWork(@"browser_scroll");
  return YES;
}

- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    completion:(TatwoCEFBrowserInputHandler)completion {
  // Preserve non-agent host callers. Agent requests must use the explicit
  // dispatchGate overload so later native stages cannot outlive their grant.
  [self typeText:text elementID:elementID navigationGeneration:generation
          submit:submit dispatchGate:^BOOL(dispatch_block_t dispatch) {
            dispatch();
            return YES;
          } completion:completion];
}

- (void)typeText:(NSString *)text elementID:(NSString *)elementID
    navigationGeneration:(uint64_t)generation submit:(BOOL)submit
    dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate
    completion:(TatwoCEFBrowserInputHandler)completion {
  if (!BrowserInputIsCurrent(self, generation) || ![elementID hasPrefix:@"cef-"]) {
    completion(NO, @"browser_field_target_unavailable"); return;
  }
  NSString *number = [elementID substringFromIndex:4];
  NSCharacterSet *not_digit = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
  const long long backend_id = number.longLongValue;
  if (number.length == 0 || number.length > 10 || backend_id <= 0 ||
      backend_id > std::numeric_limits<int>::max() ||
      [number rangeOfCharacterFromSet:not_digit].location != NSNotFound) {
    completion(NO, @"browser_field_target_unavailable"); return;
  }
  BrowserState *state = State(self);
  if (!state->client) { completion(NO, @"browser_unavailable"); return; }
  state->client->TypeText(state->browser, static_cast<int>(backend_id), text,
                          generation, submit, dispatchGate, completion);
}

- (void)loadURLString:(NSString *)urlString {
  [self queueOrDispatchURLString:urlString pendingDispatchGate:nil];
}

- (void)loadURLString:(NSString *)urlString
        dispatchGate:(TatwoCEFBrowserInputDispatchGate)dispatchGate {
  if (dispatchGate == nil) return;
  [self queueOrDispatchURLString:urlString pendingDispatchGate:dispatchGate];
}

- (void)queueOrDispatchURLString:(NSString *)urlString
 pendingDispatchGate:(nullable TatwoCEFBrowserInputDispatchGate)dispatchGate {
  if (!NSThread.isMainThread) return;
  BrowserState *state = State(self);
  if (!state || state->close_requested ||
      g_shutdown_requested.load()) {
    return;
  }
  if (state->request_context_security_blocked) {
    PublishState(self);
    return;
  }
  if (dispatchGate) [self beginAgentInteraction];
  BrowserRequestPolicySnapshot policy = ActorRequestPolicy(self);
  const bool local_deny =
      IsDeniedByLocalHostList(policy, urlString);
  // W56-fix: the exact inert about:blank is allowed on the load path too (new tabs are
  // created with it); anything else still goes through the actor/network policy.
  const bool inert_blank = [urlString isEqualToString:@"about:blank"];
  if (!inert_blank &&
      (URLHasCredentials(urlString) ||
       !IsActorURLAllowed(policy, urlString) ||
       local_deny)) {
    LogBrowserNavigationTrace(
        @"host_navigation_blocked", ERR_BLOCKED_BY_CLIENT, false);
    PublishVisibleError(self,
                        ResourceBlockMessage(policy, urlString),
                        TatwoCEFBrowserErrorKindSecurity,
                        ERR_BLOCKED_BY_CLIENT,
                        TatwoCEFBrowserPhaseBlockedBySecurity);
    return;
  }
  LogBrowserNavigationTrace(@"host_navigation_requested", 0, true);
  if (!state->browser) {
    if (!state->creation_attempted || state->creation_pending) {
      state->pending_error = nil;
      state->phase = TatwoCEFBrowserPhaseCreating;
      state->error_kind = TatwoCEFBrowserErrorKindNone;
      state->error_code = 0;
      state->pending_url = [urlString copy];
      // Replacement is atomic on the main thread: never reuse a prior URL's
      // gate, or leave a prior gate attached to a later manual navigation.
      state->pending_navigation_gate = [dispatchGate copy];
      [self startBrowserIfReady];
    }
    return;
  }
  state->pending_error = nil;
  state->phase = TatwoCEFBrowserPhaseLoading;
  state->is_loading = true;
  state->http_status_code = 0;
  state->error_kind = TatwoCEFBrowserErrorKindNone;
  state->error_code = 0;
  BeginNavigationFrameTelemetry(self, state, @"navigation");
  StartLoadingActiveMessagePump(
      self, state->mount_generation, @"navigation");
  CefRefPtr<CefBrowser> browser = state->browser;
  const BOOL dispatched = DispatchBrowserNavigation(self, dispatchGate, ^{
    browser->GetMainFrame()->LoadURL(ToCefString(urlString));
  });
  if (!dispatched) {
    PublishVisibleError(self, @"瀏覽器操作已撤回，請重新觀察後再試。",
                        TatwoCEFBrowserErrorKindNavigation, ERR_ABORTED,
                        TatwoCEFBrowserPhaseNavigationFailed);
  }
  ScheduleImmediateCEFMessagePumpWork(@"navigation");
}

#pragma mark - W57a
- (void)stopLoading {
  auto *state = State(self);
  if (ActorRequestPolicy(self).human && state && state->browser) state->browser->StopLoad();
}
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase {
  auto *state = State(self);
  if (!ActorRequestPolicy(self).human || !state || !state->browser) return;
  if (!text.length) { [self stopFinding]; return; }
  const std::string query = ToCefString(text).ToString();
  const bool next = state->find_text == query && state->find_match_case == matchCase;
  state->find_text = query; state->find_match_case = matchCase;
  state->browser->GetHost()->Find(ToCefString(text), forward, matchCase, next);
}
- (void)stopFinding {
  auto *state = State(self);
  if (!ActorRequestPolicy(self).human || !state || !state->browser) return;
  state->find_text.clear();
  state->browser->GetHost()->StopFinding(true);
  if (self.onFindResult) self.onFindResult(0, 0);
}
- (double)zoomLevel {
  auto *state = State(self);
  return state && state->browser ? state->browser->GetHost()->GetZoomLevel() : 0;
}
- (void)setZoomLevel:(double)level {
  auto *state = State(self);
  if (ActorRequestPolicy(self).human && state && state->browser && std::isfinite(level))
    state->browser->GetHost()->SetZoomLevel(std::min(5.0, std::max(-5.0, level)));
}
- (void)performContextEdit:(NSString *)kind {
  auto *state = State(self);
  if (!ActorRequestPolicy(self).human || !state || !state->browser) return;
  auto frame = state->browser->GetFocusedFrame();
  if (!frame) return;
  if ([kind isEqualToString:@"cut"]) frame->Cut();
  else if ([kind isEqualToString:@"copy"]) frame->Copy();
  else if ([kind isEqualToString:@"paste"]) frame->Paste();
  else if ([kind isEqualToString:@"selectAll"]) frame->SelectAll();
}
- (void)downloadImageURL:(NSString *)url {
  auto *state = State(self);
  auto policy = ActorRequestPolicy(self);
  if (policy.human && state && state->browser && !URLHasCredentials(url) &&
      IsActorURLAllowed(policy, url) && !IsDeniedByLocalHostList(policy, url))
    state->browser->GetHost()->StartDownload(ToCefString(url));
}
#pragma mark - W57a end

#pragma mark - W57d
- (void)cancelWebFeatures { W57dInvalidate(self); }
- (void)exitContentFullscreen {
  auto *state = State(self);
  if (state && state->browser && state->browser->GetHost()->IsFullscreen())
    state->browser->GetHost()->ExitFullscreen(true);
  if (self.onFullscreenModeChange) self.onFullscreenModeChange(NO);
}
- (void)printPage {
  auto *state = State(self);
  if (!W57dCurrent(self, self.navigationGeneration) || !state || !state->browser) return;
  state->browser->GetHost()->Print();
  ScheduleImmediateCEFMessagePumpWork(@"print");
}
- (void)printToPDFWithCompletion:(void (^)(NSString * _Nullable))completion {
  auto *state = State(self);
  if (!W57dCurrent(self, self.navigationGeneration) || !state || !state->client ||
      state->client->pdf_print_pending_) { completion(nil); return; }
  // mkdtemp reserves a private directory, so another process cannot preplant the file.
  NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"browser-print-XXXXXX"];
  std::vector<char> buffer(pattern.fileSystemRepresentation,
                           pattern.fileSystemRepresentation + strlen(pattern.fileSystemRepresentation) + 1);
  char *directory = mkdtemp(buffer.data());
  if (!directory) { completion(nil); return; }
  NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"page.pdf"];
  CefRefPtr<TatwoClient> client = state->client;
  client->pdf_print_pending_ = true;
  const uint64_t serial = client->web_features_serial_;
  const uint64_t generation = self.navigationGeneration;
  __weak TatwoCEFBrowserView *weak_view = self;
  CefPdfPrintSettings settings;
  settings.print_background = true;
  state->browser->GetHost()->PrintToPDF(ToCefString(path), settings,
      new W57dPDFPrintCallback([weak_view, client, serial, generation, path, completion](bool ok) {
        const bool current = client->web_features_serial_ == serial;
        if (current) client->pdf_print_pending_ = false;
        completion(ok && current && W57dCurrent(weak_view, generation) && W57dIsPDF(path) ? path : nil);
      }));
  ScheduleImmediateCEFMessagePumpWork(@"print_pdf");
}
- (void)downloadCurrentPDFWithCompletion:(void (^)(NSString * _Nullable))completion {
  auto *state = State(self);
  NSString *url = self.currentURLString;
  const auto policy = ActorRequestPolicy(self);
  if (!W57dCurrent(self, self.navigationGeneration) || !state || !state->client ||
      state->client->pdf_download_completion_ ||
      ![[NSURL URLWithString:url].path.pathExtension.lowercaseString isEqualToString:@"pdf"] ||
      URLHasCredentials(url) || !IsActorURLAllowed(policy, url) || IsDeniedByLocalHostList(policy, url)) {
    completion(nil); return;
  }
  state->client->pdf_download_url_ = url;
  state->client->pdf_download_completion_ = [completion copy];
  state->browser->GetHost()->StartDownload(ToCefString(url));
  ScheduleImmediateCEFMessagePumpWork(@"pdf_download");
}
#pragma mark - W57d End

- (void)goBack {
  BrowserState *state = State(self);
  if (!g_shutdown_requested.load() &&
      state && state->browser && state->browser->CanGoBack()) {
    state->is_loading = true;
    BeginNavigationFrameTelemetry(self, state, @"go_back");
    StartLoadingActiveMessagePump(
        self, state->mount_generation, @"go_back");
    state->browser->GoBack();
    ScheduleImmediateCEFMessagePumpWork(@"go_back");
  }
}

- (void)goForward {
  BrowserState *state = State(self);
  if (!g_shutdown_requested.load() &&
      state && state->browser && state->browser->CanGoForward()) {
    state->is_loading = true;
    BeginNavigationFrameTelemetry(self, state, @"go_forward");
    StartLoadingActiveMessagePump(
        self, state->mount_generation, @"go_forward");
    state->browser->GoForward();
    ScheduleImmediateCEFMessagePumpWork(@"go_forward");
  }
}

- (void)reload {
  BrowserState *state = State(self);
  if (!g_shutdown_requested.load() && state && state->browser) {
    state->is_loading = true;
    BeginNavigationFrameTelemetry(self, state, @"reload");
    StartLoadingActiveMessagePump(
        self, state->mount_generation, @"reload");
    state->browser->Reload();
    ScheduleImmediateCEFMessagePumpWork(@"reload");
  }
}

- (void)invokeWebMCPToolNamed:(NSString *)toolName
                argumentsJSON:(NSString *)argumentsJSON
         navigationGeneration:(uint64_t)navigationGeneration
                   completion:(TatwoCEFWebMCPInvocationHandler)completion {
  NSAssert(NSThread.isMainThread,
           @"WebMCP invocation must enter CEF on the main thread");
  BrowserState *state = State(self);
  if (completion == nil) {
    return;
  }
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load() || state == nullptr ||
      state->close_requested || !state->browser || !state->client) {
    completion(nil, @"webmcp_runtime_unavailable");
    return;
  }
  state->client->InvokeWebMCPTool(
      state->browser,
      toolName,
      argumentsJSON,
      navigationGeneration,
      completion);
}

- (void)closeBrowser {
  [self closeBrowserWithCompletion:nil];
}

- (void)closeBrowserWithCompletion:
    (nullable TatwoCEFBrowserCloseHandler)completion {
#pragma mark - W57d
  W57dInvalidate(self);
#pragma mark - W57d End
#pragma mark - W57c Drop credentials on tab teardown
  W57cInvalidate(self, false, false);
#pragma mark - W57c End
#pragma mark - W58
  W58Invalidate(self, false);
#pragma mark - W58 End
  [self releaseAgentPointer];
  [self releaseAgentKey];
  BrowserState *state = State(self);
  if (!state) {
    if (completion != nil) {
      completion();
    }
    return;
  }
  if (completion != nil) {
    [state->close_handlers addObject:[completion copy]];
  }
  if (state->close_requested) {
    return;
  }
  StopLoadingActiveMessagePump(
      self, state->mount_generation, @"close_requested");
  state->close_requested = true;
  state->pending_url = nil;
  state->pending_navigation_gate = nil;
  state->close_generation += 1;
  state->close_retry_attempt = 0;
  state->close_retry_scheduled = false;
  LogBrowserLifecycle(@"close_requested");
  if (state->client) {
    if (g_closing_views == nil) {
      g_closing_views = [NSMutableSet set];
    }
    [g_closing_views addObject:self];
  }
  if (state->browser || state->creation_pending) {
    DriveBrowserClose(
        self, state, state->close_generation);
    return;
  }
  CompleteBrowserClose(self, state);
}

@end

@implementation TatwoCEFRuntime

#pragma mark - W60
+ (NSDictionary<NSString *, id> *)processDiagnostics { return W60ProcessDiagnostics(); }
#pragma mark - W60 End

+ (uint64_t)messagePumpGateRepeatedKickProbe:(uint32_t)kicks {
  return TatwoCEFMessagePumpGateRepeatedKickProbe(kicks);
}

+ (uint64_t)messagePumpShutdownLateBlockProbe {
  return TatwoCEFMessagePumpShutdownLateBlockProbe() ? 1 : 0;
}

+ (uint64_t)messagePumpImmediateInterleavingProbe {
  return TatwoCEFMessagePumpImmediateInterleavingProbe();
}

+ (uint64_t)messagePumpQueuedHostKickProbe {
  return TatwoCEFMessagePumpQueuedHostKickProbe();
}

+ (uint64_t)messagePumpFirstScheduleDeliveryProbe {
  return TatwoCEFMessagePumpFirstScheduleDeliveryProbe();
}

+ (uint64_t)messagePumpTwoImmediateSchedulesProbe {
  return TatwoCEFMessagePumpTwoImmediateSchedulesProbe();
}

+ (uint64_t)messagePumpLoadingActiveLifecycleProbe {
  return TatwoCEFMessagePumpLoadingActiveLifecycleProbe();
}

+ (BOOL)compiled {
  return YES;
}

+ (NSString *)engineIdentifier {
  return @"chromium-cef";
}

+ (NSString *)runtimeVersion {
  return @CEF_VERSION;
}

+ (BOOL)supportsOriginScopedSiteDataClearing {
  return YES;
}

+ (BOOL)supportsOriginScopedHTTPResponseCacheClearing {
  // CEF 151 exposes profile-wide ClearHttpCache(), but no equivalent scoped to
  // one origin. This remains explicitly unsupported and is never used as a
  // fallback for site-data maintenance.
  return NO;
}

+ (BOOL)supportsChromiumWebMCP {
  return g_initialized.load(std::memory_order_acquire) &&
         !g_shutdown.load(std::memory_order_acquire) &&
         !g_shutdown_requested.load(std::memory_order_acquire) &&
         g_webmcp_renderer_hook_active.load(
             std::memory_order_acquire);
}

+ (void)configureRendererProcessLimit:(NSInteger)limit {
  NSAssert(NSThread.isMainThread, @"CEF configuration belongs to the main thread");
  if (!g_initialized.load() && limit >= 0 && limit <= 8) {
    g_renderer_process_limit.store(static_cast<int>(limit));
  }
}

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
               helperExecutablePath:(NSString *)helperExecutablePath
                        logFilePath:(NSString *)logFilePath
               bundledDenyListPath:(NSString *)bundledDenyListPath
                              error:(NSError * _Nullable * _Nullable)error {
  NSAssert(NSThread.isMainThread, @"CEF must initialize on the main thread");
  if (g_initialized.load() && !g_shutdown.load() &&
      !g_shutdown_requested.load()) {
    return YES;
  }
  if (g_shutdown.load() || g_shutdown_requested.load()) {
    if (error != nullptr) {
      *error = MakeError(10, @"Chromium runtime already shut down");
    }
    return NO;
  }
  if (rootCachePath.length == 0 ||
      helperExecutablePath.length == 0 ||
      logFilePath.length == 0 ||
      bundledDenyListPath.length == 0) {
    if (error != nullptr) {
      *error = MakeError(11, @"Chromium runtime paths are incomplete");
    }
    return NO;
  }
  NSError *deny_list_error = nil;
  g_host_deny_list =
      LoadHostDenyListSnapshot(
          rootCachePath,
          bundledDenyListPath,
          &deny_list_error);
  if (!g_host_deny_list) {
    if (error != nullptr) {
      *error = deny_list_error
          ?: MakeError(15, @"Chromium 本機封鎖名單載入失敗");
    }
    return NO;
  }
  ConfigureCEFEmbeddingTelemetry(logFilePath);
  g_host_blocked_request_count.store(0, std::memory_order_relaxed);
  g_host_blocked_main_frame_count.store(0, std::memory_order_relaxed);
  g_host_blocked_subresource_count.store(0, std::memory_order_relaxed);
  NSString *resolved_helper_executable_path =
      ResolveCEFHelperExecutablePath(helperExecutablePath);
  if (resolved_helper_executable_path.length == 0) {
    if (error != nullptr) {
      *error = MakeError(
          14,
          @"Chromium helper bundle or declared executable is unavailable");
    }
    return NO;
  }

  g_library_loader = std::make_unique<CefScopedLibraryLoader>();
  if (!g_library_loader->LoadInMain()) {
    g_library_loader.reset();
    if (error != nullptr) {
      *error = MakeError(12, @"Chromium runtime unavailable");
    }
    return NO;
  }

  CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
  g_webrtc_ip_policy_configured.store(
      false, std::memory_order_release);
  g_webmcp_renderer_hook_active.store(
      false, std::memory_order_release);
  CefSettings settings;
#pragma mark - W57d
  CefString(&settings.user_agent).FromASCII(W57dUserAgent());
#pragma mark - W57d End
  settings.no_sandbox = false;
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = true;
  settings.windowless_rendering_enabled = false;
  settings.remote_debugging_port = 0;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.root_cache_path) = ToCefString(rootCachePath);
  // Give CEF the exact base helper executable. On macOS CEF uses this unsuffixed
  // path as the anchor for the role-specific Alerts/GPU/Plugin/Renderer sibling
  // helper bundles. This avoids ambiguous inference when CFBundleName and the
  // top-level CFBundleExecutable intentionally differ in staging.
  CefString(&settings.browser_subprocess_path) =
      ToCefString(resolved_helper_executable_path);
  CefString(&settings.log_file) = ToCefString(logFilePath);
  CefString(&settings.locale).FromASCII("en-US");

  g_application = new TatwoBrowserProcessApp();
  if (!CefInitialize(main_args, settings, g_application, nullptr)) {
    g_application = nullptr;
    g_library_loader.reset();
    if (error != nullptr) {
      *error = MakeError(13, @"Chromium initialization failed");
    }
    return NO;
  }
  if (!g_webrtc_ip_policy_configured.load(
          std::memory_order_acquire)) {
    g_application = nullptr;
    CefShutdown();
    g_library_loader.reset();
    g_host_deny_list.reset();
    g_shutdown.store(true);
    if (error != nullptr) {
      *error = MakeError(16, kPrivacyStrictStartupError);
    }
    return NO;
  }
  g_initialized.store(true);
  StartCEFMessagePumpIdleTimer();
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=security_capability event=webrtc_ip_policy "
           "policyVersion=%u value=%s configured=1 privacyStrict=1",
          kBrowserNetworkSecurityPolicyVersion,
          kWebRTCIPHandlingPolicy]);
  AppendCEFEmbeddingTelemetryLine(
      [NSString stringWithFormat:
          @"phase=security_capability event=local_deny_list_loaded "
           "policyVersion=%u exactCount=%zu suffixCount=%zu "
           "bundledExactCount=%zu bundledSuffixCount=%zu "
           "adminExactCount=%zu adminSuffixCount=%zu "
           "userExactCount=%zu userSuffixCount=%zu",
          kBrowserNetworkSecurityPolicyVersion,
          g_host_deny_list->exact_hosts.size(),
          g_host_deny_list->suffix_hosts.size(),
          g_host_deny_list->bundled_exact_count,
          g_host_deny_list->bundled_suffix_count,
          g_host_deny_list->admin_exact_count,
          g_host_deny_list->admin_suffix_count,
          g_host_deny_list->user_exact_count,
          g_host_deny_list->user_suffix_count]);

  if (g_termination_observer == nil) {
    g_termination_observer =
        [NSNotificationCenter.defaultCenter
            addObserverForName:NSApplicationWillTerminateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *notification) {
                      [TatwoCEFRuntime shutdown];
                    }];
  }
  // Route the bootstrap iteration through the same gate and telemetry as all
  // later work so a reentrant host kick becomes one bounded follow-up instead
  // of an unobserved nested CefDoMessageLoopWork call.
  RunCEFMessagePumpWorkOnMainThread();
  return YES;
}

+ (void)clearDataForOrigin:(NSString *)origin
         persistentProfile:(NSString *)persistentProfile
                completion:(TatwoCEFOriginDataClearHandler)completion {
  NSAssert(NSThread.isMainThread,
           @"CEF origin data clearing must run on the main thread");
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.load()) {
    completion(
        NO,
        NO,
        YES,
        MakeError(
            TatwoCEFOriginDataClearErrorRuntimeUnavailable,
            @"Chromium runtime unavailable"));
    return;
  }
  NSURLComponents *components = SafeURLComponents(origin);
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host;
  BOOL path_is_origin_only =
      components.path.length == 0 || [components.path isEqualToString:@"/"];
  BOOL valid_origin =
      ([scheme isEqualToString:@"http"] ||
       [scheme isEqualToString:@"https"]) &&
      host.length > 0 &&
      components.user == nil &&
      components.password == nil &&
      components.query == nil &&
      components.fragment == nil &&
      path_is_origin_only &&
      IsAllowedURLString(origin);
  if (!valid_origin) {
    completion(
        NO,
        NO,
        YES,
        MakeError(
            TatwoCEFOriginDataClearErrorInvalidOrigin,
            @"Chromium origin is invalid or disallowed"));
    return;
  }
  if (persistentProfile.length == 0) {
    completion(
        NO,
        NO,
        YES,
        MakeError(
            TatwoCEFOriginDataClearErrorInvalidPersistentProfile,
            @"Chromium persistent profile is required"));
    return;
  }

  CefRefPtr<TatwoOriginDataClearOperation> operation =
      new TatwoOriginDataClearOperation(
          origin,
          persistentProfile,
          completion);
  RetainOriginDataClearOperation(operation);
  operation->Start();
}

+ (void)captureActiveVisibleSnapshotWithCompletion:
    (TatwoCEFBrowserSnapshotHandler)completion {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [TatwoCEFRuntime captureActiveVisibleSnapshotWithCompletion:completion];
    });
    return;
  }
  TatwoCEFBrowserView *view = g_active_committed_browser_view;
  if (!view) { completion(nil, @"snapshot_unavailable"); return; }
  [view captureVisibleSnapshotWithCompletion:completion];
}

+ (void)shutdown {
  NSAssert(NSThread.isMainThread, @"CEF must shut down on the main thread");
  if (!g_initialized.load() || g_shutdown.load() ||
      g_shutdown_requested.exchange(true)) {
    return;
  }
  AppendCEFEmbeddingTelemetryLine(
      @"phase=runtime_shutdown event=drain_started");
  StopCEFMessagePumpIdleTimer();
  if (!DrainCEFReferencesForShutdown()) {
    const NSUInteger browser_reference_count =
        LiveBrowserReferenceCount();
    const size_t origin_operation_count =
        g_origin_data_clear_operations.size();
    const size_t resource_decision_count =
        PendingResourceDecisionCount();
    AppendCEFEmbeddingTelemetryLine(
        [NSString stringWithFormat:
            @"phase=runtime_shutdown event=cef_shutdown_skipped "
             "reason=live_references browserReferences=%lu "
             "originOperations=%zu resourceDecisions=%zu",
            static_cast<unsigned long>(browser_reference_count),
            origin_operation_count,
            resource_decision_count]);
    // Never call CefShutdown while wrapper references are still live. The
    // process is already terminating; skipping CEF teardown is safer than
    // triggering the wrapper's "Object reference incorrectly held at
    // CefShutdown" DCHECK/SIGTRAP.
    g_initialized.store(false);
    g_shutdown.store(true);
    g_message_pump_generation.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  g_initialized.store(false);
  g_shutdown.store(true);
  g_message_pump_generation.fetch_add(1, std::memory_order_relaxed);
  g_active_committed_browser_view = nil;
  g_live_browser_views = nil;
  g_closing_views = nil;
  g_application = nullptr;
  CefShutdown();
  g_library_loader.reset();
  g_host_deny_list.reset();
  g_webrtc_ip_policy_configured.store(
      false, std::memory_order_release);
}

@end

int TatwoCEFExecuteSubprocess(void) {
  const CEFHelperRoleTelemetry helper = CurrentCEFHelperRole();
  ConfigureCEFHelperProcessTelemetry(helper.token);
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(*_NSGetArgc(), *_NSGetArgv())) {
    return CompleteCEFHelperProcessTelemetry(helper.token, 73);
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return CompleteCEFHelperProcessTelemetry(helper.token, 74);
  }
  CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
  CefRefPtr<CefApp> application = new TatwoBrowserProcessApp();
  const int exit_code =
      CefExecuteProcess(main_args, application, nullptr);
  return CompleteCEFHelperProcessTelemetry(helper.token, exit_code);
}

BOOL TatwoCEFURLPolicyAllowsURLString(NSString *urlString) {
  return IsAllowedURLString(urlString);
}

BOOL TatwoCEFResolvedURLPolicyAllowsURLString(NSString *urlString) {
  return IsAllowedResolvedURLString(urlString);
}

BOOL TatwoCEFHostSwitchIsDenied(NSString *switchName) {
  return IsDeniedHostSwitch(switchName);
}
