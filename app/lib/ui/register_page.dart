import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import 'login_page.dart';

/// 注册新用户：仅用户名/密码/确认密码三项，成功后自动登录进 App。
/// 视觉复用登录页设计稿（同渐变底、装饰圆、AuthField、朱砂渐变主按钮），
/// 服务器地址沿用登录页（serverUrl 由登录页传入，不在本页重复填写）。
class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _confirmObscure = true;
  bool _busy = false;

  Future<void> _submit() async {
    final user = _username.text.trim();
    final pass = _password.text;
    if (user.isEmpty) {
      _toast('请填写用户名');
      return;
    }
    if (pass.length < 6) {
      _toast('密码至少 6 位');
      return;
    }
    if (_confirm.text != pass) {
      _toast('两次输入的密码不一致');
      return;
    }
    setState(() => _busy = true);
    try {
      await ApiClient.register(widget.serverUrl, user, pass);
    } on ApiException catch (e) {
      _toast(e.message);
      return;
    } catch (e) {
      _toast('注册失败：$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // 注册成功即自动登录（会话持久化走登录同一链路），登录后本页自行退出
    try {
      await ref.read(sessionProvider.notifier).login(widget.serverUrl, user, pass);
    } on ApiException catch (e) {
      _toast('注册成功，自动登录失败：${e.message}，请返回登录');
      return;
    } catch (e) {
      _toast('注册成功，自动登录失败，请返回登录');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: MoStyle.pageGradient),
        child: SafeArea(
          child: Stack(
            children: [
              // 右上角朱砂装饰圆（登录页同款）
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
                        // ---- Hero：朱砂竖条 + 标题 + 副文案（登录页同款）----
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
                              '注册新用户',
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
                            '家庭阅读 · 创建账号',
                            style: TextStyle(fontSize: 12, color: MoStyle.muted, letterSpacing: 0.3),
                          ),
                        ),
                        const SizedBox(height: 22),

                        AuthField(
                          label: '用户名',
                          icon: Icons.person_outline,
                          controller: _username,
                          hintText: '2 位以上',
                        ),
                        const SizedBox(height: 15),
                        AuthField(
                          label: '密码',
                          icon: Icons.lock_outline,
                          controller: _password,
                          obscure: _obscure,
                          onToggleObscure: () => setState(() => _obscure = !_obscure),
                          hintText: '至少 6 位',
                        ),
                        const SizedBox(height: 15),
                        AuthField(
                          label: '确认密码',
                          icon: Icons.lock_outline,
                          controller: _confirm,
                          obscure: _confirmObscure,
                          onToggleObscure: () => setState(() => _confirmObscure = !_confirmObscure),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 26),

                        // ---- 注册按钮（登录按钮同款渐变 + 阴影）----
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
                                          '注册并登录',
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

                        // ---- 返回登录 ----
                        TextButton(
                          onPressed: _busy ? null : () => Navigator.of(context).pop(),
                          child: const Text('已有账号，返回登录',
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
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }
}
