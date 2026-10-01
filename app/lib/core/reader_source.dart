// 阅读器数据源抽象：同一套 ReaderPage 同时服务「服务端书」和「本机书」。
// 服务端书走 API（目录/正文/进度都在服务器，跨设备同步）；
// 本机书全部落在设备本地（切分表 + 正文切片 + 本地进度），不产生任何网络请求。

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'api.dart';
import 'local_books.dart';

abstract class ReaderSource {
  /// 用于阅读器本地持久化（`rd.ch.<key>` / `rd.pg.<key>` / `rd.so.<key>`）的键
  String get persistKey;

  int get totalChapters;

  Future<List<ChapterMeta>> loadToc();

  Future<Chapter> loadChapter(int idx);

  /// 保存阅读进度（实现方自行决定存本地还是报服务端；允许 fire-and-forget）
  void saveProgress(int chapterIdx);
}

/// 服务端书：目录、正文、进度都走 API，按用户存储，跨设备同步
class ApiReaderSource implements ReaderSource {
  ApiReaderSource(this._api, this._book);

  final ApiClient _api;
  final Book _book;
  int? _tocTotal; // 目录加载后以实际章节数为准

  @override
  String get persistKey => '${_book.id}';

  @override
  int get totalChapters => _tocTotal ?? _book.totalChapters;

  @override
  Future<List<ChapterMeta>> loadToc() async {
    final toc = (await _api.bookDetail(_book.id)).chapters;
    _tocTotal = toc.length;
    return toc;
  }

  @override
  Future<Chapter> loadChapter(int idx) => _api.chapter(_book.id, idx);

  @override
  void saveProgress(int chapterIdx) {
    // 调用方已不等待，这里吞错：进度上报失败绝不影响阅读
    _api.saveProgress(_book.id, chapterIdx).catchError((_) {});
  }
}

/// 本机书：正文与进度全在设备本地，不同步到服务器
class LocalReaderSource implements ReaderSource {
  LocalReaderSource(this._content)
      : persistKey = 'local_${_content.meta.id}';

  final LocalBookContent _content;
  late final List<ChapterMeta> _toc = [
    for (final c in _content.meta.chapters)
      ChapterMeta(
        idx: (c['idx'] as num).toInt(),
        title: (c['title'] ?? '') as String,
      ),
  ];

  @override
  final String persistKey;

  @override
  int get totalChapters => _toc.length;

  @override
  Future<List<ChapterMeta>> loadToc() async => _toc;

  @override
  Future<Chapter> loadChapter(int idx) async => _content.chapterAt(idx);

  @override
  void saveProgress(int chapterIdx) {
    // 进度只存本机（`rd.ch.local_<id>`），阅读器恢复逻辑与在线书共用同一套 key
    SharedPreferences.getInstance().then((p) {
      p.setInt('rd.ch.$persistKey', chapterIdx);
    });
  }
}
