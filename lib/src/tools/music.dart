/// Müzik yapma araçları: davul pedi, piyano, döngü/ritim yapıcı ve
/// sentezleyici. Bütün sesler cihazda sentezlenir (hazır örnek kullanılmaz).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/audio.dart';

final Map<String, Uint8List> _drumWavs = {};

Uint8List drumWav(String kind) => _drumWavs[kind] ??= encodeWav(drum(kind));

const List<Color> _padColors = [
  Color(0xFFEF5350), Color(0xFFFFA726), Color(0xFFFFEE58), Color(0xFF66BB6A), //
  Color(0xFF26C6DA), Color(0xFF42A5F5), Color(0xFFAB47BC), Color(0xFFEC407A),
];

/// Basılan seslerin zamanlı kaydı ve geri çalınması.
class TapRecorder {
  final List<(int, String)> events = [];
  final Stopwatch _sw = Stopwatch();
  bool recording = false;
  final List<Timer> _timers = [];

  void start() {
    events.clear();
    _sw
      ..reset()
      ..start();
    recording = true;
  }

  void stop() {
    _sw.stop();
    recording = false;
  }

  void add(String id) {
    if (recording) events.add((_sw.elapsedMilliseconds, id));
  }

  void play(void Function(String id) hit) {
    cancel();
    for (final e in events) {
      _timers.add(Timer(Duration(milliseconds: e.$1), () => hit(e.$2)));
    }
  }

  void cancel() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }
}

Widget _recordBar(ToolContext t, TapRecorder rec, VoidCallback onChanged, void Function(String id) hit) {
  return ActionRow([
    AppButton(
      label: rec.recording ? L(t, 'stop') : L(t, 'record'),
      icon: rec.recording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded,
      onPressed: () {
        if (rec.recording) {
          rec.stop();
        } else {
          rec.start();
        }
        onChanged();
      },
    ),
    AppButton(
      label: t.core('play'),
      icon: Icons.play_arrow_rounded,
      onPressed: rec.recording || rec.events.isEmpty ? null : () => rec.play(hit),
    ),
  ]);
}

// ================================================================ davul pedi

class DrumPadTool extends StatefulWidget {
  final ToolContext t;
  const DrumPadTool(this.t, {super.key});

  @override
  State<DrumPadTool> createState() => _DrumPadState();
}

class _DrumPadState extends State<DrumPadTool> {
  final VoicePool _pool = VoicePool(8);
  final TapRecorder _rec = TapRecorder();
  String? _lit;

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _rec.cancel();
    _pool.dispose();
    super.dispose();
  }

  void _hit(String id) {
    unawaited(_pool.play(drumWav(id)));
    _rec.add(id);
    if (!mounted) return;
    setState(() => _lit = id);
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted && _lit == id) setState(() => _lit = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            for (var i = 0; i < kDrumIds.length; i++)
              Listener(
                onPointerDown: (_) => _hit(kDrumIds[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  decoration: BoxDecoration(
                    color: _padColors[i].withValues(alpha: _lit == kDrumIds[i] ? 1 : 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    L(t, 'd_${kDrumIds[i]}'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
          ],
        ),
      ),
      _recordBar(t, _rec, () => setState(() {}), _hit),
    ]);
  }
}

// ================================================================ piyano

class PianoKeyboard extends StatelessWidget {
  final int baseMidi;
  final int octaves;
  final Set<int> lit;
  final void Function(int midi) onDown;
  const PianoKeyboard({super.key, required this.baseMidi, this.octaves = 2, required this.lit, required this.onDown});

  static const _whiteSteps = [0, 2, 4, 5, 7, 9, 11];
  static const _blackSteps = {0: 1, 1: 3, 3: 6, 4: 8, 5: 10};

