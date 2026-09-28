// Compiled with ARC. All private API use is dynamic (NSClassFromString,
// respondsToSelector:), so a changed Xcode fails with an error, not a crash.
#import "SimulatorBridge.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>
#import <objc/runtime.h>

// Wire-format structs, from facebook/idb (MIT): Sources/SimulatorBridge/idb/.
#import "idb/Indigo.h"

// The wire layout idb documents; a mismatch would send garbage to the guest.
_Static_assert(sizeof(IndigoPayload) == 0x90, "IndigoPayload size");
_Static_assert(sizeof(IndigoMessage) == 0xB0, "IndigoMessage size");
_Static_assert(__builtin_offsetof(IndigoMessage, payload) == 0x20, "payload offset");
_Static_assert(__builtin_offsetof(IndigoMessage, payload.event) == 0x30, "event offset");
_Static_assert(__builtin_offsetof(IndigoMessage, payload.event.touch.xRatio) == 0x3C, "xRatio offset");

// SimulatorKit message builders (signatures from idb's SimulatorIndigoHID.swift).
typedef IndigoMessage *(*HMMouseEventFn)(CGPoint *, CGPoint *, uint32_t target, NSUInteger eventType, CGSize, uint32_t edge);
typedef IndigoMessage *(*HMKeyboardFn)(int32_t keyCode, int32_t direction);
typedef IndigoMessage *(*HMButtonFn)(int32_t source, int32_t direction, int32_t target);

@protocol HMPrivHIDClient <NSObject>
- (id)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(IndigoMessage *)message freeWhenDone:(BOOL)free
        completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

// MARK: Private interfaces (declared so the compiler knows the selectors)

@protocol HMPrivSimServiceContext <NSObject>
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
@end

@protocol HMPrivSimDevice <NSObject>
@property (readonly) NSUUID *UDID;
@property (readonly) NSString *name;
@property (readonly) NSString *runtimeIdentifier;
@property (readonly) id io;
@end

@protocol HMPrivIOClient <NSObject>
@property (readonly) NSArray *ioPorts;
@end

@protocol HMPrivPort <NSObject>
- (id)descriptor;
@end

@protocol HMPrivRenderable <NSObject>
@property (readonly) id framebufferSurface;
- (id)state;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id, id))cb;
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(NSArray *))cb;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
@end

@protocol HMPrivDisplayState <NSObject>
@property (readonly) unsigned short displayClass;  // 0 = main display
@end

/// SimDevice.state: 3 = booted. Read via KVC; the display port also has a -state.
static unsigned long long DeviceState(id d) {
  return [[d valueForKey:@"state"] unsignedLongLongValue];
}

