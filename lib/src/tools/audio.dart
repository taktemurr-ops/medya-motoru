/// Ses araçları: müzik çalar, zil sesi, ses düzenleyici, uyku sesleri, ses
/// değiştirici, podcast kaydı, ses yükseltici, gürültü azaltma ve biçim
/// dönüştürücü. Ses işleme saf Dart'tır (web dahil); WAV dışındaki
/// biçimler mobilde yerel çözücüyle açılır.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/audio.dart';
import '../native.dart';
import '../platform/files.dart';

/// Sesi WAV olarak (mobilde istenirse M4A) kaydeder.
Future<void> savePcm(BuildContext context, ToolContext t, Pcm p, String base, {bool m4a = false}) async {
  final wav = encodeWav(p);
  if (m4a && MedyaNative.supported) {
    final src = await MediaFiles.writeTemp(wav, 'wav');
    final out = await MediaFiles.tempPath('m4a');
    if (src != null && out != null && await MedyaNative.encodeM4a(src, out)) {
      final b = await MediaFiles.read(out);
      unawaited(MediaFiles.delete(src));
      unawaited(MediaFiles.delete(out));
      if (b != null && context.mounted) {
        await saveFile(context, t, b, '$base.m4a', 'audio/mp4');
        return;
      }
    }
  }
  if (context.mounted) await saveFile(context, t, wav, '$base.wav', 'audio/wav');
}

/// Ses dosyası seçip çözen ortak durum.
mixin _AudioLoading<T extends StatefulWidget> on State<T> {
  Pcm? pcm;
  String name = 'ses';
  bool busy = false;

  ToolContext get tool;

  Future<void> pickAudio() async {
    final ps = await MediaPick.audio();
    if (ps.isEmpty) return;
    setState(() => busy = true);
    final p = await loadAudio(ps.first);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (p != null) {
        pcm = p;
        final n = ps.first.name;
        final dot = n.lastIndexOf('.');
        name = dot > 0 ? n.substring(0, dot) : n;
      }
    });
    if (p == null) snack(context, L(tool, MedyaNative.supported ? 'failed' : 'wav_hint'));
    if (p != null) onLoaded();
  }

  void onLoaded() {}
}

/// Mikrofondan WAV kaydı (web dahil).
class MicRecorder {
  final AudioRecorder _rec = AudioRecorder();
  bool recording = false;

  Future<bool> start(BuildContext context, ToolContext t) async {
    if (!await rationaleOnce(context, t, 'mic', Icons.mic_rounded)) return false;
    try {
      if (!await _rec.hasPermission()) return false;
      final path = kIsWeb ? '' : (await MediaFiles.tempPath('wav') ?? '');
      await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 1), path: path);
      recording = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Stream<Amplitude> amplitude() => _rec.onAmplitudeChanged(const Duration(milliseconds: 120));

  Future<void> pause() => _rec.pause();
  Future<void> resume() => _rec.resume();

  Future<Pcm?> stop() async {
    recording = false;
    try {
      final path = await _rec.stop();
      if (path == null) return null;
      final b = await XFile(path).readAsBytes();
      if (!kIsWeb) unawaited(MediaFiles.delete(path));
      return decodeWav(b);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    unawaited(_rec.dispose());
  }
}

// ================================================================ müzik çalar

class MusicPlayerTool extends StatefulWidget {
  final ToolContext t;
  const MusicPlayerTool(this.t, {super.key});

  @override
  State<MusicPlayerTool> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayerTool> {
  final AudioPlayer _p = AudioPlayer();
  final List<Picked> _list = [];
  int _index = -1;
  bool _shuffle = false, _repeat = false, _playing = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;
  final List<StreamSubscription<Object?>> _subs = [];

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    _subs.add(_p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(_p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    }));
    _subs.add(_p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(_p.onPlayerComplete.listen((_) => _next(auto: true)));
    unawaited(_restore());
  }

  /// Mobilde liste (yollar) hatırlanır; yoksa olan dosyalar atlanır.
  Future<void> _restore() async {
    if (kIsWeb) return;
    final rows = await t.store.readList('playlist');
    final out = <Picked>[];
    for (final r in rows) {
      final path = r['path'];
      final name = r['name'];
      if (path is String && name is String && await MediaFiles.exists(path)) out.add(Picked(name, path: path));
    }
    if (mounted && out.isNotEmpty) setState(() => _list.addAll(out));
  }

