import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_rank_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 番茄书城：UI 复刻番茄 App 书城。
/// 「推荐」频道 = App 同源 feed（实时热度排行）+ 官方近似分榜；
/// 「小说」频道 = 官方分类榜单；正文按需回源，可整本离线缓存。
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

  // ── 推荐频道：榜单卡子榜 ──
  static const _rankTabs = ['推荐榜', '完本榜', '巅峰榜', '新书榜'];
  static const _boardKeys = {0: '', 1: 'finished', 2: 'peak', 3: 'new'};
  int _rankTabIdx = 0;
  final Map<String, List<LibraryBook>> _boardBooks = {};
  final Set<String> _boardLoading = {};
  final Map<String, String?> _boardErrors = {};

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

  // ── feed（推荐榜数据源）────────────────────────────────────────
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
      final books =
          await _api.storeRankBooks(_selRankId, offset: _rankOffset, limit: 15);
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
    if (_channel == '小说') {
      if (_rankBooks.isNotEmpty || _selRankId.isNotEmpty) {
        await _loadRankBooks(reset: true);
      } else {
        await _loadRankGroups();
      }
    } else {
      await _loadFeed();
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
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const StoreSearchPage())),
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

  // ── 推荐频道（榜单卡：子榜切换 + 两列网格）────────────────────────
  Widget _recBody(BuildContext context) {
    if (_feedLoading && _rankTabIdx == 0) return _buildSkeleton(context);
    if (_feedError != null && _rankTabIdx == 0) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
        ErrorRetry(message: _feedError!, onRetry: _loadFeed)
      ]);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: .55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 子榜 tab 行 + 完整榜单入口
              SizedBox(
                height: 30,
                child: Row(
                  children: [
                    for (var i = 0; i < _rankTabs.length; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() => _rankTabIdx = i);
                          _ensureBoard(_boardKeys[i]!);
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Text(_rankTabs[i],
                              style: TextStyle(
                                  fontSize: _rankTabIdx == i ? 15.5 : 13.5,
                                  fontWeight: _rankTabIdx == i
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: _rankTabIdx == i
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context)
                                          .colorScheme
                                          .outline)),
                        ),
                      ),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const StoreRankPage())),
                      child: Row(children: [
                        Text('完整榜单',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                        Icon(Icons.chevron_right_rounded,
                            size: 15,
                            color: Theme.of(context).colorScheme.outline),
                      ]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _buildRankGrid(context),
            ],
          ),
        ),
        _buildRecFeed(context),
      ],
    );
  }

  // ── 子榜数据 ────────────────────────────────────────────────────
  List<_RankEntry> get _rankEntries {
    if (_rankTabIdx == 0) {
      // 推荐榜：App 同源 feed 排行榜
      for (final sec in _feedSections) {
        if (sec.title.contains('榜')) {
          return sec.books
              .map((b) => _RankEntry(
                  id: b.id,
                  title: b.title,
                  author: b.author,
                  cover: b.cover,
                  metric: b.rankScore.isNotEmpty ? b.rankScore : b.readCount,
                  finished: b.finished))
              .toList();
        }
      }
      return const [];
    }
    final key = _boardKeys[_rankTabIdx]!;
    return (_boardBooks[key] ?? const <LibraryBook>[])
        .map((b) => _RankEntry(
            id: b.id,
            title: b.title,
            author: b.author,
            cover: b.cover,
            metric: b.readCount.isNotEmpty ? b.readCount : b.wordCount,
            finished: b.finished))
        .toList();
  }

  bool get _rankTabLoading {
    if (_rankTabIdx == 0) return _feedLoading;
    return _boardLoading.contains(_boardKeys[_rankTabIdx]!);
  }

  String? get _rankTabError {
    if (_rankTabIdx == 0) return _feedError;
    final k = _boardKeys[_rankTabIdx]!;
    return _boardLoading.contains(k) ? null : _boardErrors[k];
  }

  void _ensureBoard(String key) {
    if (key.isEmpty || _boardBooks.containsKey(key) || _boardLoading.contains(key)) {
      return;
    }
    _boardLoading.add(key);
    setState(() => _boardErrors[key] = null);
    _api.storeFeaturedBooks(key, limit: 16).then((books) {
      if (!mounted) return;
      setState(() {
        _boardBooks[key] = books;
        _boardLoading.remove(key);
      });
    }).catchError((e) {
      if (!mounted) return;
      setState(() {
        _boardLoading.remove(key);
        _boardErrors[key] = e is ApiException ? e.message : '$e';
      });
    });
  }

  Widget _buildRankGrid(BuildContext context) {
    final entries = _rankEntries;
    if (_rankTabLoading && entries.isEmpty) {
      return Column(
        children: [
          for (var i = 0; i < 4; i++) _skCell(context),
        ],
      );
    }
    final err = _rankTabError;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: (err != null)
            ? ErrorRetry(message: err, onRetry: () {
                if (_rankTabIdx == 0) {
                  _loadFeed();
                } else {
                  _ensureBoard(_boardKeys[_rankTabIdx]!);
                  setState(() {});
                }
              })
            : const EmptyView(
                icon: Icons.leaderboard_rounded, title: '该榜单暂无内容'),
      );
    }

    final top8 = entries.take(8).toList();

    // 官方同构：榜单卡只展示 8 本（2×4），不做 9-16 展开——
    // 下方瀑布流是独立 feed，与子榜切换无关（10/03 官方 App 实测）
    return Row(
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
    );
  }

  // ── 推荐频道：榜单卡下方的独立瀑布流（App 同源 feed 分区）────────
  // 与子榜切换完全解耦：切 完本榜/巅峰榜 只刷卡片，此区域保持不变（官方同构）。
  Widget _buildRecFeed(BuildContext context) {
    if (_feedSections.isEmpty) {
      if (_feedLoading) {
        return const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      }
      if (_feedError != null) {
        return Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: ErrorRetry(message: _feedError!, onRetry: _loadFeed));
      }
      return const SizedBox.shrink();
    }
    final ranked =
        _feedSections.where((s) => s.title.contains('榜')).toList();
    final feedSecs =
        _feedSections.where((s) => !s.title.contains('榜')).toList();
    // 兜底：上游只下发榜单分区时，把推荐榜第 9 名起固定挂在此处
    //（锚定推荐榜本身，切子榜不影响）
    final sections = feedSecs.isNotEmpty
        ? feedSecs
        : (ranked.isNotEmpty
            ? [
                FeedSection(
                    title: ranked.first.title,
                    subtitle: ranked.first.subtitle,
                    books: ranked.first.books.skip(8).toList())
              ]
            : const <FeedSection>[]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final sec in sections)
          if (sec.books.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 4),
              child: Text(sec.title,
                  style: TextStyle(
                      fontFamily: MoStyle.titleFont,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: MoStyle.strongOf(context))),
            ),
            for (var i = 0; i < sec.books.length; i++)
              _FeedTile(
                  title: sec.books[i].title,
                  author: sec.books[i].author,
                  cover: sec.books[i].cover,
                  metric: sec.books[i].rankScore.isNotEmpty
                      ? sec.books[i].rankScore
                      : sec.books[i].readCount,
                  finished: sec.books[i].finished,
                  onTap: () =>
                      _openDetail(sec.books[i].id, sec.books[i].title)),
          ],
      ],
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
            child: ErrorRetry(
                message: _rankBooksError!,
                onRetry: () => _loadRankBooks(reset: true)),
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
              onTap: () =>
                  _openDetail(_rankBooks[i].id, _rankBooks[i].title)),
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
      padding: const EdgeInsets.all(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: .55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                    child: Column(children: [
                  for (var i = 0; i < 4; i++) _skCell(context)
                ])),
                Expanded(
                    child: Column(children: [
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
                    width: 180,
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

// ── 子榜条目视图模型 ────────────────────────────────────────────────
class _RankEntry {
  final String id;
  final String title;
  final String author;
  final String cover;
  final String metric;
  final bool finished;

  const _RankEntry({
    required this.id,
    required this.title,
    required this.author,
    required this.cover,
    required this.metric,
    required this.finished,
  });
}

// ── 榜单网格单元（番茄同款：封面 + 大名次 + 两行书名 + 底行信息）─────
class _RankCell extends StatelessWidget {
  const _RankCell({required this.book, required this.rank});

  final _RankEntry book;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final metric = book.metric;
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
                    metric.isNotEmpty ? metric : '$status · ${book.author}',
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
                        Flexible(
                          child: Text(metric,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: MoStyle.strongOf(context))),
                        ),
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
