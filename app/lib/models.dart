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
  final bool isComic; // source=comic：漫画行（仅元数据，阅读走漫画接口）

  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.intro,
    required this.cover,
    required this.fanqieId,
    required this.totalChapters,
    this.isComic = false,
  });

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: (j['id'] as num).toInt(),
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        intro: (j['intro'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        fanqieId: (j['fanqie_id'] ?? '') as String,
        totalChapters: (j['total_chapters'] as num?)?.toInt() ?? 0,
        isComic: (j['source'] ?? '') == 'comic',
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
  final bool finished;
  final String wordCount;
  final String readCount;
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
    this.finished = false,
    this.wordCount = '',
    this.readCount = '',
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
        finished: (j['finished'] ?? false) as bool,
        wordCount: (j['word_count'] ?? '') as String,
        readCount: (j['read_count'] ?? '') as String,
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
  // 猜你喜欢瀑布流分页游标（仅个性化 feed 分区携带）
  final String cellId;
  final String planId;
  final int algoType;
  final int nextOffset;

  const FeedSection({
    required this.title,
    required this.subtitle,
    required this.books,
    this.cellId = '',
    this.planId = '',
    this.algoType = 0,
    this.nextOffset = 0,
  });

  bool get paginatable => cellId.isNotEmpty && nextOffset > 0;

  factory FeedSection.fromJson(Map<String, dynamic> j) => FeedSection(
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? '') as String,
        books: ((j['books'] as List?) ?? const [])
            .map((e) => FeedBook.fromJson(e as Map<String, dynamic>))
            .toList(),
        cellId: (j['cell_id'] ?? '') as String,
        planId: (j['plan_id'] ?? '') as String,
        algoType: (j['algo_type'] as num?)?.toInt() ?? 0,
        nextOffset: (j['next_offset'] as num?)?.toInt() ?? 0,
      );
}

/// 瀑布流翻页结果
class FeedPageResult {
  final List<FeedBook> books;
  final int nextOffset;
  final bool hasMore;

  const FeedPageResult({
    required this.books,
    required this.nextOffset,
    required this.hasMore,
  });
}

/// 通用分页结果（非 FeedBook 条目，如漫画频道卡）
class FeedPageResultExt<T> {
  final List<T> items;
  final int nextOffset;
  final bool hasMore;

  const FeedPageResultExt({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
  });
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
  final String wordCount; // 原始字数值（"2595175"），显示时格式化

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
    this.wordCount = '',
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
        wordCount: (j['word_count'] ?? '') as String,
      );

  /// 字数展示："2595175" → "259.5万字"；缺失返回空
  String get wordCountText {
    final n = int.tryParse(wordCount);
    if (n == null || n <= 0) return '';
    if (n >= 10000) {
      final w = n / 10000;
      return '${w >= 100 ? w.toStringAsFixed(0) : w.toStringAsFixed(1)}万字';
    }
    return '$n字';
  }
}

/// 漫画频道卡片（server /api/store/comicfeed）
class ComicBook {
  final String id;
  final String title;
  final String author;
  final String synopsis;
  final String cover;
  final String category;
  final String readCount; // 形如 "12.5万人在读"
  final String updateTag; // 形如 "周更"
  final String wordCount; // 复用字段装 "322话"
  final String score;
  final bool finished;

  const ComicBook({
    required this.id,
    required this.title,
    required this.author,
    required this.cover,
    this.synopsis = '',
    this.category = '',
    this.readCount = '',
    this.updateTag = '',
    this.wordCount = '',
    this.score = '',
    this.finished = false,
  });

  factory ComicBook.fromJson(Map<String, dynamic> j) => ComicBook(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        readCount: (j['read_count'] ?? '') as String,
        updateTag: (j['update_tag'] ?? '') as String,
        wordCount: (j['word_count'] ?? '') as String,
        score: (j['score'] ?? '') as String,
        finished: (j['finished'] ?? false) as bool,
      );
}

/// 漫画详情（server /api/store/comics/:bookID）
class ComicDetailData {
  final String id;
  final String title;
  final String author;
  final String cover;
  final String synopsis;
  final String category;
  final String tags;
  final String score;
  final String readCount;
  final String updateTag;
  final bool finished;
  final bool onShelf; // 是否已在当前用户书架（未入库恒为 false）
  final List<StoreChapter> chapters;

