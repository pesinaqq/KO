import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../player/play_headers.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../widgets/auth_gate.dart';
import '../widgets/chrome.dart';
import 'collect_screen.dart';
import 'detail_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'video_screen.dart';

/// 宽屏单栈换页；竖屏窄窗用底部菜单（普通 App）。
enum KotvPage { video, search, history, live, settings, profile, collect }

final kotvPageProvider = StateProvider<KotvPage>((ref) => KotvPage.video);

/// 主 Tab 返回栈（不含详情 push）；用于设置/我的等返回上一页，而非直接退桌面。
final kotvPageStackProvider = StateProvider<List<KotvPage>>((ref) => <KotvPage>[]);

final rootNavigatorKey = GlobalKey<NavigatorState>();

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  RemoteBridge? _bridge;
  PostMsgHost? _postMsg;
  DateTime? _lastHomeBackAt;
  /// 防止 PopScope 与 NavigatorPopHandler 同一次返回各调一次。
  bool _handlingBack = false;
  /// Web：登录完成前不渲染主界面。
  bool _webAuthed = !kIsWeb;
  /// 稳定 Navigator key：切 Tab 用 pushAndRemoveUntil 换根页，勿用 GlobalObjectKey(page)
  ///（卸树再挂同一 GlobalKey 会在 activate 时 _state! 空指针 →「页面渲染出错」）。
  final GlobalKey<NavigatorState> _shellNavKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 仅 Web：打开本站页面必须先登录。PC/安卓在设置里「远端登录」。
      if (kIsWeb) {
        while (mounted) {
          final ok = await ensureRemoteAuthIfNeeded(context, ref);
          if (!mounted) return;
          if (ok) {
            setState(() => _webAuthed = true);
            break;
          }
        }
      }
      if (!mounted) return;
      _wireRemote();
    });
  }

  void _wireRemote() {
    final api = ref.read(apiProvider);
    _bridge?.stop();
    _postMsg?.stop();
    _bridge = RemoteBridge(api)
      ..onSearch = (kw) {
        goKotvPage(ref, KotvPage.search);
        ref.read(pendingSearchProvider.notifier).state = kw;
      }
      ..start();
    _postMsg = PostMsgHost(api, navigatorKey: rootNavigatorKey)..start();
    ref.read(remoteBridgeProvider.notifier).state = _bridge;
    // 启动时同步无痕开关到本地历史写入逻辑
    api.getSettings().then((st) {
      final map = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
      final inc = '${map['incognito'] ?? ''}'.toLowerCase() == 'true';
      kotvApplyPlayUaSetting('${map['ua'] ?? ''}');
      return LocalHistory.setIncognito(inc);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _bridge?.stop();
    _postMsg?.stop();
    super.dispose();
  }

  int _bottomIndex(KotvPage page) {
    return switch (page) {
      KotvPage.video => 0,
      KotvPage.search => 1,
      KotvPage.profile || KotvPage.history || KotvPage.collect || KotvPage.settings => 2,
      // 直播入口已移除，不可达；保留枚举成员以满足穷尽 switch。
      KotvPage.live => 1,
    };
  }

  void _onBottomTap(int i) {
    final next = switch (i) {
      0 => KotvPage.video,
      1 => KotvPage.search,
      _ => KotvPage.profile,
    };
    // 底栏切主 Tab：清空返回栈，避免从深层页「返回」跳到已离开的 Tab
    ref.read(kotvPageStackProvider.notifier).state = <KotvPage>[];
    goKotvPage(ref, next, recordHistory: false);
  }

  Widget _pageOf(KotvPage page) {
    return switch (page) {
      KotvPage.video => const VideoScreen(),
      KotvPage.search => const SearchScreen(),
      KotvPage.history => const HistoryScreen(),
      KotvPage.settings => const SettingsScreen(),
      KotvPage.profile => const ProfileScreen(),
      KotvPage.collect => const CollectScreen(),
      // 直播入口已移除，不可达。
      KotvPage.live => const ProfileScreen(),
    };
  }

  /// 系统/手势/遥控返回：先关根弹窗/详情 → 主 Tab 返回栈 → 首页连按两次退桌面。
  void _onShellBack() {
    if (_handlingBack) return;
    _handlingBack = true;
    scheduleMicrotask(() => _handlingBack = false);

    final root = rootNavigatorKey.currentState;
    // 扫码等 useRootNavigator 弹窗 / 点播全屏在根栈顶：先 pop。
    if (root != null && root.canPop()) {
      root.pop();
      return;
    }
    final post = PostMsgHost.instance;
    if (post != null && post.hasOpenDialog) {
      unawaited(post.cancelAll(reply: true, popDialog: true));
      return;
    }
    final page = ref.read(kotvPageProvider);
    final nav = _shellNavKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    // 详情播放中 PopScope.canPop=false → Navigator.canPop 也是 false，
    // 但仍须 maybePop 触发详情 onPopInvoked→_leavePage，不能误走退桌面。
    if (DetailScreen.isOpen && nav != null) {
      unawaited(nav.maybePop());
      return;
    }
    // 直播：先关侧栏/退出沉浸全屏。
    if (page == KotvPage.live) {
      if (liveScreenHandleBack?.call() == true) return;
    }
    // 非首页：退到上一主 Tab（kotvPageStack）；无栈则回点播首页。
    if (page != KotvPage.video) {
      _lastHomeBackAt = null;
      kotvPageBack(ref);
      return;
    }
    // 已在点播首页：连按两次退桌面。
    _promptDoubleBackExit();
  }

  void _promptDoubleBackExit() {
    final now = DateTime.now();
    final last = _lastHomeBackAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      _lastHomeBackAt = null;
      SystemNavigator.pop();
      return;
    }
    _lastHomeBackAt = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('再按一次返回桌面'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_webAuthed) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: SizedBox.expand(),
      );
    }
    final page = ref.watch(kotvPageProvider);
    final busy = ref.watch(uiBusyProvider);
    final bottomNav = KotvLayout.useBottomNav(context);

    // 切主 Tab：原地换根路由，Navigator 元素不卸树，避免 GlobalKey reactivate 崩溃。
    ref.listen<KotvPage>(kotvPageProvider, (prev, next) {
      if (prev == null || prev == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final nav = _shellNavKey.currentState;
        if (nav == null) return;
        nav.pushAndRemoveUntil(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: next.name),
            builder: (_) => _pageOf(next),
          ),
          (_) => false,
        );
      });
    });

    return PopScope(
      // 根层始终拦截：禁止系统直接 finish Activity。
      // 用 onPopInvoked（非 WithResult）以兼容 Win7 / Flutter 3.19。
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _onShellBack();
      },
      // 壁纸铺满整屏（含底栏区域）；内容区停在底栏上方，半透明底栏只透壁纸不透海报。
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // Android edge-to-edge：顶栏按钮若画进状态栏区域会被系统吃掉点击
          // 不 extendBody：列表不画进底栏下面，避免海报透出来。
          extendBody: false,
          body: SafeArea(
            bottom: !bottomNav,
            child: ScaledLayoutBox(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 内层 Navigator 会抢走系统返回；无子路由可 pop 时必须用
                  // NavigatorPopHandler 接到外壳，否则 Android 直接退桌面。
                  // onPop（非 WithResult）兼容 Flutter 3.19。
                  NavigatorPopHandler(
                    onPop: _onShellBack,
                    child: Navigator(
                      key: _shellNavKey,
                      onGenerateRoute: (settings) {
                        return MaterialPageRoute<void>(
                          settings: settings,
                          builder: (_) => _pageOf(page),
                        );
                      },
                    ),
                  ),
                  if (busy != null && busy.isNotEmpty)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: () => ref.read(uiBusyProvider.notifier).state = null,
                        child: ColoredBox(
                          color: const Color(0x990A0820),
                          child: Center(
                            child: Container(
                              constraints: BoxConstraints(
                                minWidth: KotvLayout.isCompact(context) ? 200 : 280,
                                maxWidth: 420,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
                              decoration: BoxDecoration(
                                color: const Color(0xCC63248A),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: const Color(0x55D8A5E8)),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    busy,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: bottomNav
              ? Builder(builder: (context) {
                  final p = KotvPalette.of(context);
                  // Scaffold 透明 + 外层 AppBackdrop：半透明底栏只透壁纸。
                  final barBg = p.bottomNav.withOpacity(p.light ? 0.72 : 0.55);
                  return NavigationBarTheme(
                    data: NavigationBarThemeData(
                      backgroundColor: barBg,
                      indicatorColor: p.selected.withOpacity(0.92),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      overlayColor: MaterialStateProperty.all(Colors.transparent),
                      labelTextStyle: MaterialStateProperty.resolveWith((states) {
                        final selected = states.contains(MaterialState.selected);
                        return TextStyle(
                          fontSize: 12,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? p.fg : p.muted,
                        );
                      }),
                      iconTheme: MaterialStateProperty.resolveWith((states) {
                        final selected = states.contains(MaterialState.selected);
                        return IconThemeData(color: selected ? Colors.white : p.muted, size: 24);
                      }),
                    ),
                    child: NavigationBar(
                      height: 64,
                      backgroundColor: barBg,
                      indicatorColor: p.selected.withOpacity(0.92),
                      surfaceTintColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      overlayColor: MaterialStateProperty.all(Colors.transparent),
                      elevation: 0,
                      selectedIndex: _bottomIndex(page),
                      onDestinationSelected: _onBottomTap,
                      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                      destinations: [
                        NavigationDestination(
                          icon: Icon(Icons.home_outlined, color: p.muted),
                          selectedIcon: const Icon(Icons.home_rounded, color: Colors.white),
                          label: '首页',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.search_rounded, color: p.muted),
                          selectedIcon: const Icon(Icons.search_rounded, color: Colors.white),
                          label: '搜索',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.person_outline_rounded, color: p.muted),
                          selectedIcon: const Icon(Icons.person_rounded, color: Colors.white),
                          label: '我的',
                        ),
                      ],
                    ),
                  );
                })
              : null,
        ),
      ),
    );
  }
}

