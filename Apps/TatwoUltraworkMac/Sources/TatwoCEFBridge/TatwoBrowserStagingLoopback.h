#pragma once

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>

// Shared by the real bridge and unavailable bridge. Zero always means disabled.
static inline NSInteger TatwoBrowserStagingLoopbackPort(
    NSString *flag, NSString *scratchHome, NSString *bundleID, NSString *portText) {
  if (![flag isEqualToString:@"1"] ||
      [scratchHome stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0 ||
      [bundleID isEqualToString:@"ai.tatwo.tatwo2"] ||
      ![bundleID hasPrefix:@"ai.tatwo.tatwo2."] ||
      bundleID.length <= @"ai.tatwo.tatwo2.".length) {
    return 0;
  }
  NSString *text = portText ?: @"8765";
  if (text.length == 0) return 0;
  NSInteger port = 0;
  for (NSUInteger index = 0; index < text.length; ++index) {
    unichar digit = [text characterAtIndex:index];
    if (digit < '0' || digit > '9') return 0;
    port = port * 10 + digit - '0';
    if (port > 65535) return 0;
  }
  return port;
}

static inline BOOL TatwoBrowserStagingLoopbackAllows(
    NSURLComponents *components, NSInteger port) {
  if (port < 1 || port > 65535 || components == nil) return NO;
  @try {
    NSString *scheme = components.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        [components.percentEncodedHost isEqualToString:@"127.0.0.1"] &&
        components.port != nil && components.port.integerValue == port &&
        components.user == nil && components.password == nil;
  } @catch (NSException *exception) {
    return NO;
  }
}

static inline NSString *TatwoBrowserStagingEnvironmentValue(const char *name) {
  const char *value = getenv(name);
  return value == NULL ? nil : [NSString stringWithUTF8String:value];
}

static inline NSInteger TatwoBrowserStagingLoopbackRuntimePort(void) {
  static NSInteger port = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    port = TatwoBrowserStagingLoopbackPort(
        TatwoBrowserStagingEnvironmentValue("TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"),
        TatwoBrowserStagingEnvironmentValue("TATWO_STAGING_SCRATCH_HOME"),
        NSBundle.mainBundle.bundleIdentifier,
        TatwoBrowserStagingEnvironmentValue("TATWO_STAGING_BROWSER_LOOPBACK_PORT"));
    if (port != 0) {
      fprintf(stderr, "browser_staging_loopback=enabled port=%ld\n", (long)port);
    }
  });
  return port;
}
