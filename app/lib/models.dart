// 与后端 (Go) 返回结构一一对应的数据模型

class User {
  final int id;
  final String username;
  final String nickname;
  final bool isAdmin;

  const User({
    required this.id,
    required this.username,
    required this.nickname,
    required this.isAdmin,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: (j['id'] as num).toInt(),
        username: (j['username'] ?? '') as String,
        nickname: (j['nickname'] ?? '') as String,
        isAdmin: (j['is_admin'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'is_admin': isAdmin,
      };

  String get displayName => nickname.isNotEmpty ? nickname : username;
}

class Book {
  final int id;
  final String title;
  final String author;
  final String intro;
  final String cover;
  final String fanqieId;
  final int totalChapters;

  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.intro,
    required this.cover,
    required this.fanqieId,
    required this.totalChapters,
  });

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: (j['id'] as num).toInt(),
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        intro: (j['intro'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        fanqieId: (j['fanqie_id'] ?? '') as String,
        totalChapters: (j['total_chapters'] as num?)?.toInt() ?? 0,
      );

  /// 后端把封面存成本地绝对路径（…/downloads/<书名>/cover.jpg），
  /// 服务端以 /covers 静态暴露下载目录，这里换算成可访问的 URL；
  /// 在线书（书城入库）存的是番茄 CDN 直链，直接使用。
  String? coverUrl(String baseUrl) {
    if (cover.isEmpty) return null;
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    final p = cover.replaceAll('\\', '/');
    final key = 'downloads/';
    final i = p.lastIndexOf(key);
    if (i < 0) return null;
    final rel = p.substring(i + key.length);
    final encoded = rel.split('/').map(Uri.encodeComponent).join('/');
    return '$baseUrl/covers/$encoded';
  }
}

class ChapterMeta {
  final int idx;
  final String title;

  const ChapterMeta({required this.idx, required this.title});

  factory ChapterMeta.fromJson(Map<String, dynamic> j) => ChapterMeta(
        idx: (j['idx'] as num).toInt(),
        title: (j['title'] ?? '') as String,
      );
}

class Chapter {
  final int idx;
  final String title;
  final String content;

  const Chapter({required this.idx, required this.title, required this.content});

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        idx: (j['idx'] as num).toInt(),
        title: (j['title'] ?? '') as String,
        content: (j['content'] ?? '') as String,
      );
}

class ShelfItem {
  final Book book;
  final int progressChapterIdx;

  const ShelfItem({required this.book, required this.progressChapterIdx});

  factory ShelfItem.fromJson(Map<String, dynamic> j) => ShelfItem(
        book: Book.fromJson(j['book'] as Map<String, dynamic>),
        progressChapterIdx: (j['progress_chapter_idx'] as num?)?.toInt() ?? 0,
      );
}

class BookPage {
  final int total;
  final int page;
  final List<Book> items;

  const BookPage({required this.total, required this.page, required this.items});

