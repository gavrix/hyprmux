// Chromium (CEF) backend for hyprmux web tiles. Compiled with ARC.
//
// Browsers are "windowed": CEF puts its own NSView inside a parent view we
// supply, and Chromium composites into it. On macOS that forces CEF's Alloy
// style, which still shows Chrome's passkey (WebAuthn) dialog in its own window.
#import "ChromiumBridge.h"
#import <QuartzCore/QuartzCore.h>

#include <climits>
#include <crt_externs.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_values.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

static BOOL gRunning = NO;
static BOOL gQuitting = NO;
static int gBrowserCount = 0;
/// Browsers must be released before CefShutdown; we keep them alive until closed.
static NSMutableSet<HMChromiumBrowser *> *gLive;
static CefScopedLibraryLoader *gLoader = nullptr;

static NSString *NS(const CefString &s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}

typedef NS_ENUM(NSInteger, HMCredentialDevToolsStage) {
  HMCredentialDevToolsStageFrameTree,
  HMCredentialDevToolsStageIsolatedWorld,
  HMCredentialDevToolsStageFunction,
};

@interface HMCredentialCall : NSObject
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSDictionary<NSString *, id> *argument;
@property(nonatomic, copy, nullable) void (^completion)(id _Nullable, NSString *_Nullable);
@property(nonatomic) HMCredentialDevToolsStage stage;
@end
@implementation HMCredentialCall
@end

@interface HMChromiumBrowser ()
- (void)attach:(CefRefPtr<CefBrowser>)browser;
- (void)detach;
- (void)devToolsMethodResult:(int)messageID success:(BOOL)success data:(NSData *)data;
- (void)devToolsAgentDetached;
- (BOOL)executeCredentialMethod:(NSString *)method params:(CefRefPtr<CefDictionaryValue>)params
                           call:(HMCredentialCall *)call stage:(HMCredentialDevToolsStage)stage;
- (void)finishCredentialCall:(HMCredentialCall *)call value:(nullable id)value error:(nullable NSString *)error;
- (void)failAllCredentialCalls:(NSString *)error;
@property (nonatomic) CefRefPtr<CefClient> client;
@end

// MARK: - CefApp

namespace {

/// Converts only JSON-compatible Foundation values. Credential arguments never
/// pass through a JSON string, which keeps their values out of source text.
static CefRefPtr<CefValue> CefValueFromFoundation(id object) {
  CefRefPtr<CefValue> result = CefValue::Create();
  if (!object || object == [NSNull null]) {
    result->SetNull();
  } else if ([object isKindOfClass:[NSString class]]) {
    result->SetString([(NSString *)object UTF8String]);
  } else if ([object isKindOfClass:[NSNumber class]]) {
    NSNumber *number = object;
    if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
      result->SetBool(number.boolValue);
    } else if (CFNumberIsFloatType((__bridge CFNumberRef)number)) {
      result->SetDouble(number.doubleValue);
    } else {
      long long value = number.longLongValue;
      if (value >= INT_MIN && value <= INT_MAX) result->SetInt((int)value);
      else result->SetDouble(number.doubleValue);
    }
  } else if ([object isKindOfClass:[NSDictionary class]]) {
    CefRefPtr<CefDictionaryValue> dictionary = CefDictionaryValue::Create();
    for (id key in (NSDictionary *)object) {
      if (![key isKindOfClass:[NSString class]]) return nullptr;
      CefRefPtr<CefValue> value = CefValueFromFoundation([(NSDictionary *)object objectForKey:key]);
      if (!value || !dictionary->SetValue([(NSString *)key UTF8String], value)) return nullptr;
    }
    result->SetDictionary(dictionary);
  } else if ([object isKindOfClass:[NSArray class]]) {
    NSArray *array = object;
    CefRefPtr<CefListValue> list = CefListValue::Create();
    list->SetSize(array.count);
    for (NSUInteger i = 0; i < array.count; i++) {
      CefRefPtr<CefValue> value = CefValueFromFoundation(array[i]);
      if (!value || !list->SetValue(i, value)) return nullptr;
    }
    result->SetList(list);
  } else {
    return nullptr;
  }
  return result;
}

class HMCredentialDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit HMCredentialDevToolsObserver(HMChromiumBrowser *owner) : owner_(owner) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                              const void *result, size_t result_size) override {
    HMChromiumBrowser *owner = owner_;
    if (!owner) return;
    NSData *data = result && result_size ? [NSData dataWithBytes:result length:result_size] : [NSData data];
    [owner devToolsMethodResult:message_id success:success data:data];
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    HMChromiumBrowser *owner = owner_;
    [owner devToolsAgentDetached];
  }

 private:
  __weak HMChromiumBrowser *owner_;
  IMPLEMENT_REFCOUNTING(HMCredentialDevToolsObserver);
};

class HMApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit HMApp(NSArray<NSString *> *switches) : switches_(switches) {}

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    // Ad-hoc signed builds change identity each build; a real keychain item
    // would prompt every time. Cookies still persist on disk.
    command_line->AppendSwitch("use-mock-keychain");
    for (NSString *sw in switches_) {
      NSRange eq = [sw rangeOfString:@"="];
      if (eq.location == NSNotFound) {
        command_line->AppendSwitch(sw.UTF8String);
      } else {
        command_line->AppendSwitchWithValue([sw substringToIndex:eq.location].UTF8String,
                                            [sw substringFromIndex:eq.location + 1].UTF8String);
      }
    }
  }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

 private:
  NSArray<NSString *> *switches_;
  IMPLEMENT_REFCOUNTING(HMApp);
};

// MARK: - CefClient: forwards callbacks to the Objective-C browser object.

class HMClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefDisplayHandler,
                 public CefLoadHandler,
                 public CefFocusHandler,
                 public CefRequestHandler {
 public:
  explicit HMClient(HMChromiumBrowser *owner) : owner_(owner) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // Life span

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    gBrowserCount++;
    HMChromiumBrowser *o = owner_;
    [o attach:browser];
    [o.delegate chromiumBrowserDidCreate:o];
  }

  // Returning false would send performClose: to the top-level window, which is
  // the whole hyprmux monitor. Instead finish the close by removing the
  // browser's view; CEF destroys the browser and calls OnBeforeClose.
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    NSView *v = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [v removeFromSuperview]; });
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    gBrowserCount--;
    HMChromiumBrowser *o = owner_;
    [o detach];
    [o.delegate chromiumBrowserDidClose:o];
    if (o) [gLive removeObject:o];
    if (gQuitting && gBrowserCount <= 0) CefQuitMessageLoop();
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString &target_url, const CefString &target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo,
                     CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra_info, bool *no_javascript_access) override {
    HMChromiumBrowser *o = owner_;
    HMChromiumBrowser *popup = [o.delegate chromiumBrowser:o wantsPopupForURL:NS(target_url)];
    if (!popup) return true;  // blocked
    NSRect b = popup.parentView.bounds;
    windowInfo.SetAsChild((__bridge void *)popup.parentView,
                          CefRect(0, 0, (int)b.size.width, (int)b.size.height));
    client = popup.client;
    return false;
  }

  // Display

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowser:o titleChanged:NS(title)];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (!frame->IsMain()) return;
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowser:o addressChanged:NS(url)];
  }

  void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString &value) override {
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowser:o statusMessageChanged:NS(value)];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowser:o progressChanged:progress];
  }

  // Load

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                            bool canGoForward) override {
    loading_ = isLoading;
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowser:o loadingChanged:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }

  // Focus

  void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
    HMChromiumBrowser *o = owner_;
    [o.delegate chromiumBrowserGotFocus:o];
  }

  // Chromium focuses a page when it loads. Returning true cancels that.
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
    if (source != FOCUS_SOURCE_NAVIGATION) return false;
    HMChromiumBrowser *o = owner_;
    return ![o.delegate chromiumBrowserShouldTakeNavigationFocus:o];
  }

  // Request

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString &target_url, WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    if (target_disposition == CEF_WOD_NEW_FOREGROUND_TAB || target_disposition == CEF_WOD_NEW_BACKGROUND_TAB ||
        target_disposition == CEF_WOD_NEW_WINDOW) {
      HMChromiumBrowser *o = owner_;
      [o.delegate chromiumBrowser:o openURLInNewTile:NS(target_url)];
      return true;
    }
    return false;
  }

  bool loading() const { return loading_; }

 private:
  __weak HMChromiumBrowser *owner_;
  bool loading_ = false;
  IMPLEMENT_REFCOUNTING(HMClient);
};

}  // namespace

// MARK: - HMApplication

@interface HMApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation HMApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)v { _handlingSendEvent = v; }

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  if (gRunning && self.terminateHandler) {
    // Browsers must close before the loop ends; the handler calls +closeAllAndQuit.
    self.terminateHandler();
    return;
  }
  [super terminate:sender];
}
@end

// MARK: - HMChromium

