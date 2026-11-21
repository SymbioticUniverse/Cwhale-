import 'dart:io';

import 'chat_models.dart';
import 'generation_protection.dart';
import 'model_stream_executor.dart';

export 'model_stream_executor.dart' show ModelToolCall, ModelTurn;

class DirectModelClient {
  static Uri completionUri(String baseUrl) {
    final base = Uri.parse(baseUrl.trim());
    var path = base.path.replaceFirst(RegExp(r'/+$'), '');
    if (!path.endsWith('/chat/completions')) {
      path = '$path/chat/completions';
    }
    return base.replace(path: path);
  }

  Future<ModelTurn> streamReply({
    required ModelSettings settings,
    required List<Map<String, dynamic>> messages,
    required void Function(String delta) onDelta,
    List<Map<String, dynamic>>? tools,
    bool deepThinking = false,
    String thinkingMode = 'default',
  }) async {
    if (settings.apiKey.trim().isEmpty) {
      throw const FormatException('请先填写模型 API Key。');
    }
    if (settings.model.trim().isEmpty) {
      throw const FormatException('请先填写模型名称。');
    }

    final outboundMessages = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList();
    final globalSystemPrompt = settings.globalSystemPrompt.trim();
    if (globalSystemPrompt.isNotEmpty) {
      final firstSystemMessage = outboundMessages.indexWhere(
        (message) => message['role'] == 'system',
      );
      if (firstSystemMessage >= 0) {
        final currentContent =
            outboundMessages[firstSystemMessage]['content']?.toString() ?? '';
        outboundMessages[firstSystemMessage]['content'] =
            '$globalSystemPrompt\n\n$currentContent';
      } else {
        outboundMessages.insert(0, {
          'role': 'system',
          'content': globalSystemPrompt,
        });
      }
    }
    if (settings.injectLocalTimestamp) {
      outboundMessages.insert(0, {
        'role': 'system',
        'content': _localTimeInstruction(DateTime.now()),
      });
    }

    final body = <String, dynamic>{
      'model': settings.model.trim(),
      'stream': true,
      'stream_options': {'include_usage': true},
      'messages': outboundMessages,
    };
    if (settings.supportsThinkingToggle && thinkingMode != 'default') {
      body['thinking'] = {
        'type': thinkingMode == 'off' ? 'disabled' : 'enabled',
      };
    }
    if (settings.supportsThinkingLevels &&
        const {'low', 'medium', 'high'}.contains(thinkingMode)) {
      body['reasoning_effort'] = thinkingMode;
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    final backgroundProtected = await GenerationProtection.acquire();
    try {
      if (Platform.isAndroid && backgroundProtected) {
        return await GenerationProtection.executeRequest(
          uri: completionUri(settings.baseUrl).toString(),
          apiKey: settings.apiKey.trim(),
          body: body,
          onDelta: onDelta,
        );
      }
      return await ModelStreamExecutor.execute(
        uri: completionUri(settings.baseUrl),
        apiKey: settings.apiKey.trim(),
        body: body,
        onDelta: onDelta,
      );
    } finally {
      if (backgroundProtected) await GenerationProtection.release();
    }
  }

  String _localTimeInstruction(DateTime now) {
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    final hoursText = (minutes ~/ 60).toString().padLeft(2, '0');
    final minutesText = (minutes % 60).toString().padLeft(2, '0');
    final localStamp = now.toIso8601String().replaceFirst('T', ' ');
    return '【用户设备本地时间基准】$localStamp UTC$sign$hoursText:$minutesText '
        '(${now.timeZoneName})。这是本次请求唯一可信的“现在”时间。回答现在、今天、明天、日期、星期或相对时间问题时，必须以此为准；忽略模型服务器时间、旧消息中的时间和任何默认时区。此时间仅适用于当前请求。';
  }
}
