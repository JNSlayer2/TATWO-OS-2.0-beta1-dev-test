import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const native = fs.readFileSync(path.join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');

test('production loading callback releases a retained human document after attachment navigation without reviving old grants', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/retained-document-input');
  fs.mkdirSync(dir, {recursive: true});
  const start = native.indexOf('void UpdateLoadingState(TatwoCEFBrowserView *view, bool is_loading) {');
  const end = native.indexOf('\nvoid PublishMainFrameLoadStart(', start);
  assert.ok(start > 0 && end > start);
  const method = native.slice(start, end);
  fs.writeFileSync(path.join(dir, 'fixture.mm'), String.raw`
#import <AppKit/AppKit.h>
#include <memory>
#include <string>
#include <cassert>
enum { TatwoCEFBrowserPhaseBlank, TatwoCEFBrowserPhaseLoading,
 TatwoCEFBrowserPhaseCommitted, TatwoCEFBrowserPhaseFinished,
 TatwoCEFBrowserPhaseBlockedBySecurity, TatwoCEFBrowserPhaseNavigationFailed,
 TatwoCEFBrowserPhaseRendererFailed };
enum { TatwoCEFBrowserErrorKindNone, TatwoCEFBrowserErrorKindSecurity };
struct Frame {
 bool valid=true; std::string url="http://127.0.0.1:8766/page-a";
 bool IsValid() { return valid; } std::string GetURL() { return url; }
};
struct Browser {
 bool loading=false; std::shared_ptr<Frame> frame=std::make_shared<Frame>();
 bool IsLoading() { return loading; } std::shared_ptr<Frame> GetMainFrame() { return frame; }
};
struct BrowserState {
 bool is_loading=true, navigation_in_flight=true, document_epoch_valid=true, close_requested=false;
 int error_kind=TatwoCEFBrowserErrorKindNone, phase=TatwoCEFBrowserPhaseFinished;
 uint64_t mount_generation=2, navigation_generation=7, document_epoch=3;
 bool old_credential_grant_valid=false, old_site_grant_valid=false;
 NSString *committed_url=@"http://127.0.0.1:8766/page-a";
 std::shared_ptr<Browser> browser=std::make_shared<Browser>();
};
@interface TatwoCEFBrowserView : NSObject
@property(nonatomic) BOOL human;
@end
@implementation TatwoCEFBrowserView @end
BrowserState *current=nullptr;
int recovered=0, starts=0, stops=0;
void MutateStateOnMain(TatwoCEFBrowserView *, void (^mutation)(BrowserState *)) { mutation(current); }
struct Policy { bool human; };
Policy ActorRequestPolicy(TatwoCEFBrowserView *view) { return {bool(view.human)}; }
NSString *FromCefString(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }
void AppendCEFEmbeddingTelemetryLine(NSString *) { ++recovered; }
void StartLoadingActiveMessagePump(TatwoCEFBrowserView *,uint64_t,NSString *) { ++starts; }
void StopLoadingActiveMessagePump(TatwoCEFBrowserView *,uint64_t,NSString *) { ++stops; }
` + method + String.raw`
int main() { @autoreleasepool {
 auto view=[[TatwoCEFBrowserView alloc] init]; view.human=YES;
 BrowserState state;
 auto reset=[&] { state=BrowserState{}; current=&state; view.human=YES; };
 auto preserved=[&] {
   assert(state.navigation_generation==7 && state.document_epoch==3);
   assert(!state.old_credential_grant_valid && !state.old_site_grant_valid);
   assert([state.committed_url isEqualToString:@"http://127.0.0.1:8766/page-a"]);
 };
 reset(); UpdateLoadingState(view,false);
 assert(!state.navigation_in_flight && !state.is_loading && recovered==1);
 assert(state.phase==TatwoCEFBrowserPhaseFinished); preserved();
 reset(); state.phase=TatwoCEFBrowserPhaseCommitted; UpdateLoadingState(view,false);
 assert(!state.navigation_in_flight && state.phase==TatwoCEFBrowserPhaseCommitted); preserved();
 // Fail closed for agents, invalid documents, errors, navigation still active,
 // changed frames, hidden replacement documents, and closing browser owners.
 reset(); view.human=NO; UpdateLoadingState(view,false); assert(state.navigation_in_flight); preserved();
 reset(); state.document_epoch_valid=false; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.error_kind=TatwoCEFBrowserErrorKindSecurity; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.browser->loading=true; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.browser->frame->url="http://127.0.0.1:8766/page-b"; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.phase=TatwoCEFBrowserPhaseLoading; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.phase=TatwoCEFBrowserPhaseBlockedBySecurity; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.browser->frame->valid=false; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.browser->frame=nullptr; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.browser=nullptr; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.committed_url=nil; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); state.close_requested=true; UpdateLoadingState(view,false); assert(state.navigation_in_flight);
 reset(); UpdateLoadingState(view,true); assert(state.navigation_in_flight && state.is_loading); preserved();
 assert(recovered==2 && starts==1 && stops==14);
 puts("PASS: retained document recovers input; generation/revocations preserved; agents, new navigation and invalid owners rejected");
} }
`);
  const build = spawnSync('clang++', ['-std=c++20', '-fobjc-arc', '-fblocks', '-framework', 'AppKit', path.join(dir, 'fixture.mm'), '-o', path.join(dir, 'fixture')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(path.join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
