import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'widgets.dart';

/// 分类书单页（复刻番茄官方标签落地页）：
/// 顶部标签名 + 官方 banner 语 + 相关分类词条 + 字数/状态/排序筛选 + 评分书单。
/// 数据走官方 new_category/landing 协议（10/05 定案），筛选值 = 官方 selector_item_id。
class StoreCategoryResultPage extends ConsumerStatefulWidget {
  const StoreCategoryResultPage({
    super.key,
    required this.categoryId,
    required this.title,
    required this.gender,
  });

  final int categoryId;
  final String title;
  final int gender; // 1=男生 0=女生（随分类页频道带入）

  @override
  ConsumerState<StoreCategoryResultPage> createState() =>
      _StoreCategoryResultPageState();
}

class _StoreCategoryResultPageState
    extends ConsumerState<StoreCategoryResultPage> {
  // 官方筛选（selector_item_id 与文案来自 10/05 抓包，服务端下发集合固定）
  static const _wordFilters = [
    ('不限', 'word_num_default'),
    ('10万字以内', 'word_num_lte10'),
    ('30万字以内', 'word_num_lte30'),
    ('50万字以内', 'word_num_lte50'),
    ('30万字以上', 'word_num_gte30'),
    ('50万字以上', 'word_num_gte50'),
    ('100万字以上', 'word_num_gte100'),
    ('200万字以上', 'word_num_gte200'),
    ('300万字以上', 'word_num_gte300'),
    ('500万字以上', 'word_num_gte500'),
  ];
  static const _statusFilters = [
    ('不限', 'creation_status_default'),
    ('完结', 'creation_status_end'),
    ('半年内完结', 'creation_status_half_year_end'),
    ('连载中', 'creation_status_loading'),
    ('3日内更新', 'creation_status_3day_update'),
    ('7日内更新', 'creation_status_7day_update'),
    ('1月内更新', 'creation_status_1month_update'),
  ];
  static const _sortFilters = [
    ('综合', 'sort_default'),
    ('新书', 'sort_new_book'),
    ('高分', 'sort_score'),
    ('字数', 'sort_word_number'),
  ];

  int _wordIdx = 0;
  int _statusIdx = 0;
  int _sortIdx = 0;

  List<FeedBook> _books = const [];
  String _banner = '';
  List<StoreCategoryTag> _related = const [];
  int _offset = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  Timer? _retryTimer;
  int _reqGen = 0; // 切筛选/跳相关分类可打断在途请求，旧响应作废

  ApiClient get _api => ref.read(sessionProvider).api!;

  String get _filters =>
      [_wordFilters[_wordIdx].$2, _statusFilters[_statusIdx].$2, _sortFilters[_sortIdx].$2]
          .join(',');

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final gen = ++_reqGen;
    setState(() {
      _loading = true;
      if (reset) {
        _books = const [];
        _offset = 0;
        _hasMore = true;
      }
      _error = null;
    });
    try {
      final r = await _api.storeCategoryFeed(
          categoryId: widget.categoryId,
          gender: widget.gender,
          filters: _filters,
          offset: reset ? 0 : _offset);
      if (!mounted || gen != _reqGen) return;
      setState(() {
        _books = reset ? r.books : [..._books, ...r.books];
        _offset = r.nextOffset;
        _hasMore = r.hasMore;
        if (reset) {
          _banner = r.banner;
          if (r.related.isNotEmpty) _related = r.related;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _reqGen) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 90), () {
        if (mounted && _error != null) _load(reset: reset);
      });
    }
  }

  void _onFilterChanged() {
    _load(reset: true);
  }

  void _openRelated(StoreCategoryTag tag) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => StoreCategoryResultPage(
            categoryId: tag.id, title: tag.name, gender: widget.gender)));
  }

  void _openBook(FeedBook b) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreBookDetailPage(fanqieId: b.id, title: b.title)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.axis == Axis.vertical &&
                      n.metrics.pixels >= n.metrics.maxScrollExtent - 800) {
                    _load();
                  }
                  return false;
                },
                child: _buildList(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 顶栏：返回 + 标签名胶囊 ────────────────────────────────────────
  Widget _buildTopBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          BackButton(onPressed: () => Navigator.of(context).pop()),
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded,
                      size: 18, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, color: MoStyle.inkOf(context))),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading && _books.isEmpty && _error == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _books.isEmpty) {
      return ErrorRetry(message: _error!, onRetry: () => _load(reset: true));
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_banner.isNotEmpty) _buildBanner(context, _banner),
        if (_related.isNotEmpty) _buildRelated(context),
        _buildFilterRows(context),
        if (_books.isEmpty && !_loading)
          const EmptyView(icon: Icons.auto_stories_rounded, title: '该分类暂无书籍')
        else
          for (final b in _books)
            _CategoryBookRow(
                book: b, onTap: () => _openBook(b)),
        if (_loading && _books.isNotEmpty)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (!_hasMore && _books.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
                child: Text('已经到底了',
                    style: TextStyle(fontSize: 11.5, color: cs.outline))),
          ),
      ],
    );
  }

  // ── 官方标签语 banner（绿色软底）────────────────────────────────────
  Widget _buildBanner(BuildContext context, String text) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: dark
            ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .05)
            : const Color(0xFFE4F3EA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: dark
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : const Color(0xFF2E7D5B))),
    );
  }

  // ── 相关分类词条（官方 cate_* 行，整页跳转）──────────────────────────
  Widget _buildRelated(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        itemCount: _related.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final t = _related[i];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openRelated(t),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(t.name,
                  style: TextStyle(
                      fontSize: 13, height: 1.0, color: MoStyle.inkOf(context))),
            ),
          );
        },
      ),
    );
  }

  // ── 筛选行 ×3（字数/状态/排序，组内单选，官方 selector 同构）──────────
  Widget _buildFilterRows(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterRow(context, _wordFilters, _wordIdx,
              (i) => setState(() => _wordIdx = i)),
          _filterRow(context, _statusFilters, _statusIdx,
              (i) => setState(() => _statusIdx = i)),
          _filterRow(context, _sortFilters, _sortIdx,
              (i) => setState(() => _sortIdx = i)),
        ],
      ),
    );
  }

  Widget _filterRow(BuildContext context, List<(String, String)> options,
      int selectedIdx, ValueChanged<int> onTap) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 18),
        itemBuilder: (context, i) {
          final selected = i == selectedIdx;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (selected) return;
              onTap(i);
              _onFilterChanged();
            },
            child: Center(
              child: Text(options[i].$1,
                  style: TextStyle(
                    fontSize: selected ? 14 : 13,
                    height: 1.0,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w400,
                    color: selected
                        ? MoStyle.strongOf(context)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
            ),
          );
        },
      ),
    );
  }
}

/// 书单行卡（官方 landing 卡同构：封面 + 书名 + 简介 + 标签行 + 右侧评分）
class _CategoryBookRow extends StatelessWidget {
  const _CategoryBookRow({required this.book, required this.onTap});

  final FeedBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: cs.outlineVariant, width: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: BookCover(
                    url: book.cover.isEmpty ? null : book.cover,
                    title: book.title,
                    radius: 8,
                    cacheWidth: 200),
              ),
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
                          height: 1.2,
                          fontWeight: FontWeight.w600)),
                  if (book.synopsis.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(book.synopsis,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, height: 1.3, color: cs.outline)),
                  ],
                  const SizedBox(height: 4),
                  Text(book.tags,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.outline)),
                ],
              ),
            ),
            if (book.score.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text('${book.score}分',
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      color: MoStyle.strongOf(context))),
            ],
          ],
        ),
      ),
    );
  }
}
