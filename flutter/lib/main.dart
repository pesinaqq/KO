import 'dart:async';
import 'util/kotv_io.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop/mini_player_window.dart';
import 'desktop/playback_window.dart';
import 'api/kotv_engine_url.dart';
import 'engine/engine_launcher.dart';
import 'player/buffer_budget.dart';
import 'player/fvp_register.dart';
import 'player/kotv_playback.dart';
import 'providers.dart';
import 'screens/shell.dart';
import 'theme/layout_scale.dart';
import 'theme/kotv_palette.dart';
import 'theme/kotv_theme.dart';
import 'widgets/chrome.dart';
import 'widgets/h_scroll.dart';

/// Release 构建里 build 抛异常会渲染成一块灰色空白（默认 ErrorWidget），
/// 页面看着像"没了"却无从追查；换成可读文案并把错误打到日志。
void _kotvLogUiError(Object error, StackTrace? stack, {String where = 'build'}) {
  debugPrint('KOTV UI ERROR ($where): $error');
  if (stack != null) debugPrint('$stack');
  if (kIsWeb) return;
  try {
    final dir = Directory('${Platform.environment['HOME'] ?? ''}/Library/Caches/KOTV/data/log');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/flutter-ui.err.log');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()} [$where]\n$error\n${stack ?? StackTrace.current}\n\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

Widget _kotvErrorWidget(FlutterErrorDetails details) {
  _kotvLogUiError(details.exception, details.stack, where: 'ErrorWidget');
  final stackLine = (details.stack?.toString() ?? '')
      .split('\n')
      .where((l) => l.contains('package:kotv/') || l.contains('package:flutter/'))
      .take(8)
      .join('\n');
  return Material(
    color: const Color(0xFF14161B),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFE53955), size: 40),
            const SizedBox(height: 12),
            const Text('页面渲染出错', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '${details.exception}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9AA0AA), fontSize: 12),
            ),
            if (stackLine.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                stackLine,
                maxLines: 10,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: const TextStyle(color: Color(0xFF6E7580), fontSize: 10, fontFamily: 'Courier'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = _kotvErrorWidget;
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _kotvLogUiError(details.exception, details.stack, where: 'FlutterError');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _kotvLogUiError(error, stack, where: 'PlatformDispatcher');
    return true;
  };
  if (!kIsWeb) {
    // Android 也要 init：用户可选 MPV（media_kit）；Web 用 HTML5，不初始化 media_kit。
    MediaKit.ensureInitialized();
    kotvRegisterFvp();
    // v5：独立播放器改为独立进程（kotv-player.exe，见 lib/playback_main.dart），
    // 经本地 TCP IPC 通信，不再使用 desktop_multi_window 共享进程子窗口。
  }
  unawaited(KotvBufferBudget.warm());
  final prefs = await SharedPreferences.getInstance();
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    final savedW = prefs.getDouble('window_w');
    final savedH = prefs.getDouble('window_h');
    final savedX = prefs.getDouble('window_x');
    final savedY = prefs.getDouble('window_y');
    var size = Size(
      (savedW ?? 1920).clamp(kotvMinWindowSize.width, 10000),
      (savedH ?? 1080).clamp(kotvMinWindowSize.height, 10000),
    );
    // 首次启动（未保存过窗口尺寸）：按主显示器分辨率取 80% 比例，
    // 避免固定 1280x720 在 4K/高分屏上偏小、在小分辨率屏上放不下。
    // 用 Flutter 内置 platformDispatcher.views 主视图取屏幕逻辑尺寸，
    // 不依赖 window_manager 的 Display API（0.4.3 无 getPrimaryDisplay）。
    if (savedW == null || savedH == null) {
      try {
        final views = WidgetsBinding.instance.platformDispatcher.views;
        if (views.isNotEmpty) {
          final v = views.first;
          final logical = Size(
            v.physicalSize.width / v.devicePixelRatio,
            v.physicalSize.height / v.devicePixelRatio,
          );
          size = Size(
            (logical.width * 0.8).clamp(kotvMinWindowSize.width, 10000),
            (logical.height * 0.8).clamp(kotvMinWindowSize.height, 10000),
          );
        }
      } catch (_) {}
    }
    final opts = WindowOptions(
      size: size,
      minimumSize: kotvMinWindowSize,
      center: savedX == null || savedY == null,
      title: 'KO影视',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      // 位置有效性校验：坏值（-32000 哨兵/越界）直接忽略，交给 center。
      final posOk = savedX != null &&
          savedY != null &&
          savedX >= -2000 &&
          savedY >= -2000 &&
          savedX <= 10000 &&
          savedY <= 10000;
      if (posOk) {
        try {
          await windowManager.setPosition(Offset(savedX, savedY));
        } catch (_) {}
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }
  var engineUrl = prefs.getString('engine_base_url');
  // Web：固定同源引擎（本页所在服务器），不可改远端地址。
  if (kIsWeb) {
    await prefs.remove('engine_base_url');
    final origin = Uri.base.origin;
    engineUrl = (origin.isNotEmpty && origin != 'null') ? origin : 'http://127.0.0.1:9978';
  } else {
    // 远端地址若无 token：降级为草稿，启动仍用本机（不拉远端仓）
    final tok = (prefs.getString('kotv_auth_token') ?? '').trim();
    if (engineUrl != null &&
        engineUrl.isNotEmpty &&
        !kotvIsLocalEngineBaseUrl(engineUrl) &&
        tok.isEmpty) {
      await prefs.setString('engine_base_url_draft', engineUrl);
      await prefs.remove('engine_base_url');
      await prefs.remove('remote_username');
      engineUrl = null;
    }
  }
  runApp(ProviderScope(
    overrides: [
      engineLauncherProvider.overrideWith((ref) {
        final launcher = EngineLauncher();
        if (engineUrl != null && engineUrl.isNotEmpty) {
          launcher.baseUrl = engineUrl;
        }
        ref.onDispose(launcher.dispose);
        return launcher;
      }),
    ],
    child: const KotvApp(),
  ));
}

class KotvApp extends ConsumerStatefulWidget {
  const KotvApp({super.key});

  @override
  ConsumerState<KotvApp> createState() => _KotvAppState();
}

class _KotvAppState extends ConsumerState<KotvApp> with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MiniPlayerWindow.bindAndroidPipListener();
    unawaited(PlaybackWindow.initHost());
    // 同步一次当前系统亮暗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(platformBrightnessProvider.notifier).state =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    _saveBoundsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    ref.read(platformBrightnessProvider.notifier).state = b;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 后台回来：Android 常把子进程引擎冻死/杀掉，不恢复则 /api/v1/play 会 Connection closed。
    unawaited(ref.read(engineLauncherProvider).onAppResumed());
  }

  Timer? _saveBoundsTimer;

  Future<void> _persistWindowBounds() async {
    if (kIsWeb || !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
    if (MiniPlayerWindow.active) return;
    try {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      final w = size.width;
      final h = size.height;
      // 最小化时 getSize 可能返回 0 或极小值，同样跳过避免下次以小窗启动。
      if (w > 0 && h > 0 && w <= 10000 && h <= 10000) {
        await prefs.setDouble('window_w', w);
        await prefs.setDouble('window_h', h);
      }
      // 窗口最小化/隐藏时 Win32 会把位置挪到 (-32000,-32000) 哨兵坐标，
      // 若直接保存，下次启动 setPosition 会把主窗口放到屏幕外（"打开不显示"）。
      // 只保存合理范围内的位置；异常坐标跳过，保留上次有效值。
      final dx = pos.dx;
      final dy = pos.dy;
      if (dx >= -2000 && dy >= -2000 && dx <= 10000 && dy <= 10000) {
        await prefs.setDouble('window_x', dx);
        await prefs.setDouble('window_y', dy);
      }
    } catch (_) {}
  }

  void _scheduleSaveWindowBounds() {
    _saveBoundsTimer?.cancel();
    _saveBoundsTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistWindowBounds());
    });
  }

  @override
  void onWindowResize() => _scheduleSaveWindowBounds();

  @override
  void onWindowMove() => _scheduleSaveWindowBounds();

  @override
  void onWindowClose() async {
    _saveBoundsTimer?.cancel();
    await _persistWindowBounds();
    // 先关独立播放窗口，再停页面内 libmpv，最后关引擎/销毁窗口。
    try {
      await PlaybackWindow.close();
    } catch (_) {}
    // 先停页面内 libmpv，再关引擎/销毁窗口，避免 mpv core 与 FlutterEngine 竞态崩溃。
    try {
      await kotvRunQuitHooks();
    } catch (_) {}
    // 先优雅停引擎（HTTP shutdown → 杀 Java/Python）；超时再杀进程树。
    // Windows 仍避免 window_manager.destroy（Win7 易 WER），最后 exit。
    try {
      await ref
          .read(engineLauncherProvider)
          .shutdown()
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        ref.read(engineLauncherProvider).shutdownSync();
      } catch (_) {}
    }
    if (Platform.isWindows) {
      exit(0);
    }
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(engineReadyProvider);
    final palette = ref.watch(kotvPaletteProvider);
    return MaterialApp(
      title: 'KO影视',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: buildKotvTheme(palette),
      // 桌面端默认不把鼠标当拖动设备；芯片/分类栏过长时需可拖拽横滚
      scrollBehavior: const KotvScrollBehavior(),
      // 色板已按 effectiveLight 生成，固定用当前 theme 即可
      themeMode: ThemeMode.light,
      home: ready.when(
        data: (ok) => ok ? const AppShell() : const _EngineOfflinePage(),
        loading: () => const AppBackdrop(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
        ),
        error: (e, _) => AppBackdrop(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: Text('$e', style: const TextStyle(color: Colors.white))),
          ),
        ),
      ),
    );
  }
}

