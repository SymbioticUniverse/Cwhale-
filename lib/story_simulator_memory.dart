class StoryTurnSummary {
  const StoryTurnSummary({
    required this.turnId,
    required this.userMessageId,
    required this.assistantMessageId,
    required this.userMessageIndex,
    required this.assistantMessageIndex,
    required this.userMessageReference,
    required this.assistantMessageReference,
    required this.storyTimeStart,
    required this.storyTimeEnd,
    required this.summary,
    this.relationshipChanges = const <String>[],
    this.appellationChanges = const <String>[],
    this.keywords = const <String>[],
    this.sceneDetails = const <String>[],
  });

  final String turnId;
  final String userMessageId;
  final String assistantMessageId;
  final int userMessageIndex;
  final int assistantMessageIndex;
  final String userMessageReference;
  final String assistantMessageReference;
  final String storyTimeStart;
  final String storyTimeEnd;
  final String summary;
  final List<String> relationshipChanges;
  final List<String> appellationChanges;
  final List<String> keywords;
  final List<String> sceneDetails;

  StoryTurnSummary copyWith({
    int? userMessageIndex,
    int? assistantMessageIndex,
    String? userMessageReference,
    String? assistantMessageReference,
  }) => StoryTurnSummary(
    turnId: turnId,
    userMessageId: userMessageId,
    assistantMessageId: assistantMessageId,
    userMessageIndex: userMessageIndex ?? this.userMessageIndex,
    assistantMessageIndex: assistantMessageIndex ?? this.assistantMessageIndex,
    userMessageReference: userMessageReference ?? this.userMessageReference,
    assistantMessageReference:
        assistantMessageReference ?? this.assistantMessageReference,
    storyTimeStart: storyTimeStart,
    storyTimeEnd: storyTimeEnd,
    summary: summary,
    relationshipChanges: relationshipChanges,
    appellationChanges: appellationChanges,
    keywords: keywords,
    sceneDetails: sceneDetails,
  );

  Map<String, dynamic> toJson() => {
    'turnId': turnId,
    'userMessageId': userMessageId,
    'assistantMessageId': assistantMessageId,
    'userMessageIndex': userMessageIndex,
    'assistantMessageIndex': assistantMessageIndex,
    'userMessageReference': userMessageReference,
    'assistantMessageReference': assistantMessageReference,
    'storyTimeStart': storyTimeStart,
    'storyTimeEnd': storyTimeEnd,
    'summary': summary,
    'relationshipChanges': relationshipChanges,
    'appellationChanges': appellationChanges,
    'keywords': keywords,
    'sceneDetails': sceneDetails,
  };

  factory StoryTurnSummary.fromJson(Map<String, dynamic> json) =>
      StoryTurnSummary(
        turnId: json['turnId'] as String? ?? '',
        userMessageId: json['userMessageId'] as String? ?? '',
        assistantMessageId: json['assistantMessageId'] as String? ?? '',
        userMessageIndex: (json['userMessageIndex'] as num?)?.toInt() ?? -1,
        assistantMessageIndex:
            (json['assistantMessageIndex'] as num?)?.toInt() ?? -1,
        userMessageReference: json['userMessageReference'] as String? ?? '',
        assistantMessageReference:
            json['assistantMessageReference'] as String? ?? '',
        storyTimeStart: json['storyTimeStart'] as String? ?? '',
        storyTimeEnd: json['storyTimeEnd'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        relationshipChanges: _readStringList(json['relationshipChanges']),
        appellationChanges: _readStringList(json['appellationChanges']),
        keywords: _readStringList(json['keywords']),
        sceneDetails: _readStringList(json['sceneDetails']),
      );

  String render() {
    final lines = <String>[
      '剧情时间：$storyTimeStart${storyTimeEnd == storyTimeStart ? '' : ' → $storyTimeEnd'}',
      '梗概：$summary',
      ...sceneDetails,
      if (relationshipChanges.isNotEmpty)
        '关系变化：${relationshipChanges.join('；')}',
      if (appellationChanges.isNotEmpty) '称呼变化：${appellationChanges.join('；')}',
      '原文位置：$userMessageReference；$assistantMessageReference',
    ];
    return lines.join('\n');
  }
}

class StorySimulatorMemory {
  StorySimulatorMemory({
    this.globalMemoryText = '',
    this.storyTime = '第 1 日 · 剧情开始',
    List<StoryTurnSummary>? summaries,
  }) : summaries = summaries ?? <StoryTurnSummary>[];

  String globalMemoryText;
  String storyTime;
  final List<StoryTurnSummary> summaries;

  Map<String, dynamic> toJson() => {
    'globalMemoryText': globalMemoryText,
    'storyTime': storyTime,
    'summaries': summaries.map((item) => item.toJson()).toList(),
  };

  factory StorySimulatorMemory.fromJson(Map<String, dynamic> json) =>
      StorySimulatorMemory(
        globalMemoryText: json['globalMemoryText'] as String? ?? '',
        storyTime: (json['storyTime'] as String?)?.trim().isNotEmpty == true
            ? (json['storyTime'] as String).trim()
            : '第 1 日 · 剧情开始',
        summaries: (json['summaries'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(StoryTurnSummary.fromJson)
            .toList(),
      );
}

List<String> _readStringList(Object? value) =>
    (value as List<dynamic>? ?? const []).whereType<String>().toList();
