import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/appearance.dart';
import '../core/app_update.dart';
import '../core/session.dart';
import '../core/store_pref.dart';
import 'widgets.dart';

/// 设置：外观 / 书城频道 / 服务器地址 / 扫描导入（管理员）/ 检查更新 / 版本信息。
/// 从「我的」页拆出（10/06），账号相关（修改密码/退出登录）留在「我的」。
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
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

  /// 书城频道偏好（男频/女频，持久化；榜单卡与书库分类按此取数）
  Future<void> _pickGender() async {
    final current = ref.read(storeGenderProvider);
    final gender = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('书城频道'),
        children: [
          RadioListTile<String>(
            value: '1',
            groupValue: current,
            title: const Text('男频'),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<String>(
            value: '0',
            groupValue: current,
            title: const Text('女频'),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
    );
    if (gender != null) await ref.read(storeGenderProvider.notifier).set(gender);
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

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const PageHeader(title: '设置', horizontal: 2),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: [
                MenuCard(children: [
                  MenuTile(
                    icon: Icons.brightness_6_outlined,
                    title: '外观',
                    subtitle: switch (ref.watch(appearanceProvider)) {
                      ThemeMode.light => '浅色',
                      ThemeMode.dark => '深色',
                      _ => '跟随系统',
                    },
                    onTap: _pickAppearance,
                  ),
                  menuDivider(cs),
                  MenuTile(
                    icon: Icons.male_rounded,
                    title: '书城频道',
                    subtitle: ref.watch(storeGenderProvider) == '0' ? '女频' : '男频',
                    onTap: _pickGender,
                  ),
                ]),
                const SizedBox(height: 14),
                MenuCard(children: [
                  MenuTile(
                    icon: Icons.dns_outlined,
                    title: '服务器地址',
                    subtitle: ref.watch(sessionProvider).serverUrl,
                    onTap: _editServer,
                  ),
                ]),

                const SizedBox(height: 14),
                MenuCard(children: [
                  MenuTile(
                    icon: Icons.system_update_alt_rounded,
                    title: '检查更新',
                    subtitle: '每天首次进入 App 也会自动检查',
                    onTap: () => AppUpdate.checkNow(context, _api.baseUrl),
                  ),
                ]),
                const SizedBox(height: 20),
                const Center(child: VersionFooter()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