  Future<void> _persist() async {
    if (kIsWeb) return;
    await t.store.writeList('playlist', [
      for (final p in _list)
        if (p.path != null) {'name': p.name, 'path': p.path},
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_p.dispose());
    super.dispose();
  }

  Future<void> _add() async {
    final ps = await MediaPick.audio(multiple: true);
    if (ps.isEmpty) return;
    setState(() => _list.addAll(ps));
    await _persist();
  }

  Future<void> _play(int i) async {
    if (i < 0 || i >= _list.length) return;
    final p = _list[i];
    setState(() {
      _index = i;
      _pos = Duration.zero;
    });
    try {
      await _p.stop();
      final path = p.path;
      final bytes = p.bytes;
      if (path != null) {
        await _p.play(DeviceFileSource(path));
      } else if (bytes != null) {
        await _p.play(BytesSource(bytes));
      }
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  void _next({bool auto = false}) {
    if (_list.isEmpty) return;
    if (auto && _repeat && _index >= 0) {
      unawaited(_play(_index));
      return;
    }
    final i = _shuffle ? math.Random().nextInt(_list.length) : (_index + 1) % _list.length;
    if (auto && !_shuffle && i == 0) return;
    unawaited(_play(i));
  }

  void _prev() {
    if (_list.isEmpty) return;
    unawaited(_play((_index - 1 + _list.length) % _list.length));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLook.of(context);
    final now = _index >= 0 && _index < _list.length ? _list[_index].name : '';
    return ToolList(children: [
      AppPanel(
        child: Column(children: [
          Icon(Icons.album_rounded, size: 72, color: s.accent),
          const SizedBox(height: 8),
          Text(now.isEmpty ? '—' : now,
              maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          Slider(
            value: _pos.inMilliseconds.clamp(0, math.max<int>(1, _dur.inMilliseconds)).toDouble(),
            max: math.max<int>(1, _dur.inMilliseconds).toDouble(),
            onChanged: (v) => unawaited(_p.seek(Duration(milliseconds: v.round()))),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(fmtClock(_pos.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
            Text(fmtClock(_dur.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
          ]),
          // Dar ekranda denetim düğmeleri sığacak kadar küçülür.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: L(t, 'shuffle'),
              isSelected: _shuffle,
              onPressed: () => setState(() => _shuffle = !_shuffle),
              icon: Icon(Icons.shuffle_rounded, color: _shuffle ? s.accent : Colors.white54),
            ),
            IconButton(iconSize: 36, onPressed: _prev, icon: const Icon(Icons.skip_previous_rounded)),
            IconButton.filled(
              iconSize: 44,
              onPressed: _list.isEmpty
                  ? null
                  : () {
                      if (_playing) {
                        unawaited(_p.pause());
                      } else if (_index < 0) {
                        unawaited(_play(0));
                      } else {
                        unawaited(_p.resume());
                      }
                    },
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            IconButton(iconSize: 36, onPressed: () => _next(), icon: const Icon(Icons.skip_next_rounded)),
            IconButton(
              tooltip: L(t, 'repeat'),
              onPressed: () => setState(() => _repeat = !_repeat),
              icon: Icon(Icons.repeat_one_rounded, color: _repeat ? s.accent : Colors.white54),
            ),
          ]),
          ),
        ]),
      ),
      if (_list.isEmpty) AppInfoCard(L(t, 'empty_list'), icon: Icons.queue_music_rounded),
      for (var i = 0; i < _list.length; i++)
        ListTile(
          leading: Icon(i == _index ? Icons.graphic_eq_rounded : Icons.music_note_rounded, color: i == _index ? s.accent : null),
          title: Text(_list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _play(i),
          trailing: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () {
              setState(() {
                _list.removeAt(i);
                if (_index == i) {
                  _index = -1;
                  unawaited(_p.stop());
                } else if (_index > i) {
                  _index--;
                }
              });
              unawaited(_persist());
            },
          ),
        ),
      ActionRow([AppButton(label: L(t, 'add_files'), icon: Icons.library_add_rounded, onPressed: _add)]),
    ]);
  }
}

// ================================================================ zil sesi

class RingtoneTool extends StatefulWidget {
  final ToolContext t;
  const RingtoneTool(this.t, {super.key});

  @override
  State<RingtoneTool> createState() => _RingtoneState();
}

class _RingtoneState extends State<RingtoneTool> with _AudioLoading {
  RangeValues _range = const RangeValues(0, 30);
  bool _fade = true;
  final TonePlayer _player = TonePlayer();

  ToolContext get t => widget.t;
  @override
  ToolContext get tool => widget.t;

  @override
  void onLoaded() {
    final p = pcm;
    if (p != null) setState(() => _range = RangeValues(0, math.min(30.0, p.seconds)));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Pcm? _cut() {
    final p = pcm;
    if (p == null) return null;
    final c = trimPcm(p, _range.start, _range.end);
    if (_fade) {
      fadeIn(c, 0.4);
      fadeOut(c, 1.2);
    }
    return c;
  }

  Future<void> _export() async {
    final c = _cut();
    if (c == null) return;
    setState(() => busy = true);
    final base = 'zil_$name';
    if (MedyaNative.isAndroid) {
      final src = await MediaFiles.writeTemp(encodeWav(c), 'wav');
      final out = await MediaFiles.tempPath('m4a');
      var ok = false;
      if (src != null && out != null && await MedyaNative.encodeM4a(src, out)) {
        ok = await MedyaNative.saveRingtone(out, '$base.m4a');
      }
      if (mounted) {
        if (ok) {
          snack(context, L(t, 'saved'));
        } else {
          await savePcm(context, t, c, base, m4a: true);
        }
      }
    } else if (mounted) {
      await savePcm(context, t, c, base, m4a: MedyaNative.supported);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = pcm;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.ring_volume_rounded, onTap: busy ? null : pickAudio)
      else ...[
        WaveView(peaks(p, 160), start: _range.start / p.seconds, end: _range.end / p.seconds),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: RangeSlider(
            values: _range,
            min: 0,
            max: p.seconds,
            onChanged: (v) {
              var r = v;
              if (r.end - r.start > 40) r = RangeValues(r.start, r.start + 40);
              setState(() => _range = r);
            },
          ),
        ),
        AppResult(label: L(t, 'duration'), value: '${fmtClock(_range.start)} – ${fmtClock(_range.end)}', lang: t.lang),
        SwitchListTile(title: Text('${L(t, 'fade_in')} / ${L(t, 'fade_out')}'), value: _fade, onChanged: (v) => setState(() => _fade = v)),
      ],
      if (busy) BusyLine(L(t, 'processing')),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) AppInfoCard(L(t, 'ringtone_ios'), icon: Icons.info_outline_rounded),
      if (MedyaNative.isAndroid) AppInfoCard(L(t, 'ringtone_hint'), icon: Icons.info_outline_rounded),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: busy ? null : pickAudio),
        if (p != null)
          AppButton(
            label: t.core('play'),
            icon: Icons.play_arrow_rounded,
            onPressed: () {
              final c = _cut();
              if (c != null) unawaited(_player.playWav(encodeWav(c)));
            },
          ),
        if (p != null) AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: busy ? null : _export),
        if (MedyaNative.isAndroid)
          AppButton(label: L(t, 'sound_settings'), icon: Icons.settings_rounded, onPressed: () => MedyaNative.openSoundSettings()),
      ]),
    ]);
  }
}

