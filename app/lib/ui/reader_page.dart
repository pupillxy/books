import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/reader_source.dart';
import '../core/session.dart';
import '../models.dart';
import 'widgets.dart';

// ============================================================
// 分页排版：TextPainter 逐段测量，放不下的段落按行拆分
// ============================================================

class PagedChapter {
  final List<List<String>> pages; // 每页若干行片段
  final List<int> pageStartChars; // 每页首字符在整章中的偏移（换字号/屏幕后恢复位置用）
  const PagedChapter({required this.pages, required this.pageStartChars});

  static int pageForChar(PagedChapter pc, int charOffset) {
    var page = 0;
    for (var i = 0; i < pc.pageStartChars.length; i++) {
      if (pc.pageStartChars[i] <= charOffset) page = i;
    }
    return page;
  }
}

class ReaderPaginator {
  /// 把整章内容按可用的宽高分页
  static PagedChapter paginate({
    required String content,
    required double maxWidth,
    required double maxHeight,
    required TextStyle style,
  }) {
    final paragraphs = content
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map(_indent)
        .toList();

    final pages = <List<String>>[];
    final starts = <int>[];
    var charCount = 0;
    var cur = <String>[];
    var used = 0.0;
    var curStart = 0;

    void pushPage() {
      if (cur.isNotEmpty) {
        pages.add(List.of(cur));
        starts.add(curStart);
      }
      cur = <String>[];
      used = 0;
      curStart = charCount;
    }

    for (final p in paragraphs) {
      final tp = TextPainter(
        text: TextSpan(text: p, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);

      // 整段能放进当前页剩余空间
      if (tp.height <= maxHeight - used + 0.01) {
        cur.add(p);
        charCount += p.length;
        used += tp.height;
        tp.dispose();
        continue;
      }
      // 段落跨页：先提交当前页，再按行拆分
      pushPage();
      final lineH = (style.fontSize ?? 16) * (style.height ?? 1.6);
      var lineStart = 0;
      while (lineStart < p.length) {
        TextRange range;
        try {
          range = tp.getLineBoundary(TextPosition(offset: lineStart));
        } catch (_) {
          range = TextRange(start: lineStart, end: math.min(lineStart + 1, p.length));
        }
        if (range.end <= range.start) break;
        final line = p.substring(range.start, math.min(range.end, p.length));
        if (used + lineH > maxHeight + 0.01) pushPage();
        cur.add(line);
        charCount += line.length;
        used += lineH;
        lineStart = range.end;
      }
      tp.dispose();
    }
    pushPage();
    if (pages.isEmpty) {
      pages.add(const []);
      starts.add(0);
    }
    return PagedChapter(pages: pages, pageStartChars: starts);
  }

  static String _indent(String p) =>
      (p.startsWith('　') || p.startsWith(' ')) ? p : '　　$p';
}

// ============================================================
// 阅读主题：6 套（羊皮纸/纯白/浅米/护眼绿/石板灰/夜间）
// ============================================================

class ReaderTheme {
  final String name;
  final Color bg;
  final Color fg;
  final Color sub;

