import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'drama_player_page.dart';
import 'widgets.dart';

/// 短剧详情：渐变封面头 + 标签 + 简介 + 选集网格
class DramaDetailPage extends ConsumerStatefulWidget {
  const DramaDetailPage({super.key, required this.sid, required this.title});

  final String sid;
  final String title;

  @override
  ConsumerState<DramaDetailPage> createState() => _DramaDetailPageState();
}

class _DramaDetailPageState extends ConsumerState<DramaDetailPage> {
  DramaDetailData? _detail;
  String? _error;
  bool _introExpanded = false;
  int _currentEp = 0; // 正在看的集（从播放页返回后更新不了，仅记录最近一次跳转）

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.dramaDetail(widget.sid);
      if (!mounted) return;
      setState(() => _detail = d);
      // 服务端观看记录 → 选集定位到上次看到的那集
      try {
        final ep = await _api.dramaProgress(widget.sid);
        if (!mounted || ep <= 0 || _detail == null) return;
        setState(() {
          _currentEp = ep.clamp(0, _detail!.episodes.length);
        });
      } on ApiException {
        // 无记录/查询失败不影响详情展示
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  void _play(DramaEpisode ep) {
    if (_detail == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => DramaPlayerPage(
            sid: widget.sid,
            title: _detail!.drama.title,
            cover: _detail!.drama.cover,
            index: ep.index,
            episodes: _detail!.episodes,
          ),
        ))
        .then((watched) {
      if (watched is int && watched > 0) setState(() => _currentEp = watched);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final d = _detail;

    // 顶部是浅色奶油渐变头（深浅色模式都一样）→ 状态栏恒用深色图标
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
      backgroundColor: dark ? cs.surface : MoStyle.bg,
      body: d == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? SafeArea(child: ErrorRetry(message: _error!, onRetry: _load))
              : _buildBody(context, d, cs, dark),
      ),
    );
  }

  Widget _buildBody(BuildContext context, DramaDetailData d, ColorScheme cs, bool dark) {
    final drama = d.drama;
    final statusText = drama.finished ? '已完结' : '连载中';
    final countText = d.episodes.isNotEmpty ? '共${d.episodes.length}集' : drama.remark;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) => false,
      child: CustomScrollView(
        slivers: [
          // ---------- 封面头 ----------
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(gradient: MoStyle.detailHeaderGradient),
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 返回行
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back_rounded, size: 22),
                            color: MoStyle.ink,
                          ),
                          Expanded(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: MoStyle.titleFont,
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w700,
                                  color: MoStyle.ink),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 封面 + 信息
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 118,
                            height: 164,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: MoStyle.shadowMd(MoStyle.ink),
                            ),
                            child: BookCover(url: drama.cover, title: drama.title, radius: 14),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  drama.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontFamily: MoStyle.titleFont,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w800,
                                      height: 1.3,
                                      color: MoStyle.ink),
                                ),
                                const SizedBox(height: 8),
                                Text('$countText · $statusText',
                                    style: const TextStyle(
                                        fontSize: 12.5, color: MoStyle.ink2)),
                                if (drama.score.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.star_rounded,
                                          size: 15, color: MoStyle.star),
                                      const SizedBox(width: 2),
                                      Text(drama.score,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700,
                                              color: MoStyle.ink2)),
                                    ],
                                  ),
                                ],
                                if (drama.playCount.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text('${drama.playCount}次播放',
                                      style: const TextStyle(
                                          fontSize: 11.5, color: MoStyle.muted)),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ---------- 标签 + 简介 ----------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (drama.tags.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in drama.tags.take(6))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(t,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: dark ? MoStyle.darkPrimary : MoStyle.primary)),
                          ),
                      ],
                    ),
                  if (drama.intro.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => setState(() => _introExpanded = !_introExpanded),
                      child: Text(
                        drama.intro,
                        maxLines: _introExpanded ? 20 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.65,
                            color: dark ? MoStyle.darkInk2 : MoStyle.ink2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: () => setState(() => _introExpanded = !_introExpanded),
                        child: Text(_introExpanded ? '收起' : '展开',
                            style: TextStyle(
                                fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // ---------- 选集 ----------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 4),
              child: Row(
                  children: [
                    Text('选集',
                        style: TextStyle(
                            fontFamily: MoStyle.titleFont,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: MoStyle.inkOf(context))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('共${d.episodes.length}集',
                          style: TextStyle(fontSize: 11, color: cs.outline)),
                    ),
                    // 继续观看：跳到上次看到的那集
                    if (_currentEp > 0 && d.episodes.any((e) => e.index == _currentEp))
                      GestureDetector(
                        onTap: () {
                          final i = d.episodes.indexWhere((e) => e.index == _currentEp);
                          if (i >= 0) _play(d.episodes[i]);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
                          child: Row(
                            children: [
                              Icon(Icons.play_circle_outline_rounded,
                                  size: 16, color: cs.primary),
                              const SizedBox(width: 3),
                              Text('继续看第$_currentEp集',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: cs.primary)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 92,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                mainAxisExtent: 40,
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: d.episodes.length,
                (context, i) {
                  final ep = d.episodes[i];
                  final active = ep.index == _currentEp;
                  return Material(
                    color: active
                        ? cs.primary
                        : (dark ? MoStyle.darkPanel : MoStyle.panel),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _play(ep),
                      child: Center(
                        child: Text(
                          '${ep.index}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? Colors.white
                                : (dark ? MoStyle.darkInk2 : MoStyle.ink2),
                          ),
                        ),
                      ),
                    ),
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
