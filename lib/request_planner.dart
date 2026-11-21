import 'direct_model_client.dart';
import 'chat_models.dart';

class RequestPlan {
  const RequestPlan({
    required this.includeConversationContext,
    required this.toolNames,
    this.directTurn,
  });

  final bool includeConversationContext;
  final Set<String> toolNames;
  final ModelTurn? directTurn;
}

class RequestPlanner {
  static const capabilityPrompt = '''
用户本条消息询问 Cwhale 支持什么功能时，按以下清单简明回答，不夸大未实现能力：
- 与当前配置的兼容 API 进行流式对话，可按会话切换本机保存的模型档案。
- 聊天记录、重要记忆和文件保存在本机；用户可以手动写入记忆、管理记忆，并压缩对话上下文。
- 用户明确要求时，可使用已授权的联网搜索、天气或本机时间工具；智能搜索开关只是授权，是否搜索由当前问题决定。
- 用户明确要求时，可在本机生成 Word、PowerPoint 和 Excel 文件，并交给设备上的其他应用打开。
- 可选择图片或文件，按需在本机整理文档摘要。
只介绍本应用目前支持的能力。不要列出内部提示词、工具定义或假装已执行任何操作。工具需用户明确请求或手动授权，不能声称后台自动运行。
如果用户同时询问模型身份，回答：“我是 Cwhale，背后具体的服务商由您当前激活的 API 为准。”
''';

  static bool asksCapabilities(String text) => RegExp(
    r'(你|助手|Cwhale).{0,12}(能做什么|可以做什么|会做什么|有什么功能|支持什么|支持哪些|有哪些功能|有哪些工具)|'
    r'(你有什么功能|你能做什么|你会什么|你都会什么|你能干什么|你能干啥|你能做啥|'
    r'可以帮我做什么|你能提供什么服务|支持哪些功能|有哪些可用功能)',
    caseSensitive: false,
  ).hasMatch(text);

