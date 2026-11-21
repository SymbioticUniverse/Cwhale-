import 'chat_models.dart';

/// Local, rule-based router for the user-visible important-memory document.
/// It never asks a model to decide what should be remembered.
class MemoryRouter {
  List<String> manualKeywords(String topic, String content) =>
      _keywords('$topic $content');

  static final _relationshipWords = RegExp(
    r'(朋友|同学|同事|家人|父母|爸爸|妈妈|父亲|母亲|兄弟|姐妹|亲戚|室友|领导|老板|老师|伴侣|男朋友|女朋友|妻子|丈夫|老公|老婆|孩子)',
  );
  static final _eventWords = RegExp(
    r'(发生|遇到|告诉|跟我说|和我说|吵架|分手|结婚|生病|去世|搬家|辞职|入职|认识|见面|联系|借钱|帮我|去了|回来|考试|出生|离开|买了|卖了|失业|升职|住院|受伤|搬到|开始工作)',
  );
  static final _selfWords = RegExp(r'(我|我们|本人|自己)');
  static final _planWords = RegExp(
    r'(打算|计划|决定|承诺|准备|目标是|立志|我要做|我要成为|我想做|我想成为|我准备|我决定|我打算|我承诺|我计划|我以后要|以后我要|以后我想做|将来我想做|我将来要|我未来要|我希望成为|我会在.{0,12}(做|完成|开始|实现))',
  );
  static final _profileWords = RegExp(
    r'(我的性格|我性格|我的个性|我个性|我的脾气|我脾气|我(是.{0,5})?(很|比较|非常)?(内向|外向|慢热|乐观|敏感|开朗|谨慎|急性子|慢性子)|我的习惯|我习惯|我的偏好|我偏好|我一直喜欢|我长期喜欢|我比较喜欢|我最喜欢|我不喜欢|我讨厌|我的爱好|我的职业|我从事|我住在|我来自|我的家乡|我的生日|我的专业|我的学历|长期以来)',
  );
  static final _significantPersonalEventWords = RegExp(
    r'(出生|结婚|离婚|分手|搬家|搬到|毕业|入学|辞职|失业|入职|升职|创业|确诊|诊断|住院|手术|去世|葬礼|受伤|重大事故|重大疾病|第一次独立|重要决定|找到工作|换工作|考上|落榜)',
  );
  static final _significantImpactWords = RegExp(
    r'(对我影响很大|改变了我的人生|改变了我|让我至今|一直记得|特别痛苦|特别难过|非常难过|很难过|很受打击|长期困扰|人生中最|对我很重要|重大打击|深受影响)',
  );
  static final _relationshipEventWords = RegExp(
    r'(吵架|冲突|和好|分手|结婚|离婚|生病|去世|住院|受伤|借钱|帮了我|背叛|和我说|跟我说|发生了|对我影响|关系破裂|关系变好|换工作|失业|入职)',
  );
  static final _majorRelationshipEventWords = RegExp(
    r'(结婚|离婚|分手|去世|住院|确诊|手术|重大疾病|严重受伤|失业)',
  );
  static final _questionOrRequestWords = RegExp(
    r'(我想知道|想知道|请问|问一下|帮我|搜索|搜一下|查一下|查询|检索|介绍一下|解释一下|是什么|怎么样|怎样|如何|为什么|哪里|哪儿|几点|几号|发生了什么|发生什么事)',
  );
  static final _roleplayOrHypotheticalWords = RegExp(
    r'(假如|假设|如果我是|如果我|扮演|角色扮演|小说里|故事里|虚构|设定中|假想)',
  );
  static final _assistantNicknamePattern = RegExp(
    r'(?:以后|今后|从现在起|往后)?(?:我)?(?:就)?(?:叫你|称呼你|管你叫|喊你|给你起名(?:叫)?|给你取名(?:叫)?)[“"「『]?\s*([\u3400-\u9fffA-Za-z0-9_-]{1,16})|(?:你的名字|你叫)(?:是|叫|为|做)?[“"「『]?\s*([\u3400-\u9fffA-Za-z0-9_-]{1,16})',
  );
  static final _assistantCommandStarts = RegExp(
    r'^(帮我|帮|做|去|在|把|给我|写|查|搜索|搜|回答|生成|总结|介绍|解释|提醒|记得|不要|必须|先|告诉|用|继续|试试|看看|说|处理|完成|打开|关闭)',
  );
  static final _historicalWords = RegExp(
    r'(之前|以前|上次|过去|去年|曾经|那时|当时|早些时候|原来|最初|旧的|历史|之前那件事|以前说过)',
  );
  static final _broadRecallWords = RegExp(
    r'(记得|记忆|我说过|我提过|我的计划|我打算|我喜欢|我的性格|我的朋友|我们之前|发生过什么)',
  );

