import 'dart:typed_data';

import 'offline_types.dart';

/// Ambient (evictable) cache maintenance operations.
///
/// INVALIDATE is deliberately absent: source check 0.2 in the spec —
/// invalidated rows are withheld from rendering while offline and the
/// offline download path ignores invalidation entirely, so no product path
/// may ever issue it.
enum AmbientCacheOp { reset, pack, clear }

/// The command side of the offline protocol, injectable so the facade's
/// state machine is testable without native code — the same seam discipline
/// as `WorkerLink`.
///
/// Implementations (iOS: direct calls on the renderers' shared runtime,
/// events routed via `FfiBasemapRenderer.runtimeEventHook`; Android: the
/// `fmm_worker` offline mode over a send port) consume every native handle
/// (operation take_result, status snapshots, region lists) on their own
/// side: only the plain-value [OfflineEvent] types cross this boundary.
///
/// Request/response pairing is by caller-generated [requestId]; region-
/// scoped pushes (status, error) carry the native region id instead.
abstract interface class OfflineLink {
  /// Returns false when the native side is unavailable; no events will
  /// follow. After a successful start, every event is delivered to
  /// [onEvent] until [dispose].
  bool start(void Function(OfflineEvent event) onEvent);

  /// Creates a tile-pyramid region. Answered by [OfflineRegionCreated] or
  /// [OfflineOperationFailed]. [metadata] is stored verbatim on the native
  /// region (the facade uses it for group ids).
  void createRegion({
    required int requestId,
    required OfflineRegionDefinition definition,
    required Uint8List metadata,
  });

  /// Answered by [OfflineCommandAcknowledged] or [OfflineOperationFailed];
  /// progress then surfaces as [OfflineRegionStatusChanged].
  void setDownloadState({
    required int requestId,
    required int regionId,
    required bool active,
  });

  /// Opt this region into status events ([OfflineRegionStatusChanged] /
  /// [OfflineRegionErrored]) — the native API is opt-in per region.
  /// Answered by [OfflineCommandAcknowledged] or [OfflineOperationFailed].
  void setObserved({
    required int requestId,
    required int regionId,
    required bool observed,
  });

  /// Answered by [OfflineRegionList] or [OfflineOperationFailed].
  void listRegions({required int requestId});

  /// Answered by [OfflineRegionDeleted] or [OfflineOperationFailed].
  void deleteRegion({required int requestId, required int regionId});

  /// Answered by one [OfflineRegionStatusChanged] for [regionId] (also the
  /// resync path after a missed event) or [OfflineOperationFailed].
  void requestStatus({required int requestId, required int regionId});

  /// Answered by [OfflineAmbientOpCompleted] or [OfflineOperationFailed].
  void ambientOp({required int requestId, required AmbientCacheOp op});

  /// Drains pending native events into [OfflineEvent]s. The facade drives
  /// this on its slow timer while operations are in flight; renderer pumps
  /// may also deliver events at any time (iOS shares the runtime).
  void pump();

  /// After this, no further events are delivered and no method may be
  /// called; in-flight native operations are discarded.
  void dispose();
}

sealed class OfflineEvent {
  const OfflineEvent();
}

class OfflineRegionCreated extends OfflineEvent {
  const OfflineRegionCreated({required this.requestId, required this.regionId});

  final int requestId;
  final int regionId;
}

/// Plain-value mirror of one `mln_offline_region_info`.
class OfflineRegionRecord {
  const OfflineRegionRecord({
    required this.regionId,
    required this.definition,
    required this.metadata,
  });

  final int regionId;
  final OfflineRegionDefinition definition;
  final Uint8List metadata;
}

class OfflineRegionList extends OfflineEvent {
  const OfflineRegionList({required this.requestId, required this.regions});

  final int requestId;
  final List<OfflineRegionRecord> regions;
}

class OfflineRegionDeleted extends OfflineEvent {
  const OfflineRegionDeleted({required this.requestId});

  final int requestId;
}

class OfflineAmbientOpCompleted extends OfflineEvent {
  const OfflineAmbientOpCompleted({required this.requestId});

  final int requestId;
}

/// Success ack for commands whose effect surfaces elsewhere
/// (setDownloadState, setObserved).
class OfflineCommandAcknowledged extends OfflineEvent {
  const OfflineCommandAcknowledged({required this.requestId});

  final int requestId;
}

/// Pushed for observed regions on native status changes, and once in reply
/// to [OfflineLink.requestStatus].
class OfflineRegionStatusChanged extends OfflineEvent {
  const OfflineRegionStatusChanged({
    required this.regionId,
    required this.progress,
    this.requestId,
  });

  /// Set when this is the reply to a [OfflineLink.requestStatus] call.
  final int? requestId;
  final int regionId;
  final OfflineRegionProgress progress;
}

/// A region download hit an error. Downloads generally continue past
/// transient resource errors; [isFatal] marks the ones that stop it (the
/// native tile-count-limit event maps here with [isFatal] true).
class OfflineRegionErrored extends OfflineEvent {
  const OfflineRegionErrored({
    required this.regionId,
    required this.message,
    required this.isFatal,
  });

  final int regionId;
  final String message;
  final bool isFatal;
}

/// Terminal failure of a request-scoped command.
class OfflineOperationFailed extends OfflineEvent {
  const OfflineOperationFailed({
    required this.requestId,
    required this.message,
  });

  final int requestId;
  final String message;
}
