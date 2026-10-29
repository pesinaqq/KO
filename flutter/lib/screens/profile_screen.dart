import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../util/runtime_info.dart';
import '../widgets/chrome.dart';
import '../widgets/config_branding.dart';
import '../widgets/dialogs.dart';
import '../widgets/poster_card.dart';
import 'detail_screen.dart';
import 'shell.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  List<VodItem> _recent = [];
  int _histCount = 0;
  int _keepCount = 0;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final hist = await LocalHistory.list();
    final keeps = await LocalCollect.list();
    if (!mounted) return;
    setState(() {
      _histCount = hist.length;
      _keepCount = keeps.length;
      // progressLabel：个人中心最近观看角标「继续观看」
      _recent = hist.take(15).map((e) {
        final r = e.remarks.trim();
        if (r.isNotEmpty && r != '继续观看') return e;
        return VodItem(id: e.id, name: e.name, pic: e.pic, remarks: '继续观看', site: e.site, typeName: e.typeName);
      }).toList();
    });
  }

  Future<void> _checkUpdate() async {
    setState(() => _status = '正在检查更新…');
    try {
      final data = await ref.read(apiProvider).tools('checkUpdate');
      final msg = '${data['message'] ?? '检查完成'}';
      setState(() => _status = msg);
      if (mounted) showAppNews(context, msg);
    } catch (e) {
      setState(() => _status = '检查失败: $e');
    }
  }

  Future<void> _showAbout() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final rt = <String, String>{
        for (final e in Map<String, dynamic>.from((st['runtime'] as Map?) ?? {}).entries)
          e.key: '${e.value ?? ''}',
      };
      final lines = <String>[
        'KO影视 Flutter ${st['version'] ?? '0.1.0'}',
        '引擎端口：${st['port'] ?? '9978'}',
        '',
        '运行时：',
        ...formatKotvRuntimeLines(rt).map((e) => '  $e'),
      ];
      if (mounted) showAppNews(context, lines.join('\n'));
    } catch (e) {
      if (mounted) showAppNews(context, '读取运行时失败: $e\n${remoteHint(ref)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final cfg = ref.watch(configProvider);
    final siteCount = cfg.maybeWhen(
      data: (c) => ((c['sites'] as List?) ?? []).length,
      orElse: () => 0,
    );
    final logoUrl = cfg.maybeWhen(data: (c) => '${c['logo'] ?? ''}'.trim(), orElse: () => '');
    final bottomNav = KotvLayout.useBottomNav(context);
    final compact = KotvLayout.isCompact(context);
    // 固定高度：不跟过小的 design scale 把用户信息挤爆
    final cardH = compact ? 200.0 : 128.0;
    final featureH = compact ? 72.0 : 104.0;
    final gap = compact ? 12.0 : 16.0;
    final sidePad = compact ? 12.0 : 28.0;
    final p = KotvPalette.of(context);

    Widget logoAvatar({required double radius}) => ConfigLogoAvatar(
          logoUrl: logoUrl,
          radius: radius,
          backgroundColor: p.variant,
          onTap: () => goKotvPage(ref, KotvPage.history),
        );

    Widget userHeader() {
      if (compact) {
        return Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: p.pillBg,
                borderRadius: BorderRadius.circular(14 * s),
                border: Border.all(color: p.pillBorder),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(14 * s, 12 * s, 14 * s, 12 * s),
                child: Row(
                  children: [
                    logoAvatar(radius: 28 * s),
                    SizedBox(width: 12 * s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('用户：本地用户', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.fg, fontSize: 17, fontWeight: FontWeight.w700, height: 1.15)),
                          const SizedBox(height: 4),
                          Text('版本：0.1.0 · 站源：$siteCount', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 13, height: 1.15)),
                          Text('历史 $_histCount · 收藏 $_keepCount', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted.withOpacity(0.85), fontSize: 12, height: 1.15)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: gap),
            Column(
              children: [
                SizedBox(
                  height: 72,
                  child: Row(
                    children: [
                      Expanded(
                        child: FeatureCard(
                          title: '设置',
                          subtitle: '播放器与源',
                          start: const Color(0xEE6E29CD),
                          end: const Color(0xEE3B19A7),
                          icon: Icons.settings,
                          height: 72,
                          onTap: () => goKotvPage(ref, KotvPage.settings),
                        ),
                      ),
                      SizedBox(width: gap),
                      Expanded(
                        child: FeatureCard(
                          title: '检查更新',
                          subtitle: '当前 0.1.0',
                          start: const Color(0xF0E5BA43),
                          end: const Color(0xF0B57928),
                          icon: Icons.download,
                          height: 72,
                          onTap: _checkUpdate,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: gap),
                FeatureCard(
                  title: '关于',
                  subtitle: '运行时信息',
                  start: const Color(0xEE49A7E9),
                  end: const Color(0xEE376EC5),
                  icon: Icons.info_outline,
                  height: 72,
                  onTap: _showAbout,
                ),
              ],
            ),
          ],
        );
      }
      return SizedBox(
        height: cardH,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.pillBg,
            borderRadius: BorderRadius.circular(14 * s),
            border: Border.all(color: p.pillBorder),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18 * s, 14 * s, 18 * s, 14 * s),
            child: Row(
              children: [
                Expanded(
                  flex: 34,
                  child: Row(
                    children: [
                      logoAvatar(radius: 30),
                      SizedBox(width: 12 * s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('用户：本地用户', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.fg, fontSize: 18, fontWeight: FontWeight.w700, height: 1.15)),
                            const SizedBox(height: 4),
                            Text('版本：0.1.0   站源：$siteCount 个', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 13, height: 1.15)),
                            const SizedBox(height: 2),
                            Text('历史 $_histCount 条 · 收藏 $_keepCount 个', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted.withOpacity(0.85), fontSize: 12, height: 1.15)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: gap),
                Expanded(
                  flex: 66,
                  child: Row(
                    children: [
                      Expanded(
                        child: FeatureCard(
                          title: '设置',
                          subtitle: '播放器与源配置',
                          start: const Color(0xEE6E29CD),
                          end: const Color(0xEE3B19A7),
                          icon: Icons.settings,
                          height: featureH,
                          onTap: () => goKotvPage(ref, KotvPage.settings),
                        ),
                      ),
                      SizedBox(width: gap),
                      Expanded(
                        child: FeatureCard(
                          title: '检查更新',
                          subtitle: '当前 0.1.0',
                          start: const Color(0xF0E5BA43),
                          end: const Color(0xF0B57928),
                          icon: Icons.download,
                          height: featureH,
                          onTap: _checkUpdate,
                        ),
                      ),
                      SizedBox(width: gap),
                      Expanded(
                        child: FeatureCard(
                          title: '关于',
                          subtitle: '运行时与组件信息',
                          start: const Color(0xEE49A7E9),
                          end: const Color(0xEE376EC5),
                          icon: Icons.info_outline,
                          height: featureH,
                          onTap: _showAbout,
                        ),
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

    return Column(
      children: [
        if (!bottomNav)
          Padding(
            padding: EdgeInsets.fromLTRB(sidePad, 18 * s, sidePad, 0),
            child: Row(
              children: [
                AppPill(label: '返回', width: compact ? 88 : 104, height: 40, onTap: () => kotvPageBack(ref)),
                SizedBox(width: 10 * s),
                AppPill(label: '搜索', width: compact ? 88 : 104, height: 40, onTap: () => goKotvPage(ref, KotvPage.search)),
                SizedBox(width: 10 * s),
                AppPill(label: '收藏', width: compact ? 88 : 104, height: 40, onTap: () => goKotvPage(ref, KotvPage.collect)),
                const Spacer(),
                Text('KO影视', style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
              ],
            ),
          )
        else
          Padding(
            padding: EdgeInsets.fromLTRB(sidePad, 14 * s, sidePad, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('我的', style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
            ),
          ),
        if (_status.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(sidePad, 8 * s, sidePad, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_status, style: TextStyle(color: p.muted, fontSize: 13)),
            ),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(sidePad, 14 * s, sidePad, 24 * s),
            children: [
              // 用户信息 + 功能卡（logo 来自接口；banner 仅用于首页轮播）
              userHeader(),
              SizedBox(height: 16 * s),
              if (compact)
                Wrap(
                  spacing: 10 * s,
                  runSpacing: 10 * s,
                  children: [
                    for (final e in [
                      ('历史记录', KotvPage.history),
                      ('我的收藏', KotvPage.collect),
                      ('设置', KotvPage.settings),
                      ('检测爬虫', KotvPage.settings),
                    ])
                      SizedBox(
                        width: (MediaQuery.sizeOf(context).width - sidePad * 2 - 10 * s) / 2,
                        child: AppPill(label: e.$1, height: 42, onTap: () => goKotvPage(ref, e.$2)),
                      ),
                    SizedBox(
                      width: (MediaQuery.sizeOf(context).width - sidePad * 2 - 10 * s) / 2,
                      child: AppPill(
                        label: '添加线路',
                        height: 42,
                        onTap: () async {
                          await showAddVodDialog(context, ref);
                          ref.invalidate(configProvider);
                          await _reload();
                        },
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  height: 46 * s,
                  child: Row(
                    children: [
                      for (final e in [
                        ('历史记录', KotvPage.history),
                        ('我的收藏', KotvPage.collect),
                        ('设置', KotvPage.settings),
                      ]) ...[
                        Expanded(child: AppPill(label: e.$1, height: 46, onTap: () => goKotvPage(ref, e.$2))),
                        SizedBox(width: 14 * s),
                      ],
                      Expanded(
                        child: AppPill(
                          label: '检测爬虫',
                          height: 46,
                          onTap: () {
                            goKotvPage(ref, KotvPage.settings);
                          },
                        ),
                      ),
                      SizedBox(width: 14 * s),
                      Expanded(
                        child: AppPill(
                          label: '添加线路',
                          height: 46,
                          onTap: () async {
                            await showAddVodDialog(context, ref);
                            ref.invalidate(configProvider);
                            await _reload();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              SizedBox(height: 16 * s),
              const SectionTitle('最近观看', subtitle: '点击继续播放'),
              SizedBox(height: 6 * s),
              if (_recent.isEmpty)
                Padding(
                  padding: EdgeInsets.all(24 * s),
                  child: Text('暂无观看记录', style: TextStyle(color: p.muted)),
                )
              else
                SizedBox(
                  height: compact ? 168.0 : 240.0,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.zero,
                    itemCount: _recent.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) {
                      final it = _recent[i];
                      final posterH = compact ? 168.0 : 240.0;
                      final posterW = posterH * 214 / 286;
                      return SizedBox(
                        width: posterW,
                        height: posterH,
                        child: PosterCard(
                          item: it,
                          onTap: () => Navigator.of(context).push(
                            kotvDetailRoute(builder: (_) => DetailScreen(id: it.id, site: it.site, title: it.name)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
