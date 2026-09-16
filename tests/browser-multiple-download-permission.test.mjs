import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const native = fs.readFileSync(path.join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
test('production permission callback asks for multiple downloads, dismisses unsupported/stale requests, and denies agents', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/multiple-download-permission'); fs.mkdirSync(dir, {recursive:true});
  const start = native.indexOf('  bool OnShowPermissionPrompt(');
  const end = native.indexOf('  void OnLoadingStateChange(', start);
  assert.ok(start > 0 && end > start);
  const method = native.slice(start, end).replace(') override {', ') {');
  fs.writeFileSync(path.join(dir, 'fixture.mm'), String.raw`
#import <AppKit/AppKit.h>
#include <memory>
#include <string>
#include <cassert>
template<class T> using CefRefPtr = std::shared_ptr<T>;
using CefString = std::string;
struct CefBrowser {};
struct CefPermissionPromptCallback { int result=-1; void Continue(int value) { result=value; } };
constexpr int CEF_PERMISSION_TYPE_CAMERA_STREAM=1<<2, CEF_PERMISSION_TYPE_MIC_STREAM=1<<12,
 CEF_PERMISSION_TYPE_GEOLOCATION=1<<8, CEF_PERMISSION_TYPE_NOTIFICATIONS=1<<15,
 CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS=1<<14;
constexpr int CEF_PERMISSION_RESULT_ACCEPT=0, CEF_PERMISSION_RESULT_DENY=1, CEF_PERMISSION_RESULT_DISMISS=2;
constexpr int TatwoCEFBrowserErrorKindSecurity=0, ERR_ACCESS_DENIED=1, TatwoCEFBrowserPhaseBlockedBySecurity=2;
NSString *kPermissionBlockedError=@"blocked";
@interface TatwoCEFBrowserView : NSView
@property(nonatomic) BOOL human;
@property(nonatomic) uint64_t navigationGeneration;
@property(nonatomic,copy) void (^onPermissionRequested)(NSString *,NSString *,void (^)(BOOL));
@end
@implementation TatwoCEFBrowserView @end
struct Policy { bool human; };
Policy ActorRequestPolicy(TatwoCEFBrowserView *owner) { return {bool(owner.human)}; }
NSString *FromCefString(const CefString &s) { return [NSString stringWithUTF8String:s.c_str()]; }
bool live=true; int visibleErrors=0;
bool IsPermissionReplyLive(TatwoCEFBrowserView *owner,uint64_t mount,uint64_t generation) { return live && owner.human && owner.navigationGeneration==generation; }
void PublishVisibleError(TatwoCEFBrowserView *,NSString *,int,int,int) { ++visibleErrors; }
void ScheduleImmediateCEFMessagePumpWork(NSString *) {}
struct Client {
 TatwoCEFBrowserView *owner_;
 uint64_t mount_generation_=1;
` + method + String.raw`
};
int main() { @autoreleasepool {
 auto owner=[[TatwoCEFBrowserView alloc] init]; owner.human=YES; owner.navigationGeneration=1;
 Client client{owner}; __block int asked=0; __block NSString *label=nil; __block void (^answer)(BOOL)=nil;
 owner.onPermissionRequested=^(NSString *origin,NSString *permission,void (^completion)(BOOL)) { ++asked; label=permission; answer=[completion copy]; };
 auto denied=std::make_shared<CefPermissionPromptCallback>();
 client.OnShowPermissionPrompt(nullptr,1,"http://localhost:8766",CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS,denied);
 assert(asked==1 && denied->result==-1 && [label containsString:@"下載多個檔案"]);
 answer(NO); assert(denied->result==CEF_PERMISSION_RESULT_DISMISS);
 auto allowed=std::make_shared<CefPermissionPromptCallback>();
 client.OnShowPermissionPrompt(nullptr,2,"http://localhost:8766",CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS,allowed);
 assert(asked==2 && allowed->result==-1); answer(YES); assert(allowed->result==CEF_PERMISSION_RESULT_ACCEPT);
 auto unsupported=std::make_shared<CefPermissionPromptCallback>();
 client.OnShowPermissionPrompt(nullptr,3,"http://localhost:8766",1u<<30,unsupported);
 assert(asked==2 && unsupported->result==CEF_PERMISSION_RESULT_DISMISS);
 auto stale=std::make_shared<CefPermissionPromptCallback>();
 client.OnShowPermissionPrompt(nullptr,4,"http://localhost:8766",CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS,stale);
 live=false; answer(YES); assert(stale->result==CEF_PERMISSION_RESULT_DISMISS);
 owner.human=NO;
 auto agent=std::make_shared<CefPermissionPromptCallback>();
 client.OnShowPermissionPrompt(nullptr,5,"http://localhost:8766",CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS,agent);
 assert(asked==3 && agent->result==CEF_PERMISSION_RESULT_DENY && visibleErrors==1);
 puts("PASS: real native permission dispatch, explicit approval, nonpersistent refusal, stale reply and agent denial");
} }
`);
  const build=spawnSync('clang++',['-std=c++20','-fobjc-arc','-fblocks','-framework','AppKit',path.join(dir,'fixture.mm'),'-o',path.join(dir,'fixture')],{encoding:'utf8',timeout:60000});
  assert.equal(build.status,0,build.stderr);
  const run=spawnSync(path.join(dir,'fixture'),[],{encoding:'utf8',timeout:10000});
  assert.equal(run.status,0,run.stdout+run.stderr);
});
