#import "MLNBridge.h"

#include <maplibre_native_c.h>

static NSMutableDictionary<NSString *, id> *gLastFailure = nil;

@implementation MLNBridge {
  mln_runtime *_runtime;
  mln_map *_map;
  mln_render_session *_session;
  NSMutableDictionary<NSString *, id> *_diagnostics;
  NSInteger _frameCount;
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

- (BOOL)renderTick {
  if (!_runtime || !_session) return NO;

  mln_runtime_run_once(_runtime);

  // Drain the queue. The spike renders every tick regardless, so the only
  // reason to inspect events is to surface style-loading failures.
  mln_runtime_event event;
  memset(&event, 0, sizeof(event));
  event.size = (uint32_t)sizeof(event);
  bool hasEvent = false;
  do {
    hasEvent = false;
    if (mln_runtime_poll_event(_runtime, &event, &hasEvent) != MLN_STATUS_OK) break;
    if (hasEvent && event.type == MLN_RUNTIME_EVENT_MAP_LOADING_FAILED) {
      _diagnostics[@"loadingFailed"] = @YES;
      if (event.message && event.message_size > 0) {
        _diagnostics[@"loadingFailedMessage"] =
            [[NSString alloc] initWithBytes:event.message
                                     length:event.message_size
                                   encoding:NSUTF8StringEncoding];
      }
    }
  } while (hasEvent);

  mln_status status = mln_render_session_render_update(_session);
  _diagnostics[@"lastRenderStatus"] = @(status);
  if (status == MLN_STATUS_OK) {
    _frameCount++;
    _diagnostics[@"frameCount"] = @(_frameCount);
    return YES;
  }
  return NO;
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