/// 引擎未就绪页：必须作为 MaterialApp.home 的子树，dialog / Theme 才能用到 Navigator。
class _EngineOfflinePage extends ConsumerWidget {
  const _EngineOfflinePage();

  Future<void> _setupBackendUrl(BuildContext context, WidgetRef ref) async {
    final launcher = ref.read(engineLauncherProvider);
    final ctrl = TextEditingController(
      text: launcher.baseUrl == 'http://127.0.0.1:9978' ? '' : launcher.baseUrl,
    );
    final navCtx = rootNavigatorKey.currentContext ?? context;
    final p = KotvPalette.of(navCtx);
    final v = await showDialog<String>(
      context: navCtx,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text('连接后端服务', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: p.fg),
            decoration: InputDecoration(
              hintText: 'http://10.0.0.8:9978 或 https://api.example.com',
              hintStyle: TextStyle(color: p.muted),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存并重试')),
        ],
      ),
    );
    if (v == null) return;
    final prefs = await SharedPreferences.getInstance();
    final n = kotvNormalizeEngineBaseUrl(v);
    if (n.isEmpty) {
      await prefs.remove('engine_base_url');
      launcher.applyBaseUrl('');
    } else {
      await prefs.setString('engine_base_url', n);
      launcher.applyBaseUrl(n);
    }
    ref.read(apiProvider).baseUrl = launcher.baseUrl;
    ref.invalidate(engineReadyProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurface.withOpacity(0.7);
    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('KO影视', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(
                  kIsWeb
                      ? '无法连接本站后端服务\n请确认引擎已启动后刷新页面'
                      : '请先连接可用后端服务',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 16),
                if (!kIsWeb)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppPill(
                        label: '连接后端',
                        width: 130,
                        autofocus: true,
                        onTap: () => unawaited(_setupBackendUrl(context, ref)),
                      ),
                      const SizedBox(width: 10),
                      AppPill(
                        label: '重试',
                        width: 90,
                        onTap: () => ref.invalidate(engineReadyProvider),
                      ),
                    ],
                  )
                else
                  AppPill(
                    label: '刷新重试',
                    width: 120,
                    autofocus: true,
                    onTap: () => ref.invalidate(engineReadyProvider),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