// ================================================================ ses düzenleyici

class AudioEditorTool extends StatefulWidget {
  final ToolContext t;
  const AudioEditorTool(this.t, {super.key});

  @override
  State<AudioEditorTool> createState() => _AudioEditorState();
}

class _AudioEditorState extends State<AudioEditorTool> with _AudioLoading {
  final List<Pcm> _undo = [];
  RangeValues _sel = const RangeValues(0, 1);
  final TonePlayer _player = TonePlayer();
  final MicRecorder _mic = MicRecorder();

  ToolContext get t => widget.t;
  @override
  ToolContext get tool => widget.t;

  @override
  void onLoaded() {
    _undo.clear();
    setState(() => _sel = const RangeValues(0, 1));
  }

  @override
  void dispose() {
    _player.dispose();
    _mic.dispose();
    super.dispose();
  }

  void _apply(Pcm Function(Pcm p) op) {
    final p = pcm;
    if (p == null) return;
    _undo.add(p);
    if (_undo.length > 6) _undo.removeAt(0);
    setState(() {
      pcm = op(p.copy());
      _sel = const RangeValues(0, 1);
    });
  }

  /// İşlemi yalnızca seçili aralığa uygular.
  Pcm _onSelection(Pcm p, void Function(Pcm part) f) {
    final a = (p.frames * _sel.start).round(), b = (p.frames * _sel.end).round();
    final part = Pcm(p.rate, p.channels, Float32List.fromList(p.samples.sublist(a * p.channels, b * p.channels)));
    f(part);
    p.samples.setRange(a * p.channels, b * p.channels, part.samples);
    return p;
  }

