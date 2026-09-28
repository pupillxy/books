import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/api.dart';
import '../core/mo_theme.dart';
import '../core/session.dart';
import '../models.dart';

/// 短剧播放器：抖音式上下滑动切集。
/// 当前集播放中，前后各一集提前建好播放器（取线路 + ExoPlayer prepare），
/// 滑过去即秒开；滑出窗口的集自动回收。
class DramaPlayerPage extends ConsumerStatefulWidget {
  const DramaPlayerPage({
    super.key,
    required this.sid,
    required this.title,
    required this.index,
    required this.episodes,
    this.cover = '',
  });

  final String sid;
  final String title;
  final int index; // 1-based
  final List<DramaEpisode> episodes;
  final String cover; // 用于观看记录展示

  @override
  ConsumerState<DramaPlayerPage> createState() => _DramaPlayerPageState();
}

/// 单集的播放资源：控制器 + 该集可选清晰度 + 加载态
class _Ep {
  VideoPlayerController? ctrl;
  List<DramaQuality> qualities = const [];
  bool loading = true;
  String? error;
  bool ended = false; // 已播完（防止自动切集重复触发）
  int token = 0; // 防并发令牌：重试/换清晰度开启新一轮，旧轮次结果直接丢弃
}

class _DramaPlayerPageState extends ConsumerState<DramaPlayerPage> {
  late final List<DramaEpisode> _eps;
  late final PageController _pageController;
  int _cur = 0; // 当前集在 _eps 中的位置
  final Map<int, _Ep> _players = {};

  int _stickyQuality = 0; // 清晰度选择跨集记忆
  bool _controlsVisible = true;
  bool _dragging = false; // 进度条拖动中
  DateTime _swipeResetAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _hideTimer; // 控制层自动隐藏定时器（避免逐帧轮询导致整页每秒重建）

  @override
  void initState() {
    super.initState();
    _eps = [...widget.episodes]..sort((a, b) => a.index.compareTo(b.index));
    _cur = _eps.indexWhere((e) => e.index == widget.index);
    if (_cur < 0) _cur = 0;
    _pageController = PageController(initialPage: _cur);
    _ensure(_cur);
    _ensure(_cur + 1); // 预加载下一集
    _ensure(_cur - 1); // 预加载上一集
    _report(_eps[_cur].index);
  }

  // 上报观看进度到服务端（fire-and-forget，API 内部吞错，绝不影响播放）
  void _report(int epIndex) {
    final api = ref.read(sessionProvider).api;
    if (api == null) return;
    unawaited(api.reportDramaProgress(
      sid: widget.sid,
      title: widget.title,
      cover: widget.cover,
      totalEps: _eps.length,
      epIndex: epIndex,
    ));
  }

  // 加载并初始化某一集：取线路 → 建流 → ExoPlayer prepare，失败自动重试 2 次。
  // 真机上手机 WiFi 偶发在取流中途瞬断（ExoPlayer 报 Source error），自动重试可恢复。
  Future<void> _ensure(int pos, {bool retry = false}) async {
    if (pos < 0 || pos >= _eps.length) return;
    var existing = _players[pos];
    if (existing != null && !retry) return;
    if (existing == null) {
      existing = _Ep();
      _players[pos] = existing;
    }
    final ep = existing; // final 局部变量，闭包内可直接使用
    final token = ++ep.token;
    if (mounted) {
      setState(() {
        ep.loading = true;
        ep.error = null;
      });
    }
    const backoff = [Duration(milliseconds: 600), Duration(milliseconds: 1500)];
    for (var attempt = 0; ; attempt++) {
      VideoPlayerController? c;
      try {
        List<DramaQuality> qualities;
        if (retry && ep.qualities.isNotEmpty) {
          qualities = ep.qualities; // 换清晰度复用已取到的线路
        } else {
          final api = ref.read(sessionProvider).api!;
          qualities = await api.dramaPlay(widget.sid, _eps[pos].vid);
        }
        if (!mounted || token != ep.token || !_players.containsKey(pos)) return;
        if (qualities.isEmpty) throw ApiException('没有可用的播放线路');
        final qIdx = _stickyQuality.clamp(0, qualities.length - 1);
        final base = ref.read(sessionProvider).serverUrl;
        final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
        c = VideoPlayerController.networkUrl(Uri.parse(b + qualities[qIdx].url));
        await c.initialize();
        if (!mounted || token != ep.token || !_players.containsKey(pos)) {
          await c.dispose();
          return;
        }
        // 新控制器完全就绪后再替换旧实例，换清晰度时旧画面播到最后一刻不中断
        final old = ep.ctrl;
        ep.ctrl = c;
        ep.qualities = qualities;
        ep.loading = false;
        ep.error = null;
        ep.ended = false;
        c.addListener(_onTick);
        if (pos == _cur) {
          c.play();
          _armHide();
        }
        old?.removeListener(_onTick);
        await old?.dispose();
        if (mounted) setState(() {});
        return;
      } catch (e) {
        // 清理本轮已创建但未成功初始化的控制器，避免泄漏
        try {
          await c?.dispose();
        } catch (_) {}
        final msg = e is ApiException ? e.message : '加载失败: $e';
        if (attempt < backoff.length && token == ep.token && mounted) {
          await Future.delayed(backoff[attempt]);
          continue;
        }
        if (!mounted || token != ep.token || !_players.containsKey(pos)) return;
        ep.loading = false;
        ep.error = msg;
        if (mounted) setState(() {});
        return;
      }
    }
  }

