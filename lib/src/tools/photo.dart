/// Fotoğraf araçları: düzenleyici, kolaj, kırp ve boyutlandır, sıkıştırma,
/// filigran, görselden PDF, bilgi silici, kopya bulucu, ekran görüntüsü
/// düzenleyici ve filtreli kamera.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/imaging.dart';

String _filterLabel(ToolContext t, String id) => L(t, 'f_$id');

/// Dönüşüm + renk matrisiyle yeniden çizer.
Future<ui.Image> transformImage(ui.Image src, {int quarter = 0, bool flip = false, List<double>? matrix}) {
  final odd = quarter.isOdd;
  final w = odd ? src.height : src.width, h = odd ? src.width : src.height;
  return renderImage(w, h, (c, s) {
    c.translate(w / 2, h / 2);
    c.rotate(quarter * math.pi / 2);
    if (flip) c.scale(-1, 1);
    final p = Paint()..filterQuality = FilterQuality.high;
    if (matrix != null) p.colorFilter = ColorFilter.matrix(matrix);
    c.drawImage(src, Offset(-src.width / 2, -src.height / 2), p);
  });
}

// ================================================================ düzenleyici

class PhotoEditorTool extends StatefulWidget {
  final ToolContext t;
  const PhotoEditorTool(this.t, {super.key});

  @override
  State<PhotoEditorTool> createState() => _PhotoEditorState();
}

class _PhotoEditorState extends State<PhotoEditorTool> {
  ui.Image? _img;
  bool _busy = false;
  double _bright = 0, _contrast = 0, _sat = 1, _warm = 0, _sharp = 0, _vig = 0;
  String _filter = 'none';
  int _quarter = 0;
  bool _flip = false;

  ToolContext get t => widget.t;

