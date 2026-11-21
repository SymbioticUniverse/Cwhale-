import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the Android process important while a user-requested model response
/// is streaming. Requests still run in the Flutter client and go directly to
/// the selected provider; this class only controls a local Android service.
class GenerationProtection {
  GenerationProtection._();

  static const MethodChannel _channel = MethodChannel('com.cwhale/generation');

  static int _leases = 0;
  static bool _serviceStarted = false;
  static String? _lastStartError;
  static Future<void> _operations = Future<void>.value();

  static int get activeLeases => _leases;
  static String? get lastStartError => _lastStartError;

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

  static Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('requestBatteryOptimizationExemption');
  }

  static Future<bool> acquire() async {
    if (!Platform.isAndroid) return true;
    var started = false;
    final operation = _operations.then((_) async {
      if (_leases == 0) {
        try {
          await _channel.invokeMethod<void>('start');
          _serviceStarted = true;
          _lastStartError = null;
          started = true;
        } on PlatformException catch (error) {
          _serviceStarted = false;
          _lastStartError = error.message ?? error.code;
        } on MissingPluginException catch (error) {
          _serviceStarted = false;
          _lastStartError = error.message;
        } catch (error) {
          _serviceStarted = false;
          _lastStartError = error.toString();
        }
      } else {
        started = _serviceStarted;
      }
      if (started) _leases++;
    });
    _operations = operation;
    await operation;
    return started;
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    final operation = _operations.then((_) async {
      if (_leases > 0) _leases--;
      if (_leases == 0 && _serviceStarted) {
        _serviceStarted = false;
        try {
          await _channel.invokeMethod<void>('stop');
        } on PlatformException {
          // The service may already have been stopped by Android.
        } on MissingPluginException {
          // Older or non-Android embeddings do not expose the channel.
        } catch (_) {
          // A best-effort service stop must not fail the model response.
        }
      }
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
      if (_serviceStarted) {
        try {
          final detached = await _channel.invokeMethod<bool>('complete', {
            'completed': completed,
            'receivedCharacters': receivedCharacters,
          });
          if (detached != true) {
            await _channel.invokeMethod<void>('stop');
          }
        } catch (_) {
          try {
            await _channel.invokeMethod<void>('stop');
          } catch (_) {
            // Best-effort shutdown must not replace the model result.
          }
        }
      }
      _leases = 0;
      _serviceStarted = false;
    });
    _operations = operation;
    await operation;
  }
}