@implementation HMChromium

+ (BOOL)isRunning { return gRunning; }

+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath switches:(NSArray<NSString *> *)switches {
  if (gRunning) return YES;
  gLoader = new CefScopedLibraryLoader();
  if (!gLoader->LoadInMain()) {
    NSLog(@"hyprmux: failed to load Chromium Embedded Framework");
    return NO;
  }
  gLive = [NSMutableSet set];

  CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  settings.no_sandbox = true;
  settings.persist_session_cookies = true;
  [[NSFileManager defaultManager] createDirectoryAtPath:rootCachePath withIntermediateDirectories:YES
                                             attributes:nil error:nil];
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  CefString(&settings.cache_path) = [rootCachePath stringByAppendingPathComponent:@"Default"].UTF8String;
  settings.log_severity = LOGSEVERITY_WARNING;

  CefRefPtr<HMApp> app(new HMApp(switches));
  if (!CefInitialize(args, settings, app.get(), nullptr)) {
    NSLog(@"hyprmux: CefInitialize failed (exit code %d)", CefGetExitCode());
    return NO;
  }
  gRunning = YES;
  return YES;
}

+ (void)runMessageLoop { CefRunMessageLoop(); }

+ (void)closeAllAndQuit {
  gQuitting = YES;
  if (gBrowserCount <= 0) {
    CefQuitMessageLoop();
    return;
  }
  for (HMChromiumBrowser *b in [gLive copy]) [b close];
}

+ (void)shutdown {
  if (!gRunning) return;
  [gLive removeAllObjects];
  CefShutdown();
  gRunning = NO;
}

@end

// MARK: - HMChromiumBrowser

@implementation HMChromiumBrowser {
  CefRefPtr<CefBrowser> _browser;
  NSString *_pendingURL;
  CefRefPtr<HMCredentialDevToolsObserver> _devToolsObserver;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber *, HMCredentialCall *> *_credentialCallsByMessageID;
  NSMutableSet<HMCredentialCall *> *_credentialCalls;
  int _nextDevToolsMessageID;
}

- (instancetype)initPendingWithParentView:(NSView *)parentView {
  if ((self = [super init])) {
    _parentView = parentView;
    _client = new HMClient(self);
    [gLive addObject:self];
  }
  return self;
}

- (instancetype)initWithParentView:(NSView *)parentView url:(NSString *)url {
  if ((self = [self initPendingWithParentView:parentView])) {
    NSRect b = parentView.bounds;
    CefWindowInfo info;
    info.SetAsChild((__bridge void *)parentView, CefRect(0, 0, (int)b.size.width, (int)b.size.height));
    CefBrowserSettings bs;
    CefBrowserHost::CreateBrowser(info, _client, url.UTF8String ?: "", bs, nullptr, nullptr);
  }
  return self;
}

- (void)attach:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  // Sized by -layoutInParent, not autoresizing (see there).
  self.browserView.autoresizingMask = NSViewNotSizable;
  [self layoutInParent];
  if (_pendingURL) {
    [self loadURL:_pendingURL];
    _pendingURL = nil;
  }
}

// AppKit and Core Animation round autoresized sizes, and Chromium's own views
// and its compositor layer follow the browser view by size deltas. With
// fractional tile sizes (floating resize) the rounding errors add up: the page
// layer ends up
// taller than its view, so the page draws shifted up while clicks land where
// the view is. So: whole points, every level set explicitly, nothing autoresized.
- (void)layoutInParent {
  NSView *v = self.browserView;
  if (!v) return;
  NSRect b = _parentView.bounds;
  NSRect target = NSMakeRect(0, 0, round(NSWidth(b)), round(NSHeight(b)));
  if (!NSEqualRects(v.frame, target)) v.frame = target;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self fillSubviewsOf:v depth:0];
  [CATransaction commit];
}

/// CefBrowserHostView > WebContentsViewCocoa > RenderWidgetHostViewCocoa: each
/// fills its parent. The render view's layer holds a flipped, autoresizing
/// sublayer (ui::DisplayCALayerTree) that must fill it too.
- (void)fillSubviewsOf:(NSView *)view depth:(int)depth {
  if (depth > 2) return;
  for (NSView *sub in view.subviews) {
    if (!NSEqualRects(sub.frame, view.bounds)) sub.frame = view.bounds;
    CALayer *layer = sub.layer;
    for (CALayer *l in layer.sublayers) {
      if (l.autoresizingMask == (kCALayerWidthSizable | kCALayerHeightSizable) &&
          !CGRectEqualToRect(l.frame, layer.bounds)) {
        l.frame = layer.bounds;
      }
    }
    [self fillSubviewsOf:sub depth:depth + 1];
  }
}

