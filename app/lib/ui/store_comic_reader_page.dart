import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../models.dart';
import 'widgets.dart';

/// 漫画阅读器：竖屏滚图。整话图片列表一次下发（reader/full/v，CDN 直链），
/// 翻话走 server 实时回放；当前话打开时顺带预取下一话，切话近乎即点即看。
class StoreComicReaderPage extends ConsumerStatefulWidget {
  const StoreComicReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    required this.initialIndex,
  });

  final String bookId;
  final String title;
  final List<StoreChapter> chapters;
  final int initialIndex;

  @override
  ConsumerState<StoreComicReaderPage> createState() => _StoreComicReaderPageState();
}

class _StoreComicReaderPageState extends ConsumerState<StoreComicReaderPage> {
  late int _index;
  final ScrollController _scrollCtl = ScrollController();
  final Map<int, ComicChapterContent> _loaded = {};
  final Map<int, Future<ComicChapterContent>> _prefetch = {};
  String? _error;
  bool _loading = false;
  bool _appbarVisible = true;

  ApiClient get _api => ref.read(sessionProvider).api!;

  StoreChapter get _chapter => widget.chapters[_index];
  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.chapters.length - 1;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _openChapter(_index);
    _scrollCtl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 滚动时隐藏 AppBar（沉浸看图），停住即显示；顺带在接近底部时预取下一话
    final hide = _scrollCtl.position.pixels > 120;
    if (hide != !_appbarVisible) setState(() => _appbarVisible = !hide);
    if (_scrollCtl.position.pixels >=
        _scrollCtl.position.maxScrollExtent - 2000) {
      _prefetchChapter(_index + 1);
    }
  }

  Future<ComicChapterContent> _fetchChapter(int idx) {
    return _prefetch.putIfAbsent(idx, () {
      final ch = widget.chapters[idx];
      return _api.storeComicChapter(widget.bookId, ch.id);
    });
  }

  void _prefetchChapter(int idx) {
    if (idx < 0 || idx >= widget.chapters.length) return;
    if (_loaded.containsKey(idx) || _prefetch.containsKey(idx)) return;
    _fetchChapter(idx).then((_) {
      // 预取成功即可，读取时直接命中
    }).catchError((_) {
      _prefetch.remove(idx); // 预取失败清除，下次真正打开时重试
    });
  }

  Future<void> _openChapter(int idx) async {
    if (idx < 0 || idx >= widget.chapters.length) return;
    setState(() {
      _index = idx;
      _loading = true;
      _error = null;
    });
    try {
      final content = await _fetchChapter(idx);
      if (!mounted) return;
      setState(() {
        _loaded[idx] = content;
        _loading = false;
      });
      _prefetchChapter(idx + 1);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _switchChapter(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.chapters.length) return;
    if (_scrollCtl.hasClients) {
      _scrollCtl.jumpTo(0);
    }
    _openChapter(target);
  }

  @override
  Widget build(BuildContext context) {
    final content = _loaded[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appbarVisible
          ? AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text('${widget.title} · ${_chapter.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600)),
            )
          : null,
      body: Column(
        children: [
          Expanded(
            child: content == null
                ? (_loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : ErrorRetry(
                        message: _error ?? '加载失败',
                        onRetry: () => _openChapter(_index)))
                : ListView.builder(
                    controller: _scrollCtl,
                    itemCount: content.images.length,
                    itemBuilder: (context, i) {
                      final img = content.images[i];
                      return Image.network(
                        img.url,
                        width: double.infinity,
                        fit: BoxFit.fitWidth,
                        filterQuality: FilterQuality.medium,
                        loadingBuilder: (context, child, progress) {
                          if (progress?.expectedTotalBytes ==
                              progress?.cumulativeBytesLoaded) {
                            return child;
                          }
                          return AspectRatio(
                            aspectRatio: 3 / 4,
                            child: Center(
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70)),
                          );
                        },
                        errorBuilder: (context, e, st) => AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Icon(Icons.broken_image_rounded,
                              size: 42, color: Colors.white30),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _hasPrev ? () => _switchChapter(-1) : null,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24)),
                      child: const Text('上一话'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('${_chapter.index}/${widget.chapters.length}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _hasNext ? () => _switchChapter(1) : null,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24)),
                      child: const Text('下一话'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
