import 'package:flutter/foundation.dart';

import 'chat_models.dart';

class LocalDocumentChunk {
  LocalDocumentChunk({
    required this.id,
    required this.index,
    required this.start,
    required this.end,
    required this.section,
    required this.forcedBoundary,
    required this.keywords,
    this.status = 'pending',
    this.summary = '',
    this.error = '',
    this.profileId = '',
    this.modelName = '',
    this.inputTokens,
    this.outputTokens,
  });

  final String id;
  int index;
  final int start;
  final int end;
  final String section;
  final bool forcedBoundary;
  final List<String> keywords;
  String status;
  String summary;
  String error;
  String profileId;
  String modelName;
  int? inputTokens;
  int? outputTokens;

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'start': start,
    'end': end,
    'section': section,
    'forcedBoundary': forcedBoundary,
    'keywords': keywords,
    'status': status,
    'summary': summary,
    'error': error,
    'profileId': profileId,
    'modelName': modelName,
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (outputTokens != null) 'outputTokens': outputTokens,
  };

  factory LocalDocumentChunk.fromJson(Map<String, dynamic> json) =>
      LocalDocumentChunk(
        id: json['id'] as String? ?? newLocalId(),
        index: (json['index'] as num?)?.toInt() ?? 0,
        start: (json['start'] as num?)?.toInt() ?? 0,
        end: (json['end'] as num?)?.toInt() ?? 0,
        section: json['section'] as String? ?? '',
        forcedBoundary: json['forcedBoundary'] as bool? ?? false,
        keywords: (json['keywords'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        status: json['status'] as String? ?? 'pending',
        summary: json['summary'] as String? ?? '',
        error: json['error'] as String? ?? '',
        profileId: json['profileId'] as String? ?? '',
        modelName: json['modelName'] as String? ?? '',
        inputTokens: (json['inputTokens'] as num?)?.toInt(),
        outputTokens: (json['outputTokens'] as num?)?.toInt(),
      );
}

class LocalDocumentSummaryNode {
  LocalDocumentSummaryNode({
    required this.id,
    required this.level,
    required this.start,
    required this.end,
    required this.section,
    required this.summary,
    required this.sourceChunkIds,
  });

  final String id;
  final int level;
  final int start;
  final int end;
  final String section;
  final String summary;
  final List<String> sourceChunkIds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'level': level,
    'start': start,
    'end': end,
    'section': section,
    'summary': summary,
    'sourceChunkIds': sourceChunkIds,
  };

  factory LocalDocumentSummaryNode.fromJson(Map<String, dynamic> json) =>
      LocalDocumentSummaryNode(
        id: json['id'] as String? ?? newLocalId(),
        level: (json['level'] as num?)?.toInt() ?? 0,
        start: (json['start'] as num?)?.toInt() ?? 0,
        end: (json['end'] as num?)?.toInt() ?? 0,
        section: json['section'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        sourceChunkIds: (json['sourceChunkIds'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
      );
}

class LocalDocumentRecord {
  LocalDocumentRecord({
    required this.id,
    required this.threadId,
    required this.name,
    required this.createdAt,
    required this.sourceLength,
    this.updatedAt = '',
    this.initialQuestion = '',
    this.status = 'pending',
    this.error = '',
    this.attachedMessageId = '',
    this.overview = '',
    List<LocalDocumentChunk>? chunks,
    List<List<LocalDocumentSummaryNode>>? summaryLayers,
    List<Map<String, dynamic>>? revisions,
    this.selectedRevisionIndex = -1,
  }) : chunks = chunks ?? <LocalDocumentChunk>[],
       summaryLayers = summaryLayers ?? <List<LocalDocumentSummaryNode>>[],
       revisions = revisions ?? <Map<String, dynamic>>[];

  final String id;
  final String threadId;
  final String name;
  final DateTime createdAt;
  final int sourceLength;
  String updatedAt;
  String initialQuestion;
  String status;
  String error;
  String attachedMessageId;
  String overview;
  List<LocalDocumentChunk> chunks;
  List<List<LocalDocumentSummaryNode>> summaryLayers;
  List<Map<String, dynamic>> revisions;
  int selectedRevisionIndex;

  bool get isComplete => status == 'complete' && overview.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'threadId': threadId,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'sourceLength': sourceLength,
    'updatedAt': updatedAt,
    'initialQuestion': initialQuestion,
    'status': status,
    'error': error,
    'attachedMessageId': attachedMessageId,
    'overview': overview,
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
    'summaryLayers': summaryLayers
        .map((layer) => layer.map((node) => node.toJson()).toList())
        .toList(),
    'revisions': revisions,
    'selectedRevisionIndex': selectedRevisionIndex,
  };

  factory LocalDocumentRecord.fromJson(Map<String, dynamic> json) {
    final rawLayers = json['summaryLayers'] as List<dynamic>? ?? const [];
    return LocalDocumentRecord(
      id: json['id'] as String? ?? newLocalId(),
      threadId: json['threadId'] as String? ?? '',
      name: json['name'] as String? ?? '本机文档',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      sourceLength: (json['sourceLength'] as num?)?.toInt() ?? 0,
      updatedAt: json['updatedAt'] as String? ?? '',
      initialQuestion: json['initialQuestion'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      error: json['error'] as String? ?? '',
      attachedMessageId: json['attachedMessageId'] as String? ?? '',
      overview: json['overview'] as String? ?? '',
      chunks: (json['chunks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LocalDocumentChunk.fromJson)
          .toList(),
      summaryLayers: rawLayers
          .whereType<List<dynamic>>()
          .map(
            (layer) => layer
                .whereType<Map<String, dynamic>>()
                .map(LocalDocumentSummaryNode.fromJson)
                .toList(),
          )
          .toList(),
      revisions: (json['revisions'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
      selectedRevisionIndex:
          (json['selectedRevisionIndex'] as num?)?.toInt() ?? -1,
    );
  }
}

class DocumentSlicePlan {
  const DocumentSlicePlan({
    required this.start,
    required this.end,
    required this.section,
    required this.forcedBoundary,
    required this.keywords,
  });

  final int start;
  final int end;
  final String section;
  final bool forcedBoundary;
  final List<String> keywords;

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'section': section,
    'forcedBoundary': forcedBoundary,
    'keywords': keywords,
  };
}

Future<List<DocumentSlicePlan>> planLocalDocumentSlices({
  required String text,
  required int targetTokens,
  required int hardLimitTokens,
}) async {
  final result = await compute<Map<String, Object>, List<Map<String, dynamic>>>(
    _planDocumentSlicesWorker,
    <String, Object>{
      'text': text,
      'targetTokens': targetTokens,
      'hardLimitTokens': hardLimitTokens,
    },
  );
  return result.map((item) {
    return DocumentSlicePlan(
      start: (item['start'] as num).toInt(),
      end: (item['end'] as num).toInt(),
      section: item['section'] as String,
      forcedBoundary: item['forcedBoundary'] as bool,
      keywords: (item['keywords'] as List<dynamic>)
          .whereType<String>()
          .toList(),
    );
  }).toList();
}

List<Map<String, dynamic>> _planDocumentSlicesWorker(
  Map<String, Object> arguments,
) {
  final text = arguments['text']! as String;
  final targetTokens = (arguments['targetTokens']! as int).clamp(1, 1000000);
  final hardLimitTokens = (arguments['hardLimitTokens']! as int).clamp(
    targetTokens,
    1000000,
  );
  if (text.isEmpty) return <Map<String, dynamic>>[];

  int estimate(String value) {
    var cjk = 0;
    var other = 0;
    for (final rune in value.runes) {
      if ((rune >= 0x3400 && rune <= 0x9fff) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        cjk++;
      } else {
        other++;
      }
    }
    return ((cjk + (other / 3).ceil()) * 1.1).ceil();
  }

  final boundaries = <int>[0];
  for (var index = 0; index < text.length; index++) {
    final code = text.codeUnitAt(index);
    if (code == 10 || code == 13) {
      var end = index + 1;
      while (end < text.length &&
          (text.codeUnitAt(end) == 10 || text.codeUnitAt(end) == 13)) {
        end++;
      }
      boundaries.add(end);
      index = end - 1;
      continue;
    }
    final character = String.fromCharCode(code);
    if (!'。！？.!?；;'.contains(character)) continue;
    if (character == '.' &&
        index > 0 &&
        index + 1 < text.length &&
        _isAsciiDigit(text.codeUnitAt(index - 1)) &&
        _isAsciiDigit(text.codeUnitAt(index + 1))) {
      continue;
    }
    boundaries.add(index + 1);
  }
  if (boundaries.last != text.length) boundaries.add(text.length);

  final headings = <({int start, String title})>[];
  final headingPattern = RegExp(
    r'^(?:#{1,6}\s+(.+)|((?:第\s*\d+\s*(?:页|章|节)|工作表：?\S+).{0,80}))\s*$',
    multiLine: true,
  );
  for (final match in headingPattern.allMatches(text)) {
    final title = (match.group(1) ?? match.group(2) ?? '').trim();
    if (title.isNotEmpty) headings.add((start: match.start, title: title));
  }

  int safeBoundary(int position) {
    var value = position.clamp(0, text.length);
    if (value > 0 &&
        value < text.length &&
        text.codeUnitAt(value - 1) >= 0xd800 &&
        text.codeUnitAt(value - 1) <= 0xdbff &&
        text.codeUnitAt(value) >= 0xdc00 &&
        text.codeUnitAt(value) <= 0xdfff) {
      value--;
    }
    return value;
  }

  int forwardEnd(int start, int tokenLimit) {
    var cjk = 0;
    var other = 0;
    var index = start;
    while (index < text.length) {
      final first = text.codeUnitAt(index);
      var rune = first;
      var width = 1;
      if (first >= 0xd800 && first <= 0xdbff && index + 1 < text.length) {
        final second = text.codeUnitAt(index + 1);
        if (second >= 0xdc00 && second <= 0xdfff) {
          rune = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
          width = 2;
        }
      }
      if ((rune >= 0x3400 && rune <= 0x9fff) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        cjk++;
      } else {
        other++;
      }
      if (((cjk + (other / 3).ceil()) * 1.1).ceil() > tokenLimit) {
        return safeBoundary(index);
      }
      index += width;
    }
    return text.length;
  }

  int nextBoundaryAtOrBefore(int value, int start) {
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (boundaries[mid] <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final index = low - 1;
    return index >= 0 && boundaries[index] > start ? boundaries[index] : -1;
  }

  int nextBoundaryAfter(int value, int maxValue) {
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (boundaries[mid] <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low < boundaries.length && boundaries[low] <= maxValue) {
      return boundaries[low];
    }
    return -1;
  }

  final output = <Map<String, dynamic>>[];
  final wholeDocumentFits = estimate(text) <= hardLimitTokens;
  if (wholeDocumentFits) {
    return <Map<String, dynamic>>[
      _sliceJson(text, 0, text.length, _sectionAt(headings, 0), false),
    ];
  }
  var start = 0;
  while (start < text.length) {
    final hardEnd = forwardEnd(start, hardLimitTokens);
    if (hardEnd >= text.length) {
      output.add(
        _sliceJson(
          text,
          start,
          text.length,
          _sectionAt(headings, start),
          false,
        ),
      );
      break;
    }
    final targetEnd = forwardEnd(start, targetTokens);
    final extensionEnd = forwardEnd(start, (targetTokens * 1.1).floor());
    final maxNaturalEnd = extensionEnd < hardEnd ? extensionEnd : hardEnd;
    final before = nextBoundaryAtOrBefore(targetEnd, start);
    final after = nextBoundaryAfter(targetEnd, maxNaturalEnd);
    var end = -1;
    if (before > start &&
        estimate(text.substring(start, before)) >= targetTokens * 0.65) {
      end = before;
    } else if (after > start) {
      end = after;
    } else if (before > start) {
      end = before;
    }
    final forced = end < 0;
    if (forced) end = targetEnd;
    end = safeBoundary(end);
    if (end <= start) {
      end = safeBoundary(start + 1);
      while (end < text.length && estimate(text.substring(start, end)) <= 1) {
        end = safeBoundary(end + 1);
      }
    }
    if (end > hardEnd) end = hardEnd;
    if (end <= start) end = safeBoundary(start + 1);
    final section = _sectionAt(headings, start);
    output.add(_sliceJson(text, start, end, section, forced));
    start = end;
  }
  return output;
}

bool _isAsciiDigit(int value) => value >= 48 && value <= 57;

String _sectionAt(List<({int start, String title})> headings, int offset) {
  var section = '';
  for (final heading in headings) {
    if (heading.start > offset) break;
    section = heading.title;
  }
  return section;
}

Map<String, dynamic> _sliceJson(
  String text,
  int start,
  int end,
  String section,
  bool forced,
) => {
  'start': start,
  'end': end,
  'section': section,
  'forcedBoundary': forced,
  'keywords': documentKeywords(text.substring(start, end)),
};

List<String> documentKeywords(String text, {int limit = 80}) {
  final counts = <String, int>{};
  for (final match in RegExp(r'[a-zA-Z][a-zA-Z0-9_-]{2,}').allMatches(text)) {
    final term = match.group(0)!.toLowerCase();
    counts.update(term, (value) => value + 1, ifAbsent: () => 1);
  }
  final cjkSegments = RegExp(r'[\u3400-\u9fff]{2,}').allMatches(text);
  for (final match in cjkSegments) {
    final segment = match.group(0)!;
    final width = segment.length >= 5 ? 2 : segment.length;
    for (var i = 0; i + width <= segment.length; i++) {
      final term = segment.substring(i, i + width);
      if (const {
        '我们',
        '你们',
        '他们',
        '这个',
        '那个',
        '因为',
        '所以',
        '如果',
        '但是',
        '可以',
        '不是',
        '一个',
        '进行',
        '相关',
        '内容',
        '文件',
        '文章',
        '目前',
        '以及',
        '其中',
      }.contains(term)) {
        continue;
      }
      counts.update(term, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  final terms = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return terms.take(limit).map((entry) => entry.key).toList();
}

Set<String> documentQueryTerms(String query) =>
    documentKeywords(query, limit: 30).toSet();

int scoreDocumentTerms(Set<String> queryTerms, Iterable<String> candidates) {
  if (queryTerms.isEmpty) return 0;
  final haystack = candidates.join(' ').toLowerCase();
  return queryTerms
      .where((term) => haystack.contains(term.toLowerCase()))
      .length;
}
