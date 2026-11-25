/// whisper.cpp (whisper_ggml, MIT) ile cihazda konuşmadan metne.
///
/// Model (ggml-tiny.bin, ~75 MB, MIT) ilk kullanımda resmî whisper.cpp
/// deposundan indirilir: https://huggingface.co/ggerganov/whisper.cpp
library;

import 'dart:io';

import 'package:whisper_ggml/whisper_ggml.dart';

class SpeechSegment {
  final Duration from;
  final Duration to;
  final String text;
  const SpeechSegment(this.from, this.to, this.text);
}

class Speech {
  static bool get supported => Platform.isAndroid || Platform.isIOS;
  static const int modelMb = 75;
  static const WhisperModel _model = WhisperModel.tiny;

  /// Resmî indirme adresi (whisper.cpp model deposu).
  static String get modelUrl => _model.modelUri.toString();

  static Future<String> _path() => WhisperController().getPath(_model);

  static Future<bool> hasModel() async {
    try {
      final f = File(await _path());
      return await f.exists() && await f.length() > 60 * 1024 * 1024;
    } catch (_) {
      return false;
    }
  }

  static Future<void> deleteModel() async {
    try {
      final f = File(await _path());
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Modeli indirir; 0..1 ilerleme yayar. Yarım kalan indirme .part dosyasında tutulur.
  static Stream<double> download() async* {
    final target = await _path();
    final part = File('$target.part');
    final client = HttpClient();
    try {
      final req = await client.getUrl(_model.modelUri);
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) yield got / total;
        }
      } finally {
        await sink.close();
      }
      await part.rename(target);
      yield 1.0;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<SpeechSegment>?> transcribe(String audioPath, String lang) async {
    final r = await WhisperController().transcribe(
      model: _model,
      audioPath: audioPath,
      lang: lang,
      withSegments: true,
    );
    if (r == null) return null;
    final segs = r.transcription.segments;
    if (segs == null || segs.isEmpty) {
      final text = r.transcription.text.trim();
      return text.isEmpty ? const [] : [SpeechSegment(Duration.zero, const Duration(seconds: 5), text)];
    }
    return [for (final s in segs) SpeechSegment(s.fromTs, s.toTs, s.text.trim())];
  }
}
