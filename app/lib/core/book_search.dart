// 本机书正文搜索：整本文本一次扫描，命中处带前后上下文摘录。
// 纯函数、无 UI 依赖，供搜索页在 isolate 里跑（compute），也方便单测。

/// 一处命中：关键词落在哪一章、章内偏移多少、摘录长什么样
class BookSearchHit {
  BookSearchHit({
    required this.chapterIdx,
    required this.chapterTitle,
    required this.startInChapter,
    required this.excerpt,
    required this.matchStartInExcerpt,
    required this.matchLength,
  });

  final int chapterIdx;
  final String chapterTitle;

  /// 关键词起点在整章文本（章内容，含章首标题行）中的偏移，阅读器定位用
  final int startInChapter;

  /// 摘录文本（前后各 context 字，换行/制表已折成空格），被章界截断处带 …
  final String excerpt;
  final int matchStartInExcerpt;
  final int matchLength;

  Map<String, dynamic> toDebugMap() => {
        'ch': chapterIdx,
        'off': startInChapter,
        'mStart': matchStartInExcerpt,
        'mLen': matchLength,
        'excerpt': excerpt,
      };
}

class BookSearchResult {
  const BookSearchResult({required this.hits, required this.truncated});

  final List<BookSearchHit> hits;

  /// 命中数超过上限被截断（此时 hits.length == maxHits）
  final bool truncated;
}

/// 搜索参数（compute 跨 isolate 传参用，字段全部可发送）
class BookSearchArgs {
  const BookSearchArgs({
    required this.text,
    required this.chapters,
    required this.query,
    this.context = 14,
    this.maxHits = 300,
  });

  final String text;

  /// 章节切分表（LocalBookMeta.chapters 的原始形状）
  /// 空表 = 整本作为一章「正文」处理
  final List<Map<String, dynamic>> chapters;
  final String query;
  final int context;
  final int maxHits;
}

/// isolate 入口（顶层函数，compute 可调用）
BookSearchResult runBookSearch(BookSearchArgs args) {
  final query = args.query.trim();
  if (query.isEmpty) return const BookSearchResult(hits: [], truncated: false);

  final text = args.text;

  // 大小写不敏感（对 ASCII）；toLowerCase 改变长度的极端字符直接退回原文精确匹配
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final bool ci =
      lowerText.length == text.length && lowerQuery.length == query.length;
  final String hay = ci ? lowerText : text;
  final String needle = ci ? lowerQuery : query;

  // 章节边界：切分表为空时整本视为一章「正文」
  final bounds = <({int idx, int start, int end, String title})>[];
  if (args.chapters.isEmpty) {
    bounds.add((idx: 0, start: 0, end: text.length, title: '正文'));
  } else {
    for (final c in args.chapters) {
      final start = (c['start'] as num?)?.toInt() ?? 0;
      var end = (c['end'] as num?)?.toInt() ?? text.length;
      if (end < start) end = start;
      bounds.add((
        idx: (c['idx'] as num?)?.toInt() ?? bounds.length,
        start: start.clamp(0, text.length),
        end: end.clamp(0, text.length),
        title: (c['title'] ?? '') as String,
      ));
    }
    // 排除异常（start 乱序）对归属判断的干扰：按 start 排序
    bounds.sort((a, b) => a.start.compareTo(b.start));
  }

  final hits = <BookSearchHit>[];
  var truncated = false;
  var chapterPos = 0; // 命中按文本顺序出现，章节指针只前进
  var from = hay.indexOf(needle);
  while (from >= 0) {
    if (hits.length >= args.maxHits) {
      truncated = true;
      break;
    }
    // 定位命中所属章：起点 <= 命中位置的最后一章
    while (chapterPos + 1 < bounds.length &&
        bounds[chapterPos + 1].start <= from) {
      chapterPos++;
    }
    final cb = bounds[chapterPos];

    final to = from + needle.length;
    hits.add(_buildHit(
      chapterIdx: cb.idx,
      chapterTitle: cb.title,
      chapterStart: cb.start,
      chapterEnd: cb.end,
      text: text,
      matchStart: from,
      matchEnd: to,
      context: args.context,
    ));

    from = hay.indexOf(needle, to); // needle 非空，to > from，不会死循环
  }
  return BookSearchResult(hits: hits, truncated: truncated);
}

/// 组装单条摘录：窗口取自所属章内（不跨章），换行/制表等长折成空格
/// （偏移不漂移），再按首尾空白裁剪并修正偏移
BookSearchHit _buildHit({
  required int chapterIdx,
  required String chapterTitle,
  required int chapterStart,
  required int chapterEnd,
  required String text,
  required int matchStart,
  required int matchEnd,
  required int context,
}) {
  final winA = chapterStart >= matchStart - context
      ? chapterStart
      : matchStart - context;
  final winB = chapterEnd <= matchEnd + context ? chapterEnd : matchEnd + context;

  final sb = StringBuffer();
  for (var i = winA; i < winB; i++) {
    final ch = text[i];
    sb.write(ch == '\n' || ch == '\r' || ch == '\t' ? ' ' : ch);
  }
  final raw = sb.toString();
  var lead = 0;
  while (lead < raw.length && raw[lead] == ' ') {
    lead++;
  }
  var trail = raw.length;
  while (trail > lead && raw[trail - 1] == ' ') {
    trail--;
  }
  final body = raw.substring(lead, trail);
  // 窗口在章内被截断 → 补省略号（窗口顶到章界则说明本来就是章首/章尾）
  final prefix = winA > chapterStart ? '…' : '';
  final suffix = winB < chapterEnd ? '…' : '';

  return BookSearchHit(
    chapterIdx: chapterIdx,
    chapterTitle: chapterTitle.isEmpty ? '第 ${chapterIdx + 1} 章' : chapterTitle,
    startInChapter: matchStart - chapterStart,
    matchStartInExcerpt: prefix.length + (matchStart - winA - lead),
    matchLength: matchEnd - matchStart,
    excerpt: '$prefix$body$suffix',
  );
}
