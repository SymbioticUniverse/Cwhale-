part of 'resource_radar.dart';

class _SourceFailure implements Exception {
  const _SourceFailure(this.message);
  final String message;
}

class _Network {
  final _client = http.Client();
  final _nextRequest = <String, DateTime>{};
  void close() => _client.close();

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    bool empty201 = false,
  }) async {
    var next = _https(url);
    for (var redirects = 0; redirects < 4 && next != null; redirects++) {
      final uri = next;
      final now = DateTime.now();
      final host = uri.host;
      final last = _nextRequest[host];
      final due = last != null && last.isAfter(now) ? last : now;
      final gap = host.endsWith('reddit.com')
          ? const Duration(seconds: 4)
          : const Duration(milliseconds: 700);
      _nextRequest[host] = due.add(gap);
      if (due.isAfter(now)) await Future<void>.delayed(due.difference(now));
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll({
        'user-agent': 'Cwhale-ResourceRadar/1.0',
        'accept': 'application/json, application/rss+xml, application/atom+xml, text/html, */*',
        ...headers,
      });
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 7));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        if (headers.containsKey('cookie'))
          throw const _SourceFailure('站点要求重新登录');
        final destination = response.headers['location'];
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        next = destination == null
            ? null
            : _https(uri.resolve(destination).toString());
        continue;
      }
      if (empty201 && response.statusCode == 201) {
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        return '[]';
      }
      if (response.statusCode != 200) {
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        final code = response.statusCode;
        if (code == 401 || code == 403)
          throw _SourceFailure('来源拒绝访问 · HTTP $code');
        if (code == 429) throw const _SourceFailure('来源暂时限流');
        throw _SourceFailure('来源不可用 · HTTP $code');
      }
      final bytes = <int>[];
      final start = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 4),
      )) {
        if (bytes.length + chunk.length > 3 * 1024 * 1024 ||
            DateTime.now().difference(start) > const Duration(seconds: 8)) {
          throw const _SourceFailure('响应过大或传输超时');
        }
        bytes.addAll(chunk);
      }
      final head = latin1.decode(bytes.take(300).toList());
      final type = (response.headers['content-type'] ?? '') + ' ' + head;
      final encoding = RegExp(
        r'''(?:charset|encoding)\s*=\s*["']?([\w-]+)''',
        caseSensitive: false,
      ).firstMatch(type)?[1];
      final decoder = encoding == null
          ? null
          : Charset.getByName(encoding.toLowerCase());
      if (decoder != null) return decoder.decode(bytes);
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return gbk.decode(bytes);
      }
    }
    throw const _SourceFailure('没有可用的 HTTPS 地址');
  }

  Future<Object?> json(
    String url, {
    Map<String, String> headers = const {},
    bool empty201 = false,
  }) async => jsonDecode(await get(url, headers: headers, empty201: empty201));
}

String _url(String host, String path, [Map<String, String>? parameters]) =>
    Uri.https(host, path, parameters).toString();

int _limit(Object? n, [int fallback = 25]) =>
    n is int ? n.clamp(1, 80) : fallback;

Future<List<_Entry>> _collect(
  _Network network,
  RadarSource s,
  String? feed,
  List<String> channels,
  String ngaLogin,
) {
  if (feed != null) return _rss(network, s, {'url': feed});
  final config = s._config;
  return switch (s.kind) {
    'rss' => _multi(_maps(config['feeds']), (spec) => _rss(network, s, spec)),
    'linuxdo' => _rss(network, s, {
      'url': _url(
        'linux.do',
        '/c/' +
            _text(config['rssSlug']) +
            '/' +
            config['categoryId'].toString() +
            '.rss',
      ),
    }),
    'v2ex' => _v2ex(network, s),
    'epic' => _epic(network, s),
    'steam' => _steam(network, s),
    'gog' => _gog(network, s),
    'gamerpower' => _gamerPower(network, s),
    'cheapshark' => _cheapShark(network, s),
    'openrouter' => _openRouter(network, s),
    'github-readme' => _multi(
      _maps(config['repos']),
      (spec) => _github(network, s, spec),
    ),
    'telegram' => _multi(channels, (channel) => _telegram(network, s, channel)),
    'bsky' => _multi(
      _strings(config['actors']),
      (actor) => _bluesky(network, s, actor),
    ),
    'cctv' => _multi(
      _maps(config['channels']),
      (spec) => _cctv(network, s, spec),
    ),
    'bili' => _bilibili(network, s),
    'nga' => _nga(network, s, ngaLogin),
    'weibo' => _multi(
      _strings(config['keywords']),
      (keyword) => _weibo(network, s, keyword),
    ),
    _ => Future.error(const _SourceFailure('需要配置数据来源')),
  };
}