- (void)detach {
  [self failAllCredentialCalls:@"The Chromium browser closed before credential filling completed."];
  _devToolsRegistration = nullptr;
  _devToolsObserver = nullptr;
  _browser = nullptr;
}

- (NSView *)browserView {
  if (!_browser) return nil;
  return (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
}

- (NSString *)currentURL {
  if (!_browser) return _pendingURL ?: @"";
  return NS(_browser->GetMainFrame()->GetURL());
}

- (BOOL)isLoading { return _browser ? _browser->IsLoading() : NO; }

- (void)loadURL:(NSString *)url {
  if (!_browser) {
    _pendingURL = url;
    return;
  }
  _browser->GetMainFrame()->LoadURL(url.UTF8String);
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stopLoad { if (_browser) _browser->StopLoad(); }

- (void)showDevTools {
  if (!_browser) return;
  CefWindowInfo info;
  CefBrowserSettings bs;
  _browser->GetHost()->ShowDevTools(info, nullptr, bs, CefPoint());
}

- (void)setFocused:(BOOL)focused {
  if (_browser) _browser->GetHost()->SetFocus(focused);
}

- (void)callIsolatedFunction:(NSString *)source
                    argument:(NSDictionary<NSString *, id> *)argument
                     timeout:(NSTimeInterval)timeout
                  completion:(void (^)(id _Nullable, NSString *_Nullable))completion {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self callIsolatedFunction:source argument:argument timeout:timeout completion:completion];
    });
    return;
  }
  if (!_browser || !_browser->IsValid()) {
    completion(nil, @"The Chromium browser is not available.");
    return;
  }
  // Reject unsupported Foundation values before creating a DevTools world.
  if (!CefValueFromFoundation(argument)) {
    completion(nil, @"The credential function argument is not JSON-compatible.");
    return;
  }
  if (!_devToolsObserver) {
    _devToolsObserver = new HMCredentialDevToolsObserver(self);
    _devToolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_devToolsObserver);
    if (!_devToolsRegistration) {
      _devToolsObserver = nullptr;
      completion(nil, @"Chromium could not attach its credential execution context.");
      return;
    }
  }
  if (!_credentialCalls) _credentialCalls = [NSMutableSet set];
  if (!_credentialCallsByMessageID) _credentialCallsByMessageID = [NSMutableDictionary dictionary];

  HMCredentialCall *call = [HMCredentialCall new];
  call.source = [source copy];
  call.argument = [argument copy];
  call.completion = [completion copy];
  [_credentialCalls addObject:call];

  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  if (![self executeCredentialMethod:@"Page.getFrameTree" params:params call:call
                                stage:HMCredentialDevToolsStageFrameTree]) {
    [self finishCredentialCall:call value:nil error:@"Chromium could not inspect the page frame."];
    return;
  }

  __weak HMChromiumBrowser *weakSelf = self;
  __weak HMCredentialCall *weakCall = call;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, timeout) * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    HMChromiumBrowser *self = weakSelf;
    HMCredentialCall *call = weakCall;
    if (self && call && [self->_credentialCalls containsObject:call]) {
      [self finishCredentialCall:call value:nil error:@"Chromium credential execution timed out."];
    }
  });
}

- (BOOL)executeCredentialMethod:(NSString *)method params:(CefRefPtr<CefDictionaryValue>)params
                           call:(HMCredentialCall *)call stage:(HMCredentialDevToolsStage)stage {
  if (!_browser || !_browser->IsValid()) return NO;
  if (_nextDevToolsMessageID <= 0) _nextDevToolsMessageID = 1;
  int messageID = _nextDevToolsMessageID++;
  call.stage = stage;
  _credentialCallsByMessageID[@(messageID)] = call;
  int submitted = _browser->GetHost()->ExecuteDevToolsMethod(messageID, method.UTF8String, params);
  if (submitted == 0) {
    [_credentialCallsByMessageID removeObjectForKey:@(messageID)];
    return NO;
  }
  return YES;
}

