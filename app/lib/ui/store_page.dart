import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'store_library_page.dart';
import 'store_rank_page.dart';
import 'store_search_page.dart';
import 'widgets.dart';

/// 书城首页（「墨笺」风）：搜索 + 榜单 Tab/频道切换 + 焦点轮播（当前榜 Top3）+
/// 分类直达 + 完本精选/新书速递横向书架 + 巅峰榜速览 + 全屏三列网格（滚动加载更多）。
/// 数据全部来自番茄网页端（书库热门近似榜单，A 方案）；官方分类榜单在「完整榜单」二级页。
/// 侧栏区块各自独立容错：单个加载失败仅隐藏该区块，不影响主网格。
class StorePage extends ConsumerStatefulWidget {
  const StorePage({super.key});

  @override
  ConsumerState<StorePage> createState() => _StorePageState();
}

class _StorePageState extends ConsumerState<StorePage> {
  List<FeaturedBoard> _boards = const [];
  int _boardIdx = 0;
  String _gender = '1'; // 频道：'1' 男生 '0' 女生，影响全部区块

  final _books = <LibraryBook>[]; // 当前榜单（焦点轮播 + 主网格）
  final _finished = <LibraryBook>[]; // 完本精选书架
  final _newBooks = <LibraryBook>[]; // 新书速递书架
  final _peak = <LibraryBook>[]; // 巅峰榜速览
  List<LibCategory> _mainCats = const []; // 分类直达（书库「主分类」组）

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  static const _pageSize = 18;

  // 焦点轮播：当前榜 Top3 自动轮播
  final _heroCtrl = PageController();
  int _heroIdx = 0;
  Timer? _heroTimer;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _heroCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBoards() async {
    try {
      final boards = await _api.storeFeaturedBoards();
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _boardIdx = 0;
      });
      _fetchFirst(silent: false);
      _loadSecondary();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadBooks() => _fetchFirst(silent: false);

