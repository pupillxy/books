import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'book_detail_page.dart';
import 'reader_page.dart';
import 'store_page.dart';
import 'widgets.dart';

/// 书架：续读卡 + 3 列书网格（「墨笺」纸感风）
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  List<ShelfItem>? _items;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  ApiClient get _api => ref.read(sessionProvider).api!;

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await _api.shelf();
      if (!mounted) return;
      setState(() => _items = items);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _openDetail(Book book) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookDetailPage(book: book),
    ));
    _load();
  }

  void _openReader(ShelfItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderPage(book: item.book, initialChapter: item.progressChapterIdx),
    ));
  }

  Future<void> _remove(Book book) async {
    try {
      await _api.shelfRemove(book.id);
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating));
    }
  }

  void _showActions(ShelfItem item) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text('继续阅读：${item.book.title}'),
              subtitle: Text('第 ${item.progressChapterIdx + 1} 章'),
              onTap: () {
                Navigator.pop(sheet);
                _openReader(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('查看详情'),
              onTap: () {
                Navigator.pop(sheet);
                _openDetail(item.book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: MoStyle.danger),
              title: const Text('移出书架', style: TextStyle(color: MoStyle.danger)),
              onTap: () {
                Navigator.pop(sheet);
                _remove(item.book);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final baseUrl = _api.baseUrl;

    Widget body;
    if (_error != null && _items == null) {
      body = ErrorRetry(message: _error!, onRetry: _load);
    } else if (_items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final items = _items!;
      // 续读书：取有阅读进度的第一本，否则第一本
      ShelfItem? reading;
      for (final it in items) {
        if (it.progressChapterIdx > 0) {
          reading = it;
          break;
        }
      }
      reading ??= items.isEmpty ? null : items.first;

      body = RefreshIndicator(
        color: cs.primary,
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ---------- 页头（固定常驻）----------
            MoPinnedHeader(
              child: PageHeader(title: '书架', actions: [
                IconButton(
                  tooltip: '去书城添加',
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const StorePage())),
                  icon: const Icon(Icons.add_circle_outline, color: MoStyle.ink2),
                ),
              ]),
            ),
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(
                  icon: Icons.collections_bookmark_outlined,
                  title: '书架还是空的',
                  subtitle: '去「书城」找一本书加入书架吧',
                ),
              )
            else ...[
              // ---------- 续读卡 ----------
              if (reading != null)
                SliverToBoxAdapter(
                  child: _ContinueCard(
                    item: reading,
                    baseUrl: baseUrl,
                    onTap: () => _openReader(reading!),
                  ),
                ),
              // ---------- 分组头 ----------
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 18, 10),
                  child: Row(
                    children: [
                      Text('我的书架',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant)),
                      const SizedBox(width: 6),
                      Text('${items.length}',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: MoStyle.primary)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          height: 1,
                          color: cs.outlineVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---------- 书网格（3 列 + 添加卡）----------
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.52,
                  ),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == items.length) {
                      return _AddCard(onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => const StorePage())));
                    }
                    final it = items[i];
                    return _ShelfCard(
                      item: it,
                      baseUrl: baseUrl,
                      onTap: () => _openDetail(it.book),
                      onLongPress: () => _showActions(it),
                      onPlayTap: () => _openReader(it),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Scaffold(body: body);
  }
}

/// 续读卡：朱砂渐变 + 右上半透明装饰圆
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.item, required this.baseUrl, required this.onTap});

  final ShelfItem item;
  final String baseUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final progress = item.progressChapterIdx + 1;
    final total = item.book.totalChapters;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
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
                  top: -46,
                  right: -30,
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.13),
                    ),
                  ),
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 52,
                      height: 70,
                      child: BookCover(
                        url: item.book.coverUrl(baseUrl),
                        title: item.book.title,
                        radius: 5,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('继续阅读',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withValues(alpha: 0.75))),
                          const SizedBox(height: 4),
                          Text(item.book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: MoStyle.titleFont,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                          const SizedBox(height: 6),
                          Text(
                            total > 0 ? '第 $progress / $total 章' : '第 $progress 章',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.white.withValues(alpha: 0.85)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 半透明白胶囊按钮
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text('继续读',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 书架网格卡片：封面 + 「读」角标 + 书名 + 进度
class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.item,
    required this.baseUrl,
    required this.onTap,
    required this.onLongPress,
    required this.onPlayTap,
  });

  final ShelfItem item;
  final String baseUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPlayTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final started = item.progressChapterIdx > 0;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(10)),
                      boxShadow: [
                        BoxShadow(
                            color: Color(0x29A13F1E),
                            blurRadius: 14,
                            offset: Offset(0, 6)),
                      ],
                    ),
                    child: BookCover(
                      url: item.book.coverUrl(baseUrl),
                      title: item.book.title,
                      radius: 10,
                    ),
                  ),
                ),
                if (started)
                  Positioned(
                    top: 0,
                    left: 0,
                    child: GestureDetector(
                      onTap: onPlayTap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: const BoxDecoration(
                          color: MoStyle.primary,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(10),
                            bottomRight: Radius.circular(10),
                          ),
                        ),
                        child: const Text('读',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.3)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 固定两行高度，避免书名行数不同导致封面大小不一
          SizedBox(
            height: 32,
            child: Text(item.book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: MoStyle.inkOf(context),
                    height: 1.35)),
          ),
          const SizedBox(height: 2),
          Text(
            started ? '读到第 ${item.progressChapterIdx + 1} 章' : '未开始读',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: started ? cs.primary : cs.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「添加书籍」60% 透明封面卡
class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});

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
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant, width: 1.2),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 26, color: cs.outline),
                  const SizedBox(height: 4),
                  Text('添加书籍',
                      style: TextStyle(fontSize: 10.5, color: cs.outline)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('去书城逛逛',
              maxLines: 1,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: cs.outline)),
        ],
      ),
    );
  }
}