Future<List<_Entry>> _multi<T>(
  Iterable<T> configs,
  Future<List<_Entry>> Function(T) collect,
) async {
  final results = <_Entry>[];
  Object? lastError;
  var worked = false;
  for (final config in configs) {
    try {
      results.addAll(await collect(config));
      worked = true;
    } catch (error) {
      lastError = error;
    }
  }
  if (!worked) throw lastError ?? const _SourceFailure('需要配置数据来源');
  return results;
}

String _xmlText(XmlElement element, List<String> keys) {
  for (final key in keys) {
    final child = element.childElements
        .where((e) => e.name.local == key)
        .firstOrNull;
    if (child != null && child.innerText.trim().isNotEmpty)
      return child.innerText.trim();
  }
  return '';
}

Future<List<_Entry>> _rss(
  _Network net,
  RadarSource s,
  Map<String, dynamic> spec,
) async {
  final url = _text(spec['url']).replaceFirst(RegExp(r'^http:'), 'https:');
  final raw = await net.get(url);
  final document = XmlDocument.parse(raw.replaceFirst('\uFEFF', '').trim());
  if (![
    'rss',
    'feed',
    'rdf',
  ].contains(document.rootElement.name.local.toLowerCase())) {
    throw const _SourceFailure('地址未返回有效 RSS 或 Atom');
  }
  final articles = document.descendants.whereType<XmlElement>().where(
    (e) => ['item', 'entry'].contains(e.name.local),
  );
  final includes = _strings(spec['includeCategories'])
      .map((s) => s.toLowerCase())
      .toSet();
  final keywords = _strings(spec['titleKeywords'])
      .map((s) => s.toLowerCase())
      .toList();
  final result = <_Entry>[];
  for (final item in articles.take(150)) {
    final title = _xmlText(item, ['title']);
    final tags = item.childElements
        .where((e) => e.name.local == 'category')
        .map(
          (e) => (e.getAttribute('term') ?? e.innerText).trim().toLowerCase(),
        );
    if (includes.isNotEmpty && !tags.any(includes.contains)) continue;
    final description = _xmlText(item, [
      'description',
      'summary',
      'encoded',
      'content',
    ]);
    if (keywords.isNotEmpty && !keywords.any(title.toLowerCase().contains))
      continue;
    final freeSale = spec['only100Off'] == true;
    if (freeSale &&
        !RegExp(
          r'100\s*%\s*(?:off|discount)',
          caseSensitive: false,
        ).hasMatch(title + ' ' + description))
      continue;
    final linkNode = item.childElements
        .where(
          (e) =>
              e.name.local == 'link' &&
              (e.getAttribute('rel') == null ||
                  e.getAttribute('rel') == 'alternate'),
        )
        .firstOrNull;
    final link =
        linkNode?.getAttribute('href') ??
        linkNode?.innerText ??
        _xmlText(item, ['guid', 'id']);
    final entry = _entry(
      s,
      title,
      link,
      base: url,
      summary: description,
      published: _xmlText(item, ['pubDate', 'published', 'updated', 'date']),
      category: _text(spec['categoryHint']).isEmpty
          ? null
          : _text(spec['categoryHint']),
      kind: freeSale ? 'freebie' : null,
      verified: freeSale,
    );
    if (entry != null) result.add(entry);
    if (result.length >= _limit(spec['limit'])) break;
  }
  return result;
}

