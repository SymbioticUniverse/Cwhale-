import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_theme.dart';
import 'brand_mark.dart';
import 'chat_models.dart';

Color get _importInk => CwhaleTheme.ink;
Color get _importMuted => CwhaleTheme.muted;
Color get _importAccent => CwhaleTheme.accent;
Color get _importSurface => CwhaleTheme.surface;
Color get _importRaised => CwhaleTheme.raisedSurface;
Color get _importLine => CwhaleTheme.line;

class DeepSeekImportResult {
  const DeepSeekImportResult({
    required this.threads,
    required this.skippedCount,
  });

  final List<ChatThread> threads;
  final int skippedCount;
}

class DeepSeekChatImportPage extends StatefulWidget {
  const DeepSeekChatImportPage({super.key, required this.apiProfileId});

  final String apiProfileId;

  @override
  State<DeepSeekChatImportPage> createState() => _DeepSeekChatImportPageState();
}

class _DeepSeekChatImportPageState extends State<DeepSeekChatImportPage> {
  static const _maxArchiveBytes = 128 * 1024 * 1024;
  final _urlController = TextEditingController();
  final _folderController = TextEditingController();
  Uint8List? _zipBytes;
  String? _zipName;
  String _status = '';
  String? _error;
  bool _busy = false;
  bool _importIntoFolder = false;
  DeepSeekImportResult? _result;

  @override
  void dispose() {
    _urlController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  Future<void> _pickZip() async {
    if (_busy) return;
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        dialogTitle: '选择 DeepSeek 导出 ZIP',
      );
      if (file == null || !mounted) return;
      final size = await file.length();
      if (size != null && size > _maxArchiveBytes) {
        throw const FormatException('ZIP 文件超过 128 MB，请先缩小导出文件。');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxArchiveBytes) {
        throw const FormatException('ZIP 文件超过 128 MB，请先缩小导出文件。');
      }
      setState(() {
        _zipBytes = Uint8List.fromList(bytes);
        _zipName = file.name;
        _error = null;
        _result = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _cleanError(error));
    }
  }

  Future<void> _importSelectedZip() async {
    final bytes = _zipBytes;
    if (bytes == null || _busy) return;
    await _parseAndReturn(bytes);
  }