/// 直播页注册：返回键优先关侧栏/退出沉浸全屏。返回 true 表示已消费。
bool Function()? liveScreenHandleBack;

void goKotvPage(WidgetRef ref, KotvPage page, {bool recordHistory = true}) {
  final cur = ref.read(kotvPageProvider);
  if (recordHistory && cur != page) {
    final stack = List<KotvPage>.from(ref.read(kotvPageStackProvider));
    stack.add(cur);
    while (stack.length > 24) {
      stack.removeAt(0);
    }
    ref.read(kotvPageStackProvider.notifier).state = stack;
  }
  // 切主页面前硬停详情播放，避免后台出声。
  unawaited(DetailScreen.prepareLeave());
  // 切 Tab 时若有声明式弹窗则关掉，避免遮罩残留挡后续详情
  if (cur != page) {
    final post = PostMsgHost.instance;
    if (post != null && post.hasOpenDialog) {
      unawaited(post.cancelAll(reply: true));
    }
  }
  ref.read(kotvPageProvider.notifier).state = page;
}

/// 顶栏/遥控返回：有历史则回上一主页，否则回首页。
void kotvPageBack(WidgetRef ref) {
  final stack = List<KotvPage>.from(ref.read(kotvPageStackProvider));
  if (stack.isNotEmpty) {
    final prev = stack.removeLast();
    ref.read(kotvPageStackProvider.notifier).state = stack;
    goKotvPage(ref, prev, recordHistory: false);
    return;
  }
  goKotvPage(ref, KotvPage.video, recordHistory: false);
}

String remoteHint(WidgetRef ref) {
  final base = ref.read(engineLauncherProvider).baseUrl;
  return base.isEmpty ? 'http://127.0.0.1:9978' : base;
}
