import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import 'app_settings_page.dart';
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
          const SizedBox(height: 16),
          // ---------- 菜单卡：账号与设置 ----------
          MenuCard(children: [
            MenuTile(
              icon: Icons.password_outlined,
              title: '修改密码',
              onTap: _changePassword,
            ),
            menuDivider(cs),
            MenuTile(
              icon: Icons.settings_outlined,
              title: '设置',
              subtitle: '外观 · 书城频道 · 检查更新 · 服务器',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AppSettingsPage())),
            ),
          ]),
          const SizedBox(height: 14),
          // ---------- 菜单卡：退出 ----------
          MenuCard(children: [
            MenuTile(
              icon: Icons.logout,
              title: '退出登录',
              danger: true,
              onTap: _logout,
            ),
          ]),
          const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }



}