  Future<void> _record() async {
    if (_mic.recording) {
      final p = await _mic.stop();
      if (!mounted) return;
      setState(() {
        if (p != null) pcm = p;
      });
      if (p != null) onLoaded();
      return;
    }
    if (await _mic.start(context, t) && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = pcm;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.graphic_eq_rounded, onTap: busy ? null : pickAudio)
      else ...[
        WaveView(peaks(p, 200), start: _sel.start, end: _sel.end),
        RangeSlider(values: _sel, onChanged: (v) => setState(() => _sel = v)),
        AppResult(
          label: L(t, 'duration'),
          value: '${fmtClock(p.seconds * _sel.start)} – ${fmtClock(p.seconds * _sel.end)} / ${fmtClock(p.seconds)}',
          lang: t.lang,
        ),
        ActionRow([
          AppButton(
            label: L(t, 'trim'),
            icon: Icons.content_cut_rounded,
            onPressed: () => _apply((x) => trimPcm(x, x.seconds * _sel.start, x.seconds * _sel.end)),
          ),
          AppButton(label: L(t, 'fade_in'), icon: Icons.trending_up_rounded, onPressed: () => _apply((x) => _onSelection(x, (s) => fadeIn(s, s.seconds)))),
          AppButton(label: L(t, 'fade_out'), icon: Icons.trending_down_rounded, onPressed: () => _apply((x) => _onSelection(x, (s) => fadeOut(s, s.seconds)))),
          AppButton(label: L(t, 'normalize'), icon: Icons.equalizer_rounded, onPressed: () => _apply((x) => _onSelection(x, (s) => normalizePeak(s)))),
          AppButton(label: '+3 dB', icon: Icons.volume_up_rounded, onPressed: () => _apply((x) => _onSelection(x, (s) => boost(s, 3)))),
          AppButton(label: '−3 dB', icon: Icons.volume_down_rounded, onPressed: () => _apply((x) => _onSelection(x, (s) => applyGain(s, -3)))),
          AppButton(label: L(t, 'reverse'), icon: Icons.swap_horiz_rounded, onPressed: () => _apply(reversePcm)),
        ]),
      ],
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: busy ? null : pickAudio),
        AppButton(
          label: _mic.recording ? L(t, 'stop') : L(t, 'record'),
          icon: _mic.recording ? Icons.stop_rounded : Icons.mic_rounded,
          onPressed: busy ? null : _record,
        ),
        if (p != null) ...[
          AppButton(label: t.core('undo'), icon: Icons.undo_rounded, onPressed: _undo.isEmpty ? null : () => setState(() => pcm = _undo.removeLast())),
          AppButton(label: t.core('play'), icon: Icons.play_arrow_rounded, onPressed: () => unawaited(_player.playWav(encodeWav(p)))),
          AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: () => savePcm(context, t, p, 'duzenle_$name', m4a: MedyaNative.supported)),
        ],
      ]),
    ]);
  }
}

// ================================================================ uyku sesleri

class SleepSoundsTool extends StatefulWidget {
  final ToolContext t;
  const SleepSoundsTool(this.t, {super.key});

  @override
  State<SleepSoundsTool> createState() => _SleepSoundsState();
}

class _SleepSoundsState extends State<SleepSoundsTool> {
  final Map<String, double> _levels = {for (final k in kNoiseIds) k: 0};
  final Map<String, Pcm> _cache = {};
  final TonePlayer _player = TonePlayer();
  int _timerMin = 0;
  Timer? _timer;
  DateTime? _endsAt;
  bool _playing = false, _busy = false;

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    _levels['rain'] = 0.7;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<Uint8List?> _mixWav() async {
    final parts = <Pcm>[], lv = <double>[];
    for (final e in _levels.entries) {
      if (e.value <= 0.01) continue;
      parts.add(_cache[e.key] ??= ambient(e.key, seed: e.key.hashCode & 0xff));
      lv.add(e.value);
    }
    if (parts.isEmpty) return null;
    return encodeWav(mix(parts, lv));
  }

