import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 番茄书城：UI 复刻番茄 App 书城（搜索行 + 频道行 + 频道内容）。
/// 「推荐」频道 = App 同源 feed（实时热度排行）；「小说」频道 = 官方分类榜单；
/// 正文按需回源（读到哪章拉哪章并缓存），整本可离线缓存。
class FanqiePage extends ConsumerStatefulWidget {
  const FanqiePage({super.key});

  @override
  ConsumerState<FanqiePage> createState() => _FanqiePageState();
}

class _FanqiePageState extends ConsumerState<FanqiePage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  // ── 频道 ──
  static const _channels = ['推荐', '小说', '听书', '经典', '视频', '知识', '漫画', '新书'];
  String _channel = '推荐';

  // ── 推荐频道：App 同源 feed ──
  List<FeedSection> _feedSections = const [];
  bool _feedLoading = true;
  String? _feedError;

  // ── 小说频道：官方分类榜单 ──
  List<RankGroup> _rankGroups = const [];
  bool _ranksLoading = false;
  String? _ranksError;
  String _selRankId = '';
  String _selRankName = '';
  List<StoreBook> _rankBooks = [];
  int _rankOffset = 0;
  bool _rankHasMore = true;
  bool _rankLoading = false;
  String? _rankBooksError;

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  // ── feed（推荐频道）────────────────────────────────────────────
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

  // ── 小说频道：榜单分组 + 榜单书籍 ────────────────────────────────
  Future<void> _loadRankGroups() async {
    setState(() {
      _ranksLoading = true;
      _ranksError = null;
    });
    try {
      final groups = await _api.storeRanks();
      if (!mounted) return;
      setState(() {
        _rankGroups = groups;
        _ranksLoading = false;
      });
      final first = groups.isNotEmpty ? groups.first.items.firstOrNull : null;
      if (first != null) _selectRank(first);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _ranksLoading = false;
        _ranksError = e.message;
      });
    }
  }

  void _selectRank(RankItem item) {
    setState(() {
      _selRankId = item.id;
      _selRankName = item.name;
      _rankBooks = [];
      _rankOffset = 0;
      _rankHasMore = true;
      _rankBooksError = null;
    });
    _loadRankBooks(reset: true);
  }

  Future<void> _loadRankBooks({bool reset = false}) async {
    if (_rankLoading || _selRankId.isEmpty) return;
    if (!reset && !_rankHasMore) return;
    setState(() {
      _rankLoading = true;
      if (reset) {
        _rankBooks = [];
        _rankOffset = 0;
      }
      _rankBooksError = null;
    });
    try {
      final books = await _api.storeRankBooks(_selRankId,
          offset: _rankOffset, limit: 15);
      if (!mounted) return;
      setState(() {
        _rankBooks = reset ? books : [..._rankBooks, ...books];
        _rankOffset += books.length;
        _rankHasMore = books.length >= 15;
        _rankLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _rankLoading = false;
        _rankBooksError = e.message;
      });
    }
  }

  Future<void> _refresh() async {
    if (_channel == 'rec') {
      await _loadFeed();
    } else {
      if (_rankBooks.isNotEmpty || _selRankId.isNotEmpty) {
        await _loadRankBooks(reset: true);
      } else {
        await _loadRankGroups();
      }
    }
  }

  void _openDetail(String fanqieId, String title) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreBookDetailPage(fanqieId: fanqieId, title: title)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildSearchRow(context),
            _buildChannelTabs(context),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: _channel == '小说' ? _novelBody(context) : _recBody(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 搜索行 ──────────────────────────────────────────────────────
  Widget _buildSearchRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const StoreSearchPage())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    );
  }

  // ── 频道行 ──────────────────────────────────────────────────────
  Widget _buildChannelTabs(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _channels.length,
        separatorBuilder: (context, index) => const SizedBox(width: 20),
        itemBuilder: (context, i) {
          final name = _channels[i];
          final active = name == _channel;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (active) return;
              if (name == '小说') {
                setState(() => _channel = '小说');
                if (_rankGroups.isEmpty && !_ranksLoading) _loadRankGroups();
              } else if (name == '推荐') {
                setState(() => _channel = '推荐');
              } else {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('$name 频道即将上线'),
                    behavior: SnackBarBehavior.floating));
              }
            },
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(name,
                      style: TextStyle(
                        fontSize: active ? 17 : 15,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                        color: active
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).colorScheme.outline,
                      )),
                  const SizedBox(height: 3),
                  Container(
                    height: 3,
                    width: 20,
                    decoration: BoxDecoration(
                      color: active
                          ? MoStyle.strongOf(context)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
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

  // ── 推荐频道（App 同源 feed）─────────────────────────────────────
  Widget _recBody(BuildContext context) {
    if (_feedLoading) return _buildSkeleton(context);
    if (_feedError != null) {
      return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ErrorRetry(message: _feedError!, onRetry: _loadFeed)
          ]);
    }
    if (_feedSections.isEmpty) {
      return ListView(children: const [
        EmptyView(icon: Icons.leaderboard_rounded, title: 'App feed 暂无内容')
      ]);
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        for (final sec in _feedSections) ...[
          _sectionHeader(context, sec.title, sec.subtitle),
          if (sec.books.length >= 3) _buildTop3(context, sec),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Column(
              children: [
                for (var i = 0; i < sec.books.length; i++)
                  _FeedTile(
                      title: sec.books[i].title,
                      author: sec.books[i].author,
                      cover: sec.books[i].cover,
                      metric: sec.books[i].rankScore.isNotEmpty
                          ? sec.books[i].rankScore
                          : sec.books[i].readCount,
                      finished: sec.books[i].finished,
                      rank: sec.books.length >= 3 ? i + 1 : null,
                      onTap: () => _openDetail(sec.books[i].id, sec.books[i].title)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(title,
              style: TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: MoStyle.strongOf(context))),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(subtitle,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTop3(BuildContext context, FeedSection sec) {
    final top = sec.books.take(3).toList();
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        itemCount: top.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final b = top[i];
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openDetail(b.id, b.title),
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

  // ── 小说频道（官方分类榜单）──────────────────────────────────────
  Widget _novelBody(BuildContext context) {
    if (_ranksLoading && _rankGroups.isEmpty) return _buildSkeleton(context);
    if (_ranksError != null && _rankGroups.isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
        ErrorRetry(message: _ranksError!, onRetry: _loadRankGroups)
      ]);
    }
    if (_rankGroups.isEmpty) {
      return ListView(children: const [
        EmptyView(icon: Icons.category_rounded, title: '暂无榜单分组')
      ]);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        // 榜单条目 chips（当前分组的所有榜单）
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: _currentGroupItems.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final item = _currentGroupItems[i];
              final selected = item.id == _selRankId;
              return ChoiceChip(
                label: Text(item.name),
                selected: selected,
                onSelected: (_) => _selectRank(item),
                selectedColor: MoStyle.strongOf(context),
                labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
              );
            },
          ),
        ),
        if (_rankBooksError != null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: ErrorRetry(message: _rankBooksError!, onRetry: () => _loadRankBooks(reset: true)),
          ),
        if (_selRankName.isNotEmpty && _rankBooks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Text(_selRankName,
                style: TextStyle(
                    fontFamily: MoStyle.titleFont,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: MoStyle.strongOf(context))),
          ),
        for (var i = 0; i < _rankBooks.length; i++)
          _FeedTile(
              title: _rankBooks[i].title,
              author: _rankBooks[i].author,
              cover: _rankBooks[i].cover,
              metric: _rankBooks[i].wordCount.isNotEmpty
                  ? _rankBooks[i].wordCount
                  : _rankBooks[i].readCount,
              finished: _rankBooks[i].finished,
              rank: i + 1,
              onTap: () => _openDetail(_rankBooks[i].id, _rankBooks[i].title)),
        if (_rankLoading)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_rankHasMore && _rankBooks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: OutlinedButton(
                onPressed: () => _loadRankBooks(),
                child: const Text('加载更多'),
              ),
            ),
          ),
      ],
    );
  }

  List<RankItem> get _currentGroupItems {
    for (final g in _rankGroups) {
      if (g.items.any((it) => it.id == _selRankId)) return g.items;
    }
    return _rankGroups.isNotEmpty ? _rankGroups.first.items : const [];
  }

  // ── 通用组件 ────────────────────────────────────────────────────
  Widget _buildSkeleton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          for (var i = 0; i < 8; i++)
            Container(
              height: 88,
              margin: const EdgeInsets.only(bottom: 10),
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

// ── 行卡：名次 + 封面 + 信息（feed/榜单通用）────────────────────────
class _FeedTile extends StatelessWidget {
  const _FeedTile({
    required this.title,
    required this.author,
    required this.cover,
    required this.metric,
    required this.finished,
    required this.onTap,
    this.rank,
  });

  final String title;
  final String author;
  final String cover;
  final String metric;
  final bool finished;
  final int? rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rankColor = (rank != null && rank! <= 3)
        ? MoStyle.primaryStrong
        : Theme.of(context).colorScheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
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
                  child: BookCover(url: cover, title: title, cacheWidth: 200)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: MoStyle.titleFont,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                      ),
                      if (metric.isNotEmpty) ...[
                        Text(' · ',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                        Text(metric,
                            style: TextStyle(
                                fontSize: 12,
                                color: MoStyle.strongOf(context))),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (finished)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text('完结',
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.outline)),
              ),
          ],
        ),
      ),
    );
  }
}
