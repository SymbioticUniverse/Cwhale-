import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_models.dart';

/// Public free-catalog validation for the one built-in automatic router.
/// Custom API profiles never use this service.
class KiloGateway {
  KiloGateway._();

  static const requestsPerHourPerIp = 200;

  static final http.Client _client = http.Client();
  static DateTime? _catalogCheckedAt;
  static bool? _autoRouterIsFree;
  static int _contextWindowTokens = 256000;
  static const _cacheLifetime = Duration(minutes: 2);
  static const _publicModelWhitelist = <String>{kiloGatewayModelId};

  static int get contextWindowTokens => _contextWindowTokens;

  static bool isWhitelistedFreeEntry(Map<String, dynamic>? model) =>
      model != null &&
      model['id'] == kiloGatewayModelId &&
      model['isFree'] == true &&
      _publicModelWhitelist.contains(kiloGatewayModelId);

  static bool hasDataConsent(Set<String> scopes) =>
      scopes.contains(kiloModelDataConsentScope);

  static Set<String> grantDataConsent(Set<String> scopes) => {
    ...scopes,
    kiloModelDataConsentScope,
  };

  static Set<String> revokeDataConsent(Set<String> scopes) =>
      scopes.where((scope) => scope != kiloModelDataConsentScope).toSet();

  static Future<bool> refreshCatalog({bool force = false}) async {
    final checkedAt = _catalogCheckedAt;
    if (!force &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < _cacheLifetime &&
        _autoRouterIsFree != null) {
      return _autoRouterIsFree!;
    }

    final uri = Uri.parse('$kiloApiBaseUrl/models');
    late final http.Response response;
    try {
      response = await _client.get(uri).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const KiloGatewayException('无法连接 Cwhale 免费模型服务，请检查网络后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KiloGatewayException(
        '无法读取免费模型目录（${response.statusCode}），请检查网络后重试。',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const KiloGatewayException('免费模型目录格式无法识别。');
    }
    final rawModels = decoded is Map<String, dynamic>
        ? decoded['data'] ?? decoded['models']
        : null;
    if (rawModels is! List) {
      throw const KiloGatewayException('免费模型目录缺少模型列表。');
    }

    Map<String, dynamic>? router;
    for (final item in rawModels) {
      if (item is Map<String, dynamic> && item['id'] == kiloGatewayModelId) {
        router = item;
        break;
      }
    }
    final isFree = isWhitelistedFreeEntry(router);
    final context = router?['context_length'];
    if (context is num && context > 0) {
      _contextWindowTokens = context.toInt();
    }
    _catalogCheckedAt = DateTime.now();
    _autoRouterIsFree = isFree;
    return isFree;
  }

  static Future<void> requireFreeAutoRouter({bool force = false}) async {
    final isFree = await refreshCatalog(force: force);
    if (!isFree) {
      throw const KiloModelUnavailableException(
        'Cwhale 免费模型当前不可用，请重新选择其他 API 配置。',
      );
    }
  }
}

class KiloGatewayException implements Exception {
  const KiloGatewayException(this.message);
  final String message;

  @override
  String toString() => message;
}

class KiloModelUnavailableException extends KiloGatewayException {
  const KiloModelUnavailableException(super.message);
}
