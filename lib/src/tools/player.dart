/// Yerel video oynatıcı: cihazdaki videolardan oynatma listesi, kaldığı
/// yerden devam, hız (0,25–3×), tekrar (kapalı/tek/tümü), karıştırma, A-B
/// tekrar, ±10 sn (çift dokunma), SRT/VTT altyazı (kaydırma ayarlı), sığdır/
/// doldur/uzat, ekran kilidi, uyku zamanlayıcısı, tam ekran ve yatay görünüm.
/// Ağ kullanılmaz; dosyalar sistem seçicisiyle açılır (geniş depolama izni yok).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:studio_core/apps/apps.dart';
import 'package:video_player/video_player.dart';

import '../common.dart';
import '../media_core.dart';
import '../platform/files.dart';

/// Oynatma listesindeki video. Web'de yalnız bu oturum için baytlar tutulur.
class PlayItem {
  final String name;
  final String? path;
  final int size;
  final Uint8List? bytes;
  const PlayItem(this.name, {this.path, this.size = 0, this.bytes});

  String get key => resumeKey(name, size);
  Map<String, Object?> toJson() => {'name': name, 'path': path, 'size': size};
}

enum _Fit { contain, cover, fill }

class VideoPlayerTool extends StatefulWidget {
  final ToolContext t;
  const VideoPlayerTool(this.t, {super.key});
  @override
  State<VideoPlayerTool> createState() => _VideoPlayerToolState();
}

class _VideoPlayerToolState extends State<VideoPlayerTool> {
  ToolContext get t => widget.t;
  List<PlayItem> _items = [];
  Map<String, int> _resume = {};
  double _speed = 1;

  @override
  void initState() {
    super.initState();
    () async {
      final m = await t.store.readMap('player');
      final list = <PlayItem>[];
      if (m['items'] is List && MediaFiles.hasFileSystem) {
        for (final o in m['items'] as List) {
          if (o is Map && o['path'] is String && await MediaFiles.exists(o['path'] as String)) {
            list.add(PlayItem(o['name'] as String? ?? '?', path: o['path'] as String, size: (o['size'] as num?)?.toInt() ?? 0));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _items = list;
        _speed = (m['speed'] as num?)?.toDouble() ?? 1;
        if (m['resume'] is Map) {
          _resume = {
            for (final e in (m['resume'] as Map).entries)
              if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt(),
          };
        }
      });
    }();
  }

  Future<void> _persist() => t.store.writeMap('player', {
        'items': [for (final i in _items) if (i.path != null) i.toJson()],
        'resume': _resume,
        'speed': _speed,
      });

  Future<void> _add() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true, withData: kIsWeb);
      if (r == null) return;
      setState(() {
        for (final f in r.files) {
          if (!kIsWeb && f.path == null) continue;
          if (_items.any((i) => i.path != null && i.path == f.path)) continue;
          _items.add(PlayItem(f.name, path: kIsWeb ? null : f.path, size: f.size, bytes: kIsWeb ? f.bytes : null));
        }
      });
      await _persist();
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  Future<void> _open(int index) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PlayerPage(
        t: t,
        items: _items,
        start: index,
        speed: _speed,
        resume: _resume,
        onResume: (key, ms) {
          if (ms == null) {
            _resume.remove(key);
          } else {
            _resume[key] = ms;
          }
          if (_resume.length > 200) _resume.remove(_resume.keys.first);
          unawaited(_persist());
        },
        onSpeed: (s) {
          _speed = s;
          unawaited(_persist());
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      if (_items.isEmpty)
        PickPrompt(label: L(t, 'pick_video'), icon: Icons.video_library_rounded, onTap: _add)
      else ...[
        ActionRow([
          FilledButton.icon(onPressed: () => _open(0), icon: const Icon(Icons.play_arrow_rounded), label: Text(L(t, 'play_all'))),
          OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add_rounded), label: Text(L(t, 'add_files'))),
        ]),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorder: (a, b) {
            setState(() {
              if (b > a) b--;
              _items.insert(b, _items.removeAt(a));
            });
            unawaited(_persist());
          },
          children: [
            for (var i = 0; i < _items.length; i++)
              Card(
                key: ObjectKey(_items[i]),
                child: ListTile(
                  leading: const Icon(Icons.movie_rounded),
                  title: Text(_items[i].name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    if (_items[i].size > 0) '${(_items[i].size / 1024 / 1024).toStringAsFixed(1)} MB',
                    if (_resume[_items[i].key] != null)
                      '${L(t, 'resume_at')} ${fmtTime(Duration(milliseconds: _resume[_items[i].key]!))}',
                  ].join(' · ')),
                  onTap: () => _open(i),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    tooltip: L(t, 'remove'),
                    onPressed: () {
                      setState(() => _items.removeAt(i));
                      unawaited(_persist());
                    },
                  ),
                ),
              ),
          ],
        ),
      ],
      AppInfoCard(L(t, 'player_note'), icon: Icons.info_outline_rounded),
    ]);
  }
}

