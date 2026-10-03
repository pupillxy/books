import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书城频道偏好（'1'=男频 '0'=女频；榜单卡/书库分类按此取数，持久化）
class StoreGenderNotifier extends Notifier<String> {
  static const _key = 'store.gender';

  @override
  String build() => '1';

  /// 启动时恢复上次选择（AppRoot 调用）
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    state = (v == '0') ? '0' : '1';
  }

  Future<void> set(String gender) async {
    state = (gender == '0') ? '0' : '1';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, state);
  }
}

final storeGenderProvider =
    NotifierProvider<StoreGenderNotifier, String>(StoreGenderNotifier.new);
