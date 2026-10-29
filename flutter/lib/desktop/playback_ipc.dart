import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 独立播放器进程 IPC：主进程(kotv.exe) ↔ 播放器进程(kotv-player.exe)。
///
/// 通信载体：本地 TCP（127.0.0.1 随机端口），HTTP JSON。
/// 双端各持一个 HttpServer：
///  - 主进程：PlaybackIpcServer —— 接收播放器上报的事件（/event）
///  - 播放器：PlaybackIpcClient —— 接收主进程下发的指令（/play /close /focus）
///
/// 为什么换掉 desktop_multi_window：共享进程里子窗口与主窗口共用
/// Flutter/媒体资源，播放器一忙主窗口 UI 就冻结（界面点不动、关不掉）。
/// 独立进程彻底隔离——播放器崩溃/卡死都不影响主窗口。
class PlaybackIpcCodec {
  static const String typePlay = 'play';
  static const String typeClose = 'close';
  static const String typeFocus = 'focus';
  static const String typeReady = 'ready';
  static const String typeClosed = 'closed';
  static const String typeError = 'error';
  static const String typeSwitchEpisode = 'switchEpisode';

  // v6：播放器进程请求主窗口执行的动作/状态同步。
  static const String typeParse = 'parse';
  static const String typeRefresh = 'refresh';
  static const String typeOffsets = 'offsets';

  static String encode(Object? body) => jsonEncode(body);
}

/// 主进程侧：HTTP server（接收播放器事件）+ HTTP 客户端（向播放器下发指令）。
class PlaybackIpcServer {
  HttpServer? _server;
  int? _port;

  /// 播放器进程启动后上报的 ready 端口。
  int? playerPort;

  /// 播放器上报 closed（已退出）。
  void Function()? onClosed;

  /// 播放器上报播放错误。
  void Function(String message)? onError;

  /// 播放器请求切换剧集（主窗口负责解析新 URL 后回发 play）。
  void Function(int epIdx)? onSwitchEpisode;

  /// 播放器请求主窗口重新解析（换解析器后重播当前集）。
  void Function()? onParse;

  /// 播放器请求主窗口刷新当前集。
  void Function()? onRefresh;

  /// 播放器内调整了片头/片尾偏移，请主窗口同步持久化。
  void Function(int openingSec, int endingSec)? onOffsets;

  /// 惰性启动主进程侧 server；返回监听端口。
  Future<int> ensurePort() async {
    final s = _server;
    if (s != null) return _port!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    unawaited(_serve(server));
    return server.port;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      try {
        if (req.method != 'POST' || req.uri.path != '/event') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          continue;
        }
        final raw = await utf8.decodeStream(req);
        final body = (raw.isEmpty) ? null : jsonDecode(raw);
        final type = (body is Map) ? '${body['type']}' : '';
        Object? reply = 'ok';
        switch (type) {
          case PlaybackIpcCodec.typeReady:
            playerPort = (body['port'] as num?)?.toInt() ?? playerPort;
            break;
          case PlaybackIpcCodec.typeClosed:
            onClosed?.call();
            break;
          case PlaybackIpcCodec.typeError:
            onError?.call('${body['message'] ?? ''}');
            break;
          case PlaybackIpcCodec.typeSwitchEpisode:
            final idx = (body['epIdx'] as num?)?.toInt();
            if (idx != null) onSwitchEpisode?.call(idx);
            break;
          case PlaybackIpcCodec.typeParse:
            onParse?.call();
            break;
          case PlaybackIpcCodec.typeRefresh:
            onRefresh?.call();
            break;
          case PlaybackIpcCodec.typeOffsets:
            final open = (body['opening'] as num?)?.toInt() ?? 0;
            final end = (body['ending'] as num?)?.toInt() ?? 0;
            onOffsets?.call(open, end);
            break;
          default:
            reply = null;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        if (reply != null) {
          req.response.write(PlaybackIpcCodec.encode({'result': reply}));
        }
        await req.response.close();
      } catch (e) {
        debugPrint('playback ipc server error: $e');
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  /// 向播放器进程下发指令。播放器端口未知（未 ready）时返回 false。
  Future<bool> sendToPlayer(String type, [Map<String, dynamic>? payload]) async {
    final port = playerPort;
    if (port == null || port <= 0) return false;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client
            .postUrl(Uri.parse('http://127.0.0.1:$port/$type'))
            .timeout(const Duration(seconds: 3));
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        req.write(PlaybackIpcCodec.encode(payload ?? const <String, dynamic>{}));
        final res = await req.close().timeout(const Duration(seconds: 5));
        await res.drain<void>();
        return res.statusCode == HttpStatus.ok;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('playback ipc sendToPlayer($type) failed: $e');
      return false;
    }
  }

  void dispose() {
    try {
      _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _port = null;
  }
}

/// 播放器进程侧：HTTP server（接收主进程指令）+ 上报事件到主进程。
class PlaybackIpcClient {
  final int parentPort;
  HttpServer? _server;

  /// 主进程下发播放指令。
  void Function(Map<String, dynamic> args)? onPlay;

  /// 主进程请求关闭播放器。
  void Function()? onClose;

  /// 主进程请求播放器窗口置前。
  void Function()? onFocus;

  PlaybackIpcClient(this.parentPort);

  /// 启动播放器侧 server，返回端口。
  Future<int> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
    return server.port;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      try {
        if (req.method != 'POST') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          continue;
        }
        final path = req.uri.path;
        final raw = await utf8.decodeStream(req);
        final body = (raw.isEmpty) ? null : jsonDecode(raw);
        switch (path) {
          case '/play':
            onPlay?.call(
                (body is Map) ? Map<String, dynamic>.from(body) : const {});
            break;
          case '/close':
            onClose?.call();
            break;
          case '/focus':
            onFocus?.call();
            break;
          default:
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
            continue;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        req.response.write(PlaybackIpcCodec.encode({'result': 'ok'}));
        await req.response.close();
      } catch (e) {
        debugPrint('playback ipc client server error: $e');
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  /// 上报事件到主进程。parentPort<=0 时不发（比如被直接双击启动）。
  Future<void> notify(String type, [Map<String, dynamic>? payload]) async {
    if (parentPort <= 0) return;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client
            .postUrl(Uri.parse('http://127.0.0.1:$parentPort/event'))
            .timeout(const Duration(seconds: 2));
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        final m = <String, dynamic>{'type': type};
        if (payload != null) m.addAll(payload);
        req.write(PlaybackIpcCodec.encode(m));
        final res = await req.close().timeout(const Duration(seconds: 3));
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('playback ipc notify($type) failed: $e');
    }
  }

  void dispose() {
    try {
      _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }
}
