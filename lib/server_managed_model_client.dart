import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_auth_service.dart';
import 'chat_models.dart';
import 'direct_model_client.dart' show DirectModelClient, ModelTurn;

bool isGiftedProfileId(String id) => id.startsWith('cwhale-gift-');

/// Routes auxiliary calls through the same entitlement and quota as chat.
/// Each call gets its own task binding so it cannot replace the visible reply.
class GiftedModelClient extends DirectModelClient {
  GiftedModelClient({
    required this.server,
    required this.conversationId,
    required this.profileId,
  });

  final ServerManagedModelClient server;
  final String conversationId;
  final String profileId;

  @override
  Future<ModelTurn> streamReply({
    required ModelSettings settings,
    required List<Map<String, dynamic>> messages,
    required void Function(String delta) onDelta,
    List<Map<String, dynamic>>? tools,
    bool deepThinking = false,
    String thinkingMode = 'default',
  }) async {
    final entitlement = settings.serverEntitlementId.trim();
    if (entitlement.isEmpty || profileId != 'cwhale-gift-$entitlement') {
      throw const FormatException('获赠模型已不可用，请在当前对话中重新选择模型。');
    }
    return server.streamReply(
      settings: settings,
      messages: messages,
      onDelta: onDelta,
      tools: tools,
      deepThinking: deepThinking,
      thinkingMode: thinkingMode,
      conversationId: conversationId,
      userMessageId: newLocalId(),
      assistantMessageId: newLocalId(),
      profileId: profileId,
    );
  }
}

