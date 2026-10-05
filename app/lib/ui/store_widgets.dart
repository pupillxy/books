import 'package:flutter/material.dart';

import '../core/mo_theme.dart';
import '../models.dart';
import 'widgets.dart';

/// 书城系页面共享组件（首页 StorePage / 书城 Tab FanqiePage 共用）。
/// 从 store_page.dart 提取（10/06），样式以 StorePage 设计为准。

/// 区块头：14.5/700 标题 + 右侧「更多 ›」11 muted
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 14.5, fontWeight: FontWeight.w700, color: MoStyle.inkOf(context))),
        const Spacer(),
        if (actionLabel != null)
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text(actionLabel!, style: TextStyle(fontSize: 11, color: cs.outline)),
            ),
          ),
      ],
    );
  }
}

/// 男/女频道胶囊切换（影响书城全部区块）
class GenderToggle extends StatelessWidget {
  const GenderToggle({super.key, required this.value, required this.onChanged});

  final String value; // '1' 男生 '0' 女生
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(context, '男生', '1'),
          _seg(context, '女生', '0'),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, String label, String v) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final sel = value == v;
    return InkWell(
      onTap: () => onChanged(v),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? (dark ? MoStyle.darkPrimarySoft : MoStyle.primarySoft) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          // height:1 收紧行框，修正 CJK 字体 metrics 造成的文字偏上
          style: TextStyle(
            fontSize: 11.5,
            height: 1,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? (dark ? MoStyle.darkPrimaryStrong : MoStyle.primaryStrong) : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 分类直达胶囊
class CatPill extends StatelessWidget {
  const CatPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 焦点轮播卡：朱砂三段渐变 + 右上装饰圆 + 金牌封面（No.1）
class HeroCard extends StatelessWidget {
  const HeroCard({
    super.key,
    required this.book,
    required this.boardName,
    required this.rank,
    required this.onTap,
  });

  final LibraryBook book;
  final String boardName;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 156,
        padding: const EdgeInsets.fromLTRB(18, 0, 14, 0),
        decoration: BoxDecoration(
          gradient: MoStyle.brandGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(color: Color(0x4DC2522C), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned(
                top: -50,
                right: -24,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.13),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('$boardName · No.$rank',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                        const SizedBox(height: 10),
                        Text(book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: MoStyle.titleFont,
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.3)),
                        const SizedBox(height: 8),
                        Text(
                            [
                              book.author.isEmpty ? '佚名' : book.author,
                              if (book.readCount.isNotEmpty) book.readCount,
                            ].join(' · '),
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.white.withValues(alpha: 0.85))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 80,
                    height: 108,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: BookCover(url: book.coverUrl, title: book.title, radius: 10),
                        ),
                        if (rank == 1)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.only(
                                  topRight: Radius.circular(10),
                                  bottomLeft: Radius.circular(10),
                                ),
                              ),
                              child: const Text('金牌',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: MoStyle.primaryStrong)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 横向书架卡：封面 96×128 + 完结/在库角标 + 书名 + 作者 · 字数
class ShelfCard extends StatelessWidget {
  const ShelfCard({
    super.key,
    required this.book,
    required this.coverW,
    required this.onTap,
  });

  final LibraryBook book;
  final int coverW; // 封面解码宽（像素）
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = book.wordCount.isNotEmpty ? book.wordCount : book.readCount;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 96,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 128,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: BookCover(
                      url: book.coverUrl,
                      title: book.title,
                      radius: 10,
                      cacheWidth: coverW,
                    ),
                  ),
                  if (book.finished)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: const BoxDecoration(
                          color: Color(0xCC1F9D6D),
                          borderRadius: BorderRadius.only(topRight: Radius.circular(10)),
                        ),
                        child: const Text('完结',
                            style: TextStyle(
                                fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  if (book.inLibrary)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.only(
                              topRight: Radius.circular(10), bottomLeft: Radius.circular(10)),
                        ),
                        child: Text(book.localStatus == 'ready' ? '全文' : '在库',
                            style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: MoStyle.primaryStrong)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 30,
              child: Text(book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color: MoStyle.inkOf(context))),
            ),
            const SizedBox(height: 3),
            Text(
              '${book.author.isEmpty ? "佚名" : book.author}${meta.isEmpty ? "" : " · $meta"}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 焦点轮播占位
class HeroSkeleton extends StatelessWidget {
  const HeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.brightness == Brightness.dark ? MoStyle.darkRule : MoStyle.rule;
    return Container(
      decoration: BoxDecoration(
        color: block.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
    );
  }
}

/// 横向书架占位：4 个灰封面
class ShelfSkeleton extends StatelessWidget {
  const ShelfSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.brightness == Brightness.dark ? MoStyle.darkRule : MoStyle.rule;
    return Row(
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            width: 96,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: block.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
      ],
    );
  }
}
