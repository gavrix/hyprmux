// Objective-C face of the Chromium (CEF) backend. Swift only sees this header;
// all CEF C++ stays in ChromiumBridge.mm.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class HMChromiumBrowser;

@protocol HMChromiumBrowserDelegate <NSObject>
- (void)chromiumBrowser:(HMChromiumBrowser *)browser titleChanged:(NSString *)title;
- (void)chromiumBrowser:(HMChromiumBrowser *)browser addressChanged:(NSString *)url;
- (void)chromiumBrowser:(HMChromiumBrowser *)browser
         loadingChanged:(BOOL)loading
              canGoBack:(BOOL)canGoBack
           canGoForward:(BOOL)canGoForward;
- (void)chromiumBrowser:(HMChromiumBrowser *)browser progressChanged:(double)progress;
/// The page opened a window (window.open, target=_blank). Return a browser made with
/// -initPendingWithParentView: to host it (keeps window.opener), or nil to block it.
- (nullable HMChromiumBrowser *)chromiumBrowser:(HMChromiumBrowser *)browser wantsPopupForURL:(NSString *)url;
/// Cmd+click / middle-click on a link.
- (void)chromiumBrowser:(HMChromiumBrowser *)browser openURLInNewTile:(NSString *)url;
- (void)chromiumBrowserDidCreate:(HMChromiumBrowser *)browser;
- (void)chromiumBrowserGotFocus:(HMChromiumBrowser *)browser;
- (void)chromiumBrowserDidClose:(HMChromiumBrowser *)browser;
@end

/// Process-wide CEF lifecycle. Main thread only.
@interface HMChromium : NSObject
/// Loads the framework and starts CEF. Call after NSApp exists, before the run loop.
/// `switches` are extra Chromium switches ("name" or "name=value").
+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath switches:(NSArray<NSString *> *)switches;
@property (class, readonly) BOOL isRunning;
/// Runs the app's event loop (replaces -[NSApplication run]). Returns after quit.
+ (void)runMessageLoop;
/// Closes every browser, then ends the event loop.
+ (void)closeAllAndQuit;
+ (void)shutdown;
@end

/// NSApplication subclass that CEF requires (it tracks event dispatch).
@interface HMApplication : NSApplication
/// Called instead of the default terminate when CEF is running.
@property (nonatomic, copy, nullable) void (^terminateHandler)(void);
@end

/// One Chromium browser shown as a subview of `parentView`.
@interface HMChromiumBrowser : NSObject
- (instancetype)initWithParentView:(NSView *)parentView url:(NSString *)url;
/// For popups: the browser attaches when Chromium creates it.
- (instancetype)initPendingWithParentView:(NSView *)parentView;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<HMChromiumBrowserDelegate> delegate;
@property (nonatomic, readonly) NSView *parentView;
/// Chromium's own view, once created.
@property (nonatomic, readonly, nullable) NSView *browserView;
@property (nonatomic, readonly) NSString *currentURL;
@property (nonatomic, readonly) BOOL isLoading;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoad;
- (void)showDevTools;
- (void)setFocused:(BOOL)focused;
/// Force-closes the browser. The delegate gets chromiumBrowserDidClose:.
- (void)close;
@end

#ifdef __cplusplus
extern "C" {
#endif
/// Entry point for the helper processes (GPU, renderer, ...).
int HMChromiumHelperMain(int argc, char *_Nonnull *_Nonnull argv);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
