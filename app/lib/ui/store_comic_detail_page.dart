import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_comic_reader_page.dart';
import 'widgets.dart';

/// 漫画详情：封面 + 信息 + 简介 + 话列表（官方协议 comic_tab/comic_detail +
/// directory/all_items，10/04 定案）。阅读实时回放不下载；加入书架在阅读器内
/// 悬浮按钮完成（server 轻量入库 books，source=comic）。
class StoreComicDetailPage extends ConsumerStatefulWidget {
  const StoreComicDetailPage({super.key, required this.bookId, required this.title});

  final String bookId;
  final String title;

  @override
  ConsumerState<StoreComicDetailPage> createState() => _StoreComicDetailPageState();
}

class _StoreComicDetailPageState extends ConsumerState<StoreComicDetailPage> {
  ComicDetailData? _detail;
  String? _error;
  bool _synopsisExpanded = false;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.storeComicDetail(widget.bookId);
      if (!mounted) return;
      setState(() => _detail = d);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  void _openChapter(int index) {
    final chapters = _detail!.chapters;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreComicReaderPage(
            bookId: widget.bookId,
            title: _detail?.title ?? widget.title,
            chapters: chapters,
            initialIndex: index,
            onShelf: _detail?.onShelf ?? false)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _detail == null
          ? (_error != null
              ? ErrorRetry(message: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator(strokeWidth: 2)))
          : _buildBody(context, _detail!),
    );
  }

  Widget _buildBody(BuildContext context, ComicDetailData d) {
    final meta = [
      if (d.category.isNotEmpty) d.category,
      if (d.updateTag.isNotEmpty) d.updateTag,
      if (d.readCount.isNotEmpty) d.readCount,
    ].join(' · ');
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: Text(d.title,
              style: TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          pinned: true,
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: BookCover(
                          url: d.cover.isEmpty ? null : d.cover,
                          title: d.title,
                          cacheWidth: 400)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: MoStyle.titleFont,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: MoStyle.strongOf(context))),
                      const SizedBox(height: 6),
                      Text(d.author,
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.outline)),
                      const SizedBox(height: 6),
                      Row(children: [
                        if (d.score.isNotEmpty) ...[
                          Text('${d.score}分',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: MoStyle.primaryStrong)),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.outline)),
                        ),
                      ]),
                      if (d.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(d.tags,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.outline)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (d.synopsis.isNotEmpty)
          SliverToBoxAdapter(
            child: GestureDetector(
              onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.synopsis,
                        maxLines: _synopsisExpanded ? null : 3,
                        overflow: _synopsisExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.5,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: .85))),
                    Icon(_synopsisExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                        size: 18, color: Theme.of(context).colorScheme.outline),
                  ],
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text('话列表（${d.chapters.length}）',
                style: TextStyle(
                    fontFamily: MoStyle.titleFont,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: MoStyle.strongOf(context))),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final ch = d.chapters[i];
                return InkWell(
                  onTap: () => _openChapter(i),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 34,
                          child: Text('${ch.index}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontFamily: MoStyle.titleFont,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.outline)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(ch.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14)),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 16,
                            color: Theme.of(context).colorScheme.outline),
                      ],
                    ),
                  ),
                );
              },
              childCount: d.chapters.length,
            ),
          ),
        ),
      ],
    );
  }
}