static NSError *HMErr(NSString *msg) {
  return [NSError errorWithDomain:@"hypermux.simulator" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// MARK: - HMSimDeviceInfo

@implementation HMSimDeviceInfo
- (instancetype)initWithDevice:(id<HMPrivSimDevice>)d {
  if ((self = [super init])) {
    _udid = d.UDID.UUIDString;
    _name = d.name ?: @"";
    _runtime = [d respondsToSelector:@selector(runtimeIdentifier)] ? d.runtimeIdentifier : @"";
    _booted = DeviceState(d) == 3;
  }
  return self;
}
@end

// MARK: - HMSimulator

@implementation HMSimulator

static NSString *DeveloperDir(void) {
  NSString *env = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (env.length) return env;
  NSTask *t = [NSTask new];
  t.launchPath = @"/usr/bin/xcode-select";
  t.arguments = @[ @"-p" ];
  NSPipe *p = [NSPipe pipe];
  t.standardOutput = p;
  t.standardError = [NSFileHandle fileHandleWithNullDevice];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return nil; }
  NSString *out = [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
  return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

+ (BOOL)loadFrameworksWithError:(NSError **)error {
  static BOOL loaded = NO;
  static NSString *failure = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *dev = DeveloperDir();
    if (!dev.length) { failure = @"no Xcode selected (xcode-select -p)"; return; }
    NSArray *paths = @[
      @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
      [dev stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"],
    ];
    for (NSString *path in paths) {
      if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        failure = [NSString stringWithFormat:@"cannot load %@: %s", path.lastPathComponent, dlerror()];
        return;
      }
    }
    loaded = NSClassFromString(@"SimServiceContext") != nil;
    if (!loaded) failure = @"CoreSimulator has no SimServiceContext";
  });
  if (!loaded && error) *error = HMErr(failure ?: @"cannot load simulator frameworks");
  return loaded;
}

+ (NSArray *)rawDevicesWithError:(NSError **)error {
  if (![self loadFrameworksWithError:error]) return nil;
  Class ctxClass = NSClassFromString(@"SimServiceContext");
  id ctx = [(id<HMPrivSimServiceContext>)ctxClass sharedServiceContextForDeveloperDir:DeveloperDir() error:error];
  if (!ctx) return nil;
  id set = [ctx defaultDeviceSetWithError:error];
  if (!set) return nil;
  return [set respondsToSelector:@selector(devices)] ? [set valueForKey:@"devices"] : @[];
}

+ (NSArray<HMSimDeviceInfo *> *)devicesWithError:(NSError **)error {
  NSArray *raw = [self rawDevicesWithError:error];
  if (!raw) return nil;
  NSMutableArray *out = [NSMutableArray array];
  for (id d in raw) [out addObject:[[HMSimDeviceInfo alloc] initWithDevice:d]];
  return out;
}

@end

// MARK: - HMSimDisplay

@implementation HMSimDisplay {
  id<HMPrivRenderable> _renderable;
  NSUUID *_callbackID;
  BOOL _stopped;
  id _device;
  id _hid;
  dispatch_queue_t _hidQueue;
  HMMouseEventFn _mouseFn;
  HMKeyboardFn _keyboardFn;
  HMButtonFn _buttonFn;
}

- (instancetype)initWithQuery:(NSString *)query error:(NSError **)error {
  if (!(self = [super init])) return nil;
  NSArray *devices = [HMSimulator rawDevicesWithError:error];
  if (!devices) return nil;

  id<HMPrivSimDevice> device = nil;
  NSString *q = query.length ? query : @"booted";
  for (id<HMPrivSimDevice> d in devices) {
    BOOL match = [q isEqualToString:@"booted"] ? DeviceState(d) == 3
               : ([d.UDID.UUIDString caseInsensitiveCompare:q] == NSOrderedSame || [d.name isEqualToString:q]);
    // Prefer a booted match when several devices share a name.
    if (match && (!device || (DeviceState(d) == 3 && DeviceState(device) != 3))) device = d;
  }
  if (!device) { if (error) *error = HMErr([NSString stringWithFormat:@"no simulator matches '%@'", q]); return nil; }
  if (DeviceState(device) != 3) { if (error) *error = HMErr([NSString stringWithFormat:@"'%@' is not booted", device.name]); return nil; }
  _udid = device.UDID.UUIDString;
  _name = device.name;
  _device = device;

  // Find the main display among the device's IO ports.
  id io = [(id)device respondsToSelector:@selector(io)] ? device.io : nil;
  NSArray *ports = [io respondsToSelector:@selector(ioPorts)] ? [(id<HMPrivIOClient>)io ioPorts] : nil;
  for (id port in ports) {
    if (![port respondsToSelector:@selector(descriptor)]) continue;
    id desc = [(id<HMPrivPort>)port descriptor];
    if (![desc respondsToSelector:@selector(framebufferSurface)]) continue;
    if ([desc respondsToSelector:@selector(state)]) {
      id st = [(id<HMPrivRenderable>)desc state];
      if ([st respondsToSelector:@selector(displayClass)] && [(id<HMPrivDisplayState>)st displayClass] != 0) continue;
    }
    _renderable = desc;
    break;
  }
  if (!_renderable) { if (error) *error = HMErr(@"simulator has no main display port (Xcode changed?)"); return nil; }

  _callbackID = [NSUUID UUID];
  __weak HMSimDisplay *weakSelf = self;
  if ([(id)_renderable respondsToSelector:@selector(registerCallbackWithUUID:ioSurfacesChangeCallback:)]) {
    [_renderable registerCallbackWithUUID:_callbackID ioSurfacesChangeCallback:^(id a, id b) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf frameChanged]; });
    }];
  }
  if ([(id)_renderable respondsToSelector:@selector(registerCallbackWithUUID:damageRectanglesCallback:)]) {
    [_renderable registerCallbackWithUUID:_callbackID damageRectanglesCallback:^(NSArray *rects) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf frameChanged]; });
    }];
  }
  return self;
}

// MARK: Input

