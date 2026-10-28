import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../player/kotv_playback.dart';
import '../player/kotv_player_factory.dart';
import '../player/mpv_opts.dart';
import '../widgets/buffering_overlay.dart';

/// 独立播放窗口参数（跨窗口 JSON 传递）。
///
/// 主窗口解析出播放地址后，把画面相关参数交给独立窗口；独立窗口自行创建
/// media_kit(MPV) 播放器渲染，主窗口保持浏览列表。
class PlaybackWindowArgs {
  const PlaybackWindowArgs({
    required this.vodName,
    required this.title,
    required this.epIdx,
    this.episodes = const [],
    required this.playUrl,
    this.headers = const {},
    this.decodeMode = 'auto',
    this.fit = 'contain',
    this.volume,
    this.rate,
  });

  final String vodName;
  final String title;
  final int epIdx;
  final List<String> episodes;
  final String playUrl;
  final Map<String, String> headers;
  final String decodeMode;

  /// BoxFit.name：contain / fill / zoom / cover / fitWidth / fitHeight。
  final String fit;
  final double? volume;
  final double? rate;

  Map<String, dynamic> toJson() => {
        'vodName': vodName,
        'title': title,
        'epIdx': epIdx,
        'episodes': episodes,
        'playUrl': playUrl,
        'headers': headers,
        'decodeMode': decodeMode,
        'fit': fit,
        'volume': volume,
        'rate': rate,
      };

  static PlaybackWindowArgs? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    try {
      final a = Map<String, dynamic>.from(raw);
      final url = '${a['playUrl'] ?? ''}';
      if (url.isEmpty) return null;
      return PlaybackWindowArgs(
        vodName: '${a['vodName'] ?? ''}',
        title: '${a['title'] ?? ''}',
        epIdx: (a['epIdx'] as num?)?.toInt() ?? 0,
        episodes: (a['episodes'] as List?)?.map((e) => '$e').toList() ?? const [],
        playUrl: url,
        headers: Map<String, String>.from((a['headers'] as Map?) ?? const {}),
        decodeMode: '${a['decodeMode'] ?? 'auto'}',
        fit: '${a['fit'] ?? 'contain'}',
        volume: (a['volume'] as num?)?.toDouble(),
        rate: (a['rate'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 [WindowController.fromCurrentEngine] 传来的窗口参数。
  static PlaybackWindowArgs? tryFromWindowArguments(String json) {
    if (json.isEmpty) return null;
    try {
      final m = Map<String, dynamic>.from(jsonDecode(json) as Map);
      if (m['type'] != 'playback') return null;
      return tryFromMap(m['args']);
    } catch (_) {
      return null;
    }
  }
}

/// 主窗口侧：管理独立播放窗口的创建 / 切集 / 关闭。
class PlaybackWindow {
  PlaybackWindow._();

  static const WindowMethodChannel _playCh =
      WindowMethodChannel('kotv_playback', mode: ChannelMode.unidirectional);
  static const WindowMethodChannel _hostCh =
      WindowMethodChannel('kotv_playback_host', mode: ChannelMode.unidirectional);

  static WindowController? _ctrl;

  /// 独立播放窗口是否已打开。
  static bool get open => _ctrl != null;

  /// 独立窗口关闭时回调（主窗口 UI 复位）。
  static VoidCallback? onPlaybackClosed;

  /// 独立窗口播放出错回调。
  static void Function(String message)? onPlaybackError;

  /// 独立窗口请求切换剧集（子窗口 → 主窗口，主窗口负责解析新集 URL）。
  static void Function(int epIdx)? onSwitchEpisode;

  /// 主窗口启动时注册一次：接收独立窗口上报。
  static Future<void> initHost() async {
    if (kIsWeb) return;
    try {
      await _hostCh.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'closed':
            _ctrl = null;
            onPlaybackClosed?.call();
            return 'ok';
          case 'error':
            onPlaybackError?.call('${call.arguments ?? ''}');
            return 'ok';
          case 'switchEpisode':
            final idx = (call.arguments as num?)?.toInt();
            if (idx != null) {
              onSwitchEpisode?.call(idx);
              return 'ok';
            }
            return 'bad_args';
        }
        return null;
      });
    } catch (e) {
      debugPrint('playback window host init failed: $e');
    }
  }

  /// 请求独立窗口播放：窗口已存在则直接切集，不存在则创建。
  /// 返回 false 表示独立窗口不可用（调用方回退内嵌播放）。
  static Future<bool> play(PlaybackWindowArgs args) async {
    if (kIsWeb) return false;
    final existing = _ctrl;
    if (existing != null) {
      try {
        await _playCh.invokeMethod('play', args.toJson());
        return true;
      } catch (_) {
        _ctrl = null;
      }
    }
    try {
      final ctrl = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'playback', 'args': args.toJson()}),
        ),
      );
      _ctrl = ctrl;
      await ctrl.show();
      return true;
    } catch (e) {
      _ctrl = null;
      debugPrint('playback window create failed: $e');
      return false;
    }
  }

  /// 把独立播放窗口调到前台（点主窗口画面区域时）。
  static Future<void> focus() async {
    if (kIsWeb || _ctrl == null) return;
    try {
      await _ctrl?.show();
    } catch (_) {}
  }

  /// 请求关闭独立播放窗口（不等待结果；窗口关闭后由 host 回调复位）。
  static Future<void> close() async {
    if (kIsWeb || _ctrl == null) return;
    try {
      await _playCh.invokeMethod('close');
    } catch (_) {
      _ctrl = null;
    }
  }
}