  factory BookPage.fromJson(Map<String, dynamic> j) => BookPage(
        total: (j['total'] as num?)?.toInt() ?? 0,
        page: (j['page'] as num?)?.toInt() ?? 1,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => Book.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class BookDetailData {
  final Book book;
  final List<ChapterMeta> chapters;

  const BookDetailData({required this.book, required this.chapters});

  factory BookDetailData.fromJson(Map<String, dynamic> j) => BookDetailData(
        book: Book.fromJson(j['book'] as Map<String, dynamic>),
        chapters: ((j['chapters'] as List?) ?? const [])
            .map((e) => ChapterMeta.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ScanStatusInfo {
  final String lastScan;
  final bool scanning;
  final int lastImported;
  final int totalBooks;

  const ScanStatusInfo({
    required this.lastScan,
    required this.scanning,
    required this.lastImported,
    required this.totalBooks,
  });

  factory ScanStatusInfo.fromJson(Map<String, dynamic> j) => ScanStatusInfo(
        lastScan: (j['last_scan'] ?? '') as String,
        scanning: (j['scanning'] ?? false) as bool,
        lastImported: (j['last_imported'] as num?)?.toInt() ?? 0,
        totalBooks: (j['total_books'] as num?)?.toInt() ?? 0,
      );
}

// ---------- 书城 ----------

class RankItem {
  final String id;
  final String name;

  const RankItem({required this.id, required this.name});

  factory RankItem.fromJson(Map<String, dynamic> j) => RankItem(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
      );
}

class RankGroup {
  final String title;
  final List<RankItem> items;

  const RankGroup({required this.title, required this.items});

  factory RankGroup.fromJson(Map<String, dynamic> j) => RankGroup(
        title: (j['title'] ?? '') as String,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => RankItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class StoreBook {
  final String id;
  final int rank;
  final String title;
  final String author;
  final String synopsis;
  final String cover;
  final bool inLibrary;
  final int localBookId;
  final String localStatus;

  const StoreBook({
    required this.id,
    required this.rank,
    required this.title,
    required this.author,
    required this.synopsis,
    required this.cover,
    this.inLibrary = false,
    this.localBookId = 0,
    this.localStatus = '',
  });

  factory StoreBook.fromJson(Map<String, dynamic> j) => StoreBook(
        id: (j['id'] ?? '') as String,
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        inLibrary: (j['in_library'] ?? false) as bool,
        localBookId: (j['book_id'] as num?)?.toInt() ?? 0,
        localStatus: (j['status'] ?? '') as String,
      );

  /// 番茄封面 CDN 直链，无需代理
  String? get coverUrl => cover.isEmpty ? null : cover;
}

/// 书库分类项（label: 主分类/主题/角色/情节）
class LibCategory {
  final String label;
  final String name;
  final int id;

  const LibCategory({required this.label, required this.name, required this.id});

  factory LibCategory.fromJson(Map<String, dynamic> j) => LibCategory(
        label: (j['label'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        id: (j['id'] as num?)?.toInt() ?? 0,
      );
}

/// 书库书籍条目
class LibraryBook {
  final String id;
  final String title;
  final String author;
  final String synopsis;
  final String cover;
  final bool finished;
  final String wordCount;
  final String readCount; // 形如 "47.6万人在读"，榜单卡片副行用
  final bool inLibrary;
  final int localBookId;
  final String localStatus;

  const LibraryBook({
    required this.id,
    required this.title,
    required this.author,
    required this.synopsis,
    required this.cover,
    this.finished = false,
    this.wordCount = '',
    this.readCount = '',
    this.inLibrary = false,
    this.localBookId = 0,
    this.localStatus = '',
  });

  factory LibraryBook.fromJson(Map<String, dynamic> j) => LibraryBook(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        finished: (j['finished'] ?? false) as bool,
        wordCount: (j['word_count'] ?? '') as String,
        readCount: (j['read_count'] ?? '') as String,
        inLibrary: (j['in_library'] ?? false) as bool,
        localBookId: (j['book_id'] as num?)?.toInt() ?? 0,
        localStatus: (j['status'] ?? '') as String,
      );

  String? get coverUrl => cover.isEmpty ? null : cover;
}

/// 预设榜单条目（App 推荐榜卡近似，server /api/store/featured）
class FeaturedBoard {
  final String key;
  final String name;

  const FeaturedBoard({required this.key, required this.name});

  factory FeaturedBoard.fromJson(Map<String, dynamic> j) => FeaturedBoard(
        key: (j['key'] ?? '') as String,
        name: (j['name'] ?? '') as String,
      );
}

class StoreChapter {
  final String id;
  final int index;
  final String title;
  final bool isFree;

  const StoreChapter({required this.id, required this.index, required this.title, required this.isFree});

  factory StoreChapter.fromJson(Map<String, dynamic> j) => StoreChapter(
        id: (j['id'] ?? '') as String,
        index: (j['index'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '') as String,
        isFree: (j['is_free'] ?? false) as bool,
      );
}

class StoreBookDetail {
  final String fanqieId;
  final String title;
  final String author;
  final String cover;
  final String synopsis;
  final int chapterCount;
  final int freeCount;
  final bool finished;
  final List<StoreChapter> chapters;
  final bool inLibrary;
  final bool onShelf; // 是否已在当前用户书架（未入库时恒为 false）
  final int bookId;
  final String status;
  final String downloadStatus;

  const StoreBookDetail({
    required this.fanqieId,
    required this.title,
    required this.author,
    required this.cover,
    required this.synopsis,
    required this.chapterCount,
    required this.freeCount,
    required this.finished,
    required this.chapters,
    required this.inLibrary,
    required this.onShelf,
    required this.bookId,
    required this.status,
    required this.downloadStatus,
  });

  factory StoreBookDetail.fromJson(Map<String, dynamic> j) => StoreBookDetail(
        fanqieId: (j['fanqie_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        chapterCount: (j['chapter_count'] as num?)?.toInt() ?? 0,
        freeCount: (j['free_count'] as num?)?.toInt() ?? 0,
        finished: (j['finished'] ?? false) as bool,
        chapters: ((j['chapters'] as List?) ?? const [])
            .map((e) => StoreChapter.fromJson(e as Map<String, dynamic>))
            .toList(),
        inLibrary: (j['in_library'] ?? false) as bool,
        onShelf: (j['on_shelf'] ?? false) as bool,
        bookId: (j['book_id'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? '') as String,
        downloadStatus: (j['download_status'] ?? '') as String,
      );
}

class DownloadTask {
  final String fanqieId;
  final String title;
  final String status;

  const DownloadTask({required this.fanqieId, required this.title, required this.status});

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        fanqieId: (j['fanqie_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        status: (j['status'] ?? '') as String,
      );
}

// ---------- 短剧（红果） ----------

class DramaGenre {
  final String key;
  final String name;

  const DramaGenre({required this.key, required this.name});

  factory DramaGenre.fromJson(Map<String, dynamic> j) => DramaGenre(
        key: (j['key'] ?? '') as String,
        name: (j['name'] ?? '') as String,
      );
}

class DramaItem {
  final String id;
  final String title;
  final String cover;
  final String intro;
  final String category;
  final List<String> tags;
  final String remark; // 如 "共80集"
  final String episodeCount;
  final bool finished;
  final String score;
  final String playCount;

  const DramaItem({
    required this.id,
    required this.title,
    required this.cover,
    this.intro = '',
    this.category = '',
    this.tags = const [],
    this.remark = '',
    this.episodeCount = '',
    this.finished = false,
    this.score = '',
    this.playCount = '',
  });

  factory DramaItem.fromJson(Map<String, dynamic> j) => DramaItem(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        intro: (j['intro'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        tags: ((j['tags'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        remark: (j['remark'] ?? '') as String,
        episodeCount: (j['episode_count'] ?? '') as String,
        finished: (j['finished'] ?? false) as bool,
        score: (j['score'] ?? '') as String,
        playCount: (j['play_count'] ?? '') as String,
      );
}

class DramaCatalogPage {
  final List<DramaItem> items;
  final bool hasMore;
  final int nextOffset;
  final List<DramaFilterDim> filters; // 二级筛选面板（首屏返回）

  const DramaCatalogPage({
    required this.items,
    required this.hasMore,
    required this.nextOffset,
    this.filters = const [],
  });

  factory DramaCatalogPage.fromJson(Map<String, dynamic> j) => DramaCatalogPage(
        items: ((j['items'] as List?) ?? const [])
            .map((e) => DramaItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        hasMore: (j['has_more'] ?? false) as bool,
        nextOffset: (j['next_offset'] as num?)?.toInt() ?? 0,
        filters: ((j['filters'] as List?) ?? const [])
            .map((e) => DramaFilterDim.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 二级筛选维度（主题/角色/年代…）及组内可选项
class DramaFilterDim {
  final String key;
  final String title;
  final List<DramaFilterItem> items;

  const DramaFilterDim({required this.key, required this.title, required this.items});

  factory DramaFilterDim.fromJson(Map<String, dynamic> j) => DramaFilterDim(
        key: (j['key'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => DramaFilterItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DramaFilterItem {
  final String id;
  final String name;

  const DramaFilterItem({required this.id, required this.name});

  factory DramaFilterItem.fromJson(Map<String, dynamic> j) => DramaFilterItem(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
      );
}

class DramaEpisode {
  final String vid;
  final int index; // 1-based

  const DramaEpisode({required this.vid, required this.index});

  factory DramaEpisode.fromJson(Map<String, dynamic> j) => DramaEpisode(
        vid: (j['vid'] ?? '') as String,
        index: (j['index'] as num?)?.toInt() ?? 0,
      );
}

class DramaDetailData {
  final DramaItem drama;
  final List<DramaEpisode> episodes;

  const DramaDetailData({required this.drama, required this.episodes});

  factory DramaDetailData.fromJson(Map<String, dynamic> j) => DramaDetailData(
        drama: DramaItem.fromJson(j['drama'] as Map<String, dynamic>),
        episodes: ((j['episodes'] as List?) ?? const [])
            .map((e) => DramaEpisode.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DramaQuality {
  final String name;
  final String url; // 相对代理地址，如 /api/drama/stream?...
  final int quality;

  const DramaQuality({required this.name, required this.url, required this.quality});

  factory DramaQuality.fromJson(Map<String, dynamic> j) => DramaQuality(
        name: (j['name'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        quality: (j['quality'] as num?)?.toInt() ?? 0,
      );
}

/// 短剧观看记录（服务端持久化，跨设备同步）
class DramaHistoryItem {
  final String sid;
  final String title;
  final String cover;
  final int totalEps;
  final int epIndex; // 看到的集（1-based）
  final String updatedAt; // 服务端 UTC 时间 "2026-09-28 03:33:04"

  const DramaHistoryItem({
    required this.sid,
    required this.title,
    required this.cover,
    required this.totalEps,
    required this.epIndex,
    required this.updatedAt,
  });

  factory DramaHistoryItem.fromJson(Map<String, dynamic> j) => DramaHistoryItem(
        sid: (j['sid'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        totalEps: (j['total_eps'] as num?)?.toInt() ?? 0,
        epIndex: (j['ep_index'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] ?? '') as String,
      );
}

/// App 同源书城 feed 的一个模块（如「排行榜」）
class FeedSection {
  final String title;
  final String subtitle;
  final List<FeedBook> books;

  const FeedSection({required this.title, required this.subtitle, required this.books});

  factory FeedSection.fromJson(Map<String, dynamic> j) => FeedSection(
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? '') as String,
        books: ((j['books'] as List?) ?? const [])
            .map((e) => FeedBook.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// App 推荐流中的一本书
class FeedBook {
  final String id;
  final String title;
  final String author;
  final String synopsis;
  final String cover;
  final bool finished;
  final String readCount;
  final String score;
  final String rankScore;
  final String category;
  final String tags;

  const FeedBook({
    required this.id,
    required this.title,
    required this.author,
    required this.synopsis,
    required this.cover,
    this.finished = false,
    this.readCount = '',
    this.score = '',
    this.rankScore = '',
    this.category = '',
    this.tags = '',
  });

  factory FeedBook.fromJson(Map<String, dynamic> j) => FeedBook(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        finished: (j['finished'] ?? false) as bool,
        readCount: (j['read_count'] ?? '') as String,
        score: (j['score'] ?? '') as String,
        rankScore: (j['rank_score'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        tags: (j['tags'] ?? '') as String,
      );
}