  const ComicDetailData({
    required this.id,
    required this.title,
    required this.author,
    required this.cover,
    required this.synopsis,
    required this.chapters,
    this.category = '',
    this.tags = '',
    this.score = '',
    this.readCount = '',
    this.updateTag = '',
    this.finished = false,
    this.onShelf = false,
  });

  factory ComicDetailData.fromJson(Map<String, dynamic> j) => ComicDetailData(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        cover: (j['cover'] ?? '') as String,
        synopsis: (j['synopsis'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        tags: (j['tags'] ?? '') as String,
        score: (j['score'] ?? '') as String,
        readCount: (j['read_count'] ?? '') as String,
        updateTag: (j['update_tag'] ?? '') as String,
        finished: (j['finished'] ?? false) as bool,
        onShelf: (j['on_shelf'] ?? false) as bool,
        chapters: ((j['chapters'] as List?) ?? const [])
            .map((e) => StoreChapter.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 漫画单话内容（server /api/store/comics/:bookID/chapters/:itemID）
class ComicChapterContent {
  final List<ComicImage> images;

  const ComicChapterContent({required this.images});

  factory ComicChapterContent.fromJson(Map<String, dynamic> j) =>
      ComicChapterContent(
        images: ((j['images'] as List?) ?? const [])
            .map((e) => ComicImage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 漫画页图片（server 解密代理地址，CDN 原图为加密文件不能直连）
class ComicImage {
  final String url;
  final int width;
  final int height;

  const ComicImage({required this.url, this.width = 0, this.height = 0});

  factory ComicImage.fromJson(Map<String, dynamic> j) => ComicImage(
        url: (j['proxy'] ?? j['url'] ?? '') as String,
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
      );
}

// ─── 书城分类页（官方 new_category 协议，10/05 定案）─────────────────

/// 分类页顶部频道（server 只透出小说两频道：男生=1 / 女生=0）
class StoreCategoryTab {
  final int id;
  final String name;

  const StoreCategoryTab({required this.id, required this.name});

  factory StoreCategoryTab.fromJson(Map<String, dynamic> j) => StoreCategoryTab(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? '') as String,
      );
}

/// 分类标签（点击进书单页）
class StoreCategoryTag {
  final int id;
  final String name;

  const StoreCategoryTag({required this.id, required this.name});

  factory StoreCategoryTag.fromJson(Map<String, dynamic> j) => StoreCategoryTag(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? '') as String,
      );
}

/// 左侧栏分组（热门标签/主题/角色/情节）
class StoreCategoryGroup {
  final String name;
  final List<StoreCategoryTag> tags;

  const StoreCategoryGroup({required this.name, required this.tags});

  factory StoreCategoryGroup.fromJson(Map<String, dynamic> j) =>
      StoreCategoryGroup(
        name: (j['name'] ?? '') as String,
        tags: ((j['tags'] as List?) ?? const [])
            .map((e) => StoreCategoryTag.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 分类页标签树（单频道）
class StoreCategoriesData {
  final int tab;
  final String name;
  final List<StoreCategoryTab> tabs;
  final List<StoreCategoryGroup> groups;

  const StoreCategoriesData({
    required this.tab,
    required this.name,
    required this.tabs,
    required this.groups,
  });

  factory StoreCategoriesData.fromJson(Map<String, dynamic> j) =>
      StoreCategoriesData(
        tab: (j['tab'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? '') as String,
        tabs: ((j['tabs'] as List?) ?? const [])
            .map((e) => StoreCategoryTab.fromJson(e as Map<String, dynamic>))
            .toList(),
        groups: ((j['groups'] as List?) ?? const [])
            .map((e) => StoreCategoryGroup.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 分类书单页（landing）：书单 + 官方 banner 语 + 相关分类
class CategoryFeedPageResult {
  final List<FeedBook> books;
  final int nextOffset;
  final bool hasMore;
  final String banner;
  final List<StoreCategoryTag> related;

  const CategoryFeedPageResult({
    required this.books,
    required this.nextOffset,
    required this.hasMore,
    this.banner = '',
    this.related = const [],
  });

  factory CategoryFeedPageResult.fromJson(Map<String, dynamic> j) =>
      CategoryFeedPageResult(
        books: ((j['items'] as List?) ?? const [])
            .map((e) => FeedBook.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextOffset: (j['next_offset'] as num?)?.toInt() ?? 0,
        hasMore: (j['has_more'] ?? false) as bool,
        banner: (j['banner'] ?? '') as String,
        related: ((j['related'] as List?) ?? const [])
            .map((e) => StoreCategoryTag.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