Future<List<_Entry>> _v2ex(_Network net, RadarSource s) async {
  final node = _text(s._config['node']);
  try {
    final data = await net.json(
      _url('www.v2ex.com', '/api/topics/show.json', {'node_name': node}),
    );
    if (data is! List) throw const FormatException('V2EX topics');
    return _maps(data)
        .map(
          (item) => _entry(
            s,
            item['title'],
            item['url'],
            base: 'https://www.v2ex.com/',
            summary: item['content_rendered'] ?? item['content'],
            published: item['created'],
            kind: node == 'free' ? 'freebie' : null,
          ),
        )
        .nonNulls
        .toList();
  } catch (_) {
    return _rss(net, s, {'url': _url('www.v2ex.com', '/feed/$node.xml')});
  }
}

Future<List<_Entry>> _epic(_Network net, RadarSource s) async {
  final locale = Platform.localeName.split('.').first.replaceAll('_', '-');
  final country = locale.split('-').last.toUpperCase();
  final region = RegExp(r'^[A-Z]{2}$').hasMatch(country) && locale.contains('-')
      ? country
      : 'CN';
  final data = _map(
    await net.json(
      _url(
        'store-site-backend-static-ipv4.ak.epicgames.com',
        '/freeGamesPromotions',
        {'locale': locale, 'country': region, 'allowCountries': region},
      ),
    ),
  );
  final entries = _map(
    _map(_map(data['data'])['Catalog'])['searchStore'],
  )['elements'];
  if (entries is! List) throw const FormatException('Epic catalog');
  final now = DateTime.now();
  final result = <_Entry>[];
  for (final item in _maps(entries)) {
    final price = _map(_map(item['price'])['totalPrice']);
    if (price['discountPrice'] != 0 ||
        price['originalPrice'] is! num ||
        (price['originalPrice'] as num) <= 0 ||
        item['offerType'] != 'BASE_GAME')
      continue;
    final slug =
        [
              ..._maps(item['offerMappings']).map((e) => e['pageSlug']),
              item['productSlug'],
              item['urlSlug'],
              ..._maps(_map(item['catalogNs'])['mappings'])
                  .map((e) => e['pageSlug']),
            ]
            .map(_text)
            .map((e) => e.replaceFirst(RegExp(r'/home$'), ''))
            .where((e) => RegExp(r'^[\w-]+$').hasMatch(e))
            .firstOrNull;
    if (slug == null) continue;
    final groups = _maps(_map(item['promotions'])['promotionalOffers']);
    for (final offer in groups.expand(
      (item) => _maps(item['promotionalOffers']),
    )) {
      final start = _date(offer['startDate']);
      final end = _date(offer['endDate']);
      if (start == null ||
          end == null ||
          now.isBefore(start) ||
          !now.isBefore(end) ||
          _map(offer['discountSetting'])['discountPercentage'] != 0)
        continue;
      final row = _entry(
        s,
        item['title'],
        'https://store.epicgames.com/p/$slug',
        end: offer['endDate'],
        platform: 'PC, Epic Games Store',
        kind: 'freebie',
        verified: true,
        obtain: '限时零元领取',
      );
      if (row != null) result.add(row);
      break;
    }
  }
  return result;
}

Future<List<_Entry>> _gamerPower(_Network net, RadarSource s) async {
  final query = Uri.splitQueryString(_text(s._config['query']));
  final type = query['type'] ?? 'game';
  final url = _url('www.gamerpower.com', '/api/giveaways', query);
  final data = await net.json(url, empty201: true);
  if (data is! List) throw const FormatException('GamerPower giveaways');
  return _maps(data)
      .where(
        (e) =>
            _text(e['status']).toLowerCase() == 'active' &&
            _text(e['type']).toLowerCase() == type &&
            [
              'www.gamerpower.com',
              'gamerpower.com',
            ].contains(_https(_text(e['gamerpower_url']))?.host),
      )
      .take(_limit(s._config['limit'], 60))
      .map(
        (e) => _entry(
          s,
          e['title'],
          e['gamerpower_url'],
          platform: _text(e['platforms']),
          published: e['published_date'],
          end: e['end_date'],
          kind: 'freebie',
          verified: true,
          obtain: '领取条件以活动页为准',
        ),
      )
      .nonNulls
      .toList();
}