class ServerManagedTaskFailedException implements Exception {
  const ServerManagedTaskFailedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends a single model turn to the authenticated durable task queue. The
/// request is idempotent by task ID and polling always carries the full local
/// conversation/message binding, so changing the selected chat cannot redirect
/// the response to another window.
class ServerManagedModelClient {
  ServerManagedModelClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<ModelTurn> streamReply({
    required ModelSettings settings,
    required List<Map<String, dynamic>> messages,
    required void Function(String delta) onDelta,
    required String conversationId,
    required String userMessageId,
    required String assistantMessageId,
    required String profileId,
    List<Map<String, dynamic>>? tools,
    bool deepThinking = false,
    String thinkingMode = 'default',
    String? taskId,
    FutureOr<void> Function(String taskId)? onTaskId,
    FutureOr<void> Function()? onTaskFinished,
    void Function(String status)? onStatus,
  }) async {
    if (settings.isKiloAnonymous ||
        settings.baseUrl.toLowerCase().contains('ai-gateway.kilo.ai')) {
      throw const FormatException('Cwhale 免费模型固定使用本机直连，不能开启服务器代管。');
    }
    if (settings.apiKey.trim().isEmpty) {
      if (settings.serverEntitlementId.trim().isEmpty) {
        throw const FormatException('请先填写模型 API Key。');
      }
    }
    if (settings.serverEntitlementId.trim().isNotEmpty &&
        settings.apiKey.trim().isNotEmpty) {
      throw const FormatException('获赠模型请求不能携带个人 API Key。');
    }
    if (settings.model.trim().isEmpty) {
      throw const FormatException('请先填写模型名称。');
    }
    final requestTaskId = taskId ?? newLocalId();
    await onTaskId?.call(requestTaskId);

    final outboundMessages = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList();
    final systemPrompt = settings.globalSystemPrompt.trim();
    if (systemPrompt.isNotEmpty) {
      final index = outboundMessages.indexWhere(
        (message) => message['role'] == 'system',
      );
      if (index >= 0) {
        final current = outboundMessages[index]['content']?.toString() ?? '';
        outboundMessages[index]['content'] = '$systemPrompt\n\n$current';
      } else {
        outboundMessages.insert(0, {'role': 'system', 'content': systemPrompt});
      }
    }
    if (settings.injectLocalTimestamp) {
      final currentUser = outboundMessages.lastIndexWhere(
        (message) => message['role'] == 'user',
      );
      outboundMessages.insert(
        currentUser < 0 ? outboundMessages.length : currentUser,
        {'role': 'system', 'content': _localTimeInstruction(DateTime.now())},
      );
    }
    final requestBody = <String, dynamic>{
      'model': settings.model.trim(),
      'stream': true,
      'stream_options': {'include_usage': true},
      'messages': outboundMessages,
      if (settings.supportsThinkingToggle && thinkingMode != 'default')
        'thinking': {'type': thinkingMode == 'off' ? 'disabled' : 'enabled'},
      if (settings.supportsThinkingLevels &&
          const {'low', 'medium', 'high'}.contains(thinkingMode))
        'reasoning_effort': thinkingMode,
      if (tools != null && tools.isNotEmpty) ...{
        'tools': tools,
        'tool_choice': 'auto',
      },
    };
    final auth = AccountAuthService.instance;
    final apiBase = auth.generationApiBaseUrl.trim();
    final apiUri = Uri.tryParse(apiBase);
    if (apiUri == null ||
        apiUri.scheme != 'https' ||
        apiUri.host.isEmpty ||
        apiUri.userInfo.isNotEmpty ||
        apiUri.hasQuery ||
        apiUri.hasFragment) {
      throw const FormatException('服务器代管地址尚未配置，请检查应用版本。');
    }
    final collectionUri = apiUri.resolve('/v1/generation/tasks');
    final binding = <String, String>{
      'conversationId': conversationId,
      'userMessageId': userMessageId,
      'assistantMessageId': assistantMessageId,
    };
    final payload = <String, dynamic>{
      'taskId': requestTaskId,
      ...binding,
      'profileId': profileId,
      if (settings.serverEntitlementId.trim().isNotEmpty)
        'entitlementId': settings.serverEntitlementId.trim(),
      if (settings.serverEntitlementId.trim().isEmpty) ...{
        'upstreamBaseUrl': settings.baseUrl.trim(),
        'apiKey': settings.apiKey.trim(),
      },
      'requestBody': requestBody,
    };

    var displayedStatus = '';
    void updateStatus(String? status) {
      if (status == null || status == displayedStatus) return;
      displayedStatus = status;
      onStatus?.call(status);
    }

    final created = await _createTaskWithRetry(collectionUri, auth, payload);
    updateStatus(created);
    var afterSeq = 0;
    while (true) {
      final uri = apiUri
          .resolve('/v1/generation/tasks/$requestTaskId/events')
          .replace(queryParameters: {...binding, 'afterSeq': '$afterSeq'});
      final response = await _getEventsWithRetry(uri, auth);
      final decoded = _decodeObject(response.bodyBytes);
      updateStatus(decoded['status']?.toString());
      final events = decoded['events'] as List<dynamic>? ?? const [];
      for (final event in events) {
        if (event is! Map) continue;
        final sequence = (event['seq'] as num?)?.toInt() ?? afterSeq;
        if (sequence <= afterSeq) continue;
        afterSeq = sequence;
        final data = event['data'];
        if (data is! Map) continue;
        switch (event['type']) {
          case 'delta':
            final text = data['text'];
            if (text is String && text.isNotEmpty) onDelta(text);
            break;
          case 'completed':
            final turn = data['turn'];
            if (turn is Map) {
              await onTaskFinished?.call();
              return ModelTurn.fromTaskJson(Map<String, dynamic>.from(turn));
            }
            break;
          case 'error':
            await onTaskFinished?.call();
            throw Exception(data['message']?.toString() ?? '服务器代管任务失败。');
        }
      }
      final status = decoded['status']?.toString();
      if (status == 'failed') {
        await onTaskFinished?.call();
        throw Exception('服务器代管任务已失败，请检查部分回复后重试。');
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  /// Reconnects to an already submitted task after the app process was
  /// recreated. The task's encrypted provider request remains on the server;
  /// the full message binding is still required to read it.
  Future<ModelTurn> resumeReply({
    required String taskId,
    required String conversationId,
    required String userMessageId,
    required String assistantMessageId,
    required String existingText,
    required void Function(String delta) onDelta,
  }) async {
    final auth = AccountAuthService.instance;
    final apiBase = Uri.tryParse(auth.generationApiBaseUrl.trim());
    if (apiBase == null ||
        apiBase.scheme != 'https' ||
        apiBase.host.isEmpty ||
        apiBase.userInfo.isNotEmpty ||
        apiBase.hasQuery ||
        apiBase.hasFragment) {
      throw const FormatException('服务器代管地址尚未配置，无法续接任务。');
    }
    final binding = <String, String>{
      'conversationId': conversationId,
      'userMessageId': userMessageId,
      'assistantMessageId': assistantMessageId,
    };
    var afterSeq = 0;
    var emittedText = existingText;
    while (true) {
      final uri = apiBase
          .resolve('/v1/generation/tasks/$taskId/events')
          .replace(queryParameters: {...binding, 'afterSeq': '$afterSeq'});
      final response = await _getEventsWithRetry(uri, auth);
      final decoded = _decodeObject(response.bodyBytes);
      final snapshot = decoded['outputText'];
      if (snapshot is String &&
          snapshot.length >= emittedText.length &&
          snapshot.startsWith(emittedText)) {
        final delta = snapshot.substring(emittedText.length);
        if (delta.isNotEmpty) {
          emittedText = snapshot;
          onDelta(delta);
        }
      }
      final events = decoded['events'] as List<dynamic>? ?? const [];
      for (final event in events) {
        if (event is! Map) continue;
        final sequence = (event['seq'] as num?)?.toInt() ?? afterSeq;
        if (sequence > afterSeq) afterSeq = sequence;
        final data = event['data'];
        if (data is! Map) continue;
        if (event['type'] == 'completed' && data['turn'] is Map) {
          return ModelTurn.fromTaskJson(
            Map<String, dynamic>.from(data['turn'] as Map),
          );
        }
        if (event['type'] == 'error') {
          throw ServerManagedTaskFailedException(
            data['message']?.toString() ?? '服务器代管任务失败。',
          );
        }
      }
      if (decoded['status'] == 'failed') {
        throw const ServerManagedTaskFailedException(
          '服务器代管任务已失败，请检查本机已保存的部分回复。',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<String> _createTaskWithRetry(
    Uri uri,
    AccountAuthService auth,
    Map<String, dynamic> payload,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final token = await auth.requireAccessToken();
        final response = await _client
            .post(
              uri,
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json; charset=utf-8',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 30));
        final body = _decodeObject(response.bodyBytes);
        if (response.statusCode == 202 || response.statusCode == 200) {
          return body['status']?.toString() ?? 'queued';
        }
        if (response.statusCode == 429) {
          throw Exception(body['detail']?.toString() ?? '服务器任务队列已满，请稍后重试。');
        }
        if (response.statusCode == 401) {
          throw const AccountAuthException('UNAUTHORIZED', '登录状态已失效，请重新登录。');
        }
        if (response.statusCode >= 500) {
          lastError = Exception('服务器暂时不可用（${response.statusCode}）。');
        } else {
          throw Exception(
            body['detail']?.toString() ??
                '无法创建服务器代管任务（${response.statusCode}）。',
          );
        }
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(Duration(milliseconds: 500 + attempt * 700));
    }
    throw Exception(
      '无法连接服务器代管队列，请检查网络后重试。${lastError == null ? '' : ' $lastError'}',
    );
  }

  Future<http.Response> _getEventsWithRetry(
    Uri uri,
    AccountAuthService auth,
  ) async {
    while (true) {
      try {
        final token = await auth.requireAccessToken();
        final response = await _client
            .get(
              uri,
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $token',
              },
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode == 200) return response;
        if (response.statusCode == 401) {
          throw const AccountAuthException(
            'UNAUTHORIZED',
            '登录状态已失效，请重新登录以续接代管任务。',
          );
        }
        if (response.statusCode == 404) {
          throw const ServerManagedTaskFailedException(
            '服务器找不到绑定到本会话的任务；为避免跨窗口读取，已停止续接。',
          );
        }
        if (response.statusCode >= 500) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final body = _decodeObject(response.bodyBytes);
        throw Exception(
          body['detail']?.toString() ?? '读取服务器任务失败（${response.statusCode}）。',
        );
      } on TimeoutException {
        await Future<void>.delayed(const Duration(seconds: 1));
      } on http.ClientException {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Map<String, dynamic> _decodeObject(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, dynamic> ? value : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
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