  /// 拉取当前榜单第一页；[silent] 为 true 时不闪加载圈（详情页返回刷新角标用）
  Future<void> _fetchFirst({required bool silent}) async {
    if (_boards.isEmpty) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final books = await _api.storeFeaturedBooks(
        _boards[_boardIdx].key,
        gender: _gender,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted) return;
      // 静默刷新（详情页返回）不打断当前轮播页，仅在新数据页数变少时回位
      final n = books.length >= 3 ? 3 : books.length;
      final resetHero = !silent || _heroIdx >= n;
      setState(() {
        _books
          ..clear()
          ..addAll(books);
        _hasMore = books.length >= _pageSize;
        _loading = false;
        if (resetHero) _heroIdx = 0;
      });
      if (resetHero && _heroCtrl.hasClients) _heroCtrl.jumpToPage(0);
      _restartHeroTimer();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) _error = e.message;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _boards.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final books = await _api.storeFeaturedBooks(
        _boards[_boardIdx].key,
        gender: _gender,
        offset: _books.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _books.addAll(books);
        _hasMore = books.length >= _pageSize;
        _loadingMore = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 侧栏区块（分类直达 / 完本精选 / 新书速递 / 巅峰榜速览）并行加载
  Future<void> _loadSecondary() async {
    await Future.wait([
      _loadSideBoard('finished', _finished, 8),
      _loadSideBoard('new', _newBooks, 8),
      _loadSideBoard('peak', _peak, 5),
      _loadCats(),
    ]);
  }

  Future<void> _loadSideBoard(String key, List<LibraryBook> sink, int limit) async {
    try {
      final books = await _api.storeFeaturedBooks(key, gender: _gender, offset: 0, limit: limit);
      if (!mounted) return;
      setState(() {
        sink
          ..clear()
          ..addAll(books);
      });
    } on ApiException {
      // 静默：区块留空即隐藏
    }
  }

  Future<void> _loadCats() async {
    try {
      final cats = await _api.storeLibraryCategories(_gender);
      if (!mounted) return;
      setState(() => _mainCats = cats.where((c) => c.label == '主分类').toList());
    } on ApiException {
      // 静默：分类直达区块隐藏
    }
  }

  /// 从详情页返回后静默刷新（详情页进入即自动入库，返回后更新「在库」角标）
  Future<void> _reloadSilent() async {
    await _fetchFirst(silent: true);
    _loadSideBoard('finished', _finished, 8);
    _loadSideBoard('new', _newBooks, 8);
    _loadSideBoard('peak', _peak, 5);
  }

  void _switchBoard(int i) {
    if (i == _boardIdx) return;
    setState(() => _boardIdx = i);
    _loadBooks();
  }

  void _switchGender(String g) {
    if (_gender == g) return;
    setState(() => _gender = g);
    _loadBooks();
    _loadSecondary();
  }

  // ---------- 焦点轮播 ----------

  int get _heroCount => _books.length >= 3 ? 3 : _books.length;

  void _restartHeroTimer() {
    _heroTimer?.cancel();
    _heroTimer = null;
    if (_heroCount < 2) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_heroCtrl.hasClients) return;
      final cur = _heroCtrl.page?.round() ?? 0;
      _heroCtrl.animateToPage(
        (cur + 1) % _heroCount,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ---------- 跳转 ----------

  void _openBook(LibraryBook book) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
        ))
        .then((_) {
      if (mounted) _reloadSilent();
    });
  }

  void _openRankPage() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StoreRankPage()));
  }

  void _openLibrary({String? catGroup, int catId = -1, int status = -1, int sort = 0}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StoreLibraryPage(
        initialGender: _gender,
        initialCatGroup: catGroup ?? '',
        initialCatId: catId,
        initialStatus: status,
        initialSort: sort,
      ),
    ));
  }

  Future<void> _refresh() {
    if (_boards.isEmpty) return _loadBoards();
    return Future.wait([_loadBooks(), _loadSecondary()]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.of(context).devicePixelRatio;

    // 全屏三列网格度量：与书库页一致
    const hPad = 18.0;
    const gap = 10.0;
    final screenW = MediaQuery.of(context).size.width;
    final coverW = (screenW - hPad * 2 - gap * 2) / 3;
    final coverH = coverW * 1.3;
    final cardH = coverH + 58; // 封面固定高 + 6 间距 + 52 文字区
    final ratio = coverW / cardH;
    final heroN = _heroCount;

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
          return false;
        },
        child: RefreshIndicator(
          color: cs.primary,
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ---------- 页头：衬线大标题 + 完整榜单入口（固定常驻）----------
              MoPinnedHeader(
                child: PageHeader(
                  title: '书城',
                  actions: [
                    IconButton(
                      tooltip: '完整榜单',
                      onPressed: _openRankPage,
                      icon: Icon(Icons.leaderboard_outlined,
                          size: 22, color: MoStyle.strongOf(context)),
                    ),
                  ],
                ),
              ),
              // ---------- 搜索框（真搜索）+ 书库入口 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(13),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => const StoreSearchPage())),
                          child: Container(
                            height: 42,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: MoStyle.inputFillOf(context),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.search, size: 18, color: cs.outline),
                                const SizedBox(width: 8),
                                Text('搜索书名 / 作者',
                                    style: TextStyle(fontSize: 13, color: cs.outline)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 书库入口
                      InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () => _openLibrary(),
                        child: Container(
                          height: 42,
                          width: 46,
                          decoration: BoxDecoration(
                            color: cs.brightness == Brightness.dark
                                ? MoStyle.darkPrimarySoft
                                : MoStyle.primarySoft,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(Icons.auto_stories_outlined,
                              size: 20, color: MoStyle.strongOf(context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---------- 榜单 Tab + 男/女频道切换 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (var i = 0; i < _boards.length; i++)
                                MoUnderlineTab(
                                  label: _boards[i].name,
                                  selected: i == _boardIdx,
                                  hPad: 8,
                                  onTap: () => _switchBoard(i),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _GenderToggle(value: _gender, onChanged: _switchGender),
                    ],
                  ),
                ),
              ),
              // ---------- 焦点轮播：当前榜 Top3 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: SizedBox(
                    height: 156,
                    child: _books.isEmpty
                        ? const _HeroSkeleton()
                        : Stack(
                            children: [
                              Positioned.fill(
                                child: PageView.builder(
                                  controller: _heroCtrl,
                                  itemCount: heroN,
                                  onPageChanged: (i) {
                                    setState(() => _heroIdx = i);
                                    _restartHeroTimer();
                                  },
                                  itemBuilder: (_, i) => _HeroCard(
                                    book: _books[i],
                                    boardName: _boards[_boardIdx].name,
                                    rank: i + 1,
                                    onTap: () => _openBook(_books[i]),
                                  ),
                                ),
                              ),
                              if (heroN > 1)
                                Positioned(
                                  bottom: 10,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (var i = 0; i < heroN; i++)
                                          AnimatedContainer(
                                            duration: const Duration(milliseconds: 250),
                                            width: i == _heroIdx ? 14 : 4,
                                            height: 4,
                                            margin: const EdgeInsets.symmetric(horizontal: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.white
                                                  .withValues(alpha: i == _heroIdx ? 0.95 : 0.4),
                                              borderRadius: BorderRadius.circular(2),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
              // ---------- 分类直达（书库主分类）----------
              if (_mainCats.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionHeader(
                          title: '分类直达',
                          actionLabel: '书库 ›',
                          onAction: () => _openLibrary(),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 32,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final c in _mainCats)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: _CatPill(
                                    label: c.name,
                                    onTap: () => _openLibrary(catGroup: c.label, catId: c.id),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // ---------- 完本精选 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(
                        title: '完本精选',
                        actionLabel: '更多 ›',
                        onAction: () => _openLibrary(status: 0),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 182,
                        child: _finished.isEmpty && _loading
                            ? const _ShelfSkeleton()
                            : ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: _finished.length,
                                itemBuilder: (_, i) => _ShelfCard(
                                  book: _finished[i],
                                  coverW: (96 * dpr).round(),
                                  onTap: () => _openBook(_finished[i]),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---------- 新书速递 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(
                        title: '新书速递',
                        actionLabel: '更多 ›',
                        onAction: () => _openLibrary(sort: 1),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 182,
                        child: _newBooks.isEmpty && _loading
                            ? const _ShelfSkeleton()
                            : ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: _newBooks.length,
                                itemBuilder: (_, i) => _ShelfCard(
                                  book: _newBooks[i],
                                  coverW: (96 * dpr).round(),
                                  onTap: () => _openBook(_newBooks[i]),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---------- 巅峰榜速览 ----------
              if (_peak.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                    child: _PeakCard(
                      books: _peak,
                      coverW: (36 * dpr).round(),
                      onTap: _openBook,
                      onMore: _openRankPage,
                    ),
                  ),
                ),
              // ---------- 主网格：骨架屏 / 错误 / 榜单头 + 网格 ----------
              if (_loading && _books.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(hPad, 16, hPad, 0),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: 14,
                      childAspectRatio: ratio,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      childCount: 9,
                      (context, i) => const _CardPlaceholder(),
                    ),
                  ),
                )
              else if (_error != null && _books.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetry(message: _error!, onRetry: _loadBoards),
                )
              else if (_books.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('暂时没有上榜书籍', style: TextStyle(fontSize: 13))),
                )
              else ...[
                // 区块头：榜名 + 计数
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 18, 2),
                    child: Row(
                      children: [
                        Text(_boards[_boardIdx].name,
                            style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: MoStyle.inkOf(context))),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('${_books.length} 本在榜',
                              style: TextStyle(fontSize: 11, color: cs.outline)),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(hPad, 10, hPad, 0),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: 14,
                      childAspectRatio: ratio,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      childCount: _books.length,
                      (context, i) => _BoardBookCard(
                        book: _books[i],
                        rank: i + 1,
                        coverW: (coverW * dpr).round(),
                        coverH: coverH,
                        onTap: () => _openBook(_books[i]),
                      ),
                    ),
                  ),
                ),
                if (_loadingMore)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2))),
                    ),
                  )
                else if (!_hasMore && _books.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                          child: Text('已经到底了',
                              style: TextStyle(fontSize: 11.5, color: cs.outline))),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 区块头 / 小组件 ----------

/// 区块头：14.5/700 标题 + 右侧「更多 ›」11 muted
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 14.5, fontWeight: FontWeight.w700, color: MoStyle.inkOf(context))),
        const Spacer(),
        if (actionLabel != null)
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text(actionLabel!, style: TextStyle(fontSize: 11, color: cs.outline)),
            ),
          ),
      ],
    );
  }
}

