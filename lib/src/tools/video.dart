/// Video araçları (Android: Media3 Transformer, iOS: AVFoundation): kes ve
/// birleştir, GIF, slayt gösterisi, sıkıştırma, hız, ses çıkarma ve zaman
/// atlamalı video. Web'de video düzenleme yoktur; GIF fotoğraflardan
/// her yerde yapılabilir.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:studio_core/apps/apps.dart';
import 'package:video_player/video_player.dart';

import '../common.dart';
import '../dsp/audio.dart' show fmtClock;
import '../native.dart';
import '../platform/files.dart';

/// Çift sayıya yuvarlar ve sınırlar (H.264 kodlayıcıları çift boyut ister).
int even(num v, {int max = 1920}) {
  final x = math.min<int>(max, v.round());
  return math.max<int>(2, x - x % 2);
}

/// Boyutu [maxSide] içine sığdırıp çift sayılara çevirir.
({int w, int h}) evenFit(int w, int h, int maxSide) {
  final m = math.max<int>(w, h);
  final s = m > maxSide ? maxSide / m : 1.0;
  return (w: even(w * s, max: maxSide), h: even(h * s, max: maxSide));
}

String mbOf(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// Seçilen videonun önizlemesi.
class VideoPreview extends StatefulWidget {
  final String path;
  const VideoPreview(this.path, {super.key});

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(VideoPreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      final c = _c;
      _c = null;
      if (c != null) unawaited(c.dispose());
      _open();
    }
  }

  void _open() {
    final c = MediaFiles.video(widget.path);
    if (c == null) return;
    _c = c;
    unawaited(c.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((Object _) {}));
  }

  @override
  void dispose() {
    unawaited(_c?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(alignment: Alignment.center, children: [
              VideoPlayer(c),
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: c,
                builder: (context, v, _) => IconButton.filled(
                  iconSize: 36,
                  onPressed: () => v.isPlaying ? c.pause() : c.play(),
                  icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Video seçip bilgisini alan ortak durum.
mixin _VideoPicking<T extends StatefulWidget> on State<T> {
  String? path;
  MediaInfo? info;
  bool busy = false;

  Future<void> pickVideo() async {
    final p = await MediaPick.video();
    if (p == null) return;
    final i = await MedyaNative.probe(p);
    if (!mounted) return;
    setState(() {
      path = p;
      info = i;
    });
    onPicked();
  }

  void onPicked() {}

  /// Uzun işlemi yürütür; başarılıysa videoyu galeriye kaydeder.
  Future<void> runVideo(ToolContext t, Future<bool> Function(String out) job) async {
    final out = await MediaFiles.tempPath('mp4');
    if (out == null) return;
    setState(() => busy = true);
    final ok = await job(out);
    if (!mounted) return;
    if (ok) {
      final saved = await MediaFiles.saveVideo(out, 'video_${stamp()}.mp4');
      if (mounted) snack(context, L(t, saved ? 'saved' : 'save_failed'));
    } else {
      snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => busy = false);
  }
}

// ================================================================ kes ve birleştir

class VideoTrimMergeTool extends StatefulWidget {
  final ToolContext t;
  const VideoTrimMergeTool(this.t, {super.key});

  @override
  State<VideoTrimMergeTool> createState() => _TrimMergeState();
}

class _Clip {
  final String path;
  final MediaInfo info;
  RangeValues range;
  _Clip(this.path, this.info) : range = RangeValues(0, info.durationMs.toDouble());
}

class _TrimMergeState extends State<VideoTrimMergeTool> {
  final List<_Clip> _clips = [];
  int _sel = 0;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _add() async {
    final p = await MediaPick.video();
    if (p == null) return;
    final i = await MedyaNative.probe(p);
    if (i == null || i.durationMs <= 0) {
      if (mounted) snack(context, L(t, 'failed'));
      return;
    }
    if (!mounted) return;
    setState(() {
      _clips.add(_Clip(p, i));
      _sel = _clips.length - 1;
    });
  }

  Future<void> _export() async {
    if (_clips.isEmpty) return;
    setState(() => _busy = true);
    final temps = <String>[];
    var ok = true;
    try {
      final parts = <String>[];
      for (final c in _clips) {
        final full = c.range.start <= 0 && c.range.end >= c.info.durationMs;
        if (full) {
          parts.add(c.path);
          continue;
        }
        final o = await MediaFiles.tempPath('mp4');
        if (o == null || !await MedyaNative.trim(c.path, o, c.range.start.round(), c.range.end.round(), hasAudio: c.info.hasAudio)) {
          ok = false;
          break;
        }
        temps.add(o);
        parts.add(o);
      }
      String? result;
      if (ok && parts.length == 1) {
        result = parts.first;
        if (result == _clips.first.path) {
          final o = await MediaFiles.tempPath('mp4');
          ok = o != null && await MedyaNative.trim(result, o, 0, _clips.first.info.durationMs, hasAudio: _clips.first.info.hasAudio);
          result = o;
        }
      } else if (ok) {
        final f = _clips.first.info;
        final size = evenFit(f.displayWidth, f.displayHeight, 1920);
        final o = await MediaFiles.tempPath('mp4');
        ok = o != null && await MedyaNative.merge(parts, o, width: size.w, height: size.h);
        result = o;
      }
      if (ok && result != null) {
        final saved = await MediaFiles.saveVideo(result, 'video_${stamp()}.mp4');
        if (mounted) snack(context, L(t, saved ? 'saved' : 'save_failed'));
      } else if (mounted) {
        snack(context, L(t, 'failed'));
      }
    } finally {
      for (final p in temps) {
        unawaited(MediaFiles.delete(p));
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    if (_clips.isEmpty) {
      return ToolList(children: [PickPrompt(label: L(t, 'pick_video'), icon: Icons.content_cut_rounded, onTap: _add)]);
    }
    final c = _clips[_sel.clamp(0, _clips.length - 1)];
    return ToolList(children: [
      VideoPreview(c.path, key: ValueKey(c.path)),
      SizedBox(
        height: 48,
        child: ReorderableListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            final x = _clips.removeAt(a);
            _clips.insert(b, x);
            _sel = b;
          }),
          children: [
            for (var i = 0; i < _clips.length; i++)
              Padding(
                key: ValueKey('${_clips[i].path}#$i'),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InputChip(
                  label: Text('${i + 1} · ${fmtClock((_clips[i].range.end - _clips[i].range.start) / 1000)}'),
                  selected: i == _sel,
                  onSelected: (_) => setState(() => _sel = i),
                  onDeleted: () => setState(() {
                    _clips.removeAt(i);
                    _sel = 0;
                  }),
                ),
              ),
          ],
        ),
      ),
      AppHeading('${L(t, 'trim')}: ${fmtClock(c.range.start / 1000)} – ${fmtClock(c.range.end / 1000)}', icon: Icons.content_cut_rounded),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: RangeSlider(
          values: c.range,
          min: 0,
          max: c.info.durationMs.toDouble(),
          onChanged: (v) => setState(() => c.range = v),
        ),
      ),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'add_clip'), icon: Icons.add_rounded, onPressed: _busy ? null : _add),
        AppButton(
          label: _clips.length > 1 ? L(t, 'merge') : L(t, 'save'),
          icon: _clips.length > 1 ? Icons.merge_rounded : Icons.save_alt_rounded,
          onPressed: _busy ? null : _export,
        ),
      ]),
    ]);
  }
}