  @override
  Widget build(BuildContext context) {
    final whites = <int>[
      for (var o = 0; o < octaves; o++)
        for (final s in _whiteSteps) baseMidi + o * 12 + s,
      baseMidi + octaves * 12,
    ];
    final accent = AppLook.of(context).accent;
    return SizedBox(
      height: 220,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / whites.length;
        final blacks = <(double, int)>[];
        for (var i = 0; i < whites.length - 1; i++) {
          final step = i % 7;
          final b = _blackSteps[step];
          if (b != null) blacks.add(((i + 1) * w - w * 0.3, baseMidi + (i ~/ 7) * 12 + b));
        }
        return Stack(children: [
          Row(children: [
            for (final m in whites)
              Expanded(
                child: Listener(
                  onPointerDown: (_) => onDown(m),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: lit.contains(m) ? accent : Colors.white,
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                    ),
                    alignment: Alignment.bottomCenter,
                    padding: const EdgeInsets.only(bottom: 6),
                    child: m % 12 == 0
                        ? Text('C${m ~/ 12 - 1}', style: const TextStyle(color: Colors.black54, fontSize: 11))
                        : null,
                  ),
                ),
              ),
          ]),
          for (final b in blacks)
            Positioned(
              left: b.$1,
              top: 0,
              width: w * 0.6,
              height: 132,
              child: Listener(
                onPointerDown: (_) => onDown(b.$2),
                child: Container(
                  decoration: BoxDecoration(
                    color: lit.contains(b.$2) ? accent : const Color(0xFF1B1B1B),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                  ),
                ),
              ),
            ),
        ]);
      }),
    );
  }
}

class PianoTool extends StatefulWidget {
  final ToolContext t;
  const PianoTool(this.t, {super.key});

  @override
  State<PianoTool> createState() => _PianoState();
}

class _PianoState extends State<PianoTool> {
  static final Map<int, Uint8List> _cache = {};
  final VoicePool _pool = VoicePool(8);
  final TapRecorder _rec = TapRecorder();
  final Set<int> _lit = {};
  int _base = 60;

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _rec.cancel();
    _pool.dispose();
    super.dispose();
  }

  void _down(int midi) {
    unawaited(_pool.play(_cache[midi] ??= encodeWav(pianoNote(midi))));
    _rec.add('$midi');
    if (!mounted) return;
    setState(() => _lit.add(midi));
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _lit.remove(midi));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: PianoKeyboard(baseMidi: _base, lit: _lit, onDown: _down),
      ),
      Choice<int>(
        values: const [36, 48, 60, 72],
        labels: const ['C2', 'C3', 'C4', 'C5'],
        selected: _base,
        onChanged: (v) => setState(() => _base = v),
      ),
      _recordBar(t, _rec, () => setState(() {}), (id) => _down(int.parse(id))),
    ]);
  }
}

// ================================================================ döngü ve ritim

class LoopMakerTool extends StatefulWidget {
  final ToolContext t;
  const LoopMakerTool(this.t, {super.key});

  @override
  State<LoopMakerTool> createState() => _LoopMakerState();
}