  Future<void> _play() async {
    setState(() => _busy = true);
    final wav = await _mixWav();
    if (!mounted) return;
    setState(() => _busy = false);
    if (wav == null) {
      await _stop();
      return;
    }
    await _player.playWav(wav, loop: true);
    setState(() => _playing = true);
    _armTimer();
  }

  Future<void> _stop() async {
    _timer?.cancel();
    await _player.stop();
    if (mounted) {
      setState(() {
        _playing = false;
        _endsAt = null;
      });
    }
  }

  void _armTimer() {
    _timer?.cancel();
    _endsAt = null;
    if (_timerMin <= 0 || !_playing) return;
    _endsAt = DateTime.now().add(Duration(minutes: _timerMin));
    _timer = Timer.periodic(const Duration(seconds: 1), (tm) async {
      final end = _endsAt;
      if (end == null) return;
      final left = end.difference(DateTime.now()).inMilliseconds;
      if (left <= 0) {
        tm.cancel();
        await _stop();
      } else if (left < 20000) {
        await _player.setVolume(left / 20000);
      }
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final end = _endsAt;
    return ToolList(children: [
      for (final k in kNoiseIds)
        SliderRow(
          label: L(t, 'n_$k'),
          value: _levels[k] ?? 0,
          min: 0,
          max: 1,
          format: (v) => v <= 0.01 ? '—' : '${(v * 100).round()}',
          onChanged: (v) => setState(() => _levels[k] = v),
          onChangeEnd: (_) {
            if (_playing) unawaited(_play());
          },
        ),
      AppHeading(L(t, 'timer'), icon: Icons.timer_rounded),
      ChipsRow<int>(
        values: const [0, 15, 30, 45, 60, 90],
        label: (v) => v == 0 ? L(t, 'timer_off') : '$v min',
        selected: _timerMin,
        onChanged: (v) {
          setState(() => _timerMin = v);
          _armTimer();
        },
      ),
      if (end != null) AppResult(label: L(t, 'timer'), value: fmtClock(end.difference(DateTime.now()).inSeconds.toDouble()), lang: t.lang),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(
          label: _playing ? t.core('pause') : t.core('play'),
          icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          onPressed: _busy ? null : (_playing ? _stop : _play),
        ),
      ]),
    ]);
  }
}

// ================================================================ ses değiştirici

class VoiceChangerTool extends StatefulWidget {
  final ToolContext t;
  const VoiceChangerTool(this.t, {super.key});

  @override
  State<VoiceChangerTool> createState() => _VoiceChangerState();
}

class _VoiceChangerState extends State<VoiceChangerTool> with _AudioLoading {
  final MicRecorder _mic = MicRecorder();
  final TonePlayer _player = TonePlayer();
  String _fx = 'robot';
  Pcm? _out;

  ToolContext get t => widget.t;
  @override
  ToolContext get tool => widget.t;

  @override
  void dispose() {
    _mic.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  void onLoaded() => unawaited(_render());

  Future<void> _record() async {
    if (_mic.recording) {
      final p = await _mic.stop();
      if (!mounted) return;
      setState(() => pcm = p);
      if (p != null) await _render();
      return;
    }
    if (await _mic.start(context, t) && mounted) setState(() => _out = null);
  }

  Future<void> _render() async {
    final p = pcm;
    if (p == null) return;
    setState(() => busy = true);
    final out = await compute(_fxJob, (p, _fx));
    if (!mounted) return;
    setState(() {
      _out = out;
      busy = false;
    });
    unawaited(_player.playWav(encodeWav(out)));
  }

  @override
  Widget build(BuildContext context) {
    final out = _out;
    return ToolList(children: [
      AppPanel(
        child: Column(children: [
          IconButton.filled(
            iconSize: 64,
            onPressed: busy ? null : _record,
            icon: Icon(_mic.recording ? Icons.stop_rounded : Icons.mic_rounded),
          ),
          const SizedBox(height: 8),
          Text(_mic.recording ? L(t, 'recording') : L(t, 'record'), style: const TextStyle(color: Colors.white70)),
        ]),
      ),
      ChipsRow<String>(
        values: kVoiceIds,
        label: (k) => L(t, 'v_$k'),
        selected: _fx,
        onChanged: (v) {
          setState(() => _fx = v);
          unawaited(_render());
        },
      ),
      if (out != null) WaveView(peaks(out, 160)),
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: busy ? null : pickAudio),
        if (out != null) ...[
          AppButton(label: t.core('play'), icon: Icons.play_arrow_rounded, onPressed: () => unawaited(_player.playWav(encodeWav(out)))),
          AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: () => savePcm(context, t, out, 'ses_$_fx', m4a: MedyaNative.supported)),
        ],
      ]),
      AppInfoCard(L(t, 'mic_perm'), icon: Icons.lock_rounded),
    ]);
  }
}

