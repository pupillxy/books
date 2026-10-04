import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import 'register_page.dart';

// 「墨笺」设计 Token 已抽至 core/mo_theme.dart，此处直接复用

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _https = false;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(sessionProvider).serverUrl;
    if (saved.isNotEmpty) {
      var url = saved;
      if (url.startsWith('https://')) {
        _https = true;
        url = url.substring(8);
      } else if (url.startsWith('http://')) {
        url = url.substring(7);
      }
      final i = url.indexOf(':');
      if (i > 0) {
        _host.text = url.substring(0, i);
        _port.text = url.substring(i + 1).replaceAll('/', '');
      } else {
        _host.text = url;
      }
    }
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    final port = _port.text.trim();
    final user = _username.text.trim();
    final pass = _password.text;
    if (host.isEmpty || port.isEmpty) {
      _toast('请填写服务器地址和端口');
      return;
    }
    if (user.isEmpty || pass.isEmpty) {
      _toast('请填写用户名和密码');
      return;
    }
    final url = '${_https ? 'https' : 'http'}://$host:$port';
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).login(url, user, pass);
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // 注册入口：优先用表单里现填的地址，没填就用上次连接过的
  void _openRegister() {
    final host = _host.text.trim();
    final port = _port.text.trim();
    var url = ref.read(sessionProvider).serverUrl;
    if (host.isNotEmpty && port.isNotEmpty) {
      url = '${_https ? 'https' : 'http'}://$host:$port';
    }
    if (url.isEmpty) {
      _toast('请先填写服务器地址和端口');
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RegisterPage(serverUrl: url)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: MoStyle.pageGradient),
        child: SafeArea(
          child: Stack(
            children: [
              // 右上角朱砂装饰圆
              Positioned(
                right: -34,
                top: -20,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x29C2522C), Color(0x00C2522C)],
                    ),
                  ),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ---- Hero：朱砂竖条 + 标题 + 副文案 ----
                        Row(
                          children: [
                            Container(
                              width: 5,
                              height: 20,
                              decoration: BoxDecoration(
                                color: MoStyle.primary,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(width: 9),
                            const Text(
                              '服务器',
                              style: TextStyle(
                                fontFamily: MoStyle.titleFont,
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                                color: MoStyle.primaryStrong,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        const Padding(
                          padding: EdgeInsets.only(left: 14),
                          child: Text(
                            '阅读服务 · 连接参数',
                            style: TextStyle(fontSize: 12, color: MoStyle.muted, letterSpacing: 0.3),
                          ),
                        ),
                        const SizedBox(height: 22),

                        // ---- 地址 + 端口 分栏 ----
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 14,
                              child: AuthField(
                                label: '地址',
                                icon: Icons.grid_view_rounded,
                                controller: _host,
                                hintText: '192.168.31.102',
                                keyboardType: TextInputType.url,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 10,
                              child: AuthField(
                                label: '端口',
                                controller: _port,
                                hintText: '8080',
                                keyboardType: TextInputType.number,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),
                        AuthField(
                          label: '用户名',
                          icon: Icons.person_outline,
                          controller: _username,
                          hintText: 'admin',
                        ),
                        const SizedBox(height: 15),
                        AuthField(
                          label: '密码',
                          icon: Icons.lock_outline,
                          controller: _password,
                          obscure: _obscure,
                          onToggleObscure: () => setState(() => _obscure = !_obscure),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 16),

                        // ---- HTTPS 开关卡片 ----
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: MoStyle.rule, width: 1.5),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment(-0.7, -1),
                                    end: Alignment(0.7, 1),
                                    colors: [Color(0xFFD0683C), Color(0xFFC2522C)],
                                  ),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: const Icon(Icons.gpp_good_outlined, color: Colors.white, size: 20),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('使用 HTTPS (SSL)',
                                        style: TextStyle(fontSize: 13.5, color: MoStyle.ink)),
                                    SizedBox(height: 2),
                                    Text('局域网自签名证书时可关闭',
                                        style: TextStyle(fontSize: 11, color: MoStyle.muted)),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _https,
                                onChanged: (v) => setState(() => _https = v),
                                trackColor: WidgetStateProperty.resolveWith((s) =>
                                    s.contains(WidgetState.selected)
                                        ? MoStyle.primary
                                        : const Color(0xFFD8C7B4)),
                                thumbColor: const WidgetStatePropertyAll(Colors.white),
                                trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                              ),
                            ],
                          ),
                        ),

                        // ---- 登录按钮 ----
                        Material(
                          borderRadius: BorderRadius.circular(14),
                          child: Ink(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment(-1, -1),
                                end: Alignment(1, 1),
                                colors: [MoStyle.btnGradientStart, MoStyle.primary],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x57C2522C), // rgba(194,82,44,.34)
                                  offset: Offset(0, 10),
                                  blurRadius: 22,
                                ),
                              ],
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: _busy ? null : _submit,
                              child: SizedBox(
                                height: 52,
                                child: Center(
                                  child: _busy
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          '连接并登录',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // ---- 注册入口 ----
                        TextButton(
                          onPressed: _busy ? null : _openRegister,
                          child: const Text('注册新用户',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  color: MoStyle.muted,
                                  letterSpacing: 0.3)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }
}

/// 登录/注册共用输入框（设计稿 .field）：label + 白底圆角输入框（聚焦时朱砂边框 + 光晕）
class AuthField extends StatefulWidget {
  const AuthField({
    super.key,
    required this.label,
    required this.controller,
    this.icon,
    this.hintText,
    this.keyboardType,
    this.obscure = false,
    this.onToggleObscure,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final IconData? icon;
  final String? hintText;
  final TextInputType? keyboardType;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final ValueChanged<String>? onSubmitted;

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Text(widget.label,
              style: const TextStyle(
                  fontSize: 12, color: MoStyle.ink2, fontWeight: FontWeight.w700)),
        ),
        Focus(
          onFocusChange: (v) => setState(() => _focused = v),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: _focused ? MoStyle.primary : MoStyle.rule,
                width: 1.5,
              ),
              boxShadow: _focused
                  ? const [BoxShadow(color: MoStyle.focusShadow, blurRadius: 0, spreadRadius: 3)]
                  : const [],
            ),
            child: Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: MoStyle.accent2),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    keyboardType: widget.keyboardType,
                    autocorrect: false,
                    enableSuggestions: false,
                    obscureText: widget.obscure,
                    onSubmitted: widget.onSubmitted,
                    cursorColor: MoStyle.primary,
                    style: const TextStyle(fontSize: 15, color: MoStyle.ink),
                    // 强制行盒与字号一致，避免中文字体 metrics 把文字顶偏（不垂直居中）
                    strutStyle: const StrutStyle(
                        fontSize: 15, height: 1.0, forceStrutHeight: true),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false, // 外层容器已画白底，避免继承全局主题的深色填充
                      border: InputBorder.none,
                      // 聚焦边框由外层容器统一绘制，避免两层线
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: widget.hintText,
                      hintStyle: const TextStyle(fontSize: 15, color: Color(0xFFC4B5A4)),
                    ),
                  ),
                ),
                if (widget.onToggleObscure != null)
                  GestureDetector(
                    onTap: widget.onToggleObscure,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        widget.obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 19,
                        color: MoStyle.accent2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