class _LoopMakerState extends State<LoopMakerTool> {
  static const int _steps = 16;
  List<List<bool>> _grid = List<List<bool>>.generate(kDrumIds.length, (_) => List<bool>.filled(_steps, false));
  double _bpm = 100;
  final TonePlayer _player = TonePlayer();
  final Stopwatch _sw = Stopwatch();
  Timer? _tick;
  bool _playing = false;

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final s = await t.store.read('grid');
    final bpm = await t.store.readDouble('bpm', 100);
    if (!mounted) return;
    setState(() {
      _bpm = bpm.clamp(60, 180).toDouble();
      if (s != null && s.length == kDrumIds.length * _steps) {
        _grid = [
          for (var r = 0; r < kDrumIds.length; r++) [for (var c = 0; c < _steps; c++) s[r * _steps + c] == '1'],
        ];
      } else {
        // Başlangıç ritmi.
        for (var c = 0; c < _steps; c += 4) {
          _grid[0][c] = true;
        }
        _grid[1][4] = _grid[1][12] = true;
        for (var c = 0; c < _steps; c += 2) {
          _grid[2][c] = true;
        }
      }
    });
  }

  Future<void> _save() async {
    await t.store.write('grid', [for (final r in _grid) for (final v in r) v ? '1' : '0'].join());
    await t.store.write('bpm', _bpm.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    await _player.playWav(encodeWav(renderPattern(_grid, _bpm)), loop: true);
    _sw
      ..reset()
      ..start();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _sw.stop();
    await _player.stop();
    if (mounted) setState(() => _playing = false);
  }

  void _changed() {
    unawaited(_save());
    if (_playing) unawaited(_play());
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLook.of(context);
    final stepMs = 60000 / _bpm / 4;
    final cur = _playing ? (_sw.elapsedMilliseconds / stepMs).floor() % _steps : -1;
    return ToolList(children: [
      for (var r = 0; r < kDrumIds.length; r++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(children: [
            SizedBox(
              width: 64,
              child: Text(L(t, 'd_${kDrumIds[r]}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            for (var c = 0; c < _steps; c++)
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _grid[r][c] = !_grid[r][c]);
                    _changed();
                  },
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      margin: EdgeInsets.only(left: c % 4 == 0 ? 3 : 1, right: 1),
                      decoration: BoxDecoration(
                        color: _grid[r][c]
                            ? _padColors[r]
                            : (c == cur ? Colors.white24 : Colors.white.withValues(alpha: c % 4 == 0 ? 0.12 : 0.06)),
                        borderRadius: BorderRadius.circular(4),
                        border: c == cur ? Border.all(color: s.accent) : null,
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      SliderRow(
        label: L(t, 'tempo'),
        value: _bpm,
        min: 60,
        max: 180,
        divisions: 120,
        format: (v) => '${v.round()} BPM',
        onChanged: (v) => setState(() => _bpm = v),
        onChangeEnd: (_) => _changed(),
      ),
      ActionRow([
        AppButton(
          label: _playing ? L(t, 'stop') : t.core('play'),
          icon: _playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
          onPressed: _playing ? _stop : _play,
        ),
        AppButton(
          label: L(t, 'clear'),
          icon: Icons.clear_all_rounded,
          onPressed: () {
            setState(() {
              for (final row in _grid) {
                row.fillRange(0, row.length, false);
              }
            });
            _changed();
          },
        ),
        AppButton(
          label: L(t, 'save'),
          icon: Icons.save_alt_rounded,
          onPressed: () => saveFile(context, t, encodeWav(renderPattern(_grid, _bpm, loops: 4)), 'ritim_${_bpm.round()}bpm_${stamp()}.wav', 'audio/wav'),
        ),
      ]),
    ]);
  }
}

// ================================================================ sentezleyici

class SynthTool extends StatefulWidget {
  final ToolContext t;
  const SynthTool(this.t, {super.key});

  @override
  State<SynthTool> createState() => _SynthState();
}

class _SynthState extends State<SynthTool> {
  final VoicePool _pool = VoicePool(8);
  final Map<int, Uint8List> _cache = {};
  final Set<int> _lit = {};
  String _wave = 'saw';
  double _a = 0.01, _d = 0.2, _s = 0.6, _r = 0.3, _cut = 3000;
  int _base = 48;

  ToolContext get t => widget.t;

  SynthPatch get _patch => SynthPatch(wave: _wave, attack: _a, decay: _d, sustain: _s, release: _r, cutoff: _cut);

  @override
  void dispose() {
    _pool.dispose();
    super.dispose();
  }

  void _invalidate() => _cache.clear();

  void _down(int midi) {
    unawaited(_pool.play(_cache[midi] ??= encodeWav(synthNote(midi, _patch, hold: 0.35))));
    setState(() => _lit.add(midi));
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _lit.remove(midi));
    });
  }

  Widget _knob(String key, double v, double min, double max, ValueChanged<double> f, {String Function(double)? fmt}) =>
      SliderRow(
        label: L(t, key),
        value: v,
        min: min,
        max: max,
        format: fmt ?? ((x) => x.toStringAsFixed(2)),
        onChanged: (x) => setState(() => f(x)),
        onChangeEnd: (_) => _invalidate(),
      );

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: PianoKeyboard(baseMidi: _base, octaves: 1, lit: _lit, onDown: _down),
      ),
      Choice<int>(
        values: const [36, 48, 60, 72],
        labels: const ['C2', 'C3', 'C4', 'C5'],
        selected: _base,
        onChanged: (v) => setState(() => _base = v),
      ),
      ChipsRow<String>(
        values: kWaveIds,
        label: (w) => L(t, 'w_$w'),
        selected: _wave,
        onChanged: (v) {
          setState(() => _wave = v);
          _invalidate();
        },
      ),
      _knob('attack', _a, 0.001, 1, (x) => _a = x),
      _knob('decay', _d, 0.01, 1.5, (x) => _d = x),
      _knob('sustain', _s, 0, 1, (x) => _s = x),
      _knob('release', _r, 0.02, 2, (x) => _r = x),
      _knob('cutoff', _cut, 200, 12000, (x) => _cut = x, fmt: (x) => '${x.round()} Hz'),
    ]);
  }
}
