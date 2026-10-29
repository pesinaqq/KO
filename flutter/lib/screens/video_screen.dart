import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../widgets/chrome.dart';
import '../widgets/config_branding.dart';
import '../widgets/dialogs.dart';
import '../widgets/h_scroll.dart';
import '../widgets/poster_card.dart';
import 'detail_screen.dart';
import 'shell.dart';

class VideoScreen extends ConsumerStatefulWidget {
  const VideoScreen({super.key});

  @override
  ConsumerState<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends ConsumerState<VideoScreen> {
  String? _tid;
  int _page = 1;
  bool _loadingMore = false;
  final _items = <VodItem>[];
  List<CategoryType> _types = [];
  List<CategoryFilter> _filters = [];
  final Map<String, String> _extend = {};
  String? _statusMsg;
  bool _loading = true;
  bool _ready = false;
  int _bannerIdx = 0;
  Timer? _bannerTimer;
  List<ConfigBannerSlide> _apiBanners = [];
  String _apiBannerUrl = '';
  int _apiBannerLoadGen = 0;

  List<VodItem> _history = [];
  List<VodItem> _keeps = [];
  final ScrollController _scroll = ScrollController();
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    _bannerTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _tid != null) return;
      final n = _apiBanners.isNotEmpty ? _apiBanners.length : _bannerSlides.length;
      if (n < 2) return;
      setState(() => _bannerIdx = (_bannerIdx + 1) % n);
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  List<VodItem> get _bannerSlides {
    final withPic = _items.where((e) => e.pic.isNotEmpty).take(15).toList();
    if (withPic.isNotEmpty) return withPic;
    return _items.take(15).toList();
  }

  void _syncApiBanner(String url) {
    final next = url.trim();
    if (next == _apiBannerUrl) return;
    _apiBannerUrl = next;
    final gen = ++_apiBannerLoadGen;
    if (next.isEmpty) {
      if (_apiBanners.isNotEmpty && mounted) {
        setState(() {
          _apiBanners = [];
          _bannerIdx = 0;
        });
      }
      return;
    }
    unawaited(_loadApiBanner(next, gen));
  }

  Future<void> _loadApiBanner(String url, int gen) async {
    final slides = await fetchConfigBanners(url);
    if (!mounted || gen != _apiBannerLoadGen) return;
    setState(() {
      _apiBanners = slides;
      _bannerIdx = 0;
    });
  }

  void _onApiBannerTap(ConfigBannerSlide slide) {
    final q = slide.title.trim();
    if (q.isNotEmpty) {
      ref.read(pendingSearchProvider.notifier).state = q;
      goKotvPage(ref, KotvPage.search);
      return;
    }
    goKotvPage(ref, KotvPage.history);
  }

  Future<void> _refreshLocalMeta() async {
    final h = await LocalHistory.list();
    final k = await LocalCollect.list();
    if (!mounted) return;
    setState(() {
      _history = h;
      _keeps = k;
    });
  }

  Future<void> _bootstrap() async {
    await _refreshLocalMeta();
    await _reload();
  }

  /// 无点播源：source 空且错误像「未配置」。
  bool _isNoSourceConfig(Map<String, dynamic> cfg) {
    final source = '${cfg['source'] ?? ''}'.trim();
    if (source.isNotEmpty) return false;
    final err = '${cfg['error'] ?? ''}';
    return err.isEmpty || err.contains('未配置') || err.contains('点播源') || err.contains('请输入');
  }