/// 男/女频道胶囊切换（影响书城全部区块）
class _GenderToggle extends StatelessWidget {
  const _GenderToggle({required this.value, required this.onChanged});

  final String value; // '1' 男生 '0' 女生
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(context, '男生', '1'),
          _seg(context, '女生', '0'),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, String label, String v) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final sel = value == v;
    return InkWell(
      onTap: () => onChanged(v),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? (dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          // height:1 收紧行框，修正 CJK 字体 metrics 造成的文字偏上
          style: TextStyle(
            fontSize: 11.5,
            height: 1,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? (dark ? MoStyle.darkPrimaryStrong : MoStyle.primaryStrong) : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 分类直达胶囊（点击深链书库页对应分类）
class _CatPill extends StatelessWidget {
  const _CatPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 焦点轮播卡：朱砂三段渐变 + 右上装饰圆 + 金牌封面（No.1）
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.book,
    required this.boardName,
    required this.rank,
    required this.onTap,
  });

  final LibraryBook book;
  final String boardName;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 156,
        padding: const EdgeInsets.fromLTRB(18, 0, 14, 0),
        decoration: BoxDecoration(
          gradient: MoStyle.brandGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(color: Color(0x4DC2522C), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned(
                top: -50,
                right: -24,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.13),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('$boardName · No.$rank',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                        const SizedBox(height: 10),
                        Text(book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: MoStyle.titleFont,
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.3)),
                        const SizedBox(height: 8),
                        Text(
                            [
                              book.author.isEmpty ? '佚名' : book.author,
                              if (book.readCount.isNotEmpty) book.readCount,
                            ].join(' · '),
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.white.withValues(alpha: 0.85))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 80,
                    height: 108,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: BookCover(url: book.coverUrl, title: book.title, radius: 10),
                        ),
                        if (rank == 1)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.only(
                                  topRight: Radius.circular(10),
                                  bottomLeft: Radius.circular(10),
                                ),
                              ),
                              child: const Text('金牌',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: MoStyle.primaryStrong)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 横向书架卡：封面 96×128 + 完结/在库角标 + 书名 + 作者 · 字数
class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.book,
    required this.coverW,
    required this.onTap,
  });

  final LibraryBook book;
  final int coverW; // 封面解码宽（像素）
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = book.wordCount.isNotEmpty ? book.wordCount : book.readCount;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 96,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 128,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: BookCover(
                      url: book.coverUrl,
                      title: book.title,
                      radius: 10,
                      cacheWidth: coverW,
                    ),
                  ),
                  if (book.finished)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: const BoxDecoration(
                          color: Color(0xCC1F9D6D),
                          borderRadius: BorderRadius.only(topRight: Radius.circular(10)),
                        ),
                        child: const Text('完结',
                            style: TextStyle(
                                fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  if (book.inLibrary)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.only(
                              topRight: Radius.circular(10), bottomLeft: Radius.circular(10)),
                        ),
                        child: Text(book.localStatus == 'ready' ? '全文' : '在库',
                            style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: MoStyle.primaryStrong)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 30,
              child: Text(book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color: MoStyle.inkOf(context))),
            ),
            const SizedBox(height: 3),
            Text(
              '${book.author.isEmpty ? "佚名" : book.author}${meta.isEmpty ? "" : " · $meta"}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 巅峰榜速览卡：白面板 Top5 列表（名次衬线 + 小封面 + 在读数）+「完整榜单 ›」
class _PeakCard extends StatelessWidget {
  const _PeakCard({
    required this.books,
    required this.coverW,
    required this.onTap,
    required this.onMore,
  });

  final List<LibraryBook> books;
  final int coverW; // 封面解码宽（像素）
  final void Function(LibraryBook) onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: MoStyle.shadowSm(const Color(0xFFA13F1E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department_outlined,
                    size: 17, color: MoStyle.coral),
                const SizedBox(width: 5),
                Text('巅峰榜',
                    style: TextStyle(
                        fontFamily: MoStyle.titleFont,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: MoStyle.inkOf(context))),
                const Spacer(),
                InkWell(
                  onTap: onMore,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                    child: Text('完整榜单 ›', style: TextStyle(fontSize: 10.5, color: cs.outline)),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < books.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 0.8, indent: 68, endIndent: 12),
            InkWell(
              onTap: () => onTap(books[i]),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      child: Text('${i + 1}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontFamily: MoStyle.titleFont,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                              color: i < 3 ? MoStyle.strongOf(context) : cs.outline)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 36,
                      height: 50,
                      child: BookCover(
                        url: books[i].coverUrl,
                        title: books[i].title,
                        radius: 6,
                        cacheWidth: coverW,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(books[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                  color: MoStyle.inkOf(context))),
                          const SizedBox(height: 4),
                          Text(
                            [
                              books[i].author.isEmpty ? '佚名' : books[i].author,
                              if (books[i].wordCount.isNotEmpty) books[i].wordCount,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10.5, color: cs.outline),
                          ),
                        ],
                      ),
                    ),
                    if (books[i].readCount.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(books[i].readCount,
                          style: TextStyle(
                              fontSize: 10.5, color: MoStyle.strongOf(context))),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ---------- 骨架屏 ----------

/// 焦点轮播占位
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.brightness == Brightness.dark ? MoStyle.darkRule : MoStyle.rule;
    return Container(
      decoration: BoxDecoration(
        color: block.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
    );
  }
}

/// 横向书架占位：4 个灰封面
class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.brightness == Brightness.dark ? MoStyle.darkRule : MoStyle.rule;
    return Row(
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            width: 96,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: block.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
      ],
    );
  }
}