/// Creates the HID client on first use. Failures are remembered, not retried per event.
- (BOOL)ensureHID {
  if (_hid) return YES;
  if (_inputUnavailableReason) return NO;
  _mouseFn = (HMMouseEventFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
  _keyboardFn = (HMKeyboardFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
  _buttonFn = (HMButtonFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForButton");
  Class cls = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient");
  if (!_mouseFn || !_keyboardFn || !_buttonFn || !cls) {
    _inputUnavailableReason = @"SimulatorKit input functions not found (Xcode changed?)";
    return NO;
  }
  NSError *err = nil;
  @try {
    _hid = [(id<HMPrivHIDClient>)[cls alloc] initWithDevice:_device error:&err];
  } @catch (NSException *e) {
    _inputUnavailableReason = [NSString stringWithFormat:@"HID client threw: %@", e.reason];
    return NO;
  }
  if (!_hid) {
    _inputUnavailableReason = [NSString stringWithFormat:@"no HID client: %@", err.localizedDescription ?: @"unknown"];
    return NO;
  }
  _hidQueue = dispatch_queue_create("hypermux.simulator.hid", DISPATCH_QUEUE_SERIAL);
  return YES;
}

/// Hands a malloc'd message to the client, which frees it.
- (void)send:(IndigoMessage *)message {
  if (!message) return;
  id client = _hid;
  dispatch_queue_t q = _hidQueue;
  dispatch_async(q, ^{
    @try {
      [(id<HMPrivHIDClient>)client sendWithMessage:message freeWhenDone:YES completionQueue:q completion:^(NSError *e) {
        if (e) NSLog(@"hypermux: simulator HID send failed: %@", e);
      }];
    } @catch (NSException *e) {
      NSLog(@"hypermux: simulator HID send threw: %@", e.reason);
    }
  });
}

/// A single-touch message, built like idb's SimulatorIndigoHID.touchMessage: SimulatorKit only
/// builds multi-touch messages, so take its digitizer payload and re-envelope it as single-touch.
- (void)sendTouchAtRatio:(CGPoint)ratio phase:(HMSimTouchPhase)phase edge:(HMSimEdge)edge {
  if (_stopped || ![self ensureHID]) return;
  CGPoint p = CGPointMake(MIN(MAX(ratio.x, 0), 1), MIN(MAX(ratio.y, 0), 1));
  // Moves are successive "down" contacts at the new point; "up" lifts the finger.
  NSUInteger direction = phase == HMSimTouchPhaseUp ? ButtonEventTypeUp : ButtonEventTypeDown;
  IndigoMessage *source = _mouseFn(&p, NULL, ButtonEventTargetDigitizer, direction, CGSizeMake(1, 1), (uint32_t)edge);
  if (!source) return;
  source->payload.event.touch.xRatio = p.x;
  source->payload.event.touch.yRatio = p.y;

  size_t stride = sizeof(IndigoPayload);                      // 0x90
  size_t size = sizeof(IndigoMessage) + sizeof(IndigoPayload);  // 0x140
  uint8_t *dst = calloc(1, size);
  IndigoMessage *msg = (IndigoMessage *)dst;
  msg->innerSize = (unsigned int)sizeof(IndigoPayload);
  msg->eventType = IndigoEventTypeTouch;
  msg->payload.eventKind = 0xB;
  msg->payload.timestamp = mach_absolute_time();
  memcpy(dst + 0x30, ((uint8_t *)source) + 0x30, sizeof(IndigoTouch));
  free(source);
  // Second payload: a copy of the first, marked as the paired contact.
  memcpy(dst + 0x20 + stride, dst + 0x20, stride);
  IndigoPayload *second = (IndigoPayload *)(dst + 0x20 + stride);
  second->event.touch.field1 = 1;
  second->event.touch.field2 = 2;
  [self send:msg];
}

- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down {
  if (_stopped || ![self ensureHID]) return;
  [self send:_keyboardFn((int32_t)usage, down ? ButtonEventTypeDown : ButtonEventTypeUp)];
}

- (void)sendButton:(HMSimButton)button down:(BOOL)down {
  if (_stopped || ![self ensureHID]) return;
  int32_t source = button == HMSimButtonHome ? ButtonEventSourceHomeButton : ButtonEventSourceLock;
  [self send:_buttonFn(source, down ? ButtonEventTypeDown : ButtonEventTypeUp, ButtonEventTargetHardware)];
}

- (IOSurfaceRef)surface {
  if (_stopped) return NULL;
  id s = _renderable.framebufferSurface;
  return (__bridge IOSurfaceRef)s;
}

- (void)frameChanged {
  if (_stopped) return;
  if (self.onFrame) self.onFrame();
}

- (void)stop {
  if (_stopped) return;
  _stopped = YES;
  if ([(id)_renderable respondsToSelector:@selector(unregisterIOSurfacesChangeCallbackWithUUID:)])
    [_renderable unregisterIOSurfacesChangeCallbackWithUUID:_callbackID];
  if ([(id)_renderable respondsToSelector:@selector(unregisterDamageRectanglesCallbackWithUUID:)])
    [_renderable unregisterDamageRectanglesCallbackWithUUID:_callbackID];
  _renderable = nil;
  self.onFrame = nil;
}

- (void)dealloc { [self stop]; }

@end