Pcm _fxJob((Pcm, String) a) => voiceEffect(a.$1, a.$2);

// ================================================================ podcast kaydı

class PodcastTool extends StatefulWidget {
  final ToolContext t;
  const PodcastTool(this.t, {super.key});

  @override
  State<PodcastTool> createState() => _PodcastState();
}

class _PodcastState extends State<PodcastTool> {
  final AudioRecorder _rec = AudioRecorder();
  final TonePlayer _player = TonePlayer();
  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _levels = [];
  bool _recording = false, _paused = false;
  final Stopwatch _clock = Stopwatch();
  Timer? _tick;
  List<String> _episodes = [];
  final List<({String name, Uint8List bytes})> _webEpisodes = [];

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_ampSub?.cancel());
    unawaited(_rec.dispose());
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dir = await MediaFiles.appDir('podcast');
    if (dir == null) return;
    final list = await MediaFiles.list(dir, kIsWeb ? 'wav' : 'm4a');
    if (mounted) setState(() => _episodes = list);
  }

  Future<void> _start() async {
    if (!await rationaleOnce(context, t, 'mic', Icons.mic_rounded)) return;
    try {
      if (!await _rec.hasPermission()) return;
      String path = '';
      var cfg = const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 1);
      if (!kIsWeb) {
        final dir = await MediaFiles.appDir('podcast');
        if (dir == null) return;
        path = '$dir/bolum_${stamp()}.m4a';
        cfg = const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1, bitRate: 96000);
      }
      await _rec.start(cfg, path: path);
      _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
        final v = ((a.current + 50) / 50).clamp(0.0, 1.0);
        if (!mounted) return;
        setState(() {
          _levels.add(v);
          if (_levels.length > 120) _levels.removeAt(0);
        });
      });
      _clock
        ..reset()
        ..start();
      _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _recording = true;
        _paused = false;
      });
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  Future<void> _pauseResume() async {
    if (_paused) {
      await _rec.resume();
      _clock.start();
    } else {
      await _rec.pause();
      _clock.stop();
    }
    setState(() => _paused = !_paused);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _clock.stop();
    await _ampSub?.cancel();
    final path = await _rec.stop();
    if (kIsWeb && path != null) {
      final b = await XFile(path).readAsBytes();
      _webEpisodes.add((name: 'bolum_${stamp()}.wav', bytes: b));
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _levels.clear();
    });
    await _load();
  }

  Widget _episodeTile(String title, {required VoidCallback onPlay, required VoidCallback onShare, required VoidCallback onDelete}) {
    return ListTile(
      leading: const Icon(Icons.podcasts_rounded),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(children: [
        IconButton(icon: const Icon(Icons.play_arrow_rounded), onPressed: onPlay),
        IconButton(icon: const Icon(Icons.ios_share_rounded), onPressed: onShare),
        IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: onDelete),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLook.of(context);
    return ToolList(children: [
      AppPanel(
        child: Column(children: [
          Text(fmtClock(_clock.elapsedMilliseconds / 1000),
              style: TextStyle(color: s.number, fontSize: 48, fontWeight: FontWeight.w900)),
          SizedBox(
            height: 60,
            width: double.infinity,
            child: CustomPaint(painter: _LevelPainter(List<double>.of(_levels), s.accent)),
          ),
          Text(_recording ? (_paused ? t.core('pause') : L(t, 'recording')) : L(t, 'level'), style: const TextStyle(color: Colors.white70)),
        ]),
      ),
      ActionRow([
        if (!_recording)
          AppButton(label: L(t, 'record'), icon: Icons.fiber_manual_record_rounded, onPressed: _start)
        else ...[
          AppButton(
            label: _paused ? t.core('resume') : t.core('pause'),
            icon: _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            onPressed: _pauseResume,
          ),
          AppButton(label: L(t, 'stop'), icon: Icons.stop_rounded, onPressed: _stop),
        ],
      ]),
      AppHeading(L(t, 'episodes'), icon: Icons.list_rounded),
      if (_episodes.isEmpty && _webEpisodes.isEmpty) AppInfoCard(L(t, 'empty_list')),
      for (final e in _episodes)
        _episodeTile(
          e.split('/').last,
          onPlay: () => unawaited(_player.playSource(DeviceFileSource(e))),
          onShare: () => unawaited(MediaFiles.sharePath(e, 'audio/mp4')),
          onDelete: () async {
            await MediaFiles.delete(e);
            await _load();
          },
        ),
      for (final e in List.of(_webEpisodes))
        _episodeTile(
          e.name,
          onPlay: () => unawaited(_player.playWav(e.bytes)),
          onShare: () => saveFile(context, t, e.bytes, e.name, 'audio/wav'),
          onDelete: () => setState(() => _webEpisodes.remove(e)),
        ),
      AppInfoCard(L(t, 'mic_perm'), icon: Icons.lock_rounded),
    ]);
  }
}

class _LevelPainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  _LevelPainter(this.levels, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    const n = 120;
    final w = size.width / n;
    final p = Paint()..color = color;
    for (var i = 0; i < levels.length; i++) {
      final h = math.max(2.0, levels[i] * size.height);
      canvas.drawRect(Rect.fromLTWH((n - levels.length + i) * w, (size.height - h) / 2, math.max(1.0, w - 1), h), p);
    }
  }

  @override
  bool shouldRepaint(_LevelPainter old) => true;
}

