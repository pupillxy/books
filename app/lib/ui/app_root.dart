import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_update.dart';
import '../core/appearance.dart';
import '../core/store_pref.dart';
import '../core/session.dart';
import 'home_page.dart';
import 'login_page.dart';

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  bool _updateChecked = false; // 每次启动只检查一次更新

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(sessionProvider.notifier).restore();
      ref.read(appearanceProvider.notifier).restore();
      ref.read(storeGenderProvider.notifier).restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    // 状态栏图标颜色跟随主题：浅色模式黑字、深色模式白字。
    // 各页没有 AppBar 时不会自动设置，必须在这里统一兜底，
    // 否则会被阅读器等页面留下的全局样式污染（浅色底白字看不清）。
    // 登录后就地检查应用更新（AppUpdate 内部保证单次会话只弹一次，失败静默）
    if (s.restored && s.loggedIn && s.api != null && !_updateChecked) {
      _updateChecked = true;
      Future.microtask(() {
        // AppRoot 是根组件，context 与会话同生命周期，跨 microtask 安全
        // ignore: use_build_context_synchronously
        AppUpdate.dailyCheck(context, s.api!.baseUrl); // 每天首次进入查一次
      });
    }
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
