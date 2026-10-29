import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../api/kotv_engine_url.dart';
import '../desktop/mini_player_window.dart';
import '../desktop/playback_window.dart';
import '../models/models.dart';
import '../player/danmaku_layer.dart';
import '../player/exo_playback.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/buffer_budget.dart';
import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_player_factory.dart';
import '../player/mpv_opts.dart';
import '../player/play_headers.dart';
import '../player/playback_failover.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/h_scroll.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_fullscreen.dart';
import 'shell.dart';

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.id, this.site = '', this.title = ''});

  final String id;
  final String site;
  final String title;

  /// 详情是否在栈上（含播放中 PopScope.canPop=false）。
  static bool get isOpen => _DetailScreenState._active != null;

  /// 换源等场景：在 pop 详情栈前先硬停播（await），避免后台继续出声。
  static Future<void> prepareLeave() async {
    final active = _DetailScreenState._active;
    if (active == null) return;
    await active._stopHard();
    if (!active.mounted) return;
    // 放开 PopScope，否则随后的 popUntil 会被 canPop:false 拦住。
    active._allowPop = true;
    active.setState(() {});
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  static _DetailScreenState? _active;
  VodDetail? _detail;
  String? _error;
  bool _loading = true;
  int _flagIdx = 0;
  int _epIdx = -1;
  /// 全屏页在 rootNavigator，父 setState 到不了；revision 驱动画面/集数/播放器重建。
  final ValueNotifier<int> _fsRev = ValueNotifier(0);
  int _epPage = 0;
  bool _reversed = false;
  bool _kept = false;
  String _status = '选择剧集开始播放';
  String _playUrl = '';
  String _decodeMode = 'auto';
  /// 设置/用户所选解码；failover 临时翻转只改 [_decodeMode]。
  String _prefDecodeMode = 'auto';
  KotvMpvOpts _mpvOpts = const KotvMpvOpts();
  bool _danmakuOn = false;
  bool _ambientOn = false;
  bool _stableVolumeOn = false;
  String _danmakuApi = '';
  final ValueNotifier<List<DanmakuItem>> _danmakuItems = ValueNotifier(const []);
  AspectSpec _aspect = const AspectSpec(key: 'default', fit: BoxFit.contain);
  int _openingSec = 0;
  int _endingSec = 0;
  String _playerVal = kotvDefaultVodPlayer();
  /// 设置/用户所选播放器；failover 临时切换只改 [_playerVal]。
  String _prefPlayerVal = kotvDefaultVodPlayer();
  /// 设置「自动切换播放器」：auto=开，off=关。
  String _prefPlayerFailover = 'auto';
  bool _miniDesktop = false;
  /// 桌面端「独立播放窗口」：点击播放弹出系统独立窗口，主窗口保持浏览。
  bool _popupPlayer = false;
  /// 当前是否磁力/BT 本地流（状态文案与卡顿语义不同）。
  bool _magnetPlay = false;
  Timer? _btProgressTimer;
  static const _epSize = 20;
  double? _prefSpeed;
  double? _prefVolume;

  Player? _mkPlayer;
  MediaKitPlayback? _mk;
  ExoPlayback? _exo;
  FvpPlayback? _fvp;
  HtmlPlayback? _html;
  ArtPlayback? _art;
  XgPlayback? _xg;
  ZwPlayback? _zw;
  StreamSubscription? _playingSub;
  StreamSubscription? _endedSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription? _bufferingSub;
  KotvPlayback? _wiredNotifyTarget;
  VoidCallback? _playbackNotify;
  bool _openingSeekDone = false;
  bool _stoppedHard = false;
  /// 独立播放窗口是否被用户主动关闭（v8.1：关闭后不再回退内置播放）。
  bool _popupClosed = false;
  /// 硬停完成后再允许真正出栈（配合 [PopScope]）。
  bool _allowPop = false;
  /// 每次 [_playAt] 一代；仅本代真正进入可播（≈STATE_READY）后才允许自动连播。
  int _playGen = 0;
  int _playAtSerial = 0;
  /// 本代是否已消费过「播完→下一集」（completed / 片尾共用，防连跳）。
  int _endConsumedGen = -1;
  /// ≈ TV 在 STATE_READY 后才挂 Clock；开播/解析中为 false。
  bool _playbackLive = false;
  bool _advanceBusy = false;
  DateTime? _sessionStartedAt;

  KotvEmbedBackend get _backend => kotvEmbedBackend(_playerVal);

  /// 当前页内后端：按设置选择 Exo / MPV / FVP / HTML。
  KotvPlayback get _playback {
    switch (_backend) {
      case KotvEmbedBackend.html:
        return _html ??= HtmlPlayback();
      case KotvEmbedBackend.art:
        return _art ??= ArtPlayback();
      case KotvEmbedBackend.xg:
        return _xg ??= XgPlayback();
      case KotvEmbedBackend.zw:
        return _zw ??= ZwPlayback();
      case KotvEmbedBackend.fvp:
        return _fvp ??= FvpPlayback();
      case KotvEmbedBackend.exo:
        return _exo ??= ExoPlayback();
      case KotvEmbedBackend.mpv:
        return _ensureMpv();
    }
  }

  bool get _useMpv => _backend == KotvEmbedBackend.mpv;
  String get _enginePrefix => flutterPlayerLabel(_playerVal);

  bool get _isBuffering => _playUrl.isNotEmpty && _playback.buffering;

  /// 按真实播放器状态刷新文案，避免「播放中」但 00:00/00:00。
  void _syncPlayStatus() {
    if (!mounted || _playUrl.isEmpty) return;
    final p = _playback;
    final prefix = _enginePrefix;
    final magnet = _magnetPlay || _playUrl.contains('/proxy/bt/');
    // 网速只交给 [KotvBufferingOverlay]：写进文案会让每次测速都改字符串，
    // 从而每秒多次 setState 重建整个详情页（全屏播放明显掉帧）。
    final String next;
    if (p.completed && !p.playing) {
      next = '播放结束';
    } else if (p.playing) {
      // MPV 常在 playing=true 时仍报 buffering；已开播优先显示播放中，避免误当成缓冲去切播放器。
      final started = p.position > Duration.zero || p.duration > Duration.zero || p.width > 0;
      if (started) {
        next = magnet ? '$prefix 播放中（磁力）' : '$prefix 播放中';
      } else if (_isBuffering) {
        next = magnet ? '磁力缓冲中…' : '$prefix 缓冲中…';
      } else {
        final startedAt = _sessionStartedAt;
        if (startedAt != null && DateTime.now().difference(startedAt) > const Duration(seconds: 10)) {
          next = magnet ? '磁力无画面（可换源/换节点）' : '$prefix 无画面（可换源/解析）';
        } else {
          next = magnet ? '磁力缓冲中…' : '$prefix 加载中…';
        }
      }
    } else if (magnet && (_isBuffering ||
            !(p.position > Duration.zero || p.duration > Duration.zero || p.width > 0))) {
      next = '磁力缓冲中…';
    } else if (_isBuffering) {
      next = '$prefix 缓冲中…';
    } else {
      final startedAt = _sessionStartedAt;
      final stalled = startedAt != null &&
          DateTime.now().difference(startedAt) > const Duration(seconds: 12) &&
          p.position < const Duration(seconds: 2) &&
          p.width <= 0;
      next = stalled ? '$prefix 无法播放（可换源/解析）' : '已暂停';
    }
    if (_status == next) return;
    setState(() => _status = next);
  }

  MediaKitPlayback _ensureMpv() {
    if (_mk != null) {
      // stopHard 会拆掉 playing 订阅；复用 Player 时必须重新挂上。
      _playingSub ??= _mkPlayer!.stream.playing.listen((_) {
        if (!mounted || _playUrl.isEmpty || !_useMpv) return;
        _markPlaybackLiveIfNeeded();
        _syncPlayStatus();
      });
      _bufferingSub ??= _mkPlayer!.stream.buffering.listen((_) {
        if (!mounted || _playUrl.isEmpty || !_useMpv) return;
        _syncPlayStatus();
      });
      return _mk!;
    }
    final player = kotvCreateMpvPlayer();
    _mkPlayer = player;
    _mk = MediaKitPlayback(player, opts: _mpvOpts.copyWith(decodeMode: _decodeMode));
    _playingSub = player.stream.playing.listen((_) {
      if (!mounted || _playUrl.isEmpty || !_useMpv) return;
      _markPlaybackLiveIfNeeded();
      _syncPlayStatus();
    });
    _bufferingSub = player.stream.buffering.listen((_) {
      if (!mounted || _playUrl.isEmpty || !_useMpv) return;
      _syncPlayStatus();
    });
    // ended/position 由 _playAt 在 open 后再挂，避免创建 Player 时残留 completed 误触
    return _mk!;
  }

  Future<void> _stopInactiveBackends(KotvEmbedBackend keep) async {
    if (keep != KotvEmbedBackend.mpv) {
      try {
        await _mk?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.fvp) {
      try {
        await _fvp?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.exo) {
      try {
        await _exo?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.html) {
      try {
        await _html?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.art) {
      try {
        await _art?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.xg) {
      try {
        await _xg?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.zw) {
      try {
        await _zw?.stop();
      } catch (_) {}
    }
  }

  /// 换集/换源：解析可能要数秒，必须先停当前播放，否则上一集继续出声。
  Future<void> _stopAllBackends() async {
    await Future.wait<void>([
      () async {
        try {
          await _mk?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _fvp?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _exo?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _html?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _art?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _xg?.stop();
        } catch (_) {}
      }(),
      () async {
        try {
          await _zw?.stop();
        } catch (_) {}
      }(),
    ]);
  }

  @override
  void initState() {
    super.initState();
    _active = this;
    kotvRegisterQuitHook(_prepareQuit);
    // 独立播放窗口关闭 / 出错时复位本页状态。
    PlaybackWindow.onPlaybackClosed = () {
      if (!mounted) return;
      // 用户主动关闭 → 后续在途播放请求直接停止，不转内置；
      // 异常退出 → closedByUser=false，仍可回退内置兜底。
      _popupClosed = PlaybackWindow.closedByUser;
      setState(() {
        _playUrl = '';
        _status = '已停止';
      });
    };
    PlaybackWindow.onPlaybackError = (msg) {
      if (!mounted) return;
      setState(() {
        _playUrl = '';
        _status = '独立窗口播放失败：$msg';
      });
    };
    // 独立窗口内点选集：由主窗口解析新集 URL 并切集。
    PlaybackWindow.onSwitchEpisode = (idx) {
      // 播放器已关闭（竞态中残留请求）：忽略，避免关闭后被重新拉起/转内置。
      if (!mounted || !PlaybackWindow.open) return;
      if (idx < 0 || idx >= _eps.length) return;
      unawaited(_playAt(idx));
    };
    // 独立窗口内点"解析"：主窗口选解析器后重播当前集（回发 play）。
    PlaybackWindow.onParse = () {
      if (!mounted || !PlaybackWindow.open) return;
      unawaited(_pickParse());
    };
    // 独立窗口内点"刷新"：主窗口重新解析当前集。
    PlaybackWindow.onRefresh = () {
      if (!mounted || !PlaybackWindow.open) return;
      if (_epIdx >= 0) unawaited(_playAt(_epIdx));
    };
    // 独立窗口内调整片头/片尾偏移：主窗口同步状态并持久化，
    // 后续切集/重开窗口时作为初始值下发。
    PlaybackWindow.onOffsets = (open, end) {
      if (!mounted) return;
      setState(() {
        _openingSec = open.clamp(0, 3600);
        _endingSec = end.clamp(0, 3600);
      });
      final id = _detail?.id.isNotEmpty == true ? _detail!.id : widget.id;
      final site =
          _detail?.site.isNotEmpty == true ? _detail!.site : widget.site;
      unawaited(LocalPlayOffsets.set(id, site, _openingSec, _endingSec));
    };
    // v8：独立窗口内点"换源"：idx==null 请求线路列表（回发 /sources），
    // idx!=null 为播放器已选定线路 → 切线路并走 popup 分支回发 play。
    PlaybackWindow.onSwitchSource = (idx) {
      // 播放器已关闭：忽略（idx==null 的线路请求同理）。
      if (!mounted || !PlaybackWindow.open) return;
      final d = _detail;
      if (d == null || d.flags.isEmpty) return;
      if (idx == null) {
        unawaited(PlaybackWindow.sendSources(
            d.flags.map((f) => f.show).toList(), _flagIdx));
        return;
      }
      if (idx < 0 || idx >= d.flags.length) return;
      _selectFlag(idx);
    };
    _load();
  }

  Future<void> _prepareQuit() async {
    try {
      await _stopHard();
    } catch (_) {}
    final mkPlayer = _mkPlayer;
    _mkPlayer = null;
    try {
      _mk?.dispose();
    } catch (_) {}
    _mk = null;
    await kotvDisposeMpvPlayer(mkPlayer);
  }

  /// await stop，等原生停住（Win7 上 unawaited stop 不够）。
  /// 不要 pause：pause 会粘在播放器上，下次 open 只出一帧。
  Future<void> _stopHard() async {
    _playbackLive = false;
    _advanceBusy = false;
    _playGen++;
    _endConsumedGen = _playGen;
    // 抬起播世代：返回/停播时丢弃进行中的 play/磁力 Fetch 结果
    _playAtSerial++;
    _sessionStartedAt = null;
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _unwirePlaybackNotify();
    _playingSub = null;
    _endedSub = null;
    _posSub = null;
    _bufferingSub = null;
    _playUrl = '';
    _magnetPlay = false;
    _stopBtProgressPoll();
    // Source.stop：离开详情硬杀运行时 + 停磁力
    unawaited(ref.read(apiProvider).cancelPending(hard: true, thunder: true));

    Future<void> hardStop(KotvPlayback? p) async {
      if (p == null) return;
      try {
        await p.stop();
      } catch (_) {}
    }

    await Future.wait<void>([
      hardStop(_fvp),
      hardStop(_mk),
      hardStop(_exo),
      hardStop(_html),
      hardStop(_art),
      hardStop(_xg),
      hardStop(_zw),
    ]);
    _stoppedHard = true;
  }

  Future<void> _leavePage({VoidCallback? afterPop}) async {
    if (_miniDesktop) {
      try {
        await _exitMini();
      } catch (_) {}
    }
    await _stopHard();
    if (!mounted) return;
    _allowPop = true;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).pop();
    afterPop?.call();
  }

  void _wireEnded(KotvPlayback p) {
    _endedSub?.cancel();
    _endedSub = p.completedStream.listen((done) {
      if (!done || !mounted) return;
      unawaited(_onPlaybackEnded());
    });
  }

  void _wirePosition(KotvPlayback p) {
    _posSub?.cancel();
    _posSub = p.positionStream.listen(_onPositionTick);
  }

  void _unwirePlaybackNotify() {
    final t = _wiredNotifyTarget;
    final cb = _playbackNotify;
    if (t != null && cb != null) {
      try {
        t.removeListener(cb);
      } catch (_) {}
    }
    _wiredNotifyTarget = null;
    _playbackNotify = null;
  }

  void _wirePlaybackNotify(KotvPlayback p) {
    _unwirePlaybackNotify();
    _playbackNotify = () {
      if (!mounted || _playUrl.isEmpty) return;
      _syncPlayStatus();
    };
    _wiredNotifyTarget = p;
    p.addListener(_playbackNotify!);
  }

  /// STATE_READY：本集真正开播后才允许片尾/completed 自动连播。
  /// 仅凭 width>0 不足（解码器探头即可有尺寸但黑屏），须进度真正前进。
  void _markPlaybackLiveIfNeeded() {
    if (_playUrl.isEmpty || _playbackLive) return;
    final p = _playback;
    if (p.completed) return;
    final pos = p.position.inMilliseconds;
    final dur = p.duration.inMilliseconds;
    // 上一集残留的近片尾进度绝不当作 READY
    if (dur > 15000 && pos >= dur - 5000 && pos > 8000) return;
    final progressed = pos >= 2500 || (dur > 0 && pos >= 1200 && p.playing);
    if (progressed && (p.playing || pos >= 2500)) {
      _playbackLive = true;
    }
  }

  /// playbackEnded / onTimeChanged→nextEpisode：每集只前进一次。
  Future<void> _advanceToNextEpisode() async {
    if (!mounted || _advanceBusy) return;
    if (!_playbackLive) return;
    if (_endConsumedGen == _playGen) return;
    final eps = _eps;
    final next = _epIdx + 1;
    if (next < 0 || next >= eps.length) {
      if (mounted) setState(() => _status = '播放结束');
      _endConsumedGen = _playGen;
      _playbackLive = false;
      return;
    }
    _endConsumedGen = _playGen;
    _playbackLive = false;
    _advanceBusy = true;
    if (mounted) setState(() => _status = '自动播放下一集…');
    try {
      await _playAt(next);
    } finally {
      _advanceBusy = false;
    }
  }

  /// 片头起播跳过；片尾 `ending+position>=duration` 切下一集。
  /// Clock 仅在 READY（[_playbackLive]）后生效，避免解析/换集中连跳。
  void _onPositionTick(Duration pos) {
    if (_playUrl.isEmpty || !mounted) return;
    _syncPlayStatus();
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final dur = _playback.duration;
    if (dur.inMilliseconds <= 0) return;
    final openMs = _openingSec * 1000;
    final endMs = _endingSec * 1000;
    if (openMs > 0 && !_openingSeekDone) {
      if (pos.inMilliseconds + 800 < openMs) {
        _openingSeekDone = true;
        unawaited(_playback.seek(Duration(milliseconds: openMs)));
        return;
      }
      if (pos.inMilliseconds >= openMs) _openingSeekDone = true;
    }
    // ending > 0 && ending + position >= duration
    if (endMs > 0 && pos.inMilliseconds + endMs >= dur.inMilliseconds) {
      _openingSeekDone = false;
      unawaited(_advanceToNextEpisode());
    }
  }

  Future<void> _onPlaybackEnded() async {
    if (!mounted) return;
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final pos = _playback.position.inMilliseconds;
    final dur = _playback.duration.inMilliseconds;
    // 黑屏/假结束：几乎没播过就不自动下一集
    if (pos < 8000) return;
    if (dur > 0) {
      final nearEnd = pos + 8000 >= dur || pos >= (dur * 0.92).round();
      if (!nearEnd) return;
    }
    await _advanceToNextEpisode();
  }

  @override
  void dispose() {
    kotvUnregisterQuitHook(_prepareQuit);
    if (_active == this) _active = null;
    // 离开详情：回传扫码取消并打断 JAR；不要再 nav.pop（本页正在出栈）。
    final api = ref.read(apiProvider);
    unawaited(PostMsgHost.instance?.cancelAll(reply: true, popDialog: false) ?? Future<void>.value());
    unawaited(api.cancelPending(hard: true, thunder: true));
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _unwirePlaybackNotify();
    _stopBtProgressPoll();
    _danmakuItems.dispose();
    _fsRev.dispose();
    // 正常路径已在 [_stopHard] 里 await pause/stop；此处兜底再停一次再释放。
    if (!_stoppedHard) {
      unawaited(_fvp?.stop() ?? Future<void>.value());
      unawaited(_exo?.stop() ?? Future<void>.value());
      unawaited(_html?.stop() ?? Future<void>.value());
      unawaited(_art?.stop() ?? Future<void>.value());
      unawaited(_xg?.stop() ?? Future<void>.value());
      unawaited(_zw?.stop() ?? Future<void>.value());
    }
    _fvp?.dispose();
    _mk?.dispose();
    _exo?.dispose();
    _html?.dispose();
    _art?.dispose();
    _xg?.dispose();
    _zw?.dispose();
    final mkPlayer = _mkPlayer;
    _mkPlayer = null;
    unawaited(kotvDisposeMpvPlayer(mkPlayer));
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(apiProvider).detail(id: widget.id, site: widget.site);
      final vod = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
      final kept = await LocalCollect.isKept(
        vod.id.isNotEmpty ? vod.id : widget.id,
        vod.site.isNotEmpty ? vod.site : widget.site,
      );
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final decode = '${settings['playerDecode'] ?? 'auto'}';
        if (decode.isNotEmpty) {
          _decodeMode = decode;
          _prefDecodeMode = decode;
        }
        _mpvOpts = KotvMpvOpts.fromSettings(settings, decodeMode: _decodeMode);
        _danmakuOn = '${settings['danmaku'] ?? ''}'.toLowerCase() == 'true';
        _ambientOn = '${settings['playerAmbient'] ?? ''}'.toLowerCase() == 'true';
        _stableVolumeOn = '${settings['playerStableVolume'] ?? ''}'.toLowerCase() == 'true';
        _danmakuApi = '${settings['danmakuApi'] ?? ''}';
        final scale = '${settings['playerScale'] ?? 'default'}';
        _aspect = _aspectFromScale(scale);
        var playerVal = '${settings['player'] ?? kotvDefaultVodPlayer()}'.trim();
        if (playerVal.isEmpty) {
          playerVal = kotvDefaultVodPlayer();
        }
        _playerVal = kotvClampPlayerVal(playerVal, live: false);
        _prefPlayerVal = _playerVal;
        final failoverMode = '${settings['playerFailover'] ?? 'auto'}'.trim().toLowerCase();
        _prefPlayerFailover = (failoverMode == 'off' || failoverMode == 'false') ? 'off' : 'auto';
        // 桌面端独立播放窗口：v8.2 起桌面端强制独立窗口（不需要内置播放），
        // 设置项 popupPlayer 仅在移动端有意义。
        final popupRaw = '${settings['popupPlayer'] ?? ''}'.trim();
        _popupPlayer = kotvIsDesktop() || popupRaw.toLowerCase() == 'true';
        // 绝不在进详情时创建 Player：libmpv 初始化 + VideoController 附着会卡死 UI / 手机闪退。
        // 音量/倍速等偏好先记下，真正 [_playAt] open 后再套。
        _prefSpeed = double.tryParse('${settings['playerSpeed'] ?? ''}');
        _prefVolume = double.tryParse('${settings['playerVolume'] ?? ''}');
        kotvApplyPlayUaSetting('${settings['ua'] ?? ''}');
        unawaited(KotvBufferBudget.warm());
      } catch (_) {}
      setState(() {
        _detail = vod;
        _kept = kept;
        _loading = false;
      });
      final id = vod.id.isNotEmpty ? vod.id : widget.id;
      final site = vod.site.isNotEmpty ? vod.site : widget.site;
      final off = await LocalPlayOffsets.get(id, site);
      if (mounted) {
        setState(() {
          _openingSec = off.$1;
          _endingSec = off.$2;
        });
      }
      final needExpand = data['magnet'] == true || _detailHasMagnet(vod);
      if (needExpand && mounted) {
        unawaited(_expandMagnet(id: id, site: site));
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  bool _detailHasMagnet(VodDetail vod) {
    for (final f in vod.flags) {
      for (final ep in f.episodes) {
        final u = ep.url.trim().toLowerCase();
        if (u.startsWith('magnet:') || u.startsWith('thunder:') || u.startsWith('ed2k:') || u.contains('.torrent')) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _expandMagnet({required String id, required String site}) async {
    if (!mounted) return;
    final cur = _detail;
    if (cur == null) return;
    // 已在播非磁力：展开只更新列表，不抢状态栏、不清选集
    final playingNonMagnet = _playUrl.isNotEmpty && !_magnetPlay;
    if (!playingNonMagnet) {
      setState(() => _status = '正在展开磁力文件…');
    }
    _startBtProgressPoll(expanding: true);
    try {
      final flagsPayload = cur.flags
          .map((f) => {
                'flag': f.flag,
                'show': f.show,
                'episodes': f.episodes.map((e) => {'name': e.name, 'url': e.url}).toList(),
              })
          .toList();
      final data = await ref.read(apiProvider).detailExpand(id: id, site: site, flags: flagsPayload);
      if (!mounted) return;
      if (data['expanded'] == true && data['vod'] is Map) {
        final expanded = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
        // 只替换线路/剧集，保留当前详情其它字段，避免整页重建冲掉扫码等弹窗。
        setState(() {
          _detail = cur.withFlags(expanded.flags);
          if (_flagIdx >= expanded.flags.length) _flagIdx = 0;
          _epPage = 0;
          if (!playingNonMagnet && _epIdx >= 0) _epIdx = -1;
          if (!playingNonMagnet) {
            _status = '磁力文件已展开，可选集播放';
          }
        });
      } else if (mounted && !playingNonMagnet) {
        setState(() => _status = '选择剧集开始播放');
      }
    } catch (e) {
      if (mounted && !playingNonMagnet) setState(() => _status = '磁力展开失败，仍可点原链起播');
    } finally {
      _stopBtProgressPoll();
    }
  }

  void _startBtProgressPoll({bool expanding = false}) {
    _btProgressTimer?.cancel();
    _btProgressTimer = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (!mounted) return;
      try {
        final p = await ref.read(apiProvider).btProgress();
        final msg = '${p['message'] ?? ''}'.trim();
        if (msg.isEmpty || !mounted) return;
        // 展开过程中若已在播非磁力，绝不抢状态栏。
        if (expanding && _playUrl.isNotEmpty && !_magnetPlay) return;
        // 「已取消」来自 thunder.Stop；非磁力播放时忽略，避免误显示。
        if (msg == '已取消' && !_magnetPlay) return;
        // 展开/起播过程中用引擎进度覆盖状态；已进入正式播放文案则不抢。
        if (_status.contains('播放中') && !_status.contains('磁力缓冲')) return;
        if (_status == '已暂停' || _status == '播放结束' || _status.startsWith('播放失败')) return;
        if (expanding || _magnetPlay || _status.contains('磁力') || _status.contains('解析') || _status.contains('缓冲') || _status.contains('加载')) {
          if (_status != msg) setState(() => _status = msg);
        }
      } catch (_) {}
    });
  }

  void _stopBtProgressPoll() {
    _btProgressTimer?.cancel();
    _btProgressTimer = null;
  }

  List<EpisodeItem> get _eps {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return const [];
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final list = List<EpisodeItem>.from(flag.episodes);
    return _reversed ? list.reversed.toList() : list;
  }

  String? _currentEpisodeName() {
    final eps = _eps;
    if (_epIdx >= 0 && _epIdx < eps.length) return eps[_epIdx].name;
    return null;
  }

  /// 对齐 TV Flag.find：按集名 / 集号匹配，不按「第 N 个」。
  int _matchEpisodeIndex(List<EpisodeItem> eps, String remarks) {
    if (eps.isEmpty) return -1;
    if (eps.length == 1) return 0;
    final want = remarks.trim();
    if (want.isEmpty) return -1;
    final wantNum = _episodeNumber(want);
    var best = -1;
    var bestScore = 0;
    for (var i = 0; i < eps.length; i++) {
      final name = eps[i].name.trim();
      var score = 0;
      if (name.toLowerCase() == want.toLowerCase()) {
        score = 100;
      } else if (wantNum != -1 && _episodeNumber(name) == wantNum) {
        score = 80;
      } else if (wantNum == -1 && want.length >= 2 && name.toLowerCase().contains(want.toLowerCase())) {
        score = 70;
      } else if (wantNum == -1 && name.length >= 2 && want.toLowerCase().contains(name.toLowerCase())) {
        score = 60;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best >= 0) return best;
    if (_epIdx >= 0 && _epIdx < eps.length) return _epIdx;
    return -1;
  }

  static int _episodeNumber(String name) {
    final m = RegExp(r'(\d+)').firstMatch(name);
    if (m == null) return -1;
    return int.tryParse(m.group(1) ?? '') ?? -1;
  }

  /// 换线路：立刻切列表并按集名保留当前集（对齐 TV seamless）。
  void _selectFlag(int i, {bool autoPlay = true}) {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    if (i < 0 || i >= d.flags.length) return;
    final remarks = _currentEpisodeName() ?? '';
    _flagIdx = i;
    final eps = _eps;
    final idx = _matchEpisodeIndex(eps, remarks);
    if (!mounted) return;
    setState(() {
      _flagIdx = i;
      _epIdx = idx;
      _epPage = idx >= 0 ? idx ~/ _epSize : 0;
      _status = '已切换线路: ${d.flags[i].show}';
    });
    if (autoPlay && idx >= 0) unawaited(_playAt(idx));
  }

  AspectSpec _aspectFromScale(String scale) {
    switch (scale) {
      case 'fill':
        return const AspectSpec(key: 'fill', fit: BoxFit.fill);
      case 'zoom':
        return const AspectSpec(key: 'zoom', fit: BoxFit.cover);
      case '16:9':
        return const AspectSpec(key: '16:9', fit: BoxFit.fill, ratio: 16 / 9);
      case '4:3':
        return const AspectSpec(key: '4:3', fit: BoxFit.fill, ratio: 4 / 3);
      default:
        return const AspectSpec(key: 'default', fit: BoxFit.contain);
    }
  }

  Future<void> _applyStableVolume(KotvPlayback p, bool on) async {
    if (p is MediaKitPlayback) {
      try {
        await (p.player.platform as dynamic).setProperty('af', on ? 'loudnorm' : '');
      } catch (_) {
        try {
          await (p.player.platform as dynamic).setProperty('af', on ? 'dynaudnorm' : '');
        } catch (_) {}
      }
      return;
    }
    
  }

  Future<void> _loadDanmakuForEpisode({
    required String playDanmaku,
    required String name,
    required String episode,
  }) async {
    _danmakuItems.value = const [];
    if (playDanmaku.trim().isEmpty && _danmakuApi.trim().isEmpty) return;
    try {
      List<DanmakuItem> items = const [];
      if (playDanmaku.trim().isNotEmpty) {
        items = await DanmakuLoader.loadUrl(playDanmaku);
      }
      if (items.isEmpty && _danmakuApi.trim().isNotEmpty) {
        items = await DanmakuLoader.loadApi(_danmakuApi, name: name, episode: episode);
      }
      if (!mounted) return;
      _danmakuItems.value = items;
    } catch (_) {
      if (mounted) _danmakuItems.value = const [];
    }
  }

  Future<void> _playAt(int epIdx, {bool fullscreen = false}) async {
    // 新一轮播放发起：清除上一轮"用户已关闭播放窗口"标志。
    // 若本代执行期间用户又关闭了播放窗口，onPlaybackClosed 会重新置位。
    _popupClosed = false;
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final eps = _eps;
    if (epIdx < 0 || epIdx >= eps.length) return;
    final ep = eps[epIdx];
    _stoppedHard = false;
    // 换集：抬世代，关掉 READY/连播（BUFFERING 时 Clock=null）
    final gen = ++_playGen;
    final serial = ++_playAtSerial;
    _playbackLive = false;
    _sessionStartedAt = null;
    _openingSeekDone = false;
    _endedSub?.cancel();
    _endedSub = null;
    _posSub?.cancel();
    _posSub = null;
    final epLooksMagnet = RegExp(r'^(magnet|thunder|ed2k):', caseSensitive: false).hasMatch(ep.url.trim()) ||
        ep.url.toLowerCase().contains('.torrent') ||
        ep.url.contains('/proxy/bt/') ||
        ep.url.toLowerCase().startsWith('magnet://local');
    // 立刻高亮（对齐 TV）：不要等停播/解析，否则 PC 要点 1–2 秒按钮才变色。
    if (mounted) {
      setState(() {
        _epIdx = epIdx;
        _epPage = epIdx ~/ _epSize;
        _magnetPlay = epLooksMagnet;
        _status = epLooksMagnet
            ? '磁力解析中…'
            : (_epLooksDirectPlayUrl(ep.url) ? '换集中…' : '解析中…');
      });
    }
    _syncFullscreen();
    // 解析/拉流可能要数秒：先停播，避免上一集在后台继续出声。
    await _stopAllBackends();
    if (serial != _playAtSerial || !mounted) return;
    // 先 await 软取消上一集，再 play。unawaited 会与本次 play 竞态：
    // SoftCancel 抬 epoch → JS/JAR 立刻报「脚本调用已中断」。
    await ref.read(apiProvider).cancelPending(
          hard: false,
          thunder: _magnetPlay || epLooksMagnet,
        );
    if (serial != _playAtSerial || !mounted) return;
    if (mounted) {
      setState(() {
        _playUrl = '';
        _magnetPlay = epLooksMagnet;
      });
    }
    _syncFullscreen();
    if (epLooksMagnet) _startBtProgressPoll();
    try {
      Map<String, dynamic> data;
      try {
        data = await ref.read(apiProvider).play(
              url: ep.url,
              site: d.site.isNotEmpty ? d.site : widget.site,
              id: widget.id,
              flag: flag.flag,
            );
      } catch (e) {
        // 从后台回来常见引擎僵死：Connection closed / refused。先拉起再重试一次。
        if (!_isLocalEngineConnError(e)) rethrow;
        final ok = await ref.read(engineLauncherProvider).recoverIfNeeded();
        if (!ok || serial != _playAtSerial || !mounted) rethrow;
        data = await ref.read(apiProvider).play(
              url: ep.url,
              site: d.site.isNotEmpty ? d.site : widget.site,
              id: widget.id,
              flag: flag.flag,
            );
      }
      if (serial != _playAtSerial || !mounted) return;
      final playUrl = kotvRewriteEngineLocalUrl(
        '${data['url'] ?? ''}',
        ref.read(apiProvider).baseUrl,
      );
      if (playUrl.isEmpty) throw Exception('空播放地址');
      final mediaUrl = kotvRewriteEngineLocalUrl(
        '${data['media'] ?? ''}',
        ref.read(apiProvider).baseUrl,
      );
      final headers = <String, String>{
        for (final e in Map<String, dynamic>.from((data['headers'] as Map?) ?? const {}).entries)
          if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
      };
      final magnet = data['magnet'] == true || playUrl.contains('/proxy/bt/') || epLooksMagnet;
      _magnetPlay = magnet;
      final drmRaw = data['drm'];
      final drm = drmRaw is Map
          ? Map<String, dynamic>.from(drmRaw)
          : null;
      final hasDrm = drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty;
      await LocalHistory.push(VodItem(
        id: d.id.isNotEmpty ? d.id : widget.id,
        name: d.name,
        pic: d.pic,
        site: d.site,
        remarks: ep.name,
      ));
      // 起播再读一次：设置页改播放器/软硬解/自动切换后，详情页可能还开着。
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final fo = '${settings['playerFailover'] ?? ''}'.trim();
        if (fo.isNotEmpty) {
          _prefPlayerFailover = KotvPlaybackFailover.enabledFromSetting(fo) ? 'auto' : 'off';
        }
        final pv = '${settings['player'] ?? ''}'.trim();
        if (pv.isNotEmpty) {
          _prefPlayerVal = kotvClampPlayerVal(pv, live: false);
        }
        final decode = '${settings['playerDecode'] ?? ''}'.trim();
        if (decode.isNotEmpty) {
          _prefDecodeMode = decode;
        }
      } catch (_) {}
      // 有 DRM 强制 Exo（MPV/FVP 不解 Widevine）
      final startPlayer = (hasDrm && kotvIsAndroid())
          ? 'innie#exo'
          : _prefPlayerVal;
      final failover = KotvPlaybackFailover(
        playerVal: startPlayer,
        decodeMode: _prefDecodeMode,
        lockExoForDrm: hasDrm && kotvIsAndroid(),
        enabled: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
      );
      // 独立播放窗口模式（桌面端）：解析已完成，交给独立播放器起播。
      // v8.2：桌面端一律独立窗口（不需要内置播放），不再回退内嵌 MPV。
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        await _stopInactiveBackends(_backend);
        if (serial != _playAtSerial || !mounted) return;
        final cached = playUrl.contains('/proxy/cached_m3u8');
        final proxied = playUrl.contains('/proxy/play');
        final popHeaders =
            (headers.isNotEmpty && !cached && !proxied) ? headers : const <String, String>{};
        setState(() {
          _playUrl = '';
          _playerVal = startPlayer;
          _decodeMode = _prefDecodeMode;
          _status = '独立窗口播放中';
        });
        _syncFullscreen();
        final ok = await PlaybackWindow.play(PlaybackWindowArgs(
          vodName: d.name,
          title: ep.name,
          epIdx: epIdx,
          episodes: _eps.map((e) => e.name).toList(),
          playUrl: playUrl,
          headers: popHeaders,
          decodeMode: _prefDecodeMode,
          fit: _aspect.fit.name,
          volume: _prefVolume,
          rate: _prefSpeed,
          openingSec: _openingSec,
          endingSec: _endingSec,
        ));
        if (!ok) {
          // v8.2：不需要内置播放——独立播放器不可用/失败不再回退内嵌播放，
          // 直接停止并提示（播放器崩溃等异常时同样如此）。
          if (mounted) {
            setState(() {
              _playUrl = '';
              _status = _popupClosed ? '已停止' : '独立播放器不可用，播放失败';
            });
          }
          return;
        }
        return;
      }
      Object? lastOpenError;
      var opened = false;
      for (var attempt = 0; attempt < 8; attempt++) {
        if (serial != _playAtSerial || !mounted) return;
        failover.markAttempt();
        _playerVal = failover.playerVal;
        _decodeMode = failover.decodeMode;
        await _stopInactiveBackends(_backend);
        if (serial != _playAtSerial || !mounted) return;
        final pb = _playback;
        await pb.setDecodeMode(failover.decodeMode);
        // Exo：优先直连 media+headers；cached_m3u8 仍走代理且不带远端头
        var openUrl = playUrl;
        Map<String, String>? openHeaders = headers.isEmpty ? null : headers;
        if (_backend == KotvEmbedBackend.exo || hasDrm) {
          final cached = playUrl.contains('/proxy/cached_m3u8');
          final proxied = playUrl.contains('/proxy/play');
          if (!cached &&
              !magnet &&
              mediaUrl.startsWith('http') &&
              headers.isNotEmpty) {
            openUrl = mediaUrl;
            openHeaders = headers;
          } else if (cached || proxied) {
            openHeaders = null;
          }
        }
        // 先挂播放器视图再 open（Texture / 平台视图需进树；全屏也靠 _fsRev 挂上）。
        setState(() {
          _playUrl = playUrl;
          _playerVal = failover.playerVal;
          _decodeMode = failover.decodeMode;
          _status = magnet ? '磁力缓冲中…' : '$_enginePrefix 加载中…';
        });
        _syncFullscreen();
        await WidgetsBinding.instance.endOfFrame;
        if (serial != _playAtSerial || !mounted) return;
        try {
          // 起播缓冲由守卫无限等待；仅黑屏/视源失败抛 SilentVideo 才 failover。
          // 勿再套墙钟 timeout：慢源会被误切播放器。
          await pb.open(openUrl, headers: openHeaders, drm: hasDrm ? drm : null);
          try {
            await _playback.play();
          } catch (_) {}
          opened = true;
          break;
        } on KotvSilentVideoException catch (e) {
          lastOpenError = e;
          if (!failover.enabled) {
            // 关闭自动切换：不换引擎、不判失败，继续当前播放器。
            opened = true;
            break;
          }
        }
        final step = failover.nextStep();
        if (step == null) break;
        if (!mounted || serial != _playAtSerial) return;
        setState(() {
          _playerVal = step.playerVal;
          _decodeMode = step.decodeMode;
          _status = step.status;
        });
        _syncFullscreen();
        try {
          await pb.stop();
        } catch (_) {}
      }
      if (!opened) {
        throw lastOpenError ?? const KotvSilentVideoException();
      }
      if (serial != _playAtSerial || !mounted) return;
      // 起播后再套偏好：loudnorm 在 open 前同步套极易卡死主线程。
      final speed = _prefSpeed;
      if (speed != null && speed > 0) {
        try {
          await _playback.setRate(speed);
        } catch (_) {}
      }
      final vol = _prefVolume;
      if (vol != null) {
        try {
          await _playback.setVolume(vol.clamp(0, 100));
        } catch (_) {}
      }
      if (_stableVolumeOn) {
        // 推迟到首帧后，避免与 demuxer/硬解初始化抢同一条 native 路径。
        unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () async {
          if (!mounted || serial != _playAtSerial) return;
          try {
            await _applyStableVolume(_playback, true);
          } catch (_) {}
        }));
      }
      if (!mounted) return;
      unawaited(_loadDanmakuForEpisode(
        playDanmaku: '${data['danmaku'] ?? ''}',
        name: d.name,
        episode: ep.name,
      ));
      // 仍未 READY：等进度回调 _markPlaybackLiveIfNeeded（STATE_READY 才挂 Clock）
      _playbackLive = false;
      _sessionStartedAt = DateTime.now();
      _openingSeekDone = false;
      if (gen == _playGen) {
        _wireEnded(_playback);
        _wirePosition(_playback);
        _wirePlaybackNotify(_playback);
      }
      _stopBtProgressPoll();
      _syncPlayStatus();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: '${d.name} · ${ep.name}', url: playUrl);
      if (fullscreen && mounted) {
        await _enterFullscreen();
      }
    } catch (e) {
      if (serial != _playAtSerial) return;
      _stopBtProgressPoll();
      _playbackLive = false;
      _sessionStartedAt = null;
      setState(() {
        _playUrl = '';
        _status = _friendlyPlayError(
          e,
          triedSwitch: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
        );
      });
      _syncFullscreen();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _friendlyPlayError(
                e,
                triedSwitch: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
              ),
            ),
          ),
        );
      }
    }
  }

  /// 对齐 TV Sniffer.isVideoFormat 的常见直链：这类换集不显示「解析」浮层。
  bool _epLooksDirectPlayUrl(String raw) {
    final u = raw.trim().toLowerCase();
    if (u.isEmpty) return false;
    if (u.startsWith('rtmp:')) return true;
    if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
    if (u.contains('url=http') || u.contains('v=http') || u.contains('.html')) return false;
    const marks = ['.m3u8', '.mp4', '.mkv', '.flv', '.mpd', '.mp3', '.m4a', '.aac', 'video/tos'];
    for (final m in marks) {
      if (u.contains(m)) return true;
    }
    return false;
  }

  /// 折叠「播放失败: 解析失败: 解析失败: …」这类层层包装。
  String _friendlyPlayError(Object e, {bool triedSwitch = true}) {
    if (e is KotvSilentVideoException) {
      final m = e.message.trim();
      if (m.contains('视频源')) {
        return triedSwitch ? '播放失败: 无可用视频源（已尝试修复并切换播放器）' : '播放失败: 无可用视频源';
      }
      if (m.contains('进度停滞')) {
        return triedSwitch ? '播放失败: 播放中进度停滞（已尝试切换播放器）' : '播放失败: 播放中进度停滞';
      }
      return triedSwitch ? '播放失败: 无画面（已尝试可用播放器）' : '播放失败: 无画面';
    }
    var s = '$e';
    s = s.replaceFirst(RegExp(r'^(Exception|KotvApiException):\s*'), '');
    while (s.contains('解析失败: 解析失败:')) {
      s = s.replaceAll('解析失败: 解析失败:', '解析失败:');
    }
    while (s.contains('播放失败: 播放失败:')) {
      s = s.replaceAll('播放失败: 播放失败:', '播放失败:');
    }
    if (s.startsWith('播放失败:')) return s;
    if (s.startsWith('解析失败:')) return '播放失败: ${s.substring('解析失败:'.length).trimLeft()}';
    return '播放失败: $s';
  }

  bool _isLocalEngineConnError(Object e) {
    final s = '$e';
    return s.contains('Connection closed') ||
        s.contains('Connection refused') ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup') ||
        s.contains('TimeoutException') ||
        s.contains('Broken pipe');
  }

  /// 全屏在 rootNavigator，详情 setState 到不了，靠 revision 把当前播放器/集数推上去。
  void _syncFullscreen() {
    if (!mounted) return;
    _fsRev.value++;
  }

  Future<void> _enterFullscreen([KotvDesktopFullscreenKind desktopFs = KotvDesktopFullscreenKind.window]) async {
    final d = _detail;
    if (d == null || !mounted) return;
    if (_miniDesktop) await _exitMini();
    if (!mounted) return;
    final api = ref.read(apiProvider);
    final id = d.id.isNotEmpty ? d.id : widget.id;
    final site = d.site.isNotEmpty ? d.site : widget.site;
    _syncFullscreen();

    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => ValueListenableBuilder<int>(
          valueListenable: _fsRev,
          builder: (context, _, __) {
            final vod = _detail;
            if (vod == null) return const ColoredBox(color: Colors.black);
            final eps = _eps;
            final epIdx = _epIdx;
            final title = '${vod.name}${epIdx >= 0 && epIdx < eps.length ? ' · ${eps[epIdx].name}' : ''}';
            return ValueListenableBuilder<List<DanmakuItem>>(
              valueListenable: _danmakuItems,
              builder: (context, danmakuItems, _) => DetailFullscreenPage(
                playback: _playback,
                vodName: vod.name,
                title: title,
                episodes: eps.map((e) => e.name).toList(),
                epIdx: epIdx,
                playUrl: _playUrl,
                decodeMode: _decodeMode,
                aspect: _aspect,
                danmakuOn: _danmakuOn,
                danmakuItems: danmakuItems,
                ambientOn: _ambientOn,
                stableVolumeOn: _stableVolumeOn,
                keepLabel: _kept ? '取消收藏' : '收藏',
                offsetId: id,
                offsetSite: site,
                openingSec: _openingSec,
                endingSec: _endingSec,
                desktopFullscreen: desktopFs,
                onOffsetsChanged: (open, end) {
                  if (!mounted) return;
                  setState(() {
                    _openingSec = open;
                    _endingSec = end;
                  });
                },
                onSelectEp: (i) => _playAt(i),
                onNext: () => _playAt(_epIdx + 1),
                onPrev: () => _playAt(_epIdx - 1),
                onDecodeChanged: (mode) {
                  if (mounted) {
                    setState(() {
                      _decodeMode = mode;
                      _prefDecodeMode = mode;
                    });
                    _syncFullscreen();
                  }
                },
                onPersistSetting: (k, v) async {
                  await api.setSetting(k, v);
                  if (!mounted) return;
                  if (k == 'playerScale') {
                    setState(() => _aspect = _aspectFromScale(v));
                    _syncFullscreen();
                  }
                  if (k == 'playerAmbient') {
                    setState(() => _ambientOn = v.toLowerCase() == 'true');
                    _syncFullscreen();
                  }
                  if (k == 'playerStableVolume') {
                    final on = v.toLowerCase() == 'true';
                    setState(() => _stableVolumeOn = on);
                    unawaited(_applyStableVolume(_playback, on));
                    _syncFullscreen();
                  }
                  if (k == 'danmaku') {
                    setState(() => _danmakuOn = v.toLowerCase() == 'true');
                    _syncFullscreen();
                  }
                  if (k == 'danmakuApi') setState(() => _danmakuApi = v);
                  if (k == 'playerDecode') {
                    final next = v.trim().isEmpty ? 'auto' : v.trim();
                    setState(() {
                      _decodeMode = next;
                      _prefDecodeMode = next;
                    });
                    _syncFullscreen();
                  }
                  if (k == 'player') {
                    final prev = _playerVal;
                    final next = kotvClampPlayerVal(v, live: false);
                    setState(() {
                      _playerVal = next;
                      _prefPlayerVal = next;
                    });
                    if (next != prev && _epIdx >= 0) {
                      unawaited(_playAt(_epIdx));
                    } else {
                      _syncFullscreen();
                    }
                  }
                },
                onPlayerStatus: api.playerStatus,
                onExternalPlayer: (player) => api.playerExternal(url: _playUrl, player: player),
                onToggleKeep: () async {
                  final item = VodItem(id: id, name: vod.name, pic: vod.pic, site: site, remarks: vod.remarks);
                  final kept = await LocalCollect.toggle(item);
                  if (mounted) {
                    setState(() => _kept = kept);
                    _syncFullscreen();
                  }
                  return kept ? '取消收藏' : '收藏';
                },
                onDanmakuChanged: (v) {
                  if (mounted) {
                    setState(() => _danmakuOn = v);
                    _syncFullscreen();
                  }
                },
                onAmbientChanged: (v) {
                  if (mounted) {
                    setState(() => _ambientOn = v);
                    _syncFullscreen();
                  }
                },
                onParse: () => unawaited(_pickParse()),
                onRefresh: () {
                  if (_epIdx >= 0) unawaited(_playAt(_epIdx));
                },
                onCast: () => unawaited(_cast()),
                onMini: () {
                  Navigator.of(context).maybePop();
                  unawaited(_enterMini());
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _cast() async {
    if (_playUrl.isEmpty) {
      if (mounted) showAppNews(context, '请先播放内容再投屏');
      return;
    }
    final msg = await runKotvCast(
      context,
      ref.read(apiProvider),
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    if (msg != null && mounted) setState(() => _status = msg);
  }

  Future<void> _enterMini() async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先播放内容')));
      }
      return;
    }
    if (kIsWeb) {
      _playback.onPictureInPictureChanged = (inPip) {
        if (!mounted) return;
        setState(() => _miniDesktop = inPip);
      };
      final ok = await _playback.enterPictureInPicture();
      if (!mounted) return;
      if (ok) {
        setState(() => _miniDesktop = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法进入画中画，请检查浏览器是否支持')),
        );
      }
      return;
    }
    if (!MiniPlayerWindow.supported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前平台不支持迷你桌面播放')));
      }
      return;
    }
    MiniPlayerWindow.onAndroidPipChanged = (inPip) {
      if (!mounted) return;
      setState(() => _miniDesktop = inPip);
    };
    await MiniPlayerWindow.enter();
    if (!mounted) return;
    if (MiniPlayerWindow.active) {
      setState(() => _miniDesktop = true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法进入小窗，请检查系统是否支持画中画')));
    }
  }

  Future<void> _exitMini() async {
    if (kIsWeb) {
      await _playback.exitPictureInPicture();
      if (!mounted) return;
      setState(() => _miniDesktop = false);
      return;
    }
    await MiniPlayerWindow.exit();
    if (!mounted) return;
    setState(() => _miniDesktop = false);
  }

  Widget _videoStage({required bool interactive}) {
    final d = _detail;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_playUrl.isEmpty) {
          // 独立窗口模式下画面为空闲区：把播放窗口调到前台。
          if (_popupPlayer && PlaybackWindow.open) {
            unawaited(PlaybackWindow.focus());
          }
          return;
        }
        unawaited(_playback.playOrPause());
        setState(() {});
      },
      onDoubleTap: interactive
          ? () {
              // v8.2：不需要内置播放——画面区双击在独立窗口模式下始终聚焦播放窗口；
              // 未播放则弹独立窗口播放，不再进入内嵌全屏。
              if (PlaybackWindow.open) {
                unawaited(PlaybackWindow.focus());
              } else if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_eps.isNotEmpty) {
                unawaited(_playAt(_epIdx >= 0 ? _epIdx : 0));
              }
            }
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_playUrl.isEmpty)
            (d == null || d.pic.isEmpty
                ? const ColoredBox(
                    color: Color(0xFF2A1848),
                    child: Center(
                      child: Text('选择剧集开始播放', style: TextStyle(color: Colors.white70, fontSize: 16)),
                    ),
                  )
                : Image.network(d.pic, fit: BoxFit.contain))
          else
            ListenableBuilder(
              listenable: _playback,
              builder: (context, _) => kotvPlaybackView(
                playerVal: _playerVal,
                playback: _playback,
                mpv: _mk,
                fit: _aspect.fit,
              ),
            ),
          if (_playUrl.isNotEmpty)
            KotvBufferingOverlay(
              player: _playback,
              force: !_playback.playing &&
                  (_status.contains('加载中') ||
                      _status.contains('换集') ||
                      _status.contains('磁力缓冲') ||
                      _status.contains('缓冲中')),
            ),
          if (_status.contains('解析') || _status.contains('嗅探'))
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFE53955), strokeWidth: 3),
                    SizedBox(height: 14),
                    Text('正在解析播放地址', style: TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inlineChrome() {
    return VodInlineControls(
      player: _playback,
      miniActive: _miniDesktop,
      onCast: () => unawaited(_cast()),
      onMini: () => unawaited(_miniDesktop ? _exitMini() : _enterMini()),
      onExpand: (kind) => unawaited(_enterFullscreen(kind)),
      onStop: () async {
        await _stopHard();
        if (_miniDesktop) await _exitMini();
        if (mounted) {
          setState(() {
            _status = '已停止';
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = (_miniDesktop && _detail != null)
        // 主界面已收起：仅桌面悬浮播放层；控件半透明，鼠标移入显示
        ? Scaffold(
            backgroundColor: Colors.transparent,
            body: DragToMoveArea(
              child: MiniHoverShell(
                video: _videoStage(interactive: true),
                chrome: VodInlineControls(
                  player: _playback,
                  miniActive: true,
                  translucent: true,
                  onCast: () => unawaited(_cast()),
                  onMini: () => unawaited(_exitMini()),
                  onExpand: (kind) => unawaited(_enterFullscreen(kind)),
                  onStop: () async {
                    await _stopHard();
                    if (_miniDesktop) await _exitMini();
                    if (mounted) {
                      setState(() {
                        _status = '已停止';
                      });
                    }
                  },
                ),
              ),
            ),
          )
        : Scaffold(
            backgroundColor: Colors.transparent,
            body: AppBackdrop(
              child: Column(
                children: [
                  LibraryTopBar(
                    onBack: () => unawaited(_leavePage()),
                    onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
                    onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
                    onNews: () => showAppNews(context, remoteHint(ref)),
                    title: widget.title.isNotEmpty ? widget.title : '详情',
                  ),
                  Expanded(
                    child: _loading
                        ? Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary))
                        : _error != null
                            ? Center(child: Text(_error!, style: TextStyle(color: KotvPalette.of(context).fg)))
                            : _buildBody(),
                  ),
                ],
              ),
            ),
          );

    return PopScope(
      // 未在播时可直接手势/系统返回；播放中先硬停再 pop（对齐停播需求）
      canPop: _allowPop || (!_miniDesktop && _playUrl.isEmpty),
      onPopInvoked: (didPop) {
        if (didPop) {
          unawaited(_stopHard());
          return;
        }
        unawaited(_leavePage());
      },
      child: body,
    );
  }

  Widget _buildBody() {
    final d = _detail!;
    final flags = d.flags;
    final eps = _eps;
    final pageCount = eps.isEmpty ? 0 : ((eps.length - 1) ~/ _epSize) + 1;
    final pageEps = eps.skip(_epPage * _epSize).take(_epSize).toList();
    final director = d.director.isEmpty ? '暂无' : d.director;
    final actor = d.actor.isEmpty ? '暂无' : d.actor;
    final introRaw = d.content.isEmpty ? '' : d.content;
    final intro = introRaw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final introText = intro.isEmpty ? '暂无' : intro;
    final compact = KotvLayout.isCompact(context);
    final p = KotvPalette.of(context);
    final fg = p.fg;
    final muted = p.muted;

    Widget videoPane({required bool expand}) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xEE0A0A12),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: expand
              ? Column(
                  children: [
                    Expanded(child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(aspectRatio: 16 / 9, child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                ),
        ),
      );
    }

    Widget metaBlock() {
      final info = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导演：$director',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 6),
          Text(
            '演员：$actor',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 6),
          Text(
            '简介：$introText',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.5),
          ),
        ],
      );
      return InkWell(
        onTap: () => _showVodMeta(d),
        borderRadius: BorderRadius.circular(8),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: info),
      );
    }

    Widget actionRow() {
      final compactActions = compact || KotvLayout.useBottomNav(context);
      final rowH = compactActions ? 40.0 : 58.0;
      return SizedBox(
        height: rowH,
        child: HScroll(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
            _action('播放', Icons.play_arrow_rounded, () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_epIdx >= 0) {
                unawaited(_playAt(_epIdx));
              } else if (eps.isNotEmpty) {
                unawaited(_playAt(0));
              }
            }),
            _action('搜索', Icons.search_rounded, () {
              final q = _quickSearchQuery(d);
              unawaited(_leavePage(afterPop: () {
                ref.read(pendingSearchProvider.notifier).state = q;
                goKotvPage(ref, KotvPage.search);
              }));
            }),
            _action(_reversed ? '正序' : '倒叙', Icons.swap_vert_rounded, () {
              final n = _eps.length;
              final old = _epIdx;
              setState(() {
                _reversed = !_reversed;
                if (old >= 0 && n > 0) {
                  _epIdx = n - 1 - old;
                  _epPage = _epIdx ~/ _epSize;
                } else {
                  _epPage = 0;
                }
                _status = _reversed ? '已倒序' : '已正序';
              });
            }),
            _action(_kept ? '取消收藏' : '收藏', Icons.star_border_rounded, () async {
              final kept = await LocalCollect.toggle(VodItem(
                id: d.id.isNotEmpty ? d.id : widget.id,
                name: d.name,
                pic: d.pic,
                site: d.site.isNotEmpty ? d.site : widget.site,
                remarks: d.remarks,
              ));
              setState(() {
                _kept = kept;
                _status = kept ? '已加入收藏' : '已取消收藏';
              });
            }),
            _action('换源', Icons.visibility_outlined, () {
              if (flags.length <= 1) {
                setState(() => _status = '仅一条线路，无法换源');
                return;
              }
              final next = (_flagIdx + 1) % flags.length;
              _selectFlag(next);
            }),
            _action('解析', Icons.tune_rounded, () => _pickParse()),
          ],
        ),
        ),
      );
    }

    Widget lower() {
      final pillH = compact ? 28.0 : 36.0;
      final pillFs = compact ? 12.0 : 15.0;
      final epH = compact ? 32.0 : 42.0;
      final epFs = compact ? 12.0 : 14.0;
      final gap = compact ? 6.0 : 10.0;
      final srcLabelFs = compact ? 13.0 : 16.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: compact ? 8 : 10),
          Row(
            children: [
              Text('视频来源', style: TextStyle(color: fg, fontSize: srcLabelFs, fontWeight: FontWeight.w700)),
              SizedBox(width: compact ? 8 : 14),
              Expanded(
                child: SizedBox(
                  height: pillH + 2,
                  child: HScrollList(
                    itemCount: flags.length,
                    separatorBuilder: (_, __) => SizedBox(width: compact ? 6 : 8),
                    itemBuilder: (_, i) => AppPill(
                      label: flags[i].show,
                      height: pillH,
                      fontSize: pillFs,
                      selected: i == _flagIdx,
                      onTap: () {
                        if (i == _flagIdx) return;
                        _selectFlag(i);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (pageCount > 1) ...[
            SizedBox(height: compact ? 8 : 10),
            SizedBox(
              height: pillH,
              child: HScrollList(
                itemCount: pageCount,
                separatorBuilder: (_, __) => SizedBox(width: compact ? 6 : 8),
                itemBuilder: (_, i) {
                  final from = i * _epSize + 1;
                  final to = ((i + 1) * _epSize).clamp(0, eps.length);
                  return AppPill(
                    label: '$from-$to',
                    height: pillH,
                    fontSize: pillFs,
                    selected: i == _epPage,
                    onTap: () => setState(() => _epPage = i),
                  );
                },
              ),
            ),
          ],
          SizedBox(height: compact ? 8 : 12),
          if (pageEps.isEmpty)
            Text('无剧集', style: TextStyle(color: muted))
          else
            LayoutBuilder(
              builder: (context, c) {
                final cols = compact ? 3 : 6;
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < pageEps.length; i++)
                      SizedBox(
                        width: w,
                        height: epH,
                        child: EpisodeChip(
                          label: pageEps[i].name,
                          selected: _epIdx == _epPage * _epSize + i,
                          autofocus: false,
                          height: epH,
                          fontSize: epFs,
                          onTap: () => _playAt(_epPage * _epSize + i),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      );
    }

    if (compact) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
        children: [
          videoPane(expand: false),
          const SizedBox(height: 12),
          Text(
            d.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg, fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
              _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
              _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
              if (d.area.isNotEmpty) _meta('地区：${d.area}'),
            ],
          ),
          const SizedBox(height: 8),
          metaBlock(),
          const SizedBox(height: 4),
          Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted.withOpacity(0.85), fontSize: 12)),
          const SizedBox(height: 6),
          actionRow(),
          lower(),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 略压缩上半区，避免简介区与「视频来源」之间大块空档
        final upperH = (constraints.maxHeight * 0.44).clamp(320.0, 440.0);
        return ListView(
          padding: const EdgeInsets.fromLTRB(48, 8, 48, 36),
          children: [
            SizedBox(
              height: upperH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 42, child: videoPane(expand: true)),
                  const SizedBox(width: 28),
                  Expanded(
                    flex: 58,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 20,
                            runSpacing: 6,
                            children: [
                              _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
                              _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
                              _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
                              if (d.area.isNotEmpty) _meta('地区：${d.area}'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          metaBlock(),
                          const Spacer(),
                          Text(
                            _status,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted.withOpacity(0.85), fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          actionRow(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            lower(),
          ],
        );
      },
    );
  }

  Future<void> _pickParse() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final parses = ((st['parses'] as List?) ?? []).whereType<Map>().toList();
      if (parses.isEmpty) {
        setState(() => _status = '当前配置无解析器');
        return;
      }
      final names = parses.map((e) => '${e['name'] ?? ''}').where((e) => e.isNotEmpty).toList();
      final cur = '${(st['settings'] as Map?)?['preferredParse'] ?? ''}';
      final picked = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) {
          final pal = KotvPalette.of(ctx);
          return SimpleDialog(
            backgroundColor: pal.dialogBg,
            title: Text('选择解析器', style: TextStyle(color: pal.fg)),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, ''),
                child: Text('自动（默认）${cur.isEmpty ? '  ✓' : ''}', style: TextStyle(color: pal.fg)),
              ),
              for (final n in names)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, n),
                  child: Text('$n${cur == n ? '  ✓' : ''}', style: TextStyle(color: pal.fg)),
                ),
            ],
          );
        },
      );
      if (picked == null) return;
      await ref.read(apiProvider).setSetting('preferredParse', picked);
      setState(() => _status = picked.isEmpty ? '解析器: 自动' : '解析器: $picked');
      if (_epIdx >= 0) _playAt(_epIdx);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Widget _meta(String t) {
    final p = KotvPalette.of(context);
    return Text(
      t,
      style: TextStyle(color: p.muted, fontSize: 14.5, height: 1.3),
    );
  }

  String _quickSearchQuery(VodDetail d) {
    var q = d.actor.trim();
    if (q.isEmpty || q == '暂无') return d.name;
    for (final sep in [',', '，', '/', '、', ' ']) {
      final i = q.indexOf(sep);
      if (i > 0) {
        q = q.substring(0, i).trim();
        break;
      }
    }
    return q.isEmpty ? d.name : q;
  }

  void _showVodMeta(VodDetail d) {
    final p = KotvPalette.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text(d.name, style: TextStyle(color: p.fg)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Text(
              '导演：${d.director.isEmpty ? '暂无' : d.director}\n'
              '演员：${d.actor.isEmpty ? '暂无' : d.actor}\n'
              '类型：${d.typeName.isEmpty ? '暂无' : d.typeName}\n'
              '年份：${d.year.isEmpty ? '暂无' : d.year}\n'
              '地区：${d.area.isEmpty ? '暂无' : d.area}\n'
              '备注：${d.remarks.isEmpty ? '暂无' : d.remarks}\n\n'
              '${d.content.isEmpty ? '暂无简介' : d.content.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim()}',
              style: TextStyle(color: p.muted, height: 1.55, fontSize: 15),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('关闭', style: TextStyle(color: p.primary))),
        ],
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onTap) {
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context) || KotvLayout.useBottomNav(context);
    final s = LayoutScale.layoutOf(context);
    final w = (compact ? 48.0 : 72.0) * (compact ? 1.0 : s.clamp(0.75, 1.0));
    final h = (compact ? 36.0 : 56.0) * (compact ? 1.0 : s.clamp(0.75, 1.0));
    final iconSz = compact ? 14.0 : 20.0;
    final fs = compact ? 9.0 : 11.0;
    final gap = compact ? 1.0 : 4.0;
    final radius = compact ? 7.0 : 10.0;
    return Padding(
      padding: EdgeInsets.only(right: compact ? 4 : 8),
      child: TvFocus(
        onPressed: onTap,
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: Ink(
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: p.pillBg,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: p.pillBorder),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: p.fg, size: iconSz),
                  SizedBox(height: gap),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.fg.withOpacity(0.85), fontSize: fs, height: 1.1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
