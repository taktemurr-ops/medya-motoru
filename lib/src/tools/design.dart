/// Tasarım ve çizim araçları: meme yapıcı (kendi fotoğrafınla), duvar kâğıdı
/// üretici, piksel sanatı, dijital resim ve tek bir tasarım tuvali üzerinden
/// logo, davetiye/kart ve afiş/sosyal medya tasarımı. Hazır telifli şablon
/// ya da marka benzeri öğe yoktur; desenler ve süslemeler kodla çizilir.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/imaging.dart';
import 'photo.dart' show TextOverlayPainter, kSwatches, swatchRow;

Future<void> _exportImage(BuildContext context, ToolContext t, ui.Image im, String base, {bool png = false}) async {
  final rgba = await rgbaOf(im);
  if (rgba == null) {
    if (context.mounted) snack(context, L(t, 'failed'));
    return;
  }
  final bytes = png ? await pngOfRgba(rgba) : await jpgOf(rgba, quality: 94);
  if (context.mounted) await saveImage(context, t, bytes, '${base}_${stamp()}.${png ? 'png' : 'jpg'}');
}

// ================================================================ meme

class MemeTool extends StatefulWidget {
  final ToolContext t;
  const MemeTool(this.t, {super.key});

  @override
  State<MemeTool> createState() => _MemeState();
}

class _MemeState extends State<MemeTool> {
  ui.Image? _img;
  final _top = TextEditingController();
  final _bottom = TextEditingController();
  double _size = 0.09;
  bool _busy = false;

  ToolContext get t => widget.t;

  @override
  void dispose() {
    _top.dispose();
    _bottom.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    final im = await decodeUi(b, maxSide: 2048);
    if (mounted) setState(() => _img = im);
  }

  TextOverlayPainter _painter(ui.Image im) => TextOverlayPainter(
        im,
        [
          (text: _top.text.toUpperCase(), at: Alignment.topCenter, size: _size, color: Colors.white, opacity: 1.0, outline: true),
          (text: _bottom.text.toUpperCase(), at: Alignment.bottomCenter, size: _size, color: Colors.white, opacity: 1.0, outline: true),
        ],
        dir: t.rtl ? TextDirection.rtl : TextDirection.ltr,
      );

  Future<void> _save() async {
    final im = _img;
    if (im == null) return;
    setState(() => _busy = true);
    final out = await renderImage(im.width, im.height, (c, s) => _painter(im).paint(c, s));
    if (mounted) await _exportImage(context, t, out, 'meme');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final im = _img;
    return ToolList(children: [
      if (im == null)
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.sentiment_very_satisfied_rounded, onTap: _pick)
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: AspectRatio(aspectRatio: im.width / im.height, child: CustomPaint(painter: _painter(im))),
            ),
          ),
        ),
      AppTextField(controller: _top, label: L(t, 'top_text'), onChanged: (_) => setState(() {})),
      AppTextField(controller: _bottom, label: L(t, 'bottom_text'), onChanged: (_) => setState(() {})),
      SliderRow(label: L(t, 'font_size'), value: _size, min: 0.04, max: 0.16, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _size = v)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy || im == null ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ duvar kâğıdı

const List<String> kPatternIds = ['gradient', 'waves', 'dots', 'stripes', 'blobs', 'triangles'];

