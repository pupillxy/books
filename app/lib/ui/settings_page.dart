import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/appearance.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'widgets.dart';

/// 我的：渐变头像 + 统计卡 + 菜单卡（「墨笺」风）
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  // ---------- 通用 ----------

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ---------- 服务器 ----------

  Future<void> _editServer() async {
    final ctrl = TextEditingController(text: ref.read(sessionProvider).serverUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.10:8080',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final url = ctrl.text.trim();
    if (url.isEmpty) return;
    final err = await ref.read(sessionProvider.notifier).updateServer(url);
    if (!mounted) return;
    _toast(err ?? '服务器已更新');
  }

  // ---------- 修改密码 ----------

  Future<void> _changePassword() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '原密码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (newCtrl.text.length < 6) {
      _toast('新密码至少 6 位');
      return;
    }
    try {
      await _api.changePassword(oldCtrl.text, newCtrl.text);
      if (!mounted) return;
      _toast('密码已修改');
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  // ---------- 外观 ----------

  /// 全局深浅色模式切换（持久化，立即生效）
  Future<void> _pickAppearance() async {
    final current = ref.read(appearanceProvider);
    final mode = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('外观'),
        children: [
          for (final e in const {
            ThemeMode.system: '跟随系统',
            ThemeMode.light: '浅色',
            ThemeMode.dark: '深色',
          }.entries)
            RadioListTile<ThemeMode>(
              value: e.key,
              groupValue: current,
              title: Text(e.value),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ],
      ),
    );
    if (mode != null) await ref.read(appearanceProvider.notifier).set(mode);
  }

  // ---------- 退出登录 ----------

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(sessionProvider.notifier).logout();
    }
  }

  // ---------- 管理员：扫描 ----------

  Future<void> _triggerScan() async {
    try {
      await _api.triggerScan();
      if (!mounted) return;
      _toast('扫描已触发');
      setState(() {});
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = ref.watch(sessionProvider);
    final user = session.user;
    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- 页头（固定常驻）----------
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const PageHeader(title: '我的', horizontal: 2),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
              children: [
                // ---------- 账号卡 ----------
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Row(
              children: [
                // 渐变头像 58
                Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment(-0.7, -1), // ≈140deg
                      end: Alignment(0.7, 1),
                      colors: [Color(0xFFD0683C), Color(0xFFC2522C)],
                    ),
                    boxShadow: [
                      BoxShadow(color: Color(0x40C2522C), blurRadius: 14, offset: Offset(0, 6)),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    user.displayName.characters.first.toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: MoStyle.titleFont,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: MoStyle.inkOf(context))),
                          ),
                          if (user.isAdmin) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: MoStyle.softOf(context),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text('管理员',
                                  style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: MoStyle.strongOf(context))),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text('@${user.username}',
                          style: TextStyle(fontSize: 11.5, color: cs.outline)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ---------- 统计卡 ----------
          FutureBuilder<List<int>>(
            future: _stats(),
            builder: (context, snap) {
              final shelf = snap.data?[0];
              final library = snap.data?[1];
              return Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.outlineVariant, width: 0.8),
                ),
                child: Row(
                  children: [
                    _statCell('${shelf ?? '–'}', '书架收藏', cs),
                    _vRule(cs),
                    _statCell('${library ?? '–'}', '书库藏书', cs),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          // ---------- 菜单卡：通用 ----------
          _MenuCard(children: [
            _MenuTile(
              icon: Icons.brightness_6_outlined,
              title: '外观',
              subtitle: switch (ref.watch(appearanceProvider)) {
                ThemeMode.light => '浅色',
                ThemeMode.dark => '深色',
                _ => '跟随系统',
              },
              cs: cs,
              onTap: _pickAppearance,
            ),
            _divider(cs),
            _MenuTile(
              icon: Icons.dns_outlined,
              title: '服务器地址',
              subtitle: session.serverUrl,
              cs: cs,
              onTap: _editServer,
            ),
            _divider(cs),
            _MenuTile(
              icon: Icons.password_outlined,
              title: '修改密码',
              cs: cs,
              onTap: _changePassword,
            ),
          ]),
          // 管理员功能：普通用户完全不可见
          if (user.isAdmin) ...[
            const SizedBox(height: 14),
            _AdminCard(onTriggerScan: _triggerScan),
          ],
          const SizedBox(height: 14),
          // ---------- 菜单卡：退出 ----------
          _MenuCard(children: [
            _MenuTile(
              icon: Icons.logout,
              title: '退出登录',
              danger: true,
              cs: cs,
              onTap: _logout,
            ),
          ]),
          const SizedBox(height: 20),
          Center(
            child: Text('墨笺 · v1.0.0',
                style: TextStyle(fontSize: 11.5, color: cs.outline)),
          ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell(String num, String label, ColorScheme cs) {
    return Expanded(
      child: Column(
        children: [
          Text(num,
              style: TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: cs.primary)),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ),
    );
  }

  Widget _vRule(ColorScheme cs) => Container(width: 0.8, height: 26, color: cs.outlineVariant);

  Widget _divider(ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(left: 52),
        child: Container(height: 0.8, color: cs.outlineVariant),
      );

  /// 书架数 + 书库总数
  Future<List<int>> _stats() async {
    final shelf = await _api.shelf();
    final books = await _api.books(page: 1, size: 1);
    return [shelf.length, books.total];
  }
}

/// 白底圆角菜单卡
class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant, width: 0.8),
      ),
      child: Column(children: children),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.cs,
    this.subtitle,
    this.danger = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final ColorScheme cs;
  final bool danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MoStyle.danger : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: color)),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: cs.outline)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// 管理员卡：扫描导入
class _AdminCard extends ConsumerStatefulWidget {
  const _AdminCard({required this.onTriggerScan});

  final VoidCallback onTriggerScan;

  @override
  ConsumerState<_AdminCard> createState() => _AdminCardState();
}

class _AdminCardState extends ConsumerState<_AdminCard> {
  ScanStatusInfo? _status;
  String? _error;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _api.scanStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _status;
    return _MenuCard(
      children: [
        _MenuTile(
          icon: Icons.admin_panel_settings_outlined,
          title: '扫描导入',
          subtitle: _subtitle(s, _error),
          cs: cs,
          onTap: s?.scanning == true
              ? null
              : () {
                  widget.onTriggerScan();
                  Future.delayed(const Duration(seconds: 2), _load);
                },
        ),
      ],
    );
  }

  String _subtitle(ScanStatusInfo? s, String? error) {
    if (error != null) return error;
    if (s == null) return '加载中…';
    if (s.scanning) return '正在扫描导入…';
    final last = s.lastScan.isEmpty ? '从未' : s.lastScan;
    return '上次扫描：$last · 书库 ${s.totalBooks} 本';
  }
}
