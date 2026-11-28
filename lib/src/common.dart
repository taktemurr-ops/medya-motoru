/// Araçların ortak yardımcıları: çeviri, düzen parçaları, dosya seçme
/// (Android Photo Picker), görüntü çözme/kodlama, kaydetme, ses yükleme,
/// ses çalma, kamera kutusu ve dalga biçimi çizimi.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:studio_core/app/studio_ui.dart';
import 'package:studio_core/apps/apps.dart';

import 'dsp/audio.dart';
import 'dsp/imaging.dart';
import 'native.dart';
import 'platform/files.dart';
import 'tx.dart';

// ------------------------------------------------------------------ metin

/// Araç etiketi (33 dil); {ad} yer tutucuları [p] ile doldurulur.
String L(ToolContext t, String key, [Map<String, Object> p = const {}]) {
  var s = t.t(kMedyaL[key] ?? [key]);
  p.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// "Bu cihazda yok" bilgisi.
Widget notAvailable(ToolContext t) =>
    AppInfoCard(t.tx(kIsWeb ? 'web_unavailable' : 'not_available'), icon: Icons.block_rounded);

void snack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

// ------------------------------------------------------------------ düzen

class ToolList extends StatelessWidget {
  final List<Widget> children;
  const ToolList({super.key, required this.children});

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.only(top: 8, bottom: 32), children: children);
}

class Choice<T> extends StatelessWidget {
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  const Choice({super.key, required this.values, required this.labels, required this.selected, required this.onChanged});

  /// Onaylı tasarımın hap çipleri (seçili olan vurgu renginde).
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Center(
                  widthFactor: 1,
                  child: StudioPill(
                    label: labels[i],
                    selected: values[i] == selected,
                    onTap: () => onChanged(values[i]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Yatay kaydırılan seçim çipleri (çok seçenek için).
class ChipsRow<T> extends StatelessWidget {
  final List<T> values;
  final String Function(T) label;
  final T selected;
  final ValueChanged<T> onChanged;
  const ChipsRow({super.key, required this.values, required this.label, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final v in values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(child: StudioPill(label: label(v), selected: v == selected, onTap: () => onChanged(v))),
            ),
        ],
      ),
    );
  }
}

class SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.format,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(color: Colors.white70))),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(format?.call(v) ?? v.toStringAsFixed(1),
              textAlign: TextAlign.end, style: const TextStyle(color: Colors.white)),
        ),
      ]),
    );
  }
}

class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  const AppTextField({super.key, required this.controller, required this.label, this.maxLines = 1, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        onChanged: onChanged,
        style: const TextStyle(color: Colors.white, fontSize: 17),
        decoration: InputDecoration(
          labelText: label,
        ),
      ),
    );
  }
}

/// Butonları sarmalayan satır.
class ActionRow extends StatelessWidget {
  final List<Widget> children;
  const ActionRow(this.children, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: children),
      );
}

/// İşlem sürerken gösterilen satır.
class BusyLine extends StatelessWidget {
  final String text;
  final double? progress;
  const BusyLine(this.text, {super.key, this.progress});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: Colors.white70)),
        ]),
      );
}

/// Seçilmiş bir şey yokken gösterilen büyük seçme düğmesi.
class PickPrompt extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const PickPrompt({super.key, required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final look = StudioLook.of(context);
    return StudioPanel(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 30),
      child: Column(children: [
        StudioIconBadge(icon, color: look.accent, size: 64),
        const SizedBox(height: 12),
        Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// ui.Image önizlemesi (isteğe bağlı renk matrisiyle).
class ImagePreview extends StatelessWidget {
  final ui.Image image;
  final List<double>? matrix;
  final double maxHeight;
  final bool checker;
  const ImagePreview(this.image, {super.key, this.matrix, this.maxHeight = 380, this.checker = false});

  @override
  Widget build(BuildContext context) {
    Widget child = RawImage(image: image, fit: BoxFit.contain);
    if (matrix != null) child = ColorFiltered(colorFilter: ColorFilter.matrix(matrix!), child: child);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(
          aspectRatio: image.width / math.max<int>(1, image.height),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: checker ? CustomPaint(painter: CheckerPainter(), child: child) : child,
          ),
        ),
      ),
    );
  }
}

/// Saydam alanlar için dama deseni.
class CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 12.0;
    final a = Paint()..color = const Color(0xFF3A3A3A);
    final b = Paint()..color = const Color(0xFF555555);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        final odd = ((x / s).floor() + (y / s).floor()).isOdd;
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), odd ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(CheckerPainter oldDelegate) => false;
}

