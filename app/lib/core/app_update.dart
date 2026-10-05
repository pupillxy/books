import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mo_theme.dart';

/// 应用内更新。
///
/// - 检查源固定为**生产通道**（/api/app/latest）：dev 包（与生产并排安装、包名
///   `.dev`）也替生产 App 查更新——下载的是生产 APK，系统安装器直接更新手机上的
///   「小说阅读」，dev 包自身不动。dev 通道（apks/dev/）仅作测试分发，App 不消费。
/// - 每天首次进入 App 自动查一次（本地日期 gate，SharedPreferences 持久化）；
///   设置页「检查更新」可手动查，有结果反馈。
/// - 流程：弹窗[立即更新 / 下次提示] → 下载进度 → [点击安装] → 系统安装器。
///   「下次提示」即关闭，次日首次进入再查再弹。
/// 发版：app/build_all.ps1（见 AGENTS.md §5）。
const String kAppChannel = String.fromEnvironment('APP_CHANNEL', defaultValue: 'prod');

class AppUpdate {
  static const _installChannel = MethodChannel('xiaoshuo/install');
  static const _lastCheckDayKey = 'app_update_last_check_day';

  /// 每天首次进入 App 检查（按本地日期去重；手动「检查更新」不受此限制）
  static Future<void> dailyCheck(BuildContext context, String baseUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      if (prefs.getString(_lastCheckDayKey) == day) return;
      await prefs.setString(_lastCheckDayKey, day);
      // ignore: use_build_context_synchronously
      await _check(context, baseUrl, manual: false);
    } catch (_) {
      // 日期持久化失败不影响检查本身
      // ignore: use_build_context_synchronously
      await _check(context, baseUrl, manual: false);
    }
  }

  /// 手动检查（设置页入口）：无更新/失败都有提示
  static Future<void> checkNow(BuildContext context, String baseUrl) async {
    await _check(context, baseUrl, manual: true);
  }

  static Future<void> _check(BuildContext context, String baseUrl,
      {required bool manual}) async {
    try {
      final local = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
      final dio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final resp = await dio.get<Map<String, dynamic>>('/api/app/latest');
      final data = resp.data ?? const {};
      final latestCode = (data['version_code'] as num?)?.toInt() ?? 0;
      if (latestCode <= local) {
        if (manual && context.mounted) _toast(context, '当前已是最新版本');
        return;
      }
      if (!context.mounted) return;
      _showUpdateDialog(context, dio, data);
    } catch (_) {
      if (manual && context.mounted) _toast(context, '检查更新失败，请确认与 NAS 的连接');
    }
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  static void _showUpdateDialog(
      BuildContext context, Dio dio, Map<String, dynamic> data) {
    final name = (data['version_name'] ?? '') as String;
    final notes = (data['notes'] ?? '') as String;
    final size = (data['size'] as num?)?.toInt() ?? 0;
    final sizeText = size > 0 ? ' · ${(size / (1 << 20)).toStringAsFixed(1)}MB' : '';
    final isDevApp = kAppChannel == 'dev';
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Text(isDevApp ? '生产版有更新 $name' : '发现新版本 $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notes.trim().isNotEmpty)
              Text(notes.trim(), style: const TextStyle(fontSize: 13.5, height: 1.5)),
            if (notes.trim().isNotEmpty) const SizedBox(height: 8),
            Text(
              isDevApp ? '将更新手机上的「小说阅读」正式版$sizeText' : '安装包 $sizeText',
              style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(), // 下次提示：次日首次进入再弹
            child: const Text('下次提示'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: MoStyle.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              _downloadAndInstall(context, dio, name);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  static Future<void> _downloadAndInstall(
      BuildContext context, Dio dio, String name) async {
    // 进度对话框内部状态经 dialogSet 从下载回调刷新（StatefulBuilder 惯用法）
    void Function(VoidCallback)? dialogSet;
    var progress = 0.0;
    var done = false;
    var failed = false;
    var installing = false;
    String? savedPath;

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSet = setDialogState; // 暴露给下载回调刷新进度
          return PopScope(
            canPop: done || failed,
            child: AlertDialog(
              title: Text(failed ? '更新失败' : done ? '下载完成' : '正在更新 $name'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: failed ? null : (done ? 1 : progress),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    failed
                        ? '下载失败，请确认与 NAS 的连接后重试'
                        : done
                            ? (installing ? '正在打开安装程序…' : '下载完成，点击安装即可更新')
                            : '${(progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                        fontSize: 12.5, color: Theme.of(ctx).colorScheme.outline),
                  ),
                ],
              ),
              actions: [
                if (done && !installing)
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MoStyle.primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      setDialogState(() => installing = true);
                      try {
                        await _installChannel
                            .invokeMethod('installApk', {'path': savedPath!});
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      } catch (_) {
                        setDialogState(() {
                          installing = false;
                          failed = true;
                          done = false;
                        });
                      }
                    },
                    child: const Text('点击安装'),
                  ),
                if (failed) ...[
                  TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('关闭')),
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _downloadAndInstall(context, dio, name);
                    },
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ));

    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      savedPath = '${dir.path}/update.apk';
      final file = File(savedPath);
      if (await file.exists()) await file.delete();
      await dio.download('/api/app/latest/apk', savedPath,
          onReceiveProgress: (got, total) {
        if (total > 0) progress = (got / total).clamp(0.0, 1.0);
        dialogSet?.call(() {});
      });
      done = true;
      dialogSet?.call(() {}); // 停在「点击安装」，等用户手动触发
    } catch (_) {
      failed = true;
      dialogSet?.call(() {});
    }
  }
}