/// 加载骨架：灰封面 + 灰文字条（纸感占位，无第三方依赖）
class _CardPlaceholder extends StatelessWidget {
  const _CardPlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.brightness == Brightness.dark ? MoStyle.darkRule : MoStyle.rule;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: block.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Container(height: 13, width: double.infinity, color: block.withValues(alpha: 0.45)),
        const SizedBox(height: 5),
        FractionallySizedBox(
          widthFactor: 0.6,
          child: Container(height: 10, color: block.withValues(alpha: 0.35)),
        ),
      ],
    );
  }
}

/// 榜单书卡：与书库 _BookCard 同构，封面左上角加名次角标（前 3 主色）
class _BoardBookCard extends StatelessWidget {
  const _BoardBookCard({
    required this.book,
    required this.rank,
    required this.coverW,
    required this.coverH,
    required this.onTap,
  });

  final LibraryBook book;
  final int rank;
  final int coverW; // 封面解码宽（像素）
  final double coverH; // 封面固定高，保证所有卡片封面一致
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = book.readCount.isNotEmpty ? book.readCount : book.wordCount;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: coverH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: BookCover(
                    url: book.coverUrl,
                    title: book.title,
                    radius: 10,
                    cacheWidth: coverW,
                  ),
                ),
                // 名次角标：左上角，前 3 朱砂底
                Positioned(
                  top: 0,
                  left: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: rank <= 3
                          ? MoStyle.primary
                          : Colors.black.withValues(alpha: 0.45),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        bottomRight: Radius.circular(10),
                      ),
                    ),
                    child: Text('$rank',
                        style: TextStyle(
                            fontFamily: MoStyle.titleFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1)),
                  ),
                ),
                if (book.finished)
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                      decoration: const BoxDecoration(
                        color: Color(0xCC1F9D6D),
                        borderRadius: BorderRadius.only(topRight: Radius.circular(10)),
                      ),
                      child: const Text('完结',
                          style: TextStyle(
                              fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ),
                if (book.inLibrary)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.only(
                            topRight: Radius.circular(10), bottomLeft: Radius.circular(10)),
                      ),
                      child: Text(book.localStatus == 'ready' ? '全文' : '在库',
                          style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: MoStyle.primaryStrong)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 固定高度文字区：标题恒占 2 行，封面高度不受标题行数影响
          SizedBox(
            height: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 32,
                  child: Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: MoStyle.inkOf(context))),
                ),
                const SizedBox(height: 3),
                Text(
                  '${book.author.isEmpty ? "佚名" : book.author}${meta.isEmpty ? "" : " · $meta"}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cs.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
