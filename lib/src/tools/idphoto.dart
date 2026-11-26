/// Vesikalık ve biyometrik fotoğraf: ülke ölçü şablonları, cihazda yüz bulma
/// ile otomatik çerçeveleme, isteğe bağlı arka plan değiştirme (U²-Netp,
/// arka plan silme aracındaki model) ve 10×15 cm baskı sayfası.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/imaging.dart';
import '../ek4_core.dart';
import '../native.dart';
import '../platform/vision.dart';
import '../tx.dart';
import 'ai.dart' show Models, pickForAi;

Rgba _cutJob((Rgba, Uint8List) a) {
  final out = a.$1.copy();
  applyMask(out, a.$2, kU2Size, kU2Size);
  return out;
}

/// Ülke adı (33 dil, CLDR) ve belge türüyle şablon adı.
String idSpecName(ToolContext t, IdPhotoSpec s) {
  final kinds = L(t, 'id_kinds').split(',');
  final country = t.t(kMedyaL['cc_${s.country}'] ?? [s.country]);
  return '$country · ${kinds[s.kind.clamp(0, kinds.length - 1)].trim()}';
}

class IdPhotoTool extends StatefulWidget {
  final ToolContext t;
  const IdPhotoTool(this.t, {super.key});

  @override
  State<IdPhotoTool> createState() => _IdPhotoState();
}

class _IdPhotoState extends State<IdPhotoTool> {
  ToolContext get t => widget.t;

  int _specIndex = 0; // kIdPhotoSpecs içinde; -1 özel ölçü
  double _cw = 35, _chh = 45;
  ui.Image? _src, _cut;
  String? _path;
  double _scaleToOrig = 1; // özgün piksel / çözülen piksel
  Offset _center = Offset.zero; // kesim merkezi (çözülen piksel)
  double _zoom = 1;
  bool _replaceBg = false;
  int _bg = 0;
  bool _busy = false;
  double? _dl;
  bool? _hasModel;

