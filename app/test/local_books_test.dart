import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoshuo_app/core/local_books.dart';

void main() {
  group('decodeTxt', () {
    test('UTF-8 中文', () {
      final bytes = Uint8List.fromList(utf8.encode('第一章 试炼\n正文内容'));
      expect(decodeTxt(bytes), '第一章 试炼\n正文内容');
    });

    test('GBK 中文（国内常见编码）', () {
      // “第一章” 的 GBK 字节
      final gbkBytes = gbk.encode('第一章 起点');
      expect(decodeTxt(Uint8List.fromList(gbkBytes)), '第一章 起点');
    });

    test('带 BOM 的 UTF-8', () {
      final body = utf8.encode('第一章 起点');
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]);
      expect(decodeTxt(bytes), '第一章 起点');
    });
  });

  group('splitChapters', () {
    test('按「第X章」切分，偏移可还原正文', () {
      const text = '序章内容\n第一章 起点\n张三上山。\n第二章 遇敌\n李四出手。';
      final chapters = splitChapters(text);
      expect(chapters.length, 2);
      expect(chapters[0]['title'], '第一章 起点');
      expect(chapters[1]['title'], '第二章 遇敌');
      final c0 = text.substring(chapters[0]['start'] as int, chapters[0]['end'] as int);
      expect(c0, contains('张三上山'));
      expect(c0, isNot(contains('李四出手')));
    });

    test('切不出章节时整本归为「正文」', () {
      const text = '没有章节标题的一本书。\n第二行正文。';
      final chapters = splitChapters(text);
      expect(chapters.length, 1);
      expect(chapters[0]['title'], '正文');
      expect(chapters[0]['end'], text.length);
    });
  });

  group('LocalBookMeta', () {
    // 回归：fromJson 曾漏读 chapters，导致打开本机书时 clamp(0,-1) 抛
    // "Invalid argument(s): 0" 红屏。
    test('toJson → fromJson 保留章节切分表', () {
      final meta = LocalBookMeta(
        id: 't1',
        title: '书名',
        author: '',
        fileName: '书名.txt',
        fileSize: 123,
        chapterCount: 2,
        importedAt: '2026-09-30T10:00:00.000',
        chapters: [
          {'idx': 0, 'title': '第一章', 'start': 0, 'end': 10},
          {'idx': 1, 'title': '第二章', 'start': 10, 'end': 20},
        ],
      );
      final back = LocalBookMeta.fromJson(
          jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>);
      expect(back.chapters.length, 2);
      expect(back.chapters[1]['title'], '第二章');
      expect(back.chapterCount, 2);
    });
  });
}
