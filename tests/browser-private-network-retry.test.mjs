import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
test('denied private navigation reloads its exact target through normal policy, never a stale or agent target', {skip: process.platform !== 'darwin'}, () => {
  const native = readFileSync('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', 'utf8');
  const start = native.indexOf('void RememberPrivateNetworkRetry(', native.indexOf('struct BrowserState {'));
  const methods = native.slice(start, native.indexOf('\nvoid PublishResourceError(', start));
  const reloadStart = native.indexOf('- (void)reload {');
  const reload = native.slice(reloadStart, native.indexOf('\n- (void)invokeWebMCP', reloadStart));
  assert.ok(start > 0 && reloadStart > 0);
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-network-retry-'));
  writeFileSync(join(dir, 'checks.mm'), String.raw`
#import <AppKit/AppKit.h>
#include <memory>
#include <atomic>
#include <cassert>
struct Epoch { uint64_t generation = 4; bool IsCurrent(uint64_t value) { return generation == value; } };
struct ResourceErrorContext { std::shared_ptr<Epoch> epoch; uint64_t generation; uint64_t mount_generation; };
enum { TatwoCEFBrowserErrorKindNone, TatwoCEFBrowserErrorKindSecurity };
struct Browser { int reloads=0; void Reload() { ++reloads; } };
struct BrowserState {
 NSString *private_network_retry_url=nil;
 uint64_t private_network_retry_generation=0, navigation_generation=7, mount_generation=3;
 bool close_requested=false, close_completed=false, is_loading=false;
 int error_kind=TatwoCEFBrowserErrorKindSecurity;
 std::shared_ptr<Browser> browser=std::make_shared<Browser>();
};
BrowserState *current=nullptr;
std::atomic<bool> g_shutdown_requested{false};
@interface TatwoCEFBrowserView : NSObject
@property BOOL human;
@property NSString *loaded;
- (void)loadURLString:(NSString *)url;
- (void)reload;
@end
BrowserState *State(TatwoCEFBrowserView *) { return current; }
struct Policy { bool human; };
Policy ActorRequestPolicy(TatwoCEFBrowserView *view) { return {bool(view.human)}; }
bool URLHasCredentials(NSString *url) { return [url containsString:@"@"]; }
void BeginNavigationFrameTelemetry(TatwoCEFBrowserView *,BrowserState *state,NSString *) { ++state->navigation_generation; }
void StartLoadingActiveMessagePump(TatwoCEFBrowserView *,uint64_t,NSString *) {}
void ScheduleImmediateCEFMessagePumpWork(NSString *) {}
` + methods + String.raw`
@implementation TatwoCEFBrowserView
- (void)loadURLString:(NSString *)url { self.loaded=url; ++current->navigation_generation; }
` + reload + String.raw`
@end
int main() { @autoreleasepool {
 auto view=[TatwoCEFBrowserView new]; view.human=YES;
 BrowserState state; current=&state;
 auto epoch=std::make_shared<Epoch>(); ResourceErrorContext context{epoch,4,3};
 NSString *target=@"http://127.0.0.1:8766/page-a?retry=1";
 auto reset=[&] { state=BrowserState{}; view.human=YES; view.loaded=nil; epoch->generation=4; };
 reset(); RememberPrivateNetworkRetry(view,context,target); [view reload];
 assert([view.loaded isEqualToString:target] && state.browser->reloads==0 && !state.private_network_retry_url);
 [view reload]; assert(state.browser->reloads==1); // consumed once
 reset(); RememberPrivateNetworkRetry(view,context,target); ++state.navigation_generation; [view reload];
 assert(!view.loaded && state.browser->reloads==1);
 reset(); RememberPrivateNetworkRetry(view,context,target); view.human=NO; [view reload];
 assert(!view.loaded && state.browser->reloads==1);
 reset(); RememberPrivateNetworkRetry(view,context,target); state.error_kind=TatwoCEFBrowserErrorKindNone; [view reload];
 assert(!view.loaded && state.browser->reloads==1);
 reset(); epoch->generation=5; RememberPrivateNetworkRetry(view,context,target); assert(!state.private_network_retry_url);
 reset(); state.mount_generation=8; RememberPrivateNetworkRetry(view,context,target); assert(!state.private_network_retry_url);
 reset(); state.close_requested=true; RememberPrivateNetworkRetry(view,context,target); assert(!state.private_network_retry_url);
 reset(); RememberPrivateNetworkRetry(view,context,@"http://user:secret@127.0.0.1/"); assert(!state.private_network_retry_url);
 reset(); RememberPrivateNetworkRetry(view,context,target); state.close_completed=true; assert(!TakePrivateNetworkRetry(view));
 puts("PASS: exact retry via loadURLString; consume once; newer navigation, actor takeover, non-error, stale epoch/mount, close and credentials rejected");
} }
`);
  const bin=join(dir,'checks');
  const build=spawnSync('clang++',['-std=c++20','-fobjc-arc','-fblocks','-framework','AppKit',join(dir,'checks.mm'),'-o',bin],{encoding:'utf8',timeout:60000});
  assert.equal(build.status,0,build.stderr);
  const run=spawnSync(bin,[],{encoding:'utf8',timeout:10000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  process.stdout.write(run.stdout);
});
