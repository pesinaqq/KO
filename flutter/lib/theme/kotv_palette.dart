import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// 壁纸主题中文名（与引擎 wallMode 对齐）。
const kotvWallModeNames = <String, String>{
  'gradient': '极光紫',
  'config': '配置墙纸',
  'url': '网络图片',
  'file': '本地文件',
  'builtin1': '深海蓝',
  'builtin2': '绯霞玫',
  'builtin3': '墨夜青',
};

/// 系统外观（跟随系统时用）；由 [KotvApp] 监听平台变化写入。
final platformBrightnessProvider = StateProvider<Brightness>((ref) {
  return WidgetsBinding.instance.platformDispatcher.platformBrightness;
});

/// 从引擎 backdrop 解析出的 UI 色板；卡片/顶栏/字体统一读这里。
@immutable
class KotvPalette extends ThemeExtension<KotvPalette> {
  const KotvPalette({
    required this.mode,
    required this.name,
    required this.light,
    required this.primary,
    required this.surface,
    required this.variant,
    required this.fg,
    required this.muted,
    required this.outline,
    required this.input,
    required this.pillBg,
    required this.pillBorder,
    required this.statusBar,
    required this.catBar,
    required this.bottomNav,
    required this.dialogBg,
    required this.posterBar,
    required this.posterPh,
    required this.selected,
    required this.focus,
    required this.gradStart,
    required this.gradEnd,
    required this.glowTop,
    required this.glowBottom,
    required this.glowMid,
    required this.wallTint,
  });

  final String mode;
  final String name;
  final bool light;
  final Color primary;
  final Color surface;
  final Color variant;
  final Color fg;
  final Color muted;
  final Color outline;
  final Color input;
  final Color pillBg;
  final Color pillBorder;
  final Color statusBar;
  final Color catBar;
  final Color bottomNav;
  final Color dialogBg;
  final Color posterBar;
  final Color posterPh;
  final Color selected;
  final Color focus;
  final Color gradStart;
  final Color gradEnd;
  final Color glowTop;
  final Color glowBottom;
  final Color glowMid;
  final Color wallTint;

  static const defaults = KotvPalette(
    mode: 'gradient',
    name: '极光紫',
    light: false,
    primary: Color(0xFFD84B82),
    surface: Color(0xFF63248A),
    variant: Color(0xFF653AA8),
    fg: Color(0xFFFFFFFF),
    muted: Color(0xD8FFFFFF),
    outline: Color(0xB0D8A5E8),
    input: Color(0xB3582D91),
    pillBg: Color(0x9918161E),
    pillBorder: Color(0xA04A4855),
    statusBar: Color(0x70471A66),
    catBar: Color(0x553B1A6E),
    bottomNav: Color(0xA60F0A1E),
    dialogBg: Color(0xF2241740),
    posterBar: Color(0xCC411A70),
    posterPh: Color(0xFF2E1258),
    selected: Color(0xD9C73C62),
    focus: Color(0xFFFFD54F),
    gradStart: Color(0xFF1E3BC9),
    gradEnd: Color(0xFF9E1CA4),
    glowTop: Color(0x35FF55CB),
    glowBottom: Color(0x3028C9FF),
    glowMid: Color(0x288D50F2),
    wallTint: Color(0x55120832),
  );

  static KotvPalette of(BuildContext context) =>
      Theme.of(context).extension<KotvPalette>() ?? defaults;

  static Color _c(int argb) => Color(argb);

