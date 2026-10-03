// 本机书籍：从手机导入 TXT，仅存本机（应用私有目录），不与服务器同步。
//
// 存储：<AppDoc>/local_books/<id>/ 下两个文件
//   book.txt   —— 原始文本（导入时复制）
//   meta.json  —— 书名/作者/章节切分表（字符偏移，不解码正文即可列目录）
//
// 阅读进度沿用阅读器的 SharedPreferences key（`rd.ch.local_<id>` 等），
// 同样只存本机，换设备不迁移。

import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

class LocalBookMeta {
  final String id;
  final String title;
  final String author;
  final String fileName;
  final int fileSize; // 字节
  final int chapterCount;
  final String importedAt; // ISO8601 本机时间

  // 章节切分表：[{idx,title,start,end}]，start/end 为 book.txt 解码后文本的字符偏移
  List<Map<String, dynamic>> chapters;

  LocalBookMeta({
    required this.id,
    required this.title,
    required this.author,
    required this.fileName,
    required this.fileSize,
    required this.chapterCount,
    required this.importedAt,
    this.chapters = const [],
  });

  factory LocalBookMeta.fromJson(Map<String, dynamic> j) => LocalBookMeta(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        fileName: (j['file_name'] ?? '') as String,
        fileSize: (j['file_size'] as num?)?.toInt() ?? 0,
        chapterCount: (j['chapter_count'] as num?)?.toInt() ?? 0,
        importedAt: (j['imported_at'] ?? '') as String,
        chapters: ((j['chapters'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'file_name': fileName,
        'file_size': fileSize,
        'chapter_count': chapterCount,
        'imported_at': importedAt,
        'chapters': chapters,
      };
}

/// 打开后的本机书：整本文本已解码在内存，按切分表切片取章
class LocalBookContent {
  final LocalBookMeta meta;
  final String _text;
  LocalBookContent(this.meta, this._text);

  /// 整本解码后文本（书内搜索用；与 meta.chapters 的字符偏移同一坐标系）
  String get fullText => _text;

  int get chapterCount => meta.chapters.length;

  Chapter chapterAt(int idx) {
    if (meta.chapters.isEmpty) {
      return Chapter(idx: 0, title: '正文', content: _text);
    }
    final c = meta.chapters[idx.clamp(0, meta.chapters.length - 1)];
    final start = (c['start'] as num).toInt();
    final end = (c['end'] as num).toInt();
    return Chapter(
      idx: (c['idx'] as num).toInt(),
      title: (c['title'] ?? '') as String,
      content: _text.substring(start.clamp(0, _text.length), end.clamp(0, _text.length)),
    );
  }
}

class LocalBookService {
  LocalBookService._();
  static final instance = LocalBookService._();

  static const _progressPrefix = 'local_'; // 阅读器持久化 key 前缀

  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}${Platform.pathSeparator}local_books');
  }

  Future<String> _bookDir(String id) async =>
      '${(await _root()).path}${Platform.pathSeparator}$id';

  /// 全部本机书，按导入时间倒序
  Future<List<LocalBookMeta>> list() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final metas = <LocalBookMeta>[];
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      final f = File('${dir.path}${Platform.pathSeparator}meta.json');
      try {
        metas.add(LocalBookMeta.fromJson(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // 残缺目录直接跳过
      }
    }
    metas.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return metas;
  }

  Future<LocalBookContent> open(String id) async {
    final dir = await _bookDir(id);
    final meta = LocalBookMeta.fromJson(jsonDecode(
            await File('$dir${Platform.pathSeparator}meta.json').readAsString())
        as Map<String, dynamic>);
    final text = await compute(_readDecoded, '$dir${Platform.pathSeparator}book.txt');
    if (meta.chapters.isEmpty) {
      // 切分表缺失/损坏 → 从正文重新切分并回写，避免打开即崩
      meta.chapters = splitChapters(text);
      try {
        await File('$dir${Platform.pathSeparator}meta.json')
            .writeAsString(jsonEncode(meta.toJson()));
      } catch (_) {}
    }
    return LocalBookContent(meta, text);
  }

  Future<void> delete(String id) async {
    final dir = Directory(await _bookDir(id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 导入：系统文件选择器选 TXT → 复制进私有目录 → 解码 → 切章 → 写 meta。
  /// 返回 null 表示用户取消。
  Future<LocalBookMeta?> importTxt() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      withData: false,
    );
    final path = picked?.files.single.path;
    if (path == null) return null;
    return importFromPath(path);
  }

  Future<LocalBookMeta> importFromPath(String path) async {
    final src = File(path);
    final bytes = await src.readAsBytes();
    if (bytes.isEmpty) throw Exception('文件是空的');
    final text = await compute(decodeTxt, bytes);
    if (text.trim().isEmpty) throw Exception('没有解析到文字内容');

    final chapters = splitChapters(text);
    final id = 't${DateTime.now().millisecondsSinceEpoch}';
    final dir = Directory(await _bookDir(id));
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}book.txt').writeAsString(text);

    final name = pickedName(path);
    final dot = name.lastIndexOf('.');
    final meta = LocalBookMeta(
      id: id,
      title: (dot > 0 ? name.substring(0, dot) : name).trim(),
      author: '',
      fileName: name,
      fileSize: bytes.length,
      chapterCount: chapters.length,
      importedAt: DateTime.now().toIso8601String(),
      chapters: chapters,
    );
    await File('${dir.path}${Platform.pathSeparator}meta.json')
        .writeAsString(jsonEncode(meta.toJson()));
    return meta;
  }

  static String pickedName(String path) {
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf('\\');
    final k = i > j ? i : j;
    return k < 0 ? path : path.substring(k + 1);
  }

  /// 阅读器进度 key（SharedPreferences）：`local_<id>`
  static String progressKey(String id) => '$_progressPrefix$id';

  /// 本机阅读进度（章下标，0 = 未开始）：读阅读器写入的 `rd.ch.local_<id>`
  Future<int> progressOf(String id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('rd.ch.${progressKey(id)}') ?? 0;
  }
}

// ---------- 解码 ----------

/// TXT 解码：BOM 识别 → 严格 UTF-8 → 兜底 GBK（国内 TXT 常见编码）
String decodeTxt(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16le(bytes.sublist(2));
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16be(bytes.sublist(2));
    }
  }
  var body = bytes;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    body = bytes.sublist(3);
  }
  try {
    return utf8.decode(body); // 严格模式，GBK 会因非法字节抛错
  } catch (_) {
    return gbk.decode(body);
  }
}