  List<double> get _matrix =>
      editMatrix(brightness: _bright, contrast: _contrast, saturation: _sat, warmth: _warm, filter: _filter);

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    setState(() => _busy = true);
    final im = await decodeUi(b);
    if (!mounted) return;
    setState(() {
      _img = im;
      _busy = false;
    });
  }

  void _reset() => setState(() {
        _bright = _contrast = _warm = _sharp = _vig = 0;
        _sat = 1;
        _filter = 'none';
        _quarter = 0;
        _flip = false;
      });

  Future<void> _save() async {
    final src = _img;
    if (src == null) return;
    setState(() => _busy = true);
    try {
      final out = await transformImage(src, quarter: _quarter, flip: _flip, matrix: _matrix);
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      sharpen(rgba, _sharp);
      vignette(rgba, _vig);
      final jpg = await jpgOf(rgba, quality: 92);
      if (mounted) await saveImage(context, t, jpg, 'foto_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final im = _img;
    if (im == null) {
      return ToolList(children: [
        if (_busy) BusyLine(L(t, 'processing')),
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.add_photo_alternate_rounded, onTap: _busy ? null : _pick),
      ]);
    }
    Widget preview = ImagePreview(im, matrix: _matrix);
    if (_vig > 0) {
      preview = Stack(alignment: Alignment.center, children: [
        preview,
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: RadialGradient(
                      colors: [Colors.transparent, Colors.black.withValues(alpha: _vig * 0.8)], stops: const [0.55, 1]),
                ),
              ),
            ),
          ),
        ),
      ]);
    }
    preview = RotatedBox(quarterTurns: _quarter, child: Transform.flip(flipX: _flip, child: preview));
    return ToolList(children: [
      preview,
      ChipsRow<String>(
        values: kFilterIds,
        label: (id) => _filterLabel(t, id),
        selected: _filter,
        onChanged: (v) => setState(() => _filter = v),
      ),
      SliderRow(label: L(t, 'brightness'), value: _bright, min: -1, max: 1, onChanged: (v) => setState(() => _bright = v)),
      SliderRow(label: L(t, 'contrast'), value: _contrast, min: -0.8, max: 0.8, onChanged: (v) => setState(() => _contrast = v)),
      SliderRow(label: L(t, 'saturation'), value: _sat, min: 0, max: 2, onChanged: (v) => setState(() => _sat = v)),
      SliderRow(label: L(t, 'warmth'), value: _warm, min: -1, max: 1, onChanged: (v) => setState(() => _warm = v)),
      SliderRow(label: L(t, 'sharpen'), value: _sharp, min: 0, max: 1, onChanged: (v) => setState(() => _sharp = v)),
      SliderRow(label: L(t, 'vignette'), value: _vig, min: 0, max: 1, onChanged: (v) => setState(() => _vig = v)),
      ActionRow([
        AppButton(label: L(t, 'rotate'), icon: Icons.rotate_90_degrees_cw_rounded, onPressed: () => setState(() => _quarter = (_quarter + 1) % 4)),
        AppButton(label: L(t, 'flip'), icon: Icons.flip_rounded, onPressed: () => setState(() => _flip = !_flip)),
        AppButton(label: L(t, 'reset'), icon: Icons.restart_alt_rounded, onPressed: _reset),
      ]),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ kolaj

const List<int> kSwatches = [
  0xFFFFFFFF, 0xFF000000, 0xFF263238, 0xFFFFE0B2, 0xFFF8BBD0, 0xFFB3E5FC, 0xFFC8E6C9, 0xFFFFF59D, 0xFFD1C4E9, 0xFFFF7043,
];

class CollagePainter extends CustomPainter {
  final List<ui.Image> images;
  final List<List<double>> cells;
  final double spacing;
  final double radius;
  final Color background;
  CollagePainter(this.images, this.cells, this.spacing, this.radius, this.background);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final gap = spacing * size.shortestSide;
    for (var i = 0; i < cells.length && i < images.length; i++) {
      final c = cells[i];
      final r = Rect.fromLTWH(c[0] * size.width + gap / 2, c[1] * size.height + gap / 2, c[2] * size.width - gap,
          c[3] * size.height - gap);
      if (r.width <= 0 || r.height <= 0) continue;
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(r, Radius.circular(radius * size.shortestSide)));
      paintImage(canvas: canvas, rect: r, image: images[i], fit: BoxFit.cover, filterQuality: FilterQuality.high);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CollagePainter old) => true;
}

class CollageTool extends StatefulWidget {
  final ToolContext t;
  const CollageTool(this.t, {super.key});

  @override
  State<CollageTool> createState() => _CollageState();
}

class _CollageState extends State<CollageTool> {
  final List<ui.Image> _imgs = [];
  int _variant = 0;
  double _spacing = 0.015, _radius = 0.02;
  int _bg = 0;
  double _ratio = 1;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    final ps = await MediaPick.images();
    if (ps.isEmpty) return;
    setState(() => _busy = true);
    final list = <ui.Image>[];
    for (final p in ps.take(9)) {
      final b = await p.read();
      if (b == null) continue;
      final im = await decodeUi(b, maxSide: 2048);
      if (im != null) list.add(im);
    }
    if (!mounted) return;
    setState(() {
      _imgs
        ..clear()
        ..addAll(list);
      _busy = false;
    });
  }

  Future<void> _save() async {
    if (_imgs.isEmpty) return;
    setState(() => _busy = true);
    try {
      const w = 2400;
      final h = (w / _ratio).round();
      final painter = CollagePainter(_imgs, collageCells(_imgs.length, _variant), _spacing, _radius, Color(kSwatches[_bg]));
      final out = await renderImage(w, h, (c, s) => painter.paint(c, s));
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      final jpg = await jpgOf(rgba, quality: 92);
      if (mounted) await saveImage(context, t, jpg, 'kolaj_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_imgs.isEmpty) {
      return ToolList(children: [
        if (_busy) BusyLine(L(t, 'processing')),
        PickPrompt(label: L(t, 'pick_photos'), icon: Icons.dashboard_customize_rounded, onTap: _busy ? null : _pick),
      ]);
    }
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: AspectRatio(
              aspectRatio: _ratio,
              child: CustomPaint(
                painter: CollagePainter(
                    _imgs, collageCells(_imgs.length, _variant), _spacing, _radius, Color(kSwatches[_bg])),
              ),
            ),
          ),
        ),
      ),
      Choice<double>(
        values: const [1.0, 0.8, 0.5625],
        labels: [L(t, 'sz_square'), L(t, 'sz_portrait'), L(t, 'sz_story')],
        selected: _ratio,
        onChanged: (v) => setState(() => _ratio = v),
      ),
      ActionRow([
        AppButton(
            label: L(t, 'layout'),
            icon: Icons.view_quilt_rounded,
            onPressed: () => setState(() => _variant = (_variant + 1) % 3)),
      ]),
      SliderRow(
          label: L(t, 'border'),
          value: _spacing,
          min: 0,
          max: 0.06,
          format: (v) => '${(v * 1000).round()}',
          onChanged: (v) => setState(() => _spacing = v)),
      SliderRow(
          label: L(t, 'corner'),
          value: _radius,
          min: 0,
          max: 0.08,
          format: (v) => '${(v * 1000).round()}',
          onChanged: (v) => setState(() => _radius = v)),
      _SwatchRow(selected: _bg, onChanged: (i) => setState(() => _bg = i)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photos'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

class _SwatchRow extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  final List<int> colors;
  const _SwatchRow({required this.selected, required this.onChanged, this.colors = kSwatches});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < colors.length; i++)
          GestureDetector(
            onTap: () => onChanged(i),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Color(colors[i]),
                shape: BoxShape.circle,
                border: Border.all(color: i == selected ? Colors.white : Colors.white24, width: i == selected ? 3 : 1),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Renk seçici satırı (diğer araçlar da kullanır).
Widget swatchRow(int selected, ValueChanged<int> onChanged, {List<int> colors = kSwatches}) =>
    _SwatchRow(selected: selected, onChanged: onChanged, colors: colors);

// ================================================================ kırp ve boyutlandır

class CropResizeTool extends StatefulWidget {
  final ToolContext t;
  const CropResizeTool(this.t, {super.key});

  @override
  State<CropResizeTool> createState() => _CropState();
}

class _CropState extends State<CropResizeTool> {
  ui.Image? _img;
  bool _busy = false;
  double _ratio = 0; // 0: serbest (özgün)
  double _px = 0.5, _py = 0.5;
  double _scale = 100;
  bool _png = false;

  ToolContext get t => widget.t;

  static const _ratios = <double>[0, 1, 4 / 3, 3 / 4, 16 / 9, 9 / 16, 4 / 5];
  static const _ratioNames = ['', '1:1', '4:3', '3:4', '16:9', '9:16', '4:5'];

  Rect _cropRect(ui.Image im) {
    final c = centeredCrop(im.width, im.height, _ratio);
    final freeX = im.width - c.w, freeY = im.height - c.h;
    return Rect.fromLTWH(freeX * _px, freeY * _py, c.w.toDouble(), c.h.toDouble());
  }

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    setState(() => _busy = true);
    final im = await decodeUi(b, maxSide: 8192);
    if (!mounted) return;
    setState(() {
      _img = im;
      _busy = false;
    });
  }

  ({int w, int h}) _outSize(ui.Image im) {
    final r = _cropRect(im);
    return (w: math.max<int>(1, (r.width * _scale / 100).round()), h: math.max<int>(1, (r.height * _scale / 100).round()));
  }

  Future<void> _save() async {
    final im = _img;
    if (im == null) return;
    setState(() => _busy = true);
    try {
      final r = _cropRect(im);
      final o = _outSize(im);
      final out = await renderImage(o.w, o.h, (c, s) {
        c.drawImageRect(im, r, Offset.zero & s, Paint()..filterQuality = FilterQuality.high);
      });
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      final bytes = _png ? await pngOfRgba(rgba) : await jpgOf(rgba, quality: 92);
      if (mounted) await saveImage(context, t, bytes, 'kirp_${stamp()}.${_png ? 'png' : 'jpg'}');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final im = _img;
    if (im == null) {
      return ToolList(children: [
        if (_busy) BusyLine(L(t, 'processing')),
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.crop_rounded, onTap: _busy ? null : _pick),
      ]);
    }
    final r = _cropRect(im);
    final o = _outSize(im);
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: AspectRatio(
              aspectRatio: im.width / im.height,
              child: CustomPaint(painter: _CropPainter(im, r)),
            ),
          ),
        ),
      ),
      ChipsRow<int>(
        values: List<int>.generate(_ratios.length, (i) => i),
        label: (i) => i == 0 ? L(t, 'ratio_free') : _ratioNames[i],
        selected: _ratios.indexOf(_ratio),
        onChanged: (i) => setState(() => _ratio = _ratios[i]),
      ),
      if (_ratio > 0) ...[
        SliderRow(label: '↔', value: _px, min: 0, max: 1, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _px = v)),
        SliderRow(label: '↕', value: _py, min: 0, max: 1, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _py = v)),
      ],
      SliderRow(
        label: L(t, 'size'),
        value: _scale,
        min: 5,
        max: 100,
        divisions: 19,
        format: (v) => '${v.round()}%',
        onChanged: (v) => setState(() => _scale = v),
      ),
      AppResult(label: '${L(t, 'width')} × ${L(t, 'height')}', value: '${o.w} × ${o.h} px', lang: t.lang),
      Choice<bool>(values: const [false, true], labels: const ['JPG', 'PNG'], selected: _png, onChanged: (v) => setState(() => _png = v)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect crop;
  _CropPainter(this.image, this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);
    final sx = size.width / image.width, sy = size.height / image.height;
    final r = Rect.fromLTWH(crop.left * sx, crop.top * sy, crop.width * sx, crop.height * sy);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(shade, Paint()..color = Colors.black54);
    canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_CropPainter old) => true;
}

