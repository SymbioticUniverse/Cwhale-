part of 'resource_radar.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
Iterable<Map<String, dynamic>> _maps(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>() : const [];
List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];
String _text(Object? value) => value is String ? value.trim() : '';
Uri? _https(String text) {
  final uri = Uri.tryParse(text);
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.host.endsWith('.local')
      ? uri
      : null;
}

const _categories = <String, String>{
  'ai': 'AI 与模型',
  'game': '游戏与礼包',
  'software': '软件与应用',
  'cloud': '云服务与主机',
  'vps': 'VPS',
  'domain': '域名',
  'dev': '开发资源',
  'opensource': '开源',
  'goods': '实物与购物',
  'offline': '实物福利',
  'carpool': '拼车拼单',
  'trade': '二手交易',
  'pan': '网盘资源',
  'course': '网课与电子书',
  'edu': '教育',
  'news': '新闻',
  'finance': '财经',
  'tech': '科技',
  'stock': '市场',
  'design': '设计与素材',
  'security': '安全与网络',
  'hardware': '硬件数码',
  'media': '影音会员',
  'headline': '时政要闻',
  'world': '国际要闻',
  'lottery': '抽奖',
  'invite': '邀请码',
  'other': '社区与综合',
};

String radarCategoryLabel(String category) => _categories[category] ?? category;

String _sourceCategory(RadarSource s) {
  final cfg = s._config;
  final hints = _text(cfg['fixedCategory'] ?? cfg['categoryHint']);
  if (hints.isNotEmpty) return hints;
  final feed = _maps(cfg['feeds']).firstOrNull;
  final hint = _text(feed?['categoryHint']);
  if (hint.isNotEmpty) return hint;
  if (s.kind == 'openrouter') return 'ai';
  if (['epic', 'steam', 'gog', 'gamerpower', 'cheapshark'].contains(s.kind))
    return 'game';
  if (s.kind == 'cctv')
    return s.id == 'cctv-economy'
        ? 'finance'
        : s.id == 'cctv-tech'
        ? 'tech'
        : 'news';
  if (s.kind == 'github-readme')
    return s.id == 'github-selfhosted' ? 'opensource' : 'dev';
  final label = s.id + ' ' + s.name;
  return _categoryForText(label) ?? 'other';
}

String? _categoryForText(String text) {
  const rules = <String, String>{
    'game': r'游戏|喜加一|steam|epic|gog\b|itch\.io|game(?:rpower|deal|find|s\b)|keylol|GG\.deals',
    'ai': r'\bai\b|大模型|OpenRouter|模型额度',
    'software': r'软件|AppHookup|应用限免|免费插件|Giveaway of the Day|SharewareOnSale|TickCoupon',
    'cloud': r'云服务|云计算|主机|VPS|cloud',
    'pan': r'网盘|yunpan',
    'course': r'网课|电子书|ebooks|免费教程',
    'goods': r'实物|样品|优惠券|购物|FreebieShark|HeyItsFree|FreeFlys',
    'news': r'新闻|要闻|头条|快讯',
    'finance': r'财经|经济',
    'opensource': r'开源|open.source|自托管',
    'dev': r'开发|API|工程',
    'tech': r'科技|数码',
  };
  for (final rule in rules.entries) {
    if (RegExp(rule.value, caseSensitive: false).hasMatch(text))
      return rule.key;
  }
  return null;
}

bool _categoryMatches(String query, String entry) => switch (query) {
  'all' => true,
  'cloud' => ['cloud', 'vps', 'domain'].contains(entry),
  'goods' => ['goods', 'offline', 'carpool', 'trade'].contains(entry),
  'course' => ['course', 'edu', 'pan'].contains(entry),
  'news' => [
    'news',
    'tech',
    'finance',
    'stock',
    'headline',
    'world',
  ].contains(entry),
  'dev' => ['dev', 'opensource', 'design', 'security'].contains(entry),
  _ => query == entry,
};

int _priority(RadarSource source) {
  if (['epic', 'steam', 'gamerpower', 'openrouter'].contains(source.kind))
    return 4;
  final name = source.name;
  if (RegExp(r'限免|免费|福利|羊毛|goodies', caseSensitive: false).hasMatch(name))
    return 3;
  if (['news', 'finance', 'tech', 'stock'].contains(source.category)) return 1;
  return 2;
}

