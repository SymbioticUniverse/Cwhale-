import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AccountAuthException implements Exception {
  const AccountAuthException(this.code, this.message, {this.challengeId});

  final String code;
  final String message;
  final String? challengeId;

  @override
  String toString() => message;
}

class AccountChallenge {
  const AccountChallenge({required this.id, required this.retryAfterSeconds});

  final String id;
  final int retryAfterSeconds;

  factory AccountChallenge.fromJson(Map<String, dynamic> json) =>
      AccountChallenge(
        id: json['challengeId']?.toString() ?? '',
        retryAfterSeconds: (json['retryAfterSeconds'] as num?)?.toInt() ?? 60,
      );
}

class AccountUser {
  const AccountUser({
    required this.id,
    required this.email,
    required this.emailVerified,
    this.displayName,
  });

  final String id;
  final String email;
  final bool emailVerified;
  final String? displayName;

  String get label =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : email;

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'emailVerified': emailVerified,
    if (displayName != null) 'displayName': displayName,
  };

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id: json['id']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    emailVerified: json['emailVerified'] == true,
    displayName: json['displayName']?.toString() ?? json['name']?.toString(),
  );
}

class AccountAuthService extends ChangeNotifier {
  AccountAuthService._();

  static final AccountAuthService instance = AccountAuthService._();

