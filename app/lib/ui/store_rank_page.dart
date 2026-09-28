import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'widgets.dart';

/// 完整榜单：番茄官方榜单浏览（分组 Tab + 子项 pill + 焦点大卡 + 榜单行）
/// 从书城首页拆出，首页推荐榜卡的「完整榜单 ›」入口落到这里。
class StoreRankPage extends ConsumerStatefulWidget {
  const StoreRankPage({super.key});

  @override
  ConsumerState<StoreRankPage> createState() => _StoreRankPageState();
}

class _StoreRankPageState extends ConsumerState<StoreRankPage> {
  List<RankGroup>? _groups;
  String? _error;
  int _groupIdx = 0;
  String _rankId = '';
  String _rankName = '';

  final _books = <StoreBook>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _booksError;

  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  ApiClient get _api => ref.read(sessionProvider).api!;

  Future<void> _loadGroups() async {
    setState(() => _error = null);
    try {
      final groups = await _api.storeRanks();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        if (groups.isNotEmpty && groups.first.items.isNotEmpty) {
          _rankId = groups.first.items.first.id;
          _rankName = groups.first.items.first.name;
        }
      });
      if (_rankId.isNotEmpty) _loadBooks();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadBooks() async {
    setState(() {
      _loading = true;
      _booksError = null;
    });
    try {
      final books = await _api.storeRankBooks(_rankId, offset: 0, limit: _pageSize);
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
        _booksError = e.message;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final books = await _api.storeRankBooks(_rankId, offset: _books.length, limit: _pageSize);
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

  void _selectRank(RankItem item) {
    if (item.id == _rankId) return;
    setState(() {
      _rankId = item.id;
      _rankName = item.name;
    });
    _loadBooks();
  }

  void _openBook(StoreBook book) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_error != null && _groups == null) {
      return Scaffold(body: SafeArea(child: ErrorRetry(message: _error!, onRetry: _loadGroups)));
    }
    if (_groups == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
              const MoPinnedHeader(child: PageHeader(title: '完整榜单')),
              // ---------- 分组 Tab：下划线选中样式 ----------
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 42,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: [
                      for (var i = 0; i < _groups!.length; i++)
                        _UnderlineTab(
                          label: _groups![i].title,
                          selected: i == _groupIdx,
                          onTap: () {
                            final g = _groups![i];
                            if (g.items.isEmpty) return;
                            setState(() {
                              _groupIdx = i;
                              _rankId = g.items.first.id;
                              _rankName = g.items.first.name;
                            });
                            _loadBooks();
                          },
                        ),
                    ],
                  ),
                ),
              ),
              // ---------- 榜单子项 pill ----------
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
                    children: [
                      for (final item in _groups![_groupIdx].items)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _RankPill(
                            label: item.name,
                            selected: item.id == _rankId,
                            onTap: () => _selectRank(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // ---------- 内容 ----------
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
              else ...[
                // 焦点大卡（榜单第 1 名）
                if (_books.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                    sliver: SliverToBoxAdapter(
                      child: _FocusCard(
                          book: _books.first, rankName: _rankName, onTap: () => _openBook(_books.first)),
                    ),
                  ),
                // 区块头
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 18, 18, 2),
                    child: Row(
                      children: [
                        Text(_rankName,
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
                // 榜单行
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                  sliver: SliverList.builder(
                    itemCount: _books.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _books.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                              child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2))),
                        );
                      }
                      return _RankRow(book: _books[i], rankName: _rankName);
                    },
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

/// 分类 Chip：选中主色 + 底部短下划线（公共组件）
class _UnderlineTab extends StatelessWidget {
  const _UnderlineTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MoUnderlineTab(label: label, selected: selected, onTap: onTap);
  }
}

/// 榜单子项胶囊
class _RankPill extends StatelessWidget {
  const _RankPill({required this.label, required this.selected, required this.onTap});

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
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            label,
            // height:1 收紧行框，修正 CJK 字体 metrics 造成的文字偏上
            style: TextStyle(
              fontSize: 12.5,
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

/// 焦点大卡：朱砂渐变 + 右上装饰圆 + 金牌封面
class _FocusCard extends StatelessWidget {
  const _FocusCard({required this.book, required this.rankName, required this.onTap});

  final StoreBook book;
  final String rankName;
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
              // 右上半透明白圆装饰
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
                          child: Text('$rankName · No.1',
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
                        Text(book.author.isEmpty ? '佚名' : book.author,
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.white.withValues(alpha: 0.85))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 右侧封面 + 金牌角标
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

/// 榜单行：名次 + 小封面 + 书名/作者
class _RankRow extends StatelessWidget {
  const _RankRow({required this.book, required this.rankName});

  final StoreBook book;
  final String rankName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final top3 = book.rank <= 3;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
      )),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.8)),
        ),
        child: Row(
          children: [
            // 名次：衬线 15/800，前 3 主色其余 muted
            SizedBox(
              width: 26,
              child: Text('${book.rank}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: MoStyle.titleFont,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: top3 ? MoStyle.primary : cs.outline)),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 36,
              height: 50,
              child: BookCover(url: book.coverUrl, title: book.title, radius: 6),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: MoStyle.inkOf(context))),
                      ),
                      if (book.inLibrary) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: (cs.brightness == Brightness.dark
                                ? MoStyle.darkPrimarySoft
                                : MoStyle.primarySoft),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(book.localStatus == 'ready' ? '全文' : '在库',
                              style: const TextStyle(
                                  fontSize: 9.5, fontWeight: FontWeight.w600, color: MoStyle.primaryStrong)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${book.author.isEmpty ? "佚名" : book.author} · $rankName',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('第 ${book.rank} 名',
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w700, color: MoStyle.primary)),
          ],
        ),
      ),
    );
  }
}
