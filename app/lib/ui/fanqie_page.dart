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

/// 番茄书城（新设计）：榜单为主的在线阅读入口。
/// 内容与番茄同源——四榜（推荐/完本/新书/巅峰）+ 搜索 + 书库分类。
/// 正文按需回源（读到哪章拉哪章），无需整本下载。
class FanqiePage extends ConsumerStatefulWidget {
  const FanqiePage({super.key});

  @override
  ConsumerState<FanqiePage> createState() => _FanqiePageState();
}

class _FanqiePageState extends ConsumerState<FanqiePage> {
  ApiClient get _api => ref.read(sessionProvider).api!;

  List<FeaturedBoard> _boards = const [];
  bool _boardsLoading = true;
  String _boardsError = '';

  String _gender = '1'; // '1' 男生 / '0' 女生
  int _boardIdx = 0;
  final Map<String, List<LibraryBook>> _booksCache = {};
  final Set<String> _loadingKeys = {};
  String? _booksError;

  String get _boardKey =>
      _boards.isEmpty ? '' : _boards[_boardIdx.clamp(0, _boards.length - 1)].key;
  String get _cacheKey => '$_boardKey|$_gender';

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    setState(() {
      _boardsLoading = true;
      _boardsError = '';
    });
    try {
      final boards = await _api.storeFeaturedBoards();
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _boardsLoading = false;
        if (_boardIdx >= boards.length) _boardIdx = 0;
      });
      if (boards.isNotEmpty) _loadBooks();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _boardsLoading = false;
        _boardsError = e.message;
      });
    }
  }

  Future<void> _loadBooks() async {
    final key = _cacheKey;
    if (_boardKey.isEmpty || _booksCache.containsKey(key)) {
      setState(() {});
      return;
    }
    _loadingKeys.add(key);
    setState(() => _booksError = null);
    try {
      final books =
          await _api.storeFeaturedBooks(_boardKey, gender: _gender, limit: 20);
      if (!mounted) return;
      setState(() {
        _booksCache[key] = books;
        _loadingKeys.remove(key);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingKeys.remove(key);
        _booksError = e.message;
      });
    }
  }

  Future<void> _refresh() async {
    _booksCache.clear();
    await _loadBoards();
    await _loadBooks();
  }

  void _openDetail(LibraryBook b) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreBookDetailPage(fanqieId: b.id, title: b.title)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverToBoxAdapter(child: _buildSearchBar(context)),
            SliverToBoxAdapter(child: _buildBody(context)),
            SliverToBoxAdapter(child: _buildEntries(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  // ── 头部：渐变 + 标题 + 性别切换 ─────────────────────────────────
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
          Row(
            children: [
              Text('番茄书城',
                  style: TextStyle(
                    fontFamily: MoStyle.titleFont,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 1,
                  )),
              const Spacer(),
              _GenderPill(
                value: _gender,
                onChanged: (v) {
                  setState(() => _gender = v);
                  _loadBooks();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('榜单同源 · 正文按需在线读',
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
    if (_boardsLoading) return _buildSkeleton();
    if (_boardsError.isNotEmpty) {
      return ErrorRetry(message: _boardsError, onRetry: _loadBoards);
    }
    if (_boards.isEmpty) {
      return const EmptyView(icon: Icons.leaderboard_rounded, title: '暂无榜单');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTop3(context),
        _buildBoardChips(context),
        _buildBoardList(context),
      ],
    );
  }

  // ── TOP3 横滑大卡 ───────────────────────────────────────────────
  Widget _buildTop3(BuildContext context) {
    final books = _booksCache[_cacheKey] ?? const <LibraryBook>[];
    if (books.isEmpty) {
      return const SizedBox(
          height: 150,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final top = books.take(3).toList();
    final boardName = _boards[_boardIdx.clamp(0, _boards.length - 1)].name;
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
                                url: b.coverUrl,
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
                        Text(boardName,
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
                        if (b.readCount.isNotEmpty)
                          Text(b.readCount,
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

  Widget _buildBoardChips(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _boards.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = i == _boardIdx;
          return ChoiceChip(
            label: Text(_boards[i].name),
            selected: selected,
            onSelected: (_) {
              setState(() => _boardIdx = i);
              _loadBooks();
            },
            selectedColor: MoStyle.strongOf(context),
            labelStyle: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
          );
        },
      ),
    );
  }

  // ── 榜单列表（第 4 名起的行卡）────────────────────────────────────
  Widget _buildBoardList(BuildContext context) {
    final all = _booksCache[_cacheKey] ?? const <LibraryBook>[];
    if (_loadingKeys.contains(_cacheKey)) {
      return _buildListSkeleton();
    }
    if (_booksError != null) {
      return ErrorRetry(message: _booksError!, onRetry: _loadBooks);
    }
    final rest = all.length > 3 ? all.sublist(3) : const <LibraryBook>[];
    if (rest.isEmpty) {
      return const EmptyView(
          icon: Icons.menu_book_rounded, title: '这一榜就这几本了');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        children: [
          for (var i = 0; i < rest.length; i++)
            _RankTile(
                book: rest[i],
                rank: i + 4,
                onTap: () => _openDetail(rest[i])),
        ],
      ),
    );
  }

  Widget _buildSkeleton() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: 72,
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

  Widget _buildListSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
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

  // ── 更多入口 ────────────────────────────────────────────────────
  Widget _buildEntries(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _EntryCard(
              icon: Icons.leaderboard_rounded,
              title: '全部榜单',
              subtitle: '分类排行 · 完整排名',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StoreRankPage())),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _EntryCard(
              icon: Icons.category_rounded,
              title: '分类书库',
              subtitle: '题材筛选 · 精准找书',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StoreLibraryPage())),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 行卡：名次 + 封面 + 信息 ─────────────────────────────────────────
class _RankTile extends StatelessWidget {
  const _RankTile({required this.book, required this.rank, required this.onTap});

  final LibraryBook book;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rankColor = rank <= 3
        ? MoStyle.primaryStrong
        : Theme.of(context).colorScheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text('$rank',
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
                      url: book.coverUrl,
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
                      Flexible(
                        child: Text(book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                      ),
                      if (book.readCount.isNotEmpty) ...[
                        Text(' · ',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(context).colorScheme.outline)),
                        Text(book.readCount,
                            style: TextStyle(
                                fontSize: 12,
                                color: MoStyle.strongOf(context))),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (book.finished)
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

// ── 性别切换 pill ───────────────────────────────────────────────────
class _GenderPill extends StatelessWidget {
  const _GenderPill({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _pill('男生', '1'),
        _pill('女生', '0'),
      ]),
    );
  }

  Widget _pill(String label, String v) {
    final selected = value == v;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onChanged(v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? MoStyle.primaryStrong : Colors.white)),
      ),
    );
  }
}

// ── 入口卡 ──────────────────────────────────────────────────────────
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: MoStyle.softOf(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: MoStyle.strongOf(context), size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontFamily: MoStyle.titleFont,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: Theme.of(context).colorScheme.outline),
          ],
        ),
      ),
    );
  }
}