  /// 按 wallMode + 深/浅 本地生成完整色板（跟随系统时不依赖引擎写死的 light=false）。
  static KotvPalette resolve(String mode, bool light) {
    mode = mode.trim().isEmpty ? 'gradient' : mode.trim();
    final name = kotvWallModeNames[mode] ?? '极光紫';

    // 默认极光紫 / 配置墙纸 / 网络 / 本地：同一套 UI 色
    // 浅色：顶栏/分类栏高不透明，海报底栏用浅霜白底 + 深色字，避免壁纸透底导致发灰看不清
    var p = light
        ? const KotvPalette(
            mode: 'gradient',
            name: '极光紫',
            light: true,
            primary: Color(0xFF1A2A6C),
            surface: Color(0xFFE9EEFB),
            variant: Color(0xFFB994F5),
            fg: Color(0xFF14141C),
            muted: Color(0xFF3A3B48),
            outline: Color(0x99767680),
            input: Color(0xCCDDE2FF),
            pillBg: Color(0xA6FFFFFF),
            pillBorder: Color(0x99767680),
            statusBar: Color(0xD0F4F6FC),
            catBar: Color(0xC8EEF0F8),
            bottomNav: Color(0xB3FCF8FF),
            dialogBg: Color(0xE0FCF8FF),
            posterBar: Color(0xE6FFFFFF),
            posterPh: Color(0xFFD0C8E8),
            selected: Color(0xD9C73C62),
            focus: Color(0xFF1A2A6C),
            gradStart: Color(0xFFE9EEFB),
            gradEnd: Color(0xFFF3E7F8),
            glowTop: Color(0x2EFF8AC8),
            glowBottom: Color(0x2A7AC8FF),
            glowMid: Color(0x24B994F5),
            wallTint: Color(0x66FFFFFF),
          )
        : defaults;

    switch (mode) {
      case 'builtin1':
        p = light
            ? p.copyWith(
                mode: mode,
                name: name,
                light: true,
                primary: _c(0xFF156B8A),
                surface: _c(0xFFC8E0F2),
                variant: _c(0xFF4FC3F7),
                fg: _c(0xFF0A2A40),
                muted: _c(0xE00E3A5C),
                outline: _c(0x99156B8A),
                input: _c(0xCCE8F4FC),
                pillBg: _c(0xA6FFFFFF),
                pillBorder: _c(0x992E86AB),
                statusBar: _c(0xF0E8F4FC),
                catBar: _c(0xE8D8ECF5),
                bottomNav: _c(0xB3F2F8FC),
                dialogBg: _c(0xE0E8F4FC),
                posterBar: _c(0xF2FFFFFF),
                posterPh: _c(0xFFB0D4E8),
                selected: _c(0xD92E86AB),
                focus: _c(0xFF156B8A),
                gradStart: _c(0xFFDDEEFA),
                gradEnd: _c(0xFFC8E0F2),
                glowTop: _c(0x304FC3F7),
                glowBottom: _c(0x28156B8A),
                glowMid: _c(0x252E86AB),
                wallTint: _c(0x66FFFFFF),
              )
            : p.copyWith(
                mode: mode,
                name: name,
                light: false,
                primary: _c(0xFF4FC3F7),
                surface: _c(0xFF156B8A),
                variant: _c(0xFF2E86AB),
                fg: _c(0xFFFFFFFF),
                muted: _c(0xD8FFFFFF),
                outline: _c(0x904FC3F7),
                input: _c(0xB30E3A5C),
                pillBg: _c(0x990A2438),
                pillBorder: _c(0x884FC3F7),
                statusBar: _c(0x600E3A5C),
                catBar: _c(0x4D1A5C8A),
                bottomNav: _c(0x8C0A1E2E),
                dialogBg: _c(0xE00E3A5C),
                posterBar: _c(0xCC156B8A),
                posterPh: _c(0xFF0E3A5C),
                selected: _c(0xD92E86AB),
                focus: _c(0xFF4FC3F7),
                gradStart: _c(0xFF1A5C8A),
                gradEnd: _c(0xFF0E3A5C),
                glowTop: _c(0x304FC3F7),
                glowBottom: _c(0x28156B8A),
                glowMid: _c(0x252E86AB),
                wallTint: _c(0x55120832),
              );
      case 'builtin2':
        p = light
            ? p.copyWith(
                mode: mode,
                name: name,
                light: true,
                primary: _c(0xFFC73C62),
                surface: _c(0xFFF7E3F2),
                variant: _c(0xFFE86A83),
                fg: _c(0xFF3A1028),
                muted: _c(0xE05A1A3A),
                outline: _c(0x99C73C62),
                input: _c(0xCCFFF0F5),
                pillBg: _c(0xA6FFFFFF),
                pillBorder: _c(0x99E86A83),
                statusBar: _c(0xF0FFF0F5),
                catBar: _c(0xE8F5E0EA),
                bottomNav: _c(0xB3FFF5F8),
                dialogBg: _c(0xE0FFF0F5),
                posterBar: _c(0xF2FFFFFF),
                posterPh: _c(0xFFE8B0C0),
                selected: _c(0xD9C73C62),
                focus: _c(0xFFE91E63),
                gradStart: _c(0xFFF7E3F2),
                gradEnd: _c(0xFFFBE0E6),
                glowTop: _c(0x32FF8A65),
                glowBottom: _c(0x28E91E63),
                glowMid: _c(0x22FF6F91),
                wallTint: _c(0x66FFFFFF),
              )
            : p.copyWith(
                mode: mode,
                name: name,
                light: false,
                primary: _c(0xFFFF6F91),
                surface: _c(0xFF7B2D8E),
                variant: _c(0xFFC73C62),
                fg: _c(0xFFFFFFFF),
                muted: _c(0xD8FFFFFF),
                outline: _c(0xB0FF8AA5),
                input: _c(0xB35A2068),
                pillBg: _c(0x991A0C22),
                pillBorder: _c(0xC8E86A83),
                statusBar: _c(0x60551C48),
                catBar: _c(0x4D7B2D8E),
                bottomNav: _c(0x8C1A0A1E),
                dialogBg: _c(0xE05A2068),
                posterBar: _c(0xCCC73C62),
                posterPh: _c(0xFF4A1848),
                selected: _c(0xD9C73C62),
                focus: _c(0xFFFF8A65),
                gradStart: _c(0xFF7B2D8E),
                gradEnd: _c(0xFFC73C62),
                glowTop: _c(0x32FF8A65),
                glowBottom: _c(0x28E91E63),
                glowMid: _c(0x22FF6F91),
                wallTint: _c(0x55120832),
              );
      case 'builtin3':
        p = light
            ? p.copyWith(
                mode: mode,
                name: name,
                light: true,
                primary: _c(0xFF266E8C),
                surface: _c(0xFFD5E4E8),
                variant: _c(0xFF4DA8DA),
                fg: _c(0xFF0A1822),
                muted: _c(0xE00F202E),
                outline: _c(0x99266E8C),
                input: _c(0xCCE8F0F2),
                pillBg: _c(0xA6FFFFFF),
                pillBorder: _c(0x994DA8DA),
                statusBar: _c(0xF0E8F0F2),
                catBar: _c(0xE8D8E6EA),
                bottomNav: _c(0xB3F0F4F6),
                dialogBg: _c(0xE0E8F0F2),
                posterBar: _c(0xF2FFFFFF),
                posterPh: _c(0xFFB0C8D0),
                selected: _c(0xD94DA8DA),
                focus: _c(0xFF266E8C),
                gradStart: _c(0xFFE2EEEE),
                gradEnd: _c(0xFFD5E4E8),
                glowTop: _c(0x2880CBC4),
                glowBottom: _c(0x224DA8DA),
                glowMid: _c(0x20266E8C),
                wallTint: _c(0x66FFFFFF),
              )
            : p.copyWith(
                mode: mode,
                name: name,
                light: false,
                primary: _c(0xFF80CBC4),
                surface: _c(0xFF203A43),
                variant: _c(0xFF4DA8DA),
                fg: _c(0xFFFFFFFF),
                muted: _c(0xD8FFFFFF),
                outline: _c(0x9080CBC4),
                input: _c(0xB3152830),
                pillBg: _c(0x990A141C),
                pillBorder: _c(0x884DA8DA),
                statusBar: _c(0x600F202E),
                catBar: _c(0x4D203A43),
                bottomNav: _c(0x8C0A1218),
                dialogBg: _c(0xE0152830),
                posterBar: _c(0xCC203A43),
                posterPh: _c(0xFF0F202E),
                selected: _c(0xD94DA8DA),
                focus: _c(0xFF80CBC4),
                gradStart: _c(0xFF0F202E),
                gradEnd: _c(0xFF203A43),
                glowTop: _c(0x2880CBC4),
                glowBottom: _c(0x224DA8DA),
                glowMid: _c(0x20266E8C),
                wallTint: _c(0x55120832),
              );
      default:
        p = p.copyWith(mode: mode, name: name, light: light);
    }
    return p;
  }