  IdPhotoSpec get _spec => _specIndex >= 0
      ? kIdPhotoSpecs[_specIndex]
      : IdPhotoSpec('custom', '', 0, _cw, _chh, source: '-');

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final m = await t.store.readMap('idphoto');
      final i = (m['spec'] as num?)?.toInt();
      if (!mounted) return;
      setState(() {
        if (i != null && i >= -1 && i < kIdPhotoSpecs.length) _specIndex = i;
        _cw = ((m['cw'] as num?)?.toDouble() ?? _cw).clamp(10, 100).toDouble();
        _chh = ((m['ch'] as num?)?.toDouble() ?? _chh).clamp(10, 100).toDouble();
        if (_specIndex >= 0) _bg = kIdPhotoSpecs[_specIndex].background;
      });
    }());
  }

  void _persist() => unawaited(t.store.writeMap('idphoto', {'spec': _specIndex, 'cw': _cw, 'ch': _chh}));

  /// Kesim dikdörtgeni (çözülen görüntü pikselinde).
  Rect _crop() {
    final src = _src;
    if (src == null) return Rect.zero;
    final s = _spec;
    final h = src.height / _zoom;
    final w = h * s.widthMm / s.heightMm;
    return Rect.fromCenter(center: _center, width: w, height: h);
  }

  Future<void> _pick() async {
    var ow = 0, oh = 0;
    final r = await pickForAi(maxSide: 2400, onSize: (w, h) {
      ow = w;
      oh = h;
    });
    if (r == null || !mounted) return;
    setState(() {
      _src = r.image;
      _cut = null;
      _path = r.path;
      _scaleToOrig = ow > 0 ? ow / r.image.width : 1;
      _center = Offset(r.image.width / 2, r.image.height / 2);
      _zoom = math.max(1, r.image.height / (r.image.width * _spec.heightMm / _spec.widthMm));
      if (oh == 0) _scaleToOrig = 1;
    });
    await _autoFrame(quiet: true);
    if (_replaceBg) await _segment();
  }

  Future<void> _autoFrame({bool quiet = false}) async {
    final src = _src, path = _path;
    if (src == null) return;
    if (path == null || !Vision.supported) {
      if (!quiet && mounted) snack(context, L(t, 'id_no_face'));
      return;
    }
    setState(() => _busy = true);
    final faces = await Vision.faces(path);
    if (!mounted) return;
    setState(() => _busy = false);
    if (faces.isEmpty) {
      snack(context, L(t, 'id_no_face'));
      return;
    }
    // En büyük yüz; özgün pikselden çözülen piksele.
    final f = faces.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
    final k = 1 / _scaleToOrig;
    final face = Rect.fromLTRB(f.left * k, f.top * k, f.right * k, f.bottom * k);
    final c = idCropForFace(face, _spec);
    setState(() {
      _center = c.center;
      _zoom = (src.height / c.height).clamp(0.3, 8.0).toDouble();
    });
  }

  Future<void> _checkModel() async {
    final ok = await Models.ready(Models.u2netp);
    if (mounted) setState(() => _hasModel = ok);
  }

  void _download() {
    setState(() => _dl = 0);
    Models.download(Models.u2netp).listen(
      (p) {
        if (mounted) setState(() => _dl = p);
      },
      onError: (Object _) {
        if (mounted) {
          setState(() => _dl = null);
          snack(context, L(t, 'failed'));
        }
      },
      onDone: () async {
        await _checkModel();
        if (mounted) setState(() => _dl = null);
        if (_hasModel == true) await _segment();
      },
      cancelOnError: true,
    );
  }

  Future<void> _segment() async {
    final src = _src;
    if (src == null || _cut != null) return;
    if (_hasModel != true) return;
    setState(() => _busy = true);
    try {
      final rgba = await rgbaOf(src);
      final model = await Models.path(Models.u2netp);
      if (rgba == null || model == null) throw StateError('model');
      final out = await MedyaNative.onnx(model, u2Input(rgba), const [1, 3, kU2Size, kU2Size]);
      if (out == null || out.length < kU2Size * kU2Size) throw StateError('onnx');
      final mask = u2Mask(Float32List.sublistView(out, 0, kU2Size * kU2Size));
      final cut = await compute(_cutJob, (rgba, mask));
      final im = await uiOf(cut);
      if (mounted) setState(() => _cut = im);
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Bir kopyayı [dst] içine çizer (zemin + fotoğraf).
  void _paintPhoto(Canvas c, Rect dst) {
    final src = _src;
    if (src == null) return;
    final cut = _cut;
    final useCut = _replaceBg && cut != null;
    c.save();
    c.clipRect(dst);
    c.drawRect(dst, Paint()..color = Color(useCut ? kIdBackgrounds[_bg] : 0xFFFFFFFF));
    c.drawImageRect(useCut ? cut : src, _crop(), dst, Paint()..filterQuality = FilterQuality.high);
    c.restore();
  }

  Future<void> _save({required bool sheet}) async {
    if (_src == null) return;
    final s = _spec;
    setState(() => _busy = true);
    try {
      final pw = mmToPx(s.widthMm), ph = mmToPx(s.heightMm);
      final ui.Image out;
      if (!sheet) {
        out = await renderImage(pw, ph, (c, size) => _paintPhoto(c, Offset.zero & size));
      } else {
        const sw = 152.4, sh = 101.6; // 6×4 inç (10×15 cm)
        final slots = idSheetSlots(s, sheetW: sw, sheetH: sh);
        out = await renderImage(mmToPx(sw), mmToPx(sh), (c, size) {
          c.drawRect(Offset.zero & size, Paint()..color = Colors.white);
          final line = Paint()
            ..color = const Color(0xFFBDBDBD)
            ..strokeWidth = 1;
          for (final (x, y) in slots) {
            final r = Rect.fromLTWH(mmToPx(x).toDouble(), mmToPx(y).toDouble(), pw.toDouble(), ph.toDouble());
            _paintPhoto(c, r);
            c.drawRect(r.inflate(1), line..style = PaintingStyle.stroke);
          }
        });
      }
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      final jpg = await jpgOf(rgba, quality: 95);
      if (mounted) await saveImage(context, t, jpg, '${sheet ? 'vesikalik_sayfa' : 'vesikalik'}_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _preview() {
    final s = _spec;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 360),
          child: AspectRatio(
            aspectRatio: s.widthMm / s.heightMm,
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                onPanUpdate: (d) {
                  final k = _crop().height / box.maxHeight;
                  setState(() => _center -= d.delta * k);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CustomPaint(
                    size: Size(box.maxWidth, box.maxHeight),
                    painter: _IdPainter(this, s),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _bgControls() {
    if (!MedyaNative.supported) return [AppInfoCard(L(t, 'ai_local'), icon: Icons.block_rounded)];
    if (_hasModel == null) {
      unawaited(_checkModel());
      return const [];
    }
    if (_hasModel == false) {
      return [
        if (_dl != null)
          BusyLine(L(t, 'downloading'), progress: _dl)
        else
          ActionRow([
            AppButton(
              label: L(t, 'model_download', {'mb': Models.u2netp.mb}),
              icon: Icons.download_rounded,
              onPressed: _download,
            ),
          ]),
        AppInfoCard(L(t, 'model_once'), icon: Icons.wifi_off_rounded),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 10, children: [
          for (var i = 0; i < kIdBackgrounds.length; i++)
            GestureDetector(
              onTap: () => setState(() => _bg = i),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Color(kIdBackgrounds[i]),
                  shape: BoxShape.circle,
                  border: Border.all(color: _bg == i ? AppLook.of(context).accent : Colors.white24, width: _bg == i ? 3 : 1),
                ),
              ),
            ),
        ]),
      ),
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = _spec;
    final src = _src;
    return ToolList(children: [
      AppHeading(L(t, 'id_preset'), icon: Icons.badge_rounded),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DropdownButton<int>(
          isExpanded: true,
          value: _specIndex,
          items: [
            for (var i = 0; i < kIdPhotoSpecs.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text('${idSpecName(t, kIdPhotoSpecs[i])} · ${kIdPhotoSpecs[i].sizeText}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            DropdownMenuItem(value: -1, child: Text(L(t, 'id_custom'))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _specIndex = v;
              if (v >= 0) _bg = kIdPhotoSpecs[v].background;
            });
            _persist();
          },
        ),
      ),
      if (_specIndex < 0) ...[
        SliderRow(
          label: L(t, 'width'),
          value: _cw,
          min: 20,
          max: 80,
          divisions: 60,
          format: (v) => '${v.round()} mm',
          onChanged: (v) => setState(() => _cw = v.roundToDouble()),
          onChangeEnd: (_) => _persist(),
        ),
        SliderRow(
          label: L(t, 'height'),
          value: _chh,
          min: 20,
          max: 80,
          divisions: 60,
          format: (v) => '${v.round()} mm',
          onChanged: (v) => setState(() => _chh = v.roundToDouble()),
          onChangeEnd: (_) => _persist(),
        ),
      ] else
        AppInfoCard(
          [
            s.sizeText,
            if (s.hasHead) L(t, 'id_head', {'a': s.headMinMm.toStringAsFixed(0), 'b': s.headMaxMm.toStringAsFixed(0)}),
            '${L(t, 'id_source')}: ${s.source}',
          ].join(' · '),
          icon: Icons.straighten_rounded,
        ),
      if (src == null)
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.portrait_rounded, onTap: _busy ? null : _pick)
      else ...[
        _preview(),
        AppInfoCard(L(t, 'id_adjust_hint'), icon: Icons.pan_tool_rounded),
        SliderRow(
          label: L(t, 'id_zoom'),
          value: _zoom,
          min: 0.3,
          max: 8,
          format: (v) => '${v.toStringAsFixed(1)}×',
          onChanged: (v) => setState(() => _zoom = v),
        ),
        SwitchListTile(
          value: _replaceBg,
          title: Text(L(t, 'id_bg_replace')),
          onChanged: (v) {
            setState(() => _replaceBg = v);
            if (v) unawaited(_checkModel().then((_) => _segment()));
          },
        ),
        if (_replaceBg) ..._bgControls(),
      ],
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        if (src != null)
          AppButton(label: L(t, 'id_auto'), icon: Icons.face_retouching_natural_rounded, onPressed: _busy ? null : _autoFrame),
      ]),
      if (src != null)
        ActionRow([
          AppButton(label: L(t, 'id_single'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : () => _save(sheet: false)),
          AppButton(label: L(t, 'id_sheet'), icon: Icons.print_rounded, onPressed: _busy ? null : () => _save(sheet: true)),
        ]),
      AppInfoCard(L(t, 'id_tips'), icon: Icons.lightbulb_outline_rounded),
      AppInfoCard(L(t, 'id_no_guarantee'), icon: Icons.info_outline_rounded),
    ]);
  }
}

class _IdPainter extends CustomPainter {
  final _IdPhotoState st;
  final IdPhotoSpec spec;
  _IdPainter(this.st, this.spec);

  @override
  void paint(Canvas canvas, Size size) {
    st._paintPhoto(canvas, Offset.zero & size);
    // Baş kılavuzu: tepe–çene aralığı ve göz çizgisi.
    final headH = size.height * spec.headFraction;
    final top = (size.height - headH) * 0.42;
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xCCFF7043);
    canvas.drawOval(Rect.fromCenter(center: Offset(size.width / 2, top + headH / 2), width: headH * 0.72, height: headH), guide);
    final thin = Paint()
      ..strokeWidth = 1
      ..color = const Color(0x88FFFFFF);
    canvas.drawLine(Offset(0, top), Offset(size.width, top), thin);
    canvas.drawLine(Offset(0, top + headH), Offset(size.width, top + headH), thin);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), thin);
  }

  @override
  bool shouldRepaint(covariant _IdPainter old) => true;
}