// ================================================================ GIF

/// GIF kodlama (ayrı izolede): kareler ilk karenin boyutuna ortalanarak sığar.
Uint8List? gifJob(({List<Uint8List> frames, int maxSide, int delayCs}) a) {
  final enc = img.GifEncoder(delay: a.delayCs, repeat: 0, samplingFactor: 10);
  int? w, h;
  var count = 0;
  for (final b in a.frames) {
    var im = img.decodeImage(b);
    if (im == null) continue;
    im = img.bakeOrientation(im);
    if (w == null || h == null) {
      final s = math.min(1.0, a.maxSide / math.max<int>(im.width, im.height));
      w = math.max<int>(1, (im.width * s).round());
      h = math.max<int>(1, (im.height * s).round());
    }
    final s = math.min(w / im.width, h / im.height);
    final rw = math.max<int>(1, (im.width * s).round()), rh = math.max<int>(1, (im.height * s).round());
    final resized = img.copyResize(im, width: rw, height: rh, interpolation: img.Interpolation.average);
    final frame = img.Image(width: w, height: h);
    img.fill(frame, color: img.ColorRgb8(0, 0, 0));
    img.compositeImage(frame, resized, dstX: (w - rw) ~/ 2, dstY: (h - rh) ~/ 2);
    enc.addFrame(frame, duration: a.delayCs);
    count++;
  }
  if (count == 0) return null;
  return enc.finish();
}

