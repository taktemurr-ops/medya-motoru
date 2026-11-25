/// Ekran kaydedici (Android): MediaProjection + MediaRecorder ile ekranı
/// MP4 olarak kaydeder; isteğe bağlı mikrofon sesi, çözünürlük, kare hızı,
/// kalite, geri sayım, duraklat/sürdür. Kayıt bir ön plan hizmetinde sürer;
/// bildirimden durdurulabilir. Kayıtlar uygulama klasöründe tutulur; galeriye
/// kaydedilir, paylaşılır, silinir. iOS'ta uygulamalar ReplayKit ile yalnız
/// kendi ekranlarını kaydedebilir; sistem genelinde kayıt için Denetim
/// Merkezi'ndeki yerleşik "Ekran Kaydı" kullanılır (araç bunu anlatır).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../media_core.dart';
import '../native.dart';
import '../platform/files.dart';
import 'video.dart' show VideoPreview;

class ScreenRecorderTool extends StatefulWidget {
  final ToolContext t;
  const ScreenRecorderTool(this.t, {super.key});
  @override
  State<ScreenRecorderTool> createState() => _ScreenRecState();
}

class _ScreenRecState extends State<ScreenRecorderTool> {
  ToolContext get t => widget.t;
  int _short = 720, _fps = 30, _quality = 1, _countdown = 3;
  bool _audio = false;
  bool _recording = false, _paused = false, _waiting = false;
  int _elapsed = 0;
  String? _dir;
  List<String> _files = [];
  final Map<String, int> _sizes = {};
  Timer? _poll;

  bool get _android => MedyaNative.isAndroid;

  @override
  void initState() {
    super.initState();
    () async {
      final m = await t.store.readMap('screen');
      _short = (m['short'] as num?)?.toInt() ?? 720;
      _fps = (m['fps'] as num?)?.toInt() ?? 30;
      _quality = (m['quality'] as num?)?.toInt() ?? 1;
      _countdown = (m['countdown'] as num?)?.toInt() ?? 3;
      _audio = m['audio'] == true;
      if (_android) {
        _dir = await MediaFiles.appDir('ekran_kayitlari');
        await _refresh();
        _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _status());
      }
      if (mounted) setState(() {});
    }();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _persist() => t.store.writeMap('screen', {
        'short': _short, 'fps': _fps, 'quality': _quality, 'countdown': _countdown, 'audio': _audio,
      });

  Future<void> _refresh() async {
    final d = _dir;
    if (d == null) return;
    final files = await MediaFiles.list(d, 'mp4');
    for (final f in files) {
      _sizes[f] = await MediaFiles.size(f);
    }
    if (mounted) setState(() => _files = files);
  }

  Future<void> _status() async {
    final s = await MedyaNative.screenRecordStatus();
    if (!mounted) return;
    final stopped = _recording && !s.recording && !s.waiting;
    setState(() {
      _recording = s.recording;
      _paused = s.paused;
      _waiting = s.waiting;
      _elapsed = s.elapsedMs;
    });
    if (stopped) {
      await _refresh();
      if (mounted) snack(context, s.error == null ? L(t, 'rec_saved') : L(t, 'failed'));
    }
  }

  Future<void> _start() async {
    final d = _dir;
    if (d == null) return;
    var audio = _audio;
    if (audio) {
      final rec = AudioRecorder();
      try {
        audio = await rec.hasPermission();
      } catch (_) {
        audio = false;
      } finally {
        unawaited(rec.dispose());
      }
      if (!audio && mounted) snack(context, L(t, 'mic_perm'));
    }
    if (!mounted) return;
    final view = View.of(context);
    final px = view.physicalSize;
    final size = recordSize(px.width.round(), px.height.round(), _short);
    final ok = await MedyaNative.screenRecordStart(
      output: '$d/${recordFileName(DateTime.now())}',
      width: size.w,
      height: size.h,
      dpi: math.max(120, (view.devicePixelRatio * 160).round()),
      fps: _fps,
      bitrate: recordBitrate(size.w, size.h, _fps, _quality),
      audio: audio,
      delayMs: _countdown * 1000,
    );
    if (!mounted) return;
    if (!ok) {
      snack(context, L(t, 'rec_denied'));
    } else {
      setState(() => _waiting = _countdown > 0);
      await _status();
    }
  }