  // 只监听"播完"事件用于自动切下一集；进度刷新交给底部条的 ListenableBuilder，
  // 控制层隐藏交给定时器 —— 避免每次进度回调都整页 setState 重建造成滑动掉帧。
  void _onTick() {
    if (!mounted) return;
    final ep = _players[_cur];
    if (ep == null) return;
    final c = ep.ctrl;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    // 播完自动滑到下一集（用户正在拖进度条/翻页/刚滑回来时暂不触发）
    final pageScrolling =
        _pageController.hasClients && _pageController.position.isScrollingNotifier.value;
    final recentSwipe = DateTime.now().difference(_swipeResetAt).inMilliseconds < 800;
    if (!v.isPlaying &&
        v.duration > Duration.zero &&
        v.position >= v.duration &&
        !ep.ended &&
        !_dragging &&
        !pageScrolling &&
        !recentSwipe) {
      ep.ended = true;
      _cancelHide();
      if (_cur + 1 < _eps.length) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _onPageChanged(int pos) {
    final old = _cur;
    _cur = pos;
    // 关键：立刻暂停上一页的播放器。否则滑动时两路视频同时解码，
    // CPU/解码器争抢会直接表现为翻页掉帧，且伴音会重叠。
    if (old != pos) _players[old]?.ctrl?.pause();
    _report(_eps[pos].index); // 切集即记录，跨设备可续看
    _touch();
    final ep = _players[pos];
    if (ep != null) {
      final c = ep.ctrl;
      if (c != null && c.value.isInitialized) {
        // 滑回已播完的集 → 从头播
        if (ep.ended && c.value.position >= c.value.duration) {
          ep.ended = false;
          _swipeResetAt = DateTime.now();
          c.seekTo(Duration.zero);
        }
        c.play();
        _armHide();
      }
    }
    if (mounted) setState(() {}); // 顶栏集数 / 底部清晰度切到新的一集
  }

  // 翻页动画结束后再补加载邻集、回收窗口外的播放器（当前 ±1），
  // 避免在滑动动画进行中做 ExoPlayer 初始化/销毁导致掉帧。
  void _onScrollEnd() {
    _ensure(_cur + 1);
    _ensure(_cur - 1);
    final stale = _players.keys.where((k) => k < _cur - 1 || k > _cur + 1).toList();
    for (final k in stale) {
      final dead = _players.remove(k);
      dead?.ctrl?.removeListener(_onTick);
      dead?.ctrl?.dispose();
    }
  }

  void _togglePlay(int pos) {
    _touch();
    final ep = _players[pos];
    if (ep == null) return;
    final c = ep.ctrl;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    if (v.position >= v.duration && v.duration > Duration.zero) {
      // 已播完再点 → 从头播
      ep.ended = false;
      c.seekTo(Duration.zero);
      c.play();
      _armHide();
    } else if (v.isPlaying) {
      c.pause();
      _cancelHide();
    } else {
      c.play();
      _armHide();
    }
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  Future<void> _switchQuality(int idx) async {
    final ep = _players[_cur];
    if (ep == null || idx >= ep.qualities.length || idx == _stickyQuality) return;
    setState(() => _stickyQuality = idx);
    await _ensure(_cur, retry: true);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  void _touch() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _cancelHide();
    _armHide();
  }

  // 播放中 3 秒无操作自动隐藏控制层（暂停状态保持常显）
  void _armHide() {
    _hideTimer ??= Timer(const Duration(seconds: 3), () {
      _hideTimer = null;
      if (!mounted) return;
      final c = _players[_cur]?.ctrl;
      final playing = c != null && c.value.isInitialized && c.value.isPlaying;
      if (_controlsVisible && playing && !_dragging) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  @override
  void dispose() {
    _cancelHide();
    for (final ep in _players.values) {
      ep.ctrl?.removeListener(_onTick);
      ep.ctrl?.dispose();
    }
    _players.clear();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ep = _players[_cur];
    final c = ep?.ctrl;
    final ready = c != null && c.value.isInitialized;
    final qualities = ep?.qualities ?? const <DramaQuality>[];

    // 播放器恒为纯黑背景 → 状态栏用白色图标（与 App 主题无关）
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
          // ---------- 竖向翻页：上滑下一集 / 下滑上一集 ----------
          NotificationListener<ScrollNotification>(
            onNotification: (n) {
              // 动画/手势完全停稳后再做预加载与回收，滑动过程中保持轻负载
              if (n is ScrollEndNotification) _onScrollEnd();
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              allowImplicitScrolling: true, // 缓存相邻页，配合 _ensure 实现预加载
              itemCount: _eps.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) {
                final p = _players[i];
                final pc = p?.ctrl;
                final pReady = pc != null && pc.value.isInitialized;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _togglePlay(i),
                  child: Center(
                    child: pReady
                        ? AspectRatio(
                            aspectRatio: pc.value.aspectRatio,
                            child: VideoPlayer(pc),
                          )
                        : p == null || p.loading
                            ? const CircularProgressIndicator(color: Colors.white70)
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.error_outline,
                                      color: Colors.white54, size: 44),
                                  const SizedBox(height: 12),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 40),
                                    child: Text(
                                      p.error ?? '',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 13.5),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextButton.icon(
                                    onPressed: () => _ensure(i, retry: true),
                                    icon: const Icon(Icons.refresh, size: 18),
                                    label: const Text('重试'),
                                    style: TextButton.styleFrom(
                                        foregroundColor: MoStyle.darkPrimary),
                                  ),
                                ],
                              ),
                  ),
                );
              },
            ),
          ),
          // ---------- 顶部栏：返回 + 标题 + 集数 ----------
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 4, left: 4, right: 16),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(_eps[_cur].index),
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '第${_eps[_cur].index}集',
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ---------- 底部控制：进度条 + 清晰度 ----------
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: EdgeInsets.fromLTRB(
                      16, 26, 16, MediaQuery.of(context).padding.bottom + 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 进度条：只随播放器通知重建这一小块，不整页刷新
                      if (ready)
                        ListenableBuilder(
                          listenable: c,
                          builder: (context, _) {
                            return Row(
                              children: [
                                Text(_fmt(c.value.position),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11)),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2.5,
                                      thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6),
                                      overlayShape: const RoundSliderOverlayShape(
                                          overlayRadius: 12),
                                      inactiveTrackColor: Colors.white24,
                                      activeTrackColor: MoStyle.darkPrimary,
                                      thumbColor: MoStyle.darkPrimary,
                                    ),
                                    child: Slider(
                                      value: c.value.position.inMilliseconds
                                          .clamp(0, c.value.duration.inMilliseconds)
                                          .toDouble(),
                                      max: c.value.duration.inMilliseconds.toDouble(),
                                      onChangeStart: (_) => _dragging = true,
                                      onChangeEnd: (v) {
                                        _dragging = false;
                                        ep!.ended = false; // 手动拖动后重新计时播完判定
                                        c.seekTo(Duration(milliseconds: v.toInt()));
                                      },
                                      onChanged: (v) =>
                                          c.seekTo(Duration(milliseconds: v.toInt())),
                                    ),
                                  ),
                                ),
                                Text(_fmt(c.value.duration),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11)),
                              ],
                            );
                          },
                        ),
                      const SizedBox(height: 6),
                      // 操作行：清晰度（上下集切换已改为滑动翻页）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          for (var i = 0; i < qualities.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _QualityChip(
                                label: qualities[i].name,
                                selected: i == _stickyQuality,
                                onTap: () => _switchQuality(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
        decoration: BoxDecoration(
          color: selected ? MoStyle.darkPrimary : Colors.white24,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}
