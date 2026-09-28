import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/mo_theme.dart';
import 'ui/app_root.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ProviderScope(child: XiaoshuoApp()));
}

class XiaoshuoApp extends StatelessWidget {
  const XiaoshuoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '墨笺',
      debugShowCheckedModeBanner: false,
      theme: moLightTheme(),
      darkTheme: moDarkTheme(),
      themeMode: ThemeMode.system,
      home: const AppRoot(),
    );
  }
}
