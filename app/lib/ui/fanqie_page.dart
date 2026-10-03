import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../core/store_pref.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_comic_detail_page.dart';
import 'store_rank_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 番茄书城：UI 复刻番茄 App 书城。
/// 「推荐」频道 = App 同源 feed（实时热度排行）+ 官方近似分榜；
/// 「小说」频道 = 官方筛选瀑布流（cell/change + selected_items，10/04 协议定案）；
/// 「漫画」频道 = 官方漫画瀑布流（cell/change tab_type=9），点开即看。
class FanqiePage extends ConsumerStatefulWidget {
  const FanqiePage({super.key});

  @override
  ConsumerState<FanqiePage> createState() => _FanqiePageState();
}

class _FanqiePageState extends ConsumerState<FanqiePage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  // ── 频道（协议未接的频道不保留，避免死 tab）──
  static const _channels = ['推荐', '小说', '漫画'];
  String _channel = '推荐';

  // ── 推荐频道：猜你喜欢瀑布流（cell/change 翻页，全程不依赖 tab/v）──
  List<FeedBook> _guessBooks = const [];
  int _guessOffset = 0;
  bool _guessHasMore = true;
  bool _guessLoading = false;
  String? _guessError;
  Timer? _guessRetryTimer;

  // ── 推荐频道：榜单卡子榜 ──
  static const _rankTabs = ['推荐榜', '完本榜', '巅峰榜', '新书榜'];
  static const _boardKeys = {
    0: 'recommend',
    1: 'finished',
    2: 'peak',
    3: 'new',
  };
  int _rankTabIdx = 0;
  int _rankPage = 0; // 榜单卡横滑页码（官方同构：16 本两页，跟 tab 一样左右翻）
  final Map<String, List<LibraryBook>> _boardBooks = {};
  final Set<String> _boardLoading = {};
  final Map<String, String?> _boardErrors = {};

  // ── 小说频道：官方筛选瀑布流（筛选值 = 官方 selected_items，10/04 实测）──
  static const _novelFilterOptions = [
    ('完结', 'finished'),
    ('一年内上架', 'online_in_past_one_year'),
    ('200万字以上', 'word_num_gt_200w'),
    ('男生', 'male'),
    ('女生', 'female'),
  ];
  final Set<String> _novelFilters = {};
  bool _novelFiltersInit = false;
  List<FeedBook> _novelBooks = const [];
  int _novelOffset = 0;
  bool _novelHasMore = true;
  bool _novelLoading = false;
  String? _novelError;
  Timer? _novelRetryTimer;
  int _novelReqGen = 0; // 请求代数：切筛选/刷新可打断在途请求，旧响应作废

  // ── 漫画频道：官方漫画瀑布流（tab_type=9）──
  List<ComicBook> _comicBooks = const [];
  int _comicOffset = 0;
  bool _comicHasMore = true;
  bool _comicLoading = false;
  String? _comicError;
  Timer? _comicRetryTimer;
  int _comicReqGen = 0;

  @override
  void initState() {
    super.initState();
    _ensureBoard(_boardKeys[0]!);
    _loadGuessPage(reset: true);
  }

  @override
  void dispose() {
    _guessRetryTimer?.cancel();
    _novelRetryTimer?.cancel();
    _comicRetryTimer?.cancel();
    super.dispose();
  }

  // ── 猜你喜欢瀑布流（官方 cell/change 翻页；offset 由上游 next_offset 驱动）──
  Future<void> _loadGuessPage({bool reset = false}) async {
    if (_guessLoading) return;
    if (!reset && !_guessHasMore) return;
    setState(() {
      _guessLoading = true;
      if (reset) {
        _guessBooks = const [];
        _guessOffset = 0;
        _guessHasMore = true;
      }
      _guessError = null;
    });
    try {
      final r = await _api.storeAppFeedPage(
          cellId: '', planId: '', offset: reset ? 0 : _guessOffset);
      if (!mounted) return;
      setState(() {
        _guessBooks = reset ? r.books : [..._guessBooks, ...r.books];
        _guessOffset = r.nextOffset;
        _guessHasMore = r.hasMore;
        _guessLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _guessLoading = false;
        _guessError = e.message;
      });
      // 静默自动重试（server 负缓存兜底），恢复后自动回填
      _guessRetryTimer?.cancel();
      _guessRetryTimer = Timer(const Duration(seconds: 90), () {
        if (mounted && _guessError != null) _loadGuessPage(reset: reset);
      });
    }
  }

  // ── 小说频道：官方筛选瀑布流 ─────────────────────────────────────
  void _ensureNovelFilters() {
    if (_novelFiltersInit) return;
    _novelFiltersInit = true;
    // 频道偏好联动：男频默认「男生」筛选，女频默认「女生」
    _novelFilters.add(
        ref.read(storeGenderProvider) == '0' ? 'female' : 'male');
  }

  Future<void> _loadNovelPage({bool reset = false}) async {
    // 翻页请求受 loading/hasMore 守卫；筛选与刷新（reset）随时可打断在途请求
    if (!reset && (_novelLoading || !_novelHasMore)) return;
    _ensureNovelFilters();
    final gen = ++_novelReqGen;
    setState(() {
      _novelLoading = true;
      if (reset) {
        _novelBooks = const [];
        _novelOffset = 0;
        _novelHasMore = true;
      }
      _novelError = null;
    });
    try {
      final r = await _api.storeNovelFeed(
          filters: _novelFilters.toList().join(','),
          offset: reset ? 0 : _novelOffset);
      if (!mounted || gen != _novelReqGen) return;
      setState(() {
        _novelBooks = reset ? r.books : [..._novelBooks, ...r.books];
        _novelOffset = r.nextOffset;
        _novelHasMore = r.hasMore;
        _novelLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _novelReqGen) return;
      setState(() {
        _novelLoading = false;
        _novelError = e.message;
      });
      _novelRetryTimer?.cancel();
      _novelRetryTimer = Timer(const Duration(seconds: 90), () {
        if (mounted && _novelError != null) _loadNovelPage(reset: reset);
      });
    }
  }

  void _toggleNovelFilter(String value) {
    setState(() {
      if (_novelFilters.contains(value)) {
        _novelFilters.remove(value);
      } else {
        // 性别组内互斥（官方面板同语义）
        if (value == 'male') _novelFilters.remove('female');
        if (value == 'female') _novelFilters.remove('male');
        _novelFilters.add(value);
      }
    });
    _loadNovelPage(reset: true);
  }

  // ── 漫画频道：官方漫画瀑布流 ─────────────────────────────────────
  Future<void> _loadComicPage({bool reset = false}) async {
    if (!reset && (_comicLoading || !_comicHasMore)) return;
    final gen = ++_comicReqGen;
    setState(() {
      _comicLoading = true;
      if (reset) {
        _comicBooks = const [];
        _comicOffset = 0;
        _comicHasMore = true;
      }
      _comicError = null;
    });
    try {
      final r = await _api.storeComicFeed(offset: reset ? 0 : _comicOffset);
      if (!mounted || gen != _comicReqGen) return;
      setState(() {
        _comicBooks = reset ? r.items : [..._comicBooks, ...r.items];
        _comicOffset = r.nextOffset;
        _comicHasMore = r.hasMore;
        _comicLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _comicReqGen) return;
      setState(() {
        _comicLoading = false;
        _comicError = e.message;
      });
      _comicRetryTimer?.cancel();
      _comicRetryTimer = Timer(const Duration(seconds: 90), () {
        if (mounted && _comicError != null) _loadComicPage(reset: reset);
      });
    }
  }

  Future<void> _refresh() async {
    switch (_channel) {
      case '小说':
        await _loadNovelPage(reset: true);
      case '漫画':
        await _loadComicPage(reset: true);
      default:
        _ensureBoard(_boardKeys[_rankTabIdx]!);
        await _loadGuessPage(reset: true);
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
                child: switch (_channel) {
                  '小说' => _novelBody(context),
                  '漫画' => _comicBody(context),
                  _ => _recBody(context),
                },
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
              setState(() => _channel = name);
              if (name == '小说') {
                _loadNovelPage(reset: _novelBooks.isEmpty);
              } else if (name == '漫画') {
                _loadComicPage(reset: _comicBooks.isEmpty);
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
    // feed 拉取失败不再整页报错：完本/巅峰/新书榜与瀑布流重试照常可用，
    // 推荐榜和瀑布流各自在原位显示局部重试（server 风控自愈后点重试即恢复）
    if (_guessLoading && _guessBooks.isEmpty && _guessError == null) {
      return _buildSkeleton(context);
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // 滚动近底部自动加载猜你喜欢瀑布流下一页（官方同构）
        if (n.metrics.axis == Axis.vertical &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 800) {
          _loadGuessPage();
        }
        return false;
      },
      child: ListView(
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
                          setState(() {
                            _rankTabIdx = i;
                            _rankPage = 0;
                          });
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
      ),
    );
  }

  // ── 子榜数据 ────────────────────────────────────────────────────
  List<_RankEntry> get _rankEntries {
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

  bool get _rankTabLoading => _boardLoading.contains(_boardKeys[_rankTabIdx]!);

  String? get _rankTabError {
    final k = _boardKeys[_rankTabIdx]!;
    return _boardLoading.contains(k) ? null : _boardErrors[k];
  }

  void _ensureBoard(String key) {
    if (key.isEmpty || _boardBooks.containsKey(key) || _boardLoading.contains(key)) {
      return;
    }
    _boardLoading.add(key);
    setState(() => _boardErrors[key] = null);
    _api.storeFeaturedBooks(key,
            gender: ref.read(storeGenderProvider), limit: 16).then((books) {
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
                _ensureBoard(_boardKeys[_rankTabIdx]!);
                setState(() {});
              })
            : const EmptyView(
                icon: Icons.leaderboard_rounded, title: '该榜单暂无内容'),
      );
    }

    // 官方同构：16 本分两页左右横滑（跟 tab 一样一页页翻，非滚动条），
    // 每页 2 列 × 4 行 = 8 本；下方瀑布流是独立 feed，与子榜切换无关
    final shown = entries.take(16).toList();
    final pageBooks = <List<_RankEntry>>[
      shown.take(8).toList(),
      if (shown.length > 8) shown.sublist(8),
    ];

    return Column(
      children: [
        SizedBox(
          height: 4 * 96.0,
          child: PageView(
            onPageChanged: (page) => setState(() => _rankPage = page),
            children: [
              for (var p = 0; p < pageBooks.length; p++)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        child: Column(children: [
                      for (var i = 0; i < 4 && i < pageBooks[p].length; i++)
                        _RankCell(
                            book: pageBooks[p][i], rank: p * 8 + i + 1)
                    ])),
                    Expanded(
                        child: Column(children: [
                      for (var i = 4; i < 8 && i < pageBooks[p].length; i++)
                        _RankCell(
                            book: pageBooks[p][i], rank: p * 8 + i + 1)
                    ])),
                  ],
                ),
            ],
          ),
        ),
        if (pageBooks.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var p = 0; p < pageBooks.length; p++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p == _rankPage
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.35),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 推荐频道：榜单卡下方的「猜你喜欢」瀑布流 ─────────────────────
  // 数据走 cell/change 翻页（offset 由上游 next_offset 驱动），与 tab/v 和子榜切换零关联。
  Widget _buildRecFeed(BuildContext context) {
    if (_guessBooks.isEmpty) {
      if (_guessLoading) {
        return const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      }
      if (_guessError != null) {
        return Padding(
            padding: const EdgeInsets.fromLTRB(14, 20, 14, 0),
            child: Row(children: [
              Icon(Icons.cloud_off_rounded,
                  size: 16, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('猜你喜欢暂时不可用，稍后会自动恢复',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.outline))),
              TextButton(
                  onPressed: () => _loadGuessPage(reset: true),
                  child: const Text('重试', style: TextStyle(fontSize: 12.5))),
            ]));
      }
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 4),
          child: Text('猜你喜欢',
              style: TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: MoStyle.strongOf(context))),
        ),
        for (var i = 0; i < _guessBooks.length; i++)
          _FeedTile(
              title: _guessBooks[i].title,
              author: _guessBooks[i].author,
              cover: _guessBooks[i].cover,
              metric: _guessBooks[i].rankScore.isNotEmpty
                  ? _guessBooks[i].rankScore
                  : _guessBooks[i].readCount,
              finished: _guessBooks[i].finished,
              onTap: () =>
                  _openDetail(_guessBooks[i].id, _guessBooks[i].title)),
        if (_guessLoading)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ],
    );
  }

  // ── 小说频道：官方筛选条 + 双列瀑布流（tab_type=25 协议）────────────
  Widget _novelBody(BuildContext context) {
    if (_novelLoading && _novelBooks.isEmpty && _novelError == null) {
      return _buildSkeleton(context);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 800) {
          _loadNovelPage();
        }
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildNovelChips(context)),
          if (_novelError != null && _novelBooks.isEmpty)
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.all(14),
              child: ErrorRetry(
                  message: _novelError!, onRetry: () => _loadNovelPage(reset: true)),
            ))
          else if (_novelBooks.isEmpty && !_novelLoading)
            const SliverToBoxAdapter(
                child: EmptyView(icon: Icons.auto_stories_rounded, title: '该筛选组合暂无书籍'))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 32),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.55,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _NovelCard(
                      book: _novelBooks[i],
                      onTap: () =>
                          _openDetail(_novelBooks[i].id, _novelBooks[i].title)),
                  childCount: _novelBooks.length,
                ),
              ),
            ),
          if (_novelLoading)
            const SliverToBoxAdapter(
                child: Padding(
              padding: EdgeInsets.all(14),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )),
        ],
      ),
    );
  }

  // ── 筛选条（官方快捷栏同构：完结/一年内上架/200万字以上/男生/女生）──
  Widget _buildNovelChips(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _novelFilterOptions.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (label, value) = _novelFilterOptions[i];
          final selected = _novelFilters.contains(value);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleNovelFilter(value),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? MoStyle.strongOf(context).withValues(alpha: .12)
                    : Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: .6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? MoStyle.strongOf(context)
                        : Theme.of(context).colorScheme.onSurface,
                  )),
            ),
          );
        },
      ),
    );
  }

  // ── 漫画频道：双列卡瀑布流（tab_type=9 协议）──────────────────────
  Widget _comicBody(BuildContext context) {
    if (_comicLoading && _comicBooks.isEmpty && _comicError == null) {
      return _buildSkeleton(context);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 800) {
          _loadComicPage();
        }
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_comicError != null && _comicBooks.isEmpty)
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.all(14),
              child: ErrorRetry(
                  message: _comicError!, onRetry: () => _loadComicPage(reset: true)),
            ))
          else if (_comicBooks.isEmpty && !_comicLoading)
            const SliverToBoxAdapter(
                child: EmptyView(icon: Icons.image_rounded, title: '漫画频道暂无内容'))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 32),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.55,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _ComicCard(
                      book: _comicBooks[i],
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => StoreComicDetailPage(
                              bookId: _comicBooks[i].id,
                              title: _comicBooks[i].title)))),
                  childCount: _comicBooks.length,
                ),
              ),
            ),
          if (_comicLoading)
            const SliverToBoxAdapter(
                child: Padding(
              padding: EdgeInsets.all(14),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )),
        ],
      ),
    );
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
  });

  final String title;
  final String author;
  final String cover;
  final String metric;
  final bool finished;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Row(
          children: [
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

// ── 双列大卡：小说频道/漫画频道共用骨架（官方瀑布流同构）──────────────
class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.title,
    required this.cover,
    required this.subtitle,
    this.score = '',
    required this.onTap,
  });

  final String title;
  final String cover;
  final String subtitle;
  final String score; // 封面左下角评分角标（如 "9.4分"）
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: BookCover(
                    url: cover.isEmpty ? null : cover,
                    title: title,
                    cacheWidth: 400),
              ),
              if (score.isNotEmpty)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .45),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(score,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 13.5,
                  height: 1.25,
                  fontWeight: FontWeight.w600)),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline)),
            ),
        ],
      ),
    );
  }
}

class _NovelCard extends StatelessWidget {
  const _NovelCard({required this.book, required this.onTap});

  final FeedBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (book.category.isNotEmpty) book.category,
      if (book.wordCountText.isNotEmpty) book.wordCountText,
      if (book.readCount.isNotEmpty) book.readCount,
    ].join(' · ');
    return _ChannelCard(
        title: book.title,
        cover: book.cover,
        subtitle: sub,
        score: book.score.isEmpty ? '' : '${book.score}分',
        onTap: onTap);
  }
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({required this.book, required this.onTap});

  final ComicBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (book.category.isNotEmpty) book.category,
      if (book.updateTag.isNotEmpty) book.updateTag,
      if (book.wordCount.isNotEmpty) book.wordCount,
      if (book.readCount.isNotEmpty) book.readCount,
    ].join(' · ');
    return _ChannelCard(
        title: book.title,
        cover: book.cover,
        subtitle: sub,
        score: book.score.isEmpty ? '' : '${book.score}分',
        onTap: onTap);
  }
}
