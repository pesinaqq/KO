																				// 首次打开放到屏幕右上角：避开任务栏（底部）与主界面（左上角），
																				// 独立进程内安全；右上角在多分辨率下位置都稳定。
																				try {
																					await windowManager.setAlignment(Alignment.topRight);
            try {
              await windowManager.setPosition(const Offset(200, 80));
            } catch (_) {}
          }
          // 拦截系统标题栏关闭：先上报主进程，再销毁本进程窗口。
          await windowManager.setPreventClose(true);
          windowManager.addListener(this);
          await windowManager.show();
        } catch (e) {
          debugPrint('playback window init failed: $e');
        }
      });
    } catch (e) {
      debugPrint('playback window init failed: $e');
    }
  }

  Future<void> _focusSelf() async {
    if (kIsWeb) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _open(PlaybackWindowArgs args) async {
    final mk = _mk;
    if (mk == null || _busy) return;
    _busy = true;
    _switchTimeout?.cancel();
    _resetAutoNext();
    try {
      setState(() {
        _args = args;
        _openingSec = args.openingSec;
        _endingSec = args.endingSec;
        _status = '加载中…';
        _pos = Duration.zero;
        _epPanel = false;
        _openingSeekDone = false;
        _endingSkipFired = false;
      });
      try {
        await mk.stop();
      } catch (_) {}
      try {
        final headers = args.headers.isEmpty ? null : args.headers;
        await mk.open(args.playUrl, headers: headers);
        try {
          await mk.play();
        } catch (_) {}
        if (args.rate != null && args.rate! > 0) {
          try {
            await mk.setRate(args.rate!);
          } catch (_) {}
        }
        if (args.volume != null) {
          try {
            await mk.setVolume(args.volume!.clamp(0, 100));
          } catch (_) {}
        }
        if (_repeatOne) {
          try {
            await mk.setRepeatOne(true);
          } catch (_) {}
        }
        if (_stableVolume) {
          try {
            await _applyStableVolume(true);
          } catch (_) {}
        }
        if (mounted) setState(() => _status = '');
      } catch (e) {
        if (mounted) setState(() => _status = '播放失败：$e');
        unawaited(_notifyError('$e'));
      }
    } finally {
      _busy = false;
    }
  }

  /// 稳定音量：MPV af 滤镜（对齐主窗口 vod_player_chrome）。
  Future<void> _applyStableVolume(bool on) async {
    final p = _mk;
    if (p == null) return;
    try {
      await (p.player.platform as dynamic).setProperty('af', on ? 'loudnorm' : '');
    } catch (_) {
      try {
        await (p.player.platform as dynamic).setProperty('af', on ? 'dynaudnorm' : '');
      } catch (_) {}
    }
  }

  /// 调整片头/片尾偏移并上报主窗口持久化。
  Future<void> _setOffsets(int open, int end) async {
    setState(() {
      _openingSec = open.clamp(0, 3600);
      _endingSec = end.clamp(0, 3600);
      _openingSeekDone = false;
      _endingSkipFired = false;
    });
    await widget.ipc.notify(PlaybackIpcCodec.typeOffsets, {
      'opening': _openingSec,
      'ending': _endingSec,
    });
  }

  Future<void> _notifyClosed() async {
    await widget.ipc.notify(PlaybackIpcCodec.typeClosed);
  }

  /// 休眠定时器：到点后暂停播放并复位。
  void _setSleepMinutes(int mins) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    setState(() => _sleepMinutes = mins);
    if (mins > 0) {
      _sleepTimer = Timer(Duration(minutes: mins), () {
        if (!mounted) return;
        setState(() => _sleepMinutes = 0);
        final mk = _mk;
        if (mk != null) unawaited(mk.pause());
      });
    }
  }

  /// "更多"面板：循环播放/跳过片头片尾/稳定音量/休眠定时器/解析/刷新。
  Future<void> _showMore() async {
    _bumpChrome();
    final mk = _mk;
    if (mk == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void sync(VoidCallback fn) {
              setState(fn);
              setSheet(() {});
            }

            Widget row({
              required IconData icon,
              required String label,
              Widget? trailing,
              VoidCallback? onTap,
            }) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(icon, color: Colors.white, size: 24),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(label,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500)),
                          ),
                          if (trailing != null) trailing,
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }

            Widget toggle({required bool value, required ValueChanged<bool> onChanged}) {
              return Switch.adaptive(
                value: value,
                activeColor: Colors.white,
                activeTrackColor: const Color(0xFF5C5C66),
                inactiveThumbColor: const Color(0xFFB0B0B8),
                inactiveTrackColor: const Color(0xFF3A3A42),
                onChanged: onChanged,
              );
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Material(
                  color: const Color(0xCC2A2A30),
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(ctx).height * 0.72),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.28),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        row(
                          icon: Icons.repeat,
                          label: '循环播放视频',
                          trailing: toggle(
                            value: _repeatOne,
                            onChanged: (v) {
                              sync(() => _repeatOne = v);
                              unawaited(mk.setRepeatOne(v));
                            },
                          ),
                        ),
                        row(
                          icon: Icons.skip_next_outlined,
                          label: '跳过片头片尾',
                          trailing: toggle(
                            value: _loopSkip,
                            onChanged: (v) {
                              sync(() {
                                _loopSkip = v;
                                _endingSkipFired = false;
                                _openingSeekDone = false;
                              });
                              if (v) _onPositionTick(mk.position);
                            },
                          ),
                        ),
                        row(
                          icon: Icons.graphic_eq,
                          label: '稳定音量',
                          trailing: toggle(
                            value: _stableVolume,
                            onChanged: (v) {
                              sync(() => _stableVolume = v);
                              unawaited(_applyStableVolume(v));
                            },
                          ),
                        ),
                        row(
                          icon: Icons.playlist_play,
                          label: '自动连播',
                          trailing: toggle(
                            value: _autoNext,
                            onChanged: (v) {
                              sync(() {
                                _autoNext = v;
                                if (!v) _cancelAutoNext();
                              });
                            },
                          ),
                        ),
                        row(
                          icon: Icons.bedtime_outlined,
                          label: '休眠定时器',
                          trailing: Text(
                            _sleepMinutes <= 0 ? '关闭' : '$_sleepMinutes 分钟',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.55),
                                fontSize: 15),
                          ),
                          onTap: () => unawaited(_pickSleepTimer(ctx)),
                        ),
                        row(
                          icon: Icons.auto_awesome,
                          label: '解析',
                          onTap: () {
                            Navigator.pop(ctx);
                            unawaited(
                                widget.ipc.notify(PlaybackIpcCodec.typeParse));
                          },
                        ),
                        row(
                          icon: Icons.refresh,
                          label: '刷新',
                          onTap: () {
                            Navigator.pop(ctx);
                            unawaited(
                                widget.ipc.notify(PlaybackIpcCodec.typeRefresh));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _pickSleepTimer(BuildContext sheetCtx) async {
    final picked = await showModalBottomSheet<int>(
      context: sheetCtx,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      builder: (ctx) {
        Widget opt(String label, int mins) {
          return InkWell(
            onTap: () => Navigator.pop(ctx, mins),
            child: Container(
              height: 52,
              alignment: Alignment.center,
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Material(
              color: const Color(0xCC2A2A30),
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in [
                    ('关闭', 0),
                    ('10 分钟', 10),
                    ('30 分钟', 30),
                    ('60 分钟', 60),
                    ('90 分钟', 90),
                  ])
                    opt(e.$1, e.$2),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) _setSleepMinutes(picked);
  }

  Future<void> _notifyError(String message) async {
    await widget.ipc.notify(PlaybackIpcCodec.typeError, {'message': message});
  }

  /// 请求主窗口解析并切换到第 [idx] 集（主窗口走 popup 分支回传新 playUrl）。
  Future<void> _requestEpisode(int idx) async {
    if (idx == _args.epIdx) return;
    final mk = _mk;
    if (mk == null) return;
    _switchTimeout?.cancel();
    _cancelAutoNext();
    setState(() {
      _epPanel = false;
      _status = '切换中…';
    });
    try {
      await mk.stop();
    } catch (_) {}
    _switchTimeout = Timer(const Duration(seconds: 10), () {
      if (mounted && _status == '切换中…') setState(() => _status = '');
    });
    await widget.ipc.notify(
        PlaybackIpcCodec.typeSwitchEpisode, {'epIdx': idx});
  }

  /// v8：请求主窗口下发线路列表 → 弹出换源面板（仅一条线路时不弹）。
  Future<void> _requestSources() async {
    _bumpChrome();
    setState(() => _sourcePanel = false);
    await widget.ipc.notify(PlaybackIpcCodec.typeSwitchSource);
  }

  /// v8：选定第 [i] 条线路 → 通知主窗口切线路并回发 play 重播。
  Future<void> _selectSource(int i) async {
    _cancelAutoNext();
    setState(() {
      _sourcePanel = false;
      _status = '换源中…';
    });
    await widget.ipc.notify(
        PlaybackIpcCodec.typeSwitchSource, {'idx': i});
  }

  Future<void> _close() async {
    // 先通知主窗口复位，再停播放，最后销毁本窗口（独立进程，安全）。
    await _notifyClosed();
    await _disposePlayback();
    if (kIsWeb) return;
    try {
      await windowManager.destroy();
    } catch (_) {
      try {
        await windowManager.close();
      } catch (_) {}
    }
  }

  /// 系统标题栏关闭被 setPreventClose 拦截后回调：走同一关闭路径。
  @override
  void onWindowClose() async {
    await _close();
  }

  Future<void> _disposePlayback() async {
    final mk = _mk;
    _mk = null;
    if (mk == null) return;
    _switchTimeout?.cancel();
    try {
      await mk.stop();
    } catch (_) {}
    try {
      await kotvDisposeMpvPlayer(mk.player);
    } catch (_) {}
    try {
      mk.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _switchTimeout?.cancel();
    _sleepTimer?.cancel();
    _posSub?.cancel();
    if (!kIsWeb) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    unawaited(_disposePlayback());
    super.dispose();
  }

  void _bumpChrome() {
    _hideTimer?.cancel();
    if (!_showChrome && mounted) setState(() => _showChrome = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _showChrome) setState(() => _showChrome = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final mk = _mk;
    if (mk == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(mk.playOrPause());
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      final p = mk.position - const Duration(seconds: 10);
      unawaited(mk.seek(p.isNegative ? Duration.zero : p));
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(mk.seek(mk.position + const Duration(seconds: 10)));
      _bumpChrome();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _fmtSec(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final mk = _mk;
    final title =
        _args.epIdx >= 0 && _args.epIdx < _args.episodes.length
            ? '${_args.vodName} · ${_args.episodes[_args.epIdx]}'
            : (_args.vodName.isNotEmpty ? _args.vodName : 'KO影视');
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _bumpChrome(),
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (mk != null)
                ListenableBuilder(
                  listenable: mk,
                  builder: (context, _) => kotvPlaybackView(
                    playerVal: 'mpv',
                    playback: mk,
                    mpv: mk,
                    fit: _fit,
                  ),
                )
              else
                const ColoredBox(color: Colors.black),
              if (mk != null)
                KotvBufferingOverlay(
                  player: mk,
                  force: _status.contains('加载') && !mk.playing,
                ),
              if (_status.isNotEmpty)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _status,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              // 顶栏
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withOpacity(0.72), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
                          onPressed: () => unawaited(_close()),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 底部控制条
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black.withOpacity(0.72), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
                    child: mk == null
                        ? const SizedBox.shrink()
                        : ListenableBuilder(
                            listenable: mk,
                            builder: (context, _) {
                              final dur = mk.duration;
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: '播放/暂停',
                                        icon: Icon(
                                          mk.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                        onPressed: () => unawaited(mk.playOrPause()),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(_fmt(_pos), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      Expanded(
                                        child: SliderTheme(
                                          data: SliderThemeData(
                                            trackHeight: 3,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                            activeTrackColor: const Color(0xFFE53955),
                                            inactiveTrackColor: Colors.white24,
                                            thumbColor: Colors.white,
                                          ),
                                          child: Slider(
                                            max: dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1,
                                            value: _pos.inMilliseconds
                                                .clamp(0, dur.inMilliseconds > 0 ? dur.inMilliseconds : 1)
                                                .toDouble(),
                                            onChanged: dur.inMilliseconds > 0
                                                ? (v) {
                                                    final t = Duration(milliseconds: v.round());
                                                    _cancelAutoNext();
                                                    setState(() => _pos = t);
                                                    unawaited(mk.seek(t));
                                                  }
                                                : null,
                                          ),
                                        ),
                                      ),
                                      Text(_fmt(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      const SizedBox(width: 8),
                                      _VolumeButton(player: mk),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        tooltip: '选集',
                                        icon: const Icon(Icons.video_library_outlined, color: Colors.white, size: 22),
                                        onPressed: () {
                                          _bumpChrome();
                                          setState(() {
                                            _epPanel = !_epPanel;
                                            _sourcePanel = false;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      _BarBtn(label: '片头 -', onTap: () {
                                        _bumpChrome();
                                        unawaited(_setOffsets(_openingSec - 5, _endingSec));
                                      }),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Text('片头 ${_fmtSec(_openingSec)}',
                                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                      ),
                                      _BarBtn(label: '片头 +', onTap: () {
                                        _bumpChrome();
                                        unawaited(_setOffsets(_openingSec + 5, _endingSec));
                                      }),
                                      const SizedBox(width: 8),
                                      _BarBtn(label: '片尾 -', onTap: () {
                                        _bumpChrome();
                                        unawaited(_setOffsets(_openingSec, _endingSec - 5));
                                      }),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Text('片尾 ${_fmtSec(_endingSec)}',
                                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                      ),
                                      _BarBtn(label: '片尾 +', onTap: () {
                                        _bumpChrome();
                                        unawaited(_setOffsets(_openingSec, _endingSec + 5));
                                      }),
                                      const SizedBox(width: 8),
                                      _BarBtn(label: '重置', onTap: () {
                                        _bumpChrome();
                                        unawaited(_setOffsets(0, 0));
                                      }),
                                      const SizedBox(width: 8),
                                      _BarBtn(label: '换源', accent: true, onTap: () {
                                        _bumpChrome();
                                        unawaited(_requestSources());
                                      }),
                                      const SizedBox(width: 8),
                                      _BarBtn(label: '更多', accent: true, onTap: () {
                                        _bumpChrome();
                                        unawaited(_showMore());
                                      }),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ),
              ),
              // v8：换源面板（线路列表，同选集面板样式）。
              if (_sourcePanel && _sources.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 84,
                  child: Material(
                    color: Colors.black.withOpacity(0.88),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < _sources.length; i++)
                              _EpButton(
                                label: _sources[i],
                                active: i == _currentSource,
                                onTap: () => unawaited(_selectSource(i)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // v8：片尾自动连播倒计时（腾讯式"下一集 N 秒后播放"）。
              if (_nextCountdown != null && _args.epIdx + 1 < _args.episodes.length)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 120,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.78),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '下一集：${_args.episodes[_args.epIdx + 1]}  $_nextCountdown 秒后播放',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () {
                              _cancelAutoNext();
                              unawaited(_requestEpisode(_args.epIdx + 1));
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE53955),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('立即播放',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              setState(() => _autoNextCancelled = true);
                              _cancelAutoNext();
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('取消',
                                  style: TextStyle(color: Colors.white70, fontSize: 13)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              // 选集面板
              if (_epPanel && _args.episodes.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 84,
                  child: Material(
                    color: Colors.black.withOpacity(0.88),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < _args.episodes.length; i++)
                              _EpButton(
                                label: _args.episodes[i],
                                active: i == _args.epIdx,
                                onTap: () => unawaited(_requestEpisode(i)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarBtn extends StatelessWidget {
  const _BarBtn({
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: accent ? const Color(0xFFE53955) : Colors.white12,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _EpButton extends StatelessWidget {
  const _EpButton({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFE53955) : Colors.white12,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: active ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.player});

  final KotvPlayback player;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final vol = widget.player.volume;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_expanded)
              SizedBox(
                width: 90,
                child: Slider(
                  value: vol.clamp(0, 100),
                  onChanged: (v) => unawaited(widget.player.setVolume(v)),
                ),
              ),
            IconButton(
              tooltip: '音量',
              icon: Icon(
                vol <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        );
      },
    );
  }
}