  static const _baseUrl = String.fromEnvironment('CWHale_AUTH_BASE_URL');
  static const _refreshTokenKey = 'cwhale.account.refresh-token.v1';
  static const _cachedUserKey = 'cwhale.account.user.v1';
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(
      keyCipherAlgorithm:
          KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked,
      synchronizable: false,
    ),
  );

  final http.Client _http = http.Client();
  String? _accessToken;
  AccountUser? _user;

  bool get isConfigured {
    final uri = Uri.tryParse(_baseUrl.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  AccountUser? get currentUser => _user;

  Future<AccountChallenge> register({
    required String email,
    required String password,
  }) async {
    final result = await _post('/v1/auth/register', {
      'email': _normalizeEmail(email),
      'password': password,
    });
    return AccountChallenge.fromJson(result);
  }

  Future<AccountUser> verifyEmail({
    required String challengeId,
    required String code,
  }) async => _acceptSession(
    await _post('/v1/auth/email/verify', {
      'challengeId': challengeId,
      'code': code.trim(),
    }),
  );

  Future<AccountUser> login({
    required String email,
    required String password,
  }) async => _acceptSession(
    await _post('/v1/auth/login', {
      'email': _normalizeEmail(email),
      'password': password,
    }),
  );

  Future<void> resendEmailCode(String challengeId) async {
    await _post('/v1/auth/email/resend', {'challengeId': challengeId});
  }

  Future<AccountChallenge> requestPasswordReset(String email) async {
    final result = await _post('/v1/auth/password-reset/request', {
      'email': _normalizeEmail(email),
    });
    return AccountChallenge.fromJson(result);
  }

  Future<void> resendPasswordResetCode(String challengeId) async {
    await _post('/v1/auth/password-reset/resend', {'challengeId': challengeId});
  }

  Future<void> resetPassword({
    required String challengeId,
    required String code,
    required String newPassword,
  }) async {
    await _post('/v1/auth/password-reset/confirm', {
      'challengeId': challengeId,
      'code': code.trim(),
      'newPassword': newPassword,
    });
  }

  Future<AccountUser?> restoreSession() async {
    final cachedUserJson = await _secure.read(key: _cachedUserKey);
    if (cachedUserJson != null && cachedUserJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedUserJson);
        if (decoded is Map<String, dynamic>) {
          _user = AccountUser.fromJson(decoded);
          notifyListeners();
        }
      } on FormatException {
        await _secure.delete(key: _cachedUserKey);
      }
    }
    if (!isConfigured) return _user;
    final refreshToken = await _secure.read(key: _refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) return _user;
    try {
      _user = await _acceptSession(
        await _post('/v1/auth/token/refresh', {'refreshToken': refreshToken}),
      );
      return _user;
    } on AccountAuthException catch (error) {
      if (error.code == 'UNAUTHORIZED' || error.code == 'TOKEN_REVOKED') {
        await _clearSession();
        rethrow;
      }
      if (_user != null) return _user;
      rethrow;
    }
  }

  Future<void> logout() async {
    final refreshToken = await _secure.read(key: _refreshTokenKey);
    if (isConfigured && refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _post('/v1/auth/logout', {'refreshToken': refreshToken});
      } on AccountAuthException {
        // Clear the local session even when the server cannot be reached.
      }
    }
    await _clearSession();
  }

  Future<AccountUser> _acceptSession(Map<String, dynamic> json) async {
    final accessToken = json['accessToken']?.toString() ?? '';
    final refreshToken = json['refreshToken']?.toString() ?? '';
    final userJson = json['user'];
    if (accessToken.isEmpty ||
        refreshToken.isEmpty ||
        userJson is! Map<String, dynamic>) {
      throw const AccountAuthException(
        'INVALID_RESPONSE',
        '账号服务返回的数据不完整，请稍后重试。',
      );
    }
    final user = AccountUser.fromJson(userJson);
    _accessToken = accessToken;
    _user = user;
    await _secure.write(key: _refreshTokenKey, value: refreshToken);
    await _secure.write(key: _cachedUserKey, value: jsonEncode(user.toJson()));
    notifyListeners();
    return user;
  }

  Future<void> _clearSession() async {
    _accessToken = null;
    _user = null;
    await _secure.delete(key: _refreshTokenKey);
    await _secure.delete(key: _cachedUserKey);
    notifyListeners();
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    bool authenticated = false,
  }) async {
    if (!isConfigured) {
      throw const AccountAuthException(
        'NOT_CONFIGURED',
        '账号服务器尚未配置；邮箱登录界面已就绪，聊天和记忆仍保存在本机。',
      );
    }
    final base = Uri.parse(_baseUrl.trim());
    final uri = base.resolve(path);
    try {
      final response = await _http
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json; charset=utf-8',
              if (authenticated && _accessToken != null)
                'Authorization': 'Bearer $_accessToken',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> data = <String, dynamic>{};
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) data = decoded;
      } on FormatException {
        data = <String, dynamic>{};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code =
            data['code']?.toString() ?? _statusCode(response.statusCode);
        final message = data['message']?.toString() ?? _messageFor(code);
        throw AccountAuthException(
          code,
          message,
          challengeId: data['challengeId']?.toString(),
        );
      }
      return data;
    } on TimeoutException {
      throw const AccountAuthException('TIMEOUT', '账号服务暂时没有响应，请检查网络后重试。');
    } on http.ClientException {
      throw const AccountAuthException('NETWORK_ERROR', '无法连接账号服务，请稍后重试。');
    }
  }

  String _normalizeEmail(String value) => value.trim().toLowerCase();

  String _statusCode(int status) => switch (status) {
    401 => 'UNAUTHORIZED',
    409 => 'CONFLICT',
    429 => 'RATE_LIMITED',
    _ => 'SERVER_ERROR',
  };

  String _messageFor(String code) => switch (code) {
    'EMAIL_NOT_VERIFIED' => '邮箱尚未验证，请输入邮件中的验证码。',
    'INVALID_CREDENTIALS' || 'UNAUTHORIZED' => '邮箱或密码不正确。',
    'EMAIL_ALREADY_EXISTS' || 'CONFLICT' => '该邮箱已注册，请直接登录或找回密码。',
    'INVALID_CODE' => '验证码不正确或已过期。',
    'RATE_LIMITED' => '操作过于频繁，请稍后再试。',
    _ => '账号服务暂时不可用，请稍后重试。',
  };
}
