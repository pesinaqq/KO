// 基础冒烟测试：默认主题色板为深色、主色为品牌粉。
// （上游 1d16d78 自带的是 Flutter 模板 Counter 测试，引用已不存在的 MyApp，已替换为色板冒烟。）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kotv/theme/kotv_palette.dart';

void main() {
  test('KotvPalette.defaults 是深色极光紫主色', () {
    final p = KotvPalette.defaults;
    expect(p.light, isFalse);
    // 主色为品牌粉（美化后的 D84B82）
    expect(p.primary, const Color(0xFFD84B82));
  });
}