Future<List<_Entry>> _steam(_Network net, RadarSource s) async {
  final url = _url('store.steampowered.com', '/search/results/', {
    'query': '',
    'start': '0',
    'count': _limit(s._config['count'], 50).toString(),
    'maxprice': 'free',
    'specials': '1',
    'infinite': '1',
    'l': 'schinese',
  });
  final data = _map(await net.json(url));
  if (data['results_html'] is! String)
    throw const FormatException('Steam results');
  return html
      .parseFragment(_text(data['results_html']))
      .querySelectorAll('a.search_result_row')
      .where(
        (row) =>
            (row.querySelector('.discount_pct')?.text.trim() ?? '') == '-100%',
      )
      .map((row) {
        final link = _https(row.attributes['href'] ?? '');
        if (link?.host != 'store.steampowered.com' ||
            !link!.path.startsWith('/app/'))
          return null;
        final path = link.path;
        return _entry(
          s,
          row.querySelector('.title')?.text,
          'https://store.steampowered.com$path',
          platform: 'PC, Steam',
          kind: 'freebie',
          verified: true,
          obtain: '商店当前标注 100% 折扣',
        );
      })
      .nonNulls
      .toList();
}

Future<List<_Entry>> _gog(_Network net, RadarSource s) async {
  final data = _map(
    await net.json(
      _url('catalog.gog.com', '/v1/catalog', {
        'limit': '48',
        'discount': '100',
        'productType': 'in:game',
        'countryCode': 'US',
        'locale': 'en-US',
        'currencyCode': 'USD',
      }),
    ),
  );
  if (data['products'] is! List) throw const FormatException('GOG catalog');
  return _maps(data['products'])
      .where((row) {
        final price = _map(row['price']);
        final finalAmount =
            _map(price['finalMoney'])['amount'] ?? price['final'];
        final baseAmount = _map(price['baseMoney'])['amount'] ?? price['base'];
        return _amount(finalAmount) == 0 && (_amount(baseAmount) ?? 0) > 0;
      })
      .map(
        (row) => _entry(
          s,
          row['title'],
          row['storeLink'],
          platform: 'PC, GOG',
          kind: 'freebie',
          verified: true,
        ),
      )
      .nonNulls
      .toList();
}

double? _amount(Object? raw) => raw is num
    ? raw.toDouble()
    : double.tryParse(_text(raw).replaceAll(RegExp(r'[$€£]'), ''));

Future<List<_Entry>> _cheapShark(_Network net, RadarSource s) async {
  final cfg = s._config;
  final limit = _limit(cfg['pageSize'], 40);
  final data = await net.json(
    _url('www.cheapshark.com', '/api/1.0/deals', {
      'upperPrice': (cfg['upperPrice'] ?? 1).toString(),
      'pageSize': limit.toString(),
      'onSale': '1',
    }),
  );
  if (data is! List) throw const FormatException('CheapShark deals');
  return _maps(data)
      .take(limit)
      .map((row) {
        final id = _text(row['dealID']);
        final amount = _amount(row['salePrice']);
        if (id.isEmpty || amount == null || amount < 0) return null;
        final price = _text(row['salePrice']);
        final platform = _text(row['steamAppID']).isEmpty ? 'PC' : 'PC, Steam';
        return _entry(
          s,
          row['title'],
          _url('www.cheapshark.com', '/redirect', {'dealID': id}),
          platform: platform,
          kind: amount == 0 ? 'freebie' : 'deal',
          summary: '活动价格 USD $price',
          verified: amount == 0,
        );
      })
      .nonNulls
      .toList();
}

Future<List<_Entry>> _openRouter(_Network net, RadarSource s) async {
  final data = _map(await net.json('https://openrouter.ai/api/v1/models'));
  if (data['data'] is! List) throw const FormatException('OpenRouter models');
  return _maps(data['data'])
      .where((row) {
        final price = _map(row['pricing']);
        return _text(row['id']).contains('/') &&
            _amount(price['prompt']) == 0 &&
            _amount(price['completion']) == 0;
      })
      .map((row) {
        final id = _text(row['id']);
        final name = _text(row['name']);
        return _entry(
          s,
          name.isEmpty ? id : name,
          'https://openrouter.ai/$id',
          summary: row['description'],
          kind: 'freebie',
          verified: true,
          obtain: '免费模型，调用配额以 OpenRouter 为准',
        );
      })
      .nonNulls
      .toList();
}

