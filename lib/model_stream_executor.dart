import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

  Map<String, dynamic> toTaskJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  factory ModelToolCall.fromTaskJson(Map<String, dynamic> json) =>
      ModelToolCall(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        arguments: json['arguments'] as String? ?? '',
      );
}

class ModelTurn {
  const ModelTurn({
    required this.text,
    required this.toolCalls,
    required this.reasoning,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.usageStatus,
  });

  final String text;
  final String reasoning;
  final List<ModelToolCall> toolCalls;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final String? usageStatus;

  Map<String, dynamic> toTaskJson() => {
    'text': text,
    'reasoning': reasoning,
    'toolCalls': toolCalls.map((call) => call.toTaskJson()).toList(),
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (outputTokens != null) 'outputTokens': outputTokens,
    if (totalTokens != null) 'totalTokens': totalTokens,
    if (usageStatus != null) 'usageStatus': usageStatus,
  };

  factory ModelTurn.fromTaskJson(Map<String, dynamic> json) => ModelTurn(
    text: json['text'] as String? ?? '',
    reasoning: json['reasoning'] as String? ?? '',
    toolCalls: (json['toolCalls'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (call) => ModelToolCall.fromTaskJson(Map<String, dynamic>.from(call)),
        )
        .toList(),
    inputTokens: (json['inputTokens'] as num?)?.toInt(),
    outputTokens: (json['outputTokens'] as num?)?.toInt(),
    totalTokens: (json['totalTokens'] as num?)?.toInt(),
    usageStatus: json['usageStatus'] as String?,
  );
}

class _ToolCallBuffer {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

/// Executes one provider SSE request. It contains no app, storage, or UI
/// dependencies, so the same implementation can run in the foreground task's
/// dedicated Flutter engine.
class ModelStreamExecutor {
  ModelStreamExecutor._();

  static const _responseHeaderTimeout = Duration(seconds: 180);
  static const _sseIdleTimeout = Duration(minutes: 10);

  static Future<ModelTurn> execute({
    required Uri uri,
    required String apiKey,
    required Map<String, dynamic> body,
    required void Function(String delta) onDelta,
    http.Client? httpClient,
  }) async {
    final request = http.Request('POST', uri)..followRedirects = false;
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    if (apiKey.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }
    request.body = jsonEncode(body);

    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(_responseHeaderTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final responseBody = await response.stream.bytesToString().timeout(
          const Duration(seconds: 20),
        );
        throw Exception(
          _readProviderError(
            response.statusCode,
            responseBody,
            isKilo: uri.host.toLowerCase() == 'ai-gateway.kilo.ai',
          ),
        );
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
    }
  }

  static String _readProviderError(
    int statusCode,
    String body, {
    required bool isKilo,
  }) {
    if (isKilo && statusCode == 429) {
      return 'Cwhale 免费额度已用完，请稍后再试。';
    }
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
