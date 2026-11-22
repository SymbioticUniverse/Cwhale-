import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_auth_service.dart';
import 'app_theme.dart';
import 'chat_models.dart';
import 'deepseek_chat_import_page.dart';
import 'local_store.dart';

class OnboardingFlowPage extends StatefulWidget {
  const OnboardingFlowPage({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<OnboardingFlowPage> createState() => _OnboardingFlowPageState();
}

class _OnboardingFlowPageState extends State<OnboardingFlowPage> {
  final _store = LocalStore();
  final _pages = PageController();
  final _apiKey = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _code = TextEditingController();
  final _auth = AccountAuthService.instance;

  int _page = 0;
  bool _showApiKey = false;
  bool _verifying = false;
  bool _busy = false;
  bool _registered = false;
  bool _acceptedTerms = false;
  int _resendSeconds = 0;
  String? _challengeId;
  String? _signedInEmail;
  Timer? _resendTimer;

  static const _steps = <String>['欢迎', '导入对话', '配置 API', '可选账号', '开源致谢'];

  @override
  void dispose() {
    _resendTimer?.cancel();
    _pages.dispose();
    _apiKey.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _goTo(int index) async {
    if (_busy || index < 0 || index > 4) return;
    setState(() => _page = index);
    await _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _skip() => _goTo(_page + 1);

  Future<void> _saveApiKeyAndContinue() async {
    final value = _apiKey.text.trim();
    if (value.isNotEmpty) {
      final settings = await _store.loadSettings();
      final targetIndex = settings.apiProfiles.indexWhere(
        (profile) => profile.id == deepSeekDefaultProfileId,
      );
      final profiles = List<ApiProfile>.of(settings.apiProfiles);
      if (targetIndex >= 0) {
        profiles[targetIndex] = profiles[targetIndex].copyWith(apiKey: value);
      } else {
        profiles.add(
          const ApiProfile(
            id: deepSeekDefaultProfileId,
            name: 'DeepSeek',
            providerName: 'DeepSeek',
            baseUrl: deepSeekApiBaseUrl,
            model: deepSeekFlashModel,
            apiKey: '',
            supportsThinkingToggle: true,
          ).copyWith(apiKey: value),
        );
      }
      final active = profiles.firstWhere(
        (profile) => profile.id == settings.defaultApiProfileId,
        orElse: () => profiles.first,
      );
      await _store.saveSettings(
        settings.copyWith(
          apiProfiles: List.unmodifiable(profiles),
          baseUrl: active.baseUrl,
          model: active.model,
          apiKey: active.apiKey,
        ),
      );
    }
    if (mounted) await _goTo(3);
  }

  Future<void> _openImport() async {
    final settings = await _store.loadSettings();
    if (!mounted) return;
    final result = await Navigator.of(context).push<DeepSeekImportResult>(
      MaterialPageRoute(
        builder: (_) =>
            DeepSeekChatImportPage(apiProfileId: settings.defaultApiProfileId),
      ),
    );
    if (!mounted || result == null || result.threads.isEmpty) return;

    for (final thread in result.threads.reversed) {
      final messages = List<ChatMessage>.of(thread.messages);
      await _store.appendMessages(thread.id, startIndex: 0, messages: messages);
      thread
        ..messageCount = messages.length
        ..messageBaseIndex = 0
        ..messages.clear();
    }
    final existing = await _store.loadThreads();
    final importedIds = existing.map((thread) => thread.id).toSet();
    existing.insertAll(
      0,
      result.threads.where((thread) => !importedIds.contains(thread.id)),
    );
    await _store.saveThreads(existing);
    if (mounted) {
      _showMessage(
        '已导入 ${result.threads.length} 个对话${result.skippedCount > 0 ? '，跳过 ${result.skippedCount} 个无效对话' : ''}。',
      );
    }
  }

  bool _validRegistration() {
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      _showMessage('请输入有效的邮箱地址。');
      return false;
    }
    if (_password.text.length < 8) {
      _showMessage('密码至少需要 8 个字符。');
      return false;
    }
    if (_password.text != _confirmPassword.text) {
      _showMessage('两次输入的密码不一致。');
      return false;
    }
    return true;
  }

  Future<void> _register() async {
    if (!_auth.isConfigured) {
      _showMessage('账号服务尚未配置，你可以跳过登录并使用全部本地功能。');
      return;
    }
    if (!_validRegistration()) return;
    if (!_acceptedTerms) {
      _showMessage('请先阅读并同意服务条款与隐私政策。');
      return;
    }
    await _run(() async {
      final challenge = await _auth.register(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (challenge.id.isEmpty) {
        throw const AccountAuthException(
          'INVALID_RESPONSE',
          '账号服务没有返回验证码会话，请稍后重试。',
        );
      }
      _challengeId = challenge.id;
      _registered = true;
      _verifying = true;
      _code.clear();
      _startResendCooldown(challenge.retryAfterSeconds);
      _showMessage('验证码已发送到 ${_email.text.trim()}。');
    });
  }

  Future<void> _verifyAndLogin() async {
    if (_code.text.trim().length != 6) {
      _showMessage('请输入邮件中的 6 位验证码。');
      return;
    }
    final challengeId = _challengeId;
    if (challengeId == null || challengeId.isEmpty) return;
    await _run(() async {
      final user = await _auth.verifyEmail(
        challengeId: challengeId,
        code: _code.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _signedInEmail = user.email;
        _verifying = false;
      });
      _showMessage('邮箱验证成功，已自动登录。');
    });
  }

  Future<void> _resendCode() async {
    final challengeId = _challengeId;
    if (challengeId == null || _resendSeconds > 0) return;
    await _run(() async {
      await _auth.resendEmailCode(challengeId);
      _startResendCooldown(60);
      _showMessage('验证码已重新发送。');
    });
  }

  void _startResendCooldown(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = seconds.clamp(0, 120));
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _resendSeconds <= 1) {
        timer.cancel();
        if (mounted) setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await action();
    } on AccountAuthException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('操作失败，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete() async {
    final settings = await _store.loadSettings();
    await _store.markOnboardingCompleted();
    await _store.saveSettings(
      settings.copyWith(useDarkTheme: CwhaleTheme.darkMode.value),
    );
    widget.onCompleted();
  }

  void _showMessage(String message) {
    if (!mounted) return;
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
    final names = _steps;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 20, 0),
              child: Row(
                children: [
                  Text(
                    'Cwhale',
                    style: TextStyle(
                      color: ink,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: CwhaleTheme.darkMode.value ? '浅色模式' : '深夜模式',
                    onPressed: () => CwhaleTheme.darkMode.value =
                        !CwhaleTheme.darkMode.value,
                    icon: Icon(
                      CwhaleTheme.darkMode.value
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                      color: accent,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 9, 24, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        names[_page],
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      const Spacer(),
                      Text(
                        '${_page + 1} / 5',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (_page + 1) / 5,
                      minHeight: 2,
                      backgroundColor: line,
                      color: accent,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildWelcome(ink, muted, accent, line),
                  _buildImportPage(ink, muted, accent),
                  _buildApiPage(ink, muted, accent),
                  _buildAccountPage(ink, muted, accent),
                  _buildCreditsPage(ink, muted, accent, line),
                ],
              ),
            ),
            _buildFooter(ink, muted, accent, line, theme),
          ],
        ),
      ),
    );
  }