Future<List<_Entry>> _github(
  _Network net,
  RadarSource s,
  Map<String, dynamic> spec,
) async {
  final repo = _text(spec['repo']);
  final path = _text(spec['path']);
  final endpoint = path.isEmpty
      ? '/repos/$repo/readme'
      : '/repos/$repo/contents/$path';
  final markdown = await net.get(
    _url('api.github.com', endpoint),
    headers: {'accept': 'application/vnd.github.raw+json'},
  );
  final links = RegExp(r'\[([^\]\n]{2,180})\]\((https://[^\s)]+)\)')
      .allMatches(markdown);
  final result = <_Entry>[];
  for (final line in links) {
    final title = line[1];
    final link = line[2]!;
    if (RegExp(
      r'(shields\.io|badge|/license\b|/issues\b)',
      caseSensitive: false,
    ).hasMatch(link))
      continue;
    final entry = _entry(
      s,
      title,
      link,
      kind: s.id == 'github-selfhosted' ? 'opensource' : 'info',
      origin: repo,
    );
    if (entry != null) result.add(entry);
    if (result.length >= _limit(spec['limit'])) break;
  }
  if (result.isEmpty && !markdown.contains('#'))
    throw const FormatException('GitHub README');
  return result;
}

Future<List<_Entry>> _telegram(
  _Network net,
  RadarSource s,
  String channel,
) async {
  final url = _url('t.me', '/s/$channel');
  final document = html.parse(await net.get(url));
  if (document.querySelector('.tgme_channel_info') == null &&
      document.querySelector('.tgme_widget_message') == null)
    throw const _SourceFailure('公开频道不可读');
  return document
      .querySelectorAll('.tgme_widget_message')
      .reversed
      .take(25)
      .map((e) {
        final body = e.querySelector('.tgme_widget_message_text')?.text ?? '';
        final title = body
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .firstOrNull;
        final link = e
            .querySelector('a.tgme_widget_message_date')
            ?.attributes['href'];
        return _entry(
          s,
          title,
          link,
          summary: body,
          base: url,
          published: e.querySelector('time')?.attributes['datetime'],
          origin: '@$channel',
        );
      })
      .nonNulls
      .toList();
}

Future<List<_Entry>> _bluesky(_Network net, RadarSource s, String actor) async {
  final data = _map(
    await net.json(
      _url('public.api.bsky.app', '/xrpc/app.bsky.feed.getAuthorFeed', {
        'actor': actor,
        'limit': _limit(s._config['limitPerActor'], 10).toString(),
      }),
    ),
  );
  if (data['feed'] is! List) throw const FormatException('Bluesky feed');
  return _maps(data['feed'])
      .map((e) {
        final post = _map(e['post']);
        final record = _map(post['record']);
        final handle = _text(_map(post['author'])['handle']);
        final uri = _text(post['uri']);
        if (!uri.startsWith('at://') || handle.isEmpty) return null;
        final key = uri.split('/').last;
        final content = _text(record['text']);
        return _entry(
          s,
          content.split('\n').first,
          'https://bsky.app/profile/$handle/post/$key',
          summary: content,
          published: record['createdAt'],
          origin: handle,
        );
      })
      .nonNulls
      .toList();
}

Future<List<_Entry>> _cctv(
  _Network net,
  RadarSource s,
  Map<String, dynamic> spec,
) async {
  final channel = _text(spec['channel']);
  final cb = _text(spec['cb'] ?? channel);
  final raw = (await net.get(
    _url(
      'news.cctv.com',
      '/2019/07/gaiban/cmsdatainterface/page/' + channel + '_1.jsonp',
      {'cb': cb},
    ),
  )).trim();
  final prefix = '$cb(';
  final json = raw.startsWith(prefix)
      ? raw.substring(prefix.length).replaceFirst(RegExp(r'\)\s*;?\s*$'), '')
      : raw;
  final data = _map(_map(jsonDecode(json))['data'])['list'];
  if (data is! List) throw const FormatException('CCTV channel');
  return _maps(data)
      .take(_limit(spec['limit']))
      .map(
        (e) => _entry(
          s,
          e['title'],
          e['url'],
          summary: e['brief'],
          published: e['focus_date'],
          category: _text(spec['categoryHint']),
          kind: s.id == 'cctv-tech' ? 'info' : 'news',
        ),
      )
      .nonNulls
      .toList();
}

