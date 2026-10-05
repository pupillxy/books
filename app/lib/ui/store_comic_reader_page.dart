import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'widgets.dart';

/// 漫画阅读器：竖屏滚图。整话图片列表一次下发（reader/full/v，CDN 直链），
/// 翻话走 server 实时回放；当前话打开时顺带预取下一话，切话近乎即点即看。
/// 与小说阅读器同构：点按唤出菜单——顶栏从上滑下，底部面板从下滑上；
/// 未加入书架时菜单上方悬浮「加入书架」（server 轻量入库后复用通用书架）。
class StoreComicReaderPage extends ConsumerStatefulWidget {
  const StoreComicReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    required this.initialIndex,
    this.onShelf = false,
  });

  final String bookId;
  final String title;
  final List<StoreChapter> chapters;
  final int initialIndex;
  final bool onShelf;

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
  bool _menuVisible = false;
  bool _dim = false; // 夜间：压暗画面
  bool _onShelf = false;
  bool _shelfBusy = false;
  double? _scrub; // 进度条拖动中的临时话序号（未松手不加载）
  int? _imageCacheBump; // 阅读器期间的位图缓存扩容（原值，dispose 恢复）

  ApiClient get _api => ref.read(sessionProvider).api!;

  StoreChapter get _chapter => widget.chapters[_index];
  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.chapters.length - 1;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _onShelf = widget.onShelf;
    // 漫画页解码后仍有 5~10MB/张，默认 100MB 缓存必然疯狂驱逐（回滚重解码
    // = 滚动闪黑/卡顿）。阅读器期间扩容，退出恢复原值。
    final cache = PaintingBinding.instance.imageCache;
    _imageCacheBump = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 512 << 20;
    _openChapter(_index);
    _scrollCtl.addListener(_onScroll);
  }

  @override
  void dispose() {
    if (_imageCacheBump != null) {
      PaintingBinding.instance.imageCache.maximumSizeBytes = _imageCacheBump!;
    }
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 沉浸看图：滚动即收起菜单；顺带在接近底部时预取下一话
    if (_menuVisible && _scrollCtl.position.pixels > 0) {
      setState(() => _menuVisible = false);
    }
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
      _reportProgress(idx);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 阅读进度上报（fire-and-forget）。漫画行只有加入书架后才入库（books.id），
  /// 未入库时上报必然 FK 失败，直接跳过不打无效请求。
  void _reportProgress(int idx) {
    if (!_onShelf) return;
    final bid = int.tryParse(widget.bookId);
    if (bid == null) return;
    _api.saveProgress(bid, idx).catchError((_) {});
  }

  /// 加入书架：入库 + 收藏都由 server 端点完成，成功后悬浮按钮消失
  Future<void> _addToShelf() async {
    if (_shelfBusy) return;
    setState(() => _shelfBusy = true);
    try {
      await _api.storeComicShelfAdd(widget.bookId);
      if (!mounted) return;
      setState(() {
        _onShelf = true;
        _menuVisible = false;
      });
      _reportProgress(_index);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已加入书架'), behavior: SnackBarBehavior.floating));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _shelfBusy = false);
    }
  }

  void _switchTo(int idx) {
    if (idx < 0 || idx >= widget.chapters.length || idx == _index) return;
    if (_scrollCtl.hasClients) {
      _scrollCtl.jumpTo(0);
    }
    _openChapter(idx);
  }

  void _switchChapter(int delta) => _switchTo(_index + delta);

  @override
  Widget build(BuildContext context) {
    final content = _loaded[_index];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 内容层：点按唤出/收起菜单
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _menuVisible = !_menuVisible),
                child: content == null
                    ? (_loading
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : ErrorRetry(
                            message: _error ?? '加载失败',
                            onRetry: () => _openChapter(_index)))
                    : _comicList(content)),
            ),
            // 夜间压暗层
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: _dim ? Colors.black.withValues(alpha: 0.45) : null,
                ),
              ),
            ),
            // 顶栏：从上滑下
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_menuVisible,
                child: AnimatedSlide(
                  offset: _menuVisible ? Offset.zero : const Offset(0, -1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: _topBar(),
                ),
              ),
            ),
            // 底部菜单：从下滑上
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_menuVisible,
                child: AnimatedSlide(
                  offset: _menuVisible ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: _bottomMenu(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 滚图列表 ----------

  /// 漫画滚图列表。三个关键点（10/05，修"滚动跳回第一张/闪黑图"）：
  /// ① 行高用 server 下发的真实宽高提前固定（AspectRatio 包住加载/成图/错误
  ///    三态）——此前加载中 3:4 占位、加载完变真实比例，行高反复突变导致滚动
  ///    锚点漂移，体感就是"滚着滚着跑回第一张"；
  /// ② cacheExtent 预构建上下各约 2.5 屏（长图一屏一张 ≈ 上下各 2~3 张），
  ///    字节下载+解码发生在滚到之前，滚到即显示；
  /// ③ cacheWidth 限解码宽度 = 屏宽 × dpr（原图 1500×2666 全量解码 16MB/张，
  ///    一话 73 张必然把默认 100MB 缓存打爆，驱逐重解码 = 闪黑图），内存降 ~60%；
  ///    缓存上限已在 initState 扩到 512MB，可视区 ± 窗口的图全程驻留。
  Widget _comicList(ComicChapterContent content) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeW = (size.width * dpr).round().clamp(720, 2160);
    return ListView.builder(
      controller: _scrollCtl,
      itemCount: content.images.length,
      cacheExtent: size.height * 2.5,
      itemBuilder: (context, i) => _comicPage(context, content.images[i], decodeW),
    );
  }

  Widget _comicPage(BuildContext context, ComicImage img, int decodeW) {
    // 元数据缺失时退 3:4 占位比（加载完成不换行高是老行为，正常数据不会走到）
    final ratio =
        (img.width > 0 && img.height > 0) ? img.width / img.height : 3 / 4;
    return AspectRatio(
      aspectRatio: ratio,
      child: Image.network(
        img.url,
        fit: BoxFit.fill, // 槽位比例=图片真实比例，正好铺满无变形
        cacheWidth: decodeW,
        gaplessPlayback: true, // 缓存被驱逐后重解码时保留旧像素，不闪黑
        filterQuality: FilterQuality.medium,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70));
        },
        errorBuilder: (context, e, st) => Center(
            child: Icon(Icons.broken_image_rounded,
                size: 42, color: Colors.white30)),
      ),
    );
  }

  // ---------- 点击唤出工具栏（无蒙版：顶栏从上滑下，底部菜单从下滑上）----------

  /// 话名标签：上游漫画话标题通常自带「第N话」前缀，没有时补上
  String get _chapterLabel {
    final t = _chapter.title.trim();
    if (t.startsWith('第')) return t;
    return '第${_chapter.index}话 · $t';
  }

  /// 顶栏：状态栏区域（黑底）+ 返回键 + 两行标题（上行书名、下行小字话名，
  /// 长话名不再把书名一起挤没）
  Widget _topBar() {
    return Material(
      color: Colors.black,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 16, 6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    size: 20, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _chapterLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.white.withValues(alpha: 0.65)),
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

  /// 底部菜单：上一话 — 话数进度条 — 下一话 / 目录·夜间
  Widget _bottomMenu() {
    Widget menuBtn(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: Colors.white.withValues(alpha: 0.9)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.75))),
            ],
          ),
        ),
      );
    }

    final n = widget.chapters.length;
    // 黑面板直通屏幕最底（垫住系统手势条/小白条区域），内容用 sysPad 抬离；
    // 此前用 SafeArea，面板下方留白透出画面，小白条悬在漫画上很突兀
    final sysPad = MediaQuery.paddingOf(context).bottom;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 未加入书架：面板右上沿悬浮「加入书架」，随菜单一起滑入滑出
          if (!_onShelf)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(alignment: Alignment.centerRight, child: _shelfButton()),
            ),
          Material(
            color: Colors.black,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, 6 + sysPad),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (n > 1)
                      Row(
                        children: [
                          _sideBtn('上一话', _hasPrev, () => _switchChapter(-1)),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                activeTrackColor: Colors.white70,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                                overlayColor: Colors.white12,
                                valueIndicatorColor: Colors.white24,
                              ),
                              child: Slider(
                                value: (_scrub ?? _index).toDouble(),
                                max: (n - 1).toDouble(),
                                divisions: n - 1,
                                label:
                                    '第 ${widget.chapters[(_scrub ?? _index).round()].index} 话',
                                onChanged: (v) => setState(() => _scrub = v),
                                onChangeEnd: (v) {
                                  final t = v.round();
                                  setState(() => _scrub = null);
                                  _switchTo(t);
                                },
                              ),
                            ),
                          ),
                          _sideBtn('下一话', _hasNext, () => _switchChapter(1)),
                        ],
                      ),
                    Row(
                      children: [
                        Expanded(
                            child: menuBtn(
                                Icons.menu_book_outlined, '目录', _openToc)),
                        Expanded(
                            child: menuBtn(
                          _dim ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                          _dim ? '日间' : '夜间',
                          () => setState(() => _dim = !_dim),
                        )),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
    );
  }

  /// 悬浮「加入书架」：朱砂胶囊，加完即随菜单收起并消失
  Widget _shelfButton() {
    return InkWell(
      onTap: _addToShelf,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: MoStyle.primary,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(color: Color(0x66C2522C), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_shelfBusy)
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
            else
              const Icon(Icons.add_rounded, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            const Text('加入书架',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _sideBtn(String label, bool enabled, VoidCallback onTap) {
    return TextButton(
      onPressed: enabled ? onTap : null,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 14,
              color: enabled ? Colors.white : Colors.white24)),
    );
  }

  // ---------- 目录（话列表，底部上滑弹出）----------

  void _openToc() {
    final cs = Theme.of(context).colorScheme;
    final tocCtl = ScrollController();
    var tocJumped = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.transparent,
      backgroundColor: cs.surface,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        final list = widget.chapters;
        return SizedBox(
          height: h * 0.72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                child: Row(
                  children: [
                    Text('目录',
                        style: const TextStyle(
                            fontFamily: MoStyle.titleFont,
                            fontSize: 17,
                            fontWeight: FontWeight.w800)),
                    const Spacer(),
                    Text('共 ${list.length} 话',
                        style:
                            TextStyle(fontSize: 11.5, color: cs.outline)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Builder(builder: (context) {
                  // 打开目录自动定位到当前话并居中（与小说目录同构）
                  if (!tocJumped) {
                    tocJumped = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!tocCtl.hasClients) return;
                      final pos = tocCtl.position;
                      final target =
                          (_index * 48.0 - (pos.viewportDimension - 48) / 2)
                              .clamp(0.0, pos.maxScrollExtent);
                      tocCtl.jumpTo(target);
                    });
                  }
                  return ListView.builder(
                    controller: tocCtl,
                    itemExtent: 48,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final ch = list[i];
                      final cur = i == _index;
                      return ListTile(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 20),
                        title: Text(
                          '${ch.index}. ${ch.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight:
                                cur ? FontWeight.w700 : FontWeight.w400,
                            color: cur ? cs.primary : cs.onSurfaceVariant,
                          ),
                        ),
                        trailing: cur
                            ? Icon(Icons.play_circle_outline,
                                size: 16, color: cs.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          _switchTo(i);
                        },
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}
