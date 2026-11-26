import 'dart:io';

import 'account_auth_service.dart';
import 'chat_models.dart';
import 'generation_protection.dart';
import 'kilo_gateway.dart';
import 'local_store.dart';
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
    final isKiloRequest =
        settings.isKiloAnonymous &&
        settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '') ==
            kiloApiBaseUrl &&
        settings.model.trim() == kiloDisplayModelAlias;
    if (settings.isKiloAnonymous && !isKiloRequest) {
      throw const FormatException('Cwhale 免费模型配置无效，请重新选择 API 配置。');
    }
    if (isKiloRequest) {
      final auth = AccountAuthService.instance;
      if (!auth.isConfigured || auth.currentUser == null) {
        throw const CwhaleFreeModelAccountRequiredException();
      }
      await KiloGateway.requireFreeAutoRouter();
      final consents = await LocalStore().loadModelDataConsents();
      if (!KiloGateway.hasDataConsent(consents)) {
        throw const KiloDataConsentRequiredException();
      }
    } else if (settings.apiKey.trim().isEmpty) {
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
      final currentUser = outboundMessages.lastIndexWhere(
        (message) => message['role'] == 'user',
      );
      outboundMessages.insert(
        currentUser < 0 ? outboundMessages.length : currentUser,
        {'role': 'system', 'content': _localTimeInstruction(DateTime.now())},
      );
    }

    final body = <String, dynamic>{
      'model': isKiloRequest ? kiloGatewayModelId : settings.model.trim(),
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

    if (isKiloRequest) {
      // Persist only a local timestamp before dispatch. Kilo's actual quota is
      // shared by every app behind the same public IP, so this cannot be exact.
      try {
        await LocalStore().recordKiloModelRequest();
      } catch (_) {
        // A local counter failure must not prevent the user's model request.
      }
    }

    final backgroundProtected = await GenerationProtection.acquire();
    try {
      try {
        final result = Platform.isAndroid && backgroundProtected
            ? await GenerationProtection.executeRequest(
                uri: completionUri(settings.baseUrl).toString(),
                apiKey: isKiloRequest ? '' : settings.apiKey.trim(),
                body: body,
                onDelta: onDelta,
              )
            : await ModelStreamExecutor.execute(
                uri: completionUri(settings.baseUrl),
                apiKey: isKiloRequest ? '' : settings.apiKey.trim(),
                body: body,
                onDelta: onDelta,
              );
        if (isKiloRequest) {
          try {
            await LocalStore().clearFreeModelQuotaExhausted();
          } catch (_) {
            // Quota display persistence must not interrupt a valid reply.
          }
        }
        return result;
      } catch (error) {
        if (isKiloRequest && error.toString().contains('免费额度已用完')) {
          try {
            await LocalStore().markFreeModelQuotaExhausted();
          } catch (_) {
            // The next local usage refresh will fall back to recorded calls.
          }
        }
        rethrow;
      }
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

class KiloDataConsentRequiredException implements Exception {
  const KiloDataConsentRequiredException();

  @override
  String toString() => '使用 Cwhale 免费模型前需要先确认数据发送说明。';
}

class CwhaleFreeModelAccountRequiredException implements Exception {
  const CwhaleFreeModelAccountRequiredException();

  @override
  String toString() => '请先登录 Cwhale 账号，再使用免费模型。';
}