// ================================================================ ses yükseltici

class VolumeBoosterTool extends StatefulWidget {
  final ToolContext t;
  const VolumeBoosterTool(this.t, {super.key});

  @override
  State<VolumeBoosterTool> createState() => _VolumeBoosterState();
}

class _VolumeBoosterState extends State<VolumeBoosterTool> with _AudioLoading {
  double _db = 6;
  final TonePlayer _player = TonePlayer();

  ToolContext get t => widget.t;
  @override
  ToolContext get tool => widget.t;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Pcm? _result() {
    final p = pcm;
    if (p == null) return null;
    final c = p.copy();
    boost(c, _db);
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final p = pcm;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.volume_up_rounded, onTap: busy ? null : pickAudio)
      else ...[
        WaveView(peaks(p, 160)),
        AppResult(label: L(t, 'level'), value: '${(20 * math.log(math.max(1e-6, peakOf(p))) / math.ln10).toStringAsFixed(1)} dBFS', lang: t.lang),
      ],
      SliderRow(
        label: L(t, 'gain'),
        value: _db,
        min: 0,
        max: 18,
        divisions: 18,
        format: (v) => '+${v.round()} dB',
        onChanged: (v) => setState(() => _db = v),
      ),
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: busy ? null : pickAudio),
        if (p != null) ...[
          AppButton(
            label: t.core('play'),
            icon: Icons.play_arrow_rounded,
            onPressed: () {
              final r = _result();
              if (r != null) unawaited(_player.playWav(encodeWav(r)));
            },
          ),
          AppButton(
            label: L(t, 'save'),
            icon: Icons.save_alt_rounded,
            onPressed: () {
              final r = _result();
              if (r != null) unawaited(savePcm(context, t, r, 'yuksek_$name', m4a: MedyaNative.supported));
            },
          ),
        ],
      ]),
    ]);
  }
}

// ================================================================ gürültü azaltma

class NoiseReducerTool extends StatefulWidget {
  final ToolContext t;
  const NoiseReducerTool(this.t, {super.key});

  @override
  State<NoiseReducerTool> createState() => _NoiseReducerState();
}

Pcm _denoiseJob((Pcm, double) a) => reduceNoise(a.$1, strength: a.$2);

class _NoiseReducerState extends State<NoiseReducerTool> with _AudioLoading {
  double _strength = 0.7;
  Pcm? _out;
  final TonePlayer _player = TonePlayer();
  final MicRecorder _mic = MicRecorder();

