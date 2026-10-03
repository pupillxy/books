import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoshuo_app/core/book_search.dart';

void main() {
  // 三章样例；切分偏移按「行首累计 +1 换行」手算（与 splitChapters 同坐标系）
  // 行起点：0 / 7 / 15 / 23 / 30 / 39 / 50 / 57，总长 67
  const text = '第一章 出山\n山下有座破庙。\n少年背剑而行。\n'
      '第二章 入城\n城门口人声鼎沸。\n他低声念着背剑二字。\n'
      '第三章 夜雨\n雨落背剑人的肩头。\n';

  final chapters = [
    {'idx': 0, 'title': '第一章 出山', 'start': 0, 'end': 23},
    {'idx': 1, 'title': '第二章 入城', 'start': 23, 'end': 50},
    {'idx': 2, 'title': '第三章 夜雨', 'start': 50, 'end': 67},
  ];

  group('runBookSearch', () {
    test('全部命中并归属正确章节，摘录含上下文', () {
      final r = runBookSearch(
          BookSearchArgs(text: text, chapters: chapters, query: '背剑'));
      // 第一章 1 处（17）、第二章 1 处（44）、第三章 1 处（59）
      expect(r.hits.length, 3);
      expect(r.truncated, false);
      expect(r.hits.map((h) => h.chapterIdx).toList(), [0, 1, 2]);
      expect(r.hits.map((h) => h.startInChapter).toList(), [17, 21, 9]);
      // 每条摘录都能按偏移切出关键词
      for (final h in r.hits) {
        expect(h.excerpt.contains('背剑'), true);
        expect(
            h.excerpt.substring(
                h.matchStartInExcerpt, h.matchStartInExcerpt + h.matchLength),
            '背剑');
      }
      // 章内偏移可在章文本中还原关键词
      final ch1 = text.substring(23, 50);
      const h1Start = 21;
      expect(ch1.substring(h1Start, h1Start + 2), '背剑');
    });

    test('上下文不跨章：窗口被章界截断时补 …', () {
      // 「城门」距章首 7 字 < 上下文 14 → 窗口顶到章首，无前省略号；
      // 窗口在章尾被截 → 有后省略号
      final r = runBookSearch(BookSearchArgs(
          text: text, chapters: chapters, query: '城门', context: 14));
      final h = r.hits.single;
      expect(h.chapterIdx, 1);
      expect(h.excerpt.startsWith('…'), false);
      expect(h.excerpt.endsWith('…'), true);
      expect(h.excerpt, startsWith('第二章 入城 城门口人声鼎沸。'));
      expect(h.excerpt.contains('少年'), false); // 上一章内容不进摘录

      // 「背剑」(44) 距章首 21 字 > 14 → 前文被截，有前省略号；顶到章尾无后省略号
      final r2 = runBookSearch(
          BookSearchArgs(text: text, chapters: chapters, query: '背剑', context: 14));
      final h2 = r2.hits[1];
      expect(h2.excerpt.startsWith('…'), true);
      expect(h2.excerpt.endsWith('…'), false);
    });

    test('跨行字面不误报（匹配基于原文，不折叠换行）', () {
      final r = runBookSearch(
          BookSearchArgs(text: text, chapters: chapters, query: '庙。少年'));
      expect(r.hits, isEmpty);
    });

    test('摘录里的换行折成空格，偏移不漂移', () {
      const t = '第一章\n甲乙\n丙丁戊'; // 乙 在 5，换行在 6
      final r = runBookSearch(BookSearchArgs(
        chapters: [
          {'idx': 0, 'title': '第一章', 'start': 0, 'end': t.length}
        ],
        text: t,
        query: '乙',
        context: 4,
      ));
      final h = r.hits.single;
      expect(h.excerpt, '…一章 甲乙 丙丁戊'); // \n 折成空格
      expect(h.matchStartInExcerpt, 5);
      expect(
          h.excerpt.substring(h.matchStartInExcerpt,
              h.matchStartInExcerpt + h.matchLength),
          '乙');
    });

    test('大小写不敏感（ASCII），空切分表 = 整本一章「正文」', () {
      const t = 'Chapter One\nHe said Hello World loudly';
      final r = runBookSearch(BookSearchArgs(
          chapters: const [], text: t, query: 'hello world', context: 8));
      expect(r.hits.length, 1);
      final h = r.hits.single;
      expect(h.chapterTitle, '正文');
      expect(h.excerpt, '…He said Hello World loudly');
      expect(
          h.excerpt.substring(
              h.matchStartInExcerpt, h.matchStartInExcerpt + h.matchLength),
          'Hello World');
    });

    test('空关键词 / 无命中', () {
      expect(
          runBookSearch(
                  BookSearchArgs(text: text, chapters: chapters, query: '  '))
              .hits,
          isEmpty);
      expect(
          runBookSearch(BookSearchArgs(
                  text: text, chapters: chapters, query: '不存在的词'))
              .hits,
          isEmpty);
    });

    test('maxHits 截断', () {
      const t = 'ab ab ab ab ab';
      final r = runBookSearch(
          BookSearchArgs(chapters: const [], text: t, query: 'ab', maxHits: 3));
      expect(r.hits.length, 3);
      expect(r.truncated, true);
    });

    test('乱序切分表也能正确归属（按 start 排序兜底）', () {
      final r = runBookSearch(BookSearchArgs(
          text: text,
          chapters: [
            {'idx': 1, 'title': '第二章 入城', 'start': 23, 'end': 50},
            {'idx': 0, 'title': '第一章 出山', 'start': 0, 'end': 23},
            {'idx': 2, 'title': '第三章 夜雨', 'start': 50, 'end': 67},
          ],
          query: '背剑'));
      expect(r.hits.map((h) => h.chapterIdx).toList(), [0, 1, 2]);
    });
  });
}
