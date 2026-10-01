import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';
import 'reader_page.dart';
import 'widgets.dart';

/// 在线书详情：渐变封面区 + 手动加入书架（入库后自动整本下载）/阅读 + 简介/章节预览 Tab
class StoreBookDetailPage extends ConsumerStatefulWidget {
  const StoreBookDetailPage({super.key, required this.fanqieId, required this.title});

  final String fanqieId;
  final String title;

  @override
  ConsumerState<StoreBookDetailPage> createState() => _StoreBookDetailPageState();
}

class _StoreBookDetailPageState extends ConsumerState<StoreBookDetailPage> {
  StoreBookDetail? _detail;
  String? _error;
  bool _busy = false;
  bool _autoTried = false;
  Timer? _poll;

  ApiClient get _api => ref.read(sessionProvider).api!;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _ensureDownloading());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.storeBookDetail(widget.fanqieId);
      if (!mounted) return;
      setState(() => _detail = d);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// 进页即自动整本下载（仅入库+下载、不加书架；书架由用户手动加入，幂等）。
  /// 已在下载中/已全文就绪时不重复触发。
  Future<void> _ensureDownloading() async {
    if (_autoTried) return;
    _autoTried = true;
    final d = _detail;
    if (d == null) return;
    if (d.status == 'ready' || d.downloadStatus == 'pending' || d.downloadStatus == 'running') {
      _startPoll();
      return;
    }
    try {
      await _api.storeAutoDownload(widget.fanqieId, addShelf: false);
    } on ApiException {
      // 静默：页面仍可浏览免费章节，底部提示会说明原因
    }
    if (!mounted) return;
    await _load();
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      final d = _detail;
      final done = d == null ||
          d.status == 'ready' ||
          d.downloadStatus == 'failed' ||
          d.downloadStatus == 'disabled';
      if (done) {
        _poll?.cancel();
        _poll = null;
        return;
      }
      _load();
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  /// 手动加入书架（入库/下载已在进页时自动处理，这里幂等补书架 + 补触发下载）
  Future<void> _addToLibrary() async {
    if (_busy || _detail == null) return;
    setState(() => _busy = true);
    try {
      await _api.storeAutoDownload(widget.fanqieId, addShelf: true);
      await _load();
      _startPoll();
      if (!mounted) return;
      _toast('已加入书架');
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 免费阅读：不进书架直接看（进页自动入库后可读免费章；未就绪时先补一次入库）
  Future<void> _openFreeRead() async {
    final d = _detail;
    if (d == null) return;
    if (d.bookId <= 0) {
      try {
        await _api.storeAutoDownload(widget.fanqieId, addShelf: false);
      } on ApiException catch (e) {
        _toast(e.message);
        return;
      }
      await _load();
      if (!mounted) return;
      if (_detail == null || _detail!.bookId <= 0) {
        _toast('书籍准备中，请稍后再试');
        return;
      }
    }
    await _openReader();
  }

  /// 已入库但整本下载失败时的手动重试
  Future<void> _retryDownload() async {
    if (_busy || _detail == null) return;
    setState(() => _busy = true);
    try {
      await _api.storeAutoDownload(widget.fanqieId, addShelf: false);
      await _load();
      _startPoll();
      if (mounted) _toast('已重新开始下载');
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 入库后点章节：直接打开阅读器并定位到该章（idx 为 0-based）
  void _openReaderAt(int chapterIdx) {
    final d = _detail!;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderPage(
        book: Book(
          id: d.bookId,
          title: d.title,
          author: d.author,
          intro: d.synopsis,
          cover: '',
          fanqieId: d.fanqieId,
          totalChapters: d.chapterCount,
        ),
        initialChapter: chapterIdx,
      ),
    ));
  }

  /// 主按钮：从上次阅读进度直接进入阅读器
  Future<void> _openReader() async {
    final d = _detail!;
    var progress = 0;
    try {
      progress = await _api.progress(d.bookId);
    } on ApiException {
      progress = 0;
    }
    if (!mounted) return;
    _openReaderAt(progress);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    if (_error != null && _detail == null) {
      return Scaffold(body: ErrorRetry(message: _error!, onRetry: _load));
    }
    if (_detail == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final d = _detail!;
    final inLib = d.inLibrary;
    final onShelf = d.onShelf;
    final busy = _busy;
    const headerH = 182.0;
    final fullyDownloaded = d.status == 'ready';

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: NestedScrollView(
          headerSliverBuilder: (_, __) => [
            SliverAppBar(
              pinned: true,
              toolbarHeight: 54,
              centerTitle: true,
              backgroundColor: dark ? MoStyle.darkPanel : const Color(0xFFF7E6D6),
              surfaceTintColor: Colors.transparent,
              title: Text('书籍详情',
                  style: TextStyle(
                      fontFamily: MoStyle.titleFont,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: MoStyle.inkOf(context))),
              expandedHeight: MediaQuery.of(context).padding.top + 54 + headerH,
              flexibleSpace: FlexibleSpaceBar(
                background: Column(
                  children: [
                    SizedBox(height: MediaQuery.of(context).padding.top + 54),
                    SizedBox(
                      height: headerH,
                      child: DetailCoverHeader(
                        coverUrl: d.cover.isEmpty ? null : d.cover,
                        title: d.title,
                        author: d.author,
                        meta: '${d.finished ? '已完结' : '连载中'} · 共 ${d.chapterCount} 章 · 免费读 ${d.freeCount} 章',
                        badge: switch (d.status) {
                          'ready' => '全文',
                          'downloading' => '下载中',
                          _ => '免费',
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          body: Column(
            children: [
              // ---------- 按钮区：进页已自动入库下载；书架始终可操作 ----------
              // 未入库：左「免费阅读」+ 右「加入书架」；
              // 已入库：左「加入书架/已在书架」+ 右「开始阅读」（自动入库不加书架，按钮不能消失）
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: inLib
                    ? Row(
                        children: [
                          Expanded(
                            child: GhostButton(
                              label: onShelf ? '已在书架' : (busy ? '处理中…' : '加入书架'),
                              icon: onShelf
                                  ? Icons.check_circle_outline
                                  : Icons.add_circle_outline,
                              onPressed: onShelf || busy ? null : _addToLibrary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: GradientButton(
                              label: '开始阅读',
                              icon: switch (d.status) {
                                'downloading' => Icons.downloading_rounded,
                                'ready' => Icons.download_done_rounded,
                                _ => Icons.menu_book_rounded,
                              },
                              onPressed: busy ? null : _openReader,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: GhostButton(
                              label: '免费阅读',
                              icon: Icons.menu_book_rounded,
                              onPressed: _openFreeRead,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GradientButton(
                              label: busy ? '处理中…' : '加入书架',
                              icon: Icons.add_circle_outline,
                              onPressed: busy ? null : _addToLibrary,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 10),
              // ---------- Tab ----------
              MoTabBar(labels: const ['简介', '章节']),
              Expanded(
                child: TabBarView(
                  children: [
                    // 简介
                    ListView(
                      padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
                      children: [
                        Text(
                          d.synopsis.isEmpty ? '暂无简介' : d.synopsis,
                          style: TextStyle(
                              fontSize: 13, height: 1.85, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                    // 章节：免费章立即可读，其余在整本下载完成后解锁
                    d.chapters.isEmpty
                        ? const EmptyView(icon: Icons.list_alt, title: '暂无章节目录')
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: d.chapters.length + 1,
                            itemBuilder: (context, i) {
                              if (i == d.chapters.length) {
                                return _DownloadFooter(
                                  ready: fullyDownloaded,
                                  downloadStatus: d.downloadStatus,
                                  onRetry: _retryDownload,
                                  truncated: d.chapterCount > d.chapters.length,
                                );
                              }
                              final ch = d.chapters[i];
                              final unlocked = fullyDownloaded || ch.isFree;
                              return ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 22),
                                title: Text(
                                  '${ch.index}. ${ch.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      color: unlocked
                                          ? cs.onSurfaceVariant
                                          : cs.outline.withValues(alpha: 0.55)),
                                ),
                                trailing: unlocked
                                    ? Icon(Icons.chevron_right,
                                        size: 18, color: cs.outline)
                                    : Icon(Icons.lock_outline,
                                        size: 15, color: cs.outline.withValues(alpha: 0.6)),
                                onTap: unlocked
                                    ? () => _openReaderAt(ch.index - 1)
                                    : () => _toast('下载完成后解锁该章节'),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 章节列表末尾：下载状态提示（进页已自动下载；失败给手动重试）
class _DownloadFooter extends StatelessWidget {
  const _DownloadFooter({
    required this.ready,
    required this.downloadStatus,
    this.onRetry,
    this.truncated = false,
  });

  final bool ready;
  final String downloadStatus;
  final VoidCallback? onRetry;

  /// 详情目录仅返回前 30 章时提示完整目录位置
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hintStyle = TextStyle(fontSize: 11.5, color: cs.outline);
    Widget child;
    if (ready) {
      child = Text('全文已下载至本地，可阅读全部章节',
          textAlign: TextAlign.center, style: hintStyle);
    } else if (downloadStatus == 'pending' || downloadStatus == 'running') {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6)),
          const SizedBox(width: 8),
          Flexible(
            child: Text('正在自动下载整本，完成后解锁全部章节',
                textAlign: TextAlign.center, style: hintStyle),
          ),
        ],
      );
    } else if (downloadStatus == 'done') {
      child = Text('下载完成，正在整理入库…',
          textAlign: TextAlign.center, style: hintStyle);
    } else if (downloadStatus == 'failed') {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text('整本下载失败，当前可在线阅读免费章节',
                textAlign: TextAlign.center, style: hintStyle),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
          ],
          if (onRetry != null)
            InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text('点击重试',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary)),
              ),
            ),
        ],
      );
    } else {
      // disabled / 无任务：TND 未配置
      child = Text('服务器未配置下载服务，当前仅可在线阅读免费章节',
          textAlign: TextAlign.center, style: hintStyle);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
      child: Column(
        children: [
          child,
          if (truncated) ...[
            const SizedBox(height: 4),
            Text('目录较长，仅展示前 30 章，其余可在阅读器内查看',
                textAlign: TextAlign.center, style: hintStyle),
          ],
        ],
      ),
    );
  }
}
