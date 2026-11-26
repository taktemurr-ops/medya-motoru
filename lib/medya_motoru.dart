/// Fotoğraf, Video ve Ses motoru: 48 aracın gerçek uygulamaları, 33 dilde
/// metinleri ve merkez görünümü. İnce depolar (uyg-*) buradan tek bir araç alır.
///
/// Motor aynı zamanda bir Flutter eklentisidir: Android'de Media3 Transformer,
/// iOS'ta AVFoundation ile video işleri; cihaz üzerinde yapay zekâ Android'de
/// ONNX Runtime, iOS'ta Core ML ile (bkz. android/, ios/). Modeller ilk
/// kullanımda indirilir (SHA-256 doğrulamalı), sonra çevrimdışı çalışır.
library;

export 'src/dsp/audio.dart';
export 'src/dsp/fft.dart';
export 'src/dsp/imaging.dart';
export 'src/ek4_core.dart';
export 'src/media_core.dart';
export 'src/native.dart' show MedyaNative, MediaInfo;
export 'src/registry.dart';
export 'src/tools/ai.dart' show AiModel, Models, whisperLang, kAppLangs;
export 'src/tools/design.dart' show floodFill, upscaleNearest, shapePath, kPatternIds;
export 'src/tools/photo.dart' show readPhotoMeta, kSwatches;
export 'src/tools/video.dart' show even, evenFit, gifJob;