// ================================================================ sıkıştırma

class CompressTool extends StatefulWidget {
  final ToolContext t;
  const CompressTool(this.t, {super.key});

  @override
  State<CompressTool> createState() => _CompressState();
}

class _CompressState extends State<CompressTool> {
  List<Picked> _files = [];
  double _quality = 75;
  int _maxSide = 2048;
  bool _busy = false;
  double _progress = 0;
  int _before = 0, _after = 0;

  ToolContext get t => widget.t;
  static const int _freeLimit = 10;

  String _mb(int b) => '${(b / 1024 / 1024).toStringAsFixed(2)} MB';

  Future<void> _pick() async {
    final ps = await MediaPick.images();
    if (ps.isEmpty) return;
    setState(() {
      _files = ps;
      _before = _after = 0;
    });
  }

  Future<void> _run() async {
    if (_files.isEmpty) return;
    if (_files.length > _freeLimit && !await t.unlockedToday('batch')) {
      if (!await t.unlockForToday('batch')) return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _before = _after = 0;
    });
    var i = 0;
    for (final f in _files) {
      final b = await f.read();
      if (b != null) {
        final im = await decodeUi(b, maxSide: _maxSide);
        final rgba = im == null ? null : await rgbaOf(im);
        if (rgba != null) {
          final jpg = await jpgOf(rgba, quality: _quality.round());
          _before += b.length;
          _after += jpg.length;
          if (!mounted) return;
          await saveImage(context, t, jpg, 'kucuk_${stamp()}_$i.jpg');
        }
      }
      i++;
      if (mounted) setState(() => _progress = i / _files.length);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      if (_files.isEmpty)
        PickPrompt(label: L(t, 'pick_photos'), icon: Icons.compress_rounded, onTap: _pick)
      else
        AppResult(label: L(t, 'count'), value: '${_files.length}', lang: t.lang),
      SliderRow(
          label: L(t, 'quality'),
          value: _quality,
          min: 30,
          max: 95,
          divisions: 13,
          format: (v) => '${v.round()}',
          onChanged: (v) => setState(() => _quality = v)),
      ChipsRow<int>(
        values: const [8192, 4096, 2048, 1600, 1280, 1024],
        label: (v) => v == 8192 ? L(t, 'original') : '$v px',
        selected: _maxSide,
        onChanged: (v) => setState(() => _maxSide = v),
      ),
      AppInfoCard('${L(t, 'max_side')}: ${_maxSide == 8192 ? L(t, 'original') : '$_maxSide px'}', icon: Icons.photo_size_select_large_rounded),
      if (_files.length > _freeLimit) AppInfoCard(t.tx('unlock_ad'), icon: Icons.ondemand_video_rounded),
      if (_busy) BusyLine(L(t, 'processing'), progress: _progress),
      if (_after > 0) ...[
        AppResult(label: L(t, 'original'), value: _mb(_before), lang: t.lang),
        AppResult(label: L(t, 'result'), value: '${_mb(_after)}  (−${(100 - _after * 100 / math.max<int>(1, _before)).round()}%)', lang: t.lang, big: true),
      ],
      ActionRow([
        AppButton(label: L(t, 'pick_photos'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'compress'), icon: Icons.compress_rounded, onPressed: _busy || _files.isEmpty ? null : _run),
      ]),
    ]);
  }
}