class _PlayerPage extends StatefulWidget {
  final ToolContext t;
  final List<PlayItem> items;
  final int start;
  final double speed;
  final Map<String, int> resume;
  final void Function(String key, int? ms) onResume;
  final ValueChanged<double> onSpeed;
  const _PlayerPage({
    required this.t,
    required this.items,
    required this.start,
    required this.speed,
    required this.resume,
    required this.onResume,
    required this.onSpeed,
  });
  @override
  State<_PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<_PlayerPage> {
  ToolContext get t => widget.t;
  VideoPlayerController? _c;
  late int _index = widget.start;
  late double _speed = widget.speed;
  RepeatMode _repeat = RepeatMode.off;
  List<int>? _order;
  bool _controls = true;
  bool _locked = false;
  bool _muted = false;
  _Fit _fit = _Fit.contain;
  Duration? _a, _b;
  List<Cue> _cues = [];
  Duration _subOffset = Duration.zero;
  Timer? _hide, _save, _sleep;
  DateTime? _sleepAt;
  bool _ending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(SystemChrome.setPreferredOrientations(const []));
    _load(_index);
    _save = Timer.periodic(const Duration(seconds: 5), (_) => _remember());
  }

  @override
  void dispose() {
    _remember();
    _hide?.cancel();
    _save?.cancel();
    _sleep?.cancel();
    final c = _c;
    _c = null;
    c?.removeListener(_tick);
    unawaited(c?.dispose());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _restoreOrientation();
    super.dispose();
  }

