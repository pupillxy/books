import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'drama_detail_page.dart';
import 'drama_history_page.dart';
import 'widgets.dart';

/// 短剧：红果短剧浏览（「墨笺」风：下划线分类 Tab + 竖版海报网格 + 搜索）
class DramaPage extends ConsumerStatefulWidget {
  const DramaPage({super.key});

  @override
  ConsumerState<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends ConsumerState<DramaPage> {
  List<DramaGenre>? _genres;
  String? _error;
  String _genreKey = '';
  String _genreName = '';

  // 二级筛选：_tag 格式 "dim|id"（与后端 select_items 维度对应），空 = 不限
  List<DramaFilterDim> _dims = const [];
  String _tag = '';

  final _items = <DramaItem>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _listError;

  // 搜索
  bool _searching = false;
  bool _searchLoading = false;
  String? _searchError;
  final _results = <DramaItem>[];
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _loadGenres();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadGenres() async {
    setState(() => _error = null);
    try {
      final genres = await _api.dramaGenres();
      if (!mounted) return;
      setState(() {
        _genres = genres;
        if (genres.isNotEmpty) {
          _genreKey = genres.first.key;
          _genreName = genres.first.name;
        }
      });
      if (_genreKey.isNotEmpty) _loadList();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadList() async {
    setState(() {
      _loading = true;
      _listError = null;
    });
    try {
      final page = await _api.dramaCatalog(_genreKey, offset: 0, tag: _tag);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _hasMore = page.hasMore;
        _loading = false;
        // 一级分类切换后维度组可能不同，整组替换；原选中项不在新面板则重置
        _dims = page.filters;
        if (_tag.isNotEmpty &&
            !_dims.any((d) => d.items.any((it) => '${d.key}|${it.id}' == _tag))) {
          _tag = '';
        }
      });
      _precacheCovers();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _listError = e.message;
      });
    }
  }

  // 首屏封面预解码：数据到位后后台逐张（间隔 60ms）预热图片缓存，
  // 用户开始滚动时直接命中缓存，消除"刚进页面掉帧、过一会正常"。
  void _precacheCovers() {
    if (!mounted) return;
    // 与 _DramaCard 的解码宽度保持一致（(屏宽-36-24)/3 × dpr），确保命中同一缓存键
    final w =
        ((MediaQuery.sizeOf(context).width - 18 * 2 - 12 * 2) / 3 * MediaQuery.devicePixelRatioOf(context))
            .round();
    final n = _items.length < 18 ? _items.length : 18;
    for (var i = 0; i < n; i++) {
      final url = _items[i].cover;
      if (url.isEmpty) continue;
      Future.delayed(Duration(milliseconds: 60 * i), () {
        if (!mounted) return;
        precacheImage(Image.network(url, cacheWidth: w).image, context);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _searching) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _api.dramaCatalog(_genreKey, offset: _items.length, tag: _tag);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _search(String kw) async {
    final query = kw.trim();
    if (query.isEmpty) return;
    _searchFocus.unfocus();
    setState(() {
      _searching = true;
      _searchLoading = true;
      _searchError = null;
      _results.clear();
    });
    try {
      final list = await _api.dramaSearch(query);
      if (!mounted) return;
      setState(() {
        _results.addAll(list);
        _searchLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _searchLoading = false;
        _searchError = e.message;
      });
    }
  }

  void _exitSearch() {
    _searchCtrl.clear();
    setState(() => _searching = false);
  }

  void _selectGenre(DramaGenre g) {
    if (g.key == _genreKey) return;
    setState(() {
      _genreKey = g.key;
      _genreName = g.name;
      _tag = ''; // 换分类后二级筛选项不同，重置为不限
    });
    _loadList();
  }

  // 二级筛选：同项再点取消；换项即刷新（书库页同款交互）
  void _selectFilter(DramaFilterDim dim, DramaFilterItem item) {
    final next = '${dim.key}|${item.id}';
    if (_tag == next) {
      setState(() => _tag = '');
    } else {
      setState(() => _tag = next);
    }
    _loadList();
  }

  // 二级筛选行：组名 + 「全部」+ 选项 chips（同书库页筛选行样式）
  Widget _filterRow(DramaFilterDim dim) {
    final activeKey = _tag.split('|').first;
    final dimActive = _tag.isNotEmpty && activeKey == dim.key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            const SizedBox(width: 18),
            SizedBox(
              width: 34,
              child: Text(dim.title,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _FilterChip(
                    label: '全部',
                    selected: !dimActive,
                    onTap: dimActive ? () => setState(() => _tag = '') : null,
                  ),
                  for (final item in dim.items)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _FilterChip(
                        label: item.name,
                        selected: _tag == '${dim.key}|${item.id}',
                        onTap: () => _selectFilter(dim, item),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(DramaItem d) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DramaDetailPage(sid: d.id, title: d.title),
    ));
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DramaHistoryPage()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final screenW = MediaQuery.of(context).size.width;
    final cellW = (screenW - 18 * 2 - 12 * 2) / 3;
    final extent = cellW / 0.72 + 44;

    final items = _searching ? _results : _items;
    final loading = _searching ? _searchLoading : _loading;
    final error = _searching ? _searchError : _listError;

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (!_searching && n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
          return false;
        },
        child: RefreshIndicator(
          color: cs.primary,
          onRefresh: () async {
            if (_searching) {
              final kw = _searchCtrl.text;
              if (kw.trim().isNotEmpty) await _search(kw);
            } else {
              await _loadList();
            }
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ---------- 页头：标题 + 搜索 + 历史 单行（固定常驻）----------
              MoPinnedHeader(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text('短剧',
                            style: TextStyle(
                                fontFamily: MoStyle.titleFont,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: cs.brightness == Brightness.dark
                                ? MoStyle.darkInputFill
                                : const Color(0xFFEEF2FB),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.search, size: 18, color: cs.outline),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _searchCtrl,
                                  focusNode: _searchFocus,
                                  style: TextStyle(fontSize: 13.5, color: cs.onSurface),
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: _search,
                                  decoration: InputDecoration(
                                    isCollapsed: true,
                                    border: InputBorder.none,
                                    hintText: '搜索短剧名称',
                                    hintStyle: TextStyle(fontSize: 13, color: cs.outline),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 搜索中显示"取消"，平时显示历史入口
                      if (_searching)
                        GestureDetector(
                          onTap: _exitSearch,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Text('取消',
                                style: TextStyle(
                                    fontSize: 13.5,
                                    color: cs.primary,
                                    fontWeight: FontWeight.w600)),
                          ),
                        )
                      else
                        IconButton(
                          onPressed: _openHistory,
                          tooltip: '观看历史',
                          icon: const Icon(Icons.history_rounded, size: 22),
                          color: cs.outline,
                        ),
                    ],
                  ),
                ),
              ),
              // ---------- 分类 Tab（搜索模式下隐藏） ----------
              if (!_searching && _genres != null && _genres!.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      children: [
                        for (final g in _genres!)
                          _UnderlineTab(
                            label: g.name,
                            selected: g.key == _genreKey,
                            onTap: () => _selectGenre(g),
                          ),
                      ],
                    ),
                  ),
                ),
              // ---------- 二级筛选（搜索模式下隐藏；无面板数据则整行不占位） ----------
              if (!_searching && _dims.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final dim in _dims)
                          _filterRow(dim),
                      ],
                    ),
                  ),
                ),
              // ---------- 内容 ----------
              if (_error != null && _genres == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetry(message: _error!, onRetry: _loadGenres),
                )
              else if (loading && items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (error != null && items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetry(
                      message: error, onRetry: _searching ? () => _search(_searchCtrl.text) : _loadList),
                )
              else if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyView(
                      title: _searching ? '没有找到相关短剧' : '暂无内容',
                      icon: _searching ? Icons.search_off : Icons.movie_creation_outlined),
                )
              else ...[
                if (!_searching)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(22, 14, 18, 2),
                      child: Row(
                        children: [
                          Text(_genreName,
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: MoStyle.inkOf(context))),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('为你精选',
                                style: TextStyle(fontSize: 11, color: cs.outline)),
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 14,
                      mainAxisExtent: extent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      childCount: items.length + (!_searching && _hasMore ? 1 : 0),
                      (context, i) {
                        if (i >= items.length) {
                          return const Center(
                              child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2)));
                        }
                        return _DramaCard(
                            drama: items[i], cellW: cellW, onTap: () => _openDetail(items[i]));
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖版海报卡：封面 + 集数角标 + 两行标题
class _DramaCard extends StatelessWidget {
  const _DramaCard({required this.drama, required this.cellW, required this.onTap});

  final DramaItem drama;
  final double cellW;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                BookCover(
                  url: drama.cover,
                  title: drama.title,
                  radius: 12,
                  // 按格子实际显示宽度 × 像素密度解码，避免大图全量解码拖慢滚动
                  cacheWidth: (cellW * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
                if (drama.remark.isNotEmpty)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        drama.remark,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 固定两行高度：标题不管占 1 行还是 2 行，封面高度都一致
          SizedBox(
            height: 33,
            child: Text(
              drama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: MoStyle.inkOf(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 筛选胶囊（同书库页 _Chip 风格）：30 高 + height:1 修正 CJK 文字偏上
class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? (cs.brightness == Brightness.dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft)
          : cs.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Text(
            label,
            // height:1 收紧行框，修正 CJK 字体 metrics 造成的文字偏上
            style: TextStyle(
              fontSize: 12,
              height: 1,
              color: selected ? MoStyle.strongOf(context) : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类 Chip：选中主色 + 底部短下划线（与书城一致）
class _UnderlineTab extends StatelessWidget {
  const _UnderlineTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(right: 22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? cs.primary : MoStyle.inkOf(context),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 18,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? cs.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
