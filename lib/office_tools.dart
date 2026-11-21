import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/local.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_xml/open_xml.dart';
import 'package:path_provider/path_provider.dart';

class PickedOfficeFile {
  const PickedOfficeFile({
    required this.name,
    required this.text,
    this.imageDataBase64,
    this.imageMimeType,
    this.originalBytes,
    this.mimeType = 'application/octet-stream',
  });

  final String name;
  final String text;
  final String? imageDataBase64;
  final String? imageMimeType;
  final Uint8List? originalBytes;
  final String mimeType;
}

class GeneratedOfficeFile {
  const GeneratedOfficeFile({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String path;
  final String name;
  final String mimeType;
  final int sizeBytes;
}

class OfficeTools {
  static const _maxFileBytes = 15 * 1024 * 1024;
  static const _maxImageBytes = 8 * 1024 * 1024;
  static const _maxAttachments = 10;
  static const _maxSelectionBytes = 40 * 1024 * 1024;
  static const _maxGeneratedTextChars = 90000;
  // The 15 MB source-file limit bounds the input. Keep complete extracted text;
  // document summarization, not extraction, is responsible for model budgeting.
  static const _fs = LocalFileSystem();

  Future<List<PickedOfficeFile>> pickAndExtract() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['docx', 'pptx', 'xlsx', 'csv', 'txt', 'md'],
      dialogTitle: '选择要交给 AI 阅读的文件',
    );
    if (files.isEmpty) return const <PickedOfficeFile>[];
    if (files.length > _maxAttachments) {
      throw const FormatException('一次最多选择 10 个文件。');
    }
    var selectedBytes = 0;
    final result = <PickedOfficeFile>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      selectedBytes += bytes.length;
      if (bytes.length > _maxFileBytes) {
        throw FormatException('文件“${file.name}”超过 15 MB，请先缩小文件再试。');
      }
      if (selectedBytes > _maxSelectionBytes) {
        throw const FormatException('所选文件合计超过 40 MB，请分批发送。');
      }
      final extension = (file.extension ?? '').toLowerCase();
      final extracted = switch (extension) {
        'docx' => await _readWord(bytes),
        'pptx' => await _readPresentation(bytes),
        'xlsx' => await _readSpreadsheet(bytes),
        'csv' || 'txt' || 'md' => utf8.decode(bytes, allowMalformed: true),
        _ => throw const FormatException('暂不支持这种文件格式。'),
      };
      final trimmed = extracted.trim();
      if (trimmed.isEmpty) {
        throw FormatException('文件“${file.name}”没有读取到可用的文字内容。');
      }
      result.add(
        PickedOfficeFile(
          name: file.name,
          text: trimmed,
          originalBytes: bytes,
          mimeType: _documentMimeType(extension),
        ),
      );
    }
    return result;
  }

  Future<List<PickedOfficeFile>> pickImages() async {
    final files = await FilePicker.pickFiles(
      type: FileType.image,
      dialogTitle: '添加图片',
      compressionQuality: 82,
    );
    if (files.isEmpty) return const <PickedOfficeFile>[];
    if (files.length > _maxAttachments) {
      throw const FormatException('一次最多选择 10 张图片。');
    }
    var selectedBytes = 0;
    final result = <PickedOfficeFile>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      selectedBytes += bytes.length;
      if (bytes.length > _maxImageBytes) {
        throw FormatException('图片“${file.name}”超过 8 MB，请先压缩后再试。');
      }
      if (selectedBytes > _maxSelectionBytes) {
        throw const FormatException('所选图片合计超过 40 MB，请分批发送。');
      }
      final extension = (file.extension ?? '').toLowerCase();
      final mimeType = _imageMimeType(extension);
      result.add(
        PickedOfficeFile(
          name: file.name,
          text: '用户附加图片：${file.name}',
          imageDataBase64: base64Encode(bytes),
          imageMimeType: mimeType,
          originalBytes: bytes,
          mimeType: mimeType,
        ),
      );
    }
    return result;
  }

  String _documentMimeType(String extension) => switch (extension) {
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'csv' => 'text/csv',
    'txt' => 'text/plain',
    'md' => 'text/markdown',
    _ => 'application/octet-stream',
  };

  String _imageMimeType(String extension) => switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => throw const FormatException('暂不支持这种图片格式。'),
  };

  Future<GeneratedOfficeFile> createWord({
    required String fileName,
    required String markdown,
  }) async {
    final path = await _temporaryPath('docx');
    final document = await WordDocument.create(_fs);
    try {
      for (final line in _limitedText(markdown).split('\n')) {
        final text = line.trimRight();
        final paragraph = Paragraph();
        paragraph.addText(
          text.startsWith('#')
              ? text.replaceFirst(RegExp(r'^#+\s*'), '')
              : text,
          bold: text.startsWith('#'),
        );
        document.addParagraph(paragraph);
      }
      await document.save(_fs.file(path));
      return await _save(
        path,
        _safeName(fileName, 'docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    } finally {
      await document.close();
      await _deleteTemporary(path);
    }
  }

  Future<GeneratedOfficeFile> createPresentation({
    required String fileName,
    required String title,
    required List<dynamic> slides,
  }) async {
    final path = await _temporaryPath('pptx');
    final presentation = await Presentation.create(_fs);
    try {
      presentation.title = title.trim().isEmpty ? 'Cwhale演示文稿' : title.trim();
      presentation.setAspectRatio(PresentationAspectRatio.widescreen_16_9);
      final boundedSlides = slides.take(20).toList();
      if (boundedSlides.isEmpty) {
        final slide = presentation.addSlide();
        slide.addTitle(presentation.title);
      }
      for (final item in boundedSlides) {
        if (item is! Map) continue;
        final slideTitle = item['title']?.toString().trim() ?? '';
        final bullets = (item['bullets'] as List<dynamic>? ?? const [])
            .take(20)
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .map((value) => '• $value')
            .join('\n');
        final slide = presentation.addSlide();
        slide.addTitle(slideTitle.isEmpty ? presentation.title : slideTitle);
        if (bullets.isNotEmpty) slide.addText(bullets);
      }
      await presentation.save(_fs.file(path));
      return await _save(
        path,
        _safeName(fileName, 'pptx'),
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
    } finally {
      await presentation.close();
      await _deleteTemporary(path);
    }
  }

  Future<GeneratedOfficeFile> createSpreadsheet({
    required String fileName,
    required List<dynamic> sheets,
  }) async {
    final path = await _temporaryPath('xlsx');
    final workbook = await Workbook.create(_fs);
    try {
      final boundedSheets = sheets.take(10).toList();
      if (boundedSheets.isEmpty) {
        workbook.addSheet('Sheet1');
      }
      for (var index = 0; index < boundedSheets.length; index++) {
        final item = boundedSheets[index];
        if (item is! Map) continue;
        final rawName = item['name']?.toString().trim() ?? '';
        final name = _sheetName(
          rawName.isEmpty ? 'Sheet${index + 1}' : rawName,
        );
        final sheet = workbook.addSheet(name);
        final columns = (item['columns'] as List<dynamic>? ?? const [])
            .take(50)
            .toList();
        if (columns.isNotEmpty) {
          final header = sheet.addRow();
          for (final column in columns) {
            header.addCell(column.toString());
          }
        }
        final rows = (item['rows'] as List<dynamic>? ?? const [])
            .take(500)
            .toList();
        var cellCount = columns.length;
        for (final rawRow in rows) {
          if (rawRow is! List) continue;
          if (cellCount >= 20000) break;
          final row = sheet.addRow();
          for (final value in rawRow.take(50)) {
            row.addCell(value?.toString() ?? '');
            cellCount++;
            if (cellCount >= 20000) break;
          }
        }
      }
      await workbook.save(_fs.file(path));
      return await _save(
        path,
        _safeName(fileName, 'xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } finally {
      await workbook.close();
      await _deleteTemporary(path);
    }
  }

  Future<String> _readWord(Uint8List bytes) async {
    final path = await _writeTemporary(bytes, 'docx');
    final document = await WordDocument.open(_fs.file(path), fs: _fs);
    try {
      return document.paragraphs.map((paragraph) => paragraph.text).join('\n');
    } finally {
      await document.close();
      await _deleteTemporary(path);
    }
  }

  Future<String> _readPresentation(Uint8List bytes) async {
    final path = await _writeTemporary(bytes, 'pptx');
    final presentation = await Presentation.open(_fs.file(path));
    try {
      return presentation.slides.indexed
          .map((entry) {
            final (index, slide) = entry;
            final content = slide.texts.join('\n').trim();
            return '第 ${index + 1} 页\n$content';
          })
          .join('\n\n');
    } finally {
      await presentation.close();
      await _deleteTemporary(path);
    }
  }

  Future<String> _readSpreadsheet(Uint8List bytes) async {
    final path = await _writeTemporary(bytes, 'xlsx');
    final workbook = await Workbook.open(_fs.file(path));
    try {
      return workbook.worksheets
          .map((sheet) {
            final rows = sheet.rows
                .map(
                  (row) => row.cells.map((cell) => cell.value ?? '').join('\t'),
                )
                .join('\n');
            return '工作表：${sheet.name}\n$rows';
          })
          .join('\n\n');
    } finally {
      await workbook.close();
      await _deleteTemporary(path);
    }
  }

  Future<String> _writeTemporary(Uint8List bytes, String extension) async {
    final path = await _temporaryPath(extension);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<String> _temporaryPath(String extension) async {
    final directory = await getTemporaryDirectory();
    return '${directory.path}${Platform.pathSeparator}suiwen-${DateTime.now().microsecondsSinceEpoch}.$extension';
  }

  Future<GeneratedOfficeFile> _save(
    String path,
    String fileName,
    String mimeType,
  ) async {
    final supportDirectory = await getApplicationSupportDirectory();
    final outputDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}generated_files',
    );
    await outputDirectory.create(recursive: true);
    final destinationName = await _availableFileName(outputDirectory, fileName);
    final destination = File(
      '${outputDirectory.path}${Platform.pathSeparator}$destinationName',
    );
    await File(path).copy(destination.path);
    return GeneratedOfficeFile(
      path: destination.path,
      name: destinationName,
      mimeType: mimeType,
      sizeBytes: await destination.length(),
    );
  }

  Future<String> _availableFileName(
    Directory directory,
    String fileName,
  ) async {
    final extensionIndex = fileName.lastIndexOf('.');
    final stem = extensionIndex < 0
        ? fileName
        : fileName.substring(0, extensionIndex);
    final extension = extensionIndex < 0
        ? ''
        : fileName.substring(extensionIndex);
    var candidate = fileName;
    var suffix = 2;
    while (await File('${directory.path}${Platform.pathSeparator}$candidate')
        .exists()) {
      candidate = '$stem ($suffix)$extension';
      suffix++;
    }
    return candidate;
  }

  Future<void> _deleteTemporary(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Temporary-file cleanup should not discard an otherwise successful action.
    }
  }

  String _safeName(String requested, String extension) {
    var result = requested.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (result.isEmpty) result = 'Cwhale生成文件';
    result = result.replaceFirst(RegExp(r'\.[^.]+$'), '');
    if (result.length > 80) result = result.substring(0, 80);
    return '$result.$extension';
  }

  String _sheetName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\\/?*\[\]:]'), '_');
    return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
  }

  String _limitedText(String value) => value.length > _maxGeneratedTextChars
      ? value.substring(0, _maxGeneratedTextChars)
      : value;
}