class WallpaperPainter extends CustomPainter {
  final String pattern;
  final int seed;
  WallpaperPainter(this.pattern, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final pal = paletteFromSeed(seed).map((c) => Color(c)).toList();
    final rnd = math.Random(seed);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(rnd.nextDouble() * 2 - 1, -1),
          end: Alignment(rnd.nextDouble() * 2 - 1, 1),
          colors: [pal[0], pal[1]],
        ).createShader(rect),
    );
    final u = size.shortestSide;
    switch (pattern) {
      case 'waves':
        for (var i = 0; i < 7; i++) {
          final y0 = size.height * (0.25 + i * 0.11);
          final amp = u * (0.03 + rnd.nextDouble() * 0.05);
          final len = size.width / (1 + rnd.nextInt(3));
          final path = Path()..moveTo(0, size.height);
          for (var x = 0.0; x <= size.width; x += size.width / 60) {
            path.lineTo(x, y0 + math.sin(x / len * 2 * math.pi + i) * amp);
          }
          path
            ..lineTo(size.width, size.height)
            ..close();
          canvas.drawPath(path, Paint()..color = (i.isEven ? pal[2] : pal[1]).withValues(alpha: 0.18 + i * 0.05));
        }
        break;
      case 'dots':
        final step = u / 12;
        for (var y = step / 2; y < size.height; y += step) {
          for (var x = step / 2; x < size.width; x += step) {
            final r = step * (0.12 + 0.25 * (0.5 + 0.5 * math.sin(x / u * 6 + y / u * 4 + seed)));
            canvas.drawCircle(Offset(x, y), r, Paint()..color = pal[2].withValues(alpha: 0.55));
          }
        }
        break;
      case 'stripes':
        canvas.save();
        canvas.translate(size.width / 2, size.height / 2);
        canvas.rotate(rnd.nextDouble() * math.pi);
        final span = size.longestSide;
        final w = u / (8 + rnd.nextInt(10));
        var k = 0;
        for (var x = -span; x < span; x += w) {
          canvas.drawRect(Rect.fromLTWH(x, -span, w / 2, span * 2), Paint()..color = pal[k++ % 2 == 0 ? 2 : 1].withValues(alpha: 0.35));
        }
        canvas.restore();
        break;
      case 'blobs':
        for (var i = 0; i < 9; i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          final r = u * (0.15 + rnd.nextDouble() * 0.35);
          canvas.drawCircle(
            c,
            r,
            Paint()
              ..color = pal[i % 3].withValues(alpha: 0.45)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35),
          );
        }
        break;
      case 'triangles':
        final cols = 8, rows = (cols * size.height / size.width).ceil() + 1;
        final cw = size.width / cols, ch = size.height / rows;
        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < cols; c++) {
            final x = c * cw, y = r * ch;
            for (var k = 0; k < 2; k++) {
              final p = Path();
              if (k == 0) {
                p
                  ..moveTo(x, y)
                  ..lineTo(x + cw, y)
                  ..lineTo(x, y + ch);
              } else {
                p
                  ..moveTo(x + cw, y)
                  ..lineTo(x + cw, y + ch)
                  ..lineTo(x, y + ch);
              }
              final mixT = rnd.nextDouble();
              canvas.drawPath(p..close(), Paint()..color = Color.lerp(pal[1], pal[2], mixT)!.withValues(alpha: 0.35 + 0.4 * mixT));
            }
          }
        }
        break;
      default: // gradient: üçüncü renkle yumuşak ışık
        canvas.drawCircle(
          Offset(size.width * rnd.nextDouble(), size.height * rnd.nextDouble()),
          u * 0.8,
          Paint()
            ..color = pal[2].withValues(alpha: 0.5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.3),
        );
    }
  }

  @override
  bool shouldRepaint(WallpaperPainter old) => old.pattern != pattern || old.seed != seed;
}

class WallpaperTool extends StatefulWidget {
  final ToolContext t;
  const WallpaperTool(this.t, {super.key});

  @override
  State<WallpaperTool> createState() => _WallpaperState();
}

class _WallpaperState extends State<WallpaperTool> {
  String _pattern = 'blobs';
  int _seed = DateTime.now().millisecondsSinceEpoch & 0xffff;
  String _size = 'screen';
  bool _busy = false;

  ToolContext get t => widget.t;

  ({int w, int h}) _dims(BuildContext context) {
    switch (_size) {
      case 'square':
        return (w: 2048, h: 2048);
      case 'landscape':
        return (w: 2560, h: 1440);
      default:
        final mq = MediaQuery.of(context);
        final w = (mq.size.width * mq.devicePixelRatio).round();
        final h = (mq.size.height * mq.devicePixelRatio).round();
        final s = fitWithin(math.max<int>(w, 720), math.max<int>(h, 1280), 3200);
        return (w: s.w, h: s.h);
    }
  }

