import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';

/// poster：约 214×280、圆角 10、底栏标题、备注粉角标。
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.autofocus = false,
  });

  final VodItem item;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      borderRadius: 12 * s,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12 * s),
            child: LayoutBuilder(
              builder: (context, c) {
                if (!c.hasBoundedHeight || !c.hasBoundedWidth || c.maxHeight <= 0 || c.maxWidth <= 0) {
                  return ColoredBox(color: p.posterPh);
                }
                final barH = (c.maxHeight * 0.18).clamp(30.0, 48.0);
                final remarkBottom = barH + 4;
                final titleLines = barH >= 40 ? 2 : 1;
                final letter = () {
                  final s = item.name.trim();
                  if (s.isEmpty) return '?';
                  final it = s.runes.iterator;
                  return it.moveNext() ? String.fromCharCode(it.current) : '?';
                }();
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: p.posterPh,
                      child: item.pic.isEmpty || !_isHttpPic(item.pic)
                          ? Center(
                              child: Text(
                                letter,
                                style: TextStyle(
                                  color: p.fg.withOpacity(0.35),
                                  fontSize: 54 * s,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                            )
                          : Image.network(
                              item.pic.trim(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => ColoredBox(color: p.posterPh),
                            ),
                    ),
                    if (item.remarks.isNotEmpty)
                      Positioned(
                        left: 6 * s,
                        bottom: remarkBottom,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 2.5 * s),
                          decoration: BoxDecoration(
                            color: p.primary.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(6 * s),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.35),
                                blurRadius: 6 * s,
                                offset: Offset(0, 2 * s),
                              ),
                            ],
                          ),
                          child: Text(
                            item.remarks,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                    // 标题区渐变遮罩：亮海报上标题也清晰
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: barH + 14 * s,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.0, 0.55, 1.0],
                            colors: [
                              Colors.transparent,
                              p.posterBar.withOpacity(0.55),
                              p.posterBar.withOpacity(0.96),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: barH,
                      child: Container(
                        alignment: Alignment.center,
                        color: Colors.transparent,
                        padding: EdgeInsets.symmetric(horizontal: 5 * s, vertical: 2),
                        child: Text(
                          item.name,
                          maxLines: titleLines,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.fg,
                            fontSize: titleLines == 2 ? 12.5 : 14,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static bool _isHttpPic(String s) {
    final t = s.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }
}

/// 海报流：按宽度算列数；窄屏最多 3 列，避免格子过矮只露半截。
class PosterFlow extends StatelessWidget {
  const PosterFlow({
    super.key,
    required this.items,
    required this.onOpen,
    this.padding = const EdgeInsets.fromLTRB(50, 10, 50, 24),
  });

  final List<VodItem> items;
  final void Function(VodItem) onOpen;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final compact = KotvLayout.isCompact(context);
        // v8.6：海报随窗口自动缩放——cell 基准随窗口 scale 缩放：
        // 拉大窗口海报放大、缩小窗口海报缩小；窄屏固定 3 列自然缩放。
        final s = LayoutScale.of(context);
        final gap = compact ? 6.0 : 10.0;
        final pad = compact ? const EdgeInsets.fromLTRB(12, 8, 12, 16) : padding;
        final inner = c.maxWidth - pad.horizontal;
        final cellW = 200.0 * s;
        // 窄屏强制 3 列；宽屏按缩放后的 cell 算列数（上限 8）。
        final cross = compact ? 3 : (inner / (cellW + gap)).floor().clamp(3, 8);
        return GridView.builder(
          padding: pad,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: 214 / 286,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final it = items[i];
            return PosterCard(
              item: it,
              autofocus: false,
              onTap: () => onOpen(it),
            );
          },
        );
      },
    );
  }
}