  /// Telefonlarda dikey, tablette serbest yönlendirmeye döner (merkezin kuralı).
  void _restoreOrientation() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final v = views.first;
    final phone = (v.physicalSize / v.devicePixelRatio).shortestSide < 600;
    unawaited(SystemChrome.setPreferredOrientations(
        phone ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown] : const []));
  }

  PlayItem get _item => widget.items[_index];

  void _remember() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final p = resumePoint(c.value.position, c.value.duration);
    widget.onResume(_item.key, p?.inMilliseconds);
  }

  Future<void> _load(int index) async {
    final old = _c;
    _c = null;
    old?.removeListener(_tick);
    if (old != null) {
      _remember();
      unawaited(old.dispose());
    }
    setState(() {
      _index = index;
      _a = null;
      _b = null;
      _cues = [];
      _error = null;
      _ending = false;
    });
    final it = widget.items[index];
    VideoPlayerController? c;
    if (it.path != null) {
      c = MediaFiles.video(it.path!);
    } else if (it.bytes != null) {
      c = await MediaFiles.videoBytes(it.bytes!, it.name);
    }
    if (c == null) {
      setState(() => _error = t.tx('not_available'));
      return;
    }
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _error = L(t, 'cannot_play'));
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    await c.setPlaybackSpeed(_speed);
    await c.setVolume(_muted ? 0 : 1);
    final r = widget.resume[it.key];
    if (r != null && r < c.value.duration.inMilliseconds) {
      await c.seekTo(Duration(milliseconds: r));
      if (mounted) snack(context, '${L(t, 'resume_at')} ${fmtTime(Duration(milliseconds: r))}');
    }
    c.addListener(_tick);
    setState(() => _c = c);
    await c.play();
    _autoHide();
  }

  void _tick() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    final jump = abJump(v.position, _a, _b);
    if (jump != null) {
      unawaited(c.seekTo(jump));
      return;
    }
    if (v.isInitialized && !v.isPlaying && v.duration > Duration.zero && v.position >= v.duration && !_ending) {
      _ending = true;
      widget.onResume(_item.key, null);
      final n = nextIndex(_index, widget.items.length, _repeat, order: _order);
      if (n == null) {
        setState(() => _controls = true);
      } else if (n == _index) {
        _ending = false;
        unawaited(c.seekTo(Duration.zero).then((_) => c.play()));
      } else {
        unawaited(_load(n));
      }
      return;
    }
    setState(() {});
  }

  void _autoHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _controls = false);
    });
  }

  void _seekBy(int seconds) {
    final c = _c;
    if (c == null) return;
    final d = c.value.duration;
    var p = c.value.position + Duration(seconds: seconds);
    if (p < Duration.zero) p = Duration.zero;
    if (p > d) p = d;
    unawaited(c.seekTo(p));
  }

  Future<void> _loadSubs() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['srt', 'vtt'], withData: true);
      final b = r?.files.single.bytes;
      if (b == null) return;
      final cues = parseSrt(utf8.decode(b, allowMalformed: true));
      if (!mounted) return;
      setState(() {
        _cues = cues;
        _subOffset = Duration.zero;
      });
      snack(context, cues.isEmpty ? L(t, 'failed') : L(t, 'subs_loaded', {'n': cues.length}));
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  void _ab() {
    final c = _c;
    if (c == null) return;
    setState(() {
      if (_a == null) {
        _a = c.value.position;
      } else if (_b == null && c.value.position > _a!) {
        _b = c.value.position;
      } else {
        _a = null;
        _b = null;
      }
    });
  }

  void _setSleep(int minutes) {
    _sleep?.cancel();
    setState(() => _sleepAt = minutes == 0 ? null : DateTime.now().add(Duration(minutes: minutes)));
    if (minutes > 0) {
      _sleep = Timer(Duration(minutes: minutes), () {
        unawaited(_c?.pause());
        if (mounted) setState(() => _sleepAt = null);
      });
    }
  }

  Widget _video() {
    final c = _c!;
    final size = c.value.size;
    final w = size.width <= 0 ? 16.0 : size.width, h = size.height <= 0 ? 9.0 : size.height;
    return SizedBox.expand(
      child: FittedBox(
        fit: switch (_fit) { _Fit.contain => BoxFit.contain, _Fit.cover => BoxFit.cover, _Fit.fill => BoxFit.fill },
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: w, height: h, child: VideoPlayer(c)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final v = c?.value;
    final pos = v?.position ?? Duration.zero, dur = v?.duration ?? Duration.zero;
    final cue = _cues.isEmpty ? '' : cueAt(_cues, pos, offset: _subOffset);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        if (c != null && v!.isInitialized) _video(),
        if (c == null && _error == null) const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))),
        // Dokunma: kontrolleri göster/gizle; iki kez dokunma: ±10 sn.
        Positioned.fill(
          child: Row(children: [
            for (final side in [-10, 10])
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _controls = !_controls);
                    if (_controls) _autoHide();
                  },
                  onDoubleTap: _locked ? null : () => _seekBy(side),
                ),
              ),
          ]),
        ),
        if (cue.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            bottom: _controls ? 150 : 36,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
                child: Text(cue, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, height: 1.3)),
              ),
            ),
          ),
        if (_controls && _locked)
          Positioned(
            top: 24,
            right: 16,
            child: SafeArea(
              child: IconButton.filled(
                tooltip: L(t, 'unlock_screen'),
                icon: const Icon(Icons.lock_rounded),
                onPressed: () => setState(() => _locked = false),
              ),
            ),
          ),
        if (_controls && !_locked) ..._overlay(pos, dur, v),
      ]),
    );
  }

  List<Widget> _overlay(Duration pos, Duration dur, VideoPlayerValue? v) {
    final c = _c;
    final playing = v?.isPlaying ?? false;
    final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    const fitIcons = {_Fit.contain: Icons.fit_screen_rounded, _Fit.cover: Icons.crop_rounded, _Fit.fill: Icons.aspect_ratio_rounded};
    return [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent])),
          child: SafeArea(
            bottom: false,
            child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
              Expanded(child: Text(_item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
              IconButton(tooltip: L(t, 'subtitles'), icon: Icon(_cues.isEmpty ? Icons.subtitles_off_outlined : Icons.subtitles_rounded), onPressed: _loadSubs),
              IconButton(
                tooltip: L(t, 'fit'),
                icon: Icon(fitIcons[_fit]),
                onPressed: () => setState(() => _fit = _Fit.values[(_fit.index + 1) % _Fit.values.length]),
              ),
              IconButton(
                tooltip: L(t, 'rotate'),
                icon: const Icon(Icons.screen_rotation_rounded),
                onPressed: () {
                  final land = MediaQuery.orientationOf(context) == Orientation.portrait;
                  unawaited(SystemChrome.setPreferredOrientations(land
                      ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
                      : const [DeviceOrientation.portraitUp]));
                },
              ),
              IconButton(tooltip: L(t, 'lock_screen'), icon: const Icon(Icons.lock_open_rounded), onPressed: () => setState(() => _locked = true)),
            ]),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const SizedBox(width: 12),
                Text(fmtTime(pos)),
                Expanded(
                  child: Slider(
                    value: pos.inMilliseconds.clamp(0, total.toInt()).toDouble(),
                    max: total,
                    onChanged: c == null ? null : (x) => c.seekTo(Duration(milliseconds: x.round())),
                    onChangeEnd: (_) => _autoHide(),
                  ),
                ),
                Text(fmtTime(dur)),
                const SizedBox(width: 12),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => _load(previousIndex(_index, widget.items.length, order: _order)),
                ),
                IconButton(icon: const Icon(Icons.replay_10_rounded), onPressed: () => _seekBy(-10)),
                IconButton.filled(
                  iconSize: 40,
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: c == null
                      ? null
                      : () {
                          if (playing) {
                            c.pause();
                          } else {
                            if (pos >= dur) c.seekTo(Duration.zero);
                            _ending = false;
                            c.play();
                            _autoHide();
                          }
                        },
                ),
                IconButton(icon: const Icon(Icons.forward_10_rounded), onPressed: () => _seekBy(10)),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () {
                    final n = nextIndex(_index, widget.items.length, _repeat == RepeatMode.one ? RepeatMode.all : _repeat, order: _order);
                    if (n != null) _load(n);
                  },
                ),
              ]),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  PopupMenuButton<double>(
                    tooltip: L(t, 'speed'),
                    initialValue: _speed,
                    onSelected: (s) {
                      setState(() => _speed = s);
                      c?.setPlaybackSpeed(s);
                      widget.onSpeed(s);
                    },
                    itemBuilder: (_) => [for (final s in kSpeeds) PopupMenuItem(value: s, child: Text('${s}×'))],
                    child: Padding(padding: const EdgeInsets.all(12), child: Text('${_speed}×', style: const TextStyle(fontWeight: FontWeight.w800))),
                  ),
                  IconButton(
                    tooltip: L(t, 'repeat'),
                    icon: Icon(switch (_repeat) {
                      RepeatMode.off => Icons.repeat_rounded,
                      RepeatMode.one => Icons.repeat_one_on_rounded,
                      RepeatMode.all => Icons.repeat_on_rounded,
                    }),
                    onPressed: () => setState(() => _repeat = RepeatMode.values[(_repeat.index + 1) % 3]),
                  ),
                  IconButton(
                    tooltip: L(t, 'shuffle'),
                    icon: Icon(_order == null ? Icons.shuffle_rounded : Icons.shuffle_on_rounded),
                    onPressed: () => setState(
                        () => _order = _order == null ? shuffledOrder(widget.items.length, _index, math.Random()) : null),
                  ),
                  TextButton(
                    onPressed: _ab,
                    child: Text(_a == null ? 'A-B' : (_b == null ? 'A ${fmtTime(_a!)} → B?' : 'A-B ✓')),
                  ),
                  IconButton(
                    tooltip: L(t, 'mute'),
                    icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                    onPressed: () {
                      setState(() => _muted = !_muted);
                      c?.setVolume(_muted ? 0 : 1);
                    },
                  ),
                  PopupMenuButton<int>(
                    tooltip: L(t, 'sleep_timer'),
                    onSelected: _setSleep,
                    itemBuilder: (_) => [
                      for (final m in [0, 15, 30, 45, 60, 90])
                        PopupMenuItem(value: m, child: Text(m == 0 ? L(t, 'timer_off') : '$m min')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Icon(_sleepAt == null ? Icons.bedtime_outlined : Icons.bedtime_rounded),
                        if (_sleepAt != null) Text(' ${fmtTime(_sleepAt!.difference(DateTime.now()))}'),
                      ]),
                    ),
                  ),
                  if (_cues.isNotEmpty) ...[
                    IconButton(
                      tooltip: L(t, 'subs_earlier'),
                      icon: const Icon(Icons.fast_rewind_rounded, size: 18),
                      onPressed: () => setState(() => _subOffset -= const Duration(milliseconds: 500)),
                    ),
                    Text('${(_subOffset.inMilliseconds / 1000).toStringAsFixed(1)} s'),
                    IconButton(
                      tooltip: L(t, 'subs_later'),
                      icon: const Icon(Icons.fast_forward_rounded, size: 18),
                      onPressed: () => setState(() => _subOffset += const Duration(milliseconds: 500)),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    ];
  }
}