  Future<void> _save() async {
    final d = _dims(context);
    setState(() => _busy = true);
    final im = await renderImage(d.w, d.h, (c, s) => WallpaperPainter(_pattern, _seed).paint(c, s));
    if (mounted) await _exportImage(context, t, im, 'duvar');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = _dims(context);
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: AspectRatio(
              aspectRatio: d.w / d.h,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CustomPaint(painter: WallpaperPainter(_pattern, _seed)),
              ),
            ),
          ),
        ),
      ),
      ChipsRow<String>(values: kPatternIds, label: (p) => L(t, 'p_$p'), selected: _pattern, onChanged: (v) => setState(() => _pattern = v)),
      Choice<String>(
        values: const ['screen', 'square', 'landscape'],
        labels: [L(t, 'sz_screen'), L(t, 'sz_square'), L(t, 'sz_landscape')],
        selected: _size,
        onChanged: (v) => setState(() => _size = v),
      ),
      AppResult(label: L(t, 'resolution'), value: '${d.w} × ${d.h}', lang: t.lang),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(label: L(t, 'randomize'), icon: Icons.casino_rounded, onPressed: () => setState(() => _seed = math.Random().nextInt(1 << 30))),
        AppButton(label: L(t, 'save'), icon: Icons.wallpaper_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ piksel sanatı

const List<int> kPixelPalette = [
  0xFF000000, 0xFFFFFFFF, 0xFF9E9E9E, 0xFF5D4037, 0xFFE53935, 0xFFFF7043, 0xFFFFB300, 0xFFFFEB3B, //
  0xFF7CB342, 0xFF2E7D32, 0xFF26C6DA, 0xFF1E88E5, 0xFF3949AB, 0xFF8E24AA, 0xFFEC407A, 0xFFFFCCBC,
];

/// Yakın komşu büyütme (piksel sanatı için keskin kenarlar).
Rgba upscaleNearest(Rgba src, int factor) {
  final w = src.width * factor, h = src.height * factor;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final sy = y ~/ factor;
    for (var x = 0; x < w; x++) {
      final s = (sy * src.width + x ~/ factor) * 4;
      final o = (y * w + x) * 4;
      out[o] = src.data[s];
      out[o + 1] = src.data[s + 1];
      out[o + 2] = src.data[s + 2];
      out[o + 3] = src.data[s + 3];
    }
  }
  return Rgba(w, h, out);
}

/// Dört yönlü taşma dolgusu.
void floodFill(List<int> px, int n, int x, int y, int color) {
  final target = px[y * n + x];
  if (target == color) return;
  final stack = <int>[y * n + x];
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    if (px[i] != target) continue;
    px[i] = color;
    final cx = i % n, cy = i ~/ n;
    if (cx > 0) stack.add(i - 1);
    if (cx < n - 1) stack.add(i + 1);
    if (cy > 0) stack.add(i - n);
    if (cy < n - 1) stack.add(i + n);
  }
}

class PixelArtTool extends StatefulWidget {
  final ToolContext t;
  const PixelArtTool(this.t, {super.key});

  @override
  State<PixelArtTool> createState() => _PixelArtState();
}

class _PixelArtState extends State<PixelArtTool> {
  int _n = 16;
  List<int> _px = List<int>.filled(16 * 16, 0);
  final List<List<int>> _undo = [];
  int _color = 0;
  String _tool = 'pen';
  bool _grid = true;

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final s = await t.store.read('px');
    if (s == null || !mounted) return;
    final parts = s.split(',');
    final n = math.sqrt(parts.length).round();
    if (n * n != parts.length || ![16, 32, 64].contains(n)) return;
    setState(() {
      _n = n;
      _px = [for (final p in parts) int.tryParse(p, radix: 16) ?? 0];
    });
  }

  void _persist() => unawaited(t.store.write('px', _px.map((c) => c.toRadixString(16)).join(',')));

  void _snapshot() {
    _undo.add(List<int>.of(_px));
    if (_undo.length > 30) _undo.removeAt(0);
  }

  void _paintAt(Offset local, double side, {bool first = false}) {
    final cell = side / _n;
    final x = (local.dx / cell).floor(), y = (local.dy / cell).floor();
    if (x < 0 || y < 0 || x >= _n || y >= _n) return;
    if (first) _snapshot();
    setState(() {
      if (_tool == 'fill') {
        if (first) floodFill(_px, _n, x, y, kPixelPalette[_color]);
      } else {
        _px[y * _n + x] = _tool == 'eraser' ? 0 : kPixelPalette[_color];
      }
    });
  }

  Future<void> _resize(int n) async {
    if (n == 64 && !await t.unlockedToday('pixel64')) {
      if (!await t.unlockForToday('pixel64')) return;
    }
    setState(() {
      _snapshot();
      _n = n;
      _px = List<int>.filled(n * n, 0);
    });
    _persist();
  }

  Future<void> _save() async {
    final r = Rgba(_n, _n, Uint8List(_n * _n * 4));
    for (var i = 0; i < _px.length; i++) {
      final c = _px[i];
      r.data[i * 4] = (c >> 16) & 0xff;
      r.data[i * 4 + 1] = (c >> 8) & 0xff;
      r.data[i * 4 + 2] = c & 0xff;
      r.data[i * 4 + 3] = (c >> 24) & 0xff;
    }
    final big = upscaleNearest(r, 1024 ~/ _n);
    final png = await pngOfRgba(big);
    if (mounted) await saveImage(context, t, png, 'piksel_${stamp()}.png');
  }

  @override
  Widget build(BuildContext context) {
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(builder: (context, box) {
            final side = box.maxWidth;
            return GestureDetector(
              onPanStart: (d) => _paintAt(d.localPosition, side, first: true),
              onPanUpdate: (d) => _paintAt(d.localPosition, side),
              onPanEnd: (_) => _persist(),
              onTapDown: (d) => _paintAt(d.localPosition, side, first: true),
              onTapUp: (_) => _persist(),
              child: CustomPaint(size: Size(side, side), painter: _PixelPainter(_px, _n, _grid)),
            );
          }),
        ),
      ),
      ChipsRow<String>(values: const ['pen', 'eraser', 'fill'], label: (k) => L(t, k), selected: _tool, onChanged: (v) => setState(() => _tool = v)),
      swatchRow(_color, (i) => setState(() => _color = i), colors: kPixelPalette),
      Choice<int>(values: const [16, 32, 64], labels: const ['16', '32', '64'], selected: _n, onChanged: (v) => unawaited(_resize(v))),
      SwitchListTile(title: Text(L(t, 'grid')), value: _grid, onChanged: (v) => setState(() => _grid = v)),
      ActionRow([
        AppButton(
          label: t.core('undo'),
          icon: Icons.undo_rounded,
          onPressed: _undo.isEmpty
              ? null
              : () {
                  setState(() {
                    _px = _undo.removeLast();
                    _n = math.sqrt(_px.length).round();
                  });
                  _persist();
                },
        ),
        AppButton(
          label: L(t, 'clear'),
          icon: Icons.delete_sweep_rounded,
          onPressed: () {
            _snapshot();
            setState(() => _px = List<int>.filled(_n * _n, 0));
            _persist();
          },
        ),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _save),
      ]),
    ]);
  }
}

