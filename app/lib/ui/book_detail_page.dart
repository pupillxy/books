import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'reader_page.dart';
import 'widgets.dart';

/// 本地书详情：渐变封面区 + 渐变主按钮/ghost 次按钮 + 简介/目录 Tab
class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, required this.book});

  final Book book;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  BookDetailData? _detail;
  String? _error;
  bool _onShelf = false;
  int _progress = 0;

  ApiClient get _api => ref.read(sessionProvider).api!;
  Book get _book => _detail?.book ?? widget.book;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.bookDetail(widget.book.id);
      final shelf = await _api.shelf();
      var progress = 0;
      try {
        progress = await _api.progress(widget.book.id);
      } on ApiException {
        progress = 0;
      }
      if (!mounted) return;
      setState(() {
        _detail = d;
        _progress = progress;
        _onShelf = shelf.any((e) => e.book.id == widget.book.id);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _toggleShelf() async {
    try {
      if (_onShelf) {
        await _api.shelfRemove(_book.id);
        _onShelf = false;
      } else {
        await _api.shelfAdd(_book.id);
        _onShelf = true;
      }
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating));
    }
  }

  void _openReader([int? chapterIdx]) {
    final idx = chapterIdx ?? _progress;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderPage(book: _book, initialChapter: idx),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    if (_error != null && _detail == null) {
      return Scaffold(body: ErrorRetry(message: _error!, onRetry: _load));
    }
    if (_detail == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final chapters = _detail!.chapters;
    // 详情头部高度（封面 142 + 上下留白）
    const headerH = 182.0;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: NestedScrollView(
          headerSliverBuilder: (_, __) => [
            SliverAppBar(
              pinned: true,
              toolbarHeight: 54,
              centerTitle: true,
              backgroundColor:
                  dark ? MoStyle.darkPanel : const Color(0xFFF7E6D6),
              surfaceTintColor: Colors.transparent,
              title: Text('书籍详情',
                  style: TextStyle(
                      fontFamily: MoStyle.titleFont,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: MoStyle.inkOf(context))),
              expandedHeight: MediaQuery.of(context).padding.top + 54 + headerH,
              flexibleSpace: FlexibleSpaceBar(
                background: Column(
                  children: [
                    SizedBox(height: MediaQuery.of(context).padding.top + 54),
                    SizedBox(
                      height: headerH,
                      child: DetailCoverHeader(
                        coverUrl: _book.coverUrl(_api.baseUrl),
                        title: _book.title,
                        author: _book.author,
                        meta: _book.totalChapters > 0
                            ? '共 ${_book.totalChapters} 章'
                            : '章节加载中',
                        badge: _onShelf ? '在架' : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          body: Column(
            children: [
              // ---------- 按钮区 ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: GradientButton(
                        label: _progress > 0
                            ? '继续阅读 · 第 ${_progress + 1} 章'
                            : '开始阅读',
                        icon: _progress > 0
                            ? Icons.play_circle_outline
                            : Icons.menu_book_rounded,
                        onPressed: chapters.isNotEmpty ? () => _openReader() : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GhostButton(
                        label: _onShelf ? '已在书架' : '加入书架',
                        icon: _onShelf ? Icons.done_all : Icons.add,
                        onPressed: _toggleShelf,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // ---------- Tab ----------
              MoTabBar(labels: const ['简介', '目录']),
              Expanded(
                child: TabBarView(
                  children: [
                    // 简介
                    ListView(
                      padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
                      children: [
                        Text(
                          _book.intro.isEmpty ? '暂无简介' : _book.intro,
                          style: TextStyle(
                              fontSize: 13, height: 1.85, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                    // 目录
                    chapters.isEmpty
                        ? const EmptyView(icon: Icons.list_alt, title: '暂无章节')
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: chapters.length,
                            itemBuilder: (context, i) {
                              final ch = chapters[i];
                              final read = ch.idx < _progress;
                              final reading = ch.idx == _progress;
                              return ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 22),
                                title: Text(
                                  '${ch.idx + 1}. ${ch.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight:
                                        reading ? FontWeight.w700 : FontWeight.w400,
                                    color: reading
                                        ? cs.primary
                                        : read
                                            ? cs.outline
                                            : cs.onSurfaceVariant,
                                  ),
                                ),
                                trailing: reading
                                    ? Icon(Icons.play_circle_outline,
                                        size: 18, color: cs.primary)
                                    : null,
                                onTap: () => _openReader(ch.idx),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