// ================================================================ filigran

class WatermarkTool extends StatefulWidget {
  final ToolContext t;
  const WatermarkTool(this.t, {super.key});

  @override
  State<WatermarkTool> createState() => _WatermarkState();
}

/// Görüntünün üstüne metin yazan çizici (filigran ve meme ortak kullanır).
class TextOverlayPainter extends CustomPainter {
  final ui.Image image;
  final List<({String text, Alignment at, double size, Color color, double opacity, bool outline})> items;
  final bool tile;
  final TextDirection dir;
  TextOverlayPainter(this.image, this.items, {this.tile = false, this.dir = TextDirection.ltr});

  TextPainter _tp(String text, double fs, Color color, double opacity, bool stroke, double maxW) {
    final style = TextStyle(
      fontSize: fs,
      fontWeight: FontWeight.w900,
      height: 1.1,
      foreground: stroke
          ? (Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = fs / 7
            ..color = Colors.black.withValues(alpha: opacity))
          : (Paint()..color = color.withValues(alpha: opacity)),
    );
    return TextPainter(text: TextSpan(text: text, style: style), textDirection: dir, textAlign: TextAlign.center)
      ..layout(maxWidth: maxW);
  }

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill, filterQuality: FilterQuality.high);
    for (final it in items) {
      if (it.text.trim().isEmpty) continue;
      final fs = it.size * size.shortestSide;
      final maxW = size.width * 0.92;
      final fill = _tp(it.text, fs, it.color, it.opacity, false, maxW);
      final stroke = it.outline ? _tp(it.text, fs, it.color, it.opacity, true, maxW) : null;
      void draw(Offset o) {
        stroke?.paint(canvas, o);
        fill.paint(canvas, o);
      }

      if (tile) {
        canvas.save();
        canvas.translate(size.width / 2, size.height / 2);
        canvas.rotate(-math.pi / 8);
        final stepX = fill.width + fs * 2, stepY = fill.height + fs * 2;
        final span = size.longestSide;
        for (var y = -span; y < span; y += stepY) {
          for (var x = -span; x < span; x += stepX) {
            draw(Offset(x, y));
          }
        }
        canvas.restore();
      } else {
        final pad = size.shortestSide * 0.03;
        final ax = (it.at.x + 1) / 2, ay = (it.at.y + 1) / 2;
        final x = pad + (size.width - 2 * pad - fill.width) * ax;
        final y = pad + (size.height - 2 * pad - fill.height) * ay;
        draw(Offset(x, y));
      }
    }
  }

  @override
  bool shouldRepaint(TextOverlayPainter old) => true;
}

