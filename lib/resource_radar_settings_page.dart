import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'resource_radar.dart';

class ResourceRadarSettingsPage extends StatefulWidget {
  const ResourceRadarSettingsPage({super.key});

  @override
  State<ResourceRadarSettingsPage> createState() =>
      _ResourceRadarSettingsPageState();
}

class _ResourceRadarSettingsPageState extends State<ResourceRadarSettingsPage> {
  final _radar = ResourceRadar.instance;
  late Future<void> _ready;
  String _query = '';
  String _category = 'all';
  bool _onlyEnabled = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ready = _radar.initialize();
  }

  Future<void> _apply(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } on FormatException catch (error) {
      _message(error.message);
    } catch (_) {
      _message('操作失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<String?> _ask({
    required String title,
    required String label,
    String value = '',
    String? help,
    bool secret = false,
  }) async {
    var draft = value;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: value,
          autofocus: true,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            helperMaxLines: 4,
          ),
          onChanged: (text) => draft = text,
          onFieldSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(RadarSource source) async {
    final name = source.name;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          children: [
            ListTile(title: Text(name), subtitle: Text(_radar.status(source))),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('配置公开订阅地址'),
              subtitle: const Text('可用 HTTPS RSS 或 Atom 覆盖内置入口'),
              onTap: () => Navigator.pop(context, 'feed'),
            ),
            if (source.kind == 'telegram')
              ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('配置 Telegram 公开频道'),
                onTap: () => Navigator.pop(context, 'channels'),
              ),
            if (source.kind == 'nga')
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('配置 NGA 登录'),
                subtitle: const Text('三个 NGA 板块共用，凭据保存在设备安全存储'),
                onTap: () => Navigator.pop(context, 'nga'),
              ),
            if (source.needsImport) ...[
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入本机 JSON'),
                subtitle: const Text(
                  '每条包含 title 和 url，可附 summary 和 publishedAt',
                ),
                onTap: () => Navigator.pop(context, 'import'),
              ),
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('清除已导入条目'),
                onTap: () => Navigator.pop(context, 'clear'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'feed':
        final value = await _ask(
          title: name,
          label: 'HTTPS 订阅地址',
          value: _radar.feed(source),
          help: '留空恢复内置入口。请使用公开地址。',
        );
        if (value != null && mounted)
          await _apply(() => _radar.setFeed(source, value));
      case 'channels':
        final value = await _ask(
          title: name,
          label: '公开频道用户名',
          value: _radar.channels(source).join(', '),
          help: '用逗号或空格分隔，可填 @频道名。',
        );
        if (value != null && mounted)
          await _apply(() => _radar.setChannels(source, value));
      case 'nga':
        final value = await _ask(
          title: 'NGA 登录',
          label: '站点 Cookie',
          help: '请输入自己账号的 ngaPassportUid 和 ngaPassportCid。留空保存会清除当前凭据。',
          secret: true,
        );
        if (value != null && mounted)
          await _apply(() => _radar.setNgaLogin(value));
      case 'import':
        await _apply(() async {
          final file = await FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: const ['json'],
            dialogTitle: '导入福利雷达数据',
          );
          if (file == null) return;
          const maxSize = 1024 * 1024;
          final size = await file.length();
          if (size != null && size > maxSize) {
            throw const FormatException('请选择 1 MB 以内的 JSON 文件');
          }
          final bytes = await file.readAsBytes();
          if (bytes.length > maxSize) {
            throw const FormatException('请选择 1 MB 以内的 JSON 文件');
          }
          await _radar.importItems(source, utf8.decode(bytes));
          _message('已导入到 $name');
        });
      case 'clear':
        await _apply(() => _radar.clearImport(source));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('福利雷达'),
      actions: [
        ListenableBuilder(
          listenable: _radar,
          builder: (context, _) => IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '立即更新',
            onPressed: _radar.refreshing || _radar.sources.isEmpty
                ? null
                : () => unawaited(_radar.refresh(force: true)),
          ),
        ),
      ],
    ),
    body: FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('无法加载福利雷达来源'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListenableBuilder(
          listenable: _radar,
          builder: (context, _) {
            final sources = _radar.sources;
            final total = sources.length;
            final enabled = _radar.enabledCount;
            final defaults = sources
                .where((source) => source.defaultEnabled)
                .length;
            final categories =
                sources.map((source) => source.category).toSet().toList()..sort(
                  (a, b) =>
                      radarCategoryLabel(a).compareTo(radarCategoryLabel(b)),
                );
            final query = _query.trim().toLowerCase();
            final filtered = sources
                .where(
                  (source) =>
                      (!_onlyEnabled || _radar.isEnabled(source)) &&
                      (_category == 'all' || source.category == _category) &&
                      (query.isEmpty ||
                          (source.name + ' ' + source.id)
                              .toLowerCase()
                              .contains(query)),
                )
                .toList();
            return Column(
              children: [
                if (_radar.refreshing)
                  const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '已启用 $enabled / $total · 默认 $defaults 个',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _apply(_radar.restoreDefaults),
                            child: const Text('恢复默认开关'),
                          ),
                        ],
                      ),
                      TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: '搜索来源',
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<String>(
                            value: _category,
                            items: [
                              const DropdownMenuItem(
                                value: 'all',
                                child: Text('全部分类'),
                              ),
                              for (final id in categories)
                                DropdownMenuItem(
                                  value: id,
                                  child: Text(radarCategoryLabel(id)),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => _category = value ?? 'all'),
                          ),
                          FilterChip(
                            label: const Text('只看已启用'),
                            selected: _onlyEnabled,
                            onSelected: (selected) =>
                                setState(() => _onlyEnabled = selected),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('没有符合筛选条件的来源'))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                          ),
                          itemBuilder: (context, index) {
                            final source = filtered[index];
                            return ListTile(
                              title: Text(source.name),
                              subtitle: Text(
                                radarCategoryLabel(source.category) +
                                    ' · ' +
                                    _radar.status(source),
                              ),
                              onTap: _saving ? null : () => _edit(source),
                              trailing: Switch.adaptive(
                                value: _radar.isEnabled(source),
                                onChanged: _saving
                                    ? null
                                    : (enabled) => _apply(
                                        () =>
                                            _radar.setEnabled(source, enabled),
                                      ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    ),
  );
}
