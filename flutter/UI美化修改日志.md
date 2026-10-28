# KO影视 0.1.0 UI 美化 — 修改日志

- 基线：上游 main `1d16d78710d7e81c8ff5148adbcaba0dc4472268`（2026-08-17 `fix(play): 不去扩展名删切片；Exo 纯音频不再误切播放器`）
- 方向：内置中文字体 + 色板精修 + 海报卡/标题/弹窗质感（对齐 0.2.2 展示过的"正式版质感"）
- 交付：仅源码 + 本日志，未打包安装包

## 修改文件（6 个）

### 1. `flutter/pubspec.yaml` — 内嵌 Noto 字体（全平台）
- `flutter:` 段新增 `fonts:`，注册 3 个字体族：
  - `NotoSansSC`：Regular(400) + Bold(700)
  - `NotoColorEmoji`（彩色 emoji 兜底）
  - `NotoEmoji`（黑白 emoji 兜底）
- 字体文件（新）：`flutter/assets/fonts/` 下 4 个文件，取自 0.2.2 安装目录（`data/flutter_assets/assets/fonts/`）：
  `NotoSansSC-Regular.otf`(8.0M)、`NotoSansSC-Bold.otf`(8.2M)、`NotoColorEmoji.ttf`(4.6M)、`NotoEmoji.ttf`(1.9M)
- Win7 线兼容：`adapt-flutter-win7-sdk.sh` 检测到 `family: NotoSansSC` 已存在会**跳过注入**；`fetch-flutter-fonts.sh` 仅 `KOTV_WIN7=1` 时执行，互不冲突

### 2. `flutter/lib/theme/kotv_theme.dart` — 字体启用 + 组件质感
- **NotoSansSC 全平台启用**：`useEmbeddedCJK = !kIsWeb`（原仅 Win7 启用），Web 仍走系统字体回退链；中文界面渲染明显更精致（不再依赖系统缺字回退）
- 主题新增/强化：
  - `cardTheme`：surface 55% 半透明、圆角 14、elevation 0、margin zero、surfaceTint 透明（适配壁纸背板）
  - `dialogTheme`：圆角 22（原直角 4）
  - `snackBarTheme`：floating 浮动胶囊 + 圆角 14，不再整条铺底压壁纸
  - `scrollbarTheme`：细条（厚 6、圆角 8、thumb muted 32% 透明）
  - 点击反馈：`splashFactory: InkSparkle` + highlight 透明 + splash 主色 12%，反馈更克制
- 注：`background/onBackground`、`MaterialState*`、`withOpacity` 等为上游既有写法（Flutter 3.19 兼容注释），保留未动，仅产生 info 级弃用提示

### 3. `flutter/lib/theme/kotv_palette.dart` — 默认"极光紫"深色色板精修
仅改 `defaults`（`mode: gradient, name: 极光紫`），builtin1/2/3 与浅色版未动：
| 项 | 原值 | 新值 | 效果 |
|---|---|---|---|
| primary | 0xFFCF4274 | **0xFFD84B82** | 品牌粉提亮一档，暗底对比更强 |
| statusBar | 0x60551C72 | 0x70471A66 | 顶栏更深沉 |
| catBar | 0x4D653AA8 | 0x553B1A6E | 分类栏更稳 |
| bottomNav | 0x8C1A0F2E | 0xA60F0A1E | 底栏更沉、层次分明 |
| dialogBg | 0xE03B1970 | 0xF2241740 | 弹窗接近不透明，内容更聚焦 |
| posterBar | 0xCC653AA8 | 0xCC411A70 | 海报标题栏加深，白字更清晰 |
| posterPh | 0xFF3A1A6E | 0xFF2E1258 | 占位底更深 |
| gradStart | 0xFF243DD0 | 0xFF1E3BC9 | 渐变更收敛 |
| gradEnd | 0xFFB220AC | 0xFF9E1CA4 | 渐变更收敛 |

### 4. `flutter/lib/widgets/poster_card.dart` — 海报卡质感
- 圆角 `10*s` → `12*s`（TvFocus + ClipRRect 同步）
- 标题区上方新增**渐变遮罩**：`barH+14*s` 高，`透明→posterBar 55%→96%` 三段渐变，亮色海报上标题也清晰
- 标题栏底色改 `Colors.transparent`（由遮罩承接）
- 角标（remarks）：改为胶囊（padding h6、圆角 6*s）+ 黑色 35% 阴影（`blur 6*s, offset(0,2*s)`），悬停感更强

### 5. `flutter/lib/widgets/chrome.dart` — 区块标题
- `SectionTitle` 标题前新增**主题强调竖条**（宽 5、高 22、圆角 3、`primary→variant 35%` 竖向渐变），"为你推荐/继续观看"等区块标题更有层次
- 其余组件（FeatureCard/EpisodeChip/NavPill/AppBackdrop）已有渐变/圆角设计，未改动

### 6. `flutter/test/widget_test.dart` — 修复上游过期测试
- 上游自带的是 Flutter 模板 Counter 测试，引用已不存在的 `MyApp`，导致 `flutter analyze` 必报 1 error
- 替换为色板冒烟测试：断言 `KotvPalette.defaults` 为深色且主色 = 0xFFD84B82

## 验证
- 环境：Flutter 3.44.9 stable / Dart 3.12.2（上游 CI 用 3.44.8，同档）
- `flutter analyze`：**0 error**；剩余 163 条均为上游既有 info/warning（`withOpacity` 弃用、unused import、MaterialState 弃用等，本次未触碰）
- `flutter test`：**26/26 全部通过**（含新增色板测试）

## 未做 / 后续可选项
- 未重新打包 Windows 安装包（本次仅源码交付；如需打包，发行目录与 ISCC 命令沿用 `KO/dist/KOTV-full-windows-x64` 流程）
- 若想整体换成浅色风格或其它色系（青绿/暖金），只需改 `kotv_palette.dart` 中对应色板即可，组件层零改动
