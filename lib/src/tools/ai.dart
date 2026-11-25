/// Cihaz üzerinde yapay zekâ araçları: arka plan silme (U²-Netp), fotoğraf
/// iyileştirme (Real-ESRGAN x4v3), renklendirme (ECCV16, deneysel, isteğe
/// bağlı indirme), yüz/plaka bulanıklaştırma (ML Kit + elle) ve otomatik
/// altyazı (whisper.cpp tiny, ilk kullanımda indirilir).
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/audio.dart';
import '../dsp/imaging.dart';
import '../native.dart';
import '../platform/files.dart';
import '../platform/speech.dart';
import '../platform/vision.dart';
import 'photo.dart' show swatchRow, kSwatches;

/// Modeller: ikisi uygulamaya gömülü, renklendirme isteğe bağlı indirilir.
class Models {
  static const String u2netp = 'packages/medya_motoru/assets/models/u2netp.onnx';
  static const String esrgan = 'packages/medya_motoru/assets/models/realesr_general_x4v3.onnx';

  /// ECCV16 renklendirme ağının ONNX hâli (tool/convert_models.py ile resmî
  /// richzhang/colorization ağırlığından üretilir ve sürüm eki olarak yayınlanır).
  static const String colorizeUrl =
      'https://github.com/taktemurr-ops/medya-motoru/releases/download/models-v1/colorization_eccv16.onnx';
  static const int colorizeMb = 129;

