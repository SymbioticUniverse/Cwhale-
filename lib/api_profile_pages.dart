import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'account_auth_service.dart';
import 'chat_models.dart';
import 'kilo_gateway.dart';

Color get _profilePaper => CwhaleTheme.background;
Color get _profileSurface => CwhaleTheme.surface;
Color get _profileInk => CwhaleTheme.ink;
Color get _profileMuted => CwhaleTheme.muted;
Color get _profileAccent => CwhaleTheme.accent;
Color get _profileLine => CwhaleTheme.line;

class ApiProfilesResult {
  const ApiProfilesResult({
    required this.profiles,
    required this.defaultProfileId,
  });

  final List<ApiProfile> profiles;
  final String defaultProfileId;
}

class ApiProfilesPage extends StatefulWidget {
  const ApiProfilesPage({
    required this.profiles,
    required this.defaultProfileId,
    required this.usageCounts,
    this.onRequireKiloLogin,
    super.key,
  });

  final List<ApiProfile> profiles;
  final String defaultProfileId;
  final Map<String, int> usageCounts;
  final Future<bool> Function()? onRequireKiloLogin;

  @override
  State<ApiProfilesPage> createState() => _ApiProfilesPageState();
}

class _ApiProfilesPageState extends State<ApiProfilesPage> {
  late List<ApiProfile> _profiles = List.of(widget.profiles);
  late String _defaultProfileId = widget.defaultProfileId;
  bool _allowPop = false;
  bool _enablingKilo = false;

  bool get _hasKiloProfile => _profiles.any((profile) => profile.isBuiltInKilo);