  /// 等到 ready，或确认无源；有源加载中则继续等。
  Future<Map<String, dynamic>> _waitConfigReady({int maxAttempts = 80}) async {
    final api = ref.read(apiProvider);
    Map<String, dynamic> cfg = const {};
    for (var i = 0; i < maxAttempts; i++) {
      cfg = await api.getConfig();
      if (cfg['ready'] == true) return cfg;
      if (_isNoSourceConfig(cfg)) return cfg;
      final err = '${cfg['error'] ?? ''}'.trim();
      if (err.isNotEmpty) return cfg;
      if (i == 0 && mounted) {
        setState(() {
          _ready = false;
          _loading = true;
          _statusMsg = '正在加载点播源…';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return cfg;
  }

  Future<void> _reload({bool clearContent = false}) async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _statusMsg = null;
      _page = 1;
      _bannerIdx = 0;
      // 断线重试保留骨架；换仓/换站必须清空，避免旧海报残留
      if (clearContent) {
        _items.clear();
        _types = [];
        _filters = [];
      }
    });
    try {
      // 断线自动拉起引擎
      final launcher = ref.read(engineLauncherProvider);
      final up = await launcher.recoverIfNeeded();
      if (!up) {
        if (!mounted || gen != _loadGen) return;
        setState(() {
          _ready = false;
          _statusMsg = '无法连接 Go 引擎（:9978），请稍后点重试';
          _loading = false;
        });
        return;
      }

      final cfg = await _waitConfigReady();
      if (!mounted || gen != _loadGen) return;
      final ready = cfg['ready'] == true;
      // 刷新全局配置（壁纸等），避免 FutureProvider 缓存空 wallpaper
      ref.invalidate(configProvider);
      setState(() => _ready = ready);

      if (!ready) {
        final source = '${cfg['source'] ?? ''}'.trim();
        final err = '${cfg['error'] ?? ''}'.trim();
        setState(() {
          _types = [];
          _filters = [];
          _items.clear();
          _loading = false;
          // 有源却未 ready：显示错误/重试，不要伪装成「未配置」
          _statusMsg = source.isEmpty
              ? null
              : (err.isNotEmpty ? err : '点播源加载超时，请重试');
        });
        return;
      }

      final api = ref.read(apiProvider);
      final data = _tid == null || _tid!.isEmpty
          ? await api.home()
          : await api.category(_tid!, pg: '1', extend: Map<String, String>.from(_extend));
      if (!mounted || gen != _loadGen) return;
      _applyPage(data, replace: true);
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      final msg = '$e';
      if (msg.contains('Connection refused') || msg.contains('SocketException')) {
        final ok = await ref.read(engineLauncherProvider).recoverIfNeeded();
        if (ok) {
          try {
            final api = ref.read(apiProvider);
            final data = _tid == null || _tid!.isEmpty
                ? await api.home()
                : await api.category(_tid!, pg: '1', extend: Map<String, String>.from(_extend));
            if (!mounted || gen != _loadGen) return;
            _applyPage(data, replace: true);
            setState(() => _statusMsg = null);
            return;
          } catch (e2) {
            if (!mounted || gen != _loadGen) return;
            setState(() => _statusMsg = '$e2');
            return;
          }
        }
      }
      setState(() => _statusMsg = msg);
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  /// loadCategory：先切导航/清空列表，再异步加载。
  void _switchCategory(String? tid) {
    final filters = <CategoryFilter>[];
    if (tid != null && tid.isNotEmpty) {
      for (final t in _types) {
        if (t.id == tid && t.filters.isNotEmpty) {
          filters.addAll(t.filters);
          break;
        }
      }
    }
    setState(() {
      _tid = tid;
      _extend.clear();
      _filters = filters;
      for (final f in _filters) {
        _extend[f.key] = f.init.isNotEmpty ? f.init : (f.values.isNotEmpty ? f.values.first.value : '');
      }
      _items.clear();
      _page = 1;
      _bannerIdx = 0;
      _loading = true;
      _loadingMore = false;
      _statusMsg = null;
    });
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    unawaited(_reload());
  }

  /// 筛选 chip：先更新选中态并清空瀑布流，再加载。
  void _switchFilter(String key, String value) {
    if ((_extend[key] ?? '') == value) return;
    setState(() {
      _extend[key] = value;
      _items.clear();
      _page = 1;
      _loading = true;
      _loadingMore = false;
      _statusMsg = null;
    });
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    unawaited(_reload());
  }

  Future<void> _loadMore() async {
    if (_tid == null || _tid!.isEmpty || _loadingMore || _loading || !_ready) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await ref.read(apiProvider).category(_tid!, pg: '$next', extend: Map<String, String>.from(_extend));
      _page = next;
      _applyPage(data, replace: false);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _applyPage(Map<String, dynamic> data, {required bool replace}) {
    try {
      final list = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final types = ((data['class'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => CategoryType.fromJson(Map<String, dynamic>.from(e)))
          .where((t) => t.id.isNotEmpty && t.id != 'home' && t.name != '首页' && t.name != '推荐')
          .toList();
      final filters = ((data['filters'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => CategoryFilter.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      setState(() {
        _statusMsg = null;
        if (types.isNotEmpty) {
          _types = types;
        } else if (replace && (_tid == null || _tid!.isEmpty)) {
          _types = [];
        }
        if (_tid != null && _tid!.isNotEmpty) {
          if (filters.isNotEmpty) {
            _filters = filters;
          } else {
            for (final t in _types) {
              if (t.id == _tid && t.filters.isNotEmpty) {
                _filters = t.filters;
                break;
              }
            }
          }
          for (final f in _filters) {
            _extend.putIfAbsent(f.key, () => f.init.isNotEmpty ? f.init : (f.values.isNotEmpty ? f.values.first.value : ''));
          }
        } else {
          _filters = [];
          _extend.clear();
        }
        if (replace) {
          _items
            ..clear()
            ..addAll(list);
        } else {
          _items.addAll(list);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMsg = '页面数据异常: $e');
    }
  }

  void _open(VodItem it) {
    LocalHistory.push(it);
    Navigator.of(context).push(kotvDetailRoute(
      builder: (_) => DetailScreen(id: it.id, site: it.site, title: it.name),
    ));
  }

  Future<void> _openSitePicker(List<SiteInfo> sites) async {
    if (sites.isEmpty) {
      await showAddVodDialog(context, ref);
      await _reload();
      return;
    }
    await showSitePicker(
      context,
      ref,
      sites: sites,
      onSelect: (key) async {
        final name = () {
          for (final s in sites) {
            if (s.key == key) return s.name;
          }
          return key;
        }();
        // 换源前先硬停详情播放，再清栈，避免后台继续出声。
        await DetailScreen.prepareLeave();
        final nav = Navigator.of(context);
        if (nav.canPop()) {
          nav.popUntil((r) => r.isFirst);
        }
        // 只保留全局遮罩一层转圈，避免与页内 spinner 叠两层
        ref.read(uiBusyProvider.notifier).state = '正在切换到 $name…';
        setState(() {
          _tid = null;
          _extend.clear();
          _filters = [];
          _types = [];
          _items.clear();
          _statusMsg = null;
        });
        try {
          await ref.read(apiProvider).setHome(key);
          ref.invalidate(configProvider);
          ref.invalidate(settingsProvider);
          await _reload(clearContent: true);
        } catch (e) {
          if (mounted) setState(() => _statusMsg = '切换失败: $e');
        } finally {
          ref.read(uiBusyProvider.notifier).state = null;
        }
      },
    );
  }

  Future<void> _addSource() async {
    await showAddVodDialog(context, ref);
    await _refreshLocalMeta();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    try {
      return _buildRoot(context);
    } catch (e, st) {
      debugPrint('VideoScreen build error: $e\n$st');
      final p = KotvPalette.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: p.primary, size: 40),
              const SizedBox(height: 12),
              Text('首页渲染出错', style: TextStyle(color: p.fg, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('$e', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 12)),
              const SizedBox(height: 16),
              AppPill(label: '重试', width: 100, onTap: () => _reload(clearContent: true)),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildRoot(BuildContext context) {
    final cfg = ref.watch(configProvider);
    final sites = cfg.maybeWhen(
      data: (c) {
        try {
          return ((c['sites'] as List?) ?? [])
              .whereType<Map>()
              .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        } catch (_) {
          return <SiteInfo>[];
        }
      },
      orElse: () => <SiteInfo>[],
    );
    SiteInfo? home;
    for (final s in sites) {
      if (s.home) {
        home = s;
        break;
      }
    }
    home ??= sites.isEmpty ? null : sites.first;
    final cfgSource = cfg.maybeWhen(data: (c) => '${c['source'] ?? ''}'.trim(), orElse: () => '');
    final cfgReady = cfg.maybeWhen(data: (c) => c['ready'] == true, orElse: () => false);
    final ready = _ready || cfgReady;
    // 有源但尚未 ready：显示加载，而不是「请先添加点播源」
    final loadingSource = !ready && (_loading || cfgSource.isNotEmpty || (_statusMsg ?? '').contains('加载'));
    final siteName = !ready
        ? (loadingSource ? '加载中…' : '未配置源')
        : ((home != null && home.name.isNotEmpty)
            ? home.name
            : cfg.maybeWhen(data: (c) => c['ready'] == true ? '选站' : '未配置源', orElse: () => '…') ?? '未配置源');
    final busy = ref.watch(uiBusyProvider);
    final onHome = (_tid ?? '').isEmpty;

    return Column(
      children: [
        TopStatusBar(
          siteName: siteName,
          onRepo: () async {
            final switched = await showRepoPicker(context, ref);
            if (!switched || !mounted) return;
            setState(() {
              _tid = null;
              _extend.clear();
              _filters = [];
              _types = [];
              _items.clear();
              _statusMsg = null;
            });
            // 多仓切换已有全局遮罩；内容必须清空后再拉，避免旧仓海报残留
            await _reload(clearContent: true);
          },
          onSite: () => _openSitePicker(sites),
          onSettings: () => goKotvPage(ref, KotvPage.settings),
          onNews: () => showAppNews(context, remoteHint(ref)),
        ),
        // 未就绪不画分类导航
        if (ready)
          CategoryNavBar(
            homeLabel: onHome ? '换源' : '首页',
            homeSelected: onHome,
            onHome: () {
              if (onHome) {
                _openSitePicker(sites);
              } else {
                _switchCategory(null);
              }
            },
            categories: [for (final t in _types) (id: t.id, name: t.name)],
            selectedTid: _tid,
            onCategory: (tid) => _switchCategory(tid),
          ),
        if (ready && !onHome && _filters.isNotEmpty) _buildFilters(),
        if (ready && _statusMsg != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(_statusMsg ?? '', style: TextStyle(color: KotvPalette.of(context).muted, fontSize: 13)),
                ),
                AppPill(label: '重试', width: 88, height: 32, fontSize: 13, onTap: _reload),
              ],
            ),
          ),
        Expanded(
          child: !ready
              ? (loadingSource ? _buildLoadingSource() : _buildNotReady())
              : _buildBody(),
        ),
        // 有全局遮罩时不再画底栏进度条，避免两层转圈
        if (busy == null && (_loading || _loadingMore))
          const LinearProgressIndicator(minHeight: 2, color: Color(0xFFCF4274)),
      ],
    );
  }

  Widget _buildLoadingSource() {
    final p = KotvPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFFCF4274)),
          ),
          const SizedBox(height: 16),
          Text('正在加载点播源…', style: TextStyle(color: p.fg, fontSize: 18, fontWeight: FontWeight.w700)),
          if ((_statusMsg ?? '').isNotEmpty && !(_statusMsg ?? '').contains('正在加载')) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_statusMsg!, textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 13)),
            ),
            const SizedBox(height: 14),
            AppPill(label: '重试', width: 100, onTap: () => _reload(clearContent: true)),
          ],
        ],
      ),
    );
  }