  @override
  KotvPalette copyWith({
    String? mode,
    String? name,
    bool? light,
    Color? primary,
    Color? surface,
    Color? variant,
    Color? fg,
    Color? muted,
    Color? outline,
    Color? input,
    Color? pillBg,
    Color? pillBorder,
    Color? statusBar,
    Color? catBar,
    Color? bottomNav,
    Color? dialogBg,
    Color? posterBar,
    Color? posterPh,
    Color? selected,
    Color? focus,
    Color? gradStart,
    Color? gradEnd,
    Color? glowTop,
    Color? glowBottom,
    Color? glowMid,
    Color? wallTint,
  }) {
    return KotvPalette(
      mode: mode ?? this.mode,
      name: name ?? this.name,
      light: light ?? this.light,
      primary: primary ?? this.primary,
      surface: surface ?? this.surface,
      variant: variant ?? this.variant,
      fg: fg ?? this.fg,
      muted: muted ?? this.muted,
      outline: outline ?? this.outline,
      input: input ?? this.input,
      pillBg: pillBg ?? this.pillBg,
      pillBorder: pillBorder ?? this.pillBorder,
      statusBar: statusBar ?? this.statusBar,
      catBar: catBar ?? this.catBar,
      bottomNav: bottomNav ?? this.bottomNav,
      dialogBg: dialogBg ?? this.dialogBg,
      posterBar: posterBar ?? this.posterBar,
      posterPh: posterPh ?? this.posterPh,
      selected: selected ?? this.selected,
      focus: focus ?? this.focus,
      gradStart: gradStart ?? this.gradStart,
      gradEnd: gradEnd ?? this.gradEnd,
      glowTop: glowTop ?? this.glowTop,
      glowBottom: glowBottom ?? this.glowBottom,
      glowMid: glowMid ?? this.glowMid,
      wallTint: wallTint ?? this.wallTint,
    );
  }

