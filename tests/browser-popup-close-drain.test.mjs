import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

const native = readFileSync('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', 'utf8');
test('profile-owner completion waits for all real and accepted-pending popup descendants', {skip: process.platform !== 'darwin'}, () => {
  const dir=mkdtempSync(join(tmpdir(),'tatwo-popup-drain-'));
  const start=native.indexOf('bool DeferCloseUntilPopupsDrain(');
  const end=native.indexOf('\nvoid CompleteBrowserClose(',start);
  assert.ok(start>0 && end>start);
  const final=native.slice(end,native.indexOf('void TatwoClient::OnAfterCreated',end));
  assert.ok(final.indexOf('DeferCloseUntilPopupsDrain')<final.indexOf('state->close_completed = true'));
  assert.ok(final.indexOf('removeObjectIdenticalTo:view')<final.indexOf('handler();'));
  writeFileSync(join(dir,'fixture.mm'), `
#import <Foundation/Foundation.h>
#include <cassert>
struct BrowserState;
@interface TatwoCEFBrowserView : NSObject
@property(nonatomic) BrowserState *state;
@property(nonatomic,weak) TatwoCEFBrowserView *parent;
@property(nonatomic,copy) void (^completion)(void);
@property(nonatomic) BOOL acceptedPending;
@property(nonatomic) BOOL immediate;
@property(nonatomic) int closeCalls;
- (void)closeBrowserWithCompletion:(void (^)(void))completion;
- (void)nativeBeforeClose;
@end
struct BrowserState {
 bool popup_close_pending=false, close_requested=false;
 uint64_t close_generation=1;
 NSMutableArray<TatwoCEFBrowserView *> *popup_views=[NSMutableArray array];
};
BrowserState *State(TatwoCEFBrowserView *v) { return v.state; }
int completed=0;
void CompleteBrowserClose(TatwoCEFBrowserView *,BrowserState *);
${native.slice(start,end)}
void CompleteBrowserClose(TatwoCEFBrowserView *view,BrowserState *state) {
 if (DeferCloseUntilPopupsDrain(view,state)) return;
 // Mirrors production's remove-from-opener before close-handler delivery.
 if (view.parent.state) [view.parent.state->popup_views removeObjectIdenticalTo:view];
 view.state=nullptr; delete state;
 if (view.completion) { auto done=view.completion;view.completion=nil;done(); }
 else ++completed; // Only owner completion can release/reuse/purge the profile.
}
@implementation TatwoCEFBrowserView
- (void)closeBrowserWithCompletion:(void (^)(void))completion {
 ++self.closeCalls;self.completion=completion;
 if (self.immediate) [self nativeBeforeClose];
}
- (void)nativeBeforeClose {
 assert(!self.acceptedPending);
 CompleteBrowserClose(self,self.state);
}
@end
TatwoCEFBrowserView *make(TatwoCEFBrowserView *parent=nil) {
 auto v=[TatwoCEFBrowserView new];v.state=new BrowserState();v.parent=parent;
 if(parent) [parent.state->popup_views addObject:v];
 return v;
}
int main(){@autoreleasepool {
 auto owner=make();auto a=make(owner);auto pending=make(owner);auto nested=make(a);
 pending.acceptedPending=YES;
 CompleteBrowserClose(owner,owner.state);
 assert(completed==0 && owner.state && owner.state->close_requested);
 assert(owner.state->close_generation==2 && a.closeCalls==1 && pending.closeCalls==1);
 CompleteBrowserClose(owner,owner.state); // Duplicate native delivery cannot reschedule children.
 assert(a.closeCalls==1 && pending.closeCalls==1);
 [a nativeBeforeClose];assert(completed==0 && nested.closeCalls==1);
 [nested nativeBeforeClose];assert(completed==0 && owner.state);
 // Accepted creation only: no fake completion or profile reuse before OnBeforeClose.
 assert(pending.acceptedPending && owner.state->popup_close_pending);
 pending.acceptedPending=NO;assert(completed==0);
 [pending nativeBeforeClose];assert(completed==1 && !owner.state);
 auto sync=make();auto child=make(sync);child.immediate=YES;
 CompleteBrowserClose(sync,sync.state);assert(completed==2 && !sync.state);
 auto aborted=make();auto neverCreated=make(aborted);neverCreated.immediate=YES;
 CompleteBrowserClose(aborted,aborted.state);assert(completed==3 && !aborted.state);
 puts("popup tree drains before owner/profile completion; pending, nested, duplicate, synchronous and aborted cases PASS");
}}
`);
  const build=spawnSync('xcrun',['clang++','-std=c++20','-fobjc-arc','-fblocks','-framework','Foundation',join(dir,'fixture.mm'),'-o',join(dir,'checks')],{encoding:'utf8',timeout:60000});
  assert.equal(build.status,0,build.stderr);
  const run=spawnSync(join(dir,'checks'),[],{encoding:'utf8',timeout:10000});
  assert.equal(run.status,0,run.stdout+run.stderr);
});