// ------------------------------------------------------------------ seçme

/// Seçilen dosya: web'de yalnızca baytlar, mobilde yol da vardır.
class Picked {
  final String name;
  final Uint8List? bytes;
  final String? path;
  const Picked(this.name, {this.bytes, this.path});

  Future<Uint8List?> read() async => bytes ?? (path == null ? null : await MediaFiles.read(path!));
}

class MediaPick {
  static bool _photoPickerSet = false;

  /// Android'de geniş medya izni yerine sistem Photo Picker'ını kullanır.
  static void _usePhotoPicker() {
    if (_photoPickerSet) return;
    _photoPickerSet = true;
    final p = ImagePickerPlatform.instance;
    if (p is ImagePickerAndroid) p.useAndroidPhotoPicker = true;
  }

  static Future<Picked?> image() async {
    _usePhotoPicker();
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return null;
      return Picked(x.name, bytes: await x.readAsBytes(), path: kIsWeb ? null : x.path);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Picked>> images() async {
    _usePhotoPicker();
    try {
      final xs = await ImagePicker().pickMultiImage();
      return [for (final x in xs) Picked(x.name, path: kIsWeb ? null : x.path, bytes: kIsWeb ? await x.readAsBytes() : null)];
    } catch (_) {
      return const [];
    }
  }

  /// Video yolu (yalnızca mobil).
  static Future<String?> video() async {
    if (kIsWeb) return null;
    _usePhotoPicker();
    try {
      final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
      return x?.path;
    } catch (_) {
      return null;
    }
  }

  /// Ses dosyaları (sistem dosya seçicisi; izin gerekmez).
  static Future<List<Picked>> audio({bool multiple = false}) async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: multiple, withData: kIsWeb);
      if (r == null) return const [];
      return [
        for (final f in r.files)
          Picked(f.name, bytes: f.bytes, path: kIsWeb ? null : f.path),
      ];
    } catch (_) {
      return const [];
    }
  }
}

// ------------------------------------------------------------------ görüntü

/// Görüntüyü çözer; en uzun kenar [maxSide]'ı aşarsa oranı koruyarak küçültür.
/// [onSize] özgün boyutu bildirir.
Future<ui.Image?> decodeUi(Uint8List bytes, {int maxSide = 4096, void Function(int w, int h)? onSize}) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      onSize?.call(w, h);
      if (math.max<int>(w, h) <= maxSide) return ui.TargetImageSize(width: w, height: h);
      return w >= h ? ui.TargetImageSize(width: maxSide) : ui.TargetImageSize(height: maxSide);
    });
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> pngOf(ui.Image image) async {
  final d = await image.toByteData(format: ui.ImageByteFormat.png);
  return d?.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
}

Future<Rgba?> rgbaOf(ui.Image image) async {
  final d = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (d == null) return null;
  return Rgba(image.width, image.height, Uint8List.fromList(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)));
}

/// RGBA tamponundan ui.Image (alfa varsa önceden çarpılır).
Future<ui.Image> uiOf(Rgba r) {
  var px = r.data;
  var hasAlpha = false;
  for (var i = 3; i < px.length; i += 4) {
    if (px[i] != 255) {
      hasAlpha = true;
      break;
    }
  }
  if (hasAlpha) {
    px = Uint8List.fromList(px);
    for (var i = 0; i < px.length; i += 4) {
      final a = px[i + 3];
      px[i] = px[i] * a ~/ 255;
      px[i + 1] = px[i + 1] * a ~/ 255;
      px[i + 2] = px[i + 2] * a ~/ 255;
    }
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, r.width, r.height, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Tuvale çizip görüntü üretir.
Future<ui.Image> renderImage(int width, int height, void Function(Canvas canvas, Size size) paint) {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  paint(canvas, Size(width.toDouble(), height.toDouble()));
  final pic = rec.endRecording();
  return pic.toImage(width, height);
}

/// Görüntüyü renk matrisiyle yeniden çizer.
Future<ui.Image> renderWithMatrix(ui.Image src, List<double> matrix) =>
    renderImage(src.width, src.height, (c, s) {
      c.drawImage(src, Offset.zero, Paint()..colorFilter = ColorFilter.matrix(matrix));
    });

Uint8List _encodeJpg((Rgba, int) a) {
  final r = a.$1;
  final im = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.data.buffer,
    bytesOffset: r.data.offsetInBytes,
    numChannels: 4,
  );
  return img.encodeJpg(im, quality: a.$2);
}

Uint8List _encodePng(Rgba r) {
  final im = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.data.buffer,
    bytesOffset: r.data.offsetInBytes,
    numChannels: 4,
  );
  return img.encodePng(im, level: 6);
}