/// 独立播放窗口的根组件（子窗口 runApp 用）。
class PlaybackWindowApp extends StatelessWidget {
  const PlaybackWindowApp({super.key, required this.args});

  final PlaybackWindowArgs args;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KO影视',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: PlaybackWindowPage(args: args),
    );
  }
}

class PlaybackWindowPage extends StatefulWidget {
  const PlaybackWindowPage({super.key, required this.args});

  final PlaybackWindowArgs args;

  @override
  State<PlaybackWindowPage> createState() => _PlaybackWindowPageState();
}

class _PlaybackWindowPageState extends State<PlaybackWindowPage>
    with WindowListener {
  MediaKitPlayback? _mk;
  late PlaybackWindowArgs _args = widget.args;
  String _status = '';
  bool _showChrome = true;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _winChangeSub;
  Duration _pos = Duration.zero;
  bool _busy = false;
  bool _epPanel = false;
  Timer? _switchTimeout;

  BoxFit get _fit {
    try {
      return BoxFit.values.byName(_args.fit);
    } catch (_) {
      return BoxFit.contain;
    }
  }

  @override
  void initState() {
    super.initState();
    _initWindow();
    final mk = MediaKitPlayback(
      kotvCreateMpvPlayer(),
      opts: KotvMpvOpts(decodeMode: _args.decodeMode),
    );
    _mk = mk;
    _posSub = mk.positionStream.listen((d) {
      if (!mounted) return;
      if (d.inSeconds == _pos.inSeconds) return;
      setState(() => _pos = d);
    });
    const ch = WindowMethodChannel('kotv_playback', mode: ChannelMode.unidirectional);
    unawaited(ch.setMethodCallHandler(_onPlayCall));
    // 兜底：窗口被系统直接关闭（窗口列表里消失）时也复位主窗口。
    _winChangeSub = onWindowsChanged.listen((_) {
      unawaited(_checkAlive());
    });
    unawaited(_open(_args));
  }

  /// 子窗口里 window_manager 只用于「本窗口」的显示层 + 拦截系统关闭；
  /// 绝不调用 destroy()（PostQuitMessage(0) 打在主消息循环上会连主窗口一起退出）。
  Future<void> _initWindow() async {
    if (kIsWeb) return;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await windowManager.ensureInitialized();
          await windowManager.setTitle('KO影视');
          await windowManager.setMinimumSize(const Size(420, 280));
          await windowManager.center();
          // 拦截系统标题栏关闭（×）：WM_CLOSE 到 Flutter 引擎会触发全局
          // RunLoop 的 PostQuitMessage，把主窗口一起退出。拦截后走 Dart
          // onWindowClose → destroySelf（原生 DestroyWindow，绕过 WM_CLOSE）。
          await windowManager.setPreventClose(true);
          windowManager.addListener(this);
        } catch (e) {
          debugPrint('playback window init failed: $e');
        }
      });
    } catch (e) {
      debugPrint('playback window init failed: $e');
    }
  }

  Future<void> _checkAlive() async {
    try {
      final me = await WindowController.fromCurrentEngine();
      final all = await WindowController.getAll();
      final alive = all.any((w) => w.windowId == me.windowId);
      if (!alive) {
        // 本窗口已被系统关闭：通知主窗口并释放播放器。
        await _notifyClosed();
        await _disposePlayback();
      }
    } catch (_) {}
  }

  Future<dynamic> _onPlayCall(MethodCall call) async {
    switch (call.method) {
      case 'play':
        final a = PlaybackWindowArgs.tryFromMap(call.arguments);
        if (a != null) {
          unawaited(_open(a));
          return 'ok';
        }
        return 'bad_args';
      case 'close':
        unawaited(_close());
        return 'ok';
    }
    return null;
  }

  Future<void> _open(PlaybackWindowArgs args) async {
    final mk = _mk;
    if (mk == null || _busy) return;
    _busy = true;
    _switchTimeout?.cancel();
    try {
      setState(() {
        _args = args;
        _status = '加载中…';
        _pos = Duration.zero;
        _epPanel = false;
      });
      try {
        await mk.stop();
      } catch (_) {}
      try {
        final headers = args.headers.isEmpty ? null : args.headers;
        await mk.open(args.playUrl, headers: headers);
        try {
          await mk.play();
        } catch (_) {}
        if (args.rate != null && args.rate! > 0) {
          try {
            await mk.setRate(args.rate!);
          } catch (_) {}
        }
        if (args.volume != null) {
          try {
            await mk.setVolume(args.volume!.clamp(0, 100));
          } catch (_) {}
        }
        if (mounted) setState(() => _status = '');
      } catch (e) {
        if (mounted) setState(() => _status = '播放失败：$e');
        unawaited(_notifyError('$e'));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _notifyClosed() async {
    if (kIsWeb) return;
    try {
      await const WindowMethodChannel('kotv_playback_host', mode: ChannelMode.unidirectional)
          .invokeMethod('closed');
    } catch (_) {}
  }

  Future<void> _notifyError(String message) async {
    if (kIsWeb) return;
    try {
      await const WindowMethodChannel('kotv_playback_host', mode: ChannelMode.unidirectional)
          .invokeMethod('error', message);
    } catch (_) {}
  }

  /// 请求主窗口解析并切换到第 [idx] 集（主窗口走 popup 分支回传新 playUrl）。
  Future<void> _requestEpisode(int idx) async {
    if (idx == _args.epIdx) return;
    final mk = _mk;
    if (mk == null) return;
    _switchTimeout?.cancel();
    setState(() {
      _epPanel = false;
      _status = '切换中…';
    });
    try {
      await mk.stop();
    } catch (_) {}
    _switchTimeout = Timer(const Duration(seconds: 10), () {
      if (mounted && _status == '切换中…') setState(() => _status = '');
    });
    if (!kIsWeb) {
      try {
        await const WindowMethodChannel('kotv_playback_host', mode: ChannelMode.unidirectional)
            .invokeMethod('switchEpisode', idx);
      } catch (_) {
        if (mounted) setState(() => _status = '');
      }
    }
  }

  Future<void> _close() async {
    // 先通知主窗口复位，再停播放，最后原生销毁本窗口（绕过 WM_CLOSE）。
    await _notifyClosed();
    await _disposePlayback();
    if (kIsWeb) return;
    try {
      await const MethodChannel('kotv_playback_native')
          .invokeMethod('destroySelf');
    } catch (_) {
      // Linux 等未注册原生通道的环境：退回 window_manager.close()。
      try {
        await windowManager.close();
      } catch (_) {}
    }
  }

  /// 系统标题栏关闭被 setPreventClose 拦截后回调：走同一关闭路径。
  @override
  void onWindowClose() async {
    await _close();
  }

  Future<void> _disposePlayback() async {
    final mk = _mk;
    _mk = null;
    if (mk == null) return;
    _switchTimeout?.cancel();
    try {
      await mk.stop();
    } catch (_) {}
    try {
      await kotvDisposeMpvPlayer(mk.player);
    } catch (_) {}
    try {
      mk.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _switchTimeout?.cancel();
    _posSub?.cancel();
    _winChangeSub?.cancel();
    if (!kIsWeb) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    unawaited(_disposePlayback());
    super.dispose();
  }

  void _bumpChrome() {
    _hideTimer?.cancel();
    if (!_showChrome && mounted) setState(() => _showChrome = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _showChrome) setState(() => _showChrome = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final mk = _mk;
    if (mk == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(mk.playOrPause());
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      final p = mk.position - const Duration(seconds: 10);
      unawaited(mk.seek(p.isNegative ? Duration.zero : p));
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(mk.seek(mk.position + const Duration(seconds: 10)));
      _bumpChrome();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final mk = _mk;
    final title =
        _args.epIdx >= 0 && _args.epIdx < _args.episodes.length
            ? '${_args.vodName} · ${_args.episodes[_args.epIdx]}'
            : (_args.vodName.isNotEmpty ? _args.vodName : 'KO影视');
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _bumpChrome(),
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (mk != null)
                ListenableBuilder(
                  listenable: mk,
                  builder: (context, _) => kotvPlaybackView(
                    playerVal: 'mpv',
                    playback: mk,
                    mpv: mk,
                    fit: _fit,
                  ),
                )
              else
                const ColoredBox(color: Colors.black),
              if (mk != null)
                KotvBufferingOverlay(
                  player: mk,
                  force: _status.contains('加载') && !mk.playing,
                ),
              if (_status.isNotEmpty)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _status,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              // 顶栏
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withOpacity(0.72), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
                          onPressed: () => unawaited(_close()),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 底部控制条
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black.withOpacity(0.72), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
                    child: mk == null
                        ? const SizedBox.shrink()
                        : ListenableBuilder(
                            listenable: mk,
                            builder: (context, _) {
                              final dur = mk.duration;
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: '播放/暂停',
                                        icon: Icon(
                                          mk.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                        onPressed: () => unawaited(mk.playOrPause()),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(_fmt(_pos), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      Expanded(
                                        child: SliderTheme(
                                          data: SliderThemeData(
                                            trackHeight: 3,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                            activeTrackColor: const Color(0xFFE53955),
                                            inactiveTrackColor: Colors.white24,
                                            thumbColor: Colors.white,
                                          ),
                                          child: Slider(
                                            max: dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1,
                                            value: _pos.inMilliseconds
                                                .clamp(0, dur.inMilliseconds > 0 ? dur.inMilliseconds : 1)
                                                .toDouble(),
                                            onChanged: dur.inMilliseconds > 0
                                                ? (v) {
                                                    final t = Duration(milliseconds: v.round());
                                                    setState(() => _pos = t);
                                                    unawaited(mk.seek(t));
                                                  }
                                                : null,
                                          ),
                                        ),
                                      ),
                                      Text(_fmt(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      const SizedBox(width: 8),
                                      _VolumeButton(player: mk),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        tooltip: '选集',
                                        icon: const Icon(Icons.video_library_outlined, color: Colors.white, size: 22),
                                        onPressed: () {
                                          _bumpChrome();
                                          setState(() => _epPanel = !_epPanel);
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ),
              ),
              // 选集面板
              if (_epPanel && _args.episodes.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 84,
                  child: Material(
                    color: Colors.black.withOpacity(0.88),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < _args.episodes.length; i++)
                              _EpButton(
                                label: _args.episodes[i],
                                active: i == _args.epIdx,
                                onTap: () => unawaited(_requestEpisode(i)),
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
      ),
    );
  }
}

class _EpButton extends StatelessWidget {
  const _EpButton({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFE53955) : Colors.white12,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: active ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.player});

  final KotvPlayback player;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final vol = widget.player.volume;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_expanded)
              SizedBox(
                width: 90,
                child: Slider(
                  value: vol.clamp(0, 100),
                  onChanged: (v) => unawaited(widget.player.setVolume(v)),
                ),
              ),
            IconButton(
              tooltip: '音量',
              icon: Icon(
                vol <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        );
      },
    );
  }
}
