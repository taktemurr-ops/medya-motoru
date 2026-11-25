/// Yerel ortam eklentisi (Android Media3 Transformer, iOS AVFoundation,
/// ONNX Runtime). Web'de ve masaüstünde yoktur; o zaman her çağrı null/false
/// döner ve araçlar "bu cihazda yok" bilgisini gösterir.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Video/ses dosyası hakkında temel bilgi.
class MediaInfo {
  final int durationMs;
  final int width;
  final int height;
  final int rotation;
  final bool hasAudio;
  final bool hasVideo;
  const MediaInfo(this.durationMs, this.width, this.height, this.rotation, this.hasAudio, this.hasVideo);

  /// Ekranda görünen (döndürme uygulanmış) boyut.
  int get displayWidth => rotation % 180 != 0 && defaultTargetPlatform == TargetPlatform.android ? height : width;
  int get displayHeight => rotation % 180 != 0 && defaultTargetPlatform == TargetPlatform.android ? width : height;
}

class MedyaNative {
  static const MethodChannel _ch = MethodChannel('medya_motoru/media');

  /// Yerel video ve yapay zekâ işlemleri yalnızca Android ve iOS'ta.
  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('medya_motoru $method: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> _ok(String method, Map<String, Object?> args) async => (await _call<bool>(method, args)) == true;

  static Future<MediaInfo?> probe(String path) async {
    final m = await _call<Map<Object?, Object?>>('probe', {'path': path});
    if (m == null) return null;
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return MediaInfo(n('durationMs'), n('width'), n('height'), n('rotation'), m['hasAudio'] == true, m['hasVideo'] == true);
  }

  static Future<bool> trim(String input, String output, int startMs, int endMs, {bool hasAudio = true}) =>
      _ok('trim', {'input': input, 'output': output, 'startMs': startMs, 'endMs': endMs, 'hasAudio': hasAudio});

  static Future<bool> merge(List<String> inputs, String output, {int width = 0, int height = 0}) =>
      _ok('merge', {'inputs': inputs, 'output': output, 'width': width, 'height': height});

  static Future<bool> compress(String input, String output,
          {required int maxHeight, required int bitrateKbps, bool hasAudio = true}) =>
      _ok('compress', {
        'input': input,
        'output': output,
        'maxHeight': maxHeight,
        'bitrateKbps': bitrateKbps,
        'hasAudio': hasAudio,
      });

  static Future<bool> speed(String input, String output, double factor, {bool keepAudio = true, bool hasAudio = true}) =>
      _ok('speed', {'input': input, 'output': output, 'factor': factor, 'keepAudio': keepAudio, 'hasAudio': hasAudio});

  static Future<bool> extractAudio(String input, String output) =>
      _ok('extractAudio', {'input': input, 'output': output});

  /// Herhangi bir ses/video dosyasını 16 bit PCM WAV'a çözer.
  static Future<bool> decodeToWav(String input, String output, {int sampleRate = 44100, int channels = 1}) =>
      _ok('decodeToWav', {'input': input, 'output': output, 'sampleRate': sampleRate, 'channels': channels});

  /// WAV → AAC (M4A).
  static Future<bool> encodeM4a(String input, String output) => _ok('encodeM4a', {'input': input, 'output': output});

  static Future<bool> slideshow(List<String> images, String output,
          {required int msPerImage, required int width, required int height}) =>
      _ok('slideshow', {'images': images, 'output': output, 'msPerImage': msPerImage, 'width': width, 'height': height});

  static Future<List<String>> frames(String input, String outDir,
      {required int count, int maxSide = 480, int startMs = 0, int endMs = -1}) async {
    final r = await _call<List<Object?>>('frames', {
      'input': input,
      'outDir': outDir,
      'count': count,
      'maxSide': maxSide,
      'startMs': startMs,
      'endMs': endMs,
    });
    return [for (final p in r ?? const <Object?>[]) if (p is String) p];
  }

  /// ONNX modelini çalıştırır; ilk çıktının düz verisini döndürür.
  static Future<Float32List?> onnx(String modelPath, Float32List input, List<int> shape) =>
      _call<Float32List>('onnxRun', {'model': modelPath, 'input': input, 'shape': shape});

  /// Android 10+: dosyayı "Ringtones" klasörüne ekler.
  static Future<bool> saveRingtone(String path, String name) => _ok('saveRingtone', {'path': path, 'name': name});

  static Future<bool> openSoundSettings() => _ok('openSoundSettings', const {});

  // ------------------------------------------------------------ ekran kaydı (Android)

  /// Ekran kaydını başlatır: sistem izin penceresi (MediaProjection) açılır,
  /// kullanıcı onaylarsa ön plan hizmeti [delayMs] sonra kayda başlar.
  static Future<bool> screenRecordStart({
    required String output,
    required int width,
    required int height,
    required int dpi,
    required int fps,
    required int bitrate,
    required bool audio,
    int delayMs = 0,
  }) =>
      _ok('screenRecordStart', {
        'output': output,
        'width': width,
        'height': height,
        'dpi': dpi,
        'fps': fps,
        'bitrate': bitrate,
        'audio': audio,
        'delayMs': delayMs,
      });

  static Future<bool> screenRecordStop() => _ok('screenRecordStop', const {});

  static Future<bool> screenRecordPause(bool pause) => _ok('screenRecordPause', {'pause': pause});

  /// Kayıt durumu: kayıtta mı, duraklatıldı mı, geçen süre, dosya, hata.
  static Future<({bool recording, bool paused, bool waiting, int elapsedMs, String? path, String? error})> screenRecordStatus() async {
    final m = await _call<Map<Object?, Object?>>('screenRecordStatus', const {});
    return (
      recording: m?['recording'] == true,
      paused: m?['paused'] == true,
      waiting: m?['waiting'] == true,
      elapsedMs: (m?['elapsedMs'] as num?)?.toInt() ?? 0,
      path: m?['path'] as String?,
      error: m?['error'] as String?,
    );
  }
}
