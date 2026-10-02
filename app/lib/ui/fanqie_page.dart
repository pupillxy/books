import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 番茄书城：全部数据走 App 协议（unidbg 同源）。
/// 首页 feed（实时热度排行榜等模块）+ 搜索；正文按需回源，无需整本下载。
class FanqiePage extends ConsumerStatefulWidget {
  const FanqiePage({super.key});

  @override
  ConsumerState<FanqiePage> createState() => _FanqiePageState();
}

class _FanqiePageState extends ConsumerState<FanqiePage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  List<FeedSection> _feedSections = const [];
  bool _feedLoading = true;
  String? _feedError;

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  Future<void> _loadFeed() async {
    setState(() {
      _feedLoading = true;
      _feedError = null;
    });
    try {
      final secs = await _api.storeAppFeed();
      if (!mounted) return;
      setState(() {
        _feedSections = secs;
        _feedLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _feedLoading = false;
        _feedError = e.message;
      });
    }
  }

  void _openDetail(FeedBook b) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreBookDetailPage(fanqieId: b.id, title: b.title)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _loadFeed,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverToBoxAdapter(child: _buildSearchBar(context)),
            SliverToBoxAdapter(child: _buildBody(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  // ── 头部：渐变 + 标题 ────────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [MoStyle.darkPrimaryStrong, MoStyle.darkPrimary]
              : [MoStyle.primaryStrong, MoStyle.primary],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(22),
          bottomRight: Radius.circular(22),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('番茄书城',
              style: TextStyle(
                fontFamily: MoStyle.titleFont,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 1,
              )),
          const SizedBox(height: 4),
          Text('App 同源 · 实时热度排行 · 正文按需在线读',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: .85), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const StoreSearchPage())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded,
                  size: 20, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 8),
              Text('搜书名 / 搜作者',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_feedLoading) return _buildSkeleton();
    if (_feedError != null) {
      return ErrorRetry(message: _feedError!, onRetry: _loadFeed);
    }
    if (_feedSections.isEmpty) {
      return const EmptyView(
          icon: Icons.leaderboard_rounded, title: 'App feed 暂无内容');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final sec in _feedSections) ...[
          if (sec.books.length >= 3) _buildTop3(context, sec),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(sec.title,
                    style: TextStyle(
                        fontFamily: MoStyle.titleFont,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: MoStyle.strongOf(context))),
                if (sec.subtitle.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(sec.subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                for (var i = 0; i < sec.books.length; i++)
                  _FeedTile(
                      book: sec.books[i],
                      rank: sec.books.length >= 3 ? i + 1 : null,
                      onTap: () => _openDetail(sec.books[i])),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── 模块 TOP3 横滑大卡（仅当模块书够多时展示）────────────────────
  Widget _buildTop3(BuildContext context, FeedSection sec) {
    final top = sec.books.take(3).toList();
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: top.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final b = top[i];
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openDetail(b),
            child: Container(
              width: 288,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MoStyle.softOf(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: MoStyle.strongOf(context).withValues(alpha: .18)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Stack(
                      children: [
                        AspectRatio(
                            aspectRatio: 3 / 4,
                            child: BookCover(
                                url: b.cover.isEmpty ? null : b.cover,
                                title: b.title,
                                cacheWidth: 300)),
                        Positioned(left: 0, top: 0, child: _rankBadge(i + 1)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sec.title,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: MoStyle.strongOf(context))),
                        const SizedBox(height: 4),
                        Text(b.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: MoStyle.titleFont,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(b.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.outline)),
                        const Spacer(),
                        Text(b.rankScore.isNotEmpty ? b.rankScore : b.readCount,
                            style: TextStyle(
                                fontSize: 11,
                                color: MoStyle.strongOf(context))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _rankBadge(int n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: n <= 3 ? MoStyle.primaryStrong : Colors.black54,
        borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
      ),
      child: Text('TOP$n',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800)),
    );
  }

  Widget _buildSkeleton() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            height: 168,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          for (var i = 0; i < 6; i++)
            Container(
              height: 64,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 模块行卡：名次 + 封面 + 热度/在读 ────────────────────────────────
class _FeedTile extends StatelessWidget {
  const _FeedTile({required this.book, required this.onTap, this.rank});

  final FeedBook book;
  final int? rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rankColor = (rank != null && rank! <= 3)
        ? MoStyle.primaryStrong
        : Theme.of(context).colorScheme.outline;
    final metric = book.rankScore.isNotEmpty
        ? book.rankScore
        : (book.readCount.isNotEmpty ? book.readCount : book.score);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(rank == null ? '·' : '$rank',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: MoStyle.titleFont,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    color: rankColor,
                  )),
            ),
            SizedBox(
              width: 52,
              child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: BookCover(
                      url: book.cover.isEmpty ? null : book.cover,
                      title: book.title,
                      cacheWidth: 200)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: MoStyle.titleFont,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (book.category.isNotEmpty) ...[
                        Text(book.category,
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                        Text(' · ',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                      ],
                      Flexible(
                        child: Text(book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (metric.isNotEmpty)
              Text(metric,
                  style: TextStyle(
                      fontSize: 12, color: MoStyle.strongOf(context))),
          ],
        ),
      ),
    );
  }
}