  static const _topicPhrases = [
    '人工智能',
    '深度学习',
    '手机应用',
    '电子商务',
    '创业项目',
    '找工作',
    '换工作',
    '学习计划',
    '职业规划',
    '家庭关系',
    '人际关系',
    '男朋友',
    '女朋友',
    '父亲',
    '母亲',
    '爸爸',
    '妈妈',
    '同事',
    '朋友',
    '同学',
    '工作',
    '职业',
    '项目',
    '创业',
    '开发',
    '学习',
    '考试',
    '搬家',
    '旅行',
    '结婚',
    '健康',
    '家人',
    '父母',
    '性格',
    '内向',
    '外向',
    '慢热',
    '乐观',
    '敏感',
    '喜欢',
    '爱好',
    '手机',
    '应用',
    '软件',
    '产品',
    '生意',
    '公司',
    '家庭',
    '关系',
  ];

  static const _stopWords = [
    '以后',
    '将来',
    '未来',
    '打算',
    '计划',
    '准备',
    '目标是',
    '目标',
    '希望',
    '我要',
    '我想',
    '我会',
    '我们',
    '我的',
    '本人',
    '自己',
    '我',
    '想要',
    '要做',
    '想做',
    '做一个',
    '做一份',
    '一个',
    '一些',
    '关于',
    '然后',
    '因为',
    '所以',
    '但是',
    '可能',
    '应该',
    '觉得',
    '认为',
    '是一个',
    '我比较',
    '比较',
    '非常',
    '真的',
    '那个',
    '这个',
    '事情',
    '东西',
    '今天',
    '昨天',
    '明天',
    '最近',
    '之前',
    '以后',
  ];

  List<ImportantMemoryRecord> capture({
    required String userText,
    required String sourceWindowId,
    required List<ImportantMemoryRecord> globalRecords,
    required List<ImportantMemoryRecord> windowRecords,
  }) {
    if (_explicitlyOptsOut(userText)) return const [];
    final additions = <ImportantMemoryRecord>[];
    final priorRecords = [...globalRecords, ...windowRecords];
    for (final sentence in _sentences(userText)) {
      final category = _classify(sentence);
      if (category == null) continue;
      final keywords = _keywords(sentence);
      final latestForCategory = _latestByKey(priorRecords + additions)
          .where((record) => record.category == category)
          .toList();
      final matched = _bestMatch(keywords, latestForCategory);
      final key = matched?.key ?? _newKey(category, keywords, sentence);
      final previous = _latestByKey(priorRecords + additions)
          .where((record) => record.key == key)
          .fold<ImportantMemoryRecord?>(
            null,
            (latest, record) =>
                latest == null ||
                    record.recordedAtUtc.isAfter(latest.recordedAtUtc)
                ? record
                : latest,
          );
      final content = sentence.trim();
      if (previous != null &&
          _normalize(previous.content) == _normalize(content)) {
        continue;
      }
      final now = DateTime.now();
      additions.add(
        ImportantMemoryRecord(
          id: newLocalId(),
          key: key,
          category: category,
          content: content,
          keywords: keywords,
          recordedAtUtc: now.toUtc(),
          timestampLabel: formatLocalTimestamp(now),
          sourceWindowId: sourceWindowId,
          supersedesId: previous?.id,
        ),
      );
    }
    return additions;
  }