class GifTool extends StatefulWidget {
  final ToolContext t;
  const GifTool(this.t, {super.key});

  @override
  State<GifTool> createState() => _GifState();
}

class _GifState extends State<GifTool> {
  List<Uint8List> _frames = [];
  Uint8List? _gif;
  int _maxSide = 480;
  double _delay = 20; // salise
  bool _busy = false;
  double _count = 20;

  ToolContext get t => widget.t;

  Future<void> _fromPhotos() async {
    final ps = await MediaPick.images();
    if (ps.isEmpty) return;
    final list = <Uint8List>[];
    for (final p in ps.take(60)) {
      final b = await p.read();
      if (b != null) list.add(b);
    }
    setState(() {
      _frames = list;
      _gif = null;
    });
  }

  Future<void> _fromVideo() async {
    final p = await MediaPick.video();
    if (p == null) return;
    final dir = await MediaFiles.appDir('gif_frames');
    if (dir == null) return;
    setState(() => _busy = true);
    final paths = await MedyaNative.frames(p, dir, count: _count.round(), maxSide: _maxSide);
    final list = <Uint8List>[];
    for (final f in paths) {
      final b = await MediaFiles.read(f);
      if (b != null) list.add(b);
      unawaited(MediaFiles.delete(f));
    }
    if (!mounted) return;
    setState(() {
      _frames = list;
      _gif = null;
      _busy = false;
    });
    if (list.isEmpty) snack(context, L(t, 'failed'));
  }

  Future<void> _make() async {
    if (_frames.isEmpty) return;
    setState(() => _busy = true);
    final g = await compute(gifJob, (frames: _frames, maxSide: _maxSide, delayCs: _delay.round()));
    if (!mounted) return;
    setState(() {
      _gif = g;
      _busy = false;
    });
    if (g == null) snack(context, L(t, 'failed'));
  }

  @override
  Widget build(BuildContext context) {
    final g = _gif;
    return ToolList(children: [
      if (g != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(g, gaplessPlayback: true)),
        )
      else if (_frames.isNotEmpty)
        AppResult(label: L(t, 'frames'), value: '${_frames.length}', lang: t.lang)
      else
        PickPrompt(label: L(t, 'from_photos'), icon: Icons.gif_rounded, onTap: _busy ? null : _fromPhotos),
      SliderRow(
        label: L(t, 'speed'),
        value: _delay,
        min: 4,
        max: 100,
        format: (v) => '${(v * 10).round()} ms',
        onChanged: (v) => setState(() => _delay = v),
      ),
      ChipsRow<int>(
        values: const [240, 320, 480, 640],
        label: (v) => '$v px',
        selected: _maxSide,
        onChanged: (v) => setState(() => _maxSide = v),
      ),
      if (MedyaNative.supported)
        SliderRow(
          label: L(t, 'frames'),
          value: _count,
          min: 5,
          max: 60,
          divisions: 11,
          format: (v) => '${v.round()}',
          onChanged: (v) => setState(() => _count = v),
        ),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'from_photos'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _fromPhotos),
        if (MedyaNative.supported)
          AppButton(label: L(t, 'from_video'), icon: Icons.video_library_rounded, onPressed: _busy ? null : _fromVideo),
        AppButton(label: 'GIF', icon: Icons.gif_rounded, onPressed: _busy || _frames.isEmpty ? null : _make),
        if (g != null)
          AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: () => saveFile(context, t, g, 'gif_${stamp()}.gif', 'image/gif')),
      ]),
    ]);
  }
}

// ================================================================ slayt gösterisi

/// Fotoğrafı yönü düzeltilmiş JPEG olarak geçici klasöre yazar.
Future<String?> normalizedJpeg(Uint8List bytes, {int maxSide = 1920}) async {
  final im = await decodeUi(bytes, maxSide: maxSide);
  final rgba = im == null ? null : await rgbaOf(im);
  if (rgba == null) return null;
  final jpg = await jpgOf(rgba, quality: 90);
  return MediaFiles.writeTemp(jpg, 'jpg');
}

class SlideshowTool extends StatefulWidget {
  final ToolContext t;
  const SlideshowTool(this.t, {super.key});

