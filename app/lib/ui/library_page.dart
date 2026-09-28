import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../models.dart';
import 'book_detail_page.dart';
import 'widgets.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  final _keywordCtrl = TextEditingController();
  final _scroll = ScrollController();

  List<Book> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String _keyword = '';

  @override
  bool get wantKeepAlive => true;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _api.books(keyword: _keyword, page: 1, size: 20);
      if (!mounted) return;
      setState(() {
        _items = p.items;
        _total = p.total;
        _page = 1;
        _hasMore = _items.length < _total;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final p = await _api.books(keyword: _keyword, page: _page + 1, size: 20);
      if (!mounted) return;
      setState(() {
        _page = p.page;
        _items.addAll(p.items);
        _hasMore = _items.length < p.total;
        _loadingMore = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _submitSearch(String kw) {
    _keyword = kw.trim();
    FocusScope.of(context).unfocus();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: '搜索'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              controller: _keywordCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: _submitSearch,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索书名 / 作者',
                prefixIcon: const Icon(Icons.search, size: 22),
                suffixIcon: _keywordCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          _keywordCtrl.clear();
                          _submitSearch('');
                        },
                      ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null && _items.isEmpty) {
      return ErrorRetry(message: _error!, onRetry: _reload);
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return EmptyView(
        icon: Icons.local_library_outlined,
        title: _keyword.isEmpty ? '书库是空的' : '没有找到「$_keyword」',
        subtitle: _keyword.isEmpty
            ? '把番茄 TXT 放入服务器下载目录，等扫描导入后就会出现在这里'
            : '换个关键词试试，或确认已扫描导入',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final b = _items[i];
          return _BookTile(
            book: b,
            baseUrl: _api.baseUrl,
            onOpen: () => _openDetail(b),
          );
        },
      ),
    );
  }

  Future<void> _openDetail(Book b) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookDetailPage(book: b),
    ));
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.baseUrl, required this.onOpen});

  final Book book;
  final String baseUrl;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              height: 88,
              child: BookCover(url: book.coverUrl(baseUrl), title: book.title),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    book.author.isEmpty ? '佚名' : book.author,
                    style: TextStyle(fontSize: 13, color: cs.outline),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    book.intro.isEmpty ? '暂无简介' : book.intro,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.outline, height: 1.35),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    book.totalChapters > 0 ? '共 ${book.totalChapters} 章' : '',
                    style: TextStyle(fontSize: 12, color: cs.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