- (void)devToolsMethodResult:(int)messageID success:(BOOL)success data:(NSData *)data {
  HMCredentialCall *call = _credentialCallsByMessageID[@(messageID)];
  if (!call) return;
  [_credentialCallsByMessageID removeObjectForKey:@(messageID)];
  if (!success) {
    [self finishCredentialCall:call value:nil error:@"A Chromium credential protocol method failed."];
    return;
  }

  NSError *parseError = nil;
  id value = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
  NSDictionary *result = [value isKindOfClass:[NSDictionary class]] ? value : nil;
  if (!result || parseError) {
    [self finishCredentialCall:call value:nil error:@"Chromium returned an invalid credential protocol result."];
    return;
  }

  if (call.stage == HMCredentialDevToolsStageFrameTree) {
    NSDictionary *frameTree = [result[@"frameTree"] isKindOfClass:[NSDictionary class]] ? result[@"frameTree"] : nil;
    NSDictionary *frame = [frameTree[@"frame"] isKindOfClass:[NSDictionary class]] ? frameTree[@"frame"] : nil;
    NSString *frameID = [frame[@"id"] isKindOfClass:[NSString class]] ? frame[@"id"] : nil;
    if (!frameID.length) {
      [self finishCredentialCall:call value:nil error:@"Chromium did not return the main page frame."];
      return;
    }
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("frameId", frameID.UTF8String);
    params->SetString("worldName", "hyprmux-credentials");
    if (![self executeCredentialMethod:@"Page.createIsolatedWorld" params:params call:call
                                  stage:HMCredentialDevToolsStageIsolatedWorld]) {
      [self finishCredentialCall:call value:nil error:@"Chromium could not create an isolated credential world."];
    }
    return;
  }

  if (call.stage == HMCredentialDevToolsStageIsolatedWorld) {
    NSNumber *contextID = [result[@"executionContextId"] isKindOfClass:[NSNumber class]]
        ? result[@"executionContextId"] : nil;
    if (!contextID) {
      [self finishCredentialCall:call value:nil error:@"Chromium did not return a credential execution context."];
      return;
    }
    CefRefPtr<CefValue> argumentValue = CefValueFromFoundation(call.argument);
    // The argument may hold a revealed secret. Keep it only in the outgoing params.
    call.argument = @{};
    if (!argumentValue) {
      [self finishCredentialCall:call value:nil error:@"The credential function argument is not JSON-compatible."];
      return;
    }
    CefRefPtr<CefDictionaryValue> callArgument = CefDictionaryValue::Create();
    callArgument->SetValue("value", argumentValue);
    CefRefPtr<CefListValue> arguments = CefListValue::Create();
    arguments->SetSize(1);
    arguments->SetDictionary(0, callArgument);

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("functionDeclaration", call.source.UTF8String);
    params->SetInt("executionContextId", contextID.intValue);
    params->SetList("arguments", arguments);
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    params->SetBool("silent", true);
    if (![self executeCredentialMethod:@"Runtime.callFunctionOn" params:params call:call
                                  stage:HMCredentialDevToolsStageFunction]) {
      [self finishCredentialCall:call value:nil error:@"Chromium could not execute the credential function."];
    }
    return;
  }

  if (result[@"exceptionDetails"] && result[@"exceptionDetails"] != [NSNull null]) {
    [self finishCredentialCall:call value:nil error:@"The Chromium credential function threw an exception."];
    return;
  }
  NSDictionary *remoteObject = [result[@"result"] isKindOfClass:[NSDictionary class]] ? result[@"result"] : nil;
  if (!remoteObject) {
    [self finishCredentialCall:call value:nil error:@"Chromium returned no credential function result."];
    return;
  }
  [self finishCredentialCall:call value:remoteObject[@"value"] error:nil];
}

- (void)devToolsAgentDetached {
  [self failAllCredentialCalls:@"Chromium's credential execution context detached."];
}

- (void)finishCredentialCall:(HMCredentialCall *)call value:(id)value error:(NSString *)error {
  if (![_credentialCalls containsObject:call]) return;
  [_credentialCalls removeObject:call];
  NSArray<NSNumber *> *messageIDs = [_credentialCallsByMessageID allKeysForObject:call];
  [_credentialCallsByMessageID removeObjectsForKeys:messageIDs];
  void (^completion)(id, NSString *) = call.completion;
  call.completion = nil;
  if (completion) completion(value, error);
}

- (void)failAllCredentialCalls:(NSString *)error {
  for (HMCredentialCall *call in [_credentialCalls copy]) {
    [self finishCredentialCall:call value:nil error:error];
  }
}

- (void)close {
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
  } else {
    [gLive removeObject:self];
    [self.delegate chromiumBrowserDidClose:self];
  }
}

@end

// MARK: - Helper processes

int HMChromiumHelperMain(int argc, char **argv) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
