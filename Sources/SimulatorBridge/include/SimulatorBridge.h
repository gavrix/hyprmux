// iOS Simulator displays for hyprmux tiles, via Xcode's private CoreSimulator
// and SimulatorKit frameworks (the same route idb and Radon IDE use).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

@interface HMSimDeviceInfo : NSObject
@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *runtime;
@property (nonatomic, readonly) BOOL booted;
@end

@interface HMSimulator : NSObject
/// Loads CoreSimulator + SimulatorKit from the selected Xcode. Idempotent.
+ (BOOL)loadFrameworksWithError:(NSError **)error;
+ (nullable NSArray<HMSimDeviceInfo *> *)devicesWithError:(NSError **)error;
@end

typedef NS_ENUM(NSInteger, HMSimTouchPhase) {
  HMSimTouchPhaseDown = 0,
  HMSimTouchPhaseMove = 1,
  HMSimTouchPhaseUp = 2,
};

/// Where a touch started, for system edge gestures (home swipe, Notification Center, back).
typedef NS_ENUM(uint32_t, HMSimEdge) {
  HMSimEdgeNone = 0,
  HMSimEdgeTop = 1,
  HMSimEdgeLeft = 2,
  HMSimEdgeBottom = 3,
  HMSimEdgeRight = 4,
};

typedef NS_ENUM(NSInteger, HMSimButton) {
  HMSimButtonHome = 0,
  HMSimButtonLock = 1,
};

/// Live main display of one booted simulator.
@interface HMSimDisplay : NSObject
/// `query` is a UDID, a device name, or "booted" (first booted device).
- (nullable instancetype)initWithQuery:(NSString *)query error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
/// Current framebuffer. Replaced when the display changes (rotation, resize).
@property (nonatomic, readonly, nullable) IOSurfaceRef surface;
/// Main thread. Called when pixels change or the surface is replaced.
@property (nonatomic, copy, nullable) void (^onFrame)(void);

- (void)stop;

// MARK: Input (sent to the device's HID service; Simulator.app is not involved)

/// Single-finger touch. `ratio` is 0...1 from the screen's top-left. `edge` tags every
/// event of a touch that began at a screen edge; iOS reads system gestures from it.
- (void)sendTouchAtRatio:(CGPoint)ratio phase:(HMSimTouchPhase)phase edge:(HMSimEdge)edge;
/// Keyboard key by USB HID usage (keyboard page 0x07), e.g. 0x04 = 'a', 0xE1 = left shift.
- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down;
- (void)sendButton:(HMSimButton)button down:(BOOL)down;
/// Set when input can't be delivered (e.g. SimulatorKit changed); nil when input works.
@property (nonatomic, readonly, nullable) NSString *inputUnavailableReason;
@end

NS_ASSUME_NONNULL_END