String _utf16le(Uint8List b) {
  final sb = StringBuffer();
  for (var i = 0; i + 1 < b.length; i += 2) {
    sb.writeCharCode(b[i] | (b[i + 1] << 8));
  }
  return sb.toString();
}

String _utf16be(Uint8List b) {
  final sb = StringBuffer();
  for (var i = 0; i + 1 < b.length; i += 2) {
    sb.writeCharCode((b[i] << 8) | b[i + 1]);
  }
  return sb.toString();
}

String _readDecoded(String path) => decodeTxt(File(path).readAsBytesSync());

// ---------- 章节切分 ----------

final _chapterTitleRe = RegExp(
  r'^\s*'
  r'(?:'
  r'第\s*[0-9０-９零一二三四五六七八九十百千万两〇]+\s*[章节卷回部集][^\n]{0,24}'
  r'|Chapter\s+\d+[^\n]{0,24}'
  r'|\d{1,4}[、.．:：]\s*\S[^\n]{0,22}'
  r')'
  r'\s*$',
  caseSensitive: false,
);

/// 按常见章节标题行切分；切不出多章时整本作为一章「正文」。
/// 返回 [{idx,title,start,end}]，end 为下一章起点（章含标题行，阅读器标题单独显示无妨）。
List<Map<String, dynamic>> splitChapters(String text) {
  final marks = <int>[]; // 每个标题行的行首偏移
  final titles = <String>[];
  var offset = 0;
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.length <= 30 && _chapterTitleRe.hasMatch(line)) {
      marks.add(offset);
      titles.add(t);
    }
    offset += line.length + 1; // +1 为被 split 吃掉的换行
  }
  if (marks.length < 2) {
    return [
      {'idx': 0, 'title': '正文', 'start': 0, 'end': text.length}
    ];
  }
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < marks.length; i++) {
    out.add({
      'idx': i,
      'title': titles[i],
      'start': marks[i],
      'end': i + 1 < marks.length ? marks[i + 1] : text.length,
    });
  }
  return out;
}

/// 本机书在书架等处展示用的占位 Book（不访问服务端）
Book localBookAsBook(LocalBookMeta m) => Book(
      id: -1,
      title: m.title,
      author: m.author,
      intro: '本机书籍 · ${m.fileName}',
      cover: '',
      fanqieId: '',
      totalChapters: m.chapterCount,
    );
