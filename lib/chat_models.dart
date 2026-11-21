import 'dart:math';

import 'story_simulator_memory.dart';

const deepSeekApiBaseUrl = 'https://api.deepseek.com';
const deepSeekFlashModel = 'deepseek-flash';
const deepSeekDefaultProfileId = 'deepseek-default';
const contextWindowChoices = <int>[
  16000,
  32000,
  64000,
  128000,
  256000,
  512000,
  1000000,
];

String formatContextWindow(int tokens) =>
    tokens >= 1000000 ? '1M' : '${(tokens / 1000).round()}K';

String newLocalId() {
  final randomPart = Random.secure().nextInt(1 << 32).toRadixString(36);
  return DateTime.now().microsecondsSinceEpoch.toRadixString(36) + randomPart;
}

class ChatFileAttachment {
  const ChatFileAttachment({
    required this.name,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String name;
  final String path;
  final String mimeType;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
  };

  factory ChatFileAttachment.fromJson(Map<String, dynamic> json) =>
      ChatFileAttachment(
        name: json['name'] as String? ?? '附件',
        path: json['path'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

class ChatImageAttachment {
  const ChatImageAttachment({
    required this.name,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String name;
  final String path;
  final String mimeType;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
  };

  factory ChatImageAttachment.fromJson(Map<String, dynamic> json) =>
      ChatImageAttachment(
        name: json['name'] as String? ?? '图片',
        path: json['path'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'image/jpeg',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.displayContent,
    this.reasoning = '',
    this.filePath,
    this.fileName,
    this.fileMimeType,
    this.fileSizeBytes,
    this.imageDataBase64,
    this.imageMimeType,
    List<ChatFileAttachment>? fileAttachments,
    List<ChatImageAttachment>? imageAttachments,
    this.documentId,
    this.apiProfileId,
    this.providerName,
    this.modelName,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.usageStatus,
    this.processingDurationMs,
    this.annotation,
    List<String>? versions,
    List<Map<String, dynamic>>? versionMetadata,
    this.selectedVersionIndex = 0,
    this.thinkingStatus = '',
    this.generationStatus,
    this.generationError,
    DateTime? createdAt,
    String? id,
  }) : createdAt = createdAt ?? DateTime.now(),
       id = id ?? newLocalId(),
       fileAttachments = fileAttachments ?? <ChatFileAttachment>[],
       imageAttachments = imageAttachments ?? <ChatImageAttachment>[],
       versions = versions ?? <String>[],
       versionMetadata = versionMetadata ?? <Map<String, dynamic>>[];

  final String id;
  final String role;
  String content;
  final String? displayContent;
  String reasoning;
  final String? filePath;
  final String? fileName;
  final String? fileMimeType;
  final int? fileSizeBytes;
  final String? imageDataBase64;
  final String? imageMimeType;
  final List<ChatFileAttachment> fileAttachments;
  final List<ChatImageAttachment> imageAttachments;
  final String? documentId;
  String? apiProfileId;
  String? providerName;
  String? modelName;
  int? inputTokens;
  int? outputTokens;
  int? totalTokens;

  /// `actual`, `partial`, `estimated`, or `unavailable`.
  String? usageStatus;
  int? processingDurationMs;
  String? annotation;
  List<String> versions;
  List<Map<String, dynamic>> versionMetadata;
  int selectedVersionIndex;
  String thinkingStatus;
  String? generationStatus;
  String? generationError;
  final DateTime createdAt;

  void selectVersion(int index) {
    if (versions.isEmpty || index < 0 || index >= versions.length) return;
    selectedVersionIndex = index;
    content = versions[index];
    processingDurationMs = null;
    if (index < versionMetadata.length) {
      final metadata = versionMetadata[index];
      apiProfileId = metadata['apiProfileId'] as String?;
      providerName = metadata['providerName'] as String?;
      modelName = metadata['modelName'] as String?;
      inputTokens = (metadata['inputTokens'] as num?)?.toInt();
      outputTokens = (metadata['outputTokens'] as num?)?.toInt();
      totalTokens = (metadata['totalTokens'] as num?)?.toInt();
      usageStatus = metadata['usageStatus'] as String?;
      processingDurationMs = (metadata['processingDurationMs'] as num?)
          ?.toInt();
      thinkingStatus = metadata['thinkingStatus'] as String? ?? '';
    }
  }

  void addVersion(String value, {Map<String, dynamic>? metadata}) {
    if (versions.isEmpty) {
      versions = <String>[content];
      versionMetadata = <Map<String, dynamic>>[_currentMetadata()];
    }
    versionMetadata = <Map<String, dynamic>>[
      for (var index = 0; index < versions.length; index++)
        if (index < versionMetadata.length)
          versionMetadata[index]
        else if (index == selectedVersionIndex)
          _currentMetadata()
        else
          <String, dynamic>{},
      metadata ?? _currentMetadata(),
    ];
    versions = <String>[...versions, value];
    selectedVersionIndex = versions.length - 1;
    content = value;
    selectVersion(selectedVersionIndex);
  }

  Map<String, dynamic> _currentMetadata() => {
    if (apiProfileId != null) 'apiProfileId': apiProfileId,
    if (providerName != null) 'providerName': providerName,
    if (modelName != null) 'modelName': modelName,
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (outputTokens != null) 'outputTokens': outputTokens,
    if (totalTokens != null) 'totalTokens': totalTokens,
    if (usageStatus != null) 'usageStatus': usageStatus,
    if (processingDurationMs != null)
      'processingDurationMs': processingDurationMs,
    if (thinkingStatus.isNotEmpty) 'thinkingStatus': thinkingStatus,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (displayContent != null) 'displayContent': displayContent,
    if (filePath != null) 'filePath': filePath,
    if (fileName != null) 'fileName': fileName,
    if (fileMimeType != null) 'fileMimeType': fileMimeType,
    if (fileSizeBytes != null) 'fileSizeBytes': fileSizeBytes,
    if (imageDataBase64 != null) 'imageDataBase64': imageDataBase64,
    if (imageMimeType != null) 'imageMimeType': imageMimeType,
    if (fileAttachments.isNotEmpty)
      'fileAttachments': fileAttachments.map((item) => item.toJson()).toList(),
    if (imageAttachments.isNotEmpty)
      'imageAttachments': imageAttachments
          .map((item) => item.toJson())
          .toList(),
    if (documentId != null) 'documentId': documentId,
    if (apiProfileId != null) 'apiProfileId': apiProfileId,
    if (providerName != null) 'providerName': providerName,
    if (modelName != null) 'modelName': modelName,
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (outputTokens != null) 'outputTokens': outputTokens,
    if (totalTokens != null) 'totalTokens': totalTokens,
    if (usageStatus != null) 'usageStatus': usageStatus,
    if (processingDurationMs != null)
      'processingDurationMs': processingDurationMs,
    if (annotation != null) 'annotation': annotation,
    if (versions.isNotEmpty) 'versions': versions,
    if (versionMetadata.isNotEmpty) 'versionMetadata': versionMetadata,
    if (versions.isNotEmpty) 'selectedVersionIndex': selectedVersionIndex,
    if (thinkingStatus.isNotEmpty) 'thinkingStatus': thinkingStatus,
    if (generationStatus != null) 'generationStatus': generationStatus,
    if (generationError != null) 'generationError': generationError,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String?,
    role: json['role'] as String? ?? 'user',
    content: json['content'] as String? ?? '',
    displayContent: json['displayContent'] as String?,
    reasoning: json['reasoning'] as String? ?? '',
    filePath: json['filePath'] as String?,
    fileName: json['fileName'] as String?,
    fileMimeType: json['fileMimeType'] as String?,
    fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt(),
    imageDataBase64: json['imageDataBase64'] as String?,
    imageMimeType: json['imageMimeType'] as String?,
    fileAttachments: (json['fileAttachments'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .map(ChatFileAttachment.fromJson)
        .toList(),
    imageAttachments: (json['imageAttachments'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .map(ChatImageAttachment.fromJson)
        .toList(),
    documentId: json['documentId'] as String?,
    apiProfileId: json['apiProfileId'] as String?,
    providerName: json['providerName'] as String?,
    modelName: json['modelName'] as String?,
    inputTokens: (json['inputTokens'] as num?)?.toInt(),
    outputTokens: (json['outputTokens'] as num?)?.toInt(),
    totalTokens: (json['totalTokens'] as num?)?.toInt(),
    usageStatus: json['usageStatus'] as String?,
    processingDurationMs: (json['processingDurationMs'] as num?)?.toInt(),
    annotation: json['annotation'] as String?,
    versions: (json['versions'] as List<dynamic>?)
        ?.whereType<String>()
        .toList(),
    versionMetadata: (json['versionMetadata'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .toList(),
    selectedVersionIndex: (json['selectedVersionIndex'] as num?)?.toInt() ?? 0,
    thinkingStatus: json['thinkingStatus'] as String? ?? '',
    generationStatus: json['generationStatus'] as String?,
    generationError: json['generationError'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );
}

class ImportantMemoryRecord {
  const ImportantMemoryRecord({
    required this.id,
    required this.key,
    required this.category,
    required this.content,
    required this.keywords,
    required this.recordedAtUtc,
    required this.timestampLabel,
    required this.sourceWindowId,
    this.supersedesId,
    this.sourceMessageId,
    this.sourceMessageIndex,
  });

  final String id;
  final String key;
  final String category;
  final String content;
  final List<String> keywords;
  final DateTime recordedAtUtc;
  final String timestampLabel;
  final String sourceWindowId;
  final String? supersedesId;
  final String? sourceMessageId;
  final int? sourceMessageIndex;

  Map<String, dynamic> toJson() => {
    'recordedAtUtc': recordedAtUtc.toUtc().toIso8601String(),
    'timestampLabel': timestampLabel,
    'id': id,
    'key': key,
    'category': category,
    'content': content,
    'keywords': keywords,
    'sourceWindowId': sourceWindowId,
    if (supersedesId != null) 'supersedesId': supersedesId,
    if (sourceMessageId != null) 'sourceMessageId': sourceMessageId,
    if (sourceMessageIndex != null) 'sourceMessageIndex': sourceMessageIndex,
  };

  factory ImportantMemoryRecord.fromJson(Map<String, dynamic> json) =>
      ImportantMemoryRecord(
        id: json['id'] as String? ?? newLocalId(),
        key: json['key'] as String? ?? 'legacy:${json['id'] ?? ''}',
        category: json['category'] as String? ?? '本地记忆',
        content: json['content'] as String? ?? '',
        keywords: (json['keywords'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        recordedAtUtc:
            DateTime.tryParse(json['recordedAtUtc'] as String? ?? '')
                ?.toUtc() ??
            DateTime.now().toUtc(),
        timestampLabel: json['timestampLabel'] as String? ?? '时间未知（旧版记忆）',
        sourceWindowId: json['sourceWindowId'] as String? ?? '',
        supersedesId: json['supersedesId'] as String?,
        sourceMessageId: json['sourceMessageId'] as String?,
        sourceMessageIndex: (json['sourceMessageIndex'] as num?)?.toInt(),
      );
}

String formatLocalTimestamp(DateTime value) {
  final offset = value.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  final zone =
      'UTC$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';
  return '${value.toIso8601String()} $zone (${value.timeZoneName})';
}

class ChatThread {
  ChatThread({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.titleIsManual = false,
    this.apiProfileId = '',
    this.webSearchEnabled = false,
    this.injectLocalTimestamp = false,
    this.deepThinkingEnabled = false,
    this.thinkingLevel = 'default',
    this.humanizerEnabled = false,
    this.folderName = '',
    List<ChatMessage>? messages,
    int? messageCount,
    this.messageBaseIndex = 0,
    List<ImportantMemoryRecord>? windowMemories,
    this.localNote = '',
    this.localNoteUpdatedAt = '',
    this.rollingSummary = '',
    this.rollingSummaryUpdatedAt = '',
    this.summaryCursor = 0,
    this.lastUserMessageAt,
    this.isArchived = false,
    this.archiveReason = '',
    this.successorThreadId = '',
    this.handoffSummary = '',
    this.handoffStatus = 'none',
    this.handoffUpdatedAt = '',
    this.handoffFocusQuery = '',
    this.handoffSourceThreadId = '',
    List<String>? handoffSourceMessageIds,
    this.autoCompressOverride,
    this.storySimulatorEnabled = false,
    this.storyGlobalMemoryText = '',
    this.storyTime = '第 1 日 · 剧情开始',
    List<StoryTurnSummary>? storySummaries,
  }) : messages = messages ?? <ChatMessage>[],
       messageCount = messageCount ?? (messages?.length ?? 0),
       windowMemories = windowMemories ?? <ImportantMemoryRecord>[],
       handoffSourceMessageIds = handoffSourceMessageIds ?? <String>[],
       storySummaries = storySummaries ?? <StoryTurnSummary>[];

  final String id;
  String title;
  bool titleIsManual;
  String apiProfileId;
  bool? webSearchEnabled;
  bool? injectLocalTimestamp;
  bool? deepThinkingEnabled;
  String? thinkingLevel;
  bool? humanizerEnabled;
  String folderName;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  int messageCount;
  int messageBaseIndex;
  final List<ImportantMemoryRecord> windowMemories;
  String localNote;
  String localNoteUpdatedAt;
  String rollingSummary;
  String rollingSummaryUpdatedAt;

  /// Number of transcript messages already compressed into rollingSummary.
  int summaryCursor;
  DateTime? lastUserMessageAt;
  bool isArchived;
  String archiveReason;
  String successorThreadId;
  String handoffSummary;
  String handoffStatus;
  String handoffUpdatedAt;
  String handoffFocusQuery;
  String handoffSourceThreadId;
  List<String> handoffSourceMessageIds;
  bool? autoCompressOverride;
  bool storySimulatorEnabled;
  String storyGlobalMemoryText;
  String storyTime;
  final List<StoryTurnSummary> storySummaries;

  factory ChatThread.create({
    String apiProfileId = deepSeekDefaultProfileId,
    bool injectLocalTimestamp = false,
  }) {
    final now = DateTime.now();
    return ChatThread(
      id: newLocalId(),
      title: '新对话',
      apiProfileId: apiProfileId,
      injectLocalTimestamp: injectLocalTimestamp,
      createdAt: now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> toJson({bool includeMessages = true}) => {
    'id': id,
    'title': title,
    'titleIsManual': titleIsManual,
    'apiProfileId': apiProfileId,
    if (webSearchEnabled != null) 'webSearchEnabled': webSearchEnabled,
    if (injectLocalTimestamp != null)
      'injectLocalTimestamp': injectLocalTimestamp,
    if (deepThinkingEnabled != null) 'deepThinkingEnabled': deepThinkingEnabled,
    if (thinkingLevel != null) 'thinkingLevel': thinkingLevel,
    if (humanizerEnabled != null) 'humanizerEnabled': humanizerEnabled,
    if (folderName.isNotEmpty) 'folderName': folderName,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messageCount': messageCount,
    'messageBaseIndex': messageBaseIndex,
    if (includeMessages)
      'messages': messages.map((message) => message.toJson()).toList(),
    'windowMemories': windowMemories.map((memory) => memory.toJson()).toList(),
    'localNote': localNote,
    'localNoteUpdatedAt': localNoteUpdatedAt,
    'rollingSummary': rollingSummary,
    'rollingSummaryUpdatedAt': rollingSummaryUpdatedAt,
    'summaryCursor': summaryCursor,
    if (lastUserMessageAt != null)
      'lastUserMessageAt': lastUserMessageAt!.toIso8601String(),
    'isArchived': isArchived,
    'archiveReason': archiveReason,
    'successorThreadId': successorThreadId,
    'handoffSummary': handoffSummary,
    'handoffStatus': handoffStatus,
    'handoffUpdatedAt': handoffUpdatedAt,
    'handoffFocusQuery': handoffFocusQuery,
    'handoffSourceThreadId': handoffSourceThreadId,
    'handoffSourceMessageIds': handoffSourceMessageIds,
    if (autoCompressOverride != null)
      'autoCompressOverride': autoCompressOverride,
    'storySimulatorEnabled': storySimulatorEnabled,
    'storyGlobalMemoryText': storyGlobalMemoryText,
    'storyTime': storyTime,
    'storySummaries': storySummaries.map((item) => item.toJson()).toList(),
  };

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List<dynamic>? ?? const [];
    final rawMemories = json['windowMemories'] as List<dynamic>? ?? const [];
    return ChatThread(
      id: json['id'] as String? ?? newLocalId(),
      title: json['title'] as String? ?? '新对话',
      titleIsManual: json['titleIsManual'] as bool? ?? false,
      apiProfileId: json['apiProfileId'] as String? ?? '',
      webSearchEnabled: json['webSearchEnabled'] as bool?,
      injectLocalTimestamp: json['injectLocalTimestamp'] as bool?,
      deepThinkingEnabled: json['deepThinkingEnabled'] as bool?,
      thinkingLevel: json['thinkingLevel'] as String?,
      humanizerEnabled: json['humanizerEnabled'] as bool?,
      folderName: json['folderName'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      messages: rawMessages
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
      messageCount:
          (json['messageCount'] as num?)?.toInt() ?? rawMessages.length,
      messageBaseIndex: (json['messageBaseIndex'] as num?)?.toInt() ?? 0,
      windowMemories: rawMemories
          .whereType<Map<String, dynamic>>()
          .map(ImportantMemoryRecord.fromJson)
          .toList(),
      localNote: json['localNote'] as String? ?? '',
      localNoteUpdatedAt: json['localNoteUpdatedAt'] as String? ?? '',
      rollingSummary: json['rollingSummary'] as String? ?? '',
      rollingSummaryUpdatedAt: json['rollingSummaryUpdatedAt'] as String? ?? '',
      summaryCursor: (json['summaryCursor'] as num?)?.toInt() ?? 0,
      lastUserMessageAt: DateTime.tryParse(
        json['lastUserMessageAt'] as String? ?? '',
      ),
      isArchived: json['isArchived'] as bool? ?? false,
      archiveReason: json['archiveReason'] as String? ?? '',
      successorThreadId: json['successorThreadId'] as String? ?? '',
      handoffSummary: json['handoffSummary'] as String? ?? '',
      handoffStatus: json['handoffStatus'] as String? ?? 'none',
      handoffUpdatedAt: json['handoffUpdatedAt'] as String? ?? '',
      handoffFocusQuery: json['handoffFocusQuery'] as String? ?? '',
      handoffSourceThreadId: json['handoffSourceThreadId'] as String? ?? '',
      handoffSourceMessageIds:
          (json['handoffSourceMessageIds'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
      autoCompressOverride: json['autoCompressOverride'] as bool?,
      storySimulatorEnabled: json['storySimulatorEnabled'] as bool? ?? false,
      storyGlobalMemoryText: json['storyGlobalMemoryText'] as String? ?? '',
      storyTime: json['storyTime'] as String? ?? '第 1 日 · 剧情开始',
      storySummaries: (json['storySummaries'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(StoryTurnSummary.fromJson)
          .toList(),
    );
  }
}

class ApiProfile {
  const ApiProfile({
    required this.id,
    required this.name,
    this.providerName = '',
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.contextWindowTokens = 1000000,
    this.autoCompressContext = true,
    this.autoCompressAtPercent = 80,
    this.supportsThinkingToggle = false,
    this.supportsThinkingLevels = false,
    this.supportsImages = false,
    this.supportsFiles = false,
  });

  final String id;
  final String name;
  final String providerName;
  final String baseUrl;
  final String model;
  final String apiKey;
  final int contextWindowTokens;
  final bool autoCompressContext;
  final int autoCompressAtPercent;
  final bool supportsThinkingToggle;
  final bool supportsThinkingLevels;
  final bool supportsImages;
  final bool supportsFiles;

  ApiProfile copyWith({
    String? name,
    String? providerName,
    String? baseUrl,
    String? model,
    String? apiKey,
    int? contextWindowTokens,
    bool? autoCompressContext,
    int? autoCompressAtPercent,
    bool? supportsThinkingToggle,
    bool? supportsThinkingLevels,
    bool? supportsImages,
    bool? supportsFiles,
  }) => ApiProfile(
    id: id,
    name: name ?? this.name,
    providerName: providerName ?? this.providerName,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    autoCompressContext: autoCompressContext ?? this.autoCompressContext,
    autoCompressAtPercent: autoCompressAtPercent ?? this.autoCompressAtPercent,
    supportsThinkingToggle:
        supportsThinkingToggle ?? this.supportsThinkingToggle,
    supportsThinkingLevels:
        supportsThinkingLevels ?? this.supportsThinkingLevels,
    supportsImages: supportsImages ?? this.supportsImages,
    supportsFiles: supportsFiles ?? this.supportsFiles,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'providerName': providerName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'contextWindowTokens': contextWindowTokens,
    'autoCompressContext': autoCompressContext,
    'autoCompressAtPercent': autoCompressAtPercent,
    'supportsThinkingToggle': supportsThinkingToggle,
    'supportsThinkingLevels': supportsThinkingLevels,
    'supportsImages': supportsImages,
    'supportsFiles': supportsFiles,
  };

  factory ApiProfile.fromJson(Map<String, dynamic> json) {
    final contextWindow =
        (json['contextWindowTokens'] as num?)?.toInt() ?? 1000000;
    final threshold = (json['autoCompressAtPercent'] as num?)?.toInt() ?? 80;
    return ApiProfile(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? (json['id'] as String).trim()
          : newLocalId(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'API 配置',
      providerName: (json['providerName'] as String?)?.trim().isNotEmpty == true
          ? (json['providerName'] as String).trim()
          : ((json['name'] as String?)?.trim().isNotEmpty == true
                ? (json['name'] as String).trim()
                : '自定义服务'),
      baseUrl: (json['baseUrl'] as String?)?.trim().isNotEmpty == true
          ? (json['baseUrl'] as String).trim()
          : deepSeekApiBaseUrl,
      model: (json['model'] as String?)?.trim().isNotEmpty == true
          ? (json['model'] as String).trim()
          : deepSeekFlashModel,
      apiKey: json['apiKey'] as String? ?? '',
      contextWindowTokens: contextWindow.clamp(16000, 1000000).toInt(),
      autoCompressContext: json['autoCompressContext'] as bool? ?? true,
      autoCompressAtPercent: const [60, 70, 80, 90].contains(threshold)
          ? threshold
          : 80,
      supportsThinkingToggle:
          json['supportsThinkingToggle'] as bool? ??
          ((json['id'] as String?) == deepSeekDefaultProfileId),
      supportsThinkingLevels: json['supportsThinkingLevels'] as bool? ?? false,
      supportsImages: json['supportsImages'] as bool? ?? false,
      supportsFiles: json['supportsFiles'] as bool? ?? false,
    );
  }
}

const _defaultDeepSeekProfile = ApiProfile(
  id: deepSeekDefaultProfileId,
  name: 'DeepSeek',
  providerName: 'DeepSeek',
  baseUrl: deepSeekApiBaseUrl,
  model: deepSeekFlashModel,
  apiKey: '',
  supportsThinkingToggle: true,
);

class ModelSettings {
  const ModelSettings({
    this.baseUrl = deepSeekApiBaseUrl,
    this.model = deepSeekFlashModel,
    this.apiKey = '',
    this.globalSystemPrompt = '',
    this.injectLocalTimestamp = false,
    this.webSearchEnabled = false,
    this.useDarkTheme = false,
    this.contextWindowTokens = 1000000,
    this.autoCompressContext = true,
    this.autoCompressAtPercent = 80,
    this.apiProfiles = const [_defaultDeepSeekProfile],
    this.defaultApiProfileId = deepSeekDefaultProfileId,
    this.favoriteApiProfileIds = const <String>[],
    this.supportsThinkingToggle = false,
    this.supportsThinkingLevels = false,
  });

  final String baseUrl;
  final String model;
  final String apiKey;
  final String globalSystemPrompt;
  final bool injectLocalTimestamp;
  final bool webSearchEnabled;
  final bool useDarkTheme;
  final int contextWindowTokens;
  final bool autoCompressContext;
  final int autoCompressAtPercent;
  final List<ApiProfile> apiProfiles;
  final String defaultApiProfileId;
  final List<String> favoriteApiProfileIds;
  final bool supportsThinkingToggle;
  final bool supportsThinkingLevels;

  bool hasApiProfile(String id) =>
      apiProfiles.any((profile) => profile.id == id);

  ApiProfile profileFor(String? id) {
    for (final profile in apiProfiles) {
      if (profile.id == id) return profile;
    }
    for (final profile in apiProfiles) {
      if (profile.id == defaultApiProfileId) return profile;
    }
    return apiProfiles.isEmpty ? _defaultDeepSeekProfile : apiProfiles.first;
  }

  ModelSettings forProfile(String? id) {
    final profile = profileFor(id);
    return copyWith(
      baseUrl: profile.baseUrl,
      model: profile.model,
      apiKey: profile.apiKey,
      contextWindowTokens: profile.contextWindowTokens,
      autoCompressContext: profile.autoCompressContext,
      autoCompressAtPercent: profile.autoCompressAtPercent,
      supportsThinkingToggle: profile.supportsThinkingToggle,
      supportsThinkingLevels: profile.supportsThinkingLevels,
    );
  }

  ModelSettings copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
    String? globalSystemPrompt,
    bool? injectLocalTimestamp,
    bool? webSearchEnabled,
    bool? useDarkTheme,
    int? contextWindowTokens,
    bool? autoCompressContext,
    int? autoCompressAtPercent,
    List<ApiProfile>? apiProfiles,
    String? defaultApiProfileId,
    List<String>? favoriteApiProfileIds,
    bool? supportsThinkingToggle,
    bool? supportsThinkingLevels,
  }) => ModelSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    globalSystemPrompt: globalSystemPrompt ?? this.globalSystemPrompt,
    injectLocalTimestamp: injectLocalTimestamp ?? this.injectLocalTimestamp,
    webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
    useDarkTheme: useDarkTheme ?? this.useDarkTheme,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    autoCompressContext: autoCompressContext ?? this.autoCompressContext,
    autoCompressAtPercent: autoCompressAtPercent ?? this.autoCompressAtPercent,
    apiProfiles: apiProfiles ?? this.apiProfiles,
    defaultApiProfileId: defaultApiProfileId ?? this.defaultApiProfileId,
    favoriteApiProfileIds: favoriteApiProfileIds ?? this.favoriteApiProfileIds,
    supportsThinkingToggle:
        supportsThinkingToggle ?? this.supportsThinkingToggle,
    supportsThinkingLevels:
        supportsThinkingLevels ?? this.supportsThinkingLevels,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'globalSystemPrompt': globalSystemPrompt,
    'injectLocalTimestamp': injectLocalTimestamp,
    'webSearchEnabled': webSearchEnabled,
    'useDarkTheme': useDarkTheme,
    'contextWindowTokens': contextWindowTokens,
    'autoCompressContext': autoCompressContext,
    'autoCompressAtPercent': autoCompressAtPercent,
    'apiProfiles': apiProfiles.map((profile) => profile.toJson()).toList(),
    'defaultApiProfileId': defaultApiProfileId,
    'favoriteApiProfileIds': favoriteApiProfileIds,
    'supportsThinkingToggle': supportsThinkingToggle,
    'supportsThinkingLevels': supportsThinkingLevels,
  };

  factory ModelSettings.fromJson(Map<String, dynamic> json) {
    final savedBaseUrl = json['baseUrl'] as String?;
    final baseUrl = savedBaseUrl?.trim().isNotEmpty == true
        ? savedBaseUrl!.trim()
        : deepSeekApiBaseUrl;
    final model = (json['model'] as String?)?.trim().isNotEmpty == true
        ? (json['model'] as String).trim()
        : deepSeekFlashModel;
    final apiKey = json['apiKey'] as String? ?? '';
    final savedContextWindow =
        (json['contextWindowTokens'] as num?)?.toInt() ?? 1000000;
    final savedCompressionThreshold =
        (json['autoCompressAtPercent'] as num?)?.toInt() ?? 80;
    final legacyContextWindow = savedContextWindow
        .clamp(16000, 1000000)
        .toInt();
    final legacyThreshold =
        const [60, 70, 80, 90].contains(savedCompressionThreshold)
        ? savedCompressionThreshold
        : 80;
    final parsedProfiles = (json['apiProfiles'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ApiProfile.fromJson)
        .toList();
    var profiles = parsedProfiles;
    var defaultProfileId = json['defaultApiProfileId'] as String?;
    if (profiles.isEmpty) {
      final legacyIsDeepSeek =
          Uri.tryParse(baseUrl)?.host.toLowerCase() == 'api.deepseek.com';
      final legacyProfile = ApiProfile(
        id: legacyIsDeepSeek ? deepSeekDefaultProfileId : 'legacy-custom',
        name: legacyIsDeepSeek ? 'DeepSeek' : '旧版 API 配置',
        providerName: legacyIsDeepSeek
            ? 'DeepSeek'
            : (Uri.tryParse(baseUrl)?.host ?? '旧版自定义服务'),
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
        contextWindowTokens: legacyContextWindow,
        autoCompressContext: json['autoCompressContext'] as bool? ?? true,
        autoCompressAtPercent: legacyThreshold,
      );
      profiles = legacyIsDeepSeek
          ? [legacyProfile]
          : [_defaultDeepSeekProfile, legacyProfile];
      defaultProfileId = legacyProfile.id;
    }
    if (!profiles.any((profile) => profile.id == deepSeekDefaultProfileId)) {
      profiles = [_defaultDeepSeekProfile, ...profiles];
    }
    if (defaultProfileId == null ||
        !profiles.any((profile) => profile.id == defaultProfileId)) {
      defaultProfileId = profiles.first.id;
    }
    final defaultProfile = profiles.firstWhere(
      (profile) => profile.id == defaultProfileId,
      orElse: () => profiles.first,
    );
    return ModelSettings(
      baseUrl: defaultProfile.baseUrl,
      model: defaultProfile.model,
      apiKey: defaultProfile.apiKey,
      globalSystemPrompt: json['globalSystemPrompt'] as String? ?? '',
      injectLocalTimestamp: json['injectLocalTimestamp'] as bool? ?? false,
      webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      useDarkTheme: json['useDarkTheme'] as bool? ?? false,
      contextWindowTokens: defaultProfile.contextWindowTokens,
      autoCompressContext: defaultProfile.autoCompressContext,
      autoCompressAtPercent: defaultProfile.autoCompressAtPercent,
      apiProfiles: profiles,
      defaultApiProfileId: defaultProfileId,
      favoriteApiProfileIds:
          (json['favoriteApiProfileIds'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
      supportsThinkingToggle: json['supportsThinkingToggle'] as bool? ?? false,
      supportsThinkingLevels: json['supportsThinkingLevels'] as bool? ?? false,
    );
  }
}
