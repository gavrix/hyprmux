// iOS Simulator displays for hypermux tiles, via Xcode's private CoreSimulator
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
@end

NS_ASSUME_NONNULL_END