  @override
  KotvPalette lerp(ThemeExtension<KotvPalette>? other, double t) {
    if (other is! KotvPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return KotvPalette(
      mode: t < 0.5 ? mode : other.mode,
      name: t < 0.5 ? name : other.name,
      light: t < 0.5 ? light : other.light,
      primary: mix(primary, other.primary),
      surface: mix(surface, other.surface),
      variant: mix(variant, other.variant),
      fg: mix(fg, other.fg),
      muted: mix(muted, other.muted),
      outline: mix(outline, other.outline),
      input: mix(input, other.input),
      pillBg: mix(pillBg, other.pillBg),
      pillBorder: mix(pillBorder, other.pillBorder),
      statusBar: mix(statusBar, other.statusBar),
      catBar: mix(catBar, other.catBar),
      bottomNav: mix(bottomNav, other.bottomNav),
      dialogBg: mix(dialogBg, other.dialogBg),
      posterBar: mix(posterBar, other.posterBar),
      posterPh: mix(posterPh, other.posterPh),
      selected: mix(selected, other.selected),
      focus: mix(focus, other.focus),
      gradStart: mix(gradStart, other.gradStart),
      gradEnd: mix(gradEnd, other.gradEnd),
      glowTop: mix(glowTop, other.glowTop),
      glowBottom: mix(glowBottom, other.glowBottom),
      glowMid: mix(glowMid, other.glowMid),
      wallTint: mix(wallTint, other.wallTint),
    );
  }
}

/// 设置里的 theme + 系统外观 → 是否浅色。
final effectiveLightProvider = Provider<bool>((ref) {
  final st = ref.watch(settingsProvider);
  final theme = st.maybeWhen(
    data: (d) {
      final s = Map<String, dynamic>.from((d['settings'] as Map?) ?? const {});
      return '${s['theme'] ?? 'dark'}'.trim();
    },
    orElse: () => 'dark',
  );
  if (theme == 'light') return true;
  if (theme == 'dark') return false;
  // system
  return ref.watch(platformBrightnessProvider) == Brightness.light;
});

final kotvPaletteProvider = Provider<KotvPalette>((ref) {
  final bd = ref.watch(backdropProvider);
  final mode = '${bd['mode'] ?? 'gradient'}'.trim();
  final light = ref.watch(effectiveLightProvider);
  return KotvPalette.resolve(mode.isEmpty ? 'gradient' : mode, light);
});
