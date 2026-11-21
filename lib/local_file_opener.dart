import 'package:flutter/services.dart';

class LocalFileOpener {
  static const _channel = MethodChannel('com.cwhale/local_files');

  Future<void> openWith({required String path, required String mimeType}) =>
      _channel.invokeMethod<void>('openWith', {
        'path': path,
        'mimeType': mimeType,
      });

  Future<void> openUrl(String url) =>
      _channel.invokeMethod<void>('openUrl', {'url': url});
}