  const ReaderTheme(this.name, {required this.bg, required this.fg, required this.sub});
}

const kReaderThemes = [
  ReaderTheme('羊皮纸', bg: Color(0xFFF6F3EA), fg: Color(0xFF2C2C2C), sub: Color(0xFF9C917C)),
  ReaderTheme('纯白', bg: Color(0xFFFFFFFF), fg: Color(0xFF252525), sub: Color(0xFF9A9A9A)),
  ReaderTheme('浅米', bg: Color(0xFFEAE4D6), fg: Color(0xFF3A3326), sub: Color(0xFF948A72)),
  ReaderTheme('护眼绿', bg: Color(0xFFD9ECDC), fg: Color(0xFF29422F), sub: Color(0xFF6D8A72)),
  ReaderTheme('石板灰', bg: Color(0xFFE9EBF1), fg: Color(0xFF2C3038), sub: Color(0xFF8F94A3)),
  ReaderTheme('夜间', bg: Color(0xFF14171F), fg: Color(0xFFB9BFCF), sub: Color(0xFF5C6270)),
];

// ============================================================
// 阅读器页面
// ============================================================

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.book,
    required this.initialChapter,
    this.source,
    this.initialCharOffset, // 进入时定位到章内字符偏移（书内搜索跳转用）
  });

  final Book book;
  final int initialChapter;

  /// 阅读数据源：null = 服务端在线书（走 API）；本机书传 LocalReaderSource
  final ReaderSource? source;

  /// 打开时定位到 initialChapter 内容里的这个字符偏移（null = 常规恢复进度）
  final int? initialCharOffset;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const _padH = 30.0; // 正文水平留白（规范）
  static const _chromeH = 76.0; // 页眉 + 页脚 + 留白

  static const _fontFamilies = ['宋体', '黑体', '楷体'];
  static const _fontFamilyValues = ['serif', null, 'KaiTi'];

  late final PageController _pageController;
  final _chapterCache = <int, Chapter>{};
  List<ChapterMeta>? _toc; // 目录缓存

  int _chapterIdx = 0;
  String? _content;
  String? _chapterTitle;
  String? _error;
  bool _loading = true;
  bool _menuVisible = false;

  double _fontSize = 17; // 规范默认 17
  double _lineHeight = 1.9; // 规范默认 1.9
  int _themeIdx = 0;
  int _ffIdx = 0; // 字体：宋/黑/楷

  // 分页缓存（按 章节+排版+尺寸 失效）
  PagedChapter? _paged;
  String _pagedKey = '';
  int _pagedChapter = -1;
  int? _pendingPage; // 新章节要跳到的页
  int? _pendingChar; // 换排版要恢复的字符偏移
  int? _pendingLocate; // 进入时定位的章内字符偏移（搜索跳转，消费一次）
  int _locateIdx = -1; // 滚动模式：待定位的中心章条目下标
  GlobalKey? _locateKey; // 滚动模式：定位条目的 key（ensureVisible 用）

  // 上下滚动模式（false = 左右翻页）。
  // 连续滚动模型：当前章为"中心"（offset 0），前章向负方向、后章向正方向无缝拼接，
  // 中心锚定保证挂载邻章时已读内容像素位置不动（无跳动），视口内最多呈现两章交界。
  bool _scrollMode = true;
  final ScrollController _scrollCtl = ScrollController();
  final GlobalKey _centerKey = GlobalKey();
  final List<int> _leadBlocks = []; // 中心章之前的章，阅读顺序：远→近
  final List<int> _trailBlocks = []; // 中心章之后的章，阅读顺序：近→远
  int? _centerBlock;
  List<_ScrollItem> _leadItems = const [];
  List<_ScrollItem> _centerItems = const [];
  List<_ScrollItem> _trailItems = const [];
  final Map<int, GlobalKey> _blockKeys = {}; // 章首标题 key（量测章起点）
  final Map<int, double> _blockStarts = {}; // 章 → 起始滚动偏移（相对中心，可为负）
  final Set<int> _mounting = {}; // 正在挂载的邻章（去重并发）
  final Map<int, DateTime> _mountFailedAt = {}; // 邻章挂载失败时间（冷却后可重试）
  double? _pendingPageRatio; // 滚动→分页切换时要恢复的页面比例
  int _lastScrollPct = -1; // 页脚百分比节流
  DateTime _lastPosSave = DateTime.fromMillisecondsSinceEpoch(0); // 位置落盘节流
  Brightness _appBrightness = Brightness.light; // App 当前主题亮度（退出时恢复状态栏用）

  late final ReaderSource _source; // initState 里初始化（在线书默认 API 源）

  int get _total => _source.totalChapters;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appBrightness = Theme.of(context).brightness;
  }

  @override
  void initState() {
    super.initState();
    _source = widget.source ??
        ApiReaderSource(ref.read(sessionProvider).api!, widget.book);
    _pageController = PageController();
    _scrollCtl.addListener(_onScroll);
    _chapterIdx = widget.initialChapter;
    _pendingLocate = widget.initialCharOffset;
    _restorePrefsAndLoad();
  }

  Future<void> _restorePrefsAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = prefs.getDouble('rd.font') ?? 17;
      _lineHeight = prefs.getDouble('rd.lh') ?? 1.9;
      _themeIdx = prefs.getInt('rd.theme') ?? 0;
      _ffIdx = prefs.getInt('rd.ff') ?? 0;
      _scrollMode = prefs.getBool('rd.scroll') ?? true;
    });
    _applySystemUi();
    // 带定位进入（搜索跳转）：不做进度恢复，直接定位到命中处
    final locating = _pendingLocate != null;
    final savedCh = prefs.getInt('rd.ch.${_source.persistKey}');
    final sameCh = savedCh == _chapterIdx;
    final restorePage =
        sameCh && !locating ? (prefs.getInt('rd.pg.${_source.persistKey}') ?? 0) : 0;
    final restoreScroll =
        sameCh && !locating ? prefs.getDouble('rd.so.${_source.persistKey}') : null;
    await _loadChapter(_chapterIdx,
        page: restorePage, scrollOffset: restoreScroll);
  }

  /// 阅读顺序章序列：远前章 → 中心章 → 远后章
  List<int> get _orderedBlocks => [
        ..._leadBlocks,
        if (_centerBlock != null) _centerBlock!,
        ..._trailBlocks,
      ];

  /// 滚动模式页脚百分比：当前章内偏移比例（0-100）
  int _scrollPct() {
    if (!_scrollCtl.hasClients) return _lastScrollPct < 0 ? 0 : _lastScrollPct;
    final start = _blockStarts[_chapterIdx];
    double? end;
    final ordered = _orderedBlocks;
    final curPos = ordered.indexOf(_chapterIdx);
    if (curPos >= 0) {
      for (var i = curPos + 1; i < ordered.length; i++) {
        final s = _blockStarts[ordered[i]];
        if (s != null) {
          end = s;
          break;
        }
      }
    }
    end ??= _scrollCtl.position.maxScrollExtent;
    if (start == null || end <= start) {
      return _lastScrollPct < 0 ? 0 : _lastScrollPct;
    }
    return (((_scrollCtl.offset - start) / (end - start)).clamp(0.0, 1.0) * 100)
        .round();
  }

  void _onScroll() {
    if (!mounted || !_scrollMode) return;
    if (_scrollCtl.hasClients) {
      final pos = _scrollCtl.position;
      final vp = pos.viewportDimension;
      // 接近章尾/章首 → 预挂载邻章（已挂载则幂等跳过）
      if (pos.pixels > pos.maxScrollExtent - vp * 1.5) _mountNeighbor(1);
      if (pos.pixels < pos.minScrollExtent + vp * 1.5) _mountNeighbor(-1);
    }
    _scrollMaintenance();
    final pct = _scrollPct();
    if (pct != _lastScrollPct) setState(() => _lastScrollPct = pct);
    // 滚动过程中节流落盘（进程被杀也能恢复到大致位置）
    final now = DateTime.now();
    if (now.difference(_lastPosSave).inMilliseconds > 2000) {
      _lastPosSave = now;
      _persistScrollPos();
    }
  }

  /// 保存滚动阅读位置：当前章 + 章内偏移
  void _persistScrollPos() {
    if (!_scrollMode || !_scrollCtl.hasClients) return;
    final start = _blockStarts[_chapterIdx] ?? 0;
    final within = _scrollCtl.offset - start;
    SharedPreferences.getInstance().then((p) {
      p.setInt('rd.ch.${_source.persistKey}', _chapterIdx);
      if (within > 0) {
        p.setDouble('rd.so.${_source.persistKey}', within);
      } else {
        p.remove('rd.so.${_source.persistKey}');
      }
    });
  }

  /// 量测各章起点 + 把"当前章"推进到视口顶部所在章
  void _scrollMaintenance() {
    if (!_scrollCtl.hasClients) return;
    void measure(int ch) {
      final ctx = _blockKeys[ch]?.currentContext;
      if (ctx == null) return;
      final ro = ctx.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        final vp = RenderAbstractViewport.of(ro);
        _blockStarts[ch] = vp.getOffsetToReveal(ro, 0).offset;
      }
    }

    if (_centerBlock != null) measure(_centerBlock!);
    for (final ch in _leadBlocks) {
      measure(ch);
    }
    for (final ch in _trailBlocks) {
      measure(ch);
    }

    // 当前章 = 视口顶所在块：第一个"已知起点在视口顶下方"的块的前一块
    final off = _scrollCtl.offset;
    final ordered = _orderedBlocks;
    int? cur = ordered.isEmpty ? null : ordered.first;
    for (final ch in ordered) {
      final s = _blockStarts[ch];
      if (s != null && s > off + 1) break;
      cur = ch;
    }
    if (cur != null && cur != _chapterIdx && _chapterCache.containsKey(cur)) {
      setState(() {
        _chapterIdx = cur!;
        _chapterTitle = _chapterCache[cur]?.title ?? _chapterTitle;
        _lastScrollPct = -1;
      });
      _source.saveProgress(cur);
      _lastPosSave = DateTime.now();
      _persistScrollPos(); // 跨章立即落盘，避免杀进程丢章号
    }
  }

  void _applySystemUi() {
    final dark = kReaderThemes[_themeIdx].bg.computeLuminance() < 0.35;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    ));
  }

  Future<Chapter> _fetchChapter(int idx) async {
    final cached = _chapterCache[idx];
    if (cached != null) return cached;
    final ch = await _source.loadChapter(idx);
    _chapterCache[idx] = ch;
    return ch;
  }

  Future<void> _loadChapter(int idx,
      {int page = 0, double? scrollOffset}) async {
    if (idx < 0 || (_total > 0 && idx >= _total)) return;
    final locate = _pendingLocate;
    _pendingLocate = null; // 只在进入时消费一次
    setState(() {
      _loading = true;
      _error = null;
      _menuVisible = false;
      _pendingPageRatio = null;
    });
    try {
      final ch = await _fetchChapter(idx);
      if (!mounted) return;
      setState(() {
        _chapterIdx = idx;
        _chapterTitle = ch.title;
        _content = ch.content;
        if (!_scrollMode && locate != null) {
          // 分页模式：交给 _ensurePaginated 按 _pendingChar 落到命中页
          _pendingPage = null;
          _pendingChar = locate;
        } else {
          _pendingPage = _scrollMode ? null : page;
        }
        _loading = false;
        if (_scrollMode) {
          // 当前章居中，前后邻章另行预挂
          _leadBlocks.clear();
          _trailBlocks.clear();
          _centerBlock = idx;
          _blockStarts.clear();
          _blockStarts[idx] = 0;
          _mounting.clear();
          _mountFailedAt.clear();
          _rebuildScrollItems();
        }
      });
      if (_scrollMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollMode || !_scrollCtl.hasClients) return;
          if (locate != null) {
            _locateInCenter(locate);
          } else {
            _scrollCtl.jumpTo(
                (scrollOffset ?? 0.0).clamp(0.0, _scrollCtl.position.maxScrollExtent));
          }
        });
        // 急切挂载前后邻章，保证章界无缝
        _mountNeighbor(1);
        _mountNeighbor(-1);
      }
      _source.saveProgress(idx);
      _prefetch(idx + 1);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 滚动模式：按章内字符偏移找到所在段落条目，跳过去并精确定位
  void _locateInCenter(int charOffset) {
    var target = -1;
    for (var i = 0; i < _centerItems.length; i++) {
      final it = _centerItems[i];
      if (it.isTitle || it.charStart == null) continue;
      if (it.charStart! <= charOffset) {
        target = i;
      } else {
        break;
      }
    }
    if (target < 0) {
      // 命中在章首标题行内：直接回章首
      if (_scrollCtl.hasClients) _scrollCtl.jumpTo(0);
      return;
    }
    _locateRound(target, 0);
  }

  /// SliverList 懒构建：先按文字测量估算目标条目的像素位置跳过去，
  /// 目标条目进入构建范围后挂 key 用 ensureVisible 精校；
  /// 估算被 maxScrollExtent 截断时（章很长）逐轮续跳
  void _locateRound(int itemIdx, int round) {
    if (!mounted || !_scrollMode || !_scrollCtl.hasClients) return;
    final est = _estimateItemOffset(itemIdx);
    final vp = _scrollCtl.position.viewportDimension;
    _scrollCtl.jumpTo(
        (est - vp * 0.18).clamp(0.0, _scrollCtl.position.maxScrollExtent));
    setState(() {
      _locateIdx = itemIdx;
      _locateKey ??= GlobalKey();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _locateKey?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.2,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic);
        _clearLocate();
      } else if (round < 12) {
        _locateRound(itemIdx, round + 1);
      } else {
        _clearLocate();
      }
    });
  }

  void _clearLocate() {
    if (!mounted) return;
    setState(() {
      _locateIdx = -1;
      _locateKey = null;
    });
  }

  /// 中心章第 itemIdx 个条目顶边在滚动坐标里的位置（章首标题 = 条目 0）。
  /// 与 _scrollItemView 用同样的样式/宽度测量，估算即真实高度
  double _estimateItemOffset(int itemIdx) {
    final w = MediaQuery.of(context).size.width - _padH * 2;
    final scaler = MediaQuery.textScalerOf(context);
    var h = 4.0; // 中心章 SliverPadding 顶部
    for (var i = 0; i < itemIdx && i < _centerItems.length; i++) {
      final it = _centerItems[i];
      if (it.isTitle) {
        h += 8 +
            12 +
            _measureTextHeight(
                it.text,
                TextStyle(
                    fontSize: _fontSize + 2,
                    height: 1.45,
                    fontWeight: FontWeight.w700),
                w,
                scaler);
      } else {
        h += _measureTextHeight(it.text, _bodyStyle(), w, scaler);
      }
    }
    return h;
  }

  double _measureTextHeight(
      String text, TextStyle style, double w, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: w);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  Future<void> _prefetch(int idx) async {
    if (idx < 0 || (_total > 0 && idx >= _total)) return;
    if (_chapterCache.containsKey(idx)) return;
    try {
      await _fetchChapter(idx);
    } catch (_) {/* 预取失败静默 */}
  }

  // ---------- 目录 ----------

  Future<List<ChapterMeta>> _ensureToc() async {
    if (_toc != null) return _toc!;
    return _toc = await _source.loadToc();
  }

  void _openToc() async {
    final cs = Theme.of(context).colorScheme;
    final tocCtl = ScrollController();
    var tocJumped = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.transparent,
      backgroundColor: cs.surface,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
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
                    FutureBuilder<List<ChapterMeta>>(
                      future: _ensureToc(),
                      builder: (context, snap) => Text(
                        snap.hasData ? '共 ${snap.data!.length} 章' : '',
                        style: TextStyle(fontSize: 11.5, color: cs.outline),
                      ),
                    ),
                    IconButton(
                      tooltip: '搜索章节',
                      icon: const Icon(Icons.search, size: 20),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openChapterSearch();
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<ChapterMeta>>(
                  future: _ensureToc(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final list = snap.data!;
                    // 打开目录自动定位到当前章并居中（官方同构）
                    if (!tocJumped) {
                      tocJumped = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!tocCtl.hasClients) return;
                        final cur = list.indexWhere((c) => c.idx == _chapterIdx);
                        if (cur < 0) return;
                        final pos = tocCtl.position;
                        final target = (cur * 48.0 - (pos.viewportDimension - 48) / 2)
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
                        final cur = ch.idx == _chapterIdx;
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                          title: Text(
                            '${ch.idx + 1}. ${ch.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: cur ? FontWeight.w700 : FontWeight.w400,
                              color: cur ? cs.primary : cs.onSurfaceVariant,
                            ),
                          ),
                          trailing:
                              cur ? Icon(Icons.play_circle_outline, size: 16, color: cs.primary) : null,
                          onTap: () {
                            Navigator.pop(ctx);
                            _loadChapter(ch.idx);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    tocCtl.dispose();
  }

  void _flip(int dir) {
    if (_loading) return;
    if (_scrollMode) {
      // 连续滚动列表：直接滚一屏，跨章由挂载块无缝衔接
      if (!_scrollCtl.hasClients) return;
      final pos = _scrollCtl.position;
      final target = _scrollCtl.offset + dir * pos.viewportDimension * 0.85;
      _scrollCtl.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (_paged == null) return;
    final p = _pageController.hasClients ? (_pageController.page?.round() ?? 0) : 0;
    final target = p + dir;
    if (target < 0) {
      if (_chapterIdx > 0) _loadChapter(_chapterIdx - 1, page: -1);
      return;
    }
    if (target >= _paged!.pages.length) {
      if (_chapterIdx < _total - 1) _loadChapter(_chapterIdx + 1);
      return;
    }
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  void _setFont(double v) {
    v = v.clamp(13, 24);
    _rememberCharOffset();
    setState(() => _fontSize = v);
    SharedPreferences.getInstance().then((p) => p.setDouble('rd.font', v));
  }

  void _setLineHeight(double v) {
    _rememberCharOffset();
    setState(() => _lineHeight = v);
    SharedPreferences.getInstance().then((p) => p.setDouble('rd.lh', v));
  }

  void _setTheme(int i) {
    setState(() => _themeIdx = i);
    _applySystemUi();
    SharedPreferences.getInstance().then((p) => p.setInt('rd.theme', i));
  }

  void _setFontFamily(int i) {
    _rememberCharOffset();
    setState(() => _ffIdx = i);
    SharedPreferences.getInstance().then((p) => p.setInt('rd.ff', i));
  }

  /// 切换 翻页/滚动 模式，按比例恢复当前位置
  void _setScrollMode(bool v) {
    if (_scrollMode == v) return;
    double ratio = 0;
    if (v) {
      // 分页 → 滚动：当前页 / 总页数
      if (_paged != null &&
          _paged!.pages.length > 1 &&
          _pageController.hasClients) {
        ratio = ((_pageController.page ?? 0) / (_paged!.pages.length - 1))
            .clamp(0.0, 1.0);
      }
    } else if (_scrollCtl.hasClients) {
      // 滚动 → 分页：当前章内偏移比例
      final start = _blockStarts[_chapterIdx] ?? 0;
      double? end;
      final ordered = _orderedBlocks;
      final curPos = ordered.indexOf(_chapterIdx);
      if (curPos >= 0) {
        for (var i = curPos + 1; i < ordered.length; i++) {
          final s = _blockStarts[ordered[i]];
          if (s != null) {
            end = s;
            break;
          }
        }
      }
      end ??= _scrollCtl.position.maxScrollExtent;
      final span = end - start;
      if (span > 0) {
        ratio = ((_scrollCtl.offset - start) / span).clamp(0.0, 1.0);
      }
    }
    setState(() => _scrollMode = v);
    SharedPreferences.getInstance().then((p) => p.setBool('rd.scroll', v));
    if (v) {
      // 初始化滚动块：当前章居中，前后邻章预挂
      _leadBlocks.clear();
      _trailBlocks.clear();
      _centerBlock = _chapterIdx;
      _blockStarts.clear();
      _blockStarts[_chapterIdx] = 0;
      _mounting.clear();
      _mountFailedAt.clear();
      _rebuildScrollItems();
      _mountNeighbor(1);
      _mountNeighbor(-1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollCtl.hasClients) return;
        _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent * ratio);
      });
    } else if (_paged != null && _pagedChapter == _chapterIdx) {
      // 已有当前章节分页：直接按比例跳页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients || _paged == null) return;
        final target =
            (ratio * (_paged!.pages.length - 1)).round().clamp(0, _paged!.pages.length - 1);
        _pageController.jumpToPage(target);
      });
    } else {
      // 需要重新分页：交给 _ensurePaginated 消费
      _pendingPageRatio = ratio;
    }
  }

  void _rememberCharOffset() {
    if (_paged == null || _pagedChapter != _chapterIdx) return;
    final idx = _pageController.hasClients ? (_pageController.page?.round() ?? 0) : 0;
    if (idx >= 0 && idx < _paged!.pageStartChars.length) {
      _pendingChar = _paged!.pageStartChars[idx];
    }
  }

  TextStyle _bodyStyle() => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        color: kReaderThemes[_themeIdx].fg,
        fontFamily: _fontFamilyValues[_ffIdx],
      );

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final theme = kReaderThemes[_themeIdx];
    return Scaffold(
      backgroundColor: theme.bg,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _flip(-1),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _flip(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _flip(1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _flip(1),
        },
        child: Focus(
          autofocus: true,
          child: AnimatedBuilder(
            animation: _pageController,
            builder: (context, _) => _buildBody(theme),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ReaderTheme theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensurePaginated(constraints);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (_scrollMode) {
              // 滚动模式：点按只唤出/收起菜单，不做左右翻页
              setState(() => _menuVisible = !_menuVisible);
              return;
            }
            final w = constraints.maxWidth;
            if (d.localPosition.dx < w * 0.33) {
              _flip(-1);
              if (_menuVisible) setState(() => _menuVisible = false);
            } else if (d.localPosition.dx > w * 0.67) {
              _flip(1);
              if (_menuVisible) setState(() => _menuVisible = false);
            } else {
              setState(() => _menuVisible = !_menuVisible);
            }
          },
          child: Stack(
            children: [
              Positioned.fill(child: _buildReader(constraints, theme)),
              // 点击唤出：顶栏（含状态栏背景）从上滑下 + 底部菜单从下滑上，无蒙版
              // 顶栏
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
                    child: _overlayTopBar(theme),
                  ),
                ),
              ),
              // 底部菜单
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
                    child: _overlayBottomMenu(theme),
                  ),
                ),
              ),
              if (_loading) const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _ensurePaginated(BoxConstraints c) {
    if (_content == null || _scrollMode) return;
    final topInset = MediaQuery.of(context).padding.top; // 状态栏高度
    final w = c.maxWidth - _padH * 2;
    final h = c.maxHeight - _chromeH - topInset;
    final key =
        '$_chapterIdx|$_fontSize|$_lineHeight|$_ffIdx|${w.toStringAsFixed(1)}x${h.toStringAsFixed(1)}';
    if (key == _pagedKey) return;

    final sameChapter = _pagedChapter == _chapterIdx;
    _rememberCharOffset();
    _paged = ReaderPaginator.paginate(
      content: _content!,
      maxWidth: w,
      maxHeight: h,
      style: _bodyStyle(),
    );
    _pagedKey = key;
    _pagedChapter = _chapterIdx;

    int target;
    if (_pendingPageRatio != null) {
      target = (_pendingPageRatio! * math.max(_paged!.pages.length - 1, 0)).round();
      _pendingPageRatio = null;
    } else if (_pendingPage != null) {
      target = _pendingPage! < 0 ? _paged!.pages.length - 1 : _pendingPage!;
      _pendingPage = null;
    } else if (_pendingChar != null) {
      target = PagedChapter.pageForChar(_paged!, _pendingChar!);
      _pendingChar = null;
    } else if (sameChapter) {
      target = 0;
    } else {
      target = 0;
    }
    target = target.clamp(0, _paged!.pages.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      final cur = _pageController.page?.round() ?? -1;
      if (cur != target) _pageController.jumpToPage(target);
    });
  }

  Widget _buildReader(BoxConstraints c, ReaderTheme theme) {
    if (_error != null) {
      return ErrorRetry(message: _error!, onRetry: () => _loadChapter(_chapterIdx));
    }
    if (_loading || _content == null) {
      return const SizedBox.shrink();
    }
    final now = TimeOfDay.now().format(context);

    // 进度：滚动模式按当前章内偏移，分页模式按页码
    int pct = 0;
    double prog = 0;
    if (_scrollMode) {
      pct = _scrollPct();
      prog = pct / 100.0;
    } else {
      final paged = _paged;
      if (paged != null && paged.pages.isNotEmpty) {
        final pageIndex = _pageController.hasClients
            ? (_pageController.page?.round() ?? 0).clamp(0, paged.pages.length - 1)
            : 0;
        pct = ((pageIndex + 1) / paged.pages.length * 100).round().clamp(0, 100);
        prog = (pageIndex + 1) / paged.pages.length;
      }
    }

    return Column(
      children: [
        // 状态栏避让
        SizedBox(height: MediaQuery.of(context).padding.top),
        // 页眉：章节名
        SizedBox(
          height: 30,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _chapterTitle ?? '第 ${_chapterIdx + 1} 章',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.sub),
              ),
            ),
          ),
        ),
        Expanded(
          child: _scrollMode ? _scrollBody(theme) : _pageBodyView(theme),
        ),
        // 页脚：时间 + 3px 进度条 + 百分比
        SizedBox(
          height: 34,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Row(
              children: [
                Text(now, style: TextStyle(fontSize: 11, color: theme.sub)),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: prog,
                      minHeight: 3,
                      backgroundColor: theme.sub.withValues(alpha: 0.25),
                      valueColor: AlwaysStoppedAnimation(theme.sub),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text('$pct%',
                    style: TextStyle(
                        fontSize: 11, color: theme.sub, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pageBodyView(ReaderTheme theme) {
    final paged = _paged;
    if (paged == null) return const SizedBox.shrink();
    return PageView.builder(
      key: ValueKey('pv-$_chapterIdx-$_fontSize-$_lineHeight-$_ffIdx'),
      controller: _pageController,
      itemCount: paged.pages.length,
      onPageChanged: (i) {
        setState(() {});
        SharedPreferences.getInstance().then((p) {
          p.setInt('rd.ch.${_source.persistKey}', _chapterIdx);
          p.setInt('rd.pg.${_source.persistKey}', i);
        });
      },
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: 4),
        child: _pageBody(paged.pages[i], theme),
      ),
    );
  }

  /// 滚动主体：中心锚定三段 sliver（前章 / 当前章 / 后章）。
  /// 挂载邻章只向两端扩展，已读内容像素位置不动 → 跨章无跳动。
  Widget _scrollBody(ReaderTheme theme) {
    SliverPadding sliverList(List<_ScrollItem> items, EdgeInsets padding,
            {Key? key, bool isCenter = false}) =>
        SliverPadding(
          key: key,
          padding: padding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final view = _scrollItemView(items[i], theme);
                // 书内搜索定位：给目标条目挂 key（仅中心章）
                if (isCenter && i == _locateIdx && _locateKey != null) {
                  return KeyedSubtree(key: _locateKey, child: view);
                }
                return view;
              },
              childCount: items.length,
            ),
          ),
        );

    return CustomScrollView(
      controller: _scrollCtl,
      center: _centerKey,
      slivers: [
        if (_leadItems.isNotEmpty)
          sliverList(_leadItems, const EdgeInsets.symmetric(horizontal: _padH)),
        sliverList(_centerItems, const EdgeInsets.fromLTRB(_padH, 4, _padH, 0),
            key: _centerKey, isCenter: true),
        if (_trailItems.isNotEmpty)
          sliverList(_trailItems, const EdgeInsets.symmetric(horizontal: _padH)),
        SliverToBoxAdapter(child: _scrollFooter(theme)),
      ],
    );
  }

  /// 章尾页脚：下一章加载中 / 加载失败点按重试 / 已是最后一章
  Widget _scrollFooter(ReaderTheme theme) {
    final last = _trailBlocks.isNotEmpty ? _trailBlocks.last : _centerBlock;
    final next = (last ?? -1) + 1;
    Widget hint(String text, {Color? color}) => Padding(
          padding: const EdgeInsets.fromLTRB(_padH, 18, _padH, 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(text,
                style: TextStyle(
                    fontSize: 12.5, color: color ?? theme.fg.withValues(alpha: 0.4))),
          ]),
        );
    if (_total > 0 && next >= _total) {
      return hint('已经是最后一章了');
    }
    if (_mounting.contains(next)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(_padH, 18, _padH, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                  strokeWidth: 1.8, color: theme.fg.withValues(alpha: 0.45))),
          const SizedBox(width: 8),
          Text('下一章加载中…',
              style: TextStyle(
                  fontSize: 12.5, color: theme.fg.withValues(alpha: 0.45))),
        ]),
      );
    }
    if (_mountFailedAt.containsKey(next)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(_padH, 12, _padH, 8),
        child: Center(
          child: InkWell(
            onTap: () {
              setState(() => _mountFailedAt.remove(next));
              _mountNeighbor(1, force: true);
            },
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: theme.fg.withValues(alpha: 0.25), width: 1)),
              child: Text('下一章加载失败，点按重试',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.fg.withValues(alpha: 0.6))),
            ),
          ),
        ),
      );
    }
    // 正常状态：留出与旧版一致的底部留白
    return const SizedBox(height: 24, key: ValueKey('scroll-footer-idle'));
  }

  Widget _scrollItemView(_ScrollItem it, ReaderTheme theme) {
    if (it.isTitle) {
      // 章首标题：挂 GlobalKey 供量测章起点
      return Padding(
        key: _blockKeys.putIfAbsent(it.ch, () => GlobalKey()),
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(
          it.text,
          style: TextStyle(
            fontSize: _fontSize + 2,
            height: 1.45,
            fontWeight: FontWeight.w700,
            color: theme.fg,
          ),
        ),
      );
    }
    return Text(it.text, style: _bodyStyle());
  }

  /// 预取并挂载一章邻章（幂等；失败记入冷却 6s 后可重试，不再永久拉黑）
  Future<void> _mountNeighbor(int dir, {bool force = false}) async {
    final cur = _centerBlock;
    if (cur == null) return;
    final int target;
    if (dir < 0) {
      target = (_leadBlocks.isNotEmpty ? _leadBlocks.first : cur) - 1;
    } else {
      target = (_trailBlocks.isNotEmpty ? _trailBlocks.last : cur) + 1;
    }
    if (target < 0 || (_total > 0 && target >= _total)) return;
    if (target == _centerBlock ||
        _leadBlocks.contains(target) ||
        _trailBlocks.contains(target) ||
        _mounting.contains(target)) {
      return;
    }
    // 失败冷却：6s 内不自动重试（force 跳过，供页脚「点按重试」用）
    if (!force) {
      final failAt = _mountFailedAt[target];
      if (failAt != null && DateTime.now().difference(failAt).inSeconds < 6) {
        return;
      }
    }
    _mounting.add(target);
    try {
      await _fetchChapter(target);
    } catch (_) {
      if (mounted) {
        setState(() => _mountFailedAt[target] = DateTime.now());
        // 用户常停在章尾不动（无滚动事件），冷却过后自动补一次重试；
        // 仅补一次，仍失败则留在页脚「点按重试」，避免对不可用章打风暴
        Future.delayed(const Duration(seconds: 7), () {
          if (mounted &&
              _scrollMode &&
              _mountFailedAt.containsKey(target) &&
              !_mounting.contains(target)) {
            _mountNeighbor(dir);
          }
        });
      }
      return;
    } finally {
      _mounting.remove(target);
    }
    if (!mounted) return;
    if (target == _centerBlock ||
        _leadBlocks.contains(target) ||
        _trailBlocks.contains(target)) {
      return;
    }
    // 顺向挂载时新块起点 = 挂载前的 maxScrollExtent（量测前先用种子值）
    final seed = (dir > 0 && _scrollCtl.hasClients)
        ? _scrollCtl.position.maxScrollExtent
        : null;
    setState(() {
      _mountFailedAt.remove(target);
      if (dir < 0) {
        _leadBlocks.insert(0, target);
      } else {
        _trailBlocks.add(target);
        if (seed != null) _blockStarts[target] = seed;
      }
      _rebuildScrollItems();
    });
    unawaited(_prefetch(target + dir)); // 链式预取更远一章
  }

  /// 由已挂载章重建三段扁平条目（章首标题 + 缩进段落）
  void _rebuildScrollItems() {
    List<_ScrollItem> build(int ch) {
      final c = _chapterCache[ch];
      final items = <_ScrollItem>[
        _ScrollItem(ch: ch, isTitle: true, text: c?.title ?? '第 ${ch + 1} 章'),
      ];
      final content = c?.content;
      if (content != null) {
        // 按 '\n' 切分并累加偏移（与章节切分表同一坐标系），段落记录章内起点，
        // 供书内搜索定位
        var off = 0;
        for (final line in content.split('\n')) {
          final p = line.trim();
          if (p.isNotEmpty) {
            items.add(_ScrollItem(
                ch: ch,
                isTitle: false,
                text: ReaderPaginator._indent(p),
                charStart: off + line.indexOf(p)));
          }
          off += line.length + 1; // +1 为被 split 吃掉的换行
        }
      }
      return items;
    }

    // 前章 sliver 为反向增长：索引 0 最靠近中心 → 远→近倒序展开
    _leadItems = [for (final ch in _leadBlocks.reversed) ...build(ch)];
    _centerItems = _centerBlock == null ? const [] : build(_centerBlock!);
    _trailItems = [for (final ch in _trailBlocks) ...build(ch)];
  }

  Widget _pageBody(List<String> pieces, ReaderTheme theme) {
    if (pieces.isEmpty) {
      return Center(
          child: Text('本章内容为空', style: TextStyle(color: theme.sub, fontSize: 15)));
    }
    // NeverScrollable 容器：超出被裁剪，避免黄色溢出条纹
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in pieces)
            Text(t, style: _bodyStyle()),
        ],
      ),
    );
  }

  // ---------- 点击唤出工具栏（无蒙版：顶栏含状态栏背景从上滑下，底部菜单从下滑上）----------

  /// 顶栏：状态栏区域（theme.bg 实底）+ 返回键 + 章节标题
  Widget _overlayTopBar(ReaderTheme theme) {
    return Material(
      color: theme.bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 16, 6),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new, size: 20, color: theme.fg),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _chapterTitle ?? '第 ${_chapterIdx + 1} 章',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: theme.fg),
                ),
              ),
              IconButton(
                tooltip: '搜索章节',
                icon: Icon(Icons.search, size: 21, color: theme.fg),
                onPressed: _openChapterSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 章节搜索（搜章节名，在线书/本地书通用）----------

  void _openChapterSearch() {
    final cs = Theme.of(context).colorScheme;
    final ctl = TextEditingController();
    var query = '';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        return StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: h * 0.72,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: TextField(
                      controller: ctl,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: '搜索章节名',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        filled: true,
                        fillColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (v) {
                        query = v;
                        setSheet(() {});
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: FutureBuilder<List<ChapterMeta>>(
                      future: _ensureToc(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final q = query.trim().toLowerCase();
                        final list = q.isEmpty
                            ? snap.data!
                            : snap.data!
                                .where((c) => c.title.toLowerCase().contains(q))
                                .toList();
                        if (list.isEmpty) {
                          return Center(
                              child: Text('没有匹配的章节',
                                  style: TextStyle(
                                      fontSize: 13, color: cs.outline)));
                        }
                        return ListView.builder(
                          itemExtent: 48,
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final ch = list[i];
                            final cur = ch.idx == _chapterIdx;
                            return ListTile(
                              dense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              title: Text(
                                '${ch.idx + 1}. ${ch.title}',
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
                                _loadChapter(ch.idx);
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 底部菜单：目录 / 日间·夜晚切换 / 设置 三个按钮
  Widget _overlayBottomMenu(ReaderTheme theme) {
    Widget btn(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        onTap: () {
          setState(() => _menuVisible = false); // 操作后收起菜单
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: theme.fg.withValues(alpha: 0.9)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.fg.withValues(alpha: 0.75))),
            ],
          ),
        ),
      );
    }

    return Material(
      color: theme.bg,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              Expanded(
                  child: btn(Icons.menu_book_outlined, '目录', _openToc)),
              Expanded(
                  child: btn(
                _themeIdx == 5 ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                _themeIdx == 5 ? '日间' : '夜晚',
                () => _setTheme(_themeIdx == 5 ? 0 : 5),
              )),
              Expanded(
                  child: btn(Icons.settings_outlined, '设置', _openSettingsPanel)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 设置面板（底部上滑弹出）----------

  void _openSettingsPanel() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void rebuild(VoidCallback fn) {
            fn();
            setState(() {}); // 同步阅读器状态
          }

          final cs = Theme.of(ctx).colorScheme;
          final dark = cs.brightness == Brightness.dark;
          final sectionTitle = TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: cs.outline,
              letterSpacing: 0.5);

          Widget themeBlock() {
            // 昼夜分段 + 6 主题色块 3 列
            final isNight = _themeIdx == 5;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: MoStyle.inputFillOf(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Row(
                    children: [
                      _segBtn('白天', !isNight, () {
                        rebuild(() => _setTheme(0));
                        setSheet(() {});
                      }, cs),
                      _segBtn('夜间', isNight, () {
                        rebuild(() => _setTheme(5));
                        setSheet(() {});
                      }, cs),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                for (final row in [0, 1])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        for (var col = 0; col < 3; col++)
                          Expanded(
                            child: Center(
                              child: Builder(builder: (context) {
                                final i = row * 3 + col;
                                if (i >= kReaderThemes.length) return const SizedBox();
                                return _ThemeBlock(
                                  theme: kReaderThemes[i],
                                  selected: i == _themeIdx,
                                  onTap: () {
                                    rebuild(() => _setTheme(i));
                                    setSheet(() {});
                                  },
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          }

          return Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 拖拽条
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // ① 主题
                  Text('背景主题', style: sectionTitle),
                  const SizedBox(height: 10),
                  themeBlock(),
                  const SizedBox(height: 14),
                  // ② 字号
                  Text('字号', style: sectionTitle),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _squareBtn('A-', () {
                        rebuild(() => _setFont(_fontSize - 1));
                        setSheet(() {});
                      }, cs, small: true),
                      Expanded(
                        child: Slider(
                          value: _fontSize,
                          min: 13,
                          max: 24,
                          divisions: 11,
                          label: _fontSize.round().toString(),
                          activeColor: cs.primary,
                          onChanged: (v) {
                            rebuild(() => _setFont(v));
                            setSheet(() {});
                          },
                        ),
                      ),
                      _squareBtn('A+', () {
                        rebuild(() => _setFont(_fontSize + 1));
                        setSheet(() {});
                      }, cs, small: false),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('${_fontSize.round()}',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: dark ? MoStyle.darkPrimaryStrong : MoStyle.primaryStrong)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // ③ 行距
                  Text('行距', style: sectionTitle),
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      activeTrackColor: cs.primary,
                      inactiveTrackColor: cs.outlineVariant,
                      thumbColor: cs.primary,
                      overlayColor: cs.primary.withValues(alpha: 0.12),
                    ),
                    child: Slider(
                      value: _lineHeight,
                      min: 1.4,
                      max: 2.4,
                      divisions: 10,
                      label: _lineHeight.toStringAsFixed(1),
                      onChanged: (v) {
                        rebuild(() => _setLineHeight(v));
                        setSheet(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ④ 字体
                  Text('字体', style: sectionTitle),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < _fontFamilies.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _fontOption(
                            _fontFamilies[i],
                            _ffIdx == i,
                            () {
                              rebuild(() => _setFontFamily(i));
                              setSheet(() {});
                            },
                            cs,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),
                  // ⑤ 翻页方式
                  Text('翻页方式', style: sectionTitle),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: MoStyle.inputFillOf(context),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: Row(
                      children: [
                        _segBtn('左右翻页', !_scrollMode, () {
                          rebuild(() => _setScrollMode(false));
                          setSheet(() {});
                        }, cs),
                        _segBtn('上下滚动', _scrollMode, () {
                          rebuild(() => _setScrollMode(true));
                          setSheet(() {});
                        }, cs),
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

  Widget _segBtn(String label, bool selected, VoidCallback onTap, ColorScheme cs) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6)]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? cs.primary : cs.outline)),
        ),
      ),
    );
  }

  Widget _squareBtn(String label, VoidCallback onTap, ColorScheme cs, {required bool small}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant, width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: small ? 14 : 17,
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant)),
      ),
    );
  }

  Widget _fontOption(String label, bool selected, VoidCallback onTap, ColorScheme cs) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? (cs.brightness == Brightness.dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? cs.primary : cs.onSurfaceVariant)),
      ),
    );
  }

  @override
  void deactivate() {
    // 离开页面时保存阅读位置。
    // 必须在这里做：dispose 阶段子树先卸载，controller 已解绑读不到位置。
    super.deactivate();
    if (_scrollMode) {
      _persistScrollPos();
    } else if (_paged != null &&
        _pagedChapter == _chapterIdx &&
        _pageController.hasClients) {
      final idx =
          (_pageController.page?.round() ?? 0).clamp(0, _paged!.pages.length - 1);
      SharedPreferences.getInstance().then((p) {
        p.setInt('rd.ch.${_source.persistKey}', _chapterIdx);
        p.setInt('rd.pg.${_source.persistKey}', idx);
      });
    }
  }

  @override
  void dispose() {
    // 阅读器会全局改写状态栏样式（SystemChrome 是全局粘性的），
    // 退出时按 App 当前主题恢复，避免浅色模式下状态栏白字残留。
    final dark = _appBrightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    ));
    _scrollCtl.dispose();
    _pageController.dispose();
    super.dispose();
  }
}

/// 滚动模式扁平条目：章首标题（带章索引供量测/推进）或正文段落
class _ScrollItem {
  const _ScrollItem({
    required this.ch,
    required this.isTitle,
    required this.text,
    this.charStart,
  });

  final int ch;
  final bool isTitle;
  final String text;

  /// 段落首字符在章内容中的偏移（标题为 null），书内搜索定位用
  final int? charStart;
}

/// 设置面板：主题色块（选中主色描边 2.5 + 光环）
class _ThemeBlock extends StatelessWidget {
  const _ThemeBlock({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        padding: selected ? const EdgeInsets.all(3) : EdgeInsets.zero,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 2.5),
          boxShadow: selected
              ? [BoxShadow(color: cs.primary.withValues(alpha: 0.25), blurRadius: 12, spreadRadius: 2)]
              : null,
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.bg,
            border: Border.all(color: theme.sub.withValues(alpha: 0.4), width: 1),
          ),
          alignment: Alignment.center,
          child: selected
              ? Icon(Icons.check, size: 18, color: theme.fg)
              : Text(theme.name,
                  style: TextStyle(fontSize: 9, color: theme.sub, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
