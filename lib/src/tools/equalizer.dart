/// Ekolayzır ve bas güçlendirici: uygulama içi oynatıcıda 10 bant + bas
/// (her platformda, cihazda DSP), hazır ayarlar, işlenmiş sesi kaydetme.
/// Android'de ayrıca, ses oturumunu duyuran diğer oynatıcılara sistem
/// eşitleyicisi uygulanabilir (Android'in izin verdiği tek yol; bkz. SystemEq).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/audio.dart';
import '../ek4_core.dart';
import '../native.dart';
import '../platform/files.dart';
import 'audio.dart' show savePcm;

const List<String> _bandLabels = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];

class EqualizerTool extends StatefulWidget {
  final ToolContext t;
  const EqualizerTool(this.t, {super.key});

  @override
  State<EqualizerTool> createState() => _EqualizerState();
}

class _EqualizerState extends State<EqualizerTool> {
  ToolContext get t => widget.t;

  List<double> _gains = List<double>.filled(10, 0);
  double _bass = 0;
  String _preset = 'flat';
  bool _system = false;
  int _sessions = 0;
  Timer? _poll, _debounce;

  Pcm? _pcm;
  String _name = 'ses';
  bool _busy = false;
  AudioPlayer? _player;
  bool _playing = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;
  final List<StreamSubscription<Object?>> _subs = [];
  String? _tempPath;
  int _renderId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final m = await t.store.readMap('eq');
      if (!mounted) return;
      final g = m['gains'];
      setState(() {
        if (g is List && g.length == 10) _gains = [for (final v in g) (v is num ? v.toDouble() : 0.0).clamp(-kEqMaxDb, kEqMaxDb).toDouble()];
        _bass = ((m['bass'] as num?)?.toDouble() ?? 0.0).clamp(0.0, kEqMaxDb);
        final p = m['preset'];
        if (p is String && kEqPresetIds.contains(p)) _preset = p;
      });
      if (m['system'] == true && MedyaNative.isAndroid) await _setSystem(true);
    }());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _debounce?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player?.dispose());
    final tp = _tempPath;
    if (tp != null) unawaited(MediaFiles.delete(tp));
    super.dispose();
  }

  void _persist() => unawaited(t.store.writeMap('eq', {'gains': _gains, 'bass': _bass, 'preset': _preset, 'system': _system}));

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _subs.add(p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    }));
    _subs.add(p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _player = p;
    return p;
  }

  void _changed() {
    _persist();
    if (_system) unawaited(MedyaNative.eqSystem(true, eqCurvePoints(_gains, _bass)));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => unawaited(_render(keepPlaying: true)));
  }

  void _applyPreset(String id) {
    final p = kEqPresets[id];
    setState(() {
      _preset = id;
      if (p != null) {
        _gains = List<double>.of(p.$1);
        _bass = p.$2;
      }
    });
    _changed();
  }

  Future<void> _pick() async {
    final ps = await MediaPick.audio();
    if (ps.isEmpty) return;
    final f = ps.first;
    setState(() => _busy = true);
    Pcm? p;
    try {
      p = await _decodeStereo(f);
    } catch (_) {
      p = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pcm = p;
      final dot = f.name.lastIndexOf('.');
      _name = dot > 0 ? f.name.substring(0, dot) : f.name;
    });
    if (p == null) {
      snack(context, L(t, MedyaNative.supported ? 'failed' : 'wav_hint'));
      return;
    }
    await _render(keepPlaying: false, autoplay: true);
  }

  /// Stereo çözme (uzun dosyalarda bellek için tek kanal).
  Future<Pcm?> _decodeStereo(Picked f) async {
    if (!MedyaNative.supported) return loadAudio(f);
    var src = f.path;
    final bytes = f.bytes;
    if (src == null && bytes != null) src = await MediaFiles.writeTemp(bytes, f.name.contains('.') ? f.name.split('.').last : 'bin');
    final out = await MediaFiles.tempPath('wav');
    if (src == null || out == null) return null;
    if (!await MedyaNative.decodeToWav(src, out, sampleRate: 44100, channels: 2)) return null;
    final b = await MediaFiles.read(out);
    unawaited(MediaFiles.delete(out));
    if (b == null) return null;
    final p = decodeWav(b);
    if (p != null && p.channels > 1 && p.seconds > 600) return toMono(p);
    return p;
  }

  /// İşlenmiş sesi hazırlar; çalıyorsa aynı konumdan sürdürür.
  Future<void> _render({required bool keepPlaying, bool autoplay = false}) async {
    final p = _pcm;
    if (p == null) return;
    final id = ++_renderId;
    setState(() => _busy = true);
    final out = await compute(applyEq, (p, List<double>.of(_gains), _bass));
    if (!mounted || id != _renderId) return;
    final wav = encodeWav(out);
    final player = _ensurePlayer();
    final wasPlaying = _playing;
    final at = _pos;
    try {
      Source src;
      if (MediaFiles.hasFileSystem) {
        final path = await MediaFiles.writeTemp(wav, 'wav');
        if (path == null) throw StateError('temp');
        final old = _tempPath;
        _tempPath = path;
        src = DeviceFileSource(path);
        if (old != null) unawaited(MediaFiles.delete(old));
      } else {
        src = BytesSource(wav, mimeType: 'audio/wav');
      }
      await player.stop();
      if ((keepPlaying && wasPlaying) || autoplay) {
        await player.play(src, position: keepPlaying ? at : Duration.zero);
      } else {
        await player.setSource(src);
        if (keepPlaying && at > Duration.zero) await player.seek(at);
      }
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted && id == _renderId) setState(() => _busy = false);
  }

  Future<void> _setSystem(bool on) async {
    final ok = await MedyaNative.eqSystem(on, eqCurvePoints(_gains, _bass));
    if (!mounted) return;
    setState(() => _system = on && ok);
    _poll?.cancel();
    if (_system) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        final n = await MedyaNative.eqSessions();
        if (mounted) setState(() => _sessions = n);
      });
    } else {
      _sessions = 0;
      if (on && !ok && mounted) snack(context, L(t, 'failed'));
    }
    _persist();
  }

  Future<void> _savePcm() async {
    final p = _pcm;
    if (p == null) return;
    setState(() => _busy = true);
    final out = await compute(applyEq, (p, List<double>.of(_gains), _bass));
    if (mounted) await savePcm(context, t, out, 'eq_$_name', m4a: MedyaNative.supported);
    if (mounted) setState(() => _busy = false);
  }

  Widget _bands() {
    final s = AppLook.of(context);
    return SizedBox(
      height: 220,
      child: Row(children: [
        for (var i = 0; i < 10; i++)
          Expanded(
            child: Column(children: [
              Text('${_gains[i] >= 0 ? '+' : ''}${_gains[i].round()}', style: const TextStyle(fontSize: 11, color: Colors.white70)),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: _gains[i],
                      min: -kEqMaxDb,
                      max: kEqMaxDb,
                      divisions: 24,
                      activeColor: s.accent,
                      onChanged: (v) => setState(() {
                        _gains[i] = v;
                        _preset = 'custom';
                      }),
                      onChangeEnd: (_) => _changed(),
                    ),
                  ),
                ),
              ),
              Text(_bandLabels[i], style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLook.of(context);
    final names = L(t, 'eq_presets').split(',');
    final p = _pcm;
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(height: 90, child: CustomPaint(painter: _CurvePainter(_gains, _bass, s.accent), size: Size.infinite)),
      ),
      ChipsRow<String>(
        values: kEqPresetIds,
        label: (id) => names[kEqPresetIds.indexOf(id).clamp(0, names.length - 1)].trim(),
        selected: _preset,
        onChanged: (id) {
          if (id != 'custom') _applyPreset(id);
        },
      ),
      _bands(),
      SliderRow(
        label: L(t, 'eq_bass'),
        value: _bass,
        min: 0,
        max: kEqMaxDb,
        divisions: 12,
        format: (v) => '+${v.round()} dB',
        onChanged: (v) => setState(() {
          _bass = v;
          _preset = 'custom';
        }),
        onChangeEnd: (_) => _changed(),
      ),
      AppHeading(L(t, 'eq_inapp'), icon: Icons.headphones_rounded),
      if (p == null)
        PickPrompt(label: L(t, 'pick_audio'), icon: Icons.equalizer_rounded, onTap: _busy ? null : _pick)
      else
        AppPanel(
          child: Column(children: [
            Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: _pos.inMilliseconds.clamp(0, math.max<int>(1, _dur.inMilliseconds)).toDouble(),
              max: math.max<int>(1, _dur.inMilliseconds).toDouble(),
              onChanged: (v) => unawaited(_player?.seek(Duration(milliseconds: v.round()))),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(fmtClock(_pos.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
              IconButton.filled(
                iconSize: 36,
                onPressed: _busy && _player == null
                    ? null
                    : () {
                        final pl = _ensurePlayer();
                        unawaited(_playing ? pl.pause() : pl.resume());
                      },
                icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              Text(fmtClock(_dur.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
            ]),
          ]),
        ),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_audio'), icon: Icons.audio_file_rounded, onPressed: _busy ? null : _pick),
        if (p != null) AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _savePcm),
      ]),
      AppHeading(L(t, 'eq_system'), icon: Icons.settings_suggest_rounded),
      if (MedyaNative.isAndroid) ...[
        SwitchListTile(
          value: _system,
          title: Text(L(t, 'eq_system_on')),
          subtitle: _system ? Text(L(t, 'eq_sessions', {'n': _sessions})) : null,
          onChanged: (v) => unawaited(_setSystem(v)),
        ),
        AppInfoCard(L(t, 'eq_system_note'), icon: Icons.info_outline_rounded),
      ] else
        AppInfoCard(L(t, 'eq_ios'), icon: Icons.info_outline_rounded),
    ]);
  }
}

class _CurvePainter extends CustomPainter {
  final List<double> gains;
  final double bass;
  final Color color;
  _CurvePainter(this.gains, this.bass, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Colors.white24);
    final path = Path();
    const n = 60;
    for (var i = 0; i <= n; i++) {
      final f = 20 * math.pow(1000, i / n).toDouble();
      final db = eqCurveDb(f, gains, bass).clamp(-18.0, 18.0);
      final x = size.width * i / n, y = mid - db / 18 * (size.height / 2 - 4);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => true;
}
