import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'account_auth_service.dart';

Color get _authInk => CwhaleTheme.ink;
Color get _authMuted => CwhaleTheme.muted;
Color get _authBlue => CwhaleTheme.accent;
Color get _authSurface => CwhaleTheme.surface;
Color get _authLine => CwhaleTheme.line;

enum _AccountFlow {
  login,
  register,
  verifyEmail,
  forgotPassword,
  resetPassword,
  account,
}

class AccountAuthPage extends StatefulWidget {
  const AccountAuthPage({this.returnOnSuccess = false, super.key});

  final bool returnOnSuccess;

  @override
  State<AccountAuthPage> createState() => _AccountAuthPageState();
}

class _AccountAuthPageState extends State<AccountAuthPage> {
  final _service = AccountAuthService.instance;
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _verificationCode = TextEditingController();
  Timer? _resendTimer;
  _AccountFlow _flow = _AccountFlow.login;
  AccountUser? _user;
  String? _challengeId;
  String _challengeEmail = '';
  int _resendSeconds = 0;
  bool _busy = false;
  bool _passwordVisible = false;
  bool _acceptedTerms = false;
  bool _verificationForSignup = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _verificationCode.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    if (!_service.isConfigured) return;
    try {
      final user = await _service.restoreSession();
      if (mounted && user != null) {
        setState(() {
          _user = user;
          _flow = _AccountFlow.account;
        });
        if (widget.returnOnSuccess) _returnAfterAuth();
      }
    } on AccountAuthException catch (error) {
      if (mounted) _showMessage(error.message);
    }
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
      if (mounted) _showMessage('操作失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    if (!_validate()) return;
    await _run(() async {
      try {
        final user = await _service.login(
          email: _email.text,
          password: _password.text,
        );
        if (!mounted) return;
        setState(() {
          _user = user;
          _flow = _AccountFlow.account;
        });
      } on AccountAuthException catch (error) {
        if (error.code == 'EMAIL_NOT_VERIFIED' &&
            error.challengeId?.isNotEmpty == true) {
          _challengeId = error.challengeId;
          _challengeEmail = _email.text.trim();
          _verificationForSignup = false;
          _verificationCode.clear();
          setState(() => _flow = _AccountFlow.verifyEmail);
          _startResendCooldown(60);
          return;
        }
        rethrow;
      }
    });
    if (_service.currentUser != null && widget.returnOnSuccess) {
      _returnAfterAuth();
    }
  }

  Future<void> _register() async {
    if (!_validate()) return;
    if (!_acceptedTerms) {
      _showMessage('请先阅读并同意服务条款和隐私政策。');
      return;
    }
    await _run(() async {
      final challenge = await _service.register(
        email: _email.text,
        password: _password.text,
      );
      if (challenge.id.isEmpty) {
        throw const AccountAuthException(
          'INVALID_RESPONSE',
          '账号服务没有返回邮箱验证码会话，请稍后重试。',
        );
      }
      _challengeId = challenge.id;
      _challengeEmail = _email.text.trim();
      _verificationForSignup = true;
      _verificationCode.clear();
      if (!mounted) return;
      setState(() => _flow = _AccountFlow.verifyEmail);
      _startResendCooldown(challenge.retryAfterSeconds);
      _showMessage('如果注册信息有效，验证码已发送到 $_challengeEmail。');
    });
  }

  Future<void> _verifyEmail() async {
    if (_verificationCode.text.trim().length != 6) {
      _showMessage('请输入邮件中的 6 位验证码。');
      return;
    }
    await _run(() async {
      final user = await _service.verifyEmail(
        challengeId: _challengeId ?? '',
        code: _verificationCode.text,
      );
      if (!mounted) return;
      setState(() {
        _user = user;
        _flow = _AccountFlow.account;
      });
    });
    if (_service.currentUser != null && widget.returnOnSuccess) {
      _returnAfterAuth();
    }
  }

  Future<void> _requestPasswordReset() async {
    if (!_validateEmailOnly()) return;
    await _run(() async {
      final challenge = await _service.requestPasswordReset(_email.text);
      if (challenge.id.isEmpty) {
        throw const AccountAuthException(
          'INVALID_RESPONSE',
          '账号服务没有返回重置验证码会话，请稍后重试。',
        );
      }
      _challengeId = challenge.id;
      _challengeEmail = _email.text.trim();
      _verificationCode.clear();
      _password.clear();
      _confirmPassword.clear();
      if (!mounted) return;
      setState(() => _flow = _AccountFlow.resetPassword);
      _startResendCooldown(challenge.retryAfterSeconds);
      _showMessage('如果该邮箱已注册，验证码会发送到 $_challengeEmail。');
    });
  }

  Future<void> _resetPassword() async {
    if (_verificationCode.text.trim().length != 6) {
      _showMessage('请输入邮件中的 6 位验证码。');
      return;
    }
    if (!_validatePasswordPair()) return;
    await _run(() async {
      await _service.resetPassword(
        challengeId: _challengeId ?? '',
        code: _verificationCode.text,
        newPassword: _password.text,
      );
      _password.clear();
      _confirmPassword.clear();
      _verificationCode.clear();
      if (!mounted) return;
      setState(() => _flow = _AccountFlow.login);
      _showMessage('密码已重置，请使用新密码登录。');
    });
  }