class _PixelPainter extends CustomPainter {
  final List<int> px;
  final int n;
  final bool grid;
  _PixelPainter(this.px, this.n, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / n;
    CheckerPainter().paint(canvas, size);
    final p = Paint();
    for (var i = 0; i < px.length; i++) {
      if (px[i] == 0) continue;
      p.color = Color(px[i]);
      canvas.drawRect(Rect.fromLTWH((i % n) * cell, (i ~/ n) * cell, cell + 0.5, cell + 0.5), p);
    }
    if (grid) {
      final g = Paint()
        ..color = Colors.white24
        ..strokeWidth = 0.5;
      for (var i = 0; i <= n; i++) {
        canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, size.height), g);
        canvas.drawLine(Offset(0, i * cell), Offset(size.width, i * cell), g);
      }
    }
  }

  @override
  bool shouldRepaint(_PixelPainter old) => true;
}

// ================================================================ dijital resim

class _Stroke {
  final String kind; // pen, marker, spray, eraser
  final Color color;
  final double width; // kısa kenara oranla
  final List<Offset> pts = []; // 0..1
  _Stroke(this.kind, this.color, this.width);
}

class _PaintingPainter extends CustomPainter {
  final ui.Image? background;
  final List<_Stroke> strokes;
  _PaintingPainter(this.background, this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = background;
    if (bg != null) {
      paintImage(canvas: canvas, rect: rect, image: bg, fit: BoxFit.cover, filterQuality: FilterQuality.high);
    } else {
      canvas.drawRect(rect, Paint()..color = Colors.white);
    }
    canvas.saveLayer(rect, Paint());
    final u = size.shortestSide;
    for (var si = 0; si < strokes.length; si++) {
      final s = strokes[si];
      if (s.pts.isEmpty) continue;
      final w = math.max(1.0, s.width * u);
      final pts = [for (final p in s.pts) Offset(p.dx * size.width, p.dy * size.height)];
      if (s.kind == 'spray') {
        final rnd = math.Random(si * 7919);
        final dot = Paint()..color = s.color;
        for (final p in pts) {
          for (var k = 0; k < 14; k++) {
            final a = rnd.nextDouble() * 2 * math.pi, r = rnd.nextDouble() * w * 1.5;
            canvas.drawCircle(p + Offset(math.cos(a) * r, math.sin(a) * r), math.max(0.6, w * 0.06), dot);
          }
        }
        continue;
      }
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.kind == 'marker' ? w * 2 : w
        ..strokeCap = s.kind == 'marker' ? StrokeCap.square : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = s.kind == 'marker' ? s.color.withValues(alpha: 0.45) : s.color;
      if (s.kind == 'eraser') {
        paint
          ..blendMode = BlendMode.clear
          ..strokeWidth = w * 2.5;
      }
      if (pts.length == 1) {
        canvas.drawCircle(pts.first, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        final m = (pts[i - 1] + pts[i]) / 2;
        path.quadraticBezierTo(pts[i - 1].dx, pts[i - 1].dy, m.dx, m.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PaintingPainter old) => true;
}

class PaintTool extends StatefulWidget {
  final ToolContext t;
  const PaintTool(this.t, {super.key});

  @override
  State<PaintTool> createState() => _PaintState();
}

class _PaintState extends State<PaintTool> {
  ui.Image? _bg;
  final List<_Stroke> _strokes = [];
  final List<_Stroke> _redo = [];
  String _brush = 'pen';
  int _color = 1;
  double _width = 0.012;
  bool _busy = false;

  ToolContext get t => widget.t;

  double get _aspect {
    final b = _bg;
    return b == null ? 3 / 4 : b.width / b.height;
  }

  Future<void> _pickBg() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    final im = await decodeUi(b, maxSide: 2048);
    if (mounted) setState(() => _bg = im);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final w = _aspect >= 1 ? 2048 : (2048 * _aspect).round();
    final h = _aspect >= 1 ? (2048 / _aspect).round() : 2048;
    final im = await renderImage(w, h, (c, s) => _PaintingPainter(_bg, _strokes).paint(c, s));
    if (mounted) await _exportImage(context, t, im, 'resim', png: true);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = <int>[0xFF000000, ...kSwatches.skip(1)];
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: AspectRatio(
              aspectRatio: _aspect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LayoutBuilder(builder: (context, box) {
                  Offset norm(Offset o) => Offset(o.dx / box.maxWidth, o.dy / box.maxHeight);
                  return GestureDetector(
                    onPanStart: (d) => setState(() {
                      _redo.clear();
                      _strokes.add(_Stroke(_brush, Color(colors[_color]), _width)..pts.add(norm(d.localPosition)));
                    }),
                    onPanUpdate: (d) => setState(() => _strokes.last.pts.add(norm(d.localPosition))),
                    child: CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _PaintingPainter(_bg, _strokes)),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
      ChipsRow<String>(
        values: const ['pen', 'marker', 'spray', 'eraser'],
        label: (k) => L(t, k),
        selected: _brush,
        onChanged: (v) => setState(() => _brush = v),
      ),
      swatchRow(_color, (i) => setState(() => _color = i), colors: colors),
      SliderRow(label: L(t, 'brush_size'), value: _width, min: 0.003, max: 0.06, format: (v) => '${(v * 1000).round()}', onChanged: (v) => setState(() => _width = v)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        AppButton(
          label: t.core('undo'),
          icon: Icons.undo_rounded,
          onPressed: _strokes.isEmpty ? null : () => setState(() => _redo.add(_strokes.removeLast())),
        ),
        AppButton(
          label: '↻',
          icon: Icons.redo_rounded,
          onPressed: _redo.isEmpty ? null : () => setState(() => _strokes.add(_redo.removeLast())),
        ),
        AppButton(label: L(t, 'background'), icon: Icons.image_rounded, onPressed: _pickBg),
        AppButton(label: L(t, 'clear'), icon: Icons.delete_sweep_rounded, onPressed: () => setState(() {
              _strokes.clear();
              _redo.clear();
              _bg = null;
            })),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ tasarım tuvali (logo, kart, afiş)

class _El {
  String kind; // text, shape, icon
  String text;
  Offset pos; // 0..1
  double size; // kısa kenara oranla
  int color;
  String shape; // circle, square, hexagon, star
  int icon;
  bool bold;
  _El.text(this.text, this.pos, this.size, this.color, {this.bold = true})
      : kind = 'text',
        shape = '',
        icon = 0;
  _El.shape(this.shape, this.pos, this.size, this.color)
      : kind = 'shape',
        text = '',
        icon = 0,
        bold = false;
  _El.icon(this.icon, this.pos, this.size, this.color)
      : kind = 'icon',
        text = '',
        shape = '',
        bold = false;
}

/// Logo simgeleri: genel Material simgeleri (marka değil).
const List<IconData> kLogoIcons = [
  Icons.star_rounded, Icons.bolt_rounded, Icons.eco_rounded, Icons.pets_rounded, Icons.local_cafe_rounded, //
  Icons.camera_alt_rounded, Icons.music_note_rounded, Icons.rocket_launch_rounded, Icons.spa_rounded,
  Icons.favorite_rounded, Icons.home_rounded, Icons.brush_rounded, Icons.restaurant_rounded, Icons.sports_soccer_rounded,
];

const List<String> kShapeIds = ['circle', 'square', 'hexagon', 'star'];

Path shapePath(String id, Offset c, double r) {
  final p = Path();
  switch (id) {
    case 'square':
      p.addRRect(RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: r), Radius.circular(r * 0.25)));
      break;
    case 'hexagon':
      for (var i = 0; i < 6; i++) {
        final a = math.pi / 3 * i - math.pi / 2;
        final pt = c + Offset(math.cos(a) * r, math.sin(a) * r);
        if (i == 0) {
          p.moveTo(pt.dx, pt.dy);
        } else {
          p.lineTo(pt.dx, pt.dy);
        }
      }
      p.close();
      break;
    case 'star':
      for (var i = 0; i < 10; i++) {
        final a = math.pi / 5 * i - math.pi / 2;
        final rr = i.isEven ? r : r * 0.45;
        final pt = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
        if (i == 0) {
          p.moveTo(pt.dx, pt.dy);
        } else {
          p.lineTo(pt.dx, pt.dy);
        }
      }
      p.close();
      break;
    default:
      p.addOval(Rect.fromCircle(center: c, radius: r));
  }
  return p;
}

class DesignPainter extends CustomPainter {
  final List<_El> els;
  final int seed;
  final ui.Image? photo;
  final String decor; // none, confetti, hearts, rings, sparkles, leaves
  final int? selected;
  final TextDirection dir;
  DesignPainter(this.els, this.seed, this.photo, this.decor, {this.selected, this.dir = TextDirection.ltr});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pal = paletteFromSeed(seed).map((c) => Color(c)).toList();
    final ph = photo;
    if (ph != null) {
      paintImage(canvas: canvas, rect: rect, image: ph, fit: BoxFit.cover, filterQuality: FilterQuality.high);
      canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.25));
    } else {
      canvas.drawRect(
        rect,
        Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [pal[0], pal[1]]).createShader(rect),
      );
    }
    final u = size.shortestSide;
    final rnd = math.Random(seed);
    switch (decor) {
      case 'confetti':
        for (var i = 0; i < 70; i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(rnd.nextDouble() * math.pi);
          canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: u * 0.02, height: u * 0.008),
              Paint()..color = Color(kSwatches[3 + rnd.nextInt(kSwatches.length - 3)]));
          canvas.restore();
        }
        break;
      case 'hearts':
        for (var i = 0; i < 18; i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          final r = u * (0.015 + rnd.nextDouble() * 0.03);
          final h = Path()
            ..moveTo(c.dx, c.dy + r)
            ..cubicTo(c.dx - r * 2, c.dy - r * 0.2, c.dx - r * 0.8, c.dy - r * 1.6, c.dx, c.dy - r * 0.5)
            ..cubicTo(c.dx + r * 0.8, c.dy - r * 1.6, c.dx + r * 2, c.dy - r * 0.2, c.dx, c.dy + r);
          canvas.drawPath(h, Paint()..color = const Color(0xFFFF8A80).withValues(alpha: 0.6));
        }
        break;
      case 'rings':
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = u * 0.006
          ..color = Colors.white.withValues(alpha: 0.7);
        canvas.drawCircle(Offset(size.width * 0.46, size.height * 0.2), u * 0.06, ring);
        canvas.drawCircle(Offset(size.width * 0.54, size.height * 0.2), u * 0.06, ring);
        canvas.drawRect(rect.deflate(u * 0.03), ring);
        break;
      case 'sparkles':
        for (var i = 0; i < 28; i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          canvas.drawPath(shapePath('star', c, u * (0.006 + rnd.nextDouble() * 0.014)), Paint()..color = const Color(0xFFFFF59D).withValues(alpha: 0.8));
        }
        break;
      case 'leaves':
        for (var i = 0; i < 14; i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextBool() ? rnd.nextDouble() * size.height * 0.15 : size.height * (0.85 + rnd.nextDouble() * 0.15));
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(rnd.nextDouble() * math.pi * 2);
          canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: u * 0.08, height: u * 0.03), Paint()..color = const Color(0xFF81C784).withValues(alpha: 0.7));
          canvas.restore();
        }
        break;
    }
    for (var i = 0; i < els.length; i++) {
      final e = els[i];
      final c = Offset(e.pos.dx * size.width, e.pos.dy * size.height);
      final s = e.size * u;
      switch (e.kind) {
        case 'shape':
          canvas.drawPath(shapePath(e.shape, c, s), Paint()..color = Color(e.color));
          break;
        case 'icon':
          final ic = kLogoIcons[e.icon % kLogoIcons.length];
          final itp = TextPainter(
            text: TextSpan(
              text: String.fromCharCode(ic.codePoint),
              style: TextStyle(fontFamily: ic.fontFamily, package: ic.fontPackage, fontSize: s * 2, color: Color(e.color)),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          itp.paint(canvas, c - Offset(itp.width / 2, itp.height / 2));
          break;
        default:
          final tp = TextPainter(
            text: TextSpan(
              text: e.text,
              style: TextStyle(
                fontSize: s,
                height: 1.15,
                fontWeight: e.bold ? FontWeight.w900 : FontWeight.w500,
                color: Color(e.color),
                shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: s * 0.08, offset: Offset(0, s * 0.03))],
              ),
            ),
            textAlign: TextAlign.center,
            textDirection: dir,
          )..layout(maxWidth: size.width * 0.9);
          tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      }
      if (i == selected) {
        canvas.drawCircle(
            c,
            math.max(s, u * 0.04),
            Paint()
              ..style = PaintingStyle.stroke
              ..color = Colors.white70
              ..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(DesignPainter old) => true;
}

/// Logo, davetiye/kart ve afiş/sosyal medya tasarımı ([kind]: logo, card, poster).
class DesignTool extends StatefulWidget {
  final ToolContext t;
  final String kind;
  const DesignTool(this.t, {super.key, required this.kind});

  @override
  State<DesignTool> createState() => _DesignState();
}

class _DesignState extends State<DesignTool> {
  final List<_El> _els = [];
  int _seed = 7;
  ui.Image? _photo;
  String _decor = 'none';
  String _sizeId = 'square';
  String _template = '';
  int? _sel;
  final _text = TextEditingController();
  bool _busy = false;

  ToolContext get t => widget.t;

  static const Map<String, (int, int)> _sizes = {
    'square': (1080, 1080),
    'portrait': (1080, 1350),
    'story': (1080, 1920),
    'landscape': (1920, 1080),
    'card': (1240, 1748),
  };

  List<String> get _sizeOptions => switch (widget.kind) {
        'logo' => const ['square'],
        'card' => const ['card', 'square', 'landscape'],
        _ => const ['square', 'portrait', 'story', 'landscape'],
      };

  List<String> get _templates =>
      widget.kind == 'card' ? const ['birthday', 'wedding', 'party', 'holiday', 'thanks'] : const [];

  @override
  void initState() {
    super.initState();
    _sizeId = _sizeOptions.first;
    _applyTemplate(widget.kind == 'card' ? 'birthday' : '');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _applyTemplate(String id) {
    _els.clear();
    _template = id;
    _sel = null;
    switch (widget.kind) {
      case 'logo':
        _seed = 11;
        _decor = 'none';
        _els
          ..add(_El.shape('circle', const Offset(0.5, 0.4), 0.22, 0xFFFFFFFF))
          ..add(_El.icon(0, const Offset(0.5, 0.4), 0.13, 0xFF263238))
          ..add(_El.text('LOGO', const Offset(0.5, 0.75), 0.11, 0xFFFFFFFF));
        break;
      case 'card':
        const decor = {'birthday': 'confetti', 'wedding': 'rings', 'party': 'sparkles', 'holiday': 'leaves', 'thanks': 'hearts'};
        const seeds = {'birthday': 3, 'wedding': 21, 'party': 9, 'holiday': 33, 'thanks': 45};
        _decor = decor[id] ?? 'none';
        _seed = seeds[id] ?? 5;
        _els
          ..add(_El.text(L(t, 't_$id'), const Offset(0.5, 0.36), 0.1, 0xFFFFFFFF))
          ..add(_El.text('…', const Offset(0.5, 0.56), 0.05, 0xFFFFFFFF, bold: false))
          ..add(_El.text('00.00.0000', const Offset(0.5, 0.7), 0.045, 0xFFFFFFFF, bold: false));
        break;
      default:
        _seed = 17;
        _decor = 'sparkles';
        _els
          ..add(_El.text(L(t, 'text'), const Offset(0.5, 0.4), 0.11, 0xFFFFFFFF))
          ..add(_El.text('…', const Offset(0.5, 0.6), 0.05, 0xFFFFFFFF, bold: false));
    }
  }

  void _select(int? i) {
    setState(() => _sel = i);
    _text.text = i == null || _els[i].kind != 'text' ? '' : _els[i].text;
  }

  int? _hit(Offset n, double aspect) {
    int? best;
    var bestD = 0.12;
    for (var i = 0; i < _els.length; i++) {
      final d = Offset((_els[i].pos.dx - n.dx) * aspect, _els[i].pos.dy - n.dy).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  Future<void> _pickPhoto() async {
    final p = await MediaPick.image();
    final b = await p?.read();
    if (b == null) return;
    final im = await decodeUi(b, maxSide: 2048);
    if (mounted) setState(() => _photo = im);
  }

  Future<void> _save() async {
    final s = _sizes[_sizeId] ?? (1080, 1080);
    setState(() {
      _busy = true;
      _sel = null;
    });
    final im = await renderImage(s.$1, s.$2, (c, sz) => DesignPainter(_els, _seed, _photo, _decor, dir: t.rtl ? TextDirection.rtl : TextDirection.ltr).paint(c, sz));
    if (mounted) await _exportImage(context, t, im, widget.kind, png: widget.kind == 'logo');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = _sizes[_sizeId] ?? (1080, 1080);
    final aspect = s.$1 / s.$2;
    final sel = _sel;
    final e = sel == null || sel >= _els.length ? null : _els[sel];
    return ToolList(children: [
      if (_templates.isNotEmpty)
        ChipsRow<String>(
          values: _templates,
          label: (k) => L(t, 't_$k'),
          selected: _template,
          onChanged: (v) => setState(() => _applyTemplate(v)),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: AspectRatio(
              aspectRatio: aspect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LayoutBuilder(builder: (context, box) {
                  Offset norm(Offset o) => Offset((o.dx / box.maxWidth).clamp(0.0, 1.0), (o.dy / box.maxHeight).clamp(0.0, 1.0));
                  return GestureDetector(
                    onTapDown: (d) => _select(_hit(norm(d.localPosition), aspect)),
                    onPanStart: (d) => _select(_hit(norm(d.localPosition), aspect)),
                    onPanUpdate: (d) {
                      final i = _sel;
                      if (i == null) return;
                      setState(() => _els[i].pos = norm(d.localPosition));
                    },
                    child: CustomPaint(
                      size: Size(box.maxWidth, box.maxHeight),
                      painter: DesignPainter(_els, _seed, _photo, _decor,
                          selected: _sel, dir: t.rtl ? TextDirection.rtl : TextDirection.ltr),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
      if (_sizeOptions.length > 1)
        ChipsRow<String>(
          values: _sizeOptions,
          label: (k) => k == 'card' ? '${_sizes[k]!.$1}×${_sizes[k]!.$2}' : L(t, 'sz_$k'),
          selected: _sizeId,
          onChanged: (v) => setState(() => _sizeId = v),
        ),
      if (e != null) ...[
        if (e.kind == 'text')
          AppTextField(
            controller: _text,
            label: L(t, 'text'),
            onChanged: (v) => setState(() => e.text = v),
          ),
        if (e.kind == 'shape')
          ChipsRow<String>(values: kShapeIds, label: (k) => k == 'circle' ? '●' : k == 'square' ? '■' : k == 'hexagon' ? '⬢' : '★', selected: e.shape, onChanged: (v) => setState(() => e.shape = v)),
        if (e.kind == 'icon')
          SizedBox(
            height: 52,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (var i = 0; i < kLogoIcons.length; i++)
                IconButton(
                  isSelected: e.icon == i,
                  onPressed: () => setState(() => e.icon = i),
                  icon: Icon(kLogoIcons[i]),
                ),
            ]),
          ),
        SliderRow(label: L(t, 'size'), value: e.size, min: 0.02, max: 0.4, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => e.size = v)),
        swatchRow(kSwatches.indexOf(e.color).clamp(0, kSwatches.length - 1), (i) => setState(() => e.color = kSwatches[i])),
      ],
      ActionRow([
        AppButton(
          label: L(t, 'add_text'),
          icon: Icons.title_rounded,
          onPressed: () => setState(() {
            _els.add(_El.text(L(t, 'text'), const Offset(0.5, 0.5), 0.07, 0xFFFFFFFF));
            _select(_els.length - 1);
          }),
        ),
        if (widget.kind == 'logo') ...[
          AppButton(
            label: L(t, 'shape'),
            icon: Icons.category_rounded,
            onPressed: () => setState(() => _els.insert(0, _El.shape('hexagon', const Offset(0.5, 0.4), 0.2, 0xFFFFFFFF))),
          ),
          AppButton(
            label: L(t, 'icon'),
            icon: Icons.emoji_symbols_rounded,
            onPressed: () => setState(() => _els.add(_El.icon(1, const Offset(0.5, 0.4), 0.1, 0xFF263238))),
          ),
        ],
        if (e != null)
          AppButton(
            label: t.core('delete'),
            icon: Icons.delete_outline_rounded,
            onPressed: () => setState(() {
              _els.removeAt(sel!);
              _sel = null;
            }),
          ),
      ]),
      AppHeading(L(t, 'background'), icon: Icons.format_paint_rounded),
      ActionRow([
        AppButton(label: L(t, 'randomize'), icon: Icons.casino_rounded, onPressed: () => setState(() => _seed = math.Random().nextInt(1 << 30))),
        AppButton(label: L(t, 'pick_photo'), icon: Icons.image_rounded, onPressed: _pickPhoto),
        if (_photo != null) AppButton(label: L(t, 'clear'), icon: Icons.hide_image_rounded, onPressed: () => setState(() => _photo = null)),
      ]),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save)]),
    ]);
  }
}
