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

/// 书城首页（「墨笺」风）：搜索 + 榜单 Tab + 焦点大卡 + 全屏三列网格（滚动加载更多）。
/// 数据全部来自番茄网页端（书库热门近似榜单，A 方案）；官方分类榜单在「完整榜单」二级页。
class StorePage extends ConsumerStatefulWidget {
  const StorePage({super.key});

  @override
  ConsumerState<StorePage> createState() => _StorePageState();
}

class _StorePageState extends ConsumerState<StorePage> {
  List<FeaturedBoard> _boards = const [];
  int _boardIdx = 0;

  final _books = <LibraryBook>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  static const _pageSize = 18;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    try {
      final boards = await _api.storeFeaturedBoards();
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _boardIdx = 0;
      });
      await _loadBooks();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadBooks() async {
    if (_boards.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final books = await _api.storeFeaturedBooks(
        _boards[_boardIdx].key,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _books
          ..clear()
          ..addAll(books);
        _hasMore = books.length >= _pageSize;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _boards.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final books = await _api.storeFeaturedBooks(
        _boards[_boardIdx].key,
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

  void _switchBoard(int i) {
    if (i == _boardIdx) return;
    setState(() => _boardIdx = i);
    _loadBooks();
  }

  void _openBook(LibraryBook book) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
    ));
  }

  Future<void> _refresh() {
    if (_boards.isEmpty) return _loadBoards();
    return _loadBooks();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 全屏三列网格度量：与书库页一致
    const hPad = 18.0;
    const gap = 10.0;
    final screenW = MediaQuery.of(context).size.width;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final coverW = (screenW - hPad * 2 - gap * 2) / 3;
    final coverH = coverW * 1.3;
    final cardH = coverH + 58; // 封面固定高 + 6 间距 + 52 文字区
    final ratio = coverW / cardH;

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
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => const StoreRankPage())),
                      icon: Icon(Icons.leaderboard_outlined, size: 22, color: MoStyle.primaryStrong),
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
                              color: cs.brightness == Brightness.dark
                                  ? MoStyle.darkInputFill
                                  : const Color(0xFFEEF2FB),
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
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const StoreLibraryPage())),
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
                              size: 20, color: MoStyle.primaryStrong),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---------- 榜单 Tab：下划线选中样式 ----------
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 42,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: [
                      for (var i = 0; i < _boards.length; i++)
                        MoUnderlineTab(
                          label: _boards[i].name,
                          selected: i == _boardIdx,
                          onTap: () => _switchBoard(i),
                        ),
                    ],
                  ),
                ),
              ),
              // ---------- 内容：骨架屏 / 错误 / 焦点大卡 + 网格 ----------
              if (_loading && _books.isEmpty)
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
                // 焦点大卡（当前榜第 1 名）
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                  sliver: SliverToBoxAdapter(
                    child: _HeroCard(
                      book: _books.first,
                      boardName: _boards[_boardIdx].name,
                      onTap: () => _openBook(_books.first),
                    ),
                  ),
                ),
                // 区块头：榜名 + 计数
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 18, 2),
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

/// 焦点大卡：当前榜第 1 名（朱砂三段渐变 + 右上装饰圆 + 金牌封面）
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.book, required this.boardName, required this.onTap});

  final LibraryBook book;
  final String boardName;
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
                          child: Text('$boardName · No.1',
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
