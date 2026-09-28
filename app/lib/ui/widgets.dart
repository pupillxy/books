import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/mo_theme.dart';

/// 通用小部件

/// 固定在顶部的 Sliver 页头：状态栏 + 标题常驻，内容滚动时不会被顶走。
/// child 通常传 PageHeader；背景取 scaffoldBackgroundColor，滚动内容从下方穿过不透出。
/// 仅限 CustomScrollView 的 slivers 中使用（内部复用框架 PinnedHeaderSliver）。
class MoPinnedHeader extends StatelessWidget {
  const MoPinnedHeader({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PinnedHeaderSliver(
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
    );
  }
}

/// 统一页头：衬线大标题 + 右侧 actions。
/// 返回键自动显示：Navigator 可 pop（即子页面）时出现；Tab 页（IndexedStack 内）无返回键。
/// 自动让开系统状态栏：Tab 页在 SafeArea 内 padding.top 已为 0，不会重复让位。
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions, this.horizontal = 16});

  final String title;
  final List<Widget>? actions;

  /// 无返回键时的左缘边距；外层滚动容器已带横向 padding 时可调小避免叠加
  final double horizontal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canBack = Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          canBack ? 4 : horizontal, MediaQuery.of(context).padding.top + 6, canBack ? 6 : horizontal, 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            if (canBack)
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: cs.onSurface,
              ),
            SizedBox(width: canBack ? 4 : 0),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: MoStyle.titleFont,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
            ),
            ...?actions,
          ],
        ),
      ),
    );
  }
}

/// 下划线选中 Tab：选中主色加粗 + 底部 2.5px 短下划线（书城/榜单页通用）
class MoUnderlineTab extends StatelessWidget {
  const MoUnderlineTab({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? MoStyle.primaryStrong : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            // 2.5px 短下划线（选中时显示，宽约字宽 40%）
            Container(
              width: 20,
              height: 2.5,
              decoration: BoxDecoration(
                color: selected ? MoStyle.primaryStrong : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书籍封面：有图显示图片，无图/加载失败显示渐变占位 + 衬线书名
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.url,
    required this.title,
    this.radius = 10,
    this.cacheWidth = 600,
  });

  final String? url;
  final String title;
  final double radius;

  /// 解码宽度上限（像素）：封面实际显示都很小，限制解码分辨率可大幅
  /// 降低滚动时的位图解码开销，避免列表掉帧。高度按原图比例自动缩放。
  final int cacheWidth;

  Widget _placeholder(BuildContext context) {
    final g = MoStyle
        .coverGradients[title.isEmpty ? 0 : title.hashCode.abs() % MoStyle.coverGradients.length];
    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: g)),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      child: Text(
        title.isEmpty ? '书' : title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: MoStyle.titleFont,
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          height: 1.35,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ph = _placeholder(context);
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: u == null || u.isEmpty
          ? ph
          : Image.network(
              u,
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
              filterQuality: FilterQuality.low, // 显示尺寸≈解码尺寸，双线性足够且栅格开销最低
              errorBuilder: (_, __, ___) => ph,
              // 不做淡入动画：滚动时多张图同时半透明会连续 saveLayer 掉帧。
              // 传输中显示渐变占位，解码完成后直接显示（无任何额外合成开销）。
              frameBuilder: (context, child, frame, wasSync) {
                if (wasSync || frame != null) return child;
                return ph;
              },
            ),
    );
  }
}

/// 加载失败重试页
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 44, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

/// 空数据提示
class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: color),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(color: color, fontSize: 15)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 12),
                textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

String formatChapterPosition(int idx, int total) {
  if (total <= 0) return '暂无章节';
  final p = idx <= 0 ? 0 : (idx / total * 100).clamp(0, 100);
  return '第 ${math.min(idx + 1, total)} / $total 章 · $p%';
}

/// 详情页渐变封面区：暖沙渐变 + 大封面 + 书名/作者
class DetailCoverHeader extends StatelessWidget {
  const DetailCoverHeader({
    super.key,
    required this.coverUrl,
    required this.title,
    required this.author,
    required this.meta,
    this.badge,
  });

  final String? coverUrl;
  final String title;
  final String author;
  final String meta;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: dark ? null : MoStyle.detailHeaderGradient,
        color: dark ? MoStyle.darkPanel : null,
      ),
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 封面 106×142 圆角 12 + 右上主色角标
          SizedBox(
            width: 106,
            height: 142,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      boxShadow: [
                        BoxShadow(color: Color(0x33A13F1E), blurRadius: 18, offset: Offset(0, 8)),
                      ],
                    ),
                    child: BookCover(url: coverUrl, title: title, radius: 12),
                  ),
                ),
                if (badge != null)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                      decoration: const BoxDecoration(
                        color: MoStyle.primary,
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(12),
                          bottomLeft: Radius.circular(10),
                        ),
                      ),
                      child: Text(badge!,
                          style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              height: 1.3)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: MoStyle.titleFont,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                        height: 1.4)),
                const SizedBox(height: 8),
                Text('作者：${author.isEmpty ? '佚名' : author}',
                    style: TextStyle(fontSize: 12, color: cs.outline)),
                const SizedBox(height: 5),
                Text(meta, style: TextStyle(fontSize: 12, color: cs.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 主按钮：朱砂渐变 h48（有可点击感：渐变+阴影）
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          gradient: MoStyle.btnGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: enabled ? MoStyle.shadowBtn() : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 19, color: Colors.white),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 次按钮：ghost（主色淡底 + 主色深文字）
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final bg = dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft;
    final fg = dark ? MoStyle.darkPrimaryStrong : MoStyle.primaryStrong;
    return SizedBox(
      height: 48,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 19, color: fg),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页 Tab 行：13/700 选中主色 + 2.5px 下划线
class MoTabBar extends StatelessWidget {
  const MoTabBar({super.key, required this.labels, this.controller});

  final List<String> labels;
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.8)),
      ),
      child: TabBar(
        controller: controller,
        tabs: [for (final l in labels) Tab(text: l)],
        indicatorColor: cs.primary,
        indicatorWeight: 2.5,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: cs.primary,
        unselectedLabelColor: cs.outline,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
