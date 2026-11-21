import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class GitHubUpdateException implements Exception {
  const GitHubUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubReleaseInfo {
  const GitHubReleaseInfo({
    required this.tagName,
    required this.releaseUrl,
    required this.apkName,
    required this.apkUrl,
    required this.notes,
  });

  final String tagName;
  final String releaseUrl;
  final String apkName;
  final String apkUrl;
  final String notes;

  String get version => tagName.replaceFirst(RegExp(r'^[vV]'), '');

  bool isNewerThan(String currentVersion) {
    final releaseParts = _versionParts(version);
    final currentParts = _versionParts(currentVersion);
    if (releaseParts == null || currentParts == null) return false;
    for (var index = 0; index < 3; index++) {
      if (releaseParts[index] != currentParts[index]) {
        return releaseParts[index] > currentParts[index];
      }
    }
    return false;
  }

  static List<int>? _versionParts(String value) {
    final match = RegExp(r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$')
        .firstMatch(value.trim());
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }
}

class GitHubUpdateService {
  GitHubUpdateService._();

  static final Uri _latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/SymbioticUniverse/Cwhale-/releases/latest',
  );
  static const Duration _timeout = Duration(seconds: 20);

  static Future<GitHubReleaseInfo> fetchLatestRelease() async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            _latestReleaseUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Cwhale-Android',
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 404) {
        throw const GitHubUpdateException('GitHub 上还没有正式发布的版本。');
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const GitHubUpdateException('GitHub 暂时限制了版本查询，请稍后重试。');
      }
      if (response.statusCode != 200) {
        throw GitHubUpdateException(
          'GitHub 版本查询失败（HTTP ${response.statusCode}）。',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const GitHubUpdateException('GitHub 返回的版本信息无法识别。');
      }

      final tagName = decoded['tag_name'];
      final releaseUrl = decoded['html_url'];
      if (tagName is! String ||
          !RegExp(r'^[vV]?\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(tagName) ||
          releaseUrl is! String) {
        throw const GitHubUpdateException('GitHub Release 缺少有效的版本号或页面链接。');
      }

      final parsedReleaseUrl = Uri.tryParse(releaseUrl);
      if (parsedReleaseUrl == null ||
          parsedReleaseUrl.scheme != 'https' ||
          parsedReleaseUrl.host != 'github.com' ||
          parsedReleaseUrl.path !=
              '/SymbioticUniverse/Cwhale-/releases/tag/$tagName') {
        throw const GitHubUpdateException('GitHub Release 页面链接无效。');
      }

      final rawAssets = decoded['assets'];
      if (rawAssets is! List) {
        throw const GitHubUpdateException('GitHub Release 没有可下载的 APK。');
      }
      Map<String, dynamic>? apkAsset;
      for (final rawAsset in rawAssets) {
        if (rawAsset is! Map<String, dynamic>) continue;
        final name = rawAsset['name'];
        if (name is String &&
            name.toLowerCase().endsWith('.apk') &&
            name.startsWith('Cwhale-')) {
          apkAsset = rawAsset;
          break;
        }
      }
      if (apkAsset == null) {
        throw const GitHubUpdateException('GitHub 最新 Release 尚未附加 Cwhale APK。');
      }

      final apkName = apkAsset['name'] as String;
      final apkUrl = apkAsset['browser_download_url'];
      final parsedApkUrl = apkUrl is String ? Uri.tryParse(apkUrl) : null;
      final expectedPathPrefix =
          '/SymbioticUniverse/Cwhale-/releases/download/$tagName/';
      if (parsedApkUrl == null ||
          parsedApkUrl.scheme != 'https' ||
          parsedApkUrl.host != 'github.com' ||
          !parsedApkUrl.path.startsWith(expectedPathPrefix) ||
          !parsedApkUrl.path.endsWith('.apk')) {
        throw const GitHubUpdateException('GitHub APK 下载链接无效。');
      }

      final notes = decoded['body'] is String
          ? (decoded['body'] as String).trim()
          : '';
      return GitHubReleaseInfo(
        tagName: tagName,
        releaseUrl: releaseUrl,
        apkName: apkName,
        apkUrl: apkUrl as String,
        notes: notes,
      );
    } on GitHubUpdateException {
      rethrow;
    } on TimeoutException {
      throw const GitHubUpdateException('连接 GitHub 超时，请检查网络后重试。');
    } on SocketException {
      throw const GitHubUpdateException('无法连接 GitHub，请检查网络后重试。');
    } on FormatException {
      throw const GitHubUpdateException('GitHub 返回的版本信息格式错误。');
    } finally {
      client.close();
    }
  }
}
