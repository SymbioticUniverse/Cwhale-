import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_models.dart';
import 'generation_protection.dart';

class ModelToolCall {
  const ModelToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

class ModelTurn {
  const ModelTurn({
    required this.text,
    required this.toolCalls,
    required this.reasoning,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
  });

  final String text;
  final String reasoning;
  final List<ModelToolCall> toolCalls;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
}

class _ToolCallBuffer {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

class DirectModelClient {
  static const _responseHeaderTimeout = Duration(seconds: 180);
  // This is an inactivity timeout between SSE events, not a total generation
  // deadline. Long-running streams may continue beyond ten minutes.
  static const _sseIdleTimeout = Duration(minutes: 10);

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

    final request = http.Request('POST', completionUri(settings.baseUrl))
      ..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer ' + settings.apiKey.trim(),
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    request.body = jsonEncode(body);

    final client = http.Client();
    final backgroundProtected = await GenerationProtection.acquire();
    try {
      final response = await client
          .send(request)
          .timeout(_responseHeaderTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final responseBody = await response.stream.bytesToString().timeout(
          const Duration(seconds: 20),
        );
        throw Exception(_readProviderError(response.statusCode, responseBody));
      }

      final answer = StringBuffer();
      final reasoning = StringBuffer();
      final calls = <int, _ToolCallBuffer>{};
      int? inputTokens;
      int? outputTokens;
      int? totalTokens;
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(_sseIdleTimeout)) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') {
          if (payload == '[DONE]') break;
          continue;
        }
        try {
          final event = jsonDecode(payload) as Map<String, dynamic>;
          final usage = event['usage'];
          if (usage is Map<String, dynamic>) {
            inputTokens =
                (usage['prompt_tokens'] as num?)?.toInt() ?? inputTokens;
            outputTokens =
                (usage['completion_tokens'] as num?)?.toInt() ?? outputTokens;
            totalTokens =
                (usage['total_tokens'] as num?)?.toInt() ?? totalTokens;
          }
          final choices = event['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final choice = choices.first as Map<String, dynamic>;
          final delta = choice['delta'] as Map<String, dynamic>? ?? const {};
          final fragment = delta['reasoning_content'];
          if (fragment is String) reasoning.write(fragment);
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            answer.write(content);
            onDelta(content);
          }
          final rawCalls = delta['tool_calls'] as List<dynamic>? ?? const [];
          for (final rawCall in rawCalls) {
            if (rawCall is! Map<String, dynamic>) continue;
            final index = (rawCall['index'] as num?)?.toInt() ?? calls.length;
            final buffer = calls.putIfAbsent(index, _ToolCallBuffer.new);
            final id = rawCall['id'];
            if (id is String) buffer.id += id;
            final function = rawCall['function'];
            if (function is! Map<String, dynamic>) continue;
            final name = function['name'];
            if (name is String) buffer.name += name;
            final arguments = function['arguments'];
            if (arguments is String) buffer.arguments.write(arguments);
          }
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }

      final toolCalls = calls.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final parsedCalls = toolCalls
          .map(
            (entry) => ModelToolCall(
              id: entry.value.id,
              name: entry.value.name,
              arguments: entry.value.arguments.toString(),
            ),
          )
          .where((call) => call.id.isNotEmpty && call.name.isNotEmpty)
          .toList();

      if (answer.isEmpty && parsedCalls.isEmpty) {
        throw Exception('模型没有返回内容，请检查模型名称和 API 服务状态。');
      }
      return ModelTurn(
        text: answer.toString(),
        toolCalls: parsedCalls,
        reasoning: reasoning.toString(),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: totalTokens,
      );
    } finally {
      client.close();
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

  String _readProviderError(int statusCode, String body) {
    var providerDetail = '';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        providerDetail = error['message'] as String;
      } else if (json['message'] is String) {
        providerDetail = json['message'] as String;
      }
    } on FormatException {
      // Fall back to the status code for non-JSON error pages.
    } on TypeError {
      // Fall back to the status code for unexpected JSON values.
    }
    if (providerDetail.isEmpty) providerDetail = body.trim();
    if (RegExp(
      r'(vision|image|multimodal|图片|图像).{0,80}(not supported|unsupported|not available|不支持|不可用)|(not supported|unsupported|not available|不支持|不可用).{0,80}(vision|image|multimodal|图片|图像)',
      caseSensitive: false,
    ).hasMatch(providerDetail)) {
      return '当前 API 或模型不支持图片识别：$providerDetail。图片已保留在本机，请切换支持图片输入的模型后重试。';
    }
    if (providerDetail.isNotEmpty) {
      return '模型 API 返回 $statusCode：$providerDetail';
    }
    return '模型 API 请求失败（$statusCode）。请检查 API 地址和密钥。';
  }
}