  ToolContext get t => widget.t;
  @override
  ToolContext get tool => widget.t;

  @override
  void dispose() {
    _player.dispose();
    _mic.dispose();
    super.dispose();
  }

  @override
  void onLoaded() => setState(() => _out = null);

  Future<void> _run() async {
    final p = pcm;
    if (p == null) return;
    setState(() => busy = true);
    final out = await compute(_denoiseJob, (p, _strength));
    if (!mounted) return;
    setState(() {
      _out = out;
      busy = false;
    });
  }

  Future<void> _record() async {
    if (_mic.recording) {
      final p = await _mic.stop();
      if (!mounted) return;
      setState(() {
        pcm = p;
        _out = null;
      });
      return;
    }
    if (await _mic.start(context, t) && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = pcm, out = _out;
    return ToolList(children: [
      if (p == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.hearing_rounded, onTap: busy ? null : pickAudio)
      else ...[
        WaveView(peaks(p, 160)),
        if (out != null) WaveView(peaks(out, 160)),
      ],
      SliderRow(label: L(t, 'strength'), value: _strength, min: 0.1, max: 1, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _strength = v)),
      if (busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: busy ? null : pickAudio),
        AppButton(
          label: _mic.recording ? L(t, 'stop') : L(t, 'record'),
          icon: _mic.recording ? Icons.stop_rounded : Icons.mic_rounded,
          onPressed: busy ? null : _record,
        ),
        if (p != null) AppButton(label: L(t, 'apply'), icon: Icons.auto_fix_high_rounded, onPressed: busy ? null : _run),
        if (p != null) AppButton(label: L(t, 'original'), icon: Icons.play_arrow_rounded, onPressed: () => unawaited(_player.playWav(encodeWav(p)))),
        if (out != null) ...[
          AppButton(label: L(t, 'result'), icon: Icons.play_circle_rounded, onPressed: () => unawaited(_player.playWav(encodeWav(out)))),
          AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: () => savePcm(context, t, out, 'temiz_$name', m4a: MedyaNative.supported)),
        ],
      ]),
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
    ]);
  }
}

// ================================================================ biçim dönüştürücü

class AudioConverterTool extends StatefulWidget {
  final ToolContext t;
  const AudioConverterTool(this.t, {super.key});

  @override
  State<AudioConverterTool> createState() => _AudioConverterState();
}

class _AudioConverterState extends State<AudioConverterTool> {
  Picked? _file;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    final ps = await MediaPick.audio();
    if (ps.isNotEmpty) setState(() => _file = ps.first);
  }

  String get _base {
    final n = _file?.name ?? 'ses';
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  Future<void> _toWav() async {
    final f = _file;
    if (f == null) return;
    setState(() => _busy = true);
    final p = await loadAudio(f);
    if (!mounted) return;
    if (p == null) {
      snack(context, L(t, MedyaNative.supported ? 'failed' : 'wav_hint'));
    } else {
      await saveFile(context, t, encodeWav(p), '$_base.wav', 'audio/wav');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toM4a() async {
    final f = _file;
    if (f == null) return;
    setState(() => _busy = true);
    var src = f.path;
    final bytes = f.bytes;
    if (src == null && bytes != null) src = await MediaFiles.writeTemp(bytes, f.name.split('.').last);
    final out = await MediaFiles.tempPath('m4a');
    final ok = src != null && out != null && await MedyaNative.encodeM4a(src, out);
    final b = ok ? await MediaFiles.read(out) : null;
    if (!mounted) return;
    if (b == null) {
      snack(context, L(t, 'failed'));
    } else {
      await saveFile(context, t, b, '$_base.m4a', 'audio/mp4');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return ToolList(children: [
      if (f == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.swap_horiz_rounded, onTap: _pick)
      else
        AppResult(label: L(t, 'format'), value: f.name, lang: t.lang),
      if (!MedyaNative.supported) AppInfoCard(L(t, 'wav_hint'), icon: Icons.info_outline_rounded),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'to_wav'), icon: Icons.graphic_eq_rounded, onPressed: _busy || f == null ? null : _toWav),
        if (MedyaNative.supported)
          AppButton(label: L(t, 'to_m4a'), icon: Icons.audiotrack_rounded, onPressed: _busy || f == null ? null : _toM4a),
      ]),
    ]);
  }
}
