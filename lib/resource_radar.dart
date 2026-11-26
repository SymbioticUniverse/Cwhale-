import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A device-local index of currently claimable game offers.
class ResourceRadar {
  ResourceRadar._();

  static final instance = ResourceRadar._();
  static const toolName = 'search_resource_radar';
  static const gamerPowerCredit = '[GamerPower](https://www.gamerpower.com/)';
  static const _freshFor = Duration(minutes: 15);
  static const _keepFor = Duration(hours: 24);
  static const _sources = ['Epic Games', 'GamerPower'];

  static bool matchesRequest(String text) {
    if (RegExp(r'资源雷达|福利雷达', caseSensitive: false).hasMatch(text)) {
      return true;
    }
    return RegExp(
          r'限免|免费|白嫖|喜加一|免费领|赠送|free|giveaway',
          caseSensitive: false,
        ).hasMatch(text) &&
        RegExp(
          r'游戏|大作|game|steam|epic|gog',
          caseSensitive: false,
        ).hasMatch(text) &&
        RegExp(
          r'今天|现在|近期|最近|本周|目前|有哪|有没有|有什么|还有|查|搜|推荐|能领|可以领|[？?]|today|current|this week|find|show|any|what',
          caseSensitive: false,
        ).hasMatch(text);
  }

