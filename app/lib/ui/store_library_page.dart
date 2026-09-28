import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'widgets.dart';

/// 书库：番茄官网筛选浏览（频道/分类/状态/字数 + 热门/最新/字数排序 + 封面网格）
class StoreLibraryPage extends ConsumerStatefulWidget {
  const StoreLibraryPage({super.key});

  @override
  ConsumerState<StoreLibraryPage> createState() => _StoreLibraryPageState();
}

class _StoreLibraryPageState extends ConsumerState<StoreLibraryPage> {
  List<LibCategory>? _cats; // 全部分类（按 label 分组）

  String _gender = '1';
  String _catGroup = ''; // '' = 不限；否则为主分类/主题/角色/情节
  int _catId = -1;
  int _status = -1; // -1全部 0已完结 1连载中
  int _words = 0; // 0全部 1-5 字数档
  int _sort = 0; // 0热门 1最新 2字数

  final _books = <LibraryBook>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _booksError;
  int _page = 0;

  static const _pageSize = 18;
  static const _wordsLabels = ['全部', '30万以下', '30-50万', '50-100万', '100-200万', '200万以上'];
  static const _statusLabels = {0: '已完结', 1: '连载中'};

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _loadBooks();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await _api.storeLibraryCategories(_gender);
      if (!mounted) return;
      setState(() {
        _cats = cats;
        // 频道切换后原分类可能不存在，重置
        if (_catGroup.isNotEmpty && !cats.any((c) => c.label == _catGroup)) _resetCategory();
      });
    } on ApiException {
      // 分类加载失败时分类行只显示「全部」，不阻塞书库列表
    }
  }

  void _resetCategory() {
    _catGroup = '';
    _catId = -1;
  }

  Future<void> _loadBooks() async {
    setState(() {
      _loading = true;
      _booksError = null;
    });
    await _fetch(page: 0, replace: true);
  }

  /// 静默刷新（从详情页返回时更新在库角标，不闪加载圈）
  Future<void> _reloadSilent() async {
    await _fetch(page: 0, replace: true);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    await _fetch(page: _page + 1, replace: false);
  }

  Future<void> _fetch({required int page, required bool replace}) async {
    try {
      final books = await _api.storeLibraryBooks(
        gender: _gender,
        category: _catId,
        status: _status,
        words: _words,
        sort: _sort,
        page: page,
        size: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (replace) _books.clear();
        _books.addAll(books);
        _page = page;
        _hasMore = books.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (replace) _booksError = e.message;
      });
    }
  }

  void _onFilterChanged() {
    _loadBooks();
  }

  void _openBook(LibraryBook book) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
        ))
        .then((_) {
      if (mounted) _reloadSilent(); // 详情页进入即自动入库，返回后刷新角标
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenW = MediaQuery.of(context).size.width;
    const hPad = 18.0;
    const gap = 10.0;
    final coverW = (screenW - hPad * 2 - gap * 2) / 3;
    final coverH = coverW * 1.3;
    final cardH = coverH + 58; // 封面固定高 + 6 间距 + 52 文字区，保证所有卡片等高
    final ratio = coverW / cardH;

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
          return false;
        },
        child: RefreshIndicator(
          color: cs.primary,
          onRefresh: _loadBooks,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ---------- 页头：返回 + 衬线标题（PageHeader 自动返回键+避让状态栏）----------
              const SliverToBoxAdapter(child: PageHeader(title: '书库')),
              // ---------- 筛选区 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(hPad, 6, hPad, 0),
                  child: _buildFilters(cs),
                ),
              ),
              // ---------- 排序 Tab ----------
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: hPad),
                    children: [
                      for (final e in const {0: '热门', 1: '最新', 2: '字数'}.entries)
                        _UnderlineTab(
                          label: e.value,
                          selected: _sort == e.key,
                          onTap: () {
                            if (_sort == e.key) return;
                            setState(() => _sort = e.key);
                            _onFilterChanged();
                          },
                        ),
                    ],
                  ),
                ),
              ),
              // ---------- 内容网格 ----------
              if (_loading && _books.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_booksError != null && _books.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetry(message: _booksError!, onRetry: _loadBooks),
                )
              else if (_books.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('没有符合条件的书籍', style: TextStyle(fontSize: 13))),
                )
              else ...[
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
                      (context, i) => _BookCard(
                        book: _books[i],
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
                else if (!_hasMore)
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

  // ---------- 筛选区 ----------

  Widget _buildFilters(ColorScheme cs) {
    final groups = <String, List<LibCategory>>{};
    if (_cats != null) {
      for (final c in _cats!) {
        (groups[c.label] ??= []).add(c);
      }
    }
    final groupOrder = groups.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filterRow(cs, '频道', [
          _Chip(label: '男生', selected: _gender == '1', onTap: () => _switchGender('1')),
          _Chip(label: '女生', selected: _gender == '0', onTap: () => _switchGender('0')),
        ]),
        _filterRow(cs, '分类', [
          _Chip(
              label: '全部',
              selected: _catGroup.isEmpty,
              onTap: () {
                if (_catGroup.isEmpty) return;
                setState(_resetCategory);
                _onFilterChanged();
              }),
          for (final g in groupOrder)
            _Chip(
                label: g,
                selected: _catGroup == g,
                onTap: () {
                  if (_catGroup == g) return;
                  setState(() {
                    _catGroup = g;
                    _catId = -1;
                  });
                  _onFilterChanged();
                }),
        ]),
        if (_catGroup.isNotEmpty)
          _filterRow(cs, '', [
            _Chip(
                label: '全部',
                selected: _catId == -1,
                onTap: () {
                  if (_catId == -1) return;
                  setState(() => _catId = -1);
                  _onFilterChanged();
                }),
            for (final c in groups[_catGroup] ?? const <LibCategory>[])
              _Chip(
                  label: c.name,
                  selected: _catId == c.id,
                  onTap: () {
                    if (_catId == c.id) return;
                    setState(() => _catId = c.id);
                    _onFilterChanged();
                  }),
          ]),
        _filterRow(cs, '状态', [
          _Chip(
              label: '全部',
              selected: _status == -1,
              onTap: () {
                if (_status == -1) return;
                setState(() => _status = -1);
                _onFilterChanged();
              }),
          for (final e in _statusLabels.entries)
            _Chip(
                label: e.value,
                selected: _status == e.key,
                onTap: () {
                  if (_status == e.key) return;
                  setState(() => _status = e.key);
                  _onFilterChanged();
                }),
        ]),
        _filterRow(cs, '字数', [
          for (var i = 0; i < _wordsLabels.length; i++)
            _Chip(
                label: _wordsLabels[i],
                selected: _words == i,
                onTap: () {
                  if (_words == i) return;
                  setState(() => _words = i);
                  _onFilterChanged();
                }),
        ]),
      ],
    );
  }

  Widget _filterRow(ColorScheme cs, String label, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 38,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 34,
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: cs.outline)),
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _switchGender(String g) {
    if (_gender == g) return;
    setState(() {
      _gender = g;
      _resetCategory();
    });
    _loadCategories();
    _onFilterChanged();
  }
}

// ---------- 小组件 ----------

/// 筛选胶囊（同书城榜单 pill 风格）
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? (cs.brightness == Brightness.dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft)
          : cs.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Text(
            label,
            // height:1 收紧行框，修正 CJK 字体 metrics 造成的文字偏上
            style: TextStyle(
              fontSize: 12,
              height: 1,
              color: selected ? MoStyle.primaryStrong : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 排序 Tab：选中主色 + 底部短下划线
class _UnderlineTab extends StatelessWidget {
  const _UnderlineTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? MoStyle.primaryStrong : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 18,
              height: 2.5,
              decoration: BoxDecoration(
                color: selected ? MoStyle.primaryStrong : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书库网格卡片：封面（完结/在库角标）+ 书名 + 作者 · 字数
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.coverW,
    required this.coverH,
    required this.onTap,
  });

  final LibraryBook book;
  final int coverW; // 封面解码宽（像素）
  final double coverH; // 封面固定高，保证所有卡片封面一致
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                        borderRadius: BorderRadius.only(topRight: Radius.circular(10), bottomLeft: Radius.circular(10)),
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
                  '${book.author.isEmpty ? "佚名" : book.author}${book.wordCount.isEmpty ? "" : " · ${book.wordCount}"}',
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
