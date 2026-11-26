import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_auth_service.dart';
import 'chat_models.dart';

class AccountOperationsException implements Exception {
  const AccountOperationsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CwhaleNotification {
  const CwhaleNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    required this.action,
    required this.actionValue,
    required this.publishedAt,
    required this.isRead,
  });

  final String id;
  final String title;
  final String body;
  final String category;
  final String action;
  final String actionValue;
  final int publishedAt;
  final bool isRead;

  factory CwhaleNotification.fromJson(Map<String, dynamic> json) =>
      CwhaleNotification(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        body: json['body']?.toString() ?? '',
        category: json['category']?.toString() ?? 'general',
        action: json['action']?.toString() ?? 'none',
        actionValue:
            json['actionValue']?.toString() ??
            json['action_value']?.toString() ??
            '',
        publishedAt:
            (json['publishedAt'] as num?)?.toInt() ??
            (json['published_at'] as num?)?.toInt() ??
            0,
        isRead: json['isRead'] == true,
      );
}

class AccountOperationsClient {
  AccountOperationsClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  final AccountAuthService _auth = AccountAuthService.instance;

  void close() => _client.close();

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool optionalAuth = false,
  }) async {
    final base = Uri.tryParse(_auth.apiBaseUrl);
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw const AccountOperationsException('账号服务尚未配置。');
    }
    final uri = base.resolve(path);
    try {
      final accountId = _auth.currentUser?.id;
      final token = !optionalAuth || accountId != null
          ? await _auth.requireAccessToken()
          : null;
      if (accountId != null && _auth.currentUser?.id != accountId) {
        throw const AccountOperationsException('账号已切换，请重新加载。');
      }
      final request = http.Request(method, uri)
        ..headers.addAll({
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json; charset=utf-8',
          if (token != null) 'Authorization': 'Bearer $token',
        });
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 30));
      if (token != null && _auth.currentUser?.id != accountId) {
        throw const AccountOperationsException('账号已切换，请重新加载。');
      }
      Map<String, dynamic> data = <String, dynamic>{};
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) data = decoded;
      } on FormatException {
        data = <String, dynamic>{};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AccountOperationsException(
          data['detail']?.toString() ??
              data['message']?.toString() ??
              '账号服务请求失败（${response.statusCode}）。',
        );
      }
      return data;
    } on AccountAuthException catch (error) {
      throw AccountOperationsException(error.message);
    } on http.ClientException {
      throw const AccountOperationsException('无法连接账号服务，请稍后重试。');
    }
  }

  Future<({List<CwhaleNotification> items, int unreadCount})>
  loadNotifications() async {
    final result = await _request(
      'GET',
      '/v1/notifications',
      optionalAuth: true,
    );
    final raw = result['items'] as List<dynamic>? ?? const [];
    return (
      items: raw
          .whereType<Map>()
          .map(
            (item) =>
                CwhaleNotification.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      unreadCount: (result['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> markNotificationRead(String id) async {
    await _request('POST', '/v1/notifications/$id/read', body: const {});
  }

  Future<List<ApiProfile>> loadGiftedProfiles() async {
    final result = await _request('GET', '/v1/me/gray-models');
    final raw = result['items'] as List<dynamic>? ?? const [];
    final baseUrl = _auth.generationApiBaseUrl;
    return raw.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      final entitlementId = json['entitlementId']?.toString() ?? '';
      final displayName = json['displayName']?.toString() ?? '获赠模型';
      bool capability(String key) =>
          json[key] == true || json[key] == 1 || json[key] == '1';
      return ApiProfile(
        id: 'cwhale-gift-$entitlementId',
        name: 'Cwhale',
        providerName: 'Cwhale',
        baseUrl: baseUrl,
        model: displayName,
        apiKey: '',
        contextWindowTokens:
            (json['contextWindowTokens'] as num?)?.toInt() ?? 128000,
        supportsThinkingToggle: capability('supportsThinkingToggle'),
        supportsThinkingLevels: capability('supportsThinkingLevels'),
        supportsImages: capability('supportsImages'),
        supportsFiles: capability('supportsFiles'),
        serverEntitlementId: entitlementId,
        giftedQuotaTokens: (json['quotaTokens'] as num?)?.toInt() ?? 0,
        giftedUsedTokens: (json['usedTokens'] as num?)?.toInt() ?? 0,
        giftedReservedTokens: (json['reservedTokens'] as num?)?.toInt() ?? 0,
        giftedRemainingTokens: (json['remainingTokens'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }
}
