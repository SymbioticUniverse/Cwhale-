part of 'chat_screen.dart';

typedef _MarkdownBlock = Widget Function(
  _MessageMarkdownState renderer,
  TextStyle style,
);

class _MessageMarkdown extends StatefulWidget {
  const _MessageMarkdown({
    required String this.source,
    required this.onOpenLink,
    this.desktop = false,
  }) : block = null;

  const _MessageMarkdown.block({
    required _MarkdownBlock this.block,
    required this.onOpenLink,
    this.desktop = false,
  }) : source = null;

  final String? source;
  final _MarkdownBlock? block;
  final ValueChanged<String>? onOpenLink;
  final bool desktop;

  @override
  State<_MessageMarkdown> createState() => _MessageMarkdownState();
}

class _MessageMarkdownState extends State<_MessageMarkdown> {
  Widget? _rendered;
  String? _renderedSource;
  _MarkdownBlock? _renderedBlock;
  Brightness? _renderedBrightness;
  bool? _renderedDesktop;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (_rendered != null &&
        _renderedSource == widget.source &&
        identical(_renderedBlock, widget.block) &&
        brightness == _renderedBrightness &&
        widget.desktop == _renderedDesktop) {
      return _rendered!;
    }
    _disposeLinkRecognizers();
    final style = TextStyle(
      color: _ink,
      fontSize: widget.desktop ? 16 : 15,
      height: widget.desktop ? 1.65 : 1.55,
    );
    _renderedSource = widget.source;
    _renderedBlock = widget.block;
    _renderedBrightness = brightness;
    _renderedDesktop = widget.desktop;
    final block = widget.block;
    if (block != null) return _rendered = block(this, style);
    return _rendered = SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final part in _parseMessageMarkdown(widget.source!))
            part(this, style),
        ],
      ),
    );
  }

  static final _links = RegExp(
    r'''\[([^\[\]\n]+)\]\((https?://[^)\s]+)\)|(https?://[^\s<>{}\[\]<>"`，。；：！？、）】》”’]+)''',
    caseSensitive: false,
  );
  static final _formatting = RegExp(
    r'\*\*(.+?)\*\*|(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)|(?<!_)_(?!\s)(.+?)(?<!\s)_(?!_)|`([^`]+)`',
    dotAll: true,
  );

  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    _disposeLinkRecognizers();
    super.dispose();
  }

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  List<InlineSpan> _messageSpans(String source, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _links.allMatches(source)) {
      if (match.start > cursor) {
        _addPlainSpans(spans, source.substring(cursor, match.start), baseStyle);
      }
      final markdownTitle = match.group(1);
      var url = (match.group(2) ?? match.group(3) ?? '').trim();
      var trailing = '';
      if (markdownTitle == null) {
        while (url.isNotEmpty && RegExp(r'[.,;:!?，。；：！？、]$').hasMatch(url)) {
          trailing = '${url.substring(url.length - 1)}$trailing';
          url = url.substring(0, url.length - 1);
        }
      }
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty) {
        _addPlainSpans(spans, match.group(0)!, baseStyle);
      } else {
        final title = markdownTitle?.trim();
        final label =
            title == null ||
                title.isEmpty ||
                title.startsWith('http://') ||
                title.startsWith('https://')
            ? _compactUrl(uri)
            : (title.length > 42 ? '${title.substring(0, 39)}…' : title);
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenLink?.call(uri.toString());
        _linkRecognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: label,
            style: baseStyle.copyWith(
              color: _green,
              decoration: TextDecoration.underline,
              decorationColor: _green.withValues(alpha: 0.55),
            ),
            recognizer: recognizer,
          ),
        );
        if (trailing.isNotEmpty) {
          _addPlainSpans(spans, trailing, baseStyle);
        }
      }
      cursor = match.end;
    }
    if (cursor < source.length) {
      _addPlainSpans(spans, source.substring(cursor), baseStyle);
    }
    return spans;
  }

  void _addPlainSpans(
    List<InlineSpan> spans,
    String text,
    TextStyle baseStyle,
  ) {
    var cursor = 0;
    for (final match in _formatting.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final boldText = match.group(1);
      final italicText = match.group(2) ?? match.group(3);
      final codeText = match.group(4);
      spans.add(
        TextSpan(
          text: boldText ?? italicText ?? codeText,
          style: boldText != null
              ? baseStyle.copyWith(fontWeight: FontWeight.w700)
              : codeText != null
              ? baseStyle.copyWith(
                  fontFamily: 'monospace',
                  backgroundColor: _surfaceRaised,
                )
              : baseStyle.copyWith(fontStyle: FontStyle.italic),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
  }

  String _compactUrl(Uri uri) {
    final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
    final lastSegment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final tail = lastSegment.length > 18
        ? '…${lastSegment.substring(lastSegment.length - 14)}'
        : lastSegment;
    final compact = tail.isEmpty ? host : '$host/…/$tail';
    return compact.length > 42 ? '${compact.substring(0, 39)}…' : compact;
  }

  Widget _inline(String text, TextStyle style) => Text.rich(
    TextSpan(style: style, children: _messageSpans(text, style)),
    style: style,
  );
}

final _leadingTablePipe = RegExp(r'^\|');
final _trailingTablePipe = RegExp(r'\|$');
final _tableSeparator = RegExp(r'^:?-{3,}:?$');
final _markdownHeading = RegExp(r'^(#{1,6})\s+(.+)$');
final _markdownQuote = RegExp(r'^>\s?');
final _markdownBullet = RegExp(r'^(?:[-*+]\s+|\d+[.)]\s+)(.+)$');
final _startsMarkdownBlock = RegExp(r'^(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)');

List<_MarkdownBlock> _parseMessageMarkdown(
  String source, {
  bool groupForScroll = false,
}) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <_MarkdownBlock>[];
  final pending = <_MarkdownBlock>[];
  const targetLines = 12;
  var pendingLines = 0;

  void flushGroup() {
    if (pending.length == 1) {
      blocks.add(pending.single);
    } else if (pending.isNotEmpty) {
      final group = List<_MarkdownBlock>.of(pending, growable: false);
      blocks.add(
        (renderer, style) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final item in group) item(renderer, style)],
        ),
      );
    }
    pending.clear();
    pendingLines = 0;
  }

  void addBlock(int estimatedLines, _MarkdownBlock build) {
    if (!groupForScroll) {
      blocks.add(build);
      return;
    }
    if (pendingLines + estimatedLines > targetLines) flushGroup();
    if (estimatedLines >= targetLines) {
      blocks.add(build);
      return;
    }
    pending.add(build);
    pendingLines += estimatedLines;
  }

  for (var i = 0; i < lines.length;) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    if (line.trimLeft().startsWith('```')) {
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        code.add(lines[i++]);
      }
      if (i < lines.length) i++;
      addBlock(
        code.length + 2,
        (renderer, style) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              constraints: const BoxConstraints(minWidth: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _surfaceRaised,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _line),
              ),
              child: Text(
                code.join('\n'),
                style: style.copyWith(
                  fontFamily: 'monospace',
                  fontSize: style.fontSize! - 1,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
      );
      continue;
    }
    if (line.trimLeft().startsWith('|') &&
        i + 1 < lines.length &&
        lines[i + 1].contains('|')) {
      final rows = <List<String>>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        final cells = lines[i]
            .trim()
            .replaceFirst(_leadingTablePipe, '')
            .replaceFirst(_trailingTablePipe, '')
            .split('|')
            .map((cell) => cell.trim())
            .toList();
        final separator =
            cells.isNotEmpty &&
            cells.every((cell) => _tableSeparator.hasMatch(cell));
        if (!separator) rows.add(cells);
        i++;
      }
      if (rows.isNotEmpty) {
        final columnCount = rows
            .map((row) => row.length)
            .reduce((a, b) => a > b ? a : b);
        addBlock(
          rows.length * 2,
          (renderer, style) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const FixedColumnWidth(150),
                border: TableBorder.all(
                  color: _line,
                  borderRadius: BorderRadius.circular(8),
                ),
                children: rows
                    .map(
                      (row) => TableRow(
                        children: List.generate(
                          columnCount,
                          (column) => Padding(
                            padding: const EdgeInsets.all(8),
                            child: renderer._inline(
                              column < row.length ? row[column] : '',
                              style.copyWith(
                                fontWeight: rows.first == row
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        );
      }
      continue;
    }
    final trimmed = line.trimLeft();
    final heading = _markdownHeading.firstMatch(trimmed);
    if (heading != null) {
      final level = heading.group(1)!.length;
      addBlock(
        2 + heading.group(2)!.length ~/ 25,
        (renderer, style) => Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 12 : 8, bottom: 3),
          child: renderer._inline(
            heading.group(2)!,
            style.copyWith(
              fontSize: (style.fontSize! + (4 - level).clamp(0, 3)).toDouble(),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
      i++;
      continue;
    }
    if (trimmed.startsWith('>')) {
      addBlock(
        1 + (trimmed.length + 24) ~/ 25,
        (renderer, style) => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: _green, width: 3)),
            color: _surface.withValues(alpha: 0.55),
          ),
          child: renderer._inline(
            trimmed.replaceFirst(_markdownQuote, ''),
            style.copyWith(color: _muted, fontStyle: FontStyle.italic),
          ),
        ),
      );
      i++;
      continue;
    }
    final bullet = _markdownBullet.firstMatch(trimmed);
    if (bullet != null) {
      addBlock(
        (trimmed.length + 24) ~/ 25,
        (renderer, style) => Padding(
          padding: const EdgeInsets.only(left: 7, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                RegExp(r'^\d').hasMatch(trimmed)
                    ? '${RegExp(r'^\d+').firstMatch(trimmed)!.group(0)}. '
                    : '•  ',
                style: style,
              ),
              Expanded(child: renderer._inline(bullet.group(1)!, style)),
            ],
          ),
        ),
      );
      i++;
      continue;
    }
    final paragraph = <String>[line];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !lines[i].trimLeft().startsWith('```') &&
        !lines[i].trimLeft().startsWith('|') &&
        !_startsMarkdownBlock.hasMatch(lines[i].trimLeft())) {
      paragraph.add(lines[i++]);
    }
    final text = paragraph.join('\n');
    for (final part in _splitPlainParagraph(text)) {
      addBlock(
        1 + (part.text.length + 24) ~/ 25,
        (renderer, style) => Padding(
          padding: EdgeInsets.only(bottom: part.last ? 7 : 0),
          child: renderer._inline(part.text, style),
        ),
      );
    }
  }
  flushGroup();
  return blocks;
}

Iterable<({String text, bool last})> _splitPlainParagraph(String text) sync* {
  const limit = 1200;
  if (text.length <= limit || _inlineMarkdownMarker.hasMatch(text)) {
    yield (text: text, last: true);
    return;
  }
  var start = 0;
  while (text.length - start > limit) {
    final maximum = start + limit;
    var end = text.lastIndexOf('\n', maximum - 1) + 1;
    if (end < start + limit ~/ 2) {
      end = text.lastIndexOf(' ', maximum - 1) + 1;
    }
    if (end < start + limit ~/ 2) {
      end = maximum;
      final next = text.codeUnitAt(end);
      if (next >= 0xdc00 && next <= 0xdfff) end--;
    }
    // A row boundary already supplies a line break.
    final visibleEnd = text.codeUnitAt(end - 1) == 10 ? end - 1 : end;
    yield (text: text.substring(start, visibleEnd), last: false);
    start = end;
  }
  yield (text: text.substring(start), last: true);
}

final _inlineMarkdownMarker = RegExp(
  r'[*_`\[]|https?://',
  caseSensitive: false,
);
