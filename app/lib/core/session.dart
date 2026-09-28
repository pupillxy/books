import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import '../models.dart';

/// 会话状态：登录态 + 服务器地址
class SessionState {
  /// 启动时是否已完成本地凭据恢复
  final bool restored;
  final String serverUrl;
  final ApiClient? api;
  final User? user;

  const SessionState({
    this.restored = false,
    this.serverUrl = '',
    this.api,
    this.user,
  });

  bool get loggedIn => api != null && user != null;
}

class SessionNotifier extends Notifier<SessionState> {
  String _token = '';

  @override
  SessionState build() => const SessionState();

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url') ?? '';
    final token = prefs.getString('token') ?? '';
    if (url.isEmpty || token.isEmpty) {
      state = SessionState(restored: true, serverUrl: url);
      return;
    }
    _token = token;
    final api = ApiClient(baseUrl: url, token: token);
    try {
      final me = await api.me();
      state = SessionState(restored: true, serverUrl: url, api: api, user: me);
    } catch (_) {
      // token 失效或服务器不可达：回到登录页，保留已填的服务器地址
      state = SessionState(restored: true, serverUrl: url);
    }
  }

  Future<void> login(String serverUrl, String username, String password) async {
    final r = await ApiClient.login(serverUrl, username, password);
    _token = r.token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', serverUrl.trim());
    await prefs.setString('token', r.token);
    await prefs.setString('user_json', jsonEncode(r.user.toJson()));
    state = SessionState(
      restored: true,
      serverUrl: serverUrl.trim(),
      api: ApiClient(baseUrl: serverUrl, token: r.token),
      user: r.user,
    );
  }

  Future<void> logout() async {
    _token = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('user_json');
    final url = state.serverUrl;
    state = SessionState(restored: true, serverUrl: url);
  }

  /// 修改服务器地址：用现有 token 验证，成功则无缝切换，失败返回错误信息
  Future<String?> updateServer(String newUrl) async {
    final api = ApiClient(baseUrl: newUrl, token: _token.isEmpty ? null : _token);
    try {
      final me = await api.me();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', newUrl.trim());
      state = SessionState(
        restored: true,
        serverUrl: newUrl.trim(),
        api: api,
        user: state.user ?? me,
      );
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);
