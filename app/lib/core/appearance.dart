import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局外观模式（设置页切换、持久化；阅读器 6 套配色独立，不受此影响）
class AppearanceNotifier extends Notifier<ThemeMode> {
  static const _key = 'appearance.mode';

  @override
  ThemeMode build() => ThemeMode.system;

  /// 启动时恢复上次选择（AppRoot 调用）
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key) ?? 'system';
    state = switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          _ => 'system',
        });
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceNotifier, ThemeMode>(AppearanceNotifier.new);
