import 'package:flutter/material.dart';

/// Server-driven inbox. The caller supplies account-scoped fetch/read actions so
/// this page never owns credentials or notification delivery rules.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({
    super.key,
    required this.loadNotifications,
    required this.markRead,
    this.onAction,
  });

  final Future<List<dynamic>> Function() loadNotifications;
  final Future<void> Function(String id) markRead;
  final Future<void> Function(String action, String value)? onAction;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<dynamic> _items = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};
  final Set<String> _readIds = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  dynamic _value(dynamic item, String camel, [String? snake]) {
    if (item is Map) return item[camel] ?? (snake == null ? null : item[snake]);
    try {
      switch (camel) {
        case 'id':
          return item.id;
        case 'title':
          return item.title;
        case 'body':
          return item.body;
        case 'category':
          return item.category;
        case 'createdAt':
          return item.createdAt;
        case 'publishedAt':
          return item.publishedAt;
        case 'read':
          return item.isRead;
        case 'isRead':
          return item.isRead;
        case 'action':
          return item.action;
        case 'actionValue':
          return item.actionValue;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.loadNotifications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _markRead(String id) async {
    if (id.isEmpty || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.markRead(id);
      if (!mounted) return;
      setState(
        () => _items = _items.map((item) {
          final itemId = '${_value(item, 'id') ?? ''}';
          if (itemId != id) return item;
          if (item is Map) return {...item, 'read': true, 'isRead': true};
          return item;
        }).toList(),
      );
      _readIds.add(id);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('标记已读失败：$error')));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  bool _isRead(dynamic item) =>
      _readIds.contains('${_value(item, 'id') ?? ''}') ||
      _value(item, 'read') == true ||
      _value(item, 'isRead') == true ||
      _value(item, 'is_read') == true;

  String _timestamp(dynamic value) {
    if (value is DateTime)
      return value.toLocal().toString().replaceFirst(RegExp(r'\.\d+'), '');
    if (value is num && value > 0) {
      final millis = value > 100000000000
          ? value.toInt()
          : value.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(
        millis,
        isUtc: true,
      ).toLocal().toString().replaceFirst(RegExp(r'\.\d+'), '');
    }
    return value?.toString() ?? '';
  }

  String _categoryLabel(String category) => switch (category) {
    'activity' => '活动',
    'update' => '更新',
    'gray_test' => '灰度测试',
    'quota' => '额度',
    'general' => '通知',
    _ => category,
  };

  String _actionLabel(String action) => switch (action) {
    'models' => '查看模型',
    'quota' => '查看额度',
    'activity' => '查看活动',
    'updates' => '查看更新',
    _ => '查看',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('暂时无法加载通知', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _refresh, child: const Text('重试')),
                  ],
                ),
              ),
            )
          : _items.isEmpty
          ? const Center(child: Text('暂无通知'))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final id = '${_value(item, 'id') ?? ''}';
                  final read = _isRead(item);
                  final title = '${_value(item, 'title') ?? '通知'}';
                  final body = '${_value(item, 'body') ?? ''}';
                  final category = '${_value(item, 'category') ?? ''}';
                  final time = _timestamp(
                    _value(item, 'publishedAt', 'published_at') ??
                        _value(item, 'createdAt', 'created_at'),
                  );
                  final action = '${_value(item, 'action') ?? ''}';
                  final actionValue =
                      '${_value(item, 'actionValue', 'action_value') ?? ''}';
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: read ? null : () => _markRead(id),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (!read)
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                if (!read) const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    title,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: read
                                              ? FontWeight.w500
                                              : FontWeight.w700,
                                        ),
                                  ),
                                ),
                                if (category.isNotEmpty)
                                  Chip(
                                    label: Text(
                                      _categoryLabel(category),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                              ],
                            ),
                            if (body.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(body),
                              ),
                            if (time.isNotEmpty || action.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      time,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                  if (action.isNotEmpty &&
                                      action != 'none' &&
                                      widget.onAction != null)
                                    TextButton(
                                      onPressed: () async {
                                        await _markRead(id);
                                        await widget.onAction!(
                                          action,
                                          actionValue,
                                        );
                                      },
                                      child: Text(_actionLabel(action)),
                                    ),
                                ],
                              ),
                            ],
                            if (_busy.contains(id))
                              const LinearProgressIndicator(minHeight: 2),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
