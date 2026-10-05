import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/appearance.dart';
import 'core/mo_theme.dart';
import 'ui/app_root.dart';

/// 限制单主机并发连接数：书城封面改走 NAS 代理后所有图打到同一主机，
/// dart:io 的 TLS 握手在 UI isolate 上执行，几十条并发新建连接会在首屏
/// 造成握手风暴掉帧；限流后握手错峰、keep-alive 复用率也更高。
class _BoundedConnectionsOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.maxConnectionsPerHost = 6;
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _BoundedConnectionsOverrides();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ProviderScope(child: XiaoshuoApp()));
}

class XiaoshuoApp extends ConsumerWidget {
  const XiaoshuoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 全局深浅色模式：设置页「外观」切换（appearanceProvider 持久化）
    final mode = ref.watch(appearanceProvider);
    return MaterialApp(
      title: '墨笺',
      debugShowCheckedModeBanner: false,
      theme: moLightTheme(),
      darkTheme: moDarkTheme(),
      themeMode: mode,
      home: const AppRoot(),
    );
  }
}
