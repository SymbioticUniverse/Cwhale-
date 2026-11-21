import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'chat_models.dart';
import 'document_memory.dart';
import 'story_simulator_memory.dart';

class LocalStore {
  static Future<void> _threadIndexWriteQueue = Future<void>.value();
  static const messageChunkSize = 100;
  static const _largeChunkSize = 32 * 1024;
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
  static const _settingsKey = 'suiwen.model-settings.v1';
  static const _modelDataConsentsKey = 'suiwen.model-data-consents.v1';

  Future<File> _chatFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(directory.path + Platform.pathSeparator + 'chats-v1.json');
  }

  Future<File> _threadIndexFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(directory.path + Platform.pathSeparator + 'chats-v2.json');
  }

  Future<File> _activeThreadFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
      directory.path + Platform.pathSeparator + 'active-thread-v1.txt',
    );
  }

  Future<String?> loadActiveThreadId() async {
    final file = await _activeThreadFile();
    if (!await file.exists()) return null;
    try {
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> saveActiveThreadId(String threadId) async {
    final file = await _activeThreadFile();
    await file.writeAsString(threadId, flush: true);
  }

  Future<void> appendGenerationDiagnostic(Map<String, dynamic> event) async {
    final directory = await getApplicationSupportDirectory();
    final file = File(
      directory.path +
          Platform.pathSeparator +
          'generation-diagnostics-v1.jsonl',
    );
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() > 256 * 1024) {
      final lines = (await file.readAsLines())
          .where((line) => line.isNotEmpty)
          .toList();
      final retained = lines.skip(lines.length > 500 ? lines.length - 500 : 0);
      await file.writeAsString('${retained.join('\n')}\n', flush: true);
    }
    await file.writeAsString(
      '${jsonEncode(event)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<File> _generationCheckpointFile(
    String threadId,
    String messageId,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
      throw FormatException('消息 ID 不合法，已拒绝访问本机断点路径。');
    }
    final directory = await _threadArchiveDirectory(threadId);
    return File(
      directory.path +
          Platform.pathSeparator +
          'generation-$messageId-checkpoint.json',
    );
  }

  Future<void> saveGenerationCheckpoint({
    required String threadId,
    required String messageId,
    required String content,
  }) async {
    final file = await _generationCheckpointFile(threadId, messageId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'messageId': messageId,
        'content': content,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<String?> loadGenerationCheckpoint({
    required String threadId,
    required String messageId,
  }) async {
    try {
      final file = await _generationCheckpointFile(threadId, messageId);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['messageId'] != messageId) {
        return null;
      }
      return decoded['content'] as String?;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearGenerationCheckpoint({
    required String threadId,
    required String messageId,
  }) async {
    try {
      final file = await _generationCheckpointFile(threadId, messageId);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A stale sidecar is ignored unless the corresponding message is pending.
    }
  }

  Future<Directory> _threadArchivesDirectory() async {
    final directory = await getApplicationSupportDirectory();
    return Directory(directory.path + Platform.pathSeparator + 'threads');
  }

  Future<Directory> _threadArchiveDirectory(String threadId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(threadId)) {
      throw FormatException('对话 ID 不合法，已拒绝访问本机归档路径。');
    }
    final root = await _threadArchivesDirectory();
    return Directory(root.path + Platform.pathSeparator + threadId);
  }

  Future<File> _messageChunkFile(String threadId, int chunkIndex) async {
    final directory = await _threadArchiveDirectory(threadId);
    final name = 'messages-${chunkIndex.toString().padLeft(8, '0')}.json';
    return File(directory.path + Platform.pathSeparator + name);
  }

  Future<Directory> _threadDocumentsDirectory(String threadId) async {
    final directory = await _threadArchiveDirectory(threadId);
    return Directory(directory.path + Platform.pathSeparator + 'documents');
  }

  Future<String> saveThreadAttachment({
    required String threadId,
    required String fileName,
    required List<int> bytes,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(threadId)) {
      throw FormatException('对话 ID 不合法，已拒绝保存本机附件。');
    }
    final safeName = fileName.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final extension = safeName.contains('.')
        ? safeName.substring(safeName.lastIndexOf('.')).toLowerCase()
        : '';
    final safeExtension = RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension)
        ? extension
        : '';
    final threadDirectory = await _threadArchiveDirectory(threadId);
    final directory = Directory(
      threadDirectory.path + Platform.pathSeparator + 'attachments',
    );
    await directory.create(recursive: true);
    final file = File(
      directory.path + Platform.pathSeparator + '${newLocalId()}$safeExtension',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Directory> _documentDirectory(
    String threadId,
    String documentId,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(documentId)) {
      throw FormatException('文档 ID 不合法，已拒绝访问本机文档路径。');
    }
    final root = await _threadDocumentsDirectory(threadId);
    return Directory(root.path + Platform.pathSeparator + documentId);
  }

  Future<File> _documentMetadataFile(String threadId, String documentId) async {
    final directory = await _documentDirectory(threadId, documentId);
    return File(directory.path + Platform.pathSeparator + 'metadata-v1.json');
  }

  Future<File> _documentSourceFile(String threadId, String documentId) async {
    final directory = await _documentDirectory(threadId, documentId);
    return File(directory.path + Platform.pathSeparator + 'source.txt');
  }

  Future<void> saveLocalDocument(
    LocalDocumentRecord document, {
    String? sourceText,
  }) async {
    final directory = await _documentDirectory(document.threadId, document.id);
    await directory.create(recursive: true);
    if (sourceText != null) {
      final source = await _documentSourceFile(document.threadId, document.id);
      if (!await source.exists()) {
        await source.writeAsString(sourceText, flush: true);
      }
    }
    document.updatedAt = DateTime.now().toIso8601String();
    final metadata = await _documentMetadataFile(
      document.threadId,
      document.id,
    );
    await metadata.writeAsString(jsonEncode(document.toJson()), flush: true);
  }

  Future<LocalDocumentRecord?> loadLocalDocument(
    String threadId,
    String documentId,
  ) async {
    try {
      final file = await _documentMetadataFile(threadId, documentId);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return LocalDocumentRecord.fromJson(decoded);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<List<LocalDocumentRecord>> loadLocalDocuments(String threadId) async {
    final root = await _threadDocumentsDirectory(threadId);
    if (!await root.exists()) return <LocalDocumentRecord>[];
    final documents = <LocalDocumentRecord>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final record = await loadLocalDocument(threadId, id);
      if (record != null) documents.add(record);
    }
    documents.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return documents;
  }

  Future<String> loadLocalDocumentSource(
    String threadId,
    String documentId, {
    int? start,
    int? end,
  }) async {
    final file = await _documentSourceFile(threadId, documentId);
    if (!await file.exists()) throw const FileSystemException('本机原文归档不存在。');
    if (start == null && end == null) return file.readAsString();
    final from = start ?? 0;
    final to = end ?? from;
    if (from < 0 || to <= from) return '';
    final output = StringBuffer();
    var characterOffset = 0;
    await for (final segment in file.openRead().transform(utf8.decoder)) {
      final segmentEnd = characterOffset + segment.length;
      if (segmentEnd > from && characterOffset < to) {
        final localStart = (from - characterOffset).clamp(0, segment.length);
        final localEnd = (to - characterOffset).clamp(
          localStart,
          segment.length,
        );
        output.write(segment.substring(localStart, localEnd));
      }
      characterOffset = segmentEnd;
      if (characterOffset >= to) break;
    }
    return output.toString();
  }

  Future<File> _importantMemoryFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
      directory.path + Platform.pathSeparator + 'important-memories-v1.json',
    );
  }

  Future<File> _deletedMemoryTopicsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
      directory.path + Platform.pathSeparator + 'deleted-memory-topics-v1.json',
    );
  }

  Future<List<ImportantMemoryRecord>> loadDeletedMemoryTopics() async {
    final file = await _deletedMemoryTopicsFile();
    if (!await file.exists()) return <ImportantMemoryRecord>[];
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(ImportantMemoryRecord.fromJson)
          .toList();
    } on FormatException {
      return <ImportantMemoryRecord>[];
    } on FileSystemException {
      return <ImportantMemoryRecord>[];
    }
  }

  Future<void> saveDeletedMemoryTopics(
    List<ImportantMemoryRecord> records,
  ) async {
    final file = await _deletedMemoryTopicsFile();
    await file.writeAsString(
      jsonEncode(records.map((item) => item.toJson()).toList()),
      flush: true,
    );
  }

  Future<Directory> _generatedFilesDirectory() async {
    final directory = await getApplicationSupportDirectory();
    return Directory(
      directory.path + Platform.pathSeparator + 'generated_files',
    );
  }

  Future<List<ChatThread>> loadThreads() async {
    final indexFile = await _threadIndexFile();
    if (await indexFile.exists()) {
      try {
        final decoded =
            jsonDecode(await indexFile.readAsString()) as List<dynamic>;
        final threads = decoded
            .whereType<Map<String, dynamic>>()
            .map(ChatThread.fromJson)
            .toList();
        final legacyFile = await _chatFile();
        if (await legacyFile.exists()) {
          try {
            await legacyFile.delete();
          } on FileSystemException {
            // A valid v2 archive remains canonical; retry legacy cleanup next launch.
          }
        }
        return threads;
      } on FormatException {
        // If an interrupted migration left a broken v2 index, recover from v1.
      } on FileSystemException {
        // Continue to the legacy file when it is still available.
      }
    }

    final legacyFile = await _chatFile();
    if (!await legacyFile.exists()) return <ChatThread>[];
    try {
      final decoded =
          jsonDecode(await legacyFile.readAsString()) as List<dynamic>;
      final threads = decoded
          .whereType<Map<String, dynamic>>()
          .map(ChatThread.fromJson)
          .toList();
      for (final thread in threads) {
        final legacyMessages = List<ChatMessage>.of(thread.messages);
        await _writeAllMessages(thread.id, legacyMessages);
        thread.messageCount = legacyMessages.length;
        thread.messageBaseIndex = legacyMessages.length;
        thread.messages.clear();
      }
      await saveThreads(threads);
      // The migrated archive and index are durable before the legacy copy is removed.
      try {
        await legacyFile.delete();
      } on FileSystemException {
        // A valid v2 archive remains canonical; retry legacy cleanup next launch.
      }
      return threads;
    } on FormatException {
      return <ChatThread>[];
    } on FileSystemException {
      return <ChatThread>[];
    }
  }

  Future<void> saveThreads(List<ChatThread> threads) {
    final snapshot = jsonEncode(
      threads.map((thread) => thread.toJson(includeMessages: false)).toList(),
    );
    final operation = _threadIndexWriteQueue.catchError((_) {}).then((_) async {
      final file = await _threadIndexFile();
      await file.writeAsString(snapshot, flush: true);
    });
    _threadIndexWriteQueue = operation;
    return operation;
  }

  Future<void> _writeAllMessages(
    String threadId,
    List<ChatMessage> messages,
  ) async {
    final directory = await _threadArchiveDirectory(threadId);
    await directory.create(recursive: true);
    await for (final entity in directory.list()) {
      if (entity is File &&
          RegExp(r'^messages-\d{8}\.json$')
              .hasMatch(entity.uri.pathSegments.last)) {
        await entity.delete();
      }
    }
    for (var start = 0; start < messages.length; start += messageChunkSize) {
      final end = (start + messageChunkSize).clamp(0, messages.length);
      final chunk = messages.sublist(start, end);
      final file = await _messageChunkFile(threadId, start ~/ messageChunkSize);
      await _writeChunk(file, chunk);
    }
  }

  Future<List<ChatMessage>> loadMessagesRange(
    String threadId, {
    required int start,
    required int end,
  }) async {
    if (start < 0 || end <= start) return <ChatMessage>[];
    final messages = <ChatMessage>[];
    final firstChunk = start ~/ messageChunkSize;
    final lastChunk = (end - 1) ~/ messageChunkSize;
    for (var chunkIndex = firstChunk; chunkIndex <= lastChunk; chunkIndex++) {
      final file = await _messageChunkFile(threadId, chunkIndex);
      final chunk = await _readChunk(file);
      if (chunk.isEmpty) continue;
      final migrated = await _migrateInlineDocuments(threadId, chunk);
      if (migrated) {
        await _writeChunk(file, chunk);
      }
      final chunkStart = chunkIndex * messageChunkSize;
      final from = (start - chunkStart).clamp(0, chunk.length);
      final to = (end - chunkStart).clamp(0, chunk.length);
      if (to > from) messages.addAll(chunk.sublist(from, to));
    }
    return messages;
  }

  /// Moves legacy inline attachment text out of chat prompts into the local
  /// document archive while preserving the original text byte-for-byte at the
  /// Dart string level. The message keeps its visible attachment label and a
  /// stable link to the new local document record.
  Future<bool> _migrateInlineDocuments(
    String threadId,
    List<ChatMessage> messages,
  ) async {
    const startMarker = '<文件内容开始>';
    const endMarker = '<文件内容结束>';
    List<LocalDocumentRecord>? existingDocuments;
    var changed = false;
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (message.role != 'user' || message.documentId != null) continue;
      final content = message.content;
      final start = content.indexOf(startMarker);
      final end = start < 0
          ? -1
          : content.indexOf(endMarker, start + startMarker.length);
      if (start < 0 || end < 0) continue;

      final prefix = content.substring(0, start);
      if (!prefix.contains('用户附加的本地文件：')) continue;

      var source = content.substring(start + startMarker.length, end);
      source = source.replaceFirst(RegExp(r'^\r?\n'), '');
      source = source.replaceFirst(RegExp(r'\r?\n$'), '');
      if (source.isEmpty) continue;

      final name = RegExp(r'用户附加的本地文件：([^\r\n]+)')
          .firstMatch(prefix)
          ?.group(1)
          ?.trim();
      final question =
          RegExp(r'用户问题：([\s\S]*)$').firstMatch(prefix)?.group(1)?.trim() ?? '';
      existingDocuments ??= await loadLocalDocuments(threadId);
      LocalDocumentRecord? document;
      for (final candidate in existingDocuments) {
        if (candidate.attachedMessageId == message.id) {
          document = candidate;
          break;
        }
      }
      if (document == null) {
        document = LocalDocumentRecord(
          id: newLocalId(),
          threadId: threadId,
          name: name?.isNotEmpty == true ? name! : '历史附件',
          createdAt: message.createdAt,
          sourceLength: source.length,
          initialQuestion: question,
          attachedMessageId: message.id,
          status: 'pending',
        );
        await saveLocalDocument(document, sourceText: source);
        existingDocuments.add(document);
      }

      final json = Map<String, dynamic>.from(message.toJson())
        ..['content'] = '用户附加的本机文档：${document.name}\n用户问题：$question'
        ..['documentId'] = document.id;
      messages[index] = ChatMessage.fromJson(json);
      changed = true;
    }
    return changed;
  }

  Future<DateTime?> latestUserMessageAt(ChatThread thread) async {
    final chunkCount =
        (thread.messageCount + messageChunkSize - 1) ~/ messageChunkSize;
    for (var chunkIndex = chunkCount - 1; chunkIndex >= 0; chunkIndex--) {
      final start = chunkIndex * messageChunkSize;
      final end = (start + messageChunkSize).clamp(0, thread.messageCount);
      final chunk = await loadMessagesRange(thread.id, start: start, end: end);
      for (final message in chunk.reversed) {
        if (message.role == 'user') return message.createdAt;
      }
    }
    return null;
  }

  Future<void> appendMessages(
    String threadId, {
    required int startIndex,
    required List<ChatMessage> messages,
  }) async {
    if (messages.isEmpty) return;
    final directory = await _threadArchiveDirectory(threadId);
    await directory.create(recursive: true);
    var offset = 0;
    while (offset < messages.length) {
      final absoluteIndex = startIndex + offset;
      final chunkIndex = absoluteIndex ~/ messageChunkSize;
      final file = await _messageChunkFile(threadId, chunkIndex);
      final chunk = await _readChunk(file);
      final withinChunk = absoluteIndex % messageChunkSize;
      while (offset < messages.length &&
          (startIndex + offset) ~/ messageChunkSize == chunkIndex) {
        final index = (startIndex + offset) % messageChunkSize;
        if (index < chunk.length) {
          chunk[index] = messages[offset];
        } else if (index == chunk.length) {
          chunk.add(messages[offset]);
        } else {
          throw StateError('本机聊天分块出现缺口，无法安全追加消息。');
        }
        offset++;
      }
      if (withinChunk >= messageChunkSize) {
        throw StateError('本机聊天分块索引无效。');
      }
      await _writeChunk(file, chunk);
    }
  }

  Future<void> replaceMessage(
    String threadId, {
    required int index,
    required ChatMessage message,
  }) async {
    if (index < 0) return;
    final chunkIndex = index ~/ messageChunkSize;
    final file = await _messageChunkFile(threadId, chunkIndex);
    final chunk = await _readChunk(file);
    final withinChunk = index % messageChunkSize;
    if (withinChunk >= chunk.length) return;
    chunk[withinChunk] = message;
    await _writeChunk(file, chunk);
  }

  Future<void> rewriteMessages(String threadId, List<ChatMessage> messages) =>
      _writeAllMessages(threadId, messages);

  Future<void> saveWindowMemory(ChatThread thread) async {
    final directory = await _threadArchiveDirectory(thread.id);
    await directory.create(recursive: true);
    final file = File(
      directory.path + Platform.pathSeparator + 'window-memory-v1.json',
    );
    await file.writeAsString(
      jsonEncode({
        'threadId': thread.id,
        'handoffSummary': thread.handoffSummary,
        'updatedAt': DateTime.now().toIso8601String(),
        'sourceThreadId': thread.handoffSourceThreadId.isEmpty
            ? thread.id
            : thread.handoffSourceThreadId,
        'sourceMessageIds': thread.handoffSourceMessageIds,
        'localNote': thread.localNote,
        'rollingSummary': thread.rollingSummary,
        'windowMemories': thread.windowMemories
            .map((memory) => memory.toJson())
            .toList(),
      }),
      flush: true,
    );
  }

  Future<File> _storySimulatorMemoryFile(String threadId) async {
    final directory = await _threadArchiveDirectory(threadId);
    return File(
      directory.path +
          Platform.pathSeparator +
          'story-simulator-memory-v1.json',
    );
  }

  Future<StorySimulatorMemory?> loadStorySimulatorMemory(
    String threadId,
  ) async {
    try {
      final file = await _storySimulatorMemoryFile(threadId);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['threadId'] != threadId ||
          decoded['memory'] is! Map<String, dynamic>) {
        return null;
      }
      return StorySimulatorMemory.fromJson(
        decoded['memory'] as Map<String, dynamic>,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveStorySimulatorMemory(ChatThread thread) async {
    final file = await _storySimulatorMemoryFile(thread.id);
    await file.parent.create(recursive: true);
    final memory = StorySimulatorMemory(
      globalMemoryText: thread.storyGlobalMemoryText,
      storyTime: thread.storyTime,
      summaries: thread.storySummaries,
    );
    await file.writeAsString(
      jsonEncode({'threadId': thread.id, 'memory': memory.toJson()}),
      flush: true,
    );
  }

  Future<String> loadStoryGlobalMemoryText(String threadId) async =>
      (await loadStorySimulatorMemory(threadId))?.globalMemoryText ?? '';

  Future<String> loadStorySummaryMemoryText(String threadId) async {
    final memory = await loadStorySimulatorMemory(threadId);
    if (memory == null) return '';
    return memory.summaries.map((item) => item.render()).join('\n\n');
  }

  Future<String> loadFullStoryMemoryText(
    String threadId, {
    required int messageCount,
  }) async {
    final output = StringBuffer();
    for (var start = 0; start < messageCount; start += messageChunkSize) {
      final messages = await loadMessagesRange(
        threadId,
        start: start,
        end: (start + messageChunkSize).clamp(0, messageCount).toInt(),
      );
      for (var offset = 0; offset < messages.length; offset++) {
        final message = messages[offset];
        final index = start + offset;
        final chunk = (index ~/ messageChunkSize).toString().padLeft(8, '0');
        output
          ..writeln(
            '位置：threads/$threadId/messages-$chunk.json[${index % messageChunkSize}]#${message.id}',
          )
          ..writeln('角色：${message.role == 'user' ? '用户' : '助手'}')
          ..writeln(message.content)
          ..writeln();
      }
    }
    return output.toString().trimRight();
  }

  Future<void> truncateMessages(String threadId, int newCount) async {
    final directory = await _threadArchiveDirectory(threadId);
    if (!await directory.exists()) return;
    final lastChunkIndex = newCount == 0
        ? -1
        : (newCount - 1) ~/ messageChunkSize;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final match = RegExp(r'^messages-(\d{8})\.json$')
          .firstMatch(entity.uri.pathSegments.last);
      if (match == null) continue;
      final chunkIndex = int.tryParse(match.group(1) ?? '') ?? -1;
      if (chunkIndex > lastChunkIndex) {
        await entity.delete();
      } else if (chunkIndex == lastChunkIndex &&
          newCount % messageChunkSize != 0) {
        final chunk = await _readChunk(entity);
        final keep = newCount % messageChunkSize;
        if (chunk.length > keep) {
          await entity.writeAsString(
            jsonEncode(chunk.take(keep).map((item) => item.toJson()).toList()),
            flush: true,
          );
        }
      }
    }
  }

  Future<List<ChatMessage>> _readChunk(File file) async {
    if (!await file.exists()) return <ChatMessage>[];
    final contents = await file.readAsString();
    if (contents.length >= _largeChunkSize) {
      return compute(_decodeChunk, contents, debugLabel: 'decode chat history');
    }
    return _decodeChunk(contents);
  }

  static List<ChatMessage> _decodeChunk(String contents) {
    final decoded = jsonDecode(contents) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<void> _writeChunk(File file, List<ChatMessage> chunk) async {
    var length = 0;
    for (final message in chunk) {
      length +=
          message.content.length +
          message.reasoning.length +
          (message.displayContent?.length ?? 0) +
          (message.imageDataBase64?.length ?? 0);
      for (final version in message.versions) {
        length += version.length;
      }
      if (length >= _largeChunkSize) break;
    }
    final contents = length >= _largeChunkSize
        ? await compute(_encodeChunk, chunk, debugLabel: 'encode chat history')
        : _encodeChunk(chunk);
    await file.writeAsString(contents, flush: true);
  }

  static String _encodeChunk(List<ChatMessage> chunk) =>
      jsonEncode(chunk.map((message) => message.toJson()).toList());

  Future<Set<String>> searchThreadContent(
    Iterable<ChatThread> threads,
    String query,
  ) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return <String>{};
    final matches = <String>{};
    for (final thread in threads) {
      final chunks =
          (thread.messageCount + messageChunkSize - 1) ~/ messageChunkSize;
      for (var chunkIndex = 0; chunkIndex < chunks; chunkIndex++) {
        final start = chunkIndex * messageChunkSize;
        final end = (start + messageChunkSize).clamp(0, thread.messageCount);
        final messages = await loadMessagesRange(
          thread.id,
          start: start,
          end: end,
        );
        if (messages.any(
          (message) => message.content.toLowerCase().contains(needle),
        )) {
          matches.add(thread.id);
          break;
        }
      }
    }
    return matches;
  }

  Future<List<Map<String, String>>> searchArchivedMessages(
    Iterable<ChatThread> threads,
    String query, {
    required String excludeThreadId,
    List<ImportantMemoryRecord> deletedTopics = const <ImportantMemoryRecord>[],
    int limit = 3,
  }) async {
    final terms = <String>{};
    for (final match in RegExp(
      r'[a-zA-Z0-9_-]{3,}|[\u3400-\u9fff]{2,}',
    ).allMatches(query.toLowerCase())) {
      final value = match.group(0)!;
      if (value.length <= 8) {
        terms.add(value);
      } else if (RegExp(r'[\u3400-\u9fff]').hasMatch(value)) {
        for (var i = 0; i < value.length - 1; i++) {
          terms.add(value.substring(i, i + 2));
        }
      }
    }
    const ignored = {'之前', '以前', '上次', '过去', '历史', '我说', '说过', '什么', '发生'};
    terms.removeAll(ignored);
    if (terms.isEmpty) return <Map<String, String>>[];
    final candidates = <({int score, DateTime at, Map<String, String> item})>[];
    for (final thread in threads) {
      if (thread.id == excludeThreadId || !thread.isArchived) continue;
      for (
        var start = 0;
        start < thread.messageCount;
        start += messageChunkSize
      ) {
        final chunk = await loadMessagesRange(
          thread.id,
          start: start,
          end: (start + messageChunkSize).clamp(0, thread.messageCount),
        );
        for (final message in chunk) {
          final content = message.content.toLowerCase();
          if (content.trim().isEmpty) continue;
          final deletedMatch = deletedTopics.any((record) {
            if (record.content.trim().length >= 6 &&
                content.contains(record.content.toLowerCase()))
              return true;
            final specific = record.keywords
                .where((keyword) => keyword.length >= 3)
                .toList();
            return specific.length >= 2 &&
                specific.every(
                  (keyword) => content.contains(keyword.toLowerCase()),
                );
          });
          if (deletedMatch) continue;
          final score = terms.where(content.contains).length;
          if (score == 0) continue;
          final body = message.content.length > 650
              ? '${message.content.substring(0, 650)}…'
              : message.content;
          candidates.add((
            score: score,
            at: message.createdAt,
            item: {
              'threadId': thread.id,
              'title': thread.title,
              'messageId': message.id,
              'timestamp': formatLocalTimestamp(message.createdAt),
              'role': message.role,
              'content': body,
            },
          ));
        }
      }
    }
    candidates.sort(
      (a, b) => b.score != a.score
          ? b.score.compareTo(a.score)
          : b.at.compareTo(a.at),
    );
    return candidates.take(limit).map((candidate) => candidate.item).toList();
  }

  Future<List<String>> generatedFilePaths(
    String threadId,
    int messageCount,
  ) async {
    final paths = <String>[];
    for (var start = 0; start < messageCount; start += messageChunkSize) {
      final messages = await loadMessagesRange(
        threadId,
        start: start,
        end: (start + messageChunkSize).clamp(0, messageCount),
      );
      paths.addAll(
        messages.map((message) => message.filePath).whereType<String>(),
      );
    }
    return paths;
  }

  Future<void> deleteThreadArchive(String threadId) async {
    final directory = await _threadArchiveDirectory(threadId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<List<ImportantMemoryRecord>> loadImportantMemories() async {
    final file = await _importantMemoryFile();
    if (!await file.exists()) return <ImportantMemoryRecord>[];
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(ImportantMemoryRecord.fromJson)
          .toList();
    } on FormatException {
      return <ImportantMemoryRecord>[];
    } on FileSystemException {
      return <ImportantMemoryRecord>[];
    }
  }

  Future<void> saveImportantMemories(
    List<ImportantMemoryRecord> memories,
  ) async {
    final file = await _importantMemoryFile();
    await file.writeAsString(
      jsonEncode(memories.map((memory) => memory.toJson()).toList()),
      flush: true,
    );
  }

  Future<ModelSettings> loadSettings() async {
    final saved = await _secure.read(key: _settingsKey);
    if (saved == null || saved.isEmpty) return const ModelSettings();
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      final settings = ModelSettings.fromJson(decoded);
      if (decoded.containsKey('weatherApiKey')) {
        await saveSettings(settings);
      }
      return settings;
    } on FormatException {
      return const ModelSettings();
    }
  }

  Future<void> saveSettings(ModelSettings settings) =>
      _secure.write(key: _settingsKey, value: jsonEncode(settings.toJson()));

  Future<Set<String>> loadModelDataConsents() async {
    final saved = await _secure.read(key: _modelDataConsentsKey);
    if (saved == null) return {};
    try {
      final decoded = jsonDecode(saved);
      return decoded is List ? decoded.whereType<String>().toSet() : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> saveModelDataConsents(Set<String> endpoints) => _secure.write(
    key: _modelDataConsentsKey,
    value: jsonEncode(endpoints.toList()),
  );

  Future<void> revokeModelDataConsents() =>
      _secure.delete(key: _modelDataConsentsKey);

  Future<void> deleteThreadData() async {
    final file = await _chatFile();
    if (await file.exists()) await file.delete();
    final indexFile = await _threadIndexFile();
    if (await indexFile.exists()) await indexFile.delete();
    final activeThreadFile = await _activeThreadFile();
    if (await activeThreadFile.exists()) await activeThreadFile.delete();
    final threadArchives = await _threadArchivesDirectory();
    if (await threadArchives.exists())
      await threadArchives.delete(recursive: true);
    final memoryFile = await _importantMemoryFile();
    if (await memoryFile.exists()) await memoryFile.delete();
    final deletedMemoryFile = await _deletedMemoryTopicsFile();
    if (await deletedMemoryFile.exists()) await deletedMemoryFile.delete();
    final generatedFiles = await _generatedFilesDirectory();
    if (await generatedFiles.exists()) {
      await generatedFiles.delete(recursive: true);
    }
  }

  Future<void> deleteGeneratedFiles(Iterable<String> paths) async {
    final directory = await _generatedFilesDirectory();
    if (!await directory.exists()) return;
    final root = await directory.resolveSymbolicLinks();
    final rootPrefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final resolved = await file.resolveSymbolicLinks();
        if (resolved.startsWith(rootPrefix)) await file.delete();
      } on FileSystemException {
        // A missing or inaccessible attachment should not block chat deletion.
      }
    }
  }
}
