#import "MLNBridge.h"

#include <maplibre_native_c.h>

static NSMutableDictionary<NSString *, id> *gLastFailure = nil;

@implementation MLNBridge {
  mln_runtime *_runtime;
  mln_map *_map;
  mln_render_session *_session;
  NSMutableDictionary<NSString *, id> *_diagnostics;
  NSInteger _frameCount;
  double _totalRenderMs;
  double _maxRenderMs;
  NSInteger _steadyFrames;
  double _steadyRenderMs;
  double _steadyMaxMs;
  BOOL _updateAvailable;
  NSInteger _updatesAvailable;
  NSInteger _idleEvents;
  NSInteger _linkRenders;
  NSInteger _skippedTicks;
  NSInteger _cameraRenders;  // renders driven by setCamera, vs the display link's _linkRenders
  BOOL _needsRepaint;
  int64_t _nativeFrames;
  int64_t _drawCalls;
}

+ (NSDictionary<NSString *, id> *)lastFailureDiagnostics {
  return gLastFailure ?: @{};
}

- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                                 scale:(double)scale
                              styleURL:(NSString *)styleURL
                               texture:(id<MTLTexture>)texture {
  self = [super init];
  if (!self) return nil;

  _diagnostics = [NSMutableDictionary dictionary];

  mln_runtime_options runtimeOptions = mln_runtime_options_default();
  runtimeOptions.cache_path = ":memory:";
  mln_status status = mln_runtime_create(&runtimeOptions, &_runtime);
  _diagnostics[@"runtimeCreateStatus"] = @(status);
  if (status != MLN_STATUS_OK) return [self failWith:@"mln_runtime_create"];

  mln_map_options mapOptions = mln_map_options_default();
  mapOptions.width = (uint32_t)width;
  mapOptions.height = (uint32_t)height;
  mapOptions.scale_factor = scale;
  mapOptions.map_mode = MLN_MAP_MODE_CONTINUOUS;
  status = mln_map_create(_runtime, &mapOptions, &_map);
  _diagnostics[@"mapCreateStatus"] = @(status);
  if (status != MLN_STATUS_OK) return [self failWith:@"mln_map_create"];

  status = mln_map_set_style_url(_map, styleURL.UTF8String);
  _diagnostics[@"setStyleStatus"] = @(status);

  mln_camera_options camera = mln_camera_options_default();
  camera.fields = MLN_CAMERA_OPTION_CENTER | MLN_CAMERA_OPTION_ZOOM;
  camera.latitude = 59.437;
  camera.longitude = 24.7536;
  camera.zoom = 13.0;
  status = mln_map_jump_to(_map, &camera);
  _diagnostics[@"jumpToStatus"] = @(status);

  mln_map_request_repaint(_map);

  mln_metal_borrowed_texture_descriptor descriptor =
      mln_metal_borrowed_texture_descriptor_default();
  descriptor.extent.width = (uint32_t)width;
  descriptor.extent.height = (uint32_t)height;
  descriptor.extent.scale_factor = scale;
  descriptor.texture = (__bridge void *)texture;

  status = mln_metal_borrowed_texture_attach(_map, &descriptor, &_session);
  _diagnostics[@"attachStatus"] = @(status);
  if (status != MLN_STATUS_OK) {
    return [self failWith:@"mln_metal_borrowed_texture_attach"];
  }

  return self;
}

- (nullable instancetype)failWith:(NSString *)what {
  _diagnostics[@"error"] = what;
  gLastFailure = [_diagnostics mutableCopy];
  [self shutdown];
  return nil;
}

- (BOOL)setCameraAndRenderLatitude:(double)latitude
                         longitude:(double)longitude
                              zoom:(double)zoom
                           bearing:(double)bearing {
  if (!_map || !_session) return NO;
  mln_camera_options camera = mln_camera_options_default();
  camera.fields = MLN_CAMERA_OPTION_CENTER | MLN_CAMERA_OPTION_ZOOM |
                  MLN_CAMERA_OPTION_BEARING;
  camera.latitude = latitude;
  camera.longitude = longitude;
  camera.zoom = zoom;
  camera.bearing = bearing;
  mln_map_jump_to(_map, &camera);
  mln_map_request_repaint(_map);

  [self pumpEvents];
  BOOL rendered = [self renderNow];
  if (rendered) {
    _cameraRenders++;
    _diagnostics[@"cameraRenders"] = @(_cameraRenders);
  }
  return rendered;
}

- (void)setStyleURL:(NSString *)styleURL {
  if (!_map) return;
  mln_status status = mln_map_set_style_url(_map, styleURL.UTF8String);
  _diagnostics[@"setStyleStatus"] = @(status);
  mln_map_request_repaint(_map);
}