/// JPEG kodlama (mobilde ayrı izolede).
Future<Uint8List> jpgOf(Rgba r, {int quality = 90}) => compute(_encodeJpg, (r, quality));

Future<Uint8List> pngOfRgba(Rgba r) => compute(_encodePng, r);

/// Kaydeder ve sonucu kısa mesajla bildirir.
/// Galeriye kaydedildiyse kısa mesajda "Paylaş" düğmesi de çıkar (piyasadaki
/// düzenleyiciler gibi kaydet → paylaş tek adımda).
Future<void> saveImage(BuildContext context, ToolContext t, Uint8List bytes, String name) async {
  final ok = await MediaFiles.saveImage(bytes, name);
  if (!context.mounted) return;
  if (!ok) return snack(context, L(t, 'save_failed'));
  final mime = name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(L(t, 'saved')),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(label: L(t, 'share'), onPressed: () => MediaFiles.shareBytes(bytes, name, mime)),
    ));
}

Future<void> saveFile(BuildContext context, ToolContext t, Uint8List bytes, String name, String mime) async {
  final ok = await MediaFiles.shareBytes(bytes, name, mime);
  if (context.mounted) snack(context, L(t, ok ? 'saved' : 'save_failed'));
}

Future<void> saveText(BuildContext context, ToolContext t, String text, String name, String mime) =>
    saveFile(context, t, Uint8List.fromList(utf8.encode(text)), name, mime);

String stamp() {
  final d = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
}

// ------------------------------------------------------------------ ses

/// Seçilen ses dosyasını çözer: WAV her yerde, diğer biçimler mobilde
/// yerel çözücüyle. Web'de WAV dışı biçimler için null döner.
Future<Pcm?> loadAudio(Picked p, {int rate = 44100}) async {
  final bytes = p.bytes;
  if (bytes != null && p.name.toLowerCase().endsWith('.wav')) {
    final w = decodeWav(bytes);
    if (w != null) return w;
  }
  if (!MedyaNative.supported) {
    if (bytes != null) return decodeWav(bytes);
    if (p.path != null) {
      final b = await MediaFiles.read(p.path!);
      return b == null ? null : decodeWav(b);
    }
    return null;
  }
  var src = p.path;
  if (src == null && bytes != null) {
    final ext = p.name.contains('.') ? p.name.split('.').last : 'bin';
    src = await MediaFiles.writeTemp(bytes, ext);
  }
  if (src == null) return null;
  final out = await MediaFiles.tempPath('wav');
  if (out == null) return null;
  if (!await MedyaNative.decodeToWav(src, out, sampleRate: rate, channels: 1)) return null;
  final b = await MediaFiles.read(out);
  unawaited(MediaFiles.delete(out));
  return b == null ? null : decodeWav(b);
}

/// Tek bir ses çalar.
class TonePlayer {
  final AudioPlayer _p = AudioPlayer();
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
  StreamSubscription<PlayerState>? _sub;

  TonePlayer() {
    _sub = _p.onPlayerStateChanged.listen((s) => playing.value = s == PlayerState.playing);
  }

  Future<void> playWav(Uint8List wav, {bool loop = false, double volume = 1}) async {
    try {
      await _p.stop();
      await _p.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      await _p.setVolume(volume);
      await _p.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (_) {}
  }

  Future<void> playSource(Source s) async {
    try {
      await _p.stop();
      await _p.setReleaseMode(ReleaseMode.stop);
      await _p.play(s);
    } catch (_) {}
  }

  Future<void> setVolume(double v) async {
    try {
      await _p.setVolume(v);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _p.stop();
    } catch (_) {}
  }

  AudioPlayer get raw => _p;

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_p.dispose());
    playing.dispose();
  }
}

/// Çok sesli kısa sesler (davul, piyano): oyuncular sırayla kullanılır.
class VoicePool {
  final List<AudioPlayer> _players;
  int _next = 0;

  VoicePool([int size = 6]) : _players = List<AudioPlayer>.generate(size, (_) => AudioPlayer());