  @override
  State<SlideshowTool> createState() => _SlideshowState();
}

class _SlideshowState extends State<SlideshowTool> {
  List<Picked> _photos = [];
  double _sec = 2.5;
  String _shape = 'landscape';
  bool _busy = false;
  double _progress = 0;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    final ps = await MediaPick.images();
    if (ps.isNotEmpty) setState(() => _photos = ps);
  }

  Future<void> _make() async {
    if (_photos.isEmpty) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    final files = <String>[];
    var i = 0;
    for (final p in _photos) {
      final b = await p.read();
      final f = b == null ? null : await normalizedJpeg(b);
      if (f != null) files.add(f);
      i++;
      if (mounted) setState(() => _progress = i / _photos.length * 0.4);
    }
    final size = switch (_shape) {
      'portrait' => (w: 720, h: 1280),
      'square' => (w: 1080, h: 1080),
      _ => (w: 1280, h: 720),
    };
    final out = await MediaFiles.tempPath('mp4');
    final ok = out != null &&
        files.isNotEmpty &&
        await MedyaNative.slideshow(files, out, msPerImage: (_sec * 1000).round(), width: size.w, height: size.h);
    for (final f in files) {
      unawaited(MediaFiles.delete(f));
    }
    if (!mounted) return;
    if (ok) {
      final saved = await MediaFiles.saveVideo(out, 'slayt_${stamp()}.mp4');
      if (mounted) snack(context, L(t, saved ? 'saved' : 'save_failed'));
    } else {
      snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    return ToolList(children: [
      if (_photos.isEmpty)
        PickPrompt(label: L(t, 'pick_photos'), icon: Icons.slideshow_rounded, onTap: _pick)
      else
        AppResult(label: L(t, 'count'), value: '${_photos.length}', lang: t.lang),
      SliderRow(
        label: L(t, 'per_photo'),
        value: _sec,
        min: 0.5,
        max: 8,
        divisions: 15,
        format: (v) => '${v.toStringAsFixed(1)} s',
        onChanged: (v) => setState(() => _sec = v),
      ),
      Choice<String>(
        values: const ['landscape', 'portrait', 'square'],
        labels: [L(t, 'sz_landscape'), L(t, 'sz_portrait'), L(t, 'sz_square')],
        selected: _shape,
        onChanged: (v) => setState(() => _shape = v),
      ),
      if (_photos.isNotEmpty)
        AppResult(label: L(t, 'duration'), value: fmtClock(_photos.length * _sec), lang: t.lang),
      if (_busy) BusyLine(L(t, 'processing'), progress: _progress > 0 && _progress < 0.4 ? _progress : null),
      ActionRow([
        AppButton(label: L(t, 'pick_photos'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.movie_creation_rounded, onPressed: _busy || _photos.isEmpty ? null : _make),
      ]),
    ]);
  }
}

// ================================================================ sıkıştırma

class VideoCompressTool extends StatefulWidget {
  final ToolContext t;
  const VideoCompressTool(this.t, {super.key});

  @override
  State<VideoCompressTool> createState() => _VideoCompressState();
}

class _VideoCompressState extends State<VideoCompressTool> with _VideoPicking {
  int _height = 720;
  int _size = 0;

  ToolContext get t => widget.t;

  static const _presets = <int, int>{1080: 6000, 720: 3000, 540: 1800, 480: 1200};

  @override
  void onPicked() {
    final p = path;
    if (p == null) return;
    unawaited(MediaFiles.size(p).then((v) {
      if (mounted) setState(() => _size = v);
    }));
  }

  int get _short {
    final i = info;
    if (i == null) return 1080;
    return math.min<int>(i.displayWidth, i.displayHeight);
  }

  int get _estimate {
    final i = info;
    if (i == null) return 0;
    final kbps = _presets[_height]! + (i.hasAudio ? 128 : 0);
    return (kbps * 1000 / 8 * i.durationMs / 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final p = path;
    final options = _presets.keys.where((h) => h <= math.max<int>(_short, 480)).toList();
    final height = options.contains(_height) ? _height : (options.isEmpty ? 480 : options.first);
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_video'), icon: Icons.video_settings_rounded, onTap: pickVideo)
      else ...[
        VideoPreview(p, key: ValueKey(p)),
        AppResult(label: L(t, 'original'), value: '${mbOf(_size)} · ${info?.displayWidth ?? 0}×${info?.displayHeight ?? 0}', lang: t.lang),
        ChipsRow<int>(values: options, label: (v) => '${v}p', selected: height, onChanged: (v) => setState(() => _height = v)),
        AppResult(label: L(t, 'result'), value: '≈ ${mbOf(_estimate)}', lang: t.lang, big: true),
      ],
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_video'), icon: Icons.video_library_rounded, onPressed: busy ? null : pickVideo),
        AppButton(
          label: L(t, 'compress'),
          icon: Icons.compress_rounded,
          onPressed: busy || p == null
              ? null
              : () => runVideo(
                  t,
                  (out) => MedyaNative.compress(p, out,
                      maxHeight: height, bitrateKbps: _presets[height] ?? 2000, hasAudio: info?.hasAudio ?? true)),
        ),
      ]),
    ]);
  }
}