  Future<void> _play(String f) => showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          backgroundColor: Colors.black,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            VideoPreview(f),
            TextButton(onPressed: () => Navigator.pop(c), child: Text(t.core('ok'))),
          ]),
        ),
      );

  Future<void> _delete(String f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(L(t, 'delete_item_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.core('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.core('ok'))),
        ],
      ),
    );
    if (ok != true) return;
    await MediaFiles.delete(f);
    await _refresh();
  }

  Widget _chips<T>(String label, List<T> values, String Function(T) text, T sel, ValueChanged<T> on) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label, style: const TextStyle(color: Colors.white70))),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final v in values)
                ChoiceChip(
                  label: Text(text(v)),
                  selected: v == sel,
                  onSelected: _recording
                      ? null
                      : (_) {
                          setState(() => on(v));
                          _persist();
                        },
                ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return ToolList(children: [notAvailable(t)]);
    if (!_android) {
      return ToolList(children: [
        const SizedBox(height: 12),
        const Icon(Icons.screen_share_rounded, size: 64),
        AppInfoCard(L(t, 'rec_ios'), icon: Icons.info_outline_rounded),
      ]);
    }
    final q = [L(t, 'q_low'), L(t, 'q_medium'), L(t, 'q_high')];
    return ToolList(children: [
      AppPanel(
        child: Column(children: [
          Icon(_recording ? (_paused ? Icons.pause_circle_rounded : Icons.fiber_manual_record_rounded) : Icons.screen_share_rounded,
              size: 56, color: _recording && !_paused ? Colors.redAccent : Colors.white70),
          const SizedBox(height: 6),
          Text(
            _waiting ? L(t, 'rec_soon') : (_recording ? fmtTime(Duration(milliseconds: _elapsed)) : L(t, 'rec_ready')),
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: 10),
          if (!_recording && !_waiting)
            AppButton(label: L(t, 'rec_start'), icon: Icons.fiber_manual_record_rounded, onPressed: _start)
          else
            Wrap(spacing: 10, children: [
              if (_recording)
                OutlinedButton.icon(
                  onPressed: () async {
                    await MedyaNative.screenRecordPause(!_paused);
                    await _status();
                  },
                  icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  label: Text(L(t, _paused ? 'resume' : 'pause')),
                ),
              FilledButton.icon(
                onPressed: () async {
                  await MedyaNative.screenRecordStop();
                  await _status();
                },
                icon: const Icon(Icons.stop_rounded),
                label: Text(L(t, 'stop')),
              ),
            ]),
        ]),
      ),
      _chips<int>(L(t, 'resolution'), const [480, 720, 1080, 0], (v) => v == 0 ? L(t, 'original') : '${v}p', _short, (v) => _short = v),
      _chips<int>(L(t, 'frame_rate'), const [24, 30, 60], (v) => '$v fps', _fps, (v) => _fps = v),
      _chips<int>(L(t, 'quality'), const [0, 1, 2], (v) => q[v], _quality, (v) => _quality = v),
      _chips<int>(L(t, 'countdown'), const [0, 3, 5, 10], (v) => v == 0 ? L(t, 'timer_off') : '$v s', _countdown, (v) => _countdown = v),
      SwitchListTile(
        title: Text(L(t, 'mic_audio')),
        secondary: const Icon(Icons.mic_rounded),
        value: _audio,
        onChanged: _recording
            ? null
            : (b) {
                setState(() => _audio = b);
                _persist();
              },
      ),
      AppHeading(L(t, 'recordings'), icon: Icons.video_library_rounded),
      if (_files.isEmpty)
        Padding(padding: const EdgeInsets.all(16), child: Text(L(t, 'empty_list'), textAlign: TextAlign.center))
      else
        for (final f in _files)
          Card(
            child: ListTile(
              leading: IconButton(icon: const Icon(Icons.play_circle_rounded), onPressed: () => _play(f)),
              title: Text(f.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${((_sizes[f] ?? 0) / 1024 / 1024).toStringAsFixed(1)} MB'),
              trailing: PopupMenuButton<int>(
                onSelected: (i) async {
                  if (i == 0) {
                    final ok = await MediaFiles.saveVideo(f, f.split('/').last);
                    if (context.mounted) snack(context, ok ? L(t, 'saved') : L(t, 'failed'));
                  } else if (i == 1) {
                    await MediaFiles.sharePath(f, 'video/mp4');
                  } else {
                    await _delete(f);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 0, child: Text(L(t, 'save'))),
                  PopupMenuItem(value: 1, child: Text(L(t, 'share'))),
                  PopupMenuItem(value: 2, child: Text(L(t, 'delete'))),
                ],
              ),
            ),
          ),
      AppInfoCard(L(t, 'rec_note'), icon: Icons.privacy_tip_outlined),
    ]);
  }
}
