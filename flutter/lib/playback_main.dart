import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'desktop/playback_ipc.dart';
import 'desktop/playback_window.dart';

/// KO影视 独立播放器进程入口（kotv-player.exe）。
///
/// 由主进程（kotv.exe）启动，通过本地 TCP IPC 接收播放指令。
/// 独立进程让播放器（media_kit/MPV）与主窗口彻底隔离——
/// 播放器忙/崩都不再影响主窗口 UI（v5 修复 v1~v4 共享进程冻结问题）。
///
/// 命令行参数：
///   --parent-port=<主进程 IPC server 端口>
/// 启动后打印一行 ASCII：KOTV_PLAYER_PORT=<本进程端口>，供主进程连接。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 播放器只用 media_kit(MPV) 渲染，不注册 fvp(mdk)，保持进程最小。

  // 由主进程通过环境变量传入 IPC 端口（避免 Windows 命令行/编码差异）。
  final parentPort =
      int.tryParse(Platform.environment['KOTV_PARENT_PORT'] ?? '') ?? 0;

  final ipc = PlaybackIpcClient(parentPort);
  final port = await ipc.start();
  // 纯 ASCII 行：避免 Windows 控制台编码对中文/UTF-8 的影响。
  stdout.writeln('KOTV_PLAYER_PORT=$port');
  unawaited(ipc.notify(PlaybackIpcCodec.typeReady, {'port': port}));

  runApp(ProviderScope(
    child: PlaybackWindowApp(ipc: ipc, args: PlaybackWindowArgs.placeholder()),
  ));
}