// ================================================================ hız

class VideoSpeedTool extends StatefulWidget {
  final ToolContext t;
  const VideoSpeedTool(this.t, {super.key});

  @override
  State<VideoSpeedTool> createState() => _VideoSpeedState();
}

class _VideoSpeedState extends State<VideoSpeedTool> with _VideoPicking {
  double _factor = 2;
  bool _keepAudio = true;

  ToolContext get t => widget.t;

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final p = path;
    final i = info;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_video'), icon: Icons.slow_motion_video_rounded, onTap: pickVideo)
      else
        VideoPreview(p, key: ValueKey(p)),
      ChipsRow<double>(
        values: const [0.25, 0.5, 0.75, 1.5, 2, 3, 4, 8],
        label: (v) => v == v.roundToDouble() ? '${v.round()}×' : '$v×',
        selected: _factor,
        onChanged: (v) => setState(() => _factor = v),
      ),
      if (i != null) AppResult(label: L(t, 'duration'), value: '${fmtClock(i.durationMs / 1000)} → ${fmtClock(i.durationMs / 1000 / _factor)}', lang: t.lang),
      if (i != null && i.hasAudio)
        SwitchListTile(title: Text(L(t, 'keep_audio')), value: _keepAudio, onChanged: (v) => setState(() => _keepAudio = v)),
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_video'), icon: Icons.video_library_rounded, onPressed: busy ? null : pickVideo),
        AppButton(
          label: L(t, 'save'),
          icon: Icons.save_alt_rounded,
          onPressed: busy || p == null
              ? null
              : () => runVideo(t, (out) => MedyaNative.speed(p, out, _factor, keepAudio: _keepAudio, hasAudio: i?.hasAudio ?? false)),
        ),
      ]),
    ]);
  }
}

// ================================================================ videodan ses

class ExtractAudioTool extends StatefulWidget {
  final ToolContext t;
  const ExtractAudioTool(this.t, {super.key});

  @override
  State<ExtractAudioTool> createState() => _ExtractAudioState();
}

class _ExtractAudioState extends State<ExtractAudioTool> with _VideoPicking {
  bool _wav = false;

  ToolContext get t => widget.t;

  Future<void> _extract() async {
    final p = path;
    if (p == null) return;
    final out = await MediaFiles.tempPath(_wav ? 'wav' : 'm4a');
    if (out == null) return;
    setState(() => busy = true);
    final ok = _wav ? await MedyaNative.decodeToWav(p, out, channels: 2) : await MedyaNative.extractAudio(p, out);
    final bytes = ok ? await MediaFiles.read(out) : null;
    if (!mounted) return;
    if (bytes != null) {
      await saveFile(context, t, bytes, 'ses_${stamp()}.${_wav ? 'wav' : 'm4a'}', _wav ? 'audio/wav' : 'audio/mp4');
    } else {
      snack(context, L(t, 'failed'));
    }
    unawaited(MediaFiles.delete(out));
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final p = path;
    final i = info;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_video'), icon: Icons.audio_file_rounded, onTap: pickVideo)
      else
        VideoPreview(p, key: ValueKey(p)),
      if (i != null && !i.hasAudio) AppInfoCard(L(t, 'no_audio_track'), icon: Icons.volume_off_rounded),
      Choice<bool>(values: const [false, true], labels: const ['M4A', 'WAV'], selected: _wav, onChanged: (v) => setState(() => _wav = v)),
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_video'), icon: Icons.video_library_rounded, onPressed: busy ? null : pickVideo),
        AppButton(
          label: L(t, 'extract'),
          icon: Icons.music_note_rounded,
          onPressed: busy || p == null || (i != null && !i.hasAudio) ? null : _extract,
        ),
      ]),
    ]);
  }
}

