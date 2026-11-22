import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'model_stream_executor.dart';

/// Runs provider SSE requests in the foreground service's dedicated Flutter
/// engine. The API key crosses the in-process task channel only for the active
/// request; it is never written to a file or notification.
class GenerationProtection {
  GenerationProtection._();

  static const MethodChannel _channel = MethodChannel('com.cwhale/generation');
  static const _channelId = 'cwhale_generation';
  static const _serviceId = 4102;
  static const _readyTimeout = Duration(seconds: 8);
  static const _idleStopDelay = Duration(seconds: 6);
  static const _maxTaskChunkCodeUnits = 48 * 1024;

  static final Map<String, _PendingModelRequest> _pendingRequests = {};
  static int _nextRequestId = 0;
  static int _leases = 0;
  static bool _serviceStarted = false;
  static bool _initialized = false;
  static String? _lastStartError;
  static Completer<void>? _serviceReady;
  static Timer? _stopTimer;
  static Future<void> _operations = Future<void>.value();

  static int get activeLeases => _leases;
  static String? get lastStartError => _lastStartError;

  /// Must run on the UI isolate before the app starts, so the receive port is
  /// registered before Android creates the background Flutter engine.
  static void initialize() {
    if (!Platform.isAndroid || _initialized) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_handleTaskMessage);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: 'Cwhale 回复生成',
        channelDescription: '用户发起的模型回复在后台生成时显示。',
        onlyAlertOnce: true,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // Keep the task service eligible for recovery if Android/OEM policy
        // kills its process while the UI task is in the background.
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
    _initialized = true;
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isServiceRunning() async {
    if (!Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return _serviceStarted;
    }
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('requestBatteryOptimizationExemption');
  }

  static Future<bool> acquire() async {
    if (!Platform.isAndroid) return true;
    initialize();
    var started = false;
    final operation = _operations.then((_) async {
      _stopTimer?.cancel();
      _stopTimer = null;
      if (_leases == 0 || !_serviceStarted) {
        try {
          await _ensureServiceReady();
          _lastStartError = null;
          started = true;
        } catch (error) {
          _serviceStarted = false;
          _lastStartError = error.toString();
        }
      } else {
        started = true;
      }
      if (started) {
        _leases++;
        _serviceStarted = true;
      }
    });
    _operations = operation;
    await operation;
    return started;
  }

  static Future<void> _ensureServiceReady() async {
    _serviceReady = Completer<void>();
    if (!await FlutterForegroundTask.isRunningService) {
      try {
        final permission =
            await FlutterForegroundTask.checkNotificationPermission();
        if (permission == NotificationPermission.denied) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      } catch (_) {
        // Android can still run the foreground task when drawer notifications
        // are denied; the system will show the app under active apps instead.
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Cwhale 正在生成回复',
        notificationText: '切换到其他应用时，回复仍会继续生成。',
        callback: _cwhaleGenerationTaskCallback,
      );
      if (result is ServiceRequestFailure) {
        throw StateError('Android 前台任务启动失败：${result.error}');
      }
    }
    // A running service may belong to a previous activity instance. Ping it
    // and wait for its task isolate before sending request payloads.
    FlutterForegroundTask.sendDataToTask({'type': 'ping'});
    await _serviceReady!.future.timeout(_readyTimeout);
  }

  static Future<ModelTurn> executeRequest({
    required String uri,
    required String apiKey,
    required Map<String, dynamic> body,
    required void Function(String delta) onDelta,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}_${++_nextRequestId}';
    final completer = Completer<ModelTurn>();
    _pendingRequests[id] = _PendingModelRequest(
      completer: completer,
      onDelta: onDelta,
    );
    try {
      final encodedBody = jsonEncode(body);
      final chunks = _splitForTaskChannel(encodedBody);
      FlutterForegroundTask.sendDataToTask({
        'type': 'request_start',
        'requestId': id,
        'uri': uri,
        'apiKey': apiKey,
        'partCount': chunks.length,
      });
      for (var index = 0; index < chunks.length; index++) {
        FlutterForegroundTask.sendDataToTask({
          'type': 'request_part',
          'requestId': id,
          'partIndex': index,
          'data': chunks[index],
        });
      }
      return await completer.future;
    } catch (_) {
      _pendingRequests.remove(id);
      rethrow;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  static List<String> _splitForTaskChannel(String value) {
    final chunks = <String>[];
    final current = StringBuffer();
    var codeUnits = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (codeUnits + character.length > _maxTaskChunkCodeUnits &&
          current.isNotEmpty) {
        chunks.add(current.toString());
        current.clear();
        codeUnits = 0;
      }
      current.write(character);
      codeUnits += character.length;
    }
    if (current.isNotEmpty || chunks.isEmpty) chunks.add(current.toString());
    return chunks;
  }

  static void _handleTaskMessage(Object data) {
    if (data is! Map) return;
    final message = Map<String, dynamic>.from(data);
    final type = message['type'] as String?;
    if (type == 'ready') {
      _serviceStarted = true;
      final ready = _serviceReady;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (type == 'service_destroyed') {
      _serviceStarted = false;
      _serviceReady = null;
      for (final pending in _pendingRequests.values) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(
            StateError('Android 已停止后台生成任务，当前请求已中断。'),
          );
        }
      }
      return;
    }
    final requestId = message['requestId'] as String?;
    if (requestId == null) return;
    final pending = _pendingRequests[requestId];
    if (pending == null) return;
    switch (type) {
      case 'delta':
        final delta = message['delta'];
        if (delta is String && delta.isNotEmpty) pending.onDelta(delta);
        return;
      case 'complete':
        final rawTurn = message['turn'];
        if (rawTurn is Map && !pending.completer.isCompleted) {
          pending.completer.complete(
            ModelTurn.fromTaskJson(Map<String, dynamic>.from(rawTurn)),
          );
        }
        return;
      case 'error':
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(
            Exception(message['message'] as String? ?? '后台模型请求失败。'),
          );
        }
        return;
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    final operation = _operations.then((_) async {
      if (_leases > 0) _leases--;
      if (_leases == 0 && _serviceStarted) _scheduleIdleStop();
    });
    _operations = operation;
    await operation;
  }