/// Pumps the runtime and drains its event queue into flags and counters.
/// `_updateAvailable` is sticky: set here, cleared only by a successful
/// render. Making it per-tick (the old behaviour) would lose updates that
/// arrive while a render is skipped.
- (void)pumpEvents {
  mln_runtime_run_once(_runtime);

  mln_runtime_event event;
  memset(&event, 0, sizeof(event));
  event.size = (uint32_t)sizeof(event);
  bool hasEvent = false;
  do {
    hasEvent = false;
    if (mln_runtime_poll_event(_runtime, &event, &hasEvent) != MLN_STATUS_OK) break;
    if (!hasEvent) break;

    switch (event.type) {
      case MLN_RUNTIME_EVENT_MAP_RENDER_UPDATE_AVAILABLE:
        _updateAvailable = YES;
        _updatesAvailable++;
        break;

      case MLN_RUNTIME_EVENT_MAP_IDLE:
        _idleEvents++;
        break;

      case MLN_RUNTIME_EVENT_MAP_RENDER_FRAME_FINISHED:
        // needs_repaint is MapLibre asking for another frame — a fade, a
        // symbol transition, a tile still landing. It is the signal that
        // distinguishes "settled" from "mid-animation".
        if (event.payload &&
            event.payload_size >= sizeof(mln_runtime_event_render_frame)) {
          const mln_runtime_event_render_frame *frame = event.payload;
          _needsRepaint = frame->needs_repaint;
          _nativeFrames = frame->stats.frame_count;
          _drawCalls = frame->stats.draw_call_count;
        }
        break;

      case MLN_RUNTIME_EVENT_MAP_LOADING_FAILED:
        _diagnostics[@"loadingFailed"] = @YES;
        if (event.message && event.message_size > 0) {
          _diagnostics[@"loadingFailedMessage"] =
              [[NSString alloc] initWithBytes:event.message
                                       length:event.message_size
                                     encoding:NSUTF8StringEncoding];
        }
        break;

      default:
        break;
    }
  } while (hasEvent);

  _diagnostics[@"updatesAvailable"] = @(_updatesAvailable);
  _diagnostics[@"idleEvents"] = @(_idleEvents);
  _diagnostics[@"needsRepaint"] = @(_needsRepaint);
  _diagnostics[@"nativeFrames"] = @(_nativeFrames);
  _diagnostics[@"drawCalls"] = @(_drawCalls);
}

/// Renders one frame and records timing stats. Returns YES on success.
/// render_update blocks until the GPU finishes (the FFI's texture path calls
/// waitUntilCompleted), so this interval is CPU-record *plus* GPU-execute.
- (BOOL)renderNow {
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  mln_status status = mln_render_session_render_update(_session);
  double elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;

  _diagnostics[@"lastRenderStatus"] = @(status);
  if (status != MLN_STATUS_OK) return NO;

  _updateAvailable = NO;
  _frameCount++;
  _totalRenderMs += elapsedMs;
  if (elapsedMs > _maxRenderMs) _maxRenderMs = elapsedMs;
  // Ignore the first few frames: style load and initial tile upload are not
  // representative of steady state.
  if (_frameCount > 30) {
    _steadyFrames++;
    _steadyRenderMs += elapsedMs;
    if (elapsedMs > _steadyMaxMs) _steadyMaxMs = elapsedMs;
  }
  _diagnostics[@"frameCount"] = @(_frameCount);
  _diagnostics[@"renderMsLast"] = @(round(elapsedMs * 100) / 100);
  _diagnostics[@"renderMsMax"] = @(round(_maxRenderMs * 100) / 100);
  if (_steadyFrames > 0) {
    _diagnostics[@"renderMsAvgSteady"] =
        @(round(_steadyRenderMs / _steadyFrames * 100) / 100);
    _diagnostics[@"renderMsMaxSteady"] = @(round(_steadyMaxMs * 100) / 100);
  }
  return YES;
}

- (BOOL)renderTick {
  if (!_runtime || !_session) return NO;
  [self pumpEvents];

  // The gate. An idle map produces no update events and no repaint request,
  // so a stationary map renders zero frames instead of 120/sec. Fallback if
  // the events prove dishonest on device (spec §2): drop `_updateAvailable`
  // from the condition and gate on `_needsRepaint` alone.
  if (!_updateAvailable && !_needsRepaint) {
    _skippedTicks++;
    _diagnostics[@"skippedTicks"] = @(_skippedTicks);
    return NO;
  }

  BOOL rendered = [self renderNow];
  if (rendered) {
    _linkRenders++;
    _diagnostics[@"linkRenders"] = @(_linkRenders);
  }
  return rendered;
}

- (void)shutdown {
  if (_session) {
    mln_render_session_destroy(_session);
    _session = NULL;
  }
  if (_map) {
    mln_map_destroy(_map);
    _map = NULL;
  }
  if (_runtime) {
    mln_runtime_destroy(_runtime);
    _runtime = NULL;
  }
}

- (NSDictionary<NSString *, id> *)diagnostics {
  return [_diagnostics copy];
}

@end