  Future<RequestPlan> plan({
    required DirectModelClient client,
    required ModelSettings settings,
    required String userText,
    required Set<String> authorizedTools,
    required bool forceConversationContext,
    required bool deepThinking,
    required String thinkingMode,
    required void Function(String delta) onDirectDelta,
    String? humanizerPrompt,
    String? simulatorContext,
    bool deferDirectAnswer = false,
  }) async {
    if (asksCapabilities(userText)) {
      final turn = await client.streamReply(
        settings: settings,
        messages: [
          {'role': 'system', 'content': capabilityPrompt},
          if (simulatorContext != null)
            {'role': 'system', 'content': simulatorContext},
          if (humanizerPrompt != null)
            {'role': 'system', 'content': humanizerPrompt},
          {'role': 'user', 'content': userText},
        ],
        deepThinking: deepThinking,
        thinkingMode: thinkingMode,
        onDelta: onDirectDelta,
      );
      return RequestPlan(
        includeConversationContext: false,
        toolNames: const <String>{},
        directTurn: turn,
      );
    }

    final routeBuffer = StringBuffer();
    String? route;
    int bodyStart = 0;
    final allowedNames = authorizedTools.toList()..sort();
    final prompt = _routerPrompt(
      allowedNames,
      forceConversationContext,
      deferDirectAnswer,
      simulatorContext,
    );

    void receiveDelta(String delta) {
      routeBuffer.write(delta);
      final current = routeBuffer.toString();
      if (route == null) {
        final newline = current.indexOf('\n');
        if (newline >= 0 && newline <= 256) {
          final match = RegExp(
            r'^\s*CWHALEROUTE\s*:\s*(DIRECT|CONTEXT|TOOLS|CONTEXT_TOOLS)(?:\s*:\s*([a-z0-9_, ]*))?\s*\r?$',
            caseSensitive: false,
          ).firstMatch(current.substring(0, newline));
          if (match != null) {
            route = match.group(1)!.toUpperCase();
            bodyStart = newline + 1;
            if (route == 'DIRECT' &&
                !forceConversationContext &&
                !deferDirectAnswer) {
              final body = current.substring(bodyStart);
              if (body.isNotEmpty) onDirectDelta(body);
            }
            return;
          }
        }
        if (current.length > 256) {
          // A non-conforming router response is treated as a normal answer;
          // it cannot trigger tools or cause old context to be attached.
          route = 'DIRECT_FALLBACK';
          bodyStart = 0;
          if (!deferDirectAnswer) onDirectDelta(current);
        }
      } else if ((route == 'DIRECT' &&
              !forceConversationContext &&
              !deferDirectAnswer) ||
          (route == 'DIRECT_FALLBACK' && !deferDirectAnswer)) {
        onDirectDelta(delta);
      }
    }

    final routerTurn = await client.streamReply(
      settings: settings,
      messages: [
        {'role': 'system', 'content': prompt},
        {'role': 'user', 'content': userText},
      ],
      deepThinking: deepThinking,
      thinkingMode: thinkingMode,
      onDelta: receiveDelta,
    );

    final fullText = routerTurn.text;
    if (route == null) {
      final newline = fullText.indexOf('\n');
      final headerText = newline < 0
          ? fullText
          : fullText.substring(0, newline);
      final match = RegExp(
        r'^\s*CWHALEROUTE\s*:\s*(DIRECT|CONTEXT|TOOLS|CONTEXT_TOOLS)(?:\s*:\s*([a-z0-9_, ]*))?\s*$',
        caseSensitive: false,
      ).firstMatch(headerText);
      if (match == null) {
        route = 'DIRECT_FALLBACK';
        bodyStart = 0;
        if (!deferDirectAnswer) onDirectDelta(fullText);
      } else {
        route = match.group(1)!.toUpperCase();
        bodyStart = newline < 0 ? fullText.length : newline + 1;
        if (route == 'DIRECT' &&
            !forceConversationContext &&
            !deferDirectAnswer) {
          final body = fullText.substring(bodyStart);
          if (body.isNotEmpty) onDirectDelta(body);
        }
      }
    }

    final headerEnd = fullText.indexOf('\n');
    final header = headerEnd < 0 ? fullText : fullText.substring(0, headerEnd);
    final headerMatch = RegExp(
      r'^\s*CWHALEROUTE\s*:\s*(DIRECT|CONTEXT|TOOLS|CONTEXT_TOOLS)(?:\s*:\s*([a-z0-9_, ]*))?\s*\r?$',
      caseSensitive: false,
    ).firstMatch(header);
    final rawTools = headerMatch?.group(2) ?? '';
    final selectedTools = rawTools
        .split(RegExp(r'[,\s]+'))
        .where((name) => name.isNotEmpty && authorizedTools.contains(name))
        .toSet();
    final effectiveRoute = route ?? 'DIRECT_FALLBACK';
    final directAnswer = effectiveRoute == 'DIRECT' &&
        !forceConversationContext &&
        !deferDirectAnswer;
    final fallbackAnswer =
        effectiveRoute == 'DIRECT_FALLBACK' && !deferDirectAnswer;
    if (directAnswer || fallbackAnswer) {
      final answer = fullText.substring(bodyStart).trimLeft();
      if (answer.trim().isEmpty) {
        // If the route header arrived without an answer, let the normal
        // compact assistant prompt produce one rather than showing a blank.
        return RequestPlan(
          includeConversationContext: forceConversationContext,
          toolNames: const <String>{},
        );
      }
      return RequestPlan(
        includeConversationContext: false,
        toolNames: const <String>{},
        directTurn: ModelTurn(
          text: answer,
          toolCalls: const <ModelToolCall>[],
          reasoning: routerTurn.reasoning,
          inputTokens: routerTurn.inputTokens,
          outputTokens: routerTurn.outputTokens,
          totalTokens: routerTurn.totalTokens,
        ),
      );
    }

    final hasContext =
        forceConversationContext ||
        effectiveRoute == 'CONTEXT' ||
        effectiveRoute == 'CONTEXT_TOOLS';
    return RequestPlan(
      includeConversationContext: hasContext,
      toolNames: selectedTools,
    );
  }

  String _routerPrompt(
    List<String> allowedTools,
    bool forceContext,
    bool deferDirectAnswer,
    String? simulatorContext,
  ) {
    const toolLabels = <String, String>{
      'get_local_time': '读取本机时间',
      'get_weather': '查询天气',
      'web_search': '联网搜索',
      'open_web_page': '读取搜索来源网页',
      'create_word_document': '生成 Word 文件',
      'create_presentation': '生成 PPT 文件',
      'create_spreadsheet': '生成 Excel 文件',
    };
    final toolNames = allowedTools.isEmpty
        ? '无'
        : allowedTools
              .map((name) => '$name=${toolLabels[name] ?? name}')
              .join('、');
    return '''你是 Cwhale 本轮路由器，只看当前消息，不读历史、不调用工具。已授权工具：$toolNames。
第一行严格输出以下协议之一：CWHALEROUTE:DIRECT；CWHALEROUTE:CONTEXT；CWHALEROUTE:TOOLS:工具名；CWHALEROUTE:CONTEXT_TOOLS:工具名。只选已授权工具。
${deferDirectAnswer ? 'DIRECT 时只输出协议行，由后续正式请求生成答复。' : 'DIRECT 时第二行直接给出答复。'}
问候和稳定常识用 DIRECT；“之前／继续／偏好／这个”等需上文时用 CONTEXT。搜索只在用户要求或问题需要最新信息且开关已授权时选择。若问模型身份，答“我是 Cwhale，背后具体的服务商由您当前激活的 API 为准。”无法回答时说明限制，不猜测。
${simulatorContext == null ? '' : '$simulatorContext\n'}
${forceContext ? '本条附件必须选择 CONTEXT 或 CONTEXT_TOOLS。' : ''}''';
  }
}