class _WatermarkState extends State<WatermarkTool> {
  ui.Image? _img;
  final _text = TextEditingController(text: '© ');
  double _size = 0.05, _opacity = 0.6;
  int _color = 0;
  Alignment _at = Alignment.bottomRight;
  bool _tile = false, _busy = false;

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    setState(() => _busy = true);
    final im = await decodeUi(b);
    if (!mounted) return;
    setState(() {
      _img = im;
      _busy = false;
    });
  }

  TextOverlayPainter _painter(ui.Image im) => TextOverlayPainter(
        im,
        [(text: _text.text, at: _at, size: _size, color: Color(kSwatches[_color]), opacity: _opacity, outline: false)],
        tile: _tile,
        dir: t.rtl ? TextDirection.rtl : TextDirection.ltr,
      );

  Future<void> _save() async {
    final im = _img;
    if (im == null) return;
    setState(() => _busy = true);
    try {
      final out = await renderImage(im.width, im.height, (c, s) => _painter(im).paint(c, s));
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      final jpg = await jpgOf(rgba, quality: 92);
      if (mounted) await saveImage(context, t, jpg, 'filigran_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final im = _img;
    if (im == null) {
      return ToolList(children: [
        if (_busy) BusyLine(L(t, 'processing')),
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.branding_watermark_rounded, onTap: _busy ? null : _pick),
      ]);
    }
    const spots = [
      Alignment.topLeft, Alignment.topCenter, Alignment.topRight, //
      Alignment.centerLeft, Alignment.center, Alignment.centerRight,
      Alignment.bottomLeft, Alignment.bottomCenter, Alignment.bottomRight,
    ];
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: AspectRatio(aspectRatio: im.width / im.height, child: CustomPaint(painter: _painter(im))),
          ),
        ),
      ),
      AppTextField(controller: _text, label: L(t, 'text'), onChanged: (_) => setState(() {})),
      SliderRow(label: L(t, 'font_size'), value: _size, min: 0.02, max: 0.15, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _size = v)),
      SliderRow(label: L(t, 'opacity'), value: _opacity, min: 0.1, max: 1, format: (v) => '${(v * 100).round()}%', onChanged: (v) => setState(() => _opacity = v)),
      swatchRow(_color, (i) => setState(() => _color = i)),
      SwitchListTile(title: Text(L(t, 'tile')), value: _tile, onChanged: (v) => setState(() => _tile = v)),
      if (!_tile)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
            for (final a in spots)
              IconButton.filledTonal(
                isSelected: a == _at,
                onPressed: () => setState(() => _at = a),
                icon: Transform.rotate(
                  angle: math.atan2(a.y, a.x == 0 && a.y == 0 ? 1 : a.x),
                  child: Icon(a == Alignment.center ? Icons.adjust_rounded : Icons.arrow_forward_rounded),
                ),
              ),
          ]),
        ),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ görselden PDF

class PdfTool extends StatefulWidget {
  final ToolContext t;
  const PdfTool(this.t, {super.key});

  @override
  State<PdfTool> createState() => _PdfState();
}

class _PdfState extends State<PdfTool> {
  final List<({String name, Uint8List bytes, ui.Image thumb})> _pages = [];
  String _size = 'a4';
  double _margin = 18;
  bool _busy = false;

  ToolContext get t => widget.t;
  static const int _freeLimit = 20;