  /// Gömülü modeli uygulama klasörüne bir kez yazar ve yolunu döndürür.
  static Future<String?> asset(String key) async {
    final dir = await MediaFiles.appDir('models');
    if (dir == null) return null;
    final path = '$dir/${key.split('/').last}';
    if (await MediaFiles.exists(path) && await MediaFiles.size(path) > 1024) return path;
    try {
      final data = await rootBundle.load(key);
      final ok = await MediaFiles.write(path, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      return ok ? path : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> colorizePath() async {
    final dir = await MediaFiles.appDir('models');
    return dir == null ? null : '$dir/colorization_eccv16.onnx';
  }

  static Future<bool> hasColorize() async {
    final p = await colorizePath();
    return p != null && await MediaFiles.exists(p) && await MediaFiles.size(p) > 50 * 1024 * 1024;
  }
}

Rgba _maskJob((Rgba, Uint8List) a) {
  final out = a.$1.copy();
  applyMask(out, a.$2, kU2Size, kU2Size);
  return out;
}

Rgba _labJob((Rgba, Float32List) a) => combineLab(a.$1, a.$2);

/// Fotoğraf seçip ui.Image + Rgba olarak hazırlar.
Future<({ui.Image image, Rgba rgba, String? path})?> pickForAi({int maxSide = 2048, void Function(int w, int h)? onSize}) async {
  final p = await MediaPick.image();
  final b = await p?.read();
  if (p == null || b == null) return null;
  final im = await decodeUi(b, maxSide: maxSide, onSize: onSize);
  if (im == null) return null;
  final rgba = await rgbaOf(im);
  if (rgba == null) return null;
  var path = p.path;
  if (path == null && MediaFiles.hasFileSystem) path = await MediaFiles.writeTemp(b, 'jpg');
  return (image: im, rgba: rgba, path: path);
}

// ================================================================ arka plan silme

class BackgroundTool extends StatefulWidget {
  final ToolContext t;
  const BackgroundTool(this.t, {super.key});

  @override
  State<BackgroundTool> createState() => _BackgroundState();
}

class _BackgroundState extends State<BackgroundTool> {
  ui.Image? _src;
  ui.Image? _cut;
  Rgba? _cutRgba;
  int _bg = -1; // -1: saydam
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    final r = await pickForAi();
    if (r == null || !mounted) return;
    setState(() {
      _src = r.image;
      _cut = null;
      _busy = true;
    });
    try {
      final model = await Models.asset(Models.u2netp);
      if (model == null) throw StateError('model');
      final out = await MedyaNative.onnx(model, u2Input(r.rgba), const [1, 3, kU2Size, kU2Size]);
      if (out == null || out.length < kU2Size * kU2Size) throw StateError('onnx');
      final mask = u2Mask(Float32List.sublistView(out, 0, kU2Size * kU2Size));
      final cut = await compute(_maskJob, (r.rgba, mask));
      final im = await uiOf(cut);
      if (!mounted) return;
      setState(() {
        _cut = im;
        _cutRgba = cut;
      });
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final cut = _cut, rgba = _cutRgba;
    if (cut == null || rgba == null) return;
    setState(() => _busy = true);
    try {
      if (_bg < 0) {
        final png = await pngOfRgba(rgba);
        if (mounted) await saveImage(context, t, png, 'arkaplansiz_${stamp()}.png');
      } else {
        final out = await renderImage(cut.width, cut.height, (c, s) {
          c.drawRect(Offset.zero & s, Paint()..color = Color(kSwatches[_bg]));
          c.drawImage(cut, Offset.zero, Paint());
        });
        final r = await rgbaOf(out);
        if (r == null) throw StateError('rgba');
        final jpg = await jpgOf(r, quality: 92);
        if (mounted) await saveImage(context, t, jpg, 'arkaplan_${stamp()}.jpg');
      }
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t), AppInfoCard(L(t, 'ai_local'))]);
    final cut = _cut, src = _src;
    return ToolList(children: [
      if (src == null)
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.auto_fix_high_rounded, onTap: _busy ? null : _pick)
      else if (cut == null)
        ImagePreview(src)
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: AspectRatio(
              aspectRatio: cut.width / cut.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CustomPaint(
                  painter: _bg < 0 ? CheckerPainter() : null,
                  child: Container(
                    color: _bg < 0 ? null : Color(kSwatches[_bg]),
                    child: RawImage(image: cut, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          ),
        ),
      if (_busy) BusyLine(L(t, 'processing')),
      if (cut != null) ...[
        AppHeading(L(t, 'background'), icon: Icons.format_color_fill_rounded),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ChoiceChip(label: const Text('▦'), selected: _bg < 0, onSelected: (_) => setState(() => _bg = -1)),
          ),
        ),
        swatchRow(_bg, (i) => setState(() => _bg = i)),
      ],
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy || cut == null ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ iyileştirme (×4)

class EnhanceTool extends StatefulWidget {
  final ToolContext t;
  const EnhanceTool(this.t, {super.key});

  @override
  State<EnhanceTool> createState() => _EnhanceState();
}

class _EnhanceState extends State<EnhanceTool> {
  ui.Image? _src;
  ui.Image? _out;
  Rgba? _outRgba;
  bool _busy = false, _showOriginal = false;
  double _progress = 0;

  ToolContext get t => widget.t;
  static const int _tile = 128, _overlap = 8, _scale = 4;

  Future<void> _pick() async {
    final r = await pickForAi(maxSide: 512);
    if (r == null || !mounted) return;
    setState(() {
      _src = r.image;
      _out = null;
      _busy = true;
      _progress = 0;
    });
    try {
      final model = await Models.asset(Models.esrgan);
      if (model == null) throw StateError('model');
      final src = r.rgba;
      final dst = Rgba(src.width * _scale, src.height * _scale, Uint8List(src.width * _scale * src.height * _scale * 4));
      final parts = tiles(src.width, src.height, _tile, _overlap);
      var done = 0;
      for (final tl in parts) {
        final piece = cropRgba(src, tl.x, tl.y, tl.w, tl.h);
        final out = await MedyaNative.onnx(model, rgbPlanar(piece), [1, 3, tl.h, tl.w]);
        if (out == null) throw StateError('onnx');
        pasteTile(dst, fromPlanar(out, tl.w * _scale, tl.h * _scale), tl, _scale, _overlap, _tile - 2 * _overlap);
        done++;
        if (mounted) setState(() => _progress = done / parts.length);
      }
      for (var i = 3; i < dst.data.length; i += 4) {
        dst.data[i] = 255;
      }
      final im = await uiOf(dst);
      if (!mounted) return;
      setState(() {
        _out = im;
        _outRgba = dst;
      });
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final r = _outRgba;
    if (r == null) return;
    setState(() => _busy = true);
    final jpg = await jpgOf(r, quality: 93);
    if (mounted) await saveImage(context, t, jpg, 'iyi_${stamp()}.jpg');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final src = _src, out = _out;
    return ToolList(children: [
      if (src == null)
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.hd_rounded, onTap: _busy ? null : _pick)
      else
        GestureDetector(
          onTapDown: (_) => setState(() => _showOriginal = true),
          onTapUp: (_) => setState(() => _showOriginal = false),
          onTapCancel: () => setState(() => _showOriginal = false),
          child: ImagePreview(out == null || _showOriginal ? src : out),
        ),
      if (out != null)
        AppResult(label: L(t, 'result'), value: '${src!.width}×${src.height} → ${out.width}×${out.height}', lang: t.lang),
      if (_busy) BusyLine(L(t, 'processing'), progress: _progress),
      AppInfoCard(L(t, 'upscale_note'), icon: Icons.info_outline_rounded),
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
      ActionRow([
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy || out == null ? null : _save),
      ]),
    ]);
  }
}

// ================================================================ renklendirme (deneysel)

class ColorizeTool extends StatefulWidget {
  final ToolContext t;
  const ColorizeTool(this.t, {super.key});

  @override
  State<ColorizeTool> createState() => _ColorizeState();
}

class _ColorizeState extends State<ColorizeTool> {
  bool? _hasModel;
  double? _dl;
  ui.Image? _src, _out;
  Rgba? _outRgba;
  bool _busy = false;
  StreamSubscription<double>? _sub;

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    unawaited(Models.hasColorize().then((v) {
      if (mounted) setState(() => _hasModel = v);
    }));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _download() async {
    final path = await Models.colorizePath();
    if (path == null) return;
    setState(() => _dl = 0);
    _sub = MediaFiles.download(Models.colorizeUrl, path).listen(
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
        final ok = await Models.hasColorize();
        if (mounted) {
          setState(() {
            _dl = null;
            _hasModel = ok;
          });
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _pick() async {
    final r = await pickForAi();
    if (r == null || !mounted) return;
    setState(() {
      _src = r.image;
      _out = null;
      _busy = true;
    });
    try {
      final model = await Models.colorizePath();
      if (model == null) throw StateError('model');
      final out = await MedyaNative.onnx(model, lightnessInput(r.rgba), const [1, 1, kColorSize, kColorSize]);
      if (out == null || out.length < 2 * kColorSize * kColorSize) throw StateError('onnx');
      final res = await compute(_labJob, (r.rgba, out));
      final im = await uiOf(res);
      if (!mounted) return;
      setState(() {
        _out = im;
        _outRgba = res;
      });
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final r = _outRgba;
    if (r == null) return;
    final jpg = await jpgOf(r, quality: 92);
    if (mounted) await saveImage(context, t, jpg, 'renkli_${stamp()}.jpg');
  }

  @override
  Widget build(BuildContext context) {
    if (!MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final has = _hasModel;
    final src = _src, out = _out;
    return ToolList(children: [
      AppInfoCard(L(t, 'experimental'), icon: Icons.science_rounded),
      if (has == null)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (!has) ...[
        if (_dl != null)
          BusyLine(L(t, 'downloading'), progress: _dl)
        else
          ActionRow([
            AppButton(
              label: L(t, 'model_download', {'mb': Models.colorizeMb}),
              icon: Icons.download_rounded,
              onPressed: _download,
            ),
          ]),
        AppInfoCard(L(t, 'model_once'), icon: Icons.wifi_off_rounded),
      ] else ...[
        if (src == null)
          PickPrompt(label: L(t, 'pick_photo'), icon: Icons.palette_rounded, onTap: _busy ? null : _pick)
        else
          ImagePreview(out ?? src),
        if (_busy) BusyLine(L(t, 'processing')),
        ActionRow([
          AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
          AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy || out == null ? null : _save),
        ]),
      ],
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
    ]);
  }
}

// ================================================================ yüz ve plaka bulanıklaştırma

class PrivacyBlurTool extends StatefulWidget {
  final ToolContext t;
  const PrivacyBlurTool(this.t, {super.key});

  @override
  State<PrivacyBlurTool> createState() => _PrivacyBlurState();
}

class _PrivacyBlurState extends State<PrivacyBlurTool> {
  ui.Image? _img;
  Rgba? _rgba;
  String? _path;
  double _origW = 1;
  final List<Rect> _rects = [];
  Offset? _dragStart;
  double _strength = 0.7;
  bool _busy = false;

  ToolContext get t => widget.t;

  Future<void> _pick() async {
    var ow = 1;
    final r = await pickForAi(maxSide: 3000, onSize: (w, h) => ow = w);
    if (r == null || !mounted) return;
    setState(() {
      _img = r.image;
      _rgba = r.rgba;
      _path = r.path;
      _origW = ow.toDouble();
      _rects.clear();
    });
  }

  Future<void> _detect(bool faces) async {
    final p = _path, im = _img;
    if (p == null || im == null) return;
    setState(() => _busy = true);
    final found = faces ? await Vision.faces(p) : await Vision.plates(p);
    final s = im.width / _origW;
    if (!mounted) return;
    setState(() {
      _busy = false;
      for (final r in found) {
        _rects.add(Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s).inflate(4 * s));
      }
    });
    snack(context, L(t, 'found_n', {'n': found.length}));
  }

  Future<void> _save() async {
    final src = _rgba;
    if (src == null) return;
    setState(() => _busy = true);
    try {
      final out = src.copy();
      for (final r in _rects) {
        blurRegion(out, r.left.round(), r.top.round(), r.width.round(), r.height.round(), strength: _strength);
      }
      final jpg = await jpgOf(out, quality: 92);
      if (mounted) await saveImage(context, t, jpg, 'gizli_${stamp()}.jpg');
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
        PickPrompt(label: L(t, 'pick_photo'), icon: Icons.blur_on_rounded, onTap: _pick),
        AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
      ]);
    }
    return ToolList(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: AspectRatio(
              aspectRatio: im.width / im.height,
              child: LayoutBuilder(builder: (context, box) {
                final k = im.width / box.maxWidth;
                Offset toImg(Offset o) => o * k;
                return GestureDetector(
                  onPanStart: (d) {
                    _dragStart = toImg(d.localPosition);
                    setState(() => _rects.add(Rect.fromPoints(_dragStart!, _dragStart!)));
                  },
                  onPanUpdate: (d) {
                    final s = _dragStart;
                    if (s == null || _rects.isEmpty) return;
                    setState(() => _rects[_rects.length - 1] = Rect.fromPoints(s, toImg(d.localPosition)));
                  },
                  onPanEnd: (_) => _dragStart = null,
                  child: CustomPaint(
                    size: Size(box.maxWidth, box.maxHeight),
                    painter: _BlurBoxPainter(im, _rects),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
      AppInfoCard(L(t, 'blur_hint'), icon: Icons.touch_app_rounded),
      SliderRow(label: L(t, 'strength'), value: _strength, min: 0.2, max: 1, format: (v) => '${(v * 100).round()}', onChanged: (v) => setState(() => _strength = v)),
      if (_busy) BusyLine(L(t, 'processing')),
      ActionRow([
        if (Vision.supported && _path != null) ...[
          AppButton(label: L(t, 'detect_faces'), icon: Icons.face_retouching_off_rounded, onPressed: _busy ? null : () => _detect(true)),
          AppButton(label: L(t, 'detect_plates'), icon: Icons.directions_car_rounded, onPressed: _busy ? null : () => _detect(false)),
        ],
        AppButton(
          label: t.core('undo'),
          icon: Icons.undo_rounded,
          onPressed: _rects.isEmpty ? null : () => setState(() => _rects.removeLast()),
        ),
        AppButton(label: L(t, 'pick_photo'), icon: Icons.photo_library_rounded, onPressed: _busy ? null : _pick),
        AppButton(label: L(t, 'save'), icon: Icons.save_alt_rounded, onPressed: _busy ? null : _save),
      ]),
    ]);
  }
}

class _BlurBoxPainter extends CustomPainter {
  final ui.Image image;
  final List<Rect> rects;
  _BlurBoxPainter(this.image, this.rects);

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);
    final s = size.width / image.width;
    final fill = Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12);
    for (final r in rects) {
      final rr = Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);
      canvas.save();
      canvas.clipRect(rr);
      canvas.saveLayer(rr, fill);
      paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);
      canvas.restore();
      canvas.restore();
      canvas.drawRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white70
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_BlurBoxPainter old) => true;
}

// ================================================================ otomatik altyazı

class SubtitleTool extends StatefulWidget {
  final ToolContext t;
  const SubtitleTool(this.t, {super.key});

  @override
  State<SubtitleTool> createState() => _SubtitleState();
}

/// Uygulama dil kodu → whisper dil kodu.
String whisperLang(String lang) {
  switch (lang) {
    case 'fil':
      return 'tl';
    case 'nb':
      return 'no';
    default:
      return lang;
  }
}

const List<String> kAppLangs = [
  'tr', 'en', 'de', 'es', 'fr', 'ar', 'fa', 'he', 'ur', 'ru', 'uk', 'pl', 'cs', 'ro', 'hu', 'el', 'it', //
  'pt', 'nl', 'sv', 'da', 'nb', 'fi', 'ja', 'ko', 'zh', 'hi', 'bn', 'id', 'ms', 'th', 'vi', 'fil',
];

class _SubtitleState extends State<SubtitleTool> {
  bool? _hasModel;
  double? _dl;
  String _lang = 'auto';
  String? _source;
  List<SpeechSegment>? _segs;
  bool _busy = false;
  StreamSubscription<double>? _sub;

  ToolContext get t => widget.t;

  @override
  void initState() {
    super.initState();
    _lang = kAppLangs.contains(t.lang) ? t.lang : 'auto';
    unawaited(Speech.hasModel().then((v) {
      if (mounted) setState(() => _hasModel = v);
    }));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _download() {
    setState(() => _dl = 0);
    _sub = Speech.download().listen(
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
        final ok = await Speech.hasModel();
        if (mounted) {
          setState(() {
            _dl = null;
            _hasModel = ok;
          });
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _run(String? path) async {
    if (path == null) return;
    setState(() {
      _busy = true;
      _source = path;
      _segs = null;
    });
    try {
      final wav = await MediaFiles.tempPath('wav');
      if (wav == null || !await MedyaNative.decodeToWav(path, wav, sampleRate: 16000, channels: 1)) {
        throw StateError('wav');
      }
      final segs = await Speech.transcribe(wav, _lang == 'auto' ? 'auto' : whisperLang(_lang));
      unawaited(MediaFiles.delete(wav));
      if (segs == null) throw StateError('whisper');
      if (mounted) setState(() => _segs = segs);
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _busy = false);
  }

  List<(Duration, Duration, String)> get _cues => [for (final s in _segs ?? const <SpeechSegment>[]) (s.from, s.to, s.text)];

  String get _base {
    final s = _source;
    if (s == null) return 'altyazi_${stamp()}';
    final name = s.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  Widget build(BuildContext context) {
    if (!Speech.supported || !MedyaNative.supported) return ToolList(children: [notAvailable(t)]);
    final has = _hasModel;
    final segs = _segs;
    return ToolList(children: [
      if (has == null)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (!has) ...[
        if (_dl != null)
          BusyLine(L(t, 'downloading'), progress: _dl)
        else
          ActionRow([
            AppButton(
              label: L(t, 'model_download', {'mb': Speech.modelMb}),
              icon: Icons.download_rounded,
              onPressed: _download,
            ),
          ]),
        AppInfoCard(L(t, 'model_once'), icon: Icons.wifi_off_rounded),
      ] else ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            initialValue: _lang,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.core('language')),
            items: [
              DropdownMenuItem(value: 'auto', child: Text(L(t, 'auto_lang'))),
              for (final l in kAppLangs) DropdownMenuItem(value: l, child: Text(l.toUpperCase())),
            ],
            onChanged: (v) => setState(() => _lang = v ?? 'auto'),
          ),
        ),
        if (_busy) BusyLine(L(t, 'processing')),
        ActionRow([
          AppButton(
            label: L(t, 'pick_video'),
            icon: Icons.video_library_rounded,
            onPressed: _busy ? null : () async => _run(await MediaPick.video()),
          ),
          AppButton(
            label: L(t, 'pick_audio'),
            icon: Icons.audio_file_rounded,
            onPressed: _busy
                ? null
                : () async {
                    final a = await MediaPick.audio();
                    if (a.isEmpty) return;
                    final p = a.first;
                    var path = p.path;
                    if (path == null && p.bytes != null) path = await MediaFiles.writeTemp(p.bytes!, 'bin');
                    await _run(path);
                  },
          ),
        ]),
        if (segs != null && segs.isEmpty) AppInfoCard(L(t, 'empty_list')),
        if (segs != null && segs.isNotEmpty) ...[
          AppHeading(L(t, 'transcript'), icon: Icons.subtitles_rounded),
          AppPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final s in segs.take(200))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${fmtClock(s.from.inMilliseconds / 1000)}  ', style: const TextStyle(color: Colors.white54)),
                    TextSpan(text: s.text, style: const TextStyle(color: Colors.white)),
                  ])),
                ),
            ]),
          ),
          ActionRow([
            AppButton(label: 'SRT', icon: Icons.save_alt_rounded, onPressed: () => saveText(context, t, toSrt(_cues), '$_base.srt', 'application/x-subrip')),
            AppButton(label: 'VTT', icon: Icons.save_alt_rounded, onPressed: () => saveText(context, t, toVtt(_cues), '$_base.vtt', 'text/vtt')),
            AppButton(
              label: 'TXT',
              icon: Icons.notes_rounded,
              onPressed: () => saveText(context, t, segs.map((s) => s.text).join('\n'), '$_base.txt', 'text/plain'),
            ),
          ]),
        ],
      ],
      AppInfoCard(L(t, 'ai_local'), icon: Icons.lock_rounded),
    ]);
  }
}
