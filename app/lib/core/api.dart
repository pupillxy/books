import 'package:dio/dio.dart';

import '../models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

class LoginResult {
  final String token;
  final User user;
  const LoginResult({required this.token, required this.user});
}

/// 后端 API 客户端：App 唯一的数据出口，永不直连番茄。
class ApiClient {
  ApiClient({required this.baseUrl, this.token})
      : _dio = Dio(BaseOptions(
          baseUrl: _normalize(baseUrl),
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 60),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (token != null && token!.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));
  }

  final String baseUrl;
  final String? token;
  final Dio _dio;

  static String _normalize(String url) {
    var u = url.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  static ApiException _fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) {
      return ApiException(data['error'] as String);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException('连接超时，请检查服务器地址与网络');
      case DioExceptionType.connectionError:
        return ApiException('无法连接服务器，请检查地址与网络');
      default:
        final code = e.response?.statusCode;
        if (code != null) return ApiException('请求失败 ($code)');
        return ApiException('网络错误');
    }
  }

  /// 登录（独立请求，不依赖已有 token）
  static Future<LoginResult> login(String serverUrl, String username, String password) async {
    final dio = Dio(BaseOptions(
      baseUrl: _normalize(serverUrl),
      connectTimeout: const Duration(seconds: 8),
    ));
    try {
      final r = await dio.post('/api/auth/login', data: {
        'username': username,
        'password': password,
      });
      return LoginResult(
        token: r.data['token'] as String,
        user: User.fromJson(r.data['user'] as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      throw _fromDio(e);
    } catch (_) {
      throw ApiException('登录失败，请检查服务器地址');
    }
  }

  Future<T> _get<T>(String path, {Map<String, dynamic>? query}) async {
    try {
      final r = await _dio.get(path, queryParameters: query);
      return r.data as T;
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<T> _send<T>(String method, String path, {Map<String, dynamic>? data, Map<String, dynamic>? query}) async {
    try {
      final r = await _dio.request(path,
          data: data, queryParameters: query, options: Options(method: method));
      return r.data as T;
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  // ---------- 账号 ----------

  Future<User> me() async {
    return User.fromJson(await _get<Map<String, dynamic>>('/api/me'));
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _send<Map<String, dynamic>>('PUT', '/api/me/password', data: {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  // ---------- 书库 ----------

  Future<BookPage> books({String keyword = '', int page = 1, int size = 20}) async {
    final j = await _get<Map<String, dynamic>>('/api/books', query: {
      'keyword': keyword,
      'page': page,
      'size': size,
    });
    return BookPage.fromJson(j);
  }

  Future<BookDetailData> bookDetail(int id) async {
    final j = await _get<Map<String, dynamic>>('/api/books/$id');
    return BookDetailData.fromJson(j);
  }

  Future<Chapter> chapter(int bookId, int idx) async {
    final j = await _get<Map<String, dynamic>>('/api/books/$bookId/chapters/$idx');
    return Chapter.fromJson(j);
  }

  // ---------- 书架 ----------

  Future<List<ShelfItem>> shelf() async {
    final list = await _get<List<dynamic>>('/api/shelf');
    return list.map((e) => ShelfItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> shelfAdd(int bookId) async {
    await _send<Map<String, dynamic>>('POST', '/api/shelf', data: {'book_id': bookId});
  }

  Future<void> shelfRemove(int bookId) async {
    await _send<Map<String, dynamic>>('DELETE', '/api/shelf/$bookId');
  }

  // ---------- 阅读进度 ----------

  Future<void> saveProgress(int bookId, int chapterIdx) async {
    await _send<Map<String, dynamic>>('PUT', '/api/progress',
        data: {'book_id': bookId, 'chapter_idx': chapterIdx});
  }

  Future<int> progress(int bookId) async {
    final j = await _get<Map<String, dynamic>>('/api/progress/$bookId');
    return (j['chapter_idx'] as num?)?.toInt() ?? 0;
  }

  // ---------- 管理员 ----------

  Future<ScanStatusInfo> scanStatus() async {
    return ScanStatusInfo.fromJson(await _get<Map<String, dynamic>>('/api/admin/scan'));
  }

  Future<void> triggerScan() async {
    await _send<Map<String, dynamic>>('POST', '/api/admin/scan');
  }

  // ---------- 书城 ----------

  Future<List<RankGroup>> storeRanks() async {
    final j = await _get<Map<String, dynamic>>('/api/store/ranks');
    return ((j['items'] as List?) ?? const [])
        .map((e) => RankGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<StoreBook>> storeRankBooks(String rankId, {int offset = 0, int limit = 20}) async {
    final j = await _get<Map<String, dynamic>>(
      '/api/store/ranks/$rankId/books',
      query: {'offset': offset, 'limit': limit},
    );
    return ((j['items'] as List?) ?? const [])
        .map((e) => StoreBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 预设榜单清单（App 推荐榜卡近似：recommend/finished/new/peak）
  Future<List<FeaturedBoard>> storeFeaturedBoards() async {
    final j = await _get<Map<String, dynamic>>('/api/store/featured');
    return ((j['items'] as List?) ?? const [])
        .map((e) => FeaturedBoard.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 书城搜索（网页端源）
  Future<List<LibraryBook>> storeAppSearch(String query, {int offset = 0, int count = 10}) async {
    final j = await _get<Map<String, dynamic>>('/api/store/search', query: {
      'query': query,
      'offset': offset,
      'count': count,
    });
    return ((j['items'] as List?) ?? const [])
        .map((e) => LibraryBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 预设榜单书籍（书库筛选近似，A 方案）
  Future<List<LibraryBook>> storeFeaturedBooks(
    String board, {
    String gender = '1',
    int offset = 0,
    int limit = 10,
  }) async {
    final j = await _get<Map<String, dynamic>>(
      '/api/store/featured/$board',
      query: {'gender': gender, 'offset': offset, 'limit': limit},
    );
    return ((j['items'] as List?) ?? const [])
        .map((e) => LibraryBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// App 同源书城 feed（unidbg：实时热度排行榜等模块）
  Future<List<FeedSection>> storeAppFeed() async {
    final j = await _get<Map<String, dynamic>>('/api/store/appfeed');
    return ((j['sections'] as List?) ?? const [])
        .map((e) => FeedSection.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 猜你喜欢瀑布流翻页（cell 参数来自 appfeed 分区下发）
  Future<FeedPageResult> storeAppFeedPage({
    required String cellId,
    required String planId,
    required int offset,
  }) async {
    final j = await _get<Map<String, dynamic>>('/api/store/appfeed/page',
        query: {'cell_id': cellId, 'plan_id': planId, 'offset': '$offset'});
    return FeedPageResult(
      books: ((j['books'] as List?) ?? const [])
          .map((e) => FeedBook.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextOffset: (j['next_offset'] as num?)?.toInt() ?? offset,
      hasMore: (j['has_more'] ?? false) as bool,
    );
  }

  /// 小说频道筛选瀑布流（官方 cell/change 协议；filters 为官方筛选值逗号串，
  /// 如 finished,online_in_past_one_year / 空串=不筛选）
  Future<FeedPageResult> storeNovelFeed({
    String filters = '',
    required int offset,
  }) async {
    final j = await _get<Map<String, dynamic>>('/api/store/novelfeed',
        query: {'filters': filters, 'offset': '$offset'});
    return FeedPageResult(
      books: ((j['items'] as List?) ?? const [])
          .map((e) => FeedBook.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextOffset: (j['next_offset'] as num?)?.toInt() ?? offset,
      hasMore: (j['has_more'] ?? false) as bool,
    );
  }

  /// 漫画频道瀑布流
  Future<FeedPageResultExt<ComicBook>> storeComicFeed({required int offset}) async {
    final j = await _get<Map<String, dynamic>>('/api/store/comicfeed',
        query: {'offset': '$offset'});
    return FeedPageResultExt(
      items: ((j['items'] as List?) ?? const [])
          .map((e) => ComicBook.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextOffset: (j['next_offset'] as num?)?.toInt() ?? offset,
      hasMore: (j['has_more'] ?? false) as bool,
    );
  }

  /// 漫画详情 + 全量话列表
  Future<ComicDetailData> storeComicDetail(String bookId) async {
    final j = await _get<Map<String, dynamic>>('/api/store/comics/$bookId');
    return ComicDetailData.fromJson(j);
  }

  /// 漫画单话图片列表（proxy 为 server 解密代理的相对路径，这里拼成绝对地址）
  Future<ComicChapterContent> storeComicChapter(String bookId, String itemId) async {
    final j = await _get<Map<String, dynamic>>('/api/store/comics/$bookId/chapters/$itemId');
    final images = (j['images'] as List?) ?? const [];
    for (final e in images) {
      if (e is Map && e['proxy'] is String) {
        final p = e['proxy'] as String;
        e['proxy'] = p.startsWith('http') ? p : '$baseUrl$p';
      }
    }
    return ComicChapterContent.fromJson(j);
  }

  /// 书库分类树（gender: '1'=男生 '0'=女生，分组 label: 主分类/主题/角色/情节）
  Future<List<LibCategory>> storeLibraryCategories(String gender) async {
    final j = await _get<Map<String, dynamic>>('/api/store/library/categories',
        query: {'gender': gender});
    return ((j['items'] as List?) ?? const [])
        .map((e) => LibCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 书库筛选列表（page 从 0 起）
  Future<List<LibraryBook>> storeLibraryBooks({
    String gender = '1',
    int category = -1,
    int status = -1,
    int words = 0,
    int sort = 0,
    int page = 0,
    int size = 18,
  }) async {
    final j = await _get<Map<String, dynamic>>('/api/store/library/books', query: {
      'gender': gender,
      'category': category,
      'status': status,
      'words': words,
      'sort': sort,
      'page': page,
      'size': size,
    });
    return ((j['items'] as List?) ?? const [])
        .map((e) => LibraryBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StoreBookDetail> storeBookDetail(String fanqieId) async {
    final j = await _get<Map<String, dynamic>>('/api/store/books/$fanqieId');
    return StoreBookDetail.fromJson(j);
  }

  /// 返回入库后的 book_id（已入库时 already=true）
  Future<Map<String, dynamic>> storeAddBook(String fanqieId, {bool download = false}) async {
    return await _send<Map<String, dynamic>>('POST', '/api/store/books/$fanqieId/add',
        data: {'download': download});
  }

  /// 入库 + 整本下载（幂等，已就绪/下载中直接返回当前状态）。
  /// [addShelf] 为 false 时仅入库+下载、不加入书架（详情页进页自动下载用）。
  Future<Map<String, dynamic>> storeAutoDownload(String fanqieId, {bool addShelf = true}) async {
    return await _send<Map<String, dynamic>>('POST', '/api/store/books/$fanqieId/auto',
        query: {'shelf': addShelf ? 1 : 0});
  }

  Future<Map<String, dynamic>> storeTriggerDownload(String fanqieId) async {
    return await _send<Map<String, dynamic>>('POST', '/api/store/books/$fanqieId/download');
  }

  Future<List<DownloadTask>> storeDownloads() async {
    final j = await _get<Map<String, dynamic>>('/api/store/downloads');
    return ((j['items'] as List?) ?? const [])
        .map((e) => DownloadTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---------- 短剧（红果） ----------

  // 封面改走服务端代理：响应里的 cover 是相对代理路径（/api/drama/cover?p=...&s=...），
  // 这里拼上 baseUrl 变成绝对地址给 Image.network 用（与播放流 URL 同一模式）。
  String _absCover(String u) => (u.isEmpty || u.startsWith('http')) ? u : '$baseUrl$u';

  /// 就地改写单个对象里的 cover 字段
  void _absCoverMap(dynamic m) {
    if (m is Map && m['cover'] is String) {
      m['cover'] = _absCover(m['cover'] as String);
    }
  }

  /// 就地改写列表里每项的 cover 字段
  void _absCoverList(dynamic items) {
    if (items is List) {
      for (final it in items) {
        _absCoverMap(it);
      }
    }
  }

  Future<List<DramaGenre>> dramaGenres() async {
    final j = await _get<Map<String, dynamic>>('/api/drama/genres');
    return ((j['items'] as List?) ?? const [])
        .map((e) => DramaGenre.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// tag 为二级筛选（格式 dim|id，如 category_dim_theme|xxx），可选；
  /// gender 为频道筛选（"1"=男频 "0"=女频，空=不限），可选
  Future<DramaCatalogPage> dramaCatalog(String genre,
      {int offset = 0, String tag = '', String gender = ''}) async {
    final q = <String, dynamic>{'genre': genre, 'offset': offset};
    if (tag.isNotEmpty) q['tag'] = tag;
    if (gender.isNotEmpty) q['gender'] = gender;
    final j = await _get<Map<String, dynamic>>('/api/drama/catalog', query: q);
    _absCoverList(j['items']);
    return DramaCatalogPage.fromJson(j);
  }

  Future<List<DramaItem>> dramaSearch(String kw) async {
    final j = await _get<Map<String, dynamic>>('/api/drama/search', query: {'kw': kw});
    _absCoverList(j['items']);
    return ((j['items'] as List?) ?? const [])
        .map((e) => DramaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DramaDetailData> dramaDetail(String sid) async {
    final j = await _get<Map<String, dynamic>>('/api/drama/detail', query: {'sid': sid});
    _absCoverMap(j['drama']);
    return DramaDetailData.fromJson(j);
  }

  /// 播放线路（url 为相对代理地址，如 /api/drama/stream?...，需拼 baseUrl）
  Future<List<DramaQuality>> dramaPlay(String sid, String vid) async {
    final j = await _get<Map<String, dynamic>>(
      '/api/drama/play',
      query: {'sid': sid, 'vid': vid},
    );
    return ((j['qualities'] as List?) ?? const [])
        .map((e) => DramaQuality.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 上报观看进度（切集时调用；失败静默——记录绝不能影响播放）
  Future<void> reportDramaProgress({
    required String sid,
    required String title,
    required String cover,
    required int totalEps,
    required int epIndex,
  }) async {
    try {
      await _send<Map<String, dynamic>>('PUT', '/api/drama/progress', data: {
        'sid': sid,
        'title': title,
        'cover': cover,
        'total_eps': totalEps,
        'ep_index': epIndex,
      });
    } on ApiException {
      // 忽略：进度上报失败无伤大雅
    }
  }

  /// 查询某部短剧看到第几集（无记录返回 0）
  Future<int> dramaProgress(String sid) async {
    final j = await _get<Map<String, dynamic>>('/api/drama/progress/$sid');
    return (j['ep_index'] as num?)?.toInt() ?? 0;
  }

  /// 观看记录（最近在前）
  Future<List<DramaHistoryItem>> dramaHistory() async {
    final j = await _get<Map<String, dynamic>>('/api/drama/history');
    _absCoverList(j['items']);
    return ((j['items'] as List?) ?? const [])
        .map((e) => DramaHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteDramaHistory(String sid) async {
    await _send<Map<String, dynamic>>('DELETE', '/api/drama/history/$sid');
  }
}