  static Future<void> finish({
    required bool completed,
    required int receivedCharacters,
  }) async {
    if (!Platform.isAndroid) return;
    final operation = _operations.then((_) async {
      if (_leases == 0) return;
      if (_leases > 1) {
        _leases--;
        return;
      }
      _leases = 0;
      if (!_serviceStarted) return;
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: completed ? 'Cwhale 回复已完成' : 'Cwhale 回复已中断',
          notificationText: '已接收约 $receivedCharacters 字符。',
        );
      } catch (_) {
        // The task may already have been stopped by Android.
      }
      _scheduleIdleStop();
    });
    _operations = operation;
    await operation;
  }

  static void _scheduleIdleStop() {
    _stopTimer?.cancel();
    _stopTimer = Timer(_idleStopDelay, () {
      final operation = _operations.then((_) async {
        _stopTimer = null;
        if (_leases != 0 || !_serviceStarted) return;
        try {
          await FlutterForegroundTask.stopService();
        } catch (_) {
          // A best-effort service stop must not replace the model result.
        }
        _serviceStarted = false;
        _serviceReady = null;
      });
      _operations = operation;
      unawaited(operation);
    });
  }
}

class _PendingModelRequest {
  const _PendingModelRequest({required this.completer, required this.onDelta});

  final Completer<ModelTurn> completer;
  final void Function(String delta) onDelta;
}

@pragma('vm:entry-point')
void _cwhaleGenerationTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_CwhaleGenerationTaskHandler());
}

class _CwhaleGenerationTaskHandler extends TaskHandler {
  final Map<String, _TaskRequestBuffer> _requests = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.sendDataToMain({'type': 'ready'});
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    FlutterForegroundTask.sendDataToMain({'type': 'service_destroyed'});
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final message = Map<String, dynamic>.from(data);
    switch (message['type']) {
      case 'ping':
        FlutterForegroundTask.sendDataToMain({'type': 'ready'});
        return;
      case 'request_start':
        final id = message['requestId'] as String?;
        final partCount = (message['partCount'] as num?)?.toInt() ?? 0;
        final uri = message['uri'] as String?;
        final apiKey = message['apiKey'] as String?;
        if (id == null ||
            partCount < 1 ||
            uri == null ||
            apiKey == null ||
            partCount > 4096) {
          return;
        }
        _requests[id] = _TaskRequestBuffer(
          uri: uri,
          apiKey: apiKey,
          partCount: partCount,
        );
        return;
      case 'request_part':
        final id = message['requestId'] as String?;
        final request = id == null ? null : _requests[id];
        final index = (message['partIndex'] as num?)?.toInt();
        final part = message['data'];
        if (id == null || request == null || index == null || part is! String) {
          return;
        }
        request.parts[index] = part;
        if (request.parts.length == request.partCount) {
          _requests.remove(id);
          unawaited(_executeRequest(id, request));
        }
        return;
    }
  }

  Future<void> _executeRequest(
    String requestId,
    _TaskRequestBuffer request,
  ) async {
    try {
      final encodedBody = List<String>.generate(
        request.partCount,
        (index) => request.parts[index] ?? '',
      ).join();
      final decoded = jsonDecode(encodedBody);
      if (decoded is! Map) throw const FormatException('模型请求格式无效。');
      final body = Map<String, dynamic>.from(decoded);
      final pendingDelta = StringBuffer();
      var queuedCodeUnits = 0;
      Timer? flushTimer;
      void flushDelta() {
        if (pendingDelta.isEmpty) return;
        FlutterForegroundTask.sendDataToMain({
          'type': 'delta',
          'requestId': requestId,
          'delta': pendingDelta.toString(),
        });
        pendingDelta.clear();
        queuedCodeUnits = 0;
        flushTimer?.cancel();
        flushTimer = null;
      }

      final turn = await ModelStreamExecutor.execute(
        uri: Uri.parse(request.uri),
        apiKey: request.apiKey,
        body: body,
        onDelta: (delta) {
          pendingDelta.write(delta);
          queuedCodeUnits += delta.length;
          if (queuedCodeUnits >= 512) {
            flushDelta();
          } else {
            flushTimer ??= Timer(const Duration(milliseconds: 80), flushDelta);
          }
        },
      );
      flushDelta();
      FlutterForegroundTask.sendDataToMain({
        'type': 'complete',
        'requestId': requestId,
        'turn': turn.toTaskJson(),
      });
    } catch (error) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'requestId': requestId,
        'message': error.toString().replaceFirst('Exception: ', ''),
      });
    }
  }
}

class _TaskRequestBuffer {
  _TaskRequestBuffer({
    required this.uri,
    required this.apiKey,
    required this.partCount,
  });

  final String uri;
  final String apiKey;
  final int partCount;
  final Map<int, String> parts = {};
}