  Future<void> play(Uint8List wav, {double volume = 1}) async {
    final p = _players[_next];
    _next = (_next + 1) % _players.length;
    try {
      await p.stop();
      await p.setVolume(volume);
      await p.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (_) {}
  }

  void dispose() {
    for (final p in _players) {
      unawaited(p.dispose());
    }
  }
}

/// Dalga biçimi ve seçim aralığı.
class WaveView extends StatelessWidget {
  final List<double> peaks;
  final double start;
  final double end;
  final double? cursor;
  const WaveView(this.peaks, {super.key, this.start = 0, this.end = 1, this.cursor});

  @override
  Widget build(BuildContext context) {
    final s = AppLook.of(context);
    return AppPanel(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        height: 110,
        width: double.infinity,
        child: CustomPaint(painter: _WavePainter(peaks, start, end, cursor, s.accent)),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> peaks;
  final double start, end;
  final double? cursor;
  final Color color;
  _WavePainter(this.peaks, this.start, this.end, this.cursor, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final mid = size.height / 2;
    final w = size.width / peaks.length;
    final on = Paint()..color = color;
    final off = Paint()..color = Colors.white24;
    for (var i = 0; i < peaks.length; i++) {
      final f = i / peaks.length;
      final h = math.max(1.0, peaks[i].clamp(0.0, 1.0) * mid);
      canvas.drawRect(Rect.fromLTWH(i * w, mid - h, math.max(1.0, w - 1), h * 2), f >= start && f <= end ? on : off);
    }
    final c = cursor;
    if (c != null) {
      canvas.drawLine(Offset(c * size.width, 0), Offset(c * size.width, size.height),
          Paint()
            ..color = Colors.white
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

// ------------------------------------------------------------------ izin ve kamera

/// İzin açıklaması bir kez gösterilir ([key]: 'camera' ya da 'mic').
Future<bool> rationaleOnce(BuildContext context, ToolContext t, String key, IconData icon) async {
  if (await t.store.readBool('perm.$key')) return true;
  if (!context.mounted) return false;
  final ok = await explainPermission(context, lang: t.lang, icon: icon, reason: L(t, '${key}_perm'));
  if (ok) await t.store.writeBool('perm.$key', true);
  return ok;
}

/// Kamerayı açıp önizlemeyi çizen kutu.
class CameraBox extends StatefulWidget {
  final ToolContext tool;
  final CameraLensDirection lens;
  final Widget Function(BuildContext context, CameraController c) builder;
  const CameraBox({super.key, required this.tool, required this.builder, this.lens = CameraLensDirection.back});

  @override
  State<CameraBox> createState() => _CameraBoxState();
}

class _CameraBoxState extends State<CameraBox> with WidgetsBindingObserver {
  CameraController? _c;
  String? _error;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(CameraBox old) {
    super.didUpdateWidget(old);
    if (old.lens != widget.lens) {
      final c = _c;
      _c = null;
      if (c != null) unawaited(c.dispose());
      unawaited(_open());
    }
  }

  Future<void> _open() async {
    if (!_asked) {
      _asked = true;
      final ok = await rationaleOnce(context, widget.tool, 'camera', Icons.photo_camera_rounded);
      if (!ok) {
        if (mounted) setState(() => _error = appTx('perm_denied', widget.tool.lang));
        return;
      }
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('none', 'none');
      final cam = cams.firstWhere((c) => c.lensDirection == widget.lens, orElse: () => cams.first);
      final c = CameraController(cam, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code.toLowerCase().contains('denied')
          ? appTx('perm_denied', widget.tool.lang)
          : appTx(kIsWeb ? 'web_unavailable' : 'not_available', widget.tool.lang));
    } catch (_) {
      if (mounted) setState(() => _error = appTx('not_available', widget.tool.lang));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _c = null;
      unawaited(c.dispose());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _error == null) {
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final c = _c;
    _c = null;
    if (c != null) unawaited(c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return AppInfoCard(_error!, icon: Icons.no_photography_rounded);
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    }
    return widget.builder(context, c);
  }
}

/// Önizlemeyi kutuya sığdırır.
Widget cameraPreview(CameraController c, {double? height, List<double>? matrix}) {
  Widget p = CameraPreview(c);
  if (matrix != null) p = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: p);
  return ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      height: height,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.previewSize?.height ?? 480,
          height: c.value.previewSize?.width ?? 640,
          child: p,
        ),
      ),
    ),
  );
}
