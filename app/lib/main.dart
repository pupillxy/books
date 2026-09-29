import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/appearance.dart';
import 'core/mo_theme.dart';
import 'ui/app_root.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
