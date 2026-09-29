import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_book_detail_page.dart';
import 'widgets.dart';

/// 书城真搜索（网页端源）：点键盘搜索键/提交才搜索，不逐字自动触发
/// 失败时页面展示错误并保留重试。
class StoreSearchPage extends ConsumerStatefulWidget {
  const StoreSearchPage({super.key});

  @override
  ConsumerState<StoreSearchPage> createState() => _StoreSearchPageState();
}

class _StoreSearchPageState extends ConsumerState<StoreSearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  final _books = <LibraryBook>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String _lastQuery = '';
  int _offset = 0;

  // 上游搜索接口仅接受 page_count=10（其他值报参数错误），分页宽度必须固定为 10
  static const _pageSize = 10;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 输入框清空时复位列表（搜索本身只在提交时触发）
  void _onChanged(String text) {
    if (text.trim().isEmpty) {
      setState(() {
        _books.clear();
        _error = null;
        _loading = false;
        _lastQuery = '';
      });
    }
  }

  Future<void> _search(String query, {bool fresh = false}) async {
    if (_loading) return;
    if (query.isEmpty) return;
    if (fresh) {
      _offset = 0;
      _lastQuery = query;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final books = await _api.storeAppSearch(query, offset: _offset, count: _pageSize);
      if (!mounted) return;
      setState(() {
        if (fresh) _books.clear();
        _books.addAll(books);
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

  void _loadMore() {
    if (_loading || _loadingMore || !_hasMore || _lastQuery.isEmpty) return;
    setState(() => _loadingMore = true);
    _offset = _books.length;
    _search(_lastQuery);
  }

  void _openBook(LibraryBook book) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StoreBookDetailPage(fanqieId: book.id, title: book.title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          // 固定头部（本页无滚动吸顶需求，直接用 PageHeader，勿用 sliver 版 MoPinnedHeader）
          const PageHeader(title: '搜索'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: cs.brightness == Brightness.dark ? MoStyle.darkInputFill : const Color(0xFFEEF2FB),
                borderRadius: BorderRadius.circular(13),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) => _search(v.trim(), fresh: true),
                onChanged: _onChanged,
                style: TextStyle(fontSize: 13.5, color: MoStyle.inkOf(context)),
                decoration: InputDecoration(
                  hintText: '搜索书名 / 作者',
                  hintStyle: TextStyle(fontSize: 13, color: cs.outline),
                  prefixIcon: Icon(Icons.search, size: 18, color: cs.outline),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, v, _) => v.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: Icon(Icons.close, size: 16, color: cs.outline),
                            onPressed: () {
                              _controller.clear();
                              _onChanged('');
                            },
                          ),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(cs)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading && _books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _books.isEmpty) {
      return ErrorRetry(message: _error!, onRetry: () => _search(_lastQuery, fresh: true));
    }
    if (_books.isEmpty) {
      return Center(
        child: Text(_lastQuery.isEmpty ? '输入书名或作者开始搜索' : '没有找到相关书籍',
            style: TextStyle(fontSize: 13, color: cs.outline)),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
        itemCount: _books.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _books.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return _SearchRow(book: _books[i], onTap: () => _openBook(_books[i]));
        },
      ),
    );
  }
}

/// 搜索结果行：名次位不显示，封面 + 书名/作者/在读
class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.book, required this.onTap});

  final LibraryBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = [
      book.author.isEmpty ? '佚名' : book.author,
      if (book.readCount.isNotEmpty) book.readCount,
      if (book.wordCount.isNotEmpty) book.wordCount,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.8)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 50,
              height: 67,
              child: BookCover(url: book.coverUrl, title: book.title, radius: 8),
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
                                fontFamily: MoStyle.titleFont,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: MoStyle.inkOf(context))),
                      ),
                      if (book.inLibrary) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: cs.brightness == Brightness.dark
                                ? MoStyle.darkPrimarySoft
                                : MoStyle.primarySoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(book.localStatus == 'ready' ? '全文' : '在库',
                              style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: MoStyle.primaryStrong)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
