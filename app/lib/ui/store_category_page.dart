import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'store_category_result_page.dart';
import 'widgets.dart';

/// 书城分类页（复刻番茄官方「分类」）：
/// 顶部男生/女生频道 + 左侧栏分组（热门标签/主题/角色/情节）+ 右侧标签墙。
/// 数据走官方 new_category/front 协议（10/05 定案），点标签进分类书单页。
class StoreCategoryPage extends ConsumerStatefulWidget {
  const StoreCategoryPage({super.key, this.initialGender = 1});

  final int initialGender; // 1=男生 0=女生

  @override
  ConsumerState<StoreCategoryPage> createState() => _StoreCategoryPageState();
}

class _StoreCategoryPageState extends ConsumerState<StoreCategoryPage> {
  final Map<int, StoreCategoriesData> _cache = {}; // gender → 标签树
  final Map<int, String?> _errors = {};
  final Set<int> _loading = {};

  late int _gender;
  int _activeGroup = 0;
  final ScrollController _wallCtrl = ScrollController();
  final List<GlobalKey> _groupKeys = [];

  ApiClient get _api => ref.read(sessionProvider).api!;

  StoreCategoriesData? get _data => _cache[_gender];

  @override
  void initState() {
    super.initState();
    _gender = widget.initialGender;
    _ensureData();
  }

  @override
  void dispose() {
    _wallCtrl.dispose();
    super.dispose();
  }

  void _ensureData() {
    if (_cache.containsKey(_gender) || _loading.contains(_gender)) return;
    _loading.add(_gender);
    _api.storeCategories(gender: _gender).then((d) {
      if (!mounted) return;
      setState(() {
        _cache[_gender] = d;
        _loading.remove(_gender);
        _activeGroup = 0;
        _groupKeys.clear();
        for (final _ in d.groups) {
          _groupKeys.add(GlobalKey());
        }
      });
    }).catchError((e) {
      if (!mounted) return;
      setState(() {
        _errors[_gender] = e is ApiException ? e.message : '$e';
        _loading.remove(_gender);
      });
    });
  }

  void _switchGender(int g) {
    if (g == _gender) return;
    setState(() {
      _gender = g;
      _activeGroup = 0;
    });
    _ensureData();
  }

  void _scrollToGroup(int i) {
    setState(() => _activeGroup = i);
    final ctx = i < _groupKeys.length ? _groupKeys[i].currentContext : null;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 240), alignment: 0.02);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(child: _buildBody(context, data)),
          ],
        ),
      ),
    );
  }

  // ── 顶栏：返回 + 男生/女生频道 ─────────────────────────────────────
  Widget _buildTopBar(BuildContext context) {
    final tabs = <StoreCategoryTab>[
      const StoreCategoryTab(id: 1, name: '男生'),
      const StoreCategoryTab(id: 0, name: '女生'),
    ];
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          BackButton(onPressed: () => Navigator.of(context).pop()),
          Expanded(
            child: Row(
              children: [
                for (final t in tabs)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _switchGender(t.id),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 22),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(t.name,
                              style: TextStyle(
                                fontSize: _gender == t.id ? 19 : 16,
                                height: 1.1,
                                fontWeight: _gender == t.id
                                    ? FontWeight.w900
                                    : FontWeight.w500,
                                color: _gender == t.id
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context)
                                        .colorScheme
                                        .outline
                                        .withValues(alpha: .8),
                              )),
                          const SizedBox(height: 3),
                          Container(
                            height: 3,
                            width: 18,
                            decoration: BoxDecoration(
                              color: _gender == t.id
                                  ? MoStyle.strongOf(context)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, StoreCategoriesData? data) {
    if (data != null) return _buildWall(context, data);
    if (_loading.contains(_gender)) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final err = _errors[_gender];
    if (err != null) {
      return ErrorRetry(message: err, onRetry: () {
        setState(() => _errors[_gender] = null);
        _ensureData();
      });
    }
    return const SizedBox.shrink();
  }

  // ── 标签墙：左侧栏分组 + 右侧标签墙 ────────────────────────────────
  Widget _buildWall(BuildContext context, StoreCategoriesData data) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧栏
        SizedBox(
          width: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < data.groups.length; i++)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _scrollToGroup(i),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 16),
                    color: _activeGroup == i
                        ? cs.onSurface.withValues(alpha: .035)
                        : Colors.transparent,
                    child: Text(data.groups[i].name,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.0,
                          fontWeight:
                              _activeGroup == i ? FontWeight.w800 : FontWeight.w500,
                          color: _activeGroup == i
                              ? MoStyle.strongOf(context)
                              : cs.onSurfaceVariant,
                        )),
                  ),
                ),
            ],
          ),
        ),
        // 右侧标签墙
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollUpdateNotification) {
                // 按各组纵向位置反推当前分组（左侧栏高亮跟随滚动）
                var active = 0;
                for (var i = 0; i < _groupKeys.length; i++) {
                  final ctx = _groupKeys[i].currentContext;
                  if (ctx == null) continue;
                  final box = ctx.findRenderObject()! as RenderBox;
                  final y = box.localToGlobal(Offset.zero).dy;
                  if (y <= 160) active = i;
                }
                if (active != _activeGroup) setState(() => _activeGroup = active);
              }
              return false;
            },
            child: ListView(
              controller: _wallCtrl,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 32),
              children: [
                for (var i = 0; i < data.groups.length; i++)
                  _buildGroup(context, data.groups[i], _groupKeys[i]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGroup(BuildContext context, StoreCategoryGroup group, GlobalKey key) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: key,
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Text(group.name,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.0,
                    color: cs.outline.withValues(alpha: .9))),
          ),
          // 官方同构：标签墙三列等宽（Wrap 会把带 alignment 的子项撑满整行，
          // 这里用 LayoutBuilder 算列宽，SizedBox 定宽）
          LayoutBuilder(builder: (context, cons) {
            const spacing = 9.0;
            final chipW = (cons.maxWidth - spacing * 2) / 3;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final t in group.tags)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openTag(t),
                    child: Container(
                      width: chipW,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: .05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13.5,
                              height: 1.0,
                              color: MoStyle.inkOf(context))),
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }

  void _openTag(StoreCategoryTag tag) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoreCategoryResultPage(
            categoryId: tag.id, title: tag.name, gender: _gender)));
  }
}
