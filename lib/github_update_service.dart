import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
    required this.assetName,
    required this.assetUrl,
    required this.notes,
  });

  final String tagName;
  final String releaseUrl;
  final String assetName;
  final String assetUrl;
  final String notes;

  String get version => tagName.replaceFirst(RegExp(r'^[vV]'), '');

  // Keep the Android names available to existing callers.
  String get apkName => assetName;
  String get apkUrl => assetUrl;

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

  static const latestReleasePageUrl =
      'https://github.com/SymbioticUniverse/Cwhale-/releases/latest';

  static final Uri _releasesUri = Uri.https(
    'api.github.com',
    '/repos/SymbioticUniverse/Cwhale-/releases',
    const {'per_page': '30'},
  );
  static const Duration _timeout = Duration(seconds: 20);
  static const Duration automaticCheckInterval = Duration(hours: 24);

  /// Returns the newest stable release with an Android APK.
  static Future<GitHubReleaseInfo> fetchLatestRelease() =>
      _fetchLatestPlatformRelease(
        userAgent: 'Cwhale-Android',
        assetMatches: (name) =>
            name.startsWith('Cwhale-') && name.toLowerCase().endsWith('.apk'),
        missingAssetMessage: 'GitHub Release 尚未附加 Cwhale APK。',
        invalidAssetMessage: 'GitHub APK 下载链接无效。',
        assetExtension: '.apk',
      );

  /// Returns the newest stable release with a Windows installer.
  static Future<GitHubReleaseInfo> fetchLatestWindowsRelease() =>
      _fetchLatestPlatformRelease(
        userAgent: 'Cwhale-Windows',
        assetMatches: (name) =>
            name.startsWith('Cwhale-Setup-') &&
            name.toLowerCase().endsWith('.exe'),
        missingAssetMessage: 'GitHub Release 尚未附加 Windows 安装程序。',
        invalidAssetMessage: 'GitHub Windows 安装程序链接无效。',
        assetExtension: '.exe',
      );

  static Future<bool> shouldCheckAutomatically() async {
    try {
      final file = await _automaticCheckFile();
      if (!await file.exists()) return true;
      final lastCheck = DateTime.tryParse(await file.readAsString());
      if (lastCheck == null) return true;
      final elapsed = DateTime.now().toUtc().difference(lastCheck.toUtc());
      return elapsed.isNegative || elapsed >= automaticCheckInterval;
    } catch (_) {
      return true;
    }
  }

  static Future<void> recordAutomaticCheck() async {
    try {
      final file = await _automaticCheckFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        DateTime.now().toUtc().toIso8601String(),
        flush: true,
      );
    } catch (_) {
      // Update checks must stay optional when local storage is unavailable.
    }
  }

  static Future<File> _automaticCheckFile() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return File(
      '${supportDirectory.path}${Platform.pathSeparator}github-update-check.txt',
    );
  }

  static Future<GitHubReleaseInfo> _fetchLatestPlatformRelease({
    required String userAgent,
    required bool Function(String name) assetMatches,
    required String missingAssetMessage,
    required String invalidAssetMessage,
    required String assetExtension,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            _releasesUri,
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': userAgent,
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const GitHubUpdateException('GitHub 暂时限制了版本查询，请稍后重试。');
      }
      if (response.statusCode != 200) {
        throw GitHubUpdateException(
          'GitHub 版本查询失败（HTTP ${response.statusCode}）。',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const GitHubUpdateException('GitHub 返回的版本信息无法识别。');
      }

      final candidates = <GitHubReleaseInfo>[];
      for (final rawRelease in decoded) {
        if (rawRelease is! Map<String, dynamic> ||
            rawRelease['draft'] == true ||
            rawRelease['prerelease'] == true) {
          continue;
        }

        final tagName = rawRelease['tag_name'];
        final releaseUrl = rawRelease['html_url'];
        final releaseParts = tagName is String
            ? GitHubReleaseInfo._versionParts(tagName)
            : null;
        if (tagName is! String ||
            releaseParts == null ||
            releaseUrl is! String) {
          continue;
        }

        final parsedReleaseUrl = Uri.tryParse(releaseUrl);
        if (parsedReleaseUrl == null ||
            parsedReleaseUrl.scheme != 'https' ||
            parsedReleaseUrl.host != 'github.com' ||
            parsedReleaseUrl.path !=
                '/SymbioticUniverse/Cwhale-/releases/tag/$tagName') {
          continue;
        }

        final rawAssets = rawRelease['assets'];
        if (rawAssets is! List) continue;
        Map<String, dynamic>? selectedAsset;
        for (final rawAsset in rawAssets) {
          if (rawAsset is! Map<String, dynamic>) continue;
          final name = rawAsset['name'];
          if (name is String && assetMatches(name)) {
            selectedAsset = rawAsset;
            break;
          }
        }
        if (selectedAsset == null) continue;

        final assetName = selectedAsset['name'] as String;
        final assetUrl = selectedAsset['browser_download_url'];
        final parsedAssetUrl = assetUrl is String
            ? Uri.tryParse(assetUrl)
            : null;
        final expectedPathPrefix =
            '/SymbioticUniverse/Cwhale-/releases/download/$tagName/';
        if (parsedAssetUrl == null ||
            parsedAssetUrl.scheme != 'https' ||
            parsedAssetUrl.host != 'github.com' ||
            !parsedAssetUrl.path.startsWith(expectedPathPrefix) ||
            !parsedAssetUrl.path.toLowerCase().endsWith(assetExtension)) {
          throw GitHubUpdateException(invalidAssetMessage);
        }

        candidates.add(
          GitHubReleaseInfo(
            tagName: tagName,
            releaseUrl: releaseUrl,
            assetName: assetName,
            assetUrl: assetUrl as String,
            notes: rawRelease['body'] is String
                ? (rawRelease['body'] as String).trim()
                : '',
          ),
        );
      }

      if (candidates.isEmpty) {
        throw GitHubUpdateException(missingAssetMessage);
      }
      candidates.sort((left, right) {
        final leftParts = GitHubReleaseInfo._versionParts(left.version)!;
        final rightParts = GitHubReleaseInfo._versionParts(right.version)!;
        for (var index = 0; index < 3; index++) {
          final comparison = rightParts[index].compareTo(leftParts[index]);
          if (comparison != 0) return comparison;
        }
        return 0;
      });
      return candidates.first;
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