  Future<void> _downloadAndImport() async {
    if (_busy) return;
    final value = _urlController.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '请先粘贴 DeepSeek 导出 ZIP 的 HTTPS 下载链接。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在从公开 HTTPS 地址下载';
    });
    try {
      final bytes = await _downloadPublicHttpsZip(value);
      if (!mounted) return;
      setState(() => _zipName = '下载的 DeepSeek 导出文件');
      await _parseAndReturn(bytes, alreadyBusy: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _error = _cleanError(error);
      });
    }
  }

  Future<Uint8List> _downloadPublicHttpsZip(String source) async {
    final parsed = Uri.tryParse(source);
    if (parsed == null || !parsed.hasAuthority) {
      throw const FormatException('下载链接格式不正确。');
    }
    var current = parsed;
    final client = http.Client();
    try {
      for (var redirectCount = 0; redirectCount <= 4; redirectCount++) {
        await _validatePublicHttps(current);
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['accept'] =
              'application/zip, application/octet-stream, */*';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers['location'];
          await response.stream.drain<void>();
          if (location == null || redirectCount == 4) {
            throw const FormatException('下载链接重定向次数过多或目标无效。');
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw FormatException('下载失败，网站返回 HTTP ${response.statusCode}。');
        }
        if ((response.contentLength ?? 0) > _maxArchiveBytes) {
          await response.stream.drain<void>();
          throw const FormatException('下载文件超过 128 MB，请先缩小导出文件。');
        }
        final builder = BytesBuilder(copy: false);
        var received = 0;
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > _maxArchiveBytes) {
            throw const FormatException('下载文件超过 128 MB，请先缩小导出文件。');
          }
          builder.add(chunk);
          if (received % (1024 * 1024) < chunk.length && mounted) {
            setState(
              () => _status =
                  '正在下载 · ${(received / 1048576).toStringAsFixed(1)} MB',
            );
          }
        }
        return builder.takeBytes();
      }
    } finally {
      client.close();
    }
    throw const FormatException('下载没有完成。');
  }

  Future<void> _validatePublicHttps(Uri uri) async {
    final host = uri.host.toLowerCase();
    if (uri.scheme != 'https' ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        !host.contains('.') ||
        InternetAddress.tryParse(host) != null) {
      throw const FormatException('只允许公开 HTTPS 网站的 ZIP 下载链接。');
    }
    final addresses = await InternetAddress.lookup(host)
        .timeout(const Duration(seconds: 8));
    if (addresses.isEmpty || addresses.any(_isNonPublicAddress)) {
      throw const FormatException('下载地址解析到本机或内网地址，已阻止访问。');
    }
  }

  bool _isNonPublicAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) {
      return true;
    }
    final value = address.address.toLowerCase();
    if (address.type == InternetAddressType.IPv4) {
      final octets = value.split('.').map(int.tryParse).toList();
      if (octets.length != 4 || octets.any((part) => part == null)) return true;
      final a = octets[0]!;
      final b = octets[1]!;
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 100 && b >= 64 && b <= 127) ||
          a >= 224;
    }
    return value == '::' ||
        value.startsWith('fc') ||
        value.startsWith('fd') ||
        value.startsWith('fe8') ||
        value.startsWith('fe9') ||
        value.startsWith('fea') ||
        value.startsWith('feb') ||
        value.startsWith('fec') ||
        value.startsWith('fed') ||
        value.startsWith('fee') ||
        value.startsWith('fef') ||
        value.startsWith('::ffff:');
  }

  Future<void> _parseAndReturn(
    Uint8List bytes, {
    bool alreadyBusy = false,
  }) async {
    if (!alreadyBusy) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    setState(() => _status = '正在本机读取 ZIP 并解析对话');
    try {
      final parsed = await compute(_parseDeepSeekExport, bytes);
      final rawThreads = (parsed['threads'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final folderName = _importIntoFolder
          ? (_folderController.text.trim().isEmpty
                ? 'DeepSeek 导入'
                : _folderController.text.trim())
          : '';
      final imported = <ChatThread>[];
      for (final raw in rawThreads) {
        final rawMessages = (raw['messages'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>();
        final messages = rawMessages
            .map(
              (item) => ChatMessage(
                role: item['role'] as String? ?? 'user',
                content: item['content'] as String? ?? '',
                reasoning: item['reasoning'] as String? ?? '',
                thinkingStatus: (item['reasoning'] as String? ?? '').isEmpty
                    ? ''
                    : '已深度思考',
                imageDataBase64: item['imageDataBase64'] as String?,
                imageMimeType: item['imageMimeType'] as String?,
                createdAt:
                    DateTime.tryParse(item['createdAt'] as String? ?? '')
                        ?.toLocal() ??
                    DateTime.now(),
              ),
            )
            .toList();
        if (messages.isEmpty) continue;
        final createdAt =
            DateTime.tryParse(raw['createdAt'] as String? ?? '')?.toLocal() ??
            messages.first.createdAt;
        final updatedAt =
            DateTime.tryParse(raw['updatedAt'] as String? ?? '')?.toLocal() ??
            messages.last.createdAt;
        final originalTitle = (raw['title'] as String? ?? '').trim();
        final title = originalTitle.isEmpty
            ? _fallbackTitle(messages)
            : originalTitle;
        final thread = ChatThread(
          id: newLocalId(),
          title: title,
          titleIsManual: true,
          apiProfileId: widget.apiProfileId,
          folderName: folderName,
          createdAt: createdAt,
          updatedAt: updatedAt,
          messages: messages,
          messageCount: messages.length,
          // Imported chronology is historical source data. Idle rollover
          // starts after the first message the user sends inside Cwhale.
          lastUserMessageAt: null,
        );
        imported.add(thread);
      }
      if (imported.isEmpty) {
        throw const FormatException('ZIP 中没有可导入的有效对话。');
      }
      if (!mounted) return;
      setState(() {
        _result = DeepSeekImportResult(
          threads: imported,
          skippedCount: (parsed['skippedCount'] as num?)?.toInt() ?? 0,
        );
        _status = '已完成导入预览';
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _error = _cleanError(error);
      });
    }
  }

  String _fallbackTitle(List<ChatMessage> messages) {
    final firstUser = messages.where((message) => message.role == 'user');
    final content = firstUser.isEmpty ? '' : firstUser.first.content.trim();
    if (content.isEmpty) return '导入的对话';
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length > 30
        ? '${normalized.substring(0, 30)}…'
        : normalized;
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst('FormatException: ', '')
      .replaceFirst('Exception: ', '');

  void _finishImport() {
    final result = _result;
    if (result != null) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      backgroundColor: CwhaleTheme.background,
      appBar: AppBar(
        title: const Text('导入 DeepSeek 对话'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: _busy ? null : () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                children: [
                  Row(
                    children: [
                      const CwhaleBrandMark(size: 44, cornerRadius: 15),
                      const SizedBox(width: 12),
                      Text(
                        'DeepSeek  →  Cwhale',
                        style: TextStyle(
                          color: _importInk,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 17),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        color: const Color(0xff32aa8b),
                        size: 21,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '导入只写入本机，不会影响已有对话。',
                          style: TextStyle(color: _importMuted, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _importAccent.withValues(
                        alpha: CwhaleTheme.isDark ? 0.12 : 0.08,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: _importAccent.withValues(alpha: 0.75),
                        width: 1.2,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: _importSurface,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Icon(
                                Icons.folder_zip_outlined,
                                color: _importAccent,
                                size: 29,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'DeepSeek 导出 ZIP',
                                    style: TextStyle(
                                      color: _importInk,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '选择官网导出的原始 ZIP，无需解压。',
                                    style: TextStyle(
                                      color: _importMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (_zipName != null) ...[
                          const SizedBox(height: 13),
                          Row(
                            children: [
                              Icon(
                                Icons.check_circle_outline_rounded,
                                size: 18,
                                color: const Color(0xff32aa8b),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _zipName!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: _importInk),
                                ),
                              ),
                              IconButton(
                                tooltip: '移除文件',
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        _zipBytes = null;
                                        _zipName = null;
                                      }),
                                icon: const Icon(Icons.close_rounded, size: 19),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 13),
                        FilledButton.icon(
                          onPressed: _busy ? null : _pickZip,
                          icon: const Icon(Icons.upload_file_rounded),
                          label: Text(
                            _zipName == null ? '选择 ZIP 文件' : '更换 ZIP 文件',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: _importAccent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(child: Divider(color: _importLine)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Text('或', style: TextStyle(color: _importMuted)),
                      ),
                      Expanded(child: Divider(color: _importLine)),
                    ],
                  ),
                  const SizedBox(height: 17),
                  Text(
                    '下载链接',
                    style: TextStyle(
                      color: _importInk,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.link_rounded),
                      hintText: 'https://…',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy || _urlController.text.trim().isEmpty
                        ? null
                        : _downloadAndImport,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('下载并导入'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      foregroundColor: _importAccent,
                      side: BorderSide(color: _importLine),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _importIntoFolder,
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _importIntoFolder = value ?? false,
                          ),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('导入到文件夹'),
                    secondary: Icon(Icons.folder_outlined, color: _importMuted),
                  ),
                  if (_importIntoFolder) ...[
                    TextField(
                      controller: _folderController,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '文件夹名称',
                        hintText: 'DeepSeek 导入',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  _infoSection(
                    icon: Icons.info_outline_rounded,
                    title: '导入说明',
                    lines: const [
                      'ZIP、解压后的对话正文和附件记录只在本机处理。',
                      '单个 ZIP 最大 128 MB；导入时请保持 Cwhale 在前台。',
                      '无法识别的对话会跳过，已有聊天不会被覆盖。',
                    ],
                  ),
                  if (_status.isNotEmpty || _busy) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _importRaised,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          if (_busy) ...[
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                          ] else ...[
                            Icon(
                              Icons.check_circle_outline_rounded,
                              color: const Color(0xff32aa8b),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              _status,
                              style: TextStyle(color: _importInk),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: _importAccent.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '已识别 ${result.threads.length} 个对话${result.skippedCount == 0 ? '' : '，跳过 ${result.skippedCount} 个无效或超出范围的对话'}。点“完成并返回”后会加入对话列表。',
                        style: TextStyle(color: _importInk, height: 1.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              decoration: BoxDecoration(
                color: CwhaleTheme.background,
                border: Border(top: BorderSide(color: _importLine)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.maybePop(context),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        foregroundColor: _importInk,
                        side: BorderSide(color: _importLine),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : result != null
                          ? _finishImport
                          : _zipBytes == null
                          ? null
                          : _importSelectedZip,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: _importAccent,
                        foregroundColor: Colors.white,
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(result == null ? '开始导入' : '完成并返回'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoSection({
    required IconData icon,
    required String title,
    required List<String> lines,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: _importMuted, size: 20),
          const SizedBox(width: 9),
          Text(
            title,
            style: TextStyle(
              color: _importInk,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            line,
            style: TextStyle(color: _importMuted, height: 1.45),
          ),
        ),
    ],
  );
}

Map<String, Object?> _parseDeepSeekExport(Uint8List bytes) {
  const maxConversationBytes = 32 * 1024 * 1024;
  const maxTotalConversationBytes = 128 * 1024 * 1024;
  const maxConversations = 1000;
  const maxSingleImageBytes = 4 * 1024 * 1024;
  const maxTotalImageBytes = 16 * 1024 * 1024;
  if (bytes.length > 128 * 1024 * 1024) {
    throw const FormatException('ZIP 文件超过 128 MB。');
  }
  final archive = ZipDecoder().decodeBytes(bytes, throwOnError: true);
  if (archive.files.length > 20000) {
    throw const FormatException('ZIP 内文件数量过多，已停止导入。');
  }
  final byName = <String, ArchiveFile>{};
  for (final file in archive.files) {
    if (file.isDirectory) continue;
    if (byName.containsKey(file.name)) {
      throw const FormatException('ZIP 中存在重复文件名，无法安全导入。');
    }
    byName[file.name] = file;
  }
  Map<String, dynamic> readObject(
    String name, {
    int maxBytes = 2 * 1024 * 1024,
  }) {
    final file = byName[name];
    if (file == null || file.size > maxBytes) {
      throw FormatException('缺少或超出大小限制：$name');
    }
    final content = file.readBytes();
    if (content == null || content.length > maxBytes) {
      throw FormatException('无法读取：$name');
    }
    final decoded = jsonDecode(utf8.decode(content, allowMalformed: false));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$name 格式不正确。');
    }
    return decoded;
  }

  final manifest = readObject('manifest.json');
  final version = (manifest['export_format_version'] as num?)?.toInt();
  if (version != 3) {
    throw FormatException('暂不支持此 DeepSeek 导出版本（${version ?? '未知'}）。');
  }
  final indexFile = byName['chat_session_index.json'];
  if (indexFile == null || indexFile.size > 16 * 1024 * 1024) {
    throw const FormatException('ZIP 内缺少对话索引，或索引文件过大。');
  }
  final indexBytes = indexFile.readBytes();
  if (indexBytes == null) throw const FormatException('无法读取对话索引。');
  final decodedIndex = jsonDecode(
    utf8.decode(indexBytes, allowMalformed: false),
  );
  if (decodedIndex is! List) {
    throw const FormatException('对话索引格式不正确。');
  }
  final indexRows = decodedIndex.whereType<Map<String, dynamic>>().toList()
    ..sort((left, right) {
      final updated = _exportTime(right['updated_at'])
          .compareTo(_exportTime(left['updated_at']));
      if (updated != 0) return updated;
      final inserted = _exportTime(right['inserted_at'])
          .compareTo(_exportTime(left['inserted_at']));
      return inserted != 0
          ? inserted
          : '${left['id']}'.compareTo('${right['id']}');
    });
  if (indexRows.isEmpty) throw const FormatException('导出文件中没有对话。');
  final candidates = indexRows.take(maxConversations).toList();
  var skipped = indexRows.length - candidates.length;
  var totalConversationBytes = 0;
  var totalImageBytes = 0;
  final imported = <Map<String, Object?>>[];
  for (final row in candidates) {
    final id = row['id'];
    if (id is! String || id.isEmpty || id.contains('/') || id.contains('\\')) {
      skipped++;
      continue;
    }
    final name = 'chat_sessions/$id.json';
    final entry = byName[name];
    if (entry == null ||
        entry.size > maxConversationBytes ||
        totalConversationBytes + entry.size > maxTotalConversationBytes) {
      skipped++;
      continue;
    }
    totalConversationBytes += entry.size;
    try {
      final source = entry.readBytes();
      if (source == null || source.length > maxConversationBytes) {
        skipped++;
        entry.clear();
        continue;
      }
      final conversation = jsonDecode(
        utf8.decode(source, allowMalformed: false),
      );
      if (conversation is! Map<String, dynamic>) {
        skipped++;
        entry.clear();
        continue;
      }
      final result = _parseConversation(
        conversation,
        byName,
        maxSingleImageBytes,
        maxTotalImageBytes,
        totalImageBytes,
      );
      totalImageBytes += (result['imageBytes'] as int? ?? 0);
      final thread = result['thread'] as Map<String, Object?>?;
      if (thread == null ||
          (thread['messages'] as List<dynamic>? ?? const []).isEmpty) {
        skipped++;
      } else {
        imported.add(thread);
      }
    } on FormatException {
      skipped++;
    } catch (_) {
      skipped++;
    } finally {
      entry.clear();
    }
  }
  if (imported.isEmpty) {
    throw const FormatException('没有找到可导入的对话。请确认 ZIP 是 DeepSeek 官网导出的原始 ZIP。');
  }
  return <String, Object?>{'threads': imported, 'skippedCount': skipped};
}

Map<String, Object?> _parseConversation(
  Map<String, dynamic> conversation,
  Map<String, ArchiveFile> byName,
  int maxSingleImageBytes,
  int maxTotalImageBytes,
  int currentImageBytes,
) {
  final rawMessages = (conversation['messages'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (rawMessages.isEmpty) return <String, Object?>{'thread': null};
  final nodes = <int, Map<String, dynamic>>{};
  for (final message in rawMessages) {
    final id = (message['id'] as num?)?.toInt();
    if (id == null || nodes.containsKey(id)) {
      return <String, Object?>{'thread': null};
    }
    nodes[id] = message;
  }
  final requestedId = (conversation['current_message_id'] as num?)?.toInt();
  final selected =
      nodes[requestedId] ??
      nodes.values.reduce(
        (left, right) =>
            ((left['id'] as num).toInt() > (right['id'] as num).toInt())
            ? left
            : right,
      );
  final chain = <Map<String, dynamic>>[];
  var cursor = selected;
  while (true) {
    if (chain.length >= nodes.length) return <String, Object?>{'thread': null};
    chain.add(cursor);
    final parent = cursor['parent_id'];
    if (parent == null) break;
    final parentId = (parent as num?)?.toInt();
    if (parentId == null || nodes[parentId] == null) {
      return <String, Object?>{'thread': null};
    }
    cursor = nodes[parentId]!;
  }
  final branch = chain.reversed.toList();
  final importedMessages = <Map<String, Object?>>[];
  var usedImages = 0;
  for (var index = 0; index < branch.length; index++) {
    final node = branch[index];
    final role = node['role'] == 'USER' ? 'user' : 'assistant';
    if (role == 'assistant') continue;
    final next = index + 1 < branch.length ? branch[index + 1] : null;
    final assistantNode = next != null && next['role'] == 'ASSISTANT'
        ? next
        : null;
    if (assistantNode != null && assistantNode['status'] == 'CONTENT_FILTER') {
      index++;
      continue;
    }
    final userData = _fragmentsToMessage(
      node['fragments'],
      role: 'user',
      byName: byName,
      maxSingleImageBytes: maxSingleImageBytes,
      maxTotalImageBytes: maxTotalImageBytes,
      currentImageBytes: currentImageBytes + usedImages,
    );
    usedImages += userData.imageBytes;
    if (userData.content.trim().isEmpty && userData.imageDataBase64 == null) {
      continue;
    }
    importedMessages.add(<String, Object?>{
      'role': 'user',
      'content': userData.content,
      if (userData.imageDataBase64 != null)
        'imageDataBase64': userData.imageDataBase64,
      if (userData.imageMimeType != null)
        'imageMimeType': userData.imageMimeType,
      'createdAt': _messageDate(node['inserted_at']).toIso8601String(),
    });
    if (assistantNode != null) {
      index++;
      final assistantData = _fragmentsToMessage(
        assistantNode['fragments'],
        role: 'assistant',
        byName: byName,
        maxSingleImageBytes: maxSingleImageBytes,
        maxTotalImageBytes: maxTotalImageBytes,
        currentImageBytes: currentImageBytes + usedImages,
      );
      usedImages += assistantData.imageBytes;
      if (assistantData.content.trim().isNotEmpty ||
          assistantData.reasoning.trim().isNotEmpty) {
        importedMessages.add(<String, Object?>{
          'role': 'assistant',
          'content': assistantData.content,
          'reasoning': assistantData.reasoning,
          'createdAt': _messageDate(assistantNode['inserted_at'])
              .toIso8601String(),
        });
      }
    }
  }
  final firstAt = importedMessages.isEmpty
      ? _messageDate(conversation['inserted_at'])
      : DateTime.parse(importedMessages.first['createdAt']! as String);
  final lastAt = importedMessages.isEmpty
      ? firstAt
      : DateTime.parse(importedMessages.last['createdAt']! as String);
  return <String, Object?>{
    'imageBytes': usedImages,
    'thread': <String, Object?>{
      'title': conversation['title'] is String ? conversation['title'] : '',
      'createdAt': firstAt.toIso8601String(),
      'updatedAt': lastAt.toIso8601String(),
      'messages': importedMessages,
    },
  };
}

({
  String content,
  String reasoning,
  String? imageDataBase64,
  String? imageMimeType,
  int imageBytes,
})
_fragmentsToMessage(
  Object? raw, {
  required String role,
  required Map<String, ArchiveFile> byName,
  required int maxSingleImageBytes,
  required int maxTotalImageBytes,
  required int currentImageBytes,
}) {
  final fragments = raw is List
      ? raw.whereType<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];
  final content = <String>[];
  final reasoning = <String>[];
  String? imageData;
  String? imageMime;
  var imageBytes = 0;
  for (final fragment in fragments) {
    final type = fragment['type'];
    if (type == 'REQUEST' && role == 'user') {
      final text = fragment['content'];
      if (text is String && text.trim().isNotEmpty) content.add(text);
    } else if (type == 'RESPONSE' && role == 'assistant') {
      final text = fragment['content'];
      if (text is String && text.trim().isNotEmpty) content.add(text);
    } else if (type == 'THINK' && role == 'assistant') {
      final text = fragment['content'];
      if (text is String && text.trim().isNotEmpty) reasoning.add(text);
    } else if (type == 'FILE' && role == 'user') {
      final files = (fragment['files'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      for (final item in files) {
        final filename = item['file_name'] as String? ?? '附件';
        if (item['is_image'] == true && imageData == null) {
          final path = item['export_path'] as String?;
          final entry = path == null ? null : byName[path];
          if (entry != null &&
              entry.size <= maxSingleImageBytes &&
              currentImageBytes + entry.size <= maxTotalImageBytes) {
            final bytes = entry.readBytes();
            if (bytes != null && bytes.length <= maxSingleImageBytes) {
              imageData = base64Encode(bytes);
              imageBytes = bytes.length;
              imageMime = _imageMime(path!);
              continue;
            }
            entry.clear();
          }
        }
        content.add('[附件：$filename]');
      }
    } else if (type == 'TOOL_SEARCH' && role == 'assistant') {
      final results = (fragment['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .take(6);
      final lines = <String>[];
      for (final result in results) {
        final url = result['url'] as String? ?? '';
        final title = (result['title'] as String? ?? '').trim();
        final snippet = (result['snippet'] as String? ?? '').trim();
        if (url.startsWith('https://')) {
          lines.add(
            '- [${title.isEmpty ? url : title}]($url)${snippet.isEmpty ? '' : ' — $snippet'}',
          );
        }
      }
      if (lines.isNotEmpty) content.add('搜索来源：\n${lines.join('\n')}');
    } else if (type == 'READ_LINK' && role == 'assistant') {
      final results = (fragment['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      for (final result in results) {
        final url = result['url'] as String? ?? '';
        final title = result['title'] as String? ?? '';
        if (url.startsWith('https://')) {
          content.add('[${title.isEmpty ? url : title}]($url)');
        } else if (title.isNotEmpty) {
          content.add(title);
        }
      }
    } else if (type == 'TOOL_OPEN' && role == 'assistant') {
      final url = fragment['url'] as String? ?? '';
      final title = fragment['title'] as String? ?? '';
      if (url.startsWith('https://')) {
        content.add('查看网页：[${title.isEmpty ? url : title}]($url)');
      }
    }
  }
  return (
    content: content.join('\n\n'),
    reasoning: reasoning.join('\n\n'),
    imageDataBase64: imageData,
    imageMimeType: imageMime,
    imageBytes: imageBytes,
  );
}

String _imageMime(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => 'image/png',
  };
}

DateTime _messageDate(Object? value) =>
    DateTime.tryParse(value as String? ?? '') ??
    DateTime.fromMillisecondsSinceEpoch(0);

DateTime _exportTime(Object? value) =>
    DateTime.tryParse(value as String? ?? '') ??
    DateTime.fromMillisecondsSinceEpoch(0);