  Widget _buildNotReady() {
    final p = KotvPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('请先添加点播源', style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('粘贴配置 URL 或 JSON，即可开始大屏观影', style: TextStyle(color: p.muted)),
          const SizedBox(height: 16),
          AppPill(label: '添加点播源', width: 160, autofocus: true, onTap: _addSource),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final compact = KotvLayout.isCompact(context);
    final p = KotvPalette.of(context);
    final padH = compact ? 10.0 : 24.0;
    // 标签仅两字宽，桌面 72 会造成与胶囊之间大片空档
    final labelW = compact ? 36.0 : 44.0;
    final pillW = compact ? null : 88.0;
    final pillH = compact ? 28.0 : 36.0;
    final pillFs = compact ? 12.0 : 13.0;
    final sepW = compact ? 4.0 : 8.0;
    return Container(
      padding: EdgeInsets.fromLTRB(padH, 4, padH, 4),
      child: Column(
        children: [
          for (final f in _filters)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: labelW,
                    child: Text(
                      f.name,
                      style: TextStyle(
                        color: p.fg.withOpacity(p.light ? 0.72 : 0.78),
                        fontSize: compact ? 12 : 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: pillH,
                      child: HScrollList(
                        itemCount: f.values.length,
                        separatorBuilder: (_, __) => SizedBox(width: sepW),
                        itemBuilder: (_, i) {
                          final v = f.values[i];
                          final sel = (_extend[f.key] ?? '') == v.value;
                          return AppPill(
                            label: v.name,
                            width: pillW,
                            height: pillH,
                            fontSize: pillFs,
                            selected: sel,
                            onTap: () => _switchFilter(f.key, v.value),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final busy = ref.watch(uiBusyProvider);
    // 全局遮罩已在转圈时，页内不再叠第二个 spinner
    if (busy == null && _loading && _items.isEmpty && _types.isEmpty) {
      return Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary));
    }

    final onHome = (_tid ?? '').isEmpty;
    final pad = KotvLayout.isCompact(context) ? 12.0 : 30.0;
    final catPad = KotvLayout.isCompact(context) ? 16.0 : 60.0;
    final bottomPad = 24.0;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (!onHome && n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
        return false;
      },
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (onHome) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad * LayoutScale.of(context), 10 * LayoutScale.of(context), pad * LayoutScale.of(context), 0),
                child: _buildHomeFeatureGrid(),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: 16 * LayoutScale.of(context))),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad * LayoutScale.of(context)),
                child: const SectionTitle('为你推荐', subtitle: '来自当前站源的热门内容'),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: 10 * LayoutScale.of(context))),
            if (_items.isEmpty && _loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary)),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad * LayoutScale.of(context), 0, pad * LayoutScale.of(context), bottomPad * LayoutScale.of(context)),
                sliver: _posterSliver(_items),
              ),
          ] else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(catPad, 10, catPad, 0),
                child: SectionTitle(
                  _types.where((t) => t.id == _tid).map((t) => t.name).firstOrNull ?? '分类',
                  subtitle: '发现更多精彩内容',
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            if (_items.isEmpty && _loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary)),
              )
            else if (_items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(child: Text('暂无内容', style: TextStyle(color: KotvPalette.of(context).muted))),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(catPad, 0, catPad, bottomPad),
                sliver: _posterSliver(_items),
              ),
          ],
        ],
      ),
    );
  }

  /// 对齐参考图：四列等宽网格。
  /// 左上两卡与下方四卡完全同宽同高；轮播 = 右三列 × 两行高。
  /// 有接口 banner 时只替换轮播内容，功能卡布局不变。
  Widget _buildHomeFeatureGrid() {
    final bannerUrl = ref.watch(configProvider).maybeWhen(
          data: (c) => '${c['banner'] ?? ''}'.trim(),
          orElse: () => '',
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncApiBanner(bannerUrl);
    });

    final useApi = _apiBanners.isNotEmpty;
    final apiCur = useApi ? _apiBanners[_bannerIdx.clamp(0, 1 << 30) % _apiBanners.length] : null;
    final slides = _bannerSlides;
    final cur = slides.isEmpty ? null : slides[_bannerIdx.clamp(0, 1 << 30) % slides.length];
    final bottomNav = KotvLayout.useBottomNav(context);
    final compact = KotvLayout.isCompact(context);

    final continueSub = _history.isEmpty
        ? (compact ? '暂无记录' : '暂无观看记录')
        : _ellipsize(_history.first.name, compact ? 8 : 14);
    final keepSub = _keeps.isEmpty
        ? (compact ? '收藏夹' : '喜欢的东西都在这里')
        : (compact ? '${_keeps.length} 个收藏' : '${_keeps.length} 个收藏内容');
    final histSub = _history.isEmpty
        ? (compact ? '暂无历史' : '你看过的都在这里')
        : (compact ? '${_history.length} 条记录' : '${_history.length} 条最近记录');

    Widget feature({
      required String title,
      required String subtitle,
      required Color start,
      required Color end,
      required IconData icon,
      required VoidCallback onTap,
      required double h,
    }) {
      return FeatureCard(
        title: title,
        subtitle: subtitle,
        start: start,
        end: end,
        icon: icon,
        height: h,
        onTap: onTap,
      );
    }

    final bannerCount = useApi ? _apiBanners.length : slides.length;
    final bannerTitle = useApi ? (apiCur?.title ?? '') : (cur?.name ?? '暂无推荐内容');
    final bannerSub = useApi
        ? (apiCur == null ? '配置源后这里会轮播推荐' : '点击搜索相关内容')
        : ((cur != null && cur.remarks.isNotEmpty)
            ? cur.remarks
            : (cur == null ? '配置源后这里会轮播推荐' : '点击查看详情并播放'));
    final bannerPic = useApi ? (apiCur?.image ?? '') : (cur?.pic ?? '');
    final bannerEmptyTitle = useApi ? '正在加载推荐…' : '暂无推荐内容';

    Widget banner(double radius) => TvFocus(
          onPressed: useApi
              ? () {
                  if (apiCur != null) _onApiBannerTap(apiCur);
                }
              : (cur == null ? () {} : () => _open(cur)),
          borderRadius: radius,
          child: GestureDetector(
            onTap: useApi
                ? (apiCur == null ? null : () => _onApiBannerTap(apiCur))
                : (cur == null ? null : () => _open(cur)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF652291)),
                  if (_isHttpUrl(bannerPic))
                    Image.network(bannerPic, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 40,
                    child: Text(
                      bannerTitle.isNotEmpty ? bannerTitle : bannerEmptyTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 8, offset: Offset(0, 1))],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 64,
                    bottom: 14,
                    child: Text(
                      bannerSub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.92),
                        fontSize: 13,
                        height: 1.15,
                        shadows: const [Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1))],
                      ),
                    ),
                  ),
                  if (bannerCount > 0)
                    Positioned(
                      right: 14,
                      bottom: 14,
                      child: Text(
                        '${(bannerCount == 0 ? 0 : (_bannerIdx % bannerCount) + 1)}/$bannerCount',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );

    // 竖屏：轮播 + 下方两列功能卡
    if (bottomNav || compact) {
      final gap = 10.0;
      final cardH = 76.0;
      final actions = <Widget>[
        feature(
          title: '继续观看',
          subtitle: continueSub,
          start: const Color(0xF2E46643),
          end: const Color(0xF2DB4F45),
          icon: Icons.replay,
          h: cardH,
          onTap: () {
            if (_history.isNotEmpty) {
              _open(_history.first);
            } else {
              goKotvPage(ref, KotvPage.history);
            }
          },
        ),
        feature(
          title: '收藏',
          subtitle: keepSub,
          start: const Color(0xF2D55999),
          end: const Color(0xF2C04DA4),
          icon: Icons.check_circle_outline,
          h: cardH,
          onTap: () => goKotvPage(ref, KotvPage.collect),
        ),
        feature(
          title: '历史记录',
          subtitle: histSub,
          start: const Color(0xF25598D8),
          end: const Color(0xF24C7EC7),
          icon: Icons.access_time,
          h: cardH,
          onTap: () => goKotvPage(ref, KotvPage.history),
        ),
      ];
      return Column(
        children: [
          SizedBox(height: 150, child: banner(10)),
          SizedBox(height: gap),
          for (var i = 0; i < actions.length; i += 2) ...[
            if (i > 0) SizedBox(height: gap),
            SizedBox(
              height: cardH,
              child: Row(
                children: [
                  Expanded(child: actions[i]),
                  if (i + 1 < actions.length) ...[
                    SizedBox(width: gap),
                    Expanded(child: actions[i + 1]),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final gap = 16.0;
        final w = c.maxWidth;
        // 四列等宽：左列宽 = 下方每张卡宽
        final cardW = ((w - gap * 3) / 4).clamp(48.0, 400.0);
        // 卡高略小于宽，接近参考图比例
        final cardH = (cardW * 0.52).clamp(100.0, 132.0);
        final heroH = cardH * 2 + gap;

        Widget cell(Widget child) => SizedBox(width: cardW, height: cardH, child: child);

        return Column(
          children: [
            SizedBox(
              height: heroH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: cardW,
                    child: Column(
                      children: [
                        cell(feature(
                          title: '搜索',
                          subtitle: '搜索一下，看尽天下',
                          start: const Color(0xF26742D1),
                          end: const Color(0xF24D2BB5),
                          icon: Icons.search,
                          h: cardH,
                          onTap: () => goKotvPage(ref, KotvPage.search),
                        )),
                        SizedBox(height: gap),
                        cell(feature(
                          title: '个人中心',
                          subtitle: '管理收藏与播放记录',
                          start: const Color(0xF6E8C158),
                          end: const Color(0xF6D2A240),
                          icon: Icons.person_outline,
                          h: cardH,
                          onTap: () => goKotvPage(ref, KotvPage.profile),
                        )),
                      ],
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(child: banner(14)),
                ],
              ),
            ),
            SizedBox(height: gap),
            SizedBox(
              height: cardH,
              child: Row(
                children: [
                  cell(feature(
                    title: '继续观看',
                    subtitle: continueSub,
                    start: const Color(0xF2E46643),
                    end: const Color(0xF2DB4F45),
                    icon: Icons.replay,
                    h: cardH,
                    onTap: () {
                      if (_history.isNotEmpty) {
                        _open(_history.first);
                      } else {
                        goKotvPage(ref, KotvPage.history);
                      }
                    },
                  )),
                  SizedBox(width: gap),
                  cell(feature(
                    title: '收藏',
                    subtitle: keepSub,
                    start: const Color(0xF2D55999),
                    end: const Color(0xF2C04DA4),
                    icon: Icons.check_circle_outline,
                    h: cardH,
                    onTap: () => goKotvPage(ref, KotvPage.collect),
                  )),
                  SizedBox(width: gap),
                  cell(feature(
                    title: '历史记录',
                    subtitle: histSub,
                    start: const Color(0xF25598D8),
                    end: const Color(0xF24C7EC7),
                    icon: Icons.access_time,
                    h: cardH,
                    onTap: () => goKotvPage(ref, KotvPage.history),
                  )),
                  SizedBox(width: gap),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _posterSliver(List<VodItem> items) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final compact = KotvLayout.isCompact(context);
        // 列数按逻辑宽度算，避免 scale 越小列越多、海报被压成扁条
        // 窄屏固定 3 列，不再按 cell 宽度计算（竖屏宽度有限，避免只出 2 列）
        final gap = compact ? 6.0 : 10.0;
        final extent = constraints.crossAxisExtent;
        final cross = !extent.isFinite || extent <= 0
            ? (compact ? 3 : 4)
            : (compact ? 3 : (extent / (200.0 + gap)).floor().clamp(3, 5));
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: 214 / 286,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i < 0 || i >= items.length) return const SizedBox.shrink();
              final it = items[i];
              return PosterCard(
                item: it,
                autofocus: false,
                onTap: () => _open(it),
              );
            },
            childCount: items.length,
          ),
        );
      },
    );
  }

  String _ellipsize(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static bool _isHttpUrl(String s) {
    final t = s.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