  List<ImportantMemoryRecord> recall({
    required String query,
    required List<ImportantMemoryRecord> globalRecords,
    required List<ImportantMemoryRecord> windowRecords,
    int limit = 12,
  }) {
    final all = _uniqueById([...windowRecords, ...globalRecords]);
    if (all.isEmpty || query.trim().isEmpty) return const [];

    final latest = _latestByKey(all);
    final queryKeywords = _keywords(query);
    final historical = _historicalWords.hasMatch(query);
    final broadRecall = _broadRecallWords.hasMatch(query);
    final matchedKeys = <String>{};

    for (final record in latest) {
      if (record.category == '个人特征' ||
          record.category == 'AI称呼' ||
          _matchScore(queryKeywords, record.keywords) >= 0.24 ||
          query.contains(record.content) ||
          record.content.contains(query.trim())) {
        matchedKeys.add(record.key);
      }
    }

    if (broadRecall) {
      matchedKeys.addAll(latest.map((record) => record.key));
    }

    final selected = all.where((record) {
      if (!matchedKeys.contains(record.key)) return false;
      if (historical) return true;
      return latest.any((current) => current.id == record.id);
    }).toList()..sort((a, b) => b.recordedAtUtc.compareTo(a.recordedAtUtc));

    return selected.take(limit).toList();
  }

  String renderForPrompt(List<ImportantMemoryRecord> memories, String query) {
    if (memories.isEmpty) return '';
    final historical = _historicalWords.hasMatch(query);
    final latestIds = _latestByKey(memories).map((record) => record.id).toSet();
    final lines = memories
        .map((record) {
          final version = historical && !latestIds.contains(record.id)
              ? '历史版本'
              : '当前版本';
          return '- [${record.timestampLabel}] [${record.category}] [$version] ${record.content}';
        })
        .join('\n');
    return '本机匹配到的个人重要记忆（已按关键词/语义类别匹配；每条记录带本地时间戳。'
        '默认以每个主题的当前版本为准；只有用户询问以前、上次等历史时才参考历史版本）：\n$lines';
  }

  bool _explicitlyOptsOut(String text) =>
      RegExp(r'(不要|别|不需要|不希望|不必|不用).{0,8}(记住|记录|保存)').hasMatch(text);

  String? _classify(String sentence) {
    final text = sentence.trim();
    if (text.length < 7 ||
        RegExp(r'[?？]|吗$|是不是|是否|会不会|能不能').hasMatch(text) ||
        _questionOrRequestWords.hasMatch(text) ||
        _roleplayOrHypotheticalWords.hasMatch(text) ||
        RegExp(r'^(请|帮我|告诉我|搜索|查询|问一下)').hasMatch(text)) {
      return null;
    }
    final nickname = _assistantNicknamePattern.firstMatch(text);
    final nicknameValue = nickname?.group(1) ?? nickname?.group(2);
    if (nicknameValue != null &&
        !_assistantCommandStarts.hasMatch(nicknameValue)) {
      return 'AI称呼';
    }
    final personal = _selfWords.hasMatch(sentence);
    final relationship = _relationshipWords.hasMatch(sentence);
    if (relationship &&
        _relationshipEventWords.hasMatch(text) &&
        (personal ||
            _significantImpactWords.hasMatch(text) ||
            _majorRelationshipEventWords.hasMatch(text))) {
      return '关系事件';
    }
    if (personal && _planWords.hasMatch(text)) return '计划目标';
    if (personal && _profileWords.hasMatch(text)) return '个人特征';
    if (personal &&
        (_significantPersonalEventWords.hasMatch(text) ||
            (_significantImpactWords.hasMatch(text) &&
                _eventWords.hasMatch(text)))) {
      return '个人事件';
    }
    return null;
  }