  Future<void> _add() async {
    final ps = await MediaPick.images();
    if (ps.isEmpty) return;
    setState(() => _busy = true);
    for (final p in ps) {
      final b = await p.read();
      if (b == null) continue;
      final full = await decodeUi(b, maxSide: 2480);
      final thumb = await decodeUi(b, maxSide: 200);
      if (full == null || thumb == null) continue;
      final rgba = await rgbaOf(full);
      if (rgba == null) continue;
      final jpg = await jpgOf(rgba, quality: 88);
      _pages.add((name: p.name, bytes: jpg, thumb: thumb));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    if (_pages.isEmpty) return;
    if (_pages.length > _freeLimit && !await t.unlockedToday('pdf')) {
      if (!await t.unlockForToday('pdf')) return;
    }
    setState(() => _busy = true);
    try {
      final doc = pw.Document();
      for (final p in _pages) {
        final image = pw.MemoryImage(p.bytes);
        PdfPageFormat fmt;
        if (_size == 'fit') {
          final w = p.thumb.width.toDouble(), h = p.thumb.height.toDouble();
          const base = 595.0;
          fmt = w >= h ? PdfPageFormat(base * w / h, base) : PdfPageFormat(base, base * h / w);
        } else {
          fmt = _size == 'letter' ? PdfPageFormat.letter : PdfPageFormat.a4;
        }
        doc.addPage(pw.Page(
          pageFormat: fmt,
          margin: pw.EdgeInsets.all(_size == 'fit' ? 0 : _margin),
          build: (c) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ));
      }
      final bytes = await doc.save();
      if (mounted) await saveFile(context, t, bytes, 'belge_${stamp()}.pdf', 'application/pdf');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      if (_pages.isEmpty)
        PickPrompt(label: L(t, 'pick_photos'), icon: Icons.picture_as_pdf_rounded, onTap: _busy ? null : _add)
      else
        SizedBox(
          height: 150,
          child: ReorderableListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onReorder: (a, b) => setState(() {
              if (b > a) b--;
              final x = _pages.removeAt(a);
              _pages.insert(b, x);
            }),
            children: [
              for (var i = 0; i < _pages.length; i++)
                Padding(
                  key: ValueKey('${_pages[i].name}_${identityHashCode(_pages[i].bytes)}'),
                  padding: const EdgeInsets.all(4),
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(width: 100, height: 140, child: RawImage(image: _pages[i].thumb, fit: BoxFit.cover)),
                    ),
                    Positioned(
                      left: 4,
                      top: 4,
                      child: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                        onPressed: () => setState(() => _pages.removeAt(i)),
                      ),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      Choice<String>(
        values: const ['a4', 'letter', 'fit'],
        labels: ['A4', 'Letter', L(t, 'fit_page')],
        selected: _size,
        onChanged: (v) => setState(() => _size = v),
      ),
      if (_size != 'fit')
        SliderRow(label: L(t, 'margin'), value: _margin, min: 0, max: 60, format: (v) => '${v.round()}', onChanged: (v) => setState(() => _margin = v)),
      if (_pages.length > _freeLimit) AppInfoCard(t.tx('unlock_ad'), icon: Icons.ondemand_video_rounded),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photos'), icon: Icons.add_photo_alternate_rounded, onPressed: _busy ? null : _add),
        AppButton(label: L(t, 'save'), icon: Icons.picture_as_pdf_rounded, onPressed: _busy || _pages.isEmpty ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ bilgi silici

class ExifTool extends StatefulWidget {
  final ToolContext t;
  const ExifTool(this.t, {super.key});

  @override
  State<ExifTool> createState() => _ExifState();
}

/// JPEG içindeki konum, cihaz ve tarih bilgisini okur.
({bool gps, String device, String date})? readPhotoMeta(Uint8List bytes) {
  try {
    final exif = img.decodeJpgExif(bytes);
    if (exif == null) return null;
    String v(img.IfdDirectory d, int tag) => d.data[tag]?.toString().replaceAll('\u0000', '').trim() ?? '';
    final device = '${v(exif.imageIfd, 0x010F)} ${v(exif.imageIfd, 0x0110)}'.trim();
    var date = v(exif.exifIfd, 0x9003);
    if (date.isEmpty) date = v(exif.imageIfd, 0x0132);
    final gps = exif.gpsIfd.data.isNotEmpty;
    if (!gps && device.isEmpty && date.isEmpty) return null;
    return (gps: gps, device: device, date: date);
  } catch (_) {
    return null;
  }
}

class _ExifState extends State<ExifTool> {
  Uint8List? _bytes;
  ui.Image? _thumb;
  ({bool gps, String device, String date})? _meta;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    final th = await decodeUi(b, maxSide: 600);
    if (!mounted) return;
    setState(() {
      _bytes = b;
      _thumb = th;
      _meta = readPhotoMeta(b);
    });
  }

  Future<void> _clean() async {
    final b = _bytes;
    if (b == null) return;
    setState(() => _busy = true);
    try {
      final im = await decodeUi(b, maxSide: 12000);
      final rgba = im == null ? null : await rgbaOf(im);
      if (rgba == null) throw StateError('rgba');
      final jpg = await jpgOf(rgba, quality: 95);
      if (mounted) await saveImage(context, t, jpg, 'temiz_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final th = _thumb;
    final m = _meta;
    return ToolList(children: [
      if (th == null)
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.location_off_rounded, onTap: _pick)
      else ...[
        ImagePreview(th, maxHeight: 240),
        AppHeading(L(t, 'exif_list'), icon: Icons.info_outline_rounded),
        if (m == null)
          AppInfoCard(L(t, 'no_metadata'), icon: Icons.verified_user_rounded)
        else ...[
          AppResult(label: L(t, 'location'), value: m.gps ? '✓' : '—', lang: t.lang, big: m.gps),
          AppResult(label: L(t, 'device'), value: m.device.isEmpty ? '—' : m.device, lang: t.lang),
          AppResult(label: L(t, 'date'), value: m.date.isEmpty ? '—' : m.date, lang: t.lang),
        ],
      ],
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'clean_save'), icon: Icons.cleaning_services_rounded, onPressed: _busy || _bytes == null ? null : _clean),
      ]),
    ]);
  }
}

// ================================================================ kopya bulucu

class DuplicateTool extends StatefulWidget {
  final ToolContext t;
  const DuplicateTool(this.t, {super.key});

  @override
  State<DuplicateTool> createState() => _DuplicateState();
}

class _DuplicateState extends State<DuplicateTool> {
  final List<({String name, ui.Image thumb, Uint8List hash})> _items = [];
  List<List<int>>? _groups;
  double _threshold = 6;
  bool _busy = false;
  double _progress = 0;

  ToolContext get t => widget.t;
  static const int _freeLimit = 200;

  Future<void> _pick() async {
    final ps = await MediaPick.images();
    if (ps.isEmpty) return;
    if (ps.length > _freeLimit && !await t.unlockedToday('dupes')) {
      if (!await t.unlockForToday('dupes')) return;
    }
    setState(() {
      _busy = true;
      _items.clear();
      _groups = null;
      _progress = 0;
    });
    var i = 0;
    for (final p in ps) {
      final b = await p.read();
      if (b != null) {
        final th = await decodeUi(b, maxSide: 160);
        final rgba = th == null ? null : await rgbaOf(th);
        if (th != null && rgba != null) _items.add((name: p.name, thumb: th, hash: dHash(rgba)));
      }
      i++;
      if (mounted) setState(() => _progress = i / ps.length);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _scan();
    });
  }

  void _scan() => _groups = groupSimilar([for (final x in _items) x.hash], _threshold.round());

  @override
  Widget build(BuildContext context) {
    final g = _groups;
    return ToolList(children: [
      if (_items.isEmpty && !_busy) PickPrompt(label: L(t, 'pick_photos'), icon: Icons.filter_none_rounded, onTap: _pick),
      if (_busy) BusyLine(L(t, 'processing'), progress: _progress),
      SliderRow(
        label: L(t, 'threshold'),
        value: _threshold,
        min: 0,
        max: 16,
        divisions: 16,
        format: (v) => '${v.round()}',
        onChanged: (v) => setState(() {
          _threshold = v;
          if (_items.isNotEmpty) _scan();
        }),
      ),
      if (g != null && g.isEmpty) AppInfoCard(L(t, 'no_duplicates'), icon: Icons.check_circle_rounded),
      if (g != null && g.isNotEmpty) AppHeading('${L(t, 'similar_groups')}: ${g.length}', icon: Icons.filter_none_rounded),
      if (g != null)
        for (final grp in g)
          AppPanel(
            child: SizedBox(
              height: 110,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final i in grp)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(width: 80, height: 80, child: RawImage(image: _items[i].thumb, fit: BoxFit.cover)),
                      ),
                      SizedBox(
                        width: 80,
                        child: Text(_items[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
      ActionRow([
        AppButton(label: L(t, 'scan'), icon: Icons.search_rounded, onPressed: _busy ? null : _pick),
      ]),
    ]);
  }
}

// ================================================================ ekran görüntüsü düzenleyici

class ScreenshotTool extends StatefulWidget {
  final ToolContext t;
  const ScreenshotTool(this.t, {super.key});

  @override
  State<ScreenshotTool> createState() => _ScreenshotState();
}

class _Mark {
  final String kind; // arrow, box, hide, text
  Offset a;
  Offset b;
  final String text;
  final Color color;
  _Mark(this.kind, this.a, this.b, {this.text = '', this.color = const Color(0xFFFF3D00)});
}

class _MarkPainter extends CustomPainter {
  final ui.Image image;
  final List<_Mark> marks;
  final Rect? crop;
  final bool hideAsBlocks;
  _MarkPainter(this.image, this.marks, this.crop, {this.hideAsBlocks = true});

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);
    final sx = size.width / image.width;
    for (final m in marks) {
      final a = m.a * sx, b = m.b * sx;
      final stroke = Paint()
        ..color = m.color
        ..strokeWidth = math.max(2.0, 6 * sx * (image.width / 1080))
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      switch (m.kind) {
        case 'box':
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromPoints(a, b), Radius.circular(6 * sx)), stroke);
          break;
        case 'hide':
          if (hideAsBlocks) canvas.drawRect(Rect.fromPoints(a, b), Paint()..color = Colors.black.withValues(alpha: 0.75));
          break;
        case 'text':
          final tp = TextPainter(
            text: TextSpan(
              text: m.text,
              style: TextStyle(color: m.color, fontSize: 48 * sx * (image.width / 1080), fontWeight: FontWeight.w800),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: size.width);
          tp.paint(canvas, a);
          break;
        default:
          canvas.drawLine(a, b, stroke);
          final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
          final head = stroke.strokeWidth * 4;
          final p = Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(b.dx - head * math.cos(ang - 0.5), b.dy - head * math.sin(ang - 0.5))
            ..moveTo(b.dx, b.dy)
            ..lineTo(b.dx - head * math.cos(ang + 0.5), b.dy - head * math.sin(ang + 0.5));
          canvas.drawPath(p, stroke);
      }
    }
    final c = crop;
    if (c != null) {
      final r = Rect.fromLTRB(c.left * sx, c.top * sx, c.right * sx, c.bottom * sx);
      canvas.drawPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(Offset.zero & size)
            ..addRect(r),
          Paint()..color = Colors.black54);
      canvas.drawRect(
          r,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => true;
}

class _ScreenshotState extends State<ScreenshotTool> {
  ui.Image? _img;
  final List<_Mark> _marks = [];
  Rect? _crop;
  String _mode = 'arrow';
  int _color = 9;
  bool _busy = false;
  _Mark? _live;
  Offset? _cropStart;
  final _text = TextEditingController();

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    final im = await decodeUi(b);
    if (!mounted) return;
    setState(() {
      _img = im;
      _marks.clear();
      _crop = null;
    });
  }

  Offset _toImage(Offset local, Size box, ui.Image im) {
    final s = im.width / box.width;
    return Offset((local.dx * s).clamp(0.0, im.width.toDouble()), (local.dy * s).clamp(0.0, im.height.toDouble()));
  }

  void _start(Offset p) {
    if (_mode == 'crop') {
      _cropStart = p;
      setState(() => _crop = Rect.fromPoints(p, p));
      return;
    }
    if (_mode == 'text') {
      if (_text.text.trim().isEmpty) return;
      setState(() => _marks.add(_Mark('text', p, p, text: _text.text.trim(), color: Color(kSwatches[_color]))));
      return;
    }
    _live = _Mark(_mode, p, p, color: Color(kSwatches[_color]));
    setState(() => _marks.add(_live!));
  }

  void _move(Offset p) {
    final s = _cropStart;
    if (_mode == 'crop' && s != null) {
      setState(() => _crop = Rect.fromPoints(s, p));
      return;
    }
    final l = _live;
    if (l != null) setState(() => l.b = p);
  }

  Future<void> _save() async {
    final im = _img;
    if (im == null) return;
    setState(() => _busy = true);
    try {
      // 1) Gizlenecek alanlar pikselleştirilir, 2) işaretler çizilir, 3) kırpılır.
      var rgba = await rgbaOf(im);
      if (rgba == null) throw StateError('rgba');
      for (final m in _marks.where((m) => m.kind == 'hide')) {
        final r = Rect.fromPoints(m.a, m.b);
        pixelate(rgba, r.left.round(), r.top.round(), r.width.round(), r.height.round(), math.max<int>(8, im.width ~/ 60));
      }
      final base = await uiOf(rgba);
      final painted = await renderImage(im.width, im.height, (c, s) => _MarkPainter(base, _marks, null, hideAsBlocks: false).paint(c, s));
      rgba = await rgbaOf(painted);
      if (rgba == null) throw StateError('rgba');
      final c = _crop;
      if (c != null && c.width > 8 && c.height > 8) {
        rgba = cropRgba(rgba, c.left.round(), c.top.round(), c.width.round(), c.height.round());
      }
      final png = await pngOfRgba(rgba);
      if (mounted) await saveImage(context, t, png, 'ekran_${stamp()}.png');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final im = _img;
    if (im == null) {
      return ToolList(children: [PickPrompt(label: L(t, 'pick_photo'), icon: Icons.screenshot_rounded, onTap: _pick)]);
    }
    return ToolList(children: [
      ChipsRow<String>(
        values: const ['arrow', 'box', 'hide', 'text', 'crop'],
        label: (k) => L(t, k),
        selected: _mode,
        onChanged: (v) => setState(() => _mode = v),
      ),
      if (_mode == 'text') AppTextField(controller: _text, label: L(t, 'text')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: AspectRatio(
              aspectRatio: im.width / im.height,
              child: LayoutBuilder(builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                return GestureDetector(
                  onPanStart: (d) => _start(_toImage(d.localPosition, size, im)),
                  onPanUpdate: (d) => _move(_toImage(d.localPosition, size, im)),
                  onPanEnd: (_) {
                    _live = null;
                    _cropStart = null;
                  },
                  onTapUp: (d) {
                    if (_mode == 'text') _start(_toImage(d.localPosition, size, im));
                  },
                  child: CustomPaint(size: size, painter: _MarkPainter(im, _marks, _crop)),
                );
              }),
            ),
          ),
        ),
      ),
      swatchRow(_color, (i) => setState(() => _color = i)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(
          label: t.core('undo'),
          icon: Icons.undo_rounded,
          onPressed: _marks.isEmpty && _crop == null
              ? null
              : () => setState(() {
                    if (_mode == 'crop' && _crop != null) {
                      _crop = null;
                    } else if (_marks.isNotEmpty) {
                      _marks.removeLast();
                    }
                  }),
        ),
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ filtreli kamera

class FilterCameraTool extends StatefulWidget {
  final ToolContext t;
  const FilterCameraTool(this.t, {super.key});

  @override
  State<FilterCameraTool> createState() => _FilterCameraState();
}

class _FilterCameraState extends State<FilterCameraTool> {
  String _filter = 'vivid';
  CameraLensDirection _lens = CameraLensDirection.back;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _shoot(CameraController c) async {
    if (_busy || c.value.isTakingPicture) return;
    setState(() => _busy = true);
    try {
      final x = await c.takePicture();
      final b = await x.readAsBytes();
      final im = await decodeUi(b);
      if (im == null) throw StateError('decode');
      final out = await transformImage(im, flip: _lens == CameraLensDirection.front, matrix: filterMatrix(_filter));
      final rgba = await rgbaOf(out);
      if (rgba == null) throw StateError('rgba');
      final jpg = await jpgOf(rgba, quality: 92);
      if (mounted) await saveImage(context, t, jpg, 'kamera_${stamp()}.jpg');
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      CameraBox(
        tool: t,
        lens: _lens,
        builder: (context, c) => Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Transform.flip(
              flipX: _lens == CameraLensDirection.front,
              child: cameraPreview(c, height: 420, matrix: filterMatrix(_filter)),
            ),
          ),
          ActionRow([
            AppButton(
              label: L(t, 'flip_camera'),
              icon: Icons.cameraswitch_rounded,
              onPressed: () => setState(() => _lens =
                  _lens == CameraLensDirection.back ? CameraLensDirection.front : CameraLensDirection.back),
            ),
            AppButton(label: L(t, 'take_photo'), icon: Icons.camera_rounded, onPressed: _busy ? null : () => _shoot(c)),
          ]),
        ]),
      ),
      ChipsRow<String>(
        values: kFilterIds,
        label: (id) => _filterLabel(t, id),
        selected: _filter,
        onChanged: (v) => setState(() => _filter = v),
      ),
      if (_busy) BusyLine(L(t, 'processing')),
    ]);
  }
}
