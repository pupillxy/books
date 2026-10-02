import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 番茄书城：UI 复刻番茄 App 书城（搜索行 + 频道行 + 圆角榜单卡两列网格），
/// 数据全部来自 App 协议（unidbg 同源 feed）；正文按需回源。
class FanqiePage extends ConsumerStatefulWidget {
  const FanqiePage({super.key});

  @override
  ConsumerState<FanqiePage> createState() => _FanqiePageState();
}

class _FanqiePageState extends ConsumerState<FanqiePage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  static const _channels = ['推荐', '小说', '听书', '经典', '视频', '知识', '漫画', '新书'];

  List<FeedSection> _feedSections = const [];
  bool _feedLoading = true;
  String? _feedError;
  bool _rankExpanded = false; // 榜单卡默认前 8，可展开全部

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  Future<void> _loadFeed() async {
    setState(() {
      _feedLoading = true;
      _feedError = null;
      _rankExpanded = false;
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

  FeedSection? get _rankSection {
    for (final s in _feedSections) {
      if (s.title.contains('榜')) return s;
    }
    return _feedSections.isEmpty ? null : _feedSections.first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _loadFeed,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _buildSearchRow(context),
              _buildChannelTabs(context),
              _buildBody(context),
            ],
          ),
        ),
      ),
    );
  }

  // ── 搜索行：搜索条（番茄同款灰底圆角）───────────────────────────
  Widget _buildSearchRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StoreSearchPage())),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded,
                        size: 19, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 8),
                    Text('搜书名 / 搜作者',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 频道行：推荐 小说 听书 …（番茄同款，非「推荐」频道暂未接数据）──
  Widget _buildChannelTabs(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _channels.length,
        separatorBuilder: (context, index) => const SizedBox(width: 20),
        itemBuilder: (context, i) {
          final active = i == 0;
          return GestureDetector(
            onTap: () {
              if (!active) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${_channels[i]}频道即将上线'),
                    behavior: SnackBarBehavior.floating));
              }
            },
            child: Center(
              child: Text(_channels[i],
                  style: TextStyle(
                    fontSize: active ? 17 : 15,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    color: active
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.outline,
                  )),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_feedLoading) return _buildSkeleton(context);
    if (_feedError != null) {
      return ErrorRetry(message: _feedError!, onRetry: _loadFeed);
    }
    final rank = _rankSection;
    if (rank == null || rank.books.isEmpty) {
      return const EmptyView(
          icon: Icons.leaderboard_rounded, title: 'App feed 暂无内容');
    }

    final books = rank.books;
    final top8 = books.take(8).toList();
    final rest = books.length > 8 ? books.sublist(8) : const <FeedBook>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 榜单圆角卡（番茄同款两列网格）──────────────────────────
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: .55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text('热读榜',
                      style: TextStyle(
                          fontFamily: MoStyle.titleFont,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(width: 8),
                  if (rank.subtitle.isNotEmpty)
                    Text(rank.subtitle,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                      child: Column(
                          children: [
                        for (var i = 0; i < 4 && i < top8.length; i++)
                          _RankCell(book: top8[i], rank: i + 1)
                      ])),
                  Expanded(
                      child: Column(
                          children: [
                        for (var i = 4; i < 8 && i < top8.length; i++)
                          _RankCell(book: top8[i], rank: i + 1)
                      ])),
                ],
              ),
              if (rest.isNotEmpty && !_rankExpanded)
                TextButton(
                  onPressed: () => setState(() => _rankExpanded = true),
                  child: Text('展开全部 ${books.length} 本',
                      style: TextStyle(
                          fontSize: 13, color: MoStyle.strongOf(context))),
                ),
            ],
          ),
        ),
        // ── 展开的其余名次（行卡）──────────────────────────────────
        if (_rankExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Column(
              children: [
                for (var i = 0; i < rest.length; i++)
                  _FeedTile(
                      book: rest[i],
                      rank: i + 9,
                      onTap: () => _openDetail(rest[i])),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest
              .withValues(alpha: .55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                    child: Column(
                        children: [
                      for (var i = 0; i < 4; i++) _skCell(context)
                    ])),
                Expanded(
                    child: Column(
                        children: [
                      for (var i = 0; i < 4; i++) _skCell(context)
                    ])),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _skCell(BuildContext context) {
    return Container(
      height: 92,
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
              width: 56,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              )),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    height: 14,
                    width: double.infinity,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest),
                const SizedBox(height: 8),
                Container(
                    height: 11,
                    width: .6 * 300,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 榜单网格单元（番茄同款：封面 + 大名次 + 两行书名 + 底行信息）─────
class _RankCell extends StatelessWidget {
  const _RankCell({required this.book, required this.rank});

  final FeedBook book;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final metric = book.rankScore.isNotEmpty
        ? book.rankScore
        : (book.readCount.isNotEmpty ? book.readCount : '');
    final status = book.finished ? '完结' : '新书';
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              StoreBookDetailPage(fanqieId: book.id, title: book.title))),
      child: SizedBox(
        height: 96,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 54,
              child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: BookCover(
                      url: book.cover.isEmpty ? null : book.cover,
                      title: book.title,
                      cacheWidth: 200)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$rank',
                          style: TextStyle(
                              fontFamily: MoStyle.titleFont,
                              fontSize: 19,
                              height: 1.0,
                              fontWeight: FontWeight.w900,
                              color: Theme.of(context).colorScheme.onSurface)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.25,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    metric.isNotEmpty
                        ? metric
                        : '$status · ${book.category}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 展开后的行卡 ────────────────────────────────────────────────────
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
                  Text(metric,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
