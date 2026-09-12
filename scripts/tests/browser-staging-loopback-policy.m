// Headless tests of the exact predicate shared by both CEF bridge builds.
#import "../../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoBrowserStagingLoopback.h"
#ifdef TATWO_TEST_STUB_STARTUP
#import "../../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h"
#endif

static NSUInteger checks = 0;
static void Check(BOOL success, NSString *label) {
  ++checks;
  if (!success) {
    fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    exit(1);
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
#ifdef TATWO_TEST_STUB_STARTUP
    // Link the real unavailable bridge and a fixture __info_plist. +load must
    // snapshot before main, without creating NSApplication or opening any GUI.
    if (argc == 2) {
      NSInteger expected = [[NSString stringWithUTF8String:argv[1]] integerValue];
      NSString *allowed = [NSString stringWithFormat:@"http://127.0.0.1:%ld/drag.html",
          (long)(expected ?: 8765)];
      // Change the environment before the first exported policy call: lazy
      // first-use initialization (instead of +load) would fail these checks.
      setenv("TATWO_STAGING_ALLOW_BROWSER_LOOPBACK", expected ? "0" : "1", 1);
      setenv("TATWO_STAGING_SCRATCH_HOME", "/fixture/home", 1);
      setenv("TATWO_STAGING_BROWSER_LOOPBACK_PORT", "8765", 1);
      Check(!TatwoCEFRuntime.compiled, @"probe must not launch CEF");
      Check(TatwoCEFURLPolicyAllowsURLString(allowed) == (expected != 0), @"startup URL gate");
      Check(TatwoCEFResolvedURLPolicyAllowsURLString(allowed) == (expected != 0), @"startup resolved gate");
      for (NSString *target in @[@"http://localhost:8765/", @"http://127.0.0.2:8765/",
                                 @"http://[::1]:8765/", @"http://10.0.0.1/",
                                 @"http://user:pw@127.0.0.1:8765/"]) {
        Check(!TatwoCEFURLPolicyAllowsURLString(target), target);
        Check(!TatwoCEFResolvedURLPolicyAllowsURLString(target), target);
      }
      // Later changes must not change the grant either.
      setenv("TATWO_STAGING_ALLOW_BROWSER_LOOPBACK", expected ? "1" : "0", 1);
      setenv("TATWO_STAGING_BROWSER_LOOPBACK_PORT", "65535", 1);
      Check(TatwoCEFURLPolicyAllowsURLString(allowed) == (expected != 0), @"cached URL gate");
      Check(TatwoCEFResolvedURLPolicyAllowsURLString(allowed) == (expected != 0), @"cached resolved gate");
      fprintf(stdout, "CEF_STAGING_LOOPBACK_STARTUP_PASS expected_port=%ld checks=%lu\n",
          (long)expected, (unsigned long)checks);
      return 0;
    }
#endif
    NSString *identity = @"ai.tatwo.tatwo2.c2";
    NSInteger port = TatwoBrowserStagingLoopbackPort(@"1", @"/fixture/home", identity, nil);
    Check(port == 8765, @"default port");
    for (NSString *flag in @[@"", @"0", @"true", @"01", @"1 ", @" 1"]) {
      Check(TatwoBrowserStagingLoopbackPort(flag, @"/fixture/home", identity, nil) == 0, flag);
    }
    Check(TatwoBrowserStagingLoopbackPort(nil, nil, identity, nil) == 0, @"no environment");
    for (NSString *home in @[@"", @" \n\t"]) {
      Check(TatwoBrowserStagingLoopbackPort(@"1", home, identity, nil) == 0, @"empty isolation");
    }
    Check(TatwoBrowserStagingLoopbackPort(@"1", nil, identity, nil) == 0, @"missing isolation");
    for (NSString *bundle in @[@"", @"ai.tatwo.tatwo2", @"ai.tatwo.tatwo2.",
                              @"ai.tatwo.tatwo20.stage", @"org.example.stage"]) {
      Check(TatwoBrowserStagingLoopbackPort(@"1", @"/fixture/home", bundle, nil) == 0, bundle);
    }
    Check(TatwoBrowserStagingLoopbackPort(@"1", @"/fixture/home", nil, nil) == 0, @"missing bundle");
    for (NSString *text in @[@"", @"0", @"-1", @"+8765", @"65536", @"8765 ", @" 8765",
                             @"8x", @"８７６５", @"999999999999999999999999999"]) {
      Check(TatwoBrowserStagingLoopbackPort(@"1", @"/fixture/home", identity, text) == 0, text);
    }
    for (NSString *text in @[@"1", @"9001", @"65535"]) {
      Check(TatwoBrowserStagingLoopbackPort(@"1", @"/fixture/home", identity, text) ==
            text.integerValue, text);
    }
    for (NSString *text in @[@"http://127.0.0.1:8765/drag.html",
                             @"https://127.0.0.1:8765/drag.html?test=1#target"]) {
      NSURLComponents *url = [NSURLComponents componentsWithString:text];
      Check(TatwoBrowserStagingLoopbackAllows(url, port), text);
      Check(!TatwoBrowserStagingLoopbackAllows(url, 0), @"disabled");
      Check(!TatwoBrowserStagingLoopbackAllows(url, 9001), @"other configured port");
    }
    for (NSString *text in @[
        @"http://127.0.0.1:8766/", @"http://127.0.0.1/", @"https://127.0.0.1/",
        @"http://127.0.0.2:8765/", @"http://localhost:8765/",
        @"http://a.localhost:8765/", @"http://test.local:8765/",
        @"http://[::1]:8765/", @"http://[::ffff:127.0.0.1]:8765/",
        @"http://10.0.0.1/", @"http://172.16.0.1:8765/", @"http://192.168.1.1:8765/",
        @"http://user:pw@127.0.0.1:8765/", @"http://@127.0.0.1:8765/",
        @"http://127.1:8765/", @"http://2130706433:8765/", @"http://0x7f000001:8765/",
        @"http://127.0.0.1.:8765/", @"http://%31%32%37.0.0.1:8765/",
        @"ftp://127.0.0.1:8765/", @"https://example.com/"]) {
      // Same predicate is applied afresh to redirect targets; no origin state.
      Check(!TatwoBrowserStagingLoopbackAllows([NSURLComponents componentsWithString:text], port), text);
    }
    Check(!TatwoBrowserStagingLoopbackAllows(nil, port), @"missing URL");
    Check(TatwoBrowserStagingLoopbackAllows(
        [NSURLComponents componentsWithString:@"http://127.0.0.1:9001/"], 9001), @"custom endpoint");
    fprintf(stdout, "CEF_STAGING_LOOPBACK_PREDICATE_PASS checks=%lu\n", (unsigned long)checks);
  }
  return 0;
}