  List<String> _sentences(String text) =>
      RegExp(r'[^。！？!?；;\n]+[。！？!?]?')
          .allMatches(text)
          .map((match) => match.group(0)!.trim())
          .where((sentence) => sentence.length >= 5)
          .toList();

  List<String> _keywords(String text) {
    final normalized = _normalize(text);
    final keywords = <String>{};
    for (final phrase in _topicPhrases) {
      if (normalized.contains(phrase.toLowerCase())) {
        keywords.add(phrase.toLowerCase());
      }
    }
    keywords.addAll(
      RegExp(r'[a-z][a-z0-9_+#.-]{1,}')
          .allMatches(normalized)
          .map((match) => match.group(0)!),
    );
    keywords.addAll(
      RegExp(r'\d+').allMatches(normalized).map((m) => m.group(0)!),
    );

    var reduced = normalized;
    for (final stopWord in _stopWords) {
      reduced = reduced.replaceAll(stopWord, ' ');
    }
    for (final run in RegExp(
      r'[\u3400-\u9fff]{2,}',
    ).allMatches(reduced).map((match) => match.group(0)!)) {
      for (var index = 0; index < run.length - 1; index++) {
        final pair = run.substring(index, index + 2);
        if (!_stopWords.contains(pair) && pair.trim().length == 2) {
          keywords.add(pair);
        }
      }
    }
    keywords.removeWhere(
      (word) => word.length < 2 || _stopWords.contains(word),
    );
    return keywords.take(32).toList();
  }

  String _newKey(String category, List<String> keywords, String sentence) {
    final semanticGroup = switch (category) {
      'AI称呼' => 'interaction:assistant_nickname',
      '个人特征' when RegExp(r'(性格|个性|脾气)').hasMatch(sentence) =>
        'profile:personality',
      '个人特征' when RegExp(r'(工作|职业)').hasMatch(sentence) => 'profile:work',
      '个人特征' when RegExp(r'(喜欢|不喜欢|讨厌|偏好|爱好)').hasMatch(sentence) =>
        'profile:preference:${keywords.take(2).join('_')}',
      _ => '',
    };
    if (semanticGroup.isNotEmpty) return semanticGroup;
    final signature = keywords.take(3).join('_');
    if (signature.isNotEmpty) return '${category.toLowerCase()}:$signature';
    final normalized = _normalize(sentence);
    return '${category.toLowerCase()}:${normalized.substring(0, normalized.length.clamp(0, 20).toInt())}';
  }

  List<ImportantMemoryRecord> _uniqueById(List<ImportantMemoryRecord> records) {
    final seen = <String>{};
    return records.where((record) => seen.add(record.id)).toList();
  }

  List<ImportantMemoryRecord> _latestByKey(
    List<ImportantMemoryRecord> records,
  ) {
    final latest = <String, ImportantMemoryRecord>{};
    for (final record in records) {
      final current = latest[record.key];
      if (current == null ||
          record.recordedAtUtc.isAfter(current.recordedAtUtc) ||
          (record.recordedAtUtc.isAtSameMomentAs(current.recordedAtUtc) &&
              record.id.compareTo(current.id) > 0)) {
        latest[record.key] = record;
      }
    }
    return latest.values.toList();
  }

  ImportantMemoryRecord? _bestMatch(
    List<String> keywords,
    List<ImportantMemoryRecord> candidates,
  ) {
    ImportantMemoryRecord? best;
    var bestScore = 0.0;
    for (final candidate in candidates) {
      final score = _matchScore(keywords, candidate.keywords);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore >= 0.42 ? best : null;
  }

  double _matchScore(List<String> left, List<String> right) {
    if (left.isEmpty || right.isEmpty) return 0;
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    final overlap = leftSet.intersection(rightSet).length;
    if (overlap == 0) return 0;
    final smaller = leftSet.length < rightSet.length
        ? leftSet.length
        : rightSet.length;
    final union = leftSet.union(rightSet).length;
    return (overlap / union) * 0.65 + (overlap / smaller) * 0.35;
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff+#]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