// ================================================================ zaman atlamalı

class TimelapseTool extends StatefulWidget {
  final ToolContext t;
  const TimelapseTool(this.t, {super.key});

  @override
  State<TimelapseTool> createState() => _TimelapseState();
}

class _TimelapseState extends State<TimelapseTool> with _VideoPicking {
  String _mode = 'camera';
  double _interval = 2;
  double _factor = 8;
  final List<String> _shots = [];
  Timer? _timer;
  bool _capturing = false;
  ({int w, int h})? _size;

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _timer?.cancel();
    for (final s in _shots) {
      unawaited(MediaFiles.delete(s));
    }
    super.dispose();
  }

  void _start(CameraController c) {
    _timer?.cancel();
    setState(() => _capturing = true);
    _timer = Timer.periodic(Duration(milliseconds: (_interval * 1000).round()), (_) => _shoot(c));
    _shoot(c);
  }

  Future<void> _shoot(CameraController c) async {
    if (!c.value.isInitialized || c.value.isTakingPicture) return;
    try {
      final x = await c.takePicture();
      final b = await x.readAsBytes();
      final im = await decodeUi(b, maxSide: 1280);
      final rgba = im == null ? null : await rgbaOf(im);
      if (rgba == null) return;
      _size ??= evenFit(rgba.width, rgba.height, 1280);
      final f = await MediaFiles.writeTemp(await jpgOf(rgba, quality: 88), 'jpg');
      if (f != null && mounted) setState(() => _shots.add(f));
    } catch (_) {}
  }

  Future<void> _finish() async {
    _timer?.cancel();
    setState(() => _capturing = false);
    if (_shots.length < 2) return;
    final s = _size ?? (w: 1280, h: 720);
    await runVideo(t, (out) => MedyaNative.slideshow(List<String>.of(_shots), out, msPerImage: 42, width: s.w, height: s.h));
    for (final f in _shots) {
      unawaited(MediaFiles.delete(f));
    }
    if (mounted) setState(() => _shots.clear());
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    return ToolList(children: [
      Choice<String>(
        values: const ['camera', 'video'],
        labels: [L(t, 'shoot_interval'), L(t, 'speed_up')],
        selected: _mode,
        onChanged: _capturing ? (_) {} : (v) => setState(() => _mode = v),
      ),
      if (_mode == 'camera') ...[
        CameraBox(
          tool: t,
          builder: (context, c) => Column(children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: cameraPreview(c, height: 320)),
            AppResult(label: L(t, 'frames'), value: '${_shots.length} · ${fmtClock(_shots.length / 24)}', lang: t.lang),
            ActionRow([
              if (!_capturing)
                AppButton(label: L(t, 'record'), icon: Icons.fiber_manual_record_rounded, onPressed: busy ? null : () => _start(c))
              else
                AppButton(label: L(t, 'stop'), icon: Icons.stop_rounded, onPressed: _finish),
            ]),
          ]),
        ),
        SliderRow(
          label: L(t, 'interval'),
          value: _interval,
          min: 1,
          max: 30,
          divisions: 29,
          format: (v) => '${v.round()} s',
          onChanged: _capturing ? (_) {} : (v) => setState(() => _interval = v),
        ),
      ] else ...[
        if (path == null)
          PickPrompt(label: L(t, 'pick_video'), icon: Icons.timelapse_rounded, onTap: pickVideo)
        else
          VideoPreview(path!, key: ValueKey(path)),
        ChipsRow<double>(
          values: const [4, 8, 16, 32],
          label: (v) => '${v.round()}×',
          selected: _factor,
          onChanged: (v) => setState(() => _factor = v),
        ),
        ActionRow([
          AppButton(label: L(t, 'pick_video'), icon: Icons.video_library_rounded, onPressed: busy ? null : pickVideo),
          AppButton(
            label: L(t, 'save'),
            icon: Icons.save_alt_rounded,
            onPressed: busy || path == null
                ? null
                : () => runVideo(t, (out) => MedyaNative.speed(path!, out, _factor, keepAudio: false, hasAudio: false)),
          ),
        ]),
      ],
      if (busy) BusyLine(L(t, 'processing')),
    ]);
  }
}