Future<List<_Entry>> _nga(_Network net, RadarSource s, String cookie) async {
  final fid = s._config['fid'].toString();
  final board = _url('bbs.nga.cn', '/thread.php', {'fid': fid, 'page': '1'});
  final page = html.parse(
    await net.get(
      board,
      headers: {'cookie': cookie, 'referer': 'https://bbs.nga.cn/'},
    ),
  );
  if (page.body?.text.contains('访客不能直接访问') ?? false)
    throw const _SourceFailure('NGA 登录已失效');
  final links = page.querySelectorAll('a.topic, a.topicrow');
  if (links.isEmpty && page.querySelector('#topicrows') == null)
    throw const _SourceFailure('NGA 版面不可读，请检查登录');
  return links
      .take(65)
      .map(
        (e) => _entry(
          s,
          e.text,
          e.attributes['href'],
          base: board,
          kind: s.id == 'nga-deals' ? null : 'deal',
        ),
      )
      .nonNulls
      .toList();
}

Future<List<_Entry>> _bilibili(_Network net, RadarSource s) async {
  const host = 'api.bilibili.com';
  const headers = {'referer': 'https://www.bilibili.com/'};
  const order = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];
  final nav = _map(
    await net.json(_url(host, '/x/web-interface/nav'), headers: headers),
  );
  final img = _map(_map(nav['data'])['wbi_img']);
  String name(Object? value) => _text(value).split('/').last.split('.').first;
  final raw = name(img['img_url']) + name(img['sub_url']);
  if (raw.length <= 58) throw const _SourceFailure('B站搜索暂不可用');
  final key = order.map((index) => raw[index]).join();
  return _multi(_strings(s._config['keywords']), (keyword) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final query =
        'keyword=' +
        Uri.encodeComponent(keyword) +
        '&order=pubdate&page=1&search_type=video&wts=$now';
    final digest = md5.convert(utf8.encode(query + key));
    final payload = _map(
      await net.json(
        'https://$host/x/web-interface/wbi/search/type?$query&w_rid=$digest',
        headers: headers,
      ),
    );
    if (payload['code'] != 0) throw const _SourceFailure('B站拒绝本次搜索');
    return _maps(_map(payload['data'])['result'])
        .take(_limit(s._config['limitPerKeyword']))
        .map((e) {
          final bvid = _text(e['bvid']);
          if (!RegExp(r'^BV[a-zA-Z0-9]+$').hasMatch(bvid)) return null;
          return _entry(
            s,
            e['title'],
            'https://www.bilibili.com/video/$bvid',
            summary: e['description'],
            published: e['pubdate'],
          );
        })
        .nonNulls
        .toList();
  });
}

Future<List<_Entry>> _weibo(_Network net, RadarSource s, String keyword) async {
  final data = _map(
    await net.json(
      _url('weibo.com', '/ajax/statuses/search', {'q': keyword, 'page': '1'}),
      headers: {
        'referer': 'https://weibo.com/',
        'x-requested-with': 'XMLHttpRequest',
      },
    ),
  );
  if (data['statuses'] is! List) throw const _SourceFailure('微博搜索需要站点登录或公开订阅');
  return _maps(data['statuses'])
      .take(_limit(s._config['limitPerKeyword']))
      .map((e) {
        final id = _text(e['mblogid'] ?? e['idstr']);
        final body = e['text_raw'] ?? e['text'];
        if (id.isEmpty) return null;
        return _entry(
          s,
          _plain(body, 90),
          'https://m.weibo.cn/detail/$id',
          summary: body,
          published: e['created_at'],
        );
      })
      .nonNulls
      .toList();
}