String _plain(Object? value, int max) {
  final raw = _text(value);
  if (raw.isEmpty) return '';
  final input = raw.length > 24000 ? raw.substring(0, 24000) : raw;
  final normalized = (html.parseFragment(input).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return String.fromCharCodes(normalized.runes.take(max));
}

DateTime? _date(Object? raw) {
  if (raw is num && raw > 0 && raw < 4102444800) {
    return DateTime.fromMillisecondsSinceEpoch(
      (raw * 1000).toInt(),
      isUtc: true,
    );
  }
  final text = _text(raw);
  final iso = DateTime.tryParse(text);
  if (iso != null) return iso;
  try {
    return HttpDate.parse(text);
  } catch (_) {
    return null;
  }
}

_Entry? _entry(
  RadarSource source,
  Object? titleValue,
  Object? linkValue, {
  Object? summary,
  Object? published,
  Object? end,
  String platform = '',
  String? category,
  String? kind,
  String? obtain,
  bool verified = false,
  String base = '',
  String origin = '',
}) {
  final title = _plain(titleValue, 180);
  final rawLink = _text(linkValue);
  if (title.isEmpty || rawLink.isEmpty) return null;
  final uri = Uri.tryParse(base)?.resolve(rawLink) ?? Uri.tryParse(rawLink);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty)
    return null;
  final detail = _plain(summary, 360);
  final suggested = source.category;
  final sourceKind = _text(source._config['kindHint']);
  final group =
      category ??
      (suggested == 'other' ? _categoryForText(title) ?? suggested : suggested);
  final text = title + ' ' + detail;
  final signal = RegExp(
    r'限免|免费领|免费[赠送]|0\s*元|白嫖|喜加一|100%\s*(?:off|discount)|giveaway|\bfree\b|免费额度',
    caseSensitive: false,
  );
  final negative = RegExp(
    r'已结束|已过期|领完|售罄|无效|expired|ended',
    caseSensitive: false,
  );
  final titleRejected = negative.hasMatch(title);
  final format =
      obtain ??
      (RegExp(
            r'抽奖|随机抽|lottery|sweepstakes',
            caseSensitive: false,
          ).hasMatch(title)
          ? '抽奖'
          : RegExp(
              r'试用|试玩|\btrial\b|\bdemo\b',
              caseSensitive: false,
            ).hasMatch(title)
          ? '试用'
          : RegExp(r'返利|推广|affiliat|邀请码', caseSensitive: false).hasMatch(title)
          ? '推广或有条件'
          : '');
  final strongHint =
      sourceKind == 'freebie' ||
      RegExp(
        r'限免|免费样品|免费赠送|100%|FreeGameFindings|FreeEBOOKS|FreeGamesOnSteam',
        caseSensitive: false,
      ).hasMatch(source.name);
  final type = titleRejected
      ? 'expired'
      : kind ??
            (format.isNotEmpty
                ? 'conditional'
                : sourceKind == 'deal' && !signal.hasMatch(title)
                ? 'deal'
                : signal.hasMatch(title) || strongHint && signal.hasMatch(text)
                ? 'freebie'
                : sourceKind == 'news' || group == 'news'
                ? 'news'
                : sourceKind == 'opensource' || group == 'opensource'
                ? 'opensource'
                : RegExp(
                    r'折扣|优惠|好价|discount|sale\b',
                    caseSensitive: false,
                  ).hasMatch(title)
                ? 'deal'
                : 'info');
  final date = _date(published);
  final deadline = _date(end);
  final host = uri.host;
  final inferredPlatform = platform.isNotEmpty
      ? platform
      : <String>[
          if (group == 'game' &&
              RegExp(
                r'steam',
                caseSensitive: false,
              ).hasMatch(host + ' ' + title + ' ' + source.id))
            'Steam',
          if (group == 'game' &&
              RegExp(
                r'epicgames|epic\b',
                caseSensitive: false,
              ).hasMatch(host + ' ' + title))
            'Epic',
          if (group == 'game' &&
              RegExp(
                r'\bgog\b',
                caseSensitive: false,
              ).hasMatch(host + ' ' + title))
            'GOG',
          if (group == 'game' &&
              RegExp(
                r'itch\.io|drm.free|PC\b',
                caseSensitive: false,
              ).hasMatch(host + ' ' + title))
            'PC',
          if (RegExp(
            r'android|googleplay|play\.google',
            caseSensitive: false,
          ).hasMatch(host + ' ' + title + ' ' + source.id))
            'Android',
          if (RegExp(
            r'\bios\b|iphone|apps\.apple',
            caseSensitive: false,
          ).hasMatch(host + ' ' + title))
            'iOS',
        ].join(', ');
  return _Entry(
    title: title,
    url: uri.toString(),
    summary: detail,
    category: group,
    kind: type,
    platform: inferredPlatform,
    verified: verified,
    obtain: format,
    published: date?.millisecondsSinceEpoch ?? 0,
    deadline: deadline?.toIso8601String() ?? '',
    origin: origin,
  );
}

