// Chromium (CEF) backend for hypermux web tiles. Compiled with ARC.
//
// Browsers are "windowed": CEF puts its own NSView inside a parent view we
// supply, and Chromium composites into it. On macOS that forces CEF's Alloy
// style, which still shows Chrome's passkey (WebAuthn) dialog in its own window.
#import "ChromiumBridge.h"

#include <crt_externs.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
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

@interface HMChromiumBrowser ()
- (void)attach:(CefRefPtr<CefBrowser>)browser;
- (void)detach;
@property (nonatomic) CefRefPtr<CefClient> client;
@end

// MARK: - CefApp

namespace {

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
  // the whole hypermux monitor. Instead finish the close by removing the
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
    NSLog(@"hypermux: failed to load Chromium Embedded Framework");
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
    NSLog(@"hypermux: CefInitialize failed (exit code %d)", CefGetExitCode());
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
  NSView *v = self.browserView;
  // Track the tile's size without a resize callback.
  v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  v.frame = _parentView.bounds;
  if (_pendingURL) {
    [self loadURL:_pendingURL];
    _pendingURL = nil;
  }
}

- (void)detach { _browser = nullptr; }

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