  Widget _pageBody({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.fromLTRB(28, 26, 28, 18),
  }) => SingleChildScrollView(
    padding: padding,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 300),
      child: child,
    ),
  );

  Widget _ornament(Color accent) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(width: 30, height: 1, color: accent.withValues(alpha: .55)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Icon(Icons.auto_awesome_rounded, size: 13, color: accent),
        ),
        Container(width: 30, height: 1, color: accent.withValues(alpha: .55)),
      ],
    ),
  );

  Widget _sectionHeading({
    required String eyebrow,
    required String title,
    required String intro,
    required Color ink,
    required Color muted,
    required Color accent,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow.toUpperCase(),
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.25,
        ),
      ),
      const SizedBox(height: 9),
      Text(
        title,
        style: TextStyle(
          color: ink,
          fontSize: 27,
          height: 1.18,
          fontWeight: FontWeight.w800,
          letterSpacing: -.55,
        ),
      ),
      _ornament(accent),
      Text(intro, style: TextStyle(color: muted, fontSize: 14, height: 1.65)),
    ],
  );

  Widget _buildWelcome(Color ink, Color muted, Color accent, Color line) =>
      _pageBody(
        padding: const EdgeInsets.fromLTRB(28, 34, 28, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              'Cwhale',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 43,
                height: 1.05,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.9,
                foreground: Paint()
                  ..shader = const LinearGradient(
                    colors: [Color(0xff5375ed), Color(0xff20b9c7)],
                  ).createShader(const Rect.fromLTWH(0, 0, 250, 60)),
              ),
            ),
            _ornament(accent),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  color: muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .2,
                ),
                children: [
                  const TextSpan(text: '本地优先 · '),
                  TextSpan(
                    text: '自由连接',
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const TextSpan(text: ' · 长聊延续'),
                ],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ...const [
              ('01', '无需登录 · 隐私安全', '聊天、记忆与文件默认保存在本机'),
              ('02', 'DeepSeek 开箱即用', '也可以连接你自己的模型服务'),
              ('03', '极简上下文 · 快速响应', '按需带入相关内容，减少无关输入'),
              ('04', '适配长篇剧情模拟', '为故事与连续互动设计'),
              ('05', '独特记忆管理 · 对话继续延续', '重要内容由你管理，长聊接续更自然'),
            ].map(
              (item) => Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: line)),
                ),
                child: Column(
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${item.$1}  ',
                            style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                          TextSpan(
                            text: item.$2,
                            style: TextStyle(
                              color: ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.$3,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildImportPage(Color ink, Color muted, Color accent) => _pageBody(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          eyebrow: '第二步 · 可选',
          title: '导入 DeepSeek 对话',
          intro: '把已有对话带到 Cwhale。导入会新增本机记录，不会修改原来的聊天。',
          ink: ink,
          muted: muted,
          accent: accent,
        ),
        const SizedBox(height: 22),
        _featureLine(
          icon: Icons.folder_zip_outlined,
          title: '选择 DeepSeek 导出 ZIP',
          detail: '也可以使用 ZIP 下载链接，导入流程与应用内保持一致。',
          ink: ink,
          muted: muted,
          accent: accent,
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _busy ? null : _openImport,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('打开导入页面'),
        ),
        const SizedBox(height: 16),
        Text(
          '也可以暂时跳过，以后从侧边栏导入。',
          style: TextStyle(color: muted, fontSize: 12, height: 1.55),
        ),
      ],
    ),
  );

  Widget _buildApiPage(Color ink, Color muted, Color accent) => _pageBody(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          eyebrow: '第三步 · 可选',
          title: '配置 DeepSeek API',
          intro: '如果你已经有 API Key，可以现在添加；没有的话之后也能在设置里配置。',
          ink: ink,
          muted: muted,
          accent: accent,
        ),
        const SizedBox(height: 23),
        _fieldLabel('API Key', ink),
        TextField(
          controller: _apiKey,
          obscureText: !_showApiKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: '粘贴你的 API Key',
            suffixIcon: IconButton(
              tooltip: _showApiKey ? '隐藏密钥' : '显示密钥',
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
              icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _notice(
          icon: Icons.lock_outline_rounded,
          title: '加密保存在本机',
          body: '请妥善保存 API Key。模型请求会由手机直接发送到你配置的服务商。',
          ink: ink,
          muted: muted,
          accent: accent,
        ),
      ],
    ),
  );

  Widget _buildAccountPage(Color ink, Color muted, Color accent) => _pageBody(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          eyebrow: '第四步 · 可选',
          title: '注册并登录账号',
          intro: '完成邮箱验证后会自动登录，可在免费额度开放后领取额度。不登录也能使用全部功能。',
          ink: ink,
          muted: muted,
          accent: accent,
        ),
        const SizedBox(height: 17),
        if (_signedInEmail != null) ...[
          _notice(
            icon: Icons.verified_outlined,
            title: '已注册并登录',
            body: _signedInEmail!,
            ink: ink,
            muted: muted,
            accent: accent,
          ),
          const SizedBox(height: 12),
        ] else ...[
          _fieldLabel('账号邮箱', ink),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(hintText: 'name@example.com'),
          ),
          if (!_verifying) ...[
            _fieldLabel('密码', ink),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(hintText: '至少 8 个字符'),
            ),
            _fieldLabel('确认密码', ink),
            TextField(
              controller: _confirmPassword,
              obscureText: true,
              decoration: const InputDecoration(hintText: '再次输入密码'),
            ),
            CheckboxListTile.adaptive(
              value: _acceptedTerms,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: accent,
              title: Text(
                '我已阅读并同意服务条款与隐私政策',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              onChanged: (value) =>
                  setState(() => _acceptedTerms = value ?? false),
            ),
          ] else ...[
            _fieldLabel('邮箱验证码', ink),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(hintText: '输入 6 位验证码'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy || _resendSeconds > 0 ? null : _resendCode,
                  child: Text(
                    _resendSeconds > 0 ? '${_resendSeconds}s' : '重发验证码',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _verifying = false;
                        _registered = false;
                        _challengeId = null;
                      }),
                child: const Text('返回修改注册信息'),
              ),
            ),
          ],
          const SizedBox(height: 14),
          _notice(
            icon: Icons.shield_outlined,
            title: '登录用途与隐私',
            body: '账号只用于管理登录状态和未来额度发放，不读取你的本机聊天、记忆或文件。使用免费额度时，你提交的请求内容会发送给对应模型服务商。',
            ink: ink,
            muted: muted,
            accent: accent,
          ),
          if (!_auth.isConfigured) ...[
            const SizedBox(height: 10),
            Text(
              '账号服务尚未开放；你可以跳过，稍后再注册。',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ],
    ),
  );

  Widget _buildCreditsPage(Color ink, Color muted, Color accent, Color line) =>
      _pageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeading(
              eyebrow: '第五步',
              title: '开源致谢',
              intro: 'Cwhale 建立在开源社区的成果之上。感谢项目作者、维护者与所有贡献者。',
              ink: ink,
              muted: muted,
              accent: accent,
            ),
            const SizedBox(height: 20),
            ...const [
              ('Flutter', 'Google / Flutter Authors', 'BSD-3-Clause'),
              ('archive', 'Brendan Duncan', 'MIT'),
              ('file_picker', 'Miguel Ruivo 等', 'MIT'),
              ('flutter_foreground_task', 'Dev-hwang', 'MIT'),
              ('flutter_secure_storage', 'German Saprykin 等', 'BSD-3-Clause'),
              ('html、http、file', 'Dart Authors', 'BSD-3-Clause'),
              ('open_xml', 'Rody Davis', 'Apache-2.0'),
              ('path_provider', 'Flutter Authors', 'BSD-3-Clause'),
              ('trafilatura', 'Kamran X', 'Apache-2.0'),
              ('humanizer', 'Blader', 'MIT'),
            ].map(
              (item) => Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: line)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        item.$1,
                        style: TextStyle(
                          color: ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        item.$2,
                        style: TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      item.$3,
                      style: TextStyle(
                        color: accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            _notice(
              icon: Icons.code_rounded,
              title: 'Cwhale · MIT License',
              body: 'https://github.com/SymbioticUniverse/Cwhale-',
              ink: ink,
              muted: muted,
              accent: accent,
            ),
            const SizedBox(height: 10),
            Text(
              '感谢所有开源项目作者与社区维护者。',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      );

  Widget _featureLine({
    required IconData icon,
    required String title,
    required String detail,
    required Color ink,
    required Color muted,
    required Color accent,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: accent, size: 23),
      const SizedBox(width: 13),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(detail, style: TextStyle(color: muted, height: 1.55)),
          ],
        ),
      ),
    ],
  );

  Widget _fieldLabel(String label, Color ink) => Padding(
    padding: const EdgeInsets.only(top: 15, bottom: 7),
    child: Text(
      label,
      style: TextStyle(color: ink, fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );

  Widget _notice({
    required IconData icon,
    required String title,
    required String body,
    required Color ink,
    required Color muted,
    required Color accent,
  }) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: CwhaleTheme.raisedSurface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: CwhaleTheme.line),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: accent, size: 21),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                body,
                style: TextStyle(color: muted, fontSize: 12, height: 1.55),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildFooter(
    Color ink,
    Color muted,
    Color accent,
    Color line,
    ThemeData theme,
  ) {
    final isWelcome = _page == 0;
    final isLast = _page == 4;
    final accountComplete = _page == 3 && _signedInEmail != null;
    final canRegister = _page == 3 && !_registered && !accountComplete;
    final primaryLabel = switch (_page) {
      0 => '下一页',
      1 => '下一页',
      2 => '保存并继续',
      3 =>
        accountComplete
            ? '下一页'
            : _verifying
            ? '验证并登录'
            : '注册并登录',
      _ => '开始进入 Cwhale 世界',
    };
    final VoidCallback action = switch (_page) {
      0 || 1 => _skip,
      2 => _saveApiKeyAndContinue,
      3 =>
        accountComplete
            ? _skip
            : _verifying
            ? _verifyAndLogin
            : _register,
      _ => _complete,
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: line.withValues(alpha: .8))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isWelcome && !isLast && !accountComplete)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _skip,
                      child: const Text('暂时跳过'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : canRegister && !_auth.isConfigured
                          ? _skip
                          : action,
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              canRegister && !_auth.isConfigured
                                  ? '继续'
                                  : primaryLabel,
                            ),
                    ),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : action,
                child: _busy && _page == 3
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(primaryLabel),
              ),
            ),
          const SizedBox(height: 7),
          Text(
            switch (_page) {
              0 => '聊天、记忆与文件留在本机。',
              1 => '导入不会影响原有对话。',
              2 => 'API Key 通过系统安全存储加密保存。',
              3 => '不登录也能使用 Cwhale 的全部本地功能。',
              _ => '你的模型，你的对话，留在本机。',
            },
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