class _Entry {
  const _Entry({
    required this.title,
    required this.url,
    required this.summary,
    required this.category,
    required this.kind,
    required this.platform,
    required this.verified,
    required this.obtain,
    required this.published,
    required this.deadline,
    this.origin = '',
  });
  final String title,
      url,
      summary,
      category,
      kind,
      platform,
      obtain,
      deadline,
      origin;
  final bool verified;
  final int published;

  factory _Entry.fromJson(Map<String, dynamic> e) => _Entry(
    title: _text(e['title']),
    url: _text(e['url']),
    summary: _text(e['summary']),
    category: _text(e['category']),
    kind: _text(e['kind']),
    platform: _text(e['platform']),
    verified: e['verified'] == true,
    obtain: _text(e['obtain']),
    published: e['published'] as int? ?? 0,
    deadline: _text(e['deadline']),
    origin: _text(e['origin']),
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'summary': summary,
    'category': category,
    'kind': kind,
    'platform': platform,
    'verified': verified,
    'obtain': obtain,
    'published': published,
    'deadline': deadline,
    'origin': origin,
  };

  String get key {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    final path = uri?.path ?? '';
    final tags = platform.toLowerCase();
    final storefront = [
      'epic',
      'steam',
      'gog',
    ].where(tags.contains).firstOrNull;
    final gameTitle = title
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*(?:epic games|steam|gog)[^)]*\)'), '')
        .replaceFirst(RegExp(r'\s+giveaway$'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (verified &&
        category == 'game' &&
        storefront != null &&
        gameTitle.isNotEmpty)
      return '$storefront:$gameTitle';
    if (path.isEmpty || path == '/' || uri?.hasQuery == true)
      return uri?.removeFragment().toString() ?? url;
    return '$host$path';
  }

  int get rank => verified && kind == 'freebie'
      ? 5
      : kind == 'freebie'
      ? 4
      : kind == 'conditional'
      ? 3
      : kind == 'deal'
      ? 2
      : 1;
  bool isCurrent(DateTime now) {
    if (kind == 'expired' || title.isEmpty || url.isEmpty) return false;
    final end = DateTime.tryParse(deadline);
    if (end != null) return now.isBefore(end);
    if (published == 0) return true;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(published));
    return age < Duration(days: verified ? 180 : 30);
  }

  bool matchesPlatform(String filter) {
    final label = platform.toLowerCase();
    return switch (filter) {
      'pc' => RegExp(
        r'\bpc\b|steam|epic|\bgog\b|drm.free|itch',
      ).hasMatch(label),
      'mobile' => label.contains('android') || label.contains('ios'),
      'steam' ||
      'epic' ||
      'gog' ||
      'ios' ||
      'android' => label.contains(filter),
      _ => true,
    };
  }

  String display(String source, {required bool cached}) {
    final type = switch (kind) {
      'freebie' => verified ? '来源标记免费' : '免费线索，需看原文核实',
      'conditional' => '有条件活动',
      'deal' => '付费优惠或好价',
      'news' => '新闻',
      'opensource' => '开源',
      _ => '资讯',
    };
    final categoryName = radarCategoryLabel(category);
    return jsonEncode({
      '标题': title,
      '来源': origin.isEmpty ? source : '$source · $origin',
      '类型': type,
      '分类': categoryName,
      '链接': url,
      if (platform.isNotEmpty) '平台': platform,
      if (obtain.isNotEmpty) '方式': obtain,
      if (summary.isNotEmpty) '摘要': summary,
      if (deadline.isNotEmpty) '截止': deadline,
      if (published > 0)
        '发布时间': DateTime.fromMillisecondsSinceEpoch(
          published,
          isUtc: true,
        ).toIso8601String(),
      if (cached) '来源状态': '本次更新失败，使用本机缓存',
    });
  }
}