  Future<void> _resendCode() async {
    final challengeId = _challengeId;
    if (challengeId == null || _resendSeconds > 0) return;
    await _run(() async {
      if (_flow == _AccountFlow.resetPassword) {
        await _service.resendPasswordResetCode(challengeId);
      } else {
        await _service.resendEmailCode(challengeId);
      }
      _startResendCooldown(60);
      _showMessage('验证码已重新发送；邮件可能需要一点时间到达。');
    });
  }

  Future<void> _logout() async {
    await _run(() async {
      await _service.logout();
      if (!mounted) return;
      setState(() {
        _user = null;
        _password.clear();
        _flow = _AccountFlow.login;
      });
      _showMessage('已退出账号；本机聊天和记忆未受影响。');
    });
  }

  void _startResendCooldown(int seconds) {
    _resendTimer?.cancel();
    if (!mounted) return;
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

  bool _validate() => _formKey.currentState?.validate() ?? false;

  bool _validateEmailOnly() {
    final value = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      _showMessage('请输入有效的邮箱地址。');
      return false;
    }
    return true;
  }

  bool _validatePasswordPair() {
    final value = _password.text;
    if (value.length < 8) {
      _showMessage('密码至少需要 8 个字符。');
      return false;
    }
    if (value != _confirmPassword.text) {
      _showMessage('两次输入的密码不一致。');
      return false;
    }
    return true;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _returnAfterAuth() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    });
  }

  void _back() {
    switch (_flow) {
      case _AccountFlow.login:
      case _AccountFlow.account:
        Navigator.of(context).pop();
      case _AccountFlow.register:
      case _AccountFlow.forgotPassword:
        setState(() => _flow = _AccountFlow.login);
      case _AccountFlow.verifyEmail:
        setState(
          () => _flow = _verificationForSignup
              ? _AccountFlow.register
              : _AccountFlow.login,
        );
      case _AccountFlow.resetPassword:
        setState(() => _flow = _AccountFlow.forgotPassword);
    }
  }

  String get _title => switch (_flow) {
    _AccountFlow.login => '邮箱登录',
    _AccountFlow.register => '创建账号',
    _AccountFlow.verifyEmail => '验证邮箱',
    _AccountFlow.forgotPassword => '找回密码',
    _AccountFlow.resetPassword => '重置密码',
    _AccountFlow.account => '账号与安全',
  };

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    bool obscure = false,
    int? maxLength,
    String? Function(String?)? validator,
    Widget? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      maxLength: maxLength,
      autocorrect: false,
      enableSuggestions: false,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        counterText: '',
      ),
    ),
  );

  Widget _emailField() => _field(
    controller: _email,
    label: '邮箱',
    hint: 'name@example.com',
    icon: Icons.mail_outline_rounded,
    keyboardType: TextInputType.emailAddress,
    validator: (value) {
      final email = value?.trim() ?? '';
      return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
          ? null
          : '请输入有效的邮箱地址';
    },
  );

  Widget _passwordField({required bool confirmation}) {
    final controller = confirmation ? _confirmPassword : _password;
    return _field(
      controller: controller,
      label: confirmation ? '确认密码' : '密码',
      hint: confirmation ? '再次输入密码' : '至少 8 个字符',
      icon: Icons.lock_outline_rounded,
      obscure: !_passwordVisible,
      validator: confirmation
          ? (value) => value == _password.text ? null : '两次输入的密码不一致'
          : (value) => (value?.length ?? 0) >= 8 ? null : '密码至少需要 8 个字符',
      suffix: IconButton(
        tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
        onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
        icon: Icon(
          _passwordVisible
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
        ),
      ),
    );
  }

  Widget _codeField() => _field(
    controller: _verificationCode,
    label: '邮箱验证码',
    hint: '输入 6 位验证码',
    icon: Icons.verified_user_outlined,
    keyboardType: TextInputType.number,
    maxLength: 6,
    validator: (value) =>
        (value?.trim().length ?? 0) == 6 ? null : '请输入 6 位验证码',
  );

  Widget _submitButton(String label, VoidCallback onPressed) => SizedBox(
    width: double.infinity,
    height: 52,
    child: FilledButton(
      onPressed: _busy ? null : onPressed,
      child: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );

  Widget _serviceNotice() => Container(
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: _authSurface,
      border: Border.all(color: _authLine),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, color: _authBlue, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _service.isConfigured
                ? '账号资料由 Cwhale 账号服务处理。聊天、记忆、模型 API Key 和文件仍只保存在本机。'
                : '账号服务尚未接入。当前可查看完整流程；服务端配置后才能注册或登录。聊天和记忆继续保存在本机。',
            style: TextStyle(color: _authMuted, fontSize: 12, height: 1.45),
          ),
        ),
      ],
    ),
  );

  Widget _buildLogin() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(),
        _passwordField(confirmation: false),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () =>
                setState(() => _flow = _AccountFlow.forgotPassword),
            child: const Text('忘记密码？'),
          ),
        ),
        const SizedBox(height: 5),
        _submitButton('登录', _login),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () => setState(() => _flow = _AccountFlow.register),
          child: const Text('没有账号？邮箱注册'),
        ),
      ],
    ),
  );

  Widget _buildRegister() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(),
        _passwordField(confirmation: false),
        _passwordField(confirmation: true),
        CheckboxListTile.adaptive(
          value: _acceptedTerms,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: _authBlue,
          title: Text(
            '我已阅读并同意服务条款与隐私政策',
            style: TextStyle(color: _authMuted, fontSize: 12),
          ),
          onChanged: (value) => setState(() => _acceptedTerms = value ?? false),
        ),
        const SizedBox(height: 10),
        _submitButton('发送验证邮件', _register),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() => _flow = _AccountFlow.login),
          child: const Text('已有账号？返回登录'),
        ),
      ],
    ),
  );

  Widget _buildVerifyEmail() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _infoLine('验证码将发送到 $_challengeEmail。验证码有效期由账号服务控制。'),
        const SizedBox(height: 18),
        _codeField(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy || _resendSeconds > 0 ? null : _resendCode,
            child: Text(
              _resendSeconds > 0 ? '$_resendSeconds 秒后重新发送' : '重新发送验证码',
            ),
          ),
        ),
        const SizedBox(height: 8),
        _submitButton('验证并登录', _verifyEmail),
      ],
    ),
  );

  Widget _buildForgotPassword() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _infoLine('输入注册邮箱。为保护账号隐私，无论邮箱是否注册，页面都显示相同提示。'),
        const SizedBox(height: 18),
        _emailField(),
        const SizedBox(height: 8),
        _submitButton('发送重置验证码', _requestPasswordReset),
      ],
    ),
  );

  Widget _buildResetPassword() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _infoLine('如果 $_challengeEmail 已注册，验证码已发送到该邮箱。'),
        const SizedBox(height: 18),
        _codeField(),
        _passwordField(confirmation: false),
        _passwordField(confirmation: true),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy || _resendSeconds > 0 ? null : _resendCode,
            child: Text(
              _resendSeconds > 0 ? '$_resendSeconds 秒后重新发送' : '重新发送验证码',
            ),
          ),
        ),
        const SizedBox(height: 8),
        _submitButton('重置密码', _resetPassword),
      ],
    ),
  );

  Widget _buildAccount() {
    final user = _user;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _authSurface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: CwhaleTheme.selectedSurface,
                child: Icon(Icons.person_rounded, color: _authBlue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user?.email ?? '', style: TextStyle(color: _authInk)),
                    const SizedBox(height: 4),
                    Text(
                      user?.emailVerified == true ? '邮箱已验证' : '邮箱待验证',
                      style: TextStyle(color: _authMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _infoLine('退出登录只清除账号会话。本机聊天、记忆、API 配置和文件保持不变。'),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _busy ? null : _logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('退出登录'),
        ),
      ],
    );
  }

  Widget _infoLine(String value) => Text(
    value,
    style: TextStyle(color: _authMuted, fontSize: 13, height: 1.5),
  );

  Widget _flowContent() => switch (_flow) {
    _AccountFlow.login => _buildLogin(),
    _AccountFlow.register => _buildRegister(),
    _AccountFlow.verifyEmail => _buildVerifyEmail(),
    _AccountFlow.forgotPassword => _buildForgotPassword(),
    _AccountFlow.resetPassword => _buildResetPassword(),
    _AccountFlow.account => _buildAccount(),
  };

  String get _headline => switch (_flow) {
    _AccountFlow.login => '连接你的 Cwhale 账号',
    _AccountFlow.register => '创建你的邮箱账号',
    _AccountFlow.verifyEmail => '确认邮箱属于你',
    _AccountFlow.forgotPassword => '找回账号密码',
    _AccountFlow.resetPassword => '设置新密码',
    _AccountFlow.account => '账号资料',
  };

  String get _description => switch (_flow) {
    _AccountFlow.login => '登录仅用于账号服务。聊天内容仍留在这台设备。',
    _AccountFlow.register => '使用邮箱注册，完成邮箱验证码验证后即可登录。',
    _AccountFlow.verifyEmail => '请输入邮件中的 6 位验证码。',
    _AccountFlow.forgotPassword => '通过注册邮箱验证身份并重设密码。',
    _AccountFlow.resetPassword => '验证码通过后，账号密码会在账号服务器更新。',
    _AccountFlow.account => '管理当前登录状态。',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_title),
      leading: IconButton(
        tooltip: '返回',
        onPressed: _back,
        icon: const Icon(Icons.arrow_back_rounded),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 30),
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _authSurface,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(Icons.shield_outlined, color: _authBlue, size: 27),
              ),
              const SizedBox(height: 19),
              Text(
                _headline,
                style: TextStyle(
                  color: _authInk,
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                _description,
                style: TextStyle(color: _authMuted, height: 1.45),
              ),
              const SizedBox(height: 22),
              _serviceNotice(),
              _flowContent(),
            ],
          ),
        ),
      ),
    ),
  );
}
