import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'drama_player_page.dart';
import 'widgets.dart';

/// 短剧观看历史：点条目直接续播上次看到的那一集，长按删除
class DramaHistoryPage extends ConsumerStatefulWidget {
  const DramaHistoryPage({super.key});

  @override
  ConsumerState<DramaHistoryPage> createState() => _DramaHistoryPageState();
}

class _DramaHistoryPageState extends ConsumerState<DramaHistoryPage> {
  List<DramaHistoryItem>? _items;
  String? _error;
  bool _opening = false; // 防止连点重复进播放器

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await _api.dramaHistory();
      if (!mounted) return;
      setState(() => _items = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _remove(DramaHistoryItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('不再显示《${it.title}》的观看记录？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteDramaHistory(it.sid);
      if (!mounted) return;
      setState(() => _items?.removeWhere((e) => e.sid == it.sid));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // 点条目 → 取详情 → 直接进播放器续播
  Future<void> _open(DramaHistoryItem it) async {
    if (_opening) return;
    _opening = true;
    try {
      final d = await _api.dramaDetail(it.sid);
      if (!mounted) return;
      final eps = d.episodes;
      if (eps.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('该剧暂无可播放的剧集')));
        return;
      }
      // 优先续播记录的那集；记录的集已不存在（下架/重排）就播第一集
      final i = eps.indexWhere((e) => e.index == it.epIndex);
      final ep = i >= 0 ? eps[i] : eps.first;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DramaPlayerPage(
          sid: it.sid,
          title: d.drama.title.isNotEmpty ? d.drama.title : it.title,
          cover: d.drama.cover.isNotEmpty ? d.drama.cover : it.cover,
          index: ep.index,
          episodes: eps,
        ),
      ));
      _load(); // 回来后刷新进度
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final items = _items;

    return Scaffold(
      backgroundColor: dark ? cs.surface : MoStyle.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: '观看历史'),
          Expanded(
            child: items == null && _error == null
                ? const Center(child: CircularProgressIndicator())
                : items == null
                    ? ErrorRetry(message: _error!, onRetry: _load)
                    : items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.movie_creation_outlined, size: 46, color: cs.outline),
                          const SizedBox(height: 10),
                          Text('还没有观看记录',
                              style: TextStyle(fontSize: 13.5, color: cs.outline)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      color: cs.primary,
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final it = items[i];
                          return _HistoryCard(
                            item: it,
                            dark: dark,
                            onTap: () => _open(it),
                            onLongPress: () => _remove(it),
                          );
                        },
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.item,
    required this.dark,
    required this.onTap,
    required this.onLongPress,
  });

  final DramaHistoryItem item;
  final bool dark;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static String _fmtTime(String raw) {
    DateTime? t;
    try {
      // 服务端存 UTC："2026-09-28 03:33:04"
      t = DateTime.parse(raw.replaceFirst(' ', 'T') + (raw.endsWith('Z') ? '' : 'Z')).toLocal();
    } catch (_) {}
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes}分钟前';
    if (d.inHours < 24) return '${d.inHours}小时前';
    if (d.inDays < 30) return '${d.inDays}天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final epText = item.totalEps > 0 ? '看到第${item.epIndex}集 / 共${item.totalEps}集' : '看到第${item.epIndex}集';
    final time = _fmtTime(item.updatedAt);

    return Material(
      color: dark ? MoStyle.darkPanel : MoStyle.panel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              SizedBox(
                width: 62,
                height: 84,
                child: BookCover(url: item.cover, title: item.title, radius: 10, cacheWidth: 200),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: MoStyle.inkOf(context)),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.play_circle_outline_rounded, size: 14, color: cs.primary),
                        const SizedBox(width: 4),
                        Text(epText,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: cs.primary)),
                      ],
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(time, style: TextStyle(fontSize: 11, color: cs.outline)),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}
