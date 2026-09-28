import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'home_page.dart';
import 'login_page.dart';

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(sessionProvider.notifier).restore());
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    // 状态栏图标颜色跟随主题：浅色模式黑字、深色模式白字。
    // 各页没有 AppBar 时不会自动设置，必须在这里统一兜底，
    // 否则会被阅读器等页面留下的全局样式污染（浅色底白字看不清）。
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: !s.restored
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (!s.loggedIn ? const LoginPage() : const HomePage()),
    );
  }
}
