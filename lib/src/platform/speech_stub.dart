library;

/// Altyazı satırı.
class SpeechSegment {
  final Duration from;
  final Duration to;
  final String text;
  const SpeechSegment(this.from, this.to, this.text);
}

class Speech {
  static bool get supported => false;
  static const int modelMb = 75;
  static String get modelUrl => '';
  static Future<bool> hasModel() async => false;
  static Stream<double> download() => const Stream<double>.empty();
  static Future<void> deleteModel() async {}
  static Future<List<SpeechSegment>?> transcribe(String audioPath, String lang) async => null;
}
