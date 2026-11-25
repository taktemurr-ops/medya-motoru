/// Fotoğraf, Video ve Ses motoru: 45 aracın gerçek uygulamaları, 33 dilde
/// metinleri ve merkez görünümü. İnce depolar (uyg-*) buradan tek bir araç alır.
///
/// Motor aynı zamanda bir Flutter eklentisidir: Android'de Media3 Transformer,
/// iOS'ta AVFoundation ile video işleri ve ONNX Runtime ile cihaz üzerinde
/// yapay zekâ (bkz. android/, ios/).
library;

export 'src/dsp/audio.dart';
export 'src/dsp/fft.dart';
export 'src/dsp/imaging.dart';
export 'src/media_core.dart';
export 'src/native.dart' show MedyaNative, MediaInfo;
export 'src/registry.dart';
export 'src/tools/ai.dart' show Models, whisperLang, kAppLangs;
export 'src/tools/design.dart' show floodFill, upscaleNearest, shapePath, kPatternIds;
export 'src/tools/photo.dart' show readPhotoMeta, kSwatches;
export 'src/tools/video.dart' show even, evenFit, gifJob;