  final _snapshots = <String, ({DateTime fetchedAt, List<_Offer> offers})>{};
  final _failed = <String>{};
  Future<void>? _refreshing;
  bool _loaded = false;
  DateTime? _lastAttempt;

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() {
    _refreshing = null;
  });

  Future<List<String>> recommendedPrompts() async {
    await refresh();
    final now = DateTime.now();
    final offers = <String, String>{};
    for (final source in _sources) {
      final saved = _snapshots[source];
      if (saved == null || now.difference(saved.fetchedAt) >= _freshFor) {
        continue;
      }
      for (final item in saved.offers) {
        if (!item.matches('pc', '', now)) continue;
        final title = item.title
            .replaceAll(
              RegExp(
                r'\((?:Epic Games|Steam|GOG)[^)]*\)',
                caseSensitive: false,
              ),
              '',
            )
            .replaceFirst(RegExp(r'\s+giveaway$', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (title.isEmpty || title.runes.length > 44) continue;
        offers.putIfAbsent(item.dedupKey, () => '用资源雷达查《$title》的领取方式');
      }
    }
    return offers.values.take(12).toList();
  }

  Future<File> _cacheFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}resource-radar-v1.json',
    );
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final saved = _map(jsonDecode(await (await _cacheFile()).readAsString()));
      for (final name in _sources) {
        final source = _map(saved[name]);
        final fetchedAt = DateTime.tryParse(_text(source['fetchedAt']));
        if (fetchedAt == null) continue;
        _snapshots[name] = (
          fetchedAt: fetchedAt,
          offers: _list(source['offers']).map(_Offer.fromJson).toList(),
        );
      }
    } catch (_) {
      // A missing or unreadable cache never prevents fetching public offers.
    }
  }

  Future<void> _refresh() async {
    await _load();
    final now = DateTime.now();
    final lastAttempt = _lastAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(minutes: 1)) {
      return;
    }
    final due = _sources.where((name) {
      final saved = _snapshots[name];
      return saved == null || now.difference(saved.fetchedAt) >= _freshFor;
    }).toList();
    if (due.isEmpty) return;
    _lastAttempt = now;
    final client = http.Client();
    var changed = false;
    try {
      await Future.wait(
        due.map((name) async {
          try {
            final offers = name == 'Epic Games'
                ? await _epic(client)
                : await _gamerPower(client);
            _snapshots[name] = (fetchedAt: DateTime.now(), offers: offers);
            _failed.remove(name);
            changed = true;
          } catch (_) {
            _failed.add(name);
          }
        }),
      );
    } finally {
      client.close();
    }
    if (!changed) return;
    try {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(
        jsonEncode({
          for (final entry in _snapshots.entries)
            entry.key: {
              'fetchedAt': entry.value.fetchedAt.toIso8601String(),
              'offers': entry.value.offers
                  .map((item) => item.toJson())
                  .toList(),
            },
        }),
        flush: true,
      );
      await pending.rename(file.path);
    } catch (_) {
      // Keep the successful results available in memory.
    }
  }

  Future<String> search({
    required String platform,
    required String keyword,
  }) async {
    await refresh();
    final now = DateTime.now();
    final needle = keyword.trim().toLowerCase();
    final offers = <String, _Offer>{};
    final notes = <String>[];
    for (final source in _sources) {
      final saved = _snapshots[source];
      if (saved == null || now.difference(saved.fetchedAt) >= _keepFor) {
        notes.add('$source 暂不可用。');
        continue;
      }
      if (_failed.contains(source)) {
        notes.add('$source 本次刷新失败，使用 ${saved.fetchedAt.toLocal()} 的缓存。');
      }
      for (final item in saved.offers) {
        if (!item.matches(platform, needle, now)) continue;
        final key = item.dedupKey;
        if (key.isEmpty) continue;
        offers.putIfAbsent(key, () => item);
      }
    }
    final items = offers.values.take(12).toList();
    return [
      if (items.isEmpty)
        notes.length == _sources.length &&
                _snapshots.values.every(
                  (s) => now.difference(s.fetchedAt) >= _keepFor,
                )
            ? '资源雷达当前不可用。'
            : '已读取的来源中没有匹配结果。',
      for (final item in items) item.display(),
      if (items.any((item) => item.source == 'GamerPower'))
        '数据来源：$gamerPowerCredit',
      ...notes,
    ].join('\n\n');
  }

  static Future<Object?> _get(
    http.Client client,
    Uri uri, {
    bool empty201 = false,
  }) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 7));
    if (empty201 && response.statusCode == 201) return const [];
    if (response.statusCode != 200) throw const FormatException('来源不可用');
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 5),
    )) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const FormatException('来源响应过大');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  static Future<List<_Offer>> _epic(http.Client client) async {
    final locale = Platform.localeName.split('.').first.replaceAll('_', '-');
    final country = locale.split('-').last.toUpperCase();
    final region =
        RegExp(r'^[A-Z]{2}$').hasMatch(country) && locale.contains('-')
        ? country
        : 'CN';
    final payload = await _get(
      client,
      Uri.https(
        'store-site-backend-static-ipv4.ak.epicgames.com',
        '/freeGamesPromotions',
        {'locale': locale, 'country': region, 'allowCountries': region},
      ),
    );
    final entries = _map(
      _map(_map(_map(payload)['data'])['Catalog'])['searchStore'],
    )['elements'];
    if (entries is! List) throw const FormatException('Epic 数据格式变化');
    final now = DateTime.now();
    final offers = <_Offer>[];
    for (final item in _list(entries)) {
      final price = _map(_map(item['price'])['totalPrice']);
      if (price['discountPrice'] != 0 ||
          (price['originalPrice'] is num &&
              (price['originalPrice'] as num) <= 0)) {
        continue;
      }
      // Explicit add-ons and editions with no verified full-game classification
      // are not passed off as base game giveaways.
      if (item['offerType'] != 'BASE_GAME') continue;
      final title = _text(item['title']);
      final slug =
          [
                ..._list(item['offerMappings'])
                    .map((mapping) => mapping['pageSlug']),
                item['productSlug'],
                item['urlSlug'],
                ..._list(
                  item['catalogNs'] is Map
                      ? _map(item['catalogNs'])['mappings']
                      : null,
                ).map((mapping) => mapping['pageSlug']),
              ]
              .map(_text)
              .map((value) => value.replaceFirst(RegExp(r'/home$'), ''))
              .firstWhere(
                (value) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value),
                orElse: () => '',
              );
      if (title.isEmpty || slug.isEmpty) continue;
      final promotions = _list(_map(item['promotions'])['promotionalOffers']);
      for (final window in promotions.expand(
        (group) => _list(group['promotionalOffers']),
      )) {
        final start = DateTime.tryParse(_text(window['startDate']));
        final end = DateTime.tryParse(_text(window['endDate']));
        if (_map(window['discountSetting'])['discountPercentage'] != 0 ||
            start == null ||
            end == null ||
            now.isBefore(start) ||
            !now.isBefore(end)) {
          continue;
        }
        offers.add(
          _Offer(
            title: title,
            source: 'Epic Games',
            platforms: 'PC, Epic Games Store',
            url: 'https://store.epicgames.com/p/$slug',
            endsAt: end.toIso8601String(),
          ),
        );
        break;
      }
    }
    return offers;
  }

  static Future<List<_Offer>> _gamerPower(http.Client client) async {
    final payload = await _get(
      client,
      Uri.https('www.gamerpower.com', '/api/giveaways', {'type': 'game'}),
      empty201: true,
    );
    if (payload is! List) throw const FormatException('GamerPower 数据格式变化');
    return [
      for (final item in _list(payload).take(250))
        if (_text(item['status']).toLowerCase() == 'active' &&
            _text(item['type']).toLowerCase() == 'game' &&
            _text(item['title']).isNotEmpty &&
            _gamerPowerLink(item['gamerpower_url']))
          _Offer(
            title: _text(item['title']),
            source: 'GamerPower',
            platforms: _text(item['platforms']),
            url: _text(item['gamerpower_url']),
            endsAt: DateTime.tryParse(_text(item['end_date'])) == null
                ? ''
                : _text(item['end_date']),
          ),
    ];
  }

  static bool _gamerPowerLink(Object? value) {
    final uri = Uri.tryParse(_text(value));
    return uri != null &&
        uri.scheme == 'https' &&
        const {'gamerpower.com', 'www.gamerpower.com'}.contains(uri.host);
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

Iterable<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>() : const [];

String _text(Object? value) => value is String ? value.trim() : '';

class _Offer {
  const _Offer({
    required this.title,
    required this.source,
    required this.platforms,
    required this.url,
    required this.endsAt,
  });

  factory _Offer.fromJson(Map<String, dynamic> json) => _Offer(
    title: _text(json['title']),
    source: _text(json['source']),
    platforms: _text(json['platforms']),
    url: _text(json['url']),
    endsAt: _text(json['endsAt']),
  );

  final String title;
  final String source;
  final String platforms;
  final String url;
  final String endsAt;

  String get dedupKey {
    final store = platforms.toLowerCase();
    final storefront = [
      'epic',
      'steam',
      'gog',
    ].where(store.contains).firstOrNull;
    if (storefront == null) return url;
    final name = title
        .replaceAll(
          RegExp(r'\((?:Epic Games|Steam|GOG)[^)]*\)', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'\s+giveaway$', caseSensitive: false), '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return name.isEmpty ? url : '$storefront:$name';
  }

  bool matches(String platform, String keyword, DateTime now) {
    if (url.isEmpty || !title.toLowerCase().contains(keyword)) return false;
    final end = DateTime.tryParse(endsAt);
    if (end != null) {
      if (source == 'Epic Games' && !now.isBefore(end)) return false;
      // GamerPower does not include a zone. Allow a day before declaring
      // a cached listing expired on that evidence alone.
      if (source == 'GamerPower' &&
          !now.isBefore(end.add(const Duration(days: 1)))) {
        return false;
      }
    }
    final labels = platforms.toLowerCase();
    return switch (platform) {
      'mobile' => labels.contains('android') || labels.contains('ios'),
      'pc' => RegExp(
        r'\bpc\b|steam|epic|\bgog\b|drm-free|itch',
      ).hasMatch(labels),
      'epic' || 'steam' || 'gog' => labels.contains(platform),
      _ => true,
    };
  }

  String display() {
    final end = DateTime.tryParse(endsAt);
    final deadline = end == null
        ? '未注明'
        : source == 'Epic Games'
        ? end.toUtc().toIso8601String()
        : '$endsAt（来源未注明时区）';
    final obtain = source == 'Epic Games' ? '限时零元领取' : '免费活动，领取条件以来源为准';
    final urlLabel = source == 'Epic Games' ? 'Epic 商店链接' : 'GamerPower 活动链接';
    final plainTitle = title.replaceAll(RegExp(r'\s+'), ' ');
    return '$plainTitle · $platforms\n获取方式：$obtain\n截止：$deadline\n$urlLabel：$url';
  }

  Map<String, String> toJson() => {
    'title': title,
    'source': source,
    'platforms': platforms,
    'url': url,
    'endsAt': endsAt,
  };
}
