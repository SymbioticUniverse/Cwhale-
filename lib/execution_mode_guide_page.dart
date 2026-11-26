import 'package:flutter/material.dart';

import 'account_auth_service.dart';
import 'app_theme.dart';
import 'chat_models.dart';
import 'local_store.dart';

/// One-time guide shown after the user's first successful Cwhale login.
/// The selection changes the default for new conversations only.
class ExecutionModeGuidePage extends StatefulWidget {
  const ExecutionModeGuidePage({super.key});

  @override
  State<ExecutionModeGuidePage> createState() => _ExecutionModeGuidePageState();
}

class _ExecutionModeGuidePageState extends State<ExecutionModeGuidePage> {
  final _store = LocalStore();
  String _selectedMode = 'direct';
  bool _serverAvailable = false;
  bool _acknowledgedServerMode = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _store.loadSettings();
      final auth = AccountAuthService.instance;
      if (!mounted) return;
      setState(() {
        _selectedMode = settings.defaultExecutionMode == 'server'
            ? 'server'
            : 'direct';
        _serverAvailable =
            auth.isConfigured &&
            auth.isGenerationApiConfigured &&
            auth.currentUser != null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveAndContinue() async {
    if (_saving || _loading) return;
    if (_selectedMode == 'server' && !_serverAvailable) {
      _showMessage('服务器代管暂不可用，请先使用本机直连。');
      return;
    }
    if (_selectedMode == 'server' && !_acknowledgedServerMode) {
      _showMessage('请先确认服务器代管的数据传输说明。');
      return;
    }

    setState(() => _saving = true);
    try {
      final settings = await _store.loadSettings();
      await _store.saveSettings(
        settings.copyWith(defaultExecutionMode: _selectedMode),
      );
      try {
        await _store.markExecutionModeGuideCompleted();
      } catch (_) {
        // Keep the saved choice even if the one-time-guide marker cannot be
        // written; the screen can be skipped again without losing settings.
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) _showMessage('保存失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = CwhaleTheme.ink;
    final muted = CwhaleTheme.muted;
    final accent = CwhaleTheme.accent;
    final line = CwhaleTheme.line;
    final surface = CwhaleTheme.surface;
    final raised = CwhaleTheme.raisedSurface;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(false),
                    icon: Icon(Icons.arrow_back_rounded, color: ink),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Cwhale',
                    style: TextStyle(
                      color: ink,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.5,
                    ),
                  ),
                  const Spacer(),
                  Text('连接方式', style: TextStyle(color: muted, fontSize: 13)),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: accent))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_rounded,
                                    color: accent,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '账号已连接',
                                    style: TextStyle(
                                      color: accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              Icons.swap_horiz_rounded,
                              color: accent,
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 22),
                          Text(
                            '选择对话运行方式',
                            style: TextStyle(
                              color: ink,
                              fontSize: 26,
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            '这是新对话的默认方式。每个窗口也能单独切换，已经开始的对话不会受影响。',
                            style: TextStyle(
                              color: muted,
                              fontSize: 14,
                              height: 1.55,
                            ),
                          ),
                          const SizedBox(height: 24),
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: _modeCard(
                                    mode: 'direct',
                                    icon: Icons.phone_android_rounded,
                                    title: '本机直连',
                                    points: const [
                                      '手机直接连接模型服务商',
                                      '消息不经过 Cwhale 服务器',
                                      '切后台或熄屏时回复可能中断',
                                    ],
                                    ink: ink,
                                    muted: muted,
                                    accent: accent,
                                    line: line,
                                    surface: surface,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _modeCard(
                                    mode: 'server',
                                    icon: Icons.cloud_queue_rounded,
                                    title: '服务器代管',
                                    points: const [
                                      '切后台或熄屏后仍可等待回复',
                                      '适合长回复和切换应用',
                                      '请求由 Cwhale 服务器转发',
                                      '手机工具需回到应用后继续',
                                    ],
                                    ink: ink,
                                    muted: muted,
                                    accent: accent,
                                    line: line,
                                    surface: surface,
                                    enabled: _serverAvailable,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_selectedMode == 'server') ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(15),
                              decoration: BoxDecoration(
                                color: raised,
                                borderRadius: BorderRadius.circular(17),
                                border: Border.all(color: line),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.shield_outlined,
                                        size: 19,
                                        color: accent,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '服务器代管的数据说明',
                                        style: TextStyle(
                                          color: ink,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '当前窗口的消息、必要上下文和 API Key 会通过 HTTPS 发到 Cwhale 服务器，再转发给你配置的模型服务商。任务期间加密暂存；请求和密钥在任务结束后删除，回复事件最长保留 7 天供断线续接。Cwhale 免费模型始终本机直连。',
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  CheckboxListTile.adaptive(
                                    value: _acknowledgedServerMode,
                                    contentPadding: EdgeInsets.zero,
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    activeColor: accent,
                                    title: Text(
                                      '我了解并同意以上数据传输方式',
                                      style: TextStyle(
                                        color: ink,
                                        fontSize: 13,
                                      ),
                                    ),
                                    onChanged: (value) => setState(
                                      () => _acknowledgedServerMode =
                                          value ?? false,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Text(
                            '之后可在设置中修改新对话默认方式；免费模型仍使用本机直连。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                border: Border(top: BorderSide(color: line)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton(
                      onPressed: _loading || _saving
                          ? null
                          : _selectedMode == 'server' &&
                                (!_serverAvailable || !_acknowledgedServerMode)
                          ? null
                          : _saveAndContinue,
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 19,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _selectedMode == 'server'
                                  ? '同意并使用服务器代管'
                                  : '使用本机直连',
                            ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '此项只影响新对话，不会修改已有窗口',
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeCard({
    required String mode,
    required IconData icon,
    required String title,
    required List<String> points,
    required Color ink,
    required Color muted,
    required Color accent,
    required Color line,
    required Color surface,
    bool enabled = true,
  }) {
    final selected = _selectedMode == mode;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: !enabled || _saving
            ? null
            : () => setState(() => _selectedMode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: .07) : surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? accent : line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white.withValues(alpha: .78)
                          : accent.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      color: enabled ? accent : muted,
                      size: 20,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected ? accent : muted,
                    size: 19,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? ink : muted,
                  fontSize: 14,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 9),
              _pointGroup(
                label: '运行特点',
                points: points,
                color: accent,
                textColor: enabled ? muted : muted.withValues(alpha: .7),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pointGroup({
    required String label,
    required List<String> points,
    required Color color,
    required Color textColor,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      for (final point in points)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  point,
                  style: TextStyle(color: textColor, fontSize: 11, height: 1.3),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
