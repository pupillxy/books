import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/book_search.dart';
import '../core/local_books.dart';
import '../core/mo_theme.dart';
import '../core/reader_source.dart';
import '../core/session.dart';
import '../models.dart';
import 'book_content_search_page.dart';
import 'book_detail_page.dart';
import 'reader_page.dart';
import 'store_comic_detail_page.dart';
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
  List<LocalBookMeta> _local = const []; // 本机书（只存设备，不参与服务端同步）
  Map<String, int> _localProgress = const {}; // 本机书 id → 已读章下标

  @override
  bool get wantKeepAlive => true;

  ApiClient get _api => ref.read(sessionProvider).api!;

  Future<void> _load() async {
    setState(() => _error = null);
    _loadLocal();
    try {
      final items = await _api.shelf();
      if (!mounted) return;
      setState(() => _items = items);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  // 本机书列表独立加载：失败不阻塞服务端书架，只影响本机区块
  Future<void> _loadLocal() async {
    try {
      final local = await LocalBookService.instance.list();
      final progress = <String, int>{};
      for (final m in local) {
        progress[m.id] = await LocalBookService.instance.progressOf(m.id);
      }
      if (!mounted) return;
      setState(() {
        _local = local;
        _localProgress = progress;
      });
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _openDetail(Book book) async {
    // 漫画行（source=comic）：详情/阅读走漫画接口，不能进文字书详情
    if (book.isComic) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreComicDetailPage(bookId: book.fanqieId, title: book.title),
      ));
      _load();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookDetailPage(book: book),
    ));
    _load();
  }

  void _openReader(ShelfItem item) {
    // 漫画没有文字阅读器，进漫画详情选话阅读
    if (item.book.isComic) {
      _openDetail(item.book);
      return;
    }
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

  // ---------- 本机书 ----------

  void _openLocal(LocalBookMeta m, {int? initialChapter, int? initialCharOffset}) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final content = await LocalBookService.instance.open(m.id);
      final progress = await LocalBookService.instance.progressOf(m.id);
      if (!mounted) return;
      Navigator.of(context).pop(); // 关 loading
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: localBookAsBook(m),
          initialChapter: initialChapter ??
              (content.chapterCount > 0
                  ? progress.clamp(0, content.chapterCount - 1)
                  : 0),
          initialCharOffset: initialCharOffset,
          source: LocalReaderSource(content),
        ),
      ));
      _loadLocal();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('打开失败：$e'), behavior: SnackBarBehavior.floating));
    }
  }

  /// 书内内容搜索：搜索页返回命中的那条 → 打开阅读器并定位
  Future<void> _searchLocalContent(LocalBookMeta m) async {
    final hit = await Navigator.of(context).push<BookSearchHit>(
      MaterialPageRoute(builder: (_) => BookContentSearchPage(meta: m)),
    );
    if (hit == null || !mounted) return;
    _openLocal(m,
        initialChapter: hit.chapterIdx, initialCharOffset: hit.startInChapter);
  }

  Future<void> _importLocal() async {
    try {
      final meta = await LocalBookService.instance.importTxt();
      if (meta == null || !mounted) return; // 用户取消
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已导入《${meta.title}》· ${meta.chapterCount} 章（仅本机）'),
          behavior: SnackBarBehavior.floating));
      _loadLocal();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('导入失败：$e'), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _deleteLocal(LocalBookMeta m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本机书'),
        content: Text('《${m.title}》只存在这台设备上，删除后无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: MoStyle.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LocalBookService.instance.delete(m.id);
    _loadLocal();
  }

  void _showLocalActions(LocalBookMeta m) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text('继续阅读：${m.title}'),
              subtitle: Text('${m.chapterCount} 章 · 仅存本机'),
              onTap: () {
                Navigator.pop(sheet);
                _openLocal(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: const Text('搜索书内内容'),
              subtitle: const Text('搜正文关键词，直达所在章节'),
              onTap: () {
                Navigator.pop(sheet);
                _searchLocalContent(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: MoStyle.danger),
              title: const Text('删除本机书', style: TextStyle(color: MoStyle.danger)),
              onTap: () {
                Navigator.pop(sheet);
                _deleteLocal(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  // 「添加书籍」入口：书城 / 导入本地 TXT
  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('去书城添加'),
              subtitle: const Text('在线书，进度云同步'),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const StorePage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导入本地 TXT'),
              subtitle: const Text('仅存本机，不云同步'),
              onTap: () {
                Navigator.pop(sheet);
                _importLocal();
              },
            ),
          ],
        ),
      ),
    );
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
              subtitle: Text('第 ${item.progressChapterIdx + 1} ${item.book.isComic ? '话' : '章'}'),
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
                  icon: Icon(Icons.add_circle_outline,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            if (items.isEmpty && _local.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(
                  icon: Icons.collections_bookmark_outlined,
                  title: '书架还是空的',
                  subtitle: '去「书城」找一本书，或导入本地 TXT',
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
              // ---------- 书网格（3 列：服务端书 + 本机书 + 添加卡）----------
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.52,
                  ),
                  itemCount: items.length + _local.length + 1,
                  itemBuilder: (context, i) {
                    if (i == items.length + _local.length) {
                      return _AddCard(onTap: _showAddSheet);
                    }
                    if (i < items.length) {
                      final it = items[i];
                      return _ShelfCard(
                        item: it,
                        baseUrl: baseUrl,
                        onTap: () => _openDetail(it.book),
                        onLongPress: () => _showActions(it),
                        onPlayTap: () => _openReader(it),
                      );
                    }
                    final m = _local[i - items.length];
                    return _LocalCard(
                      meta: m,
                      progress: _localProgress[m.id] ?? 0,
                      onTap: () => _openLocal(m),
                      onLongPress: () => _showLocalActions(m),
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
    final unit = item.book.isComic ? '话' : '章';
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
                            total > 0 ? '第 $progress / $total $unit' : '第 $progress $unit',
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
            started
                ? '读到第 ${item.progressChapterIdx + 1} ${item.book.isComic ? '话' : '章'}'
                : '未开始读',
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

/// 本机书卡片：渐变占位封面 + 「本机」角标（不访问服务端）
class _LocalCard extends StatelessWidget {
  const _LocalCard({
    required this.meta,
    required this.progress,
    required this.onTap,
    required this.onLongPress,
  });

  final LocalBookMeta meta;
  final int progress; // 已读章下标，0 = 未开始
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final started = progress > 0;
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
                    child: BookCover(url: null, title: meta.title, radius: 10),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                    decoration: const BoxDecoration(
                      color: Color(0x8C000000),
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(10),
                        bottomLeft: Radius.circular(10),
                      ),
                    ),
                    child: const Text('本机',
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.3)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: Text(meta.title,
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
            started ? '本机 · 读到第 ${progress + 1} 章' : '本机书 · 未开始读',
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
