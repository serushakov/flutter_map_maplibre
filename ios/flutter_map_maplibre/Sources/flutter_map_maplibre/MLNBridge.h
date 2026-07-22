#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper over maplibre-native-ffi's C API.
///
/// Exists because importing the C headers into Swift as a module fights
/// Xcode's explicitly-built modules. Objective-C can `#include` them directly,
/// and CocoaPods exposes this class to Swift through the pod's umbrella header
/// with no modulemap involved.
@interface MLNBridge : NSObject

/// Creates the runtime, map and render session, targeting `texture`.
/// Returns nil if any step fails; inspect `diagnostics` on the returned object
/// only when non-nil, otherwise use `+lastFailureDiagnostics`.
- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                                 scale:(double)scale
                              styleURL:(NSString *)styleURL
                               texture:(id<MTLTexture>)texture;

/// Pumps the run loop, drains events, renders one frame.
/// Returns YES if a frame was rendered.
- (BOOL)renderTick;

/// Moves the camera. Called from Dart as the flutter_map camera changes; the
/// residual transform on the Flutter side covers the frames of lag between
/// this landing and the next render.
- (void)setCameraLatitude:(double)latitude
                longitude:(double)longitude
                     zoom:(double)zoom
                  bearing:(double)bearing;

/// Swaps the style without tearing down the map or the render session.
- (void)setStyleURL:(NSString *)styleURL;

- (void)shutdown;

@property(nonatomic, readonly) NSDictionary<NSString *, id> *diagnostics;

/// Diagnostics from the most recent failed init.
+ (NSDictionary<NSString *, id> *)lastFailureDiagnostics;

@end

NS_ASSUME_NONNULL_END
