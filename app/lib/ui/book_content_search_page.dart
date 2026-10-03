import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/book_search.dart';
import '../core/local_books.dart';
import '../core/mo_theme.dart';
import 'widgets.dart';

/// 本机书·书内内容搜索：搜正文关键词，结果 = 每处命中一行
/// （章节名 + 前后上下文摘录，关键词高亮），点一条返回该命中，
/// 由打开方跳进阅读器对应位置。
class BookContentSearchPage extends StatefulWidget {
  const BookContentSearchPage({super.key, required this.meta});

  final LocalBookMeta meta;

  @override
  State<BookContentSearchPage> createState() => _BookContentSearchPageState();
}

class _BookContentSearchPageState extends State<BookContentSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;

  LocalBookContent? _content; // 整本已解码文本（open 时载入）
  String? _loadError;

  BookSearchResult? _result;
  String _searchedQuery = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadBook() async {
    try {
      final content = await LocalBookService.instance.open(widget.meta.id);
      if (!mounted) return;
      setState(() => _content = content);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '打开书籍失败：$e');
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        _result = null;
        _searchedQuery = '';
        _searching = false;
      });
      return;
    }
    // 输入停顿 400ms 自动搜（整本扫描在 isolate，主线程不卡）
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    final content = _content;
    if (content == null || q.isEmpty) return;
    _debounce?.cancel();
    setState(() {
      _searching = true;
      _searchedQuery = q;
    });
    try {
      // 整本文本 + 切分表一起丢进 isolate 扫描，避免大书卡 UI
      final result = await compute(
        runBookSearch,
        BookSearchArgs(
          text: content.fullText,
          chapters: content.meta.chapters,
          query: q,
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          PageHeader(title: '搜索书内内容'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: MoStyle.inputFillOf(context),
                borderRadius: BorderRadius.circular(13),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) => _search(v.trim()),
                onChanged: _onChanged,
                style: TextStyle(fontSize: 13.5, color: MoStyle.inkOf(context)),
                decoration: InputDecoration(
                  hintText: '输入关键词，搜《${widget.meta.title}》正文',
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
    if (_loadError != null) {
      return Center(
          child: Text(_loadError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.outline)));
    }
    if (_content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searching && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchedQuery.isEmpty) {
      return Center(
        child: Text('输入关键词，搜索这本书的正文',
            style: TextStyle(fontSize: 13, color: cs.outline)),
      );
    }
    final result = _result;
    if (result == null || result.hits.isEmpty) {
      return Center(
        child: Text('没有找到「$_searchedQuery」',
            style: TextStyle(fontSize: 13, color: cs.outline)),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
          child: Row(
            children: [
              Text('「$_searchedQuery」',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: cs.primary)),
              Text(
                result.truncated
                    ? ' 命中较多，仅显示前 ${result.hits.length} 处'
                    : ' 共 ${result.hits.length} 处命中',
                style: TextStyle(fontSize: 11.5, color: cs.outline),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            itemCount: result.hits.length,
            itemBuilder: (context, i) {
              final hit = result.hits[i];
              return _HitRow(
                hit: hit,
                highlightColor: cs.brightness == Brightness.dark
                    ? MoStyle.darkPrimaryStrong
                    : MoStyle.primaryStrong,
                onTap: () => Navigator.of(context).pop(hit),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 命中行：章节名 + 摘录（关键词高亮）
class _HitRow extends StatelessWidget {
  const _HitRow({
    required this.hit,
    required this.highlightColor,
    required this.onTap,
  });

  final BookSearchHit hit;
  final Color highlightColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final excerptStyle = TextStyle(
        fontSize: 13.5, height: 1.5, color: MoStyle.inkOf(context));

    final spans = <InlineSpan>[];
    final start = hit.matchStartInExcerpt.clamp(0, hit.excerpt.length);
    final end = (start + hit.matchLength).clamp(start, hit.excerpt.length);
    if (start > 0) {
      spans.add(TextSpan(text: hit.excerpt.substring(0, start)));
    }
    spans.add(TextSpan(
      text: hit.excerpt.substring(start, end),
      style: TextStyle(color: highlightColor, fontWeight: FontWeight.w800),
    ));
    if (end < hit.excerpt.length) {
      spans.add(TextSpan(text: hit.excerpt.substring(end)));
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hit.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: cs.primary)),
            const SizedBox(height: 3),
            Text.rich(
              TextSpan(style: excerptStyle, children: spans),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