  Future<void> _enableKilo() async {
    if (_enablingKilo || _hasKiloProfile) return;
    final auth = AccountAuthService.instance;
    if (!auth.isConfigured) {
      _showMessage('Cwhale 登录服务尚未配置；发布者需在 APK 构建时配置账号服务地址。');
      return;
    }
    if (auth.currentUser == null) {
      final callback = widget.onRequireKiloLogin;
      if (callback == null || await callback() != true || !mounted) return;
    }
    setState(() => _enablingKilo = true);
    try {
      final available = await KiloGateway.refreshCatalog(force: true);
      if (!mounted) return;
      if (!available) {
        _showMessage('Cwhale 免费模型当前暂不可用，请稍后重试。');
        return;
      }
      final profile = kiloAutoApiProfile.copyWith(
        contextWindowTokens: KiloGateway.contextWindowTokens,
      );
      setState(() {
        _profiles.add(profile);
        _defaultProfileId = profile.id;
      });
      _showMessage('已启用 Cwhale 免费模型；此对话可直接切换使用。');
    } catch (error) {
      if (mounted) _showMessage('启用 Cwhale 免费模型失败：${error.toString()}');
    } finally {
      if (mounted) setState(() => _enablingKilo = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  ApiProfile _fallbackFor(String removedId) {
    for (final profile in _profiles) {
      if (profile.id == _defaultProfileId && profile.id != removedId) {
        return profile;
      }
    }
    return _profiles.firstWhere(
      (profile) =>
          profile.id == deepSeekDefaultProfileId && profile.id != removedId,
      orElse: () => _profiles.firstWhere((profile) => profile.id != removedId),
    );
  }

  Future<void> _editProfile([ApiProfile? profile]) async {
    final result = await Navigator.of(context).push<ApiProfile>(
      MaterialPageRoute<ApiProfile>(
        builder: (context) => ApiProfileEditorPage(profile: profile),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final index = _profiles.indexWhere((item) => item.id == result.id);
      if (index < 0) {
        _profiles.add(result);
      } else {
        _profiles[index] = result;
      }
    });
  }

  Future<void> _deleteProfile(ApiProfile profile) async {
    if (profile.id == deepSeekDefaultProfileId) return;
    final affected = widget.usageCounts[profile.id] ?? 0;
    final fallback = _fallbackFor(profile.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除 API 配置？'),
        content: Text(
          '“${profile.displayName}”将从本机删除。$affected 个使用此配置的对话会切换到“${fallback.displayName} · ${fallback.displayModelName}”；此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除并切换对话'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _profiles.removeWhere((item) => item.id == profile.id);
      if (_defaultProfileId == profile.id) {
        _defaultProfileId = fallback.id;
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('受影响的对话将在保存后切换到 ${fallback.name}。')),
      );
  }

  void _finish() {
    if (_allowPop) return;
    final result = ApiProfilesResult(
      profiles: List.unmodifiable(_profiles),
      defaultProfileId: _defaultProfileId,
    );
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope<ApiProfilesResult>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _finish();
    },
    child: Scaffold(
      backgroundColor: _profilePaper,
      appBar: AppBar(
        title: const Text('API 配置档案'),
        actions: [TextButton(onPressed: _finish, child: const Text('完成'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text(
              '选择新对话默认配置。每个对话也可以单独切换；档案通过 OpenAI 兼容 Chat Completions 协议直连服务商。',
              style: TextStyle(color: _profileMuted, height: 1.45),
            ),
          ),
          if (!_hasKiloProfile)
            Card(
              color: _profileSurface,
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: _profileLine),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bolt_rounded, color: _profileAccent),
                        const SizedBox(width: 9),
                        Text(
                          'Cwhale 免费模型',
                          style: TextStyle(
                            color: _profileInk,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '无需填写 API Key · 自动路由 · 首次启用需登录 Cwhale。',
                      style: TextStyle(color: _profileMuted, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _enablingKilo ? null : _enableKilo,
                        icon: _enablingKilo
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_rounded),
                        label: Text(
                          _enablingKilo ? '正在验证免费目录…' : '启用 Cwhale 免费模型',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (final profile in _profiles)
            Card(
              color: _profileSurface,
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: _profileLine),
              ),
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: profile.id,
                    groupValue: _defaultProfileId,
                    activeColor: _profileAccent,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _defaultProfileId = value);
                      }
                    },
                    title: Text(
                      profile.displayName,
                      style: TextStyle(
                        color: _profileInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${profile.displayProviderName} · ${profile.displayModelName}\n'
                      '${formatContextWindow(profile.contextWindowTokens)} · '
                      '自动压缩${profile.autoCompressContext ? ' ${profile.autoCompressAtPercent}%' : '关闭'}',
                      style: TextStyle(
                        color: _profileMuted,
                        height: 1.5,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Divider(height: 1, color: _profileLine),
                  Row(
                    children: [
                      const Spacer(),
                      if (!profile.isBuiltInKilo)
                        TextButton.icon(
                          onPressed: () => _editProfile(profile),
                          icon: const Icon(Icons.edit_outlined, size: 17),
                          label: const Text('编辑'),
                        ),
                      if (profile.id != deepSeekDefaultProfileId)
                        TextButton.icon(
                          onPressed: () => _deleteProfile(profile),
                          icon: const Icon(Icons.delete_outline, size: 17),
                          label: const Text('删除'),
                        ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 7),
          OutlinedButton.icon(
            onPressed: () => _editProfile(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('新增 API 配置'),
          ),
        ],
      ),
    ),
  );
}

class ApiProfileEditorPage extends StatefulWidget {
  const ApiProfileEditorPage({required this.profile, super.key});

  final ApiProfile? profile;

  @override
  State<ApiProfileEditorPage> createState() => _ApiProfileEditorPageState();
}

class _ApiProfileEditorPageState extends State<ApiProfileEditorPage> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _provider = TextEditingController(
    text: widget.profile?.providerName ?? '',
  );
  late final _baseUrl = TextEditingController(
    text: widget.profile?.baseUrl ?? '',
  );
  late final _model = TextEditingController(text: widget.profile?.model ?? '');
  late final _apiKey = TextEditingController(
    text: widget.profile?.apiKey ?? '',
  );
  late int _contextTokens = widget.profile?.contextWindowTokens ?? 1000000;
  late bool _autoCompress = widget.profile?.autoCompressContext ?? true;
  late int _compressionPercent = widget.profile?.autoCompressAtPercent ?? 80;
  late bool _supportsThinking = widget.profile?.supportsThinkingToggle ?? false;
  late bool _supportsThinkingLevels =
      widget.profile?.supportsThinkingLevels ?? false;
  late bool _supportsImages = widget.profile?.supportsImages ?? false;
  late bool _supportsFiles = widget.profile?.supportsFiles ?? false;
  bool _showKey = false;

  @override
  void dispose() {
    _name.dispose();
    _provider.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _pasteApiKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final value = data?.text?.trim() ?? '';
    if (value.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('剪贴板里没有可粘贴的 API Key。')));
      return;
    }
    _apiKey.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _save() {
    final baseUrl = _baseUrl.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(baseUrl);
    final host = parsed?.host.toLowerCase() ?? '';
    final isLoopback = const {'localhost', '127.0.0.1', '::1'}.contains(host);
    final allowedTransport =
        parsed?.scheme == 'https' || (parsed?.scheme == 'http' && isLoopback);
    if (parsed == null ||
        !parsed.hasAuthority ||
        host.isEmpty ||
        !allowedTransport ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      _showError('Base URL 请填写 HTTPS 地址；本机 localhost 可使用 HTTP。');
      return;
    }
    if (_name.text.trim().isEmpty || _provider.text.trim().isEmpty) {
      _showError('请填写显示名称和服务商名称。');
      return;
    }
    if (_model.text.trim().isEmpty) {
      _showError('请填写模型名称。');
      return;
    }
    final profile = ApiProfile(
      id: widget.profile?.id ?? newLocalId(),
      name: _name.text.trim(),
      providerName: _provider.text.trim(),
      baseUrl: baseUrl,
      model: _model.text.trim(),
      apiKey: _apiKey.text.trim(),
      contextWindowTokens: _contextTokens,
      autoCompressContext: _autoCompress,
      autoCompressAtPercent: _compressionPercent,
      supportsThinkingToggle: _supportsThinking,
      supportsThinkingLevels: _supportsThinking && _supportsThinkingLevels,
      supportsImages: _supportsImages,
      supportsFiles: _supportsFiles,
    );
    Navigator.pop(context, profile);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    Widget textField(
      String label,
      TextEditingController controller,
      String hint,
      IconData icon, {
      TextInputType keyboardType = TextInputType.text,
      bool obscure = false,
      bool readOnly = false,
      Widget? suffix,
    }) => Padding(
      padding: const EdgeInsets.fromLTRB(15, 11, 15, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: _profileMuted, fontSize: 12)),
          const SizedBox(height: 7),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            obscureText: obscure,
            readOnly: readOnly,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(icon, size: 19),
              suffixIcon: suffix,
            ),
          ),
        ],
      ),
    );

    Widget group(List<Widget> children) => Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: _profileSurface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: _profileLine),
            children[i],
          ],
        ],
      ),
    );

    return Scaffold(
      backgroundColor: _profilePaper,
      appBar: AppBar(
        title: Text(widget.profile == null ? '新增 API 配置' : '编辑 API 配置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        children: [
          group([
            textField(
              '显示名称',
              _name,
              '例如：工作模型',
              Icons.label_outline,
              readOnly: widget.profile?.id == deepSeekDefaultProfileId,
            ),
            textField(
              '服务商名称',
              _provider,
              '例如：DeepSeek',
              Icons.business_outlined,
              readOnly: widget.profile?.id == deepSeekDefaultProfileId,
            ),
            textField(
              'Base URL',
              _baseUrl,
              'https://api.deepseek.com',
              Icons.link_rounded,
              keyboardType: TextInputType.url,
              readOnly: widget.profile?.id == deepSeekDefaultProfileId,
            ),
            textField('模型名称', _model, 'deepseek-flash', Icons.memory_rounded),
            textField(
              'API Key',
              _apiKey,
              '粘贴服务商 API Key',
              Icons.key_rounded,
              obscure: !_showKey,
              suffix: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: _pasteApiKey, child: const Text('粘贴')),
                  IconButton(
                    tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                    onPressed: () => setState(() => _showKey = !_showKey),
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ),
          ]),
          group([
            ListTile(
              leading: Icon(Icons.data_usage_rounded, color: _profileAccent),
              title: const Text('上下文窗口'),
              subtitle: const Text('按本档案单独计算占比和压缩'),
              trailing: DropdownButton<int>(
                value: _contextTokens,
                items: contextWindowChoices
                    .map(
                      (tokens) => DropdownMenuItem(
                        value: tokens,
                        child: Text(formatContextWindow(tokens)),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _contextTokens = value);
                  }
                },
              ),
            ),
            SwitchListTile.adaptive(
              value: _autoCompress,
              onChanged: (value) => setState(() => _autoCompress = value),
              activeThumbColor: _profileAccent,
              secondary: Icon(Icons.compress_rounded, color: _profileAccent),
              title: const Text('自动 AI 压缩'),
              subtitle: const Text('达到阈值时请求当前档案的模型压缩较早对话'),
            ),
            ListTile(
              leading: Icon(Icons.tune_rounded, color: _profileAccent),
              title: const Text('压缩阈值'),
              trailing: DropdownButton<int>(
                value: _compressionPercent,
                items: const [60, 70, 80, 90]
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('$value%'),
                      ),
                    )
                    .toList(),
                onChanged: _autoCompress
                    ? (value) {
                        if (value != null) {
                          setState(() => _compressionPercent = value);
                        }
                      }
                    : null,
              ),
            ),
          ]),
          group([
            SwitchListTile.adaptive(
              value: _supportsThinking,
              onChanged: (value) => setState(() {
                _supportsThinking = value;
                if (!value) _supportsThinkingLevels = false;
              }),
              activeThumbColor: _profileAccent,
              secondary: Icon(
                Icons.psychology_alt_outlined,
                color: _profileAccent,
              ),
              title: const Text('支持深度思考开关'),
              subtitle: const Text('只按此档案中明确配置的能力显示'),
            ),
            if (_supportsThinking)
              SwitchListTile.adaptive(
                value: _supportsThinkingLevels,
                onChanged: (value) =>
                    setState(() => _supportsThinkingLevels = value),
                activeThumbColor: _profileAccent,
                secondary: Icon(Icons.tune_rounded, color: _profileAccent),
                title: const Text('支持思考档位'),
                subtitle: const Text('开启后可在对话里选择默认、低、中、高'),
              ),
            SwitchListTile.adaptive(
              value: _supportsImages,
              onChanged: (value) => setState(() => _supportsImages = value),
              activeThumbColor: _profileAccent,
              secondary: Icon(Icons.image_outlined, color: _profileAccent),
              title: const Text('支持图片输入'),
            ),
            SwitchListTile.adaptive(
              value: _supportsFiles,
              onChanged: (value) => setState(() => _supportsFiles = value),
              activeThumbColor: _profileAccent,
              secondary: Icon(Icons.attach_file_rounded, color: _profileAccent),
              title: const Text('支持文件输入'),
            ),
          ]),
          Padding(
            padding: EdgeInsets.fromLTRB(5, 0, 5, 12),
            child: Text(
              '使用 OpenAI 兼容 Chat Completions 协议，手机通过 HTTPS 直接连接此地址。API Key 加密保存在本机安全存储中。',
              style: TextStyle(
                color: _profileMuted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
          SizedBox(
            height: 52,
            child: FilledButton(onPressed: _save, child: const Text('保存档案')),
          ),
        ],
      ),
    );
  }
}
